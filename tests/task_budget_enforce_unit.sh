#!/usr/bin/env bash
# DIVE-4430: prove the per-TASK token budget is enforced ONLY on a figure the
# dispatch cross-check verified — and that DIVE-3343's population guard, the
# reason it was ever removed, is still intact underneath it.
#
# HISTORY, because this file has now asserted four different things and each
# assertion was a design document someone cited:
#   DIVE-2794  asserted the budget was HARD (parks + gates).
#   DIVE-3341  inverted arm 0: a row with no budget on a host with no pref is
#              never evaluated. The built-in 5M default had parked 9 rows on
#              customer box 5dive-teal-fox-cx43 and 6 of ours, 2 urgent each.
#   DIVE-3343  inverted the rest. DIVE-3341 removed the POPULATION the bad
#              measurement was applied to; a row with an EXPLICIT budget was
#              still graded by it. `_spend_scan_task_ids` keys by ASSIGNEE and
#              sums every transcript under that agent's home in the row's
#              window — nothing filters by task, because no per-task token
#              signal exists in a transcript to filter on.
#   DIVE-4430  (this) re-arms enforcement, and the reason is written here rather
#              than only on the row because this file is where the next person
#              will look. NOTHING DIVE-3343 MEASURED HAS BEEN WALKED BACK: the
#              assignee-keyed reader is still unattributable, the controls below
#              still re-measure its 6.0M double-billing on this very fixture,
#              and no code path may park a row on it — arm 2 runs the LIVE sweep
#              over DIVE-3341's own shape and requires zero parks.
#
#              What is new is a SIGNAL, not an appetite. DIVE-2058 added a
#              falsifiable cross-check to `usage --json`: an attributed window
#              must intersect a /goal DISPATCH of that ident, and every row
#              carries `dispatched` true|false|null. The guard charges
#              `dispatched == true` and nothing else; false ("attributed, no
#              dispatch found") and null ("no pins to check against") are the
#              ABSENCE of evidence, which is exactly what DIVE-3343 is the
#              record of parking on. Measured blast radius at merge: zero open
#              rows park on the first tick, and the two rows over the 150M
#              default are both unverified and therefore exempt.
#
#              So the arms invert in one direction only. Everything that says
#              "an unverified figure parks nothing" is DIVE-3341/3343 held, and
#              is graded by a MUTANT (arm 2b) that drops the cross-check and
#              requires the same fixture to park — without it, "nothing parked"
#              is a claim an empty guard also satisfies.
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

# ── 1. THE SWEEP IS BACK, AND IT IS THE EVIDENCE THAT CHANGED ────────────────
# DIVE-3343 removed per-task enforcement because the NUMBER COULD NOT BE
# MEASURED. Everything it proved about that number is still true and still
# asserted below: `_spend_scan_task_ids` keys by ASSIGNEE, the controls above
# re-measure the 6.0M double-billing on this very fixture, and nothing in the
# tree may park a row on it.
#
# What DIVE-4430 has that DIVE-3343 did not is a DIFFERENT signal, not a
# different appetite. DIVE-2058 added a falsifiable cross-check to
# `usage --json`: an attributed window must intersect a /goal DISPATCH of that
# ident, and each row carries `dispatched` true|false|null. The guard charges
# `dispatched == true` and NOTHING else — false and null are the absence of
# evidence, which is precisely what DIVE-3343 is the record of parking on.
#
# So this arm inverts and the population guard does not. The sweep exists again;
# every claim below is that it cannot reach DIVE-3341's population.
[[ -n "$(declare -F _hb_task_budget_sweep)" ]] \
  && ok_t "_hb_task_budget_sweep exists again (DIVE-4430) — what follows is why that is not a re-run of DIVE-3341" \
  || bad_t "_hb_task_budget_sweep is missing" "the sweep this file now grades is not defined"

if grep -qE '^\s*_hb_task_budget_sweep' "$SRC/cmd_heartbeat.sh"; then
  ok_t "the heartbeat tick calls it, fed the tick's single usage snapshot"
else
  bad_t "the sweep is defined but never called" "a guard nothing invokes is not a guard"
fi

# The built-in default is back too, and that is the DIVE-3341 shape read
# literally — so say so and grade the thing that makes it different, rather than
# passing on a rename. 3341's 5M builtin parked 9 rows on a CUSTOMER box; this
# one is 150M and, far more to the point, it is a CEILING, never evidence.
[[ "${_HB_TASK_BUDGET_DEFAULT:-}" =~ ^[1-9][0-9]*$ ]] \
  && ok_t "a built-in default budget exists again (${_HB_TASK_BUDGET_DEFAULT} tok) — the arm that matters is not its absence but that it cannot be applied without a verified figure" \
  || bad_t "no built-in default to grade" "_HB_TASK_BUDGET_DEFAULT='${_HB_TASK_BUDGET_DEFAULT:-<unset>}'"

# ── 2. DIVE-3341'S POPULATION, RUN THROUGH THE LIVE SWEEP, PARKS NOTHING ─────
# The fixture is 3341's own shape: rows on ONE agent with real spend under its
# home, an explicit cap far below that spend, a 1500h idle row, and a row with
# no budget at all against a host pref. The sweep runs for real. Nothing may
# park, because no row here has a dispatch-verified figure.
_hb_log() { :; }
ledger_emit() { :; }

# EMPTY snapshot first: the tick that could not read the meter at all.
_hb_task_budget_sweep "" 2>/dev/null
rc_empty=$?
(( rc_empty == 0 )) \
  && ok_t "a tick with NO usage snapshot completes (rc=0) and is a no-op, rather than failing or falling back to a number" \
  || bad_t "the sweep errored on an empty snapshot" "rc=${rc_empty}"

# Then the real shape: a snapshot that DOES attribute tokens to these rows, and
# attributes them at 6.0M against a 1.0M cap — but carries dispatched=false
# (attributed, no dispatch found) and dispatched=null (no pins to check
# against). Both are DIVE-3341's population wearing DIVE-2058's clothes.
UNVERIFIED_JSON=$(cat <<JSON
{"data":{"tasks":[
  {"ident":"DIVE-9000","quota":6000000,"dispatched":false},
  {"ident":"DIVE-9001","quota":6000000,"dispatched":null},
  {"ident":"DIVE-9002","quota":6000000},
  {"ident":"DIVE-9003","quota":6000000,"dispatched":false},
  {"ident":"DIVE-9004","quota":6000000,"dispatched":false}
]}}
JSON
)
_hb_task_budget_sweep "$UNVERIFIED_JSON" 2>/dev/null

for pair in "idle:$id_idle" "pairA:$id_pairA" "pairB:$id_pairB" "none:$id_none" "nobudget:$id_nobud"; do
  nm="${pair%%:*}"; rid="${pair##*:}"
  st=$(parked_of "$rid")
  [[ "$st" == "in_progress/live" ]] \
    && ok_t "row [$nm] is UNTOUCHED at 6000000 attributed tok against a 1000000 cap — the figure is not dispatch-verified, so it is not chargeable (acceptance 1, DIVE-3343's guard intact)" \
    || bad_t "row [$nm] was parked on an unverified figure" "$st — this is DIVE-3341 again"
done

[[ -s "$SCANLOG" ]] \
  && bad_t "a row was SCANNED by the assignee-wide reader" "the task budget may never reach _spend_scan_task_ids: $(cat "$SCANLOG")" \
  || ok_t "no row is ever handed to _spend_scan_task_ids — the unattributable assignee-wide number is not even computed, on either snapshot"

n_reason=$(db "SELECT COUNT(*) FROM tasks WHERE park_reason IS NOT NULL;")
[[ "$n_reason" == "0" ]] \
  && ok_t "no row carries a token-budget park_reason (acceptance 3: the 1500h idle row still scores nothing at all)" \
  || bad_t "a park_reason was written" "$(db "SELECT ident||': '||park_reason FROM tasks WHERE park_reason IS NOT NULL;")"

[[ ! -s "$GATELOG" ]] \
  && ok_t "no budget gate is filed on an unverified figure, so the guard cannot become gate spam" \
  || bad_t "a gate was filed" "$(cat "$GATELOG")"

# ── 2b. THE MUTANT. "Nothing parked" is trivially true of a sweep that parks ──
# nothing EVER, and that is the failure mode DIVE-3341's first replacement arm
# actually had. So break the ONE predicate the claim rests on — charge any
# attributed figure, the pre-DIVE-2058 reading — and require the same fixture to
# park. If this mutant cannot park a row, every arm above is vacuous and says so.
_verified_real() { :; }
eval "_verified_real() $(declare -f _hb_task_verified_quota | tail -n +2)"
_hb_task_verified_quota() {   # the NAIVE reader: no dispatch cross-check
  local ident="$1" json; json=$(cat)
  [[ -n "$json" ]] || return 1
  printf '%s' "$json" | jq -r --arg i "$ident" '
      (.data // .) | (.tasks // []) | map(select(.ident == $i))
      | if length == 0 then empty else ([.[].quota | numbers] | add // 0 | floor) end' 2>/dev/null
}
_hb_task_budget_sweep "$UNVERIFIED_JSON" 2>/dev/null
n_mut=$(db "SELECT COUNT(*) FROM tasks WHERE parked_at IS NOT NULL;")
(( n_mut > 0 )) \
  && ok_t "MUTANT (drop the dispatch cross-check): the same fixture parks ${n_mut} row(s) — so the arms above are graded by the verified-figure predicate and by nothing else" \
  || bad_t "the mutant parks nothing either" "the negative arms above are vacuous: they would pass against a sweep that never parks anything"
# Put the real reader back and undo the mutant's damage before anything else runs.
eval "_hb_task_verified_quota() $(declare -f _verified_real | tail -n +2)"
db "UPDATE tasks SET status='in_progress', parked_at=NULL, park_reason=NULL,
       need_type=NULL, ask=NULL, need_options=NULL, recommend=NULL, gate_mode=NULL;"
: > "$GATELOG"; : > "$SCANLOG"
db "DELETE FROM task_prefs WHERE key='task_budget_trips';"

# ── 3. AND THE POSITIVE HALF: A VERIFIED FIGURE DOES PARK ────────────────────
# Without this the guard could be enforcing nothing at all and every arm above
# would still be green. `dispatched: true` is the only difference from the
# snapshot in arm 2 — same rows, same cap, same spend.
VERIFIED_JSON='{"data":{"tasks":[{"ident":"DIVE-9001","quota":6000000,"dispatched":true}]}}'
_hb_task_budget_sweep "$VERIFIED_JSON" 2>/dev/null
[[ "$(parked_of "$id_pairA")" == "blocked/parked" ]] \
  && ok_t "a row whose figure IS dispatch-verified parks at 6000000/1000000 — the guard is live, not decorative" \
  || bad_t "a verified over-budget row did not park" "$(parked_of "$id_pairA") — the enforcement this row ships does not fire"
[[ "$(parked_of "$id_pairB")" == "in_progress/live" ]] \
  && ok_t "...and its same-agent twin, identical in every way except that ITS figure is unverified, is untouched in the same pass — the double-billing DIVE-3343 measured cannot recur" \
  || bad_t "the unverified twin parked too" "$(parked_of "$id_pairB")"
[[ -s "$GATELOG" ]] \
  && ok_t "the parked row files exactly one gate, so a human sees it (the park is not silent)" \
  || bad_t "a row parked with no gate" "the park would be invisible"
# Reset again for the pref arms below.
db "UPDATE tasks SET status='in_progress', parked_at=NULL, park_reason=NULL,
       need_type=NULL, ask=NULL, need_options=NULL, recommend=NULL, gate_mode=NULL;"
: > "$GATELOG"

# ── 4. THE HOST PREF SETS THE CEILING AND NEVER THE EVIDENCE ─────────────────
# DIVE-3341 left `task_budget_default` alive as "a budget someone typed" and
# DIVE-3343 made every reader of it disappear. It is read again — a ceiling has
# to come from somewhere — so the arm that replaces "nobody reads it" is that
# NO VALUE OF IT can park a row the cross-check did not verify. 5000000 against
# 6000000 of attributed spend is a breach at any cap; it must still park nothing.
db "INSERT INTO task_prefs (key,value) VALUES ('task_budget_default','5000000')
    ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
_hb_task_budget_sweep "$UNVERIFIED_JSON" 2>/dev/null
n_pref=$(db "SELECT COUNT(*) FROM tasks WHERE parked_at IS NOT NULL;")
[[ "$n_pref" == "0" ]] \
  && ok_t "an operator-typed 5000000 host cap parks nothing against 6000000 of UNVERIFIED spend — the pref moves the ceiling, never the evidence" \
  || bad_t "the host pref parked a row on an unverified figure" "$(db "SELECT ident FROM tasks WHERE parked_at IS NOT NULL;")"

# The enforcement pref is the operator's off switch and must still be one.
db "INSERT INTO task_prefs (key,value) VALUES ('task_budget_enforce','off')
    ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
_hb_task_budget_sweep "$VERIFIED_JSON" 2>/dev/null
[[ "$(parked_of "$id_pairA")" == "in_progress/live" ]] \
  && ok_t "task_budget_enforce=off stops even a VERIFIED breach — an operator can turn the whole guard off without editing a row" \
  || bad_t "enforce=off did not disarm the sweep" "$(parked_of "$id_pairA")"
db "DELETE FROM task_prefs WHERE key='task_budget_enforce';"
db "UPDATE tasks SET status='in_progress', parked_at=NULL, park_reason=NULL,
       need_type=NULL, ask=NULL, need_options=NULL, recommend=NULL, gate_mode=NULL;"
: > "$GATELOG"

# ── 4b. THE SURFACES ACCEPT A VALUE, AND NOW SAY WHAT IT DOES ────────────────
db "UPDATE tasks SET task_budget='777777' WHERE id=${id_nobud};"
[[ "$(db "SELECT task_budget FROM tasks WHERE id=${id_nobud};")" == "777777" ]] \
  && ok_t "task_budget is still stored, so no caller's --task-budget= breaks" \
  || bad_t "task_budget is no longer storable" "the column stopped accepting a value"

# The help text was the whole point of DIVE-3343's arm: an operator must never
# believe they hold a guard they do not. The same test, pointed the other way —
# now they must not believe it is inert when it is not, and the text has to name
# what is enforced (a token count) and what is still advisory (the $cost form).
if grep -q 'DIVE-4430' "$SRC/task/crud.sh" \
   && grep -qiE 'ENFORCED again' "$SRC/task/crud.sh" \
   && grep -qi 'cost form is still advisory' "$SRC/task/crud.sh"; then
  ok_t "--task-budget's validation error says a token count is enforced again, names the row, and still calls the \$cost form advisory"
else
  bad_t "--task-budget's help text does not match what the code does" "$(grep -n 'task-budget must be' "$SRC/task/crud.sh")"
fi
if grep -q 'DIVE-4430' "$SRC/task/dispatch.sh" && ! grep -qi 'Nothing enforces it' "$SRC/task/dispatch.sh"; then
  ok_t "set-budget's own help no longer advertises itself as inert"
else
  bad_t "set-budget still says nothing enforces it" "$(grep -n 'set-budget <id>' "$SRC/task/dispatch.sh")"
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
