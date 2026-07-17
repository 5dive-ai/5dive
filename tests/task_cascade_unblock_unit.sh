#!/usr/bin/env bash
# DIVE-1355 isolated unit harness for the task-engine self-dispatch fix:
#   * _task_cascade_unblock — on `task done`/`task cancel`, drop the satisfied
#     blocking edge and flip a dependent with no edges left blocked->todo, UNLESS
#     it has a live non-dependency hold (unanswered human need-gate, or a park).
#   * _hb_blocked_sweep — (a) auto-recover a task still 'blocked' whose every
#     edge points to a done/cancelled blocker (repairs pre-existing rot), and
#     (b) SURFACE (never auto-unblock) a task blocked with no live reason.
# Same isolation contract as the other harnesses: source src/ directly, throwaway
# tasks.db (STATE_DIR -> tmp), cmd_send stubbed so no tmux/network is touched.
# Run: bash tests/task_cascade_unblock_unit.sh   (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/task-cascade-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

# --- stubs: record pings, never touch tmux/network ---------------------------
SEND_LOG="$TMP/sent"; : >"$SEND_LOG"
cmd_send() {  # $1 = target agent; last arg carries --message=…
  local tgt="$1" msg=""; shift
  for a in "$@"; do case "$a" in --message=*) msg="${a#--message=}";; esac; done
  printf '%s\t%s\n' "$tgt" "$msg" >>"$SEND_LOG"
}
audit_log() { return 0; }

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
jf()    { jq -r "$1" 2>/dev/null; }

addt()  { ( cmd_task_add "$@" ) 2>/dev/null | jf '.data.id'; }
st()    { db "SELECT status FROM tasks WHERE id=$1;"; }
edges() { db "SELECT COUNT(*) FROM task_deps WHERE task_id=$1;"; }

# =============================================================================
# Live cascade (_task_cascade_unblock via cmd_task_done / cmd_task_cancel)
# =============================================================================

# --- T1: done a single blocker flips its dependent blocked->todo, edge dropped
a=$(addt --assignee=alice -- "blocker A"); b=$(addt --assignee=bob -- "dependent B")
( cmd_task_block "$b" --by="$a" ) >/dev/null 2>&1
[[ "$(st "$b")" == "blocked" && "$(edges "$b")" == "1" ]] || bad_t "T1 setup" "B not blocked"
( cmd_task_done "$a" ) >/dev/null 2>&1
[[ "$(st "$b")" == "todo" && "$(edges "$b")" == "0" ]] \
  && ok_t "done blocker -> dependent flips todo, edge dropped" \
  || bad_t "single cascade" "B status=$(st "$b") edges=$(edges "$b")"

# --- T1b: the freed dependent's assignee got pinged
grep -q $'^bob\t' "$SEND_LOG" \
  && ok_t "freed dependent's assignee pinged" || bad_t "ping" "no bob ping in $SEND_LOG"

# --- T2: two blockers — dependent stays blocked until BOTH clear
a1=$(addt -- "A1"); a2=$(addt -- "A2"); d=$(addt --assignee=dora -- "D two-blockers")
( cmd_task_block "$d" --by="$a1" ) >/dev/null 2>&1
( cmd_task_block "$d" --by="$a2" ) >/dev/null 2>&1
( cmd_task_done "$a1" ) >/dev/null 2>&1
half="$(st "$d")/$(edges "$d")"
( cmd_task_done "$a2" ) >/dev/null 2>&1
full="$(st "$d")/$(edges "$d")"
[[ "$half" == "blocked/1" && "$full" == "todo/0" ]] \
  && ok_t "two blockers: stays blocked after 1, flips after both ($half -> $full)" \
  || bad_t "multi-blocker cascade" "got $half -> $full"

# --- T3: CANCELLING a blocker cascades just like done
a=$(addt -- "A cancel"); b=$(addt --assignee=bob -- "B via cancel")
( cmd_task_block "$b" --by="$a" ) >/dev/null 2>&1
( cmd_task_cancel "$a" ) >/dev/null 2>&1
[[ "$(st "$b")" == "todo" && "$(edges "$b")" == "0" ]] \
  && ok_t "cancelled blocker also cascades" || bad_t "cancel cascade" "B status=$(st "$b")"

# --- T4 GUARDRAIL: an unanswered human need-gate is NOT auto-unblocked
a=$(addt -- "A gate"); b=$(addt --assignee=bob -- "B gated")
( cmd_task_block "$b" --by="$a" ) >/dev/null 2>&1
( cmd_task_need "$b" --type=decision --options="X|Y" --ask="pick one" ) >/dev/null 2>&1
( cmd_task_done "$a" ) >/dev/null 2>&1
[[ "$(st "$b")" == "blocked" && "$(edges "$b")" == "0" ]] \
  && ok_t "need-gated dependent stays blocked (edge dropped, not flipped)" \
  || bad_t "gate guardrail" "B status=$(st "$b") edges=$(edges "$b")"

# --- T5 GUARDRAIL: a parked dependent is NOT auto-unblocked
a=$(addt -- "A park"); b=$(addt --assignee=bob -- "B parked")
( cmd_task_block "$b" --by="$a" ) >/dev/null 2>&1
db "UPDATE tasks SET parked_at=datetime('now'), park_reason='holding' WHERE id=$b;"
( cmd_task_done "$a" ) >/dev/null 2>&1
[[ "$(st "$b")" == "blocked" ]] \
  && ok_t "parked dependent stays blocked (park owns the hold)" \
  || bad_t "park guardrail" "B status=$(st "$b")"

# =============================================================================
# Safety sweep (_hb_blocked_sweep)
# =============================================================================

# --- T6 (a) AUTO-RECOVER pre-existing rot: blocked with an edge to an
#     already-done blocker where the live cascade never fired (raw done).
a=$(addt -- "A pre-done"); b=$(addt --assignee=eve -- "B rotted")
( cmd_task_block "$b" --by="$a" ) >/dev/null 2>&1
db "UPDATE tasks SET status='done', done_at=datetime('now') WHERE id=$a;"  # bypass cascade
[[ "$(st "$b")" == "blocked" && "$(edges "$b")" == "1" ]] || bad_t "T6 setup" "B not rotted"
: >"$SEND_LOG"
_hb_blocked_sweep
[[ "$(st "$b")" == "todo" && "$(edges "$b")" == "0" ]] \
  && ok_t "sweep auto-recovers blocked-whose-blockers-all-done -> todo" \
  || bad_t "sweep recover" "B status=$(st "$b") edges=$(edges "$b")"
grep -q $'^main\t' "$SEND_LOG" \
  && ok_t "sweep recovery pings main" || bad_t "recover ping" "no main ping"

# --- T7 (b) SURFACE (never auto-unblock): blocked, no edge, no gate, no park
o=$(addt --assignee=frank -- "orphan blocked")
db "UPDATE tasks SET status='blocked' WHERE id=$o;"
: >"$SEND_LOG"
db "DELETE FROM task_prefs WHERE key='blocked_sweep_pinged_at';"
_hb_blocked_sweep
pinged="$(cut -f2 "$SEND_LOG" | grep -c 'no live reason')"
[[ "$(st "$o")" == "blocked" && "$pinged" -ge 1 ]] \
  && ok_t "no-reason blocked is SURFACED, not auto-unblocked" \
  || bad_t "surface" "O status=$(st "$o") pinged=$pinged"
[[ -n "$(db "SELECT value FROM task_prefs WHERE key='blocked_sweep_pinged_at';")" ]] \
  && ok_t "surface stamps the throttle key" || bad_t "throttle stamp" "no key"

# --- T7b: throttle — a second sweep within 24h does NOT re-ping
: >"$SEND_LOG"
_hb_blocked_sweep
[[ "$(cut -f2 "$SEND_LOG" | grep -c 'no live reason')" == "0" ]] \
  && ok_t "surface throttled to once/24h (no re-ping)" || bad_t "throttle" "re-pinged"

# --- T8 GUARDRAIL: a parked no-edge task is neither recovered nor surfaced
p=$(addt --assignee=greg -- "parked orphan")
db "UPDATE tasks SET status='blocked', parked_at=datetime('now') WHERE id=$p;"
db "DELETE FROM task_prefs WHERE key='blocked_sweep_pinged_at';"
: >"$SEND_LOG"
_hb_blocked_sweep
# it must stay blocked, and must not appear in a 'no live reason' surface line
if [[ "$(st "$p")" == "blocked" ]] && ! cut -f2 "$SEND_LOG" | grep -q "$(db "SELECT ident FROM tasks WHERE id=$p;")"; then
  ok_t "parked no-edge task left untouched (not recovered, not surfaced)"
else
  bad_t "park sweep guardrail" "P status=$(st "$p")"
fi

echo "-----"
echo "task_cascade_unblock_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
