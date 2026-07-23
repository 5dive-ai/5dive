#!/usr/bin/env bash
# DIVE-1819: hermes+zai auth failed with a correct key because _apply_byo_hermes
# UNCONDITIONALLY unset model.base_url and let hermes' catalog resolve zai to an
# endpoint the GLM Coding-Plan key won't auth against. Fix: pin the verified
# anthropic-wire endpoint (api.z.ai/api/anthropic — the one pi + the claude
# anthropic-skin use) when a known override exists, keeping the unset only as the
# stale-value fallback. _apply_byo_hermes shells out to sudo + the real hermes
# binary, so (as with the DIVE-1318 sibling test) we assert against the table
# values and the parsed function body.
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

# 1. The override table exists and resolves zai to the verified anthropic endpoint.
declare -p HERMES_PROVIDER_URL >/dev/null 2>&1 \
  && ok_t "HERMES_PROVIDER_URL table is declared" \
  || bad_t "HERMES_PROVIDER_URL not declared"
[[ "${HERMES_PROVIDER_URL[zai]:-}" == "https://api.z.ai/api/anthropic" ]] \
  && ok_t "HERMES_PROVIDER_URL[zai] = api.z.ai/api/anthropic (anthropic-wire)" \
  || bad_t "zai override wrong/missing" "got: '${HERMES_PROVIDER_URL[zai]:-}'"

# 2. It matches the endpoint the working reference paths (claude anthropic-skin /
#    pi) already use — single source of the verified URL, no drift.
[[ "${HERMES_PROVIDER_URL[zai]:-}" == "${CLAUDE_PROVIDER_BASEURL[zai]:-}" ]] \
  && ok_t "hermes zai URL matches CLAUDE_PROVIDER_BASEURL[zai] (reference-good)" \
  || bad_t "hermes zai URL drifted from claude anthropic-skin" \
     "hermes='${HERMES_PROVIDER_URL[zai]:-}' claude='${CLAUDE_PROVIDER_BASEURL[zai]:-}'"

# 3. _apply_byo_hermes reads the override and SETS base_url to it when defined...
h=$(declare -f _apply_byo_hermes)
grep -q 'hermes_base_url="${HERMES_PROVIDER_URL\[\$canonical\]:-}"' <<<"$h" \
  && ok_t "_apply_byo_hermes resolves HERMES_PROVIDER_URL[\$canonical]" \
  || bad_t "hermes does not read HERMES_PROVIDER_URL" "$h"
grep -q 'config set model.base_url "\$hermes_base_url"' <<<"$h" \
  && ok_t "_apply_byo_hermes sets model.base_url to the override when defined" \
  || bad_t "hermes never sets base_url to the override" "$h"

# 4. ...and keeps the unconditional unset ONLY as the fallback (stale-codex guard).
grep -q 'config set model.base_url "" ' <<<"$h" \
  && ok_t "_apply_byo_hermes still unsets base_url on the fallback path" \
  || bad_t "hermes lost the stale-value unset fallback" "$h"
# The set and the unset must be on opposite branches of one if/else, so a
# provider WITH an override is never also unset (which would re-introduce the bug).
grep -Pzoq 'if \[\[ -n "\$hermes_base_url" \]\]; then(.|\n)*?config set model.base_url "\$hermes_base_url"(.|\n)*?else(.|\n)*?config set model.base_url ""' <<<"$h" \
  && ok_t "set (override) and unset (fallback) are mutually exclusive branches" \
  || bad_t "base_url set/unset are not an if/else — override could still be unset" "$h"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
