#!/usr/bin/env bash
# DIVE-1261: installer bundle checksum (build emit + install verify logic).
set -uo pipefail

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
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
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
grep -q 'mktemp "${BIN_DIR}/.5dive' install.sh && ok_t "install.sh swaps atomically (temp in BIN_DIR)" || bad_t "no atomic-swap temp"

policy="$(sed -n '/^  # >>> DIVE-2248 checksum policy/,/^  # <<< DIVE-2248 checksum policy/p' install.sh)"
if [[ -n "$policy" ]] && grep -q '_want=.*5dive.sha256' <<<"$policy" && grep -q 'file://\*' <<<"$policy"; then
  ok_t "checksum source policy is extractable from install.sh"
else
  bad_t "checksum source policy missing" "DIVE-2248 fence, checksum fetch, or file:// discrimination drifted"
fi

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

# DIVE-2248: execute the shipped policy with a hermetic curl double. A network
# source whose checksum request fails must refuse and remove the downloaded
# bundle; an explicit file:// source with the same curl failure must survive.
# Both fixtures run the same extracted bytes, so the guard discriminates on the
# source rather than merely blocking every absent checksum.
fixture="$(mktemp -d)"
mkdir -p "$fixture/bin"
cat > "$fixture/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
case "${FAKE_CHECKSUM:-missing}" in
  present) printf '%s\n' "$FAKE_WANT" ;;
  missing) exit 22 ;;
  *) exit 2 ;;
esac
FAKE_CURL
chmod +x "$fixture/bin/curl"

run_policy(){ # $1=repo $2=present|missing $3=bundle-path
  local repo="$1" mode="$2" bundle_path="$3" expected
  expected="$(sha256sum "$bundle_path" | awk '{print $1}')"
  env -i PATH="$fixture/bin:/usr/bin:/bin" REPO="$repo" \
    FAKE_CHECKSUM="$mode" FAKE_WANT="$expected" \
    bash -c "set -euo pipefail
die(){ printf 'DIE: %s\\n' \"\$*\" >&2; exit 1; }
_bundle_tmp='${bundle_path}'
$policy
printf '__SURVIVED__\\n'" 2>&1
}

network_bundle="$fixture/network-bundle"; printf 'network bytes\n' > "$network_bundle"
out="$(run_policy 'https://example.invalid/release' missing "$network_bundle")"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"failed to fetch required 5dive.sha256"* && "$out" == *"refusing to install an unverified bundle"* ]] && [[ ! -e "$network_bundle" ]]; then
  ok_t "network source missing checksum REFUSES before swap and names the missing integrity object"
else
  bad_t "network source missing checksum did not fail closed" "rc=$rc exists=$([[ -e "$network_bundle" ]] && echo yes || echo no) out=${out//$'\n'/ | }"
fi

offline_bundle="$fixture/offline-bundle"; printf 'offline bytes\n' > "$offline_bundle"
out="$(run_policy 'file:///opt/5dive-bundle' missing "$offline_bundle")"; rc=$?
if (( rc == 0 )) && [[ "$out" == *"local file:// source has no 5dive.sha256"* && "$out" == *"__SURVIVED__"* ]] && [[ -e "$offline_bundle" ]]; then
  ok_t "offline file:// source missing checksum PROCEEDS explicitly"
else
  bad_t "offline file:// checksum exception was blocked" "rc=$rc exists=$([[ -e "$offline_bundle" ]] && echo yes || echo no) out=${out//$'\n'/ | }"
fi

verified_bundle="$fixture/verified-bundle"; printf 'verified bytes\n' > "$verified_bundle"
out="$(run_policy 'https://example.invalid/release' present "$verified_bundle")"; rc=$?
if (( rc == 0 )) && [[ "$out" == *"__SURVIVED__"* ]] && [[ -e "$verified_bundle" ]]; then
  ok_t "network source with matching checksum PROCEEDS"
else
  bad_t "matching network checksum was refused" "rc=$rc out=${out//$'\n'/ | }"
fi
rm -rf "$fixture"

echo; echo "$PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]
