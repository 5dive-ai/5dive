#!/usr/bin/env bash
# DIVE-9253 — the onboarder seat: an outsider types into it while it holds the
# box's Claude sign-in. Contract pinned here:
#   L1 the launcher, AGENT_ONBOARDER=1: argv rebuilt to no tools (--tools "",
#      every built-in denied, dontAsk + one allowlisted tool, no slash commands,
#      dashboard channel only), whatever the blocks before it added
#   L2 the root marker alone turns it on too (env lost, lock holds)
#   L3 neither: the argv is untouched
#   L4 a non-dashboard channel or a non-claude type refuses to start (exit 2)
#   L5 the inner shell exports DASHBOARD_ONBOARDER=1 for the plugin (lock 2)
#   W1 write_agent_env stamps AGENT_ONBOARDER=1 and keeps it across a rewrite
#   B* the brief: public facts only (fields, email, phone, contact)
# The verbs (box create/rm/ls/wake/tick, client add/rm/ls/mark) and their
# parked-seat and shell-injection arms moved to
# tests/dive9254_onboarder_door_unit.sh with DIVE-9254.
#
# Run: bash tests/dive9253_onboarder_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
TMP=$(mktemp -d /tmp/onboarder-unit.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0
t() {  # t <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi
}
yn() { "$@" && echo yes || echo no; }

# --- L*: the launcher block, run as written -------------------------------------
blk=$(awk '/^# DIVE-9253: an onboarder seat\. An outsider/,/^fi$/' bin/5dive-agent-start)
[[ -n "$blk" ]] || { echo "FAIL - launcher block not found"; exit 1; }
mkdir -p "$TMP/markers"
launch() {  # launch <AGENT_ONBOARDER> <type> <channels> -> "rc|ARGS (one per line)|OVERRIDE"
  ( TYPE="$2" CHANNELS="$3" NAME=onb-acme AGENT_ONBOARDER="$1" ONBOARDER_MARKER_DIR="$TMP/markers"
    ARGS=(--dangerously-skip-permissions --append-system-prompt "AUTONOMY MODE: yolo" --chrome --channels "plugin:telegram@x")
    RESUME_ID=abc
    out=$(eval "$blk" 2>/dev/null; printf '%s\n' "${ARGS[@]}"; printf 'OVERRIDE=%s\nRESUME=%s\n' "${ONBOARDER_OVERRIDE:-}" "$RESUME_ID")
    rc=$?; printf 'rc=%s\n%s\n' "$rc" "$out" )
}
want=$'--permission-mode\ndontAsk\n--allowedTools\nmcp__plugin_dashboard_dashboard__reply\n--tools\n\n--disallowedTools'
out=$(launch 1 claude dashboard)
t 'L1 argv starts with dontAsk, one allowlisted tool, --tools ""' yes "$([[ "$out" == *"rc=0"$'\n'"$want"* ]] && echo yes || echo no)"
deny=$(sed -n '/^--disallowedTools$/{n;p}' <<<"$out")
for tool in Bash Read Write Edit Glob Grep WebFetch WebSearch Task Agent NotebookEdit Skill ToolSearch Monitor; do
  t "L1 ...$tool is denied by name" yes "$([[ ",$deny," == *",$tool,"* ]] && echo yes || echo no)"
done
t 'L1 ...--disable-slash-commands' 1 "$(grep -cx -- '--disable-slash-commands' <<<"$out")"
t 'L1 ...dashboard is the one channel' "plugin:dashboard@5dive-plugins" "$(sed -n '/^--channels$/{n;p}' <<<"$out")"
t 'L1 ...the skip-permissions, autonomy text and Chrome args are gone' 0 "$(grep -c -e skip-permissions -e 'AUTONOMY MODE' -e '^--chrome$' -e telegram <<<"$out")"
t 'L1 ...no resume of an older session' 'RESUME=' "$(grep '^RESUME=' <<<"$out")"
t 'L5 the inner shell exports DASHBOARD_ONBOARDER=1' 'OVERRIDE=export DASHBOARD_ONBOARDER=1; ' "$(grep '^OVERRIDE=' <<<"$out")"
t 'L5 ...and INNER carries it, after STAGE_GUARD' 1 "$(grep -c '^INNER="unset CLAUDE_CONFIG_DIR ${UNSET_CREDS}; ${STAGE_GUARD}${ONBOARDER_OVERRIDE}' bin/5dive-agent-start)"
t 'L5 the block sits after every ARGS+= and before CMD_STR' yes "$(
  b=$(grep -n '^# DIVE-9253: an onboarder seat\. An outsider' bin/5dive-agent-start | cut -d: -f1)
  c=$(grep -n "^CMD_STR=\$(printf '%q ' \"\$BIN\" \"\${ARGS\[@\]}\")" bin/5dive-agent-start | cut -d: -f1)
  l=$(grep -n 'ARGS+=' bin/5dive-agent-start | tail -1 | cut -d: -f1)
  (( l < b && b < c )) && echo yes || echo no)"
: > "$TMP/markers/onb-acme"
out=$(launch "" claude dashboard)
t 'L2 the root marker alone turns it on' yes "$([[ "$out" == *"rc=0"$'\n'"$want"* ]] && echo yes || echo no)"
out=$(launch 0 claude dashboard)
t 'L2 ...and an env of 0 cannot turn it off' yes "$([[ "$out" == *"$want"* ]] && echo yes || echo no)"
rm -f "$TMP/markers/onb-acme"
out=$(launch "" claude dashboard)
t 'L3 not an onboarder: argv untouched' yes "$([[ "$out" == *$'rc=0\n--dangerously-skip-permissions\n--append-system-prompt'* && "$out" == *'RESUME=abc'* ]] && echo yes || echo no)"
t 'L4 telegram beside dashboard refuses to start' 'rc=2' "$(launch 1 claude telegram,dashboard | head -1)"
t 'L4 a codex onboarder refuses to start' 'rc=2' "$(launch 1 codex dashboard | head -1)"

# --- W1: the env stamp -------------------------------------------------------------
fn=$(awk '/^write_agent_env\(\) \{/,/^}/' src/cmd_agent_create.sh)
ENV_DIR="$TMP/agents.d"; mkdir -p "$ENV_DIR"
chown() { :; }; channel_in_list() { return 1; }; valid_model() { return 0; }; openclaw_port_valid() { return 0; }
eval "$fn"
_ONBOARDER_OVERRIDE=1 write_agent_env onb-acme claude dashboard "" "" sandboxed
t 'W1 create stamps AGENT_ONBOARDER=1' 1 "$(grep -cx 'AGENT_ONBOARDER=1' "$ENV_DIR/onb-acme.env")"
_ONBOARDER_OVERRIDE='' write_agent_env onb-acme claude dashboard "" "" sandboxed
t 'W1 ...an unrelated rewrite keeps it' 1 "$(grep -cx 'AGENT_ONBOARDER=1' "$ENV_DIR/onb-acme.env")"
write_agent_env theo claude telegram
t 'W1 ...an ordinary seat never gets it' 0 "$(grep -c ONBOARDER "$ENV_DIR/theo.env")"
_stopped_blk=$(awk '/DIVE-9253: an onboarder seat is created STOPPED/,/^  fi$/' src/cmd_agent_create.sh)
t 'W1 create leaves a _CREATE_STOPPED seat stopped and not enabled' yes "$(
  grep -q 'if \[\[ "${_CREATE_STOPPED:-}" == 1 \]\]; then' <<<"$_stopped_blk" && echo yes || echo no)"

# --- the verb, sourced with stubs ----------------------------------------------------
LOG="$TMP/calls.log"; : > "$LOG"
fail() { echo "FAIL[$1] ${*:2}" >&2; exit "$1"; }
step() { :; }; warn() { :; }
require_root() { :; }
E_USAGE=2 E_VALIDATION=3 E_NOT_FOUND=4 E_CONFLICT=5 E_GENERIC=1
JSON_MODE=0
REG='{"agents":{}}'
registry_read() { printf '%s' "$REG"; }
with_registry_lock() { "$@"; }
export ONBOARDER_STATE_DIR="$TMP/state" ONBOARDER_MARKER_DIR="$TMP/markers" ONBOARDER_FACT_SHEET="$TMP/sheet.md" \
       ONBOARDER_CRON_FILE="$TMP/cron" ONBOARDER_HOME_ROOT="$TMP/home"
printf '5dive runs a team of AI agents on your own server.\n' > "$ONBOARDER_FACT_SHEET"
# shellcheck source=src/cmd_onboarder.sh
. src/cmd_onboarder.sh

prob() { _onboarder_brief_problem <<<"$1"; }
GOOD='{"firm":"Acme Law","domains":["acme-law.com"],"band":"Team","setup":"cloud","facts":["120 lawyers, founded 1998-2005 merger"],"contact":{"name":"Jo Bloggs","role":"Managing partner"}}'
t 'B1 a public brief passes (a year range is not a phone)' '' "$(prob "$GOOD")"
t 'B2 an extra field is refused by name' yes "$([[ "$(prob '{"firm":"A","domains":["a.com"],"home_address":"x"}')" == *home_address* ]] && echo yes || echo no)"
t 'B3 an email anywhere is refused' yes "$([[ "$(prob '{"firm":"A","domains":["a.com"],"facts":["write to user@example.com"]}')" == *email* ]] && echo yes || echo no)"
t 'B4 a phone number with a country code is refused' yes "$([[ "$(prob '{"firm":"A","domains":["a.com"],"facts":["London desk (+44) 20 7946 0958"]}')" == *phone* ]] && echo yes || echo no)"
t 'B4 a phone number is refused' yes "$([[ "$(prob '{"firm":"A","domains":["a.com"],"facts":["call +1-555-0100 ext 22"]}')" == *phone* ]] && echo yes || echo no)"
t 'B5 a contact field beyond name and role is refused' yes "$([[ "$(prob '{"firm":"A","domains":["a.com"],"contact":{"name":"J","role":"P","birthday":"1 May"}}')" == contact* ]] && echo yes || echo no)"
t 'B6 a bad domain is refused' yes "$([[ "$(prob '{"firm":"A","domains":["not a domain"]}')" == domains* ]] && echo yes || echo no)"
t 'B7 not JSON is refused' 'the brief is not valid JSON' "$(prob 'nope')"
t 'B8 a slug that would overflow a Linux user name is refused' no "$(yn _onboarder_valid_slug abcdefghijklm)"


echo "---"; echo "pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
