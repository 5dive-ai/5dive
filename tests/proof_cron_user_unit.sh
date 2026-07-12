#!/usr/bin/env bash
# OSS-30 isolated unit harness for `proof on --user`: the cron's effective user
# must own the box's git push creds (root has none on boxes where creds live
# with a service user). Sources cmd_proof.sh with stubbed deps and drives
# _proof_onoff against a temp state dir + temp cron file — no root, no cron.d.
# Asserts:
#   - default cron user is root (back-compat),
#   - --user=<u> writes that user into the cron line AND persists to proof.json,
#   - the persisted user survives a re-on with no --user,
#   - an unknown --user is rejected (E_USAGE), no cron written,
#   - status reflects the configured non-root user.
# Run: bash tests/proof_cron_user_unit.sh   (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/proof-cron-user.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- stub the deps cmd_proof.sh reaches for, then source it ------------------
E_USAGE=2
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
_PROOF_CRON="$TMP/cron"                 # override the /etc/cron.d path (testable)
JSON_MODE=0
require_root() { :; }                   # no-op: we don't actually touch cron.d
# fail <code> <msg>: the real fail EXITS, so mirror that (exit, not return) or
# validation control-flow won't short-circuit. We invoke _proof_onoff in a
# subshell per case so this exit is contained; all state lives on disk.
fail() { echo "fail($1): $2" >&2; exit "$1"; }
# _proof_install_cron guards on the literal /etc/cron.d dir (we can't move it,
# but we DID redirect the file it writes there via _PROOF_CRON). Skip cleanly
# on the rare host without cron.d rather than assert a false failure.
[ -d /etc/cron.d ] || { echo "SKIP - /etc/cron.d absent on this host"; exit 0; }

# shellcheck disable=SC1091
source src/cmd_proof.sh

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
cron_user() { sed -n 's/^0 [0-9]* \* \* \* \([^ ]*\) .*/\1/p' "$_PROOF_CRON" 2>/dev/null; }
pref() { jq -r "$1 // \"\"" "$STATE_DIR/proof.json" 2>/dev/null; }

REPO="https://github.com/acme/box.git"

# --- Case 1: default user is root (back-compat) ------------------------------
( _proof_onoff on --repo="$REPO" --at=3 ) >/dev/null 2>&1
[ "$(cron_user)" = "root" ] && ok_t "default cron user is root" || bad_t "default user" "got '$(cron_user)'"
[ "$(pref '.user')" = "root" ] && ok_t "default user persisted as root" || bad_t "persist default" "$(pref '.user')"

# --- Case 2: --user=<current user> writes + persists that user ---------------
ME="$(id -un)"
( _proof_onoff on --repo="$REPO" --at=3 --user="$ME" ) >/dev/null 2>&1
[ "$(cron_user)" = "$ME" ] && ok_t "--user writes that user into the cron line" || bad_t "user in cron" "got '$(cron_user)'"
[ "$(pref '.user')" = "$ME" ] && ok_t "--user persisted to proof.json" || bad_t "persist user" "$(pref '.user')"

# --- Case 3: re-on with no --user keeps the persisted user -------------------
( _proof_onoff on --repo="$REPO" --at=5 ) >/dev/null 2>&1
[ "$(cron_user)" = "$ME" ] && ok_t "re-on without --user keeps persisted user" || bad_t "sticky user" "got '$(cron_user)'"

# --- Case 4: unknown user is rejected, cron NOT rewritten --------------------
BOGUS="no_such_user_$$"
cp "$_PROOF_CRON" "$TMP/cron.before"
( _proof_onoff on --repo="$REPO" --at=5 --user="$BOGUS" ) >/dev/null 2>&1; RC=$?
[ "$RC" -eq "$E_USAGE" ] && ok_t "unknown --user rejected with E_USAGE" || bad_t "reject rc" "rc=$RC"
[ "$(cron_user)" = "$ME" ] && ok_t "rejected --user left cron unchanged" || bad_t "cron mutated on reject" "got '$(cron_user)'"

# --- Case 5: status reflects the configured non-root user -------------------
OUT="$(_proof_onoff status 2>/dev/null)"
echo "$OUT" | grep -q "as ${ME}" && ok_t "status shows non-root cron user" || bad_t "status user" "$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
