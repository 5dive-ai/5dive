#!/usr/bin/env bash
# DIVE-6796 — a pack skill arrives WHOLE: SKILL.md plus its scripts, references/
# and evals/. The registry fetch used to curl skills/<id>/SKILL.md alone ("curl
# can't list a dir"), and the install was `rm -rf` + copy, so mail/mail.py never
# reached an agent and a re-import wiped one pushed by hand. Measured on lodar's
# box: 82 files missing across 8 agents; the public registry has 295 such files.
#   A. the registry fetch lists the skill dir from the git tree and brings every
#      file, +x where the tree says 100755; a hostile listing is refused per entry;
#      an unreadable tree falls back to SKILL.md alone and the import still works;
#   B. a re-import keeps a file the new bundle lacks, and replaces what it carries;
#   C. the nightly pack-sync BACKFILLS an agent imported on the old code: missing
#      files copied in, nothing it has overwritten (an owner edit included), no
#      restart marker, and the next night is unchanged.
# Drives the real fetch / install / sync code with the network and the agent user
# stubbed at their seams.
# TIER: core
# Run: timeout 120 bash tests/pack_skill_files_unit.sh
set -uo pipefail
# The org is pinned BEFORE anything is sourced: gh_org() probes with curl, and
# the curl stub below must never reach it (an unpinned probe re-entered the stub
# from inside a $( ), where the cache never sticks: a fork bomb, 2026-10-23).
export GH_ORG=5dive-ai
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

TMP="$(mktemp -d /tmp/pack-skill-files.XXXXXX)"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/registry.sh lib/agent_setup.sh lib/marketplace.sh cmd_skill.sh cmd_pack.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e
JSON_MODE=1
export AGENT_HOME_ROOT="$TMP/home" REGISTRY="$TMP/agents.json" PENDING_RESTART_DIR="$TMP/pending"

PASS=0; FAIL=0
ok_()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad_() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
is()   { [[ "$2" == "$3" ]] && ok_ "$1" || bad_ "$1 (want [$3] got [$2])"; }
has()  { [[ -f "$2" ]] && ok_ "$1" || bad_ "$1 (missing $2)"; }
hasnt(){ [[ ! -e "$2" && ! -L "$2" ]] && ok_ "$1" || bad_ "$1 (present: $2)"; }

# ---- the registry: a directory, served through the fetch seams ---------------
REG="$TMP/reg"; TREE_OK=1
TREE_URL=$(_marketplace_tree_url)   # once, here: the stub must not compute it
_marketplace_base() { printf 'https://reg.example'; }
_marketplace_index() { printf '{"packs":[{"slug":"maya","path":"packs/maya"}]}'; }
_serve() { local f="$REG/${1#https://reg.example/}"; [[ -f "$f" ]] && cp "$f" "$2"; }
_marketplace_get_required() { _serve "$1" "$2" || return 1; }
# The git tree: every regular file in $REG with its mode, plus whatever hostile
# entries the arm adds to $TMP/extra-tree.
_tree_json() {
  (cd "$REG" && find . -type f | sed 's#^\./##' | sort) | while IFS= read -r p; do
    [[ -x "$REG/$p" ]] && m=100755 || m=100644
    jq -nc --arg p "$p" --arg m "$m" '{path:$p, mode:$m, type:"blob"}'
  done | { cat; cat "$TMP/extra-tree" 2>/dev/null; } | jq -s '{sha:"x", truncated:false, tree:.}'
}
curl() {
  local out="" url="" prev="" arg
  for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    [[ "$arg" == https://* ]] && url="$arg"
    prev="$arg"
  done
  if [[ "$url" == "$TREE_URL" ]]; then
    (( TREE_OK )) || return 22
    _tree_json; return 0
  fi
  _serve "$url" "$out" || return 22
}

mkdir -p "$REG/packs/maya/skills/mail" "$REG/packs/maya/skills/emails/references" "$REG/packs/maya/skills/emails/evals"
jq -n '{packFormat:1, agentName:"maya", skills:["mail","emails"]}' >"$REG/packs/maya/manifest.json"
printf 'You are Maya.\n' >"$REG/packs/maya/CLAUDE.md"
printf '# mail\nRun mail.py\n' >"$REG/packs/maya/skills/mail/SKILL.md"
printf '#!/usr/bin/env python3\nprint("mail")\n' >"$REG/packs/maya/skills/mail/mail.py"; chmod 755 "$REG/packs/maya/skills/mail/mail.py"
printf '# emails\n' >"$REG/packs/maya/skills/emails/SKILL.md"
printf 'copy rules\n' >"$REG/packs/maya/skills/emails/references/copy-guidelines.md"
printf '{}\n' >"$REG/packs/maya/skills/emails/evals/evals.json"
# A file of a skill the manifest does NOT list: never fetched.
mkdir -p "$REG/packs/maya/skills/unlisted"; printf 'x\n' >"$REG/packs/maya/skills/unlisted/SKILL.md"

fetch() { # -> extracts the fetched pack into $TMP/x; echoes its member list
  local p; p=$(_marketplace_fetch_pack maya) || { echo "FETCH-RC=$?"; return; }
  rm -rf "$TMP/x"; mkdir -p "$TMP/x"; tar -xzf "$p" -C "$TMP/x"
  tar -tzf "$p" | sed 's#^\./##' | grep -v '/$' | grep -v '^$' | sort | tr '\n' ' '
  rm -f "$p"
}

echo "== A. the registry fetch brings the whole skill =="
L=$(fetch)
has "A1 mail/mail.py is fetched" "$TMP/x/skills/mail/mail.py"
[[ -x "$TMP/x/skills/mail/mail.py" ]] && ok_ "A2 ...executable (tree mode 100755)" || bad_ "A2 mail.py lost its +x"
has "A3 emails/references/* is fetched" "$TMP/x/skills/emails/references/copy-guidelines.md"
has "A4 emails/evals/* is fetched" "$TMP/x/skills/emails/evals/evals.json"
[[ ! -x "$TMP/x/skills/emails/references/copy-guidelines.md" ]] && ok_ "A5 a 100644 blob is not executable" || bad_ "A5 a 100644 blob came out executable"
hasnt "A6 a skill the manifest does not list is never fetched" "$TMP/x/skills/unlisted"
is "A7 byte for byte" "$(cat "$TMP/x/skills/mail/mail.py")" "$(cat "$REG/packs/maya/skills/mail/mail.py")"

# Hostile listing entries: traversal, a dot segment, an absolute path, a link.
mkdir -p "$REG/packs/maya/skills/mail/sub"; printf 'link target\n' >"$REG/packs/maya/skills/mail/sub/linked"
{
  jq -nc '{path:"packs/maya/skills/mail/../../../../etc/evil", mode:"100644", type:"blob"}'
  jq -nc '{path:"packs/maya/skills/mail/./dot", mode:"100644", type:"blob"}'
  jq -nc '{path:"packs/maya/skills/mail//abs", mode:"100644", type:"blob"}'
} >"$TMP/extra-tree"
mkdir -p "$REG/packs/maya/skills/etc"; printf 'evil\n' >"$REG/packs/maya/skills/etc/evil"
# The link: served as a regular file by the stub, so only the MODE refuses it.
_tree_json_real=$(declare -f _tree_json)
_tree_json() { eval "${_tree_json_real/_tree_json/_tj}"; _tj | jq '.tree |= map(if .path == "packs/maya/skills/mail/sub/linked" then .mode = "120000" else . end)'; }
L=$(fetch)
hasnt "A8 a ../ entry never lands outside the skill" "$TMP/x/etc/evil"
hasnt "A8b ...nor anywhere in the pack" "$TMP/x/skills/etc"
hasnt "A9 a ./ segment is refused" "$TMP/x/skills/mail/dot"
hasnt "A10 an empty segment is refused" "$TMP/x/skills/mail/abs"
hasnt "A11 a symlink blob (120000) is refused" "$TMP/x/skills/mail/sub/linked"
has "A12 the good files still arrive beside refused ones" "$TMP/x/skills/mail/mail.py"
eval "$_tree_json_real"; rm -f "$TMP/extra-tree"; rm -rf "$REG/packs/maya/skills/etc" "$REG/packs/maya/skills/mail/sub"

# Cap: one skill may bring at most PACK_SKILL_MAX_FILES files.
PACK_SKILL_MAX_FILES=1
L=$(fetch)
is "A13 the per-skill file cap holds" "$(find "$TMP/x/skills/emails" -type f ! -name SKILL.md | wc -l)" 1
PACK_SKILL_MAX_FILES=200

TREE_OK=0
L=$(fetch)
has "A14 an unreadable tree still fetches SKILL.md (old behaviour, never a failed import)" "$TMP/x/skills/mail/SKILL.md"
hasnt "A15 ...and only SKILL.md" "$TMP/x/skills/mail/mail.py"
TREE_OK=1

echo "== B. import installs it whole; a re-import keeps what the bundle lacks =="
agent_type() { registry_read | jq -r --arg n "$1" '.agents[$n].type // empty'; }
chown() { :; }
_pack_as_agent() { shift; "$@"; }   # the agent user does not exist here
jq -n '{agents:{maya:{type:"claude", pack:{source:"marketplace", slug:"maya"}}}}' >"$REGISTRY"
SK="$AGENT_HOME_ROOT/agent-maya/.claude/skills"; mkdir -p "$SK"
fetch >/dev/null
_install_bundled_skill maya mail "$TMP/x/skills/mail"; is "B1 install rc 0" "$?" 0
_install_bundled_skill maya emails "$TMP/x/skills/emails"
has "B2 mail/mail.py installed" "$SK/mail/mail.py"
[[ -x "$SK/mail/mail.py" ]] && ok_ "B3 ...executable" || bad_ "B3 installed mail.py is not executable"
has "B4 emails/references installed" "$SK/emails/references/copy-guidelines.md"
printf 'hand-pushed helper\n' >"$SK/mail/helper.sh"; chmod 755 "$SK/mail/helper.sh"
# A SKILL.md-only bundle (an old-format pack, or a rate-limited tree) re-imported:
TREE_OK=0; fetch >/dev/null; TREE_OK=1
printf '# mail v2\n' >"$TMP/x/skills/mail/SKILL.md"
_install_bundled_skill maya mail "$TMP/x/skills/mail"
has "B5 a re-import KEEPS mail.py the bundle lacks" "$SK/mail/mail.py"
has "B6 ...and a hand-pushed file" "$SK/mail/helper.sh"
[[ -x "$SK/mail/mail.py" && -x "$SK/mail/helper.sh" ]] && ok_ "B7 ...with their +x" || bad_ "B7 a kept file lost +x"
is "B8 what the bundle carries IS replaced" "$(cat "$SK/mail/SKILL.md")" "# mail v2"
# A link the agent planted is never carried (find does not follow links).
ln -s /etc/hostname "$SK/mail/planted"
_install_bundled_skill maya mail "$TMP/x/skills/mail"
hasnt "B9 a planted link is dropped, not followed" "$SK/mail/planted"

echo "== C. the nightly pack-sync backfills an agent imported on the old code =="
_pending_restart_mark() { mkdir -p "$PENDING_RESTART_DIR"; printf 'reason=%s\n' "$2" >"$PENDING_RESTART_DIR/$1"; }
require_root() { :; }
fail() { printf 'FAIL-CALLED %s\n' "$*" >&2; return 1; }
# Old-code agent: SKILL.md only, and the record holds the SKILL.md-only hashes.
rm -rf "$SK"; mkdir -p "$SK/mail" "$SK/emails"
cp "$REG/packs/maya/skills/mail/SKILL.md" "$SK/mail/"; cp "$REG/packs/maya/skills/emails/SKILL.md" "$SK/emails/"
jq -n --arg m "$(_pack_tree_sha "$SK/mail")" --arg e "$(_pack_tree_sha "$SK/emails")" \
  '{agents:{maya:{type:"claude", pack:{source:"marketplace", slug:"maya", skills:{mail:$m, emails:$e}}}}}' >"$REGISTRY"
rm -rf "$PENDING_RESTART_DIR"
out=$(_pack_sync_one maya "" 1 1)
is "C1 --dry-run reports the backfill" "$(jq -c .backfilled <<<"$out")" '["mail","emails"]'
hasnt "C2 ...and writes nothing" "$SK/mail/mail.py"
out=$(_pack_sync_one maya "" 0 1); rc=$?
is "C3 sync rc 0" "$rc" 0
is "C4 status changed" "$(jq -r .status <<<"$out")" changed
is "C5 both skills backfilled, none 'updated'" "$(jq -c '[.backfilled, .updated]' <<<"$out")" '[["mail","emails"],[]]'
has "C6 mail/mail.py restored" "$SK/mail/mail.py"
[[ -x "$SK/mail/mail.py" ]] && ok_ "C7 ...executable" || bad_ "C7 restored mail.py is not executable"
has "C8 emails/references restored" "$SK/emails/references/copy-guidelines.md"
[[ ! -e "$PENDING_RESTART_DIR/maya" ]] && ok_ "C9 NO restart for a backfill" || bad_ "C9 a backfill marked a restart"
is "C10 the record holds the live tree" "$(jq -r '.agents.maya.pack.skills.mail' "$REGISTRY")" "$(_pack_tree_sha "$SK/mail")"
out=$(_pack_sync_one maya "" 0 1)
is "C11 the next night is unchanged" "$(jq -r .status <<<"$out")" unchanged

# Owner edited SKILL.md AND a script is missing: the edit stays, the script comes back.
printf '# mail, edited by the owner\n' >"$SK/mail/SKILL.md"; rm -f "$SK/mail/mail.py"
printf 'owner rewrote this\n' >"$SK/emails/references/copy-guidelines.md"; rm -rf "$SK/emails/evals"
out=$(_pack_sync_one maya "" 0 1)
is "C12 both reported as drift" "$(jq -c .drift <<<"$out")" '["mail","emails"]'
is "C13 the owner's SKILL.md edit survives" "$(cat "$SK/mail/SKILL.md")" "# mail, edited by the owner"
has "C14 ...and the missing script is restored beside it" "$SK/mail/mail.py"
is "C15 an owner-edited reference is never overwritten" "$(cat "$SK/emails/references/copy-guidelines.md")" "owner rewrote this"
has "C16 ...while its missing evals/ come back" "$SK/emails/evals/evals.json"
[[ ! -e "$PENDING_RESTART_DIR/maya" ]] && ok_ "C17 still no restart" || bad_ "C17 drift backfill marked a restart"

# The backfill writes AS THE AGENT: a refused write is a failure, never a root write.
rm -rf "$SK"; mkdir -p "$SK/mail"; cp "$REG/packs/maya/skills/mail/SKILL.md" "$SK/mail/"
_pack_as_agent() { return 1; }
out=$(_pack_sync_one maya "" 0 1)
hasnt "C18 nothing is written when the agent-side write is refused" "$SK/mail/mail.py"
is "C19 ...and the skill is reported failed, not backfilled (emails, absent, is a plain install)" "$(jq -c '[.failed, .backfilled, .added]' <<<"$out")" '[["mail"],[],["emails"]]'

echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
