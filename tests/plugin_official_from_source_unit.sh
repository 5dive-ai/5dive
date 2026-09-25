#!/usr/bin/env bash
# DIVE-4955 — `official` is decided by where a plugin came FROM, never by what
# its own manifest says.
#
# Before this row the trust gate read `fivedive.trust.review` out of the plugin's
# own plugin.json, so any GitHub repo that wrote "review":"official" installed
# box-wide — the third-party deferral (lodar, DIVE-4020 gate, 2026-09-07) was a
# field in a stranger's manifest. The rule now: `official` iff the marketplace
# was registered from a GitHub owner in PLUGIN_OFFICIAL_OWNERS (5dive-ai, and its
# old name 5dive-com), or is the registry the operator pinned with
# FIVEDIVE_PLUGIN_REGISTRY. The manifest may only DOWNGRADE.
#
# DIFFERENTIAL. Arms marked [D] are red on the pre-fix tree (92fcce9d) — each is a
# stranger's `official` claim that used to install. Arms marked [C] are controls
# that must stay green on both trees (our own plugins still install). Arms marked
# [F] are regression fences that pass on both trees and are labelled so nobody
# reads them as evidence the fix did something. T0a/T6 call functions the fix
# adds, so on the old tree they are red by absence, not by behaviour.
#
# HOW IT FETCHES. Real git, real clones: tests/lib/github_fixture.sh points
# https://github.com/ at local directories through git's own url.insteadOf, so
# the product records exactly the owner/repo a box would record.
#
# LIVE ARMS (opt-in, FIVEDIVE_LIVE_GITHUB=1): the real 5dive-ai/5dive-voice,
# 5dive-council, 5dive-ui and voice@5dive-plugins over the network. Not run in
# CI, and they say so.
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
mkrepo() {
  local d="$G/$1.git" p="$2" v="$3" r="$4"
  mkdir -p "$d/.claude-plugin" "$d/$p/.claude-plugin"
  jq -cn --arg p "$p" --arg v "$v" --arg r "$r" \
    '{name:$p, version:$v, description:"fixture", author:{name:"t"},
      fivedive:{contract:"1", capabilities:["channel"], grants:[],
                trust:{publisher:"t", did:"did:key:t", review:$r}}}' \
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
# A FORK: byte-identical to 5dive-ai/good, under another owner.
mkdir -p "$G/mallory"; cp -a "$G/5dive-ai/good.git" "$G/mallory/good.git"

# =============================================================================
# T0 — the harness really fetches through the seam
# =============================================================================
t "T0a the subject defines the decision" "function" "$(type -t _plugin_mkt_is_official 2>/dev/null || echo missing)"
t "T0b a fixture repo really clones through https://github.com/ (the seam is live)" "0" \
  "$(command git clone -q https://github.com/acme/evil.git "$TMP/probe" 2>/dev/null; echo $?)"

# =============================================================================
# T1 — [D] a stranger's `official` claim is refused at ADD
# =============================================================================
run cmd_plugin_add acme/evil --yes
t  "T1a [D] acme/evil, whose manifest says official, is REFUSED" "$E_PERMISSION" "$RC"
tc "T1b ...as community — the tier we decided, not the one it claimed" "is a community plugin" "$ERR"
tc "T1c ...and the refusal says why its claim did not count" "cannot vouch for itself" "$ERR"
t  "T1d ...and nothing was installed" "no" "$(installed evil@evil)"
t  "T1e ...and no code was copied" "no" "$([[ -d "$(_plugin_cache_dir)/evil" ]] && echo yes || echo no)"

run cmd_plugin_add https://github.com/acme/evil.git --as=evil-url --yes
t  "T1f [D] the same repository by URL is refused too" "$E_PERMISSION" "$RC"

# "A fork of 5dive-ai/x under another owner must NOT pass."
run cmd_plugin_add mallory/good --as=mallory-good --yes
t  "T1g [D] a byte-identical FORK of 5dive-ai/good under another owner is refused" "$E_PERMISSION" "$RC"
t  "T1h ...nothing installed" "no" "$(installed good@mallory-good)"

# The two-step form, which is what the dashboard's qualified ref resolves through.
run cmd_plugin_marketplace add acme/evil --as=acme-evil
t  "T1i setup: a stranger's marketplace can still be REGISTERED (browsing is not installing)" "0" "$RC"
run cmd_plugin_add evil@acme-evil --yes
t  "T1j [D] evil@<its marketplace> is refused — the qualified ref gets the same gate" "$E_PERMISSION" "$RC"

# A local directory is whatever was copied into it — even one of ours.
run cmd_plugin_marketplace add "$G/5dive-ai/good.git" --as=local-good
run cmd_plugin_add good@local-good --yes
t  "T1k [D] a LOCAL copy of a 5dive-ai plugin is community: a path proves nothing about who wrote it" "$E_PERMISSION" "$RC"

# =============================================================================
# T2 — [C] our own still install
# =============================================================================
run cmd_plugin_add 5dive-ai/good --yes
t  "T2a [C] 5dive-ai/good installs" "0" "$RC"
t  "T2b ...and the stored tier is the one we DECIDED" "official" \
   "$(jq -r '.["good@good"].review' "$(_plugin_installed_json)")"
tc "T2c ...and the consent screen says official" "review:     official" "$OUT$ERR"

run cmd_plugin_add voice@5dive-plugins --yes
t  "T2d [C] voice@5dive-plugins installs from the self-registered registry" "0" "$RC"
t  "T2e ...which registered itself from the 5dive-ai URL" "https://github.com/5dive-ai/5dive-plugins.git" \
   "$(jq -r '.["5dive-plugins"].source' "$(_plugin_mkt_json)")"

run cmd_plugin_add 5dive-com/legacyorg --yes
t  "T2f [C] 5dive-com (the org gh_org() falls back to) is ours too" "0" "$RC"

# =============================================================================
# T3 — [F] the manifest may DOWNGRADE (fences: green on both trees)
# =============================================================================
run cmd_plugin_add 5dive-ai/modest --yes
t  "T3a [F] a 5dive-ai plugin whose manifest says unreviewed stays refused" "$E_PERMISSION" "$RC"
tc "T3b ...as unreviewed" "is a unreviewed plugin" "$ERR"
run cmd_plugin_add 5dive-ai/plain --yes
t  "T3c [F] ...and one that says community stays refused" "$E_PERMISSION" "$RC"

# =============================================================================
# T4 — UPGRADE re-decides
# =============================================================================
# The pre-fix population: a box that installed acme/evil while the claim still
# counted. Its record says official. Seeded by hand because no path on this tree
# can produce it any more — which is the point.
seed_legacy() {  # <plugin> <mkt>
  local p="$1" m="$2" dest; dest="$(_plugin_cache_dir)/$m/$p/1.0.0"
  mkdir -p "$(dirname "$dest")"
  cp -a "$(_plugin_mkt_dir)/$m/$p" "$dest"
  ln -sfn "$dest" "$(_plugin_enabled_dir)/$p@$m"
  jq --arg k "$p@$m" --arg p "$p" --arg m "$m" \
     '.[$k] = {plugin:$p, marketplace:$m, version:"1.0.0", enabled:true, review:"official",
               publisher:"t", capabilities:["channel"], grants:[], verbs:[]}' \
     "$(_plugin_installed_json)" > "$TMP/x" && mv "$TMP/x" "$(_plugin_installed_json)"
}
seed_legacy evil acme-evil
bump acme/evil evil 1.1.0
run _plugin_mkt_upgrade acme-evil
run cmd_plugin_upgrade evil@acme-evil
t  "T4a [D] upgrading a stranger's self-described official plugin is REFUSED" "$E_PERMISSION" "$RC"
tc "T4b ...with the same reason" "cannot vouch for itself" "$ERR"
t  "T4c ...and the pointer did not move" "1.0.0" "$(basename "$(readlink "$(_plugin_enabled_dir)/evil@acme-evil")")"
t  "T4d ...and neither did the record" "1.0.0" "$(jq -r '.["evil@acme-evil"].version' "$(_plugin_installed_json)")"

bump 5dive-ai/good good 1.1.0
run _plugin_mkt_upgrade good
run cmd_plugin_upgrade good@good
t  "T4e [C] upgrading our own still works" "0" "$RC"
t  "T4f ...and the record carries the tier decided at upgrade" "official" \
   "$(jq -r '.["good@good"].review' "$(_plugin_installed_json)")"

# =============================================================================
# T5 — [D] the name is not the identity: squatting the registry's name
# =============================================================================
# A fresh store where the real registry is unreachable, so the first thing that
# claims the name `5dive-plugins` is a stranger.
squat() {
  export STATE_DIR="$TMP/state-squat" GH_ORG=no-such-org; unset _GH_ORG_RESOLVED
  cmd_plugin_marketplace add acme/evil --as=5dive-plugins >/dev/null 2>&1 || exit 97
  cmd_plugin_add evil@5dive-plugins --yes
}
run squat
t  "T5a [D] a stranger's repo registered AS '5dive-plugins' is still refused" "$E_PERMISSION" "$RC"

# The operator pin: the registry at a local checkout is ours only under its own
# name, only while the pin is set, and only at the exact recorded path.
pin() {  # <as-name>
  export STATE_DIR="$TMP/state-pin-$1" FIVEDIVE_PLUGIN_REGISTRY="$G/5dive-ai/5dive-plugins.git"
  if [[ "$1" == 5dive-plugins ]]; then cmd_plugin_add voice@5dive-plugins --yes
  else cmd_plugin_marketplace add "$FIVEDIVE_PLUGIN_REGISTRY" --as="$1" >/dev/null 2>&1 || exit 97
       cmd_plugin_add "voice@$1" --yes; fi
}
run pin 5dive-plugins
t  "T5b [C] the operator-pinned local registry (FIVEDIVE_PLUGIN_REGISTRY) installs voice" "0" "$RC"
run pin not-the-registry
t  "T5c [D] ...the same checkout added under ANY other name is local, so community" "$E_PERMISSION" "$RC"

# =============================================================================
# T6 — the owner parser, table-driven. Strict on purpose.
# =============================================================================
# NOT IN THIS TABLE: the two SSH spellings (scp-style and ssh:// with the git
# user) and any userinfo-before-github URL. The fixture guard refuses a literal
# user-at-host string in a test file as a possible real address, and encoding one
# around the guard is not a fix. Those branches are read, not run: see
# _plugin_github_owner, where each is one literal prefix strip.
owner_of() { _plugin_github_owner "$1" || echo "<none>"; }
while IFS='|' read -r src want; do
  [[ -z "$src" ]] && continue
  t "T6 owner of '$src'" "$want" "$(owner_of "$src")"
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
# T7 — LIVE (opt-in): the real repositories the row names
# =============================================================================
if [[ "${FIVEDIVE_LIVE_GITHUB:-}" == 1 ]]; then
  live() {  # <ref> — each in its own empty store, real network, no seam
    rm -rf "$TMP/state-live"
    export STATE_DIR="$TMP/state-live" GIT_CONFIG_GLOBAL=/dev/null GH_ORG=5dive-ai; unset _GH_ORG_RESOLVED
    cmd_plugin_add "$1" --yes
  }
  for ref in 5dive-ai/5dive-voice 5dive-ai/5dive-council 5dive-ai/5dive-ui voice@5dive-plugins; do
    run live "$ref"
    t "T7 [C] LIVE $ref installs" "0" "$RC"
    [[ "$RC" == 0 ]] || printf '   %s\n' "$(tail -3 <<<"$ERR")"
  done
else
  printf '  !! NOT RUN — T7 LIVE arms (real 5dive-ai repos over the network). Set FIVEDIVE_LIVE_GITHUB=1.\n'
fi

printf '\nplugin_official_from_source_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
