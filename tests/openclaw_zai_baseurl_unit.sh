#!/usr/bin/env bash
# DIVE-1826: openclaw+zai auth failed with a correct GLM Coding-Plan key (lodar
# hit it, sibling of the DIVE-1819 hermes fix). Root cause is DIFFERENT from
# hermes: openclaw's zai provider speaks z.ai's OpenAI-compatible /paas/v4 surface
# (NOT the anthropic-wire endpoint), and openclaw's auto-detect probes the GENERAL
# endpoints before the Coding Plan ones — while our create path writes a bare
# {provider:zai} auth profile that never runs that probe. So a Coding-Plan key
# lands on the general endpoint and 401s. Fix: pin models.providers.zai.baseUrl to
# the openai-compat *coding* URL (api.z.ai/api/coding/paas/v4). _apply_byo_openclaw
# shells out to sudo + the real openclaw binary, so (as with the DIVE-1318/1819
# sibling tests) we assert against the table values and the parsed function body.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_auth.sh cmd_agent_create.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f" 2>/dev/null || { echo "source FAIL: $f"; exit 7; }
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# 1. The override table exists and resolves zai to the openai-compat CODING URL.
declare -p OPENCLAW_PROVIDER_URL >/dev/null 2>&1 \
  && ok_t "OPENCLAW_PROVIDER_URL table is declared" \
  || bad_t "OPENCLAW_PROVIDER_URL not declared"
[[ "${OPENCLAW_PROVIDER_URL[zai]:-}" == "https://api.z.ai/api/coding/paas/v4" ]] \
  && ok_t "OPENCLAW_PROVIDER_URL[zai] = api.z.ai/api/coding/paas/v4 (openai-compat coding surface)" \
  || bad_t "zai override wrong/missing" "got: '${OPENCLAW_PROVIDER_URL[zai]:-}'"

# 2. It must NOT be the anthropic-wire endpoint hermes/pi use — openclaw speaks
#    openai-completions to z.ai, so pinning the anthropic URL would break it. This
#    is the whole reason the override tables are not shared.
[[ "${OPENCLAW_PROVIDER_URL[zai]:-}" != "${CLAUDE_PROVIDER_BASEURL[zai]:-}" ]] \
  && ok_t "openclaw zai URL is NOT the anthropic endpoint (distinct from hermes/pi)" \
  || bad_t "openclaw zai URL wrongly equals the anthropic endpoint" \
     "openclaw='${OPENCLAW_PROVIDER_URL[zai]:-}' anthropic='${CLAUDE_PROVIDER_BASEURL[zai]:-}'"
[[ "${OPENCLAW_PROVIDER_URL[zai]:-}" == *"/coding/paas/v4" ]] \
  && ok_t "openclaw zai URL targets the Coding Plan endpoint family (/coding/paas/v4)" \
  || bad_t "openclaw zai URL is not a coding endpoint" "got: '${OPENCLAW_PROVIDER_URL[zai]:-}'"

# 3. _apply_byo_openclaw reads the override and pins it via the provider-catalog
#    config path (models.providers.<native>.baseUrl), the openclaw parallel to
#    hermes' `config set model.base_url`.
o=$(declare -f _apply_byo_openclaw)
grep -q 'openclaw_base_url="${OPENCLAW_PROVIDER_URL\[\$canonical\]:-}"' <<<"$o" \
  && ok_t "_apply_byo_openclaw resolves OPENCLAW_PROVIDER_URL[\$canonical]" \
  || bad_t "openclaw does not read OPENCLAW_PROVIDER_URL" "$o"
grep -q 'config set "models.providers.\${native}.baseUrl" "\$openclaw_base_url"' <<<"$o" \
  && ok_t "_apply_byo_openclaw pins models.providers.<id>.baseUrl to the override" \
  || bad_t "openclaw never sets models.providers.<id>.baseUrl to the override" "$o"

# 4. The pin is guarded — only providers WITH an override get a baseUrl written
#    (no override => no config write, so non-zai providers are untouched).
grep -Pzoq 'if \[\[ -n "\$openclaw_base_url" \]\]; then(.|\n)*?config set "models.providers.\$\{native\}.baseUrl"' <<<"$o" \
  && ok_t "baseUrl pin is gated on a non-empty override (non-zai providers untouched)" \
  || bad_t "openclaw writes baseUrl unconditionally" "$o"

# 5. The GLM Coding-Plan key-TYPE hint fires for zai (mirrors the hermes note).
grep -q 'canonical" == "zai"' <<<"$o" \
  && grep -qi 'GLM Coding-Plan key' <<<"$o" \
  && ok_t "_apply_byo_openclaw surfaces the GLM Coding-Plan key-type note for zai" \
  || bad_t "openclaw create path is missing the zai key-type hint" "$o"

# 6. Sanity: a provider without an override (e.g. openai) has no OPENCLAW_PROVIDER_URL
#    entry, so it falls through to openclaw's own catalog resolution (no pin).
[[ -z "${OPENCLAW_PROVIDER_URL[openai]:-}" ]] \
  && ok_t "no spurious override for a catalog-resolved provider (openai)" \
  || bad_t "unexpected OPENCLAW_PROVIDER_URL[openai]" "got: '${OPENCLAW_PROVIDER_URL[openai]:-}'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
