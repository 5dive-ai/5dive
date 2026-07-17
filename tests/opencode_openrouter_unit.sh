#!/usr/bin/env bash
# DIVE-1206: OpenCode create-path OpenRouter wiring (no root/network needed).
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
has() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] && ok_t "$label" || bad_t "$label" "missing: $needle"
}

[[ "$(opencode_provider_var openrouter)" == OPENROUTER_API_KEY ]] \
  && ok_t "openrouter maps to OPENROUTER_API_KEY" \
  || bad_t "openrouter provider mapping"
out=$(opencode_provider_var deepseek 2>/dev/null); rc=$?
(( rc != 0 )) && [[ -z "$out" ]] \
  && ok_t "unsupported direct provider is rejected" \
  || bad_t "unsupported provider rejection" "rc=$rc out='$out'"

capture=$(mktemp)
trap 'rm -f "$capture"' EXIT
require_root() { :; }
step() { :; }
write_default_connector() {
  local file="$1" var="$2" key
  key=$(cat)
  printf '%s|%s|%s' "$file" "$var" "$key" >"$capture"
}
opencode_apply_provider_key openrouter sk-or-test-123456
[[ "$(<"$capture")" == 'openai.env|OPENROUTER_API_KEY|sk-or-test-123456' ]] \
  && ok_t "create helper stores OpenRouter key in its native variable" \
  || bad_t "OpenRouter key routing" "got '$(<"$capture")'"

merged=$(_opencode_merge_model_config 'openrouter/moonshotai/kimi-k2' \
  <<<'{"theme":"system","model":"openai/stale"}')
jq -e '.theme == "system" and .model == "openrouter/moonshotai/kimi-k2"' \
  >/dev/null <<<"$merged" \
  && ok_t "model config merge prefixes provider and preserves other keys" \
  || bad_t "model config merge" "got '$merged'"

create_src=$(<src/cmd_agent_create.sh)
has "$create_src" '"$type" == "opencode"' \
  "create accepts opencode in the provider/key path"
has "$create_src" 'opencode_provider_var "$byo_provider"' \
  "create validates the OpenCode provider map"
has "$create_src" 'opencode_apply_provider_key "$byo_provider" "$byo_api_key" "$profile"' \
  "create applies the selected provider key"
has "$create_src" 'opencode_apply_model_default "$name" "$byo_provider" "$byo_model"' \
  "create pins the selected provider/model"

for model in deepseek/deepseek-chat z-ai/glm-4.6 moonshotai/kimi-k2 qwen/qwen3-coder; do
  full="openrouter/$model"
  [[ "$full" == openrouter/* ]] \
    && ok_t "OpenRouter model slug accepted: $model" \
    || bad_t "OpenRouter model slug: $model"
done

# DIVE-1395: create-time catalog validation. A stub `opencode models` stands in
# for the real binary (no network/key), so the reject/accept/skip decisions of
# opencode_validate_model_or_fail run deterministically.
FAKE=$(mktemp -d)
cat >"$FAKE/opencode" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == models ]] || exit 0
printf '%s\n' \
  "openrouter/google/gemini-2.5-flash-lite" \
  "openrouter/google/gemini-3.1-flash-lite" \
  "openrouter/deepseek/deepseek-chat"
STUB
chmod +x "$FAKE/opencode"

# The exact QA slug is absent from the catalog and must be rejected (fail exits).
( OPENCODE_BIN="$FAKE/opencode" opencode_validate_model_or_fail \
    openrouter openrouter/google/gemini-2.0-flash-lite-001 KEY ) >/dev/null 2>&1
(( $? != 0 )) \
  && ok_t "unknown pinned slug is rejected at create" \
  || bad_t "unknown slug should be rejected" "gemini-2.0-flash-lite-001 absent from stub catalog"

# The rejection surfaces same-family suggestions.
msg=$( OPENCODE_BIN="$FAKE/opencode" opencode_validate_model_or_fail \
    openrouter openrouter/google/gemini-2.0-flash-lite-001 KEY 2>&1 )
has "$msg" "gemini-2.5-flash-lite" "reject message lists close catalog matches"

# A real catalog slug passes cleanly.
( OPENCODE_BIN="$FAKE/opencode" opencode_validate_model_or_fail \
    openrouter openrouter/google/gemini-2.5-flash-lite KEY ) >/dev/null 2>&1 \
  && ok_t "known catalog slug passes validation" \
  || bad_t "known slug should pass" "gemini-2.5-flash-lite is in stub catalog"

# Fail-OPEN: no key => cannot enumerate => skip so create is never blocked.
( opencode_validate_model_or_fail openrouter openrouter/anything/at-all "" ) >/dev/null 2>&1 \
  && ok_t "empty key skips validation (fail-open)" \
  || bad_t "empty key must skip, not fail" "validation blocked create with no key"

# Fail-OPEN: empty catalog (offline) => skip even for a bogus slug.
EMPTY=$(mktemp -d); printf '#!/usr/bin/env bash\nexit 0\n' >"$EMPTY/opencode"; chmod +x "$EMPTY/opencode"
( OPENCODE_BIN="$EMPTY/opencode" opencode_validate_model_or_fail \
    openrouter openrouter/bogus/model KEY ) >/dev/null 2>&1 \
  && ok_t "empty catalog skips validation (fail-open)" \
  || bad_t "empty catalog must skip, not fail" "offline enumeration blocked create"
rm -rf "$FAKE" "$EMPTY"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
