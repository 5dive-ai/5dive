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
# WHY THAT NEEDED A SECOND HALF (DIVE-2702). A fragment surviving on main is
# harmless once; it is not harmless twice. The deletion lives only in the tag, so
# the NEXT cut sees the same fragment still sitting on main and folds it AGAIN,
# on top of whatever is new — v0.19.1's notes would repeat all of v0.19.0's,
# v0.19.2 both, and it COMPOUNDS. Measured 2026-08-04 straight after v0.19.0:
# `git ls-tree origin/main changelog.d/` still listed all 8 fragments while
# `git ls-tree v0.19.0 changelog.d/` listed 1. The cut is also a NIGHTLY AUTO-CUT
# (lodar 2026-07-27, cadence option A), so the degraded artifact is public before
# anyone chooses to look.
#
# THE FIX, and note which property it adds: IDEMPOTENCE, not a push to main. The
# fold skips a fragment that was ALREADY CONSUMED BY AN EARLIER CUT, and it reads
# that fact off history main can see — the previous release tag's PARENT is main's
# tip as of that cut, so a fragment present in that tree, byte-identical to the one
# here, was folded into that tag and has shipped. Everything else folds. This adds
# no credential, no second workflow, and no push to a protected branch (DIVE-2247
# removed that on purpose; restoring it via a post-tag PR was the rejected shape).
#
# Deliberately BYTE-IDENTICAL and not by ident: a fragment EDITED after its cut is
# new content and folds again, which is what a re-filed fragment needs.
#
# BASELINE: $FOLD_RELEASED_BASELINE, a git ref whose tree is main as of the last
# cut. release-cut.yml passes the sha from scripts/release-cut-baseline.sh, which
# holds the single copy of the rule. It used to pass "${incumbent}^" and DIVE-3170
# measured that wrong: a cut makes two commits, so the tag's first parent is the
# ASSIGN commit — a tree this very script has already emptied — and every fragment
# therefore looked unshipped and re-folded on every cut. SET-BUT-EMPTY means
# "no previous cut, fold everything" (the first cut ever). UNSET means auto-detect
# with the same filter+sort release-cut.yml and install.sh use. Unresolvable is
# NOT fatal — the cut must not die over a changelog — but it is reported, because
# folding everything is exactly the defect above and must never pass silently.
#
# FRAGMENT FORMAT: a fragment's first non-blank line MUST be a
# `## Unreleased — <headline>` (or bare `## Unreleased`) heading — the exact text
# that would otherwise have been typed at the top of CHANGELOG.md, so authoring a
# fragment is not a new format to learn, only a new file to put it in.
#
# AND A FRAGMENT THAT IS NOT IN THAT FORMAT ENDS THE CUT (DIVE-4177, exit 3). It used
# to be skipped with a line on stderr and the cut published anyway: v0.29.0's notes
# listed two entries and no feature for a release correctly derived MINOR from three
# `feat` commits, because six fragments were skipped that way. A dropped entry is not a
# degraded artifact, it is a wrong one, and the tag makes it permanent. The refusal
# cannot fire on a clean main — scripts/lint-changelog-fragments.sh grades the same
# heading at PR time, under the required `title` context.
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

# DIVE-2702: resolve the ALREADY-CONSUMED baseline (see the header). Three states,
# kept distinct on purpose — "nothing to skip against" and "I could not look" are
# not the same answer, and only one of them deserves a warning.
baseline="${FOLD_RELEASED_BASELINE-__auto__}"
baseline_explicit=1
if [[ "$baseline" == "__auto__" ]]; then
  baseline_explicit=0
  # Same filter and same sort as release-cut.yml's incumbent and install.sh's
  # resolve_gh_tag(). At fold time the tag for THIS cut does not exist yet, so the
  # newest tag is the previous release.
  _prev_tag="$(git tag -l 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  # DIVE-3170: resolve tag -> main commit through the one helper, never "^" here.
  baseline=""
  if [[ -n "$_prev_tag" ]]; then
    _here="$(dirname -- "${BASH_SOURCE[0]}")"
    baseline="$(bash "${_here}/release-cut-baseline.sh" "$_prev_tag" 2>/dev/null || true)"
    # Unresolvable stays unresolvable and keeps the loud warning below; it must not
    # quietly degrade to a tag-relative guess that is wrong in the same direction.
    [[ -n "$baseline" ]] || baseline="${_prev_tag}^{unresolvable-baseline}"
  fi
fi
if [[ -n "$baseline" ]] && ! git rev-parse --verify -q "${baseline}^{commit}" >/dev/null 2>&1; then
  # Loud, and it names the consequence rather than the symptom: this is the exact
  # state in which every already-shipped fragment folds a second time.
  echo "fold-changelog-fragments: baseline '${baseline}' does not resolve to a commit ($([[ $baseline_explicit -eq 1 ]] && echo 'passed in FOLD_RELEASED_BASELINE' || echo 'auto-detected from the newest release tag')) — folding EVERY fragment, so entries that already shipped may repeat in these notes (DIVE-2702)" >&2
  baseline=""
fi
# Fragment paths are matched against the baseline TREE, so they must be
# repo-relative even when the script is run from a subdirectory.
prefix="$(git rev-parse --show-prefix 2>/dev/null || true)"

folded=0
skipped_released=0
skipped_malformed=0
# THE ACCEPTED HEADING, kept byte-identical to the condition in
# scripts/lint-changelog-fragments.sh (DIVE-4177). The PR-time lint is what keeps this
# refusal from ever firing on a clean main; if the two patterns drift, the lint admits
# a fragment this loop then skips, which is the exact defect wearing a green check.
# tests/changelog_fragment_lint_unit.sh asserts they are the same string.
readonly FRAGMENT_HEADING_RE='^##[[:space:]]+Unreleased([[:space:]]|$)'
malformed_paths=()
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for f in "${frags[@]}"; do
  path="${fragdir}/${f}"
  # Validate before consulting the baseline. A malformed file was never folded,
  # so its mere presence in an older main tree is not evidence that it shipped.
  # It must remain visible for repair, not disappear from the release tree under
  # the already-consumed cleanup below.
  first_content_line="$(grep -m1 -v '^[[:space:]]*$' "$path" || true)"
  if [[ ! "$first_content_line" =~ $FRAGMENT_HEADING_RE ]]; then
    echo "fold-changelog-fragments: ${path} does not start with '## Unreleased' — skipping (not folded, not deleted)" >&2
    skipped_malformed=$((skipped_malformed + 1))
    malformed_paths+=("$path")
    continue
  fi
  # DIVE-2702: already consumed by an earlier cut? Compare BLOBS, not idents —
  # an edited fragment is new content and must fold again. DIVE-3291: "skip"
  # means skip adding its prose a second time, not keep the source fragment in
  # this release tree. The detached cut must consume both new and already-shipped
  # valid fragments; main remains untouched by the cut (DIVE-2247).
  if [[ -n "$baseline" ]]; then
    released_blob="$(git rev-parse --verify -q "${baseline}:${prefix}${path}" 2>/dev/null || true)"
    if [[ -n "$released_blob" && "$released_blob" == "$(git hash-object -- "$path" 2>/dev/null)" ]]; then
      echo "fold-changelog-fragments: ${path} already shipped in a previous cut (unchanged since ${baseline}) — skipping prose and deleting the consumed fragment from this release tree (DIVE-2702, DIVE-3291)" >&2
      rm -f "$path"
      skipped_released=$((skipped_released + 1))
      continue
    fi
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

if [[ "$skipped_released" -gt 0 ]]; then
  echo "fold-changelog-fragments: ${skipped_released} fragment(s) skipped as already shipped before ${baseline} (DIVE-2702)" >&2
fi

# DIVE-4177: A SKIP IS A DROPPED FEATURE, so it ends the cut instead of decorating it.
# Until now this loop printed the skip on stderr and returned 0, and release-cut.yml
# published anyway — v0.29.0 shipped six entries into the void that way and v0.30.0
# repeated it with the very commit that forced its own minor. The skipped prose is not
# recoverable after the tag: the notes are the diff over a range that has moved on.
# ITS OWN EXIT CODE (3), not the generic non-zero, because release-cut.yml maps a
# generic failure to `::warning ... publishing anyway` and must keep doing so — a fold
# that dies for some other reason is still not worth killing a cut over.
if [[ "$skipped_malformed" -gt 0 ]]; then
  echo "fold-changelog-fragments: REFUSING the fold — ${skipped_malformed} fragment(s) do not start with '## Unreleased' and would be dropped from these notes silently (DIVE-4177): ${malformed_paths[*]}" >&2
  echo "$folded"
  exit 3
fi

echo "$folded"
