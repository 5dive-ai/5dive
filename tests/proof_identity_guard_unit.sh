#!/usr/bin/env bash
# DIVE-2051 isolated unit harness for the `proof publish` IDENTITY guard: the
# publisher authors PUBLIC commits, so it must never infer the author. Sources
# cmd_proof.sh with stubbed deps against a temp state dir and a temp HOME (so
# the runner's own ~/.gitconfig cannot decide the outcome either way — this
# harness asserts a NEGATIVE, and an ambient identity would make the refusal
# case pass for the wrong reason). No root, no network, no cron.
# Asserts:
#   - nothing configured anywhere  -> _proof_build REFUSES (rc 4), no clone/commit,
#   - the refusal names the fix and does NOT publish,
#   - --dry-run refuses too (a dry run that skips the check is how a box first
#     learns it is misconfigured at 02:00 from cron),
#   - a HALF identity (name, no email) refuses as well,
#   - precedence env > proof.json > git config --global, with the source named,
#   - a resolved identity lets the guard pass (rc != 4).
# Run: bash tests/proof_identity_guard_unit.sh   (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/proof-identity.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- stub the deps cmd_proof.sh reaches for, then source it ------------------
E_USAGE=2; E_VALIDATION=3; E_GENERIC=1
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
_PROOF_CRON="$TMP/cron"
_PROOF_LOG="$TMP/log"
JSON_MODE=0
require_root() { :; }
fail() { echo "fail($1): $2" >&2; exit "$1"; }
warn() { echo "warn: $*" >&2; }

# Neutralize the runner's ambient git identity for the whole harness: a fresh
# HOME with an empty gitconfig, and the GIT_* env pins git itself honors.
export HOME="$TMP/home"; mkdir -p "$HOME"; : > "$HOME/.gitconfig"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
unset ZH_GIT_NAME ZH_GIT_EMAIL

# shellcheck disable=SC1091
source src/cmd_proof.sh

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# The guard must fire BEFORE any network or git work, so a bare _proof_build
# against an unreachable repo is a valid probe: rc 4 proves it never got that
# far. Anything else means the identity check did not run first.
UNREACHABLE="file://$TMP/definitely-not-a-repo"
build_rc() { local out; out="$(_proof_build "$UNREACHABLE" status "${1:-0}" 2>"$TMP/err")"; echo "$?"; }

# --- Case 1: nothing configured anywhere -> refuse ---------------------------
RC="$(build_rc 0)"
[[ "$RC" == "4" ]] && ok_t "no identity anywhere -> _proof_build refuses (rc 4)" \
  || bad_t "no-identity refusal" "rc=$RC err=$(head -2 "$TMP/err")"
grep -q "NO GIT IDENTITY CONFIGURED" "$TMP/err" \
  && ok_t "refusal says what is wrong" || bad_t "refusal message" "$(cat "$TMP/err")"
grep -q -- "--as-email" "$TMP/err" && grep -q "ZH_GIT_EMAIL" "$TMP/err" \
  && ok_t "refusal names both supported ways to pin an identity" \
  || bad_t "refusal remediation" "$(cat "$TMP/err")"
grep -qi "nothing was published" "$TMP/err" \
  && ok_t "refusal states nothing was published" || bad_t "refusal outcome line"

# --- Case 2: --dry-run refuses too -------------------------------------------
RC="$(build_rc 1)"
[[ "$RC" == "4" ]] && ok_t "--dry-run refuses too (misconfig surfaces before cron does)" \
  || bad_t "dry-run refusal" "rc=$RC"

# --- Case 3: a HALF identity still refuses -----------------------------------
# git would synthesize the missing email as user@hostname — the same guess.
git config --global user.name "half configured" 2>/dev/null
RC="$(build_rc 0)"
[[ "$RC" == "4" ]] && ok_t "name without email still refuses (no synthesized user@host)" \
  || bad_t "half-identity refusal" "rc=$RC"
git config --global --unset user.name 2>/dev/null

# --- Case 4: precedence + source naming --------------------------------------
git config --global user.name "global name" 2>/dev/null
git config --global user.email "global@example.com" 2>/dev/null
_proof_identity
[[ "$_PROOF_ID_EMAIL" == "global@example.com" ]] \
  && ok_t "falls back to git config --global when nothing else is pinned" \
  || bad_t "global fallback" "got=$_PROOF_ID_EMAIL"
[[ "$_PROOF_ID_SOURCE" == *"git config --global"* ]] \
  && ok_t "source names the global git config" || bad_t "global source" "got=$_PROOF_ID_SOURCE"

printf '{"identity":{"name":"cfg name","email":"cfg@example.com"}}\n' > "$STATE_DIR/proof.json"
_proof_identity
[[ "$_PROOF_ID_EMAIL" == "cfg@example.com" && "$_PROOF_ID_NAME" == "cfg name" ]] \
  && ok_t "proof.json identity beats the ambient global config" \
  || bad_t "config precedence" "got=$_PROOF_ID_NAME <$_PROOF_ID_EMAIL>"
[[ "$_PROOF_ID_SOURCE" == "proof.json identity" ]] \
  && ok_t "source names the pinned config" || bad_t "config source" "got=$_PROOF_ID_SOURCE"

ZH_GIT_NAME="env name" ZH_GIT_EMAIL="env@example.com" _proof_identity
[[ "$_PROOF_ID_EMAIL" == "env@example.com" && "$_PROOF_ID_NAME" == "env name" ]] \
  && ok_t "ZH_GIT_* env beats both" || bad_t "env precedence" "got=$_PROOF_ID_EMAIL"
[[ "$_PROOF_ID_SOURCE" == "env ZH_GIT_EMAIL" ]] \
  && ok_t "source names the env pin" || bad_t "env source" "got=$_PROOF_ID_SOURCE"

# --- Case 5: a resolved identity passes the guard ----------------------------
# Still fails (the repo is unreachable) — but with a DIFFERENT rc, which is the
# whole point: the guard let it through and the failure is now about the repo.
RC="$(build_rc 0)"
[[ "$RC" != "4" ]] && ok_t "a configured identity passes the guard (rc $RC is the unreachable repo, not the guard)" \
  || bad_t "configured identity still refused" "rc=$RC err=$(head -3 "$TMP/err")"

# --- Case 6: cannot inspect another user's config -> "unchecked", not "unset" -
# A false alarm is the same defect as a false green, pointed the other way. Only
# meaningful as a non-root runner; as root the lookup really can be done.
rm -f "$STATE_DIR/proof.json"
if [ "$(id -u)" != "0" ]; then
  _proof_identity "definitely-not-me"
  [[ "$_PROOF_ID_UNCHECKED" == "1" && -z "$_PROOF_ID_SOURCE" ]] \
    && ok_t "another user's identity is reported UNCHECKED, not falsely unset" \
    || bad_t "unchecked flag" "unchecked=$_PROOF_ID_UNCHECKED source=$_PROOF_ID_SOURCE"
  # …but a box-level pin is readable by anyone, so it must still resolve.
  printf '{"identity":{"name":"cfg name","email":"cfg@example.com"}}\n' > "$STATE_DIR/proof.json"
  _proof_identity "definitely-not-me"
  [[ "$_PROOF_ID_EMAIL" == "cfg@example.com" ]] \
    && ok_t "a pinned identity still resolves for another user (it is box-level)" \
    || bad_t "config resolves cross-user" "got=$_PROOF_ID_EMAIL"
  rm -f "$STATE_DIR/proof.json"
fi

# --- Case 7: the root path really reads the OTHER user's config --------------
# The branch that matters in production (the cron user is rarely the caller)
# cannot be exercised for real by a non-root runner, so drive it with stubbed
# id/runuser rather than leave it asserted by nobody.
(
  id() { case "${1:-}" in -u) echo 0 ;; -un) echo root ;; *) command id "$@" ;; esac; }
  runuser() { echo "cron-user@example.com"; }   # both name and email lookups
  _proof_identity "some-cron-user"
  [[ "$_PROOF_ID_EMAIL" == "cron-user@example.com" && "$_PROOF_ID_UNCHECKED" == "0" ]] || exit 1
  [[ "$_PROOF_ID_SOURCE" == *"some-cron-user"* ]] || exit 2
) && ok_t "as root, layer 3 resolves AS the cron user and names them in the source" \
  || bad_t "root cross-user resolution" "rc=$?"

# --- Case 8: `proof on --as-*` validation ------------------------------------
( _proof_onoff on --repo="https://github.com/acme/box.git" --as-email="not-an-email" ) 2>"$TMP/err2"
RC=$?
[[ "$RC" == "2" || "$RC" == "3" ]] \
  && ok_t "--as-email without --as-name / malformed is rejected" || bad_t "as-email validation" "rc=$RC"

echo
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
