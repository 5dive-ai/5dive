#!/usr/bin/env bash
# DIVE-5174: account_signin_detail must report a claude BYO profile's mapped
# model (ANTHROPIC_DEFAULT_SONNET_MODEL) so the partner API can show the model a
# client's OpenRouter key was connected with. A plain subscription has no map
# and keeps model null. Pure function test: no root, no network.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/claude-signin-model.XXXXXX)

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh cmd_auth.sh cmd_account.sh; do
  source "$SRC/$f"
done
set +e

AUTH_PROFILES_DIR="$TMP/profiles"
mkdir -p "$AUTH_PROFILES_DIR"
export FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
CONNECTORS_DIR="$FIVEDIVE_CONNECTOR_DIR"
mkdir -p "$CONNECTORS_DIR"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

mk_profile() {
  local n="$1"; shift
  mkdir -p "$AUTH_PROFILES_DIR/$n"
  printf '%s\n' "$@" > "$AUTH_PROFILES_DIR/$n/combined.env"
}
field() { account_signin_detail "$1" claude | jq -r ".$2 // \"null\""; }

OR_URL="${CLAUDE_PROVIDER_BASEURL[openrouter]}"
DS_URL="${CLAUDE_PROVIDER_BASEURL[deepseek]}"

# An OpenRouter key connected with --model: opus+sonnet carry the override.
mk_profile client-openrouter "ANTHROPIC_BASE_URL=$OR_URL" 'ANTHROPIC_AUTH_TOKEN=sk-or-xxxx' \
  'ANTHROPIC_DEFAULT_OPUS_MODEL=minimax/minimax-m2.7' 'ANTHROPIC_DEFAULT_SONNET_MODEL=minimax/minimax-m2.7' \
  'ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek/deepseek-v4.1-flash'
[[ "$(field client-openrouter provider)" == "openrouter" ]] && ok_t "openrouter profile keeps provider openrouter" \
  || bad_t "provider" "$(account_signin_detail client-openrouter claude)"
[[ "$(field client-openrouter model)" == "minimax/minimax-m2.7" ]] && ok_t "openrouter profile reports its --model" \
  || bad_t "openrouter model" "$(account_signin_detail client-openrouter claude)"

# A quoted value and a later write: the last line wins, quotes stripped.
mk_profile ds "ANTHROPIC_BASE_URL=$DS_URL" 'ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-v4-flash"' \
  'ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-v4-pro"'
[[ "$(field ds model)" == "deepseek-v4-pro" ]] && ok_t "last write wins, quotes stripped" \
  || bad_t "deepseek model" "$(account_signin_detail ds claude)"

# The key never reaches the output.
# Capture first: under pipefail a matching grep -q can SIGPIPE the writer and
# score the leak as a miss (tests/epipe_corpus_guard_unit.sh).
out=$(account_signin_detail client-openrouter claude)
if grep -q 'sk-or-xxxx' <<<"$out"; then
  bad_t "no key in the detail" "$out"
else ok_t "no key in the detail"; fi

# A plain subscription / Anthropic key: no base url, no map -> model null.
mk_profile sub 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-xxxx'
[[ "$(field sub model)" == "null" && "$(field sub provider)" == "null" ]] && ok_t "subscription: model and provider stay null" \
  || bad_t "subscription" "$(account_signin_detail sub claude)"
mk_profile ak 'ANTHROPIC_API_KEY=sk-ant-api03-xxxx' 'ANTHROPIC_DEFAULT_SONNET_MODEL=stale'
[[ "$(field ak model)" == "null" ]] && ok_t "no base url: a stray map is not reported" \
  || bad_t "anthropic key" "$(account_signin_detail ak claude)"

# A BYO profile with no map yet: model null, not an empty string.
mk_profile nomap "ANTHROPIC_BASE_URL=$OR_URL" 'ANTHROPIC_AUTH_TOKEN=sk-or-yyyy'
[[ "$(account_signin_detail nomap claude | jq -c .model)" == "null" ]] && ok_t "BYO without a map: model null" \
  || bad_t "no map" "$(account_signin_detail nomap claude)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 && PASS == 7 ))
