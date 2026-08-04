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
n_asserts="$(grep -o -F -- '[[ -x /home/claude/.local/bin/codex ]]' <<<"$recipe" | wc -l)" || n_asserts=0
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
# ITERATION 3 — why this arm is built the way it is. Iteration 2 bind-mounted
# the rig straight onto /home/claude/.nvm and /home/claude/.local/bin. Those
# are the right ADDRESSES (they are what the recipe reads) but they exist only
# on a 5dive host. On a GitHub runner home is /home/runner, both mounts failed
# with "mount point does not exist", and because the driver ran `set -u` with
# no `-e` the failures went to stderr and the recipe was graded in an UNRIGGED
# namespace: both arms returned `VERDICT=absent rc=1`, a string shaped exactly
# like a measurement. Two independent holes, two independent repairs:
#
#  1. The rig SYNTHESISES /home/claude inside the namespace (tmpfs over /home,
#     then mkdir) rather than borrowing the host's. Deriving the mount point
#     from $HOME — the obvious fix — does NOT work here: the literal string
#     /home/claude is hardcoded in the RECIPE UNDER TEST, so a rig mounted at
#     /home/runner would be just as unrigged, only quieter. The path has to be
#     CREATED, not relocated. Doing it unconditionally is also what kills the
#     host-dependence that hid the CI failure from every local run: this host
#     has /home/claude, so borrowing it passed here and only here. Everything
#     below is namespace-local — unshare(1) defaults to private propagation —
#     and on a host that DOES have /home/claude it is shadowed, never touched.
#
#  2. The driver REFUSES rather than emitting a verdict when any rig step
#     fails, and the environment guard now grades THE RIG IT NEEDS (build one,
#     check it reports RIGOK) instead of the proxy question "is unshare
#     permitted". On a runner unshare IS permitted, which is exactly why the
#     old guard let the run through to an unrigged measurement.
#
# Where the rig genuinely cannot be built, SKIP LOUDLY with the named reason
# from each candidate: a silent skip reads as coverage this harness did not
# provide, and an unnamed one cannot be told from a rig that is merely broken.

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
  # Witness file. `mount --bind` reporting success is not the same claim as the
  # rig being VISIBLE at the path the recipe reads; the driver checks for this
  # mark on the far side of the bind rather than trusting mount's exit status.
  : >"$root/localbin/.rigmark"
}

# Everything that must run INSIDE the namespace before a recipe can be graded.
# Emitted from ONE function so the preflight and every measurement drive the
# same mechanism — a preflight that exercised a different code path would be
# back to grading a proxy.
rig_preamble() {
  printf 'set -u\nexport PATH=/usr/sbin:/usr/bin:/sbin:/bin\n'
  printf 'RIG_ROOT=%q\n' "$1"
  cat <<'RIG'
fail() { echo "RIGFAIL=$1"; exit 3; }
# Build the recipe's hardcoded home, do not borrow the host's.
mount -t tmpfs tmpfs /home                                || fail "tmpfs-over-home"
[[ ! -e /home/claude ]]                                   || fail "tmpfs-did-not-shadow-home"
mkdir -p /home/claude/.nvm /home/claude/.local/bin        || fail "mkdir-bind-targets"
mount --bind "$RIG_ROOT/nvm" /home/claude/.nvm            || fail "bind-nvm"
mount --bind "$RIG_ROOT/localbin" /home/claude/.local/bin || fail "bind-localbin"
export PATH="$RIG_ROOT/path:/usr/bin:/bin"
# Witnesses, read through the paths the recipe will use.
[[ -r /home/claude/.nvm/nvm.sh ]]                         || fail "nvm-not-visible"
[[ -e /home/claude/.local/bin/.rigmark ]]                 || fail "localbin-not-visible"
[[ "$(command -v npm)" == "$RIG_ROOT/path/npm" ]]         || fail "npm-not-rigged"
RIG
}

# The measurement itself. Separate from the preamble so a rig failure can never
# reach it: `fail` exits 3 before this line is ever read.
drive_tail='bash "$RIG_ROOT/recipe.sh" >/dev/null 2>&1; rc=$?
link=/home/claude/.local/bin/codex
if [[ ! -L $link && ! -e $link ]]; then echo "VERDICT=absent rc=$rc"
elif [[ -x $link ]]; then echo "VERDICT=ok rc=$rc"
else echo "VERDICT=dangling rc=$rc"; fi'

# Runs one recipe in a namespace with the rig bound over the recipe's hardcoded
# paths. REFUSES — loudly, and without printing anything verdict-shaped — if the
# namespace it got back was not actually rigged.
run_recipe() {
  local root="$1" script="$2" out
  printf '%s\n' "$script" >"$root/recipe.sh"
  { rig_preamble "$root"; printf '%s\n' "$drive_tail"; } >"$root/drive.sh"
  out="$("${UNSHARE[@]}" bash "$root/drive.sh" 2>"$root/drive.err")" || true
  [[ "$out" =~ ^VERDICT=(ok|dangling|absent)\ rc=[0-9]+$ ]] || {
    echo "FAIL: the rig did not build under '${UNSHARE[*]}' — refusing to emit a verdict from an unrigged namespace" >&2
    echo "      driver stdout: [${out:-<empty>}]" >&2
    echo "      driver stderr: [$(tr '\n' ' ' <"$root/drive.err")]" >&2
    exit 1
  }
  printf '%s\n' "$out"
}

# Environment guard: pick the first launcher under which a rig ACTUALLY BUILDS.
# Not "is unshare permitted" — that question is answered YES on a GitHub runner,
# where the rig then failed to build anyway.
rig_reasons=()
for cand in "unshare -m --map-root-user" "sudo -n unshare -m"; do
  read -r -a UNSHARE <<<"$cand"
  build_rig "$TMP/preflight"
  { rig_preamble "$TMP/preflight"; printf 'echo RIGOK\n'; } >"$TMP/preflight/drive.sh"
  pf="$("${UNSHARE[@]}" bash "$TMP/preflight/drive.sh" 2>&1)" || true
  [[ "$pf" == *RIGOK ]] && break
  rig_reasons+=("$cand -> ${pf:-<no output>}")
  UNSHARE=()
done
if (( ${#UNSHARE[@]} == 0 )); then
  echo "SKIP: codex locator behavioural arm — no launcher could build the mount-namespace rig; static arms only" >&2
  printf '  tried: %s\n' "${rig_reasons[@]}" >&2
  exit 0
fi

# --- rig-integrity arm ------------------------------------------------------
# The refusal above is the only thing standing between a broken rig and a
# verdict-shaped string, and iteration 2 proved that gap is not hypothetical.
# Grade the refusal by BREAKING a rig on purpose: remove the bind source, so the
# driver hits `fail bind-nvm` exactly where the runner hit "mount point does not
# exist". The driver must refuse, name the reason, and emit no VERDICT at all.
integrity_root="$TMP/rigfail"; build_rig "$integrity_root"; rm -rf "$integrity_root/nvm"
if rigfail_out="$(run_recipe "$integrity_root" "$recipe" 2>&1)"; then
  echo "FAIL: driver emitted a verdict from a rig that did not build ($rigfail_out)" >&2
  exit 1
fi
[[ "$rigfail_out" == *"refusing to emit a verdict from an unrigged namespace"* ]] || {
  echo "FAIL: driver failed on a broken rig but did not name it as a rig failure ($rigfail_out)" >&2
  exit 1
}
[[ "$rigfail_out" == *"RIGFAIL=bind-nvm"* ]] || {
  echo "FAIL: expected the driver to stop at the failed bind; got ($rigfail_out)" >&2
  exit 1
}
[[ "$rigfail_out" != *"VERDICT="* ]] || {
  echo "FAIL: the refusal still leaked a verdict-shaped string ($rigfail_out)" >&2
  exit 1
}
echo "PASS: driver refuses, names the failed rig step, and emits no VERDICT when the rig does not build"

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
