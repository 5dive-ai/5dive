#!/usr/bin/env bash
# DIVE-7420 — a pack import must leave the harness skills dir owned by the seat.
# The marketplace import of a grok agent ran `mkdir -p ~/.grok/skills` as root and
# chowned only the skill under it, so the seat could not create
# ~/.grok/skills/notify-user when Telegram was connected: the channel install
# failed, channels rolled back to none, and the bot never answered.
#   A. agent_owned_dir makes the chain below home and hands every new dir to the seat;
#   B. a dir a root write already left root-owned goes back to the seat, others are untouched;
#   C. it never goes through a link, a file or a ".." component;
#   D. _install_bundled_skill gives the seat the skills dir itself, for every harness type;
#   E. the Telegram connect's notify-user seed heals the dir before the seat writes into it.
# chown and the owner read are stubbed at their seams: the harness is not root.
# TIER: core
# Run: timeout 60 bash tests/pack_skills_dir_owner_unit.sh
set -uo pipefail
export GH_ORG=5dive-ai
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

TMP="$(mktemp -d /tmp/pack-skills-owner.XXXXXX)"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/registry.sh lib/agent_setup.sh cmd_skill.sh cmd_pack.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e
JSON_MODE=1
export AGENT_HOME_ROOT="$TMP/home" REGISTRY="$TMP/agents.json"

PASS=0; FAIL=0
ok_()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad_() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
is()   { [[ "$2" == "$3" ]] && ok_ "$1" || bad_ "$1 (want [$3] got [$2])"; }

CHOWNS="$TMP/chowns"
chown() { printf '%s\n' "$*" >>"$CHOWNS"; }
ROOT_OWNED=""   # space-separated dirs the owner read reports as uid 0
_agent_dir_uid() { [[ " $ROOT_OWNED " == *" $1 "* ]] && echo 0 || echo 1000; }
chowned() { grep -qxF -- "$1" "$CHOWNS" 2>/dev/null; }

echo "== A. a fresh chain is made and handed to the seat =="
H="$AGENT_HOME_ROOT/agent-dude"; mkdir -p "$H"; : >"$CHOWNS"
agent_owned_dir agent-dude "$H" "$H/.grok/skills"; is "A1 rc 0" "$?" 0
[[ -d "$H/.grok/skills" ]] && ok_ "A2 ~/.grok/skills exists" || bad_ "A2 ~/.grok/skills was not made"
chowned "agent-dude:agent-dude $H/.grok" && ok_ "A3 ~/.grok goes to the seat" || bad_ "A3 ~/.grok not chowned: $(cat "$CHOWNS")"
chowned "agent-dude:agent-dude $H/.grok/skills" && ok_ "A4 ~/.grok/skills goes to the seat" || bad_ "A4 ~/.grok/skills not chowned"
chowned "agent-dude:agent-dude $H" && bad_ "A5 the home itself was chowned" || ok_ "A5 the home itself is left alone"

echo "== B. a root-owned dir is healed; a seat-owned one is untouched =="
: >"$CHOWNS"
agent_owned_dir agent-dude "$H" "$H/.grok/skills"
is "B1 nothing to heal: no chown at all" "$(wc -l <"$CHOWNS" | tr -d ' ')" 0
ROOT_OWNED="$H/.grok/skills"
agent_owned_dir agent-dude "$H" "$H/.grok/skills"; is "B2 rc 0" "$?" 0
chowned "agent-dude:agent-dude $H/.grok/skills" && ok_ "B3 the root-owned skills dir goes back to the seat" || bad_ "B3 root-owned dir not healed"
chowned "agent-dude:agent-dude $H/.grok" && bad_ "B4 a seat-owned parent was chowned" || ok_ "B4 its seat-owned parent is untouched"
ROOT_OWNED=""

echo "== C. never through a link, a file or .. =="
mkdir -p "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$H/.agents"
agent_owned_dir agent-dude "$H" "$H/.agents/skills"; is "C1 a symlinked component is refused" "$?" 1
[[ ! -e "$TMP/elsewhere/skills" ]] && ok_ "C2 nothing made through the link" || bad_ "C2 a dir was made through the link"
rm -f "$H/.agents"; : >"$H/.codex"
agent_owned_dir agent-dude "$H" "$H/.codex/skills"; is "C3 a file component is refused" "$?" 1
rm -f "$H/.codex"
agent_owned_dir agent-dude "$H" "$H/../x/skills"; is "C4 a .. component is refused" "$?" 1
agent_owned_dir agent-dude "$H" "$TMP/outside"; is "C5 a dir outside the home is refused" "$?" 1

echo "== D. the pack import gives the seat its skills dir, every harness type =="
agent_type() { registry_read | jq -r --arg n "$1" '.agents[$n].type // empty'; }
_pack_as_agent() { shift; "$@"; }
mkdir -p "$TMP/bundle/mail"; printf '# mail\n' >"$TMP/bundle/mail/SKILL.md"
for t in grok codex opencode pi antigravity hermes openclaw claude; do
  rm -rf "$H"; mkdir -p "$H"; : >"$CHOWNS"
  jq -n --arg t "$t" '{agents:{dude:{type:$t}}}' >"$REGISTRY"
  dir="$H/$(skills_install_dir "$t")"
  _install_bundled_skill dude mail "$TMP/bundle/mail"; rc=$?
  if (( rc == 0 )) && [[ -f "$dir/mail/SKILL.md" ]] && chowned "agent-dude:agent-dude $dir"; then
    ok_ "D $t: ~/$(skills_install_dir "$t") is the seat's"
  else
    bad_ "D $t: rc=$rc, skills dir $dir not handed to the seat ($(tr '\n' ';' <"$CHOWNS"))"
  fi
done

echo "== E. connecting Telegram heals the dir before the seat writes =="
SEEN="$TMP/seen"; : >"$SEEN"
notify_user_skill_src() { printf '%s\n' "$TMP/bundle/mail/SKILL.md"; }
agent_owned_dir() { printf 'own %s\n' "$*" >>"$SEEN"; }
sudo() { printf 'sudo %s\n' "$*" >>"$SEEN"; }
seed_notify_user_skill agent-dude /home/agent-dude/.grok/skills
is "E1 the heal runs first, on the seat's home and the skills dir" "$(head -1 "$SEEN")" "own agent-dude /home/agent-dude /home/agent-dude/.grok/skills"
is "E2 ...then the seat's own mkdir" "$(sed -n 2p "$SEEN")" "sudo -u agent-dude mkdir -p /home/agent-dude/.grok/skills/notify-user"

echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
