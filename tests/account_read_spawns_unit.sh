#!/usr/bin/env bash
# DIVE-6985: `account list` and `account usage` back the Telegram /account
# picker, and on poke-two they took 1.5s and 1.8s — almost all of it spawned
# processes, not work: ~23 per account to find its signed-in types (a `$( )`
# fork per type, a grep per env var), ~10 per (account, type) for the sign-in
# tile, and for usage two registry reads per account, one more per seat, five
# jq field reads and two sqlite calls per account with a live reading.
#
# The rewrite reads combined.env once with builtins, skips a type with no
# <profile>/<type>/ dir before forking, builds the tile's JSON without jq where
# it can, and joins the usage rows from ONE registry read, ONE jq and ONE
# sqlite write. This harness pins what that must keep (the grep semantics it
# replaced, exact JSON) and the call counts that make it fast.
# Run: bash tests/account_read_spawns_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/acct-spawns.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/registry.sh lib/tasks_db.sh \
         lib/quota_wall.sh lib/codex_quota.sh lib/account_history.sh cmd_auth.sh cmd_account.sh; do
  source "$SRC/$f"
done
set +e
lazy_need() { :; }
ensure_state_ro() { :; }
_tasks_store_fence() { :; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want: $3 | got: $2"; fi; }

AUTH_PROFILES_DIR="$TMP/profiles"; CONNECTORS_DIR="$TMP/connectors"
STATE_DIR="$TMP"; REGISTRY="$TMP/registry.json"; TASKS_DB="$TMP/tasks.db"
QUOTA_SNAPSHOT_FILE="$TMP/account-usage.json"
mkdir -p "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR" "$TMP/home"
usage_agent_home() { printf '%s/home/%s\n' "$TMP" "$1"; }
mk() { mkdir -p "$AUTH_PROFILES_DIR/$1"; printf '%s\n' "${@:2}" >"$AUTH_PROFILES_DIR/$1/combined.env"; }
types_of() { account_types_authed_arr "$1"; local IFS=,; printf '%s' "${ACCOUNT_TYPES_AUTHED[*]}"; }

# --- A: types — the grep semantics the one-pass read replaced -----------------
mk oauth 'CLAUDE_CODE_OAUTH_TOKEN=t'
mk emptykey 'ANTHROPIC_API_KEY='              # `grep ^VAR=` matched an empty value
mk pi-empty 'ZAI_API_KEY='                    # `grep ^VAR=.+` did not
mk exported 'export XAI_API_KEY=x' 'FOO BAR=1' 'OPENAI_API_KEY'
printf 'MOONSHOT_API_KEY=m\r\n' >"$AUTH_PROFILES_DIR/crlf.env"; mkdir -p "$AUTH_PROFILES_DIR/crlf"
mv "$AUTH_PROFILES_DIR/crlf.env" "$AUTH_PROFILES_DIR/crlf/combined.env"
mk sub 'X=1'; mkdir -p "$AUTH_PROFILES_DIR/sub/claude"; echo '{}' >"$AUTH_PROFILES_DIR/sub/claude/.credentials.json"
mk cdx 'X=1'; mkdir -p "$AUTH_PROFILES_DIR/cdx/codex"; echo '{}' >"$AUTH_PROFILES_DIR/cdx/codex/auth.json"
check "A1 CLAUDE_CODE_OAUTH_TOKEN= -> claude" "$(types_of oauth)" "claude"
check "A2 ANTHROPIC_API_KEY= with an empty value still -> claude (as ^VAR= did)" "$(types_of emptykey)" "claude"
check "A3 an empty pi key is not pi (as ^VAR=.+ did)" "$(types_of pi-empty)" ""
check "A4 'export VAR=', a key with a space, a bare name: none count" "$(types_of exported)" ""
check "A5 a CRLF line still has a value" "$(types_of crlf)" "pi"
check "A6 per-type sentinel under <profile>/claude/" "$(types_of sub)" "claude"
check "A7 per-type sentinel under <profile>/codex/" "$(types_of cdx)" "codex"

# --- B: the sign-in tile's JSON is exact without jq ---------------------------
mk byo 'ANTHROPIC_API_KEY=k' 'ANTHROPIC_BASE_URL=https://openrouter.ai/api' \
       'ANTHROPIC_DEFAULT_SONNET_MODEL=a"b\c' 'ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic"'
mk uni 'ANTHROPIC_API_KEY=k' 'ANTHROPIC_BASE_URL=https://openrouter.ai/api' 'ANTHROPIC_DEFAULT_SONNET_MODEL=modèl'
touch -d '2026-05-01 10:00:00Z' "$AUTH_PROFILES_DIR"/*/combined.env
d=$(account_signin_detail byo claude)
check "B1 last ANTHROPIC_BASE_URL wins, quotes stripped -> provider" "$(jq -r .provider <<<"$d")" "zai"
check "B2 a quote and a backslash survive as JSON" "$(jq -r .model <<<"$d")" 'a"b\c'
check "B3 signedInAt" "$(jq -r .signedInAt <<<"$d")" "2026-05-01T10:00:00Z"
check "B4 non-ASCII goes through jq, same bytes" "$(account_signin_detail uni claude | jq -r .model)" "modèl"
account_signin_detail_v byo claude
check "B5 the no-fork form leaves the same object" "$ACCOUNT_SIGNIN_DETAIL" "$d"
check "B6 a type not signed in is {}" "$(account_signin_detail oauth codex)" "{}"

# --- C: account usage — one registry read, one jq join, one sqlite write ------
rm -rf "$AUTH_PROFILES_DIR"; mkdir -p "$AUTH_PROFILES_DIR"
now=$(date +%s)
for p in a b c d e; do mk "$p" 'X=1'; done
reg='{"agents":{'; sep=""
i=0
for s in s1 s2 s3 s4 s5 s6 s7 s8; do
  i=$((i+1)); p=$(cut -d' ' -f$(( (i % 4) + 1 )) <<<"a b c d")
  mkdir -p "$TMP/home/$s/.claude"
  printf '{"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":"2026-11-01T00:00:00Z"}}}' \
    "$((i * 5))" "$((now + 3600))" "$i" >"$TMP/home/$s/.claude/statusline-last.json"
  touch -d "@$((now - i * 60))" "$TMP/home/$s/.claude/statusline-last.json"
  reg+="${sep}\"$s\":{\"authProfile\":\"$p\",\"type\":\"claude\"}"; sep=,
done
echo "${reg},\"loose\":{\"type\":\"claude\"}}}" >"$REGISTRY"
echo "{\"asOf\":$((now + 100)),\"source\":\"poll\",\"pollError\":null,\"fiveHour\":{\"pct\":7,\"resetsAt\":1},\"sevenDay\":null}" \
  >"$AUTH_PROFILES_DIR/b/usage.json"
echo '{"asOf":1,"source":"s9","fiveHour":{"pct":70,"resetsAt":1},"sevenDay":null}' >"$AUTH_PROFILES_DIR/e/usage.json"
: >"$TASKS_DB"
_account_history_ensure   # both history tables, as a live board has them

SQL_CALLS="$TMP/sqlite.calls"; JQ_CALLS="$TMP/jq.calls"
sqlite3() { echo x >>"$SQL_CALLS"; command sqlite3 "$@"; }
jq()      { echo x >>"$JQ_CALLS"; command jq "$@"; }
rows=$(account_usage_rows)
unset -f sqlite3 jq
check "C1 a row per account, in dir order" "$(jq -c '[.[].name]' <<<"$rows")" '["a","b","c","d","e"]'
check "C2 bound seats from the one registry read" "$(jq -c '[.[].agents]' <<<"$rows")" '[["s4","s8"],["s1","s5"],["s2","s6"],["s3","s7"],[]]'
check "C3 the freshest seat's reading wins" "$(jq -r '.[0].usage | "\(.source) \(.fiveHour.pct) \(.remembered)"' <<<"$rows")" "s4 20 false"
check "C4 a newer poll reading beats the seats" "$(jq -r '.[1].usage.source' <<<"$rows")" "poll"
check "C5 no seats: the account's remembered reading" "$(jq -r '.[4].usage | "\(.remembered) \(.fiveHour.pct)"' <<<"$rows")" "true 70"
check "C6 one sample per account with a live seat" "$(command sqlite3 "$TASKS_DB" 'SELECT group_concat(account) FROM (SELECT account FROM account_usage_samples ORDER BY account)')" "a,c,d"
n=$(wc -l <"$SQL_CALLS")
if (( n <= 3 )); then ok_t "C7 sqlite ran $n times (burn read, schema check, one batched insert), not 2 per account"
else bad_t "C7 sqlite calls" "want <= 3, got $n"; fi
n=$(wc -l <"$JQ_CALLS")
# 1 registry + 1 burn + 8 seat caches + 5 poll checks + 3 live usages + 1 recall
# + 1 join. The loop this replaced ran 64 here (and sqlite 7 times).
if (( n <= 20 )); then ok_t "C8 jq ran $n times for 5 accounts and 8 seats (budget 20)"
else bad_t "C8 jq calls" "want <= 20, got $n"; fi
ino=$(stat -c %i "$AUTH_PROFILES_DIR/a/usage.json")
rows2=$(account_usage_rows)
check "C9 a second pass gives the same rows" "$rows2" "$rows"
check "C10 an unchanged reading is not rewritten" "$(stat -c %i "$AUTH_PROFILES_DIR/a/usage.json")" "$ino"
check "C11 the sample is not inserted twice" "$(command sqlite3 "$TASKS_DB" 'SELECT count(*) FROM account_usage_samples')" "3"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
