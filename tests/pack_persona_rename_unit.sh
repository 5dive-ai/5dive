#!/usr/bin/env bash
# DIVE-2599 isolated unit harness for pack-import persona renaming.
#
# Registry slugs resolve to the same staged tarball path as local archives, and
# cmd_import calls _pack_rename_persona once after that convergence. This grades
# the shared helper against every file it rewrites, including the reported
# contraction corruption and adjacent matches that share a delimiter.
# Run: bash tests/pack_persona_rename_unit.sh
set -uo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit
SRC=src

TMP="$(mktemp -d /tmp/pack-persona-rename-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  source "$SRC/$f"
done
# cmd_pack.sh is function-defs-only at source time.
# shellcheck source=/dev/null
source "$SRC/cmd_pack.sh"

set +e
PASS=0; FAIL=0
ok_()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad_() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has() {
  if grep -qF -- "$2" "$1"; then ok_ "$3"; else bad_ "$3 (missing [$2] in $1)"; fi
}
hasnt() {
  if grep -qF -- "$2" "$1"; then bad_ "$3 (unexpected [$2] in $1)"; else ok_ "$3"; fi
}

echo "== DIVE-2599 pack persona rename boundaries =="
STAGE="$TMP/stage"
mkdir -p "$STAGE/memory"

fixture() {
  cat <<'EOF'
# Don
You are Don. Don's brief calls the slug don twice: don don.
People don't buy rooted documents from surface-level vendors.
People don’t accept naive replacements either.
EOF
}

for f in "$STAGE/CLAUDE.md" "$STAGE/card.md" "$STAGE/persona.yaml" "$STAGE/memory/reference.md"; do
  fixture > "$f"
done
fixture > "$STAGE/unrelated.txt"

_pack_rename_persona "$STAGE" don zed

for f in "$STAGE/CLAUDE.md" "$STAGE/card.md" "$STAGE/persona.yaml" "$STAGE/memory/reference.md"; do
  has "$f" "# Zed" "$(basename "$f"): display name renamed"
  has "$f" "You are Zed. Zed's brief calls the slug zed twice: zed zed." \
    "$(basename "$f"): display, possessive and adjacent slug matches renamed"
  has "$f" "People don't buy rooted documents from surface-level vendors." \
    "$(basename "$f"): ASCII contraction and embedded substrings preserved"
  has "$f" "People don’t accept naive replacements either." \
    "$(basename "$f"): curly-apostrophe contraction preserved"
  hasnt "$f" "zed't" "$(basename "$f"): reported corruption absent"
done

has "$STAGE/unrelated.txt" "# Don" "files outside the persona set are untouched"

# A replacement may itself contain the old short slug. The matcher must walk
# the original text once, not recursively expand its own output.
RECUR="$TMP/non-recursive"
mkdir -p "$RECUR"
printf 'A a.\n' > "$RECUR/CLAUDE.md"
_pack_rename_persona "$RECUR" a a-one
has "$RECUR/CLAUDE.md" "A-one a-one." "replacement text is not processed recursively"
hasnt "$RECUR/CLAUDE.md" "a-one-one" "short old slug does not expand inside the new name"

# Wiring guard: both archive and registry resolution happen before the one
# shared rename call. This prevents a future route-specific copy from bypassing
# the behaviour exercised above.
IMPORT_BODY=$(sed -n '/^cmd_import()/,/^}/p' "$SRC/cmd_pack.sh")
# shellcheck disable=SC2016
CALLS=$(grep -c '_pack_rename_persona "\$stage" "\$orig_name" "\$as"' <<<"$IMPORT_BODY")
if [[ "$CALLS" == 1 ]]; then ok_ "cmd_import has one shared post-resolution rename call"
else bad_ "cmd_import shared rename wiring (want 1 call, got $CALLS)"; fi

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
