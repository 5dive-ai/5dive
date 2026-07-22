#!/usr/bin/env bash
# DIVE-1768: send_welcome_message must NOT swallow Telegram's 403 for a chat that
# has never opened the bot (auto-paired owner / CoS-create). curl exits 0 on an
# HTTP 403, so the old `-o /dev/null … || warn` reported nothing actionable. The
# fix reads the JSON body: on the unreachable-bot case it emits an open-your-bot
# nudge and returns 3; a real send returns 0; any other API error returns 1.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/welcome-403.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh cmd_agent_pairing.sh; do
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; ENV_DIR="$STATE_DIR/agents.d"; mkdir -p "$ENV_DIR"
account_signin_detail() { echo '{}'; }   # provider probe stub (unused here)

# curl stub: branch on the endpoint in the arg list. $CURL_MODE selects the
# sendMessage response; getMe always returns a username so the nudge can name it.
CURL_MODE="ok"
curl() {
  local args="$*"
  if [[ "$args" == *"/getMe"* ]]; then
    printf '{"ok":true,"result":{"username":"acme_bot"}}\n'; return 0
  fi
  case "$CURL_MODE" in
    ok)      printf '{"ok":true,"result":{"message_id":1}}\n' ;;
    forbid)  printf '{"ok":false,"error_code":403,"description":"Forbidden: bot can'"'"'t initiate conversation with a user"}\n' ;;
    nochat)  printf '{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}\n' ;;
    other)   printf '{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 5"}\n' ;;
  esac
  return 0
}

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

run() { CURL_MODE="$1"; ERR=$(send_welcome_message "12345" "tok" "acme" "claude" 2>&1 >/dev/null); RC=$?; }

# 1) happy path: real send returns 0, no nudge
run ok
[[ "$RC" -eq 0 ]] && ok_t "success: returns 0" || bad_t "success rc" "rc=$RC"
grep -qi "ACTION:" <<<"$ERR" && bad_t "success: no nudge on real send" "$ERR" || ok_t "success: no spurious nudge"

# 2) 403 bot-can't-initiate: rc 3 + actionable nudge naming the bot
run forbid
[[ "$RC" -eq 3 ]] && ok_t "403: returns 3 (pending nudge)" || bad_t "403 rc" "rc=$RC err=$ERR"
grep -qi "ACTION: open Telegram" <<<"$ERR" && ok_t "403: emits open-your-bot ACTION nudge" || bad_t "403 nudge" "$ERR"
grep -q "@acme_bot" <<<"$ERR" && ok_t "403: names the bot via getMe (@acme_bot)" || bad_t "403 bot name" "$ERR"

# 3) chat not found: same unreachable class -> rc 3 + nudge
run nochat
[[ "$RC" -eq 3 ]] && ok_t "chat-not-found: returns 3" || bad_t "nochat rc" "rc=$RC err=$ERR"
grep -qi "ACTION:" <<<"$ERR" && ok_t "chat-not-found: nudge present" || bad_t "nochat nudge" "$ERR"

# 4) unrelated API error (429): rc 1, plain warn, NO open-your-bot nudge
run other
[[ "$RC" -eq 1 ]] && ok_t "other error: returns 1 (not the nudge path)" || bad_t "other rc" "rc=$RC err=$ERR"
grep -qi "ACTION: open Telegram" <<<"$ERR" && bad_t "other error: must NOT emit open-your-bot nudge" "$ERR" || ok_t "other error: no misleading nudge"

# 5) no em-dash in the operator-facing nudge (public-copy rule)
run forbid
grep -q -- "—" <<<"$ERR" && bad_t "nudge: NO em-dash (public-copy rule)" "$ERR" || ok_t "nudge: em-dash-free"

printf '\nDIVE-1768 welcome 403 nudge: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
