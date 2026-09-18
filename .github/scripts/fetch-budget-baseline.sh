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
#
# DIVE-4519: A SECOND TIER, BEHIND A FLAG, IN A SEPARATE DIRECTORY.
# `--tiers=core+full` additionally fetches the `full-<env>-<shard>` reports of the
# most recent full-sweep run on main. Two deliberate choices:
#
#   IT IS OPT-IN AND THE DEFAULT IS TODAY. The confirm jobs call this script with no
#   flag and get byte-identical behaviour, because they must: `tier_budget_attribution`
#   keys its baseline on the harness PATH, `tier_list full` is EVERY harness (core
#   included, tests/lib/tier.sh), and its awk takes the last row read for a path
#   rather than the max. Unzipping full reports into `baseline-reports/` would
#   therefore reprice the whole attribution baseline from a different run, silently
#   and in a direction nobody chose — under the glob's own sort order, `full-*` after
#   `core-*`, the full price would win every overlap. Only the weights table wants
#   full-tier prices, so only it asks.
#
#   FULL-TIER RUNS ARE NOT REQUIRED TO BE GREEN, and that is not a softening of the
#   rule above. The green-only rule protects a baseline used to RELIEVE a red; these
#   rows are used only to decide which shard a harness lands in, where a stale or
#   missing number is already safe (scripts/refresh-harness-weights.sh says so at
#   length). Requiring success here would also deadlock the one job it has: the
#   full sweep goes red BECAUSE a shard is over budget, which is exactly the
#   imbalance these rows exist to remove. Measured 2026-09-18 on 5dive-ai/5dive: the
#   five most recent full-sweep runs on main were all `failure`, so a success filter
#   would fetch nothing at all. The rc=0 filter downstream is what keeps a red
#   shard's failing rows out; its PASSING rows spent the time they say they spent.
set -uo pipefail

usage='usage: fetch-budget-baseline.sh <pristine|installed> [--tiers=core|core+full]'
env="${1:?$usage}"
case "$env" in
  pristine|installed) ;;
  *) printf 'fetch-budget-baseline: unknown environment %s (want pristine|installed)\n' "$env" >&2; exit 2 ;;
esac
tiers=core
if (( $# > 1 )); then
  case "$2" in
    --tiers=core|--tiers=core+full) tiers="${2#--tiers=}" ;;
    *) printf 'fetch-budget-baseline: unknown argument %s\n%s\n' "$2" "$usage" >&2; exit 2 ;;
  esac
fi
(( $# <= 2 )) || { printf 'fetch-budget-baseline: too many arguments\n%s\n' "$usage" >&2; exit 2; }
repo="${GITHUB_REPOSITORY:?fetch-budget-baseline: GITHUB_REPOSITORY is not set}"
out="baseline-reports"
# The full-tier reports get their OWN directory, never $out — see the DIVE-4519 note
# in the header. The caller that wants them knows where they are; the caller that
# globs $out cannot pick them up by accident, which is the point.
out_full="baseline-reports-full"
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
#
# DIVE-4519: the enumeration is now a FUNCTION, because there are two tiers to
# enumerate and the argument above is not about the word "core" — it is about never
# hand-writing a shard list. `<prefix>` is `core-$env` or `full-$env`; the `[0-9]+$`
# anchor is what keeps `core-<env>-confirm-<n>` and the full sweep's `probe-*`
# artifacts out of a baseline, in both tiers.
# Prints: got<TAB>matched<TAB>space-separated artifact names.
fetch_tier() { # <artifact-prefix> <dest-dir> <artifact-listing>
  local prefix="$1" dest="$2" listing="$3"
  local art_id shard_name tmp_zip got=0 matched=0
  local -a seen=()
  mkdir -p "$dest"
  while IFS=$'\t' read -r art_id shard_name; do
    [[ -n "$art_id" ]] || continue
    matched=$(( matched + 1 ))
    tmp_zip="$(mktemp "${TMPDIR:-/tmp}/budget-baseline.XXXXXX.zip")" || continue
    if gh api "repos/$repo/actions/artifacts/$art_id/zip" > "$tmp_zip" 2>/dev/null \
       && unzip -o -q "$tmp_zip" -d "$dest" 2>/dev/null; then
      got=$(( got + 1 ))
      seen+=("$shard_name")
    fi
    rm -f "$tmp_zip"
  done < <(awk -F'\t' -v re="^$prefix-[0-9]+$" '$2 ~ re { print $1 "\t" $2 }' <<<"$listing" \
             | sort -t- -k3,3n -u)
  # The artifact also carries the shard's verdict hand-off file; only the report TSVs
  # are the baseline, and passing verdict files would feed the join lines it must skip.
  # Globbed by SHAPE rather than by tier: core uploads `core-verdict-<env>-<n>.txt`,
  # full uploads none today, and a tier that starts uploading one must not need an
  # edit here to stay out of the join.
  rm -f "$dest"/*verdict*.txt 2>/dev/null || true
  printf '%s\t%s\t%s\n' "$got" "$matched" "${seen[*]-}"
}

IFS=$'\t' read -r got matched shards_seen_str < <(fetch_tier "core-$env" "$out" "$arts")

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
  "$run_id" "$head_sha" "$created_at" "$got" "$shards_seen_str"
ls -l "$out"

# ── DIVE-4519: the full-tier addendum ────────────────────────────────────────────
# Everything below runs ONLY for --tiers=core+full and can only ADD a directory the
# default caller never looks at. A failure here therefore does NOT disarm: the core
# baseline above is what the attribution instrument consults, it is already fetched
# and already guarded, and throwing it away because a SECOND, unrelated fetch missed
# would turn "the weights table is stale" — which is safe by construction — into "an
# over-budget red went unattributed", which is not. The full dir is left EMPTY and
# said out loud, and scripts/refresh-harness-weights.sh is the caller that decides
# what an empty one means for it.
[[ "$tiers" == "core+full" ]] || exit 0

mkdir -p "$out_full"
rm -f "$out_full"/*.txt 2>/dev/null || true

no_full() { # <why>
  rm -f "$out_full"/*.txt 2>/dev/null || true
  printf 'fetch-budget-baseline: NO FULL-TIER ROWS — %s.\n' "$1"
  printf 'The core baseline above is unaffected. A caller that wanted full-tier prices\n'
  printf 'must treat %s/ being empty as "not measured", never as "measured at zero".\n' "$out_full"
  exit 0
}

# THE MOST RECENT RUN WHOSE REPORTS EXIST, not the most recent run. A full-sweep run
# that was cancelled before its shards uploaded, or one whose artifacts have aged past
# the retention window, lists nothing matching — and stopping at the first such run
# would report "no full-tier rows" while last night's are sitting one row down. So
# walk the page until a run actually carries `full-$env-<shard>` artifacts.
full_runs="$(gh api "repos/$repo/actions/workflows/full-sweep.yml/runs?branch=main&status=completed&per_page=10" \
  --jq '.workflow_runs[] | "\(.id)\t\(.head_sha)\t\(.created_at)\t\(.conclusion)"' 2>/dev/null)" || full_runs=""
[[ -n "$full_runs" && "$full_runs" != "null"* ]] || no_full "could not resolve a completed full-sweep run on main"

full_id=""; full_sha=""; full_at=""; full_concl=""; full_arts=""
while IFS=$'\t' read -r cand_id cand_sha cand_at cand_concl; do
  [[ "$cand_id" =~ ^[0-9]+$ ]] || continue
  cand_arts="$(gh api "repos/$repo/actions/runs/$cand_id/artifacts?per_page=100" \
    --jq '.artifacts[] | "\(.id)\t\(.name)"' 2>/dev/null)" || cand_arts=""
  [[ -n "$cand_arts" ]] || continue
  awk -F'\t' -v re="^full-$env-[0-9]+$" '$2 ~ re { found = 1 } END { exit !found }' <<<"$cand_arts" || continue
  full_id="$cand_id"; full_sha="$cand_sha"; full_at="$cand_at"; full_concl="$cand_concl"
  full_arts="$cand_arts"
  break
done <<<"$full_runs"
[[ -n "$full_id" ]] || no_full "no completed full-sweep run on main in the last 10 carries full-$env-* artifacts (retention window, or none has uploaded yet)"

IFS=$'\t' read -r fgot fmatched fshards_str < <(fetch_tier "full-$env" "$out_full" "$full_arts")
# MATCHED IS NOT FETCHED, here too (DIVE-4374's argument, one tier over). A partial
# full-tier table is worse than none: the shard whose reports arrived would price its
# harnesses honestly while the shard that failed to download keeps pricing its own at
# the median, so the planner would pack the half it cannot see — the very defect this
# flag exists to remove, arriving with a reassuring row count.
(( fgot == fmatched )) || no_full "full-sweep run $full_id carries $fmatched full-$env-* shard artifact(s) but only $fgot could be fetched — a partial full-tier table prices the missing shard at the median, which is the imbalance this tier exists to fix"
(( fgot > 0 )) || no_full "full-sweep run $full_id carried no full-$env-* artifacts"

printf 'fetch-budget-baseline: full-tier rows are run %s (%s, %s, conclusion=%s), %d shard artifact(s) [%s]:\n' \
  "$full_id" "$full_sha" "$full_at" "$full_concl" "$fgot" "$fshards_str"
ls -l "$out_full"
