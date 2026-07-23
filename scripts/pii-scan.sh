#!/usr/bin/env bash
# PII denylist scanner (DIVE-1774).
#
# HARD RULE gate: fail if any candidate token in the scanned text SHA-256-matches
# an entry in the denylist. The denylist stores only hashes, never plaintext, so
# no real identifier is committed to this public repo. Matching is exact-hash, so
# the gate has zero false positives against curated entries.
#
# Reads text from the files given as args, or from stdin. Exits:
#   0  clean
#   1  one or more denylisted identifiers found
#   2  usage / missing denylist
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DENYLIST="${PII_DENYLIST:-$HERE/../.github/pii-denylist.txt}"

if [[ ! -f "$DENYLIST" ]]; then
  echo "pii-scan: denylist not found: $DENYLIST" >&2
  exit 2
fi

# Load hashes (strip trailing comments + whitespace, lowercase) into a set.
declare -A DENY
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | tr -d '[:space:]' | tr 'A-F' 'a-f')"
  [[ -z "$line" ]] && continue
  DENY["$line"]=1
done < "$DENYLIST"

if [[ $# -gt 0 ]]; then
  TEXT="$(cat "$@")"
else
  TEXT="$(cat)"
fi

hits=0
check() {
  local tok="$1" label="$2"
  [[ -z "$tok" ]] && return
  local h; h="$(printf '%s' "$tok" | sha256sum | cut -d' ' -f1)"
  if [[ -n "${DENY[$h]:-}" ]]; then
    echo "PII-DENYLIST HIT ($label): sha256=$h" >&2
    hits=$((hits + 1))
  fi
}

# Candidate: emails (lowercased).
while IFS= read -r tok; do
  check "$(printf '%s' "$tok" | tr 'A-Z' 'a-z')" email
done < <(grep -oiE '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' <<<"$TEXT" || true)

# Candidate: digit runs 7-15 (telegram ids, unformatted phones).
while IFS= read -r tok; do
  check "$tok" digits
done < <(grep -oE '[0-9]{7,15}' <<<"$TEXT" || true)

# Candidate: digit runs 7-15 after stripping phone separators (formatted phones).
STRIPPED="$(printf '%s' "$TEXT" | tr -d ' ()+.-')"
while IFS= read -r tok; do
  check "$tok" digits-normalized
done < <(grep -oE '[0-9]{7,15}' <<<"$STRIPPED" || true)

if [[ $hits -gt 0 ]]; then
  echo "pii-scan: $hits denylisted identifier(s) found. Never put real user ids/emails/phones in" >&2
  echo "         public artifacts; use placeholders (<user-id>, 1234567890). See CLAUDE.md." >&2
  exit 1
fi
echo "pii-scan: clean"
