#!/usr/bin/env bash
# DIVE-4035 — contract §2's live half: a DECLARED verb is dispatched.
#
# The row's grading mutant is "a plugin declares a verb that is NOT dispatched:
# install must either make it work or say out loud that it did not". Every arm
# below drives the real functions against a real store on a throwaway STATE_DIR;
# none of them greps the source for a line, with ONE deliberate exception (T5,
# the builtin-list guard) whose whole subject IS a source-derived list.
#
# THE DISPATCH ARMS RUN A REAL EXEC. _plugin_dispatch_verb ends in `exec`, which
# replaces the process — so every arm that reaches it runs inside `run()`'s
# subshell and reads what the child left behind, never a return value. T4b is the
# positive control for that mechanism: if the sentinel scheme were broken, every
# "did not execute" assertion below would pass for the wrong reason, which is
# exactly the trap DIVE-4020's suite documents at its own `set +e`.
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

# header.sh:14 is `set -euo pipefail`; sourcing it turns errexit on in THIS
# shell, where the `( ... )` in run() would take the harness down with the first
# refusal it is meant to grade. Same reason, same fix, as plugin_contract_unit.
set +e -o pipefail

require_root() { :; }

TMP="$(mktemp -d)"
export STATE_DIR="$TMP/state"
SENTINEL="$TMP/EXECUTED"
export SENTINEL

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

OUT=""; ERR=""; RC=0
run() {
  local o="$TMP/.o" e="$TMP/.e"
  ( "$@" ) >"$o" 2>"$e"; RC=$?
  OUT=$(cat "$o"); ERR=$(cat "$e")
  return 0
}

# ---- fixtures ---------------------------------------------------------------
MKT="$TMP/fixture-mkt"
mkdir -p "$MKT/.claude-plugin"

# The entry point every runnable fixture ships. It records that it RAN and the
# argv it was handed, so an arm can assert both "it executed" and "the vector
# survived" from one file.
mkentry() {  # mkentry <plugin-dir-name> <verb>
  mkdir -p "$MKT/$1/bin"
  cat > "$MKT/$1/bin/$2" <<'ENTRY'
#!/usr/bin/env bash
{ printf 'RAN=%s\n' "${FIVEDIVE_VERB:-?}"
  printf 'KEY=%s\n' "${FIVEDIVE_PLUGIN_KEY:-?}"
  printf 'DIR=%s\n' "${FIVEDIVE_PLUGIN_DIR:-?}"
  printf 'ARGC=%s\n' "$#"
  for a in "$@"; do printf 'ARG=[%s]\n' "$a"; done
} > "$SENTINEL"
echo "voice-fixture-stdout"
ENTRY
  chmod +x "$MKT/$1/bin/$2"
}

mkplugin() {  # mkplugin <dir-name> <manifest-json>
  mkdir -p "$MKT/$1/.claude-plugin"
  printf '%s\n' "$2" > "$MKT/$1/.claude-plugin/plugin.json"
}
mkindex() {
  local arr="[]" d n
  for d in "$MKT"/*/; do
    n=$(basename "${d%/}"); [[ "$n" == .* ]] && continue
    arr=$(jq -c --arg n "$n" '. + [{name:$n, description:("fixture " + $n), category:"test", source:("./" + $n)}]' <<<"$arr")
  done
  jq -n --argjson p "$arr" '{name:"fixture", description:"test fixture", owner:{name:"t"}, plugins:$p}' \
    > "$MKT/.claude-plugin/marketplace.json"
}

# manifest <name> <caps-json> <verbs-json>
manifest() {
  jq -cn --arg n "$1" --argjson caps "$2" --argjson verbs "$3" \
     '{name:$n, version:"1.0.0", description:"fixture", author:{name:"t"},
       fivedive:{contract:"1", capabilities:$caps, verbs:$verbs, grants:[],
                 trust:{publisher:"t", did:"did:key:t", review:"official"}}}'
}
V() { jq -cn --arg n "$1" '[{name:$n, summary:"fixture verb", installs:"channel"}]'; }

# runnable, correctly declared
mkplugin sings   "$(manifest sings '["verb"]' "$(V sing)")";        mkentry sings sing
# names a verb but never declares the capability — inert under §2, and the whole
# point is that it must SAY so
mkplugin mutters "$(manifest mutters '["channel"]' "$(V mutter)")"; mkentry mutters mutter
# declares the capability and names nothing
mkplugin empty   "$(manifest empty '["verb"]' '[]')"
# verb name that is not kebab-case
mkplugin shouty  "$(manifest shouty '["verb"]' "$(V SING)")"
# collides with a real 5dive builtin
mkplugin usurper "$(manifest usurper '["verb"]' "$(V task)")";      mkentry usurper task
# declares a verb and ships no bin/ at all
mkplugin hollow  "$(manifest hollow '["verb"]' "$(V hum)")"
# ships the file but forgets chmod +x
mkplugin limp    "$(manifest limp '["verb"]' "$(V whistle)")"
  mkdir -p "$MKT/limp/bin"; echo '#!/bin/sh' > "$MKT/limp/bin/whistle"
# a SECOND plugin claiming `sing`
mkplugin rival   "$(manifest rival '["verb"]' "$(V sing)")";        mkentry rival sing
# §5 negative control: the manifest carries strings that WOULD write a sentinel
# if anything ever evaluated them. Nothing may.
mkplugin sneaky  "$(manifest sneaky '["verb"]' "$(V sneak)")";      mkentry sneaky sneak
  jq --arg c 'touch '"$TMP/MANIFEST-STRING-RAN" \
     '.fivedive.setup = {hint:"h", command:$c} | .fivedive.verbs[0].command = $c' \
     "$MKT/sneaky/.claude-plugin/plugin.json" > "$TMP/x" && mv "$TMP/x" "$MKT/sneaky/.claude-plugin/plugin.json"
mkindex

run cmd_plugin_marketplace add "$MKT" --as=fixture
t  'setup: marketplace add rc' 0 "$RC"

# ---- T1  §2 both directions, at validation time -----------------------------
run cmd_plugin_add mutters@fixture --yes
t  'T1a mutters installs (verbs without the capability are inert, not invalid)' 0 "$RC"
tc 'T1a mutters says the verb will not be dispatched' 'will NOT be dispatched' "$ERR"
tc 'T1a mutters names the dead command'               "5dive mutter" "$ERR"

run cmd_plugin_add empty@fixture --yes
t  'T1b verb capability with no verbs is refused' "$E_VALIDATION" "$RC"
tc 'T1b names the missing declaration' 'names no verbs' "$ERR"

run cmd_plugin_add shouty@fixture --yes
t  'T1c non-kebab verb name refused' "$E_VALIDATION" "$RC"
tc 'T1c names the offending verb' "'SING'" "$ERR"

# ---- T2  install-time collision + entry-point refusals ----------------------
run cmd_plugin_add usurper@fixture --yes
t  'T2a verb colliding with a builtin is refused' "$E_VALIDATION" "$RC"
tc 'T2a names the builtin'      "verb 'task'" "$ERR"
tc 'T2a explains it could never run' 'could never run' "$ERR"

run cmd_plugin_add hollow@fixture --yes
t  'T2b declared verb with no executable is refused' "$E_VALIDATION" "$RC"
tc 'T2b names where 5dive looks' 'bin/hum' "$ERR"

run cmd_plugin_add limp@fixture --yes
t  'T2c non-executable entry point is refused' "$E_VALIDATION" "$RC"
tc 'T2c names the chmod'  'chmod +x' "$ERR"

run cmd_plugin_add sings@fixture --yes
t  'T2d a correctly declared verb installs' 0 "$RC"
tc 'T2d says the verb is now live' "'5dive sing' now runs this plugin" "$ERR"
t  'T2d record carries the verb capability' 'true' \
   "$(jq -r '.["sings@fixture"].capabilities | index("verb") != null' "$STATE_DIR/plugins/installed.json")"
t  'T2d record carries the verb name' 'sing' \
   "$(jq -r '.["sings@fixture"].verbs[0].name' "$STATE_DIR/plugins/installed.json")"

run cmd_plugin_add rival@fixture --yes
t  'T2e a second claimant is refused' "$E_VALIDATION" "$RC"
tc 'T2e names the incumbent' 'sings@fixture' "$ERR"

# ---- T3  resolution reads the RECORD, and honours enable/disable ------------
t 'T3a an enabled declared verb resolves to its plugin' 'sings@fixture' "$(_plugin_verb_claims sing)"
t 'T3b an undeclared verb resolves to nothing'          ''              "$(_plugin_verb_claims mutter)"
t 'T3c an unknown verb resolves to nothing'             ''              "$(_plugin_verb_claims nosuch)"

run cmd_plugin_disable sings@fixture
t 'T3d disable makes the verb stop resolving' '' "$(_plugin_verb_claims sing)"
run cmd_plugin_enable sings@fixture
t 'T3e enable brings it back' 'sings@fixture' "$(_plugin_verb_claims sing)"

_plugin_verb_entry_in "$STATE_DIR/plugins/enabled/sings@fixture" sing >/dev/null; t 'T3f entry resolves when executable' 0 "$?"
_plugin_verb_entry_in "$MKT/limp" whistle >/dev/null;                            t 'T3g entry refuses a non-executable file' 1 "$?"
_plugin_verb_entry_in "$MKT/hollow" hum >/dev/null;                              t 'T3h entry refuses a missing file' 1 "$?"

# ---- T4  dispatch: the real exec -------------------------------------------
rm -f "$SENTINEL"
run _plugin_dispatch_verb sing one "two three" '*'
t  'T4a dispatch execs the entry point'   0 "$RC"
tc 'T4a the child ran'          'RAN=sing'          "$(cat "$SENTINEL" 2>/dev/null)"
tc 'T4a the child was told its key' 'KEY=sings@fixture' "$(cat "$SENTINEL" 2>/dev/null)"
tc 'T4a the child stdout reaches the caller' 'voice-fixture-stdout' "$OUT"
t  'T4a argv arrived as a VECTOR, not a string' 'ARGC=3' \
   "$(grep '^ARGC=' "$SENTINEL")"
tc 'T4a an argument with spaces survived intact' 'ARG=[two three]' "$(cat "$SENTINEL")"
tc 'T4a a glob argument was not expanded'        'ARG=[*]'         "$(cat "$SENTINEL")"

# POSITIVE CONTROL for every "did not run" assertion below.
rm -f "$SENTINEL"
( SENTINEL="$SENTINEL" "$STATE_DIR/plugins/enabled/sings@fixture/bin/sing" probe >/dev/null 2>&1 )
t 'T4b positive control: the sentinel mechanism works' 'yes' \
  "$([[ -f "$SENTINEL" ]] && echo yes || echo no)"

rm -f "$SENTINEL"
run _plugin_dispatch_verb nosuch
t  'T4c an unclaimed verb returns 1 for main() to turn into unknown command' 1 "$RC"
t  'T4c and says nothing at all' '' "$ERR$OUT"
t  'T4c and executed nothing' 'no' "$([[ -f "$SENTINEL" ]] && echo yes || echo no)"

# A builtin name hand-written into the store cannot be dispatched, independent of
# where the call site sits in main().
jq '.["usurper@fixture"] = {plugin:"usurper", marketplace:"fixture", version:"1.0.0",
      enabled:true, review:"official", publisher:"t", capabilities:["verb"],
      grants:[], verbs:[{name:"task"}], installed_at:"x"}' \
  "$STATE_DIR/plugins/installed.json" > "$TMP/x" && mv "$TMP/x" "$STATE_DIR/plugins/installed.json"
run _plugin_dispatch_verb task ls
t 'T4d a builtin name is never dispatched, even when the store claims it' 1 "$RC"
t 'T4d and it printed nothing'                                           '' "$ERR$OUT"

# Two enabled claimants: refuse, do not pick.
jq '.["rival@fixture"] = {plugin:"rival", marketplace:"fixture", version:"1.0.0",
      enabled:true, review:"official", publisher:"t", capabilities:["verb"],
      grants:[], verbs:[{name:"sing"}], installed_at:"x"}' \
  "$STATE_DIR/plugins/installed.json" > "$TMP/x" && mv "$TMP/x" "$STATE_DIR/plugins/installed.json"
rm -f "$SENTINEL"
run _plugin_dispatch_verb sing
t  'T4e two claimants refuse rather than pick' "$E_VALIDATION" "$RC"
tc 'T4e names both'  'sings@fixture' "$ERR"
tc 'T4e names both'  'rival@fixture' "$ERR"
t  'T4e and ran neither' 'no' "$([[ -f "$SENTINEL" ]] && echo yes || echo no)"
jq 'del(.["rival@fixture"]) | del(.["usurper@fixture"])' \
  "$STATE_DIR/plugins/installed.json" > "$TMP/x" && mv "$TMP/x" "$STATE_DIR/plugins/installed.json"

# Claimed, but the entry point has gone missing since install.
mv "$STATE_DIR/plugins/cache/fixture/sings/1.0.0/bin/sing" "$TMP/sing.parked"
run _plugin_dispatch_verb sing
t  'T4f a claimed verb with no runnable entry fails loudly' "$E_NOT_FOUND" "$RC"
tc 'T4f names the path it looked at' 'bin/sing' "$ERR"
mv "$TMP/sing.parked" "$STATE_DIR/plugins/cache/fixture/sings/1.0.0/bin/sing"

run cmd_plugin_disable sings@fixture
rm -f "$SENTINEL"
run _plugin_dispatch_verb sing
t 'T4g a disabled plugin does not dispatch'  1 "$RC"
t 'T4g and executed nothing' 'no' "$([[ -f "$SENTINEL" ]] && echo yes || echo no)"
run cmd_plugin_enable sings@fixture

# §5 stays shut: install AND dispatch a plugin whose manifest carries command
# strings, and assert nothing ever evaluated one.
rm -f "$TMP/MANIFEST-STRING-RAN"
run cmd_plugin_add sneaky@fixture --yes
t  'T4h sneaky installs' 0 "$RC"
tc 'T4h the setup command is PRINTED' 'Run it yourself' "$ERR"
run _plugin_dispatch_verb sneak
t  'T4h dispatch runs the file, not the manifest string' 0 "$RC"
t  'T4h no string out of plugin.json was ever executed (contract §5)' 'no' \
   "$([[ -f "$TMP/MANIFEST-STRING-RAN" ]] && echo yes || echo no)"

# ---- T6  the registry is READABLE by the unprivileged caller ----------------
# The defect this row surfaced on a real box: every writer builds the document in
# a `mktemp` and moves it into place, and mktemp is 0600, so installed.json was
# root-only. Invisible for all of DIVE-4020 (every `plugin` subverb is
# root-gated, so the only readers were root) and fatal to dispatch, whose reader
# is whoever typed the verb. These arms grade the MODE of the artifact rather
# than the presence of a chmod line, so they red on any writer that forgets to
# route through _plugin_publish_json.
t 'T6a installed.json is world-readable after an install' '644' \
  "$(stat -c %a "$STATE_DIR/plugins/installed.json")"
t 'T6b marketplaces.json is world-readable' '644' \
  "$(stat -c %a "$STATE_DIR/plugins/marketplaces.json")"
t 'T6c the store root is traversable' '755' "$(stat -c %a "$STATE_DIR/plugins")"
t 'T6d the enabled/ pointer dir is traversable' '755' "$(stat -c %a "$STATE_DIR/plugins/enabled")"
# Every mutating subverb must LEAVE it readable, not just `add`.
run cmd_plugin_disable sings@fixture
t 'T6e ...and still readable after disable rewrites it' '644' \
  "$(stat -c %a "$STATE_DIR/plugins/installed.json")"
run cmd_plugin_enable sings@fixture
t 'T6f ...and after enable' '644' "$(stat -c %a "$STATE_DIR/plugins/installed.json")"
run cmd_plugin_remove sneaky@fixture
t 'T6g ...and after remove' '644' "$(stat -c %a "$STATE_DIR/plugins/installed.json")"

# ---- T5  the builtin list is not hand-maintained on trust -------------------
# The ONE source-derived arm in this file, because the subject IS the source: a
# new top-level verb added to main.sh without a line here would silently become
# claimable by a plugin, and no behavioural arm can see a verb that does not
# exist yet.
declared=$(printf '%s\n' $FIVEDIVE_BUILTIN_VERBS | sort -u)
actual=$(awk 'f&&/^}$/{exit} /^main\(\) \{$/{f=1} f' "$ROOT/src/main.sh" \
         | grep -oE '^    [a-z0-9_|*-]+\)' | tr -d ' )' | tr '|' '\n' | grep -v '^\*$' | sort -u)
t 'T5 FIVEDIVE_BUILTIN_VERBS matches main.sh case labels exactly' "$actual" "$declared"

# ---- T7  the WIRING in main.sh, graded through the real binary --------------
# Every arm above calls _plugin_dispatch_verb directly, which is exactly the
# blind spot a maker builds for themselves: delete the call site from main.sh's
# `*)` branch and all 62 of them stay green while `5dive voice` goes back to
# being an unknown command. So these run the BUILT CLI.
#
# The store is assembled BY HAND here rather than through cmd_plugin_add,
# because every `5dive plugin` subverb is root-gated and a suite must not need
# root. That is not a shortcut past the install path — T1/T2 grade that — it is
# the only way to reach the dispatcher as an ordinary user.
#
# NO SKIP IF ./5dive IS ABSENT. An unbuilt tree would silently drop the only
# arms that can see the wiring, and a suite that is green because it did not run
# is the failure mode this corpus has been bitten by before. Build first.
E2E="$TMP/e2e"; mkdir -p "$E2E/plugins/enabled" "$E2E/plugins/cache/fixture/sings/1.0.0/bin"
cat > "$E2E/plugins/cache/fixture/sings/1.0.0/bin/sing" <<'E2EENTRY'
#!/usr/bin/env bash
printf 'E2E-RAN verb=%s key=%s argc=%s\n' "${FIVEDIVE_VERB:-?}" "${FIVEDIVE_PLUGIN_KEY:-?}" "$#"
for a in "$@"; do printf 'E2E-ARG=[%s]\n' "$a"; done
E2EENTRY
chmod +x "$E2E/plugins/cache/fixture/sings/1.0.0/bin/sing"
ln -sfn "$E2E/plugins/cache/fixture/sings/1.0.0" "$E2E/plugins/enabled/sings@fixture"
jq -n '{"sings@fixture":{plugin:"sings", marketplace:"fixture", version:"1.0.0",
        enabled:true, review:"official", publisher:"t", capabilities:["verb"],
        grants:[], verbs:[{name:"sing"}], installed_at:"x"}}' \
  > "$E2E/plugins/installed.json"
echo '{}' > "$E2E/plugins/marketplaces.json"

if [[ ! -x "$ROOT/5dive" ]]; then
  FAIL=$((FAIL+1))
  printf 'FAIL: T7-precondition ./5dive is not built — run ./build.sh; the wiring arms cannot run\n'
else
  e2e() { ( STATE_DIR="$E2E" "$ROOT/5dive" "$@" ) 2>"$TMP/.e2ee"; }
  out=$(e2e sing alpha "two words"); rc=$?
  t  'T7a the built CLI dispatches a plugin verb' 0 "$rc"
  tc 'T7a ...running the entry point'      'E2E-RAN verb=sing' "$out"
  tc 'T7a ...with its key'                 'key=sings@fixture' "$out"
  tc 'T7a ...and argv as a vector'         'E2E-ARG=[two words]' "$out"
  t  'T7a ...exactly two arguments'        'argc=2' "$(grep -o 'argc=[0-9]*' <<<"$out")"

  out=$(e2e definitely-not-a-verb); rc=$?
  t  'T7b an unclaimed command still fails as usage' 2 "$rc"
  tc 'T7b ...with the unchanged message' 'unknown command: definitely-not-a-verb' "$(cat "$TMP/.e2ee")"

  # A builtin still wins, with the plugin store present and claiming nothing
  # relevant — the structural guarantee, measured rather than reasoned.
  out=$(e2e --version); rc=$?
  t  'T7c builtins are untouched by the new branch' 0 "$rc"
  tc 'T7c ...and still answer'                     '5dive' "$out"

  # Disabled means gone, through the real binary too.
  jq '.["sings@fixture"].enabled = false' "$E2E/plugins/installed.json" > "$TMP/x" \
    && mv "$TMP/x" "$E2E/plugins/installed.json"
  e2e sing >/dev/null; rc=$?
  t  'T7d a disabled plugin is not dispatched by the built CLI' 2 "$rc"
  tc 'T7d ...and reads as an unknown command' 'unknown command: sing' "$(cat "$TMP/.e2ee")"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
