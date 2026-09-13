#!/usr/bin/env bash
# DIVE-4456 — the marketplace DIVE-4202 stopped writing is still on every box
# that updated across it, and two sources for one name is exit 5.
#
# WHAT BROKE, measured on poke-two and exact-swallow (both 0.36.0) on 2026-09-13:
#
#     $ sudo 5dive plugin add voice --yes
#     error: 'voice' exists in 2 marketplaces (5dive 5dive-plugins) — name one: voice@5dive
#     rc=5
#
# The documented install line (the voice plugin's README) and the install
# contract's own T1b (`plugin add $p --yes`, bare) are therefore red on the whole
# updated population, while a FRESH docker install stays green — which is exactly
# why every existing harness passes. `_plugin_register_bundled` was deleted in
# DIVE-4202, so nothing WRITES the `5dive` entry any more; deleting a writer does
# not unwrite what it wrote, and nothing was ever taught to retire it.
#
# WHY THIS FILE AND NOT AN ARM IN plugin_bundled_install_unit.sh: every harness in
# this repo builds its store from scratch, which reproduces a NEW box. The defect
# only exists on a store with HISTORY. T0 below therefore seeds the leftover by
# hand — the fixture IS the finding — and every other arm grades what the CLI
# does when it meets one.
#
# THE NEGATIVE CONTROLS ARE THE POINT (T3/T4/T5). Pruning a marketplace is a
# destructive act on a customer's box, so most of this file is the three cases
# where it must NOT happen: something is still installed from it, the registry is
# not there to replace it, or the marketplace is one the user added themselves.
# A green here that came from "prune whenever you see a second marketplace" would
# red T3, T4 and T5.
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

# header.sh:14 is `set -euo pipefail`; sourcing it turns errexit on in THIS shell,
# where a refusal this file exists to grade would take the harness down instead of
# being graded. Same reason, same fix, as plugin_contract_unit.
set +e -o pipefail

require_root() { :; }

TMP="$(mktemp -d)"

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

OUT=""; ERR=""; RC=0
# Deliberately NOT `RC=$(...)`: a helper called inside `$( )` sets its globals in a
# SUBSHELL, so OUT/ERR would come back empty in the parent and every message arm
# would assert against "".
run() {
  local o="$TMP/.o" e="$TMP/.e"
  ( "$@" ) >"$o" 2>"$e"; RC=$?
  OUT=$(cat "$o"); ERR=$(cat "$e")
  return 0
}

# ---- fixtures --------------------------------------------------------------
# Two marketplaces that both offer `voice`, which is the whole shape of the bug.
# The bundled one carries the OLDER copy, as the real one does: on a real box
# `browser@5dive` is 1.0.0 with no `serve`, which is why following the CLI's own
# `name one: voice@5dive` hint is worse than the refusal (DIVE-4347).
mkmkt() {  # mkmkt <dir> <plugin-name> <version>
  local dir="$1" n="$2" v="$3"
  mkdir -p "$dir/.claude-plugin" "$dir/plugins/$n/.claude-plugin"
  jq -cn --arg n "$n" --arg v "$v" \
     '{name:$n, version:$v, description:"fixture", author:{name:"t"},
       fivedive:{contract:"1", capabilities:[], grants:[],
                 trust:{publisher:"t", did:"did:key:t", review:"official"}}}' \
     > "$dir/plugins/$n/.claude-plugin/plugin.json"
  jq -n --arg n "$n" '{name:"fixture", description:"fixture", owner:{name:"t"},
                       plugins:[{name:$n, description:"fixture", category:"test", source:("./plugins/" + $n)}]}' \
     > "$dir/.claude-plugin/marketplace.json"
}
mkmkt "$TMP/registry" voice 1.1.0
mkmkt "$TMP/bundled"  voice 1.0.0
export FIVEDIVE_PLUGIN_REGISTRY="$TMP/registry"

# Seed a store the way a box that updated ACROSS DIVE-4202 carries one: the
# `5dive` entry with the flags the deleted `_plugin_register_bundled` wrote
# (cmd_plugin.sh @fabeb5df^: kind local, bundled true), plus its materialised
# copy under the store. Written by hand because no code in this tree can write
# it any more — which is precisely the situation being graded.
seed() {  # seed <state-dir> [extra-jq-for-marketplaces.json]
  local st="$1" extra="${2:-.}"
  rm -rf "$st"; mkdir -p "$st/plugins/marketplaces"
  cp -a "$TMP/bundled" "$st/plugins/marketplaces/5dive"
  jq -n --arg s "$TMP/bundled" \
     '{"5dive":{source:$s, kind:"local", ref:"", added_at:"2026-09-09T00:00:00Z", bundled:true}}' \
     | jq "$extra" > "$st/plugins/marketplaces.json"
  echo '{}' > "$st/plugins/installed.json"
}
mkts()  { jq -r 'keys | join(",")' "$1/plugins/marketplaces.json"; }

# ---- T0: the leftover store REPRODUCES the customer's refusal ---------------
# Without this arm the rest of the file could pass on a store that never had the
# bug. It calls the resolver directly, with no ensure-store in front of it, so it
# reads the state a 0.36.0 box is in TODAY.
export STATE_DIR="$TMP/s0"
seed "$STATE_DIR"
jq -n --arg s "$TMP/registry" \
   '{"5dive-plugins":{source:$s, kind:"git", ref:"", added_at:"2026-09-10T00:00:00Z", registry:true}}' \
   > "$TMP/.reg"
jq -s '.[0] * .[1]' "$STATE_DIR/plugins/marketplaces.json" "$TMP/.reg" > "$TMP/.m" \
  && mv "$TMP/.m" "$STATE_DIR/plugins/marketplaces.json"
cp -a "$TMP/registry" "$STATE_DIR/plugins/marketplaces/5dive-plugins"
run _plugin_split_ref voice
t  "T0 a store carrying the DIVE-4202 leftover refuses the bare name (the box's state today)" "$E_CONFLICT" "$RC"
tc "T0b ...and names both sources" "exists in 2 marketplaces" "$ERR"

# ---- T1: ensure-store retires it -------------------------------------------
export STATE_DIR="$TMP/s1"
seed "$STATE_DIR"
run _plugin_ensure_store
t "T1 ensure_store rc"                                    "0"             "$RC"
t "T1a the stale bundled entry is gone, the registry remains" \
  "5dive-plugins" "$(mkts "$STATE_DIR")"
t "T1b ...and so is its materialised copy under the store" \
  "absent" "$([[ -d "$STATE_DIR/plugins/marketplaces/5dive" ]] && echo present || echo absent)"
t "T1c the payload OUTSIDE the store is left alone (unregistered is inert; a root rm -rf there is not this fix's trade)" \
  "present" "$([[ -d "$TMP/bundled" ]] && echo present || echo absent)"

# ---- T2: which is the customer-visible claim -------------------------------
run _plugin_split_ref voice
t "T2 the documented bare 'plugin add voice' resolves again" "0" "$RC"
# Called in THIS shell, not through run(): the resolver's answer is a GLOBAL, and
# run() evaluates in a subshell, so `$_PL_MKT` after a run() is always empty. Safe
# here only because it is guarded on T2 having proved it does not `fail` — an
# unguarded call would exit the harness before its summary under a mutant.
_PL_MKT=""; [[ "$RC" == 0 ]] && _plugin_split_ref voice
t "T2a ...to the REGISTRY copy, not the stale one"           "5dive-plugins" "${_PL_MKT:-}"
run cmd_plugin_add voice --yes
t "T2b and the whole verb installs, rc 0 (this is install-contract T1b)" "0" "$RC"
[[ "$RC" == 0 ]] || printf '   stderr: %s\n' "$ERR"
t "T2c ...recording the registry's version, not the bundled 1.0.0" \
  "1.1.0" "$(jq -r '."voice@5dive-plugins".version // "missing"' "$STATE_DIR/plugins/installed.json")"

# ---- T3 (negative control): something is still INSTALLED from it ------------
# `_plugin_mkt_remove` refuses to unregister the source of an installed plugin.
# The same refusal has to apply when WE are the one asking, or an upgrade later
# resolves an origin that is not there.
export STATE_DIR="$TMP/s3"
seed "$STATE_DIR"
jq -n '{"voice@5dive":{plugin:"voice", marketplace:"5dive", version:"1.0.0"}}' \
  > "$STATE_DIR/plugins/installed.json"
run _plugin_ensure_store
t  "T3 a marketplace something is installed from is NOT retired" \
   "5dive,5dive-plugins" "$(mkts "$STATE_DIR")"
t  "T3a ...and its copy is left on disk"  \
   "present" "$([[ -d "$STATE_DIR/plugins/marketplaces/5dive" ]] && echo present || echo absent)"
tc "T3b ...and it SAYS so, naming what is holding it" "voice@5dive" "$ERR"

# ---- T4 (negative control): no registry to replace it -----------------------
# The registry clone is best-effort and never lands on an offline box. Pruning
# there removes the only source a name has, which is not this bug — a box with
# one marketplace resolves fine.
export STATE_DIR="$TMP/s4"
seed "$STATE_DIR"
export FIVEDIVE_PLUGIN_REGISTRY="$TMP/no-such-registry"
run _plugin_ensure_store
t "T4 with the registry unregistered the bundled entry STAYS (it is the only source left)" \
  "5dive" "$(mkts "$STATE_DIR")"
run _plugin_split_ref voice
t "T4a ...and the bare name still resolves there, as it does on an offline box" "0" "$RC"
export FIVEDIVE_PLUGIN_REGISTRY="$TMP/registry"

# ---- T5 (negative control): a marketplace the USER added --------------------
# Retirement keys off the two flags the deleted code wrote. A local marketplace
# someone added by hand carries neither, so it is theirs — and the ambiguity it
# creates is still an ERROR, because that rule is correct and is not what this
# row changes.
export STATE_DIR="$TMP/s5"
seed "$STATE_DIR" 'del(."5dive") + {"mine":{source:"'"$TMP/bundled"'", kind:"local", ref:"", added_at:"2026-09-12T00:00:00Z"}}'
mv "$STATE_DIR/plugins/marketplaces/5dive" "$STATE_DIR/plugins/marketplaces/mine"
run _plugin_ensure_store
t "T5 a user-added local marketplace is untouched" \
  "5dive-plugins,mine" "$(mkts "$STATE_DIR")"
run _plugin_split_ref voice
t  "T5a ...so a name in two marketplaces is still a refusal, not a silent pick" "$E_CONFLICT" "$RC"
tc "T5b ...naming the user's marketplace" "mine" "$ERR"

printf 'plugin_stale_bundled_prune_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
