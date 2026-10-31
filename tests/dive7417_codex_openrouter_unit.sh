#!/usr/bin/env bash
# DIVE-7417: Codex on any OpenRouter model, and the nightly init-smoke's Hermes
# and Codex cells on the capped OpenRouter test key. Graded against the SHIPPED
# code, extracted rather than copied:
#   1. codex_provider_var / codex_apply_provider_key (cmd_auth.sh): the key goes
#      to OPENROUTER_API_KEY, on stdin, never argv.
#   2. agent create refuses --provider without --api-key, an unknown codex
#      provider, and --api-key without --provider (the validation block, run).
#   3. seed_codex_provider (agent_setup.sh) + apply_codex_provider_seed
#      (5dive-agent-start): the seat's config.toml gets model_provider and a
#      [model_providers.openrouter] table that names the variable, never the key;
#      idempotent, and a provider someone already chose is kept.
#   4. init offers OpenRouter for Codex and creates with the key on stdin.
#   5. init-smoke: hermes and codex cells take the OpenRouter secret, which pull
#      requests never get, and run on openai/gpt-6-luna.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1 (expected '$2', got '$3')"; fi; }

for f in src/header.sh src/lib/error_codes.sh src/lib/output.sh src/lib/validation.sh src/lib/models.sh src/cmd_auth.sh; do
  # shellcheck source=/dev/null
  source "$f"
done
set +e
KEY="sk-or-v1-dive7417-test-0123456789"

# ---------------------------------------------------------------------------
# 1. The key writer.
# ---------------------------------------------------------------------------
eq_t "provider: openrouter reads OPENROUTER_API_KEY" "OPENROUTER_API_KEY" "$(codex_provider_var openrouter)"
_out=$(codex_provider_var deepseek); _rc=$?
[[ "$_rc" -ne 0 && -z "$_out" ]] && ok_t "provider: one Codex has no route for is refused" \
  || bad_t "provider: deepseek resolved for codex (rc=$_rc out='$_out')"

require_root() { :; }
step() { :; }
write_default_connector() { printf '%s|%s|%s|argv=%s' "$1" "$2" "$(cat)" "$*" > "$TMP/conn"; }
profile_set_var() { printf '%s|%s|%s|argv=%s' "$1" "$2" "$(cat)" "$*" > "$TMP/prof"; }
ensure_profile_dir() { :; }
codex_apply_provider_key openrouter "$KEY"
eq_t "key: lands in the codex connector as OPENROUTER_API_KEY, from stdin" \
  "openai.env|OPENROUTER_API_KEY|$KEY|argv=openai.env OPENROUTER_API_KEY" "$(cat "$TMP/conn")"
codex_apply_provider_key openrouter "$KEY" orkey
eq_t "key: with an account, lands in that account, from stdin" \
  "orkey|OPENROUTER_API_KEY|$KEY|argv=orkey OPENROUTER_API_KEY" "$(cat "$TMP/prof")"

# ---------------------------------------------------------------------------
# 2. Create's --provider/--api-key validation, run.
# ---------------------------------------------------------------------------
CREATE=src/cmd_agent_create.sh
_block="$(awk '/^  if \[\[ -n "\$byo_provider" \|\| -n "\$byo_api_key" \]\]; then$/ { on = 1 } on { print } on && /^  fi$/ { exit }' "$CREATE")"
[[ -n "$_block" ]] || { echo "FATAL - could not extract create's --provider/--api-key block"; exit 1; }
eval "create_byo_check() { $_block
echo VALID; }"
fail() { echo "REFUSED: $2"; exit 1; }
byo() { ( type=codex profile="" defer_auth=0 byo_base_url="" byo_model="" byo_provider="$1" byo_api_key="$2"; create_byo_check ) 2>&1 </dev/null; }
_o=$(byo openrouter "")
[[ "$_o" == *"must be passed together"* ]] && ok_t "create: codex --provider=openrouter without --api-key is refused" \
  || bad_t "create: --provider without --api-key was not refused: $_o"
_o=$(byo "" "$KEY")
[[ "$_o" == *"must be passed together"* ]] && ok_t "create: codex --api-key without --provider is refused" \
  || bad_t "create: --api-key without --provider was not refused: $_o"
_o=$(byo deepseek "$KEY")
[[ "$_o" == *"codex provider 'deepseek' not supported"* ]] && ok_t "create: a provider Codex has no route for is refused" \
  || bad_t "create: codex --provider=deepseek was not refused: $_o"
_o=$(byo openrouter "$KEY")
eq_t "create: codex --provider=openrouter --api-key passes" "VALID" "$_o"
_o=$( ( type=devin profile="" defer_auth=0 byo_base_url="" byo_model="" byo_provider=openrouter byo_api_key="$KEY"; create_byo_check ) 2>&1 </dev/null)
[[ "$_o" == *"only supported for"* ]] && ok_t "create: a type with no key path is still refused (control)" \
  || bad_t "create: devin --provider passed: $_o"

_apply="$(awk '/^  if \[\[ -n "\$byo_provider" \]\]; then$/ { on = 1 } on { print } on && /^  fi$/ { exit }' "$CREATE")"
grep -q 'codex_apply_provider_key "$byo_provider" "$byo_api_key" "$profile"' <<<"$_apply" \
  && ok_t "create: a codex key is written by codex_apply_provider_key" \
  || bad_t "create: the BYO apply block never calls codex_apply_provider_key"
_branch="$(awk '/preseed_codex_return_channel "\$name"/ { on = 1 } on { print } on && /^  fi$/ { exit }' "$CREATE")"
grep -q 'seed_codex_provider "$name" "$byo_provider"' <<<"$_branch" \
  && ok_t "create: the codex branch seeds the provider" \
  || bad_t "create: the codex branch never seeds the provider"

# ---------------------------------------------------------------------------
# 3. Seed, then first start.
# ---------------------------------------------------------------------------
eval "$(awk '/^seed_codex_provider\(\) \{$/ { on = 1 } on { print } on && $0 == "}" { exit }' src/lib/agent_setup.sh)"
declare -F seed_codex_provider >/dev/null || { echo "FATAL - could not extract seed_codex_provider"; exit 1; }
chown() { :; }
export AGENT_HOME_ROOT="$TMP/homes"
seed_codex_provider orseat openrouter; _rc=$?
H="$TMP/homes/agent-orseat/.codex"
eq_t "seed: rc 0" "0" "$_rc"
eq_t "seed: id, base_url, variable" $'openrouter\nhttps://openrouter.ai/api/v1\nOPENROUTER_API_KEY' "$(cat "$H/.5dive-provider-seed")"
eq_t "seed: 0600" "600" "$(stat -c '%a' "$H/.5dive-provider-seed")"
seed_codex_provider badseat deepseek; _rc=$?
[[ "$_rc" -ne 0 && ! -e "$TMP/homes/agent-badseat/.codex/.5dive-provider-seed" ]] \
  && ok_t "seed: an unknown provider writes nothing (rc $_rc)" || bad_t "seed: an unknown provider left a seed"

START=bin/5dive-agent-start
eval "$(awk '/^  apply_codex_model_seed\(\) \{/ { on = 1 } on { print } on && $0 == "  }" { exit }' "$START")"
eval "$(awk '/^  apply_codex_provider_seed\(\) \{/ { on = 1 } on { print } on && $0 == "  }" { exit }' "$START")"
declare -F apply_codex_provider_seed >/dev/null || { echo "FATAL - could not extract apply_codex_provider_seed"; exit 1; }
# config.toml as 5dive-agent-start writes it on first start.
printf 'approval_policy = "never"\nsandbox_mode = "danger-full-access"\ncheck_for_update_on_startup = false\n\n[projects."/home/agent-orseat"]\ntrust_level = "trusted"\n' > "$H/config.toml"
printf 'openai/gpt-6-luna\n' > "$H/.5dive-model-seed"
apply_codex_model_seed "$H"
apply_codex_provider_seed "$H" 2>"$TMP/warn"
toml() { python3 -c 'import json,sys,tomllib; print(json.dumps(tomllib.load(open(sys.argv[1],"rb"))))' "$1"; }
_j=$(toml "$H/config.toml") || bad_t "start: config.toml is not valid TOML: $(cat "$H/config.toml")"
eq_t "start: model_provider is top-level openrouter" "openrouter" "$(jq -r .model_provider <<<"$_j")"
eq_t "start: model is the seeded slug" "openai/gpt-6-luna" "$(jq -r .model <<<"$_j")"
eq_t "start: the table names the endpoint" "https://openrouter.ai/api/v1" "$(jq -r .model_providers.openrouter.base_url <<<"$_j")"
eq_t "start: the table names the variable" "OPENROUTER_API_KEY" "$(jq -r .model_providers.openrouter.env_key <<<"$_j")"
eq_t "start: wire_api is responses (codex 0.166 refuses chat)" "responses" "$(jq -r .model_providers.openrouter.wire_api <<<"$_j")"
eq_t "start: the trusted project is still its own table" "trusted" "$(jq -r '.projects["/home/agent-orseat"].trust_level' <<<"$_j")"
grep -q "sk-or" "$H/config.toml" && bad_t "start: a key reached config.toml" || ok_t "start: no key in config.toml"
[[ ! -e "$H/.5dive-provider-seed" ]] && ok_t "start: the seed is consumed" || bad_t "start: the seed is still there"
_before=$(cat "$H/config.toml")
seed_codex_provider orseat openrouter; apply_codex_provider_seed "$H"
eq_t "start: a second seed changes nothing (no duplicate table)" "$_before" "$(cat "$H/config.toml")"
# A provider someone already chose is kept.
H2="$TMP/homes/agent-mine/.codex"; mkdir -p "$H2"
printf 'model_provider = "azure"\napproval_policy = "never"\n' > "$H2/config.toml"
printf 'openrouter\nhttps://openrouter.ai/api/v1\nOPENROUTER_API_KEY\n' > "$H2/.5dive-provider-seed"
apply_codex_provider_seed "$H2"
eq_t "start: an existing model_provider is kept" "azure" "$(toml "$H2/config.toml" | jq -r .model_provider)"
# A malformed seed is dropped, not written.
H3="$TMP/homes/agent-bad/.codex"; mkdir -p "$H3"
printf 'approval_policy = "never"\n' > "$H3/config.toml"
printf 'openrouter"\nhttps://x\nOPENROUTER_API_KEY\n' > "$H3/.5dive-provider-seed"
apply_codex_provider_seed "$H3" 2>"$TMP/warn3"
eq_t "start: a malformed seed leaves config.toml alone" 'approval_policy = "never"' "$(cat "$H3/config.toml")"
grep -q "malformed codex provider seed" "$TMP/warn3" && [[ ! -e "$H3/.5dive-provider-seed" ]] \
  && ok_t "start: a malformed seed warns and is dropped" || bad_t "start: a malformed seed was not reported/dropped"
grep -q '^  apply_codex_provider_seed "\$AGENT_CODEX_HOME"$' "$START" \
  && ok_t "start: the provider seed is applied on every codex start" || bad_t "start: apply_codex_provider_seed is never called"

# ---------------------------------------------------------------------------
# 4. init.
# ---------------------------------------------------------------------------
INIT=src/cmd_init.sh
_codex="$(awk '/^      codex\)$/ { on = 1 } on { print } on && /^        ;;$/ { exit }' "$INIT")"
grep -q '"openrouter|OpenRouter|' <<<"$_codex" && ok_t "init: Codex offers OpenRouter" || bad_t "init: no OpenRouter option for Codex"
grep -q 'create_provider="openrouter"' <<<"$_codex" && grep -q '_init_secret create_key "openrouter API key"' <<<"$_codex" \
  && ok_t "init: provider and masked key are kept for create" || bad_t "init: the Codex OpenRouter choice is not kept for create"
grep -q '_init_text create_model "Model" "openai/$(codex_model_default)"' <<<"$_codex" \
  && ok_t "init: asks the model, defaulting to openai/<GPT Sol>" || bad_t "init: no model question for Codex on OpenRouter"
grep -q 'auth set codex.*--provider' <<<"$_codex" && bad_t "init: Codex OpenRouter takes the early auth-set path" \
  || ok_t "init: the key is not written before create"
grep -q 'create_args+=("--provider=$create_provider" "--api-key=-")' "$INIT" \
  && grep -q 'printf .%s. "$create_key" | _init_run "Creating $name" 5dive agent create' "$INIT" \
  && ok_t "init: create gets --provider and the key on stdin" || bad_t "init: create does not get the key on stdin"

# ---------------------------------------------------------------------------
# 5. init-smoke.
# ---------------------------------------------------------------------------
WF=.github/workflows/init-smoke.yml
_unguarded=$(grep -n 'secrets\.' "$WF" | grep -v "github.event_name != 'pull_request' && secrets\." || true)
eq_t "workflow: every secret is withheld from pull requests" "" "$_unguarded"
grep -q "OPENROUTER_KEY: \${{ github.event_name != 'pull_request' && secrets.INIT_SMOKE_OPENROUTER_API_KEY || '' }}" "$WF" \
  && ok_t "workflow: the OpenRouter secret is wired, PR-guarded" || bad_t "workflow: INIT_SMOKE_OPENROUTER_API_KEY not wired"
grep -q 'codex|hermes-\*) key="$OPENROUTER_KEY"' "$WF" \
  && ok_t "workflow: hermes and codex cells take the OpenRouter key" || bad_t "workflow: hermes/codex do not take the OpenRouter key"
SM=scripts/init-smoke.sh
for c in codex hermes-sandboxed hermes-standard; do
  eq_t "smoke: $c bills the openrouter key" "openrouter" "$(bash -c "source <(sed -n '/^cell_key()/p' $SM); cell_key $c")"
done
eq_t "smoke: claude still bills the anthropic key" "anthropic" "$(bash -c "source <(sed -n '/^cell_key()/p' $SM); cell_key claude")"
_or=$(sed -n 's/^OR_MODEL=//p' "$SM")
eq_t "smoke: the OpenRouter model is gpt-6-luna" "openai/gpt-6-luna" "$_or"
[[ "${_or,,}" != *claude* && "${_or,,}" != *anthropic* ]] && ok_t "smoke: never a Claude model through OpenRouter" || bad_t "smoke: OR_MODEL is a Claude model"
_s=$(bash "$SM" steps codex)
eq_t "smoke: codex picks OpenRouter" "OpenRouter" "$(jq -r '.[1].pick' <<<"$_s")"
eq_t "smoke: codex types the key at init's openrouter prompt" "true" "$(jq -r '.[] | select(.wait | test("openrouter")) | .secret' <<<"$_s")"
eq_t "smoke: codex answers the model question with gpt-6-luna" "openai/gpt-6-luna" "$(jq -r '.[] | select(.wait | startswith("Model")) | .send | rtrimstr("\n")' <<<"$_s")"
printf '  › Model [openai/gpt-6.1-sol]: ' | grep -qP "$(jq -r '.[] | select(.wait | startswith("Model")) | .wait' <<<"$_s")" \
  && ok_t "smoke: the model wait matches init's prompt" || bad_t "smoke: the model wait does not match init's prompt"
for c in hermes-sandboxed hermes-standard; do
  _s=$(bash "$SM" steps "$c")
  eq_t "smoke: $c picks OpenRouter" "OpenRouter" "$(jq -r '.[1].pick' <<<"$_s")"
done
eq_t "smoke: claude keeps its Anthropic steps" "Anthropic API key" "$(bash "$SM" steps claude | jq -r '.[1].pick')"
grep -qE "grep -qiE '[^']*insufficient credits" "$SM" \
  && ok_t "smoke: an empty OpenRouter balance is a skip, like Anthropic's" || bad_t "smoke: OpenRouter's out-of-credit reply is not recognised"

echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
