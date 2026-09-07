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

export FIVEDIVE_BUNDLED_PLUGINS="$ROOT/plugins"
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

# The bundled marketplace is what makes contract §6 literally true on a box with
# no network and no prior setup.
t "T7e the CLI's own bundled marketplace registered itself" "true" \
  "$(jq -r '.["5dive"].bundled // false' "$(_plugin_mkt_json)")"
t "T7f ...and voice resolves from it" "yes" \
  "$(_plugin_source_dir 5dive voice >/dev/null 2>&1 && echo yes || echo no)"
t "T7g ...as an official plugin, so it is the one thing that installs today" "official" \
  "$(jq -r '.fivedive.trust.review' "$(_plugin_source_dir 5dive voice)/.claude-plugin/plugin.json")"
t "T7h ...declaring channel, the shape browser will copy" '["channel"]' \
  "$(jq -c '.fivedive.capabilities' "$(_plugin_source_dir 5dive voice)/.claude-plugin/plugin.json")"

# =============================================================================
# §7.2 — discovery folds into `market`; it does not become a fourth silo
# =============================================================================
JSON_MODE=1
run cmd_market --kind=plugin
t  "T8a market --kind=plugin answers" "0" "$RC"
tc "T8b ...and the bundled voice is in it, so discovery and the installer agree" '"name":"voice"' "$OUT"
t  "T8c ...marked installable right now (it needs no marketplace to be added first)" "true" \
   "$(jq -r '.data.plugins[] | select(.name=="voice") | .ready' <<<"$OUT")"
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
tc "T9b2 ...along with the command, marked as theirs to run" "5dive does not run this for you" "$OUT$ERR"
t  "T9c ...and the command was PRINTED, NOT EXECUTED (the whole design in one arm)" "no" \
   "$([[ -e "$SENTINEL" ]] && echo yes || echo no)"

# The bundled voice plugin is the live instance of that, so grade the real file
# rather than only the fixture: if someone later drops the setup block from
# voice, or points it at something other than the host installer, this reds.
VOICE="$(_plugin_source_dir 5dive voice)/.claude-plugin/plugin.json"
t "T9d voice names the real host installer, not a placeholder" "sudo 5dive-setup-voice" \
  "$(jq -r '.fivedive.setup.command' "$VOICE")"
t "T9e voice asks for audio, which is what makes its consent screen honest" "true" \
  "$(jq -r '[.fivedive.grants[]] | index("audio-io") != null' "$VOICE")"

printf 'plugin_contract_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
