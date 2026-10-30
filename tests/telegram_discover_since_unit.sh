#!/usr/bin/env bash
# DIVE-7332: `5dive init` paired whoever had a message pending on the bot, even
# one sent before setup began (init QA 2026-10-30: "Telegram connected" 0.7 s
# after the prompt), and wrote them to the allowlist without asking. Arms:
#   1  discover --since skips a message sent before setup and returns the one
#      sent after it, in the same getUpdates answer.
#   2  an old message alone is confirmed (offset = its update_id + 1) and the
#      poll goes on to find the new one in the next round.
#   3  only old messages: found:false, and they were confirmed, not returned.
#   4  NEGATIVE CONTROL: without --since the first pending message wins, as
#      before (the dashboard's path) — the defect arm 1 removes.
#   5  init's Telegram step (run for real, with discover and the picker stubbed):
#      passes --since, shows the sender, and allowlists only on "yes"; "keep
#      waiting" moves --since forward and takes the next sender; "pair later"
#      allowlists nobody.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tg-discover-since.XXXXXX")
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

source src/lib/error_codes.sh
source src/lib/output.sh
source src/lib/validation.sh
source src/cmd_agent_telegram.sh
JSON_MODE=1
TOKEN="1234567890:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

PASS=0; FAIL=0
t() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; else
    FAIL=$((FAIL+1)); printf 'FAIL %s — expected %s, got %s\n' "$1" "$2" "$3" >&2
  fi
}

# Sent before setup (date 900) by a stranger; sent after it (date 1100) by the owner.
OLD='{"update_id":10,"message":{"date":900,"from":{"id":111,"first_name":"Stranger"},"chat":{"id":111}}}'
NEW='{"update_id":11,"message":{"date":1100,"from":{"id":222,"first_name":"Owner","username":"owner"},"chat":{"id":222}}}'

# curl stub: getUpdates answers from $TMP/round.<n> (then an empty result) and
# logs the offset it was asked for; deleteWebhook answers nothing.
curl() {
  local a url="" offset="-"
  for a in "$@"; do
    case "$a" in
      https://*) url="$a" ;;
      offset=*)  offset="${a#offset=}" ;;
    esac
  done
  [[ "$url" == */getUpdates ]] || return 0
  local n; n=$(( $(cat "$TMP/calls" 2>/dev/null || echo 0) + 1 ))
  echo "$n" >"$TMP/calls"
  echo "$offset" >>"$TMP/offsets"
  if [[ -f "$TMP/round.$n" ]]; then cat "$TMP/round.$n"; else echo '{"ok":true,"result":[]}'; fi
}
rounds() {
  rm -f "$TMP"/round.* "$TMP/calls" "$TMP/offsets"
  local i=1 r
  for r in "$@"; do printf '{"ok":true,"result":[%s]}' "$r" >"$TMP/round.$i"; i=$((i+1)); done
}

# 1
rounds "$OLD,$NEW"
out=$(cmd_telegram_discover --token="$TOKEN" --poll-secs=1 --since=1000)
t "1 --since returns the message sent after setup" "222" "$(jq -r '.data.userId' <<<"$out")"
t "1 sentAt is the message's send time" "1100" "$(jq -r '.data.sentAt' <<<"$out")"

# 2
rounds "$OLD" "$NEW"
out=$(cmd_telegram_discover --token="$TOKEN" --poll-secs=1 --since=1000)
t "2 old message alone: next round finds the new one" "222" "$(jq -r '.data.userId' <<<"$out")"
t "2 the old message was confirmed (offset 11)" "- 11" "$(tr '\n' ' ' <"$TMP/offsets" | sed 's/ $//')"

# 3
rounds "$OLD"
out=$(cmd_telegram_discover --token="$TOKEN" --poll-secs=1 --since=1000)
t "3 only an old message: found:false" "false" "$(jq -r '.data.found' <<<"$out")"
t "3 the old message was confirmed" "11" "$(sed -n 2p "$TMP/offsets")"

# 4
rounds "$OLD,$NEW"
out=$(cmd_telegram_discover --token="$TOKEN" --poll-secs=1)
t "4 control: without --since the first pending message wins" "111" "$(jq -r '.data.userId' <<<"$out")"
out=$(cmd_telegram_discover --token="$TOKEN" --poll-secs=1 --since=soon 2>/dev/null)
t "4 --since must be a number" "false" "$(jq -r '.ok' <<<"$out")"

# 5: run init's real Telegram step, cut from cmd_init.
source src/cmd_init.sh
step=$(declare -f cmd_init | sed -n '/local discover_json tg_since/,/^ *done;\{0,1\}$/p')
[[ "$step" == *"telegram-discover"* && "$step" == *"done"* ]] \
  || { echo "FAIL 5: could not cut the Telegram step out of cmd_init" >&2; exit 1; }
eval "init_tg_step() { $step
}"
_init_note() { :; }; _init_ok() { echo "OK $*" >>"$TMP/init.out"; }
# 5dive stub: each discover call answers the next sender in $SENDERS and logs its --since.
5dive() {
  local a; for a in "$@"; do [[ "$a" == --since=* ]] && echo "${a#--since=}" >>"$TMP/since"; done
  local n; n=$(( $(cat "$TMP/dcalls" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$TMP/dcalls"
  local who; who=$(cut -d' ' -f"$n" <<<"$SENDERS")
  case "$who" in
    stranger) echo '{"ok":true,"data":{"found":true,"userId":"111","firstName":"Stranger","username":""}}' ;;
    owner)    echo '{"ok":true,"data":{"found":true,"userId":"222","firstName":"Owner","username":"owner"}}' ;;
    *)        echo '{"ok":true,"data":{"found":false}}' ;;
  esac
}
# picker stub: answers from $PICKS in order, logs each question.
_init_pick() {
  local n; n=$(( $(cat "$TMP/pcalls" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$TMP/pcalls"
  echo "$2" >>"$TMP/asked"
  printf -v "$1" '%s' "$(cut -d' ' -f"$n" <<<"$PICKS")"
}
run_step() {
  rm -f "$TMP/since" "$TMP/dcalls" "$TMP/pcalls" "$TMP/asked" "$TMP/init.out"
  SENDERS="$1" PICKS="$2"
  local telegram_token="$TOKEN" telegram_user_id="" name="my-agent" tg_where="@bot"
  init_tg_step
  echo "$telegram_user_id"
}

uid=$(run_step "owner" "yes")
t "5 yes: the sender is allowlisted" "222" "$uid"
t "5 the owner is shown who sent it" "Message from Owner (@owner). Let them talk to my-agent?" "$(cat "$TMP/asked")"
t "5 discover was asked for messages sent after the prompt" "yes" \
  "$([[ "$(cat "$TMP/since")" =~ ^[0-9]+$ ]] && echo yes || echo no)"

uid=$(run_step "stranger owner" "wait yes")
t "5 keep waiting: the stranger is skipped, the owner is allowlisted" "222" "$uid"
t "5 the stranger was named before the skip" "Message from Stranger (id 111). Let them talk to my-agent?" "$(head -1 "$TMP/asked")"
s1=$(sed -n 1p "$TMP/since"); s2=$(sed -n 2p "$TMP/since")
t "5 keep waiting moves --since forward" "yes" "$( (( s2 >= s1 )) && echo yes || echo no)"

uid=$(run_step "stranger" "skip")
t "5 pair later: nobody is allowlisted" "" "$uid"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
