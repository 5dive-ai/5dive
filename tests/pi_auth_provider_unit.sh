#!/usr/bin/env bash
# DIVE-1200 unit harness for the pi auth path (multi-provider API-key, no OAuth).
#
# pi reads a standard per-provider *_API_KEY env var straight from its
# environment (verified against @earendil-works/pi-coding-agent 0.80.6). Unlike
# the single-var env types (codex→OPENAI_API_KEY) pi's target var depends on
# --provider, resolved via PI_PROVIDER_VAR / pi_provider_var(). This guards:
#   - the three core providers wired in DIVE-1200 map to the right native var,
#   - the default (no --provider) is anthropic,
#   - an unknown/not-yet-wired provider fails (rc!=0, empty stdout) so callers
#     surface the known set + the DIVE-1205 pointer instead of writing a bogus var,
#   - pi is in TYPE_API_FILE (so auth_creds_present's default-profile fallback
#     recognizes a pi key) but NOT in TYPE_API_VAR (it has no single native var).
# Run: bash tests/pi_auth_provider_unit.sh  (no root, no network, no tmux).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_auth.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e  # header.sh enabled set -e; asserts below deliberately probe non-zero rc

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- provider -> native var table ---------------------------------------------
[[ "$(pi_provider_var anthropic)" == 'ANTHROPIC_API_KEY' ]] && ok_t "anthropic -> ANTHROPIC_API_KEY" || bad_t "anthropic var" "got '$(pi_provider_var anthropic)'"
[[ "$(pi_provider_var openai)"    == 'OPENAI_API_KEY'    ]] && ok_t "openai -> OPENAI_API_KEY"       || bad_t "openai var" "got '$(pi_provider_var openai)'"
[[ "$(pi_provider_var google)"    == 'GEMINI_API_KEY'    ]] && ok_t "google -> GEMINI_API_KEY"       || bad_t "google var" "got '$(pi_provider_var google)'"

# --- DIVE-1205: OpenRouter + Chinese-model built-in providers -----------------
# All are pi built-ins (base_url ships in pi's registry), so wiring is just the
# per-provider *_API_KEY var; provider ids match pi's --provider/auth.json key.
[[ "$(pi_provider_var openrouter)"  == 'OPENROUTER_API_KEY' ]] && ok_t "openrouter -> OPENROUTER_API_KEY" || bad_t "openrouter var" "got '$(pi_provider_var openrouter)'"
[[ "$(pi_provider_var deepseek)"    == 'DEEPSEEK_API_KEY'   ]] && ok_t "deepseek -> DEEPSEEK_API_KEY"     || bad_t "deepseek var" "got '$(pi_provider_var deepseek)'"
[[ "$(pi_provider_var moonshotai)"  == 'MOONSHOT_API_KEY'   ]] && ok_t "moonshotai -> MOONSHOT_API_KEY"   || bad_t "moonshotai var" "got '$(pi_provider_var moonshotai)'"
[[ "$(pi_provider_var kimi-coding)" == 'KIMI_API_KEY'       ]] && ok_t "kimi-coding -> KIMI_API_KEY"      || bad_t "kimi-coding var" "got '$(pi_provider_var kimi-coding)'"
[[ "$(pi_provider_var zai)"         == 'ZAI_API_KEY'        ]] && ok_t "zai(GLM) -> ZAI_API_KEY"          || bad_t "zai var" "got '$(pi_provider_var zai)'"
[[ "$(pi_provider_var minimax)"     == 'MINIMAX_API_KEY'    ]] && ok_t "minimax -> MINIMAX_API_KEY"       || bad_t "minimax var" "got '$(pi_provider_var minimax)'"

# --- default (no arg) is anthropic --------------------------------------------
[[ "$(pi_provider_var)" == 'ANTHROPIC_API_KEY' ]] && ok_t "default provider = anthropic" || bad_t "default provider" "got '$(pi_provider_var)'"

# --- genuinely unknown providers still fail (rc!=0, empty stdout) --------------
# 'moonshot' (bare) is intentionally NOT a key: pi's id is 'moonshotai'.
for p in bogus moonshot qwen dashscope; do
  out=$(pi_provider_var "$p" 2>/dev/null); rc=$?
  label="unknown provider '${p:-<empty>}' rejected"
  if (( rc != 0 )) && [[ -z "$out" ]]; then ok_t "$label"; else bad_t "$label" "rc=$rc out='$out'"; fi
done

# --- DIVE-1205: settings.json model-pin merge (defaultProvider/defaultModel) ---
# Mirrors pi_apply_model_default's jq: overwrite the two model fields, preserve
# any other settings keys. Hermetic (no root/agent-user needed).
_tmp_sf=$(mktemp); printf '%s' '{"theme":"dark","defaultModel":"stale"}' > "$_tmp_sf"
_merged=$(jq --arg p openrouter --arg m 'deepseek/deepseek-chat' '.defaultProvider=$p | .defaultModel=$m' "$_tmp_sf")
if jq -e '.theme=="dark" and .defaultProvider=="openrouter" and .defaultModel=="deepseek/deepseek-chat"' >/dev/null <<<"$_merged"; then
  ok_t "settings.json merge pins provider+model, keeps other keys"
else
  bad_t "settings.json merge" "got '$_merged'"
fi
rm -f "$_tmp_sf"

# --- array wiring: pi in TYPE_API_FILE, NOT in TYPE_API_VAR --------------------
[[ "${TYPE_API_FILE[pi]:-}" == 'pi.env' ]] && ok_t "TYPE_API_FILE[pi] = pi.env" || bad_t "TYPE_API_FILE[pi]" "got '${TYPE_API_FILE[pi]:-<unset>}'"
[[ -z "${TYPE_API_VAR[pi]:-}" ]] && ok_t "TYPE_API_VAR[pi] unset (multi-provider)" || bad_t "TYPE_API_VAR[pi] should be unset" "got '${TYPE_API_VAR[pi]:-}'"

# --- DIVE-1396: the systemd template MUST load the pi connector -----------------
# TYPE_API_FILE[pi] is inert unless 5dive-agent@.service injects it into the
# agent env. Without this EnvironmentFile the OPENROUTER_API_KEY written by
# `agent create --type=pi --provider=openrouter` never reaches pi and the TUI
# boots to "No models available". Assert the wiring stays in lockstep.
_unit=systemd/5dive-agent@.service
grep -qxF "EnvironmentFile=-/etc/5dive/connectors/${TYPE_API_FILE[pi]}" "$_unit" \
  && ok_t "5dive-agent@.service loads /etc/5dive/connectors/${TYPE_API_FILE[pi]}" \
  || bad_t "systemd unit missing pi connector EnvironmentFile" "expected EnvironmentFile=-/etc/5dive/connectors/${TYPE_API_FILE[pi]} in $_unit"

# --- pi is a known type with a file-sentinel + channels enabled ---------------
[[ "${TYPE_AUTH[pi]:-}" == '/home/claude/.pi/agent/auth.json' ]] && ok_t "TYPE_AUTH[pi] sentinel present" || bad_t "TYPE_AUTH[pi]" "got '${TYPE_AUTH[pi]:-<unset>}'"

# --- DIVE-1402: create-time model validation against pi's registry -------------
# A stub `pi --list-models` stands in for the real binary (no network/key) and
# emits pi's whitespace table format (with a "~" alias row) so the reject/accept/
# skip decisions of pi_validate_model_or_fail run deterministically.
FAKE=$(mktemp -d)
cat >"$FAKE/pi" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --list-models ]] || exit 0
printf '%-11s %s\n' provider model
printf '%-11s %s\n' openrouter '~google/gemini-flash-latest'
printf '%-11s %s\n' openrouter google/gemini-2.5-flash-lite
printf '%-11s %s\n' openrouter deepseek/deepseek-chat
STUB
chmod +x "$FAKE/pi"

# The reported QA slug is absent from the catalog and must be rejected (fail exits).
( PI_BIN="$FAKE/pi" pi_validate_model_or_fail openrouter google/gemini-2.0-flash-lite-001 KEY ) >/dev/null 2>&1
(( $? != 0 )) \
  && ok_t "unknown pinned pi slug is rejected at create" \
  || bad_t "unknown slug should be rejected" "google/gemini-2.0-flash-lite-001 absent from stub catalog"

# The rejection surfaces same-family suggestions.
_msg=$( PI_BIN="$FAKE/pi" pi_validate_model_or_fail openrouter google/gemini-2.0-flash-lite-001 KEY 2>&1 )
grep -q "gemini-2.5-flash-lite" <<<"$_msg" \
  && ok_t "reject message lists close catalog matches" \
  || bad_t "reject message should list close matches" "got: $_msg"

# A real catalog slug passes cleanly, and pi's "~" alias marker is stripped for matching.
( PI_BIN="$FAKE/pi" pi_validate_model_or_fail openrouter google/gemini-2.5-flash-lite KEY ) >/dev/null 2>&1 \
  && ok_t "known catalog slug passes validation" \
  || bad_t "known slug should pass" "gemini-2.5-flash-lite is in stub catalog"
( PI_BIN="$FAKE/pi" pi_validate_model_or_fail openrouter google/gemini-flash-latest KEY ) >/dev/null 2>&1 \
  && ok_t "aliased (~) catalog slug passes after marker strip" \
  || bad_t "aliased slug should pass" "~google/gemini-flash-latest should match google/gemini-flash-latest"

# A ":<thinking>" suffix is compared on the slug alone (pi accepts it).
( PI_BIN="$FAKE/pi" pi_validate_model_or_fail openrouter google/gemini-2.5-flash-lite:high KEY ) >/dev/null 2>&1 \
  && ok_t "thinking suffix stripped before catalog match" \
  || bad_t "slug:thinking should validate on slug" "suffix not stripped"

# Fail-OPEN: no key => cannot enumerate => skip so create is never blocked.
( pi_validate_model_or_fail openrouter anything/at-all "" ) >/dev/null 2>&1 \
  && ok_t "empty key skips validation (fail-open)" \
  || bad_t "empty key must skip, not fail" "validation blocked create with no key"

# Fail-OPEN: empty catalog (offline `pi --list-models`) => skip even for a bogus slug.
EMPTY=$(mktemp -d); printf '#!/usr/bin/env bash\nexit 0\n' >"$EMPTY/pi"; chmod +x "$EMPTY/pi"
( PI_BIN="$EMPTY/pi" pi_validate_model_or_fail openrouter bogus/model KEY ) >/dev/null 2>&1 \
  && ok_t "empty catalog skips validation (fail-open)" \
  || bad_t "empty catalog must skip, not fail" "offline enumeration blocked create"
rm -rf "$FAKE" "$EMPTY"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
