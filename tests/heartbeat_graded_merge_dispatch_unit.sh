#!/usr/bin/env bash
# DIVE-4220 — the seat that HOLDS the merge is woken onto the row, and is told
# the merge is its move.
#
# THE DEFECT THIS PINS. `_hb_pick_tasks` selected `assignee=<seat>` only.
# DIVE-4206 then (correctly) stopped handing a maker a row whose merge is owed by
# someone else — but nothing put that row on the OWNER's queue, so between the two
# it was dispatched to NOBODY and waited until a seat happened to look. Measured
# 2026-09-10 10:45Z: 8 rows in graded->merge, three with the pull request already
# MERGED hours earlier and the row still open.
#
# The two halves are graded TOGETHER on purpose. Waking the owner while the wake
# NOTE still reads "terminal for this goal, someone else acts" is worse than not
# waking them: the seat boots, is told to stand down, and the strand survives with
# a turn spent on it. Arms 5-7 are that half.
# Run: bash tests/heartbeat_graded_merge_dispatch_unit.sh  (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-gm-dispatch-unit.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# mk <title> <assignee> [priority] [status]
mk() {
  local title="$1" who="$2" prio="${3:-urgent}" status="${4:-todo}"
  db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, status)
      VALUES ($(sqlq "$title"), '', $(sqlq "$prio"), $(sqlq "$who"), 'main', 'standard', $(sqlq "$status"));
      SELECT last_insert_rowid();"
}
# grade <id> <maker> <verifier/grader> [merge_owner]
grade() {
  local id="$1" maker="$2" grader="$3" owner="${4:-}"
  db "UPDATE tasks
         SET graded_at=datetime('now'), graded_by=$(sqlq "$grader"), graded_verdict='pass',
             maker_agent=$(sqlq "$maker"), verifier=$(sqlq "$grader"),
             merge_owner=$( [[ -n "$owner" ]] && sqlq "$owner" || printf 'NULL' ),
             delivery_ref='https://github.com/5dive-ai/5dive/pull/1'
       WHERE id=${id};"
}

# --- Arm 1: the GRADER owns the merge on a row assigned to the MAKER ---------
# The exact shape of the 8 stranded rows: assignee is still the maker, the grade
# is quinn's, and the disposition recorded quinn as the seat that owes the merge.
# Before this change neither seat could be woken onto it — dev's pick excluded it
# (DIVE-4206) and quinn's pick never looked past `assignee=quinn`.
db "DELETE FROM task_deps;"; db "DELETE FROM tasks;"
GM=$(mk "GM graded, quinn owes the merge" dev)
grade "$GM" dev quinn quinn
got=$(_hb_pick_task quinn)
[[ "$got" == "$GM" ]] && ok_t "arm 1: merge owner quinn is dispatched onto a row assigned to dev ($GM)" \
                      || bad_t "arm 1: the merge owner must be woken onto the row it owes" "got '$got', row=$GM"

# --- Arm 2: and the maker is still NOT woken onto it (DIVE-4206 preserved) ---
# The negative half. A fix that simply widened the picker to every graded row
# would pass arm 1 and re-open the 25-45min-per-attempt defect DIVE-4206 closed.
got=$(_hb_pick_task dev)
[[ -z "$got" ]] && ok_t "arm 2: the maker is still not woken onto a merge owed by quinn" \
                || bad_t "arm 2: DIVE-4206's exclusion must survive this change" "got '$got', row=$GM"

# --- Arm 3: a NON-graded row assigned elsewhere is still not dispatched ------
# The new arm is scoped by the graded-and-waiting predicate, not by merge_owner
# alone. A row that merely names quinn in merge_owner without a grade or a bound
# delivery must stay off quinn's queue: this is the arm that reds if the TFV
# conjunct is dropped from the OR branch and the picker starts handing out other
# seats' live work.
db "DELETE FROM tasks;"
UG=$(mk "UG assigned to dev, merge_owner quinn, NOT graded" dev)
db "UPDATE tasks SET merge_owner='quinn' WHERE id=${UG};"
got=$(_hb_pick_task quinn)
[[ -z "$got" ]] && ok_t "arm 3: merge_owner alone (no grade, no binding) does not dispatch" \
                || bad_t "arm 3: the second arm must be scoped by the graded-and-waiting predicate" "got '$got', row=$UG"

# --- Arm 4: an unanswered human gate still suppresses the owner's wake -------
# The widened arm must sit INSIDE the runnability guards, not beside them.
db "DELETE FROM tasks;"
GG=$(mk "GG graded, quinn owes the merge, gate open" dev)
grade "$GG" dev quinn quinn
db "UPDATE tasks SET need_type='decision', need_answered_at=NULL WHERE id=${GG};"
got=$(_hb_pick_task quinn)
[[ -z "$got" ]] && ok_t "arm 4: an open human gate suppresses the merge owner's wake too" \
                || bad_t "arm 4: the owner arm must not escape the gate guard" "got '$got', row=$GG"
db "UPDATE tasks SET need_answered_at=datetime('now') WHERE id=${GG};"
got=$(_hb_pick_task quinn)
[[ "$got" == "$GG" ]] && ok_t "arm 4b: answering the gate restores the owner's wake ($GG)" \
                      || bad_t "arm 4b: answered gate must restore selection" "got '$got', row=$GG"

# --- Arm 5: the wake NOTE tells the owner the merge is THEIRS ----------------
# Waking the owner and then telling them to stand down is the strand with a turn
# spent on it, so the note is graded, not just the selection.
db "DELETE FROM tasks;"
N=$(mk "N graded, quinn owes the merge" dev)
grade "$N" dev quinn quinn
note=$(_hb_loop_terminal_clause quinn "$N" "DIVE-9001")
if grep -q "MERGE IS YOURS" <<<"$note"; then
  ok_t "arm 5: the owner's note says the merge is theirs"
else
  bad_t "arm 5: the merge owner must not be told to stand down" "got: ${note:-<empty>}"
fi
grep -q "TERMINAL FOR THIS GOAL" <<<"$note" \
  && bad_t "arm 5b: the owner still got the stand-down clause" "got: $note" \
  || ok_t "arm 5b: the owner does NOT get the 'terminal, someone else acts' clause"
# All three dispositions are named, so the seat does not have to re-derive which
# turn it is in — and the already-merged one is a CLOSE the seat decides, never
# an auto-close (main2: a merged pull request is not a finished row).
#
# DIVE-4520 iteration 2: `task done DIVE-9001` LEFT THIS LIST ON PURPOSE, and its
# absence is now asserted below. This dispatch is the second composer of the
# instruction the row was filed about: on a graded-and-waiting row the assignee is
# still the maker, so a close from the woken seat takes the routing fork,
# re-delivers, and strips the merge standing of the seat being woken — and since
# the guard shipped it is refused outright. Naming the verb that is REFUSED, on
# the branch a merge owner reads first, is the defect, not the wording of it.
# DIVE-4654 SUPERSEDED THE HAND-OFF VERB IN BRANCH (1). It used to be
# `task assign <ident> <verifier>`, which moves the row and leaves it in the
# MERGING stage: the board goes on painting graded->merge, the picker goes on
# excluding the seat the row was just handed to, and this same dispatch fires
# again next tick (ops measured four dispatches on DIVE-4632, three no-ops).
# `task merge-landed` records the landing, exits the stage AND hands the row to
# the closing seat in one act, so branch (1) names it instead. The ARM is
# unchanged in intent: the branch must name a verb that terminates the row.
for want in "ALREADY MERGED" "task merge-landed DIVE-9001" "task merge DIVE-9001" "task reject DIVE-9001"; do
  grep -qF "$want" <<<"$note" \
    && ok_t "arm 5c: the note names '$want'" \
    || bad_t "arm 5c: the note must name '$want'" "got: $note"
done
grep -qF "(dev)" <<<"$note" \
  && ok_t "arm 5d: the red-check bounce names the maker by seat (dev)" \
  || bad_t "arm 5d: the bounce must name the maker" "got: $note"
# --- Arm 5e (DIVE-4520 iteration 2): THE REFUSED VERB IS NOT NAMED AT ALL ------
# The mutant this exists for is the one-word revert: putting
# `'5dive task done ${task_ident}'` back into branch (1). It reds here and
# nowhere else in this suite.
grep -qF "task done" <<<"$note" \
  && bad_t "arm 5e: branch (1) must not name the verb the DIVE-4520 guard refuses" "got: $note" \
  || ok_t "arm 5e: the note names no 'task done' anywhere — the close is the verifier's, after the assign"
# --- Arm 5f: and the hand-off is named for the branch that needs it -----------
# Branch (2) used to end in a bare "then close", which is the same instruction
# one verb later. It must route through the same hand-off as (1).
# DIVE-4654: the phrase moved with the verb — branch (2) now says "record the
# landing exactly as in (1)". Still the same property: (2) does not end in a bare
# "then close", it routes through (1).
grep -qF "record the landing exactly as in (1)" <<<"$note" \
  && ok_t "arm 5f: the merge branch hands off the same way instead of saying 'then close'" \
  || bad_t "arm 5f: branch (2) must route its termination through branch (1)" "got: $note"

# --- Arm 6: the MAKER's note on the same row is unchanged -------------------
# The stand-down clause is still correct for everyone who does not own the merge.
note_m=$(_hb_loop_terminal_clause dev "$N" "DIVE-9001")
grep -q "TERMINAL FOR THIS GOAL" <<<"$note_m" \
  && ok_t "arm 6: the maker still gets the stand-down clause" \
  || bad_t "arm 6: the non-owner's note must be unchanged" "got: ${note_m:-<empty>}"
grep -q "MERGE IS YOURS" <<<"$note_m" \
  && bad_t "arm 6b: the maker was told the merge is theirs" "got: $note_m" \
  || ok_t "arm 6b: the maker is not told the merge is theirs"

# --- Arm 7: a seat that is neither assignee nor owner gets NO note -----------
# The widened read must not start emitting notes about other seats' rows.
note_x=$(_hb_loop_terminal_clause codex "$N" "DIVE-9001")
[[ -z "$note_x" ]] && ok_t "arm 7: an unrelated seat gets no note at all" \
                   || bad_t "arm 7: the widened read leaked another seat's row" "got: $note_x"

# --- Arm 8: merge_owner NULL falls back to maker_agent, both halves ----------
# The owner expression is the board's; the fallback arm must behave identically
# under it, or the picker and the board disagree about who was dispatched.
db "DELETE FROM tasks;"
F=$(mk "F graded, no merge_owner recorded" dev)
grade "$F" dev quinn ""
got=$(_hb_pick_task dev)
[[ "$got" == "$F" ]] && ok_t "arm 8: no merge_owner -> maker_agent dev is still woken ($F)" \
                     || bad_t "arm 8: the maker_agent fallback must keep the maker selectable" "got '$got', row=$F"
got=$(_hb_pick_task quinn)
[[ -z "$got" ]] && ok_t "arm 8b: and quinn, who owns nothing here, is not woken" \
                || bad_t "arm 8b: the fallback must not dispatch to the grader" "got '$got', row=$F"

# --- Arm 9 (DIVE-4520 iteration 2): THE NON-DEGENERATE FIXTURE ---------------
# Every fixture above ties verifier == grader == merge owner, so a composer that
# printed `$name` (the woken seat) instead of the row's VERIFIER would pass arm
# 5c unchanged. The DIVE-4491 shape does not tie them: a TEMP grader (main2)
# holds the merge, the loop's own verifier (quinn) is still on the row, and the
# row is assigned to the maker. The hand-off must name quinn — the seat whose
# close the guard does not refuse — and not main2, who cannot close it.
db "DELETE FROM tasks;"
T=$(mk "T graded by a temp session, loop verifier is quinn" dev)
grade "$T" dev quinn main2
db "UPDATE tasks SET verifier='quinn', graded_by='main2' WHERE id=${T};"
note_t=$(_hb_loop_terminal_clause main2 "$T" "DIVE-9002")
grep -q "MERGE IS YOURS" <<<"$note_t" \
  && ok_t "arm 9: the temp grader that owns the merge still gets the owner's note" \
  || bad_t "arm 9: the merge owner must be woken with the owner note" "got: ${note_t:-<empty>}"
# DIVE-4654: the hand-off is performed BY the verb now, so what the note must
# still get right is WHICH SEAT it names — the row's verifier column (quinn),
# never the woken grading seat (main2), whose own close would re-deliver.
grep -qF "its verifier 'quinn'" <<<"$note_t" \
  && ok_t "arm 9b: ...and the hand-off names the row's VERIFIER (quinn), not the woken seat" \
  || bad_t "arm 9b: the hand-off must name the verifier column, not the grader" "got: $note_t"
grep -qF "task assign DIVE-9002 main2" <<<"$note_t" \
  && bad_t "arm 9c: the hand-off named the grading seat, which cannot close the row" "got: $note_t" \
  || ok_t "arm 9c: ...and never the grading seat, whose own close would re-deliver"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
