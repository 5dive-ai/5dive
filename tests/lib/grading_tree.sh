# shellcheck shell=bash
# NAME THE TREE YOU GRADE.  (DIVE-2211, split out of DIVE-1921.)
#
# THE DEFECT THIS CLOSES.  Every harness in tests/ reads src/ from the WORKING
# TREE by relative path, so "21 passed, 0 failed" has always been a claim about
# whatever happened to be on disk, not about a commit.  A green log from a stale
# checkout and a green log from origin/main are byte-identical.  That is the
# whole class: an operation that succeeds against the WRONG TARGET is
# indistinguishable from one that succeeds against the right one -- no error, no
# empty result, and it hands you plausible content to reason about, which is
# worse than nothing because it feeds the next step.  dev's DIVE-2144 audit
# anchored to a checkout ~20 commits behind origin/main, read real well-formed
# bash, and recommended REMOVING a control that exists.
#
# The unifying predicate, which is what makes the audit finite rather than a
# standing instruction to be careful: THE OPERATION ACCEPTED A TARGET NOBODY
# NAMED AND DEFAULTED TO THE WRONG ONE.  Enumerate the operations in a control
# path that take a target you did not write down, and write it down.  That list
# terminates.
#
# WHY PRINT AND NOT CHECK.  An implicit target cannot be printed, because there
# is no expression for it -- so the print statement cannot be written without
# doing the resolution you had been letting default.  Checking demands you know
# which target is right AT THE MOMENT OF CHECKING; printing demands only that
# you stop letting it default.  Strictly weaker demand on the author, and it
# leaves evidence in the log.  It also deletes a moment of recall instead of
# relying on one: a control that must be RECALLED at the right instant is prose
# no matter where it is stored, and a successful read asks no question.
#
# This is deliberately NOT a gate.  A dirty or stale tree is the normal
# pre-commit case and must stay gradeable.  The property is only that no log can
# be SILENT about which tree it graded.
#
# THREE OUTCOMES, NOT TWO.  A check can pass, fail, or FAIL TO RUN, and the
# third is where this class re-enters through its own fix.  `git diff --quiet
# HEAD` exits nonzero both for "there is a difference" and for "I could not
# run", so a bare `|| dirty` asserts uncommitted work on the strength of a check
# that established nothing.  Flip the polarity to `&& echo CLEAN` and the same
# non-runnable check reports clean forever: same line, same bug, opposite blast
# radius.  So every branch below is explicit, and the unknown branch says out
# loud that it is asserting nothing.  The pattern is already in this repo --
# install.sh takes `resolve_gh_tag || true`, gets empty, and treats EMPTY AS ITS
# OWN THIRD BRANCH rather than defaulting either direction.
#
# WHY STDERR.  A harness's stdout can be its output contract.  A control that
# corrupts the thing it grades reds for the wrong reason, and a control that
# reds for the wrong reason is worse than no control because it reds often
# enough to feel real.  stderr is still the log in CI and in a terminal.
#
# WHY THE TREE IS RESOLVED FROM THIS FILE'S OWN PATH, not from $PWD.  Harnesses
# `cd` around; $PWD at source time is a target nobody named either.  The tree
# graded is the one the harness FILE lives in, and BASH_SOURCE is the only
# expression that says so.

_5d_grading_tree_line() {
  local root sha rc dirt

  root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || root=""
  if [[ -z "$root" ]]; then
    # Could-not-resolve is its own branch: no tree is named, and we say so
    # rather than naming a plausible wrong one.
    printf 'grading tree: UNRESOLVED (could not resolve the harness path; no tree named)\n'
    return 0
  fi

  sha="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || true)"
  if [[ -z "$sha" ]]; then
    # No commit exists to compare against, so there is no dirtiness question to
    # answer.  DIVE-1921's first attempt evaluated the diff unconditionally and
    # printed "NOT-A-GIT-TREE +UNCOMMITTED CHANGES" -- a claim about uncommitted
    # work from a check that could not run, inside the line written to stop
    # exactly that.  No tree, no dirtiness claim.
    printf 'grading tree: %s @ NOT-A-GIT-TREE (no commit to compare against; no dirtiness claim)\n' "$root"
    return 0
  fi

  # HEAD, not the default.  A bare `git diff --quiet` compares against the
  # INDEX, so a STAGED but uncommitted change reports CLEAN -- this line's own
  # defect class, live inside the fix for it, and caught only by staging a file
  # and watching it lie.
  rc=0
  git -C "$root" diff --quiet HEAD -- src tests 2>/dev/null || rc=$?
  case "$rc" in
    0) dirt="" ;;
    1) dirt="  +UNCOMMITTED CHANGES in src/ or tests/" ;;
    *) dirt="  +DIRTINESS UNKNOWN (git diff exited $rc; this label asserts nothing)" ;;
  esac

  printf 'grading tree: %s @ %s%s\n' "$root" "$sha" "$dirt"
}

# Print once per process, even if several files source this.  Guarded with :-
# so it is safe under `set -u`, and the whole thing is written so nothing can
# return nonzero into a caller running under `set -e`.
if [[ -z "${_5D_GRADING_TREE_PRINTED:-}" ]]; then
  _5D_GRADING_TREE_PRINTED=1
  _5d_grading_tree_line >&2
fi
:
