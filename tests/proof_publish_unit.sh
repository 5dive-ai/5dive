#!/usr/bin/env bash
# OSS-17 isolated unit harness for the `proof publish` payload builder. Extracts
# the embedded python block from src/cmd_proof.sh (the honesty-critical core that
# turns digest JSON into badge.json/zero-human.json/history.jsonl) and drives it
# with fixture digest output — no git, no network, no live digest. Asserts:
#   - the three files are built VERBATIM from the digest numbers (no edit path),
#   - a same-day re-run is a no-op (exit 3, files unchanged),
#   - "ask" vs "asks" pluralization,
#   - cumulative totals sum the non-overlapping 24h datapoints across days.
# Run: bash tests/proof_publish_unit.sh   (no root, no network).
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

TMP="$(mktemp -d /tmp/proof-publish.XXXXXX)"

# Extract the embedded python builder (between the PROOFPY heredoc markers).
awk "/python3 <<'PROOFPY'/{f=1;next} f&&/^PROOFPY\$/{f=0} f" src/cmd_proof.sh > "$TMP/proof.py"
[[ -s "$TMP/proof.py" ]] || { echo "FAIL - could not extract proof python"; exit 1; }

# run_build <workdir> <day_shipped> <day_asks> <week_shipped> <week_asks> [today]
# Runs the builder inside <workdir> (cwd == status-branch checkout). Echoes the
# builder's stdout; returns its exit code.
run_build() {
  local wd="$1" ds="$2" da="$3" ws="$4" wa="$5" today="${6:-2026-07-11}"
  ( cd "$wd" && \
    DAY_JSON="{\"zeroHuman\":{\"shipped\":$ds,\"humanTouches\":$da}}" \
    WEEK_JSON="{\"zeroHuman\":{\"shipped\":$ws,\"humanTouches\":$wa}}" \
    TODAY="$today" NOW_ISO="${today}T00:00:00Z" \
    CLI_VERSION="0.8.8" METHODOLOGY_URL="https://example.test/zero-human.md" \
    python3 "$TMP/proof.py" )
}

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
jget() { python3 -c "import sys,json; d=json.load(open(sys.argv[1])); print(d$2)" "$1" 2>/dev/null; }

# --- Case 1: fresh publish (no history.jsonl) --------------------------------
# DIVE-1552: week is derived from the daily history datapoints, not WEEK_JSON.
# Fresh history => the only day is today (5 shipped, 1 ask) => week 5/1 =>
# 1 - 1/5 = 80.0% -> "80%". The WEEK_JSON 27/2 is deliberately ignored.
W1="$TMP/w1"; mkdir -p "$W1"
OUT1="$(run_build "$W1" 5 1 27 2)"; RC1=$?
[[ $RC1 -eq 0 ]] && ok_t "fresh publish exits 0" || bad_t "fresh exit" "rc=$RC1"
[[ -f "$W1/badge.json" && -f "$W1/zero-human.json" && -f "$W1/history.jsonl" && -f "$W1/README.md" ]] \
  && ok_t "all four files written" || bad_t "files written"
[[ "$(jget "$W1/badge.json" "['message']")" == "80%" ]] \
  && ok_t "badge message = self-shipped pct from the last-7 daily datapoints" || bad_t "badge message" "$(cat "$W1/badge.json")"
[[ "$(jget "$W1/badge.json" "['schemaVersion']")" == "1" && "$(jget "$W1/badge.json" "['label']")" == "zero-human" ]] \
  && ok_t "badge is a valid shields endpoint schema" || bad_t "badge schema"

# DIVE-1924: the badge message is the NUMBER ONLY — lodar's call, the date is
# visual noise on the one asset whose value is being instantly readable. This
# pins that: anything appended here (a date, an "updated", a separator) fails.
# The freshness guarantee it replaces lives in .github/workflows/badge-staleness.yml,
# an INDEPENDENT hourly watcher, because a dead publisher cannot mark itself dead.
BADGE_MSG="$(jget "$W1/badge.json" "['message']")"          # 80%
[[ "$BADGE_MSG" == "80%" ]] \
  && ok_t "badge message is the number alone, nothing appended" \
  || bad_t "badge message minimal" "expected '80%', got '$BADGE_MSG'"

# The agreement property from DIVE-1908 SURVIVES — it just moved to the fields
# that still carry a date. One clock read feeds both (cmd_proof.sh), so
# zero-human.json's `date` must be the day part of its own generatedAtUtc,
# byte-identical, no parsing. This is what stops the watcher above from reading
# one field while the artifact describes another day; deleting the badge's date
# must not silently delete the property that made the dates trustworthy.
DP_DATE="$(jget "$W1/zero-human.json" "['date']")"          # 2026-07-11
DP_STAMP="$(jget "$W1/zero-human.json" "['generatedAtUtc']")"
[[ -n "$DP_DATE" && "${DP_STAMP%%T*}" == "$DP_DATE" ]] \
  && ok_t "zero-human.json date IS the day of its own generatedAtUtc (string ==, one clock read)" \
  || bad_t "datapoint date == generatedAtUtc day" "date='$DP_DATE' stamp='$DP_STAMP'"
# ...and the stamp must really have had a time part, so the check above cannot
# pass vacuously if the T separator ever disappears.
[[ "${DP_STAMP%%T*}" != "$DP_STAMP" ]] \
  && ok_t "generatedAtUtc is a full timestamp, not a bare day" \
  || bad_t "generatedAtUtc shape" "no 'T' separator in '$DP_STAMP'"
[[ "$(jget "$W1/zero-human.json" "['week']['shipped']")" == "5" \
   && "$(jget "$W1/zero-human.json" "['week']['humanAsks']")" == "1" \
   && "$(jget "$W1/zero-human.json" "['day']['shipped']")" == "5" \
   && "$(jget "$W1/zero-human.json" "['day']['humanAsks']")" == "1" ]] \
  && ok_t "day = digest verbatim; week = last-7 daily sum (here just today)" \
  || bad_t "datapoint numbers" "$(cat "$W1/zero-human.json")"
[[ "$(jget "$W1/zero-human.json" "['cumulative']['daysPublished']")" == "1" \
   && "$(jget "$W1/zero-human.json" "['cumulative']['shipped']")" == "5" \
   && "$(jget "$W1/zero-human.json" "['cumulative']['humanAsks']")" == "1" ]] \
  && ok_t "cumulative = the single day datapoint" || bad_t "cumulative day1"
[[ "$(wc -l < "$W1/history.jsonl")" == "1" ]] && ok_t "history has one appended row" || bad_t "history rows"
echo "$OUT1" | grep -q "2026-07-11 (7d: 5 shipped, 1 ask)" && ok_t "summary line printed" || bad_t "summary" "$OUT1"

# --- Case 2: same-day re-run is an idempotent no-op (exit 3) ------------------
HIST_BEFORE="$(cat "$W1/history.jsonl")"
OUT2="$(run_build "$W1" 9 9 99 9 2026-07-11)"; RC2=$?
[[ $RC2 -eq 3 ]] && ok_t "same-day re-run exits 3 (already published)" || bad_t "rerun exit" "rc=$RC2"
[[ "$(cat "$W1/history.jsonl")" == "$HIST_BEFORE" ]] && ok_t "re-run left history.jsonl unchanged" || bad_t "history mutated on rerun"

# --- Case 3a: perfect week drops the trailing .0 (100%, not 100.0%) ----------
W3="$TMP/w3"; mkdir -p "$W3"
run_build "$W3" 4 0 10 0 >/dev/null
[[ "$(jget "$W3/badge.json" "['message']")" == "100%" ]] \
  && ok_t "zero asks -> 100% with trailing .0 dropped" || bad_t "100pct" "$(cat "$W3/badge.json")"

# --- Case 3b: a week with zero ships has no ratio -> raw-count fallback -------
W3b="$TMP/w3b"; mkdir -p "$W3b"
run_build "$W3b" 0 1 0 1 >/dev/null
[[ "$(jget "$W3b/badge.json" "['message']")" == "0 shipped, 1 ask" ]] \
  && ok_t "zero shipped -> raw-count fallback, singular 'ask'" || bad_t "zero-ship fallback" "$(cat "$W3b/badge.json")"

# --- Case 4: cumulative sums the non-overlapping 24h datapoints across days ---
W4="$TMP/w4"; mkdir -p "$W4"
# Seed a prior day's row (shipped 4, asks 1 on 2026-07-10).
printf '%s\n' '{"cliVersion":"0.8.8","date":"2026-07-10","day":{"humanAsks":1,"shipped":4},"week":{"humanAsks":1,"shipped":20}}' > "$W4/history.jsonl"
run_build "$W4" 5 1 27 2 2026-07-11 >/dev/null
[[ "$(jget "$W4/zero-human.json" "['cumulative']['daysPublished']")" == "2" \
   && "$(jget "$W4/zero-human.json" "['cumulative']['shipped']")" == "9" \
   && "$(jget "$W4/zero-human.json" "['cumulative']['humanAsks']")" == "2" \
   && "$(jget "$W4/zero-human.json" "['cumulative']['since']")" == "2026-07-10" ]] \
  && ok_t "cumulative sums day datapoints (4+5=9 shipped, 1+1=2 asks, since first)" \
  || bad_t "cumulative multiday" "$(cat "$W4/zero-human.json")"
[[ "$(wc -l < "$W4/history.jsonl")" == "2" ]] && ok_t "history appended (2 rows)" || bad_t "history append"

# --- Case 5 (DIVE-1552): week = sum of the LAST 7 daily datapoints, NOT the --
# live-board WEEK_JSON. Proves the rolling window survives a board wipe: even
# when WEEK_JSON under-reports (3/0, as it did after the 2026-07-19 wipe), the
# badge counts the real 7-day total from the append-only daily history, and the
# 8th-oldest day correctly drops out of the window.
W5="$TMP/w5"; mkdir -p "$W5"
: > "$W5/history.jsonl"
for i in 1 2 3 4 5 6 7; do
  printf '{"cliVersion":"0.8.8","date":"2026-07-%02d","day":{"humanAsks":1,"shipped":10},"week":{"humanAsks":0,"shipped":0}}\n' "$((3+i))" >> "$W5/history.jsonl"
done
run_build "$W5" 12 2 3 0 2026-07-11 >/dev/null
# hist after append = Jul04..Jul11 (8 rows); last-7 = Jul05..Jul11 =
# 6*10/1 + 12/2 = 72 shipped / 8 asks. Jul04 drops out; WEEK_JSON 3/0 ignored.
[[ "$(jget "$W5/zero-human.json" "['week']['shipped']")" == "72" \
   && "$(jget "$W5/zero-human.json" "['week']['humanAsks']")" == "8" ]] \
  && ok_t "DIVE-1552: week sums the last 7 daily datapoints, ignores a wiped WEEK_JSON" \
  || bad_t "rolling-7 week" "$(cat "$W5/zero-human.json")"

# --- Case 6 (DIVE-1864): digest passed via *_FILE handles a >128KB blob -------
# A single env var over MAX_ARG_STRLEN (32 pages = 131072B) makes the python
# exec die with E2BIG ("Argument list too long"). The real _proof_build routes
# the digest JSON through DAY_JSON_FILE/WEEK_JSON_FILE so an arbitrarily large
# blob still builds. Drive the builder directly via the file pointers with a
# ~200KB day blob (would E2BIG as an env string) and assert it builds verbatim.
W6="$TMP/w6"; mkdir -p "$W6"
PAD="$(head -c 200000 /dev/zero | tr '\0' 'x')"           # 200000 chars > 128KB
printf '{"_pad":"%s","zeroHuman":{"shipped":6,"humanTouches":0}}' "$PAD" > "$TMP/day6.json"
printf '{"zeroHuman":{"shipped":6,"humanTouches":0}}' > "$TMP/week6.json"
[[ "$(wc -c < "$TMP/day6.json")" -gt 131072 ]] && ok_t "day6 blob exceeds MAX_ARG_STRLEN (would E2BIG via env)" || bad_t "day6 blob size"
OUT6="$( cd "$W6" && \
  DAY_JSON_FILE="$TMP/day6.json" WEEK_JSON_FILE="$TMP/week6.json" \
  TODAY="2026-07-12" NOW_ISO="2026-07-12T00:00:00Z" \
  CLI_VERSION="0.8.8" METHODOLOGY_URL="https://example.test/zero-human.md" \
  python3 "$TMP/proof.py" )"; RC6=$?
[[ $RC6 -eq 0 ]] && ok_t "DIVE-1864: >128KB digest via *_FILE builds (no E2BIG)" || bad_t "big-file build" "rc=$RC6"
[[ "$(jget "$W6/badge.json" "['message']")" == "100%" ]] \
  && ok_t "big-file badge computes verbatim (6 shipped / 0 asks -> 100%)" || bad_t "big-file badge" "$(cat "$W6/badge.json" 2>/dev/null)"

# --- Case 7 (DIVE-2654, spec: DIVE-2652): corroborators ship inside
# zero-human.json, carrying their own scope; the badge MESSAGE stays untouched.
# Numbers pinned to the exact fixture named in DIVE-2652's SHIP SHAPE:
# 124/192 graded (59.1% coverage of 325 shipped), 3 iteration-NULL graded rows
# (<=1.6pp upward bias); 126 policy-blocked, 13 of 26 sites fired in 7d, 16 of
# 26 lifetime, ledger opened 2026-07-25 12:04.
W7="$TMP/w7"; mkdir -p "$W7"
OUT7="$( cd "$W7" && \
  DAY_JSON='{"zeroHuman":{"shipped":5,"humanTouches":1}}' \
  WEEK_JSON='{"zeroHuman":{"shipped":27,"humanTouches":2}}' \
  TODAY="2026-08-03" NOW_ISO="2026-08-03T21:00:00Z" \
  CLI_VERSION="0.18.0" METHODOLOGY_URL="https://example.test/zero-human.md" \
  CORR_ROWS="325|192|124|3" \
  CORR_REFUSALS="126" CORR_FIRED_WINDOW="13" CORR_FIRED_LIFETIME="16" CORR_SITES="26" \
  CORR_LEDGER_SINCE="2026-07-25 12:04:00" \
  python3 "$TMP/proof.py" )"; RC7=$?
[[ $RC7 -eq 0 ]] && ok_t "corroborator fixture builds" || bad_t "corroborator build" "rc=$RC7"
[[ "$(jget "$W7/zero-human.json" "['corroborators']['verifierFirstPassRate']['value']")" == "64.6%" ]] \
  && ok_t "LEAD: verifier first-pass rate = 124/192 = 64.6%" || bad_t "first-pass value" "$(cat "$W7/zero-human.json")"
[[ "$(jget "$W7/zero-human.json" "['corroborators']['verifierFirstPassRate']['coveragePct']")" == "59.1" ]] \
  && ok_t "LEAD carries its own coverage: 192 of 325 shipped = 59.1%" || bad_t "coveragePct"
[[ "$(jget "$W7/zero-human.json" "['corroborators']['verifierFirstPassRate']['shippedStandardTasks']")" == "325" ]] \
  && ok_t "LEAD names its denominator shippedStandardTasks (NOT the bare key 'shipped', DIVE-2654 review)" || bad_t "shippedStandardTasks key"
[[ "$(jget "$W7/zero-human.json" "['corroborators']['verifierFirstPassRate']['basis']")" == *"week.shipped"* \
   && "$(jget "$W7/zero-human.json" "['corroborators']['verifierFirstPassRate']['basis']")" == *"DIVE-1552"* ]] \
  && ok_t "LEAD discloses it is a DIFFERENT instrument from week.shipped (frozen sum, DIVE-1552)" || bad_t "basis disclosure" "$(jget "$W7/zero-human.json" "['corroborators']['verifierFirstPassRate']['basis']")"
[[ "$(jget "$W7/zero-human.json" "['corroborators']['verifierFirstPassRate']['iterationNullBiasPctPtsMax']")" == "1.6" ]] \
  && ok_t "LEAD discloses the iteration-NULL upward bias (3/192 <= 1.6pp)" || bad_t "iterationNullBiasPctPtsMax"
[[ "$(jget "$W7/zero-human.json" "['corroborators']['policyBlockedAttempts']['value']")" == "126" ]] \
  && ok_t "SECOND: policy-blocked attempts = 126" || bad_t "policy-blocked value"
[[ "$(jget "$W7/zero-human.json" "['corroborators']['policyBlockedAttempts']['firedSites']")" == "13" \
   && "$(jget "$W7/zero-human.json" "['corroborators']['policyBlockedAttempts']['instrumentedSites']")" == "26" \
   && "$(jget "$W7/zero-human.json" "['corroborators']['policyBlockedAttempts']['firedSitesLifetime']")" == "16" ]] \
  && ok_t "SECOND carries fired-vs-instrumented site split (13/26 window, 16/26 lifetime)" || bad_t "site split"
[[ "$(jget "$W7/zero-human.json" "['corroborators']['policyBlockedAttempts']['ledgerAgeDays']")" != "" \
   && "$(jget "$W7/zero-human.json" "['corroborators']['policyBlockedAttempts']['ledgerAgeDays']")" != "None" ]] \
  && ok_t "SECOND carries the ledger's own age" || bad_t "ledgerAgeDays missing"
BADGE7_MSG="$(jget "$W7/badge.json" "['message']")"
[[ "$BADGE7_MSG" == "80%" ]] \
  && ok_t "DIVE-1924 preserved: badge message is unaffected by corroborators shipping" \
  || bad_t "badge untouched" "expected '80%', got '$BADGE7_MSG'"
[[ "$(python3 -c "import json; print(sorted(json.load(open('$W7/badge.json')).keys()))")" == "['color', 'label', 'message', 'schemaVersion']" ]] \
  && ok_t "badge.json schema unchanged (still exactly schemaVersion/label/message/color)" || bad_t "badge schema shape"

# --- Case 8 (DIVE-2654): honesty invariant carries over — no source means an
# explicit no-data marker, never a bare 0/0%, same rule `proof scorecard` uses.
W8="$TMP/w8"; mkdir -p "$W8"
( cd "$W8" && \
  DAY_JSON='{"zeroHuman":{"shipped":5,"humanTouches":1}}' \
  WEEK_JSON='{"zeroHuman":{"shipped":27,"humanTouches":2}}' \
  TODAY="2026-08-03" NOW_ISO="2026-08-03T21:00:00Z" \
  CLI_VERSION="0.18.0" METHODOLOGY_URL="https://example.test/zero-human.md" \
  python3 "$TMP/proof.py" ) >/dev/null
[[ "$(jget "$W8/zero-human.json" "['corroborators']['verifierFirstPassRate']['value']")" == "None" \
   && "$(jget "$W8/zero-human.json" "['corroborators']['verifierFirstPassRate']['nodata']")" != "" ]] \
  && ok_t "no CORR_ROWS -> verifier first-pass degrades to NO DATA with a reason, not 0%" \
  || bad_t "first-pass no-data" "$(cat "$W8/zero-human.json")"
[[ "$(jget "$W8/zero-human.json" "['corroborators']['policyBlockedAttempts']['value']")" == "None" \
   && "$(jget "$W8/zero-human.json" "['corroborators']['policyBlockedAttempts']['nodata']")" != "" ]] \
  && ok_t "no CORR_REFUSALS/CORR_SITES -> policy-blocked degrades to NO DATA with a reason, never 0" \
  || bad_t "policy-blocked no-data" "$(cat "$W8/zero-human.json")"

# --- Case 9 (DIVE-2654 review, main2): a fixture that CANNOT agree for the
# wrong reason. Case 7 seeded no prior history, so week.shipped (frozen sum)
# and shippedStandardTasks (live SQL) both landed on whatever the single fresh
# day supplied and collapsed to the SAME value — a fixture in that shape is
# structurally incapable of telling the two instruments apart
# (community/wiki/an-empty-fixture-makes-a-frozen-sum-impersonate-a-live-count.md).
# Seed >=7 prior daily datapoints so the frozen week.shipped sum is a real,
# different number from the live shippedStandardTasks the corroborator reports,
# and assert they stay visibly distinguishable in the same emitted file.
W9="$TMP/w9"; mkdir -p "$W9"
: > "$W9/history.jsonl"
for i in 1 2 3 4 5 6 7; do
  printf '{"cliVersion":"0.18.0","date":"2026-07-%02d","day":{"humanAsks":1,"shipped":10},"week":{"humanAsks":0,"shipped":0}}\n' "$((3+i))" >> "$W9/history.jsonl"
done
( cd "$W9" && \
  DAY_JSON='{"zeroHuman":{"shipped":12,"humanTouches":2}}' \
  WEEK_JSON='{"zeroHuman":{"shipped":3,"humanTouches":0}}' \
  TODAY="2026-07-11" NOW_ISO="2026-07-11T00:00:00Z" \
  CLI_VERSION="0.18.0" METHODOLOGY_URL="https://example.test/zero-human.md" \
  CORR_ROWS="325|192|124|3" \
  CORR_REFUSALS="126" CORR_FIRED_WINDOW="13" CORR_FIRED_LIFETIME="16" CORR_SITES="26" \
  CORR_LEDGER_SINCE="2026-07-25 12:04:00" \
  python3 "$TMP/proof.py" ) >/dev/null
W9_WEEK="$(jget "$W9/zero-human.json" "['week']['shipped']")"                                          # frozen: 6*10+12=72
W9_CORR="$(jget "$W9/zero-human.json" "['corroborators']['verifierFirstPassRate']['shippedStandardTasks']")"  # live fixture: 325
[[ -n "$W9_WEEK" && -n "$W9_CORR" && "$W9_WEEK" != "$W9_CORR" ]] \
  && ok_t "DIVE-2654 point 4: populated history makes frozen week.shipped ($W9_WEEK) and live shippedStandardTasks ($W9_CORR) DISAGREE, proving the fixture can detect the two instruments" \
  || bad_t "frozen vs live no longer distinguishable" "week.shipped=$W9_WEEK shippedStandardTasks=$W9_CORR"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
