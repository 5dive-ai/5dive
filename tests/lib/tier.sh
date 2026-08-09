# shellcheck shell=bash
# DIVE-2525: WHICH TIER DOES THIS HARNESS RUN IN, and WHAT DOES THE TIER COST.
# One resolver, one pair of numbers, sourced by everything that selects or
# budgets the corpus (scripts/run-harnesses.sh and the CI workflows). Two
# selectors written in two places are one contract with two authors, and when they
# drift the PR path and the nightly path silently grade different corpora — which
# is DIVE-2018 exactly, one level out.
#
# WHY THIS EXISTS AT ALL (measured 2026-08-02, community/wiki/guards-compound-in-cost-
# and-nothing-ever-retires-one.md): tests/*.sh went 96 -> 267 harnesses in 13 days,
# ~+13/day, against FOUR harness deletions ever. A guard is bought once and paid for
# on every future change forever, while its benefit stays fixed at the one class it
# catches, so the ledger tilts by construction and no single decision to add one is
# ever wrong on its own merits. Nobody has ever been paged by a guard that was too
# slow, so nobody ever files "delete this guard": ~170 additions against 4 deletions
# is a mechanism with no reverse gear, not restraint failing occasionally.
#
# WHY WALL-CLOCK AND NOT A COUNT. "Do not add too many tests" is unenforceable and
# reads as an argument against testing. "The core must finish in N minutes" is
# measurable, count-neutral, and is the reverse gear: past the cap, a new guard has
# to replace or merge an existing one — or justify, in writing, why it belongs in
# the nightly sweep instead.
#
# THE TIERS
#   core     — runs on EVERY pull request, in both CI environments. The DEFAULT.
#   nightly  — runs only in the full sweep. Must be declared IN THE FILE, with a
#              reason, because a demotion nobody has to justify is not a reverse
#              gear either: it just moves the growth to a budget nobody watches.
#
# THE MARKER, spelled once, here:
#
#   # TIER: nightly — <reason, >= 12 chars>
#
# Anything else, anywhere in the first 40 lines of a harness, is `core`. A `# TIER:`
# line with an unknown tier, or a `nightly` line with no reason, is a REFUSAL (exit
# 3) and not a silent default in either direction — "I could not tell" is a third
# outcome and folding it into either of the other two is the class this repo keeps
# re-learning (tests/lib/grading_tree.sh, DIVE-2274).

# The budgets, in seconds of HARNESS WALL-CLOCK (the runner measures only the
# harnesses, never checkout/build/setup, so the number means the same thing in CI,
# on the control plane, and on a laptop).
#
# CORE = 300s. lodar's number, set on Telegram 2026-08-02 after the measurement
# above. It is per-job, and both PR environments (pristine and installed-host) are
# held to it separately.
#
# FULL = 1320s (22 min). MEASURED IN CI ON THIS PR, not extrapolated: 268 harnesses
# in 1097s pristine and 1146s installed-host (gh run 30761800471). The estimate this
# number was first set from — release-cut.yml's published 3.79s/harness — agreed with
# it to within 6%, and is now superseded by the direct reading.
#
# So the sweep starts at 83-86% OF ITS OWN CAP, and that is the finding, not a
# mis-set number: the corpus is ALREADY at the cost a nightly job can carry. 1320 is
# today plus ~15-20%, which is runner variance and roughly 30 more harnesses — about
# three days at the observed +13/day. Raising it to buy comfortable headroom would be
# re-installing the ratchet this row exists to remove. The run prints its
# percentage-of-budget every time, so the trend is legible in the number rather than
# only in the red.
TIER_BUDGET_CORE=300
TIER_BUDGET_FULL=1320

# DIVE-2728: A SECOND IS NOT A STABLE UNIT ON RENTED HARDWARE, so the cap above is
# spent in units of a CALIBRATION WORKLOAD carried in the same job.
#
# WHAT FORCED THIS (DIVE-2667, community/wiki/an-absolute-time-budget-on-a-variable-
# platform-measures-the-runner.md): PR #461 red-gated at 322s with 234 of 234
# harnesses passing and a diff worth +0.1s. Per-harness, against the identical corpus
# on main, unrelated files ran 10-36% slower while the ONE file the diff touched moved
# +0.3%. Five recent runs of that same corpus: 253/256/260/261/273s. That is 27s of
# headroom on the worst normal run — 9% — against a platform that draws 10-36% slow.
# The gate had stopped failing when the corpus grows and started failing when the VM
# is slow, and those are different events wearing the same red.
#
# THE FIX IS A RATIO, NOT A BIGGER NUMBER. Raising 300 buys time until the corpus
# catches up and re-installs the ratchet DIVE-2525 exists to remove (olivia, DIVE-2710:
# explicitly NOT the remedy). Instead the runner times a small fixed workload in the
# same job and spends the budget in units of it: a uniformly slow VM scales the
# calibration and the corpus together, and the ratio cancels.
#
# THREE THINGS THIS GETS WRONG IF BUILT CARELESSLY, all of them designed against here:
#
#   1. A RELATIVE BUDGET REPLACES ONE NOISY NUMBER WITH A RATIO OF TWO. A 3s probe
#      swinging +-20% hands the effective cap that same swing, and the gate ends up
#      NOISIER than the absolute one it replaced. So the probe is sampled to a WALL-
#      CLOCK TARGET (TIER_CAL_TARGET_MS, ~10s) rather than to a fixed iteration count,
#      and min-of-TIER_CAL_SAMPLES is kept — reusing DIVE-2592's one-sided-noise
#      argument (contention only ADDS time, so the low sample is the least
#      contaminated estimate).
#
#      The unit is therefore MICROSECONDS PER ITERATION, not milliseconds per probe.
#      Auto-sizing to a time target means two runs do different iteration counts, so a
#      raw probe duration is not comparable across runs; normalising per iteration
#      makes the sampling length a PRECISION knob that cannot move the unit.
#
#   2. UNCLAMPED, THE SCALE FACTOR IS ITSELF THE ESCAPE HATCH. A cap that grows with
#      the runner draw licenses an arbitrarily larger corpus, which is DIVE-2525's
#      ratchet re-installed through the back door. Hence TIER_CAL_SCALE_MAX_PCT: past
#      it the run is UNDETERMINED with its own non-zero exit, never green (cf.
#      DIVE-2555 — a run that could not measure has not passed).
#
#   3. THE PROBE MUST MATCH THE CORPUS'S COST MIX, NOT MERELY ITS DURATION. The
#      observed 10-36% spread was across process spawn, bash startup, the built CLI's
#      own startup and small file I/O. A CPU spin is the tempting probe and the wrong
#      one: it calibrates a dimension these harnesses barely pay for, so it would
#      track a draw the corpus does not feel. See scripts/run-harnesses.sh:cal_probe.
#
# THE LOWER CLAMP IS 1.0 — a fast VM never TIGHTENS the cap. Symmetric scaling is the
# purer reading OF THE MEASUREMENT, and it was left open for the builder to argue
# (DIVE-2710 §2.2). The argument against it: 300s is lodar's agreed number, and
# scaling below it reds a PR that would pass on a normal runner, on a signal its
# author cannot reproduce and cannot act on. That is precisely the unactionable red
# this row exists to remove, merely inverted — and it ratchets the agreed policy
# tighter with nobody agreeing to it. The gate is a policy instrument, not an
# estimator, so it rounds in the direction the policy was set.
#
# THE CLAMP PAIR IS STILL POLICY, NOT MEASUREMENT (DIVE-2710 set them as starting
# values). TIER_CAL_BASELINE_US is no longer among them: it was re-derived from CI on
# 2026-08-05 (DIVE-2736) and carries its environment — see its own note.
TIER_CAL_SCALE_MIN_PCT=100
TIER_CAL_SCALE_MAX_PCT=150

# TIER_CAL_BASELINE_US — the calibration workload's cost, in MICROSECONDS PER
# ITERATION, on a runner drawing normal.
#
# RE-DERIVED FROM CI 2026-08-05 (DIVE-2736). ENVIRONMENT, because a figure without one
# cannot be refuted by the next reading (DIVE-2555): GitHub-hosted `ubuntu-latest`,
# both PR jobs (core/pristine and core/installed-host), six readings across three
# commits, each the min of 2 auto-sized samples:
#
#     116662   117714   120693   121231   121382      <- five, within 4%, BOTH job types
#      82218                                          <- one, ONE job, ONE run
#
# 119000 is the MEDIAN OF ALL SIX (119203, rounded down). The median is the estimator
# on purpose: it lands within 0.5% of the mean of the tight five (119536) WITHOUT
# anyone having to first win the argument about excluding the sixth. An outlier you
# have to argue away before you can compute is an outlier your estimator is too fragile
# to see. The sixth reading is a real event and it has its own row — it is the
# anti-correlated run this constant's row was filed for — but it is not evidence about
# where NORMAL sits, and n=1 cannot make it so.
#
# WHY THE OLD NUMBER WAS NOT MERELY IMPRECISE, AND THIS IS THE FINDING: 173000 was
# measured on the CONTROL PLANE, which is ~45% slower per iteration than the runner it
# was grading. A baseline set too HIGH does not misgrade in some visible direction — it
# reads every CI probe as a FAST runner, and because the lower clamp is 1.0 by policy, a
# fast reading can never widen the cap. All six readings came in at 47-70% of baseline;
# all six clamped to the 100% floor; the effective cap was exactly 300s on every run
# observed. So a baseline attached to the wrong environment SILENTLY DISABLES the
# relative mechanism rather than skewing it, and the gate goes on behaving exactly like
# the absolute one DIVE-2728 replaced, while every log line claims a ratio was applied.
# A one-directional clamp turns a mis-set baseline into a no-op instead of an error.
#
# THE RE-BASELINE WARNING BELOW FIRED ON ALL SIX RUNS (30-53% off), from the first CI
# run onward. It was right, it was in the log every time, and nothing read it until this
# row. Recording that here because the instrument working is not the same as the
# instrument being read, and the second one is the part that has no test.
# RUNNING THIS LOCALLY NOW TRIPS THE RE-BASELINE WARNING, AND THAT IS CORRECT. The
# control plane measures ~168900us/iter against this 119000, so a local run prints "41%
# off". The number is attached to GitHub `ubuntu-latest` on purpose, because that is the
# environment the gate actually fires in; a warning on your laptop is the constant
# telling you truthfully that you are not standing in it. DO NOT "fix" it by re-deriving
# from the box you happen to be on — that is exactly how 173000 got here, and the
# failure mode is silent (every CI probe then reads fast, the floor clamps, and the
# relative budget quietly stops existing while still printing a ratio).
TIER_CAL_BASELINE_US=119000

# How long ONE sample of the probe should run. This is the PRECISION knob from note 1:
# the probe's own relative error must sit well under the headroom being protected (9%
# today), and a ~10s sample of a ~180ms unit is ~55 iterations, whose spread is small
# beside a 10-36% platform draw. Two samples ~= 20s of job time, which is deliberately
# NOT counted toward the corpus total — the runner says so in its report.
TIER_CAL_TARGET_MS=10000
TIER_CAL_PILOT_ITERS=5
TIER_CAL_MIN_ITERS=5
TIER_CAL_MAX_ITERS=20000
TIER_CAL_SAMPLES=2

# DIVE-2710 §2.5: TIER_CAL_BASELINE_US is a measurement with no environment attached,
# which is exactly the thing nobody ever re-reads. The runner measures it every run, so
# grading it is free: past this drift the run says RE-BASELINE rather than absorbing the
# drift silently. A GitHub runner image change is precisely the event that moves it.
TIER_CAL_REBASELINE_PCT=25

# DIVE-2736: A RATIO WHOSE NUMERATOR AND DENOMINATOR CAN MOVE IN OPPOSITE DIRECTIONS IS
# NOT A RATIO, AND NOTHING NOTICED WHEN THEY DID.
#
# MEASURED on core/installed-host, run 30967674559: the probe read 82218us/iter — 30%
# FASTER than its own cluster — on the run whose corpus came in at 372s against a 282s
# reading 13 minutes earlier, with ONE FEWER harness. Probe fast, corpus slow, same job,
# same commit. DIVE-2710's premise ("a uniformly slow VM scales both sides and the ratio
# cancels") inverted, on the one run that needed the relief: scale_raw 47%, clamped to
# the floor, no scaling applied, exit 4. A probe that under-reads is strictly WORSE than
# no probe on a slow run — it cannot widen the cap past the 1.0 floor, and it spends
# ~20s of job time not helping.
#
# TWO CANDIDATE CAUSES, AND THEY HAVE DIFFERENT REMEDIES:
#
#   TEMPORAL — the probe is a ~20s point sample taken BEFORE a ~6-minute corpus, and the
#     runner's draw varies within the job. Remedy: BRACKET the corpus (probe before and
#     after, scale on the mean or the max), which costs another probe and no new design.
#   STRUCTURAL (trap 3 above) — the probe's cost mix omits what the corpus actually pays
#     (sqlite, deeper process trees, I/O under contention), so it is systematically blind
#     to the dimension that got slow. Remedy: re-shape cal_probe, which is a redesign.
#
# THE EVIDENCE FAVOURS TEMPORAL AND SAYS SO OUT LOUD: on that same run the OTHER job's
# probe (core/pristine, 121231) sat squarely in the cluster with a normal corpus. A
# structural mix mismatch would under-read on every run in both jobs; five of six agree
# within 4%. A one-off confined to one job on one run is the shape of transient
# contention. But a prior is not a measurement, so what ships here is the DISCRIMINATOR,
# not either remedy: a second probe AFTER the corpus, recorded and reported, never
# graded on. See scripts/run-harnesses.sh (the post probe) and scripts/tier-cal-window.sh
# (the across-runs read). What falsifies TEMPORAL: a post probe that AGREES with the pre
# probe on a run whose corpus was slow.
#
# THE DISCRIMINATOR IS ONE-SIDED, and reading it as symmetric would be the mistake here.
# The corpus warms the page cache and the CLI it just spawned 236 times, so the post
# probe is biased FAST for a benign reason. POST SLOWER THAN PRE is therefore the clean
# signal (it survives a confound pushing the other way) and confirms TEMPORAL. POST
# AGREEING is consistent with structural blindness, with contention that ended, AND with
# cache warmth masking a real slowdown — it weakens TEMPORAL without establishing trap 3.
#
# THE THRESHOLD IS DERIVED, NOT PICKED. The five clustered CI readings span 4%
# (116662-121382), which is this probe's observed run-to-run spread on this platform.
# 15% is comfortably outside that and comfortably inside the 30% divergence actually
# measured, so it can fire on the event and not on the weather.
TIER_CAL_POST_DIVERGE_PCT=15

# tier_cal_diverge_pct <pre_us> <post_us> -> how far the post-corpus probe moved from
# the pre-corpus one, in SIGNED percent of the pre reading. POSITIVE means the runner
# was SLOWER after the corpus than before it (the TEMPORAL signal); negative means
# faster. Signed on purpose: an absolute value would fold the one clean direction into
# the confounded one, which is the whole distinction this number exists to carry.
tier_cal_diverge_pct() {
  local pre="${1:?tier_cal_diverge_pct <pre_us> <post_us>}" post="${2:?tier_cal_diverge_pct <pre_us> <post_us>}"
  if (( pre <= 0 )); then
    printf 'tier_cal_diverge_pct: pre must be > 0, got %s\n' "$pre" >&2; return 2
  fi
  printf '%s\n' "$(( (post - pre) * 100 / pre ))"
}

# DIVE-2867: WHO IS ALLOWED TO MOVE TIER_CAL_BASELINE_US, AND ON WHAT EVIDENCE.
#
# The constant above has now been re-derived twice by argument (173000 -> 119000, then a
# proposed 116584), each time from a hand-copied handful of readings, because the
# cross-run instrument that should settle it — scripts/tier-cal-window.sh — could not be
# fed. It said so in its own header: reports do not outlive the run that wrote them.
# scripts/tier-cal-harvest.sh removes that excuse (the runner prints every field the
# window reads straight to the job log, and GitHub already keeps those), so the rule below
# is now SATISFIABLE and is written as a countable check rather than a paragraph.
#
# THE RULE IS ONE-SIDED, mirroring the clamp it serves. RAISING the reference tightens
# every future cap toward the 100% floor and is safe from any sample. LOWERING it widens
# every future cap, permanently, for everyone — DIVE-2525's ratchet wearing the
# calibration's clothes — so only that direction has to buy its evidence.
#
# WHY A COUNT AND NOT A PERCENTILE. "Use p10, not the minimum" was the first form of this
# guard and it is the guard MIS-STATED: at n=8 the p10 was 116584 and the min was 116404,
# 0.15% apart, so p10 WAS the extremum in all but name while sounding considered. There
# are ~9 percentile conventions and they disagree most at small n. The real content was
# never the statistic — it is a constraint on SAMPLE SIZE, and a count says it directly.
#
# WHY THE COUNT ALSO NEEDS A PROXIMITY BAND, and this is the part only the harvested
# window could show. MEASURED 2026-08-08 over the last 20 `unit-tests` runs on main (n=40
# job-samples, both lanes, via tier-cal-harvest.sh + tier-cal-window.sh): the 31
# CONCORDANT probe readings are BIMODAL.
#
#     92852  96155  97360  99941  106833   <- a distinct FAST mode, n=5
#     ---------------------------------------- a 10% gap with nothing in it
#     117761 ... 121542 (median) ... 126454 <- the normal mode, n=26
#
# Excluding discordant runs first — the fix written for the previous hole — does NOT
# separate these: three of the five fast-mode readings are honestly concordant (a fast box
# ran a fast corpus). So a bare "K samples strictly below the candidate" is satisfied for
# ANY candidate above 97360 by the fast mode ALONE, and the guard would have certified a
# reference with K=5 while NO normal-population run had ever been observed below it. The
# guard counts samples; the samples it counts came from a different population.
#
# Hence the band: a sample only supports a candidate if it sits WITHIN
# TIER_CAL_REF_BAND_PCT below it. A reading 20% faster than the candidate is not evidence
# about where the candidate sits in the normal distribution — it is evidence that a second
# population exists. 10% is inside the normal mode's own observed spread (117761-126454 is
# 7.4%) so it admits genuine neighbours, and outside the 12-25% gap to the fast mode so it
# cannot be satisfied across it.
#
# APPLIED, which is why this ships as a refusal rather than as a new number: the proposed
# fast-end 116584 has FIVE concordant samples below it and NONE within 10% of it (band
# [104926, 116584) contains only 106833) -> K=1 -> REFUSED. The incumbent 119000 has band
# [107100, 119000) containing 117761 and 118000 -> K=2 -> ADMITTED. The measurement does
# not support the move the row proposed, and it does support leaving the constant alone.
# AND THE BAND ALONE IS NOT ENOUGH — found by the arm written to prove it was, which is
# the only reason it is here. A candidate placed INSIDE the fast mode (say 100000) has
# four concordant neighbours within 10% below it, so it passes the support test at K=4
# and would be certified — while handing a typical run (median concordant reading 121160)
# a scale of 121% and a 363s cap against a 300s policy. The band proves LOCAL DENSITY;
# it cannot tell a dense fast mode from the low tail of the working one.
#
# So the guard is a CONJUNCTION, and the two halves catch different things — neither is
# redundant and neither alone is sufficient:
#
#   SUPPORT      K concordant samples within BAND% below the candidate.
#                  116584 -> K=1  REFUSED   |   100000 -> K=4  passes
#   BOUNDED COST the window's MEDIAN concordant reading may not scale past MAX_WIDEN.
#                  116584 -> 103% passes    |   100000 -> 121% REFUSED
#
# The second is the bounded-cost test in its checkable form: a reference change is
# legitimate because its cost is bounded, not because its intent was good. It needs no
# mode-fitting — it asks the only question policy actually cares about, which is how much
# extra cap the TYPICAL run is being handed.
TIER_CAL_REF_MIN_BELOW=2
TIER_CAL_REF_BAND_PCT=10
TIER_CAL_REF_MAX_WIDEN_PCT=110

# tier_cal_ref_admissible <candidate_us> <current_us> <concordant_sample_us>...
#   -> "admit raise" | "admit K=<n> median-widen=<pct>%" | "refuse support ..." | "refuse cost ..."
#      exit 0 admit / 1 refuse. The two refusals are spelled apart on purpose: they send
#      the reader to different evidence, and a caller that cannot tell them apart will
#      answer "get more samples" to a bounded-cost refusal that more samples cannot fix.
#
# Feed it CONCORDANT samples only (tier-cal-window.sh classifies them). Passing the whole
# window is the caller's bug and this cannot detect it — which is why the harvest ->
# window -> here order is the documented one and not a suggestion.
tier_cal_ref_admissible() {
  local cand="${1:?tier_cal_ref_admissible <candidate_us> <current_us> <sample>...}"
  local cur="${2:?tier_cal_ref_admissible <candidate_us> <current_us> <sample>...}"
  shift 2
  if (( cand <= 0 || cur <= 0 )); then
    printf 'tier_cal_ref_admissible: candidate and current must be > 0\n' >&2; return 2
  fi
  # Raising tightens toward the floor. No sample can make that dangerous, and demanding
  # one would block the honest response to a runner image getting slower.
  if (( cand >= cur )); then printf 'admit raise\n'; return 0; fi
  local lo=$(( cand * (100 - TIER_CAL_REF_BAND_PCT) / 100 )) s k=0 n=0
  local sorted=() med=0
  for s in "$@"; do
    [[ "$s" =~ ^[0-9]+$ ]] || continue
    sorted+=("$s"); n=$((n+1))
    (( s < cand && s >= lo )) && k=$((k+1))
  done
  if (( k < TIER_CAL_REF_MIN_BELOW )); then
    printf 'refuse support K=%d need %d within %d%% below %d (band %d-%d)\n' \
      "$k" "$TIER_CAL_REF_MIN_BELOW" "$TIER_CAL_REF_BAND_PCT" "$cand" "$lo" "$cand"
    return 1
  fi
  # BOUNDED COST. Refuse rather than guess when there is nothing to take a median of —
  # "no samples" and "the cost is fine" are different answers and only one is a pass.
  if (( n == 0 )); then
    printf 'refuse no samples to bound the cost against\n'; return 1
  fi
  mapfile -t sorted < <(printf '%s\n' "${sorted[@]}" | sort -n)
  med="${sorted[$(( n / 2 ))]}"
  local widen=$(( med * 100 / cand ))
  if (( widen > TIER_CAL_REF_MAX_WIDEN_PCT )); then
    printf 'refuse cost median %d scales to %d%% at candidate %d (max %d%%)\n' \
      "$med" "$widen" "$cand" "$TIER_CAL_REF_MAX_WIDEN_PCT"
    return 1
  fi
  printf 'admit K=%d median-widen=%d%%\n' "$k" "$widen"
  return 0
}

# tier_cal_scale_pct <measured_us> [<baseline_us>] -> the RAW, UNCLAMPED scale, in
# percent. Kept separate from the clamp so the runner can tell "slow" (clamped, still
# graded) from "too slow to grade" (past the clamp, undetermined) — one number cannot
# carry both and the difference is a different exit code.
tier_cal_scale_pct() {
  local m="${1:?tier_cal_scale_pct <measured_us> [baseline_us]}" b="${2:-$TIER_CAL_BASELINE_US}"
  if (( b <= 0 )); then
    printf 'tier_cal_scale_pct: baseline must be > 0, got %s\n' "$b" >&2; return 2
  fi
  printf '%s\n' "$(( m * 100 / b ))"
}

# tier_cal_clamp_pct <raw_pct> -> the scale actually applied to the budget.
tier_cal_clamp_pct() {
  local p="${1:?tier_cal_clamp_pct <raw_pct>}"
  if (( p < TIER_CAL_SCALE_MIN_PCT )); then p=$TIER_CAL_SCALE_MIN_PCT; fi
  if (( p > TIER_CAL_SCALE_MAX_PCT )); then p=$TIER_CAL_SCALE_MAX_PCT; fi
  printf '%s\n' "$p"
}

# DIVE-2555: HOW FAR A HEADER'S OWN MEASUREMENT MAY DRIFT FROM THE CLOCK.
#
# A demotion is argued in the diff with a number — `14.3s measured: does not fit
# the 300s PR core`. That number is the whole evidence a reviewer has that a cost
# was moved rather than hidden, and NOTHING GRADED IT: it is free text in a comment,
# written once, never re-read. Measured 2026-08-03 on the control plane,
# gate_channel_session_t2_mutation.sh claimed 300.0s and ran 335s (+12%), and the
# claim had no environment and no date on it, so neither reading could refute the
# other.
#
# The fix costs nothing to run, because the runner already times every harness in
# the run it was doing anyway (property 2: enforce on the number you MEASURE, never
# on a table of per-file costs — this grades the table AGAINST the measurement
# instead of trusting it). Two thresholds, not one:
#
#   WARN  measured exceeds the claim by >= 10% AND by >= 1s. Printed with the exact
#         replacement line. This is the band a busier host or a slower runner can
#         produce, and the honest remedy is to update the number, not to red a build.
#   FAIL  >= 50% AND >= 3s over  ->  exit 5. Runner variance does not double a
#         harness that is already several seconds long. A claim that far under is
#         not a stale measurement, it is a wrong one, and it was load-bearing
#         evidence in a review that already happened.
#
# Exit 5 is its OWN code for the same reason over-budget is 4 and a red harness is
# 1: a red that could mean either gets triaged as neither.
TIER_CLAIM_DRIFT_WARN_PCT=10
TIER_CLAIM_DRIFT_WARN_S=1
TIER_CLAIM_DRIFT_FAIL_PCT=50
TIER_CLAIM_DRIFT_FAIL_S=3

# Match the marker on the harness's own header. Anchored to a comment so a string
# inside a heredoc or an assertion cannot demote a file by accident.
TIER_MARKER_RE='^[[:space:]]*#[[:space:]]*TIER:[[:space:]]*([a-z-]+)[[:space:]]*(.*)$'

# tier_of <file> -> prints core|nightly, exit 0
#                   prints a diagnostic on stderr, exit 3, when the file names a
#                   tier this resolver does not know or demotes without a reason.
tier_of() {
  local f="$1" line tier reason
  # Only the header. A marker 400 lines down is not a header contract, and reading
  # the whole file to find one invites exactly the accidental match this avoids.
  line="$(head -40 -- "$f" 2>/dev/null | grep -m1 -E '^[[:space:]]*#[[:space:]]*TIER:' || true)"
  if [[ -z "$line" ]]; then printf 'core\n'; return 0; fi
  [[ "$line" =~ $TIER_MARKER_RE ]] || {
    printf 'tier: REFUSING %s — has a "# TIER:" line this resolver cannot parse: %s\n' "$f" "$line" >&2
    return 3
  }
  tier="${BASH_REMATCH[1]}"; reason="${BASH_REMATCH[2]}"
  case "$tier" in
    core)
      # Redundant but legal: saying out loud that a file is core is not an error.
      printf 'core\n'; return 0 ;;
    nightly)
      # Strip the separator (— / -- / :) people will reach for, then demand prose.
      reason="${reason#[—:-]}"; reason="${reason#[-—]}"
      reason="${reason#"${reason%%[![:space:]]*}"}"
      if (( ${#reason} < 12 )); then
        printf 'tier: REFUSING %s — demoted to nightly with no reason. A demotion nobody has to justify is not a budget, it is a second budget nobody watches. Write: # TIER: nightly — <why this cannot be in the 5-minute PR core>\n' "$f" >&2
        return 3
      fi
      printf 'nightly\n'; return 0 ;;
    *)
      printf 'tier: REFUSING %s — unknown tier "%s". Known tiers: core, nightly.\n' "$f" "$tier" >&2
      return 3 ;;
  esac
}

# tier_reason <file> -> the demotion reason, or empty for a core harness.
tier_reason() {
  local line
  line="$(head -40 -- "$1" 2>/dev/null | grep -m1 -E '^[[:space:]]*#[[:space:]]*TIER:[[:space:]]*nightly' || true)"
  [[ -n "$line" ]] || return 0
  line="${line#*nightly}"; line="${line#[[:space:]]}"; line="${line#[—:-]}"; line="${line#[-—]}"
  printf '%s\n' "${line#"${line%%[![:space:]]*}"}"
}

# tier_claim <file> -> the number of SECONDS the header claims was MEASURED for this
# harness ("14.3s measured"), or nothing when the demotion reason argues from
# something other than a clock ("40s of container setup" is prose, not a claim this
# can grade, and inventing a number from it would be worse than having none).
tier_claim() {
  local r re='([0-9]+(\.[0-9]+)?)s[[:space:]]+measured'
  r="$(tier_reason "$1")" || return 0
  [[ -n "$r" && "$r" =~ $re ]] || return 0
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# tier_list <core|nightly|full> [corpus-dir=tests] -> harness paths, one per line.
# `full` is every harness; it is the union, not a third tier.
# Exits 3 if ANY harness in the corpus has an unreadable marker — a selection built
# from a corpus it could not fully classify is not a selection, and shipping the
# subset it did understand is how a check reports clean on what it never saw.
tier_list() {
  local want="${1:?tier_list <core|nightly|full>}" dir="${2:-tests}" t got rc=0 out=()
  for t in "$dir"/*.sh; do
    [[ -e "$t" ]] || continue
    if ! got="$(tier_of "$t")"; then rc=3; continue; fi
    case "$want" in
      full) out+=("$t") ;;
      "$got") out+=("$t") ;;
    esac
  done
  (( rc == 0 )) || return 3
  (( ${#out[@]} )) && printf '%s\n' "${out[@]}"
  return 0
}

# tier_budget <core|full> -> the budget in seconds for that RUN (not that tier's
# membership: a `full` run includes the core harnesses, so it carries the full
# budget). `nightly` is not a run selector and has no budget of its own.
tier_budget() {
  case "${1:?tier_budget <core|full>}" in
    core) printf '%s\n' "$TIER_BUDGET_CORE" ;;
    full) printf '%s\n' "$TIER_BUDGET_FULL" ;;
    *) printf 'tier_budget: unknown run tier %s\n' "$1" >&2; return 2 ;;
  esac
}

# Usable as a CLI so a workflow step, a git hook or a human can ask without writing
# bash: tests/lib/tier.sh list core | of <file> | reason <file> | budget core
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." || exit 2
  case "${1:-}" in
    list)   tier_list "${2:?list <core|nightly|full>}" "${3:-tests}" ;;
    of)     tier_of "${2:?of <file>}" ;;
    reason) tier_reason "${2:?reason <file>}" ;;
    claim)  tier_claim  "${2:?claim <file>}" ;;
    budget) tier_budget "${2:?budget <core|full>}" ;;
    scale)  tier_cal_scale_pct "${2:?scale <measured_us> [baseline_us]}" "${3:-$TIER_CAL_BASELINE_US}" ;;
    clamp)  tier_cal_clamp_pct "${2:?clamp <raw_pct>}" ;;
    diverge) tier_cal_diverge_pct "${2:?diverge <pre_us> <post_us>}" "${3:?diverge <pre_us> <post_us>}" ;;
    refadmit) shift; tier_cal_ref_admissible "${1:?refadmit <candidate_us> <current_us> <concordant_sample>...}" "${2:?refadmit <candidate_us> <current_us> <concordant_sample>...}" "${@:3}" ;;
    *) printf 'usage: tier.sh {list core|nightly|full [dir] | of <file> | reason <file> | claim <file> | budget core|full | scale <us> [baseline] | clamp <pct> | diverge <pre_us> <post_us> | refadmit <candidate_us> <current_us> <concordant_sample>...}\n' >&2; exit 2 ;;
  esac
fi
