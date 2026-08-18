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
# Core tier on purpose: ~7s, dominated by five 8-file fixture-corpus runs, and it
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
mk() { printf '#!/usr/bin/env bash\nsleep 0.15\nexit 0\n' > "$CORPUS/$1"; }
for i in 1 2 3 4 5 6 7 8; do mk "h$i.sh"; done
for i in 1 2 3 4 5 6 7 8; do printf '100\t0\t%s/h%d.sh\n' "$CORPUS" "$i"; done > "$TMP/cb-uniform.txt"
for i in 1 2 3 4 5 6 7 8; do printf '160\t0\t%s/h%d.sh\n' "$CORPUS" "$i"; done > "$TMP/cb-heavy.txt"

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

printf '#!/usr/bin/env bash\nexit 1\n' > "$CORPUS/h9.sh"
run --budget=1 --label=t --report="$TMP/r-fail.txt" --baseline-report="$TMP/cb-uniform.txt"
want "a FAILING harness still dominates: exit 1, never a weather downgrade over a red test" "1" "$RC"
rm -f "$CORPUS/h9.sh"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
exit 0
