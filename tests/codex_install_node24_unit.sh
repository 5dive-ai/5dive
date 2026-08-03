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

# The shipping locator asks the npm that performed the install.
[[ "$recipe" == *'ln -sfn "$(npm prefix -g)/bin/codex" /home/claude/.local/bin/codex'* ]] || {
  echo "FAIL: codex symlink must target \$(npm prefix -g)/bin/codex — the npm that installed it" >&2
  exit 1
}
# The pre-fix locator must be GONE, not merely unused: a string survives dead code.
[[ "$recipe" != *'dirname "$(nvm which 24)"'* ]] || {
  echo "FAIL: codex symlink still derived from 'nvm which 24' (DIVE-2596)" >&2
  exit 1
}
# A dangling link must fail the recipe instead of being reported as success.
[[ "$recipe" == *'&& [[ -x /home/claude/.local/bin/codex ]]'* ]] || {
  echo "FAIL: recipe must assert the symlink resolves before reporting success" >&2
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
build_rig() {
  local root="$1"
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
  "install -g") printf '#!/bin/sh\necho codex\n' > "$root/prefix/bin/codex"
                chmod +x "$root/prefix/bin/codex" ;;
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
