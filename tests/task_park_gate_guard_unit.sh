#!/usr/bin/env bash
# DIVE-1453 isolated unit harness for the PARK-OVER-GATE guard in cmd_task_park.
# Bug: park and a human need-gate share status='blocked' plus the need_* columns,
# so cmd_task_park's UPDATE (which NULLs need_type/ask/need_options/recommend/
# need_answer/need_answered_at) would silently DESTROY an open, unanswered gate —
# no answer, no audit row — and the heartbeat wake then unparks it to todo as if a
# human had cleared it (live case: DIVE-1366 ada/rex approval gate, 2026-07-17).
# Fix: park REFUSES when the task has a live gate (need_type set, need_answered_at
# NULL, task still open). Isolation matches the sibling gate harnesses: source src/
# libs into a throwaway STATE_DIR — the live shared tasks.db is NEVER touched.
# Run: bash tests/task_park_gate_guard_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/park-gate-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# Don't DM on gate filing; no root-owned audit log in this harness.
task_need_notify() { :; }
audit_log() { :; }
# A trusted human path for answering (keeps the tier-2 provenance floor happy so
# the "answer then park" control clears cleanly).
export SUDO_UID=0
id() { if [[ "${1:-}" == -un ]]; then echo "root"; else command id "$@"; fi; }

seed_task()  { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
statusof()   { db "SELECT status FROM tasks WHERE ident='$1';"; }
needtype()   { db "SELECT COALESCE(need_type,'') FROM tasks WHERE ident='$1';"; }
gateopen()   { db "SELECT CASE WHEN need_type IS NOT NULL AND need_answered_at IS NULL THEN 'open' ELSE 'clear' END FROM tasks WHERE ident='$1';"; }
parkedof()   { db "SELECT CASE WHEN parked_at IS NULL THEN 'no' ELSE 'yes' END FROM tasks WHERE ident='$1';"; }

# --- T1: parking a task with an OPEN gate is REFUSED, and the gate SURVIVES intact
#     (need_type/ask preserved, task NOT parked). This is the core DIVE-1453 fix. --
seed_task DIVE-201
cmd_task_need DIVE-201 --type=approval --ask="cast ada/rex?" >/dev/null 2>&1
[[ "$(gateopen DIVE-201)" == "open" ]] || bad_t "T1 precond gate open" "got $(gateopen DIVE-201)"
out=$(cmd_task_park DIVE-201 --reason="hold" --wake=+7d 2>&1); rc=$?
[[ $rc -ne 0 ]] \
  && ok_t "T1 park over an open gate is REFUSED (non-zero exit)" \
  || bad_t "T1 park refused" "rc=$rc out=$out"
[[ "$(gateopen DIVE-201)" == "open" && "$(needtype DIVE-201)" == "approval" ]] \
  && ok_t "T1 the open gate SURVIVES the refused park (need_type intact)" \
  || bad_t "T1 gate survives" "gate=$(gateopen DIVE-201) type='$(needtype DIVE-201)'"
[[ "$(parkedof DIVE-201)" == "no" ]] \
  && ok_t "T1 task was NOT parked" \
  || bad_t "T1 not parked" "parked=$(parkedof DIVE-201)"
[[ "$out" == *"DIVE-1453"* && "$out" == *"gate"* ]] \
  && ok_t "T1 refusal carries an actionable, attributed message" \
  || bad_t "T1 actionable message" "out=$out"

# --- T2: answer the gate first, THEN park cleanly (the prescribed path). ----------
seed_task DIVE-202
cmd_task_need DIVE-202 --type=approval --ask="cast ada/rex?" >/dev/null 2>&1
cmd_task_answer DIVE-202 --value=yes --human >/dev/null 2>&1
[[ "$(gateopen DIVE-202)" == "clear" ]] || bad_t "T2 precond gate answered" "got $(gateopen DIVE-202)"
cmd_task_park DIVE-202 --reason="hold" --wake=+7d >/dev/null 2>&1
[[ "$(statusof DIVE-202)" == "blocked" && "$(parkedof DIVE-202)" == "yes" ]] \
  && ok_t "T2 park succeeds once the gate is answered" \
  || bad_t "T2 park after answer" "status=$(statusof DIVE-202) parked=$(parkedof DIVE-202)"

# --- T3: a plain task with NO gate parks normally — the guard is scoped, not a
#     blanket block on park. -------------------------------------------------------
seed_task DIVE-203
cmd_task_park DIVE-203 --reason="revisit later" --wake=+3d >/dev/null 2>&1
[[ "$(statusof DIVE-203)" == "blocked" && "$(parkedof DIVE-203)" == "yes" ]] \
  && ok_t "T3 park on an ungated task is UNCHANGED (parks)" \
  || bad_t "T3 ungated park" "status=$(statusof DIVE-203) parked=$(parkedof DIVE-203)"

echo "-----"
printf 'task_park_gate_guard_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
