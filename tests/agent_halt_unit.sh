#!/usr/bin/env bash
# TIER: nightly — `5dive agent halt`, graded by simulating a busy seat's turn.
# DIVE-4769 — halting a busy seat must END THE TURN and GIVE THE ROW BACK.
#
# The defect it exists against is DIVE-4724's: `heartbeat wake-task` reaches a
# busy seat and ORPHANS its claim — the row stays in_progress under a turn that
# no longer exists. So the grade is not "did something get typed", it is:
#
#   * ESCAPE is what ends the turn (C-u only edits the composer), and the
#     composer is cleared after it;
#   * a second Escape only when the seat STILL reads busy, never a third;
#   * the claim is handed back through the reaper's own `_hb_reclaim_to_todo`,
#     and a DELIVERED row goes back to the verifier's queue (keep-handoff) and
#     is not clean-reclaimed on top;
#   * --no-requeue ends the turn and leaves the claim alone, and says so;
#   * a board this process cannot reach DEGRADES LOUDLY — it must never print a
#     clean halt over the very orphan the verb exists to prevent;
#   * the notice is delivered on the INTERRUPTING path, so it cannot be spooled
#     behind the turn it is reporting on;
#   * a seat with no tmux session is E_NOT_RUNNING and nothing is typed.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/cmd_agent_runtime.sh

PASS=0; FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMPROOT:-/nonexistent-4769h}"; echo "HARNESS-RC=$rc"' EXIT
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
is() { local l="$1" w="$2" g="$3"; if [[ "$g" == "$w" ]]; then ok_t "$l"; else bad_t "$l" "want=[$w] got=[$g]"; fi; }
has() { local l="$1" n="$2" h="$3"; if [[ "$h" == *"$n"* ]]; then ok_t "$l"; else bad_t "$l" "missing [$n] in [$h]"; fi; }
hasnt(){ local l="$1" n="$2" h="$3"; if [[ "$h" != *"$n"* ]]; then ok_t "$l"; else bad_t "$l" "unexpected [$n] in [$h]"; fi; }

TYPED="${TMPROOT}/typed.log"
RECLAIM="${TMPROOT}/reclaim.log"
export _HALT_SETTLE_SEC=0

# --- boundaries -------------------------------------------------------------
_a2a_queue_dir() { printf '%s\n' "${TMPROOT}/agent-${1}/.5dive/a2a-queue"; }
sudo() {
  local -a a=("$@")
  [[ "${a[0]:-}" == "-n" ]] && a=("${a[@]:1}")
  if [[ "${a[0]:-}" == "-u" ]]; then a=("${a[@]:2}"); fi
  "${a[@]}"
}
tmux() {
  # `has-session` is the presence probe cmd_halt refuses on; everything else is
  # a keystroke we record.
  if [[ "${1:-}" == "has-session" ]]; then return "${NO_SESSION:-0}"; fi
  printf 'TMUX %s\n' "$*" >>"$TYPED"; return 0
}
require_agent()           { :; }
a2a_needs_scoped()        { return "${SCOPED_RC:-1}"; }
_envelope_caller()        { printf 'main\n'; }
_agent_delivery_inbox()   { return 1; }
_agent_pane_safe_to_type(){ return 0; }
_hb_claude_pid()          { printf '4769\n'; }
_hb_verify_submit()       { return 0; }
_wedge_clear()            { :; }
audit_log()               { :; }
# BUSY_SEQ drives consecutive _hb_agent_idle readings: "1 1" = busy, still busy.
_hb_agent_idle() {
  local -a seq=(${BUSY_SEQ:-0})
  local i="${IDLE_I:-0}"
  IDLE_I=$(( i + 1 ))
  local rc="${seq[$i]:-${seq[-1]}}"
  return "$rc"
}
sqlq()      { printf "'%s'" "$1"; }
_hb_ident() { printf 'DIVE-%s' "$1"; }
db() {
  local q="$1"
  if [[ "$q" == *"SELECT id FROM tasks"* ]]; then printf '%s\n' ${ROW_IDS:-}; return 0; fi
  if [[ "$q" == *"SELECT status FROM tasks"* ]]; then printf '%s\n' "${ROW_STATUS:-todo}"; return 0; fi
  return 0
}
_hb_reclaim_to_todo()     { printf 'clean %s %s\n' "$1" "$2" >>"$RECLAIM"; }
_hb_reclaim_to_verifier() { printf 'keep-handoff %s %s\n' "$1" "$2" >>"$RECLAIM"; }

esc_count() { grep -c 'send-keys -t [^ ]* Escape' "$TYPED" 2>/dev/null || true; }
cu_count()  { grep -c 'send-keys -t [^ ]* C-u' "$TYPED" 2>/dev/null || true; }
typed_text(){ cat "$TYPED" 2>/dev/null || true; }
spool_count(){ find "$(_a2a_queue_dir "$1")" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '; }
reset_arm() { : >"$TYPED"; : >"$RECLAIM"; rm -rf "${TMPROOT}/agent-quinn"; IDLE_I=0; }

# --- H1: the whole path on a busy seat holding one row ----------------------
reset_arm
out="$(BUSY_SEQ="1 0" ROW_IDS="4603" ROW_STATUS="in_progress" JSON_MODE=1 \
        cmd_halt quinn --reason="lodar says stop spending on this grade" 2>/dev/null)"
is "H1: was_busy:true"              "true"        "$(jq -r '.data.was_busy' <<<"$out")"
is "H1: one Escape (it went idle)"  "1"           "$(esc_count)"
# The composer clear is asserted by ORDER, not by count: cmd_halt types its own
# C-u after the Escape, and inject_and_submit types one more of its own before
# the notice (DIVE-4246 hygiene). Pinning the count would red the day either
# site changes for an unrelated reason; what this row owns is that the abandoned
# draft is cleared AFTER the turn was ended.
[[ "$(cu_count)" -ge 1 ]] && ok_t "H1: the composer is cleared" \
  || bad_t "H1: the composer is cleared" "no C-u recorded"
is "H1: cleared AFTER the Escape, not before" "Escape" \
   "$(grep -o -e 'Escape' -e 'C-u' "$TYPED" | head -1)"
is "H1: the row is requeued"        "DIVE-4603"   "$(jq -r '.data.requeued[0]' <<<"$out")"
is "H1: the notice was delivered"   "true"        "$(jq -r '.data.notice_delivered' <<<"$out")"
is "H1: the notice was NOT spooled" "0"           "$(spool_count quinn)"
has "H1: the reclaim is the reaper's own primitive" "clean quinn 4603" "$(cat "$RECLAIM")"
has "H1: the seat is told the row went back" "RETURNED TO THE QUEUE" "$(typed_text)"
has "H1: and why"                   "lodar says stop spending" "$(typed_text)"

# --- H2: a DELIVERED row goes back to the VERIFIER, not to its maker --------
# keep-handoff is tried first; when it lands (the row is no longer in_progress)
# the clean reclaim must NOT run on top of it.
reset_arm
BUSY_SEQ="1 0" ROW_IDS="4603" ROW_STATUS="todo" JSON_MODE=1 \
  cmd_halt quinn --reason="moot" >/dev/null 2>&1
has   "H2: keep-handoff attempted"          "keep-handoff quinn 4603" "$(cat "$RECLAIM")"
hasnt "H2: no clean reclaim on top of it"   "clean quinn 4603"        "$(cat "$RECLAIM")"

# --- H3: a second Escape only while it is STILL busy, never a third ---------
reset_arm
BUSY_SEQ="1 1 1" ROW_IDS="" JSON_MODE=1 cmd_halt quinn >/dev/null 2>&1
is "H3: two Escapes when it stayed busy" "2" "$(esc_count)"

# --- H4: --no-requeue ends the turn and leaves the claim alone --------------
reset_arm
out="$(BUSY_SEQ="1 0" ROW_IDS="4603" ROW_STATUS="in_progress" \
        cmd_halt quinn --no-requeue 2>/dev/null | tail -1)"
is  "H4: nothing was reclaimed" "" "$(cat "$RECLAIM")"
is  "H4: the turn still ended"  "1" "$(esc_count)"
has "H4: and the receipt says so" "the claim was left exactly as it was" "$out"

# --- H5: an unreachable board DEGRADES LOUDLY -------------------------------
reset_arm
unset -f db
out="$(BUSY_SEQ="1 0" ROW_IDS="4603" cmd_halt quinn 2>/dev/null | tail -1)"
has "H5: names the unreclaimed row"  "NO row was requeued" "$out"
has "H5: and names the manual check" "task ls --assignee=quinn" "$out"
db() {
  local q="$1"
  if [[ "$q" == *"SELECT id FROM tasks"* ]]; then printf '%s\n' ${ROW_IDS:-}; return 0; fi
  if [[ "$q" == *"SELECT status FROM tasks"* ]]; then printf '%s\n' "${ROW_STATUS:-todo}"; return 0; fi
  return 0
}

# --- H6: no session -> E_NOT_RUNNING, and nothing is typed ------------------
reset_arm
_rc=0
out="$(NO_SESSION=1 BUSY_SEQ="1" cmd_halt quinn 2>&1)" || _rc=$?
is  "H6: rc $E_NOT_RUNNING"   "$E_NOT_RUNNING" "$_rc"
is  "H6: nothing typed"       "0"              "$(esc_count)"
has "H6: names the other verb" "agent stop quinn" "$out"

# --- H7: a scoped caller is refused, and pointed at --urgent ----------------
reset_arm
_rc=0
out="$(SCOPED_RC=0 BUSY_SEQ="1" cmd_halt quinn 2>&1)" || _rc=$?
is  "H7: rc $E_PERMISSION"    "$E_PERMISSION" "$_rc"
is  "H7: nothing typed"       "0"             "$(esc_count)"
has "H7: names the route it CAN use" "--urgent" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
