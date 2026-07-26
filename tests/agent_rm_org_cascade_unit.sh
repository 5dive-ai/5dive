#!/usr/bin/env bash
# DIVE-1609 isolated unit for `5dive agent rm` org-chart cascade. No root, no
# systemd, no network — stubs the heavyweight teardown (user deletion, channel
# secrets, systemctl) and drives cmd_rm against a temp registry + temp tasks db.
# Asserts that removing an agent:
#   - drops it from the registry (agents.json)
#   - drops its agents_org row (the DIVE-1609 cascade — used to leak)
#   - reparents its direct reports via ON DELETE SET NULL (no orphan pointer)
#   - clears the failed templated unit (systemctl reset-failed <unit>)
# Run: bash tests/agent_rm_org_cascade_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/agent-rm-cascade-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/registry.sh lib/tasks_db.sh cmd_org.sh \
         cmd_agent_lifecycle.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
ENV_DIR="$TMP/env"
REGISTRY="$TMP/registry.json"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$ENV_DIR" "$TASKS_DIR"
set +e

# --- test seams: neuter root-only / host-only teardown -----------------------
ensure_state() { :; }                              # no require_root / chown
registry_write() { cat > "$REGISTRY"; }            # plain file, no chown
remove_channel_secret() { :; }
delete_agent_user() { :; }
paperclip_unseed_for_profile() { :; }
# record systemctl invocations so we can assert reset-failed ran
SYSCTL_LOG="$TMP/systemctl.log"
: > "$SYSCTL_LOG"
systemctl() { printf '%s\n' "$*" >> "$SYSCTL_LOG"; return 0; }

tasks_db_init

# Seed registry with two agents (agy reports up to creative).
cat > "$REGISTRY" <<'JSON'
{"schemaVersion":2,"agents":{"agy":{"type":"claude"},"creative":{"type":"claude"},"kidreports":{"type":"claude"}}}
JSON
# Seed org chart: creative at top, agy + kidreports report to agy.
db "INSERT OR IGNORE INTO agents_org (name) VALUES ('creative'),('agy'),('kidreports');"
db "UPDATE agents_org SET reports_to='creative' WHERE name='agy';"
db "UPDATE agents_org SET reports_to='agy' WHERE name='kidreports';"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- exercise ----------------------------------------------------------------
cmd_rm agy >/dev/null 2>"$TMP/err"

# 1. gone from registry
gone_reg=$(jq -r '.agents.agy // "ABSENT"' "$REGISTRY")
[[ "$gone_reg" == "ABSENT" ]] \
  && ok_t "agent rm drops the registry entry" \
  || bad_t "registry entry survived" "got: $gone_reg :: $(cat "$TMP/err")"

# 2. gone from agents_org (the DIVE-1609 cascade)
gone_org=$(db "SELECT COUNT(*) FROM agents_org WHERE name='agy';")
[[ "$gone_org" == "0" ]] \
  && ok_t "agent rm cascades the agents_org row" \
  || bad_t "agents_org row orphaned" "count=$gone_org"

# 3. direct report reparented (reports_to -> NULL), not left dangling at 'agy'
child_mgr=$(db "SELECT COALESCE(reports_to,'(top)') FROM agents_org WHERE name='kidreports';")
[[ "$child_mgr" == "(top)" ]] \
  && ok_t "ON DELETE SET NULL reparents the removed agent's reports" \
  || bad_t "child still points at removed manager" "reports_to=$child_mgr"

# 4. failed unit cleared
grep -q "reset-failed 5dive-agent@agy.service" "$SYSCTL_LOG" \
  && ok_t "agent rm reset-failed the templated unit" \
  || bad_t "reset-failed not issued" "$(cat "$SYSCTL_LOG")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
