# 5dive in Docker

Try `5dive` without touching your host. The container runs systemd as PID 1
and has the CLI pre-installed.

## Build

```sh
docker build -f docker/Dockerfile -t 5dive .
```

Build from the **repo root**, not from inside `docker/` — the Dockerfile
`COPY`s the CLI bundle (`5dive`, `5dive-agent-start`, `install.sh`, …) plus
`hooks/`, `skills/`, and `systemd/` from the working tree.

## Run

```sh
docker run -d --name 5dive-demo --privileged 5dive
docker exec -it 5dive-demo bash
```

`--privileged` is required so systemd inside the container can manage cgroups
and start agent units. Inside the shell, use `5dive` as you would on a host:

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

## Teardown

```sh
docker rm -f 5dive-demo
```

The image (and any auth credentials added inside the container) goes with it.

## Caveats

- **Not for production.** This image is for evaluation — the systemd-in-Docker
  setup needs `--privileged`, which is a security trade-off most teams won't
  want past a kick-the-tires session. For real use, run the host installer.
- **State is ephemeral.** `docker rm` deletes the agent registry, auth
  profiles, and Telegram tokens. To persist, mount volumes for
  `/var/lib/5dive` and `/etc/5dive/connectors`.
- **OAuth flows are awkward.** Device-code flows work; browser-based flows
  inside a headless container don't. Prefer `5dive agent auth set <type>
  --api-key=<key>` when trying the container.
