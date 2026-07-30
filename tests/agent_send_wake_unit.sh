#!/usr/bin/env bash
# DIVE-2385 unit: `agent send --wake` — deferred work must not depend on the
# recipient being awake at the instant the scheduler fires.
#
# THE DEFECT this grades. `agent send` needs a live tmux session. Send to an agent
# that is not running and it dies in ~190ms with E_NOT_RUNNING: no queue, no
# retry, no persistence. On 2026-07-30 a transient `systemd-run --on-calendar`
# unit carrying an approved blog post's publish pointer fired exactly on time,
# hit status=8 because the target was asleep, and the message was gone. A one-shot
# .timer is consumed once it fires, so there was no second attempt; the only
# evidence was a .service in `failed` state under /run/systemd/transient/.
#
# WHAT IS ACTUALLY WORTH ASSERTING HERE, and why the obvious test is not it.
# "--wake starts the unit" is the cheap arm and it is nearly worthless on its own:
# it stays green on a build where --wake ALSO starts an agent a human deliberately
# stopped, and on a build where the wake is accepted, ignored, and the send is
# reported as delivered anyway. Both are one direction away from what shipped. So
# every arm below is paired with the mutation it is supposed to catch, and two of
# them (the DISTINCTNESS arm on the failure reason, and the ORDER arm on the
# scoped refusal) exist only because their absence is what would let a wrong build
# pass:
#
#   * refusal-vs-wake are graded as SEPARATE arms with a stub that records whether
#     systemctl was reached, so "refuses on desiredState=stopped" cannot be
#     satisfied by a build that refuses everything;
#   * ABSENT desiredState is its own arm (DIVE-2318, unknown is not a negative) —
#     an agent never start/stop'd through the CLI carries no field at all, which is
#     the common case, and reading absent as "stopped" would make --wake a no-op on
#     exactly the agents that need it;
#   * the reason string is asserted NON-EMPTY on each failure AND asserted EMPTY on
#     success, because a reason that is always set carries no information;
#   * the default path is asserted to still carry the ORIGINAL rc and message,
#     since _task_need_route_deliver (DIVE-2011) polls a detached send's rc for
#     that exact sub-second E_NOT_RUNNING to decide a gate handoff was observed to
#     fail. A --wake that leaked into the default path would convert those into a
#     30s+ boot wait reported as delivered.
#
# Pure: sources the shipped function out of src/, stubs systemctl/sudo/sleep, no
# root, no tmux, no network.
#   bash tests/agent_send_wake_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades. No 2>/dev/null — the helper's own
# stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
eq_t()  { # eq_t <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1 (expected '$2', got '$3')"; fi
}

RT=src/cmd_agent_runtime.sh

# Source the SHIPPED function out of the real source file so this test cannot
# drift from the code that runs. Same awk technique as
# envelope_tier_provenance_unit.sh / agent_send_credential_guard_unit.sh: from the
# function's opening line to the first line that is exactly "}". The declare -F
# guard is what turns a silently-empty extraction into a hard failure.
for fn in agent_wake_for_send agent_prompt_detectable agent_wake_gate_ready; do
  eval "$(awk -v f="^${fn}\\\\(\\\\) \\\\{$" '$0 ~ f { on=1 } on { print } on && $0 == "}" { exit }' "$RT")"
  declare -F "$fn" >/dev/null \
    || { printf 'FATAL - could not extract %s from %s\n' "$fn" "$RT"; exit 1; }
done

# ---------------------------------------------------------------------------
# Stubs. SYSTEMCTL_CALLS is the instrument: an arm that claims "refused" is only
# meaningful if we can see that the unit was never started.
# ---------------------------------------------------------------------------
SYSTEMCTL_CALLS=""
SYSTEMCTL_RC=0
SESSION_UP=0        # what `tmux has-session` reports (0 = up, 1 = absent)
DESIRED=""          # registry desiredState for the target

systemctl() { SYSTEMCTL_CALLS+="$* "; return "$SYSTEMCTL_RC"; }
sleep()     { :; }   # the timeout loop must not actually wait
sudo()      {        # only shape used by the function: sudo -u agent-X tmux has-session -t ...
  local a
  for a in "$@"; do [[ "$a" == "has-session" ]] && return "$SESSION_UP"; done
  return 0
}
registry_read() {
  if [[ -z "$DESIRED" ]]; then
    printf '{"agents":{"marketing":{"type":"claude"}}}'
  else
    printf '{"agents":{"marketing":{"type":"claude","desiredState":"%s"}}}' "$DESIRED"
  fi
}

reset_stubs() { SYSTEMCTL_CALLS=""; SYSTEMCTL_RC=0; AGENT_WAKE_FAIL_REASON=""; }

# --- ARM 1: operator intent. desiredState=stopped must REFUSE, and must not have
# touched the unit. The "did not start it" half is the load-bearing one: without
# it, a build that refuses unconditionally scores identically.
reset_stubs; DESIRED="stopped"; SESSION_UP=1
agent_wake_for_send marketing 2 >/dev/null 2>&1; rc=$?
eq_t "desiredState=stopped refuses" "1" "$rc"
eq_t "desiredState=stopped never starts the unit" "" "$SYSTEMCTL_CALLS"
if [[ "$AGENT_WAKE_FAIL_REASON" == *"desiredState=stopped"* ]]; then
  ok_t "refusal names the operator intent it is honouring"
else
  bad_t "refusal reason does not name desiredState=stopped (got '$AGENT_WAKE_FAIL_REASON')"
fi

# --- ARM 2: DIVE-2318. ABSENT is not "stopped". An agent never start/stop'd
# through the CLI has no desiredState at all; if absent read as stopped, --wake
# would no-op on precisely the agents it exists for.
reset_stubs; DESIRED=""; SESSION_UP=0
agent_wake_for_send marketing 2 >/dev/null 2>&1; rc=$?
eq_t "absent desiredState wakes (unknown is not a negative)" "0" "$rc"
if [[ "$SYSTEMCTL_CALLS" == *"start 5dive-agent@marketing.service"* ]]; then
  ok_t "wake starts the target's own template unit"
else
  bad_t "wake did not start 5dive-agent@marketing.service (calls: '$SYSTEMCTL_CALLS')"
fi

# --- ARM 3: the crash case. desiredState=running + dead unit is exactly what the
# operator asked for, so it wakes.
reset_stubs; DESIRED="running"; SESSION_UP=0
agent_wake_for_send marketing 2 >/dev/null 2>&1
eq_t "desiredState=running wakes" "0" "$?"

# --- ARM 4: DISTINCTNESS. On the success path the reason must be EMPTY. A reason
# that is set unconditionally makes every "reason is non-empty" arm below vacuous.
reset_stubs; DESIRED="running"; SESSION_UP=0
agent_wake_for_send marketing 2 >/dev/null 2>&1
eq_t "success leaves no failure reason" "" "$AGENT_WAKE_FAIL_REASON"

# --- ARM 5: unit starts, session never appears. The caller must NOT be told the
# message was sent, and the reason must say which half failed — the bare
# "is the agent running?" was true and useless to a systemd unit.
reset_stubs; DESIRED="running"; SESSION_UP=1
agent_wake_for_send marketing 2 >/dev/null 2>&1; rc=$?
eq_t "started-but-no-session fails" "1" "$rc"
if [[ "$AGENT_WAKE_FAIL_REASON" == *"did not appear"* ]]; then
  ok_t "no-session reason distinguishes started-but-dead from never-started"
else
  bad_t "no-session reason is uninformative (got '$AGENT_WAKE_FAIL_REASON')"
fi

# --- ARM 6: systemctl itself fails. Distinct reason from ARM 5, so the two
# failure modes are not collapsed into one message.
reset_stubs; DESIRED="running"; SESSION_UP=1; SYSTEMCTL_RC=1
agent_wake_for_send marketing 2 >/dev/null 2>&1; rc=$?
eq_t "systemctl start failure fails" "1" "$rc"
if [[ "$AGENT_WAKE_FAIL_REASON" == *"systemctl start"* ]]; then
  ok_t "start-failure reason names systemctl"
else
  bad_t "start-failure reason does not name systemctl (got '$AGENT_WAKE_FAIL_REASON')"
fi
SYSTEMCTL_RC=0

# ---------------------------------------------------------------------------
# Source-shape arms. These grade properties of cmd_send that a pure unit cannot
# exercise (it needs a real tmux + root), and each one is a mutation that the
# behavioural arms above would NOT catch.
# ---------------------------------------------------------------------------

# The default path must be untouched: same rc, same message, and reached only when
# --wake was NOT passed. _task_need_route_deliver polls for this exact sub-second
# E_NOT_RUNNING.
_default_guard=$(grep -c 'wake )) \\$' "$RT")
if (( _default_guard >= 1 )); then
  ok_t "the E_NOT_RUNNING fail is guarded by (( wake )) rather than replaced"
else
  bad_t "no (( wake )) guard found in front of the default E_NOT_RUNNING fail"
fi
_orig_msg=$(grep -c "fail \"\$E_NOT_RUNNING\" \"tmux session 'agent-\${name}' not found (is the agent running?)\"" "$RT")
if (( _orig_msg >= 1 )); then
  ok_t "the original not-running message survives verbatim on the default path"
else
  bad_t "the default-path E_NOT_RUNNING message was altered or removed"
fi

# The scoped refusal must come BEFORE the exec into _deliver. If it moved after,
# a scoped caller's --wake would be silently dropped and the send reported OK —
# the same lost message, with an exit 0 over it. Order is the property; a grep
# that only checks presence stays green on the broken build.
_refusal_line=$(grep -n 'wake )) && a2a_needs_scoped' "$RT" | head -1 | cut -d: -f1)
_exec_line=$(grep -n 'exec sudo -n /usr/local/bin/5dive agent _deliver' "$RT" | head -1 | cut -d: -f1)
if [[ -n "$_refusal_line" && -n "$_exec_line" ]] && (( _refusal_line < _exec_line )); then
  ok_t "--wake is refused for scoped callers BEFORE the exec into _deliver"
else
  bad_t "scoped --wake refusal is missing or sits after the _deliver exec (refusal=$_refusal_line exec=$_exec_line)"
fi

# The success line must report WHETHER it had to wake the agent. That is the fact
# the failed transient unit could not tell anyone.
if grep -q 'woken:(\$w=="1")' "$RT"; then
  ok_t "the send's ok payload reports woken"
else
  bad_t "the send's ok payload does not carry a woken field"
fi


# ---------------------------------------------------------------------------
# ITERATION 2 — THE POST-WAKE DELIVERY HALF.
#
# Every arm above stops at agent_wake_for_send, which returns the instant
# `tmux has-session` succeeds: the EARLIEST moment of a cold boot, well before the
# TUI renders an input prompt. Delivery then continued into wait_agent_input_ready,
# which is NON-FATAL by design — on timeout it warns and types anyway — and the run
# ended at `sent:true`, exit 0. So a --wake send to an agent whose cold boot outran
# the readiness budget reported success on a message its own comment says was
# dropped: the defect this ticket exists to remove, made quieter than the 190ms
# failure it replaced. The reason the 15 arms above could not see it is that ZERO of
# them reference wait_agent_input_ready and both live ones terminate BEFORE
# delivery. These arms are that missing half.
#
# The real `fail` exits, so stubbing it as an exit is faithful, and running the gate
# in a SUBSHELL lets the arm read the rc a scheduler would actually get.
# ---------------------------------------------------------------------------
E_NOT_RUNNING=8   # src/lib/error_codes.sh

# The real detectability table, extracted from source for the same
# cannot-drift reason as the functions.
eval "$(awk '/^declare -A _AGENT_PROMPT_DETECTABLE=\(/ { on=1 } on { print } on && /^\)/ { exit }' "$RT")"
[[ -n "${_AGENT_PROMPT_DETECTABLE[claude]+x}" ]] \
  || { printf 'FATAL - could not extract _AGENT_PROMPT_DETECTABLE from %s\n' "$RT"; exit 1; }

ATYPE="claude"      # what agent_type reports for the target
READY_RC=0          # what wait_agent_input_ready returns
READY_BUDGET_SEEN="" # the timeout it was handed — the budget instrument
agent_type()             { printf '%s' "$ATYPE"; }
wait_agent_input_ready() { READY_BUDGET_SEEN="${2:-}"; return "$READY_RC"; }
step()                   { :; }

# Run the gate in a subshell with `fail` stubbed to exit, exactly as the real one
# does. Echoes the reason on stdout so an arm can grade the message too.
run_gate() { ( fail() { printf '%s' "$2"; exit "$1"; }; agent_wake_gate_ready "$1" ); }

# --- ARM A (THE MISSING ARM olivia named): session appears, prompt NEVER renders.
# This is the likeliest real cold-boot shape and the one the suite lacked. It must
# be FATAL — not a warning followed by keystrokes and sent:true.
AGENT_WAKE_BUDGET_SECS=105; AGENT_WAKE_ELAPSED=0; ATYPE="claude"; READY_RC=1
_msg=$(run_gate marketing); rc=$?
eq_t "woke but prompt never rendered => FATAL E_NOT_RUNNING" "$E_NOT_RUNNING" "$rc"
if [[ "$_msg" == *"input prompt never rendered"* && "$_msg" == *"105s"* ]]; then
  ok_t "the fatal reason names the unrendered prompt AND the total budget"
else
  bad_t "fatal reason is uninformative (got '$_msg')"
fi

# --- ARM B: LIVENESS, the differential half of ARM A. Same call, prompt DOES
# render: it must proceed (rc 0) and record proof. Without this arm, a build that
# fails the wake path unconditionally scores identically on ARM A.
AGENT_WAKE_READY=""; READY_RC=0
agent_wake_gate_ready marketing >/dev/null 2>&1; rc=$?
eq_t "prompt renders => gate proceeds" "0" "$rc"
eq_t "a proven-ready delivery is recorded as proven" "proven" "$AGENT_WAKE_READY"

# --- ARM C: the hole, made OBSERVABLE rather than silent. A runtime with no prompt
# marker cannot be proven ready at all (wait_agent_input_ready returns 0 meaning
# "nothing to detect", never "ready"). Failing would refuse deliveries that work;
# passing silently would re-create the very green-on-a-dropped-message ARM A
# removes. So it proceeds AND says so.
AGENT_WAKE_READY=""; ATYPE="opencode"; READY_RC=1   # RC=1 proves the poll is not even consulted
agent_wake_gate_ready marketing >/dev/null 2>&1; rc=$?
eq_t "undetectable runtime still delivers (refusing would break working sends)" "0" "$rc"
eq_t "...but is reported unprovable, not proven" "unprovable" "$AGENT_WAKE_READY"

# --- ARM D: DISTINCTNESS. proven and unprovable must not collapse into one value —
# a build that hardcodes either passes ARM B or ARM C but never both, and this arm
# is what states the requirement directly.
AGENT_WAKE_READY=""; ATYPE="claude"; READY_RC=0
agent_wake_gate_ready marketing >/dev/null 2>&1; _proven="$AGENT_WAKE_READY"
AGENT_WAKE_READY=""; ATYPE="opencode"
agent_wake_gate_ready marketing >/dev/null 2>&1; _unprov="$AGENT_WAKE_READY"
if [[ -n "$_proven" && -n "$_unprov" && "$_proven" != "$_unprov" ]]; then
  ok_t "proven and unprovable are distinguishable in the payload"
else
  bad_t "ready values collapse ('$_proven' vs '$_unprov')"
fi

# --- ARM E: ONE budget, not two stacked ones. The readiness wait must get the
# REMAINDER of AGENT_WAKE_BUDGET_SECS after the wake spent its share. A build that
# hands it a fresh 45 (or the whole budget) silently doubles the worst case a
# scheduler is sizing TimeoutStartSec against.
ATYPE="claude"; READY_RC=0; AGENT_WAKE_BUDGET_SECS=105; AGENT_WAKE_ELAPSED=40
READY_BUDGET_SEEN=""
agent_wake_gate_ready marketing >/dev/null 2>&1
eq_t "readiness gets the REMAINING budget, not a second fresh one" "65" "$READY_BUDGET_SEEN"

# --- ARM F: a wake that burned the whole budget must not hand the poll a zero or
# negative timeout (`while (( waited < 0 ))` never runs, and a negative reads as a
# bug rather than a deadline).
AGENT_WAKE_ELAPSED=105; READY_BUDGET_SEEN=""
agent_wake_gate_ready marketing >/dev/null 2>&1
if [[ -n "$READY_BUDGET_SEEN" ]] && (( READY_BUDGET_SEEN >= 1 )); then
  ok_t "an exhausted budget floors at 1s rather than going 0 or negative"
else
  bad_t "exhausted budget produced a non-positive timeout ('$READY_BUDGET_SEEN')"
fi
AGENT_WAKE_ELAPSED=0

# --- ARM G: agent_wake_for_send must RECORD what it spent, or the budget above is
# arithmetic over a constant. Graded differentially: a wake that returns late must
# report more elapsed than one that returns immediately.
reset_stubs; DESIRED="running"; SESSION_UP=0; AGENT_WAKE_ELAPSED=-1
agent_wake_for_send marketing 5 >/dev/null 2>&1
_fast="$AGENT_WAKE_ELAPSED"
reset_stubs; DESIRED="running"; SESSION_UP=1; AGENT_WAKE_ELAPSED=-1
agent_wake_for_send marketing 5 >/dev/null 2>&1
_slow="$AGENT_WAKE_ELAPSED"
if [[ "$_fast" == "0" ]] && (( _slow > _fast )); then
  ok_t "the wake records the time it actually spent (fast=$_fast slow=$_slow)"
else
  bad_t "AGENT_WAKE_ELAPSED does not track the wake (fast='$_fast' slow='$_slow')"
fi

# --- ARM H: ORDER. The gate must sit BEFORE inject_and_submit, or it grades nothing:
# keystrokes already fired cannot be un-fired by a later refusal. Same technique as
# the scoped-refusal order arm above — presence alone stays green on the broken build.
_gate_line=$(grep -n 'agent_wake_gate_ready "\$name"$' "$RT" | head -1 | cut -d: -f1)
_inject_line=$(grep -n 'inject_and_submit "\$name" "\$payload"' "$RT" | head -1 | cut -d: -f1)
if [[ -n "$_gate_line" && -n "$_inject_line" ]] && (( _gate_line < _inject_line )); then
  ok_t "the readiness gate runs BEFORE inject_and_submit"
else
  bad_t "readiness gate is missing or sits after inject_and_submit (gate=$_gate_line inject=$_inject_line)"
fi

# --- ARM I: the DEFAULT path keeps its best-effort readiness byte for byte. The
# fatal branch is gated on `woken`; the original warn-and-send-anyway must survive
# as the else. A busy-but-healthy live agent that never parks at a prompt still gets
# its message, and _task_need_route_deliver's contract is untouched.
if grep -q 'elif ! wait_agent_input_ready "\$name"; then' "$RT" \
   && grep -q "input prompt not detected after 45s — sending best-effort" "$RT"; then
  ok_t "the default path keeps its non-fatal readiness warning verbatim"
else
  bad_t "the default path's best-effort readiness branch was altered or removed"
fi
if grep -q 'if (( woken )); then' "$RT"; then
  ok_t "the fatal readiness branch is gated on woken, not applied to every send"
else
  bad_t "no (( woken )) gate found in front of the fatal readiness branch"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
