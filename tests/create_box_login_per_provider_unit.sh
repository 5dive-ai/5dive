#!/usr/bin/env bash
# DIVE-7084 — one sign-in per provider per box. On a self-hosted box (2026-10-27)
# the owner asked Olivia to hire one agent on Grok and one on Codex. He signed in
# to both providers once, and each hire then came up with its own empty login and
# a second device link for the same account: 4 sign-ins for 2 agents. A lead names
# an account on every hire (a Claude account, the demo AI, or a new one named
# after the hire), and an account with no sign-in for that provider is a new link.
# Graded on box fixtures through the real cmd_create, stopped where the agent
# user would be made:
#   1. the rule: which account holds a codex/grok sign-in (a Claude key does not);
#   2. an agent's hire uses the box's login: codex, grok, two hires in a row;
#   3. the overrides: --own-login, the owner's own surfaces, a box with no login.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/lib/models.sh
# shellcheck disable=SC1091
source src/lib/agent_setup.sh
STATE_DIR="$(mktemp -d)"   # cmd_auth.sh reads it at source time; never the live /var/lib/5dive
# shellcheck disable=SC1091
source src/cmd_auth.sh
# shellcheck disable=SC1091
source src/cmd_agent_create.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

TMP=$(mktemp -d); rm -rf "$STATE_DIR"
AUTH_PROFILES_DIR="$TMP/auth-profiles"
CONNECTORS_DIR="$TMP/connectors"
HOMEDIR="$TMP/home-claude"
# The shared logins live in the fixture, never in the host's /home/claude.
TYPE_AUTH[claude]="$CONNECTORS_DIR/anthropic.env:CLAUDE_CODE_OAUTH_TOKEN"
TYPE_AUTH[codex]="$HOMEDIR/.codex/auth.json"
TYPE_AUTH[grok]="$HOMEDIR/.grok/auth.json"
mkdir -p "$TMP/bin"
for _t in claude codex grok; do
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$_t"; chmod +x "$TMP/bin/$_t"
  TYPE_BIN[$_t]="$TMP/bin/$_t"
done
cmd_install() { printf 'INSTALL-ATTEMPTED %s\n' "$*"; return 1; }
export FIVEDIVE_CHAT_ONLY_MARK="$TMP/chat-only"
export FIVE_GROK_ARM_MARKER="$TMP/grok-unfreeze"; : > "$FIVE_GROK_ARM_MARKER"
OAUTH='{"auth_mode":"chatgpt","tokens":{"refresh_token":"fixture"}}'

# box [shared:<type>]... [<acct>:claude|<acct>:codex|<acct>:grok|<acct>:demo|<acct>:]...
box() {
  rm -rf "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR" "$HOMEDIR"
  mkdir -p "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR" "$HOMEDIR"
  local a n k
  for a in "$@"; do
    n="${a%%:*}"; k="${a#*:}"
    if [[ "$n" == shared ]]; then
      mkdir -p "$HOMEDIR/.$k"; printf '%s\n' "$OAUTH" > "$HOMEDIR/.$k/auth.json"; continue
    fi
    mkdir -p "$AUTH_PROFILES_DIR/$n"; : > "$AUTH_PROFILES_DIR/$n/combined.env"
    case "$k" in
      claude) echo 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-fixture' > "$AUTH_PROFILES_DIR/$n/combined.env" ;;
      demo)   echo 'ANTHROPIC_AUTH_TOKEN=sk-or-v1-fixturedemo' > "$AUTH_PROFILES_DIR/$n/combined.env" ;;
      codex)  mkdir -p "$AUTH_PROFILES_DIR/$n/codex"; printf '%s\n' "$OAUTH" > "$AUTH_PROFILES_DIR/$n/codex/auth.json" ;;
      grok)   mkdir -p "$AUTH_PROFILES_DIR/$n/grok/.grok"; printf '%s\n' "$OAUTH" > "$AUTH_PROFILES_DIR/$n/grok/.grok/auth.json" ;;
      openai) echo 'OPENAI_API_KEY=sk-fixture-openai' > "$AUTH_PROFILES_DIR/$n/combined.env" ;;
    esac
  done
}
has() { _create_has_login "$@" && echo yes || echo no; }
rule() { _create_sole_account "$1" || echo none; }

echo '== 1. the rule =='
box mp:claude
eq_t 'a Claude account is not signed in to Codex' no "$(has codex mp)"
eq_t 'nor to Grok' no "$(has grok mp)"
eq_t 'it is still signed in to Claude' yes "$(has claude mp)"
eq_t 'so a codex seat never takes it as the one login' none "$(rule codex)"
box mp:claude gpt:codex
eq_t 'an account with a Codex sign-in is one' yes "$(has codex gpt)"
eq_t 'and is the box login for a codex seat' gpt "$(rule codex)"
box gpt:openai
eq_t 'an OpenAI key in the account counts for Codex' yes "$(has codex gpt)"
box x:grok
eq_t 'an account with a Grok sign-in is the box login for grok' x "$(rule grok)"
box shared:codex gpt:codex
eq_t 'the shared login is there: seats keep using it' none "$(rule codex)"
eq_t 'and it is a codex login' yes "$(has codex)"
box marcus:
eq_t "an empty account named after a hire is not a login" no "$(has codex marcus)"
[[ -d "$AUTH_PROFILES_DIR/marcus/codex" ]] \
  && bad_t 'reading the rule made a codex dir in the account' || ok_t 'reading the rule makes no dir'

echo '== 2. an agent hire uses the box login =='
require_root() { :; }
ensure_state() { :; }
registry_read() { printf '%s\n' '{"agents":{}}'; }
actor_routing_agent() { return 1; }
step() { printf 'STEP: %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
CALLER=agent
_create_caller_is_agent() { [[ "$CALLER" == agent ]]; }
create_agent_user() { printf 'REACHED profile=%s defer=%s\n' "$profile" "$defer_auth"; exit 0; }
made() {
  local out; out=$( ( cmd_create "$@" ) 2>&1 )
  [[ -n "${DBG:-}" ]] && printf "%s\n" "$out" >&2
  printf '%s' "$out" > "$TMP/last.log"
  grep -m1 '^REACHED ' <<<"$out" | sed 's/^REACHED //' || true
  grep -q '^REACHED ' <<<"$out" || grep -m1 -oE 'not authenticated|not configured|free demo AI|needs --auth-profile' <<<"$out" || echo '(refused)'
}

# lodar's box after one Codex and one Grok sign-in from Olivia's links.
box shared:codex shared:grok mp:claude demo-ai:demo
eq_t 'codex hire on an account named after it (the demo-AI hint): box login' \
  'profile= defer=0' "$(made marcus --type=codex --auth-profile=marcus --defer-auth)"
grep -qF "has no codex sign-in: using this box's codex login" "$TMP/last.log" \
  && ok_t 'create says it used the box login' || bad_t 'create did not say which login' "$(cat "$TMP/last.log")"
grep -q 'deferred' "$TMP/last.log" && bad_t 'a deferral was still reported' "$(cat "$TMP/last.log")" \
  || ok_t 'no "deferred" in its output'
eq_t 'a second codex hire: the same login, no second link' \
  'profile= defer=0' "$(made ward --type=codex --auth-profile=ward --defer-auth)"
eq_t 'codex hire on the Claude account (5dive account list): box login' \
  'profile= defer=0' "$(made marcus --type=codex --auth-profile=mp)"
eq_t 'codex hire on the demo AI: box login, not refused' \
  'profile= defer=0' "$(made marcus --type=codex --auth-profile=demo-ai)"
eq_t 'grok hire on an account named after it: box login' \
  'profile= defer=0' "$(made dude --type=grok --auth-profile=dude --defer-auth)"
eq_t 'a second grok hire: the same login' \
  'profile= defer=0' "$(made scout --type=grok --auth-profile=scout --defer-auth)"
eq_t 'a team template (defer_auth, no account): box login, not deferred' \
  'profile= defer=0' "$(made pixel --type=codex --defer-auth)"
eq_t 'claude hires are not touched (DIVE-7028 owns them)' \
  'profile=mp defer=0' "$(made olivia --type=claude --auth-profile=mp --defer-auth)"

box mp:claude gpt:codex
eq_t 'no shared login, one Codex account: a hire on a Claude account uses it' \
  'profile=gpt defer=0' "$(made marcus --type=codex --auth-profile=mp)"
eq_t 'and a hire naming no account uses it' \
  'profile=gpt defer=0' "$(made ward --type=codex --defer-auth)"
eq_t 'an account that holds its own Codex sign-in is kept' \
  'profile=gpt defer=0' "$(made ward --type=codex --auth-profile=gpt --defer-auth)"

echo '== 3. the overrides =='
box shared:codex shared:grok mp:claude
eq_t '--own-login: the owner asked for a second account, so it gets one' \
  'profile=marcus defer=1' "$(made marcus --type=codex --auth-profile=marcus --defer-auth --own-login)"
eq_t '--own-login with grok too' \
  'profile=dude defer=1' "$(made dude --type=grok --auth-profile=dude --defer-auth --own-login)"
eq_t '--own-login names no account: refused' \
  'needs --auth-profile' "$(made marcus --type=codex --own-login)"
CALLER=owner
eq_t "the owner's dashboard 'new account' flow keeps the account it named" \
  'profile=marcus defer=1' "$(made marcus --type=codex --auth-profile=marcus --defer-auth)"
eq_t 'and a Claude account named for a codex seat is no longer called signed in' \
  'profile=mp defer=1' "$(made marcus --type=codex --auth-profile=mp --defer-auth)"
CALLER=agent
box mp:claude demo-ai:demo
eq_t 'no codex login on the box: the hire still asks for one' \
  'profile=marcus defer=1' "$(made marcus --type=codex --auth-profile=marcus --defer-auth)"
eq_t 'a codex hire on the demo AI with no login: refused' \
  'free demo AI' "$(made marcus --type=codex --auth-profile=demo-ai)"
grep -qF 'no --auth-profile' "$TMP/last.log" && ! grep -qF 'auth-profile=marcus' "$TMP/last.log" \
  && ok_t 'its next step is the box login, not an account per hire' \
  || bad_t 'the refusal still names an account per hire' "$(cat "$TMP/last.log")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
