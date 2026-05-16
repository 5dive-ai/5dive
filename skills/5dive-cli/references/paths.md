# On-disk state — for debugging only

The CLI manages every path here. Don't edit them by hand.

| Path                                              | What                                                              |
| ------------------------------------------------- | ----------------------------------------------------------------- |
| `/var/lib/5dive/agents.json`                      | Agent registry (versioned). Source of truth for `agent list`.     |
| `/var/lib/5dive/agents.d/<name>.env`              | Per-agent systemd `EnvironmentFile`.                              |
| `/var/lib/5dive/auth-profiles/<name>/`            | Named auth profile env files + captured CLI config.               |
| `/var/lib/5dive/auth-sessions/<id>/`              | Live device-code session state (poll / submit / cancel).          |
| `/etc/5dive/connectors/<type>.env`                | Shared auth env (default profile). e.g. `anthropic.env`.          |
| `/etc/5dive/connectors/telegram-<name>.env`       | Per-agent Telegram bot token.                                     |
| `/etc/5dive/connectors/discord-<name>.env`        | Per-agent Discord bot token.                                      |
| `/etc/systemd/system/5dive-agent@.service`        | Templated systemd unit. One instance per agent.                   |
| `/var/log/5dive/agent-audit.log`                  | NDJSON audit trail of every mutating CLI invocation.              |
| `/home/agent-<name>/`                             | Agent's home dir. `~/.claude/skills/<id>/` holds installed skills.|
| `/home/agent-<name>/.claude/channels/<ch>/access.json` | Pairing allow-list for telegram/discord.                     |

## Diagnostic one-liners

```bash
# Which agents are registered?
sudo jq '.agents | keys' /var/lib/5dive/agents.json

# Why did agent-foo crash recently?
sudo journalctl -u 5dive-agent@foo --since "10 min ago"

# What did the dashboard do in the last hour?
sudo tail -n 200 /var/log/5dive/agent-audit.log | jq .
```
