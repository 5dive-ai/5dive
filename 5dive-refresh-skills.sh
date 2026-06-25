#!/usr/bin/env bash
# Backfill default skills onto every existing agent user. New agents get the
# default skill set at create time (install_default_skill_for_agent in the
# CLI); this script brings already-provisioned boxes up to the same set so a
# newly-added default skill (e.g. `openagent`, DIVE-658) lands on agents that
# were created before it joined the defaults. Idempotent.
#
# Per agent: for each default skill, force re-pull it via
# `5dive agent skill <name> add --force` (which resolves the agent's type,
# install dir, and sandbox strategy from the registry — no duplication here).
#
# FORCE RE-PULL, NOT install-if-missing (DIVE-698): these are pinned/managed
# skills, so an already-present copy may be a STALE version (e.g. an old
# openagent from before the v0.27 pin). Skipping on presence meant the pin only
# ever reached brand-new agents; --force drops the existing dir and re-pulls the
# current pinned version so upgrades actually land on existing boxes too.
#
# NEVER-BOOTED GOTCHA: `npx skills add` writes to the agent user's ~/.claude,
# which only exists after the agent's service has booted at least once. On a
# never-booted user the install errors and can leave a half-written tree, so we
# skip any agent whose ~/.claude is absent — it'll get the skill from the
# create-path seed or the next refresh after it first boots.
#
# Called by the daily host/customer update cron (install.sh --upgrade path)
# right after 5dive-refresh-plugins.sh, before agents restart.
#
# Standalone usage:
#   sudo /usr/local/bin/5dive-refresh-skills.sh            # all agents
#   sudo /usr/local/bin/5dive-refresh-skills.sh dev        # one agent (sans agent- prefix)

set -uo pipefail

FIVE_BIN="${FIVE_BIN:-/usr/local/bin/5dive}"

# Default skills every agent should carry, as `<owner/repo>:<skill-id>` specs.
# Keep in sync with install_default_skill_for_agent calls in the CLI's
# lib/agent_setup.sh. find-skills / 5dive-cli / compile-knowledge are seeded at
# create time and rarely change; the backfill's job is mainly to roll out
# newly-added defaults like openagent onto pre-existing boxes.
DEFAULT_SKILLS=(
  "5dive-ai/skills:openagent"
)

[[ -x "$FIVE_BIN" ]] || { echo "no 5dive at $FIVE_BIN — skipping skills refresh" >&2; exit 0; }

# Resolve the requested agents: an explicit name argument, else every
# registered agent (registry first, /home/agent-* fallback like
# 5dive-refresh-plugins.sh).
if [[ $# -gt 0 ]]; then
  agents="$1"
elif [[ -r /var/lib/5dive/agents.json ]] && command -v jq >/dev/null 2>&1; then
  agents=$(jq -r '.agents | keys[]?' /var/lib/5dive/agents.json 2>/dev/null || true)
else
  agents=$(for d in /home/agent-*; do [[ -d "$d" ]] && basename "$d" | sed 's/^agent-//'; done)
fi
[[ -n "${agents// }" ]] || { echo "no agents to refresh"; exit 0; }

refreshed=0 failed=0 booting=0
for ag in $agents; do
  user="agent-$ag"
  home=$(getent passwd "$user" | cut -d: -f6)
  [[ -n "$home" && -d "$home" ]] || continue

  # Never-booted guard: ~/.claude is created on first boot; skip until then.
  if [[ ! -d "$home/.claude" ]]; then
    echo "· $ag — not booted yet (~/.claude absent), skipping"
    booting=$((booting+1))
    continue
  fi

  # Force re-pull every managed default to its current pinned version. No
  # skip-if-present check: that's the whole point (DIVE-698) — an existing copy
  # might be stale, and `add --force` drops it before re-pulling.
  for spec in "${DEFAULT_SKILLS[@]}"; do
    source="${spec%%:*}" skill="${spec#*:}"
    echo "+ $ag — re-pulling $skill from $source"
    if "$FIVE_BIN" agent skill "$ag" add --source="$source" --skill="$skill" --force >&2; then
      refreshed=$((refreshed+1))
    else
      echo "  warn: $skill refresh failed for $ag (continuing)" >&2
      failed=$((failed+1))
    fi
  done
done

echo "skills refresh done: $refreshed re-pulled, $failed failed, $booting awaiting first boot"
