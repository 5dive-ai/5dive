#!/usr/bin/env bash
# DIVE-6935 — the devteam plugin's code is read into 5dive itself
# (src/lib/devteam.sh), so WHO may do that is the whole row.
#
# Part A grades the install gate: the `core` capability installs only as
# devteam@5dive-plugins from a 5dive-owned source. Part B builds a real bundle
# and runs it against a throwaway STATE_DIR: the plugin's copy of a lazy module
# is in use while it is byte-identical to the core's, and every pin (key,
# review, capability, enabled, ownership and write bits, the identity check,
# FIVEDIVE_DEVTEAM=0) stops it. An identical copy is not read a second time:
# B12 runs the five modules that declare `readonly` (DIVE-6959). Part C runs
# five mutants of the built bundle and requires each to turn an arm red.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT="$PWD"
umask 022

TMP="$(mktemp -d)"
chmod 755 "$TMP"

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

# =============================================================================
# Part B first (it needs no sourced src/): a built bundle, a fake plugin tree
# =============================================================================
BUNDLE="$TMP/5dive"
BUILD_OUT="$BUNDLE" ./build.sh >/dev/null 2>"$TMP/build.err" \
  || { echo "FAIL: build: $(cat "$TMP/build.err")"; exit 1; }

export STATE_DIR="$TMP/state"
PL="$STATE_DIR/plugins"
VDIR="$PL/cache/5dive-plugins/devteam/0.1.0"
mkdir -p "$VDIR/core" "$PL/enabled"
# Phase 1: the loader reads the plugin's copy only while it is byte-for-byte the
# core's own file. CURRENT is that copy. DRIFTED redefines one function only, so
# under the mutant with no identity check one call shows both halves: the
# plugin's file really is sourced, and a function only the core copy defines is
# still there.
CURRENT="$VDIR/core/cmd_proof.sh"
cp "$ROOT/src/cmd_proof.sh" "$CURRENT"; chmod 644 "$CURRENT"
DRIFTED_TEXT='cmd_proof() {
  echo "DEVTEAM-OVERLAY $(declare -F _proof_ledger >/dev/null && echo core-kept || echo core-lost)"
}'
ln -s "$VDIR" "$PL/enabled/devteam@5dive-plugins"
record() {  # record <review> <capabilities-json> <enabled>
  jq -n --arg r "$1" --argjson c "$2" --argjson e "$3" \
    '{"devteam@5dive-plugins": {plugin:"devteam", marketplace:"5dive-plugins", version:"0.1.0",
       enabled:$e, review:$r, publisher:"5dive", capabilities:$c, grants:[], verbs:[]}}' \
    > "$PL/installed.json"
  chmod 644 "$PL/installed.json"
}
OUT=""; ERR=""
proof() {  # run `5dive proof` from the bundle under test; OUT/ERR
  local b="${BIN:-$BUNDLE}"
  OUT=$(FIVE_LAZY_TRACE=1 bash "$b" proof 2>"$TMP/.e"); ERR=$(cat "$TMP/.e")
}
LOADED="overlay cmd_proof in use from $CURRENT"
drift()   { printf '%s\n' "$DRIFTED_TEXT" > "$CURRENT"; chmod 644 "$CURRENT"; }
undrift() { cp "$ROOT/src/cmd_proof.sh" "$CURRENT"; chmod 644 "$CURRENT"; }

record official '["core"]' true
BIN="$BUNDLE"
t  "B0 negative control: the bundle recorded the sha of the core's own cmd_proof.sh" \
   "__DEVTEAM_CORE_SHA[cmd_proof]=$(sha256sum <"$ROOT/src/cmd_proof.sh" | cut -d' ' -f1)" \
   "$(grep -m1 '^__DEVTEAM_CORE_SHA\[cmd_proof\]=' "$BUNDLE")"
proof
tc "B1 official, enabled, core capability, safe files, same bytes: the plugin's copy is in use" "$LOADED" "$ERR"
tn "B1a and those bytes are not read a second time" "overlay cmd_proof from" "$ERR"
tc "B1b and the verb answers as it always did" "usage: 5dive proof" "$OUT$ERR"
drift; proof
tn "B1c a plugin copy that differs from this core is NOT read (a core fix must not be undone)" "DEVTEAM-OVERLAY" "$OUT"
tc "B1d and the trace says why" "overlay cmd_proof skipped: the plugin copy differs from this core" "$ERR"
undrift

FIVEDIVE_DEVTEAM=0 proof
tn "B2 FIVEDIVE_DEVTEAM=0 skips the plugin" "$LOADED" "$ERR"

record community '["core"]' true; proof
tn "B3 a record whose review is community is not loaded" "$LOADED" "$ERR"
record official '["verb"]' true; proof
tn "B4 a record without the core capability is not loaded" "$LOADED" "$ERR"
record official '["core"]' false; proof
tn "B5 a disabled record is not loaded" "$LOADED" "$ERR"

record official '["core"]' true
chmod 664 "$CURRENT"; proof
tn "B6 a group-writable core file is not loaded" "$LOADED" "$ERR"
tc "B6b and it says why, with the way out" "writable by someone other than root" "$ERR"
chmod 644 "$CURRENT"
chmod 777 "$VDIR/core"; proof
tn "B7 a world-writable core/ directory is not loaded" "$LOADED" "$ERR"
chmod 755 "$VDIR/core"
chmod 666 "$PL/installed.json"; proof
tn "B8 a writable install record is not trusted" "$LOADED" "$ERR"
chmod 644 "$PL/installed.json"

mv "$PL/enabled/devteam@5dive-plugins" "$PL/enabled/devteam@lookalike"
jq '{"devteam@lookalike": (.["devteam@5dive-plugins"] | .marketplace = "lookalike")}' "$PL/installed.json" > "$TMP/x" && mv "$TMP/x" "$PL/installed.json"
chmod 644 "$PL/installed.json"; proof
tn "B9 the same plugin under any other key is not loaded" "overlay" "$ERR"
mv "$PL/enabled/devteam@lookalike" "$PL/enabled/devteam@5dive-plugins"
record official '["core"]' true

rm "$PL/enabled/devteam@5dive-plugins"; proof
tn "B10 no plugin installed: nothing is overlaid" "overlay" "$ERR"
tc "B10b and the core's verb answers" "usage: 5dive proof" "$OUT$ERR"
ln -s "$VDIR" "$PL/enabled/devteam@5dive-plugins"

proof
tc "B11 positive control after every negative above: it loads again" "$LOADED" "$ERR"

# DIVE-6959: the real plugin ships all eight modules, and five of them declare a
# top-level readonly, which dies if the same file is read twice. cmd_proof has
# none, which is why B1 could not see it. Each verb below loads at least one of
# them; `task deliver` stops at the empty task store, past the module load.
DT_MODS="task/delivery.sh task/gate_evidence.sh task/grader_pool.sh task/grader_process.sh cmd_proof.sh cmd_gh.sh cmd_push.sh cmd_deploy.sh"
allmods() { local r; mkdir -p "$VDIR/core/task"; for r in $DT_MODS; do cp "$ROOT/src/$r" "$VDIR/core/$r"; chmod 644 "$VDIR/core/$r"; done; }
nomods()  { local r; for r in $DT_MODS; do [[ "$r" == cmd_proof.sh ]] || rm -f "$VDIR/core/$r"; done; undrift; }
RO_RC=""
ro_verbs() {  # every verb under ${BIN:-$BUNDLE}; RO_OUT = all stderr, RO_RC = rcs
  local b="${BIN:-$BUNDLE}" v; RO_OUT=""; RO_RC=""
  for v in "gh --help" "push --help" "deploy --help" "team ps --help" "task deliver NOPE-1"; do
    # shellcheck disable=SC2086
    FIVE_LAZY_TRACE=1 bash "$b" $v >/dev/null 2>"$TMP/.e"; RO_RC+="$v=$? "
    RO_OUT+=$(cat "$TMP/.e")$'\n'
  done
}
allmods; FIVEDIVE_DEVTEAM=0 ro_verbs; RO_BASE="$RO_RC"
tn "B12-base negative control: the verbs ran the core copies" "overlay" "$RO_OUT"
ro_verbs
tc "B12-pre all five readonly modules were offered by the plugin and accepted" \
   "overlay cmd_gh in use from $VDIR/core/cmd_gh.sh" "$RO_OUT"
for _m in cmd_push cmd_deploy task__delivery task__gate_evidence; do
  tc "B12-pre $_m is in use too" "overlay $_m in use from" "$RO_OUT"
done
tn "B12 a module that declares readonly survives the plugin standing in for it" "readonly variable" "$RO_OUT"
t  "B12b and every verb exits as it does without the plugin" "$RO_BASE" "$RO_RC"
tc "B12b2 and that baseline is real (gh --help answers)" "gh --help=0 " "$RO_BASE"
tc "B12c task deliver got past the module load to its own refusal" "tasks store not initialised" "$RO_OUT"
nomods

# Phase 2's shape: no recorded sha for a module means the core no longer carries
# it, and the plugin's copy is read as the code.
BIN="$TMP/5dive.phase2"
grep -v '^__DEVTEAM_CORE_SHA\[cmd_proof\]=' "$BUNDLE" > "$BIN"
drift; proof; undrift
tc "B13 no recorded sha (phase 2): the plugin's copy is read as the code" "DEVTEAM-OVERLAY core-kept" "$OUT"
tc "B13b and the trace says it was read" "overlay cmd_proof from $CURRENT" "$ERR"
BIN="$BUNDLE"

# =============================================================================
# Part C — mutants. Each removes one pin; the arm it guards must go red.
# =============================================================================
mutant() {  # mutant <name> <sed-expr>  -> path of a mutated bundle
  local m="$TMP/5dive.$1"
  sed -e "$2" "$BUNDLE" > "$m"
  cmp -s "$BUNDLE" "$m" && { echo "FAIL: mutant $1 changed nothing" >&2; }
  printf '%s' "$m"
}
BIN=$(mutant perms 's/^_devteam_path_safe() {$/_devteam_path_safe() { return 0;/')
chmod 664 "$CURRENT"; proof; chmod 644 "$CURRENT"
tc "C1 mutant: no ownership/write check -> B6 would load the group-writable file" "$LOADED" "$ERR"
BIN=$(mutant review 's/(\.review == "official")/true/')
record community '["core"]' true; proof; record official '["core"]' true
tc "C2 mutant: no review pin -> B3 would load a community record" "$LOADED" "$ERR"
BIN=$(mutant hook 's/^    _devteam_overlay "\${__lz_pending\[@\]}"$/    :/')
proof
tn "C3 mutant: no hook in the lazy loader -> B1 would not see the plugin" "$LOADED" "$ERR"
BIN=$(mutant same 's/^_devteam_copy_current() {$/_devteam_copy_current() { return 0;/')
drift; proof; undrift
tc "C4 mutant: no identity check -> B1c would run the drifted copy" "DEVTEAM-OVERLAY" "$OUT"
tc "C4b and that proves the plugin's file is really sourced, keeping core-only functions" "core-kept" "$OUT"
BIN=$(mutant reread '/^_devteam_copy_current() {$/,/^}$/ s/^  return 2$/  return 0/')
allmods; ro_verbs; nomods
tc "C5-pre the mutant still put the modules in use" "overlay cmd_gh from" "$RO_OUT"
tc "C5 mutant: an identical copy is read again (the DIVE-6939 overlay) -> B12 would die on readonly" "readonly variable" "$RO_OUT"
BIN="$BUNDLE"
for _m in perms review hook same reread; do
  cmp -s "$BUNDLE" "$TMP/5dive.$_m"
  t "C0-$_m the mutant really changed the bundle" "1" "$?"
done

# =============================================================================
# Part A — the install gate, sourced like tests/plugin_contract_unit.sh
# =============================================================================
export STATE_DIR="$TMP/state-a"
# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/header.sh
# shellcheck source=/dev/null
source src/lib/devteam.sh
# shellcheck source=/dev/null
source src/cmd_plugin.sh
set +e -o pipefail
require_root() { :; }
JSON_MODE=0
RC=0
run() {
  local o="$TMP/.o" e="$TMP/.e"
  ( "$@" ) >"$o" 2>"$e"; RC=$?
  OUT=$(cat "$o"); ERR=$(cat "$e")
  return 0
}
# shellcheck source=/dev/null
. "$ROOT/tests/lib/github_fixture.sh"
gh_fixture_seam "$TMP/github"
unset FIVEDIVE_PLUGIN_REGISTRY
mkmkt() {  # mkmkt <owner> -> a fixture marketplace with devteam + corecomm
  local m="$TMP/github/$1/fixture-mkt.git" n caps review
  mkdir -p "$m/.claude-plugin"
  for n in devteam corecomm; do
    review=official; [[ "$n" == corecomm ]] && review=community
    mkdir -p "$m/$n/.claude-plugin" "$m/$n/core"
    echo ': # fixture' > "$m/$n/core/cmd_proof.sh"
    jq -cn --arg n "$n" --arg r "$review" \
      '{name:$n, version:"0.1.0", description:"fixture", author:{name:"t"},
        fivedive:{contract:"1", capabilities:["core"], grants:[],
                  trust:{publisher:"t", did:"did:key:t", review:$r}}}' > "$m/$n/.claude-plugin/plugin.json"
  done
  jq -n '{name:"fixture", description:"t", owner:{name:"t"},
          plugins:[{name:"devteam",description:"d",category:"test",source:"./devteam"},
                   {name:"corecomm",description:"c",category:"test",source:"./corecomm"}]}' \
    > "$m/.claude-plugin/marketplace.json"
  gh_fixture_publish "$m"
}
mkmkt 5dive-ai
mkmkt someone

t "A0 the gate function exists (an empty source would pass every refusal vacuously)" "function" "$(type -t _plugin_core_cap_gate)"
run _plugin_mkt_add 5dive-ai/fixture-mkt --as=fixture
t "A0b fixture marketplace registers" "0" "$RC"
run cmd_plugin_add devteam@fixture --yes
t  "A1 the core capability under any key but devteam@5dive-plugins is refused" "$E_VALIDATION" "$RC"
tc "A1b and the refusal names the one key that may use it" "only 5dive's own devteam@5dive-plugins" "$ERR"

run _plugin_mkt_add 5dive-ai/fixture-mkt --as=5dive-plugins
t "A2-pre the same source registers as 5dive-plugins" "0" "$RC"
run cmd_plugin_add corecomm@5dive-plugins --yes
tc "A2b and it is the core gate that refused it" "only 5dive's own" "$ERR"
t  "A2 a community plugin declaring core is refused, even from 5dive's marketplace" "$E_VALIDATION" "$RC"
run cmd_plugin_add devteam@5dive-plugins --yes
t  "A3 positive control: devteam@5dive-plugins from a 5dive-owned source installs" "0" "$RC"
t  "A3b and its record carries the core capability the loader looks for" "true" \
   "$(jq -r '.["devteam@5dive-plugins"] | (.capabilities | index("core") != null) and .review == "official"' "$STATE_DIR/plugins/installed.json")"
( _devteam_resolve; echo "dir=$_DEVTEAM_DIR why=$_DEVTEAM_WHY" ) > "$TMP/.r" 2>&1
tc "A3c and the loader accepts what install wrote" "dir=$STATE_DIR/plugins/cache/5dive-plugins/devteam/0.1.0" "$(cat "$TMP/.r")"

tc "A3d doctor's line says where the dev-team tools come from" "loaded from $STATE_DIR/plugins/cache/5dive-plugins/devteam/0.1.0 (1 of 8 modules in use)" "$(devteam_status_line 2>&1)"

# The same plugin from somebody else's GitHub, registered under 5dive's name.
export STATE_DIR="$TMP/state-a2"
run _plugin_mkt_add someone/fixture-mkt --as=5dive-plugins
run cmd_plugin_add devteam@5dive-plugins --yes
tc "A4b and it is the core gate that refused it" "only 5dive's own" "$ERR"
t  "A4 devteam@5dive-plugins from a source 5dive does not own is refused" "$E_VALIDATION" "$RC"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
