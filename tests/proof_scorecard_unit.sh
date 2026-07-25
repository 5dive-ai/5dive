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

# run <digest-json> <usage-json> <db_rows> <group_rows> [as_json] [by]
run() {
  printf '%s' "$1" > "$TMP/d.json"
  printf '%s' "$2" > "$TMP/u.json"
  DIGEST_FILE="$TMP/d.json" USAGE_FILE="$TMP/u.json" DB_ROWS="$3" GROUP_ROWS="$4" \
  WINDOW="7d" BY="${6:-tier}" AS_JSON="${5:-1}" python3 "$TMP/score.py"
}

FULL_DIGEST='{"zeroHuman":{"shipped":100,"humanTouches":10},"stuck":{"mttuSec":600,"episodes":4},"precedentPrefill":{"count":8,"accepted":4,"acceptanceRate":50}}'
# DIVE-1929: a usage read now declares its own coverage, and the tokens row
# renders a number ONLY when the read was complete. The fixture carries it.
FULL_USAGE='{"agents":[{"name":"a","total":1000},{"name":"b","total":1000}],
             "coverage":{"agentsExpected":2,"agentsRead":2,"unreadable":[],"complete":true}}'
PARTIAL_USAGE='{"agents":[{"name":"a","total":1000}],
             "coverage":{"agentsExpected":16,"agentsRead":2,"complete":false,
             "unreadable":[{"name":"b","reason":"home not readable by this user (needs root)"}]}}'
UNLABELLED_USAGE='{"agents":[{"name":"a","total":1000},{"name":"b","total":1000}]}'

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
jq -e '.metrics[]|select(.name=="tokens per accepted outcome")|.sample|test("2 of 2 agent transcript sets readable")' <<<"$OUT" >/dev/null \
  && ok_t "a complete token read still SHIPS its coverage on the row (DIVE-1922 rule)" \
  || bad_t "coverage on complete read" "$(jq -c '.metrics[]|select(.name|test("tokens"))' <<<"$OUT")"

# --- Case 1b (DIVE-1929): THE NEGATIVE CONTROL for this row. A PARTIAL read is
#     the dangerous state — it is the only one that emits a number that is WRONG
#     rather than absent (root 4,670,188/outcome vs agent-olivia 220,391 for the
#     same window, 21x low, unmarked). It must not render a number at all.
OUT1B="$(run "$FULL_DIGEST" "$PARTIAL_USAGE" "100|50|40|30" "0|10
untiered|90")"
TOKV="$(jq -r '.metrics[]|select(.name=="tokens per accepted outcome")|.value' <<<"$OUT1B")"
[[ "$TOKV" == "null" ]] \
  && ok_t "PARTIAL token read renders NO DATA, never a confident number" \
  || bad_t "partial read rendered a number" "got: $TOKV"
jq -e '.metrics[]|select(.name=="tokens per accepted outcome")|.nodata|test("2 of 16")' <<<"$OUT1B" >/dev/null \
  && ok_t "the partial-read marker names the coverage it is missing" \
  || bad_t "partial nodata reason" "$(jq -c '.metrics[]|select(.name|test("tokens"))' <<<"$OUT1B")"
grep -q '10,000\|"10"' <<<"$(jq -c '.metrics[]|select(.name|test("tokens"))' <<<"$OUT1B")" \
  && bad_t "partial read leaked a computed rate into the row" || ok_t "no partial-derived rate appears anywhere on the row"

# --- Case 1c (DIVE-1929): an UNLABELLED total (an older collector that reports
#     no coverage) is indistinguishable from a partial one, so it is treated as
#     partial. Trusting it is how the bug shipped in the first place.
OUT1C="$(run "$FULL_DIGEST" "$UNLABELLED_USAGE" "100|50|40|30" "0|10")"
[[ "$(jq -r '.metrics[]|select(.name=="tokens per accepted outcome")|.value' <<<"$OUT1C")" == "null" ]] \
  && ok_t "token total with NO coverage declared is refused, not assumed complete" \
  || bad_t "unlabelled total rendered" "$OUT1C"

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
[[ "$(jq -r '.coverage.pct == 30' <<<"$OUT4")" == "true" ]] \
  && ok_t "coverage reported as a percentage of ALL shipped work (30/100)" \
  || bad_t "coverage" "$(jq -c '.coverage' <<<"$OUT4")"
[[ "$(jq -r '.breakdown.rows[]|select(.key=="untiered")|.shipped' <<<"$OUT4")" == "70" ]] \
  && ok_t "untiered work appears as its own visible bucket, not dropped" \
  || bad_t "untiered bucket" "$(jq -c '.breakdown' <<<"$OUT4")"

# --- Case 4b (DIVE-1914 iteration 2, olivia): a flag value that is accepted as
#     LEGAL must actually change what is computed. --by=class was validated and
#     then ignored, so the output said "by":"class" beside tier rows — output
#     asserting what the code never computed, the exact class this verb exists
#     to prevent. Assert the LABEL and the DATA cannot disagree, for EVERY
#     accepted value, so the next inert flag value cannot come back either.
CLASS_ROWS="dive/high|60
dive/low|40"
OUT4C="$(run "$FULL_DIGEST" "$FULL_USAGE" "100|50|40|100" "$CLASS_ROWS" 1 class)"
[[ "$(jq -r '.by' <<<"$OUT4C")" == "class" \
   && "$(jq -r '.breakdown.by' <<<"$OUT4C")" == "class" \
   && "$(jq -r '.coverage.dimension' <<<"$OUT4C")" == "class" ]] \
  && ok_t "--by=class labels the breakdown AND the coverage as class (label travels with the data)" \
  || bad_t "by=class labels" "$(jq -c '{by,b:.breakdown.by,c:.coverage.dimension}' <<<"$OUT4C")"
[[ "$(jq -r '.breakdown.rows[0].key' <<<"$OUT4C")" == "dive/high" ]] \
  && ok_t "--by=class actually groups the CLASS rows it was handed" \
  || bad_t "by=class rows" "$(jq -c '.breakdown.rows' <<<"$OUT4C")"
# THE DECISIVE ONE, and it must live at the SHELL layer. The renderer above is
# handed GROUP_ROWS by this harness, so it will happily group whatever it is
# given — a renderer-level check passes even when --by is completely inert
# (verified: reintroducing the defect did NOT fail the renderer assertions).
# The defect lives in the shell's query selection, so assert THERE: extract the
# real `case "$by"` block from the shipped source, evaluate both branches, and
# require that they produce DIFFERENT SQL. An inert --by value makes them equal,
# which is exactly how this hid the first time.
CASE_BLOCK="$(awk '/^  case "\$by" in$/{f=1} f{print} f&&/^  esac$/{exit}' src/cmd_proof.sh)"
[[ -n "$CASE_BLOCK" ]] || bad_t "extract --by case block" "not found in src/cmd_proof.sh"
eval_by() {  # <by> -> "<group_expr>|<known_expr>"
  local by="$1" group_expr="" known_expr=""
  eval "$CASE_BLOCK"
  printf '%s|%s' "$group_expr" "$known_expr"
}
TIER_SQL="$(eval_by tier)"; CLASS_SQL="$(eval_by class)"
[[ -n "$TIER_SQL" && "${TIER_SQL#|}" != "$TIER_SQL" ]] && bad_t "tier branch empty" "$TIER_SQL"
[[ -n "$CLASS_SQL" && "$CLASS_SQL" != "|" ]] \
  && ok_t "every accepted --by value produces a non-empty grouping expression" \
  || bad_t "class branch inert" "class produced '$CLASS_SQL'"
[[ "$TIER_SQL" != "$CLASS_SQL" ]] \
  && ok_t "tier and class compute DIFFERENT SQL (a legal-but-INERT --by value would make them identical)" \
  || bad_t "inert --by" "both branches produce the same SQL: $TIER_SQL"
[[ "$CLASS_SQL" == *project_key* && "$CLASS_SQL" == *priority* ]] \
  && ok_t "class groups by project_key + priority, as the spec defines class" \
  || bad_t "class expr" "$CLASS_SQL"

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
