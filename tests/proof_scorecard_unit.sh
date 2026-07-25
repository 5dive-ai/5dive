#!/usr/bin/env bash
# DIVE-1914 unit: `proof scorecard` must never render a metric that has no
# source as a NUMBER.
#
# The whole point of this verb: a metric with no source renders 0.0% and reads
# as "we never get blocked" / "we never roll back" — a confident zero on the
# honesty instrument itself, which is the succeeding-in-appearance class. So the
# assertions here are mostly NEGATIVE: given inputs where a source is missing or
# empty, no number may appear. A test that only checks the happy path would pass
# on exactly the build we are trying to prevent.
#
# Drives the embedded python renderer with fixtures — no digest, no db, no root.
#   bash tests/proof_scorecard_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/proof-scorecard.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

awk "/python3 <<'SCOREPY'/{f=1;next} f&&/^SCOREPY\$/{f=0} f" src/cmd_proof.sh > "$TMP/score.py"
[[ -s "$TMP/score.py" ]] || { echo "FAIL - could not extract scorecard python"; exit 1; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# run <digest-json> <usage-json> <db_rows> <tier_rows> [as_json]
run() {
  printf '%s' "$1" > "$TMP/d.json"
  printf '%s' "$2" > "$TMP/u.json"
  DIGEST_FILE="$TMP/d.json" USAGE_FILE="$TMP/u.json" DB_ROWS="$3" TIER_ROWS="$4" \
  WINDOW="7d" BY="tier" AS_JSON="${5:-1}" python3 "$TMP/score.py"
}

FULL_DIGEST='{"zeroHuman":{"shipped":100,"humanTouches":10},"stuck":{"mttuSec":600,"episodes":4},"precedentPrefill":{"count":8,"accepted":4,"acceptanceRate":50}}'
FULL_USAGE='{"agents":[{"name":"a","total":1000},{"name":"b","total":1000}]}'

# --- Case 1: everything sourced -> real numbers, and NOTHING marked no-data
#     except the two that genuinely have no source anywhere.
OUT="$(run "$FULL_DIGEST" "$FULL_USAGE" "100|50|40|30" "0|10
1|20
untiered|70")"
ND="$(jq -r '[.metrics[]|select(.value==null)|.name]|join(",")' <<<"$OUT")"
[[ "$ND" == "policy-blocked action attempts,autonomous rollback rate" ]] \
  && ok_t "fully-sourced run marks EXACTLY the two genuinely-sourceless metrics" \
  || bad_t "no-data set" "got: $ND"
[[ "$(jq -r '.metrics[]|select(.name=="verifier first-pass rate")|.value' <<<"$OUT")" == "80.0%" ]] \
  && ok_t "verifier first-pass computed verbatim (40/50)" || bad_t "first-pass" "$OUT"
[[ "$(jq -r '.metrics[]|select(.name=="tokens per accepted outcome")|.value' <<<"$OUT")" == "20" ]] \
  && ok_t "tokens per accepted outcome computed verbatim (2000/100)" || bad_t "tokens" "$OUT"

# --- Case 2: THE CORE ASSERTION. Sources missing/empty must yield NO DATA, and
#     specifically must never yield 0, 0%, or 0.0%.
EMPTY='{"zeroHuman":{},"stuck":{},"precedentPrefill":{}}'
OUT2="$(run "$EMPTY" "" "0|0|0|0" "")"
ZEROS="$(jq -r '[.metrics[]|select(.value=="0%" or .value=="0.0%" or .value==0 or .value=="0")]|length' <<<"$OUT2")"
[[ "$ZEROS" == "0" ]] \
  && ok_t "NO metric renders a bare zero when its source is empty" \
  || bad_t "confident zero rendered" "$OUT2"
ALL_ND="$(jq -r '[.metrics[]|select(.value==null)]|length' <<<"$OUT2")"
[[ "$ALL_ND" == "7" ]] \
  && ok_t "every metric degrades to an explicit no-data marker on an empty digest" \
  || bad_t "degrade" "only $ALL_ND of 7 marked no-data"
MISSING_WHY="$(jq -r '[.metrics[]|select(.value==null and ((.nodata//"")==""))]|length' <<<"$OUT2")"
[[ "$MISSING_WHY" == "0" ]] \
  && ok_t "every no-data marker carries a REASON, never a bare blank" \
  || bad_t "nodata reason" "$MISSING_WHY markers have no reason"

# --- Case 3: the two sourceless metrics stay no-data even when handed numbers.
#     Nothing in the input should be able to talk them into rendering.
OUT3="$(run "$FULL_DIGEST" "$FULL_USAGE" "100|50|50|100" "0|100")"
for m in "policy-blocked action attempts" "autonomous rollback rate"; do
  v="$(jq -r --arg m "$m" '.metrics[]|select(.name==$m)|.value' <<<"$OUT3")"
  [[ "$v" == "null" ]] && ok_t "'$m' stays no-data on a fully-populated run" \
    || bad_t "$m leaked a value" "got '$v'"
done
# ...and each names the task that would build its source, so the reader learns
# WHY rather than merely THAT.
jq -e '[.metrics[]|select(.value==null and (.nodata|test("DIVE-19")))]|length==2' <<<"$OUT3" >/dev/null \
  && ok_t "both sourceless metrics name the task that would build the source" \
  || bad_t "nodata task refs" "$(jq -c '[.metrics[]|select(.value==null)|.nodata]' <<<"$OUT3")"

# --- Case 4: tier coverage must be reported, and untiered must be VISIBLE.
#     A breakdown of 0/1/2 without coverage reads as the shape of the whole.
OUT4="$(run "$FULL_DIGEST" "$FULL_USAGE" "100|50|40|30" "0|10
1|20
untiered|70")"
[[ "$(jq -r '.tierCoverage.pct == 30' <<<"$OUT4")" == "true" ]] \
  && ok_t "tier coverage reported as a percentage of ALL shipped work (30/100)" \
  || bad_t "coverage" "$(jq -c '.tierCoverage' <<<"$OUT4")"
[[ "$(jq -r '.tierBreakdown[]|select(.tier=="untiered")|.shipped' <<<"$OUT4")" == "70" ]] \
  && ok_t "untiered work appears as its own visible bucket, not dropped" \
  || bad_t "untiered bucket" "$(jq -c '.tierBreakdown' <<<"$OUT4")"

# --- Case 5: sample sizes ride ON the sourced numbers, not in a footnote.
for m in "verifier first-pass rate" "median recovery time" "precedent acceptance rate"; do
  s="$(jq -r --arg m "$m" '.metrics[]|select(.name==$m)|.sample' <<<"$OUT")"
  [[ -n "$s" && "$s" != "null" ]] && ok_t "'$m' carries its sample size" \
    || bad_t "$m sample" "sample='$s'"
done

# --- Case 6: the row is NAMED for what it measures. "cost" would be a claim the
#     data cannot support — the work runs on a subscription, so no money figure
#     exists at all, and that is stated as a fact rather than left silent.
jq -e '[.metrics[]|select(.name|test("cost";"i"))]|length==0' <<<"$OUT" >/dev/null \
  && ok_t "no metric is NAMED 'cost' (the row name is the claim, not a footnote)" \
  || bad_t "cost row" "$(jq -c '[.metrics[].name]' <<<"$OUT")"
jq -e '.moneyNote|test("subscription")' <<<"$OUT" >/dev/null \
  && ok_t "the absence of a money figure is stated explicitly, with the reason" \
  || bad_t "money note" "$(jq -r '.moneyNote' <<<"$OUT")"

# --- Case 7: the badge stays the headline; the scorecard never supplants it.
jq -e '.headline.note|test("headline")' <<<"$OUT" >/dev/null \
  && ok_t "output states the badge remains the headline number" || bad_t "headline note"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
