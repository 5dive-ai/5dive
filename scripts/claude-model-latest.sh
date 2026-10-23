#!/usr/bin/env bash
# claude-model-latest.sh — is model_latest still the newest Claude per family? (DIVE-6788)
#
# A seat follows each release on its own once `agent _float_models` has moved it
# to the bare alias, but a NEW seat's first boot, the per-model effort keys and
# the BYO anthropic pins all read model_latest in src/lib/models.sh. That table
# missed the 5.5 releases for a week because nothing watched it (the codex id
# had codex-model-latest.sh; the Claude ids had nothing). OpenRouter's public
# catalog (keyless) lists Anthropic's models as anthropic/claude-<family>-<ver>,
# dotted: claude-sonnet-5-5 <-> anthropic/claude-sonnet-5.5, and a dated id
# (claude-haiku-4-5-20251001) is version 4.5. Only plain ids count: `:batch`,
# `-fast` and other suffixed variants are not a new default.
#
#   scripts/claude-model-latest.sh [--catalog=<file>]
#
# Prints one line per family, `<family> current=<id> latest=<slug>`, and one
# `new-family latest=<slug>` line for a claude-<name>-<ver> whose <name> is no
# family of ours. A family absent from the catalog prints `latest=none` and is
# not an error (fable was not always listed). rc 0 = every family is current;
# rc 1 = something newer exists; rc 2 = could not read the table or the catalog.
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
families="$(model_families 2>/dev/null)"
[[ -n "$families" ]] || { echo "model_families is empty" >&2; exit 2; }

if [[ -n "$catalog_file" ]]; then
  json="$(cat "$catalog_file" 2>/dev/null)" || { echo "cannot read $catalog_file" >&2; exit 2; }
else
  json="$(curl -fsS --max-time 30 https://openrouter.ai/api/v1/models)" \
    || { echo "could not fetch the OpenRouter catalog" >&2; exit 2; }
fi
# Plain anthropic/claude-<name>-<version> ids, as "<name> <version>".
plain="$(jq -r '.data[]?.id // empty' <<<"$json" 2>/dev/null \
  | sed -n 's#^anthropic/claude-\([a-z][a-z]*\)-\([0-9][0-9]*\(\.[0-9][0-9]*\)*\)$#\1 \2#p')"
[[ -n "$plain" ]] || { echo "no anthropic/claude-<family>-<version> id in the catalog" >&2; exit 2; }

rc=0
while read -r fam; do
  id="$(model_latest "$fam")"
  # claude-<fam>-<a>[-<b>][-<yyyymmdd>] -> <a>[.<b>]
  ver="${id#"claude-$fam-"}"
  ver="$(sed -E 's/-[0-9]{8}$//; s/-/./g' <<<"$ver")"
  [[ "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]] \
    || { echo "model_latest $fam '$id' is not a claude-$fam-<version> id" >&2; exit 2; }
  up="$(awk -v f="$fam" '$1 == f { print $2 }' <<<"$plain" | sort -V | tail -1)"
  if [[ -z "$up" ]]; then
    echo "$fam current=$id latest=none"
    continue
  fi
  newest="$(printf '%s\n%s\n' "$ver" "$up" | sort -V | tail -1)"
  echo "$fam current=$id latest=anthropic/claude-$fam-$newest"
  [[ "$newest" == "$ver" ]] || rc=1
done <<<"$families"

while read -r name; do
  [[ -n "$name" ]] || continue
  grep -qxF -- "$name" <<<"$families" && continue
  up="$(awk -v f="$name" '$1 == f { print $2 }' <<<"$plain" | sort -V | tail -1)"
  echo "new-family latest=anthropic/claude-$name-$up"
  rc=1
done < <(awk '{ print $1 }' <<<"$plain" | sort -u)
exit "$rc"
