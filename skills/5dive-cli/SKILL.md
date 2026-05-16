---
name: 5dive-cli
description: Use the local `5dive` CLI on a 5dive runtime VM to spawn, inspect, send to, and tear down sibling agents. Trigger this skill whenever the user asks for a worker, sub-agent, side task, parallel run, "another agent", "fan out", "delegate", or anything that needs more than one Claude/Codex/Gemini process running at once on the host. Also trigger when the user asks to inspect, restart, or pair an existing agent, when they mention `/var/lib/5dive/`, or when they need a machine-readable health check (`5dive doctor --json`). Always prefer `5dive` over running coding CLIs by hand — it is the only sanctioned way to keep agents under systemd.
---

# 5dive-cli

This skill teaches you to drive the `5dive` command on a 5dive runtime VM.
You are running inside one such VM. You can spawn additional agents on the
same host by shelling out to `sudo 5dive ...` and parsing the JSON envelope
it emits when you pass `--json`.

## When to use this skill

Use it whenever the work in front of you would benefit from a second pair of
hands — for example:

- The user asks for a "worker", "sub-agent", "another agent", or "side task".
- A long task could fan out into independent pieces (e.g. audit each route
  in parallel, run a different model on the same prompt, A/B two implementations).
- You need to keep one agent on a hot context while a second one investigates
  something orthogonal.
- The user wants to inspect / restart / pair / tear down an agent that
  already exists on the host.
- You need a machine-readable health check of the host's coding-CLI stack.

If the user just wants you to do the work yourself, do not spawn an agent.

## Mental model

Everything the CLI does maps onto these resources on the host:

- One **agent** = one Linux user (`agent-<name>`) + one systemd unit
  (`5dive-agent@<name>.service`) + one tmux session (`agent-<name>`)
  running the chosen CLI in a restart loop.
- Auth is decoupled. You authenticate a *type* once; every agent of that
  type inherits the credentials via `EnvironmentFile`.
- A **channel** (`telegram` / `discord` / `none`) is the inbound message
  surface. Channels are only supported by `claude`, `openclaw`, `hermes`.
- The CLI is idempotent and safe to call from another agent — your agent
  user is in the `claude` group and has `sudo 5dive ...` whitelisted.

## Output contract — always pass `--json`

Pass `--json` as a global flag (anywhere on the command line). Stdout
becomes a stable envelope; progress lines stay on stderr.

```bash
sudo 5dive agent create scout --type=claude --json
```

Success:
```json
{ "ok": true, "data": { "name": "scout", "type": "claude", "created": true } }
```

Failure (exit code matches `error.code`):
```json
{ "ok": false, "error": { "code": 6, "class": "auth_required", "message": "..." } }
```

**Branch on `error.class`, not on the human message.** Classes:
`ok`, `usage`, `validation`, `not_found`, `conflict`, `auth_required`,
`not_installed`, `not_running`, `pairing`, `permission`, `timeout`, `generic`.

See `references/exit-codes.md` for the full table.

## Recipes

### Spawn a worker for a side task

```bash
# 1. Pick a unique name (lowercase letters/digits/hyphens, ≤16 chars,
#    must start with a letter). Check the registry first if you care:
sudo 5dive agent list --json | jq '.data.agents | keys'

# 2. Create the worker. --workdir scopes its tmux cwd; default is
#    /home/claude/projects.
sudo 5dive agent create worker-1 \
  --type=claude \
  --workdir=/home/claude/projects/myrepo \
  --json

# 3. Send it the task. tmux send-keys + Enter, so the text appears
#    in the worker's running CLI prompt.
sudo 5dive agent send worker-1 \
  "audit the auth middleware for OWASP A01 issues; report back as a markdown bullet list"

# 4. Poll its output until it goes idle. --tmux dumps the scrollback.
sudo 5dive agent logs worker-1 --tmux --lines=80

# 5. Tear it down when you're done — frees the systemd unit + Linux user.
sudo 5dive agent rm worker-1 --json
```

#### Skill inheritance on agent-spawned children

When an agent (you, `SUDO_USER=agent-*`) creates another **claude-typed** agent,
the CLI auto-installs the `5dive-cli` skill into the child so it inherits
inter-agent comms knowledge. Humans creating from the dashboard don't get this
default. Override either way:

- `--with-skills=<spec>[,<spec>...]` — explicit list. Each spec is a bare id
  (defaults to `5dive-com/skills`) or `<owner/repo>:<id>`.
  Example: `--with-skills=5dive-cli,acme/skills:db-tools`.
- `--no-skills` — opt out, even when called from another agent.

#### Create-then-auth: `--defer-auth`

Use when you want the agent registered before its credentials are wired up
(e.g. the agent's own first-run UI will handle sign-in). Skips the auth gate
on `agent create`; combine with `--auth-profile=<name>` to bind a profile slot
that doesn't yet have a `combined.env`.

```bash
sudo 5dive agent create draft-bot --type=claude --defer-auth --json
```

### Fan out: same prompt, three different models

Useful for "let me see how Codex/Gemini/Claude each approach this".

```bash
for type in claude codex gemini; do
  sudo 5dive agent create "fan-${type}" --type="${type}" --json
  sudo 5dive agent send "fan-${type}" "$PROMPT"
done

# Wait, then collect the last 200 lines of each:
for type in claude codex gemini; do
  echo "=== ${type} ==="
  sudo 5dive agent logs "fan-${type}" --tmux --lines=200
done

# Cleanup.
for type in claude codex gemini; do
  sudo 5dive agent rm "fan-${type}" --json
done
```

### Recover from `auth_required`

```bash
# If create fails with error.class=auth_required, the type isn't authenticated.
# Two paths — pick by what credentials you have:

# A) Static API key in $KEY (preferred for automation)
echo "$KEY" | sudo 5dive agent auth set claude --api-key=- --json

# B) Device-code flow (when only a human can complete login)
sudo 5dive agent auth start claude --json
# -> session id; give the URL from `auth poll` to the user; they paste the
#    callback code back via `auth submit`.
```

Never call `5dive agent auth login <type>` from your own process — it
hands the TTY off to the upstream CLI's interactive flow and hangs your
agent. Use `auth start` / `auth set` instead.

### Multi-account: the `account` noun

A 5dive **account** is a named auth profile — one bag of credentials that any
number of agents can share via `--auth-profile=<name>`. Use it when the host
has more than one human / billing identity (e.g. work + personal Anthropic
sign-ins) and different agents should use different ones.

`5dive account ...` is the user-facing surface; the lower-level
`agent auth start|poll|submit|cancel` verbs are still what the dashboard's
device-code flow uses, and what you should use from a script.

```bash
# Inventory: which named accounts exist, what types each is signed into,
# and how many agents are bound to each.
sudo 5dive account list --json

# Detail for one account, including which env keys are populated.
sudo 5dive account show acme-prod --json

# Provision a new empty account, then sign it in (TTY-only — humans).
sudo 5dive account add acme-prod
sudo 5dive account login acme-prod --type=claude

# Rebind an existing agent to a different account. Restarts the agent so
# the new EnvironmentFile takes effect.
sudo 5dive agent set-account worker-1 acme-prod --json
sudo 5dive agent set-account worker-1 default --json   # clears the override

# Rename / remove. `remove` refuses while any agents are still bound.
sudo 5dive account rename acme-prod acme-staging --json
sudo 5dive account remove acme-staging --json
```

The reserved name `default` is rejected by `account add` / `rename` — at the
agent level, `auth-profile=default` already means "no override, use the shared
`/etc/5dive/connectors/<type>.env`".

### Pair a Telegram channel without a bot reply

`agent pair` accepts three input shapes:

```bash
# A) Classic — return a pairing code, user DMs the bot, paste the bot reply.
sudo 5dive agent pair worker-1 --json
sudo 5dive agent pair worker-1 --code=AB12CD --json

# B) Auto-detect — long-poll Telegram for the next inbound message and
#    seed access.json from whoever DMs the bot first. Useful in onboarding
#    flows where the user has the bot open already.
sudo 5dive agent telegram-discover --token="$BOT_TOKEN" --poll-secs=60 --json
# -> {found:true, userId, chatId, ...}; re-poll on {found:false}.
sudo 5dive agent pair worker-1 --user-id=<userId> --chat-id=<chatId> --json

# C) Bot identity for deep links — fast getMe lookup so the dashboard can
#    render a tappable t.me/<bot> link alongside the "send /start" prompt.
sudo 5dive agent telegram-getme --token="$BOT_TOKEN" --json
# -> {ok:true, data:{botId, username, firstName}}
```

`telegram-discover` and `telegram-getme` are read-only (no registry mutation,
no audit log) and do not require a bound agent.

### Talking to other agents (inter-agent comms)

`agent send` and `agent ask` work as a tiny message bus between agents on the
same host. There is no separate channel — messages land in the receiver's
running CLI as if a human had typed them.

#### Sending: attribution is automatic

When you (an agent) shell out to `sudo 5dive agent send <name> "..."`, the CLI
sees that `$SUDO_USER` is `agent-<you>` and wraps the payload as:

```
[5dive-msg from=<you> id=<8-hex>] <your text>
```

so the receiver can tell it's being pinged by a peer agent and which one.
Override the inferred name with `--from=<label>`. Skip wrapping with `--raw`
(useful when you're piping a prompt that already has its own structure).

Humans running `sudo 5dive agent send` directly never get auto-wrapped — only
sends from `agent-*` users do.

#### Receiving: recognise the envelope and reply by name

When a line like

```
[5dive-msg from=scout id=ab12cd34] please summarise the auth middleware audit
```

appears as your input, treat it as an inter-agent request. To reply, send
back to the named sender:

```bash
sudo 5dive agent send scout "[re=ab12cd34] auth middleware looks clean except for ..."
```

The `[re=<id>]` prefix is convention, not enforced — it lets the original
sender match your reply to their question when they're juggling several at
once. Drop it for casual back-and-forth.

#### One-shot synchronous calls: `agent ask`

If you want a request/response in one CLI call (no manual polling of
`agent logs`), use `ask`:

```bash
sudo 5dive agent ask scout \
  "list the OWASP A01 issues you found, one per line" \
  --timeout=180 --json
```

It sends the wrapped envelope, then watches `tmux capture-pane` after the
marker line and returns once the scrollback has been quiet for `--idle-secs`
(default 5s). Stdout (text mode) is just the reply body; in `--json` mode the
envelope is `{ok:true, data:{name, from, msg_id, reply}}`.

Caveats — read these before leaning on `ask`:

1. **Idle-by-stability is heuristic.** A receiver that streams progress
   continuously will keep `ask` awake until `--timeout` fires. If you're
   asking for something the receiver might narrate (long agentic work),
   prompt it for a terse final summary or use plain `send` + `logs`.
2. **The reply is whatever was on screen.** It includes any chrome the
   receiver CLI prints (cursor lines, status hints) — don't expect a clean
   JSON body unless the prompt asks for one.
3. **No retries, no delivery confirmation.** If the receiver crashed mid-
   reply you'll get a partial slice or a timeout, nothing in between.

#### Rules of thumb

- For "fire-and-forget delegate, I'll check later": `agent send` + poll `agent logs --tmux` when it suits you.
- For "I need an answer to continue": `agent ask`.
- For broadcast / fan-out across N agents: loop `agent send` (or `agent ask` in parallel via `&` + `wait`). Each call is independent.
- Don't reuse `--from` labels for unrelated agents — pick a label that names *you*, so receivers can address replies correctly.

### Diagnose a sick host

```bash
sudo 5dive doctor --json
```

Envelope is always `{ ok: true, data: { summary, checks } }` with exit 0.
Branch on `data.summary.errors > 0`. Add `--repair` to attempt reversible
fixes (apt installs, type installer recipes, registry reseed).

## Rules of engagement

1. **Always pass `--json`.** Parse the envelope. Don't grep stderr.
2. **One name = one agent.** Names are lowercase letters/digits/hyphens,
   start with a letter, max 16 chars. Reuse a name only after `agent rm`.
3. **Don't share bot tokens.** Two Telegram-channel agents on the same
   bot will race each other on `getUpdates`. Each agent needs its own.
4. **Tear down what you spin up.** A leaked `worker-N` agent stays
   running across reboots — it's a real systemd unit, not a thread.
   On task completion call `5dive agent rm <name>`.
5. **Don't shell out to the underlying CLI binaries directly.** Going
   around `5dive` skips the systemd unit, the audit log, and the env
   injection — the agent will run with broken auth and no restart loop.
6. **Read `5dive --help`** if a flag is rejected as unknown — the binary
   on the host may be newer or older than this skill. The help output is
   authoritative.
7. **The `auth login <type>` path is interactive only.** Never call it
   from your own session.

## Reference

- `references/commands.md` — every subcommand and flag, copy/pasteable.
- `references/exit-codes.md` — exit codes & error classes.
- `references/paths.md` — on-disk state layout (only for debugging).

## Going further

The full reference manual lives at <https://5dive.com/docs>. If a flag in
this skill conflicts with what the running binary accepts, trust the
binary — run `sudo 5dive --help` or `sudo 5dive agent <sub> --help`
directly and follow that.
