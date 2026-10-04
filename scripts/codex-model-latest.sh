#!/usr/bin/env bash
# codex-model-latest.sh — is codex_model_default still the newest GPT Sol? (DIVE-5503)
#
# Codex has no floating "latest Sol" alias, so a new codex seat's default is a
# pinned id in src/lib/models.sh. This keeps it from rotting silently: OpenRouter's
# public model catalog (keyless) lists OpenAI's models under the same ids Codex
# takes (`openai/gpt-6.1-sol` <-> `gpt-6.1-sol`). Only plain `gpt-<version>-sol`
# counts: `-pro`, dated snapshots and `:batch` variants are not a new default.
#
#   scripts/codex-model-latest.sh [--catalog=<file>]
#
# Prints `current=<id> latest=<id>`. rc 0 = current is the newest; rc 1 = a newer
# Sol exists (latest= names it); rc 2 = could not read the pin or the catalog.
# --catalog reads a saved catalog JSON instead of fetching (the test seam).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
catalog_file=""
for a in "$@"; do
  case "$a" in
    --catalog=*) catalog_file="${a#--catalog=}" ;;
    *) echo "usage: $0 [--catalog=<file>]" >&2; exit 2 ;;
  esac
done

# shellcheck source=../src/lib/models.sh
source "$here/src/lib/models.sh" 2>/dev/null || { echo "cannot read src/lib/models.sh" >&2; exit 2; }
current="$(codex_model_default 2>/dev/null)"
[[ "$current" =~ ^gpt-([0-9]+(\.[0-9]+)*)-sol$ ]] \
  || { echo "codex_model_default '$current' is not a gpt-<version>-sol id" >&2; exit 2; }
current_ver="${BASH_REMATCH[1]}"

if [[ -n "$catalog_file" ]]; then
  json="$(cat "$catalog_file" 2>/dev/null)" || { echo "cannot read $catalog_file" >&2; exit 2; }
else
  json="$(curl -fsS --max-time 30 https://openrouter.ai/api/v1/models)" \
    || { echo "could not fetch the OpenRouter catalog" >&2; exit 2; }
fi
latest_ver="$(jq -r '.data[]?.id // empty' <<<"$json" 2>/dev/null \
  | sed -n 's#^openai/gpt-\([0-9][0-9]*\(\.[0-9][0-9]*\)*\)-sol$#\1#p' | sort -V | tail -1)"
[[ -n "$latest_ver" ]] || { echo "no openai/gpt-<version>-sol id in the catalog" >&2; exit 2; }

newest="$(printf '%s\n%s\n' "$current_ver" "$latest_ver" | sort -V | tail -1)"
echo "current=$current latest=gpt-${newest}-sol"
[[ "$newest" == "$current_ver" ]] && exit 0
exit 1
