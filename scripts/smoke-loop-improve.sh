#!/usr/bin/env bash
# DIVE-8692 LIVE smoke for self-improving loops: the DEFAULT model path (a real
# headless `claude --print` on this seat, no stub) against a real recurring loop
# in a throwaway STATE_DIR. Costs one or two small model calls (~1-3 cents).
# Not part of CI (needs a signed-in claude). Run: bash scripts/smoke-loop-improve.sh. Lives in scripts/, not tests/, so CI never runs it.
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "SMOKE-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/loop-improve-smoke.XXXXXX)"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=1
mkdir -p "$TASKS_DIR"; cmd_send() { :; }
set +e
unset FIVEDIVE_LOOP_IMPROVE_AI; export FIVEDIVE_LOOP_IMPROVE_SYNC=1
tasks_db_init
out=$(JSON_MODE=1 cmd_task_add "Morning weather note" --recurring="0 7 * * *" --assignee=dev \
      --body="Write a one-line weather note for Berlin." 2>&1)
L=$(jq -r .data.ident <<<"$out"); echo "loop: $L"
cmd_task_loop_improve "$L" on | jq -c .data
mk_run() { db "INSERT INTO tasks (title, body, assignee, created_by, kind, from_template_id, status)
               SELECT title, body, assignee, created_by, 'standard', id, 'in_progress' FROM tasks WHERE ident='$L';
               SELECT ident FROM tasks WHERE id=last_insert_rowid();"; }
R1=$(mk_run)
( AGENT_NAME=dev cmd_task_done "$R1" --result="Berlin: cloudy." ) >/dev/null 2>&1
echo "--- after run 1 ($R1)"; JSON_MODE=0 cmd_task_loop_improve "$L" log
echo "--- template text now:"; db "SELECT body FROM tasks WHERE ident='$L';"
R2=$(mk_run)
( AGENT_NAME=dev cmd_task_done "$R2" --result="Berlin today: 8C, cloudy, light rain after 15:00, take an umbrella. Source: DWD forecast at 06:30." ) >/dev/null 2>&1
echo "--- after run 2 ($R2)"; JSON_MODE=0 cmd_task_loop_improve "$L" log
cmd_task_loop_improve "$L" log --json | jq -c '.data | {improved, score_start, score_now, entries:[.entries[]|{id,status,kept,change,score_before,score_after,cost_usd}], runs}'
JSON_MODE=1 cmd_task_ls --recurring | jq -c ".data.tasks[]|select(.ident==\"$L\")|{ident,self_improving,score}"
n=$(cmd_task_loop_improve "$L" log --json | jq '.data.runs | length')
[[ "$n" == "2" ]] && echo "SMOKE: both runs graded by the real model" || { echo "SMOKE: FAIL, $n runs graded"; exit 1; }
