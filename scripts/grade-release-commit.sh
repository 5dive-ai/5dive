#!/usr/bin/env bash
# Grade the RELEASE COMMIT's own artifact (DIVE-2433).
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
# Usage: grade-release-commit.sh <expected-version>   # run from the release tree root
#
# Exits, matching scripts/pii-scan.sh's contract so a caller can tell "clean" from
# "could not look":
#   0  graded, clean
#   1  a grade FAILED — do not publish
#   2  UNDETERMINED — could not grade. This is NOT a pass.
set -uo pipefail

WANT_VERSION="${1:-}"
BUNDLE="${GRC_BUNDLE:-./5dive}"
TESTS_GLOB="${GRC_TESTS_GLOB:-tests/*.sh}"

if [[ -z "$WANT_VERSION" ]]; then
  echo "grade-release-commit: UNDETERMINED — no expected version given. This is NOT a pass." >&2
  exit 2
fi
if [[ ! -f "$BUNDLE" ]]; then
  echo "grade-release-commit: UNDETERMINED — no bundle at '$BUNDLE', so the released artifact was never run. This is NOT a pass." >&2
  exit 2
fi

rc=0

# 1. THE ARTIFACT ITSELF, not a rebuild of it. Ordered first because it is the whole
#    point of this script; the corpus below mostly re-covers the parent's tree.
#    --allow=snapshot-rails matches unit-tests.yml, so this is the same bar and not a
#    softer one invented here.
if bash "$BUNDLE" selfcheck --allow=snapshot-rails --label=release-commit; then
  echo "grade-release-commit: selfcheck PASS on the released bundle"
else
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

# 3. The corpus, same invocation as unit-tests.yml's `test` job, against the RELEASE
#    tree rather than main's.
#
#    An EMPTY glob is UNDETERMINED, never clean: a `for t in tests/*.sh` over nothing
#    iterates the literal pattern once, and a caller that only reads the exit code
#    cannot tell "every harness passed" from "no harness ran". That is the DIVE-2264
#    shape and it is exactly the failure this whole row is about, so it is refused
#    here rather than reported as a pass.
_ran=0 _failed=0
for _t in $TESTS_GLOB; do
  [[ -f "$_t" ]] || continue
  _ran=$((_ran + 1))
  bash "$_t" >/dev/null 2>&1 || { echo "grade-release-commit: FAIL — $_t" >&2; _failed=$((_failed + 1)); }
done
if (( _ran == 0 )); then
  echo "grade-release-commit: UNDETERMINED — no harness matched '$TESTS_GLOB', so the corpus never ran. This is NOT a pass." >&2
  exit 2
fi
(( _failed == 0 )) || rc=1
echo "grade-release-commit: corpus ran $_ran harness(es), $_failed failed"

if (( rc == 0 )); then
  echo "grade-release-commit: PASS — $WANT_VERSION graded on the exact artifact ($_ran harnesses + selfcheck + smoke)"
fi
exit "$rc"
