#!/usr/bin/env bash
# DIVE-1349 isolated unit harness for ASYNC `5dive goal add` + `goal status`.
#
# Sources src/ directly against a throwaway STATE_DIR (never touches the live
# tasks.db). Proves the async contract that fixes the goals-page 502:
#   * default `goal add` (no --wait/--plan) returns a job id at once WITHOUT
#     blocking on the planner, and materializes NOTHING yet;
#   * `goal status <job>` reports queued/running while the planner task is open;
#   * once the backing planner task lands a plan (simulated: task done + result),
#     `goal status` runs the validate->finish tail and returns done + the plan
#     (dry-run) or materialized tasks (create);
#   * a repeat poll is idempotent (materialize happens exactly once);
#   * a planner that closes without a plan surfaces as status=failed, not a hang.
# Run: bash tests/goal_async_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/goal-async-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_goal.sh cmd_loop.sh cmd_heartbeat.sh; do
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

# A registered planner agent 'dev' so role/assignee resolution + spawn work; keep
# it OUT of the idle probe so the optimistic fast-return never fires (we drive the
# planner completion by hand). _hb_agent_idle returns non-zero for an unknown
# tmux/native state, so leaving 'dev' unbacked keeps the async job pending.
_org_resolve_assignee() { printf '%s' "dev"; }   # stub: any assignee resolves

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
# Run the verb under `set -e` (the installed binary runs with header.sh's set -e;
# the harness itself uses set +e). This makes the test catch the prod-only class
# of bug where an unguarded `$(...)` that exits non-zero silently kills the flow.
run() { ( set -e; "$@" ) 2>/dev/null; }

PLAN_OK='{"project":{"key":"widget","name":"Ship widget","goal":"Ship the widget"},
  "tasks":[
    {"local_id":"t1","title":"Design widget","assignee_or_role":"dev","risk":"low"},
    {"local_id":"t2","title":"Build widget","assignee_or_role":"dev","depends_on":["t1"],
     "acceptance":"tests pass","verify":"npm test","verifier":"qa","risk":"low"}]}'

# ---- (1) async add returns a job id fast, creates nothing ----
out=$(run cmd_goal_add --planner=dev --dry-run -- "Ship a widget"); rc=$?
JOB=$(printf '%s' "$out" | jq -r '.data.job // ""' 2>/dev/null)
STATUS=$(printf '%s' "$out" | jq -r '.data.status // ""' 2>/dev/null)
[[ $rc -eq 0 && -n "$JOB" && ( "$STATUS" == "queued" || "$STATUS" == "running" ) ]] \
  && ok_t "async goal add returns a job id ($STATUS), no block" \
  || bad_t "async goal add returns job id" "rc=$rc out=$out"

TASK_ID=$(db "SELECT task_id FROM goal_jobs WHERE job_id=$(sqlq "$JOB");")
NLEAF=$(db "SELECT COUNT(*) FROM tasks WHERE title NOT LIKE 'Goal:%' AND kind='standard' AND id!=${TASK_ID:-0};")
[[ "${NLEAF:-0}" -eq 0 ]] \
  && ok_t "async add materialized nothing yet (only the planner backing task)" \
  || bad_t "async add creates nothing yet" "leaves=$NLEAF"

# ---- (2) status while the planner task is still open -> queued/running ----
out=$(run cmd_goal_status "$JOB"); st=$(printf '%s' "$out" | jq -r '.data.status // ""')
[[ "$st" == "queued" || "$st" == "running" ]] \
  && ok_t "goal status reports '$st' while planner task open" \
  || bad_t "status reports pending" "out=$out"

# ---- (3) simulate the planner landing the plan: backing task done + result ----
db "UPDATE tasks SET status='done', result=$(sqlq "$PLAN_OK") WHERE id=${TASK_ID};" >/dev/null
out=$(run cmd_goal_status "$JOB"); rc=$?
st=$(printf '%s' "$out" | jq -r '.data.status // ""')
dry=$(printf '%s' "$out" | jq -r '.data.dryRun // false')
tc=$(printf '%s' "$out" | jq -r '.data.taskCount // 0')
[[ $rc -eq 0 && "$st" == "done" && "$dry" == "true" && "$tc" == "2" ]] \
  && ok_t "goal status done -> returns the dry-run plan (2 tasks)" \
  || bad_t "status done returns plan" "rc=$rc out=$out"

# dry-run must still have created nothing
NLEAF=$(db "SELECT COUNT(*) FROM tasks WHERE title NOT LIKE 'Goal:%' AND kind='standard' AND id!=${TASK_ID};")
[[ "${NLEAF:-0}" -eq 0 ]] \
  && ok_t "done dry-run job still created no tasks" \
  || bad_t "dry-run creates nothing" "leaves=$NLEAF"

# ---- (4) a CREATE (non-dry-run) async job materializes exactly once ----
out=$(run cmd_goal_add --planner=dev --project=gizmo -- "Ship a gizmo"); JOB2=$(printf '%s' "$out" | jq -r '.data.job // ""')
TASK2=$(db "SELECT task_id FROM goal_jobs WHERE job_id=$(sqlq "$JOB2");")
PLAN_G='{"project":{"key":"gizmo","name":"Ship gizmo","goal":"Ship the gizmo"},
  "tasks":[{"local_id":"g1","title":"Build gizmo","assignee_or_role":"dev","risk":"low"}]}'
db "UPDATE tasks SET status='done', result=$(sqlq "$PLAN_G") WHERE id=${TASK2};" >/dev/null
out=$(run cmd_goal_status "$JOB2"); st=$(printf '%s' "$out" | jq -r '.data.status // ""'); mat=$(printf '%s' "$out" | jq -r '.data.materialized // false')
[[ "$st" == "done" && "$mat" == "true" ]] \
  && ok_t "create async job materializes on first done poll" \
  || bad_t "create materializes" "out=$out"
BUILT1=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='gizmo' AND title NOT LIKE 'Goal:%' AND kind='standard';")
# poll again — must be idempotent (no second materialize, no error)
out=$(run cmd_goal_status "$JOB2"); rc=$?; st=$(printf '%s' "$out" | jq -r '.data.status // ""')
BUILT2=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='gizmo' AND title NOT LIKE 'Goal:%' AND kind='standard';")
[[ $rc -eq 0 && "$st" == "done" && "$BUILT1" == "$BUILT2" && "${BUILT1:-0}" -ge 1 ]] \
  && ok_t "repeat poll is idempotent (materialize ran exactly once: $BUILT1==$BUILT2)" \
  || bad_t "idempotent repeat poll" "rc=$rc built1=$BUILT1 built2=$BUILT2 out=$out"

# ---- (5) planner closes with no plan -> failed, not a hang ----
out=$(run cmd_goal_add --planner=dev --dry-run -- "Doomed goal"); JOB3=$(printf '%s' "$out" | jq -r '.data.job // ""')
TASK3=$(db "SELECT task_id FROM goal_jobs WHERE job_id=$(sqlq "$JOB3");")
db "UPDATE tasks SET status='escalated', result='' WHERE id=${TASK3};" >/dev/null
out=$(run cmd_goal_status "$JOB3"); st=$(printf '%s' "$out" | jq -r '.data.status // ""')
[[ "$st" == "failed" ]] \
  && ok_t "planner-with-no-plan surfaces as status=failed" \
  || bad_t "no-plan -> failed" "out=$out"

# ---- (5b) create-from-preview: --from-job materializes the previewed plan ----
out=$(run cmd_goal_add --planner=dev --project=widgetjob --dry-run -- "Preview then create"); JOB4=$(printf '%s' "$out" | jq -r '.data.job // ""')
TASK4=$(db "SELECT task_id FROM goal_jobs WHERE job_id=$(sqlq "$JOB4");")
PLAN_W='{"project":{"key":"widgetjob","name":"Widget job","goal":"Ship the widget job"},
  "tasks":[{"local_id":"w1","title":"Do the widget","assignee_or_role":"dev","risk":"low"}]}'
db "UPDATE tasks SET status='done', result=$(sqlq "$PLAN_W") WHERE id=${TASK4};" >/dev/null
# preview (dry-run) created nothing
PRE=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='widgetjob' AND title NOT LIKE 'Goal:%' AND kind='standard';")
out=$(run cmd_goal_add --from-job="$JOB4"); rc=$?
mat=$(printf '%s' "$out" | jq -r '.data.materialized // false')
POST=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='widgetjob' AND title NOT LIKE 'Goal:%' AND kind='standard';")
[[ $rc -eq 0 && "$mat" == "true" && "${PRE:-0}" -eq 0 && "${POST:-0}" -ge 1 ]] \
  && ok_t "--from-job materializes the previewed plan (pre=$PRE post=$POST)" \
  || bad_t "--from-job materializes" "rc=$rc pre=$PRE post=$POST out=$out"

# --from-job before the plan is ready is a clean error, not a materialize
out=$(run cmd_goal_add --planner=dev --dry-run -- "Not ready yet"); JOB5=$(printf '%s' "$out" | jq -r '.data.job // ""')
out=$(run cmd_goal_add --from-job="$JOB5"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -qi "no plan yet" \
  && ok_t "--from-job before plan ready rejected cleanly" \
  || bad_t "--from-job not-ready rejected" "rc=$rc out=$out"

# ---- (6) unknown job id is a clean error ----
out=$(run cmd_goal_status "L-does-not-exist"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -qi "no goal job" \
  && ok_t "unknown job id rejected cleanly" \
  || bad_t "unknown job id rejected" "rc=$rc out=$out"

# ---- (7) planner drift: project.title/description aliased to name/goal ----
DRIFT='{"project":{"key":"drift","title":"Drifted title","description":"Drifted goal"},
  "tasks":[{"local_id":"d1","title":"Do it","assignee_or_role":"dev","risk":"low"}]}'
out=$(run cmd_goal_add --plan="$DRIFT" --dry-run -- "Some outcome"); rc=$?
nm=$(printf '%s' "$out" | jq -r '.data.plan.project.name // ""' 2>/dev/null)
gl=$(printf '%s' "$out" | jq -r '.data.plan.project.goal // ""' 2>/dev/null)
[[ $rc -eq 0 && "$nm" == "Drifted title" && "$gl" == "Drifted goal" ]] \
  && ok_t "planner title/description aliased to name/goal (no false reject)" \
  || bad_t "planner drift normalized" "rc=$rc name=$nm goal=$gl out=$out"

# a plan already carrying name/goal is untouched by normalization
out=$(run cmd_goal_add --plan="$PLAN_OK" --dry-run -- "x"); rc=$?
nm=$(printf '%s' "$out" | jq -r '.data.plan.project.name // ""' 2>/dev/null)
[[ $rc -eq 0 && "$nm" == "Ship widget" ]] \
  && ok_t "well-formed plan name/goal left intact" \
  || bad_t "well-formed plan untouched" "rc=$rc name=$nm"

echo
echo "goal async unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
