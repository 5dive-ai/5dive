# DIVE-7558: the office chat server's bun source, staged root-owned by
# _local_chat_stage (src/cmd_local_chat.sh). Kept as one heredoc so the CLI
# bundle carries it (the same pattern as src/cmd_chat.sh's chat-e2e.ts).
_local_chat_server_ts() {
  cat <<'LOCAL_CHAT_TS'
// DIVE-7558: the office chat server. One bun process, two listeners:
//
//   LOOPBACK (http://127.0.0.1:<loop port>) — the box side. It answers the SAME
//     endpoints the dashboard adapter's root rail calls on api.5dive.com
//     (/server/messages/pending [+ long poll], pending/ack, event, status,
//     /server/selfhost/files, /server/selfhost/heard) with the same box-token
//     bearer, so the agent side is unchanged: /etc/5dive/api-base points the
//     rail here. Plus POST /local/notice (no token, loopback only): a gate
//     notice or owner question, shown in the chat instead of Telegram.
//   LAN (https://<office address>:<lan port>, self-signed) — the browser side:
//     the chat page and its /api/*. A device is let in once with a one-time
//     pairing code (`sudo 5dive local pair`), then by an HttpOnly cookie.
//
// Store: one sqlite file in the state dir. Files: bytes under <state>/files.
// No end-to-end sealing in this mode: the box is the only server and TLS covers
// the LAN hop, so an e2e envelope posted here is refused, never stored.
//
//   bun local_chat_server.ts serve
//   bun local_chat_server.ts admin pair-add <sha256-hex> <expires-epoch-s> [chat|owner]
//   bun local_chat_server.ts admin devices-ls
//   bun local_chat_server.ts admin devices-revoke <id>
import { Database } from "bun:sqlite";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const env = process.env;
const STATE = env.LC_STATE || "/var/lib/5dive-local-chat";
const LAN_ADDR = env.LC_LAN_ADDR || "0.0.0.0";
const LAN_PORT = Number(env.LC_LAN_PORT || 8443);
const LOOP_PORT = Number(env.LC_LOOP_PORT || 8480);
const CRED = env.CREDENTIALS_DIRECTORY || "";
const CERT = env.LC_CERT || (CRED ? join(CRED, "cert") : "");
const KEY = env.LC_KEY || (CRED ? join(CRED, "key") : "");
const TOKEN_FILE = env.LC_TOKEN_FILE || (CRED ? join(CRED, "token") : "");
const AGENTS_FILE = env.LC_AGENTS_FILE || "/etc/5dive/local-chat/agents.json";
const UPLOADS = (env.LC_UPLOADS || "/home/claude/chat-uploads").replace(/\/+$/, "");
const FILE_MAX = Number(env.LC_FILE_MAX || 20 * 1024 * 1024);
const WAIT_MAX = 25;
const AGENT_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const NOTICE_AGENT = "5dive";
// DIVE-7576: the office control panel's one door to root (src/cmd_local_panel.sh).
const PANEL_SOCK = env.LC_PANEL_SOCK || "/run/5dive-local-panel.sock";

mkdirSync(join(STATE, "files"), { recursive: true, mode: 0o700 });
const db = new Database(join(STATE, "chat.db"), { create: true });
db.exec("PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;");
db.exec(`
CREATE TABLE IF NOT EXISTS messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT NOT NULL,
  dir TEXT NOT NULL CHECK (dir IN ('in','out')),
  body TEXT NOT NULL,
  meta TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  collected_at TEXT,
  device TEXT
);
CREATE INDEX IF NOT EXISTS messages_agent ON messages (agent, id);
CREATE TABLE IF NOT EXISTS pair_codes (hash TEXT PRIMARY KEY, expires INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, cookie_hash TEXT NOT NULL UNIQUE,
  created INTEGER NOT NULL, last_seen INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS files (
  path TEXT PRIMARY KEY, blob TEXT NOT NULL, name TEXT NOT NULL, size INTEGER NOT NULL, created INTEGER NOT NULL
);
`);
// DIVE-7576: device roles. A device paired before roles existed is chat-only.
// Added in place on a live db (CREATE TABLE IF NOT EXISTS never adds a column).
for (const [t, col] of [["devices", "role"], ["pair_codes", "role"]]) {
  const cols = db.query(`PRAGMA table_info(${t})`).all() as { name: string }[];
  if (!cols.some((c) => c.name === col)) db.exec(`ALTER TABLE ${t} ADD COLUMN role TEXT NOT NULL DEFAULT 'chat'`);
}

const now = () => Math.floor(Date.now() / 1000);
const sha256 = (s: string | Uint8Array) => createHash("sha256").update(s).digest("hex");
const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });

// ── admin (run as the server user by the CLI; never over the network) ────────
if (process.argv[2] === "admin") {
  const [op, a, b] = process.argv.slice(3);
  const role = process.argv[6] ?? "chat";
  if (op === "pair-add" && /^[0-9a-f]{64}$/.test(a || "") && /^\d+$/.test(b || "") && (role === "chat" || role === "owner")) {
    db.query("DELETE FROM pair_codes WHERE expires < ? OR used = 1").run(now());
    db.query("INSERT OR REPLACE INTO pair_codes (hash, expires, role) VALUES (?, ?, ?)").run(a, Number(b), role);
    console.log(JSON.stringify({ ok: true }));
  } else if (op === "devices-ls") {
    console.log(JSON.stringify(db.query("SELECT id, name, role, created, last_seen, revoked FROM devices ORDER BY created").all()));
  } else if (op === "devices-revoke" && /^[a-f0-9]{8,32}$/.test(a || "")) {
    const r = db.query("UPDATE devices SET revoked = 1 WHERE id = ? AND revoked = 0").run(a);
    console.log(JSON.stringify({ ok: r.changes > 0 }));
    process.exit(r.changes > 0 ? 0 : 3);
  } else {
    console.error("usage: admin pair-add <sha256> <expires> [chat|owner] | devices-ls | devices-revoke <id>");
    process.exit(2);
  }
  process.exit(0);
}
if (process.argv[2] !== "serve") {
  console.error("usage: local_chat_server.ts serve | admin ...");
  process.exit(2);
}

// ── box token (re-read on every call, so a rotation needs no restart) ─────────
function boxToken(): string {
  try {
    const m = readFileSync(TOKEN_FILE, "utf8").match(/^CONNECTORD_TOKEN=(.*)$/m);
    return (m?.[1] ?? "").trim().replace(/^["']|["']$/g, "");
  } catch {
    return "";
  }
}
function boxAuthed(req: Request): boolean {
  const tok = boxToken();
  const got = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!tok || !got) return false;
  const x = Buffer.from(sha256(tok)), y = Buffer.from(sha256(got));
  return timingSafeEqual(x, y);
}

// ── wakeups: a long poll waits on these ───────────────────────────────────────
const waiters = new Set<() => void>();
function wake() {
  for (const w of [...waiters]) w();
}
async function waitFor<T>(read: () => T[], seconds: number, signal?: AbortSignal): Promise<T[]> {
  let rows = read();
  const deadline = Date.now() + Math.min(Math.max(seconds, 0), WAIT_MAX) * 1000;
  while (rows.length === 0 && Date.now() < deadline && !signal?.aborted) {
    await new Promise<void>((resolve) => {
      const done = () => { waiters.delete(done); clearTimeout(t); resolve(); };
      const t = setTimeout(done, deadline - Date.now());
      waiters.add(done);
      signal?.addEventListener("abort", done, { once: true });
    });
    rows = read();
  }
  return rows;
}

// ── state shown on the page ───────────────────────────────────────────────────
const status = new Map<string, { active: boolean; label: string | null; ts: number }>();
const seen = new Set<string>();
function agents(): string[] {
  let list: string[] = [];
  try {
    const raw = JSON.parse(readFileSync(AGENTS_FILE, "utf8"));
    if (Array.isArray(raw)) list = raw.filter((n) => typeof n === "string" && AGENT_RE.test(n));
  } catch {}
  for (const n of seen) if (!list.includes(n)) list.push(n);
  const notices = db.query("SELECT 1 FROM messages WHERE agent = ? LIMIT 1").get(NOTICE_AGENT);
  if (notices && !list.includes(NOTICE_AGENT)) list.push(NOTICE_AGENT);
  return list;
}

type Row = { id: number; agent: string; dir: string; body: string; meta: string; created_at: string };
const serialize = (r: Row) => ({
  id: r.id, agent: r.agent, from: r.dir === "in" ? "you" : r.agent, text: r.body,
  meta: JSON.parse(r.meta || "{}"), ts: r.created_at,
});

function insert(agent: string, dir: "in" | "out", body: string, meta: object, device: string | null = null) {
  const r = db
    .query("INSERT INTO messages (agent, dir, body, meta, created_at, device) VALUES (?, ?, ?, ?, ?, ?) RETURNING id")
    .get(agent, dir, body, JSON.stringify(meta), new Date().toISOString(), device) as { id: number };
  wake();
  return r.id;
}

// ── files ─────────────────────────────────────────────────────────────────────
async function storeFile(path: string, name: string, bytes: Uint8Array) {
  const blob = sha256(bytes);
  const dest = join(STATE, "files", blob);
  if (!existsSync(dest)) writeFileSync(dest, bytes, { mode: 0o600 });
  db.query("INSERT OR REPLACE INTO files (path, blob, name, size, created) VALUES (?, ?, ?, ?, ?)")
    .run(path, blob, name, bytes.length, now());
}
function fileRow(path: string) {
  return db.query("SELECT path, blob, name, size FROM files WHERE path = ?").get(path) as
    | { path: string; blob: string; name: string; size: number } | null;
}
function serveFile(path: string, download: boolean) {
  const f = fileRow(path);
  if (!f) return json({ error: "not found" }, 404);
  const headers: Record<string, string> = { "content-type": "application/octet-stream", "content-length": String(f.size) };
  if (download) headers["content-disposition"] = `attachment; filename="${f.name.replace(/[^\w.\- ]/g, "_")}"`;
  return new Response(Bun.file(join(STATE, "files", f.blob)), { headers });
}
async function readBody(req: Request): Promise<Uint8Array | null> {
  const len = Number(req.headers.get("content-length") ?? 0);
  if (len > FILE_MAX) return null;
  const buf = new Uint8Array(await req.arrayBuffer());
  return buf.length > FILE_MAX ? null : buf;
}
const safeName = (s: string) => (s.split("/").pop() || "file").replace(/[^\w.\- ]/g, "_").slice(0, 120) || "file";

// An agent's reply names files on the box. A file the adapter `put` first is
// already stored under that path; otherwise read it from disk if this server's
// user may (the chat outbox is world-readable), and keep a copy.
async function adoptFile(path: string): Promise<{ path: string; name: string; size: number } | null> {
  let f = fileRow(path);
  if (!f) {
    try {
      const st = statSync(path);
      if (!st.isFile() || st.size > FILE_MAX) return null;
      await storeFile(path, safeName(path), new Uint8Array(readFileSync(path)));
      f = fileRow(path);
    } catch {
      return null;
    }
  }
  return f ? { path: f.path, name: f.name, size: f.size } : null;
}

// ── box side ──────────────────────────────────────────────────────────────────
async function boxSide(req: Request, url: URL): Promise<Response> {
  const p = url.pathname;
  if (p === "/local/notice" && req.method === "POST") {
    let b: { agent?: unknown; text?: unknown };
    try { b = await req.json(); } catch { return json({ error: "invalid body" }, 400); }
    const text = typeof b.text === "string" ? b.text.trim() : "";
    if (!text || text.length > 8192) return json({ error: "text is empty or over 8 KiB" }, 400);
    const agent = typeof b.agent === "string" && AGENT_RE.test(b.agent) ? b.agent : NOTICE_AGENT;
    const id = insert(agent, "out", text, { notice: true });
    return json({ ok: true, id });
  }
  if (!boxAuthed(req)) return json({ error: "unauthorized" }, 401);

  if (p === "/server/messages/pending" && req.method === "GET") {
    const agent = url.searchParams.get("agent") ?? "";
    if (!AGENT_RE.test(agent)) return json({ error: "invalid agent" }, 400);
    seen.add(agent);
    const read = () =>
      db.query("SELECT * FROM messages WHERE agent = ? AND dir = 'in' AND collected_at IS NULL ORDER BY id LIMIT 50")
        .all(agent) as Row[];
    const wait = Number(url.searchParams.get("wait") ?? 0) || 0;
    const rows = await waitFor(read, wait, req.signal);
    return json({
      pending: rows.map((r) => {
        const m = JSON.parse(r.meta || "{}");
        return {
          id: r.id, text: r.body, from: "dashboard", chat_id: r.agent, ts: r.created_at,
          ...(typeof m.image_path === "string" ? { image_path: m.image_path } : {}),
        };
      }),
    });
  }
  if (p === "/server/messages/pending/ack" && req.method === "POST") {
    let b: { agent?: unknown; ids?: unknown };
    try { b = await req.json(); } catch { return json({ error: "invalid body" }, 400); }
    const agent = typeof b.agent === "string" ? b.agent : "";
    if (!AGENT_RE.test(agent)) return json({ error: "invalid agent" }, 400);
    const ids = Array.isArray(b.ids) ? b.ids.filter((v) => Number.isInteger(v) && v > 0).slice(0, 500) : [];
    let acked = 0;
    const q = db.query("UPDATE messages SET collected_at = ? WHERE id = ? AND agent = ? AND dir = 'in' AND collected_at IS NULL");
    for (const id of ids) acked += q.run(new Date().toISOString(), id, agent).changes;
    return json({ ok: true, acked });
  }
  if (p === "/server/messages/event" && req.method === "POST") {
    let b: { agent?: unknown; body?: unknown; metadata?: any };
    try { b = await req.json(); } catch { return json({ error: "invalid body" }, 400); }
    const agent = typeof b.agent === "string" ? b.agent : "";
    const text = typeof b.body === "string" ? b.body : "";
    if (!AGENT_RE.test(agent)) return json({ error: "invalid agent" }, 400);
    if (!text.trim()) return json({ error: "empty body" }, 400);
    if (text.length > 65536) return json({ error: "body too long" }, 413);
    const md = b.metadata && typeof b.metadata === "object" ? b.metadata : {};
    if (md.e2e) return json({ error: "this office chat is not end-to-end sealed", reason: "e2e_off_local" }, 409);
    seen.add(agent);
    const meta: Record<string, unknown> = {};
    if (Array.isArray(md.files)) {
      const files = [];
      for (const f of md.files.slice(0, 10)) if (typeof f === "string") { const a = await adoptFile(f); if (a) files.push(a); }
      if (files.length) meta.files = files;
    }
    const qn = md.question;
    if (qn && typeof qn.id === "string" && Array.isArray(qn.options)) {
      meta.question = {
        id: qn.id.slice(0, 64),
        options: qn.options.slice(0, 10).filter((o: any) => typeof o?.label === "string")
          .map((o: any) => ({ label: o.label.slice(0, 120), ...(typeof o.description === "string" ? { description: o.description.slice(0, 200) } : {}) })),
      };
    }
    status.set(agent, { active: false, label: null, ts: now() });
    const id = insert(agent, "out", text, meta);
    return json({ ok: true, id, conversation: agent });
  }
  if (p === "/server/messages/status" && req.method === "POST") {
    let b: { agent?: unknown; active?: unknown; label?: unknown };
    try { b = await req.json(); } catch { return json({ error: "invalid body" }, 400); }
    const agent = typeof b.agent === "string" ? b.agent : "";
    if (!AGENT_RE.test(agent)) return json({ error: "invalid agent" }, 400);
    const label = typeof b.label === "string" ? b.label.slice(0, 120) : null;
    status.set(agent, { active: b.active === true, label, ts: now() });
    seen.add(agent);
    wake();
    return json({ ok: true, conversation: agent });
  }
  if (p === "/server/selfhost/files") {
    const path = url.searchParams.get("path") ?? "";
    if (!path.startsWith("/") || path.length > 1024) return json({ error: "invalid path" }, 400);
    if (req.method === "GET") return serveFile(path, false);
    if (req.method === "POST") {
      const bytes = await readBody(req);
      if (!bytes) return json({ error: "file too large" }, 413);
      await storeFile(path, safeName(path), bytes);
      return json({ ok: true, size: bytes.length });
    }
  }
  if (p === "/server/selfhost/heard" && req.method === "POST") return json({ ok: true });
  return json({ error: "not found" }, 404);
}

// ── browser side ──────────────────────────────────────────────────────────────
type Device = { id: string; name: string; role: string };
function deviceOf(req: Request): Device | null {
  const m = (req.headers.get("cookie") ?? "").match(/(?:^|;\s*)lc_dev=([A-Za-z0-9_-]{20,100})/);
  if (!m) return null;
  const d = db.query("SELECT id, name, role FROM devices WHERE cookie_hash = ? AND revoked = 0").get(sha256(m[1])) as
    | Device | null;
  if (d) db.query("UPDATE devices SET last_seen = ? WHERE id = ?").run(now(), d.id);
  return d;
}

const pairTries: number[] = [];
async function browserSide(req: Request, url: URL): Promise<Response> {
  const p = url.pathname;
  if ((p === "/" || p === "/panel") && req.method === "GET")
    return new Response(p === "/" ? PAGE : PANEL_PAGE, {
      headers: {
        "content-type": "text/html; charset=utf-8",
        "content-security-policy": "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data: blob:",
        "x-frame-options": "DENY",
        "referrer-policy": "no-referrer",
      },
    });
  // Every write carries a custom header, so a page on another origin cannot
  // post with this device's cookie (it would need a CORS preflight we refuse).
  if (req.method === "POST" && req.headers.get("x-local-chat") !== "1") return json({ error: "forbidden" }, 403);

  if (p === "/api/pair" && req.method === "POST") {
    const t = Date.now();
    while (pairTries.length && pairTries[0] < t - 60_000) pairTries.shift();
    if (pairTries.length >= 10) return json({ error: "too many tries, wait a minute" }, 429);
    pairTries.push(t);
    let b: { code?: unknown; name?: unknown };
    try { b = await req.json(); } catch { return json({ error: "invalid body" }, 400); }
    const code = typeof b.code === "string" ? b.code.replace(/[\s-]/g, "").toUpperCase() : "";
    const row = db.query("SELECT hash, role FROM pair_codes WHERE hash = ? AND used = 0 AND expires >= ?").get(sha256(code), now()) as
      | { hash: string; role: string } | null;
    if (!code || !row) return json({ error: "That code is wrong or expired." }, 403);
    db.query("UPDATE pair_codes SET used = 1 WHERE hash = ?").run(sha256(code));
    const cookie = randomBytes(32).toString("base64url");
    const id = randomBytes(6).toString("hex");
    const name = (typeof b.name === "string" ? b.name : "").replace(/[^\w .'-]/g, "").slice(0, 40) || "device";
    const role = row.role === "owner" ? "owner" : "chat";
    db.query("INSERT INTO devices (id, name, cookie_hash, created, last_seen, role) VALUES (?, ?, ?, ?, ?, ?)")
      .run(id, name, sha256(cookie), now(), now(), role);
    return json({ ok: true, device: id, role }, 200, {
      "set-cookie": `lc_dev=${cookie}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000`,
    });
  }

  const dev = deviceOf(req);
  if (!dev) return json({ error: "pair this device first" }, 401);

  if (p === "/api/agents" && req.method === "GET") {
    const last = db.query("SELECT * FROM messages WHERE agent = ? ORDER BY id DESC LIMIT 1");
    return json({
      device: dev.name,
      role: dev.role,
      agents: agents().map((name) => {
        const l = last.get(name) as Row | null;
        return { name, status: status.get(name) ?? null, last: l ? serialize(l) : null };
      }),
    });
  }
  if (p === "/api/messages" && req.method === "GET") {
    const agent = url.searchParams.get("agent") ?? "";
    if (!AGENT_RE.test(agent)) return json({ error: "invalid agent" }, 400);
    const since = Number(url.searchParams.get("since") ?? 0) || 0;
    const statusAt = Number(url.searchParams.get("status_at") ?? 0) || 0;
    const read = () => {
      const rows = since
        ? (db.query("SELECT * FROM messages WHERE agent = ? AND id > ? ORDER BY id LIMIT 200").all(agent, since) as Row[])
        : (db.query("SELECT * FROM (SELECT * FROM messages WHERE agent = ? ORDER BY id DESC LIMIT 100) ORDER BY id").all(agent) as Row[]);
      // A status change ends the wait too, so the live line moves.
      return rows.length || (status.get(agent)?.ts ?? 0) > statusAt ? [rows] : [];
    };
    const wait = since ? Number(url.searchParams.get("wait") ?? 0) || 0 : 0;
    const got = await waitFor(read, wait, req.signal);
    return json({ messages: (got[0] ?? []).map(serialize), status: status.get(agent) ?? null });
  }
  if (p === "/api/messages" && req.method === "POST") {
    let b: { agent?: unknown; text?: unknown; files?: unknown };
    try { b = await req.json(); } catch { return json({ error: "invalid body" }, 400); }
    const agent = typeof b.agent === "string" ? b.agent : "";
    if (!AGENT_RE.test(agent) || agent === NOTICE_AGENT) return json({ error: "invalid agent" }, 400);
    let text = typeof b.text === "string" ? b.text.trim() : "";
    const files = Array.isArray(b.files) ? b.files.filter((f) => typeof f === "string" && fileRow(f)).slice(0, 10) : [];
    if (!text && !files.length) return json({ error: "empty message" }, 400);
    if (text.length > 65536) return json({ error: "message too long" }, 413);
    const meta: Record<string, unknown> = {};
    if (files.length) {
      meta.files = files.map((f) => { const r = fileRow(f)!; return { path: r.path, name: r.name, size: r.size }; });
      meta.image_path = files[0];
      const extra = files.slice(1).map((f) => `[file: ${f}]`).join("\n");
      if (extra) text = text ? `${text}\n${extra}` : extra;
      if (!text) text = `[file: ${fileRow(files[0])!.name}]`;
    }
    const id = insert(agent, "in", text, meta, dev.id);
    return json({ ok: true, id });
  }
  if (p === "/api/files" && req.method === "POST") {
    const agent = url.searchParams.get("agent") ?? "";
    if (!AGENT_RE.test(agent)) return json({ error: "invalid agent" }, 400);
    const bytes = await readBody(req);
    if (!bytes || !bytes.length) return json({ error: "file is empty or over 20 MB" }, 413);
    const name = safeName(url.searchParams.get("name") ?? "file");
    const path = `${UPLOADS}/${agent}/${Date.now()}-${randomBytes(3).toString("hex")}-${name}`;
    await storeFile(path, name, bytes);
    return json({ ok: true, path, name, size: bytes.length });
  }
  if (p === "/api/files" && req.method === "GET") return serveFile(url.searchParams.get("path") ?? "", true);
  if (p.startsWith("/api/panel/")) return panelSide(req, p, dev);
  return json({ error: "not found" }, 404);
}

// ── panel side (DIVE-7576): owner devices only ───────────────────────────────
// Every action goes to root through the one socket (panelExec); this process
// never acts as root and passes only the verb and fixed-position arguments.
// The root side re-checks every argument (src/cmd_local_panel.sh).
type PanelReply = { ok: boolean; data?: any; error?: string };
function panelExec(argv: string[], device: string, input = "", timeoutMs = 900_000): Promise<PanelReply> {
  // Bun.connect, not node:net: the request ends with a half-close (the root
  // side reads the value to EOF), and Bun's node:net client drops the answer
  // after end(). shutdown() sends FIN and keeps reading.
  return new Promise((resolve) => {
    const chunks: Uint8Array[] = [];
    let done = false;
    const finish = (r: PanelReply) => { if (!done) { done = true; clearTimeout(t); resolve(r); } };
    const down = () => finish({ ok: false, error: "The panel helper is not running. On the server: sudo 5dive local serve" });
    let sock: { end(): void } | null = null;
    const t = setTimeout(() => { sock?.end(); finish({ ok: false, error: "that took too long" }); }, timeoutMs);
    Bun.connect({
      unix: PANEL_SOCK,
      socket: {
        open(s) { sock = s; s.write(JSON.stringify({ argv, device }) + "\n"); if (input) s.write(input); s.shutdown(); },
        data(_s, d) { chunks.push(d); },
        close() {
          try { finish(JSON.parse(Buffer.concat(chunks).toString("utf8").trim() || "null") ?? { ok: false, error: "no answer" }); }
          catch { finish({ ok: false, error: "the panel helper gave an answer this page cannot read" }); }
        },
        error() { down(); },
        connectError() { down(); },
      },
    }).catch(down);
  });
}
const reply = (r: PanelReply) => json(r, r.ok ? 200 : 422);
const str = (v: unknown, max = 200) => (typeof v === "string" && v.length <= max ? v : "");

async function panelSide(req: Request, p: string, dev: Device): Promise<Response> {
  if (dev.role !== "owner")
    return json({ error: "This device can chat but not manage the office server. Pair it as an owner: sudo 5dive local pair --owner", reason: "not_owner" }, 403);
  const get = req.method === "GET", post = req.method === "POST";
  let b: Record<string, unknown> = {};
  if (post) { try { b = await req.json(); } catch { return json({ error: "invalid body" }, 400); } }
  if (p === "/api/panel/team" && get) return reply(await panelExec(["team"], dev.id));
  if (p === "/api/panel/team" && post) {
    const verb = ({ add: "agent-add", restart: "agent-restart", remove: "agent-remove" } as Record<string, string>)[str(b.action)];
    const name = str(b.name, 16);
    if (!verb || !AGENT_RE.test(name)) return json({ error: "Names are lowercase letters, digits and dashes, up to 16." }, 400);
    return reply(await panelExec([verb, name], dev.id));
  }
  if (p === "/api/panel/board" && get) return reply(await panelExec(["board"], dev.id));
  if (p === "/api/panel/answer" && post) {
    const ident = str(b.ident, 20), value = str(b.value);
    if (!ident || !value) return json({ error: "invalid answer" }, 400);
    return reply(await panelExec(["gate-answer", ident, value], dev.id));
  }
  if (p === "/api/panel/secrets" && get) return reply(await panelExec(["secrets"], dev.id));
  if (p === "/api/panel/secrets" && post) {
    const name = str(b.name, 64), value = typeof b.value === "string" ? b.value : "";
    if (!name || !value || value.length > 8192) return json({ error: "A secret needs a name and a value (up to 8 KB)." }, 400);
    return reply(await panelExec(["secret-set", name], dev.id, value));
  }
  if (p === "/api/panel/settings" && get) {
    const r = await panelExec(["settings"], dev.id);
    const devices = db.query("SELECT id, name, role, created, last_seen FROM devices WHERE revoked = 0 ORDER BY created").all();
    return reply(r.ok ? { ok: true, data: { ...r.data, devices, me: dev.id } } : r);
  }
  if (p === "/api/panel/test" && post) {
    const account = str(b.account, 32);
    if (!account) return json({ error: "invalid account" }, 400);
    return reply(await panelExec(["account-test", account], dev.id, "", 120_000));
  }
  if (p === "/api/panel/revoke" && post) {
    const id = str(b.id, 32);
    if (!/^[a-f0-9]{8,32}$/.test(id)) return json({ error: "invalid device" }, 400);
    return reply(await panelExec(["device-revoke", id], dev.id));
  }
  return json({ error: "not found" }, 404);
}

// ── listeners ─────────────────────────────────────────────────────────────────
const errorPage = (e: unknown) => { console.error(e); return json({ error: "server error" }, 500); };
Bun.serve({
  hostname: "127.0.0.1", port: LOOP_PORT, idleTimeout: 60, maxRequestBodySize: FILE_MAX + 1024,
  fetch: (req) => boxSide(req, new URL(req.url)).catch(errorPage),
});
if (LAN_PORT > 0) {
  const tls = CERT && KEY && existsSync(CERT) ? { cert: Bun.file(CERT), key: Bun.file(KEY) } : undefined;
  if (!tls && env.LC_ALLOW_PLAIN !== "1") { console.error("local chat: no TLS cert; refusing to serve the office network in the clear"); process.exit(1); }
  Bun.serve({
    hostname: LAN_ADDR, port: LAN_PORT, idleTimeout: 60, maxRequestBodySize: FILE_MAX + 1024, ...(tls ? { tls } : {}),
    fetch: (req) => browserSide(req, new URL(req.url)).catch(errorPage),
  });
}
console.log(`local chat: box side http://127.0.0.1:${LOOP_PORT}, office side ${LAN_PORT > 0 ? `https://${LAN_ADDR}:${LAN_PORT}` : "off"}`);

// ── the page ──────────────────────────────────────────────────────────────────
const PAGE = /*html*/ `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Office chat</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--ink:#14171c;--mute:#667085;--line:#e4e7ec;--me:#2563eb;--meink:#fff;--them:#fff;--accent:#2563eb;--live:#16a34a}
@media (prefers-color-scheme:dark){:root{--bg:#0f1115;--card:#171a21;--ink:#eef0f3;--mute:#98a2b3;--line:#262b35;--me:#3b82f6;--them:#1d2129;--accent:#60a5fa;--live:#22c55e}}
*{box-sizing:border-box}html,body{margin:0;height:100%;background:var(--bg);color:var(--ink);font:16px/1.4 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
header{position:sticky;top:0;z-index:2;display:flex;align-items:center;gap:10px;padding:14px 16px;background:var(--card);border-bottom:1px solid var(--line)}
header h1{margin:0;font-size:18px;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
header button{border:0;background:none;color:var(--accent);font-size:16px;padding:4px 8px 4px 0;cursor:pointer}
.sub{font-size:13px;color:var(--mute);font-weight:400}
main{max-width:720px;margin:0 auto}
.list a{display:flex;gap:12px;align-items:center;padding:14px 16px;border-bottom:1px solid var(--line);color:inherit;text-decoration:none;background:var(--card)}
.av{flex:none;width:44px;height:44px;border-radius:50%;display:grid;place-items:center;font-weight:600;color:#fff;background:var(--accent);text-transform:uppercase}
.row{min-width:0;flex:1}.row b{display:block}.row span{display:block;color:var(--mute);font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.live{color:var(--live)!important}
.thread{display:flex;flex-direction:column;gap:8px;padding:16px 16px 96px}
.msg{max-width:85%;padding:10px 12px;border-radius:16px;white-space:pre-wrap;word-wrap:break-word;overflow-wrap:anywhere}
.msg.you{align-self:flex-end;background:var(--me);color:var(--meink);border-bottom-right-radius:4px}
.msg.them{align-self:flex-start;background:var(--them);border:1px solid var(--line);border-bottom-left-radius:4px}
.msg.notice{align-self:stretch;max-width:none;background:#fff7e6;color:#5a3d00;border:1px solid #f5d38a}
@media (prefers-color-scheme:dark){.msg.notice{background:#2a2110;color:#f5d38a;border-color:#5a4512}}
.msg a{color:inherit}.file{display:block;margin-top:6px;text-decoration:underline}
.opts{display:flex;flex-wrap:wrap;gap:8px;margin-top:8px}
.opts button{border:1px solid var(--accent);background:transparent;color:var(--accent);border-radius:999px;padding:8px 14px;font-size:15px;cursor:pointer}
.status{position:fixed;left:0;right:0;bottom:72px;text-align:center;color:var(--live);font-size:14px;pointer-events:none}
form.send{position:fixed;left:0;right:0;bottom:0;display:flex;gap:8px;padding:12px 16px calc(12px + env(safe-area-inset-bottom));background:var(--card);border-top:1px solid var(--line)}
form.send textarea{flex:1;resize:none;height:44px;max-height:140px;padding:11px 14px;line-height:20px;overflow:hidden;border:1px solid var(--line);border-radius:22px;background:var(--bg);color:var(--ink);font:inherit}
.btn{flex:none;height:44px;min-width:44px;border:0;border-radius:22px;background:var(--accent);color:#fff;font-size:16px;font-weight:600;padding:0 16px;cursor:pointer}
.ghost{display:grid;place-items:center;background:transparent;color:var(--accent);border:1px solid var(--line);padding:0 12px}
.pair{padding:48px 24px;text-align:center}.pair h2{margin:0 0 8px;font-size:24px}.pair p{color:var(--mute);margin:0 0 24px}
.pair input{display:block;width:100%;max-width:320px;margin:0 auto 12px;padding:14px;font-size:24px;letter-spacing:4px;text-align:center;text-transform:uppercase;border:1px solid var(--line);border-radius:12px;background:var(--card);color:var(--ink)}
.pair .btn{width:100%;max-width:320px}.err{color:#dc2626;min-height:22px;margin-top:12px}
.empty{padding:40px 24px;text-align:center;color:var(--mute)}
</style></head><body>
<header><button id="back" hidden>&larr; Back</button><h1 id="title">Office chat</h1><a id="manage" href="/panel" hidden style="color:var(--accent);text-decoration:none;font-size:15px">⚙️ Manage</a></header>
<main id="app"></main>
<script>
const $ = (s) => document.querySelector(s);
const app = $("#app"), title = $("#title"), back = $("#back");
const H = { "content-type": "application/json", "x-local-chat": "1" };
let view = null, ctl = null;
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const hue = (n) => [...n].reduce((a, c) => a + c.charCodeAt(0), 0) % 360;
async function api(path, opts = {}) {
  const r = await fetch(path, { credentials: "same-origin", ...opts, signal: ctl?.signal });
  if (r.status === 401) { showPair(); throw new Error("unpaired"); }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || "Something went wrong");
  return j;
}
function reset(t, showBack) { ctl?.abort(); ctl = new AbortController(); title.innerHTML = t; back.hidden = !showBack; window.scrollTo(0, 0); }

function showPair() {
  view = "pair"; reset("Office chat", false);
  app.innerHTML = '<div class="pair"><h2>Connect this device</h2><p>Type the code your office server shows.</p>' +
    '<input id="code" autocomplete="one-time-code" inputmode="text" maxlength="12" placeholder="ABCD-1234" aria-label="Pairing code">' +
    '<button class="btn" id="go">Connect</button><div class="err" id="err"></div></div>';
  const go = async () => {
    $("#err").textContent = "";
    try {
      const r = await fetch("/api/pair", { method: "POST", headers: H, body: JSON.stringify({ code: $("#code").value, name: navigator.platform || "device" }) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(j.error || "That code did not work.");
      showList();
    } catch (e) { $("#err").textContent = e.message; }
  };
  $("#go").onclick = go; $("#code").onkeydown = (e) => { if (e.key === "Enter") go(); };
}

async function showList() {
  view = "list"; reset("Office chat", false);
  const tick = async () => {
    if (view !== "list") return;
    try {
      const j = await api("/api/agents");
      $("#manage").hidden = j.role !== "owner";
      if (!j.agents.length) { app.innerHTML = '<div class="empty">No agents yet. They show up here when they start.</div>'; }
      else app.innerHTML = '<nav class="list">' + j.agents.map((a) => {
        const st = a.status && a.status.active ? '<span class="live">' + esc(a.status.label ? "Working: " + a.status.label : "Working…") + "</span>"
          : "<span>" + esc(a.last ? (a.last.from === "you" ? "You: " : "") + a.last.text : "Say hello") + "</span>";
        return '<a href="#' + esc(a.name) + '"><div class="av" style="background:hsl(' + hue(a.name) + ' 55% 45%)">' + esc(a.name[0]) + '</div><div class="row"><b>' + esc(a.name) + "</b>" + st + "</div></a>";
      }).join("") + "</nav>";
    } catch (e) { if (e.message === "unpaired") return; }
    setTimeout(tick, 5000);
  };
  tick();
}

function bubble(m) {
  const cls = m.meta && m.meta.notice ? "notice" : m.from === "you" ? "you" : "them";
  let h = esc(m.text);
  for (const f of (m.meta && m.meta.files) || []) h += '<a class="file" href="/api/files?path=' + encodeURIComponent(f.path) + '">📎 ' + esc(f.name) + "</a>";
  if (m.meta && m.meta.question) h += '<div class="opts">' + m.meta.question.options.map((o) =>
    '<button data-a="' + esc(o.label) + '" title="' + esc(o.description || "") + '">' + esc(o.label) + "</button>").join("") + "</div>";
  return '<div class="msg ' + cls + '">' + h + "</div>";
}

async function showThread(agent) {
  view = agent; reset(esc(agent) + ' <span class="sub" id="live"></span>', true);
  const notices = agent === "5dive";
  app.innerHTML = '<div class="thread" id="t"></div><div class="status" id="st"></div>' + (notices ? "" :
    '<form class="send" id="f"><label class="btn ghost" title="Attach a file">📎<input type="file" id="file" hidden multiple></label>' +
    '<textarea id="txt" placeholder="Message ' + esc(agent) + '" rows="1"></textarea><button class="btn">Send</button></form>');
  const t = $("#t"); let last = 0, statusAt = 0, pending = [];
  const draw = (j) => {
    if (j.messages.length) {
      t.insertAdjacentHTML("beforeend", j.messages.map(bubble).join(""));
      last = j.messages[j.messages.length - 1].id; window.scrollTo(0, document.body.scrollHeight);
    }
    const s = j.status; statusAt = s ? s.ts : statusAt;
    $("#st").textContent = s && s.active ? (s.label ? "Working: " + s.label : "Working…") : "";
  };
  try { draw(await api("/api/messages?agent=" + encodeURIComponent(agent))); } catch (e) { return; }
  if (!t.children.length) t.innerHTML = '<div class="empty">' + (notices ? "Notices from your server show up here." : "Send " + esc(agent) + " a message to start.") + "</div>";
  const send = async (text) => {
    if (!text && !pending.length) return;
    t.querySelector(".empty")?.remove();
    await api("/api/messages", { method: "POST", headers: H, body: JSON.stringify({ agent, text, files: pending.map((p) => p.path) }) });
    pending = [];
  };
  t.onclick = (e) => { const a = e.target.closest("button[data-a]"); if (a) send(a.dataset.a).catch((er) => alert(er.message)); };
  if (!notices) {
    $("#f").onsubmit = async (e) => { e.preventDefault(); const v = $("#txt").value.trim(); $("#txt").value = ""; try { await send(v); } catch (er) { if (er.name !== "AbortError") alert(er.message); } };
    $("#txt").onkeydown = (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); $("#f").requestSubmit(); } };
    $("#file").onchange = async (e) => {
      for (const f of e.target.files) {
        try { pending.push(await api("/api/files?agent=" + encodeURIComponent(agent) + "&name=" + encodeURIComponent(f.name), { method: "POST", headers: { "x-local-chat": "1" }, body: f })); }
        catch (er) { alert(er.message); }
      }
      $("#txt").placeholder = pending.length ? pending.length + " file(s) attached — add a note or tap Send" : "Message " + agent;
      e.target.value = "";
    };
  }
  while (view === agent) {
    try { draw(await api("/api/messages?agent=" + encodeURIComponent(agent) + "&since=" + last + "&status_at=" + statusAt + "&wait=25")); }
    catch (e) { if (e.name === "AbortError" || e.message === "unpaired") return; await new Promise((r) => setTimeout(r, 3000)); }
  }
}

back.onclick = () => { location.hash = ""; };
const route = () => { const a = decodeURIComponent(location.hash.slice(1)); a ? showThread(a) : showList(); };
window.onhashchange = route; route();
</script></body></html>`;

// ── the panel page (DIVE-7576): owner devices; same look as the chat ─────────
const PANEL_PAGE = /*html*/ `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Office server</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--ink:#14171c;--mute:#667085;--line:#e4e7ec;--accent:#2563eb;--live:#16a34a;--warn:#b45309;--bad:#dc2626}
@media (prefers-color-scheme:dark){:root{--bg:#0f1115;--card:#171a21;--ink:#eef0f3;--mute:#98a2b3;--line:#262b35;--accent:#60a5fa;--live:#22c55e;--warn:#f5b041;--bad:#f87171}}
*{box-sizing:border-box}html,body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.4 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
header{position:sticky;top:0;z-index:2;display:flex;align-items:center;gap:10px;padding:14px 16px;background:var(--card);border-bottom:1px solid var(--line)}
header h1{margin:0;font-size:18px;flex:1}header a{color:var(--accent);text-decoration:none;font-size:15px}
main{max-width:720px;margin:0 auto;padding:12px 16px 96px}
nav.tabs{position:fixed;left:0;right:0;bottom:0;display:flex;background:var(--card);border-top:1px solid var(--line);padding-bottom:env(safe-area-inset-bottom)}
nav.tabs button{flex:1;border:0;background:none;color:var(--mute);font-size:12px;padding:8px 0 10px;cursor:pointer}
nav.tabs button b{display:block;font-size:22px;font-weight:400}nav.tabs button.on{color:var(--accent)}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px;margin:0 0 12px}
.card h3{margin:0 0 4px;font-size:16px}.mute{color:var(--mute);font-size:14px}
.item{display:flex;align-items:center;gap:12px;padding:12px 0;border-top:1px solid var(--line)}.item:first-of-type{border-top:0}
.item .grow{flex:1;min-width:0}.item .grow b{display:block}.item .grow span{color:var(--mute);font-size:14px}
.dot{flex:none;width:10px;height:10px;border-radius:50%;background:var(--mute)}.dot.on{background:var(--live)}.dot.bad{background:var(--bad)}
.btn{border:0;border-radius:999px;background:var(--accent);color:#fff;font-size:15px;font-weight:600;padding:9px 16px;cursor:pointer}
.btn.line{background:transparent;color:var(--accent);border:1px solid var(--accent)}.btn.red{background:transparent;color:var(--bad);border:1px solid var(--bad)}
.btn:disabled{opacity:.5}.row{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}.row .btn{text-transform:capitalize}
input{width:100%;padding:12px;font:inherit;border:1px solid var(--line);border-radius:12px;background:var(--bg);color:var(--ink);margin:6px 0}
.ok{color:var(--live)}.leak{color:var(--bad);font-weight:600}.big{font-size:20px;font-weight:600;margin:4px 0}
.toast{position:fixed;left:16px;right:16px;bottom:84px;margin:auto;max-width:520px;padding:12px 14px;border-radius:12px;background:var(--ink);color:var(--bg);display:none}
.empty{padding:32px 8px;text-align:center;color:var(--mute)}
</style></head><body>
<header><h1 id="title">Office server</h1><a href="/">💬 Chat</a></header>
<main id="app"><div class="empty">Loading…</div></main>
<div class="toast" id="toast"></div>
<nav class="tabs" id="tabs" hidden>
<button data-t="team"><b>👥</b>Team</button><button data-t="board"><b>✅</b>Approvals</button>
<button data-t="secrets"><b>🔑</b>Secrets</button><button data-t="settings"><b>⚙️</b>Settings</button></nav>
<script>
const $ = (s) => document.querySelector(s);
const app = $("#app");
const H = { "content-type": "application/json", "x-local-chat": "1" };
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
let tab = "team";
function toast(t) { const e = $("#toast"); e.textContent = t; e.style.display = "block"; clearTimeout(e._t); e._t = setTimeout(() => { e.style.display = "none"; }, 4000); }
async function api(path, body) {
  const r = await fetch(path, body ? { method: "POST", headers: H, body: JSON.stringify(body) } : { credentials: "same-origin" });
  const j = await r.json().catch(() => ({}));
  if (r.status === 401) { location.href = "/"; throw new Error("Pair this device first."); }
  if (r.status === 403) { blocked(j.error); throw new Error(j.error); }
  if (!r.ok || j.ok === false) throw new Error(j.error || "That did not work.");
  return j.data;
}
function blocked(msg) {
  $("#tabs").hidden = true;
  app.innerHTML = '<div class="card"><h3>This device can chat, not manage</h3><p class="mute">' + esc(msg) + '</p><a class="btn" href="/" style="display:inline-block;text-decoration:none">Go to chat</a></div>';
}
async function act(btn, path, body, done) {
  btn.disabled = true; const t = btn.textContent; btn.textContent = "Working…";
  try { await api(path, body); toast(done); show(tab); } catch (e) { toast(e.message); btn.disabled = false; btn.textContent = t; }
}
const views = {
  async team() {
    const d = await api("/api/panel/team");
    const list = Array.isArray(d) ? d : (d && d.agents) || [];
    app.innerHTML = '<div class="card"><h3>Your agents</h3>' + (list.length ? list.map((a) => {
      const up = String(a.active || a.state || "") === "active";
      return '<div class="item"><span class="dot ' + (up ? "on" : "") + '"></span><div class="grow"><b>' + esc(a.name) + '</b><span>' + (up ? "Running" : "Stopped") + '</span></div>' +
        '<button class="btn line" data-a="restart" data-n="' + esc(a.name) + '">Restart</button>' +
        '<button class="btn red" data-a="remove" data-n="' + esc(a.name) + '">Remove</button></div>';
    }).join("") : '<div class="empty">No agents yet.</div>') + '</div>' +
      '<div class="card"><h3>Add an agent</h3><p class="mute">It runs on this server’s own AI.</p><input id="nn" placeholder="name, e.g. paralegal" maxlength="16" autocapitalize="off"><button class="btn" id="add">Add agent</button></div>';
    app.onclick = (e) => {
      const b = e.target.closest("button[data-a]"); if (!b) return;
      const n = b.dataset.n, a = b.dataset.a;
      if (a === "remove" && !confirm("Remove " + n + "? Its files are kept on the server.")) return;
      act(b, "/api/panel/team", { action: a, name: n }, a === "remove" ? n + " removed" : n + " restarted");
    };
    $("#add").onclick = () => { const n = $("#nn").value.trim().toLowerCase(); if (n) act($("#add"), "/api/panel/team", { action: "add", name: n }, n + " added"); };
  },
  async board() {
    const d = await api("/api/panel/board");
    const gates = d.gates || [], open = (d.tasks || []).filter((t) => !/done|cancel/.test(t.status || ""));
    app.innerHTML = '<div class="card"><h3>Waiting for you</h3>' + (gates.length ? gates.map((g) => {
      let opts = String(g.need_options || "").split("|").map((o) => o.trim()).filter(Boolean);
      if (!opts.length && g.need_type === "approval") opts = ["approve", "reject"];
      if (!opts.length && g.need_type === "manual") opts = ["done"];
      const btns = g.need_type === "secret" ? '<p class="mute">Needs a secret: add it under 🔑 Secrets.</p>' :
        '<div class="row">' + opts.map((o) => '<button class="btn ' + (o === g.recommend ? "" : "line") + '" data-i="' + esc(g.ident) + '" data-v="' + esc(o) + '">' + esc(o) + '</button>').join("") + '</div>';
      return '<div class="item" style="display:block"><b>' + esc(g.ask || g.title) + '</b><span class="mute">' + esc(g.ident) + (g.recommend ? " · suggested: " + esc(g.recommend) : "") + '</span>' + btns + '</div>';
    }).join("") : '<div class="empty">Nothing waiting. 🎉</div>') + '</div>' +
      '<div class="card"><h3>Open work</h3>' + (open.length ? open.slice(0, 50).map((t) =>
        '<div class="item"><div class="grow"><b>' + esc(t.title) + '</b><span>' + esc(t.ident + " · " + (t.assignee || "unassigned") + " · " + String(t.status || "").replace(/_/g, " ")) + '</span></div></div>').join("") : '<div class="empty">No open work.</div>') + '</div>';
    app.onclick = (e) => { const b = e.target.closest("button[data-i]"); if (b) act(b, "/api/panel/answer", { ident: b.dataset.i, value: b.dataset.v }, "Answered"); };
  },
  async secrets() {
    const names = await api("/api/panel/secrets");
    app.innerHTML = '<div class="card"><h3>Add or replace a secret</h3><p class="mute">Every agent can use it. You will not see the value again.</p>' +
      '<input id="sn" placeholder="NAME_API_KEY" autocapitalize="characters" maxlength="64"><input id="sv" type="password" placeholder="value" autocomplete="off">' +
      '<button class="btn" id="save">Save</button></div><div class="card"><h3>Saved</h3>' +
      (names.length ? names.map((n) => '<div class="item"><span class="dot on"></span><div class="grow"><b>' + esc(n) + '</b><span>value hidden</span></div></div>').join("") : '<div class="empty">None yet.</div>') + '</div>';
    app.onclick = null;
    $("#save").onclick = () => {
      const name = $("#sn").value.trim().toUpperCase(), value = $("#sv").value;
      if (name && value) act($("#save"), "/api/panel/secrets", { name, value }, name + " saved");
    };
  },
  async settings() {
    const d = await api("/api/panel/settings");
    const leaks = d.localOnly.filter((r) => !r.ok);
    app.innerHTML = '<div class="card"><h3>Stays in the office?</h3>' +
      (d.localOnly.length ? '<div class="big ' + (leaks.length ? "leak" : "ok") + '">' + (leaks.length ? "⚠️ " + leaks.length + " thing(s) still reach the internet" : "✅ Fully local") + '</div>' +
        d.localOnly.map((r) => '<div class="item"><span class="dot ' + (r.ok ? "on" : "bad") + '"></span><div class="grow"><b>' + esc(r.item) + '</b><span>' + esc(r.state) + '</span></div></div>').join("")
        : '<p class="mute">Local-only mode is not set up on this server.</p>') + '</div>' +
      '<div class="card"><h3>Your AI</h3>' + (d.accounts.length ? d.accounts.map((a) =>
        '<div class="item"><div class="grow"><b>' + esc(a.model || a.name) + '</b><span>' + esc(a.baseUrl) + '</span></div><button class="btn line" data-test="' + esc(a.name) + '">Test</button></div>').join("")
        : '<p class="mute">No local AI added yet.</p>') + '</div>' +
      '<div class="card"><h3>Connected devices</h3>' + d.devices.map((v) =>
        '<div class="item"><div class="grow"><b>' + esc(v.name) + (v.id === d.me ? " (this one)" : "") + '</b><span>' + (v.role === "owner" ? "Can manage" : "Chat only") + '</span></div><button class="btn red" data-rv="' + esc(v.id) + '">Remove</button></div>').join("") + '</div>' +
      (d.updateFromFile ? '<div class="card"><h3>Update</h3><p class="mute">Install an update file from your IT team.</p></div>' : "");
    app.onclick = async (e) => {
      const t = e.target.closest("button[data-test]"), r = e.target.closest("button[data-rv]");
      if (t) {
        t.disabled = true; t.textContent = "Testing…";
        try { const x = await api("/api/panel/test", { account: t.dataset.test }); toast(x && x.ok ? "✅ Your AI answered" : "⚠️ " + ((x && x.reason) || "No answer")); }
        catch (er) { toast(er.message); }
        t.disabled = false; t.textContent = "Test";
      }
      if (r && confirm("Remove this device? It will need a new code to come back.")) act(r, "/api/panel/revoke", { id: r.dataset.rv }, "Device removed");
    };
  },
};
async function show(t) {
  tab = t;
  for (const b of document.querySelectorAll("nav.tabs button")) b.classList.toggle("on", b.dataset.t === t);
  try { await views[t](); $("#tabs").hidden = false; }
  catch (e) {
    if (/can chat/.test(e.message)) return;
    if ($("#tabs").hidden) { app.innerHTML = '<div class="empty">' + esc(e.message) + '</div>'; $("#tabs").hidden = false; }
    else toast(e.message);
  }
}
$("#tabs").onclick = (e) => { const b = e.target.closest("button[data-t]"); if (b) { location.hash = b.dataset.t; } };
window.onhashchange = () => show(views[location.hash.slice(1)] ? location.hash.slice(1) : "team");
window.onhashchange();
</script></body></html>`;
LOCAL_CHAT_TS
}
