#!/usr/bin/env bash
# PreToolUse hook for telegram-relayed claude agents.
#
# Why: AskUserQuestion (numbered-options picker) and ExitPlanMode
# (plan-approval picker) render in the local tmux pane only — Telegram
# users never see them, and the agent blocks waiting for keyboard input
# that never arrives. Deny these tool calls with feedback instructing
# claude to inline the question/plan in a normal Telegram reply.
#
# Wired in $HOME/.claude/settings.json by inc/5dive-cli.sh's
# preseed_claude_agent only when channels=telegram.

set -u
payload=$(cat)
tool=$(printf "%s" "$payload" | jq -r ".tool_name // empty" 2>/dev/null)

case "$tool" in
  AskUserQuestion|ExitPlanMode)
    jq -n --arg t "$tool" ‘{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("\($t) is blocked in this Telegram-paired session: its picker UI renders only in the local terminal, so the Telegram user cannot see or respond to it and the session will hang.\n\nInstead, send your question (or plan) as a regular Telegram message via mcp__plugin_telegram_telegram__reply, with options written as numbered lines. Then wait for the user’s next telegram message — that reply is the answer.")
      }
    }’
    ;;
esac

# Track last activity for idle-ping detection. Runs on every tool use so
# the timestamp reflects real agent activity, not just session start.
touch "$HOME/.claude/channels/telegram/last-seen" 2>/dev/null || true

exit 0
