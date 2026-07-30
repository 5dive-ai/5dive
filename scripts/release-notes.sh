#!/usr/bin/env bash
# release-notes.sh — derive a release body for the version being cut (DIVE-2452).
#
# WHY THIS EXISTS. `release-cut.yml` published `gh release create --notes "${note}"`
# where `note` is the CUT REASON ("nightly auto-cut: main changed and CI is green").
# So v0.17.0/0.17.1/0.17.9 all shipped a body describing HOW they were cut and never
# WHAT shipped — 256 characters covering 76 commits, found by lodar on the public
# release page.
#
# WHY THE SOURCE IS THE GIT RANGE AND NOT THE HEADING TEXT. The obvious
# implementation is "collect the sections headed `## Unreleased`". It is wrong here,
# and quietly: nothing ever stamps CHANGELOG.md on main — DIVE-2247 removed this
# workflow's ability to write to main at all (a `github.token` push to a protected
# branch is rejected, and the fix was to stop needing the push). So on main EVERY
# section is headed `## Unreleased`, for every version ever released, and a
# heading-based reader would put the entire file in every release body.
#
# The boundary that is actually true is the RANGE: what did CHANGELOG.md gain
# between the commit the incumbent tag was cut from and the commit being cut now.
# That needs no state, no stamping, and cannot drift.
#
# ORDER OF PREFERENCE, and the last arm is the point:
#   1. CHANGELOG.md's added lines over the range — prose someone wrote on purpose.
#   2. the commit subjects over the range, grouped by conventional-commit type —
#      always available, never as good.
#   3. NOTHING -> exit 1. A release whose body cannot be derived is a release
#      nobody can read; refusing is louder than publishing the cut reason again.
#
# Lives in scripts/ rather than inline in the workflow for the reason the workflow
# itself states about `grade-release-commit.sh`: a workflow body cannot be
# unit-tested and `.github/workflows/` needs a credential most agents do not hold,
# so the logic sits where it can be graded and repaired on the normal rail
# (tests/release_notes_unit.sh).
#
# Usage: release-notes.sh <from-ref|""> <to-ref> <version> [changelog-path]
#        prints the release body on stdout; exit 1 if nothing could be derived.
set -uo pipefail

from="${1-}"
to="${2-}"
version="${3-}"
changelog="${4:-CHANGELOG.md}"

if [[ -z "$to" || -z "$version" ]]; then
  echo "usage: release-notes.sh <from-ref|\"\"> <to-ref> <version> [changelog-path]" >&2
  exit 2
fi

# _rn_changelog_added — the lines CHANGELOG.md GAINED over the range, with the diff
# markers stripped. `git diff` is asked for the one path, so a rename or an
# unrelated file cannot contribute. Deletions are ignored on purpose: a release
# body describes what arrived, not what someone tidied away.
_rn_changelog_added() {
  [[ -n "$from" ]] || return 0
  git diff "${from}..${to}" -- "$changelog" 2>/dev/null \
    | sed -n 's/^+\([^+].*\)$/\1/p; s/^+$//p'
}

# _rn_retitle — a CHANGELOG section heading is `## Unreleased — feat(x): thing`.
# In a release body the "Unreleased" half is noise (and actively misleading on a
# page titled with the version), so the heading is demoted to `### feat(x): thing`.
# Any other heading level is left exactly as written.
_rn_retitle() {
  sed -E 's/^## +Unreleased +[-—–]+ +(.*)$/### \1/; s/^## +Unreleased *$/### Changes/'
}

# _rn_commit_summary — the fallback. Conventional-commit types are grouped so the
# list is skimmable; anything unrecognised lands under Other rather than being
# dropped, because a silently shortened list is the failure this file exists for.
_rn_commit_summary() {
  local range="$to"
  [[ -n "$from" ]] && range="${from}..${to}"
  local subjects
  subjects=$(git log --no-merges --format='%s' "$range" 2>/dev/null) || return 0
  [[ -n "$subjects" ]] || return 0

  local feats fixes others
  feats=$(printf '%s\n'  "$subjects" | grep -E '^feat(\(|:)' || true)
  fixes=$(printf '%s\n'  "$subjects" | grep -E '^fix(\(|:)'  || true)
  others=$(printf '%s\n' "$subjects" | grep -vE '^(feat|fix)(\(|:)' || true)

  if [[ -n "$feats" ]]; then
    printf '### Features\n\n'
    printf '%s\n' "$feats" | sed 's/^/- /'
    printf '\n'
  fi
  if [[ -n "$fixes" ]]; then
    printf '### Fixes\n\n'
    printf '%s\n' "$fixes" | sed 's/^/- /'
    printf '\n'
  fi
  if [[ -n "$others" ]]; then
    printf '### Other\n\n'
    printf '%s\n' "$others" | sed 's/^/- /'
    printf '\n'
  fi
}

body=""
source_label=""

added=$(_rn_changelog_added | _rn_retitle)
# "Has content" means a non-blank line exists — a range that only added blank lines
# or a heading-less fragment is not notes, and treating it as notes would publish an
# empty body while reporting success.
if printf '%s\n' "$added" | grep -q '[^[:space:]]'; then
  body="$added"
  source_label="CHANGELOG.md over ${from:-<root>}..${to}"
else
  body=$(_rn_commit_summary)
  if printf '%s\n' "$body" | grep -q '[^[:space:]]'; then
    source_label="commit subjects over ${from:-<root>}..${to} (CHANGELOG.md gained nothing in this range)"
  fi
fi

if ! printf '%s\n' "$body" | grep -q '[^[:space:]]'; then
  echo "::error::release notes for v${version} could not be derived — CHANGELOG.md gained nothing over ${from:-<root>}..${to} and the range has no commits. Refusing to publish a release whose body would describe only how it was cut (DIVE-2452)." >&2
  exit 1
fi

printf '%s\n' "$body"
printf '\n---\n\n'
printf '_Notes derived from %s._\n' "$source_label"
