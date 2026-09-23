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
#   sudo /usr/local/bin/5dive-refresh-plugins.sh --status         # what each FORK plugin is running, vs upstream
#
# TWO LINEAGES, ONE SCRIPT (DIVE-3269). The claude-lineage plugin is delivered by
# the marketplace machinery below; the five FORK plugins are STAGED to
# /usr/local/lib/5dive/telegram-<rt>, which until DIVE-3269 nothing wrote — see
# 5dive-stage-fork-plugins.sh for what that cost and the three decisions it settles. `--status` answers "which version is each fork actually running", the
# question whose absence let two merged rows sit undelivered unnoticed.
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

# The agent registry. One name for the path every reader in this script uses —
# the agent enumeration, the fork-lineage bounce list, and (DIVE-4399) the
# parked check below. Overridable so the unit test can point all three at a
# temp file instead of the box's real registry.
AGENTS_REGISTRY="${AGENTS_REGISTRY:-/var/lib/5dive/agents.json}"

# GitHub org migration (5dive-com -> 5dive-ai, 2026-06): existing agents
# persist the marketplace source in THREE places — known_marketplaces.json, the
# marketplace clone's origin remote, and settings.json extraKnownMarketplaces
# (the declaration the other two derive from; DIVE-4867). All break once the old
# org name is parked, so rewrite them as soon as the new org is live. Probe once per
# run; no-op until the rename happens. GH_ORG env overrides the probe.
GH_ORG="${GH_ORG:-}"
if [[ -z "$GH_ORG" ]]; then
  if curl -fsI --max-time 8 "https://raw.githubusercontent.com/5dive-ai/5dive/main/install.sh" >/dev/null 2>&1; then
    GH_ORG="5dive-ai"
  else
    GH_ORG="5dive-com"
  fi
fi

migrate_marketplace_org() {
  local user="$1" home="$2"
  [[ "$GH_ORG" == "5dive-com" ]] && return 0
  local km="$home/.claude/plugins/known_marketplaces.json"
  if [[ -f "$km" ]] && grep -q '5dive-com/' "$km"; then
    # sudo -u (not plain sed -i) so the rewritten file keeps the agent's
    # ownership — sed -i replaces via rename and would leave it root-owned.
    sudo -u "$user" -H sed -i "s#github.com/5dive-com/#github.com/$GH_ORG/#g; s#\"5dive-com/#\"$GH_ORG/#g" "$km" \
      && echo "    migrated known_marketplaces.json -> $GH_ORG"
  fi
  local mpdir url
  for mpdir in "$home"/.claude/plugins/marketplaces/*/; do
    [[ -d "$mpdir/.git" ]] || continue
    url=$(sudo -u "$user" -H git -C "$mpdir" remote get-url origin 2>/dev/null || true)
    case "$url" in
      *github.com/5dive-com/*)
        sudo -u "$user" -H git -C "$mpdir" remote set-url origin "${url//5dive-com/$GH_ORG}" \
          && echo "    migrated $(basename "$mpdir") clone remote -> $GH_ORG" ;;
    esac
  done
  _migrate_settings_marketplace_source "$user" "$home" "$km"
  return 0
}

# >>> DIVE-4867 settings.json carries the marketplace source too
# The two rewrites above left the THIRD copy of the source alone:
# settings.json `.extraKnownMarketplaces.<name>.source`. That copy is the
# declaration, and known_marketplaces.json is Claude Code's state derived from
# it — so the log said "migrated known_marketplaces.json -> 5dive-ai" EVERY night
# on the same seats (the rewrite was being undone between runs), and when the two
# disagree `claude plugin marketplace update` answers `Marketplace '5dive-plugins'
# not found`. telegram@5dive-plugins sat on 0.5.49 on five control-plane seats
# from 2026-08-26 to 2026-09-23 on exactly that.
#
# THE SOURCE MUST MATCH EXACTLY, FORM INCLUDED. A github-form source
# (`{"source":"github","repo":…}`) beside a git-form one
# (`{"source":"git","url":…}`) for the same repo still fails — measured on two
# seats, where rewriting only the org name was not enough. So the settings entry
# takes known_marketplaces' source OBJECT verbatim; the string rewrite is the
# fallback only when known_marketplaces has no usable entry for that name.
#
# SCOPE: only entries whose source names one of OUR orgs. A third-party
# marketplace the operator declared is their configuration, not our migration.
#
# Written as root with `cat >` into the existing file (not a rename), so the
# seat keeps ownership and mode — a root-owned settings.json in a seat's home is
# a seat that can no longer save its own settings.
_migrate_settings_marketplace_source() { # <user> <home> <known_marketplaces.json>
  local user="${1:-}" home="${2:-}" km="${3:-}" st raw before after tmp name
  st="$home/.claude/settings.json"
  [[ -n "$user" && -f "$st" ]] || return 0
  grep -qE '5dive-(com|ai)/' "$st" || return 0
  local kmjson='{}'
  [[ -f "$km" ]] && kmjson=$(jq -c '.' "$km" 2>/dev/null) && [[ -n "$kmjson" ]] || kmjson='{}'
  # Transform the file in its OWN key order and compare sorted: a rewrite must not
  # reorder the seat's whole settings.json to change one source object.
  raw=$(jq -c '.' "$st" 2>/dev/null) && [[ -n "$raw" ]] || {
    echo "    WARN: $st is not valid JSON — marketplace source NOT migrated for $user" >&2; return 0; }
  after=$(jq -c --argjson km "$kmjson" --arg org "$GH_ORG" '
    def ours: tojson | test("5dive-(com|ai)/");
    def stale: tojson | test("5dive-com/");
    if (.extraKnownMarketplaces | type) != "object" then . else
      .extraKnownMarketplaces |= with_entries(
        .key as $n | (.value.source // null) as $s | ($km[$n].source // null) as $k
        | if ($s == null) or ($s | ours | not) then .
          elif ($k != null) and ($k | stale | not) then .value.source = $k
          elif ($s | stale) then .value.source = ($s | tojson | gsub("5dive-com/"; $org + "/") | fromjson)
          else . end)
    end' <<<"$raw" 2>/dev/null) && [[ -n "$after" ]] || return 0
  before=$(jq -S -c '.' <<<"$raw")
  [[ "$(jq -S -c '.' <<<"$after")" != "$before" ]] || return 0
  tmp=$(mktemp) || return 0
  if jq '.' <<<"$after" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]] && cat "$tmp" > "$st"; then
    for name in $(jq -r --argjson b "$before" \
        '.extraKnownMarketplaces // {} | to_entries[] | select(.value.source != ($b.extraKnownMarketplaces[.key].source)) | .key' \
        <<<"$after" 2>/dev/null); do
      echo "    migrated settings.json marketplace $name -> $(jq -c --arg n "$name" '.extraKnownMarketplaces[$n].source' <<<"$after")"
    done
  else
    echo "    WARN: could not write $st — marketplace source NOT migrated for $user" >&2
  fi
  rm -f "$tmp"
  return 0
}
# <<< DIVE-4867 settings.json carries the marketplace source too

RESTART_CHANGED=0
STATUS_ONLY=0
agents=""
for arg in "$@"; do
  case "$arg" in
    --restart) RESTART_CHANGED=1 ;;
    --status)  STATUS_ONLY=1 ;;
    -*) echo "5dive-refresh-plugins: unknown flag: $arg" >&2; exit 2 ;;
    *) agents="${agents:+$agents }$arg" ;;
  esac
done

if [[ ! -x "$CLAUDE_BIN" ]]; then
  echo "5dive-refresh-plugins: $CLAUDE_BIN not executable" >&2
  exit 1
fi

if [[ -z "$agents" ]]; then
  if [[ -r "$AGENTS_REGISTRY" ]] && command -v jq >/dev/null 2>&1; then
    agents=$(jq -r '.agents | keys[]?' "$AGENTS_REGISTRY" 2>/dev/null || true)
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

# >>> DIVE-4852 clear Claude Code's MCP failure cache after the per-seat plugin probe
# `claude plugin update` STARTS the plugin's MCP server to refresh it (Claude Code
# 2.1.278). The server we start here is the seat's telegram channel, and it starts
# WITHOUT the channel secret: `TELEGRAM_BOT_TOKEN` is injected by the unit launcher,
# and `sudo -u <seat>` above is not the unit. It dies in ~375ms, and Claude Code
# records that in `~/.claude/mcp-needs-auth-cache.json`:
#
#     {"plugin:telegram:telegram":{"timestamp":<ms>,"id":"<hash>"}}
#
# For the next FIFTEEN MINUTES every session that seat starts prints "Skipping
# connection (recent failure cached …)" and never spawns the server at all — no
# mcp-logs file, no lifecycle `start` line. A session already inside the window does
# NOT retry when it expires; it stays deaf until it is restarted again.
#
# This script's own `--restart` pass, and `5dive self-update`'s restart loop (which
# runs after install.sh calls us), both bounce seats within ~4 minutes of this probe.
# That is the whole of DIVE-4852: four seats deaf on Telegram 13:19–13:36Z on
# 2026-09-22, main through three restarts, and lodar had to report it. The identical
# probe at 07:15Z the same morning hurt nobody — nothing restarted behind it — which
# is why the hazard sat invisible for three days of 2.1.278.
#
# So the poisoned cache is dropped BEFORE anything can restart the seat. Three fixes
# were on the row; this is the one with no failure mode of its own:
#   (a) drop the entry here                      — taken;
#   (b) run the probe with the channel env       — puts a live bot token into every
#       nightly cron's argv/environment to fix a cache file;
#   (c) refuse to restart inside the 15-min window — makes the nightly refresh a no-op
#       for the seats it JUST updated, i.e. trades deaf for stale, forever.
#
# WHY THE WHOLE FILE AND NOT THE TELEGRAM KEY. Every entry in it was written by this
# same tokenless probe, the file is a NEGATIVE cache and nothing else, and removing
# it costs exactly one retry. Editing it in place has a failure mode that removal
# does not: we run as root here, so a rewritten file is left root-owned in a seat's
# home and that seat can never cache again. `rm` needs no such care — and it is what
# src/lib/agent_setup.sh already does on the create path, for this same reason.
#
# NEVER a silent no-op: an absent receipt and a receipt we failed to print are the
# same empty log, so both outcomes say which one happened.
_clear_mcp_failure_cache() { # <user> <home>
  local user="${1:-}" home="${2:-}" f
  [[ -n "$user" && -n "$home" ]] || return 0
  f="$home/.claude/mcp-needs-auth-cache.json"
  if [[ ! -e "$f" ]]; then
    echo "    mcp failure cache for $user: nothing cached"
    return 0
  fi
  if rm -f "$f" 2>/dev/null && [[ ! -e "$f" ]]; then
    echo "    cleared mcp failure cache for $user"
  else
    # Loud, and NOT fatal. A refresh that aborts here leaves the rest of the fleet
    # on yesterday's plugins to protect one seat's channel — the freeze direction,
    # which DIVE-3269 already measured as the more expensive one.
    echo "    WARN: could not clear $f for $user — if this seat is restarted within 15 minutes it will come up deaf on its channel (fix by hand: rm -f '$f')" >&2
  fi
  return 0
}
# <<< DIVE-4852 clear Claude Code's MCP failure cache after the per-seat plugin probe

# >>> DIVE-4867 a failed claude plugin step is logged and counted
# Until DIVE-4867 each step was piped through `grep -E 'updated|error|warn|fail'`
# — case-sensitive — and Claude Code reports a failure as `✘ Failed to update
# marketplace(s): …`. Capital F: the filter dropped the ONLY line a failure
# prints, so a seat that failed every night for a month logged exactly what a
# seat with nothing to do logs. The DEFAULT of a filter is what decides what the
# operator never sees, so here the direction is inverted: a failure prints
# EVERYTHING it said (capped), and only a success is filtered down.
#
# A step failed when it exits non-zero OR prints a `✘` / fail / error line —
# either alone, because nothing guarantees Claude Code's exit code tracks its
# own `✘`. A failed step makes the seat a failed seat; the run ends with a
# `refresh_failed_count:` line that is printed even at 0 (an absent line cannot
# be told from a run that never reached the count — DIVE-4399's parked_count rule).
REFRESH_FAIL_LINES="${REFRESH_FAIL_LINES:-20}"
FAILED_AGENTS=""
# It runs `claude plugin <args>` and nothing else. The `plugin` word is written HERE,
# at the one real call site, so the plugin-caller sweep in
# tests/self_update_mcp_failure_cache_unit.sh still sees this file as a caller.
# _claude_step <user> <label> <claude plugin args…> — returns 1 when the step failed.
# (Arguments on their own line: the harnesses lift a function by `^name() {$`.)
_claude_step() {
  local user="$1" label="$2" out rc=0 line failed=0 n=0
  shift 2
  out=$(sudo -u "$user" -H "$CLAUDE_BIN" plugin "$@" 2>&1) || rc=$?
  (( rc != 0 )) && failed=1
  grep -qiE '✘|fail|error' <<<"$out" && failed=1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if (( failed )); then
      n=$((n + 1)); (( n > REFRESH_FAIL_LINES )) && continue
    else
      grep -qiE 'updated|already|installed|warn|restart' <<<"$line" || continue
    fi
    echo "    [$label] $line"
  done <<<"$out"
  (( n > REFRESH_FAIL_LINES )) && echo "    [$label] … $((n - REFRESH_FAIL_LINES)) more line(s) not shown"
  if (( failed )); then
    echo "    [$label] FAILED (exit $rc)"
    return 1
  fi
  return 0
}

# Files in a seat's marketplaces dir that the seat does not own make Claude Code's
# own update fail (`EACCES … rmdir 5dive-plugins.bak` on agent-main: 72 root-owned
# files left by an earlier root-run step). Named, not fixed — whether to chown or
# move them aside is a judgement about how they got there.
# _warn_foreign_owned_marketplace_files <user> <home>
_warn_foreign_owned_marketplace_files() {
  local user="${1:-}" home="${2:-}" dir first count
  dir="$home/.claude/plugins/marketplaces"
  [[ -n "$user" && -d "$dir" ]] || return 0
  count=$(find "$dir" ! -user "$user" 2>/dev/null | wc -l)
  (( count > 0 )) || return 0
  first=$(find "$dir" ! -user "$user" 2>/dev/null | head -1)
  echo "    WARN: $count file(s) under $dir are not owned by $user (first: $first) — Claude Code's marketplace update can fail with EACCES on them (seen on agent-main, 2026-09-23)"
  return 0
}

_refresh_summary() {
  local n=0 ag
  for ag in $FAILED_AGENTS; do n=$((n + 1)); done
  if (( n > 0 )); then
    echo "--- $n seat(s) FAILED a plugin step this run: $FAILED_AGENTS — see the FAILED lines above; whatever those steps were fetching did not arrive ---"
    echo "  refresh_failed: $FAILED_AGENTS"
  fi
  echo "  refresh_failed_count: $n"
}
# <<< DIVE-4867 a failed claude plugin step is logged and counted

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

  migrate_marketplace_org "$user" "$home"

  _warn_foreign_owned_marketplace_files "$user" "$home"

  local marketplaces seat_failed=0
  marketplaces=$(printf '%s\n' "$all_keys" | awk -F@ '{print $NF}' | sort -u)
  for mp in $marketplaces; do
    _claude_step "$user" "marketplace $mp" marketplace update "$mp" || seat_failed=1
  done

  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    local verb="update"
    if [[ -n "$installed_keys" ]] && ! grep -Fxq "$key" <<<"$installed_keys"; then
      verb="install"
    elif [[ -z "$installed_keys" ]]; then
      verb="install"
    fi
    _claude_step "$user" "plugin $verb $key" "$verb" "$key" || seat_failed=1
  done <<<"$all_keys"
  (( seat_failed )) && FAILED_AGENTS="${FAILED_AGENTS:+$FAILED_AGENTS }$ag"

  # DIVE-4852: AFTER the last `claude plugin` invocation for this seat and before
  # anything can restart it. Clearing before the probe is a no-op — the probe
  # re-poisons the file microseconds later — so the position of this call is the fix,
  # not the call.
  _clear_mcp_failure_cache "$user" "$home"

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

# DIVE-3269: the FORK lineage is staged by its own script (see its header for the
# three decisions it settles). It is called here rather than from the cron directly
# so that BOTH lineages are delivered by one entry point and one --restart pass — a
# second cron entry is a second thing to forget, and forgetting is this row's defect.
FORK_STAGE_SH="${FORK_STAGE_SH:-$(dirname "${BASH_SOURCE[0]}")/5dive-stage-fork-plugins.sh}"
[[ -x "$FORK_STAGE_SH" ]] || FORK_STAGE_SH=/usr/local/bin/5dive-stage-fork-plugins.sh

if (( STATUS_ONLY )); then
  if [[ -x "$FORK_STAGE_SH" ]]; then "$FORK_STAGE_SH" --status; else
    echo "5dive-refresh-plugins: --status needs 5dive-stage-fork-plugins.sh (not found)" >&2; exit 2; fi
  exit 0
fi

echo "=== $(date -Iseconds) plugin refresh start ==="
for ag in $agents; do
  echo "--- agent-$ag ---"
  refresh_agent "$ag"
done

# Which forks moved, and therefore which fork agents need a bounce. The staging
# script prints `changed: <rt>`; anything else it prints is progress for the log.
FORK_CHANGED=""
if [[ -x "$FORK_STAGE_SH" ]]; then
  while IFS= read -r line; do
    case "$line" in
      "changed: "*) FORK_CHANGED="${FORK_CHANGED:+$FORK_CHANGED }${line#changed: }" ;;
      *) echo "$line" ;;
    esac
  done < <("$FORK_STAGE_SH" 2>&1)
else
  echo "--- fork plugins: SKIPPED — $FORK_STAGE_SH not present ---" >&2
fi

# `type` in the registry IS the runtime, and the fork dir is telegram-<type>; a
# claude-lineage agent is served by the marketplace path above and never matches.
if [[ -n "$FORK_CHANGED" && -r "$AGENTS_REGISTRY" ]] && command -v jq >/dev/null 2>&1; then
  _fork_restart=""
  while IFS=$'\t' read -r _name _type; do
    [[ -n "$_type" && "$_type" != claude && "$_type" != null ]] || continue
    case " $FORK_CHANGED " in *" telegram-$_type "*) _fork_restart="${_fork_restart:+$_fork_restart }$_name" ;; esac
  done < <(jq -r '.agents | to_entries[] | "\(.key)\t\(.value.type // "")"' "$AGENTS_REGISTRY" 2>/dev/null)
  if [[ -n "$_fork_restart" ]]; then
    CHANGED_AGENTS="${CHANGED_AGENTS:+$CHANGED_AGENTS }$_fork_restart"
    echo "--- fork agents needing a bounce: $_fork_restart ---"
  fi
fi

# >>> DIVE-4399 an operator-parked agent stays parked (the plugin-refresh bounce)
# `desiredState: stopped` is the operator's recorded intent (`5dive agent stop`
# writes it). The supervisor, the heartbeat, `agent send --wake`, the objective
# preflight and — since DIVE-4033 — the self-update restart sweep all read it.
# THIS path never did: `git grep -n desiredState` over this file returned zero
# hits, and `systemctl restart` on a stopped unit STARTS it. Measured on
# `5dive-teal-fox-cx43`: `katya` carries `desiredState: stopped`, had been
# resurrected nightly for roughly a month, and masking the unit by hand was the
# only defence the operator found. `systemctl disable` is not one — it stops
# boot-time activation, not an explicit restart.
#
# WHY THIS FILE AND NOT src/. DIVE-4033 fixed the same defect on the same agent
# and looked for siblings with `git grep -l desiredState -- src scripts`. This
# script sits at the REPO ROOT, outside that filter, so the sweep that was meant
# to make the fix complete structurally could not see the one path still broken.
# See community/wiki/an-audit-grep-with-a-path-filter-cannot-find-the-file-outside-the-filter.md
#
# IT SKIPS, IT DOES NOT ENFORCE (DIVE-4033's shape, deliberately not a second
# one). Stopping a running-but-parked agent from a plugin-refresh cron is
# destructive and is the supervisor's job; reconciling registry against systemd
# is not this script's. So the bounce declines to perpetuate the contradiction
# by its own action, says so once per parked agent, and names BOTH exits —
# only a person knows which is the right one.
#
# THE SKIPPED BOUNCE IS OWED TO NOBODY. The plugin refresh itself already ran
# for this agent: its on-disk plugin cache is current, and Claude reads plugins
# at launch. A parked-and-stopped agent therefore loads the new payload on its
# next start by construction, and a parked-but-running one loads it whenever the
# operator takes either exit. Nothing is deferred and nothing is lost.
#
# ABSENT IS NOT STOPPED, AND UNREADABLE IS NOT STOPPED (DIVE-2318, and the
# `// "running"` default every other reader uses). The two failure directions are
# not symmetric: a wrong skip silently freezes agents on the old plugin build —
# the exact silent-dormancy class DIVE-3269 measured on this very script, where
# five staged plugins sat an hour behind two merged rows and nobody could tell
# — while a wrong restart is loud and recoverable. So ONLY an explicit,
# parseable `stopped` skips. A missing registry, absent jq, a corrupt body, an
# agent with no such field and an agent absent from the file ALL restart.
_agent_is_parked() {
  local name="${1:-}" desired=""
  [[ -n "$name" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [[ -n "${AGENTS_REGISTRY:-}" && -r "$AGENTS_REGISTRY" ]] || return 1
  desired=$(jq -r --arg n "$name" '.agents[$n].desiredState // "running"' "$AGENTS_REGISTRY" 2>/dev/null) || return 1
  [[ "$desired" == "stopped" ]]
}

# The line the operator reads in the nightly log. It names both exits because
# either can be correct and a bare "skipped" would read as a decision already
# taken on their behalf.
_parked_skip_note() {
  local n="${1:-}"
  printf "  parked: agent-%s has new plugins on disk but the registry says desiredState=stopped — NOT restarting it, and not stopping it either. Nothing is owed: the refreshed plugins load on its next start. Reconcile: '5dive agent stop %s' if the park is real, '5dive agent start %s' if the intent is stale.\n" "$n" "$n" "$n"
}

# --restart: bounce only the agents whose plugin set changed, so the new code
# actually loads — minus the ones the operator parked. Deferred via systemd-run
# (--on-active=1 --collect) so the restart fires ~1s after we exit: this both
# lets this script finish cleanly and makes it safe for an agent to restart
# ITSELF (the transient unit outlives our teardown).
#
# `parked` / `parked_count` are emitted as their own machine-readable lines, in
# the pair DIVE-4033 put on the self-update JSON, so "which agents did the cron
# decline to bounce last night" is greppable and not only prose. parked_count is
# printed on EVERY --restart pass, including 0 — an absent line would be
# indistinguishable from a pass that never reached the check.
_restart_changed_agents() {
  local list="${1:-}" ag parked_count=0 restarted=0
  if [[ -z "$list" ]]; then
    echo "--- --restart: no agents changed, nothing to bounce ---"
    echo "  parked_count: 0"
    return 0
  fi
  echo "--- restarting changed agents: $list ---"
  for ag in $list; do
    if _agent_is_parked "$ag"; then
      parked_count=$((parked_count + 1))
      _parked_skip_note "$ag"
      continue
    fi
    if systemd-run --on-active=1 --collect \
         /bin/systemctl restart "5dive-agent@${ag}.service" >/dev/null 2>&1; then
      restarted=$((restarted + 1))
      echo "  scheduled restart: agent-$ag (~1s)"
    else
      echo "  WARN: failed to schedule restart for agent-$ag" >&2
    fi
  done
  echo "  parked_count: $parked_count"
  return 0
}
# <<< DIVE-4399 an operator-parked agent stays parked (the plugin-refresh bounce)

if (( RESTART_CHANGED )); then
  _restart_changed_agents "$CHANGED_AGENTS"
fi

_refresh_summary
echo "=== $(date -Iseconds) plugin refresh done ==="
