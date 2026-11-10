#!/usr/bin/env bash
# DIVE-8137 — `agent list --json` marks a Claude Code seat on a custom
# ANTHROPIC_BASE_URL as deaf and says why in `health.chat`.
#
# Claude Code turns its channels feature OFF whenever ANTHROPIC_BASE_URL is not
# Anthropic's (community wiki cc-channels-are-blocked-on-any-custom-anthropic-
# base-url). A self-hosted owner's seat signed in through OpenRouter never heard
# app chat or telegram while the list said deaf:false, auth ok, startup ok.
#
# Graded in BOTH list paths: the python fast path (the embedded shaper) and the
# shell reference path (`_cmd_list_legacy`, reached through the SUDOERS_D seam).
# Flags only on a POSITIVE read of the URL the unit runs with; a non-claude seat,
# a seat with no channel, an Anthropic URL and an unreadable file all stay null.
# Pure, no root, no network:
#   bash tests/agent_list_custom_base_url_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; chmod -R u+rwX "${TMP:-}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP="$(mktemp -d /tmp/agent-list-custom-base-url.XXXXXX)"
pass=0; fail=0
okk() { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

P="$TMP/profiles"; E="$TMP/agents.d"; C="$TMP/connectors"; C2="$TMP/connectors-or"; H="$TMP/home"
mkdir -p "$P" "$E" "$C" "$C2" "$H" "$TMP/sudoers"
prof() { mkdir -p "$P/$1"; printf '%s\n' "$2" >"$P/$1/combined.env"; }
prof orp  'ANTHROPIC_BASE_URL=https://openrouter.ai/api
ANTHROPIC_AUTH_TOKEN=x'
prof gwp  'ANTHROPIC_BASE_URL="https://llm.example.com/anthropic"
ANTHROPIC_AUTH_TOKEN=x'
prof anp  'ANTHROPIC_BASE_URL=https://api.anthropic.com
ANTHROPIC_API_KEY=x'
prof clr  'ANTHROPIC_BASE_URL=
CLAUDE_CODE_OAUTH_TOKEN=x'
prof lockp 'ANTHROPIC_BASE_URL=https://openrouter.ai/api'
chmod 0000 "$P/lockp/combined.env"
printf 'ANTHROPIC_BASE_URL=https://llm.example.com/v1\n' >"$E/authenv-auth.env"
# Second run: the box-wide connector points every unprofiled seat at OpenRouter.
printf 'ANTHROPIC_BASE_URL=https://openrouter.ai/api\nANTHROPIC_AUTH_TOKEN=x\n' >"$C2/anthropic.env"

REG=$(jq -nc '{agents: {
  orb:     {type:"claude", channels:"dashboard",          authProfile:"orp"},
  gw:      {type:"claude", channels:"telegram,dashboard", authProfile:"gwp"},
  anth:    {type:"claude", channels:"dashboard",          authProfile:"anp"},
  clear:   {type:"claude", channels:"dashboard",          authProfile:"clr"},
  plain:   {type:"claude", channels:"dashboard"},
  authenv: {type:"claude", channels:"dashboard"},
  cx:      {type:"codex",  channels:"dashboard",          authProfile:"orp"},
  nochan:  {type:"claude", channels:"none",               authProfile:"orp"},
  locked:  {type:"claude", channels:"dashboard",          authProfile:"lockp"}
}}')
printf '%s\n' "$REG" >"$TMP/agents.json"
NAMES="orb gw anth clear plain authenv cx nochan locked"

# --- python fast path ------------------------------------------------------
PY="$TMP/snapshot.py"
awk '/^# __5DIVE_AGENT_LIST_PY_BEGIN__$/{e=1;next} /^# __5DIVE_AGENT_LIST_PY_END__$/{exit} e{print}' \
  "$ROOT/src/cmd_agent.sh" >"$PY"
py_snap() { AGENT_ENV_DIR="$E" python3 "$PY" "$TMP/agents.json" "$P" "$1" "$H" "$TMP/sudoers" /default 2>"$TMP/err"; }
PY1=$(py_snap "$C"); PY2=$(py_snap "$C2")
[[ -n "$PY1" && -n "$PY2" ]] || { echo "python snapshot produced nothing: $(cat "$TMP/err")"; exit 1; }

# --- shell reference path --------------------------------------------------
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
# shellcheck source=/dev/null
source src/cmd_agent_create.sh
# shellcheck source=/dev/null
source src/cmd_agent.sh
set +e
export SUDOERS_D="$TMP/sudoers"
AUTH_PROFILES_DIR="$P"; ENV_DIR="$E"; AGENT_HOME_ROOT="$H"; DEFAULT_WORKDIR=/default
ensure_state_ro()      { :; }
registry_read()        { printf '%s\n' "$REG"; }
systemctl()            { :; }
resolve_agent_model()  { printf ''; }
resolve_agent_effort() { printf ''; }
JSON_MODE=1
CONNECTORS_DIR="$C";  SH1=$(cmd_list 2>/dev/null | jq -c '.data')
CONNECTORS_DIR="$C2"; SH2=$(cmd_list 2>/dev/null | jq -c '.data')
[[ -n "$SH1" && "$SH1" != null && -n "$SH2" && "$SH2" != null ]] || { echo "shell list produced nothing"; exit 1; }

# --- arms, each graded in both paths ---------------------------------------
got() { jq -c --arg n "$2" '.[] | select(.name==$n) | [.health.deaf, (.health | has("chat")), .health.chat]' <<<"$1"; }
FLAG_OR='[true,true,{"ok":false,"reason":"openrouter"}]'
FLAG_GW='[true,true,{"ok":false,"reason":"custom-base-url"}]'
CLEAN='[false,true,null]'
arm() { # <desc> <name> <want> <python-json> <shell-json>
  local p s
  p=$(got "$4" "$2"); s=$(got "$5" "$2")
  [[ "$p" == "$3" ]] && okk "python: $1" || bad "python: $1 (want $3 got $p)"
  [[ "$s" == "$3" ]] && okk "shell: $1"  || bad "shell: $1 (want $3 got $s)"
}
arm 'claude on an OpenRouter profile: deaf, reason openrouter'          orb     "$FLAG_OR" "$PY1" "$SH1"
arm 'claude on another gateway (quoted value): reason custom-base-url'  gw      "$FLAG_GW" "$PY1" "$SH1"
arm 'claude on api.anthropic.com: not deaf, chat null'                  anth    "$CLEAN"   "$PY1" "$SH1"
arm 'claude with no base URL anywhere: not deaf, chat null'             plain   "$CLEAN"   "$PY1" "$SH1"
arm 'claude whose agents.d auth overlay sets a gateway: flagged'        authenv "$FLAG_GW" "$PY1" "$SH1"
arm 'codex on the same OpenRouter profile: not flagged'                 cx      "$CLEAN"   "$PY1" "$SH1"
arm 'claude with no channel at all: not flagged (agent send still works)' nochan "$CLEAN"  "$PY1" "$SH1"
arm 'box connector on OpenRouter reaches an unprofiled seat'            plain   "$FLAG_OR" "$PY2" "$SH2"
arm 'a profile that names api.anthropic.com overrides the box connector' anth   "$CLEAN"   "$PY2" "$SH2"
arm 'a profile that clears the base URL overrides the box connector'    clear   "$CLEAN"   "$PY2" "$SH2"
if [[ "$(id -u)" == "0" ]]; then
  echo "skip: unreadable profile -> not flagged (running as root; 0000 mode does not apply)"
else
  arm 'an unreadable profile is no evidence: not flagged'               locked  "$CLEAN"   "$PY1" "$SH1"
fi
for n in $NAMES; do
  [[ "$(jq -r --arg n "$n" '[.[] | select(.name==$n)] | length' <<<"$PY1")" == 1 ]] || bad "python: row $n missing"
done

echo "agent_list_custom_base_url_unit: $pass passed, $fail failed"
(( fail == 0 ))
