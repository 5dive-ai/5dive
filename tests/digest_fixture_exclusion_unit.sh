#!/usr/bin/env bash
# DIVE-3227 isolated unit harness for the digest's fixture exclusion — the
# denominator of the PUBLISHED zero-human badge (1 - asks/shipped). Drives the
# digest's embedded python directly via the DIGEST_*_F env contract (no live
# board, no root, no network) and pins four things:
#
#   1. a fixture-shaped row (title prefix from five_fixture_title_prefixes) does
#      NOT count as shipped work,
#   2. it is COUNTED and its idents reported — a silent filter on a published
#      metric is the same defect class as the inflation it removes,
#   3. the rule is PREFIX-anchored: a row whose title merely CONTAINS the words
#      still ships (DIVE-3227's own title contains them while reporting the bug),
#   4. an absent prefix list excludes NOTHING and emits an EMPTY rule — the
#      marker `proof publish` refuses on, rather than silently filtering by a
#      rule it cannot state.
#
# Run: bash tests/digest_fixture_exclusion_unit.sh   (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

command -v python3 >/dev/null 2>&1 || { echo "SKIP - python3 absent"; exit 0; }

TMP="$(mktemp -d /tmp/digest-fixture.XXXXXX)"

# Extract the embedded python block verbatim.
awk "/python3 - >.*<<'PY'/{f=1;next} f&&/^PY\$/{f=0} f" src/cmd_digest.sh > "$TMP/digest.py"
[[ -s "$TMP/digest.py" ]] || { echo "FAIL - could not extract digest python"; exit 1; }

# The prefix list comes from THE PRODUCT (src/lib/tasks_db.sh), never a copy
# here: a harness carrying its own rule grades the copy (DIVE-3175).
eval "$(awk '/^five_fixture_title_prefixes\(\) \{/,/^\}/' src/lib/tasks_db.sh)"
declare -F five_fixture_title_prefixes >/dev/null \
  || { echo "FAIL - could not extract five_fixture_title_prefixes from src/lib/tasks_db.sh"; exit 1; }
PREFIXES="$(five_fixture_title_prefixes)"
[[ -n "$PREFIXES" ]] || { echo "FAIL - the shipped prefix list is empty"; exit 1; }

iso() { date -u -d "@$(( $(date +%s) - $1 ))" +%FT%TZ; }
D1=$(iso $((1*86400)))

echo '{"agents":[],"tasks":[]}' > "$TMP/usage.json"
: > "$TMP/hb.txt"
echo '{"loops":[]}' > "$TMP/loops.json"

# 2 real ships, 2 fixture ships, 1 real ship whose title CONTAINS the fixture
# words mid-string (the anchoring control), and one human-answered gate.
cat > "$TMP/tasks.json" <<JSON
{"tasks":[
  {"ident":"R-1","title":"ship a real thing","status":"done","done_at":"$D1","assignee":"dev","kind":"task"},
  {"ident":"R-2","title":"ship another real thing","status":"done","done_at":"$D1","assignee":"dev","kind":"task"},
  {"ident":"F-1","title":"stamp arm A","status":"done","done_at":"$D1","assignee":"main","kind":"task"},
  {"ident":"F-2","title":"  Stamp Arm B  ","status":"done","done_at":"$D1","assignee":"main","kind":"task"},
  {"ident":"R-3","title":"the badge counts stamp arm % rows as shipped work","status":"done","done_at":"$D1","assignee":"ops","kind":"task"},
  {"ident":"G-1","title":"a real gate","status":"done","done_at":"$D1","need_type":"decision","need_answered_by":"human:lodar","need_answered_at":"$D1","need_asked_at":"$D1","need_answer":"go","assignee":"main","kind":"task"}
]}
JSON

run_digest() {  # $1 = DIGEST_JSON (1|0); prefixes from env FIXPFX (default: shipped list)
  DIGEST_TASKS_F="$TMP/tasks.json" DIGEST_USAGE_F="$TMP/usage.json" \
  DIGEST_HB_F="$TMP/hb.txt" DIGEST_LOOPS_F="$TMP/loops.json" \
  DIGEST_FIXTURE_PREFIXES="${FIXPFX-$PREFIXES}" \
  DIGEST_WINDOW=604800 DIGEST_JSON="$1" python3 "$TMP/digest.py" 2>/dev/null
}
jp() { python3 -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

J="$(run_digest 1)"
[[ -n "$J" ]] || { echo "FAIL - digest produced no JSON"; exit 1; }

got_ship="$(jp "['zeroHuman']['shipped']" <<<"$J")"
got_fx="$(jp "['zeroHuman']['fixturesExcluded']['shipped']" <<<"$J")"
got_ids="$(jp "['zeroHuman']['fixturesExcluded']['idents']" <<<"$J")"
got_rule="$(jp "['zeroHuman']['fixturesExcluded']['rule']" <<<"$J")"

# 4 shipped: R-1, R-2, R-3 (contains, not prefix) and G-1 (a gated ship).
[[ "$got_ship" == "4" ]] \
  && ok_t "fixture-shaped rows do not count as shipped (4 of 6)" \
  || bad_t "shipped" "got $got_ship — $J"
[[ "$got_fx" == "2" ]] && ok_t "the excluded count is reported (2)" || bad_t "fixturesExcluded.shipped" "got $got_fx"
[[ "$got_ids" == *"F-1"* && "$got_ids" == *"F-2"* && "$got_ids" != *"R-3"* ]] \
  && ok_t "the excluded IDENTS are named, and the contains-only row is not among them" \
  || bad_t "fixturesExcluded.idents" "got $got_ids"
[[ -n "$got_rule" ]] && ok_t "the rule travels with the numbers" || bad_t "fixturesExcluded.rule empty"
# The anchoring control, stated as its own arm: R-3 must be IN the done list.
done_ids="$(python3 -c "import sys,json; print([t['ident'] for t in json.load(sys.stdin)['done']])" <<<"$J")"
[[ "$done_ids" == *"R-3"* ]] \
  && ok_t "prefix-anchored: a title that CONTAINS the words still ships (R-3)" \
  || bad_t "anchoring" "$done_ids"

# Text mode prints the filter where the number is rendered.
T="$(run_digest 0)"
grep -q "excluded 2 fixture-shaped row" <<<"$T" \
  && ok_t "the text digest prints the excluded count beside the KPI" \
  || bad_t "text exclusion line" "$T"
grep -q "F-1" <<<"$T" && ok_t "the text digest names the excluded rows" || bad_t "text idents" "$T"

# Absent prefix list: nothing excluded AND an empty rule (the publisher's marker).
J0="$(FIXPFX= run_digest 1)"
[[ "$(jp "['zeroHuman']['shipped']" <<<"$J0")" == "6" ]] \
  && ok_t "no prefix list => nothing excluded (6, fail-open on the COUNT)" \
  || bad_t "unwired shipped" "$(jp "['zeroHuman']['shipped']" <<<"$J0")"
[[ -z "$(jp "['zeroHuman']['fixturesExcluded']['rule']" <<<"$J0")" ]] \
  && ok_t "no prefix list => EMPTY rule, which is what proof publish refuses on" \
  || bad_t "unwired rule must be empty" "$J0"

# The prior-window baseline nets fixtures out too (else the filter reads as a trend).
[[ "$(jp "['autonomy']['shipped']" <<<"$J")" == "4" ]] \
  && ok_t "the autonomy rollup uses the netted ship count" \
  || bad_t "autonomy.shipped" "$(jp "['autonomy']['shipped']" <<<"$J")"

echo
echo "digest_fixture_exclusion_unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
