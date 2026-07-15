#!/usr/bin/env bash
# DIVE-1257: OpenCode init/auth provider selection (no root/network needed).
set -uo pipefail
cd "$(dirname "$0")/.."

for f in src/header.sh src/lib/error_codes.sh src/lib/output.sh src/lib/validation.sh src/cmd_auth.sh; do
  # shellcheck source=/dev/null
  source "$f"
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

[[ "$(opencode_provider_var openai)" == OPENAI_API_KEY ]] \
  && ok_t "openai maps to OPENAI_API_KEY" \
  || bad_t "openai provider mapping"
[[ "$(opencode_provider_var openrouter)" == OPENROUTER_API_KEY ]] \
  && ok_t "openrouter maps to OPENROUTER_API_KEY" \
  || bad_t "openrouter provider mapping"

out=$(opencode_provider_var anthropic 2>/dev/null); rc=$?
(( rc != 0 )) && [[ -z "$out" ]] \
  && ok_t "unsupported provider is rejected" \
  || bad_t "unsupported provider rejection" "rc=$rc out='$out'"

capture=$(mktemp)
trap 'rm -f "$capture"' EXIT
require_root() { :; }
write_default_connector() {
  local file="$1" var="$2" key
  key=$(cat)
  printf '%s|%s|%s' "$file" "$var" "$key" >"$capture"
}
ok() { :; }
cmd_auth_set opencode --api-key=sk-or-test-123456 --provider=openrouter
[[ "$(<"$capture")" == 'openai.env|OPENROUTER_API_KEY|sk-or-test-123456' ]] \
  && ok_t "auth set stores OpenRouter key in its native variable" \
  || bad_t "auth set OpenRouter routing" "got '$(<"$capture")'"

init_src=$(<src/cmd_init.sh)
[[ "$init_src" == *'provider [default openrouter]:'* ]] \
  && ok_t "init prompts for provider with OpenRouter default" \
  || bad_t "missing provider prompt"
[[ "$init_src" == *'agent auth set opencode --api-key=- --provider="$provider"'* ]] \
  && ok_t "init forwards selected provider to auth set" \
  || bad_t "provider is not forwarded"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
