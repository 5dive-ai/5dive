#!/usr/bin/env bash
# DIVE-8669 — Anthropic's binary CDN (downloads.claude.ai) answered 403 to a
# box's IPv4 while claude.ai/install.sh still answered. The native installer left
# no /home/claude/.local/bin/claude, so every hire on that box died with "claude
# install reported success but … still missing", Retry after Retry. npm reached
# the same build from the same box. The claude recipe now falls back to npm and
# links the npm binary to ~/.local/bin/claude, the one path agent-start and the
# hire check read.
#
# The recipe runs verbatim, re-rooted at a sandbox home (the method of
# devin_install_setup_login_unit.sh). curl is stubbed to fail like the 403
# (curl -f exits 22 and pipes nothing, so `| bash` reports 0), and nvm.sh + npm
# are stubbed so each arm picks whether npm can install.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../src/header.sh
source "$ROOT/src/header.sh"

# The recipe before this fix: the negative control shows the sandbox reproduces
# the defect (rc 0, no binary), so a green F1 is not a stub that cannot fail.
PRE_FIX='[[ -x /home/claude/.local/bin/claude ]] || curl -fsSL https://claude.ai/install.sh | bash'

fails=0
ok_()  { echo "ok   $1"; }
bad_() { echo "FAIL $1" >&2; fails=$((fails+1)); }

# run_recipe <recipe> <native: 403|works> <npm: works|fails> <binary: present|absent>
# Prints "rc=<n> curl=<0|1> npm=<0|1> bin=<exec|none>".
run_recipe() {
  local recipe="$1" native="$2" npm="$3" binary="$4"
  local fake; fake=$(mktemp -d) || return 99
  local home="$fake/home/claude" prefix="$fake/nvm-node"
  mkdir -p "$home/.nvm" "$fake/stubs" "$prefix/bin"
  case "$native" in
    403)
      printf '#!/usr/bin/env bash\ntouch %q\necho "curl: (22) The requested URL returned error: 403" >&2\nexit 22\n' \
        "$fake/curl.called" > "$fake/stubs/curl" ;;
    works)
      printf '#!/usr/bin/env bash\ntouch %q\ncat <<'"'"'SCRIPT'"'"'\nmkdir -p "$HOME/.local/bin"; printf "#!/bin/sh\\necho 2.1.327\\n" > "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"\nSCRIPT\n' \
        "$fake/curl.called" > "$fake/stubs/curl" ;;
  esac
  chmod +x "$fake/stubs/curl"
  # npm, as nvm puts it on PATH: `prefix -g` names its prefix, `install -g`
  # drops the package's native binary under <prefix>/bin (or fails).
  local npm_install
  case "$npm" in
    works) npm_install="printf '#!/bin/sh\\necho 2.1.327\\n' > $(printf %q "$prefix/bin/claude"); chmod +x $(printf %q "$prefix/bin/claude")" ;;
    fails) npm_install='echo "npm ERR! network" >&2; exit 1' ;;
  esac
  cat > "$prefix/bin/npm" <<NPM
#!/usr/bin/env bash
touch $(printf %q "$fake/npm.called")
case "\$1" in
  prefix) echo $(printf %q "$prefix") ;;
  install) $npm_install ;;
  *) exit 2 ;;
esac
NPM
  chmod +x "$prefix/bin/npm"
  printf 'export PATH=%q:"$PATH"\nnvm() { return 0; }\n' "$prefix/bin" > "$home/.nvm/nvm.sh"
  if [[ "$binary" == present ]]; then
    mkdir -p "$home/.local/bin"
    printf '#!/bin/sh\necho 2.1.300\n' > "$home/.local/bin/claude"; chmod +x "$home/.local/bin/claude"
  fi
  local rc=0
  ( cd "$fake" && HOME="$home" PATH="$fake/stubs:/usr/bin:/bin" \
      /usr/bin/env bash -c "${recipe//\/home\/claude/$home}" >/dev/null 2>&1 ) || rc=$?
  local called=0 npmc=0 bin=none
  [[ -e "$fake/curl.called" ]] && called=1
  [[ -e "$fake/npm.called" ]] && npmc=1
  [[ -x "$home/.local/bin/claude" ]] && bin=exec
  rm -rf "$fake"
  echo "rc=$rc curl=$called npm=$npmc bin=$bin"
}

RECIPE="${TYPE_INSTALL[claude]:-}"
[[ -n "$RECIPE" ]] || { bad_ "P0 TYPE_INSTALL[claude] is empty"; exit 1; }

got=$(run_recipe "$RECIPE" 403 works absent)
[[ "$got" == "rc=0 curl=1 npm=1 bin=exec" ]] && ok_ "F1 native 403, npm works: ~/.local/bin/claude is executable ($got)" \
  || bad_ "F1 native 403, npm works: want rc=0 curl=1 npm=1 bin=exec, got $got"

got=$(run_recipe "$RECIPE" 403 fails absent)
[[ "$got" == rc=[1-9]*" curl=1 npm=1 bin=none" ]] && ok_ "F2 native 403, npm fails too: the install FAILS, not 'success' ($got)" \
  || bad_ "F2 native 403, npm fails: want rc!=0 curl=1 npm=1 bin=none, got $got"

got=$(run_recipe "$RECIPE" works works absent)
[[ "$got" == "rc=0 curl=1 npm=0 bin=exec" ]] && ok_ "F3 native works: npm is never touched ($got)" \
  || bad_ "F3 native works: want rc=0 curl=1 npm=0 bin=exec, got $got"

got=$(run_recipe "$RECIPE" 403 fails present)
[[ "$got" == "rc=0 curl=0 npm=0 bin=exec" ]] && ok_ "F4 claude already there: nothing downloads, nothing replaces it ($got)" \
  || bad_ "F4 claude already there: want rc=0 curl=0 npm=0 bin=exec, got $got"

# Mutant: the fallback removed from the shipping recipe -> F1 must go red.
MUTANT="${RECIPE//"$CLAUDE_NPM_FALLBACK"/false}"
[[ "$MUTANT" != "$RECIPE" ]] || bad_ "M0 could not build the mutant (fallback not found in the recipe)"
got=$(run_recipe "$MUTANT" 403 works absent)
[[ "$got" == rc=[1-9]*" bin=none" ]] && ok_ "M1 mutant (fallback removed) fails F1 ($got)" \
  || bad_ "M1 mutant (fallback removed) should leave no binary, got $got"

got=$(run_recipe "$PRE_FIX" 403 works absent)
[[ "$got" == "rc=0 curl=1 npm=0 bin=none" ]] && ok_ "N1 negative control: the pre-fix recipe says success and leaves no binary ($got)" \
  || bad_ "N1 negative control: want rc=0 curl=1 npm=0 bin=none, got $got"

echo "$fails arm(s) failed"
exit $(( fails > 0 ))
