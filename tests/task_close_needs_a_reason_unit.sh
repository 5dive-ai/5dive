#!/usr/bin/env bash
# TIER: nightly — 36s measured on the control-plane VM (bare `bash tests/task_close_needs_a_reason_unit.sh`,
# built tree, 2026-08-05): does not fit the 300s PR core, where it would be 12% of the whole
# budget on its own. Nothing here is network-priced — the cost is ~20 real `task add`/close/
# reject round-trips through the audit, reclaim and cascade rails, and the arms that make this
# harness worth having (F, G, K, L) are precisely the ones that need the REAL rail rather than a
# fixture, so there is no cheaper shape that still grades the defect. Its two nearest neighbours
# (task_close_preserves_done_at_unit.sh, 52.4s) are nightly for the same reason. Editing it always
# runs it, so the PR that changes this guard still grades it.
# DIVE-2773 — a FIRST close must carry a reason, on BOTH verbs; a cancel must not
# delete a live human gate; and `task reject` must stop hand-rolling the result guard.
#
# THE FILING'S OWN MECHANISM WAS WRONG AND THAT IS WHY THIS HARNESS EXISTS.
# The row was filed as "cancel accepts an EMPTY result while done refuses one".
# It does not. `_task_guard_result_over_closed` RETURNS EARLY when the row carries
# no result yet — with nothing recorded there are no bytes at risk, which is
# correct for destroy-protection and means a blank FIRST close was accepted by
# BOTH verbs all along (olivia, on scratch row DIVE-2774: open row,
# `task done --result=""`, rc=0, empty result stored). So arms A-D grade a NEW
# predicate — "this row is being closed and nothing has ever been written about
# why" — and B/D exist specifically because a port of the existing check to
# `cancel` would leave them RED while looking like a fix.
#
# WHAT THE MEASUREMENT WAS, since the guard is only worth its cost against it:
# seven empty-result cancels on the board in three days, every one a daily
# recurring row, arriving in bursts (three inside 186 seconds). DIVE-2472 was the
# same act by the same actor on the same template WITH a reason and is still
# explicable six days on; DIVE-2683 and DIVE-2737 are not.
#
# ARMS E-G ARE THE NON-VACUITY HALF and are not decoration. A guard that refused
# everything would pass every refusal arm here; E (a close WITH a reason lands),
# F (a bare RE-close stays the rc=0 no-op it has always been) and G (a
# maker→verifier delivery is not a close and must not be caught) are what make
# the refusals mean something narrower than "closes are broken".
#
# Run: bash tests/task_close_needs_a_reason_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades.
# NOTE the absence of `2>/dev/null` — the helper's stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
# DIVE-2518: impersonate through the SEALED seam, not via USER=.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"

SRC=src
TMP="$(mktemp -d /tmp/task-close-reason-unit.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh lib/registry.sh \
         lib/disk.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_push.sh cmd_org.sh \
         cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1; mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }

tasks_db_init
as() { local who="$1"; shift; ( actor_seam_as "${who}"; "$@" ) 2>"$TMP"/err; }

status_of()   { db "SELECT status                        FROM tasks WHERE ident=$(sqlq "$1");"; }
res_of()      { db "SELECT COALESCE(result,'')           FROM tasks WHERE ident=$(sqlq "$1");"; }
assignee_of() { db "SELECT COALESCE(assignee,'')         FROM tasks WHERE ident=$(sqlq "$1");"; }
gate_ans_of() { db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE ident=$(sqlq "$1");"; }

add() { JSON_MODE=1 cmd_task_add "$@" 2>"$TMP"/err | jq -r '.data.ident // empty'; }

# ── instrument: without impersonation the actor-scoped guards make arms vacuous
actor_is() { ( actor_seam_as "$1"; task_actor ); }
[[ "$(actor_is dev2)" == "dev2" ]] \
  && ok_t "INSTRUMENT: harness impersonates an actor (task_actor -> dev2)" \
  || bad_t "INSTRUMENT: actor impersonation broken" "got '$(actor_is dev2)' — arms are vacuous"

# ── A: `task cancel --result=""` on a first close is REFUSED ──────────────────
# The shape measured seven times in three days.
A=$(add "A empty cancel" --assignee=dev)
as dev cmd_task_cancel "$A" --result="" >/dev/null; a_rc=$?
(( a_rc != 0 )) && [[ "$(status_of "$A")" == "todo" ]] \
  && ok_t "A: empty-result FIRST cancel refused (rc=$a_rc), row left open" \
  || bad_t "A: empty-result first cancel was accepted" "rc=$a_rc status=$(status_of "$A")"

# ── B: the SAME on `done` — the arm a port-of-the-existing-check leaves red ───
B=$(add "B empty done" --assignee=dev)
as dev cmd_task_done "$B" --result="" >/dev/null; b_rc=$?
(( b_rc != 0 )) && [[ "$(status_of "$B")" == "todo" ]] \
  && ok_t "B: empty-result FIRST done refused (rc=$b_rc) — the DIVE-2774 demo, now closed" \
  || bad_t "B: empty-result first done was accepted (DIVE-2774 shape survives)" "rc=$b_rc status=$(status_of "$B")"

# ── C/D: a BARE first close (no --result at all) is the same event ────────────
# `--result=""` and an absent flag both leave the column permanently blank, and
# the ledger keeps only a sha256 of it, so neither is distinguishable afterwards
# from a reason nobody ever wrote.
C=$(add "C bare done" --assignee=dev)
as dev cmd_task_done "$C" >/dev/null; c_rc=$?
(( c_rc != 0 )) && [[ "$(status_of "$C")" == "todo" ]] \
  && ok_t "C: BARE first done refused (rc=$c_rc)" \
  || bad_t "C: bare first done was accepted" "rc=$c_rc status=$(status_of "$C")"

D=$(add "D bare cancel" --assignee=dev)
as dev cmd_task_cancel "$D" >/dev/null; d_rc=$?
(( d_rc != 0 )) && [[ "$(status_of "$D")" == "todo" ]] \
  && ok_t "D: BARE first cancel refused (rc=$d_rc)" \
  || bad_t "D: bare first cancel was accepted" "rc=$d_rc status=$(status_of "$D")"

# ── E: NON-VACUITY — a close WITH a reason still lands, on both verbs ─────────
E=$(add "E done with a reason" --assignee=dev)
as dev cmd_task_done "$E" --result="shipped as #123" >/dev/null; e_rc=$?
(( e_rc == 0 )) && [[ "$(status_of "$E")" == "done" && "$(res_of "$E")" == "shipped as #123" ]] \
  && ok_t "E: a first done WITH a reason lands and stores it" \
  || bad_t "E: a reasoned first done did not land" "rc=$e_rc status=$(status_of "$E") result='$(res_of "$E")'"

E2=$(add "E2 cancel with a reason" --assignee=dev)
as dev cmd_task_cancel "$E2" --result="stale dated instance, not work declined" >/dev/null; e2_rc=$?
(( e2_rc == 0 )) && [[ "$(status_of "$E2")" == "cancelled" ]] \
  && ok_t "E2: a first cancel WITH a reason lands" \
  || bad_t "E2: a reasoned first cancel did not land" "rc=$e2_rc status=$(status_of "$E2")"

# ── F: NON-VACUITY — a BARE RE-close is still the rc=0 no-op it always was ────
# "First" is meant literally. tests/task_close_preserves_done_at_unit.sh (arm B)
# depends on this bare re-close landing; refusing it here would silently make
# that harness's done_at arm vacuous rather than red.
as dev cmd_task_done "$E" >/dev/null; f_rc=$?
(( f_rc == 0 )) && [[ "$(status_of "$E")" == "done" ]] \
  && ok_t "F: a bare RE-close of an already-closed row stays rc=0 (idempotency preserved)" \
  || bad_t "F: the bare re-close regressed" "rc=$f_rc status=$(status_of "$E")"

# ── G: NON-VACUITY — a maker→verifier DELIVERY is not a close ─────────────────
# `task done` on a row whose verifier differs from its assignee routes and
# returns BEFORE the reason check. Catching it here would refuse every handoff on
# the loop rail, which is the way this guard could have done real damage.
G=$(add "G delivery is not a close" --assignee=mk --verifier=vfy)
as mk cmd_task_done "$G" >/dev/null; g_rc=$?
(( g_rc == 0 )) && [[ "$(assignee_of "$G")" == "vfy" && "$(status_of "$G")" != "done" ]] \
  && ok_t "G: a bare maker→verifier delivery still ROUTES, not refused (assignee -> vfy)" \
  || bad_t "G: the reason guard caught a delivery" "rc=$g_rc assignee=$(assignee_of "$G") status=$(status_of "$G")"

# ── H: a cancel over a LIVE unanswered gate is refused ────────────────────────
# The gate columns are set as a FIXTURE rather than through `task need`: this arm
# grades the close guard's predicate (need_type set, need_answered_at NULL), and
# routing it through the filing path would drag the tier floor and the ping rails
# into an assertion that is not about them. Arm I then uses the REAL
# `need --withdraw` verb, so the exit the refusal names is exercised for real.
H=$(add "H cancel over a live gate" --assignee=dev)
db "UPDATE tasks SET need_type='decision', ask='surface: fleet or personal?',
      need_answered_at=NULL, gate_filed_by='dev', tier=2 WHERE ident=$(sqlq "$H");"
# The fixture must actually BE the shape under test, or every arm below reads as
# a pass for the wrong reason. `db` prints sqlite's error and returns 0, so an
# unchecked UPDATE that names a column the schema does not have (the first draft
# of this arm used `need_ask`) leaves the row UNGATED and the refusal arms then
# grade an ordinary cancel.
[[ "$(db "SELECT COALESCE(need_type,'')||'/'||COALESCE(need_answered_at,'-') FROM tasks WHERE ident=$(sqlq "$H");")" == "decision/-" ]] \
  && ok_t "H/REACHABILITY: the fixture row really carries a PENDING gate" \
  || bad_t "H/REACHABILITY: gate fixture did not take — arms H/H2/I are vacuous" \
           "got '$(db "SELECT COALESCE(need_type,'')||'/'||COALESCE(need_answered_at,'-') FROM tasks WHERE ident=$(sqlq "$H");")'"
as dev cmd_task_cancel "$H" --result="abandoning this" >/dev/null; h_rc=$?
(( h_rc != 0 )) && [[ "$(status_of "$H")" == "todo" ]] \
  && ok_t "H: cancel over a live gate refused (rc=$h_rc) EVEN WITH a good reason — the stronger condition" \
  || bad_t "H: cancel deleted a live human gate" "rc=$h_rc status=$(status_of "$H")"

# ── H2: and `done` over the same row is still refused (DIVE-555 control) ──────
# Both close verbs refused is the state that makes arm I load-bearing: without a
# reachable withdraw, this row would have NO close verb at all and the next agent
# would invent one.
as dev cmd_task_done "$H" --result="abandoning this" >/dev/null; h2_rc=$?
(( h2_rc != 0 )) \
  && ok_t "H2: done over the same live gate still refused (DIVE-555 intact, rc=$h2_rc)" \
  || bad_t "H2: DIVE-555 regressed" "rc=$h2_rc"

# ── I: THE NAMED EXIT IS REACHABLE — withdraw, then the cancel lands ──────────
# A refusal that names an exit which does not work is worse than one that names
# none: it spends the operator's trust and then makes them improvise.
as dev cmd_task_need "$H" --withdraw >/dev/null; i_rc=$?
# A withdrawal CLEARS need_type (and archives the gate to gate_history); it does
# NOT stamp need_answered_at, which is the point — a withdrawal is not an answer,
# so nothing is recorded as having been answered by anyone. Asserting on
# need_answered_at (the first draft of this arm) reads a withdrawal as a failure.
i_type=$(db "SELECT COALESCE(need_type,'') FROM tasks WHERE ident=$(sqlq "$H");")
i_ans=$(gate_ans_of "$H")
(( i_rc == 0 )) && [[ -z "$i_type" && -z "$i_ans" ]] \
  && ok_t "I/REACHABILITY: 'task need --withdraw' clears the gate (rc=0, need_type NULL) WITHOUT recording an answer" \
  || bad_t "I/REACHABILITY: the exit named in the refusal does not work" "rc=$i_rc need_type='$i_type' need_answered_at='$i_ans'"
as dev cmd_task_cancel "$H" --result="withdrew the gate, then abandoned the work" >/dev/null; i2_rc=$?
(( i2_rc == 0 )) && [[ "$(status_of "$H")" == "cancelled" ]] \
  && ok_t "I: after the withdrawal the cancel lands (rc=0)" \
  || bad_t "I: the row is wedged — neither close verb works after a withdrawal" "rc=$i2_rc status=$(status_of "$H")"

# ── K: `task reject` on a DELIVERED (todo) row PRESERVES the maker's result ───
# THE DIVE-2762 CLASS, ONE VERB OVER. reject kept a PRIVATE copy of the old,
# wrong predicate — `if [[ $st == 'done' && -n $prev ]]` — so its preservation
# fired only on a CLOSED row. A delivered row is `todo` by design, so on the
# ORDINARY bounce (the one the loop manufactures every iteration) the branch did
# not fire and the bare UPDATE replaced the maker's record with the rejection
# text. Built through the REAL rail — deliver, then bounce — because the whole
# defect is that the rail's own state (`todo`) is the one the old predicate missed.
K=$(add "K reject preserves a delivered result" --assignee=mk --verifier=vfy)
as mk cmd_task_done "$K" --result="MAKER-RECORD: built X, see PR #9" >/dev/null
k_delivered_st=$(status_of "$K")
[[ "$k_delivered_st" == "todo" && "$(res_of "$K")" == *"MAKER-RECORD"* ]] \
  && ok_t "K/REACHABILITY: the delivered row is 'todo' and carries the maker's result — the exact cell the old predicate skipped" \
  || bad_t "K/REACHABILITY: fixture is not the delivered shape" "status=$k_delivered_st result='$(res_of "$K")'"
as vfy cmd_task_reject "$K" --feedback="missing the migration" >/dev/null; k_rc=$?
k_res=$(res_of "$K")
(( k_rc == 0 )) && [[ "$k_res" == *"MAKER-RECORD: built X, see PR #9"* ]] \
  && ok_t "K: the maker's result SURVIVES the reject (preserved under a seam)" \
  || bad_t "K: reject destroyed the maker's result on the ordinary bounce" "rc=$k_rc result='$k_res'"
[[ "$k_res" == *"missing the migration"* ]] \
  && ok_t "K2: ...and the verifier's feedback is recorded alongside it" \
  || bad_t "K2: the feedback was lost" "result='$k_res'"

# ── L: no regression on the shape the OLD private branch did handle ───────────
# The recorded verifier withdrawing their own grade (DIVE-2112) reopens a CLOSED
# row. The shared guard's default on a closed row is to REFUSE, so this arm is
# what pins that reject asks it to APPEND instead.
L=$(add "L reject over a closed row" --assignee=mk --verifier=vfy)
as mk cmd_task_done "$L" --result="MAKER-RECORD-L" >/dev/null
as vfy cmd_task_done "$L" --result="VERIFIER-GRADE-L: pass" >/dev/null
[[ "$(status_of "$L")" == "done" ]] \
  && ok_t "L/REACHABILITY: the row is CLOSED and graded before the reject" \
  || bad_t "L/REACHABILITY: fixture never closed" "status=$(status_of "$L")"
as vfy cmd_task_reject "$L" --feedback="withdrawing my grade" >/dev/null; l_rc=$?
l_res=$(res_of "$L")
(( l_rc == 0 )) && [[ "$l_res" == *"VERIFIER-GRADE-L: pass"* && "$l_res" == *"withdrawing my grade"* ]] \
  && ok_t "L: a verifier reopening their own closed grade still preserves it (not refused, not replaced)" \
  || bad_t "L: the closed-row reject regressed" "rc=$l_rc result='$l_res'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
