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
//   bun local_chat_server.ts admin pair-add <sha256-hex> <expires-epoch-s> [chat|owner] [<name>]
//   bun local_chat_server.ts admin devices-ls
//   bun local_chat_server.ts admin devices-revoke <id>
import { Database } from "bun:sqlite";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, statfsSync, writeFileSync } from "node:fs";
import { freemem, totalmem, uptime } from "node:os";
import { open } from "node:fs/promises";
import { extname, join, normalize } from "node:path";

const env = process.env;
const STATE = env.LC_STATE || "/var/lib/5dive-local-chat";
const LAN_ADDR = env.LC_LAN_ADDR || "0.0.0.0";
const LAN_PORT = Number(env.LC_LAN_PORT || 8443);
const LOOP_PORT = Number(env.LC_LOOP_PORT || 8480);
const CRED = env.CREDENTIALS_DIRECTORY || "";
// DIVE-7598: where systemd sets CREDENTIALS_DIRECTORY but the service cannot see
// it (a systemd in a container: the folder is absent in the service's view), the
// unit's root pre-start also copies the three files into this service's own
// 0700 runtime folder. Same reader (this user only), same tmpfs.
const RUN = env.RUNTIME_DIRECTORY || "";
const cred = (n: string) => { for (const d of [CRED, RUN]) if (d && existsSync(join(d, n))) return join(d, n); return ""; };
const CERT = env.LC_CERT || cred("cert");
const KEY = env.LC_KEY || cred("key");
const TOKEN_FILE = env.LC_TOKEN_FILE || cred("token");
const AGENTS_FILE = env.LC_AGENTS_FILE || "/etc/5dive/local-chat/agents.json";
const UPLOADS = (env.LC_UPLOADS || "/home/claude/chat-uploads").replace(/\/+$/, "");
const FILE_MAX = Number(env.LC_FILE_MAX || 20 * 1024 * 1024);
const WAIT_MAX = 25;
const AGENT_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const NOTICE_AGENT = "5dive";
// DIVE-7576: the office control panel's one door to root (src/cmd_local_panel.sh).
const PANEL_SOCK = env.LC_PANEL_SOCK || "/run/5dive-local-panel.sock";
// DIVE-7579 (D4): an update file uploaded from the panel (a release file is
// ~150 MB). Only that one owner route may send a body this size.
const UPDATE_MAX = Number(env.LC_UPDATE_MAX || 1024 * 1024 * 1024);
const UPDATE_PATH = "/api/panel/update";

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
// DIVE-7599: an invite names the person; the device that uses the code takes
// that name, not the one its browser guessed.
if (!(db.query("PRAGMA table_info(pair_codes)").all() as { name: string }[]).some((c) => c.name === "name"))
  db.exec("ALTER TABLE pair_codes ADD COLUMN name TEXT NOT NULL DEFAULT ''");
const cleanName = (v: unknown) => (typeof v === "string" ? v : "").replace(/[^\w .'-]/g, "").trim().slice(0, 40);
// DIVE-8807: PEOPLE, not just devices. A person has many devices and a role
// (owner|member); removing a person signs out every device they have. A member
// uses only the agents granted to them (deny by default, like the online staff
// logins); '*' is every agent. A code may name the person it joins (another
// device for them) and carries the grants a new person starts with: a code from
// `local pair` (the owner at a terminal or the panel) starts with '*', as before
// people existed; an invite made in the app starts with exactly what it lists.
db.exec(`
CREATE TABLE IF NOT EXISTS people (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, role TEXT NOT NULL CHECK (role IN ('owner','member')),
  created INTEGER NOT NULL, removed INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS grants (person TEXT NOT NULL, agent TEXT NOT NULL, PRIMARY KEY (person, agent));
`);
for (const [t, col, def] of [["devices", "person", "''"], ["pair_codes", "person", "''"], ["pair_codes", "agents", "'*'"]]) {
  const cols = db.query(`PRAGMA table_info(${t})`).all() as { name: string }[];
  if (!cols.some((c) => c.name === col)) db.exec(`ALTER TABLE ${t} ADD COLUMN ${col} TEXT NOT NULL DEFAULT ${def}`);
}
// A device paired before people existed becomes one person with its name and
// role, and keeps every agent it could chat with ('*').
db.transaction(() => {
  for (const d of db.query("SELECT id, name, role, created FROM devices WHERE person = ''").all() as
    { id: string; name: string; role: string; created: number }[]) {
    const pid = randomBytes(6).toString("hex");
    db.query("INSERT INTO people (id, name, role, created) VALUES (?, ?, ?, ?)").run(pid, d.name, d.role === "owner" ? "owner" : "member", d.created);
    db.query("INSERT OR IGNORE INTO grants (person, agent) VALUES (?, '*')").run(pid);
    db.query("UPDATE devices SET person = ? WHERE id = ?").run(pid, d.id);
  }
})();

const now = () => Math.floor(Date.now() / 1000);
const sha256 = (s: string | Uint8Array) => createHash("sha256").update(s).digest("hex");
const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });

// ── admin (run as the server user by the CLI; never over the network) ────────
if (process.argv[2] === "admin") {
  const [op, a, b] = process.argv.slice(3);
  const role = process.argv[6] ?? "chat";
  const who = process.argv[7] ?? "";
  if (op === "pair-add" && /^[0-9a-f]{64}$/.test(a || "") && /^\d+$/.test(b || "") && (role === "chat" || role === "owner")
      && cleanName(who) === who) {
    db.query("DELETE FROM pair_codes WHERE expires < ? OR used = 1").run(now());
    db.query("INSERT OR REPLACE INTO pair_codes (hash, expires, role, name) VALUES (?, ?, ?, ?)").run(a, Number(b), role, who);
    console.log(JSON.stringify({ ok: true }));
  } else if (op === "devices-ls") {
    console.log(JSON.stringify(db.query("SELECT id, name, role, created, last_seen, revoked FROM devices ORDER BY created").all()));
  } else if (op === "devices-revoke" && /^[a-f0-9]{8,32}$/.test(a || "")) {
    const r = db.query("UPDATE devices SET revoked = 1 WHERE id = ? AND revoked = 0").run(a);
    console.log(JSON.stringify({ ok: r.changes > 0 }));
    process.exit(r.changes > 0 ? 0 : 3);
  } else {
    console.error("usage: admin pair-add <sha256> <expires> [chat|owner] [<name>] | devices-ls | devices-revoke <id>");
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
// DIVE-8807: a device is let in only while its PERSON is too; its role is the
// person's (owner → 'owner', member → 'chat', the word the panel checks).
type Device = { id: string; name: string; role: string; person: string; personName: string; personRole: "owner" | "member" };
function deviceOf(req: Request): Device | null {
  const m = (req.headers.get("cookie") ?? "").match(/(?:^|;\s*)lc_dev=([A-Za-z0-9_-]{20,100})/);
  if (!m) return null;
  const d = db.query(`SELECT d.id, d.name, d.person, p.name AS personName, p.role AS personRole FROM devices d
    JOIN people p ON p.id = d.person WHERE d.cookie_hash = ? AND d.revoked = 0 AND p.removed = 0`).get(sha256(m[1])) as
    | Omit<Device, "role"> | null;
  if (!d) return null;
  db.query("UPDATE devices SET last_seen = ? WHERE id = ?").run(now(), d.id);
  return { ...d, role: d.personRole === "owner" ? "owner" : "chat" };
}
// The agents a person may use: null = all (an owner, or a '*' grant).
function grantsOf(person: string, role: string): Set<string> | null {
  if (role === "owner") return null;
  const rows = db.query("SELECT agent FROM grants WHERE person = ?").all(person) as { agent: string }[];
  return rows.some((r) => r.agent === "*") ? null : new Set(rows.map((r) => r.agent));
}
const mayUse = (dev: Device, agent: string) => { const g = grantsOf(dev.person, dev.personRole); return !g || g.has(agent); };
const NOT_YOUR_AGENT = { error: "not_your_agent", reason: "The team's owner has not given you this agent." };
// A member may fetch a file sent to, or by, an agent they may use.
function fileAllowed(dev: Device, path: string): boolean {
  const g = grantsOf(dev.person, dev.personRole);
  if (!g) return true;
  for (const a of g) if (path.startsWith(`${UPLOADS}/${a}/`)) return true;
  const rows = db.query("SELECT DISTINCT agent FROM messages WHERE instr(meta, ?) > 0 LIMIT 50").all(JSON.stringify(path)) as { agent: string }[];
  return rows.some((r) => g.has(r.agent));
}

// Spend a one-time code (typed, or from a join link) and let this device in.
// The code joins the person it names, else makes a new person from it.
type CodeRow = { hash: string; role: string; name: string; person: string; agents: string };
function admitDevice(row: CodeRow, typedName: string): { cookie: string; device: string; person: string; role: "owner" | "member" } | null {
  return db.transaction(() => {
    if (db.query("UPDATE pair_codes SET used = 1 WHERE hash = ? AND used = 0").run(row.hash).changes !== 1) return null;
    let person = row.person, role: "owner" | "member" = row.role === "owner" ? "owner" : "member";
    let name = row.name || typedName || "device";
    if (person) {
      const p = db.query("SELECT name, role FROM people WHERE id = ? AND removed = 0").get(person) as { name: string; role: "owner" | "member" } | null;
      if (!p) return null;
      role = p.role; name = p.name;
    } else {
      person = randomBytes(6).toString("hex");
      db.query("INSERT INTO people (id, name, role, created) VALUES (?, ?, ?, ?)").run(person, name, role, now());
      let list: string[] = [];
      if (row.agents === "*") list = ["*"];
      else { try { const a = JSON.parse(row.agents); if (Array.isArray(a)) list = a.filter((x) => typeof x === "string" && AGENT_RE.test(x)); } catch {} }
      for (const a of list) db.query("INSERT OR IGNORE INTO grants (person, agent) VALUES (?, ?)").run(person, a);
    }
    const cookie = randomBytes(32).toString("base64url");
    const device = randomBytes(6).toString("hex");
    db.query("INSERT INTO devices (id, name, cookie_hash, created, last_seen, role, person) VALUES (?, ?, ?, ?, ?, ?, ?)")
      .run(device, name, sha256(cookie), now(), now(), role === "owner" ? "owner" : "chat", person);
    return { cookie, device, person, role };
  })();
}
const sessionCookie = (cookie: string) => `lc_dev=${cookie}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000`;
const normCode = (v: unknown) => (typeof v === "string" ? v.replace(/[\s-]/g, "").toUpperCase() : "");
function codeRow(code: string): CodeRow | null {
  if (!code) return null;
  return db.query("SELECT hash, role, name, person, agents FROM pair_codes WHERE hash = ? AND used = 0 AND expires >= ?").get(sha256(code), now()) as CodeRow | null;
}
// Ten code tries a minute across every sign-in door (typed code, join link).
const pairTries: number[] = [];
function pairThrottled(): boolean {
  const t = Date.now();
  while (pairTries.length && pairTries[0] < t - 60_000) pairTries.shift();
  if (pairTries.length >= 10) return true;
  pairTries.push(t);
  return false;
}

// DIVE-8809: the office app (`5dive local app install`), unpacked root-owned under
// /opt/5dive/office-app/<version>; `current` names the one served. Read on every
// request (a realpath), so an install needs no restart. No app: the page below.
const APP_DIR = env.LC_APP_DIR || "/opt/5dive/office-app/current";
type OfficeApp = { root: string; index: string; fallbacks: { prefix: string; file: string }[] };
let appSeen: { real: string; app: OfficeApp | null } | null = null;
function officeApp(): OfficeApp | null {
  let real = "";
  try { real = realpathSync(APP_DIR); } catch { return null; }
  if (appSeen?.real === real) return appSeen.app;
  let app: OfficeApp | null = null;
  try {
    const a = JSON.parse(readFileSync(join(real, "manifest.json"), "utf8"))?.app ?? {};
    const safe = (v: unknown, re: RegExp): v is string => typeof v === "string" && re.test(v) && !v.includes("..");
    const index = safe(a.index, /^\/[A-Za-z0-9._\/-]*$/) ? a.index : "/";
    const fallbacks = (Array.isArray(a.fallbacks) ? a.fallbacks : [])
      .filter((f: any) => safe(f?.prefix, /^\/[A-Za-z0-9._\/-]+\/$/) && safe(f?.file, /^[A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+)*$/));
    if (statSync(join(real, "app")).isDirectory()) app = { root: join(real, "app"), index, fallbacks };
  } catch {}
  appSeen = { real, app };
  return app;
}
const APP_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".json": "application/json", ".webmanifest": "application/manifest+json", ".txt": "text/plain; charset=utf-8",
  ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp", ".gif": "image/gif",
  ".svg": "image/svg+xml", ".ico": "image/x-icon", ".woff2": "font/woff2", ".woff": "font/woff", ".map": "application/json",
};
// The app talks only to this server: the browser is told so (connect-src 'self').
const APP_CSP = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; " +
  "font-src 'self' data:; connect-src 'self'; worker-src 'self'; manifest-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'";
function appFile(app: OfficeApp, rel: string): string | null {
  if (rel.includes("\0") || rel.split("/").includes("..")) return null;
  const p = normalize(join(app.root, rel));
  if (p !== app.root && !p.startsWith(app.root + "/")) return null;
  try {
    const st = statSync(p);
    const f = st.isDirectory() ? join(p, "index.html") : p;
    return statSync(f).isFile() ? f : null;
  } catch { return null; }
}
function serveApp(app: OfficeApp, p: string): Response {
  let rel = "";
  try { rel = decodeURIComponent(p); } catch { return json({ error: "not found" }, 404); }
  let f = appFile(app, rel.slice(1));
  if (!f) {
    const fb = app.fallbacks.find((x) => rel.startsWith(x.prefix) && rel.length > x.prefix.length);
    if (fb) f = appFile(app, fb.file);
  }
  const status = f ? 200 : 404;
  if (!f) f = appFile(app, "404.html");
  if (!f) return json({ error: "not found" }, 404);
  const ext = extname(f);
  return new Response(Bun.file(f), {
    status,
    headers: {
      "content-type": APP_TYPES[ext] ?? "application/octet-stream",
      // Content-hashed names never change; everything else is checked on each load.
      "cache-control": rel.startsWith("/_next/static/") ? "public, max-age=31536000, immutable" : "no-cache",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
      ...(ext === ".html" ? { "content-security-policy": APP_CSP, "x-frame-options": "DENY" } : {}),
    },
  });
}
const PAGE_HEADERS = {
  "content-type": "text/html; charset=utf-8",
  "content-security-policy": "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data: blob:",
  "x-frame-options": "DENY",
  "referrer-policy": "no-referrer",
};

async function browserSide(req: Request, url: URL): Promise<Response> {
  const p = url.pathname;
  const read = req.method === "GET" || req.method === "HEAD";
  if (p === "/panel" && read) return new Response(PANEL_PAGE, { headers: PAGE_HEADERS });
  // DIVE-8809: with the app installed, / opens it for a signed-in device; a
  // signed-out one gets the page's sign-in (a code, or a join link at /join),
  // which comes back to / once in. /lite is the page, always.
  if ((p === "/" || p === "/join" || p === "/lite") && read) {
    const app = officeApp();
    if (app && p === "/" && deviceOf(req)) return new Response(null, { status: 302, headers: { location: app.index + url.search, "cache-control": "no-store" } });
    return new Response(app && p !== "/lite" ? PAGE.replace('<html lang="en">', '<html lang="en" data-app="1">') : PAGE, { headers: PAGE_HEADERS });
  }
  if (read && !p.startsWith("/api/")) {
    const app = officeApp();
    if (app) return serveApp(app, p);
  }
  // DIVE-8807: the office app's own API paths (a fixed allowlist, never forwarded).
  if (p.startsWith("/api/proxy/")) return officeProxy(req, url);
  // Every write carries a custom header, so a page on another origin cannot
  // post with this device's cookie (it would need a CORS preflight we refuse).
  if (req.method === "POST" && req.headers.get("x-local-chat") !== "1") return json({ error: "forbidden" }, 403);
  // DIVE-7579: the listener takes a body up to UPDATE_MAX for the update upload,
  // so every POST names its length and only that route may be that big.
  if (req.method === "POST") {
    const len = Number(req.headers.get("content-length") ?? NaN);
    if (!Number.isFinite(len)) return json({ error: "length required" }, 411);
    if (len > (p === UPDATE_PATH ? UPDATE_MAX : FILE_MAX + 1024)) return json({ error: "That is too big to send here." }, 413);
  }

  if (p === "/api/pair" && req.method === "POST") {
    if (pairThrottled()) return json({ error: "too many tries, wait a minute" }, 429);
    let b: { code?: unknown; name?: unknown };
    try { b = await req.json(); } catch { return json({ error: "invalid body" }, 400); }
    const row = codeRow(normCode(b.code));
    const got = row && admitDevice(row, cleanName(b.name));
    if (!got) return json({ error: "That code is wrong or expired." }, 403);
    return json({ ok: true, device: got.device, role: got.role === "owner" ? "owner" : "chat" }, 200, { "set-cookie": sessionCookie(got.cookie) });
  }

  const dev = deviceOf(req);
  if (!dev) return json({ error: "pair this device first" }, 401);

  if (p === "/api/agents" && req.method === "GET") {
    const last = db.query("SELECT * FROM messages WHERE agent = ? ORDER BY id DESC LIMIT 1");
    return json({
      device: dev.name,
      role: dev.role,
      agents: agents().filter((name) => mayUse(dev, name)).map((name) => {
        const l = last.get(name) as Row | null;
        return { name, status: status.get(name) ?? null, last: l ? serialize(l) : null };
      }),
    });
  }
  if (p === "/api/messages" && req.method === "GET") {
    const agent = url.searchParams.get("agent") ?? "";
    if (!AGENT_RE.test(agent)) return json({ error: "invalid agent" }, 400);
    if (!mayUse(dev, agent)) return json(NOT_YOUR_AGENT, 403);
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
    if (!mayUse(dev, agent)) return json(NOT_YOUR_AGENT, 403);
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
    if (!mayUse(dev, agent)) return json(NOT_YOUR_AGENT, 403);
    const bytes = await readBody(req);
    if (!bytes || !bytes.length) return json({ error: "file is empty or over 20 MB" }, 413);
    const name = safeName(url.searchParams.get("name") ?? "file");
    const path = `${UPLOADS}/${agent}/${Date.now()}-${randomBytes(3).toString("hex")}-${name}`;
    await storeFile(path, name, bytes);
    return json({ ok: true, path, name, size: bytes.length });
  }
  if (p === "/api/files" && req.method === "GET") {
    const path = url.searchParams.get("path") ?? "";
    if (!fileAllowed(dev, path)) return json(NOT_YOUR_AGENT, 403);
    return serveFile(path, true);
  }
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
  if (p === UPDATE_PATH && post) return updateUpload(req, dev);
  if (p === UPDATE_PATH && get) return reply(await panelExec(["update-status"], dev.id));
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
  // DIVE-7599: invite a person by name. Root runs `local pair --name`, so the
  // code is the same one-use, 15-minute code; it comes back here once and is
  // never written anywhere but its hash.
  if (p === "/api/panel/invite" && post) {
    const name = str(b.name, 40).trim(), role = str(b.role, 5);
    if (!name || cleanName(name) !== name || !/^[A-Za-z0-9]/.test(name) || (role !== "chat" && role !== "owner"))
      return json({ error: "Type their name (letters, digits, spaces), and pick Chat or Manage." }, 400);
    return reply(await panelExec(["device-invite", name, role], dev.id));
  }
  // DIVE-7599: first-run setup — find the office's AI server, then save it and
  // make the first agent. Root does both; this process dials nothing.
  if (p === "/api/panel/ai-scan" && post) {
    const url = str(b.url, 300).trim();
    return reply(await panelExec(url ? ["ai-scan", url] : ["ai-scan"], dev.id, "", 120_000));
  }
  if (p === "/api/panel/ai-setup" && post) {
    const url = str(b.url, 300).trim(), model = str(b.model, 200), agent = str(b.agent, 16);
    if (!url || !model || !AGENT_RE.test(agent)) return json({ error: "Pick an AI server and a model, and name your first agent." }, 400);
    return reply(await panelExec(["ai-setup", url, model, agent], dev.id, "", 600_000));
  }
  // DIVE-7886: a Support file. The description goes to root on stdin; root
  // answers with the file's text, which the page saves as is. Nothing is sent.
  if (p === "/api/panel/support-file" && post) {
    const what = typeof b.what === "string" ? b.what : "";
    if (!what.trim()) return json({ error: "Describe the problem first." }, 400);
    if (what.length > 2000) return json({ error: "That is too long (2000 characters at most)." }, 400);
    return reply(await panelExec(["support-file"], dev.id, what, 120_000));
  }
  return json({ error: "not found" }, 404);
}

// DIVE-7579 (D4): stream the update file into this server's own state folder
// (never into memory), then hand it to root. Root copies it out, checks the
// signature and every member, and installs it detached; the page polls.
async function updateUpload(req: Request, dev: Device): Promise<Response> {
  const dir = join(STATE, "update");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const part = join(dir, "incoming.part"), dest = join(dir, "incoming.tar");
  let n = 0;
  const fh = await open(part, "w", 0o600);
  try {
    if (!req.body) throw new Error("empty");
    for await (const chunk of req.body as unknown as AsyncIterable<Uint8Array>) {
      n += chunk.length;
      if (n > UPDATE_MAX) throw new Error("too big");
      await fh.write(chunk);
    }
  } catch {
    await fh.close().catch(() => {});
    rmSync(part, { force: true });
    return json({ ok: false, error: "The file did not arrive in full. Try again." }, 413);
  }
  await fh.close();
  if (!n) { rmSync(part, { force: true }); return json({ ok: false, error: "That file is empty." }, 400); }
  renameSync(part, dest);
  const r = await panelExec(["update-install"], dev.id, "", 120_000);
  if (!r.ok) rmSync(dest, { force: true });
  return reply(r);
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
    hostname: LAN_ADDR, port: LAN_PORT, idleTimeout: 120, maxRequestBodySize: Math.max(UPDATE_MAX, FILE_MAX) + 1024, ...(tls ? { tls } : {}),
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
.pair input#dn{font-size:16px;letter-spacing:0;text-transform:none}.pair .btn{width:100%;max-width:320px}.err{color:#dc2626;min-height:22px;margin-top:12px}
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

// DIVE-7579 (m4): every device was named after navigator.platform ("Linux
// x86_64" three times over), so the owner could not tell which one to remove.
// The owner may name it; else browser + kind of device, e.g. "Safari on iPhone".
function guessName() {
  const u = navigator.userAgent || "", has = (x) => u.includes(x);
  const os = has("iPhone") ? "iPhone" : has("iPad") ? "iPad" : has("Android") ? "Android" : has("CrOS") ? "Chromebook"
    : has("Macintosh") ? "Mac" : has("Windows") ? "Windows PC" : has("Linux") ? "Linux" : "device";
  const br = has("Edg/") ? "Edge" : has("Firefox/") ? "Firefox" : has("Chrome/") ? "Chrome" : has("Safari/") ? "Safari" : "";
  return br ? br + " on " + os : os;
}
function deviceName() { const v = ($("#dn") && $("#dn").value.trim()) || ""; return (v || guessName()).slice(0, 40); }
function showPair() {
  view = "pair"; reset("Office chat", false);
  app.innerHTML = '<div class="pair"><h2>Connect this device</h2><p>Type the code your office server shows.</p>' +
    '<input id="code" autocomplete="one-time-code" inputmode="text" maxlength="12" placeholder="ABCD-1234" aria-label="Pairing code">' +
    '<input id="dn" maxlength="40" placeholder="' + esc(guessName()) + '" aria-label="Name this device (optional)">' +
    '<button class="btn" id="go">Connect</button><div class="err" id="err"></div></div>';
  const go = async () => {
    $("#err").textContent = "";
    try {
      const r = await fetch("/api/pair", { method: "POST", headers: H, body: JSON.stringify({ code: $("#code").value, name: deviceName() }) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(j.error || "That code did not work.");
      if (APP) return location.replace("/");
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
// DIVE-8807: a join link (https://<office>/join#<code>, from Team → Invite)
// spends its code once, then this device is in and the code leaves the address.
// DIVE-8809: the server marks the page when an office app is installed; a device
// that signs in here then opens the app at /.
const APP = document.documentElement.dataset.app === "1";
async function boot() {
  if (location.pathname === "/join") {
    const token = location.hash.slice(1);
    history.replaceState(null, "", "/");
    if (token) {
      const r = await fetch("/api/proxy/team/accept", { method: "POST", headers: H, body: JSON.stringify({ token }) }).catch(() => null);
      if (!r || !r.ok) { showPair(); $("#err").textContent = "That invite link is used or expired. Ask for a new one."; return; }
      if (APP) return location.replace("/");
    }
  }
  window.onhashchange = route; route();
}
boot();
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
nav.tabs[hidden]{display:none}nav.tabs{position:fixed;left:0;right:0;bottom:0;display:flex;background:var(--card);border-top:1px solid var(--line);padding-bottom:env(safe-area-inset-bottom)}
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
input,textarea{width:100%;padding:12px;font:inherit;border:1px solid var(--line);border-radius:12px;background:var(--bg);color:var(--ink);margin:6px 0}textarea{resize:vertical}
.ok{color:var(--live)}.leak{color:var(--bad);font-weight:600}.big{font-size:20px;font-weight:600;margin:4px 0}
.toast{position:fixed;left:16px;right:16px;bottom:84px;margin:auto;max-width:520px;padding:12px 14px;border-radius:12px;background:var(--ink);color:var(--bg);display:none}
.empty{padding:32px 8px;text-align:center;color:var(--mute)}
.seg{display:flex;gap:8px;margin:6px 0 12px}.seg button{flex:1;border:1px solid var(--line);border-radius:12px;background:var(--bg);color:var(--ink);font:inherit;padding:10px 8px;cursor:pointer;text-align:left}
.seg button b{display:block}.seg button span{color:var(--mute);font-size:13px}.seg button.on{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent)}
.code{font:600 34px/1.2 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:4px;text-align:center;padding:14px;margin:8px 0;border:1px dashed var(--accent);border-radius:12px}
.pick{display:block;width:100%;text-align:left;border:1px solid var(--line);border-radius:12px;background:var(--bg);color:var(--ink);font:inherit;padding:10px 12px;margin:6px 0;cursor:pointer}
.pick span{display:block;color:var(--mute);font-size:13px}.pick.on{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent)}
.cw{max-width:720px;margin:12px auto 0;padding:12px 14px;border-radius:14px;border:1px solid var(--warn);color:var(--warn);background:var(--card);font-weight:600}
@media (max-width:752px){.cw{margin:12px 16px 0}}
</style></head><body>
<header><h1 id="title">Office server</h1><a href="/">💬 Chat</a></header>
<div id="cw" class="cw" hidden></div>
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
    certWarn(d.certificate);
    const leaks = d.localOnly.filter((r) => !r.ok);
    // DIVE-7579 (m5): the headline and only what needs the owner. The full list
    // of checked items (unit names) stays one tap away, not on the screen.
    const row = (r) => '<div class="item"><span class="dot ' + (r.ok ? "on" : "bad") + '"></span><div class="grow"><b>' + esc(r.item) + '</b><span>' + esc(r.state) + '</span></div></div>';
    const seen = (t) => { const x = new Date(t * 1000); return x.toDateString() === new Date().toDateString() ? "today " + x.toTimeString().slice(0, 5) : x.toLocaleDateString(); };
    app.innerHTML = '<div class="card"><h3>Stays in the office?</h3>' +
      (d.localOnly.length ? '<div class="big ' + (leaks.length ? "leak" : "ok") + '">' + (leaks.length ? "⚠️ " + leaks.length + " thing(s) still reach the internet" : "✅ Fully local") + '</div>' +
        leaks.map(row).join("") +
        '<details><summary class="mute">What was checked (' + d.localOnly.length + ')</summary>' + d.localOnly.filter((r) => r.ok).map(row).join("") + '</details>'
        : '<p class="mute">Local-only mode is not set up on this server.</p>') + '</div>' +
      '<div class="card"><h3>Your AI</h3>' + (d.accounts.length ? d.accounts.map((a) =>
        '<div class="item"><div class="grow"><b>' + esc(a.model || a.name) + '</b><span>' + esc(a.baseUrl) + '</span></div><button class="btn line" data-test="' + esc(a.name) + '">Test</button></div>').join("")
        : '<p class="mute">No local AI added yet.</p>') + '</div>' +
      // DIVE-8611: the firm's own certificate, when it runs out, and whether renewals come in by themselves.
      (d.certificate && d.certificate.mine ? '<div class="card"><h3>Certificate</h3><p class="' + (d.certificate.warning ? "leak" : "mute") + '">' +
        (d.certificate.warning ? "⚠️ " + esc(d.certificate.warning) : "✅ Valid until " + esc(d.certificate.until) + ". " +
          (d.certificate.renewsBySelf ? "When your IT renews it, the chat takes the new one by itself." : "When your IT renews it, they give the new files to this server once more.")) + '</p></div>' : "") +
      '<div class="card"><h3>Connected devices</h3><button class="btn" id="inv" style="margin:6px 0 4px">＋ Invite a person</button>' + d.devices.map((v) =>
        '<div class="item"><div class="grow"><b>' + esc(v.name) + (v.id === d.me ? " (this one)" : "") + '</b><span>' + (v.role === "owner" ? "Can manage" : "Chat only") + ' · last seen ' + esc(seen(v.last_seen)) + '</span></div><button class="btn red" data-rv="' + esc(v.id) + '">Remove</button></div>').join("") + '</div>' +
      (d.updateFromFile ? '<div class="card"><h3>Update</h3><p class="mute">This server runs 5dive ' + esc(d.version || "") + '. Got an update file or the Office server file from your IT team? Pick it and install.</p>' +
        '<input type="file" id="uf" accept=".tar,.run"><button class="btn" id="ub">Install update</button><p id="us" class="mute"></p>' +
        '<details id="ul" hidden><summary class="mute">What the last install said</summary><pre id="ulog" class="mute" style="white-space:pre-wrap;overflow-wrap:anywhere;font-size:12px"></pre></details></div>' : "") +
      // DIVE-7886: a Support file for a server with no internet (marketing's words).
      '<div class="card"><h3>Need help?</h3><p class="mute">No internet on this server? Save a support file, then attach it in Support in the 5dive app from any computer.</p>' +
        '<textarea id="sw" rows="3" maxlength="2000" placeholder="What went wrong?"></textarea><button class="btn" id="sb">Save support file</button>' +
        '<p class="mute">It holds this server&#39;s version and system details, its health checks and your text. Nothing else.</p></div>';
    app.onclick = async (e) => {
      const t = e.target.closest("button[data-test]"), r = e.target.closest("button[data-rv]");
      if (t) {
        t.disabled = true; t.textContent = "Testing…";
        try { const x = await api("/api/panel/test", { account: t.dataset.test }); toast(x && x.ok ? "✅ Your AI answered" : "⚠️ " + ((x && x.reason) || "No answer")); }
        catch (er) { toast(er.message); }
        t.disabled = false; t.textContent = "Test";
      }
      if (r && confirm("Remove this device? It will need a new code to come back.")) act(r, "/api/panel/revoke", { id: r.dataset.rv }, "Device removed");
      if (e.target.id === "ub") installUpdate();
      if (e.target.id === "inv") invite();
      if (e.target.id === "sb") supportFile(e.target);
    };
    if (d.updateFromFile) { try { const u = await api("/api/panel/update"); if (u && u.state === "running") watchUpdate(); else if (u && u.state !== "none") updateDone(u); } catch (er) {} }
  },
};
// DIVE-8611: the certificate warning sits above every tab until it is renewed.
function certWarn(c) {
  const e = $("#cw"), w = c && c.mine && c.warning ? c.warning : "";
  e.textContent = w ? "⚠️ " + w : ""; e.hidden = !w;
}
// DIVE-7886: save a Support file. The text root answers with is the file,
// byte for byte (a Blob of a string is its UTF-8), downloaded under root's name.
async function supportFile(btn) {
  const what = $("#sw").value;
  if (!what.trim()) { toast("Describe the problem first."); return; }
  btn.disabled = true; const t = btn.textContent; btn.textContent = "Working…";
  try {
    const d = await api("/api/panel/support-file", { what });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([d.file], { type: "application/json" }));
    a.download = d.name || "5dive-support-file.json";
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 10000);
    toast("Saved. Now attach it in Support in the 5dive app.");
  } catch (e) { toast(e.message); }
  btn.disabled = false; btn.textContent = t;
}
// DIVE-7599: invite a person. Their name, Chat or Manage, then the one-time
// code and the address to hand over. The code is shown once, here only.
function invite() {
  let role = "chat";
  $("#tabs").hidden = true; window.scrollTo(0, 0);
  app.onclick = null;
  app.innerHTML = '<div class="card"><h3>Invite a person</h3><p class="mute">They get a code to connect their phone or laptop.</p>' +
    '<input id="pn" placeholder="Their name, e.g. Ana" maxlength="40" autocomplete="off">' +
    '<div class="seg" id="seg"><button data-r="chat" class="on"><b>💬 Chat</b><span>Talk to the agents</span></button>' +
    '<button data-r="owner"><b>⚙️ Manage</b><span>Chat, and run this server</span></button></div>' +
    '<button class="btn" id="go">Get a code</button> <button class="btn line" id="cx">Cancel</button></div>';
  $("#seg").onclick = (e) => { const b = e.target.closest("button[data-r]"); if (!b) return; role = b.dataset.r; for (const x of $("#seg").children) x.classList.toggle("on", x === b); };
  $("#cx").onclick = () => show("settings");
  $("#go").onclick = async () => {
    const name = $("#pn").value.trim(), go = $("#go");
    if (!name) { toast("Type their name first."); return; }
    go.disabled = true; go.textContent = "Working…";
    try {
      const c = await api("/api/panel/invite", { name, role });
      const fp = String(c.fingerprint || "").slice(-23);
      app.innerHTML = '<div class="card"><h3>Code for ' + esc(c.name || name) + '</h3>' +
        '<p class="mute">On their phone or laptop, open</p><div class="big">' + esc(c.url) + '</div>' +
        '<p class="mute">and type this code. It works once, for 15 minutes.</p><div class="code" id="cd">' + esc(c.code) + '</div>' +
        '<p class="mute">' + (c.role === "owner" ? "⚙️ They can chat and manage this server." : "💬 They can chat with the agents.") + '</p>' +
        (fp ? '<p class="mute">If the browser warns about the certificate, it is safe when it ends with ' + esc(fp) + '.</p>' : '') +
        '<button class="btn" id="dn">Done</button></div>';
      $("#dn").onclick = () => show("settings");
    } catch (er) { toast(er.message); go.disabled = false; go.textContent = "Get a code"; }
  };
  $("#pn").focus();
}
// DIVE-7599: first run. No AI on this server yet: find the office's AI server,
// test it, save it and make the first agent, without a terminal.
async function setup() {
  let pick = null;
  $("#tabs").hidden = true; window.scrollTo(0, 0); app.onclick = null;
  app.innerHTML = '<div class="card"><h3>Set up your office AI</h3><p class="mute" id="sl">Your agents think with an AI server in your office. Looking for one on your network…</p><div id="found"><div class="empty">Searching…</div></div>' +
    '<details id="typed"><summary class="mute">Type its address instead</summary><input id="au" placeholder="e.g. 192.168.1.20:11434" autocapitalize="off" autocomplete="off"><button class="btn line" id="ac">Check</button></details></div>' +
    '<div class="card"><h3>Your first agent</h3><input id="an" value="assistant" maxlength="16" autocapitalize="off"><button class="btn" id="sb" disabled>Test and set up</button><p id="ss" class="mute"></p></div>' +
    '<p class="mute" style="text-align:center"><a href="#team" id="skip" style="color:var(--accent)">Skip for now</a></p>';
  const list = (servers, empty) => {
    const rows = [];
    for (const s of servers) for (const m of (s.models || [])) rows.push({ url: s.url, model: m, kind: s.kind });
    $("#sl").textContent = rows.length ? "Pick the AI your agents will think with." : "Your agents think with an AI server in your office.";
    $("#found").innerHTML = rows.length ? rows.map((r, i) => '<button class="pick" data-i="' + i + '"><b>' + esc(r.model) + '</b><span>' + esc(r.kind + " · " + r.url) + '</span></button>').join("") : '<div class="empty">' + esc(empty) + '</div>';
    $("#found").onclick = (e) => {
      const b = e.target.closest("button[data-i]"); if (!b) return;
      pick = rows[+b.dataset.i];
      for (const x of $("#found").querySelectorAll(".pick")) x.classList.toggle("on", x === b);
      $("#sb").disabled = false;
    };
    if (rows.length === 1) $("#found").querySelector(".pick").click();
  };
  $("#skip").onclick = () => { try { sessionStorage.setItem("skipSetup", "1"); } catch (er) {} };
  $("#ac").onclick = async () => {
    let url = $("#au").value.trim(); if (!url) return;
    if (!/^https?:[/][/]/.test(url)) url = "http://" + url;
    $("#ac").disabled = true;
    try { const d = await api("/api/panel/ai-scan", { url }); list(d.servers || [], "Nothing answered there. Check the address and that the AI server is on."); }
    catch (er) { toast(er.message); }
    $("#ac").disabled = false;
  };
  $("#sb").onclick = async () => {
    const agent = $("#an").value.trim().toLowerCase(), sb = $("#sb");
    if (!pick || !agent) return;
    sb.disabled = true; $("#ss").textContent = "Testing " + pick.model + "… this can take a minute.";
    try {
      const r = await api("/api/panel/ai-setup", { url: pick.url, model: pick.model, agent });
      app.innerHTML = '<div class="card"><h3>✅ Your office AI works</h3><p class="mute">' + esc(r.agent) + ' is ready in the chat, thinking with ' + esc(r.model) + '.</p>' +
        '<div class="row"><a class="btn" href="/" style="text-decoration:none">Open chat</a><a class="btn line" href="#team" style="text-decoration:none">Manage</a></div></div>';
    } catch (er) { $("#ss").textContent = "⚠️ " + er.message; sb.disabled = false; }
  };
  try { const d = await api("/api/panel/ai-scan", {}); list(d.servers || [], "No AI server found on your network. Type its address below."); if (!(d.servers || []).length) $("#typed").open = true; }
  catch (er) { list([], er.message); $("#typed").open = true; }
}
// DIVE-7579 (D4): upload the file (with progress), then poll until the install
// ends. The install restarts the agents and this server, so a failed poll is
// retried, not reported.
function updateSay(t) { const e = $("#us"); if (e) e.textContent = t; }
// DIVE-7603 (n3): the last install's verdict and what it printed, also after a reload.
function updateLog(u) { const d = $("#ul"), p = $("#ulog"); if (!d || !p) return; p.textContent = (u && u.log) || ""; d.hidden = !(u && u.log); }
function updateDone(u) {
  updateLog(u);
  if (u.state === "done") updateSay("✅ " + (u.message || "Updated."));
  if (u.state === "failed") updateSay("⚠️ " + (u.message || "The update was not installed."));
}
function installUpdate() {
  const f = $("#uf") && $("#uf").files[0], b = $("#ub");
  if (!f) { toast("Pick the update file first."); return; }
  b.disabled = true;
  const x = new XMLHttpRequest();
  x.open("POST", "/api/panel/update");
  x.setRequestHeader("x-local-chat", "1");
  x.upload.onprogress = (ev) => { if (ev.lengthComputable) updateSay("Sending the file… " + Math.round((ev.loaded / ev.total) * 100) + "%"); };
  x.onload = () => {
    let j = {}; try { j = JSON.parse(x.responseText); } catch (er) {}
    if (x.status === 200 && j.ok !== false) { watchUpdate(); return; }
    b.disabled = false; updateSay("⚠️ " + (j.error || "The file was not taken."));
  };
  x.onerror = () => { b.disabled = false; updateSay("⚠️ The file did not arrive. Try again."); };
  updateSay("Sending the file…");
  x.send(f);
}
async function watchUpdate() {
  const b = $("#ub"); if (b) b.disabled = true;
  updateLog(null);
  updateSay("Checking the file… if it is newer, it installs in about a minute.");
  const until = Date.now() + 15 * 60 * 1000;
  while (Date.now() < until) {
    await new Promise((r) => setTimeout(r, 3000));
    let u = null;
    try { const r = await fetch("/api/panel/update", { credentials: "same-origin" }); const j = await r.json(); if (r.ok) u = j.data; } catch (er) { continue; }
    if (!u || u.state === "running") continue;
    if (u.state === "done") { updateDone(u); toast(u.message || "Updated"); return; }
    if (u.state === "failed") { updateDone(u); if (b) b.disabled = false; return; }
    return;
  }
  updateSay("Still not finished after 15 minutes. Reload this page to check.");
}
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
// DIVE-7599: a server with no AI yet opens on the setup sheet (once per visit
// after "Skip for now").
(async () => {
  let skip = false; try { skip = sessionStorage.getItem("skipSetup") === "1"; } catch (er) {}
  // DIVE-8611: read once on open, so the certificate warning shows whatever tab opens.
  let d = null;
  try { d = await api("/api/panel/settings"); certWarn(d.certificate); } catch (er) { if (/can chat/.test(er.message)) return; }
  if (!location.hash && !skip && d) {
    if (!d.accounts.length) { setup(); return; }
  }
  window.onhashchange();
})();
</script></body></html>`;
LOCAL_CHAT_TS
  _local_office_api_ts
}

# DIVE-8807: the office app's API — the app's own paths under /api/proxy/*,
# answered with the shapes api.5dive.com returns. Appended to server.ts (one
# file on the box); it uses the store, the people and the panel door above.
_local_office_api_ts() {
  cat <<'OFFICE_API_TS'
// ── office app API (DIVE-8807) ────────────────────────────────────────────────
// The office copy of the 5dive app calls the SAME paths it calls on
// api.5dive.com, under /api/proxy/*, with the session cookie and no bearer.
// Only the routes below answer; every other path is a 404 and nothing is ever
// forwarded off this box. Shapes follow api.5dive.com (src/routes/team.ts,
// conversations.ts, messages.ts, server.ts, chat-e2e.ts) and carry office:true
// where the app needs to tell the two apart.
const TEAM_MAX = 20;
// A join link's token: 32 random bytes, 43 base64url characters (the shape the
// app takes from the link's #). Spent exactly as given, never case-folded.
const linkToken = () => randomBytes(32).toString("base64url");
const INVITE_TTL = 24 * 3600;
type Person = { id: string; name: string; role: "owner" | "member"; created: number };
type Ctx = { dev: Device; me: Person };
type Handler = (req: Request, url: URL, c: Ctx, m: RegExpMatchArray) => Promise<Response> | Response;
const ownerOnly = () => json({ error: "owner_only", reason: "Only the team's owner can do this." }, 403);
async function body(req: Request): Promise<Record<string, any> | null> {
  try { const b = await req.json(); return b && typeof b === "object" && !Array.isArray(b) ? b : null; } catch { return null; }
}
const iso = (s: number | null) => (s ? new Date(s * 1000).toISOString() : null);
const agentList = (v: unknown): string[] | null | undefined =>
  v === null ? null : Array.isArray(v) && v.every((a) => typeof a === "string" && AGENT_RE.test(a)) ? [...new Set(v as string[])].slice(0, 200) : undefined;
function agentsOf(person: string, role: string): string[] | null {
  const g = grantsOf(person, role);
  return g ? [...g].sort() : null;
}
function setGrants(person: string, list: string[] | null) {
  db.transaction(() => {
    db.query("DELETE FROM grants WHERE person = ?").run(person);
    for (const a of list ?? ["*"]) db.query("INSERT INTO grants (person, agent) VALUES (?, ?)").run(person, a);
  })();
}
function personView(p: Person) {
  const devices = (db.query("SELECT COUNT(*) AS n FROM devices WHERE person = ? AND revoked = 0").get(p.id) as { n: number }).n;
  return {
    id: p.id, name: p.name, email: p.name, invitedEmail: p.name, role: p.role, state: "joined",
    invitedAt: iso(p.created), joinedAt: iso(p.created), agents: agentsOf(p.id, p.role), perms: [], devices,
  };
}
// An invite not yet used shows on the owner's list as "invited"; its id is
// "i" + the first 12 hex of the code's hash, so the owner can cancel it.
function inviteViews() {
  const rows = db.query("SELECT hash, role, name, agents, expires FROM pair_codes WHERE used = 0 AND expires >= ? AND person = '' AND name != '' ORDER BY expires")
    .all(now()) as { hash: string; role: string; name: string; agents: string; expires: number }[];
  return rows.map((r) => {
    let agents: string[] | null = null;
    if (r.agents !== "*") { try { agents = JSON.parse(r.agents); } catch { agents = []; } }
    return {
      id: "i" + r.hash.slice(0, 12), name: r.name, email: r.name, invitedEmail: r.name, role: r.role === "owner" ? "owner" : "member",
      state: "invited", invitedAt: iso(r.expires - INVITE_TTL), joinedAt: null, expiresAt: iso(r.expires), agents, perms: [], devices: 0,
    };
  });
}
const livePeople = () => db.query("SELECT id, name, role, created FROM people WHERE removed = 0 ORDER BY created").all() as Person[];
function removePerson(id: string): boolean {
  return db.transaction(() => {
    if (db.query("UPDATE people SET removed = ? WHERE id = ? AND removed = 0").run(now(), id).changes !== 1) return false;
    db.query("UPDATE devices SET revoked = 1 WHERE person = ?").run(id);
    db.query("DELETE FROM grants WHERE person = ?").run(id);
    db.query("UPDATE pair_codes SET used = 1 WHERE person = ?").run(id);
    return true;
  })();
}
const ownerCount = () => (db.query("SELECT COUNT(*) AS n FROM people WHERE role = 'owner' AND removed = 0").get() as { n: number }).n;

const teamRoutes: [string, RegExp, Handler][] = [
  ["GET", /^\/me$/, (_r, _u, c) => json({ id: c.me.id, name: c.me.name, role: c.me.role, office: true })],
  // DIVE-8809 (contract addition from DIVE-8806): the app's "Sign out" — this device only.
  ["DELETE", /^\/me$/, (_r, _u, c) => {
    db.query("UPDATE devices SET revoked = 1 WHERE id = ?").run(c.dev.id);
    return new Response(null, { status: 204, headers: { "set-cookie": "lc_dev=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0", "cache-control": "no-store" } });
  }],
  ["GET", /^\/team$/, (_r, _u, c) => {
    const people = livePeople().filter((p) => p.id !== c.me.id || c.me.role === "member");
    const cabinets = { current: null, teams: [], max: 1 };
    if (c.me.role === "owner")
      return json({ role: "owner", me: null, ownerEmail: null, members: [...people.map(personView), ...inviteViews()], max: TEAM_MAX, cabinets, office: true });
    const owner = livePeople().find((p) => p.role === "owner");
    return json({
      role: "member", me: c.me.name, agents: agentsOf(c.me.id, c.me.role), perms: [], ownerEmail: owner?.name ?? null,
      members: people.map(personView), max: TEAM_MAX, cabinets, office: true,
    });
  }],
  // Team → Invite: a one-time link for one person (24 h). The app draws the QR.
  // With personId it adds a device for someone already on the team (an owner
  // for anyone, a person for themself): it joins them, it makes no one new.
  ["POST", /^\/team\/invite$/, async (req, url, c) => {
    const b = await body(req);
    if (!b) return json({ error: "invalid body" }, 400);
    if (b.personId !== undefined) {
      if (c.me.role !== "owner" && b.personId !== c.me.id) return ownerOnly();
      const p = livePeople().find((x) => x.id === b.personId);
      if (!p) return json({ error: "not_found" }, 404);
      const code = linkToken(), expires = now() + INVITE_TTL;
      db.query("INSERT INTO pair_codes (hash, expires, role, name, person, agents) VALUES (?, ?, ?, ?, ?, '[]')")
        .run(sha256(code), expires, p.role === "owner" ? "owner" : "chat", p.name, p.id);
      return json({ ok: true, id: p.id, link: `${url.origin}/join#${code}`, emailed: false, expiresAt: iso(expires) });
    }
    if (c.me.role !== "owner") return ownerOnly();
    // The app's invite form sends an email; the office has no mail, so it is the person's name.
    const name = cleanName(b.name ?? b.email);
    if (!name || !/^[A-Za-z0-9]/.test(name)) return json({ error: "invalid_email", reason: "Type their name (letters, digits, spaces)." }, 400);
    const role = b.role === "owner" ? "owner" : "member";
    // The app's "All agents" leaves `agents` out (every agent, as online); a
    // list grants exactly those, and [] none. A person with no grant row uses no agent.
    const agents = b.agents === undefined ? null : agentList(b.agents);
    if (agents === undefined) return json({ error: "invalid_agents" }, 400);
    if (livePeople().length + inviteViews().length >= TEAM_MAX) return json({ error: "team_full", reason: `A team has at most ${TEAM_MAX} people.` }, 409);
    const code = linkToken();
    const hash = sha256(code), expires = now() + INVITE_TTL;
    db.query("DELETE FROM pair_codes WHERE expires < ? OR used = 1").run(now());
    db.query("INSERT INTO pair_codes (hash, expires, role, name, person, agents) VALUES (?, ?, ?, ?, '', ?)")
      .run(hash, expires, role === "owner" ? "owner" : "chat", name, agents === null || role === "owner" ? "*" : JSON.stringify(agents));
    return json({ ok: true, id: "i" + hash.slice(0, 12), link: `${url.origin}/join#${code}`, emailed: false, expiresAt: iso(expires) });
  }],
  ["PUT", /^\/team\/members\/([a-f0-9]{8,32})\/agents$/, async (req, _u, c, m) => {
    if (c.me.role !== "owner") return ownerOnly();
    const b = await body(req);
    const list = b && "agents" in b ? agentList(b.agents) : undefined;
    if (list === undefined) return json({ error: "invalid_agents" }, 400);
    const p = livePeople().find((x) => x.id === m[1]);
    if (!p) return json({ error: "not_found" }, 404);
    setGrants(p.id, list);
    return json({ ok: true, agents: agentsOf(p.id, p.role) });
  }],
  ["DELETE", /^\/team\/members\/(i?[a-f0-9]{8,32})$/, (_r, _u, c, m) => {
    if (c.me.role !== "owner") return ownerOnly();
    const id = m[1];
    if (id.startsWith("i")) {
      const hit = db.query("UPDATE pair_codes SET used = 1 WHERE substr(hash, 1, 12) = ? AND used = 0").run(id.slice(1)).changes;
      return hit ? json({ ok: true }) : json({ error: "not_found" }, 404);
    }
    if (id === c.me.id) return json({ error: "self" }, 400);
    return removePerson(id) ? json({ ok: true }) : json({ error: "not_found" }, 404);
  }],
  ["POST", /^\/team\/leave$/, (_r, _u, c) => {
    if (c.me.role === "owner" && ownerCount() <= 1) return json({ error: "not_a_member", reason: "The last owner cannot leave." }, 400);
    removePerson(c.me.id);
    return json({ ok: true }, 200, { "set-cookie": "lc_dev=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0" });
  }],
];

// Chat: one conversation per agent (the office has no group chats), with a
// stable number id, and a read mark per person.
db.exec(`
CREATE TABLE IF NOT EXISTS conversations (id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS reads (person TEXT NOT NULL, conversation INTEGER NOT NULL, last_id INTEGER NOT NULL, PRIMARY KEY (person, conversation));
`);
function convId(agent: string): number {
  db.query("INSERT OR IGNORE INTO conversations (agent) VALUES (?)").run(agent);
  return (db.query("SELECT id FROM conversations WHERE agent = ?").get(agent) as { id: number }).id;
}
const convAgent = (id: number) => (db.query("SELECT agent FROM conversations WHERE id = ?").get(id) as { agent: string } | null)?.agent ?? null;
const usable = (c: Ctx) => agents().filter((a) => mayUse(c.dev, a));
// The app's words: inbound = a person to an agent, outbound = an agent's reply.
const direction = (dir: string) => (dir === "in" ? "inbound" : "outbound");
const proxyMsg = (r: Row & { collected_at?: string | null }) => ({
  id: r.id, conversation: convId(r.agent), agent: r.agent, direction: direction(r.dir), chatId: String(convId(r.agent)), body: r.body,
  metadata: JSON.parse(r.meta || "{}"), createdAt: r.created_at, collectedAt: r.collected_at ?? null, deliveredAt: r.collected_at ?? null,
});
function convView(agent: string, person: string) {
  const id = convId(agent);
  const last = db.query("SELECT * FROM messages WHERE agent = ? ORDER BY id DESC LIMIT 1").get(agent) as Row | null;
  const lastReadId = (db.query("SELECT last_id FROM reads WHERE person = ? AND conversation = ?").get(person, id) as { last_id: number } | null)?.last_id ?? 0;
  const unread = (db.query("SELECT COUNT(*) AS n FROM messages WHERE agent = ? AND dir = 'out' AND id > ?").get(agent, lastReadId) as { n: number }).n;
  return {
    id, dmAgent: agent, title: null, defaultAgent: null, participants: [agent], unread, lastReadId,
    lastMessage: last ? { id: last.id, direction: direction(last.dir), agent: last.agent, body: last.body, createdAt: last.created_at } : null,
  };
}
// The agents one message read is about: ?conversation= or ?agent=, else all the person may use.
function scope(url: URL, c: Ctx): string[] | Response {
  const conv = Number(url.searchParams.get("conversation") ?? 0);
  const agent = conv ? convAgent(conv) : url.searchParams.get("agent");
  if (conv && !agent) return json({ error: "not_found" }, 404);
  if (agent) {
    if (!AGENT_RE.test(agent)) return json({ error: "invalid agent" }, 400);
    return mayUse(c.dev, agent) ? [agent] : json(NOT_YOUR_AGENT, 403);
  }
  return usable(c);
}
// since = null: the latest `limit` rows; a number: the rows after it, oldest first.
function readMessages(list: string[], since: number | null, limit: number): Row[] {
  if (!list.length) return [];
  const marks = list.map(() => "?").join(",");
  return since !== null
    ? (db.query(`SELECT * FROM messages WHERE agent IN (${marks}) AND id > ? ORDER BY id LIMIT ?`).all(...list, since, limit) as Row[])
    : (db.query(`SELECT * FROM (SELECT * FROM messages WHERE agent IN (${marks}) ORDER BY id DESC LIMIT ?) ORDER BY id`).all(...list, limit) as Row[]);
}
// A member may send or fetch files only inside an agent's upload folder they may use.
function uploadAgent(path: string): string | null {
  const m = path.startsWith(`${UPLOADS}/`) ? path.slice(UPLOADS.length + 1).match(/^([a-z0-9][a-z0-9-]{0,63})\/[^/]+$/) : null;
  return m ? m[1] : null;
}

const chatRoutes: [string, RegExp, Handler][] = [
  ["GET", /^\/server\/conversations$/, (_r, _u, c) =>
    json({ rosterKnown: true, hiddenRemoved: 0, conversations: usable(c).filter((a) => a !== NOTICE_AGENT || c.me.role === "owner").map((a) => convView(a, c.me.id)) })],
  ["POST", /^\/server\/conversations$/, async (req, _u, c) => {
    const b = await body(req);
    const agent = typeof b?.agent === "string" ? b.agent : "";
    if (!AGENT_RE.test(agent)) return json({ error: "office chats are one agent each", reason: "office_dm_only" }, 400);
    if (!mayUse(c.dev, agent)) return json(NOT_YOUR_AGENT, 403);
    const existed = !!db.query("SELECT 1 FROM conversations WHERE agent = ?").get(agent);
    const v = convView(agent, c.me.id);
    return json({ ok: true, created: !existed, conversation: { id: v.id, dmAgent: agent, title: null, defaultAgent: null, participants: [agent] } });
  }],
  ["POST", /^\/server\/conversations\/(\d+)\/read$/, async (req, _u, c, m) => {
    const agent = convAgent(Number(m[1]));
    if (!agent) return json({ error: "not_found" }, 404);
    if (!mayUse(c.dev, agent)) return json(NOT_YOUR_AGENT, 403);
    const b = await body(req);
    const lastId = Number.isInteger(b?.lastId) && b!.lastId > 0 ? b!.lastId : 0;
    db.query("INSERT INTO reads (person, conversation, last_id) VALUES (?, ?, ?) ON CONFLICT (person, conversation) DO UPDATE SET last_id = max(last_id, excluded.last_id)")
      .run(c.me.id, Number(m[1]), lastId);
    return json({ ok: true, lastReadId: lastId });
  }],
  // List, and the long poll: ?since=<id>&wait=<s> holds up to 25 s for a new row.
  ["GET", /^\/server\/messages$/, async (req, url, c) => {
    const list = scope(url, c);
    if (list instanceof Response) return list;
    const since = url.searchParams.has("since") ? Math.max(Number(url.searchParams.get("since")) || 0, 0) : null;
    const limit = Math.min(Math.max(Number(url.searchParams.get("limit") ?? 100) || 100, 1), 500);
    const wait = since !== null ? Number(url.searchParams.get("wait") ?? 0) || 0 : 0;
    const got = await waitFor(() => { const r = readMessages(list, since, limit); return r.length ? [r] : []; }, wait, req.signal);
    return json({ messages: (got[0] ?? []).map(proxyMsg) });
  }],
  // The live feed the app opens on api.5dive.com: ready, then message and
  // status events (an agent working or done), a ping when 25 s pass quietly.
  ["GET", /^\/server\/messages\/stream$/, (req, url, c) => {
    const list = scope(url, c);
    if (list instanceof Response) return list;
    let last = (db.query("SELECT COALESCE(MAX(id), 0) AS n FROM messages").get() as { n: number }).n;
    // Each status change is a new object in the map, so "changed" is "not the one last sent".
    const sent = new Map(list.map((a) => [a, status.get(a)]));
    const changed = () => list.filter((a) => status.get(a) && status.get(a) !== sent.get(a));
    const enc = new TextEncoder();
    const stream = new ReadableStream({
      async start(ctl) {
        const send = (ev: string, d: unknown) => ctl.enqueue(enc.encode(`event: ${ev}\ndata: ${JSON.stringify(d)}\n\n`));
        send("ready", {});
        while (!req.signal.aborted) {
          const got = await waitFor(() => { const r = readMessages(list, last, 100); return r.length || changed().length ? [r] : []; }, WAIT_MAX, req.signal);
          if (req.signal.aborted) break;
          if (!got.length) { send("ping", {}); continue; }
          for (const a of changed()) {
            const st = status.get(a)!;
            send("status", { agent: a, conversation: convId(a), active: st.active, ...(st.label ? { label: st.label } : {}) });
            sent.set(a, st);
          }
          for (const r of got[0]) { send("message", proxyMsg(r)); last = Math.max(last, r.id); }
        }
        try { ctl.close(); } catch {}
      },
    });
    return new Response(stream, { headers: { "content-type": "text/event-stream", "cache-control": "no-store" } });
  }],
  ["POST", /^\/server\/messages$/, async (req, _u, c) => {
    const b = await body(req);
    if (!b) return json({ error: "invalid body" }, 400);
    const agent = Number.isInteger(b.conversation) ? convAgent(b.conversation) : typeof b.agent === "string" ? b.agent : null;
    if (!agent || !AGENT_RE.test(agent) || agent === NOTICE_AGENT) return json({ error: "invalid agent" }, 400);
    if (!mayUse(c.dev, agent)) return json(NOT_YOUR_AGENT, 403);
    let text = typeof b.body === "string" ? b.body.trim() : "";
    const md = b.metadata && typeof b.metadata === "object" ? b.metadata : {};
    if (md.e2e) return json({ error: "this office chat is not end-to-end sealed", reason: "e2e_off_local" }, 409);
    const named = [...(typeof md.image_path === "string" ? [md.image_path] : []), ...(Array.isArray(md.files) ? md.files : [])];
    const files = [...new Set(named)].filter((f: unknown) => typeof f === "string" && fileRow(f) && uploadAgent(f) === agent).slice(0, 10) as string[];
    if (!text && !files.length) return json({ error: "empty message" }, 400);
    if (text.length > 65536) return json({ error: "message too long" }, 413);
    const meta: Record<string, unknown> = { from: { name: c.me.name } };
    if (files.length) {
      meta.files = files.map((f) => { const r = fileRow(f)!; return { path: r.path, name: r.name, size: r.size }; });
      meta.image_path = files[0];
      const extra = files.slice(1).map((f) => `[file: ${f}]`).join("\n");
      if (extra) text = text ? `${text}\n${extra}` : extra;
      if (!text) text = `[file: ${fileRow(files[0])!.name}]`;
    }
    const id = insert(agent, "in", text, meta, c.dev.id);
    return json({ ok: true, id, conversation: convId(agent), agent, routed: [agent], delivered: false, queued: true });
  }],
  // Files: the raw body goes in under the agent's upload folder; download needs the same right.
  ["POST", /^\/server\/files\/upload$/, async (req, url, c) => {
    let path = url.searchParams.get("path") ?? "";
    const agent = url.searchParams.get("agent") ?? uploadAgent(path) ?? "";
    if (!AGENT_RE.test(agent)) return json({ error: "path outside allowed root" }, 403);
    if (!mayUse(c.dev, agent)) return json(NOT_YOUR_AGENT, 403);
    const bytes = await readBody(req);
    if (!bytes || !bytes.length) return json({ error: "file is empty or over 20 MB" }, 413);
    const name = safeName(url.searchParams.get("name") ?? path ?? "file");
    if (uploadAgent(path) !== agent) path = `${UPLOADS}/${agent}/${Date.now()}-${randomBytes(3).toString("hex")}-${name}`;
    await storeFile(path, name, bytes);
    return json({ ok: true, path, name, size: bytes.length });
  }],
  // The app makes the upload folder first; the store needs none. Only an agent's own upload folder.
  ["POST", /^\/server\/files\/mkdir$/, async (req, _u, c) => {
    const b = await body(req);
    const rest = typeof b?.path === "string" && b.path.startsWith(`${UPLOADS}/`) ? b.path.slice(UPLOADS.length + 1) : "";
    const m = rest.match(/^([a-z0-9][a-z0-9-]{0,63})\/?$/);
    if (!m) return json({ error: "path outside allowed root" }, 403);
    return mayUse(c.dev, m[1]) ? json({ ok: true }) : json(NOT_YOUR_AGENT, 403);
  }],
  ["GET", /^\/server\/files\/download$/, (_r, url, c) => {
    const path = url.searchParams.get("path") ?? "";
    return fileAllowed(c.dev, path) ? serveFile(path, true) : json(NOT_YOUR_AGENT, 403);
  }],
  // The office chat is never end-to-end sealed (TLS covers the office network; the box is the only server).
  ["GET", /^\/server\/chat-e2e$/, () => json({ offered: false, kind: "self_host", enabled: false, box: null, devices: [], office: true })],
];

// Server: what the app shows about the box: a ready ("installed"), self-hosted
// server. Not chatOnly: on a chatOnly box the app skips its agent and Needs-you reads.
function healthNow() {
  let disk = { used: 0, total: 0 };
  try {
    const s = statfsSync("/");
    disk = { used: (s.blocks - s.bfree) * s.bsize, total: s.blocks * s.bsize };
  } catch {}
  return { disk, memory: { used: totalmem() - freemem(), total: totalmem() }, uptimeSeconds: Math.floor(uptime()) };
}
const serverRoutes: [string, RegExp, Handler][] = [
  ["GET", /^\/server\/status$/, (_r, url) => json({
    status: "installed", ip: null, domain: url.hostname, plan: "enterprise", selfHosted: true, chatOnly: false, office: true,
    offlineSince: null, downSince: null, statusMessage: null, createdAt: null, updatedAt: null,
  })],
  ["GET", /^\/server\/health$/, () => json(healthNow())],
];
// POST /server/agents/exec {args}: the app runs `5dive <args> --json` on its
// box and reads the CLI's {ok,data} envelope from stdout. The office answers a
// FIXED set of those reads (and one write, a Needs-you answer) through the root
// panel verbs; anything else is refused here, never run.
type Exec = { args: string[]; c: Ctx };
const envelope = (data: unknown) => json({ exit: 0, stdout: JSON.stringify({ ok: true, data }), stderr: "", timedOut: false });
const envFail = (message: string) => json({ exit: 1, stdout: JSON.stringify({ ok: false, error: { code: "office", message } }), stderr: "", timedOut: false });
const panel = async (c: Ctx, argv: string[]) => panelExec(argv, c.dev.id, "", 120_000);
async function board(c: Ctx): Promise<{ tasks: any[]; gates: any[] } | string> {
  const r = await panel(c, ["board"]);
  if (!r.ok) return r.error || "the board could not be read";
  // A member sees only the work of agents they may use.
  const mine = (t: any) => typeof t?.assignee === "string" && mayUse(c.dev, t.assignee);
  const all = c.me.role === "owner";
  return { tasks: (r.data?.tasks ?? []).filter((t: any) => all || mine(t)), gates: (r.data?.gates ?? []).filter((t: any) => all || mine(t)) };
}
const EXEC: { match: (a: string[]) => boolean; owner?: boolean; run: (e: Exec) => Promise<Response> | Response }[] = [
  { match: (a) => a[0] === "agent" && a[1] === "list", run: async ({ c }) => {
    const r = await panel(c, ["team"]);
    if (!r.ok) return envFail(r.error || "the team could not be read");
    return envelope((Array.isArray(r.data) ? r.data : []).filter((x: any) => typeof x?.name === "string" && mayUse(c.dev, x.name)));
  } },
  // Read beside the agent list; the office has no projects or org chart yet.
  { match: (a) => a[0] === "project" && (a[1] === "ls" || a[1] === "list"), run: () => envelope({ projects: [] }) },
  { match: (a) => a[0] === "org" && a[1] === "tree", run: () => envelope({ tree: [] }) },
  { match: (a) => a[0] === "task" && a[1] === "inbox", run: async ({ c }) => {
    const b = await board(c);
    return typeof b === "string" ? envFail(b) : envelope({ inbox: b.gates, needs_you: b.gates.length });
  } },
  { match: (a) => a[0] === "task" && (a[1] === "ls" || a[1] === "list"), run: async ({ c }) => {
    const b = await board(c);
    return typeof b === "string" ? envFail(b) : envelope({ tasks: b.tasks });
  } },
  // A Needs-you answer. Root checks it is one of the answers the gate offers.
  { match: (a) => a[0] === "task" && a[1] === "answer", run: async ({ args, c }) => {
    const ident = args[2] ?? "";
    const raw = args.slice(3).find((x) => x.startsWith("--value="))?.slice(8) ?? "";
    const value = ({ approved: "approve", denied: "reject" } as Record<string, string>)[raw] ?? raw;
    if (!/^[A-Z][A-Z0-9]{0,9}-[0-9]{1,7}$/.test(ident) || !value) return envFail("Answer this one from the office panel.");
    const b = await board(c);
    if (typeof b === "string") return envFail(b);
    if (!b.gates.some((g: any) => g.ident === ident)) return envFail(`${ident} is not waiting for your answer`);
    const r = await panel(c, ["gate-answer", ident, value]);
    return r.ok ? envelope(r.data) : envFail(r.error || "the answer was not taken");
  } },
  { match: (a) => a[0] === "account" && (a[1] === "list" || a[1] === "ls"), owner: true, run: async ({ c }) => {
    const r = await panel(c, ["settings"]);
    if (!r.ok) return envFail(r.error || "settings could not be read");
    return envelope((r.data?.accounts ?? []).map((x: any) => ({ name: x.name, types: x.harness ? [x.harness] : [], agents: [], signins: {}, model: x.model ?? null })));
  } },
  { match: (a) => a[0] === "secret" && a[1] === "saved" && a[2] === "ls", owner: true, run: async ({ c }) => {
    const r = await panel(c, ["secrets"]);
    return r.ok ? envelope({ names: Array.isArray(r.data) ? r.data : [] }) : envFail(r.error || "secrets could not be read");
  } },
  // Updates come by file (the panel's Update screen); there is no "latest" to compare offline.
  { match: (a) => a[0] === "update" && a[1] === "--check", owner: true, run: async ({ c }) => {
    const r = await panel(c, ["settings"]);
    return r.ok ? envelope({ current: r.data?.version ?? null, latest: null, behind: false }) : envFail(r.error || "settings could not be read");
  } },
];
const settingsRoutes: [string, RegExp, Handler][] = [
  ["POST", /^\/server\/agents\/exec$/, async (req, _u, c) => {
    const b = await body(req);
    const args = Array.isArray(b?.args) && b!.args.every((x: unknown) => typeof x === "string" && x.length <= 300) ? (b!.args as string[]).filter((x) => x !== "--json") : null;
    if (!args || !args.length || args.length > 12) return json({ error: "invalid args" }, 400);
    const hit = EXEC.find((x) => x.match(args));
    if (!hit) return json({ error: "This is not available on the office server.", reason: "office_not_answered" }, 404);
    if (hit.owner && c.me.role !== "owner") return ownerOnly();
    return hit.run({ args, c });
  }],
];

const OFFICE_ROUTES: [string, RegExp, Handler][] = [...teamRoutes, ...chatRoutes, ...serverRoutes, ...settingsRoutes];
// The one door: /api/proxy/<path>. Writes must come from this origin (the app
// is served here; the cookie is SameSite=Strict too). Signed out, only the
// join link's accept answers.
async function officeProxy(req: Request, url: URL): Promise<Response> {
  const path = url.pathname.slice("/api/proxy".length) || "/";
  const m = req.method;
  if (m !== "GET" && m !== "HEAD") {
    const origin = req.headers.get("origin");
    if (req.headers.get("x-local-chat") !== "1" && origin !== url.origin) return json({ error: "forbidden" }, 403);
    if (m === "POST" || m === "PUT") {
      const len = Number(req.headers.get("content-length") ?? NaN);
      if (!Number.isFinite(len)) return json({ error: "length required" }, 411);
      if (len > FILE_MAX + 1024) return json({ error: "That is too big to send here." }, 413);
    }
  }
  if (m === "POST" && path === "/team/accept") {
    if (pairThrottled()) return json({ error: "too many tries, wait a minute" }, 429);
    const b = await body(req);
    const token = typeof b?.token === "string" && /^[A-Za-z0-9_-]{43}$/.test(b.token) ? b.token : "";
    const row = codeRow(token);
    const got = row && admitDevice(row, "");
    if (!got) return json({ error: "invalid_link", reason: "That invite link is used or expired. Ask for a new one." }, 404);
    return json({ ok: true, id: got.person, role: got.role }, 200, { "set-cookie": sessionCookie(got.cookie) });
  }
  const hit = OFFICE_ROUTES.map(([verb, re, h]) => [verb, path.match(re), h] as const).filter(([, mm]) => mm);
  if (!hit.length) return json({ error: "not found", reason: "office_not_answered" }, 404);
  const route = hit.find(([verb]) => verb === m || (m === "HEAD" && verb === "GET"));
  if (!route) return json({ error: "method not allowed" }, 405);
  const dev = deviceOf(req);
  if (!dev) return json({ error: "unauthorized", reason: "signed_out" }, 401);
  const me = { id: dev.person, name: dev.personName, role: dev.personRole, created: 0 };
  return route[2](req, url, { dev, me }, route[1]!);
}
OFFICE_API_TS
}
