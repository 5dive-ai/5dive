#!/usr/bin/env bash
# DIVE-1499: `task inbox --send` — owner digest with working per-gate tap
# buttons, nonce never on stdout, hash rotation only after confirmed delivery.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/inbox-send.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate

ACCESS="$TMP/access.json"
printf '{"allowFrom":["433634012"]}' >"$ACCESS"

SEND_LOG="$TMP/sends"; : >"$SEND_LOG"
LAST_TEXT="$TMP/text"; LAST_MARKUP="$TMP/markup"
FAIL_SEND=0
_task_owner_channel() {
  TASK_CH_TYPE=claude TASK_CH_TOKEN=x TASK_CH_ACCESS="$ACCESS"
  return 0
}
_task_send_owner() {
  local text="$1" markup="$2" ids="$3"
  printf '%s\n' "$ids" >>"$SEND_LOG"
  printf '%s' "$text" >"$LAST_TEXT"; printf '%s' "$markup" >"$LAST_MARKUP"
  TASK_SEND_MESSAGE_IDS="901"
  if [[ "$FAIL_SEND" == "1" ]]; then TASK_SEND_DELIVERED=0; return 0; fi
  TASK_SEND_DELIVERED=1
}
require_root() { :; }
audit_log() { :; }

PASS=0; FAIL=0
ok_t() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
nsends() { grep -c . "$SEND_LOG"; }
reset() { db "DELETE FROM tasks;"; : >"$SEND_LOG"; : >"$LAST_TEXT"; : >"$LAST_MARKUP"; FAIL_SEND=0; }
mk_gate() { # ident type options recommend
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,need_type,tier,ask,need_options,recommend,need_asked_at)
      VALUES ($(sqlq "$1"),'gate','high','dev','dev','standard','blocked',$(sqlq "$2"),2,'choose now',$(sqlq "$3"),$(sqlq "$4"),datetime('now'));
      SELECT last_insert_rowid();"
}

# Empty inbox: reports cleanly, sends nothing.
reset
out=$(cmd_task_inbox --send 2>&1); rc=$?
[[ "$rc" == "0" && "$(nsends)" == "0" && "$out" == *"nothing to send"* ]] \
  && ok_t "empty inbox sends nothing" || bad_t "empty inbox misbehaved" "rc=$rc out=$out"

# Mixed gate types: ONE message, working buttons for all three, nonce hashes
# stored, and the raw nonce NEVER on stdout.
reset
g1=$(mk_gate DIVE-21 decision 'A|B' A)
g2=$(mk_gate DIVE-22 approval '' approved)
g3=$(mk_gate DIVE-23 manual '' '')
out=$(cmd_task_inbox --send --channel-proof=433634012 2>&1); rc=$?
approval_cb=$(jq -r --arg p "tna:${g2}:approved:" '[.inline_keyboard[][] | .callback_data | select(startswith($p))][0] // empty' "$LAST_MARKUP")
approval_nonce=${approval_cb##*:}
manual_cb=$(jq -r --arg p "tna:${g3}:done:" '[.inline_keyboard[][] | .callback_data | select(startswith($p))][0] // empty' "$LAST_MARKUP")
manual_nonce=${manual_cb##*:}
h2=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${g2};")
h3=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${g3};")
grep -q "tna:${g1}:0" "$LAST_MARKUP"; has_d=$?
[[ "$rc" == "0" && "$(nsends)" == "1" && "$has_d" == "0" \
   && -n "$approval_nonce" && "$h2" == "$(_human_nonce_sha "$approval_nonce")" \
   && -n "$manual_nonce"   && "$h3" == "$(_human_nonce_sha "$manual_nonce")" ]] \
  && ok_t "one digest, working decision+approval+manual buttons, hashes stored" \
  || bad_t "digest buttons invalid" "rc=$rc sends=$(nsends) d=$has_d a=$approval_cb m=$manual_cb"
grep -q "DIVE-21" "$LAST_TEXT" && grep -q "DIVE-22" "$LAST_TEXT" && grep -q "DIVE-23" "$LAST_TEXT" \
  && ok_t "digest text lists every gate" || bad_t "digest text missing a gate"
if [[ -n "$approval_nonce" && "$out" != *"$approval_nonce"* && "$out" != *"$manual_nonce"* ]]; then
  ok_t "raw nonce never printed to stdout"
else
  bad_t "nonce leaked to stdout" "out=$out"
fi

# Unconfirmed delivery: command fails, hashes NOT rotated.
reset
g4=$(mk_gate DIVE-24 approval '' '')
FAIL_SEND=1
out=$(cmd_task_inbox --send 2>&1); rc=$?
h4=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${g4};")
[[ "$rc" != "0" && -z "$h4" ]] \
  && ok_t "unconfirmed delivery fails and leaves hash unrotated" \
  || bad_t "fail-closed path broken" "rc=$rc hash=$h4"

# Bad channel-proof: refused before any send.
reset
mk_gate DIVE-25 decision 'A|B' A >/dev/null
out=$(cmd_task_inbox --send --channel-proof=999 2>&1); rc=$?
[[ "$rc" != "0" && "$(nsends)" == "0" ]] \
  && ok_t "unallowlisted channel-proof refused" || bad_t "bad proof accepted" "rc=$rc out=$out"

# Cap: 12 gates -> 10 sent, overflow noted.
reset
for i in $(seq 31 42); do mk_gate "DIVE-${i}" decision 'A|B' A >/dev/null; done
out=$(cmd_task_inbox --send 2>&1); rc=$?
sent_ids=$(tail -1 "$SEND_LOG")
n_ids=$(awk -F, '{print NF}' <<<"$sent_ids")
grep -q "and 2 more" "$LAST_TEXT"; has_more=$?
[[ "$rc" == "0" && "$n_ids" == "10" && "$has_more" == "0" ]] \
  && ok_t "digest caps at 10 gates and notes the overflow" \
  || bad_t "cap broken" "rc=$rc n_ids=$n_ids more=$has_more"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
