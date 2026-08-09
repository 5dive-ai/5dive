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
#   6  UNDETERMINED (DIVE-2728). The budget could not be GRADED: the calibration
#      probe could not run, or the runner drew so far outside its clamp that the
#      scaled cap would license an arbitrarily larger corpus. NOT 4, and the
#      distinction is the whole point of the row: "the corpus is over its cap" and
#      "this box cannot measure that cap" are different events, and folding the
#      second into the first is what DIVE-2667 was. Not 0 either — a run that could
#      not measure has not passed (DIVE-2555).
#   2  usage
#
# THE BUDGET IS RELATIVE (DIVE-2728). The cap in tests/lib/tier.sh is spent in units
# of a calibration workload run in this same job, so a uniformly slow VM scales both
# sides and cancels. The full argument, the three traps and every constant live next
# to the numbers in tests/lib/tier.sh; the mechanics are below. Calibration time is
# NOT part of total_s and the report says so.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 2

# DIVE-3077 — RAISE A SIGNAL THE BOARD-WRITE FENCE READS. `_task_human_send_allowed`
# (DIVE-1506) has refused on FIVEDIVE_TEST since it was written; measured across the
# 344-harness corpus on 2026-08-09, FIVEDIVE_TEST was set by ZERO files and
# FIVEDIVE_E2E by ZERO. A control that reads a flag nobody sets is not a weak
# control, it is an absent one wearing a control's shape — which is why 98 fixture
# rows reached the prod board in one day (DIVE-3075).
#
# THE FIX IS ONE PLACE, NOT 344. Asking harness authors to set a marker is opt-OUT
# of production and needs every author to remember; two stores have now proved they
# do not. Setting it in the runner covers every harness including ones not yet
# written, and inverts the default to opt-IN to production: only an invocation that
# bypasses this script can reach the prod board at all.
#
# WHY THIS IS NOT `export FIVEDIVE_TEST=1`, which is what DIVE-3077 was filed asking
# for and was MEASURED not to work. FIVEDIVE_TEST is read by
# `_task_human_send_allowed`, where it forces refuse REGARDLESS of store path. But 29
# harnesses point FIVEDIVE_PROD_TASKS_DB at their own fixture store precisely so they
# can exercise that predicate's ALLOWED arm — simulating prod is their job. Exporting
# FIVEDIVE_TEST here flips all of them to refuse. Measured on this branch, 2026-08-09:
# 0/29 fail without the marker, 25/29 fail with it. Re-using the send rail's sentinel
# for the write rail overloads one flag with two incompatible meanings, so the write
# rail gets its own.
#
# KNOWN LIMIT, recorded rather than smoothed: this assumes the runner is the only
# path to a harness. `bash tests/foo.sh` by hand bypasses it. That gap is real and
# smaller — one person at a keyboard, not a nightly fleet — so this marker is a
# FLOOR, not a proof. The durable fix in that direction is a writer-set scope column
# as provenance (DIVE-3075), not a name match on the title.
export FIVEDIVE_HARNESS=1
# shellcheck source=tests/lib/tier.sh
. tests/lib/tier.sh

TIER=""; BUDGET=""; LABEL=""; REPORT=""; TOP=10; CORPUS_DIR="tests"; SHARD=""
# DIVE-2592: how many of the slowest harnesses a BUDGET RED is allowed to re-time
# before it claims the corpus is over its cap. See the block below the run loop.
CONFIRM_TOP=3
# DIVE-2728 calibration. CALIBRATE=1 means MEASURE this runner before spending the
# budget on it; the flags below are seams, not policy, and each carries its own note.
CALIBRATE=1; CAL_US_IN=""; CAL_BASELINE_US=""; CAL_CLI="./5dive"
# DIVE-2736. CAL_POST=1 means take a SECOND probe after the corpus. It is a
# discriminator, not an input to the verdict — see the block after the run loop.
CAL_POST=1; CAL_POST_US_IN=""
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
  # DIVE-2592. Unlike --budget, this is NOT a hatch: the confirmation pass can only
  # ever REMOVE a red, so lowering it (0 disables it entirely) can only make this gate
  # STRICTER, which is the one direction an override is allowed to move a control in.
  # There is deliberately no flag that lets a caller confirm MORE than the runner does.
  --confirm-top=*) CONFIRM_TOP="${a#--confirm-top=}" ;;
  # DIVE-2728 seams. --no-calibrate falls back to the RAW cap, and that is the one
  # direction an override is allowed to move this control: the clamp floor is 1.0, so
  # the scaled cap is never SMALLER than the raw one and turning calibration off can
  # only make the gate STRICTER (same argument as --confirm-top). It exists for a
  # laptop with no built bundle, and for every arm of the harness that grades the
  # ABSOLUTE machinery and must not pay 20s of probe to do it.
  --no-calibrate) CALIBRATE=0 ;;
  # Inject the measurement instead of taking it, in MICROSECONDS PER ITERATION. This
  # is how the harness drives the timing arms: a test that MEASURES its own durations
  # grades the runner it happens to be on, which is the defect this row is fixing
  # (DIVE-2555 §4). A workflow SHOULD NOT pass either of these — same reason --budget
  # exists and is not passed: the policy belongs beside the tier definition. Abuse is
  # bounded by the clamp (at most 1.5x, and past it the run is UNDETERMINED, not
  # green), but it is still an override and it is still logged as `injected`.
  --cal-us=*) CAL_US_IN="${a#--cal-us=}" ;;
  --cal-baseline-us=*) CAL_BASELINE_US="${a#--cal-baseline-us=}" ;;
  # Which binary the probe spawns. The probe must pay the CLI's own startup because
  # that is what the corpus pays; pointing this at a path that does not exist is how
  # the harness grades the fail-closed arm.
  --cal-cli=*) CAL_CLI="${a#--cal-cli=}" ;;
  # DIVE-2736 seams. The post-corpus probe costs another ~20s of job time and grades
  # NOTHING, so --no-cal-post exists for anyone who wants the old cost; it cannot move a
  # verdict in either direction, which is the whole point of it. --cal-post-us= injects
  # the second reading for the same reason --cal-us= injects the first.
  --no-cal-post) CAL_POST=0 ;;
  --cal-post-us=*) CAL_POST_US_IN="${a#--cal-post-us=}" ;;
  --top=*)    TOP="${a#--top=}" ;;
  *) printf 'unknown arg: %s\n' "$a" >&2; exit 2 ;;
esac; done

case "$TIER" in
  core|full) ;;
  *) printf 'usage: run-harnesses.sh --tier=core|full [--budget=<seconds>] [--label=<env>] [--report=<file>] [--corpus-dir=<dir>] [--confirm-top=<n>] [--no-calibrate] [--cal-us=<us/iter>] [--cal-baseline-us=<us/iter>] [--cal-cli=<path>] [--no-cal-post] [--cal-post-us=<us/iter>]\n' >&2; exit 2 ;;
esac
[[ "$CONFIRM_TOP" =~ ^[0-9]+$ ]] || { printf 'run-harnesses: --confirm-top must be a non-negative integer, got %s\n' "$CONFIRM_TOP" >&2; exit 2; }
[[ -n "$BUDGET" ]] || BUDGET="$(tier_budget "$TIER")" || exit 2
[[ -n "$LABEL" ]] || LABEL="local"
[[ -n "$CAL_BASELINE_US" ]] || CAL_BASELINE_US="$TIER_CAL_BASELINE_US"
for _v in CAL_US_IN:"$CAL_US_IN" CAL_BASELINE_US:"$CAL_BASELINE_US" CAL_POST_US_IN:"$CAL_POST_US_IN"; do
  [[ -z "${_v#*:}" || "${_v#*:}" =~ ^[0-9]+$ ]] || {
    printf 'run-harnesses: --%s must be a non-negative integer of microseconds, got %s\n' \
      "$(tr 'A-Z_' 'a-z-' <<<"${_v%%:*}")" "${_v#*:}" >&2; exit 2; }
done
(( CAL_BASELINE_US > 0 )) || { printf 'run-harnesses: calibration baseline must be > 0, got %s\n' "$CAL_BASELINE_US" >&2; exit 2; }

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

# ---------------------------------------------------------------------------------
# DIVE-2728: CALIBRATE THE RUNNER BEFORE SPENDING THE BUDGET ON IT.
#
# Runs ONCE, in this job, immediately before the corpus, timed exactly the way the
# harnesses are. Its time is NOT added to total_ms — the cap is on the corpus, and a
# probe that spent the corpus's budget would be a tax for the privilege of measuring.
#
# THE PROBE'S SHAPE IS THE LOAD-BEARING CHOICE (trap 3 in tests/lib/tier.sh): process
# spawn, bash startup, the built CLI's own startup, small file write+read. That is
# what these harnesses actually cost. A CPU spin would have been shorter to write and
# would calibrate a dimension the corpus barely pays for, so it would track a draw the
# corpus does not feel — a probe can be perfectly precise about the wrong thing.
#
# AUTO-SIZED TO A TIME TARGET, NOT TO A FIXED ITERATION COUNT, and reported PER
# ITERATION. A fixed count is a probe whose DURATION depends on the box, which is
# exactly the noise being removed; sampling to ~TIER_CAL_TARGET_MS makes the sample
# long enough that its own relative error sits under the headroom being protected,
# and normalising to us/iteration keeps the unit comparable between two runs that did
# different counts. Min of TIER_CAL_SAMPLES, on DIVE-2592's one-sided-noise argument.
cal_probe() { # <iters> -> elapsed ms on stdout; non-zero if the probe could not run
  local n="$1" i s e d rc=0
  d="$(mktemp -d "${TMPDIR:-/tmp}/harness-cal.XXXXXX")" || return 1
  s=$(date +%s%N)
  for (( i = 0; i < n; i++ )); do
    bash -c ':' || { rc=1; break; }
    "$CAL_CLI" --version >/dev/null 2>&1 || { rc=1; break; }
    printf 'cal %s\n' "$i" > "$d/probe" || { rc=1; break; }
    read -r _ < "$d/probe" || { rc=1; break; }
  done
  e=$(date +%s%N)
  rm -rf "$d"
  (( rc == 0 )) || return 1
  printf '%s\n' "$(( (e - s) / 1000000 ))"
}

CAL_STATUS="skipped"; CAL_US=0; CAL_ITERS=0; CAL_WHY=""
CAL_POST_STATUS="skipped"; CAL_POST_US=0; CAL_POST_DELTA=0
SCALE_RAW=100; SCALE=100
EFF_MS=$(( BUDGET * 1000 )); EFF_BUDGET="$BUDGET"
undetermined=0

if (( BUDGET > 0 )) && [[ -n "$CAL_US_IN" ]]; then
  CAL_US="$CAL_US_IN"; CAL_STATUS="injected"
elif (( BUDGET > 0 && CALIBRATE == 1 )); then
  if [[ ! -x "$CAL_CLI" ]]; then
    CAL_STATUS="failed"; CAL_WHY="no executable CLI at $CAL_CLI (run ./build.sh)"
  else
    printf 'harness-budget[%s/%s]: calibrating this runner (~%ds, NOT counted toward the corpus total)\n' \
      "$TIER" "$LABEL" "$(( TIER_CAL_TARGET_MS * TIER_CAL_SAMPLES / 1000 ))"
    # ONE UNTIMED WARM-UP ITERATION, and it is not decoration. Measured here on the
    # control plane: without it the pilot ran ~2x slow on a cold page cache, the
    # iteration count was sized from that number, and each "10s" sample came in at
    # ~5s — half the precision the target exists to buy, silently. An auto-sized
    # probe is only as long as its pilot is honest.
    cal_probe 1 >/dev/null 2>&1 || true
    if ! _pilot="$(cal_probe "$TIER_CAL_PILOT_ITERS")"; then
      CAL_STATUS="failed"; CAL_WHY="the calibration probe could not complete"
    else
      (( _pilot > 0 )) || _pilot=1
      CAL_ITERS=$(( TIER_CAL_TARGET_MS * TIER_CAL_PILOT_ITERS / _pilot ))
      (( CAL_ITERS < TIER_CAL_MIN_ITERS )) && CAL_ITERS=$TIER_CAL_MIN_ITERS
      (( CAL_ITERS > TIER_CAL_MAX_ITERS )) && CAL_ITERS=$TIER_CAL_MAX_ITERS
      _best=""
      for (( _s = 0; _s < TIER_CAL_SAMPLES; _s++ )); do
        if ! _ms="$(cal_probe "$CAL_ITERS")"; then
          CAL_STATUS="failed"; CAL_WHY="the calibration probe could not complete"; _best=""; break
        fi
        _us=$(( _ms * 1000 / CAL_ITERS )); (( _us > 0 )) || _us=1
        if [[ -z "$_best" ]] || (( _us < _best )); then _best="$_us"; fi
      done
      if [[ -n "$_best" ]]; then CAL_US="$_best"; CAL_STATUS="measured"; fi
    fi
  fi
fi

if [[ "$CAL_STATUS" == "measured" || "$CAL_STATUS" == "injected" ]]; then
  SCALE_RAW="$(tier_cal_scale_pct "$CAL_US" "$CAL_BASELINE_US")" || exit 2
  SCALE="$(tier_cal_clamp_pct "$SCALE_RAW")"
  EFF_MS=$(( BUDGET * 1000 * SCALE / 100 ))
  EFF_BUDGET=$(( EFF_MS / 1000 ))
  # TRAP 2, enforced: past the clamp the scaled cap would license an arbitrarily
  # larger corpus, so the run is UNDETERMINED rather than generously green. Resolved
  # at the exit ladder, not here, so a genuinely FAILING harness still dominates and
  # still exits 1 — "the box was slow" must never hide a broken test.
  if (( SCALE_RAW > TIER_CAL_SCALE_MAX_PCT )); then
    undetermined=1
    CAL_WHY="this runner drew ${SCALE_RAW}% of baseline, past the ${TIER_CAL_SCALE_MAX_PCT}% clamp"
  fi
elif (( BUDGET > 0 && CALIBRATE == 1 )); then
  # TRAP-ADJACENT, and the arm most likely to be written the lazy way: a probe that
  # cannot run must FAIL CLOSED. "Calibration unavailable, falling back to the raw
  # cap" sounds harmless and is the free escape hatch DIVE-2525 closed, one rename
  # later. --no-calibrate is the deliberate, logged way to ask for the raw cap.
  undetermined=1
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
# DIVE-2728: pct stays the percentage of the RAW cap and keeps its name — budget-report
# and every trend reader parse it by name, and it is still the number that answers "did
# the corpus grow". eff_pct is the one the VERDICT is taken on. Printing both, side by
# side, is what lets a reader tell "the corpus grew" from "the VM was slow" without
# leaving the log; DIVE-2710 §2.4 calls that separation the actual product here.
pct=0; (( BUDGET > 0 )) && pct=$(( total_s * 100 / BUDGET ))
eff_pct=0; (( EFF_MS > 0 )) && eff_pct=$(( total_ms * 100 / EFF_MS ))

# ---------------------------------------------------------------------------------
# DIVE-2736: PROBE THE RUNNER AGAIN, ON THE OTHER SIDE OF THE CORPUS.
#
# The pre-corpus probe is a ~20s POINT SAMPLE standing in for a ~6-minute integral. On
# run 30967674559 those two disagreed by 30% in the direction that guarantees no relief:
# probe fast, corpus slow, scale clamped to the floor, exit 4 on a run the mechanism was
# built to rescue. Nothing in the runner noticed, because nothing was looking — a ratio
# whose halves can move in opposite directions is not a ratio, and there was no second
# measurement to compare the first against.
#
# THIS IS A DISCRIMINATOR AND IT GRADES NOTHING. It does not enter SCALE, EFF_MS, the
# verdict or the exit code, and the arm in tests/corpus_tier_budget_unit.sh that proves
# so is the load-bearing one: shipping a remedy on n=1 evidence is how DIVE-2710's
# premise got into the tree unmeasured in the first place. What it produces is the pair
# of readings, on every run, in the report — so the question "does the probe track the
# corpus" becomes answerable from logs instead of arguable from priors
# (scripts/tier-cal-window.sh does the across-runs read).
#
# SAME ITERATION COUNT, SAME MIN-OF-N, on purpose. A cheaper post probe — one sample
# instead of min-of-two — would read systematically SLOWER than the pre probe for a
# reason that is arithmetic rather than weather, and would manufacture exactly the
# divergence it was added to detect. Two estimators are only comparable when they are
# the same estimator.
#
# AND IT ONLY RUNS WHEN THE PRE PROBE WAS MEASURED. Comparing a measured post against an
# INJECTED pre would be comparing this runner against a number the harness typed.
if [[ -n "$CAL_POST_US_IN" ]]; then
  CAL_POST_US="$CAL_POST_US_IN"; CAL_POST_STATUS="injected"
elif (( CAL_POST == 1 )) && [[ "$CAL_STATUS" == "measured" ]] && (( CAL_ITERS > 0 )); then
  printf '\nharness-budget[%s/%s]: re-calibrating AFTER the corpus (~%ds, NOT counted toward the\n' \
    "$TIER" "$LABEL" "$(( TIER_CAL_TARGET_MS * TIER_CAL_SAMPLES / 1000 ))"
  printf '  corpus total, and NOT used to grade this run — it is the discriminator, DIVE-2736)\n'
  _best=""
  for (( _s = 0; _s < TIER_CAL_SAMPLES; _s++ )); do
    if ! _ms="$(cal_probe "$CAL_ITERS")"; then
      CAL_POST_STATUS="failed"; _best=""; break
    fi
    _us=$(( _ms * 1000 / CAL_ITERS )); (( _us > 0 )) || _us=1
    if [[ -z "$_best" ]] || (( _us < _best )); then _best="$_us"; fi
  done
  if [[ -n "$_best" ]]; then CAL_POST_US="$_best"; CAL_POST_STATUS="measured"; fi
fi
if [[ "$CAL_POST_STATUS" == "measured" || "$CAL_POST_STATUS" == "injected" ]] && (( CAL_US > 0 )); then
  CAL_POST_DELTA="$(tier_cal_diverge_pct "$CAL_US" "$CAL_POST_US")" || CAL_POST_DELTA=0
fi

# ---------------------------------------------------------------------------------
# DIVE-2592: A BUDGET RED CONFIRMS ITSELF BEFORE IT CLAIMS ANYTHING.
#
# THE MEASUREMENT THAT FORCED THIS is a RE-RUN OF THE SAME COMMIT. PR #395 — one line
# of code and two test arms — went red on exit 4 with zero assertion failures. Same
# head, no rebase, nothing changed between the two attempts:
#
#     attempt 1   core/pristine   209 harnesses   356s   118% of budget   FAIL
#     attempt 2   core/pristine   209 harnesses   289s    96% of budget   PASS
#
# and the whole 67s lived in ONE file: tests/baseline_pin_unit.sh, 57.5s on main and
# 174.1s on that attempt, because it resolves pinned baseline COMMITS against the
# remote and is therefore priced by the network rather than by its assertions.
#
# A verdict that flips on a re-run of the same tree is not a measurement of the
# corpus, and the red it produces is unactionable in the worst way: to the author it
# reads as systemic (it appeared right after a runner change merged) and to the next
# reader it reads as flake. Both are wrong and NO SINGLE RUN CAN SHOW THAT.
#
# The cap is not the defect. 300s is lodar's number and the corpus really does sit at
# 96% of it — raising it to 450 buys three weeks and re-installs the ratchet DIVE-2525
# exists to remove. THE COMPARISON is the defect: one noisy sample against a hard
# threshold, on a base with no headroom, reds at random on content it did not measure.
#
# So when the sum comes in over, re-time the few harnesses that dominate it and keep,
# per file, the SMALLER of the two samples. Noise here is ONE-SIDED — contention, a
# cold cache and a slow remote can only ADD time, never subtract it — so the low
# sample is the least contaminated estimate of what the file costs, while real corpus
# growth appears in BOTH samples and survives untouched. The gate keeps its teeth and
# loses its coin flip.
#
# PAID ONLY ON THE RED PATH, and bounded twice: at most CONFIRM_TOP files, and it
# stops the moment the recomputed total is back inside the cap. A green run re-times
# nothing, so the common case costs zero.
#
# IT RUNS BEFORE THE DRIFT GRADER ON PURPOSE. A header's claimed number should be
# graded against the same confirmed measurement, or a network spike gets a harness
# author accused of writing an optimistic figure (DIVE-2555, exit 5).
#
# THE RE-RUN IS NOT REDIRECTED. Sending it to /dev/null would make the second sample
# structurally faster than the first for a reason that is not noise, and min-of-two is
# only honest between two samples taken the same way.
#
# A HARNESS THAT FAILS ITS RE-RUN keeps its original timing AND its original pass: the
# graded run is the first one, and flipping a pass to a fail on a second sample is
# this same one-sample error inverted.
#
# WHAT THAT EVENT IS, AND WHAT IT IS NOT (olivia, grading DIVE-2592). Two runs
# disagreeing is OBSERVED. Calling it a flaky harness is INFERRED, and it is only one
# of at least three candidates: the harness may be non-deterministic, or the FIRST run
# may have left state the second tripped on, or the runner changed underneath both. A
# guess printed among measured sentences inherits their authority, so the output says
# which half is which rather than naming a cause it did not measure.
# ---------------------------------------------------------------------------------
# DIVE-2728: the confirmation now triggers on, and stops at, the EFFECTIVE cap. It has
# to: re-timing the top-N against the raw cap on a runner that was granted a scaled one
# would re-time files it no longer needs to, and would keep going after the run is
# already inside the cap it is actually graded against.
first_total_s="$total_s"; first_pct="$pct"; confirmed=0
declare -a SWING=() FLAKED=()
if (( BUDGET > 0 && total_ms > EFF_MS && ${#failed[@]} == 0 && CONFIRM_TOP > 0 )); then
  confirmed=1
  printf '\nharness-budget[%s/%s]: %ds is over the %ds cap ON ONE SAMPLE. Re-timing the slowest\n' \
    "$TIER" "$LABEL" "$total_s" "$EFF_BUDGET"
  printf 'harness(es) before claiming it — a wall-clock red that flips on a re-run of the same\n'
  printf 'commit measures the runner, not the corpus (DIVE-2592).\n'
  mapfile -t _order < <(for i in "${!NAME[@]}"; do printf '%s\t%s\n' "${MS[$i]}" "$i"; done | sort -rn | cut -f2)
  _n=0
  for i in "${_order[@]}"; do
    (( _n < CONFIRM_TOP )) || break
    (( total_ms > EFF_MS )) || break
    _n=$(( _n + 1 ))
    printf '=== re-timing %s (budget confirmation %d/%d)\n' "${NAME[$i]}" "$_n" "$CONFIRM_TOP"
    s=$(date +%s%N)
    bash "${NAME[$i]}"; rc2=$?
    e=$(date +%s%N)
    ms2=$(( (e - s) / 1000000 ))
    if (( rc2 != 0 )); then
      FLAKED+=("$(printf '%s\t%s' "${NAME[$i]}" "$rc2")")
      continue
    fi
    (( ms2 < MS[i] )) || continue
    SWING+=("$(printf '%s\t%s\t%s' "${NAME[$i]}" "${MS[$i]}" "$ms2")")
    total_ms=$(( total_ms - MS[i] + ms2 )); MS[$i]="$ms2"
    total_s=$(( (total_ms + 999) / 1000 )); pct=$(( total_s * 100 / BUDGET ))
    eff_pct=$(( total_ms * 100 / EFF_MS ))
  done
fi

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
    # DIVE-2592: wall_clock_s stays the ENFORCED number and keeps its name and place —
    # budget-report and every future reader parse by field name. The first sample is
    # appended beside it, because the SPREAD between the two is the trend that matters
    # now: a corpus whose confirmed and unconfirmed totals diverge is one whose cost is
    # being set by the runner rather than by its own assertions.
    printf '# run-harnesses report\n# tier=%s\n# label=%s\n# shard=%s\n# harnesses=%d\n# wall_clock_s=%d\n# budget_s=%d\n# pct_of_budget=%d\n# header_drift=%d\n# first_pass_wall_clock_s=%d\n# budget_confirmed=%d\n# confirm_reclaimed_s=%d\n' \
      "$TIER" "$LABEL" "${SHARD:-1/1}" "${#CORPUS[@]}" "$total_s" "$BUDGET" "$pct" "${#drift[@]}" \
      "$first_total_s" "$confirmed" "$(( first_total_s - total_s ))"
    # DIVE-2728. APPENDED, never substituted: wall_clock_s / budget_s / pct_of_budget
    # keep their names and their meaning because budget-report and the trend readers
    # parse by field name (the same rule DIVE-2592 followed). The calibration is a new
    # set of fields beside them, and cal_us_per_iter is the one to re-baseline from.
    printf '# cal_status=%s\n# cal_us_per_iter=%d\n# cal_baseline_us_per_iter=%d\n# cal_iters=%d\n# cal_scale_pct=%d\n# cal_scale_pct_applied=%d\n# effective_budget_s=%d\n# pct_of_effective_budget=%d\n# undetermined=%d\n' \
      "$CAL_STATUS" "$CAL_US" "$CAL_BASELINE_US" "$CAL_ITERS" "$SCALE_RAW" "$SCALE" \
      "$EFF_BUDGET" "$eff_pct" "$undetermined"
    # DIVE-2736: appended for the same reason, and these three are the ones that make
    # "did the probe track the corpus" answerable ACROSS runs rather than argued within
    # one. cal_post_delta_pct is SIGNED — positive is the runner slower after the corpus
    # than before it. scripts/tier-cal-window.sh reads exactly these fields plus
    # wall_clock_s and harnesses.
    printf '# cal_post_status=%s\n# cal_post_us_per_iter=%d\n# cal_post_delta_pct=%d\n' \
      "$CAL_POST_STATUS" "$CAL_POST_US" "$CAL_POST_DELTA"
    for i in "${!NAME[@]}"; do printf '%s\t%s\t%s\n' "${MS[$i]}" "${RC[$i]}" "${NAME[$i]}"; done
  } > "$REPORT"
fi

# Build 3 of DIVE-2525: the number, in its own output, every run.
printf '\nharness-budget[%s/%s]: %d harnesses, %ds wall-clock, budget %ds (%d%% of budget)\n' \
  "$TIER" "$LABEL" "${#CORPUS[@]}" "$total_s" "$BUDGET" "$pct"

# DIVE-2728 §2.4 — THE REPORT IS THE ACTUAL PRODUCT, more than the pass/fail flip is.
# Both percentages on adjacent lines, because the pair is the diagnosis: raw high and
# effective low means THE VM WAS SLOW; both high means THE CORPUS GREW. Getting that
# wrong cost DIVE-2667 a day of looking for a regression in a diff worth +0.1s.
if (( BUDGET > 0 )) && [[ "$CAL_STATUS" == "measured" || "$CAL_STATUS" == "injected" ]]; then
  printf 'harness-budget[%s/%s]: CALIBRATION (%s) %dus/iter vs baseline %dus/iter = %d%% of a normal\n' \
    "$TIER" "$LABEL" "$CAL_STATUS" "$CAL_US" "$CAL_BASELINE_US" "$SCALE_RAW"
  printf '  runner; applied %d%% (clamp %d-%d%%) -> effective cap %ds. This run is %d%% of the RAW cap\n' \
    "$SCALE" "$TIER_CAL_SCALE_MIN_PCT" "$TIER_CAL_SCALE_MAX_PCT" "$EFF_BUDGET" "$pct"
  printf '  and %d%% of the EFFECTIVE cap. Raw high + effective low = the VM was slow; both high =\n' "$eff_pct"
  printf '  the corpus grew. Calibration time is NOT in the %ds above.\n' "$total_s"
  # DIVE-2710 §2.5: the baseline is a measurement with no environment attached, and
  # the runner re-measures it every run, so grading it is free. K-consecutive-run
  # confirmation is deliberately NOT done here — one run cannot see K runs, and this
  # field is in the report so budget-report can make that call across runs.
  _drift=$(( SCALE_RAW - 100 )); (( _drift < 0 )) && _drift=$(( -_drift ))
  if (( _drift >= TIER_CAL_REBASELINE_PCT )); then
    printf 'harness-budget[%s/%s]: RE-BASELINE THE CALIBRATION — the probe is %d%% off TIER_CAL_BASELINE_US\n' \
      "$TIER" "$LABEL" "$_drift"
    printf '  (>= %d%%). A runner image change is exactly the event that moves this. If this repeats on\n' "$TIER_CAL_REBASELINE_PCT"
    printf '  main, set TIER_CAL_BASELINE_US=%d in tests/lib/tier.sh, WITH the environment and date on\n' "$CAL_US"
    printf '  it — a figure with no environment cannot be refuted by the next reading (DIVE-2555).\n'
  fi
elif (( BUDGET > 0 && CALIBRATE == 0 )); then
  printf 'harness-budget[%s/%s]: CALIBRATION OFF (--no-calibrate) — graded against the RAW %ds cap.\n' \
    "$TIER" "$LABEL" "$BUDGET"
  printf '  The clamp floor is %d%%, so this is the STRICTEST this gate gets, never a relaxation.\n' "$TIER_CAL_SCALE_MIN_PCT"
fi

# DIVE-2736: the two probes, side by side, with the verdict this run supports and the
# one it does not. Printed on every calibrated run, not only on a red — the anomaly this
# exists to catch was found by comparing a PASSING run against a failing one 13 minutes
# later, and a diagnostic that only prints on the red half of that pair cannot be used
# that way.
if [[ "$CAL_POST_STATUS" == "measured" || "$CAL_POST_STATUS" == "injected" ]] && (( CAL_US > 0 )); then
  _absd=$CAL_POST_DELTA; (( _absd < 0 )) && _absd=$(( -_absd ))
  printf 'harness-budget[%s/%s]: PROBE BRACKET (DIVE-2736) pre %dus/iter -> post %dus/iter (%+d%%),\n' \
    "$TIER" "$LABEL" "$CAL_US" "$CAL_POST_US" "$CAL_POST_DELTA"
  if (( _absd < TIER_CAL_POST_DIVERGE_PCT )); then
    printf '  which AGREES (under %d%%). The runner drew the same at both ends of the corpus, so a\n' "$TIER_CAL_POST_DIVERGE_PCT"
    printf '  slow corpus on this run would NOT be explained by the probe sampling the wrong moment.\n'
    printf '  Read that as weak evidence only: the corpus just warmed the page cache and the CLI it\n'
    printf '  spawned, which biases this second reading FAST, so agreement is also what a real\n'
    printf '  slowdown masked by cache warmth looks like.\n'
  elif (( CAL_POST_DELTA > 0 )); then
    # The clean direction: the confound above pushes the post probe FASTER, so a post
    # probe that comes in SLOWER did so against it.
    _bus=$CAL_US; (( CAL_POST_US > _bus )) && _bus=$CAL_POST_US
    _braw="$(tier_cal_scale_pct "$_bus" "$CAL_BASELINE_US")"
    _bcap=$(( BUDGET * $(tier_cal_clamp_pct "$_braw") / 100 ))
    printf '  which DIVERGES (>= %d%%) with the runner SLOWER after the corpus than before it. That\n' "$TIER_CAL_POST_DIVERGE_PCT"
    printf '  is the pre-probe under-reading a draw that arrived later — a ~20s point sample standing\n'
    printf '  in for a %ds integral — and it survives the cache-warmth confound, which pushes the\n' "$total_s"
    printf '  other way. COUNTERFACTUAL, NOT APPLIED: bracketing on max(pre,post) reads %d%% of\n' "$_braw"
    printf '  baseline and would have set the cap to %ds instead of %ds. This run was graded on the\n' "$_bcap" "$EFF_BUDGET"
    printf '  PRE probe regardless; the number is here to be collected, not acted on.\n'
  else
    printf '  which DIVERGES (>= %d%%) with the runner FASTER after the corpus. Either contention\n' "$TIER_CAL_POST_DIVERGE_PCT"
    printf '  ended during the run, or the corpus warmed what the probe pays for. Both are consistent\n'
    printf '  with a pre-probe that over-read, which is the direction that costs nobody a red.\n'
  fi
elif [[ "$CAL_POST_STATUS" == "failed" ]]; then
  # NOT undetermined and NOT a red: this probe grades nothing, so it cannot fail closed
  # onto a verdict it does not participate in. Saying so is the whole handling.
  printf 'harness-budget[%s/%s]: the post-corpus probe (DIVE-2736) could not run. The verdict above\n' "$TIER" "$LABEL"
  printf '  is unaffected — it is graded on the pre-corpus probe and always was.\n'
fi

slowest() {
  local n="$1" i
  for i in "${!NAME[@]}"; do printf '%s\t%s\n' "${MS[$i]}" "${NAME[$i]}"; done \
    | sort -rn | head -"$n" | while IFS=$'\t' read -r ms nm; do
        printf '    %6.1fs  %s\n' "$(awk -v m="$ms" 'BEGIN{print m/1000}')" "$nm"
      done
}

# DIVE-2592: the leaderboard is not the ACTIONABLE set. "here are the 10 slowest"
# tells a reader what is expensive; it does not tell them what is over. This prints
# the smallest group of harnesses whose time COVERS the overage — remove or demote
# those and the run is inside the cap, which is the sentence the reader needs.
covering() {
  local over_ms="$1" i
  for i in "${!NAME[@]}"; do printf '%s\t%s\n' "${MS[$i]}" "${NAME[$i]}"; done | sort -rn \
    | { acc=0; while IFS=$'\t' read -r ms nm; do
          (( acc >= over_ms )) && break
          acc=$(( acc + ms ))
          printf '    %6.1fs  %s\n' "$(awk -v m="$ms" 'BEGIN{print m/1000}')" "$nm"
        done; }
}

# DIVE-2592: printed whenever a confirmation happened, PASS OR FAIL. A run that was
# over on its first sample and inside on its second is the finding, not a non-event —
# swallowing it is how the corpus arrives at 118% with everything looking green.
if (( confirmed )); then
  printf '\nharness-budget[%s/%s]: BUDGET CONFIRMATION — first sample %ds (%d%%), confirmed %ds (%d%%).\n' \
    "$TIER" "$LABEL" "$first_total_s" "$first_pct" "$total_s" "$pct"
  if (( ${#SWING[@]} )); then
    printf 'Kept the SMALLER of two samples per file (noise only ADDS time, so the low sample is\n'
    printf 'the least contaminated estimate; real growth shows up in both and survives this):\n'
    for sw in "${SWING[@]}"; do
      IFS=$'\t' read -r nm a b <<<"$sw"
      printf '    %6.1fs -> %6.1fs  (-%.1fs)  %s\n' \
        "$(awk -v m="$a" 'BEGIN{print m/1000}')" "$(awk -v m="$b" 'BEGIN{print m/1000}')" \
        "$(awk -v x="$a" -v y="$b" 'BEGIN{print (x-y)/1000}')" "$nm"
    done
  else
    printf 'No re-timed harness came in faster. The total is the corpus, not the weather.\n'
  fi
  for fl in "${FLAKED[@]}"; do
    IFS=$'\t' read -r nm rc2 <<<"$fl"
    printf 'RE-RUN DISAGREED (observed): %s PASSED in the graded run and FAILED (rc=%s) when\n' "$nm" "$rc2"
    printf '  it was re-timed. Its pass STANDS — the graded run is the first one — and its timing\n'
    printf '  was not replaced.\n'
    printf '  CAUSE NOT MEASURED (inferred): this is consistent with a non-deterministic harness,\n'
    printf '  with state the first run left behind, or with the runner changing under both. This\n'
    printf '  line cannot tell them apart and neither can the exit code. Worth its own row; not\n'
    printf '  worth a diagnosis from here.\n'
  done
fi

over=0
if (( BUDGET <= 0 )); then
  printf 'harness-budget[%s]: BUDGET DISABLED (--budget=%s). This run enforces nothing.\n' "$TIER" "$BUDGET"
elif (( undetermined )); then
  # DIVE-2728. THIS IS NOT A BUDGET FAILURE AND IT DOES NOT SHARE ITS EXIT CODE.
  # Exit 4 says "the corpus no longer fits its cap" and sends the author to retire a
  # guard. Exit 6 says "this box could not measure that cap" and sends them to re-run.
  # DIVE-2667 was those two events wearing the same red for a fortnight; merging them
  # back here would undo the only thing this row is for.
  printf '\nharness-budget[%s/%s]: UNDETERMINED — %s.\n' "$TIER" "$LABEL" "${CAL_WHY:-the calibration could not be taken}"
  printf 'The corpus ran and %d of %d harnesses passed, but its %ds CANNOT BE GRADED against the\n' \
    "$(( ${#CORPUS[@]} - ${#failed[@]} ))" "${#CORPUS[@]}" "$total_s"
  printf '%ds cap from this runner. This is exit 6, NOT exit 4: nothing says your corpus is over,\n' "$BUDGET"
  printf 'and nothing says it is inside either. A run that could not measure has not passed\n'
  printf '(DIVE-2555), and a cap that grows without limit with the runner draw is not a cap at all\n'
  printf '(past %d%% the scale factor stops being a correction and becomes an escape hatch).\n' "$TIER_CAL_SCALE_MAX_PCT"
  printf 'RE-RUN. If it repeats on main, the baseline is wrong, not the box — re-baseline it.\n'
elif (( total_ms > EFF_MS )); then
  over=1
  printf '\nharness-budget[%s]: OVER BUDGET by %ds (%ds > %ds effective cap).\n' \
    "$TIER" "$(( (total_ms - EFF_MS + 999) / 1000 ))" "$total_s" "$EFF_BUDGET"
  # DIVE-2592: SAY WHAT THIS RED IS, in the output that carries it. `exit 4` beside a
  # green assertion count cost the author of #395 an hour: it reads as systemic to the
  # person whose PR it stopped and as flake to the next reader, and it is neither.
  # DIVE-2801: the no-test-failed claim is only true when nothing failed, and this
  # branch had been asserting it unconditionally — while computing "N of M" from
  # the very `failed` array that contradicts it. On a run with 2 failures it
  # printed "NO TEST FAILED — 241 of 243 harnesses passed", which is a verdict the
  # printer did not compute, in the output whose whole job is to say what this red
  # IS. Exactly the class this row exists to fix, occurring inside the measurement
  # of it. Both facts are true at once here and the reader needs both, plus which
  # exit code wins.
  if (( ${#failed[@]} == 0 )); then
    printf 'NO TEST FAILED — %d of %d harnesses passed. This is a BUDGET failure (exit 4), not a\n' \
      "$(( ${#CORPUS[@]} - ${#failed[@]} ))" "${#CORPUS[@]}"
    printf 'test failure (exit 1): nothing in your diff is broken, the CORPUS no longer fits its cap.\n'
  else
    printf '%d HARNESS(ES) ALSO FAILED — %d of %d passed. This run is BOTH over budget AND red.\n' \
      "${#failed[@]}" "$(( ${#CORPUS[@]} - ${#failed[@]} ))" "${#CORPUS[@]}"
    printf 'The FAILURE takes precedence and this run exits 1, not 4: fix the failing harness(es)\n'
    printf 'first, then re-read the budget — a red run is not a trustworthy timing sample either.\n'
  fi
  if (( confirmed )); then
    printf 'It was measured TWICE (%ds, then %ds) before this was printed, so it is not variance.\n' \
      "$first_total_s" "$total_s"
  elif (( CONFIRM_TOP == 0 )); then
    printf 'Confirmation was disabled (--confirm-top=0), so this is ONE sample. Re-run to confirm.\n'
  fi
  # DIVE-2728: measured against the EFFECTIVE cap, so the covering set is the set that
  # actually gets this run inside the cap it was graded on. And the line above it says
  # so out loud, because "over by 22s" against an unstated cap is how a reader ends up
  # attributing a slow runner to their own diff.
  if (( SCALE > 100 )); then
    printf '\nThis runner was measured at %d%% of baseline, so the cap it is held to is %ds, not %ds.\n' \
      "$SCALE_RAW" "$EFF_BUDGET" "$BUDGET"
    printf 'It is over EVEN WITH that allowance, which is what makes this the corpus and not the VM.\n'
  fi
  printf '\nThe overage is %ds, and these harness(es) cover it — the run is inside the cap without\n' "$(( (total_ms - EFF_MS + 999) / 1000 ))"
  printf 'them. This is the actionable set; the leaderboard below is context:\n'
  covering "$(( total_ms - EFF_MS ))"
  printf '\nThe corpus is not free: every harness here runs on every future change, forever.\n'
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
elif (( eff_pct >= 80 )); then
  # DIVE-2728: read against the EFFECTIVE cap. Against the raw cap this line fired on
  # every slow-runner draw and told the author their corpus was nearly full when it was
  # not, which is the same misattribution one warning earlier.
  printf 'harness-budget[%s]: %d%% of budget — inside the cap, but the next few guards will not be.\n' "$TIER" "$eff_pct"
  # DIVE-2592: at 80%+ the tier has no variance headroom left, and that — not the
  # percentage on its own — is what makes an unrelated PR go red. Say so, because the
  # number alone has been sitting in the log getting bigger for a fortnight.
  printf 'At this base a harness with budget-scale variance reds PRs on content they did not\n'
  printf 'change: the cap is one sample, and one sample of this corpus has swung 67s (DIVE-2592).\n'
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
# DIVE-2728: 6 sits ABOVE 4 and BELOW 1. Below 1 because a failing harness is still
# the thing to fix first and an unmeasurable runner must never hide one — which is why
# the undetermined verdict is resolved here rather than short-circuiting before the
# corpus ever ran. Above 4 because when the cap could not be graded there is no
# over-budget claim to make: `over` was not even computed on that path.
(( undetermined == 0 )) || exit 6
(( over == 0 )) || exit 4
(( drift_fatal == 0 )) || exit 5
exit 0
