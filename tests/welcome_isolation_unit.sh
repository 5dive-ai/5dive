#!/usr/bin/env bash
# DIVE-1571: the first-contact CONTROL-PLANE welcome (approved copy — spin up a
# team / company / council / goal) fires ONLY for admin-isolation agents. A
# standard/sandboxed agent must NOT claim powers it lacks, so it keeps the plain
# per-type welcome. A curl trap captures the sent text without any network call.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/welcome-iso.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh cmd_agent_pairing.sh; do
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; ENV_DIR="$STATE_DIR/agents.d"
mkdir -p "$ENV_DIR"
account_signin_detail() { echo '{}'; }   # hermes/openclaw provider probe stub

# curl trap: record the URL-encoded body instead of POSTing. The welcome text is
# the `text=` field; decode the bits the assertions need.
CURL_BODY="$TMP/body"; : >"$CURL_BODY"
curl() { printf '%s\n' "$*" >>"$CURL_BODY"; return 0; }

PASS=0; FAIL=0
ok_t() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

mk_env() { printf 'AGENT_ISOLATION=%s\n' "$2" >"$ENV_DIR/$1.env"; }
send_for() { : >"$CURL_BODY"; send_welcome_message "12345" "tok" "$1" "${2:-claude}" >/dev/null 2>&1; cat "$CURL_BODY"; }

# --- admin isolation -> approved control-plane copy, verbatim lead ---
mk_env admin_bot admin
body=$(send_for admin_bot claude)
grep -q "i'm admin_bot, your agent, and i'm not alone." <<<"$body" && ok_t "admin: leads with the approved copy + agent name" || bad_t "admin: approved lead" "$body"
grep -q "spin up a whole team, stand up a company, run a council, or turn a goal into a plan" <<<"$body" && ok_t "admin: control-plane capability pitch present" || bad_t "admin: capability pitch" "$body"
grep -q "show me what you can do" <<<"$body" && ok_t "admin: keeps the 'show me what you can do' CTA" || bad_t "admin: CTA" "$body"
grep -q -- "—" <<<"$body" && bad_t "admin: NO em-dash in public copy" "$body" || ok_t "admin: em-dash-free (public-copy rule)"

# --- standard isolation -> plain per-type welcome, NO control-plane claims ---
mk_env std_bot standard
body=$(send_for std_bot claude)
grep -q "We're connected!" <<<"$body" && ok_t "standard: keeps the plain per-type welcome" || bad_t "standard: plain welcome" "$body"
grep -q "stand up a company, run a council" <<<"$body" && bad_t "standard: must NOT claim control-plane powers it lacks" "$body" || ok_t "standard: no control-plane claims"

# --- sandboxed isolation -> also plain (only admin is gated in) ---
mk_env box_bot sandboxed
body=$(send_for box_bot claude)
grep -q "run a council" <<<"$body" && bad_t "sandboxed: must NOT claim control-plane powers" "$body" || ok_t "sandboxed: no control-plane claims"

# --- missing/unreadable env file -> FAIL-SAFE default STANDARD (plain welcome, never over-claim) ---
body=$(send_for ghost_bot claude)
grep -q "run a council" <<<"$body" && bad_t "unknown isolation must NOT over-claim (fail-safe -> standard)" "$body" || ok_t "unknown/unreadable isolation defaults STANDARD (fail-safe, no over-claim)"
grep -q "We're connected!" <<<"$body" && ok_t "unknown isolation gets the plain per-type welcome" || bad_t "unknown -> plain welcome" "$body"

# --- non-claude admin type (codex) still gets the type-neutral control-plane lead ---
mk_env cdx admin
body=$(send_for cdx codex)
grep -q "i'm not alone" <<<"$body" && ok_t "admin codex: control-plane welcome is type-neutral" || bad_t "admin codex" "$body"

printf '\nDIVE-1571 welcome isolation gate: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
