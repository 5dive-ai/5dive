#!/usr/bin/env bash
# DIVE-7128 — a STANDARD seat's secret gate reaches its owner with the one-time
# link, and the seat never holds it.
#
# lodar, 2026-10-27, on oinoa's DIVE-7127 key ask (poke-two, an OSS box): the
# alert said "open this task in the 5dive app", and an OSS box has no app. A
# standard seat cannot mint, because a link is the right to write one key into a
# root-owned connector file. So the seat hands the gate to one exact-path root
# verb, `5dive _secret_link_notify`, which mints AND sends, and answers "sent".
#
# S arms, the seat half (_task_secret_send_via_root):
#   S1 a standard seat with the grant crosses: ident + nonce on stdin, NO argv
#      beyond the verb, and the delivery is credited from root's one line
#   S2 an admin seat mints for itself: no cross
#   S3 a seat without the grant yet: no cross, no refused sudo, a `none` line
#   S4 root refused: the seat falls back, and the reason is on the record
#   S5 a fixture or dry-run store never crosses (root reads the box's store)
#   S6 root's own retries never re-cross
# R arms, the root half (cmd_secret_link_notify_delegated):
#   R1 the seat's own open gate: minted, sent to the owner WITH the link, and
#      stdout is one line that carries no link token
#   R2 another seat's gate is refused, and nothing is minted or sent
#   R3 an answered gate, a closed row, a non-secret gate, a gate naming no
#      place on the box: each refused, nothing minted
#   R4 a link for the gate is still live: refused (no paging loop)
#   R5 not root, no SUDO_UID, a caller that is no seat, an argument: refused
#   R6 a send nobody received burns the link it minted
# A arm: the one POST every alert funnels through puts neither the text nor the
#   keyboard in curl's argv (any seat can list argv), and leaves no file behind.
# G arm: the standard sudoers template carries the exact grant and still
#   classifies cli-scoped with no extra entries.
#
# Run: bash tests/secret_link_root_send_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
SRC=src
TMP=$(mktemp -d /tmp/secret-link-root-send.XXXXXX)

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_agent_runtime.sh cmd_task.sh cmd_secret_drop.sh cmd_agent_create.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
SECRET_DROP_DIR="$TMP/drop"; mkdir -p "$TASKS_DIR" "$SECRET_DROP_DIR"
tasks_db_init; _tasks_db_migrate
LOG="$TMP/gate-notify.log"; FIVEDIVE_GATE_NOTIFY_LOG="$LOG"
export FIVEDIVE_CONNECTORD_ENV="$TMP/no-connectord.env"   # an OSS box
# Load the lazily-dispatched notify module before stubbing anything inside it.
declare -F _task_gate_undo_window_secs >/dev/null 2>&1 || _task_gate_undo_window_secs DIVE-0 >/dev/null 2>&1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if eval "$2"; then ok_t "$1"; else bad_t "$1" "${3:-}"; fi; }

TOKEN="AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_Zz9"
URL="https://secrets.box.example.com/${TOKEN}"

# --- seams --------------------------------------------------------------------
SEND_ALLOWED=0
_task_human_send_allowed() { (( SEND_ALLOWED )); }
_task_store_audit_log() { :; }
audit_log() { :; }
mkdir -p "$TMP/ch/oinoa"
printf '{"allowFrom":["1234567890"]}' >"$TMP/ch/oinoa/access.json"
_task_agent_channel() {
  TASK_CH_TOKEN="" TASK_CH_ACCESS="" TASK_CH_TYPE="" TASK_CH_AGENT=""
  [[ -n "$1" && -d "$TMP/ch/$1" ]] || return 1
  TASK_CH_TOKEN="tok-$1" TASK_CH_ACCESS="$TMP/ch/$1/access.json" TASK_CH_TYPE=claude TASK_CH_AGENT="$1"
}
_task_gate_notifier_explicit() { return 1; }
_human_registry_active() { return 1; }
_task_partner_app_url() { :; }
_task_secret_gate_app_button() { :; }
SEND_TEXT="$TMP/sent-text"; SEND_OK=1
_task_post_owner_target() { # token chat thread text access markup ids
  printf '%s' "$4" >"$SEND_TEXT"
  printf 'sending: %s\n' "$4" >&2   # a chatty path: root must not pass this on
  if (( SEND_OK )); then
    TASK_SEND_DELIVERED=1 TASK_SEND_MESSAGE_IDS=901 TASK_SEND_TARGETS="$2"
    _task_gate_delivery_log ok "$7" "$2" 901 "confirmed Bot API send"
  else
    TASK_SEND_FAILED=1
    _task_gate_delivery_log error "$7" "$2" "" "Bot API refused"
  fi
}
MINT_LOG="$TMP/mints"
_task_mint_drop_link() { # what the root path does: a real link file, then url|ttl
  printf '%s\n' "$1" >>"$MINT_LOG"
  printf 'task=%s\nkey=%s\nconnector=%s\nexpires=%s\n' "$1" "$2" "$3" "$(( $(date +%s) + 1800 ))" \
    >"$SECRET_DROP_DIR/$(_secret_drop_hash "$TOKEN")"
  printf '%s|30' "$URL"
}

mk_gate() { # ident filer [need_type] [status] [answered] [key]
  db "INSERT INTO tasks (ident,title,status,priority,assignee,created_by,gate_filed_by,need_type,tier,ask,need_asked_at,need_answered_at,secret_key,connector)
      VALUES ($(sqlq "$1"),'fixture',$(sqlq "${4:-blocked}"),'high',$(sqlq "$2"),'main',$(sqlq "$2"),$(sqlq "${3:-secret}"),2,
              'paste the Clerk secret key',datetime('now'),$( [[ -n "${5:-}" ]] && echo "datetime('now')" || echo NULL ),
              $(sqlq "${6-CLERK_SECRET_KEY}"),'tools');"
}
reset() {
  db "DELETE FROM tasks;"; rm -f "$SECRET_DROP_DIR"/* 2>/dev/null
  : >"$MINT_LOG"; : >"$SEND_TEXT"; : >"$LOG"; SEND_OK=1
}

# ================================ S: the seat half ============================
SUDO_LOG="$TMP/sudo.log"; SUDO_IN="$TMP/sudo.stdin"
SUDO_L_RC=0; SUDO_RC=0; SUDO_OUT="sent ttl=30 to=1234567890"; SUDO_ERR=""
sudo() {
  printf '%s\n' "$*" >>"$SUDO_LOG"
  if [[ "$*" == "-n -l "* ]]; then return "$SUDO_L_RC"; fi
  cat >"$SUDO_IN"
  [[ -n "$SUDO_ERR" ]] && printf '%s\n' "$SUDO_ERR" >&2
  printf '%s\n' "$SUDO_OUT"; return "$SUDO_RC"
}
id() { [[ "${1:-}" == -un ]] && { printf 'agent-oinoa\n'; return 0; }; command id "$@"; }
SEAT_TIER=standard
agent_tier() { [[ "$1" == oinoa ]] && printf '%s\n' "$SEAT_TIER" || printf 'unknown:unregistered\n'; }
cross() {
  : >"$SUDO_LOG"; : >"$SUDO_IN"
  TASK_SEND_DELIVERED=0 TASK_SEND_TARGETS="" TASK_GATE_DROP_LINK_TTL="" TASK_GATE_DELIVERY_ROWS=0
  _task_secret_send_via_root DIVE-7127 nonce-abc 2>/dev/null
}

SEND_ALLOWED=1
cross; rc=$?
check 'S1 a standard seat crosses: exact verb, no argument beyond it' \
  '[[ "$rc" == 0 && "$(tail -n1 "$SUDO_LOG")" == "-n /usr/local/bin/5dive _secret_link_notify" ]]' "rc=$rc sudo=$(cat "$SUDO_LOG")"
check '  S1b ...the ident and the nonce travel on stdin' \
  '[[ "$(cat "$SUDO_IN")" == "DIVE-7127"$'"'"'\n'"'"'"nonce-abc" ]]' "stdin=$(cat "$SUDO_IN")"
check '  S1c ...and the delivery is credited from the one line root printed' \
  '[[ "$TASK_SEND_DELIVERED" == 1 && "$TASK_GATE_DROP_LINK_TTL" == 30 && "$TASK_SEND_TARGETS" == 1234567890 && "$TASK_GATE_DELIVERY_ROWS" == 1 ]]' \
  "delivered=$TASK_SEND_DELIVERED ttl=$TASK_GATE_DROP_LINK_TTL to=$TASK_SEND_TARGETS rows=$TASK_GATE_DELIVERY_ROWS"

SEAT_TIER='admin'
cross; rc=$?
check 'S2 an admin seat mints for itself: no cross' '[[ "$rc" == 1 && ! -s "$SUDO_LOG" ]]' "rc=$rc sudo=$(cat "$SUDO_LOG")"
SEAT_TIER=standard

SUDO_L_RC=1
cross; rc=$?
check 'S3 no grant yet: no cross, only the sudo -l probe, and a none line says why' \
  '[[ "$rc" == 1 && "$(cat "$SUDO_LOG")" == "-n -l /usr/local/bin/5dive _secret_link_notify" && "$(tail -n1 "$LOG")" == *"result=none tasks=DIVE-7127"*"no\\ grant"* ]]' \
  "rc=$rc sudo=$(cat "$SUDO_LOG") log=$(tail -n1 "$LOG")"
SUDO_L_RC=0

SUDO_RC=13; SUDO_OUT=""; SUDO_ERR="DIVE-7127's gate was filed by main, not oinoa"
cross; rc=$?
check 'S4 root refused: the seat falls back (rc 1, nothing credited) and the reason is logged' \
  '[[ "$rc" == 1 && "$TASK_SEND_DELIVERED" == 0 && "$(tail -n1 "$LOG")" == *"result=error tasks=DIVE-7127"*"filed\\ by\\ main"* ]]' \
  "rc=$rc delivered=$TASK_SEND_DELIVERED log=$(tail -n1 "$LOG")"
SUDO_RC=0; SUDO_OUT="sent ttl=30 to=1234567890"; SUDO_ERR=""

SEND_ALLOWED=0
cross; rc=$?
check 'S5a a fixture store never crosses' '[[ "$rc" == 1 && ! -s "$SUDO_LOG" ]]' "rc=$rc sudo=$(cat "$SUDO_LOG")"
SEND_ALLOWED=1
FIVEDIVE_NOTIFY_DRYRUN=1 cross; rc=$?
check 'S5b a dry-run never crosses' '[[ "$rc" == 1 && ! -s "$SUDO_LOG" ]]' "rc=$rc sudo=$(cat "$SUDO_LOG")"
TASK_GATE_ESCALATING=1 cross; rc=$?
check "S6 root's own retries never re-cross" '[[ "$rc" == 1 && ! -s "$SUDO_LOG" ]]' "rc=$rc sudo=$(cat "$SUDO_LOG")"
unset -f sudo id agent_tier

# ================================ R: the root half ============================
_gate_is_root() { return 0; }
_gate_uid_to_agent() { case "$1" in 1101) printf 'oinoa' ;; 1102) printf 'quinn' ;; *) printf '' ;; esac; }
root_send() { # stdin text; prints "rc|stdout|stderr"
  local out err rc=0
  out=$( (printf '%s' "$1" | cmd_secret_link_notify_delegated "${@:2}") 2>"$TMP/err" ) || rc=$?
  err=$(cat "$TMP/err")
  printf '%s|%s|%s' "$rc" "$out" "$err"
}
export SUDO_UID=1101

reset; mk_gate DIVE-7127 oinoa
got=$(root_send $'DIVE-7127\nnonce-abc\n')
check "R1 the seat's own open gate: sent, and stdout is exactly one line" \
  '[[ "$got" == "0|sent ttl=30 to=1234567890|" ]]' "got=$got"
check '  R1b ...the owner got the link in one line, with no app, dashboard or 5dive.ai named (an OSS box)' \
  '[[ "$(cat "$SEND_TEXT")" == *"Paste the CLERK_SECRET_KEY key here (one use, 30 min): ${URL}"* && "$(cat "$SEND_TEXT")" != *dashboard* && "$(cat "$SEND_TEXT")" != *"5dive app"* && "$(cat "$SEND_TEXT")" != *"5dive.ai"* ]]' \
  "text=$(cat "$SEND_TEXT")"
check '  R1c ...and nothing the seat reads back carries the token: stdout, stderr, gate-notify.log' \
  '[[ "$got" != *"$TOKEN"* && "$(cat "$LOG")" != *"$TOKEN"* ]]' "got=$got log=$(cat "$LOG")"
check '  R1d ...minted once, and the gate is stamped pinged' \
  '[[ "$(cat "$MINT_LOG")" == DIVE-7127 && "$(db "SELECT gate_pinged_at IS NOT NULL FROM tasks WHERE ident='"'"'DIVE-7127'"'"';")" == 1 ]]' \
  "mints=$(cat "$MINT_LOG")"

reset; mk_gate DIVE-7127 main
got=$(root_send $'DIVE-7127\n\n')
check "R2 another seat's gate is refused, nothing minted or sent" \
  '[[ "${got%%|*}" != 0 && "$got" == *"filed by main, not oinoa"* && ! -s "$MINT_LOG" && ! -s "$SEND_TEXT" ]]' "got=$got"

for shape in answered closed manual nokey; do
  reset
  case "$shape" in
    answered) mk_gate DIVE-7127 oinoa secret blocked yes ;;
    closed)   mk_gate DIVE-7127 oinoa secret 'done' ;;
    manual)   mk_gate DIVE-7127 oinoa manual ;;
    nokey)    mk_gate DIVE-7127 oinoa secret blocked "" "" ;;
  esac
  got=$(root_send $'DIVE-7127\n\n')
  check "R3 refused on a gate that is ${shape}, nothing minted or sent" \
    '[[ "${got%%|*}" != 0 && "$got" == *"no open secret gate"* && ! -s "$MINT_LOG" && ! -s "$SEND_TEXT" ]]' "got=$got"
done

reset; mk_gate DIVE-7127 oinoa
printf 'task=DIVE-7127\nkey=CLERK_SECRET_KEY\nconnector=tools\nexpires=%s\n' "$(( $(date +%s) + 600 ))" >"$SECRET_DROP_DIR/live"
got=$(root_send $'DIVE-7127\n\n')
check 'R4 a link for the gate is still live: refused, nothing minted or sent (no paging loop)' \
  '[[ "${got%%|*}" != 0 && "$got" == *"already live"* && ! -s "$MINT_LOG" && ! -s "$SEND_TEXT" ]]' "got=$got"

reset; mk_gate DIVE-7127 oinoa
_gate_is_root() { return 1; }
got=$(root_send $'DIVE-7127\n\n')
check 'R5a not root: refused' '[[ "${got%%|*}" != 0 && "$got" == *"privileged internal primitive"* && ! -s "$MINT_LOG" ]]' "got=$got"
_gate_is_root() { return 0; }
got=$(SUDO_UID='' root_send $'DIVE-7127\n\n')
check 'R5b no sudo caller: refused' '[[ "${got%%|*}" != 0 && "$got" == *"requires sudo from an agent seat"* && ! -s "$MINT_LOG" ]]' "got=$got"
got=$(SUDO_UID=1999 root_send $'DIVE-7127\n\n')
check 'R5c a caller that is no seat: refused' '[[ "${got%%|*}" != 0 && "$got" == *"is not an agent seat"* && ! -s "$MINT_LOG" ]]' "got=$got"
got=$(root_send $'DIVE-7127\n\n' DIVE-7127)
check 'R5d an argument: refused (the grant is the exact path)' '[[ "${got%%|*}" != 0 && "$got" == *"takes no arguments"* && ! -s "$MINT_LOG" ]]' "got=$got"
got=$(root_send $'DIVE-7127; rm -rf /\n\n')
check 'R5e a malformed ident: refused' '[[ "${got%%|*}" != 0 && "$got" == *"expected a task ident"* && ! -s "$MINT_LOG" ]]' "got=$got"

reset; mk_gate DIVE-7127 oinoa; SEND_OK=0
got=$(root_send $'DIVE-7127\n\n')
live=$(ls "$SECRET_DROP_DIR" | wc -l | tr -d ' ')
check 'R6 a send nobody received: refused, and the link it minted is burned' \
  '[[ "${got%%|*}" != 0 && "$got" == *"not delivered"* && "$(cat "$MINT_LOG")" == DIVE-7127 && "$live" == 0 && "$got" != *"$TOKEN"* ]]' \
  "got=$got live=$live"
SEND_OK=1

# ======================= A: no alert text in a process argv ===================
CURL_ARGV="$TMP/curl.argv"; CURL_SEEN="$TMP/curl.seen"
curl() {
  printf '%s\n' "$@" >"$CURL_ARGV"
  local a; : >"$CURL_SEEN"
  for a in "$@"; do
    case "$a" in text@*|reply_markup@*) cat "${a#*@}" >>"$CURL_SEEN"; printf '\n' >>"$CURL_SEEN" ;; esac
  done
  printf '{"ok":true,"result":{"message_id":7}}'
}
unset FIVEDIVE_NOTIFY_DRYRUN
MARKUP='{"inline_keyboard":[[{"text":"🔑 Open secure link","url":"'"$URL"'"}]]}'
nsendfiles() { local f n=0; for f in "${TMPDIR:-/tmp}"/5dive-send.*; do [[ -e "$f" ]] && n=$((n+1)); done; printf '%s' "$n"; }
before=$(nsendfiles)
resp=$(_mirror_send tok-oinoa 1234567890 "" "🔑 Paste it here: ${URL}" "$MARKUP")
after=$(nsendfiles)
check 'A1 neither the text nor the keyboard is in curl argv, and both still reach Telegram, byte for byte' \
  '[[ "$(cat "$CURL_ARGV")" != *"$TOKEN"* && "$(cat "$CURL_SEEN")" == "🔑 Paste it here: ${URL}"$'"'"'\n'"'"'"${MARKUP}" && "$resp" == *"\"ok\":true"* ]]' \
  "argv=$(cat "$CURL_ARGV") seen=$(cat "$CURL_SEEN") resp=$resp"
check '  A1b ...and the files are gone afterwards' '[[ "$after" == "$before" ]]' "before=$before after=$after"
unset -f curl

# =================== G: the grant in the standard sudoers template ============
sud=$(render_standard_sudoers agent-oinoa 0 0)
check 'G1 the standard template grants the exact verb, no wildcard' \
  'grep -qx "agent-oinoa ALL=(root) NOPASSWD: /usr/local/bin/5dive _secret_link_notify" <<<"$sud" && ! grep -q "_secret_link_notify \*" <<<"$sud"' \
  "$(grep _secret_link_notify <<<"$sud")"
check '  G1b ...and still classifies cli-scoped with no extra entries' \
  '[[ "$(classify_sudo_grant <<<"$sud")" == "cli-scoped|root|0" ]]' "$(classify_sudo_grant <<<"$sud")"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
