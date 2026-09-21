#!/usr/bin/env bash
# DIVE-4654 — a merge pressed on the FORGE must leave the board's MERGING stage.
#
# THE DEADLOCK, as ops measured it on DIVE-4632 (2026-09-20): the pull request
# merged on the forge at 19:08:15Z, nothing was owed by anyone, and nine hours
# later a forced wake printed
#
#     stage=MERGING stage-owner=ops assignee=quinn pickable-by-quinn=no
#
# The tick dispatches on the stage OWNER, the close is gated on the ASSIGNEE, and
# the only verb that exited the stage (`task merge`) is bound to the seat named in
# graded_by — which on that row deliberately was NOT the seat that can push.
# Dispatched and unable to act; able to act and never dispatched.
#
# WHAT THIS FILE GRADES, and in the order the row's acceptance states it:
#   A  a row whose bound PR is merged on the forge LEAVES the stage, with no
#      `task merge` and no credential  (acceptance 1)
#   B  a row whose PR is NOT merged still holds at MERGING and still dispatches
#      to the merge owner  (acceptance 3, the negative control)
#   C  the assignee is pickable once the stage is exited, and is NOT pickable
#      before it  (acceptance 4 — the picker's own answer, not a re-derivation)
#   D  standing, idempotence, a re-pointed binding, and the refusals
#   M  mutants: the two lines that ARE the fix, reverted one at a time, must make
#      this file red.
#
# THE PROBE IS A SEAM, never a live GitHub: `_gate_gh` is stubbed, so the REAL
# `_merge_landed_read` runs and its credential argument stays observable — the
# claim that this verb needs no machine account is graded, not asserted.
# DIVE-2211: name the tree this harness grades. Sourced BEFORE the cd, from
# BASH_SOURCE, so the tree named is the one this FILE lives in rather than $PWD.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
export FIVE_GATE_NO_ANON=1
TMP="$(mktemp -d /tmp/task-merge-landed.XXXXXX)"
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
AUDIT_LOG="$TMP/audit.log"   # never the host's /var/log/5dive layout
mkdir -p "$TASKS_DIR"; set +e
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
tasks_db_init

OWNER=ops          # the seat the stage dispatches to, and the one that can push
GRADER=quinn       # graded_by — and, on the measured row, the assignee too
MAKER=dev
PR=https://github.com/5dive-ai/ops/pull/20
SHA=81b7fd9c0e14a2b5d6e8f0a1b2c3d4e5f6071823
AT=2026-09-19T19:08:15Z

# --- the store fixture: the DIVE-4632 shape --------------------------------
seed() { # <ident> [status] [assignee] [verifier]
  db "DELETE FROM tasks WHERE ident='$1';"
  db "INSERT INTO tasks(ident,title,status,kind,created_by,assignee,maker_agent,verifier,
        graded_at,graded_verdict_at,graded_by,graded_verdict,handoff_delivered_at,
        delivery_ref,merge_owner,merge_hold_reason,started_at)
      VALUES('$1','graded, merged on the forge','${2:-todo}','standard','ops',
        '${3:-$GRADER}','$MAKER','${4:-$GRADER}','2026-09-19 18:40:00',
        '2026-09-19 18:40:00','$GRADER','pass','2026-09-19 18:00:00','$PR',
        '$OWNER','merger:no-graded-sha-stated','2026-09-19 18:00:00');"
  db "SELECT id FROM tasks WHERE ident='$1';"
}
tfv()  { db "SELECT COUNT(*) FROM tasks WHERE ident='$1' AND ${_TASKS_TFV_SQL};"; }
col()  { db "SELECT COALESCE($2,'-') FROM tasks WHERE ident='$1';"; }
owner_of() { db "SELECT $(_tasks_merge_owner_sql) FROM tasks WHERE ident='$1';"; }
picks() { _hb_pick_tasks "$1" 20 | grep -cx "$2"; }

# --- the GitHub seam -------------------------------------------------------
# The token is recorded in a FILE: every call below is inside a command
# substitution (a subshell), and a variable set there does not reach this scope.
TOKF="$TMP/tok"
_gate_gh_payload="MERGED|$SHA|$AT"; _gate_gh_rc=0
_gate_gh() { printf '[%s]' "$1" >"$TOKF"; shift 2
             [[ -n "$_gate_gh_payload" ]] && printf '%s\n' "$_gate_gh_payload"
             return "$_gate_gh_rc"; }
ACT="$OWNER"
task_actor_claim() { ACTOR_BOARD="$ACT"; }
task_actor() { printf '%s\n' "$ACT"; }

# ===========================================================================
# F — THE FIXTURE REPRODUCES THE DEADLOCK (or every arm below is vacuous)
# ===========================================================================
id=$(seed DIVE-4632)
[[ -n "$id" ]] && ok_t "F0 fixture seeded (id=$id): graded PASS by $GRADER, bound to $PR, merge_owner=$OWNER, assignee=$GRADER" || bad_t "F0 seed" ""
[[ "$(tfv DIVE-4632)" == "1" ]] \
  && ok_t "F1 the row IS in the MERGING stage by the board's own predicate" || bad_t "F1 fixture must satisfy _TASKS_TFV_SQL" ""
[[ "$(owner_of DIVE-4632)" == "$OWNER" ]] \
  && ok_t "F2 ...and the stage owner the tick dispatches to is '$OWNER'" || bad_t "F2 owner" "$(owner_of DIVE-4632)"
[[ "$(picks "$OWNER" "$id")" == "1" ]] \
  && ok_t "F3 ...so the picker hands the row to '$OWNER' (the dispatch that fired four times on the real row)" || bad_t "F3 owner dispatched" ""
[[ "$(picks "$GRADER" "$id")" == "0" ]] \
  && ok_t "F4 THE DEADLOCK, LIVE: the ASSIGNEE — the only seat that may close it — is NOT pickable, excluded by the same predicate" \
  || bad_t "F4 assignee must be excluded before the fix" "the fixture does not reproduce the lockout; C1 below would prove nothing"

# ===========================================================================
# A — ACCEPTANCE 1: the row leaves MERGING, with no `task merge`
# ===========================================================================
out=$(cmd_task_merge_landed DIVE-4632 2>&1); rc=$?
(( rc == 0 )) && ok_t "A1 'task merge-landed' run by the MERGE OWNER exits 0 — the seat the stage dispatches to now has a verb for it" \
  || bad_t "A1 rc" "rc=$rc out=$out"
[[ "$(cat "$TOKF" 2>/dev/null)" == "[]" ]] \
  && ok_t "A1a THE CREDENTIAL CLAIM: the forge was asked with an EMPTY token — recording a landing resolves no machine account" \
  || bad_t "A1a credential-free" "token seen: '$(cat "$TOKF" 2>/dev/null)'"
[[ "$(col DIVE-4632 merge_landed_sha)" == "$SHA" && "$(col DIVE-4632 merge_landed_ref)" == "$PR" \
   && "$(col DIVE-4632 merge_landed_by)" == "$OWNER" && "$(col DIVE-4632 merge_landed_at)" != "-" ]] \
  && ok_t "A2 THE RECORD: sha, the binding it was recorded against, the recording seat and a timestamp are all on the row" \
  || bad_t "A2 record" "sha=$(col DIVE-4632 merge_landed_sha) ref=$(col DIVE-4632 merge_landed_ref) by=$(col DIVE-4632 merge_landed_by) at=$(col DIVE-4632 merge_landed_at)"
[[ "$(col DIVE-4632 merge_landed_at)" != "$AT" ]] \
  && ok_t "A2a ...and merge_landed_at is when it was RECORDED, never the forge's mergedAt backdated onto the row" || bad_t "A2a not backdated" ""
[[ "$(tfv DIVE-4632)" == "0" ]] \
  && ok_t "A3 ACCEPTANCE 1: the row has LEFT the MERGING stage — and no 'task merge' and no credential were involved" \
  || bad_t "A3 stage exited" "still matches _TASKS_TFV_SQL"
[[ "$(col DIVE-4632 merge_owner)" == "-" && "$(col DIVE-4632 merge_hold_reason)" == "-" ]] \
  && ok_t "A4 ...the merge hold is retired: a landed pull request is owed a merge by nobody" || bad_t "A4 hold retired" ""
[[ "$out" == *"NO MERGE PERFORMED"* && "$out" == *"LEFT the merging stage"* && "$out" == *"owed now is a close"* ]] \
  && ok_t "A5 ...and the operator line says a landing was RECORDED, not that this seat merged anything" || bad_t "A5 wording" "$out"

# ===========================================================================
# C — ACCEPTANCE 4: the picker's own answer, before and after
# ===========================================================================
[[ "$(picks "$GRADER" "$id")" == "1" ]] \
  && ok_t "C1 ACCEPTANCE 4: the ASSIGNEE is now pickable — pickable-by-assignee is no longer 'no' on a row with no stage-owner action left" \
  || bad_t "C1 assignee pickable" "the picker still refuses the only seat that can close it"
[[ "$(picks "$OWNER" "$id")" == "0" ]] \
  && ok_t "C2 ...and the merge owner is NO LONGER dispatched: the no-op wake that cost a session each time is gone" \
  || bad_t "C2 owner no longer dispatched" "the row still wakes '$OWNER'"

# ===========================================================================
# D — idempotence, the handoff, standing, and the refusals
# ===========================================================================
was=$(col DIVE-4632 merge_landed_at)
out=$(cmd_task_merge_landed DIVE-4632 2>&1); rc=$?
{ (( rc == 0 )) && [[ "$out" == *"ALREADY RECORDED"* && "$(col DIVE-4632 merge_landed_at)" == "$was" ]]; } \
  && ok_t "D1 a SECOND run is a seat re-reading the board, not a second event: exit 0, says so, rewrites nothing" \
  || bad_t "D1 idempotent" "rc=$rc out=$out at-was=$was at-now=$(col DIVE-4632 merge_landed_at)"

# A re-pointed delivery is a DIFFERENT pull request, so the row must re-enter the
# stage rather than carry the old landing onto the new binding.
db "UPDATE tasks SET delivery_ref='https://github.com/5dive-ai/ops/pull/21' WHERE ident='DIVE-4632';"
[[ "$(tfv DIVE-4632)" == "1" ]] \
  && ok_t "D2 A RE-POINTED BINDING RE-ENTERS MERGING: a landing recorded against a ref the row no longer carries confers nothing" \
  || bad_t "D2 re-pointed binding" "the stale landing still holds the row out of the stage"

# The handoff: on a row assigned to its MAKER, the exit must land the row on the
# seat whose close is ungated, or the deadlock has only moved one seat over.
id2=$(seed DIVE-4633 todo "$MAKER" "$GRADER")
_gate_gh_payload="MERGED|$SHA|$AT"; _gate_gh_rc=0; ACT="$OWNER"
out=$(cmd_task_merge_landed DIVE-4633 2>&1); rc=$?
{ (( rc == 0 )) && [[ "$(col DIVE-4633 assignee)" == "$GRADER" ]]; } \
  && ok_t "D3 on a row assigned to its MAKER the exit hands it to the VERIFIER, whose close is ungated (DIVE-4520)" \
  || bad_t "D3 handoff" "rc=$rc assignee=$(col DIVE-4633 assignee)"
[[ "$(picks "$GRADER" "$id2")" == "1" && "$(picks "$MAKER" "$id2")" == "0" ]] \
  && ok_t "D3a ...and the picker follows: the closing seat is dispatched and the maker is not woken onto work it does not owe" \
  || bad_t "D3a handoff dispatch" "verifier=$(picks "$GRADER" "$id2") maker=$(picks "$MAKER" "$id2")"

# ACCEPTANCE 3 — THE NEGATIVE CONTROL. An unmerged pull request changes nothing.
id3=$(seed DIVE-4634)
_gate_gh_payload="OPEN|null|null"; _gate_gh_rc=0; ACT="$OWNER"
out=$(cmd_task_merge_landed DIVE-4634 2>&1); rc=$?
(( rc != 0 )) && ok_t "B1 ACCEPTANCE 3: an UNMERGED pull request is REFUSED — this verb records only a landing the forge itself reports" \
  || bad_t "B1 unmerged refused" "rc=$rc out=$out"
[[ "$(col DIVE-4634 merge_landed_at)" == "-" && "$(col DIVE-4634 merge_owner)" == "$OWNER" ]] \
  && ok_t "B1a ...and NOTHING was written: no landing, and the hold is still on the row" || bad_t "B1a nothing written" ""
[[ "$(tfv DIVE-4634)" == "1" && "$(picks "$OWNER" "$id3")" == "1" ]] \
  && ok_t "B1b ...so the row still HOLDS at MERGING and still dispatches to '$OWNER', exactly as today" || bad_t "B1b still dispatches" ""
_gate_gh_payload=""; _gate_gh_rc=1
out=$(cmd_task_merge_landed DIVE-4634 2>&1); rc=$?
{ (( rc != 0 )) && [[ "$(col DIVE-4634 merge_landed_at)" == "-" ]]; } \
  && ok_t "B2 FAILS TOWARDS TODAY: a GitHub that cannot be asked is a refusal too, so an unreadable forge never records a landing" \
  || bad_t "B2 unreadable refused" "rc=$rc"

# STANDING. The row names three seats; nobody else moves it.
id4=$(seed DIVE-4635)
_gate_gh_payload="MERGED|$SHA|$AT"; _gate_gh_rc=0
ACT=marketing
out=$(cmd_task_merge_landed DIVE-4635 2>&1); rc=$?
{ (( rc != 0 )) && [[ "$out" == *"none of them"* && "$(col DIVE-4635 merge_landed_at)" == "-" ]]; } \
  && ok_t "D4 a seat the row does not name is REFUSED: the record moves a row, so it is not board-wide reconciliation" \
  || bad_t "D4 standing" "rc=$rc out=$out"
ACT="$GRADER"
out=$(cmd_task_merge_landed DIVE-4635 2>&1); rc=$?
(( rc == 0 )) && ok_t "D5 ...and the GRADER may still record it — the fix removes a constraint, it does not add one" || bad_t "D5 grader allowed" "rc=$rc out=$out"

# A row that is not in the stage at all, and a terminal row.
db "DELETE FROM tasks WHERE ident='DIVE-4636';"
db "INSERT INTO tasks(ident,title,status,kind,created_by,assignee,delivery_ref)
    VALUES('DIVE-4636','ungraded','todo','standard','ops','$OWNER','$PR');"
ACT="$OWNER"
out=$(cmd_task_merge_landed DIVE-4636 2>&1); rc=$?
{ (( rc != 0 )) && [[ "$out" == *"NOT in the merging stage"* ]]; } \
  && ok_t "D6 an UNGRADED row is refused by name: recording an exit cannot stand in for a grade" || bad_t "D6 ungraded refused" "rc=$rc out=$out"
db "UPDATE tasks SET status='done' WHERE ident='DIVE-4635';"
out=$(cmd_task_merge_landed DIVE-4635 2>&1); rc=$?
(( rc != 0 )) && ok_t "D7 a terminal row is refused — it is owed no merge and records no landing" || bad_t "D7 terminal refused" "rc=$rc"
out=$(cmd_task_merge_landed 2>&1); rc=$?
(( rc != 0 )) && ok_t "D8 no ident is a usage refusal, not a scan of the board" || bad_t "D8 no ident" "rc=$rc"
out=$(cmd_task_merge_landed --help 2>&1); rc=$?
{ (( rc == 0 )) && [[ "$out" == "usage: 5dive task merge-landed"* ]]; } \
  && ok_t "D9 --help answers with its OWN usage line (tests/task_subverb_help_unit.sh's contract)" || bad_t "D9 help" "rc=$rc out=$out"
[[ -n "$(grep -E '^    merge-landed\)' src/task/dispatch.sh)" ]] \
  && ok_t "D10 ...and the verb is reachable: the label is in the task dispatch table" || bad_t "D10 dispatch label" ""

# ===========================================================================
# E — THE BOARD SAYS SO. A stage exit that paints the row plain 'todo' again is
# DIVE-3098's silence one stage later: the reader cannot tell a merged row owed a
# close from work nobody has started.
# ===========================================================================
id5=$(seed DIVE-4637 todo "$GRADER" "$GRADER")
_gate_gh_payload="MERGED|$SHA|$AT"; _gate_gh_rc=0; ACT="$OWNER"
board_before=$(cmd_task_ls 2>&1)
out=$(cmd_task_merge_landed DIVE-4637 2>&1)
board_after=$(cmd_task_ls 2>&1)
[[ "$board_before" == *"graded->merge:$OWNER"* ]] \
  && ok_t "E1 before: the board paints the row graded->merge:$OWNER" || bad_t "E1 board before" "$board_before"
[[ "$board_after" == *"merged->close:$GRADER"* ]] \
  && ok_t "E2 after: the board paints it merged->close:$GRADER — the merge happened, the CLOSE is owed, and by whom" \
  || bad_t "E2 board after" "$board_after"
show=$(cmd_task_show DIVE-4637 2>&1)
[[ "$show" == *"MERGED ON THE FORGE"* && "$show" == *"${SHA:0:12}"* && "$show" == *"owed a CLOSE"* ]] \
  && ok_t "E3 ...and task show names the merge commit, when it was recorded and by whom, where the hold used to be" \
  || bad_t "E3 show" "$show"

# ===========================================================================
# M — MUTANTS. The two lines that ARE the fix, reverted one at a time.
# ===========================================================================
MUT="$TMP/mut"; mkdir -p "$MUT"
# (1) THE PREDICATE. Without the conjunct, a recorded landing does not exit the
# stage — which is the whole defect.
cp src/lib/tasks_db.sh "$MUT/tasks_db.sh"
python3 - "$MUT/tasks_db.sh" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
old="       AND NOT (${_TASKS_MERGE_LANDED_SQL})\n"
assert s.count(old)==1
open(p,'w').write(s.replace(old,"       -- MUTANT: the DIVE-4654 conjunct reverted\n"))
PY
if bash -n "$MUT/tasks_db.sh" 2>/dev/null; then
  ( set +e
    _TASKS_TFV_SQL=""; source "$MUT/tasks_db.sh" >/dev/null 2>&1
    got=$(db "SELECT COUNT(*) FROM tasks WHERE ident='DIVE-4633' AND ${_TASKS_TFV_SQL};" 2>/dev/null)
    [[ "$got" == "1" ]] && exit 0 || exit 1 ) \
    && ok_t "M1 MUTANT (predicate reverted): the recorded landing does NOT exit the stage — A3 and C1 are red on it, the defect live" \
    || bad_t "M1 mutant must keep the row in MERGING" "the reverted predicate still exits the stage; A3/C1 are not measuring the conjunct"
else
  bad_t "M1 mutant parses" "the mutated tasks_db.sh is not valid bash"
fi
# (2) THE WRITE. Without the record, the predicate has nothing to read.
cp src/task/delivery.sh "$MUT/delivery.sh"
sed -i 's@^        merge_landed_at=datetime(.now.),$@        merge_landed_at=NULL, -- MUTANT@' "$MUT/delivery.sh"
m_hits=$(grep -c 'merge_landed_at=NULL, -- MUTANT' "$MUT/delivery.sh")
{ [[ "$m_hits" == "1" ]] && bash -n "$MUT/delivery.sh"; } \
  && ok_t "M2 MUTANT (the stamp reverted to NULL) substitutes exactly once and still parses — a recorder that records nothing" \
  || bad_t "M2 substitution" "hits=$m_hits"
m_diff=$(diff src/task/delivery.sh "$MUT/delivery.sh" | grep -c '^[<>]')
[[ "$m_diff" == "2" ]] \
  && ok_t "M2a ...and it is otherwise the shipped file, exactly one line different" || bad_t "M2a diff size" "changed lines=$m_diff"
( set +e
  source "$MUT/delivery.sh" >/dev/null 2>&1
  db "UPDATE tasks SET merge_landed_at=NULL, merge_landed_ref=NULL WHERE ident='DIVE-4634';"
  _task_merge_landed_record "$(db "SELECT id FROM tasks WHERE ident='DIVE-4634';")" "$SHA" "$AT" "$OWNER" "$PR" >/dev/null 2>&1
  [[ "$(db "SELECT COUNT(*) FROM tasks WHERE ident='DIVE-4634' AND ${_TASKS_TFV_SQL};")" == "1" ]] && exit 0 || exit 1 ) \
  && ok_t "M3 MUTANT (the stamp): the row stays in MERGING after a 'successful' record — A3 is red on it" \
  || bad_t "M3 mutant keeps the row in MERGING" "the stampless recorder still exits the stage"

printf -- '-----\n'
printf 'task_merge_landed: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
