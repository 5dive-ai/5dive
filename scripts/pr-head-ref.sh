#!/usr/bin/env bash
# pr-head-ref.sh — DIVE-4237. Make a pull request's HEAD COMMIT exist in the
# clone, from the ref GitHub does not recompute.
#
# THE DEFECT (measured 2026-09-10 on lodar/5dive-api#153, wiki:
# community/wiki/a-gate-that-dies-before-it-evaluates-reports-its-subjects-verdict.md):
#   `actions/checkout` gets a pull request's tree from `refs/pull/<n>/merge`.
#   That ref is NOT always there — GitHub rebuilds it whenever the base branch
#   moves, and a run started inside that window finds it missing. checkout does
#   not fail and does not warn: it falls back to fetching `+refs/heads/*` and
#   `+refs/tags/*` and checking out the BASE branch. Same head, same workflow,
#   59 minutes apart:
#     12:26Z  fetch … +3ab4d0a8:refs/remotes/pull/153/merge  -> merge ref
#     13:25Z  fetch … (heads and tags only)                  -> origin/main
#   The event payload still carries `pull_request.head.sha` in both runs. In the
#   second it names no object in the clone, so every `git diff BASE HEAD` in the
#   job dies with exit 128 BEFORE the assertion the job exists to make.
#
# WHY NOT THE FILES-API PORT (DIVE-4231, 5dive-api PR #154). That fix replaces
#   the changed-file LIST with `GET /pulls/<n>/files`, and it is the right fix
#   for a gate that only needs to know WHICH paths moved — which is what both
#   5dive-api gates needed. Measured on this repo's three exposed jobs, none of
#   them is that shape: install-guard renders the DIFF TEXT into the job summary,
#   pr-title-lint's fragment lint reads the BODY of each changelog.d/*.md the PR
#   touched (scripts/lint-changelog-fragments.sh opens the file), and pii-guard
#   scans COMMIT MESSAGES and ADDED LINES across the range
#   (scripts/pii-scan-range.sh). All three need the PR's content, so a file list
#   closes none of them. The dependency to remove here is on the RECOMPUTED ref,
#   not on the tree.
#
# WHAT THIS DOES. `refs/pull/<n>/head` is the pull request branch's own tip. It
#   is written when the author pushes and at no other time — GitHub never
#   recomputes it against the base branch, which is the entire property the
#   merge ref lacks. Fetching it makes `pull_request.head.sha` a real object, so
#   each job's existing `git` calls work unchanged on every run.
#
# FAIL DIRECTION, which is the load-bearing part. Every path that cannot
#   materialise the head EXITS NON-ZERO and says so in those words. A job that
#   cannot read the change must not report on the change — in EITHER direction.
#   install-guard's pre-DIVE-4237 body is why this is spelled out: it ran
#   without `errexit`, so a dead `git diff` left `$files` empty and the job took
#   its "the path filter and the diff disagree" branch and exited 0. The check
#   went GREEN and the root-path diff it exists to put in front of a human was
#   never rendered. A gate that dies before it evaluates reports its subject's
#   verdict; that one reported the subject's ACQUITTAL.
#
# Usage: pr-head-ref.sh --sha=<head sha> [--remote=origin] [--pr=<number>]
#   --sha   the head sha from the event payload. Required; it is what the job's
#           own git calls name, so it is what has to exist.
#   --pr    the pull request number. Optional: when given, the fetch is by
#           `refs/pull/<n>/head`, which reaches the commit even when it is on no
#           branch this clone knows and when the server refuses a bare-sha fetch.
# Exit: 0 the sha is a COMMIT in this clone (already, or after the fetch)
#       2 it is not, and could not be made one. NOT a verdict on the PR.
set -uo pipefail

sha=""; remote="origin"; pr=""
for arg in "$@"; do
  case "$arg" in
    --sha=*)    sha="${arg#--sha=}" ;;
    --remote=*) remote="${arg#--remote=}" ;;
    --pr=*)     pr="${arg#--pr=}" ;;
    *) echo "pr-head-ref: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

if [ -z "$sha" ]; then
  echo "pr-head-ref: --sha=<head sha> is required" >&2
  exit 2
fi

# `^{commit}` and not `cat-file -e`: the callers diff this sha, so an object
# that is not a commit is not a materialised head.
have() { git rev-parse -q --verify "${1}^{commit}" >/dev/null 2>&1; }

if have "$sha"; then
  echo "pr-head-ref: ${sha:0:12} is already a commit in this clone."
  exit 0
fi

echo "pr-head-ref: ${sha:0:12} is NOT a commit in this clone." >&2
echo "pr-head-ref: that is the merge-ref recompute window, not a fact about the PR —" >&2
echo "pr-head-ref: actions/checkout fell back to the base branch without saying so." >&2

if [ -n "$pr" ]; then
  echo "pr-head-ref: fetching refs/pull/${pr}/head, which GitHub does not recompute." >&2
  git fetch --no-tags "$remote" "+refs/pull/${pr}/head:refs/remotes/pull/${pr}/head" >&2 || true
fi
if ! have "$sha"; then
  echo "pr-head-ref: fetching the sha directly." >&2
  git fetch --no-tags "$remote" "$sha" >&2 || true
fi

if have "$sha"; then
  echo "pr-head-ref: ${sha:0:12} is now a commit in this clone."
  exit 0
fi

{
  echo "pr-head-ref: UNDETERMINED — could not make ${sha:0:12} a commit in this clone."
  echo "pr-head-ref: the caller must REFUSE, in both directions. Reporting green here"
  echo "pr-head-ref: would clear a change nobody read; reporting red would publish the"
  echo "pr-head-ref: runner's problem under the gate's name, against the pull request."
} >&2
exit 2
