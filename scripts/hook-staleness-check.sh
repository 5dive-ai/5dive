#!/usr/bin/env bash
# DIVE-2072: detect a branch whose repo-tracked git hooks are BEHIND main's.
#
# core.hooksPath=scripts/git-hooks means git runs the hook FROM THE WORKING TREE
# — the copy at your branch's commit, not main's. So a guard added to main is
# silently absent on every branch cut before it. Measured: 852285e added the
# version-bump guard; a branch based on 7e5d8f8 pushed with 0 references to it
# and nothing said so. An absent hook does not fail, it simply does not run, and
# the push looks clean. 'The guard did not block me' and 'the guard was not
# there' are indistinguishable from the pusher's side.
#
# A missing hook cannot announce its own absence, so the detection has to live
# somewhere that is present when the hook is not: here, at PR time, where the
# remedy (rebase) is still cheap and the damage has not landed.
#
# THE PREDICATE, and why it is not a bare diff against main. A bare
# `git diff origin/main -- scripts/git-hooks/` fires on any branch whose hook
# differs for ANY reason — including the PR that is deliberately IMPROVING the
# hook, which is the one PR that must never be told to rebase away its own work.
# Staleness is specifically "main moved and this branch did not":
#
#   base := merge-base(HEAD, main)
#   STALE  iff  hooks@HEAD == hooks@base   (this branch did not touch them)
#         and   hooks@main != hooks@base   (main did)
#
# A branch that edits the hooks itself is NOT stale by this test, whatever it
# contains — it has its own opinion and git will surface any conflict at rebase.
#
# Usage: hook-staleness-check.sh [head-ref] [main-ref] [hook-dir]
# Exit: 0 = current or branch-owns-the-hooks; 1 = STALE; 2 = could not determine.
set -uo pipefail

HEAD_REF="${1:-HEAD}"
MAIN_REF="${2:-origin/main}"
HOOK_DIR="${3:-scripts/git-hooks}"

# Fail-open must be LOUD, and two different fall-through causes must not share
# one message (wiki: stubbed-boundary-format-contract, rule 2) — an operator who
# learns to skip the routine one stops reading the one that means something.
if ! git rev-parse --verify --quiet "$MAIN_REF" >/dev/null; then
  echo "hook-staleness: UNDETERMINED — no such ref '$MAIN_REF' (shallow clone, or the base was never fetched)." >&2
  echo "hook-staleness: this is NOT a pass; the check did not run. Fetch the base ref and re-run." >&2
  exit 2
fi
if ! BASE=$(git merge-base "$HEAD_REF" "$MAIN_REF" 2>/dev/null) || [[ -z "$BASE" ]]; then
  echo "hook-staleness: UNDETERMINED — no merge-base between '$HEAD_REF' and '$MAIN_REF' (unrelated histories, or a truncated fetch)." >&2
  echo "hook-staleness: this is NOT a pass; the check did not run." >&2
  exit 2
fi

# Tree hash of the hook directory at a ref; empty string if the dir is absent
# there (a branch predating the hooks entirely — still a real comparison).
tree_at() { git rev-parse "$1:$HOOK_DIR" 2>/dev/null || printf ''; }
H_HEAD=$(tree_at "$HEAD_REF"); H_BASE=$(tree_at "$BASE"); H_MAIN=$(tree_at "$MAIN_REF")

if [[ "$H_HEAD" != "$H_BASE" ]]; then
  echo "hook-staleness: OK — this branch modifies $HOOK_DIR itself, so it owns its copy (not stale by definition)."
  exit 0
fi
if [[ "$H_MAIN" == "$H_BASE" ]]; then
  echo "hook-staleness: OK — $HOOK_DIR is unchanged on '$MAIN_REF' since this branch's base."
  exit 0
fi

# STALE. Name the commits the branch is missing — a guard that will not say what
# it graded cannot be told apart from one that did not run.
echo "hook-staleness: STALE — '$MAIN_REF' has changed $HOOK_DIR since this branch's base, and this branch has not picked it up." >&2
echo >&2
echo "  Hooks run from YOUR working tree (core.hooksPath=$HOOK_DIR), so the guards added by these commits" >&2
echo "  DID NOT RUN on your pushes, silently — an absent hook does not fail, it just does not execute:" >&2
echo >&2
git log --oneline "$BASE..$MAIN_REF" -- "$HOOK_DIR" 2>/dev/null | sed 's/^/    /' >&2
echo >&2
echo "  Fix: rebase onto '$MAIN_REF'. The CI-side twins remain the net for anything already pushed." >&2
exit 1
