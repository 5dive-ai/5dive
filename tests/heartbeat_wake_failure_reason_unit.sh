#!/usr/bin/env bash
# TIER: core
#
# DIVE-4310 — a heartbeat wake that fails NAMES THE STEP THAT FAILED, its exit
# code, and the first line of what the underlying tool said. And `5dive task
# gates` resolves instead of erroring.
#
# DIVE-4279 (#874) fixed exactly one step: tmux send-keys. Re-verified on lodar's
# box (5dive-exact-swallow, 5dive 0.32.0) as STILL NOT FIXED for the wake as a
# whole — every other exit of `_hb_wake` returned a bare 1, and the tick printed
# the bare verdict:
#     [devops] wake failed — will retry next tick
# A seat that fails to wake and logs no reason is the one class of stall nobody
# can diagnose from the log.
#
# Every arm grades an ACTION: which exit was made to fail, and the reason string
# that came back from it. Pre-fix differentials (D1/D2) and a mutation arm (D3)
# prove the arms are pinned to the fix, not to the fixture.
#
# Reserved-fake values only: seat 'seatx' does not exist; sudo/systemctl are
# functions here, so no unit is started and no live pane is touched.
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: one trap, every exit path.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not present"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }
TMP=$(mktemp -d /tmp/wake-fail-reason.XXXXXX)
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"; HBLOG="$TMP/hb.log"; KEYS="$TMP/keys"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
not_ok(){ FAIL=$((FAIL+1)); printf 'not ok - %s\n' "$1"; }
grade() { if eval "$2"; then ok_t "$1"; else not_ok "$1"; fi; }

# ---- fixture seams ------------------------------------------------------------
SC_RC=0; SC_ERR=''            # systemctl start outcome
TS_RC=0; TS_ERR=''            # tmux has-session outcome
IS_ACTIVE_RC=0                # systemctl is-active outcome
SEND_RC=0; SEND_REASON=''     # what the injector reports back
_hb_log() { printf '%s\n' "$1" >>"$HBLOG"; }
sleep()   { :; }
systemctl() {
  case "${1:-}" in
    is-active) return "$IS_ACTIVE_RC" ;;
    start)     [[ -n "$SC_ERR" ]] && printf '%s\n' "$SC_ERR" >&2; return "$SC_RC" ;;
  esac
  return 0
}
sudo() {
  while [ $# -gt 0 ]; do case "$1" in -u) shift 2;; -n|-H) shift;; *) break;; esac; done
  [[ "${1:-}" == tmux ]] || { "$@"; return $?; }
  case "${2:-}" in
    has-session) [[ -n "$TS_ERR" ]] && printf '%s\n' "$TS_ERR" >&2; return "$TS_RC" ;;
    send-keys)   printf '%s\n' "$*" >>"$KEYS"; return 0 ;;
  esac
  return 0
}
_sudo_wake=$(declare -f sudo)
db() { case "$1" in *"SELECT status"*) echo "todo" ;; *COUNT*) echo 0 ;; *) echo "" ;; esac; }
_hb_send_line() { _HB_SEND_FAIL_REASON="$SEND_REASON"; return "$SEND_RC"; }
_hb_loop_terminal_clause() { echo ""; }
_hb_reject_fix_clause()    { echo ""; }
_hb_carryover_clause()     { echo ""; }
_hb_recall_cite()          { echo ""; }
_hb_is_knowledge_task()    { return 1; }
_task_agent_gate_pred()    { echo "1=0"; }
_reset() { : >"$HBLOG"; : >"$KEYS"
           SC_RC=0; SC_ERR=''; TS_RC=0; TS_ERR=''; IS_ACTIVE_RC=0; SEND_RC=0; SEND_REASON=''; FAIL_KEY=''
           _HB_WAKE_FAIL_STEP=""; _HB_WAKE_FAIL_REASON=""; _HB_SEND_FAIL_REASON=""; }

# === A. every exit of _hb_wake names itself, its rc, and the first stderr line ==
_reset; IS_ACTIVE_RC=1; SC_RC=5; SC_ERR=$'Failed to start 5dive-agent@seatx.service: Unit not found.\nSee system logs.'
_hb_wake seatx false 4310 DIVE-4310; rc=$?
grade "A1 systemctl start failure names the step, rc 5 and systemd's first stderr line" \
  "[[ $rc -eq 1 ]] && grep -q 'wake FAILED at systemctl start (5dive-agent@seatx.service) (rc 5): Failed to start 5dive-agent@seatx.service: Unit not found.' '$HBLOG'"
grade "A2 ...and only the FIRST line of stderr is quoted (no multi-line spill)" \
  "! grep -q 'See system logs' '$HBLOG'"
grade "A3 ...and the reason is published for the caller's one-line verdict" \
  "[[ \"\$_HB_WAKE_FAIL_REASON\" == 'systemctl start (5dive-agent@seatx.service) (rc 5)'* && \"\$_HB_WAKE_FAIL_STEP\" == 'systemctl start'* ]]"

_reset; TS_RC=1; TS_ERR="can't find session: agent-seatx"
_hb_wake seatx false 4310 DIVE-4310; rc=$?
grade "A4 a missing tmux session names the PROBE (not 'wake failed') with tmux's words" \
  "[[ $rc -eq 1 ]] && grep -q \"wake FAILED at tmux session probe (agent-seatx has no session after start) (rc 1): can't find session: agent-seatx\" '$HBLOG'"

_reset; SEND_RC=1; SEND_REASON='send-keys/composer clear (C-u) (tmux rc 1): no server running on /tmp/tmux-0/default'
_hb_wake seatx true 4310 DIVE-4310; rc=$?
grade "A5 a failed /clear names the /clear step AND carries the injector's own cause through" \
  "[[ $rc -eq 1 ]] && grep -q 'wake FAILED at /clear injection (rc 1): send-keys/composer clear (C-u) (tmux rc 1): no server running' '$HBLOG'"

_reset; SEND_RC=1; SEND_REASON='pane-safe guard (rc 1): pane is a credential/login prompt, not a chat input (DIVE-2137)'
_hb_wake seatx false 4310 DIVE-4310; rc=$?
grade "A6 a failed nudge names the nudge step, the task, and the guard that refused" \
  "[[ $rc -eq 1 ]] && grep -q 'wake FAILED at nudge injection (/goal DIVE-4310) (rc 1): pane-safe guard (rc 1): pane is a credential/login prompt' '$HBLOG'"

_reset; SEND_RC=1; SEND_REASON=''
_hb_wake seatx false 4310 DIVE-4310; rc=$?
grade "A7 an injector that reports NO reason still yields a complete, readable line" \
  "[[ $rc -eq 1 ]] && grep -q 'wake FAILED at nudge injection (/goal DIVE-4310) (rc 1): <injector reported no reason>' '$HBLOG'"

# === B. the four injector-level causes reach _HB_SEND_FAIL_REASON ==============
# _hb_send_line is the layer BELOW the wake; these are the strings A5/A6 quote.
unset -f _hb_send_line; eval "$(sed -n '/^_hb_send_line() {/,/^}/p' "$SRC/cmd_heartbeat.sh")"
TMUX_ERR='no server running on /tmp/tmux-0/default'
FAIL_KEY=''; ENTER_OK=1
sudo() {
  while [ $# -gt 0 ]; do case "$1" in -u) shift 2;; -n|-H) shift;; *) break;; esac; done
  [[ "${1:-}" == tmux ]] || { "$@"; return $?; }
  shift
  case "${1:-}" in
    send-keys) shift; while [ $# -gt 0 ]; do case "$1" in -t) shift 2;; -l) shift;; --) shift; break;; *) break;; esac; done
               local key="$*"; printf '%s\n' "$key" >>"$KEYS"
               [[ -n "$FAIL_KEY" && "$key" == "$FAIL_KEY" ]] && { printf '%s\n' "$TMUX_ERR" >&2; return 1; }
               return 0 ;;
    capture-pane) printf '%b' "$PANE"; return 0 ;;
  esac
  return 0
}
E=$'\e'; NB=$'\xc2\xa0'
PANE="${E}[39m❯${NB} ${E}[39m\n  Opus 5 5h: 3%\n"
_agent_delivery_inbox()    { return 1; }
_agent_pane_safe_to_type() { return 0; }
_hb_claude_pid()           { echo 4242; }
_hb_landed_check()         { return 1; }
_hb_landed_mark()          { :; }
_hb_verify_submit()        { return 0; }
TEXT='/goal do the thing'

_reset; FAIL_KEY='C-u'; _hb_send_line seatx "$TEXT" >/dev/null 2>&1
grade "B1 a send-keys failure publishes 'send-keys/<step> (tmux rc N): <stderr>'" \
  "[[ \"\$_HB_SEND_FAIL_REASON\" == \"send-keys/composer clear (C-u) (tmux rc 1): \$TMUX_ERR\" ]]"

_reset; _agent_pane_safe_to_type() { _AGENT_PANE_REFUSAL_REASON=unreadable; return 1; }
_hb_send_line seatx "$TEXT" >/dev/null 2>&1
grade "B2 the pane-safe guard's could-not-read refusal is published as its own step" \
  "[[ \"\$_HB_SEND_FAIL_REASON\" == 'pane-safe guard (rc 1): could not read the pane'* ]]"
_reset; _agent_pane_safe_to_type() { _AGENT_PANE_REFUSAL_REASON=credential; return 1; }
_hb_send_line seatx "$TEXT" >/dev/null 2>&1
grade "B3 ...and the credential-prompt refusal is a DIFFERENT published reason" \
  "[[ \"\$_HB_SEND_FAIL_REASON\" == 'pane-safe guard (rc 1): pane is a credential/login prompt'* ]]"
_agent_pane_safe_to_type() { return 0; }

_reset; _agent_delivery_inbox() { echo "$TMP/inbox"; return 0; }
_agent_dispatch_is_tui_control() { return 1; }
_agent_dispatch_inbox_send() { return 7; }
_agent_submit_unconfirmed_reason() { echo "dispatcher inbox never drained (rc $2)"; }
_hb_send_line seatx "$TEXT" >/dev/null 2>&1
grade "B4 a dispatcher-inbox failure names THAT rail and its rc, not the tmux one" \
  "[[ \"\$_HB_SEND_FAIL_REASON\" == 'dispatcher inbox (rc 7): dispatcher inbox never drained (rc 7)' ]]"
_agent_delivery_inbox() { return 1; }

_reset; _hb_verify_submit() { _HB_COMPOSER_UNSENT='irst (verify before relying'; return 1; }
_hb_send_line seatx "$TEXT" >/dev/null 2>&1
grade "B5 an unverified submit publishes the composer remainder as the cause (DIVE-4242)" \
  "[[ \"\$_HB_SEND_FAIL_REASON\" == 'submit unverified (rc 1): the composer still holds 27 chars of non-ghost text'* ]]"
_hb_verify_submit() { return 0; }

# The non-claude Enter loop: it used to return 1 with NOTHING written anywhere.
_reset; _hb_claude_pid() { echo ""; }; _hb_agent_idle() { return 0; }
_hb_send_line seatx "$TEXT" >/dev/null 2>&1
grade "B6 the non-claude Enter loop's exhaustion is no longer silent (5 attempts, named)" \
  "[[ \"\$_HB_SEND_FAIL_REASON\" == 'submit not accepted (rc 1): the seat was still idle after 5 Enter attempts'* ]] && grep -q 'still idle after 5 Enter attempts' '$HBLOG'"
_hb_claude_pid() { echo 4242; }; unset -f _hb_agent_idle

# === C. the healthy path is untouched ==========================================
_reset; _hb_send_line seatx "$TEXT" >/dev/null 2>&1; rc=$?
grade "C1 a clean send is rc 0 and publishes no reason at all" \
  "[[ $rc -eq 0 && -z \"\$_HB_SEND_FAIL_REASON\" ]]"
_hb_send_line() { _HB_SEND_FAIL_REASON="$SEND_REASON"; return "$SEND_RC"; }
eval "$_sudo_wake"     # back to the wake-section seam: has-session answers again
_reset; _hb_wake seatx false 4310 DIVE-4310; rc=$?
grade "C2 a clean wake is rc 0, logs no FAILED line, and leaves the reason empty" \
  "[[ $rc -eq 0 && -z \"\$_HB_WAKE_FAIL_REASON\" ]] && ! grep -q FAILED '$HBLOG'"
_reset; SC_RC=5; SC_ERR='boom'; IS_ACTIVE_RC=1; _hb_wake seatx false 4310 DIVE-4310 >/dev/null 2>&1
SC_RC=0; SC_ERR=''; IS_ACTIVE_RC=0; _hb_wake seatx false 4310 DIVE-4310; rc=$?
grade "C3 a FAILED wake followed by a clean one does not leak the old reason (no stale cause)" \
  "[[ $rc -eq 0 && -z \"\$_HB_WAKE_FAIL_REASON\" ]]"

# === D. differentials + mutation: the arms are live ============================
grade "D1 differential: the tick no longer EMITS the bare 'wake failed' verdict" \
  "! grep -q '_hb_log \"\[\$name\] wake failed —' '$SRC/cmd_heartbeat.sh'"
grade "D2 ...and the tick's verdict now interpolates the published reason" \
  "grep -q 'wake failed at \${_HB_WAKE_FAIL_REASON' '$SRC/cmd_heartbeat.sh' && grep -q 'forced wake FAILED at \${_HB_WAKE_FAIL_REASON' '$SRC/cmd_heartbeat.sh'"

_reset; TS_RC=1; TS_ERR="can't find session: agent-seatx"
_orig_fail=$(declare -f _hb_wake_fail)
_hb_wake_fail() { return 1; }      # the pre-fix world: a bare 1, no reason anywhere
_hb_wake seatx false 4310 DIVE-4310; mut_rc=$?
mut_silent=1; grep -q 'wake FAILED' "$HBLOG" && mut_silent=0
eval "$_orig_fail"
grade "D3 mutation: a reason-less exit returns the SAME rc 1 and logs nothing — A4 is live" \
  "[[ $mut_rc -eq 1 && $mut_silent -eq 1 ]]"
_reset; TS_RC=1; TS_ERR="can't find session: agent-seatx"; _hb_wake seatx false 4310 DIVE-4310 >/dev/null 2>&1
grade "D4 ...and the restored helper names the step again (the restore took)" \
  "grep -q 'wake FAILED at tmux session probe' '$HBLOG'"

# === E. `5dive task gates` resolves (it was 'unknown task command') ============
_gates_seen=0
cmd_task_inbox() { _gates_seen=$((_gates_seen+1)); return 0; }
fail() { printf 'FAIL:%s\n' "$2" >>"$TMP/dispatch.err"; return 1; }
: >"$TMP/dispatch.err"
cmd_task gates >/dev/null 2>&1
grade "E1 'task gates' routes to the inbox verb instead of erroring" \
  "[[ $_gates_seen -eq 1 && ! -s '$TMP/dispatch.err' ]]"
cmd_task inbox >/dev/null 2>&1
grade "E2 ...and 'task inbox' still routes to the same one function (they cannot diverge)" \
  "[[ $_gates_seen -eq 2 ]]"
cmd_task gatez >/dev/null 2>&1
grade "E3 a NEAR-MISS verb is still rejected — the alias is exact, not a prefix match" \
  "[[ $_gates_seen -eq 2 ]] && grep -q 'unknown task command: gatez' '$TMP/dispatch.err'"
grade "E4 the alias is documented in 'task --help' where a reader looks for it" \
  "grep -q 'gates  *alias of' '$SRC/task/dispatch.sh'"

echo "-----"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
