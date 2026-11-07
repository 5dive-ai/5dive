#!/usr/bin/env bash
# DIVE-7851 — `agent auth login|start <type>` installs a missing runtime first.
#
# A self-hosted box ships Claude Code only. The app's one line for ChatGPT is
#   sudo 5dive account add chatgpt && sudo 5dive agent auth login codex --auth-profile=chatgpt
# and on a fresh box the second half died "codex not installed at …/codex",
# because cmd_auth_login and cmd_auth_start checked `-x $bin` and failed. Both now
# run the TYPE_INSTALL recipe first, as `agent create/import` and `agent switch` do.
#
#   L1  login, codex missing: installed first, then the device sign-in hand-off runs
#       (negative control: red on the pre-fix tree, HARNESS_SRC=<old src dir>)
#   L2  login, codex present: no install, hand-off runs
#   L3  login, install fails: no hand-off, the error names the retry command
#   S1  start, codex missing: installed first, then the profile/device flow starts
#   S2  start --json, install fails: stdout is still one JSON error document
#   N1  a type with no installer: refused, no install attempted
#
# cmd_install, require_root and the profile writers are stubs; `sudo` is a PATH
# shim that prints the hand-off instead of running it. No root, no network.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC="${HARNESS_SRC:-src}"
TMP=$(mktemp -d /tmp/auth-install.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/state.sh \
         lib/registry.sh lib/audit.sh cmd_auth.sh; do
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

mkdir -p "$TMP/shim" "$TMP/home"
printf '#!/usr/bin/env bash\necho "HANDOFF: $*"\n' >"$TMP/shim/sudo"; chmod +x "$TMP/shim/sudo"
export PATH="$TMP/shim:$PATH"
LOG="$TMP/log"
BIN="$TMP/home/codex"
TYPE_BIN[codex]="$BIN"

INSTALL_MODE=ok
cmd_install() {
  echo "INSTALL $* json=$JSON_MODE" >>"$LOG"
  if [[ "$INSTALL_MODE" == ok ]]; then
    printf '#!/bin/sh\n' >"$BIN"; chmod +x "$BIN"
    ok "$1 installed at $BIN"
  else
    fail "$E_GENERIC" "$1 install failed (installer exit 1) and $BIN is missing"
  fi
}
require_root()       { echo "ROOT" >>"$LOG"; }
ensure_profile_dir() { echo "PROFILE-DIR $*" >>"$LOG"; echo "$TMP/p"; }
profile_type_dir()   { echo "PAST-INSTALL-GATE" >>"$LOG"; echo "$TMP/p/$2"; }
profile_type_env()   { echo "CODEX_HOME=$TMP/p/codex"; }

reset() { rm -f "$BIN" "$LOG"; : >"$LOG"; INSTALL_MODE=ok; JSON_MODE=0; }

# ---- L1
reset
out=$( (cmd_auth_login codex --auth-profile=chatgpt) 2>&1 ); rc=$?
if grep -q '^INSTALL codex' "$LOG" && [[ $rc -eq 0 ]] && grep -q 'HANDOFF:.*codex login --device-auth' <<<"$out"; then
  ok_t "L1 login on a box without codex installs it, then reaches the device sign-in"
else
  bad_t "L1 login on a box without codex installs it, then reaches the device sign-in" "rc=$rc out=$out log=$(cat "$LOG")"
fi
# install must come before the profile work, or the sign-in lands in a profile for a missing runtime
if [[ "$(grep -n '^INSTALL' "$LOG" | cut -d: -f1)" -lt "$(grep -n 'PAST-INSTALL-GATE' "$LOG" | cut -d: -f1 || echo 0)" ]] 2>/dev/null; then
  ok_t "L1 install runs before the profile is prepared"
else
  bad_t "L1 install runs before the profile is prepared" "$(cat "$LOG")"
fi

# ---- L2
reset; printf '#!/bin/sh\n' >"$BIN"; chmod +x "$BIN"
out=$( (cmd_auth_login codex --auth-profile=chatgpt) 2>&1 ); rc=$?
if ! grep -q '^INSTALL' "$LOG" && [[ $rc -eq 0 ]] && grep -q 'HANDOFF:.*codex login --device-auth' <<<"$out"; then
  ok_t "L2 login with codex present does not reinstall"
else
  bad_t "L2 login with codex present does not reinstall" "rc=$rc out=$out log=$(cat "$LOG")"
fi

# ---- L3
reset; INSTALL_MODE=fail
out=$( (cmd_auth_login codex --auth-profile=chatgpt) 2>&1 ); rc=$?
if [[ $rc -ne 0 ]] && ! grep -q 'HANDOFF' <<<"$out" && grep -q 'sudo 5dive agent install codex' <<<"$out"; then
  ok_t "L3 a failed install stops before sign-in and names the retry"
else
  bad_t "L3 a failed install stops before sign-in and names the retry" "rc=$rc out=$out"
fi

# ---- S1
reset
out=$( (cmd_auth_start codex --auth-profile=chatgpt) 2>&1 ); rc=$?
if grep -q '^INSTALL codex' "$LOG" && grep -q 'PAST-INSTALL-GATE' "$LOG" \
   && [[ "$(grep -n '^INSTALL' "$LOG" | cut -d: -f1)" -lt "$(grep -n 'PAST-INSTALL-GATE' "$LOG" | cut -d: -f1)" ]]; then
  ok_t "S1 start on a box without codex installs it, then starts the device flow"
else
  bad_t "S1 start on a box without codex installs it, then starts the device flow" "rc=$rc out=${out:0:400} log=$(cat "$LOG")"
fi
if grep -q '^INSTALL codex json=0' "$LOG"; then
  ok_t "S1 the nested install runs in prose mode (its progress goes to stderr)"
else
  bad_t "S1 the nested install runs in prose mode (its progress goes to stderr)" "$(cat "$LOG")"
fi

# ---- S2
reset; INSTALL_MODE=fail; JSON_MODE=1
stdout=$( (cmd_auth_start codex --auth-profile=chatgpt) 2>/dev/null ); rc=$?
if [[ $rc -ne 0 ]] && jq -e . >/dev/null 2>&1 <<<"$stdout" && [[ $(jq -s length <<<"$stdout") -eq 1 ]] \
   && grep -q 'agent install codex' <<<"$stdout"; then
  ok_t "S2 start --json with a failed install prints one JSON error on stdout"
else
  bad_t "S2 start --json with a failed install prints one JSON error on stdout" "rc=$rc stdout=$stdout"
fi

# ---- N1
reset
saved="${TYPE_INSTALL[codex]}"; unset 'TYPE_INSTALL[codex]'
out=$( (cmd_auth_login codex) 2>&1 ); rc=$?
TYPE_INSTALL[codex]="$saved"
if [[ $rc -ne 0 ]] && ! grep -q '^INSTALL' "$LOG" && grep -q 'not installed' <<<"$out"; then
  ok_t "N1 a type with no installer is refused without an install attempt"
else
  bad_t "N1 a type with no installer is refused without an install attempt" "rc=$rc out=$out"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
