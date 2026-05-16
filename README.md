# 5dive CLI

Open-source CLI to spawn, manage, and message AI agents — any model, any machine.

> Prefer managed? [5dive.com](https://5dive.com) runs the same CLI on a hardened VM — point it at the agent, skip the ops.

```sh
curl -fsSL https://raw.githubusercontent.com/5dive-com/5dive-cli/main/install.sh | sudo bash
```

### Or have your existing AI agent install it

If you already use Claude Code / Codex / Gemini / opencode etc., paste one of these prompts in and let the agent do the install. After it's done, the agent will have learned the `5dive-cli` skill, so you can keep talking to it to create agents, set API keys, and pair Telegram bots — no manual CLI dance needed.

**On the same machine the agent is running on:**

```
Install 5dive-cli on this Linux host so I can use you to manage 5dive agents.

1. Run the official installer (idempotent — safe to rerun):
   curl -fsSL https://raw.githubusercontent.com/5dive-com/5dive-cli/main/install.sh | sudo bash
2. Confirm: `5dive --version` should print "5dive 0.1.x".
3. Install the 5dive-cli skill so you know how to drive it. Use the
   `--agent` value that matches your runtime — `claude-code`, `codex`,
   `gemini-cli`, `hermes-agent`, `openclaw`, or `opencode`:
   npx -y skills add https://github.com/5dive-com/skills --skill 5dive-cli --agent <your-runtime> --yes
4. Tell me to restart so the skill loads, then wait — I'll ask which agent
   to create first.

If the install errors out (apt deps, sudo, network), surface the exact error
and don't retry blindly.
```

**From your laptop, installing onto a remote VM over SSH:**

```
Install 5dive-cli on the remote VM at <user@host> so I can manage agents on
it through you over SSH.

1. Confirm reachability: `ssh <user@host> uname -a`. Stop if that fails.
2. Run the installer on the remote:
   ssh -t <user@host> 'curl -fsSL https://raw.githubusercontent.com/5dive-com/5dive-cli/main/install.sh | sudo bash'
3. Verify: `ssh <user@host> '/usr/local/bin/5dive --version'` should print
   "5dive 0.1.x".
4. Install the 5dive-cli skill into your own (local) home — that's where
   you'll be issuing `ssh <user@host> 5dive ...` calls from. Use the
   `--agent` value that matches your runtime — `claude-code`, `codex`,
   `gemini-cli`, `hermes-agent`, `openclaw`, or `opencode`:
   npx -y skills add https://github.com/5dive-com/skills --skill 5dive-cli --agent <your-runtime> --yes
5. Tell me to restart, then wait — I'll ask which agent to spin up first on
   the remote.

For step 2+ you'll mostly prefix `5dive` calls with `ssh <user@host>`. Use
`ssh -t` for anything that needs a TTY (`5dive agent auth login`, etc.). If
sudo on the remote needs a password and your key isn't enough, surface it
— don't pipe a password into ssh.
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

## Demo

Sixty seconds — install, spawn, send, attach, tear down.

<!-- GIF here -->

---

## Agents that talk to each other

Every agent can call `5dive agent send` and `5dive agent ask` on any other agent on the same host. Stand up a small team — drafter, reviewer, deployer — each with its own model, auth, isolation tier, and channel, all sharing one command surface.

```sh
# main → marketing: hand off a writing task (fire-and-forget)
5dive agent send marketing "draft a launch tweet for v0.4"

# marketing → main: pull a fact before drafting (wait for the reply)
5dive agent ask  main "summarize the v0.4 changelog — 3 bullets" --timeout=120
```

No coordinator service, no orchestration layer, no API. The CLI itself is the bus. Spawn a senior agent and a junior, give them different prompts, let them pass work. Have one agent delegate research while another holds the user-facing thread.

This is the feature most people don't realize they need until they try it.

---

## Quickstart

**1. Install** (or upgrade an existing install with `bash -s -- --upgrade`)
```sh
curl -fsSL https://raw.githubusercontent.com/5dive-com/5dive-cli/main/install.sh | sudo bash
```

Rerunning the installer is safe — it won't touch your registry, auth profiles, or agents. `--upgrade` skips apt/nvm/bun entirely and only refreshes the CLI binaries, systemd unit, and hooks.

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

Or wire it to a Telegram bot so you can message it from your phone — [BotFather](https://t.me/BotFather) gives you the token:
```sh
5dive agent create my-agent --type=claude --channels=telegram --telegram-token=<bot-token>
5dive agent pair my-agent --code=<pairing-code>   # one-time DM handshake
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

## Try it in Docker (no host install)

Kick the tires without touching your host. Build the demo image from the repo
root, run it `--privileged` (systemd-in-Docker), exec in, use `5dive` as
normal:

```sh
docker build -f docker/Dockerfile -t 5dive .
docker run -d --name 5dive-demo --privileged 5dive
docker exec -it 5dive-demo bash
```

See [docker/README.md](docker/README.md) for dashboard port-forwarding,
caveats, and teardown. This path is for evaluation only — for real use,
install on a host.

---

## Offline / air-gapped install

The installer fetches a small set of files from `$REPO` (default
`raw.githubusercontent.com/5dive-com/5dive-cli/main`) and a few system
dependencies from apt / nvm / bun. Override `$REPO` and pre-install the
deps, and the same `install.sh` runs with no internet access on the
target host.

**On a connected machine** — grab the repo at the version you want and
build a tarball:

```sh
git clone --depth=1 https://github.com/5dive-com/5dive-cli.git
tar czf 5dive-offline.tar.gz -C 5dive-cli \
  5dive 5dive-agent-start install.sh systemd hooks skills
```

Also download:
- apt packages: `jq`, `tmux`, `git`, `curl`, `python3-yaml` (or use your
  org's internal apt mirror)
- [nvm v0.40.3](https://github.com/nvm-sh/nvm/releases/tag/v0.40.3) +
  [Node.js 22](https://nodejs.org/dist/) (only needed for `codex` /
  `gemini` agents)
- [bun](https://github.com/oven-sh/bun/releases) (only needed for the
  telegram channel plugin)

**On the air-gapped host** — pre-install the deps so `install.sh`'s
network-fetching branches all short-circuit:

```sh
# 1. apt deps from your mirror / sneakernet
sudo apt-get install -y jq tmux git curl python3-yaml

# 2. claude user + nvm + node 22 (skip if you don't need codex/gemini)
#    install.sh's `nvm install 22` step is a no-op if v22 is already on disk.
sudo groupadd --system claude
sudo useradd --system --gid claude --shell /bin/bash \
  --create-home --home-dir /home/claude claude
sudo -u claude bash -c '
  cd ~ && tar xzf /path/to/nvm-v0.40.3.tar.gz && mv nvm-0.40.3 .nvm
  mkdir -p .nvm/versions/node
  tar xJf /path/to/node-v22.x.x-linux-x64.tar.xz -C .nvm/versions/node
  mv .nvm/versions/node/node-v22.x.x-linux-x64 .nvm/versions/node/v22.x.x
'

# 3. bun (skip if you don't need telegram)
sudo -u claude bash -c 'mkdir -p ~/.bun/bin && cp /path/to/bun ~/.bun/bin/bun && chmod +x ~/.bun/bin/bun'

# 4. extract + install, pointing $REPO at the local tree
tar xzf 5dive-offline.tar.gz -C /opt/5dive-offline
sudo REPO=file:///opt/5dive-offline bash /opt/5dive-offline/install.sh
```

The installer's apt / nvm / bun steps detect existing installs and skip;
the only files it actively pulls (the `5dive` bundle, `5dive-agent-start`,
the systemd unit, hooks, the notify-user skill) come from `$REPO`, so
`file://` works without modification.

To upgrade later, refresh `/opt/5dive-offline` and rerun with `--upgrade`:

```sh
sudo REPO=file:///opt/5dive-offline bash /opt/5dive-offline/install.sh --upgrade
```

---

## Supported agent types

| Type | Model family | Auth method | Channels |
|------|-------------|-------------|----------|
| `claude` | Anthropic Claude | OAuth / API key | Telegram, Discord |
| `codex` | OpenAI Codex | OAuth / API key | — |
| `gemini` | Google Gemini | OAuth / API key | — |
| `hermes` | Nous Hermes | OAuth / API key | Telegram, Discord |
| `openclaw` | OpenClaw | OAuth / API key | Telegram, Discord |
| `opencode` | OpenCode | API key | — |

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

## Local web dashboard

```sh
5dive ui                        # opens http://localhost:5175 (loopback only)
5dive ui setup                  # configure password auth
5dive ui --host=0.0.0.0         # expose on the network (requires setup first)
```

See [ui/README.md](ui/README.md) for the full auth model and a reverse-proxy
recipe for exposing the dashboard publicly.

---

## No middlemen

**No auth proxying.** 5dive runs your AI CLI of choice (Claude Code, Codex, Gemini, Hermes, openclaw, opencode) on your own server — you log in with your own credentials, exactly like you would locally. Your auth tokens never touch us.

**No telemetry.** The CLI does not phone home, send usage data, or report errors anywhere — it only talks to the model providers you configure.

---

## Securing your server

5dive puts agents with shell access on a box you control. That's a powerful default — and a responsibility. Standard server hygiene matters more here than for a static web app, because a compromised agent is a compromised shell.

The shortlist:
- **Keep the OS patched.** Enable `unattended-upgrades` (Ubuntu) or your distro's equivalent.
- **Lock down SSH.** Key-only auth, no root login, no password fallback (`/etc/ssh/sshd_config`).
- **Firewall by default-deny.** Open only SSH and — if you're exposing it — the dashboard port. `ufw` is the easy option.
- **Don't expose the dashboard naked.** `5dive ui setup` configures password auth before you bind beyond loopback. Behind a reverse proxy with TLS if you publish it.
- **Restrict who can pair.** Each Telegram-paired agent has an access allowlist (`telegram:access` skill). Use it.
- **Pick the right isolation tier.** `sandboxed` for untrusted work, `standard` for shared-file flows, `admin` only when an agent really needs to manage the host.

For deeper baselines, the standard tools are well-maintained — [devsec.os_hardening](https://github.com/dev-sec/ansible-collection-hardening) (Ansible), [Lynis](https://github.com/CISOfy/lynis) (audit), [fail2ban](https://www.fail2ban.org/) (brute-force protection). 5dive doesn't reinvent any of this — use whichever fits your workflow.

---

## Managed platform

Or skip the checklist — [5dive.com](https://5dive.com) handles the hardening.

---

## Requirements

- Linux (Ubuntu 22.04+ recommended)
- `bash` 5+, `jq`, `tmux`, `systemd`
- Root access for install

No systemd, no root, or not on Linux? Run the [Docker image](#try-it-in-docker-no-host-install) — it bundles systemd + a working install, and works on macOS and Windows hosts.

---

## Contributing

The installed `5dive` is a single bash file — that's deliberate, so `curl … | sudo bash` can fetch one artifact. The source is split for readability:

```
src/header.sh           # set -euo pipefail, globals, declare -A maps
src/lib/*.sh            # error_codes, output, validation, state/audit/registry,
                        # agent_setup (channel + skill + preseed installers)
src/cmd_*.sh            # one file per top-level subcommand
                        # (auth, account, agent, skill, doctor, watch, compose)
src/main.sh             # usage(), main(), EXIT trap, main "$@"
```

`./build.sh` concatenates them (in an order pinned by the script — not a glob) into the single-file `5dive` bundle that lives at the repo root. The bundle is committed so the installer keeps fetching one file; CI runs `./build.sh && git diff --exit-code 5dive` on every push so the bundle and `src/` can never drift apart. If CI fails on bundle-drift, run `./build.sh` locally and commit the result.

Don't `source` files at runtime — it breaks the one-liner install and bash's cross-file scoping has enough ordering footguns to avoid.

---

## License

MIT — see [LICENSE](LICENSE)
