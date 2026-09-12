#!/usr/bin/env bash
# DIVE-3580: FETCH THE LAST GREEN MAIN RUN'S PER-HARNESS REPORTS, for attributing a
# confirmed budget red before it blocks a merge.
#
# Lives here for the simulate-installed-host.sh reason: BOTH confirm jobs must fetch
# the same object the same way, and two copies of a fetch block are two baselines as
# soon as one is edited.
#
# EVERY EXIT IS 0 EXCEPT USAGE. This script arms an instrument that may only ever
# RELIEVE a red (tests/lib/tier.sh, DIVE-3580 block: 4 -> 6 on a positive uniform-lift
# measurement, never anything else). A fetch that fails must therefore disarm the
# instrument and let the red stand exactly as it did before DIVE-3580 — failing the
# JOB here would turn an API hiccup into a red on a PR whose corpus nobody measured,
# which is the exact class this whole ladder exists to remove. "No baseline" is said
# out loud and the reports directory is simply left without files; the caller's glob
# then passes no --baseline-report flags and run-harnesses.sh records
# budget_attribution=off, which is a GRADED "not consulted", not a silent skip.
#
# GREEN RUNS ONLY (status=success), and that is load-bearing: a red main run's
# reports may themselves carry the fleet-wide slow hour this is a baseline AGAINST,
# and a baseline contaminated by the weather it grades would read every slow box as
# normal. The freshest green run is the right one for the same reason — the corpus
# drifts by ~a file a day, and the common-set join in tier.sh absorbs what remains.
set -uo pipefail

env="${1:?usage: fetch-budget-baseline.sh <pristine|installed>}"
case "$env" in
  pristine|installed) ;;
  *) printf 'fetch-budget-baseline: unknown environment %s (want pristine|installed)\n' "$env" >&2; exit 2 ;;
esac
repo="${GITHUB_REPOSITORY:?fetch-budget-baseline: GITHUB_REPOSITORY is not set}"
out="baseline-reports"
mkdir -p "$out"

disarm() { # <why>
  # DIVE-4374: leave NO files behind. The caller globs this directory and passes one
  # --baseline-report flag per file it finds, so a disarm that left a half-fetched
  # shard in place would arm the instrument on a PARTIAL baseline — which is the
  # defect this script's own enumeration fix exists to close, one layer down.
  rm -f "$out"/*.txt 2>/dev/null || true
  printf 'fetch-budget-baseline: NO BASELINE — %s.\n' "$1"
  printf 'Attribution is DISARMED for this run: an over-budget verdict stands exactly as it\n'
  printf 'did before DIVE-3580. Nothing is weakened by this; only the relief is unavailable.\n'
  exit 0
}

run_line="$(gh api "repos/$repo/actions/workflows/unit-tests.yml/runs?branch=main&status=success&per_page=1" \
  --jq '.workflow_runs[0] | "\(.id)\t\(.head_sha)\t\(.created_at)"' 2>/dev/null)" || run_line=""
[[ -n "$run_line" && "$run_line" != "null"* ]] || disarm "could not resolve a green unit-tests run on main"
IFS=$'\t' read -r run_id head_sha created_at <<<"$run_line"
[[ "$run_id" =~ ^[0-9]+$ ]] || disarm "the green-run lookup returned no usable run id"

arts="$(gh api "repos/$repo/actions/runs/$run_id/artifacts?per_page=100" \
  --jq '.artifacts[] | "\(.id)\t\(.name)"' 2>/dev/null)" || arts=""
[[ -n "$arts" ]] || disarm "run $run_id lists no artifacts (expired or still uploading)"

# DIVE-4374: ENUMERATE THE SHARD ARTIFACTS THE RUN ACTUALLY CARRIES, never a
# hand-written list. This loop named `core-$env-1` and `core-$env-2` literally, from
# when the corpus matrix was two shards wide; unit-tests.yml went to three
# (`matrix: { shard: [1, 2, 3] }`) and this list did not. The third shard's
# per-harness prices were therefore never fetched, and the join in tests/lib/tier.sh
# prices every harness it has no baseline for AS ITSELF — so a third of the corpus
# arrived at its own inflated, over-budget cost. Measured on the two runs that
# ejected PR #906 from the merge queue (34666831882, 34667348433): re-running
# `tier.sh attribute` on their own reports against the same green baseline run
# 34667337255 gives `verdict=corpus common_cover_pct=39 new_files=89` with shards
# 1+2 and `verdict=runner common_cover_pct=100 new_files=0 repriced_s=296` with all
# three. The relief this script exists to arm was disarmed by arithmetic nobody
# could see, and the failure direction of a partial baseline is always TOWARD the
# red — so the enumeration must come from the artifact listing, which cannot drift
# out of step with the matrix.
got=0
matched=0
shards_seen=()
while IFS=$'\t' read -r art_id shard_name; do
  [[ -n "$art_id" ]] || continue
  matched=$(( matched + 1 ))
  tmp_zip="$(mktemp "${TMPDIR:-/tmp}/budget-baseline.XXXXXX.zip")" || continue
  if gh api "repos/$repo/actions/artifacts/$art_id/zip" > "$tmp_zip" 2>/dev/null \
     && unzip -o -q "$tmp_zip" -d "$out" 2>/dev/null; then
    got=$(( got + 1 ))
    shards_seen+=("$shard_name")
  fi
  rm -f "$tmp_zip"
done < <(awk -F'\t' -v re="^core-$env-[0-9]+$" '$2 ~ re { print $1 "\t" $2 }' <<<"$arts" \
           | sort -t- -k3,3n -u)
# The artifact also carries the shard's verdict hand-off file; only the report TSVs
# are the baseline, and passing verdict files would feed the join lines it must skip.
rm -f "$out"/core-verdict-*.txt 2>/dev/null || true

# DIVE-4374: MATCHED IS NOT FETCHED. A shard artifact the listing named but whose
# download or unzip failed leaves `got` short, and every remaining line of this
# script would then hand the confirm job a baseline covering some of the corpus —
# the same two-of-three shape the enumeration fix above removes, arriving by a
# different door and at exit 0. A thin baseline fails toward the RED, so it is never
# a false green; it is a red on harnesses the PR did not touch, which is the whole
# reason this row exists. All or nothing: either every shard the run carries is
# priced, or attribution is disarmed and the red stands as it did before DIVE-3580.
(( got == matched )) || disarm "run $run_id carries $matched core-$env-* shard artifact(s) but only $got could be fetched — a partial baseline prices the missing shard's harnesses as themselves"
(( got > 0 )) || disarm "run $run_id carried no core-$env-* artifacts"
# DIVE-4374: NAME THE SHARDS, not just the count. A baseline that silently covers
# two of three shards reads identically to a complete one in a bare number, and that
# is how this went unnoticed — the count said "2 shard artifact(s)" on a three-shard
# matrix for as long as the matrix has been three wide.
printf 'fetch-budget-baseline: baseline is run %s (%s, %s), %d shard artifact(s) [%s]:\n' \
  "$run_id" "$head_sha" "$created_at" "$got" "${shards_seen[*]-}"
ls -l "$out"
