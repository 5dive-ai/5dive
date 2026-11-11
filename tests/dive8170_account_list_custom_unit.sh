#!/usr/bin/env bash
# DIVE-8170: `account list --json` names an account's «Your own AI» record as
# `custom: {harness, model, host}`, so the partner API can show a client's own
# model as «<model> · <host>» (5dive-api partner-ai.ts projectAccounts).
#
# WHAT IS ASSERTED (against the shipped cmd_account.sh, sourced)
#   HOST.  account_url_host keeps the host only: no scheme, no user:password@,
#          no port, no path/query/fragment, lowercased; a bracketed IPv6 stays.
#   ROW.   a custom account's row carries custom{harness, model, host}; the key
#          (FIVEDIVE_CUSTOM_API_KEY) and the address's path appear nowhere in
#          the output; every other account has no `custom` key; the rows,
#          types and signins are what they were.
# Fixture addresses are RFC 5737 / private ones and identify nothing.
# Run: bash tests/dive8170_account_list_custom_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/registry.sh lib/tasks_db.sh \
         lib/quota_wall.sh lib/codex_quota.sh lib/account_history.sh cmd_auth.sh cmd_account.sh; do
  source "src/$f"
done
set +e
lazy_need() { :; }
ensure_state_ro() { :; }
_tasks_store_fence() { :; }
_self_account_eligible() { return 1; }
account_default_v() { ACCOUNT_DEFAULT_ACCOUNT=""; ACCOUNT_DEFAULT_TYPE=""; ACCOUNT_DEFAULT_PINNED=0; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want: $3 | got: $2"; fi; }

# ── HOST ────────────────────────────────────────────────────────────────────
check "HOST: scheme, port and path go" "$(account_url_host https://GPU.Example.com:8443/v1/x)" "gpu.example.com"
check "HOST: user:password@ goes" "$(account_url_host 'https://u:s3cret@gw.example.com/api')" "gw.example.com"
check "HOST: query and fragment go" "$(account_url_host 'https://gw.example.com?k=1#f')" "gw.example.com"
check "HOST: a private IPv4 with a port" "$(account_url_host http://192.168.1.20:11434)" "192.168.1.20"
check "HOST: a bracketed IPv6 keeps its brackets" "$(account_url_host 'http://[::1]:8080/v1')" "[::1]"

# ── ROW ─────────────────────────────────────────────────────────────────────
AUTH_PROFILES_DIR="$TMP/profiles"; CONNECTORS_DIR="$TMP/connectors"
STATE_DIR="$TMP"; REGISTRY="$TMP/registry.json"; TASKS_DB="$TMP/tasks.db"
mkdir -p "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR"
echo '{"agents":{"nova":{"authProfile":"client-custom","type":"claude"}}}' >"$REGISTRY"
registry_read() { cat "$REGISTRY"; }
mk() { mkdir -p "$AUTH_PROFILES_DIR/$1"; printf '%s\n' "${@:2}" >"$AUTH_PROFILES_DIR/$1/combined.env"; }
# What custom_ai_save + _apply_byo_claude write for a claude custom account.
mk client-custom 'FIVEDIVE_CUSTOM_HARNESS=claude' 'FIVEDIVE_CUSTOM_BASE_URL=https://u:pw@llm.example.com:8443/secretpath/v1' \
  'FIVEDIVE_CUSTOM_MODEL=qwen3:32b' 'FIVEDIVE_CUSTOM_API_KEY=sk-NEVERSHOWN' \
  'ANTHROPIC_BASE_URL=https://u:pw@llm.example.com:8443/secretpath' 'ANTHROPIC_AUTH_TOKEN=sk-NEVERSHOWN' \
  'ANTHROPIC_DEFAULT_SONNET_MODEL=qwen3:32b'
mk office 'FIVEDIVE_CUSTOM_HARNESS=pi' 'FIVEDIVE_CUSTOM_BASE_URL=http://192.168.1.20:11434' 'FIVEDIVE_CUSTOM_MODEL=llama3.1' 'FIVEDIVE_CUSTOM_API_KEY='
mk client-deepseek 'ANTHROPIC_API_KEY=k' 'ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic'
mk bare 'X=1'
JSON_MODE=1
out=$(cmd_account_list 2>"$TMP/err")
check "ROW: the envelope is ok" "$(jq -r .ok <<<"$out")" "true"
check "ROW: four rows, as before" "$(jq -r '.data | length' <<<"$out")" "4"
check "ROW: the claude custom account's record" \
  "$(jq -c '.data[] | select(.name=="client-custom") | .custom' <<<"$out")" '{"harness":"claude","model":"qwen3:32b","host":"llm.example.com"}'
check "ROW: a pi custom account's record" \
  "$(jq -c '.data[] | select(.name=="office") | .custom' <<<"$out")" '{"harness":"pi","model":"llama3.1","host":"192.168.1.20"}'
check "ROW: types and signins are unchanged beside it" \
  "$(jq -c '.data[] | select(.name=="client-custom") | [.types, .agents, .signins.claude.model]' <<<"$out")" '[["claude"],["nova"],"qwen3:32b"]'
check "ROW: no custom key on a key account or a bare one" \
  "$(jq -c '[.data[] | select(.name=="client-deepseek" or .name=="bare") | has("custom")]' <<<"$out")" '[false,false]'
if grep -q 'NEVERSHOWN\|secretpath\|u:pw' <<<"$out"; then bad_t "ROW: the key, the path or the user:password show in the output" "$out"
else ok_t "ROW: the key, the address's path and its user:password appear nowhere"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
