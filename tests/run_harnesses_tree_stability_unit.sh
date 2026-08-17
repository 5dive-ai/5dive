#!/usr/bin/env bash
# TIER: core — the sweep must grade ONE tree, and say so (DIVE-3228).
#
# WHAT FORCED THIS. A 72-harness sweep reported 72/0 while a commit landed in the
# worktree two minutes before it finished. Some harnesses graded the old sha, some
# the new one, and the summary could not say which — an UNATTRIBUTABLE GREEN,
# which is worse than an unattributable red because the red gets investigated and
# the green gets banked. `tests/lib/grading_tree.sh` (DIVE-2211) already makes
# every grading harness NAME its tree; what was missing is that the sweep never
# compared those names to each other.
#
# THE ARM THAT MATTERS IS THE STREAM ARM. The first cut of the check teed STDOUT.
# grading_tree.sh emits with `_5d_grading_tree_line >&2`, so it collected zero
# lines and would have passed forever while asserting nothing — a vacuous control
# shipped on the very ticket about unattributable greens. `stream:` below is that
# arm, and it reads a REAL harness rather than a fixture, so it stays coupled to
# the emitter: move the line back to stdout and this reds.
#
# Run: bash tests/run_harnesses_tree_stability_unit.sh   (no root, no network.)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP=$(mktemp -d /tmp/run-harness-tree.XXXXXX)

PASS=0; FAIL=0
chk() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fi
}

RH=scripts/run-harnesses.sh
[[ -r "$RH" ]] || { echo "skip - $RH not readable"; exit 0; }

# ---- the check is actually wired into the runner ---------------------------
# A helper nobody calls is the bug with extra steps, and this one is invisible
# until a tree moves — so grade its PRESENCE, not just its logic.
chk "wiring: the runner collects grading-tree lines" "1" \
    "$([[ $(grep -c '_gt_capture' "$RH") -ge 3 ]] && echo 1 || echo 0)"
chk "wiring: and exits 7 when they disagree" "1" \
    "$(grep -cE '^\s*exit 7$' "$RH")"
# 6 is DIVE-2728's budget-UNDETERMINED code. Two different "could not be graded"
# causes sharing one exit is the ambiguity this ladder exists to remove.
chk "wiring: 7 and not 6 — 6 is already the budget-UNDETERMINED code" "1" \
    "$([[ $(grep -c 'undetermined == 0 )) || exit 6' "$RH") -ge 1 ]] && echo 1 || echo 0)"

# ---- stream: the line is on STDERR, and the collector must follow it --------
# Reads a REAL harness. This is the arm that catches a collector pointed at the
# wrong stream — the bug this check shipped with in its first cut.
probe_out="$TMP/probe.out"; probe_err="$TMP/probe.err"
bash tests/schema_sync_unit.sh >"$probe_out" 2>"$probe_err"
chk "stream: a real harness emits its grading-tree line on STDERR" "1" \
    "$(grep -c '^grading tree: ' "$probe_err")"
chk "stream: and NOT on stdout (a stdout collector would see nothing)" "0" \
    "$(grep -c '^grading tree: ' "$probe_out")"

# ---- the extraction, over the shape the runner actually greps ---------------
# Same sed the runner uses. Kept in step by the stream arm above plus this one
# reading a REAL emitted line rather than only hand-written ones.
extract() { sed -n 's/^grading tree: .* @ \([0-9a-f]\{7,\}\).*/\1/p' "$1" | sort -u; }

real_line=$(grep -m1 '^grading tree: ' "$probe_err")
printf '%s\n' "$real_line" >"$TMP/real"
chk "extract: pulls a sha out of a REAL grading-tree line" "1" \
    "$(extract "$TMP/real" | grep -c .)"

# One tree, many harnesses — the normal green run.
{ printf 'grading tree: /repo @ abc1234\n'
  printf 'grading tree: /repo @ abc1234 +UNCOMMITTED CHANGES in src/ or tests/\n'
  printf 'grading tree: /repo @ abc1234\n'; } >"$TMP/stable"
chk "stable: one sha across the corpus is ONE distinct tree" "1" \
    "$(extract "$TMP/stable" | grep -c .)"
# The dirty marker must NOT count as movement: a harness writing a scratch file
# inside the repo flips it without the graded code changing at all, and reddening
# on that would bolt a flake generator onto the flake detector.
chk "stable: the +UNCOMMITTED marker does not read as a second tree" "abc1234" \
    "$(extract "$TMP/stable")"

# The failure being fixed: a commit landed mid-corpus.
{ printf 'grading tree: /repo @ 8c2c95c\n'
  printf 'grading tree: /repo @ 143fbe3\n'; } >"$TMP/moved"
chk "moved: two shas are detected as two distinct trees" "2" \
    "$(extract "$TMP/moved" | grep -c .)"

# A non-git export is a legitimate way to run this corpus. It must not red.
{ printf 'grading tree: /repo @ abc1234\n'
  printf 'grading tree: /export @ NOT-A-GIT-TREE (no commit to compare against; no dirtiness claim)\n'
  printf 'grading tree: UNRESOLVED (could not resolve the harness path; no tree named)\n'; } >"$TMP/mixed"
chk "non-git: UNRESOLVED / NOT-A-GIT-TREE are excluded, not counted as a 2nd tree" "1" \
    "$(extract "$TMP/mixed" | grep -c .)"

# ---- END TO END, through the real runner -----------------------------------
# The arms above grade the parts. This drives scripts/run-harnesses.sh itself over
# a throwaway corpus via --corpus-dir, because a check that is correct in pieces
# and unwired in the runner is the failure mode it exists to catch. Positive AND
# negative control: an arm asserting "exit 7 on movement" is worth nothing unless
# another proves the same runner exits 0 when the tree holds still.
E2E="$TMP/corpus"; mkdir -p "$E2E"
_mk() { # <name> <sha>
  { printf '#!/usr/bin/env bash\n'
    printf '# TIER: core — 0.1s measured (fixture).\n'
    printf "printf 'grading tree: /repo @ %s\\n' >&2\n" "$2"
    printf 'echo "1 passed, 0 failed"\n'; } >"$E2E/fake_$1_unit.sh"
}
_mk a abc1234; _mk b def5678
( bash scripts/run-harnesses.sh --tier=core --corpus-dir="$E2E" --no-calibrate --cross-runner=off ) >"$TMP/e2e.log" 2>&1
chk "e2e: a tree that MOVES mid-run exits 7 through the real runner" "7" "$?"
chk "e2e: and says so loudly rather than reporting a summary" "1" \
    "$(grep -c 'THE TREE MOVED MID-RUN' "$TMP/e2e.log")"

_mk b abc1234   # negative control: both harnesses now name the same tree
( bash scripts/run-harnesses.sh --tier=core --corpus-dir="$E2E" --no-calibrate --cross-runner=off ) >"$TMP/e2e2.log" 2>&1
chk "e2e: liveness — a STABLE tree still exits 0 (the check is not always-on)" "0" "$?"
chk "e2e: and prints no movement claim" "0" \
    "$(grep -c 'THE TREE MOVED MID-RUN' "$TMP/e2e2.log")"

printf -- '-----\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
