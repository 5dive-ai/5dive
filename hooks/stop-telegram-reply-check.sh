#!/usr/bin/env bash
# Stop hook: catch the "Telegram inbound this turn, no reply tool call" slip
# and auto-relay the assistant's transcript text to the paired chat so the
# user doesn't get silence.
#
# Why: claude agents paired over Telegram sometimes "talk to the transcript"
# instead of calling mcp__plugin_telegram_telegram__reply. The MCP guidance
# is loaded every turn but easy to skim — especially for short answers that
# feel like chat. Prompt-level reminders haven't been enough; this hook is
# the safety net. Auto-relay (vs blocking the Stop and asking the agent to
# retry) means the user always gets *something* even on a one-shot.
#
# Wired in $HOME/.claude/settings.json by inc/5dive-cli.sh's
# preseed_claude_agent only when channels=telegram. Token comes from
# TELEGRAM_BOT_TOKEN, exported into the agent's systemd env from
# /etc/5dive/connectors/telegram-<name>.env.

set -u
payload=$(cat)

# Re-entry guard: if Stop is being re-invoked after a previous block decision
# (stop_hook_active=true means we already fired this turn), don't loop.
stop_active=$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)
[[ "$stop_active" == "true" ]] && exit 0

transcript_path=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
[[ -z "$transcript_path" || ! -r "$transcript_path" ]] && exit 0

# Walk the transcript and analyze the current turn. A turn starts at the
# most-recent entry where type=user AND .message.content is a STRING — that
# pattern is the initial real user/channel prompt (tool_result feedback also
# has type=user but content is an array, so it's excluded). Within the turn:
#   - had_telegram_inbound: any user content (initial OR system-reminder
#     embedded in a tool_result) contains a telegram <channel> block. The
#     channel plugin injects "A message arrived while you were working"
#     system-reminders into tool_results, so mid-turn inbounds count.
#   - had_telegram_tool_call: any assistant tool_use called one of the
#     mcp__plugin_telegram_telegram__{reply,react,edit_message} tools. Any
#     of those satisfies the "something reached Telegram" rule — a pure
#     reaction-only turn (e.g. acking a status ping) is intentional.
#   - last_text: the latest assistant text content in the turn — what we
#     auto-relay if a slip is detected.
#   - last_chat_id: chat_id from the most-recent inbound — the chat the user
#     is waiting on a reply for. Multiple inbounds in one turn (rare) → last
#     one wins.
analysis=$(jq -s --arg tg 'mcp__plugin_telegram_telegram__' '
  # Index of the most-recent string-content user message = turn start.
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
      had_telegram_inbound: (
        [ $turn[]
          | select(.type == "user")
          | (.message.content | tostring)
          | contains("source=\"plugin:telegram:telegram\"")
        ] | any
      ),
      had_telegram_tool_call: (
        [ $turn[]
          | select(.type == "assistant")
          | (.message.content // [])[]?
          | select(.type == "tool_use" and (.name | startswith($tg)))
        ] | length > 0
      ),
      last_text: (
        [ $turn[]
          | select(.type == "assistant")
          | (.message.content // [])
          | map(select(.type == "text") | .text) | join("\n")
          | select(length > 0)
        ] | last // ""
      ),
      last_chat_id: (
        [ $turn[]
          | select(.type == "user")
          | (.message.content | tostring)
          | scan("source=\"plugin:telegram:telegram\" chat_id=\"([0-9]+)\"")
          | .[0]
        ] | last // ""
      )
    }
' "$transcript_path" 2>/dev/null)

[[ -z "$analysis" ]] && exit 0

had_inbound=$(printf '%s' "$analysis" | jq -r '.had_telegram_inbound // false')
had_tool=$(printf '%s' "$analysis" | jq -r '.had_telegram_tool_call // false')
last_text=$(printf '%s' "$analysis" | jq -r '.last_text // ""')
chat_id=$(printf '%s' "$analysis" | jq -r '.last_chat_id // ""')

# Slip conditions: inbound this turn, no tool call back, and we know which
# chat to relay to. Any miss → exit cleanly, no relay.
[[ "$had_inbound" == "true" && "$had_tool" == "false" ]] || exit 0
[[ -n "$chat_id" ]] || exit 0
[[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || exit 0

# Build relay text. Prefix "(auto-relay)" so the user can tell the agent
# slipped (didn't intentionally pick this text to send). Empty transcript
# text → still send a notice, because total silence is worse than admitting
# the slip; an "(auto-relay) [no text]" message is debuggable in journalctl.
trimmed=$(printf '%s' "$last_text" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
if [[ -z "$trimmed" ]]; then
  text="(auto-relay) The agent stopped without sending a Telegram reply and produced no transcript text to relay."
else
  text="(auto-relay) ${trimmed}"
fi

# Telegram caps text at 4096 chars per message; truncate with a marker rather
# than letting the API reject the call silently.
if (( ${#text} > 4000 )); then
  text="${text:0:3960}… [truncated; see journalctl on the host]"
fi

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${chat_id}" \
  --data-urlencode "text=${text}" \
  -o /dev/null 2>/dev/null || true

exit 0
