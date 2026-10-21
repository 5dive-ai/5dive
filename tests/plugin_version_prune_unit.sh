#!/usr/bin/env bash
# DIVE-6650 — `plugin upgrade` keeps the newest PLUGIN_KEEP_VERSIONS version dirs
# of a plugin and deletes the rest, never the pointer's target, the recorded
# version, or a version a seat's installed_plugins.json pins.
#
# Before the fix the store kept every version forever: 22 browser dirs, 373 MB,
# on a box at 88% disk (exact-swallow, 2026-10-21). Every arm calls the real
# cmd_plugin_upgrade / cmd_plugin_rollback against a throwaway STATE_DIR, the same
# seam tests/plugin_contract_unit.sh uses.
#
# NEGATIVE CONTROL: PRUNE_SRC=<path to a pre-fix cmd_plugin.sh> runs the same
# arms against that file; P1 (the oldest three are gone) must go red there.
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
source "${PRUNE_SRC:-src/cmd_plugin.sh}"
# header.sh turns errexit on; the run() subshells below must not take the
# harness down with them (see plugin_contract_unit.sh for the long version).
set +e -o pipefail

require_root() { :; }

TMP="$(mktemp -d)"
export STATE_DIR="$TMP/state"
export PERSONA_HOME_ROOT="$TMP/home"
mkdir -p "$PERSONA_HOME_ROOT"

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

# shellcheck source=/dev/null
. "$ROOT/tests/lib/github_fixture.sh"
gh_fixture_seam "$TMP/github"
MKT="$TMP/github/5dive-ai/fixture-mkt.git"

manifest() {  # manifest <name> <version>
  jq -cn --arg n "$1" --arg v "$2" \
     '{name:$n, version:$v, description:"fixture", author:{name:"t"},
       fivedive:{contract:"1", capabilities:[], grants:[],
                 trust:{publisher:"t", did:"did:key:t", review:"official"}}}'
}
publish() {  # publish <plugin> <version> — bump the marketplace copy and fetch it
  mkdir -p "$MKT/$1/.claude-plugin" "$MKT/.claude-plugin"
  manifest "$1" "$2" > "$MKT/$1/.claude-plugin/plugin.json"
  local arr="[]" d n
  for d in "$MKT"/*/; do
    n=$(basename "${d%/}"); [[ "$n" == .* ]] && continue
    arr=$(jq -c --arg n "$n" '. + [{name:$n, description:"f", category:"test", source:("./" + $n)}]' <<<"$arr")
  done
  jq -n --argjson p "$arr" '{name:"fixture", description:"f", owner:{name:"t"}, plugins:$p}' \
    > "$MKT/.claude-plugin/marketplace.json"
  gh_fixture_publish "$MKT"
  [[ -f "$(_plugin_mkt_json)" ]] && run _plugin_mkt_upgrade fixture
  return 0
}
# seed <plugin> <version...> — version dirs that an older box accumulated, laid
# down beside the installed one exactly as `upgrade` used to leave them.
seed() {
  local p="$1" v base; shift; base="$(_plugin_cache_dir)/fixture/$p"
  for v in "$@"; do
    [[ -d "$base/$v" ]] && continue
    cp -a "$base/$(ls "$base" | sort -V | tail -1)" "$base/$v"
  done
}
on_disk() { ls "$(_plugin_cache_dir)/fixture/$1" 2>/dev/null | sort -V | tr '\n' ' ' | sed 's/ $//'; }
pin() {  # pin <seat> <plugin> <version> — a seat's claude pins that version
  local f="$PERSONA_HOME_ROOT/agent-$1/.claude/plugins/installed_plugins.json"
  mkdir -p "$(dirname "$f")"
  jq -n --arg k "$2@fixture" --arg v "$3" '{version:2, plugins:{($k):[{scope:"user", version:$v}]}}' > "$f"
}

publish keep 1.0.0; publish pinned 1.0.0
run _plugin_mkt_add 5dive-ai/fixture-mkt --as=fixture
run cmd_plugin_add keep@fixture --yes;   t "P0 fixture: keep installs" "0" "$RC"
run cmd_plugin_add pinned@fixture --yes; t "P0b fixture: pinned installs" "0" "$RC"

# at <plugin> <version> — the box records and points at <version>, as if the
# upgrades that laid down the seeded dirs had run on the pre-fix tree.
at() {
  ln -sfn "$(_plugin_cache_dir)/fixture/$1/$2" "$(_plugin_enabled_dir)/$1@fixture"
  jq --arg k "$1@fixture" --arg v "$2" '.[$k].version = $v' \
    "$(_plugin_installed_json)" > "$TMP/x" && mv "$TMP/x" "$(_plugin_installed_json)"
}

# ---- P1-P3: a store seeded with 6 versions; one upgrade keeps the newest 3 ----
# 1.5.0 is seeded too: `upgrade` copies only when the target dir is missing, so
# the store holds exactly six dirs across the upgrade under test.
seed keep 1.1.0 1.2.0 1.3.0 1.4.0 1.5.0; at keep 1.4.0
t "P1pre fixture: six versions on disk before the upgrade" \
  "1.0.0 1.1.0 1.2.0 1.3.0 1.4.0 1.5.0" "$(on_disk keep)"
publish keep 1.5.0; run cmd_plugin_upgrade keep@fixture
t  "P1 after one upgrade the newest 3 remain and the oldest 3 are gone" \
   "1.3.0 1.4.0 1.5.0" "$(on_disk keep)"
t  "P2 ...the pointer is the new version" "1.5.0" "$(basename "$(readlink "$(_plugin_enabled_dir)/keep@fixture")")"
tc "P3 ...and the upgrade says what it removed" "removed 3 old version(s) of keep@fixture: 1.0.0 1.1.0 1.2.0" "$ERR"

# P1s: a version a seat pins survives though it is older than the newest 3.
seed pinned 1.1.0 1.2.0 1.3.0 1.4.0 1.5.0; at pinned 1.4.0
pin other pinned 1.1.0
publish pinned 1.5.0; run cmd_plugin_upgrade pinned@fixture
t "P1s a seat-pinned 1.1.0 survives the same upgrade" "1.1.0 1.3.0 1.4.0 1.5.0" "$(on_disk pinned)"
rm -f "$PERSONA_HOME_ROOT/agent-other/.claude/plugins/installed_plugins.json"

# ---- P4: rollback with no version still lands on the previous version ---------
run cmd_plugin_rollback keep@fixture
t "P4 rollback after a prune lands on the previous version" "1.4.0" \
  "$(basename "$(readlink "$(_plugin_enabled_dir)/keep@fixture")")"
t "P4b ...a pointer flip, the dir was kept" "1.4.0" "$(jq -r '.["keep@fixture"].version' "$(_plugin_installed_json)")"
run cmd_plugin_upgrade keep@fixture   # back to 1.5.0 for the arms below

# ---- P5: a box that already holds a pile reclaims with NO new release ----------
seed keep 1.0.0 1.1.0 1.2.0
run cmd_plugin_upgrade keep@fixture   # marketplace still offers 1.5.0
t "P5 the same-version nightly upgrade also prunes, so existing boxes reclaim with no migration" \
  "1.3.0 1.4.0 1.5.0" "$(on_disk keep)"

# ---- P6-P8: what is never deleted, graded on the helper directly ---------------
if declare -F _plugin_prune_versions >/dev/null; then
  base="$(_plugin_cache_dir)/fixture/keep"
  seed keep 1.0.0 1.1.0
  # P6: the pointer's target, even when it is older than the newest 3.
  ln -sfn "$base/1.0.0" "$(_plugin_enabled_dir)/keep@fixture"
  run _plugin_prune_versions keep@fixture keep fixture
  t "P6 the enabled pointer's target survives though it is not among the newest 3" \
    "1.0.0 1.3.0 1.4.0 1.5.0" "$(on_disk keep)"
  # P7: a DISABLED plugin (no pointer) keeps its recorded version.
  seed keep 1.1.0
  rm -f "$(_plugin_enabled_dir)/keep@fixture"
  jq '.["keep@fixture"].version = "1.1.0" | .["keep@fixture"].enabled = false' \
    "$(_plugin_installed_json)" > "$TMP/x" && mv "$TMP/x" "$(_plugin_installed_json)"
  run _plugin_prune_versions keep@fixture keep fixture
  t "P7 a disabled plugin keeps the version installed.json records" \
    "1.1.0 1.3.0 1.4.0 1.5.0" "$(on_disk keep)"
  # P8: a seat pin file that cannot be read means nothing is deleted.
  seed keep 1.0.0
  mkdir -p "$PERSONA_HOME_ROOT/agent-broken/.claude/plugins"
  printf 'not json' > "$PERSONA_HOME_ROOT/agent-broken/.claude/plugins/installed_plugins.json"
  run _plugin_prune_versions keep@fixture keep fixture
  t  "P8 an unreadable seat pin file deletes nothing" "1.0.0 1.1.0 1.3.0 1.4.0 1.5.0" "$(on_disk keep)"
  tc "P8b ...and says why" "could not be read" "$ERR"
else
  FAIL=$((FAIL+1)); printf 'FAIL: P6-P8 _plugin_prune_versions does not exist in %s\n' "${PRUNE_SRC:-src/cmd_plugin.sh}"
fi

printf 'plugin_version_prune_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
