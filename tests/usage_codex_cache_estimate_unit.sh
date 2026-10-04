#!/usr/bin/env bash
# DIVE-5504 item 5 — cache-aware usage for a Codex seat.
#
# The codex audit (2026-10-04) measured 134-146k input tokens per model call at
# 96% cache, and found `5dive usage` counting every cached token at 1.0x on the
# strength of ONE observation (DIVE-4028), labelled "measured". OpenAI's own
# credit rate charges a cached token 1/20 of an uncached one. This pins:
#   E1  a Codex agent row carries input split three ways (raw = uncached + cached)
#   E2  credits and API dollars at OpenAI's published rates for the turn's model
#   E3  a model with no rate here gets null, never a guess
#   E4  the provider's 5h/7d percentages are passed through untouched
#   E5  the basis block labels each figure; the 1.0x weight is "single observation"
#   E6  the per-agent view prints each basis with its label, and no token count
#       is presented as a percentage
#   E7  the rate table prices codex_model_default, its dated snapshot, and no
#       variant (-pro) of it; the id is read from models.sh, never spelled in
#       cmd_usage.sh. E2 pins the id the rates were PUBLISHED for, so a models.sh
#       bump turns E2 red until someone re-checks the rates.
# Negative control: USAGE_SRC_DIR=<origin/main src> makes E1-E6 fail.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

SRC_DIR="${USAGE_SRC_DIR:-src}"
TMP="$(mktemp -d /tmp/usage-codex-est.XXXXXX)"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

awk "/python3 - <<'PY'/{f=1;next} f&&/^PY\$/{f=0} f" "$SRC_DIR/cmd_usage.sh" > "$TMP/collect.py"
[[ -s "$TMP/collect.py" ]] || { echo "FAIL - could not extract usage_collect python"; exit 1; }

NOW="$(date +%s)"
TS="$(date -u -d @"$NOW" +%Y-%m-%dT%H:%M:%SZ)"
R="$TMP/homes"
rollout() { # <agent> <model> — the audit's own call: 145,871 in, 140,672 cached, 653 out
  local d="$R/agent-$1/.codex/sessions/$(date -u -d @"$NOW" +%Y/%m/%d)"
  mkdir -p "$d"
  printf '%s\n' \
    "{\"type\":\"turn_context\",\"timestamp\":\"$TS\",\"payload\":{\"model\":\"$2\",\"effort\":\"high\"}}" \
    "{\"type\":\"event_msg\",\"timestamp\":\"$TS\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":145871,\"cached_input_tokens\":140672,\"cache_write_input_tokens\":0,\"output_tokens\":653}},\"rate_limits\":{\"primary\":{\"used_percent\":19},\"secondary\":{\"used_percent\":29}}}}" \
    > "$d/rollout-a.jsonl"
}
rollout sol gpt-6.1-sol
rollout odd gpt-9-unknown
rollout pro gpt-6.1-sol-pro
rollout snap gpt-6.1-sol-2026-09-30
printf '{"agents":{"sol":{"type":"codex"},"odd":{"type":"codex"},"pro":{"type":"codex"},"snap":{"type":"codex"}}}' > "$TMP/reg.json"
# shellcheck source=../src/lib/models.sh
source src/lib/models.sh
OUT="$(CODEX_RATES_MODEL="$(codex_model_default)" REGISTRY="$TMP/reg.json" TASK_DB="$TMP/none.db" \
       USAGE_SINCE="$((NOW-3600))" USAGE_HOME_ROOT="$R" python3 "$TMP/collect.py" 2>"$TMP/err")"
SOL="$(jq -c '.agents[] | select(.name=="sol")' <<<"$OUT" 2>/dev/null)"
ODD="$(jq -c '.agents[] | select(.name=="odd")' <<<"$OUT" 2>/dev/null)"

[[ "$(jq -r '.codexEstimate | [.rawInput,.uncachedInput,.cachedInput,.output] | @csv' <<<"$SOL" 2>/dev/null)" == '145871,5199,140672,653' ]] \
  && ok_t "E1 input split three ways: raw 145,871 = 5,199 uncached + 140,672 cached" \
  || bad_t "E1 split" "$(jq -c '.codexEstimate' <<<"$SOL" 2>/dev/null) $(head -c 300 "$TMP/err")"

# credits = (5199*50 + 140672*2.5 + 653*250)/1e6 = 0.77488; api = (5199*2 + 140672*0.10 + 653*10)/1e6 = 0.0309952
[[ "$(jq -r '.codexEstimate | [.model,.ratesFor,.credits,.apiUsd,.ratesAsOf] | @csv' <<<"$SOL" 2>/dev/null)" == '"gpt-6.1-sol","gpt-6.1-sol",0.77,0.031,"2026-10-04"' ]] \
  && ok_t "E2 credits 0.77 and API \$0.031 at OpenAI's published gpt-6.1-sol rates (cached at 1/20)" \
  || bad_t "E2 estimate" "$(jq -c '.codexEstimate' <<<"$SOL" 2>/dev/null)"

[[ "$(jq -r '.codexEstimate | [.model, (.credits|tostring), (.apiUsd|tostring)] | @csv' <<<"$ODD" 2>/dev/null)" == '"gpt-9-unknown","null","null"' ]] \
  && ok_t "E3 a model with no rate here is priced null, never guessed" \
  || bad_t "E3 unknown model" "$(jq -c '.codexEstimate' <<<"$ODD" 2>/dev/null)"

[[ "$(jq -r '[.fiveHourPct,.sevenDayPct] | @csv' <<<"$SOL" 2>/dev/null)" == '19,29' ]] \
  && ok_t "E4 the provider's 5h/7d percentages pass through untouched" \
  || bad_t "E4 provider pct" "$SOL"

B="$(jq -c '.basis' <<<"$OUT" 2>/dev/null)"
[[ "$(jq -r '.quota.providerWeights.codex.basis' <<<"$B")" == "single observation" \
   && "$(jq -r '.providerPct.use' <<<"$B")" == *"never derived from tokens"* \
   && "$(jq -r '.codexEstimate.caveat' <<<"$B")" == *"not a plan percentage"* ]] \
  && ok_t "E5 every figure's basis is labelled; the 1.0x weight is one observation, not 'measured'" \
  || bad_t "E5 basis labels" "$B"

# --- the per-agent view ----------------------------------------------------------
source src/lib/error_codes.sh 2>/dev/null || { E_USAGE=2; E_GENERIC=1; E_PERMISSION=77; E_VALIDATION=3; }
JSON_MODE=0
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
fail() { printf 'error: %s\n' "${2:-}" >&2; exit "${1:-1}"; }
ok()   { printf 'ok: %s\n' "${1:-}"; }
# shellcheck disable=SC1090
source "$SRC_DIR/cmd_usage.sh"
ensure_state()  { :; }
VIEW="$(usage_render_agent "$OUT" sol 24h 2>&1)"
grep -qF "Plan window used (provider-reported): 5h 19% · 7d 29%" <<<"$VIEW" \
  && grep -qF "Codex input: 145.8k = 5.1k uncached + 140.6k cached (96% cached) · output 653" <<<"$VIEW" \
  && grep -qF "Codex credits (estimate, OpenAI Standard rates for gpt-6.1-sol, 2026-10-04): 0.77 · API-equivalent: \$0.031" <<<"$VIEW" \
  && ! grep -qiE "QUOTA[^\n]*%" <<<"$(grep -i quota <<<"$VIEW")" \
  && ok_t "E6 the per-agent view labels each basis; no token count is shown as a percentage" \
  || bad_t "E6 view" "$VIEW"
VIEW_ODD="$(usage_render_agent "$OUT" odd 24h 2>&1)"
grep -qF "no published rate for gpt-9-unknown" <<<"$VIEW_ODD" \
  && ok_t "E6b an unpriced model says so instead of printing a number" \
  || bad_t "E6b" "$VIEW_ODD"

PRO="$(jq -c '.agents[] | select(.name=="pro") | .codexEstimate' <<<"$OUT" 2>/dev/null)"
SNAP="$(jq -c '.agents[] | select(.name=="snap") | .codexEstimate' <<<"$OUT" 2>/dev/null)"
if [[ "$(jq -r '[(.ratesFor|tostring), (.credits|tostring)] | @csv' <<<"$PRO")" == '"null","null"' \
   && "$(jq -r '[.ratesFor, .credits] | @csv' <<<"$SNAP")" == '"gpt-6.1-sol",0.77' \
   && "$(grep -cF 'CODEX_RATES_MODEL="$(codex_model_default' "$SRC_DIR/cmd_usage.sh")" == 1 ]]; then
  ok_t "E7 rates key off codex_model_default: its dated snapshot priced, -pro left unpriced"
else
  bad_t "E7 rate key" "pro=$PRO snap=$SNAP"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
