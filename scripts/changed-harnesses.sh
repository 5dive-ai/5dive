#!/usr/bin/env bash
# DIVE-4208 — WHICH HARNESSES DID THIS CHANGE TOUCH. One implementation, two
# callers.
#
# WHY THIS FILE EXISTS AT ALL. The selection used to live inline in the
# `changed-harnesses` job of .github/workflows/unit-tests.yml, which was fine
# while CI was the only thing that ran it. DIVE-4208 adds a second caller — the
# pre-push rail, which runs the same harnesses in the maker's worktree BEFORE
# the push — and a selector written in two places is one contract with two
# authors. tests/lib/tier.sh's own header says exactly this about the corpus
# selector, one level out: when the two drift, the local rail and the merge gate
# silently grade different sets, and the local one greens on a set that does not
# include the file CI is about to red on. That is worse than no local rail,
# because it is a green that means nothing.
#
# So the job now CALLS this, the same way the pre-push hook calls
# scripts/pii-scan.sh rather than carrying a copy of the pattern list.
#
# CONTRACT
#   usage: scripts/changed-harnesses.sh <base> [head]
#   stdout: one harness path per line, repo-relative, possibly empty
#   stderr: the base it resolved and why
#   exit 0  selection made (including an empty selection from a real diff)
#   exit 1  no base could be resolved — see below
#
# A BASE WE CANNOT RESOLVE IS NOT "NOTHING CHANGED". That distinction is carried
# over from the job verbatim and is the reason this exits 1 rather than printing
# an empty list: an unresolvable base printed as an empty selection is a check
# reporting clean on what it never looked at. Callers must treat exit 1 as
# BLOCKED, not as a green.
#
# THE PATHSPEC. tests/*.sh only, never tests/lib/ or tests/meta/ — the same
# corpus shape the shell glob in tests/lib/tier.sh selects. --diff-filter=ACMR
# excludes deletions: a harness that is gone cannot be run, and making deletion
# easy is the direction DIVE-2525's budget work is pushing.
#
# A CHANGED-FILES SELECTOR CANNOT SEE A CORPUS-WIDE CONTRACT. Some harnesses do
# not grade their own source — they enumerate `tests/*.sh` and assert a property
# of EVERY OTHER harness (the HARNESS-RC EXIT trap, the named grading tree). For
# those, the input is the corpus, so ADDING a harness invalidates them while
# leaving their own diff empty: a path-keyed selection returns them exactly never,
# and the rail greens on a set chosen to exclude the check that is about to red
# the PR. Measured on this row's own first push (DIVE-4208, quinn's iteration-1
# rejection): `harnesses 2.5s green` locally, then core-pristine(1) /
# core-installed-host(1) / test / test-installed-host red on
# harness_rc_corpus_contract_unit.sh naming the harness the branch had just added.
#
# So when the diff ADDS or DELETES any tests/*.sh, the corpus-wide contracts join
# the selection. They are DISCOVERED, not hardcoded: any harness whose source
# enumerates the corpus glob is one, so the next contract of this shape is covered
# the day it lands, without editing this file. Graded by A15/A16 in
# tests/pre_push_rail_unit.sh; the path-keyed mutant reds A15.
set -uo pipefail

base="${1:-}"
head_rev="${2:-HEAD}"

if [[ -z "$base" || "$base" == 0000000000000000000000000000000000000000 ]] \
   || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
  # --verify --quiet, NOT a bare rev-parse: a bare `git rev-parse origin/main` in
  # a repo that has no such ref ECHOES THE ARGUMENT BACK and exits 128, so the
  # fallback "succeeds" with the literal string "origin/main" and every command
  # downstream fails on a revision that was never a sha. That is the
  # unresolvable-base case wearing the resolved-base costume — the exact
  # substitution this script exists to refuse. Graded by
  # tests/pre_push_rail_unit.sh A5.
  base="$(git rev-parse --verify --quiet origin/main 2>/dev/null || true)"
  [[ -n "$base" ]] && echo "changed-harnesses: base not resolvable; falling back to origin/main ($base)." >&2
fi

if [[ -z "$base" ]]; then
  echo "changed-harnesses: BLOCKED — could not resolve a base commit to diff against; refusing to report 'no harnesses changed' on the strength of a diff that never ran." >&2
  exit 1
fi

echo "changed-harnesses: base=$base head=$head_rev" >&2

# The corpus of the repo BEING DIFFED, not of wherever this script happens to
# live: the rail copies this file around, and the contracts that matter are the
# ones in the tree whose push is being graded.
TOP="$(git rev-parse --show-toplevel 2>/dev/null)"
[[ -n "$TOP" ]] || TOP="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

sel="$(git diff --name-only --diff-filter=ACMR "$base" "$head_rev" -- \
  'tests/*.sh' ':(exclude)tests/lib/*' ':(exclude)tests/meta/*')"

# ADDED or DELETED — the two edits that change what a corpus-wide contract reads.
# A pure MODIFY does not: the corpus membership is the same set before and after.
addel="$(git diff --name-only --diff-filter=AD "$base" "$head_rev" -- \
  'tests/*.sh' ':(exclude)tests/lib/*' ':(exclude)tests/meta/*')"

if [[ -n "$addel" ]]; then
  contracts=()
  while IFS= read -r c; do [[ -n "$c" ]] && contracts+=("tests/$(basename "$c")"); done < <(
    grep -lE '^[[:space:]]*[A-Za-z_]+=\(tests/\*\.sh\)' "$TOP"/tests/*.sh 2>/dev/null
  )
  if (( ${#contracts[@]} )); then
    echo "changed-harnesses: diff adds/deletes harness(es); adding ${#contracts[@]} corpus-wide contract(s) whose input is the corpus, not their own source." >&2
    sel="$(printf '%s\n' "$sel" "${contracts[@]}")"
  else
    echo "changed-harnesses: diff adds/deletes harness(es) but NO corpus-wide contract was discovered — if one exists it is not being selected." >&2
  fi
fi

printf '%s\n' "$sel" | sed '/^$/d' | sort -u
