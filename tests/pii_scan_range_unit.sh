#!/usr/bin/env bash
# DIVE-2267 unit harness for scripts/pii-scan-range.sh.
#
# Incident under test: pii-guard.yml's PUSH path ran `git log -1 --format='%B' |
# pii-scan.sh` and nothing else, so on a direct push to main the guard read the
# COMMIT MESSAGE and no content at all. A denylisted identifier in an added line
# landed on public main with a green pii-guard. The mitigation that does scan
# content, scripts/git-hooks/pre-push, is a git hook and therefore per-checkout:
# git will not run a repo-tracked hook automatically (DIVE-2255), so a FRESH
# CLONE -- the route admin and bot pushes actually take -- had no content scan on
# either side. Measured instance: main's 0.17.2 hand-assign from /tmp.
#
# The load-bearing assertions here are the OLD/NEW pairs. Each one first shows
# the retired push-path command reporting CLEAN on the content, then shows
# pii-scan-range.sh catching it. Without the old half these tests would only
# prove the new script works, not that it closes a gap that was really open.
#
# Second thing under test, from DIVE-2264: every path that cannot scan must exit
# NON-zero. That ticket's defect was three distinct unusable-input conditions
# collapsing into one silent `exit 0`, in a workflow wrapping a script that
# itself failed closed. So "could not look" is asserted to be distinguishable
# from "clean" here, per input class.
#
# Isolation: a throwaway git repo per scenario under mktemp, and a synthetic
# denylist built from a RESERVED FAKE telegram id (1234567890, per the repo's
# test-fixture rule) hashed at runtime -- no real identifier is used, and no
# hash is hardcoded. Never touches the real repo's git state or the real
# denylist.
# Run: bash tests/pii_scan_range_unit.sh  (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE the absence of `2>/dev/null` -- the obvious hardening would also swallow
# the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RANGE_SCAN="$ROOT/scripts/pii-scan-range.sh"
PII_SCAN_SH="$ROOT/scripts/pii-scan.sh"

TMP="$(mktemp -d /tmp/pii-scan-range-unit.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

assert_exit() {  # assert_exit "$name" expected_rc actual_rc [context]
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then ok_t "$name"
  else bad_t "$name" "expected exit $expected, got $actual. ${4:-}"; fi
}

assert_contains() {  # assert_contains "$name" "$haystack" "$needle"
  local name="$1" hay="$2" needle="$3"
  if [[ "$hay" == *"$needle"* ]]; then ok_t "$name"
  else bad_t "$name" "output did not contain '$needle'. Got: $hay"; fi
}

# --- synthetic denylist ------------------------------------------------
# A RESERVED FAKE id, never a real one. pii-scan.sh treats any digit run of
# 7-15 as a candidate, so a 10-digit fake exercises the same code path a real
# telegram id would.
FAKE_ID="1234567890"
DENY="$TMP/denylist.txt"
{
  printf '# synthetic denylist for tests/pii_scan_range_unit.sh\n'
  printf '%s\n' "$(printf '%s' "$FAKE_ID" | sha256sum | cut -d' ' -f1)"
} > "$DENY"
export PII_DENYLIST="$DENY"

# Sanity floor: if the scanner does not flag the fake id through this denylist,
# every "caught it" assertion below would pass vacuously for the wrong reason.
printf 'contact %s please\n' "$FAKE_ID" | bash "$PII_SCAN_SH" >/dev/null 2>&1
assert_exit "floor: pii-scan.sh flags the synthetic fake id (else every catch below is vacuous)" 1 "$?"
printf 'nothing to see here\n' | bash "$PII_SCAN_SH" >/dev/null 2>&1
assert_exit "floor: pii-scan.sh passes clean text through the synthetic denylist" 0 "$?"

# --- repo scaffold -----------------------------------------------------
new_repo() {  # new_repo <name> -> echoes path, cd's into it
  local d="$TMP/$1"
  mkdir -p "$d"; cd "$d" || exit 1
  git init -q .
  git config user.email "test@example.com"
  git config user.name "test"
  git commit -q --allow-empty -m "root commit"
  printf '%s' "$d"
}

# The retired push-path command, verbatim in shape: head commit MESSAGE only.
old_push_path_rc() {
  git log -1 --format='%B' | bash "$PII_SCAN_SH" >/dev/null 2>&1
  printf '%s' "$?"
}

# ======================================================================
# 1. THE INCIDENT: denylisted id in an ADDED LINE, clean commit message.
# ======================================================================
new_repo incident >/dev/null
base="$(git rev-parse HEAD)"
printf 'telegram_id = %s\n' "$FAKE_ID" > leaked.txt
git add leaked.txt
git commit -q -m "chore: add a config file"   # message is CLEAN
head="$(git rev-parse HEAD)"

assert_exit "INCIDENT/old: the retired push path reports CLEAN on a leak in an added line" \
  0 "$(old_push_path_rc)"
out="$(bash "$RANGE_SCAN" "$base" "$head" 2>&1)"; rc=$?
assert_exit "INCIDENT/new: pii-scan-range.sh CATCHES the leak the old path missed" 1 "$rc" "$out"
assert_contains "INCIDENT/new: names the added-lines scan as the source of the hit" \
  "$out" "added lines in"

# ======================================================================
# 2. Multi-commit push, leak in a MIDDLE commit's message.
#    `git log -1` only ever read the tip.
# ======================================================================
new_repo midmsg >/dev/null
base="$(git rev-parse HEAD)"
git commit -q --allow-empty -m "wip: ping $FAKE_ID about this"   # middle commit
git commit -q --allow-empty -m "chore: tidy up"                  # clean tip
head="$(git rev-parse HEAD)"

assert_exit "MIDDLE-MSG/old: the retired push path reports CLEAN (it read only the tip message)" \
  0 "$(old_push_path_rc)"
out="$(bash "$RANGE_SCAN" "$base" "$head" 2>&1)"; rc=$?
assert_exit "MIDDLE-MSG/new: caught across the whole range" 1 "$rc" "$out"
assert_contains "MIDDLE-MSG/new: names the commit-message scan as the source" \
  "$out" "commit messages in"

# ======================================================================
# 3. UNUSABLE ANCHORS (DIVE-2264's three collapsed conditions).
#    Each must NARROW and still scan -- never a silent pass.
# ======================================================================
new_repo anchors >/dev/null
printf 'id: %s\n' "$FAKE_ID" > leak2.txt
git add leak2.txt
git commit -q -m "chore: harmless-looking commit"
head="$(git rev-parse HEAD)"
ZERO="0000000000000000000000000000000000000000"
ABSENT="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

for label in empty zero absent; do
  case "$label" in
    empty)  arg="" ;;
    zero)   arg="$ZERO" ;;
    absent) arg="$ABSENT" ;;
  esac
  out="$(bash "$RANGE_SCAN" "$arg" "$head" 2>&1)"; rc=$?
  assert_exit "ANCHOR/$label: still CATCHES the leak instead of skipping" 1 "$rc" "$out"
  assert_contains "ANCHOR/$label: says NARROWED rather than reporting a full-range pass" \
    "$out" "NARROWED"
done

# The narrowed path must not launder itself into an all-clear when it IS clean:
# it has to keep saying the range was narrowed.
new_repo anchors_clean >/dev/null
printf 'nothing here\n' > fine.txt
git add fine.txt
git commit -q -m "chore: clean commit"
out="$(bash "$RANGE_SCAN" "" "$(git rev-parse HEAD)" 2>&1)"; rc=$?
assert_exit "ANCHOR/clean: a narrowed CLEAN scan still exits 0" 0 "$rc" "$out"
assert_contains "ANCHOR/clean: a narrowed pass is labelled NARROWED, not a full-range all-clear" \
  "$out" "NARROWED"

# ======================================================================
# 4. NOTHING SCANNABLE -> UNDETERMINED (exit 2), the anti-fail-open case.
#    Root commit, no parent, no usable base: there is no content to diff.
#    The retired code's answer to this shape was `exit 0`.
# ======================================================================
new_repo rootonly >/dev/null
out="$(bash "$RANGE_SCAN" "" "$(git rev-parse HEAD)" 2>&1)"; rc=$?
assert_exit "UNDETERMINED/no-parent: exits 2, NOT 0, when no content can be scanned" 2 "$rc" "$out"
assert_contains "UNDETERMINED/no-parent: states plainly that this is not a pass" \
  "$out" "NOT a pass"

# A head ref that does not resolve is also not a pass.
out="$(bash "$RANGE_SCAN" "" "$ABSENT" 2>&1)"; rc=$?
assert_exit "UNDETERMINED/bad-head: unresolvable head ref exits 2, not 0" 2 "$rc" "$out"

# ======================================================================
# 5. A SCANNER THAT COULD NOT LOOK must not be reported as clean.
#    This is the exact asymmetry DIVE-2264 named: pii-scan.sh exits 2 on a
#    missing denylist, and the caller must propagate that rather than treating
#    every non-zero as "found" or, worse, only checking for 1.
# ======================================================================
new_repo scannerfail >/dev/null
base="$(git rev-parse HEAD)"
printf 'plain content\n' > f.txt
git add f.txt
git commit -q -m "chore: clean"
head="$(git rev-parse HEAD)"

out="$(PII_DENYLIST="$TMP/does-not-exist.txt" bash "$RANGE_SCAN" "$base" "$head" 2>&1)"; rc=$?
assert_exit "SCANNER-FAIL/missing-denylist: exits 2 rather than reporting clean" 2 "$rc" "$out"
assert_contains "SCANNER-FAIL/missing-denylist: says UNDETERMINED" "$out" "UNDETERMINED"

out="$(PII_SCAN="$TMP/no-such-scanner.sh" bash "$RANGE_SCAN" "$base" "$head" 2>&1)"; rc=$?
assert_exit "SCANNER-FAIL/absent-scanner: exits 2 rather than reporting clean" 2 "$rc" "$out"

# ======================================================================
# 6. NO FALSE POSITIVES on the shapes that broke naive implementations.
# ======================================================================
new_repo clean >/dev/null
base="$(git rev-parse HEAD)"
printf 'hello\nworld\n' > ok.txt
git add ok.txt
git commit -q -m "chore: add a clean file"
out="$(bash "$RANGE_SCAN" "$base" "$(git rev-parse HEAD)" 2>&1)"; rc=$?
assert_exit "CLEAN: a clean range exits 0" 0 "$rc" "$out"

# A PURE DELETION has no added lines, so `grep -E '^\+'` exits 1. With pipefail
# set, letting grep's status stand as the verdict would turn every deletion-only
# push red -- a guard that fails on correct input gets switched off.
new_repo deletion >/dev/null
printf 'to be removed\n' > gone.txt
git add gone.txt
git commit -q -m "chore: add"
base="$(git rev-parse HEAD)"
git rm -q gone.txt
git commit -q -m "chore: remove"
out="$(bash "$RANGE_SCAN" "$base" "$(git rev-parse HEAD)" 2>&1)"; rc=$?
assert_exit "CLEAN/pure-deletion: no added lines is an EMPTY scan, not a failure" 0 "$rc" "$out"

# An empty range (base == head) is clean, not an error.
out="$(bash "$RANGE_SCAN" "$base" "$base" 2>&1)"; rc=$?
assert_exit "CLEAN/empty-range: base == head exits 0" 0 "$rc" "$out"

# A leak that is REMOVED rather than added must not trip the gate: the guard
# scans added lines, and a deletion of a bad line is the fix, not the offence.
new_repo removal >/dev/null
printf 'id: %s\n' "$FAKE_ID" > bad.txt
git add bad.txt
git commit -q -m "chore: add"
base="$(git rev-parse HEAD)"
git rm -q bad.txt
git commit -q -m "chore: remove the bad file"
out="$(bash "$RANGE_SCAN" "$base" "$(git rev-parse HEAD)" 2>&1)"; rc=$?
assert_exit "CLEAN/leak-removal: deleting a denylisted line is not itself a hit" 0 "$rc" "$out"

# ======================================================================
# 7. Usage floor.
# ======================================================================
out="$(bash "$RANGE_SCAN" 2>&1)"; rc=$?
assert_exit "USAGE: no args exits 2" 2 "$rc" "$out"
out="$(bash "$RANGE_SCAN" onlyone 2>&1)"; rc=$?
assert_exit "USAGE: one arg exits 2" 2 "$rc" "$out"

cd "$ROOT" || exit 1
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
