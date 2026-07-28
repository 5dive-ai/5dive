#!/usr/bin/env bash
# DIVE-2113 — `task start` must REFUSE a closed task, and must not refuse anything else.
#
# The defect: `task start` on a done/cancelled row silently reopened it to
# in_progress for ANY actor (neither maker nor verifier), rc=0, with the only
# output an advisory warn about the assignee. The result survived — milder than
# the DIVE-2112 reject bug that destroyed it — but the recorded grade then
# described a task the board showed as OPEN. And done_at was NOT cleared, so the
# row landed internally contradictory: in_progress while still carrying done_at.
#
# Both directions are graded here on purpose. A refusal test with no
# still-works control cannot tell "guards the closed case" from "refuses
# everything", and the second is a fleet-wide outage rather than a fix.
#
# Collects rather than fail-fasts (PASS/FAIL counters, no exit on first bad
# assertion), so an "N red" mutation claim against this file is observable —
# a fail-fast harness can only ever show the FIRST failure (DIVE-1932).
#
#   bash tests/task_start_closed_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"
SRC="${SRC:-src}"
TMP="$(mktemp -d /tmp/task-start-closed.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_agent_pairing.sh cmd_agent_runtime.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

mk() { # mk <title> <status> [result] -> ident
  local t="$1" st="$2" res="${3:-}"
  cmd_task_add "$t" --assignee=dev >/dev/null 2>&1
  local id; id=$(db "SELECT ident FROM tasks WHERE title=$(sqlq "$t");")
  db "UPDATE tasks SET status=$(sqlq "$st")
        $( [[ "$st" == done || "$st" == cancelled ]] && printf ", done_at=datetime('now')" )
        $( [[ -n "$res" ]] && printf ", result=%s" "$(sqlq "$res")" )
      WHERE ident=$(sqlq "$id");"
  printf '%s' "$id"
}
st_of() { db "SELECT status FROM tasks WHERE ident=$(sqlq "$1");"; }

# ---- 1. MUST REFUSE: a closed row is not startable ---------------------------
for s in done cancelled; do
  T=$(mk "closed $s" "$s" "VERIFIER ACK: the graded record")
  OUT=$(cmd_task_start "$T" 2>&1); RC=$?
  [[ $RC -ne 0 ]] \
    && ok_t "task start on a '$s' task REFUSES (rc=$RC)" \
    || bad_t "task start on '$s' refuses" "rc=0 — it reopened a closed task"
  [[ "$(st_of "$T")" == "$s" ]] \
    && ok_t "the '$s' row's status is UNCHANGED by the refused start" \
    || bad_t "'$s' status preserved" "became '$(st_of "$T")'"
  [[ "$(db "SELECT result FROM tasks WHERE ident=$(sqlq "$T");")" == "VERIFIER ACK: the graded record" ]] \
    && ok_t "the '$s' row's graded result is intact" \
    || bad_t "'$s' result intact" "result was mutated"
  grep -q "is CLOSED" <<<"$OUT" \
    && ok_t "the '$s' refusal says the task is CLOSED" \
    || bad_t "'$s' refusal message" "got: ${OUT:0:120}"
done

# ---- 2. THE GUARD MUST NOT ADVERTISE ITS OWN BYPASS ---------------------------
# DIVE-2067: `task done`'s refusal named `task verify --cmd`, which had no
# equivalent check, and a landed verifier ACK was replaced 39 seconds later by
# someone who simply took the exit the refusal offered. A refusal that
# enumerates verbs is a specification of THOSE verbs' obligations, written by
# someone thinking about a different path. This asserts ours names none.
T=$(mk "closed for bypass check" done "graded")
OUT=$(cmd_task_start "$T" 2>&1)
if grep -qE "task (verify|reject|reopen|deliver|unblock|unpark|done|cancel)\b" <<<"$OUT"; then
  bad_t "the refusal names no alternative verb" "it advertises an exit: ${OUT:0:160}"
else
  ok_t "the refusal names NO alternative verb (does not publish a route around itself)"
fi

# ---- 3. MUST STILL WORK: everything not closed ---------------------------------
# Without this, "refuses everything" passes section 1 perfectly.
for s in todo in_progress blocked; do
  T=$(mk "open $s" "$s")
  cmd_task_start "$T" >/dev/null 2>&1; RC=$?
  [[ $RC -eq 0 && "$(st_of "$T")" == "in_progress" ]] \
    && ok_t "task start still works on a '$s' task" \
    || bad_t "start works on '$s'" "rc=$RC status=$(st_of "$T")"
done

echo; echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
