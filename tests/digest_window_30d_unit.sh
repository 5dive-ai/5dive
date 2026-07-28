#!/usr/bin/env bash
# DIVE-1921 unit harness for the digest --30d window.
#
# TWO LAYERS, DELIBERATELY. The renderer is HANDED its window as an env var by
# this harness, so a python-only test grades a window it supplied itself and
# stays green even if `--30d` is rejected by the shell before python ever runs
# (the same vacuity DIVE-1914 shipped once and DIVE-1922 shipped twice). So the
# arg-parse `case` block is extracted from the shipped source and evaluated for
# real, and the scorecard's window mapping is evaluated the same way.
#
# What is actually asserted:
#   SHELL  - `--30d` is accepted and selects 2592000s (a deleted case arm fails)
#   LABEL  - the window label is DERIVED, not a `>=` ladder: 2592000 renders
#            "30 days", never "7 days" (the pre-fix code renders "7 days" here)
#   SUM    - a window-scoped count widens with the window
#   RATE   - a rate's DENOMINATOR widens with the window (the thin-n fix)
#   POINT  - a point reading is IDENTICAL at 7d and 30d (loop burn is all-time)
#   TREND  - priorWindowComplete is false when the store cannot cover the prior
#            window, true when it can
#   MIXED  - the scorecard's window moves as ONE unit: no hard-coded span
#            survives, and the two branches compute DIFFERENT spans
# Run: bash tests/digest_window_30d_unit.sh  (no root, no network, no live DB).
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/digest-30d.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ---------------------------------------------------------------- SHELL layer
# Evaluate the REAL arg-parse case block. This is the assertion a renderer test
# structurally cannot make: python never sees the flag, it sees the seconds.
CASE_BLOCK="$(awk '/^    case "\$1" in$/{f=1} f{print} f&&/^    esac$/{exit}' src/cmd_digest.sh)"
[[ -n "$CASE_BLOCK" ]] || { echo "FAIL - could not extract digest arg-parse case block"; exit 1; }

parse_window() {  # <flag> -> window seconds, or "REJECTED"
  local window=86400 do_send=0 as_json=0 E_USAGE=2
  fail() { echo "REJECTED"; exit 0; }
  set -- "$1"
  eval "$CASE_BLOCK"
  echo "$window"
}

W30="$(parse_window --30d)"
[[ "$W30" == "2592000" ]] \
  && ok_t "shell: --30d is ACCEPTED and selects a 30-day window (2592000s)" \
  || bad_t "--30d not wired in the arg parser" "got '$W30' (pre-fix this is REJECTED)"
[[ "$(parse_window --7d)"  == "604800" ]] && ok_t "shell: --7d still selects 7 days"   || bad_t "--7d regressed" "$(parse_window --7d)"
[[ "$(parse_window --24h)" == "86400"  ]] && ok_t "shell: --24h still selects 24h"     || bad_t "--24h regressed" "$(parse_window --24h)"
[[ "$(parse_window --90d)" == "REJECTED" ]] \
  && ok_t "shell: an unoffered window is still refused (the parser did not go permissive)" \
  || bad_t "--90d silently accepted" "$(parse_window --90d)"
grep -q -- '--7d|--30d' <<<"$(grep 'usage: 5dive digest' src/cmd_digest.sh)" \
  && ok_t "shell: --help advertises the window it now supports" \
  || bad_t "help text not updated" "$(grep 'usage: 5dive digest' src/cmd_digest.sh)"

# --------------------------------------------------------------- PYTHON layer
awk "/python3 - >.*<<'PY'/{f=1;next} f&&/^PY\$/{f=0} f" src/cmd_digest.sh > "$TMP/digest.py"
[[ -s "$TMP/digest.py" ]] || { echo "FAIL - could not extract digest python"; exit 1; }

NOW=$(date +%s)
iso() { date -u -d "@$(( NOW - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
D2=$(iso 172800)       # 2 days ago   - inside every window
D20=$(iso 1728000)     # 20 days ago  - inside 30d, OUTSIDE 7d
D50=$(iso 4320000)     # 50 days ago  - earliest row we hold

# Fixture. Two shipped tasks and two answered precedent prefills straddle the
# 7d boundary, so widening changes a SUM and a RATE's denominator. The earliest
# created_at is 50d, which covers the 7d window's predecessor (14d back) but NOT
# the 30d window's (60d back) - so the trend's completeness flag must flip.
cat > "$TMP/tasks.json" <<JSON
{"tasks":[
 {"ident":"DIVE-A","title":"recent ship","status":"done","kind":"standard","assignee":"dev",
  "done_at":"$D2","created_at":"$D50"},
 {"ident":"DIVE-B","title":"older ship","status":"done","kind":"standard","assignee":"dev",
  "done_at":"$D20","created_at":"$D50"},
 {"ident":"DIVE-C","title":"prefill kept","status":"done","kind":"standard","assignee":"dev",
  "done_at":"$D20","created_at":"$D50","precedent_ref":"7","precedent_kind":"exact",
  "need_answer":"ship it","recommend":"ship it","need_answered_at":"$D20","need_answered_by":"olivia"},
 {"ident":"DIVE-D","title":"prefill overridden","status":"done","kind":"standard","assignee":"dev",
  "done_at":"$D2","created_at":"$D50","precedent_ref":"8","precedent_kind":"exact",
  "need_answer":"hold","recommend":"ship it","need_answered_at":"$D2","need_answered_by":"olivia"}
]}
JSON
echo '{"agents":[],"tasks":[]}' > "$TMP/usage.json"
: > "$TMP/hb.txt"
echo '{"loops":[{"loop_id":"L1","topology":"relay","status":"done","tokens":1000,"ceiling":null},
                {"loop_id":"L2","topology":"relay","status":"running","tokens":500,"ceiling":null}]}' > "$TMP/loops.json"
echo '[]' > "$TMP/sup.json"

run() {  # <seconds> -> full digest JSON
  DIGEST_TASKS_F="$TMP/tasks.json" DIGEST_USAGE_F="$TMP/usage.json" \
  DIGEST_HB_F="$TMP/hb.txt" DIGEST_LOOPS_F="$TMP/loops.json" DIGEST_SUP_F="$TMP/sup.json" \
  DIGEST_OBJ_F="/dev/null" DIGEST_WINDOW="$1" DIGEST_JSON=1 python3 "$TMP/digest.py" 2>/dev/null
}
jq_() { python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }

J7="$(run 604800)"; J30="$(run 2592000)"; J24="$(run 86400)"
[[ -n "$J30" ]] || { echo "FAIL - digest python produced nothing at 2592000"; exit 1; }

# LABEL. The pre-fix ladder (`"7 days" if window >= 604800`) renders "7 days"
# here - the digest's own headline asserting a span it did not measure.
L30="$(echo "$J30" | jq_ "['window']['label']")"
[[ "$L30" == "30 days" ]] \
  && ok_t "label: a 30d window renders \"30 days\"" \
  || bad_t "30d window mislabelled" "got '$L30' (the >= ladder yields '7 days')"
[[ "$(echo "$J7"  | jq_ "['window']['label']")" == "7 days" ]] && ok_t "label: 7d still renders \"7 days\"" || bad_t "7d label regressed" "$J7"
[[ "$(echo "$J24" | jq_ "['window']['label']")" == "24h"    ]] && ok_t "label: 24h still renders \"24h\""   || bad_t "24h label regressed" "$J24"
[[ "$(echo "$J30" | jq_ "['window']['seconds']")" == "2592000" && "$(echo "$J30" | jq_ "['window']['days']")" == "30.0" ]] \
  && ok_t "label: the window is also published as machine-readable seconds/days" \
  || bad_t "window.seconds/days missing" "$(echo "$J30" | jq_ "['window']")"

# SUM. done_at is window-scoped, so the older ship appears only at 30d.
S7="$(echo "$J7" | jq_ "['zeroHuman']['shipped']")"; S30="$(echo "$J30" | jq_ "['zeroHuman']['shipped']")"
[[ "$S7" == "2" && "$S30" == "4" ]] \
  && ok_t "sum: shipped widens with the window (2 at 7d -> 4 at 30d)" \
  || bad_t "sum did not widen" "7d=$S7 30d=$S30"

# RATE. The denominator grows - this is the thin-n fix DIVE-1914 asked for.
P7="$(echo "$J7" | jq_ "['precedentPrefill']['count']")"; P30="$(echo "$J30" | jq_ "['precedentPrefill']['count']")"
R30="$(echo "$J30" | jq_ "['precedentPrefill']['acceptanceRate']")"
[[ "$P7" == "1" && "$P30" == "2" && "$R30" == "50" ]] \
  && ok_t "rate: the acceptance-rate DENOMINATOR widens (n=1 at 7d -> n=2 at 30d, 50%)" \
  || bad_t "rate denominator did not widen" "n7=$P7 n30=$P30 rate30=$R30"

# POINT. Loop burn is `usage loops --all` - every loop ever. It must NOT move
# with the window, and the payload must SAY so, or a 30d header claims it.
LT7="$(echo "$J7" | jq_ "['loops']['total']")"; LT30="$(echo "$J30" | jq_ "['loops']['total']")"
[[ "$LT7" == "1500" && "$LT30" == "1500" ]] \
  && ok_t "point: loop burn is identical at 7d and 30d (it is not a window slice)" \
  || bad_t "loop burn moved with the window" "7d=$LT7 30d=$LT30"
PIT="$(echo "$J30" | jq_ "['pointInTime']")"
_missing=""
for k in usage usageCoverage loops health inProgress blocked; do
  [[ "$PIT" == *"'$k'"* ]] || _missing="$_missing $k"
done
[[ -z "$_missing" ]] \
  && ok_t "point: pointInTime names every block the window does NOT scope" \
  || bad_t "pointInTime incomplete" "missing:$_missing"

# TREND. A prior window the store cannot cover is a partial span; the flag says
# so instead of letting the arrow read as growth.
[[ "$(echo "$J7"  | jq_ "['autonomy']['priorWindowComplete']")" == "True" ]] \
  && ok_t "trend: prior 7d window IS covered by the store (earliest row is 50d old)" \
  || bad_t "priorWindowComplete wrong at 7d" "$(echo "$J7" | jq_ "['autonomy']")"
[[ "$(echo "$J30" | jq_ "['autonomy']['priorWindowComplete']")" == "False" ]] \
  && ok_t "trend: prior 30d window is NOT covered (reaches 60d back, store starts at 50d)" \
  || bad_t "priorWindowComplete wrong at 30d" "$(echo "$J30" | jq_ "['autonomy']")"

# ------------------------------------------------- SHELL layer: the scorecard
# `proof scorecard` combines the digest sub-call, the SQL counts and the token
# read into single ratios. A span left behind at 7 days does not render as a
# wrong window - it renders as a plausible rate whose numerator and denominator
# were measured over different spans. Assert at the layer where that lives.
SCORE_FN="$(awk '/^_proof_scorecard\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' src/cmd_proof.sh)"
[[ -n "$SCORE_FN" ]] || { echo "FAIL - could not extract _proof_scorecard from src/cmd_proof.sh"; exit 1; }
HARDCODED="$(grep -c -- "-7 days" <<<"$SCORE_FN")"
[[ "$HARDCODED" == "1" ]] \
  && ok_t "scorecard: no span is hard-coded outside the single window mapping (1 occurrence = the mapping itself)" \
  || bad_t "a hard-coded span survives in the scorecard" "found $HARDCODED occurrences of '-7 days'; a leftover mixes windows inside one ratio"
grep -q 'digest --json "--\$window"' <<<"$SCORE_FN" \
  && ok_t "scorecard: the digest sub-call carries the selected window" \
  || bad_t "scorecard still pins its digest sub-call" "$(grep -o 'digest --json [^ ]*' <<<"$SCORE_FN")"
grep -q 'usage_collect "\$usage_secs"' <<<"$SCORE_FN" \
  && ok_t "scorecard: the token read carries the selected window" \
  || bad_t "scorecard still pins its token read" "$(grep -o 'usage_collect [^ ]*' <<<"$SCORE_FN")"

SC_CASE="$(awk '/^  case "\$window" in$/{f=1} f{print} f&&/^  esac$/{exit}' src/cmd_proof.sh)"
[[ -n "$SC_CASE" ]] || { echo "FAIL - could not extract the scorecard window mapping"; exit 1; }
eval_win() {  # <window> -> "<sql_window>|<usage_secs>"
  local window="$1" sql_window="" usage_secs="" E_USAGE=2
  fail() { echo "REJECTED"; exit 0; }
  eval "$SC_CASE"
  printf '%s|%s' "$sql_window" "$usage_secs"
}
V7="$(eval_win 7d)"; V30="$(eval_win 30d)"
[[ "$V7" == "-7 days|604800" ]]   && ok_t "scorecard: 7d maps to a 7-day span and a 7-day token read"   || bad_t "7d mapping" "$V7"
[[ "$V30" == "-30 days|2592000" ]] && ok_t "scorecard: 30d maps to a 30-day span and a 30-day token read" || bad_t "30d mapping" "$V30"
[[ "$V7" != "$V30" ]] \
  && ok_t "scorecard: the two windows compute DIFFERENT spans (a legal-but-INERT --30d makes them identical)" \
  || bad_t "inert --30d" "both windows produce '$V7'"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
# The house verdict idiom (digest_mttu / digest_autonomy / proof_scorecard all use
# it verbatim): the LAST executable line IS the verdict, so the script's exit
# status is this comparison. tests/meta/harness-verdict-probe.sh identifies the
# verdict variable from this line and mutates it; an explicit-exit form
# (`[[ … ]] || exit 1`) is a shape it can fail to classify, which reports
# UNPROBEABLE and fails harness-verdict-union.sh closed. Do not "simplify" this.
[[ "$FAIL" -eq 0 ]]
