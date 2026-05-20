#!/usr/bin/env bash
# Stop hook: mirror this agent's reply to an inbound 5dive inter-agent
# message (5dive agent send|ask) into the shared Telegram group, so the
# operator can read BOTH sides of agent-to-agent conversations in one room.
#
# Companion to mirror-agent-send.sh: that hook posts the OUTBOUND ask/send
# when this agent initiates. This hook posts the REPLY when this agent is
# the receiver. Together they make the group chat a complete transcript of
# inter-agent traffic — without this hook the group sees A's question to B
# but never B's answer.
#
# Why Stop only (not PostToolUse): inter-agent replies are typically a
# single end-of-turn text block. The mid-turn-relay companion that exists
# for Telegram inbound is overkill here — operator just wants the answer.
# Stop-only also keeps group noise bounded to one mirror line per turn.
#
# Skip cases (any → exit 0):
#   - No transcript, no token, or no group in access.json
#   - Turn's inbound wasn't a [5dive-msg from=X id=Y] envelope
#   - Agent emitted no transcript text this turn (tool-only response)
#
# Truncation: MIRROR_REPLY_MAX_CHARS (default 800) trims the body and
# appends a "+N chars" overflow indicator, matching mirror-agent-send.sh.
#
# Wired in $HOME/.claude/settings.json by lib/agent_setup.sh's
# preseed_claude_agent when channels=telegram. Token from TELEGRAM_BOT_TOKEN
# in the agent's systemd env (see /etc/5dive/connectors/telegram-<name>.env).

set -u
# Journal breadcrumb so a missing mirror can be distinguished from a hook
# that never fired (settings.json wiring problem). Followed by an end-state
# line near the curl call so the journal shows fired→sent or fired→skip.
logger -t stop-mirror "fired pid=$$ user=$(id -un 2>/dev/null) hook=stop-mirror-inter-agent" 2>/dev/null || true
payload=$(cat)

transcript_path=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
[[ -z "$transcript_path" || ! -r "$transcript_path" ]] && exit 0

# Wait for the end_turn assistant entry to land in the JSONL. Node's
# fs.appendFile() is async — Stop fires the moment the model returns
# stop_reason=end_turn, and the transcript write of that same message can
# still be in flight. A fixed 50ms sleep was not enough in practice (saw
# hook fire @ Xs.200 while end_turn flushed @ Xs.587), causing the hook
# to pick up the previous mid-turn text block as "last text" and mirror
# the wrong line. Poll up to ~2s for the latest assistant entry to carry
# stop_reason=end_turn; if it never does, fall through and read what we
# have (better stale-mirror than no-mirror).
for _ in $(seq 1 20); do
  last_reason=$(jq -sr '
    [ .[] | select(.type == "assistant") ] | last
    | (.message.stop_reason // "")
  ' "$transcript_path" 2>/dev/null)
  [[ "$last_reason" == "end_turn" ]] && break
  sleep 0.1
done

[[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || exit 0

access_file="${HOME}/.claude/channels/telegram/access.json"
[[ -r "$access_file" ]] || exit 0
group_chat_id=$(jq -r '(.groups // {}) | keys | .[0] // empty' "$access_file" 2>/dev/null)
[[ -n "$group_chat_id" ]] || exit 0

# Turn analysis: find the latest user-string entry (turn boundary), then
# within that turn pull (a) the 5dive-msg sender label from the envelope
# and (b) the last assistant text block (= the reply marketing/etc sees
# via tmux capture). Picking the LAST text block — not all of them —
# avoids mirroring mid-turn narration ("on it", interim status) that
# isn't the substantive answer.
analysis=$(jq -s '
  (
    [range(0; length)] as $idx
    | [
        $idx[] as $i
        | select(.[$i].type == "user" and (.[$i].message.content | type) == "string")
        | $i
      ]
    | last // 0
  ) as $turn_start
  | .[$turn_start:] as $turn
  | {
      sender: (
        [ $turn[]
          | select(.type == "user")
          | (.message.content | tostring)
          | scan("\\[5dive-msg[[:space:]]+from=([a-z0-9-]+)")
          | .[0]
        ] | last // ""
      ),
      last_text: (
        [ $turn[]
          | select(.type == "assistant")
          | (.message.content // [])
          | map(select(.type == "text") | .text) | join("\n")
          | select(length > 0)
        ] | last // ""
      )
    }
' "$transcript_path" 2>/dev/null)

[[ -z "$analysis" ]] && exit 0

sender=$(printf '%s' "$analysis" | jq -r '.sender // ""')
text=$(printf '%s' "$analysis" | jq -r '.last_text // ""')

[[ -n "$sender" ]] || exit 0
[[ -n "$text" ]] || exit 0

trimmed=$(printf '%s' "$text" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
[[ -n "$trimmed" ]] || exit 0

max_chars="${MIRROR_REPLY_MAX_CHARS:-800}"
if (( ${#trimmed} > max_chars )); then
  body_disp="${trimmed:0:$((max_chars - 1))}…"
  overflow=" (+$(( ${#trimmed} - max_chars )) chars)"
else
  body_disp="$trimmed"
  overflow=""
fi

# Sender label: prefer @bot_username so the mirror line threads visually
# with mirror-agent-send.sh's outbound line (which mentions @receiver_bot).
# Reads in the group as: agent_x_bot says "@y question", agent_y_bot says
# "@x answer" — natural conversation flow. Fall back to bare name if the
# 5dive registry lookup fails for any reason.
sender_label="$sender"
sender_bot=$(sudo -n 5dive --json agent list 2>/dev/null \
  | jq -r --arg n "$sender" '
      (.data // [])[]
      | select(.name == $n)
      | .botUsername // empty
    ' 2>/dev/null \
  | head -1)
[[ -n "$sender_bot" ]] && sender_label="@${sender_bot}"

mirror_text=$(printf '%s %s%s' "$sender_label" "$body_disp" "$overflow")

logger -t stop-mirror "sending mirror sender=$sender bytes=${#mirror_text} chat=${group_chat_id}" 2>/dev/null || true
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${group_chat_id}" \
  --data-urlencode "text=${mirror_text}" \
  -o /dev/null 2>/dev/null || true

exit 0
