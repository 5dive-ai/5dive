#!/usr/bin/env bash
# TIER: nightly — the urgent a2a interrupt, graded by simulating a busy seat's turn.
# DIVE-4769 — `agent send --urgent` must REACH a busy seat, and must stay a class.
#
# WHAT THIS GRADES, and it is the row's acceptance:
#   * a plain send to a BUSY seat still spools (DIVE-4214 is not weakened);
#   * --urgent to the SAME busy seat is TYPED, and nothing is spooled;
#   * the receiver can TELL: `urgent=1` in the envelope and the interrupt marker
#     at the head of the payload;
#   * the BOUND refuses an over-long urgent outright and types nothing;
#   * the BUDGET downgrades the 4th urgent in the window to the normal path —
#     the send still happens, `urgent:false` in the receipt, `urgent=1` NOT in
#     the envelope, and it queues because the target is busy;
#   * a caller cannot join the interrupting class permanently: the marker does
#     not leak from an urgent send to the next plain one in the same shell.
#
# Boundaries only are stubbed: tmux, the idle predicate, and `sudo` (reduced to
# "drop the -u <user> prefix and run it here"). _a2a_should_queue, _a2a_queue_put,
# inject_and_submit, cmd_send and the whole of lib/a2a_urgent.sh stay REAL.
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
TMPROOT="$(mktemp -d)"
# Point the budget ledger at the throwaway root BEFORE the lib is sourced: the
# path is resolved once, at definition. The cap itself is deliberately not
# overridable (an override is the exemption the control exists to remove), so
# the arms spend the real budget of 3 against this file.
export A2A_URGENT_LEDGER="${TMPROOT}/a2a-urgent.tsv"
# shellcheck disable=SC1091
source src/cmd_agent_runtime.sh

PASS=0; FAIL=0
trap 'rc=$?; rm -rf "${TMPROOT:-/nonexistent-4769}"; echo "HARNESS-RC=$rc"' EXIT
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
is() {
  local label="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then ok_t "$label"; else bad_t "$label" "want=[$want] got=[$got]"; fi
}
has() {
  local label="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then ok_t "$label"; else bad_t "$label" "missing [$needle] in [$hay]"; fi
}
hasnt() {
  local label="$1" needle="$2" hay="$3"
  if [[ "$hay" != *"$needle"* ]]; then ok_t "$label"; else bad_t "$label" "unexpected [$needle] in [$hay]"; fi
}

TYPED="${TMPROOT}/typed.log"; : >"$TYPED"

# --- boundaries -------------------------------------------------------------
_a2a_queue_dir() { printf '%s\n' "${TMPROOT}/agent-${1}/.5dive/a2a-queue"; }
sudo() {
  local -a a=("$@")
  [[ "${a[0]:-}" == "-n" ]] && a=("${a[@]:1}")
  if [[ "${a[0]:-}" == "-u" ]]; then a=("${a[@]:2}"); fi
  "${a[@]}"
}
tmux() { printf 'TMUX %s\n' "$*" >>"$TYPED"; return 0; }
_agent_delivery_inbox()   { return 1; }
_agent_pane_safe_to_type(){ return 0; }
_hb_claude_pid()          { printf '4769\n'; }
_hb_verify_submit()       { return 0; }
_wedge_clear()            { :; }
wait_agent_input_ready()  { return 0; }
require_agent()           { :; }
mirror_interagent_outbound() { :; }
_buzz_mirror_outbound()   { :; }
_agent_send_row_hint()    { :; }
_agent_body_shell_hint()  { :; }
a2a_needs_scoped()        { return 1; }
a2a_round_guard()         { return 0; }
envelope_tier()           { printf 'admin\n'; }
envelope_via()            { :; }
envelope_provenance()     { printf 'derived\n'; }
_envelope_caller()        { printf "${CALLER:-main}\n"; }
gen_msg_id()              { printf 'u4769\n'; }
# Same stub as tests/a2a_busy_queue_unit.sh: the peer-forgery guard resolves
# `envelope_peer_forgery` from a lib this harness does not source, and a 127
# inside it aborts the send under errexit — a harness fault that would read as a
# send failure.
_agent_refuse_peer_forgery() { :; }
audit_log()               { :; }
_hb_agent_idle() { return "${IDLE_RC:-0}"; }

typed_count() { grep -c -- 'send-keys -t [^ ]* -l --' "$TYPED" 2>/dev/null || true; }
typed_text()  { grep -- 'send-keys -t [^ ]* -l --' "$TYPED" 2>/dev/null || true; }
spool_count() { find "$(_a2a_queue_dir "$1")" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '; }
reset_arm()   { : >"$TYPED"; rm -rf "${TMPROOT}/agent-quinn"; }
reset_budget(){ : >"$A2A_URGENT_LEDGER"; }

# --- T1: the control — DIVE-4214 is not weakened ----------------------------
reset_arm; reset_budget
out="$(IDLE_RC=1 JSON_MODE=1 cmd_send quinn --message="stop grading DIVE-4603" 2>/dev/null)"
is "T1: plain send to a busy seat is queued"   "true" "$(jq -r '.data.queued' <<<"$out")"
is "T1: plain send typed nothing"              "0"    "$(typed_count)"
is "T1: plain send has no urgent key"          "null" "$(jq -r '.data.urgent // "null"' <<<"$out")"

# --- T2: --urgent reaches the SAME busy seat --------------------------------
reset_arm; reset_budget
out="$(IDLE_RC=1 JSON_MODE=1 cmd_send quinn --urgent --message="stop grading DIVE-4603, rubber-stamp it" 2>/dev/null)"
is "T2: urgent send is sent:true"     "true" "$(jq -r '.data.sent' <<<"$out")"
is "T2: urgent:true in the receipt"   "true" "$(jq -r '.data.urgent' <<<"$out")"
is "T2: nothing spooled"              "0"    "$(spool_count quinn)"
[[ "$(typed_count)" -gt 0 ]] && ok_t "T2: typed into the busy pane" \
  || bad_t "T2: typed into the busy pane" "no send-keys recorded"
has "T2: envelope carries urgent=1"   "urgent=1" "$(typed_text)"
has "T2: payload carries the interrupt marker" "URGENT INTERRUPT" "$(typed_text)"

# --- T3: the marker does not leak -------------------------------------------
# The wiki's test for the class is not "does the flag work" but "can a caller
# join it": the next plain send in the same shell must queue again.
reset_arm
out="$(IDLE_RC=1 JSON_MODE=1 cmd_send quinn --message="and another thing" 2>/dev/null)"
is "T3: the next plain send still queues" "true" "$(jq -r '.data.queued' <<<"$out")"
is "T3: nothing typed"                    "0"    "$(typed_count)"

# --- T4: the BOUND refuses, and types nothing -------------------------------
reset_arm; reset_budget
long="$(head -c 401 < /dev/zero | tr '\0' 'x')"
_rc=0
out="$(IDLE_RC=1 cmd_send quinn --urgent --message="$long" 2>&1)" || _rc=$?
is "T4: refused (rc $E_VALIDATION)" "$E_VALIDATION" "$_rc"
has "T4: names the bound"           "bound is 400"  "$out"
is "T4: nothing typed"              "0"             "$(typed_count)"
is "T4: nothing spooled"            "0"             "$(spool_count quinn)"
# 400 exactly is inside the bound.
reset_arm; reset_budget
at="$(head -c 400 < /dev/zero | tr '\0' 'y')"
_rc=0; IDLE_RC=1 cmd_send quinn --urgent --message="$at" >/dev/null 2>&1 || _rc=$?
is "T4: 400 bytes is accepted" "0" "$_rc"

# --- T5: the BUDGET downgrades the 4th, it does not lose it -----------------
reset_budget
for n in 1 2 3; do
  reset_arm
  out="$(IDLE_RC=1 JSON_MODE=1 cmd_send quinn --urgent --message="urgent ${n}" 2>/dev/null)"
  is "T5.${n}: granted" "true" "$(jq -r '.data.urgent' <<<"$out")"
done
reset_arm
out="$(IDLE_RC=1 JSON_MODE=1 cmd_send quinn --urgent --message="urgent 4" 2>/dev/null)"
is "T5.4: urgent:false (downgraded)"        "false" "$(jq -r '.data.urgent' <<<"$out")"
is "T5.4: urgent_requested:true is kept"    "true"  "$(jq -r '.data.urgent_requested' <<<"$out")"
is "T5.4: the message is NOT lost — queued" "true"  "$(jq -r '.data.queued' <<<"$out")"
is "T5.4: nothing typed"                    "0"     "$(typed_count)"
f="$(find "$(_a2a_queue_dir quinn)" -name '*.msg' | head -1)"
hasnt "T5.4: the spooled envelope does not claim urgent=1" "urgent=1" "$(cat "$f")"
hasnt "T5.4: and carries no interrupt marker" "URGENT INTERRUPT" "$(cat "$f")"
is "T5: the ledger recorded exactly the 3 grants" "3" "$(grep -c '^main' "$A2A_URGENT_LEDGER" || true)"
# The budget is PER SENDER: another seat still has its own.
reset_arm
out="$(CALLER=ops IDLE_RC=1 JSON_MODE=1 cmd_send quinn --urgent --message="ops interrupts" 2>/dev/null)"
is "T5: a different sender is not budget-blocked" "true" "$(jq -r '.data.urgent' <<<"$out")"

# --- T6: --urgent + --raw is refused ----------------------------------------
reset_arm; reset_budget
_rc=0
out="$(IDLE_RC=1 cmd_send quinn --urgent --raw --message="no envelope" 2>&1)" || _rc=$?
is "T6: refused (rc $E_USAGE)" "$E_USAGE" "$_rc"
is "T6: nothing typed"         "0"        "$(typed_count)"

# --- T7: an IDLE seat is unchanged by --urgent ------------------------------
# The flag is about the QUEUE decision. Against an idle target there is no queue
# to jump, and the send must behave exactly as it always did.
reset_arm; reset_budget
out="$(IDLE_RC=0 JSON_MODE=1 cmd_send quinn --urgent --message="idle target" 2>/dev/null)"
is "T7: sent:true"     "true" "$(jq -r '.data.sent' <<<"$out")"
is "T7: nothing spooled" "0"  "$(spool_count quinn)"

# --- T8: downgraded AND delivered — the one case where sent:true must still
# say urgent:false. The budget is spent and the target is IDLE, so there is no
# queue to fall into and the send succeeds; a receipt that reported the FLAG
# here would tell the sender it interrupted a seat it did not.
reset_arm; reset_budget
for n in 1 2 3; do IDLE_RC=0 cmd_send quinn --urgent --message="urgent ${n}" >/dev/null 2>&1; done
reset_arm
out="$(IDLE_RC=0 JSON_MODE=1 cmd_send quinn --urgent --message="urgent 4 to an idle seat" 2>/dev/null)"
is "T8: sent:true"                        "true"  "$(jq -r '.data.sent' <<<"$out")"
is "T8: urgent:false (budget was spent)"  "false" "$(jq -r '.data.urgent' <<<"$out")"
is "T8: urgent_requested:true"            "true"  "$(jq -r '.data.urgent_requested' <<<"$out")"
hasnt "T8: and the envelope does not claim it" "urgent=1" "$(typed_text)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
