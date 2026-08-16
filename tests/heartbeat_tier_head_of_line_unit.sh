#!/usr/bin/env bash
# DIVE-2716 — a tier HOLD is a verdict on a TASK; it used to be spent as a
# verdict on the AGENT.
#
# THE DEFECT. The wake loop picked ONE row (_hb_pick_task, LIMIT 1), and when
# DIVE-1065's tier guard held that row it ran `continue` — on the agent's
# iteration, not on the row. Selection is deterministic, so the next tick picked
# the SAME row, held it again, and skipped the agent again. Measured on the live
# board 2026-08-04: five held rows head-of-line blocking 122 runnable ones, the
# fleet idle 2h35m, main's queue stuck since 2026-07-30.
#
# WHY THE OLD REASONING PASSED REVIEW. The guard's own comment said "a hold skips
# ONE agent's wake this tick and never aborts the tick" — true, per tick, and it
# bounds the wrong axis. Per-event isolation says nothing about an event that
# repeats with identical input. This harness therefore grades ACROSS the repeat:
# every arm runs the REAL cmd_heartbeat_tick, and the anchor runs the pre-fix
# tick on the SAME fixture so "permanent" is measured rather than argued.
#
# WHAT IS ASSERTED
#   1  a held head is STEPPED OVER: the tick wakes the agent on the first
#      candidate the guard clears, and says so in the log;
#   2  the guard is not weakened — a held row is never the wake target, stays
#      todo, and is still named in the log (it is a hold, not a silent drop);
#   3  a queue whose every candidate is held still yields NO wake (the escalation
#      the guard exists to prevent does not become reachable by scanning);
#   4  ordering is untouched: with nothing held, the tick wakes on exactly the row
#      _hb_pick_task returns, so DIVE-979's priority/critical-path rules are
#      unchanged;
#   5  the scan is BOUNDED and says so: with the cap set below the number of held
#      rows, the tick logs that rows past the cap were not examined rather than
#      reporting an idle agent;
#   6  ANCHOR: the same fixture driven against the PRE-FIX cmd_heartbeat.sh from a
#      PINNED COMMIT (not a branch, not a reimplementation here) wakes NOBODY —
#      and is graded for vacuity: the pre-fix run must still log the hold, or the
#      red would be attributable to a dead harness rather than to the defect.
#
# Pure: scratch sqlite + a fixture registry in a tmpdir. No root, no network, no
# tmux, no live board.
#   bash tests/heartbeat_tier_head_of_line_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
. "$(dirname "${BASH_SOURCE[0]}")/lib/pinned_baseline.sh" \
  || printf 'pinned baseline helper: UNRESOLVED (tests/lib/pinned_baseline.sh not reachable)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

PASS=0; FAIL=0; SKIP=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; return 0; }
skip_t() { SKIP=$((SKIP+1)); printf 'SKIP - %s\n' "$1"; }
eq_t()   { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected '$2', got '$3'"; fi; }

TMP="$(mktemp -d /tmp/hb-tier-hol-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_heartbeat.sh; do
  # cmd_heartbeat.sh is sourced HERE too (each arm re-sources its own copy in a
  # subshell) so arm 4 can call the shipped _hb_pick_task directly: the "same row
  # as before" claim has to be measured against the real picker, not a retyped
  # query.
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
REGISTRY="$TMP/registry.json"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; the asserts below probe states deliberately

tasks_db_init

# The fleet as it actually was: an ADMIN assignee, a STANDARD creator whose rows
# the guard must refuse to auto-drive, and a human/external filer (unregistered
# => MEASURED, rank 0) whose rows are the ones that must still flow.
cat > "$REGISTRY" <<'JSON'
{"agents":{
  "dev":   {"isolation":"admin",     "heartbeat":{"enabled":true,"everyMin":30,"lastRunAt":0}},
  "main2": {"isolation":"sandboxed",  "heartbeat":{"enabled":false}},
  "ghost": {"heartbeat":{"enabled":false}}
}}
JSON

mk() {  # mk <title> <priority> <created_by> [assignee] -> row id
  db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, status)
      VALUES ($(sqlq "$1"), '', $(sqlq "$2"), $(sqlq "${4:-dev}"), $(sqlq "$3"), 'standard', 'todo');
      SELECT last_insert_rowid();"
}
status_of() { db "SELECT status FROM tasks WHERE id=$1;"; }
reset_board() { db "DELETE FROM tasks;"; }

# --- The run harness ---------------------------------------------------------
# Each arm drives the REAL cmd_heartbeat_tick in a SUBSHELL, sourcing the
# cmd_heartbeat.sh under test (working tree, or a pinned pre-fix blob) and then
# re-applying the boundary stubs on top of it. Stubs must be defined AFTER the
# source or the real definitions win — that ordering is the whole reason the
# arm runs in a subshell instead of re-sourcing in place.
#
# Observable: the WAKE TARGET (which task id the tick nudged, or NONE) plus the
# tick's log. The wake target is read from the stub's own record, never inferred
# from a log line.
run_tick() {  # run_tick <path-to-cmd_heartbeat.sh> <logfile> [scan-cap-override] -> echoes woken task id or NONE
  local hb="$1" logf="$2" cap="${3:-}"
  (
    # shellcheck source=/dev/null
    source "$hb"
    [[ -n "$cap" ]] && _HB_PICK_SCAN="$cap"
    require_root()          { :; }
    registry_read()         { cat "$REGISTRY"; }
    registry_write()        { cat > /dev/null; }
    with_registry_lock()    { local fn="$1"; shift; "$fn" "$@"; }
    _hb_log()               { printf '%s\n' "$1" >> "$logf"; }
    _hb_send_line()         { return 0; }
    _hb_agent_idle()        { return 0; }
    _hb_claude_started()    { echo ""; }
    _hb_pane_fingerprint()  { echo "fp"; }
    _hb_mark_active_defer() { echo 0; }
    _hb_clear_active_defer(){ :; }
    _hb_wake_budget_ok()    { return 0; }
    _hb_wake_budget_inc()   { :; }
    _hb_usage_limit_frozen(){ return 1; }
    _hb_mark_run()          { :; }
    cmd_send()              { :; }
    cmd_task_escalate()     { :; }
    _HB_SLEPT=0; _HB_SLEEP_ARMED=0
    for _sweep in _hb_materialize_recurring _hb_gate_renag_sweep _hb_gate_ttl_sweep \
                  _hb_autosleep_sweep _hb_capability_reverify_sweep _hb_blocked_sweep \
                  _hb_gate_shipped_sweep _hb_council_rot_sweep _hb_stall_sweep \
                  _hb_loop_ceiling_sweep _hb_budget_sweep _hb_poller_liveness_sweep \
                  _hb_objective_reconcile _hb_reclaim; do
      eval "${_sweep}() { :; }"
    done
    # _hb_reclaim is neutered above but the caller reads two numbers from it.
    _hb_reclaim() { echo "0 0"; }
    # THE observable. Records the id the tick chose, then reports success so the
    # claim path downstream runs exactly as it does in production.
    _hb_wake() { printf '%s' "$3" > "$TMP/woke"; return 0; }
    : > "$TMP/woke"
    # stdout is KEPT (it used to go to /dev/null): under JSON_MODE the tick's
    # closing ok() is the operator-facing tick summary, and arm 9 grades the
    # tierHeld counter inside it. Discarding it is what made the counter
    # unmeasured in the first place.
    cmd_heartbeat_tick >"$TMP/summary.json" 2>/dev/null
  )
  local w; w=$(cat "$TMP/woke" 2>/dev/null)
  printf '%s' "${w:-NONE}"
}

# The tick summary's hold counter, or MISSING if the tick never reported one.
# MISSING and 0 are DIFFERENT answers and the arms below distinguish them: a
# counter that was never emitted is the silent-skip regression, a counter that
# is emitted as 0 is a real (and gradeable) claim about the tick.
tier_held_count() {
  local v
  v=$(jq -r 'select(.data.skipped != null) | .data.skipped.tierHeld // "MISSING"' \
        "$TMP/summary.json" 2>/dev/null | tail -1)
  printf '%s' "${v:-MISSING}"
}
# How many of the seeded rows the tick actually got a claim onto.
n_claimed() { db "SELECT COUNT(*) FROM tasks WHERE status='in_progress';"; }

HB_NEW="$SRC/cmd_heartbeat.sh"

# ---------------------------------------------------------------------------
# 1 + 2. A held head is stepped over; the held rows stay held.
# ---------------------------------------------------------------------------
reset_board
T_HELD_U=$(mk "held urgent, sandboxed creator" urgent main2)     # guard: HOLD
T_HELD_H=$(mk "held high, sandboxed creator"   high   main2)     # guard: HOLD
T_RUN=$(mk    "runnable high, human creator"  high   lodar)     # guard: clears
T_LOW=$(mk    "runnable medium, self"         medium dev)

LOG1="$TMP/tick1.log"; : > "$LOG1"
got=$(run_tick "$HB_NEW" "$LOG1")
eq_t "held head is stepped over — tick wakes on the first CLEARED candidate" "$T_RUN" "$got"
eq_t "held urgent row stays todo (not auto-run)"  "todo" "$(status_of "$T_HELD_U")"
eq_t "held high row stays todo (not auto-run)"    "todo" "$(status_of "$T_HELD_H")"
eq_t "the woken row was CLAIMED by the dispatcher" "in_progress" "$(status_of "$T_RUN")"

if grep -q "main2(sandboxed) < assignee(admin)" "$LOG1"; then
  ok_t "each hold still NAMES itself in the log (a hold, not a silent drop)"
else
  bad_t "the hold was not logged" "$(cat "$LOG1")"
fi
n_holds=$(grep -c "main2(sandboxed) < assignee(admin)" "$LOG1")
eq_t "both held rows were considered and held (not just the head)" "2" "$n_holds"
if grep -q "tier guard held 2 higher-priority todo(s); waking on" "$LOG1"; then
  ok_t "the tick summarises WHAT it stepped over and what it woke instead"
else
  bad_t "no step-over summary line" "$(cat "$LOG1")"
fi

# ---------------------------------------------------------------------------
# 3. Every candidate held => still NO wake. Scanning must not become a bypass.
# ---------------------------------------------------------------------------
reset_board
A=$(mk "all held A" urgent main2); B=$(mk "all held B" high main2); C=$(mk "all held C" low main2)
LOG2="$TMP/tick2.log"; : > "$LOG2"
got=$(run_tick "$HB_NEW" "$LOG2")
eq_t "a fully-held queue wakes NOBODY (guard is not weakened)" "NONE" "$got"
eq_t "held row A untouched" "todo" "$(status_of "$A")"
eq_t "held row C untouched" "todo" "$(status_of "$C")"
if grep -q "tier guard held all 3 runnable todo(s)" "$LOG2"; then
  ok_t "a fully-held queue is REPORTED as held, not as 'no todo'"
else
  bad_t "fully-held queue did not report itself" "$(cat "$LOG2")"
fi
if grep -q "no todo — stay idle" "$LOG2"; then
  bad_t "a fully-held queue was mislabelled 'no todo' — the held rows are invisible"
else
  ok_t "held is distinguishable from empty in the log"
fi

# ---------------------------------------------------------------------------
# 4. Nothing held => the pick is byte-for-byte the old pick. DIVE-979 untouched.
# ---------------------------------------------------------------------------
reset_board
mk "human urgent"  urgent lodar >/dev/null
mk "human high"    high   lodar >/dev/null
mk "self medium"   medium dev   >/dev/null
LOG3="$TMP/tick3.log"; : > "$LOG3"
want=$(_hb_pick_task dev 2>/dev/null)
if [[ -z "$want" ]]; then
  # _hb_pick_task is only in scope here if the working tree defines it; if the
  # wrapper were dropped this must not pass by defaulting to empty.
  bad_t "precondition: _hb_pick_task returned nothing on an unheld board"
else
  got=$(run_tick "$HB_NEW" "$LOG3")
  eq_t "with nothing held, the tick wakes on exactly _hb_pick_task's row" "$want" "$got"
fi
if grep -q "tier guard held" "$LOG3"; then
  bad_t "an unheld board logged a hold" "$(cat "$LOG3")"
else
  ok_t "an unheld board scans exactly one candidate (no hold noise)"
fi

# ---------------------------------------------------------------------------
# 5. The scan is BOUNDED, and hitting the bound is loud.
# ---------------------------------------------------------------------------
reset_board
mk "cap held 1" urgent main2 >/dev/null
mk "cap held 2" urgent main2 >/dev/null
mk "cap held 3" urgent main2 >/dev/null
T_PAST=$(mk "runnable past the cap" high lodar)
LOG4="$TMP/tick4.log"; : > "$LOG4"
got=$(run_tick "$HB_NEW" "$LOG4" 2)     # cap BELOW the number of held rows
eq_t "scan stops at the cap rather than walking the whole queue" "NONE" "$got"
eq_t "the row past the cap is left todo (it was never examined)" "todo" "$(status_of "$T_PAST")"
if grep -q "scan cap _HB_PICK_SCAN=2 reached" "$LOG4"; then
  ok_t "hitting the cap is LOGGED — an unexamined tail is never reported as idle"
else
  bad_t "the cap truncated the scan silently" "$(cat "$LOG4")"
fi

# ---------------------------------------------------------------------------
# 7. REACHABILITY, stated WITHOUT reference to the guard's verdict.
# ---------------------------------------------------------------------------
# Every other reachability arm above asserts the tick wakes on one SPECIFIC row,
# so neutering the guard reds it too (the tick then wakes the held row instead)
# and the arm cannot tell a broken guard apart from a broken scheduler. This arm
# asserts ONLY that a queue containing runnable work does not leave the agent
# idle. That is true whatever the guard decides, so it survives a neutered guard
# and reds exactly when the scheduler stops stepping over a held head — the
# scheduler-side half of the disjoint pair whose other half is arm 3.
reset_board
mk "held head" urgent main2 >/dev/null
for i in 1 2 3 4 5; do mk "runnable behind $i" high lodar >/dev/null; done
LOG7="$TMP/tick7.log"; : > "$LOG7"
got=$(run_tick "$HB_NEW" "$LOG7")
if [[ "$got" != "NONE" ]]; then
  ok_t "a queue holding runnable work never leaves the agent idle (reachability, guard-independent)"
else
  bad_t "agent left idle with 5 runnable rows behind a held head — head-of-line block is back" \
        "$(cat "$LOG7")"
fi

# ---------------------------------------------------------------------------
# 9. OBSERVABILITY: the hold is COUNTED in the tick summary, not just logged.
# ---------------------------------------------------------------------------
# DIVE-2459 sat held from 2026-07-30 and went unnoticed for FIVE DAYS; it was
# only ever found because it eventually blocked everything. Stepping over a held
# head removes that blocking symptom, so if the hold is not visible in the tick's
# own summary this fix makes the NEXT occurrence strictly harder to find than
# this one was. The log line alone is not enough — nobody greps a heartbeat log
# for a condition they do not know to look for; the counter is what a digest or
# an alert can watch. MISSING is graded apart from 0 on purpose.
held_n=$(tier_held_count)
if [[ "$held_n" == "MISSING" ]]; then
  bad_t "the tick summary does not report holds at all — a held row is invisible to any watcher" \
        "$(cat "$TMP/summary.json" 2>/dev/null)"
elif (( held_n >= 1 )); then
  ok_t "the tick summary COUNTS the stepped-over hold (tierHeld=${held_n})"
else
  bad_t "tierHeld reported 0 while a row was demonstrably held" "summary said ${held_n}"
fi
# An unheld board must report 0 — a counter that is always non-zero is no more
# informative than one that is always absent.
reset_board
mk "human high" high lodar >/dev/null
LOG8="$TMP/tick8.log"; : > "$LOG8"
run_tick "$HB_NEW" "$LOG8" >/dev/null
eq_t "an unheld board reports tierHeld=0 (the counter tracks reality, not a constant)" \
     "0" "$(tier_held_count)"

# ---------------------------------------------------------------------------
# 6. ANCHOR — the pre-fix tick, same fixture, from a PINNED COMMIT.
# ---------------------------------------------------------------------------
# A BRANCH name would rot the instant this merges (origin/main becomes the
# post-fix tree and the anchor compares post to post — the exact self-
# invalidation DIVE-2229 found in the sibling harness). c59c1e7 is main
# immediately before this change.
PRE_FIX_REF="c59c1e7812191bcbc23a704bb07d541b2c0a30bd"
OLD_HB="$TMP/old_cmd_heartbeat.sh"
if pinned_blob "$PRE_FIX_REF" src/cmd_heartbeat.sh "$OLD_HB"; then
  reset_board
  O_HELD=$(mk "held urgent, sandboxed creator" urgent main2)
  O_RUN=$(mk  "runnable high, human creator"  high   lodar)
  LOG5="$TMP/tick5.log"; : > "$LOG5"
  old_got=$(run_tick "$OLD_HB" "$LOG5")
  eq_t "ANCHOR: pre-fix tick wakes NOBODY — the runnable row is unreachable" "NONE" "$old_got"
  eq_t "ANCHOR: pre-fix leaves the runnable row in todo" "todo" "$(status_of "$O_RUN")"
  # VACUITY GRADE. "No wake" is also what a dead harness produces. The pre-fix
  # run must have reached the guard and held THIS row, or the red above is not
  # attributable to the defect.
  if grep -q "main2(sandboxed) < assignee(admin)" "$LOG5"; then
    ok_t "ANCHOR is non-vacuous: the pre-fix tick reached the guard and held the head"
  else
    bad_t "ANCHOR is VACUOUS: pre-fix tick never logged a hold" \
          "no wake proves nothing if the tick never reached the guard — log was: $(cat "$LOG5")"
  fi
  # DIFFERENTIAL: same board, same harness, new code — the row the pre-fix tick
  # could not reach IS reached.
  reset_board
  N_HELD=$(mk "held urgent, sandboxed creator" urgent main2)
  N_RUN=$(mk  "runnable high, human creator"  high   lodar)
  LOG6="$TMP/tick6.log"; : > "$LOG6"
  new_got=$(run_tick "$HB_NEW" "$LOG6")
  eq_t "DIFFERENTIAL: the identical board wakes on the runnable row post-fix" "$N_RUN" "$new_got"
  if [[ "$old_got" != "$new_got" ]]; then
    ok_t "the fix is what moved the outcome (pre='${old_got}' post='${new_got}')"
  else
    bad_t "pre-fix and post-fix ticks agree — this harness cannot see the change"
  fi

  # --- The incident's SHAPE, not just one row (N behind one head) ------------
  # The live board cannot be used as the anchor here and must not be: the four
  # blocking heads were PARKED at 19:38 to drain the fleet, so a pre-fix probe
  # that read live rows would find nothing held and pass for the wrong reason —
  # parked, not stepped over. This fixture is self-seeded in a scratch sqlite db
  # under $TMP and reads no live state, so the park cannot reach it. N=5 stands
  # in for the measured 83-behind-one-head; the assertion is that ZERO of them
  # are reached pre-fix, which is the stall itself rather than a proxy for it.
  reset_board
  mk "held head, sandboxed creator" urgent main2 >/dev/null
  for i in 1 2 3 4 5; do mk "runnable behind $i" high lodar >/dev/null; done
  LOG9="$TMP/tick9.log"; : > "$LOG9"
  old_n=$(run_tick "$OLD_HB" "$LOG9")
  eq_t "ANCHOR/N: pre-fix reaches ZERO of the 5 runnable rows behind the held head" \
       "0" "$(n_claimed)"
  eq_t "ANCHOR/N: pre-fix wake target is NONE with 5 rows runnable" "NONE" "$old_n"
  if grep -q "main2(sandboxed) < assignee(admin)" "$LOG9"; then
    ok_t "ANCHOR/N is non-vacuous: the pre-fix tick reached the guard and held the head"
  else
    bad_t "ANCHOR/N is VACUOUS: pre-fix tick never logged a hold" "$(cat "$LOG9")"
  fi
  # Same board, same harness, post-fix: the queue behind the head is reachable.
  reset_board
  mk "held head, sandboxed creator" urgent main2 >/dev/null
  for i in 1 2 3 4 5; do mk "runnable behind $i" high lodar >/dev/null; done
  LOG10="$TMP/tick10.log"; : > "$LOG10"
  new_n=$(run_tick "$HB_NEW" "$LOG10")
  eq_t "ANCHOR/N: post-fix reaches one of the rows the pre-fix tick could not" "1" "$(n_claimed)"
  eq_t "ANCHOR/N: the held head is still NOT the wake target" "todo" \
       "$(db "SELECT status FROM tasks WHERE created_by='main2';")"
else
  bad_t "ANCHOR: pre-fix stall NOT re-measured" "$(pinned_unavailable_msg "$PRE_FIX_REF")"
fi

# ---------------------------------------------------------------------------
# Structural: the head-of-line shape must not come back.
# ---------------------------------------------------------------------------
if grep -qE '^\s*task_id=\$\(_hb_pick_task "\$name"\)' "$HB_NEW"; then
  bad_t "the wake loop went back to a single LIMIT-1 pick — a held head blocks the agent again"
else
  ok_t "the wake loop no longer commits to a single pick"
fi
if grep -q '_hb_pick_tasks "\$name" "\$_HB_PICK_SCAN"' "$HB_NEW"; then
  ok_t "the wake loop iterates a bounded candidate list"
else
  bad_t "the wake loop does not call _hb_pick_tasks with the scan cap"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
