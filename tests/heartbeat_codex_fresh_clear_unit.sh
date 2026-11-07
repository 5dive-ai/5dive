#!/usr/bin/env bash
# TIER: core
#
# DIVE-7870 — `heartbeat --fresh` on a Codex PANE seat must get past /clear.
#
# Box bug 766 (teal-fox, CLI 0.121.0, codex-cli 0.166, 2026-11-07 08:40Z):
#     wake failed at /clear injection (rc 1): submit not accepted (rc 1): the seat
#     was still idle after 5 Enter attempts — the paste never committed
# every tick, forever. The /clear DID land (fresh banner on the pane); the /goal
# was never sent. Cause: the non-claude submit path (DIVE-1217) accepted a line
# only if the seat LEFT idle after Enter, and /clear starts no turn — Codex resets
# and stays idle by design.
#
# Fix: a control line is accepted once it has LEFT the composer. Still verified:
# a control line that stays in the composer fails loudly and is C-u'd, because an
# unsent /clear fires later and wipes a working seat (DIVE-4642).
#
# The stub tmux models a Codex pane: `send-keys -l` types into the composer,
# Enter submits it (or not, per CLEAR_TAKES), C-u empties it, capture-pane draws
# the composer as the last `›` line. `_hb_agent_idle` reads a busy flag that only
# a submitted NON-control line sets — /clear leaves the seat idle, as live.
#
# Reserved-fake values only: seat 'seatx' does not exist; sudo is a function and
# no live pane is touched.
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: one trap, every exit path.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not present"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }
TMP=$(mktemp -d /tmp/codex-fresh-clear.XXXXXX)
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"; _HB_TRANSCRIPT_ROOT=""
KEYS="$TMP/keys"; HBLOG="$TMP/hb.log"; COMP="$TMP/composer"; BUSY="$TMP/busy"; SUB="$TMP/submitted"
CLEAR_TAKES=1      # 1 = Enter on /clear resets the pane (live Codex); 0 = it stays in the composer
PANE_MODE=codex    # codex | blank (unreadable)
SEAT_TYPE=codex

sudo() {
  while [ $# -gt 0 ]; do case "$1" in -u) shift 2;; -n|-H) shift;; *) break;; esac; done
  [[ "${1:-}" == tmux ]] || { "$@"; return $?; }
  shift
  case "${1:-}" in
    has-session) return 0 ;;
    send-keys) shift; local lit=0
               while [ $# -gt 0 ]; do case "$1" in -t) shift 2;; -l) lit=1; shift;; --) shift; break;; *) break;; esac; done
               local key="$*"; printf '%s\n' "$key" >>"$KEYS"
               if (( lit )); then printf '%s' "$(cat "$COMP")$key" >"$COMP"; return 0; fi
               case "$key" in
                 C-u) : >"$COMP" ;;
                 Enter) local c; c=$(cat "$COMP")
                        [[ -z "$c" ]] && return 0
                        if [[ "$c" == "/clear" ]]; then
                          (( CLEAR_TAKES )) && { : >"$COMP"; printf '%s\n' "$c" >>"$SUB"; }
                        else
                          : >"$COMP"; printf '%s\n' "$c" >>"$SUB"; echo 1 >"$BUSY"
                        fi ;;
               esac
               return 0 ;;
    capture-pane)
               [[ "$PANE_MODE" == blank ]] && { printf '\n\n'; return 0; }
               local c; c=$(cat "$COMP")
               printf '%s\n' ">_ OpenAI Codex (v0.166.0)" "" "› [5dive-msg from=ask] earlier message" "• done." ""
               if [[ -n "$c" ]]; then printf '› %s\n' "$c"; else printf '› Ask Codex to do anything\n'; fi
               [[ "$c" == /* ]] && printf '  %s\n' "/clear     start a new chat"
               printf '\n  gpt-5.5 medium · ~/projects\n'
               return 0 ;;
  esac
  return 0
}
_agent_delivery_inbox()    { return 1; }   # no dispatcher inbox: the pane path under test
_agent_pane_safe_to_type() { return 0; }
_hb_claude_pid()           { echo ""; }    # non-claude TUI path (DIVE-1217)
agent_type()               { echo "$SEAT_TYPE"; }
_hb_agent_idle()           { [[ "$(cat "$BUSY")" == 1 ]] && return 1; return 0; }
_hb_log()                  { printf '%s\n' "$1" >>"$HBLOG"; }
_hb_wake_start_unit_if_needed() { return 0; }
_hb_nudge_text()           { echo "/goal ${3} — your only row this turn"; }
db() { case "$1" in *"SELECT status"*) echo "todo" ;; *) echo "" ;; esac; }
sleep()                    { :; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
not_ok(){ FAIL=$((FAIL+1)); printf 'not ok - %s\n' "$1"; }
grade() { if eval "$2"; then ok_t "$1"; else not_ok "$1"; fi; }
_reset() { : >"$KEYS"; : >"$HBLOG"; : >"$COMP"; echo 0 >"$BUSY"; : >"$SUB"
           CLEAR_TAKES=1; PANE_MODE=codex; SEAT_TYPE=codex
           _HB_WAKE_FAIL_STEP=""; _HB_WAKE_FAIL_REASON=""; _HB_SEND_FAIL_REASON=""; }

# === A. the reported repro: fresh wake on a Codex pane seat that stays idle =====
_reset; _hb_wake seatx true 7 DIVE-7; rc=$?
grade "A1 fresh wake on a codex pane seat returns 0 (was: rc 1 at '/clear injection')" "[[ $rc -eq 0 ]]"
grade "A2 ...the /clear was submitted and THEN the /goal was submitted, in that order" \
  "[[ \"\$(cat '$SUB')\" == \$'/clear\n/goal DIVE-7 — your only row this turn' ]]"
grade "A3 ...the /clear was accepted on the first Enter, by the composer check (log names it)" \
  "grep -q \"control line '/clear' accepted: it left the composer (Enter attempt 1)\" '$HBLOG'"
grade "A4 ...and no wake failure was recorded" "[[ -z \"\$_HB_WAKE_FAIL_STEP\" ]] && ! grep -q 'wake FAILED' '$HBLOG'"

# === B. negative: the /clear never leaves the composer -> fails LOUDLY ==========
_reset; CLEAR_TAKES=0; _hb_wake seatx true 7 DIVE-7; rc=$?
grade "B1 a /clear still in the composer after every Enter fails the wake (rc 1)" "[[ $rc -eq 1 ]]"
grade "B2 ...at the '/clear injection' step, naming the control line and the composer" \
  "[[ \"\$_HB_WAKE_FAIL_STEP\" == '/clear injection' ]] && grep -q \"control line '/clear' was still in the composer after 5 Enter attempts\" '$HBLOG'"
grade "B3 ...no /goal was typed or submitted" "! grep -q '^/goal' '$KEYS' && ! grep -q '/goal' '$SUB'"
grade "B4 ...and the residual /clear was C-u'd (composer empty), so it cannot fire later (DIVE-4642)" \
  "[[ -z \"\$(cat '$COMP')\" ]] && [[ \"\$(tail -n1 '$KEYS')\" == C-u ]]"
grade "B5 ...after exactly 5 Enters (same bound as before)" "[[ \$(grep -c '^Enter\$' '$KEYS') -eq 5 ]]"

# === C. a control line on an unreadable pane is NOT accepted ====================
_reset; PANE_MODE=blank; _hb_send_line seatx "/clear"; rc=$?
grade "C1 an unreadable pane + idle seat fails the control line (no false accept)" \
  "[[ $rc -eq 1 ]] && grep -q 'its composer could not be read' '$HBLOG'"

# === D. a TURN-STARTING line keeps the leave-idle check unchanged ===============
# A /goal whose Enter lands but the seat never leaves idle is still a failure:
# leaving the composer is NOT enough for a line that must start a turn.
_reset
_hb_agent_idle() { return 0; }   # the seat never leaves idle
_hb_send_line seatx "/goal DIVE-7 do it"; rc=$?
_hb_agent_idle() { [[ "$(cat "$BUSY")" == 1 ]] && return 1; return 0; }
grade "D1 a /goal on a seat that stays idle still fails with the DIVE-1217 reason" \
  "[[ $rc -eq 1 ]] && grep -q 'the seat was still idle after 5 Enter attempts — the paste never committed' '$HBLOG'"
grade "D2 ...and the composer check was never consulted for it" "! grep -q 'DIVE-7870' '$HBLOG'"

# === E. the composer reader itself ===============================================
pane_of() { PANE_TXT="$1"; }
cap_stub() { printf '%s' "$PANE_TXT"; }
_reader() { # $1 = pane text, $2 = typed text, $3 = seat type -> echoes rc
  local saved; saved=$(declare -f sudo)
  PANE_TXT="$1"; SEAT_TYPE="$3"
  sudo() { while [ $# -gt 0 ]; do case "$1" in -u) shift 2;; *) break;; esac; done; printf '%s' "$PANE_TXT"; }
  _hb_pane_composer_holds seatx "$2"; local r=$?
  eval "$saved"; echo "$r"; }
H_ECHO=$'› /clear\n• ok\n\n› Ask Codex to do anything\n\n  gpt-5.5 medium · ~/p\n'
H_HELD=$'• ok\n\n› /clear\n  /clear  start a new chat\n\n  gpt-5.5 medium · ~/p\n'
H_POP=$'• ok\n\n› /cl\n› /clear  start a new chat\n'
H_NB=$'• ok\n›\xc2\xa0/clear\n'
grade "E1 a '› /clear' ABOVE the composer (history echo) is not read as holding" "[[ \$(_reader \"\$H_ECHO\" /clear codex) -eq 1 ]]"
grade "E2 the composer line '› /clear' reads as holding" "[[ \$(_reader \"\$H_HELD\" /clear codex) -eq 0 ]]"
grade "E3 a glyph-led popup row starting with the line reads as holding (safe side)" "[[ \$(_reader \"\$H_POP\" /clear codex) -eq 0 ]]"
grade "E4 a no-break space after the glyph is handled" "[[ \$(_reader \"\$H_NB\" /clear codex) -eq 0 ]]"
grade "E5 a codex pane with no glyph line at all is 'cannot tell' (2)" "[[ \$(_reader \$'banner\nfooter\n' /clear codex) -eq 2 ]]"
grade "E6 an unknown runtime: the line in the bottom lines reads as holding" "[[ \$(_reader \$'x\n│ /clear │\n' /clear grok) -eq 0 ]]"
grade "E7 an unknown runtime: a reset pane reads as not holding" "[[ \$(_reader \$'welcome\n│ > │\n' /clear grok) -eq 1 ]]"

# === M. mutation: a reader that never sees the line leave = the pre-fix verdict ==
_reset
_hb_pane_composer_holds() { return 0; }
_hb_wake seatx true 7 DIVE-7; rc=$?
grade "M1 MUTANT (composer check disabled) reproduces bug 766: rc 1 at '/clear injection', no /goal sent" \
  "[[ $rc -eq 1 && \"\$_HB_WAKE_FAIL_STEP\" == '/clear injection' ]] && ! grep -q '/goal' '$SUB'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
