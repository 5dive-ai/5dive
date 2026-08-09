#!/usr/bin/env bash
# TIER: nightly — 24.1s measured on the 5dive host (OSS-37 re-measured it after adding
# the 6 STUCK arms; was 21.5s, DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# OSS-27 isolated unit harness for the objective RE-PLAN cycle (cmd_objective.sh).
# Feeds diffs via --diff=<json> (the test seam, like goal add --plan) so no live
# planner agent is needed. Asserts the anti-Goodhart spine inherited from
# cmd_goal.sh + the OSS-27 additions:
#   - empty diff -> applied noop, cycle recorded
#   - create (all-low) over the default checkpoint 0 -> ONE decision gate, nothing built
#   - create with --yes -> materialized + stamped originated_by_objective/cycle
#   - max_new_per_cycle cap rejects an over-cap create batch (reject-not-truncate)
#   - tier-lowering guard rejects a low-labeled T2-text create
#   - a T2 create ALWAYS gates (hard tier 2) even with --yes
#   - reprioritize/cancel restricted to THIS objective's own originated tasks
#   - --from-gate applies only on a HUMAN 'approve' (re-validated)
#   - stop-conditions: paused / target-reached / budget-exhausted are terminal
# Run: bash tests/objective_replan_unit.sh  (no root, no network).
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

TMP="$(mktemp -d /tmp/obj-replan-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_goal.sh \
         cmd_loop.sh cmd_objective.sh; do
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
jf()    { jq -r "$1" 2>/dev/null; }
run()   { ( "cmd_objective_$@" ) 2>"$TMP/err"; }   # subshell so fail->exit can't kill harness

objid() { db "SELECT id FROM objectives WHERE name=$(sqlq "$1");"; }

# helper: make an objective
( cmd_objective_add "steer-signups" --metric-cmd="echo 42" --target=100 --direction=up --max-new-per-cycle=2 ) >/dev/null 2>&1
OID=$(objid "steer-signups")
[[ -n "$OID" ]] && ok_t "objective created (id=$OID)" || bad_t "setup" "no objective"

# --- T1: empty diff -> applied noop, a cycle row is recorded
r=$(run replan "steer-signups" --diff='{}')
c1=$(echo "$r" | jf '.data.outcome // (if .data.applied then "applied" else "?" end)')
ncyc=$(db "SELECT COUNT(*) FROM objective_cycles WHERE objective_id=$OID;")
[[ "$(echo "$r" | jf '.ok')" == "true" && "$ncyc" == "1" ]] \
  && ok_t "empty diff -> applied, cycle recorded ($ncyc)" || bad_t "empty diff" "$r"

# --- T2: a single all-low create over the default checkpoint(0) -> GATED
DIFF_ONE='{"create":[{"local_id":"t1","title":"draft a signup nudge email","assignee_or_role":"alice","risk":"low"}]}'
r=$(run replan "steer-signups" --diff="$DIFF_ONE")
gated=$(echo "$r" | jf '.data.gated')
anchor=$(echo "$r" | jf '.data.anchor')
built=$(db "SELECT COUNT(*) FROM tasks WHERE originated_by_objective=$OID;")
[[ "$gated" == "true" && -n "$anchor" && "$built" == "0" ]] \
  && ok_t "all-low create over checkpoint 0 -> ONE gate, nothing built (anchor $anchor)" \
  || bad_t "origination gate" "gated=$gated anchor=$anchor built=$built :: $r"

# the gate is a decision (tier 1 — count-only), on the anchor
gtype=$(db "SELECT need_type FROM tasks WHERE ident=$(sqlq "$anchor");")
gtier=$(db "SELECT COALESCE(tier,'') FROM tasks WHERE ident=$(sqlq "$anchor");")
[[ "$gtype" == "decision" && "$gtier" == "1" ]] \
  && ok_t "count-only origination gates at tier 1 decision" || bad_t "gate tier" "type=$gtype tier=$gtier"

# --- T3: create with --yes -> materialized + provenance stamped
r=$(run replan "steer-signups" --diff="$DIFF_ONE" --yes)
built=$(db "SELECT COUNT(*) FROM tasks WHERE originated_by_objective=$OID AND originated_cycle IS NOT NULL;")
applied=$(echo "$r" | jf '.data.applied')
[[ "$applied" == "true" && "$built" == "1" ]] \
  && ok_t "--yes waives the count checkpoint -> create materialized + stamped" \
  || bad_t "yes apply" "applied=$applied built=$built :: $r"
OWNED_IDENT=$(db "SELECT ident FROM tasks WHERE originated_by_objective=$OID ORDER BY id DESC LIMIT 1;")

# --- T3b (DIVE-1551): a planner that emits `id` instead of `local_id` is
# tolerated (id->local_id coercion) — the create-bearing cycle applies instead
# of crashing with "every task needs a non-empty local_id".
before=$(db "SELECT COUNT(*) FROM tasks WHERE originated_by_objective=$OID;")
DIFF_IDKEY='{"create":[{"id":"t1","title":"ship a referral banner","assignee_or_role":"alice","risk":"low"}]}'
r=$(run replan "steer-signups" --diff="$DIFF_IDKEY" --yes)
after=$(db "SELECT COUNT(*) FROM tasks WHERE originated_by_objective=$OID;")
[[ "$(echo "$r" | jf '.data.applied')" == "true" && "$after" -eq "$((before+1))" ]] \
  && ok_t "DIVE-1551: create using key 'id' is coerced to local_id and applies" \
  || bad_t "id->local_id coercion" "applied=$(echo "$r" | jf '.data.applied') before=$before after=$after :: $(cat "$TMP/err" 2>/dev/null) :: $r"

# --- T4: max_new_per_cycle cap (2) rejects a 3-create batch (reject-not-truncate)
DIFF_OVER='{"create":[{"local_id":"a","title":"one","assignee_or_role":"alice","risk":"low"},{"local_id":"b","title":"two","assignee_or_role":"alice","risk":"low"},{"local_id":"c","title":"three","assignee_or_role":"alice","risk":"low"}]}'
r=$(run replan "steer-signups" --diff="$DIFF_OVER" --yes)
grep -qiE 'over the .*cap|max-tasks' "$TMP/err" \
  && ok_t "create batch over max_new_per_cycle is rejected (not truncated)" || bad_t "cap" "$(cat "$TMP/err") :: $r"

# --- T5: tier-lowering guard — low-labeled but T2 text -> rejected
DIFF_LAUNDER='{"create":[{"local_id":"t1","title":"pay the $500 ad invoice","assignee_or_role":"alice","risk":"low"}]}'
r=$(run replan "steer-signups" --diff="$DIFF_LAUNDER" --yes)
grep -qiE 'Tier-2|lower a tier' "$TMP/err" \
  && ok_t "tier-lowering guard rejects a low-labeled T2-text create" || bad_t "tier guard" "$(cat "$TMP/err") :: $r"

# --- T6: a T2 create ALWAYS gates (hard tier 2) even with --yes
DIFF_T2='{"create":[{"local_id":"t1","title":"buy $200 of ads","assignee_or_role":"alice","risk":"spend"}]}'
r=$(run replan "steer-signups" --diff="$DIFF_T2" --yes)
gated=$(echo "$r" | jf '.data.gated'); anchor=$(echo "$r" | jf '.data.anchor')
gtier=$(db "SELECT tier FROM tasks WHERE ident=$(sqlq "$anchor");")
[[ "$gated" == "true" && "$gtier" == "2" ]] \
  && ok_t "T2 create gates at hard tier 2 even with --yes (never waived)" || bad_t "T2 gate" "gated=$gated tier=$gtier :: $r"

# --- T7: cancel OWN originated task works; a foreign task is refused
FOREIGN=$( ( cmd_task_add --assignee=bob -- "human task not ours" ) | jf '.data.ident' )
r=$(run replan "steer-signups" --diff="$(jq -cn --arg id "$FOREIGN" '{cancel:[{ident:$id,reason:"x"}]}')")
grep -qiE 'only its own originated|not an OPEN task this objective originated' "$TMP/err" \
  && ok_t "cancel of a NON-originated (human) task is refused" || bad_t "cancel foreign" "$(cat "$TMP/err") :: $r"
r=$(run replan "steer-signups" --diff="$(jq -cn --arg id "$OWNED_IDENT" '{cancel:[{ident:$id,reason:"superseded"}]}')")
st=$(db "SELECT status FROM tasks WHERE ident=$(sqlq "$OWNED_IDENT");")
[[ "$(echo "$r" | jf '.data.applied')" == "true" && "$st" == "cancelled" ]] \
  && ok_t "cancel of an OWN originated task applies" || bad_t "cancel own" "st=$st :: $r"

# --- T8: reprioritize own vs foreign
r=$(run replan "steer-signups" --diff="$(jq -cn --arg id "$FOREIGN" '{reprioritize:[{ident:$id,priority:"urgent"}]}')")
grep -qiE 'only its own originated|not an OPEN task this objective originated' "$TMP/err" \
  && ok_t "reprioritize of a foreign task is refused" || bad_t "repri foreign" "$(cat "$TMP/err")"

# --- T9: --from-gate applies ONLY on a human 'approve' (re-validated)
# file a fresh T2 gate, then simulate a human approve, then apply.
r=$(run replan "steer-signups" --diff="$DIFF_T2"); anchor=$(echo "$r" | jf '.data.anchor')
aid=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$anchor");")
# not-yet-answered -> refused
r=$(run replan "steer-signups" --from-gate="$anchor")
grep -qiE 'not answered yet' "$TMP/err" && ok_t "--from-gate refused before a human answers" || bad_t "from-gate pre" "$(cat "$TMP/err")"
# agent-answered (non-human) -> refused
db "UPDATE tasks SET need_answered_at=datetime('now'), need_answer='approve', need_answered_by='agent:dev' WHERE id=$aid;"
r=$(run replan "steer-signups" --from-gate="$anchor")
grep -qiE 'not cleared by a human' "$TMP/err" && ok_t "--from-gate refuses an agent-cleared gate (DIVE-916)" || bad_t "from-gate agent" "$(cat "$TMP/err")"
# human approve -> applies (materializes the T2 create)
before=$(db "SELECT COUNT(*) FROM tasks WHERE originated_by_objective=$OID AND status='todo';")
db "UPDATE tasks SET need_answered_by='human:lodar' WHERE id=$aid;"
r=$(run replan "steer-signups" --from-gate="$anchor")
after=$(db "SELECT COUNT(*) FROM tasks WHERE originated_by_objective=$OID AND status='todo';")
[[ "$(echo "$r" | jf '.data.applied')" == "true" && "$after" -gt "$before" ]] \
  && ok_t "--from-gate applies on a HUMAN approve (materializes the gated create)" || bad_t "from-gate human" "before=$before after=$after :: $r"

# --- T10: stop-conditions
# paused
( cmd_objective_setstatus paused "steer-signups" ) >/dev/null 2>&1
r=$(run replan "steer-signups" --diff='{}')
grep -qiE 'is paused' "$TMP/err" && ok_t "paused objective refuses re-plan" || bad_t "paused" "$(cat "$TMP/err")"
( cmd_objective_setstatus active "steer-signups" ) >/dev/null 2>&1

# target reached (insert a reading at/above target 100)
db "INSERT INTO objective_readings (objective_id, value, rc) VALUES ($OID, 120, 0);"
r=$(run replan "steer-signups" --diff="$DIFF_ONE")
[[ "$(echo "$r" | jf '.data.outcome')" == "target_reached" ]] \
  && ok_t "target-reached is a terminal cycle (originates nothing)" || bad_t "target" "$r"

# budget exhausted (objective with a tiny budget + a spent cycle)
( cmd_objective_add "cap-me" --metric-cmd="echo 1" --target=100 --budget=50 ) >/dev/null 2>&1
BID=$(objid "cap-me")
db "INSERT INTO objective_cycles (objective_id, cycle_no, tokens_spent, outcome) VALUES ($BID, 1, 60, 'applied');"
r=$(run replan "cap-me" --diff="$DIFF_ONE")
[[ "$(echo "$r" | jf '.data.outcome')" == "budget_exhausted" ]] \
  && ok_t "budget-exhausted is a terminal cycle" || bad_t "budget" "$r"

# --- T11: shadow-first (OSS-35) — a shadow objective gates the WHOLE diff, even a
#     reprioritize-only cycle that LIVE mode would apply directly.
( cmd_objective_add "dogfood-run" --metric-cmd="echo 5" --target=10 --shadow --max-new-per-cycle=2 ) >/dev/null 2>&1
SID=$(objid "dogfood-run")
[[ "$(db "SELECT run_mode FROM objectives WHERE id=$SID;")" == "shadow" ]] \
  && ok_t "objective add --shadow persists run_mode=shadow" || bad_t "shadow add" "mode=$(db "SELECT run_mode FROM objectives WHERE id=$SID;")"
# originate one task (via --yes bypass under a temporary live flip? no — set it up directly)
db "UPDATE objectives SET run_mode='live' WHERE id=$SID;"
r=$(run replan "dogfood-run" --diff='{"create":[{"local_id":"t1","title":"seed task","assignee_or_role":"alice","risk":"low"}]}' --yes)
SOWN=$(db "SELECT ident FROM tasks WHERE originated_by_objective=$SID ORDER BY id DESC LIMIT 1;")
db "UPDATE objectives SET run_mode='shadow' WHERE id=$SID;"
# now a reprioritize-only diff must GATE (shadow), not apply
r=$(run replan "dogfood-run" --diff="$(jq -cn --arg id "$SOWN" '{reprioritize:[{ident:$id,priority:"urgent"}]}')")
gated=$(echo "$r" | jf '.data.gated'); po=$(echo "$r" | jf '.data.proposeOnly')
prio=$(db "SELECT priority FROM tasks WHERE ident=$(sqlq "$SOWN");")
[[ "$gated" == "true" && "$po" == "true" && "$prio" != "urgent" ]] \
  && ok_t "shadow: a reprioritize-only cycle is GATED (nothing auto-applied)" \
  || bad_t "shadow gate repri" "gated=$gated po=$po prio=$prio :: $r"

# --- T12: --yes cannot waive a shadow propose-only gate
r=$(run replan "dogfood-run" --diff="$(jq -cn --arg id "$SOWN" '{cancel:[{ident:$id,reason:"x"}]}')" --yes)
st=$(db "SELECT status FROM tasks WHERE ident=$(sqlq "$SOWN");")
[[ "$(echo "$r" | jf '.data.gated')" == "true" && "$st" != "cancelled" ]] \
  && ok_t "shadow: --yes cannot waive the propose-only gate" || bad_t "shadow yes" "st=$st :: $r"

# --- T13: objective shadow/live setters flip the mode
( cmd_objective_setmode live "dogfood-run" ) >/dev/null 2>&1
[[ "$(db "SELECT run_mode FROM objectives WHERE id=$SID;")" == "live" ]] \
  && ok_t "objective live flips run_mode back to live" || bad_t "live setter" ""
# in live, a reprioritize-only cycle applies directly (own-task autonomy)
r=$(run replan "dogfood-run" --diff="$(jq -cn --arg id "$SOWN" '{reprioritize:[{ident:$id,priority:"high"}]}')")
[[ "$(echo "$r" | jf '.data.applied')" == "true" && "$(db "SELECT priority FROM tasks WHERE ident=$(sqlq "$SOWN");")" == "high" ]] \
  && ok_t "live: a reprioritize-only cycle applies directly (own-task autonomy)" || bad_t "live apply" "$r"

# --- T14: --propose-only flag forces the gate on a LIVE objective
r=$(run replan "dogfood-run" --propose-only --diff="$(jq -cn --arg id "$SOWN" '{reprioritize:[{ident:$id,priority:"low"}]}')")
[[ "$(echo "$r" | jf '.data.gated')" == "true" && "$(db "SELECT priority FROM tasks WHERE ident=$(sqlq "$SOWN");")" == "high" ]] \
  && ok_t "--propose-only forces the gate on a live objective" || bad_t "propose-only flag" "$r"

# --- T15 (OSS-37): a burnt-out maker→verifier loop is marked STUCK in the injected
# context. `task reject` at max_iterations parks the row on a human without closing
# it, so without a marker the planner reads a dead task as in-flight and re-plans
# around nothing. Rendered by _objective_build_contract, which the --diff seam never
# reaches (it bypasses the live planner), so the arms call it directly.
( cmd_objective_add "stuck-probe" --metric-cmd="echo 1" --target=10 --direction=up ) >/dev/null 2>&1
PID=$(objid "stuck-probe")
LOOPT=$( ( cmd_task_add --assignee=alice -- "loop task with a verifier" ) | jf '.data.ident' )
PLAINT=$( ( cmd_task_add --assignee=alice -- "plain task, no verifier" ) | jf '.data.ident' )
db "UPDATE tasks SET originated_by_objective=$PID, originated_cycle=1 WHERE ident IN ($(sqlq "$LOOPT"), $(sqlq "$PLAINT"));"
# a live loop BELOW its cap: attached verifier, 1 of 3 iterations spent
db "UPDATE tasks SET verifier='bob', max_iterations=3, iteration=1 WHERE ident=$(sqlq "$LOOPT");"
ctx=$(_objective_build_contract "stuck-probe" "$PID" "1" "" "flat" "10" "up" "" "2")

# A1 baseline: the row renders and its LINE is NOT marked — proves the marker is
# absent before the condition holds, so A2 is not asserting a string that is always
# present. Graded on the task's own line, never on the whole context: the standing
# guidance paragraph names STUCK verbatim, so a whole-context match is true from the
# first render and would grade nothing.
line=$(printf '%s\n' "$ctx" | grep -F "$LOOPT")
[[ -n "$line" && "$line" != *"STUCK"* ]] \
  && ok_t "OSS-37: a loop below its cap renders unmarked (baseline)" \
  || bad_t "stuck baseline" "line=$line"

# A2: burn the cap -> STUCK, naming the spent iterations
db "UPDATE tasks SET iteration=3, status='blocked' WHERE ident=$(sqlq "$LOOPT");"
ctx=$(_objective_build_contract "stuck-probe" "$PID" "1" "" "flat" "10" "up" "" "2")
line=$(printf '%s\n' "$ctx" | grep -F "$LOOPT")
[[ "$line" == *"STUCK"* && "$line" == *"3/3"* ]] \
  && ok_t "OSS-37: a loop at its cap is marked STUCK with its spent iterations" \
  || bad_t "stuck marker" "line=$line"

# A3: isolating witness — the sibling open originated task with NO verifier is
# rendered in the SAME context and stays unmarked, so the marker is per-row and
# has not degraded into a blanket applied to every open task.
pline=$(printf '%s\n' "$ctx" | grep -F "$PLAINT")
[[ -n "$pline" && "$pline" != *"STUCK"* ]] \
  && ok_t "OSS-37: a non-loop sibling in the same render stays unmarked" \
  || bad_t "stuck bleed" "pline=$pline"

# A4: the unanswered human gate the escalation filed is named — the planner must
# not treat cancelling its own task as having resolved that gate.
db "UPDATE tasks SET need_type='manual', ask='loop stuck, review + decide', need_answered_at=NULL WHERE ident=$(sqlq "$LOOPT");"
ctx=$(_objective_build_contract "stuck-probe" "$PID" "1" "" "flat" "10" "up" "" "2")
line=$(printf '%s\n' "$ctx" | grep -F "$LOOPT")
[[ "$line" == *"parked on an unanswered human gate"* ]] \
  && ok_t "OSS-37: a stuck task parked on an open human gate says so" || bad_t "stuck gate note" "line=$line"

# A5: an ANSWERED gate drops the parked note (the marker tracks the gate's live
# state, not the mere presence of a need_type).
db "UPDATE tasks SET need_answered_at=datetime('now'), need_answered_by='human:tester' WHERE ident=$(sqlq "$LOOPT");"
line=$(_objective_build_contract "stuck-probe" "$PID" "1" "" "flat" "10" "up" "" "2" | grep -F "$LOOPT")
[[ "$line" == *"STUCK"* && "$line" != *"parked on an unanswered"* ]] \
  && ok_t "OSS-37: an answered gate drops the parked note, STUCK stays" || bad_t "stuck gate answered" "line=$line"

# A6: the prompt tells the planner what STUCK obliges — re-plan around it, and the
# human gate is not its to clear.
[[ "$ctx" == *"** STUCK **"* && "$ctx" == *"NOT yours to clear"* ]] \
  && ok_t "OSS-37: the contract explains STUCK and fences the human gate" || bad_t "stuck guidance" "missing guidance"

# A7 (main's review of OSS-37): the planner and `loop board --stuck` share ONE
# definition of stuck — they do not merely agree. Two copies that match today buy
# does-not-currently-drift; only a shared definition buys cannot-drift, and the two
# are indistinguishable by any assertion that reads the CURRENT output of each.
#
# So mutate the definition and require BOTH to move. Overriding
# _task_stuck_loop_pred to a never-true predicate must strip the marker from the
# planner's context AND drop the row from the loops board's stuck set. A consumer
# that re-typed the predicate inline would be untouched by the override and stay
# marked — which is exactly the drift this arm exists to catch, made observable
# instead of left to a future reader to notice.
_orig_stuck_pred=$(declare -f _task_stuck_loop_pred)
_task_stuck_loop_pred() { printf '%s' "(1=0)"; }

mline=$(_objective_build_contract "stuck-probe" "$PID" "1" "" "flat" "10" "up" "" "2" | grep -F "$LOOPT")
mboard=$( ( JSON_MODE=1 cmd_task_loops --stuck ) 2>/dev/null | jf '[.data.loops[]?.ident] | join(",")' )
eval "$_orig_stuck_pred"                      # restore before asserting, so a failed
                                              # arm cannot leave the override in place
                                              # for every later arm in this file.
[[ "$mline" != *"STUCK"* ]] \
  && ok_t "OSS-37: overriding the shared predicate unmarks the planner's context" \
  || bad_t "planner re-types the predicate" "planner still marks the row with the definition mutated: $mline"
[[ "$mboard" != *"$LOOPT"* ]] \
  && ok_t "OSS-37: the same override drops the row from \`task loops --stuck\`" \
  || bad_t "board re-types the predicate" "board still lists $LOOPT with the definition mutated: $mboard"

# A7 is only meaningful if the row IS stuck under the REAL definition — otherwise both
# halves pass vacuously on a row nothing would ever mark. Re-assert the positive here,
# after the restore, so the control and the mutation are graded against one another.
rline=$(_objective_build_contract "stuck-probe" "$PID" "1" "" "flat" "10" "up" "" "2" | grep -F "$LOOPT")
rboard=$( ( JSON_MODE=1 cmd_task_loops --stuck ) 2>/dev/null | jf '[.data.loops[]?.ident] | join(",")' )
[[ "$rline" == *"STUCK"* && "$rboard" == *"$LOOPT"* ]] \
  && ok_t "OSS-37: with the real predicate restored, BOTH consumers mark the row (A7 non-vacuous)" \
  || bad_t "A7 vacuity control" "line=$rline board=$rboard"

echo "-----"
echo "objective_replan_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
