#!/usr/bin/env bash
# DIVE-2059 isolated unit harness for the START-ON-TEMPLATE guard in
# _task_status_cmd. Bug: `task start` on a recurring TEMPLATE (kind='recurring')
# set status='in_progress' with no guard, and post-DIVE-2055 the materializer's
# fire predicate requires status='todo' — so a `task start <template>` silently
# retired the driver (no error, no output) and the template also dropped out of
# the default `task ls --recurring` listing (same live predicate). cancel/block/
# park on a template are the real, intentional stop levers from DIVE-2055 and
# must keep working — this guard refuses ONLY the meaningless 'start' verb.
# Isolation matches the sibling guard harnesses: source src/ libs into a
# throwaway STATE_DIR — the live shared tasks.db is NEVER touched.
# Run: bash tests/task_start_recurring_guard_unit.sh  (no root, no network).
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
TMP="$(mktemp -d /tmp/start-recurring-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
audit_log() { :; }

seed_template() { db "INSERT INTO tasks (ident, title, status, created_by, kind, schedule) VALUES ('$1','t','todo','main','recurring','0 2 * * *');"; }
seed_std()      { db "INSERT INTO tasks (ident, title, status, created_by, kind) VALUES ('$1','t','todo','main','standard');"; }
statusof()      { db "SELECT status FROM tasks WHERE ident='$1';"; }
scheduleof()    { db "SELECT COALESCE(schedule,'') FROM tasks WHERE ident='$1';"; }

# --- T1: `task start` on a recurring TEMPLATE is REFUSED, status stays 'todo'
#     (the materializer's fire predicate), and the schedule survives intact. --
seed_template DIVE-301
out=$(cmd_task_start DIVE-301 --no-preflight 2>&1); rc=$?
[[ $rc -ne 0 ]] \
  && ok_t "T1 start on a recurring template is REFUSED (non-zero exit)" \
  || bad_t "T1 start refused" "rc=$rc out=$out"
[[ "$(statusof DIVE-301)" == "todo" ]] \
  && ok_t "T1 status stays 'todo' — the template keeps firing" \
  || bad_t "T1 status unchanged" "status=$(statusof DIVE-301)"
[[ "$(scheduleof DIVE-301)" == "0 2 * * *" ]] \
  && ok_t "T1 schedule survives the refused start" \
  || bad_t "T1 schedule intact" "schedule=$(scheduleof DIVE-301)"
[[ "$out" == *"task cancel"* && "$out" == *"TEMPLATE"* ]] \
  && ok_t "T1 refusal carries an actionable, attributed message" \
  || bad_t "T1 actionable message" "out=$out"

# --- T2: cancel/block/park on a template are UNCHANGED — the real DIVE-2055
#     stop levers must keep working; this guard is scoped to 'start' only. ----
seed_template DIVE-302
cmd_task_cancel DIVE-302 --result="retiring" >/dev/null 2>&1
[[ "$(statusof DIVE-302)" == "cancelled" ]] \
  && ok_t "T2 cancel on a template still works" \
  || bad_t "T2 cancel unaffected" "status=$(statusof DIVE-302)"

seed_template DIVE-303
cmd_task_park DIVE-303 --reason="hold" --wake=+7d >/dev/null 2>&1
[[ "$(statusof DIVE-303)" == "blocked" ]] \
  && ok_t "T2 park on a template still works" \
  || bad_t "T2 park unaffected" "status=$(statusof DIVE-303)"

# --- T3: `task start` on an ORDINARY (kind='standard') task is UNCHANGED —
#     the guard is scoped to recurring templates, not a blanket block. --------
seed_std DIVE-304
cmd_task_start DIVE-304 --no-preflight >/dev/null 2>&1
[[ "$(statusof DIVE-304)" == "in_progress" ]] \
  && ok_t "T3 start on a standard task is UNCHANGED (starts normally)" \
  || bad_t "T3 standard start" "status=$(statusof DIVE-304)"

echo "-----"
printf 'task_start_recurring_guard_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
