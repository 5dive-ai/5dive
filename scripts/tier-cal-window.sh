#!/usr/bin/env bash
# DIVE-2736: GRADE THE CALIBRATION PROBE AGAINST THE CORPUS, ACROSS A WINDOW OF RUNS.
#
# WHAT FORCED THIS. On core/installed-host, run 30967674559, the probe read 82218us/iter
# — 30% FASTER than its own five-run cluster — while the corpus came in at 372s against
# 282s thirteen minutes earlier, with ONE FEWER harness. Probe fast, corpus slow, same
# job, same commit. DIVE-2710's premise for a relative budget is that "a uniformly slow
# VM scales the calibration and the corpus together, and the ratio cancels". On that run
# they ANTI-CORRELATED, the scale clamped to its floor, and the mechanism gave exactly
# zero relief on the run it was built to rescue.
#
# NOTHING NOTICED, AND THAT IS THE DEFECT THIS SCRIPT ADDRESSES. Each run prints its own
# two numbers and neither one is wrong on its own; the anti-correlation is only visible
# BETWEEN runs, and no single run can see a window. run-harnesses.sh says so itself where
# it declines to do K-consecutive-run confirmation of the re-baseline warning: "one run
# cannot see K runs". Same shape, same answer — the cross-run read lives out here.
#
# WHAT IT READS: `--report=` files written by scripts/run-harnesses.sh, one per run. It
# needs cal_us_per_iter, wall_clock_s and harnesses; it uses cal_post_us_per_iter and
# cal_post_delta_pct when present.
#
# WHY THE CORPUS IS NORMALISED TO MICROSECONDS PER HARNESS, and this is the one piece of
# arithmetic that carries the whole conclusion: the raw wall-clock moves when the corpus
# GROWS, which is the event the budget exists to catch and is not runner draw at all.
# Dividing it out leaves a per-harness cost whose remaining movement is the platform —
# the same quantity the probe claims to measure. Comparing raw wall-clock against the
# probe would find "anti-correlation" every time somebody deletes a harness, which is
# precisely the confound that made the anomalous pair hard to read (236 files against
# 237).
#
# WHY MEDIAN-SIDE AGREEMENT AND NOT A CORRELATION COEFFICIENT. At n=6 a Pearson r is a
# number with a false amount of authority attached; its confidence interval at that n
# spans most of [-1,1]. What a small window can honestly answer is a SIGN question: when
# this run's probe sat below the window's typical reading, did its corpus sit below too?
# That is countable, it degrades gracefully as the window grows, and it does not require
# assuming a linear relationship nobody has established.
#
# THE DIRECTION THAT COSTS SOMEBODY A RED has its own name here. Because the scale clamp
# floors at 100%, a probe reading FAST can never widen the cap. So a run with a fast
# probe and a slow corpus is not merely discordant — it is UNPROTECTED: the mechanism was
# live, the corpus needed the relief, and the input guaranteed none arrived. Those are
# the runs to count.
#
# NOT WIRED TO CI, DELIBERATELY, AND THE GAP IS NAMED RATHER THAN PAPERED OVER: a
# window needs reports to OUTLIVE the run that wrote them, and today they do not
# persist. Wiring this means uploading the report as an artifact (or appending to a
# series on main) and reading N back — a separate change with its own retention
# question. Until then this is the instrument a human points at downloaded reports, and
# `--strict` is off by default because at n=6 with one anomaly, gating would encode a
# verdict the data does not yet support (DIVE-2736 says so explicitly: n=1 on the
# anti-correlation, do not bake it into a constant).
#
#   scripts/tier-cal-window.sh report1.txt report2.txt ...   [--strict] [--min-runs=N]
#
# Exit: 0 read and reported | 2 could not read a window | 7 --strict and the window
# FAILS the correlation assertion (discordant outnumber concordant).
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 2
# shellcheck source=tests/lib/tier.sh
. tests/lib/tier.sh

STRICT=0; MIN_RUNS=3; FILES=()
for a in "$@"; do case "$a" in
  --strict) STRICT=1 ;;
  # A window of two has no interior and its median is one of its own endpoints, so
  # "which side of typical" is not a question it can answer. Refusing under three is
  # the same fail-closed call the runner makes on an empty corpus: a verdict computed
  # from too little is worse than no verdict, because it reads exactly like one.
  --min-runs=*) MIN_RUNS="${a#--min-runs=}" ;;
  -*) printf 'unknown arg: %s\n' "$a" >&2; exit 2 ;;
  *) FILES+=("$a") ;;
esac; done

[[ "$MIN_RUNS" =~ ^[0-9]+$ ]] && (( MIN_RUNS >= 3 )) || {
  printf 'tier-cal-window: --min-runs must be an integer >= 3, got %s\n' "$MIN_RUNS" >&2; exit 2; }
(( ${#FILES[@]} )) || {
  printf 'usage: tier-cal-window.sh <run-harnesses report>... [--strict] [--min-runs=N]\n' >&2; exit 2; }

field() { # field <file> <key> -> value, empty if absent
  local v; v="$(grep -m1 "^# $2=" "$1" 2>/dev/null)" || true
  printf '%s\n' "${v#*=}"
}

declare -a LBL=() CAL=() LOAD=() POST=() DELTA=() HN=() WALL=()
skipped=0; skipnames=""
for f in "${FILES[@]}"; do
  if [[ ! -r "$f" ]]; then skipped=$((skipped+1)); skipnames="$skipnames $f(unreadable)"; continue; fi
  _st="$(field "$f" cal_status)"; _cal="$(field "$f" cal_us_per_iter)"
  _h="$(field "$f" harnesses)";   _w="$(field "$f" wall_clock_s)"
  # A run whose probe was never taken carries no ratio, and folding it in as a zero
  # would drag the median toward a reading that does not exist.
  if [[ "$_st" != "measured" && "$_st" != "injected" ]]; then
    skipped=$((skipped+1)); skipnames="$skipnames $(basename "$f")(cal_status=${_st:-absent})"; continue
  fi
  if ! [[ "$_cal" =~ ^[0-9]+$ && "$_h" =~ ^[0-9]+$ && "$_w" =~ ^[0-9]+$ ]] || (( _cal <= 0 || _h <= 0 )); then
    skipped=$((skipped+1)); skipnames="$skipnames $(basename "$f")(incomplete)"; continue
  fi
  LBL+=("$(field "$f" label)/$(field "$f" tier)")
  CAL+=("$_cal"); HN+=("$_h"); WALL+=("$_w")
  LOAD+=("$(( _w * 1000000 / _h ))")
  _p="$(field "$f" cal_post_us_per_iter)"; [[ "$_p" =~ ^[0-9]+$ ]] || _p=0
  _d="$(field "$f" cal_post_delta_pct)";   [[ "$_d" =~ ^-?[0-9]+$ ]] || _d=0
  POST+=("$_p"); DELTA+=("$_d")
done

n=${#CAL[@]}
if (( n < MIN_RUNS )); then
  printf 'tier-cal-window: UNDETERMINED — %d usable run(s), need %d.\n' "$n" "$MIN_RUNS" >&2
  (( skipped )) && printf 'tier-cal-window: skipped%s\n' "$skipnames" >&2
  printf 'A window this short cannot say which side of typical a run sat on. This is exit 2,\n' >&2
  printf 'not a pass: nothing here says the probe tracks the corpus, and nothing says it does not.\n' >&2
  exit 2
fi

med() { # med <values...> -> lower median
  printf '%s\n' "$@" | sort -n | sed -n "$(( (${#@} + 1) / 2 ))p"
}
mcal="$(med "${CAL[@]}")"; mload="$(med "${LOAD[@]}")"

printf 'tier-cal-window: %d run(s), median probe %dus/iter, median corpus %dus/harness\n' \
  "$n" "$mcal" "$mload"
(( skipped )) && printf 'tier-cal-window: skipped %d —%s\n' "$skipped" "$skipnames"
printf '\n%-22s %5s %6s %11s %11s %11s %7s  %s\n' \
  RUN HARN WALL_S US/HARN CAL_US POST_US DELTA% VERDICT

conc=0; disc=0; unprot=0; neutral=0
for i in "${!CAL[@]}"; do
  cs=0; (( CAL[i]  > mcal ))  && cs=1;  (( CAL[i]  < mcal ))  && cs=-1
  ls=0; (( LOAD[i] > mload )) && ls=1;  (( LOAD[i] < mload )) && ls=-1
  if (( cs == 0 || ls == 0 )); then v="at-median"; neutral=$((neutral+1))
  elif (( cs == ls )); then v="concordant"; conc=$((conc+1))
  else
    disc=$((disc+1))
    if (( cs < 0 && ls > 0 )); then v="UNPROTECTED"; unprot=$((unprot+1))
    else v="discordant"; fi
  fi
  printf '%-22s %5d %6d %11d %11d %11d %+7d  %s\n' \
    "${LBL[$i]}" "${HN[$i]}" "${WALL[$i]}" "${LOAD[$i]}" "${CAL[$i]}" "${POST[$i]}" "${DELTA[$i]}" "$v"
done

printf '\nconcordant %d | discordant %d (of which UNPROTECTED %d) | at-median %d\n' \
  "$conc" "$disc" "$unprot" "$neutral"
printf 'CONCORDANT = probe and corpus sat on the SAME side of the window median, which is the\n'
printf 'relative budget doing what DIVE-2710 assumed. DISCORDANT = opposite sides. UNPROTECTED is\n'
printf 'the discordant half that costs somebody a red: probe below median (reads FAST, so the\n'
printf 'clamp floors the scale at 100%% and the cap cannot widen) while the corpus sat above it.\n'

if (( unprot )); then
  printf '\ntier-cal-window: %d UNPROTECTED run(s). On each, the mechanism was live and applied no\n' "$unprot"
  printf 'relief to a corpus that was running slow. Check cal_post_us_per_iter on those rows: a post\n'
  printf 'probe SLOWER than its pre probe says the pre-probe sampled the wrong moment (TEMPORAL,\n'
  printf 'remedy = bracket the corpus); one that AGREES leaves the cost-mix reading (trap 3 in\n'
  printf 'tests/lib/tier.sh) on the table — weakly, because the corpus warms what the probe pays\n'
  printf 'for and that biases the post reading fast.\n'
fi

if (( STRICT )); then
  if (( disc > conc )); then
    printf '\ntier-cal-window: FAIL (--strict) — %d discordant against %d concordant. Across this\n' "$disc" "$conc"
    printf 'window the probe does not track the corpus, so the budget is not spending a ratio; it is\n'
    printf 'dividing two numbers that move independently. Exit 7.\n'
    exit 7
  fi
  printf '\ntier-cal-window: PASS (--strict) — %d concordant against %d discordant.\n' "$conc" "$disc"
fi
exit 0
