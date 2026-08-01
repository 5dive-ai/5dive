#!/usr/bin/env bash
# deploy_unit — INST-5: the delegated-deploy EXECUTOR (src/cmd_deploy.sh).
#
# tests/broker_surface_unit.sh grades the POLICY stage under the deploy surface
# (lib/broker.sh parameterized by `deploy`). Nothing sourced cmd_deploy.sh
# itself, so the 221-line executor — the thing INST-5 was actually filed to land
# — shipped its first iteration with no harness that loaded it. This is that
# harness. Same isolation posture as push_unit.sh: source the src/ libs, point
# STATE_DIR at a throwaway temp dir, seed the tasks store directly.
#
# Covers every NON-CREDENTIAL path. The real deploy needs root, the on-box
# Vercel token and the network, so everything here stops at --dry-run or at the
# root-only refusal; no token is read and no deployment is ever fired.
#   - usage: no task id -> refuse
#   - no deploy target (no --target, no `Deploy:` body line) -> refuse, and the
#     refusal names the body line to add rather than guessing a target
#   - a target that is not exactly <project>@<ref> -> refuse
#   - hostile project/ref/env are rejected BEFORE anything reaches a URL or a
#     JSON body (traversal, injection, leading '-', '..', unknown --env)
#   - gate states: no gate / open / rejected -> refuse; cleared -> dry-run ok
#   - B5 target binding: a --target disagreeing with the task's own `Deploy:`
#     line is refused, and a task carrying only a `Branch:` line cannot
#     authorize a deploy at all (a push gate is not a deploy gate)
#   - _deploy_do is root-only, graded against a STUBBED uid so the arm tests the
#     code rather than whichever user the runner happens to be
#   - INST-5 fail-closed: a missing broker predicate refuses instead of
#     proceeding (the shape CI caught on this branch)
# Run: bash tests/deploy_unit.sh  (no root, no network, no credential)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/deploy-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh cmd_task.sh cmd_deploy.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"
JSON_MODE=0
# Hermetic: point the connector at an absent path so nothing here can read the
# box's real /etc/5dive/connectors/vercel.env. Every arm stops before the
# credential anyway; this makes that a property of the harness, not a hope.
export VERCEL_ENV_FILE="$TMP/no-vercel-env"
mkdir -p "$TASKS_DIR"
printf '%064d\n' 1496 > "$GATE_PROOF_KEY"
set +e

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# seed_task <ident> <body> <need_type> <need_answered_at> <need_answer>
#           [answered_by] [routed_reviewer] [sign=1]
seed_task() {
  local answered_by="${6:-human:test}" reviewer="${7:-}" sign="${8:-1}" id sig
  db "INSERT INTO tasks(ident,project_key,title,status,assignee,kind,body,
         need_type,need_answered_at,need_answer,need_answered_by,
         need_answered_uid,routed_reviewer)
      VALUES($(sqlq "$1"),'dive',$(sqlq "t-$1"),'in_progress','dev','standard',
             $(sqlq "$2"),$(sqlq_or_null "$3"),$(sqlq_or_null "$4"),
             $(sqlq_or_null "$5"),$(sqlq_or_null "$answered_by"),1000,
             $(sqlq_or_null "$reviewer"));"
  if [[ -n "$4" && "$sign" == "1" ]]; then
    id=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$1");")
    sig=$(_gate_closure_sign "$id" "$3" "$5" "$answered_by" "$4" 1000)
    db "UPDATE tasks SET need_answer_sig=$(sqlq "$sig") WHERE id=${id};"
  fi
}

run_deploy() { ( cmd_deploy "$@" ) 2>&1; }

CLEARED="2026-08-01 00:00:00"

# --- 1) usage -------------------------------------------------------------
out=$(run_deploy); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "usage: 5dive deploy" <<<"$out"; } \
  && ok_t "no task id -> usage refusal" || bad_t "no task id -> usage refusal" "rc=$rc :: $out"

# --- 2) no declared target ------------------------------------------------
# The executor must refuse to GUESS. A task with no `Deploy:` line and no
# --target names nothing deployable, and "deploy something reasonable" is
# exactly the inference a broker exists to delete.
seed_task DIVE-801 "no target here" approval "$CLEARED" "yes ship it"
out=$(run_deploy DIVE-801 --dry-run); rc=$?
{ [[ $rc -ne 0 ]] && grep -q "Deploy: <project>@<ref>" <<<"$out"; } \
  && ok_t "no deploy target -> refuse, naming the body line to add" \
  || bad_t "no deploy target -> refuse, naming the body line to add" "rc=$rc :: $out"

# A task carrying ONLY a `Branch:` line is a PUSH task. Its cleared gate must not
# authorize a deploy — the two surfaces read different body keys on purpose.
seed_task DIVE-802 "Branch: feature-ok" approval "$CLEARED" "yes ship it"
out=$(run_deploy DIVE-802 --dry-run); rc=$?
{ [[ $rc -ne 0 ]] && ! grep -qi "would deploy" <<<"$out"; } \
  && ok_t "a Branch:-only (push) task cannot authorize a deploy" \
  || bad_t "a Branch:-only (push) task cannot authorize a deploy" "rc=$rc :: $out"

# --- 3) target SHAPE ------------------------------------------------------
seed_task DIVE-803 "Deploy: notapair" approval "$CLEARED" "yes ship it"
out=$(run_deploy DIVE-803 --dry-run); rc=$?
{ [[ $rc -ne 0 ]] && grep -q "must be exactly" <<<"$out"; } \
  && ok_t "a target that is not <project>@<ref> -> refuse" \
  || bad_t "a target that is not <project>@<ref> -> refuse" "rc=$rc :: $out"

# Two '@' is ambiguous, not "close enough" — _deploy_split_target returns empty.
[[ -z "$(_deploy_split_target 'a@b@c')" ]] \
  && ok_t "a two-'@' target is ambiguous -> empty split" \
  || bad_t "a two-'@' target is ambiguous -> empty split" "got '$(_deploy_split_target 'a@b@c')'"
[[ "$(_deploy_split_target 'app@feat/x')" == "app feat/x" ]] \
  && ok_t "non-vacuity: a well-formed target still splits" \
  || bad_t "non-vacuity: a well-formed target still splits" "got '$(_deploy_split_target 'app@feat/x')'"

# --- 4) hostile inputs, rejected BEFORE they reach a URL or a JSON body ----
# project, ref and env are all attacker-controlled in the threat model this
# broker exists for: a granted agent supplies them. Each is graded on its own so
# a single over-broad regex cannot make the others vacuous.
for bad in '../etc/passwd' '-rf' 'a b' 'x;rm -rf /' '.leading' '$(id)'; do
  ( _deploy_validate_target "$bad" main production ) >/dev/null 2>&1
  [[ $? -ne 0 ]] && ok_t "hostile project '$bad' -> refused" \
                 || bad_t "hostile project '$bad' -> refused" "accepted"
done
for bad in '-delete' 'a..b' 'x;y' 'a b' '$(id)'; do
  ( _deploy_validate_target app "$bad" production ) >/dev/null 2>&1
  [[ $? -ne 0 ]] && ok_t "hostile ref '$bad' -> refused" \
                 || bad_t "hostile ref '$bad' -> refused" "accepted"
done
( _deploy_validate_target app main staging ) >/dev/null 2>&1
[[ $? -ne 0 ]] && ok_t "an unknown --env -> refused (production|preview only)" \
               || bad_t "an unknown --env -> refused" "accepted 'staging'"
# Non-vacuity: the validator is not simply refusing everything.
( _deploy_validate_target my-app feat/a-1 production ) >/dev/null 2>&1
[[ $? -eq 0 ]] && ok_t "non-vacuity: a legitimate project/ref/env passes" \
               || bad_t "non-vacuity: a legitimate project/ref/env passes" "refused a valid triple"
( _deploy_validate_target app main preview ) >/dev/null 2>&1
[[ $? -eq 0 ]] && ok_t "non-vacuity: --env=preview is accepted" \
               || bad_t "non-vacuity: --env=preview is accepted" "refused preview"

# --- 5) gate states -------------------------------------------------------
seed_task DIVE-804 "Deploy: app@feat/a" "" "" ""
out=$(run_deploy DIVE-804 --dry-run); rc=$?
{ [[ $rc -ne 0 ]] && ! grep -qi "would deploy" <<<"$out"; } \
  && ok_t "no gate -> refuse" || bad_t "no gate -> refuse" "rc=$rc :: $out"

seed_task DIVE-805 "Deploy: app@feat/a" approval "" ""
out=$(run_deploy DIVE-805 --dry-run); rc=$?
{ [[ $rc -ne 0 ]] && ! grep -qi "would deploy" <<<"$out"; } \
  && ok_t "open (unanswered) gate -> refuse" || bad_t "open (unanswered) gate -> refuse" "rc=$rc :: $out"

seed_task DIVE-806 "Deploy: app@feat/a" approval "$CLEARED" "no, do not ship"
out=$(run_deploy DIVE-806 --dry-run); rc=$?
{ [[ $rc -ne 0 ]] && ! grep -qi "would deploy" <<<"$out"; } \
  && ok_t "rejected gate -> refuse" || bad_t "rejected gate -> refuse" "rc=$rc :: $out"

# --- 6) happy dry-run (the liveness anchor for every negative above) -------
seed_task DIVE-807 "Deploy: app@feat/a" approval "$CLEARED" "yes ship it"
out=$(run_deploy DIVE-807 --dry-run); rc=$?
{ [[ $rc -eq 0 ]] && grep -qi "would deploy app@feat/a" <<<"$out"; } \
  && ok_t "cleared gate + declared target -> dry-run ok" \
  || bad_t "cleared gate + declared target -> dry-run ok" "rc=$rc :: $out"
grep -q "production" <<<"$out" \
  && ok_t "…and it defaults to the production env" \
  || bad_t "…and it defaults to the production env" "$out"

# --- 7) B5 target binding -------------------------------------------------
# The cleared gate authorizes exactly the target the TASK declares, read fresh
# from the DB. A --target that disagrees is refused, so a granted agent cannot
# cite one task's cleared gate to ship a different project or a different ref.
out=$(run_deploy DIVE-807 --target=other@feat/a --dry-run); rc=$?
{ [[ $rc -ne 0 ]] && ! grep -qi "would deploy" <<<"$out"; } \
  && ok_t "a --target naming a DIFFERENT project -> refuse" \
  || bad_t "a --target naming a DIFFERENT project -> refuse" "rc=$rc :: $out"
out=$(run_deploy DIVE-807 --target=app@other-ref --dry-run); rc=$?
{ [[ $rc -ne 0 ]] && ! grep -qi "would deploy" <<<"$out"; } \
  && ok_t "a --target naming a DIFFERENT ref -> refuse" \
  || bad_t "a --target naming a DIFFERENT ref -> refuse" "rc=$rc :: $out"
# Non-vacuity: --target is not simply always refused.
out=$(run_deploy DIVE-807 --target=app@feat/a --dry-run); rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "non-vacuity: a --target AGREEING with the task passes" \
  || bad_t "non-vacuity: a --target AGREEING with the task passes" "rc=$rc :: $out"

# --- 8) _deploy_do is root-only -------------------------------------------
# STUB the uid the code READS. An unstubbed `id -u` grades the RUNNER, not the
# code: red under our `sudo -u claude` convention and green in a root container,
# so both readings would be "true" and neither would be about cmd_deploy.sh.
id() { if [[ "${1:-}" == "-u" ]]; then printf '%s' "$FAKE_UID"; else command id "$@"; fi; }
FAKE_UID=1000
out=$( printf 'DIVE-807\napp\nfeat/a\nproduction\n' | cmd_deploy_do 2>&1 ); rc=$?
{ [[ $rc -ne 0 ]] && grep -q "root-only" <<<"$out"; } \
  && ok_t "_deploy_do as non-root -> refuse (stubbed uid 1000)" \
  || bad_t "_deploy_do as non-root -> refuse" "rc=$rc :: $out"
# Differential: as uid 0 the SAME call gets past the root check. It must not
# succeed — there is no credential here — but it must fail for a LATER reason,
# which is what proves the arm above graded the root check and not some
# unrelated refusal that would fire either way.
FAKE_UID=0
out=$( printf 'DIVE-807\napp\nfeat/a\nproduction\n' | cmd_deploy_do 2>&1 ); rc=$?
{ [[ $rc -ne 0 ]] && ! grep -q "root-only" <<<"$out"; } \
  && ok_t "…and as uid 0 it passes the root check and fails LATER (arm is differential)" \
  || bad_t "…and as uid 0 it passes the root check and fails later" "rc=$rc :: $out"
# The credential is absent, so the failure must be the connector — never a
# silent success, and never a token read from the real box.
grep -qiE "vercel|connector" <<<"$out" \
  && ok_t "…and the later failure is the absent Vercel connector, not a silent pass" \
  || bad_t "…and the later failure is the absent Vercel connector" "$out"
FAKE_UID=1000
unset -f id

# --- 9) INST-5 fail-closed on a missing predicate -------------------------
# The shape CI caught on this branch: an extracted predicate that is not loaded
# is merely "command not found", and a bare call site reads that as success. The
# control is arm 6 above — same fixture, same command, one predicate removed.
for _pred in broker_gate_check broker_bind_target; do
  out=$( unset -f "$_pred"; cmd_deploy DIVE-807 --dry-run 2>&1 ); rc=$?
  { [[ $rc -ne 0 ]] && ! grep -qi "would deploy" <<<"$out"; } \
    && ok_t "missing $_pred -> refuses, and no deploy is reported" \
    || bad_t "missing $_pred -> refuses, and no deploy is reported" "rc=$rc :: $out"
done
unset _pred

echo "-----"
printf 'deploy_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
