#!/usr/bin/env bash
# DIVE-1737 isolated unit harness for the async self-heal materialize sweep
# (_hb_objective_reconcile in cmd_heartbeat.sh) + the replan 'awaiting_planner'
# handoff. Asserts:
#   - a planner loop that times out (stubbed) records an 'awaiting_planner' cycle
#     stamped with the backing loop/task ids (no hard E_TIMEOUT, nothing dropped)
#   - reconciler + backing task done w/ a JSON diff -> materializes via the
#     existing replan --diff path, marker consumed, real cycle recorded at the
#     SAME cycle_no (no double-increment)
#   - backing task done w/ PROSE (human ACK) -> planner_failed, no auto-apply
#   - backing task still in_progress -> left pending (idempotent, no change)
#   - backing task cancelled -> planner_failed
# Run: bash tests/objective_reconcile_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/obj-reconcile-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_goal.sh \
         cmd_loop.sh cmd_objective.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

# stub outbound comms so the reconciler's escalation never needs a real channel
cmd_send() { return 0; }
# quiet the sweep's stderr logger
_hb_log() { :; }

tasks_db_init
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
objid() { db "SELECT id FROM objectives WHERE name=$(sqlq "$1");"; }

# --- schema: the additive planner-handle columns exist
cols=$(db "SELECT name FROM pragma_table_info('objective_cycles');")
{ printf '%s\n' "$cols" | grep -qx planner_loop_id && printf '%s\n' "$cols" | grep -qx planner_task_id; } \
  && ok_t "objective_cycles has planner_loop_id + planner_task_id" \
  || bad_t "schema" "cols=$cols"

( cmd_objective_add "steer-x" --metric-cmd="echo 0" --target=100 --direction=up --planner=alice --max-new-per-cycle=2 ) >/dev/null 2>&1
OID=$(objid "steer-x")
[[ -n "$OID" ]] && ok_t "objective created (id=$OID)" || bad_t "setup" "no objective"

# --- the replan handoff: a timed-out planner loop records awaiting_planner ---
# Stub cmd_loop_spawn to emit a TIMEOUT/escalated spawn result (loopId+taskId set).
cmd_loop_spawn() {
  # create a real backing task so the recorded task id resolves
  local aj; aj=$(JSON_MODE=1 cmd_task_add --assignee=alice --body="planner contract" -- "loop:worker — planner" 2>/dev/null)
  local tid; tid=$(printf '%s' "$aj" | jq -r '.data.id')
  printf '{"ok":true,"data":{"loopId":"L-STUB1","status":"escalated","taskId":%s,"taskIdent":"X","tokensSpent":123,"result":""}}' "$tid"
}
( JSON_MODE=1 cmd_objective_replan "steer-x" --force ) >/dev/null 2>"$TMP/err"
aw=$(db "SELECT COUNT(*) FROM objective_cycles WHERE objective_id=$OID AND outcome='awaiting_planner';")
awtid=$(db "SELECT COALESCE(planner_task_id,'') FROM objective_cycles WHERE objective_id=$OID AND outcome='awaiting_planner' LIMIT 1;")
awlid=$(db "SELECT COALESCE(planner_loop_id,'') FROM objective_cycles WHERE objective_id=$OID AND outcome='awaiting_planner' LIMIT 1;")
{ [[ "$aw" == "1" && -n "$awtid" && "$awlid" == "L-STUB1" ]]; } \
  && ok_t "planner timeout -> awaiting_planner cycle stamped (task=$awtid loop=$awlid)" \
  || bad_t "awaiting recording" "count=$aw tid=$awtid lid=$awlid err=$(cat "$TMP/err")"

# --- reconciler: backing task done with a JSON diff -> materialize ---
CYC=$(db "SELECT cycle_no FROM objective_cycles WHERE objective_id=$OID AND outcome='awaiting_planner' LIMIT 1;")
DIFF='{"create":[{"local_id":"t1","title":"ship an attribution smoke","assignee_or_role":"alice","risk":"low"}]}'
db "UPDATE tasks SET status='done', result=$(sqlq "$DIFF") WHERE id=${awtid};"
_hb_objective_reconcile
still_aw=$(db "SELECT COUNT(*) FROM objective_cycles WHERE objective_id=$OID AND outcome='awaiting_planner';")
gate_row=$(db "SELECT COUNT(*) FROM objective_cycles WHERE objective_id=$OID AND cycle_no=$CYC AND outcome IN ('gated','applied');")
same_cyc=$(db "SELECT COUNT(*) FROM objective_cycles WHERE objective_id=$OID AND cycle_no=$CYC;")
{ [[ "$still_aw" == "0" && "$gate_row" == "1" && "$same_cyc" == "1" ]]; } \
  && ok_t "reconcile JSON diff -> materialized at SAME cycle #$CYC, marker consumed (no double-count)" \
  || bad_t "reconcile-materialize" "still_aw=$still_aw gate_row=$gate_row same_cyc=$same_cyc"

# --- reconciler: prose close -> planner_failed, nothing applied ---
db "INSERT INTO objective_cycles (objective_id,cycle_no,proposed,gated,tokens_spent,outcome,planner_loop_id,planner_task_id)
    VALUES ($OID, 90, 0,0,0,'awaiting_planner','L-PROSE', NULL);"
pj=$(JSON_MODE=1 cmd_task_add --assignee=alice --body="x" -- "loop:worker prose" 2>/dev/null); ptid=$(printf '%s' "$pj" | jq -r '.data.id')
db "UPDATE objective_cycles SET planner_task_id=${ptid} WHERE objective_id=$OID AND cycle_no=90;"
db "UPDATE tasks SET status='done', result='ACK verified-sound, plan is correct.' WHERE id=${ptid};"
_hb_objective_reconcile
pf=$(db "SELECT outcome FROM objective_cycles WHERE objective_id=$OID AND cycle_no=90;")
[[ "$pf" == "planner_failed" ]] && ok_t "prose close -> planner_failed (no guess-apply)" || bad_t "prose" "outcome=$pf"

# --- reconciler: still in_progress -> left pending (idempotent) ---
db "INSERT INTO objective_cycles (objective_id,cycle_no,proposed,gated,tokens_spent,outcome,planner_loop_id,planner_task_id)
    VALUES ($OID, 91, 0,0,0,'awaiting_planner','L-INPROG', NULL);"
ij=$(JSON_MODE=1 cmd_task_add --assignee=alice --body="x" -- "loop:worker inprog" 2>/dev/null); itid=$(printf '%s' "$ij" | jq -r '.data.id')
db "UPDATE objective_cycles SET planner_task_id=${itid} WHERE objective_id=$OID AND cycle_no=91;"
db "UPDATE tasks SET status='in_progress' WHERE id=${itid};"
_hb_objective_reconcile
ip=$(db "SELECT outcome FROM objective_cycles WHERE objective_id=$OID AND cycle_no=91;")
[[ "$ip" == "awaiting_planner" ]] && ok_t "in_progress planner -> left pending (idempotent)" || bad_t "pending" "outcome=$ip"

# --- reconciler: cancelled backing task -> planner_failed ---
db "INSERT INTO objective_cycles (objective_id,cycle_no,proposed,gated,tokens_spent,outcome,planner_loop_id,planner_task_id)
    VALUES ($OID, 92, 0,0,0,'awaiting_planner','L-CANC', NULL);"
cj=$(JSON_MODE=1 cmd_task_add --assignee=alice --body="x" -- "loop:worker canc" 2>/dev/null); ctid=$(printf '%s' "$cj" | jq -r '.data.id')
db "UPDATE objective_cycles SET planner_task_id=${ctid} WHERE objective_id=$OID AND cycle_no=92;"
db "UPDATE tasks SET status='cancelled' WHERE id=${ctid};"
_hb_objective_reconcile
cx=$(db "SELECT outcome FROM objective_cycles WHERE objective_id=$OID AND cycle_no=92;")
[[ "$cx" == "planner_failed" ]] && ok_t "cancelled planner task -> planner_failed" || bad_t "cancelled" "outcome=$cx"

printf 'objective_reconcile_unit: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
