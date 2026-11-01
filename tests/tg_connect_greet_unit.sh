#!/usr/bin/env bash
# DIVE-7478 — the owner is greeted the moment Telegram is connected, and sees
# "typing" until the agent's session polls (`agent _tg_connect_greet`).
#
# Against a curl stub that plays the Telegram Bot API (no root, no network, no
# systemd, no bot):
#   G1   an allowlisted owner gets the greeting at once: the bot's name, its short
#        description, the ask line and the "starting up" line.
#   G2   the token never reaches curl's argv (it goes through -K on stdin).
#   G3   "typing" goes to the greeted chat while the bridge is down.
#   G4   connect-greeted.json {botId, at, chats} is written 0600, and boot-greeted
#        holds the bot id (an older claude plugin then skips its boot greeting).
#   G5   the bridge's heartbeat bumped after the start ends the run early.
#   G6   an owner who has not pressed Start (403) is greeted on their first
#        message, in their language (ru), and the peek NEVER confirms an update
#        (no offset in any getUpdates body).
#   G7   a refused getUpdates (webhook / another poller, 409) stops the peeking.
#   G8   a stranger's message and a group message are not greeted.
#   G9   owners: `owners` wins over allowFrom but only allowlisted, positive ids.
#   G10  no owner id: nothing is sent.
#   G11  the persona's name and welcome replace the bot's (bun only; skipped without).
#   E1-E2 under the binary's set -e, a dead network (every call, or only the peek)
#        costs the sends, never the run: it still ends with its JSON line, rc 0.
#   P1-P2 the markers are written as the seat (runuser -u agent-<name> when root),
#        and a symlink planted at boot-greeted is replaced, its target untouched.
#   L1-L3 the launch: the systemd-run argv (unit, verb, name); skipped for
#        openclaw/hermes; FIVE_TG_CONNECT_GREET=0 turns it off.
#   W1-W4 wiring: the dispatch arm, build.sh loads the module, config set launches
#        on a first attach with a new token only, create launches before the seat starts.
#   NC1  NEGATIVE CONTROL: a copy with the bridge-up stop removed must be CAUGHT by G5.
#   NC2  NEGATIVE CONTROL: a copy whose peek passes an offset must be CAUGHT by G6.
#   NC3  NEGATIVE CONTROL: a copy without the getMe `|| …` guard must be CAUGHT by E1.
# Run: bash tests/tg_connect_greet_unit.sh   (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 2
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tg-connect-greet.XXXXXX")"

export STATE_DIR="$TMP/state" AGENT_HOME_ROOT="$TMP/home" CONNECTORS_DIR="$TMP/connectors" STUB_DIR="$TMP"
mkdir -p "$STATE_DIR" "$CONNECTORS_DIR" "$TMP/bin"
MOD="src/cmd_tg_connect_greet.sh"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/state.sh lib/registry.sh cmd_agent_pairing.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
CONNECTORS_DIR="$TMP/connectors"
load() {
  # shellcheck source=/dev/null
  source "${1:-$MOD}"
  set +e
  ensure_state() { :; }
  registry_read() { cat "$STATE_DIR/agents.json"; }
}
load
export PATH="$TMP/bin:$PATH"
export TG_CONNECT_GREET_TICK=0.05 TG_CONNECT_GREET_MAX_SEC=2 TG_CONNECT_TYPING_EVERY=4 TG_CONNECT_PEEK_EVERY=2

pass=0; fail=0
ok_t()  { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { fail=$((fail+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if eval "$2"; then ok_t "$1"; else bad_t "$1" "${3:-$2}"; fi; }

TOKEN="7000000001:AAH-secret-part-ABCDEFGHIJKLMNOP"
OWNER=1234567890
# The Bot API: one line per call in calls.log ("<method> <body>"), argv kept.
#   STUB_403        space-separated chat ids whose sendMessage answers 403
#   STUB_UPDATES    a file with the getUpdates result array
#   STUB_PEEK_409   1 = getUpdates answers 409
#   STUB_HB_AFTER   N = touch the heartbeat on the Nth sendChatAction (the bridge comes up)
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$STUB_DIR/curl.argv"
url=$(sed -n 's/^url = "\(.*\)"$/\1/p'); method="${url##*/}"
body=""; prev=""; for a in "$@"; do [[ "$prev" == "--data-binary" ]] && body="$a"; prev="$a"; done
printf '%s %s\n' "$method" "$body" >>"$STUB_DIR/calls.log"
[[ "${STUB_CURL_FAIL:-}" == all || "${STUB_CURL_FAIL:-}" == "$method" ]] && exit 7
case "$method" in
  getMe) printf '{"ok":true,"result":{"id":7000000001,"first_name":"Ada","username":"ada_bot"}}' ;;
  getMyShortDescription) printf '{"ok":true,"result":{"short_description":"keeps the books"}}' ;;
  sendMessage)
    chat=$(jq -r .chat_id <<<"$body")
    # 403 until the owner's own message has been seen (they pressed Start).
    if [[ " ${STUB_403:-} " == *" $chat "* ]] && ! grep -qx "$chat" "$STUB_DIR/started" 2>/dev/null; then printf '{"ok":false,"error_code":403,"description":"Forbidden: bot can'"'"'t initiate conversation with a user"}'
    else printf '{"ok":true,"result":{"message_id":1}}'; fi ;;
  sendChatAction)
    n=$(( $(cat "$STUB_DIR/typing.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$STUB_DIR/typing.n"
    [[ -n "${STUB_HB_AFTER:-}" && "$n" -ge "$STUB_HB_AFTER" ]] && date +%s >"$STUB_HB_FILE" && touch -d "@$(( $(date +%s) + 1 ))" "$STUB_HB_FILE"
    printf '{"ok":true,"result":true}' ;;
  getUpdates)
    if [[ "${STUB_PEEK_409:-0}" == 1 ]]; then printf '{"ok":false,"error_code":409,"description":"Conflict: can'"'"'t use getUpdates method while webhook is active"}'
    else
      res=$(cat "${STUB_UPDATES:-/dev/null}" 2>/dev/null); [[ -n "$res" ]] || res='[]'
      jq -r '.[] | select(.message.chat.type == "private") | .message.chat.id' <<<"$res" >>"$STUB_DIR/started"
      printf '{"ok":true,"result":%s}' "$res"
    fi ;;
  *) printf '{"ok":false}' ;;
esac
EOF
chmod +x "$TMP/bin/curl"
cat >"$TMP/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$STUB_DIR/sdrun.argv"; echo --- >>"$STUB_DIR/sdrun.argv"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/bin/systemctl"
chmod +x "$TMP/bin/systemd-run" "$TMP/bin/systemctl"

# seat <name> <type> <access-json> — a fresh seat with its state dir and token.
seat() {
  local name="$1" type="$2" dir
  dir="$AGENT_HOME_ROOT/agent-$name/.$type/channels/telegram"
  rm -rf "$AGENT_HOME_ROOT/agent-$name"; mkdir -p "$dir"
  printf '%s\n' "$3" >"$dir/access.json"
  printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" >"$CONNECTORS_DIR/telegram-$name.env"
  printf '{"agents":{"%s":{"type":"%s","channels":"telegram"}}}\n' "$name" "$type" >"$STATE_DIR/agents.json"
  rm -f "$TMP/calls.log" "$TMP/curl.argv" "$TMP/typing.n" "$TMP/started"
  SEAT_DIR="$dir"
}
run() { OUT=$(cmd_agent_tg_connect_greet "$1" 2>"$TMP/err"); }
calls() { grep -c "^$1 " "$TMP/calls.log" 2>/dev/null || true; }

# ── G1-G4: a greeted owner ───────────────────────────────────────────────────
seat ada claude "{\"dmPolicy\":\"allowlist\",\"allowFrom\":[\"$OWNER\"],\"groups\":{}}"
run ada
first=$(grep -m1 '^sendMessage ' "$TMP/calls.log" | cut -d' ' -f2-)
text=$(jq -r .text <<<"$first" 2>/dev/null)
check "G1 the owner is greeted at once (first message goes to the owner)" \
  '[[ "$(jq -r .chat_id <<<"$first")" == "$OWNER" ]]' "first sendMessage: $first"
want=$'Hi, I\'m Ada.\nAda keeps the books.\n\nTell me what you need, and I will get on it.\n\nI\'m starting up, ready in about 30 seconds.'
check "G1 the text is the /start greeting plus the starting-up line" '[[ "$text" == "$want" ]]' "got: $text"
check "G1 the greeting is the run's first send (before any typing)" \
  '[[ "$(grep -m1 -E "^(sendMessage|sendChatAction) " "$TMP/calls.log" | cut -d" " -f1)" == sendMessage ]]'
check "G2 the token never reaches curl argv" '! grep -qF "secret-part" "$TMP/curl.argv"'
check "G3 typing goes to the greeted owner while the bridge is down" \
  '(( $(calls sendChatAction) >= 2 )) && grep "^sendChatAction " "$TMP/calls.log" | grep -q "\"chat_id\":$OWNER" && grep -q "\"action\":\"typing\"" "$TMP/calls.log"'
mk="$SEAT_DIR/connect-greeted.json"
check "G4 connect-greeted.json names the bot and the chat" \
  '[[ "$(jq -c "{botId, chats}" "$mk")" == "{\"botId\":\"7000000001\",\"chats\":[\"$OWNER\"]}" ]] && jq -e ".at > 1700000000000" "$mk" >/dev/null' "$(cat "$mk" 2>&1)"
check "G4 the marker is 0600" '[[ "$(stat -c %a "$mk")" == 600 ]]'
check "G4 boot-greeted holds the bot id" '[[ "$(cat "$SEAT_DIR/boot-greeted")" == 7000000001 ]]'
check "G4 the run reports who it greeted and that the bridge never came up" \
  '[[ "$(jq -c "{greeted, bridgeUp}" <<<"$OUT")" == "{\"greeted\":[\"$OWNER\"],\"bridgeUp\":false}" ]]' "$OUT"
check "G1 one greeting only" '[[ "$(calls sendMessage)" == 1 ]]'

# ── G5: the bridge comes up ──────────────────────────────────────────────────
g5() {
  seat ada claude "{\"allowFrom\":[\"$OWNER\"]}"
  STUB_HB_FILE="$SEAT_DIR/bot.heartbeat" STUB_HB_AFTER=2 TG_CONNECT_GREET_MAX_SEC=6
  export STUB_HB_FILE STUB_HB_AFTER TG_CONNECT_GREET_MAX_SEC
  local t0=$SECONDS; run ada; G5_SECS=$(( SECONDS - t0 ))
  unset STUB_HB_FILE STUB_HB_AFTER; export TG_CONNECT_GREET_MAX_SEC=2
}
g5
check "G5 the bridge's heartbeat ends the run (bridgeUp, well before the cap)" \
  '[[ "$(jq -r .bridgeUp <<<"$OUT")" == true ]] && (( G5_SECS < 4 )) && [[ "$(calls sendChatAction)" == 2 ]]' "out=$OUT secs=$G5_SECS typing=$(calls sendChatAction)"

# ── G6-G8: an owner who has not pressed Start ────────────────────────────────
seat ada claude "{\"allowFrom\":[\"$OWNER\",\"555\"]}"
cat >"$TMP/updates.json" <<EOF
[{"update_id":10,"message":{"chat":{"id":-100777,"type":"supergroup"},"from":{"id":$OWNER,"language_code":"ru"},"text":"hi all"}},
 {"update_id":11,"message":{"chat":{"id":999,"type":"private"},"from":{"id":999,"language_code":"en"},"text":"hey"}},
 {"update_id":12,"message":{"chat":{"id":$OWNER,"type":"private"},"from":{"id":$OWNER,"language_code":"ru"},"text":"/start"}},
 {"update_id":13,"message":{"chat":{"id":$OWNER,"type":"private"},"from":{"id":$OWNER,"language_code":"ru"},"text":"hey"}}]
EOF
STUB_403="$OWNER 555" STUB_UPDATES="$TMP/updates.json" run ada
sends=$(grep '^sendMessage ' "$TMP/calls.log" | cut -d' ' -f2-)
owner_sends=$(jq -s --arg o "$OWNER" '[.[] | select((.chat_id|tostring) == $o)] | length' <<<"$sends")
ru=$(jq -s -r --arg o "$OWNER" '[.[] | select((.chat_id|tostring) == $o)] | last | .text' <<<"$sends")
check "G6 the 403 owner is greeted after their first message: tried once, then once more" '[[ "$owner_sends" == 2 ]]' "$sends"
check "G6 in their language" '[[ "$ru" == "Здравствуйте, я Ada."* && "$ru" == *"Я запускаюсь"* ]]' "$ru"
check "G6 the peek never confirms an update (no offset in any getUpdates)" \
  '(( $(calls getUpdates) >= 1 )) && ! grep "^getUpdates " "$TMP/calls.log" | grep -q offset' "$(grep '^getUpdates ' "$TMP/calls.log")"
check "G6 the marker gains the chat greeted late" '[[ "$(jq -c .chats "$SEAT_DIR/connect-greeted.json")" == "[\"$OWNER\"]" ]]'
check "G8 a stranger (999) and the group are never greeted" \
  '! jq -s -e "map(.chat_id) | any(. == 999 or . == -100777)" <<<"$sends" >/dev/null'
check "G6 the owner still not seen (555) is never typed at" '! grep "^sendChatAction " "$TMP/calls.log" | grep -q "\"chat_id\":555"'

seat ada claude "{\"allowFrom\":[\"$OWNER\"]}"
STUB_403="$OWNER" STUB_PEEK_409=1 run ada
check "G7 a refused getUpdates stops the peeking (one call only)" '[[ "$(calls getUpdates)" == 1 ]]' "getUpdates calls: $(calls getUpdates)"

# ── G9-G10: who counts as an owner ───────────────────────────────────────────
seat ada claude '{"allowFrom":["111","-100222","abc"],"owners":["111","333"]}'
run ada
check "G9 owners ∩ allowFrom, positive ids only" \
  '[[ "$(grep "^sendMessage " "$TMP/calls.log" | cut -d" " -f2- | jq -s -c "map(.chat_id)")" == "[111]" ]]'
seat ada claude '{"allowFrom":[]}'
run ada
check "G10 no owner id: nothing is sent" '[[ ! -s "$TMP/calls.log" ]] && [[ "$(jq -c .greeted <<<"$OUT")" == "[]" ]]' "$OUT"

# ── G11: the persona ─────────────────────────────────────────────────────────
if command -v bun >/dev/null 2>&1; then
  seat ada claude "{\"allowFrom\":[\"$OWNER\"]}"
  mkdir -p "$AGENT_HOME_ROOT/agent-ada/.claude"
  printf 'name: Olivia\next:\n  "5dive":\n    welcome:\n      en: "Olivia here. What is the one goal?"\n' >"$AGENT_HOME_ROOT/agent-ada/.claude/persona.yaml"
  run ada
  t=$(grep -m1 '^sendMessage ' "$TMP/calls.log" | cut -d' ' -f2- | jq -r .text)
  check "G11 the pack's welcome replaces the greeting" \
    '[[ "$t" == $'"'"'Olivia here. What is the one goal?\n\nI\'"'"'m starting up, ready in about 30 seconds.'"'"' ]]' "$t"
  printf 'name: Olivia\n' >"$AGENT_HOME_ROOT/agent-ada/.claude/persona.yaml"
  rm -f "$TMP/calls.log"; run ada
  t=$(grep -m1 '^sendMessage ' "$TMP/calls.log" | cut -d' ' -f2- | jq -r .text)
  check "G11 the persona's name replaces the bot's" '[[ "$t" == "Hi, I'"'"'m Olivia."$'"'"'\n'"'"'"Olivia keeps the books."* ]]' "$t"
else
  printf 'skip - G11 (no bun on PATH)\n'
fi

# ── E1-E2: set -e and a dead network ─────────────────────────────────────────
seat ada claude "{\"allowFrom\":[\"$OWNER\"]}"
OUT=$( set -e; STUB_CURL_FAIL=all cmd_agent_tg_connect_greet ada 2>/dev/null ); rc=$?
check "E1 every call failing: the run still ends (rc 0, its JSON line, nobody greeted)" \
  '[[ $rc == 0 && "$(jq -c .greeted <<<"$OUT")" == "[]" ]]' "rc=$rc out=$OUT"
seat ada claude "{\"allowFrom\":[\"$OWNER\"]}"
OUT=$( set -e; STUB_403="$OWNER" STUB_CURL_FAIL=getUpdates cmd_agent_tg_connect_greet ada 2>/dev/null ); rc=$?
check "E2 the peek failing: the run still ends (rc 0, its JSON line)" \
  '[[ $rc == 0 && "$(jq -r .bridgeUp <<<"$OUT")" == false ]]' "rc=$rc out=$OUT"

# ── P1-P2: the markers are the seat's own writes ─────────────────────────────
seat ada claude "{\"allowFrom\":[\"$OWNER\"]}"
printf 'precious\n' >"$TMP/victim"; ln -s "$TMP/victim" "$SEAT_DIR/boot-greeted"
run ada
check "P2 a symlink planted at boot-greeted is replaced, its target untouched" \
  '[[ "$(cat "$TMP/victim")" == precious && ! -L "$SEAT_DIR/boot-greeted" && "$(cat "$SEAT_DIR/boot-greeted")" == 7000000001 ]]'
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$STUB_DIR/runuser.argv"\n[[ "$1" == -u && "$3" == -- ]] && shift 3\nexec "$@"\n' >"$TMP/bin/runuser"
chmod +x "$TMP/bin/runuser"
seat ada claude "{\"allowFrom\":[\"$OWNER\"]}"
( _tgcg_is_root() { return 0; }; run ada )
check "P1 as root, both marker writes go through runuser -u agent-ada" \
  '[[ "$(grep -c "^-u agent-ada -- sh -c" "$TMP/runuser.argv" 2>/dev/null)" == 2 ]]' "$(cat "$TMP/runuser.argv" 2>&1)"

# ── L1-L3: the launch ────────────────────────────────────────────────────────
# The harness is not root and must not become it: the seam says root.
_tgcg_is_root() { return 0; }
rm -f "$TMP/sdrun.argv"
_tg_connect_greet_launch ada claude >/dev/null 2>&1
check "L1 systemd-run starts unit 5dive-tg-greet-ada running 'agent _tg_connect_greet ada'" \
  'grep -qx -- "--unit=5dive-tg-greet-ada" "$TMP/sdrun.argv" && tr "\n" " " <"$TMP/sdrun.argv" | grep -q -- "-- /usr/local/bin/5dive agent _tg_connect_greet ada "' "$(cat "$TMP/sdrun.argv" 2>&1)"
rm -f "$TMP/sdrun.argv"
for t in openclaw hermes; do _tg_connect_greet_launch ada "$t" >/dev/null 2>&1; done
check "L2 openclaw and hermes are not launched (their gateway answers at once)" '[[ ! -e "$TMP/sdrun.argv" ]]'
FIVE_TG_CONNECT_GREET=0 _tg_connect_greet_launch ada codex >/dev/null 2>&1
check "L3 FIVE_TG_CONNECT_GREET=0 turns it off" '[[ ! -e "$TMP/sdrun.argv" ]]'
_tg_connect_greet_launch ada codex >/dev/null 2>&1
check "L3 positive control: the same codex launch with the switch on does start a unit" '[[ -s "$TMP/sdrun.argv" ]]'

# ── W1-W4: wiring ────────────────────────────────────────────────────────────
check "W1 main.sh dispatches _tg_connect_greet" \
  'grep -A2 "^ *_tg_connect_greet)" src/main.sh | grep -q "cmd_agent_tg_connect_greet"'
check "W2 build.sh loads the module" 'grep -qx "  src/cmd_tg_connect_greet.sh" build.sh'
cfg=$(grep -B3 -A1 '_tg_connect_greet_launch' src/cmd_agent_config.sh)
check "W3 config set launches on a first attach with a new token only" \
  '[[ "$cfg" == *"-n \"\$new_telegram_token\""* && "$cfg" == *"! channel_in_list telegram \"\$prev_channels\""* ]]' "$cfg"
l_launch=$(grep -n '_tg_connect_greet_launch' src/cmd_agent_create.sh | head -1 | cut -d: -f1)
l_enable=$(grep -n 'systemctl enable --now "5dive-agent@' src/cmd_agent_create.sh | head -1 | cut -d: -f1)
check "W4 create launches it before the seat starts" '[[ -n "$l_launch" && -n "$l_enable" ]] && (( l_launch < l_enable ))'

# ── negative controls ────────────────────────────────────────────────────────
nc() { # <label> <sed-expr> <arm-fn> <predicate>
  local copy="$TMP/nc.sh"
  sed "$2" "$MOD" >"$copy"
  if cmp -s "$copy" "$MOD"; then bad_t "$1" "the mutation did not apply"; return; fi
  # Not on the left of && / ||: that context switches set -e off for everything
  # inside it, nested `set -e` included, and E1's mutant would pass vacuously.
  local r
  ( load "$copy"; export PATH; $3; eval "$4" ); r=$?
  if (( r == 0 )); then bad_t "$1" "the mutated copy PASSED the arm"; else ok_t "$1"; fi
}
nc "NC1 a copy without the bridge-up stop is CAUGHT by G5" \
  '/_tgcg_bridge_up "\$dir" "\$started_s" && break$/d' g5 \
  '[[ "$(jq -r .bridgeUp <<<"$OUT")" == true ]] && (( G5_SECS < 4 )) && [[ "$(calls sendChatAction)" == 2 ]]'
nc6() {
  seat ada claude "{\"allowFrom\":[\"$OWNER\"]}"
  STUB_403="$OWNER" STUB_UPDATES="$TMP/updates.json" run ada
}
nc "NC2 a copy whose peek confirms updates is CAUGHT by G6" \
  's/{"timeout":0,"limit":100}/{"timeout":0,"limit":100,"offset":-1}/' nc6 \
  '! grep "^getUpdates " "$TMP/calls.log" | grep -q offset'

e1() {
  seat ada claude "{\"allowFrom\":[\"$OWNER\"]}"
  OUT=$( set -e; STUB_CURL_FAIL=all cmd_agent_tg_connect_greet ada 2>/dev/null ); rc=$?
}
nc "NC3 a copy without the getMe guard is CAUGHT by E1 (set -e kills the run)" \
  's/  me=$(_tgcg_call "$token" getMe) || me=""/  me=$(_tgcg_call "$token" getMe)/' e1 \
  '[[ $rc == 0 && "$(jq -c .greeted <<<"$OUT")" == "[]" ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
