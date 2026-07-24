#!/usr/bin/env bash
# Install the fleet-wide pre-push PII guard (DIVE-1797) on a 5dive-ai/5dive
# checkout by pointing git at the in-repo hook via core.hooksPath.
#
# One install per CLONE covers the whole worktree family: core.hooksPath lives in
# the shared clone config, so every existing linked worktree AND every future
# `git worktree add` inherits it automatically. Relative path `scripts/git-hooks`
# resolves against each worktree's own root at hook time, so each push is gated by
# the hook committed on the branch it is pushing.
#
# Idempotent. Safe to re-run from the daily update path. No-op (exit 0) on any
# directory that is not a 5dive-ai/5dive checkout, so provisioning can call it
# blindly on every box.
#
# Usage:
#   scripts/install-pii-push-guard.sh [repo-dir]   # default: this script's repo
set -uo pipefail

DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Must be a git checkout of the CLI repo. Match the origin loosely (ssh or https,
# with or without .git) so it works regardless of how the box cloned it.
url="$(git -C "$DIR" config --get remote.origin.url 2>/dev/null || true)"
case "$url" in
  *5dive-ai/5dive*) ;;
  *) echo "pii-push-guard: $DIR is not a 5dive-ai/5dive checkout — skipping." >&2; exit 0 ;;
esac

# Must carry the hook on this checkout (skip stale branches predating the hook;
# they inherit the config anyway once they rebase onto main).
top="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$top" ]] || { echo "pii-push-guard: $DIR has no worktree — skipping." >&2; exit 0; }

# Set on the SHARED config (covers all worktrees). --local writes to the common
# config for a worktree, which is exactly what we want here.
current="$(git -C "$DIR" config --local --get core.hooksPath 2>/dev/null || true)"
if [[ "$current" != "scripts/git-hooks" ]]; then
  git -C "$DIR" config --local core.hooksPath scripts/git-hooks
fi

# Make sure the committed hook is executable on this checkout (if present).
[[ -f "$top/scripts/git-hooks/pre-push" ]] && chmod +x "$top/scripts/git-hooks/pre-push" 2>/dev/null || true

echo "pii-push-guard: core.hooksPath=scripts/git-hooks set on $(git -C "$DIR" rev-parse --git-common-dir 2>/dev/null)"
