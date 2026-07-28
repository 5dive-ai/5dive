# shellcheck shell=bash
# PIN THE BASELINE TO A COMMIT, AND MAKE FAILURE TO RESOLVE IT LOUD. (DIVE-2229.)
#
# THE DEFECT THIS CLOSES, both halves of it.
#
# 1. A BASELINE NAMED BY A BRANCH MOVES OUT FROM UNDER THE CLAIM.  An anchor
#    that reads its "before" from `origin/main` is correct exactly until the fix
#    merges -- then origin/main IS the post-fix tree and the anchor compares post
#    to post.  On a "did the fix change anything" assertion that goes RED on main
#    for a reason unrelated to the code under test (measured on
#    heartbeat_tier_guard_unmeasured_unit.sh after DIVE-2213: "3 -> 3
#    distinguishable decisions").  On a MUST-NOT-CHANGE assertion
#    (`X is byte-identical to origin/main`) it is worse: it goes VACUOUS-PASS and
#    never announces itself again.  The second is the dangerous one, because the
#    log still reads `ok`.
#
# 2. THE COMPARISON MAY NEVER RUN WHERE IT GATES.  `actions/checkout@v4` with no
#    `fetch-depth` is depth 1.  What that does to a branch-named baseline depends
#    on how the shallow tree was made, and BOTH outcomes are wrong:
#      - PR checkout (fetch of refs/pull/N/merge, no refs/remotes/origin/main):
#        the ref does not resolve, and a harness that treats that as `skip`
#        reports NOT-REACHED while a reader counts it as green.
#      - `git clone --depth=1 --branch main`: refs/remotes/origin/main EXISTS and
#        points at the same commit as HEAD, so `git show origin/main:<path>` hands
#        back the WORKING TREE'S OWN CONTENT.  Every byte-identical assertion
#        passes, having compared a file to itself.  No skip, no red, no signal.
#    So "does origin/main resolve?" is not even a reliable detector of the
#    problem -- it can resolve and still be meaningless.  Pin the commit.
#
# THE CONTRACT.  `pinned_blob <ref> <path> <outfile>` writes the blob at
# <ref>:<path> to <outfile> and returns 0, or returns non-zero having written
# nothing.  It never reports success against a tree it did not resolve, and it
# never silently substitutes HEAD.
#
# WHY IT FETCHES, AND WHY THE FETCH IS BOUNDED.  A shallow clone legitimately
# lacks the pinned commit, and refusing to try turns a solvable condition into a
# permanent skip -- which is the second half of the defect above.  So it asks the
# remote for exactly that one commit at depth 1 (GitHub serves reachable SHAs).
# It does NOT deepen the whole history: the cost of the fallback must not scale
# with the repo, or CI will be tempted to remove it again.
#
# WHY CALLERS MUST NOT `skip` ON FAILURE.  A skip count is NOT-REACHED, not
# green, and these are exactly the assertions nobody re-checks by hand.  Every
# caller in tests/ treats an unresolvable pin as a FAILURE and says so in the
# message.  The workflow guarantees it resolves (`fetch-depth: 0`); a developer
# box with a network can fetch it; a box with neither has not run the check and
# must not be told it passed.  tests/baseline_pin_unit.sh fences both halves.

# Resolve <ref> to a commit in THIS repository, fetching it once if absent.
# Prints nothing. Returns 0 if the commit is present afterwards.
pinned_commit_available() {
  local ref="$1"
  git rev-parse --verify -q "${ref}^{commit}" >/dev/null 2>&1 && return 0
  # Bounded, targeted: this one commit, depth 1, no history deepening.
  git fetch --depth=1 origin "$ref" >/dev/null 2>&1 || return 1
  git rev-parse --verify -q "${ref}^{commit}" >/dev/null 2>&1
}

# pinned_blob <ref> <path> <outfile>
# On success <outfile> holds <ref>:<path>. On failure <outfile> is not created
# and the return status is non-zero -- callers MUST red, not skip.
pinned_blob() {
  local ref="$1" path="$2" out="$3"
  pinned_commit_available "$ref" || return 1
  # A missing PATH at a resolvable REF is a different failure (the file moved),
  # and it must not be laundered into "baseline unavailable" either.
  git show "${ref}:${path}" > "${out}.part" 2>/dev/null || { rm -f "${out}.part"; return 1; }
  # An empty baseline blob compares equal to an empty extraction, which is the
  # vacuous-pass this file exists to prevent. Treat it as unresolved.
  [[ -s "${out}.part" ]] || { rm -f "${out}.part"; return 1; }
  mv "${out}.part" "$out"
}

# pinned_unavailable_msg <ref> -- the message every caller shares, so the reason
# a load-bearing arm did not run is stated the same way everywhere.
#
# RED AND DECLINED MUST STAY DISTINGUISHABLE TO A READER. Turning the old skip
# into a failure is right -- a skip reads as green in the tally -- but a failure
# that reads like an ordinary assertion sends the next person into src/ looking
# for a defect that is not there. The model in this corpus is
# org_write_authz_unit.sh, which says out loud that the SUITE cannot be exercised
# in this environment; the counter-examples are the harnesses that go red under
# root with ordinary assertion text and leave you unable to tell a broken product
# from a wrong environment. The person who hits this line is offline, in a hurry,
# and must be told in the first clause that the ENVIRONMENT is the cause.
pinned_unavailable_msg() {
  printf 'PRECONDITION NOT MET (environment, not a product defect): this box cannot see the pinned baseline commit %s. The tree is shallow and the single-commit fetch fallback did not reach a remote -- offline, or a CI checkout without fetch-depth:0. NOTHING IS WRONG WITH src/ ON THE STRENGTH OF THIS LINE; the comparison simply did not run, and it is reported red rather than skipped because a skip is counted as green by every reader of the tally. To exercise it: deepen the checkout (git fetch --depth=1 origin %s, or fetch-depth: 0 in the workflow) and re-run.' "$1" "$1"
}

# pinned_diff <ref> [<git-diff-args>...] -- a diff against a PINNED ref that
# refuses instead of returning empty when the ref is not there.
#
# WHY THIS EXISTS (olivia, DIVE-2229 review): her scope check ran
# `git diff --name-only origin/main...origin/<branch> | grep -vE <allowed>` and
# printed "none out of scope -- claim HOLDS". The branch had not been pushed, so
# the diff was EMPTY, and an empty diff satisfies an out-of-scope filter
# perfectly. A comparison against a ref that is not there announced SUCCESS
# rather than ABSENCE -- the same defect this file exists to close, one level up,
# and it fooled the verifier of the ticket about it. An empty result set is not
# evidence; it is the shape a missing input takes.
pinned_diff() {
  local ref="$1"; shift
  pinned_commit_available "$ref" || return 1
  git diff "$@" "$ref" 2>/dev/null || return 1
}
