#!/usr/bin/env bash
# DIVE-4955 — third-party plugins install from the command line, labelled by
# where they come FROM, never by what their own manifest says.
#
# Before this row the trust gate read `fivedive.trust.review` out of the plugin's
# own plugin.json: any GitHub repo that wrote "review":"official" installed as
# official, and anything else was refused. lodar opened third-party on
# 2026-09-25 ("open for all via command line ... any repo that follows our plugin
# standard"), so the rule is now:
#   * the STANDARD is asked of the manifest: a `fivedive` block naming contract
#     "1". No block -> refused, naming the contract doc.
#   * the TIER is asked of the SOURCE: `official` only from a GitHub owner in
#     PLUGIN_OFFICIAL_OWNERS (or the operator-pinned registry); everyone else is
#     `community`. The manifest can lower its tier, never raise it.
#   * community installs behind a consent screen naming its source@commit and
#     saying there is no sandbox; `--official-only` (the dashboard) refuses it.
#
# LABELS. [D] = red on the pre-fix tree (92fcce9d). [C] = a control, green on
# both trees. [F] = a fence that passes on both and is labelled so nobody reads
# it as evidence the fix did something. T0a/T6 call functions the fix adds, so on
# the old tree they are red by absence, not by behaviour.
#
# HOW IT FETCHES. Real git, real clones: tests/lib/github_fixture.sh points
# https://github.com/ at local directories through git's own url.insteadOf, so
# the product records exactly the owner/repo a box would record.
#
# LIVE ARMS (opt-in, FIVEDIVE_LIVE_GITHUB=1): the real 5dive-ai/5dive-voice,
# 5dive-council, 5dive-ui and voice@5dive-plugins over the network, through the
# dashboard's --official-only path. Not run in CI, and they say so.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/header.sh
# shellcheck source=/dev/null
source src/cmd_plugin.sh
set +e -o pipefail   # header.sh turns errexit on; run() below needs it off

require_root() { :; }
# The seat walk is not the subject and must never touch a real seat on the host
# this runs on.
plugin_seat_apply() { return 0; }
plugin_seat_is_seat_facing() { return 1; }

TMP="$(mktemp -d)"
export STATE_DIR="$TMP/state"
unset FIVEDIVE_PLUGIN_REGISTRY
export GH_ORG=5dive-ai; unset _GH_ORG_RESOLVED   # the registry URL is https://github.com/5dive-ai/5dive-plugins.git
JSON_MODE=0

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

OUT=""; ERR=""; RC=0
run() {
  local o="$TMP/.o" e="$TMP/.e"
  ( "$@" ) >"$o" 2>"$e"; RC=$?
  OUT=$(cat "$o"); ERR=$(cat "$e")
  return 0
}
installed() { jq -r --arg k "$1" 'if has($k) then "yes" else "no" end' "$(_plugin_installed_json)" 2>/dev/null || echo no; }

# shellcheck source=/dev/null
. tests/lib/github_fixture.sh
G="$TMP/github"
gh_fixture_seam "$G"

# mkrepo <owner>/<repo> <plugin> <version> <review> — a standalone plugin repo
# in the shape the voice migration guide fixes: marketplace at the root, the
# plugin in its own subdirectory.
mkrepo() {  # ... [block|noblock|emptyblock]
  local d="$G/$1.git" p="$2" v="$3" r="$4" shape="${5:-block}"
  mkdir -p "$d/.claude-plugin" "$d/$p/.claude-plugin"
  jq -cn --arg p "$p" --arg v "$v" --arg r "$r" --arg shape "$shape" \
    '{name:$p, version:$v, description:"fixture", author:{name:"t"},
      fivedive:{contract:"1", capabilities:["channel"], grants:["network"],
                trust:{publisher:"t", did:"did:key:t", review:$r}}}
     | if $shape == "noblock" then del(.fivedive)
       elif $shape == "emptyblock" then .fivedive = {} else . end' \
    > "$d/$p/.claude-plugin/plugin.json"
  jq -cn --arg p "$p" '{name:$p, owner:{name:"t"}, plugins:[{name:$p, description:"f", source:("./" + $p)}]}' \
    > "$d/.claude-plugin/marketplace.json"
  gh_fixture_publish "$d" >/dev/null
}
bump() {  # bump <owner>/<repo> <plugin> <version>
  local d="$G/$1.git"
  jq --arg v "$3" '.version=$v' "$d/$2/.claude-plugin/plugin.json" > "$TMP/x" && mv "$TMP/x" "$d/$2/.claude-plugin/plugin.json"
  gh_fixture_publish "$d" >/dev/null
}

mkrepo 5dive-ai/5dive-plugins voice   1.0.0 official     # the registry itself
mkrepo 5dive-ai/good          good    1.0.0 official
mkrepo 5dive-ai/modest        modest  1.0.0 unreviewed
mkrepo 5dive-ai/plain         plain   1.0.0 community
mkrepo 5dive-com/legacyorg    legacyorg 1.0.0 official
mkrepo acme/evil              evil    1.0.0 official
mkrepo acme/plainclaude       plainclaude 1.0.0 official noblock     # a plain Claude Code plugin
mkrepo acme/halfblock         halfblock 1.0.0 official emptyblock   # "fivedive": {}
# A FORK: byte-identical to 5dive-ai/good, under another owner.
mkdir -p "$G/mallory"; cp -a "$G/5dive-ai/good.git" "$G/mallory/good.git"

# =============================================================================
# T0 — the harness really fetches through the seam
# =============================================================================
t "T0a the subject defines the decision" "function" "$(type -t _plugin_mkt_is_official 2>/dev/null || echo missing)"
t "T0b a fixture repo really clones through https://github.com/ (the seam is live)" "0" \
  "$(command git clone -q https://github.com/acme/evil.git "$TMP/probe" 2>/dev/null; echo $?)"
EVILSHA=$(command git -C "$G/acme/evil.git" rev-parse --short=12 HEAD)
tier() { jq -r --arg k "$1" '.[$k].review // "ABSENT"' "$(_plugin_installed_json)"; }

# =============================================================================
# T1 — a stranger's plugin that follows the standard INSTALLS, as community
# =============================================================================
run cmd_plugin_add acme/evil --yes
t  "T1a [F] acme/evil (follows the standard, manifest claims official) installs" "0" "$RC"
t  "T1b [D] ...STORED as community — the tier the source earns, not the one it claimed" "community" "$(tier evil@evil)"
tc "T1c [D] the consent output shows the SOURCE and the commit we can check" "source:     acme/evil@$EVILSHA" "$OUT"
tc "T1d [D] ...labels the publisher as the plugin's own claim" "claimed by the plugin" "$OUT"
tc "T1e [D] ...and says plainly there is no sandbox" "Not from 5dive. It runs with your agents' access; there is no sandbox." "$OUT"
tc "T1f [D] ...and names the only off switch there is" "sudo 5dive plugin disable evil@evil" "$OUT"
tc "T1g [D] ...and the review line says community" "review:     community" "$OUT"
tc "T1h [C] ...and still lists what it is handed" "handed to it:" "$OUT"

run cmd_plugin_add https://github.com/acme/evil.git --as=evil-url --yes
t  "T1i [D] the same repository by URL: installs, as community" "0|community" "$RC|$(tier evil@evil-url)"

# "A fork of 5dive-ai/x under another owner" is community.
run cmd_plugin_add mallory/good --as=mallory-good --yes
t  "T1j [D] a byte-identical FORK of 5dive-ai/good under another owner is community" "0|community" "$RC|$(tier good@mallory-good)"

run cmd_plugin_marketplace add acme/evil --as=acme-evil
t  "T1k setup: a stranger's marketplace registers" "0" "$RC"
run cmd_plugin_add evil@acme-evil --yes
t  "T1l [D] the qualified ref evil@<its marketplace> gets the same answer" "0|community" "$RC|$(tier evil@acme-evil)"

run cmd_plugin_marketplace add "$G/5dive-ai/good.git" --as=local-good
run cmd_plugin_add good@local-good --yes
t  "T1m [D] a LOCAL copy of a 5dive-ai plugin is community: a path proves nothing about who wrote it" "0|community" "$RC|$(tier good@local-good)"

run cmd_plugin_add acme/evil --as=evil-noconsent
t  "T1n [F] no terminal and no --yes is still a refusal for community (consent is not decorative)" "$E_PERMISSION" "$RC"

# =============================================================================
# T2 — the standard: no `fivedive` block, no install
# =============================================================================
run cmd_plugin_add acme/plainclaude --yes
t  "T2a [F] a plain Claude Code plugin (no fivedive block) is REFUSED" "$E_PERMISSION" "$RC"
tc "T2b [D] ...naming the standard" "does not follow the 5dive plugin standard" "$ERR"
tc "T2c [D] ...and pointing at the contract doc" "docs/plugin-contract.md" "$ERR"
t  "T2d ...and nothing was installed" "ABSENT" "$(tier plainclaude@plainclaude)"
run cmd_plugin_add acme/halfblock --yes
t  "T2e [F] an EMPTY fivedive block declares nothing, so it does not follow it either" "$E_PERMISSION" "$RC"
tc "T2f [D] ...same message" "does not follow the 5dive plugin standard" "$ERR"
t  "T2g [D] the contract doc the message names exists in this tree" "yes" "$([[ -s docs/plugin-contract.md ]] && echo yes || echo no)"

# =============================================================================
# T3 — --official-only: the dashboard's one-click path
# =============================================================================
run cmd_plugin_add acme/evil --as=evil-oo --official-only --yes
t  "T3a [D] --official-only REFUSES a community plugin" "$E_PERMISSION" "$RC"
tc "T3b ...saying this path takes only official plugins" "this install path takes only official plugins" "$ERR"
tc "T3c ...and why its own claim did not count" "cannot vouch for itself" "$ERR"
tc "T3d ...and the command-line route, with sudo" "sudo 5dive plugin add evil@evil-oo" "$ERR"
t  "T3e ...and installed nothing" "ABSENT" "$(tier evil@evil-oo)"
run cmd_plugin_add 5dive-ai/good --yes
t  "T3f [C] our own installs, official" "0|official" "$RC|$(tier good@good)"
tc "T3g [C] ...whose consent says official" "review:     official" "$OUT"
run cmd_plugin_add voice@5dive-plugins --official-only --yes
t  "T3h [D] --official-only installs voice@5dive-plugins from the self-registered registry" "0|official" "$RC|$(tier voice@5dive-plugins)"
t  "T3i ...which registered itself from the 5dive-ai URL" "https://github.com/5dive-ai/5dive-plugins.git" \
   "$(jq -r '.["5dive-plugins"].source' "$(_plugin_mkt_json)")"
run cmd_plugin_add 5dive-com/legacyorg --official-only --yes
t  "T3j [D] 5dive-com (the org gh_org() falls back to) is ours too, on the --official-only path" "0|official" "$RC|$(tier legacyorg@legacyorg)"

# The built-in channel refusal (DIVE-4466) still runs first, on both paths.
run cmd_plugin_add telegram@5dive-plugins --yes
t  "T3k [C] telegram@5dive-plugins is still refused as a per-agent channel" "$E_USAGE" "$RC"
tc "T3l ...pointing at --channels" "--channels=telegram" "$ERR"

# =============================================================================
# T4 — the manifest may DOWNGRADE, never upgrade
# =============================================================================
run cmd_plugin_add 5dive-ai/modest --yes
t  "T4a [D] a 5dive-ai plugin whose manifest says unreviewed installs AS unreviewed" "0|unreviewed" "$RC|$(tier modest@modest)"
tc "T4b ...and the screen does not call it 'not from 5dive'" "From 5dive's GitHub, but its publisher has not marked it official." "$OUT"
run cmd_plugin_add 5dive-ai/plain --as=plain-oo --official-only --yes
t  "T4c [D] ...and --official-only refuses a 5dive-ai plugin that calls itself community" "$E_PERMISSION" "$RC"

# =============================================================================
# T5 — UPGRADE re-decides
# =============================================================================
# The pre-fix population: a box that installed a stranger's plugin while the
# claim still counted. Its record says official. Seeded by hand because no path
# on this tree can write that record any more — which is the point.
seed_legacy() {  # <plugin> <mkt>
  local p="$1" m="$2" dest; dest="$(_plugin_cache_dir)/$m/$p/0.9.0"
  mkdir -p "$(dirname "$dest")"
  cp -a "$(_plugin_mkt_dir)/$m/$p" "$dest"
  ln -sfn "$dest" "$(_plugin_enabled_dir)/$p@$m"
  jq --arg k "$p@$m" --arg p "$p" --arg m "$m" \
     '.[$k] = {plugin:$p, marketplace:$m, version:"0.9.0", enabled:true, review:"official",
               publisher:"t", capabilities:["channel"], grants:[], verbs:[]}' \
     "$(_plugin_installed_json)" > "$TMP/x" && mv "$TMP/x" "$(_plugin_installed_json)"
}
run cmd_plugin_marketplace add acme/evil --as=legacy-evil
seed_legacy evil legacy-evil
JSON_MODE=1 run cmd_plugin_list; JSON_MODE=0
t  "T5a [D] 'plugin list --json' re-decides a legacy record: community, not its stored official" "community" \
   "$(jq -r '.data["evil@legacy-evil"].review // .["evil@legacy-evil"].review // "?"' <<<"$OUT")"
run cmd_plugin_list
tc "T5b [D] ...and so does the table" "community" "$(grep 'evil@legacy-evil' <<<"$OUT")"
run cmd_plugin_upgrade evil@legacy-evil
t  "T5c [F] upgrading it proceeds (consent was given at add, to this source)" "0" "$RC"
t  "T5d [D] ...and the record now carries the decided tier" "community" "$(tier evil@legacy-evil)"
tc "T5e [D] ...and says so out loud" "recorded as official on its own manifest's word" "$ERR"
tc "T5f [D] ...naming the source and the missing sandbox" "not published by 5dive; there is no sandbox" "$ERR"

# An upgrade that stops following the standard is refused.
jq 'del(.fivedive) | .version="2.0.0"' "$G/acme/evil.git/evil/.claude-plugin/plugin.json" > "$TMP/x" \
  && mv "$TMP/x" "$G/acme/evil.git/evil/.claude-plugin/plugin.json"
gh_fixture_publish "$G/acme/evil.git" >/dev/null
run _plugin_mkt_upgrade acme-evil
run cmd_plugin_upgrade evil@acme-evil
t  "T5g [F] an upgrade whose manifest drops the fivedive block is refused" "$E_PERMISSION" "$RC"
tc "T5h [D] ...as not following the standard" "does not follow the 5dive plugin standard" "$ERR"
t  "T5i ...and the pointer did not move" "1.0.0" "$(basename "$(readlink "$(_plugin_enabled_dir)/evil@acme-evil")")"

bump 5dive-ai/good good 1.1.0
run _plugin_mkt_upgrade good
run cmd_plugin_upgrade good@good
t  "T5j [C] upgrading our own still works, and stays official" "0|official" "$RC|$(tier good@good)"

# =============================================================================
# T6 — the name is not the identity
# =============================================================================
# A fresh store where the real registry is unreachable, so the first thing that
# claims the name `5dive-plugins` is a stranger.
squat() {
  export STATE_DIR="$TMP/state-squat" GH_ORG=no-such-org; unset _GH_ORG_RESOLVED
  cmd_plugin_marketplace add acme/evil --as=5dive-plugins >/dev/null 2>&1 || exit 97
  cmd_plugin_add evil@5dive-plugins --official-only --yes
}
run squat
t  "T6a [D] a stranger's repo registered AS '5dive-plugins' is still not official" "$E_PERMISSION" "$RC"

# The operator pin: the registry at a local checkout is ours only under its own
# name, only while the pin is set, and only at the exact recorded path.
pin() {  # <as-name>
  export STATE_DIR="$TMP/state-pin-$1" FIVEDIVE_PLUGIN_REGISTRY="$G/5dive-ai/5dive-plugins.git"
  if [[ "$1" == 5dive-plugins ]]; then cmd_plugin_add voice@5dive-plugins --official-only --yes
  else cmd_plugin_marketplace add "$FIVEDIVE_PLUGIN_REGISTRY" --as="$1" >/dev/null 2>&1 || exit 97
       cmd_plugin_add "voice@$1" --official-only --yes; fi
}
run pin 5dive-plugins
t  "T6b [D] the operator-pinned local registry (FIVEDIVE_PLUGIN_REGISTRY) is official" "0" "$RC"
run pin not-the-registry
t  "T6c [D] ...the same checkout added under ANY other name is local, so not official" "$E_PERMISSION" "$RC"

# =============================================================================
# T7 — the owner parser, table-driven. Strict on purpose.
# =============================================================================
# NOT IN THIS TABLE: the two SSH spellings (scp-style and ssh:// with the git
# user) and any userinfo-before-github URL. The fixture guard refuses a literal
# user-at-host string in a test file as a possible real address, and encoding one
# around the guard is not a fix. Those branches are read, not run: see
# _plugin_github_owner, where each is one literal prefix strip.
owner_of() { _plugin_github_owner "$1" || echo "<none>"; }
while IFS='|' read -r src want; do
  [[ -z "$src" ]] && continue
  t "T7 owner of '$src'" "$want" "$(owner_of "$src")"
done <<'TABLE'
5dive-ai/5dive-voice|5dive-ai
5DIVE-AI/5dive-voice|5dive-ai
https://github.com/5dive-ai/5dive-voice.git|5dive-ai
https://github.com/5dive-ai/5dive-voice|5dive-ai
https://github.com/5dive-ai/5dive-voice/|5dive-ai
https://github.com/acme/5dive-voice.git|acme
http://github.com/5dive-ai/5dive-voice.git|<none>
https://evil.example/5dive-ai/5dive-voice.git|<none>
https://github.com.evil.example/5dive-ai/x.git|<none>
https://github.com/5dive-ai/x/tree/main|<none>
5dive-ai/x/y|<none>
/opt/5dive-ai/x|<none>
./5dive-ai/x|<none>
../5dive-ai/x|<none>
TABLE

# =============================================================================
# T8 — LIVE (opt-in): the real repositories the row names, on the dashboard path
# =============================================================================
if [[ "${FIVEDIVE_LIVE_GITHUB:-}" == 1 ]]; then
  live() {  # <ref> [flag] — each in its own empty store, real network, no seam
    rm -rf "$TMP/state-live"
    export STATE_DIR="$TMP/state-live" GIT_CONFIG_GLOBAL=/dev/null GH_ORG=5dive-ai; unset _GH_ORG_RESOLVED
    cmd_plugin_add "$1" --yes ${2:+"$2"} || exit
    jq -r 'to_entries[0].value.review' "$(_plugin_installed_json)"
  }
  for ref in 5dive-ai/5dive-voice 5dive-ai/5dive-council 5dive-ai/5dive-ui voice@5dive-plugins; do
    run live "$ref"
    t "T8 [C] LIVE $ref installs as official, unchanged" "0|official" "$RC|$(tail -1 <<<"$OUT")"
    [[ "$RC" == 0 ]] || printf '   %s\n' "$(tail -3 <<<"$ERR")"
    run live "$ref" --official-only
    t "T8 [D] LIVE $ref installs on the dashboard's --official-only path" "0|official" "$RC|$(tail -1 <<<"$OUT")"
    [[ "$RC" == 0 ]] || printf '   %s\n' "$(tail -3 <<<"$ERR")"
  done
else
  printf '  !! NOT RUN — T8 LIVE arms (real 5dive-ai repos over the network). Set FIVEDIVE_LIVE_GITHUB=1.\n'
fi

printf '\nplugin_official_from_source_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
