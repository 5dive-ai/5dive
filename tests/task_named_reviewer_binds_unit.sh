#!/usr/bin/env bash
# DIVE-9175 — a reviewer someone NAMED always binds, and the reviewer's close
# runs the row's stored check.
#
# Found in the DIVE-9083 research-team trial: under the box default
# verify=delivered-only, 6 of 6 desk rows filed `--review=<seat>` with no pull
# request closed on the maker's `task done`, past the reviewer the lead had
# named. And a row's stored `--verify=<cmd>` was never read on the close path,
# so the team's QA check held only if the reviewer remembered `task verify`.
#
# Each fix has a mutation arm that puts the old behaviour back and must go RED;
# a green mutation arm means the arms above it grade nothing.
# Run: bash tests/task_named_reviewer_binds_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"

SRC=src
TMP="$(mktemp -d /tmp/task-named-reviewer.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh lib/registry.sh \
         lib/disk.sh lib/verify_policy.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh \
         cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
BOX_CONFIG="$TMP/box.json"
JSON_MODE=1; mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }

cmd_send() { :; }
_task_send_owner() { :; }
set_policy() { printf '{"verify":"%s"}\n' "$1" >"$BOX_CONFIG"; }

tasks_db_init >/dev/null 2>&1
add() { local who="$1"; shift; ( actor_seam_as "$who"; JSON_MODE=1 cmd_task_add "$@" 2>"$TMP"/adderr | jq -r '.data.ident // empty' ); }
as()  { local who="$1"; shift; ( actor_seam_as "$who"; "$@" ) >"$TMP"/out 2>"$TMP"/err; }
col() { db "SELECT COALESCE($2,'') FROM tasks WHERE ident=$(sqlq "$1");"; }
handed_off() { [[ "$(col "$1" status)" == todo && "$(col "$1" assignee)" == reviewer ]]; }

[[ "$( ( actor_seam_as maker; task_actor ) )" == "maker" ]] \
  && ok_t "INSTRUMENT: harness impersonates an actor" \
  || bad_t "INSTRUMENT: actor impersonation broken" "arms below would be vacuous"

# ── 1. a named reviewer binds on a delivered-only box, PR or not ────────────────
set_policy delivered-only
for spelling in --review=reviewer --verifier=reviewer; do
  T=$(add lead "write the market report ($spelling)" --assignee=maker --priority=high "$spelling")
  [[ -n "$T" ]] || { bad_t "add $spelling" "$(cat "$TMP"/adderr)"; continue; }
  as maker cmd_task_done "$T" --result="Report written; sources listed in section 4."
  if handed_off "$T"; then
    ok_t "delivered-only + $spelling, no PR: the maker's done hands the row to the reviewer"
  else
    bad_t "delivered-only + $spelling: the maker's done closed past the reviewer" \
          "status=$(col "$T" status) assignee=$(col "$T" assignee) err=$(head -c 300 "$TMP"/err)"
  fi
done

_n=$( ( actor_seam_as lead; JSON_MODE=0 cmd_task_add "named note row" --assignee=maker --priority=high --review=reviewer ) 2>&1)
[[ "$_n" == *"DIVE-9175"* && "$_n" != *"no grader yet"* ]] \
  && ok_t "task add says the named reviewer binds now, not 'no grader yet'" \
  || bad_t "task add still promises a deferred grader for a named reviewer" "${_n:0:400}"

# ── 2. negative controls: the box default still defers, never still caps ────────
T=$(add lead "write the summary (box default)" --assignee=maker --priority=high)
as maker cmd_task_done "$T" --result="Summary written."
[[ "$(col "$T" status)" == done ]] \
  && ok_t "delivered-only, no reviewer named: the maker's done closes (the box default defers)" \
  || bad_t "a row with no named reviewer stopped closing" "status=$(col "$T" status) assignee=$(col "$T" assignee)"

set_policy never
T=$(add lead "write the brief (never box)" --assignee=maker --priority=high --review=reviewer)
as maker cmd_task_done "$T" --result="Brief written."
[[ "$(col "$T" status)" == done ]] \
  && ok_t "verify=never + --review=<seat>: the box's spend cap still wins" \
  || bad_t "a named reviewer beat verify=never" "status=$(col "$T" status) assignee=$(col "$T" assignee)"
set_policy delivered-only

# ── 3. the reviewer's close runs the stored check ───────────────────────────────
GREEN="$TMP/green"
T=$(add lead "research the vendor list" --assignee=maker --priority=high --review=reviewer --verify="test -f '$GREEN' || { echo 'qa: 2 claims have no source'; exit 3; }")
as maker cmd_task_done "$T" --result="Vendor list done."
handed_off "$T" || bad_t "precondition: check row did not hand off" "status=$(col "$T" status) assignee=$(col "$T" assignee)"
as reviewer cmd_task_done "$T" --result="Looks good."
if [[ "$(col "$T" status)" != done ]] && grep -q "DIVE-9175" "$TMP"/err && grep -q "2 claims have no source" "$TMP"/err; then
  ok_t "red stored check: the reviewer's done is refused, with the check's output"
else
  bad_t "red stored check did not refuse the reviewer's close" "status=$(col "$T" status) err=$(head -c 400 "$TMP"/err)"
fi
touch "$GREEN"
as reviewer cmd_task_done "$T" --result="Looks good; sources fixed."
[[ "$(col "$T" status)" == done ]] \
  && ok_t "green stored check: the reviewer's done closes" \
  || bad_t "green stored check still refused" "status=$(col "$T" status) err=$(head -c 400 "$TMP"/err)"

# ── 4. a recorded PASS counts only when it is the latest record and stamped ─────
_gate_graded_sha() { sed -n 's/.*graded-sha: \([0-9a-f]\{7,40\}\).*/\1/p' <<<"$1" | tail -n1; }
C='bash qa.sh'
P=$'✅ verify PASS (exit 0): bash qa.sh\n--- output tail ---\nok\ngraded-sha: abc1234 (the tree this grade ran in)'
_task_result_stamped_pass "$P" "$C" && ok_t "stamped PASS of the stored command counts" \
  || bad_t "stamped PASS of the stored command was not accepted" ""
! _task_result_stamped_pass $'✅ verify PASS (exit 0): bash qa.sh\nok' "$C" \
  && ok_t "a PASS with no graded-sha does not count" || bad_t "an unstamped PASS counted" ""
! _task_result_stamped_pass "${P}"$'\n❌ verify FAIL (exit 1): bash qa.sh\nboom' "$C" \
  && ok_t "a later FAIL outranks an earlier PASS" || bad_t "a stale PASS beat a later FAIL" ""
! _task_result_stamped_pass "${P//qa.sh/other.sh}" "$C" \
  && ok_t "a PASS of a different command does not count" || bad_t "a PASS of another command counted" ""
unset -f _gate_graded_sha

# ── 5. mutation arms: put each old behaviour back, the arms above must go red ───
_orig_grants=$(declare -f _task_verify_grants)
eval "$(sed '/_task_review_seat_named/d' <<<"$_orig_grants")"
T=$(add lead "mutant 1 report" --assignee=maker --priority=high --review=reviewer)
as maker cmd_task_done "$T" --result="Report."
handed_off "$T" \
  && bad_t "MUTANT 1 (named seat no longer stands in for a delivery) stayed green" "arm 1 grades nothing" \
  || ok_t "MUTANT 1 goes red: without the fix the maker's done closes past the reviewer"
eval "$_orig_grants"

_orig_check=$(declare -f _task_stored_check_at_close)
_task_stored_check_at_close() { return 0; }
T=$(add lead "mutant 2 research" --assignee=maker --priority=high --review=reviewer --verify="exit 3")
as maker cmd_task_done "$T" --result="Research."
as reviewer cmd_task_done "$T" --result="ok"
[[ "$(col "$T" status)" == done ]] \
  && ok_t "MUTANT 2 goes red: without the check the reviewer closes over a failing check" \
  || bad_t "MUTANT 2 (stored check not run) stayed refused" "status=$(col "$T" status) — arm 3 grades nothing"
eval "$_orig_check"

echo "pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
