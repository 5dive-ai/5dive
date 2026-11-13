#!/usr/bin/env bash
# DIVE-8315 — the email channel's core wiring (an agent's own email address).
#
# A channel is not one edit (community/wiki: a-channel-is-six-wiring-sites-and-
# five-green-ones-is-what-broken-looks-like). Every site below is one that, if
# missed, leaves `channels=email` accepted and the agent deaf. Each grep arm has
# a CONTROL that the same pattern finds teams' line, so a green cannot come from
# a regex that matches nothing.
#
#   1. valid_channel accepts email (and not a near-miss)
#   2. install_channel_plugin_for_agent routes it to 5dive-plugins
#   3. install_channel_for_agent refuses non-claude types
#   4. agent config: claude-only check, the install dispatch, the staging gate
#   5. agent create: the per-channel install arm
#   6. 5dive-agent-start emits --channels plugin:email@5dive-plugins
#   7. managed settings allowlist it: header constant AND both install.sh copies
#   8. local-only: email is NOT refused as a channel (a LAN mail server works
#      offline); `config local-only allow email` is accepted; teams' gate is unchanged
#   9. `agent email` dispatches to the OFFICIAL plugin only
#  10. the create-time self-check covers its plugin; agent info lists it
#
# Run: bash tests/email_channel_wiring_unit.sh  (no root, no network).
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
both() {  # <label> <file> <ERE with CH>: email's line exists AND the same pattern finds teams'
  local label="$1" file="$2" pat="$3"
  grep -qE "${pat//CH/teams}" "$file" || { bad_t "CONTROL: $label (pattern finds teams)" "pattern: ${pat//CH/teams}"; return; }
  grep -qE "${pat//CH/email}" "$file" && ok_t "$label" || bad_t "$label" "no match in $file for: ${pat//CH/email}"
}

# 1
valid_channel email && ok_t "valid_channel email" || bad_t "valid_channel email"
valid_channel telegram,teams,email && ok_t "valid_channel telegram,teams,email" || bad_t "valid_channel telegram,teams,email"
valid_channel emails && bad_t "NEGATIVE: emails must be rejected" || ok_t "NEGATIVE: emails rejected"
valid_channel none,email && bad_t "NEGATIVE: none,email must be rejected" || ok_t "NEGATIVE: none,email rejected"

# 2, 3
grep -qE '"\$plugin" == "teams" \|\| "\$plugin" == "email" \]\]; then' "$SRC/lib/agent_setup.sh" \
  && ok_t "install routes email to 5dive-plugins" || bad_t "install routes email to 5dive-plugins"
both "install_channel_for_agent refuses non-claude" "$SRC/lib/agent_setup.sh" '"\$plugin" == "CH" && "\$type" != "claude"'

# 4
both "agent config refuses non-claude before the registry write" "$SRC/cmd_agent_config.sh" '"\$type" != "claude" \]\] && channel_in_list CH "\$v"'
both "agent config dispatches the install" "$SRC/cmd_agent_config.sh" '_config_install_channel "\$prev_channels" "\$type" CH "\$name"'
grep -qE 'telegram\|dashboard\|buzz\|teams\|email\) gate_marketplace="5dive-plugins"' "$SRC/cmd_agent_config.sh" \
  && ok_t "agent config staging gate covers email" || bad_t "agent config staging gate covers email"

# 5
both "agent create installs the plugin" "$SRC/cmd_agent_create.sh" 'install_channel_for_agent "\$type" CH "\$name" ""'

# 6
both "5dive-agent-start emits the channel" bin/5dive-agent-start 'ARGS\+=\(--channels "plugin:CH@5dive-plugins"\)'
grep -qE 'channels=email is claude-only' bin/5dive-agent-start && ok_t "5dive-agent-start refuses non-claude" || bad_t "5dive-agent-start refuses non-claude"

# 7
grep -qF '{"plugin":"email","marketplace":"5dive-plugins"}' <<<"$FIVEDIVE_CHANNEL_PLUGINS_JSON" \
  && ok_t "managed-settings constant allowlists email" || bad_t "managed-settings constant allowlists email"
[[ $(grep -cE '"plugin": ?"email", ?"marketplace": ?"5dive-plugins"' install.sh) -eq 2 ]] \
  && ok_t "install.sh allowlists email in both its copies" || bad_t "install.sh allowlists email in both its copies" "$(grep -n '"email"' install.sh)"

# 8 — run the real gate
(
  for f in lib/local_only.sh; do source "$SRC/$f"; done
  FIVE_LOCAL_ONLY_FILE=$(mktemp); export FIVE_LOCAL_ONLY_FILE
  t() { ( local_only_gate "$@" ) >/dev/null 2>&1; }
  L=--base-url=http://127.0.0.1:11434
  t agent create x --type=claude $L --channels=email && echo "ok create --channels=email allowed offline (a LAN mail server works)" || echo "FAIL create --channels=email refused offline"
  t agent config x set channels=email && echo "ok config channels=email allowed offline" || echo "FAIL config channels=email refused offline"
  t agent create x --type=claude $L --channels=teams && echo "FAIL control: teams allowed offline" || echo "ok control: teams still refused offline"
  [[ " ${LO_ALLOWABLE[*]} " == *" email "* && " ${LO_ALLOWABLE[*]} " == *" teams "* ]] && echo "ok local-only allow knows email and still teams" || echo "FAIL LO_ALLOWABLE=${LO_ALLOWABLE[*]}"
  rm -f "$FIVE_LOCAL_ONLY_FILE"
) >"${TMPDIR:-/tmp}/email_lo.$$" 2>&1
while read -r st rest; do
  [[ "$st" == ok ]] && ok_t "local-only: $rest" || bad_t "local-only: $rest"
done <"${TMPDIR:-/tmp}/email_lo.$$"
rm -f "${TMPDIR:-/tmp}/email_lo.$$"

# 9
grep -qE '_plugin_verb_claims email 2>/dev/null\)" == "email@5dive-plugins"' "$SRC/main.sh" \
  && ok_t "agent email dispatches to the official plugin only" || bad_t "agent email dispatches to the official plugin only"
grep -qE 'Email is a plugin: sudo 5dive plugin install email' "$SRC/main.sh" \
  && ok_t "without the plugin, agent email says how to get it" || bad_t "without the plugin, agent email says how to get it"

# 10
grep -qE 'for _cp in dashboard buzz teams email; do' "$SRC/cmd_agent_create.sh" \
  && ok_t "create self-check covers the email plugin" || bad_t "create self-check covers the email plugin"
grep -qE 'elif ch in \("dashboard", "buzz", "teams", "email"\):' "$SRC/cmd_agent.sh" \
  && ok_t "agent info maps email to its plugin" || bad_t "agent info maps email to its plugin"

echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
