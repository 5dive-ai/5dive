#!/usr/bin/env bash
# DIVE-5205: a hired agent gets its pack's LATER skill fixes — `agent pack-sync`.
# DIVE-5211 (arms 10-19): ...and its pack's later persona.yaml and CLAUDE.md section.
#
# A pack was applied once, at import, and nothing re-applied it: every pack fix
# needed a by-hand root push per agent per box. This grades the sync on a fixture
# home (AGENT_HOME_ROOT) and a fixture registry, with the two fetchers stubbed to
# hand back locally built pack tarballs — no root, no network, no agent user:
#   - only ids the pack lists are touched; an owner-added skill is never read;
#   - a pack skill whose body still equals what the pack installed is replaced
#     when the pack changes it; one the owner EDITED is left and reported as drift;
#   - a changed agent gets a pending-restart marker (the heartbeat sweep bounces it
#     at a quiet moment), an unchanged one does not;
#   - --dry-run writes nothing; a link for ANOTHER pack is refused; the signed
#     link itself is never stored; --all walks marketplace agents only.
# Run: bash tests/pack_sync_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

TMP="$(mktemp -d /tmp/pack-sync-unit.XXXXXX)"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/registry.sh lib/agent_setup.sh cmd_skill.sh cmd_pack.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e
JSON_MODE=1
export AGENT_HOME_ROOT="$TMP/home" REGISTRY="$TMP/agents.json" PENDING_RESTART_DIR="$TMP/pending"
# The seams: fetchers hand back a local tarball; the rest is the shipped code.
FIX_PACK=""
_marketplace_fetch_pack() { local o; o=$(mktemp --suffix=.tar.gz); tar -czf "$o" -C "$FIX_PACK" . && echo "$o"; }
_pack_fetch_url() { local o; o=$(mktemp --suffix=.tar.gz); tar -czf "$o" -C "$FIX_PACK" . && echo "$o"; }
_pending_restart_mark() { mkdir -p "$PENDING_RESTART_DIR"; printf 'reason=%s\n' "$2" >"$PENDING_RESTART_DIR/$1"; }
agent_type() { registry_read | jq -r --arg n "$1" '.agents[$n].type // empty'; }
require_root() { :; }
chown() { :; }   # registry_write/_install_bundled_skill chown to root/the seat
fail() { printf 'FAIL-CALLED %s\n' "$*" >&2; return 1; }

PASS=0; FAIL=0
ok_()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad_() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
is()   { [[ "$2" == "$3" ]] && ok_ "$1" || bad_ "$1 (want [$3] got [$2])"; }

# mk_pack <dir> <skill>=<body>... — a v1 pack whose manifest lists exactly those skills.
mk_pack() {
  local dir="$1"; shift; rm -rf "$dir"; mkdir -p "$dir/skills"
  local kv ids=()
  for kv in "$@"; do
    mkdir -p "$dir/skills/${kv%%=*}"; printf '%s\n' "${kv#*=}" >"$dir/skills/${kv%%=*}/SKILL.md"; ids+=("${kv%%=*}")
  done
  printf '%s\n' "${ids[@]}" | jq -R . | jq -s '{packFormat:1, agentName:"testpack", skills:.}' >"$dir/manifest.json"
}
SK="$AGENT_HOME_ROOT/agent-maya/.claude/skills"
body() { cat "$SK/$1/SKILL.md" 2>/dev/null; }
rec()  { jq -c --arg n "${2:-maya}" ".agents[\$n].pack$1" "$REGISTRY"; }
sync() { _pack_sync_one "$1" "${2:-}" "${3:-0}" "${4:-1}"; }

# Fixture: maya was hired from marketplace pack `testpack` before this row, so
# her record names the pack but holds no skill hashes. She has an OLD copy of the
# pack's `notes` skill and an owner-added `owner-tool` the pack never listed.
mkdir -p "$SK/notes" "$SK/owner-tool"
printf 'notes v0\n' >"$SK/notes/SKILL.md"; printf 'owner tool\n' >"$SK/owner-tool/SKILL.md"
jq -n '{agents:{
  maya:{type:"claude", pack:{source:"marketplace", slug:"testpack"}},
  galina:{type:"claude"},
  frank:{type:"claude", pack:{source:"url", slug:"frankpack"}}}}' >"$REGISTRY"
owner_sha=$(_pack_tree_sha "$SK/owner-tool")

echo "== 1. first sync: add the new skill, replace the stale one, never read the owner's =="
FIX_PACK="$TMP/p1"; mk_pack "$FIX_PACK" "mail=mail v1" "notes=notes v1"
out=$(sync maya); rc=$?
is "1a rc 0" "$rc" 0
is "1b status changed" "$(jq -r .status <<<"$out")" changed
is "1c mail added" "$(jq -c .added <<<"$out")" '["mail"]'
is "1d notes updated (no record = the pack's own id)" "$(jq -c .updated <<<"$out")" '["notes"]'
is "1e mail body landed" "$(body mail)" "mail v1"
is "1f notes body replaced" "$(body notes)" "notes v1"
is "1g owner-added skill untouched" "$(_pack_tree_sha "$SK/owner-tool")" "$owner_sha"
is "1h owner-added skill not in the record" "$(rec '.skills["owner-tool"] // "none"')" '"none"'
is "1i the record holds the installed hashes" "$(rec '.skills.mail')" "\"$(_pack_tree_sha "$SK/mail")\""
[[ -f "$PENDING_RESTART_DIR/maya" ]] && ok_ "1j a restart is owed (marker, not a restart here)" || bad_ "1j no restart marker for a changed agent"
is "1k a pack with no persona/CLAUDE.md reports both absent" "$(jq -c '[.persona.status, .claudeMd.status]' <<<"$out")" '["absent","absent"]'

echo "== 2. same pack again: nothing changes, no restart =="
rm -rf "$PENDING_RESTART_DIR"
out=$(sync maya)
is "2a status unchanged" "$(jq -r .status <<<"$out")" unchanged
[[ ! -e "$PENDING_RESTART_DIR/maya" ]] && ok_ "2b no restart for an unchanged agent" || bad_ "2b restart marked for an unchanged agent"

echo "== 3. pack v2 while the owner edited one pack skill: update the rest, leave the edit =="
printf 'notes, edited by the owner\n' >"$SK/notes/SKILL.md"
FIX_PACK="$TMP/p2"; mk_pack "$FIX_PACK" "mail=mail v2" "notes=notes v2" "calendar=cal v1"
out=$(sync maya)
is "3a mail updated" "$(jq -c .updated <<<"$out")" '["mail"]'
is "3b calendar added" "$(jq -c .added <<<"$out")" '["calendar"]'
is "3c notes reported as drift" "$(jq -c .drift <<<"$out")" '["notes"]'
is "3d the owner's notes edit survives" "$(body notes)" "notes, edited by the owner"
is "3e mail v2 landed" "$(body mail)" "mail v2"
is "3f owner-added skill still untouched" "$(_pack_tree_sha "$SK/owner-tool")" "$owner_sha"

echo "== 4. --dry-run writes nothing =="
rm -rf "$PENDING_RESTART_DIR"; before=$(cat "$REGISTRY")
FIX_PACK="$TMP/p3"; mk_pack "$FIX_PACK" "mail=mail v3" "notes=notes v2" "calendar=cal v1"
out=$(sync maya "" 1)
is "4a status would-change" "$(jq -r .status <<<"$out")" would-change
is "4b mail body unchanged on disk" "$(body mail)" "mail v2"
is "4c registry unchanged" "$(cat "$REGISTRY")" "$before"
[[ ! -e "$PENDING_RESTART_DIR/maya" ]] && ok_ "4d no restart on a dry run" || bad_ "4d restart marked on a dry run"

echo "== 5. partner link: the recorded pack only, and the link is never stored =="
link="https://api.example.com/partner/packs/p1/otherpack.tar.gz?e=1&sig=deadbeef"
out=$(sync maya "$link"); rc=$?
is "5a a link for ANOTHER pack is refused" "$rc" 1
grep -q 'refusing to overlay' <<<"$out" && ok_ "5b refusal names why" || bad_ "5b refusal reason: $out"
is "5c mail untouched by the refused link" "$(body mail)" "mail v2"
mkdir -p "$AGENT_HOME_ROOT/agent-galina/.claude/skills"
link="https://api.example.com/partner/packs/p1/testpack.tar.gz?e=1&sig=deadbeef"
out=$(sync galina "$link"); rc=$?
is "5d an agent hired before the record syncs from a link" "$rc" 0
is "5e ...and records the pack's slug" "$(rec .slug galina)" '"testpack"'
is "5f ...as a url source" "$(rec .source galina)" '"url"'
grep -q 'sig=' "$REGISTRY" && bad_ "5g the signed link was written to the registry" || ok_ "5g the signed link is not stored"
is "5h _pack_url_slug parses the link" "$(_pack_url_slug "$link")" testpack
is "5i _pack_url_slug refuses a non-pack path" "$(_pack_url_slug "https://x.example/a/b?c=1")" ""

echo "== 6. nothing refetchable: skipped, not an error =="
out=$(sync frank); rc=$?
is "6a a url-sourced agent with no link is skipped (rc 0)" "$rc" 0
is "6b status skipped" "$(jq -r .status <<<"$out")" skipped
jq '.agents.nobody = {type:"claude"}' "$REGISTRY" >"$TMP/r" && mv "$TMP/r" "$REGISTRY"
is "6c no record at all is skipped" "$(sync nobody | jq -r .status)" skipped

mkdir -p "$AGENT_HOME_ROOT/agent-nobody/.claude/skills"
out=$(_pack_sync_one nobody "" 1 1 otherslug); is "6d --marketplace names the pack for an unrecorded agent" "$(jq -r .slug <<<"$out")" otherslug
out=$(_pack_sync_one maya "" 1 1 otherslug); rc=$?
is "6e --marketplace for ANOTHER pack than recorded is refused" "$rc" 1

echo "== 7. --all walks marketplace agents only =="
FIX_PACK="$TMP/p3"; rm -rf "$PENDING_RESTART_DIR"
out=$(cmd_pack_sync --all --no-restart)
is "7a --all synced exactly maya" "$(jq -c '[.data.agents[].name]' <<<"$out")" '["maya"]'
is "7b --no-restart leaves no marker" "$(ls "$PENDING_RESTART_DIR" 2>/dev/null | wc -l)" 0

echo "== 8. a skill another reconciler owns is never synced =="
DEFAULT_AGENT_SKILLS=("@org/skills:compile-knowledge")
mkdir -p "$AGENT_HOME_ROOT/agent-maya/.claude"
printf '{"enabledPlugins":{"telegram@5dive-plugins":true}}' >"$AGENT_HOME_ROOT/agent-maya/.claude/settings.json"
FIX_PACK="$TMP/p4"; mk_pack "$FIX_PACK" "mail=mail v3" "notes=notes v2" "calendar=cal v1" "compile-knowledge=pack copy" "notify-user=pack copy"
out=$(sync maya)
is "8a default + telegram-carried skills are named, not synced" "$(jq -c .managedElsewhere <<<"$out")" '["compile-knowledge","notify-user"]'
[[ ! -e "$SK/compile-knowledge" && ! -e "$SK/notify-user" ]] && ok_ "8b neither was installed" || bad_ "8b a skill owned by another reconciler was installed"
rm -f "$AGENT_HOME_ROOT/agent-maya/.claude/settings.json"
out=$(sync maya "" 1)
is "8c without the telegram plugin, notify-user is the pack's again" "$(jq -c .added <<<"$out")" '["notify-user"]'
DEFAULT_AGENT_SKILLS=()

echo "== 9. import records the pack it came from =="
imp=$(sed -n '/^cmd_import() {/,/^}/p' src/cmd_pack.sh)
grep -q '_pack_record_write "$as" "$pk_src" "$pk_slug"' <<<"$imp" && ok_ "9a cmd_import writes the pack record" || bad_ "9a cmd_import does not record the pack"
first=$(rec .importedAt)
_pack_record_write maya marketplace testpack '{}'
is "9b a later write keeps importedAt" "$(rec .importedAt)" "$first"

# ---------------------------------------------------------------------------
# DIVE-5211: the identity members. The live instructions file is the pack's
# section PREPENDED by persona_install_doc, then a tail the CLI owns — so only
# the section may move, and only while it is still exactly what the pack put in.
# ---------------------------------------------------------------------------
IH="$AGENT_HOME_ROOT/agent-olga/.claude"; MD="$IH/CLAUDE.md"
TAIL=$'## Role\nYou report to main.\n'
# mk_idpack <dir> <section-line> <voice> — a pack named `idpack` whose CLAUDE.md
# and registry persona call the agent by the PACK's name (import renames it).
mk_idpack() {
  mk_pack "$1"
  jq '.agentName = "idpack"' "$1/manifest.json" >"$1/m" && mv "$1/m" "$1/manifest.json"
  printf '# Idpack\nYou are Idpack, the office manager.\n%s\n' "$2" >"$1/CLAUDE.md"
  printf 'name: Idpack\nvoice:\n  audio: %s\n' "$3" >"$1/registry-persona.yaml"
}
# What import would have left on disk: the renamed section, "\n", the tail.
installed() { printf '# Olga\nYou are Olga, the office manager.\n%s\n\n%s' "$1" "$TAIL"; }
sha() { sha256sum <"$1" | cut -d' ' -f1; }
markers() { ls "$PENDING_RESTART_DIR" 2>/dev/null | wc -l | tr -d ' '; }
mkdir -p "$IH"
installed "Answer mail within a day." >"$MD"
jq '.agents.olga = {type:"claude", pack:{source:"marketplace", slug:"idpack"}}' "$REGISTRY" >"$TMP/r" && mv "$TMP/r" "$REGISTRY"
sync1() { _pack_sync_one olga "" 0 1; }

echo "== 10. first sync of an agent hired before the record: baseline the section, install the persona =="
FIX_PACK="$TMP/i1"; mk_idpack "$FIX_PACK" "Answer mail within a day." Kore
rm -rf "$PENDING_RESTART_DIR"; before=$(sha "$MD")
out=$(sync1); rc=$?
is "10a rc 0" "$rc" 0
is "10b the section is baselined, not rewritten" "$(jq -r .claudeMd.status <<<"$out")" baselined
is "10c CLAUDE.md byte-identical" "$(sha "$MD")" "$before"
is "10d persona.yaml added" "$(jq -r .persona.status <<<"$out")" added
grep -q 'audio: Kore' "$IH/persona.yaml" && ok_ "10e persona body landed" || bad_ "10e persona body missing"
grep -q '^name: Olga' "$IH/persona.yaml" && bad_ "10f registry persona was renamed (import installs it as-is)" || ok_ "10f registry persona installed as-is, like import"
is "10g the record holds the section's size" "$(rec .claudeMd.bytes olga)" "$(installed "Answer mail within a day." | head -c -$(( ${#TAIL} + 1 )) | wc -c | tr -d ' ')"
is "10h the record holds the persona's sha" "$(rec .persona olga)" "\"$(sha "$IH/persona.yaml")\""
is "10i one restart marker (the persona changed)" "$(markers)" 1
is "10j status changed" "$(jq -r .status <<<"$out")" changed

echo "== 11. same pack again: unchanged, no restart =="
rm -rf "$PENDING_RESTART_DIR"
out=$(sync1)
is "11a status unchanged" "$(jq -r .status <<<"$out")" unchanged
is "11b section unchanged" "$(jq -r .claudeMd.status <<<"$out")" unchanged
is "11c persona unchanged" "$(jq -r .persona.status <<<"$out")" unchanged
is "11d no restart marker" "$(markers)" 0

echo "== 12. pack bumps a CLAUDE.md line and a persona field: an unedited agent gets both, one restart =="
FIX_PACK="$TMP/i2"; mk_idpack "$FIX_PACK" "Answer mail within an hour." Puck
printf 'Owner note appended below the section.\n' >>"$MD"   # a TAIL edit is the owner's, and survives
want_tail=$(tail -c +"$(( $(jq -r '.agents.olga.pack.claudeMd.bytes' "$REGISTRY") + 1 ))" "$MD")
out=$(sync1); rc=$?
is "12a rc 0" "$rc" 0
is "12b section updated" "$(jq -r .claudeMd.status <<<"$out")" updated
is "12c persona updated" "$(jq -r .persona.status <<<"$out")" updated
grep -q 'within an hour' "$MD" && ok_ "12d the new line landed" || bad_ "12d new CLAUDE.md line missing"
grep -q 'within a day' "$MD" && bad_ "12e the old line survived" || ok_ "12e the old line is gone"
head -1 "$MD" | grep -qx '# Olga' && ok_ "12f the swapped section is renamed for the agent" || bad_ "12f section not renamed: $(head -1 "$MD")"
is "12g the tail (CLI blocks + owner note) is kept byte-for-byte" "$(tail -c +"$(( $(jq -r '.agents.olga.pack.claudeMd.bytes' "$REGISTRY") + 1 ))" "$MD")" "$want_tail"
grep -q 'audio: Puck' "$IH/persona.yaml" && ok_ "12h persona field landed" || bad_ "12h persona not refreshed"
is "12i exactly one restart marker" "$(markers)" 1
is "12j status changed" "$(jq -r .status <<<"$out")" changed

echo "== 13. and again: unchanged =="
rm -rf "$PENDING_RESTART_DIR"
out=$(sync1)
is "13a status unchanged" "$(jq -r .status <<<"$out")" unchanged
is "13b no restart marker" "$(markers)" 0
FIX_PACK="$TMP/i2b"; mk_idpack "$FIX_PACK" "Answer mail within two hours." Puck
out=$(sync1)
is "13c a section-only change is updated" "$(jq -r .claudeMd.status <<<"$out")" updated
is "13d ...with the persona unchanged" "$(jq -r .persona.status <<<"$out")" unchanged
is "13e ...and it alone owes a restart" "$(markers)" 1
rm -rf "$PENDING_RESTART_DIR"

echo "== 14. the owner edited the section: left alone, reported as drift, never clobbered =="
sed -i 's/within two hours/within ten minutes, always/' "$MD"
before=$(sha "$MD")
FIX_PACK="$TMP/i3"; mk_idpack "$FIX_PACK" "Answer mail within a week." Puck
out=$(sync1); rc=$?
is "14a rc 0 (drift is not a failure)" "$rc" 0
is "14b section reported as drift" "$(jq -r .claudeMd.status <<<"$out")" drift
jq -e '.claudeMd.reason | test("edited")' <<<"$out" >/dev/null && ok_ "14c drift says why" || bad_ "14c no drift reason"
is "14d the edited file is byte-identical" "$(sha "$MD")" "$before"
is "14e no restart for drift alone" "$(markers)" 0
is "14f status unchanged" "$(jq -r .status <<<"$out")" unchanged
grep -q 'CLAUDE.md section drift' < <(JSON_MODE=0 cmd_pack_sync olga 2>&1 >/dev/null) && ok_ "14g the prose line names the drift" || bad_ "14g prose line silent on drift"

echo "== 15. the owner edited persona.yaml: left alone =="
printf 'name: Olga (mine)\n' >"$IH/persona.yaml"; before=$(sha "$IH/persona.yaml")
FIX_PACK="$TMP/i4"; mk_idpack "$FIX_PACK" "Answer mail within a week." Charon
out=$(sync1)
is "15a persona drift" "$(jq -r .persona.status <<<"$out")" drift
is "15b the owner's persona is untouched" "$(sha "$IH/persona.yaml")" "$before"

echo "== 16. no record and the file is not the current section: left alone, drift =="
mkdir -p "$AGENT_HOME_ROOT/agent-pia/.claude"
printf '# Pia\nAn older pack version, or a hand edit.\n\n%s' "$TAIL" >"$AGENT_HOME_ROOT/agent-pia/.claude/CLAUDE.md"
before=$(sha "$AGENT_HOME_ROOT/agent-pia/.claude/CLAUDE.md")
jq '.agents.pia = {type:"claude", pack:{source:"marketplace", slug:"idpack"}}' "$REGISTRY" >"$TMP/r" && mv "$TMP/r" "$REGISTRY"
out=$(_pack_sync_one pia "" 0 1)
is "16a unrecorded mismatch is drift" "$(jq -r .claudeMd.status <<<"$out")" drift
jq -e '.claudeMd.reason | test("no install record")' <<<"$out" >/dev/null && ok_ "16b ...and says there was no record" || bad_ "16b reason"
is "16c file untouched" "$(sha "$AGENT_HOME_ROOT/agent-pia/.claude/CLAUDE.md")" "$before"
is "16d no section recorded for it" "$(rec '.claudeMd // "none"' pia)" '"none"'
# The pack dropped its section's last line: the live file STARTS with the new
# section's bytes, but the section it holds runs on. Baselining there would put
# the dropped line in the tail forever, so it must not match.
mkdir -p "$AGENT_HOME_ROOT/agent-rex/.claude"
printf '# Rex
You are Rex, the office manager.
Answer mail within a day.
A closing line the pack later dropped.

%s' "$TAIL" >"$AGENT_HOME_ROOT/agent-rex/.claude/CLAUDE.md"
jq '.agents.rex = {type:"claude", pack:{source:"marketplace", slug:"idpack"}}' "$REGISTRY" >"$TMP/r" && mv "$TMP/r" "$REGISTRY"
FIX_PACK="$TMP/i1"; out=$(_pack_sync_one rex "" 0 0)
is "16e a section that runs on past the pack's is not baselined" "$(jq -r .claudeMd.status <<<"$out")" drift

echo "== 17. --dry-run writes neither member =="
jq '.agents.dry = {type:"claude", pack:{source:"marketplace", slug:"idpack"}}' "$REGISTRY" >"$TMP/r" && mv "$TMP/r" "$REGISTRY"
DH="$AGENT_HOME_ROOT/agent-dry/.claude"; mkdir -p "$DH"
printf '# Dry\nYou are Dry, the office manager.\nAnswer mail within a day.\n\n%s' "$TAIL" >"$DH/CLAUDE.md"
FIX_PACK="$TMP/i1"; _pack_sync_one dry "" 0 0 >/dev/null     # baseline at v1
FIX_PACK="$TMP/i4"; before=$(sha "$DH/CLAUDE.md"); regb=$(cat "$REGISTRY"); rm -f "$DH/persona.yaml"
out=$(_pack_sync_one dry "" 1 1)
is "17a status would-change" "$(jq -r .status <<<"$out")" would-change
is "17b section would update" "$(jq -r .claudeMd.status <<<"$out")" updated
is "17c file unchanged" "$(sha "$DH/CLAUDE.md")" "$before"
[[ ! -e "$DH/persona.yaml" ]] && ok_ "17d no persona written" || bad_ "17d persona written on a dry run"
is "17e registry unchanged" "$(cat "$REGISTRY")" "$regb"

echo "== 18. a pack persona naming a signing key is never installed with it =="
FIX_PACK="$TMP/i5"; mk_idpack "$FIX_PACK" "Answer mail within a week." Charon
rm -f "$FIX_PACK/registry-persona.yaml"
printf 'name: Idpack\nvoice:\n  audio: Charon\next:\n  5dive:\n    signing_key: SECRETKEY\n' >"$FIX_PACK/persona.yaml"
rm -f "$DH/persona.yaml"
out=$(_pack_sync_one dry "" 0 0)
[[ -f "$DH/persona.yaml" ]] && ok_ "18a the stripped persona is installed" || bad_ "18a persona missing: $out"
grep -q 'SECRETKEY\|signing_key' "$DH/persona.yaml" 2>/dev/null && bad_ "18b the signing key reached the seat" || ok_ "18b no signing key on the seat"
grep -q '^name: Dry' "$DH/persona.yaml" && ok_ "18c the pack's own persona is renamed, as import does" || bad_ "18c pack persona not renamed"
grep -rq SECRETKEY "$REGISTRY" "$AGENT_HOME_ROOT" && bad_ "18d the key was written somewhere" || ok_ "18d the key was written nowhere"

echo "== 19. a codex seat: the section at the head of AGENTS.md, the return-channel doc kept =="
CH="$AGENT_HOME_ROOT/agent-cody/.codex"; mkdir -p "$CH"
CODEX_TAIL=$'# Return channel (DIVE-1410)\nReply with 5dive agent send.\n'
printf '# Cody\nYou are Cody, the office manager.\nAnswer mail within a day.\n\n%s' "$CODEX_TAIL" >"$CH/AGENTS.md"
jq '.agents.cody = {type:"codex", pack:{source:"marketplace", slug:"idpack"}}' "$REGISTRY" >"$TMP/r" && mv "$TMP/r" "$REGISTRY"
FIX_PACK="$TMP/i1"; out=$(_pack_sync_one cody "" 0 0)
is "19a baselined on AGENTS.md" "$(jq -r .claudeMd.status <<<"$out")" baselined
FIX_PACK="$TMP/i2"; out=$(_pack_sync_one cody "" 0 0)
is "19b updated" "$(jq -r .claudeMd.status <<<"$out")" updated
grep -q 'within an hour' "$CH/AGENTS.md" && ok_ "19c new line landed in AGENTS.md" || bad_ "19c AGENTS.md not updated"
[[ "$(tail -c ${#CODEX_TAIL} "$CH/AGENTS.md")" == "${CODEX_TAIL%$'\n'}" ]] && ok_ "19d return-channel doc kept" || bad_ "19d return-channel doc lost"
[[ ! -e "$AGENT_HOME_ROOT/agent-cody/.claude/CLAUDE.md" ]] && ok_ "19e no stray ~/.claude/CLAUDE.md on a codex seat" || bad_ "19e wrote ~/.claude/CLAUDE.md on a codex seat"

echo "== 20. import records the section and the persona =="
grep -q 'pk_members=$(jq -nc --arg s "$(_pack_file_sha "$stage/CLAUDE.md")"' <<<"$imp" && ok_ "20a cmd_import records the installed section" || bad_ "20a cmd_import does not record the section"
grep -q '_pack_record_write "$as" "$pk_src" "$pk_slug" .* "$pk_members"' <<<"$imp" && ok_ "20b ...and passes it to the record" || bad_ "20b section not passed to the record"
_pack_record_write olga marketplace idpack '{}' '{}'
is "20c a write that names no member keeps the old member record" "$(rec '.claudeMd | type' olga)" '"object"'

echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
