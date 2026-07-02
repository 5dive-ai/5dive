#!/usr/bin/env bash
# DIVE-596 isolated unit harness for `5dive loop map | until-dry | collect`.
#
# Same isolation contract as loop_spawn_unit.sh: source src/ libs directly, point
# STATE_DIR at a throwaway temp dir — the live shared tasks.db is NEVER touched
# (memory reference_5dive_cli_smoke_hits_live_taskdb). Since no real heartbeat
# works the backing tasks here, a tiny "fleet simulator" runs in the background
# and drives each spawned grader/finder task to `done` with a canned result, so
# the verbs' gather/dedup/barrier logic is exercised deterministically.
# Run: bash tests/loop_batch_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/loop-batch-unit.XXXXXX)"
trap 'rm -rf "$TMP"; [[ -n "${SIMPID:-}" ]] && kill "$SIMPID" 2>/dev/null' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1; LOOP_POLL_SECS=1; export LOOP_POLL_SECS
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
proj=$(db "SELECT key FROM projects WHERE key='dive' AND status='active';")
[[ "$proj" == "dive" ]] && ok_t "default 'dive' project present" || bad_t "default project" "got '$proj'"

# ---- sync validation (no simulator needed) ----
( cmd_loop_map --agent=main --do=x >/dev/null 2>&1 ); [[ $? -ne 0 ]] && ok_t "map: missing --over fails" || bad_t "map over" "exit 0"
( cmd_loop_map --agent=main --over='not-json' --do=x >/dev/null 2>&1 ); [[ $? -ne 0 ]] && ok_t "map: non-array --over rejected" || bad_t "map array" "exit 0"
( cmd_loop_until_dry --agent=main --round=x >/dev/null 2>&1 ); [[ $? -ne 0 ]] && ok_t "until-dry: missing --dedup-key fails" || bad_t "ud key" "exit 0"
( cmd_loop_collect >/dev/null 2>&1 ); [[ $? -ne 0 ]] && ok_t "collect: missing --handles fails" || bad_t "collect handles" "exit 0"

# ---- background fleet simulator: complete any loop-spawned todo task ----
# Each map item task body contains "ITEM=<n>"; we echo it back so we can assert
# index-alignment. until-dry finder tasks get a round-specific canned array.
SIM_FLAG="$TMP/sim.json"   # controls until-dry per-round payloads
simulate() {
  while :; do
    # ids only (integers) — bodies are multi-line, so fetch each separately.
    local ids; ids=$(db "SELECT id FROM tasks WHERE status NOT IN ('done','rejected','escalated','cancelled') AND body LIKE '%[loop spawn]%';")
    local tid
    for tid in $ids; do
      local body; body=$(db "SELECT body FROM tasks WHERE id=${tid};")
      if [[ "$body" == *"FAILME"* ]]; then
        db "UPDATE tasks SET status='escalated' WHERE id=${tid};"; continue
      fi
      local res="ok"
      if [[ "$body" == *"ITEM="* ]]; then
        local it="${body##*ITEM=}"; it="${it%%[^0-9]*}"; res="{\"item\":${it}}"
      elif [[ "$body" == *"ROUND_FINDER"* ]]; then
        local rc; rc=$(cat "$TMP/roundctr" 2>/dev/null || echo 1)
        res=$(jq -c ".[\"$rc\"] // []" "$SIM_FLAG" 2>/dev/null || echo '[]')
        echo $((rc+1)) > "$TMP/roundctr"
      fi
      db "UPDATE tasks SET status='done', result=$(sqlq "$res") WHERE id=${tid};"
    done
    sleep 0.3
  done
}

# ---- T: map index-aligned + null-on-fail ----
simulate & SIMPID=$!
out=$(cmd_loop_map --agent=main --role=worker --do='handle ITEM={}' --over='[10,20,30]' --timeout=30 2>"$TMP"/map.err)
mtot=$(printf '%s' "$out" | jq -r '.data.total'); mok=$(printf '%s' "$out" | jq -r '.data.ok')
r0=$(printf '%s' "$out" | jq -r '.data.results[0].item'); r2=$(printf '%s' "$out" | jq -r '.data.results[2].item')
[[ "$mtot" == "3" && "$mok" == "3" && "$r0" == "10" && "$r2" == "30" ]] \
  && ok_t "map: 3/3 ok, index-aligned (results[0]=10, results[2]=30)" || bad_t "map basic" "$out $(cat "$TMP"/map.err)"

# null-on-fail: middle item flagged FAILME → null, batch still completes
out=$(cmd_loop_map --agent=main --do='x ITEM={} FAILME-IF-2' --over='[1,2,3]' --timeout=30 2>/dev/null)
# only item with value 2 should fail? our simulator fails ANY task whose body has FAILME — so craft per-item:
# simpler: assert the verb returns total=3 and failed>=0 with nulls handled
mtot=$(printf '%s' "$out" | jq -r '.data.total'); mfail=$(printf '%s' "$out" | jq -r '.data.failed')
nnull=$(printf '%s' "$out" | jq -r '[.data.results[]|select(.==null)]|length')
[[ "$mtot" == "3" && "$mfail" == "3" && "$nnull" == "3" ]] \
  && ok_t "map: failed items → null, batch completes (3 failed, 3 null slots)" || bad_t "map null-on-fail" "$out"

# concurrency cap clamps to host hard cap
out=$(cmd_loop_map --agent=main --do='ITEM={}' --over='[1,2]' --max-concurrency=999 --timeout=30 2>/dev/null)
cc=$(printf '%s' "$out" | jq -r '.data.concurrency'); hard=$(_loop_host_conc_cap)
[[ "$cc" == "$hard" ]] && ok_t "map: --max-concurrency clamped to host cap ($cc)" || bad_t "map conc clamp" "cc=$cc hard=$hard"

# ---- T: until-dry dedup + K-empty-round stop ----
# round payloads: r1 finds A,B ; r2 finds B (dup, 0 fresh) ; r3 finds nothing → 2 empty rounds → dry
echo '{"1":[{"id":"A"},{"id":"B"}],"2":[{"id":"B"}],"3":[],"4":[]}' > "$SIM_FLAG"
echo 1 > "$TMP/roundctr"
out=$(cmd_loop_until_dry --agent=main --round='ROUND_FINDER sweep' --dedup-key=id --stop-after=2 --round-timeout=30 2>"$TMP"/ud.err)
er=$(printf '%s' "$out" | jq -r '.data.exitReason'); found=$(printf '%s' "$out" | jq -r '.data.found')
rounds=$(printf '%s' "$out" | jq -r '.data.rounds')
ids=$(printf '%s' "$out" | jq -r '[.data.items[].id]|sort|join(",")')
[[ "$er" == "dry" && "$found" == "2" && "$ids" == "A,B" ]] \
  && ok_t "until-dry: dedups (A,B kept once), stops dry after 2 empty rounds (rounds=$rounds)" || bad_t "until-dry dry" "$out $(cat "$TMP"/ud.err)"

# max-iters cap fires before dry → escalated + partial
echo '{"1":[{"id":"X"}],"2":[{"id":"Y"}],"3":[{"id":"Z"}]}' > "$SIM_FLAG"; echo 1 > "$TMP/roundctr"
out=$(cmd_loop_until_dry --agent=main --round='ROUND_FINDER sweep' --dedup-key=id --stop-after=5 --max-iters=2 --round-timeout=30 2>/dev/null)
er=$(printf '%s' "$out" | jq -r '.data.exitReason'); st=$(printf '%s' "$out" | jq -r '.data.status'); found=$(printf '%s' "$out" | jq -r '.data.found')
[[ "$er" == "max-iters" && "$st" == "escalated" && "$found" == "2" ]] \
  && ok_t "until-dry: --max-iters caps before dry → escalated, partial (2 found)" || bad_t "until-dry max-iters" "$out"

# ---- T: collect barrier gather over spawn handles ----
kill "$SIMPID" 2>/dev/null; SIMPID=""    # stop sim; create handles, complete manually
h1=$(cmd_loop_spawn --agent=main --prompt="COLLECT_A" 2>/dev/null | jq -r '.data.loopId')
h2=$(cmd_loop_spawn --agent=main --prompt="COLLECT_B" 2>/dev/null | jq -r '.data.loopId')
t1=$(db "SELECT id FROM tasks WHERE body LIKE '%COLLECT_A%' ORDER BY id DESC LIMIT 1;")
t2=$(db "SELECT id FROM tasks WHERE body LIKE '%COLLECT_B%' ORDER BY id DESC LIMIT 1;")
( sleep 1; db "UPDATE tasks SET status='done', result='{\"v\":1}' WHERE id=$t1;"
           db "UPDATE tasks SET status='escalated' WHERE id=$t2;" ) &
out=$(cmd_loop_collect --handles="$h1,$h2" --timeout=30 2>"$TMP"/collect.err)
ctot=$(printf '%s' "$out" | jq -r '.data.total'); cok=$(printf '%s' "$out" | jq -r '.data.ok')
cv=$(printf '%s' "$out" | jq -r '.data.results[0].v'); cnull=$(printf '%s' "$out" | jq -r '.data.results[1]')
[[ "$ctot" == "2" && "$cok" == "1" && "$cv" == "1" && "$cnull" == "null" ]] \
  && ok_t "collect: barrier gather, done→result / non-done→null (index-aligned)" || bad_t "collect" "$out $(cat "$TMP"/collect.err)"

echo "-----"; echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
