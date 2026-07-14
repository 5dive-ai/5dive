#!/usr/bin/env bash
# DIVE-1188 unit: normalize_profile_seed_perms() makes a profile's file-based
# seed credentials (codex/grok auth.json) group-readable so 5dive-agent-start
# can seed them into an agent home WITHOUT sudo (standard-isolation agents have
# no passwordless-sudo rule; the old `sudo -n cat` seed bailed → unauthenticated
# boot). Pure, no root, no network:
#   bash tests/profile_seed_perms_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/profile-seed-perms-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

# Point the profile store at the throwaway tmp (never touch /var/lib).
AUTH_PROFILES_DIR="$TMP/auth-profiles"
# Minimal type table so profile_type_auth_path resolves codex/grok.
declare -A TYPE_AUTH=([codex]="" [grok]="")
is_known_type() { case "$1" in codex|grok|claude|hermes|openclaw|antigravity) return 0;; *) return 1;; esac; }

# Pull in just the two functions under test from cmd_auth.sh without running
# its top-level code: source it (functions are defined, no side effects at load).
# shellcheck source=/dev/null
source "$SRC/cmd_auth.sh"

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want=$3 got=$2)"; fail=1; fi; }

# Build a fake profile with 0600 codex + grok auth.json (as the CLIs write them).
mkdir -p "$AUTH_PROFILES_DIR/acme/codex" "$AUTH_PROFILES_DIR/acme/grok/.grok"
echo '{"token":"c"}' > "$AUTH_PROFILES_DIR/acme/codex/auth.json"
echo '{"token":"g"}' > "$AUTH_PROFILES_DIR/acme/grok/.grok/auth.json"
chmod 0600 "$AUTH_PROFILES_DIR/acme/codex/auth.json" "$AUTH_PROFILES_DIR/acme/grok/.grok/auth.json"

# Precondition: not group-readable.
check "codex pre-perm 600" "$(stat -c '%a' "$AUTH_PROFILES_DIR/acme/codex/auth.json")" "600"

normalize_profile_seed_perms "acme"

check "codex now 640" "$(stat -c '%a' "$AUTH_PROFILES_DIR/acme/codex/auth.json")" "640"
check "grok now 640"  "$(stat -c '%a' "$AUTH_PROFILES_DIR/acme/grok/.grok/auth.json")" "640"

# Empty profile is a safe no-op (default profile keeps shared /home/claude paths).
normalize_profile_seed_perms "" && echo "ok: empty-profile no-op returns 0" || { echo "FAIL: empty-profile"; fail=1; }

# Missing file is a safe no-op (no error).
rm -rf "$AUTH_PROFILES_DIR/acme"
normalize_profile_seed_perms "acme" && echo "ok: missing-creds no-op returns 0" || { echo "FAIL: missing-creds"; fail=1; }

exit $fail
