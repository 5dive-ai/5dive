#!/usr/bin/env bash
# DIVE-973 isolated unit harness for the digest MTTU (mean-time-to-unstick)
# block. Extracts the digest's embedded python and feeds it a supervisor_events
# transition fixture via the DIGEST_SUP_F env contract (no shell-out, no live
# DB), then asserts the deterministic stuck block: MTTU over the window, episode
# count, still-stuck count, and the per-cause breakdown. Pairs a transition INTO
# classification='stuck' with the next transition OUT of it; an episode counts
# only when its recovery lands inside the window.
# Run: bash tests/digest_mttu_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/digest-mttu.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

awk "/python3 - >.*<<'PY'/{f=1;next} f&&/^PY\$/{f=0} f" src/cmd_digest.sh > "$TMP/digest.py"
[[ -s "$TMP/digest.py" ]] || { echo "FAIL - could not extract digest python"; exit 1; }

NOW=$(date +%s)
ago() { echo $(( NOW - $1 )); }

# empty aux fixtures (python defaults handle these)
echo '{"tasks":[]}'            > "$TMP/tasks.json"
echo '{"agents":[],"tasks":[]}'> "$TMP/usage.json"
: > "$TMP/hb.txt"
echo '{"loops":[]}'            > "$TMP/loops.json"

# supervisor_events transition fixture (ts = epoch seconds, as dbfmt emits):
#  dev:      stuck at -2h30m -> healthy at -2h        => 30m unstick, recovered IN 24h window
#  research: loop-stuck at -5h -> healthy at -4h      => 60m unstick, cause=loop-stuck, IN window
#  olivia:   stuck at -40h -> healthy at -39h         => recovered OUTSIDE 24h window (ignored)
#  theo:     stuck at -1h, no recovery row            => STILL STUCK (open, not in mean)
cat > "$TMP/sup.json" <<JSON
[
  {"agent":"dev","ts":$(ago 9000),"classification":"stuck","prev_classification":"healthy","cause":"no-progress"},
  {"agent":"dev","ts":$(ago 7200),"classification":"healthy","prev_classification":"stuck","cause":null},
  {"agent":"research","ts":$(ago 18000),"classification":"stuck","prev_classification":"healthy","cause":"loop-stuck"},
  {"agent":"research","ts":$(ago 14400),"classification":"healthy","prev_classification":"stuck","cause":null},
  {"agent":"olivia","ts":$(ago 144000),"classification":"stuck","prev_classification":"healthy","cause":"service-dead"},
  {"agent":"olivia","ts":$(ago 140400),"classification":"healthy","prev_classification":"stuck","cause":null},
  {"agent":"theo","ts":$(ago 3600),"classification":"stuck","prev_classification":"healthy","cause":"tmux-dead"}
]
JSON

run() {
  DIGEST_TASKS_F="$TMP/tasks.json" DIGEST_USAGE_F="$TMP/usage.json" \
  DIGEST_HB_F="$TMP/hb.txt" DIGEST_LOOPS_F="$TMP/loops.json" DIGEST_SUP_F="$TMP/sup.json" \
  DIGEST_WINDOW="${1:-86400}" DIGEST_JSON=1 python3 "$TMP/digest.py" 2>/dev/null \
    | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['stuck']))"
}

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
jf() { python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)"; }

# --- 24h window: dev(30m) + research(60m) recovered in-window; olivia excluded; theo open ---
S=$(run 86400)
[[ -n "$S" ]] || { echo "FAIL - stuck block missing from JSON"; exit 1; }
[[ "$(echo "$S" | jf "['episodes']")"  == "2"    ]] && ok_t "episodes = 2 (recovered in 24h window)"        || bad_t "episodes" "$S"
[[ "$(echo "$S" | jf "['mttuSec']")"   == "2700" ]] && ok_t "mttuSec = 2700 (mean of 30m + 60m)"            || bad_t "mttuSec" "$S"
[[ "$(echo "$S" | jf "['openStuck']")" == "1"    ]] && ok_t "openStuck = 1 (theo still stuck, no recovery)" || bad_t "openStuck" "$S"
[[ "$(echo "$S" | jf "['byCause']['loop-stuck']['mttuSec']")" == "3600" ]] && ok_t "byCause loop-stuck = 3600 (research 60m)" || bad_t "byCause loop-stuck" "$S"
[[ "$(echo "$S" | jf "['byCause']['no-progress']['mttuSec']")" == "1800" ]] && ok_t "byCause no-progress = 1800 (dev 30m)"   || bad_t "byCause no-progress" "$S"

# --- 7d window: olivia's episode now recovers in-window too -> 3 episodes ---
S7=$(run 604800)
[[ "$(echo "$S7" | jf "['episodes']")"  == "3" ]] && ok_t "7d window -> episodes = 3 (olivia now in window)" || bad_t "7d episodes" "$S7"
[[ "$(echo "$S7" | jf "['openStuck']")" == "1" ]] && ok_t "7d window -> openStuck still 1"                    || bad_t "7d openStuck" "$S7"

# --- empty trail -> null MTTU, zero episodes ---
echo '[]' > "$TMP/sup.json"
SE=$(run 86400)
[[ "$(echo "$SE" | jf "['mttuSec']")"  == "None" ]] && ok_t "empty trail -> mttuSec null" || bad_t "empty mttuSec" "$SE"
[[ "$(echo "$SE" | jf "['episodes']")" == "0"    ]] && ok_t "empty trail -> episodes 0"   || bad_t "empty episodes" "$SE"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
