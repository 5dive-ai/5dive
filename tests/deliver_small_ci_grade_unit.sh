#!/usr/bin/env bash
# DIVE-6223 isolated unit harness — a small or docs-only DELIVERY books no grader
# session, and the row it leaves behind is one somebody may actually merge.
#
# The defect: DIVE-2719 (docs-only) and DIVE-4559 (verify-small) were asked only
# by `task done`, and the fleet delivers through `task deliver`, which routed
# every delivery to the grader. Measured 2026-10-14: a one-file README PR (+71/-5)
# under verify-small=150 sat in quinn's queue. And DIVE-6210: a review=check row
# whose command PASSED stayed unmergeable, because the pass was stamped with the
# maker's seat and writer != grader stripped merge standing from everyone.
#
# Every downgrade arm has a CONTROL beside it — same box, same stubs, one input
# changed — so a green arm cannot come from a build where the downgrade fires
# unconditionally.
#
# Run: bash tests/deliver_small_ci_grade_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/deliver-small-ci.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/verify_policy.sh lib/tasks_db.sh lib/runs.sh \
         lib/actor.sh cmd_task.sh cmd_push.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/verify_policy_fixture.sh"

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
BOX_CONFIG="$TMP/box.json"; JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAILN=0
ok_t()  { PASS=$((PASS+1));  printf 'ok   - %s\n' "$1"; }
bad_t() { FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init >/dev/null 2>&1
fixture_box_verify_policy delivered-only || bad_t "fixture" "policy"
fixture_box_verify_small 150 || bad_t "fixture" "verify-small"

# The diff and the seats are stubbed; what is under test is the branch.
_task_default_verifier() { printf 'grader'; }
_task_verify_skip_reason() { printf ''; }
_merge_hold_seat() { printf 'ops'; }
_task_companion_refs() { [[ "${COMP:-}" == 1 ]] && printf 'https://github.com/o/ops/pull/9\n'; return 0; }
_task_delivery_paths() { printf '%s\n' "${FILES_PATH:-README.md}"; }
_task_delivery_file_lines() { printf '%s\t%s\n' "${FILES_PATH:-README.md}" "${FILES_LINES:-76}"; }
FIVE_DELIVER_NO_REACH_PROBE=1

col() { db "SELECT COALESCE($2,'') FROM tasks WHERE id=$1;"; }
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null)
# Every arm, control or not, first proves the delivery LANDED: a refused
# delivery leaves a row that is "not CI-graded" for a reason that has nothing to
# do with the rule under test.
landed() { [[ -n "$(col "$1" delivery_ref)" ]] || { bad_t "delivery refused ($2)" "$(head -c 300 "$TMP/out.$1")"; return 1; }; }

# deliver_row <flags...> -> id of a row delivered by dev2 to a temp grader lane
deliver_row() {
  local out id
  out=$(cmd_task_add "small fixture $RANDOM" --assignee=dev2 --from=main --priority=high --body="w" "$@" 2>/dev/null)
  id=$(jq -r '.data.id // empty' <<<"$out")
  ( actor_seam_as dev2; cmd_task_start "$id" >/dev/null 2>&1
    cmd_task_deliver "$id" --pr="https://github.com/o/r/pull/$id" \
      --result=$'CHANGED: x\nCHECKED: y\nDELIVERED-SHA: '"$HEAD_SHA"$'\nCI: not finished at delivery\nCRITERIA: z' ) >"$TMP/out.$id" 2>&1
  printf '%s' "$id"
}

echo "── the row's harness: +76 README closes without a grader, +290 code is graded ──"
id_doc=$(FILES_PATH=README.md FILES_LINES=76 deliver_row)
landed "$id_doc" id_doc
[[ "$(col "$id_doc" verify_forced)" != "1" ]] \
  && ok_t "fixture: the row is not force-flagged (the arms below are not vacuous)" \
  || bad_t "fixture forced" "verify_forced=1"
if [[ -z "$(col "$id_doc" verifier)" && "$(col "$id_doc" graded_by)" == "ci:docs-only" \
      && "$(col "$id_doc" graded_verdict)" == "pass" && "$(col "$id_doc" assignee)" == "ops" \
      && "$(col "$id_doc" merge_owner)" == "ops" && "$(col "$id_doc" status)" == "todo" ]]; then
  ok_t "a +76 README delivery books NO grader: CI-graded, handed to the merge seat"
else
  bad_t "README delivery skips the grader" "verifier='$(col "$id_doc" verifier)' graded_by='$(col "$id_doc" graded_by)' assignee='$(col "$id_doc" assignee)' out=$(head -c 400 "$TMP/out.$id_doc")"
fi
_gs=$(_gate_graded_sha "$(col "$id_doc" result)")
[[ -n "$_gs" && "$_gs" == "$(col "$id_doc" delivered_sha)" ]] \
  && ok_t "the CI grade names the delivered head as its graded-sha (the merge disposition pins it)" \
  || bad_t "graded-sha" "graded-sha='$_gs' delivered_sha='$(col "$id_doc" delivered_sha)'"
grep -q 'CHANGED: x' <<<"$(col "$id_doc" result)" \
  && ok_t "the maker's result is kept above the CI line" || bad_t "result kept" "$(col "$id_doc" result)"
grep -q 'DIVE-6223' "$TMP/out.$id_doc" \
  && ok_t "the skip names itself on stderr" || bad_t "silent skip" "$(head -c 300 "$TMP/out.$id_doc")"

id_big=$(FILES_PATH=src/cmd_agent.sh FILES_LINES=290 deliver_row)
landed "$id_big" id_big
[[ "$(col "$id_big" verifier)" == "grader" && "$(col "$id_big" assignee)" == "grader" && -z "$(col "$id_big" graded_by)" ]] \
  && ok_t "CONTROL: a +290 code delivery is still routed to its grader" \
  || bad_t "big control" "verifier='$(col "$id_big" verifier)' assignee='$(col "$id_big" assignee)' graded_by='$(col "$id_big" graded_by)'"

echo "── size, and what beats it ──"
id_sm=$(FILES_PATH=src/cmd_agent.sh FILES_LINES=40 deliver_row)
landed "$id_sm" id_sm
[[ "$(col "$id_sm" graded_by)" == "ci:small" && -z "$(col "$id_sm" verifier)" && "$(col "$id_sm" assignee)" == "ops" ]] \
  && ok_t "a 40-line code delivery under verify-small=150 is CI-graded" \
  || bad_t "small code" "graded_by='$(col "$id_sm" graded_by)' verifier='$(col "$id_sm" verifier)'"

id_deny=$(FILES_PATH=src/lib/verify_policy.sh FILES_LINES=5 deliver_row)
landed "$id_deny" id_deny
[[ "$(col "$id_deny" assignee)" == "grader" ]] \
  && ok_t "a 5-line shared-lib delivery is still graded (the denylist beats the size)" \
  || bad_t "denylist" "assignee='$(col "$id_deny" assignee)' graded_by='$(col "$id_deny" graded_by)'"

id_force=$(FILES_PATH=README.md FILES_LINES=5 deliver_row --verify)
landed "$id_force" id_force
[[ "$(col "$id_force" assignee)" == "grader" && -z "$(col "$id_force" graded_by)" ]] \
  && ok_t "--verify beats both rails at delivery, docs-only included" \
  || bad_t "forced" "assignee='$(col "$id_force" assignee)' graded_by='$(col "$id_force" graded_by)'"

id_pin=$(FILES_PATH=src/cmd_agent.sh FILES_LINES=10 deliver_row --review=quinn)
landed "$id_pin" id_pin
[[ "$(col "$id_pin" graded_by)" != ci:* && "$(col "$id_pin" assignee)" != "ops" ]] \
  && ok_t "a row pinned to a NAMED grader keeps it" \
  || bad_t "pinned seat" "graded_by='$(col "$id_pin" graded_by)' assignee='$(col "$id_pin" assignee)'"

id_comp=$(COMP=1 FILES_PATH=README.md FILES_LINES=5 deliver_row)
landed "$id_comp" id_comp
[[ "$(col "$id_comp" graded_by)" != ci:* ]] \
  && ok_t "a row binding companion PRs is still graded (the measurement read one PR, DIVE-4899)" \
  || bad_t "companion" "graded_by='$(col "$id_comp" graded_by)'"

fixture_box_verify_small off || bad_t "fixture" "small off"
id_off=$(FILES_PATH=src/cmd_agent.sh FILES_LINES=10 deliver_row)
landed "$id_off" id_off
[[ "$(col "$id_off" assignee)" == "grader" ]] \
  && ok_t "with verify-small=off a 10-line code delivery is graded" \
  || bad_t "knob off" "assignee='$(col "$id_off" assignee)' graded_by='$(col "$id_off" graded_by)'"
fixture_box_verify_small 150 || bad_t "fixture" "small on"

fixture_box_verify_policy never || bad_t "fixture" "never"
fixture_box_verify_small 150 || true
id_never=$(FILES_PATH=README.md FILES_LINES=5 deliver_row)
landed "$id_never" id_never
[[ -z "$(col "$id_never" graded_by)" ]] \
  && ok_t "a verify=never box keeps its own declined arm (no CI grade is invented)" \
  || bad_t "never" "graded_by='$(col "$id_never" graded_by)'"
fixture_box_verify_policy delivered-only || true
fixture_box_verify_small 150 || true

echo "── merge standing on a CI-graded row ──"
stand() { db "SELECT COUNT(*) FROM tasks WHERE id=$1 AND $(_task_merge_standing_sql "$2");"; }
[[ "$(stand "$id_doc" ops)" == "1" ]] \
  && ok_t "the merge owner holds merge standing on a CI-graded row" || bad_t "owner standing" "count=$(stand "$id_doc" ops)"
[[ "$(stand "$id_doc" dev2)" == "0" && "$(stand "$id_doc" grader)" == "0" ]] \
  && ok_t "the maker and an unrelated seat hold none" || bad_t "others" "dev2=$(stand "$id_doc" dev2) grader=$(stand "$id_doc" grader)"
# CONTROL: the same merge_owner on a SEAT-graded row confers nothing — the
# widening is scoped to graded_by 'ci:*' and nowhere else.
db "UPDATE tasks SET graded_by='quinn', graded_verdict='pass', graded_at=datetime('now'),
       graded_verdict_at=datetime('now'), merge_owner='ops' WHERE id=${id_big};"
[[ "$(stand "$id_big" ops)" == "0" && "$(stand "$id_big" quinn)" == "1" ]] \
  && ok_t "CONTROL: merge_owner on a seat-graded row grants nothing; its grader keeps standing" \
  || bad_t "seat-graded control" "ops=$(stand "$id_big" ops) quinn=$(stand "$id_big" quinn)"
_idoc=$(col "$id_doc" ident)
( _task_merge_preflight "$_idoc" ops ) >/dev/null 2>&1 \
  && ok_t "preflight lets the merge owner through" || bad_t "preflight owner" "refused ops"
( _task_merge_preflight "$_idoc" dev2 ) >/dev/null 2>&1 \
  && bad_t "preflight maker" "the maker passed the preflight" || ok_t "preflight refuses the maker"

echo "── DIVE-6210: a command PASS on a row that already recorded its maker ──"
# Delivered once to a temp grader (maker_agent recorded), then re-delivered with
# --verify=<cmd>: the command grades it, run in the maker's seat.
id_chk=$(FILES_PATH=src/cmd_agent.sh FILES_LINES=290 deliver_row)
landed "$id_chk" id_chk
[[ "$(col "$id_chk" maker_agent)" == "dev2" ]] || bad_t "check fixture" "maker_agent='$(col "$id_chk" maker_agent)'"
( actor_seam_as dev2
  cmd_task_deliver "$id_chk" --pr="https://github.com/o/r/pull/$id_chk" --verify='true' \
    --result=$'CHANGED: x2\nCHECKED: true\nDELIVERED-SHA: '"$HEAD_SHA"$'\nCI: not finished at delivery\nCRITERIA: z' ) >"$TMP/out.chk" 2>&1
if [[ "$(col "$id_chk" graded_verdict)" == "pass" ]]; then
  [[ "$(col "$id_chk" graded_by)" == "ci:command" && "$(col "$id_chk" merge_owner)" == "ops" \
     && -z "$(col "$id_chk" verifier)" && "$(stand "$id_chk" ops)" == "1" ]] \
    && ok_t "the PASS is recorded as the command's, and the merge seat can merge it" \
    || bad_t "check restamp" "graded_by='$(col "$id_chk" graded_by)' merge_owner='$(col "$id_chk" merge_owner)' verifier='$(col "$id_chk" verifier)' standing=$(stand "$id_chk" ops)"
else
  bad_t "check fixture" "the command grade did not pass: $(head -c 500 "$TMP/out.chk")"
fi

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAILN"
(( FAILN == 0 ))
