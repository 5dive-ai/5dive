# DIVE-3017 — `5dive acp`: speak ACP (Agent Client Protocol) over stdio, so an ACP
# client (block/buzz — 25k stars — Zed, …) can select 5dive as a coding-agent runtime.
#
# NATIVE VERB, NOT AN ADAPTER. block/buzz's PRESET_HARNESSES
# (desktop/src-tauri/src/managed_agents/discovery/presets.rs) splits into two tiers:
# vendor-owned CLIs with a native acp mode (7 of 9 — cursor-agent, opencode, kimi, …,
# all `underlying_cli: None`) and one third-party adapter (amp, via `amp-acp`). We own
# our CLI, so we belong in the first tier: command "5dive", args ["acp"]. An adapter
# would put us in amp's tier and add a dependency we do not need.
#
# TRANSPORT is an embedded bun/TS server, NOT hand-rolled JSON-RPC in bash: ACP
# interleaves server-initiated `session/update` notifications with a still-open
# `session/prompt`, which is concurrent framing in a language with no JSON parser.
# Same embedding pattern as cmd_cos.sh — and the heredoc below is the ONLY copy of
# the server, deliberately: cos keeps a root-level cos-lib.ts beside its heredoc with
# nothing guarding the two against drift, and one loader per filename is enough.
ACP_RUN_DIR_DEFAULT="/opt/5dive"

# WHERE THE SERVER STAGES — a LIST, because the first entry is root's (DIVE-3361).
#
# /opt/5dive is this VM's layout and stays FIRST so a managed box is unchanged. But
# `5dive acp` exists to be spawned on a machine that is not ours, and the ACP
# registry's required verify-auth job runs us as an unprivileged sandbox user: there
# the very first thing the verb does is `cat > /opt/5dive/acp-server.ts`, which is
# Permission denied, so initialize is never answered and the listing fails with no
# ACP frame on the wire at all. ACP_RUN_DIR already existed as an override, and an
# override is no help — the DEFAULT is what a client spawning us gets.
#
# An explicit ACP_RUN_DIR is the ONLY candidate when set: falling back past a
# directory the caller named would stage somewhere they did not ask for and exec it.
#
# NO /tmp TIER ON PURPOSE. We `exec` the file we stage, and mkdir -p succeeds
# straight through a symlink a local user pre-planted in a world-writable parent, so
# a /tmp fallback trades a clear error for a file somebody else can swap. With HOME
# and XDG_CACHE_HOME both unset the verb now fails naming ACP_RUN_DIR, which is
# actionable; that is the improvement over the dead pipe, and it does not need /tmp.
_acp_run_dir_candidates() {
  if [[ -n "${ACP_RUN_DIR:-}" ]]; then printf '%s\n' "$ACP_RUN_DIR"; return 0; fi
  printf '%s\n' "$ACP_RUN_DIR_DEFAULT"
  [[ -n "${XDG_CACHE_HOME:-}" ]] && printf '%s\n' "$XDG_CACHE_HOME/5dive"
  # Their client sets HOME to a fresh temp dir it creates, so this is the tier that
  # actually carries the registry run.
  [[ -n "${HOME:-}" ]] && printf '%s\n' "$HOME/.cache/5dive"
  return 0
}

# TWO NEAR-IDENTICAL COPIES OF THIS PROBE LIST EXIST AND WERE DELIBERATELY LEFT UNFIXED:
# _cos_resolve_bun (cmd_cos.sh) and _team_bot_resolve_bun (cmd_agent_teambot.sh). This one
# is the canonical/fixed copy — you are reading the answer to "which of the three is the
# bug". They still lack the PATH probe below, and neither has an env override at all, so
# unlike this function they cannot be driven off their hardcoded paths by any test. Left
# on purpose: both are VM-bound verbs (systemctl / useradd / /etc/5dive) that cannot
# meaningfully run on a user's laptop, so /usr/local/bin/bun is always present for them and
# the defect has zero user exposure — which is why it stays zero when the npm artifact
# ships, rather than expiring then. No ident filed; a latent duplicate that has blocked
# nothing does not earn a row. If a shared resolver is ever built, all three collapse into
# it (there is no lib/ in this repo today, which is why that was not done here).
_acp_resolve_bun() {
  local c
  # ACP_BUN_BIN: harness seam, and the escape hatch on a box with bun elsewhere.
  if [[ -n "${ACP_BUN_BIN:-}" ]]; then printf '%s' "$ACP_BUN_BIN"; return 0; fi
  for c in /usr/local/bin/bun /home/claude/.bun/bin/bun; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  # THE CALLER'S OWN PATH — required for the verb to work anywhere but our VM, not a CI
  # convenience. The two paths above are THIS box's layout, and the sudo probe below asks
  # a user that only exists here. But the whole point of `5dive acp` is to be selected as
  # a runtime on a machine that is not ours: a Buzz user on a Mac installs bun the
  # documented way (bun.sh/install -> ~/.bun/bin/bun) and has no `claude` user, so every
  # other probe misses and the literal fallback names a file that does not exist — exiting
  # E_NOT_INSTALLED to tell them to install the bun they already have. That is a
  # confidently actionable message that is wrong, which is worse than the dead pipe the
  # preflight replaced. Ordered ahead of the sudo probe: correct in a strict superset of
  # its cases and one fewer login shell.
  c=$(command -v bun 2>/dev/null)
  [[ -n "$c" && -x "$c" ]] && { printf '%s' "$c"; return 0; }
  c=$(sudo -u claude -i bash -lc 'command -v bun' 2>/dev/null | tail -1)
  [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  printf '/usr/local/bin/bun'
}

# Stage the embedded server into $1 (idempotent). Returns non-zero if $1 cannot take
# the file — mkdir is NOT the test, since the failing case on a shared box is an
# existing directory that is not ours to write (DIVE-3361).
_acp_install_runner() {
  mkdir -p "$1" || return 1
  cat > "$1/acp-server.ts" <<'ACP_SERVER_TS' || return 1
// DIVE-3017 — ACP over stdio for `5dive acp`. Staged by cmd_acp.sh; run on bun.
//
// stdout carries the PROTOCOL and nothing else. Every diagnostic goes to stderr —
// one stray println here is a parse error in the client, not a log line.
//
// ATTACH, NOT A BLANK SESSION. Selecting 5dive in a client's runtime picker must
// land on a NAMED agent in the fleet (memory, tasks, org, heartbeat intact); a
// fresh-session 5dive is just a worse coding agent in a list of coding agents.
// ACP gives exactly one surface that can carry that, and the two obvious ones are
// wrong:
//   - `session/new` params are exactly { cwd, mcpServers } — no selector.
//   - `session/load` resumes a sessionId the CLIENT already holds from us, so a
//     picker cannot offer fleet agents through it.
//   - `modes` MUST NOT carry it: Buzz consumes ACP modes as PERMISSION modes
//     (crates/buzz-acp/src/pool.rs :: agent_supports_mode), so agent names there
//     collide with a semantic it already relies on.
//   - `availableCommands` is the right surface: it is delivered as a
//     `session/update` notification, so it can be REFRESHED mid-session, and Buzz
//     consumes it (crates/buzz-acp/src/acp.rs handles `available_commands_update`
//     and reads the `availableCommands` array; the discriminator is `sessionUpdate`).
//
// The read loop dispatches WITHOUT awaiting, on purpose. `session/cancel` arrives
// as the next line while `session/prompt` is still open, so awaiting each line in
// turn deadlocks the cancel behind the thing it cancels — the same shape that bit
// the telegram-opencode bridge, where grammy's sequential update loop made a
// permission tap unprocessable while the handler blocked on the turn it gated.

const PROTOCOL_VERSION = 1; // Buzz's client sends 2 (crates/buzz-acp/src/acp.rs);
// its own agent fixtures answer 1, so negotiating down is the shape it expects. We
// answer with what we actually speak rather than claiming a version we have not read.

const RESERVED = new Set(["attach", "agents"]);
const sink = Bun.stdout.writer();

function send(msg: unknown): void {
  sink.write(JSON.stringify(msg) + "\n");
  sink.flush();
}
function log(s: string): void {
  try { process.stderr.write(`[5dive acp] ${s}\n`); } catch { /* stderr may be closed */ }
}
function ok(id: unknown, result: unknown): void { send({ jsonrpc: "2.0", id, result }); }
function err(id: unknown, code: number, message: string): void {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

// How we reach our own CLI. Root (the normal case — the client spawns us as the
// user that owns the fleet) calls it directly; a non-root caller needs the scoped
// sudoers grant every standard agent already has. ACP_CLI_BIN overrides both.
function cliArgv(): string[] {
  const override = process.env.ACP_CLI_BIN;
  if (override) return override.split(/\s+/).filter(Boolean);
  const uid = typeof process.getuid === "function" ? process.getuid() : 0;
  return uid === 0 ? ["5dive"] : ["sudo", "-n", "5dive"];
}

type Agent = { name: string; type?: string; model?: string; active?: string };

async function roster(): Promise<Agent[]> {
  const cmd = [...cliArgv(), "agent", "list", "--json"];
  try {
    const p = Bun.spawn({ cmd, stdout: "pipe", stderr: "pipe" });
    const out = await new Response(p.stdout).text();
    const code = await p.exited;
    if (code !== 0) {
      log(`agent list --json exited ${code}: ${(await new Response(p.stderr).text()).trim().slice(0, 200)}`);
      return [];
    }
    const j = JSON.parse(out);
    const d = (j && typeof j === "object" && "data" in j) ? (j as any).data : j;
    return Array.isArray(d) ? (d as Agent[]).filter((a) => a && typeof a.name === "string") : [];
  } catch (e) {
    log(`agent list --json unusable: ${(e as Error).message}`);
    return [];
  }
}

function commandsFor(agents: Agent[], attached: string | null) {
  const cmds: { name: string; description: string; input?: { hint: string } }[] = [
    {
      name: "attach",
      description: attached ? `re-attach this session (currently: ${attached})` : "attach this session to a fleet agent",
      input: { hint: "agent name" },
    },
    { name: "agents", description: "list the fleet agents this session can attach to" },
  ];
  for (const a of agents) {
    if (RESERVED.has(a.name)) {
      // Reachable as `/attach <name>`; shadowing `/attach` itself would be worse.
      log(`agent "${a.name}" collides with a reserved command name; reach it with /attach ${a.name}`);
      continue;
    }
    const bits = [a.type, a.model].filter(Boolean).join(", ");
    cmds.push({ name: a.name, description: `attach to ${a.name}${bits ? ` (${bits})` : ""}` });
  }
  return cmds;
}

function rosterText(agents: Agent[], attached: string | null): string {
  if (!agents.length) return "No fleet agents are visible from here (`5dive agent list --json` returned none).";
  const lines = agents.map((a) => {
    const bits = [a.type, a.model].filter(Boolean).join(", ");
    return `  /${a.name}${bits ? `  — ${bits}` : ""}${a.name === attached ? "   (attached)" : ""}`;
  });
  return `Fleet agents:\n${lines.join("\n")}\n\nAttach with /<name> or /attach <name>.`;
}

type Session = {
  id: string;
  cwd: string;
  attached: string | null;
  proc: { kill: (sig?: number | string) => void } | null;
  cancelled: boolean;
};
const sessions = new Map<string, Session>();
let seq = 0;

function chunk(s: Session, text: string): void {
  send({
    jsonrpc: "2.0",
    method: "session/update",
    params: { sessionId: s.id, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
}
function pushCommands(s: Session, agents: Agent[]): void {
  send({
    jsonrpc: "2.0",
    method: "session/update",
    params: { sessionId: s.id, update: { sessionUpdate: "available_commands_update", availableCommands: commandsFor(agents, s.attached) } },
  });
}

function promptText(blocks: unknown): string {
  if (!Array.isArray(blocks)) return "";
  return blocks
    .filter((b: any) => b && b.type === "text" && typeof b.text === "string")
    .map((b: any) => b.text)
    .join("\n")
    .trim();
}

// One turn = one `5dive agent ask <name> <text>`: a synchronous send into the named
// agent's live seat plus a bounded read of its reply. BOUND, stated rather than
// smoothed over: the reply arrives in whatever pieces `agent ask` prints, so this
// streams at the granularity of that command, not per token. It is a real turn on
// a real agent, not an incremental one.
async function runTurn(id: unknown, s: Session, body: string): Promise<void> {
  if (!body) { chunk(s, "(empty prompt — nothing sent)"); return ok(id, { stopReason: "end_turn" }); }
  const timeout = process.env.ACP_ASK_TIMEOUT || "180";
  const cmd = [...cliArgv(), "agent", "ask", s.attached as string, body, `--timeout=${timeout}`];
  let p;
  try {
    p = Bun.spawn({ cmd, stdout: "pipe", stderr: "pipe" });
  } catch (e) {
    chunk(s, `[5dive] could not run \`agent ask\`: ${(e as Error).message}`);
    return ok(id, { stopReason: "end_turn" });
  }
  s.proc = p;
  let saw = false;
  const dec = new TextDecoder();
  for await (const c of p.stdout as any) {
    const t = dec.decode(c as Uint8Array, { stream: true });
    if (t) { saw = true; chunk(s, t); }
  }
  const code = await p.exited;
  s.proc = null;
  if (s.cancelled) { s.cancelled = false; return ok(id, { stopReason: "cancelled" }); }
  if (code !== 0) {
    const tail = (await new Response(p.stderr).text()).trim().split("\n").slice(-3).join("\n");
    chunk(s, `\n[5dive] agent ask ${s.attached} exited ${code}${tail ? `: ${tail}` : ""}`);
  } else if (!saw) {
    chunk(s, `[5dive] ${s.attached} produced no reply within ${timeout}s.`);
  }
  return ok(id, { stopReason: "end_turn" });
}

async function attachTo(id: unknown, s: Session, name: string, trailing: string): Promise<void> {
  const agents = await roster();
  if (!agents.some((a) => a.name === name)) {
    chunk(s, `No fleet agent named "${name}".\n\n${rosterText(agents, s.attached)}`);
    pushCommands(s, agents);
    return ok(id, { stopReason: "end_turn" });
  }
  s.attached = name;
  pushCommands(s, agents); // refreshed mid-session: the point of using availableCommands
  if (trailing) return runTurn(id, s, trailing);
  chunk(s, `Attached to ${name}. Its memory, tasks, org position and heartbeat are the ones you already have — this session is a front end onto that agent, not a new one.`);
  return ok(id, { stopReason: "end_turn" });
}

async function handlePrompt(id: unknown, params: any): Promise<void> {
  const s = sessions.get(params?.sessionId);
  if (!s) return err(id, -32602, `unknown sessionId: ${params?.sessionId}`);
  const text = promptText(params?.prompt);
  const m = /^\/([A-Za-z0-9._-]+)\s*([\s\S]*)$/.exec(text);
  if (m) {
    const verb = m[1];
    const rest = (m[2] || "").trim();
    if (verb === "agents") {
      const agents = await roster();
      chunk(s, rosterText(agents, s.attached));
      pushCommands(s, agents);
      return ok(id, { stopReason: "end_turn" });
    }
    if (verb === "attach") {
      if (!rest) {
        const agents = await roster();
        chunk(s, `Name the agent to attach to.\n\n${rosterText(agents, s.attached)}`);
        return ok(id, { stopReason: "end_turn" });
      }
      const parts = rest.split(/\s+/);
      return attachTo(id, s, parts[0], parts.slice(1).join(" "));
    }
    const agents = await roster();
    if (agents.some((a) => a.name === verb)) return attachTo(id, s, verb, rest);
    // Not one of ours — fall through and let the attached agent read the text.
  }
  if (!s.attached) {
    const agents = await roster();
    chunk(s, `Not attached yet. A 5dive session is a front end onto a NAMED agent in the fleet, so there is nobody to send that to.\n\n${rosterText(agents, null)}`);
    pushCommands(s, agents);
    return ok(id, { stopReason: "end_turn" });
  }
  return runTurn(id, s, text);
}

// One turn at a time PER SESSION. A client sends one prompt per session and waits,
// and serializing here is what stops a queued prompt from overtaking the /attach
// that precedes it. `session/cancel` stays OUT of this chain on purpose — it is the
// one thing that must run WHILE a prompt is open.
const chain = new Map<string, Promise<void>>();
function serialize(sid: string, fn: () => Promise<void>): Promise<void> {
  const prev = chain.get(sid) ?? Promise.resolve();
  const next = prev.then(fn, fn);
  chain.set(sid, next.then(() => {}, () => {}));
  return next;
}

async function dispatch(line: string): Promise<void> {
  let msg: any;
  try { msg = JSON.parse(line); } catch { log(`unparseable line dropped: ${line.slice(0, 120)}`); return; }
  const { id, method, params } = msg ?? {};
  if (typeof method !== "string") return;

  if (method === "initialize") {
    const want = Number(params?.protocolVersion);
    return ok(id, {
      protocolVersion: Number.isFinite(want) ? Math.min(want, PROTOCOL_VERSION) : PROTOCOL_VERSION,
      agentCapabilities: {
        loadSession: false,
        promptCapabilities: { image: false, audio: false, embeddedContext: false },
      },
      // DIVE-3361 — AT LEAST ONE authMethod, and an empty array is not a smaller
      // answer, it is the whole ACP registry listing. Their REQUIRED verify-auth
      // job spawns us and reads exactly this frame
      // (.github/workflows/client.py :: validate_auth_methods):
      //     if not auth_methods: return False, "No authMethods in response"
      // so `authMethods: []` is rejected on the first exchange, before anything
      // else about the agent is looked at.
      //
      // NO `type` FIELD, deliberately: the spec's AuthMethod is { id, name,
      // description } and `type` is not in it. Their parser INFERS the type it
      // gates on — `_meta` "terminal-auth" -> terminal, "agent-auth" -> agent,
      // and absent both it defaults to "agent" — so the `_meta` key states it
      // through the documented extension channel instead of inventing a field or
      // leaning on their default staying where it is.
      //
      // It is also TRUE rather than a checkbox. There is no 5dive sign-in to
      // perform in this process: the server shells to the local `5dive`, which
      // carries its own credentials and audit trail, which is why `authenticate`
      // below has nothing to do and answers {}.
      authMethods: [
        {
          id: "5dive-cli",
          name: "5dive CLI credentials",
          description:
            "Uses the credentials of the 5dive CLI already installed here. No separate sign-in step: if `5dive agent list` shows your fleet, this is authenticated.",
          _meta: { "agent-auth": true },
        },
      ],
    });
  }
  if (method === "authenticate") return ok(id, {});
  if (method === "session/new") {
    const s: Session = { id: `5dive-${++seq}`, cwd: String(params?.cwd ?? process.cwd()), attached: null, proc: null, cancelled: false };
    sessions.set(s.id, s);
    ok(id, { sessionId: s.id });          // the client needs the id before the update
    pushCommands(s, await roster());      // then the roster it will render
    return;
  }
  if (method === "session/prompt") return serialize(String(params?.sessionId), () => handlePrompt(id, params));
  if (method === "session/cancel") {
    const s = sessions.get(params?.sessionId);
    if (s) { s.cancelled = true; try { s.proc?.kill(); } catch { /* already gone */ } }
    return; // notification: no response
  }
  if (method === "session/load") return err(id, -32601, "session/load is not supported (agentCapabilities.loadSession is false)");
  if (id === undefined) return;           // unknown notification: ignore, per JSON-RPC
  return err(id, -32601, `unknown method: ${method}`);
}

const inflight = new Set<Promise<void>>();
const dec = new TextDecoder();
let buf = "";
for await (const c of Bun.stdin.stream()) {
  buf += dec.decode(c as Uint8Array, { stream: true });
  let i: number;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    const t = dispatch(line).catch((e) => log(`dispatch failed: ${(e as Error).message}`));
    inflight.add(t);
    void t.finally(() => inflight.delete(t));
  }
}
// stdin closed: finish what is open rather than dropping a turn on the floor.
while (inflight.size) await Promise.allSettled([...inflight]);
ACP_SERVER_TS
  chmod 644 "$1/acp-server.ts" || return 1
}

cmd_acp() {
  local a
  for a in "$@"; do
    case "$a" in
      -h|--help) printf '%s\n' "usage: 5dive acp   # ACP over stdio; spawned BY an ACP client (Buzz, Zed). Not interactive."; return 0 ;;
      *) fail "$E_USAGE" "5dive acp takes no arguments (got: $a)" ;;
    esac
  done
  local bun; bun=$(_acp_resolve_bun)
  # PREFLIGHT, and it is load-bearing. presets.rs renders NotInstalled only when the
  # COMMAND is absent, so with `5dive` on PATH and bun missing the client spawns us
  # and gets a process that dies with no reason attached. Say why, on stderr, once.
  [[ -x "$bun" ]] || fail "$E_NOT_INSTALLED" "bun not found at $bun — 5dive acp runs its ACP server on bun. Install it (curl -fsSL https://bun.sh/install | bash) or point ACP_BUN_BIN at an existing binary."
  # First candidate that actually TAKES the file wins; the per-attempt stderr is
  # dropped because a Permission denied on /opt is expected off our VM, not news.
  # A total failure names every directory tried, which is the message that used to
  # name only /opt/5dive on a box where /opt was never the reachable one.
  local dir="" cand tried=""
  while IFS= read -r cand; do
    [[ -n "$cand" ]] || continue
    tried="${tried:+$tried, }$cand"
    if _acp_install_runner "$cand" 2>/dev/null; then dir="$cand"; break; fi
  done < <(_acp_run_dir_candidates)
  [[ -n "$dir" ]] || fail "$E_GENERIC" "could not stage the ACP server in any of: ${tried:-<none: HOME and XDG_CACHE_HOME are both unset>} — point ACP_RUN_DIR at a writable directory."
  [[ -t 0 ]] && printf '%s\n' "5dive acp speaks JSON-RPC on stdin/stdout; you are on a TTY. This verb is meant to be spawned by an ACP client." >&2
  # `exec` hands the pipes straight to bun. Note for whoever reads the audit log:
  # this replaces the process, so the dispatcher's EXIT-trap row never fires
  # (DIVE-2797). The row is emitted below, before the exec, for that reason.
  if declare -F audit_log >/dev/null 2>&1 && [[ -n "${AUDIT_LOG:-}" ]]; then
    audit_log "acp" "start" 0 -- "runner=$dir" || true
  fi
  exec "$bun" "$dir/acp-server.ts"
}
