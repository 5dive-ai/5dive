#!/usr/bin/env bash
# DIVE-1357 isolated unit harness for the block-anchor enforcement (fast-follow
# to DIVE-1355): a task can only enter 'blocked' via one of three anchors, each
# carrying a built-in revisit — a dependency edge, a human need-gate, or a park
# with a wake. A bare reasonless/dateless block is refused, so the DIVE-1355
# 'blocked with no live reason' surface set is permanently empty.
# Asserts: bare block rejected; block --by / need / park each still block AND
# satisfy _task_has_block_anchor; park requires --reason AND --wake; block with
# --reason+--wake (no --by) routes through park.
# Run: bash tests/task_block_anchor_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/task-block-anchor.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
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
addt()  { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
st()    { db "SELECT status FROM tasks WHERE id=$1;"; }
runq()  { ( "$@" ) >/dev/null 2>"$TMP/err"; }   # quiet; capture rc + stderr

# --- T1: a BARE `task block <id>` (no --by, no reason/wake) is REFUSED ---------
t=$(addt --assignee=alice -- "would-be bare block")
runq cmd_task_block "$t"; rc=$?
[[ $rc -ne 0 && "$(st "$t")" == "todo" ]] \
  && ok_t "bare 'task block' (no anchor) is refused, task stays todo" \
  || bad_t "bare block refused" "rc=$rc status=$(st "$t")"
grep -qiE 'forbidden|anchor|--by|park' "$TMP/err" \
  && ok_t "bare-block error points to the 3 anchored options" || bad_t "error guidance" "$(cat "$TMP/err")"

# --- T2: `task block --by` still works (dependency edge anchor) ----------------
a=$(addt -- "A blocker"); b=$(addt --assignee=bob -- "B dep")
runq cmd_task_block "$b" --by="$a"
{ [[ "$(st "$b")" == "blocked" ]] && _task_has_block_anchor "$b"; } \
  && ok_t "block --by blocks + satisfies the edge anchor" \
  || bad_t "block --by" "status=$(st "$b")"

# --- T3: park REQUIRES --reason ------------------------------------------------
p=$(addt -- "P noreason")
runq cmd_task_park "$p" --wake=+7d; rc=$?
[[ $rc -ne 0 && "$(st "$p")" == "todo" ]] \
  && ok_t "park without --reason is refused" || bad_t "park needs reason" "rc=$rc status=$(st "$p")"

# --- T4: park REQUIRES --wake -------------------------------------------------
p=$(addt -- "P nowake")
runq cmd_task_park "$p" --reason="waiting on upstream"; rc=$?
[[ $rc -ne 0 && "$(st "$p")" == "todo" ]] \
  && ok_t "park without --wake is refused (no revisit date)" || bad_t "park needs wake" "rc=$rc status=$(st "$p")"

# --- T5: park with BOTH reason + wake works and anchors -----------------------
p=$(addt -- "P good")
runq cmd_task_park "$p" --reason="upstream ships next week" --wake=+7d
{ [[ "$(st "$p")" == "blocked" ]] && _task_has_block_anchor "$p" \
    && [[ -n "$(db "SELECT wake_at FROM tasks WHERE id=$p;")" ]] \
    && [[ -n "$(db "SELECT park_reason FROM tasks WHERE id=$p;")" ]]; } \
  && ok_t "park --reason --wake blocks + satisfies the park anchor (wake+reason set)" \
  || bad_t "park good" "status=$(st "$p")"

# --- T6: `task block --reason --wake` (no --by) ROUTES THROUGH park -----------
r=$(addt -- "R routed")
runq cmd_task_block "$r" --reason="held for launch window" --wake=+3d
{ [[ "$(st "$r")" == "blocked" ]] && [[ -n "$(db "SELECT parked_at FROM tasks WHERE id=$r;")" ]] \
    && [[ -n "$(db "SELECT wake_at FROM tasks WHERE id=$r;")" ]]; } \
  && ok_t "block --reason --wake (no --by) routes through park" \
  || bad_t "block->park route" "status=$(st "$r") parked=$(db "SELECT parked_at FROM tasks WHERE id=$r;")"

# --- T7: a human need-gate anchors a block -----------------------------------
n=$(addt --assignee=nate -- "N gated")
runq cmd_task_need "$n" --type=decision --options="X|Y" --ask="pick"
{ [[ "$(st "$n")" == "blocked" ]] && _task_has_block_anchor "$n"; } \
  && ok_t "task need blocks + satisfies the gate anchor" || bad_t "need anchor" "status=$(st "$n")"

# --- T8: the predicate correctly REJECTS an anchorless blocked row -----------
# (simulate a raw/legacy bare block: status=blocked, no edge/gate/park.)
x=$(addt -- "X raw bare")
db "UPDATE tasks SET status='blocked' WHERE id=$x;"
_task_has_block_anchor "$x" \
  && bad_t "predicate rejects anchorless" "returned anchor=true for a bare block" \
  || ok_t "_task_has_block_anchor is FALSE for an anchorless blocked row (the graveyard state)"

echo "-----"
echo "task_block_anchor_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
