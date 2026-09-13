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
# Run it from a checkout with `gh` authenticated, then commit the result:
#   bash scripts/refresh-harness-weights.sh && git add tests/lib/harness-weights.tsv
set -uo pipefail

out="tests/lib/harness-weights.tsv"
[[ -d tests/lib ]] || { printf 'refresh-harness-weights: run me from the repo root\n' >&2; exit 2; }

tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT

run_id=""; head_sha=""
for env in pristine installed; do
  mkdir -p "$tmp/$env"
  ( cd "$tmp/$env" && GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$(git -C "$OLDPWD" remote get-url origin 2>/dev/null | sed 's#.*github.com[:/]##; s/\.git$//')}" \
      bash "$OLDPWD/.github/scripts/fetch-budget-baseline.sh" "$env" ) >"$tmp/$env.log" 2>&1
  if ! compgen -G "$tmp/$env/baseline-reports/*.txt" >/dev/null; then
    printf 'refresh-harness-weights: no %s baseline reports — table NOT rewritten.\n' "$env" >&2
    sed -n '1,3p' "$tmp/$env.log" >&2
    exit 1
  fi
  [[ -n "$run_id" ]] || run_id="$(grep -oE 'run [0-9]+' "$tmp/$env.log" | grep -oE '[0-9]+' | head -1)"
done

# ms<TAB>rc<TAB>path, '#' headers skipped, rc=0 rows only: a harness that FAILED did
# not spend the time it would spend passing, so pricing the plan off a red row plans
# the next shard against a cost that does not exist.
awk -F'\t' '
  FNR == 1 { env = (FILENAME ~ /pristine/) ? "p" : "i" }
  /^#/ { next }
  NF >= 3 && $1 ~ /^[0-9]+$/ && $2 == "0" {
    if (env == "p") { if ($1 > p[$3]) p[$3] = $1 } else { if ($1 > i[$3]) i[$3] = $1 }
    seen[$3] = 1
  }
  END {
    n = 0; for (f in seen) paths[n++] = f
    for (a = 1; a < n; a++) { k = paths[a]; b = a - 1
      while (b >= 0 && paths[b] > k) { paths[b+1] = paths[b]; b-- }
      paths[b+1] = k }
    for (a = 0; a < n; a++) { f = paths[a]
      printf "%s\t%d\t%d\n", f, (f in p ? p[f] : -1), (f in i ? i[f] : -1) }
  }
' "$tmp"/pristine/baseline-reports/*.txt "$tmp"/installed/baseline-reports/*.txt > "$tmp/body.tsv"

rows="$(wc -l < "$tmp/body.tsv")"
(( rows > 0 )) || { printf 'refresh-harness-weights: the green run measured 0 passing harnesses — table NOT rewritten.\n' >&2; exit 1; }

{
  printf '# harness weights — MEASURED milliseconds per harness, per environment (DIVE-4391).\n'
  printf '# Regenerate with scripts/refresh-harness-weights.sh; never hand-edit a number.\n'
  printf '# generated=%s source_run=%s rows=%s\n' "$(date -u +%Y-%m-%d)" "${run_id:-unknown}" "$rows"
  printf '# path\tpristine_ms\tinstalled_ms   (-1 = not measured green in that environment)\n'
  cat "$tmp/body.tsv"
} > "$out"

printf 'refresh-harness-weights: wrote %s (%s harnesses, run %s)\n' "$out" "$rows" "${run_id:-unknown}"
