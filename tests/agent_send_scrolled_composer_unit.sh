#!/usr/bin/env bash
# TIER: core
#
# DIVE-8957 — a send to an idle seat must not report a submit it did not get
# when the draft is taller than the composer.
#
# Measured 2026-11-21 (olivia, 68x24 pane, CC 2.1.330): ship-watch's
# `agent send olivia --message=<QA-WATCH …>` returned 0 at 04:40Z and 05:45Z and
# both messages sat TYPED, unsent, for 20-90 min. Reproduced on a live 68x24
# pane the same morning: a ~530-char vouched send fills the composer, Claude
# Code scrolls it, drops the `❯` line off the screen and writes the hidden count
# into the top rule (`─── ↑ 2 more ───`). The composer reader keyed on the LAST
# `❯`, found none, and read EMPTY — so an Enter swallowed by the paste ingest
# read as a submit and the retry Enter was never sent.
#
# F arms read the LIVE capture bytes (tests/fixtures/dive8957-scrolled-composer).
# S/R arms drive a stateful fake composer that wraps at the pane width and
# scrolls like the live one. D arms are the DIFFERENTIAL: the pre-fix reader,
# carried verbatim from origin/main 9c41fe6f, on the same inputs.
#
# Reserved-fake values only: seat 'seatx' does not exist; no live pane is touched
# (sudo is a function here).
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
FIXD=tests/fixtures/dive8957-scrolled-composer
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not present"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }
TMP=$(mktemp -d /tmp/scrolled-composer.XXXXXX)
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh \
         cmd_agent_runtime.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
not_ok(){ FAIL=$((FAIL+1)); printf 'not ok - %s\n' "$1"; }
grade() { if eval "$2"; then ok_t "$1"; else not_ok "$1"; fi; }

# The pre-fix reader, verbatim from origin/main 9c41fe6f (src/cmd_heartbeat.sh),
# minus its comments. Renamed so the shipped one stays loaded beside it.
_prefix_composer_unsent() {
  local name="$1" raw blk line="" l c esc=$'\e' first=1 bordered=0
  local -a cont=()
  raw=$(sudo -u "agent-${name}" tmux capture-pane -e -p -t "agent-${name}" 2>/dev/null) || { printf ''; return 0; }
  blk=$(awk '/❯/ { b = "" ; f = 1 } f { b = b $0 "\n" } END { printf "%s", b }' <<<"$raw")
  [[ -n "$blk" ]] || { printf ''; return 0; }
  blk=$(sed -E "s/${esc}\[2m[^${esc}]*(${esc}\[0m|${esc}\[22m)//g; s/${esc}\[[0-9;?]*[A-Za-z]//g" <<<"$blk")
  blk="${blk//$'\xc2\xa0'/ }"
  while IFS= read -r l; do
    l="${l//[$'\t\r']/ }"
    (( first )) && l="${l#*❯}"
    c="${l#"${l%%[![:space:]]*}"}"; c="${c%"${c##*[![:space:]]}"}"
    if (( first )); then first=0; line="$c"; continue; fi
    [[ "$c" == ─* ]] && { bordered=1; break; }
    cont+=("$c")
  done <<<"$blk"
  if (( bordered )); then
    local -a parts=("$line" "${cont[@]}"); line=""
    for c in "${parts[@]}"; do
      case "$c" in ''|'Press up to edit queued messages'|'ctrl+x ctrl+s to send now') continue ;; esac
      line="${line:+$line }$c"
    done
  fi
  case "$line" in
    'Press up to edit queued messages'|'ctrl+x ctrl+s to send now') line="" ;;
  esac
  printf '%s' "$line"
}
_REAL_UNSENT="$(declare -f _hb_composer_unsent)"

# ------------------------------------------------- F: the live capture bytes
FIX=""
sudo() { [[ " $* " == *" capture-pane "* ]] && { cat "$FIX"; return 0; }; return 0; }
FIX="$FIXD/scrolled-draft.txt"
got=$(_hb_composer_unsent seatx)
grade "F1 a live scrolled draft (no \`❯\` on the pane, \`↑ 2 more\` in the rule) reads as UNSENT, with its hidden count" \
      "[[ \"\$got\" == '[↑ 2 more lines] (checked 2026-11-21T05:45:58Z).'* ]]"
grade "F2 ...and carries the visible tail, up to the bottom rule and no further (footer excluded)" \
      "[[ \"\$got\" == *'tell main hold.' && \"\$got\" != *Haiku* ]]"
FIX="$FIXD/idle-after-clear.txt"
grade "F3 control: the same pane after the clear (dim ghost text, a PAST user message with \`❯\` above) reads EMPTY" \
      "[[ -z \"\$(_hb_composer_unsent seatx)\" ]]"
FIX="$FIXD/scrolled-draft.txt"
grade "D1 DIFFERENTIAL: the pre-fix reader reads the live scrolled draft as EMPTY — the defect, on real bytes" \
      "[[ -z \"\$(_prefix_composer_unsent seatx)\" ]]"

# ---------------------------------------------- the wrapping, scrolling fake
# State lives in files because capture-pane runs inside $(...) subshells.
#   $C        composer logical lines; the cursor is at the end of the last one
#   $SUB      every submitted message, records separated by a ^^^ line
#   $SWALLOW  how many upcoming Enters are eaten as a newline (the race)
W=66; H=7   # text columns and visible composer rows at the seats' 68x24
C="$TMP/composer"; SUB="$TMP/submitted"; SWALLOW="$TMP/swallow"; KEYS="$TMP/keys"
_reset() { printf '' >"$C"; : >"$SUB"; : >"$KEYS"; echo 0 >"$SWALLOW"; }
_lines() { local -n _a=$1; mapfile -t _a <"$C"; (( ${#_a[@]} )) || _a=(""); }
_put()   { local -n _b=$1; printf '%s\n' "${_b[@]}" >"$C"; }
_rows() {   # the composer's visual rows: each logical line wrapped at $W
  local -a L; _lines L; local l
  for l in "${L[@]}"; do
    if [[ -z "$l" ]]; then printf '\n'; continue; fi
    while (( ${#l} > W )); do printf '%s\n' "${l:0:W}"; l="${l:W}"; done
    printf '%s\n' "$l"
  done
}
_key() {
  local -a L; _lines L; local n=${#L[@]} last k
  case "$1" in
    C-u)    last="${L[n-1]}"; k=$(( ${#last} % W )); (( k == 0 && ${#last} > 0 )) && k=$W
            L[n-1]="${last:0:${#last}-k}" ;;                     # kills ONE visual row (measured)
    BSpace) if [[ -n "${L[n-1]}" ]]; then L[n-1]="${L[n-1]%?}"
            elif (( n > 1 )); then unset 'L[n-1]'; fi ;;
    Enter)  if (( $(cat "$SWALLOW") > 0 )); then
              echo $(( $(cat "$SWALLOW") - 1 )) >"$SWALLOW"; L+=("")
            else
              local joined; joined=$(printf '%s\n' "${L[@]}")
              [[ -n "${joined//[[:space:]]/}" ]] && printf '%s\n^^^\n' "$joined" >>"$SUB"
              L=("")
            fi ;;
  esac
  _put L
}
_type() {
  local -a L; _lines L; local n=${#L[@]} first=1 part
  while IFS= read -r part || [[ -n "$part" ]]; do
    if (( first )); then L[n-1]="${L[n-1]}${part}"; first=0; else L+=("$part"); fi
  done <<<"$1"
  _put L
}
E=$'\e'; NB=$'\xc2\xa0'; DASH="────────────────────────────────"
_render() {   # the live layout: rule, (glyph row | `↑ N more` rule), rows, rule, footer
  local -a R; mapfile -t R < <(_rows); local n=${#R[@]} i
  printf '%s\n' "  previous turn output"
  if (( n > H )); then
    printf '%s\n' "${E}[38;5;244m───${E}[39m ${E}[2m↑ $(( n - H )) more${E}[0m ${E}[38;5;244m${DASH}${E}[39m"
    for (( i = n - H; i < n; i++ )); do printf '%s\n' "${E}[39m  ${R[i]}"; done
  else
    printf '%s\n' "${E}[38;5;244m${DASH}${E}[39m"
    printf '%s\n' "${E}[39m❯${NB}${R[0]}"
    for (( i = 1; i < n; i++ )); do printf '  %s\n' "${R[i]}"; done
  fi
  printf '%s\n' "${E}[38;5;244m${DASH}${E}[39m"
  printf '%s\n' "  Haiku 5.5 high"
}
sudo() {
  while [ $# -gt 0 ]; do case "$1" in -u) shift 2;; -n|-H) shift;; *) break;; esac; done
  case "${1:-}" in mkdir|chown|chmod|rm|cat) "$@"; return $?;; esac
  [[ "${1:-}" == tmux ]] || return 0
  shift
  case "${1:-}" in
    send-keys) shift; local lit=0
               while [ $# -gt 0 ]; do case "$1" in -t) shift 2;; -l) lit=1; shift;; --) shift; break;; *) break;; esac; done
               if (( lit )); then printf 'TYPE\n' >>"$KEYS"; _type "$*"
               else local k; for k in "$@"; do printf '%s\n' "$k" >>"$KEYS"; _key "$k"; done; fi
               return 0;;
    capture-pane) _render; return 0;;
  esac
  return 0
}
_agent_delivery_inbox()    { return 1; }
_agent_pane_safe_to_type() { return 0; }
_a2a_should_queue()        { return 1; }
_hb_claude_pid()           { printf '4242'; }
_hb_landed_mark()          { :; }
_hb_landed_check()         { return 1; }
_hb_log()                  { :; }
sleep()                    { :; }
enters()    { grep -cx 'Enter' "$KEYS"; }
submits()   { grep -cxF '^^^' "$SUB"; }
submitted() { sed '/^^^^$/,$d' "$SUB"; }
composer()  { tr -d '\n' <"$C"; }

# The 05:45Z payload's shape: one long line, no newlines, ~560 bytes.
QA="QA-WATCH dive-8946-helper-hide: DIVE-8946 is LIVE (checked 2026-11-21T05:45:58Z). Walk these grid cells (/home/claude/projects/olivia/qa/grid.md): help:phone help:computer. PASS -> 5dive agent send main with exactly: ready in prod: the Help & setup entry is hidden for teams with a first hire; look at my.5dive.ai/team on a phone and a computer  RED -> file the bug row (dev/dev2, high, with the shot), record the cell in the grid, and tell main \"hold: <row>\". Extra words so the draft is taller than the composer viewport at sixty-six columns."
(( ${#QA} > W * H )) || { echo "fixture bug: QA must wrap past $H rows"; exit 1; }

# ------------------------------------------------- S: the swallowed Enter
_reset; echo 1 >"$SWALLOW"; _WAKE_VOUCH=1 inject_and_submit seatx "$QA"; rc=$?
grade "S1 an Enter swallowed under a SCROLLED draft is caught: the retry Enter submits it, rc 0" \
      "[[ $rc -eq 0 && \$(enters) -eq 2 && \$(submits) -eq 1 ]]"
grade "S2 ...and the seat receives the vouched line plus the whole payload" \
      "[[ \"\$(submitted)\" == \"\${_WAKE_TYPED_LINE} \${QA}\"* ]]"

_reset; echo 2 >"$SWALLOW"; _WAKE_VOUCH=1 inject_and_submit seatx "$QA"; rc=$?
grade "S3 both Enters swallowed: rc 1 (send exits E_UNCONFIRMED), never rc 0 on an unsent message" \
      "[[ $rc -eq 1 && \$(submits) -eq 0 ]]"
grade "S4 ...and the tall unsent draft is CLEARED, not left to be glued to the next send" \
      "[[ -z \"\$(composer)\" ]]"

_reset; _WAKE_VOUCH=1 inject_and_submit seatx "$QA"; rc=$?
grade "S5 control: an Enter that is not swallowed submits once, one Enter, no retry" \
      "[[ $rc -eq 0 && \$(enters) -eq 1 && \$(submits) -eq 1 ]]"

_reset; echo 1 >"$SWALLOW"; _hb_send_line seatx "/goal DIVE-8957 — ${QA}"; rc=$?
grade "S6 the heartbeat's own injector catches the same scrolled race (two Enters, one submit)" \
      "[[ $rc -eq 0 && \$(enters) -eq 2 && \$(submits) -eq 1 ]]"

# --------------------------------------- R: a tall leftover before the send
_reset; _type "${QA} ${QA} ${QA}"; inject_and_submit seatx "[from main] short follow-up"; rc=$?
grade "R1 a leftover draft ~4x the viewport is cleared before typing: the seat receives ONLY the new message" \
      "[[ $rc -eq 0 && \"\$(submitted)\" == '[from main] short follow-up' ]]"
grade "R2 ...with C-u/BSpace only, never Escape or Up" \
      "! grep -qxE 'Escape|Up' '$KEYS'"

# ------------------------------------------------------ D: the differential
_hb_composer_unsent() { _prefix_composer_unsent "$@"; }
_reset; echo 1 >"$SWALLOW"; _WAKE_VOUCH=1 inject_and_submit seatx "$QA"; rc=$?
grade "D2 PRE-FIX READER: rc 0 with NOTHING submitted and one Enter — olivia 04:40Z/05:45Z reproduced, so S1 is live" \
      "[[ $rc -eq 0 && \$(submits) -eq 0 && \$(enters) -eq 1 ]]"
_reset; _type "${QA} ${QA} ${QA}"; inject_and_submit seatx "[from main] short follow-up"; rc=$?
grade "D3 PRE-FIX READER: the tall leftover is submitted glued to the new message, so R1 is live" \
      "[[ \"\$(submitted)\" == *'QA-WATCH'*'[from main] short follow-up' ]]"
eval "$_REAL_UNSENT"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
