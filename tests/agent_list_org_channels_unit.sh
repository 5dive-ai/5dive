#!/usr/bin/env bash
# DIVE-5925 — `agent list --json` flags a seat whose Claude org policy (the
# server-managed settings Claude Code caches at ~/.claude/remote-settings.json)
# blocks one of the seat's own channel plugins, and never flags a normal account.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/agent-list-org-channels.XXXXXX)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
pass=0; fail=0
okk() { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

PY="$TMP/snapshot.py"
awk '/^# __5DIVE_AGENT_LIST_PY_BEGIN__$/{e=1;next} /^# __5DIVE_AGENT_LIST_PY_END__$/{exit} e{print}' \
  "$ROOT/src/cmd_agent.sh" >"$PY"
H="$TMP/home"; E="$TMP/agents.d"
mkdir -p "$TMP/profiles" "$TMP/connectors" "$TMP/sudoers" "$E"
remote() { mkdir -p "$H/agent-$1/.claude"; printf '%s\n' "$2" >"$H/agent-$1/.claude/remote-settings.json"; }
TG='{"marketplace":"5dive-plugins","plugin":"telegram"}'
DB='{"marketplace":"5dive-plugins","plugin":"dashboard"}'
mkdir -p "$H/agent-nofile/.claude"
remote personal '{}'
remote allowed "{\"allowedChannelPlugins\":[$TG,$DB]}"
remote mp "{\"allowedChannelPlugins\":[$TG,{\"marketplace\":\"claude-plugins-official\",\"plugin\":\"discord\"}],\"channelsEnabled\":true}"
remote off '{"channelsEnabled":false}'
remote tgonly "{\"allowedChannelPlugins\":[$TG]}"
remote upstream "{\"allowedChannelPlugins\":[$TG]}"
remote nochan "{\"allowedChannelPlugins\":[$TG]}"
remote codex "{\"allowedChannelPlugins\":[]}"
remote garbled '{"allowedChannelPlugins": ['
remote other '{"permissions":{"deny":["WebFetch"]}}'
printf 'AGENT_CHANNEL_MARKETPLACE=5dive-plugins\n' >"$E/mp.env"
printf 'AGENT_CHANNEL_MARKETPLACE=5dive-plugins\n' >"$E/tgonly.env"
printf 'AGENT_CHANNEL_MARKETPLACE=5dive-plugins\n' >"$E/off.env"
row() { printf '"%s":{"type":"%s","channels":"%s","heartbeat":{"enabled":false}}' "$1" "$2" "$3"; }
{
  printf '{"agents":{'
  row nofile claude dashboard; printf ,
  row personal claude telegram,dashboard; printf ,
  row allowed claude dashboard; printf ,
  row mp claude telegram,dashboard,buzz; printf ,
  row off claude telegram,dashboard; printf ,
  row tgonly claude telegram; printf ,
  row upstream claude telegram; printf ,
  row nochan claude none; printf ,
  row codex codex dashboard; printf ,
  row garbled claude dashboard; printf ,
  row other claude dashboard
  printf '}}\n'
} >"$TMP/agents.json"
OUT=$(AGENT_ENV_DIR="$E" python3 "$PY" "$TMP/agents.json" "$TMP/profiles" "$TMP/connectors" "$H" "$TMP/sudoers" /default 2>"$TMP/err")
flag() { jq -c --arg n "$1" '.[] | select(.name==$n) | .orgBlocksChannels' <<<"$OUT"; }
[[ -n "$OUT" ]] || { echo "snapshot produced nothing: $(cat "$TMP/err")"; exit 1; }

[[ "$(flag nofile)" == null ]] && okk 'no remote-settings.json: no flag' || bad "nofile: $(flag nofile)"
[[ "$(flag personal)" == null ]] && okk 'a personal account ({}): no flag' || bad "personal: $(flag personal)"
[[ "$(flag allowed)" == null ]] && okk 'an org list that includes dashboard: no flag' || bad "allowed: $(flag allowed)"
[[ "$(flag mp)" == '["dashboard","buzz"]' ]] && okk 'an org list without dashboard flags dashboard and buzz, not the allowed telegram' || bad "mp: $(flag mp)"
[[ "$(flag off)" == '["telegram","dashboard"]' ]] && okk 'channelsEnabled false flags every channel the seat has' || bad "off: $(flag off)"
[[ "$(flag tgonly)" == null ]] && okk 'a telegram seat on our marketplace with telegram allowed: no flag' || bad "tgonly: $(flag tgonly)"
[[ "$(flag upstream)" == '["telegram"]' ]] && okk 'a telegram seat on the upstream marketplace is matched by marketplace too' || bad "upstream: $(flag upstream)"
[[ "$(flag nochan)" == null ]] && okk 'a seat with no channels: no flag' || bad "nochan: $(flag nochan)"
[[ "$(flag codex)" == null ]] && okk 'a non-claude seat: no flag' || bad "codex: $(flag codex)"
[[ "$(flag garbled)" == null ]] && okk 'an unreadable policy is no evidence: no flag' || bad "garbled: $(flag garbled)"
[[ "$(flag other)" == null ]] && okk 'an org policy with no channel rule: no flag' || bad "other: $(flag other)"

echo "pass=$pass fail=$fail"
(( fail == 0 ))
