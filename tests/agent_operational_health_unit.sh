#!/usr/bin/env bash
# DIVE-4032: raw process liveness must not outrank credential/output health,
# and a Codex dispatcher tmux session must not be advertised as a coding TUI.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/agent-operational-health.XXXXXX)"
AGENT_HOME_ROOT="$TMP/home"
mkdir -p "$AGENT_HOME_ROOT/agent-seat"

# Extract the exact pure/read-only helpers used by both list and info. The
# terminator is a brace on its own line; inner compact groups never match it.
extract_fn() {
  local fn="$1"
  awk -v fn="$fn" '$0 ~ "^" fn "\\(\\)" {on=1} on {print} on && $0 == "}" {exit}' src/cmd_agent.sh
}
eval "$(extract_fn _agent_startup_credential_health)"
eval "$(extract_fn _agent_operational_state)"
eval "$(extract_fn _agent_auth_display)"

PASS=0; FAIL=0
is() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "ok: $1"
  else FAIL=$((FAIL+1)); echo "FAIL: $1 (want=$3 got=$2)"; fi
}
has() {
  if [[ "$2" == *"$3"* ]]; then PASS=$((PASS+1)); echo "ok: $1"
  else FAIL=$((FAIL+1)); echo "FAIL: $1 (missing=$3 got=$2)"; fi
}

is "no persisted failure -> clear" \
  "$(_agent_startup_credential_health seat | cut -d'|' -f1)" clear
printf '%s\n' 'claude credential absent — launched DEGRADED' \
  > "$AGENT_HOME_ROOT/agent-seat/.5dive-cred-seed-failed"
is "persisted launch failure -> degraded" \
  "$(_agent_startup_credential_health seat | cut -d'|' -f1)" degraded
has "persisted reason survives to the reader" \
  "$(_agent_startup_credential_health seat)" "credential absent"

is "active process + needs_login -> degraded" \
  "$(_agent_operational_state active needs_login clear)" degraded
is "active process + degraded boot -> degraded" \
  "$(_agent_operational_state active ok degraded)" degraded
is "unmeasured auth never becomes active" \
  "$(_agent_operational_state active unknown clear)" unknown
is "survey with process + auth but no output probe says ready" \
  "$(_agent_operational_state active ok clear)" ready
is "supervisor no-output verdict vetoes active process" \
  "$(_agent_operational_state active ok clear '{"verdict":"no-output","output":"dry"}')" degraded
is "a close two days ago is recent output, not current activity" \
  "$(_agent_operational_state active ok clear '{"verdict":null,"output":"ok","daysSinceClose":2}')" unverified
is "same-day output can support active" \
  "$(_agent_operational_state active ok clear '{"verdict":null,"output":"ok","daysSinceClose":0}')" active

PAST_AUTH="$(_agent_auth_display ok 1 true)"
has "past access-token expiry names the refreshable credential" \
  "$PAST_AUTH" "refreshable credential"
has "past access-token expiry explains why auth remains ok" \
  "$PAST_AUTH" "not a login failure"
is "unrefreshable future expiry keeps the ordinary rendering" \
  "$(_agent_auth_display ok 4102444800 false)" \
  "ok · expires 2100-01-01T00:00:00Z"

# Drive cmd_tui's real dispatcher refusal. The interactive negative controls use
# a fake sudo binary so exec reaches the attach branch without touching tmux.
. src/cmd_agent_config.sh
ensure_state() { :; }
REG='{"agents":{"dash":{"type":"codex","channels":"dashboard"},"combo":{"type":"codex","channels":"telegram,dashboard"},"plain":{"type":"codex","channels":"none"},"claude":{"type":"claude","channels":"dashboard"}}}'
registry_read() { printf '%s\n' "$REG"; }
E_USAGE=2; E_NOT_FOUND=4; E_CONFLICT=5
fail() { printf 'REFUSED[%s]: %s\n' "$1" "$2" >&2; exit "$1"; }
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nprintf "ATTACH:%%s\\n" "$*"\n' > "$TMP/bin/sudo"
chmod +x "$TMP/bin/sudo"

run_tui() { ( PATH="$TMP/bin:$PATH"; cmd_tui "$1" ) 2>&1; }
for seat in dash combo; do
  rc=0; out=$(run_tui "$seat") || rc=$?
  is "$seat dispatcher refuses false TUI attach" "$rc" 5
  has "$seat refusal names no interactive Codex TUI" "$out" "no interactive Codex TUI"
  has "$seat refusal points to transport logs" "$out" "5dive agent tail $seat"
done
is "plain Codex still reaches interactive attach" "$(run_tui plain)" \
  "ATTACH:-u agent-plain tmux attach -t agent-plain"
is "Claude dashboard still reaches its native TUI" "$(run_tui claude)" \
  "ATTACH:-u agent-claude tmux attach -t agent-claude"

# Wiring guards: the two user-facing surfaces must consume, not merely define,
# the operational verdict and the documented auth command must exist verbatim.
if grep -q 'operationalState: (\$live\[.key\].operationalState' src/cmd_agent.sh; then
  PASS=$((PASS+1))
else
  echo 'FAIL: list JSON does not carry operationalState'; FAIL=$((FAIL+1))
fi
if grep -q '"state:       \\(.operationalState)' src/cmd_agent.sh; then
  PASS=$((PASS+1))
else
  echo 'FAIL: info does not lead with operationalState'; FAIL=$((FAIL+1))
fi
if grep -F 'AUTH unknown =' src/cmd_agent.sh | grep -Fq '(5dive agent auth status)'; then
  PASS=$((PASS+1))
else
  echo 'FAIL: agent-list legend still points at the nonexistent auth-status command'; FAIL=$((FAIL+1))
fi
if grep -Fq '"auth:        \($authLine)"' src/cmd_agent.sh; then
  PASS=$((PASS+1))
else
  echo 'FAIL: info human render does not consume the disambiguated auth line'; FAIL=$((FAIL+1))
fi
if grep -q 'cred_seed_failed "claude credential absent' 5dive-agent-start \
   && grep -q 'supply a credential and restart' 5dive-agent-start \
   && ! grep -q 'self-heals on next restart' 5dive-agent-start; then
  PASS=$((PASS+1))
else
  echo 'FAIL: Claude timeout does not persist an actionable degraded verdict'; FAIL=$((FAIL+1))
fi

printf 'agent_operational_health_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
