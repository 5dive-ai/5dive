#!/usr/bin/env bash
# PostToolUse hook: retired (intentional no-op).
#
# This used to be a mid-turn safety net that relayed any loose assistant
# transcript text to Telegram after every non-Telegram tool call. The premise
# — "loose mid-turn text is a message the user should see now" — was wrong for
# how these agents actually work: preambles ("let me read the file"), progress
# narration and end-of-turn summaries are all transcript text too, and got
# curled to the user as noise. Worse, because the model emits that narration
# AROUND its real reply, the relayed copy often landed AFTER the answer, which
# defeats the point.
#
# Mid-turn the hook fundamentally can't tell a preamble from a forgotten answer
# (it can't see whether a reply is still coming later in the turn). So all
# relay decisions now live in stop-telegram-reply-check.sh, which sees the
# whole turn and relays transcript text ONLY when no reply/edit_message was
# sent at all — the genuine "talked to the transcript instead of replying"
# miss. Anything the agent wants the user to see goes through the
# mcp__plugin_telegram_telegram__reply / edit_message tools, which reach
# Telegram directly without this hook.
#
# Kept registered (rather than removed from settings.json) so existing agent
# configs that still reference this path don't error on a missing command.
exit 0
