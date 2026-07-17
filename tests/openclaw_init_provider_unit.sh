#!/usr/bin/env bash
# DIVE-1390: openclaw init offers a BYO provider + API-key path (dashboard
# parity), not just the OpenAI /codex/device oauth. No root/network needed.
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

init_src=$(<src/cmd_init.sh)

# openclaw must have its OWN auth branch, no longer lumped oauth-only with
# antigravity|grok.
[[ "$init_src" == *'openclaw)'* && "$init_src" != *'openclaw|antigravity|grok)'* ]] \
  && ok_t "openclaw has a dedicated auth branch (not lumped oauth-only)" \
  || bad_t "openclaw still lumped in antigravity|grok oauth branch"

# Both paths offered: keep the device-code oauth AND add BYO.
[[ "$init_src" == *'How should OpenClaw authenticate?'* \
   && "$init_src" == *'oauth|Sign in with OpenAI'* \
   && "$init_src" == *'byo|Bring your own provider'* ]] \
  && ok_t "init offers oauth + BYO choice for openclaw" \
  || bad_t "missing openclaw oauth/BYO picker"

# oauth path still launches the interactive login.
[[ "$init_src" == *'5dive agent auth login openclaw'* ]] \
  && ok_t "oauth path preserved (agent auth login openclaw)" \
  || bad_t "oauth path lost"

# BYO path picks a provider and forwards it to auth set.
[[ "$init_src" == *'Choose a provider for OpenClaw:'* \
   && "$init_src" == *'openrouter|OpenRouter|Broad model catalog · recommended'* ]] \
  && ok_t "init uses the provider picker with OpenRouter first/recommended" \
  || bad_t "missing OpenClaw provider picker"
[[ "$init_src" == *'agent auth set openclaw --api-key=- --provider="$provider"'* ]] \
  && ok_t "init forwards selected provider to auth set" \
  || bad_t "provider is not forwarded"

# Every provider the openclaw picker offers must resolve to a native
# OPENCLAW id (empty id => unsupported, e.g. nous, which is not offered).
oc_ok=1
for p in openrouter anthropic openai google deepseek moonshot qwen minimax huggingface zai; do
  [[ -n "${OPENCLAW_PROVIDER_ID[$p]:-}" ]] || { oc_ok=0; bad_t "offered provider '$p' has no native OPENCLAW_PROVIDER_ID"; }
done
(( oc_ok == 1 )) && ok_t "all offered openclaw providers resolve to a native id"
# nous has an empty native id, so it must NOT be offered by the openclaw picker.
[[ "$init_src" != *'nous|Nous|Nous models'* ]] \
  && ok_t "nous (no native id) is not offered in the openclaw picker" \
  || bad_t "nous offered in openclaw picker despite empty native id"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
