#!/usr/bin/env bash
# DIVE-968 isolated unit harness for `5dive loop status` — the read-only
# single-loop drilldown (topology/stage/iter/tokens/stuck + backing-task state).
# Same isolation as the other loop harnesses: source src/ libs, point STATE_DIR
# at a throwaway temp dir — the live shared tasks.db is NEVER touched.
# Run: bash tests/loop_status_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/loop-status-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

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

now=$(date +%s)
# Seed two backing tasks (one done, one open) + a running panel loop over them.
db "INSERT INTO tasks (ident, title, status, assignee, project_key)
    VALUES ('DIVE-1','g1','done','dev','dive');"
db "INSERT INTO tasks (ident, title, status, assignee, project_key)
    VALUES ('DIVE-2','g2','todo','dev','dive');"
t1=$(db "SELECT id FROM tasks WHERE ident='DIVE-1';")
t2=$(db "SELECT id FROM tasks WHERE ident='DIVE-2';")
db "INSERT INTO loop_runs (loop_id, topology, status, stage, iteration, tokens_spent, ceiling,
                           child_task_ids, spawned_by_agent, started_at, updated_at)
    VALUES ('L-run','panel','running','panel:correctness',2,40000,200000,'[${t1},${t2}]','dev',$now,$now);"
# A running loop that is over its ceiling → derived stuck=ceiling.
db "INSERT INTO loop_runs (loop_id, topology, status, tokens_spent, ceiling, started_at, updated_at)
    VALUES ('L-cap','map','running',200000,200000,$now,$now);"
# A running loop with a stale heartbeat → derived stuck=stale.
db "INSERT INTO loop_runs (loop_id, topology, status, tokens_spent, ceiling, started_at, updated_at)
    VALUES ('L-old','spawn','running',1000,200000,$((now-100000)),$((now-100000)));"
# A finished loop that is stale → NOT stuck (terminal).
db "INSERT INTO loop_runs (loop_id, topology, status, tokens_spent, ceiling, started_at, updated_at)
    VALUES ('L-fin','spawn','done',5000,200000,$((now-100000)),$((now-100000)));"

# --- T1: known handle → full drilldown with child states resolved
out=$( cmd_loop_status --handle=L-run )
okf=$(printf '%s' "$out"   | jq -r '.ok')
topo=$(printf '%s' "$out"  | jq -r '.data.topology')
stage=$(printf '%s' "$out" | jq -r '.data.stage')
iter=$(printf '%s' "$out"  | jq -r '.data.iteration')
tot=$(printf '%s' "$out"   | jq -r '.data.childCounts.total')
cdone=$(printf '%s' "$out" | jq -r '.data.childCounts.done')
copen=$(printf '%s' "$out" | jq -r '.data.childCounts.open')
[[ "$okf" == "true" && "$topo" == "panel" && "$stage" == "panel:correctness" \
   && "$iter" == "2" && "$tot" == "2" && "$cdone" == "1" && "$copen" == "1" ]] \
  && ok_t "loop status L-run → drilldown + child breakdown (1 done/1 open)" || bad_t "T1" "$out"

# --- T2: children carry resolved ident/status
idents=$(printf '%s' "$out" | jq -r '[.data.children[].ident]|sort|join(",")')
[[ "$idents" == "DIVE-1,DIVE-2" ]] && ok_t "loop status resolves child idents" || bad_t "T2" "$out"

# --- T3: positional handle works too
out=$( cmd_loop_status L-run )
[[ "$(printf '%s' "$out" | jq -r '.data.loopId')" == "L-run" ]] \
  && ok_t "loop status accepts a positional handle" || bad_t "T3" "$out"

# --- T4: over-ceiling running loop → stuck=true, reason=ceiling
out=$( cmd_loop_status --handle=L-cap )
st=$(printf '%s' "$out" | jq -r '.data.stuck'); sr=$(printf '%s' "$out" | jq -r '.data.stuckReason')
[[ "$st" == "true" && "$sr" == "ceiling" ]] && ok_t "over-ceiling running loop is stuck (ceiling)" || bad_t "T4" "$out"

# --- T5: stale running loop → stuck=true, reason=stale
out=$( cmd_loop_status --handle=L-old )
st=$(printf '%s' "$out" | jq -r '.data.stuck'); sr=$(printf '%s' "$out" | jq -r '.data.stuckReason')
[[ "$st" == "true" && "$sr" == "stale" ]] && ok_t "stale running loop is stuck (stale)" || bad_t "T5" "$out"

# --- T6: terminal loop is never stuck even when stale
out=$( cmd_loop_status --handle=L-fin )
st=$(printf '%s' "$out" | jq -r '.data.stuck')
[[ "$st" == "false" ]] && ok_t "terminal (done) loop is never stuck" || bad_t "T6" "$out"

# --- T7: unknown handle → NOT_FOUND envelope (not a crash / not a silent ok)
out=$( cmd_loop_status --handle=L-nope )
okf=$(printf '%s' "$out" | jq -r '.ok'); cls=$(printf '%s' "$out" | jq -r '.error.class // ""')
[[ "$okf" == "false" ]] && ok_t "unknown handle → ok:false error envelope ($cls)" || bad_t "T7" "$out"

# --- T8: missing handle → usage error
out=$( cmd_loop_status )
[[ "$(printf '%s' "$out" | jq -r '.ok')" == "false" ]] \
  && ok_t "missing --handle → usage error" || bad_t "T8" "$out"

# --- T9: text mode renders header + does not crash
JSON_MODE=0
tout=$( cmd_loop_status --handle=L-run 2>&1 )
JSON_MODE=1
printf '%s' "$tout" | grep -q "loop L-run" && printf '%s' "$tout" | grep -q "backing tasks" \
  && ok_t "text mode renders header + backing-task board" || bad_t "T9" "$tout"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
