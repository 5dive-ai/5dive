# 5dive

[![install-smoke](https://github.com/5dive-com/5dive/actions/workflows/install-smoke.yml/badge.svg)](https://github.com/5dive-com/5dive/actions/workflows/install-smoke.yml)
[![bundle-drift](https://github.com/5dive-com/5dive/actions/workflows/bundle-drift.yml/badge.svg)](https://github.com/5dive-com/5dive/actions/workflows/bundle-drift.yml)
[![Latest release](https://img.shields.io/github/v/release/5dive-com/5dive)](https://github.com/5dive-com/5dive/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

spawn and manage AI agents that talk to each other.

> MIT. The same binary that runs every agent on [5dive.com](https://5dive.com). No open-core split. Skip the ops with the managed VM, or run your own.

---

## Quickstart

```sh
# 1. install
curl -fsSL https://install.5dive.com | sudo bash

# 2. create your first agent (optional interactive wizard)
5dive init
```

Talk to an agent from your phone. Wire it to a Telegram bot ([BotFather](https://t.me/BotFather) gives you the token):

```sh
5dive agent create my-agent --type=claude --channels=telegram --telegram-token=<token>
5dive agent pair   my-agent --code=<pairing-code>
```

For scripted / CI setup, see `5dive init --help`.

---

## How it works

Each agent is its own Linux user running an official agentic AI CLI (`claude`, `codex`, `antigravity`, `grok`, …) as a systemd service. Multiple agents can share the same CLI binary and subscription. Agents reach each other by invoking the same `5dive` CLI — that *is* the bus. Channels like Telegram attach per agent.

```text
            one host
 ┌──────────────────────────────────┐
 │  coder      writer       pm      │
 │ (claude)   (codex)     (claude)  │
 │    │          │           │      │
 │    └────  5dive CLI  ─────┘      │
 │       send · ask · logs          │
 └──────────────────────────────────┘
        ↕ Telegram / Discord
        (attach per agent)
```

No broker, no protocol, no orchestrator. Shared filesystem, shared CLI.

---

## Why 5dive

**A team that works without you.** Multiple agents on one host, coordinating with each other.

**Runs as a service, not a session.** Your agents stay alive when you close the terminal. Message them from Telegram any time.

**Every major agentic AI CLI.** `claude`, `codex`, `antigravity`, `grok`, `hermes`, `openclaw`, `opencode`, all under one team.

**A subscription that's yours.** Official `claude` CLI on your own Pro/Max. No middleman, no OAuth proxy, Anthropic-policy safe.

**Safe by default.** Each agent is its own Linux user under one of three isolation tiers. Sandbox an agent and it can't read your home dir or sudo your box.

---

## Want a dashboard?

The CLI is the OSS surface. Every verb here, every agent, every host, all driven from `/usr/local/bin/5dive`.

If you'd rather click than `ssh`, [5dive.com](https://5dive.com) is the managed version: same CLI under the hood, but the VM, hardening, backups, and dashboard are run for you.

<video src="https://cdn.jsdelivr.net/gh/5dive-com/assets@main/hero-demo.mp4" autoplay loop muted playsinline width="100%"></video>

---

## Agent types

| Type | Model family | Auth | Channels |
|------|-------------|------|----------|
| `claude`      | Anthropic Claude       | OAuth / API key | Telegram, Discord |
| `codex`       | OpenAI Codex           | OAuth / API key | — |
| `antigravity` | Google Antigravity     | Google OAuth | — |
| `grok`        | xAI Grok               | OAuth (xAI) / API key | — |
| `hermes`      | third-party multi-provider harness | OAuth (OpenAI) / API key | Telegram, Discord |
| `openclaw`    | third-party multi-provider harness | OAuth (OpenAI) / API key | Telegram, Discord |
| `opencode`    | OpenCode               | API key | — |

`hermes` and `openclaw` are community-built harnesses that can route to many providers (OpenRouter, Anthropic, Google, Moonshot, etc.). As of April 4, 2026, Anthropic no longer permits routing consumer Claude Pro/Max OAuth through third-party harnesses. For that work, use the official `claude` type with your own API key. Background: [We Ditched OpenClaw for Claude →](https://blog.5dive.com/blog/we-ditched-openclaw-for-claude/).

---

## Commands at a glance

```
5dive agent list / create / start / stop / restart / rm
5dive agent send <name> <text>
5dive agent ask  <name> <text> [--timeout=120]
5dive agent logs <name> [--follow]
5dive agent <name> tui

5dive account   add / login / list / show / rename / remove
5dive auth      set / login / status     # lower-level; account is the human path
5dive skill     add / list / remove
5dive doctor [--repair] [--json]
5dive watch                              # htop-style live view
5dive compose up / down / ps             # declarative agents via 5dive.yaml
```

Full flag reference: `5dive --help` (or `5dive <verb> --help`). Machine-readable output on any command via `--json`.

---

## Accounts (shared auth profiles)

One sign-in, many agents:

```sh
5dive account add   work
5dive account login work --type=claude
5dive agent create agent-a --type=claude --auth-profile=work
5dive agent create agent-b --type=claude --auth-profile=work
```

Rename or rotate the account, every bound agent rebinds automatically.

---

## Isolation tiers

| Tier | Access |
|------|--------|
| `admin` (default) | full host |
| `standard` | shared read, limited write |
| `sandboxed` | own home only, no sudo, systemd resource limits |

```sh
5dive agent create my-agent --type=claude --isolation=sandboxed
```

---

## No middlemen

5dive runs on your server. Auth tokens go to model providers directly, never to us. No telemetry, no error reporting, no usage data leaves the box. Each agent is one Linux user with its own login.

Long form: [your auth tokens don't touch us →](https://blog.5dive.com/blog/your-auth-tokens-dont-touch-us/).

---

## Securing your server

5dive runs agents with shell access. Standard hygiene applies:

- patch the OS (`unattended-upgrades`)
- SSH key-only, no root login
- firewall default-deny
- per-agent isolation tiers
- Telegram bot allowlists

Baselines: [devsec.os_hardening](https://github.com/dev-sec/ansible-collection-hardening) · [Lynis](https://github.com/CISOfy/lynis) · [fail2ban](https://www.fail2ban.org/). Or skip the checklist; [5dive.com](https://5dive.com) handles it.

---

## Other paths

**[Docker](docker/README.md).** Kick the tires without a host install:
```sh
docker build -f docker/Dockerfile -t 5dive .
docker run -d --name 5dive-demo --privileged 5dive
docker exec -it 5dive-demo bash
```

**Offline / air-gapped.** `install.sh` reads from `$REPO` (default GitHub raw). Override with `REPO=file:///path/to/local/tree` and pre-install apt deps. The fetched files are listed at the top of `install.sh`.

**Context rot.** Long sessions degrade. Restart daily via cron:
```cron
0 4 * * * curl -fsSL https://install.5dive.com | bash -s -- --upgrade && systemctl restart '5dive-agent@*.service'
```
Claude-runtime agents keep project memory under `~/.claude/projects/<dir>/memory/` across restarts. Session resets, knowledge stays.

---

## For your AI agent

If you already use Claude Code / Codex / Antigravity / Grok / opencode, paste this prompt. Your agent installs 5dive, learns the skill, then keeps managing agents through chat:

```
Install 5dive on this Linux host so I can use you to manage 5dive agents.

1. Run the installer (idempotent, safe to rerun):
   curl -fsSL https://install.5dive.com | sudo bash
2. Confirm: `5dive --version` prints "5dive 0.1.x".
3. Install the 5dive-cli skill. Replace <runtime> with one of
   claude-code, codex, antigravity, grok, hermes-agent, openclaw, opencode:
   npx -y skills add https://github.com/5dive-com/skills --skill 5dive-cli --agent <runtime> --yes
4. Tell me to restart so the skill loads, then ask which agent to create first.
```

**Installing onto a remote VM over SSH?** Same prompt, prefix the install line with `ssh -t <user@host>`. Install the skill on the laptop where you're issuing `ssh` from, not the remote. Use `ssh -t` for anything needing a TTY (e.g. `5dive agent auth login`).

### JSON output

Every command accepts `--json`. Output is `{ok:true,data:...}` on success or `{ok:false,error:{code,class,message}}` on failure. Exit code matches `error.code` so shell pipelines branch without parsing. Progress lines stay on stderr; stdout is always valid JSON.

```json
{ "ok": true,  "data": [ {"name": "main", "type": "claude", "active": "active"} ] }
{ "ok": false, "error": { "code": 4, "class": "not_found", "message": "no agent named 'foo'" } }
```

---

## Requirements

- Linux with `systemd` (Ubuntu 22.04+ recommended)
- root for install (installer apt-installs `jq`, `tmux`, and other deps)

No systemd / no root / not Linux? Use the [Docker image](#other-paths).

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The `5dive` bundle at the repo root is built from `src/` via `./build.sh`; CI enforces no drift.

---

## Reporting a vulnerability

Use GitHub's private reporting: **[Report a vulnerability →](https://github.com/5dive-com/5dive/security/advisories/new)**. Don't open a public issue. We acknowledge within 3 business days. Scope is the `5dive` CLI, `install.sh`, shipped systemd units, and `5dive-com/*` workflows; upstream coding CLIs (`claude`, `codex`, ...) and apt/Node go to their respective maintainers.

---

## License

MIT. See [LICENSE](LICENSE).
