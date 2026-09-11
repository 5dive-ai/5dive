#!/usr/bin/env bash
# DIVE-979 isolated unit harness for dependency-aware heartbeat scheduling.
#
# Exercises _hb_pick_task (cmd_heartbeat.sh) over a small dep graph on a
# throwaway tasks.db — never touches the live shared board (STATE_DIR -> tmp,
# same posture as goal_add_unit.sh). Asserts: a todo with an OPEN blocker is
# never handed out; a blocker going done/cancelled makes the dependent
# eligible; within a priority tier the longer critical path is preferred; and
# priority still dominates critical-path depth. DIVE-4053 also pins the human-
# gate boundary on the picker itself: an unanswered gate is not runnable while
# an ungated row assigned to the same agent remains selectable.
# Run: bash tests/heartbeat_pick_unit.sh  (no root, no network).
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-pick-unit.XXXXXX)"

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
set +e   # header.sh enabled `set -e`; asserts below deliberately probe states

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# Insert a standard task, echo its row id. mk <title> <priority> [status]
mk() {
  local title="$1" prio="${2:-medium}" status="${3:-todo}"
  db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, status)
      VALUES ($(sqlq "$title"), '', $(sqlq "$prio"), 'dev', 'main', 'standard', $(sqlq "$status"));
      SELECT last_insert_rowid();"
}
dep() { db "INSERT OR IGNORE INTO task_deps (task_id, blocked_by) VALUES ($1, $2);"; }

# --- Case 1: open blocker is skipped -----------------------------------------
# A (todo) blocks B (todo). Only A is actionable → pick must be A, never B.
A=$(mk "A base"       medium todo)
B=$(mk "B on top of A" medium todo)
dep "$B" "$A"
got=$(_hb_pick_task dev)
[[ "$got" == "$A" ]] && ok_t "open blocker: picks unblocked A ($A), got $got" \
                     || bad_t "open blocker: expected A=$A" "got $got"

# B alone (had A open) must be excluded from any pick while A is open. Prove it
# by making A urgent-but-open is not the point here; instead verify B never wins
# even when B is higher priority than A.
db "UPDATE tasks SET priority='urgent' WHERE id=${B};"
got=$(_hb_pick_task dev)
[[ "$got" == "$A" ]] && ok_t "blocked B stays skipped even at urgent prio (got $got=A)" \
                     || bad_t "blocked urgent B must not be handed out" "got $got, A=$A"
db "UPDATE tasks SET priority='medium' WHERE id=${B};"

# --- Case 2: closing the blocker frees the dependent -------------------------
db "UPDATE tasks SET status='done' WHERE id=${A};"
got=$(_hb_pick_task dev)
[[ "$got" == "$B" ]] && ok_t "blocker done: B ($B) now eligible, got $got" \
                     || bad_t "blocker done: expected B=$B" "got $got"
# cancelled blocker also frees it
db "UPDATE tasks SET status='todo' WHERE id=${A};"    # re-block
db "UPDATE tasks SET status='cancelled' WHERE id=${A};"
got=$(_hb_pick_task dev)
[[ "$got" == "$B" ]] && ok_t "blocker cancelled: B ($B) eligible, got $got" \
                     || bad_t "blocker cancelled: expected B=$B" "got $got"

# --- Case 3: critical-path preference within a priority tier -----------------
# Fresh graph. Two eligible (unblocked) roots at the SAME priority:
#   R1 -> M1 -> L1   (downstream chain length 2)
#   R2               (no dependents, chain length 0)
# Both R1 and R2 are todo with no open blockers. Critical path prefers R1.
db "DELETE FROM task_deps;"; db "DELETE FROM tasks;"
R1=$(mk "R1 root long" medium todo)
M1=$(mk "M1 mid"       medium todo)
L1=$(mk "L1 leaf"      medium todo)
dep "$M1" "$R1"        # M1 blocked_by R1
dep "$L1" "$M1"        # L1 blocked_by M1
R2=$(mk "R2 root short" medium todo)
got=$(_hb_pick_task dev)
[[ "$got" == "$R1" ]] && ok_t "critical path: longer-chain R1 ($R1) preferred, got $got" \
                      || bad_t "critical path: expected R1=$R1" "got $got (R2=$R2)"

# --- Case 4: priority dominates critical path --------------------------------
# Make the short root R2 urgent; it must now win despite R1's longer chain.
db "UPDATE tasks SET priority='urgent' WHERE id=${R2};"
got=$(_hb_pick_task dev)
[[ "$got" == "$R2" ]] && ok_t "priority beats critical path: urgent R2 ($R2) wins, got $got" \
                      || bad_t "priority must dominate: expected R2=$R2" "got $got"

# --- Case 5: nothing actionable → empty --------------------------------------
db "DELETE FROM task_deps;"; db "DELETE FROM tasks;"
X=$(mk "X base" medium todo)
Y=$(mk "Y blocked" medium todo)
dep "$Y" "$X"
db "UPDATE tasks SET status='in_progress' WHERE id=${X};"   # X taken, Y blocked
got=$(_hb_pick_task dev)
[[ -z "$got" ]] && ok_t "no actionable todo → empty pick" \
                || bad_t "expected empty pick" "got $got"

# --- Case 6: an open human gate is not maker work (DIVE-4053) ----------------
# Insert the gated row first so the old picker deterministically selects it by
# id. The ungated row is the positive control: a fix that empties every pick
# fails here even though it would also suppress the gated row.
db "DELETE FROM task_deps;"; db "DELETE FROM tasks;"
G=$(mk "G waiting on a person" urgent todo)
db "UPDATE tasks
       SET need_type='decision', need_answered_at=NULL
     WHERE id=${G};"
U=$(mk "U open and actionable" urgent todo)
got=$(_hb_pick_task dev)
[[ "$got" == "$U" ]] && ok_t "open human gate: skips G ($G) and selects ungated control U ($U)" \
                      || bad_t "open human gate must not be selected while ungated work exists" "got $got, gated=$G, ungated=$U"

# Remove the positive control from the todo queue. The gated row must not become
# selectable merely because it is now the only todo left.
db "UPDATE tasks SET status='in_progress' WHERE id=${U};"
got=$(_hb_pick_task dev)
[[ -z "$got" ]] && ok_t "open human gate: gated-only queue yields no pick" \
                || bad_t "gated-only queue must be empty" "got $got, gated=$G"

# Answering the gate makes the same todo actionable again. This pins the
# need_answered_at half of the predicate: checking need_type alone would keep
# every previously-gated row suppressed forever.
db "UPDATE tasks SET need_answered_at=datetime('now') WHERE id=${G};"
got=$(_hb_pick_task dev)
[[ "$got" == "$G" ]] && ok_t "answered human gate: todo becomes selectable again ($G)" \
                      || bad_t "answered gate must restore selection" "got $got, answered=$G"

# --- Case 7: a graded row waiting on ANOTHER seat's merge is not maker work ---
# (DIVE-4206.) The row is graded, its delivery is bound and the merge is owed by
# `main`, so nothing on it is dev's move. Before this arm the picker handed it
# back and the seat spent a whole session re-deriving "nothing owed by me" —
# 25-45 min per attempt, measured over 400 maker runs.
#
# Insert the graded row FIRST and at the same priority, so the pre-4206 picker
# selects it by id order: if the predicate were dropped this case reds rather
# than passing by luck of the ordering.
db "DELETE FROM task_deps;"; db "DELETE FROM tasks;"
GM=$(mk "GM graded, main owes the merge" urgent todo)
db "UPDATE tasks
       SET graded_at=datetime('now'), graded_by='quinn', graded_verdict='pass',
           maker_agent='dev', verifier='quinn', merge_owner='main',
           delivery_ref='https://example.com/pr/1'
     WHERE id=${GM};"
U2=$(mk "U2 open and actionable" urgent todo)
got=$(_hb_pick_task dev)
[[ "$got" == "$U2" ]] && ok_t "graded->merge:main: skips GM ($GM), selects control U2 ($U2)" \
                      || bad_t "a row waiting on another seat's merge must not be picked" "got $got, graded=$GM, control=$U2"

# Alone in the queue it still must not be handed out — the whole defect is that
# it was, once the control ahead of it was gone.
db "UPDATE tasks SET status='in_progress' WHERE id=${U2};"
got=$(_hb_pick_task dev)
[[ -z "$got" ]] && ok_t "graded->merge:main: merge-waiting-only queue yields no pick" \
                || bad_t "merge-waiting-only queue must be empty" "got $got, graded=$GM"

# THE MERGE OWNER'S OWN ROW IS STILL WORK. Same row, owner flipped to dev: the
# merge is now this seat's move and suppressing it would strand the row nobody
# else can close. Pins the `<> $name` half — a predicate that skipped every
# graded row would pass both assertions above and fail here.
db "UPDATE tasks SET merge_owner='dev' WHERE id=${GM};"
got=$(_hb_pick_task dev)
[[ "$got" == "$GM" ]] && ok_t "graded->merge:dev: this seat owes the merge, row stays selectable ($GM)" \
                      || bad_t "the merge owner's own row must remain selectable" "got $got, graded=$GM"

# And with no merge_owner recorded the board falls back to maker_agent, so the
# same two readings must hold off that column too (the owner expression is the
# board's, and this is the arm of it the fallback exercises).
db "UPDATE tasks SET merge_owner=NULL WHERE id=${GM};"
got=$(_hb_pick_task dev)
[[ "$got" == "$GM" ]] && ok_t "no merge_owner: falls back to maker_agent='dev', still selectable ($GM)" \
                      || bad_t "maker_agent fallback must keep the maker's own row selectable" "got $got, graded=$GM"
db "UPDATE tasks SET maker_agent='codex' WHERE id=${GM};"
got=$(_hb_pick_task dev)
[[ -z "$got" ]] && ok_t "no merge_owner, maker_agent='codex': not dev's move, skipped" \
                || bad_t "maker_agent fallback must skip another seat's merge" "got $got, graded=$GM"

# --- Case 8: DIVE-4326 — the picker reads WHOEVER the disposition recorded -----
# The merge owner of a held row is now `ops`, not the constant `main`, and the
# whole point of the change is that the SAME skip and the SAME wake follow the
# column. So the two readings above must hold with `ops` in it: skipped for every
# other seat, selectable for ops itself. An implementation that special-cased the
# string `main` anywhere in the picker would pass case 7 and red here.
db "UPDATE tasks SET maker_agent='dev', merge_owner='ops' WHERE id=${GM};"
got=$(_hb_pick_task dev)
[[ -z "$got" ]] && ok_t "graded->merge:ops: not dev's move, skipped (DIVE-4326)" \
                || bad_t "a merge owed by ops must not be handed to the maker" "got $got, graded=$GM"
got=$(_hb_pick_task ops)
[[ "$got" == "$GM" ]] && ok_t "graded->merge:ops: ops owes it, so ops can be handed it ($GM)" \
                      || bad_t "the merge owner's own row must remain selectable for ops" "got $got, graded=$GM"
# And main is now just another seat on this row — the arm that would have passed
# silently for the whole life of the constant.
got=$(_hb_pick_task main)
[[ -z "$got" ]] && ok_t "graded->merge:ops: main is no longer hands-on for it (DIVE-4326)" \
                || bad_t "main must not be handed a merge owed by ops" "got $got, graded=$GM"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
