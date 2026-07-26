#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../src/header.sh
source "$ROOT/src/header.sh"

recipe="${TYPE_INSTALL[pi]}"

[[ "$recipe" == *"nvm install 24"* ]] || {
  echo "FAIL: pi installer must provision Node 24 before installing pi" >&2
  exit 1
}
[[ "$recipe" != *"nvm use 24"* ]] || {
  echo "FAIL: nvm use cannot provision Node 24 on a fresh host (DIVE-1254 sweep)" >&2
  exit 1
}

nvm_pos="${recipe%%nvm install 24*}"
npm_pos="${recipe%%npm install -g @earendil-works/pi-coding-agent*}"
(( ${#nvm_pos} < ${#npm_pos} )) || {
  echo "FAIL: Node 24 must be installed before the pi npm package" >&2
  exit 1
}

echo "PASS: pi install recipe provisions Node 24 before pi"
