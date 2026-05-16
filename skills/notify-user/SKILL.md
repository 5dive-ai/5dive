---
name: notify-user
description: Send progress, completion, and option-prompt messages to the paired user via this agent's Telegram bot. Use whenever work takes more than a few seconds, when blocking on a user decision, or when presenting choices. Never go silent for more than ~30s on a long-running task.
---

# notify-user

This agent runs as a 5dive Telegram-channel agent. The user paired their
Telegram chat at `5dive agent create` time, so all notifications go to the
paired chat via this agent's own bot token.

## Cadence

- **Start**: send a short "on it" message immediately.
- **Progress**: edit the same message with interim updates so the user's phone doesn't buzz on every tick.
- **Done**: send a **new** reply with the result. New messages trigger push notifications; edits do not.

## Presenting choices

When offering options, **always** use Telegram inline-keyboard buttons — never a plain text list. Each option is one button the user can tap to respond.

The `reply` MCP tool only supports plain text. For buttons, hit the Bot API directly with `curl`.

- `BOT_TOKEN` is already in your environment as `$TELEGRAM_BOT_TOKEN` (the
  systemd unit loads `/etc/5dive/connectors/telegram-<agent>.env`).
- `CHAT_ID` → first entry of `allowFrom` in `~/.claude/channels/telegram/access.json`.

```bash
CHAT_ID=$(jq -r '.allowFrom[0]' ~/.claude/channels/telegram/access.json)
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="${CHAT_ID}" \
  -d text="Pick one:" \
  --data-urlencode reply_markup='{"inline_keyboard":[[{"text":"Option A","callback_data":"a"},{"text":"Option B","callback_data":"b"}]]}'
```
