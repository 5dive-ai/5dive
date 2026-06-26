#!/usr/bin/env bash
# SessionStart hook — restart-durability "floor" (DIVE-726 Phase 0).
#
# Why: after a service restart / crash / rotation a fresh claude session
# boots with no idea what the previous one was doing. The task queue already
# holds durable cross-session state (any task you have in_progress), and the
# carryover skill writes a dated note into the agent's memory dir — but
# neither is reliably surfaced on boot. This hook injects both as
# additionalContext so a fresh session opens with "you were mid DIVE-X, here's
# where you left off" instead of nothing.
#
# Token-discipline (the Phase-0 hard requirement): output is BOUNDED by
# construction — at most a handful of in_progress task lines plus a pointer to
# (and short head of) the newest carryover. Cost is flat regardless of how
# many tasks/carryovers exist. We inject a pointer, not the whole store.
#
# Wired in $HOME/.claude/settings.json by inc/5dive-cli.sh's
# preseed_claude_agent. Safe to run anywhere: every lookup fails soft.

set -u

# SessionStart fires on startup|resume|clear|compact. Skip 'compact' — the
# model already has the conversation; re-injecting is just wasted tokens.
payload=$(cat 2>/dev/null || true)
source=$(printf '%s' "$payload" | jq -r '.source // "startup"' 2>/dev/null || echo startup)
[ "$source" = "compact" ] && exit 0

ctx=""

# --- 1. in-flight tasks (durable cross-session state) -----------------------
if command -v 5dive >/dev/null 2>&1; then
  tasks=$(5dive task ls --mine --json 2>/dev/null \
    | jq -r '.data.tasks[]? | select(.status=="in_progress")
             | "  - \(.ident): \(.title)"' 2>/dev/null | head -5)
  if [ -n "$tasks" ]; then
    ctx="You have task(s) marked in_progress (assigned to you, carried across this restart):
$tasks

Run \`5dive task show <ident>\` for the full body before resuming, in case you were mid-flight."
  fi
fi

# --- 2. newest carryover note (if the prior session wrote one) --------------
latest=$(ls -t "$HOME"/.claude/projects/*/memory/carryover_*.md 2>/dev/null | head -1)
if [ -n "$latest" ] && [ -r "$latest" ]; then
  head=$(head -20 "$latest" 2>/dev/null)
  ctx="${ctx:+$ctx

}Latest session carryover — $latest (head; read the full file if resuming):
$head"
fi

[ -z "$ctx" ] && exit 0

jq -n --arg c "$ctx" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $c
  }
}'
exit 0
