#!/usr/bin/env bash
# DIVE-7275: `agent update <name> --from-pack` — a pack update reaches a LIVE pack
# agent without root on the box.
#
# `agent pack-sync` leaves an instructions file it cannot prove the pack wrote as
# drift, forever: every partner agent's file had been pushed by hand, so every pack
# change went out as a root bundle. The verb is the deliberate overwrite, graded on
# a fixture home (AGENT_HOME_ROOT) and registry with the fetchers stubbed:
#   - a changed pack CLAUDE.md replaces only the pack's section, even when edited;
#     the CLI blocks and every line the agent added below them survive byte for
#     byte, and the old file is backed up;
#   - after it, the nightly pack-sync is back in charge (unchanged, not drift);
#   - an edited pack skill is reinstalled (extra files kept); an owner skill is not
#     read; a skill the agent lost comes back unless the pack dropped it;
#   - bot binding, chat, memory and auth files are not touched;
#   - --dry-run prints the diff and writes nothing;
#   - an agent hired from no pack is refused; a file with no CLI block is refused.
# Run: bash tests/agent_update_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

TMP="$(mktemp -d /tmp/agent-update-unit.XXXXXX)"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/registry.sh lib/agent_setup.sh cmd_skill.sh cmd_pack.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e
JSON_MODE=1
export AGENT_HOME_ROOT="$TMP/home" REGISTRY="$TMP/agents.json" PENDING_RESTART_DIR="$TMP/pending"
FIX_PACK=""
_marketplace_fetch_pack() { local o; o=$(mktemp --suffix=.tar.gz); tar -czf "$o" -C "$FIX_PACK" . && echo "$o"; }
_pack_fetch_url() { local o; o=$(mktemp --suffix=.tar.gz); tar -czf "$o" -C "$FIX_PACK" . && echo "$o"; }
_pending_restart_mark() { mkdir -p "$PENDING_RESTART_DIR"; printf 'reason=%s\n' "$2" >"$PENDING_RESTART_DIR/$1"; }
agent_type() { registry_read | jq -r --arg n "$1" '.agents[$n].type // empty'; }
require_root() { :; }
chown() { :; }
_pack_as_agent() { shift; "$@"; }   # runuser needs root; the seam the merge reads through
fail() { printf 'FAIL-CALLED %s\n' "$*"; exit 1; }   # the real one exits too

PASS=0; FAIL=0
ok_()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad_() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
is()   { [[ "$2" == "$3" ]] && ok_ "$1" || bad_ "$1 (want [$3] got [$2])"; }
sha()  { sha256sum <"$1" | cut -d' ' -f1; }
rec()  { jq -c --arg n "${2:-maya}" ".agents[\$n].pack$1" "$REGISTRY"; }
reg_add() { jq --arg n "$1" --argjson v "$2" '.agents[$n] = $v' "$REGISTRY" >"$TMP/r" && mv "$TMP/r" "$REGISTRY"; }

# mk_pack <dir> <section-line> <skill>=<body>... — pack `office-maya`, its CLAUDE.md
# naming the agent by the pack's name (import and sync rename it to the agent's).
mk_pack() {
  local dir="$1" line="$2"; shift 2; rm -rf "$dir"; mkdir -p "$dir/skills"
  local kv ids=()
  for kv in "$@"; do
    mkdir -p "$dir/skills/${kv%%=*}"; printf '%s\n' "${kv#*=}" >"$dir/skills/${kv%%=*}/SKILL.md"; ids+=("${kv%%=*}")
  done
  printf '%s\n' "${ids[@]+"${ids[@]}"}" | jq -R . | jq -s 'map(select(. != "")) | {packFormat:1, agentName:"officemaya", skills:.}' >"$dir/manifest.json"
  printf '# Officemaya\nYou are Officemaya, the office manager.\n%s\n' "$line" >"$dir/CLAUDE.md"
}
SEC=$(_persona_card_section /dev/null)
# What a claude seat holds below the pack section: the CLI's own blocks, as create wrote them.
CLI_TAIL=$'# Telegram-paired agent\n\nReply every turn.\n\n# Subagent model choice (Fable sessions only)\n\nUse haiku for search.\n'
AGENT_LINES=$'\n## Notes the agent wrote\nThe owner prefers mornings.\n'

H="$AGENT_HOME_ROOT/agent-maya"; MD="$H/.claude/CLAUDE.md"; SK="$H/.claude/skills"
mkdir -p "$SK/mail" "$SK/notes" "$SK/owner-tool" "$SK/legacy" "$H/.claude/channels/telegram" "$H/.claude/projects/x/memory"
# Hand-pushed by a root bundle: an older pack line, swapped by sed, plus an extra line.
printf '# Maya\nYou are Maya, the office manager.\nAnswer mail within a day (pushed by hand).\nA line the old bundle added.\n\n%s\n\n%s%s' "$SEC" "$CLI_TAIL" "$AGENT_LINES" >"$MD"
printf 'mail v1\n' >"$SK/mail/SKILL.md"; printf 'print(1)\n' >"$SK/mail/mail.py"
printf 'notes v1\n' >"$SK/notes/SKILL.md"
printf 'owner tool\n' >"$SK/owner-tool/SKILL.md"
printf 'legacy v1\n' >"$SK/legacy/SKILL.md"
printf 'TOKEN=123:abc\n' >"$H/.claude/channels/telegram/.env"
printf '{"allowFrom":["42"]}\n' >"$H/.claude/channels/telegram/access.json"
printf '{"claudeAiOauth":{"accessToken":"x"}}\n' >"$H/.claude/.credentials.json"
printf 'remember: owner is Galina\n' >"$H/.claude/projects/x/memory/user.md"
printf '{"enabledPlugins":{}}\n' >"$H/.claude/settings.json"
jq -n '{agents:{
  maya:{type:"claude", channels:["telegram"], pack:{source:"marketplace", slug:"office-maya",
        skills:{mail:"recorded-before-the-hand-push", notes:"recorded-before-the-hand-push"},
        claudeMd:{sha:"0000", bytes:10}}},
  plain:{type:"claude"},
  partner:{type:"claude", pack:{source:"url", slug:"office-maya"}}}}' >"$REGISTRY"
# The agent edited a pack skill, and the pack later dropped `legacy`.
printf 'notes, edited\n' >"$SK/notes/SKILL.md"
keep() { for f in "$H/.claude/channels/telegram/.env" "$H/.claude/channels/telegram/access.json" \
                  "$H/.claude/.credentials.json" "$H/.claude/projects/x/memory/user.md" "$H/.claude/settings.json" \
                  "$SK/owner-tool/SKILL.md" "$SK/legacy/SKILL.md"; do printf '%s %s\n' "$(sha "$f")" "$f"; done; }
KEEP_BEFORE=$(keep)
FIX_PACK="$TMP/p2"; mk_pack "$FIX_PACK" "Answer mail within an hour." "mail=mail v2" "notes=notes v2" "calendar=cal v1"

echo "== 1. the verb exists (red on a tree without it) =="
declare -F cmd_agent_update >/dev/null && ok_ "1a cmd_agent_update is defined" || bad_ "1a no agent update verb"
grep -q 'cmd_agent_update' src/main.sh && ok_ "1b agent update is dispatched" || bad_ "1b not dispatched from main.sh"

echo "== 2. today: pack-sync leaves the hand-pushed file and the edited skill alone =="
before=$(sha "$MD")
out=$(_pack_sync_one maya "" 1 1)
is "2a instructions are drift under pack-sync" "$(jq -r .claudeMd.status <<<"$out")" drift
is "2b the edited skills are drift under pack-sync" "$(jq -c .drift <<<"$out")" '["mail","notes"]'
is "2c nothing written" "$(sha "$MD")" "$before"

echo "== 3. --dry-run: prints the diff, writes nothing =="
regb=$(cat "$REGISTRY")
out=$(JSON_MODE=0 cmd_agent_update maya --from-pack --dry-run 2>&1)
grep -q '^-Answer mail within a day (pushed by hand)' <<<"$out" && ok_ "3a the diff shows the old line going" || bad_ "3a diff: $out"
grep -q '^+Answer mail within an hour' <<<"$out" && ok_ "3b ...and the new line coming" || bad_ "3b diff missing the new line"
grep -q '^[-+]# Telegram-paired agent\|^[-+]The owner prefers mornings' <<<"$out" && bad_ "3c the diff touches the tail" || ok_ "3c the diff leaves the tail alone"
is "3d file unchanged" "$(sha "$MD")" "$before"
is "3e registry unchanged" "$(cat "$REGISTRY")" "$regb"
[[ -z "$(ls "$H/.claude" | grep bak-pack)" ]] && ok_ "3f no backup written" || bad_ "3f backup written on a dry run"

echo "== 4. update: only the pack section moves =="
rm -rf "$PENDING_RESTART_DIR"
out=$(cmd_agent_update maya --from-pack); rc=$?
is "4a rc 0" "$rc" 0
r=$(jq -c .data.agent <<<"$out")
is "4b instructions reclaimed" "$(jq -r .claudeMd.status <<<"$r")" reclaimed
grep -q 'within an hour' "$MD" && ok_ "4c the pack's new line landed" || bad_ "4c new line missing"
grep -q 'pushed by hand\|old bundle added' "$MD" && bad_ "4d the old section survived" || ok_ "4d the old section is gone"
is "4e renamed for the agent" "$(head -1 "$MD")" "# Maya"
is "4f the CLI blocks and the agent's lines below are kept byte for byte" \
   "$(tail -c "$(( ${#CLI_TAIL} + ${#AGENT_LINES} ))" "$MD")" "$(printf '%s%s' "$CLI_TAIL" "$AGENT_LINES")"
is "4g one telegram block, not two" "$(grep -c '^# Telegram-paired agent' "$MD")" 1
bak=$(jq -r .claudeMd.backup <<<"$r")
[[ -f "$bak" ]] && is "4h the old file is backed up whole" "$(sha "$bak")" "$before" || bad_ "4h no backup at [$bak]"
is "4i the record holds the new section" "$(rec .claudeMd.sha | tr -d '"')" "$(head -c "$(rec .claudeMd.bytes)" "$MD" | sha256sum | cut -d' ' -f1)"
[[ -f "$PENDING_RESTART_DIR/maya" ]] && ok_ "4j a restart is owed at a quiet moment" || bad_ "4j no restart marker"

echo "== 5. skills =="
is "5a mail updated, notes (edited) reinstalled" "$(jq -c '.updated | sort' <<<"$r")" '["mail","notes"]'
is "5b calendar added" "$(jq -c .added <<<"$r")" '["calendar"]'
is "5c the edited pack skill now holds the pack's body" "$(cat "$SK/notes/SKILL.md")" "notes v2"
is "5d a file the pack does not ship is kept" "$(cat "$SK/mail/mail.py")" "print(1)"
is "5e nothing reported as drift" "$(jq -c .drift <<<"$r")" '[]'

echo "== 6. untouched: bot binding, chat, auth, memory, settings, owner skill, a skill the pack dropped =="
is "6a every one byte-identical" "$(keep)" "$KEEP_BEFORE"

echo "== 7. the nightly takes over again =="
out=$(_pack_sync_one maya "" 0 1)
is "7a pack-sync: instructions unchanged, not drift" "$(jq -r .claudeMd.status <<<"$out")" unchanged
is "7b pack-sync: status unchanged" "$(jq -r .status <<<"$out")" unchanged
FIX_PACK="$TMP/p3"; mk_pack "$FIX_PACK" "Answer mail within two hours." "mail=mail v2" "notes=notes v2" "calendar=cal v1"
out=$(_pack_sync_one maya "" 0 1)
is "7c the next pack change lands through pack-sync alone" "$(jq -r .claudeMd.status <<<"$out")" updated
grep -q 'within two hours' "$MD" && ok_ "7d ...in the file" || bad_ "7d not in the file"

echo "== 8. a skill the agent lost comes back; one the pack dropped is not re-added =="
rm -rf "$SK/calendar" "$SK/legacy"
out=$(cmd_agent_update maya --from-pack | jq -c .data.agent)
is "8a the lost pack skill is re-added" "$(jq -c .added <<<"$out")" '["calendar"]'
[[ ! -e "$SK/legacy" ]] && ok_ "8b the dropped skill stays removed" || bad_ "8b dropped skill came back"

echo "== 9. refusals =="
mkdir -p "$AGENT_HOME_ROOT/agent-plain/.claude"; printf '%s' "$CLI_TAIL" >"$AGENT_HOME_ROOT/agent-plain/.claude/CLAUDE.md"
pb=$(sha "$AGENT_HOME_ROOT/agent-plain/.claude/CLAUDE.md")
out=$(cmd_agent_update plain --from-pack); rc=$?
is "9a an agent hired from no pack is refused" "$rc" 1
grep -q 'not hired from a pack' <<<"$out" && ok_ "9b ...and says so" || bad_ "9b: $out"
out=$(cmd_agent_update plain --from-pack=office-maya | jq -c .data.agent)
is "9c ...even when named: no pack section to replace" "$(jq -r .claudeMd.status <<<"$out")" drift
is "9d ...and its file is untouched" "$(sha "$AGENT_HOME_ROOT/agent-plain/.claude/CLAUDE.md")" "$pb"
out=$(cmd_agent_update partner --from-pack); rc=$?
is "9e a partner agent needs a fresh link" "$rc" 1
grep -q 'fresh one' <<<"$out" && ok_ "9f ...and says so" || bad_ "9f: $out"
out=$(cmd_agent_update maya); rc=$?
is "9g no --from-pack is a usage error" "$rc" 1
out=$(cmd_agent_update ghost --from-pack); rc=$?
is "9h an unknown agent is refused" "$rc" 1
# A file with no CLI block after the section: nowhere safe to cut.
reg_add nob '{"type":"claude","pack":{"source":"marketplace","slug":"office-maya"}}'
mkdir -p "$AGENT_HOME_ROOT/agent-nob/.claude"; printf '# Nob\nOnly hand-written text.\n\n## More\nText.\n' >"$AGENT_HOME_ROOT/agent-nob/.claude/CLAUDE.md"
nb_=$(sha "$AGENT_HOME_ROOT/agent-nob/.claude/CLAUDE.md")
out=$(cmd_agent_update nob --from-pack | jq -c .data.agent)
is "9i no CLI block: left alone as drift" "$(jq -r .claudeMd.status <<<"$out")" drift
jq -e '.claudeMd.reason | test("where the pack section ends")' <<<"$out" >/dev/null && ok_ "9j ...and says why" || bad_ "9j: $out"
is "9k ...file untouched" "$(sha "$AGENT_HOME_ROOT/agent-nob/.claude/CLAUDE.md")" "$nb_"
# A pack whose own section carries a CLI marker: the cut would be ambiguous.
FIX_PACK="$TMP/pm"; mk_pack "$FIX_PACK" $'Rules.\n\n# Telegram-paired agent\nPack copy.'
sed -i 's/within two hours/within ten minutes/' "$MD"   # drifted, so only update could touch it
before=$(sha "$MD")
out=$(cmd_agent_update maya --from-pack | jq -c .data.agent)
is "9l a pack section holding a CLI marker is refused" "$(jq -r .claudeMd.status <<<"$out")" drift
is "9m ...file untouched" "$(sha "$MD")" "$before"

echo "== 10. older pack, no record at all; a link to a partner pack =="
reg_add old '{"type":"claude","pack":{"source":"url","slug":"office-maya"}}'
OH="$AGENT_HOME_ROOT/agent-old/.claude"; mkdir -p "$OH/skills"
printf '# Old\nAn older pack version.\n\n%s' "$CLI_TAIL" >"$OH/CLAUDE.md"
FIX_PACK="$TMP/p3"
out=$(cmd_agent_update old --from-pack="https://api.example.com/partner/packs/p1/office-maya.tar.gz?e=1&sig=ab" | jq -c .data.agent)
is "10a reclaimed from a signed link" "$(jq -r .claudeMd.status <<<"$out")" reclaimed
is "10b the tail is kept" "$(tail -c ${#CLI_TAIL} "$OH/CLAUDE.md")" "${CLI_TAIL%$'\n'}"
grep -q 'sig=' "$REGISTRY" && bad_ "10c the signed link was stored" || ok_ "10c the signed link is not stored"
out=$(cmd_agent_update old --from-pack="https://api.example.com/partner/packs/p1/other.tar.gz?e=1&sig=ab"); rc=$?
is "10d a link for another pack is refused" "$rc" 1

echo "== 11. a codex seat: cut at the operating baseline =="
reg_add cody '{"type":"codex","pack":{"source":"marketplace","slug":"office-maya"}}'
CH="$AGENT_HOME_ROOT/agent-cody/.codex"; mkdir -p "$CH"
CB=$'<!-- 5dive:codex-operating-baseline:begin -->\nReply with 5dive agent send.\n<!-- 5dive:codex-operating-baseline:end -->\n'
printf '# Cody\nHand-edited pack text.\n\n%s' "$CB" >"$CH/AGENTS.md"
out=$(cmd_agent_update cody --from-pack | jq -c .data.agent)
is "11a reclaimed on AGENTS.md" "$(jq -r .claudeMd.status <<<"$out")" reclaimed
is "11b the baseline is kept" "$(tail -c ${#CB} "$CH/AGENTS.md")" "${CB%$'\n'}"
grep -q 'Hand-edited' "$CH/AGENTS.md" && bad_ "11c the old section survived" || ok_ "11c the old section is gone"

echo "== 12. a link at the instructions path is never written through =="
reg_add lena '{"type":"claude","pack":{"source":"marketplace","slug":"office-maya"}}'
LH="$AGENT_HOME_ROOT/agent-lena/.claude"; mkdir -p "$LH"
printf '# Lena\nOld.\n\n%s' "$CLI_TAIL" >"$TMP/victim.md"; vb=$(sha "$TMP/victim.md"); ln -s "$TMP/victim.md" "$LH/CLAUDE.md"
out=$(cmd_agent_update lena --from-pack | jq -c .data.agent)
is "12a a linked file is drift" "$(jq -r .claudeMd.status <<<"$out")" drift
is "12b its target is untouched" "$(sha "$TMP/victim.md")" "$vb"

echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
