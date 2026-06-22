#!/usr/bin/env bash
# DIVE-595 isolated unit harness for `5dive loop panel` (N diverse-lens graders
# + quorum vote + cost-dial config).
#
# Same isolation contract as loop_spawn_unit.sh: source src/ libs directly and
# point STATE_DIR at a throwaway temp dir so the live shared tasks.db is NEVER
# touched (memory reference_5dive_cli_smoke_hits_live_taskdb). Asserts: N grader
# tasks + panel loop_runs row created, lens/N/quorum resolution + config
# default + clamp, quorum PASS/FAIL math, kill + ceiling halt.
# Run: bash tests/loop_panel_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/loop-panel-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
LOOP_POLL_SECS=1
export LOOP_POLL_SECS
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run() { ( cmd_loop_panel "$@" ) 2>/tmp/loop-panel.err; }
# grader backing tasks all carry the claim text → find them by a unique token.
grader_tids() { db "SELECT id FROM tasks WHERE body LIKE '%$1%' ORDER BY id;"; }

tasks_db_init
proj=$(db "SELECT key FROM projects WHERE key='dive' AND status='active';")
[[ "$proj" == "dive" ]] && ok_t "default 'dive' project present" || bad_t "default project" "got '$proj'"

# --- T1: no-wait creates N=3 graders + panel row, default quorum 2
out=$(run --agent=main --claim="UNIQ_basic judge this")
st=$(printf '%s' "$out" | jq -r '.data.status' 2>/dev/null)
lid=$(printf '%s' "$out" | jq -r '.data.loopId' 2>/dev/null)
pn=$(printf '%s' "$out" | jq -r '.data.n' 2>/dev/null)
pq=$(printf '%s' "$out" | jq -r '.data.quorum' 2>/dev/null)
mlen=$(printf '%s' "$out" | jq -r '.data.members | length' 2>/dev/null)
[[ "$st" == "running" && "$lid" == L-* && "$pn" == "3" && "$pq" == "2" && "$mlen" == "3" ]] \
  && ok_t "panel no-wait → running, N=3, quorum=2, 3 members" || bad_t "panel basic" "$out $(cat /tmp/loop-panel.err)"
topo=$(db "SELECT topology FROM loop_runs WHERE loop_id='$lid';")
child=$(db "SELECT child_task_ids FROM loop_runs WHERE loop_id='$lid';")
nchild=$(printf '%s' "$child" | jq 'length' 2>/dev/null)
[[ "$topo" == "panel" && "$nchild" == "3" ]] \
  && ok_t "loop_runs panel row links 3 grader tasks ($child)" || bad_t "panel row" "topo=$topo child=$child"

# --- T2: validation
run --claim=x >/dev/null 2>&1;  [[ $? -ne 0 ]] && ok_t "missing --agent fails"  || bad_t "missing agent" "exit 0"
run --agent=main >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "missing --claim fails" || bad_t "missing claim" "exit 0"
run --agent=main --claim=x --n=abc >/dev/null 2>&1;     [[ $? -ne 0 ]] && ok_t "bad --n rejected"      || bad_t "bad n" "exit 0"
run --agent=main --claim=x --quorum=0 >/dev/null 2>&1;  [[ $? -ne 0 ]] && ok_t "--quorum=0 rejected"   || bad_t "bad quorum" "exit 0"

# --- T3: --lens sets N to lens count; per-grader lens recorded
out=$(run --agent=main --claim="UNIQ_lenses x" --lens="correctness, security, repro, perf")
pn=$(printf '%s' "$out" | jq -r '.data.n')
lns=$(printf '%s' "$out" | jq -r '.data.lenses | join(",")')
[[ "$pn" == "4" && "$lns" == "correctness,security,repro,perf" ]] \
  && ok_t "--lens defines N=4 + trimmed lens list" || bad_t "lens N" "n=$pn lenses=$lns"

# --- T4: --n overrides + round-robins lenses; quorum clamp to N
out=$(run --agent=main --claim="UNIQ_clamp x" --lens="a,b" --n=3 --quorum=9)
pn=$(printf '%s' "$out" | jq -r '.data.n'); pq=$(printf '%s' "$out" | jq -r '.data.quorum')
lns=$(printf '%s' "$out" | jq -r '.data.lenses | join(",")')
[[ "$pn" == "3" && "$pq" == "3" && "$lns" == "a,b,a" ]] \
  && ok_t "--n=3 round-robins 2 lenses (a,b,a) + quorum clamped 9→3" || bad_t "n override/clamp" "n=$pn q=$pq lenses=$lns"

# --- T5: config defaults (cost-dial)
out=$(LOOP_PANEL_N_DEFAULT=2 LOOP_PANEL_QUORUM_DEFAULT=1 run --agent=main --claim="UNIQ_cfg x")
pn=$(printf '%s' "$out" | jq -r '.data.n'); pq=$(printf '%s' "$out" | jq -r '.data.quorum')
[[ "$pn" == "2" && "$pq" == "1" ]] \
  && ok_t "LOOP_PANEL_N/QUORUM_DEFAULT applied (N=2 q=1)" || bad_t "config default" "n=$pn q=$pq"

# --- T6: --wait quorum PASS (2 of 3 pass ≥ quorum 2)
( cmd_loop_panel --agent=main --claim="UNIQ_passvote x" --n=3 --quorum=2 --wait=20 >/tmp/panel-pass.out 2>&1 ) &
bgpid=$!; sleep 1
mapfile -t tids < <(grader_tids UNIQ_passvote)
db "UPDATE tasks SET status='done', result='{\"verdict\":\"pass\"}' WHERE id=${tids[0]};"
db "UPDATE tasks SET status='done', result='{\"verdict\":\"pass\"}' WHERE id=${tids[1]};"
db "UPDATE tasks SET status='done', result='{\"verdict\":\"fail\"}' WHERE id=${tids[2]};"
wait $bgpid
pv=$(jq -r '.data.verdict' /tmp/panel-pass.out 2>/dev/null)
pp=$(jq -r '.data.pass' /tmp/panel-pass.out 2>/dev/null)
[[ "$pv" == "pass" && "$pp" == "2" ]] \
  && ok_t "--wait quorum PASS (2/3 pass → pass)" || bad_t "quorum pass" "$(cat /tmp/panel-pass.out)"

# --- T7: --wait quorum FAIL (1 of 3 pass < quorum 2)
( cmd_loop_panel --agent=main --claim="UNIQ_failvote x" --n=3 --quorum=2 --wait=20 >/tmp/panel-fail.out 2>&1 ) &
bgpid=$!; sleep 1
mapfile -t tids < <(grader_tids UNIQ_failvote)
db "UPDATE tasks SET status='done', result='{\"verdict\":\"pass\"}' WHERE id=${tids[0]};"
db "UPDATE tasks SET status='done', result='{\"verdict\":\"fail\"}' WHERE id=${tids[1]};"
db "UPDATE tasks SET status='done', result='{\"verdict\":\"fail\"}' WHERE id=${tids[2]};"
wait $bgpid
fv=$(jq -r '.data.verdict' /tmp/panel-fail.out 2>/dev/null)
[[ "$fv" == "fail" ]] \
  && ok_t "--wait quorum FAIL (1/3 pass → fail)" || bad_t "quorum fail" "$(cat /tmp/panel-fail.out)"

# --- T8: --wait halts on KILL
( cmd_loop_panel --agent=main --claim="UNIQ_killpanel x" --n=2 --wait=20 >/tmp/panel-kill.out 2>&1 ) &
bgpid=$!; sleep 1
klid=$(db "SELECT loop_id FROM loop_runs WHERE topology='panel' AND child_task_ids LIKE '%' ORDER BY started_at DESC, rowid DESC LIMIT 1;")
db "UPDATE loop_runs SET kill_requested=1 WHERE loop_id='$klid';"
wait $bgpid
kst=$(jq -r '.data.status' /tmp/panel-kill.out 2>/dev/null)
[[ "$kst" == "killed" ]] && ok_t "--wait halts on kill_requested → killed" || bad_t "kill halt" "$(cat /tmp/panel-kill.out)"

# --- T9: --wait halts on CEILING breach → escalated
( cmd_loop_panel --agent=main --claim="UNIQ_ceilpanel x" --n=2 --ceiling=1000 --wait=20 >/tmp/panel-ceil.out 2>&1 ) &
bgpid=$!; sleep 1
clid=$(db "SELECT loop_id FROM loop_runs WHERE topology='panel' ORDER BY started_at DESC, rowid DESC LIMIT 1;")
db "UPDATE loop_runs SET tokens_spent=5000 WHERE loop_id='$clid';"
wait $bgpid
cst=$(jq -r '.data.status' /tmp/panel-ceil.out 2>/dev/null)
[[ "$cst" == "escalated" ]] && ok_t "--wait halts on ceiling breach → escalated" || bad_t "ceiling halt" "$(cat /tmp/panel-ceil.out)"

echo "-----"; echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
