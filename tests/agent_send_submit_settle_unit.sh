#!/usr/bin/env bash
# TIER: core
#
# DIVE-5299 — a typed send must not report a submit it did not get, and must not
# submit a stale draft as the head of the next message. Both measured on
# chill-gorge 2026-09-30 (5dive 0.64.0, CC 2.1.285):
#
#   1. 14:31Z: `_deliver` to an idle seat typed a 2-line payload (plus a trailing
#      `\n`), pressed Enter, and ONE capture at +0.33s read an empty `❯` — rc 0,
#      "delivered". The Enter had landed inside Claude Code's paste ingest and
#      was taken as a NEWLINE; the text was drawn into the composer only after
#      the sample. The seat sat idle for 9 hours with the message unsent.
#   2. 23:49Z: the next `agent send` ran its one-C-u hygiene. The cursor sat on
#      the draft's empty LAST line, so C-u cleared nothing, and the seat received
#      the 9-hour-old message glued to the front of the new one.
#
# The pane here is a STATEFUL fake composer, not a scripted capture list, so the
# arms grade what the seat would RECEIVE: C-u kills the cursor's line, BSpace at a
# line start joins it upward, Enter submits (records the composer) unless the
# fixture makes it a swallowed newline, and a swallowed Enter hides the text from
# the next capture — the race. Each mutation arm puts one pre-fix body back and
# must turn its arm red on the same fixture.
#
# Reserved-fake values only: seat 'seatx' does not exist; no live pane is touched
# (sudo is a function here).
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: one trap, every exit path.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not present"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }
TMP=$(mktemp -d /tmp/submit-settle.XXXXXX)
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh \
         cmd_agent_runtime.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"           # the wedge ledger lands under $TMP, never /var/lib/5dive

# ---------------------------------------------------------- the fake composer
# State lives in files because capture-pane runs inside $(...) subshells.
#   $C        composer lines, one per line; the cursor is on the LAST line
#   $SUB      every submitted message, records separated by a ^^^ line
#   $SWALLOW  how many upcoming Enters are eaten as a newline (the race)
#   $HIDE     how many upcoming captures still render the composer EMPTY
C="$TMP/composer"; SUB="$TMP/submitted"; SWALLOW="$TMP/swallow"; HIDE="$TMP/hide"; KEYS="$TMP/keys"
_reset() { printf '' >"$C"; : >"$SUB"; : >"$KEYS"; echo 0 >"$SWALLOW"; echo 0 >"$HIDE"; }
_cnt() { cat "$1"; }
_dec() { echo $(( $(cat "$1") - 1 )) >"$1"; }
_lines() { local -n _a=$1; mapfile -t _a <"$C"; (( ${#_a[@]} )) || _a=(""); }
_put()   { local -n _b=$1; printf '%s\n' "${_b[@]}" >"$C"; }
_key() {
  local -a L; _lines L; local n=${#L[@]}
  case "$1" in
    C-u)    L[n-1]="" ;;                                          # kill to line start (cursor at end)
    BSpace) if [[ -n "${L[n-1]}" ]]; then L[n-1]="${L[n-1]%?}"
            elif (( n > 1 )); then unset 'L[n-1]'; fi ;;          # at a line start: join upward
    Up)     : ;;                                                  # no history in this fake
    Enter)  if (( $(_cnt "$SWALLOW") > 0 )); then
              _dec "$SWALLOW"; L+=(""); echo 1 >"$HIDE"           # eaten as a newline, drawn late
            else
              local joined; joined=$(printf '%s\n' "${L[@]}")
              if [[ -n "${joined//[[:space:]]/}" ]]; then printf '%s\n^^^\n' "$joined" >>"$SUB"; fi
              L=("")
            fi ;;
  esac
  _put L
}
_type() {   # send-keys -l: literal text at the cursor; an embedded \n opens a new line
  local -a L; _lines L; local n=${#L[@]} first=1 part
  while IFS= read -r part || [[ -n "$part" ]]; do
    if (( first )); then L[n-1]="${L[n-1]}${part}"; first=0; else L+=("$part"); fi
  done <<<"$1"
  [[ "$1" == *$'\n' ]] && L+=("")
  _put L
}
E=$'\e'; NB=$'\xc2\xa0'; RULE="${E}[38;5;244m────────────────────────${E}[39m"
_render() {
  local -a L; _lines L; local i
  printf '%s\n' "  previous turn output"
  printf '%s\n' "$RULE"
  if (( $(_cnt "$HIDE") > 0 )); then _dec "$HIDE"; L=(""); fi
  printf '%s\n' "${E}[39m❯${NB}${L[0]}${E}[39m"
  for (( i = 1; i < ${#L[@]}; i++ )); do printf '  %s\n' "${L[i]}"; done
  printf '%s\n' "$RULE"
  printf '%s\n' "  Opus 5 5h: 3%"
}
sudo() {
  while [ $# -gt 0 ]; do case "$1" in -u) shift 2;; -n|-H) shift;; *) break;; esac; done
  case "${1:-}" in mkdir|chown|chmod|rm|cat) "$@"; return $?;; esac
  [[ "${1:-}" == tmux ]] || return 0
  shift
  case "${1:-}" in
    send-keys) shift; local lit=0
               while [ $# -gt 0 ]; do case "$1" in -t) shift 2;; -l) lit=1; shift;; --) shift; break;; *) break;; esac; done
               if (( lit )); then printf 'TYPE %s\n' "$*" >>"$KEYS"; _type "$*"
               else local k; for k in "$@"; do printf '%s\n' "$k" >>"$KEYS"; _key "$k"; done; fi
               return 0;;
    capture-pane) _render; return 0;;
  esac
  return 0
}
_agent_delivery_inbox()    { return 1; }   # no dispatcher inbox: the tmux path under test
_agent_pane_safe_to_type() { return 0; }
_a2a_should_queue()        { return 1; }   # an IDLE seat: the typed path, not the spool
_hb_claude_pid()           { printf '4242'; }
_hb_landed_mark()          { :; }
_hb_landed_check()         { return 1; }   # never let the transcript arm mask a submit arm
_hb_log()                  { :; }
sleep()                    { :; }
_REAL_SETTLED="$(declare -f _hb_submit_settled)"
_REAL_SCRUB="$(declare -f _hb_composer_scrub)"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
not_ok(){ FAIL=$((FAIL+1)); printf 'not ok - %s\n' "$1"; }
grade() { if eval "$2"; then ok_t "$1"; else not_ok "$1"; fi; }
enters()     { grep -cx 'Enter' "$KEYS"; }
submits()    { grep -cxF '^^^' "$SUB"; }
submitted()  { sed '/^^^^$/,$d' "$SUB"; }          # the FIRST message the seat received
composer()   { tr -d '\n' <"$C"; }

MSG2=$'RESULT: listing filed\nNEXT: check the sha of the build\n'   # head's 14:31Z shape: inner + trailing \n
STALE=$'RESULT: old head message\nNEXT: stale instruction\n'

# ------------------------------------------------ S: the submit race (defect 1)
_reset; echo 1 >"$SWALLOW"; inject_and_submit seatx "$MSG2"; rc=$?
grade "S1 an Enter eaten as a newline (text drawn after the first sample) is caught: the retry Enter submits it, rc 0" \
      "[[ $rc -eq 0 && \$(enters) -eq 2 && \$(submits) -eq 1 ]]"
grade "S2 ...and the seat receives exactly the message, without the trailing blank line" \
      "[[ \"\$(submitted)\" == \$'RESULT: listing filed\nNEXT: check the sha of the build' ]]"

_reset; echo 2 >"$SWALLOW"; inject_and_submit seatx "$MSG2"; rc=$?
grade "S3 when BOTH Enters are eaten, the send reports failure (rc 1 -> sent:false), never rc 0 on an unsubmitted message" \
      "[[ $rc -eq 1 && \$(submits) -eq 0 ]]"
grade "S4 ...and the unsent draft is CLEARED, not left to be glued to the next send" \
      "[[ -z \"\$(composer)\" ]]"

_reset; echo 1 >"$SWALLOW"; _hb_send_line seatx "/goal DIVE-5299 — your only row this turn."; rc=$?
grade "S5 the heartbeat's own injector catches the same race (rc 0, two Enters, one submit)" \
      "[[ $rc -eq 0 && \$(enters) -eq 2 && \$(submits) -eq 1 ]]"

_reset; inject_and_submit seatx "$MSG2"; rc=$?
grade "S6 control: an Enter that is NOT eaten submits once, with one Enter and no retry" \
      "[[ $rc -eq 0 && \$(enters) -eq 1 && \$(submits) -eq 1 ]]"

# ------------------------------------- R: the multi-line residual (defect 2)
# The 9-hour draft: two lines plus the trailing empty one, cursor on the last.
_reset; _type "$STALE"; inject_and_submit seatx "[from marketing] start the listing"; rc=$?
grade "R1 a 3-line residual draft is cleared before typing: the seat receives ONLY the new message" \
      "[[ $rc -eq 0 && \"\$(submitted)\" == '[from marketing] start the listing' ]]"
grade "R2 ...cleared with C-u/BSpace only, never Escape (Escape aborts a running turn) and never Up (recalls a queued message)" \
      "! grep -qxE 'Escape|Up' '$KEYS' && grep -qx BSpace '$KEYS'"

_reset; _type "$STALE"; _hb_send_line seatx "/goal DIVE-5299 — your only row this turn."; rc=$?
grade "R3 the heartbeat's injector clears the same residual (the seat receives only the /goal)" \
      "[[ $rc -eq 0 && \"\$(submitted)\" == '/goal DIVE-5299 — your only row this turn.' ]]"

_reset; _type "$STALE"; _hb_composer_clear seatx; rc=$?
grade "R4 the failure-path clear (_hb_composer_clear) empties a multi-line draft too" \
      "[[ $rc -eq 0 && -z \"\$(composer)\" ]]"

# ----------------------------------------------------- U: the composer reader
_reset; _type "$STALE"
grade "U1 the reader sees a multi-line draft's continuation lines (the cursor's empty last line hides nothing)" \
      "[[ \"\$(_hb_composer_unsent seatx)\" == 'RESULT: old head message NEXT: stale instruction' ]]"
_reset; printf '\nNEXT: only on line two\n' >"$C"
grade "U2 a draft whose FIRST line is empty is still a draft" \
      "[[ \"\$(_hb_composer_unsent seatx)\" == 'NEXT: only on line two' ]]"
P_NORULE="${E}[39m❯${NB} ${E}[39m/goal x\n  ctrl+x ctrl+s to send now\n  some status line\n"
_sudo_real="$(declare -f sudo)"
sudo() { [[ " $* " == *" capture-pane "* ]] && { printf '%b' "$P_NORULE"; return 0; }; return 0; }
grade "U3 with no composer rule under the glyph, only the glyph line is read (no new false 'unsent' outside a composer)" \
      "[[ \"\$(_hb_composer_unsent seatx)\" == '/goal x' ]]"
P_HINT="${RULE}\n${E}[39m❯${NB}${E}[2mghost suggestion${E}[0m\n  Press up to edit queued messages\n${RULE}\n"
sudo() { [[ " $* " == *" capture-pane "* ]] && { printf '%b' "$P_HINT"; return 0; }; return 0; }
grade "U4 dim ghost text and the queued-messages hint on a continuation line still read as EMPTY" \
      "[[ -z \"\$(_hb_composer_unsent seatx)\" ]]"
eval "$_sudo_real"

# ------------------------------------------------------------- mutation arms
# M1: the pre-fix verify — one sample at +0.3s.
_hb_submit_settled() { _hb_verify_submit "$1"; }
_reset; echo 1 >"$SWALLOW"; inject_and_submit seatx "$MSG2"; rc=$?
grade "M1 MUTANT (one sample): rc 0 with NOTHING submitted — the 9-hour stall, reproduced, so S1 is live" \
      "[[ $rc -eq 0 && \$(submits) -eq 0 && \$(enters) -eq 1 ]]"
eval "$_REAL_SETTLED"

# M2: the pre-fix hygiene — the single C-u only.
_hb_composer_scrub() { return 0; }
_reset; _type "$STALE"; inject_and_submit seatx "[from marketing] start the listing"; rc=$?
grade "M2 MUTANT (one C-u): the stale draft is submitted glued to the new message — 23:49Z reproduced, so R1 is live" \
      "[[ \"\$(submitted)\" == *'old head message'*'[from marketing] start the listing' ]]"
eval "$_REAL_SCRUB"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
