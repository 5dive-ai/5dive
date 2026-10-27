#!/usr/bin/env bash
# DIVE-7103 — `agent install hermes` on a box without libatomic1.
#
# hermes' upstream installer fetches a glibc Node that links libatomic.so.1,
# which a plain Ubuntu 24.04 cloud image does not carry. From our
# non-interactive `sudo -u claude` hop the installer cannot install it, exits
# "pm install failed", and cmd_install used to ignore that exit and report
# "install reported success but .../hermes still missing", never naming the
# package (lodar's 2026-10-27 self-host QA, gap 12). The arms pin:
#   - a missing libatomic.so.1 is installed with apt BEFORE the recipe runs;
#   - empty package lists get one `apt-get update` and a retry;
#   - when apt cannot install it, the install stops naming libatomic1 and the
#     recipe never runs;
#   - a present library and a type that does not need it touch apt not at all;
#   - a recipe that exits non-zero is reported as failed, not as a success;
#   - the presence probe survives SIGPIPE under pipefail on a long ldconfig.
# ldconfig, apt-get and sudo are PATH stubs; nothing is installed for real.
#
# Run: bash tests/hermes_libatomic_install_unit.sh (no root, no network, ~12s: arm 7 waits out cmd_install's 10s bin grace)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# shellcheck disable=SC2154  # rc is assigned inside the trap string
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"

PASS=0; FAIL=0
check() { # check <label> <condition-rc> [detail]
  if [[ "$2" -eq 0 ]]; then PASS=$((PASS+1)); echo "ok   $1"
  else FAIL=$((FAIL+1)); echo "FAIL $1${3:+ — $3}" >&2; fi
}

mkdir -p "$TMP/stubs"
# ldconfig -p: lists libatomic.so.1 once the "package" marker exists.
# LDCONFIG_LONG=1 prints it FIRST and then ~1.5MB more, so a `grep -q` reader
# exits early and the writer dies of SIGPIPE.
cat >"$TMP/stubs/ldconfig" <<STUB
#!/usr/bin/env bash
if [[ -f "$TMP/has-libatomic" ]]; then
  echo "	libatomic.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libatomic.so.1"
fi
if [[ "\${LDCONFIG_LONG:-}" == 1 ]]; then
  for ((i = 0; i < 20000; i++)); do echo "	libfiller\$i.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libfiller\$i.so.1"; done
fi
echo "	libc.so.6 (libc6,x86-64) => /lib/x86_64-linux-gnu/libc.so.6"
STUB
# apt-get: APT_MODE ok | needs-update | broken.
cat >"$TMP/stubs/apt-get" <<STUB
#!/usr/bin/env bash
echo "apt-get \$*" >>"$TMP/calls"
case "\$*" in
  *" update"*) touch "$TMP/lists-fresh"; exit 0 ;;
esac
case "\${APT_MODE:-ok}" in
  ok) touch "$TMP/has-libatomic"; exit 0 ;;
  needs-update) [[ -f "$TMP/lists-fresh" ]] || { echo "E: Unable to locate package libatomic1" >&2; exit 100; }
                touch "$TMP/has-libatomic"; exit 0 ;;
  *) echo "E: Unable to locate package libatomic1" >&2; exit 100 ;;
esac
STUB
# sudo: the recipe hop (bash -lc). RECIPE_MODE ok lands the binary; fail plays
# upstream's "pm install failed" exit 1 with nothing landed, and so does a
# hermes recipe run while libatomic.so.1 is still missing.
cat >"$TMP/stubs/sudo" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == -lc ]]; then
    echo "recipe" >>"$TMP/calls"
    if [[ "\${RECIPE_MODE:-ok}" == fail ]]; then echo "✗ pm install failed" >&2; exit 1; fi
    # Upstream's Node needs libatomic.so.1: without it hermes fails the same way.
    if [[ "\$*" == *hermes* && ! -f "$TMP/has-libatomic" ]]; then echo "✗ pm install failed" >&2; exit 1; fi
    mkdir -p "$TMP/bin"; printf '#!/bin/sh\n' >"$TMP/bin/hermes"; chmod +x "$TMP/bin/hermes"; exit 0
  fi
done
exit 0
STUB
chmod +x "$TMP/stubs/"*

# install <type> — run cmd_install in a subshell (fail exits); sets ALL RC.
install() {
  ALL=$(
    export PATH="$TMP/stubs:$PATH"
    # shellcheck disable=SC1091
    source "$ROOT/src/header.sh"
    # shellcheck disable=SC1091
    source "$ROOT/src/lib/error_codes.sh"
    # shellcheck disable=SC1091
    source "$ROOT/src/lib/output.sh"
    # shellcheck disable=SC1091
    source "$ROOT/src/lib/validation.sh"
    # shellcheck disable=SC1091
    source "$ROOT/src/cmd_auth.sh"
    # env_isolation's sudo guard refuses REAL sudo; here sudo is the stub.
    [[ "$(type -P sudo)" == "$TMP/stubs/sudo" ]] && unset -f sudo
    set +e
    # shellcheck disable=SC2034,SC2154  # read by the sourced cmd_install
    JSON_MODE=1 TYPE_BIN[hermes]="$TMP/bin/hermes" TYPE_BIN[codex]="$TMP/bin/codex"
    cmd_install "$@" 2>&1
  ) && RC=0 || RC=$?
}
calls() { cat "$TMP/calls" 2>/dev/null; }
reset() { rm -rf "${TMP:?}/bin" "$TMP/calls" "$TMP/has-libatomic" "$TMP/lists-fresh"; unset APT_MODE RECIPE_MODE LDCONFIG_LONG; }

# --- 1. missing libatomic: installed with apt, before the recipe ------------
reset
install hermes
check "missing: hermes install exits 0" "$([[ $RC -eq 0 ]]; echo $?)" "rc=$RC out=$ALL"
check "missing: apt-get installs libatomic1" "$(calls | grep -q '^apt-get .*install .*libatomic1'; echo $?)" "$(calls)"
check "missing: apt runs BEFORE the recipe" \
  "$(a=$(calls | grep -n '^apt-get' | head -1 | cut -d: -f1); r=$(calls | grep -n '^recipe' | head -1 | cut -d: -f1)
     [[ -n "$a" && -n "$r" && "$a" -lt "$r" ]]; echo $?)" "$(calls)"
check "missing: the step names the package" "$(grep -q 'Installing libatomic1' <<<"$ALL"; echo $?)" "$ALL"

# --- 2. empty package lists: one update, then a retry -------------------------
reset; export APT_MODE=needs-update
install hermes
check "stale lists: exits 0 after an update and a retry" "$([[ $RC -eq 0 ]]; echo $?)" "rc=$RC out=$ALL"
check "stale lists: apt-get update ran exactly once" "$([[ $(calls | grep -c '^apt-get .*update') -eq 1 ]]; echo $?)" "$(calls)"

# --- 3. apt cannot install it: fail naming the package, recipe never runs -----
reset; export APT_MODE=broken
install hermes
check "apt broken: exits non-zero" "$([[ $RC -ne 0 ]]; echo $?)" "out=$ALL"
check "apt broken: the error names libatomic1" "$(grep -q 'libatomic1' <<<"$(grep -i 'error\|"ok":false' <<<"$ALL")"; echo $?)" "$ALL"
check "apt broken: the recipe never ran" "$(! calls | grep -q '^recipe'; echo $?)" "$(calls)"
check "apt broken: no 'reported success' line" "$(! grep -q 'reported success' <<<"$ALL"; echo $?)" "$ALL"

# --- 4. already present: apt untouched ----------------------------------------
reset; touch "$TMP/has-libatomic"
install hermes
check "present: exits 0" "$([[ $RC -eq 0 ]]; echo $?)" "rc=$RC out=$ALL"
check "present: apt-get not called" "$(! calls | grep -q '^apt-get'; echo $?)" "$(calls)"

# --- 5. present at the top of a long ldconfig listing (SIGPIPE) ---------------
reset; touch "$TMP/has-libatomic"; export LDCONFIG_LONG=1
install hermes
check "long ldconfig: still read as present, apt-get not called" "$(! calls | grep -q '^apt-get'; echo $?)" "$(calls)"

# --- 6. a type that does not need it: apt untouched ---------------------------
reset; mkdir -p "$TMP/bin"; printf '#!/bin/sh\n' >"$TMP/bin/codex"; chmod +x "$TMP/bin/codex"
install codex --upgrade
check "codex: the install path ran (recipe reached)" "$(calls | grep -q '^recipe'; echo $?)" "$(calls)"
check "codex: apt-get not called for a type without a system library" "$(! calls | grep -q '^apt-get'; echo $?)" "$(calls)"

# --- 7. the recipe itself fails: say failed, not "reported success" ----------
reset; touch "$TMP/has-libatomic"; export RECIPE_MODE=fail
install hermes
check "recipe exit 1: exits non-zero" "$([[ $RC -ne 0 ]]; echo $?)" "out=$ALL"
check "recipe exit 1: reported as failed with the installer's exit" "$(grep -q 'install failed (installer exit 1)' <<<"$ALL"; echo $?)" "$ALL"
check "recipe exit 1: no 'reported success' line" "$(! grep -q 'reported success' <<<"$ALL"; echo $?)" "$ALL"

echo
echo "$PASS pass, $FAIL fail"
(( FAIL == 0 ))
