#!/usr/bin/env bash
# DIVE-1327: create-time BYO --model propagation for Claude + Hermes.
# No root, network, credentials, users, or runtime state are touched.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/lib/agent_setup.sh
# shellcheck disable=SC1091
source src/cmd_agent_create.sh

capture=$(mktemp)
captured_settings=$(mktemp)
trap 'rm -f "$capture" "$captured_settings"' EXIT
step() { :; }
warn() { printf 'WARN %s\n' "$*" >>"$capture"; }
profile_set_var() {
  local profile="$1" var="$2" value
  value=$(cat)
  printf 'PROFILE %s %s=%s\n' "$profile" "$var" "$value" >>"$capture"
}

# Claude's shared profile still receives alias translations, while the source
# wiring below verifies the per-agent settings.json selects the exact slug.
_apply_byo_claude openrouter sk-or-test-123456 qa-profile google/gemini-2.5-pro
grep -qxF 'PROFILE qa-profile ANTHROPIC_DEFAULT_OPUS_MODEL=google/gemini-2.5-pro' "$capture"
grep -qxF 'PROFILE qa-profile ANTHROPIC_DEFAULT_SONNET_MODEL=google/gemini-2.5-pro' "$capture"

# Hermes previously lost argument 5 before reaching this helper and therefore
# wrote HERMES_PROVIDER_MODEL[openrouter] (openrouter/auto). Stub sudo so we can
# assert the native config commands without touching ~/.hermes.
: >"$capture"
TYPE_BIN[hermes]="/bin/true"
sudo() {
  cat >/dev/null || true
  printf 'SUDO %s\n' "$*" >>"$capture"
}
_apply_byo_hermes openrouter openrouter sk-or-test-123456 "" google/gemini-2.5-pro
grep -qF 'config set model.provider openrouter' "$capture"
grep -qF 'config set model.default google/gemini-2.5-pro' "$capture"
if grep -qF 'config set model.default openrouter/auto' "$capture"; then
  echo 'FAIL: Hermes ignored the explicit model and used openrouter/auto' >&2
  exit 1
fi

# Exercise the real Claude preseed function and inspect the JSON it sends to
# settings.json. Use a deliberately absent agent home so the harness behaves
# identically on a 5dive VM and a clean GitHub runner; the guarded missing-home
# failure and every write/default-skill operation are stubbed locally.
test_agent="byomodel-ci-${BASHPID}"
expected_settings_path="/home/agent-${test_agent}/.claude/settings.json"
E_GENERIC="${E_GENERIC:-1}"
fail() {
  if [[ "$*" == *"agent home missing: /home/agent-${test_agent}"* ]]; then
    return 0
  fi
  printf 'unexpected fail(): %s\n' "$*" >&2
  return 1
}
sudo() {
  local args="$*"
  if [[ "$args" == *"tee ${expected_settings_path}"* ]]; then
    cat >"$captured_settings"
  elif [[ "$args" == *'tee '* ]]; then
    cat >/dev/null
  fi
  return 0
}
chmod() { :; }
install_default_skill_for_agent() { :; }
preseed_claude_agent "$test_agent" none google/gemini-2.5-pro
jq -e '.model == "google/gemini-2.5-pro"' "$captured_settings" >/dev/null

create_src=$(<src/cmd_agent_create.sh)
setup_src=$(<src/lib/agent_setup.sh)
[[ "$create_src" == *'_apply_byo_hermes "$native" "$canonical" "$api_key" "$profile" "$model"'* ]]
[[ "$create_src" == *'_claude_byo_model="$byo_model"'* ]]
[[ "$create_src" == *'preseed_claude_agent "$name" "$channels" "$_claude_byo_model"'* ]]
[[ "$setup_src" == *'selected_model="${3:-claude-opus-4-8}"'* ]]
[[ "$setup_src" == *'model: $model'* ]]

echo 'PASS: explicit BYO model reaches Claude per-agent settings and Hermes config'
