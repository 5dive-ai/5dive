#!/usr/bin/env bash
# TIER: nightly — 36s measured on the control-plane VM (bare `bash tests/task_close_needs_a_reason_unit.sh`,
# built tree, 2026-08-05): does not fit the 300s PR core, where it would be 12% of the whole
# DIVE-3340 (13 arms added, M/N/P): 12.5s on the control plane, bare bash in a SRC worktree with
# no built bundle, against a 9.3s baseline run of origin/main's copy of this file on the same box
# and the same src — so the arms cost +3.2s (two samples each, low sample kept per the one-sided-
# noise rule). That 12.5s is a DIFFERENT instrument from the 36s above, not a refutation of it, so
# the header number and the tier are left standing rather than replaced across instruments —
# re-tiering on a number measured a different way is how a stale claim gets minted.
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

# ── M/P (DIVE-3340): BOTH REFUSALS NAME THE HUMAN-SIDE EXIT ───────────────────
# Arms H..I above prove the named exit WORKS. They cannot see that it is the wrong
# exit for most readers of the message. Measured on a customer box 2026-08-12: the
# box owner tried to cancel his own row through the chat bot, was told "withdraw it
# first", and the withdraw refused him — `--withdraw` authorizes on
# human/filer/lead/coordinator and a person typing into a bot is NONE of those (the
# command executes on an agent seat and the human's identity deliberately does not
# travel through the bot: DIVE-1401/DIVE-2330 fail closed on purpose). Two
# individually-correct refusals composing into a closed loop.
#
# ANSWERING is the exit that needs no authorization at all, and neither refusal named
# it. These arms assert it is named on both, and named FIRST on the one a human reads.
#
# THESE ARE THE NEGATIVE CONTROLS, and the direction of the mutation is the point:
# the pre-DIVE-3340 text passes any assertion that only greps for "withdraw", so a
# substring test written against the old message grades nothing here. Restoring either
# old string with the code untouched must red these arms and only these.
# See community/wiki/a-refusal-that-names-a-smaller-set-than-the-code-checked.md.
#
# Fixture, not `task need`: same reasoning as arm H — this grades refusal TEXT, and
# routing through the filing path drags the tier floor and the ping rails into an
# assertion that is not about them.
gate_row() { # $1=title suffix  $2=need_type  $3=gate_filed_by  -> prints ident
  local _g; _g=$(add "DIVE-3340 $1" --assignee=dev)
  db "UPDATE tasks SET need_type=$(sqlq "$2"), ask='which surface?', need_answered_at=NULL,
        gate_filed_by=$(sqlq "$3"), tier=2 WHERE ident=$(sqlq "$_g");"
  printf '%s' "$_g"
}
gate_type_of() { db "SELECT COALESCE(need_type,'') FROM tasks WHERE ident=$(sqlq "$1");"; }

M=$(gate_row "cancel refusal" decision dev)
[[ "$(gate_type_of "$M")" == "decision" ]] \
  && ok_t "M/REACHABILITY: the fixture row really carries a pending decision gate" \
  || bad_t "M/REACHABILITY: gate fixture did not take — every M arm is vacuous" "got '$(gate_type_of "$M")'"
as dev cmd_task_cancel "$M" --result="abandoning this" >/dev/null; m_rc=$?
m_err=$(cat "$TMP"/err)
(( m_rc != 0 )) && [[ "$(status_of "$M")" == "todo" ]] \
  && ok_t "M/REACHABILITY: the cancel is refused, so the text under test is the one that shipped" \
  || bad_t "M/REACHABILITY: the cancel was not refused — the M text arms grade nothing" "rc=$m_rc status=$(status_of "$M")"
[[ "$m_err" == *"5dive task answer $M --value="* ]] \
  && ok_t "M1: the cancel refusal names the ANSWER route (the exit a human can take)" \
  || bad_t "M1: the cancel refusal does not name the answer route" "err='$m_err'"
[[ "$m_err" == *"5dive task need $M --withdraw"* ]] \
  && ok_t "M2: and it still names --withdraw (the agent-side exit is not dropped)" \
  || bad_t "M2: --withdraw vanished from the cancel refusal" "err='$m_err'"
# ORDER, asserted rather than assumed: the acceptance is the human route FIRST. Both
# substrings are already proven present by M1/M2, so the prefix-length compare is a
# real position test and not two absences reading equal.
m_pre_ans="${m_err%%5dive task answer*}"; m_pre_wd="${m_err%%5dive task need*}"
(( ${#m_pre_ans} < ${#m_pre_wd} )) \
  && ok_t "M3: the answer route is named BEFORE --withdraw (${#m_pre_ans} < ${#m_pre_wd})" \
  || bad_t "M3: --withdraw is still named first — the door the reader cannot open" "ans@${#m_pre_ans} withdraw@${#m_pre_wd}"
# The withdraw route now carries its authorized set inline, so a chat-bot seat learns
# from the FIRST refusal that route 2 is closed to it instead of discovering it on the
# second. Without this the message still sends the reader into the loop, just later.
[[ "$m_err" == *"org coordinator"* && "$m_err" == *"genuine human unix caller"* ]] \
  && ok_t "M4: the cancel refusal states WHO may withdraw, so a bot seat is not sent into the loop" \
  || bad_t "M4: --withdraw is still published as unconditionally available" "err='$m_err'"

# The route is TYPE-SHAPED, and publishing the wrong verb is the same defect one layer
# down: a secret must never be typed into the board and a manual gate records that the
# step was PERFORMED, so both take `task answer` with NO --value. A single hardcoded
# `--value=` sentence would be a refusal naming a route that refuses.
for _gt3340 in manual secret; do
  N=$(gate_row "cancel refusal / $_gt3340" "$_gt3340" dev)
  [[ "$(gate_type_of "$N")" == "$_gt3340" ]] \
    || bad_t "N/REACHABILITY[$_gt3340]: gate fixture did not take — the arm is vacuous" "got '$(gate_type_of "$N")'"
  as dev cmd_task_cancel "$N" --result="abandoning this" >/dev/null
  n_err=$(cat "$TMP"/err)
  [[ "$n_err" == *"5dive task answer $N"* && "$n_err" == *"NO --value"* && "$n_err" != *"--value=<answer>"* ]] \
    && ok_t "N[$_gt3340]: the refusal's answer route says NO --value (never a value on this type)" \
    || bad_t "N[$_gt3340]: the refusal published the --value form on a $_gt3340 gate" "err='$n_err'"
done

# ── P: the WITHDRAW refusal points a non-filer at answering ───────────────────
# The other half of the loop. Pre-DIVE-3340 this message was a pure list of
# principals: correct (DIVE-2382 fixed the SET) and actionless, so `cancel` sent the
# reader here and here sent them nowhere.
P=$(gate_row "withdraw refusal" decision dev)
p_lead=$(_gate_route_reviewer dev); p_coord=$(_task_resolve_coordinator)
# DISTINCTNESS, and it is load-bearing: if the caller happens to BE the filer's lead
# or the coordinator the withdraw SUCCEEDS and every P arm below grades a message that
# was never emitted. A fixture where two authorization routes share one agent name
# tests their union and neither of them (DIVE-2382's own fixture had this bug).
[[ "outsider" != "dev" && "outsider" != "$p_lead" && "outsider" != "$p_coord" ]] \
  && ok_t "P/DISTINCTNESS: caller 'outsider' is not the filer (dev), its lead ('${p_lead:-none}') or the coordinator ('${p_coord:-none}')" \
  || bad_t "P/DISTINCTNESS: the caller shares an authorization route — the P arms are vacuous" "lead='$p_lead' coord='$p_coord'"
as outsider cmd_task_need "$P" --withdraw >/dev/null; p_rc=$?
p_err=$(cat "$TMP"/err)
(( p_rc != 0 )) && [[ "$(gate_type_of "$P")" == "decision" ]] \
  && ok_t "P/REACHABILITY: a non-filer agent's withdraw is refused and the gate survives (rc=$p_rc)" \
  || bad_t "P/REACHABILITY: the withdraw was NOT refused — the P text arms grade nothing" "rc=$p_rc need_type='$(gate_type_of "$P")'"
[[ "$p_err" == *"5dive task answer $P --value="* ]] \
  && ok_t "P1: the withdraw refusal points the refused caller at ANSWERING" \
  || bad_t "P1: the withdraw refusal still only lists who may — no route out" "err='$p_err'"
# DIVE-2382's set must survive the addition. Dropping the enumeration to make room for
# the route would re-create the failure that ticket fixed: a legitimate
# filer/lead/coordinator has to be able to find their own name in the list.
[[ "$p_err" == *"the gate's filer (dev)"* && "$p_err" == *"org coordinator (${p_coord:-none})"* ]] \
  && ok_t "P2: and DIVE-2382's resolved-value enumeration is still intact" \
  || bad_t "P2: the DIVE-2382 principal enumeration regressed" "err='$p_err'"

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
