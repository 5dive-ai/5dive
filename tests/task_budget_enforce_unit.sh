#!/usr/bin/env bash
# DIVE-2794: prove the per-TASK token budget is ENFORCED, not advisory.
#
# `task_budget` was stored, validated and displayed since DIVE-824 and read by
# NOTHING — the field looked like a control and was a label. The two worst
# measured rows (DIVE-2814, 27% of one fleet day; DIVE-3045, 19.1M in 24h on a
# LOW row) were neither loops nor a single agent's 24h total, so the two guards
# that already halt could not see them.
#
# The arms that matter are the NEGATIVE ones — a guard that parks everything is
# not enforcement, it is an outage. So: the carve-out, the cost variant, the
# kill switch and the unreadable-spend case each get their own arm proving the
# row is left ALONE, and each is paired with a positive control so a harness
# that silently stopped parking anything cannot pass.
#
# Isolated: throwaway STATE_DIR + synthetic ~/.claude transcript under a temp
# HOME (same technique as loop_ceiling_enforce_unit.sh). Never touches the live
# queue.
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

AG="budgettest"
FAKEHOME="$TMP/home-$AG"
mkdir -p "$FAKEHOME/.claude/projects/proj"
REGISTRY="$TMP/registry.json"
printf '{"agents":{"%s":{"type":"claude"}}}' "$AG" > "$REGISTRY"
export REGISTRY LOOP_HOME_OVERRIDE_JSON
LOOP_HOME_OVERRIDE_JSON=$(printf '{"%s":"%s"}' "$AG" "$FAKEHOME")

now=$(date +%s); start=$((now-3600))
ts1=$(date -u -d "@$((start+10))" +%FT%TZ)
# 60k of real spend, cache-read deliberately huge and deliberately excluded.
printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-opus-4-8","usage":{"input_tokens":20000,"output_tokens":10000,"cache_creation_input_tokens":30000,"cache_read_input_tokens":999999}}}\n' "$ts1" \
  > "$FAKEHOME/.claude/projects/proj/session.jsonl"

mkrow() { # <ident> <budget-literal-or-empty> <priority> [title]
  local bud="NULL"; [[ -n "$2" ]] && bud="'$2'"
  db "INSERT INTO tasks (ident,title,status,assignee,kind,priority,task_budget,started_at,created_at,updated_at)
      VALUES ('$1','${4:-row $1}','in_progress','$AG','standard','${3:-medium}',$bud,
              datetime($start,'unixepoch'),datetime($start,'unixepoch'),datetime($start,'unixepoch'));"
  db "SELECT id FROM tasks WHERE ident='$1';"
}
parked_of() { db "SELECT status||'/'||CASE WHEN parked_at IS NOT NULL THEN 'parked' ELSE 'live' END FROM tasks WHERE id=$1;"; }

# Gate spy: record what the sweep would ask, without a channel or an owner.
GATELOG="$TMP/gates.txt"; : > "$GATELOG"
cmd_task_need() { printf '%s\n' "$*" >> "$GATELOG"; return 0; }

# ── 0. the shipped default is the number the ticket specifies ────────────────
# A pref can be set to anything; the arm that matters is what a fleet with NO
# pref gets, because that is every row today.
[[ "${_TASK_BUDGET_BUILTIN}" == "5000000" ]] \
  && ok_t "built-in default budget is 5M tokens" \
  || bad_t "built-in default" "got ${_TASK_BUDGET_BUILTIN}"

# Shrink the default for the remaining arms so a 60k fixture can breach it.
db "INSERT INTO task_prefs (key,value) VALUES ('task_budget_default','50000')
    ON CONFLICT(key) DO UPDATE SET value=excluded.value;"

# ── 1. THE POSITIVE ARM: no budget set -> the fleet default is ENFORCED ──────
id_def=$(mkrow "DIVE-9001" "" "low")
_hb_task_budget_sweep >/dev/null 2>&1
[[ "$(parked_of "$id_def")" == "blocked/parked" ]] \
  && ok_t "a row with NO task_budget is parked once it passes the fleet default" \
  || bad_t "default not enforced" "$(parked_of "$id_def")"
reason=$(db "SELECT park_reason FROM tasks WHERE id=$id_def;")
[[ "$reason" == *"60000/50000"* ]] \
  && ok_t "park_reason names the real spend and the budget it broke" \
  || bad_t "park_reason" "$reason"

# ── 2. the gate carries the facts that DECIDE it (main's rubber-stamp guard) ──
gate=$(grep -F "DIVE-9001" "$GATELOG" | head -1)
[[ -n "$gate" ]] && ok_t "a breach files a gate" || bad_t "no gate filed" "$(cat "$GATELOG")"
for fact in "60k" "50k" "low" "--tier=1" "--recommend=park"; do
  if [[ "$gate" == *"$fact"* ]]; then ok_t "gate ask carries [$fact]"
  else bad_t "gate ask missing [$fact]" "$gate"; fi
done
# The exact figures are not lost — they live on the row, where no classifier
# reads them. This is what makes the scaled unit in the ask a free change.
[[ "$(db "SELECT park_reason FROM tasks WHERE id=$id_def;")" == *"60000/50000"* ]] \
  && ok_t "park_reason keeps the EXACT spend, so scaling the ask loses nothing" \
  || bad_t "park_reason lost the exact figures" "$(db "SELECT park_reason FROM tasks WHERE id=$id_def;")"

# ── 2b. THE ASK MUST NOT TRIP THE TIER-2 CATEGORY FLOOR ─────────────────────
# Arm one's first live trip (DIVE-2057, 2026-08-10) parked and gated correctly
# and then paged the paired human, because the ask said "tokens" and `token` is
# on _GATE_T2_FLOOR_RX (there it means an API credential; here it is a unit).
# Every budget trip was being classified as a secrets gate. A gate that pages a
# person on every trip is switched off inside a week, so this asserts the
# property on the ask the sweep ACTUALLY EMITS, using the REAL floor predicate —
# not on a hand-written copy of the string, and not in a comment.
ask_of() { printf '%s' "${1#*--ask=}"; }
ask_def=$(ask_of "$gate")
if _gate_tier2_floor_hit "$ask_def"; then
  bad_t "the emitted ask must not floor to tier 2" \
        "floored on term='$(_gate_tier2_floor_term "$ask_def")': $ask_def"
else
  ok_t "the emitted ask does not trip the T2 category floor (stays lead-clearable)"
fi
# NON-VACUITY: the pre-fix wording must still be detected as a hit by this same
# predicate, or the arm above proves only that the floor stopped working.
_old_shape="DIVE-9001 spent ~60000 tokens (budget 50000) on a low-priority row running ~1h: \"row DIVE-9001\". It is parked. Continue with a raised budget, or leave it parked?"
_gate_tier2_floor_hit "$_old_shape" \
  && ok_t "control: the pre-fix ask DOES floor (term='$(_gate_tier2_floor_term "$_old_shape")') — the arm above is not vacuous" \
  || bad_t "control: the pre-fix ask no longer floors — arm 2b proves nothing" "$_old_shape"


# ── 3. trip rate is recorded from day one, so tier-1-vs-0 is re-decided on a
#       number rather than on irritation ─────────────────────────────────────
[[ "$(db "SELECT value FROM task_prefs WHERE key='task_budget_trips';")" == "1" ]] \
  && ok_t "the trip counter increments on a breach" \
  || bad_t "trip counter" "$(db "SELECT value FROM task_prefs WHERE key='task_budget_trips';")"

# ── 3b. THE ROW TITLE MUST NOT RIDE INSIDE THE ASK ──────────────────────────
# DIVE-2224 answer A made the floor's SUBJECT the ask, precisely so a ticket's
# DESCRIPTION could not be read as a REQUEST. Quoting "${title}" into the ask
# silently undoes that for this one gate: fixing the unit alone still leaves
# every budget trip on a row titled with a floor term paging the human.
# (Ordered AFTER the trip-counter arm on purpose — it parks a second row.)
id_hot=$(mkrow "DIVE-9110" "" "low" "delete the stale webhook rows")
_hb_task_budget_sweep >/dev/null 2>&1
gate_hot=$(grep -F "DIVE-9110" "$GATELOG" | head -1)
[[ -n "$gate_hot" ]] && ok_t "a floor-word row still files its budget gate" \
                     || bad_t "no gate filed for the hot-title row" "$(cat "$GATELOG")"
ask_hot=$(ask_of "$gate_hot")
if _gate_tier2_floor_hit "$ask_hot"; then
  bad_t "a floor-word TITLE must not floor a routine budget trip" \
        "floored on term='$(_gate_tier2_floor_term "$ask_hot")': $ask_hot"
else
  ok_t "a row titled 'delete ...' still files a lead-clearable budget gate"
fi
# NON-VACUITY for 3b: that title floors on its own, so the arm is testing the
# separation and not a harmless fixture.
_gate_tier2_floor_hit "delete the stale webhook rows" \
  && ok_t "control: the fixture title DOES floor on its own — 3b is not vacuous" \
  || bad_t "control: fixture title does not floor; pick a hotter one" "delete the stale webhook rows"

# ── 4. THE CARVE-OUT: 'none' is never parked (paired with a live control) ────
id_none=$(mkrow "DIVE-9002" "none" "urgent")
id_ctl=$(mkrow  "DIVE-9003" "" "urgent")
_hb_task_budget_sweep >/dev/null 2>&1
[[ "$(parked_of "$id_none")" == "in_progress/live" ]] \
  && ok_t "--task-budget=none is EXEMPT — the incident carve-out holds" \
  || bad_t "none was parked" "$(parked_of "$id_none")"
# Non-vacuity: an identical row WITHOUT the carve-out must park in the same pass,
# else the exemption arm proves only that the sweep stopped working.
[[ "$(parked_of "$id_ctl")" == "blocked/parked" ]] \
  && ok_t "control: the same row without 'none' IS parked in the same pass" \
  || bad_t "control not parked — the exemption arm above is vacuous" "$(parked_of "$id_ctl")"

# ── 5. the cost variant belongs to the per-agent guard, not this one ─────────
# '$1.50' must never be compared against a token count. Silently reading it as
# tokens would park the row at 60000 >= 1.50.
id_cost=$(mkrow "DIVE-9004" '$1.50' "medium")
_hb_task_budget_sweep >/dev/null 2>&1
[[ "$(parked_of "$id_cost")" == "in_progress/live" ]] \
  && ok_t "a \$cost budget is skipped, never compared to a token count" \
  || bad_t "cost variant parked" "$(parked_of "$id_cost")"

# ── 6. an explicit numeric budget overrides the fleet default, both ways ────
id_hi=$(mkrow "DIVE-9005" "999999" "medium")
id_lo=$(mkrow "DIVE-9006" "100" "medium")
_hb_task_budget_sweep >/dev/null 2>&1
[[ "$(parked_of "$id_hi")" == "in_progress/live" ]] \
  && ok_t "an explicit budget ABOVE the spend keeps the row live" \
  || bad_t "high budget parked" "$(parked_of "$id_hi")"
[[ "$(parked_of "$id_lo")" == "blocked/parked" ]] \
  && ok_t "an explicit budget BELOW the spend parks the row" \
  || bad_t "low budget not parked" "$(parked_of "$id_lo")"

# ── 7. NOT-REACHED: an unreadable spend must never park (DIVE-2304's rule) ───
# Parking on a number we could not read is the same fail-open pointing the other
# way: it halts live work over a transient python error.
id_nr=$(mkrow "DIVE-9007" "" "high")
_spend_scan_task_ids() { return 2; }
_hb_task_budget_sweep >/dev/null 2>&1
[[ "$(parked_of "$id_nr")" == "in_progress/live" ]] \
  && ok_t "an UNREADABLE spend leaves the row alone (never parks on NOT-REACHED)" \
  || bad_t "parked on an unreadable spend" "$(parked_of "$id_nr")"
unset -f _spend_scan_task_ids
source "$SRC/cmd_loop.sh"
# Non-vacuity for arm 7: with the reader restored, that same row DOES park.
_hb_task_budget_sweep >/dev/null 2>&1
[[ "$(parked_of "$id_nr")" == "blocked/parked" ]] \
  && ok_t "control: the same row parks once the spend is readable again" \
  || bad_t "control failed — arm 7 proved nothing" "$(parked_of "$id_nr")"

# ── 8. the fleet kill switch ─────────────────────────────────────────────────
db "INSERT INTO task_prefs (key,value) VALUES ('task_budget_enforce','off')
    ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
id_off=$(mkrow "DIVE-9008" "" "medium")
_hb_task_budget_sweep >/dev/null 2>&1
[[ "$(parked_of "$id_off")" == "in_progress/live" ]] \
  && ok_t "task_budget_enforce=off disables the sweep fleet-wide" \
  || bad_t "kill switch ignored" "$(parked_of "$id_off")"
db "UPDATE task_prefs SET value='on' WHERE key='task_budget_enforce';"
_hb_task_budget_sweep >/dev/null 2>&1
[[ "$(parked_of "$id_off")" == "blocked/parked" ]] \
  && ok_t "control: switching enforcement back on parks that same row" \
  || bad_t "control failed — the kill-switch arm is vacuous" "$(parked_of "$id_off")"

# ── 9. a terminal row is never touched ───────────────────────────────────────
id_done=$(mkrow "DIVE-9009" "" "medium")
db "UPDATE tasks SET status='done' WHERE id=$id_done;"
_hb_task_budget_sweep >/dev/null 2>&1
[[ "$(parked_of "$id_done")" == "done/live" ]] \
  && ok_t "a done row is never parked (it spends nothing)" \
  || bad_t "done row touched" "$(parked_of "$id_done")"

# ── 10. set-budget: the mid-incident escape must be reachable AFTER filing ───
JSON_MODE=0
id_set=$(mkrow "DIVE-9101" "" "urgent")
out=$(cmd_task_set_budget DIVE-9101 none 2>&1)
[[ "$(db "SELECT task_budget FROM tasks WHERE id=$id_set;")" == "none" ]] \
  && ok_t "set-budget writes the exemption onto an EXISTING row" \
  || bad_t "set-budget did not write" "$out"
_hb_task_budget_sweep >/dev/null 2>&1
[[ "$(parked_of "$id_set")" == "in_progress/live" ]] \
  && ok_t "...and the sweep then honours it (the 3am path works end to end)" \
  || bad_t "exempted row still parked" "$(parked_of "$id_set")"
# THE TRAP THIS CLOSES: unparking alone does not help, because the sweep re-parks
# on the next tick unless the BUDGET changed. Prove the trap is real.
id_trap=$(mkrow "DIVE-9102" "" "urgent")
_hb_task_budget_sweep >/dev/null 2>&1
db "UPDATE tasks SET status='in_progress', parked_at=NULL, park_reason=NULL WHERE id=$id_trap;"
_hb_task_budget_sweep >/dev/null 2>&1
[[ "$(parked_of "$id_trap")" == "blocked/parked" ]] \
  && ok_t "unpark WITHOUT raising the budget is re-parked next tick (why set-budget exists)" \
  || bad_t "expected a re-park" "$(parked_of "$id_trap")"
db "UPDATE tasks SET status='in_progress', parked_at=NULL, park_reason=NULL WHERE id=$id_trap;"
cmd_task_set_budget DIVE-9102 999999 >/dev/null 2>&1
_hb_task_budget_sweep >/dev/null 2>&1
[[ "$(parked_of "$id_trap")" == "in_progress/live" ]] \
  && ok_t "...and unpark WITH a raised budget survives the next tick" \
  || bad_t "raised budget still re-parked" "$(parked_of "$id_trap")"
# set-budget refuses a closed row rather than pretending to cap a finished one.
# SUBSHELL, not a bare call: fail() ends with `exit`, so an unwrapped refusal
# kills this harness at the refusal instead of grading it — and the summary line
# never prints, which reads as a hang rather than as a failure.
db "UPDATE tasks SET status='done' WHERE id=$id_set;"
if ( cmd_task_set_budget DIVE-9101 500 >/dev/null 2>&1 ); then
  bad_t "set-budget accepted a closed row" ""
else
  ok_t "set-budget refuses a closed row"
fi

# ── 11. 'none' is accepted by the add-time validator too ─────────────────────
if ( cmd_task_add "budget none row" --task-budget=none >/dev/null 2>&1 ); then
  ok_t "task add --task-budget=none validates"
else
  bad_t "add rejected --task-budget=none" ""
fi
if ( cmd_task_add "bad budget row" --task-budget=abc >/dev/null 2>&1 ); then
  bad_t "add accepted a malformed --task-budget" ""
else
  ok_t "task add still rejects a malformed --task-budget"
fi

printf -- '-----\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
