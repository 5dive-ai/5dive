#!/usr/bin/env bash
# DIVE-8295: a NEW board numbers its tasks TASK-1, TASK-2 …; a board that already
# holds DIVE rows keeps DIVE. A customer's board (5dive cloud, partner boxes,
# self-hosters) must not show our internal brand on every row, and no existing
# link, branch name or commit ref may change.
#
# THE DEFECT CLASS. Two halves, and the second is the quiet one:
#   1. the default project was seeded prefix='DIVE' on every fresh store;
#   2. idents were pulled out of free text with `DIVE-[0-9]+` (the heartbeat's
#      stale-nudge check, the supervisor's goal-drift probe, `loop install`). On a
#      TASK board those find NOTHING and fail open, so nothing goes red — a stale
#      nudge is simply delivered, a drifting goal is simply not seen.
#
# Arms:
#   F  a fresh board with no knob: `task add` mints TASK-1; show/assign/done work
#      on it by ident.
#   E  a board that already holds DIVE rows keeps DIVE: re-init does not move it,
#      the next row is DIVE-<n+1>, and the creation knob cannot renumber it.
#   H  the heartbeat's nudge ident parser and staleness check on a TASK- ident;
#      the _hb_ident fallback names the board's prefix.
#   S  supervisor goal drift resolves a TASK- goal to its row.
#   R  task add's numbered-follow-up advisory parses a TASK- ident.
#   M  mutant: the pre-fix DIVE-only pattern finds nothing in a TASK nudge, so H
#      is an arm that can go red.
#
# The shared test lib pins FIVEDIVE_TASK_PREFIX=DIVE for the other harnesses; this one
# grades the real default, so it unsets it.
#   bash tests/task_prefix_default_unit.sh   (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
cd "$(dirname "$0")/.."
SRC=src
unset FIVEDIVE_TASK_PREFIX

TMP="$(mktemp -d /tmp/task-prefix-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh lib/disk.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_heartbeat.sh cmd_supervisor.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
mkdir -p "$TMP/audit"
AUDIT_LOG="$TMP/audit/agent-audit.log"; : > "$AUDIT_LOG"
JSON_MODE=0
set +e   # header.sh enabled `set -e`; arms expect non-zero exits

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
chk()   { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected '$2', got '$3'"; }

board() {  # <dir> — point the sourced CLI at a throwaway board
  STATE_DIR="$TMP/$1"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
  mkdir -p "$TASKS_DIR"
}
created_ident() { sed -n 's/.*created \([A-Z][A-Z0-9]*-[0-9]*\).*/\1/p' <<<"$1" | head -1; }

# --- F: a fresh board mints TASK-1 -------------------------------------------
board fresh
tasks_db_init >/dev/null 2>&1
chk "F0: the fresh board's default project is prefix TASK" "TASK" \
  "$(db "SELECT prefix FROM projects WHERE key='dive';")"
out=$( ( cmd_task add "first row" ) 2>&1 )
chk "F1: task add on a fresh board creates TASK-1" "TASK-1" "$(created_ident "$out")"
out=$( ( cmd_task add "second row" ) 2>&1 )
chk "F2: the next row is TASK-2" "TASK-2" "$(created_ident "$out")"
out=$( ( cmd_task show TASK-1 --no-body ) 2>&1 )
[[ "$out" == *"ident = TASK-1"* && "$out" == *"first row"* ]] \
  && ok_t "F3: task show TASK-1 resolves the row" || bad_t "F3: task show TASK-1" "$out"
( cmd_task assign TASK-1 dev ) >/dev/null 2>&1
chk "F4: task assign TASK-1 lands" "dev" "$(db "SELECT assignee FROM tasks WHERE ident='TASK-1';")"
( cmd_task done TASK-1 --result="ok" ) >/dev/null 2>&1
chk "F5: task done TASK-1 lands" "done" "$(db "SELECT status FROM tasks WHERE ident='TASK-1';")"
chk "F6: task_default_prefix reads TASK" "TASK" "$(task_default_prefix)"

# --- E: a board that already holds DIVE rows keeps DIVE ----------------------
# Built the way every existing box was: a board seeded DIVE (the knob reproduces
# the old seed byte-for-byte), with rows on it. Then the CLI that ships this
# change opens it with no knob, as on any box after the upgrade.
board existing
FIVEDIVE_TASK_PREFIX=DIVE tasks_db_init >/dev/null 2>&1
( cmd_task add "old one" ) >/dev/null 2>&1
( cmd_task add "old two" ) >/dev/null 2>&1
chk "E0: precondition — the existing board holds DIVE-1, DIVE-2" "DIVE-1,DIVE-2" \
  "$(db "SELECT group_concat(ident, ',') FROM (SELECT ident FROM tasks ORDER BY id);")"
tasks_db_init >/dev/null 2>&1
out=$( ( cmd_task add "after upgrade" ) 2>&1 )
chk "E1: after the upgrade the next row is still DIVE-3" "DIVE-3" "$(created_ident "$out")"
chk "E2: the default project's prefix did not move" "DIVE" \
  "$(db "SELECT prefix FROM projects WHERE key='dive';")"
# The creation knob only rides the fresh-store arm, and is guarded on counter=0
# besides: replay its SQL on this board by hand and nothing renumbers.
sqlite3 "$TASKS_DB" "$(FIVEDIVE_TASK_PREFIX=FROG _tasks_fresh_prefix_sql)" >/dev/null 2>&1
chk "E3: the creation knob cannot rename a board that holds rows" "DIVE" \
  "$(db "SELECT prefix FROM projects WHERE key='dive';")"
chk "E4: a bad knob value is refused, not half-applied" "" \
  "$(FIVEDIVE_TASK_PREFIX='x;DROP' _tasks_fresh_prefix_sql 2>/dev/null)"

# --- H: the heartbeat's ident parser on a TASK- ident ------------------------
board fresh
NUDGE="[5dive-msg from=task-engine id=n1 tier=admin] TASK-1: still yours — pick it back up, then TASK-2."
chk "H1: the nudge parser finds the FIRST TASK- ident" "TASK-1" "$(_a2a_nudge_ident "$NUDGE")"
why=$(_a2a_stale_nudge_reason dev "$NUDGE"); rc=$?
[[ $rc -eq 0 && "$why" == "TASK-1 is done" ]] \
  && ok_t "H2: a nudge about a done TASK- row is recognised stale" \
  || bad_t "H2: stale TASK- nudge" "rc=$rc why='$why'"
_a2a_stale_nudge_reason dev "[5dive-msg from=lodar id=h1 tier=admin] TASK-1: what happened?" >/dev/null; rc=$?
chk "H3: a human's message about the same row is never dropped" "1" "$rc"
chk "H4: _hb_ident on a vanished row names the board's prefix" "TASK-999" "$(_hb_ident 999)"
chk "H5: _hb_ident on a live row reads its ident" "TASK-2" \
  "$(_hb_ident "$(db "SELECT id FROM tasks WHERE ident='TASK-2';")")"

# --- S: supervisor goal drift on a TASK- goal --------------------------------
GH="$TMP/goalhome"; TX="$GH/.claude/projects/p"; mkdir -p "$TX"
NOW_R=$(date +%s); OLD_TS=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S.000Z)
printf '{"type":"user","timestamp":"%s","message":{"content":"A session-scoped Stop hook is now active with condition: \\"Task TASK-2 shows status done. run 5dive task start TASK-2\\""}}\n' \
  "$OLD_TS" > "$TX/s.jsonl"
chk "S1: goal drift resolves TASK-2 to its row id" \
  "$(db "SELECT id FROM tasks WHERE ident='TASK-2';")" \
  "$(_sup_goal_drift claude "$GH" gdrift "$NOW_R" "$NOW_R")"

# --- R: the numbered follow-up advisory parses a TASK- ident -----------------
_task_numbered_followup_parse "TASK-2 fix #3: the second half"
chk "R1: 'TASK-2 fix #3' parses as a follow-up of TASK-2" "TASK-2|fix|3" \
  "${_TASK_FOLLOWUP_IDENT}|${_TASK_FOLLOWUP_KIND}|${_TASK_FOLLOWUP_NUMBER}"

# --- M: mutant — the pre-fix DIVE-only pattern -------------------------------
# The parser this row replaced. If H1 passes only because the payload happened to
# satisfy any pattern, this arm says so.
mut=$( task_ident_ere() { printf 'DIVE-[0-9]+'; }; _a2a_nudge_ident "$NUDGE" ); mrc=$?
[[ $mrc -ne 0 && -z "$mut" ]] \
  && ok_t "M1: mutant — a DIVE-only pattern finds no ident in a TASK nudge (H1 can go red)" \
  || bad_t "M1: mutant took" "rc=$mrc got '$mut'"

printf -- '-----\ntask_prefix_default_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
