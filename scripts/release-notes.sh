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

# _rn_group — turn the CHANGELOG's per-entry H2 sections into ONE grouped list.
#
# WHY (lodar, 2026-08-09, on the v0.19.9 page): "lets not wrap each release notes
# on h2 tag (##) because it looks ugly and messy ... 20 h2 tags are so messy ...
# we can group by feat and fix and other groups". A cut carries ~37 entries, so
# the old one-H2-per-entry rendering was 37 top-level headings stacked with no
# structure. Grouped bullets is the same information in three sections.
#
# AND IT FIXES A SILENT MISS. The previous version matched ONLY `## Unreleased`.
# By the time release-notes runs, `stamp-changelog.sh` has already rewritten those
# headings to `## v0.19.9 — ...`, so the substitution matched nothing and every
# heading reached the release page verbatim, still at H2. That is exactly what
# shipped on v0.19.9. The heading token is therefore matched as
# Unreleased-OR-a-version, not as the one literal.
#
# CONTENT IS NEVER DROPPED, which is the constraint that shapes the output. Most
# ranges add heading lines only (v0.19.8..v0.19.9: 37 added lines, 37 of them
# headings), but not all — v0.19.6..v0.19.7 added 384 lines against 37 headings,
# i.e. the full prose bodies. Rendering everything as a bullet would have thrown
# 347 lines of written-on-purpose prose away. So: an entry with no prose under it
# becomes a bullet, an entry WITH prose keeps a heading (demoted to H4, inside its
# group) and its prose follows. A pure-headline cut renders as pure bullets.
_rn_group() {
  # Stage 1 (sed): recognise the section heading and reduce it to a marker plus
  # the subject. Kept in sed because the em/en-dash bracket is a multibyte match
  # and this is the expression that has always handled it; awk then sees ASCII.
  sed -E 's/^## +(Unreleased|v?[0-9][^ ]*) +[-—–]+ +(.*)$/@@ENTRY@@\2/; s/^## +Unreleased *$/@@ENTRY@@Changes/' \
  | awk '
    BEGIN { n = 0; pre = "" }
    /^@@ENTRY@@/ { n++; subj[n] = substr($0, 10); body[n] = ""; next }
    { if (n == 0) pre = pre $0 "\n"; else body[n] = body[n] $0 "\n" }
    END {
      if (pre ~ /[^ \t\n]/) printf "%s\n", pre
      title["feat"] = "Features"; title["fix"] = "Fixes"; title["other"] = "Other"
      order = "feat fix other"; ng = split(order, G, " ")
      for (i = 1; i <= n; i++) {
        if (subj[i] ~ /^feat(\(|:)/)     cls[i] = "feat"
        else if (subj[i] ~ /^fix(\(|:)/) cls[i] = "fix"
        else                             cls[i] = "other"
      }
      for (g = 1; g <= ng; g++) {
        k = G[g]; any = 0
        for (i = 1; i <= n; i++) if (cls[i] == k) any = 1
        if (!any) continue
        printf "### %s\n\n", title[k]
        for (i = 1; i <= n; i++) {
          if (cls[i] != k) continue
          if (body[i] ~ /[^ \t\n]/) printf "\n#### %s\n\n%s", subj[i], body[i]
          else                      printf "- %s\n", subj[i]
        }
        printf "\n"
      }
    }
  '
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

added=$(_rn_changelog_added | _rn_group)
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
