#!/usr/bin/env bash
# DIVE-748 isolated unit harness for `5dive loop grade` (numeric scorecard).
#
# Same isolation contract as loop_spawn_unit.sh: sources src/ libs directly and
# points STATE_DIR at a throwaway temp dir so it NEVER touches the live shared
# tasks.db. Asserts: grader spawned + loop_runs topology='grade' row, arg/criteria
# validation, writer≠grader, and the --wait scorecard parse → verdict (pass/fail/
# escalate) with scorecard_json persisted. Run: bash tests/loop_grade_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/loop-grade-unit.XXXXXX)"
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
run() { ( cmd_loop_grade "$@" ) 2>/tmp/loop-grade.err; }

tasks_db_init

# sqlite JSON1 is required by the `task loops` score column (json_extract/json_valid).
jv=$(db "SELECT json_valid('{\"a\":1}');")
[[ "$jv" == "1" ]] && ok_t "sqlite JSON1 available" || bad_t "JSON1 missing" "got '$jv'"

# scorecard_json column exists on loop_runs (DIVE-748 schema/migration)
has_col=$(db "SELECT 1 FROM pragma_table_info('loop_runs') WHERE name='scorecard_json';")
[[ "$has_col" == "1" ]] && ok_t "loop_runs.scorecard_json column present" || bad_t "scorecard_json column" "missing"

# A maker task with acceptance criteria, owned by 'dev' (≠ grader 'main').
out=$(JSON_MODE=1 cmd_task_add "build the thing" --assignee=dev --accept="UNIQ_AC1 must compile; must have tests" 2>/tmp/loop-grade.err)
TGT=$(printf '%s' "$out" | jq -r '.data.ident // .data.id' 2>/dev/null)
[[ -n "$TGT" && "$TGT" != "null" ]] && ok_t "seed target task ($TGT)" || bad_t "seed target" "$out $(cat /tmp/loop-grade.err)"

# --- T1: no-wait grade spawns a grader + grade loop row
out=$(run --target="$TGT" --verifier=main)
st=$(printf '%s' "$out" | jq -r '.data.status' 2>/dev/null)
top=$(printf '%s' "$out" | jq -r '.data.topology' 2>/dev/null)
gtask=$(printf '%s' "$out" | jq -r '.data.graderTask' 2>/dev/null)
[[ "$st" == "grading" && "$top" == "grade" && "$gtask" =~ ^[0-9]+$ ]] \
  && ok_t "no-wait grade → {grading, grade, graderTask}" || bad_t "grade basic" "$out $(cat /tmp/loop-grade.err)"
gassignee=$(db "SELECT assignee FROM tasks WHERE id=$gtask;")
[[ "$gassignee" == "main" ]] && ok_t "grader task assigned to --verifier" || bad_t "grader assignee" "$gassignee"

# --- T2: validation
run --verifier=main >/dev/null 2>&1;  [[ $? -ne 0 ]] && ok_t "missing --target fails" || bad_t "missing target" "exit 0"
run --target="$TGT" >/dev/null 2>&1;  [[ $? -ne 0 ]] && ok_t "missing --verifier fails" || bad_t "missing verifier" "exit 0"
run --target="$TGT" --verifier=dev >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "writer==grader rejected" || bad_t "writer=grader" "exit 0"
run --target="$TGT" --verifier=main --threshold=150 >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "bad --threshold rejected" || bad_t "bad threshold" "exit 0"
# task with NO acceptance criteria → cannot grade
nout=$(JSON_MODE=1 cmd_task_add "no criteria task" --assignee=dev 2>/dev/null)
NAC=$(printf '%s' "$nout" | jq -r '.data.ident // .data.id')
run --target="$NAC" --verifier=main >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "no acceptance_criteria rejected" || bad_t "no criteria" "exit 0"

# helper: the grader task id for the most recent grade loop row
latest_grade_child() { db "SELECT TRIM(child_task_ids,'[]') FROM loop_runs WHERE topology='grade' ORDER BY started_at DESC, rowid DESC LIMIT 1;"; }

# --- T3: --wait, grader scores high → verdict pass, scorecard persisted
( cmd_loop_grade --target="$TGT" --verifier=main --threshold=70 --wait=20 >/tmp/loop-grade-pass.out 2>&1 ) &
bgpid=$!
sleep 1; g3=$(latest_grade_child)
db "UPDATE tasks SET status='done', result='{\"overall\":88,\"criteria\":[{\"name\":\"compile\",\"score\":95,\"reason\":\"ok\"},{\"name\":\"tests\",\"score\":80}]}' WHERE id=$g3;"
wait $bgpid
v3=$(jq -r '.data.verdict' /tmp/loop-grade-pass.out 2>/dev/null)
o3=$(jq -r '.data.overall' /tmp/loop-grade-pass.out 2>/dev/null)
[[ "$v3" == "pass" && "$o3" == "88" ]] \
  && ok_t "--wait high score → pass (overall=$o3)" || bad_t "grade pass" "$(cat /tmp/loop-grade-pass.out)"
l3=$(jq -r '.data.loopId' /tmp/loop-grade-pass.out 2>/dev/null)
sc=$(db "SELECT scorecard_json FROM loop_runs WHERE loop_id='$l3';")
scov=$(printf '%s' "$sc" | jq -r '.overall' 2>/dev/null)
sccrit=$(printf '%s' "$sc" | jq -r '.criteria | length' 2>/dev/null)
[[ "$scov" == "88" && "$sccrit" == "2" ]] \
  && ok_t "scorecard_json persisted (overall=$scov, ${sccrit} criteria)" || bad_t "scorecard persist" "$sc"

# --- T4: --wait, grader scores low → verdict fail
( cmd_loop_grade --target="$TGT" --verifier=main --threshold=70 --wait=20 >/tmp/loop-grade-fail.out 2>&1 ) &
bgpid=$!
sleep 1; g4=$(latest_grade_child)
db "UPDATE tasks SET status='done', result='{\"overall\":40,\"criteria\":[{\"name\":\"compile\",\"score\":40}]}' WHERE id=$g4;"
wait $bgpid
v4=$(jq -r '.data.verdict' /tmp/loop-grade-fail.out 2>/dev/null)
[[ "$v4" == "fail" ]] && ok_t "--wait low score → fail" || bad_t "grade fail" "$(cat /tmp/loop-grade-fail.out)"

# --- T5: --wait, grader returns unparseable result → escalated (never silent pass)
( cmd_loop_grade --target="$TGT" --verifier=main --wait=20 >/tmp/loop-grade-esc.out 2>&1 ) &
bgpid=$!
sleep 1; g5=$(latest_grade_child)
db "UPDATE tasks SET status='done', result='not json at all' WHERE id=$g5;"
wait $bgpid
v5=$(jq -r '.data.verdict' /tmp/loop-grade-esc.out 2>/dev/null)
[[ "$v5" == "escalated" ]] && ok_t "--wait unparseable → escalated" || bad_t "grade escalate" "$(cat /tmp/loop-grade-esc.out)"

# --- T6: kill mid-wait → killed
( cmd_loop_grade --target="$TGT" --verifier=main --wait=20 >/tmp/loop-grade-kill.out 2>&1 ) &
bgpid=$!
sleep 1
klid=$(db "SELECT loop_id FROM loop_runs WHERE topology='grade' AND status='running' ORDER BY started_at DESC, rowid DESC LIMIT 1;")
db "UPDATE loop_runs SET kill_requested=1 WHERE loop_id='$klid';"
wait $bgpid
kst=$(jq -r '.data.status' /tmp/loop-grade-kill.out 2>/dev/null)
[[ "$kst" == "killed" ]] && ok_t "--wait halts on kill → killed" || bad_t "grade kill" "$(cat /tmp/loop-grade-kill.out)"

echo "-----"; echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
