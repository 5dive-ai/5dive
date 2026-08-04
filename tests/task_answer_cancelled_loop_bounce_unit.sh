#!/usr/bin/env bash
# TIER: core
# DIVE-2261 — a loop rejection must not resurrect a cancelled prior step.
#
# The DIVE-552 bounce used to select the immediately preceding loop step without
# reading its status, then unconditionally write it to todo.  A cancellation is
# an explicit abandonment record, so the conservative behaviour is to refuse the
# answer before recording it.  The gate stays open and the cancelled row stays
# byte-for-byte unchanged.  The done-row control proves the ordinary redo path
# still works.
# Run: bash tests/task_answer_cancelled_loop_bounce_unit.sh
# shellcheck disable=SC2015,SC2034
set -uo pipefail

# shellcheck source=tests/lib/grading_tree.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.." || exit
# shellcheck source=tests/lib/actor_seam.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"

SRC="${DIVE2261_SRC_DIR:-src}"
TMP="$(mktemp -d /tmp/task-answer-cancelled-loop-bounce.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh \
         cmd_push.sh cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1; mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }

tasks_db_init
as() { local who="$1"; shift; ( actor_seam_as "$who"; "$@" ); }
add() { JSON_MODE=1 cmd_task_add "$@" 2>"$TMP/err" | jq -r '.data.ident // empty'; }
id_of() { db "SELECT id FROM tasks WHERE ident=$(sqlq "$1");"; }
field() { db "SELECT COALESCE($2,'') FROM tasks WHERE ident=$(sqlq "$1");"; }

seed_loop_gate() {
  local previous_status="$1" prefix="$2" gate_type="${3:-decision}"
  local run prev gate run_id prev_id gate_id
  run=$(add "$prefix run" --assignee=main)
  prev=$(add "$prefix previous work" --assignee=dev)
  gate=$(add "$prefix review gate" --assignee=dev2)
  run_id=$(id_of "$run"); prev_id=$(id_of "$prev"); gate_id=$(id_of "$gate")
  db "UPDATE tasks SET body='[[5dive-loop:run]]' WHERE id=${run_id};
      UPDATE tasks SET parent_id=${run_id}, body='[[5dive-loop:work]]',
        status=$(sqlq "$previous_status"), started_at='2001-02-03 04:05:06',
        done_at='2001-02-03 05:06:07' WHERE id=${prev_id};
      UPDATE tasks SET parent_id=${run_id}, body=$(sqlq "[[5dive-loop:gate:${gate_type}]]"),
        status='blocked', need_type=$(sqlq "$gate_type"), ask='approve or redo?', tier=1,
        need_asked_at='2001-02-03 06:07:08', need_answered_at=NULL,
        need_answered_by=NULL WHERE id=${gate_id};"
  printf '%s|%s|%s' "$run" "$prev" "$gate"
}

# C1 — the reported residual. Refusal must happen before any answer/bounce write.
IFS='|' read -r _c_run c_prev c_gate <<<"$(seed_loop_gate cancelled c)"
c_before=$(db "SELECT status||'|'||COALESCE(started_at,'')||'|'||COALESCE(done_at,'') FROM tasks WHERE ident=$(sqlq "$c_prev");")
c_out=$(as dev2 cmd_task_answer "$c_gate" --value="Do better ↩" 2>&1); c_rc=$?
[[ $c_rc -ne 0 ]] \
  && ok_t "C1 cancelled previous step is refused" \
  || bad_t "C1 cancelled previous step is refused" "rc=0; output=$c_out"
[[ "$c_out" == *"$c_prev"* && "$c_out" == *"cancelled"* && "$c_out" == *"still open"* ]] \
  && ok_t "C1 refusal names the abandoned step and the open gate" \
  || bad_t "C1 refusal names the abandoned step and the open gate" "$c_out"
[[ "$(db "SELECT status||'|'||COALESCE(started_at,'')||'|'||COALESCE(done_at,'') FROM tasks WHERE ident=$(sqlq "$c_prev");")" == "$c_before" ]] \
  && ok_t "C1 cancelled row is byte-for-byte unchanged across its lifecycle fields" \
  || bad_t "C1 cancelled row is byte-for-byte unchanged across its lifecycle fields" "before=$c_before after=$(field "$c_prev" status)|$(field "$c_prev" started_at)|$(field "$c_prev" done_at)"
[[ "$(field "$c_gate" status)" == "blocked" && -z "$(field "$c_gate" need_answered_at)" ]] \
  && ok_t "C1 gate stays blocked and unanswered" \
  || bad_t "C1 gate stays blocked and unanswered" "status=$(field "$c_gate" status) answered_at=$(field "$c_gate" need_answered_at)"
[[ "$(db "SELECT COUNT(*) FROM task_deps WHERE task_id=$(id_of "$c_gate");")" == "0" ]] \
  && ok_t "C1 refusal creates no synthetic dependency edge" \
  || bad_t "C1 refusal creates no synthetic dependency edge" "edge was inserted despite refusal"
[[ "$(db "SELECT COUNT(*) FROM policy_refusals WHERE policy='task_loop_bounce_cancelled_previous' AND ident=$(sqlq "$c_gate");")" == "1" ]] \
  && ok_t "C1 refusal is audit-visible under the DIVE-2261 policy" \
  || bad_t "C1 refusal is audit-visible under the DIVE-2261 policy" "policy_refusal count was not 1"

# C2 — current loop gates are approvals and spell the same direction "denied".
IFS='|' read -r _c2_run c2_prev c2_gate <<<"$(seed_loop_gate cancelled c2 approval)"
c2_out=$(as dev2 cmd_task_answer "$c2_gate" --value="denied" 2>&1); c2_rc=$?
[[ $c2_rc -ne 0 && "$c2_out" == *"$c2_prev"* && "$c2_out" == *"cancelled"* ]] \
  && ok_t "C2 approval-gate denied vocabulary takes the same refusal" \
  || bad_t "C2 approval-gate denied vocabulary takes the same refusal" "rc=$c2_rc; output=$c2_out"
[[ "$(field "$c2_prev" status)" == "cancelled" && -z "$(field "$c2_gate" need_answered_at)" ]] \
  && ok_t "C2 denied leaves both approval rows untouched" \
  || bad_t "C2 denied leaves both approval rows untouched" "previous=$(field "$c2_prev" status) answered_at=$(field "$c2_gate" need_answered_at)"

# W1 — positive control. A completed prior step is exactly what bounce is for.
IFS='|' read -r _w_run w_prev w_gate <<<"$(seed_loop_gate "done" w)"
w_out=$(as dev2 cmd_task_answer "$w_gate" --value="Do better ↩" 2>&1); w_rc=$?
[[ $w_rc -eq 0 ]] \
  && ok_t "W1 bounce from a done previous step still succeeds" \
  || bad_t "W1 bounce from a done previous step still succeeds" "rc=$w_rc; output=$w_out"
[[ "$(field "$w_prev" status)" == "todo" && -z "$(field "$w_prev" started_at)" ]] \
  && ok_t "W1 completed work is reopened for redo" \
  || bad_t "W1 completed work is reopened for redo" "status=$(field "$w_prev" status) started_at=$(field "$w_prev" started_at)"
[[ "$(field "$w_gate" status)" == "blocked" && -n "$(field "$w_gate" need_answered_at)" ]] \
  && ok_t "W1 answered gate is re-blocked behind the redo" \
  || bad_t "W1 answered gate is re-blocked behind the redo" "status=$(field "$w_gate" status) answered_at=$(field "$w_gate" need_answered_at)"
[[ "$(db "SELECT COUNT(*) FROM task_deps WHERE task_id=$(id_of "$w_gate") AND blocked_by=$(id_of "$w_prev");")" == "1" ]] \
  && ok_t "W1 bounce installs the expected dependency edge" \
  || bad_t "W1 bounce installs the expected dependency edge" "expected gate -> previous edge"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
