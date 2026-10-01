#!/usr/bin/env bash
# DIVE-5306 — a new standard or sandboxed claude seat starts on the LITE
# Telegram bot profile. Admin seats keep the stock bot, with no line at all.
#
# Create writes TELEGRAM_PROFILE=lite into the seat's channel .env through the
# same setter `agent config set telegram.profile=` uses (DIVE-5133). With no bot
# yet the line is staged, the DIVE-5227 way. The tier rule is one resolver,
# create_telegram_profile_default (lib/agent_setup.sh), and create is its only
# caller, so nothing later puts the default back.
#
# Contract pinned here:
#   R*  the resolver: standard/sandboxed -> lite; admin, beyond-admin, empty or
#       unknown -> nothing; an explicit --telegram-profile wins both ways; only
#       claude gets a profile.
#   C*  the REAL create call site, cut out of cmd_agent_create.sh and run
#       against the real setter: standard -> one lite line in a 0600 .env; admin
#       -> no .env written at all (same as before); explicit default on a
#       standard seat -> no line; with a token already written, the token stays.
#   L*  later events: `telegram.profile=default` removes the line and a token
#       rotation (the real writer) does not bring it back; a partner token push
#       that sends telegram.profile=lite (DIVE-5133) leaves exactly one line.
#   S*  static: the flag is parsed, validated, in usage; the call site sits
#       after the channel install loop; the resolver has exactly one caller.
#
# `sudo` is a runas-stripping shim, not a stub of the writer.
#
# Run: bash tests/agent_create_telegram_profile_default_unit.sh (no root, no network).
# TIER: core — 1.0s measured on the dev2 seat.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/tg-create-profile.XXXXXX)
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
systemd-run() { :; }
systemctl() { :; }
TYPE_CHANNELS=([claude]=1 [codex]=1 [grok]=1 [hermes]=1 [openclaw]=1)

envf() { printf '%s/home/agent-%s/.claude/channels/telegram/.env' "$TMP" "$1"; }
plines() { local n; n=$(grep -c '^TELEGRAM_PROFILE=' "$(envf "$1")" 2>/dev/null); printf '%s' "${n:-0}"; }

# ------------------------------------------------------------ R: the resolver
r() { create_telegram_profile_default "$@"; }
check_r() { # <label> <want> <args...>
  local label="$1" want="$2"; shift 2
  local got; got=$(r "$@")
  [[ "$got" == "$want" ]] && ok_t "$label" || bad_t "$label" "args=($*) want='$want' got='$got'"
}
check_r "R1 claude standard -> lite"                    lite claude standard ""
check_r "R2 claude sandboxed -> lite"                   lite claude sandboxed ""
check_r "R3 claude admin -> nothing (stock bot)"        ""   claude admin ""
check_r "R4 claude beyond-admin -> nothing"             ""   claude beyond-admin ""
check_r "R5 claude empty/unknown label -> nothing"      ""   claude "" ""
check_r "R6 explicit default on standard -> nothing"    ""   claude standard default
check_r "R7 explicit lite on admin -> lite"             lite claude admin lite
check_r "R8 codex standard -> nothing (no lite bridge)" ""   codex standard ""

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

create_block std claude standard ""
[[ "$(plines std)" == "1" && "$(grep '^TELEGRAM_PROFILE=' "$(envf std)")" == "TELEGRAM_PROFILE=lite" ]] \
  && ok_t "C1 a standard claude create writes TELEGRAM_PROFILE=lite (staged with no bot)" \
  || bad_t "C1 no lite line" "err=$(<"$TMP/err") env=$(cat "$(envf std)" 2>/dev/null)"
[[ "$(stat -c %a "$(envf std)" 2>/dev/null)" == "600" ]] \
  && ok_t "C2 the .env is 0600" || bad_t "C2 mode" "$(stat -c %a "$(envf std)" 2>/dev/null)"

create_block sbx claude sandboxed ""
[[ "$(plines sbx)" == "1" ]] \
  && ok_t "C3 a sandboxed claude create writes the lite line" || bad_t "C3 no line" "$(<"$TMP/err")"

create_block adm claude admin ""
[[ ! -e "$TMP/home/agent-adm/.claude/channels/telegram" ]] \
  && ok_t "C4 an admin create writes nothing (no telegram dir, no .env: same as before)" \
  || bad_t "C4 admin seat got a profile write" "$(ls -la "$TMP/home/agent-adm/.claude/channels/telegram" 2>&1; cat "$(envf adm)" 2>/dev/null)"

create_block opt claude standard default
[[ ! -e "$(envf opt)" ]] \
  && ok_t "C5 --telegram-profile=default on a standard create writes no line" \
  || bad_t "C5 explicit default ignored" "$(cat "$(envf opt)")"

create_block cdx codex standard ""
[[ ! -e "$TMP/home/agent-cdx" ]] \
  && ok_t "C6 a standard codex create writes nothing" || bad_t "C6 codex touched" ""

# With telegram attached at create, the token is already in the .env.
TOKEN1='1:aaaaaaaaaaaaaaaaaaaaaaaa'
mkdir -p "$(dirname "$(envf tok)")"
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN1" >"$(envf tok)"; chmod 600 "$(envf tok)"
create_block tok claude standard ""
[[ "$(plines tok)" == "1" && "$(grep -c "^TELEGRAM_BOT_TOKEN=$TOKEN1\$" "$(envf tok)")" == "1" ]] \
  && ok_t "C7 a standard create with a bot keeps the token and adds the lite line" \
  || bad_t "C7 token or profile wrong" "$(cat "$(envf tok)")"

# ------------------------------------------------------- L: later events
printf '%s' '{"agents":{"tok":{"type":"claude","channels":"telegram","isolation":"standard"}}}' >"$TMP/reg"
run_cfg() { ( JSON_MODE=1; cmd_config "$@" ) >"$TMP/out" 2>"$TMP/err"; echo $?; }
sed -n "/<<'CLAUDE_TELEGRAM_STATE'\$/,/^CLAUDE_TELEGRAM_STATE\$/p" "$SRC/lib/agent_setup.sh" \
  | sed '1d;$d' >"$TMP/token-writer.sh"

rc=$(run_cfg tok set telegram.profile=lite)
[[ "$rc" == "0" && "$(plines tok)" == "1" ]] \
  && ok_t "L1 a partner token push's telegram.profile=lite (DIVE-5133) leaves exactly one line" \
  || bad_t "L1 duplicate or failed" "rc=$rc err=$(<"$TMP/err") $(cat "$(envf tok)")"

rc=$(run_cfg tok set telegram.profile=default)
[[ "$rc" == "0" && "$(plines tok)" == "0" ]] \
  && ok_t "L2 a later telegram.profile=default on the standard seat removes the line" \
  || bad_t "L2 default not honoured" "rc=$rc $(cat "$(envf tok)")"
TOKEN2='2:bbbbbbbbbbbbbbbbbbbbbbbb'
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
