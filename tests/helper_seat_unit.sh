#!/usr/bin/env bash
# DIVE-8819 isolated unit harness for the 5dive helper seat (src/cmd_helper.sh):
#   1. outside the agent count: the seat is marked system=helper, `agent list
#      --json` carries that field from both builders, and the hire count skips it;
#   2. the welcome goes out ONCE: a second tick, a seat restart and a failed
#      post that is retried never produce a second message;
#   3. the handover read: 200 skips the question and names the business, 404
#      asks it, any other answer retries and asks only after the tries run out;
#   4. which boxes: no demo AI = nothing; DIVE-8946: no box gets a new seat;
#      an owner's own agent named `helper` is left alone;
#   5-8. the persona; the greeted claim against a racing tick; a half-built seat
#      is left as it is, never a hire; --help exits 0.
#   9-11. DIVE-8850: the BOX posts the welcome into the app as the helper (no
#      notice, no model in the path); a 0.138.0 box with `greeted` and no reply
#      from its seat is welcomed once, one whose seat did reply is not; a sealed
#      chat gets it sealed as the helper.
#   13. DIVE-8946: with no seat built, the pre-sale handover goes to the owner's
#      FIRST hire, once (a marked block in its instructions + one notice); 404,
#      an API that stays down, an old first hire: nothing given, recorded once.
# Throwaway STATE_DIR and fake 5dive / systemd-run / curl on PATH: no root, no
# network, nothing on the live box is touched.
# Run: bash tests/helper_seat_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
SRC=src
TMP="$(mktemp -d /tmp/helper-seat-unit.XXXXXX)"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/registry.sh cmd_helper.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   want: %s\n   got:  %s\n' "$1" "$2" "$3"; fi; }
has() { if grep -qF -- "$2" <<<"$3"; then t "$1" yes yes; else t "$1" "contains [$2]" "$3"; fi; }
hasnt() { if grep -qiF -- "$2" <<<"$3"; then t "$1" "no [$2]" "$3"; else t "$1" yes yes; fi; }

# --- fakes -------------------------------------------------------------------
FAKE="$TMP/bin"; mkdir -p "$FAKE"
CALLS="$TMP/calls.log"; : >"$CALLS"
cat >"$FAKE/5dive" <<'EOF'
#!/usr/bin/env bash
printf '5dive %s\n' "$*" >>"$CALLS"
exit 0
EOF
cat >"$FAKE/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf 'systemd-run %s\n' "$*" >>"$CALLS"
EOF
# curl: answers FAKE_HTTP with FAKE_BODY written to the -o file.
cat >"$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == -o ]] && out="$a"; prev="$a"; done
cat >/dev/null   # the bearer header on stdin
for a in "$@"; do [[ "$a" == http* ]] && printf 'curl %s\n' "$a" >>"$CALLS"; done
[[ -n "$out" ]] && printf '%s' "${FAKE_BODY:-}" >"$out"
printf '%s' "${FAKE_HTTP:-000}"
EOF
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH" CALLS
export FIVEDIVE_SELF_BIN="$FAKE/5dive" CONNECTORD_TOKEN="box-token-fixture"
_partner_box_token() { printf '%s' "$CONNECTORD_TOKEN"; }
_partner_api_base() { printf 'https://api.example.test'; }
RUNNING=1
_helper_running() { (( RUNNING )); }
# The app rail: one line per post into $CALLS. FAKE_POST_CODE answers a plain
# post, FAKE_SEALED_CODE a sealed one.
_dash_relay_token() { printf 'box-token-fixture'; }
_dash_relay_api_base() { printf 'https://api.example.test'; }
_dash_relay_call() {
  printf 'post %s %s\n' "$2" "$3" >>"$CALLS"
  if jq -e '.metadata.e2e' <<<"$3" >/dev/null 2>&1; then printf '%s\n{}' "${FAKE_SEALED_CODE:-200}"
  else printf '%s\n{}' "${FAKE_POST_CODE:-200}"; fi
}
_chat_e2e_live() { printf '%s' "$STATE_DIR/chat-e2e"; }
_chat_e2e_run() { local req; req=$(cat); printf 'seal %s as=%s %s\n' "$1" "$4" "$req" >>"$CALLS"; printf '{"env":{"h":{"c":"dashboard"},"sealed":true}}'; }
HELPER_SEAT_HOME="$TMP/seat-home"

fresh() {   # a new box: state dir, registry, optional demo AI account
  STATE_DIR="$TMP/box$1"; HELPER_STATE_DIR="$STATE_DIR"
  AUTH_PROFILES_DIR="$STATE_DIR/auth-profiles"; REGISTRY="$STATE_DIR/registry.json"
  mkdir -p "$STATE_DIR"
  if [[ "${2:-demo}" == demo ]]; then
    mkdir -p "$AUTH_PROFILES_DIR/demo-ai"
    printf 'ANTHROPIC_AUTH_TOKEN=sk-or-v1-fixture\n' >"$AUTH_PROFILES_DIR/demo-ai/combined.env"
  fi
  : >"$CALLS"; rm -rf "$HELPER_SEAT_HOME"
}
reg_with() { printf '{"agents":%s}' "$1"; }
built() { mkdir -p "$STATE_DIR/helper"; date >"$STATE_DIR/helper/built"; echo "$HELPER_PERSONA_REV" >"$STATE_DIR/helper/persona-rev"; }
HELPER_ROW='"helper":{"type":"claude","system":"helper"}'
HIRE_ROW='"theo":{"type":"claude"}'
n_calls() { grep -c -- "$1" "$CALLS"; }

echo '== 1. outside the agent count =='
t 'the helper seat reads as mine' mine "$(_helper_seat "$(reg_with "{$HELPER_ROW}")")"
t "an owner's own agent named helper is taken" taken "$(_helper_seat "$(reg_with '{"helper":{"type":"claude"}}')")"
t 'no seat yet' none "$(_helper_seat "$(reg_with "{$HIRE_ROW}")")"
t 'hires skip the helper seat' 1 "$(_helper_hires "$(reg_with "{$HELPER_ROW,$HIRE_ROW}")")"
t 'hires skip the partner sysadmin seat' 0 "$(_helper_hires "$(reg_with '{"sysadmin":{"type":"claude"}}')")"
t 'a box with only the helper has no hires' 0 "$(_helper_hires "$(reg_with "{$HELPER_ROW}")")"
# Both `agent list --json` builders carry the marker the API and app filter on.
t 'the jq list builder reports system' 1 "$(grep -c 'system: (.value.system // null),' src/cmd_agent.sh)"
t 'the snapshot list builder reports system' 1 "$(grep -c '"system": value.get("system"),' src/cmd_agent.sh)"
# The team export (cloud copy's source) leaves the box's system seats out.
t 'the team export skips system seats' 1 "$(grep -c "select((.value.system // \"\") == \"\") | .key' <<<\"\$reg\"" src/cmd_compose.sh)"

echo '== 2. which boxes =='
fresh 2 none
t 'no demo AI: the tick does nothing' '' "$(_helper_tick "$(reg_with '{}')")"
t 'no demo AI: nothing built' 0 "$(n_calls systemd-run)"
# DIVE-8946: no box gets a new seat, from the tick or from ensure.
fresh 3
out=$(_helper_tick "$(reg_with '{}')")
t 'a demo AI box with no seat: the tick builds nothing' '' "$out"
t 'no build unit, no agent create' 0 "$(n_calls 'systemd-run\|agent create')"
t 'the module never creates an agent' 0 "$(grep -c 'agent create' src/cmd_helper.sh)"
t 'nor starts a build unit' 0 "$(grep -c 'systemd-run' src/cmd_helper.sh)"
fresh 4; mkdir -p "$STATE_DIR/helper"; date >"$STATE_DIR/helper/built"; date >"$STATE_DIR/helper/welcomed"
_helper_tick "$(reg_with "{$HIRE_ROW}")" >/dev/null
t 'a seat the owner removed is not built again' 0 "$(n_calls 'systemd-run\|agent create')"
fresh 5; built
_helper_tick "$(reg_with '{"helper":{"type":"claude"},'"$HIRE_ROW"'}')" >/dev/null
t "an owner's own helper agent is left alone" 0 "$(n_calls '5dive\|systemd-run\|curl')"

echo '== 3. the welcome waits for an owner, then goes out once =='
fresh 7; built; FAKE_HTTP=404
_helper_tick "$(reg_with "{$HELPER_ROW}")" >/dev/null
t 'no hire yet (an unclaimed spare): no welcome' 0 "$(n_calls '^post')"
RUNNING=0; _helper_tick "$(reg_with "{$HELPER_ROW,$HIRE_ROW}")" >/dev/null; RUNNING=1
t 'seat not running: no welcome' 0 "$(n_calls '^post')"
REG="$(reg_with "{$HELPER_ROW,$HIRE_ROW}")"
FAKE_HTTP=404 FAKE_BODY='{"error":"none"}' _helper_tick "$REG" >/dev/null
FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
t 'two ticks: one welcome' 1 "$(n_calls '^post https://api.example.test/server/messages/event')"
t 'posted as the helper' helper "$(sed -n 's/^post [^ ]* //p' "$CALLS" | jq -r .agent)"
t 'with the one retry key' helper-welcome "$(sed -n 's/^post [^ ]* //p' "$CALLS" | jq -r .metadata.reply_key)"
t 'the seat is handed no notice (no model in the path)' 0 "$(n_calls '_deliver')"
# A seat restart changes nothing on disk the greeting reads; the box restart
# (STATE_DIR persists) neither.
FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
t 'after a restart: still one welcome' 1 "$(n_calls '^post')"
t 'welcomed is recorded' yes "$([[ -s "$STATE_DIR/helper/welcomed" ]] && echo yes)"
t 'once welcomed, the tick reads nothing' 0 "$(n_calls curl | awk '{print ($1>2)?1:0}')"
fresh 8; built; REG="$(reg_with "{$HELPER_ROW,$HIRE_ROW}")"
FAKE_POST_CODE=502 FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
t 'a refused post leaves no welcomed mark' no "$([[ -e "$STATE_DIR/helper/welcomed" ]] && echo yes || echo no)"
FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
t 'the retry posts it, once' 2 "$(n_calls '^post')"
t 'welcomed after the retry' yes "$([[ -e "$STATE_DIR/helper/welcomed" ]] && echo yes)"

echo '== 4. the handover read =='
fresh 9; built; REG="$(reg_with "{$HELPER_ROW,$HIRE_ROW}")"
FAKE_HTTP=200 FAKE_BODY='{"business":"a bakery\nin Lyon","suggested":["theo","dude","x y"],"asked_at":"2026-11-19T10:00:00Z"}' \
  _helper_tick "$REG" >/dev/null
msg=$(sed -n 's/^post [^ ]* //p' "$CALLS" | jq -r .body)
has 'reads GET /helper/handover' 'https://api.example.test/helper/handover' "$(cat "$CALLS")"
has '200: names the business' 'For your business (a bakery in Lyon)' "$msg"
has '200: names at most two clean suggestions' 'a good first hire is Theo or Dude:' "$msg"
hasnt '200: does not ask the question' 'what does your business do' "$msg"
t '200: the whole welcome' "Hi, I'm 5dive, your helper on this server. For your business (a bakery in Lyon), a good first hire is Theo or Dude: find them on the Hire screen. Ask me anything about setting up." "$msg"
fresh 10; built; FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
msg=$(sed -n 's/^post [^ ]* //p' "$CALLS" | jq -r .body)
t '404: asks the one question' "Hi, I'm 5dive, your helper on this server. I help you set up 5dive and choose your agents. What does your business do?" "$msg"
t 'the welcome is at most 40 words' yes "$( (( $(wc -w <<<"$msg") <= 40 )) && echo yes)"
fresh 15; built; FAKE_HTTP=200 FAKE_BODY='{"business":"a bakery","suggested":[]}' _helper_tick "$REG" >/dev/null
has '200 with no suggestion: offers to suggest' "You told me about your business: a bakery. Tell me what you want done first" "$(sed -n 's/^post [^ ]* //p' "$CALLS" | jq -r .body)"
long=$(printf 'x%.0s' {1..300})
has 'a long business is clipped' "(${long:0:119}…)" "$(_helper_greeting "$long" 'theo')"
fresh 11; built; HELPER_HANDOVER_TRIES=3
for i in 1 2; do FAKE_HTTP=503 _helper_tick "$REG" >/dev/null; done
t 'API down: no welcome while tries remain' 0 "$(n_calls '^post')"
FAKE_HTTP=503 _helper_tick "$REG" >/dev/null
t 'API down past the tries: one welcome' 1 "$(n_calls '^post')"
has 'API down past the tries: it asks' 'What does your business do?' "$(sed -n 's/^post [^ ]* //p' "$CALLS" | jq -r .body)"
HELPER_HANDOVER_TRIES=12

echo '== 5. what the seat is =='
p=$(_helper_persona)
has 'never takes a job' 'Never take a job, never claim one, and never say "On it"' "$p"
has 'never builds or edits agents' 'Never build, edit, restart or remove agents' "$p"
has 'how-to in two lines' 'in at most two short lines' "$p"
# DIVE-8898: the how-to lines name the app's real labels (pinned to the app by
# 5dive-frontend src/lib/helper-howto.test.ts), never a Model row or the old plane icon.
for l in '"My team", tap "Add your AI subscription"' 'under "Runs on", tap "Add AI subscription"' \
         'tap "Connect Telegram"' 'open "Settings", then "Tools"' 'tap "Hire", then "Hire"' \
         '"Create your own agent"' 'under "Plan", tap "Manage billing"' '"Manage on the website"'; do
  has "how-to names $l" "$l" "$p"
done
hasnt 'never names Model' 'Model' "$p"
hasnt 'no plane icon' 'plane icon' "$p"
t 'the persona is one marked block' "$HELPER_PERSONA_BEGIN|$HELPER_PERSONA_END" "$(head -n1 <<<"$p")|$(tail -n1 <<<"$p")"
has 'knows 5dive sent its welcome' 'Never send another welcome' "$p"
for g in "$(_helper_greeting '' '')" "$(_helper_greeting 'a bakery' 'theo')"; do
  hasnt 'no greeting says On it' 'on it' "$g"
  hasnt 'no greeting says it messaged first' 'messaged you first' "$g"
done

echo '== 6. the welcomed claim holds against a second sender =='
# A tick that read the handover, then lost the race: another tick already wrote
# welcomed. noclobber makes the claim fail, so this one posts nothing.
fresh 12; built; mkdir -p "$STATE_DIR/helper"; echo 'claimed by the other tick' >"$STATE_DIR/helper/welcomed"
FAKE_HTTP=404 _helper_greet >/dev/null
t 'a claim already taken: no second post' 0 "$(n_calls '^post')"
t 'the other claim is left as it was' 'claimed by the other tick' "$(cat "$STATE_DIR/helper/welcomed")"

echo '== 7. a half-built seat (0.139.x) is left as it is, and is not a hire =='
# agent create wrote the row and the mark, then the persona step failed: no built.
fresh 13; REG='{"agents":{"helper":{"type":"claude","system":"helper"}}}'
t 'it reads mine, not taken' mine "$(_helper_seat "$REG")"
t 'and it is not a hire' 0 "$(_helper_hires "$REG")"
out=$(FAKE_HTTP=404 _helper_tick "$REG")
t 'the tick does not finish the build' 0 "$(n_calls 'agent create\|systemd-run\|persona')"
t 'nor welcome from it' 0 "$(n_calls '^post')"

echo '== 8. --help =='
for h in --help -h help; do
  out=$(cmd_helper "$h" 2>&1); rc=$?
  t "helper $h exits 0" 0 "$rc"
  has "helper $h prints the usage line" 'usage: 5dive helper ensure|status' "$out"
done
t 'the usage line is what _verb_own_usage reads' 'usage: 5dive helper ensure|status [--json]' \
  "$(_verb_own_usage cmd_helper '5dive helper ensure|status')"
t 'helper is a builtin verb (plugins cannot claim it)' 1 \
  "$(grep '^readonly FIVEDIVE_BUILTIN_VERBS=' src/cmd_plugin.sh | grep -c ' helper ')"

echo '== 9. a 0.138.0 box: greeted, but did the seat reply? =='
REG="$(reg_with "{$HELPER_ROW,$HIRE_ROW}")"
transcript() { mkdir -p "$HELPER_SEAT_HOME/.claude/projects/-home-agent-helper"; printf '%s\n' "$1" >"$HELPER_SEAT_HOME/.claude/projects/-home-agent-helper/s.jsonl"; }
# Hetzner, row 664: the seat answered in its terminal, no reply-tool call.
fresh 16; built; echo '2026-11-20T01:05:02Z' >"$STATE_DIR/helper/greeted"
transcript '{"type":"assistant","message":{"content":[{"type":"text","text":"I'"'"'m 5dive. What does your business do?"}]}}'
FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
t 'no reply from the seat: the box welcomes the owner' 1 "$(n_calls '^post')"
FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
t 'then never again' 1 "$(n_calls '^post')"
# OVH, row 666: the seat called the reply tool (app message 4000).
fresh 17; built; echo '2026-11-20T01:27:58Z' >"$STATE_DIR/helper/greeted"
transcript '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"mcp__plugin_dashboard_dashboard__reply","input":{"chat_id":"dashboard","text":"Hi, I'"'"'m 5dive"}}]}}'
out=$(FAKE_HTTP=404 _helper_tick "$REG")
t 'the seat already replied: no second welcome' 0 "$(n_calls '^post')"
has 'and says why' 'already wrote to the owner' "$out"
t 'it is recorded, so the transcript is read once' yes "$([[ -s "$STATE_DIR/helper/welcomed" ]] && echo yes)"
t 'and the handover is not read' 0 "$(n_calls curl)"
rm -rf "$HELPER_SEAT_HOME"; FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
t 'a later tick does nothing' 0 "$(n_calls '^post')"

echo '== 10. a sealed chat gets it sealed, as the helper =='
fresh 18; built; mkdir -p "$STATE_DIR/chat-e2e"; echo '{}' >"$STATE_DIR/chat-e2e/box.jwk"
FAKE_POST_CODE=409 FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
t 'plain refused, then one sealed post' 2 "$(n_calls '^post')"
sealed=$(sed -n 's/^post [^ ]* //p' "$CALLS" | tail -n 1)
t 'the sealed post is e2e, in the DM conversation, with the key' 'dashboard|1|helper-welcome|helper' \
  "$(jq -r '"\(.metadata.chat_id)|\(.metadata.e2e.v)|\(.metadata.reply_key)|\(.agent)"' <<<"$sealed")"
has 'root seals it as the helper, for dashboard' 'as=helper {"op":"seal","conv":"dashboard","m":"b-helper-welcome"' "$(cat "$CALLS")"
t 'welcomed' yes "$([[ -s "$STATE_DIR/helper/welcomed" ]] && echo yes)"
fresh 19; built
FAKE_POST_CODE=409 FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
t 'sealed chat but no box key here: no welcomed mark, retried next tick' no "$([[ -e "$STATE_DIR/helper/welcomed" ]] && echo yes || echo no)"
t 'and nothing sealed' 0 "$(n_calls '^seal')"

echo '== 11. no notice reaches the seat =='
t 'the module never hands the seat the welcome' 0 "$(grep -c 'system-notice "$HELPER_AGENT"' src/cmd_helper.sh)"
t 'its one notice goes to the first hire' 1 "$(grep -c 'system-notice "$lead"' src/cmd_helper.sh)"

echo '== 12. a built seat gets the new how-to lines once (DIVE-8898) =='
SEAT_MD="$TMP/seat-md/CLAUDE.md"
persona_target() { printf '%s' "$SEAT_MD"; }
install() { local src="${@: -2:1}" dst="${@: -1}"; cp "$src" "$dst"; }   # no chown in the harness
old_persona() {   # what 0.139.x installed: unmarked, with the plane icon line
  printf '%s\n' '# You are 5dive: Help & setup' '' 'What you do:' \
    '- Telegram: the owner connects any agent, you too, by tapping the plane icon next to it in My team.' '' \
    'What you never do:' '- Never say you messaged them first, and never talk about AI budgets, keys or limits.'
}
fresh 20; mkdir -p "$STATE_DIR/helper" "$(dirname "$SEAT_MD")"; date >"$STATE_DIR/helper/built"; date >"$STATE_DIR/helper/welcomed"
{ old_persona; printf '\n%s\n' '# Base seat notes' 'kept line'; } >"$SEAT_MD"
out=$(_helper_tick "$REG")
md=$(cat "$SEAT_MD")
has 'a welcomed seat on rev 1 is refreshed' 'new how-to lines' "$out"
has 'it now names Add your AI subscription' 'tap "Add your AI subscription"' "$md"
hasnt 'the plane icon line is gone' 'plane icon' "$md"
t 'the old block is gone, not doubled' 1 "$(grep -c '^# You are 5dive: Help & setup' <<<"$md")"
has 'what was below the persona stays' 'kept line' "$md"
t 'the rev is written' "$HELPER_PERSONA_REV" "$(cat "$STATE_DIR/helper/persona-rev")"
t 'the seat is restarted once' 1 "$(n_calls 'agent restart helper')"
: >"$CALLS"; _helper_tick "$REG" >/dev/null
t 'the next tick leaves it alone' 0 "$(n_calls 'agent restart')"
# rev 2 -> rev 3: the marked block is swapped, the notes below stay, no doubling
HELPER_PERSONA_REV=3; _helper_tick "$REG" >/dev/null; HELPER_PERSONA_REV=2
md=$(cat "$SEAT_MD")
t 'a marked block is replaced, not doubled' 1 "$(grep -cF "$HELPER_PERSONA_BEGIN" <<<"$md")"
has 'and the notes below it stay' 'kept line' "$md"
t 'with exactly one blank line before them' '' "$(grep -B1 '^# Base seat notes' <<<"$md" | head -n1)"
# a seat the owner removed, or their own agent named helper: never touched
fresh 21; mkdir -p "$STATE_DIR/helper" "$(dirname "$SEAT_MD")"; date >"$STATE_DIR/helper/built"
old_persona >"$SEAT_MD"
_helper_tick "$(reg_with "{$HIRE_ROW}")" >/dev/null
has 'a removed seat: its file is not rewritten' 'plane icon' "$(cat "$SEAT_MD")"
t 'and the tick stops asking' "$HELPER_PERSONA_REV" "$(cat "$STATE_DIR/helper/persona-rev")"
unset -f persona_target install

echo '== 13. no seat: the handover goes to the first hire, once (DIVE-8946) =='
LEAD_DIR="$TMP/lead"
persona_target() { printf '%s/%s-%s.md' "$LEAD_DIR" "$1" "$2"; }
now=$(date -Iseconds); old=$(date -Iseconds -d '-10 days'); earlier=$(date -Iseconds -d '-1 hour')
REG=$(reg_with '{"sysadmin":{"type":"claude","createdAt":"'"$old"'"},"theo":{"type":"claude","createdAt":"'"$now"'"},"dude":{"type":"codex","createdAt":"'"$earlier"'"}}')
HANDOVER='{"business":"a bakery <!-- x --> in Lyon","suggested":["theo","dude"],"asked_at":"2026-11-21T10:00:00Z"}'
fresh 30; rm -rf "$LEAD_DIR"
out=$(FAKE_HTTP=200 FAKE_BODY="$HANDOVER" _helper_tick "$REG")
has 'it says what it did' 'gave the handover to the first hire dude' "$out"
t 'the first hire is the earliest, never sysadmin' 1 "$(ls "$LEAD_DIR" 2>/dev/null | grep -c '^dude-codex.md$')"
md=$(cat "$LEAD_DIR/dude-codex.md" 2>/dev/null)
has 'its instructions name the business' 'told 5dive about their business: a bakery !-- x -- in Lyon' "$md"
has 'and the suggested hires' '5dive suggested they hire Theo and Dude.' "$md"
has 'and say never to ask again' 'never ask them what their business does' "$md"
t 'one marked block' "$HELPER_LEAD_BEGIN|$HELPER_LEAD_END" "$(head -n1 <<<"$md")|$(tail -n1 <<<"$md")"
has 'the running session gets one notice' '5dive agent _deliver --system-notice dude 5dive: before buying' "$(cat "$CALLS")"
t 'one notice' 1 "$(n_calls '_deliver')"
t 'nothing posted as a helper, no seat built' 0 "$(n_calls '^post\|agent create\|systemd-run')"
t 'recorded' yes "$(grep -q 'to dude' "$STATE_DIR/helper/handed-over" && echo yes)"
has 'status says done' 'handover=done' "$(cmd_helper_status 2>&1)"
: >"$CALLS"; FAKE_HTTP=200 FAKE_BODY="$HANDOVER" _helper_tick "$REG" >/dev/null
t 'a second tick reads and sends nothing' 0 "$(n_calls 'curl\|_deliver')"
t 'the block is not doubled' 1 "$(grep -cF "$HELPER_LEAD_BEGIN" "$LEAD_DIR/dude-codex.md")"
# The block goes under what the file already holds, which stays.
fresh 31; rm -rf "$LEAD_DIR"; mkdir -p "$LEAD_DIR"; printf '# Theo\nkept line\n' >"$LEAD_DIR/theo-claude.md"
FAKE_HTTP=200 FAKE_BODY='{"business":"a bakery","suggested":[]}' _helper_tick "$(reg_with '{"theo":{"type":"claude","createdAt":"'"$now"'"}}')" >/dev/null
md=$(cat "$LEAD_DIR/theo-claude.md")
t 'the file keeps its own lines first' '# Theo|kept line' "$(sed -n 1,2p <<<"$md" | paste -sd'|')"
has 'then the block' "$HELPER_LEAD_BEGIN" "$md"
hasnt 'no suggestion: no suggested line' 'suggested they hire' "$md"
fresh 32; rm -rf "$LEAD_DIR"
FAKE_HTTP=200 FAKE_BODY="$HANDOVER" _helper_tick "$(reg_with '{}')" >/dev/null
t 'no hire yet (an unclaimed spare): nothing read' 0 "$(n_calls curl)"
t 'and not recorded, so the first hire still gets it' no "$([[ -e "$STATE_DIR/helper/handed-over" ]] && echo yes || echo no)"
fresh 33; FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
t '404 (told 5dive nothing): no notice' 0 "$(n_calls '_deliver')"
t '404: recorded once' yes "$(grep -q nothing "$STATE_DIR/helper/handed-over" && echo yes)"
fresh 34; HELPER_HANDOVER_TRIES=3
for i in 1 2; do FAKE_HTTP=503 _helper_tick "$REG" >/dev/null; done
t 'API down: not recorded while tries remain' no "$([[ -e "$STATE_DIR/helper/handed-over" ]] && echo yes || echo no)"
FAKE_HTTP=503 _helper_tick "$REG" >/dev/null
t 'API down past the tries: recorded, nothing sent' 'yes|0' "$(grep -q 'gave up' "$STATE_DIR/helper/handed-over" && echo yes)|$(n_calls '_deliver')"
HELPER_HANDOVER_TRIES=12
fresh 35; FAKE_HTTP=200 FAKE_BODY="$HANDOVER" _helper_tick "$(reg_with '{"theo":{"type":"claude","createdAt":"'"$old"'"}}')" >/dev/null
t 'a first hire 10 days old (an old box): nothing read or sent' 0 "$(n_calls 'curl\|_deliver')"
t 'and recorded as skipped' yes "$(grep -q skipped "$STATE_DIR/helper/handed-over" && echo yes)"
fresh 36 none; FAKE_HTTP=200 FAKE_BODY="$HANDOVER" _helper_tick "$REG" >/dev/null
t 'no demo AI (self-hosted, partner): nothing' 0 "$(n_calls 'curl\|_deliver')"
fresh 37; built; FAKE_HTTP=200 FAKE_BODY="$HANDOVER" _helper_tick "$(reg_with "{$HELPER_ROW,$HIRE_ROW}")" >/dev/null
t 'a box with a built seat: its welcome, not a second handover' '1|0' "$(n_calls '^post')|$(n_calls '_deliver')"
out=$(require_root() { :; }; cmd_helper_ensure 2>&1)
has 'ensure no longer builds' 'new boxes get none' "$out"
unset -f persona_target

echo "pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
