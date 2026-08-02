#!/usr/bin/env bash
# DIVE-2062 isolated unit harness for `5dive task need --tier=0` (DIVE-891
# auto-clear: the recommendation applies immediately, provenance 'auto:t0', no
# human ping — cmd_task_need, cmd_task.sh). Per the DIVE-2054 verifier pass
# (dev3, 2026-07-26), this command path was reached by NO suite at all — every
# other gate-tier suite exercises tier 1/2, never an explicit --tier=0. This
# closes that gap: drives the real tier-0 branch against a fixture TASKS_DB, on
# BOTH sides of the DIVE-2010/2054 store-identity fence around its
# `_task_store_audit_log "task need t0-auto"` call (cmd_task.sh ~3661) — the
# applied recommendation is itself TASKS_DB state, not an independent
# real-world fact, so it is fenced (see
# community/wiki/audit-log-store-fence-task-need-unnotified-dive2010.md).
# Run: bash tests/task_need_t0_auto_unit.sh  (no root, no network).
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
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-need-t0-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
task_need_notify() { :; }   # tier-0 skips the ping anyway; stubbed for safety

AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
jf()    { jq -r "$1" 2>/dev/null; }
seed()      { db "INSERT INTO tasks (ident,title,status,created_by,assignee) VALUES ('$1','t','todo','main','main');"; }
statusof()  { db "SELECT status FROM tasks WHERE ident='$1';"; }
answerof()  { db "SELECT COALESCE(need_answer,'') FROM tasks WHERE ident='$1';"; }
answeredby(){ db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='$1';"; }

# =============================================================================
# ON the prod store
# =============================================================================
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"

# DIVE-2235 — the class this file drives changed from approval to decision.
# Tier 0 IS an auto-answer, and class now outranks tier: approval/manual/access/
# secret are human-class and are floored to tier 1 instead of auto-clearing,
# whatever tier they were pinned to. `decision` is the one class that still
# auto-clears at tier 0 (deliberately out of the human class pending v0.18), so
# it is what keeps the DIVE-2062 coverage of this branch alive. Case 0 below
# grades the approval side, so the old behaviour is not merely deleted from the
# suite — it is asserted to have changed.
#
# 0: a human-class gate pinned to tier 0 is floored and left for a person.
seed DIVE-0
cmd_task_need DIVE-0 --type=approval --tier=0 --recommend="approved" \
  --ask="ok to proceed?" --from=dev >/dev/null 2>&1
[[ "$(db "SELECT COUNT(*) FROM tasks WHERE ident='DIVE-0';")" == "1" \
   && "$(db "SELECT COALESCE(need_type,'') FROM tasks WHERE ident='DIVE-0';")" == "approval" ]] \
  && ok_t "class-over-tier: the approval gate was filed (the negatives below read a real row)" \
  || bad_t "approval gate filed" "type=$(db "SELECT COALESCE(need_type,'∅') FROM tasks WHERE ident='DIVE-0';")"
[[ "$(db "SELECT COALESCE(tier,'∅') FROM tasks WHERE ident='DIVE-0';")" == "1" ]] \
  && ok_t "class-over-tier: approval pinned to tier 0 is floored to tier 1" \
  || bad_t "approval floored" "tier=$(db "SELECT COALESCE(tier,'∅') FROM tasks WHERE ident='DIVE-0';")"
[[ -z "$(answerof DIVE-0)" && "$(answeredby DIVE-0)" == "" && "$(statusof DIVE-0)" == "blocked" ]] \
  && ok_t "class-over-tier: approval is NOT auto-applied and stays blocked for a human" \
  || bad_t "approval must not auto-apply" "answer=$(answerof DIVE-0) by=$(answeredby DIVE-0) status=$(statusof DIVE-0)"

# 1: tier-0 with no dependents auto-applies the recommendation AND unblocks.
seed DIVE-1
out=$(cmd_task_need DIVE-1 --type=decision --tier=0 --recommend="approved" \
  --options="approved|rejected" --ask="ok to proceed?" --from=dev 2>"$TMP/err1")
[[ "$(printf '%s' "$out" | jf '.data.tier')" == "0" \
   && "$(printf '%s' "$out" | jf '.data.auto_applied')" == "approved" ]] \
  && ok_t "tier-0 gate reports auto_applied in its envelope" \
  || bad_t "envelope" "out=$out err=$(cat "$TMP/err1")"
[[ "$(answerof DIVE-1)" == "approved" && "$(answeredby DIVE-1)" == "auto:t0" ]] \
  && ok_t "the recommendation is written as need_answer, provenance auto:t0 (never human:*)" \
  || bad_t "auto-answer written" "answer=$(answerof DIVE-1) by=$(answeredby DIVE-1)"
[[ "$(statusof DIVE-1)" == "todo" ]] \
  && ok_t "with no blocking dep, the task returns straight to todo (never pings a human)" \
  || bad_t "unblocked to todo" "status=$(statusof DIVE-1)"
grep -q 'task need t0-auto.*task=DIVE-1.*type=decision.*applied=approved' "$AUDIT_CALLS" \
  && ok_t "on-store: the auto-clear is audited with the applied value" \
  || bad_t "on-store audit row" "$(cat "$AUDIT_CALLS")"

# 2: --tier=0 requires --recommend (usage guard, not the fence — quick sanity so
#    the case above isn't accidentally exercising a permissive branch).
seed DIVE-2
out=$(cmd_task_need DIVE-2 --type=decision --tier=0 --options="yes|no" --ask="ok?" --from=dev 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"--recommend is required"* ]] \
  && ok_t "tier=0 without --recommend is refused up front (nothing to auto-apply)" \
  || bad_t "tier0 needs recommend" "rc=$rc out=$out"

# 3: a tier-0 gate that STILL has an open dependency stays blocked — the answer
#    is recorded (auto-cleared), but the status flip is conditional on no
#    remaining task_deps edge, exactly like the human-cleared path.
seed DIVE-3
seed DIVE-3-BLOCKER
db "UPDATE tasks SET status='in_progress' WHERE ident='DIVE-3-BLOCKER';"
blocker_id=$(db "SELECT id FROM tasks WHERE ident='DIVE-3-BLOCKER';")
target_id=$(db "SELECT id FROM tasks WHERE ident='DIVE-3';")
db "INSERT INTO task_deps (task_id, blocked_by) VALUES (${target_id}, ${blocker_id});"
cmd_task_need DIVE-3 --type=decision --tier=0 --recommend="approved" \
  --options="approved|rejected" --ask="ok?" --from=dev >/dev/null 2>&1
[[ "$(answerof DIVE-3)" == "approved" && "$(statusof DIVE-3)" == "blocked" ]] \
  && ok_t "tier-0 auto-applies the answer even while a dependency still blocks the status flip" \
  || bad_t "dep-blocked tier0" "answer=$(answerof DIVE-3) status=$(statusof DIVE-3)"

# =============================================================================
# OFF the prod store: the audit row is withheld, and the withholding is
# announced — mirrors tests/heartbeat_gate_shipped_unit.sh Case 12's pattern
# for this cmd_task.sh site instead of a cmd_heartbeat.sh one.
# =============================================================================
: >"$AUDIT_CALLS"
unset _TASK_STORE_AUDIT_FENCED
export FIVEDIVE_PROD_TASKS_DB="$TMP/somewhere-else/tasks.db"
seed DIVE-4
cmd_task_need DIVE-4 --type=decision --tier=0 --recommend="approved" \
  --options="approved|rejected" --ask="ok?" --from=dev >/dev/null 2>"$TMP/offstore.err"
[[ "$(answerof DIVE-4)" == "approved" ]] \
  && ok_t "off-store: the auto-clear itself still applies (fail-open on the WRITE side — this is task-store state, not telemetry)" \
  || bad_t "off-store auto-clear still applies" "answer=$(answerof DIVE-4)"
[[ ! -s "$AUDIT_CALLS" ]] \
  && ok_t "off the prod store, task need t0-auto writes NO audit row" \
  || bad_t "off-store must not audit" "$(cat "$AUDIT_CALLS")"
grep -q "telemetry withheld" "$TMP/offstore.err" \
  && ok_t "the withholding is ANNOUNCED, not silent" \
  || bad_t "fence must announce" "err=$(cat "$TMP/offstore.err")"
unset _TASK_STORE_AUDIT_FENCED

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
