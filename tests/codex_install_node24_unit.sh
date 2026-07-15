#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../src/header.sh
source "$ROOT/src/header.sh"

recipe="${TYPE_INSTALL[codex]}"

[[ "$recipe" == *"nvm install 24"* ]] || {
  echo "FAIL: codex installer must provision Node 24 before installing Codex" >&2
  exit 1
}
[[ "$recipe" != *"nvm use 24"* ]] || {
  echo "FAIL: nvm use cannot provision Node 24 on a fresh host" >&2
  exit 1
}

nvm_pos="${recipe%%nvm install 24*}"
npm_pos="${recipe%%npm install -g @openai/codex@latest*}"
(( ${#nvm_pos} < ${#npm_pos} )) || {
  echo "FAIL: Node 24 must be installed before the Codex npm package" >&2
  exit 1
}

echo "PASS: codex install recipe provisions Node 24 before Codex"
