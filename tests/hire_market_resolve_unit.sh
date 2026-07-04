#!/usr/bin/env bash
# DIVE-1007 isolated unit harness for `_hire_resolve_market` (DIVE-993 hire
# --from-market ranking). Sources src/ libs directly (no root, no network) and
# STUBS `_marketplace_index` with a fixture registry so the pure ranking logic
# is exercised deterministically:
#   1. rarity-first pick   — a legendary beats a higher-skill-count rare.
#   2. completeness tiebreak within the same rarity — more skills wins, then
#      bundled memory breaks a skill-count tie.
#   3. match surfaces       — slug / character / name / tags all resolve.
#   4. no match             -> empty output, rc 0 (caller maps empty -> not-found).
#   5. registry unreachable -> rc 2 (index fetch fails OR index has no .packs).
# Run: bash tests/hire_market_resolve_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hire-market-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# cmd_hire.sh is function-defs-only at source time (also sets $_hire_rarity_rank).
# shellcheck source=/dev/null
source "$SRC/cmd_hire.sh"

set +e   # header.sh enabled `set -e`; tests deliberately probe non-zero paths

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ---- fixture registry ------------------------------------------------------
# The whole point of the stub: `_hire_resolve_market` normally curls the live
# marketplace index. We replace `_marketplace_index` with a cat of a fixture so
# the ranking (rarity DESC, then skill count, then bundled memory) is pinned.
#
# For role "engineer" there are two matches by `character`:
#   - eng-rare   : rare, 5 skills   (higher skill count)
#   - eng-legend : legendary, 2 skills, includesMemory
# Rarity must win, so eng-legend is picked despite fewer skills — the headline
# "rarity-first" assertion.
#
# For role "writer" two LEGENDARY packs tie on rarity; the completeness
# tiebreak (skills, then memory) must pick the more-complete one.
#   - writer-a : legendary, 3 skills, includesMemory
#   - writer-b : legendary, 3 skills, no memory   -> a wins on memory tiebreak
cat > "$TMP/index.json" <<'JSON'
{
  "packs": [
    { "slug": "eng-rare",   "character": "Engineer", "rarity": "rare",
      "skills": ["a","b","c","d","e"] },
    { "slug": "eng-legend", "character": "Staff Engineer", "rarity": "legendary",
      "skills": ["x","y"], "includesMemory": true },
    { "slug": "writer-a",   "character": "Writer", "rarity": "legendary",
      "skills": ["p","q","r"], "includesMemory": true },
    { "slug": "writer-b",   "character": "Writer", "rarity": "legendary",
      "skills": ["p","q","r"] },
    { "slug": "atlas",      "character": "Cartographer", "name": "Atlas",
      "rarity": "epic", "tags": ["maps","gis"], "skills": ["m"] }
  ]
}
JSON

# Stub the network fetch. Overriding after sourcing is what the task asks for.
_marketplace_index() { cat "$TMP/index.json"; }

# ---- 1. rarity-first pick (legendary beats a higher-skill rare) ------------
OUT=$(_hire_resolve_market "engineer"); RC=$?
SLUG=$(printf '%s' "$OUT" | cut -f1)
[[ $RC -eq 0 && "$SLUG" == "eng-legend" ]] \
  && ok_t "rarity-first: legendary beats higher-skill rare" \
  || bad_t "rarity-first pick" "rc=$RC out=$OUT"
# The TSV carries slug<TAB>character<TAB>rarity for the pick.
[[ "$(printf '%s' "$OUT" | cut -f3)" == "legendary" ]] \
  && ok_t "emits the picked pack's rarity in the TSV" \
  || bad_t "tsv rarity field" "$OUT"
[[ "$(printf '%s' "$OUT" | cut -f2)" == "Staff Engineer" ]] \
  && ok_t "emits the picked pack's character in the TSV" \
  || bad_t "tsv character field" "$OUT"

# ---- 2. completeness tiebreak within the same rarity -----------------------
OUT=$(_hire_resolve_market "writer"); RC=$?
[[ $RC -eq 0 && "$(printf '%s' "$OUT" | cut -f1)" == "writer-a" ]] \
  && ok_t "same rarity: bundled memory breaks the skill-count tie" \
  || bad_t "completeness tiebreak" "rc=$RC out=$OUT"

# ---- 3. match surfaces (name + tag), case-insensitive ----------------------
[[ "$(_hire_resolve_market "ATLAS" | cut -f1)" == "atlas" ]] \
  && ok_t "matches on pack name, case-insensitively" || bad_t "name match"
[[ "$(_hire_resolve_market "gis" | cut -f1)" == "atlas" ]] \
  && ok_t "matches on a pack tag" || bad_t "tag match"
[[ "$(_hire_resolve_market "eng-rare" | cut -f1)" == "eng-rare" ]] \
  && ok_t "matches on exact slug" || bad_t "slug match"

# ---- 4. no match -> empty output, rc 0 -------------------------------------
OUT=$(_hire_resolve_market "astronaut"); RC=$?
[[ $RC -eq 0 && -z "$OUT" ]] \
  && ok_t "no match: empty output, rc 0 (caller maps to not-found)" \
  || bad_t "no-match empty" "rc=$RC out=$OUT"

# ---- 5. registry unreachable -> rc 2 ---------------------------------------
# 5a. fetch itself fails (curl non-zero).
_marketplace_index() { return 1; }
_hire_resolve_market "engineer" >/dev/null 2>&1; RC=$?
[[ $RC -eq 2 ]] \
  && ok_t "index fetch failure -> rc 2 (registry unreachable)" \
  || bad_t "unreachable rc" "rc=$RC"

# 5b. fetch returns garbage with no .packs -> also rc 2 (fail closed).
_marketplace_index() { printf '%s' '{"oops":true}'; }
_hire_resolve_market "engineer" >/dev/null 2>&1; RC=$?
[[ $RC -eq 2 ]] \
  && ok_t "index without .packs -> rc 2 (fail closed)" \
  || bad_t "no-packs rc" "rc=$RC"

echo
printf 'DIVE-1007 hire --from-market resolve: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
