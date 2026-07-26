#!/usr/bin/env bash
# DIVE-2112 isolated unit harness for `task reject`'s actor + already-done guards.
#
# Found by olivia while VERIFYING DIVE-2067, whose refusal text pointed makers at
# this very verb. Measured on a fixture: `FIVE_SENDER=dev2 cmd_task_reject` on a
# task that was done, verified by olivia, returned rc=0 — it reopened the task,
# replaced the verifier's ACK, and filed the reopen as "verifier 'olivia'
# rejected" because the string hard-coded the RECORDED verifier rather than the
# actual actor. Destroying a record is bad; manufacturing a false one is worse.
#
# The guard is scoped, NOT symmetric: a lead bouncing an OPEN task is legitimate
# and case F asserts it still works. Only the two cases with nothing to escape
# from are refused. Case E is the byte-identical constraint — a healthy reject
# must not grow a superseded marker.
# Run: bash tests/task_reject_actor_and_closed_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/task-reject-actor-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/disk.sh lib/tasks_db.sh cmd_task.sh cmd_push.sh cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1; mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
as() { local who="$1"; shift; ( USER="agent-${who}"; SUDO_UID=""; SUDO_USER=""; "$@" ) 2>"$TMP"/err; }
actor_is() { ( USER="agent-$1"; SUDO_UID=""; SUDO_USER=""; task_actor ); }

[[ "$(actor_is dev)" == "dev" ]] && ok_t "harness can impersonate an actor (task_actor -> dev)" \
  || bad_t "actor impersonation" "got '$(actor_is dev)' — every case below would be vacuous"

res_of()    { db "SELECT COALESCE(result,'') FROM tasks WHERE ident=$(sqlq "$1");"; }
status_of() { db "SELECT status FROM tasks WHERE ident=$(sqlq "$1");"; }
refusals()  { db "SELECT COUNT(*) FROM policy_refusals WHERE policy=$(sqlq "$2") AND ident=$(sqlq "$1");"; }

# seed -> a DELIVERED loop task: maker=dev, verifier=main, assignee=main, todo.
seed() {
  local out id; out=$(JSON_MODE=1 cmd_task_add "$1" --assignee=dev --verifier=main \
                        --accept="must do the thing" 2>"$TMP"/err)
  id=$(printf '%s' "$out" | jq -r '.data.ident // empty' 2>/dev/null)
  as dev cmd_task_done "$id" --result="maker delivery v1" >/dev/null
  printf '%s' "$id"
}
# seed_closed -> the above, then the VERIFIER grades it done with a real ACK.
ACK="verified PASS — caveat: the seal only grades the bundle, not that src produces it"
seed_closed() { local id; id=$(seed "$1"); as main cmd_task_done "$id" --result="$ACK" >/dev/null; printf '%s' "$id"; }

# --- A: the MAKER may not reject its own delivery (writer grading own work).
A=$(seed "A maker rejects own delivery")
out=$(as dev cmd_task_reject "$A" --feedback="I changed my mind"); rc=$?
(( rc != 0 )) && ok_t "A maker's reject exits non-zero (rc=$rc)" || bad_t "A should refuse" "rc=$rc $out"
[[ "$(res_of "$A")" == "maker delivery v1" ]] \
  && ok_t "A delivered result untouched by the refused reject" || bad_t "A result mutated" "$(res_of "$A")"
[[ "$(refusals "$A" reject-by-maker)" == "1" ]] \
  && ok_t "A refusal audited to policy_refusals" || bad_t "A not audited" "no reject-by-maker row"
grep -qi "MAKER" "$TMP"/err && ok_t "A refusal explains the maker/verifier split" \
  || bad_t "A message" "$(cat "$TMP"/err)"

# --- B: THE MEASURED BUG — a non-verifier rejecting an already-DONE task.
B=$(seed_closed "B outsider reopens a graded task")
[[ "$(status_of "$B")" == "done" && "$(res_of "$B")" == "$ACK" ]] \
  || bad_t "B fixture" "expected a closed, graded task; got $(status_of "$B")"
out=$(as dev2 cmd_task_reject "$B" --feedback="please add X"); rc=$?
(( rc != 0 )) && ok_t "B outsider's reject over a closed task exits non-zero (rc=$rc)" \
  || bad_t "B should refuse" "rc=$rc — this is olivia's exact repro"
[[ "$(status_of "$B")" == "done" ]] \
  && ok_t "B task stays DONE — the reopen is blocked" || bad_t "B reopened" "status=$(status_of "$B")"
[[ "$(res_of "$B")" == "$ACK" ]] \
  && ok_t "B the verifier's ACK survives intact" || bad_t "B ACK destroyed" "result=$(res_of "$B")"
[[ "$(refusals "$B" reject-over-closed)" == "1" ]] \
  && ok_t "B refusal audited to policy_refusals" || bad_t "B not audited" "no reject-over-closed row"

# --- C: FALSE ATTRIBUTION — the reject must name the ACTUAL actor.
C=$(seed "C attribution names the real actor")
as main cmd_task_reject "C-nonexistent" --feedback=x >/dev/null 2>&1  # noise, ignored
out=$(as main cmd_task_reject "$C" --feedback="needs a test"); rc=$?
(( rc == 0 )) && ok_t "C the verifier's own reject still works (rc=0)" \
  || bad_t "C verifier reject broken" "rc=$rc $(cat "$TMP"/err)"
[[ "$(res_of "$C")" == *"main rejected"* ]] \
  && ok_t "C result attributes the reject to the actor who ran it" \
  || bad_t "C attribution" "result=$(res_of "$C")"
[[ "$(res_of "$C")" != *"verifier 'main' rejected"* ]] \
  && ok_t "C the hard-coded \"verifier '<recorded>' rejected\" string is gone" \
  || bad_t "C still hard-coded" "a non-verifier reject would be filed under the verifier's name"

# --- D: the VERIFIER reopening their OWN grade preserves the prior record.
D=$(seed_closed "D verifier reopens own grade")
out=$(as main cmd_task_reject "$D" --feedback="I was wrong, reopening"); rc=$?
(( rc == 0 )) && ok_t "D the grader may reopen their own grade (rc=0)" \
  || bad_t "D grader locked out" "rc=$rc $(cat "$TMP"/err)"
[[ "$(res_of "$D")" == *"superseded result (DIVE-2067, preserved)"* ]] \
  && ok_t "D prior result preserved under a superseded marker" || bad_t "D marker missing" "$(res_of "$D")"
[[ "$(res_of "$D")" == *"the seal only grades the bundle"* ]] \
  && ok_t "D the ACK's actual TEXT survives, not just a marker" || bad_t "D ACK text lost" "$(res_of "$D")"

# --- E: byte-identical constraint — a healthy reject grows NO marker.
[[ "$(res_of "$C")" != *"superseded"* ]] \
  && ok_t "E a reject on an OPEN task emits no superseded marker" \
  || bad_t "E marker leaked onto the healthy path" "$(res_of "$C")"

# --- F: NOT over-tightened — a lead bouncing an OPEN task still works.
F=$(seed "F lead bounces an open delivered task")
out=$(as olivia cmd_task_reject "$F" --feedback="scope is wrong"); rc=$?
(( rc == 0 )) && ok_t "F a non-maker non-verifier may still bounce an OPEN task" \
  || bad_t "F over-tightened" "rc=$rc — the guard broke a legitimate flow: $(cat "$TMP"/err)"
[[ "$(res_of "$F")" == *"olivia rejected"* ]] \
  && ok_t "F that bounce is attributed to olivia, not to verifier 'main'" \
  || bad_t "F attribution" "result=$(res_of "$F")"

# --- G: the max_iterations ESCALATION branch is the SECOND write site olivia named.
# It has its own `UPDATE tasks SET result=` and would carry the same false
# attribution independently; assert it consumes the fixed string, not by reading.
Gid=$(JSON_MODE=1 cmd_task_add "G max-iters escalation" --assignee=dev --verifier=main \
        --accept=x --max-iters=1 2>"$TMP"/err | jq -r '.data.ident // empty')
as dev cmd_task_done "$Gid" --result="maker delivery v1" >/dev/null
out=$(as main cmd_task_reject "$Gid" --feedback="not good enough"); rc=$?
[[ "$(db "SELECT COALESCE(max_iterations,0) FROM tasks WHERE ident=$(sqlq "$Gid");")" == "1" \
   && "$(db "SELECT COALESCE(iteration,0) FROM tasks WHERE ident=$(sqlq "$Gid");")" -ge 1 ]] \
  && ok_t "G fixture really is on the max_iterations branch (maxi=1, iter>=1)" \
  || bad_t "G fixture" "not on the escalation path — the next assertion would be vacuous"
[[ "$(res_of "$Gid")" == *"main rejected"* ]] \
  && ok_t "G escalation branch attributes to the real actor too" \
  || bad_t "G escalation attribution" "result=$(res_of "$Gid")"
[[ "$(res_of "$Gid")" != *"verifier 'main' rejected"* ]] \
  && ok_t "G escalation branch is not hard-coded either" || bad_t "G escalation hard-coded" "$(res_of "$Gid")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
