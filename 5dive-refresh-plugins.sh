#!/usr/bin/env bash
# Refresh every agent user's claude plugins so they're at the marketplace
# HEAD before the next claude restart. Idempotent.
#
# Per agent: take the union of `settings.json .enabledPlugins` keys and
# `installed_plugins.json .plugins` keys. For each unique marketplace,
# pull the local mirror; then for each key:
#   - if already in installed_plugins.json → `claude plugin update`
#   - else (enabled but never explicit-installed)  → `claude plugin install`
#
# Auto-install handles the case where a plugin was enabled via
# settings.json directly (no record in installed_plugins.json) — those
# can drift indefinitely because `claude plugin update` errors with
# "Plugin not installed".
#
# Called by the daily host/customer update cron before the next agent
# restart so newly fetched plugin versions actually load on next boot.
#
# Standalone usage:
#   sudo /usr/local/bin/5dive-refresh-plugins.sh           # all agents
#   sudo /usr/local/bin/5dive-refresh-plugins.sh main      # one agent (sans agent- prefix)

set -uo pipefail

CLAUDE_BIN="${CLAUDE_BIN:-/home/claude/.local/bin/claude}"

if [[ ! -x "$CLAUDE_BIN" ]]; then
  echo "5dive-refresh-plugins: $CLAUDE_BIN not executable" >&2
  exit 1
fi

if [[ $# -ge 1 ]]; then
  agents="$*"
else
  agents=""
  if [[ -r /var/lib/5dive/agents.json ]] && command -v jq >/dev/null 2>&1; then
    agents=$(jq -r '.agents | keys[]?' /var/lib/5dive/agents.json 2>/dev/null || true)
  fi
  if [[ -z "$agents" ]]; then
    agents=$(for d in /home/agent-*; do [[ -d "$d" ]] && basename "$d" | sed 's/^agent-//'; done)
  fi
fi

snapshot_state() {
  local installed="$1"
  [[ -r "$installed" ]] || return 0
  jq -r '.plugins // {} | to_entries[] | "\(.key) \(.value[0].version // "?") \(.value[0].gitCommitSha // "?" | .[0:7])"' \
     "$installed" 2>/dev/null
}

refresh_agent() {
  local ag="$1"
  local user="agent-$ag"

  if ! id -u "$user" >/dev/null 2>&1; then
    echo "  skip $user (no such user)"
    return
  fi

  local home settings installed
  home=$(getent passwd "$user" | cut -d: -f6)
  settings="$home/.claude/settings.json"
  installed="$home/.claude/plugins/installed_plugins.json"

  local enabled_keys="" installed_keys="" all_keys
  [[ -r "$settings" ]]  && enabled_keys=$(jq -r '.enabledPlugins // {} | keys[]?' "$settings" 2>/dev/null)
  [[ -r "$installed" ]] && installed_keys=$(jq -r '.plugins // {} | keys[]?' "$installed" 2>/dev/null)
  all_keys=$(printf '%s\n%s\n' "$enabled_keys" "$installed_keys" | grep -v '^$' | sort -u)

  if [[ -z "$all_keys" ]]; then
    echo "  $user: no enabled or installed plugins"
    return
  fi

  local before
  before=$(snapshot_state "$installed")
  if [[ -n "$before" ]]; then
    echo "  $user: before:"
    while IFS= read -r line; do echo "    $line"; done <<<"$before"
  fi

  local marketplaces
  marketplaces=$(printf '%s\n' "$all_keys" | awk -F@ '{print $NF}' | sort -u)
  for mp in $marketplaces; do
    sudo -u "$user" -H "$CLAUDE_BIN" plugin marketplace update "$mp" 2>&1 \
      | sed "s/^/    [marketplace $mp] /" \
      | grep -E 'updated|error|warn|fail' || true
  done

  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    local verb="update"
    if [[ -n "$installed_keys" ]] && ! grep -Fxq "$key" <<<"$installed_keys"; then
      verb="install"
    elif [[ -z "$installed_keys" ]]; then
      verb="install"
    fi
    sudo -u "$user" -H "$CLAUDE_BIN" plugin "$verb" "$key" 2>&1 \
      | sed "s/^/    [plugin $verb $key] /" \
      | grep -E 'updated|already|installed|error|warn|fail|Restart' || true
  done <<<"$all_keys"

  local after
  after=$(snapshot_state "$installed")
  if [[ -n "$after" ]]; then
    echo "  $user: after:"
    while IFS= read -r line; do echo "    $line"; done <<<"$after"
  fi
}

echo "=== $(date -Iseconds) plugin refresh start ==="
for ag in $agents; do
  echo "--- agent-$ag ---"
  refresh_agent "$ag"
done
echo "=== $(date -Iseconds) plugin refresh done ==="
