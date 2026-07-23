#!/usr/bin/env bash
# DIVE-1821: account_signin_detail must resolve a pi profile's active provider
# from the *_API_KEY var present in the resolved env (profile combined.env, then
# the shared pi.env connector), reverse-mapped via PI_PROVIDER_VAR — so the
# dashboard can draw pi's Z.ai/etc corner badge like it does for hermes/openclaw.
# Pure function test: no root, no network. AUTH_PROFILES_DIR + a fake connector
# dir are pointed at a tmpdir.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/pi-badge.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh cmd_auth.sh cmd_account.sh; do
  source "$SRC/$f"
done
set +e

AUTH_PROFILES_DIR="$TMP/profiles"
mkdir -p "$AUTH_PROFILES_DIR"
# Isolate the shared connector dir so the host's real /etc/5dive/connectors/pi.env
# never leaks into a profile-scoped resolution. CONNECTORS_DIR honors this var.
export FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
CONNECTORS_DIR="$FIVEDIVE_CONNECTOR_DIR"
mkdir -p "$CONNECTORS_DIR"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# mk_profile <name> <combined.env body lines...>
mk_profile() {
  local n="$1"; shift
  mkdir -p "$AUTH_PROFILES_DIR/$n"
  printf '%s\n' "$@" > "$AUTH_PROFILES_DIR/$n/combined.env"
}
prov_of() { account_signin_detail "$1" pi | jq -r '.provider // "null"'; }

# --- single zai key -> zai (the screenshot case: pi-mia bound to a Z.ai key) ---
mk_profile zprof 'ZAI_API_KEY=sk-zai-xxxx'
[[ "$(prov_of zprof)" == "zai" ]] && ok_t "single ZAI_API_KEY -> provider zai" || bad_t "zai badge" "$(account_signin_detail zprof pi)"

# --- openrouter key -> openrouter ---
mk_profile orprof 'OPENROUTER_API_KEY=sk-or-xxxx'
[[ "$(prov_of orprof)" == "openrouter" ]] && ok_t "OPENROUTER_API_KEY -> openrouter" || bad_t "openrouter badge" "$(account_signin_detail orprof pi)"

# --- deepseek key -> deepseek ---
mk_profile dsprof 'DEEPSEEK_API_KEY=sk-ds-xxxx'
[[ "$(prov_of dsprof)" == "deepseek" ]] && ok_t "DEEPSEEK_API_KEY -> deepseek" || bad_t "deepseek badge" "$(account_signin_detail dsprof pi)"

# --- empty value is not a signed-in provider (ignored) ---
mk_profile emptyval 'ZAI_API_KEY='
[[ "$(account_signin_detail emptyval pi)" == "{}" ]] && ok_t "empty *_API_KEY value -> {} (no badge)" || bad_t "empty value ignored" "$(account_signin_detail emptyval pi)"

# --- no pi var at all -> {} (falls through, no badge) ---
mk_profile novar 'SOME_OTHER=1'
[[ "$(account_signin_detail novar pi)" == "{}" ]] && ok_t "no pi *_API_KEY -> {}" || bad_t "no-var -> {}" "$(account_signin_detail novar pi)"

# --- credentials/model shape: detail is valid JSON with the badge provider ---
d=$(account_signin_detail zprof pi)
jq -e '.provider=="zai" and has("model") and has("signedInAt") and has("credentials")' <<<"$d" >/dev/null \
  && ok_t "emits {provider,model,signedInAt,credentials}" || bad_t "detail shape" "$d"

# --- account_types_authed surfaces pi (the load-bearing prerequisite: without
#     it cmd_account_list never calls account_signin_detail for pi) ---
types_has() { jq -e --arg t "$1" 'index($t) != null' <<<"$(account_types_authed "$2")" >/dev/null; }
types_has pi zprof   && ok_t "account_types_authed lists pi for a ZAI_API_KEY profile" || bad_t "types: zai->pi" "$(account_types_authed zprof)"
types_has pi orprof  && ok_t "account_types_authed lists pi for an OPENROUTER profile" || bad_t "types: or->pi" "$(account_types_authed orprof)"
# no pi var -> pi not listed
if types_has pi novar; then bad_t "types: novar must NOT list pi" "$(account_types_authed novar)"; else ok_t "no pi var -> pi absent from types"; fi

# --- shared connector fallback for a default/agent name with no profile dir,
#     and NO cross-file leak onto an unrelated profile ---
printf 'DEEPSEEK_API_KEY=sk-ds-conn\n' > "$CONNECTORS_DIR/pi.env"
[[ "$(prov_of ghostagent)" == "deepseek" ]] && ok_t "no profile dir -> falls back to shared connector (deepseek)" || bad_t "connector fallback" "$(account_signin_detail ghostagent pi)"
# zprof still resolves to its OWN zai key, not the connector's deepseek
[[ "$(prov_of zprof)" == "zai" ]] && ok_t "profile key wins over shared connector (no leak)" || bad_t "connector leak" "$(account_signin_detail zprof pi)"
rm -f "$CONNECTORS_DIR/pi.env"

# --- deterministic first-match on multi-key profile (no live agent to pin) ---
# anthropic sorts first among {anthropic,zai}; with no settings.json pin the
# fallback is the sorted-first present var, and it must be stable run-to-run.
mk_profile multi 'ANTHROPIC_API_KEY=sk-ant-x' 'ZAI_API_KEY=sk-zai-x'
p1=$(prov_of multi); p2=$(prov_of multi)
[[ "$p1" == "$p2" && -n "$p1" && "$p1" != "null" ]] && ok_t "multi-key fallback is deterministic ($p1)" || bad_t "multi-key determinism" "$p1 vs $p2"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
