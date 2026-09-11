#!/usr/bin/env bash
# PreToolUse hook for HEADLESS claude agents — seats with no channel that can
# carry a question to a person (DIVE-4293).
#
# Why this exists at all, given bypassPermissions: bypass skips PERMISSION
# prompts. AskUserQuestion is not a permission prompt — it is a tool the model
# calls ON PURPOSE, and nothing in permissions.deny, no bypass mode and no
# liveness rule touches it. On a seat with a paired channel the telegram
# plugin's own PreToolUse hook bridges the picker to the phone. On a seat
# WITHOUT one the picker renders into a tmux pane nobody is looking at and the
# session sits at "Enter to select" until a human walks past it.
#
# MEASURED 2026-09-11: dev2 (enabledPlugins {}) called AskUserQuestion at
# ~05:40Z and sat on the picker until lodar noticed at 07:12Z — 92 minutes, two
# rows with finished, committed, gate-cleared work waiting on a push.
#
# The guard that existed was folded INTO the telegram plugin (cmd_doctor.sh:940),
# which is precisely the seat where a human CAN answer. This is the same guard
# for the seat where one cannot.
#
# Wired into $HOME/.claude/settings.json by src/lib/agent_setup.sh's
# preseed_claude_agent, only when the seat has no telegram/discord channel.
# Deliberately NOT installed beside the plugin's copy: two PreToolUse denies on
# the same tool would double-fire.

set -u
payload=$(cat)
tool=$(printf "%s" "$payload" | jq -r ".tool_name // empty" 2>/dev/null)

case "$tool" in
  AskUserQuestion|ExitPlanMode)
    jq -n --arg t "$tool" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("No human sits at this keyboard. Take the option you marked Recommended (or the first) and continue; write the alternatives on the task body.\n\nThis seat has no paired channel, so \($t) renders a picker into a tmux pane nobody is reading and the session blocks until someone walks past it. If the choice genuinely needs a person, it is a gate, not a picker: file one with `5dive task need <IDENT> --type=decision --ask=\"...\" --recommend=\"...\" --options=A|B`, which pings the owner and leaves a record. Otherwise proceed on your own recommendation and record the alternatives you did not take in the task body.")
      }
    }'
    ;;
esac

exit 0
