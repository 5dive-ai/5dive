#!/usr/bin/env bash
# DIVE-5133 / DIVE-5306 — `agent config <name> set telegram.profile=lite telegram.account-url=<url>`
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
# TIER: core — 2.7s measured on the dev2 seat (best of 3, loaded box), P* plus the folded-in DIVE-5306 create arms.
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
URL='https://t.me/AcmeAppBot?startapp'

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
sed -n "/<<'CLAUDE_TELEGRAM_STATE'/,/^CLAUDE_TELEGRAM_STATE\$/p" "$SRC/lib/agent_setup.sh" \
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
refuse "P15 an account URL on a claude seat with no telegram channel refuses before any write" \
  "requires channels=telegram" mute set "telegram.account-url=$URL"
refuse "P15b profile + account URL together on that seat refuse as a whole (no half write)" \
  "requires channels=telegram" mute set telegram.profile=lite "telegram.account-url=$URL"
[[ ! -e "$TMP/home/agent-mute" ]] \
  && ok_t "P16 the refused seat got no channel dir created" || bad_t "P16 dir created on refusal" ""

# ------------- P17-P20 (DIVE-5227): profile alone is STAGED on a seat with no bot
# A Mini App hire picks the profile at hire time; the bot is connected later.
MUTE_ENV="$TMP/home/agent-mute/.claude/channels/telegram/.env"
rc=$(run_cfg mute set telegram.profile=lite)
[[ "$rc" == "0" && "$(grep -c '^TELEGRAM_PROFILE=lite$' "$MUTE_ENV" 2>/dev/null)" == "1" ]] \
  && ok_t "P17 telegram.profile=lite on a claude seat with no bot stages the line (RED on main: require channels=telegram)" \
  || bad_t "P17 profile not staged" "rc=$rc err=$(<"$TMP/err") env=$(cat "$MUTE_ENV" 2>/dev/null)"
[[ "$(jq -r '.agents.mute.channels' "$TMP/reg")" == "none" ]] \
  && ok_t "P18 staging does not attach a channel (channels stays none)" \
  || bad_t "P18 channels changed" "$(cat "$TMP/reg")"
[[ "$(stat -c %a "$MUTE_ENV" 2>/dev/null)" == "600" ]] \
  && ok_t "P19 the staged .env is 0600" || bad_t "P19 mode" "$(stat -c %a "$MUTE_ENV" 2>/dev/null)"
# The later connect: the REAL claude token writer, as `channels=telegram telegram.token=-` runs it.
TOKEN3='3:cccccccccccccccccccccccc'
if [[ -s "$TMP/token-writer.sh" ]] && HOME="$TMP/home/agent-mute" TOKEN="$TOKEN3" bash "$TMP/token-writer.sh"; then
  [[ "$(grep -c '^TELEGRAM_PROFILE=lite$' "$MUTE_ENV")" == "1" && "$(grep '^TELEGRAM_BOT_TOKEN=' "$MUTE_ENV" | cut -d= -f2-)" == "$TOKEN3" ]] \
    && ok_t "P20 connecting the bot later (the real token writer) keeps the staged lite line" \
    || bad_t "P20 connect dropped the staged line" "$(cat "$MUTE_ENV")"
else
  bad_t "P20 could not run the token writer" ""
fi
rc=$(run_cfg mute set telegram.profile=default)
[[ "$rc" == "0" && "$(grep -c '^TELEGRAM_PROFILE=' "$MUTE_ENV")" == "0" ]] \
  && ok_t "P21 telegram.profile=default un-stages it" \
  || bad_t "P21 default did not remove" "rc=$rc $(cat "$MUTE_ENV")"

# =====================================================================
# DIVE-5306 — create-time default: a new SANDBOXED claude seat starts on the
# LITE profile; standard and admin seats keep the stock bot, with no line
# (lodar 2026-10-01 07:54Z narrowed it from standard+sandboxed: standard is the
# default tier for every seat after a box's first).
# Folded in from agent_create_telegram_profile_default_unit.sh (same subject,
# same setter; one harness keeps the core shard budget). Create writes the line
# through set_claude_telegram_env_key, the setter P1-P21 pin above; with no bot
# it is staged the DIVE-5227 way. The tier rule is one resolver,
# create_telegram_profile_default (lib/agent_setup.sh), and create is its only
# caller, so nothing later puts the default back.
#   R*  the resolver: sandboxed -> lite; standard, admin, beyond-admin, empty
#       or unknown -> nothing; an explicit --telegram-profile wins both ways; only
#       claude gets a profile.
#   C*  the REAL create call site, cut out of cmd_agent_create.sh and run
#       against the real setter: sandboxed -> one lite line in a 0600 .env;
#       standard and admin -> no .env written at all (same as before); explicit
#       default on a sandboxed seat -> no line; with a token already written,
#       the token stays.
#       RED CONTROL: replace the set_claude_telegram_env_key line in the create
#       block with `:` -> 4 FAIL (C0 C1 C2 C7).
#   L*  later events: `telegram.profile=default` removes the line and a token
#       rotation (the real writer) does not bring it back; a partner token push
#       that sends telegram.profile=lite (DIVE-5133) leaves exactly one line.
#   S*  static: the flag is parsed, validated, in usage; the call site sits
#       after the channel install loop; the resolver has exactly one caller.
# =====================================================================
envf() { printf '%s/home/agent-%s/.claude/channels/telegram/.env' "$TMP" "$1"; }
plines() { local n; n=$(grep -c '^TELEGRAM_PROFILE=' "$(envf "$1")" 2>/dev/null); printf '%s' "${n:-0}"; }

# ------------------------------------------------------------ R: the resolver
r() { create_telegram_profile_default "$@"; }
check_r() { # <label> <want> <args...>
  local label="$1" want="$2"; shift 2
  local got; got=$(r "$@")
  [[ "$got" == "$want" ]] && ok_t "$label" || bad_t "$label" "args=($*) want='$want' got='$got'"
}
check_r "R1 claude standard -> nothing (stock bot)"     ""   claude standard ""
check_r "R2 claude sandboxed -> lite"                   lite claude sandboxed ""
check_r "R3 claude admin -> nothing (stock bot)"        ""   claude admin ""
check_r "R4 claude beyond-admin -> nothing"             ""   claude beyond-admin ""
check_r "R5 claude empty/unknown label -> nothing"      ""   claude "" ""
check_r "R6 explicit default on sandboxed -> nothing"   ""   claude sandboxed default
check_r "R7 explicit lite on admin -> lite"             lite claude admin lite
check_r "R8 codex sandboxed -> nothing (no lite bridge)" ""  codex sandboxed ""
check_r "R9 explicit lite on standard -> lite"         lite claude standard lite

# ----------------------------------------- C: the real create call site
# Cut the block out of cmd_create, from its `local` to the closing `fi`, so the
# harness runs the shipped lines, not a copy of them.
sed -n '/^  local _tg_create_profile$/,/^  fi$/p' "$SRC/cmd_agent_create.sh" >"$TMP/create-block.sh"
if [[ ! -s "$TMP/create-block.sh" ]] || ! grep -q 'set_claude_telegram_env_key' "$TMP/create-block.sh"; then
  bad_t "C0 could not extract the create-time profile block from cmd_agent_create.sh" ""
fi
sed -i 's/^  local /  /' "$TMP/create-block.sh"
create_block() { # <name> <type> <isolation> <explicit>
  ( name="$1" type="$2" isolation="$3" telegram_profile="$4"
    # shellcheck disable=SC1090
    source "$TMP/create-block.sh" ) >/dev/null 2>"$TMP/err"
}

create_block sbx claude sandboxed ""
[[ "$(plines sbx)" == "1" && "$(grep '^TELEGRAM_PROFILE=' "$(envf sbx)")" == "TELEGRAM_PROFILE=lite" ]] \
  && ok_t "C1 a sandboxed claude create writes TELEGRAM_PROFILE=lite (staged with no bot)" \
  || bad_t "C1 no lite line" "err=$(<"$TMP/err") env=$(cat "$(envf sbx)" 2>/dev/null)"
[[ "$(stat -c %a "$(envf sbx)" 2>/dev/null)" == "600" ]] \
  && ok_t "C2 the .env is 0600" || bad_t "C2 mode" "$(stat -c %a "$(envf sbx)" 2>/dev/null)"

create_block std claude standard ""
[[ ! -e "$TMP/home/agent-std/.claude/channels/telegram" ]] \
  && ok_t "C3 a standard claude create writes nothing (stock bot, same as before DIVE-5306)" \
  || bad_t "C3 standard seat got a profile write" "$(cat "$(envf std)" 2>/dev/null)"

create_block adm claude admin ""
[[ ! -e "$TMP/home/agent-adm/.claude/channels/telegram" ]] \
  && ok_t "C4 an admin create writes nothing (no telegram dir, no .env: same as before)" \
  || bad_t "C4 admin seat got a profile write" "$(ls -la "$TMP/home/agent-adm/.claude/channels/telegram" 2>&1; cat "$(envf adm)" 2>/dev/null)"

create_block opt claude sandboxed default
[[ ! -e "$(envf opt)" ]] \
  && ok_t "C5 --telegram-profile=default on a sandboxed create writes no line" \
  || bad_t "C5 explicit default ignored" "$(cat "$(envf opt)")"

create_block cdxnew codex sandboxed ""
[[ ! -e "$TMP/home/agent-cdxnew" ]] \
  && ok_t "C6 a sandboxed codex create writes nothing" || bad_t "C6 codex touched" ""

# With telegram attached at create, the token is already in the .env.
mkdir -p "$(dirname "$(envf tok)")"
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN1" >"$(envf tok)"; chmod 600 "$(envf tok)"
create_block tok claude sandboxed ""
[[ "$(plines tok)" == "1" && "$(grep -c "^TELEGRAM_BOT_TOKEN=$TOKEN1\$" "$(envf tok)")" == "1" ]] \
  && ok_t "C7 a sandboxed create with a bot keeps the token and adds the lite line" \
  || bad_t "C7 token or profile wrong" "$(cat "$(envf tok)")"

# ------------------------------------------------------- L: later events
printf '%s' '{"agents":{"tok":{"type":"claude","channels":"telegram","isolation":"sandboxed"}}}' >"$TMP/reg"

rc=$(run_cfg tok set telegram.profile=lite)
[[ "$rc" == "0" && "$(plines tok)" == "1" ]] \
  && ok_t "L1 a partner token push's telegram.profile=lite (DIVE-5133) leaves exactly one line" \
  || bad_t "L1 duplicate or failed" "rc=$rc err=$(<"$TMP/err") $(cat "$(envf tok)")"

rc=$(run_cfg tok set telegram.profile=default)
[[ "$rc" == "0" && "$(plines tok)" == "0" ]] \
  && ok_t "L2 a later telegram.profile=default on the sandboxed seat removes the line" \
  || bad_t "L2 default not honoured" "rc=$rc $(cat "$(envf tok)")"
if [[ -s "$TMP/token-writer.sh" ]] && HOME="$TMP/home/agent-tok" TOKEN="$TOKEN2" bash "$TMP/token-writer.sh"; then
  [[ "$(plines tok)" == "0" && "$(grep -c "^TELEGRAM_BOT_TOKEN=$TOKEN2\$" "$(envf tok)")" == "1" ]] \
    && ok_t "L3 a token rotation after that does not bring lite back" \
    || bad_t "L3 rotation re-applied the default" "$(cat "$(envf tok)")"
else
  bad_t "L3 could not extract/run the token writer from agent_setup.sh" ""
fi
before=$(sha256sum <"$(envf tok)")
run_cfg tok set telegram.allowed-users=12345 >/dev/null
[[ "$(sha256sum <"$(envf tok)")" == "$before" ]] \
  && ok_t "L4 an unrelated config set leaves the opted-out .env byte-identical" \
  || bad_t "L4 config re-applied something" "$(cat "$(envf tok)")"

# ------------------------------------------------------------ S: static
C="$SRC/cmd_agent_create.sh"
grep -qF -- '--telegram-profile=*)' "$C" \
  && ok_t "S1 create parses --telegram-profile=" || bad_t "S1 flag not parsed" ""
{ grep -qF -- "invalid --telegram-profile" "$C" && grep -qF -- "--telegram-profile is claude-only" "$C"; } \
  && ok_t "S2 create refuses a bad value and a non-claude type" || bad_t "S2 validation missing" ""
grep -qF -- '[--telegram-profile=lite|default]' "$C" \
  && ok_t "S3 the usage string names the flag" || bad_t "S3 usage" ""
loop_ln=$(grep -n 'install_channel_for_agent "$type" buzz "$name" ""' "$C" | head -1 | cut -d: -f1)
call_ln=$(grep -n 'create_telegram_profile_default "$type" "$isolation" "$telegram_profile"' "$C" | head -1 | cut -d: -f1)
env_ln=$(grep -n 'write_agent_env "$name" "$type" "$channels"' "$C" | head -1 | cut -d: -f1)
[[ -n "$loop_ln" && -n "$call_ln" && -n "$env_ln" ]] && (( loop_ln < call_ln && call_ln < env_ln )) \
  && ok_t "S4 the profile write runs after the channel install loop (token first) and before the seat starts" \
  || bad_t "S4 call site order" "loop=$loop_ln call=$call_ln env=$env_ln"
callers=$(grep -rn 'create_telegram_profile_default ' "$SRC" | grep -v -E '^[^:]+:[0-9]+:\s*#' | grep -vc 'create_telegram_profile_default() {')
[[ "$callers" == "1" ]] \
  && ok_t "S5 the default has exactly one caller (create), so no later event re-applies it" \
  || bad_t "S5 caller count" "$(grep -rn 'create_telegram_profile_default' "$SRC")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
