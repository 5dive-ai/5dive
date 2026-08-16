#!/usr/bin/env bash
# DIVE-3477: HAS THE CORE CORPUS GOT DEARER PER HARNESS? — the firing half of the
# growth metric that main's ruling attached to the core-tier shard.
#
# WHAT FORCED THIS, AND IT IS THE SAME SHAPE TWICE. A time budget on a variable
# platform measures the runner. The core tier answered a 300s cap by SHARDING, which
# restores headroom — and restored headroom is precisely how corpus growth becomes
# invisible again: two jobs reporting 157s read as comfortable while the corpus still
# costs 313s. So the shard landed with a condition: a number that does NOT move when
# capacity does. `core-budget-report` emits it every run, one line per environment:
#
#     core_us_per_harness <environment> <us> <harnesses> <shards> ref=<r> pct_of_ref=<p>
#
# THIS SCRIPT IS THE OTHER HALF, AND THE SPLIT IS THE WHOLE DESIGN. main asked to "find
# out on the run it climbs". A single raw run cannot deliver that and saying so is not a
# softening of the condition — measured on main, 6 un-sharded runs across three hours in
# which the corpus moved by TWO harnesses:
#
#     pristine         935483 .. 1148867 us/harness    draws  94 .. 125%
#     installed-host   883495 .. 1151612 us/harness
#
# and main2's 137-point census over five days puts the draw span at 74-141%. A per-run
# threshold against a fixed reference would therefore fire on the runner, constantly, and
# an alarm that cries wolf is muted — which is how the signal is lost a SECOND way. So:
# the per-run figure is EMITTED raw and unadjusted, exactly as specified, and the FIRING
# decision is taken here, on the MEDIAN of a window, which is what survives that spread.
#
# WHY A MEDIAN AND NOT A MEAN, and why a sign-style read rather than a ratio with
# decimals: the same reasoning scripts/tier-cal-window.sh states at length. One
# pathologically slow runner should not move the verdict, and at n=5-15 a ratio carries
# more authority than the sample can support. Compare the window's middle against a fixed
# reference and report which side it fell.
#
# WHAT FIRING DOES. IT FILES A ROW. It does not red a build, it is not a required check,
# and it must not become one without the same weight of decision that raising the cap
# would need — main declined to create a retire/demote programme today and said the
# growth metric IS the tripwire: "if it fires, that is when a programme gets a target
# worth naming". `--strict` exists for a human or an agent that wants a non-zero exit to
# hang a filing action off; it is OFF by default and no workflow may pass it.
#
# WHAT THIS DOES NOT DO, stated because this row is about not over-reading numbers:
#   - It does not say WHY the cost rose. A dearer per-harness cost is corpus growth OR a
#     platform that got slower for everyone; distinguishing them needs the calibration
#     read, which is scripts/tier-cal-window.sh's job and deliberately not this one's.
#   - It does not read the calibration clamp, on purpose (see tests/lib/tier.sh).
#
# TWO INPUT SHAPES, because the window has two sources and only one of them is bounded by
# artifact retention:
#
#   core-unsharded-total.txt   the artifact core-budget-report uploads, one per run,
#                              carrying the `core_us_per_harness` line directly.
#   *.report                   a run-harnesses report, INCLUDING the ones
#                              scripts/tier-cal-harvest.sh rebuilds out of a CI run LOG.
#                              The metric is recomputed here from `# wall_clock_s=` and
#                              `# harnesses=`, summed across the shards of one run, which
#                              is the same arithmetic core-budget-report does and is why
#                              it can be done anywhere. Reports are grouped into runs by
#                              the harvester's own filename convention, `<run>-<job>`,
#                              and the environment comes from `# label=` with its `-sN`
#                              shard suffix stripped.
#
# The second shape is what makes a window assemblable over HISTORY rather than only over
# whatever artifacts have not expired — the finding tier-cal-harvest.sh was written for.
#
#   scripts/core-growth-tripwire.sh <file> ...  [--strict] [--min-runs=N]
#
#   From artifacts (one file per run):
#     for id in $(5dive gh --as=bot api "repos/5dive-ai/5dive/actions/runs?branch=main&per_page=40" \
#                   --jq '.workflow_runs[]|select(.name=="unit-tests")|.id'); do
#       5dive gh --as=bot run download "$id" -R 5dive-ai/5dive -p core-unsharded-total -D "w/$id"
#     done
#     scripts/core-growth-tripwire.sh w/*/core-unsharded-total.txt
#
#   From run logs, no retention limit:
#     scripts/tier-cal-harvest.sh --last=15 --branch=main --out=w
#     scripts/core-growth-tripwire.sh w/*.report
#
# Exit: 0 read and reported | 2 could not read a window | 7 --strict and at least one
# environment's window median has cleared the reference.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 2
# shellcheck source=tests/lib/tier.sh
. tests/lib/tier.sh

STRICT=0
MIN_RUNS="$TIER_CORE_GROWTH_MIN_RUNS"
FILES=()
for a in "$@"; do case "$a" in
  --strict) STRICT=1 ;;
  --min-runs=*) MIN_RUNS="${a#--min-runs=}" ;;
  -*) printf 'unknown flag: %s\n' "$a" >&2; exit 2 ;;
  *) FILES+=("$a") ;;
esac; done

if (( ${#FILES[@]} == 0 )); then
  printf 'usage: %s <core-unsharded-total.txt> ... [--strict] [--min-runs=N]\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

# A window of two has no interior and its median is one of its own endpoints, so "did the
# middle clear the reference" is not a question it can answer. Refusing under the floor is
# the same fail-closed call the runner makes on an empty corpus: a verdict computed from
# too little reads exactly like one computed from enough.
if ! [[ "$MIN_RUNS" =~ ^[0-9]+$ ]] || (( MIN_RUNS < 3 )); then
  printf '--min-runs must be an integer >= 3 (a median needs an interior); got %s\n' "$MIN_RUNS" >&2
  exit 2
fi

median() {   # values on stdin, one per line
  sort -n | awk '{a[NR]=$1} END{
    if (NR == 0) exit 1
    if (NR % 2) printf "%d\n", a[(NR+1)/2]
    else printf "%d\n", int((a[NR/2] + a[NR/2+1]) / 2)
  }'
}

printf 'core corpus growth — window of %d file(s), fires at %d%% of reference, median of >= %d runs\n\n' \
  "${#FILES[@]}" "$TIER_CORE_GROWTH_FIRE_PCT" "$MIN_RUNS"

rc=0
fired=0
read_any=0
for env in pristine installed-host; do
  vals=()
  declare -A rep_s=() rep_n=()
  for f in "${FILES[@]}"; do
    [[ -r "$f" ]] || continue
    # ONE reading per FILE, not per line: a file is a run, and a run that somehow carried
    # the environment twice must not vote twice in its own window.
    v="$(awk -v e="$env" '$1 == "core_us_per_harness" && $2 == e { print $3; exit }' "$f")"
    if [[ -n "$v" ]]; then vals+=("$v"); continue; fi
    # A run-harnesses report instead. Recompute rather than require the emitting job to
    # have run: the arithmetic is sum(wall)/sum(harnesses) over one run's shards, and a
    # window assembled from harvested logs is the only window that reaches back past
    # artifact retention.
    lab="$(sed -n 's/^# label=//p' "$f" | head -1)"
    [[ -n "$lab" ]] || continue
    [[ "${lab%-s[0-9]*}" == "$env" ]] || continue
    ws="$(sed -n 's/^# wall_clock_s=//p' "$f" | head -1)"
    hn="$(sed -n 's/^# harnesses=//p' "$f" | head -1)"
    [[ "$ws" =~ ^[0-9]+$ && "$hn" =~ ^[0-9]+$ ]] || continue
    # The harvester names its files `<run>-<job>.report`, so the leading run id is what
    # groups two shards of ONE run. A file that does not carry one is its own run, which
    # is the safe reading: it can only make the window LARGER in points and never merge
    # two different runs into one.
    key="$(basename -- "$f")"; key="${key%%-*}"
    [[ "$key" =~ ^[0-9]+$ ]] || key="$f"
    rep_s["$key"]=$(( ${rep_s["$key"]:-0} + ws ))
    rep_n["$key"]=$(( ${rep_n["$key"]:-0} + hn ))
  done
  for key in "${!rep_s[@]}"; do
    (( rep_n["$key"] > 0 )) || continue
    vals+=("$(tier_core_us_per_harness "${rep_s[$key]}" "${rep_n[$key]}")")
  done
  n=${#vals[@]}
  ref="$(tier_core_us_per_harness_ref "$env")" || { printf '%s: no reference\n' "$env"; rc=2; continue; }

  if (( n < MIN_RUNS )); then
    # UNDETERMINED IS NOT CLEAR, and it is printed rather than skipped: an environment
    # that silently drops out of the window is an environment nobody is watching.
    printf '%-15s UNDETERMINED — %d run(s) carry a figure, fewer than the %d a median needs. Reference %d us/harness.\n' \
      "$env" "$n" "$MIN_RUNS" "$ref"
    continue
  fi
  read_any=1
  med="$(printf '%s\n' "${vals[@]}" | median)"
  lo="$(printf '%s\n' "${vals[@]}" | sort -n | head -1)"
  hi="$(printf '%s\n' "${vals[@]}" | sort -n | tail -1)"
  pct=$(( med * 100 / ref ))
  over=0
  (( pct >= TIER_CORE_GROWTH_FIRE_PCT )) && over=1
  verdict=CLEAR
  (( over )) && verdict=FIRED
  printf '%-15s %-5s median %d us/harness over %d runs (range %d..%d) — %d%% of reference %d\n' \
    "$env" "$verdict" "$med" "$n" "$lo" "$hi" "$pct" "$ref"
  if (( over )); then
    fired=1
    printf '                FILE A ROW. The window middle has cleared the reference by %d points, which is beyond the per-run draw spread this threshold was set above. That is a corpus that costs more per harness than it did on 2026-08-16, not a slow runner.\n' \
      "$(( pct - TIER_CORE_GROWTH_FIRE_PCT ))"
    printf '                It does NOT red this or any build, and it is not authority to raise a cap or to start a retire programme — it is the trigger for asking for one, with a number attached.\n'
  fi
done

if (( ! read_any )); then
  printf '\nno environment had a window worth reading — check that the files carry `core_us_per_harness` lines at all.\n'
  exit 2
fi

if (( fired && STRICT )); then
  exit 7
fi
exit "$rc"
