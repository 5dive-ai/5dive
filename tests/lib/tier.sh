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
    *) printf 'usage: tier.sh {list core|nightly|full [dir] | of <file> | reason <file> | claim <file> | budget core|full}\n' >&2; exit 2 ;;
  esac
fi
