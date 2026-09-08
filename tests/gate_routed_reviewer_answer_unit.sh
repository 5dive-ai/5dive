#!/usr/bin/env bash
# DIVE-4081: a routed standard-seat reviewer must be able to run the ordinary
# `5dive task answer` command and leave a SIGNED, closed tier-1 approval gate.
#
# This is the missing joined-up arm. DIVE-3160 separately tested the narrow
# root executor and the create-time sudoers renderer, but an existing seat kept
# the older managed drop-in forever. Both halves were green while the live row
# deadlocked. This harness starts with that old-box state, runs the upgrade
# reconciliation, then drives the public answer entry point through the exact
# grant the migrated policy contains and inspects the persisted closure.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED\n' >&2
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/gate-routed-reviewer.XXXXXX)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
export STATE_DIR="$TMP/state" TASKS_DIR="$TMP/tasks" TASKS_DB="$TMP/tasks/tasks.db"
export REGISTRY="$STATE_DIR/agents.json" GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
export AUDIT_LOG_FILE="$TMP/audit.jsonl" SUDOERS_D="$TMP/sudoers.d"
mkdir -p "$STATE_DIR" "$TASKS_DIR" "$SUDOERS_D"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
# shellcheck source=/dev/null
source src/cmd_agent_create.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad_t() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}" >&2; }
is()    { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$3], got [$2]"; }

# The registry label is part of the acceptance point: quinn is a standard,
# non-admin seat. The task is maker=dev and routed_reviewer=quinn, so the
# self-clear guard must admit the reviewer and would refuse the maker.
cat >"$REGISTRY" <<'JSON'
{"agents":{"dev":{"type":"claude","isolation":"admin"},"quinn":{"type":"claude","isolation":"standard"}}}
JSON
tasks_db_init
db "INSERT INTO tasks(ident,title,status,created_by,assignee,maker_agent,need_type,ask,recommend,tier,routed_reviewer,gate_filed_by,need_asked_at)
    VALUES('DIVE-4081','routed approval','blocked','dev','dev','dev','approval','approve delegated push for review','approved',1,'quinn','dev',datetime('now'));"

echo '== upgrade reconciles the existing standard-seat grant =='
# Model a clean managed policy written before _task_answer existed. Keep BOTH
# conditional capabilities so the migration has something dangerous to lose if
# it reconstructs policy from a label instead of preserving the enforced file.
render_standard_sudoers agent-quinn 1 1 >"$SUDOERS_D/agent-quinn"
sed -i '/\/usr\/local\/bin\/5dive _task_answer$/d' "$SUDOERS_D/agent-quinn"
is 'precondition: old policy is still cli-scoped' \
   "$(agent_sudo_grant agent-quinn)" 'cli-scoped|root|0'
is 'filing-time detector sees the stale seat cannot produce a signed answer' \
   "$(_gate_seat_can_sign quinn)" 'no|cli-scoped'
grep -q '/usr/local/bin/5dive _task_answer$' "$SUDOERS_D/agent-quinn" \
  && bad_t 'precondition: old policy lacks _task_answer' 'grant unexpectedly present' \
  || ok_t 'precondition: old policy lacks _task_answer'

# Fixture writer: production's writer performs the same render after a visudo
# check and atomic move; this seam confines the unit to its temp directory.
write_standard_sudoers() {
  render_standard_sudoers "$1" "${2:-0}" "${3:-0}" >"$SUDOERS_D/$1"
}
state=$(_reconcile_standard_sudoers_one agent-quinn)
is 'managed old policy is updated' "$state" 'updated'
grep -q '/usr/local/bin/5dive _task_answer$' "$SUDOERS_D/agent-quinn" \
  && ok_t 'migration installs the narrow signed-answer grant' \
  || bad_t 'migration installs the narrow signed-answer grant' 'grant absent after reconciliation'
is 'filing-time detector sees the migrated seat can produce a signed answer' \
   "$(_gate_seat_can_sign quinn)" 'yes|cli-scoped'
grep -q '/usr/local/bin/5dive _push_do$' "$SUDOERS_D/agent-quinn" \
  && grep -q '/usr/local/bin/5dive _deploy_do$' "$SUDOERS_D/agent-quinn" \
  && ok_t 'migration preserves delegated push and deploy' \
  || bad_t 'migration preserves delegated push and deploy' 'a conditional capability was dropped'
is 'a second reconciliation is idempotent' \
   "$(_reconcile_standard_sudoers_one agent-quinn)" 'current'

# A managed header is not permission to erase an operator's extra grant. The
# classifier's extra bit is the boundary: if it is set, reconciliation abstains.
render_standard_sudoers agent-custom 0 0 >"$SUDOERS_D/agent-custom"
printf 'agent-custom ALL=(root) NOPASSWD: /bin/echo\n' >>"$SUDOERS_D/agent-custom"
custom_before=$(sha256sum "$SUDOERS_D/agent-custom" | awk '{print $1}')
is 'a managed policy with an extra operator grant is skipped' \
   "$(_reconcile_standard_sudoers_one agent-custom)" 'skipped'
is 'skipping a custom policy leaves its bytes untouched' \
   "$(sha256sum "$SUDOERS_D/agent-custom" | awk '{print $1}')" "$custom_before"
is 'a missing per-seat policy is skipped' \
   "$(_reconcile_standard_sudoers_one agent-missing)" 'skipped'

echo '== the routed non-admin seat runs task answer and closes SIGNED =='
# Production starts a fresh root 5dive process through sudo. The existing
# _gate_is_root seam lets this rootless unit model the outer seat and inner
# executor without changing the authorization rule: the inner identity is still
# derived from SUDO_UID and the row, never argv or --from.
REVIEWER_UID=4242
_gate_is_root() { [[ "${DIVE4081_TEST_ROOT:-0}" == '1' ]]; }
_gate_caller_uid() { if _gate_is_root; then printf '0'; else printf '%s' "$REVIEWER_UID"; fi; }
_gate_passwd_stream() { printf 'agent-quinn:x:%s:1000::/tmp:/bin/bash\n' "$REVIEWER_UID"; }
_gate_uid_to_agent() {
  case "${1:-}" in "$REVIEWER_UID") printf 'quinn' ;; *) printf '' ;; esac
}
printf '%064x\n' 1 >"$GATE_PROOF_KEY"

# Avoid external notifications; the gate row and signed closure are the
# acceptance artifact. The sudo function implements exactly the two probes and
# one invocation the real caller performs, admitting _task_answer only because
# the reconciled policy now contains its exact grant.
cmd_send() { return 0; }
_run_json_str() { printf '""'; }
_run_event_for_task() { return 0; }
sudo() {
  if [[ "${1:-}" == '-n' && "${2:-}" == '-l' ]]; then
    case "${*: -1}" in
      sign) return 1 ;;
      _task_answer) grep -q '/usr/local/bin/5dive _task_answer$' "$SUDOERS_D/agent-quinn" ; return ;;
    esac
    return 1
  fi
  if [[ "${1:-}" == '-n' && "${2:-}" == '/usr/local/bin/5dive' && "${3:-}" == '_task_answer' ]]; then
    DIVE4081_TEST_ROOT=1 SUDO_UID="$REVIEWER_UID" cmd_task_answer_delegated
    return $?
  fi
  return 1
}

PUBLIC_CMD=$(_gate_routed_answer_command DIVE-4081 approved)
is 'need.sh remedy renders the command this arm runs' \
   "$PUBLIC_CMD" '5dive task answer DIVE-4081 --value=approved'
remedy_out=$(_gate_warn_unsigned_routed_reviewer DIVE-4081 quinn cli-scoped approved 2>&1)
grep -Fq '    5dive task answer DIVE-4081 --value=approved' <<<"$remedy_out" \
  && ok_t 'need.sh prints exactly the public command this arm runs' \
  || bad_t 'need.sh prints exactly the public command this arm runs' "$remedy_out"
answer_out=$(cmd_task_answer DIVE-4081 --value=approved 2>&1); answer_rc=$?
is 'public task answer exits successfully' "$answer_rc" '0'
is 'the approval value lands' \
   "$(db "SELECT COALESCE(need_answer,'') FROM tasks WHERE ident='DIVE-4081';")" 'approved'
[[ -n "$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE ident='DIVE-4081';")" ]] \
  && ok_t 'the routed gate is closed' \
  || bad_t 'the routed gate is closed' "$answer_out"
is 'the answer is attributed to the routed reviewer' \
   "$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='DIVE-4081';")" 'lead:quinn'
[[ -n "$(db "SELECT COALESCE(need_answer_sig,'') FROM tasks WHERE ident='DIVE-4081';")" ]] \
  && ok_t 'the routed answer carries a closure signature' \
  || bad_t 'the routed answer carries a closure signature' "$answer_out"
is 'answering releases the blocked row' \
   "$(db "SELECT status FROM tasks WHERE ident='DIVE-4081';")" 'todo'

# If reconciliation could not run, the fallback still lands unsigned by design.
# Its answer-time remedy must not revive the original, refused agent->root advice.
db "INSERT INTO tasks(ident,title,status,created_by,assignee,maker_agent,need_type,ask,recommend,tier,routed_reviewer,gate_filed_by,need_asked_at)
    VALUES('DIVE-4082','routed approval fallback','blocked','dev','dev','dev','approval','approve code review','approved',1,'quinn','dev',datetime('now'));"
sed -i '/\/usr\/local\/bin\/5dive _task_answer$/d' "$SUDOERS_D/agent-quinn"
fallback_out=$(cmd_task_answer DIVE-4082 --value=approved 2>&1); fallback_rc=$?
is 'an unreconciled fallback still lands without changing answer semantics' "$fallback_rc" '0'
grep -Fq '5dive task answer DIVE-4082 --value=approved' <<<"$fallback_out" \
  && ok_t 'answer-time fallback names the routed reviewer command after re-filing' \
  || bad_t 'answer-time fallback names the routed reviewer command after re-filing' "$fallback_out"
if grep -Fq 'sudo 5dive task answer DIVE-4082' <<<"$fallback_out"; then
  bad_t 'answer-time fallback does not prescribe refused agent-to-root sudo' "$fallback_out"
else
  ok_t 'answer-time fallback does not prescribe refused agent-to-root sudo'
fi

# Drive the installer-facing command, not only its one-seat helper. Root itself
# is an orthogonal dispatch guard; this seam lets the unit assert registry
# filtering and the summary without mutating the host's real sudoers.
require_root() { return 0; }
reconcile_out=$(JSON_MODE=1 cmd_agent_reconcile_sudoers)
is 'installer-facing reconciliation updates the registry standard seat' \
   "$(jq -r '.data.updated' <<<"$reconcile_out")" '1'
is 'installer-facing reconciliation ignores the registry admin seat' \
   "$(jq -r '.data.skipped' <<<"$reconcile_out")" '0'
[[ ! -e "$SUDOERS_D/agent-dev" ]] \
  && ok_t 'registry filtering never creates or rewrites an admin policy' \
  || bad_t 'registry filtering never creates or rewrites an admin policy' 'agent-dev policy appeared'

# Source-to-installer tripwire: a renderer-only fix recreates the live defect on
# every pre-existing seat. The upgrade path must invoke the reconciler after the
# new bundle is atomically installed.
grep -q '"\$BIN_DIR/5dive" agent _reconcile_sudoers' install.sh \
  && ok_t 'install and upgrade invoke the standard-seat reconciler' \
  || bad_t 'install and upgrade invoke the standard-seat reconciler' 'call missing from refresh_managed_files'
grep -Fq 'answer_cmd=$(_gate_routed_answer_command "$ident" "$value")' src/task/need.sh \
  && ok_t 'need.sh prints the single-sourced routed-reviewer command' \
  || bad_t 'need.sh prints the single-sourced routed-reviewer command' 'warning bypasses the command renderer'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
