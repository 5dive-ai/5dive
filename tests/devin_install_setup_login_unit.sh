#!/usr/bin/env bash
# DIVE-7115 — devin's installer ends with `devin setup`, a login prompt. A hire
# has no terminal, so the prompt ends "Error: Login canceled" and the script
# exits 1 after the binary has already landed. The recipe used to pass that
# exit through, so every fresh-box devin install failed (found by the nightly
# harness-smoke on ubuntu 22.04 and 24.04). The recipe's verdict is now the
# binary itself.
#
# The recipe runs verbatim, re-rooted at a sandbox home (the same method as
# type_install_gate_dimension_unit.sh), with curl stubbed to serve an installer
# whose behaviour each arm picks.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../src/header.sh
source "$ROOT/src/header.sh"

# The recipe as it was before this fix: the negative control below shows the
# sandbox reproduces the defect, so a green D1 is not a stub that cannot fail.
PRE_FIX='[[ -x /home/claude/.local/bin/devin ]] || curl -fsSL https://cli.devin.ai/install.sh | bash'

fails=0
ok_()  { echo "ok   $1"; }
bad_() { echo "FAIL $1" >&2; fails=$((fails+1)); }

# run_recipe <recipe> <installer: lands-then-login-fails|fails-without-binary> <binary: present|absent>
# Prints "rc=<n> curl=<0|1>".
run_recipe() {
  local recipe="$1" installer="$2" binary="$3"
  local fake; fake=$(mktemp -d) || return 99
  local home="$fake/home/claude"
  mkdir -p "$home/.local/bin" "$fake/stubs"
  case "$installer" in
    lands-then-login-fails)
      body='mkdir -p "$HOME/.local/bin"; printf "#!/bin/sh\necho 3000.0\n" > "$HOME/.local/bin/devin"; chmod +x "$HOME/.local/bin/devin"; echo "Error: Login canceled" >&2; exit 1' ;;
    fails-without-binary)
      body='echo "download failed" >&2; exit 1' ;;
  esac
  printf '#!/usr/bin/env bash\ntouch %q\ncat <<'"'"'SCRIPT'"'"'\n%s\nSCRIPT\n' "$fake/curl.called" "$body" > "$fake/stubs/curl"
  chmod +x "$fake/stubs/curl"
  if [[ "$binary" == present ]]; then
    printf '#!/bin/sh\necho 3000.0\n' > "$home/.local/bin/devin"; chmod +x "$home/.local/bin/devin"
  fi
  local rc=0
  ( cd "$fake" && HOME="$home" PATH="$fake/stubs:/usr/bin:/bin" \
      /usr/bin/env bash -c "${recipe//\/home\/claude/$home}" >/dev/null 2>&1 ) || rc=$?
  local called=0; [[ -e "$fake/curl.called" ]] && called=1
  rm -rf "$fake"
  echo "rc=$rc curl=$called"
}

RECIPE="${TYPE_INSTALL[devin]:-}"
[[ -n "$RECIPE" ]] || { bad_ "P0 TYPE_INSTALL[devin] is empty"; exit 1; }

got=$(run_recipe "$RECIPE" lands-then-login-fails absent)
[[ "$got" == "rc=0 curl=1" ]] && ok_ "D1 binary lands, the login prompt fails: install succeeds ($got)" \
  || bad_ "D1 binary lands, the login prompt fails: want rc=0 curl=1, got $got"

got=$(run_recipe "$RECIPE" fails-without-binary absent)
[[ "$got" == "rc=1 curl=1" ]] && ok_ "D2 installer fails and no binary: install fails ($got)" \
  || bad_ "D2 installer fails and no binary: want rc=1 curl=1, got $got"

got=$(run_recipe "$RECIPE" fails-without-binary present)
[[ "$got" == "rc=0 curl=0" ]] && ok_ "D3 binary already there: nothing is downloaded ($got)" \
  || bad_ "D3 binary already there: want rc=0 curl=0, got $got"

got=$(run_recipe "$PRE_FIX" lands-then-login-fails absent)
[[ "$got" == "rc=1 curl=1" ]] && ok_ "N1 negative control: the pre-fix recipe fails D1 ($got)" \
  || bad_ "N1 negative control: the pre-fix recipe should fail D1 with rc=1, got $got"

echo "$fails arm(s) failed"
exit $(( fails > 0 ))
