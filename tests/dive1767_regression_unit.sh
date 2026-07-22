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
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/cmd_agent_pairing.sh

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

echo "OK: dive1767_regression_unit — $pass assertions passed"
