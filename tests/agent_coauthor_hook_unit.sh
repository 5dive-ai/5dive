#!/usr/bin/env bash
# DIVE-4667: stable per-seat OpenAgent co-author trailers, with a box-wide off switch.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

TMP=$(mktemp -d /tmp/agent-coauthor.XXXXXX)
PASS=0; FAIL=0
ok_t() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
is() { [[ "$2" == "$3" ]] && ok_t "$1" || { bad_t "$1 (want=$2 got=$3)"; }; }

# Load the canonical renderer, then materialise exactly what setup installs.
source src/lib/agent_setup.sh
HOOKS="$TMP/hooks"; mkdir -p "$HOOKS"
render_agent_coauthor_hook >"$HOOKS/prepare-commit-msg"
chmod +x "$HOOKS/prepare-commit-msg"
if [[ "${MUTATE_AUTHOR:-0}" == 1 ]]; then
  sed -i '3i git config --global user.email hijacked@example.com' "$HOOKS/prepare-commit-msg"
fi
if [[ "${MUTATE_SWITCH:-0}" == 1 ]]; then
  sed -i 's/^\[\[ "$coauthor" == off \]\] && exit 0$/: # mutant ignores switch/' "$HOOKS/prepare-commit-msg"
fi

cmp -s "$HOOKS/prepare-commit-msg" scripts/git-hooks/prepare-commit-msg \
  && ok_t "in-repo hook is byte-exact with the managed renderer" \
  || [[ "${MUTATE_AUTHOR:-0}${MUTATE_SWITCH:-0}" != 00 ]] || bad_t "in-repo hook drifted from renderer"
cmp -s scripts/git-hooks/prepare-commit-msg scripts/git-hooks-portable/prepare-commit-msg \
  && ok_t "portable and in-repo hook copies are byte-exact" \
  || bad_t "portable hook drifted from in-repo hook"

export GIT_CONFIG_GLOBAL="$TMP/global.gitconfig"
git config --global user.name "Human Owner"
git config --global user.email "owner@example.com"
git config --global 5dive.seat-name "dario"
git config --global 5dive.openagent-id "oa-7f3a00000000"
git config --global 5dive.box-config "$TMP/box.json"
git config --global core.hooksPath "$HOOKS"

REPO="$TMP/repo"; git init -q "$REPO"
git -C "$REPO" config commit.gpgsign false
printf one >"$REPO/file"; git -C "$REPO" add file; git -C "$REPO" commit -qm "first"
body=$(git -C "$REPO" log -1 --format=%B)
is "fresh commit has exactly one seat trailer" 1 "$(grep -c '^Co-Authored-By: dario <oa-7f3a00000000@openagent.5dive.ai>$' <<<"$body")"
is "commit author remains the human" "Human Owner <owner@example.com>" "$(git -C "$REPO" log -1 --format='%an <%ae>')"
is "the stable local part maps to the public card URL" \
  "https://openagent.5dive.ai/card/oa-7f3a00000000" \
  "https://openagent.5dive.ai/card/$(sed -n 's/.*<\(oa-[0-9a-f]*\)@openagent.5dive.ai>.*/\1/p' <<<"$body")"

git -C "$REPO" commit --amend -qm "amended"
is "amend still has exactly one seat trailer" 1 \
  "$(git -C "$REPO" log -1 --format=%B | grep -c 'oa-7f3a00000000@openagent.5dive.ai')"

pick_base=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" switch -qc pick-source
printf pick >"$REPO/picked"; git -C "$REPO" add picked; git -C "$REPO" commit -qm "picked"
pick_sha=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" switch -q --detach "$pick_base"
git -C "$REPO" cherry-pick "$pick_sha" >/dev/null \
  || bad_t "cherry-pick completed (precondition for trailer assertion)"
is "cherry-pick still has exactly one seat trailer" 1 \
  "$(git -C "$REPO" log -1 --format=%B | grep -c 'oa-7f3a00000000@openagent.5dive.ai')"

rebase_base=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" switch -qc rebase-source
printf branch >"$REPO/rebased"; git -C "$REPO" add rebased; git -C "$REPO" commit -qm "rebased"
git -C "$REPO" switch -q --detach "$rebase_base"
printf trunk >"$REPO/trunk"; git -C "$REPO" add trunk; git -C "$REPO" commit -qm "trunk"
onto=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" switch -q rebase-source
git -C "$REPO" rebase -q "$onto"
is "rebase still has exactly one seat trailer" 1 \
  "$(git -C "$REPO" log -1 --format=%B | grep -c 'oa-7f3a00000000@openagent.5dive.ai')"

# An existing model trailer stays, while a stale display name for this stable id
# is replaced rather than duplicated.
printf 'subject\n\nCo-Authored-By: Claude <claude@example.com>\nCo-Authored-By: old-name <oa-7f3a00000000@openagent.5dive.ai>\n' >"$TMP/message"
"$HOOKS/prepare-commit-msg" "$TMP/message"
is "existing model co-author remains" 1 "$(grep -c 'Claude <claude@example.com>' "$TMP/message")"
is "stable seat id is deduplicated across display-name changes" 1 "$(grep -c 'oa-7f3a00000000@openagent.5dive.ai' "$TMP/message")"
grep -q 'Co-Authored-By: dario <oa-7f3a00000000@openagent.5dive.ai>' "$TMP/message" \
  && ok_t "canonical current seat name is written" || bad_t "current seat name missing"

# Box-wide off applies to every seat and never rewrites an existing commit.
printf '{"coauthor":"off"}\n' >"$TMP/box.json"
before=$(git -C "$REPO" rev-parse HEAD)
printf two >>"$REPO/file"; git -C "$REPO" add file; git -C "$REPO" commit -qm "off"
is "coauthor=off appends no seat trailer" 0 \
  "$(git -C "$REPO" log -1 --format=%B | grep -c '@openagent.5dive.ai' || true)"
git -C "$REPO" cat-file -e "$before^{commit}" 2>/dev/null \
  && ok_t "switching off leaves existing commits intact" || bad_t "existing commit changed"

printf '{"coauthor":"on"}\n' >"$TMP/box.json"
git config --global 5dive.seat-name "codex-seat"
printf three >>"$REPO/file"; git -C "$REPO" add file; git -C "$REPO" commit -qm "on again"
grep -q 'Co-Authored-By: codex-seat <oa-7f3a00000000@openagent.5dive.ai>' < <(git -C "$REPO" log -1 --format=%B) \
  && ok_t "box-wide on covers a non-Claude seat" || bad_t "non-Claude seat trailer missing"

is "hook never changes configured author email" "owner@example.com" "$(git config --global user.email)"
is "hook never changes configured author name" "Human Owner" "$(git config --global user.name)"

# Stable ids are minted once, stored in the registry, and the upgrade reconciler
# installs every seat (not only Claude). Drive the real reconciler with a fake
# registry and installer so no host user or global config is touched.
source src/cmd_agent_create.sh
REGFILE="$TMP/agents.json"
printf '%s\n' '{"agents":{"claude-seat":{"type":"claude"},"codex-seat":{"type":"codex","openagentId":"oa-111111111111"}}}' >"$REGFILE"
registry_read() { cat "$REGFILE"; }
registry_write() { cat >"$REGFILE"; }
require_root() { return 0; }
ok() { :; }
warn() { :; }
fail() { return 1; }
_openagent_id_candidate() { printf 'oa-222222222222\n'; }
install_agent_coauthor_hook() { printf '%s %s\n' "$1" "$2" >>"$TMP/installed"; }
cmd_agent_reconcile_coauthors
is "upgrade mints an id for an existing seat without one" "oa-222222222222" \
  "$(jq -r '.agents["claude-seat"].openagentId' "$REGFILE")"
is "upgrade preserves an existing stable id" "oa-111111111111" \
  "$(jq -r '.agents["codex-seat"].openagentId' "$REGFILE")"
is "upgrade installs hooks for every coding-tool type" 2 "$(wc -l <"$TMP/installed" | tr -d ' ')"
cmd_agent_reconcile_coauthors
is "a second upgrade does not mint new ids" "oa-222222222222" \
  "$(jq -r '.agents["claude-seat"].openagentId' "$REGFILE")"
grep -q 'agent _reconcile_coauthors' install.sh \
  && ok_t "fresh install and upgrade invoke the fleet reconciler" || bad_t "installer migration call missing"
grep -q 'openagentId: \$oid' src/cmd_agent_create.sh \
  && ok_t "fresh create writes the stable id into the registry entry" || bad_t "fresh registry id write missing"

echo
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
