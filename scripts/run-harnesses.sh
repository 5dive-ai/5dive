#!/usr/bin/env bash
# DIVE-2525: run a TIER of the harness corpus under a WALL-CLOCK BUDGET.
#
# Replaces the two inline `for t in tests/*.sh` loops in unit-tests.yml. Same
# contract as those loops — source-only harnesses, throwaway STATE_DIR, exit
# non-zero if any harness fails — plus the two things the loops could not do:
#
#   1. It TIMES the run and FAILS when the tier is over its budget, naming the
#      slowest harnesses. A warning here would be worthless: the corpus growth was
#      already visible for two weeks in a number nobody read, and what surfaced
#      first was a human noticing that fixes "felt like a struggle".
#   2. It PRINTS the total as a number in its own output, every run, with the
#      percentage of budget — so the trend is legible without archaeology.
#
# WHAT IS AND IS NOT MEASURED. Only the harnesses. Not checkout, not ./build.sh,
# not the installed-host seeding. So the number means the same thing in CI, on the
# control plane and on a laptop, and a slow `apt-get` cannot spend the corpus's
# budget. The job's own wall-clock will always be larger; that is fine and it is
# not what is capped.
#
# BUDGET FAILURE IS NOT TEST FAILURE and they do not share an exit code — a red
# that could mean either would get triaged as neither:
#   0  all harnesses passed, run inside budget
#   1  at least one harness FAILED (this dominates: over budget too still exits 1,
#      because the failing harness is the thing to fix first)
#   4  every harness passed, run is OVER BUDGET
#   3  the corpus could not be classified into tiers (see tests/lib/tier.sh)
#   2  usage
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 2
# shellcheck source=tests/lib/tier.sh
. tests/lib/tier.sh

TIER=""; BUDGET=""; LABEL=""; REPORT=""; TOP=10; CORPUS_DIR="tests"
for a in "$@"; do case "$a" in
  --tier=*)   TIER="${a#--tier=}" ;;
  # The seam that lets tests/corpus_tier_budget_unit.sh grade THIS script against a
  # throwaway corpus of its own. Without it the only way to test the budget rail is
  # to make the real corpus slow, which is the one thing this script exists to stop.
  --corpus-dir=*) CORPUS_DIR="${a#--corpus-dir=}" ;;
  # Override the resolver's number. A workflow SHOULD NOT pass this — the budget
  # belongs next to the tier definition, not scattered across the callers, or
  # raising it becomes a one-line edit in a YAML nobody reviews as a policy change.
  # It exists for the harness that grades this script, and for a human measuring.
  --budget=*) BUDGET="${a#--budget=}" ;;
  --label=*)  LABEL="${a#--label=}" ;;   # names the environment in the summary line
  --report=*) REPORT="${a#--report=}" ;; # TSV: ms<TAB>rc<TAB>path, for the trend
  --top=*)    TOP="${a#--top=}" ;;
  *) printf 'unknown arg: %s\n' "$a" >&2; exit 2 ;;
esac; done

case "$TIER" in
  core|full) ;;
  *) printf 'usage: run-harnesses.sh --tier=core|full [--budget=<seconds>] [--label=<env>] [--report=<file>] [--corpus-dir=<dir>]\n' >&2; exit 2 ;;
esac
[[ -n "$BUDGET" ]] || BUDGET="$(tier_budget "$TIER")" || exit 2
[[ -n "$LABEL" ]] || LABEL="local"

mapfile -t CORPUS < <(tier_list "$TIER" "$CORPUS_DIR") || {
  printf 'run-harnesses: REFUSING to run a corpus this tree cannot classify (see the tier: lines above).\n' >&2
  exit 3
}
# An EMPTY set is UNDETERMINED, never clean — the same reason grade-release-commit.sh
# refuses one: `for t in <nothing>` passes, loudly, having graded nothing.
if (( ${#CORPUS[@]} == 0 )); then
  printf 'run-harnesses: FAIL — tier %s selected 0 harnesses. An empty corpus is not a green one.\n' "$TIER" >&2
  exit 1
fi

declare -a MS=() RC=() NAME=()
failed=(); total_ms=0
for t in "${CORPUS[@]}"; do
  printf '=== %s\n' "$t"
  s=$(date +%s%N)
  bash "$t"; rc=$?
  e=$(date +%s%N)
  ms=$(( (e - s) / 1000000 )); total_ms=$(( total_ms + ms ))
  MS+=("$ms"); RC+=("$rc"); NAME+=("$t")
  if (( rc != 0 )); then printf 'FAILED: %s\n' "$t"; failed+=("$t"); fi
done

total_s=$(( (total_ms + 999) / 1000 ))
pct=0; (( BUDGET > 0 )) && pct=$(( total_s * 100 / BUDGET ))

if [[ -n "$REPORT" ]]; then
  {
    printf '# run-harnesses report\n# tier=%s\n# label=%s\n# harnesses=%d\n# wall_clock_s=%d\n# budget_s=%d\n# pct_of_budget=%d\n' \
      "$TIER" "$LABEL" "${#CORPUS[@]}" "$total_s" "$BUDGET" "$pct"
    for i in "${!NAME[@]}"; do printf '%s\t%s\t%s\n' "${MS[$i]}" "${RC[$i]}" "${NAME[$i]}"; done
  } > "$REPORT"
fi

# Build 3 of DIVE-2525: the number, in its own output, every run.
printf '\nharness-budget[%s/%s]: %d harnesses, %ds wall-clock, budget %ds (%d%% of budget)\n' \
  "$TIER" "$LABEL" "${#CORPUS[@]}" "$total_s" "$BUDGET" "$pct"

slowest() {
  local n="$1" i
  for i in "${!NAME[@]}"; do printf '%s\t%s\n' "${MS[$i]}" "${NAME[$i]}"; done \
    | sort -rn | head -"$n" | while IFS=$'\t' read -r ms nm; do
        printf '    %6.1fs  %s\n' "$(awk -v m="$ms" 'BEGIN{print m/1000}')" "$nm"
      done
}

over=0
if (( BUDGET <= 0 )); then
  printf 'harness-budget[%s]: BUDGET DISABLED (--budget=%s). This run enforces nothing.\n' "$TIER" "$BUDGET"
elif (( total_s > BUDGET )); then
  over=1
  printf '\nharness-budget[%s]: OVER BUDGET by %ds (%ds > %ds).\n' "$TIER" "$(( total_s - BUDGET ))" "$total_s" "$BUDGET"
  printf 'The corpus is not free: every harness here runs on every future change, forever.\n'
  printf 'Past the cap a new guard REPLACES or MERGES an existing one. The %d slowest in this tier:\n' "$TOP"
  slowest "$TOP"
  printf '\nThree ways out, in order of preference:\n'
  printf '  1. MERGE by subject. Hundreds of harness FILES for one CLI means the unit of\n'
  printf '     organisation is the incident, not the subject. Folding two files about the same\n'
  printf '     subject into one reclaims their setup cost and drops NO assertion.\n'
  printf '  2. RETIRE. A guard for a class that can no longer occur (the code path is gone, or a\n'
  printf '     stronger check subsumes it) is pure cost. Deleting it is a legitimate PR.\n'
  printf '  3. DEMOTE, with a reason, by adding to the harness header:\n'
  printf '       # TIER: nightly — <why this cannot be in the %ds PR core>\n' "$TIER_BUDGET_CORE"
  printf '     Demotion moves the cost to the nightly sweep, which has its own budget (%ds).\n' "$TIER_BUDGET_FULL"
  printf '     It does not delete the cost, which is why it is third and why it must be argued.\n'
elif (( pct >= 80 )); then
  printf 'harness-budget[%s]: %d%% of budget — inside the cap, but the next few guards will not be.\n' "$TIER" "$pct"
  printf 'The %d slowest in this tier:\n' "$TOP"; slowest "$TOP"
fi

if (( ${#failed[@]} )); then
  printf '\n%d harness(es) FAILED:\n' "${#failed[@]}"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
(( over == 0 )) || exit 4
exit 0
