#!/usr/bin/env bash
# Fail if a commit newly reachable from <new-ref> (but not from <base-ref>)
# claims a FIVE_VERSION that already appears in <base-ref>'s history under a
# DIFFERENT 5dive.sha256 content (DIVE-2065).
#
# Deliberately scoped to the NEW commits in <base-ref>..<new-ref>, not a
# full-history sweep. Measured against this repo's real history: it already
# contains many legitimate same-version/different-bundle pairs from ordinary
# commits landing between explicit version bumps (CONTRIBUTING.md:
# "FIVE_VERSION is bumped at release time, not per-merge") — e.g. 00d60e6
# rebuilt the bundle without touching src/header.sh at all, so it correctly
# shares 0.10.6's version with a different bundle than 1aef602 underneath it.
# A full-history version of this check would start permanently red and teach
# everyone to ignore it. Scoping to "does THIS range introduce a collision
# against what's already on <base-ref>" is the version that stays actionable
# — it is the CI-side twin of scripts/version-bump-guard.sh's push-time check,
# run against a wider range so it also catches a TOCTOU race between two
# pushes that each looked clear against a now-stale base.
#
# Usage: version-uniqueness-scan.sh <new-ref> [<base-ref>=origin/main]
# Exit 0 = no new collision. Exit 1 = collision, detail on stderr.
set -uo pipefail

NEW="${1:?usage: version-uniqueness-scan.sh <new-ref> [<base-ref>]}"
BASE="${2:-origin/main}"

_ver() {
  git show "$1:src/header.sh" 2>/dev/null \
    | grep -m1 '^readonly FIVE_VERSION=' \
    | sed -E 's/.*"([^"]+)".*/\1/'
}
_sha256file() { git show "$1:5dive.sha256" 2>/dev/null; }

fail=0
declare -A base_shas   # version -> newline-joined set of 5dive.sha256 contents seen

_seen() {  # _seen "$version" "$sha" -> 0 if already recorded
  case $'\n'"${base_shas[$1]:-}"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}
_record() { base_shas[$1]="${base_shas[$1]:-}"$'\n'"$2"; }

# Phase 1: everything already accepted on BASE — build the lookup, report nothing.
while read -r commit; do
  [[ -z "$commit" ]] && continue
  ver="$(_ver "$commit")"; [[ -z "$ver" ]] && continue
  sha="$(_sha256file "$commit")"; [[ -z "$sha" ]] && continue
  _seen "$ver" "$sha" || _record "$ver" "$sha"
done < <(git log --format=%H "$BASE" -- src/header.sh 5dive.sha256 2>/dev/null)

# Phase 2: only the commits this range is introducing.
while read -r commit; do
  [[ -z "$commit" ]] && continue
  ver="$(_ver "$commit")"; [[ -z "$ver" ]] && continue
  sha="$(_sha256file "$commit")"; [[ -z "$sha" ]] && continue
  if [[ -n "${base_shas[$ver]:-}" ]] && ! _seen "$ver" "$sha"; then
    echo "version-uniqueness: $commit claims FIVE_VERSION $ver, already used on $BASE with a DIFFERENT bundle." >&2
    echo "  $commit: 5dive.sha256=$sha" >&2
    fail=1
  fi
  _seen "$ver" "$sha" || _record "$ver" "$sha"
done < <(git log --format=%H --reverse "$BASE..$NEW" -- src/header.sh 5dive.sha256 2>/dev/null)

exit $fail
