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
# DIVE-2071: every assertion below is behind `[[ -z "$ver" ]] && continue` /
# `[[ -z "$sha" ]] && continue` — "if present then check", which is silently
# vacuous the moment the `FIVE_VERSION=` anchor drifts (a rename, a src/
# reorg). Measured to pass the real DIVE-2065 incident clean under a
# perturbed anchor. So extraction at the tip (NEW) is asserted first and
# unconditionally, distinct from the per-commit skip-on-empty in the sweep
# below (which is deliberately tolerant of *historical* commits that never
# had these files, per this script's own scoping note above).
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

new_tip_ver="$(_ver "$NEW")"
new_tip_sha="$(_sha256file "$NEW")"
if [[ -z "$new_tip_ver" ]]; then
  echo "version-uniqueness: BLOCKED — could not extract FIVE_VERSION from src/header.sh at $NEW (missing file, or the 'readonly FIVE_VERSION=' anchor no longer matches). Extraction failure is not the same as a clean scan." >&2
  fail=1
fi
if [[ -z "$new_tip_sha" ]]; then
  echo "version-uniqueness: BLOCKED — could not read 5dive.sha256 at $NEW (missing or empty)." >&2
  fail=1
fi

declare -A base_shas    # version -> newline-joined set of 5dive.sha256 contents seen
declare -A first_owner  # version -> "source|commit" of the first commit recorded for it

_seen() {  # _seen "$version" "$sha" -> 0 if already recorded
  case $'\n'"${base_shas[$1]:-}"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}
_record() {  # _record "$version" "$sha" "$source" "$commit"
  base_shas[$1]="${base_shas[$1]:-}"$'\n'"$2"
  [[ -n "${first_owner[$1]:-}" ]] || first_owner[$1]="$3|$4"
}

# Phase 1: everything already accepted on BASE — build the lookup, report nothing.
while read -r commit; do
  [[ -z "$commit" ]] && continue
  ver="$(_ver "$commit")"; [[ -z "$ver" ]] && continue
  sha="$(_sha256file "$commit")"; [[ -z "$sha" ]] && continue
  _seen "$ver" "$sha" || _record "$ver" "$sha" base "$commit"
done < <(git log --format=%H "$BASE" -- src/header.sh 5dive.sha256 2>/dev/null)

# Phase 2: only the commits this range is introducing.
while read -r commit; do
  [[ -z "$commit" ]] && continue
  ver="$(_ver "$commit")"; [[ -z "$ver" ]] && continue
  sha="$(_sha256file "$commit")"; [[ -z "$sha" ]] && continue
  if [[ -n "${base_shas[$ver]:-}" ]] && ! _seen "$ver" "$sha"; then
    prior="${first_owner[$ver]}"
    prior_source="${prior%%|*}"
    prior_commit="${prior#*|}"
    if [[ "$prior_source" == base ]]; then
      where="already used on $BASE (commit $prior_commit) with a DIFFERENT bundle"
    else
      where="already used earlier in this range by $prior_commit (before $BASE..$NEW reaches $commit) with a DIFFERENT bundle"
    fi
    echo "version-uniqueness: $commit claims FIVE_VERSION $ver, $where." >&2
    echo "  $commit: 5dive.sha256=$sha" >&2
    fail=1
  fi
  _seen "$ver" "$sha" || _record "$ver" "$sha" range "$commit"
done < <(git log --format=%H --reverse "$BASE..$NEW" -- src/header.sh 5dive.sha256 2>/dev/null)

exit $fail
