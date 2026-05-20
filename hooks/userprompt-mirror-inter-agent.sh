#!/usr/bin/env bash
# UserPromptSubmit hook: mirror an inbound 5dive inter-agent message
# ([5dive-msg from=X id=Y] envelope) into the shared Telegram group so the
# operator can watch agent-to-agent traffic alongside their own DMs.
#
# Receiver-side companion to stop-mirror-inter-agent.sh. Together they put
# both halves of an inter-agent exchange in the group chat: this hook posts
# the inbound question/handoff at turn-start; stop-mirror posts the reply
# at turn-end.
#
# Why receiver-side (replacing the previous PreToolUse Bash mirror on the
# sender): the old hook read the raw command string of `5dive agent send|ask`
# BEFORE the shell expanded it. Agents naturally build long bodies via
# heredoc — `5dive agent send X "$(cat <<EOF...EOF)"` — and the old hook saw
# the literal "$(cat <<EOF" text and skipped to avoid posting garbage. Net
# result: every long inter-agent message was invisible in the group.
#
# Receiver-side fires on the post-expansion envelope (Claude Code already
# received the fully expanded prompt via tmux), so quoting, heredoc, and
# shell substitution are no longer a concern.
#
# Skip cases (any → exit 0):
#   - No token, or no group in access.json
#   - Prompt isn't a [5dive-msg from=X id=Y] envelope (= a regular user msg)
#   - Sender name can't be parsed
#
# Truncation: MIRROR_MAX_BODY_CHARS (default 800), matching the other mirror
# hooks, with a "+N chars" overflow indicator.
#
# Wired in $HOME/.claude/settings.json by lib/agent_setup.sh's
# preseed_claude_agent when channels=telegram. Token from TELEGRAM_BOT_TOKEN
# in the agent's systemd env (see /etc/5dive/connectors/telegram-<name>.env).

set -u
# Journal breadcrumb so a missing inbound mirror can be distinguished from a
# hook that never fired (settings.json wiring problem). Followed by an
# end-state line near the curl call so the journal shows fired→sent or
# fired→skip.
logger -t userprompt-mirror "fired pid=$$ user=$(id -un 2>/dev/null) hook=userprompt-mirror-inter-agent" 2>/dev/null || true
payload=$(cat)

prompt=$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null)
[[ -z "$prompt" ]] && exit 0

# Envelope shape: [5dive-msg from=<name> id=<hex>] <body...>
# The CLI's send/ask path wraps every inter-agent message in this prefix
# (see cmd_agent.sh format_inter_agent_envelope), so its absence means the
# prompt is a regular human user message — nothing to mirror.
if ! [[ "$prompt" =~ ^\[5dive-msg[[:space:]]+from=([a-z0-9-]+)[[:space:]]+id=[a-f0-9]+\][[:space:]]*(.*)$ ]]; then
  exit 0
fi
sender="${BASH_REMATCH[1]}"
body="${BASH_REMATCH[2]}"

[[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || exit 0

access_file="${HOME}/.claude/channels/telegram/access.json"
[[ -r "$access_file" ]] || exit 0
group_chat_id=$(jq -r '(.groups // {}) | keys | .[0] // empty' "$access_file" 2>/dev/null)
[[ -n "$group_chat_id" ]] || exit 0

trimmed=$(printf '%s' "$body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
[[ -n "$trimmed" ]] || exit 0

max_chars="${MIRROR_MAX_BODY_CHARS:-800}"
if (( ${#trimmed} > max_chars )); then
  body_disp="${trimmed:0:$((max_chars - 1))}…"
  overflow=" (+$(( ${#trimmed} - max_chars )) chars)"
else
  body_disp="$trimmed"
  overflow=""
fi

# Directional mirror format: "@from → @to\nbody". Both the inbound (this
# hook) and the reply (stop-mirror-inter-agent.sh) post via THIS agent's
# bot — there's no sender-side mirror — so without an explicit arrow the
# group sees two consecutive messages from the same bot and can't tell
# which is incoming vs outgoing. The arrow makes direction unambiguous
# regardless of which bot Telegram shows as the poster. The group reads:
#   @marketing_bot → @main_bot \n draft the blog post...  (inbound, this hook)
#   @main_bot → @marketing_bot \n here are the notes...   (reply, stop-mirror)
# Bare-name fallback on either side if the 5dive registry lookup fails.
lookup_bot() {
  sudo -n 5dive --json agent list 2>/dev/null \
    | jq -r --arg n "$1" '
        (.data // [])[]
        | select(.name == $n)
        | .botUsername // empty
      ' 2>/dev/null \
    | head -1
}

sender_label="$sender"
sender_bot=$(lookup_bot "$sender")
[[ -n "$sender_bot" ]] && sender_label="@${sender_bot}"

me=$(id -un 2>/dev/null | sed 's/^agent-//')
me_label="$me"
me_bot=$(lookup_bot "$me")
[[ -n "$me_bot" ]] && me_label="@${me_bot}"

mirror_text=$(printf '%s → %s\n%s%s' "$sender_label" "$me_label" "$body_disp" "$overflow")

logger -t userprompt-mirror "sending mirror sender=$sender bytes=${#mirror_text} chat=${group_chat_id}" 2>/dev/null || true
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${group_chat_id}" \
  --data-urlencode "text=${mirror_text}" \
  -o /dev/null 2>/dev/null || true

exit 0
