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

got=0
for shard_name in "core-$env-1" "core-$env-2"; do
  art_id="$(awk -F'\t' -v n="$shard_name" '$2 == n { print $1; exit }' <<<"$arts")"
  [[ -n "$art_id" ]] || continue
  tmp_zip="$(mktemp "${TMPDIR:-/tmp}/budget-baseline.XXXXXX.zip")" || continue
  if gh api "repos/$repo/actions/artifacts/$art_id/zip" > "$tmp_zip" 2>/dev/null \
     && unzip -o -q "$tmp_zip" -d "$out" 2>/dev/null; then
    got=$(( got + 1 ))
  fi
  rm -f "$tmp_zip"
done
# The artifact also carries the shard's verdict hand-off file; only the report TSVs
# are the baseline, and passing verdict files would feed the join lines it must skip.
rm -f "$out"/core-verdict-*.txt 2>/dev/null || true

(( got > 0 )) || disarm "run $run_id carried no core-$env-* artifacts"
printf 'fetch-budget-baseline: baseline is run %s (%s, %s), %d shard artifact(s):\n' \
  "$run_id" "$head_sha" "$created_at" "$got"
ls -l "$out"
