#!/usr/bin/env bash
# Push-time check on src/header.sh's FIVE_VERSION anchor (DIVE-2065, DIVE-2071,
# DIVE-2585). Originally this file carried the version-COLLISION assertions from
# the DIVE-2065 incident: c97a4f9 bumped to 0.16.3 and rebuilt the bundle; a
# follow-up (2472df2) rebuilt the bundle again but its own version-bump step
# failed silently, so it reused 0.16.3 with different content. Both landed on
# main: two DIFFERENT bundles claiming one version. Those assertions are now
# retired; what is left is the ONE thing still reachable.
#
# ONE assertion, checked unconditionally:
#
#   EXTRACTION SUCCEEDS AT NEW. src/header.sh at NEW must exist and must carry a
#   readable `readonly FIVE_VERSION="..."` line. DIVE-2071: every content
#   assertion this file ever had sat behind `-n "$new_ver"`, so an unreadable
#   anchor (missing file, a rename, a src/ reorg) silently skipped ALL of them
#   and the script exited 0 — "clear to push" — measured to pass the exact
#   DIVE-2065 incident clean when the anchor was perturbed. Extraction failure
#   is therefore its own loud block, and it is now the only one.
#
# WHY THE COLLISION ASSERTION IS RETIRED (DIVE-2585), not relaxed. It read: if
# src/ or build.sh moved between BASE and NEW, FIVE_VERSION must have moved too.
# That predicate was written for a world where main carried a real release
# version. DIVE-2247 moved version assignment to TAG time: main's header carries
# the `0.0.0-dev` SENTINEL permanently, release-cut.yml writes the real number
# into a DETACHED release tree and pushes only refs/tags/*, never refs/heads/main.
# So on main FIVE_VERSION is 0.0.0-dev at every commit, the assertion's second
# half is true by construction, and the whole check reduced to "did src/ move" —
# i.e. it BLOCKED every source-changing push to main, which is all of them.
# Measured on already-landed main commits (785e391 vs its parent): rc=1.
#
# Two further reasons it had to go rather than be exempted:
#   - Its remedy string ("Bump FIVE_VERSION in src/header.sh") instructed the
#     reader to do exactly what the tag-time model forbids. A builder following
#     the printed advice would put a real version on main and break the
#     derivation release-cut.yml runs off .release-floor + the incumbent tag.
#   - Its override string cited "CI version-uniqueness" as the net. That job was
#     deleted by DIVE-2247; bundle-drift.yml carries its headstone. A guard that
#     names a net which does not exist is worse than one that names none.
#
# WHERE THE PROPERTY LIVES NOW. Two places, both reachable:
#   - The collision itself moved to the PUBLISH act: release-cut.yml refuses to
#     cut a derived tag that already exists, and refuses to re-point a published
#     one (DIVE-2118). That is the same invariant asserted where the artifact is
#     actually produced — the DIVE-2185 rule (do not keep a guard whose failure
#     mode is unreachable) applied one layer up.
#   - "main carries the sentinel, nothing assigns a version to main" is asserted
#     by tests/release_cut_bundle_unit.sh, a core-tier harness that runs on every
#     pull request. It is NOT re-asserted here, deliberately: duplicating a
#     per-PR grader at push time buys nothing and gives the next reader two
#     places to keep in sync.
#
# BASE is still accepted so the pre-push hook's call signature does not change,
# but nothing reads it any more — the surviving assertion is about NEW alone.
#
# Usage: version-bump-guard.sh <new-rev> [<base-rev>=origin/main]
# Exit 0 = clear to push. Exit 1 = blocked, reason on stderr.
set -uo pipefail

NEW="${1:?usage: version-bump-guard.sh <new-rev> [<base-rev>]}"
BASE="${2:-origin/main}"  # accepted for call-signature stability; not read (DIVE-2585)

_ver() {
  git show "$1:src/header.sh" 2>/dev/null \
    | grep -m1 '^readonly FIVE_VERSION=' \
    | sed -E 's/.*"([^"]+)".*/\1/'
}

new_ver="$(_ver "$NEW")"

fail=0

if [[ -z "$new_ver" ]]; then
  echo "version-bump-guard: BLOCKED — could not extract FIVE_VERSION from src/header.sh at $NEW (missing file, or the 'readonly FIVE_VERSION=' anchor no longer matches). Extraction failure is not the same as a clean read — investigate before overriding." >&2
  echo "  Fix the anchor. Do NOT assign a version by hand: main carries the 0.0.0-dev sentinel and the real number is written at tag time (DIVE-2247)." >&2
  echo "  Net if you override: release-cut.yml refuses to cut when it cannot write FIVE_VERSION into src/header.sh, rather than publishing the sentinel." >&2
  fail=1
fi

exit $fail
