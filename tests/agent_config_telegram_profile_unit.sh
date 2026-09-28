#!/usr/bin/env bash
# DIVE-5133 — `agent config <name> set telegram.profile=lite telegram.account-url=<url>`
# puts a claude seat's Telegram bot in the partner-client LITE profile.
#
# The telegram plugin (DIVE-5121, 5dive-plugins#129) selects the profile from
# TELEGRAM_PROFILE=lite in ~/.claude/channels/telegram/.env and the /account
# button from TELEGRAM_ACCOUNT_URL there. Nothing on a box wrote either line, so
# the profile shipped and no partner box could run it. 5dive-api's managed-bot
# token push (DIVE-5109) now passes these two keys in the same config call as the
# token; this harness pins what the CLI does with them.
#
# THE RED ARM IS P1: on origin/main the call fails with "unknown config key".
#
# Contract pinned here:
#   - the two lines land in the SAME .env as the token, and the token survives;
#   - a later token rotation (the real writer, extracted from agent_setup.sh)
#     keeps them — the managed bot's token is rotated on teardown;
#   - `default` / empty REMOVES the line, so a box can go back to the stock bot;
#   - every refusal changes nothing (no accept-and-drop, DIVE-4413);
#   - a call without these keys leaves the .env byte-identical (default path).
#
# `sudo` is a runas-stripping shim, not a stub of the writer: the heredoc that
# rewrites the .env IS the thing under test.
#
# Run: bash tests/agent_config_telegram_profile_unit.sh (no root, no network).
# TIER: core — 0.7s measured.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/tg-profile.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/registry.sh lib/audit.sh \
         cmd_agent_runtime.sh cmd_agent_config.sh cmd_agent_pairing.sh; do
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

STATE_DIR="$TMP/state"; CONNECTORS_DIR="$TMP/connectors"
mkdir -p "$STATE_DIR" "$CONNECTORS_DIR"
HOME_SWAN="$TMP/home/agent-swan"
CH="$HOME_SWAN/.claude/channels/telegram"; mkdir -p "$CH"
ENVF="$CH/.env"
TOKEN1='1:aaaaaaaaaaaaaaaaaaaaaaaa'
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN1" >"$ENVF"; chmod 600 "$ENVF"
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN1" >"$CONNECTORS_DIR/telegram-swan.env"
URL='https://t.me/OinoaAppBot?startapp'

_tg_access_state_dir() {
  case "$2" in
    claude|codex|grok|pi) printf '%s/home/%s/.%s/channels/telegram' "$TMP" "$1" "$2" ;;
    *) return 1 ;;
  esac
}
sudo() { while [[ "${1:-}" == -* || "${1:-}" == "$(id -un)" ]]; do [[ "$1" == "-u" ]] && shift; shift; done; "$@"; }
step() { :; }
ensure_state() { :; }
audit_log() { :; }
write_agent_env() { :; }
registry_read() { cat "$TMP/reg"; }
registry_write() { cat >"$TMP/reg"; }
install_channel_for_agent() { :; }
fetch_bot_username() { return 1; }
systemd-run() { printf 'restart\n' >>"$TMP/restarts"; }
systemctl() { :; }

REG0='{"agents":{"swan":{"type":"claude","channels":"telegram"},"cdx":{"type":"codex","channels":"telegram"},"mute":{"type":"claude","channels":"none"}}}'
printf '%s' "$REG0" >"$TMP/reg"
TYPE_CHANNELS=([claude]=1 [codex]=1 [grok]=1 [hermes]=1 [openclaw]=1)

run_cfg() { ( JSON_MODE=1; cmd_config "$@" ) >"$TMP/out" 2>"$TMP/err"; echo $?; }
line() { grep -c "^$1=" "$ENVF" 2>/dev/null; }
val()  { grep "^$1=" "$ENVF" 2>/dev/null | head -1 | cut -d= -f2-; }

# ------------------------------------------------------------- P1: the write
: >"$TMP/restarts"
rc=$(run_cfg swan set telegram.profile=lite "telegram.account-url=$URL")
if [[ "$rc" != "0" ]]; then
  bad_t "P1 profile+account-url set on a claude telegram seat must succeed" "rc=$rc err=$(<"$TMP/err")"
else
  [[ "$(val TELEGRAM_PROFILE)" == "lite" && "$(val TELEGRAM_ACCOUNT_URL)" == "$URL" ]] \
    && ok_t "P1 TELEGRAM_PROFILE=lite and TELEGRAM_ACCOUNT_URL land in the channel .env (RED on main: unknown config key)" \
    || bad_t "P1 lines not written" "$(cat "$ENVF")"
fi
[[ "$(val TELEGRAM_BOT_TOKEN)" == "$TOKEN1" ]] \
  && ok_t "P2 the token line survives the profile write" \
  || bad_t "P2 token lost" "$(cat "$ENVF")"
[[ "$(stat -c %a "$ENVF")" == "600" ]] \
  && ok_t "P3 the .env stays 0600" || bad_t "P3 mode changed" "$(stat -c %a "$ENVF")"
applied=$(grep -o '"applied":\[[^]]*\]' "$TMP/out" 2>/dev/null)
[[ "$applied" == *'"telegram.profile"'* && "$applied" == *'"telegram.account-url"'* ]] \
  && ok_t "P4 both keys are reported in applied" || bad_t "P4 applied keys" "out=$(<"$TMP/out")"
[[ -s "$TMP/restarts" ]] \
  && ok_t "P5 the agent is restarted, so the bot re-pushes its command menu" \
  || bad_t "P5 no restart fired" ""

# ----------------------------------------------- P6: re-set is one line each
run_cfg swan set telegram.profile=lite "telegram.account-url=$URL" >/dev/null
[[ "$(line TELEGRAM_PROFILE)" == "1" && "$(line TELEGRAM_ACCOUNT_URL)" == "1" ]] \
  && ok_t "P6 re-running the set keeps exactly one line per key" \
  || bad_t "P6 duplicated lines" "$(cat "$ENVF")"

# ---------------- P7: a token rotation (the REAL writer) keeps the profile
# The managed bot's token is rotated on teardown and re-pushed; the claude
# installer's .env rewrite must strip only TELEGRAM_BOT_TOKEN.
sed -n "/<<'CLAUDE_TELEGRAM_STATE'\$/,/^CLAUDE_TELEGRAM_STATE\$/p" "$SRC/lib/agent_setup.sh" \
  | sed '1d;$d' >"$TMP/token-writer.sh"
TOKEN2='2:bbbbbbbbbbbbbbbbbbbbbbbb'
if [[ -s "$TMP/token-writer.sh" ]] && HOME="$HOME_SWAN" TOKEN="$TOKEN2" bash "$TMP/token-writer.sh"; then
  [[ "$(val TELEGRAM_BOT_TOKEN)" == "$TOKEN2" && "$(val TELEGRAM_PROFILE)" == "lite" && "$(val TELEGRAM_ACCOUNT_URL)" == "$URL" ]] \
    && ok_t "P7 a token rotation through the real claude .env writer keeps the lite lines" \
    || bad_t "P7 rotation dropped a line" "$(cat "$ENVF")"
else
  bad_t "P7 could not extract/run the token writer from agent_setup.sh" ""
fi

# ---------------------------- P8: a call without the keys leaves the .env alone
before=$(sha256sum <"$ENVF")
run_cfg swan set telegram.allowed-users=12345 >/dev/null
[[ "$(sha256sum <"$ENVF")" == "$before" ]] \
  && ok_t "P8 a config set without the profile keys leaves the .env byte-identical" \
  || bad_t "P8 default path touched the .env" "$(cat "$ENVF")"

# ------------------------------------------- P9/P10: back to the stock bot
rc=$(run_cfg swan set telegram.profile=default)
[[ "$rc" == "0" && "$(line TELEGRAM_PROFILE)" == "0" && "$(val TELEGRAM_ACCOUNT_URL)" == "$URL" ]] \
  && ok_t "P9 telegram.profile=default removes the line (the plugin's unset = default)" \
  || bad_t "P9 default did not remove" "rc=$rc $(cat "$ENVF")"
rc=$(run_cfg swan set telegram.account-url=)
[[ "$rc" == "0" && "$(line TELEGRAM_ACCOUNT_URL)" == "0" && "$(val TELEGRAM_BOT_TOKEN)" == "$TOKEN2" ]] \
  && ok_t "P10 an empty telegram.account-url removes the line and keeps the token" \
  || bad_t "P10 empty url did not remove" "rc=$rc $(cat "$ENVF")"

# ------------------------------------------------ P11-P15: refusals change nothing
run_cfg swan set telegram.profile=lite "telegram.account-url=$URL" >/dev/null
snap_env=$(sha256sum <"$ENVF"); snap_reg=$(sha256sum <"$TMP/reg")
refuse() { # <label> <pattern> <args...>
  local label="$1" pat="$2"; shift 2
  local rc; rc=$(run_cfg "$@")
  if [[ "$rc" != "0" ]] && grep -q -- "$pat" "$TMP/err" \
      && [[ "$(sha256sum <"$ENVF")" == "$snap_env" && "$(sha256sum <"$TMP/reg")" == "$snap_reg" ]]; then
    ok_t "$label"
  else
    bad_t "$label" "rc=$rc err=$(<"$TMP/err")"
  fi
}
refuse "P11 an unknown profile value is refused" "allowed: lite, default" swan set telegram.profile=Lite
refuse "P12 an http:// account URL is refused" "https:// or tg://" swan set telegram.account-url=http://x.example
refuse "P13 a URL carrying a newline is refused (no second key smuggled into the .env)" "https:// or tg://" \
  swan set "telegram.account-url=https://x.example
TELEGRAM_PROFILE=default"
refuse "P14 a codex seat is refused, naming why (its bridge has no lite profile)" "claude-only" cdx set telegram.profile=lite
refuse "P15 a claude seat with no telegram channel refuses before any write" "require channels=telegram" mute set telegram.profile=lite
[[ ! -e "$TMP/home/agent-mute" ]] \
  && ok_t "P16 the refused seat got no channel dir created" || bad_t "P16 dir created on refusal" ""

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
