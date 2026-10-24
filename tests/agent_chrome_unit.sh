#!/usr/bin/env bash
# DIVE-6345 — `agent config <name> set chrome=on|off`: Claude in Chrome for one agent.
#
# Claude Code switches Chrome off on a setup token (its scope is user:inference
# only), and every seat runs on one. So an opted-in agent must start on its OWN
# claude.ai login, which `5dive browser claude connect` (5dive-browser 1.44.0)
# saves to ~/.claude/.credentials.json. Contract pinned here:
#   W1 write_agent_env stamps AGENT_CHROME=1, PRESERVES it across an unrelated
#      rewrite, and chrome=off removes it
#   L1 the launcher, opted in WITH a login: --chrome, and the env tokens unset in
#      the inner shell (the login file is what it runs on)
#   L2 opted in with NO login yet: unchanged (token on, no --chrome), and it says
#      how to connect — fail soft, the agent still starts
#   L3 not opted in: unchanged, whatever is on disk
#   H1 the nightly creds heal never renames an opted-in agent's login file (its
#      expiresAt is in the past whenever the agent was stopped; it refreshes
#      itself) — and still heals a non-opted-in agent's stale one
#
# Run: bash tests/agent_chrome_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
TMP=$(mktemp -d /tmp/agent-chrome.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0
t() {  # t <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi
}

# --- W1: the env stamp --------------------------------------------------------
fn=$(awk '/^write_agent_env\(\) \{/,/^}/' src/cmd_agent_create.sh)
[[ -n "$fn" ]] || { echo "FAIL - write_agent_env not found"; exit 1; }
ENV_DIR="$TMP/agents.d"; mkdir -p "$ENV_DIR"
chown() { :; }; channel_in_list() { return 1; }
eval "$fn"
_CHROME_OVERRIDE=1 write_agent_env swan claude telegram
t 'W1 chrome=on stamps AGENT_CHROME=1' 1 "$(grep -cx 'AGENT_CHROME=1' "$ENV_DIR/swan.env")"
_CHROME_OVERRIDE='' write_agent_env swan claude "telegram,dashboard"
t 'W1 ...an unrelated rewrite (channels) preserves it' 1 "$(grep -cx 'AGENT_CHROME=1' "$ENV_DIR/swan.env")"
_CHROME_OVERRIDE=0 write_agent_env swan claude telegram
t 'W1 chrome=off removes the line' 0 "$(grep -c 'AGENT_CHROME' "$ENV_DIR/swan.env")"
t 'W1 the config verb knows the key' 1 "$(grep -c '^      chrome|--chrome)$' src/cmd_agent_config.sh)"

# --- L*: the launcher block, run as written -------------------------------------
blk=$(awk '/^# DIVE-6345: Claude in Chrome for this agent/,/^fi$/' bin/5dive-agent-start)
[[ -n "$blk" ]] || { echo "FAIL - launcher block not found"; exit 1; }
launch() {  # launch <AGENT_CHROME> <home> -> "ARGS|UNSET_CREDS|stderr"
  ( TYPE=claude NAME=swan AGENT_CHROME="$1" HOME="$2"
    ARGS=(--dangerously-skip-permissions); UNSET_CREDS="OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY"
    err=$(eval "$blk" 2>&1 >/dev/null; printf '%s|%s' "${ARGS[*]}" "$UNSET_CREDS")
    printf '%s\n' "$err" )
}
H="$TMP/home-login"; mkdir -p "$H/.claude"; printf '{"claudeAiOauth":{"accessToken":"x"}}' > "$H/.claude/.credentials.json"
N="$TMP/home-none"; mkdir -p "$N"
out=$(launch 1 "$H")
t 'L1 opted in with a login: --chrome' yes "$([[ "$out" == *"--dangerously-skip-permissions --chrome|"* ]] && echo yes || echo no)"
t 'L1 ...and the seat token is unset in the inner shell' yes "$([[ "${out##*|}" == *CLAUDE_CODE_OAUTH_TOKEN* && "${out##*|}" == *ANTHROPIC_AUTH_TOKEN* ]] && echo yes || echo no)"
out=$(launch 1 "$N")
t 'L2 opted in with no login: no --chrome' no "$([[ "$out" == *--chrome* ]] && echo yes || echo no)"
t 'L2 ...the token stays' no "$([[ "${out##*|}" == *CLAUDE_CODE_OAUTH_TOKEN* ]] && echo yes || echo no)"
t 'L2 ...and it says how to connect' yes "$([[ "$out" == *"5dive browser claude connect"* ]] && echo yes || echo no)"
out=$(launch "" "$H")
t 'L3 not opted in, even with a login file on disk: unchanged' "--dangerously-skip-permissions|OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY" "${out#*$'\n'}"
t 'L3 the block sits before the inner shell is built from UNSET_CREDS' yes \
  "$( (( $(grep -n '^# DIVE-6345: Claude in Chrome for this agent' bin/5dive-agent-start | cut -d: -f1) < $(grep -n '^INNER="unset CLAUDE_CONFIG_DIR' bin/5dive-agent-start | cut -d: -f1) )) && echo yes || echo no)"

# --- H1: the creds heal ---------------------------------------------------------
fn=$(awk '/^heal_claude_shadow_creds\(\) \{/,/^}/' src/cmd_auth.sh)
eval "$fn"
REGISTRY="$TMP/registry.json"; CONNECTORS_DIR="$TMP/conn"; AUTH_PROFILES_DIR="$TMP/profiles"; mkdir -p "$CONNECTORS_DIR"
printf '{"agents":{"swan":{"type":"claude"},"crow":{"type":"claude"}}}' > "$REGISTRY"
registry_read() { cat "$REGISTRY"; }
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-x\n' > "$CONNECTORS_DIR/anthropic.env"
id() { [[ "${1:-}" == -u ]] && return 0; command id "$@"; }
mkdir -p "$TMP/h/agent-swan/.claude" "$TMP/h/agent-crow/.claude"
for a in swan crow; do printf '{"claudeAiOauth":{"accessToken":"x","expiresAt":1000}}' > "$TMP/h/agent-$a/.claude/.credentials.json"; done
printf 'AGENT_NAME=swan\nAGENT_CHROME=1\n' > "$ENV_DIR/swan.env"; printf 'AGENT_NAME=crow\n' > "$ENV_DIR/crow.env"
heal=$(declare -f heal_claude_shadow_creds | sed "s#home=\"/home/\${user}\"#home=\"$TMP/h/\${user}\"#")
eval "$heal"
out=$(heal_claude_shadow_creds 1)
t 'H1 an opted-in agent'"'"'s expired login file is NOT renamed' yes "$([[ -f "$TMP/h/agent-swan/.claude/.credentials.json" ]] && echo yes || echo no)"
t 'H1 ...a non-opted-in agent'"'"'s stale one still is (the heal is intact)' yes "$([[ "$out" == *"healed crow"* && ! -f "$TMP/h/agent-crow/.claude/.credentials.json" ]] && echo yes || echo no)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
