#!/usr/bin/env bash
# TIER: core
#
# DIVE-4242 — the heartbeat injector VERIFIES its submit and clears the composer
# before typing. Measured 2026-09-10 15:43Z on ops: `_hb_send_line` typed a /goal,
# fired Enter, returned 0, the tick claimed the row in_progress — and the pane
# showed `❯ [Pasted text #7]irst (verify before relying...` (the nudge's own tail,
# NOT dim) sitting unsent, so every later tick read 'busy — 1 in_progress, skip'
# for a task the seat never received. Correct typing wired to no receipt.
#
# Every arm grades an ACTION on a scripted pane: the keys the injector sent and
# the rc it returned. Ghost text (CC 2.1.267 promptSuggestion, DIM `ESC[2m`) is a
# fixture too, because reading it as unsent input would make the verify red on
# every idle seat. A mutation arm proves the failing arm is live: with the verify
# stubbed to always-pass, the stuck fixture returns 0 again.
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
TMP=$(mktemp -d /tmp/send-line-verify.XXXXXX)
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"
KEYS="$TMP/keys"; HBLOG="$TMP/hb.log"; PANE_I="$TMP/pane_i"
PANES=()
_reset() { : >"$KEYS"; : >"$HBLOG"; echo 0 >"$PANE_I"; }
# Fake sudo: `sudo -u agent-x tmux send-keys ...` logs the keystroke; `capture-pane`
# returns the next scripted pane (the last one repeats). Counter lives in a file
# because capture-pane is called inside $(...) subshells.
sudo() {
  while [ $# -gt 0 ]; do case "$1" in -u) shift 2;; -n|-H) shift;; *) break;; esac; done
  [[ "${1:-}" == tmux ]] || return 0
  shift
  case "${1:-}" in
    send-keys) shift; while [ $# -gt 0 ]; do case "$1" in -t) shift 2;; -l) shift;; --) shift; break;; *) break;; esac; done
               printf '%s\n' "$*" >>"$KEYS"; return 0;;
    capture-pane) local i n; i=$(cat "$PANE_I"); n=${#PANES[@]}; (( i >= n )) && i=$((n-1))
               echo $(( $(cat "$PANE_I") + 1 )) >"$PANE_I"; printf '%b' "${PANES[$i]}"; return 0;;
  esac
  return 0
}
_agent_delivery_inbox()  { return 1; }   # no dispatcher inbox: the tmux path under test
_agent_pane_safe_to_type() { return 0; }
_hb_claude_pid()         { echo 4242; }  # claude path (immediate Enter + verify)
_hb_log()                { printf '%s\n' "$1" >>"$HBLOG"; }
sleep()                  { :; }
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
not_ok(){ FAIL=$((FAIL+1)); printf 'not ok - %s\n' "$1"; }
grade() { if eval "$2"; then ok_t "$1"; else not_ok "$1"; fi; }
enters() { grep -cx 'Enter' "$KEYS"; }
E=$'\e'; NB=$'\xc2\xa0'   # CC renders "❯" + NO-BREAK SPACE (U+00A0), exactly as live panes show it
P_EMPTY="${E}[39m❯${NB} ${E}[39m\n  Opus 5 5h: 3%\n"
P_GHOST="${E}[39m❯${NB} ${E}[2mnext task${E}[0m\n  Opus 5 5h: 3%\n"
P_STUCK="${E}[38;5;246m❯${NB} ${E}[39m[Pasted text #7]irst (verify before relying)\n  Opus 5 5h: 3%\n"
P_NBSP_ONLY="${E}[38;5;246m❯${NB}${E}[39m\n  Opus 5 5h: 3%\n"
P_NOGLYPH="  booting...\n"

# A1 — clean submit: C-u first, payload, one Enter, rc 0.
_reset; PANES=("$P_EMPTY"); _hb_send_line seatx "/goal do the thing"; rc=$?
grade "A1 clean submit returns 0 with exactly one Enter" "[[ $rc -eq 0 && $(enters) -eq 1 ]]"
grade "A2 the injector clears the composer (C-u) BEFORE typing the payload" "[[ \$(sed -n 1p '$KEYS') == 'C-u' && \$(sed -n 2p '$KEYS') == '/goal do the thing' ]]"

# A3 — ghost text after the glyph is NOT unsent input: one Enter, rc 0.
_reset; PANES=("$P_GHOST"); _hb_send_line seatx "/goal do the thing"; rc=$?
grade "A3 dim ghost text is not read as unsent input (rc 0, one Enter)" "[[ $rc -eq 0 && $(enters) -eq 1 ]]"

# A4 — tail sits after the first Enter, clears after the retry: rc 0, two Enters, no UNVERIFIED.
_reset; PANES=("$P_STUCK" "$P_EMPTY"); _hb_send_line seatx "/goal do the thing"; rc=$?
grade "A4 a tail left after the first Enter is retried once and then accepted (rc 0, two Enters)" "[[ $rc -eq 0 && $(enters) -eq 2 ]] && ! grep -q 'submit UNVERIFIED' '$HBLOG'"

# A5 — tail survives both Enters: rc 1, loud log, exactly two Enters (no loop).
_reset; PANES=("$P_STUCK" "$P_STUCK"); _hb_send_line seatx "/goal do the thing"; rc=$?
grade "A5 a tail that survives both Enters returns 1 so the tick does not claim" "[[ $rc -eq 1 && $(enters) -eq 2 ]]"
grade "A6 ...and logs 'submit UNVERIFIED' naming the leftover text" "grep -q \"submit UNVERIFIED.*Pasted text #7\" '$HBLOG'"

# A7 — _hb_composer_unsent as a function: dim-only -> empty; mixed -> the real text; no glyph -> empty.
_reset; PANES=("$P_GHOST");   u1=$(_hb_composer_unsent seatx)
_reset; PANES=("$P_STUCK");   u2=$(_hb_composer_unsent seatx)
_reset; PANES=("$P_NOGLYPH"); u3=$(_hb_composer_unsent seatx)
grade "A7 composer reader: ghost-only -> '' ; stuck -> the visible text ; no glyph -> ''" "[[ -z '$u1' && '$u2' == '[Pasted text #7]irst (verify before relying)' && -z '$u3' ]]"

# A7b — the glyph's trailing NO-BREAK SPACE alone is an EMPTY composer. Measured live
# 2026-09-10 15:58Z on 13 seats: an ASCII-only trim left one char on every idle seat.
_reset; PANES=("$P_NBSP_ONLY"); u4=$(_hb_composer_unsent seatx)
grade "A7b a composer holding only the glyph's U+00A0 reads as empty (live shape on every idle seat)" "[[ -z '$u4' ]]"

# A8 — MUTATION: with the verify stubbed to always-pass, the stuck fixture returns 0 again.
_hb_verify_submit() { return 0; }
_reset; PANES=("$P_STUCK" "$P_STUCK"); _hb_send_line seatx "/goal do the thing"; rc=$?
grade "A8 mutation: dropping the verify turns A5's rc back to 0 — the arm is live" "[[ $rc -eq 0 && $(enters) -eq 1 ]]"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
