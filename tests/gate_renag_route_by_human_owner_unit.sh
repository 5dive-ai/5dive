#!/usr/bin/env bash
# DIVE-4911 — a gate reminder is carried by a bot that reaches its OWNER, not by
# the filer's bot; a miss tries the next bot, and when every bot misses the row
# backs off 24h and says so in doctor and `human recipient`.
#
# THE INCIDENT (customer box, 10 humans, 20 seats, 0.50.0). Human K had started
# only their own assistant's bot. A gate K owned, filed by another seat, re-nagged
# through the FILER's bot (`COALESCE(created_by, assignee)`), which answered
# `400 chat not found` 230 times a day; a gate K created themselves resolved no
# channel at all (created_by = K's handle). Nothing stamped a failure, so both
# re-ran every tick, and every check read OK.
#
# THE FIXTURE IS THE POINT. The real send path runs (_task_send_gate_owner ->
# _mirror_post); only the Bot API POST is stubbed, per bot token: a bot listed in
# DEAD_BOTS answers exactly what Telegram answers for a person who never started
# it. K is in every bot's allowFrom, as on the customer box, so the allowFrom
# narrowing cannot be what saves an arm.
#   R1  owned by K, filed by a seat whose bot K never started -> delivered by K's
#       linked seat. MUTANT M1 restores the filer pick and R1 goes red.
#   R2  owned by K, created BY K (created_by = a handle, not a seat) -> delivered.
#   R3  `chat not found` on the first bot -> the next bot (a confirmed receipt) is
#       tried and delivers.
#   R4  every bot fails -> gate_renag_failed_at + _via stamped, gate_pinged_at NOT;
#       the next tick sends nothing; 24h later it tries again; a re-ask re-arms it;
#       a confirmed send clears the stamp.
#   D1  doctor lists the undelivered gate and the bots that failed; D2 clean -> ok.
#   H1  `human recipient` names the sender bot and each bot's reach.
#   A1  anchor: registry empty -> the sweep is its pre-DIVE-4911 self.
#
# Run: bash tests/gate_renag_route_by_human_owner_unit.sh   (no root, no network)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/gate-owner-route.XXXXXX)

load_src() { # [heartbeat file]
  local f
  # shellcheck disable=SC1090
  for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
           lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
           lib/tasks_db.sh lib/actor.sh cmd_agent_runtime.sh cmd_task.sh cmd_org.sh \
           cmd_agent.sh cmd_human.sh cmd_doctor.sh; do
    source "$SRC/$f"
  done
  source "${1:-$SRC/cmd_heartbeat.sh}"
  set +e
}
load_src

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"      # DIVE-1506: this store IS the send target
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"
CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$CONNECTORS_DIR"

# Reserved fakes only (CLAUDE.md): documented 1234567890-shaped ids.
CHAT_K=1234500011
CHAT_A=1234500022
BOTS="kseat kdead alena luca aseat"
ACCESS="$TMP/access.json"
printf '{"allowFrom":["%s","%s"]}\n' "$CHAT_K" "$CHAT_A" >"$ACCESS"
for b in $BOTS; do printf 'TELEGRAM_BOT_TOKEN=tok-%s\n' "$b" >"$CONNECTORS_DIR/telegram-${b}.env"; done

# Only seats in BOTS have a channel; marcus (the coordinator) and a human's
# handle have none, exactly as on the customer box.
_task_agent_channel() {
  TASK_CH_TOKEN="" TASK_CH_ACCESS="" TASK_CH_TYPE="" TASK_CH_AGENT=""
  [[ " $BOTS " == *" ${1:-} "* ]] || return 1
  TASK_CH_TOKEN="tok-$1" TASK_CH_ACCESS="$ACCESS" TASK_CH_TYPE=claude TASK_CH_AGENT="$1"
}
SEND_LOG="$TMP/sends"; : >"$SEND_LOG"
DEAD_BOTS=""          # bots the person never started: "tok-x" answers chat not found
_mirror_send() {
  local bot="${1#tok-}"
  printf '%s>%s\n' "$bot" "$2" >>"$SEND_LOG"
  if [[ " $DEAD_BOTS " == *" $bot "* ]]; then
    printf '%s' '{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}'
  else
    printf '%s' '{"ok":true,"result":{"message_id":777}}'
  fi
}
_mirror_log_button_reject() { :; }
_mirror_follow_migration() { :; }
audit_log() { :; }
warn() { :; }
HB_LOG="$TMP/hb.log"; : >"$HB_LOG"
_hb_log() { printf '%s\n' "$*" >>"$HB_LOG"; }
cmd_send() { return 1; }     # never inject into a live pane from a unit test

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
sends() { tr '\n' ' ' <"$SEND_LOG"; }
# The bots tried, in order, once each: the real _mirror_post retries a failed
# button-bearing send once without its keyboard (DIVE-117), so the raw log has
# two lines per attempt and a line count would grade that retry, not routing.
bots() { cut -d'>' -f1 <"$SEND_LOG" | awk '!s[$0]++' | paste -sd, -; }
col() { db "SELECT COALESCE($2,'NULL') FROM tasks WHERE id=$1;"; }

db "INSERT INTO agents_org (name,reports_to,role) VALUES ('marcus',NULL,'coordinator'),
      ('kseat','marcus',NULL),('kdead','marcus',NULL),('alena','marcus',NULL),
      ('luca','marcus',NULL),('aseat','marcus',NULL);"

reset() {
  db "DELETE FROM tasks; DELETE FROM gate_cards; DELETE FROM human_agents; DELETE FROM humans;"
  : >"$SEND_LOG"; : >"$HB_LOG"; DEAD_BOTS=""
}
humans_on() {
  db "INSERT INTO humans (id,display_name,telegram_id) VALUES ('k','K','${CHAT_K}'),('a','A','${CHAT_A}');"
}
mk_gate() { # <ident> <created_by> <owner|''>  -> row id; tier-2, asked 2h ago, never pinged
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,need_type,tier,ask,need_asked_at,gate_filed_by,human_owner)
      VALUES ($(sqlq "$1"),'gate','high',$(sqlq "$2"),$(sqlq "$2"),'standard','blocked','approval',2,'ship it?',
              datetime('now','-2 hours'),$(sqlq "$2"),NULLIF($(sqlq "$3"),''));
      SELECT last_insert_rowid();"
}
receipt() { # <via> <chat> <age>  — a confirmed card from an earlier send
  db "INSERT INTO gate_cards (task_id,ident,chat_id,message_id,via,state,minted_at)
      VALUES (999,'DIVE-OLD',$(sqlq "$2"),'5',$(sqlq "$1"),'struck',datetime('now',$(sqlq "$3")));"
}

# ─── A1 anchor: registry EMPTY — the pre-DIVE-4911 path, byte for byte ────────
reset
a1=$(mk_gate DIVE-A1 alena '')
_hb_gate_renag_sweep
[[ "$(sends)" == "alena>"* && "$(col "$a1" gate_renag_failed_at)" == "NULL" ]] \
  && ok_t "A1 anchor: with no human accounts the re-nag still rides the filer's bot, no backoff stamp" \
  || bad_t "A1 registry-empty behaviour changed" "sends=$(sends) failed=$(col "$a1" gate_renag_failed_at)"

# ─── R1 THE BUG: owned by K, filed by a seat whose bot K never started ────────
r1_arm() {
  reset; humans_on
  db "INSERT INTO human_agents (human_id,agent) VALUES ('k','kseat'),('a','aseat'),('a','alena');"
  DEAD_BOTS="alena"          # K never started alena's bot
  R1=$(mk_gate DIVE-441 alena k)
  _hb_gate_renag_sweep
  grep -qx "kseat>${CHAT_K}" "$SEND_LOG" && [[ "$(col "$R1" gate_pinged_at)" != "NULL" ]] \
    && ! grep -q "^alena>" "$SEND_LOG"
}
if r1_arm; then
  ok_t "R1 a gate owned by K and filed by another seat is delivered through K's linked seat"
else
  bad_t "R1 reminder did not reach K through K's own seat" "sends=$(sends) pinged=$(col "$R1" gate_pinged_at)"
fi

# ─── R2 the row K created themselves: created_by is a handle, not a seat ──────
reset; humans_on
db "INSERT INTO human_agents (human_id,agent) VALUES ('k','kseat');"
r2=$(mk_gate DIVE-187 k_handle k)
_hb_gate_renag_sweep
grep -qx "kseat>${CHAT_K}" "$SEND_LOG" && [[ "$(col "$r2" gate_pinged_at)" != "NULL" ]] \
  && ok_t "R2 a row created by the human (created_by = their handle) still reaches them" \
  || bad_t "R2 human-created row not delivered" "sends=$(sends) log=$(tr '\n' ' ' <"$HB_LOG")"

# ─── R3 chat not found on the first bot -> the next bot delivers ──────────────
reset; humans_on
db "INSERT INTO human_agents (human_id,agent) VALUES ('k','kdead');"
receipt luca "$CHAT_K" '-3 hours'          # luca has reached K before
DEAD_BOTS="kdead alena"
r3=$(mk_gate DIVE-R3 alena k)
_hb_gate_renag_sweep
order=$(sends)
[[ "$order" == "kdead>${CHAT_K} "*"luca>${CHAT_K} " && "$(col "$r3" gate_pinged_at)" != "NULL" \
   && "$order" != *"alena>"* ]] \
  && ok_t "R3 'chat not found' on K's linked bot falls through to the bot with a confirmed receipt" \
  || bad_t "R3 did not try the next bot" "sends=$order pinged=$(col "$r3" gate_pinged_at)"
[[ "$(col "$r3" gate_renag_failed_at)" == "NULL" ]] \
  && ok_t "R3 a delivery on the second bot leaves no failure stamp" \
  || bad_t "R3 stamped a failure on a delivered row"

# ─── R4 every bot fails -> stamp, back off 24h, never stamp as reminded ───────
reset; humans_on
db "INSERT INTO human_agents (human_id,agent) VALUES ('k','kdead');"
receipt luca "$CHAT_K" '-3 hours'
DEAD_BOTS="kdead luca alena"
r4=$(mk_gate DIVE-R4 alena k)
_hb_gate_renag_sweep
via=$(col "$r4" gate_renag_failed_via)
[[ "$(col "$r4" gate_renag_failed_at)" != "NULL" && "$(col "$r4" gate_pinged_at)" == "NULL" \
   && "$via" == "kdead,luca,alena" && "$(bots)" == "kdead,luca,alena" ]] \
  && ok_t "R4 every bot failing stamps gate_renag_failed_at + the bots tried, and NOT gate_pinged_at" \
  || bad_t "R4 failure not recorded as a negative receipt" "sends=$(sends) via=$via pinged=$(col "$r4" gate_pinged_at)"
grep -q "UNDELIVERED to k rows=${r4}" "$HB_LOG" \
  && ok_t "R4 the heartbeat log names the person and the row" \
  || bad_t "R4 no UNDELIVERED log line" "$(tr '\n' ' ' <"$HB_LOG")"

: >"$SEND_LOG"
_hb_gate_renag_sweep
[[ ! -s "$SEND_LOG" ]] \
  && ok_t "R4 the next tick sends nothing (backing off, not re-sending every 5 minutes)" \
  || bad_t "R4 re-sent on the next tick" "sends=$(sends)"

# Liveness for the quiet tick above: 24h later it tries again, so "quiet" was
# the backoff and not a wedged row.
db "UPDATE tasks SET gate_renag_failed_at=datetime('now','-25 hours') WHERE id=${r4};"
_hb_gate_renag_sweep
[[ "$(bots)" == "kdead,luca,alena" ]] \
  && ok_t "R4 after 24h the reminder is tried again" \
  || bad_t "R4 backoff never expired" "sends=$(sends)"

# A re-ask moves need_asked_at past the stamp and re-arms at once.
: >"$SEND_LOG"
db "UPDATE tasks SET gate_renag_failed_at=datetime('now','-3 hours'), need_asked_at=datetime('now','-2 hours') WHERE id=${r4};"
_hb_gate_renag_sweep
[[ -s "$SEND_LOG" ]] \
  && ok_t "R4 a re-asked gate is not held by a failure from before the re-ask" \
  || bad_t "R4 re-ask stayed backed off"

# ─── D1 doctor names the undelivered gate and the failed bots ─────────────────
DOCTOR_CHECKS='[]'; step() { :; }
doctor_check_gate_owner_delivery
sev=$(jq -r '.[] | select(.name=="gate-owner-delivery") | .severity' <<<"$DOCTOR_CHECKS")
msg=$(jq -r '.[] | select(.name=="gate-owner-delivery") | .message' <<<"$DOCTOR_CHECKS")
[[ "$sev" == "error" && "$msg" == *"DIVE-R4 (owner k; failed via kdead,luca,alena)"* ]] \
  && ok_t "D1 doctor lists the undelivered gate, its owner and the bots that failed" \
  || bad_t "D1 doctor silent on the undelivered gate" "sev=$sev msg=$msg"

# ─── H1 human recipient names the sender bot and each bot's reach ─────────────
_human_bot_reach() {
  if [[ " $BOTS " != *" $1 "* ]]; then printf 'no bot'
  elif [[ " $DEAD_BOTS " == *" $1 "* ]]; then printf 'chat not found'
  else printf 'reachable'; fi
}
DEAD_BOTS="kdead"
out=$(cmd_human_recipient DIVE-R4 2>&1)
[[ "$out" == *"kdead: chat not found"* && "$out" == *"sender: luca"* && "$out" == *"NOT delivered"* ]] \
  && ok_t "H1 human recipient shows each bot's reach, the sender, and the failed reminder" \
  || bad_t "H1 human recipient hides the sender" "$out"
DEAD_BOTS="kdead luca alena"
out=$(cmd_human_recipient DIVE-R4 2>&1)
[[ "$out" == *"sender: NONE"* ]] \
  && ok_t "H1 with no bot able to reach the person it says so instead of OK" \
  || bad_t "H1 printed a sender nobody can use" "$out"

# ─── R5 a confirmed send clears the stamp; D2 doctor then reads ok ────────────
DEAD_BOTS="kdead alena"                       # luca reaches K again
db "UPDATE tasks SET gate_renag_failed_at=datetime('now','-25 hours') WHERE id=${r4};"
_hb_gate_renag_sweep
[[ "$(col "$r4" gate_renag_failed_at)" == "NULL" && "$(col "$r4" gate_renag_failed_via)" == "NULL" \
   && "$(col "$r4" gate_pinged_at)" != "NULL" ]] \
  && ok_t "R5 a confirmed send clears the negative receipt" \
  || bad_t "R5 stamp survived a delivery" "failed=$(col "$r4" gate_renag_failed_at)"
DOCTOR_CHECKS='[]'
doctor_check_gate_owner_delivery
[[ "$(jq -r '.[] | select(.name=="gate-owner-delivery") | .severity' <<<"$DOCTOR_CHECKS")" == "ok" ]] \
  && ok_t "D2 doctor reads ok once every gate has a receipt" \
  || bad_t "D2 doctor still flags a delivered gate" "$DOCTOR_CHECKS"
grep -q 'doctor_check_gate_owner_delivery$' src/cmd_doctor.sh \
  && ok_t "D3 cmd_doctor calls the check (defined AND wired)" \
  || bad_t "D3 the doctor check is not wired into cmd_doctor"

# ─── M1 MUTANT: restore the filer pick — R1 must go red ───────────────────────
# The mutant sends every owned batch through the caller's recipient or the rows'
# filer (COALESCE(created_by, assignee)), which is the pre-fix choice of bot.
MUT="$TMP/cmd_heartbeat.mut.sh"
python3 - "$SRC/cmd_heartbeat.sh" "$MUT" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = '  mapfile -t cands < <(_human_gate_sender_candidates "$hid" "${recipient:+${recipient},}${fallback}")'
assert old in s, "mutant anchor moved"
s = s.replace(old, '  cands=("${recipient:-${fallback%%,*}}")', 1)
open(sys.argv[2], 'w').write(s)
PY
if [[ -s "$MUT" ]]; then
  # shellcheck disable=SC1090
  source "$MUT"; set +e
  _hb_log() { printf '%s\n' "$*" >>"$HB_LOG"; }
  if r1_arm; then
    bad_t "M1 mutant (filer pick restored) still passes R1 — the arm is vacuous" "sends=$(sends)"
  else
    ok_t "M1 mutant: restoring the filer pick turns R1 red"
  fi
  source "$SRC/cmd_heartbeat.sh"; set +e
  _hb_log() { printf '%s\n' "$*" >>"$HB_LOG"; }
  r1_arm && ok_t "M1 control: the real tree passes R1 again after the mutant" \
         || bad_t "M1 control failed on the real tree" "sends=$(sends)"
else
  bad_t "M1 mutant could not be built" "anchor line not found in cmd_heartbeat.sh"
fi

printf -- '-----\ngate_renag_route_by_human_owner_unit: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
