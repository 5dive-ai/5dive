#!/usr/bin/env bash
# DIVE-2286 unit harness for scripts/harness-tree-guard.sh (push-time) and
# its interaction with tests/lib/grading_tree_source_re.sh (the regex
# shared with tests/names_the_tree_contract_unit.sh, this guard's
# whole-corpus CI twin).
#
# Incident under test: four harnesses, three authors, one calendar day
# (2026-07-29), all missing the DIVE-2211 source line -- each caught only
# after a full CI round trip. This guard is meant to catch the same defect
# locally, on just the files a push ADDS, before it ever leaves the machine.
#
# Isolation: builds a throwaway git repo per scenario group under mktemp,
# with a synthetic tests/lib/grading_tree_source_re.sh (real content, copied
# from this checkout so the guard exercises its ACTUAL regex, not a
# reimplementation) and synthetic tests/*.sh harness files. Never touches
# the real repo's git state.
# Run: bash tests/harness_tree_guard_unit.sh  (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/harness-tree-guard.sh"
RE_FILE="$ROOT/tests/lib/grading_tree_source_re.sh"

TMP="$(mktemp -d /tmp/harness-tree-guard-unit.XXXXXX)"
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

mkdir -p tests/lib
cp "$RE_FILE" tests/lib/grading_tree_source_re.sh
git add -A >/dev/null
git commit -q -m "base: carry the real grading_tree_source_re.sh"
c0="$(git rev-parse HEAD)"

GOOD_HARNESS='#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf "grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n" >&2
echo hi'

BAD_HARNESS='#!/usr/bin/env bash
set -uo pipefail
echo hi'

# commit_add_harness NAME CONTENT MSG -> prints the new sha
commit_add_harness() {
  printf '%s\n' "$2" > "tests/$1"
  git add -A >/dev/null
  git commit -q -m "$3"
  git rev-parse HEAD
}

# --- new harness WITHOUT the source line: blocked -----------------------
c1="$(commit_add_harness "no_tree_named_unit.sh" "$BAD_HARNESS" "add a harness missing the DIVE-2211 line")"
out="$(bash "$GUARD" "$c1" "$c0" 2>&1)"; rc=$?
assert_exit "guard: blocks a new harness missing the source line" 1 "$rc"
if [[ "$out" == *"tests/no_tree_named_unit.sh"* && "$out" == *"grading_tree.sh"* ]]; then
  ok_t "guard: names the specific offending file"
else
  bad_t "guard: names the specific offending file" "$out"
fi
if [[ "$out" == *"FIX --"* && "$out" == *'. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"'* ]]; then
  ok_t "guard: prints the paste-able fix snippet"
else
  bad_t "guard: prints the paste-able fix snippet" "$out"
fi
if [[ "$out" == *"2>/dev/null"* ]]; then
  ok_t "guard: warns against the load-bearing 2>/dev/null trap"
else
  bad_t "guard: warns against the load-bearing 2>/dev/null trap" "$out"
fi

git checkout -q "$c0"

# --- new harness WITH the source line: clean ----------------------------
c2="$(commit_add_harness "names_it_fine_unit.sh" "$GOOD_HARNESS" "add a harness carrying the DIVE-2211 line")"
bash "$GUARD" "$c2" "$c0" >/dev/null 2>&1
assert_exit "guard: allows a new harness that sources grading_tree.sh" 0 "$?"

git checkout -q "$c0"

# --- EXISTING harness losing the line: NOT this guard's job (CI-only) ---
# Add a compliant harness first, then a later commit that strips the line
# back out. The guard scopes to --diff-filter=A (added files only), so a
# harness that already existed before this push is out of scope even if the
# push itself removes its source line -- that is deliberately the
# whole-corpus contract test's job, not this push-time guard's.
c3="$(commit_add_harness "existing_unit.sh" "$GOOD_HARNESS" "pre-existing harness, compliant")"
printf '%s\n' "$BAD_HARNESS" > tests/existing_unit.sh
git add -A >/dev/null
git commit -q -m "regress: strip the source line from an existing harness"
c4="$(git rev-parse HEAD)"
bash "$GUARD" "$c4" "$c3" >/dev/null 2>&1
assert_exit "guard: does not fire on a MODIFIED (not added) harness losing the line" 0 "$?"

git checkout -q "$c0"

# --- push touching no tests/*.sh files: clean, and cheap (no ADDED files) -
printf 'unrelated\n' > NOTES.md
git add -A >/dev/null
git commit -q -m "docs-only change"
c5="$(git rev-parse HEAD)"
bash "$GUARD" "$c5" "$c0" >/dev/null 2>&1
assert_exit "guard: no-op on a push that adds no tests/*.sh files" 0 "$?"

# --- negative control: BASE==NEW (nothing pushed) never blocks ----------
bash "$GUARD" "$c1" "$c1" >/dev/null 2>&1
assert_exit "guard: sanity — comparing a commit against itself never blocks" 0 "$?"

# --- fail-open: missing tests/lib/grading_tree_source_re.sh at NEW -------
# Simulates a stale branch predating this guard's shared-regex file: must
# skip cleanly (CI contract test is the net) rather than block every push.
git checkout -q "$c0"
git rm -q tests/lib/grading_tree_source_re.sh
# git rm cleans up now-empty parent dirs; keep tests/ present for the next
# commit_add_harness call to write into.
mkdir -p tests
git commit -q -m "simulate a pre-DIVE-2286 branch (no shared regex file)"
c6="$(git rev-parse HEAD)"
c7="$(commit_add_harness "whatever_unit.sh" "$BAD_HARNESS" "add a harness on a branch predating this guard")"
out="$(bash "$GUARD" "$c7" "$c6" 2>&1)"; rc=$?
assert_exit "guard: fails OPEN when its own shared regex file is unreachable at NEW" 0 "$rc"
if [[ "$out" == *"skipping"* ]]; then
  ok_t "guard: fail-open case says so, rather than silently exiting 0"
else
  bad_t "guard: fail-open case says so, rather than silently exiting 0" "$out"
fi

# --- fail LOUD (not open) when the detection mechanism itself can't tell ---
# DIVE-2286 review (main): "could not determine" must not collapse into
# "nothing to flag" -- that fold IS the DIVE-2274 class this epic exists to
# catch. An unresolvable BASE makes `git diff` itself fail, which must BLOCK
# (exit 1) with its own distinct message, not silently report clear the way
# the old `2>/dev/null || true` collector used to.
git checkout -q "$c0"
out="$(bash "$GUARD" "$c0" "not-a-real-rev-at-all" 2>&1)"; rc=$?
assert_exit "guard: BLOCKS (not silently passes) when git diff itself cannot enumerate added files" 1 "$rc"
if [[ "$out" == *"could not enumerate"* ]]; then
  ok_t "guard: names the could-not-enumerate failure distinctly from a real violation"
else
  bad_t "guard: names the could-not-enumerate failure distinctly from a real violation" "$out"
fi

# Sanity: prove the loud-refusal above has teeth and isn't just always-blocking
# regardless of BASE -- a genuinely valid BASE right next to the bad one above
# must still pass cleanly when the added harness is compliant.
bash "$GUARD" "$c2" "$c0" >/dev/null 2>&1
assert_exit "guard: sanity — a valid BASE right beside the bad one above still passes a compliant add" 0 "$?"

# --- DIVE-3074: the printed remediation is DEPTH-DEPENDENT ---------------
# The canonical `")/lib/grading_tree.sh"` is correct ONLY for a file directly in
# tests/. From tests/meta/ it resolves to tests/meta/lib/grading_tree.sh, which
# cannot exist -- yet it still SATISFIES the text regex. An author who pasted
# exactly what this guard printed got guard GREEN and property ABSENT, with the
# harness printing `grading tree: UNRESOLVED` on every run and nothing saying so.
# Measured on tests/meta/harness-graded-union.sh (DIVE-3017), the first file added
# under tests/meta/ since this guard shipped.

git checkout -q "$c0"

NESTED_GOOD='#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf "grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n" >&2
echo hi'

# A spelling this guard cannot statically judge (no $(dirname ...)): it must be
# ALLOWED, not blocked. Deliberate negative control on the resolution check --
# without it, "blocks the nested case" is satisfied by a check that blocks
# everything it does not recognise.
VAR_PATH_HARNESS='#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/grading_tree.sh" \
  || printf "grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n" >&2
echo hi'

mkdir -p tests/meta
m1="$(commit_add_harness "meta/nested_missing_unit.sh" "$BAD_HARNESS" "add a nested harness with no source line")"
out="$(bash "$GUARD" "$m1" "$c0" 2>&1)"; rc=$?
assert_exit "guard: blocks a new tests/meta/ harness missing the source line" 1 "$rc"
if [[ "$out" == *'. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh"'* ]]; then
  ok_t "guard: prints a ../lib/ remediation for a file one level under tests/"
else
  bad_t "guard: prints a ../lib/ remediation for a file one level under tests/" "$out"
fi
if [[ "$out" != *'"${BASH_SOURCE[0]}")/lib/grading_tree.sh'* ]]; then
  ok_t "guard: does NOT print the depth-0 spelling for a nested file"
else
  bad_t "guard: does NOT print the depth-0 spelling for a nested file" "$out"
fi

git checkout -q "$c0"
mkdir -p tests/a/b
m2="$(commit_add_harness "a/b/deep_missing_unit.sh" "$BAD_HARNESS" "add a two-level-deep harness with no source line")"
out="$(bash "$GUARD" "$m2" "$c0" 2>&1)"
if [[ "$out" == *'. "$(dirname "${BASH_SOURCE[0]}")/../../lib/grading_tree.sh"'* ]]; then
  ok_t "guard: prints ../../lib/ for a file two levels under tests/"
else
  bad_t "guard: prints ../../lib/ for a file two levels under tests/" "$out"
fi

# THE CLASS-CLOSING CASE: the file carries the guard's OWN canonical line, so the
# text regex is satisfied -- and the path reaches nothing. Before DIVE-3074 this
# exited 0.
git checkout -q "$c0"
mkdir -p tests/meta
m3="$(commit_add_harness "meta/nested_unresolvable_unit.sh" "$GOOD_HARNESS" "nested harness carrying the depth-0 line (matches, resolves nowhere)")"
out="$(bash "$GUARD" "$m3" "$c0" 2>&1)"; rc=$?
assert_exit "guard: BLOCKS a nested harness whose source line matches but CANNOT RESOLVE" 1 "$rc"
if [[ "$out" == *"CANNOT RESOLVE"* ]]; then
  ok_t "guard: names the unresolvable-path failure distinctly from a missing line"
else
  bad_t "guard: names the unresolvable-path failure distinctly from a missing line" "$out"
fi

# ...and the corrected spelling passes, so the block above is about resolution
# and not simply about being under tests/meta/.
git checkout -q "$c0"
mkdir -p tests/meta
m4="$(commit_add_harness "meta/nested_ok_unit.sh" "$NESTED_GOOD" "nested harness with the depth-correct line")"
bash "$GUARD" "$m4" "$c0" >/dev/null 2>&1
assert_exit "guard: allows a nested harness whose ../lib/ line actually resolves" 0 "$?"

# Negative control for the resolution check: an unjudgeable spelling is deferred
# to CI, not blocked.
git checkout -q "$c0"
mkdir -p tests/meta
m5="$(commit_add_harness "meta/nested_varpath_unit.sh" "$VAR_PATH_HARNESS" "nested harness sourcing via a computed \$ROOT")"
bash "$GUARD" "$m5" "$c0" >/dev/null 2>&1
assert_exit "guard: does not block a spelling it cannot statically judge (defers to CI)" 0 "$?"

# Regression: depth 0 is unchanged -- the canonical line still passes in tests/.
git checkout -q "$c0"
r0="$(commit_add_harness "still_fine_unit.sh" "$GOOD_HARNESS" "depth-0 harness, canonical line")"
bash "$GUARD" "$r0" "$c0" >/dev/null 2>&1
assert_exit "guard: regression — the canonical line still passes directly in tests/" 0 "$?"

# --- DIVE-4108: a LARGE compliant harness must never be refused -----------
# The guard asked `printf '%s\n' "$content" | grep -qE "$RE"` under `set -o
# pipefail`. grep -q exits the instant it matches; on a blob bigger than the
# pipe can hold, printf is still writing, dies of SIGPIPE (141), pipefail
# promotes 141 to the pipeline's status, and `if !` reads that as NO MATCH --
# so the guard reported the OPPOSITE of what it measured and refused a
# compliant push. Measured 2026-09-08 on DIVE-4052: `5dive push` refused on
# attempts 1 and 2 and passed UNCHANGED on 3; six identical direct runs of the
# guard gave rc 0,0,1,0,1,1.
#
# WHY THE SIZE IS THE ARM. A Linux pipe holds 64 KiB, so under that capacity
# printf hands off its whole output and exits before grep can matter -- every
# scenario above is small, which is exactly why none of them could ever lose
# this race. The blob below is 256 KiB (4x capacity) with the source line at
# the TOP, so the match is immediate and the producer is guaranteed to still
# be blocked on write. N repeats because the outcome was a race, not a
# constant: one green run was never evidence.
git checkout -q "$c0"
BIG_HARNESS_FILE="$TMP/big_harness.sh"
{
  printf '%s\n' "$GOOD_HARNESS"
  # pad past the pipe's 64 KiB capacity; content is irrelevant, volume is the arm
  for _i in $(seq 1 4000); do
    printf '# pad line %04d -- volume is the point: this file must exceed one pipe buffer.\n' "$_i"
  done
} > "$BIG_HARNESS_FILE"
BIG_BYTES=$(wc -c < "$BIG_HARNESS_FILE")
if (( BIG_BYTES >= 65536 )); then
  ok_t "guard/DIVE-4108: the large-blob fixture actually exceeds one 64 KiB pipe buffer ($BIG_BYTES bytes)"
else
  bad_t "guard/DIVE-4108: the large-blob fixture actually exceeds one 64 KiB pipe buffer" "only $BIG_BYTES bytes -- this arm cannot lose the race and proves nothing"
fi

cp "$BIG_HARNESS_FILE" tests/big_compliant_unit.sh
git add -A >/dev/null
git commit -q -m "add a large COMPLIANT harness (>=64 KiB)"
big="$(git rev-parse HEAD)"

BIG_N=20
big_refusals=0
for _r in $(seq 1 "$BIG_N"); do
  bash "$GUARD" "$big" "$c0" >/dev/null 2>&1 || big_refusals=$((big_refusals+1))
done
if (( big_refusals == 0 )); then
  ok_t "guard/DIVE-4108: $BIG_N identical runs over a 256 KiB compliant harness, zero refusals"
else
  bad_t "guard/DIVE-4108: $BIG_N identical runs over a 256 KiB compliant harness, zero refusals" \
        "$big_refusals of $BIG_N runs REFUSED a compliant file -- the SIGPIPE race is back (see DIVE-4108)"
fi

# The size must not have bought the pass by making the guard blind: the same
# 256 KiB shape with the source line REMOVED still has to be refused, every run.
git checkout -q "$c0"
{
  printf '%s\n' "$BAD_HARNESS"
  for _i in $(seq 1 4000); do
    printf '# pad line %04d -- volume is the point: this file must exceed one pipe buffer.\n' "$_i"
  done
} > tests/big_noncompliant_unit.sh
git add -A >/dev/null
git commit -q -m "add a large NON-compliant harness (>=64 KiB)"
bigbad="$(git rev-parse HEAD)"
bigbad_passes=0
for _r in $(seq 1 "$BIG_N"); do
  bash "$GUARD" "$bigbad" "$c0" >/dev/null 2>&1 && bigbad_passes=$((bigbad_passes+1))
done
if (( bigbad_passes == 0 )); then
  ok_t "guard/DIVE-4108: negative control — a 256 KiB harness MISSING the line is refused on all $BIG_N runs"
else
  bad_t "guard/DIVE-4108: negative control — a 256 KiB harness MISSING the line is refused on all $BIG_N runs" \
        "$bigbad_passes of $BIG_N runs let it through -- the fix made the guard blind on large files"
fi

git checkout -q "$c0"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
