#!/usr/bin/env bash
# lint-changelog-fragments.sh — grade a PR's changelog.d/ fragments AT PR TIME
# (DIVE-4177).
#
# THE DEFECT THIS CLOSES. The fold (scripts/fold-changelog-fragments.sh) requires a
# fragment's first non-blank line to be a `## Unreleased` heading. Anything else is
# SKIPPED — printed on stderr, inside a cut, where nobody reads it — and the entry
# silently never reaches the release notes. Measured on v0.29.0 (3bf6519e): 11
# fragments folded, six skipped, and the published notes listed two entries and NO
# feature for a cut correctly derived MINOR from three `feat` commits. v0.30.0
# repeated it: the very commit that forced the minor was absent from its own notes.
# The LEVEL rule (DIVE-4086) was right both times; the NOTES lied.
#
# Same argument DIVE-4086 made for the commit subject, applied to the entry: the cut
# is the first place a malformed fragment is noticed, and by then it is public. So the
# contract moves to the door. A fragment nobody can MERGE malformed is a fragment the
# fold cannot skip.
#
# TWO RULES, and the second is why a well-formed fragment is not enough:
#   1. every changelog.d/*.md this PR adds or edits must start with `## Unreleased`;
#   2. a `feat`/`fix` PR must carry a fragment at all. v0.29.0's third feature
#      (DIVE-4144, #822) was not skipped — it wrote no fragment. Warn-only for
#      test|ci|chore|docs|refactor|perf: those are the changes a reader of the
#      release page is not looking for.
#
# ONE EXEMPTION TO RULE 2, and it is keyed on WHO opened the PR (DIVE-8034). A
# Dependabot security PR is titled `fix(deps): …` (.github/dependabot.yml, DIVE-7973)
# so release-cut accepts its subject, and Dependabot can never add a fragment. Without
# this, every such PR was red on `title` by construction: 5dive#1622 (a high alert)
# sat red 3 h until a person retitled it. So a PR whose AUTHOR is Dependabot AND whose
# title is exactly `fix(deps): …` needs no fragment; release-notes.sh prints that
# commit's subject under Fixes instead, so the security fix still reaches the notes.
# The author comes from the PR event (`pull_request.user.login`), which the PR's
# opener cannot set, so a person's `fix(deps):` PR still has to carry a fragment.
#
# SCOPE IS THE PR'S OWN CHANGED FILES, deliberately, not the whole directory. main
# carries fragments that predate this lint; grading those here would red every
# unrelated PR with somebody else's defect. The whole-tree grade belongs at cut time,
# where the fold now REFUSES instead of skipping (exit 3) — that is the tripwire, and
# this is the gate that keeps it from firing.
#
# Usage: lint-changelog-fragments.sh --title=<pr title> [--changed-from=<file|->]
#                                    [--fragdir=<dir>] [--author=<pr author login>]
#        changed paths are read one per line from --changed-from (default stdin),
#        repo-relative, as `git diff --name-only` prints them.
#        Exit 0 clean, 1 on a lint error, 2 on a usage error.
set -uo pipefail

title=""
changed_from="-"
fragdir="changelog.d"
author=""
for arg in "$@"; do
  case "$arg" in
    --title=*)        title="${arg#--title=}" ;;
    --changed-from=*) changed_from="${arg#--changed-from=}" ;;
    --fragdir=*)      fragdir="${arg#--fragdir=}" ;;
    --author=*)       author="${arg#--author=}" ;;
    *) echo "lint-changelog-fragments: unknown argument '${arg}'" >&2; exit 2 ;;
  esac
done

if [[ "$changed_from" == "-" ]]; then
  mapfile -t changed
else
  [[ -f "$changed_from" ]] || { echo "lint-changelog-fragments: no such file: ${changed_from}" >&2; exit 2; }
  mapfile -t changed < "$changed_from"
fi

errors=0
frag_count=0

# THE ACCEPTED HEADING, kept byte-identical to the condition in
# fold-changelog-fragments.sh. tests/changelog_fragment_lint_unit.sh asserts the two
# patterns are the same string in both files: a lint that admits what the fold skips
# is the defect wearing a green check.
readonly FRAGMENT_HEADING_RE='^##[[:space:]]+Unreleased([[:space:]]|$)'

for path in "${changed[@]}"; do
  [[ -n "$path" ]] || continue
  [[ "$path" == "${fragdir}/"*.md ]] || continue
  base="${path##*/}"
  # The fold excludes README.md from the fragment glob; so must this, or the
  # directory's own docs file is a permanent red.
  shopt -s nocasematch
  if [[ "$base" == "readme.md" ]]; then shopt -u nocasematch; continue; fi
  shopt -u nocasematch
  # Deleted in this PR — nothing to grade, and a deletion is how a fragment gets
  # withdrawn.
  [[ -f "$path" ]] || continue
  frag_count=$((frag_count + 1))
  first_content_line="$(grep -m1 -v '^[[:space:]]*$' "$path" || true)"
  if [[ ! "$first_content_line" =~ $FRAGMENT_HEADING_RE ]]; then
    {
      echo "::error file=${path}::${path} would be SKIPPED by the release fold and its entry would never reach the release notes (DIVE-4177)."
      echo "::error file=${path}::  got:  ${first_content_line}"
      echo "::error file=${path}::  want: the first non-blank line must be \`## Unreleased — <type>(<scope>): <headline> (<ident>)\`"
      echo "::error file=${path}::  e.g.  ## Unreleased — feat(release): the release level is derived from the cut (DIVE-4086)"
      echo "::error file=${path}::A bare \`## Unreleased\` is accepted too; keep the prose below the heading."
    } >&2
    errors=$((errors + 1))
  fi
done

# Rule 2 needs the change's TYPE, and the type comes from the same subject the cut
# reads. No type at all is pr-title-lint's error, not this one — reporting it twice
# teaches nobody anything the first line did not already say.
prtype=""
if [[ "$title" =~ ^([a-z]+)(\([^\)]*\))?!?:\  ]]; then
  prtype="${BASH_REMATCH[1]}"
fi

# DIVE-8034: the Dependabot exemption (header). Both halves must hold: the login is
# GitHub's own for the app (`dependabot[bot]` on the event, `app/dependabot` as gh
# prints it), and the title is the exact prefix dependabot.yml gives it — no `!`, no
# other scope, no other type.
dependabot_fix=0
if [[ "$author" == "dependabot[bot]" || "$author" == "app/dependabot" ]] \
   && [[ "$title" =~ ^fix\(deps\):\  ]]; then
  dependabot_fix=1
fi

if [[ "$frag_count" -eq 0 && "$dependabot_fix" -eq 1 ]]; then
  echo "::notice::Dependabot 'fix(deps)' PR — no changelog.d/ fragment needed; the release notes list this commit's subject under Fixes (DIVE-8034)." >&2
elif [[ "$frag_count" -eq 0 ]]; then
  case "$prtype" in
    feat|fix)
      {
        echo "::error::a '${prtype}' PR must add a changelog.d/ fragment — this is a change a release-notes reader is looking for, and without a fragment the cut has nothing to print for it (DIVE-4177)."
        echo "::error::  fix: add ${fragdir}/<ident>.md whose first line is \`## Unreleased — ${prtype}(<scope>): <headline> (<ident>)\`"
        echo "::error::  the filename is your ticket ident, so two PRs never touch the same file (DIVE-2582)."
      } >&2
      errors=$((errors + 1))
      ;;
    "")
      : ;;
    *)
      echo "::warning::no changelog.d/ fragment in this '${prtype}' PR — fine for a ${prtype}, but add one if a box operator would want to read about this (DIVE-4177)." >&2
      ;;
  esac
fi

if [[ "$errors" -gt 0 ]]; then
  exit 1
fi
printf 'ok — %d changelog.d fragment(s) graded, 0 error(s)\n' "$frag_count"
