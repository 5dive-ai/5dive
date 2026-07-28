#!/usr/bin/env bash
# DIVE-2065 unit harness for scripts/version-bump-guard.sh (push-time) and
# scripts/version-uniqueness-scan.sh (CI-side, wider-range twin).
#
# Incident under test: c97a4f9 bumped FIVE_VERSION to 0.16.3 and rebuilt the
# bundle; a same-day follow-up (2472df2) rebuilt the bundle AGAIN (real
# content change) but its own version-bump step failed silently, so it
# reused 0.16.3 with a different bundle. Nothing caught it — bundle-drift
# only enforces bundle==build(src), not version-is-unique. Fixed after the
# fact by renumbering the follow-up to 0.16.4; these guards stop the next
# one from landing.
#
# Isolation: builds a throwaway git repo per scenario group under mktemp, with
# synthetic src/header.sh + 5dive + 5dive.sha256 (fake content — the guards
# only compare FIVE_VERSION strings and raw 5dive.sha256 bytes, they never
# actually run build.sh or validate a real sha256, so no real bundle is
# needed to exercise them). Never touches the real repo's git state.
# Run: bash tests/version_bump_guard_unit.sh  (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUMP_GUARD="$ROOT/scripts/version-bump-guard.sh"
UNIQ_SCAN="$ROOT/scripts/version-uniqueness-scan.sh"

TMP="$(mktemp -d /tmp/version-bump-guard-unit.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

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

bash "$BUMP_GUARD" "$c1" "$c0" >/dev/null 2>&1
assert_exit "bump-guard: blocks the incident shape (bundle changed, version reused)" 1 "$?"

bash "$BUMP_GUARD" "$c2" "$c1" >/dev/null 2>&1
assert_exit "bump-guard: allows a genuine forward bump" 0 "$?"

# header/bundle mismatch: version bumped in header.sh but bundle never rebuilt
c3="$(commit_release 0.1.2 0.1.1 shaD "header bumped, bundle NOT rebuilt")"
bash "$BUMP_GUARD" "$c3" "$c2" >/dev/null 2>&1
assert_exit "bump-guard: blocks a bundle whose embedded version doesn't match header.sh" 1 "$?"

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

# --- version-uniqueness-scan.sh: CI-side, wider-range twin -------------

bash "$UNIQ_SCAN" "$c1" "$c0" >/dev/null 2>&1
assert_exit "uniqueness-scan: blocks the incident shape over its own delta" 1 "$?"

bash "$UNIQ_SCAN" "$c2" "$c1" >/dev/null 2>&1
assert_exit "uniqueness-scan: a genuine forward bump is clean" 0 "$?"

# Wider delta spanning the incident AND its fix (c0..c2, i.e. c1 is included
# as a NEW commit relative to c0): must still catch c1's collision. This is
# the case a real CI job hits when a push lands more than one commit at once.
bash "$UNIQ_SCAN" "$c2" "$c0" >/dev/null 2>&1
assert_exit "uniqueness-scan: catches the collision even inside a wider multi-commit delta" 1 "$?"

# Re-landing IDENTICAL content under a version already on BASE must not fire
# (e.g. a rebase/cherry-pick replays the same release commit content).
git checkout -q "$c2"
c5="$(commit_unrelated "unrelated, still on top of the clean 0.1.1 state")"
bash "$UNIQ_SCAN" "$c5" "$c2" >/dev/null 2>&1
assert_exit "uniqueness-scan: does not fire on a delta that never touches header.sh/5dive.sha256" 0 "$?"

# --- mutation proof: confirm the guards are not vacuously passing ------
# Feed the incident pair through with an intentionally WRONG base (equal to
# NEW) to confirm the block above wasn't a fluke of argument order — this
# must pass clean, proving the earlier block genuinely depended on BASE
# actually differing from NEW's committed content.
bash "$BUMP_GUARD" "$c1" "$c1" >/dev/null 2>&1
assert_exit "bump-guard: sanity — comparing a commit against itself never blocks" 0 "$?"
bash "$UNIQ_SCAN" "$c1" "$c1" >/dev/null 2>&1
assert_exit "uniqueness-scan: sanity — comparing a commit against itself never blocks" 0 "$?"

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

out="$(bash "$UNIQ_SCAN" "$c6" "$c2" 2>&1)"; rc=$?
assert_exit "uniqueness-scan: blocks when src/header.sh is missing at NEW (was fail-open)" 1 "$rc"

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

out="$(bash "$UNIQ_SCAN" "$d1" "$d0" 2>&1)"; rc=$?
assert_exit "uniqueness-scan: blocks the incident even when the FIVE_VERSION anchor drifted (was fail-open)" 1 "$rc"

# --- DIVE-2071: name the actual colliding commit; do not always blame $BASE --
# Genuine intra-range collision: BOTH claims of the version are introduced by
# this range itself, with no instance on BASE at all. The pre-fix message
# unconditionally said "already used on $BASE", which is wrong here — the
# prior claim is another NEW commit, not history reachable from BASE.
git checkout -q "$c2"
e0="$(commit_release 0.5.0 0.5.0 shaX "unrelated baseline, 0.5.0")"
e1="$(commit_release 0.6.0 0.6.0 shaY "first claim of 0.6.0, introduced by this range")"
e2="$(commit_release 0.6.0 0.6.0 shaZ "second claim of 0.6.0, different bundle, same range")"

out="$(bash "$UNIQ_SCAN" "$e2" "$e0" 2>&1)"; rc=$?
assert_exit "uniqueness-scan: catches a genuine intra-range collision" 1 "$rc"
if [[ "$out" == *"earlier in this range"* && "$out" == *"$e1"* ]]; then
  ok_t "uniqueness-scan: intra-range collision names the earlier NEW commit"
else
  bad_t "uniqueness-scan: intra-range collision names the earlier NEW commit" "$out"
fi
if [[ "$out" != *"already used on $e0"* ]]; then
  ok_t "uniqueness-scan: intra-range collision does not misattribute the prior claim to \$BASE"
else
  bad_t "uniqueness-scan: intra-range collision does not misattribute the prior claim to \$BASE" "$out"
fi

# Control: when the prior claim genuinely lives further back in BASE's own
# history than BASE's tip (a docs-only commit sits on top, touching neither
# file), the message must name the ORIGINAL claiming commit, not just repeat
# the literal $BASE argument.
git checkout -q "$c0"
g_base_tip="$(commit_unrelated "docs-only commit on top of 0.1.0, BASE tip")"
git checkout -q "$g_base_tip"
g1="$(commit_release 0.1.0 0.1.0 shaB "reuse 0.1.0 with a different bundle")"

out="$(bash "$UNIQ_SCAN" "$g1" "$g_base_tip" 2>&1)"; rc=$?
assert_exit "uniqueness-scan: catches a collision whose origin predates BASE's own tip" 1 "$rc"
if [[ "$out" == *"already used on $g_base_tip"* && "$out" == *"$c0"* ]]; then
  ok_t "uniqueness-scan: names the actual historical commit, not just the BASE argument"
else
  bad_t "uniqueness-scan: names the actual historical commit, not just the BASE argument" "$out"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
