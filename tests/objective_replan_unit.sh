#!/usr/bin/env bash
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
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/obj-replan-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_goal.sh \
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

echo "-----"
echo "objective_replan_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
