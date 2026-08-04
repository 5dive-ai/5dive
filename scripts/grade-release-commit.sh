#!/usr/bin/env bash
# Grade the RELEASE COMMIT's own artifact (DIVE-2433, reshaped by DIVE-2524).
#
# WHY THIS EXISTS. release-cut.yml builds a release commit, pushes it detached and
# tags it. Nothing grades that commit: measured on v0.17.10, the release commit
# d7db754 carries ZERO check-runs while its parent 2e36516 carries 10. So `test`,
# `install-smoke` and `docker-install` never touch the exact artifact customers
# install. Everything the cut already asserts is INTEGRITY — the bundle matches its
# own sha256, it is in the tagged tree, it is byte-correct over the CDN — and none
# of it is FUNCTION. A bundle can hash correctly and still be broken.
#
# AND CI'S OWN BUNDLE GRADE IS OF A DIFFERENT OBJECT: unit-tests.yml runs
# `./build.sh` first, because main carries no bundle at all since DIVE-2091, so it
# grades a REBUILD. Here the bundle in the tree IS the artifact, which makes the cut
# the only place the real one can be run.
#
# WHY NOT TRIGGER THE EXISTING WORKFLOWS ON THE TAG — the obvious fix, and a NO-OP.
# A push authenticated with GITHUB_TOKEN does not trigger workflows (GitHub's
# recursion guard). `push: tags:` in unit-tests.yml would look like coverage and fire
# never. Grading before the tag is pushed is also strictly better than a post-hoc
# check-run: a red after publication is a red on bytes boxes already install.
#
# WHY A SCRIPT AND NOT INLINE YAML, the same two reasons as scripts/pii-scan-range.sh
# (DIVE-2267): a workflow body cannot be unit-tested, and .github/workflows/ needs a
# credential most agents do not hold — so logic living in YAML is logic that cannot be
# repaired on the normal rail. This can, and is (tests/grade_release_commit_unit.sh).
#
# ---------------------------------------------------------------------------------
# DIVE-2524 — WHAT THE FIRST SHAPE OF THIS SCRIPT GOT WRONG, MEASURED.
#
# It ran the ENTIRE tests/*.sh corpus (264 harnesses, ~40 min) against the release
# tree, and it never passed once. DIVE-2433 merged 2026-07-30 17:14Z; v0.17.10 was
# cut 14:07Z that same day and is still the newest tag. Every cut since — six
# consecutive nights — died here, so the whole fleet sat pinned while main moved.
#
# TWO DISTINCT CAUSES WORE ONE RED X, and only one of them was a real signal:
#
#  1. tests/release_cut_bundle_unit.sh CANNOT PASS ON A RELEASE COMMIT, ever, on any
#     machine. It is the harness that guards MAIN's invariants — `5dive` and
#     `5dive.sha256` are untracked and gitignored (DIVE-2091), src/header.sh carries
#     the `0.0.0-dev` sentinel and not a real version (DIVE-2247). A release commit
#     tracks both artifacts and writes a real version: that IS what a release commit
#     is. Reproduced off CI with no token and no runner — 15 passed, 5 failed, the
#     five being exactly those invariants. So it is excluded BY NAME below, not
#     because it is flaky but because running it here asks a question whose only
#     correct answer is the failure it returns. It keeps running on main in
#     unit-tests.yml's `test` job, which is the tree it grades.
#
#  2. tests/task_merge_gate_multirepo_unit.sh and tests/task_merge_gate_result_pr_unit.sh
#     went green in that same release tree (36/0 and 31/0), so those two ARE
#     environment-specific — this job runs as uid 1001 with no token, its own
#     selfcheck line says the privileged half cannot be measured from here, and
#     that is the DIVE-2484 shape. Delta mode retires them from this job rather
#     than diagnosing them: they are graded on the parent, in a job that has what
#     they need.
#
# AND THE GRADE PRINTED NO EVIDENCE. Six nights of `FAIL — tests/x.sh` with the
# harness output sent to /dev/null. A reader could not tell a regression from a
# missing token, so the only available response was to ignore it — which is what
# happened, six times. That is the v0.16 "fails loud" thesis violated on the release
# path itself. Every failure now carries its own tail (GRC_TAIL lines).
#
# ---------------------------------------------------------------------------------
# DELTA MODE (DIVE-2524) — GRADE THE DELTA, INHERIT THE REST, BUT PROVE IT FIRST.
#
# The release commit differs from an already-graded main commit by one sed'd line
# plus regenerated artifacts. Re-running 264 harnesses to grade that is the wrong
# instrument: it costs 40 minutes AND it drags harnesses into an environment that
# cannot satisfy them.
#
# So when the caller names the PARENT, this script inherits the parent's check-runs
# for everything the delta cannot reach — and the inheritance is ASSERTED, never
# assumed. `git diff --name-only <parent> HEAD` must be a SUBSET of the paths a
# release commit is allowed to touch, and must CONTAIN src/header.sh. Both halves
# matter and for different reasons:
#
#   - the subset half is the premise. One extra path and "nothing else changed" is
#     false, the parent's green no longer describes this tree, and the cheap grade
#     would be inheriting a claim about a different object.
#   - the non-empty half is the anti-vacuity guard. A subset test over an EMPTY diff
#     passes trivially, so a cut that silently failed to write the version would sail
#     through the check that exists to catch exactly that.
#
# Either one failing is UNDETERMINED (2), not a failure and never a pass: the tree is
# not the shape delta mode reasons about, so this script has no verdict to give and
# says so. The caller (release-cut.yml) refuses on 2 exactly as hard as on 1.
#
# WITHOUT A PARENT there is no premise to prove, so there is nothing to inherit and
# the FULL corpus runs — the expensive path is the DEFAULT and the cheap one has to
# earn itself. GRC_FULL_CORPUS=1 forces the full corpus back on with a parent given.
#
# Usage: grade-release-commit.sh <expected-version> [<parent-sha>]
#        # run from the release tree root
#
# Exits, matching scripts/pii-scan.sh's contract so a caller can tell "clean" from
# "could not look":
#   0  graded, clean
#   1  a grade FAILED — do not publish
#   2  UNDETERMINED — could not grade. This is NOT a pass.
set -uo pipefail

WANT_VERSION="${1:-}"
PARENT_SHA="${2:-}"
BUNDLE="${GRC_BUNDLE:-./5dive}"
TESTS_GLOB="${GRC_TESTS_GLOB:-tests/*.sh}"
# How much of a failing harness's output to print. Enough to carry the assertion
# lines a harness prints last; not so much that six reds bury the summary.
GRC_TAIL="${GRC_TAIL:-25}"

# Paths a release commit is ALLOWED to differ from its parent by. Derived from the
# writers in release-cut.yml's release-commit block: src/header.sh (the DIVE-2247
# version assignment), the built bundle and its checksum, the DIVE-2452 CHANGELOG
# stamp, and the DIVE-2582 changelog.d fold. Anything else and the parent's CI no
# longer describes this tree.
#
# DIVE-2700: this comment said "which is the only writer" and named only the first
# four for as long as that was true. DIVE-2582 then added a SECOND writer — the fold
# at release-cut.yml:450 runs fold-changelog-fragments.sh, which DELETES every
# changelog.d/*.md it folds into CHANGELOG.md, staged at :493 — and nobody extended
# this list. The first cut attempted afterwards (v0.19.0, run 30885717462) refused
# with 7 fragment deletions "OUTSIDE the release-commit set", and every cut, patch or
# minor, would have refused identically for as long as any fragment existed. The guard
# was right; its premise had gone stale underneath it.
#
# ENTRIES ARE GLOB PATTERNS — see the matcher below. Keep this list and the workflow's
# writers in sync; tests/grade_release_commit_unit.sh section 11 derives the truth from
# the workflow and reds here at PR time, which is the only reason a human need not.
GRC_DELTA_PATHS="${GRC_DELTA_PATHS:-src/header.sh 5dive 5dive.sha256 CHANGELOG.md changelog.d/*}"
# The path whose presence in the delta proves the cut actually did something. Without
# it the subset assertion above is vacuous.
GRC_DELTA_REQUIRED="${GRC_DELTA_REQUIRED:-src/header.sh}"

# Harnesses that grade MAIN-TREE invariants and are therefore UNANSWERABLE on a
# release commit — see cause 1 in the header. Skipped by NAME and reported as a skip,
# never silently dropped: a corpus that quietly shrinks is the DIVE-2264 shape.
GRC_EXCLUDE="${GRC_EXCLUDE:-tests/release_cut_bundle_unit.sh}"

# The DELTA CORPUS: what a version write plus a rebundle plus a CHANGELOG stamp can
# actually reach, over and above the selfcheck/--version/--help grade of the artifact
# below. Everything else is inherited from the parent's check-runs, which is sound
# only because the delta assertion above proved the parent IS this tree minus those
# four paths.
#
# EVERY ENTRY WAS MEASURED ON A REAL RELEASE TREE, not reasoned about: a detached
# origin/main with FIVE_VERSION sed to 0.17.11, the CHANGELOG stamped, the bundle
# built and committed — the same object release-cut.yml produces. All 15 below ran
# green there in 49 SECONDS total, against ~40 minutes for the 264. release_cut_bundle
# is listed deliberately even though GRC_EXCLUDE drops it: naming it here is what
# makes its SKIP line appear in every release log, so the one harness this row had to
# stop running is visible in production and not only in this script's own tests.
#
#   release_cut_assign / release_cut_bundle / release_cut_guards  the cut's own rails
#   version_bump_guard / version_freeze_observer                  the version WRITE
#   update_check_propagation                                      DIVE-2042: compares
#                                                                 FIVE_VERSION to the
#                                                                 published tag, so the
#                                                                 sed IS its input
#   install_monotonicity / install_pin_sha / install_update_hint  version comparison on
#                                                                 the install path
#   install_checksum / self_bundle_evidence / gitattributes_...   the REBUNDLE
#   release_notes                                                 DIVE-2452 CHANGELOG
#   selfcheck / selfcheck_union                                   grade 1 below is a
#                                                                 selfcheck; these are
#                                                                 what keep it non-vacuous
#   grade_release_commit                                          this script
GRC_DELTA_TESTS="${GRC_DELTA_TESTS:-\
tests/release_cut_assign_unit.sh tests/release_cut_bundle_unit.sh tests/release_cut_guards_unit.sh \
tests/version_bump_guard_unit.sh tests/version_freeze_observer_unit.sh \
tests/update_check_propagation_unit.sh tests/install_monotonicity_unit.sh \
tests/install_pin_sha_unit.sh tests/install_update_hint_unit.sh tests/install_checksum_unit.sh \
tests/self_bundle_evidence_unit.sh tests/gitattributes_generated_merge_unit.sh \
tests/release_notes_unit.sh tests/selfcheck_unit.sh tests/selfcheck_union_unit.sh \
tests/grade_release_commit_unit.sh}"

if [[ -z "$WANT_VERSION" ]]; then
  echo "grade-release-commit: UNDETERMINED — no expected version given. This is NOT a pass." >&2
  exit 2
fi
if [[ ! -f "$BUNDLE" ]]; then
  echo "grade-release-commit: UNDETERMINED — no bundle at '$BUNDLE', so the released artifact was never run. This is NOT a pass." >&2
  exit 2
fi

rc=0

# ---------------------------------------------------------------------------------
# 0. THE INHERITANCE PREMISE. Runs FIRST, because everything cheap below is only
#    sound if this holds, and a premise checked after the thing it licenses is not a
#    premise.
# ---------------------------------------------------------------------------------
MODE=full
if [[ -n "$PARENT_SHA" && -z "${GRC_FULL_CORPUS:-}" ]]; then
  if ! _delta=$(git diff --name-only "$PARENT_SHA" HEAD 2>&1); then
    echo "grade-release-commit: UNDETERMINED — cannot diff HEAD against parent '$PARENT_SHA' ($_delta), so 'nothing else changed' is unproven and nothing can be inherited. This is NOT a pass." >&2
    exit 2
  fi
  _unexpected=()
  while IFS= read -r _p; do
    [[ -n "$_p" ]] || continue
    _ok=0
    # RHS deliberately UNQUOTED so entries act as GLOB PATTERNS (DIVE-2700): the fold
    # removes a whole directory of fragments whose names cannot be enumerated ahead of
    # time. The four literal entries carry no glob metacharacters, so this is inert for
    # them and changes only what a pattern entry can express.
    # shellcheck disable=SC2053  # glob matching is the point here, not an oversight
    for _allowed in $GRC_DELTA_PATHS; do [[ "$_p" == $_allowed ]] && { _ok=1; break; }; done
    (( _ok )) || _unexpected+=("$_p")
  done <<< "$_delta"
  if (( ${#_unexpected[@]} > 0 )); then
    echo "grade-release-commit: UNDETERMINED — the release commit differs from its parent ${PARENT_SHA:0:12} by ${#_unexpected[@]} path(s) OUTSIDE the release-commit set (${_unexpected[*]}). The parent's check-runs do not describe this tree, so nothing can be inherited from them. Re-run with GRC_FULL_CORPUS=1 to grade the whole corpus instead. This is NOT a pass." >&2
    exit 2
  fi
  _missing=()
  for _req in $GRC_DELTA_REQUIRED; do
    grep -qxF "$_req" <<< "$_delta" || _missing+=("$_req")
  done
  if (( ${#_missing[@]} > 0 )); then
    echo "grade-release-commit: UNDETERMINED — the delta against parent ${PARENT_SHA:0:12} does NOT touch ${_missing[*]}, so the version assignment never landed and the subset check above proved nothing about an empty diff. This is NOT a pass." >&2
    exit 2
  fi
  MODE=delta
  echo "grade-release-commit: delta vs parent ${PARENT_SHA:0:12} is within the release-commit set and assigns the version — inheriting the parent's check-runs for the rest (DIVE-2524)"
fi

# 1. THE ARTIFACT ITSELF, not a rebuild of it. Ordered first among the grades because
#    it is the whole point of this script.
#    --allow=snapshot-rails matches unit-tests.yml, so this is the same bar and not a
#    softer one invented here.
if _sc_out=$(bash "$BUNDLE" selfcheck --allow=snapshot-rails --label=release-commit 2>&1); then
  echo "$_sc_out"
  echo "grade-release-commit: selfcheck PASS on the released bundle"
else
  echo "$_sc_out"
  echo "grade-release-commit: FAIL — selfcheck did not pass on the released bundle" >&2
  rc=1
fi

# 2. Bundle smoke: the two invocations every box makes first. A bundle that cannot
#    state its own version is one nobody can diagnose later.
_got_ver="$(bash "$BUNDLE" --version 2>/dev/null | awk '{print $2}')"
if [[ "$_got_ver" == "$WANT_VERSION" ]]; then
  echo "grade-release-commit: --version reports $_got_ver"
else
  echo "grade-release-commit: FAIL — released bundle reports '${_got_ver:-<nothing>}' from --version, expected '$WANT_VERSION'" >&2
  rc=1
fi
if bash "$BUNDLE" --help >/dev/null 2>&1; then
  echo "grade-release-commit: --help runs"
else
  echo "grade-release-commit: FAIL — released bundle cannot print --help" >&2
  rc=1
fi

# 3. The harness corpus against the RELEASE tree.
#
#    In FULL mode this is the same invocation as unit-tests.yml's `test` job. In DELTA
#    mode it is the named subset that a version write and a rebundle can reach; the
#    rest is inherited from the parent, which section 0 proved is this tree.
#
#    An EMPTY set is UNDETERMINED, never clean: a `for t in tests/*.sh` over nothing
#    iterates the literal pattern once, and a caller that only reads the exit code
#    cannot tell "every harness passed" from "no harness ran". That is the DIVE-2264
#    shape and it is exactly the failure this whole row is about, so it is refused
#    here rather than reported as a pass.
if [[ "$MODE" == delta ]]; then
  _set="$GRC_DELTA_TESTS"
  _what="delta corpus"
else
  _set="$TESTS_GLOB"
  _what="corpus"
fi

_ran=0 _failed=0 _skipped=0
for _t in $_set; do
  [[ -f "$_t" ]] || continue
  _skip=0
  for _x in $GRC_EXCLUDE; do [[ "$_t" == "$_x" ]] && { _skip=1; break; }; done
  if (( _skip )); then
    # Named, printed, and counted. The reader must be able to see what did NOT run.
    echo "grade-release-commit: SKIP — $_t grades MAIN-tree invariants (untracked bundle, 0.0.0-dev sentinel) that a release commit inverts by construction; it is graded on main in unit-tests.yml's \`test\` job (DIVE-2524)"
    _skipped=$((_skipped + 1))
    continue
  fi
  _ran=$((_ran + 1))
  if ! _out=$(bash "$_t" 2>&1); then
    _failed=$((_failed + 1))
    # ITEM 1 of DIVE-2524: a rail that fails without saying why gets ignored, and this
    # one was, six nights running. The tail goes to the same stream as the verdict.
    {
      echo "grade-release-commit: FAIL — $_t"
      echo "--- last ${GRC_TAIL} lines of $_t ---"
      tail -n "$GRC_TAIL" <<< "$_out"
      echo "--- end $_t ---"
    } >&2
  fi
done
if (( _ran == 0 )); then
  echo "grade-release-commit: UNDETERMINED — no harness matched '$_set' (${_skipped} excluded by name), so the ${_what} never ran. This is NOT a pass." >&2
  exit 2
fi
(( _failed == 0 )) || rc=1
echo "grade-release-commit: ${_what} ran $_ran harness(es), $_failed failed, $_skipped skipped"

if (( rc == 0 )); then
  if [[ "$MODE" == delta ]]; then
    echo "grade-release-commit: PASS — $WANT_VERSION graded on the exact artifact ($_ran delta harnesses + selfcheck + smoke), the rest inherited from parent ${PARENT_SHA:0:12} whose delta is proven to be the release-commit set alone"
  else
    echo "grade-release-commit: PASS — $WANT_VERSION graded on the exact artifact ($_ran harnesses + selfcheck + smoke)"
  fi
fi
exit "$rc"
