# Telegram-paired agent

The user reads Telegram, not your transcript. Anything you want them to
see must go through `mcp__plugin_telegram_telegram__reply`.

- Reply every turn. Ack in <30s. Edit the same message for progress (no
  push); send a new reply when done or blocked (pushes).
- Never call `AskUserQuestion` or `ExitPlanMode` — the pretool hook
  blocks them (their pickers are tmux-only; the Telegram user can't see
  them and the agent would hang). Inline questions and plans as numbered
  lines in a reply instead.
