#!/usr/bin/env bash
# DIVE-1261: installer bundle checksum (build emit + install verify logic).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

[[ -f 5dive.sha256 ]] && ok_t "5dive.sha256 present" || bad_t "5dive.sha256 missing (run ./build.sh)"
want="$(tr -d '[:space:]' < 5dive.sha256)"
got="$(sha256sum 5dive | awk '{print $1}')"
[[ "$want" == "$got" ]] && ok_t "published sha256 matches the bundle" || bad_t "sha256 drift" "want=$want got=$got"

tmp="$(mktemp)"; cp 5dive "$tmp"
[[ "$(sha256sum "$tmp" | awk '{print $1}')" == "$want" ]] && ok_t "untampered copy verifies" || bad_t "untampered copy failed"
printf 'x' >> "$tmp"
[[ "$(sha256sum "$tmp" | awk '{print $1}')" != "$want" ]] && ok_t "tampered copy is detected" || bad_t "tampered copy NOT detected"
rm -f "$tmp"

grep -q 'checksum mismatch' install.sh && ok_t "install.sh fails closed on mismatch" || bad_t "no mismatch guard"
grep -q 'skipping integrity check' install.sh && ok_t "install.sh warns (not fatal) on absent checksum" || bad_t "no absent-checksum warn"
grep -q 'mktemp "${BIN_DIR}/.5dive' install.sh && ok_t "install.sh swaps atomically (temp in BIN_DIR)" || bad_t "no atomic-swap temp"

# DIVE-1271 regression: the absent-checksum path must be fail-soft *under the
# real installer flags*. install.sh runs `set -euo pipefail`, so a plain
# assignment whose curl-pipeline fails (offline bundle with no 5dive.sha256 →
# curl exit 37) aborts the whole install BEFORE the warn branch — which is what
# reddened docker-install. A text-only grep can't catch this; reproduce the
# exact fetch line against a bundle that omits 5dive.sha256 and assert survival.
fetch_line="$(grep -E '^\s*_want="\$\(curl .*5dive\.sha256' install.sh)"
bundle="$(mktemp -d)"; : > "$bundle/5dive"   # bundle has 5dive but NO 5dive.sha256
if bash -c "set -euo pipefail; REPO='file://$bundle'; $fetch_line; [[ -z \"\$_want\" ]]" 2>/dev/null; then
  ok_t "absent-checksum fetch is fail-soft under set -euo pipefail (offline bundle)"
else
  bad_t "absent-checksum fetch aborts under set -euo pipefail" "curl exit 37 propagates via pipefail — needs '|| _want=\"\"'"
fi
rm -rf "$bundle"

echo; echo "$PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]
