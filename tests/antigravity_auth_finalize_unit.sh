#!/usr/bin/env bash
# DIVE-1803 unit harness for the antigravity auth-finalize contract.
#
# Bug: `auth start|poll|submit antigravity` reported session state=ok the moment
# the antigravity-oauth-token sentinel's mtime bumped — but agy blocks in a
# post-login onboarding TUI (theme/model/[Next]) and the token blob isn't
# finalized until onboarding completes, so killing the session on the bare mtime
# bump stranded the profile with an EMPTY/absent token (`auth status` ->
# needs_login). The fix (cmd_auth_poll's dedicated antigravity branch) never
# declares ok until the token file is NON-EMPTY and its mtime has settled.
#
# This locks the underlying usability contract that the poll must respect:
#   - an EMPTY antigravity token file is NOT usable creds (-> needs_login),
#   - a NON-EMPTY one IS,
#   - the sibling file-based types (codex/grok) are unaffected,
# plus a structural canary that the poll's antigravity branch gates state=ok on
# a non-empty, mtime-stable sentinel rather than the bare mtime bump.
# Run: bash tests/antigravity_auth_finalize_unit.sh  (no root, no network, no tmux).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_auth.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e  # header.sh enabled set -e; asserts below deliberately probe non-zero rc

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# Sandbox the profile store so we never touch /var/lib/5dive.
TMP=$(mktemp -d -t agy-finalize.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
AUTH_PROFILES_DIR="$TMP/auth-profiles"

prof="qaagy"
agy_token="$(profile_type_auth_path "$prof" antigravity)"
mkdir -p "$(dirname "$agy_token")"

# --- 1. empty token = not usable (the exact bug: false-ok while needs_login) ---
: > "$agy_token"                    # 0-byte file, mtime freshly bumped
if auth_creds_present antigravity "$prof"; then
  bad_t "empty antigravity token counts as usable" "auth_creds_present returned 0 for a 0-byte token — this is the DIVE-1803 false-ok"
else
  ok_t "empty antigravity token is NOT usable creds (needs_login)"
fi

# --- 2. non-empty token = usable -------------------------------------------
printf 'ya29.some-opaque-token-blob\n' > "$agy_token"
if auth_creds_present antigravity "$prof"; then
  ok_t "non-empty antigravity token is usable creds"
else
  bad_t "non-empty antigravity token not recognized" "auth_creds_present returned non-zero for a populated token"
fi

# --- 3. absent token = not usable ------------------------------------------
rm -f "$agy_token"
if auth_creds_present antigravity "$prof"; then
  bad_t "absent antigravity token counts as usable" "auth_creds_present returned 0 with no token file"
else
  ok_t "absent antigravity token is NOT usable creds"
fi

# --- 4. sibling file-based type (grok) unaffected: present file = usable ----
grok_auth="$(profile_type_auth_path "$prof" grok)"
mkdir -p "$(dirname "$grok_auth")"
printf '{"access_token":"x"}\n' > "$grok_auth"
if auth_creds_present grok "$prof"; then
  ok_t "grok creds file present = usable (sibling type unaffected)"
else
  bad_t "grok present-file regressed" "auth_creds_present returned non-zero for a present grok auth.json"
fi

# --- 5. structural canary: the poll's antigravity branch must gate ok on a
#         NON-EMPTY, mtime-stable sentinel, not the bare mtime bump ----------
agy_branch=$(awk '/^          antigravity\)/{c++} c==2{print} /^          codex\|hermes\|openclaw\|grok\)/{if(c==2) exit}' "$SRC/cmd_auth.sh")
if grep -q 'state="ok"' <<<"$agy_branch" \
   && grep -qE '\[\[ -s "\$sentinel" \]\].*current == stable|current == stable' <<<"$agy_branch" \
   && grep -q '\-s "\$sentinel"' <<<"$agy_branch"; then
  ok_t "poll antigravity branch gates ok on non-empty + stable-mtime sentinel"
else
  bad_t "poll antigravity ok-gate missing" "expected the antigravity poll branch to require [[ -s \$sentinel ]] and current == stable before state=ok"
fi

echo
echo "antigravity-auth-finalize: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
