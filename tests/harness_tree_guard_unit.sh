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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
