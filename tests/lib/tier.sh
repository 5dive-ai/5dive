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
# ALL FOUR CONSTANTS BELOW ARE STARTING VALUES TO BE RE-DERIVED FROM A REAL CI RUN,
# not findings (DIVE-2710 says so explicitly). TIER_CAL_BASELINE_US in particular was
# measured on the CONTROL PLANE, not on a GitHub runner — see its own note.
TIER_CAL_SCALE_MIN_PCT=100
TIER_CAL_SCALE_MAX_PCT=150

# TIER_CAL_BASELINE_US — the calibration workload's cost, in MICROSECONDS PER
# ITERATION, on a runner drawing normal.
#
# MEASURED 2026-08-05 ON THE CONTROL PLANE (5dive host, agent-dev3), min of 2
# auto-sized samples, twice: 173186us/iter (59 iters) and 172907us/iter (54 iters).
# Two independent runs 0.16% apart, which is the number that says the probe is fit for
# purpose: its own error has to sit far under the 9% headroom it is protecting, or a
# relative budget is just a noisier absolute one (trap 1). 173000 is that reading.
#
# IT IS NOT A GITHUB-RUNNER NUMBER, and this line says so on purpose — DIVE-2555's
# whole finding is that a measurement with no environment attached cannot be refuted
# by the next reading, only silently disagreed with. The first CI run prints its own
# cal_us_per_iter in the report and will trip the re-baseline warning below if the two
# environments differ by >= TIER_CAL_REBASELINE_PCT. THAT WARNING FIRING ON THE FIRST
# CI RUN IS THE MECHANISM WORKING, and the number it prints is what this constant
# should be re-set to. Until then the clamp bounds the blast radius in both
# directions: a CI runner slower than this box gets at most 1.5x, and one faster than
# it gets exactly today's 300s.
TIER_CAL_BASELINE_US=173000

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
    *) printf 'usage: tier.sh {list core|nightly|full [dir] | of <file> | reason <file> | claim <file> | budget core|full | scale <us> [baseline] | clamp <pct>}\n' >&2; exit 2 ;;
  esac
fi
