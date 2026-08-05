#!/usr/bin/env bash
# DIVE-2757: `agent create --base-url=<url>` — point a claude-type agent at an
# Anthropic-compatible endpoint that is NOT in the CLAUDE_PROVIDER_BASEURL
# catalog (self-hosted open weights, a vendor host we ship no row for).
#
# Grades three things the feature is worthless without:
#   1. valid_base_url's scheme policy — https anywhere, http ONLY on loopback,
#      and no character that could forge a second line in combined.env.
#   2. _apply_byo_claude writes the OPERATOR's url and pins all THREE tiers,
#      including HAIKU. Haiku is the one that fails silently: it is background
#      traffic, not the tier anyone selects, so an unset value looks fine
#      interactively and 404s later.
#   3. A custom provider with no --model is REFUSED, not defaulted.
#
# No root, network, credentials, users, or runtime state are touched.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -f "${capture:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/lib/error_codes.sh   # E_USAGE / E_VALIDATION — without these every
                                # `fail "$E_..."` dies on `set -u` FIRST, and a
                                # refusal arm then "passes" on an unbound
                                # variable instead of on the guard it grades.
# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/lib/agent_setup.sh
# shellcheck disable=SC1091
source src/cmd_agent_create.sh

capture=$(mktemp)
step() { :; }
warn() { :; }
profile_set_var() {
  local profile="$1" var="$2" value
  value=$(cat)
  printf 'PROFILE %s %s=%s\n' "$profile" "$var" "$value" >>"$capture"
}
# fail() is the CLI's exit path and it EXITS — a stub that merely `return 1`s
# would let the function run on past its own refusal and write the profile
# anyway, so the harness would grade a code path production never takes. Keep
# the exit and run each refusal arm in a SUBSHELL instead.
fail() { printf 'FAIL[%s] %s\n' "$1" "$2" >&2; exit "$1"; }

fails=0 rc=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }

# --- 1. valid_base_url ------------------------------------------------------
echo "valid_base_url: scheme + shape policy"
for u in \
  "https://llm.example.com/anthropic" \
  "https://llm.example.com:8443/v1/anthropic" \
  "http://localhost:8000" \
  "http://127.0.0.1:8000/anthropic" \
  "http://[::1]:8000/anthropic" \
; do
  if valid_base_url "$u"; then ok "accepts $u"; else bad "rejected valid url: $u"; fi
done

# Rejections. Each is a distinct failure mode, not five spellings of one.
#  - plaintext to an OFF-BOX host puts the API key on the wire
#  - a private-LAN address is off-box too: "the LAN is trusted" is the wrong
#    assumption, and it is the one an exemption here would bake in
#  - a newline forges a second variable in the systemd EnvironmentFile
#  - a space/quote changes how systemd parses the line
#  - a non-http scheme is not an endpoint this harness can speak to
for u in \
  "http://llm.example.com/anthropic" \
  "http://192.0.2.10:8000" \
  "https://llm.example.com/a
FOO=bar" \
  "https://llm.example.com /anthropic" \
  "https://llm.example.com/\"x" \
  "ftp://llm.example.com" \
  "llm.example.com/anthropic" \
  "" \
; do
  if valid_base_url "$u"; then bad "accepted INVALID url: $(printf '%q' "$u")"
  else ok "rejects $(printf '%q' "$u")"; fi
done

# --- 2. the operator's url and all three tiers reach the profile ------------
echo "_apply_byo_claude: custom endpoint wins and pins every tier"
: >"$capture"
_apply_byo_claude custom sk-selfhost-123456 qa-prof qwen3.8-max "https://llm.example.com/anthropic"
assert_line() {
  if grep -qxF "$1" "$capture"; then ok "$1"; else bad "missing: $1"; fi
}
assert_line 'PROFILE qa-prof ANTHROPIC_BASE_URL=https://llm.example.com/anthropic'
assert_line 'PROFILE qa-prof ANTHROPIC_AUTH_TOKEN=sk-selfhost-123456'
assert_line 'PROFILE qa-prof ANTHROPIC_DEFAULT_OPUS_MODEL=qwen3.8-max'
assert_line 'PROFILE qa-prof ANTHROPIC_DEFAULT_SONNET_MODEL=qwen3.8-max'
# The one that would have been empty: no catalog row means no haiku default.
assert_line 'PROFILE qa-prof ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen3.8-max'
# The shared-account neutralisers still fire on this path.
assert_line 'PROFILE qa-prof CLAUDE_CODE_OAUTH_TOKEN='
assert_line 'PROFILE qa-prof ANTHROPIC_API_KEY='

# --- 2b. a KNOWN vendor redirected to another host keeps its catalog models --
# Redirecting z.ai to a different host changes WHERE the models are served, not
# WHICH models exist, so the catalog's per-tier ids must survive the override.
echo "_apply_byo_claude: known vendor + --base-url keeps catalog model ids"
: >"$capture"
_apply_byo_claude zai sk-zai-123456 qa-prof2 "" "https://open.bigmodel.cn/api/anthropic"
assert_line 'PROFILE qa-prof2 ANTHROPIC_BASE_URL=https://open.bigmodel.cn/api/anthropic'
assert_line "PROFILE qa-prof2 ANTHROPIC_DEFAULT_OPUS_MODEL=${CLAUDE_PROVIDER_OPUS_MODEL[zai]}"
assert_line "PROFILE qa-prof2 ANTHROPIC_DEFAULT_HAIKU_MODEL=${CLAUDE_PROVIDER_HAIKU_MODEL[zai]}"

# --- 3. refusals ------------------------------------------------------------
echo "_apply_byo_claude: refusals"
: >"$capture"
rc=0; ( _apply_byo_claude custom sk-selfhost-123456 qa-prof "" "https://llm.example.com/anthropic" ) 2>/dev/null || rc=$?
# The CODE, not merely non-zero: an unbound variable also exits non-zero, and
# that is exactly how this arm first passed while grading nothing.
if (( rc == E_USAGE )); then ok "custom provider with no --model is refused (exit $rc)"
else bad "expected exit $E_USAGE for missing --model, got $rc"; fi
# Positive control for the assertion above: the same call WITH a model passes,
# so the refusal is attributable to the missing model and not to the arm being
# broken in some other way.
: >"$capture"
if ( _apply_byo_claude custom sk-selfhost-123456 qa-prof m1 "https://llm.example.com/anthropic" ) 2>/dev/null; then
  ok "positive control: same call with --model succeeds"
else
  bad "positive control FAILED — the no-model refusal above proves nothing"
fi

: >"$capture"
rc=0; ( _apply_byo_claude custom sk-selfhost-123456 qa-prof m1 "http://llm.example.com" ) 2>/dev/null || rc=$?
if (( rc == E_VALIDATION )); then ok "off-box http:// endpoint is refused (exit $rc)"
else bad "expected exit $E_VALIDATION for off-box http://, got $rc"; fi

# apply_byo_provider gates --base-url to claude only.
rc=0; ( apply_byo_provider hermes custom sk-test-123456 qa-prof m1 "https://x.example.com" ) 2>/dev/null || rc=$?
if (( rc == E_VALIDATION )); then ok "--base-url is refused for non-claude types (exit $rc)"
else bad "expected exit $E_VALIDATION for --base-url on hermes, got $rc"; fi

# --- 4. the custom id is NOT a vendor --------------------------------------
# It must stay out of BYO_PROVIDER_LABEL, or every picker that enumerates that
# table offers a vendor with no endpoint behind it.
if valid_byo_provider "$CLAUDE_CUSTOM_PROVIDER_ID"; then
  bad "CLAUDE_CUSTOM_PROVIDER_ID leaked into BYO_PROVIDER_LABEL"
else
  ok "custom id is a label, not a catalog vendor"
fi

echo
if (( fails )); then echo "$fails failed"; exit 1; fi
echo "all assertions passed"
