#!/usr/bin/env bash
# DIVE-7658 — the Microsoft Teams channel's core wiring.
#
# A channel is not one edit (community/wiki: a-channel-is-six-wiring-sites-and-
# five-green-ones-is-what-broken-looks-like). Every site below is one that, if
# missed, leaves `channels=teams` accepted and the agent deaf, or lets Teams
# run on an offline server. Each grep arm has a CONTROL that the same pattern
# finds buzz's line, so a green cannot come from a regex that matches nothing.
#
#   1. valid_channel accepts teams (and not a near-miss)
#   2. install_channel_plugin_for_agent routes it to 5dive-plugins
#   3. install_channel_for_agent refuses non-claude types
#   4. agent config: claude-only check, the install dispatch, the staging gate
#   5. agent create: the per-channel install arm (the site DIVE-3509 found missing)
#   6. 5dive-agent-start emits --channels plugin:teams@5dive-plugins
#   7. managed settings allowlist it: header constant AND both install.sh copies
#   8. local-only refuses it: --channels=teams, channels=teams, agent teams connect
#   9. `agent teams` dispatches to the OFFICIAL plugin only
#  10. the create-time self-check covers its plugin
#
# Run: bash tests/teams_channel_wiring_unit.sh  (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
# both <label> <file> <ERE with CH for the channel> — the teams line exists AND
# the same pattern finds buzz's (the control).
both() {
  local label="$1" file="$2" pat="$3"
  grep -qE "${pat//CH/buzz}" "$file" || { bad_t "CONTROL: $label (pattern finds buzz)" "pattern: ${pat//CH/buzz}"; return; }
  grep -qE "${pat//CH/teams}" "$file" && ok_t "$label" || bad_t "$label" "no match in $file for: ${pat//CH/teams}"
}

# 1
valid_channel teams && ok_t "valid_channel teams" || bad_t "valid_channel teams"
valid_channel telegram,teams && ok_t "valid_channel telegram,teams" || bad_t "valid_channel telegram,teams"
valid_channel teamss && bad_t "NEGATIVE: teamss must be rejected" || ok_t "NEGATIVE: teamss rejected"
valid_channel none,teams && bad_t "NEGATIVE: none,teams must be rejected" || ok_t "NEGATIVE: none,teams rejected"

# 2, 3
grep -qE '"\$plugin" == "buzz" \|\| "\$plugin" == "teams" \]\]; then' "$SRC/lib/agent_setup.sh" \
  && ok_t "install routes teams to 5dive-plugins" || bad_t "install routes teams to 5dive-plugins"
both "install_channel_for_agent refuses non-claude" "$SRC/lib/agent_setup.sh" '"\$plugin" == "CH" && "\$type" != "claude"'

# 4
both "agent config refuses non-claude before the registry write" "$SRC/cmd_agent_config.sh" '"\$type" != "claude" \]\] && channel_in_list CH "\$v"'
both "agent config dispatches the install" "$SRC/cmd_agent_config.sh" '_config_install_channel "\$prev_channels" "\$type" CH "\$name"'
grep -qE 'telegram\|dashboard\|buzz\|teams\) gate_marketplace="5dive-plugins"' "$SRC/cmd_agent_config.sh" \
  && ok_t "agent config staging gate covers teams" || bad_t "agent config staging gate covers teams"

# 5
both "agent create installs the plugin" "$SRC/cmd_agent_create.sh" 'install_channel_for_agent "\$type" CH "\$name" ""'

# 6
both "5dive-agent-start emits the channel" bin/5dive-agent-start 'ARGS\+=\(--channels "plugin:CH@5dive-plugins"\)'
grep -qE 'channels=teams is claude-only' bin/5dive-agent-start && ok_t "5dive-agent-start refuses non-claude" || bad_t "5dive-agent-start refuses non-claude"

# 7
grep -qF '{"plugin":"teams","marketplace":"5dive-plugins"}' <<<"$FIVEDIVE_CHANNEL_PLUGINS_JSON" \
  && ok_t "managed-settings constant allowlists teams" || bad_t "managed-settings constant allowlists teams"
[[ $(grep -cE '"plugin": ?"teams", ?"marketplace": ?"5dive-plugins"' install.sh) -eq 2 ]] \
  && ok_t "install.sh allowlists teams in both its copies" || bad_t "install.sh allowlists teams in both its copies" "$(grep -n teams install.sh)"

# 8 — run the real gate
(
  for f in lib/local_only.sh; do source "$SRC/$f"; done
  FIVE_LOCAL_ONLY_FILE=$(mktemp); export FIVE_LOCAL_ONLY_FILE
  t() { ( local_only_gate "$@" ) >/dev/null 2>&1; }
  # A local model address, so the only thing create can refuse for is the channel.
  L=--base-url=http://127.0.0.1:11434
  t agent create x --type=claude $L --channels=dashboard && echo "ok create control (dashboard allowed)" || echo "FAIL create control: dashboard refused"
  t agent create x --type=claude $L --channels=teams && echo "FAIL create --channels=teams allowed" || echo "ok create --channels=teams refused"
  t agent config x set channels=telegram,teams && echo "FAIL config channels=teams allowed" || echo "ok config channels=telegram,teams refused"
  t agent teams connect x && echo "FAIL teams connect allowed" || echo "ok agent teams connect refused"
  t agent teams status x && echo "ok agent teams status allowed" || echo "FAIL status refused (a read must stay allowed)"
  t agent config x set channels=dashboard && echo "ok config control (dashboard allowed)" || echo "FAIL config control: dashboard refused"
  out=$( ( local_only_gate agent teams connect x ) 2>&1 )
  [[ "$out" == *"Microsoft Teams"* && $(wc -l <<<"$out") -eq 1 ]] && echo "ok the refusal is one line naming Teams" || echo "FAIL oneline: $out"
  rm -f "$FIVE_LOCAL_ONLY_FILE"
) >"${TMPDIR:-/tmp}/teams_lo.$$" 2>&1
while read -r st rest; do
  [[ "$st" == ok ]] && ok_t "local-only: $rest" || bad_t "local-only: $rest"
done <"${TMPDIR:-/tmp}/teams_lo.$$"
rm -f "${TMPDIR:-/tmp}/teams_lo.$$"

# 9
grep -qE '_plugin_verb_claims teams 2>/dev/null\)" == "teams@5dive-plugins"' "$SRC/main.sh" \
  && ok_t "agent teams dispatches to the official plugin only" || bad_t "agent teams dispatches to the official plugin only"
grep -qE 'Microsoft Teams is a plugin: sudo 5dive plugin install teams' "$SRC/main.sh" \
  && ok_t "without the plugin, agent teams says how to get it" || bad_t "without the plugin, agent teams says how to get it"

# 10
grep -qE 'for _cp in dashboard buzz teams; do' "$SRC/cmd_agent_create.sh" \
  && ok_t "create self-check covers the teams plugin" || bad_t "create self-check covers the teams plugin"

echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
