#!/usr/bin/env bash
# STEER-1 unit harness for the idle-watchdog "pipeline dammed" sweep.
#
# Simulates an all-blocked queue (0 actionable + open human gate) and asserts:
#   (1) actionable work present -> NO push (not dammed)
#   (2) 0 actionable + >=1 open gate -> ONE push, leading with each gate's rec
#   (3) condition persists -> NO second push (one per episode / anti-spam)
#   (4) every gate answered -> episode marker self-clears
#   (5) a fresh dam after a clear -> alarms ONCE again
# Send path (_task_send_owner) is stubbed to capture text; no root/network/tmux.
# Run: bash tests/heartbeat_dam_sweep_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."

TMPD=$(mktemp -d /tmp/dam-sweep-test.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT
SRC=src
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_agent_runtime.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e

# Point the db helper at our temp store AFTER sourcing (a lib resets STATE_DIR
# to the live /var/lib/5dive at source time; never let that leak into the test).
STATE_DIR="$TMPD"; TASKS_DIR="${TMPD}/tasks"; TASKS_DB="${TASKS_DIR}/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init >/dev/null 2>&1

# --- stubs: capture the human push instead of hitting Telegram ---------------
PUSH_TEXT=""; PUSH_COUNT=0
_task_resolve_coordinator() { echo "main"; }
_task_agent_channel() { TASK_CH_TOKEN="x" TASK_CH_ACCESS="/dev/null" TASK_CH_TYPE="claude"; return 0; }
_task_send_owner() { PUSH_TEXT="$1"; PUSH_COUNT=$((PUSH_COUNT+1)); return 0; }
run_sweep() { PUSH_TEXT=""; _hb_dam_sweep; }
marker() { db "SELECT COALESCE(value,'') FROM task_prefs WHERE key='dam_alerted_at';" 2>/dev/null; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- (1) actionable work present -> not dammed -------------------------------
db "INSERT INTO tasks (ident,title,status,kind,assignee,created_by) VALUES ('T-ACT','busy','in_progress','standard','dev','dev');"
db "INSERT INTO tasks (ident,title,status,kind,assignee,created_by,need_type,ask,recommend,tier)
    VALUES ('G-1','gate one','blocked','standard','dev','dev','decision','Ship the beta to prod?','ship',1);"
PUSH_COUNT=0; run_sweep
(( PUSH_COUNT == 0 )) && ok_t "(1) actionable work present -> no dam push" || bad_t "(1) pushed while actionable work existed"
[[ -z "$(marker)" ]] && ok_t "(1) no episode marker while actionable" || bad_t "(1) marker set while actionable"

# --- (2) drain the actionable work -> ONE dam push, leads with rec -----------
db "UPDATE tasks SET status='done' WHERE ident='T-ACT';"
PUSH_COUNT=0; run_sweep
(( PUSH_COUNT == 1 )) && ok_t "(2) 0 actionable + open gate -> exactly one push" || bad_t "(2) push count=$PUSH_COUNT (want 1)"
grep -q "Pipeline dammed" <<<"$PUSH_TEXT" && ok_t "(2) alert says 'Pipeline dammed'" || bad_t "(2) missing headline" "$PUSH_TEXT"
grep -q "G-1" <<<"$PUSH_TEXT" && ok_t "(2) alert enumerates the blocking gate" || bad_t "(2) gate not listed" "$PUSH_TEXT"
grep -q "rec: ship" <<<"$PUSH_TEXT" && ok_t "(2) alert leads with the recommended answer" || bad_t "(2) rec not surfaced" "$PUSH_TEXT"
[[ -n "$(marker)" ]] && ok_t "(2) episode marker set after alert" || bad_t "(2) marker not set"

# --- (3) still dammed -> NO second push (one per episode) ---------------------
PUSH_COUNT=0; run_sweep
(( PUSH_COUNT == 0 )) && ok_t "(3) standing dam -> no duplicate push (anti-spam)" || bad_t "(3) re-pushed same episode"

# --- (4) answer every gate -> marker self-clears ------------------------------
db "UPDATE tasks SET need_answered_at=datetime('now'), status='done' WHERE ident='G-1';"
PUSH_COUNT=0; run_sweep
(( PUSH_COUNT == 0 )) && ok_t "(4) no gates open -> no push" || bad_t "(4) pushed with zero open gates"
[[ -z "$(marker)" ]] && ok_t "(4) episode marker self-cleared once un-dammed" || bad_t "(4) marker lingered after clear"

# --- (5) a fresh dam after clearing -> alarms once again ----------------------
db "INSERT INTO tasks (ident,title,status,kind,assignee,created_by,need_type,ask,recommend,tier)
    VALUES ('G-2','gate two','blocked','standard','dev','dev','approval','Approve the refund?','approve',2);"
PUSH_COUNT=0; run_sweep
(( PUSH_COUNT == 1 )) && ok_t "(5) fresh dam episode alarms once again" || bad_t "(5) push count=$PUSH_COUNT (want 1)"
grep -q "G-2" <<<"$PUSH_TEXT" && ok_t "(5) new gate enumerated" || bad_t "(5) new gate missing" "$PUSH_TEXT"

echo "----"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
