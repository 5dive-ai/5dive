#!/usr/bin/env bash
# DIVE-2065 unit harness for scripts/version-bump-guard.sh (push-time).
#
# Incident under test: c97a4f9 bumped FIVE_VERSION to 0.16.3 and rebuilt the
# bundle; a same-day follow-up (2472df2) rebuilt the bundle AGAIN (real
# content change) but its own version-bump step failed silently, so it
# reused 0.16.3 with a different bundle. Nothing caught it — bundle-drift
# only enforces bundle==build(src), not version-is-unique. Fixed after the
# fact by renumbering the follow-up to 0.16.4; this guard stops the next one
# from landing.
#
# DIVE-2453: this harness used to ALSO grade scripts/version-uniqueness-scan.sh,
# the CI-side wider-range twin of the guard below. That script is DELETED, not
# just untested: DIVE-2247 already retired its only caller (bundle-drift.yml's
# uniqueness job) when version assignment moved to tag time — exactly one
# writer, once per cut, so the multi-merge race it scanned for (DIVE-2118) is
# now structurally impossible, the "retire a guard whose class can no longer
# occur" case in this repo's CLAUDE.md. The script itself was left on disk
# with nothing calling it but this harness — a check nothing runs grading a
# script nothing calls. The invariant it tried to hold now lives at the
# tag-time act itself: release-cut.yml refuses to cut a derived version that
# already exists as a tag, or to re-point a published one (DIVE-2118
# assertion, see that workflow's cut-time derivation block).
#
# Isolation: builds a throwaway git repo per scenario group under mktemp, with
# synthetic src/header.sh + 5dive + 5dive.sha256 (fake content — the guard
# only compares FIVE_VERSION strings and raw 5dive.sha256 bytes, it never
# actually runs build.sh or validates a real sha256, so no real bundle is
# needed to exercise it). Never touches the real repo's git state.
# Run: bash tests/version_bump_guard_unit.sh  (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUMP_GUARD="$ROOT/scripts/version-bump-guard.sh"

TMP="$(mktemp -d /tmp/version-bump-guard-unit.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap 'rc=$?; cleanup; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path; cleanup() has no $? dependency of its own so wrapping it is safe.

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

assert_exit() {  # assert_exit "$name" expected_rc actual_rc
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then ok_t "$name"
  else bad_t "$name" "expected exit $expected, got $actual"; fi
}

# --- repo scaffold -----------------------------------------------------
cd "$TMP" || exit 1
git init -q -b main repo
cd repo || exit 1
git config user.email test@example.test
git config user.name "Test Runner"

# commit_release VERSION BUNDLE_VERSION SHA_CONTENT MSG -> prints the new sha
commit_release() {
  mkdir -p src
  printf 'readonly FIVE_VERSION="%s"\n' "$1" > src/header.sh
  printf '#!/usr/bin/env bash\nreadonly FIVE_VERSION="%s"\necho hi\n' "$2" > 5dive
  printf '%s\n' "$3" > 5dive.sha256
  # DIVE-2091: the guard now keys on "did src/ or build.sh change" — the committed
  # 5dive.sha256 it used to compare is generated at tag time and is not in a commit
  # any more. SHA_CONTENT keeps its MEANING ("a different build") and changes its
  # EXPRESSION: it lands in src/, where the real signal now is.
  printf '%s\n' "$3" > src/body.sh
  git add -A >/dev/null
  git commit -q -m "$4"
  git rev-parse HEAD
}

# commit_unrelated MSG -> prints the new sha (touches neither header/bundle/sha)
commit_unrelated() {
  printf '%s\n' "$1" > NOTES.md
  git add -A >/dev/null
  git commit -q -m "$1"
  git rev-parse HEAD
}

# commit_missing_header BUNDLE_VERSION SHA_CONTENT MSG -> src/header.sh does
# not exist at all (DIVE-2071 proof (a): extraction from NEW is impossible).
commit_missing_header() {
  rm -rf src
  printf '#!/usr/bin/env bash\nreadonly FIVE_VERSION="%s"\necho hi\n' "$1" > 5dive
  printf '%s\n' "$2" > 5dive.sha256
  git add -A >/dev/null
  git commit -q -m "$3"
  git rev-parse HEAD
}

# commit_drifted_header VERSION BUNDLE_VERSION SHA_CONTENT MSG -> src/header.sh
# uses a renamed identifier (FIVE_VERSION_XX) so the guards' `FIVE_VERSION=`
# anchor can no longer find it, simulating a rename or a src/ reorg
# (DIVE-2071 proof (b)). The bundle's own anchor is left intact so this
# isolates the header-extraction failure specifically.
commit_drifted_header() {
  mkdir -p src
  printf 'readonly FIVE_VERSION_XX="%s"\n' "$1" > src/header.sh
  printf '#!/usr/bin/env bash\nreadonly FIVE_VERSION="%s"\necho hi\n' "$2" > 5dive
  printf '%s\n' "$3" > 5dive.sha256
  git add -A >/dev/null
  git commit -q -m "$4"
  git rev-parse HEAD
}

c0="$(commit_release 0.1.0 0.1.0 shaA "init 0.1.0")"
# incident shape: bundle rebuilt (new content, new sha) but version NOT bumped
c1="$(commit_release 0.1.0 0.1.0 shaB "follow-up: bundle rebuilt, version bump silently failed")"
# proper fix: bump to a version nobody has used yet
c2="$(commit_release 0.1.1 0.1.1 shaC "proper bump")"

# --- version-bump-guard.sh: push-time, single BASE..NEW comparison -----

# DIVE-2585: the version-COLLISION assertion is RETIRED, so the DIVE-2065
# incident shape is deliberately CLEAR here now. Its predicate ("src/ moved but
# FIVE_VERSION did not") was written for a world where main carried a real
# release version; under DIVE-2247's tag-time assignment main's header is the
# 0.0.0-dev sentinel at EVERY commit, so the second half was true by
# construction and the check blocked every source-changing push to main.
# The property did not disappear, it moved to the publish act: release-cut.yml
# refuses a derived tag that already exists (DIVE-2118), and
# tests/release_cut_bundle_unit.sh asserts main still carries the sentinel.
bash "$BUMP_GUARD" "$c1" "$c0" >/dev/null 2>&1
assert_exit "bump-guard: same-version src-changing range is CLEAR (collision assertion retired to release-cut.yml, DIVE-2585)" 0 "$?"

bash "$BUMP_GUARD" "$c2" "$c1" >/dev/null 2>&1
assert_exit "bump-guard: allows a genuine forward bump" 0 "$?"

# DIVE-2585, THE ARM THAT REDS ON THE PRE-FIX SCRIPT. This is the exact shape of
# every real push to main since DIVE-2247 — sentinel to sentinel, src/ changed —
# reproduced against the sentinel string itself rather than a stand-in version,
# because "0.0.0-dev == 0.0.0-dev" is precisely what made the retired assertion
# fire unconditionally. Measured pre-fix on already-landed main commits
# (785e391 vs its parent): BLOCKED, rc=1.
git checkout -q "$c2"
s0="$(commit_release 0.0.0-dev 0.0.0-dev shaS0 "sentinel main, baseline")"
git checkout -q "$s0"
s1="$(commit_release 0.0.0-dev 0.0.0-dev shaS1 "sentinel main, ordinary source change")"
out="$(bash "$BUMP_GUARD" "$s1" "$s0" 2>&1)"; rc=$?
assert_exit "bump-guard: an ordinary 0.0.0-dev -> 0.0.0-dev src-changing push to main is CLEAR" 0 "$rc"

# The two stale STRINGS are defects in their own right (DIVE-2585), independent
# of the exit code: the remedy told the reader to hand-bump main, which the
# tag-time model forbids, and the override cited a CI job DIVE-2247 deleted
# (bundle-drift.yml carries its headstone). Grade the file, not just its rc — an
# rc-only assertion passes happily with the wrong advice still printed.
# Scoped to NON-COMMENT lines (`^[^#]*`, the idiom the artifact arm above uses).
# The assertion is "must not PRINT this advice", and a bare file-wide grep does
# not say that — the fixed header deliberately QUOTES both retired strings to
# record what they said and why they were wrong, and a file-wide grep reds on
# that documentation. A grep answers "string in file", never "string in the
# scope that emits it".
if grep -qE '^[^#]*Bump FIVE_VERSION in src/header\.sh' "$BUMP_GUARD"; then
  bad_t "bump-guard: must not advise hand-bumping FIVE_VERSION (forbidden since DIVE-2247)" "$(grep -nE '^[^#]*Bump FIVE_VERSION' "$BUMP_GUARD")"
else
  ok_t "bump-guard: does not advise hand-bumping FIVE_VERSION"
fi
if grep -qE '^[^#]*(CI )?version-uniqueness check is the net' "$BUMP_GUARD" "$ROOT/scripts/git-hooks/pre-push"; then
  bad_t "bump-guard/pre-push: must not cite the deleted CI version-uniqueness job as the net" "$(grep -nE '^[^#]*version-uniqueness check is the net' "$BUMP_GUARD" "$ROOT/scripts/git-hooks/pre-push")"
else
  ok_t "bump-guard/pre-push: cites no deleted CI job as its net"
fi

# DIVE-2091: the "committed bundle embeds a version disagreeing with header.sh"
# assertion is GONE, and deliberately so — it is now UNREACHABLE, not relaxed.
# There is no committed bundle to disagree with src/header.sh; the bundle that
# ships is built at tag time FROM that header. The property did not disappear, it
# MOVED: release-cut.yml refuses when v${FIVE_VERSION} != the tag being cut, and
# tests/release_cut_bundle_unit.sh drives that refusal against the shipped
# workflow. Asserting it here would be a check that can never fail.
#
# What IS asserted here instead: the guard must not silently regrow a dependency
# on a committed artifact. If someone re-introduces one, this arm fails and they
# are told where the property actually lives.
if grep -qE '^[^#]*(git show[^|]*5dive\.sha256|_sha256file)' "$BUMP_GUARD"; then
  assert_exit "bump-guard: must NOT read a committed 5dive.sha256 (generated at tag time; see release-cut.yml + release_cut_bundle_unit.sh)" 0 1
else
  assert_exit "bump-guard: reads no committed bundle artifact" 0 0
fi

# no-op push off the clean c2 state: unrelated file only, bundle/version untouched
git checkout -q "$c2"
c4="$(commit_unrelated "docs only, no source/bundle change")"
bash "$BUMP_GUARD" "$c4" "$c2" >/dev/null 2>&1
assert_exit "bump-guard: does not fire when the bundle didn't change" 0 "$?"

# --- negative control: prove the guard's own condition has teeth -------
# A version-bump-guard invocation with BASE==NEW (nothing pushed) must never
# block — this is the guard's own vacuity check, same shape as DIVE-2065's
# own root cause (comparing two things that both didn't move reports MATCH).
bash "$BUMP_GUARD" "$c2" "$c2" >/dev/null 2>&1
assert_exit "bump-guard: BASE==NEW (nothing new) never blocks" 0 "$?"

# --- DIVE-2453: the retired script must stay retired -------------------
# scripts/version-uniqueness-scan.sh does not exist any more; the CI job that
# called it was deleted by DIVE-2247 and the property it checked now lives in
# release-cut.yml's derived-tag-already-exists refusal (DIVE-2118). If this
# fires, someone resurrected the file without restoring a caller or arguing
# why release-cut.yml's guarantee is no longer enough — that decision belongs
# in a ticket, not a silent re-add.
if [[ -e "$ROOT/scripts/version-uniqueness-scan.sh" ]]; then
  bad_t "version-uniqueness-scan.sh must not exist (DIVE-2453 retirement)" "found at $ROOT/scripts/version-uniqueness-scan.sh"
else
  ok_t "version-uniqueness-scan.sh stays retired (DIVE-2453)"
fi

# --- mutation proof: confirm the guard is not vacuously passing --------
# Feed the incident pair through with an intentionally WRONG base (equal to
# NEW) to confirm the block above wasn't a fluke of argument order — this
# must pass clean, proving the earlier block genuinely depended on BASE
# actually differing from NEW's committed content.
bash "$BUMP_GUARD" "$c1" "$c1" >/dev/null 2>&1
assert_exit "bump-guard: sanity — comparing a commit against itself never blocks" 0 "$?"

# --- DIVE-2071: extraction failure at NEW must block loudly, not fail open ---
# Proof (a): NEW is missing src/header.sh outright. Pre-fix this returned
# rc=0 — every content assertion is behind `-n "$new_ver"`, so an empty
# extraction skipped both of them and the guard reported "clear to push".
git checkout -q "$c2"
c6="$(commit_missing_header 0.1.2 shaE "src/header.sh deleted (extraction impossible)")"

out="$(bash "$BUMP_GUARD" "$c6" "$c2" 2>&1)"; rc=$?
assert_exit "bump-guard: blocks when src/header.sh is missing at NEW (was fail-open)" 1 "$rc"
if [[ "$out" == *"could not extract FIVE_VERSION from src/header.sh"* ]]; then
  ok_t "bump-guard: missing-header failure gets its own distinct message"
else
  bad_t "bump-guard: missing-header failure gets its own distinct message" "$out"
fi

# Proof (b): the FIVE_VERSION anchor in src/header.sh has drifted (renamed),
# run against the REAL incident shape (same version, bundle rebuilt with
# different content). Pre-fix this also returned rc=0 — it "silently passes
# the exact bug it exists to catch" once the anchor can't be found, for
# either commit in the pair.
git checkout -q "$c0"
d0="$(commit_drifted_header 0.1.0 0.1.0 shaA "init 0.1.0, but header anchor already renamed")"
git checkout -q "$d0"
d1="$(commit_drifted_header 0.1.0 0.1.0 shaB "bundle rebuilt, version bump silently failed, anchor still renamed")"

out="$(bash "$BUMP_GUARD" "$d1" "$d0" 2>&1)"; rc=$?
assert_exit "bump-guard: blocks the incident even when the FIVE_VERSION anchor drifted (was fail-open)" 1 "$rc"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
