#!/usr/bin/env bash
# TIER: core
#
# DIVE-5098 #1 — a long payload typed into a claude seat's pane must not arrive
# as a BARE PASTE. Measured on CC 2.1.283 (rig ~/rigs/wake-5098, 2026-09-28):
#   * `send-keys -l "<1094-char /goal line>"` + Enter recorded ONE user record,
#     `<pasted_content>/goal …</pasted_content>`, no typed text, no
#     <command-name> — the model refused it as untrusted and the goal loop the
#     heartbeat dispatches never armed;
#   * `send-keys -l "<fixed line> "`, a gap, then `send-keys -l "<payload>"` +
#     Enter recorded the line as TYPED text ahead of the <pasted_content> block.
# This harness grades the KEYS both typed-send sites emit, on a fake pane (sudo
# is a function; seat 'seatx' does not exist). The live arm is on the row.
#
# Arms, both directions:
#   W1-W4  _wake_split: short -> untouched; long -> constant line + whole text;
#          a long /goal stays whole inside the paste (inert, as today — see the
#          comment on _wake_split); the line is the same constant whatever the
#          payload (DIVE-4826: no board content).
#   H1-H3  _hb_send_line (heartbeat /goal wake): typed line, then body, then Enter.
#   H4     a non-claude seat keeps the single-paste path (no behaviour change).
#   H5     a short control line (`/clear`) is typed exactly as before.
#   I1-I2  inject_and_submit (`agent send` / ask / _deliver): same split.
#   M1     mutation: with _wake_split stubbed out, H1 goes red (the arm is live).
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not present"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }
TMP=$(mktemp -d /tmp/wake-typed-line.XXXXXX)
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh \
         cmd_agent_runtime.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"
KEYS="$TMP/keys"; HBLOG="$TMP/hb.log"
_reset() { : >"$KEYS"; : >"$HBLOG"; }
E=$'\e'; NB=$'\xc2\xa0'
P_EMPTY="${E}[39m❯${NB} ${E}[39m\n  Opus 5 5h: 3%\n"
sudo() {
  while [ $# -gt 0 ]; do case "$1" in -u) shift 2;; -n|-H) shift;; *) break;; esac; done
  [[ "${1:-}" == tmux ]] || return 0
  shift
  case "${1:-}" in
    send-keys) shift; while [ $# -gt 0 ]; do case "$1" in -t) shift 2;; -l) shift;; --) shift; break;; *) break;; esac; done
               printf '%s\n' "$*" >>"$KEYS"; return 0;;
    capture-pane) printf '%b' "$P_EMPTY"; return 0;;
  esac
  return 0
}
_agent_delivery_inbox()    { return 1; }
_agent_pane_safe_to_type() { return 0; }
_a2a_should_queue()        { return 1; }   # a seat that types, not the busy spool
CLAUDE_PID=4242
_hb_claude_pid()           { [[ -n "$CLAUDE_PID" ]] && echo "$CLAUDE_PID"; }
_hb_log()                  { printf '%s\n' "$1" >>"$HBLOG"; }
_hb_landed_mark()          { :; }
sleep()                    { :; }
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
key()   { sed -n "${1}p" "$KEYS"; }

PAD=$(printf 'This sentence is padding for a transport test. %.0s' {1..8})
GOAL="/goal DIVE-9999 — your only row this turn. ${PAD}"
PLAIN="[from agent-main] please look at the attached report. ${PAD}"
LINE="$_WAKE_TYPED_LINE"

# --- W: the pure split -------------------------------------------------------
_wake_split "/clear"
[[ -z "$_WAKE_HEAD" && "$_WAKE_BODY" == "/clear" ]] \
  && ok_t "W1 a short control line is never split" || bad_t "W1 a short control line is never split" "head=$_WAKE_HEAD"
_wake_split "$PLAIN"
[[ "$_WAKE_HEAD" == "$LINE " && "$_WAKE_BODY" == "$PLAIN" ]] \
  && ok_t "W2 a long plain payload gets the typed line; the whole payload is the paste" \
  || bad_t "W2 a long plain payload gets the typed line; the whole payload is the paste" "head=$_WAKE_HEAD"
_wake_split "$GOAL"
[[ "$_WAKE_HEAD" == "$LINE " && "$_WAKE_BODY" == "$GOAL" ]] \
  && ok_t "W3 a long /goal gets the same line in front and stays whole in the paste" \
  || bad_t "W3 a long /goal gets the same line in front and stays whole in the paste" "head=$_WAKE_HEAD body=${_WAKE_BODY:0:40}"
h1="$_WAKE_HEAD"; _wake_split "$PLAIN"
[[ "$h1" == "$_WAKE_HEAD" && "$LINE" != *DIVE-* && ${#LINE} -lt 120 ]] \
  && ok_t "W4 the typed line is one fixed short constant — no board content (DIVE-4826)" \
  || bad_t "W4 the typed line is one fixed short constant — no board content (DIVE-4826)" "$h1 | $_WAKE_HEAD"

# --- H: the heartbeat injector ----------------------------------------------
_reset; CLAUDE_PID=4242; _hb_send_line seatx "$GOAL"; rc=$?
[[ $rc -eq 0 && "$(key 1)" == "C-u" && "$(key 2)" == "$LINE " ]] \
  && ok_t "H1 heartbeat /goal wake: C-u, then the fixed line as its own keystroke" \
  || bad_t "H1 heartbeat /goal wake: C-u, then the fixed line as its own keystroke" "rc=$rc $(head -c 300 "$KEYS")"
[[ "$(key 3)" == "$GOAL" && "$(key 4)" == "Enter" ]] \
  && ok_t "H2 ...then the whole payload as a separate paste, then Enter" \
  || bad_t "H2 ...then the whole payload as a separate paste, then Enter" "$(head -c 300 "$KEYS")"
[[ "$(grep -c . "$KEYS")" -eq 4 ]] \
  && ok_t "H3 nothing else is typed (no duplicated payload)" || bad_t "H3 nothing else is typed" "$(cat "$KEYS")"
_reset; CLAUDE_PID=""
_hb_agent_idle() { return 1; }   # non-claude: the turn started on the first Enter
_hb_send_line seatx "$GOAL"
[[ "$(key 2)" == "$GOAL" ]] \
  && ok_t "H4 a non-claude seat keeps the single-paste path (unchanged)" || bad_t "H4 a non-claude seat keeps the single-paste path" "$(key 2)"
_reset; CLAUDE_PID=4242; _hb_send_line seatx "/clear"
[[ "$(key 2)" == "/clear" && "$(key 3)" == "Enter" ]] \
  && ok_t "H5 a short control line is typed exactly as before" || bad_t "H5 a short control line is typed exactly as before" "$(cat "$KEYS")"

# --- I: the agent send / ask / _deliver injector ------------------------------
_reset; CLAUDE_PID=4242; inject_and_submit seatx "$PLAIN" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && "$(key 1)" == "C-u" && "$(key 2)" == "$LINE " && "$(key 3)" == "$PLAIN" ]] \
  && ok_t "I1 agent send (long): typed line, then the whole message as the paste" \
  || bad_t "I1 agent send (long): typed line, then the whole message as the paste" "rc=$rc $(head -c 300 "$KEYS")"
_reset; inject_and_submit seatx "ok, merged" >/dev/null 2>&1
[[ "$(key 2)" == "ok, merged" ]] \
  && ok_t "I2 agent send (short) is typed exactly as before" || bad_t "I2 agent send (short) is typed exactly as before" "$(cat "$KEYS")"

# --- M: the arm is live ------------------------------------------------------
_wake_split() { _WAKE_HEAD=""; _WAKE_BODY="$1"; }
_reset; CLAUDE_PID=4242; _hb_send_line seatx "$GOAL"
[[ "$(key 2)" == "$GOAL" ]] \
  && ok_t "M1 mutation: with the split disabled, the wake is one bare paste again (H1 would be red)" \
  || bad_t "M1 mutation: with the split disabled, the wake is one bare paste again" "$(key 2)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
