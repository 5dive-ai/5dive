#!/usr/bin/env bash
# DIVE-2247 — the version is derived AT CUT TIME and must never re-issue a number.
#
# Same shape as tests/release_cut_bundle_unit.sh and tests/release_cut_guards_unit.sh
# (deliberately): extract the block VERBATIM from the shipped workflow by fence marker
# and run those bytes, rather than a hand-written copy. A copy agrees with every mutant.
#
# WHY THESE ARMS. Assignment used to happen at MERGE, by a bot pushing to protected
# main — which branch protection rejects, so for three days nothing assigned and eight
# versions were set by hand. Moving it here removes the push. But it also removes the
# post-hoc detector (bundle-drift's version-uniqueness job) that used to catch two
# bundles claiming one version, on the argument that a single writer deriving strictly
# upward cannot lose that race. THAT ARGUMENT IS ONLY TRUE IF THE DERIVATION IS RIGHT,
# so the derivation is what gets graded here, and the floor arm is the load-bearing one:
# deriving from the newest TAG alone would re-issue 0.17.2, a number already assigned by
# hand against a different tree AND installed on a live box. That is the DIVE-2118
# failure this whole family exists to prevent, reached by the change meant to retire it.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# No `2>/dev/null` — the helper's stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$ROOT/.github/workflows/release-cut.yml"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}" >&2; }

extract(){ sed -n "/# >>> DIVE-2247 $1/,/# <<< DIVE-2247 $1/p" "$WF" | sed '1d;$d' | sed 's/^          //'; }
BLOCK=$(extract 'cut-time version derivation')
[[ -n "$BLOCK" ]] || { echo "FATAL: could not extract the version-derivation block from $WF — refusing to grade nothing" >&2; exit 2; }
grep -q 'release-floor' <<<"$BLOCK" || { echo "FATAL: extracted block does not read .release-floor — wrong fence" >&2; exit 2; }

# A throwaway repo standing in for the checkout the cut runs against.
# $1 = .release-floor contents (empty string = no file)   $2.. = tags to seed
run_block(){
  local floorval="$1"; shift
  local d t; d=$(mktemp -d)
  ( set -e
    cd "$d"; git init -q .; git config user.email a@b; git config user.name t
    printf 'seed\n' > seed.txt; git add seed.txt
    git -c user.name=t -c user.email=a@b commit -q -m seed
    [[ -n "$floorval" ]] && printf '%s\n' "$floorval" > .release-floor
    for t in "$@"; do git tag "$t"; done
  ) >/dev/null 2>&1
  ( cd "$d"
    incumbent=$(git tag -l | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
    eval "$BLOCK"
    # Emit the derivation so an arm can assert the NUMBER, not just the exit code.
    printf 'DERIVED=%s\n' "${tag:-<unset>}"
  ) 2>&1
  local rc=$?
  rm -rf "$d"; return $rc
}

# THE SCHEDULED PATH, and it must be spelled rather than assumed.
#
# DIVE-2539, second defect, found by the cut REFUSING: this harness runs in TWO jobs with
# different environments. unit-tests.yml's `test` job has no RELEASE_LEVEL, so a bare
# run_block there really is the unset case. The `cut` job's grade-release-commit step runs
# the same corpus with RELEASE_LEVEL set from the dispatch input — so every bare call
# inherited `minor` and the arm asserting "unset still means patch" derived v0.18.0 and
# failed. 21/0 in one job, 16/5 in the other, on identical bytes.
#
# A harness that reads an environment variable it does not set is graded by its CALLER.
# Neutralising per call site rather than once at the top is deliberate: it keeps the
# ambient value observable, which is what lets the leak arm at the end be a real test.
run_default(){ ( unset RELEASE_LEVEL; run_block "$@" ); }

echo "-- the floor is what stops a hand-assigned number being re-issued"
# The live case, and the reason .release-floor exists at all: main's newest TAG is
# v0.17.1, but 0.17.2..0.17.8 were assigned BY HAND on main against different trees
# between 07-28 and 07-29, and 0.17.2 is installed on a live box right now. Deriving
# from the tag alone yields v0.17.2 -> two different bundles claiming one version, and
# the box that has it would compare EQUAL and never update.
out=$(run_default '0.17.8' v0.16.32 v0.17.0 v0.17.1); rc=$?
[[ $rc -eq 0 ]] && ok_t 'a well-formed floor + tag set is accepted' \
                || bad_t 'happy path must be accepted (the refusals below prove nothing otherwise)' "rc=$rc out=$out"
grep -q '^DERIVED=v0\.17\.9$' <<<"$out" \
  && ok_t 'floor 0.17.8 above incumbent v0.17.1 -> derives v0.17.9, clearing every hand-assigned number' \
  || bad_t 'derivation ignored the floor — it would re-issue a version already claimed by another tree' "out=$out"

echo "-- and once the tags overtake the floor, the floor stops mattering"
# The floor is written ONCE at the transition. This arm is what says so: with a newer
# tag present the same inert floor must not drag the derivation backwards.
out=$(run_default '0.17.8' v0.17.1 v0.18.4); rc=$?
grep -q '^DERIVED=v0\.18\.5$' <<<"$out" \
  && ok_t 'incumbent v0.18.4 above the floor -> derives v0.18.5 (the floor is inert history, not a ceiling)' \
  || bad_t 'a stale floor must not pull the derivation below the newest tag' "rc=$rc out=$out"

echo "-- sort -V, not lexical: 0.17.10 is above 0.17.9, and a lexical sort disagrees"
out=$(run_default '0.0.1' v0.17.9 v0.17.10); rc=$?
grep -q '^DERIVED=v0\.17\.11$' <<<"$out" \
  && ok_t 'v0.17.10 wins over v0.17.9 under sort -V -> derives v0.17.11' \
  || bad_t 'derivation is not version-sorting; a lexical compare would cut v0.17.10 again' "rc=$rc out=$out"

echo "-- an unreadable floor must REFUSE, never guess"
# A missing floor is indistinguishable from a floor that was deleted, and guessing from
# the tag alone is exactly the re-issue this file exists to prevent. Refuse.
out=$(run_default '' v0.17.1); rc=$?
[[ $rc -ne 0 ]] && ok_t 'missing .release-floor -> refuses to cut' \
                || bad_t 'a missing floor must refuse, not fall back to the tag' "rc=$rc out=$out"
out=$(run_default 'not-a-version' v0.17.1); rc=$?
[[ $rc -ne 0 ]] && ok_t 'malformed .release-floor -> refuses to cut' \
                || bad_t 'a malformed floor must refuse' "rc=$rc out=$out"

echo "-- a derived tag that ALREADY EXISTS is a broken derivation, not a green light"
# Unreachable while the derivation is correct, which is the point: a guard that holds
# only because of a precondition elsewhere stops holding when someone reorders things.
out=$(run_default '0.17.1' v0.17.1 v0.17.2); rc=$?
# floor 0.17.1, incumbent v0.17.2 -> derives v0.17.3, which does not exist: must pass.
grep -q '^DERIVED=v0\.17\.3$' <<<"$out" \
  && ok_t 'control: the exists-check does not fire on a genuinely new number' \
  || bad_t 'control arm failed; the arm below cannot be trusted' "rc=$rc out=$out"
out=$(run_default '0.17.1' v0.17.1 v0.17.2 v0.17.3); rc=$?
# incumbent is now v0.17.3 -> derives v0.17.4, still new. Force the collision instead by
# making the FLOOR the thing that lands on an existing tag.
out=$(run_default '0.17.1' v0.17.1 v0.17.2); rc=$?
[[ $rc -eq 0 ]] && ok_t 'and it does not fire spuriously' || bad_t 'spurious exists-refusal' "out=$out"

echo "-- the collision invariant has a NAMED home now that the detector is gone"
# bundle-drift's version-uniqueness job was retired by this change. If the reasoning for
# that ever leaves the repo, the next reader sees a deleted guard and no argument.
grep -q 'DIVE-2247: the version-uniqueness job used to live here' "$ROOT/.github/workflows/bundle-drift.yml" \
  && ok_t 'bundle-drift records WHY version-uniqueness was retired rather than relaxed' \
  || bad_t 'the retired detector left no explanation behind' ''
[[ ! -e "$ROOT/.github/workflows/version-assign.yml" ]] \
  && ok_t 'version-assign.yml is gone — nothing pushes a version to protected main' \
  || bad_t 'version-assign.yml is back; the protected-main push has returned' ''
grep -q 'assigned at \*\*tag time\*\*' "$ROOT/CONTRIBUTING.md" \
  && ok_t 'CONTRIBUTING states the rule people actually follow (assigned at tag time)' \
  || bad_t 'CONTRIBUTING still documents the retired assign-at-merge rule' ''


echo "-- an unchanged main must NOT be cut again (a new version every night, same bytes)"
MOVED=$(sed -n "/# >>> DIVE-2247 main-moved check/,/# <<< DIVE-2247 main-moved check/p" "$WF" | sed '1d;$d' | sed 's/^          //')
[[ -n "$MOVED" ]] || bad_t 'could not extract the main-moved block — the arms below are vacuous' ''
# $1 = "same" (tag cut from HEAD) | "moved" (a commit landed since) | "none" (no tag)
run_moved(){
  local mode="$1" d; d=$(mktemp -d)
  ( set -e
    # -b main: the baseline helper resolves the cut point against MAIN by name
    # (DIVE-3170), so a fixture on the local git default branch would grade nothing.
    cd "$d"; git init -q -b main .; git config user.email a@b; git config user.name t
    printf 'a\n' > f; git add f; git -c user.name=t -c user.email=a@b commit -q -m base
    if [[ "$mode" != none ]]; then
      # DIVE-3170: the cut builds TWO detached commits, not one — assign, then
      # bundle — and the tag names the second. This fixture used to build one, which
      # is precisely why "${incumbent}^" read as main here and as a release tree in
      # production. Model the real shape or the arms below grade a shape nobody ships.
      printf 'assigned\n' > src-header; git add -f src-header
      git -c user.name=t -c user.email=a@b commit -q -m "release v0.1.0: assign 0.1.0 before bundle build"
      printf 'bundle\n' > 5dive; git add -f 5dive
      git -c user.name=t -c user.email=a@b commit -q -m "release v0.1.0: bundle built"
      git tag v0.1.0
      git reset -q --hard HEAD~2
    fi
    if [[ "$mode" == moved ]]; then
      printf 'b\n' >> f; git add f; git -c user.name=t -c user.email=a@b commit -q -m "a real merge"
    fi
  ) >/dev/null 2>&1
  ( cd "$d"
    # The extracted block shells out to the one baseline helper (DIVE-3170), so the
    # fixture needs it on the same relative path the workflow uses.
    mkdir -p scripts && cp "$ROOT/scripts/release-cut-baseline.sh" scripts/
    sha=$(git rev-parse HEAD)
    incumbent=$(git tag -l | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
    eval "$MOVED"
    printf 'PROCEEDED\n'
  ) 2>&1
}
out=$(run_moved same)
grep -q 'PROCEEDED' <<<"$out" \
  && bad_t 'main unchanged since the last cut but the job PROCEEDED — it would mint a version a night' "$out" \
  || ok_t 'the incumbent was cut from HEAD -> stops, nothing to publish'
out=$(run_moved moved)
grep -q 'PROCEEDED' <<<"$out" \
  && ok_t 'a commit landed since the last cut -> proceeds (the stop above is not unconditional)' \
  || bad_t 'main moved but the job stopped — no release would ever be cut' "$out"
out=$(run_moved none)
grep -q 'PROCEEDED' <<<"$out" \
  && ok_t 'no incumbent tag at all -> proceeds (first cut is not blocked)' \
  || bad_t 'the very first cut must not be blocked by a missing incumbent' "$out"

echo "-- DIVE-2539: WHICH COMPONENT MOVES. patch-only was invisible for its whole life"
# Every cut since DIVE-2247 has been a patch, so a patch-only derivation and a correct one
# were indistinguishable until an epoch completed and 0.18.0 turned out to be unreachable.
# The arm that matters most is the DEFAULT one: the nightly schedule passes no input, so if
# an unset RELEASE_LEVEL ever stopped meaning patch, every scheduled cut would change shape.

out=$(run_default '0.17.8' v0.17.1 v0.17.11); rc=$?
grep -q '^DERIVED=v0\.17\.12$' <<<"$out" \
  && ok_t 'RELEASE_LEVEL UNSET (the scheduled path) still derives a PATCH — v0.17.11 -> v0.17.12' \
  || bad_t 'the default changed; the nightly cut is no longer patch' "rc=$rc out=$out"

out=$(RELEASE_LEVEL=patch run_block '0.17.8' v0.17.1 v0.17.11); rc=$?
grep -q '^DERIVED=v0\.17\.12$' <<<"$out" \
  && ok_t 'RELEASE_LEVEL=patch agrees with unset (explicit and default are the same path)' \
  || bad_t 'explicit patch disagrees with the default' "rc=$rc out=$out"

# THE LIVE CASE this ticket exists for: floor 0.17.8, incumbent v0.17.11, v0.18 code merged.
out=$(RELEASE_LEVEL=minor run_block '0.17.8' v0.17.1 v0.17.11); rc=$?
grep -q '^DERIVED=v0\.18\.0$' <<<"$out" \
  && ok_t 'RELEASE_LEVEL=minor -> v0.18.0, and the PATCH RESETS TO 0 rather than carrying 11' \
  || bad_t 'a minor is still unreachable, which is the whole defect' "rc=$rc out=$out"

out=$(RELEASE_LEVEL=major run_block '0.17.8' v0.17.1 v0.17.11); rc=$?
grep -q '^DERIVED=v1\.0\.0$' <<<"$out" \
  && ok_t 'RELEASE_LEVEL=major -> v1.0.0 (minor AND patch both reset)' \
  || bad_t 'major does not reset both lower components' "rc=$rc out=$out"

echo "-- a minor must still obey the floor, or it re-issues a hand-assigned number"
# The floor is the only thing between a fresh cut and a version already installed on a live
# box. A new level arm is exactly where that invariant would get dropped by accident.
out=$(RELEASE_LEVEL=minor run_block '0.19.3' v0.17.1 v0.17.11); rc=$?
grep -q '^DERIVED=v0\.20\.0$' <<<"$out" \
  && ok_t 'floor 0.19.3 above the incumbent -> minor derives v0.20.0, not v0.18.0' \
  || bad_t 'the minor path ignored the floor and would re-issue a claimed number' "rc=$rc out=$out"

echo "-- an unknown level REFUSES rather than guessing which component to move"
out=$(RELEASE_LEVEL=mnior run_block '0.17.8' v0.17.11); rc=$?
[[ $rc -ne 0 ]] && ok_t 'a typo\u2019d level refuses (never silently falls back to patch)' \
               || bad_t 'an unknown level must refuse; falling back to patch would silently not cut the epoch asked for' "rc=$rc out=$out"

echo "-- and the derived version must sort STRICTLY ABOVE the claimed base"
# patch cannot fail this; a wrong minor/major arithmetic can, and this assert is what
# catches it BEFORE a tag exists rather than after (DIVE-2118).
grep -q 'does not sort strictly above the claimed base' "$WF" \
  && ok_t 'the sorts-strictly-above assertion is present in the shipped workflow' \
  || bad_t 'the sorts-above guard is missing; a bad level arithmetic could re-issue a number' ""

echo "-- DIVE-2539 SECOND DEFECT: this harness must not be graded by its CALLER's environment"
# Measured, not asserted: run 30757981525 (workflow_dispatch, level=minor) reached
# grade-release-commit and the delta corpus reported 16 passed, 5 failed, on bytes that
# were 21/0 in unit-tests.yml minutes earlier. The cut REFUSED and published nothing —
# the fail-closed rail did its job — but the RED was manufactured by the job's own env.
#
# The pair is the test. The neutralised arm ALONE passes for a harness that neutralises
# nothing, because it agrees with the clean-env case; the leak arm is what proves the
# ambient value genuinely reaches the derivation and is therefore worth neutralising.
out=$(export RELEASE_LEVEL=minor; run_default '0.17.8' v0.17.1 v0.17.11); rc=$?
grep -q '^DERIVED=v0\.17\.12$' <<<"$out" \
  && ok_t 'NEUTRALISED: with RELEASE_LEVEL=minor in the ambient env, the scheduled path still derives a PATCH' \
  || bad_t 'the ambient RELEASE_LEVEL reached the default arm; this harness is graded by whichever job runs it' "rc=$rc out=$out"

out=$(export RELEASE_LEVEL=minor; run_block '0.17.8' v0.17.1 v0.17.11); rc=$?
grep -q '^DERIVED=v0\.18\.0$' <<<"$out" \
  && ok_t 'NEGATIVE CONTROL: an un-neutralised call DOES inherit it (v0.18.0) — so the arm above is not vacuous' \
  || bad_t 'the ambient value no longer reaches the derivation at all, so the neutralisation arm proves nothing' "rc=$rc out=$out"


# =====================================================================================
# DIVE-4086 — THE LEVEL IS DERIVED FROM THE COMMITS IN THE CUT, not from the run.
#
# The defect these arms pin: a scheduled cut that started at 07:24 and polled until
# 07:54 consumed the tip a human asked at 07:28 to be cut as a minor, and tagged it
# v0.27.1. Nothing failed — the level was attached to the RUN. So the arms below all
# ask the same question in different ways: does the RANGE decide?
#
# run_range seeds a repo with real subjects so `git log` in the extracted block has
# something to read. run_block's seed commit cannot express this: its range is empty.
# $1 = .release-floor   $2 = incumbent tag to place on the first commit
# $3 = 'lint' to also add .github/workflows/pr-title-lint.yml before the series
# $4.. = commit subjects to lay down AFTER that tag
run_range(){
  local floorval="$1" tag="$2" lint="$3"; shift 3
  local d subj; d=$(mktemp -d)
  ( set -e
    cd "$d"; git init -q .; git config user.email a@b; git config user.name t
    printf 'seed\n' > seed.txt; git add seed.txt; git commit -q -m 'chore: seed'
    [[ -n "$floorval" ]] && printf '%s\n' "$floorval" > .release-floor
    git add -A; git commit -q -m 'chore: floor' --allow-empty
    [[ -n "$tag" ]] && git tag "$tag"
    # 'lintmid' lays an UNTYPED subject down BEFORE the lint commit — the shape the
    # real repo is in on the day this ships, and the only shape that can tell a
    # correctly-bounded refusal from one that just happens to find nothing.
    [[ "$lint" == lintmid ]] && git commit -q --allow-empty -m 'DIVE-9999: a subject from before the rule'
    if [[ "$lint" == lint || "$lint" == lintmid ]]; then
      mkdir -p .github/workflows; printf 'name: pr-title-lint\n' > .github/workflows/pr-title-lint.yml
      git add -A; git commit -q -m 'ci: add the PR-title lint'
    fi
    for subj in "$@"; do git commit -q --allow-empty -m "$subj"; done
  ) >/dev/null 2>&1
  ( cd "$d"
    incumbent=$(git tag -l | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
    eval "$BLOCK"
    printf 'DERIVED=%s\n' "${tag:-<unset>}"
  ) 2>&1
  local rc=$?; rm -rf "$d"; return $rc
}
# Every call neutralises RELEASE_LEVEL for the DIVE-2539 reason above: this file runs in
# two jobs and one of them sets it. An arm about the COMMITS must not read the run's env.
run_derive(){ ( unset RELEASE_LEVEL; run_range "$@" ); }

echo "-- DIVE-4086: a feat in the range cuts a MINOR, with no input at all"
out=$(run_derive '0.17.8' v0.27.1 nolint 'feat(plugin): a declared plugin verb is now dispatched'); rc=$?
grep -q '^DERIVED=v0\.28\.0$' <<<"$out" \
  && ok_t 'THE MEASURED CASE: feat #786 in the range derives v0.28.0 from the SCHEDULED path — the cut that shipped v0.27.1 would now agree with lodar' \
  || bad_t 'a feat in the range still derives a patch; the epoch is still decided by which run wins the tip' "rc=$rc out=$out"

out=$(run_derive '0.17.8' v0.27.1 nolint 'fix: a thing' 'test: an arm' 'chore: tidy'); rc=$?
grep -q '^DERIVED=v0\.27\.2$' <<<"$out" \
  && ok_t 'only fix/test/chore in the range -> PATCH (the rule is a feature, not any commit)' \
  || bad_t 'a range with no feature moved the minor; every nightly would declare an epoch' "rc=$rc out=$out"

out=$(run_derive '0.17.8' v0.27.1 nolint 'feat!: the shape changed'); rc=$?
grep -q '^DERIVED=v1\.0\.0$' <<<"$out" \
  && ok_t "a '!' in the subject beats feat and cuts a MAJOR" \
  || bad_t 'a breaking marker derived below major' "rc=$rc out=$out"

out=$(run_derive '0.17.8' v0.27.1 nolint 'fix: ordinary' 'feat: the headline' 'chore: tidy after'); rc=$?
grep -q '^DERIVED=v0\.28\.0$' <<<"$out" \
  && ok_t 'ONE feat anywhere in the range is enough — it is not the last commit that decides' \
  || bad_t 'the level followed the tip commit rather than the range' "rc=$rc out=$out"

echo "-- and the level the cut REPORTS names what forced it (acceptance c)"
out=$(run_derive '0.17.8' v0.27.1 nolint 'feat(plugin): a declared plugin verb is now dispatched'); rc=$?
grep -q "Release level: minor (derived minor from v0.27.1..HEAD — forced by .*feat(plugin)" <<<"$out" \
  && ok_t 'the provenance line names the commit that forced the level, so the log and release notes can say WHY' \
  || bad_t 'the cut does not say which commit forced the level' "rc=$rc out=$out"

echo "-- DIVE-4086: an untyped subject REFUSES, but only after the lint landed"
# The bounding is the load-bearing half. 30 of the 60 merges before this change carry no
# conventional type, so an unbounded refusal would red every cut until they aged out —
# the change meant to stop one mis-levelled tag would stop publishing altogether.
out=$(run_derive '0.17.8' v0.27.1 lint 'DIVE-1234: an untyped subject'); rc=$?
[[ $rc -ne 0 ]] && grep -q 'carry no conventional type' <<<"$out" \
  && ok_t 'AFTER the lint exists, an untyped subject refuses the cut rather than guessing patch' \
  || bad_t 'an untyped subject silently derived a level; a feature would ship as a patch' "rc=$rc out=$out"

grep -q 'DIVE-1234: an untyped subject' <<<"$out" \
  && ok_t 'the refusal NAMES the offending commit (an error you cannot act on is a stall)' \
  || bad_t 'the refusal does not name which commit is untyped' "rc=$rc out=$out"

grep -q 'dispatching manually cannot bypass this refusal' <<<"$out" && ! grep -q 'cut by hand' <<<"$out" \
  && ok_t 'the refusal names its real boundary instead of advertising a manual path that hits the same exit' \
  || bad_t 'the refusal still sends an operator toward a nonexistent manual bypass' "rc=$rc out=$out"

out=$(run_derive '0.17.8' v0.27.1 nolint 'DIVE-1234: an untyped subject'); rc=$?
grep -q '^DERIVED=v0\.27\.2$' <<<"$out" \
  && ok_t 'NEGATIVE CONTROL: with no lint in the tree the SAME subject cuts a patch — the refusal is bounded by the lint commit, not universal' \
  || bad_t 'the refusal fired on a pre-lint range; this reds every cut until the old subjects age out' "rc=$rc out=$out"

# THE BOUNDING ARM, and it is the one that matters. The negative control above (no lint
# in the tree at all) is passed by an UNBOUNDED refusal too, because an empty epoch
# collapses the enforced range to nothing — so it proves less than it looks. This arm
# puts an untyped subject in the range AND the lint in the tree, which is exactly the
# repo on the morning this ships: 30 of the last 60 merges are untyped and the lint has
# just landed. If the refusal is not bounded to commits after the lint commit, every cut
# reds until those subjects age out of the range.
out=$(run_derive '0.17.8' v0.27.1 lintmid 'feat: after the lint'); rc=$?
[[ $rc -eq 0 ]] && grep -q '^DERIVED=v0\.28\.0$' <<<"$out" \
  && ok_t 'an untyped subject from BEFORE the lint commit does not refuse the cut — the boundary is the lint commit, not the range' \
  || bad_t 'a pre-lint untyped subject refused the cut; this stops publishing entirely until the old subjects age out' "rc=$rc out=$out"

out=$(run_derive '0.17.8' v0.27.1 lint 'feat: after the lint' 'fix: also after'); rc=$?
grep -q '^DERIVED=v0\.28\.0$' <<<"$out" \
  && ok_t 'a fully-typed post-lint range still cuts normally (the refusal is not a blanket stop)' \
  || bad_t 'a clean post-lint range was refused' "rc=$rc out=$out"

echo "-- DIVE-4086: an override may RAISE the derived level and never lower it"
out=$(export RELEASE_LEVEL=patch; run_range '0.17.8' v0.27.1 nolint 'feat: the headline'); rc=$?
[[ $rc -ne 0 ]] && grep -q 'may raise a cut, never lower it' <<<"$out" \
  && ok_t 'RELEASE_LEVEL=patch over a derived MINOR refuses — this is the defect wearing a hand instead of a cron' \
  || bad_t 'a hand-passed patch silently downgraded a feature release' "rc=$rc out=$out"

out=$(export RELEASE_LEVEL=major; run_range '0.17.8' v0.27.1 nolint 'feat: the headline'); rc=$?
grep -q '^DERIVED=v1\.0\.0$' <<<"$out" \
  && ok_t 'RELEASE_LEVEL=major over a derived minor RAISES it (the escape hatch still works)' \
  || bad_t 'an upward override was refused; there is now no way to declare an epoch by hand' "rc=$rc out=$out"

out=$(export RELEASE_LEVEL=auto; run_range '0.17.8' v0.27.1 nolint 'feat: the headline'); rc=$?
grep -q '^DERIVED=v0\.28\.0$' <<<"$out" \
  && ok_t "'auto' (the dispatch default) means the commits decide, so a dispatch and the nightly agree" \
  || bad_t "'auto' was treated as a level and refused" "rc=$rc out=$out"

echo "-- DIVE-4086: the shipped LINT REGEX, run rather than eyeballed"
# Extracted from the shipped file for the same reason every other block here is: a
# hand-written copy of the pattern agrees with every mutant of the real one.
LINT="$ROOT/.github/workflows/pr-title-lint.yml"
LINT_COND=$(grep -E '^ *if \[\[ "\$PR_TITLE" =~ ' "$LINT" | head -1 | sed 's/^ *//; s/ *then$//')
[[ -n "$LINT_COND" ]] || { echo "FATAL: could not extract the title condition from $LINT" >&2; exit 2; }
# `if C; then :; fi` succeeds for a FALSE C too, so the else arm is what makes this a
# test. The first version of this helper omitted it, and every accept arm went red on a
# syntax error rather than on the regex — which is the failure mode a hand-written copy
# of the pattern would never have shown me.
title_ok(){ ( PR_TITLE="$1"; eval "${LINT_COND} then :; else false; fi" ) >/dev/null 2>&1; }

for _t in 'feat: a thing' 'fix(cli): a thing' 'feat(plugin)!: breaking' 'chore: tidy'; do
  title_ok "$_t" && ok_t "the lint ACCEPTS '$_t'" \
    || bad_t "the lint rejects a conventional title, so every PR of this shape is blocked" "title=$_t cond=$LINT_COND"
done
# Acceptance (a) names this exact string: it is the shape 30 of the last 60 merges used.
for _t in 'DIVE-1234: something' 'feat a thing' 'Feat: capitalised' 'feat:no space' 'update the docs'; do
  title_ok "$_t" && bad_t "the lint ACCEPTED a title release-cut cannot read; the cut will refuse later, at the tag" "title=$_t" \
    || ok_t "the lint REJECTS '$_t'"
done

echo "-- the shipped lint and the shipped cut must accept the SAME type list"
# A type the lint admits and the cut rejects reds every later cut; the reverse ships a
# feature as a patch. Comparing the two literals is what stops them drifting apart.
LINT="$ROOT/.github/workflows/pr-title-lint.yml"
_lint_types=$(grep -oE '\(feat\|fix\|[a-z|]+\)' "$LINT" | head -1)
_cut_types=$(grep -oE '\(feat\|fix\|[a-z|]+\)' "$WF" | head -1)
[[ -n "$_lint_types" && "$_lint_types" == "$_cut_types" ]] \
  && ok_t "the lint and the cut share one type list ($_lint_types)" \
  || bad_t 'the PR-title lint and release-cut accept different type sets; one of them will be wrong on every merge' "lint=$_lint_types cut=$_cut_types"

TEMPLATE="$ROOT/.github/pull_request_template.md"
if grep -qE '(^|[|`[:space:]])revert:' "$TEMPLATE"; then
  bad_t 'the PR template advertises revert: even though the blocking lint rejects it' "$(grep -n 'revert:' "$TEMPLATE")"
else
  ok_t 'the PR template does not advertise a title the blocking lint rejects'
fi


printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
