#!/usr/bin/env bash
# DIVE-9173 — @openai/codex 0.172.0 was published at 00:09:39Z. The release
# smoke installed codex at ~00:12Z and got "codex install failed (exit 1)"; the
# same install worked at 04:00Z. npm makes a release's main package installable
# before its per-platform package has propagated, so for a few minutes after a
# publish `npm install -g @openai/codex@latest` fails. A customer hiring in that
# window gets the same failure. The codex (and pi) recipe now retries the npm
# step after 60s and again after 180s (npm_install_retry in src/header.sh).
#
# The REAL recipe runs, re-rooted at a sandbox home and handed through the same
# escaping `sudo -u claude -i bash -lc` applies (the method of
# claude_install_npm_fallback_unit.sh). npm is stubbed to fail its first N
# installs; `sleep` is stubbed to record its argument and return at once, so
# the arms take about a second and the waits themselves are graded.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../src/header.sh
source "$ROOT/src/header.sh"

fails=0
ok_()  { echo "ok   $1"; }
bad_() { echo "FAIL $1" >&2; fails=$((fails+1)); }

# The codex recipe before this fix, verbatim: one npm try. The negative control
# shows the sandbox reproduces the defect, so a green R1 is not a rig that
# cannot fail.
PRE_FIX='{ [[ -z "${FORCE_INSTALL:-}" ]] && [[ -x /home/claude/.local/bin/codex ]]; } || { . /home/claude/.nvm/nvm.sh && nvm install 24 >/dev/null && npm install -g @openai/codex@latest && mkdir -p /home/claude/.local/bin && ln -sfn "$(npm prefix -g)/bin/codex" /home/claude/.local/bin/codex && [[ -x /home/claude/.local/bin/codex ]]; }'

# sudo_i <recipe>: the command string sudo -i hands its login shell's -c.
sudo_i() { printf 'bash -c %s' "$(printf '%s' "$1" | sed -z 's/[^A-Za-z0-9_$-]/\\&/g')"; }

# run_recipe <recipe> <bin-name> <npm-failures>
# Prints "rc=<n> installs=<n> sleeps=<args,> bin=<exec|none>".
run_recipe() {
  local recipe="$1" name="$2" nfail="$3"
  local fake; fake=$(mktemp -d) || return 99
  local home="$fake/home/claude" prefix="$fake/nvm-node"
  mkdir -p "$home/.nvm" "$fake/stubs" "$prefix/bin"
  : > "$fake/installs"; : > "$fake/sleeps"
  cat > "$prefix/bin/npm" <<NPM
#!/usr/bin/env bash
case "\$1" in
  prefix) echo $(printf %q "$prefix") ;;
  install)
    echo x >> $(printf %q "$fake/installs")
    if (( \$(wc -l < $(printf %q "$fake/installs")) <= $nfail )); then
      echo "npm error code ETARGET: No matching version found for @openai/codex-linux-x64" >&2; exit 1
    fi
    printf '#!/bin/sh\necho ok\n' > $(printf %q "$prefix/bin/$name"); chmod +x $(printf %q "$prefix/bin/$name") ;;
  *) exit 2 ;;
esac
NPM
  printf '#!/bin/sh\nprintf "%%s," "$1" >> %q\n' "$fake/sleeps" > "$fake/stubs/sleep"
  chmod +x "$prefix/bin/npm" "$fake/stubs/sleep"
  printf 'export PATH=%q:"$PATH"\nnvm() { return 0; }\n' "$prefix/bin" > "$home/.nvm/nvm.sh"
  local rc=0 cmd
  cmd=$(sudo_i "${recipe//\/home\/claude/$home}")
  ( cd "$fake" && unset FORCE_INSTALL && HOME="$home" PATH="$fake/stubs:/usr/bin:/bin" \
      /usr/bin/env bash -c "$cmd" >/dev/null 2>&1 ) || rc=$?
  local bin="none"
  [[ -x "$home/.local/bin/$name" ]] && bin="exec"
  echo "rc=$rc installs=$(wc -l < "$fake/installs") sleeps=$(<"$fake/sleeps") bin=$bin"
  rm -rf "$fake"
}

CODEX="${TYPE_INSTALL[codex]:-}"
PI="${TYPE_INSTALL[pi]:-}"
[[ -n "$CODEX" && -n "$PI" ]] || { bad_ "P0 TYPE_INSTALL[codex] or [pi] is empty"; exit 1; }

got=$(run_recipe "$CODEX" codex 0)
[[ "$got" == "rc=0 installs=1 sleeps= bin=exec" ]] && ok_ "R0 npm works first time: one install, no wait ($got)" \
  || bad_ "R0 npm works first time: want rc=0 installs=1 sleeps= bin=exec, got $got"

got=$(run_recipe "$CODEX" codex 1)
[[ "$got" == "rc=0 installs=2 sleeps=60, bin=exec" ]] && ok_ "R1 npm fails once (publish race), then works: install ok after a 60s wait ($got)" \
  || bad_ "R1 npm fails once then works: want rc=0 installs=2 sleeps=60, bin=exec, got $got"

got=$(run_recipe "$CODEX" codex 2)
[[ "$got" == "rc=0 installs=3 sleeps=60,180, bin=exec" ]] && ok_ "R2 npm fails twice, then works: install ok after 60s + 180s ($got)" \
  || bad_ "R2 npm fails twice then works: want rc=0 installs=3 sleeps=60,180, bin=exec, got $got"

got=$(run_recipe "$CODEX" codex 3)
[[ "$got" == rc=[1-9]*" installs=3 sleeps=60,180, bin=none" ]] && ok_ "R3 npm keeps failing: the install FAILS after 3 tries, no 4th ($got)" \
  || bad_ "R3 npm keeps failing: want rc!=0 installs=3 sleeps=60,180, bin=none, got $got"

got=$(run_recipe "$PI" pi 1)
[[ "$got" == "rc=0 installs=2 sleeps=60, bin=exec" ]] && ok_ "R4 pi rides the same race: fails once, then works ($got)" \
  || bad_ "R4 pi fails once then works: want rc=0 installs=2 sleeps=60, bin=exec, got $got"

got=$(run_recipe "$PRE_FIX" codex 1)
[[ "$got" == rc=[1-9]*" installs=1 sleeps= bin=none" ]] && ok_ "N1 negative control: the pre-fix codex recipe fails on the first npm error ($got)" \
  || bad_ "N1 negative control: want rc!=0 installs=1 sleeps= bin=none, got $got"

# The codex recipe still has exactly one npm step, now wrapped (not a second,
# unretried install somewhere else in the recipe).
n=$(grep -o -F 'npm install -g @openai/codex@latest' <<<"$CODEX" | wc -l)
[[ "$n" == 3 && "$CODEX" == *"$(npm_install_retry @openai/codex@latest)"* ]] \
  && ok_ "S1 codex's npm step is the npm_install_retry fragment (3 tries, one step)" \
  || bad_ "S1 codex recipe should contain the npm_install_retry fragment once (found $n npm installs)"

(( fails == 0 )) && echo "PASS: npm install retry (DIVE-9173)" || echo "FAIL: $fails arm(s)"
(( fails == 0 ))
