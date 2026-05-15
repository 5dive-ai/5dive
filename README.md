# 5dive CLI

Open-source CLI to spawn, manage, and message AI agents — any model, any machine.

```sh
curl -fsSL https://raw.githubusercontent.com/5dive-com/5dive-cli/main/install.sh | sudo bash
```

---

## What it does

`5dive` is a runtime manager for AI agents. Each agent is a persistent process (Claude, Codex, Gemini, Hermes, openclaw, opencode) running in a tmux session under systemd, with optional Telegram or Discord wiring so you can message it from your phone.

```
5dive agent create my-agent --type=claude
5dive agent send my-agent "summarize the logs in /var/log"
5dive agent ask  my-agent "what's the status of the deploy?" --timeout=60
5dive agent list
5dive agent logs my-agent --follow
```

---

## Quickstart

**1. Install**
```sh
curl -fsSL https://raw.githubusercontent.com/5dive-com/5dive-cli/main/install.sh | sudo bash
```

**2. Add credentials**
```sh
# Claude (Anthropic)
5dive agent auth set claude --api-key sk-ant-...

# or sign in interactively (device code)
5dive agent auth login claude
```

**3. Create an agent**
```sh
5dive agent create my-agent --type=claude
```

**4. Talk to it**
```sh
5dive agent send my-agent "hello"
5dive agent ask  my-agent "what model are you?"
```

**5. Attach to the live session**
```sh
5dive agent my-agent tui
```

---

## Supported agent types

| Type | Model family | Auth method |
|------|-------------|-------------|
| `claude` | Anthropic Claude | OAuth / API key |
| `codex` | OpenAI Codex | OAuth |
| `gemini` | Google Gemini | OAuth |
| `hermes` | Nous Hermes | API key |
| `openclaw` | OpenClaw | OAuth |
| `opencode` | OpenCode | API key |

---

## Agent commands

```
5dive agent list
5dive agent create <name> --type=<type> [--channels=none|telegram|discord]
                          [--telegram-token=<token>] [--discord-token=<token>]
                          [--with-skills=<spec>] [--no-skills]
5dive agent clone  <src> <dst>
5dive agent start  <name>
5dive agent stop   <name>
5dive agent restart <name>
5dive agent rm     <name>
5dive agent send   <name> <text...>
5dive agent ask    <name> <text...> [--timeout=120]
5dive agent logs   <name> [--follow] [--lines=N]
5dive agent stats  <name>
5dive agent <name> tui
```

---

## Telegram / Discord channels

Agents can accept messages directly from Telegram or Discord bots:

```sh
5dive agent create my-agent --type=claude --channels=telegram --telegram-token=<bot-token>
5dive agent pair my-agent --code=<pairing-code>
```

---

## Isolation tiers

Control what each agent can access on the host:

| Tier | What it can do |
|------|---------------|
| `admin` | Full host access |
| `standard` | Read shared files, limited write |
| `sandboxed` | Private isolated space only |

```sh
5dive agent create my-agent --type=claude --isolation=sandboxed
```

---

## Skills

Skills are `SKILL.md` prompt bundles that drop into any agent. Install one or more at create time:

```sh
5dive agent create my-agent --type=claude --with-skills=notify-user,5dive-cli
```

Browse community skills: [github.com/5dive-com/skills](https://github.com/5dive-com/skills)

---

## Accounts (shared auth profiles)

Group sign-ins so multiple agents share one login:

```sh
5dive account add work
5dive account login work --type=claude
5dive agent create agent-a --type=claude --auth-profile=work
5dive agent create agent-b --type=claude --auth-profile=work
```

---

## Health check

```sh
5dive doctor
5dive doctor --repair   # attempt auto-fixes
5dive doctor --json     # machine-readable output for CI
```

---

## Managed platform

[5dive.com](https://5dive.com) is a managed cloud that runs this CLI on provisioned VMs — adds a web dashboard, team access, cloud infrastructure, and uptime management on top of the same runtime.

---

## Requirements

- Linux (Ubuntu 22.04+ recommended)
- `bash` 5+, `jq`, `tmux`, `systemd`
- Root access for install

---

## License

MIT — see [LICENSE](LICENSE)
