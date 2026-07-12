<p align="center">
  <a href="https://5dive.ai?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/readme-hero-dark.png">
      <img src="docs/readme-hero-light.png" alt="5dive" width="240">
    </picture>
  </a>
</p>

<p align="center"><b>run a company of AI agents on a server you own</b></p>

<p align="center"><b>English</b> ｜ <a href="README.zh-CN.md">简体中文</a></p>

<p align="center">
  <a href="docs/zero-human.md"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2F5dive-ai%2F5dive%2Fstatus%2Fbadge.json" alt="zero-human"></a>
  <a href="https://github.com/5dive-ai/5dive/releases"><img src="https://img.shields.io/github/v/release/5dive-ai/5dive" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>

<p align="center">
  <a href="https://github.com/5dive-ai/5dive/actions/workflows/install-smoke.yml"><img src="https://github.com/5dive-ai/5dive/actions/workflows/install-smoke.yml/badge.svg" alt="install-smoke"></a>
  <a href="https://github.com/5dive-ai/5dive/actions/workflows/bundle-drift.yml"><img src="https://github.com/5dive-ai/5dive/actions/workflows/bundle-drift.yml/badge.svg" alt="bundle-drift"></a>
  <a href="https://t.me/ai5dive"><img src="https://img.shields.io/badge/Telegram-@ai5dive-229ED9?logo=telegram&logoColor=white" alt="Telegram"></a>
  <a href="https://discord.gg/aU2UQC9Myy"><img src="https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white" alt="Discord"></a>
</p>

<p align="center">
  <a href="#quickstart">Quickstart</a> ·
  <a href="#why-5dive">Why 5dive</a> ·
  <a href="docs/zero-human.md">Zero-human proof</a> ·
  <a href="#for-your-ai-agent">Use from your AI agent</a> ·
  <a href="#security--isolation">Security</a> ·
  <a href="https://5dive.ai?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme">Managed VM</a>
</p>

**A company of AI agents, and the orchestrator is just bash.** No framework, no protocol, no broker: each agent is its own Linux user running an official coding CLI (claude, codex, a few others) as a systemd service, coordinating through one bash CLI they all call. Isolation is unix users, supervision is systemd, logs are journald. **I used the OS instead of building a platform.**

They take work off a shared SQLite task queue, hand it to each other while you sleep, and ping your phone over Telegram only when a human has to decide. Works with every major agent CLI.

![install to a Claude agent answering on Telegram](docs/quickstart.gif)

> **We run our own company on this.** The agents that build 5dive.ai cut this repo's releases and ask a human only when they're stuck. The badge above is that claim, measured: shipped vs human decisions, last 7 days, republished daily. Numbers and limits: [docs/zero-human.md](docs/zero-human.md). Same binary you're installing. MIT, no open-core. Run it yourself, or skip the ops with the [managed VM](https://5dive.ai?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme).

**Already use Claude Code, Codex, or another agent CLI?** Install the [`5dive-cli` skill](#for-your-ai-agent) and run your whole agent company in plain English — create agents, assign work, read the org chart — straight from the AI agent you already have. One line to set up: [jump to it ↓](#for-your-ai-agent).

---

## Quickstart

```sh
# 1. install
curl -fsSL https://install.5dive.ai | sudo bash

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


**Requirements:** a Linux box with `systemd` and your own agent-CLI subscription or API key (Claude Pro/Max, OpenAI, …) — no account with us.

> **“`curl | sudo bash`, and agents with `sudo`?”** Fair question. The installer only apt-installs deps and drops the CLI + systemd units (every file it fetches is listed at the top of [`install.sh`](install.sh)). Each agent is then its own Linux user, and you choose its blast radius — a `sandboxed` agent gets its own home, no sudo, and resource limits. Details: [Security & isolation ↓](#security--isolation).

---

## Why 5dive

**They escalate, you decide.** Agents work autonomously and only ping your phone, as tap-to-answer buttons, when a human has to make the call — spend, publishing, anything destructive.

**A company that runs itself.** Named agents on one host, reporting up an org chart, handing each other work off a shared backlog.

**A subscription that's yours.** Official CLIs on your own Pro/Max or keys. No middleman, no OAuth proxy.

**Runs as a service, not a session.** Agents stay alive when you close the terminal. Message them from Telegram any time.

**Every major agent CLI.** `claude`, `codex`, `antigravity`, `grok`, `openclaw`, `hermes`, `opencode`, all under one team.

**Safe by default.** Each agent is its own Linux user under one of three isolation tiers. MIT, no open-core split.

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

<details>
<summary><b>About <code>hermes</code> / <code>openclaw</code> (third-party multi-provider harnesses)</b></summary>

`hermes` and `openclaw` are community-built harnesses that can route to many providers (OpenRouter, Anthropic, Google, Moonshot, DeepSeek, Z.ai, etc.). As of April 4, 2026, Anthropic no longer permits routing consumer Claude Pro/Max OAuth through third-party harnesses. For that work, use the official `claude` type with your own API key. Background: [We Ditched OpenClaw for Claude →](https://blog.5dive.ai/blog/we-ditched-openclaw-for-claude/?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme).

</details>

The `claude` type can also run the official Claude Code harness against a third-party Anthropic-compatible endpoint, bring your own key:

```sh
sudo 5dive agent create cheap-coder --type=claude --provider=deepseek --api-key=<key> --auth-profile=deepseek
# providers: openrouter (any model), deepseek (DeepSeek), moonshot (Kimi), zai (GLM)
# claude BYO requires --auth-profile=<name> (the account the key is saved under; reuse it to share the key across agents)

# Pick the model too. --model overrides the primary tiers with any slug the
# provider serves (OpenRouter translates every family); the background model
# stays on the provider's cheap default. Omit it to use the per-provider default.
sudo 5dive agent create glm-coder --type=claude --provider=openrouter --api-key=<key> --auth-profile=openrouter --model=z-ai/glm-5.2
```

Switch the model on a running agent (persists across restarts):

```sh
sudo 5dive agent config glm-coder set model=z-ai/glm-5.2
```

In-session, Claude Code's built-in `/model <slug>` also accepts any custom slug live (session-scoped).

---

## For your AI agent

If you already use Claude Code / Codex / Antigravity / Grok / opencode, paste this prompt. Your agent installs 5dive, learns the skill, then keeps managing agents through chat:

```
Install 5dive on this Linux host so I can use you to manage 5dive agents.

1. Run the installer (idempotent, safe to rerun):
   curl -fsSL https://install.5dive.ai | sudo bash
2. Confirm: `5dive --version` prints a version string (e.g. "5dive 0.5.x").
3. Install the 5dive-cli skill. Replace <runtime> with one of
   claude-code, codex, antigravity, grok, hermes-agent, openclaw, opencode:
   npx -y skills add https://github.com/5dive-ai/skills --skill 5dive-cli --agent <runtime> --yes
4. Tell me to restart so the skill loads, then ask which agent to create first.
```

**Installing onto a remote VM over SSH?** Same prompt, prefix the install line with `ssh -t <user@host>`. Install the skill on the laptop where you're issuing `ssh` from, not the remote. Use `ssh -t` for anything needing a TTY (e.g. `5dive agent auth login`).

---

## Security &amp; isolation

Each agent is one Linux user under one of three isolation tiers:

| Tier | Access |
|------|--------|
| `standard` (default) | shared read, limited write |
| `admin` | full host; auto-granted to the first agent on a fresh box |
| `sandboxed` | own home only, no sudo, systemd resource limits |

```sh
sudo 5dive agent create my-agent --type=claude --isolation=sandboxed
```

**No middlemen.** 5dive runs on your server. Auth tokens go to model providers directly, never to us. No telemetry, no error reporting, no usage data leaves the box. Long form: [your auth tokens don't touch us →](https://blog.5dive.ai/blog/your-auth-tokens-dont-touch-us/?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme).

---

<details>
<summary><b>More team ops — accounts, a shared bot, commands, characters</b></summary>

### Clone a working company

Don't assemble a team agent by agent. Import a whole org in one call:

```sh
sudo 5dive team import solo-founder
# spins up the agents, their roles, the org chart, and seeds their starting backlog
```

Browse templates with `5dive team ls`, or define your own in a `5dive.yaml` and
`5dive up`. A template is a company you can fork: engineering pod, research desk,
content engine, support crew. Clone it, point it at your keys and bots, done.

### Give them work

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

### Accounts (shared auth profiles)

One sign-in, many agents:

```sh
sudo 5dive account add   work
sudo 5dive account login work --type=claude
sudo 5dive agent create agent-a --type=claude --auth-profile=work
sudo 5dive agent create agent-b --type=claude --auth-profile=work
```

Rename or rotate the account, every bound agent rebinds automatically. `5dive account usage` shows each account's rate-limit headroom.

### One bot for the whole team

Per-agent bots are optional. Point one shared bot at a Telegram group (topics enabled) and every agent gets its own forum topic:

```sh
sudo 5dive agent team-bot shared --group=<chat_id> --agents=coder,writer,pm --token=<bot-token>
```

New agents auto-attach with their own topic (opt out per agent with `--no-team-bot`). `team-bot discover` finds the group id for you, and `team-bot intercom` mirrors inter-agent chatter into a dedicated topic so you can watch the team coordinate.

### Import a character

A template gives you roles. A **character pack** gives you a personality — a ready-made persona with its own voice, model, effort, and bundled skills:

```sh
sudo 5dive agent marketplace ls            # browse the character-pack registry
sudo 5dive agent import olivia --as=ceo    # spin up a named agent from a pack
```

`--as` is the agent's name on your box; the pack supplies the persona, model, and skills. Add `--channels=telegram` to wire a bot at import time. Packs live in the [`5dive-ai/character-packs`](https://github.com/5dive-ai/character-packs) registry — and a `5dive.yaml` can reference one with `pack: <slug>`.

### Commands at a glance

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

</details>

<details>
<summary><b>Self-hosting, hardening &amp; other install paths</b></summary>

### Securing your server

5dive runs agents with shell access. Standard hygiene applies:

- patch the OS (`unattended-upgrades`)
- SSH key-only, no root login
- firewall default-deny
- per-agent isolation tiers
- Telegram bot allowlists

Baselines: [devsec.os_hardening](https://github.com/dev-sec/ansible-collection-hardening) · [Lynis](https://github.com/CISOfy/lynis) · [fail2ban](https://www.fail2ban.org/). Or skip the checklist; [5dive.ai](https://5dive.ai?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme) handles it.

### Other paths

**[Docker](docker/README.md).** Kick the tires without a host install:
```sh
docker build -f docker/Dockerfile -t 5dive .
docker run -d --name 5dive-demo --privileged 5dive
docker exec -it 5dive-demo bash
```

**Offline / air-gapped.** `install.sh` reads from `$REPO` (default GitHub raw). Override with `REPO=file:///path/to/local/tree` and pre-install apt deps. The fetched files are listed at the top of `install.sh`.

**Updating.** 5dive doesn't auto-update — you stay in control of when code changes land:
```sh
sudo 5dive self-update
```
This refreshes the CLI, hooks, skills, and plugins, then restarts each running agent so the new versions load. Want it on a schedule?
```cron
0 4 * * * /usr/local/bin/5dive self-update >/dev/null 2>&1
```

**Context rot.** Long sessions degrade — the daily `self-update` above also restarts agents, giving each a fresh session. Claude-runtime agents keep project memory under `~/.claude/projects/<dir>/memory/` across restarts. Session resets, knowledge stays.

### Requirements

- Linux with `systemd` (Ubuntu 22.04+ recommended)
- root for install (installer apt-installs `jq`, `tmux`, and other deps)

No systemd / no root / not Linux? Use the Docker image above.

### Reporting a vulnerability

Use GitHub's private reporting: **[Report a vulnerability →](https://github.com/5dive-ai/5dive/security/advisories/new)**. Don't open a public issue. We acknowledge within 3 business days. Scope is the `5dive` CLI, `install.sh`, shipped systemd units, and `5dive-ai/*` workflows; upstream coding CLIs (`claude`, `codex`, ...) and apt/Node go to their respective maintainers.

</details>

<details>
<summary><b>JSON / machine-readable output</b></summary>

Every command accepts `--json`. Output is `{ok:true,data:...}` on success or `{ok:false,error:{code,class,message}}` on failure. Exit code matches `error.code` so shell pipelines branch without parsing. Progress lines stay on stderr; stdout is always valid JSON.

```json
{ "ok": true,  "data": [ {"name": "main", "type": "claude", "active": "active"} ] }
{ "ok": false, "error": { "code": 4, "class": "not_found", "message": "no agent named 'foo'" } }
```

</details>

<details>
<summary><b>Prefer a managed dashboard instead of ssh?</b></summary>

The CLI is the OSS surface. Every verb here, every agent, every host, all driven from `/usr/local/bin/5dive`.

If you'd rather click than `ssh`, [5dive.ai](https://5dive.ai?utm_source=github&utm_medium=referral&utm_campaign=5dive-readme) is the managed version: same CLI under the hood, but the VM, hardening, updates, and dashboard are run for you.

<video src="https://cdn.jsdelivr.net/gh/5dive-ai/assets@main/hero-demo.mp4" autoplay loop muted playsinline width="100%"></video>

</details>

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The `5dive` bundle at the repo root is built from `src/` via `./build.sh`; CI enforces no drift.

## License

MIT. See [LICENSE](LICENSE).
