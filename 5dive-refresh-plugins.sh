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
#   sudo /usr/local/bin/5dive-refresh-plugins.sh                  # all agents
#   sudo /usr/local/bin/5dive-refresh-plugins.sh main             # one agent (sans agent- prefix)
#   sudo /usr/local/bin/5dive-refresh-plugins.sh --restart        # all + restart changed agents
#   sudo /usr/local/bin/5dive-refresh-plugins.sh --restart dev    # one + restart if it changed
#
# --restart: after refreshing, bounce any agent whose plugin set actually
# changed so the new version LOADS (Claude reads plugins once at launch — a
# refresh alone updates the on-disk cache but the running agent keeps the old
# code in memory until restart). Restarts are deferred via systemd-run so they
# survive this script's own teardown and are safe even for the agent that
# invoked us (e.g. a session restarting itself).

set -uo pipefail

CLAUDE_BIN="${CLAUDE_BIN:-/home/claude/.local/bin/claude}"
# How many plugin-cache versions to retain per plugin during prune. >=2 keeps
# the freshly-installed (active) version PLUS the previous one, so a still-
# running agent that loaded the previous version doesn't get its plugin dir
# yanked out from under it (which surfaces as a "Plugin directory does not
# exist" stop-hook error and breaks its hooks until restart). Set to 1 to keep
# only the active version (old behavior); 0 disables pruning.
KEEP_PLUGIN_VERSIONS="${KEEP_PLUGIN_VERSIONS:-2}"

RESTART_CHANGED=0
agents=""
for arg in "$@"; do
  case "$arg" in
    --restart) RESTART_CHANGED=1 ;;
    -*) echo "5dive-refresh-plugins: unknown flag: $arg" >&2; exit 2 ;;
    *) agents="${agents:+$agents }$arg" ;;
  esac
done

if [[ ! -x "$CLAUDE_BIN" ]]; then
  echo "5dive-refresh-plugins: $CLAUDE_BIN not executable" >&2
  exit 1
fi

if [[ -z "$agents" ]]; then
  if [[ -r /var/lib/5dive/agents.json ]] && command -v jq >/dev/null 2>&1; then
    agents=$(jq -r '.agents | keys[]?' /var/lib/5dive/agents.json 2>/dev/null || true)
  fi
  if [[ -z "$agents" ]]; then
    agents=$(for d in /home/agent-*; do [[ -d "$d" ]] && basename "$d" | sed 's/^agent-//'; done)
  fi
fi

# Agents whose plugin set changed this run (populated by refresh_agent), used
# by the --restart pass at the end.
CHANGED_AGENTS=""

snapshot_state() {
  local installed="$1"
  [[ -r "$installed" ]] || return 0
  jq -r '.plugins // {} | to_entries[] | "\(.key) \(.value[0].version // "?") \(.value[0].gitCommitSha // "?" | .[0:7])"' \
     "$installed" 2>/dev/null
}

# Drop stale plugin-cache versions for one user. `claude plugin update` fetches
# each new version into ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/
# (~29M each w/ its own node_modules) and repoints installed_plugins.json, but
# never deletes the old version dirs — so they pile up per release.
#
# Per plugin we keep a KEEP-set: the active installPath FIRST, then the
# next-newest version dirs (by version sort) until KEEP_PLUGIN_VERSIONS total.
# Keeping >=2 means a still-running agent that loaded the previous version
# isn't left with a deleted plugin dir (the "Plugin directory does not exist"
# stop-hook failure). The active dir is only used as an anchor when it still
# exists — a stale manifest must never make us delete the live version. Runs
# as root here.
prune_plugin_cache() {
  local home="$1"
  local cache="$home/.claude/plugins/cache"
  local manifest="$home/.claude/plugins/installed_plugins.json"
  [[ -d "$cache" && -r "$manifest" ]] || return 0
  [[ "$KEEP_PLUGIN_VERSIONS" -ge 1 ]] || { echo "    (prune disabled: KEEP_PLUGIN_VERSIONS=$KEEP_PLUGIN_VERSIONS)"; return 0; }
  local keep
  keep=$(jq -r '.plugins // {} | to_entries[] | .value[]? | .installPath // empty' "$manifest" 2>/dev/null)
  [[ -n "$keep" ]] || return 0
  local active parent v pruned=0
  while IFS= read -r active; do
    [[ -z "$active" ]] && continue
    case "$active" in "$cache"/*) ;; *) continue ;; esac
    [[ -d "$active" ]] || { echo "    (skip prune $(basename "$active"): active dir missing)"; continue; }
    parent=$(dirname "$active")
    # Build the keep-set for this plugin: active first, then newest-by-version
    # until we hit KEEP_PLUGIN_VERSIONS.
    local keepset=" $active "
    local kept=1 cand
    for cand in $(ls -1 "$parent" 2>/dev/null | sort -Vr); do
      [[ "$kept" -ge "$KEEP_PLUGIN_VERSIONS" ]] && break
      [[ -d "$parent/$cand" ]] || continue
      [[ "$parent/$cand" == "$active" ]] && continue
      keepset+=" $parent/$cand "
      kept=$((kept+1))
    done
    for v in "$parent"/*; do
      [[ -d "$v" ]] || continue
      [[ "$keepset" == *" $v "* ]] && continue
      rm -rf "$v" && pruned=$((pruned+1))
    done
  done <<<"$keep"
  for v in "$cache"/*.bak-*; do [[ -e "$v" ]] || continue; rm -rf "$v"; pruned=$((pruned+1)); done
  [[ "$pruned" -gt 0 ]] && echo "    pruned $pruned stale plugin-cache dir(s) (kept $KEEP_PLUGIN_VERSIONS newest/plugin)"
  return 0
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

  # Record whether the plugin set actually moved (version/commit changed, or a
  # plugin was newly installed). The --restart pass uses this so we only bounce
  # agents that have something new to load.
  if [[ "$before" != "$after" ]]; then
    CHANGED_AGENTS="${CHANGED_AGENTS:+$CHANGED_AGENTS }$ag"
  fi

  # Now that installed_plugins.json points at the freshly fetched versions,
  # drop the superseded ones so the cache doesn't grow unbounded per release.
  prune_plugin_cache "$home"
}

echo "=== $(date -Iseconds) plugin refresh start ==="
for ag in $agents; do
  echo "--- agent-$ag ---"
  refresh_agent "$ag"
done

# --restart: bounce only the agents whose plugin set changed, so the new code
# actually loads. Deferred via systemd-run (--on-active=1 --collect) so the
# restart fires ~1s after we exit — this both lets this script finish cleanly
# and makes it safe for an agent to restart ITSELF (the transient unit outlives
# our teardown). No-op when nothing changed.
if (( RESTART_CHANGED )); then
  if [[ -n "$CHANGED_AGENTS" ]]; then
    echo "--- restarting changed agents: $CHANGED_AGENTS ---"
    for ag in $CHANGED_AGENTS; do
      if systemd-run --on-active=1 --collect \
           /bin/systemctl restart "5dive-agent@${ag}.service" >/dev/null 2>&1; then
        echo "  scheduled restart: agent-$ag (~1s)"
      else
        echo "  WARN: failed to schedule restart for agent-$ag" >&2
      fi
    done
  else
    echo "--- --restart: no agents changed, nothing to bounce ---"
  fi
fi
echo "=== $(date -Iseconds) plugin refresh done ==="
