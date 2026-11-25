#!/usr/bin/env bash
# DIVE-9253 — a chat-only agent: someone outside the team types into it (a web
# chat on the dashboard channel) while it holds the box's Claude sign-in.
# Contract pinned here:
#   L1 the launcher, AGENT_CHAT_ONLY=1: argv rebuilt to no tools (--tools "",
#      every built-in denied, dontAsk + one allowlisted tool, no slash commands,
#      dashboard channel only), whatever the blocks before it added
#   L2 the root marker /etc/5dive/chat-only-agents/<name> alone turns it on too
#   L3 neither: the argv is untouched
#   L4 a non-dashboard channel or a non-claude type refuses to start (exit 2)
#   L5 the inner shell exports DASHBOARD_CHAT_ONLY_AGENT=1 for the dashboard plugin
#   W1 write_agent_env stamps AGENT_CHAT_ONLY=1 and keeps it across a rewrite
#   F* agent create: --chat-only and --stopped parse, --help names both (a
#      caller reads the help to learn this core has them), a chat-only create
#      refuses another type or channel, --stopped neither enables nor starts
#
# Run: bash tests/dive9253_chat_only_agent_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
TMP=$(mktemp -d /tmp/chat-only-unit.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0
t() {  # t <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi
}
# The channel spec the launcher passes, built so no fixture reads as an address.
DASH_SPEC=$(printf 'plugin:dashboard%s5dive-plugins' '@')
TG_SPEC=$(printf 'plugin:telegram%sx' '@')

# --- L*: the launcher block, run as written -------------------------------------
blk=$(awk '/^# DIVE-9253: a chat-only agent\. Someone outside/,/^fi$/' bin/5dive-agent-start)
[[ -n "$blk" ]] || { echo "FAIL - launcher block not found"; exit 1; }
mkdir -p "$TMP/markers"
launch() {  # launch <AGENT_CHAT_ONLY> <type> <channels> -> "rc|ARGS (one per line)|OVERRIDE"
  ( TYPE="$2" CHANNELS="$3" NAME=webchat AGENT_CHAT_ONLY="$1" CHAT_ONLY_MARKER_DIR="$TMP/markers"
    ARGS=(--dangerously-skip-permissions --append-system-prompt "AUTONOMY MODE: yolo" --chrome --channels "$TG_SPEC")
    RESUME_ID=abc
    out=$(eval "$blk" 2>/dev/null; printf '%s\n' "${ARGS[@]}"; printf 'OVERRIDE=%s\nRESUME=%s\n' "${CHAT_ONLY_OVERRIDE:-}" "$RESUME_ID")
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
t 'L1 ...dashboard is the one channel' "$DASH_SPEC" "$(sed -n '/^--channels$/{n;p}' <<<"$out")"
t 'L1 ...the skip-permissions, autonomy text and Chrome args are gone' 0 "$(grep -c -e skip-permissions -e 'AUTONOMY MODE' -e '^--chrome$' -e telegram <<<"$out")"
t 'L1 ...no resume of an older session' 'RESUME=' "$(grep '^RESUME=' <<<"$out")"
t 'L5 the inner shell exports DASHBOARD_CHAT_ONLY_AGENT=1' 'OVERRIDE=export DASHBOARD_CHAT_ONLY_AGENT=1; ' "$(grep '^OVERRIDE=' <<<"$out")"
t 'L5 ...and INNER carries it, after HERMES_OVERRIDE and before PRELUDE' 1 "$(grep -c '${HERMES_OVERRIDE}${CHAT_ONLY_OVERRIDE}${PRELUDE}' bin/5dive-agent-start)"
t 'L5 the block sits after every ARGS+= and before CMD_STR' yes "$(
  b=$(grep -n '^# DIVE-9253: a chat-only agent\. Someone outside' bin/5dive-agent-start | cut -d: -f1)
  c=$(grep -n "^CMD_STR=\$(printf '%q ' \"\$BIN\" \"\${ARGS\[@\]}\")" bin/5dive-agent-start | cut -d: -f1)
  l=$(grep -n 'ARGS+=' bin/5dive-agent-start | tail -1 | cut -d: -f1)
  (( l < b && b < c )) && echo yes || echo no)"
: > "$TMP/markers/webchat"
out=$(launch "" claude dashboard)
t 'L2 the root marker alone turns it on' yes "$([[ "$out" == *"rc=0"$'\n'"$want"* ]] && echo yes || echo no)"
out=$(launch 0 claude dashboard)
t 'L2 ...and an env of 0 cannot turn it off' yes "$([[ "$out" == *"$want"* ]] && echo yes || echo no)"
rm -f "$TMP/markers/webchat"
# /etc/5dive/chat-only is already a FILE meaning "this whole box is chat-only"
# (DIVE-6816; the dashboard plugin tests it with existsSync), so the per-agent
# markers must live in a directory of their own or they would switch that on.
t 'L2 the markers have their own directory, not the box chat-only file' 1 "$(grep -cxF 'CHAT_ONLY_MARKER_DIR="${CHAT_ONLY_MARKER_DIR:-/etc/5dive/chat-only-agents}"' <<<"$blk")"
out=$(launch "" claude dashboard)
t 'L3 not chat-only: argv untouched' yes "$([[ "$out" == *$'rc=0\n--dangerously-skip-permissions\n--append-system-prompt'* && "$out" == *'RESUME=abc'* ]] && echo yes || echo no)"
t 'L4 telegram beside dashboard refuses to start' 'rc=2' "$(launch 1 claude telegram,dashboard | head -1)"
t 'L4 a chat-only codex agent refuses to start' 'rc=2' "$(launch 1 codex dashboard | head -1)"

# --- W1: the env stamp -------------------------------------------------------------
fn=$(awk '/^write_agent_env\(\) \{/,/^}/' src/cmd_agent_create.sh)
ENV_DIR="$TMP/agents.d"; mkdir -p "$ENV_DIR"
chown() { :; }; channel_in_list() { return 1; }; valid_model() { return 0; }; openclaw_port_valid() { return 0; }
eval "$fn"
_CHAT_ONLY_OVERRIDE=1 write_agent_env webchat claude dashboard "" "" sandboxed
t 'W1 create stamps AGENT_CHAT_ONLY=1' 1 "$(grep -cx 'AGENT_CHAT_ONLY=1' "$ENV_DIR/webchat.env")"
_CHAT_ONLY_OVERRIDE='' write_agent_env webchat claude dashboard "" "" sandboxed
t 'W1 ...an unrelated rewrite keeps it' 1 "$(grep -cx 'AGENT_CHAT_ONLY=1' "$ENV_DIR/webchat.env")"
_CHAT_ONLY_OVERRIDE=0 write_agent_env theo claude telegram
t 'W1 ...an ordinary create never gets it' 0 "$(grep -c CHAT_ONLY "$ENV_DIR/theo.env")"

# --- F*: agent create -----------------------------------------------------------------
create_fn=$(awk '/^cmd_create\(\) \{/,/^}/' src/cmd_agent_create.sh)
t 'F1 --chat-only and --stopped are parsed flags' 2 "$(grep -cE '^      --(chat-only\)  +chat_only=1|stopped\)  +create_stopped=1) ;;$' <<<"$create_fn")"
t 'F1 ...and the create passes chat-only to the env stamp' 1 "$(grep -c '_CHAT_ONLY_OVERRIDE="$chat_only"' <<<"$create_fn")"
help=$(awk '/^usage\(\) \{/,/^}/' src/main.sh)
t 'F2 `agent create --help` names --chat-only and --stopped' 1 "$(grep -cF '[--chat-only] [--stopped]' <<<"$help")"
guard=$(awk '/DIVE-9253: a chat-only agent is a claude seat on the dashboard/,/^  fi$/' <<<"$create_fn")
refuse() {  # refuse <type> <channels> -> exit code of the guard
  ( fail() { exit "$1"; }; E_VALIDATION=3; chat_only=1 type="$1" channels="$2"; eval "$guard"; exit 0 )
  echo $?
}
t 'F3 a chat-only claude agent on dashboard passes' 0 "$(refuse claude dashboard)"
t 'F3 ...another type is refused' 3 "$(refuse codex dashboard)"
t 'F3 ...another channel beside dashboard is refused' 3 "$(refuse claude dashboard,telegram)"
t 'F3 ...no channel is refused' 3 "$(refuse claude none)"
stopped=$(awk '/DIVE-9253: `--stopped` creates the agent STOPPED/,/^  fi$/' <<<"$create_fn")
start() {  # start <create_stopped> -> the systemctl calls the block makes
  ( systemctl() { echo "systemctl $*"; }; step() { :; }; name=webchat create_stopped="$1"; eval "$stopped" 2>&1 )
}
t 'F4 --stopped: the service is neither enabled nor started' 0 "$(start 1 | grep -c -e enable -e start)"
t 'F4 ...without it, it is enabled and started as before' 1 "$(start 0 | grep -c 'enable --now 5dive-agent.webchat\.service')"

echo "---"; echo "pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
