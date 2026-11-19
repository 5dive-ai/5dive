#!/usr/bin/env bash
# TIER: nightly — sources the goal + heartbeat stack like goal_async_unit.sh (DIVE-2525's tier).
# DIVE-8778: on CLI 0.137 every `goal add` on even-branch failed «planner returned an empty or
# invalid plan». The planner agent wrote its JSON plan to a scratchpad file and closed the task with a
# one-line summary naming that file, because the wake line told it «--result=<1-2 self-contained
# sentences>» and that beat the planner prompt's «return ONLY a JSON object» (3 of 3 plans, 11-19).
#
# Arms:
#   (1) an agent that writes the plan to a FILE and closes with `task done --result-file=` → the
#       goal job is done, with the plan's tasks (the regression arm the row asked for);
#   (2) the shape seen on even-branch (a sentence + the file's path) still fails cleanly: the
#       poller never reads a path the agent names;
#   (3) a plan wrapped in a ```json fence or a sentence is still taken;
#   (4) the wake line for the planner row says --result-file and JSON only; a plain row's line is
#       unchanged («1-2 self-contained sentences»);
#   (5) the planner prompt says how to finish.
# Run: bash tests/goal_planner_result_file_unit.sh  (no root, no network).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/goal-planner-file-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_goal.sh cmd_loop.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init
_org_resolve_assignee() { printf '%s' "dev"; }   # stub: any assignee resolves (as goal_async_unit.sh)

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run() { ( set -e; "$@" ) 2>/dev/null; }

PLAN='{"project":{"key":"widget","name":"Ship widget","goal":"Ship the widget"},
  "tasks":[
    {"local_id":"t1","title":"Design widget","assignee_or_role":"dev","risk":"low"},
    {"local_id":"t2","title":"Build widget","assignee_or_role":"dev","depends_on":["t1"],"risk":"low"}]}'

new_job() {   # <outcome> → sets JOB TASK_ID IDENT
  local out; out=$(run cmd_goal_add --planner=dev --dry-run -- "$1")
  JOB=$(printf '%s' "$out" | jq -r '.data.job // ""' 2>/dev/null)
  TASK_ID=$(db "SELECT task_id FROM goal_jobs WHERE job_id=$(sqlq "$JOB");")
  IDENT=$(db "SELECT ident FROM tasks WHERE id=${TASK_ID:-0};")
}
job_state() { run cmd_goal_status "$JOB" | jq -r '[.data.status // "", (.data.taskCount // 0 | tostring), (.data.reason // "")] | join("|")'; }

# ---- (1) the agent writes the plan to a file and closes with --result-file ----
new_job "Ship a widget"
printf '%s\n' "$PLAN" > "$TMP/plan.json"
out=$( ( set -e; FIVE_ACTOR=dev cmd_task_done "$IDENT" --result-file="$TMP/plan.json" ) 2>&1 ); rc=$?
st=$(db "SELECT status FROM tasks WHERE id=${TASK_ID};")
[[ $rc -eq 0 && "$st" == "done" ]] \
  && ok_t "the planner closes its task with task done --result-file (task $IDENT done)" \
  || bad_t "task done --result-file closes the planner task" "rc=$rc status=$st out=$out"
got=$(job_state)
[[ "$got" == done\|2\|* ]] \
  && ok_t "a plan closed from a file is the goal's plan: job done, 2 tasks" \
  || bad_t "result-file plan reaches goal status" "got=$got"

# ---- (2) even-branch's shape: a sentence naming the file → failed, the file is never read ----
new_job "Ship a gadget"
db "UPDATE tasks SET status='done', result=$(sqlq "Plan: two low-risk tasks for dev. Full JSON graph: $TMP/plan.json") WHERE id=${TASK_ID};" >/dev/null
got=$(job_state)
[[ "$got" == "failed|0|planner returned an empty or invalid plan" ]] \
  && ok_t "a summary naming a file is still «empty or invalid plan» (no path is read)" \
  || bad_t "summary + path fails cleanly" "got=$got"

# ---- (3) a plan wrapped in a fence, or in a sentence, is still taken ----
new_job "Ship a fenced widget"
db "UPDATE tasks SET status='done', result=$(sqlq "Here is the plan:
\`\`\`json
$PLAN
\`\`\`
Two tasks.") WHERE id=${TASK_ID};" >/dev/null
got=$(job_state)
[[ "$got" == done\|2\|* ]] && ok_t "a \`\`\`json fenced plan is taken" || bad_t "fenced plan taken" "got=$got"

new_job "Ship a wrapped widget"
db "UPDATE tasks SET status='done', result=$(sqlq "Plan follows. $PLAN That is all.") WHERE id=${TASK_ID};" >/dev/null
got=$(job_state)
[[ "$got" == done\|2\|* ]] && ok_t "a plan between two sentences is taken" || bad_t "wrapped plan taken" "got=$got"

[[ -z "$(_goal_extract_plan 'no braces here')" && -z "$(_goal_extract_plan '{not json}')" && -z "$(_goal_extract_plan '[1,2]')" ]] \
  && ok_t "no object, broken JSON or an array yields no plan" \
  || bad_t "extractor refuses non-plans" ""

# ---- (4) the wake line: JSON-by-file for a schema row, unchanged for a plain one ----
new_job "Ship a nudged widget"
nudge=$(_hb_nudge_text dev "$TASK_ID" "$IDENT" 2>/dev/null)
if [[ "$nudge" == *"--result-file=<a file holding ONLY the JSON object this row asks for>"* \
      && "$nudge" != *"1-2 self-contained sentences"* ]]; then
  ok_t "the planner's wake line says --result-file, JSON only, and drops the sentence rule"
else
  bad_t "planner wake line" "$nudge"
fi
plain=$(JSON_MODE=1 cmd_task_add --assignee=dev -- "A plain row" 2>/dev/null | jq -r '.data.id // ""')
pident=$(db "SELECT ident FROM tasks WHERE id=${plain:-0};")
pn=$(_hb_nudge_text dev "$plain" "$pident" 2>/dev/null)
[[ "$pn" == *"DONE — '5dive task done ${pident} --result=\"<1-2 self-contained sentences; the creator and the dashboard read this field>\"' (on a row"* ]] \
  && ok_t "a plain row's wake line is unchanged" \
  || bad_t "plain wake line unchanged" "$pn"

# ---- (5) the planner prompt says how to finish ----
c=$(_goal_build_contract "x" 5)
[[ "$c" == *"--result-file=<that file>"* && "$c" == *"no summary sentence"* ]] \
  && ok_t "the planner prompt says: the JSON to a file, closed with --result-file" \
  || bad_t "planner prompt finish" "$c"

echo
echo "goal planner result-file unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
