#!/usr/bin/env bash
# DIVE-6760 — a gate filed by a seat whose bot has no chat with the owner.
# Measured on poke-two 2026-10-23: dev's secret gate (DIVE-6758) minted its
# one-time link, the file-time send found "no allowlisted DM", and the gate
# reached the owner 15 min later through main's bot as "🔁 Gate reminder" with
# "First reminder is after 1h" and NO link. The owner: "why reminder if I wasn't
# even asked before?" and "where to click?".
#
# R arms (the re-nag sweep): a never-pinged gate renders as the FIRST ask, a
#   pinged one still as a reminder, a mixed batch marks the new rows; a secret
#   gate's first contact always carries a fresh link, a reminder only when no
#   link is still live; both languages.
# F arms (file-time): the filer's bot reaches nobody -> the gate notifier's bot
#   sends in the same call (in-process when its channel is readable, else the
#   privileged re-send told which bot to skip); controls for a bot that reaches
#   the owner and a notifier that IS the filer.
#
# Run: bash tests/dive6760_first_contact_gate_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
SRC=src
TMP=$(mktemp -d /tmp/dive6760.XXXXXX)

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
db "INSERT INTO agents_org (name,reports_to,role) VALUES ('main',NULL,'coordinator'),('dev','main',NULL);"
# Load the lazily-dispatched notify module before stubbing anything inside it.
declare -F _task_gate_undo_window_secs >/dev/null 2>&1 || _task_gate_undo_window_secs DIVE-0 >/dev/null 2>&1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if eval "$2"; then ok_t "$1"; else bad_t "$1" "${3:-}"; fi; }

# --- seams -------------------------------------------------------------------
# Two bots: dev's has no DM with the owner, main's has one (chat 1234567890).
mkdir -p "$TMP/ch/dev" "$TMP/ch/main"
printf '{"allowFrom":[]}' >"$TMP/ch/dev/access.json"
printf '{"allowFrom":["1234567890"]}' >"$TMP/ch/main/access.json"
UNREADABLE=""          # agent names whose channel this shell cannot read
_task_agent_channel() {
  TASK_CH_TOKEN="" TASK_CH_ACCESS="" TASK_CH_TYPE="" TASK_CH_AGENT=""
  [[ -n "$1" && -d "$TMP/ch/$1" && " $UNREADABLE " != *" $1 "* ]] || return 1
  TASK_CH_TOKEN="tok-$1" TASK_CH_ACCESS="$TMP/ch/$1/access.json" TASK_CH_TYPE=claude TASK_CH_AGENT="$1"
}
_task_agent_paired() { [[ -d "$TMP/ch/$1" ]]; }
_human_registry_active() { return 1; }
_task_human_send_allowed() { return 0; }
GATE_LANG=en
_task_gate_lang() { printf '%s' "$GATE_LANG"; }
SEND_LOG="$TMP/sends"; LAST_TEXT="$TMP/text"
_task_post_owner_target() { # token chat thread text access markup ids
  printf '%s|%s|%s\n' "${1#tok-}" "$2" "$7" >>"$SEND_LOG"
  printf '%s' "$4" >"$LAST_TEXT"
  TASK_SEND_DELIVERED=1 TASK_SEND_MESSAGE_IDS=901
}
_task_secret_gate_app_button() { :; }
MINT_LOG="$TMP/mints"; MINT_OK=1
_task_mint_drop_link() {
  printf '%s\n' "$1" >>"$MINT_LOG"
  (( MINT_OK )) && printf 'https://secrets.box.example.com/tok-%s|30' "$(wc -l <"$MINT_LOG" | tr -d ' ')"
}
LIVE_LINK=0
_secret_drop_live_for() { (( LIVE_LINK )) && { printf '9999999999'; return 0; }; return 1; }
DELIV_LOG="$TMP/deliv"
_task_gate_delivery_log() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${5:-}" >>"$DELIV_LOG"; return 0; }
ESC_LOG="$TMP/esc"; ESC_RC=0
_task_gate_escalate_via_sudo() { printf '%s|%s|%s\n' "$1" "$2" "${3:-}" >>"$ESC_LOG"; return "$ESC_RC"; }
audit_log() { :; }; _hb_log() { :; }; cmd_send() { return 0; }

reset() {
  db "DELETE FROM tasks;"
  : >"$SEND_LOG"; : >"$LAST_TEXT"; : >"$MINT_LOG"; : >"$DELIV_LOG"; : >"$ESC_LOG"
  MINT_OK=1 LIVE_LINK=0 GATE_LANG=en UNREADABLE="" ESC_RC=0
  printf '{"allowFrom":[]}' >"$TMP/ch/dev/access.json"
}
nsends() { grep -c . "$SEND_LOG"; }
txt() { cat "$LAST_TEXT"; }
pinged() { db "SELECT CASE WHEN gate_pinged_at IS NULL THEN 'NULL' ELSE 'SET' END FROM tasks WHERE ident='$1';"; }
mk_gate() { # ident type asked_modifier ping_modifier|NULL
  local ping="NULL"; [[ "$4" != NULL ]] && ping="datetime('now','$4')"
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,gate_filed_by,kind,status,need_type,tier,ask,need_asked_at,gate_pinged_at,secret_key,connector)
      VALUES ('$1','gate','high','dev','dev','dev','standard','blocked','$2',2,'paste the key',datetime('now','$3'),${ping},'HF_TOKEN','tools');"
}

# --- R: the re-nag sweep --------------------------------------------------------
reset
mk_gate DIVE-21 secret '-20 minutes' NULL
_hb_gate_renag_sweep
check 'R1 a never-pinged secret gate is delivered once by the net, and stamped' \
  '[[ "$(nsends)" == 1 && "$(pinged DIVE-21)" == SET ]]' "sends=$(nsends) pinged=$(pinged DIVE-21)"
check 'R2 ...worded as the FIRST ask: the normal gate header, no "reminder", no "first reminder is after 1h"' \
  '[[ "$(txt)" == "🙋 [DIVE-21] needs you"* && "$(txt)" != *[Rr]eminder* ]]' "text: $(txt)"
check 'R3 ...and carries a fresh one-time link (the file-time one reached nobody)' \
  '[[ "$(txt)" == *"https://secrets.box.example.com/tok-1"* && "$(cat "$MINT_LOG")" == DIVE-21 ]]' \
  "mints=$(cat "$MINT_LOG") text: $(txt)"

reset; LIVE_LINK=1
mk_gate DIVE-22 secret '-20 minutes' NULL
_hb_gate_renag_sweep
check 'R4 first contact mints even while a file-time link is live (nobody holds that one)' \
  '[[ "$(cat "$MINT_LOG")" == DIVE-22 && "$(txt)" == *"https://secrets."* ]]' "mints=$(cat "$MINT_LOG")"

reset
mk_gate DIVE-23 approval '-2 hours' '-119 minutes'
_hb_gate_renag_sweep
check 'R5 control: a gate already pinged still renders as a reminder' \
  '[[ "$(nsends)" == 1 && "$(txt)" == "🔁 Gate reminder"* && "$(txt)" == *"First reminder is after 1h"* ]]' "text: $(txt)"

reset; LIVE_LINK=1
mk_gate DIVE-24 secret '-2 hours' '-119 minutes'
_hb_gate_renag_sweep
check 'R6 a reminder for a secret gate whose link is still live mints nothing' \
  '[[ ! -s "$MINT_LOG" && "$(txt)" != *"https://secrets."* ]]' "mints=$(cat "$MINT_LOG")"
reset; LIVE_LINK=0
mk_gate DIVE-25 secret '-2 hours' '-119 minutes'
_hb_gate_renag_sweep
check 'R7 a reminder for a secret gate whose link expired carries a fresh one' \
  '[[ "$(cat "$MINT_LOG")" == DIVE-25 && "$(txt)" == *"https://secrets."* && "$(txt)" == "🔁 Gate reminder"* ]]' \
  "mints=$(cat "$MINT_LOG") text: $(txt)"

reset; MINT_OK=0
: >"$TMP/connectord.env"; export FIVEDIVE_CONNECTORD_ENV="$TMP/connectord.env"   # linked to the app
mk_gate DIVE-26 secret '-20 minutes' NULL
_hb_gate_renag_sweep
check 'R8 no link could be minted: the message says where to get one (the app), not nothing' \
  '[[ "$(txt)" == *"Open this task in the 5dive app"* ]]' "text: $(txt)"
# DIVE-7128: an OSS box has no app or dashboard; the server line is the way in.
reset; MINT_OK=0
export FIVEDIVE_CONNECTORD_ENV="$TMP/no-such-connectord.env"
mk_gate DIVE-36 secret '-20 minutes' NULL
_hb_gate_renag_sweep
check 'R8b no link on an OSS box: the server line, and no app or dashboard anywhere in the message (DIVE-7128)' \
  '[[ "$(txt)" == *"sudo 5dive secret write HF_TOKEN --connector=tools --task=DIVE-36"* && "$(txt)" != *"dashboard"* && "$(txt)" != *"5dive app"* ]]' "text: $(txt)"
unset FIVEDIVE_CONNECTORD_ENV

reset
mk_gate DIVE-27 approval '-2 hours' '-119 minutes'
mk_gate DIVE-28 secret '-20 minutes' NULL
_hb_gate_renag_sweep
check 'R9 a mixed batch is a reminder, and only the never-asked row is marked new' \
  '[[ "$(txt)" == "🔁 Gate reminder"* && "$(txt)" == *"• 🆕 [DIVE-28]"* && "$(txt)" == *"• [DIVE-27]"* ]]' "text: $(txt)"

reset
mk_gate DIVE-29 approval '-20 minutes' NULL
mk_gate DIVE-30 secret '-20 minutes' NULL
_hb_gate_renag_sweep
check 'R10 two never-asked gates: one first-ask message, no reminder footer' \
  '[[ "$(nsends)" == 1 && "$(txt)" == "🙋 2 gates need you:"* && "$(txt)" != *[Rr]eminder* && "$(txt)" != *"🆕"* ]]' "text: $(txt)"

reset; GATE_LANG=ru
mk_gate DIVE-31 secret '-20 minutes' NULL
_hb_gate_renag_sweep
check 'R11 ru: first contact reads as the ask, no "Напоминание", with the link' \
  '[[ "$(txt)" == "🙋 [DIVE-31] ждёт вашего ответа"* && "$(txt)" != *Напоминание* && "$(txt)" != *"Первое напоминание"* && "$(txt)" == *"https://secrets."* ]]' "text: $(txt)"
reset; GATE_LANG=ru
mk_gate DIVE-32 approval '-20 minutes' NULL
mk_gate DIVE-33 approval '-20 minutes' NULL
_hb_gate_renag_sweep
check 'R12 ru: the plural first-ask header and footer' \
  '[[ "$(txt)" == "🙋 Ждут вашего ответа (2):"* && "$(txt)" != *"Первое напоминание"* ]]' "text: $(txt)"

# --- F: the file-time send ----------------------------------------------------
filetime() { # ident
  TASK_SEND_DELIVERED=0 TASK_GATE_DELIVERY_ROWS=0
  TASK_GATE_FILER=dev _task_need_notify_deliver_now "$1" secret 'paste the key' '' '' HF_TOKEN tools nonce123 '' 2>"$TMP/err"
}

reset
mk_gate DIVE-41 secret '-0 minutes' NULL
filetime DIVE-41
check "F1 the filer's bot reaches nobody: ONE confirmed send, from main's bot, to the owner, same call" \
  '[[ "$(nsends)" == 1 && "$(cat "$SEND_LOG")" == "main|1234567890|"* && "$TASK_SEND_DELIVERED" == 1 && "$(pinged DIVE-41)" == SET ]]' \
  "sends=$(cat "$SEND_LOG") delivered=$TASK_SEND_DELIVERED"
check '  F1b ...worded as the first ask, naming the asking seat, with a https://secrets link' \
  '[[ "$(txt)" == "🙋 [DIVE-41] needs you"* && "$(txt)" == *"asked by dev"* && "$(txt)" == *"https://secrets."* && "$(txt)" != *[Rr]eminder* ]]' "text: $(txt)"
check '  F1c ...and the miss on dev is on the record, then the ok' \
  '[[ "$(head -1 "$DELIV_LOG")" == error*"no allowlisted DM"* ]]' "deliv: $(cat "$DELIV_LOG")"

reset; UNREADABLE=main
mk_gate DIVE-42 secret '-0 minutes' NULL
filetime DIVE-42
check "F2 main's channel unreadable from this seat: the privileged re-send runs, told to skip dev's bot" \
  '[[ "$(cat "$ESC_LOG")" == "DIVE-42|nonce123|dev" && "$TASK_SEND_DELIVERED" == 1 && "$TASK_GATE_DELIVERY_ROWS" -ge 1 ]]' \
  "esc=$(cat "$ESC_LOG") delivered=$TASK_SEND_DELIVERED"
reset; UNREADABLE=main; ESC_RC=2
mk_gate DIVE-43 secret '-0 minutes' NULL
filetime DIVE-43
check '  F2b a failed re-send stays undelivered and unstamped (the re-nag is still the net)' \
  '[[ "$TASK_SEND_DELIVERED" != 1 && "$(pinged DIVE-43)" == NULL ]]' "delivered=$TASK_SEND_DELIVERED"

reset
printf '{"allowFrom":["1234567890"]}' >"$TMP/ch/dev/access.json"
mk_gate DIVE-44 secret '-0 minutes' NULL
filetime DIVE-44
check "F3 control: a filer's bot that reaches the owner sends alone — no second bot, no re-send" \
  '[[ "$(nsends)" == 1 && "$(cat "$SEND_LOG")" == dev\|* && ! -s "$ESC_LOG" && "$(txt)" != *"asked by"* ]]' "sends=$(cat "$SEND_LOG")"

reset
db "UPDATE agents_org SET role=NULL WHERE name='main'; UPDATE agents_org SET role='coordinator' WHERE name='dev';"
mk_gate DIVE-45 secret '-0 minutes' NULL
filetime DIVE-45
check "F4 the notifier IS the filer: nothing to fall back to, no loop, no re-send" \
  '[[ "$(nsends)" == 0 && ! -s "$ESC_LOG" && "$TASK_SEND_DELIVERED" != 1 ]]' "sends=$(nsends) esc=$(cat "$ESC_LOG")"
db "UPDATE agents_org SET role='coordinator' WHERE name='main'; UPDATE agents_org SET role=NULL WHERE name='dev';"

# The privileged child: `task gate-escalate --not-via=` reaches the notify path as
# TASK_GATE_NOT_VIA, and junk is refused before anything is sent.
reset
mk_gate DIVE-46 secret '-0 minutes' NULL
NOTVIA_SEEN="$TMP/notvia"
out=$( _gate_is_root() { return 0; }
       task_need_notify() { printf '%s' "${TASK_GATE_NOT_VIA:-}" >"$NOTVIA_SEEN"; TASK_SEND_DELIVERED=1; return 0; }
       _task_store_audit_log() { :; }
       cmd_task_gate_escalate DIVE-46 --not-via=dev </dev/null 2>&1 ); rc=$?
check 'F5 gate-escalate --not-via=dev hands the skip to the notify path' \
  '[[ "$rc" == 0 && "$(cat "$NOTVIA_SEEN" 2>/dev/null)" == dev ]]' "rc=$rc out=$out"
: >"$NOTVIA_SEEN"
out=$( _gate_is_root() { return 0; }
       task_need_notify() { printf 'SENT' >"$NOTVIA_SEEN"; return 0; }
       cmd_task_gate_escalate DIVE-46 '--not-via=../x' </dev/null 2>&1 ); rc=$?
check '  F5b a --not-via that is not an agent name is refused, nothing sent' \
  '[[ "$rc" != 0 && ! -s "$NOTVIA_SEEN" ]]' "rc=$rc out=$out"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
