#!/usr/bin/env bash
# DIVE-6713: `account usage` had no current number for an account with no busy
# seat (konst and mp read `- (remembered)`, 2026-10-22). The heartbeat now polls
# every Claude account (account_poll_one) and the reading competes on age in
# account_usage_rows. Arms:
#   1  an account with NO bound seat gets a live `poll` reading, written where
#      `account usage` reads. NEGATIVE CONTROL: POLL_MUTANT=1 drops the poll
#      branch from account_usage_rows and this arm goes red.
#   2  a walled account (429 WITH the headers) reads 100%, not stale.
#   3  a rejected login (401), a refused one (403) and no answer: STALE with
#      the reason, the last numbers kept, never 0%.
#   4  age decides: a fresher seat reading beats an older poll and back.
#   5  burn rate: 5h points per hour over the last hour, inside one window.
#   6  the token reaches curl on stdin only, and no output, record or log line
#      carries it.
#   7  the heartbeat polls only on a box that opted in (account-poll=on).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
TMP=$(mktemp -d "${TMPDIR:-/tmp}/account-poll.XXXXXX")
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

source src/lib/error_codes.sh
source src/lib/output.sh
source src/header.sh
source src/lib/actor.sh
eval "$(sed -n '/^sqlq() {/,/^}/p; /^sqlq_or_null() {/,/^}/p' src/lib/tasks_db.sh)"
source src/lib/account_history.sh
source src/lib/verify_policy.sh
ACCT_SRC=$(cat src/cmd_account.sh)
if [[ "${POLL_MUTANT:-0}" == 1 ]]; then
  ACCT_SRC=$(sed 's/^    if \[\[ -n "\$polled" \]\]; then$/    if false; then/' <<<"$ACCT_SRC")
  grep -q '^    if false; then$' <<<"$ACCT_SRC" || { echo "MUTANT DID NOT APPLY" >&2; exit 3; }
  echo "MUTANT: the poll reading no longer competes in account_usage_rows"
fi
source <(printf '%s\n' "$ACCT_SRC")
set +e

PASS=0; FAIL=0
t() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; else
    FAIL=$((FAIL+1)); printf 'FAIL %s — expected %s, got %s\n' "$1" "$2" "$3" >&2
  fi
}

REG="$TMP/agents.json"
AUTH_PROFILES_DIR="$TMP/profiles"
HOMES="$TMP/home"
TASKS_DB="$TMP/tasks.db"
require_root()   { :; }
ensure_state()   { :; }
registry_read()  { cat "$REG"; }
usage_agent_home() { printf '%s/agent-%s\n' "$HOMES" "$1"; }
quota_snapshot_publish() { :; }
sqlite3 "$TASKS_DB" "CREATE TABLE account_binding_events (id INTEGER PRIMARY KEY, ts INTEGER, agent TEXT, account TEXT, reason TEXT);
  CREATE TABLE account_usage_samples (account TEXT NOT NULL, as_of INTEGER NOT NULL, five_pct REAL, five_reset TEXT,
    seven_pct REAL, seven_reset TEXT, source_agent TEXT NOT NULL, UNIQUE(account, as_of));"

TOKEN="harness-token-6713-must-never-print"
for a in idle busy walled dead; do
  mkdir -p "$AUTH_PROFILES_DIR/$a"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOKEN" >"$AUTH_PROFILES_DIR/$a/combined.env"
done
mkdir -p "$AUTH_PROFILES_DIR/codexacct"; printf 'OPENAI_API_KEY=x\n' >"$AUTH_PROFILES_DIR/codexacct/combined.env"
echo '{"agents":{"dev":{"type":"claude","authProfile":"busy"}}}' >"$REG"
account_agents_bound() { jq -c --arg a "$1" '[.agents | to_entries[] | select(.value.authProfile == $a) | .key]' "$REG"; }

NOW=$(date +%s); R5=$((NOW + 7200)); R7=$((NOW + 300000))
# hdrs <code> [5h 7d] — what the provider answers.
hdrs() {
  printf 'HTTP/2 %s\r\n' "$1"
  [[ -n "${2:-}" ]] && printf 'anthropic-ratelimit-unified-5h-utilization: %s\r\nanthropic-ratelimit-unified-7d-utilization: %s\r\nanthropic-ratelimit-unified-5h-reset: %s\r\nanthropic-ratelimit-unified-7d-reset: %s\r\n' "$2" "$3" "$R5" "$R7"
  return 0
}
probe() {
  case "$1" in
    idle)   hdrs 200 0.03 0.42 ;;
    busy)   hdrs 200 0.10 0.50 ;;
    walled) hdrs 429 1.0 0.35 ;;
    dead)   hdrs "${DEAD_CODE-401}" ;;
  esac
}
_ROTATION_PROBE_CMD=probe
row() { jq -c --arg n "$1" ".[] | select(.name == \$n) | $2" <<<"$ROWS"; }

# --- 1 / 2 / 3 ---------------------------------------------------------------
t "targets: Claude accounts only" "busy dead idle walled" "$(account_poll_targets | sort | xargs)"
echo '{"fiveHour":{"pct":40,"resetsAt":1},"sevenDay":{"pct":60,"resetsAt":2},"asOf":1000,"source":"quinn","remembered":false}' \
  >"$AUTH_PROFILES_DIR/dead/usage.json"
OUT=$(account_poll_all)
printf '%s\n' "$OUT" | sed 's/^/     poll: /'
ROWS=$(account_usage_rows)
t "1 idle account: source poll"            '"poll"'  "$(row idle .usage.source)"
t "1 idle account: live, not remembered"    'false'   "$(row idle .usage.remembered)"
t "1 idle account: 5h/7d from the provider" '[3,42]'  "$(row idle '[.usage.fiveHour.pct,.usage.sevenDay.pct]')"
t "1 reading is under a minute old"         'true'    "$(row idle "(.usage.asOf >= $NOW)")"
t "2 walled (429 with headers) reads 100%"  '[100,35]' "$(row walled '[.usage.fiveHour.pct,.usage.sevenDay.pct]')"
t "3 401: stale, reason named"              '"login rejected"' "$(row dead .usage.pollError)"
t "3 401: last numbers kept, never 0%"      '[40,60]' "$(row dead '[.usage.fiveHour.pct,.usage.sevenDay.pct]')"
t "3 401: shown as remembered"              'true'    "$(row dead .usage.remembered)"
DEAD_CODE=403 account_poll_one dead >/dev/null
t "3 403: reason named" '"provider refuses this login"' "$(jq -c .pollError "$AUTH_PROFILES_DIR/dead/usage.json")"
DEAD_CODE="" account_poll_one dead >/dev/null
t "3 no answer: reason named" '"no answer"' "$(jq -c .pollError "$AUTH_PROFILES_DIR/dead/usage.json")"
t "3 the poll appended its readings to the history" '3' \
  "$(sqlite3 "$TASKS_DB" "SELECT count(*) FROM account_usage_samples WHERE source_agent='poll'")"
TABLE=$(JSON_MODE=0 cmd_account_usage)
printf '%s\n' "$TABLE" | sed 's/^/     table: /'
t "3 table says stale and why" '1' "$(grep -c '^dead .*stale .*(no answer)' <<<"$TABLE")"
t "1 table says poll and its age" '1' "$(grep -cE '^idle .* poll 0m$' <<<"$TABLE")"

# --- 4 -----------------------------------------------------------------------
mkdir -p "$HOMES/agent-dev/.claude"
jq -cn --argjson r "$R5" '{rate_limits:{five_hour:{used_percentage:22,resets_at:$r},seven_day:{used_percentage:55,resets_at:1}}}' \
  >"$HOMES/agent-dev/.claude/statusline-last.json"
touch -d "@$((NOW + 30))" "$HOMES/agent-dev/.claude/statusline-last.json"
ROWS=$(account_usage_rows)
t "4 fresher seat reading beats the poll" '["dev",22]' "$(row busy '[.usage.source,.usage.fiveHour.pct]')"
touch -d "@$((NOW - 600))" "$HOMES/agent-dev/.claude/statusline-last.json"
account_poll_one busy >/dev/null
ROWS=$(account_usage_rows)
t "4 fresher poll beats an older seat reading" '["poll",10]' "$(row busy '[.usage.source,.usage.fiveHour.pct]')"
t "4 seats bound are on the row" '["dev"]' "$(row busy .agents)"

# --- 5 -----------------------------------------------------------------------
sqlite3 "$TASKS_DB" "DELETE FROM account_usage_samples;
  INSERT INTO account_usage_samples VALUES ('idle', $((NOW-7000)), 0,  '$R5', 40, '1', 'poll');
  INSERT INTO account_usage_samples VALUES ('idle', $((NOW-3000)), 10, '$R5', 40, '1', 'poll');
  INSERT INTO account_usage_samples VALUES ('idle', $((NOW-1200)), 20, '$R5', 41, '1', 'dev');
  INSERT INTO account_usage_samples VALUES ('idle', $((NOW-600)),  30, '$R5', 42, '1', 'poll');
  INSERT INTO account_usage_samples VALUES ('reset', $((NOW-3000)), 90, '$((R5-18000))', 40, '1', 'poll');
  INSERT INTO account_usage_samples VALUES ('reset', $((NOW-1800)), 2,  '$R5', 40, '1', 'poll');
  INSERT INTO account_usage_samples VALUES ('reset', $((NOW-600)),  8,  '$R5', 40, '1', 'poll');
  INSERT INTO account_usage_samples VALUES ('short', $((NOW-300)),  5,  '$R5', 40, '1', 'poll');
  INSERT INTO account_usage_samples VALUES ('short', $((NOW-60)),   9,  '$R5', 40, '1', 'poll');"
BURN=$(account_usage_burn_json "$NOW")
t "5 burn over the last hour (20 pts in 40 min)" '30' "$(jq -c .idle <<<"$BURN")"
t "5 a reset restarts the anchor (6 pts in 20 min)" '18' "$(jq -c .reset <<<"$BURN")"
t "5 under ten minutes of samples is no rate" 'null' "$(jq -c .short <<<"$BURN")"

# --- 6 -----------------------------------------------------------------------
unset _ROTATION_PROBE_CMD
CURL_LOG="$TMP/curl.log"
curl() {
  local stdin; stdin=$(cat)
  printf 'argv: %s\n' "$*" >>"$CURL_LOG"
  [[ "$stdin" == *"$TOKEN"* ]] && echo "stdin: carries token" >>"$CURL_LOG"
  hdrs 200 0.05 0.40
}
OUT6=$(account_poll_all)
t "6 the token reached curl on stdin" '4' "$(grep -c 'stdin: carries token' "$CURL_LOG")"
t "6 the token is never on curl's argv" '0' "$(grep -c "argv: .*$TOKEN" "$CURL_LOG")"
LEAK=$(printf '%s\n' "$OUT" "$OUT6" "$TABLE"; cat "$AUTH_PROFILES_DIR"/*/usage.json; sqlite3 "$TASKS_DB" .dump)
t "6 no output, record or history row carries the token" '0' "$(grep -c "$TOKEN" <<<"$LEAK")"
unset -f curl

# --- 7 -----------------------------------------------------------------------
eval "$(sed -n '/^_hb_account_poll_enabled() {/,/^}/p; /^_hb_account_poll_sweep() {/,/^}/p' src/cmd_heartbeat.sh)"
_HB_ACCOUNT_POLL_EVERY_SEC=540
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"; BOX_CONFIG="$TMP/box.json"
HBLOG="$TMP/hb.log"; _hb_log() { printf '%s\n' "$*" >>"$HBLOG"; }
account_poll_all() { echo "x 5h 1% 7d 1%"; }
echo '{}' >"$BOX_CONFIG"
_hb_account_poll_sweep "$NOW"
t "7 a box that did not opt in never polls" '0' "${_HB_APOLL_RAN}"
echo '{"account_poll":"on"}' >"$BOX_CONFIG"
_hb_account_poll_sweep "$NOW"
t "7 account-poll=on polls" '1' "${_HB_APOLL_RAN}"
t "7 and logs each account" '1' "$(grep -c '^\[account-poll\] x 5h' "$HBLOG")"
_hb_account_poll_sweep "$((NOW + 60))"
t "7 not again inside the cadence" '0' "${_HB_APOLL_RAN}"
_hb_account_poll_sweep "$((NOW + 540))"
t "7 again at 540s, so no reading passes 10 min" '1' "${_HB_APOLL_RAN}"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
