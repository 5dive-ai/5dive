#!/usr/bin/env bash
# DIVE-1490: +1h then 24h receipt-backed, button-bearing batched gate re-nags.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/gate-renag.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_agent.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
db "INSERT INTO agents_org (name,reports_to,role) VALUES ('main',NULL,'coordinator'),('dev','main',NULL);"

SEND_LOG="$TMP/sends"; : >"$SEND_LOG"
CHANNEL_LOG="$TMP/channels"; : >"$CHANNEL_LOG"
ALERT_LOG="$TMP/alerts"; : >"$ALERT_LOG"
LAST_TEXT="$TMP/text"; LAST_MARKUP="$TMP/markup"
FAIL_SEND=0
_task_agent_channel() {
  printf '%s\n' "$1" >>"$CHANNEL_LOG"
  TASK_CH_TYPE=claude TASK_CH_TOKEN=x TASK_CH_ACCESS=/dev/null
  return 0
}
_task_send_owner() {
  local text="$1" markup="$2" ids="$3"
  printf '%s\n' "$ids" >>"$SEND_LOG"
  printf '%s' "$text" >"$LAST_TEXT"; printf '%s' "$markup" >"$LAST_MARKUP"
  TASK_SEND_MESSAGE_IDS="901"
  if [[ "$FAIL_SEND" == "1" ]]; then
    TASK_SEND_DELIVERED=0
    _task_stamp_confirmed_delivery "$ids"
    return 0
  fi
  TASK_SEND_DELIVERED=1
  _task_stamp_confirmed_delivery "$ids"
}
cmd_send() { printf '%s|%s\n' "$1" "$*" >>"$ALERT_LOG"; }
audit_log() { :; }
_hb_log() { :; }

PASS=0; FAIL=0
ok_t() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
nsends() { grep -c . "$SEND_LOG"; }
pinged() { db "SELECT CASE WHEN gate_pinged_at IS NULL THEN 'NULL' ELSE 'SET' END FROM tasks WHERE id=$1;"; }
failures() { db "SELECT COALESCE(gate_delivery_failures,0) FROM tasks WHERE id=$1;"; }
attempted() { db "SELECT COALESCE(gate_last_attempt_at,'') FROM tasks WHERE id=$1;"; }
alarmed() { db "SELECT COALESCE(gate_delivery_alarm_at,'') FROM tasks WHERE id=$1;"; }
reset() { db "DELETE FROM tasks;"; : >"$SEND_LOG"; : >"$CHANNEL_LOG"; : >"$ALERT_LOG"; : >"$LAST_TEXT"; : >"$LAST_MARKUP"; FAIL_SEND=0; }
mk_gate() { # ident tier type asked_modifier ping_modifier options recommend routed
  local ping="NULL"; [[ "$5" != "NULL" ]] && ping="datetime('now','$5')"
  local routed="NULL"; [[ -n "${8:-}" ]] && routed="$(sqlq "$8")"
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,need_type,tier,ask,need_options,recommend,need_asked_at,gate_pinged_at,routed_reviewer)
      VALUES ($(sqlq "$1"),'gate','high','dev','dev','standard','blocked',$(sqlq "$3"),$2,'choose now',$(sqlq "$6"),$(sqlq "$7"),datetime('now','$4'),${ping},${routed});
      SELECT last_insert_rowid();"
}

# Before one hour: never re-ping.
reset
early=$(mk_gate DIVE-10 2 decision '-30 minutes' '-29 minutes' 'A|B' A '')
_hb_gate_renag_sweep
[[ "$(nsends)" == "0" && "$(pinged "$early")" == "SET" ]] \
  && ok_t "no re-ping before +1h" || bad_t "early gate was re-pinged" "sends=$(nsends)"

# Two gates past +1h collapse into ONE message with working button rows.
reset
g1=$(mk_gate DIVE-11 2 decision '-2 hours' '-119 minutes' 'A|B' A '')
g2=$(mk_gate DIVE-12 2 approval '-2 hours' '-119 minutes' '' approved '')
_hb_gate_renag_sweep
rows=$(jq '.inline_keyboard | length' "$LAST_MARKUP" 2>/dev/null)
grep -q "tna:${g1}:0" "$LAST_MARKUP"; has_d=$?
approval_cb=$(jq -r --arg p "tna:${g2}:approved:" '[.inline_keyboard[][] | .callback_data | select(startswith($p))][0] // empty' "$LAST_MARKUP")
approval_nonce=${approval_cb##*:}
stored=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${g2};")
[[ "$(nsends)" == "1" && "$rows" -ge 2 && "$has_d" == "0" && -n "$approval_nonce" && "$stored" == "$(_human_nonce_sha "$approval_nonce")" ]] \
  && ok_t "two +1h gates -> ONE batch with valid per-gate tap buttons" \
  || bad_t "batched buttons invalid" "sends=$(nsends) rows=$rows decision=$has_d approval=$approval_cb"
[[ "$(pinged "$g1")" == "SET" && "$(pinged "$g2")" == "SET" ]] \
  && ok_t "confirmed batch stamps both delivery receipts" || bad_t "batch receipt missing"

# Immediate second tick is idempotent; then a 24h-old reminder stamp re-arms.
: >"$SEND_LOG"
_hb_gate_renag_sweep
[[ "$(nsends)" == "0" ]] && ok_t "no duplicate before 24h" || bad_t "immediate duplicate" "sends=$(nsends)"
db "UPDATE tasks SET need_asked_at=datetime('now','-3 days'), gate_pinged_at=datetime('now','-25 hours');"
_hb_gate_renag_sweep
[[ "$(nsends)" == "1" ]] && ok_t "subsequent reminder fires after 24h" || bad_t "24h reminder missing" "sends=$(nsends)"

# T1 reminder resolves to the org lead's channel.
reset
t1=$(mk_gate DIVE-13 1 decision '-2 hours' '-119 minutes' 'yes|no' yes main)
_hb_gate_renag_sweep
[[ "$(nsends)" == "1" && "$(tail -1 "$CHANNEL_LOG")" == "main" && "$(pinged "$t1")" == "SET" ]] \
  && ok_t "T1 re-nag routes to org lead" \
  || bad_t "T1 route wrong" "sends=$(nsends) channels=$(tr '\n' ',' <"$CHANNEL_LOG")"

# An unconfirmed transport never advances the throttle or rotates the nonce.
reset
bad=$(mk_gate DIVE-14 2 approval '-2 hours' NULL '' approved '')
oldhash=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${bad};")
FAIL_SEND=1 _hb_gate_renag_sweep
newhash=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${bad};")
[[ "$(pinged "$bad")" == "NULL" && "$newhash" == "$oldhash" && "$(failures "$bad")" == "1" && -n "$(attempted "$bad")" ]] \
  && ok_t "failed re-nag leaves receipt/nonce unchanged and records attempt" \
  || bad_t "failed re-nag mutated delivery state" "pinged=$(pinged "$bad") failures=$(failures "$bad") old=$oldhash new=$newhash"

# The next tick is quiet. Failed retries then back off 1h, 2h, 4h, 8h and cap.
: >"$SEND_LOG"
FAIL_SEND=1 _hb_gate_renag_sweep
[[ "$(nsends)" == "0" && "$(failures "$bad")" == "1" ]] \
  && ok_t "unconfirmed delivery is throttled on the next heartbeat" \
  || bad_t "immediate failure retry was not throttled" "sends=$(nsends) failures=$(failures "$bad")"

db "UPDATE tasks SET gate_last_attempt_at=datetime('now','-61 minutes') WHERE id=${bad};"
FAIL_SEND=1 _hb_gate_renag_sweep
[[ "$(nsends)" == "1" && "$(failures "$bad")" == "2" ]] \
  && ok_t "first unconfirmed retry waits one hour" \
  || bad_t "one-hour retry missing" "sends=$(nsends) failures=$(failures "$bad")"

: >"$SEND_LOG"
db "UPDATE tasks SET gate_last_attempt_at=datetime('now','-119 minutes') WHERE id=${bad};"
FAIL_SEND=1 _hb_gate_renag_sweep
before2=$(nsends)
db "UPDATE tasks SET gate_last_attempt_at=datetime('now','-121 minutes') WHERE id=${bad};"
FAIL_SEND=1 _hb_gate_renag_sweep
after2=$(nsends)
db "UPDATE tasks SET gate_last_attempt_at=datetime('now','-239 minutes') WHERE id=${bad};"
FAIL_SEND=1 _hb_gate_renag_sweep
before4=$(nsends)
db "UPDATE tasks SET gate_last_attempt_at=datetime('now','-241 minutes') WHERE id=${bad};"
FAIL_SEND=1 _hb_gate_renag_sweep
after4=$(nsends)
[[ "$before2" == "0" && "$after2" == "1" && "$before4" == "1" && "$after4" == "2" && "$(failures "$bad")" == "4" ]] \
  && ok_t "second and third retries honor the 2h and 4h boundaries" \
  || bad_t "intermediate backoff boundary wrong" "before2=$before2 after2=$after2 before4=$before4 after4=$after4 failures=$(failures "$bad")"

: >"$SEND_LOG"
db "UPDATE tasks SET gate_last_attempt_at=datetime('now','-479 minutes') WHERE id=${bad};"
FAIL_SEND=1 _hb_gate_renag_sweep
before8=$(nsends)
db "UPDATE tasks SET gate_last_attempt_at=datetime('now','-481 minutes') WHERE id=${bad};"
FAIL_SEND=1 _hb_gate_renag_sweep
[[ "$before8" == "0" && "$(nsends)" == "1" && "$(failures "$bad")" == "5" ]] \
  && ok_t "fifth unconfirmed attempt reaches the hard cap" \
  || bad_t "eight-hour retry cap not reached" "before8=$before8 sends=$(nsends) failures=$(failures "$bad")"
: >"$SEND_LOG"
FAIL_SEND=1 _hb_gate_renag_sweep
_hb_gate_delivery_alarm_sweep
first_alerts=$(grep -c . "$ALERT_LOG")
_hb_gate_delivery_alarm_sweep
[[ "$(nsends)" == "0" && -n "$(alarmed "$bad")" && "$first_alerts" == "1" && "$(grep -c . "$ALERT_LOG")" == "1" ]] \
  && ok_t "capped failures stop human sends and raise one agent alarm" \
  || bad_t "cap/alarm rail failed" "sends=$(nsends) alarm=$(alarmed "$bad") alerts=$(grep -c . "$ALERT_LOG")"

# Answered and terminal rows are excluded even if their clocks look due.
reset
answered=$(mk_gate DIVE-15 2 decision '-3 hours' NULL 'A|B' A '')
done_gate=$(mk_gate DIVE-16 2 decision '-3 hours' NULL 'A|B' A '')
db "UPDATE tasks SET need_answer='A', need_answered_at=datetime('now') WHERE id=${answered};
    UPDATE tasks SET status='done' WHERE id=${done_gate};"
_hb_gate_renag_sweep
[[ "$(nsends)" == "0" ]] \
  && ok_t "answered and done gates never enter a reminder batch" \
  || bad_t "superseded gate was re-sent" "sends=$(nsends) ids=$(tr '\n' ',' <"$SEND_LOG")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
