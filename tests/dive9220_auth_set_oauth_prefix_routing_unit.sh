#!/usr/bin/env bash
# DIVE-9220 — `5dive agent auth set claude --api-key=-` routes a Claude OAuth
# token to CLAUDE_CODE_OAUTH_TOKEN and anything else to ANTHROPIC_API_KEY.
#
# Claude Code 2.1.332: the OAuth token prefix "can now end in oat02- as well as
# oat01-". The routing matched the literal ^sk-ant-oat01-, so an oat02 token
# landed in ANTHROPIC_API_KEY, where Claude Code treats it as an API key and the
# sign-in fails. The arms pin every version digit pair we know of, the API-key
# fall-through, and two near-misses that must NOT be read as OAuth tokens.
#
# Nothing touches the box: a throwaway AUTH_PROFILES_DIR, root/chown/chmod
# stubbed, profile writes only (the default-connector path writes /etc).
#
#   bash tests/dive9220_auth_set_oauth_prefix_routing_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/dive9220-routing.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/models.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh lib/actor.sh \
         cmd_agent_create.sh cmd_auth.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"; AUTH_PROFILES_DIR="$TMP/auth-profiles"; JSON_MODE=0
mkdir -p "$AUTH_PROFILES_DIR"

require_root()  { :; }
chown()         { :; }
chmod()         { :; }
systemctl()     { :; }
registry_read() { printf '{"agents":{}}'; }
step()          { :; }
warn()          { :; }
audit_log()     { :; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# Fixture shapes only, never real credentials.
BODY='fixture-not-a-real-token-9220'
n=0
# routes <key> <expected var> <label>
routes() {
  local key="$1" want="$2" label="$3" prof env rc
  n=$((n+1)); prof="p$n"
  rc=$( ( printf '%s' "$key" | cmd_auth_set claude --auth-profile="$prof" --api-key=- ) \
          >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?")
  env="$(cat "$AUTH_PROFILES_DIR/$prof/combined.env" 2>/dev/null)"
  if [[ "$rc" == 0 && "$env" == *"${want}=${key}"* ]]; then
    ok_t "$label -> $want"
  else
    bad_t "$label -> $want" "rc=$rc env: ${env:-<none>} err: $(head -2 "$TMP/err")"
  fi
}

routes "sk-ant-oat01-$BODY" CLAUDE_CODE_OAUTH_TOKEN "oat01 OAuth token (unchanged behaviour)"
routes "sk-ant-oat02-$BODY" CLAUDE_CODE_OAUTH_TOKEN "oat02 OAuth token (Claude Code 2.1.332)"
routes "sk-ant-oat09-$BODY" CLAUDE_CODE_OAUTH_TOKEN "a future oatNN version digit"
routes "sk-ant-api03-$BODY" ANTHROPIC_API_KEY       "an Anthropic API key"
routes "sk-ant-oatXY-$BODY" ANTHROPIC_API_KEY       "near-miss oatXY- (not digits)"
routes "sk-ant-oat2-$BODY"  ANTHROPIC_API_KEY       "near-miss oat2- (one digit)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 && PASS == 6 ))
