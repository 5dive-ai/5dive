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

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/proof-scorecard.XXXXXX)"

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

# --- Case 4d (DIVE-2745, iteration 2): the RESOLVED DEFAULT WINDOW ------------
# olivia's reject: DIVE-2745 flipped this verb's default 7d -> 30d, and the
# delivery cited "proof_scorecard_unit 27/0" as the evidence. Measured: setting
# the default back to window="7d" left BOTH suites fully green. The 27 arms are
# the pre-existing suite and they pass whether or not the flip happened, so a
# green run was quoted as evidence for a change it structurally cannot see —
# the succeeding-in-appearance class, on the row whose whole thesis is that the
# window is several different quantities and moving one without the others is
# how the badge once published 51/7 against a true ~343/53.
#
# It cannot be asserted through the renderer: `run()` above passes WINDOW="7d"
# explicitly, so the extracted python never sees a default at all. Same shape as
# the --by arms directly above — the defect lives in the shell, so assert THERE.
# Extract the real arg-parse plus the span `case` from the shipped source and
# evaluate window resolution end to end.
WIN_BLOCK="$(awk '/^  local json="\$\{JSON_MODE:-0\}" window=/{f=1} f{print} f&&/^  esac$/{exit}' src/cmd_proof.sh)"
[[ -n "$WIN_BLOCK" ]] && ok_t "the scorecard's window arg-parse + span block extracted for the shell-side arms" \
  || bad_t "extract window block" "not found in src/cmd_proof.sh"
fail() { printf 'fail(%s): %s\n' "${1:-}" "${2:-}" >&2; return 1; }   # only reachable on an ILLEGAL value; the arms below pass legal ones
eval_window() {  # <args...> -> "<window>|<sql_window>|<usage_secs>"
  local E_USAGE=64 window sql_window usage_secs
  eval "$WIN_BLOCK" || return 1
  printf '%s|%s|%s' "$window" "$sql_window" "$usage_secs"
}
DEF_WIN="$(eval_window)"; SEVEN_WIN="$(eval_window --7d)"; THIRTY_WIN="$(eval_window --30d)"
# The PAIR, not just the default: an arm that only pins 30d passes if the parser
# is inert and every input resolves to 30d. Both directions, so neither a pinned
# constant nor a dead `--7d` can satisfy it.
[[ "$DEF_WIN" == "30d|-30 days|2592000" ]] \
  && ok_t "DIVE-2745: NO ARGS resolves 30d end to end (label, SQL span, usage seconds all agree)" \
  || bad_t "scorecard default window" "got: $DEF_WIN (want 30d|-30 days|2592000)"
[[ "$SEVEN_WIN" == "7d|-7 days|604800" ]] \
  && ok_t "DIVE-2745: --7d is RETAINED and still resolves 7d end to end (a deliberate narrow read stays available)" \
  || bad_t "scorecard --7d" "got: $SEVEN_WIN (want 7d|-7 days|604800)"
[[ "$DEF_WIN" == "$THIRTY_WIN" ]] \
  && ok_t "the bare default is byte-identical to an explicit --30d (the default IS the 30-day window, not a lookalike)" \
  || bad_t "default vs --30d" "default=$DEF_WIN explicit=$THIRTY_WIN"
[[ "$DEF_WIN" != "$SEVEN_WIN" ]] \
  && ok_t "non-vacuity: the same block yields two DIFFERENT resolutions, so the parser is not inert" \
  || bad_t "inert window parser" "both resolved to $DEF_WIN"
# The catch-all, matching the badge half: past the one `case`, no span may be
# hand-spelled anywhere in the verb — the fifth sense is exactly what slipped.
SC_BODY="$(awk '/^_proof_scorecard\(\)/{f=1} f{print} f&&/^}/{exit}' src/cmd_proof.sh)"
grep -q '"$self" digest --json "--\$window"' <<<"$SC_BODY" \
  && ok_t "the scorecard's digest sub-call derives its flag from the resolved window (no literal --7d/--30d)" \
  || bad_t "scorecard digest flag not derived" "$(grep -n 'digest --json' <<<"$SC_BODY")"
if grep -nE -- '(-7 days|-30 days)' <<<"$(grep -v 'sql_window="' <<<"$SC_BODY")" >/dev/null; then
  bad_t "a hand-spelled SQL span survives outside the scorecard's window case" \
        "$(grep -nE -- '(-7 days|-30 days)' <<<"$(grep -v 'sql_window="' <<<"$SC_BODY")")"
else
  ok_t "every SQL span in the verb comes from sql_window (no hand-spelled day count elsewhere)"
fi

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
