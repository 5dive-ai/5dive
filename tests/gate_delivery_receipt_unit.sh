#!/usr/bin/env bash
# DIVE-1490: Bot API receipts, loud failure logging, and visible group fallback.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/gate-delivery.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_agent_runtime.sh cmd_task.sh; do
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
# DIVE-1506: this harness deliberately exercises the human-send path, so declare its
# isolated DB as the prod DB (positive allowlist) to pass the fail-closed fixture guard.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"
ACCESS="$TMP/access.json"
printf '%s\n' '{"allowFrom":["999"],"groups":{"-1001":{"message_thread_id":42}}}' >"$ACCESS"
TASK_CH_TOKEN=x TASK_CH_ACCESS="$ACCESS" TASK_CH_TYPE=claude

SEND_LOG="$TMP/sends"; : >"$SEND_LOG"
FAIL_GROUP=0
TRANSPORT_FAIL=0
MISSING_MESSAGE_ID=0
_mirror_send() {
  local chat="$2" markup="${5:-}"
  printf '%s|%s\n' "$chat" "$([[ -n "$markup" ]] && echo buttons || echo plain)" >>"$SEND_LOG"
  if [[ "$TRANSPORT_FAIL" == "1" ]]; then
    return 7
  fi
  if [[ "$MISSING_MESSAGE_ID" == "1" ]]; then
    printf '%s' '{"ok":true,"result":{}}'
    return 0
  fi
  if [[ "$chat" == "-1001" && "$FAIL_GROUP" == "0" ]]; then
    printf '%s' '{"ok":true,"result":{"message_id":777}}'
  else
    printf '%s' '{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}'
  fi
}
_mirror_log_button_reject() { :; }
_mirror_follow_migration() { :; }
audit_log() { :; }

PASS=0; FAIL=0
ok_t() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
mk_gate() {
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,need_type,tier,ask,need_asked_at)
      VALUES ($(sqlq "$1"),'gate','high','codex','codex','standard','blocked','decision',2,'pick',datetime('now'));
      SELECT last_insert_rowid();"
}
pinged() { db "SELECT CASE WHEN gate_pinged_at IS NULL THEN 'NULL' ELSE 'SET' END FROM tasks WHERE id=$1;"; }

gid=$(mk_gate DIVE-1)
_task_send_owner "needs you" '{"inline_keyboard":[[{"text":"A","callback_data":"tna:1:0"}]]}' "$gid" 2>"$TMP/err"
err=$(<"$TMP/err")
[[ "$TASK_SEND_DELIVERED" == "1" && "$(pinged "$gid")" == "SET" ]] \
  && ok_t "bad DM falls back to group and stamps confirmed delivery" \
  || bad_t "fallback receipt/stamp" "delivered=$TASK_SEND_DELIVERED pinged=$(pinged "$gid")"
grep -q '^999|buttons$' "$SEND_LOG" && grep -q '^-1001|buttons$' "$SEND_LOG" \
  && ok_t "kill-test attempted bad chat then visible group with buttons" \
  || bad_t "expected DM and group attempts" "$(tr '\n' ',' <"$SEND_LOG")"
grep -q 'result=error.*DIVE-1.*chat=999' "$FIVEDIVE_GATE_NOTIFY_LOG" \
  && grep -q 'result=ok.*DIVE-1.*message_id=777' "$FIVEDIVE_GATE_NOTIFY_LOG" \
  && ok_t "failure and confirmed message_id are recorded against the task" \
  || bad_t "delivery event log incomplete" "$(tr '\n' ' ' <"$FIVEDIVE_GATE_NOTIFY_LOG")"
grep -q 'delivery FAILED' <<<"$err" \
  && ok_t "Bot API rejection emits a loud warning" \
  || bad_t "missing loud warning" "$err"

: >"$SEND_LOG"; FAIL_GROUP=1
gid2=$(mk_gate DIVE-2)
_task_send_owner "needs you" '{"inline_keyboard":[[{"text":"A","callback_data":"tna:2:0"}]]}' "$gid2" >/dev/null 2>&1
[[ "$TASK_SEND_DELIVERED" == "0" && "$(pinged "$gid2")" == "NULL" ]] \
  && ok_t "total failure leaves receipt NULL for retry" \
  || bad_t "failed send must not stamp" "delivered=$TASK_SEND_DELIVERED pinged=$(pinged "$gid2")"

: >"$SEND_LOG"; FAIL_GROUP=0; TRANSPORT_FAIL=1
gid3=$(mk_gate DIVE-3)
set -e
_task_send_owner "needs you" "" "$gid3" >/dev/null 2>&1
set +e
[[ "$TASK_SEND_DELIVERED" == "0" && "$(pinged "$gid3")" == "NULL" ]] \
  && ok_t "curl transport failure is handled as an unconfirmed receipt" \
  || bad_t "transport failure escaped receipt handling" "delivered=$TASK_SEND_DELIVERED pinged=$(pinged "$gid3")"

: >"$SEND_LOG"; TRANSPORT_FAIL=0; MISSING_MESSAGE_ID=1
gid4=$(mk_gate DIVE-4)
_task_send_owner "needs you" "" "$gid4" >/dev/null 2>&1
[[ "$TASK_SEND_DELIVERED" == "0" && "$(pinged "$gid4")" == "NULL" ]] \
  && ok_t "ok:true without message_id is not accepted as delivery" \
  || bad_t "malformed success stamped delivery" "delivered=$TASK_SEND_DELIVERED pinged=$(pinged "$gid4")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
