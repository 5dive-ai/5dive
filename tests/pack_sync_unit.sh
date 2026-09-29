#!/usr/bin/env bash
# DIVE-5205: a hired agent gets its pack's LATER skill fixes — `agent pack-sync`.
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
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/registry.sh cmd_skill.sh cmd_pack.sh; do
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
is "1k persona/CLAUDE.md named as not synced" "$(jq -c .notSynced <<<"$out")" '["persona.yaml","CLAUDE.md"]'

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

echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
