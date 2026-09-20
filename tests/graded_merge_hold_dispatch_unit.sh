#!/usr/bin/env bash
#
# TIER: nightly — this harness was added by #1025 and took core shard 1/3 from at-cap to 307s
# against its 300s budget (102%, 164 harnesses, on a runner calibrated at 94% of baseline, so
# not runner slowness). It is the newest cost in that shard, so it pays for itself here rather
# than by demoting a guard somebody else argued for. It is a pure-fixture unit test of a picker
# WHERE clause with no flaky surface, which is the safest class to move off the PR path.
# OWED BACK: restore it to core the moment the shard has headroom — it guards DIVE-4604, the
# row-stranding bug, and a regression there is invisible on the board by construction.
# upstream #1009 — a graded row held for merge must land on the seat that owes the merge.
#
# THE STRANDING, as the maintainer measured it: six rows graded ACCEPT, five with their pull
# requests already merged, ages up to three days, all reading `in_progress` with a gate of
# `graded->merge:<seat>` and none of them moving. Two things had to be true at once and both
# were: the grading session STARTED the row and was torn down without resetting it (so
# status='in_progress', and increasingly the assignee is an ephemeral pool clone that no
# longer exists), and EVERY picker opens with `status='todo'` (cmd_heartbeat.sh:2076/:2085).
# The merge-owner arm at :2097 exists for exactly this row and is correct — it just never
# runs, because the enclosing WHERE filtered the row out one line earlier.
#
# THE FIXTURE IS THAT PAIR OF FIELDS, because the issue's last paragraph says the pair IS the
# bug: status='in_progress', assignee = a seat that does not exist, merge_owner = a live seat.
# And the sharpest arm here is M1: moving the assignee WITHOUT clearing the started state
# "will look right and change nothing" — the maintainer verified that by hand on all five
# rows, so this file asserts it rather than trusting it.
# DIVE-2211: name the tree this harness grades. Sourced BEFORE the cd, from BASH_SOURCE, so
# the tree named is the one this FILE lives in rather than $PWD.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
export FIVE_GATE_NO_ANON=1
TMP="$(mktemp -d /tmp/graded-merge-hold.XXXXXX)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
ROOT="$PWD"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh cmd_task.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
AUDIT_LOG="$TMP/audit.log"
mkdir -p "$TASKS_DIR"; set +e
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
tasks_db_init

DEAD=gr-ephemeral-7          # the pool clone that graded it and is now gone
LIVE=quinn                   # the seat that owes the merge
PR=https://github.com/5dive-ai/5dive/pull/981

# THE STRANDED SHAPE, built exactly as the issue describes it.
seed() { # <ident> [status] [assignee]
  db "DELETE FROM tasks WHERE ident='$1';"
  db "INSERT INTO tasks(ident,title,status,kind,created_by,assignee,maker_agent,verifier,
        graded_at,graded_by,graded_verdict,delivery_ref,merge_owner,merge_hold_reason,started_at)
      VALUES('$1','graded, waiting on a merge','${2:-in_progress}','standard','luca',
        '${3:-$DEAD}','dev','$LIVE','2026-09-16 09:00:00','$LIVE','pass','$PR',
        '$LIVE','merger:no-graded-sha-stated','2026-09-16 09:00:00');"
  db "SELECT id FROM tasks WHERE ident='$1';"
}
col() { db "SELECT COALESCE($2,'') FROM tasks WHERE ident='$1';"; }

# --- 0. THE STRANDING IS REAL IN THIS FIXTURE (or every arm below is vacuous) --
id=$(seed DIVE-900)
[[ -n "$id" ]] && ok_t "F0 fixture seeded: status=in_progress, assignee=$DEAD (gone), merge_owner=$LIVE" || bad_t "F0" ""
[[ "$(db "SELECT COUNT(*) FROM tasks WHERE id=${id} AND ${_TASKS_TFV_SQL};")" == "1" ]] \
  && ok_t "F1 ...and it IS graded-and-waiting by the board's own predicate, so the merge-owner arm is the one that should reach it" \
  || bad_t "F1 fixture must satisfy _TASKS_TFV_SQL" ""
[[ -z "$(_hb_pick_tasks "$LIVE" 5 | grep -x "$id")" ]] \
  && ok_t "F2 THE DEFECT, LIVE: the merge owner's tick does NOT see it — status='todo' filtered it out before the merge-owner arm ran" \
  || bad_t "F2 the fixture must reproduce the stranding" "picker already returns it; nothing below is measuring the fix"
[[ -z "$(_hb_pick_tasks "$DEAD" 5 | grep -x "$id")" ]] \
  && ok_t "F2a ...and the assignee's tick does not either, because that seat no longer exists to be iterated" || bad_t "F2a" ""

# --- 1. ACCEPTANCE 1 + 2: the hold write lands the row on the owing seat -------
# The real write, driven through the verify path with the disposition probe stubbed to the
# hold the issue names. `_merge_disp_probe` is the seam: it is the half that talks to GitHub.
_merge_disp_probe() { printf 'hold:merger:no-graded-sha-stated\n'; }
# THE ROSTER IS A SEAM, because acceptance 2 turns on "once the clone is gone" and that is a
# registry fact, not a task-store one. ROSTER_OK=0 answers "unreadable", which is the degrade
# path, and the dead clone is deliberately absent from the list.
ROSTER_OK=1
_task_roster() {
  _TASK_ROSTER_STATE=$( ((ROSTER_OK)) && printf ok || printf unknown )
  # `ops` is on it because that is who `_merge_hold_seat` resolves the `merger`
  # role to on a real box, and DIVE-4604's move needs POSITIVE knowledge that the
  # owner is a seat the roster carries. The dead clone stays off it.
  _TASK_ROSTER=$(printf '%s\n' "$LIVE" dev main ops)
}
_gate_version_vs_installed() { :; }
task_actor() { printf '%s\n' "$LIVE"; }
task_actor_claim() { ACTOR_BOARD="$LIVE"; }

id=$(seed DIVE-901)
out=$(cmd_task_verify DIVE-901 --cmd=true --no-done 2>&1); rc=$?
[[ "$(col DIVE-901 status)" == "todo" ]] \
  && ok_t "A1 ACCEPTANCE 1: the held row is back at status='todo' — the column both pickers filter on" \
  || bad_t "A1 status must be reset" "status=[$(col DIVE-901 status)] rc=$rc out=[${out:0:200}]"
[[ -z "$(col DIVE-901 started_at)" ]] \
  && ok_t "A1a ...and started_at is NULL, the second half of the pair _hb_reclaim writes at cmd_heartbeat.sh:2868" \
  || bad_t "A1a started_at must be cleared" "started_at=[$(col DIVE-901 started_at)]"
# WHO the owner resolves to is the EXISTING rule and not this fix's business: the
# disposition says `merger`, and `_merge_hold_seat` degrades an unresolvable merge seat to
# maker_agent rather than stamping a name the roster has never heard of (DIVE-4571). So the
# arms read the owner OFF THE ROW after the write, and assert the two things this fix owes:
# the assignee is that seat, and that seat's tick returns the row.
owner=$(col DIVE-901 merge_owner)
[[ -n "$owner" ]] \
  && ok_t "A2 the hold resolved an owner and recorded it ($owner)" || bad_t "A2 owner must resolve" ""
[[ "$(col DIVE-901 assignee)" == "$owner" ]] \
  && ok_t "A2a ACCEPTANCE 2: the assignee was on a seat the roster does not carry, so it moved to that same owner — one owner on the row, not two" \
  || bad_t "A2a assignee must equal the owner" "assignee=[$(col DIVE-901 assignee)] owner=[$owner]"
[[ "$(col DIVE-901 assignee)" != "$DEAD" ]] \
  && ok_t "A2b ...so the row no longer names a seat that does not exist" || bad_t "A2b" ""
[[ -n "$(_hb_pick_tasks "$owner" 5 | grep -x "$id")" ]] \
  && ok_t "A3 ACCEPTANCE 1, MEASURED AT THE PICKER: the owing seat's next tick returns this row, with no human running task assign" \
  || bad_t "A3 picker must return it" "picked=[$(_hb_pick_tasks "$owner" 5 | tr '\n' ' ')]"
[[ -n "$(_hb_pick_task "$owner" | grep -x "$id")" ]] \
  && ok_t "A3a ...and the LIMIT-1 picker the direct-claim path uses returns it too" || bad_t "A3a" ""
[[ -z "$(_hb_pick_tasks "$DEAD" 5 | grep -x "$id")" ]] \
  && ok_t "A3b ...and the dead clone's tick does not, so the row moved rather than being shared" || bad_t "A3b" ""

# --- 1b. DIVE-4604: A LIVE ASSIGNEE IS MOVED TOO — ONE OWNER, NOT TWO --------
# The narrow rule (move only a seat that is GONE) shipped first and left the stranding in
# place on a live box. Measured 2026-09-19, after that fix was merged AND installed:
# DIVE-4574 (assignee `main`, alive) and DIVE-4632 (assignee `quinn`, alive) were both back
# at status='in_progress' with merge_owner=ops, and `task doctor` called both undispatchable.
# The status pair is necessary and NOT sufficient: it holds only until something claims the
# row again, and every other dispatch path keys on the ASSIGNEE, not on merge_owner — the
# loop-defect forced wake ("forced wake of quinn onto DIVE-4632: stage_owner=quinn"), a goal
# wake, a hand `task assign`. The picker's merge-owner arm is the only reader merge_owner
# has, so ONE claim by the old assignee hides the row from it again, permanently.
id=$(seed DIVE-905 in_progress dev)          # assignee IS on the roster, and alive
cmd_task_verify DIVE-905 --cmd=true --no-done >/dev/null 2>&1
owner905=$(col DIVE-905 merge_owner)
[[ -n "$owner905" && "$(col DIVE-905 assignee)" == "$owner905" ]] \
  && ok_t "A6 a LIVE assignee is handed to the merge owner as well — the row ends with ONE owner, so no other dispatch path can re-claim it away from the merge" \
  || bad_t "A6 a live assignee must move to the owner" "assignee=[$(col DIVE-905 assignee)] owner=[$(col DIVE-905 merge_owner)]"
[[ "$(col DIVE-905 status)" == "todo" && -z "$(col DIVE-905 started_at)" ]] \
  && ok_t "A6a ...and the STATUS PAIR still resets, which is the half that makes either owner's tick reach it" \
  || bad_t "A6a status pair must still reset" "status=[$(col DIVE-905 status)]"
[[ -n "$(_hb_pick_tasks "$owner905" 5 | grep -x "$id")" ]] \
  && ok_t "A6b ...and the owing seat's tick returns it" || bad_t "A6b owner must pick it up" "picked=[$(_hb_pick_tasks "$owner905" 5 | tr '\n' ' ')]"
[[ -z "$(_hb_pick_tasks dev 5 | grep -x "$id")" ]] \
  && ok_t "A6c ...and the ex-assignee's tick does not, so a claim by that seat can no longer put the row back at in_progress where the merge-owner arm cannot see it" \
  || bad_t "A6c the ex-assignee must not still pick it" "picked=[$(_hb_pick_tasks dev 5 | tr '\n' ' ')]"

ROSTER_OK=0
id=$(seed DIVE-906)                           # assignee gone, but the roster cannot be read
cmd_task_verify DIVE-906 --cmd=true --no-done >/dev/null 2>&1
[[ "$(col DIVE-906 assignee)" == "$DEAD" ]] \
  && ok_t "A7 DEGRADE, NEVER GUESS: an unreadable roster is evidence of neither death nor life, so the assignee is left alone — the move needs POSITIVE knowledge that the owner is a seat the heartbeat wakes" \
  || bad_t "A7 must not move on an unknown roster" "assignee=[$(col DIVE-906 assignee)]"
[[ "$(col DIVE-906 status)" == "todo" ]] \
  && ok_t "A7a ...while the status half still runs, so dispatch is restored either way" || bad_t "A7a" ""
ROSTER_OK=1

# --- 2. ACCEPTANCE 3: doctor names the shape AND the seat ----------------------
id=$(seed DIVE-902)
reason=$(db "SELECT COALESCE(reason,'') FROM ($(_task_doctor_board_sql)) WHERE ident='DIVE-902';")
[[ "$reason" == "graded-merge-held" ]] \
  && ok_t "A4 ACCEPTANCE 3: task doctor classifies the stranded row as undispatchable (graded-merge-held)" \
  || bad_t "A4 doctor must classify it" "reason=[$reason]"
owes=$(db "SELECT COALESCE(owes_merge,'') FROM ($(_task_doctor_board_sql)) WHERE ident='DIVE-902';")
[[ "$owes" == "$LIVE" ]] \
  && ok_t "A4a ...and NAMES THE SEAT THAT OWES THE MERGE ($owes), which is the half the acceptance bullet asks for" \
  || bad_t "A4a doctor must name the owing seat" "owes=[$owes]"
[[ -n "$(_task_doctor_explain graded-merge-held)" \
   && "$(_task_doctor_explain graded-merge-held)" != "undispatchable" ]] \
  && ok_t "A4b ...with a remedy of its own, not the bare 'undispatchable' fallback" || bad_t "A4b" ""
# NOT NOISE: a row that is NOT held must not acquire the finding.
db "UPDATE tasks SET merge_hold_reason=NULL WHERE ident='DIVE-902';"
[[ -z "$(db "SELECT COALESCE(reason,'') FROM ($(_task_doctor_board_sql)) WHERE ident='DIVE-902';")" ]] \
  && ok_t "A4c ...and a graded row with no hold is NOT reported — the finding is the hold, not the grade" || bad_t "A4c false positive" ""
db "UPDATE tasks SET merge_hold_reason='merger:no-graded-sha-stated', status='todo' WHERE ident='DIVE-902';"
[[ -z "$(db "SELECT COALESCE(reason,'') FROM ($(_task_doctor_board_sql)) WHERE ident='DIVE-902';")" ]] \
  && ok_t "A4d ...and a held row that IS at todo is not reported either: it is dispatchable, which is the whole point" || bad_t "A4d" ""

# --- 3. ACCEPTANCE 4: the hold itself still refuses ---------------------------
# The issue asks explicitly that this survive, with a test that asserts it. It is the rule
# that a grade binds to a COMMIT, not to a pull request.
[[ "$(_merge_disp_decide MERGEABLE OPEN abc123 '' '')" == "hold:merger:no-graded-sha-stated" ]] \
  && ok_t "A5 ACCEPTANCE 4: an ungraded head is still REFUSED — no graded sha stated" || bad_t "A5" ""
[[ "$(_merge_disp_decide MERGEABLE OPEN '' deadbeef '')" == "hold:merger:head-sha-unreadable" ]] \
  && ok_t "A5a ...and an unreadable head is still refused" || bad_t "A5a" ""
[[ "$(_merge_disp_decide MERGEABLE OPEN aaaa1111 bbbb2222 '')" == "hold:merger:graded-sha-is-not-the-head" ]] \
  && ok_t "A5b ...and a head that has MOVED since the grade is still refused (DIVE-2656 read forwards)" || bad_t "A5b" ""
[[ "$(_merge_disp_decide MERGEABLE OPEN aaaa1111aaaa aaaa1111 '')" != hold:merger:graded-sha-is-not-the-head ]] \
  && ok_t "A5c ...while a prefix match is still accepted, so an abbreviated sha does not false-refuse" || bad_t "A5c" ""

# --- 4. MUTANTS ---------------------------------------------------------------
# M1 IS THE ONE THE ISSUE ASKS FOR BY NAME: "A fix that moves the assignee without also
# clearing the started state will look right and change nothing."
id=$(seed DIVE-903)
db "UPDATE tasks SET assignee='$LIVE' WHERE ident='DIVE-903';"   # the assignee move, alone
[[ "$(col DIVE-903 assignee)" == "$LIVE" && "$(col DIVE-903 status)" == "in_progress" ]] \
  && ok_t "M1a MUTANT setup: assignee moved to the owing seat, status left at in_progress" || bad_t "M1a" ""
[[ -z "$(_hb_pick_tasks "$LIVE" 5 | grep -x "$id")" ]] \
  && ok_t "M1 MUTANT — the half-fix the issue warns about changes NOTHING: the row is on the right seat and STILL invisible to both pickers. This is why the status reset is not optional." \
  || bad_t "M1 half-fix must not dispatch" "the picker returned it, so A1/A1a are not what makes A3 pass"
db "UPDATE tasks SET status='todo', started_at=NULL WHERE ident='DIVE-903';"
[[ -n "$(_hb_pick_tasks "$LIVE" 5 | grep -x "$id")" ]] \
  && ok_t "M1b ...and adding the status pair alone makes it dispatchable, so the pair is exactly the operative change" || bad_t "M1b" ""

# M2: the doctor arm, struck from the classifier.
mut=$(_task_doctor_reason_case_sql '' '' 0 | sed "s/'graded-merge-held'/'NEVER-MATCHES'/")
[[ "$(printf '%s' "$mut" | grep -c 'NEVER-MATCHES')" == "1" ]] \
  && ok_t "M2a MUTANT setup: the classifier arm is struck exactly once" || bad_t "M2a" ""
id=$(seed DIVE-904)
[[ "$(db "SELECT COALESCE((${mut}),'') FROM tasks WHERE ident='DIVE-904';")" != "graded-merge-held" ]] \
  && ok_t "M2 MUTANT — with the arm struck, doctor reports NOTHING for a stranded row: 'no undispatchable rows' over six stalled ones, which is the reported symptom" \
  || bad_t "M2 mutant must stop classifying" ""

# M3: the hold, struck. Asserts A5 is not vacuous.
mutf="$TMP/decide_mut.sh"
sed "s|^  \[\[ -n \"\$graded\" \]\] || {| : \&\& {|" "$ROOT/src/task/delivery.sh" >/dev/null 2>&1
awk '{ if ($0 ~ /printf .hold:merger:no-graded-sha-stated.; return 0; }/) next; print }' \
    "$ROOT/src/task/delivery.sh" > "$mutf"
[[ "$(diff "$ROOT/src/task/delivery.sh" "$mutf" | grep -c '^<')" == "1" ]] \
  && ok_t "M3a MUTANT setup: the no-graded-sha refusal is removed, exactly one line" \
  || bad_t "M3a" "changed=$(diff "$ROOT/src/task/delivery.sh" "$mutf" | grep -c '^<')"
( source "$mutf" 2>/dev/null
  [[ "$(_merge_disp_decide MERGEABLE OPEN abc123 '' '')" != "hold:merger:no-graded-sha-stated" ]] ) \
  && ok_t "M3 MUTANT — with that line gone the ungraded head is no longer refused, so A5 is measuring the rule and not a constant" \
  || bad_t "M3 mutant must drop the refusal" ""

printf -- '-----\n'
printf 'graded_merge_hold_dispatch: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
