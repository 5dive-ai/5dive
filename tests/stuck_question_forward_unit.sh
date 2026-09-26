#!/usr/bin/env bash
# An agent's unanswered question reaches a person when its seat has no channel.
#
# THE DEFECT (measured 2026-09-26 on 0.54.0): a seat with no paired channel that
# ends its turn on a question waits forever — nothing in 5dive reads what an agent
# asks. marcus (no channel) ended its turn at 01:16:44Z with the question in
# MARCUS_Q below; no person saw it, and 16 seats stayed deaf on Telegram until an
# outside restart at 02:06Z. `_hb_stuck_question_sweep` forwards such a question
# to a person: a local base tier on every box, sharpened by reflex only where the
# owner opted in.
#
# Arms (the letters in brackets are the row's):
#   P  preconditions: the reader returns an ended turn's text, and the base tier
#      says yes to MARCUS_Q and no to a plain report
#   G  [g] no reflex configured: the base forwards MARCUS_Q, once, through the
#      gate notifier's bot, in the row's form; no reflex call
#   B  [b] the same text on the next tick is not forwarded again, even when the
#      transcript is touched
#   E  [e] not opted in (a key alone, no reflex model): no reflex call at all
#   A  [a] opted in, asks_human 0.95: one forward, one call, text-only state
#   C  [c] asks_human 0.6: receipt, no forward
#   H  [h] a rhetorical '?': the base forwards it; the reflex tier suppresses it
#   I  [i] reflex timing out or erroring: the base verdict stands (fail open)
#   D  [d] a seat WITH a channel: no call, no forward
#   F  [f] no receipt carries any of the seat's text
#   N  scope: a turn still running, an inactive unit, and a newer headless
#      (distiller) transcript that must be walked past
#   R  routing: an unpaired notifier falls to the nearest paired seat up the chain;
#      nobody paired means logged, not sent
#   S  a send that fails (0 chats confirmed) is retried on a later tick, transcript
#      untouched or touched, and stops once one lands; a retry does not ask reflex
#      again
#   U  nobody paired yet, then the gate notifier paired: the next tick delivers
#   K  backoff: a seat that stays undeliverable is retried and logged on a
#      doubling delay, not every tick; a new text from the seat replaces the
#      pending one
#   W  the tick runs the sweep
#   L  LIVE BOX: this box's own transcripts (read-only) have the record shape the
#      reader keys on; SKIP on a runner that has none. CONTROL: no seat home at all
#   M  MUTANT: the sweep that never looks at a channel-less seat, and the one that
#      forgets the text it judged, turn G and B red; the one that marks the text
#      judged BEFORE the send (the iteration-1 defect) turns S and U red
#
# Stubs: systemctl, _tg_access_state_dir (channel dirs into the temp tree),
# _gate_channel_api (the Bot API seam), _reflex_endpoint_decide (the model),
# _hb_log. No root, no network, no box path written.
#
#   bash tests/stuck_question_forward_unit.sh
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
SRC=src

TMP="$(mktemp -d "${TMPDIR:-/tmp}/stuck-question.XXXXXX")"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/routing_receipt.sh lib/reflex.sh \
         cmd_task.sh cmd_org.sh cmd_project.sh cmd_agent_pairing.sh \
         cmd_supervisor.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e
LIVE_HOME="${HOME:-}"

STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
REGISTRY="$STATE_DIR/agents.json"; CONNECTORS_DIR="$TMP/connectors"; JSON_MODE=0
unset BOX_CONFIG FIVEDIVE_REFLEX_RECEIPTS FIVEDIVE_REFLEX_SHADOW FIVEDIVE_REFLEX_SHADOW_BACKEND
FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE="$TMP/reflex.key"; _REFLEX_BOX_RECEIPTS=""
_HB_SEAT_HOME_ROOT="$TMP/home"
mkdir -p "$TASKS_DIR" "$CONNECTORS_DIR"; tasks_db_init >/dev/null 2>&1

PASS=0; FAIL=0; SKIP=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
skip_t() { SKIP=$((SKIP+1)); printf 'skip - %s\n' "$1"; }
has()    { [[ "$1" == *"$2"* ]]; }

# --- The texts ------------------------------------------------------------------
# MARCUS_Q is the incident's turn, verbatim from marcus's transcript
# (be3e7e0a…, 2026-09-26T01:16:44.073Z). RHETORICAL is the final paragraph of a
# real marcus turn that asks nobody anything but quotes a question; REPORT is a
# real marcus turn with no ask. ASK_BURIED is the phrase-only ask the row quotes
# from the reflex model test.
MARCUS_Q="I haven't restarted anything. The Telegram poller really is down on all 16 seats: none of them has a Telegram process, only the dashboard one. After the 01:12 fleet restart, the Telegram plugin never started on any seat. It updated to 0.5.64 at 01:01, and that version builds without errors.

Should I restart claude-swan on its own as a test? If Telegram still doesn't start there, the problem is the plugin, and restarting the other 15 won't help."
RHETORICAL='One judgement call worth flagging: the brief says "No merge gate after delivery." I read that as forbidding a "merge it now?" ask, not a hold nobody on this box can discharge — and said so in the message to claude-luca, offering to withdraw it if they disagree. `task done` was not attempted: it is refused while the PR is open, and a refused close silently discards the recorded result.'
REPORT="I haven't started DIVE-613 and won't in this session. This turn's goal was DIVE-611 only, and that row is delivered.

DIVE-613 is assigned to me as \`todo\` and gets picked up when its own goal dispatches. I sent claude-luca a message saying so, along with DIVE-611's delivery (PR #1141 at \`dd030369\`, now waiting on claude-qa)."
ASK_BURIED="Before I do the same on prod I need you to confirm the maintenance window."

# --- The fleet ------------------------------------------------------------------
# boss (root, paired) > lead (the tagged gate notifier, paired) > quiet (NO channel,
# the seat that asks) and paired (a seat with its own channel).
NOW=$(date +%s)
channel() { # <name> <allowFrom json>
  local d="$TMP/home/agent-$1/.claude/channels/telegram"
  mkdir -p "$d"; printf '{"dmPolicy":"allowlist","allowFrom":%s}\n' "$2" > "$d/access.json"
  printf 'TELEGRAM_BOT_TOKEN=tok-%s\n' "$1" > "$CONNECTORS_DIR/telegram-$1.env"
}
unchannel() { rm -rf "$TMP/home/agent-$1/.claude/channels" "$CONNECTORS_DIR/telegram-$1.env"; }
channel boss '["701"]'; channel lead '["501"]'; channel paired '["601"]'
printf '{"agents":{"boss":{"type":"claude"},"lead":{"type":"claude"},"quiet":{"type":"claude"},"paired":{"type":"claude"}}}\n' > "$REGISTRY"
db "INSERT INTO agents_org(name, reports_to, role) VALUES
      ('boss', NULL, 'Owner'), ('lead', 'boss', 'Team lead and gate notifier'),
      ('quiet', 'lead', 'Engineer'), ('paired', 'lead', 'Engineer');" >/dev/null

# One transcript in the record shape measured on a live seat: the turn's thinking
# and text records both carry the message's final stop_reason, then the system
# records Claude Code writes after a turn.
tx() { # <seat> <text> [stop_reason] [entrypoint] [file] [age s]
  local d="$TMP/home/agent-$1/.claude/projects/-home-claude-projects" f
  mkdir -p "$d"; f="$d/${5:-session}.jsonl"
  jq -cn --arg t "$2" --arg s "${3:-end_turn}" --arg e "${4:-cli}" '
    {type: "user", entrypoint: $e, message: {role: "user", content: "go on"}},
    {type: "assistant", entrypoint: $e, message: {role: "assistant", stop_reason: $s, content: [{type: "thinking", thinking: "…"}]}},
    {type: "assistant", entrypoint: $e, message: {role: "assistant", stop_reason: $s, content: [{type: "text", text: $t}]}},
    {type: "system", subtype: "stop_hook_summary"}, {type: "system", subtype: "turn_duration"}, {type: "cost-state"}' > "$f"
  touch -d "@$((NOW - ${6:-60}))" "$f"
}

_tg_access_state_dir() { printf '%s/home/%s/.%s/channels/telegram' "$TMP" "$1" "$2"; }
UNIT_ACTIVE=1
systemctl() { [[ "$1" == is-active ]] && (( UNIT_ACTIVE )); }
_gate_channel_api() { # <token> <method> [curl args...] -> api.log: token|method|chat|text
  local tok="$1" m="$2" chat="" text=""; shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d) [[ "$2" == chat_id=* ]] && chat="${2#chat_id=}"; shift ;;
      --data-urlencode) [[ "$2" == text=* ]] && text="${2#text=}"; shift ;;
    esac
    shift
  done
  printf '%s|%s|%s|%s\n' "$tok" "$m" "$chat" "${text//$'\n'/\\n}" >> "$TMP/api.log"
  if (( API_OK )); then printf '{"ok":true,"result":{"message_id":1}}\n'
  else printf '{"ok":false,"error_code":502,"description":"Bad Gateway"}\n'; fi
}
API_OK=1
CLOCK=$NOW
_hb_stuck_q_now() { printf '%s' "$CLOCK"; }
RX_RESP='{"choice":"asks_human","confidence":0.95}'; RX_RC=0
_reflex_endpoint_decide() { # <model> <timeout> — stdin request, stdout response
  cat > "$TMP/rx.req"; printf '%s\n' "$1" >> "$TMP/rx.calls"
  printf '%s\n' "$RX_RESP"; return "$RX_RC"
}
_hb_log() { printf '%s\n' "$*" >> "$TMP/hb.log"; }

opt_in()  { printf '{"reflex_model":"typesafe/jev-1.13"}\n' > "$STATE_DIR/box.json"; printf 'sk-or-test\n' > "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE"; }
opt_out() { printf '{}\n' > "$STATE_DIR/box.json"; printf 'sk-or-test\n' > "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE"; }
fresh()   { rm -rf "$STATE_DIR/stuck-question"; }         # forget every judged text
tick()    { : > "$TMP/api.log"; : > "$TMP/rx.calls"; : > "$TMP/hb.log"; rm -f "$TMP/rx.req"; _hb_stuck_question_sweep; }
sends()   { grep -c . "$TMP/api.log"; }
calls()   { grep -c . "$TMP/rx.calls"; }
receipts() { db "SELECT COALESCE(detail,'') FROM lifecycle_events WHERE kind='decision.stuck' ORDER BY id;"; }
last_receipt() { receipts | tail -1; }

# --- P) preconditions -------------------------------------------------------------
tx quiet "$MARCUS_Q"
[[ "$(_hb_seat_ended_turn_text quiet)" == "$MARCUS_Q" ]] \
  && ok_t "P1: the reader returns the ended turn's text, newlines kept" \
  || bad_t "P1: ended-turn text" "got: $(_hb_seat_ended_turn_text quiet | head -c 200)"
_hb_stuck_base_asks "$MARCUS_Q" && ! _hb_stuck_base_asks "$REPORT" \
  && ok_t "P2: the base tier reads an ask in MARCUS_Q and none in a plain report" \
  || bad_t "P2: base tier on MARCUS_Q / REPORT"
_hb_stuck_base_asks "$ASK_BURIED" && _hb_stuck_base_asks "$RHETORICAL" \
  && ! _hb_stuck_base_asks "Should I restart it? I did.

Restarted; nothing needed from you." \
  && ok_t "P3: a phrase-only ask and a quoted '?' both read as asks; a question in an EARLIER paragraph does not" \
  || bad_t "P3: base tier phrase / final-paragraph scope"

# --- G) [g] no reflex configured: the base forwards -------------------------------
opt_out; fresh; tx quiet "$MARCUS_Q"; tick
[[ "$(sends)" == 1 ]] && [[ "$(cut -d'|' -f1-3 "$TMP/api.log")" == "tok-lead|sendMessage|501" ]] \
  && ok_t "G1: one sendMessage, through the gate notifier's bot, to its human" \
  || bad_t "G1: one forward via lead" "api: $(cat "$TMP/api.log")"
G_TEXT=$(cut -d'|' -f4- "$TMP/api.log")
[[ "$G_TEXT" == "quiet is waiting for an answer: I haven't restarted anything."* ]] \
  && has "$G_TEXT" "Should I restart claude-swan on its own as a test?" \
  && [[ "$G_TEXT" == *"\\n\\nReply with sudo 5dive agent send quiet '…'" ]] \
  && ok_t "G2: the forward names the seat, carries its question and the one command that answers it" \
  || bad_t "G2: forward text" "got: $G_TEXT"
[[ "$(calls)" == 0 ]] && [[ -z "$(receipts)" ]] \
  && ok_t "G3: no reflex call and no receipt without an opt-in" \
  || bad_t "G3: base tier alone" "calls=$(calls) receipts=$(receipts)"
has "$(cat "$TMP/hb.log")" "[stuck-question] quiet is waiting for an answer; forwarded through lead's bot, 1 chat(s) confirmed" \
  && ok_t "G4: the tick log names the seat, the bot and the confirmed count" \
  || bad_t "G4: log line" "$(cat "$TMP/hb.log")"

# --- B) [b] one text, one forward -------------------------------------------------
tick
[[ "$(sends)" == 0 ]] \
  && ok_t "B1: the next tick, transcript untouched, forwards nothing" \
  || bad_t "B1: no repeat" "$(cat "$TMP/api.log")"
touch -d "@$((NOW - 5))" "$TMP/home/agent-quiet/.claude/projects/-home-claude-projects/session.jsonl"; tick
[[ "$(sends)" == 0 ]] \
  && ok_t "B2: the transcript touched but the same text: still no second forward" \
  || bad_t "B2: hash dedup" "$(cat "$TMP/api.log")"
tx quiet "Update now anyway?"; tick
[[ "$(sends)" == 1 ]] \
  && ok_t "B3: a NEW question from the same seat is forwarded" \
  || bad_t "B3: a new text forwards" "sends=$(sends)"

# --- E) [e] a key alone is not an opt-in -------------------------------------------
opt_out; fresh; tx quiet "$MARCUS_Q"; tick
[[ "$(calls)" == 0 && "$(sends)" == 1 ]] \
  && ok_t "E1: key file present, no reflex model: no reflex call, the base still forwards" \
  || bad_t "E1: not opted in" "calls=$(calls) sends=$(sends)"

# --- A) [a] opted in, asks_human 0.95 ------------------------------------------------
opt_in; fresh; RX_RESP='{"choice":"asks_human","confidence":0.95}'; RX_RC=0; tx quiet "$MARCUS_Q"; tick
[[ "$(calls)" == 1 && "$(sends)" == 1 ]] \
  && ok_t "A1: asks_human 0.95: one reflex call, one forward" \
  || bad_t "A1: reflex agrees" "calls=$(calls) sends=$(sends)"
[[ "$(head -1 "$TMP/rx.calls")" == "typesafe/jev-1.13" ]] \
  && [[ "$(jq -c '.state | keys' "$TMP/rx.req")" == '["output"]' ]] \
  && [[ "$(jq -r '.state.output' "$TMP/rx.req")" == "$MARCUS_Q" ]] \
  && [[ "$(jq -c '.options' "$TMP/rx.req")" == '["asks_human","progress","report","idle"]' ]] \
  && ok_t "A2: the box's model is asked, and the request holds the last text and nothing else of the seat's" \
  || bad_t "A2: request shape" "model=$(head -1 "$TMP/rx.calls") req=$(head -c 300 "$TMP/rx.req")"
[[ "$(last_receipt | jq -r '[.result, .confidence, .effect.forwarded, .fallback] | map(tostring) | join(" ")')" == "asks_human 0.95 true false" ]] \
  && ok_t "A3: the receipt holds the decision and its confidence" \
  || bad_t "A3: receipt" "$(last_receipt)"
LONG="$(printf 'x%.0s' {1..3000}) Can you look?"
fresh; tx quiet "$LONG"; tick
OUT_LEN=$(jq -r '.state.output | length' "$TMP/rx.req")
(( OUT_LEN <= _HB_STUCK_Q_TEXT_MAX + 1 )) && [[ "$(jq -r '.state.output' "$TMP/rx.req")" == *"Can you look?" ]] \
  && ok_t "A4: a long turn leaves the box capped at its last ${_HB_STUCK_Q_TEXT_MAX} chars plus an ellipsis (sent ${OUT_LEN})" \
  || bad_t "A4: text cap" "sent ${OUT_LEN} chars"

# --- C) [c] asks_human below the bar ----------------------------------------------------
fresh; RX_RESP='{"choice":"asks_human","confidence":0.6}'; tx quiet "$MARCUS_Q"; tick
[[ "$(calls)" == 1 && "$(sends)" == 0 ]] \
  && [[ "$(last_receipt | jq -r '[.result, .confidence, .effect.forwarded] | map(tostring) | join(" ")')" == "asks_human 0.6 false" ]] \
  && ok_t "C1: asks_human 0.6: receipt written, nothing forwarded" \
  || bad_t "C1: below 0.9" "calls=$(calls) sends=$(sends) receipt=$(last_receipt)"

# --- H) [h] the rhetorical '?' ------------------------------------------------------------
opt_out; fresh; tx quiet "$RHETORICAL"; tick
[[ "$(sends)" == 1 ]] \
  && ok_t "H1: base tier alone forwards the quoted-question report (its accepted false positive)" \
  || bad_t "H1: base forwards the rhetorical text" "sends=$(sends)"
opt_in; fresh; RX_RESP='{"choice":"report","confidence":0.93}'; tx quiet "$RHETORICAL"; tick
[[ "$(calls)" == 1 && "$(sends)" == 0 ]] && [[ "$(last_receipt | jq -r .result)" == report ]] \
  && ok_t "H2: the reflex tier reads it as a report and suppresses the forward" \
  || bad_t "H2: reflex suppresses" "calls=$(calls) sends=$(sends)"

# --- I) [i] reflex cannot answer: the base verdict stands ---------------------------------
fresh; RX_RESP=''; RX_RC=124; tx quiet "$MARCUS_Q"; tick
[[ "$(calls)" == 1 && "$(sends)" == 1 ]] \
  && [[ "$(last_receipt | jq -r '[.result, .fallback, .effect.error] | map(tostring) | join(" ")')" == "none true timeout" ]] \
  && ok_t "I1: reflex timing out: forwarded anyway, receipt says fallback/timeout" \
  || bad_t "I1: fail open on timeout" "calls=$(calls) sends=$(sends) receipt=$(last_receipt)"
fresh; RX_RESP='{"choice":null,"error":"http 502"}'; RX_RC=0; tx quiet "$MARCUS_Q"; tick
[[ "$(sends)" == 1 ]] && [[ "$(last_receipt | jq -r .effect.error)" == "http 502" ]] \
  && ok_t "I2: reflex answering an error: forwarded anyway" \
  || bad_t "I2: fail open on error" "sends=$(sends) receipt=$(last_receipt)"
fresh; RX_RESP='{"choice":"maybe","confidence":0.99}'; tx quiet "$MARCUS_Q"; tick
[[ "$(sends)" == 1 ]] && [[ "$(last_receipt | jq -r .effect.error)" == "invalid_choice" ]] \
  && ok_t "I3: reflex naming no legal option: forwarded anyway" \
  || bad_t "I3: fail open on an invalid pick" "sends=$(sends) receipt=$(last_receipt)"
RX_RESP='{"choice":"asks_human","confidence":0.95}'

# --- D) [d] a seat with its own channel ------------------------------------------------------
opt_in; fresh; tx paired "$MARCUS_Q"; rm -rf "$TMP/home/agent-quiet/.claude/projects"; tick
[[ "$(calls)" == 0 && "$(sends)" == 0 ]] \
  && ok_t "D1: a seat whose human already sees it: no reflex call, no forward" \
  || bad_t "D1: paired seat untouched" "calls=$(calls) sends=$(sends)"
rm -rf "$TMP/home/agent-paired/.claude/projects"

# --- F) [f] no receipt carries text ----------------------------------------------------------
ALL=$(receipts)
N_REC=$(grep -c . <<<"$ALL")
if (( N_REC >= 6 )) && ! grep -qE "claude-swan|restarted anything|merge it now|Update now|xxxxxxxx|Can you look" <<<"$ALL"; then
  ok_t "F1: ${N_REC} stuck receipts, none holds a word of any seat's text"
else
  bad_t "F1: receipts carry no text" "n=${N_REC}: $(head -c 400 <<<"$ALL")"
fi

# --- N) scope ------------------------------------------------------------------------------------
opt_out; fresh; tx quiet "$MARCUS_Q" tool_use; tick
[[ "$(sends)" == 0 ]] \
  && ok_t "N1: a text record whose message went on to a tool call (stop_reason tool_use) is not an ended turn" \
  || bad_t "N1: mid-turn text ignored" "$(cat "$TMP/api.log")"
fresh; tx quiet "$MARCUS_Q"; UNIT_ACTIVE=0; tick; UNIT_ACTIVE=1
[[ "$(sends)" == 0 ]] \
  && ok_t "N2: a seat whose unit is not active is left alone" \
  || bad_t "N2: inactive unit" "$(cat "$TMP/api.log")"
fresh; tx quiet "$MARCUS_Q" end_turn cli session 120
tx quiet '{"atoms":[{"type":"reference","name":"x","description":"why?"}]}' end_turn sdk-cli distiller 10
tick
[[ "$(sends)" == 1 ]] && has "$(cat "$TMP/api.log")" "claude-swan on its own" && ! has "$(cat "$TMP/api.log")" "atoms" \
  && ok_t "N3: a newer headless (sdk-cli) transcript is walked past; the interactive question is forwarded" \
  || bad_t "N3: headless transcript skipped" "$(cat "$TMP/api.log")"
rm -f "$TMP/home/agent-quiet/.claude/projects/-home-claude-projects/distiller.jsonl"
fresh; tx quiet "$MARCUS_Q" end_turn cli session $(( (_HB_STUCK_Q_MAX_AGE_MIN + 5) * 60 )); tick
[[ "$(sends)" == 0 ]] \
  && ok_t "N4: a turn older than ${_HB_STUCK_Q_MAX_AGE_MIN} min is not forwarded (no flood on the first tick after install)" \
  || bad_t "N4: age bound" "$(cat "$TMP/api.log")"
fresh; tx quiet "$REPORT"; tick
[[ "$(sends)" == 0 ]] \
  && ok_t "N5: a turn that asks nothing is not forwarded" \
  || bad_t "N5: plain report" "$(cat "$TMP/api.log")"

# --- R) routing ------------------------------------------------------------------------------------
fresh; tx quiet "$MARCUS_Q"; unchannel lead; tick
[[ "$(cut -d'|' -f1-3 "$TMP/api.log")" == "tok-boss|sendMessage|701" ]] \
  && ok_t "R1: the gate notifier unpaired: the nearest paired seat up the chain gets it" \
  || bad_t "R1: chain fallback" "$(cat "$TMP/api.log")"
fresh; tx quiet "$MARCUS_Q"; unchannel boss; tick
[[ "$(sends)" == 0 ]] && has "$(cat "$TMP/hb.log")" "no paired channel resolves" \
  && ok_t "R2: nobody paired above the seat: logged, nothing sent" \
  || bad_t "R2: undeliverable is logged" "api=$(cat "$TMP/api.log") hb=$(cat "$TMP/hb.log")"
channel boss '["701"]'; channel lead '["501"]'

# --- S) a failed send is retried, not marked judged ------------------------------------------------
# sends() counts ATTEMPTS (every sendMessage the stub saw, ok or not); the log line
# says how many landed.
opt_out; fresh; tx quiet "$MARCUS_Q"; API_OK=0; tick
[[ "$(sends)" == 1 ]] && has "$(cat "$TMP/hb.log")" "0 chat(s) confirmed, try 1" \
  && ok_t "S1: the Bot API refuses the send: one attempt, logged as 0 confirmed, try 1" \
  || bad_t "S1: failed send" "api=$(cat "$TMP/api.log") hb=$(cat "$TMP/hb.log")"
API_OK=1; tick
[[ "$(sends)" == 1 ]] && has "$(cat "$TMP/hb.log")" "1 chat(s) confirmed" \
  && ok_t "S2: the API back, transcript untouched: the next tick sends it again and it lands" \
  || bad_t "S2: retry after a failed send" "sends=$(sends) hb=$(cat "$TMP/hb.log")"
tick
[[ "$(sends)" == 0 ]] \
  && ok_t "S3: once it landed, the following tick sends nothing (still once)" \
  || bad_t "S3: no repeat after delivery" "$(cat "$TMP/api.log")"
fresh; tx quiet "$MARCUS_Q"; API_OK=0; tick; API_OK=1
touch -d "@$((NOW - 5))" "$TMP/home/agent-quiet/.claude/projects/-home-claude-projects/session.jsonl"; tick
[[ "$(sends)" == 1 ]] && has "$(cat "$TMP/hb.log")" "1 chat(s) confirmed" \
  && ok_t "S4: a failed send, then the transcript touched with the same text: sent again and it lands" \
  || bad_t "S4: retry after a touch" "sends=$(sends)"
opt_in; fresh; RX_RESP='{"choice":"asks_human","confidence":0.95}'; RX_RC=0
tx quiet "$MARCUS_Q"; API_OK=0; tick; R0=$(receipts | grep -c .); API_OK=1; tick
[[ "$(calls)" == 0 && "$(sends)" == 1 ]] && [[ "$(receipts | grep -c .)" == "$R0" ]] \
  && ok_t "S5: opted in, the retry does not ask reflex again or write another receipt (it already said forward)" \
  || bad_t "S5: retry skips reflex" "calls=$(calls) sends=$(sends) receipts $R0 -> $(receipts | grep -c .)"
opt_out

# --- U) unpaired, then paired -------------------------------------------------------------------------
fresh; tx quiet "$MARCUS_Q"; unchannel lead; unchannel boss; tick
[[ "$(sends)" == 0 ]] && has "$(cat "$TMP/hb.log")" "no paired channel resolves" \
  && ok_t "U1: nobody paired above the seat: logged, nothing sent" \
  || bad_t "U1: unroutable" "api=$(cat "$TMP/api.log") hb=$(cat "$TMP/hb.log")"
channel lead '["501"]'; tick
[[ "$(cut -d'|' -f1-3 "$TMP/api.log")" == "tok-lead|sendMessage|501" ]] \
  && ok_t "U2: the gate notifier paired afterwards: the next tick delivers the waiting question through it" \
  || bad_t "U2: re-pair delivers" "$(cat "$TMP/api.log")"
tick
[[ "$(sends)" == 0 ]] \
  && ok_t "U3: and only once" \
  || bad_t "U3: no repeat after the re-pair" "$(cat "$TMP/api.log")"
channel boss '["701"]'

# --- K) backoff ------------------------------------------------------------------------------------------
[[ "$(_hb_stuck_q_backoff 1) $(_hb_stuck_q_backoff 2) $(_hb_stuck_q_backoff 3) $(_hb_stuck_q_backoff 5) $(_hb_stuck_q_backoff 40)" == "0 600 1200 3600 3600" ]] \
  && ok_t "K1: backoff: next tick, then 10m, 20m, capped at 60m" \
  || bad_t "K1: backoff schedule" "$(_hb_stuck_q_backoff 1) $(_hb_stuck_q_backoff 2) $(_hb_stuck_q_backoff 3) $(_hb_stuck_q_backoff 5) $(_hb_stuck_q_backoff 40)"
fresh; tx quiet "$MARCUS_Q"; unchannel lead; unchannel boss
tick; tick; N2=$(grep -c 'no paired channel resolves' "$TMP/hb.log")
tick; N3=$(grep -c 'no paired channel resolves' "$TMP/hb.log")
touch -d "@$((NOW - 5))" "$TMP/home/agent-quiet/.claude/projects/-home-claude-projects/session.jsonl"
tick; N4=$(grep -c 'no paired channel resolves' "$TMP/hb.log")
[[ "$N2" == 1 && "$N3" == 0 && "$N4" == 0 ]] \
  && ok_t "K2: unroutable: try 2 logs, then a tick inside its 10m backoff logs nothing, touched transcript or not" \
  || bad_t "K2: backoff holds" "try2=$N2 inside=$N3 touched=$N4"
CLOCK=$((NOW + 600)); tick; N5=$(grep -c 'try 3, retrying in 20m' "$TMP/hb.log")
CLOCK=$((NOW + 900)); tick; N6=$(grep -c . "$TMP/hb.log")
[[ "$N5" == 1 && "$N6" == 0 ]] \
  && ok_t "K3: 10m later it tries again (try 3, next in 20m) and is quiet again inside that window" \
  || bad_t "K3: backoff doubles" "try3=$N5 after=$N6"
channel lead '["501"]'; channel boss '["701"]'
CLOCK=$((NOW + 1800)); tick
[[ "$(sends)" == 1 ]] \
  && ok_t "K4: once its backoff is up and a channel exists, the question is delivered" \
  || bad_t "K4: delivered after backoff" "$(cat "$TMP/api.log")"
CLOCK=$NOW
fresh; tx quiet "$MARCUS_Q"; API_OK=0; tick; API_OK=1
tx quiet "$REPORT"; tick
[[ "$(sends)" == 0 && ! -e "$STATE_DIR/stuck-question/quiet.retry" ]] \
  && ok_t "K5: a failed send, then the seat reports without asking: the pending retry is dropped, nothing sent" \
  || bad_t "K5: new text replaces the pending one" "sends=$(sends) retry=$(cat "$STATE_DIR/stuck-question/quiet.retry" 2>/dev/null)"
tick
[[ "$(sends)" == 0 ]] \
  && ok_t "K6: and the superseded question is never sent afterwards" \
  || bad_t "K6: superseded question stays dropped" "$(cat "$TMP/api.log")"

# --- W) the tick runs the sweep ---------------------------------------------------------------------
grep -q '^  _hb_stuck_question_sweep || _hb_log "\[stuck-question\] pass errored (non-fatal)"$' "$SRC/cmd_heartbeat.sh" \
  && ok_t "W1: cmd_heartbeat's tick calls the sweep under the non-fatal contract" \
  || bad_t "W1: sweep wired into the tick" "no call site in $SRC/cmd_heartbeat.sh"

# --- L) LIVE BOX: the transcript shape the reader keys on ----------------------------------------------
# The reader keys on a box fact — what Claude Code writes into a seat's
# ~/.claude/projects — so this reads the running user's OWN transcripts, read-only,
# instead of a fixture. A runner with none (CI) skips; it is not a pass.
LIVE_DIR="${LIVE_HOME}/.claude/projects"
LIVE_TX=()
if [[ -n "$LIVE_HOME" && -d "$LIVE_DIR" ]]; then
  mapfile -t LIVE_TX < <(find "$LIVE_DIR" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -40 | cut -d' ' -f2-)
fi
if (( ${#LIVE_TX[@]} == 0 )); then
  skip_t "L1/L2: no transcript under ${LIVE_DIR:-~/.claude/projects} on this runner — nothing live to read"
else
  LIVE_ENDED="" LIVE_WANT="" LIVE_HEADLESS=""
  for f in "${LIVE_TX[@]}"; do
    if [[ -z "$LIVE_HEADLESS" ]] && tail -n 50 "$f" | jq -e 'select(.type == "assistant" and .entrypoint == "sdk-cli")' >/dev/null 2>&1; then
      LIVE_HEADLESS="$f"; continue
    fi
    [[ -z "$LIVE_ENDED" ]] || continue
    # Independent of the reader: the last user/assistant record, by grep and jq -s.
    LAST=$(tail -n 800 "$f" | grep -E '"type":"(user|assistant)"' | tail -1)
    [[ "$(jq -r '[.type, .message.stop_reason // "", .entrypoint // ""] | join(" ")' <<<"$LAST" 2>/dev/null)" == "assistant end_turn cli" ]] || continue
    LIVE_WANT=$(jq -r '[.message.content[]? | select(.type == "text") | .text] | join("\n\n")' <<<"$LAST")
    [[ -n "$LIVE_WANT" ]] && LIVE_ENDED="$f"
  done
  if [[ -z "$LIVE_ENDED" ]]; then
    bad_t "L1: live transcripts exist but none ends a turn in the shape the reader keys on (assistant, stop_reason end_turn, entrypoint cli)" "read ${#LIVE_TX[@]} file(s) under $LIVE_DIR — the CLI's record shape moved"
  else
    LD="$TMP/home/agent-live/.claude/projects/live"; mkdir -p "$LD"
    tail -n 800 "$LIVE_ENDED" > "$LD/interactive.jsonl"; touch -d "@$((NOW - 120))" "$LD/interactive.jsonl"
    if [[ -n "$LIVE_HEADLESS" ]]; then tail -n 800 "$LIVE_HEADLESS" > "$LD/headless.jsonl"; touch -d "@$((NOW - 10))" "$LD/headless.jsonl"; fi
    GOT=$(_hb_seat_ended_turn_text live)
    # The single-record read above can only see the LAST text record; a turn whose
    # final message holds several text blocks is compared on its tail.
    [[ -n "$GOT" && "$GOT" == *"$LIVE_WANT" ]] \
      && ok_t "L1: on this box's own transcripts the reader returns the newest ended turn ($(basename "$LIVE_ENDED")$([[ -n "$LIVE_HEADLESS" ]] && printf ', walking past the newer headless %s' "$(basename "$LIVE_HEADLESS")"))" \
      || bad_t "L1: live ended turn" "file=$LIVE_ENDED got=$(head -c 160 <<<"$GOT") want=$(head -c 160 <<<"$LIVE_WANT")"
    if [[ -n "$LIVE_HEADLESS" ]]; then
      [[ "$(tail -n 800 "$LIVE_HEADLESS" | jq -r 'select(.type == "assistant") | .entrypoint' 2>/dev/null | sort -u)" == "sdk-cli" ]] \
        && ok_t "L2: this box's headless transcript marks every assistant record entrypoint=sdk-cli, the field the reader walks past" \
        || bad_t "L2: headless marker" "$LIVE_HEADLESS"
    else
      skip_t "L2: no headless transcript among this user's newest 40 — nothing live to walk past"
    fi
  fi
fi
# CONTROL, whatever box this runs on: a seat with no home at all (a clean runner).
! _hb_seat_ended_turn_text no-such-seat >/dev/null \
  && ok_t "L3: CONTROL: a seat with no home reads as no ended turn, and nothing errors" \
  || bad_t "L3: absent home" "the reader returned text for a seat with no home"

# --- M) MUTANTS -------------------------------------------------------------------------------------------
# M1 re-introduces the defect in-process: the sweep looks only at seats a person
# already sees, i.e. the channel-less seat is as unread as before this change.
# M2 forgets the text it judged. G and B must go red on them, or they grade nothing.
SWEEP_SRC=$(awk '/^_hb_stuck_question_sweep\(\) \{/,/^\}/' "$SRC/cmd_heartbeat.sh")
eval "$(sed 's/_task_agent_channel "\$name" && continue /_task_agent_channel "$name" || continue /' <<<"$SWEEP_SRC")"
has "$(declare -f _hb_stuck_question_sweep)" '_task_agent_channel "$name" || continue' \
  && ok_t "M0: (anchor) the scope mutation landed" \
  || bad_t "M0: scope mutation anchor" "the sed pattern no longer matches src/cmd_heartbeat.sh"
opt_out; fresh; tx quiet "$MARCUS_Q"; tick
[[ "$(sends)" == 0 ]] \
  && ok_t "M1: MUTANT (channel-less seat unread): G1's forward is gone — G goes red" \
  || bad_t "M1: mutant must lose the forward" "$(cat "$TMP/api.log")"
eval "$(sed '/> "\$dir\/\${name}.last"/d' <<<"$SWEEP_SRC")"
! has "$(declare -f _hb_stuck_question_sweep)" '"$hash" > "$dir/${name}.last"' \
  && ok_t "M0b: (anchor) the dedup mutation landed" \
  || bad_t "M0b: dedup mutation anchor" "the sed pattern no longer matches src/cmd_heartbeat.sh"
fresh; tx quiet "$MARCUS_Q"; tick
touch -d "@$((NOW - 5))" "$TMP/home/agent-quiet/.claude/projects/-home-claude-projects/session.jsonl"; tick
[[ "$(sends)" == 1 ]] \
  && ok_t "M2: MUTANT (text not remembered): the touched transcript forwards again — B2 goes red" \
  || bad_t "M2: mutant must repeat the forward" "sends=$(sends)"
# M3 is the iteration-1 sweep's ordering: the text is marked judged as soon as it
# is hashed, before the route and the send.
eval "$(sed 's/^    retrying=0$/    echo "$hash" > "$dir\/${name}.last"; retrying=0/' <<<"$SWEEP_SRC")"
has "$(declare -f _hb_stuck_question_sweep)" 'echo "$hash" > "$dir/${name}.last";' \
  && ok_t "M0c: (anchor) the mark-before-send mutation landed" \
  || bad_t "M0c: mark-before-send mutation anchor" "the sed pattern no longer matches src/cmd_heartbeat.sh"
opt_out; fresh; tx quiet "$MARCUS_Q"; API_OK=0; tick; API_OK=1; tick
S_MUT=$(sends)
fresh; tx quiet "$MARCUS_Q"; unchannel lead; unchannel boss; tick; channel lead '["501"]'; channel boss '["701"]'; tick
U_MUT=$(sends)
[[ "$S_MUT" == 0 && "$U_MUT" == 0 ]] \
  && ok_t "M3: MUTANT (marked judged before the send): the failed send and the unpaired question are lost — S2 and U2 go red" \
  || bad_t "M3: mutant must lose the retry" "send-fail retry sends=$S_MUT re-pair sends=$U_MUT"
eval "$SWEEP_SRC"

echo "-----"
printf 'PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
