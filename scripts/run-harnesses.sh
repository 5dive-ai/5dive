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
#   5  every harness passed and the run is inside budget, but a harness HEADER
#      claims a measured time the clock just refuted by >= 50% (DIVE-2555). Same
#      reason 4 is not 1: the remedy is different, so the code is different.
#   2  usage
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 2
# shellcheck source=tests/lib/tier.sh
. tests/lib/tier.sh

TIER=""; BUDGET=""; LABEL=""; REPORT=""; TOP=10; CORPUS_DIR="tests"; SHARD=""
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
  # DIVE-2525 (main, reviewing #376): the cap is PER JOB, so splitting the sweep
  # across N jobs cuts each job's wall-clock WITHOUT relaxing the constraint. Raising
  # the ceiling buys three days and re-installs the ratchet; sharding buys headroom
  # that scales with the corpus. Round-robin, not contiguous blocks: the cost
  # distribution has a long tail (one harness is 300s, the median is under a second),
  # and contiguous blocks would put a whole alphabetical neighbourhood of expensive
  # e2e files in one shard.
  #
  # WHAT SHARDING DOES NOT DO, said here because it is the thing to watch: it does not
  # reduce the corpus's TOTAL cost, only the wall-clock of any one job. Aggregate
  # nightly capacity is now N x the budget, and N is fixed in the workflow — so adding
  # a shard is exactly as visible, and exactly as much a policy decision, as raising
  # the number. The budget-report job re-sums the shards and prints the UN-SHARDED
  # total, because that total is the number this whole row exists to make legible and
  # sharding is the obvious way to lose it.
  --shard=*)  SHARD="${a#--shard=}" ;;   # i/N, 1-based
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

if [[ -n "$SHARD" ]]; then
  if [[ ! "$SHARD" =~ ^([0-9]+)/([0-9]+)$ ]]; then
    printf 'run-harnesses: --shard must be i/N (1-based), got %s\n' "$SHARD" >&2; exit 2
  fi
  si="${BASH_REMATCH[1]}"; sn="${BASH_REMATCH[2]}"
  if (( si < 1 || sn < 1 || si > sn )); then
    printf 'run-harnesses: --shard=%s is out of range\n' "$SHARD" >&2; exit 2
  fi
  picked=()
  for i in "${!CORPUS[@]}"; do (( i % sn == si - 1 )) && picked+=("${CORPUS[$i]}"); done
  CORPUS=("${picked[@]}")
  LABEL="$LABEL-s$si"
  # A shard that selected nothing is UNDETERMINED for the same reason an empty tier
  # is: it reports green having graded none of the corpus it names.
  if (( ${#CORPUS[@]} == 0 )); then
    printf 'run-harnesses: FAIL — shard %s of tier %s selected 0 harnesses.\n' "$SHARD" "$TIER" >&2
    exit 1
  fi
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

# DIVE-2555: GRADE EACH HEADER'S OWN NUMBER AGAINST THE CLOCK THAT JUST RAN IT.
#
# `# TIER: nightly — 14.3s measured` is the entire argument a reviewer gets that a
# cost was MOVED rather than hidden, and nothing has ever re-read it: it is a
# comment, written once, in a file whose runtime nobody measures again. Measured
# 2026-08-03, gate_channel_session_t2_mutation.sh claimed 300.0s and ran 335s on the
# control plane, and neither figure carried an environment or a date, so no reading
# could refute another.
#
# This costs nothing: MS[] is already the measurement, taken in the run that had to
# happen anyway. It is the same principle as the budget itself (enforce on the number
# you MEASURE, never on a table of per-file costs) turned on the table.
#
# A harness that FAILED is skipped — an aborted run's wall-clock is not a measurement
# of what the harness costs, and accusing its header of drift on that evidence is the
# same error, inverted.
drift=(); drift_fatal=0
for i in "${!NAME[@]}"; do
  (( RC[i] == 0 )) || continue
  claim="$(tier_claim "${NAME[$i]}")"
  [[ -n "$claim" ]] || continue
  claim_ms=$(awk -v c="$claim" 'BEGIN{printf "%d", c*1000 + 0.5}')
  (( claim_ms > 0 && MS[i] > claim_ms )) || continue
  gap_ms=$(( MS[i] - claim_ms )); over_pct=$(( gap_ms * 100 / claim_ms ))
  (( gap_ms >= TIER_CLAIM_DRIFT_WARN_S * 1000 && over_pct >= TIER_CLAIM_DRIFT_WARN_PCT )) || continue
  sev="stale"
  if (( over_pct >= TIER_CLAIM_DRIFT_FAIL_PCT && gap_ms >= TIER_CLAIM_DRIFT_FAIL_S * 1000 )); then
    sev="WRONG"; drift_fatal=1
  fi
  drift+=("$(printf '%s\t%s\t%s\t%s' "$sev" "${NAME[$i]}" "$claim" "${MS[$i]}")")
done

if [[ -n "$REPORT" ]]; then
  {
    printf '# run-harnesses report\n# tier=%s\n# label=%s\n# shard=%s\n# harnesses=%d\n# wall_clock_s=%d\n# budget_s=%d\n# pct_of_budget=%d\n# header_drift=%d\n' \
      "$TIER" "$LABEL" "${SHARD:-1/1}" "${#CORPUS[@]}" "$total_s" "$BUDGET" "$pct" "${#drift[@]}"
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

# DIVE-2555. Printed whatever else happened, because a header that no longer matches
# the clock is exactly as wrong in a run that went red for another reason.
if (( ${#drift[@]} )); then
  printf '\nharness-budget[%s/%s]: %d HEADER MEASUREMENT(S) THE CLOCK JUST REFUTED.\n' \
    "$TIER" "$LABEL" "${#drift[@]}"
  printf 'A demotion is argued in the diff with its own number, and that number is the only\n'
  printf 'evidence a reviewer has that a cost was MOVED rather than hidden. An optimistic one\n'
  printf 'is a demotion argued on a figure nobody grades. Replace the header line with the\n'
  printf 'measurement below, and say WHERE it was taken — a figure with no environment on it\n'
  printf 'cannot be refuted by the next reading, only silently disagreed with:\n'
  for d in "${drift[@]}"; do
    IFS=$'\t' read -r sev nm claim ms <<<"$d"
    printf '  %-5s %s\n' "$sev" "$nm"
    printf '        claims %ss measured, ran %.1fs here (+%d%%) on %s\n' \
      "$claim" "$(awk -v m="$ms" 'BEGIN{print m/1000}')" \
      "$(( ( ms - $(awk -v c="$claim" 'BEGIN{printf "%d", c*1000 + 0.5}') ) * 100 / $(awk -v c="$claim" 'BEGIN{printf "%d", c*1000 + 0.5}') ))" \
      "$LABEL"
    printf '        # TIER: nightly — %.1fs measured (%s, <date>): <why this cannot be in the %ds PR core>\n' \
      "$(awk -v m="$ms" 'BEGIN{print m/1000}')" "$LABEL" "$TIER_BUDGET_CORE"
  done
  (( drift_fatal )) && printf 'At least one is marked WRONG (>= %d%% and >= %ds under): that is not runner variance.\n' \
    "$TIER_CLAIM_DRIFT_FAIL_PCT" "$TIER_CLAIM_DRIFT_FAIL_S"
fi

if (( ${#failed[@]} )); then
  printf '\n%d harness(es) FAILED:\n' "${#failed[@]}"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
(( over == 0 )) || exit 4
(( drift_fatal == 0 )) || exit 5
exit 0
