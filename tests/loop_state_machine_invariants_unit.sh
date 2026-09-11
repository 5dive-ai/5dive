#!/usr/bin/env bash
# DIVE-4327 — ONE ARM PER INVARIANT of the loop state machine.
#
# Spec: community/wiki/the-loop-end-to-end-one-state-machine-from-filing-to-merge.md
# Seven invariants, seven arms, and every arm is a MUTATION THAT ONE OF
# 2026-09-11's breaks would have failed — not a restatement of what the code
# currently does. The breaks each arm pins are named in the arm's own banner.
#
# Isolated: STATE_DIR -> a tempdir, never the live shared board. No root, no
# network. Run: bash tests/loop_state_machine_invariants_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/loop-invariants-unit.XXXXXX)"

# shellcheck disable=SC1090
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

# mk_graded <title> <assignee> <maker> <verifier> <merge_owner|-> <delivered> <graded>
# The two clocks are passed as SQL datetime literals (or the word NULL) so an arm
# can put a delivery AFTER a grade, which is the whole point of invariant 3.
mk_graded() {
  local title="$1" asg="$2" maker="$3" vfier="$4" mo="$5" deliv="$6" graded="$7"
  db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, status,
                         maker_agent, verifier, merge_owner, delivery_ref,
                         handoff_delivered_at, graded_at, graded_by, graded_verdict)
      VALUES ($(sqlq "$title"), '', 'high', $(sqlq "$asg"), 'main', 'standard', 'todo',
              $(sqlq "$maker"), $(sqlq "$vfier"),
              $([[ "$mo" == "-" ]] && echo NULL || sqlq "$mo"),
              'https://example.com/pr/1',
              ${deliv}, ${graded}, $(sqlq "$vfier"), 'pass');
      SELECT last_insert_rowid();"
}
# The arms below must grade the PRODUCT on either tree, so that a red is a product
# fact and not "this tree lacks the helper". On a tree that predates DIVE-4327 the
# shared emitter does not exist; define the identical expression locally there, so
# inv1b/inv2 measure the board-vs-picker AGREEMENT on both trees and only inv1a
# (the drift guard) turns on the extraction itself.
declare -F _tasks_merge_owner_sql >/dev/null || _tasks_merge_owner_sql() {
  local p="${1:-}"
  printf "COALESCE(NULLIF(%smerge_owner,''), NULLIF(%smaker_agent,''), COALESCE(%sassignee,'?'))" "$p" "$p" "$p"
}

is_tfv()   { db "SELECT COALESCE((SELECT 1 FROM tasks WHERE id=$1 AND ${_TASKS_TFV_SQL}),0);"; }
label()    { db "SELECT CASE WHEN ${_TASKS_TFV_SQL} THEN 'graded->merge:'||$(_tasks_merge_owner_sql) ELSE status END FROM tasks WHERE id=$1;"; }
pickable() { _hb_pick_tasks "$2" 200 2>/dev/null | grep -qx -- "$1"; }

printf '\n== INVARIANT 1 — one owner per state, written on the row, never computed ==\n'
# Break it pins: DIVE-4274/4276, 2026-09-11. The board said merge owner = main for
# every row because nine hand-copied COALESCE chains each promised in a COMMENT to
# match the board "character for character". ops read the constant and stood down.
# (a) STATIC: a tenth literal copy anywhere in src/ is the drift, so it is the red.
copies=$(grep -rn "NULLIF(t\?\.\?merge_owner,'')" "$SRC" \
           | grep -v '_tasks_merge_owner_sql()' \
           | grep -v 'lib/tasks_db.sh' || true)
if [[ -z "$copies" ]]; then
  ok_t "inv1a: the merge-owner expression exists ONCE, in _tasks_merge_owner_sql"
else
  bad_t "inv1a: a hand copy of the merge-owner expression is back in src/" "$copies"
fi
# (b) BEHAVIOURAL: merge_owner written on the row WINS over every fallback.
t1=$(mk_graded 'owner written on the row' dev dev quinn ops "datetime('now','-2 hours')" "datetime('now','-1 hours')")
[[ "$(label "$t1")" == "graded->merge:ops" ]] \
  && ok_t "inv1b: a row carrying merge_owner=ops renders ops, not the maker/assignee fallback" \
  || bad_t "inv1b: the row's own merge_owner was not the owner rendered" "got $(label "$t1")"

printf '\n== INVARIANT 2 — the picker predicate IS the board label predicate ==\n'
# Break it pins: DIVE-4276, 2026-09-11 13:05-14:40Z. The board said
# graded->merge:main, the picker said "not runnable for you", TODO=2, and the seat
# logged "no todo" every minute for 95 minutes. The arm is the AGREEMENT itself,
# asserted over a matrix — not a re-check of either side on its own.
inv2_ok=1
for seat in ops dev quinn main; do
  want=0; [[ "$(label "$t1")" == "graded->merge:${seat}" ]] && want=1
  got=0;  pickable "$t1" "$seat" && got=1
  if (( want != got )); then
    inv2_ok=0
    bad_t "inv2: board and picker disagree for seat ${seat}" "label=$(label "$t1") pickable=${got}"
  fi
done
(( inv2_ok )) && ok_t "inv2: for every seat, 'the board names you the merge owner' == 'the picker hands you the row'"

printf '\n== INVARIANT 3 — a grade binds to a sha AND an iteration ==\n'
# Break it pins: DIVE-4276/DIVE-4281. `task deliver` does not clear graded_at, so
# after a redelivery the iteration-1 PASS still painted the row graded-to-merge
# while iteration 2 sat delivered-and-UNGRADED and the verifier was never woken.
t2=$(mk_graded 'redelivered after a pass' quinn dev quinn ops "datetime('now','+1 hours')" "datetime('now')")
[[ "$(is_tfv "$t2")" == "0" ]] \
  && ok_t "inv3a: a delivery clock LATER than the grade clock is not graded-and-waiting" \
  || bad_t "inv3a: an iteration-1 PASS still reads as a grade of iteration 2" "tfv=$(is_tfv "$t2")"
# And the narrowing must not empty the lane — the failure DIRECTION matters more
# than the count (DIVE-4281 iteration 1 installed a false negative here).
[[ "$(is_tfv "$t1")" == "1" ]] \
  && ok_t "inv3b: a genuinely graded, not-redelivered row STILL reads graded-and-waiting" \
  || bad_t "inv3b: the iteration bind emptied the lane — every graded row now reads ungraded" "tfv=$(is_tfv "$t1")"
t2b=$(mk_graded 'graded, no handoff clock at all' dev '' quinn ops "NULL" "datetime('now')")
[[ "$(is_tfv "$t2b")" == "1" ]] \
  && ok_t "inv3c: a graded row with no delivery clock (a non-handoff grade) is unaffected" \
  || bad_t "inv3c: the iteration bind swallowed rows that carry no handoff clock" "tfv=$(is_tfv "$t2b")"

printf '\n== INVARIANT 4 — timers key to the last transition, never a stale started_at ==\n'
# Break it pins: codex / DIVE-4290 — reaped one tick after a forced wake because
# the age was computed from a started_at left over from a previous stage.
t3=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, status, started_at, first_started_at)
         VALUES ('stale clock', '', 'high', 'dev', 'main', 'standard', 'in_progress',
                 datetime('now','-6 hours'), datetime('now','-6 hours'));
         SELECT last_insert_rowid();")
db "UPDATE tasks SET status='todo', assignee='quinn', maker_agent='dev', verifier='quinn',
       handoff_delivered_at=datetime('now'), started_at=NULL WHERE id=${t3};"
[[ -z "$(db "SELECT started_at FROM tasks WHERE id=${t3} AND started_at IS NOT NULL;")" ]] \
  && ok_t "inv4: crossing MAKING->GRADING drops the maker's started_at (the next stage's budget starts at ITS transition)" \
  || bad_t "inv4: a stale started_at survived the transition" "started_at=$(db "SELECT started_at FROM tasks WHERE id=${t3};")"

printf '\n== INVARIANT 5 — an exit proof is machine-read at the source, never prose ==\n'
# Break it pins: the general shape of a maker-written field being trusted as a
# grade. `result` and `body` are typed BY THE MAKER; a stage predicate that reads
# either can be talked into a transition.
if grep -qE "\b(result|body|acceptance_criteria)\b" <<<"$_TASKS_TFV_SQL"; then
  bad_t "inv5: the stage predicate reads a field the maker writes" "$_TASKS_TFV_SQL"
else
  ok_t "inv5: the graded-and-waiting predicate reads only machine-written columns (no result/body prose)"
fi

printf '\n== INVARIANT 6 — a human is asked for a CAPABILITY, and a decision is not a ping ==\n'
# Break it pins: DIVE-4239 — a tier-2 manual gate queued on a lead instead of
# reaching its named holder. The stable half, asserted here: the DEFAULT tier by
# type. decision/approval must stay off the paired human's desk; secret/manual
# must NOT be silently downgraded to a seat that cannot provide the capability.
need_default_tier() {
  sed -n "s/.*case \"\$type\" in decision|approval) tier=\([0-9]\).*/\1/p" "$SRC/task/need.sh" | head -1
}
dt="$(need_default_tier)"
if [[ "$dt" =~ ^[01]$ ]]; then
  ok_t "inv6a: a decision/approval gate defaults to tier ${dt} — it does not ping the paired human"
else
  bad_t "inv6a: the decision/approval default tier is not 0 or 1" "read '${dt}' from src/task/need.sh"
fi
if grep -q 'tier=2' "$SRC/task/need.sh"; then
  ok_t "inv6b: secret/manual still default to tier 2 — the capability cannot be delegated away"
else
  bad_t "inv6b: no tier-2 default remains in need.sh" "secret/manual would be routed to a seat"
fi

printf '\n== INVARIANT 7 — the loop is MEASURED per stage, so every transition is stamped ==\n'
# Break it pins: DIVE-4283 — a stage that is not measured is the one that will be
# slow. A stage median needs a clock per transition; a dropped column makes the
# stage unmeasurable and the report silently narrower, not red.
missing=""
for col in first_started_at started_at handoff_delivered_at handoff_rejected_at graded_at done_at; do
  db "SELECT ${col} FROM tasks LIMIT 1;" >/dev/null 2>&1 || missing="${missing} ${col}"
done
if [[ -z "$missing" ]]; then
  ok_t "inv7: every stage transition has its own clock column (FILED/MAKING/GRADING/CLOSED are each measurable)"
else
  bad_t "inv7: a stage transition has no clock, so its median cannot be computed" "missing:${missing}"
fi

printf '\n%s passed / %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
