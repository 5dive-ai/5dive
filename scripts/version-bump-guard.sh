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
_sha256file() { git show "$1:5dive.sha256" 2>/dev/null; }

new_ver="$(_ver "$NEW")"
new_bundle_ver="$(_bundle_ver "$NEW")"
base_ver="$(_ver "$BASE" 2>/dev/null || true)"
new_sha="$(_sha256file "$NEW")"
base_sha="$(_sha256file "$BASE" 2>/dev/null || true)"

fail=0

if [[ -n "$new_ver" && -n "$new_bundle_ver" && "$new_ver" != "$new_bundle_ver" ]]; then
  echo "version-bump-guard: BLOCKED — src/header.sh declares FIVE_VERSION=$new_ver but the committed 5dive bundle embeds $new_bundle_ver." >&2
  echo "  Run ./build.sh and commit the rebuilt bundle." >&2
  fail=1
fi

if [[ -n "$base_sha" && -n "$new_sha" && "$base_sha" != "$new_sha" \
      && -n "$base_ver" && "$new_ver" == "$base_ver" ]]; then
  echo "version-bump-guard: BLOCKED — the 5dive bundle changed (new 5dive.sha256) but FIVE_VERSION is still $new_ver, same as $BASE." >&2
  echo "  Two different bundles would claim the same release version. Bump FIVE_VERSION in src/header.sh, rebuild, and recommit." >&2
  echo "  Emergency override (discouraged; CI version-uniqueness check is the net): git push --no-verify" >&2
  fail=1
fi

exit $fail
