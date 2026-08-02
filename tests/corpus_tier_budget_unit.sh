#!/usr/bin/env bash
# DIVE-2525 isolated unit harness for the two halves of the corpus wall-clock
# budget: the tier resolver (tests/lib/tier.sh) and the budgeted runner
# (scripts/run-harnesses.sh).
#
# WHY THIS FILE IS ITSELF SMALL AND FAST, and says so. It is a harness added by the
# row whose whole subject is that harnesses are added faster than they are retired.
# The honest version of that is not to skip the coverage — it is to pay the budget
# it enforces. Throwaway corpus of three one-line harnesses, no sleeps longer than
# the assertion needs, and every arm below is one this mechanism can actually get
# wrong.
#
# THE ARMS, and the mutation each one would catch:
#   1-3   default is core; an explicit `# TIER: core` is legal; a marker below the
#         header window does not demote. (Flipping the default to nightly would
#         empty the PR path and nothing else here would notice.)
#   4-5   a nightly demotion with no reason REFUSES (exit 3), and a `# TIER:` line
#         naming an unknown tier REFUSES. This is the reverse gear: a demotion that
#         costs nothing to write is a second budget nobody watches.
#   6-8   tier_list partitions core/nightly and `full` is their union — the property
#         that makes "the nightly sweep still runs everything" true rather than
#         asserted. And a corpus containing ONE unclassifiable file makes the whole
#         listing refuse, rather than silently returning the subset it understood.
#   9-12  the runner: over budget exits 4 and names the slowest; a FAILING harness
#         exits 1 even when also over budget (the failure is what you fix first);
#         an empty selection is exit 1, never a green run over nothing; the report
#         carries the wall-clock header the nightly summary reads.
#  13-14  the over-budget message actually names a remedy and the slowest file —
#         a budget that reds without saying what to retire is a warning with a
#         worse exit code (feedback: grade the REMEDY half, not only the predicate).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

TIER_LIB="tests/lib/tier.sh"
RUNNER="scripts/run-harnesses.sh"
TMP="$(mktemp -d /tmp/corpus-tier-budget.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
want() { # want <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

# shellcheck source=tests/lib/tier.sh
. "$TIER_LIB"

mk() { printf '%s\n' "$2" > "$TMP/$1"; }

# ---------------------------------------------------------------- 1-3 resolution
mk plain.sh '#!/usr/bin/env bash
echo plain'
want "default tier is core" "core" "$(tier_of "$TMP/plain.sh")"

mk explicit_core.sh '#!/usr/bin/env bash
# TIER: core
echo core'
want "an explicit core marker is legal" "core" "$(tier_of "$TMP/explicit_core.sh")"

# A marker outside the 40-line header window must not demote. The window is what
# stops a string in a fixture, an assertion or a heredoc from moving a harness out
# of the PR path silently.
{ printf '#!/usr/bin/env bash\n'; for i in $(seq 45); do printf '# filler %s\n' "$i"; done
  printf '# TIER: nightly — far below the header window\n'; printf 'echo late\n'; } > "$TMP/late_marker.sh"
want "a marker below the header window does not demote" "core" "$(tier_of "$TMP/late_marker.sh")"

# ---------------------------------------------------------------- 4-5 refusals
mk bare_nightly.sh '#!/usr/bin/env bash
# TIER: nightly
echo bare'
out="$(tier_of "$TMP/bare_nightly.sh" 2>&1)"; rc=$?
if (( rc == 3 )) && [[ "$out" == *"no reason"* ]]; then
  ok "an unjustified demotion REFUSES (exit 3)"
else
  bad "an unjustified demotion REFUSES (exit 3)" "rc=$rc out=$out"
fi

mk bogus_tier.sh '#!/usr/bin/env bash
# TIER: weekly — only on Tuesdays
echo bogus'
out="$(tier_of "$TMP/bogus_tier.sh" 2>&1)"; rc=$?
if (( rc == 3 )) && [[ "$out" == *"unknown tier"* ]]; then
  ok "an unknown tier REFUSES rather than defaulting either way"
else
  bad "an unknown tier REFUSES rather than defaulting either way" "rc=$rc out=$out"
fi

# ---------------------------------------------------------------- 6-8 selection
rm -f "$TMP"/*.sh
mk a_core.sh '#!/usr/bin/env bash
exit 0'
mk b_core.sh '#!/usr/bin/env bash
exit 0'
mk c_night.sh '#!/usr/bin/env bash
# TIER: nightly — 40s of container setup, cannot fit the PR core
exit 0'
want "core selects only the core harnesses" \
  "a_core.sh b_core.sh" "$(tier_list core "$TMP" | xargs -n1 basename | paste -sd' ' -)"
want "nightly selects only the demoted harnesses" \
  "c_night.sh" "$(tier_list nightly "$TMP" | xargs -n1 basename | paste -sd' ' -)"
want "full is the union, so the nightly sweep still runs everything" \
  "a_core.sh b_core.sh c_night.sh" "$(tier_list full "$TMP" | xargs -n1 basename | paste -sd' ' -)"

mk d_bogus.sh '#!/usr/bin/env bash
# TIER: fortnightly — nope
exit 0'
tier_list core "$TMP" >/dev/null 2>&1; rc=$?
want "one unclassifiable file makes the WHOLE listing refuse" "3" "$rc"
rm -f "$TMP/d_bogus.sh"

# ---------------------------------------------------------------- 9-14 the runner
# Two cheap harnesses and one that burns a second, so a 1-second budget is
# genuinely exceeded by measured time rather than by a constant in the assertion.
rm -f "$TMP"/*.sh
mk fast_one.sh '#!/usr/bin/env bash
exit 0'
mk slow_one.sh '#!/usr/bin/env bash
sleep 1.2
exit 0'

run() { OUT="$(bash "$RUNNER" --corpus-dir="$TMP" "$@" 2>&1)"; RC=$?; }

run --tier=core --budget=1 --label=t
want "over budget exits 4 (not 1 — a slow suite is not a broken one)" "4" "$RC"
if [[ "$OUT" == *"OVER BUDGET"* ]]; then ok "over-budget run says so in its output"
else bad "over-budget run says so in its output" "$OUT"; fi

# The remedy half. A budget that reds without naming the file to merge, retire or
# demote is a warning with a worse exit code, and the whole finding behind this row
# is that a number nobody can act on gets read by nobody.
if [[ "$OUT" == *"slow_one.sh"* ]]; then ok "over-budget output NAMES the slowest harness"
else bad "over-budget output NAMES the slowest harness" "$OUT"; fi
if [[ "$OUT" == *"MERGE by subject"* && "$OUT" == *"RETIRE"* && "$OUT" == *"TIER: nightly"* ]]; then
  ok "over-budget output names all three remedies (merge / retire / demote)"
else bad "over-budget output names all three remedies (merge / retire / demote)" "$OUT"; fi

run --tier=core --budget=600 --label=t
want "inside budget exits 0" "0" "$RC"
if [[ "$OUT" == *"harness-budget[core/t]"* && "$OUT" == *"% of budget)"* ]]; then
  ok "every run prints the number and the percentage of budget"
else bad "every run prints the number and the percentage of budget" "$OUT"; fi

# A FAILING harness dominates an over-budget one: same run, both true, exit 1.
mk red_one.sh '#!/usr/bin/env bash
exit 1'
run --tier=core --budget=1 --label=t
want "a failing harness dominates over-budget (exit 1, not 4)" "1" "$RC"
if [[ "$OUT" == *"FAILED: $TMP/red_one.sh"* ]]; then ok "the failing harness is named"
else bad "the failing harness is named" "$OUT"; fi
rm -f "$TMP/red_one.sh"

run --tier=core --budget=600 --label=t --report="$TMP/rep.txt"
hdr_s="$(sed -n 's/^# wall_clock_s=//p' "$TMP/rep.txt")"
hdr_n="$(sed -n 's/^# harnesses=//p' "$TMP/rep.txt")"
if [[ -n "$hdr_s" && "$hdr_n" == 2 ]]; then
  ok "the report carries the header the nightly summary reads"
else
  bad "the report carries the header the nightly summary reads" "harnesses=[$hdr_n] wall_clock_s=[$hdr_s]"
fi

# An empty selection is UNDETERMINED, never clean: `for t in <nothing>` passes
# loudly, having graded nothing (the grade-release-commit.sh lesson).
mkdir -p "$TMP/empty"
run --tier=core --budget=600 --corpus-dir="$TMP/empty" 2>/dev/null || true
OUT="$(bash "$RUNNER" --tier=core --budget=600 --corpus-dir="$TMP/empty" 2>&1)"; RC=$?
if (( RC == 1 )) && [[ "$OUT" == *"not a green one"* ]]; then
  ok "an empty corpus FAILS rather than passing over nothing"
else
  bad "an empty corpus FAILS rather than passing over nothing" "rc=$RC out=$OUT"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
