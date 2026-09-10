#!/usr/bin/env bash
# DIVE-4214 — a send to a BUSY seat must QUEUE, not land mid-turn.
#
# Delivery is `tmux send-keys -l` into the live pane, so a send that arrives
# while the seat holds a task attempt becomes its NEXT USER TURN mid-row.
# Measured in the 24h to 2026-09-10: 40 of the 67 a2a sends to ops landed
# inside a running attempt.
#
# WHAT THIS GRADES, and it is the row's acceptance verbatim:
#   * a BUSY target (_hb_agent_idle rc 1) is SPOOLED and NOTHING is typed;
#   * an IDLE target is UNCHANGED — typed, one turn, no spool file;
#   * the interrupting class is exactly the enumerated set, and a caller cannot
#     join it;
#   * the flush delivers at idle, one message per idle observation, and unlinks;
#   * the replay arm: 40 mid-attempt sends produce 0 typed payloads.
#
# Boundaries only are stubbed: tmux, the idle predicate, and `sudo` (which is
# reduced to "drop the -u <user> prefix and run it here"), so the queue writes
# and reads real files under a throwaway root. _a2a_should_queue,
# _a2a_queue_put, a2a_queue_flush_one, inject_and_submit and cmd_send stay REAL
# — mutating any of them makes this red.
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
trap 'rc=$?; rm -rf "${TMPROOT:-/nonexistent-a2a}"; echo "HARNESS-RC=$rc"' EXIT
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
is() {
  local label="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then ok_t "$label"; else bad_t "$label" "want=[$want] got=[$got]"; fi
}

TMPROOT="$(mktemp -d)"
TYPED="${TMPROOT}/typed.log"
: >"$TYPED"

# --- boundaries -------------------------------------------------------------
# The spool lives in the target's home in production; here it lives under a
# throwaway root. Everything else about the path (per-seat, dot-part rename)
# is the real code.
_a2a_queue_dir() { printf '%s\n' "${TMPROOT}/agent-${1}/.5dive/a2a-queue"; }
# `sudo -u agent-X <cmd...>` -> `<cmd...>`. The queue's mkdir/tee/mv/rm/find/cat
# then act on real files, so a write that does not happen is a red, not a stub
# that lies.
sudo() {
  local -a a=("$@")
  [[ "${a[0]:-}" == "-n" ]] && a=("${a[@]:1}")
  if [[ "${a[0]:-}" == "-u" ]]; then a=("${a[@]:2}"); fi
  "${a[@]}"
}
tmux() { printf 'TMUX %s\n' "$*" >>"$TYPED"; return 0; }
_agent_delivery_inbox()   { return 1; }   # pane seat, not a dispatcher seat
_agent_pane_safe_to_type(){ return 0; }
_hb_claude_pid()          { printf '4214\n'; }
wait_agent_input_ready()  { return 0; }
require_agent()           { :; }
mirror_interagent_outbound() { :; }
_buzz_mirror_outbound()   { :; }
a2a_needs_scoped()        { return 1; }
a2a_round_guard()         { return 0; }
envelope_tier()           { printf 'admin\n'; }
envelope_via()            { :; }
envelope_provenance()     { printf 'derived\n'; }
_envelope_caller()        { printf 'ops\n'; }
auto_sender_from_sudo()   { printf 'ops\n'; }
gen_msg_id()              { printf 'q4214\n'; }
_agent_refuse_peer_forgery() { :; }
audit_log()               { :; }
# The one signal the whole feature keys off. IDLE_RC is set per arm.
_hb_agent_idle() { return "${IDLE_RC:-0}"; }

# One DELIVERY is `send-keys -l --` (the payload) plus one or more Enters, so
# count the literal-payload line only — an Enter is not a message.
typed_count() { grep -c -- 'send-keys -t [^ ]* -l --' "$TYPED" 2>/dev/null || true; }
spool_count() { find "$(_a2a_queue_dir "$1")" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '; }
reset_arm()   { : >"$TYPED"; rm -rf "${TMPROOT}/agent-ops"; }

# --- T1..T4: the idle predicate is the ONLY discriminator -------------------
# rc 1 (busy) queues. rc 0 (idle), 2 (no signal) and 3 (blocked on a dialog)
# all keep today's path: queueing on a reading we could not take would make an
# unmeasurable seat a silently deaf one.
for arm in "1:busy:queue" "0:idle:type" "2:unknown:type" "3:blocked:type"; do
  rc="${arm%%:*}"; rest="${arm#*:}"; label="${rest%%:*}"; want="${rest#*:}"
  reset_arm
  _rc=0
  IDLE_RC="$rc" inject_and_submit ops "hello from a peer" || _rc=$?
  if [[ "$want" == "queue" ]]; then
    is "T1.${label}: rc 4 (queued)"          "4" "$_rc"
    is "T1.${label}: one message spooled"    "1" "$(spool_count ops)"
    is "T1.${label}: NOTHING typed"          "0" "$(typed_count)"
  else
    is "T1.${label}: rc 0 (delivered)"       "0" "$_rc"
    is "T1.${label}: nothing spooled"        "0" "$(spool_count ops)"
    [[ "$(typed_count)" -gt 0 ]] && ok_t "T1.${label}: typed into the pane" \
      || bad_t "T1.${label}: typed into the pane" "no send-keys recorded"
  fi
done

# --- T5: the spooled bytes are the payload, verbatim ------------------------
reset_arm
IDLE_RC=1 inject_and_submit ops "[5dive-msg from=main id=q4214] merge PR 848" || true
f="$(find "$(_a2a_queue_dir ops)" -name '*.msg' | head -1)"
is "T5: spool holds the payload verbatim" "[5dive-msg from=main id=q4214] merge PR 848" "$(cat "$f")"
is "T5: no .part left behind" "0" "$(find "$(_a2a_queue_dir ops)" -name '*.part' | wc -l | tr -d ' ')"

# --- T6: the interrupting class, enumerated ---------------------------------
# Member 1 — TUI control lines. A queued /clear would reset the WRONG thread.
for ctl in "/clear" "/goal clear" "/compact"; do
  reset_arm
  _rc=0; IDLE_RC=1 inject_and_submit ops "$ctl" || _rc=$?
  is "T6.ctl '$ctl': typed through a busy seat" "0" "$_rc"
  is "T6.ctl '$ctl': not spooled"               "0" "$(spool_count ops)"
done
# Members 2+3 — `ask` and the flush, both of which set the marker in the
# TRANSPORT. There is no caller-supplied --urgent, and that is the point.
reset_arm
_rc=0; IDLE_RC=1 _A2A_INTERRUPTING=1 inject_and_submit ops "a question" || _rc=$?
is "T6.interrupting: typed through a busy seat" "0" "$_rc"
is "T6.interrupting: not spooled"               "0" "$(spool_count ops)"
# And the marker does not leak into the next send from the same shell.
reset_arm
_rc=0; IDLE_RC=1 inject_and_submit ops "a plain send" || _rc=$?
is "T6.no-leak: the next send still queues" "4" "$_rc"

# --- T7: the flush ----------------------------------------------------------
# Three spooled, seat goes idle: exactly ONE is delivered per idle observation,
# in send order, and it is unlinked. Delivering the second straight after the
# first would land it inside the turn the first just started.
reset_arm
for n in 1 2 3; do IDLE_RC=1 inject_and_submit ops "msg-${n}" || true; done
is "T7: three spooled" "3" "$(spool_count ops)"
IDLE_RC=1 a2a_queue_flush_one ops && bad_t "T7: flush is a no-op while busy" "it delivered" \
  || ok_t "T7: flush is a no-op while busy"
is "T7: still three spooled after a busy flush" "3" "$(spool_count ops)"
IDLE_RC=0 a2a_queue_flush_one ops && ok_t "T7: flush delivers at idle" \
  || bad_t "T7: flush delivers at idle" "rc non-zero"
is "T7: exactly one delivered" "1" "$(typed_count)"
is "T7: oldest first"          "1" "$(grep -c 'msg-1' "$TYPED" || true)"
is "T7: two left spooled"      "2" "$(spool_count ops)"
IDLE_RC=0 a2a_queue_flush_one ops || true
is "T7: second flush delivers msg-2" "1" "$(grep -c 'msg-2' "$TYPED" || true)"
is "T7: one left spooled"            "1" "$(spool_count ops)"
# An empty spool is not an error condition anyone should act on, it is a no-op.
IDLE_RC=0 a2a_queue_flush_one ops || true
IDLE_RC=0 a2a_queue_flush_one ops && bad_t "T7: empty spool flush is a no-op" "it returned 0" \
  || ok_t "T7: empty spool flush is a no-op"

# --- T8: the receipt cmd_send prints ----------------------------------------
# A queued send is NOT sent:true — the message has not reached the model. It
# rides the existing sent:false receipt (DIVE-2362) plus an additive queued:true,
# so a caller that already handles sent:false needs no change.
reset_arm
out="$(IDLE_RC=1 JSON_MODE=1 cmd_send ops --message="mid-attempt ping" 2>/dev/null)"
is "T8: ok:true"      "true"  "$(jq -r '.ok' <<<"$out")"
is "T8: sent:false"   "false" "$(jq -r '.data.sent' <<<"$out")"
is "T8: queued:true"  "true"  "$(jq -r '.data.queued' <<<"$out")"
[[ "$(jq -r '.data.reason' <<<"$out")" == *"queued, delivers at its next idle or wake"* ]] \
  && ok_t "T8: reason names the queue" || bad_t "T8: reason names the queue" "$(jq -r '.data.reason' <<<"$out")"
prose="$(IDLE_RC=1 cmd_send ops --message="mid-attempt ping" 2>/dev/null | tail -1)"
[[ "$prose" == *"queued for agent 'ops'"* ]] \
  && ok_t "T8: prose says queued, not sent" || bad_t "T8: prose says queued, not sent" "$prose"
# The IDLE receipt is what it was. Asserted on the PROSE line, not the JSON one,
# and that is a finding rather than a convenience: on main today the sent:true
# branch renders an EMPTY JSON envelope whenever AGENT_WAKE_READY is unset (i.e.
# every send that did not have to --wake the target), because the jq object
# carries `ready:($rd|select(length>0))` and jq drops the WHOLE object when any
# constructed value is `empty`. Reproduced against pristine origin/main with the
# same stubs, so it is pre-existing and out of this row's scope — recorded on
# DIVE-4214's body. The queued branch does not inherit it: its receipt builds the
# optional keys with `if ... then ... else {} end`.
reset_arm
prose="$(IDLE_RC=0 cmd_send ops --message="ping" 2>/dev/null | tail -1)"
[[ "$prose" == *"sent to agent 'ops'"* ]] \
  && ok_t "T8: idle send still reports sent" || bad_t "T8: idle send still reports sent" "$prose"
[[ "$prose" != *queued* ]] \
  && ok_t "T8: idle send says nothing about a queue" || bad_t "T8: idle send says nothing about a queue" "$prose"

# --- T9: the replay arm -----------------------------------------------------
# The row's acceptance: replay the 40 measured mid-attempt sends to ops; 0 land
# inside a turn. Then the same 40 against an IDLE seat: all 40 land, unchanged.
reset_arm
for i in $(seq 1 40); do IDLE_RC=1 inject_and_submit ops "replay-${i}" || true; done
is "T9: 0 of the 40 mid-attempt sends typed" "0"  "$(typed_count)"
is "T9: all 40 spooled"                      "40" "$(spool_count ops)"
reset_arm
for i in $(seq 1 40); do IDLE_RC=0 inject_and_submit ops "replay-${i}" || true; done
is "T9: 40 of 40 land on an idle seat" "40" "$(typed_count)"
is "T9: an idle seat spools nothing"   "0"  "$(spool_count ops)"

# --- T10: the kill switch ---------------------------------------------------
# FIVE_A2A_QUEUE=off restores the pre-4214 transport exactly, so a fleet that
# hits a flush defect has a one-variable way back that is not a revert.
reset_arm
_rc=0; IDLE_RC=1 FIVE_A2A_QUEUE=off inject_and_submit ops "escape hatch" || _rc=$?
is "T10: off types through a busy seat" "0" "$_rc"
is "T10: off spools nothing"            "0" "$(spool_count ops)"

# --- T11: the flush is wired into the tick, and BEFORE the autosleep pass -----
# A source-order control, for the reason arm H of agent_send_wake_unit.sh gives:
# presence alone stays green on a build where the sweep never runs, or runs after
# a seat with mail waiting has already been stopped.
HB=src/cmd_heartbeat.sh
_flush_line=$(grep -n '^  _hb_a2a_queue_sweep || _hb_log' "$HB" | head -1 | cut -d: -f1)
_sleep_line=$(grep -n '^  _hb_autosleep_sweep "\$now" || _hb_log' "$HB" | head -1 | cut -d: -f1)
if [[ -n "$_flush_line" && -n "$_sleep_line" ]] && (( _flush_line < _sleep_line )); then
  ok_t "T11: the a2a flush runs in the tick, before the autosleep pass"
else
  bad_t "T11: the a2a flush runs in the tick, before the autosleep pass" \
        "flush=${_flush_line:-absent} autosleep=${_sleep_line:-absent}"
fi
# Same isolation contract as every other sweep — it must never abort the wake loop.
grep -q '_hb_a2a_queue_sweep || _hb_log "\[a2a-queue\] pass errored (non-fatal)"' "$HB" \
  && ok_t "T11: the sweep is isolated (non-fatal)" \
  || bad_t "T11: the sweep is isolated (non-fatal)" "no non-fatal guard on the call"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
