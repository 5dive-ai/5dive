#!/usr/bin/env bash
# TIER: core — 3s measured on the 5dive host (agent-dev seat, worktree cli-4843-dev,
#   2026-09-22). No root, no network, no tmux, no live GitHub.
#
# DIVE-4843 — A HAND-OVER WRITES `todo`. THE DISPATCHER MAKES THE CLAIM.
#
# THE INCIDENT, measured by main 2026-09-22 10:20–10:35Z. Two rows merged on the
# forge and nobody could close them:
#
#   DIVE-4837  PR merged 09:48:05Z -> row became `in_progress assignee=quinn`,
#              started_at=09:48:06, loop `handoff: delivered (awaiting ACK)`.
#   DIVE-4824  PR merged 09:56:57Z -> same shape, 09:56:57.
#
# Neither ever appeared in a quinn `/goal`. `task done` from any other seat is
# correctly refused (writer != grader, DIVE-477). So the rows sat until the stale
# reaper — hours — with the PR already on main.
#
# WHY NOTHING COULD TOUCH THEM, and it is two facts that only bite together:
#   1. the landing hand-over carried the in_progress that the PREVIOUS seat's turn
#      had claimed, and only refreshed started_at. That is a claim nobody made.
#   2. BOTH arms of `_hb_pick_tasks` select `status='todo'` (cmd_heartbeat.sh),
#      so an in_progress row is invisible to the dispatcher whoever holds it.
# The one-shot courtesy ping the sweep sends is not a dispatch: a grader mid-turn
# drops it (one row per turn) and nothing re-sends it.
#
# lodar saw the other face of the same write, 10:27Z: "how can one agent still
# hold several in_progress tasks if he locks on one goal per time" — quinn showed
# three in_progress rows while running exactly one turn. A seat must never show
# more rows in_progress than it has turns.
#
# THE LOAD-BEARING ARM IS B1, NOT A2. "status is todo" is a column read and would
# stay green against a picker that had changed underneath it; B1 asks the REAL
# `_hb_pick_tasks` whether the seat that owes the close is dispatched, which is the
# property the incident actually lacked. A0/B0 arrange and prove the lockout first,
# so the absence B1 measures is informative rather than vacuous.
#
# Run: bash tests/task_handover_is_dispatchable_unit.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
export FIVE_GATE_NO_ANON=1
TMP="$(mktemp -d /tmp/dive4843.XXXXXX)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh cmd_task.sh \
         cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
AUDIT_LOG="$TMP/audit.log"
mkdir -p "$TASKS_DIR"; set +e

# THE ONE SEAM, and it is the uid derivation rather than any product logic.
# `task_actor ""` returns $ACTOR_BOARD, which `actor_claim` recomputes from
# /etc/passwd on every call — so a unit harness cannot be any seat but the one
# running it, and arm C1 (the VERIFIER's own close) would grade a refusal aimed at
# the harness's own uid instead of the rule. Overriding the derivation leaves
# `task_actor`, the DIVE-477 writer!=grader check and `cmd_task_done` entirely
# real; it only answers "which box seat is this".
FIXTURE_ACTOR=""
actor_board_name() { ACTOR_BOARD="${FIXTURE_ACTOR:-cli}"; ACTOR_BOARD_SOURCE="fixture"; return 0; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
tasks_db_init

# The three seats of the incident. None may collide with a real agent name, so the
# two that are only ever fixtures are reserved strings; GRADER is the seat the row
# is handed TO and is also what the close arm acts as.
OWNER=fixtureops        # held the merge, and the turn, when the landing landed
GRADER=fixturequinn     # the verifier: owes the grade/close, was never woken
MAKER=fixturedev
PR=https://github.com/5dive-ai/5dive/pull/4837
SHA=0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f60718293
AT=2026-09-22T09:48:05Z

# THE FORGE PROBE IS THE OTHER SEAM, stubbed the way tests/task_merge_landed_unit.sh
# stubs it: `_gate_gh` is the single point where this code leaves the box, so the
# REAL `_merge_landed_read` / `_merge_landed_probe` still run above it. Arm C1's
# close re-asks the forge, and an unreachable gh is UNKNOWN rather than absent —
# which is the correct refusal and would make C1 grade the network instead of the
# rule. The answer here is the one the incident actually had: merged.
_gate_gh_payload="MERGED|$SHA|$AT"; _gate_gh_rc=0
_gate_gh() { shift 2; [[ -n "$_gate_gh_payload" ]] && printf '%s\n' "$_gate_gh_payload"; return "$_gate_gh_rc"; }

# seed <ident> <status> <assignee> — the DIVE-4837 shape: graded PASS, bound,
# delivered, and CLAIMED by the seat that owed the merge.
seed() {
  db "DELETE FROM tasks WHERE ident='$1';"
  db "INSERT INTO tasks(ident,title,status,kind,created_by,assignee,maker_agent,verifier,
        graded_at,graded_verdict_at,graded_by,graded_verdict,handoff_delivered_at,
        delivery_ref,merge_owner,merge_hold_reason,started_at,first_started_at)
      VALUES('$1','graded PASS, merged on the forge','${2}','standard','main',
        '${3}','$MAKER','$GRADER','2026-09-22 09:30:00','2026-09-22 09:30:00',
        '$GRADER','pass','2026-09-22 09:00:00','$PR','$OWNER',
        'merger:no-graded-sha-stated','2026-09-22 09:48:06','2026-09-22 09:00:00');"
  db "SELECT id FROM tasks WHERE ident='$1';"
}
col()   { db "SELECT COALESCE($2,'<NULL>') FROM tasks WHERE ident='$1';"; }
picks() { _hb_pick_tasks "$1" 20 | grep -cx "$2"; }
# The whole hand-over, exactly as both callers invoke it: record the landing, then
# re-home. Never a raw UPDATE — a fixture built by hand would prove the SQL agrees
# with itself while saying nothing about the state the product reaches.
land() { # <id> <ident> <assignee>
  _task_merge_landed_record "$1" "$SHA" "$AT" "forge-poll" "$PR" >/dev/null 2>&1
  _task_merge_landed_handoff "$1" "$2" "$3" "$GRADER" >/dev/null 2>&1
}

echo "── A. the incident shape, arranged and PROVEN before anything is asserted about it ──"
ID=$(seed DIVE-F1 in_progress "$OWNER")
[[ "$ID" =~ ^[0-9]+$ ]] || { printf 'FATAL: fixture not created\n' >&2; exit 1; }
[[ "$(col DIVE-F1 status)" == "in_progress" && "$(col DIVE-F1 assignee)" == "$OWNER" ]] \
  && ok_t "A0/PRECONDITION: the row starts CLAIMED by the merge owner — the state a landing actually arrives in" \
  || bad_t "A0/PRECONDITION: fixture is in_progress on the owner" "every arm below would grade a different row"
[[ "$(picks "$GRADER" "$ID")" == "0" ]] \
  && ok_t "B0/THE LOCKOUT, LIVE: before the hand-over the seat that owes the close is NOT dispatched by the real picker" \
  || bad_t "B0 the fixture does not reproduce the lockout" "B1 below would prove nothing"

land "$ID" DIVE-F1 "$OWNER"
[[ "$(col DIVE-F1 assignee)" == "$GRADER" ]] \
  && ok_t "A1 the hand-over moves the row to the verifier, the seat whose close is ungated" \
  || bad_t "A1 assignee moved to the verifier" "got $(col DIVE-F1 assignee)"
[[ "$(col DIVE-F1 status)" == "todo" ]] \
  && ok_t "A2 ...and writes status=todo — it does NOT carry the previous seat's claim (DIVE-4843)" \
  || bad_t "A2 status must be todo after a hand-over" "got $(col DIVE-F1 status) — this is the DIVE-4837 defect"
[[ "$(col DIVE-F1 started_at)" == "<NULL>" ]] \
  && ok_t "A3 ...and CLEARS started_at — a start time with no turn behind it is what fed the reaper an illusion" \
  || bad_t "A3 started_at must be NULL" "got $(col DIVE-F1 started_at)"

echo "── B. the acceptance: the dispatcher can now reach it (the picker's own answer) ──"
[[ "$(picks "$GRADER" "$ID")" == "1" ]] \
  && ok_t "B1 ACCEPTANCE: _hb_pick_tasks now returns the row FOR THE VERIFIER — the wake the incident never got" \
  || bad_t "B1 the verifier is still not dispatchable" "the row is still unreachable; this IS the bug"
[[ "$(picks "$OWNER" "$ID")" == "0" ]] \
  && ok_t "B2 ...and the seat that already did its merge is no longer woken onto it" \
  || bad_t "B2 the old owner is still dispatched" "a no-op wake per tick"
# B3 grades a claim about SQLite that a reader could plausibly "fix" into a bug:
# in one UPDATE every CASE reads the PRE-UPDATE row, so the started_at arm still
# sees the old in_progress after the status arm has rewritten it. If assignment
# were left-to-right, status would be todo and started_at would survive — a row
# that is dispatchable and still carries a dead clock. Assert the PAIRING.
[[ "$(col DIVE-F1 status)" == "todo" && "$(col DIVE-F1 started_at)" == "<NULL>" ]] \
  && ok_t "B3 status and started_at moved TOGETHER — both CASE arms read the pre-UPDATE row, as one statement must" \
  || bad_t "B3 the two arms disagree" "status=$(col DIVE-F1 status) started_at=$(col DIVE-F1 started_at)"

echo "── C. and the close is gated to the seat the hand-over chose ──"
# WHY THIS ARM IS THE AUTHORISATION AND NOT A FULL CLOSE. Point 3 of the incident
# is that "nobody else may close them": `task done` from main was REFUSED on
# DIVE-4837 with writer != grader (DIVE-477) — a correct refusal in the wrong
# situation, because the one seat that COULD close it was never dispatched. So the
# property this row owes is that the hand-over lands the row on the seat the close
# is gated to. That is what C1/C2 grade, as a discriminating PAIR.
#
# NOT GRADED HERE, and named rather than left as a silent gap: the merged-to-main
# rail `task done` also runs (DIVE-1830, status.sh:1501). It is a separate rail
# with its own harness, it reads the forge through a different helper than the one
# stubbed above, and stubbing it here would have this file grading that rail's
# plumbing instead of the hand-over.
db "UPDATE tasks SET handoff_ack_at=datetime('now') WHERE ident='DIVE-F1';"
_refused_477() { grep -qiE "writer != grader|Only '${GRADER}' can grade" <<<"$1"; }
FIXTURE_ACTOR="$OWNER"
_C1OUT=$( cmd_task_done "$ID" --result="closing somebody else's grade. CHANGED: src/x.sh CHECKED: bash tests/x.sh 3/3 pass DELIVERED-SHA: ${SHA} CI: green CRITERIA: (1) -> the run above" 2>&1 )
_refused_477 "$_C1OUT" \
  && ok_t "C1 a close by the seat that merged it is REFUSED, and names the verifier as the only grader (DIVE-477) — the refusal the incident hit" \
  || bad_t "C1 the writer!=grader refusal did not fire" "so C2 below could not discriminate :: ${_C1OUT:0:200}"
FIXTURE_ACTOR="$GRADER"
_C2OUT=$( cmd_task_done "$ID" --result="graded PASS at the merged head. CHANGED: src/x.sh CHECKED: bash tests/x.sh 3/3 pass DELIVERED-SHA: ${SHA} CI: green CRITERIA: (1) -> the run above" 2>&1 )
_refused_477 "$_C2OUT" \
  && bad_t "C2 the VERIFIER must not hit the writer!=grader refusal" "the hand-over put the row on a seat that still cannot grade it :: ${_C2OUT:0:200}" \
  || ok_t "C2 ...and the VERIFIER does not — the hand-over lands the row on the one seat whose close is ungated"
[[ "$(col DIVE-F1 status)" == "todo" ]] \
  && ok_t "C3 ...and until that close lands the row stays todo, i.e. still DISPATCHABLE — a refusal never re-claims it" \
  || bad_t "C3 a refused close changed the row's status" "got $(col DIVE-F1 status)"

echo "── D. the controls: what a hand-over must NOT do ──"
# D1 — the NEGATIVE the row asks for by name. A hand-over must not disturb the
# receiving seat's real, live claim on some OTHER row. Same seat, same tick.
D1=$(seed DIVE-F2 in_progress "$GRADER")
db "UPDATE tasks SET verifier=NULL, merge_owner=NULL, delivery_ref=NULL, started_at='2026-09-22 10:19:17' WHERE ident='DIVE-F2';"
ID3=$(seed DIVE-F3 in_progress "$OWNER"); land "$ID3" DIVE-F3 "$OWNER"
[[ "$(col DIVE-F2 status)" == "in_progress" && "$(col DIVE-F2 started_at)" == "2026-09-22 10:19:17" && "$(col DIVE-F2 assignee)" == "$GRADER" ]] \
  && ok_t "D1 NEGATIVE: the verifier's own in-flight turn on a DIFFERENT row is untouched — the write is scoped to the landed row" \
  || bad_t "D1 the hand-over disturbed an unrelated live claim" "status=$(col DIVE-F2 status) started=$(col DIVE-F2 started_at) asg=$(col DIVE-F2 assignee)"
# D2 — a hand-over RELEASES a claim; it must not RE-OPEN a row. Only in_progress
# is touched, so a blocked row keeps its status and its clock.
ID4=$(seed DIVE-F4 blocked "$OWNER"); land "$ID4" DIVE-F4 "$OWNER"
[[ "$(col DIVE-F4 status)" == "blocked" && "$(col DIVE-F4 assignee)" == "$GRADER" ]] \
  && ok_t "D2 CONTROL: a BLOCKED row is re-homed but keeps its status — a hand-over releases a claim, it does not re-open a row" \
  || bad_t "D2 a blocked row was re-opened" "status=$(col DIVE-F4 status)"
# D3 — the no-op. The verifier already holds it: nothing is re-homed, and in
# particular a genuine in_progress turn by the verifier ON THIS ROW is not reset.
ID5=$(seed DIVE-F5 in_progress "$GRADER")
db "UPDATE tasks SET started_at='2026-09-22 10:00:00' WHERE ident='DIVE-F5';"
_task_merge_landed_handoff "$ID5" DIVE-F5 "$GRADER" "$GRADER" >/dev/null 2>&1
[[ "$(col DIVE-F5 status)" == "in_progress" && "$(col DIVE-F5 started_at)" == "2026-09-22 10:00:00" ]] \
  && ok_t "D3 CONTROL: when the verifier ALREADY holds the row the hand-over is a no-op — its live turn is not cancelled" \
  || bad_t "D3 the no-op path wrote to the row" "status=$(col DIVE-F5 status) started=$(col DIVE-F5 started_at)"

echo "── E. the OTHER exit from the merging stage — same write, same rule ──"
# merge-declined re-homes to the MAKER and had the identical body, so it stranded
# the identical way. Fixed in the same pass rather than left for its own incident.
ID6=$(seed DIVE-F6 in_progress "$OWNER")
# The RECORD first, exactly as cmd_task_merge_declined does it — without it the
# row is still in the merging stage and E3 would be measuring the stage predicate
# rather than the hand-over.
_task_merge_declined_record "$ID6" "$PR" "the queue ejected it; the binding needs re-pointing" "$OWNER" >/dev/null 2>&1
_task_merge_declined_handoff "$ID6" DIVE-F6 "$OWNER" "$MAKER" >/dev/null 2>&1
[[ "$(col DIVE-F6 assignee)" == "$MAKER" ]] \
  && ok_t "E1 merge-declined re-homes to the maker, the seat that can re-point the binding" \
  || bad_t "E1 declined hand-over moved the row" "got $(col DIVE-F6 assignee)"
[[ "$(col DIVE-F6 status)" == "todo" && "$(col DIVE-F6 started_at)" == "<NULL>" ]] \
  && ok_t "E2 ...and it too writes todo with a cleared clock (DIVE-4843)" \
  || bad_t "E2 declined hand-over left a claim" "status=$(col DIVE-F6 status) started=$(col DIVE-F6 started_at)"
[[ "$(picks "$MAKER" "$ID6")" == "1" ]] \
  && ok_t "E3 ...so the maker is dispatched onto it, which is the whole point of both paths" \
  || bad_t "E3 the maker is not dispatchable" "the declined row is stranded the way the landed one was"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
