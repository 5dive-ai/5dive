#!/usr/bin/env bash
# Refuse a push to main whose bundle content changed but FIVE_VERSION did not
# (DIVE-2065). Measured incident: c97a4f9 bumped to 0.16.3 and rebuilt the
# bundle; a follow-up commit (2472df2) also rebuilt the bundle (cmd_task.sh
# changed, so 5dive.sha256 changed) but its own version-bump step failed
# silently, so it still declared FIVE_VERSION=0.16.3. Both landed on main:
# two DIFFERENT bundles claiming one version, with nothing to tell them apart
# (fixed after the fact as 0.16.4, see CHANGELOG). The shared-checkout
# updater keys entirely off FIVE_VERSION, so a collision here is a silent
# coin-flip over which bundle a given box ends up running.
#
# Two independent assertions, both required to pass:
#
#   1. VERSION MOVED WITH THE BUNDLE. If the bundle (5dive.sha256) at NEW
#      differs from BASE, FIVE_VERSION must also differ from BASE. This is
#      the DIVE-2065 incident itself: a bundle rebuild landing under a
#      version that was already claimed by different bundle content.
#
#   2. BUNDLE MATCHES HEADER. The FIVE_VERSION embedded in the committed
#      `5dive` bundle at NEW must equal src/header.sh's FIVE_VERSION at NEW.
#      Catches a version bump that was never rebuilt into the bundle (the
#      other release-step failure named in DIVE-2065's ask).
#
# Deliberately does NOT require every push to main to bump the version —
# only pushes that changed the bundle. A push that touches no source (e.g.
# workflow/doc-only) leaves 5dive.sha256 unchanged and is exempt from #1.
#
# DIVE-2071: assertions 1 and 2 above are both behind `-n "$new_ver"` /
# `-n "$new_bundle_ver"` / `-n "$new_sha"` guards, so if extraction of any of
# them from NEW fails (missing file, or the `FIVE_VERSION=` anchor drifted —
# a rename, a src/ reorg), every assertion above is silently skipped and this
# script exits 0: clear to push. That is "if present then check", which
# succeeds at nothing the moment the anchor moves — measured to pass the
# exact DIVE-2065 incident clean when the anchor is perturbed. Extraction
# failure at NEW is therefore checked FIRST and unconditionally, as its own
# loud block, distinct from the two content assertions.
#
# Usage: version-bump-guard.sh <new-rev> [<base-rev>=origin/main]
# Exit 0 = clear to push. Exit 1 = blocked, reason on stderr.
set -uo pipefail

NEW="${1:?usage: version-bump-guard.sh <new-rev> [<base-rev>]}"
BASE="${2:-origin/main}"

_ver() {
  git show "$1:src/header.sh" 2>/dev/null \
    | grep -m1 '^readonly FIVE_VERSION=' \
    | sed -E 's/.*"([^"]+)".*/\1/'
}
_bundle_ver() {
  git show "$1:5dive" 2>/dev/null \
    | grep -m1 '^readonly FIVE_VERSION=' \
    | sed -E 's/.*"([^"]+)".*/\1/'
}
# DIVE-2091: the bundle is generated at TAG time and is no longer committed, so
# 5dive.sha256 cannot be read from a commit any more. It was only ever a PROXY
# for "did the source change" — this file's own header says a workflow/doc-only
# push "leaves 5dive.sha256 unchanged and is exempt". Ask the real question
# directly instead: did anything build.sh consumes change between BASE and NEW.
# Same exemption, no generated artifact required.
_src_changed() { # BASE NEW -> 0 if src/ or build.sh differ
  ! git diff --quiet "$1" "$2" -- src build.sh 2>/dev/null
}

new_ver="$(_ver "$NEW")"
base_ver="$(_ver "$BASE" 2>/dev/null || true)"
src_moved=0; _src_changed "$BASE" "$NEW" && src_moved=1

fail=0

# Extraction failure at NEW != clean. Checked first, unconditionally, with a
# message distinct from the content-mismatch assertions below — an anchor
# that can't be found is a different failure than an anchor that disagrees,
# and folding them into one message would bury the drift signal.
if [[ -z "$new_ver" ]]; then
  echo "version-bump-guard: BLOCKED — could not extract FIVE_VERSION from src/header.sh at $NEW (missing file, or the 'readonly FIVE_VERSION=' anchor no longer matches). Extraction failure is not the same as a clean bundle — investigate before overriding." >&2
  fail=1
fi
# DIVE-2091: the "bundle embeds the header's version" assertion is GONE, not
# relaxed — it is structurally impossible to violate now. There is no committed
# bundle to disagree with src/header.sh, and the bundle that ships is built at
# tag time FROM that header. release-cut.yml asserts v${FIVE_VERSION} == the tag
# being cut and refuses otherwise, which is the same property enforced where the
# artifact is actually produced. Dropping it here rather than leaving a check
# that can no longer fail (see bundle-drift's old `git diff --exit-code 5dive`).

if [[ "$src_moved" == "1" && -n "$base_ver" && "$new_ver" == "$base_ver" ]]; then
  echo "version-bump-guard: BLOCKED — src/ (or build.sh) changed but FIVE_VERSION is still $new_ver, same as $BASE." >&2
  echo "  Two different bundles would claim the same release version. Bump FIVE_VERSION in src/header.sh." >&2
  echo "  Emergency override (discouraged; CI version-uniqueness check is the net): git push --no-verify" >&2
  fail=1
fi

exit $fail
