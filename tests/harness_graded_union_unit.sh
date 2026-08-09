#!/usr/bin/env bash
# DIVE-3017 — grade tests/meta/harness-graded-union.sh, the check that asserts a
# named harness was actually GRADED in CI rather than merely selected.
#
# WHY THIS HARNESS EXISTS AT ALL. The script it grades was written because an
# INSPECTING check (does the job declare a bun step?) passed on a job that was red.
# A check that exists to catch succeeding-in-appearance is exactly the thing that
# must not itself succeed in appearance, so every discriminating case gets an arm:
# the three exits of acp_stdio_unit.sh that a status-only reader cannot separate
# (PASS 4337ms rc=0, PARTIAL 37ms rc=0, FAIL 64ms rc=1), plus the fail-closed cases
# where the report never arrives.
set -euo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

SUT=tests/meta/harness-graded-union.sh
WORK=$(mktemp -d)
FAILED=0
CHECKS=0
ok()   { CHECKS=$((CHECKS+1)); printf 'ok   - %s\n' "$1"; }
bad()  { CHECKS=$((CHECKS+1)); FAILED=$((FAILED+1)); printf 'FAIL - %s\n' "$1"; }
want() { if [[ "$1" == "true" ]]; then ok "$2"; else bad "$2"; fi; }

# report <file> <rows...>  — each row "ms rc path"
report() {
  local f="$1"; shift
  printf '# run-harnesses report\n# tier=full\n# label=pristine\n# harnesses=3\n' > "$f"
  local r
  for r in "$@"; do
    # shellcheck disable=SC2086
    set -- $r; printf '%s\t%s\t%s\n' "$1" "$2" "$3"
  done >> "$f"
}
run() { bash "$SUT" --harness=acp_stdio_unit.sh --min-ms=1000 "$@" >"$WORK/out" 2>"$WORK/err"; }

# --- the three exits a status-only reader cannot separate -----------------------
report "$WORK/pass.txt" "4337 0 tests/acp_stdio_unit.sh" "12 0 tests/other_unit.sh"
run "$WORK/pass.txt" && rc=0 || rc=$?
want "$([[ ${rc:-1} -eq 0 ]] && echo true)" "a graded run (rc=0, 4337ms) PASSES"

report "$WORK/partial.txt" "37 0 tests/acp_stdio_unit.sh"
run "$WORK/partial.txt" && rc=0 || rc=$?
want "$([[ ${rc:-0} -eq 1 ]] && echo true)" \
  "ACP_ALLOW_SKIP's PARTIAL (rc=0 in 37ms) FAILS — the case rc alone cannot see"
want "$(grep -q 'under the 1000ms floor' "$WORK/err" && echo true)" \
  "  ...and says WHY: the duration floor, not a generic mismatch"

report "$WORK/fastfail.txt" "64 1 tests/acp_stdio_unit.sh"
run "$WORK/fastfail.txt" && rc=0 || rc=$?
want "$([[ ${rc:-0} -eq 1 ]] && echo true)" \
  "a fast FAILURE (rc=1 in 64ms) FAILS — a duration bar alone is satisfied by this"
want "$(grep -q 'rc=1' "$WORK/err" && echo true)" \
  "  ...attributed to the exit code, not to the floor (main's 64ms/264ms rc=1 reads as 'fast')"

# A slow failure and a fast pass are the two off-diagonal cases; both must red, or
# the check is really only asserting one column.
report "$WORK/slowfail.txt" "9000 1 tests/acp_stdio_unit.sh"
run "$WORK/slowfail.txt" && rc=0 || rc=$?
want "$([[ ${rc:-0} -eq 1 ]] && echo true)" "a SLOW failure (rc=1, 9000ms) still FAILS"

# --- sharding: the union carries the row, most shards legitimately do not --------
report "$WORK/s1.txt" "12 0 tests/a_unit.sh"
report "$WORK/s2.txt" "4337 0 tests/acp_stdio_unit.sh"
report "$WORK/s3.txt" "9 0 tests/b_unit.sh"
run "$WORK/s1.txt" "$WORK/s2.txt" "$WORK/s3.txt" && rc=0 || rc=$?
want "$([[ ${rc:-1} -eq 0 ]] && echo true)" \
  "3 shards, the row in only ONE of them: PASSES on the union"

run "$WORK/s1.txt" "$WORK/s3.txt" && rc=0 || rc=$?
want "$([[ ${rc:-0} -eq 1 ]] && echo true)" \
  "the harness in NO shard FAILS — a shard split that stops selecting it is not a pass"
want "$(grep -q 'appears in NONE' "$WORK/err" && echo true)" \
  "  ...named as absence, so it cannot be read as a passing corpus"

# One clean shard must not cover for a dirty one.
report "$WORK/dirty.txt" "37 0 tests/acp_stdio_unit.sh"
run "$WORK/s2.txt" "$WORK/dirty.txt" && rc=0 || rc=$?
want "$([[ ${rc:-0} -eq 1 ]] && echo true)" \
  "a clean row does NOT excuse a skipped row in a sibling report"

# --- fails closed ---------------------------------------------------------------
run "$WORK/nope.txt" && rc=0 || rc=$?
want "$([[ ${rc:-0} -eq 1 ]] && echo true)" "an ABSENT report FAILS (a died lane cannot shrink the union)"

printf 'not a report\n1\t0\ttests/acp_stdio_unit.sh\n' > "$WORK/headerless.txt"
run "$WORK/headerless.txt" && rc=0 || rc=$?
want "$([[ ${rc:-0} -eq 1 ]] && echo true)" \
  "a HEADERLESS report FAILS — unparseable is not an empty corpus"

# The row is present and clean, but the file is unparseable: the header check must
# win, or a truncated report could be read for whatever rows survived in it.
want "$(grep -q 'no run-harnesses header' "$WORK/err" && echo true)" \
  "  ...refused on the header, not on the rows it happened to contain"

# --- usage ----------------------------------------------------------------------
bash "$SUT" --harness=x.sh >/dev/null 2>&1 && rc=0 || rc=$?
want "$([[ ${rc:-0} -eq 2 ]] && echo true)" "missing --min-ms / reports exits 2 (usage), not 0 or 1"
bash "$SUT" --harness=x.sh --min-ms=abc "$WORK/pass.txt" >/dev/null 2>&1 && rc=0 || rc=$?
want "$([[ ${rc:-0} -eq 2 ]] && echo true)" "a non-integer --min-ms exits 2 rather than comparing garbage"

if [[ $FAILED -ne 0 ]]; then printf 'FAILED %d of %d checks\n' "$FAILED" "$CHECKS"; exit 1; fi
printf 'PASS - %d checks\n' "$CHECKS"
