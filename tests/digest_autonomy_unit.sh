#!/usr/bin/env bash
# OSS-14 isolated unit harness for the digest autonomy rollup. Extracts the
# digest's embedded python and feeds it fixture task data via the DIGEST_*_F
# env contract (no shell-out, no live DB), then asserts the deterministic
# autonomy block: shipped/asked in the current window, the prior-window trend
# baseline, uptime (days since last human-blocking stall), and currentlyBlocked.
# Run: bash tests/digest_autonomy_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/digest-autonomy.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Extract the embedded python block (between the heredoc markers) verbatim.
awk "/python3 - >.*<<'PY'/{f=1;next} f&&/^PY\$/{f=0} f" src/cmd_digest.sh > "$TMP/digest.py"
[[ -s "$TMP/digest.py" ]] || { echo "FAIL - could not extract digest python"; exit 1; }

# now-relative ISO timestamps so the windows are stable regardless of run time.
iso() { date -u -d "@$(( $(date +%s) - $1 ))" +%FT%TZ; }
D1=$(iso $((1*86400)));  D2=$(iso $((2*86400)));  D3=$(iso $((3*86400)))
D9=$(iso $((9*86400))); D20=$(iso $((20*86400)))

# empty aux fixtures (python defaults handle these)
echo '{"agents":[],"tasks":[]}' > "$TMP/usage.json"
: > "$TMP/hb.txt"
echo '{"loops":[]}' > "$TMP/loops.json"

# Fixture: 3 shipped + 2 human-answered gates in the current 7d window;
# 2 shipped + 1 human gate in the PRIOR week; last gate filed 3d ago; no open gate.
cat > "$TMP/tasks.json" <<JSON
{"tasks":[
  {"ident":"T-1","title":"cur ship a","status":"done","done_at":"$D1","assignee":"dev","kind":"task"},
  {"ident":"T-2","title":"cur ship b","status":"done","done_at":"$D1","assignee":"dev","kind":"task"},
  {"ident":"T-3","title":"cur ship c","status":"done","done_at":"$D2","assignee":"olivia","kind":"task"},
  {"ident":"G-1","title":"cur gate a","status":"done","need_type":"decision","need_answered_by":"human:lodar","need_answered_at":"$D2","need_asked_at":"$D3","need_answer":"go","assignee":"main","kind":"task"},
  {"ident":"G-2","title":"cur gate b","status":"done","need_type":"approval","need_answered_by":"human:lodar","need_answered_at":"$D2","need_asked_at":"$D3","need_answer":"ok","assignee":"main","kind":"task"},
  {"ident":"P-1","title":"prior ship a","status":"done","done_at":"$D9","assignee":"dev","kind":"task"},
  {"ident":"P-2","title":"prior ship b","status":"done","done_at":"$D9","assignee":"dev","kind":"task"},
  {"ident":"PG-1","title":"prior gate","status":"done","need_type":"decision","need_answered_by":"human:lodar","need_answered_at":"$D9","need_asked_at":"$D9","need_answer":"go","assignee":"main","kind":"task"},
  {"ident":"OLD","title":"old base","status":"done","done_at":"$D20","assignee":"dev","kind":"task"}
]}
JSON

run_autonomy() {
  DIGEST_TASKS_F="$TMP/tasks.json" DIGEST_USAGE_F="$TMP/usage.json" \
  DIGEST_HB_F="$TMP/hb.txt" DIGEST_LOOPS_F="$TMP/loops.json" \
  DIGEST_WINDOW=604800 DIGEST_JSON=1 python3 "$TMP/digest.py" 2>/dev/null \
    | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['autonomy']))"
}

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
jf() { python3 -c "import sys,json; print(json.load(sys.stdin)['$1'])"; }

A=$(run_autonomy)
[[ -n "$A" ]] || { echo "FAIL - autonomy block missing from JSON"; exit 1; }
echo "$A" | grep -q . && :

[[ "$(echo "$A" | jf shipped)"      == "3" ]] && ok_t "shipped = 3 (current window)"          || bad_t "shipped"      "$A"
[[ "$(echo "$A" | jf asked)"        == "2" ]] && ok_t "asked = 2 (human touches in window)"    || bad_t "asked"        "$A"
[[ "$(echo "$A" | jf priorShipped)" == "2" ]] && ok_t "priorShipped = 2 (trend baseline)"      || bad_t "priorShipped" "$A"
[[ "$(echo "$A" | jf priorAsked)"   == "1" ]] && ok_t "priorAsked = 1 (trend baseline)"        || bad_t "priorAsked"   "$A"
[[ "$(echo "$A" | jf uptimeDays)"   == "3" ]] && ok_t "uptimeDays = 3 (days since last gate filed)" || bad_t "uptimeDays" "$A"
[[ "$(echo "$A" | jf currentlyBlocked)" == "False" ]] && ok_t "currentlyBlocked = false (no open gate)" || bad_t "currentlyBlocked" "$A"

# Second case: add an OPEN blocking gate -> currentlyBlocked true, uptime 0.
python3 - "$TMP/tasks.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["tasks"].append({"ident":"OPEN","title":"open gate","status":"blocked",
                   "need_type":"decision","need_asked_at":"1970-01-02T00:00:00Z",
                   "assignee":"main","kind":"task"})
json.dump(d, open(p,"w"))
PY
B=$(run_autonomy)
[[ "$(echo "$B" | jf currentlyBlocked)" == "True" ]] && ok_t "open gate -> currentlyBlocked = true"  || bad_t "blocked flag" "$B"
[[ "$(echo "$B" | jf uptimeDays)"       == "0"    ]] && ok_t "open gate -> uptimeDays = 0"            || bad_t "blocked uptime" "$B"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
