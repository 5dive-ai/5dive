#!/usr/bin/env bash
# Concatenate src/ into the single-file `5dive` binary the installer fetches.
#
# Why a build step: the installed artifact is a single file (curl install.5dive.com
# | sudo bash drops one binary into /usr/local/bin). The source repo is split for
# readability — see CONTRIBUTING in README.md. CI runs ./build.sh && git diff
# --exit-code 5dive on every push to catch "edited the bundle, forgot to edit
# src/" drift in either direction.
#
# Order matters: header.sh has `set -euo pipefail` + every global / declare -A
# map, so it must come first. main.sh has the EXIT trap and `main "$@"`, so it
# must come last. The middle is grouped by concern (lib/ helpers → cmd_*
# subcommands). state.sh / audit.sh / registry.sh look interleaved because the
# original script's audit block sat between ensure_state and with_registry_lock;
# keeping that order makes the bundle byte-identical with the pre-refactor file.
set -euo pipefail

cd "$(dirname "$0")"

# Output path is overridable (BUILD_OUT) so tests can build a throwaway binary to a
# temp dir without dirtying the tracked ./5dive artifact. Defaults to the repo ./5dive.
OUT="${BUILD_OUT:-5dive}"

cat \
  src/header.sh \
  src/lib/error_codes.sh \
  src/lib/output.sh \
  src/lib/validation.sh \
  src/lib/agent_setup.sh \
  src/lib/state.sh \
  src/lib/audit.sh \
  src/lib/registry.sh \
  src/lib/tasks_db.sh \
  src/cmd_auth.sh \
  src/cmd_account.sh \
  src/cmd_agent.sh \
  src/cmd_agent_create.sh \
  src/cmd_agent_lifecycle.sh \
  src/cmd_agent_config.sh \
  src/cmd_agent_telegram.sh \
  src/cmd_agent_teambot.sh \
  src/cmd_agent_pairing.sh \
  src/cmd_agent_runtime.sh \
  src/cmd_cos.sh \
  src/cmd_skill.sh \
  src/cmd_init.sh \
  src/cmd_doctor.sh \
  src/cmd_watch.sh \
  src/cmd_compose.sh \
  src/cmd_task.sh \
  src/cmd_trace.sh \
  src/cmd_org.sh \
  src/cmd_hire.sh \
  src/cmd_project.sh \
  src/cmd_goal.sh \
  src/cmd_objective.sh \
  src/cmd_company.sh \
  src/cmd_council.sh \
  src/cmd_constitution.sh \
  src/cmd_loop.sh \
  src/cmd_loop_pack.sh \
  src/cmd_crew.sh \
  src/cmd_heartbeat.sh \
  src/cmd_supervisor.sh \
  src/cmd_fleet.sh \
  src/cmd_usage.sh \
  src/cmd_digest.sh \
  src/cmd_proof.sh \
  src/cmd_push.sh \
  src/cmd_memory.sh \
  src/cmd_pack.sh \
  src/cmd_secret.sh \
  src/cmd_selfupdate.sh \
  src/main.sh \
  > "$OUT"

# DIVE-1261: publish a sha256 of the bundle so the installer can verify the fetched binary before
# swapping it in. Regenerated on every build and committed alongside the bundle; CI's build+diff
# drift check keeps the two in sync.
#
# CNCL-23 regression: generate the sha IMMEDIATELY after writing the bundle, BEFORE any step that
# could abort under `set -e` (the chmod below, the FIVE_VERSION check) — otherwise the bundle and
# its committed sha can DRIFT. A `chmod: Operation not permitted` (building a claude-owned worktree
# as another user) once aborted right before the old sha line, shipping a 0.12.7 bundle carrying
# 0.12.6's sha (PR #95 — CI drift-gate RED, host-roll refused on the mismatch). Order now
# guarantees: whenever $OUT exists on disk post-build, $OUT.sha256 matches it.
sha256sum "$OUT" | awk '{print $1}' > "$OUT.sha256"

# +x is a local convenience (the installer re-chmods the fetched binary); a cross-user perms
# failure must NOT abort the build and re-open the sha-drift window above.
chmod +x "$OUT" 2>/dev/null || true

# Sanity-check the version line landed in the bundle. CI's bundle-drift check
# already catches missing src→bundle plumbing, but this gives a tighter error
# when someone empties out FIVE_VERSION by accident.
if ! grep -qE '^readonly FIVE_VERSION="[^"]+"' "$OUT"; then
  echo "error: $OUT is missing FIVE_VERSION — check src/header.sh" >&2
  exit 1
fi

echo "built $OUT ($(wc -l < "$OUT") lines, $(grep -oE '^readonly FIVE_VERSION="[^"]+"' "$OUT" | cut -d'"' -f2)) + $OUT.sha256 ($(cut -c1-16 "$OUT.sha256")…)"
