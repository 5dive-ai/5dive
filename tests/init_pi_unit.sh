#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# cmd_init.sh only defines cmd_init; inspecting its definition lets this test
# cover the interactive wiring without creating a real user or agent.
# shellcheck source=../src/cmd_init.sh
source "$ROOT/src/cmd_init.sh"
body="$(declare -f cmd_init)"

assert_has() {
  local needle="$1" message="$2"
  [[ "$body" == *"$needle"* ]] || {
    echo "FAIL: $message" >&2
    exit 1
  }
}

assert_has "opencode pi" "pi must be the eighth wizard type"
assert_has '[pi]="Extension-based coding agent — bring your own provider"' \
  "pi must have a wizard menu description"
assert_has '5dive agent auth set pi --provider="$provider" --api-key=-' \
  "pi credentials must use its provider-aware auth path"
assert_has 'claude | hermes | openclaw | pi' "pi must expose its Telegram channel option"
assert_has 'iso_default="sandboxed"' \
  "wizard-created pi agents must default to sandboxed isolation (via the isolation picker)"
assert_has '--isolation=$isolation' \
  "create must forward the chosen isolation tier"

assert_has 'provider" == "openrouter"' "openrouter provider must trigger a model prompt"
assert_has 'openrouter needs a model' "openrouter model must be required (empty rejected)"
assert_has '--model=$pi_model' "chosen pi model must be pinned at create via --model"

echo "PASS: init wizard exposes and provisions pi through the guarded paths"
