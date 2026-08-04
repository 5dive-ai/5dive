#!/usr/bin/env bash
# DIVE-2565 isolated unit harness for the single-file agent export (AGENTS.md).
#
# Sources src/ libs directly (no root, no network, no agent user) and grades the
# two PURE halves of the feature against a hand-built pack stage:
#   1. _agents_md_render  — stage -> one markdown file (frontmatter + persona
#      body + skills note + fenced memory sections).
#   2. _agents_md_explode — that file -> a v1 pack stage again.
# The round-trip is the real assertion: import reuses cmd_import's existing path
# on the re-tarred stage, so if explode reconstructs a faithful v1 stage the rest
# of the import is already covered by the tarball tests.
# Run: bash tests/pack_agents_md_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NOTE the absence of 2>/dev/null —
# redirecting the source's stderr also swallows the helper's own stderr payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/agents-md-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# cmd_pack.sh is function-defs-only at source time.
# shellcheck source=/dev/null
source "$SRC/cmd_pack.sh"

JSON_MODE=1
set +e   # header.sh enabled `set -e`; tests deliberately probe non-zero paths

PASS=0; FAIL=0
ok_()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad_()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { if [[ "$2" == "$3" ]]; then ok_ "$1"; else bad_ "$1 (want [$3] got [$2])"; fi; }
truthy(){ if (( $2 == 0 )); then ok_ "$1"; else bad_ "$1"; fi; }

# ---------------------------------------------------------------- fixtures ---
# Persona body deliberately contains markdown that could collide with the
# format: a '## Skills' heading of its own, a '---' rule, and a fenced block.
STAGE="$TMP/stage"; mkdir -p "$STAGE/memory"
cat > "$STAGE/CLAUDE.md" <<'EOF'
# Ada

You are **Ada**, a research engineer.

---

## Skills

She writes her own headings, and they must survive verbatim.

```bash
echo "a fenced block inside the persona doc"
```
EOF
# A memory fact that itself holds BOTH fence styles — the renderer must open a
# fence long enough to contain them.
cat > "$STAGE/memory/reference_thing.md" <<'EOF'
---
name: reference_thing
description: a reference fact
metadata:
  type: reference
---

Body with a fence:

```
inner backticks
```

~~~~~
inner tildes
~~~~~
EOF
cat > "$STAGE/memory/project_other.md" <<'EOF'
---
name: project_other
description: a project fact
metadata:
  type: project
---

Second fact.
EOF
# Hooks are present in the source stage on purpose: the single-file format must
# drop them, and the drop must be observable.
printf 'not-really-a-png' > "$STAGE/avatar.png"   # presence is what the renderer reads
jq -n '{
  packFormat: 1, agentName: "ada", createdWith: "0.99.0",
  includes: { memory: "distilled", persona: true },
  config: { type: "claude", isolation: "standard", channels: "telegram",
            workdir: "/home/claude/projects/x", authProfile: "ada",
            model: "claude-opus-5", effort: "high" },
  plugins: ["telegram"], skills: ["deep-research", "code-review"],
  hooks: { PostToolUse: [{ command: "echo hi" }] }
}' > "$STAGE/manifest.json"

# ------------------------------------------------------------------ render ---
MD="$TMP/AGENTS.md"
_agents_md_render "$STAGE" > "$MD"; truthy "render exits 0" $?
truthy "render produced a file" $([[ -s "$MD" ]]; echo $?)

check "frontmatter opens on line 1" "$(head -1 "$MD")" "---"
truthy "frontmatter carries agentsMdFormat" $(grep -qx 'agentsMdFormat: 1' "$MD"; echo $?)
truthy "frontmatter carries the type (the ONE field that made packs claude-only)" \
  $(grep -qx 'type: "claude"' "$MD"; echo $?)
truthy "frontmatter carries the model"   $(grep -qx 'model: "claude-opus-5"' "$MD"; echo $?)
truthy "frontmatter lists skills as a block list" $(grep -qx '  - "deep-research"' "$MD"; echo $?)
truthy "hooks are declared dropped, not omitted" $(grep -q '^hooks: dropped' "$MD"; echo $?)
# The avatar is a PNG this format cannot carry. Dropping it is fine; dropping it
# SILENTLY is the one thing the format forbids, so grade the DECLARATION — with
# both arms, or "says dropped" would also pass on a stage that has no avatar.
truthy "an avatar present in the stage is declared dropped, not omitted" $(grep -q "^avatar: dropped" "$MD"; echo $?)
truthy "the file STATES that skills are names not bodies" \
  $(grep -q 'carries their NAMES, not' "$MD"; echo $?)
truthy "memory sections are human-readable headings" \
  $(grep -qx '## memory/reference_thing.md' "$MD"; echo $?)
# Non-vacuity for the tripwire below: the fixture really does hold both fences.
truthy "fixture memory really contains an inner ~~~~~ fence" \
  $(grep -qx '~~~~~' "$STAGE/memory/reference_thing.md"; echo $?)

# ----------------------------------------------------------------- detect ----
truthy "_agents_md_is accepts our own export" $(_agents_md_is "$MD"; echo $?)
printf -- '---\nname: notmine\n---\n\nhello\n' > "$TMP/other.md"
_agents_md_is "$TMP/other.md"; check "_agents_md_is rejects a foreign frontmatter doc" "$?" "1"
printf '# plain\n\nno frontmatter\n' > "$TMP/plain.md"
_agents_md_is "$TMP/plain.md"; check "_agents_md_is rejects a plain markdown file" "$?" "1"
_agents_md_is "$TMP/nope.md"; check "_agents_md_is rejects a missing file" "$?" "1"

# ---------------------------------------------------------------- explode ----
OUT="$TMP/out"
_agents_md_explode "$MD" "$OUT"; truthy "explode exits 0" $?
truthy "explode wrote a manifest" $([[ -f "$OUT/manifest.json" ]]; echo $?)

check "packFormat round-trips" "$(jq -r '.packFormat' "$OUT/manifest.json")" "1"
check "agentName round-trips"  "$(jq -r '.agentName' "$OUT/manifest.json")" "ada"
check "type round-trips"       "$(jq -r '.config.type' "$OUT/manifest.json")" "claude"
check "model round-trips"      "$(jq -r '.config.model' "$OUT/manifest.json")" "claude-opus-5"
check "effort round-trips"     "$(jq -r '.config.effort' "$OUT/manifest.json")" "high"
check "isolation round-trips"  "$(jq -r '.config.isolation' "$OUT/manifest.json")" "standard"
check "channels round-trips"   "$(jq -r '.config.channels' "$OUT/manifest.json")" "telegram"
check "workdir round-trips"    "$(jq -r '.config.workdir' "$OUT/manifest.json")" "/home/claude/projects/x"
check "memory mode round-trips as the value cmd_import accepts" \
  "$(jq -r '.includes.memory' "$OUT/manifest.json")" "distilled"
check "skills round-trip in order" \
  "$(jq -rc '.skills' "$OUT/manifest.json")" '["deep-research","code-review"]'
check "plugins round-trip" "$(jq -rc '.plugins' "$OUT/manifest.json")" '["telegram"]'
# The security half: hooks were in the source stage and must NOT survive.
check "hooks did NOT survive the single-file round-trip" \
  "$(jq -rc '.hooks' "$OUT/manifest.json")" '{}'

# The persona doc is what a foreign harness actually executes — byte-identical or
# the format is a lossy rewrite, not an export.
if diff -q "$STAGE/CLAUDE.md" "$OUT/CLAUDE.md" >/dev/null 2>&1; then
  ok_ "persona doc is byte-identical through render->explode"
else
  bad_ "persona doc DIFFERS through render->explode"; diff "$STAGE/CLAUDE.md" "$OUT/CLAUDE.md" | head -20
fi

for m in reference_thing.md project_other.md; do
  if diff -q "$STAGE/memory/$m" "$OUT/memory/$m" >/dev/null 2>&1; then
    ok_ "memory/$m is byte-identical (fence containment holds)"
  else
    bad_ "memory/$m DIFFERS"; diff "$STAGE/memory/$m" "$OUT/memory/$m" | head -20
  fi
done

# ------------------------------------------------------- traversal refusal ---
# The memory filename comes off a sentinel in a file that may have crossed a
# trust boundary, and it becomes a path. A hostile name must be refused — and the
# arm is differential: a CLEAN name in the same file must still land, otherwise
# "no file escaped" would also be true of a parser that simply did nothing.
EVIL="$TMP/evil.md"
{
  printf -- '---\nagentsMdFormat: 1\npackFormat: 1\nname: "x"\ntype: "claude"\n'
  printf 'includesMemory: "distilled"\nskills: []\nplugins: []\n---\n\nbody\n\n'
  printf '%s\n# Memory\n\n' "$AGENTS_MD_S_MEMORY"
  printf '<!-- 5dive:memory-file: ../../../../tmp/pwned-%s.md -->\n' "$$"
  printf '## memory/evil\n\n~~~~~\nowned\n~~~~~\n\n'
  printf '<!-- 5dive:memory-file: clean_fact.md -->\n'
  printf '## memory/clean_fact.md\n\n~~~~~\nfine\n~~~~~\n'
} > "$EVIL"
EOUT="$TMP/eout"
_agents_md_explode "$EVIL" "$EOUT"; truthy "explode of a hostile file still exits 0" $?
truthy "traversal target was NOT written" $([[ ! -e "/tmp/pwned-$$.md" ]]; echo $?)
truthy "LIVENESS: the clean fact in the SAME file WAS written" \
  $([[ -f "$EOUT/memory/clean_fact.md" ]]; echo $?)
truthy "hostile section body did not leak into the clean fact" \
  $(! grep -q owned "$EOUT/memory/clean_fact.md" 2>/dev/null; echo $?)
rm -f "/tmp/pwned-$$.md"

# ------------------------------------------------------------ no-memory arm ---
# A config-only export must produce a file with NO memory sections at all, and
# explode must report memory:false so cmd_import takes its config-pack branch.
S2="$TMP/stage2"; mkdir -p "$S2"
cp "$STAGE/CLAUDE.md" "$S2/CLAUDE.md"
jq -n '{ packFormat: 1, agentName: "bo", createdWith: "0.99.0",
         includes: { memory: false, persona: false },
         config: { type: "codex", isolation: "standard", channels: "none",
                   workdir: null, authProfile: null, model: null, effort: null },
         plugins: [], skills: [], hooks: {} }' > "$S2/manifest.json"
MD2="$TMP/AGENTS2.md"; _agents_md_render "$S2" > "$MD2"
truthy "config-only export has NO memory sentinel" \
  $(! grep -qxF "$AGENTS_MD_S_MEMORY" "$MD2"; echo $?)
truthy "config-only export has NO skills section (there are none)" \
  $(! grep -qxF "$AGENTS_MD_S_SKILLS" "$MD2"; echo $?)
truthy "skills: [] renders inline (valid YAML for an empty seq)" \
  $(grep -qx 'skills: \[\]' "$MD2"; echo $?)
truthy "a stage with NO avatar says none, not dropped (differential arm)" $(grep -qx "avatar: none" "$MD2"; echo $?)
O2="$TMP/out2"; _agents_md_explode "$MD2" "$O2"
check "a non-claude type survives (the whole point)" \
  "$(jq -r '.config.type' "$O2/manifest.json")" "codex"
check "config-only reports memory:false, so import takes the config-pack branch" \
  "$(jq -r '.includes.memory' "$O2/manifest.json")" "false"
check "null model stays null (not the string \"null\")" \
  "$(jq -r '.config.model' "$O2/manifest.json")" "null"
truthy "no memory dir materialised" $([[ ! -d "$O2/memory" ]]; echo $?)

# ------------------------------------------------- plugins as an OBJECT map ---
# The fixture above uses an array, which is the shape a hand-written manifest
# takes. A REAL agent's settings.json carries enabledPlugins as an OBJECT
# ({"telegram@5dive-plugins":true}) — an array-only parse dropped it silently,
# and only a live export surfaced that. Grade the real shape.
S3="$TMP/stage3"; mkdir -p "$S3"; printf '# Bo\n' > "$S3/CLAUDE.md"
jq -n '{ packFormat: 1, agentName: "bo", createdWith: "0.99.0",
         includes: { memory: false, persona: false },
         config: { type: "claude", isolation: "admin", channels: "telegram",
                   workdir: "/w", authProfile: null, model: "opus", effort: "xhigh" },
         plugins: { "telegram@5dive-plugins": true }, skills: [], hooks: {} }' > "$S3/manifest.json"
MD3="$TMP/AGENTS3.md"; _agents_md_render "$S3" > "$MD3"
O3="$TMP/out3"; _agents_md_explode "$MD3" "$O3"
check "an OBJECT-map plugins block survives the round-trip" \
  "$(jq -rc '.plugins' "$O3/manifest.json")" '{"telegram@5dive-plugins":true}'
check "and stays non-empty, so cmd_import's length>0 branch still fires" \
  "$(jq -r '.plugins | length' "$O3/manifest.json")" "1"
check "a bare model ALIAS survives verbatim (import resolves it, not us)" \
  "$(jq -r '.config.model' "$O3/manifest.json")" "opus"

# ------------------------------------------------------------------ to-pack ---
TGZ=$(_agents_md_to_pack "$MD"); truthy "_agents_md_to_pack exits 0" $?
truthy "to_pack wrote a tarball" $([[ -s "$TGZ" ]]; echo $?)
# cmd_import always mktemp -d's the stage before calling this; tar -C needs it.
mkdir -p "$TMP/x"
truthy "the tarball is what _pack_safe_extract accepts" \
  $(_pack_safe_extract "$TGZ" "$TMP/x" >/dev/null 2>&1; echo $?)
check "extracted manifest is the same one" "$(jq -r '.agentName' "$TMP/x/manifest.json")" "ada"
rm -f "$TGZ"

# ------------------------------------------ DIVE-2583: the skills statement ---
# The old text asserted "on a harness with no skills directory (codex, opencode)
# NONE are installed". Both halves are gradable WITHOUT a codex seat, and neither
# is graded by looking for words: the claim is a PREDICATE over SKILLS_INSTALL_DIR,
# so run the predicate. (DIVE-2568 shipped three findings where a string survived
# dead code — a grep for the sentence would have passed on either wording.)

# 1. The category the sentence named is empty. Decided by the resolver every
#    install site calls, over every key in the map.
# NB: grade the MAP here, not the resolver — `${m[$k]:-default}` substitutes on
# EMPTY as well as unset, so a resolver-side probe can never observe a type that
# was mapped to "". Reading the array directly is the only way this arm can red.
_empty=""; _swept=0; _disagree=""
for _t in "${!SKILLS_INSTALL_DIR[@]}"; do
  [[ -n "${SKILLS_INSTALL_DIR[$_t]}" ]] || _empty="$_empty $_t"
  [[ "$(skills_install_dir "$_t")" == "${SKILLS_INSTALL_DIR[$_t]}" ]] || _disagree="$_disagree $_t"
  _swept=$((_swept + 1))
done
check "no known type is mapped to an empty skills dir" "$_empty" ""
check "the resolver returns the mapped value for every known type" "$_disagree" ""
# ...and that sweep is only worth anything if it actually swept. A map that lost
# its entries would satisfy the arm above vacuously.
truthy "the sweep was non-vacuous (every mapped type visited)" \
  $([[ "$_swept" -ge 8 && "$_swept" -eq "${#SKILLS_INSTALL_DIR[@]}" ]]; echo $?)
check "codex — the type the old text called dir-less — maps to a real dir" \
  "$(skills_install_dir codex)" ".agents/skills"
check "opencode likewise" "$(skills_install_dir opencode)" ".agents/skills"
# The resolver is TOTAL: an unmapped type does not get "no skills directory",
# it gets the fallback. That is why the category cannot be non-empty.
check "an unknown type falls back rather than resolving to nothing" \
  "$(skills_install_dir definitely-not-a-type)" ".claude/skills"

# 2. The rendered sentence is DERIVED from that resolver, not copied from it.
#    Render once per mapped type and require the dir in the prose to EQUAL what
#    the installer would compute. A hardcoded string passes for at most one type;
#    this arm only goes green if the text moves with the map.
_S83="$TMP/s2583"; _bad=""; _rendered=0
for _t in "${!SKILLS_INSTALL_DIR[@]}"; do
  rm -rf "$_S83"; mkdir -p "$_S83"
  printf '# A\n\nbody\n' > "$_S83/CLAUDE.md"
  jq -n --arg t "$_t" '{ packFormat: 1, agentName: "ada", createdWith: "0.99.0",
     includes: { memory: false, persona: true },
     config: { type: $t, isolation: "admin", channels: "telegram", workdir: "/w",
               authProfile: null, model: "opus", effort: "high" },
     plugins: [], skills: ["deep-research"], hooks: {} }' > "$_S83/manifest.json"
  _md83="$TMP/A-$_t.md"; _agents_md_render "$_S83" > "$_md83" || { _bad="$_bad $_t(render)"; continue; }
  _got=$(grep -oE '~/[A-Za-z0-9._/-]+/<skill>/' "$_md83" | head -1)
  _got="${_got#\~/}"; _got="${_got%/<skill>/}"
  [[ "$_got" == "$(skills_install_dir "$_t")" ]] || _bad="$_bad $_t(said:${_got:-none})"
  _rendered=$((_rendered + 1))
done
check "the rendered skills dir equals the resolver's answer, for every type" "$_bad" ""
truthy "…and every mapped type was actually rendered (arm above is not vacuous)" \
  $([[ "$_rendered" -eq "${#SKILLS_INSTALL_DIR[@]}" ]]; echo $?)

# 3. The two directions are stated separately, and the permissive one is gone.
#    Graded on a CODEX render — the exact reader the old text misled.
MD83="$TMP/A-codex.md"
truthy "a codex export names .agents/skills as where an import lands a body" \
  $(grep -q '`~/.agents/skills/<skill>/`' "$MD83"; echo $?)
truthy "the file no longer claims any harness has no skills directory" \
  $(! grep -qi 'no skills directory' "$MD83"; echo $?)
truthy "nor that NONE are installed" $(! grep -q 'NONE are installed' "$MD83"; echo $?)
# Negative arms need a liveness partner or they pass on an empty file: the
# section must still be there, saying the export-direction truth.
truthy "the Skills section still renders (negatives above are not vacuous)" \
  $(grep -qx '## Skills' "$MD83"; echo $?)
truthy "export direction: THIS FILE installs nothing, on any harness" \
  $(grep -q 'own installs nothing, on any harness' "$MD83"; echo $?)
truthy "import direction is named as a separate mechanism" \
  $(grep -q '5dive agent import` re-resolves' "$MD83"; echo $?)
# 4. And the load half stays a non-promise: we install a body, we do not claim
#    the harness reads it. NB codex HAS since been measured to scan
#    $HOME/.agents/skills (DIVE-2583 amendment), so the reason this arm exists is
#    not "nobody has looked" — it is that 5dive performs no runtime check, and
#    every other harness (opencode included) is still unmeasured.
truthy "the text states landing, not loading (5dive does not verify the load at runtime)" \
  $(grep -q 'does not verify it' "$MD83"; echo $?)

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
(( FAIL == 0 ))
