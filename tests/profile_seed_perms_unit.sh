#!/usr/bin/env bash
# DIVE-1188 unit: normalize_profile_seed_perms() makes a profile's file-based
# seed credentials (codex/grok auth.json) group-readable so 5dive-agent-start
# can seed them into an agent home WITHOUT sudo (standard-isolation agents have
# no passwordless-sudo rule; the old `sudo -n cat` seed bailed → unauthenticated
# boot). Pure, no root, no network:
#   bash tests/profile_seed_perms_unit.sh
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/profile-seed-perms-unit.XXXXXX)"

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

# Build a fake profile as the vendor CLIs actually write it: 0600 credential
# files under 0700 dot-dirs (DIVE-1900 — the dirs were the other half of the
# bug; a 0640 file under a 0700 dir is still unreadable to group=claude).
AGY_CRED="$AUTH_PROFILES_DIR/acme/antigravity/.gemini/antigravity-cli/antigravity-oauth-token"
OC_CRED="$AUTH_PROFILES_DIR/acme/openclaw/.openclaw/agents/main/agent/auth-profiles.json"
mkdir -p "$AUTH_PROFILES_DIR/acme/codex" "$AUTH_PROFILES_DIR/acme/grok/.grok" \
         "$AUTH_PROFILES_DIR/acme/hermes" "$(dirname "$AGY_CRED")" "$(dirname "$OC_CRED")"
echo '{"token":"c"}' > "$AUTH_PROFILES_DIR/acme/codex/auth.json"
echo '{"token":"g"}' > "$AUTH_PROFILES_DIR/acme/grok/.grok/auth.json"
echo '{"token":"h"}' > "$AUTH_PROFILES_DIR/acme/hermes/auth.json"
echo 'ya29.agy-token'  > "$AGY_CRED"
echo '{"token":"o"}' > "$OC_CRED"
chmod 0600 "$AUTH_PROFILES_DIR/acme/codex/auth.json" "$AUTH_PROFILES_DIR/acme/grok/.grok/auth.json" \
           "$AUTH_PROFILES_DIR/acme/hermes/auth.json" "$AGY_CRED" "$OC_CRED"
chmod 0700 "$AUTH_PROFILES_DIR/acme/grok/.grok" "$(dirname "$AGY_CRED")" \
           "$AUTH_PROFILES_DIR/acme/antigravity/.gemini" "$(dirname "$OC_CRED")"

# Precondition: not group-readable.
check "codex pre-perm 600" "$(stat -c '%a' "$AUTH_PROFILES_DIR/acme/codex/auth.json")" "600"
check "agy pre-perm 600"   "$(stat -c '%a' "$AGY_CRED")" "600"
check "agy dir pre-700"    "$(stat -c '%a' "$(dirname "$AGY_CRED")")" "700"

normalize_profile_seed_perms "acme"

check "codex now 640" "$(stat -c '%a' "$AUTH_PROFILES_DIR/acme/codex/auth.json")" "640"
check "grok now 640"  "$(stat -c '%a' "$AUTH_PROFILES_DIR/acme/grok/.grok/auth.json")" "640"
# DIVE-1900: the three types the old codex/grok-only loop skipped entirely.
check "hermes now 640"  "$(stat -c '%a' "$AUTH_PROFILES_DIR/acme/hermes/auth.json")" "640"
check "agy now 640"     "$(stat -c '%a' "$AGY_CRED")" "640"
check "openclaw now 640" "$(stat -c '%a' "$OC_CRED")" "640"
# ...and the dirs between the credential and the profile root are traversable,
# or the mode fix above buys nothing.
check "agy leaf dir g+rx"   "$(stat -c '%a' "$(dirname "$AGY_CRED")")" "750"
check "agy .gemini g+rx"    "$(stat -c '%a' "$AUTH_PROFILES_DIR/acme/antigravity/.gemini")" "750"
check "grok .grok g+rx"     "$(stat -c '%a' "$AUTH_PROFILES_DIR/acme/grok/.grok")" "750"
check "openclaw leaf g+rx"  "$(stat -c '%a' "$(dirname "$OC_CRED")")" "750"
# The walk must stop AT the profile root — never widen anything above it
# (the root is already created 2750 g=claude by profile_type_dir).
chmod 0700 "$AUTH_PROFILES_DIR/acme" "$AUTH_PROFILES_DIR"
normalize_profile_seed_perms "acme"
check "profile root not widened" "$(stat -c '%a' "$AUTH_PROFILES_DIR/acme")" "700"
check "store root not widened"   "$(stat -c '%a' "$AUTH_PROFILES_DIR")" "700"
chmod 0755 "$AUTH_PROFILES_DIR" "$AUTH_PROFILES_DIR/acme"

# ...and the other side of that bound (main, PR #151): because the walk stops
# BELOW the roots, correctness rests on the store root and each profile root
# being group-traversable — a mode this function never sets and never checks.
# The seed's real invariant is the WHOLE chain, so assert the whole chain: with
# the roots at the 2750 that profile_type_dir creates, every component from the
# store down to the credential must carry group r-x after normalize. This fails
# loudly if the roots are ever created or tightened to 0700, which is exactly
# the unasserted dependency.
chmod 2750 "$AUTH_PROFILES_DIR" "$AUTH_PROFILES_DIR/acme"
# Walk from the credential's own dir up to and INCLUDING the store root; above
# that is the harness tmpdir, which is none of our business.
chain_ok=yes
probe="$(dirname "$AGY_CRED")"
while :; do
  perm="$(stat -c '%A' "$probe")"
  # drwxr-s--- → [0]=type, [1..3]=user, [4..6]=group. Group r is [4], group x
  # is [6] (shows as 's' when setgid is set, which our profile dirs are).
  [[ "${perm:4:1}" == "r" && "${perm:6:1}" =~ ^[xs]$ ]] || chain_ok="no ($probe = $perm)"
  [[ "$probe" == "$AUTH_PROFILES_DIR" ]] && break
  probe="$(dirname "$probe")"
done
check "whole path chain is group-traversable after normalize" "$chain_ok" "yes"

# Empty profile is a safe no-op (default profile keeps shared /home/claude paths).
normalize_profile_seed_perms "" && echo "ok: empty-profile no-op returns 0" || { echo "FAIL: empty-profile"; fail=1; }

# Missing file is a safe no-op (no error).
rm -rf "$AUTH_PROFILES_DIR/acme"
normalize_profile_seed_perms "acme" && echo "ok: missing-creds no-op returns 0" || { echo "FAIL: missing-creds"; fail=1; }

exit $fail
