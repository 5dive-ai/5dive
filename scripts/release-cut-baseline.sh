#!/usr/bin/env bash
# release-cut-baseline.sh — print the MAIN commit a published tag was cut from
# (DIVE-3170).
#
# WHY THIS FILE EXISTS. Three places in release-cut.yml need the same fact — "main's
# tip as of the last cut": the DIVE-2247 main-moved check, the DIVE-2702 fold
# baseline, and the DIVE-2452 release-notes range. All three spelled it
# `<tag>^` — the tag's commit's first parent — and all three were WRONG, because a
# cut does not make one commit. It makes TWO:
#
#     <tag>            release vX: bundle built from <sha> (DIVE-2091, DIVE-2603)
#     <tag>^           release vX: assign X before bundle build (DIVE-2247, DIVE-2603)
#     <tag>^^          <- the actual main commit the cut was taken from
#
# The assign commit (DIVE-2603 split the cut in two) is where the fold and the
# stamp already ran, so `<tag>^` is a POST-FOLD release tree, not main. Measured
# 2026-08-10 on v0.19.11 .. v0.19.14: `git ls-tree <tag>^ changelog.d/` listed 2
# entries (README.md and one malformed fragment) while main listed 52, and
# `<tag>^^` was an ancestor of origin/main with 43. Consequences, all observed:
#
#   * The DIVE-2702 fold guard looked every fragment up in a tree the fold had
#     already emptied, found nothing, skipped nothing, and re-folded all 52 every
#     cut — so v0.19.11/.12/.13/.14 advertise a byte-identical `### Features`
#     block. That is DIVE-3170 as filed.
#   * The main-moved check compared main's tip against an assign commit, which is
#     never equal to it, so the "nothing to publish" early-exit could not fire.
#   * The notes range started at the assign commit for the same reason.
#
# THE RULE, stated once and only once so a fourth site cannot drift: walk
# first-parent from the tag's commit and return the FIRST commit that is an
# ancestor of main. That is definitionally the commit the cut was taken from, and
# it does not care how many release commits DIVE-2603 (or its successor) stacks on
# top — one, two or five. `<tag>^^` would only re-encode today's count.
#
# Usage: release-cut-baseline.sh <tag-or-commit> [main-ref]
#        main-ref defaults to origin/main, then main, whichever resolves.
#        Prints the sha on stdout and exits 0. Prints nothing and exits 1 if the
#        tag does not resolve or no ancestor of main is reachable — callers treat
#        an empty answer as "could not look", which is NOT the same as "no
#        previous cut" and must never be folded together with it.
set -uo pipefail

tag="${1-}"
main_ref="${2-}"

if [[ -z "$tag" ]]; then
  echo "usage: release-cut-baseline.sh <tag-or-commit> [main-ref]" >&2
  exit 2
fi

start="$(git rev-parse -q --verify "${tag}^{commit}" 2>/dev/null || true)"
if [[ -z "$start" ]]; then
  echo "release-cut-baseline: '${tag}' does not resolve to a commit" >&2
  exit 1
fi

if [[ -z "$main_ref" ]]; then
  for _c in origin/main main; do
    if git rev-parse -q --verify "${_c}^{commit}" >/dev/null 2>&1; then
      main_ref="$_c"
      break
    fi
  done
fi
if [[ -z "$main_ref" ]] || ! git rev-parse -q --verify "${main_ref}^{commit}" >/dev/null 2>&1; then
  echo "release-cut-baseline: no main ref resolves (tried '${2-origin/main, main}') — cannot say what '${tag}' was cut from" >&2
  exit 1
fi

# Bounded on purpose: the answer is one or two commits away by construction, and
# an unbounded walk on a tag that is somehow disjoint from main would otherwise
# scan the whole history to say "no".
while read -r c; do
  if git merge-base --is-ancestor "$c" "$main_ref" 2>/dev/null; then
    echo "$c"
    exit 0
  fi
done < <(git rev-list --first-parent --max-count=25 "$start" 2>/dev/null)

echo "release-cut-baseline: no ancestor of ${main_ref} within 25 first-parent commits of '${tag}' — the tag is not descended from main" >&2
exit 1
