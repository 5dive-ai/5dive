#!/usr/bin/env bash
# DIVE-3580 — THE BUDGET RED'S BASELINE ATTRIBUTION, GRADED AT BOTH LAYERS.
#
# WHAT FORCED IT: PR #708 was red-blocked at 306s/300s, CONFIRMED on a second runner
# (DIVE-2829), and main's own next run of the SAME 172-harness corpus read 232s (77%)
# and 200s (66%). Two boxes are not independent when the fleet draws slow the same
# hour, so the confirm rail gained a third instrument: compare the red run's
# per-harness vector against the last GREEN main run's over the COMMON file set —
# a uniform lift across unrelated files is the box, concentration or new files are
# the corpus. tests/lib/tier.sh (the DIVE-3580 block) carries the derivation, the
# thresholds and the two named residuals; this harness holds every arm of the verdict
# open, and the NEGATIVE arms are the load-bearing half: the instrument may only ever
# RELIEVE a red (4 -> 6), so the arms that matter most are the ones proving a missing,
# thin or disagreeing baseline leaves exit 4 exactly where it stands today.
#
# Core tier on purpose: ~7s, dominated by five 13-file fixture-corpus runs (DIVE-3646
# reshaped that corpus without changing its wall clock), and it
# guards the verdict logic of the gate every PR is graded by.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# DIVE-2692 + TMP cleanup folded into ONE trap (bash keeps only the last per signal).
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"
RUNNER="$ROOT/scripts/run-harnesses.sh"
TIERLIB="$ROOT/tests/lib/tier.sh"

TMP="$(mktemp -d /tmp/budget-attribution.XXXXXX)" || exit 2
CORPUS="$TMP/corpus"; mkdir -p "$CORPUS"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
want() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing [$3] in: $2"; fi; }
hasnt() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "unexpectedly found [$3] in: $2"; fi; }

attr() { OUT="$(bash "$TIERLIB" attribute "$@" 2>&1)"; RC=$?; }

# Fixture vectors. ms<TAB>rc<TAB>path, the run-harnesses report body shape. The
# uniform pair is #708's shape scaled down: every common file lifted ~1.3x, no file
# dominating; the baseline prices the corpus comfortably inside the cap.
mkvec() { # <file> <ms-per-file> <count> [prefix]
  local f="$1" ms="$2" n="$3" p="${4:-tests/fx}" i
  : > "$f"; for (( i = 1; i <= n; i++ )); do printf '%s\t0\t%s%02d.sh\n' "$ms" "$p" "$i" >> "$f"; done
}

# --- 1-7: the verdict function, every arm ------------------------------------
mkvec "$TMP/base.txt" 1000 10                     # baseline: 10 files x 1.0s = 10s
mkvec "$TMP/red-uniform.txt" 1300 10              # red: same 10 files x 1.3s = 13s
attr 12000 "$TMP/red-uniform.txt" "$TMP/base.txt" # cap 12s: over at 13s, fits at 10s
want "a uniform 1.3x lift that fits at baseline prices is the RUNNER (exit 0)" "0" "$RC"
has  "…and says so with its numbers" "$OUT" "verdict=runner reason=uniform-lift-fits-at-baseline-prices"

{ mkvec "$TMP/red-conc.txt" 1000 9; printf '4000\t0\ttests/fx10.sh\n' >> "$TMP/red-conc.txt"; }
attr 12000 "$TMP/red-conc.txt" "$TMP/base.txt"    # one file +3s carries all the excess
want "growth concentrated in one existing file is the CORPUS (exit 1)" "1" "$RC"
has  "…named as concentration, not as weather" "$OUT" "verdict=corpus reason=concentrated-excess"

{ cp "$TMP/base.txt" "$TMP/red-new.txt"; printf '5000\t0\ttests/newA.sh\n' >> "$TMP/red-new.txt"; }
attr 12000 "$TMP/red-new.txt" "$TMP/base.txt"     # 10s common + 5s new = 15s > 12s cap
want "new files that reprice the corpus over its cap are the CORPUS" "1" "$RC"
# ORDER ARM: the new file drops common cover to 67%, under the 80% floor — repriced
# must be judged FIRST or real growth reads as "could not measure".
has  "…convicted as over-at-baseline-prices even though the new file thins the cover" \
  "$OUT" "verdict=corpus reason=over-at-baseline-prices"

# One surviving common file lifted 3.5x, ten renamed files: repriced (1s common at
# baseline + 1s renamed at their own price) FITS the 4s cap, so what fires is the
# 77% cover against the 80% floor — the relief refusal, not a conviction.
{ mkvec "$TMP/red-thin.txt" 100 10 tests/renamed; printf '3500\t0\ttests/fx01.sh\n' >> "$TMP/red-thin.txt"; }
attr 4000 "$TMP/red-thin.txt" "$TMP/base.txt"
want "a mostly-renamed corpus (thin common set) is UNMEASURABLE, never relief" "1" "$RC"
has  "…and says which refusal it is" "$OUT" "verdict=unmeasurable reason=thin-common-set"

: > "$TMP/base-empty.txt"
attr 12000 "$TMP/red-uniform.txt" "$TMP/base-empty.txt"
want "an empty baseline is UNMEASURABLE (exit 1)" "1" "$RC"
has  "…as no-common-measurement" "$OUT" "verdict=unmeasurable reason=no-common-measurement"

attr 12000 "$TMP/red-uniform.txt" "$TMP/no-such-file.txt"
want "an unreadable baseline is UNMEASURABLE, not an error that greens anything" "1" "$RC"
has  "…and names the unreadable file class" "$OUT" "verdict=unmeasurable reason=baseline-unreadable"

attr notanumber "$TMP/red-uniform.txt" "$TMP/base.txt"
want "a non-integer cap is USAGE (exit 2), not a verdict" "2" "$RC"

# --- 8-12: the runner wiring, end to end --------------------------------------
# THESE ARMS MEASURE WALL CLOCK, SO THE FIXTURE HAS TO SURVIVE A COLD RUNNER.
# DIVE-3646: on main@31031d1 the FIRST harness in this corpus read 284ms against
# 153ms for the other seven — the cold page cache and first process spawn that only
# the first one pays. DIVE-3580 read that correctly as CONCENTRATION
# (top_excess_share_pct=52 against the 50 threshold), so the arm below demanded
# `runner` and got `corpus`; test-installed-host is in branch protection, so this
# froze every merge and every release cut on the repo for ~4h.
#
# The fixture was wrong, not the attributor, and the fix belongs here — NOT in
# TIER_ATTR_CONC_MAX_PCT. Widening the concentration threshold to make this arm pass
# would blind the gate to real single-file growth: widening a safety control to
# unblock the change it would unblock.
#
# Two structural changes, neither of them a retuned magic number:
#
#   1. h00-warmup.sh runs FIRST (tier_list globs, so the corpus is in sorted order)
#      and is priced in the baseline at WARMUP_BASE_MS — far above anything it can
#      actually cost. Its excess is therefore NEGATIVE BY CONSTRUCTION, and the
#      attributor only sums excess > 0, so the warm-up file cannot enter the
#      concentration term at all. The first-harness cost now lands on a harness that
#      is structurally incapable of carrying a verdict.
#
#   2. MEAS_N measured harnesses instead of eight, at a shorter sleep so the run
#      costs the same wall clock as before. Top-3-of-12 is 25% at perfect uniformity
#      where top-3-of-8 was 37.5%, so a straggler among the MEASURED files now needs
#      roughly 6x the uniform per-file excess (~0.4s) to reach the 50 threshold,
#      against the ~0.11s that was enough before.
#
# AND THE OVER/UNDER-CAP DECISION IS NOT TIMING-COUPLED AT ALL, by construction:
# the sleeps alone sum to MEAS_N*MEAS_SLEEP = 1.2s against a 1s cap, so the corpus is
# over on any runner at any speed, and the baseline prices are CONSTANTS summing to
# less than the cap, so "fits at baseline prices" is arithmetic rather than weather.
# The guard below asserts exactly that, so that retuning these constants into
# incoherence fails as itself instead of as a mystery verdict.
CAP_MS=1000                  # --budget=1, with calibration off
MEAS_N=12; MEAS_SLEEP=0.1    # 12 x 0.1s = 1.2s of sleep alone, over CAP_MS
WARMUP_SLEEP=0.02
WARMUP_BASE_MS=500           # >> any plausible first-harness warm-up: excess < 0
UNIFORM_BASE_MS=35           # green-run price: 500 + 12*35 = 920ms, fits CAP_MS
HEAVY_BASE_MS=60             # agrees the corpus is over: 500 + 12*60 = 1220ms

mkharness() { printf '#!/usr/bin/env bash\nsleep %s\nexit 0\n' "$2" > "$CORPUS/$1"; }
mkharness h00-warmup.sh "$WARMUP_SLEEP"
for (( i = 1; i <= MEAS_N; i++ )); do mkharness "$(printf 'h%02d.sh' "$i")" "$MEAS_SLEEP"; done

mkbaseline() { # <file> <ms-per-measured-file>
  { printf '%s\t0\t%s/h00-warmup.sh\n' "$WARMUP_BASE_MS" "$CORPUS"
    for (( i = 1; i <= MEAS_N; i++ )); do printf '%s\t0\t%s/h%02d.sh\n' "$2" "$CORPUS" "$i"; done
  } > "$1"
}
mkbaseline "$TMP/cb-uniform.txt" "$UNIFORM_BASE_MS"
mkbaseline "$TMP/cb-heavy.txt" "$HEAVY_BASE_MS"

# The three arithmetic invariants the arms below rest on. None involves a clock.
sleep_ms=$(awk -v n="$MEAS_N" -v s="$MEAS_SLEEP" 'BEGIN{printf "%d", n*s*1000}')
uni_ms=$(( WARMUP_BASE_MS + MEAS_N * UNIFORM_BASE_MS ))
hvy_ms=$(( WARMUP_BASE_MS + MEAS_N * HEAVY_BASE_MS ))
if (( sleep_ms > CAP_MS && uni_ms < CAP_MS && hvy_ms > CAP_MS )); then
  ok "the fixture's own prices are coherent: sleeps ${sleep_ms}ms > cap ${CAP_MS}ms > uniform baseline ${uni_ms}ms"
else
  bad "the fixture's own prices are coherent" \
    "need sleeps > cap > uniform-baseline and heavy-baseline > cap; got ${sleep_ms}/${CAP_MS}/${uni_ms}/${hvy_ms}"
fi

run() { OUT="$(bash "$RUNNER" --no-calibrate --corpus-dir="$CORPUS" --tier=core --confirm-top=0 "$@" 2>&1)"; RC=$?; }

run --budget=1 --label=t --report="$TMP/r-runner.txt" --baseline-report="$TMP/cb-uniform.txt"
want "over + uniform-lift baseline resolves 4 -> 6 (UNDETERMINED, no corpus finding)" "6" "$RC"
has  "…the report carries the graded verdict" "$(cat "$TMP/r-runner.txt")" "# budget_attribution=runner"
has  "…and the human print says which exit and why" "$OUT" "ATTRIBUTED TO THE RUNNER (DIVE-3580)"

run --budget=1 --label=t --report="$TMP/r-off.txt"
want "the SAME over-budget corpus with NO baseline keeps its exit 4 — relief is strictly opt-in" "4" "$RC"
has  "…and the report says the instrument was not consulted (a graded off, not an absence)" \
  "$(cat "$TMP/r-off.txt")" "# budget_attribution=off"

run --budget=1 --label=t --report="$TMP/r-corpus.txt" --baseline-report="$TMP/cb-heavy.txt"
want "a baseline that agrees the corpus is over leaves exit 4 standing" "4" "$RC"
has  "…recorded as a corpus verdict" "$(cat "$TMP/r-corpus.txt")" "# budget_attribution=corpus"

run --budget=60 --label=t --report="$TMP/r-green.txt" --baseline-report="$TMP/cb-uniform.txt"
want "a green run with a baseline supplied stays green — attribution touches only a would-be 4" "0" "$RC"
has  "…and its report reads off" "$(cat "$TMP/r-green.txt")" "# budget_attribution=off"

printf '#!/usr/bin/env bash\nexit 1\n' > "$CORPUS/h99-fail.sh"
run --budget=1 --label=t --report="$TMP/r-fail.txt" --baseline-report="$TMP/cb-uniform.txt"
want "a FAILING harness still dominates: exit 1, never a weather downgrade over a red test" "1" "$RC"
rm -f "$CORPUS/h99-fail.sh"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
exit 0
