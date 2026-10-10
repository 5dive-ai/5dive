#!/usr/bin/env bash
# DIVE-5925 — `agent list --json` flags a seat whose Claude org policy (the
# server-managed settings Claude Code caches at ~/.claude/remote-settings.json)
# blocks one of the seat's own channel plugins, and never flags a normal account.
# DIVE-5993: and `orgChannelsOff` for a Team/Enterprise login whose effective
# managed policy lacks `channelsEnabled: true` (the org's settings replace the
# box file whenever they hold any key; no merge).
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
BZ='{"marketplace":"5dive-plugins","plugin":"buzz"}'
UP='{"marketplace":"claude-plugins-official","plugin":"telegram"}'
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
plan() { mkdir -p "$H/agent-$1/.claude"; printf '{"claudeAiOauth":{"accessToken":"x","subscriptionType":"%s"}}\n' "$2" >"$H/agent-$1/.claude/.credentials.json"; }
BOX="$TMP/managed-settings.json"; BOXOFF="$TMP/managed-settings-nochan.json"
printf '{"channelsEnabled":true,"allowedChannelPlugins":[%s,%s]}\n' "$TG" "$DB" >"$BOX"
printf '{"allowedChannelPlugins":[%s,%s]}\n' "$TG" "$DB" >"$BOXOFF"
# Team/Enterprise logins (DIVE-5993)
remote teamnone '{}'; plan teamnone team
remote teampol "{\"allowedChannelPlugins\":[$TG,$DB]}"; plan teampol team
remote teamon "{\"channelsEnabled\":true,\"allowedChannelPlugins\":[$TG,$DB]}"; plan teamon team
remote entprof '{"permissions":{"deny":["WebFetch"]}}'
mkdir -p "$TMP/profiles/corp/claude"; printf '{"claudeAiOauth":{"subscriptionType":"enterprise"}}\n' >"$TMP/profiles/corp/claude/.credentials.json"
remote propol "{\"allowedChannelPlugins\":[$TG,$DB]}"; plan propol pro
printf 'AGENT_CHANNEL_MARKETPLACE=5dive-plugins\n' >"$E/mp.env"
printf 'AGENT_CHANNEL_MARKETPLACE=5dive-plugins\n' >"$E/tgonly.env"
printf 'AGENT_CHANNEL_MARKETPLACE=5dive-plugins\n' >"$E/off.env"
row() { printf '"%s":{"type":"%s","channels":"%s","authProfile":"%s","heartbeat":{"enabled":false}}' "$1" "$2" "$3" "${4:-}"; }
for n in teamnone teampol teamon entprof propol; do printf 'AGENT_CHANNEL_MARKETPLACE=5dive-plugins\n' >"$E/$n.env"; done
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
  row other claude dashboard; printf ,
  row teamnone claude telegram,dashboard; printf ,
  row teampol claude telegram,dashboard; printf ,
  row teamon claude telegram,dashboard; printf ,
  row entprof claude dashboard corp; printf ,
  row propol claude telegram,dashboard
  printf '}}\n'
} >"$TMP/agents.json"
snap() { CLAUDE_MANAGED_SETTINGS="$1" AGENT_ENV_DIR="$E" python3 "$PY" "$TMP/agents.json" "$TMP/profiles" "$TMP/connectors" "$H" "$TMP/sudoers" /default 2>"$TMP/err"; }
OUT=$(CLAUDE_MANAGED_SETTINGS="$BOX" AGENT_ENV_DIR="$E" python3 "$PY" "$TMP/agents.json" "$TMP/profiles" "$TMP/connectors" "$H" "$TMP/sudoers" /default 2>"$TMP/err")
flag() { jq -c --arg n "$1" '.[] | select(.name==$n) | .orgBlocksChannels' <<<"$OUT"; }
[[ -n "$OUT" ]] || { echo "snapshot produced nothing: $(cat "$TMP/err")"; exit 1; }

[[ "$(flag nofile)" == null ]] && okk 'no remote-settings.json: no flag' || bad "nofile: $(flag nofile)"
[[ "$(flag personal)" == null ]] && okk 'a personal account ({}): no flag' || bad "personal: $(flag personal)"
[[ "$(flag allowed)" == null ]] && okk 'an org list that includes dashboard: no flag' || bad "allowed: $(flag allowed)"
[[ "$(flag mp)" == "[$DB,$BZ]" ]] && okk 'an org list without dashboard flags dashboard and buzz, not the allowed telegram' || bad "mp: $(flag mp)"
[[ "$(flag off)" == "[$TG,$DB]" ]] && okk 'channelsEnabled false flags every channel the seat has' || bad "off: $(flag off)"
[[ "$(flag tgonly)" == null ]] && okk 'a telegram seat on our marketplace with telegram allowed: no flag' || bad "tgonly: $(flag tgonly)"
[[ "$(flag upstream)" == "[$UP]" ]] && okk 'a telegram seat on the upstream marketplace is flagged with THAT marketplace, the entry the admin must add' || bad "upstream: $(flag upstream)"
[[ "$(flag nochan)" == null ]] && okk 'a seat with no channels: no flag' || bad "nochan: $(flag nochan)"
[[ "$(flag codex)" == null ]] && okk 'a non-claude seat: no flag' || bad "codex: $(flag codex)"
[[ "$(flag garbled)" == null ]] && okk 'an unreadable policy is no evidence: no flag' || bad "garbled: $(flag garbled)"
[[ "$(flag other)" == null ]] && okk 'an org policy with no channel rule: no flag' || bad "other: $(flag other)"

off() { jq -c --arg n "$1" '.[] | select(.name==$n) | .orgChannelsOff' <<<"$2"; }
[[ "$(off teamnone "$OUT")" == null && "$(flag teamnone)" == null ]] && okk 'a team login whose org set no policy falls back to the box file (channels on): no flag' || bad "teamnone: $(off teamnone "$OUT") $(flag teamnone)"
[[ "$(off teampol "$OUT")" == true && "$(flag teampol)" == "[$TG,$DB]" ]] && okk 'a team org policy without channelsEnabled replaces the box file: channels off, every plugin flagged' || bad "teampol: $(off teampol "$OUT") $(flag teampol)"
[[ "$(off teamon "$OUT")" == null && "$(flag teamon)" == null ]] && okk 'the admin added channelsEnabled true and both plugins: the notice clears' || bad "teamon: $(off teamon "$OUT") $(flag teamon)"
[[ "$(off entprof "$OUT")" == true && "$(flag entprof)" == "[$DB]" ]] && okk 'an enterprise login read from the seat profile, org policy with no channel key: channels off' || bad "entprof: $(off entprof "$OUT") $(flag entprof)"
[[ "$(off propol "$OUT")" == null ]] && okk 'a pro login is never "channels off" (Claude Code gates only team/enterprise)' || bad "propol: $(off propol "$OUT")"
[[ "$(off off "$OUT")" == true ]] && okk 'channelsEnabled false reads as channels off too' || bad "off: $(off off "$OUT")"
[[ "$(off personal "$OUT")" == null && "$(off mp "$OUT")" == null ]] && okk 'personal and allowlist-only seats are not "channels off"' || bad "personal/mp: $(off personal "$OUT") $(off mp "$OUT")"
OUT2=$(snap "$BOXOFF")
[[ "$(off teamnone "$OUT2")" == true ]] && okk 'a team login on a box file without channelsEnabled: channels off' || bad "teamnone/boxoff: $(off teamnone "$OUT2")"
OUT3=$(snap "$TMP/absent.json")
[[ "$(off teamnone "$OUT3")" == null ]] && okk 'an unreadable box file is no evidence: no flag' || bad "teamnone/absent: $(off teamnone "$OUT3")"
remote teampol "{\"channelsEnabled\":true,\"allowedChannelPlugins\":[$TG,$DB]}"
OUT4=$(snap "$BOX")
[[ "$(off teampol "$OUT4")" == null && "$(jq -c '.[] | select(.name=="teampol") | .orgBlocksChannels' <<<"$OUT4")" == null ]] && okk 'the org flips channelsEnabled on (Claude Code re-fetches on restart): the same seat clears' || bad "teampol after flip: $(off teampol "$OUT4")"

echo "pass=$pass fail=$fail"
(( fail == 0 ))
