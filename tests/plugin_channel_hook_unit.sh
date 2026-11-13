#!/usr/bin/env bash
# DIVE-8315 — one hook for plugin channels (src/lib/plugin_channels.sh).
#
# A plugin declares its channel in its manifest (fivedive.channel) and core
# reads it from there; core never names the channel. Every arm here uses
# FIXTURE plugins, so a green cannot come from a real channel's own wiring:
#
#   R1-R4  the registry: an enabled channel plugin counts; disabled, no `channel`
#          capability, a built-in name or a bad name do not
#   V1-V3  valid_channel accepts a declared channel, alone and in a list; not others
#   H1-H2  a plugin channel runs on claude agents only, and only where it says so
#   A1-A3  the Claude Code allowlist: wanted = built-ins + plugin pairs; reconcile
#          adds the pair and keeps every other entry; a second run is a no-op
#   L1-L3  5dive-agent-start: plugin:<plugin>@<marketplace> for a declared name,
#          nothing for anything else, and an undeclared name SKIPS (seat still starts)
#   O1-O2  local-only: a plugin channel with a local_only block is not "outside";
#          one without is
#   S1     every core site that used to name a channel asks the hook instead
#
# Run: bash tests/plugin_channel_hook_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP="$(mktemp -d /tmp/pc-hook.XXXXXX)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/local_only.sh \
         lib/agent_setup.sh lib/plugin_channels.sh; do
  source "$SRC/$f" 2>/dev/null
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

STATE_DIR="$TMP/state"; P="$STATE_DIR/plugins"
mkdir -p "$P/enabled"
# fixture <key> <plugin> <mkt> <enabled> <caps json> <channel json or null>
fixture() {
  local key="$1" plugin="$2" mkt="$3" en="$4" caps="$5" ch="$6"
  mkdir -p "$P/enabled/$key/.claude-plugin"
  jq -n --arg p "$plugin" --argjson c "$caps" --argjson ch "$ch" \
    '{name:$p, version:"0.0.1", fivedive:({contract:"1", capabilities:$c} + (if $ch == null then {} else {channel:$ch} end))}' \
    >"$P/enabled/$key/.claude-plugin/plugin.json"
  local cur='{}'; [[ -s "$P/installed.json" ]] && cur=$(cat "$P/installed.json")
  jq --arg k "$key" --arg p "$plugin" --arg m "$mkt" --argjson e "$en" --argjson c "$caps" \
    '.[$k] = {plugin:$p, marketplace:$m, enabled:$e, capabilities:$c}' <<<"$cur" >"$P/installed.json"
}
fixture chatx@fixture-mkt chatx fixture-mkt true '["channel","verb"]' \
  '{"name":"chatx","harnesses":["claude"],"local_only":{"label":"Chatx to its cloud","note":"Nothing else changes."}}'
fixture offx@fixture-mkt offx fixture-mkt false '["channel"]' '{"name":"offx"}'
fixture nocap@fixture-mkt nocap fixture-mkt true '["verb"]' '{"name":"nocap"}'
fixture teamsfake@other-mkt teamsfake other-mkt true '["channel"]' '{"name":"teams"}'
fixture badname@other-mkt badname other-mkt true '["channel"]' '{"name":"Bad Name"}'
fixture codexonly@fixture-mkt codexonly fixture-mkt true '["channel"]' '{"name":"codexonly","harnesses":["codex"]}'
fixture lanx@fixture-mkt lanx fixture-mkt true '["channel"]' '{"name":"lanx"}'

# --- R ----------------------------------------------------------------------
NAMES=$(plugin_channel_names)
[[ " $NAMES " == *" chatx "* ]] && ok_t "R1 an enabled plugin's declared channel is listed ($NAMES)" || bad_t "R1 chatx listed" "$NAMES"
[[ " $NAMES " != *" offx "* && " $NAMES " != *" nocap "* ]] \
  && ok_t "R2 a disabled plugin, and one without the channel capability, are not" || bad_t "R2 disabled/nocap" "$NAMES"
[[ " $NAMES " != *" teams "* && "$NAMES" != *"Bad"* ]] \
  && ok_t "R3 a built-in name (teams) and a bad name are ignored" || bad_t "R3 builtin/bad" "$NAMES"
E=$(plugin_channel chatx)
[[ "$(jq -c '[.plugin,.marketplace,.harnesses,.local_only.label]' <<<"$E")" == '["chatx","fixture-mkt",["claude"],"Chatx to its cloud"]' ]] \
  && ok_t "R4 its entry: plugin, marketplace, harnesses, local_only" || bad_t "R4 entry" "$E"

# --- V ----------------------------------------------------------------------
valid_channel chatx && valid_channel telegram,chatx && ok_t "V1 valid_channel chatx and telegram,chatx" || bad_t "V1 valid chatx"
valid_channel offx && bad_t "V2 a disabled plugin's channel must be refused" || ok_t "V2 a disabled plugin's channel is refused"
valid_channel none,chatx && bad_t "V3 none,chatx must be refused" || ok_t "V3 none,chatx is still refused"

# --- H ----------------------------------------------------------------------
plugin_channel_runs_on chatx claude && ! plugin_channel_runs_on chatx codex \
  && ok_t "H1 chatx runs on claude, not codex" || bad_t "H1 runs_on chatx"
! plugin_channel_runs_on codexonly codex && ! plugin_channel_runs_on codexonly claude \
  && ok_t "H2 a channel naming only codex runs nowhere yet (claude is the one harness that loads one by name)" || bad_t "H2 codexonly"
H3=$( (plugin_channel_harness_check chatx codex mike) 2>&1 ); H3RC=$?
[[ "$H3RC" == "$E_VALIDATION" && "$H3" == *"channels=chatx runs on claude agents only"* ]] \
  && ok_t "H3 the refusal names the channel and the types it runs on" || bad_t "H3 refusal" "rc=$H3RC $H3"

# --- A ----------------------------------------------------------------------
W=$(channel_plugins_wanted_json)
[[ "$(jq -r 'map("\(.plugin)@\(.marketplace)") | join(" ")' <<<"$W")" == *"teams@5dive-plugins"*"chatx@fixture-mkt"* \
   && "$(jq -r 'map(select(.plugin=="offx")) | length' <<<"$W")" == 0 ]] \
  && ok_t "A1 wanted allowlist = built-ins + each enabled plugin channel" || bad_t "A1 wanted" "$W"
MS="$TMP/managed-settings.json"
printf '%s\n' '{"own":1,"channelsEnabled":true,"allowedChannelPlugins":[{"plugin":"mine","marketplace":"x"}]}' >"$MS"
reconcile_managed_settings "$MS"; A2RC=$?
[[ "$A2RC" == 0 && "$(jq -r '.own' "$MS")" == 1 \
   && "$(jq -c '[.allowedChannelPlugins[] | "\(.plugin)@\(.marketplace)"] | (index("mine@x") != null) and (index("chatx@fixture-mkt") != null)' "$MS")" == true ]] \
  && ok_t "A2 reconcile adds chatx@fixture-mkt and keeps the operator's own entries" || bad_t "A2 reconcile" "rc=$A2RC $(cat "$MS")"
reconcile_managed_settings "$MS"; A3RC=$?
managed_settings_channels_ok "$MS"; A3OK=$?
[[ "$A3RC" == 3 && "$A3OK" == 0 && -z "$(managed_settings_channels_missing "$MS")" ]] \
  && ok_t "A3 a second reconcile is a no-op, and the doctor's check reads it as complete" || bad_t "A3 idempotent" "rc=$A3RC ok=$A3OK"
printf '%s\n' '{"channelsEnabled":true,"allowedChannelPlugins":[]}' >"$MS"
[[ "$(managed_settings_channels_missing "$MS")" == *"chatx@fixture-mkt"* ]] \
  && ok_t "A4 the doctor names a missing plugin channel" || bad_t "A4 doctor gap" "$(managed_settings_channels_missing "$MS")"

# --- L: the launch line, from bin/5dive-agent-start itself --------------------
LFN="$TMP/launch.sh"
sed -n '/^plugin_channel_launch() {/,/^}/p' bin/5dive-agent-start >"$LFN"
if [[ -s "$LFN" ]]; then
  # shellcheck disable=SC1090
  source "$LFN"
  [[ "$(FIVEDIVE_PLUGIN_STORE="$P" plugin_channel_launch chatx)" == "plugin:chatx@fixture-mkt" ]] \
    && ok_t "L1 agent-start resolves chatx to plugin:chatx@fixture-mkt" || bad_t "L1 launch" "$(FIVEDIVE_PLUGIN_STORE="$P" plugin_channel_launch chatx)"
  FIVEDIVE_PLUGIN_STORE="$P" plugin_channel_launch offx >/dev/null || ok_t "L2 nothing for a disabled plugin's channel"
  FIVEDIVE_PLUGIN_STORE="$P" plugin_channel_launch offx >/dev/null && bad_t "L2 disabled must not resolve"
else
  bad_t "L1 plugin_channel_launch not found in bin/5dive-agent-start"
fi
grep -qE 'no enabled plugin provides it .* starting without it' bin/5dive-agent-start \
  && grep -A3 'no enabled plugin provides it' bin/5dive-agent-start | grep -q '^      continue$' \
  && ok_t "L3 an undeclared channel is skipped with a line, and the seat still starts" || bad_t "L3 skip arm"

# --- O ----------------------------------------------------------------------
_lo_channels_outside chatx && bad_t "O1 chatx (declares local_only) must not count as outside" || ok_t "O1 a plugin channel with local_only is not outside"
_lo_channels_outside lanx && ok_t "O2 a plugin channel without local_only counts as outside" || bad_t "O2 lanx must be outside"

# --- S: the sites ask the hook --------------------------------------------------
s_ok=1
for pat in "src/cmd_agent_config.sh:plugin_channels_in \"\$channels_changed_to\"" \
           "src/cmd_agent_config.sh:plugin_channel_harness_check" \
           "src/cmd_agent_config.sh:_gpe=\$(plugin_channel \"\$gate_ch\")" \
           "src/cmd_agent_create.sh:install_channel_for_agent \"\$type\" \"\$_ch\" \"\$name\"" \
           "src/cmd_agent_create.sh:for _cp in dashboard buzz teams \$(plugin_channel_names)" \
           "src/lib/agent_setup.sh:_pce=\$(plugin_channel \"\$plugin\")" \
           "src/lib/agent_setup.sh:reconcile_managed_settings \"\$_ms\"" \
           "src/cmd_agent.sh:FIVEDIVE_PLUGIN_CHANNELS=" \
           "src/cmd_people.sh:_people_plugin_knock_card" \
           "src/cmd_local_only.sh:plugin_channel_names"; do
  grep -qF -- "${pat#*:}" "${pat%%:*}" || { s_ok=0; bad_t "S1 ${pat%%:*} asks the hook" "missing: ${pat#*:}"; }
done
(( s_ok )) && ok_t "S1 config, create, per-seat install, allowlist, agent info, people and local-only all ask the hook"
# Core names no plugin's channel: no launch line, allowlist pair or channel case for one.
if grep -rnE 'plugin:email|email@5dive|channels=email|channel=email|^ *email\)' src bin/5dive-agent-start install.sh >/dev/null; then
  bad_t "S2 core must not name the email channel" "$(grep -rnE 'plugin:email|email@5dive|channels=email|channel=email|^ *email\)' src bin/5dive-agent-start install.sh | head -3)"
else
  ok_t "S2 core names no plugin's channel (no email launch line, pair or case)"
fi

echo "plugin_channel_hook_unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
