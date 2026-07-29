#!/usr/bin/env bash
# DIVE-2244 — the DISPATCHER CLAIMS. Isolated unit harness for the claim that
# the heartbeat tick stamps at the moment it nudges an agent.
#
# WHY THIS HARNESS EXISTS, and why it drives the REAL tick loop rather than the
# helper alone. The defect was not that `_hb_claim_task` was wrong — it did not
# exist. Nothing wrote tasks.status='in_progress' / started_at, so the busy
# guard, the runaway reaper, orphan reclaim, unwedge and the fleet-stall
# predicate all read a field that never moved (measured: 0 of 24 tasks closed in
# a day had started_at ever set). A harness that only exercised the helper would
# prove the helper works while the tick never calls it — exactly the shape of
# bug being fixed. So the real `cmd_heartbeat_tick` runs here, with only its
# BOUNDARIES stubbed (tmux, registry lock, sibling sweeps, the wake itself).
#
# Asserts, in order:
#   1  a tick that nudges an agent leaves that task in_progress with started_at
#      set — read back from the ROW, never from a log line;
#   2  two-sided: a tick that wakes NOBODY (not due) leaves every row byte-identical,
#      and a tick whose wake FAILS leaves its target row untouched;
#   3  the claim is narrow — refuses a row that is not todo, and refuses a
#      recurring TEMPLATE (starting one silently retires it, DIVE-2055/2059);
#   4  idempotence: an agent that later runs `task start` does not re-clock
#      started_at (COALESCE parity with cmd_task_start);
#   5  end-to-end reaper: a task that reached in_progress ONLY through the
#      dispatcher claim, aged past the budget, is requeued to todo by _hb_reclaim;
#   6  MUTATION ARM — with the claim neutered, (1) and (5) go RED. The red is
#      graded for vacuity: the tick must still have woken the agent, so the
#      failure is attributable to the missing claim and not to a dead harness;
#   7  restore — un-neutering the claim returns the arm to green, so the mutation
#      is proven to be what moved the result.
#
# Run: bash tests/heartbeat_dispatcher_claim_unit.sh  (no root, no network, no tmux).
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
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-dispatch-claim-unit.XXXXXX)"
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
REGISTRY="$TMP/registry.json"
HB_LOG="$TMP/heartbeat.log"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; asserts below deliberately probe states

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- Boundary stubs ----------------------------------------------------------
# Everything the tick touches OUTSIDE the unit under test. The wake loop, the
# claim, _hb_pick_task, _hb_mark_run and _hb_reclaim are all the REAL code.
require_root()          { :; }
registry_read()         { cat "$REGISTRY"; }
registry_write()        { cat > "$REGISTRY"; }
with_registry_lock()    { local fn="$1"; shift; "$fn" "$@"; }
_hb_log()               { printf '%s\n' "$1" >> "$HB_LOG"; }
_hb_send_line()         { return 0; }
_hb_agent_idle()        { return 0; }          # confident idle -> falls through to the wake
_hb_claude_started()    { echo ""; }           # no proc time -> orphan rule (a) can never fire
_hb_pane_fingerprint()  { echo "fp"; }
_hb_mark_active_defer() { echo 0; }
_hb_clear_active_defer(){ :; }
_hb_wake_budget_ok()    { return 0; }
_hb_wake_budget_inc()   { :; }
_hb_usage_limit_frozen(){ return 1; }
agent_tier()            { echo admin; }
tier_unmeasured()       { return 1; }
cmd_send()              { :; }
cmd_task_escalate()     { :; }
_HB_SLEPT=0; _HB_SLEEP_ARMED=0
# Sibling sweeps: each is independently isolated in production and none of them
# is under test here. Neutering them keeps this harness about the claim.
for _sweep in _hb_materialize_recurring _hb_gate_renag_sweep _hb_gate_ttl_sweep \
              _hb_autosleep_sweep _hb_capability_reverify_sweep _hb_blocked_sweep \
              _hb_gate_shipped_sweep _hb_council_rot_sweep _hb_stall_sweep \
              _hb_loop_ceiling_sweep _hb_budget_sweep _hb_poller_liveness_sweep \
              _hb_objective_reconcile; do
  eval "${_sweep}() { :; }"
done

# The wake itself: records that it ran, and its rc is steerable so we can drive
# the wake-FAILED branch. This is the seam the claim hangs off in production.
WAKE_RC=0; WAKE_CALLS=0
_hb_wake() { WAKE_CALLS=$((WAKE_CALLS + 1)); return "$WAKE_RC"; }

# --- Fixtures ----------------------------------------------------------------
mk() {  # mk <title> [status] [kind] [assignee]
  db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, status)
      VALUES ($(sqlq "$1"), '', 'high', $(sqlq "${4:-dev}"), 'dev', $(sqlq "${3:-standard}"), $(sqlq "${2:-todo}"));
      SELECT last_insert_rowid();"
}
row()      { db "SELECT status||'|'||COALESCE(started_at,'NULL') FROM tasks WHERE id=$1;"; }
started()  { db "SELECT COALESCE(started_at,'NULL') FROM tasks WHERE id=$1;"; }
snapshot() { db "SELECT id||'|'||status||'|'||COALESCE(started_at,'')||'|'||COALESCE(updated_at,'') FROM tasks ORDER BY id;"; }

# Registry: one enrolled agent, never woken (lastRunAt 0 => due).
seed_reg() { # seed_reg <lastRunAt>
  jq -n --argjson t "${1:-0}" \
    '{agents:{dev:{authProfile:"acct-dev",heartbeat:{enabled:true,everyMin:30,fresh:false,lastRunAt:$t}}}}' \
    > "$REGISTRY"
}

# --- 1) The claim lands, asserted from the ROW -------------------------------
T1=$(mk "dispatcher claims this")
seed_reg 0; WAKE_RC=0; WAKE_CALLS=0
cmd_heartbeat_tick >/dev/null 2>&1
[[ "$(row "$T1")" == in_progress\|* && "$(started "$T1")" != "NULL" ]] \
  && ok_t "tick that nudges leaves the ROW in_progress with started_at set" \
  || bad_t "tick that nudges leaves the ROW in_progress with started_at set" "got $(row "$T1")"
(( WAKE_CALLS == 1 )) && ok_t "the tick actually woke the agent (1 wake)" \
  || bad_t "the tick actually woke the agent (1 wake)" "WAKE_CALLS=$WAKE_CALLS"

# --- 4) Idempotent with the agent's own `task start` -------------------------
# Ordered here, while T1 is the freshly-claimed row: an agent that obeys the
# /goal text must be a no-op, not a re-clock, or every claimed task's age (and
# therefore the reaper budget) restarts the moment the agent complies.
CLAIM_TS=$(started "$T1")
db "UPDATE tasks SET started_at=datetime('now','-33 minutes') WHERE id=${T1};"
CLAIM_TS=$(started "$T1")
cmd_task_start "$T1" >/dev/null 2>&1
[[ "$(started "$T1")" == "$CLAIM_TS" ]] \
  && ok_t "a later 'task start' does NOT re-clock started_at (COALESCE parity)" \
  || bad_t "a later 'task start' does NOT re-clock started_at" "was $CLAIM_TS, now $(started "$T1")"

# --- 2) Two-sided: a tick that wakes nobody claims nothing -------------------
# The ticket phrased this as "a tick that wakes nobody must leave every row
# untouched". Written literally that is FALSE, and the first draft of this
# harness failed on it: _hb_reclaim runs on EVERY tick and is deliberately NOT
# gated by everyMin (an orphaned or runaway task must clear promptly or it
# blocks the agent's whole queue via the busy guard). So a not-due tick may
# still move an in_progress row BACK to todo. That is the recovery layer doing
# its job, and after DIVE-2244 it finally has input.
#
# The invariant that actually holds, and the one the fix must satisfy, is
# directional: a tick that wakes nobody never CLAIMS — no row goes todo ->
# in_progress. Both halves are asserted below rather than papered over.
#
# Arm A — NOT DUE, no in_progress row in play, so the whole-db snapshot is exact.
db "UPDATE tasks SET status='todo', started_at=NULL WHERE id=${T1};"
T2=$(mk "must not be touched")
BEFORE=$(snapshot); WAKE_CALLS=0
seed_reg "$(date +%s)"
cmd_heartbeat_tick >/dev/null 2>&1
[[ "$(snapshot)" == "$BEFORE" ]] \
  && ok_t "not-due tick leaves EVERY row byte-identical (status/started_at/updated_at)" \
  || bad_t "not-due tick leaves EVERY row byte-identical" "before=[$BEFORE] after=[$(snapshot)]"
(( WAKE_CALLS == 0 )) && ok_t "not-due tick woke nobody" || bad_t "not-due tick woke nobody" "WAKE_CALLS=$WAKE_CALLS"
(( $(db "SELECT COUNT(*) FROM tasks WHERE status='in_progress';") == 0 )) \
  && ok_t "not-due tick claimed nothing (no row moved todo -> in_progress)" \
  || bad_t "not-due tick claimed nothing" "an in_progress row appeared with no wake"

# Arm B — WAKE FAILED. Due, picks T2, but the wake returns nonzero: the claim
# must sit inside the success branch, so the row stays exactly as it was.
db "UPDATE tasks SET status='todo', started_at=NULL WHERE id=${T1};"   # unblock the busy guard
seed_reg 0; WAKE_RC=1; WAKE_CALLS=0
cmd_heartbeat_tick >/dev/null 2>&1
[[ "$(row "$T2")" == "todo|NULL" ]] \
  && ok_t "wake FAILED => target row untouched (claim is inside the success branch)" \
  || bad_t "wake FAILED => target row untouched" "got $(row "$T2")"
(( WAKE_CALLS >= 1 )) && ok_t "wake-failed arm is non-vacuous (the wake was attempted)" \
  || bad_t "wake-failed arm is non-vacuous" "WAKE_CALLS=$WAKE_CALLS"
WAKE_RC=0

# --- 3) The claim is narrow --------------------------------------------------
T3=$(mk "already blocked" blocked)
_hb_claim_task dev "$T3" && bad_t "claim refuses a non-todo row" "claimed a blocked row" \
                         || ok_t "claim refuses a non-todo row"
[[ "$(row "$T3")" == "blocked|NULL" ]] && ok_t "refused claim left the blocked row alone" \
                                       || bad_t "refused claim left the blocked row alone" "got $(row "$T3")"
T4=$(mk "recurring template" todo recurring)
_hb_claim_task dev "$T4" && bad_t "claim refuses a recurring TEMPLATE (DIVE-2055/2059)" "claimed a template" \
                         || ok_t "claim refuses a recurring TEMPLATE (DIVE-2055/2059)"
[[ "$(row "$T4")" == "todo|NULL" ]] && ok_t "refused claim left the template firing (still todo)" \
                                    || bad_t "refused claim left the template firing" "got $(row "$T4")"

# --- 5) End-to-end reaper, reached ONLY via the dispatcher claim -------------
# This is the assertion the ticket asked to mutation-grade. Note what is NOT
# done: the in_progress row is never INSERTed. It is produced by running the
# real tick, so removing the claim removes the reaper's input too. A fixture
# that hand-wrote in_progress would stay green with the bug fully restored.
db "DELETE FROM tasks;"
R1=$(mk "runs away")
seed_reg 0; WAKE_CALLS=0
cmd_heartbeat_tick >/dev/null 2>&1
REACHED_INPROG=0; [[ "$(row "$R1")" == in_progress\|* ]] && REACHED_INPROG=1
# Age the CLOCK only, never the state: everyMin 30 * _HB_STALE_MULT 3 = 90m
# budget, so 200m is unambiguously past it. Scoped `AND status='in_progress'`
# so this exact statement can be replayed verbatim in the mutation arm and be
# DIFFERENTIAL — it must age a real claim, never manufacture the very state the
# mutation is supposed to have removed.
db "UPDATE tasks SET started_at=datetime('now','-200 minutes') WHERE id=${R1} AND status='in_progress';"
read -r RC_N _ < <(_hb_reclaim dev 30)
(( REACHED_INPROG == 1 )) && [[ "$(row "$R1")" == "todo|NULL" ]] && (( ${RC_N:-0} == 1 )) \
  && ok_t "claim -> aged past budget -> reaper requeues to todo (end-to-end, no hand-written state)" \
  || bad_t "claim -> aged -> reaper requeues" "reachedInProgress=$REACHED_INPROG row=$(row "$R1") reclaimed=${RC_N:-?}"

# --- 6) MUTATION ARM: neuter the claim, both arms must go RED ----------------
_hb_claim_task_REAL() { :; }   # placeholder so the name exists before we save it
eval "$(declare -f _hb_claim_task | sed '1s/^_hb_claim_task/_hb_claim_task_REAL/')"
_hb_claim_task() { return 0; }  # the pre-DIVE-2244 world: nudge, never claim
# Confirm the mutation LANDED, behaviourally — a `declare -f` diff would only
# prove the text changed, not that the tick resolves to this definition.
M0=$(mk "mutation probe")
_hb_claim_task dev "$M0"
[[ "$(row "$M0")" == "todo|NULL" ]] \
  && ok_t "[mutation] the neutered claim is live (a direct call no longer moves the row)" \
  || bad_t "[mutation] the neutered claim is live" "row moved to $(row "$M0")"

db "DELETE FROM tasks;"
M1=$(mk "would run away")
seed_reg 0; WAKE_CALLS=0
cmd_heartbeat_tick >/dev/null 2>&1
# RED #1 — assertion (1) inverts.
[[ "$(row "$M1")" == "todo|NULL" ]] \
  && ok_t "[mutation] RED as designed: nudged task never reaches in_progress" \
  || bad_t "[mutation] RED as designed: nudged task never reaches in_progress" "got $(row "$M1")"
# Grade that RED for vacuity: it must be caused by the missing claim, not by a
# tick that silently did nothing. The wake still ran and still targeted M1.
(( WAKE_CALLS == 1 )) \
  && ok_t "[mutation] the RED is non-vacuous — the tick still woke the agent" \
  || bad_t "[mutation] the RED is non-vacuous" "WAKE_CALLS=$WAKE_CALLS (expected 1)"
# RED #2 — the reaper has no input at all, which is the silent half of the bug.
# The aging statement is the SAME one the green arm ran, scope included, so the
# two arms differ ONLY by the mutation. An unscoped backdate here would have
# written started_at onto a never-claimed row and graded a state this arm is
# meant to prove absent (the first draft did exactly that and failed honestly).
db "UPDATE tasks SET started_at=datetime('now','-200 minutes') WHERE id=${M1} AND status='in_progress';"
read -r MRC_N _ < <(_hb_reclaim dev 30)
(( ${MRC_N:-0} == 0 )) && [[ "$(row "$M1")" == "todo|NULL" ]] \
  && ok_t "[mutation] RED as designed: reaper reclaims NOTHING (its input never existed)" \
  || bad_t "[mutation] reaper reclaims nothing" "reclaimed=${MRC_N:-?} row=$(row "$M1")"

# --- 7) Restore: the mutation is what moved the result -----------------------
eval "$(declare -f _hb_claim_task_REAL | sed '1s/^_hb_claim_task_REAL/_hb_claim_task/')"
db "DELETE FROM tasks;"
G1=$(mk "green again")
seed_reg 0; WAKE_CALLS=0
cmd_heartbeat_tick >/dev/null 2>&1
[[ "$(row "$G1")" == in_progress\|* ]] \
  && ok_t "[restore] claim reinstated => green again (the mutation was the cause)" \
  || bad_t "[restore] claim reinstated => green again" "got $(row "$G1")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
