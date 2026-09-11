#!/usr/bin/env bash
# TIER: core
#
# DIVE-4279 — when the heartbeat injector cannot type, the log NAMES THE STEP and
# quotes what tmux said, and a keystroke failure is checked against the seat's
# transcript before the wake is counted as failed.
#
# Measured 2026-09-11 04:45Z on lodar's box 5dive-exact-swallow (5dive 0.31.0):
#     04:45:20Z [heartbeat] [devops] due + todo DIVE-215 — waking (fresh=false)
#     04:45:24Z [heartbeat] [devops] nudge send failed
#     04:45:24Z [heartbeat] [devops] wake failed — will retry next tick
# Three bare `send-keys ... 2>/dev/null || return 1` calls, so the operator got a
# verdict and no cause. The seat then STARTED the row 23s later, i.e. the tick's
# `woke 0` may also have been a false negative.
#
# Every arm grades an ACTION: which tmux step was made to fail, and the reason
# line + rc that came back. The stub tmux fails one step at a time and writes a
# real tmux error to stderr; the transcript arms use fixture jsonl files on disk.
# A pre-fix differential (D1) and a mutation arm (D2) prove the arms are live.
#
# Reserved-fake values only: seat 'seatx' does not exist; no live pane is touched
# (sudo is a function here) and no path outside $TMP is read.
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: one trap, every exit path.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not present"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }
TMP=$(mktemp -d /tmp/send-line-reason.XXXXXX)
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"
KEYS="$TMP/keys"; HBLOG="$TMP/hb.log"; PANE_I="$TMP/pane_i"; ENTER_N="$TMP/enter_n"
PANES=()
TMUX_ERR='no server running on /tmp/tmux-0/default'
FAIL_KEY=""        # exact keystroke string whose send-keys fails ('' = none)
FAIL_ENTER=0       # which Enter fails (1 = the first, 2 = the retry); 0 = none
_reset() { : >"$KEYS"; : >"$HBLOG"; echo 0 >"$PANE_I"; echo 0 >"$ENTER_N"
           FAIL_KEY=""; FAIL_ENTER=0; TMUX_ERR='no server running on /tmp/tmux-0/default'
           _HB_TRANSCRIPT_ROOT=""; }
# Fake sudo. tmux send-keys logs the keystroke and fails the scripted step with a
# real tmux error on STDERR; tmux capture-pane returns the next scripted pane.
# ANYTHING ELSE RUNS FOR REAL (bash -c/ls/stat/tail), so the transcript arms
# exercise the actual file reads against fixtures in $TMP.
sudo() {
  while [ $# -gt 0 ]; do case "$1" in -u) shift 2;; -n|-H) shift;; *) break;; esac; done
  [[ "${1:-}" == tmux ]] || { "$@"; return $?; }
  shift
  case "${1:-}" in
    send-keys) shift; while [ $# -gt 0 ]; do case "$1" in -t) shift 2;; -l) shift;; --) shift; break;; *) break;; esac; done
               local key="$*"; printf '%s\n' "$key" >>"$KEYS"
               if [[ "$key" == Enter ]] && (( FAIL_ENTER > 0 )); then
                 local n; n=$(( $(cat "$ENTER_N") + 1 )); echo "$n" >"$ENTER_N"
                 (( n == FAIL_ENTER )) && { printf '%s\n' "$TMUX_ERR" >&2; return 1; }
                 return 0
               fi
               [[ -n "$FAIL_KEY" && "$key" == "$FAIL_KEY" ]] && { printf '%s\n' "$TMUX_ERR" >&2; return 1; }
               return 0;;
    capture-pane) local i n; i=$(cat "$PANE_I"); n=${#PANES[@]}; (( i >= n )) && i=$((n-1))
               echo $(( $(cat "$PANE_I") + 1 )) >"$PANE_I"; printf '%b' "${PANES[$i]}"; return 0;;
  esac
  return 0
}
_agent_delivery_inbox()    { return 1; }   # no dispatcher inbox: the tmux path under test
_agent_pane_safe_to_type() { return 0; }
_hb_claude_pid()           { echo 4242; }  # claude path (immediate Enter + verify)
_hb_log()                  { printf '%s\n' "$1" >>"$HBLOG"; }
sleep()                    { :; }
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
not_ok(){ FAIL=$((FAIL+1)); printf 'not ok - %s\n' "$1"; }
grade() { if eval "$2"; then ok_t "$1"; else not_ok "$1"; fi; }
E=$'\e'; NB=$'\xc2\xa0'
P_EMPTY="${E}[39m❯${NB} ${E}[39m\n  Opus 5 5h: 3%\n"
P_STUCK="${E}[38;5;246m❯${NB} ${E}[39m[Pasted text #7]irst (verify)\n  Opus 5 5h: 3%\n"
TEXT='/goal do the thing'

# --- fixtures: a seat transcript store, root/<project>/<session>.jsonl ----------
mk_store() { # $1 = store dir; creates one session file with one user record
  rm -rf "$1"; mkdir -p "$1/proj"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"hello"}}' >"$1/proj/s1.jsonl"
  printf '%s' "$1"
}

# === A. each step names ITSELF and quotes tmux's stderr =========================
_reset; PANES=("$P_EMPTY"); FAIL_KEY='C-u'; _hb_send_line seatx "$TEXT"; rc=$?
grade "A1 a failed C-u returns 1 and logs 'composer clear (C-u) failed' with the tmux error" \
  "[[ $rc -eq 1 ]] && grep -q \"composer clear (C-u) failed (tmux rc 1): ${TMUX_ERR}\" '$HBLOG'"
grade "A2 ...and nothing is typed after the step that failed" "[[ \$(wc -l <'$KEYS') -eq 1 ]]"

_reset; PANES=("$P_EMPTY"); FAIL_KEY="$TEXT"; _hb_send_line seatx "$TEXT"; rc=$?
grade "A3 a failed payload type logs 'payload text failed' with the tmux error" \
  "[[ $rc -eq 1 ]] && grep -q \"payload text failed (tmux rc 1): ${TMUX_ERR}\" '$HBLOG'"

_reset; PANES=("$P_EMPTY"); FAIL_ENTER=1; _hb_send_line seatx "$TEXT"; rc=$?
grade "A4 a failed first Enter logs 'submit (Enter) failed' with the tmux error" \
  "[[ $rc -eq 1 ]] && grep -q \"submit (Enter) failed (tmux rc 1): ${TMUX_ERR}\" '$HBLOG'"

# The retry Enter is its OWN step: first Enter lands, verify still sees the tail,
# the retry is what fails -> the log must say 'submit retry', not 'submit'.
_reset; PANES=("$P_STUCK" "$P_STUCK"); FAIL_ENTER=2; _hb_send_line seatx "$TEXT"; rc=$?
grade "A5 a failed retry Enter is named separately: 'submit retry (Enter) failed'" \
  "[[ $rc -eq 1 ]] && grep -q 'submit retry (Enter) failed (tmux rc 1)' '$HBLOG'"

# Non-claude TUI path (no inner claude pid): the looped Enter names its attempt.
_reset; PANES=("$P_EMPTY"); FAIL_ENTER=1
_hb_claude_pid() { echo ""; }
_hb_send_line seatx "$TEXT"; rc=$?
_hb_claude_pid() { echo 4242; }
grade "A6 the non-claude Enter loop names the attempt: 'submit (Enter, attempt 1) failed'" \
  "[[ $rc -eq 1 ]] && grep -q 'submit (Enter, attempt 1) failed (tmux rc 1)' '$HBLOG'"

# A silent tmux must still produce a readable line, not an empty tail.
_reset; PANES=("$P_EMPTY"); FAIL_KEY='C-u'; TMUX_ERR=''
_hb_send_line seatx "$TEXT" >/dev/null 2>&1
grade "A7 a tmux that wrote nothing to stderr still logs a complete, readable reason" \
  "grep -q 'composer clear (C-u) failed (tmux rc 1): <tmux wrote nothing to stderr>' '$HBLOG'"

# === B. a failed keystroke is checked against the transcript ('woke N' truth) ===
# B1 — the payload DID land (the seat's transcript gains a user record after the
# mark) even though the Enter reported failure: rc 0, and the log says so.
_reset; PANES=("$P_EMPTY"); _HB_TRANSCRIPT_ROOT=$(mk_store "$TMP/st1"); FAIL_ENTER=1
_hb_landed_check_wrap() { :; }
grow() { printf '%s\n' '{"type":"user","message":{"role":"user","content":"'"$TEXT"'"}}' >>"$TMP/st1/proj/s1.jsonl"; }
# grow the transcript at the moment the injector "waits" for the seat to redraw
sleep() { grow; }
_hb_send_line seatx "$TEXT"; rc=$?
sleep() { :; }
grade "B1 a failed Enter whose line DID land returns 0 so the tick's 'woke N' matches reality" "[[ $rc -eq 0 ]]"
grade "B2 ...and the log states the evidence (the transcript gained a user record)" \
  "grep -q 'the keystroke failed but the line DID land' '$HBLOG' && grep -q 'gained a user record after byte' '$HBLOG'"

# B3 — transcript did not grow: still a failure, and the reason says which check said so.
_reset; PANES=("$P_EMPTY"); _HB_TRANSCRIPT_ROOT=$(mk_store "$TMP/st2"); FAIL_ENTER=1
_hb_send_line seatx "$TEXT"; rc=$?
grade "B3 a failed Enter with an unchanged transcript stays a failure (rc 1) naming 'gained no bytes'" \
  "[[ $rc -eq 1 ]] && grep -q 'line did NOT land: transcript s1.jsonl gained no bytes' '$HBLOG'"

# B4 — the transcript grew but with no user record (an assistant line, a summary):
# growth alone must not be read as delivery.
_reset; PANES=("$P_EMPTY"); _HB_TRANSCRIPT_ROOT=$(mk_store "$TMP/st3"); FAIL_ENTER=1
sleep() { printf '%s\n' '{"type":"assistant","message":{"role":"assistant"}}' >>"$TMP/st3/proj/s1.jsonl"; }
_hb_send_line seatx "$TEXT"; rc=$?
sleep() { :; }
grade "B4 transcript growth without a user record is NOT delivery (rc 1, 'gained no user record')" \
  "[[ $rc -eq 1 ]] && grep -q 'grew but gained no user record' '$HBLOG'"

# B5 — a NEW newest transcript (the seat started a fresh session) is not evidence
# for THIS payload.
_reset; PANES=("$P_EMPTY"); _HB_TRANSCRIPT_ROOT=$(mk_store "$TMP/st4"); FAIL_ENTER=1
sleep() { printf '%s\n' '{"type":"user","message":{"role":"user"}}' >"$TMP/st4/proj/s2.jsonl"; touch "$TMP/st4/proj/s2.jsonl"; }
_hb_send_line seatx "$TEXT"; rc=$?
sleep() { :; }
grade "B5 a newer transcript file (a new session) is not evidence the payload landed (rc 1)" \
  "[[ $rc -eq 1 ]] && grep -q 'a new session' '$HBLOG'"

# B6 — no transcript at all: say we could not tell, do not infer either way.
_reset; PANES=("$P_EMPTY"); _HB_TRANSCRIPT_ROOT="$TMP/empty-store"; mkdir -p "$TMP/empty-store"; FAIL_ENTER=1
_hb_send_line seatx "$TEXT"; rc=$?
grade "B6 with no readable transcript the tick fails and says it could not tell (never asserts)" \
  "[[ $rc -eq 1 ]] && grep -q 'could not tell whether the line landed' '$HBLOG'"

# === C. the healthy paths are untouched ========================================
_reset; PANES=("$P_EMPTY"); _hb_send_line seatx "$TEXT"; rc=$?
grade "C1 a clean submit is unchanged: rc 0, C-u then payload then one Enter, no reason lines" \
  "[[ $rc -eq 0 && \$(sed -n 1p '$KEYS') == 'C-u' && \$(sed -n 2p '$KEYS') == '$TEXT' && \$(grep -cx Enter '$KEYS') -eq 1 ]] && ! grep -q failed '$HBLOG'"
grade "C2 a clean submit does not consult the transcript at all (no landed-check log)" \
  "! grep -q 'DIVE-4279' '$HBLOG'"

# === D. differentials: the arms are live =======================================
# D1 — the PRE-FIX body (bare send-keys, stderr discarded) on A1's fixture: same
# rc 1, and NOTHING an operator can act on. This is the reported failure.
_reset; PANES=("$P_EMPTY"); FAIL_KEY='C-u'
_pre_fix_send() {
  local name="$1" text="$2"
  sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" C-u 2>/dev/null || return 1
  sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" -l -- "$text" 2>/dev/null || return 1
  return 0
}
_pre_fix_send seatx "$TEXT"; rc=$?
grade "D1 differential: the pre-fix body returns the same rc 1 and logs NO reason at all" \
  "[[ $rc -eq 1 && ! -s '$HBLOG' ]]"

# D2 — mutation: put the discard back (stderr to /dev/null, no per-step log) and
# A1's assertion goes red, so A1 is pinned to the fix and not to the fixture.
_reset; PANES=("$P_EMPTY"); FAIL_KEY='C-u'
_orig_step=$(declare -f _hb_send_keys_step)
_hb_send_keys_step() { local name="$1"; shift 2
  sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" "$@" 2>/dev/null || return 1; }
_hb_send_line seatx "$TEXT" >/dev/null 2>&1
mut_silent=1; grep -q 'composer clear (C-u) failed' "$HBLOG" && mut_silent=0
eval "$_orig_step"
grade "D2 mutation: restoring the 2>/dev/null discard kills A1's reason line — the arm is live" \
  "[[ $mut_silent -eq 1 ]]"
# and the real implementation is back
_reset; PANES=("$P_EMPTY"); FAIL_KEY='C-u'; _hb_send_line seatx "$TEXT" >/dev/null 2>&1
grade "D3 ...and the un-mutated function logs the reason again (the restore took)" \
  "grep -q 'composer clear (C-u) failed' '$HBLOG'"

echo "-----"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
