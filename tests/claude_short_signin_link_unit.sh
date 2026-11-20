#!/usr/bin/env bash
# DIVE-8913 — Claude Code v2.1.330 `setup-token` prints a SHORT sign-in link
# (`https://claude.ai/oauth/authorize?<opaque>`) instead of the full
# claude.com/cai one. extract_claude_url only knew claude.com, so
# `5dive agent auth start claude` never reached awaiting_code and every
# Connect Claude / hire sign-in failed on 2.1.330.
#
# Fixtures (tests/fixtures/dive8913-claude-signin/) are real setup-token PTY
# logs, captured with the official binaries in tmux -x 200 + `script -q -f`,
# the way auth_spawn_pty runs it, with an empty HOME. state, code_challenge
# and the short link's opaque token are overwritten with same-length REDACTED
# filler, also inside the hard-wrapped visible copy of the link.
#   full-2.1.329.txt                  2.1.329, full claude.com link
#   short-2.1.330.txt                 2.1.330, short claude.ai link
#   short-2.1.330-with-switch.txt     2.1.330 + CLAUDE_CODE_FULL_SIGN_IN_LINK=1
#
# Run: bash tests/claude_short_signin_link_unit.sh (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/claude-short-signin.XXXXXX)"
FX=tests/fixtures/dive8913-claude-signin

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 absent"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/cmd_auth.sh
set +e

FULL_PREFIX='https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri='
FULL_TAIL='&state=REDACTEDxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
SHORT_URL='https://claude.ai/oauth/authorize?REDACTEDxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'

# --- cases 1-3: the OSC 8 branch, one per captured log --------------------------
expect_full() {  # <case label> <log>
  local got; got=$(extract_claude_url "$2")
  if [[ "$got" == "$FULL_PREFIX"* && "$got" == *"$FULL_TAIL" ]]; then
    ok_t "$1"
  else
    bad_t "$1" "got: ${got:-<nothing>}"
  fi
}
expect_full "case 1: 2.1.329 log yields the full claude.com link" "$FX/full-2.1.329.txt"

got=$(extract_claude_url "$FX/short-2.1.330.txt")
if [[ "$got" == "$SHORT_URL" ]]; then
  ok_t "case 2: 2.1.330 short-link log yields the claude.ai short link, whole"
else
  bad_t "case 2: 2.1.330 short-link log yields the claude.ai short link, whole" "got: ${got:-<nothing>}"
fi

expect_full "case 3: 2.1.330 + CLAUDE_CODE_FULL_SIGN_IN_LINK=1 yields the full claude.com link" \
  "$FX/short-2.1.330-with-switch.txt"

# --- case 4: plain-text branch (no OSC 8 wrapper) still finds the short link ----
python3 -I - "$FX/short-2.1.330.txt" "$TMP/no-osc8.log" <<'PY'
import re, sys
d = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'wb').write(re.sub(rb'\x1b\]8;[^\x07]*\x07', b'', d))
PY
got=$(extract_claude_url "$TMP/no-osc8.log")
if [[ "$got" == "$SHORT_URL" ]]; then
  ok_t "case 4: short link found by the plain-text fallback when OSC 8 is absent"
else
  bad_t "case 4: short link found by the plain-text fallback when OSC 8 is absent" "got: ${got:-<nothing>}"
fi

# --- case 5: an unrelated claude.ai URL is not mistaken for a sign-in link ------
printf 'See https://claude.ai/settings/account-and-billing-page for details\n' > "$TMP/other.log"
got=$(extract_claude_url "$TMP/other.log")
if [[ -z "$got" ]]; then
  ok_t "case 5: a non-sign-in claude.ai URL is not extracted"
else
  bad_t "case 5: a non-sign-in claude.ai URL is not extracted" "got: $got"
fi

# --- case 6: `auth start claude` spawns setup-token WITH the switch -------------
# Drive the real cmd_auth_start with its side effects stubbed; the spy records
# what auth_spawn_pty would have put in the PTY's env.
SPY="$TMP/spawn.args"
start_spawn_env() {  # [--auth-profile=x] -> prints the extra_env passed to the PTY
  (
    AUTH_SESSIONS_DIR="$TMP/sessions"; mkdir -p "$AUTH_SESSIONS_DIR"
    _auth_install_if_missing() { :; }
    require_auth_session_root() { :; }
    auth_reap_quiet() { :; }
    chown() { :; }
    valid_profile_name() { return 0; }
    ensure_profile_dir() { :; }
    profile_type_dir() { :; }
    profile_type_env() { printf 'CLAUDE_CONFIG_DIR=/profiles/%s/claude' "$1"; }
    auth_spawn_pty() { printf '%s|%s' "$2" "$4" > "$SPY"; return 0; }
    ok() { :; }
    cmd_auth_start claude "$@"
  ) >/dev/null 2>&1
  cat "$SPY" 2>/dev/null; rm -f "$SPY"
}
got=$(start_spawn_env)
if [[ "$got" == *"setup-token|"* && "$got" == *"|CLAUDE_CODE_FULL_SIGN_IN_LINK=1" ]]; then
  ok_t "case 6: auth start claude spawns setup-token with CLAUDE_CODE_FULL_SIGN_IN_LINK=1"
else
  bad_t "case 6: auth start claude spawns setup-token with CLAUDE_CODE_FULL_SIGN_IN_LINK=1" "spawn: ${got:-<not called>}"
fi
got=$(start_spawn_env --auth-profile=work)
if [[ "$got" == *"|CLAUDE_CONFIG_DIR=/profiles/work/claude CLAUDE_CODE_FULL_SIGN_IN_LINK=1" ]]; then
  ok_t "case 7: a profile-scoped start keeps its profile env AND adds the switch"
else
  bad_t "case 7: a profile-scoped start keeps its profile env AND adds the switch" "spawn: ${got:-<not called>}"
fi

# --- case 8: interactive `auth login claude` passes the switch too --------------
SUDO_SPY="$TMP/sudo.args"
got=$(
  (
    _auth_install_if_missing() { :; }
    require_root() { :; }
    sudo() {
      case " $* " in
        *" mktemp "*) mktemp "$TMP/login.XXXXXX" ;;
        *" script "*) printf '%s\n' "$*" > "$SUDO_SPY" ;;
        *) : ;;
      esac
    }
    cmd_auth_login claude
  ) >/dev/null 2>&1
  cat "$SUDO_SPY" 2>/dev/null
)
if [[ "$got" == *"env CLAUDE_CODE_FULL_SIGN_IN_LINK=1 script "*"setup-token"* ]]; then
  ok_t "case 8: auth login claude runs setup-token with CLAUDE_CODE_FULL_SIGN_IN_LINK=1"
else
  bad_t "case 8: auth login claude runs setup-token with CLAUDE_CODE_FULL_SIGN_IN_LINK=1" "sudo: ${got:-<not called>}"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
