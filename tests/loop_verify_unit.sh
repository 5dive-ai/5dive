#!/usr/bin/env bash
# DIVE-594 isolated unit harness for `5dive loop verify` (maker→verifier wrapper).
# Same isolation as loop_spawn_unit.sh: sources src/ directly, points STATE_DIR
# at a throwaway temp dir → never touches the live shared tasks.db. Asserts:
# verifier+accept attach to the target, writer≠grader guard, terminal-target
# guard, loop_runs row, and the --wait verdict/halt paths. Run:
#   bash tests/loop_verify_unit.sh   (no root, no network)
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/loop-verify-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1; LOOP_POLL_SECS=1; export LOOP_POLL_SECS
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; tests expect non-zero exits

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# helper: create a target task assigned to a maker, echo its numeric id
mk_target() { ( JSON_MODE=1 cmd_task_add --assignee="$1" --body="$2" -- "$2" ) 2>/dev/null | jq -r '.data.id'; }

# --- T1: attach verifier + accept; returns verifying; loop_runs row; fields set
tid=$(mk_target maker "UNIQ_target_one")
out=$( ( cmd_loop_verify --target="$tid" --verifier=grader --accept="must compile" ) 2>"$TMP"/lv.err )
st=$(printf '%s' "$out" | jq -r '.data.status' 2>/dev/null)
lid=$(printf '%s' "$out" | jq -r '.data.loopId' 2>/dev/null)
[[ "$st" == "verifying" && "$lid" == L-* ]] && ok_t "verify returns {verifying, loopId}" || bad_t "verify basic" "$out $(cat "$TMP"/lv.err)"
v=$(db "SELECT verifier FROM tasks WHERE id=$tid;"); a=$(db "SELECT acceptance_criteria FROM tasks WHERE id=$tid;")
[[ "$v" == "grader" && "$a" == "must compile" ]] && ok_t "verifier+acceptance attached to target ($v/$a)" || bad_t "attach" "v=$v a=$a"
topo=$(db "SELECT topology FROM loop_runs WHERE loop_id='$lid';"); child=$(db "SELECT child_task_ids FROM loop_runs WHERE loop_id='$lid';")
[[ "$topo" == "verify" && "$child" == "[$tid]" ]] && ok_t "loop_runs verify row linked ($child)" || bad_t "loop_runs" "topo=$topo child=$child"

# --- T2: writer≠grader guard (verifier == assignee → reject)
tid2=$(mk_target maker "UNIQ_target_two")
( cmd_loop_verify --target="$tid2" --verifier=maker ) >/dev/null 2>&1
[[ $? -ne 0 ]] && ok_t "verifier==assignee rejected (writer≠grader)" || bad_t "writer=grader" "exit 0"

# --- T3: terminal-target guard
tid3=$(mk_target maker "UNIQ_target_three"); db "UPDATE tasks SET status='done' WHERE id=$tid3;"
( cmd_loop_verify --target="$tid3" --verifier=grader ) >/dev/null 2>&1
[[ $? -ne 0 ]] && ok_t "done target rejected (attach before close)" || bad_t "terminal target" "exit 0"

# --- T4: arg validation
( cmd_loop_verify --target="$tid" --verifier=grader --max-iters=0 ) >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "--max-iters=0 rejected" || bad_t "max-iters" "exit 0"
( cmd_loop_verify --target="$tid" --verifier=grader --ceiling=x ) >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "non-int --ceiling rejected" || bad_t "ceiling" "exit 0"

# --- T5: --wait → done verdict pass (flip target done mid-wait)
tidw=$(mk_target maker "UNIQ_target_wait")
( cmd_loop_verify --target="$tidw" --verifier=grader --wait=20 >"$TMP"/lv-done.out 2>&1 ) &
bg=$!; sleep 1; db "UPDATE tasks SET status='done', result='graded PASS' WHERE id=$tidw;"; wait $bg
dst=$(jq -r '.data.status' "$TMP"/lv-done.out 2>/dev/null); dvd=$(jq -r '.data.verdict' "$TMP"/lv-done.out 2>/dev/null); dres=$(jq -r '.data.result' "$TMP"/lv-done.out 2>/dev/null)
[[ "$dst" == "done" && "$dvd" == "pass" && "$dres" == "graded PASS" ]] && ok_t "--wait → done/pass with result" || bad_t "wait done" "$(cat "$TMP"/lv-done.out)"

# --- T6: --wait halts on KILL
tidk=$(mk_target maker "UNIQ_target_kill")
( cmd_loop_verify --target="$tidk" --verifier=grader --wait=20 >"$TMP"/lv-kill.out 2>&1 ) &
bg=$!; sleep 1
klid=$(db "SELECT lr.loop_id FROM loop_runs lr WHERE lr.child_task_ids='[$tidk]' ORDER BY lr.started_at DESC LIMIT 1;")
db "UPDATE loop_runs SET kill_requested=1 WHERE loop_id='$klid';"; wait $bg
kst=$(jq -r '.data.status' "$TMP"/lv-kill.out 2>/dev/null)
[[ "$kst" == "killed" ]] && ok_t "--wait halts on kill → killed" || bad_t "kill" "$(cat "$TMP"/lv-kill.out)"

# --- T7: --wait halts on CEILING
tidc=$(mk_target maker "UNIQ_target_ceil")
( cmd_loop_verify --target="$tidc" --verifier=grader --ceiling=1000 --wait=20 >"$TMP"/lv-ceil.out 2>&1 ) &
bg=$!; sleep 1
clid=$(db "SELECT lr.loop_id FROM loop_runs lr WHERE lr.child_task_ids='[$tidc]' ORDER BY lr.started_at DESC LIMIT 1;")
db "UPDATE loop_runs SET tokens_spent=5000 WHERE loop_id='$clid';"; wait $bg
cst=$(jq -r '.data.status' "$TMP"/lv-ceil.out 2>/dev/null); cvd=$(jq -r '.data.verdict' "$TMP"/lv-ceil.out 2>/dev/null)
[[ "$cst" == "escalated" && "$cvd" == "escalated" ]] && ok_t "--wait halts on ceiling → escalated" || bad_t "ceiling halt" "$(cat "$TMP"/lv-ceil.out)"

echo "-----"; echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
