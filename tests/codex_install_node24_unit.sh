#!/usr/bin/env bash
set -euo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../src/header.sh
source "$ROOT/src/header.sh"

recipe="${TYPE_INSTALL[codex]}"

[[ "$recipe" == *"nvm install 24"* ]] || {
  echo "FAIL: codex installer must provision Node 24 before installing Codex" >&2
  exit 1
}
[[ "$recipe" != *"nvm use 24"* ]] || {
  echo "FAIL: nvm use cannot provision Node 24 on a fresh host" >&2
  exit 1
}

nvm_pos="${recipe%%nvm install 24*}"
npm_pos="${recipe%%npm install -g @openai/codex@latest*}"
(( ${#nvm_pos} < ${#npm_pos} )) || {
  echo "FAIL: Node 24 must be installed before the Codex npm package" >&2
  exit 1
}

echo "PASS: codex install recipe provisions Node 24 before Codex"

# ---------------------------------------------------------------------------
# DIVE-2596 — LOCATOR. Folded in here rather than shipped as a 218th harness
# file: the core tier is over its 300s cap, and the budget guard's first
# preference is to merge by subject. Same subject (the codex install recipe),
# same `source src/header.sh`, no assertion dropped.
#
# Provisioning the right node is only half the recipe. The other half is
# locating the binary it just installed, and the recipe got that wrong: it
# aimed the ~/.local/bin/codex symlink at `dirname $(nvm which 24)` — which
# node nvm SELECTED — while npm installed codex under the node that was
# RUNNING npm. Those diverge whenever ~/.local/bin holds a stale `node`
# symlink (the openclaw recipe plants one), because ~/.local/bin precedes
# nvm's bin dir on PATH and npm is a `#!/usr/bin/env node` script. The link
# then dangles, the recipe still exits 0, and create aborts with "install
# reported success but bin still missing" on a box where codex works.
# ---------------------------------------------------------------------------

ln_stmt='ln -sfn "$(npm prefix -g)/bin/codex" /home/claude/.local/bin/codex'
assert_tail=' && [[ -x /home/claude/.local/bin/codex ]]; }'

# The shipping locator asks the npm that performed the install.
[[ "$recipe" == *"$ln_stmt"* ]] || {
  echo "FAIL: codex symlink must target \$(npm prefix -g)/bin/codex — the npm that installed it" >&2
  exit 1
}
# The pre-fix locator must be GONE, not merely unused: a string survives dead code.
[[ "$recipe" != *'dirname "$(nvm which 24)"'* ]] || {
  echo "FAIL: codex symlink still derived from 'nvm which 24' (DIVE-2596)" >&2
  exit 1
}
# A dangling link must fail the recipe instead of being reported as success.
#
# DIVE-2596 iteration 1 shipped this arm as a bare `*'&& [[ -x …codex ]]'*`
# substring test and it graded NOTHING: the recipe opens with
# `{ [[ -z "${FORCE_INSTALL:-}" ]] && [[ -x /home/claude/.local/bin/codex ]]; }`
# — the FORCE_INSTALL short-circuit — which contains that substring verbatim.
# The pattern was therefore satisfied by the PRE-FIX recipe, and deleting the
# real trailing assert left the harness green. An unanchored substring arm
# cannot distinguish two identical substrings in one string; anchor it by
# POSITION and by COUNT.
[[ "$recipe" == *"$ln_stmt$assert_tail" ]] || {
  echo "FAIL: recipe must END with the symlink followed by '$assert_tail' — assert the link resolves before reporting success" >&2
  exit 1
}
# Second, independent anchor: the -x test must appear TWICE (short-circuit +
# trailing assert). Counted off the raw string, not a deduped view.
n_asserts="$(grep -o -F -- '[[ -x /home/claude/.local/bin/codex ]]' <<<"$recipe" | wc -l)"
(( n_asserts == 2 )) || {
  echo "FAIL: expected 2 occurrences of the -x test (FORCE_INSTALL short-circuit + trailing assert), found $n_asserts" >&2
  exit 1
}
# The -x short-circuit stays FIRST. `nvm install 24` resolves 24 against the
# REMOTE and downloads a brand-new v24 whenever upstream cuts one (measured:
# it pulled v24.19.0 onto a host that had v24.18.1), so an already-installed
# codex must not drag a node download onto every create.
[[ "${recipe#"${recipe%%[![:space:]]*}"}" == '{ [[ -z "${FORCE_INSTALL:-}" ]] && [[ -x /home/claude/.local/bin/codex ]]; } ||'* ]] || {
  echo "FAIL: the -x short-circuit must precede the nvm/npm work" >&2
  exit 1
}
echo "PASS: codex locator targets the installing npm's prefix and asserts it resolves"

# --- behavioural arm --------------------------------------------------------
# Static assertions cannot tell a working locator from a broken one. Run the
# REAL recipe under a rig where the two locators disagree, and run the PRE-FIX
# locator through the SAME rig as a red anchor — a green here with no red
# anchor would also pass on a rig that cannot fail.
#
# The recipe hardcodes /home/claude/.nvm and /home/claude/.local/bin, so the rig
# needs a mount namespace. Where that is not permitted, SKIP LOUDLY: a silent
# skip reads as coverage this harness did not provide.
if unshare -m --map-root-user true 2>/dev/null; then
  UNSHARE=(unshare -m --map-root-user)
elif sudo -n unshare -m true 2>/dev/null; then
  UNSHARE=(sudo -n unshare -m)
else
  echo "SKIP: codex locator behavioural arm (no usable 'unshare -m'; static arms only)" >&2
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The PRE-FIX locator, verbatim from before DIVE-2596, so the red anchor grades
# the shape that actually shipped rather than a paraphrase of it.
old_recipe='{ [[ -z "${FORCE_INSTALL:-}" ]] && [[ -x /home/claude/.local/bin/codex ]]; } || { . /home/claude/.nvm/nvm.sh && nvm install 24 >/dev/null && npm install -g @openai/codex@latest && mkdir -p /home/claude/.local/bin && ln -sfn "$(dirname "$(nvm which 24)")/codex" /home/claude/.local/bin/codex; }'

# Rig: fake nvm SELECTS one prefix; fake npm reports and installs into ANOTHER.
# Reproduces the measured divergence (nvm which 24 -> v24.19.0, npm prefix -g ->
# v24.18.0) without needing two real node builds.
#
# `lands=no` is the second rig: npm reports the SAME prefix and exits 0 having
# put no codex under it. The locator is then correct and the link still
# dangles — which is the shape the trailing -x assert exists to catch, and the
# only rig on which a no-assert recipe is distinguishable from the shipping one
# (with a correct locator and a real install, both always resolve).
build_rig() {
  local root="$1" lands="${2:-yes}" install_body
  if [[ "$lands" == yes ]]; then
    install_body="printf '#!/bin/sh\necho codex\n' > \"$root/prefix/bin/codex\"; chmod +x \"$root/prefix/bin/codex\""
  else
    install_body=":"
  fi
  rm -rf "$root"; mkdir -p "$root"/{nvm,localbin,selected/bin,prefix/bin,path}
  cat >"$root/nvm/nvm.sh" <<RIG
nvm() {
  case "\$1 \$2" in
    "which 24") echo "$root/selected/bin/node" ;;
    *) return 0 ;;
  esac
}
RIG
  cat >"$root/path/npm" <<RIG
#!/usr/bin/env bash
case "\$1 \$2" in
  "prefix -g") echo "$root/prefix" ;;
  "install -g") $install_body ;;
esac
RIG
  chmod +x "$root/path/npm"
  # The SELECTED prefix has a node but no codex — that is the whole point.
  printf '#!/bin/sh\necho node\n' >"$root/selected/bin/node"
  chmod +x "$root/selected/bin/node"
}

# Runs one recipe in a namespace with the rig bound over the hardcoded paths.
run_recipe() {
  local root="$1" script="$2"
  printf '%s\n' "$script" >"$root/recipe.sh"
  cat >"$root/drive.sh" <<RIG
set -u
mount --bind "$root/nvm" /home/claude/.nvm
mount --bind "$root/localbin" /home/claude/.local/bin
export PATH="$root/path:/usr/bin:/bin"
bash "$root/recipe.sh" >/dev/null 2>&1; rc=\$?
link=/home/claude/.local/bin/codex
if [[ ! -L \$link && ! -e \$link ]]; then echo "VERDICT=absent rc=\$rc"
elif [[ -x \$link ]]; then echo "VERDICT=ok rc=\$rc"
else echo "VERDICT=dangling rc=\$rc"; fi
RIG
  "${UNSHARE[@]}" bash "$root/drive.sh"
}

build_rig "$TMP/red";   red="$(run_recipe "$TMP/red" "$old_recipe")"
build_rig "$TMP/green"; green="$(run_recipe "$TMP/green" "$recipe")"
echo "  PRE-FIX  recipe -> $red"
echo "  SHIPPING recipe -> $green"

# Red anchor: the rig must reproduce the bug, or the green below is vacuous.
[[ "$red" == VERDICT=dangling* ]] || {
  echo "FAIL: rig did not reproduce the dangling link on the PRE-FIX recipe ($red); the green verdict would be vacuous" >&2
  exit 1
}
# ...and it reported SUCCESS while dangling. That is the half the -x assert
# fixes, and it is why the downstream error described the wrong object.
[[ "$red" == *"rc=0"* ]] || {
  echo "FAIL: expected the PRE-FIX recipe to exit 0 despite the dangling link ($red)" >&2
  exit 1
}
[[ "$green" == VERDICT=ok* ]] || {
  echo "FAIL: shipping recipe did not produce a resolvable ~/.local/bin/codex ($green)" >&2
  exit 1
}
echo "PASS: pre-fix locator dangles at rc=0; shipping locator resolves"

# --- assert-half arm: the -x assert graded by its EFFECT, not its presence ---
# The two arms above cover the LOCATOR half. Neither covers the trailing -x
# assert behaviourally: on the rig above the shipping locator always resolves,
# so a recipe with the assert and a recipe without it produce the same verdict.
# Grade it on the rig where the locator is RIGHT and the binary is still absent
# from the prefix — then the assert is the only thing standing between rc=0 and
# an honest failure.
#
# The mutant is DERIVED from the shipping recipe by removing exactly the assert,
# never hand-written: a hand-written twin grades a string this repo does not
# ship. The round-trip check below proves the removal is the only difference.
noassert_recipe="${recipe%"$assert_tail"}; }"
[[ "${noassert_recipe%'; }'}$assert_tail" == "$recipe" ]] || {
  echo "FAIL: could not derive the no-assert twin by removing exactly '$assert_tail'; the differential below would grade the wrong mutation" >&2
  exit 1
}

build_rig "$TMP/ship_noland" no; ship_noland="$(run_recipe "$TMP/ship_noland" "$recipe")"
build_rig "$TMP/mut_noland"  no; mut_noland="$(run_recipe "$TMP/mut_noland" "$noassert_recipe")"
echo "  SHIPPING  recipe, npm lands nothing -> $ship_noland"
echo "  NO-ASSERT twin,   npm lands nothing -> $mut_noland"

# Liveness: without the assert the recipe reports SUCCESS on a dangling link —
# verbatim the "install reported success but bin still missing" shape this
# ticket is about. If this is not rc=0 the rig is not exercising the assert and
# the shipping verdict below is vacuous.
[[ "$mut_noland" == "VERDICT=dangling rc=0" ]] || {
  echo "FAIL: no-assert twin did not exit 0 on a dangling link ($mut_noland); this arm is not grading the -x assert" >&2
  exit 1
}
# The differential: same rig, same locator, assert present -> non-zero rc.
[[ "$ship_noland" == VERDICT=dangling* && "$ship_noland" != *"rc=0"* ]] || {
  echo "FAIL: shipping recipe reported success on a dangling link ($ship_noland); the trailing -x assert is not doing its job" >&2
  exit 1
}
echo "PASS: -x assert turns a dangling link into a non-zero rc (no-assert twin: rc=0)"
