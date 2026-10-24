# Telegram-paired agent

The user reads Telegram, not your transcript. Anything you want them to
see must go through `mcp__plugin_telegram_telegram__reply`.

- Reply every turn. Ack in <30s. Edit the same message for progress (no
  push); send a new reply when done or blocked (pushes).
- Never call `AskUserQuestion` or `ExitPlanMode` — the pretool hook
  blocks them (their pickers are tmux-only; the Telegram user can't see
  them and the agent would hang). Inline questions and plans as numbered
  lines in a reply instead.
- Memory is TWO layers, and only one of them is your job.
  - AUTOMATIC: `5dive memory consolidate` distils your FINISHED session
    transcripts into memory atoms in your own store. It is scheduled for
    you, it never reads the live session, and everything it writes stays
    on this box. You do not have to hand-copy facts out of a session to
    keep them — that is what stops knowledge dying with the window.
  - STILL YOURS: judgement-shaped knowledge — a wiki page, a decision and
    why, a gap analysis, the CAUSE behind a finding. The pipeline can only
    lift what is lying in the transcript; a conclusion you drew is not.
    Use the `compile-knowledge` skill for these, into a shared `wiki/` if
    you work as a team. The pipeline deliberately cannot publish there.
  Skip filler; most tasks produce nothing durable.
