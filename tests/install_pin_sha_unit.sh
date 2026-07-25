#!/usr/bin/env bash
# DIVE-1977: install.sh must fetch the bundle and its .sha256 from ONE immutable
# commit sha, not from the mutable `main` ref — two independent CDN objects under
# /main can be served from different cache generations for a window after every
# release, which fails the checksum guard with a tamper-shaped message on an
# unattended nightly self-update.
#
# Hermetic by construction: the pin-resolution block is extracted verbatim from
# install.sh and run against STUBBED git/curl on PATH, so this harness makes no
# network calls and asserts the real shipped code, not a paraphrase of it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

SHA_A="1111111111111111111111111111111111111111"
SHA_B="2222222222222222222222222222222222222222"
SHA_C="3333333333333333333333333333333333333333"

block="$(sed -n '/^# >>> DIVE-1977 pin-resolution block/,/^# <<< DIVE-1977 pin-resolution block/p' install.sh)"
if [[ -n "$block" ]] && grep -q 'resolve_gh_sha()' <<<"$block"; then
  ok_t "pin-resolution block is extractable from install.sh"
else
  bad_t "pin-resolution block missing" "markers '# >>> / # <<< DIVE-1977 pin-resolution block' not found in install.sh"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# Run the extracted block under install.sh's real flags (`set -euo pipefail`,
# line 6) with $1/$2 as the git/curl stub behaviour, and echo the resolved
# REPO + GH_PINNED_SHA. Stubs shadow the real binaries via PATH.
run_block() { # $1=git stub body ('' = git absent)  $2=curl stub body
  local stubs; stubs="$(mktemp -d)"
  if [[ -n "$1" ]]; then printf '#!/usr/bin/env bash\n%s\n' "$1" > "$stubs/git"; chmod +x "$stubs/git"; fi
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$stubs/curl"; chmod +x "$stubs/curl"
  # PATH is stubs-first but keeps the real tools the block needs (awk/sed/head).
  # A stub that exits nonzero stands in for "git present but can't resolve" and
  # for "git absent" alike: both leave $sha empty and must fall through.
  env -i PATH="$stubs:/usr/bin:/bin" GH_ORG="testorg" \
    ${3+REPO="$3"} ${4+GH_SHA="$4"} \
    bash -c "set -euo pipefail
$block
printf 'REPO=%s\nPIN=%s\n' \"\$REPO\" \"\$GH_PINNED_SHA\"" 2>/dev/null
  local rc=$?; rm -rf "$stubs"; return $rc
}

# 1. git ls-remote resolves → REPO pinned to that sha, not to /main.
out="$(run_block "printf '$SHA_A\trefs/heads/main\n'" "exit 22")"
if [[ "$out" == *"REPO=https://raw.githubusercontent.com/testorg/5dive/$SHA_A"* && "$out" == *"PIN=$SHA_A"* ]]; then
  ok_t "git ls-remote sha pins REPO to raw/<sha>"
else
  bad_t "git ls-remote sha did not pin REPO" "got: ${out//$'\n'/ | }"
fi

# 2. git absent/broken → atom feed fallback pins.
atom_stub='case "$*" in
  *commits/main.atom*) printf "<entry><id>tag:github.com,2008:Grit::Commit/'"$SHA_B"'</id></entry>\n" ;;
  *) exit 22 ;;
esac'
out="$(run_block "exit 1" "$atom_stub")"
if [[ "$out" == *"PIN=$SHA_B"* ]]; then
  ok_t "atom-feed fallback pins when git can't resolve (fresh box, git not installed yet)"
else
  bad_t "atom-feed fallback did not pin" "got: ${out//$'\n'/ | }"
fi

# 3. git + atom both fail → api.github.com last resort pins.
api_stub='case "$*" in
  *api.github.com*) printf "{\"sha\": \"'"$SHA_C"'\", \"commit\": {}}\n" ;;
  *) exit 22 ;;
esac'
out="$(run_block "exit 1" "$api_stub")"
if [[ "$out" == *"PIN=$SHA_C"* ]]; then
  ok_t "api.github.com is the last-resort pin"
else
  bad_t "api.github.com fallback did not pin" "got: ${out//$'\n'/ | }"
fi

# 4. NOTHING resolves → fall back to /main, and say so via an empty pin. The
#    install must still proceed (never harden into a brick), and the mismatch
#    branch keys off the empty pin to soften its wording.
out="$(run_block "exit 1" "exit 22")"
if [[ "$out" == *"REPO=https://raw.githubusercontent.com/testorg/5dive/main"* ]] \
   && [[ "$(sed -n 's/^PIN=//p' <<<"$out")" == "" ]]; then
  ok_t "unresolvable sha falls back to /main with an empty pin (no brick)"
else
  bad_t "unresolvable-sha fallback wrong" "got: ${out//$'\n'/ | }"
fi

# 5. A caller-supplied REPO (offline smoke bundle, enterprise mirror) is never
#    re-pinned and never claims a pin.
out="$(run_block "printf '$SHA_A\trefs/heads/main\n'" "exit 22" "file:///opt/5dive-bundle")"
if [[ "$out" == *"REPO=file:///opt/5dive-bundle"* && "$out" != *"PIN=$SHA_A"* ]]; then
  ok_t "explicit REPO override is untouched and claims no pin"
else
  bad_t "explicit REPO override was clobbered or falsely claimed a pin" "got: ${out//$'\n'/ | }"
fi

# 6. GH_SHA pins directly with zero resolution (works with no git and no network).
out="$(run_block "exit 1" "exit 22" "" "$SHA_C")"
if [[ "$out" == *"REPO=https://raw.githubusercontent.com/testorg/5dive/$SHA_C"* && "$out" == *"PIN=$SHA_C"* ]]; then
  ok_t "GH_SHA pins directly without any resolution"
else
  bad_t "GH_SHA did not pin" "got: ${out//$'\n'/ | }"
fi
# (case 6 passes REPO="" explicitly — assert the empty override is treated as unset)

# 7. The bundle and its checksum must be fetched from the SAME base. A future
#    edit that reintroduces a hardcoded /main URL for either one re-opens the race.
if grep -nE '^\s*(curl .*|_want="\$\(curl .*)"?https://raw\.githubusercontent\.com/[^"]*/main/5dive' install.sh; then
  bad_t "a fetch of the bundle or its sha256 hardcodes the mutable /main ref" "must go through \$REPO"
else
  ok_t "bundle + sha256 are both fetched through \$REPO (one pinned base)"
fi

# 8. The guard is NOT weakened — mismatch is still fatal — but the message no
#    longer collapses cache skew into tampering.
if grep -q 'checksum mismatch' install.sh && grep -cq 'die "5dive bundle checksum mismatch' install.sh; then
  ok_t "mismatch is still fatal (die), guard not weakened"
else
  bad_t "mismatch guard weakened or removed"
fi
pinned_msg="$(grep -c 'immutable tree \$GH_PINNED_SHA' install.sh)"
skew_msg="$(grep -c 'different CDN cache generations' install.sh)"
if [[ "$pinned_msg" -ge 1 && "$skew_msg" -ge 1 ]]; then
  ok_t "mismatch message distinguishes pinned bad-bytes from unpinned cache skew"
else
  bad_t "mismatch message still collapses stale-mirror into tampering" \
    "pinned-branch=$pinned_msg skew-branch=$skew_msg (want >=1 each)"
fi

echo; echo "$PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]
