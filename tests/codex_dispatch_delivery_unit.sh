#!/usr/bin/env bash
# DIVE-4036 unit: a dispatched goal must reach the MODEL, not the process that
# happens to hold the agent's tmux pane.
#
# THE DEFECT this grades. PR #770 (DIVE-3961) gave a codex seat with `telegram`
# or `dashboard` in its channels a new pane process — the app-server dispatcher —
# and left every send site typing into that pane with `tmux send-keys`. The
# keystrokes landed in the dispatcher's stdin and were discarded. On this host
# the codex seat was deaf for ~2.2 days while `agent list` said active, `agent
# info` said transacting and the board said in_progress; it was found because a
# human noticed a task had not moved. Customer boxes were worse: `dashboard` is
# the common channel there, so the blast radius was never limited to Telegram.
#
# WHY THE OBVIOUS TEST IS NOT ENOUGH. "send-keys was called" is exactly the
# assertion that would have stayed green through the whole outage — it grades the
# instrument, not the delivery. So every arm here grades WHERE the payload went,
# and two arms exist only because their absence is what lets the bug back in:
#
#   * the PARITY arm. The pane process is chosen by codex_dispatcher_enabled() in
#     5dive-agent-start; the delivery path has its own fallback copy for boxes
#     whose boot script predates this fix. Two predicates that must agree, with
#     nothing forcing them to, IS the defect one layer up — so the two bodies are
#     asserted byte-identical rather than trusted to a comment.
#   * the DECLARATION-ABSENT arm. A box mid-upgrade has no boot declaration, and
#     reading that absence as "pane" reproduces the outage silently on precisely
#     the boxes that have not been fixed yet. Absence must fall back to deriving
#     the answer, not to a default.
#
# Plus: `dashboard` is graded separately from `telegram` (the row was filed on
# telegram and the expensive population is dashboard), `channels: none` is
# asserted to STAY on the pane path (andy/vesper must not be re-routed into an
# inbox no dispatcher is draining), and a non-codex seat with telegram is
# asserted unaffected (claude+telegram keeps the CLI in the pane).
#
# Pure: sources the shipped functions out of src/, stubs sudo/jq-free paths with
# a fake agent home in a tempdir, no root, no tmux, no network.
#   bash tests/codex_dispatch_delivery_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1 (expected '$2', got '$3')"; fi; }

RT=src/cmd_agent_runtime.sh
START=5dive-agent-start
HB=src/cmd_heartbeat.sh

# ---------------------------------------------------------------------------
# Arm 1 — PARITY. The boot predicate and the delivery fallback are one rule.
# ---------------------------------------------------------------------------
body_of() { # body_of <file> <fn-name>  -> the body, function name stripped
  awk -v open_line="${2}() {" '$0 == open_line { on=1; next } on && $0 == "}" { exit } on { print }' "$1"
}
_boot_body="$(body_of "$START" codex_dispatcher_enabled)"
_rt_body="$(body_of "$RT" _codex_dispatcher_enabled)"
if [[ -z "$_boot_body" ]]; then
  bad_t "parity: could not extract codex_dispatcher_enabled from $START"
elif [[ -z "$_rt_body" ]]; then
  bad_t "parity: could not extract _codex_dispatcher_enabled from $RT"
else
  eq_t "parity: the delivery fallback predicate is byte-identical to the boot predicate" \
    "$_boot_body" "$_rt_body"
fi

# The boot script must actually WRITE the declaration the delivery path reads —
# a reader with no writer is the same silence in a new place.
if grep -q 'AGENT_DELIVERY=' "$START" && grep -q 'write_delivery_declaration$' "$START"; then
  ok_t "boot: 5dive-agent-start declares AGENT_DELIVERY and calls the writer"
else
  bad_t "boot: 5dive-agent-start does not write/call the delivery declaration"
fi

# ---------------------------------------------------------------------------
# Extract the shipped delivery functions.
# ---------------------------------------------------------------------------
for fn in _agent_delivery_inbox _agent_delivery_mode _codex_dispatcher_enabled \
          _agent_dispatch_is_tui_control _agent_dispatch_inbox_send \
          _agent_dispatch_control_verb _agent_dispatch_supports_control; do
  eval "$(awk -v f="^${fn}\\\\(\\\\) \\\\{$" '$0 ~ f { on=1 } on { print } on && $0 == "}" { exit }' "$RT")"
  declare -F "$fn" >/dev/null \
    || { printf 'FATAL - could not extract %s from %s\n' "$fn" "$RT"; exit 1; }
done

# ---------------------------------------------------------------------------
# Fake host. `sudo -u agent-<name> <cmd>` is redirected at a tempdir home, so the
# functions run their REAL logic against real files with no privilege.
# ---------------------------------------------------------------------------
ENV_DIR="$TMP/agents.d"; mkdir -p "$ENV_DIR"
HOMES="$TMP/homes"
SUDO_CALLS=""
sudo() {  # sudo -u agent-<name> <cmd...>
  local user cmd
  [[ "${1:-}" == "-u" ]] || { command sudo "$@"; return; }
  user="$2"; shift 2
  SUDO_CALLS+="$user:$1 "
  cmd="$1"; shift
  # Rewrite /home/agent-<name> -> $HOMES/<user> in every argument.
  local -a args=(); local a
  for a in "$@"; do args+=("${a//\/home\/${user}//$HOMES/$user}"); done
  HOME="$HOMES/$user" command "$cmd" "${args[@]}"
}
seat() { # seat <name> <type> <channels> [declare:pane|dispatcher-inbox|none]
  local n="$1" t="$2" c="$3" d="${4:-none}"
  printf 'AGENT_TYPE=%s\nAGENT_CHANNELS=%s\n' "$t" "$c" > "$ENV_DIR/${n}.env"
  mkdir -p "$HOMES/agent-${n}/.5dive"
  rm -f "$HOMES/agent-${n}/.5dive/delivery.env"
  [[ "$d" == "none" ]] || printf 'AGENT_DELIVERY=%s\n' "$d" > "$HOMES/agent-${n}/.5dive/delivery.env"
}
mode_of() { _agent_delivery_mode "$1"; }

# ---------------------------------------------------------------------------
# Arm 2 — the DECLARATION is authoritative when present.
# ---------------------------------------------------------------------------
seat codexdecl codex telegram dispatcher-inbox
eq_t "declared dispatcher-inbox is honoured" "dispatcher-inbox" "$(mode_of codexdecl)"
# A seat whose channel was removed and restarted declares pane even though its
# env file still looks dispatcher-shaped mid-rewrite: the DECLARATION wins,
# because it is what the running process actually did.
seat codexpane codex telegram pane
eq_t "declared pane wins over an env file that still says telegram" "pane" "$(mode_of codexpane)"

# ---------------------------------------------------------------------------
# Arm 3 — DECLARATION ABSENT (box mid-upgrade) must DERIVE, never default.
# ---------------------------------------------------------------------------
seat oldtg   codex telegram         none
seat olddash codex dashboard        none
seat oldboth codex telegram,discord none
seat oldnone codex none             none
seat oldbare codex ""               none
seat claudetg claude telegram       none
eq_t "no declaration + codex/telegram  -> dispatcher-inbox" "dispatcher-inbox" "$(mode_of oldtg)"
eq_t "no declaration + codex/dashboard -> dispatcher-inbox" "dispatcher-inbox" "$(mode_of olddash)"
eq_t "no declaration + codex/telegram,discord -> dispatcher-inbox" "dispatcher-inbox" "$(mode_of oldboth)"
eq_t "no declaration + codex/none      -> pane (andy/vesper unaffected)" "pane" "$(mode_of oldnone)"
eq_t "no declaration + codex/empty     -> pane" "pane" "$(mode_of oldbare)"
eq_t "no declaration + claude/telegram -> pane (the CLI still holds the pane)" "pane" "$(mode_of claudetg)"
eq_t "unknown seat with no env file    -> pane" "pane" "$(mode_of ghost)"

# _agent_delivery_inbox is the predicate the send sites branch on: it must SUCCEED
# only for a dispatcher seat, and hand back the directory the dispatcher drains.
if _agent_delivery_inbox oldnone >/dev/null 2>&1; then
  bad_t "inbox: a pane seat must not resolve an inbox"
else ok_t "inbox: a pane seat resolves no inbox"; fi
eq_t "inbox: path is the directory dispatcher.ts drains" \
  "/home/agent-oldtg/.codex/channels/dispatcher/inbox" "$(_agent_delivery_inbox oldtg)"

# ---------------------------------------------------------------------------
# Arm 4 — the message actually written is one the dispatcher will ACCEPT.
# dispatcher.ts ingest() drops a file whose id/text/route.source/route.chat_id is
# missing, and only accepts source telegram|dashboard|agent. A malformed write is
# indistinguishable from the outage: the file is deleted and nothing is delivered.
# ---------------------------------------------------------------------------
INBOX="$HOMES/agent-oldtg/.codex/channels/dispatcher/inbox"
mkdir -p "$INBOX"
PAYLOAD=$'/goal Task DIVE-1 shows status done\nsecond "line" with $shell `chars` and \\backslash'
( _agent_dispatch_inbox_send oldtg "$PAYLOAD" "/home/agent-oldtg/.codex/channels/dispatcher/inbox" ) &
_send_pid=$!
# Act as the dispatcher: drain the first .json that appears, then let the send return.
_msg=""
for _ in $(seq 1 200); do
  _msg="$(find "$INBOX" -maxdepth 1 -name '*.json' -print -quit 2>/dev/null)"
  [[ -n "$_msg" ]] && break
  command sleep 0.05
done
if [[ -z "$_msg" ]]; then
  bad_t "write: nothing was posted into the dispatcher inbox"
  kill "$_send_pid" 2>/dev/null; wait "$_send_pid" 2>/dev/null
else
  _json="$(cat "$_msg")"
  rm -f "$_msg"
  wait "$_send_pid"; _srrc=$?
  eq_t "write: a drained message reports delivered (rc 0)" "0" "$_srrc"
  eq_t "write: route.source is 'agent' (replies must not leak into a customer channel)" \
    "agent" "$(jq -r '.route.source' <<<"$_json")"
  [[ -n "$(jq -r '.route.chat_id // empty' <<<"$_json")" ]] \
    && ok_t "write: route.chat_id is present (ingest() drops a message without one)" \
    || bad_t "write: route.chat_id missing — dispatcher would discard this message"
  [[ -n "$(jq -r '.id // empty' <<<"$_json")" ]] \
    && ok_t "write: id is present" || bad_t "write: id missing"
  eq_t "write: the payload survives newlines, quotes, \$ and backticks verbatim" \
    "$PAYLOAD" "$(jq -r '.text' <<<"$_json")"
  # No partial file may be left behind: ingest() ignores non-.json, so a leftover
  # .part is a leak, and a leftover .json is a message that gets replayed.
  eq_t "write: no partial/leftover file remains in the inbox" \
    "0" "$(find "$INBOX" -maxdepth 1 -type f | wc -l | tr -d ' ')"
fi

# UNDRAINED is a failure, not a success. This is the whole point: a message the
# dispatcher never picked up must NOT be reported as delivered.
UND_RC=0
( FIVE_DISPATCH_CONFIRM_TRIES=3 FIVE_DISPATCH_CONFIRM_SLEEP=0.05 \
  _agent_dispatch_inbox_send oldtg "nobody is draining this" \
    "/home/agent-oldtg/.codex/channels/dispatcher/inbox" ) || UND_RC=$?
[[ "$UND_RC" -ne 0 ]] \
  && ok_t "undrained: a message nobody consumed reports NOT delivered (rc $UND_RC)" \
  || bad_t "undrained: an unconsumed message was reported as delivered — the outage, reproduced"
rm -f "$INBOX"/*.json 2>/dev/null

# ---------------------------------------------------------------------------
# Arm 5 — TUI control lines. "/clear" as an inbox message is a stray user turn in
# the customer's thread, not a context reset; it must be skipped, and only it.
# ---------------------------------------------------------------------------
for c in "/clear" "/goal clear" "/compact"; do
  _agent_dispatch_is_tui_control "$c" \
    && ok_t "control: '$c' is recognised as a TUI-only line" \
    || bad_t "control: '$c' would be submitted to the dispatcher as a user turn"
done
for c in "/goal Task DIVE-1 ..." "continue" "[supervisor] You look stalled"; do
  _agent_dispatch_is_tui_control "$c" \
    && bad_t "control: real work '$c' was misread as a TUI control line and would be DROPPED" \
    || ok_t "control: real work '${c:0:24}...' is delivered, not skipped"
done

# ---------------------------------------------------------------------------
# Arm 6 — every typed-send primitive routes. A fix applied to one of two paths is
# the shape of this whole bug (DIVE-4036 came from exactly that), and the
# heartbeat is the path that carries dispatched work.
# ---------------------------------------------------------------------------
for f in "$RT" "$HB"; do
  if grep -q '_agent_delivery_inbox' "$f"; then
    ok_t "routing: $(basename "$f") consults the delivery mode before typing"
  else
    bad_t "routing: $(basename "$f") still types unconditionally into the pane"
  fi
done
# The check must come BEFORE the pane credential guard in both — that guard reads
# a pane that is not a chat pane and can refuse a perfectly good delivery.
for f in "$RT" "$HB"; do
  _i=$(grep -n '_agent_delivery_inbox "\$name"\|_agent_delivery_inbox "\$target"' "$f" | head -1 | cut -d: -f1)
  _g=$(grep -n '_agent_pane_safe_to_type "\$name"' "$f" | head -1 | cut -d: -f1)
  if [[ -n "$_i" && -n "$_g" ]]; then
    [[ "$_i" -lt "$_g" ]] \
      && ok_t "routing: $(basename "$f") routes before the pane credential guard" \
      || bad_t "routing: $(basename "$f") runs the pane guard on a seat with no chat pane"
  fi
done

# ---------------------------------------------------------------------------
# Arm 7 — DIVE-5502: a dispatcher that ADVERTISES the verb takes /clear and
# /compact as control messages (the bounded thread per task). One that does not
# — an older bridge — still gets nothing, because it would run "/clear" as a turn.
# ---------------------------------------------------------------------------
eq_t "verb: /clear is a new session" "new-session" "$(_agent_dispatch_control_verb "/clear")"
eq_t "verb: /compact is a compaction" "compact" "$(_agent_dispatch_control_verb " /compact ")"
eq_t "verb: /goal clear has no dispatcher verb (still skipped)" "" "$(_agent_dispatch_control_verb "/goal clear")"

seat ctlnew codex telegram dispatcher-inbox
seat ctlold codex telegram dispatcher-inbox
seat ctlnone codex telegram dispatcher-inbox
_ctl_dir() { printf '%s\n' "$HOMES/agent-$1/.codex/channels/dispatcher"; }
mkdir -p "$(_ctl_dir ctlnew)/inbox" "$(_ctl_dir ctlold)/inbox" "$(_ctl_dir ctlnone)/inbox"
printf '{"schema":1,"controls":["compact","new-session"]}\n' > "$(_ctl_dir ctlnew)/health.json"
printf '{"schema":1}\n' > "$(_ctl_dir ctlold)/health.json"
_ctl_inbox() { printf '%s\n' "/home/agent-$1/.codex/channels/dispatcher/inbox"; }
_agent_dispatch_supports_control ctlnew new-session "$(_ctl_inbox ctlnew)" \
  && ok_t "supports: a bridge listing new-session runs it" \
  || bad_t "supports: an advertised verb was read as unsupported — task wakes stay unbounded"
_agent_dispatch_supports_control ctlnew rewind "$(_ctl_inbox ctlnew)" \
  && bad_t "supports: a verb the bridge never listed was read as supported" \
  || ok_t "supports: an unlisted verb is not supported"
_agent_dispatch_supports_control ctlold new-session "$(_ctl_inbox ctlold)" \
  && bad_t "supports: a pre-0.5.24 bridge was sent a control it would run as a user turn" \
  || ok_t "supports: a bridge with no controls list is not sent one"
_agent_dispatch_supports_control ctlnone new-session "$(_ctl_inbox ctlnone)" \
  && bad_t "supports: an absent health file was read as support" \
  || ok_t "supports: an absent health file means no"

# The message itself: a control field beside the text, and only when asked.
_ctl_drain() { # copy the first message in <inbox> to <out>, then unlink it (the receipt)
  local in="$1" out="$2"
  ( for _ in $(seq 1 100); do
      f=$(ls "$in"/*.json 2>/dev/null | head -1) || true
      [[ -n "${f:-}" ]] && { cp "$f" "$out"; rm -f "$f"; exit 0; }
      sleep 0.03
    done ) &
}
_ctl_drain "$(_ctl_dir ctlnew)/inbox" "$TMP/ctl-msg.json"; _d=$!
FIVE_DISPATCH_CONFIRM_TRIES=60 FIVE_DISPATCH_CONFIRM_SLEEP=0.03 \
  _agent_dispatch_inbox_send ctlnew "/clear" "$(_ctl_inbox ctlnew)" new-session; _rc=$?
wait "$_d" 2>/dev/null || true
eq_t "send: a drained control returns rc 0" "0" "$_rc"
eq_t "send: the control field rides the message" "new-session|/clear|agent" \
  "$(jq -r '"\(.control)|\(.text)|\(.route.source)"' "$TMP/ctl-msg.json" 2>/dev/null)"
_ctl_drain "$(_ctl_dir ctlnew)/inbox" "$TMP/plain-msg.json"; _d=$!
FIVE_DISPATCH_CONFIRM_TRIES=60 FIVE_DISPATCH_CONFIRM_SLEEP=0.03 \
  _agent_dispatch_inbox_send ctlnew "continue" "$(_ctl_inbox ctlnew)"; _rc=$?
wait "$_d" 2>/dev/null || true
eq_t "send: an ordinary message carries no control field" "false" \
  "$(jq -r 'has("control")' "$TMP/plain-msg.json" 2>/dev/null)"

# Both send paths consult the advertisement before posting a control: a fix on
# one of the two paths is the DIVE-4036 shape.
for f in "$RT" "$HB"; do
  grep -q '_agent_dispatch_supports_control "\$name"' "$f" \
    && ok_t "routing: $(basename "$f") checks the bridge runs the verb before posting it" \
    || bad_t "routing: $(basename "$f") posts or skips controls without asking the bridge"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
