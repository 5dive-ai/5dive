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
#   C* create: sandboxed claude seat on dashboard, stopped, marker before the
#      agent exists, root-owned CLAUDE.md with rules + fact sheet + brief, record
#   R/S/T rm, ls --json, wake and the 2 h idle tick
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
t 'L5 ...and INNER carries it' 1 "$(grep -c '^INNER="unset CLAUDE_CONFIG_DIR ${UNSET_CREDS}; ${ONBOARDER_OVERRIDE}' bin/5dive-agent-start)"
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
t 'W1 create leaves a _CREATE_STOPPED seat stopped and not enabled' yes "$(
  awk '/DIVE-9253: an onboarder seat is created STOPPED/,/^  fi$/' src/cmd_agent_create.sh \
    | grep -q 'if \[\[ "${_CREATE_STOPPED:-}" == 1 \]\]; then' && echo yes || echo no)"

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
cmd_create() { echo "create _ONBOARDER_OVERRIDE=${_ONBOARDER_OVERRIDE:-} _CREATE_STOPPED=${_CREATE_STOPPED:-} marker=$([[ -e "$ONBOARDER_MARKER_DIR/$1" ]] && echo yes || echo no) $*" >> "$LOG"; }
cmd_rm() { echo "rm $*" >> "$LOG"; }
RUNNING=" "
systemctl() {
  echo "systemctl $*" >> "$LOG"
  case "$1" in
    is-active) u=${3#5dive-agent@onb-}; [[ "$RUNNING" == *" ${u%.service}"* ]] ;;
    *) return 0 ;;
  esac
}
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

out=$( (cmd_onboarder_create acme <<<"$GOOD") 2>&1 )
t 'C1 create succeeds' yes "$([[ "$out" == *"agent onb-acme created, stopped"* ]] && echo yes || echo no)"
c=$(grep '^create ' "$LOG")
t 'C1 ...a sandboxed claude seat on dashboard only, no skills/team bot/heartbeat' yes "$([[ "$c" == *"onb-acme --type=claude --channels=dashboard --isolation=sandboxed --no-skills --no-team-bot --no-heartbeat"* ]] && echo yes || echo no)"
t 'C2 ...stamped onboarder and created stopped' yes "$([[ "$c" == *"_ONBOARDER_OVERRIDE=1 _CREATE_STOPPED=1"* ]] && echo yes || echo no)"
t 'C2 ...the marker existed before the agent did' yes "$([[ "$c" == *"marker=yes"* ]] && echo yes || echo no)"
t 'C2 ...and it is never left enabled' 1 "$(grep -c 'systemctl disable --now 5dive-agent@onb-acme.service' "$LOG")"
md="$TMP/home/agent-onb-acme/.claude/CLAUDE.md"
t 'C3 CLAUDE.md says it is 5dive'"'"'s AI assistant' 1 "$(grep -c "^# You are 5dive's AI assistant for Acme Law$" "$md")"
t 'C3 ...never offers a call, points to Buy with the band' 2 "$(grep -c -e 'Never offer, suggest or book a call' -e 'Buy button on this page; the Team plan is already picked' "$md")"
t 'C3 ...carries the fact sheet and the brief' 3 "$(grep -c -e '5dive runs a team of AI agents' -e '^- Domains: acme-law.com$' -e '^- Contact: Jo Bloggs, Managing partner$' "$md")"
t 'C3 ...is not writable by the seat (640)' 640 "$(stat -c %a "$md")"
t 'C4 the record holds slug, firm, domains, band' '["acme","Acme Law","acme-law.com","Team"]' "$(jq -c '[.slug,.firm,.domains[0],.band]' "$TMP/state/acme.json")"
t 'C4 ...the minute tick is installed' 1 "$(grep -c '^\* \* \* \* \* root /usr/local/bin/5dive onboarder tick' "$TMP/cron")"
t 'C5 a second create of the same slug is refused' 5 "$( (cmd_onboarder_create acme <<<"$GOOD") >/dev/null 2>&1; echo $?)"
t 'C5 a brief with an email is refused before any agent is made' 3 "$( (cmd_onboarder_create other <<<'{"firm":"O","domains":["o.com"],"facts":["user@example.com"]}') >/dev/null 2>&1; echo $?)"
t 'C5 ...and leaves no marker behind' no "$([[ -e "$TMP/markers/onb-other" ]] && echo yes || echo no)"

t 'S1 ls --json: stopped' '[{"slug":"acme","firm":"Acme Law","domains":["acme-law.com"],"band":"Team","setup":"cloud","running":false}]' "$(JSON_MODE=0 cmd_onboarder_ls --json)"

# --- wake and tick --------------------------------------------------------------------
: > "$LOG"
cmd_onboarder_wake acme >/dev/null
t 'T1 wake starts a stopped seat' 1 "$(grep -c 'systemctl start 5dive-agent@onb-acme.service' "$LOG")"
RUNNING=" acme"; : > "$LOG"
cmd_onboarder_wake acme >/dev/null
t 'T1 ...and does nothing to a running one' 0 "$(grep -c 'systemctl start' "$LOG")"
t 'S1 ls --json: running' true "$(cmd_onboarder_ls --json | jq '.[0].running')"
: > "$LOG"; cmd_onboarder_tick
t 'T2 tick leaves a seat seen just now running' 0 "$(grep -c 'systemctl stop' "$LOG")"
touch -d '-121 minutes' "$TMP/state/acme.active"
: > "$LOG"; cmd_onboarder_tick 2>/dev/null
t 'T3 tick stops a seat idle 2 h' 1 "$(grep -c 'systemctl stop 5dive-agent@onb-acme.service' "$LOG")"
inbox="$TMP/home/agent-onb-acme/.claude/channels/dashboard/agent-inbox"; mkdir -p "$inbox"
touch -d '-121 minutes' "$TMP/state/acme.active" "$inbox"
: > "$LOG"; cmd_onboarder_tick 2>/dev/null
t 'T3 ...an empty old inbox does not keep it up' 1 "$(grep -c 'systemctl stop' "$LOG")"
RUNNING=" "; : > "$LOG"; cmd_onboarder_tick 2>/dev/null
t 'T4 a stopped seat with nothing queued stays stopped' 0 "$(grep -c 'systemctl start' "$LOG")"
echo '{}' > "$inbox/1.json"
: > "$LOG"; cmd_onboarder_tick 2>/dev/null
t 'T4 ...and starts when a message is queued' 1 "$(grep -c 'systemctl start 5dive-agent@onb-acme.service' "$LOG")"

# --- rm -------------------------------------------------------------------------------
REG='{"agents":{"onb-acme":{"type":"claude"}}}'; : > "$LOG"
cmd_onboarder_rm acme >/dev/null
t 'R1 rm removes the agent with its home' 1 "$(grep -cx 'rm onb-acme --purge-home' "$LOG")"
t 'R1 ...the record and the marker' no "$([[ -e "$TMP/state/acme.json" || -e "$TMP/markers/onb-acme" ]] && echo yes || echo no)"
t 'R1 ...and ls is empty' '[]' "$(cmd_onboarder_ls --json)"
t 'R2 rm of an unknown slug is not found' 4 "$( (cmd_onboarder_rm nope) >/dev/null 2>&1; echo $?)"

echo "---"; echo "pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
