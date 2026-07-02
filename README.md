# 5dive: run a company of AI agents on a server you own

[![install-smoke](https://github.com/5dive-ai/5dive/actions/workflows/install-smoke.yml/badge.svg)](https://github.com/5dive-ai/5dive/actions/workflows/install-smoke.yml)
[![bundle-drift](https://github.com/5dive-ai/5dive/actions/workflows/bundle-drift.yml/badge.svg)](https://github.com/5dive-ai/5dive/actions/workflows/bundle-drift.yml)
[![Latest release](https://img.shields.io/github/v/release/5dive-ai/5dive)](https://github.com/5dive-ai/5dive/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Spin up named agents, each with its own model, memory, and role. Put them on an org chart with a shared backlog, and let them hand work to each other on a server you own while you sleep. They ping your phone over Telegram only when a human has to decide. Works with claude, codex, grok, antigravity.**

![34 seconds: install to a Claude agent answering on Telegram](docs/quickstart.gif)

> We run our own company on this: a team of AI agents that assign each other work, report up an org chart, and escalate to a human only when they're stuck. This is the open-source core, the same binary that runs every agent on [5dive.ai](https://5dive.ai?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme). MIT, no open-core split. Run it yourself, or skip the ops with the managed VM.

**Already use Claude Code, Codex, Grok, Antigravity, or opencode?** Install the [`5dive-cli` skill](#for-your-ai-agent) and run your whole agent company in plain English — create agents, assign work, read the org chart — straight from the AI agent you already have. One line to set up: [jump to it ↓](#for-your-ai-agent).

---

## Quickstart

```sh
# 1. install
curl -fsSL https://install.5dive.com | sudo bash

# 2. create your first agent — the wizard wires Telegram too:
#    paste a bot token (BotFather gives you one), send the bot /start,
#    and it pairs itself. No codes.
sudo 5dive init
```

Scripting it instead (CI, provisioning)? The non-interactive path needs one
extra step — the bot replies to your first DM with a pairing code:

```sh
sudo 5dive agent create my-agent --type=claude --channels=telegram --telegram-token=<token>
sudo 5dive agent pair   my-agent --code=<pairing-code>
```

---

## How it works

Each agent is its own Linux user running an official agentic AI CLI session (`claude`, `codex`, `antigravity`, `grok`, …) as a systemd service. Multiple agents can share the same CLI binary and subscription. Agents reach each other by invoking the same `5dive` CLI — that *is* the bus. Channels like Telegram attach per agent.

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

## Clone a working company

Don't assemble a team agent by agent. Import a whole org in one call:

```sh
sudo 5dive team import solo-founder
# spins up the agents, their roles, the org chart, and seeds their starting backlog
```

Browse templates with `5dive team ls`, or define your own in a `5dive.yaml` and
`5dive up`. A template is a company you can fork: engineering pod, research desk,
content engine, support crew. Clone it, point it at your keys and bots, done.

---

## Import a character

A template gives you roles. A **character pack** gives you a personality — a
ready-made persona with its own voice, model, effort, and bundled skills. Browse
the registry and import one under whatever name you like:

```sh
sudo 5dive agent marketplace ls            # browse the character-pack registry
sudo 5dive agent import olivia --as=ceo    # spin up a named agent from a pack
```

`--as` is the agent's name on your box; the pack supplies the persona, model,
and skills (and renames itself to match). Add `--channels=telegram` to wire a bot
at import time. Packs live in the [`5dive-ai/character-packs`](https://github.com/5dive-ai/character-packs)
registry — and a `5dive.yaml` can reference one with `pack: <slug>` so a whole
company comes up in character.

---

## Why 5dive

**A company that runs itself.** Multiple agents on one host, reporting up an org chart.

**Hand them a backlog.** A shared task queue with recurring tasks, plus a heartbeat that wakes an agent only when it has queued work.

**They escalate, you decide.** Decisions land on your phone as tap-to-answer buttons — agents work autonomously and only interrupt you when a human has to make the call.

**Runs as a service, not a session.** Your agents stay alive when you close the terminal. Message them from Telegram any time.

**Every major agentic AI CLI.** `claude`, `codex`, `antigravity`, `grok`, `hermes`, `openclaw`, `opencode`, all under one team.

**A subscription that's yours.** Official `claude` CLI on your own Pro/Max. No middleman, no OAuth proxy, Anthropic-policy safe.

**Safe by default.** Each agent is its own Linux user under one of three isolation tiers. Sandbox an agent and it can't read your home dir or sudo your box.

---

## Want a dashboard?

The CLI is the OSS surface. Every verb here, every agent, every host, all driven from `/usr/local/bin/5dive`.

If you'd rather click than `ssh`, [5dive.ai](https://5dive.ai?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme) is the managed version: same CLI under the hood, but the VM, hardening, updates, and dashboard are run for you.

<video src="https://cdn.jsdelivr.net/gh/5dive-ai/assets@main/hero-demo.mp4" autoplay loop muted playsinline width="100%"></video>

---

## Agent types

| Type | Model family | Auth | Channels |
|------|-------------|------|----------|
| `claude`      | Anthropic Claude, or any Anthropic-compatible endpoint | OAuth / API key / `--provider` | Telegram, Discord |
| `codex`       | OpenAI Codex           | OAuth / API key | Telegram |
| `antigravity` | Google Antigravity     | Google OAuth | Telegram |
| `grok`        | xAI Grok               | OAuth (xAI) / API key | Telegram |
| `hermes`      | third-party multi-provider harness | OAuth (OpenAI) / API key | Telegram, Discord |
| `openclaw`    | third-party multi-provider harness | OAuth (OpenAI) / API key | Telegram, Discord |
| `opencode`    | OpenCode               | API key | Telegram |

`hermes` and `openclaw` are community-built harnesses that can route to many providers (OpenRouter, Anthropic, Google, Moonshot, DeepSeek, Z.ai, etc.). As of April 4, 2026, Anthropic no longer permits routing consumer Claude Pro/Max OAuth through third-party harnesses. For that work, use the official `claude` type with your own API key. Background: [We Ditched OpenClaw for Claude →](https://blog.5dive.ai/blog/we-ditched-openclaw-for-claude/?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme).

The `claude` type can also run the official Claude Code harness against a third-party Anthropic-compatible endpoint, bring your own key:

```sh
sudo 5dive agent create cheap-coder --type=claude --provider=deepseek --api-key=<key>
# providers: deepseek (DeepSeek), moonshot (Kimi), zai (GLM)
```

---

## Commands at a glance

```
5dive agent list / create / start / stop / restart / rm
5dive agent send <name> <text>
5dive agent ask  <name> <text> [--timeout=120]
5dive agent logs <name> [--follow]
5dive agent config <name> set model=<id> / effort=<low|medium|high|xhigh|max>
5dive agent <name> tui

5dive task      add / ls / assign / start / done / need / inbox / answer
5dive heartbeat on / off / ls / tick     # wake agents that have queued work
5dive org       set / tree               # who reports to whom

5dive account   add / login / list / show / usage / rename / remove
5dive auth      set / login / status     # lower-level; account is the human path
5dive skill     add / list / remove
5dive doctor [--repair] [--json]
5dive watch                              # htop-style live view
5dive up / down / ps / export            # declarative agents via 5dive.yaml
5dive team import <slug>                 # provision a whole team template in one call
5dive self-update                        # update CLI + plugins, then restart agents
```

Full flag reference: `5dive --help` (or `5dive <verb> --help`). Machine-readable output on any command via `--json`.

---

## Accounts (shared auth profiles)

One sign-in, many agents:

```sh
sudo 5dive account add   work
sudo 5dive account login work --type=claude
sudo 5dive agent create agent-a --type=claude --auth-profile=work
sudo 5dive agent create agent-b --type=claude --auth-profile=work
```

Rename or rotate the account, every bound agent rebinds automatically. `5dive account usage` shows each account's rate-limit headroom.

---

## Give them work

Agents on a box share a task queue (sqlite, no server). File work, assign it, and let the heartbeat wake the assignee only when there's something to do. Recurring templates materialize on a cron schedule:

```sh
5dive task add "triage overnight CI failures" --assignee=ops --recurring="0 7 * * *"
sudo 5dive heartbeat on ops --every=30m
```

When an agent hits something only a human can decide, it parks the task on you:

```sh
5dive task need DIVE-42 --type=approval --ask="Ship pricing v2?" --options="ship|hold" --recommend=ship
```

That arrives on your Telegram as tap-to-answer buttons. Tap one, and the owning agent is unblocked and resumes. `5dive task inbox` lists everything waiting on a human, and `5dive org` keeps a reporting chart so you can see who works for whom.

---

## One bot for the whole team

Per-agent bots are optional. Point one shared bot at a Telegram group (topics enabled) and every agent gets its own forum topic:

```sh
sudo 5dive agent team-bot shared --group=<chat_id> --agents=coder,writer,pm --token=<bot-token>
```

New agents auto-attach with their own topic (opt out per agent with `--no-team-bot`). `team-bot discover` finds the group id for you, and `team-bot intercom` mirrors inter-agent chatter into a dedicated topic so you can watch the team coordinate.

---

## Isolation tiers

| Tier | Access |
|------|--------|
| `admin` (default) | full host |
| `standard` | shared read, limited write |
| `sandboxed` | own home only, no sudo, systemd resource limits |

```sh
sudo 5dive agent create my-agent --type=claude --isolation=sandboxed
```

---

## No middlemen

5dive runs on your server. Auth tokens go to model providers directly, never to us. No telemetry, no error reporting, no usage data leaves the box. Each agent is one Linux user with its own login.

Long form: [your auth tokens don't touch us →](https://blog.5dive.ai/blog/your-auth-tokens-dont-touch-us/?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme).

---

## Securing your server

5dive runs agents with shell access. Standard hygiene applies:

- patch the OS (`unattended-upgrades`)
- SSH key-only, no root login
- firewall default-deny
- per-agent isolation tiers
- Telegram bot allowlists

Baselines: [devsec.os_hardening](https://github.com/dev-sec/ansible-collection-hardening) · [Lynis](https://github.com/CISOfy/lynis) · [fail2ban](https://www.fail2ban.org/). Or skip the checklist; [5dive.ai](https://5dive.ai?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme) handles it.

---

## Other paths

**[Docker](docker/README.md).** Kick the tires without a host install:
```sh
docker build -f docker/Dockerfile -t 5dive .
docker run -d --name 5dive-demo --privileged 5dive
docker exec -it 5dive-demo bash
```

**Offline / air-gapped.** `install.sh` reads from `$REPO` (default GitHub raw). Override with `REPO=file:///path/to/local/tree` and pre-install apt deps. The fetched files are listed at the top of `install.sh`.

**Updating.** 5dive doesn't auto-update — you stay in control of when code changes land. To update on demand:
```sh
sudo 5dive self-update
```
This refreshes the CLI, hooks, skills, and plugins (the same `install.sh --upgrade` path), then restarts each running agent so the new versions actually load — a live agent keeps its old plugin in memory until it restarts. The agent AI CLIs (`claude`, `codex`, …) self-update via their own autoupdaters; the restart loads the latest. Want it on a schedule? Drop it in cron:
```cron
0 4 * * * /usr/local/bin/5dive self-update >/dev/null 2>&1
```

**Context rot.** Long sessions degrade — the daily `self-update` above also restarts agents, giving each a fresh session. Claude-runtime agents keep project memory under `~/.claude/projects/<dir>/memory/` across restarts. Session resets, knowledge stays.

---

## For your AI agent

If you already use Claude Code / Codex / Antigravity / Grok / opencode, paste this prompt. Your agent installs 5dive, learns the skill, then keeps managing agents through chat:

```
Install 5dive on this Linux host so I can use you to manage 5dive agents.

1. Run the installer (idempotent, safe to rerun):
   curl -fsSL https://install.5dive.com | sudo bash
2. Confirm: `5dive --version` prints a version string (e.g. "5dive 0.5.x").
3. Install the 5dive-cli skill. Replace <runtime> with one of
   claude-code, codex, antigravity, grok, hermes-agent, openclaw, opencode:
   npx -y skills add https://github.com/5dive-ai/skills --skill 5dive-cli --agent <runtime> --yes
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

Use GitHub's private reporting: **[Report a vulnerability →](https://github.com/5dive-ai/5dive/security/advisories/new)**. Don't open a public issue. We acknowledge within 3 business days. Scope is the `5dive` CLI, `install.sh`, shipped systemd units, and `5dive-ai/*` workflows; upstream coding CLIs (`claude`, `codex`, ...) and apt/Node go to their respective maintainers.

---

## License

MIT. See [LICENSE](LICENSE).
