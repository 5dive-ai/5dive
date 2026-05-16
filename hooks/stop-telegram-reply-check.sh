#!/usr/bin/env bash
# Stop hook: catch the "Telegram inbound this turn, no reply tool call" slip
# and either auto-relay the assistant's transcript text, block the Stop so
# the agent retries, or curl a diagnostic — depending on what's in the
# transcript.
#
# Why: claude agents paired over Telegram sometimes "talk to the transcript"
# instead of calling mcp__plugin_telegram_telegram__reply. The MCP guidance
# is loaded every turn but easy to skim — especially for short answers that
# feel like chat. Prompt-level reminders haven't been enough; this hook is
# the safety net.
#
# Decision tree (slip = had_inbound && !had_tool):
#   slip + last_text non-empty       → curl "(auto-relay) <text>"
#   slip + empty text, first time    → JSON {decision:"block"} (agent retries)
#   slip + empty text, re-entry      → curl enriched diagnostic
#
# Loop safety (three layers — any one is sufficient):
#   1. payload.stop_hook_active=true set by the harness on Stop re-invocation
#      after a block. We never emit another block in that path.
#   2. /tmp/5dive-stopblock-<sha1(transcript_path)>.lock written when we
#      block, removed when re-entry runs. Belt-and-suspenders if the
#      harness flag is ever absent — once the lock exists, the empty-text
#      branch falls through to the diagnostic instead of blocking again.
#   3. Block decision is only emitted on the empty-text branch, so a model
#      producing any text will hit auto-relay and never loop.
# Worst case: 2 hook invocations per Stop event, both bounded by timeout: 10.
#
# Wired in $HOME/.claude/settings.json by inc/5dive-cli.sh's
# preseed_claude_agent only when channels=telegram. Token comes from
# TELEGRAM_BOT_TOKEN, exported into the agent's systemd env from
# /etc/5dive/connectors/telegram-<name>.env.

set -u
payload=$(cat)

TG_PREFIX='mcp__plugin_telegram_telegram__'

stop_active=$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)
transcript_path=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
[[ -z "$transcript_path" || ! -r "$transcript_path" ]] && exit 0

lock_key=$(printf '%s' "$transcript_path" | sha1sum | cut -d' ' -f1)
lock_file="/tmp/5dive-stopblock-${lock_key}.lock"

# Stale-lock GC: a lock older than 1h is from a crashed prior run, not a
# live re-entry. Remove so it doesn't suppress a legitimate future block.
if [[ -f "$lock_file" ]]; then
  age=$(( $(date +%s) - $(stat -c %Y "$lock_file" 2>/dev/null || echo 0) ))
  if (( age > 3600 )); then
    rm -f "$lock_file" 2>/dev/null || true
  fi
fi

# Re-entry path: harness flagged stop_hook_active. We blocked the previous
# Stop; now decide whether to send a diagnostic. Read cached state from the
# lock (chat_id, message_id, transcript line count at block time), then scan
# transcript entries past that line count for any telegram tool call. If the
# agent recovered (called reply/react/edit_message), exit silently. If not,
# curl the enriched diagnostic so the user isn't left silent.
if [[ "$stop_active" == "true" ]]; then
  if [[ -f "$lock_file" ]]; then
    cached_line=""
    cached_chat=""
    cached_msg=""
    IFS='|' read -r cached_chat cached_msg cached_line < "$lock_file" 2>/dev/null || true
    rm -f "$lock_file" 2>/dev/null || true

    recovered="false"
    if [[ -n "$cached_line" ]]; then
      recovered=$(tail -n "+$((cached_line + 1))" "$transcript_path" 2>/dev/null \
        | jq -s --arg tg "$TG_PREFIX" '
            [ .[]
              | select(.type == "assistant")
              | (.message.content // [])[]?
              | select(.type == "tool_use" and (.name | startswith($tg)))
            ] | length > 0
          ' 2>/dev/null)
    fi

    if [[ "$recovered" == "true" ]]; then
      exit 0
    fi

    if [[ -n "$cached_chat" && -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
      diag="(auto-relay) Agent stopped without a Telegram reply and produced no transcript text"
      [[ -n "$cached_msg" ]] && diag+=" (unanswered message_id=${cached_msg})"
      diag+=". Retry-after-block already attempted; check journalctl on the host."
      curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${cached_chat}" \
        --data-urlencode "text=${diag}" \
        -o /dev/null 2>/dev/null || true
    fi
  fi
  exit 0
fi

# Normal path: analyze current turn. A turn starts at the most-recent entry
# where type=user AND .message.content is a STRING — that pattern is the
# initial real user/channel prompt (tool_result feedback also has type=user
# but content is an array, so it's excluded). Within the turn:
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
#   - last_chat_id / last_message_id: chat_id and message_id from the
#     most-recent inbound — chat is who we relay to; message_id goes into
#     the block reason / diagnostic so the operator can identify which
#     message went unanswered.
analysis=$(jq -s --arg tg "$TG_PREFIX" '
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
      ),
      last_message_id: (
        [ $turn[]
          | select(.type == "user")
          | (.message.content | tostring)
          | scan("source=\"plugin:telegram:telegram\"[^>]*message_id=\"([0-9]+)\"")
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
message_id=$(printf '%s' "$analysis" | jq -r '.last_message_id // ""')

# Slip conditions: inbound this turn, no tool call back, and we know which
# chat to relay to. Any miss → exit cleanly, no relay.
[[ "$had_inbound" == "true" && "$had_tool" == "false" ]] || exit 0
[[ -n "$chat_id" ]] || exit 0
[[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || exit 0

trimmed=$(printf '%s' "$last_text" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

# Auto-relay path: text exists → send it (prefix "(auto-relay)" so the user
# can tell the agent slipped). Never blocks, never loops.
if [[ -n "$trimmed" ]]; then
  text="(auto-relay) ${trimmed}"
  if (( ${#text} > 4000 )); then
    text="${text:0:3960}… [truncated; see journalctl on the host]"
  fi
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${text}" \
    -o /dev/null 2>/dev/null || true
  exit 0
fi

# Empty-text branch: agent stopped with neither text nor a telegram tool
# call. If a lock file already exists, the harness lost re-entry tracking
# (rare but possible) — fall through to diagnostic instead of blocking
# again. Otherwise emit the block, write the lock with line-count anchor,
# and let the harness re-prompt the model.
if [[ -f "$lock_file" ]]; then
  cached_line=""
  cached_chat=""
  cached_msg=""
  IFS='|' read -r cached_chat cached_msg cached_line < "$lock_file" 2>/dev/null || true
  rm -f "$lock_file" 2>/dev/null || true
  diag_chat="${cached_chat:-$chat_id}"
  diag_msg="${cached_msg:-$message_id}"
  diag="(auto-relay) Agent stopped without a Telegram reply and produced no transcript text"
  [[ -n "$diag_msg" ]] && diag+=" (unanswered message_id=${diag_msg})"
  diag+=". Retry-after-block already attempted; check journalctl on the host."
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${diag_chat}" \
    --data-urlencode "text=${diag}" \
    -o /dev/null 2>/dev/null || true
  exit 0
fi

line_count=$(wc -l < "$transcript_path" 2>/dev/null | tr -d ' ')
printf '%s|%s|%s' "$chat_id" "$message_id" "${line_count:-0}" > "$lock_file" 2>/dev/null || true

reason="You received a Telegram message (chat_id=${chat_id}"
[[ -n "$message_id" ]] && reason+=", message_id=${message_id}"
reason+=") and the turn ended with neither assistant text nor an "
reason+="mcp__plugin_telegram_telegram__{reply,react,edit_message} tool call. "
reason+="Send a reply now before stopping."

jq -n --arg r "$reason" '{decision:"block",reason:$r}'
exit 0
