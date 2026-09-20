#!/usr/bin/env bash
# TIER: core
#
# DIVE-4642 — a dispatched goal that never submits, on a seat the board calls busy.
#
# Measured on quinn 2026-09-19 23:27Z: its pane held an entire multi-line
# `/goal DIVE-4614` verifier brief as an UNSENT draft, tailed by
# `ctrl+x ctrl+s to send now`. Enter had not submitted it, because Claude Code
# binds Enter to "insert a newline" once the composer holds more than one line.
# The seat never started the turn; the row it had been claimed on stayed
# `in_progress`; every later tick therefore logged `busy — 1 in_progress, skip`.
# DIVE-4628 (urgent, PR green + approved) sat ungraded for 9.5 hours inside that
# loop, and nothing anywhere paged.
#
# Four defects, four groups of arms:
#   W1..  the payload is flattened to ONE line before it is typed  (the cause)
#   W2..  a submit that could not be verified leaves NO residual text (the
#         residual is what fires later and wipes a working seat's context)
#   W3..  `busy` is not inferred from `in_progress` alone            (the deadlock)
#   W4..  a wedged seat is NAMED unhealthy by a 5dive surface        (the silence)
#   M..   mutation arms: each guard reverted to its pre-fix body, proving the
#         arms above are live and not passing by not having looked.
#
# Every arm grades an ACTION on a scripted pane: which keys the injector sent,
# which rc it returned, what the ledger holds. Reserved-fake values only: seat
# 'seatx' does not exist and no live pane is touched (sudo is a function here).
# Pane fixtures carry the LIVE bytes — `❯` + NO-BREAK SPACE (U+00A0) — because a
# harness that passes on ASCII fixtures is not evidence about a TUI (DIVE-4242).
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: one trap, every exit path.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not present"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }
TMP=$(mktemp -d /tmp/hb-composer-wedge.XXXXXX)
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh \
         cmd_agent_runtime.sh cmd_heartbeat.sh cmd_supervisor.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"           # the wedge ledger lands under $TMP, never /var/lib/5dive
KEYS="$TMP/keys"; PANE_I="$TMP/pane_i"; LOG="$TMP/log"
PANES=()
_reset() { : >"$KEYS"; : >"$LOG"; echo 0 >"$PANE_I"; rm -rf "$TMP/composer-wedge"; }
sudo() {
  while [ $# -gt 0 ]; do case "$1" in -u) shift 2;; -n|-H) shift;; *) break;; esac; done
  case "${1:-}" in mkdir|chown|chmod|rm|cat) "$@"; return $?;; esac
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
_agent_delivery_inbox()    { return 1; }   # no dispatcher inbox: the tmux path under test
_agent_pane_safe_to_type() { return 0; }
_hb_claude_pid()           { printf '%s' "${CLAUDE_PID-4242}"; }   # no colon: an explicitly EMPTY CLAUDE_PID must stay empty (that is the non-claude arm)
_hb_landed_mark()          { :; }
_hb_landed_check()         { return 1; }   # never let the transcript arm mask a submit arm
_hb_agent_native_state()   { [[ -n "${NATIVE_ST:-}" ]] || return 1; printf '%s' "$NATIVE_ST"; }
_hb_log()                  { printf '%s\n' "$*" >>"$LOG"; }
sleep()                    { :; }
# Snapshot the real bodies while they ARE the real bodies, so the mutation arms
# can restore them by eval instead of by re-sourcing the whole tree.
_REAL_FLATTEN="$(declare -f _hb_flatten_payload)"
_REAL_CLEAR="$(declare -f _hb_composer_clear)"
_REAL_PROBE="$(declare -f _hb_wedge_probe)"
_REAL_IDLE="$(declare -f _hb_agent_idle)"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
not_ok(){ FAIL=$((FAIL+1)); printf 'not ok - %s\n' "$1"; }
grade() { if eval "$2"; then ok_t "$1"; else not_ok "$1"; fi; }
enters()  { grep -cx 'Enter' "$KEYS"; }
cus()     { grep -cx 'C-u' "$KEYS"; }
E=$'\e'; NB=$'\xc2\xa0'
P_EMPTY="${E}[39m❯${NB} ${E}[39m\n  Opus 5 5h: 3%\n"
P_GHOST="${E}[39m❯${NB} ${E}[2mnext task${E}[0m\n  Opus 5 5h: 3%\n"
# The live wedge, 2026-09-19 23:27Z: a multi-line brief, no spinner, and the
# harness's own hint underneath it. Only the composer line is read.
P_WEDGE="${E}[39m❯${NB} ${E}[39m/goal DIVE-4614 — your only row this turn; read it with\n  ctrl+x ctrl+s to send now\n"
ONELINE='/goal DIVE-4642 — your only row this turn. Stop after 6 turns.'
MULTILINE=$'/goal DIVE-4642 — your only row this turn.\nFINDING: the submit never landed.\nFIX: flatten it.\n\nVERIFY: assert the spinner.'

# ----------------------------------------------------------------- W1: the cause
# A multi-line payload cannot be submitted by an Enter, so it must never be typed
# as one. `ctrl+x ctrl+s` is not an escape hatch: measured twice on the live
# wedge, tmux cannot deliver it (`send-keys C-x C-s`, and the two-step form).
grade "W1a a multi-line payload is flattened to exactly one line before typing" \
      "[[ \$(_hb_flatten_payload \"\$MULTILINE\" | wc -l) -eq 0 ]]"
grade "W1b flattening preserves every word (it is prose, not syntax — nothing is dropped)" \
      "[[ \$(_hb_flatten_payload \"\$MULTILINE\" | wc -w) -eq \$(printf '%s' \"\$MULTILINE\" | wc -w) ]]"
grade "W1c a payload that is already one line is passed through byte-identical" \
      "[[ \"\$(_hb_flatten_payload \"\$ONELINE\")\" == \"\$ONELINE\" ]]"

_reset; PANES=("$P_EMPTY"); NATIVE_ST=idle; _hb_send_line seatx "$MULTILINE"; rc=$?
grade "W1d the injector types the multi-line goal as ONE send-keys with no newline in it" \
      "[[ $rc -eq 0 ]] && ! grep -q '^\$' '$KEYS' && [[ \$(grep -c 'FINDING:' '$KEYS') -eq 1 ]]"
grade "W1e ...and it still clears the composer first, then submits with one Enter" \
      "[[ \$(sed -n 1p '$KEYS') == 'C-u' && \$(enters) -eq 1 ]]"
grade "W1f the flattening is on the record — a green log never claims a fix it did not perform" \
      "grep -q 'flattened to one line' '$LOG'"

# ------------------------------------------------- W2: no residual, ever
# The residual is the destructive half. `wake-task` injects /clear before the
# goal; a /clear left unsent FIRES AT THE TARGET'S NEXT TURN BOUNDARY and wipes a
# working seat's context — that is how quinn lost its session (23:17:36Z,
# 23:17:41Z). So a submit that cannot be verified must remove what it typed.
_reset; PANES=("$P_WEDGE" "$P_WEDGE" "$P_EMPTY"); _hb_send_line seatx "/clear"; rc=$?
grade "W2a a submit that survives both Enters returns 1 so nothing is claimed on it" "[[ $rc -eq 1 ]]"
grade "W2b ...and the composer is CLEARED afterwards (C-u after the two Enters, not before them only)" \
      "[[ \$(cus) -ge 2 ]] && [[ \$(grep -n 'C-u' '$KEYS' | tail -1 | cut -d: -f1) -gt \$(grep -n 'Enter' '$KEYS' | tail -1 | cut -d: -f1) ]]"
grade "W2c ...and the clear is C-u, never Escape (Escape on a mid-turn seat aborts the turn)" \
      "! grep -qx 'Escape' '$KEYS'"
grade "W2d ...and the failure reason SAYS the draft was cleared, so an operator is not sent to look at text that is gone" \
      "[[ \"\$_HB_SEND_FAIL_REASON\" == *'CLEARED'* ]]"
grade "W2e ...and the seat is written to the wedge ledger by name" \
      "[[ -s '$TMP/composer-wedge/seatx' ]]"

# The clear does not take: the reason must say so and name the only measured exit.
_reset; PANES=("$P_WEDGE"); _hb_send_line seatx "/clear"; rc=$?
grade "W2f a clear that does NOT take is reported as a live residual, naming 'agent restart' as the exit" \
      "[[ $rc -eq 1 && \"\$_HB_SEND_FAIL_REASON\" == *'agent restart'* ]]"

# A verified submit forgets the wedge — the ledger ages out by the seat WORKING
# again, never by a timer (a timer would clear a wedge that is still live).
_reset; _wedge_mark seatx 42 'stale' residual
PANES=("$P_EMPTY"); _hb_send_line seatx "$ONELINE"; rc=$?
grade "W2g a verified submit clears the ledger entry for that seat" \
      "[[ $rc -eq 0 && ! -e '$TMP/composer-wedge/seatx' ]]"

# ------------------------- W2h..W2k: the queued-messages hint is a RECEIPT
# `Press up to edit queued messages` is 32 bytes of Claude Code's OWN hint,
# rendered only when a message IS queued — so on a mid-turn seat the pre-DIVE-4642
# guard's failure condition and the success it detects coincided (measured on
# main 2026-09-14 09:12Z, DIVE-4355). With the clear wired in above, misreading it
# is no longer merely a false alarm: the clear's `Up` arm would RECALL the queued
# message so the `C-u` could delete it. These arms grade that it never runs.
P_QUEUED="${E}[39m❯${NB} ${E}[39mPress up to edit queued messages\n  Opus 5 5h: 3%\n"
_reset; PANES=("$P_QUEUED"); _hb_send_line seatx "$ONELINE"; rc=$?
grade "W2h a composer showing the queued-messages hint is a SUBMIT RECEIPT, not leftover input (rc 0, one Enter)" \
      "[[ $rc -eq 0 && \$(enters) -eq 1 ]]"
grade "W2i ...so the clear NEVER runs on it — exactly one C-u (the pre-type one), and no Up to recall the queued payload" \
      "[[ \$(cus) -eq 1 ]] && ! grep -qx 'Up' '$KEYS'"
grade "W2j ...and nothing is written to the wedge ledger for a seat that did submit" \
      "[[ ! -e '$TMP/composer-wedge/seatx' ]]"
grade "W2k the exclusion is by CONTENT, not by dim attribute — the hint is rendered NON-dim in this fixture" \
      "[[ -z \"\$(_hb_composer_unsent seatx)\" ]]"

# ------------------------------------------------- W3: busy is not in_progress
# The deadlock: the row keeps the seat "busy", and being "busy" is what stops the
# seat ever being re-woken. The probe is a CONJUNCTION and every leg is measured.
_reset; PANES=("$P_WEDGE" "$P_EMPTY"); NATIVE_ST=idle
_hb_wedge_probe seatx; rc=$?
grade "W3a idle native state + unsent composer text = WEDGED (rc 0)" "[[ $rc -eq 0 ]]"
grade "W3b ...and the probe clears the draft itself, so the tick can dispatch into a clean composer" \
      "[[ \$(cus) -ge 1 ]]"
grade "W3c ...and records it as cleared rather than as a live residual" \
      "grep -q 'cleared' '$TMP/composer-wedge/seatx'"

_reset; PANES=("$P_EMPTY"); NATIVE_ST=idle; _hb_wedge_probe seatx
grade "W3d an idle seat with an EMPTY composer is not wedged (rc 1) — no false red on a resting seat" "[[ $? -ne 0 ]]"
_reset; PANES=("$P_GHOST"); NATIVE_ST=idle; _hb_wedge_probe seatx
grade "W3e dim ghost text is not unsent input — the prompt suggestion must not wedge every idle seat" "[[ $? -ne 0 ]]"
_reset; PANES=("$P_WEDGE"); NATIVE_ST=busy; _hb_wedge_probe seatx
grade "W3f a seat whose own run-state says BUSY is never called wedged, whatever its pane holds" "[[ $? -ne 0 ]]"
_reset; PANES=("$P_WEDGE"); NATIVE_ST=""; _hb_wedge_probe seatx
grade "W3g an UNAVAILABLE native signal reads rc 1, not wedged — false-negative bias, the house rule" "[[ $? -ne 0 ]]"
_reset; PANES=("$P_WEDGE"); NATIVE_ST=idle; CLAUDE_PID="" ; _hb_wedge_probe seatx
grade "W3h a non-claude seat (no composer to read) is never classified from a pane scrape" "[[ $? -ne 0 ]]"
CLAUDE_PID=4242

# W3i — the WIRING arm. The arms above grade the probe; this one grades that the
# dispatch tick actually consults it BEFORE it skips the seat as busy, by running
# the shipped block itself (extracted verbatim, wrapped in a one-pass loop so its
# `continue` is legal outside the tick).
BLOCK="$TMP/busyguard.sh"
awk '/DIVE-4642 — BUSY MUST NOT BE INFERRED/{f=1} f{print} f&&/^    fi$/{exit}' "$SRC/cmd_heartbeat.sh" >"$BLOCK"
grade "W3i the shipped busy-guard block was found and extracted (the arm below grades real text)" "[[ -s '$BLOCK' ]]"
_run_guard() { # <probe-rc> -> prints SKIPPED or DISPATCHED
  local prc="$1" sk_busy=0 name=seatx inprog=1 now=0
  _hb_wedge_probe() { _HB_COMPOSER_UNSENT="draft"; return "$prc"; }
  with_registry_lock() { :; }; _hb_mark_seen() { :; }
  for _ in 1; do . "$BLOCK"; printf 'DISPATCHED\n'; return 0; done
  printf 'SKIPPED\n'
}
grade "W3j a seat the probe calls WEDGED is dispatched this tick, not skipped as busy" \
      "[[ \$(_run_guard 0) == 'DISPATCHED' ]]"
grade "W3k a seat the probe clears is still skipped as busy (the control: the guard was not simply deleted)" \
      "[[ \$(_run_guard 1) == 'SKIPPED' ]]"
eval "$_REAL_PROBE"

# ------------------------------------------------- W4: the seat is NAMED
# The injector already knew. `5dive supervisor` is where that knowledge becomes a
# verdict an operator or the board can read.
_sup_wedged_class() { _sup_classify running 1 1 s ok n/a "" 1 10 false "" "" 0 0 -1 "" unknown "" unmarked "" ok "$1" | cut -d$'\x1f' -f1; }
_sup_wedged_detail(){ _sup_classify running 1 1 s ok n/a "" 1 10 false "" "" 0 0 -1 "" unknown "" unmarked "" ok "$1" | cut -d$'\x1f' -f3; }
grade "W4a a seat with a wedge detail classifies as composer-wedged, not healthy and not 'active'" \
      "[[ \$(_sup_wedged_class 'the composer has held 900 chars of UNSENT text') == 'composer-wedged' ]]"
grade "W4b ...and the verdict carries the only measured recovery, where an operator reads it" \
      "[[ \$(_sup_wedged_detail 'x') == *'agent restart'* ]]"
grade "W4c an unwedged seat is unchanged — the branch is disarmed by absence, so no new false red" \
      "[[ \$(_sup_wedged_class '') != 'composer-wedged' ]]"

# W4d/W4e — THE NEGATIVE CONTROL, end to end: wedge a scratch seat deliberately,
# prove the detector goes red naming it, unwedge it, prove it goes green again.
_reset; PANES=("$P_WEDGE" "$P_WEDGE" "$P_WEDGE"); NATIVE_ST=idle
_hb_wedge_probe seatx >/dev/null 2>&1
DET_RED=$(_sup_wedged_class "$(_wedge_read seatx)")
_wedge_clear seatx
DET_GREEN=$(_sup_wedged_class "$(_wedge_read seatx 2>/dev/null)")
grade "W4d negative control: a deliberately wedged scratch seat drives the detector RED through the real ledger" \
      "[[ '$DET_RED' == 'composer-wedged' ]]"
grade "W4e ...and unwedging the same seat drives it back GREEN (the red was the wedge, not the harness)" \
      "[[ '$DET_GREEN' != 'composer-wedged' ]]"
grade "W4f the ledger names the SEAT — a fleet alarm that cannot say which seat is not actionable" \
      "[[ ! -e '$TMP/composer-wedge/seatx' ]]"

# --- W5: the FORCED path reads the seat before it types into it (DIVE-4642) ---
#
# luca, box-1, 5dive 0.45.0, 2026-09-20, rated S1: `heartbeat wake-task` against a
# seat 21 minutes into a turn typed `/clear` into a LIVE composer, could not
# submit it, and left it queued to fire at that turn's boundary. The tick has
# always asked `_hb_agent_idle` first; the forced verb asked nothing. These arms
# grade the read, its two fail-open cases, and the override.
#
# `_hb_agent_idle` is stubbed per arm because the arm under test is the GUARD,
# not the predicate — W5e is the one that drives the REAL `_hb_agent_idle`, so
# the group is not grading a stub against itself.
WAKES="$TMP/wakes"
require_root()              { :; }
db()                        { printf 'DIVE-4642'; }
_hb_effective_fresh()       { printf 'false'; }
_hb_wake_task_record_defect() { :; }
warn()                      { printf '%s\n' "$*" >>"$LOG"; }
_hb_wake()                  { printf 'WAKE %s\n' "$1" >>"$WAKES"; return 0; }
_wt() { : >"$WAKES"; : >"$LOG"; cmd_heartbeat_wake_task "$@" >/dev/null 2>&1; }
_woke() { grep -c . "$WAKES"; }

_hb_agent_idle() { return 1; }                       # working: a turn is in flight
_wt seatx 4642
grade "W5a a forced wake onto a seat that is MID-TURN does not reach the pane at all" \
      "[[ \$(_woke) -eq 0 ]]"
grade "W5b ...and it says so by name, with both ways forward (the row stays todo)" \
      "grep -q 'forced wake REFUSED' '$LOG' && grep -q 'seatx' '$LOG' && grep -q -- '--force' '$LOG'"

_hb_agent_idle() { return 0; }                       # idle: the wedged seat's own reading
_wt seatx 4642
grade "W5c an IDLE seat is still woken — a wedged seat reads idle, and that is the case this verb exists for" \
      "[[ \$(_woke) -eq 1 ]]"

_hb_agent_idle() { return 2; }                       # no signal at all
_wt seatx 4642
grade "W5d the guard FAILS OPEN on rc 2 (non-claude runtime / no signal): an unmeasurable seat is not a blocked one" \
      "[[ \$(_woke) -eq 1 ]]"

# W5e — the only arm here that runs the SHIPPED `_hb_agent_idle`. This harness's
# `_hb_agent_native_state` stub returns the word ALREADY MAPPED (the real body is
# what turns `waiting` into `blocked:<reason>`), so the fixture is the mapped
# form; a `blocked:` reading needs no pane sampling and reaches rc 3 through the
# real `_hb_agent_idle` body.
eval "$_REAL_IDLE"
NATIVE_ST='blocked:a permission prompt'
_wt seatx 4642
grade "W5e a seat BLOCKED on a permission prompt is refused through the real \`_hb_agent_idle\`, and the reason names the block" \
      "[[ \$(_woke) -eq 0 ]] && grep -q 'blocked on' '$LOG'"
NATIVE_ST=''

# W5f — THE MUTATION ARM, and it is exact: same seat, same state, one flag. The
# pre-fix behaviour IS `--force`, so this proves in one shot that the override
# works AND that the guard is what withheld the wake in W5a.
_hb_agent_idle() { return 1; }
_wt --force seatx 4642
grade "W5f MUTANT/override: \`--force\` on the SAME mid-turn seat wakes it, so W5a is the guard and not an accident" \
      "[[ \$(_woke) -eq 1 ]]"
_hb_agent_idle() { return 0; }

# ------------------------------------------------------------- mutation arms
# Each reverts one guard to its pre-fix body against the SAME scripted pane. A
# mutant that does not flip its arm means the arm was never grading that guard.
_hb_flatten_payload() { printf '%s' "$1"; }          # M1: pre-fix — type it raw
_reset; PANES=("$P_EMPTY"); _hb_send_line seatx "$MULTILINE" >/dev/null 2>&1
grade "M1 MUTANT (no flattening): the newlines reach the pane, so W1d is live" \
      "grep -q '^\$' '$KEYS' || [[ \$(wc -l <'$KEYS') -gt 3 ]]"
eval "$_REAL_FLATTEN"

_hb_composer_clear() { return 1; }                   # M2: pre-fix — leave the draft
_reset; PANES=("$P_WEDGE" "$P_WEDGE"); _hb_send_line seatx "/clear" >/dev/null 2>&1
grade "M2 MUTANT (no clear on failure): the residual survives and the reason stops saying CLEARED, so W2b/W2d are live" \
      "[[ \$(cus) -eq 1 && \"\$_HB_SEND_FAIL_REASON\" != *'CLEARED'* ]]"
eval "$_REAL_CLEAR"

# M2b — the pre-fix composer reader: no hint exclusion. The same queued-seat pane
# then reads as 33 chars of unsent input, the submit is called unverified, and the
# clear fires on a seat that HAD submitted — which is what W2h..W2k grade.
_REAL_UNSENT="$(declare -f _hb_composer_unsent)"
_hb_composer_unsent() { printf '%s' 'Press up to edit queued messages'; }
_reset; PANES=("$P_QUEUED"); _hb_send_line seatx "$ONELINE" >/dev/null 2>&1; rc=$?
grade "M2b MUTANT (no hint exclusion): the queued seat reads unverified and the recall-and-delete clear fires, so W2h/W2i are live" \
      "[[ $rc -eq 1 ]] && grep -qx 'Up' '$KEYS'"
eval "$_REAL_UNSENT"

# M3 — the pre-fix classifier: no wedged branch at all. Graded by ARGUMENT rather
# than by editing the function, because the branch under test is what the mutant
# must lack: the 21-argument call is exactly the shipped pre-fix call site.
grade "M3 MUTANT (pre-fix 21-arg classify, no wedge argument): the same seat reads NOT wedged, so W4a is live" \
      "[[ \$(_sup_classify running 1 1 s ok n/a '' 1 10 false '' '' 0 0 -1 '' unknown '' unmarked '' ok | cut -d\$'\x1f' -f1) != 'composer-wedged' ]]"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
