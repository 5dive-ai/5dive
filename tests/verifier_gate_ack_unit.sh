#!/usr/bin/env bash
# TIER: nightly — 20.0s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-2196 isolated unit harness: a verifier who filed a human gate has ACTED.
#
# The bug (fired live on DIVE-2146): the heartbeat stall-sweep selects delivered
# maker→verifier rows with `status NOT IN ('done','cancelled') AND handoff_ack_at
# IS NULL`. A task BLOCKED on an unanswered human gate satisfies both — 'blocked'
# is not a closed status, and filing a gate stamped no ACK — so a verifier who
# reviewed the work and escalated a policy question to a human was nagged as if
# they had never opened it. The remedy the nag prescribes is the harm: on a
# maker→verifier task the verifier's ACK *is* the close, so "run task start then
# task done/task reject" asks them to resolve a pending human gate by side effect.
#
# Three arms, three different bugs:
#   (1) the sweep must SKIP a row blocked on an unanswered gate  [cmd_heartbeat.sh]
#   (2) filing a gate as the assigned verifier of a delivered row must stamp
#       handoff_ack_at — else "reviewed and escalated" is byte-identical to
#       "never looked"                                                [cmd_task.sh]
#   (3) neither verb by which the ACK could resolve the gate may do so silently:
#       `task done` is already refused (DIVE-555 — locked here as a regression,
#       since arm (1) rests on it), and `task reject` — which auto-answers the
#       gate 'auto:reject' — must refuse on a TIER-2 (human-only) gate.
#
# Same isolation contract as the other task/heartbeat harnesses: sources src/
# directly, STATE_DIR on a throwaway temp dir, every send/notify/registry path
# stubbed so nothing touches the live board, tmux or the network.
# Run: bash tests/verifier_gate_ack_unit.sh   (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
# DIVE-2518: impersonate through the SEALED seam. `USER=agent-x` no longer moves
# the actor — that env path WAS the forgery this ticket closed, and these arms
# were leaning on it. tests/lib/actor_seam.sh explains the migration.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src

TMP="$(mktemp -d /tmp/verifier-gate-ack.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/disk.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_push.sh cmd_org.sh \
         cmd_project.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- stubs -------------------------------------------------------------------
SEND_LOG="$TMP/sent"; : >"$SEND_LOG"
cmd_send() { local tgt="$1" msg=""; shift
  for a in "$@"; do case "$a" in --message=*) msg="${a#--message=}";; esac; done
  printf '%s\t%s\n' "$tgt" "$msg" >>"$SEND_LOG"; }
task_need_notify() { :; }        # never DM a human when a fixture files a gate
audit_log() { return 0; }
registry_read() { printf '%s' '{"agents":{}}'; }   # empty fleet: never probe real panes
_hb_agent_idle() { return 2; }

# _gate_withdraw_actor reads the REAL unix identity on purpose (it must not be
# spoofable via $USER), which makes the arm below depend on who runs the suite:
# an agent box says "agent dev", CI says "human". Both are graded, explicitly,
# by forcing the value — local green would otherwise not be CI green.
GATE_ACTOR="agent reviewer"
_gate_withdraw_actor() { printf '%s' "$GATE_ACTOR"; }

tasks_db_init

as() { local who="$1"; shift; ( actor_seam_as "${who}"; "$@" ) 2>"$TMP/err"; }
[[ "$( ( actor_seam_as reviewer; task_actor ) )" == "reviewer" ]] \
  && ok_t "harness can impersonate an actor (task_actor → reviewer)" \
  || bad_t "actor impersonation broken" "every case below would be vacuous"

col()  { db "SELECT COALESCE($2,'') FROM tasks WHERE ident=$(sqlq "$1");"; }
# A fresh maker(maker)→verifier(reviewer) task, DELIVERED: status=todo, held by
# the verifier, handoff_delivered_at stamped, no ACK yet.
deliver() {
  local out ident
  out=$(as maker cmd_task_add "$1" --assignee=maker --verifier=reviewer --accept="does the thing")
  ident=$(printf '%s' "$out" | jq -r '.data.ident // empty' 2>/dev/null)
  as maker cmd_task_done "$ident" --result="built it" >/dev/null
  printf '%s' "$ident"
}
age() { db "UPDATE tasks SET handoff_delivered_at=datetime('now','-${_HB_VERIFY_STALE_MIN} minutes','-5 minutes'),
                             handoff_stale_pinged_at=NULL WHERE ident=$(sqlq "$1");"; }
# grep -c prints 0 and EXITS 1 on no match, so `|| echo 0` would emit "0\n0" and
# break the arithmetic test — count with grep alone and default only if it dies.
pinged() { local n; n=$(grep -c "${1}[ .]" "$SEND_LOG" 2>/dev/null); printf '%s' "${n:-0}"; }

# =============================================================================
# ARM 2 — filing a gate as the assigned verifier IS the ACK
# =============================================================================
A=$(deliver "gate filed by the verifier")
[[ "$(col "$A" status)" == "todo" && "$(col "$A" assignee)" == "reviewer" \
   && -n "$(col "$A" handoff_delivered_at)" && -z "$(col "$A" handoff_ack_at)" ]] \
  && ok_t "fixture is DELIVERED and unacked (todo, held by reviewer)" \
  || bad_t "fixture not delivered" "status=$(col "$A" status) assignee=$(col "$A" assignee) ack=$(col "$A" handoff_ack_at)"

as reviewer cmd_task_need "$A" --type=decision --tier=2 --options="A|B" --recommend="A" \
   --ask="Leave this open and parked, or close it as delivered?" >/dev/null
[[ "$(col "$A" need_type)" == "decision" && -z "$(col "$A" need_answered_at)" \
   && "$(col "$A" status)" == "blocked" ]] \
  && ok_t "verifier filed a tier-2 gate (task now blocked on a human)" \
  || bad_t "gate not filed" "type=$(col "$A" need_type) status=$(col "$A" status) $(cat "$TMP/err")"
[[ -n "$(col "$A" handoff_ack_at)" ]] \
  && ok_t "ARM2 filing the gate stamped handoff_ack_at — reviewed+escalated != never looked" \
  || bad_t "ARM2 ack not stamped" "handoff_ack_at is still NULL after the verifier acted"

# ...but only for the real verifier. A third party filing a gate must not forge
# the receiver's receipt (same rule as DIVE-1378's `task start` ACK).
F=$(deliver "gate filed by a third party")
as intruder cmd_task_need "$F" --type=manual --ask="unrelated question" >/dev/null
[[ -z "$(col "$F" handoff_ack_at)" ]] \
  && ok_t "ARM2 a third party's gate does NOT forge the verifier's ACK" \
  || bad_t "ARM2 forged ACK" "ack=$(col "$F" handoff_ack_at)"

# =============================================================================
# ARM 1 — the stall sweep skips a row blocked on an unanswered gate
# =============================================================================
# G is the row this arm exists for: live gate, handoff_ack_at NULL, still held by
# the verifier. That is DIVE-2146's shape TODAY and the shape of every gate-blocked
# row already on the board — arm 2's stamp only applies to gates filed AFTER it
# lands, and only to ones the verifier files themselves. Grading arm 1 on a row
# that arm 2 had already stamped made it VACUOUS: deleting the sweep's exclusion
# left the suite green, because `handoff_ack_at IS NULL` was doing the skipping.
# Two fixes for one symptom, one silently standing in for the other.
G=$(deliver "delivered, live gate, no ACK on the row")
as reviewer cmd_task_need "$G" --type=decision --tier=2 --options="A|B" --recommend="A" \
   --ask="Leave this open and parked, or close it as delivered?" >/dev/null
db "UPDATE tasks SET handoff_ack_at=NULL WHERE ident=$(sqlq "$G");"
[[ "$(col "$G" assignee)" == "reviewer" && -z "$(col "$G" handoff_ack_at)" \
   && -n "$(col "$G" need_type)" && -z "$(col "$G" need_answered_at)" ]] \
  && ok_t "ARM1 fixture reaches the sweep on every predicate BUT the gate one" \
  || bad_t "ARM1 fixture is skipped for the wrong reason" "assignee=$(col "$G" assignee) ack=$(col "$G" handoff_ack_at) gate=$(col "$G" need_type)/$(col "$G" need_answered_at)"

B=$(deliver "delivered, genuinely untouched")          # control: must still ping
C=$(deliver "delivered, gate ANSWERED")                # control: must still ping
as reviewer cmd_task_need "$C" --type=manual --ask="a question since answered" >/dev/null
# Answer it and put the row back in the verifier's hands, unacked — the wait is
# on the verifier again, so this row MUST stay sweepable. This is what keeps
# arm 1 from degenerating into "any row that ever had a gate is exempt".
db "UPDATE tasks SET need_answered_at=datetime('now'), need_answer='answered',
      need_answered_by='human:test', status='todo', handoff_ack_at=NULL
    WHERE ident=$(sqlq "$C");"
for t in "$A" "$G" "$B" "$C"; do age "$t"; done
_hb_stall_sweep >/dev/null 2>&1

[[ "$(pinged "$B")" -ge 1 ]] \
  && ok_t "LIVENESS an untouched delivered row IS surfaced (the sweep still works)" \
  || bad_t "sweep is dead" "control row $B was not pinged — every skip assertion below is vacuous"
[[ "$(pinged "$C")" -ge 1 ]] \
  && ok_t "CONTROL an ANSWERED gate does not exempt the row — it is surfaced" \
  || bad_t "over-broad exclusion" "row $C (gate answered, wait is back on the verifier) was skipped"
[[ "$(pinged "$G")" -eq 0 ]] \
  && ok_t "ARM1 a row blocked on an UNANSWERED gate is NOT nagged" \
  || bad_t "ARM1 nag still fires" "G=$G count=$(pinged "$G") log:$(cat "$SEND_LOG")"
[[ -z "$(col "$G" handoff_stale_pinged_at)" ]] \
  && ok_t "ARM1 skipped row is not marked pinged (stays eligible once the gate clears)" \
  || bad_t "ARM1 throttle stamped on a skipped row" "handoff_stale_pinged_at=$(col "$G" handoff_stale_pinged_at)"
[[ "$(pinged "$A")" -eq 0 ]] \
  && ok_t "ARM1+2 a row the verifier gated itself is skipped twice over (ACK and gate)" \
  || bad_t "gated+acked row nagged" "A=$A count=$(pinged "$A")"

# =============================================================================
# ARM 3 — neither verb may resolve the human's gate as a side effect
# =============================================================================
# (a) `task done` — the verifier's close. Already refused by DIVE-555; locked
#     here because arm 1's whole argument is that this path must not open.
out=$(as reviewer cmd_task_done "$A" --result="graded pass"); rc=$?
(( rc != 0 )) && ok_t "ARM3a verifier's close over an open gate exits non-zero (rc=$rc)" \
  || bad_t "ARM3a close went through" "rc=$rc out=$out"
[[ "$(col "$A" status)" != "done" && -z "$(col "$A" need_answered_at)" ]] \
  && ok_t "ARM3a task not closed and the gate is still pending a human" \
  || bad_t "ARM3a state mutated" "status=$(col "$A" status) answered=$(col "$A" need_answered_at)"

# (b) `task reject` — the other verb the nag prescribes. It auto-answers the gate
#     'auto:reject', a NON-HUMAN provenance the tier-2 floor forbids.
out=$(as reviewer cmd_task_reject "$A" --feedback="bounce it"); rc=$?
(( rc != 0 )) && ok_t "ARM3b reject over a TIER-2 gate exits non-zero (rc=$rc)" \
  || bad_t "ARM3b reject went through" "rc=$rc out=$out"
[[ -z "$(col "$A" need_answered_at)" && "$(col "$A" assignee)" == "reviewer" ]] \
  && ok_t "ARM3b the human's gate survives, unanswered, still held by the verifier" \
  || bad_t "ARM3b gate superseded" "answered_by=$(col "$A" need_answered_by) assignee=$(col "$A" assignee)"

# (c) CONTROL — a tier<=1 gate is fleet-actionable, so DIVE-1495's supersede must
#     still work: the CNCL-9 re-nag defect it fixed is not reintroduced.
D=$(deliver "tier-1 gate, reject supersedes")
as reviewer cmd_task_need "$D" --type=manual --tier=1 --ask="which colour should the banner be" >/dev/null
as reviewer cmd_task_reject "$D" --feedback="needs another pass" >/dev/null
[[ "$(col "$D" need_answered_by)" == "auto:reject" && "$(col "$D" assignee)" == "maker" ]] \
  && ok_t "CONTROL tier-1 gate still superseded by reject (DIVE-1495 intact)" \
  || bad_t "tier-1 supersede broken" "answered_by=$(col "$D" need_answered_by) assignee=$(col "$D" assignee)"

# (d) BOUNDARY — the refusal is scoped to an AGENT actor. A genuine human caller
#     is the party the gate is waiting on, so their reject proceeds. Graded
#     explicitly rather than inherited from whoever runs the suite.
E=$(deliver "tier-2 gate, human rejects")
as reviewer cmd_task_need "$E" --type=decision --tier=2 --options="A|B" --recommend="A" \
   --ask="Leave open and parked, or close as delivered?" >/dev/null
GATE_ACTOR="human"
as reviewer cmd_task_reject "$E" --feedback="human call: bounce it" >/dev/null
GATE_ACTOR="agent reviewer"
[[ "$(col "$E" need_answered_by)" == "auto:reject" && "$(col "$E" assignee)" == "maker" ]] \
  && ok_t "BOUNDARY a HUMAN caller's reject over a tier-2 gate still proceeds" \
  || bad_t "human blocked" "answered_by=$(col "$E" need_answered_by) assignee=$(col "$E" assignee)"

# (e) BOUNDARY — an UNTIERED (legacy / hand-inserted) gate keeps DIVE-1495's
#     supersede. Defaulting a missing tier to 2 would retro-fit the refusal onto
#     rows nobody ever tiered; every gate `task need` files carries an explicit one.
H=$(deliver "legacy untiered gate, reject supersedes")
db "UPDATE tasks SET status='blocked', need_type='manual', ask='pending human thing',
      tier=NULL, need_asked_at=datetime('now') WHERE ident=$(sqlq "$H");"
as reviewer cmd_task_reject "$H" --feedback="needs another pass" >/dev/null
[[ "$(col "$H" need_answered_by)" == "auto:reject" && "$(col "$H" assignee)" == "maker" ]] \
  && ok_t "BOUNDARY an untiered legacy gate is still superseded (no retro-fit)" \
  || bad_t "untiered gate blocked" "answered_by=$(col "$H" need_answered_by) assignee=$(col "$H" assignee)"

# (f) THE ESCAPE IS REACHABLE, not just named. A guard that forecloses the FAIL
#     verdict with no exit gets routed around. When the verifier filed the gate
#     themselves, the refusal points at withdraw-then-reject — so run it and prove
#     it completes. The withdrawal is recorded; nothing is put in the human's mouth.
I=$(deliver "verifier's own gate, withdraw then reject")
as reviewer cmd_task_need "$I" --type=decision --tier=2 --options="A|B" --recommend="A" \
   --ask="Leave open and parked, or close as delivered?" >/dev/null
msg=$(as reviewer cmd_task_reject "$I" --feedback="it fails" 2>&1; cat "$TMP/err")
[[ "$msg" == *"--withdraw"* && "$msg" == *"you can retire it yourself"* ]] \
  && ok_t "ESCAPE the filer's refusal names withdraw-then-reject" \
  || bad_t "no exit named to the filer" "$msg"
as reviewer cmd_task_need "$I" --withdraw >/dev/null
as reviewer cmd_task_reject "$I" --feedback="it fails" >/dev/null
[[ "$(col "$I" assignee)" == "maker" && "$(col "$I" need_type)" == "" \
   && "$(col "$I" need_answered_by)" == "" ]] \
  && ok_t "ESCAPE withdraw-then-reject completes; no forged answer on the record" \
  || bad_t "escape does not complete" "assignee=$(col "$I" assignee) need_type=$(col "$I" need_type) by=$(col "$I" need_answered_by)"

# (g) When SOMEONE ELSE filed the gate the verifier cannot retire it — so the
#     refusal must name the exit that does not need them: record the verdict now,
#     reject when the gate clears. Proven by running it, not by reading the string.
J=$(deliver "third party's gate, verdict recorded meanwhile")
as lead cmd_task_need "$J" --type=decision --tier=2 --options="A|B" --recommend="A" \
   --ask="policy call only a human can make" >/dev/null
db "UPDATE tasks SET assignee='reviewer' WHERE ident=$(sqlq "$J");"   # row still held by the verifier
msg=$(as reviewer cmd_task_reject "$J" --feedback="it fails" 2>&1; cat "$TMP/err")
[[ "$msg" == *"set-body"* && "$msg" == *"lead"* ]] \
  && ok_t "ESCAPE a non-filer's refusal names record-now, reject-later" \
  || bad_t "no exit named to a non-filer" "$msg"
as reviewer cmd_task_set_body "$J" "VERDICT: FAIL — reasons here" --append >/dev/null
[[ "$(col "$J" body)" == *"VERDICT: FAIL"* && -z "$(col "$J" need_answered_at)" ]] \
  && ok_t "ESCAPE the verdict is recordable while the human's gate still stands" \
  || bad_t "verdict not recordable" "body=$(col "$J" body) answered=$(col "$J" need_answered_at)"

# (h) THE NAMED ALTERNATIVE IS AN ENTRY POINT. ARM3a's refusal on `task done`
#     points at other verbs, and `task verify --cmd` closes by raw UPDATE — it
#     never saw DIVE-555. Unguarded, every rail above is advisory: one `task
#     verify --cmd=true` closes the row and the human's question disappears.
K=$(deliver "verify --cmd must not close over a gate")
as reviewer cmd_task_need "$K" --type=decision --tier=2 --options="A|B" --recommend="A" \
   --ask="Leave open and parked, or close as delivered?" >/dev/null
out=$(as reviewer cmd_task_verify "$K" --cmd=true); rc=$?
(( rc != 0 )) && ok_t "ARM3c verify auto-close over an open gate exits non-zero (rc=$rc)" \
  || bad_t "ARM3c verify closed it" "rc=$rc out=$out"
[[ "$(col "$K" status)" != "done" && -z "$(col "$K" done_at)" && -z "$(col "$K" need_answered_at)" ]] \
  && ok_t "ARM3c task not closed and the human's gate still stands" \
  || bad_t "ARM3c state mutated" "status=$(col "$K" status) done_at=$(col "$K" done_at)"
[[ "$(col "$K" result)" == *"verify PASS"* ]] \
  && ok_t "ARM3c the verdict is still RECORDED — only the close waits" \
  || bad_t "ARM3c evidence lost" "result=$(col "$K" result)"
as reviewer cmd_task_verify "$K" --cmd=true --no-done >/dev/null
[[ "$(col "$K" status)" != "done" ]] \
  && ok_t "ARM3c --no-done still works on a gated row (the named exit is real)" \
  || bad_t "--no-done closed it" "status=$(col "$K" status)"

# CONTROL — verify still auto-closes an ordinary ungated task.
L=$(printf '%s' "$(as maker cmd_task_add "plain task, no gate" --assignee=maker)" | jq -r '.data.ident')
as maker cmd_task_verify "$L" --cmd=true >/dev/null
[[ "$(col "$L" status)" == "done" ]] \
  && ok_t "CONTROL verify still closes an ungated task (guard is not a blanket)" \
  || bad_t "verify broken for ungated tasks" "status=$(col "$L" status)"

echo "-----"
echo "verifier_gate_ack_unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
