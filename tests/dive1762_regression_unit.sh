#!/usr/bin/env bash
# DIVE-1765: regression coverage for the two DIVE-1762 fixes that shipped
# manual-verified only (0.13.13 / 0.13.14).
#
#   BUG1 (be0708d) — cmd_pair's channel guard must match channel-list
#     *membership* (the ",telegram," idiom its five sibling telegram-*
#     subcommands already use), not the whole string, so a default
#     claude create with channels=telegram,dashboard still pairs.
#   BUG2 (1d2642b) — account_signin_detail's claude) case reverse-maps a
#     stored ANTHROPIC_BASE_URL (combined.env) to the canonical BYO
#     provider id, and returns null for a plain Anthropic subscription.
#
# Both cases source src/ directly and stub every side effect — no root,
# network, credentials, users, registry, or live state is touched.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh

pass=0
ok()   { pass=$((pass+1)); }
die()  { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# BUG1 — cmd_pair channel-membership guard
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/cmd_agent_pairing.sh

# Decouple cmd_pair from real state: ensure_state is a no-op, registry_read
# returns a canned single-agent registry whose channels we vary per case, and
# fail() records its message instead of aborting the shell. We only assert on
# the *guard* message; an accepted channel string proceeds past the guard and
# fails later (missing bot token) with a different message, which is fine.
ensure_state() { :; }
GUARD_MSG="pairing only applies to telegram or discord"

# Run the guard for one channels value; echoes "GUARD" if cmd_pair rejected on
# the membership guard, "PASS" if it got past it (rejected later on a *different*
# error). The unit under test is the membership guard only.
#
# cmd_pair is driven inside a subshell so a stubbed fail() can `exit` exactly
# like the real one (the real fail aborts the process; without an exit here
# cmd_pair falls through the guard into its interactive code-wait path and
# hangs). --user-id is supplied to take the non-interactive auto-pair branch.
# registry_read is stubbed to a canned single-agent registry; set +u tolerates
# the known downstream gap (cmd_pair's token/path resolution below the guard
# still exact-matches the whole channels string, so an accepted comma-list trips
# `token_var: unbound` then fails with "no bot token" — tracked separately as
# the incomplete-DIVE-1762 follow-up). The guard message is the sole discriminator.
pair_guard_result() {
  local ch="$1" out
  out=$(
    set +u
    fail() { printf '%s\n' "$2"; exit "$1"; }
    registry_read() { jq -cn --arg c "$ch" '{agents:{qa:{type:"claude", channels:$c}}}'; }
    cmd_pair qa --user-id=42 2>&1 || true
  )
  if [[ "$out" == *"$GUARD_MSG"* ]]; then echo GUARD; else echo PASS; fi
}

# Accepted: the default claude combo (both orders), discord+dashboard (both
# orders), and the plain single channels. Mirrors the 5 sibling telegram-*
# validations the fix aligns with.
for ch in "telegram,dashboard" "dashboard,telegram" "discord,dashboard" \
          "dashboard,discord" "telegram" "discord"; do
  [[ "$(pair_guard_result "$ch")" == PASS ]] \
    || die "BUG1: channels='$ch' should pass the pairing guard but was rejected"
  ok
done

# Rejected: no telegram/discord member — dashboard-only and empty.
for ch in "dashboard" ""; do
  [[ "$(pair_guard_result "$ch")" == GUARD ]] \
    || die "BUG1: channels='$ch' should be rejected by the pairing guard but passed"
  ok
done

# ---------------------------------------------------------------------------
# BUG2 — account_signin_detail claude BYO provider reverse-map
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091
source src/cmd_account.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
AUTH_PROFILES_DIR="$TMP/profiles"
# BYO has no .credentials.json sentinel; stub the auth-path lookup empty so the
# claude) branch falls back to combined.env for the signedInAt mtime.
profile_type_auth_path() { echo ""; return 0; }

# provider for a claude profile whose combined.env carries $1 as the raw
# ANTHROPIC_BASE_URL line (pass "" to omit the line entirely).
signin_provider() {
  local baseline="$1"
  rm -rf "$AUTH_PROFILES_DIR/qa"
  mkdir -p "$AUTH_PROFILES_DIR/qa"
  {
    echo "SOME_OTHER=1"
    [[ -n "$baseline" ]] && echo "$baseline"
    echo "TRAILING=2"
  } > "$AUTH_PROFILES_DIR/qa/combined.env"
  account_signin_detail qa claude | jq -r '.provider'
}

# Each canonical BYO base url reverse-maps to its provider id.
[[ "$(signin_provider 'ANTHROPIC_BASE_URL=https://openrouter.ai/api')" == openrouter ]] \
  || die "BUG2: openrouter base url did not reverse-map to 'openrouter'"; ok
[[ "$(signin_provider 'ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic')" == deepseek ]] \
  || die "BUG2: deepseek base url did not reverse-map to 'deepseek'"; ok
[[ "$(signin_provider 'ANTHROPIC_BASE_URL=https://api.moonshot.ai/anthropic')" == moonshot ]] \
  || die "BUG2: moonshot base url did not reverse-map to 'moonshot'"; ok
[[ "$(signin_provider 'ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic')" == zai ]] \
  || die "BUG2: zai base url did not reverse-map to 'zai'"; ok

# A double-quoted value (combined.env may quote it) is stripped before matching.
[[ "$(signin_provider 'ANTHROPIC_BASE_URL="https://openrouter.ai/api"')" == openrouter ]] \
  || die "BUG2: quoted openrouter base url did not reverse-map"; ok

# Plain Anthropic subscription: no base url line -> provider null (no badge).
[[ "$(signin_provider '')" == null ]] \
  || die "BUG2: plain subscription (no base url) should yield provider null"; ok

# An unrecognized base url stays null (not misattributed to a real provider).
[[ "$(signin_provider 'ANTHROPIC_BASE_URL=https://example.invalid/api')" == null ]] \
  || die "BUG2: unknown base url should not map to any provider"; ok

# No combined.env at all -> the branch bails with an empty object.
rm -rf "$AUTH_PROFILES_DIR/qa"; mkdir -p "$AUTH_PROFILES_DIR/qa"
[[ "$(account_signin_detail qa claude)" == "{}" ]] \
  || die "BUG2: missing combined.env should return '{}'"; ok

echo "OK: dive1762_regression_unit — $pass assertions passed"
