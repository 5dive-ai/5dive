#!/usr/bin/env bash
# DIVE-6849 — install.sh reads the repo layout off the PINNED tag.
#
# The box-side scripts moved into bin/ and the prompt files into prompts/. main's
# install.sh still installs from tags cut before the move (the fleet pin lags
# main, rollbacks pin by GH_SHA), and those ship the same files at the root. So
# the shipped DIVE-6849 block probes bin/host-scripts.manifest once and sets
# PIN_BIN / PIN_PROMPTS. This grades that block's bytes, arm by arm:
#   file:// bundle with bin/          -> bin/ + prompts/
#   file:// bundle without bin/       -> root
#   http 200                          -> bin/ + prompts/
#   http 404                          -> root
#   http 500 / curl failure           -> dies (never guesses root on a blip)
#   no REPO (uninstall)               -> root, no probe
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

BLOCK=$(sed -n '/^# >>> DIVE-6849 pin layout$/,/^# <<< DIVE-6849 pin layout$/p' install.sh)
[[ "$BLOCK" == *"resolve_pin_layout"* ]] || { bad_t "extract the DIVE-6849 block from install.sh" "markers not found"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

TMP=$(mktemp -d); trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
mkdir -p "$TMP/new/bin" "$TMP/old"
: > "$TMP/new/bin/host-scripts.manifest"

# One arm = a subshell that runs the shipped block with REPO and a curl stub that
# answers http code $2 (or fails with rc $3), then prints "<bin>|<prompts>".
arm() {  # REPO HTTP_CODE CURL_RC
  ( REPO=$1 STUB_CODE=$2 STUB_RC=$3
    die() { echo "DIED: $*"; exit 9; }
    # shellcheck disable=SC2317
    curl() { [[ "$STUB_RC" == 0 ]] || return "$STUB_RC"; printf '%s' "$STUB_CODE"; }
    eval "$BLOCK"
    printf '%s|%s\n' "$PIN_BIN" "$PIN_PROMPTS" ) 2>&1
}

[[ "$(arm "file://$TMP/new" - 0)" == "bin/|prompts/" ]] && ok_t "file:// bundle with bin/ -> bin/ + prompts/" || bad_t "file:// bundle with bin/" "$(arm "file://$TMP/new" - 0)"
[[ "$(arm "file://$TMP/old" - 0)" == "|" ]] && ok_t "file:// bundle without bin/ -> root layout" || bad_t "file:// bundle without bin/" "$(arm "file://$TMP/old" - 0)"
[[ "$(arm https://raw.example/sha 200 0)" == "bin/|prompts/" ]] && ok_t "http 200 -> bin/ + prompts/" || bad_t "http 200" "$(arm https://raw.example/sha 200 0)"
[[ "$(arm https://raw.example/sha 404 0)" == "|" ]] && ok_t "http 404 (a tag cut before the move) -> root layout" || bad_t "http 404" "$(arm https://raw.example/sha 404 0)"
out=$(arm https://raw.example/sha 500 0)
[[ "$out" == DIED:* ]] && ok_t "http 500 dies, never guesses root" || bad_t "http 500 must die" "$out"
out=$(arm https://raw.example/sha 000 6)
[[ "$out" == DIED:* ]] && ok_t "a curl failure dies, never guesses root" || bad_t "curl rc 6 must die" "$out"
[[ "$(arm "" 500 0)" == "|" ]] && ok_t "no REPO (uninstall) -> no probe, root" || bad_t "no REPO" "$(arm "" 500 0)"

# This tree is the new layout, and the probe file is what both install.sh and
# scripts/install-pin-compat.sh key on.
[[ -f bin/host-scripts.manifest ]] && ok_t "this tree ships the probe file bin/host-scripts.manifest" || bad_t "bin/host-scripts.manifest missing" "install.sh would read this tree as the root layout"
grep -qF -- "-e '/>>> DIVE-6849 pin layout/,/<<< DIVE-6849 pin layout/d'" scripts/install-pin-compat.sh \
  && grep -qF 'git cat-file -e "${PIN_COMMIT}:bin/host-scripts.manifest"' scripts/install-pin-compat.sh \
  && ok_t "install-pin-compat resolves the prefixes with the same probe file" \
  || bad_t "install-pin-compat does not resolve \${PIN_BIN} the way install.sh does" "the moved downloads would go ungraded"

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
