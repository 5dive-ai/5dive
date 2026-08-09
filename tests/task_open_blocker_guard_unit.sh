#!/usr/bin/env bash
# DIVE-2317 — status-changing task entry points must not hide a live blocker.
#
# `task start` used to change a blocked row to in_progress while preserving its
# blocked_by edge. The ticket also asked whether park and deliver share the hole:
# park remains blocked and is safe; deliver's distinct-verifier arm changed the
# row to todo and did share it. This harness grades both writers, their messages,
# their no-write contract, and the stale-status exception.
#
# Run: bash tests/task_open_blocker_guard_unit.sh
set -uo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
SRC=src
TMP="$(mktemp -d /tmp/task-open-blocker-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
# shellcheck disable=SC2034  # consumed by the sourced DB helpers
TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
st()    { db "SELECT status FROM tasks WHERE ident=$(sqlq "$1");"; }
field() { db "SELECT COALESCE($2,'NULL') FROM tasks WHERE ident=$(sqlq "$1");"; }

seed() { # seed IDENT STATUS [VERIFIER]
  db "INSERT INTO tasks (ident,title,status,assignee,created_by,verifier)
      VALUES ($(sqlq "$1"),$(sqlq "$1"),$(sqlq "$2"),'maker','maker',$(sqlq_or_null "${3:-}"));"
}
edge() {
  db "INSERT INTO task_deps (task_id,blocked_by)
      SELECT t.id,b.id FROM tasks t,tasks b
      WHERE t.ident=$(sqlq "$1") AND b.ident=$(sqlq "$2");"
}

tasks_db_init

# T1: start refuses the exact broken shape and names the live blocker.
seed DIVE-901 blocked
seed DIVE-902 todo
edge DIVE-901 DIVE-902
out=$(cmd_task_start DIVE-901 --no-preflight 2>&1); rc=$?
[[ "$rc" == "$E_CONFLICT" ]] \
  && ok_t "T1a start on a blocked row with an open blocker exits E_CONFLICT" \
  || bad_t "T1a start refusal code" "rc=$rc want=$E_CONFLICT :: $out"
[[ "$(st DIVE-901)" == blocked && "$(field DIVE-901 started_at)" == NULL ]] \
  && ok_t "T1b refused start writes neither status nor started_at" \
  || bad_t "T1b refused start is non-mutating" "status=$(st DIVE-901) started_at=$(field DIVE-901 started_at)"
[[ "$out" == *"DIVE-902"* && "$out" == *"status='todo'"* && "$out" == *"DIVE-2317"* ]] \
  && ok_t "T1c refusal names the blocker, its state, and the policy ticket" \
  || bad_t "T1c evidence-bearing refusal" "$out"
[[ "$(db "SELECT COUNT(*) FROM policy_refusals WHERE policy='start-on-open-blocker' AND ticket='DIVE-2317' AND ident='DIVE-901';")" == 1 ]] \
  && ok_t "T1d refusal is recorded under a stable policy slug" \
  || bad_t "T1d policy refusal recorded" "$(db "SELECT policy||'|'||ticket||'|'||ident FROM policy_refusals;")"

# T2: a different nonterminal blocker state is live too.
seed DIVE-903 blocked
seed DIVE-904 in_progress
edge DIVE-903 DIVE-904
out=$(cmd_task_start DIVE-903 --no-preflight 2>&1); rc=$?
[[ "$rc" == "$E_CONFLICT" && "$(st DIVE-903)" == blocked && "$out" == *"DIVE-904"* ]] \
  && ok_t "T2 an in-progress blocker also refuses start without changing status" \
  || bad_t "T2 all nonterminal blockers count" "rc=$rc status=$(st DIVE-903) :: $out"

# T3: stale blocked status is not itself a refusal. Both terminal blocker states
# are ignored, matching cascade semantics and preventing a stranded row.
seed DIVE-905 blocked
seed DIVE-906 'done'
seed DIVE-907 'cancelled'
edge DIVE-905 DIVE-906
edge DIVE-905 DIVE-907
out=$(cmd_task_start DIVE-905 --no-preflight 2>&1); rc=$?
[[ "$rc" == 0 && "$(st DIVE-905)" == in_progress ]] \
  && ok_t "T3 a stale blocked row whose blockers are terminal still starts" \
  || bad_t "T3 terminal blockers do not strand a stale row" "rc=$rc status=$(st DIVE-905)"

# T4: the conjunction is deliberate. An inconsistent todo row with the same
# edge keeps legacy behaviour; DIVE-2317 guards the observed blocked-row start.
seed DIVE-908 todo
seed DIVE-909 todo
edge DIVE-908 DIVE-909
out=$(cmd_task_start DIVE-908 --no-preflight 2>&1); rc=$?
[[ "$rc" == 0 && "$(st DIVE-908)" == in_progress ]] \
  && ok_t "T4 a non-blocked row is outside this narrowly scoped refusal" \
  || bad_t "T4 guard is not an edge-only blanket refusal" "rc=$rc status=$(st DIVE-908)"

# T5: deliver was the sibling hole named for inspection in the ticket. Refuse
# before writing either the delivery binding or the verifier handoff.
seed DIVE-910 blocked verifier
seed DIVE-911 todo
edge DIVE-910 DIVE-911
out=$(cmd_task_deliver DIVE-910 --pr=https://github.com/5dive-ai/5dive/pull/999 --result=work 2>&1); rc=$?
[[ "$rc" == "$E_CONFLICT" ]] \
  && ok_t "T5a deliver on a blocked row with an open blocker exits E_CONFLICT" \
  || bad_t "T5a deliver refusal code" "rc=$rc want=$E_CONFLICT :: $out"
[[ "$(st DIVE-910)" == blocked && "$(field DIVE-910 delivery_ref)" == NULL && "$(field DIVE-910 delivered_at)" == NULL && "$(field DIVE-910 result)" == NULL ]] \
  && ok_t "T5b refused deliver writes no status, binding, timestamp, or result" \
  || bad_t "T5b refused deliver is non-mutating" "status=$(st DIVE-910) ref=$(field DIVE-910 delivery_ref) at=$(field DIVE-910 delivered_at) result=$(field DIVE-910 result)"
[[ "$out" == *"DIVE-911"* && "$out" == *"status='todo'"* && "$out" == *"DIVE-2317"* ]] \
  && ok_t "T5c deliver refusal names the live blocker and policy ticket" \
  || bad_t "T5c deliver refusal evidence" "$out"

# T6: stale blocked delivery still works and routes to the distinct verifier.
seed DIVE-912 blocked verifier
seed DIVE-913 'done'
edge DIVE-912 DIVE-913
out=$(cmd_task_deliver DIVE-912 --pr=https://github.com/5dive-ai/5dive/pull/998 --result=work 2>&1); rc=$?
[[ "$rc" == 0 && "$(st DIVE-912)" == todo && "$(field DIVE-912 delivery_ref)" == https://github.com/5dive-ai/5dive/pull/998 ]] \
  && ok_t "T6 stale blocked delivery remains allowed and routes normally" \
  || bad_t "T6 terminal blocker does not refuse delivery" "rc=$rc status=$(st DIVE-912) ref=$(field DIVE-912 delivery_ref)"

# T7: park is the other sibling named for inspection. It preserves blocked
# status and the dependency edge, so it does not share the status/edge hole.
seed DIVE-914 blocked
seed DIVE-915 todo
edge DIVE-914 DIVE-915
out=$(cmd_task_park DIVE-914 --reason="waiting on dependency" --wake=+1d 2>&1); rc=$?
[[ "$rc" == 0 && "$(st DIVE-914)" == blocked && "$(db "SELECT COUNT(*) FROM task_deps d JOIN tasks t ON t.id=d.task_id WHERE t.ident='DIVE-914';")" == 1 ]] \
  && ok_t "T7 park stays blocked and preserves the live edge (no sibling hole)" \
  || bad_t "T7 park preserves the invariant" "rc=$rc status=$(st DIVE-914) edges=$(db "SELECT COUNT(*) FROM task_deps d JOIN tasks t ON t.id=d.task_id WHERE t.ident='DIVE-914';")"

echo
printf 'task_open_blocker_guard_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
