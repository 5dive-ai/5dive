#!/usr/bin/env bash
# DIVE-4391: REGENERATE tests/lib/harness-weights.tsv FROM THE LAST GREEN MAIN RUN.
#
# The corpus jobs shard `tests/` by MEASURED TIME (tier_shard_assign in
# tests/lib/tier.sh). The weights it assigns from are COMMITTED, not fetched per job,
# and that is the load-bearing choice: every shard leg of a matrix computes the whole
# plan independently, so the plan must be a function of the CHECKOUT and of nothing
# else. A per-job fetch that succeeded on shard 1 and hiccuped on shard 2 would give
# the two legs different plans, and a harness would then run twice or not at all —
# a false green nobody would see, which is a strictly worse defect than the imbalance
# this fixes.
#
# A STALE TABLE IS SAFE AND A MISSING ONE IS SAFE. Weights only decide WHICH shard a
# harness lands in; they never move a cap, a verdict or an exit code. Unknown files
# are priced at the median rather than free (a new harness that plans as 0ms is
# exactly how the next author inherits the red), and a table too thin to be worth
# using falls the assignment back to the old round-robin, said out loud in the report
# header as shard_mode=count.
#
# DIVE-4519: THE TABLE MUST PRICE THE TIER THE PLAN IS FOR. The corpus jobs that
# shard by this table include the FULL sweep, and `tier_list full` is every harness in
# tests/ — core and nightly alike. The baseline fetch used to read only the core
# artifacts of a green unit-tests run, where a `# TIER: nightly` harness never runs, so
# every nightly harness arrived with NO ROW and was priced at the median (~1s). The
# planner then packed them together on the strength of a price that was not a
# measurement. Measured on full-sweep 35313238307 (main, f5e91ee1): shard 1 was planned
# at 323s of harnesses it had prices for and ran 1357s against a 1320s budget (exit 4,
# every one of its 204 harnesses green), while shards 2 and 3 idled at 811s and 644s.
# The three most expensive harnesses in the corpus — gate_channel_session_t2_mutation
# (350s), selfcheck_mutation_e2e (152s), harness_rc_corpus_contract_unit (119s) — are
# all nightly, were all absent from the table, and all landed in shard 1: ~620s of a
# 1320s budget that the planner could not see. So this script now asks for
# `--tiers=core+full` and merges the two.
#
# FULL WINS EVERY OVERLAP, and that is the whole merge rule. A harness measured in both
# tiers has two honest numbers; the one that belongs in this table is the one from the
# environment the widest plan runs in. Taking the max instead would be a different
# claim ("the worst case anywhere"), and taking core would reintroduce the defect for
# every harness that happens to run in both.
#
# A CORE-ONLY TABLE IS REFUSED, not quietly written. Regenerating without the full
# rows produces a table that looks fresh, passes the >=90% CORE coverage arm in
# tests/corpus_tier_budget_unit.sh, and leaves the full plan exactly as broken as it
# was — the failure mode this row exists to close. `--allow-core-only` is the recorded
# escape for a box whose full-sweep artifacts have aged out, and it stamps `tiers=core`
# into the header so the table says which plan it cannot price.
#
# Run it from a checkout with `gh` authenticated, then commit the result:
#   bash scripts/refresh-harness-weights.sh && git add tests/lib/harness-weights.tsv
set -uo pipefail

allow_core_only=0
case "${1:-}" in
  "") ;;
  --allow-core-only) allow_core_only=1 ;;
  *) printf 'usage: refresh-harness-weights.sh [--allow-core-only]\n' >&2; exit 2 ;;
esac

out="tests/lib/harness-weights.tsv"
[[ -d tests/lib ]] || { printf 'refresh-harness-weights: run me from the repo root\n' >&2; exit 2; }

tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT

run_id=""; full_run=""; full_envs=0
for env in pristine installed; do
  mkdir -p "$tmp/$env"
  ( cd "$tmp/$env" && GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$(git -C "$OLDPWD" remote get-url origin 2>/dev/null | sed 's#.*github.com[:/]##; s/\.git$//')}" \
      bash "$OLDPWD/.github/scripts/fetch-budget-baseline.sh" "$env" --tiers=core+full ) >"$tmp/$env.log" 2>&1
  if ! compgen -G "$tmp/$env/baseline-reports/*.txt" >/dev/null; then
    printf 'refresh-harness-weights: no %s baseline reports — table NOT rewritten.\n' "$env" >&2
    sed -n '1,3p' "$tmp/$env.log" >&2
    exit 1
  fi
  [[ -n "$run_id" ]] || run_id="$(grep -oE 'baseline is run [0-9]+' "$tmp/$env.log" | grep -oE '[0-9]+' | head -1)"
  if compgen -G "$tmp/$env/baseline-reports-full/*.txt" >/dev/null; then
    full_envs=$(( full_envs + 1 ))
    [[ -n "$full_run" ]] || full_run="$(grep -oE 'full-tier rows are run [0-9]+' "$tmp/$env.log" | grep -oE '[0-9]+' | head -1)"
  fi
done

# BOTH environments or neither. One environment priced from the full sweep and the
# other from core alone is a table whose two columns describe different corpora, and
# tier_shard_assign picks its column by environment — so the pristine plan would be
# fixed and the installed plan would still pack the nightly harnesses, from a table
# that reads as complete.
tiers=core+full
if (( full_envs != 2 )); then
  if (( allow_core_only )); then
    tiers=core
    printf 'refresh-harness-weights: WARNING — full-tier rows present for %d/2 environment(s); writing a CORE-ONLY table because --allow-core-only was given.\n' "$full_envs" >&2
    printf 'refresh-harness-weights: the full-sweep plan will keep pricing every nightly harness at the median. The header records tiers=core.\n' >&2
    # DISCARD THE HALF THAT DID ARRIVE. A core-only table must be core-only in fact and
    # not merely in its header: keeping the one environment whose full fetch succeeded
    # is exactly the split this branch exists to refuse, and it would ship a table
    # stamped tiers=core whose pristine column was priced from the full sweep. Caught
    # by tests/budget_baseline_full_tier_unit.sh T14a/T14b, which read a PRICE rather
    # than a row count.
    for env in pristine installed; do rm -rf "${tmp:?}/$env/baseline-reports-full"; done
    full_run=""
  else
    printf 'refresh-harness-weights: full-tier rows present for %d/2 environment(s) — table NOT rewritten.\n' "$full_envs" >&2
    printf 'refresh-harness-weights: a core-only table looks fresh and leaves the full-sweep plan as broken as it was (DIVE-4519). Re-run when a completed full-sweep run on main still has its artifacts, or pass --allow-core-only to accept that and stamp it in the header.\n' >&2
    for env in pristine installed; do sed -n '/NO FULL-TIER ROWS/,+2p' "$tmp/$env.log" >&2; done
    exit 1
  fi
fi

# ms<TAB>rc<TAB>path, '#' headers skipped, rc=0 rows only: a harness that FAILED did
# not spend the time it would spend passing, so pricing the plan off a red row plans
# the next shard against a cost that does not exist.
reports=()
for env in pristine installed; do
  for d in baseline-reports baseline-reports-full; do
    compgen -G "$tmp/$env/$d/*.txt" >/dev/null || continue
    for r in "$tmp/$env/$d"/*.txt; do reports+=("$r"); done
  done
done

# ms<TAB>rc<TAB>path, '#' headers skipped, rc=0 rows only (see above). The environment
# comes from the enclosing directory and the TIER from the reports directory, both of
# which this script created — never from the report's own name, which the tiers have
# no reason to keep in step.
awk -F'\t' '
  FNR == 1 {
    env  = (FILENAME ~ /\/pristine\//) ? "p" : "i"
    tier = (FILENAME ~ /\/baseline-reports-full\//) ? "f" : "c"
  }
  /^#/ { next }
  NF >= 3 && $1 ~ /^[0-9]+$/ && $2 == "0" {
    # Max WITHIN a (tier, environment): a harness a tier ran on three shards, or a
    # report carrying a retry, gives the slowest honest reading for that tier.
    if ($1 > m[tier, env, $3]) m[tier, env, $3] = $1
    seen[$3] = 1
  }
  function price(env, f) {
    # FULL WINS THE OVERLAP — the merge rule, in one place. Core is the fallback for a
    # harness the full sweep did not measure green, and -1 ("not measured in this
    # environment") is what the table means by no reading at all.
    if (("f", env, f) in m) return m["f", env, f]
    if (("c", env, f) in m) return m["c", env, f]
    return -1
  }
  END {
    n = 0; for (f in seen) paths[n++] = f
    for (a = 1; a < n; a++) { k = paths[a]; b = a - 1
      while (b >= 0 && paths[b] > k) { paths[b+1] = paths[b]; b-- }
      paths[b+1] = k }
    for (a = 0; a < n; a++) { f = paths[a]
      printf "%s\t%d\t%d\n", f, price("p", f), price("i", f) }
  }
' "${reports[@]}" > "$tmp/body.tsv"

rows="$(wc -l < "$tmp/body.tsv")"
(( rows > 0 )) || { printf 'refresh-harness-weights: the green run measured 0 passing harnesses — table NOT rewritten.\n' >&2; exit 1; }

{
  printf '# harness weights — MEASURED milliseconds per harness, per environment (DIVE-4391).\n'
  printf '# Regenerate with scripts/refresh-harness-weights.sh; never hand-edit a number.\n'
  # tiers= and full_run= are not decoration: a table that prices only the core tier
  # is a legitimate artefact of an aged-out retention window, and the plan it cannot
  # price is not visible in any number below (DIVE-4519).
  printf '# generated=%s source_run=%s full_run=%s tiers=%s rows=%s\n' \
    "$(date -u +%Y-%m-%d)" "${run_id:-unknown}" "${full_run:-none}" "$tiers" "$rows"
  printf '# path\tpristine_ms\tinstalled_ms   (-1 = not measured green in that environment)\n'
  cat "$tmp/body.tsv"
} > "$out"

printf 'refresh-harness-weights: wrote %s (%s harnesses, tiers=%s, core run %s, full run %s)\n' \
  "$out" "$rows" "$tiers" "${run_id:-unknown}" "${full_run:-none}"
