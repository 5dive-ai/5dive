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
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/proof-publish.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

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
    TODAY="$today" TODAY_LABEL="Jul 11" NOW_ISO="${today}T00:00:00Z" \
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
