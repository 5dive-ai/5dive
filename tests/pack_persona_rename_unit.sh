#!/usr/bin/env bash
# DIVE-2599 isolated unit harness for pack-import persona renaming.
#
# Registry slugs resolve to the same staged tarball path as local archives, and
# cmd_import calls _pack_rename_persona once after that convergence. This grades
# the shared helper against every file it rewrites, including the reported
# contraction corruption and adjacent matches that share a delimiter.
# DIVE-5900 rides here (same subject: the persona-rendered identity doc, before
# and after this rename): the rendered doc tells the agent where its card is.
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
Don't corrupt sentence-leading contractions. Don’t corrupt curly ones.
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
  has "$f" "Don't corrupt sentence-leading contractions. Don’t corrupt curly ones." \
    "$(basename "$f"): capitalized contractions preserved"
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

# DIVE-5900: the persona-rendered identity doc names the agent's card — the
# persona.yaml at the path cmd_import installs it — so "show me your card" is
# answered from it, not guessed as an A2A card. Rendered, then renamed, in
# cmd_import's order.
echo "== DIVE-5900 identity doc names the card =="
CARD="$TMP/card"; mkdir -p "$CARD"
cat > "$CARD/persona.yaml" <<'EOF'
openagent: "0.1"
id: don
name: Don
role: a growth marketer
rarity: epic
behavior: Ships one experiment a day.
voice:
  written:
    rules: [Short sentences.]
EOF
card_arms() {  # <rendered CLAUDE.md> <label>
  has "$1" "## Your card" "$2: has a 'Your card' section"
  has "$1" 'Your card is your OpenAgent persona, `~/.claude/persona.yaml`.' "$2: names the installed persona path"
  has "$1" "show your name, role, tier (epic), voice and behavior" "$2: says what to show, tier from the persona"
  has "$1" '`5dive agent avatar get <your agent name>`' "$2: names the portrait"
  has "$1" '"Card" never means an A2A agent card unless they say A2A.' "$2: rules out the A2A reading"
}
if _persona_render_claudemd "$CARD/persona.yaml" "$CARD/CLAUDE.md"; then ok_ "fixture persona renders"
else bad_ "fixture persona renders"; fi
_pack_rename_persona "$CARD" don zed
card_arms "$CARD/CLAUDE.md" "rendered+renamed"
has "$CARD/CLAUDE.md" "You are **Zed**, a growth marketer." "rendered doc renamed as usual"

# No tier in the persona -> no invented one.
sed -i '/^rarity:/d' "$CARD/persona.yaml"
_persona_render_claudemd "$CARD/persona.yaml" "$CARD/notier.md"
has "$CARD/notier.md" "show your name, role, tier, voice and behavior" "no rarity in the persona: no tier invented"

# Negative control: the same arms over a render with the section helper
# emptied must go red, or they grade nothing.
( _persona_card_section() { :; }
  sed -i '1a rarity: epic' "$CARD/persona.yaml"
  _persona_render_claudemd "$CARD/persona.yaml" "$CARD/mutant.md" )
P0=$PASS F0=$FAIL
card_arms "$CARD/mutant.md" "mutant" >/dev/null
MUT_RED=$((FAIL - F0)); PASS=$P0 FAIL=$F0
if [[ -s "$CARD/mutant.md" && "$MUT_RED" == 5 ]]; then ok_ "negative control: section removed -> all 5 card arms red"
else bad_ "negative control: section removed -> want 5 card arms red, got $MUT_RED"; fi

# A marketplace / partner / made agent ships its OWN CLAUDE.md and its persona as
# REGISTRY_PERSONA (never rendered): the section is appended to that doc, once.
REG="$TMP/registry"; mkdir -p "$REG"
printf '# Olivia\nYou are Olivia, a hand-written pack doc.' > "$REG/CLAUDE.md"   # no trailing newline
sed 's/^id: don/id: olivia/' "$CARD/persona.yaml" > "$REG/$REGISTRY_PERSONA"
_persona_card_ensure "$REG"; _persona_card_ensure "$REG"
card_arms "$REG/CLAUDE.md" "registry pack doc"
has "$REG/CLAUDE.md" "You are Olivia, a hand-written pack doc." "registry pack doc: own text kept"
N=$(grep -cxF "## Your card" "$REG/CLAUDE.md")
if [[ "$N" == 1 ]]; then ok_ "registry pack doc: appended once across two calls"
else bad_ "registry pack doc: want 1 card section, got $N"; fi
# Already rendered from persona.yaml -> left byte-for-byte alone.
cp "$CARD/CLAUDE.md" "$CARD/before.md"; _persona_card_ensure "$CARD"
if cmp -s "$CARD/CLAUDE.md" "$CARD/before.md"; then ok_ "rendered doc: ensure is a no-op"
else bad_ "rendered doc: ensure changed it"; fi
# No persona at all -> no card to point at.
NONE="$TMP/none"; mkdir -p "$NONE"; printf '# Plain\n' > "$NONE/CLAUDE.md"
_persona_card_ensure "$NONE"
hasnt "$NONE/CLAUDE.md" "## Your card" "no persona in the pack: no card section"

# Wiring: import and the pack-sync re-render each ensure the section once.
SYNC_BODY=$(sed -n '/^_pack_sync_render_identity()/,/^}/p' "$SRC/cmd_pack.sh")
for pair in "cmd_import:$(grep -c '_persona_card_ensure "\$stage"' <<<"$(sed -n '/^cmd_import()/,/^}/p' "$SRC/cmd_pack.sh")")" \
            "pack-sync re-render:$(grep -c '_persona_card_ensure "\$stage"' <<<"$SYNC_BODY")"; do
  if [[ "${pair##*:}" == 1 ]]; then ok_ "${pair%:*} ensures the card section once"
  else bad_ "${pair%:*} card section wiring (want 1 call, got ${pair##*:})"; fi
done

# Wiring: the path the doc names is the path cmd_import installs the persona at.
IMPORT_BODY=$(sed -n '/^cmd_import()/,/^}/p' "$SRC/cmd_pack.sh")
if grep -qF 'local cdir="${AGENT_HOME_ROOT:-/home}/agent-${as}/.claude"' <<<"$IMPORT_BODY" \
   && grep -qF '"$stage/persona.yaml" "$cdir/persona.yaml"' <<<"$IMPORT_BODY"; then
  ok_ "cmd_import installs the persona at ~/.claude/persona.yaml"
else bad_ "cmd_import no longer installs the persona at ~/.claude/persona.yaml"; fi

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
