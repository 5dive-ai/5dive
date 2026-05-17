# 5dive hooks

Claude Code hooks installed into `/usr/local/lib/5dive/` by `install.sh` and
wired into a new agent's `~/.claude/settings.json` by `preseed_claude_agent`
in the bundle. All four are claude-only and only get wired when the agent's
`channels=telegram` — they fix specific failure modes that show up when a
claude agent's only output channel is a Telegram chat.

| File | Hook event | What it fixes |
| --- | --- | --- |
| `pretool-telegram-question.sh` | `PreToolUse` | Denies `AskUserQuestion` and `ExitPlanMode`. Both render numbered-option pickers in the local tmux pane only — a Telegram user never sees them, and the agent blocks forever waiting on keyboard input. The hook tells claude to inline the question as a normal Telegram reply instead. |
| `stop-telegram-reply-check.sh` | `Stop` | Catches the "got a Telegram message this turn, didn't call `mcp__plugin_telegram_telegram__reply`" slip — the agent thought it answered but only wrote to the transcript. Three branches: relay the transcript text to Telegram, block the Stop so the agent retries, or send a diagnostic. Loop-safe via three independent guards. |
| `stop-failure-telegram.sh` | `StopFailure` | Relays failure details to the paired chat. On rate-limit specifically: auto-presses "1" (wait) on the blocking tmux prompt and spawns `resume-after-reset.sh` so the session wakes itself when the limit clears. |
| `resume-after-reset.sh` | — (helper) | Not a hook — spawned detached by `stop-failure-telegram.sh`. Sleeps until the parsed reset epoch, sends `continue` + Enter to the original tmux pane, then pings Telegram so the user knows the agent is back. |

## Lifecycle

```
agent create … --channels=telegram --type=claude
        │
        ▼
preseed_claude_agent (in 5dive bundle)
        │
        ├─ writes ~/.claude/settings.json with hook paths pointing at /usr/local/lib/5dive/
        └─ writes /etc/5dive/connectors/telegram-<agent>.env with TELEGRAM_BOT_TOKEN

5dive-agent@<name>.service exports the connector env, then starts claude.
Hooks fire on every PreToolUse / Stop / StopFailure within that session.
```

## Editing

Edit the file in `hooks/` and commit — `install.sh` curls these from `$REPO`
on every install/upgrade, so the next `5dive agent create` (or
`install.sh --upgrade` on an existing host) picks up the change. Existing
agents keep running the version on disk until their host runs upgrade.

There is no per-agent override path — these are global hooks. If you need
agent-specific behavior, branch on environment variables the connector env
file exports, not on file paths.
