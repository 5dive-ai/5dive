#!/usr/bin/env bash
# DIVE-979 isolated unit harness for dependency-aware heartbeat scheduling.
#
# Exercises _hb_pick_task (cmd_heartbeat.sh) over a small dep graph on a
# throwaway tasks.db — never touches the live shared board (STATE_DIR -> tmp,
# same posture as goal_add_unit.sh). Asserts: a todo with an OPEN blocker is
# never handed out; a blocker going done/cancelled makes the dependent
# eligible; within a priority tier the longer critical path is preferred; and
# priority still dominates critical-path depth.
# Run: bash tests/heartbeat_pick_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-pick-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
