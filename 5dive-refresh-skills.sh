#!/usr/bin/env bash
# Backfill default skills onto every existing agent user. New agents get the
# same set at create time (preseed_default_skills_for_type in the CLI); this
# script brings already-provisioned boxes up to it, so a newly-added default
# lands on agents created before it joined the list. Both halves read ONE list
# — see DIVE-4203 below. Idempotent.
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
#   REFRESH_SKILLS_PRINT_PLAN=1 /usr/local/bin/5dive-refresh-skills.sh  # list only, touch nothing

set -uo pipefail

FIVE_BIN="${FIVE_BIN:-/usr/local/bin/5dive}"

# THE DEFAULT-SKILLS LIST LIVES IN ONE PLACE, AND IT IS NOT HERE (DIVE-4203).
# It is DEFAULT_AGENT_SKILLS in the CLI's src/lib/agent_setup.sh, read back below
# via the hidden `5dive agent _default_skills` primitive.
#
# Why: this file used to carry its own hand-maintained DEFAULT_SKILLS array, and
# it had already drifted from the provisioner's — the create path seeded four
# skills, this array held one. The consequence was not cosmetic. DIVE-4130
# removed `openagent` from 16 of 16 on-type seats and PR #837 removed it from
# THIS array so the nightly force re-pull would stop reverting the deletion; the
# create path still seeded it, so the fleet-wide removal lasted exactly until the
# next `5dive agent create`. Fixing the reconciler does not fix the provisioner.
# One list, two consumers, and tests/default_skills_single_list_unit.sh diffs
# them so they cannot drift apart again.
#
# FORCE RE-PULL, NOT install-if-missing (DIVE-698) — see the header above; that
# is also why membership in this list makes a skill unremovable per seat, and why
# a removal has to be an edit to the LIST rather than N `rm`s.

[[ -x "$FIVE_BIN" ]] || { echo "no 5dive at $FIVE_BIN — skipping skills refresh" >&2; exit 0; }

# Read THE list. A bundle too old to know `_default_skills` prints nothing and
# exits non-zero; say so and refresh NOTHING rather than fall back to a second
# hardcoded copy — a silent fallback list is the drift this row exists to end,
# and the installer refreshes the bundle before it runs this script, so an empty
# read here means something is genuinely wrong.
mapfile -t DEFAULT_SKILLS < <("$FIVE_BIN" agent _default_skills 2>/dev/null || true)
if [[ ${#DEFAULT_SKILLS[@]} -eq 0 ]]; then
  echo "warn: '$FIVE_BIN agent _default_skills' returned no skills — refreshing nothing." >&2
  echo "      (bundle predates DIVE-4203? upgrade the CLI, then re-run this script.)" >&2
  exit 0
fi

# Plan seam (DIVE-4203): print the resolved list and stop, touching no agent.
# Two callers — an operator asking "what would tonight's refresh pull?", and
# tests/default_skills_single_list_unit.sh, which diffs THIS output against what
# the provisioner seeds. The drift arm needs the refresh half of the comparison
# to be readable without a box, 17 seats and a network.
if [[ -n "${REFRESH_SKILLS_PRINT_PLAN:-}" ]]; then
  printf '%s\n' "${DEFAULT_SKILLS[@]}"
  exit 0
fi

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

changed=0 unchanged=0 first_install=0 failed=0 booting=0
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
    # DIVE-2282: --json so we can read back the content hash the installer now
    # records in the per-agent skills manifest. "N re-pulled" couldn't tell an
    # unchanged re-pull from a rewritten skill body — .data.changed and
    # .data.previous_content_sha256 can. Exit status still decides pass/fail
    # (jq only buckets), so a box without jq degrades but never miscounts a
    # failure. Progress chatter stays on stderr and still reaches the cron log.
    if out=$("$FIVE_BIN" agent skill "$ag" add --source="$source" --skill="$skill" --force --json); then
      prev=$(jq -r '.data.previous_content_sha256 // ""' <<<"$out" 2>/dev/null)
      if [[ -z "$prev" ]]; then
        echo "  first install (no previous hash on record)"
        first_install=$((first_install+1))
      elif [[ "$(jq -r '.data.changed // false' <<<"$out" 2>/dev/null)" == "true" ]]; then
        echo "  changed (content hash differs from previous)"
        changed=$((changed+1))
      else
        echo "  unchanged"
        unchanged=$((unchanged+1))
      fi
    else
      echo "  warn: $skill refresh failed for $ag (continuing)" >&2
      failed=$((failed+1))
    fi
  done
done

echo "skills refresh done: $changed changed, $unchanged unchanged, $first_install first-install, $failed failed, $booting awaiting first boot"
