#!/usr/bin/env bash
# DIVE-4020 — the plugin contract's ENFORCER, graded by execution.
#
# WHY THIS FILE IS THE POINT OF THE ROW. Iteration 1 delivered the contract as a
# wiki page and was rejected because nothing enforced it: "an undeclared surface
# is inert" (§2) is a rule, and a rule with no code is a wish. So every arm here
# names the contract clause it grades and CALLS the real function — none of them
# greps the source for a line. A source grep certifies that a line exists; it
# cannot certify that a refusal refuses.
#
# HOW IT RUNS WITHOUT ROOT. `cmd_plugin.sh` is a fragment of the concatenated
# CLI: sourcing it defines functions and runs nothing. require_root is shadowed
# (the root check is a boundary this harness has no business owning) and
# STATE_DIR points at a throwaway tree — the same env-honouring seam header.sh
# already defines, which is why the store was put under STATE_DIR rather than a
# home in the first place.
#
# A REFUSAL IS TESTED IN A SUBSHELL ON PURPOSE. `fail` exits, and inside `( )`
# it exits only that subshell — which is precisely what makes the exit CODE
# observable here. (The same property is a hazard in production code, and
# _plugin_split_ref is written to avoid it; see its comment.)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT="$PWD"

# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/header.sh
# shellcheck source=/dev/null
source src/cmd_plugin.sh
# shellcheck source=/dev/null
source src/cmd_pack.sh

# header.sh line 14 is `set -euo pipefail` — sourcing it turns errexit ON in
# THIS shell, and under errexit the `( ... )` in run() below would take the
# harness down with the first refusal it is supposed to be grading. Every arm
# after that point would silently never run, which is the worst possible failure
# mode for a suite: a green-looking short read. Turn it back off explicitly.
set +e -o pipefail

require_root() { :; }

TMP="$(mktemp -d)"
export STATE_DIR="$TMP/state"

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

OUT=""; ERR=""; RC=0
# run <fn> [args...] -> sets OUT / ERR / RC.
#
# Deliberately NOT `rc=$(rc_of ...)`: a helper called inside `$( )` sets its
# globals in a SUBSHELL, so OUT/ERR would come back empty in the parent and
# every message arm would assert against "" and pass or fail for the wrong
# reason. That is the same trap this suite grades the SUBJECT for (see T1a's
# note), and a harness is not exempt from it.
run() {
  local o="$TMP/.o" e="$TMP/.e"
  ( "$@" ) >"$o" 2>"$e"; RC=$?
  OUT=$(cat "$o"); ERR=$(cat "$e")
  return 0
}

# ---- fixtures ---------------------------------------------------------------
# One fixture marketplace, one plugin per rule under test. Each is a REAL
# directory with a REAL manifest, because the validator reads directories.
MKT="$TMP/fixture-mkt"
mkdir -p "$MKT/.claude-plugin"

mkplugin() {  # mkplugin <dir-name> <manifest-json> [manifest-subdir]
  local n="$1" j="$2" sub="${3:-.claude-plugin}"
  mkdir -p "$MKT/$n/$sub"
  printf '%s\n' "$j" > "$MKT/$n/$sub/plugin.json"
}
mkindex() {  # rebuild the marketplace index from whatever plugins now exist
  local arr="[]" d n
  for d in "$MKT"/*/; do
    n=$(basename "${d%/}"); [[ "$n" == .* ]] && continue
    arr=$(jq -c --arg n "$n" '. + [{name:$n, description:("fixture " + $n), category:"test", source:("./" + $n)}]' <<<"$arr")
  done
  jq -n --argjson p "$arr" '{name:"fixture", description:"test fixture", owner:{name:"t"}, plugins:$p}' \
    > "$MKT/.claude-plugin/marketplace.json"
}

manifest() {  # manifest <name> <version> <review> [capabilities-json] [grants-json] [extra-json]
  jq -cn --arg n "$1" --arg v "$2" --arg r "$3" \
     --argjson caps "${4:-[]}" --argjson grants "${5:-[]}" --argjson extra "${6:-{\}}" \
     '{name:$n, version:$v, description:"fixture", author:{name:"t"},
       fivedive:({contract:"1", capabilities:$caps, grants:$grants,
                  trust:{publisher:"t", did:"did:key:t", review:$r}} + $extra)}'
}

mkplugin good     "$(manifest good 1.0.0 official '["channel"]' '["audio-io"]')"
mkplugin commonly "$(manifest commonly 1.0.0 community '["channel"]')"
mkplugin bare     '{"name":"bare","version":"1.0.0","description":"no fivedive block"}'
mkplugin wrongname "$(manifest not-wrongname 1.0.0 official)"
mkplugin nover    '{"name":"nover","description":"no version"}'
mkplugin badver   '{"name":"badver","version":"one","description":"x"}'
mkplugin badcap   "$(manifest badcap 1.0.0 official '["teleport"]')"
mkplugin badgrant "$(manifest badgrant 1.0.0 official '["channel"]' '["your-soul"]')"
mkplugin badtier  "$(manifest badtier 1.0.0 official)"
  jq '.fivedive.trust.review = "gold-star"' "$MKT/badtier/.claude-plugin/plugin.json" > "$TMP/x" && mv "$TMP/x" "$MKT/badtier/.claude-plugin/plugin.json"
mkplugin future   "$(manifest future 1.0.0 official)"
  jq '.fivedive.contract = "2"' "$MKT/future/.claude-plugin/plugin.json" > "$TMP/x" && mv "$TMP/x" "$MKT/future/.claude-plugin/plugin.json"
mkplugin aliased  "$(manifest aliased 1.0.0 official '["channel"]')" .5dive-plugin
mkplugin codexed  "$(manifest codexed 1.0.0 official '["channel"]')" .codex-plugin
# undeclared surfaces: ships the files, declares nothing
mkplugin sneaky   "$(manifest sneaky 1.0.0 official '["channel"]')"
  echo '{"mcpServers":{}}' > "$MKT/sneaky/.mcp.json"
  mkdir -p "$MKT/sneaky/skills"
# declared surfaces: ships the same files AND names them
mkplugin honest   "$(manifest honest 1.0.0 official '["channel","mcp","skill"]')"
  echo '{"mcpServers":{}}' > "$MKT/honest/.mcp.json"
  mkdir -p "$MKT/honest/skills"
mkindex

# DIVE-4202: the CLI ships no plugins of its own. The registry arms below resolve
# through this seam (cmd_plugin.sh _plugin_registry_source), which takes a local
# path so a unit test never touches the network. With no registry checkout the
# registry arms are NOT RUN and say so; the fixture arms are unaffected.
# EXPLICIT ONLY — no sibling-path fallback. `projects/5dive/5dive-plugins` is a
# SHARED checkout that sits on whatever feature branch someone left it on, so
# guessing it grades an arbitrary tree and calls the result "the registry". The
# pre-push rail caught exactly that: the shared checkout had no browser/voice and
# these arms went red against a tree nobody meant to grade. An unset variable
# gives a NOT-RUN banner, which is honest; a wrong tree is worse than no tree.
REGISTRY="${FIVEDIVE_PLUGIN_REGISTRY:-}"
if [[ -n "$REGISTRY" && -d "$REGISTRY" ]]; then
  export FIVEDIVE_PLUGIN_REGISTRY="$REGISTRY"
else
  REGISTRY=""
  unset FIVEDIVE_PLUGIN_REGISTRY
fi
JSON_MODE=0

# =============================================================================
# T0 — negative control on the harness itself
# =============================================================================
t "T0a the subject file really defined the verb (an empty source would pass every arm below vacuously)" \
  "function" "$(type -t cmd_plugin)"
t "T0b the fixture marketplace really has plugins" "yes" \
  "$([[ $(jq '.plugins|length' "$MKT/.claude-plugin/marketplace.json") -ge 10 ]] && echo yes || echo no)"

run _plugin_mkt_add "$MKT" --as=fixture
t "T0c fixture marketplace registers" "0" "$RC"

# =============================================================================
# §1 — the manifest. Every refusal below is a refusal to INSTALL.
# =============================================================================
run cmd_plugin_add wrongname@fixture --yes; t "T1a name that does not match the folder is refused" "$E_VALIDATION" "$RC"
tc "T1a-msg and it says which two disagree" "does not match the folder name" "$ERR"
run cmd_plugin_add nover@fixture --yes; t "T1b a manifest with no version is refused" "$E_VALIDATION" "$RC"
tc "T1b-msg and it says why version is load-bearing" "keyed on it" "$ERR"
run cmd_plugin_add badver@fixture --yes; t "T1c a version that is not a version number is refused" "$E_VALIDATION" "$RC"
run cmd_plugin_add badcap@fixture --yes; t "T1d an unknown capability is refused" "$E_VALIDATION" "$RC"
tc "T1d-msg and it lists the legal set" "channel mcp skill verb hook" "$ERR"
run cmd_plugin_add badgrant@fixture --yes; t "T1e an unknown grant is refused" "$E_VALIDATION" "$RC"
run cmd_plugin_add badtier@fixture --yes; t "T1f an unknown review tier is refused" "$E_VALIDATION" "$RC"
run cmd_plugin_add future@fixture --yes; t "T1g a plugin targeting a contract we do not implement is refused" "$E_VALIDATION" "$RC"
run cmd_plugin_add aliased@fixture --yes; t "T1h the .5dive-plugin/ alias the contract promises is honoured" "0" "$RC"
run cmd_plugin_add codexed@fixture --yes
t "T1i .codex-plugin/ is honoured too (plugins/telegram-codex ships exactly that and nothing else)" "0" "$RC"

# =============================================================================
# §2 — an undeclared surface is inert. The clause with teeth.
# =============================================================================
run cmd_plugin_add sneaky@fixture --yes
t  "T2a a plugin shipping an undeclared surface still installs" "0" "$RC"
tc "T2b ...and the undeclared MCP server is named out loud, not dropped silently" "does not declare the 'mcp' capability" "$ERR"
tc "T2c ...same for undeclared skills" "does not declare the 'skill' capability" "$ERR"
t  "T2d ...and what is RECORDED is what was DECLARED, so registration cannot pick the surface up later" \
   '["channel"]' "$(jq -c '.["sneaky@fixture"].capabilities' "$(_plugin_installed_json)")"

run cmd_plugin_add honest@fixture --yes
tn "T2e a plugin that DECLARES the surfaces it ships is not warned about (negative control for T2b)" \
   "does not declare" "$ERR"
t  "T2f ...and all three are recorded" '["channel","mcp","skill"]' \
   "$(jq -c '.["honest@fixture"].capabilities' "$(_plugin_installed_json)")"

# =============================================================================
# §5 + lodar's gate answer (2026-09-07): official only, and the door has no flag
# =============================================================================
run cmd_plugin_add good@fixture --yes; t "T3a an official plugin installs" "0" "$RC"
run cmd_plugin_add commonly@fixture --yes; t "T3b a community plugin is REFUSED, not warned" "$E_PERMISSION" "$RC"
tc "T3b-msg and it says what is missing rather than blaming the publisher" "prove who wrote a plugin" "$ERR"
run cmd_plugin_add bare@fixture --yes; t "T3c a plugin with no fivedive block reads as unreviewed and is refused" "$E_PERMISSION" "$RC"
t "T3d ...and nothing was installed by either refusal" "null" \
  "$(jq -c '.["commonly@fixture"] // "null"' "$(_plugin_installed_json)" | tr -d '"')"
# The deferral is only real if there is no way around it. If someone later adds
# an --allow-unreviewed flag without building contract §5.1, this arm reds.
run cmd_plugin_add commonly@fixture --allow-unreviewed --yes; t "T3e there is NO --allow-unreviewed escape hatch" "$E_USAGE" "$RC"
tc "T3e-msg and it is rejected as an unknown flag, i.e. the flag does not exist at all" "unknown flag" "$ERR"

# telegram/dashboard/buzz predate the contract; refusing them with the generic
# third-party message would be true and useless.
mkplugin telegram "$(manifest telegram 9.9.9 unreviewed '["channel"]')"; mkindex
run _plugin_mkt_upgrade fixture
run cmd_plugin_add telegram@fixture --yes
t  "T3f a built-in channel plugin is still refused" "$E_USAGE" "$RC"
tc "T3f-msg ...but pointed at the per-AGENT path that actually works" "--channels=telegram" "$ERR"
tn "T3f-msg2 ...and NOT at the generic third-party wall" "prove who wrote a plugin" "$ERR"

# =============================================================================
# §5.2 — consent. Fail-closed where nobody is watching.
# =============================================================================
# A FRESH plugin, deliberately: `good` is already installed by T3a and the §4
# version short-circuit fires BEFORE the consent screen, so re-adding it would
# assert against a screen that was never printed.
mkplugin micy "$(manifest micy 1.0.0 official '["channel"]' '["audio-io"]')"
mkplugin consenty "$(manifest consenty 1.0.0 official '["channel"]' '["agent-credentials"]')"; mkindex
run _plugin_mkt_upgrade fixture
run cmd_plugin_add micy@fixture --yes
t  "T4a-rc the fresh plugin installed, so the screen below really was printed" "0" "$RC"
tc "T4a the consent screen names the grant in ENGLISH, not our enum" "your microphone and speakers" "$OUT$ERR"
tn "T4b ...and does not just echo the enum back" "audio-io" "$OUT$ERR"
# stdin here is the harness's, which is not a terminal — exactly the pipeline /
# exec-tunnel case where a defaulted "yes" would make the screen decorative.
run cmd_plugin_add consenty@fixture; t "T4c no terminal and no --yes is a REFUSAL, not a silent yes" "$E_PERMISSION" "$RC"
t "T4d ...and it installed nothing" "null" "$(jq -c '.["consenty@fixture"] // "null"' "$(_plugin_installed_json)" | tr -d '"')"

# =============================================================================
# §4 — the install path is keyed on version
# =============================================================================
t "T5a the install path embeds the version" "yes" \
  "$([[ -d "$(_plugin_cache_dir)/fixture/good/1.0.0" ]] && echo yes || echo no)"
run cmd_plugin_add good@fixture --yes
tc "T5b re-adding the same version is LOUD about fetching nothing" "cannot arrive" "$ERR"

# The trap the whole clause exists to name: publish a change WITHOUT bumping.
echo "a real change" > "$MKT/good/CHANGED"
run _plugin_mkt_upgrade fixture
run cmd_plugin_upgrade good@fixture
t  "T5c upgrade with an unbumped version reports no change" "0" "$RC"
tc "T5c-msg ...and explains that the fix cannot arrive rather than saying 'up to date'" "keyed on the version" "$ERR"
t  "T5d ...and the installed copy really is still the old one" "no" \
   "$([[ -f "$(_plugin_cache_dir)/fixture/good/1.0.0/CHANGED" ]] && echo yes || echo no)"

jq '.version="1.1.0"' "$MKT/good/.claude-plugin/plugin.json" > "$TMP/x" && mv "$TMP/x" "$MKT/good/.claude-plugin/plugin.json"
run _plugin_mkt_upgrade fixture
run cmd_plugin_upgrade good@fixture
t "T5e a bumped version upgrades" "0" "$RC"
t "T5f ...installing ALONGSIDE: the old version dir is still on disk" "yes" \
  "$([[ -d "$(_plugin_cache_dir)/fixture/good/1.0.0" && -d "$(_plugin_cache_dir)/fixture/good/1.1.0" ]] && echo yes || echo no)"
t "T5g ...and the pointer moved to the new one" "1.1.0" \
  "$(basename "$(readlink "$(_plugin_enabled_dir)/good@fixture")")"
t "T5h ...and the record agrees with the pointer" "1.1.0" \
  "$(jq -r '.["good@fixture"].version' "$(_plugin_installed_json)")"

run cmd_plugin_rollback good@fixture
t "T5i rollback is a POINTER FLIP, which is the only reason keeping the old dir is worth anything" \
  "1.0.0" "$(basename "$(readlink "$(_plugin_enabled_dir)/good@fixture")")"
t "T5j ...and the record follows it back" "1.0.0" "$(jq -r '.["good@fixture"].version' "$(_plugin_installed_json)")"

# =============================================================================
# §3 — uninstall is TOTAL
# =============================================================================
run cmd_plugin_remove good@fixture
t "T6a remove drops EVERY version, not just the enabled one" "no" \
  "$([[ -d "$(_plugin_cache_dir)/fixture/good" ]] && echo yes || echo no)"
t "T6b ...the pointer"        "no"   "$([[ -e "$(_plugin_enabled_dir)/good@fixture" ]] && echo yes || echo no)"
t "T6c ...and the record"     "null" "$(jq -c '.["good@fixture"] // "null"' "$(_plugin_installed_json)" | tr -d '"')"

# =============================================================================
# §3 — enable/disable is a FLAG FLIP, not a re-copy
# =============================================================================
# `plugin list` renders an ENABLED column. A column that can only ever say "yes"
# is a claim the product cannot honour, so either the verb exists or the column
# should not. These arms are what keep those two in step.
run cmd_plugin_add aliased@fixture --yes   # already installed; ensures a subject
run cmd_plugin_disable aliased@fixture
t "T11a disable clears the flag"     "false" "$(jq -r '.["aliased@fixture"].enabled' "$(_plugin_installed_json)")"
t "T11b ...and drops the pointer"    "no"    "$([[ -e "$(_plugin_enabled_dir)/aliased@fixture" ]] && echo yes || echo no)"
t "T11c ...but leaves the CODE on disk, which is what makes re-enabling a flip and not a re-fetch" "yes" \
  "$([[ -d "$(_plugin_cache_dir)/fixture/aliased/1.0.0" ]] && echo yes || echo no)"
run cmd_plugin_disable aliased@fixture
tc "T11d disabling twice is a no-op that says so" "already disabled" "$OUT$ERR"
run cmd_plugin_enable aliased@fixture
t "T11e enable restores the pointer"  "yes"  "$([[ -L "$(_plugin_enabled_dir)/aliased@fixture" ]] && echo yes || echo no)"
t "T11f ...and the flag"              "true" "$(jq -r '.["aliased@fixture"].enabled' "$(_plugin_installed_json)")"

# Re-enabling must not write a DANGLING pointer: `list` would then say enabled for
# a plugin with no code behind it, which is a worse state than disabled.
run cmd_plugin_disable codexed@fixture
rm -rf "$(_plugin_cache_dir)/fixture/codexed/1.0.0"
run cmd_plugin_enable codexed@fixture
t  "T11g enabling a version that is no longer on disk is refused" "$E_NOT_FOUND" "$RC"
t  "T11h ...and no dangling pointer was written" "no" \
   "$([[ -e "$(_plugin_enabled_dir)/codexed@fixture" ]] && echo yes || echo no)"

# A rollback must not silently switch a disabled plugin back on — that is a second
# decision the user did not make.
run cmd_plugin_add good@fixture --yes
jq '.version="1.2.0"' "$MKT/good/.claude-plugin/plugin.json" > "$TMP/x" && mv "$TMP/x" "$MKT/good/.claude-plugin/plugin.json"
run _plugin_mkt_upgrade fixture
run cmd_plugin_upgrade good@fixture
run cmd_plugin_disable good@fixture
run cmd_plugin_rollback good@fixture
t "T11i rollback moves the recorded version even while disabled" "1.1.0" \
  "$(jq -r '.["good@fixture"].version' "$(_plugin_installed_json)")"
t "T11j ...and does NOT re-enable it behind the user's back" "no" \
  "$([[ -e "$(_plugin_enabled_dir)/good@fixture" ]] && echo yes || echo no)"

# =============================================================================
# marketplaces
# =============================================================================
run _plugin_mkt_remove fixture
t "T7a a marketplace still holding an installed plugin cannot be removed out from under it" "$E_CONFLICT" "$RC"
tc "T7a-msg and it names what is still installed" "aliased@fixture" "$ERR"

# Ambiguity must be an error, never a first-match: two marketplaces can both
# offer `good`, and silently picking one is how a user installs the other one.
MKT2="$TMP/fixture-mkt2"; mkdir -p "$MKT2/.claude-plugin"
mkdir -p "$MKT2/good/.claude-plugin"
manifest good 2.0.0 official '["channel"]' > "$MKT2/good/.claude-plugin/plugin.json"
jq -n '{name:"fixture2", owner:{name:"t"}, plugins:[{name:"good", source:"./good"}]}' > "$MKT2/.claude-plugin/marketplace.json"
run _plugin_mkt_add "$MKT2" --as=fixture2
mkplugin good "$(manifest good 1.1.0 official '["channel"]')"; mkindex
run _plugin_mkt_upgrade fixture
run cmd_plugin_add good --yes
t "T7b a bare name that two marketplaces both offer is an ERROR, not a first-match" "$E_CONFLICT" "$RC"
tc "T7b-msg and it shows how to disambiguate" "good@fixture" "$ERR"

run _plugin_mkt_add "$MKT2" --as=fixture2; t "T7c adding a marketplace name that already exists is refused" "$E_CONFLICT" "$RC"
t "T7d a local marketplace is COPIED, so the source cannot mutate under it" "yes" \
  "$([[ -f "$(_plugin_mkt_dir)/fixture2/.claude-plugin/marketplace.json" && ! -L "$(_plugin_mkt_dir)/fixture2" ]] && echo yes || echo no)"

# The registry registering itself is what keeps contract §6 literally true after
# DIVE-4202 moved voice and browser out of this repo: `plugin add voice` still
# resolves with no prior setup, from the ONE marketplace instead of a bundled
# second one.
if [[ -z "$REGISTRY" ]]; then
  printf '  !! NOT RUN — T7e-T7i (the registry registers itself, voice resolves)\n'
  printf '  !! need a 5dive-ai/5dive-plugins checkout. Set FIVEDIVE_PLUGIN_REGISTRY.\n'
else
  t "T7e the 5dive-plugins registry registered itself" "true" \
    "$(jq -r '.["5dive-plugins"].registry // false' "$(_plugin_mkt_json)")"
  t "T7f ...and voice resolves from it" "yes" \
    "$(_plugin_source_dir 5dive-plugins voice >/dev/null 2>&1 && echo yes || echo no)"
  t "T7g ...as an official plugin, so it is the one thing that installs today" "official" \
    "$(jq -r '.fivedive.trust.review' "$(_plugin_source_dir 5dive-plugins voice)/.claude-plugin/plugin.json")"
  # DIVE-4035 added `verb` here. Kept as an EXACT set rather than an `index("channel")`
  # containment check on purpose: voice is the reference implementation, so the arm's
  # job is to notice when the reference shape changes at all, and a containment check
  # would have let `verb` in silently — which is the drift a reference implementation
  # is least able to afford.
  t "T7h ...declaring channel + verb, the shape browser copies" '["channel","verb"]' \
    "$(jq -c '.fivedive.capabilities' "$(_plugin_source_dir 5dive-plugins voice)/.claude-plugin/plugin.json")"
  t "T7i ...and shipping the executable its verb resolves to (DIVE-4035)" "yes" \
    "$([[ -x "$(_plugin_source_dir 5dive-plugins voice)/bin/voice" ]] && echo yes || echo no)"
fi

# =============================================================================
# §7.2 — discovery folds into `market`; it does not become a fourth silo
# =============================================================================
JSON_MODE=1
run cmd_market --kind=plugin
t  "T8a market --kind=plugin answers" "0" "$RC"
if [[ -z "$REGISTRY" ]]; then
  # Without a pinned registry checkout `plugin ls` reads the LIVE published
  # registry over the network, so these two would grade whatever is on the
  # registry's main today rather than the tree under test — green or red for
  # reasons that have nothing to do with this diff.
  printf '  !! NOT RUN — T8b/T8c (voice in the discovery list) need a registry checkout.\n'
else
  tc "T8b ...and the registry's voice is in it, so discovery and the installer agree" '"name":"voice"' "$OUT"
  t  "T8c ...marked installable right now (it needs no marketplace to be added first)" "true" \
     "$(jq -r '.data.plugins[] | select(.name=="voice") | .ready' <<<"$OUT")"
fi
JSON_MODE=0
run cmd_market --kind=banana; t "T8d an unknown --kind is refused rather than silently browsing agents" "$E_USAGE" "$RC"
# Regression control: the persona market is the pre-existing behaviour of this
# verb and --kind must not have broken it.
# NOTE the single quotes in this arm's NAME. Written with backticks it was a
# command substitution inside a double-quoted string: bash ran `market --help`
# as a shell command, printed "market: command not found", and the arm's own
# label ate itself. Same class as the DIVE-3994 unquoted-heredoc defect, found
# the same way — by running it.
run cmd_market --help
t 'T8e plain market --help still works (control: --kind did not break the persona front door)' "0" "$RC"

# =============================================================================
# fivedive.setup — PRINTED, never executed (proposed §6 addendum)
# =============================================================================
# T9c is the arm that matters and it is a negative control: the command in the
# manifest writes a sentinel file, so if `plugin add` ever executes it instead of
# printing it, the file exists and this arm reds. Without that arm the feature is
# indistinguishable from a post-install hook, which is arbitrary code execution
# chosen by the publisher — the door contract §5 keeps shut.
SENTINEL="$TMP/EXECUTED"
mkplugin setupy "$(manifest setupy 1.0.0 official '["channel"]' '[]' \
  "$(jq -cn --arg s "$SENTINEL" '{setup:{hint:"needs a host engine", command:("touch " + $s)}}')")"
mkindex
run _plugin_mkt_upgrade fixture
run cmd_plugin_add setupy@fixture --yes
t  "T9a a plugin declaring a setup step installs"            "0" "$RC"
tc "T9b ...and its hint is shown to the user"                "needs a host engine" "$OUT$ERR"
tc "T9b2 ...along with the command, marked as not-run-on-its-own" "5dive does not run this on its own" "$OUT$ERR"
tc "T9b3 ...and the no-terminal route to the same step is named"  "5dive plugin setup setupy@fixture" "$OUT$ERR"
t  "T9c ...and the command was PRINTED, NOT EXECUTED (the whole design in one arm)" "no" \
   "$([[ -e "$SENTINEL" ]] && echo yes || echo no)"
# DIVE-4467: the DECLARATION is recorded at install, with no run on it. This is
# what lets a page that has never seen the manifest know a box step is owed —
# without it the dashboard cannot tell "no setup needed" from "setup not done".
t "T9c2 ...but the declaration is recorded, so a page can know a step is owed" "touch $SENTINEL" \
  "$(jq -r '."setupy@fixture".setup.command' "$STATE_DIR/plugins/installed.json")"
t "T9c3 ...carrying no run receipt yet"                                        "null" \
  "$(jq -r '."setupy@fixture".setup.ran_at // "null"' "$STATE_DIR/plugins/installed.json")"
t "T9c4 ...and a plugin with no setup block records none (absence is a signal)" "null" \
  "$(jq -r '."good@fixture".setup // "null"' "$STATE_DIR/plugins/installed.json")"

# The bundled voice plugin is the live instance of that, so grade the real file
# rather than only the fixture: if someone later drops the setup block from
# voice, or points it at something other than the host installer, this reds.
if [[ -z "$REGISTRY" ]]; then
  printf '  !! NOT RUN — T9d/T9e (the real voice manifest) need a registry checkout.\n'
else
  VOICE="$(_plugin_source_dir 5dive-plugins voice)/.claude-plugin/plugin.json"
  t "T9d voice names the real host installer, not a placeholder" "sudo 5dive-setup-voice" \
    "$(jq -r '.fivedive.setup.command' "$VOICE")"
  t "T9e voice asks for audio, which is what makes its consent screen honest" "true" \
    "$(jq -r '[.fivedive.grants[]] | index("audio-io") != null' "$VOICE")"
fi

# =============================================================================
# T9f-T9n — `plugin setup`: the SAME command, run because the user asked
# (DIVE-4467)
# =============================================================================
# The pair T9c/T9g is the whole design, and neither arm means anything alone.
# T9c is the negative control (install must NOT execute the manifest's command);
# T9g is its positive control (the verb MUST execute exactly that command, or
# the dashboard button is decoration). The sentinel from T9c is reused on
# purpose: the file that must not exist after `add` is the file that must exist
# after `setup`, so the two arms cannot both pass on a broken read of the
# manifest.

# THE CALLER'S UID IS A FIXTURE FROM HERE DOWN. Every arm below runs the
# publisher's command, and since DIVE-4475 the verb picks its path from
# `$(id -u)`: at root it drops to the calling seat, anywhere else it runs as
# itself. A suite whose verdict depends on the uid of whoever invoked it is not
# a grader — run under `sudo` this section dropped `touch $SENTINEL` into a seat
# that cannot reach the harness's own 0700 temp tree, reddening four arms that
# have nothing to do with uid. The call site reads `$(id -u)` in THIS shell, so
# a function reaches it and nothing is ever actually elevated: unprivileged by
# default here, and set to 0 explicitly by the arms that exist to grade the root
# branch (T9r-T9u).
HARNESS_UID=1000
id() { if [[ "${1:-}" == "-u" ]]; then echo "$HARNESS_UID"; else command id "$@"; fi; }

# Consent first. Without --yes and with stdin not a terminal the verb must
# REFUSE, and — the half that matters — must not have run anything.
run cmd_plugin_setup setupy@fixture
t  "T9f no --yes and no terminal is refused, not assumed"      "10" "$RC"
t  "T9f2 ...and nothing ran (the sentinel is still absent)"    "no" \
   "$([[ -e "$SENTINEL" ]] && echo yes || echo no)"
tc "T9f3 ...and the refusal names the flag that would consent" "--yes" "$OUT$ERR"

# The consent text is the publisher's, shown again at the moment of running —
# a dashboard click changes the input device, not the disclosure.
run cmd_plugin_setup setupy@fixture --yes
t  "T9g the verb RUNS the manifest's command (positive control for T9c)" "yes" \
   "$([[ -e "$SENTINEL" ]] && echo yes || echo no)"
t  "T9g2 ...and reports success"                                "0" "$RC"
tc "T9g3 ...after showing the publisher's hint again"           "needs a host engine" "$OUT$ERR"
tc "T9g4 ...and the exact command it is about to run"           "touch $SENTINEL" "$OUT$ERR"

# The run is RECORDED, which is what lets the dashboard stop offering a button
# for work already done.
INST="$STATE_DIR/plugins/installed.json"
t "T9h the run is recorded on the installed entry"       "true" \
  "$(jq -r '."setupy@fixture".setup.ok' "$INST")"
t "T9h2 ...with the command that actually ran"           "touch $SENTINEL" \
  "$(jq -r '."setupy@fixture".setup.command' "$INST")"
t "T9h1b ...merged onto the declaration, not replacing it" "needs a host engine" \
  "$(jq -r '."setupy@fixture".setup.hint' "$INST")"
t "T9h3 ...and its exit code"                            "0" \
  "$(jq -r '."setupy@fixture".setup.rc' "$INST")"

# A plugin with no setup block has nothing to run, and saying so is not the same
# as running nothing quietly.
mkplugin nosetup "$(manifest nosetup 1.0.0 official '["channel"]')"
mkindex
run _plugin_mkt_upgrade fixture
run cmd_plugin_add nosetup@fixture --yes
t  "T9i0 (precondition) the no-setup fixture installed"   "0" "$RC"
run cmd_plugin_setup nosetup@fixture --yes
t  "T9i a plugin with no setup block is refused"          "4" "$RC"
tc "T9i2 ...naming what is missing"                       "fivedive.setup.command" "$OUT$ERR"

run cmd_plugin_setup nosuchplugin --yes
t  "T9j an uninstalled plugin is refused"                 "4" "$RC"

# THE ALLOWLIST ARM. The verb takes a plugin REFERENCE and nothing else; there is
# no shape in which a caller hands it a command. A second word is a usage error,
# not a second command — this is what lets the API route forward a validated key
# and never a string.
run cmd_plugin_setup setupy@fixture "touch $TMP/SMUGGLED" --yes
t  "T9k a second argument is refused, never treated as a command" "2" "$RC"
t  "T9k2 ...and nothing was smuggled through it"          "no" \
   "$([[ -e "$TMP/SMUGGLED" ]] && echo yes || echo no)"
run cmd_plugin_setup --command="touch $TMP/SMUGGLED2" --yes
t  "T9k3 an invented flag is refused rather than parsed" "2" "$RC"
t  "T9k4 ...and nothing was smuggled through it"          "no" \
   "$([[ -e "$TMP/SMUGGLED2" ]] && echo yes || echo no)"

# A failing setup is a recorded failure, not a silent one: the entry keeps rc so
# the page can show it, and the verb exits non-zero so a script can see it.
mkplugin setupbad "$(manifest setupbad 1.0.0 official '["channel"]' '[]' \
  "$(jq -cn '{setup:{hint:"will not work", command:"exit 7"}}')")"
mkindex
run _plugin_mkt_upgrade fixture
run cmd_plugin_add setupbad@fixture --yes
run cmd_plugin_setup setupbad@fixture --yes
t  "T9m a failing setup command fails the verb"           "1" "$RC"
tc "T9m2 ...naming the exit code it saw"                  "exited 7" "$OUT$ERR"
t  "T9m3 ...and the failure is recorded, not swallowed"   "7" \
  "$(jq -r '."setupbad@fixture".setup.rc' "$INST")"
t  "T9m4 ...as not-ok, so the page re-offers the button"  "false" \
  "$(jq -r '."setupbad@fixture".setup.ok' "$INST")"

# =============================================================================
# T9p-T9u — WHOSE box-half is it? (DIVE-4475)
# =============================================================================
# The defect these arms exist for: `plugin setup` ran the publisher's command as
# root, and every shipped setup command begins with `sudo`. An inner `sudo` from
# a root caller sets SUDO_USER=root, so `5dive browser setup` — which refuses to
# make root a browser seat, correctly — was UNRUNNABLE through this verb on
# every box. The existing T9f-T9n fixtures could not see it: their command is
# `touch $SENTINEL`, which has no opinion about who runs it.
#
# So: one fixture command that READS the seat, plus the decision seam graded
# directly. The seam is graded directly because the interesting case is euid 0
# and this harness is not root — a pure (caller, euid) -> argv function is
# observable at any uid, a `sudo` buried in the verb is not.

t "T9p as root, a real seat is restored by dropping to it" "runuser -u alice --" \
  "$(_plugin_setup_runner alice 0 | tr '\n' ' ' | sed 's/ $//')"
t "T9p1 ...via runuser, which asks no sudoers policy; sudo -u only where util-linux is absent" \
  "sudo -u alice --" \
  "$(PATH=/nonexistent-for-this-arm _plugin_setup_runner alice 0 | tr '\n' ' ' | sed 's/ $//')"
t "T9p2 ...and a root CALLER gets no wrapper (there is no seat to restore)" "" \
  "$(_plugin_setup_runner root 0)"
t "T9p3 ...and an unprivileged caller is already the right seat, so no sudo" "" \
  "$(_plugin_setup_runner alice 1000)"
t "T9p4 ...and an empty caller is never turned into 'sudo -u ' " "" \
  "$(_plugin_setup_runner "" 0)"

# THE FIXTURE WITH AN OPINION. Its command reads SUDO_USER — the one thing the
# browser plugin uses to pick the profile owner — and writes what it saw. An arm
# that asserts on this cannot pass while the verb launders the seat.
SEATSEEN="$TMP/seat-seen"
mkplugin setupseat "$(manifest setupseat 1.0.0 official '["channel"]' '[]' \
  "$(jq -cn --arg f "$SEATSEEN" '{setup:{hint:"needs to know whose box-half this is",
                                          command:("printf %s \"$SUDO_USER\" > " + $f)}}')")"
mkindex
run _plugin_mkt_upgrade fixture
run cmd_plugin_add setupseat@fixture --yes
t "T9q0 (precondition) the seat-reading fixture installed" "0" "$RC"

SUDO_USER=alice run cmd_plugin_setup setupseat@fixture --yes
t  "T9q the publisher's command SEES the calling seat, not root"  "alice" \
   "$(cat "$SEATSEEN" 2>/dev/null)"
t  "T9q2 ...and the same seat is what got recorded on the entry"  "alice" \
   "$(jq -r '."setupseat@fixture".setup.by' "$INST")"
tc "T9q3 ...and the consent screen names that seat, not 'as root'" "it runs, as alice:" "$OUT$ERR"
tn "T9q4 ...so the old unconditional 'as root' claim is gone"      "it runs, as root:" "$OUT$ERR"

# --- T9r-T9u: the WIRING, executed end to end --------------------------------
# T9p grades the DECISION and T9q grades the seat the publisher's command sees,
# and neither one EXECUTES the line the fix changed: the wrapper is emitted only
# at euid 0, this harness is not root, so `${runner[@]+"${runner[@]}"}` at the
# call site was graded by nothing — delete it outright and the suite stayed
# green (quinn, DIVE-4475 iteration 1). A decision nothing consumes is the row's
# own defect class.
#
# Executing it needs no root, only two shims:
#   · `HARNESS_UID=0`, read through the `id` function installed above — the call
#     site reads `$(id -u)` in THIS shell, so nothing is actually elevated.
#   · a recording `runuser` first on PATH, which appends its argv to a log and
#     execs the rest. So we observe the exact wrapper the verb chose AND the
#     publisher's command still runs — a shim that only recorded would prove the
#     command was replaced, not run.
SHIM="$TMP/shim"; mkdir -p "$SHIM"
RUNLOG="$TMP/runner.log"; export RUNLOG
cat > "$SHIM/runuser" <<'SHIMEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RUNLOG"
[[ "${1:-}" == "-u" ]] && shift 2
[[ "${1:-}" == "--" ]] && shift
exec "$@"
SHIMEOF
chmod +x "$SHIM/runuser"

shimmed_setup() {  # shimmed_setup <caller-seat> <verb args...>
  local seat="$1"; shift
  local saved="$PATH"
  : > "$RUNLOG"
  PATH="$SHIM:$PATH"; export SUDO_USER="$seat"; HARNESS_UID=0
  run cmd_plugin_setup "$@"
  PATH="$saved"; unset SUDO_USER; HARNESS_UID=1000
}

SEATWIRED="$TMP/seat-wired"
mkplugin setupwired "$(manifest setupwired 1.0.0 official '["channel"]' '[]' \
  "$(jq -cn --arg f "$SEATWIRED" '{setup:{hint:"box half, owned by a seat",
                                          command:("printf %s \"$SUDO_USER\" > " + $f)}}')")"
mkindex
run _plugin_mkt_upgrade fixture
run cmd_plugin_add setupwired@fixture --yes
t "T9r0 (precondition) the wiring fixture installed" "0" "$RC"

WIREDCMD=$(jq -r '.fivedive.setup.command' "$MKT/setupwired/.claude-plugin/plugin.json")
rm -f "$SEATWIRED"
shimmed_setup alice setupwired@fixture --yes
t "T9r at euid 0 the verb WRAPS the publisher's command, with the real seat" \
  "-u alice -- bash -c $WIREDCMD" "$(cat "$RUNLOG")"
t "T9r2 ...and the publisher's command still RAN (the wrapper execs, not swallows)" \
  "alice" "$(cat "$SEATWIRED" 2>/dev/null)"
t "T9r3 ...and the verb succeeded"  "0" "$RC"
t "T9r4 ...and the run is recorded against that seat" "alice" \
  "$(jq -r '."setupwired@fixture".setup.by' "$INST")"

# Non-vacuity, half one: the log is written by the WRAPPER, not by the arm. A
# root caller has no seat to restore, so at the same euid 0 nothing is wrapped.
rm -f "$SEATWIRED"
shimmed_setup root setupwired@fixture --yes
t "T9s a root CALLER is not wrapped even at euid 0 — the log stays empty" "" \
  "$(cat "$RUNLOG")"
t "T9s2 ...and the publisher's command ran anyway, unwrapped"  "root" \
  "$(cat "$SEATWIRED" 2>/dev/null)"

# Non-vacuity, half two: MUTATE THE CALL SITE. Strip the wrapper from the one
# line the fix changed — mutant 1 of the rejection — and the log must be EMPTY
# while everything else about the verb is unchanged. This is what makes T9r an
# arm on the wiring rather than an arm on the pure function a second time.
MUTSRC="$TMP/cmd_plugin.callsite-mutant.sh"
sed 's/${runner\[@\]+"${runner\[@\]}"} bash -c/bash -c/' src/cmd_plugin.sh > "$MUTSRC"
if cmp -s src/cmd_plugin.sh "$MUTSRC"; then MUTATED=no; else MUTATED=yes; fi
t "T9t0 (precondition) the call-site mutant really differs from the source" "yes" "$MUTATED"
rm -f "$SEATWIRED"; : > "$RUNLOG"
(
  PATH="$SHIM:$PATH"
  # shellcheck source=/dev/null
  source "$MUTSRC"
  HARNESS_UID=0
  SUDO_USER=alice cmd_plugin_setup setupwired@fixture --yes
) >/dev/null 2>&1
t "T9t with the wrapper deleted from the call site, NOTHING is wrapped" "" \
  "$(cat "$RUNLOG")"
t "T9t2 ...and that mutant is otherwise alive — it ran the command, just bare" \
  "alice" "$(cat "$SEATWIRED" 2>/dev/null)"

# ops's note 3 on the gate: before this change the publisher's inner `sudo` was
# a no-op under root; now it authenticates as the SEAT, so a box where that seat
# has no NOPASSWD turns "root ran it" into "the seat could not". That must be a
# recorded, reported failure — never a silent success.
mkplugin setupdenied "$(manifest setupdenied 1.0.0 official '["channel"]' '[]' \
  '{"setup":{"hint":"needs rights the seat has not got","command":"exit 77"}}')"
mkindex
run _plugin_mkt_upgrade fixture
run cmd_plugin_add setupdenied@fixture --yes
shimmed_setup alice setupdenied@fixture --yes
t  "T9u a command that fails UNDER THE DROP fails the verb" "1" "$RC"
tc "T9u2 ...and the exit code reaches the operator"  "setup exited 77" "$OUT$ERR"
t  "T9u3 ...and it is recorded as not-ok, so the button is re-offered"  "false" \
   "$(jq -r '."setupdenied@fixture".setup.ok' "$INST")"
t  "T9u4 ...and the drop itself still happened (it is the command that failed)" \
   "-u alice -- bash -c exit 77" "$(cat "$RUNLOG")"

unset -f shimmed_setup

# `plugin setup` is reachable through the real dispatcher, not only as a function
# this harness calls directly.
run cmd_plugin setup
t  "T9n 'plugin setup' is a dispatched subverb, not an unknown one" "2" "$RC"
tc "T9n2 ...and its usage is the plugin-reference shape" "5dive plugin setup <plugin>" "$OUT$ERR"

# =============================================================================
# T10 — RETIRED by DIVE-4202: install.sh stages no plugins
# =============================================================================
# T10a-d graded install.sh's per-file bundled-plugin staging list against what
# plugins/ contained, plus the partial-download guard around it. This repo ships
# no plugins/ any more — they are published to 5dive-ai/5dive-plugins and the
# installer stages nothing — so there is no list to drift and no guard to run.
#
# The question those arms were standing in for ("does the plugin we ship
# actually install on a fresh box") is not dropped: it moved UP to execution, in
# scripts/install-contract.sh, which enumerates the REGISTRY's manifest and runs
# `plugin add` on a freshly installed container. A file-list comparison was
# always the weaker instrument (DIVE-4126 shipped green past it); it is gone
# because its subject is gone, not because it was inconvenient.
#
# DIVE-4196 RETIRED T13, WHICH WAS THE SAME ARM ONE ARTIFACT OVER. T13a-d
# compared install.sh's `for _tpl in` staging list against team-templates/
# index.json and the directory itself. Team templates moved to the same kind of
# registry the plugins went to (<org>/5dive-marketplace, teams/): install.sh
# stages no templates, team-templates/ is gone from this repo, and the two
# declarations T13 held equal no longer both exist. Left in place it would grade
# a `for _tpl in` list that is absent — T13c, the non-empty control, is exactly
# what turns that into a red rather than a vacuous pass, so this is a deletion
# the harness's own control demanded.
#
# Its question — "does every slug the registry advertises resolve on a fresh
# box", which is #807/#808 — moved UP to execution with T10's, in
# scripts/install-contract.sh: T3a runs `team ps <slug>` on a freshly installed
# container for every slug in the LIVE registry index, and T3b checks the
# roster size against it. That is a stronger instrument than a set comparison,
# and it now grades a PUBLISH rather than a checkout.

# =============================================================================
# T12 — arms that can SEE a death under errexit
# =============================================================================
# quinn's iteration-2 reject, and it is the structural finding, not the three
# symptoms: this harness does `set +e` at line ~48 so that `fail` does not kill
# it while grading refusals — which is correct, and which ALSO switches off the
# only rail that makes an unguarded command substitution fatal. So 86 green arms
# could not have seen `plugin rollback` dying on its own probe. Grading refusals
# and grading deaths need two different shells, and this block is the second one.
#
# `( set -euo pipefail; … )` as a PLAIN command, never as an operand of ||/&&/if:
# the errexit exemption for an operand propagates INTO the subshell and would
# make the death unreachable — the trap in
# [[the-set-e-exemption-propagates-into-a-subshell-so-a-does-it-die-arm-is-vacuous]].
# T12a below is the positive control that this shell really can kill.
run_e() {
  local o="$TMP/.eo" e="$TMP/.ee"
  ( set -euo pipefail; "$@" ) >"$o" 2>"$e"; RC=$?
  OUT=$(cat "$o"); ERR=$(cat "$e")
  return 0
}
_probe_dies() { local x; x=$(printf 'a\n' | grep -F zzz); echo "SURVIVED"; }
run_e _probe_dies
t "T12a positive control: this shell CAN kill an unguarded probe (if it cannot, every arm below is vacuous)" \
  "yes" "$([[ "$RC" != 0 && -z "$OUT" && -z "$ERR" ]] && echo yes || echo no)"

# The real one. `rollback` with exactly ONE version on disk is not an edge case —
# it is every install that has never been upgraded, i.e. the first thing a user
# reaches for after their first upgrade goes wrong.
run cmd_plugin_add micy@fixture --yes   # single version, never upgraded
run_e cmd_plugin_rollback micy@fixture
t  "T12b rollback with one version REFUSES (it does not die on its own probe)" "$E_NOT_FOUND" "$RC"
t  "T12c ...and it said something — a silent non-zero is the defect, not the exit code" "yes" \
   "$([[ -n "$ERR" ]] && echo yes || echo no)"
tc "T12d ...naming the state the user is actually in" "no other version" "$ERR"

# A function whose last command is a conditional supplies its exit status; under
# errexit that takes the CALLER down with no message. Run against a FRESH store,
# because on a second call `_plugin_register_bundled` returns early and the line
# in question never executes — an arm that re-uses the bootstrapped store grades
# the early return, not the bug.
#
# HONEST SCOPE, because it matters for who owns this class: this arm proves the
# bootstrap SUCCEEDS end to end on a fresh tree. It does NOT prove the shape is
# absent — the defect is that a false conditional would SUPPLY the status, and
# on the happy path the conditional is true either way. The guard that actually
# catches the shape is the corpus-level static one,
# tests/task_show_exit_code_unit.sh, which named `cmd_plugin.sh:338` before I
# did. Duplicating its scanner here would be a second copy to drift; what this
# file adds is the runtime half it cannot see.
( STATE_DIR="$TMP/bootstrap-fresh"; run_e _plugin_ensure_store; printf '%s' "$RC" > "$TMP/.bootrc" )
t "T12e the bootstrap returns success on a FRESH store, so its callers survive errexit" \
  "0" "$(cat "$TMP/.bootrc" 2>/dev/null)"
if [[ -z "$REGISTRY" ]]; then
  printf '  !! NOT RUN — T12e2 (the bootstrap really registered the registry) needs a registry checkout.\n'
else
  t "T12e2 ...and it really did register the registry (the arm is not grading an early return)" "true" \
    "$(jq -r '.["5dive-plugins"].registry // false' "$TMP/bootstrap-fresh/plugins/marketplaces.json" 2>/dev/null)"
fi

# quinn measured this on a FRESH box: the built-in hint never fired, because it
# sat behind the trust gate, which sits behind manifest resolution, which needs
# the marketplace the user has not added. The whole value of the hint is for
# someone who has set nothing up, so grade it with nothing set up.
FRESH="$TMP/fresh"; ( STATE_DIR="$FRESH" run cmd_plugin_add telegram --yes ) >/dev/null 2>&1
( STATE_DIR="$FRESH"; run cmd_plugin_add telegram --yes; printf '%s' "$ERR" > "$TMP/.fresh_err" )
fresh_err=$(cat "$TMP/.fresh_err" 2>/dev/null)
tc "T12f on a store with NO marketplace added, 'plugin add telegram' still points at the per-agent path" \
   "--channels=telegram" "$fresh_err"
tn "T12g ...instead of the setup error the user cannot act on" "in any registered marketplace" "$fresh_err"

printf 'plugin_contract_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
