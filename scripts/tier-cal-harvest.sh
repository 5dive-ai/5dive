#!/usr/bin/env bash
# DIVE-2867: RECONSTRUCT THE CALIBRATION WINDOW FROM CI LOGS, BECAUSE THE RUNNER
# ALREADY PRINTS EVERY FIELD THE WINDOW READS.
#
# WHAT THIS UNBLOCKS. scripts/tier-cal-window.sh is the cross-run instrument — it is the
# only thing that can answer "does the probe track the corpus", because no single run can
# see a window. It has been unusable since it shipped, for one stated reason, in its own
# header: "a window needs reports to OUTLIVE the run that wrote them, and today they do
# not persist. Wiring this means uploading the report as an artifact (or appending to a
# series on main) and reading N back — a separate change with its own retention
# question."
#
# THAT PREMISE IS FALSE, AND THAT IS THE FINDING. The `--report=` file is not the only
# copy of those numbers. run-harnesses.sh prints the same quantities to STDOUT on EVERY
# run — pass and fail alike, deliberately (DIVE-2736: "a diagnostic that only prints on
# the red half of that pair cannot be used that way") — and stdout is the job log, which
# GitHub already retains for every run. So the window's inputs have been durable all
# along, in a store nobody has to choose a retention policy for:
#
#   harness-budget[core/pristine]: 254 harnesses, 283s wall-clock, budget 300s (94% of budget)
#   harness-budget[core/pristine]: CALIBRATION (measured) 119385us/iter vs baseline 119000us/iter = 100% of a normal
#     runner; applied 100% (clamp 100-150%) -> effective cap 300s. This run is 94% of the RAW cap
#   harness-budget[core/pristine]: PROBE BRACKET (DIVE-2736) pre 119385us/iter -> post 119349us/iter (+0%),
#
# Those four lines carry every field tier-cal-window.sh reads (cal_us_per_iter,
# wall_clock_s, harnesses, cal_post_us_per_iter, cal_post_delta_pct) plus the scale and
# the effective cap. This script parses them back into report format, so the window tool
# runs UNCHANGED against history.
#
# WHY THAT MATTERS RIGHT NOW rather than as tidying: the anti-ratchet rule for
# TIER_CAL_BASELINE_US is a constraint on SAMPLE SIZE ("the reference must have at least
# K CONCORDANT samples strictly below it, or one run can set it" — K=2 needs n>=20). A
# window that cannot outlive its run can never reach n=20, so the rule was unsatisfiable
# by construction and the constant could only ever be set by argument. Harvesting makes
# n a thing you can go and get.
#
# WHAT IT DOES NOT DO, said out loud because a harvester that quietly invents a field is
# worse than no harvester: the log carries a SUBSET of the report. cal_iters,
# header_drift, first_pass_wall_clock_s, budget_confirmed, confirm_reclaimed_s and the
# per-harness TSV body are not printed and are therefore ABSENT from the output, never
# zero-filled — an absence encoded as a value is read as presence, and these feed
# arithmetic. tier-cal-window.sh does not read any of them; anything that does will see
# a missing key and can say so.
#
# PROVENANCE IS NOT OPTIONAL HERE. Every harvested report carries the run id, the job, the
# sha and the harvest date, because the whole reason the previous baseline (173000) could
# not be refuted by the next reading is that it was a figure with no environment attached
# (DIVE-2555). A harvested sample is a measurement from a named runner on a named commit
# or it is not evidence.
#
#   scripts/tier-cal-harvest.sh --last=20 [--branch=main] [--workflow=unit-tests.yml] [--out=DIR]
#   scripts/tier-cal-harvest.sh <run-id>... [--out=DIR]
#   scripts/tier-cal-harvest.sh --from-log=FILE --run=ID [--sha=SHA] [--out=DIR]
#
# Then: scripts/tier-cal-window.sh "$OUT"/*.report
#
# Exit: 0 harvested at least one report | 2 usage / no runner available
#       | 6 ran clean but harvested NOTHING (an empty window is not a window; the
#         caller asked for samples and got none, and a silent 0 reads like a verdict)
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 2

LAST=""; BRANCH="main"; WORKFLOW="unit-tests.yml"; OUT="tier-cal-window"; RUNS=()
FROM_LOG=""; FROM_RUN=""; FROM_SHA=""; REPO="${TIER_CAL_HARVEST_REPO:-}"
for a in "$@"; do case "$a" in
  --last=*)     LAST="${a#--last=}" ;;
  --branch=*)   BRANCH="${a#--branch=}" ;;
  --workflow=*) WORKFLOW="${a#--workflow=}" ;;
  --out=*)      OUT="${a#--out=}" ;;
  --repo=*)     REPO="${a#--repo=}" ;;
  --from-log=*) FROM_LOG="${a#--from-log=}" ;;
  --run=*)      FROM_RUN="${a#--run=}" ;;
  --sha=*)      FROM_SHA="${a#--sha=}" ;;
  -*) printf 'unknown arg: %s\n' "$a" >&2; exit 2 ;;
  *)  RUNS+=("$a") ;;
esac; done

if [[ -n "$LAST" ]]; then
  [[ "$LAST" =~ ^[0-9]+$ ]] && (( LAST >= 1 )) || {
    printf 'tier-cal-harvest: --last must be an integer >= 1, got %s\n' "$LAST" >&2; exit 2; }
fi
if [[ -n "$FROM_LOG" && -z "$FROM_RUN" ]]; then
  # A harvested sample with no run id is a number with no environment, which is the
  # exact defect DIVE-2555 named. Refuse rather than emit an unattributable row.
  printf 'tier-cal-harvest: --from-log needs --run=<id> so the sample carries its provenance\n' >&2; exit 2
fi
if [[ -z "$FROM_LOG" && -z "$LAST" && ${#RUNS[@]} -eq 0 ]]; then
  printf 'usage: tier-cal-harvest.sh --last=N [--branch=B] [--workflow=W] [--out=DIR]\n' >&2
  printf '       tier-cal-harvest.sh <run-id>... [--out=DIR]\n' >&2
  printf '       tier-cal-harvest.sh --from-log=FILE --run=ID [--sha=SHA] [--out=DIR]\n' >&2
  exit 2
fi

gh_args=(); [[ -n "$REPO" ]] && gh_args=(-R "$REPO")
have_gh=0; command -v gh >/dev/null 2>&1 && have_gh=1
if [[ -z "$FROM_LOG" ]] && (( have_gh == 0 )); then
  printf 'tier-cal-harvest: gh is not on PATH. Use --from-log=FILE --run=ID to parse a saved log.\n' >&2
  exit 2
fi

mkdir -p -- "$OUT" || exit 2

# ---------------------------------------------------------------------------
# parse_log <logfile> <run-id> <sha> -> writes one report per JOB found.
#
# `gh run view --log` prefixes every line with "<job>\t<step>\t<timestamp> ". The job
# column is the only reliable separator: two jobs in one run interleave freely in the
# stream, and the budget block for core/pristine and core/installed-host is
# byte-similar, so keying on the harness-budget label alone would merge two runners
# into one sample. Split on the job field FIRST, parse per job.
# ---------------------------------------------------------------------------
parse_log() {
  local log="$1" run="$2" sha="$3" jobs job n=0
  jobs="$(awk -F'\t' '/harness-budget\[/ {print $1}' "$log" 2>/dev/null | sort -u)"
  [[ -n "$jobs" ]] || return 0
  while IFS= read -r job; do
    [[ -n "$job" ]] || continue
    local blk tier label harn wall budget pct
    local cal_status cal_us cal_base scale_raw scale_app eff_cap eff_pct
    local post_us post_delta
    blk="$(awk -F'\t' -v j="$job" '$1==j' "$log" | grep -a 'harness-budget\|runner; applied\|and .*% of the EFFECTIVE cap')"

    # "harness-budget[core/pristine]: 254 harnesses, 283s wall-clock, budget 300s (94% of budget)"
    local totals; totals="$(printf '%s\n' "$blk" | grep -aoE 'harness-budget\[[a-z]+/[a-z-]+\]: [0-9]+ harnesses, [0-9]+s wall-clock, budget [0-9]+s \([0-9]+% of budget\)' | tail -1)"
    [[ -n "$totals" ]] || continue
    tier="$(printf '%s' "$totals"  | sed -E 's/^harness-budget\[([a-z]+)\/.*/\1/')"
    label="$(printf '%s' "$totals" | sed -E 's/^harness-budget\[[a-z]+\/([a-z-]+)\].*/\1/')"
    harn="$(printf '%s' "$totals"  | sed -E 's/.*: ([0-9]+) harnesses.*/\1/')"
    wall="$(printf '%s' "$totals"  | sed -E 's/.*, ([0-9]+)s wall-clock.*/\1/')"
    budget="$(printf '%s' "$totals" | sed -E 's/.*budget ([0-9]+)s \(.*/\1/')"
    pct="$(printf '%s' "$totals"   | sed -E 's/.*\(([0-9]+)% of budget\)$/\1/')"

    # "CALIBRATION (measured) 119385us/iter vs baseline 119000us/iter = 100% of a normal"
    local calline; calline="$(printf '%s\n' "$blk" | grep -aoE 'CALIBRATION \([a-z]+\) [0-9]+us/iter vs baseline [0-9]+us/iter = [0-9]+%' | tail -1)"
    if [[ -n "$calline" ]]; then
      cal_status="$(printf '%s' "$calline" | sed -E 's/^CALIBRATION \(([a-z]+)\).*/\1/')"
      cal_us="$(printf '%s' "$calline"     | sed -E 's/.*\) ([0-9]+)us\/iter vs.*/\1/')"
      cal_base="$(printf '%s' "$calline"   | sed -E 's/.*vs baseline ([0-9]+)us\/iter.*/\1/')"
      scale_raw="$(printf '%s' "$calline"  | sed -E 's/.*= ([0-9]+)%$/\1/')"
    fi
    # "runner; applied 100% (clamp 100-150%) -> effective cap 300s. This run is 94% of the RAW cap"
    local appline; appline="$(printf '%s\n' "$blk" | grep -aoE 'applied [0-9]+% \(clamp [0-9]+-[0-9]+%\) -> effective cap [0-9]+s' | tail -1)"
    if [[ -n "$appline" ]]; then
      scale_app="$(printf '%s' "$appline" | sed -E 's/^applied ([0-9]+)%.*/\1/')"
      eff_cap="$(printf '%s' "$appline"   | sed -E 's/.*effective cap ([0-9]+)s$/\1/')"
    fi
    eff_pct="$(printf '%s\n' "$blk" | grep -aoE 'and [0-9]+% of the EFFECTIVE cap' | tail -1 | sed -E 's/^and ([0-9]+)%.*/\1/')"

    # "PROBE BRACKET (DIVE-2736) pre 119385us/iter -> post 119349us/iter (+0%),"
    local brk; brk="$(printf '%s\n' "$blk" | grep -aoE 'PROBE BRACKET \(DIVE-2736\) pre [0-9]+us/iter -> post [0-9]+us/iter \([-+][0-9]+%\)' | tail -1)"
    if [[ -n "$brk" ]]; then
      post_us="$(printf '%s' "$brk"    | sed -E 's/.*-> post ([0-9]+)us\/iter.*/\1/')"
      post_delta="$(printf '%s' "$brk" | sed -E 's/.*\(([-+][0-9]+)%\)$/\1/')"
    fi

    local f="$OUT/${run}-${job}.report"
    {
      printf '# run-harnesses report (HARVESTED from CI log by scripts/tier-cal-harvest.sh)\n'
      # Provenance first, and never optional: a sample that cannot name the runner and
      # the commit it came from cannot be refuted by the next reading (DIVE-2555).
      printf '# harvest_source=ci-log\n# harvest_run_id=%s\n# harvest_job=%s\n' "$run" "$job"
      [[ -n "$sha" ]] && printf '# harvest_sha=%s\n' "$sha"
      printf '# tier=%s\n# label=%s\n# harnesses=%s\n# wall_clock_s=%s\n# budget_s=%s\n# pct_of_budget=%s\n' \
        "$tier" "$label" "$harn" "$wall" "$budget" "$pct"
      # Every field below is emitted ONLY when the log actually carried it. Absent is
      # absent; a zero here would be read as a measurement.
      [[ -n "${cal_status:-}" ]] && printf '# cal_status=%s\n' "$cal_status"
      [[ -n "${cal_us:-}" ]]     && printf '# cal_us_per_iter=%s\n' "$cal_us"
      [[ -n "${cal_base:-}" ]]   && printf '# cal_baseline_us_per_iter=%s\n' "$cal_base"
      [[ -n "${scale_raw:-}" ]]  && printf '# cal_scale_pct=%s\n' "$scale_raw"
      [[ -n "${scale_app:-}" ]]  && printf '# cal_scale_pct_applied=%s\n' "$scale_app"
      [[ -n "${eff_cap:-}" ]]    && printf '# effective_budget_s=%s\n' "$eff_cap"
      [[ -n "${eff_pct:-}" ]]    && printf '# pct_of_effective_budget=%s\n' "$eff_pct"
      if [[ -n "${post_us:-}" ]]; then
        printf '# cal_post_status=measured\n# cal_post_us_per_iter=%s\n# cal_post_delta_pct=%s\n' \
          "$post_us" "${post_delta#+}"
      fi
    } > "$f"
    printf '%s\n' "$f"
    n=$((n+1))
    unset cal_status cal_us cal_base scale_raw scale_app eff_cap eff_pct post_us post_delta
  done <<< "$jobs"
  return "$(( n > 0 ? 0 : 1 ))"
}

harvested=0; skipped=0; skipnames=""

if [[ -n "$FROM_LOG" ]]; then
  if [[ -r "$FROM_LOG" ]]; then
    if out="$(parse_log "$FROM_LOG" "$FROM_RUN" "$FROM_SHA")" && [[ -n "$out" ]]; then
      printf '%s\n' "$out"; harvested=$(( harvested + $(printf '%s\n' "$out" | grep -c .) ))
    else
      skipped=$((skipped+1)); skipnames="$skipnames $FROM_RUN(no budget block)"
    fi
  else
    skipped=$((skipped+1)); skipnames="$skipnames $FROM_LOG(unreadable)"
  fi
else
  declare -A shas=()
  if [[ -n "$LAST" ]]; then
    # Both PASSING and FAILING runs are wanted. The anomaly this window exists to catch
    # was found by comparing a passing run against a failing one 13 minutes later, so
    # filtering to reds would remove exactly the comparison that makes it readable.
    while IFS=$'\t' read -r id sha; do
      [[ -n "$id" ]] && RUNS+=("$id") && shas["$id"]="$sha"
    done < <(gh "${gh_args[@]}" run list --workflow="$WORKFLOW" --branch="$BRANCH" \
               --limit="$LAST" --json databaseId,headSha \
               --jq '.[] | [(.databaseId|tostring), .headSha] | @tsv' 2>/dev/null)
  fi
  for id in "${RUNS[@]}"; do
    tmp="$(mktemp)" || exit 2
    if ! gh "${gh_args[@]}" run view "$id" --log > "$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
      # Log retention expires, and an expired log is a NAMED skip, not a quiet one:
      # a window that silently shrank is indistinguishable from a window that was
      # always that size, which is the sample-size question this tool exists to answer.
      skipped=$((skipped+1)); skipnames="$skipnames $id(log unavailable)"; rm -f "$tmp"; continue
    fi
    if out="$(parse_log "$tmp" "$id" "${shas[$id]:-}")" && [[ -n "$out" ]]; then
      printf '%s\n' "$out"; harvested=$(( harvested + $(printf '%s\n' "$out" | grep -c .) ))
    else
      skipped=$((skipped+1)); skipnames="$skipnames $id(no budget block)"
    fi
    rm -f "$tmp"
  done
fi

printf '\ntier-cal-harvest: %d report(s) into %s/' "$harvested" "$OUT" >&2
if (( skipped )); then printf ', %d skipped:%s' "$skipped" "$skipnames" >&2; fi
printf '\n' >&2
if (( harvested == 0 )); then
  printf 'tier-cal-harvest: harvested NOTHING. An empty window is not a window — do not read\n' >&2
  printf '  this as "the probe tracks fine". Check the workflow/branch names and log retention.\n' >&2
  exit 6
fi
printf 'tier-cal-harvest: now run  scripts/tier-cal-window.sh %s/*.report\n' "$OUT" >&2
exit 0
