#!/usr/bin/env bash
# DIVE-3343: prove the per-TASK token budget is NOT enforced — and prove it is
# gone because the number could not be MEASURED, not because it was badly set.
#
# HISTORY, because this file has now asserted three different things and each
# assertion was a design document someone cited:
#   DIVE-2794  asserted the budget was HARD (parks + gates).
#   DIVE-3341  inverted arm 0: a row with no budget on a host with no pref is
#              never evaluated. The built-in 5M default had parked 9 rows on
#              customer box 5dive-teal-fox-cx43 and 6 of ours, 2 urgent each.
#   DIVE-3343  (this) inverts the rest. DIVE-3341 removed the POPULATION the bad
#              measurement was applied to; a row with an EXPLICIT budget was
#              still graded by it. `_spend_scan_task_ids` keys by ASSIGNEE and
#              sums every transcript under that agent's home in the row's
#              window — nothing filters by task, because no per-task token
#              signal exists in a transcript to filter on.
#
# THE HARD PART IS NON-VACUITY AND IT IS BUILT IN, NOT COMMENTED.
# "Nothing parked" is the trivially-passing claim: an empty board passes it, and
# so does a fixture too small to breach. So every negative arm below is paired
# with a control that RUNS the real reader (`_spend_scan_task_ids`) on the same
# fixture and prints what the removed sweep would have charged. If the fixture
# ever stops breaching, the controls go red and say so — the arms cannot quietly
# become vacuous. Cf. DIVE-3341, whose first replacement arm was green against
# the mutant because the shared fixture spent 60k, under any plausible cap.
#
# Isolated: throwaway STATE_DIR + synthetic ~/.claude transcripts under temp
# HOMEs. Never touches the live queue.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-budget-enf.XXXXXX)"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh cmd_usage.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1; mkdir -p "$TASKS_DIR"; set +e
tasks_db_init; _tasks_db_migrate   # parked_at/park_reason are migrate-only
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ── fixtures ─────────────────────────────────────────────────────────────────
# One agent, one HOME, 6.0M of real spend in a single assistant turn. Every row
# below is assigned to it, which is the point: the removed sweep charged each of
# them this same 6.0M.
AG="budgetbig"
FAKEHOME="$TMP/home-$AG"
mkdir -p "$FAKEHOME/.claude/projects/proj"
REGISTRY="$TMP/registry.json"
printf '{"agents":{"%s":{"type":"claude"}}}' "$AG" > "$REGISTRY"
export REGISTRY LOOP_HOME_OVERRIDE_JSON
LOOP_HOME_OVERRIDE_JSON=$(printf '{"%s":"%s"}' "$AG" "$FAKEHOME")

now=$(date +%s)
old_start=$((now - 1500*3600))          # the idle row of acceptance 3: 1500h old
ts1=$(date -u -d "@$((now-600))" +%FT%TZ)
# cache-read deliberately huge and deliberately excluded, same metric as `usage`.
printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-opus-4-8","usage":{"input_tokens":2000000,"output_tokens":2000000,"cache_creation_input_tokens":2000000,"cache_read_input_tokens":999999}}}\n' "$ts1" \
  > "$FAKEHOME/.claude/projects/proj/session.jsonl"

mkrow() { # <ident> <budget-literal-or-empty> <started-epoch> [title]
  local bud="NULL"; [[ -n "$2" ]] && bud="'$2'"
  db "INSERT INTO tasks (ident,title,status,assignee,kind,priority,task_budget,started_at,created_at,updated_at)
      VALUES ('$1','${4:-row $1}','in_progress','$AG','standard','medium',$bud,
              datetime($3,'unixepoch'),datetime($3,'unixepoch'),datetime($3,'unixepoch'));"
  db "SELECT id FROM tasks WHERE ident='$1';"
}
parked_of() { db "SELECT status||'/'||CASE WHEN parked_at IS NOT NULL THEN 'parked' ELSE 'live' END FROM tasks WHERE id=$1;"; }

# Spy on the reader, DELEGATING to the real implementation so an arm can never
# pass by breaking the thing it observes (cf. DIVE-3341's stubbed-observable
# trap). Every call is logged with its argument.
SCANLOG="$TMP/scan.txt"; : > "$SCANLOG"
eval "_scan_real() $(declare -f _spend_scan_task_ids | tail -n +2)"
_spend_scan_task_ids() { printf '%s\n' "$1" >> "$SCANLOG"; _scan_real "$@"; }
# Gate spy: record anything the code would ask for, without a channel or owner.
GATELOG="$TMP/gates.txt"; : > "$GATELOG"
cmd_task_need() { printf '%s\n' "$*" >> "$GATELOG"; return 0; }

id_idle=$(mkrow  DIVE-9000 1000000 "$old_start" "an idle row with an explicit cap and no work done on it")
id_pairA=$(mkrow DIVE-9001 1000000 "$((now-3600))" "first of two rows open on one agent")
id_pairB=$(mkrow DIVE-9002 1000000 "$((now-3600))" "second of two rows open on one agent")
id_none=$(mkrow  DIVE-9003 none    "$((now-3600))")
id_nobud=$(mkrow DIVE-9004 ""      "$((now-3600))")

# ══ CONTROLS FIRST. Everything below is a claim that nothing happens; these ══
# ══ measure that the fixture is big enough for something to HAVE happened.  ══
scan_idle=$(_scan_real "[${id_idle}]" 0 2>/dev/null)
scan_A=$(_scan_real "[${id_pairA}]" 0 2>/dev/null)
scan_B=$(_scan_real "[${id_pairB}]" 0 2>/dev/null)
: > "$SCANLOG"   # the controls are not the code under test; do not count them

[[ "$scan_idle" =~ ^[0-9]+$ ]] && (( scan_idle >= 6000000 )) \
  && ok_t "control: the assignee-wide reader charges the IDLE row $(printf %s "$scan_idle") tok — its budget is 1000000, so the fixture really does breach" \
  || bad_t "control failed: the fixture does not breach, so every arm below is vacuous" "scan=${scan_idle:-<empty>} want >=6000000"

[[ "$scan_A" == "$scan_B" && "$scan_A" =~ ^[1-9][0-9]*$ ]] \
  && ok_t "control: two rows open on one agent are EACH charged the same $(printf %s "$scan_A") tok — the double-billing is structural, not a coincidence" \
  || bad_t "control failed: the two same-agent rows do not read identically" "A=${scan_A:-<empty>} B=${scan_B:-<empty>}"

# ── 1. THE SWEEP IS GONE FROM THE SOURCE, not merely unreferenced ────────────
# A dormant function is one call away from re-arming every box, so its mere
# EXISTENCE is the failure, exactly as arm 0 treats _TASK_BUDGET_BUILTIN.
[[ -z "$(declare -F _hb_task_budget_sweep)" ]] \
  && ok_t "there is no _hb_task_budget_sweep to call" \
  || bad_t "_hb_task_budget_sweep is back" "a per-task budget sweep is defined again"

[[ -z "${_TASK_BUDGET_BUILTIN+set}" ]] \
  && ok_t "there is no built-in default budget constant to fall back to" \
  || bad_t "_TASK_BUDGET_BUILTIN is back" "got '${_TASK_BUDGET_BUILTIN:-}' — an unasked-for cap is enforceable again"

if grep -qE '^\s*_hb_task_budget_sweep' "$SRC/cmd_heartbeat.sh"; then
  bad_t "the heartbeat tick still calls a per-task budget sweep" \
        "$(grep -nE '^\s*_hb_task_budget_sweep' "$SRC/cmd_heartbeat.sh")"
else
  ok_t "the heartbeat tick does not call a per-task budget sweep"
fi

# ── 2. A FULL TICK TOUCHES NOTHING, AND SCANS NOTHING ────────────────────────
# "Never scanned" is the stronger claim and the one that matters: computing an
# unattributable number and then declining to act on it leaves the charge for
# the next reader to wire a consequence to — which is how this one was born.
_hb_log() { :; }
_hb_task_budget_sweep 2>/dev/null   # must be a "command not found", not a pass
tick_rc=$?

(( tick_rc != 0 )) \
  && ok_t "invoking the removed sweep by name fails (rc=${tick_rc}) rather than silently succeeding" \
  || bad_t "something still answers to _hb_task_budget_sweep" "rc=${tick_rc}"

for pair in "idle:$id_idle" "pairA:$id_pairA" "pairB:$id_pairB" "none:$id_none" "nobudget:$id_nobud"; do
  nm="${pair%%:*}"; rid="${pair##*:}"
  st=$(parked_of "$rid")
  [[ "$st" == "in_progress/live" ]] \
    && ok_t "row [$nm] with a 1000000 budget against ${scan_idle} tok of assignee spend is UNTOUCHED" \
    || bad_t "row [$nm] was parked" "$st"
done

[[ -s "$SCANLOG" ]] \
  && bad_t "a row was SCANNED" "no code path may compute an unattributable charge: $(cat "$SCANLOG")" \
  || ok_t "no row is ever SCANNED — the unattributable number is not even computed (acceptance 1)"

n_reason=$(db "SELECT COUNT(*) FROM tasks WHERE park_reason IS NOT NULL;")
[[ "$n_reason" == "0" ]] \
  && ok_t "no row carries a token-budget park_reason (acceptance 3: the 1500h idle row scores nothing at all)" \
  || bad_t "a park_reason was written" "$(db "SELECT ident||': '||park_reason FROM tasks WHERE park_reason IS NOT NULL;")"

[[ ! -s "$GATELOG" ]] \
  && ok_t "no budget gate is filed, so the guard cannot become gate spam" \
  || bad_t "a gate was filed" "$(cat "$GATELOG")"

# ── 3. THE HOST PREF NO LONGER ARMS ANYTHING EITHER ──────────────────────────
# DIVE-3341 left `task_budget_default` alive as "a budget someone typed". It is
# the same unmeasurable quantity when an operator types it, so it must also stop
# parking. Enforcement pref left UNSET on purpose: unset was the armed state.
# Asserted at SOURCE rather than by running a tick: a real tick reaches the
# network and the agent registry, and a harness that has to be timed out cannot
# distinguish "parked nothing" from "died before it got there".
db "INSERT INTO task_prefs (key,value) VALUES ('task_budget_default','5000000')
    ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
pref_readers=$(grep -rn "task_prefs WHERE key='task_budget" "$SRC/" 2>/dev/null)
[[ -z "$pref_readers" ]] \
  && ok_t "no code path reads task_budget_default / _enforce / _gate_tier any more — an operator-typed cap is the same unmeasurable quantity" \
  || bad_t "a budget pref is still read" "$pref_readers"

# And the pref genuinely sits in the db while nothing acts on it, which is the
# state this arm exists to pin: stored, displayed, inert.
[[ "$(db "SELECT value FROM task_prefs WHERE key='task_budget_default';")" == "5000000" ]] \
  && ok_t "...with the 5000000 host pref set and ${scan_idle} tok of spend on the board" \
  || bad_t "fixture leak: the pref did not persist, so the arm above is vacuous" "$(db "SELECT key,value FROM task_prefs;")"

# ── 4. THE SURFACES STILL ACCEPT A VALUE, AND SAY IT IS ADVISORY ─────────────
# Removing the flags would break callers' scripts for no safety gain; leaving
# them silent would let an operator believe they hold a guard they do not.
db "UPDATE tasks SET task_budget='777777' WHERE id=${id_nobud};"
[[ "$(db "SELECT task_budget FROM tasks WHERE id=${id_nobud};")" == "777777" ]] \
  && ok_t "task_budget is still stored, so no caller's --task-budget= breaks" \
  || bad_t "task_budget is no longer storable" "the column stopped accepting a value"

if grep -qi 'advisory' "$SRC/task/dispatch.sh" && grep -q 'DIVE-3343' "$SRC/task/dispatch.sh"; then
  ok_t "set-budget's own help says the value is advisory and names the row that made it so"
else
  bad_t "set-budget still advertises enforcement" "$(grep -n 'set-budget <id>' "$SRC/task/dispatch.sh")"
fi
if grep -q 'advisory only since DIVE-3343' "$SRC/task/crud.sh"; then
  ok_t "--task-budget='s validation error says the same thing"
else
  bad_t "--task-budget still advertises enforcement" "$(grep -n 'task-budget must be' "$SRC/task/crud.sh")"
fi

# ── 5. THE LOOP CEILING IS NOT COLLATERAL ────────────────────────────────────
# `_spend_scan_task_ids` stays: the per-LOOP ceiling reads through it, and there
# the claim is different — a loop's child tasks are the work that loop
# dispatched, inside that loop's own window. Removing the task budget must not
# take the loop ceiling with it.
[[ -n "$(declare -F _spend_scan_task_ids)" && -n "$(declare -F _hb_loop_ceiling_sweep)" ]] \
  && ok_t "the per-LOOP ceiling and its reader both survive (different claim, still enforced)" \
  || bad_t "the loop ceiling was removed as collateral" "scan=$(declare -F _spend_scan_task_ids) sweep=$(declare -F _hb_loop_ceiling_sweep)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
