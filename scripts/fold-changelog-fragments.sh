#!/usr/bin/env bash
# fold-changelog-fragments.sh — fold changelog.d/*.md fragments into CHANGELOG.md
# (DIVE-2582).
#
# THE PROBLEM. main's CHANGELOG.md format is a single prose `## Unreleased —
# <headline>` H2 inserted at the TOP of the file. Every PR that adds one inserts
# at the same offset, so every merge conflicts with every other open PR that also
# added one — measured five times in one session on 2026-08-03, on five unrelated
# branches. Verified empirically (not assumed): appending at the BOTTOM instead of
# the top does NOT avoid this — a pure git 3-way merge/rebase test with two
# branches each adding a distinct block at the same anchor (top OR bottom)
# conflicts either way, because both sides insert at the identical position
# relative to a shared, unmoved context. A `.gitattributes merge=union` driver
# does resolve it for a LOCAL git merge, but GitHub's PR merge (the actual thing
# that shows a PR as CONFLICTING and blocks CI here) is server-side and does not
# honor gitattributes merge drivers at all — confirmed against
# github.com/orgs/community/discussions/9288. So neither of the two "no new
# convention" options actually fixes the reported problem.
#
# THE FIX: give every entry its OWN FILE. Two PRs each adding a distinct
# `changelog.d/<ident>.md` never conflict — there is no shared line range to
# collide on, by construction, the same argument DIVE-2091 made for the bundle.
#
# PURELY ADDITIVE — this does not replace or require migrating the existing
# convention. An agent can keep editing CHANGELOG.md directly (today's habit,
# and still supported) or drop a fragment in changelog.d/ (new, zero-conflict
# path) — both land in the same place by release time. No open PR needs to
# change anything to keep working.
#
# WHERE THIS RUNS: same place and same rule as scripts/stamp-changelog.sh — the
# detached release commit only, never main (DIVE-2247: a github.token push to a
# protected branch is rejected, so nothing here needs to push one). Consequence,
# stated so it reads as accepted rather than missed: changelog.d/ fragments are
# consumed (deleted) in the release commit's tree, not on main, so main's
# changelog.d/ keeps whatever was there — exactly the same "Unreleased never
# clears on main" property CHANGELOG.md already has today (see stamp-changelog.sh's
# header). Not a new limitation; matched to the existing one on purpose.
#
# FRAGMENT FORMAT: a fragment's first non-blank line MUST be a
# `## Unreleased — <headline>` (or bare `## Unreleased`) heading — the exact text
# that would otherwise have been typed at the top of CHANGELOG.md, so authoring a
# fragment is not a new format to learn, only a new file to put it in.
#
# Usage: fold-changelog-fragments.sh [changelog-path] [fragments-dir]
#        folds newest-fragment-first (by filename, descending) to the TOP of
#        changelog-path, deletes the folded fragments, prints the number folded.
#        0 fragments is success (prints 0) — a cut with nothing pending is normal.
set -uo pipefail

changelog="${1:-CHANGELOG.md}"
fragdir="${2:-changelog.d}"

if [[ ! -f "$changelog" ]]; then
  echo "fold-changelog-fragments: ${changelog} does not exist" >&2
  exit 2
fi

if [[ ! -d "$fragdir" ]]; then
  echo 0
  exit 0
fi

# Newest-first by filename (ticket idents sort roughly chronologically), README
# and dotfiles excluded — this is a docs/convention file, not an entry.
mapfile -t frags < <(find "$fragdir" -maxdepth 1 -type f -name '*.md' ! -iname 'readme.md' -printf '%f\n' | sort -r)

if [[ ${#frags[@]} -eq 0 ]]; then
  echo 0
  exit 0
fi

folded=0
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for f in "${frags[@]}"; do
  path="${fragdir}/${f}"
  # First non-blank line must anchor a well-formed heading, same pattern
  # stamp-changelog.sh anchors on — a fragment that drifted from the format is
  # reported and skipped, never silently folded as prose.
  first_content_line="$(grep -m1 -v '^[[:space:]]*$' "$path" || true)"
  if [[ ! "$first_content_line" =~ ^##[[:space:]]+Unreleased([[:space:]]|$) ]]; then
    echo "fold-changelog-fragments: ${path} does not start with '## Unreleased' — skipping (not folded, not deleted)" >&2
    continue
  fi
  cat "$path" >> "$tmp"
  printf '\n' >> "$tmp"
  rm -f "$path"
  folded=$((folded + 1))
done

if [[ "$folded" -gt 0 ]]; then
  # Splice the folded block in right after the `# Changelog` title line (line 1)
  # so it lands exactly where a manual top-of-file edit would have gone.
  {
    head -n1 "$changelog"
    echo
    cat "$tmp"
    tail -n +2 "$changelog" | sed '/./,$!d'
  } > "${changelog}.new"
  mv "${changelog}.new" "$changelog"
fi

echo "$folded"
