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
TMP="$(mktemp -d /tmp/park-gate-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
# DIVE-1919: BIND the gate-proof paths to the isolated STATE_DIR too. tasks_db.sh
# derives them at SOURCE time (line ~1240), i.e. from the DEFAULT /var/lib/5dive,
# so re-pointing STATE_DIR afterwards is not enough — `_gate_proof_enforced` kept
# stat-ing the LIVE host file. On a control-plane box where root has flipped
# enforcement on (/var/lib/5dive/gate-proof.enforce exists) T2's `task answer
# --human` was rejected E_AUTH_REQUIRED and the harness died rc=6 mid-run; on a
# clean CI runner the file is absent, enforcement is dormant and it passed. Same
# two-line binding the sibling gate harnesses already do (gate_nonce_unit.sh,
# gate_tier2_floor_unit.sh, gate_channel_proof_unit.sh, ...).
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"
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

# DIVE-2330: src no longer reads `id -un` — it was PATH-resolved and therefore forgeable
# by the very caller it was authorizing. This harness pins identity through its own
# `id()` stub, so bridge that pin onto the two seams the resolver DOES read. The lookup
# is DYNAMIC (`$(id -un)` at call time), so re-pointing the stub mid-file keeps working.
# Production is unaffected: nothing in src consults `id` any more, and these two
# functions are defined by src itself on every real invocation.
_PIN_UID=987654
_gate_caller_uid() { printf '%s' "$_PIN_UID"; }
_gate_passwd_stream() {
  printf '%s:x:%s:%s::/nonexistent:/bin/false\n' "$(id -un)" "$_PIN_UID" "$_PIN_UID"
  printf '%s\n' "$(</etc/passwd)"
}

# DIVE-2601: ASSERT THE PIN, do not assume it. Two checks, and the first is the one
# that is easy to leave out. The stream above names the caller from `$(id -un)` at
# call time, so a LITERAL expectation is required here: derive the expectation from
# `id -un` as well and an inert stub moves BOTH sides together, which is precisely
# the failure being fixed — the assertion would agree with the host and print ok.
# Without the pin, every arm below grades WHOEVER RAN THE SUITE: green on the box
# where the host happens to match, 8 arms red on a CI runner (DIVE-2588).
_pin_expect_un="root"
_pin_who="$(id -un)"
[[ "$_pin_who" == "$_pin_expect_un" ]] \
  || { printf 'NOT OK - the fixture caller went INERT: `id -un` answered %s, this harness models %s\n' \
       "'$_pin_who'" "'$_pin_expect_un'"; exit 1; }
# ...and the pin resolved through the REAL resolver, which is what the code reads.
if [[ "$_pin_expect_un" == agent-* ]]; then _pin_want="${_pin_expect_un#agent-}"; else _pin_want=""; fi
_pin_got="$(_gate_uid_to_agent "$(_gate_caller_uid)")"
[[ "$_pin_got" == "$_pin_want" ]] \
  || { printf 'NOT OK - identity pin is inert: uid %s resolved to agent %s, expected %s\n' \
       "$_PIN_UID" "'$_pin_got'" "'${_pin_want:-<non-agent>}'"; exit 1; }


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
