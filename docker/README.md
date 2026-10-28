# 5dive in Docker

Run `5dive` in a container: host it on a Mac mini or a home server, or just try
it without touching your machine. The container runs systemd as PID 1 and has
the CLI pre-installed.

## Host it on a Mac mini

Install [Docker Desktop](https://www.docker.com/products/docker-desktop/), then:

```sh
curl -fsSLO https://raw.githubusercontent.com/5dive-ai/5dive/main/docker/compose.yaml && docker compose up -d
docker exec -it 5dive 5dive init
```

The image is built for Apple Silicon (arm64) and Intel (amd64).

- **Your agents are kept.** Agents, logins and Telegram bots live on Docker
  volumes, so restarts, recreates and updates keep them. Only
  `docker compose down -v` deletes them.
- **It comes back after a reboot.** The container restarts by itself; turn on
  *Start Docker Desktop when you sign in* in Docker Desktop's settings, and set
  the Mac to log in automatically.
- **Update:** `docker compose pull && docker compose up -d`. Pin a release with
  `FIVEDIVE_TAG=v0.106.0 docker compose up -d`.
- **Use a machine that is only for 5dive.** The container runs `--privileged`
  (each agent is a systemd service). That is fine on a Mac mini you keep for
  this; do not run it on a computer you share or on a shared server.

The same file works on any Linux box with Docker.

## Build

```sh
docker build -f docker/Dockerfile -t 5dive .
```

Build from the **repo root**, not from inside `docker/` — the Dockerfile
`COPY`s the CLI bundle (`5dive`, `install.sh`, `bin/`, `prompts/`) plus
`hooks/`, `skills/`, and `systemd/` from the working tree.

## Run a throwaway demo

```sh
docker run -d --name 5dive-demo --privileged 5dive
docker exec -it 5dive-demo bash
```

`--privileged` is required so systemd inside the container can manage cgroups
and start agent units. Inside the shell, use `5dive` as you would on a host.
The quickest path is the wizard (type → auth → agent → Telegram, auto-pairs
on /start — you're already root in the container, no sudo needed):

```sh
5dive init
```

Or piece by piece:

```sh
5dive doctor
5dive agent auth set claude --api-key=sk-ant-...
5dive agent create my-agent --type=claude
5dive agent send my-agent "hello"
```

Have a Claude Pro/Max subscription instead of an API key? OAuth works in the
container too — there's just no browser inside, so it's copy-out/paste-in:

```sh
5dive account add me
5dive account login me --type=claude
# prints an authorize URL — open it in any browser (laptop, phone),
# approve, then paste the callback code back into this prompt
5dive agent create my-agent --type=claude --auth-profile=me
```

Talk to the agent from your phone — Telegram works from inside the container
(the bot long-polls outbound, no inbound ports needed). Get a token from
[BotFather](https://t.me/BotFather):

```sh
5dive agent create my-agent --type=claude --channels=telegram --telegram-token=<token>
5dive agent pair   my-agent --code=<pairing-code>
```

Or run the official Claude Code harness against an Anthropic-compatible
third-party endpoint, bring your own key:

```sh
5dive agent create cheap-coder --type=claude --provider=deepseek --api-key=<key>
# providers: deepseek (DeepSeek), moonshot (Kimi), zai (GLM)
```

## Teardown

```sh
docker rm -f 5dive-demo
```

The image (and any auth credentials added inside the container) goes with it.

## Caveats

- **`--privileged` is a real trade-off.** systemd-in-Docker needs it. Fine on
  a machine kept for 5dive (see *Host it on a Mac mini*); on a shared host,
  run the host installer instead.
- **A bare `docker run` is ephemeral.** `docker rm` deletes the agent
  registry, auth profiles, and Telegram tokens. To keep them, use
  `compose.yaml`: it keeps every path an agent lives on (`/etc`, `/home`,
  `/root`, `/var/lib/5dive`, `/var/spool/cron`) on named volumes. Named, not
  bind mounts: Docker seeds an empty named volume from the image, and the CLI
  needs that seed.
- **What an update re-applies.** When a newer image starts on saved volumes,
  it re-runs the installer from the image once, as `5dive self-update` does
  on a host. Anything else you installed by hand outside those paths (an
  `apt-get install`) is gone after a recreate.
- **OAuth flows are awkward.** Device-code flows work; browser-based flows
  inside a headless container don't. Prefer `5dive agent auth set <type>
  --api-key=<key>` when trying the container.
