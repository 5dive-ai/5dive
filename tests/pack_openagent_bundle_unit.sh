#!/usr/bin/env bash
# DIVE-6202 isolated unit harness — `agent export --format=pack` IS an OpenAgent
# agent bundle, and `agent import` reads one `openagent export` wrote.
#
# Graded behaviourally against the shipped helpers: the staged tree, the manifest
# they write, the stage an openagent bundle is adopted into, and the import's
# secret gate. The cross-tool arms (openagent reads our pack; we read openagent's
# bundle) need the openagent CLI: set OPENAGENT_CLI=<path to bin/openagent.js>, or
# they SKIP and say so.
# Run: bash tests/pack_openagent_bundle_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/pack-openagent-bundle.XXXXXX)"
export GH_ORG=5dive-ai

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_skill.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_pack.sh"

JSON_MODE=1
set +e

PASS=0; FAIL=0; SKIP=0
ok_()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad_()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip_() { SKIP=$((SKIP+1)); printf '  SKIP %s\n' "$1"; }
check() { if [[ "$2" == "$3" ]]; then ok_ "$1"; else bad_ "$1 (want [$3] got [$2])"; fi; }
has()   { if grep -qF -- "$2" <<<"$1"; then ok_ "$3"; else bad_ "$3 (missing [$2])"; fi; }

PERSONA='openagent: "0.2"
id: quill
name: Quill
role: Release Archivist
behavior: Keeps the changelog honest.
face:
  anchor: a tidy owl in reading glasses
  ref: https://example.com/quill.png
voice:
  written:
    rules:
      - short sentences
    sample: Shipped. Logged.
'

# ------------------------------------------------- export: skill bodies -------
echo "export: skill bodies travel under skills/<id>/"
SHARED="$TMP/shared/changelog"
mkdir -p "$SHARED/scripts" "$SHARED/.git" "$SHARED/node_modules/x"
printf -- '---\nname: changelog\n---\nOne line per PR.\n' > "$SHARED/SKILL.md"
printf '#!/bin/sh\necho hi\n' > "$SHARED/scripts/collect.sh"
echo ref > "$SHARED/.git/HEAD"; echo x > "$SHARED/node_modules/x/i.js"
echo outside > "$TMP/outside.txt"; ln -s "$TMP/outside.txt" "$SHARED/escape.txt"
SDIR="$TMP/agent/.claude/skills"; mkdir -p "$SDIR/plain" "$SDIR/nobody"
ln -s "$SHARED" "$SDIR/changelog"          # skills install as symlinks
printf '# plain\n' > "$SDIR/plain/SKILL.md"
printf 'not a skill\n' > "$SDIR/nobody/README.md"
STAGE="$TMP/stage"; mkdir -p "$STAGE"
_pack_stage_skill_bodies "$SDIR" "$STAGE"
got=$(cd "$STAGE" && find skills -type f | LC_ALL=C sort | tr '\n' ' ')
check "the symlinked skill is followed; .git, node_modules, an inner symlink and a dir with no SKILL.md stay behind" \
  "$got" "skills/changelog/SKILL.md skills/changelog/scripts/collect.sh skills/plain/SKILL.md "
check "bodies are byte for byte" "$(sha256sum <"$STAGE/skills/changelog/scripts/collect.sh")" "$(sha256sum <"$SHARED/scripts/collect.sh")"

# ------------------------------------------------- export: manifest -----------
echo "export: the manifest carries the bundle keys"
printf '%s' "$PERSONA" > "$STAGE/persona.yaml"
printf '# Quill\n' > "$STAGE/CLAUDE.md"
mkdir -p "$STAGE/memory"; printf -- '---\nname: r\nmetadata:\n  type: reference\n---\nTag after green CI.\n' > "$STAGE/memory/r.md"
jq -n '{packFormat:1, agentName:"quill", createdWith:"test", includes:{memory:"distilled", memoryShape:"atoms", persona:true}, config:{type:"claude"}, plugins:[], skills:["changelog","plain"], hooks:{}}' > "$STAGE/manifest.json"
_pack_bundle_manifest "$STAGE" true
M="$STAGE/manifest.json"
check "bundle_version" "$(jq -r .bundle_version "$M")" "1"
check "openagent" "$(jq -r .openagent "$M")" "$OPENAGENT_BUNDLE_SPEC"
check "source_harness" "$(jq -r .source_harness "$M")" "5dive"
if [[ "$(jq -r .created_at "$M")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then ok_ "created_at is ISO-8601 UTC"; else bad_ "created_at: $(jq -r .created_at "$M")"; fi
check "persona" "$(jq -r .persona "$M")" "persona.yaml"
check "files lists every member but the manifest" "$(jq -r '.files | keys | join(" ")' "$M")" \
  "CLAUDE.md memory/r.md persona.yaml skills/changelog/SKILL.md skills/changelog/scripts/collect.sh skills/plain/SKILL.md"
check "each with its sha256" "$(jq -r '.files["memory/r.md"]' "$M")" "$(sha256sum <"$STAGE/memory/r.md" | cut -d' ' -f1)"
check "5dive's own keys stay" "$(jq -c '[.packFormat, .agentName, .skills]' "$M")" '[1,"quill",["changelog","plain"]]'
NOP="$TMP/nop"; mkdir -p "$NOP"; echo '{"packFormat":1}' > "$NOP/manifest.json"
_pack_bundle_manifest "$NOP" false
check "no persona, no persona key (openagent then refuses it by name)" "$(jq -r 'has("persona")' "$NOP/manifest.json")" "false"
check "the stage passes the secret tripwire, shas and all" "$(_pack_secret_tripwire "$STAGE" 2>&1; echo rc=$?)" "rc=0"

# ------------------------------------------------- import: verify -------------
echo "import: per-member sha256s"
out=$(_pack_bundle_verify "$STAGE" 2>&1)
check "a clean bundle verifies silently" "$out" ""
printf 'edited\n' >> "$STAGE/CLAUDE.md"
out=$(_pack_bundle_verify "$STAGE" 2>&1)
has "$out" "CLAUDE.md (changed)" "a changed member warns, naming it"

# ------------------------------------------------- import: adopt --------------
echo "import: an openagent bundle is adopted into a v1 stage"
OA="$TMP/oa"; mkdir -p "$OA/skills/haiku" "$OA/memory"
printf '%s' "$PERSONA" > "$OA/quill.persona.yaml"
printf -- '---\nname: haiku\n---\n5-7-5.\n' > "$OA/skills/haiku/SKILL.md"
printf 'Cut 0.49.2 today.\n' > "$OA/memory/2026-10-13.md"
jq -n '{bundle_version:1, openagent:"0.51.0", source_harness:"openclaw", created_at:"2026-10-14T05:00:00Z", persona:"quill.persona.yaml", files:{}}' > "$OA/manifest.json"
_pack_adopt_openagent_bundle "$OA"; rc=$?
check "adopt succeeds" "$rc" "0"
check "the persona is at persona.yaml" "$( [[ -f $OA/persona.yaml && ! -e $OA/quill.persona.yaml ]] && echo yes)" "yes"
check "packFormat 1, agentName = persona id, skills from skills/*/SKILL.md" \
  "$(jq -c '[.packFormat, .agentName, .skills, .hooks]' "$OA/manifest.json")" '[1,"quill",["haiku"],{}]'
check "its memory is raw (a plain copy nothing distilled)" "$(jq -c '.includes' "$OA/manifest.json")" '{"memory":"raw","memoryShape":"atoms","persona":true}'
check "the bundle's own keys stay" "$(jq -r .source_harness "$OA/manifest.json")" "openclaw"
B2="$TMP/b2"; mkdir -p "$B2"; echo '{"bundle_version":1,"persona":"gone.persona.yaml","files":{}}' > "$B2/manifest.json"
out=$(_pack_adopt_openagent_bundle "$B2" 2>&1); rc=$?
check "a bundle missing its persona is refused" "$rc" "1"; has "$out" "names no persona file" "and says so"
echo '{"bundle_version":9,"persona":"p.yaml"}' > "$B2/manifest.json"
out=$(_pack_adopt_openagent_bundle "$B2" 2>&1)
has "$out" "newer than this CLI reads" "a newer bundle version is refused by name"
echo '{"nothing":1}' > "$B2/manifest.json"
out=$(_pack_adopt_openagent_bundle "$B2" 2>&1)
has "$out" "missing packFormat" "neither a pack nor a bundle keeps the old refusal"
echo '{"bundle_version":1,"persona":"../etc/passwd","files":{}}' > "$B2/manifest.json"
out=$(_pack_adopt_openagent_bundle "$B2" 2>&1); rc=$?
check "a persona path out of the stage is refused" "$rc" "1"

# ------------------------------------------------- import: secret gate --------
echo "import: a pack with a secret is refused"
SG="$TMP/sg"; mkdir -p "$SG/memory"; printf '%s' "$PERSONA" > "$SG/persona.yaml"
printf 'notes\nkey sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz0123\n' > "$SG/memory/creds.md"
_pack_import_secret_gate "$SG" distilled 0 2>/dev/null; check "a distilled 5dive pack with a key: refused" "$?" "1"
_pack_import_secret_gate "$SG" raw 1 2>/dev/null; check "an adopted openagent bundle with a key: refused" "$?" "1"
out=$(_pack_import_secret_gate "$SG" raw 0 2>&1); rc=$?
check "a 5dive RAW backup restores with a warning" "$rc" "0"; has "$out" "RAW IMPORT" "and the warning names it"
rm "$SG/memory/creds.md"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n' > "$SG/.signing_key"
_pack_import_secret_gate "$SG" false 0 "$SG/.signing_key" 2>/dev/null; check "the stripped signing key is not a finding" "$?" "0"
check "and it is back where it was" "$(head -c 10 "$SG/.signing_key")" "-----BEGIN"

# ------------------------------------------------- cross-tool -----------------
echo "cross-tool: openagent reads our pack, we read openagent's bundle"
if [[ -n "${OPENAGENT_CLI:-}" && -f "$OPENAGENT_CLI" ]] && command -v node >/dev/null; then
  # Our pack, the way cmd_export writes it: the stage above (re-hashed after the edit), GNU tar.
  _pack_bundle_manifest "$STAGE" true
  tar -czf "$TMP/pack.tar.gz" -C "$STAGE" . 2>/dev/null
  H="$TMP/home"; mkdir -p "$H/.hermes"; echo "You are Hermes Agent." > "$H/.hermes/SOUL.md"
  out=$(HOME="$H" OPENAGENT_HOME="$H/.openagent" NO_COLOR=1 node "$OPENAGENT_CLI" import "$TMP/pack.tar.gz" --to=hermes 2>&1); rc=$?
  check "openagent import accepts a 5dive pack" "$rc" "0"; (( rc == 0 )) || printf "%s\n" "$out" | sed "s/^/       /"
  check "its skill bodies land in hermes" "$(sha256sum <"$H/.hermes/skills/changelog/scripts/collect.sh")" "$(sha256sum <"$SHARED/scripts/collect.sh")"
  check "its memory lands in hermes" "$(cat "$H/.hermes/memories/r.md" | tail -1)" "Tag after green CI."
  has "$(cat "$H/.hermes/SOUL.md")" "You are **Quill**" "and hermes answers as the persona"
  # And back: openagent export from hermes, adopted here.
  out=$(HOME="$H" OPENAGENT_HOME="$H/.openagent" NO_COLOR=1 node "$OPENAGENT_CLI" export --from=hermes --memory -o "$TMP/back.tar.gz" 2>&1); rc=$?
  check "openagent export from hermes" "$rc" "0"
  BK="$TMP/back"; mkdir -p "$BK"
  _pack_safe_extract "$TMP/back.tar.gz" "$BK"; check "our safe-extract takes openagent's tar" "$?" "0"
  check "it round-trips our members byte for byte" \
    "$(cd "$BK" && find . -type f ! -name manifest.json | sort | xargs sha256sum)" \
    "$(cd "$STAGE" && find . -type f ! -name manifest.json | sort | xargs sha256sum)"
  check "and our keys" "$(jq -c '[.packFormat,.agentName,.skills]' "$BK/manifest.json")" '[1,"quill",["changelog","plain"]]'
  # A bundle openagent made from scratch (no 5dive keys): adopted.
  H2="$TMP/home2"; mkdir -p "$H2/.openclaw/workspace/skills/haiku" "$H2/.openclaw/workspace/memory"
  printf '%s' "$PERSONA" > "$H2/quill.persona.yaml"
  HOME="$H2" OPENAGENT_HOME="$H2/.openagent" NO_COLOR=1 node "$OPENAGENT_CLI" install --to=openclaw "$H2/quill.persona.yaml" >/dev/null 2>&1
  printf -- '---\nname: haiku\n---\n5-7-5.\n' > "$H2/.openclaw/workspace/skills/haiku/SKILL.md"
  printf 'Cut 0.49.2 today.\n' > "$H2/.openclaw/workspace/memory/2026-10-13.md"
  HOME="$H2" OPENAGENT_HOME="$H2/.openagent" NO_COLOR=1 node "$OPENAGENT_CLI" export --from=openclaw --memory -o "$TMP/oa.tar.gz" >/dev/null 2>&1
  OX="$TMP/ox"; mkdir -p "$OX"; _pack_safe_extract "$TMP/oa.tar.gz" "$OX"
  check "openagent's bundle has no packFormat" "$(jq -r '.packFormat // "none"' "$OX/manifest.json")" "none"
  check "it verifies before adoption (cmd_import's order)" "$(_pack_bundle_verify "$OX" 2>&1)" ""
  _pack_adopt_openagent_bundle "$OX"
  check "adopted: persona, skills, memory where cmd_import reads them" \
    "$( [[ -f $OX/persona.yaml && -f $OX/skills/haiku/SKILL.md && -f $OX/memory/2026-10-13.md ]] && jq -c '[.packFormat,.agentName,.skills,.includes.memory]' "$OX/manifest.json")" \
    '[1,"quill",["haiku"],"raw"]'
else
  skip_ "cross-tool arms: OPENAGENT_CLI not set (path to openagent's bin/openagent.js)"
fi

echo
echo "pack_openagent_bundle: $PASS passed, $FAIL failed, $SKIP skipped"
(( FAIL == 0 ))
