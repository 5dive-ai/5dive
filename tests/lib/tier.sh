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
# FULL = 1320s (22 min). MEASURED, not aspirational: release-cut.yml's own published
# figure is 3.79s per harness (164 harnesses in 10m21s, 168 in 10m37s), and an
# independent serial timing of the whole corpus on the control plane agreed with it
# to within 1%. Today's 267-harness corpus is therefore ~1010s of pure harness time.
# 1320 is that plus ~30% — which is RUNNER VARIANCE, not growth room. At the observed
# +13/day it is roughly three weeks of headroom, and the run prints its
# percentage-of-budget every time so the trend is legible before it reds, not after.
TIER_BUDGET_CORE=300
TIER_BUDGET_FULL=1320

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
    budget) tier_budget "${2:?budget <core|full>}" ;;
    *) printf 'usage: tier.sh {list core|nightly|full [dir] | of <file> | reason <file> | budget core|full}\n' >&2; exit 2 ;;
  esac
fi
