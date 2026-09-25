#!/usr/bin/env bash
# DIVE-4126 — every plugin we BUNDLE must install on a stock box.
#
# WHY THIS FILE EXISTS, and it is a test-design finding rather than a bug report.
# v0.28.0 shipped the browser plugin (DIVE-4021) and `sudo 5dive plugin add
# browser` refused it on every customer box: "unknown grant 'browser-profiles'".
# The manifest declared a grant the enforcer's enum did not carry. 86 arms in
# tests/plugin_contract_unit.sh did not see it, and could not have:
#
#   - that suite builds FIXTURE plugins to grade one rule each, so the only
#     manifests it ever validates are ones it wrote itself, and
#   - tests/plugin_contract_unit.sh's bundled arms set-COMPARE the staged FILE
#     list — they grade that the directory arrived, never that it installs.
#
# So the corpus graded the installer against synthetic input and graded the
# payload against a file listing, and the one question a customer asks — does
# `plugin add <the thing you ship>` work — was asked by nobody. This file asks
# exactly that, and it asks it of EVERY plugin the REGISTRY publishes, discovered
# at run time, so plugin number three is covered the day it lands rather than the
# day someone remembers to add an arm.
#
# DIVE-4202 MOVED THE CORPUS. `voice` and `browser` were the last two plugins in
# this repo; they now live in 5dive-ai/5dive-plugins with every other one, so the
# tree this harness grades is no longer inside the checkout. It resolves a
# registry checkout from $FIVEDIVE_PLUGIN_REGISTRY (CI checks the registry out
# and sets it — see .github/workflows/*, unit-tests). With no registry checkout
# the corpus arms CANNOT run, and they say so in a NOT-RUN banner and a count on
# the summary line rather than passing vacuously: a skipped arm is silence, not
# a green. The fixture arms (T3-T6) are unaffected and always run.
#
# NEGATIVE CONTROLS. Two arms exist so a green here cannot mean "the enum was
# widened until everything passes": T3 proves an unknown grant is STILL refused,
# and T5 proves the grant's enforcement bites on a store that would leak.
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
# The registry resolves through this seam (cmd_plugin.sh
# _plugin_registry_source), which is what lets the arms below install the REAL
# published plugin tree rather than whatever is on the box — and, because the
# seam accepts a local path, WITHOUT a network fetch inside a unit test.
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
# RMKT, not MKT: the fixture arms below already own the name MKT.
RMKT=5dive-plugins
NOTRUN=0

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

OUT=""; ERR=""; RC=0
# Deliberately NOT `RC=$(...)`: a helper called inside `$( )` sets its globals in
# a SUBSHELL, so OUT/ERR would come back empty in the parent and every message
# arm would assert against "" — the trap plugin_contract_unit documents.
run() {
  local o="$TMP/.o" e="$TMP/.e"
  ( "$@" ) >"$o" 2>"$e"; RC=$?
  OUT=$(cat "$o"); ERR=$(cat "$e")
  return 0
}

# ---- what we ship ----------------------------------------------------------
# Discovered from the registry's own manifest, never listed. A hardcoded list is
# how this gap reappears.
#
# DIVE-4708 — SPLIT BY THE TIER EACH PLUGIN DECLARES, and that split is the fix.
# This loop used to produce one set and T1 asserted rc 0 for all of it. But the
# harness enumerated the CATALOGUE while the product enumerates the `official`
# ALLOWLIST (_plugin_trust_gate refuses anything whose own manifest does not
# declare fivedive.trust.review == "official"). Those two sets were equal by
# COINCIDENCE, and nothing anywhere asserted they must be — so when
# 5dive-plugins@a609407 published `mod` with no review block on
# 2026-09-20T15:55:49Z, T1 demanded an install the trust gate is SUPPOSED to
# refuse, and this repo went red with no commit of its own.
#
# The outcome is not the contract; the RELATIONSHIP is. A box-installable plugin
# installs if and only if it declares `official`, so each discovered plugin is
# graded against the tier IT declares. Plugin #7 is then covered the day it lands
# whichever tier it carries, and neither half can go vacuous: T0b requires an
# installable one (or the T1/T2/T7 loops grade nothing) and T0c asserts the
# biconditional itself, so "install everything" and "refuse everything" are both
# red.
#
# DIVE-4955 moved the line the split is drawn on. The tier no longer decides
# whether a plugin installs — it is decided by the SOURCE and only labels it —
# so the biconditional is now "installs IFF it follows the standard" (a
# non-empty `fivedive` block, cmd_plugin.sh _plugin_follows_standard). `mod`,
# which carries no block, is still refused; the message is now the standard's.
#
# A plugin's manifest is resolved through the `source` its publisher DECLARES in
# the index, not by guessing $REGISTRY/plugins/<name>: the index is the only
# thing that says where a plugin lives.
_reg_standard() {   # <name> -> "yes" iff the plugin's OWN manifest carries a non-empty fivedive block
  local n="$1" src mf
  src=$(jq -r --arg n "$n" '.plugins[] | select(.name==$n) | .source // ""' \
        "$REGISTRY/.claude-plugin/marketplace.json" 2>/dev/null)
  [[ -n "$src" ]] || src="./plugins/$n"
  mf="$REGISTRY/${src#./}/.claude-plugin/plugin.json"
  [[ -f "$mf" ]] || { printf 'NO-MANIFEST'; return; }
  jq -r 'if (.fivedive | type) == "object" and (.fivedive | length) > 0 then "yes" else "no" end' "$mf" 2>/dev/null
}

BUNDLED=()     # every box-installable plugin the registry publishes
OFFICIAL=()    # ...those that follow the standard (named for history: DIVE-4708 split on the tier)
UNREVIEWED=()  # ...and those that do not: the gate MUST refuse these
if [[ -n "$REGISTRY" ]]; then
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    # A BUILT-IN channel plugin (telegram, dashboard, buzz) is installed per
    # AGENT, not per box — `plugin add` refuses it by design (cmd_plugin.sh
    # _plugin_is_builtin_channel). Grading it here would assert the opposite of
    # the product's rule. The registry publishes both kinds; only the
    # box-installable kind is this harness's subject.
    _plugin_is_builtin_channel "$n" && continue
    BUNDLED+=("$n")
    if [[ "$(_reg_standard "$n")" == yes ]]; then OFFICIAL+=("$n"); else UNREVIEWED+=("$n"); fi
  done < <(jq -r '.plugins[].name' "$REGISTRY/.claude-plugin/marketplace.json" 2>/dev/null | sort)
  # Two separate facts. The manifest must declare plugins at all (a checkout
  # pointed at the wrong tree fails HERE, loudly, instead of silently grading an
  # empty loop), and separately there must be a BOX-INSTALLABLE one left after
  # the built-in channels are dropped — if a future registry published nothing
  # but channels, the loops below would be vacuous and must say so, not pass.
  t "T0 the registry manifest declares at least one plugin (else the checkout is not a registry)" \
    "yes" "$([[ $(jq -r '.plugins | length' "$REGISTRY/.claude-plugin/marketplace.json" 2>/dev/null || echo 0) -ge 1 ]] && echo yes || echo no)"
  t "T0b ...and at least one of them is box-installable AND follows the standard, so the corpus loops are not vacuous" \
    "yes" "$([[ ${#OFFICIAL[@]} -ge 1 ]] && echo yes || echo no)"
  t "T0b2 ...and every box-installable plugin landed in exactly one tier bucket" \
    "${#BUNDLED[@]}" "$(( ${#OFFICIAL[@]} + ${#UNREVIEWED[@]} ))"
else
  NOTRUN=1
  printf '\n'
  printf '  !! NOT RUN — no registry checkout, so the CORPUS arms (T0/T1/T2/T5b/T6/T7)\n'
  printf '  !! graded NOTHING in this run. They are not passing; they did not execute.\n'
  printf '  !! Point FIVEDIVE_PLUGIN_REGISTRY at a 5dive-ai/5dive-plugins checkout, or\n'
  printf '  !! clone it beside this repo, to grade them. The fixture arms below did run.\n'
  printf '\n'
fi

# ---- T1: every OFFICIAL bundled plugin INSTALLS -----------------------------
# The row's whole subject. rc 0, from the real cmd_plugin_add, against the real
# manifest — not a file-list comparison. Scoped to the official set by DIVE-4708:
# an unreviewed plugin not installing is the trust gate working, and demanding
# rc 0 from it asserted the opposite of the product's own rule.
_inst=(); _ref=()
for p in "${OFFICIAL[@]}"; do
  run cmd_plugin_add "$p@$RMKT" --yes
  t "T1 'plugin add $p' installs on a stock box" "0" "$RC"
  [[ "$RC" == 0 ]] && _inst+=("$p") || { _ref+=("$p"); printf '   stderr: %s\n' "$ERR"; }
done

# ---- T1b: NEGATIVE CONTROL — an unreviewed bundled plugin is REFUSED --------
# The other half of T0c, asserted end to end with its message. Without this arm
# the fix to T1 above reads as "stop grading the plugins that fail", which is the
# forbidden shape. Vacuous while the registry publishes only official plugins,
# and that is correct: there is nothing to refuse.
for p in "${UNREVIEWED[@]}"; do
  run cmd_plugin_add "$p@$RMKT" --yes
  t  "T1b 'plugin add $p' is REFUSED — it carries no fivedive block" "$E_PERMISSION" "$RC"
  tc "T1b2 ...and the refusal names the standard, not something internal" "does not follow the 5dive plugin standard" "$ERR"
  [[ "$RC" == 0 ]] && _inst+=("$p") || _ref+=("$p")
done

# T1c — THE RELATIONSHIP ARM, and the one that disarms the generator. Not "the
# catalogue installs" (a third repo decides that) but "installing and being
# official are the same set" (this repo decides that). Publishing a plugin moves
# a name between the two buckets; it can no longer move the verdict. It is also
# what stops the T1/T1b split degenerating: "install everything" and "refuse
# everything" are each red here, and a plugin silently dropped from BOTH loops
# shows up as a missing name.
if [[ -n "$REGISTRY" ]]; then
  t "T1c a box-installable plugin installs IFF its own manifest follows the standard" \
    "install=[${OFFICIAL[*]}] refuse=[${UNREVIEWED[*]}]" "install=[${_inst[*]}] refuse=[${_ref[*]}]"
fi

# ---- T2: and it is recorded as installed and enabled ------------------------
# rc 0 is necessary and not sufficient: an installer that returned 0 having
# copied nothing would pass T1. Read the registry the dispatcher reads.
for p in "${OFFICIAL[@]}"; do
  t "T2 $p is recorded in installed.json as enabled" "true" \
    "$(jq -r --arg k "$p@$RMKT" '.[$k].enabled // false' "$(_plugin_installed_json)" 2>/dev/null)"
done

# T2b — the negative half, and it is not symmetry for its own sake: a refusal
# that had already copied the tree would pass T1b on rc alone.
for p in "${UNREVIEWED[@]}"; do
  t "T2b $p left NO record behind — a refused install copies nothing" "false" \
    "$(jq -r --arg k "$p@$RMKT" '.[$k].enabled // false' "$(_plugin_installed_json)" 2>/dev/null)"
done

# ---- T3: NEGATIVE CONTROL — an unknown grant is still refused ---------------
# Without this arm, "add browser-profiles to the enum" and "stop checking grants
# at all" are the same green.
MKT="$TMP/fixture-mkt"; mkdir -p "$MKT/.claude-plugin" "$MKT/badgrant/.claude-plugin"
cat > "$MKT/badgrant/.claude-plugin/plugin.json" <<'JSON'
{"name":"badgrant","version":"1.0.0","description":"fixture","author":{"name":"t"},
 "fivedive":{"contract":"1","capabilities":["channel"],"grants":["root-shell"],
             "trust":{"publisher":"5dive","did":"did:key:t","review":"official"}}}
JSON
jq -n '{name:"fixture", description:"test fixture", owner:{name:"t"},
        plugins:[{name:"badgrant", description:"fixture", category:"test", source:"./badgrant"}]}' \
  > "$MKT/.claude-plugin/marketplace.json"
run _plugin_mkt_add "$MKT" --as=fixture
t "T3pre the fixture marketplace registered (an unregistered one makes T3 grade the wrong refusal)" "0" "$RC"
run cmd_plugin_add badgrant@fixture --yes
t  "T3 an unknown grant is STILL refused (the enum was extended, not disabled)" "$E_VALIDATION" "$RC"
tc "T3b ...and it names the grant it refused" "root-shell" "$ERR"

# ---- T4: every grant in the enum renders in English on the consent screen ---
# This is the guard for the OTHER way DIVE-4126 could have half-shipped: the
# string added to the enum and forgotten in the consent map, so the screen echoes
# our internal noun at a customer instead of describing what they are handing
# over. _plugin_grant_english falls through to "$1", so the test is that the
# rendering DIFFERS from the enum token.
for g in $PLUGIN_GRANTS; do
  t "T4 grant '$g' has a plain-English rendering for the consent screen (§5.2)" \
    "yes" "$([[ "$(_plugin_grant_english "$g")" != "$g" ]] && echo yes || echo no)"
done

# ---- T5: NEGATIVE CONTROL — browser-profiles ENFORCEMENT bites -------------
# A grant nothing enforces is prose. An EXISTING store that is not root-owned
# 0711 must refuse the install, because a store anyone else can read or
# pre-populate hands one seat's logged-in sessions to another.
#
# Fresh STATE_DIR per arm, and each runs in a subshell so the export cannot leak
# into the arms below it.
_add_browser_with_store() {   # <mode> [--as-me]
  local mode="$1" st; st=$(mktemp -d)
  mkdir -p "$st/browser-profiles"; chmod "$mode" "$st/browser-profiles"
  ( export STATE_DIR="$st"; run cmd_plugin_add "browser@$RMKT" --yes; printf '%s\t%s' "$RC" "$ERR" )
  rm -rf "$st"
}
if [[ -z "$REGISTRY" ]]; then
  # T5a/T5b install the REAL browser plugin, so they need the registry corpus.
  # T5c-e below grade the same predicate directly and always run.
  printf '  !! NOT RUN — T5a/T5b (end-to-end refusal) need a registry checkout.\n'
elif [[ "$(id -u)" == 0 ]]; then
  # Running as root the store WOULD be root-owned, so only the mode arm is
  # meaningful; say so rather than asserting something the uid decides.
  printf 'NOTE: running as root — the wrong-owner arm (T5a) is not meaningful here; T5b still is.\n'
else
  res=$(_add_browser_with_store 711)
  t  "T5a a store owned by someone other than root REFUSES the install" "$E_PERMISSION" "${res%%$'\t'*}"
  tc "T5a2 ...and says why in terms of the session, not the mode bits" "sessions" "${res#*$'\t'}"
fi
if [[ -n "$REGISTRY" ]]; then
  res=$(_add_browser_with_store 777)
  t  "T5b a world-writable store REFUSES the install (0711 is traverse, not list)" \
     "$E_PERMISSION" "${res%%$'\t'*}"
fi

# T5c-e grade the PREDICATE directly, with the pairs the filesystem will not hand
# a harness. As an ordinary seat, every store this suite can create is seat-owned,
# so the owner fault fires first and the MODE fault is unreachable end-to-end —
# and a mode check nothing can reach is a mode check that can be deleted green.
# (Measured: mutating `[[ "$mode" == "711" ]]` to true SURVIVED T5a/T5b.)
t  "T5c a root-owned 0711 store is the one shape that passes" \
   "" "$(_plugin_browser_store_fault /x 0 711)"
tc "T5d a root-owned but world-writable store is a fault, named by mode" \
   "mode 777" "$(_plugin_browser_store_fault /x 0 777)"
tc "T5d2 ...and 0755 is a fault too: listable is enough to enumerate seats" \
   "mode 755" "$(_plugin_browser_store_fault /x 0 755)"
tc "T5e a seat-owned store is a fault, named by uid" \
   "uid 1007" "$(_plugin_browser_store_fault /x 1007 711)"

# ---- T6: an ABSENT store is not an error -----------------------------------
# The fresh-box path, and the reason enforcement is not simply "require the
# store". `setup` is a separate root act the install PRINTS; a first install on a
# box that has never run it must succeed. T1 already installed browser against a
# STATE_DIR with no store, so this arm asserts the message the user is left with.
if [[ -n "$REGISTRY" ]]; then
  st6=$(mktemp -d)
  res6=$( export STATE_DIR="$st6"; run cmd_plugin_add "browser@$RMKT" --yes; printf '%s\t%s' "$RC" "$ERR" )
  t  "T6 with NO store on the box the install SUCCEEDS (setup is the user's next step, not a precondition)" \
     "0" "${res6%%$'\t'*}"
  tc "T6b ...and it points at the one root act that creates the store" "5dive browser setup" "${res6#*$'\t'}"
  rm -rf "$st6"
else
  printf '  !! NOT RUN — T6/T6b (absent-store install) need a registry checkout.\n'
fi

# ---- T7: the declared verb DISPATCHES --------------------------------------
# The measured symptom on lodar's box was `5dive browser --help` -> rc 2, i.e.
# unknown command, because the plugin was never installable. Installing is half
# the claim; the other half is that the verb the manifest declares actually runs.
# _plugin_dispatch_verb ends in `exec`, so this runs in run()'s subshell and
# reads the child's exit status.
for p in "${OFFICIAL[@]}"; do
  mf="$REGISTRY/plugins/$p/.claude-plugin/plugin.json"
  [[ -f "$mf" ]] || continue
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    run _plugin_dispatch_verb "$v" --help
    t "T7 '5dive $v' dispatches to the installed $p plugin (rc 1 here = still an unknown command)" "0" "$RC"
  done < <(jq -r '(.fivedive.verbs // []) | map(.name? // empty)[]' "$mf" 2>/dev/null)
done

if (( NOTRUN )); then
  printf 'plugin_bundled_install_unit: %d passed, %d failed, CORPUS ARMS NOT RUN (no registry checkout)\n' "$PASS" "$FAIL"
else
  printf 'plugin_bundled_install_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
fi
[[ "$FAIL" -eq 0 ]]
