#!/usr/bin/env bash
# DIVE-1767: regression coverage for cmd_pair's single-channel resolution
# BELOW the DIVE-1762 membership guard.
#
#   DIVE-1762 (be0708d) fixed the *guard* to accept a comma-separated channel
#   list, but the code below it still exact-matched the whole $channels string
#   for token_env/token_var, the access.json path, and the auto-pair state dir.
#   So a real telegram,dashboard agent (the default claude combo the fix
#   targeted) got past the guard and then died with `token_var: unbound` /
#   "no bot token for agent ... telegram,dashboard.token".
#
#   The fix resolves ONE pairable channel (telegram precedence, else discord)
#   and uses THAT for token env/var, access path, and the state dir. This test
#   drives the non-interactive auto-pair branch and asserts the resolved state
#   dir is the single-channel path and that the token lookup finds the
#   telegram-<name>.env / discord-<name>.env file (not a telegram,dashboard one).
#
# Sources src/ directly and stubs every side effect — no root, network,
# credentials, users, registry, or live state is touched.
set -euo pipefail

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
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/cmd_agent_pairing.sh
# shellcheck disable=SC1091
[[ -n "${E_PAIRING:-}" ]] || source src/lib/error_codes.sh   # DIVE-7101: the openclaw arms reach fail()
declare -F fail >/dev/null || source src/lib/output.sh

pass=0
ok_()  { pass=$((pass+1)); }
die()  { echo "FAIL: $*" >&2; exit 1; }

ensure_state() { :; }

# Drive cmd_pair's auto-pair branch for one channels value and echo the STATE
# dir the seed step targeted plus whether the telegram welcome fired. A bot
# token env is planted for BOTH channels so the token lookup only succeeds if
# the code resolved the correct single channel (telegram-qa.env / discord-qa.env
# — never a bogus "telegram,dashboard-qa.env").
run_pair() {
  local ch="$1"
  local tmp; tmp=$(mktemp -d)
  printf 'TELEGRAM_BOT_TOKEN=tok-tg\n' > "$tmp/telegram-qa.env"
  printf 'DISCORD_BOT_TOKEN=tok-dc\n'  > "$tmp/discord-qa.env"
  (
    CONNECTORS_DIR="$tmp"
    JSON_MODE=0
    registry_read() { jq -cn --arg c "$ch" '{agents:{qa:{type:"claude", channels:$c}}}'; }
    # Capture the STATE dir the seed hands to python; swallow the heredoc stdin.
    sudo() { local a; for a in "$@"; do case "$a" in STATE=*) echo "STATE:${a#STATE=}";; esac; done; cat >/dev/null 2>&1 || true; return 0; }
    _operator_record() { :; }
    send_welcome_message() { echo "WELCOME"; }
    ok() { :; }
    cmd_pair qa --user-id=42 2>&1 || echo "ERR:$?"
  )
  rm -rf "$tmp"
}

# telegram,dashboard (both orders) and plain telegram -> state dir on telegram,
# token found, welcome fires.
for ch in "telegram,dashboard" "dashboard,telegram" "telegram"; do
  out=$(run_pair "$ch")
  [[ "$out" == *"STATE:/home/agent-qa/.claude/channels/telegram"* ]] \
    || die "channels='$ch' should seed the telegram state dir, got: $out"
  ok_
  [[ "$out" != *"STATE:/home/agent-qa/.claude/channels/telegram,"* ]] \
    || die "channels='$ch' leaked the raw comma-list into the state path: $out"
  ok_
  [[ "$out" == *"WELCOME"* ]] \
    || die "channels='$ch' should fire the telegram welcome, got: $out"
  ok_
  [[ "$out" != *"ERR:"* ]] \
    || die "channels='$ch' should not error (token/var resolution), got: $out"
  ok_
done

# discord,dashboard (both orders) -> state dir on discord, no telegram welcome.
for ch in "discord,dashboard" "dashboard,discord"; do
  out=$(run_pair "$ch")
  [[ "$out" == *"STATE:/home/agent-qa/.claude/channels/discord"* ]] \
    || die "channels='$ch' should seed the discord state dir, got: $out"
  ok_
  [[ "$out" != *"WELCOME"* ]] \
    || die "channels='$ch' (discord) should not fire the telegram welcome, got: $out"
  ok_
  [[ "$out" != *"ERR:"* ]] \
    || die "channels='$ch' should not error (token/var resolution), got: $out"
  ok_
done

# DIVE-7101: an openclaw bot answers a stranger with "Pairing code: XXXXXXXX …
# openclaw pairing approve telegram XXXXXXXX". cmd_pair refused openclaw
# outright, so a chat-only owner had no way in but a terminal or a timed
# listening window. Now `agent pair <openclaw> --code=` runs openclaw's own
# approve AS THE SEAT and records the sender as a box operator.
run_pair_oc() { # <approve-rc> <approve-output> <cmd_pair args...>
  local arc="$1" aout="$2"; shift 2
  local tmp; tmp=$(mktemp -d)
  printf 'TELEGRAM_BOT_TOKEN=tok-tg\n' > "$tmp/telegram-qa.env"
  (
    CONNECTORS_DIR="$tmp"
    JSON_MODE=0
    registry_read() { jq -cn '{agents:{qa:{type:"openclaw", channels:"telegram"}}}'; }
    id() { return 0; }
    sudo() { echo "SUDO:$*" >> "$tmp/argv"; printf '%s\n' "$aout"; return "$arc"; }
    _operator_record() { echo "OPERATOR:$1"; }
    _pair_record_human() { :; }
    send_welcome_message() { echo "WELCOME:$1" >> "$tmp/argv"; }
    ok() { echo "OK:$1"; }
    cmd_pair qa "$@" 2>&1 || echo "ERR:$?"
    cat "$tmp/argv" 2>/dev/null || true
  )
  rm -rf "$tmp"
}
out=$(run_pair_oc 0 $'\e[32mApproved\e[0m telegram sender 1234567890.' --code=C3NCY8GH)
[[ "$out" == *"SUDO:-u agent-qa -H "*" pairing approve telegram C3NCY8GH"* ]] \
  || die "openclaw --code must run openclaw's own approve as the seat, got: $out"
ok_
[[ "$out" == *"OPERATOR:1234567890"* && "$out" == *"WELCOME:1234567890"* ]] \
  || die "openclaw pair must record the approved sender as an operator and welcome them, got: $out"
ok_
[[ "$out" == *"OK:agent 'qa' paired with Telegram user 1234567890"* && "$out" != *"ERR:"* ]] \
  || die "openclaw pair should succeed, got: $out"
ok_
out=$(run_pair_oc 1 'Error: No pending pairing request found for code "ZZZZ9999".' --code=ZZZZ9999)
[[ "$out" == *"no pending request for code ZZZZ9999"* && "$out" != *"OK:"* ]] \
  || die "an unknown code must fail and say so, got: $out"
ok_
out=$(run_pair_oc 0 'unused')
[[ "$out" == *"--code=<the code in its reply>"* && "$out" != *"SUDO:"* ]] \
  || die "openclaw with no code must say how to get one and run nothing, got: $out"
ok_
out=$(run_pair_oc 0 'unused' '--code=a;b')
[[ "$out" == *"invalid --code"* && "$out" != *"SUDO:"* ]] \
  || die "a code that is not letters/digits must be refused before any exec, got: $out"
ok_

echo "OK: dive1767_regression_unit — $pass assertions passed"
