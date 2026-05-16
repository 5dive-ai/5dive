#!/usr/bin/env bun
// Local API server — wraps the 5dive CLI for the dashboard UI.
// Run: bun run server.ts  (or 5dive ui)
// In production (after `bun run build`), also serves the static frontend.

import { spawn } from "child_process";
import { existsSync } from "fs";
import { join } from "path";
import { loadConfig } from "./lib/config";

// Resolve bind + auth. Precedence: CLI flags / env > config file > defaults.
// `5dive ui` plumbs --host / --port into HOST / PORT env vars (empty string
// when unset, so we fall through to config).
const config = loadConfig();
const PORT = parseInt(process.env.PORT || String(config.bind.port));
const HOST = process.env.HOST || config.bind.host;
const CLI = process.env.FIVE_CLI ?? "5dive";
const DIST = join(import.meta.dir, "dist");
const SERVE_STATIC = existsSync(DIST);

async function runCLI(...args: string[]): Promise<{ ok: boolean; data?: unknown; error?: string }> {
  return new Promise((resolve) => {
    const proc = spawn(CLI, [...args, "--json"], { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (d: Buffer) => (stdout += d.toString()));
    proc.stderr.on("data", (d: Buffer) => (stderr += d.toString()));
    proc.on("close", (code) => {
      try {
        const parsed = JSON.parse(stdout.trim());
        resolve(parsed);
      } catch {
        resolve({ ok: false, error: stderr.trim() || `exit ${code}` });
      }
    });
  });
}

async function runCLIStream(args: string[], onLine: (line: string) => void): Promise<void> {
  return new Promise((resolve) => {
    const proc = spawn(CLI, args, { stdio: ["ignore", "pipe", "pipe"] });
    let buf = "";
    proc.stdout.on("data", (d: Buffer) => {
      buf += d.toString();
      const lines = buf.split("\n");
      buf = lines.pop() ?? "";
      lines.forEach(onLine);
    });
    proc.stderr.on("data", (d: Buffer) => {
      buf += d.toString();
      const lines = buf.split("\n");
      buf = lines.pop() ?? "";
      lines.forEach(onLine);
    });
    proc.on("close", () => {
      if (buf) onLine(buf);
      resolve();
    });
  });
}

// Reject cross-origin requests. The UI talks to its own server (same-origin
// in production, Vite proxies in dev), so any browser request carrying an
// Origin that doesn't match Host is either CSRF or misconfigured — refuse
// both. Non-browser callers (curl, server-side fetch) typically omit Origin
// and pass through. There is intentionally no Access-Control-Allow-Origin
// header: the API is not cross-origin-callable.
function originAllowed(req: Request): boolean {
  const origin = req.headers.get("origin");
  if (!origin) return true; // non-browser / same-origin without explicit header
  const host = req.headers.get("host");
  if (!host) return false;
  try {
    return new URL(origin).host === host;
  } catch {
    return false;
  }
}

const server = Bun.serve({
  port: PORT,
  hostname: HOST,
  async fetch(req) {
    const url = new URL(req.url);
    const path = url.pathname;

    const headers = { "Content-Type": "application/json" };

    if (!originAllowed(req)) {
      return new Response(
        JSON.stringify({ ok: false, error: "cross-origin request refused" }),
        { status: 403, headers },
      );
    }

    // OPTIONS handler kept for the rare case a same-origin client preflights;
    // no CORS headers needed since we only ever respond to same-origin.
    if (req.method === "OPTIONS") return new Response(null, { headers });

    // GET /api/agents
    if (req.method === "GET" && path === "/api/agents") {
      const result = await runCLI("agent", "list");
      return Response.json(result, { headers });
    }

    // GET /api/doctor
    if (req.method === "GET" && path === "/api/doctor") {
      const result = await runCLI("doctor");
      return Response.json(result, { headers });
    }

    // POST /api/doctor/repair
    if (req.method === "POST" && path === "/api/doctor/repair") {
      const result = await runCLI("doctor", "--repair");
      return Response.json(result, { headers });
    }

    // GET /api/accounts
    if (req.method === "GET" && path === "/api/accounts") {
      const result = await runCLI("account", "list");
      return Response.json(result, { headers });
    }

    // POST /api/accounts  { name }
    if (req.method === "POST" && path === "/api/accounts") {
      const body = await req.json() as { name: string };
      const result = await runCLI("account", "add", body.name);
      return Response.json(result, { headers });
    }

    const accountMatch = path.match(/^\/api\/accounts\/([^/]+)$/);
    if (accountMatch) {
      const name = decodeURIComponent(accountMatch[1]);
      if (req.method === "GET") {
        const result = await runCLI("account", "show", name);
        return Response.json(result, { headers });
      }
      if (req.method === "DELETE") {
        const result = await runCLI("account", "remove", name);
        return Response.json(result, { headers });
      }
      if (req.method === "PATCH") {
        const body = await req.json() as { name: string };
        const result = await runCLI("account", "rename", name, body.name);
        return Response.json(result, { headers });
      }
    }

    // GET /api/auth/:type  — check auth status
    const authMatch = path.match(/^\/api\/auth\/([^/]+)$/);
    if (authMatch) {
      const type = authMatch[1];
      if (req.method === "GET") {
        const result = await runCLI("agent", "auth", "status", type);
        return Response.json(result, { headers });
      }
      // POST /api/auth/:type  { apiKey, provider? }  — set API key via stdin
      if (req.method === "POST") {
        const body = await req.json() as { apiKey: string; provider?: string };
        const authArgs = ["agent", "auth", "set", type, "--api-key=-", "--json"];
        if (body.provider) authArgs.push(`--provider=${body.provider}`);
        const result = await new Promise<{ ok: boolean; data?: unknown; error?: string }>((resolve) => {
          const proc = spawn(CLI, authArgs, {
            stdio: ["pipe", "pipe", "pipe"],
          });
          let stdout = "";
          let stderr = "";
          proc.stdout.on("data", (d: Buffer) => (stdout += d.toString()));
          proc.stderr.on("data", (d: Buffer) => (stderr += d.toString()));
          proc.on("close", (code) => {
            try { resolve(JSON.parse(stdout.trim())); }
            catch { resolve({ ok: false, error: stderr.trim() || `exit ${code}` }); }
          });
          proc.stdin.write(body.apiKey);
          proc.stdin.end();
        });
        return Response.json(result, { headers });
      }
    }

    // POST /api/auth/:type/start  — start OAuth device-code flow
    // GET  /api/auth/:type/poll/:sessionId  — poll for URL / completion
    const authFlowMatch = path.match(/^\/api\/auth\/([^/]+)\/(start|poll(?:\/([^/]+))?)$/);
    if (authFlowMatch) {
      const type = authFlowMatch[1];
      const action = authFlowMatch[2].startsWith("poll") ? "poll" : "start";
      const sessionId = authFlowMatch[3];

      if (req.method === "POST" && action === "start") {
        const result = await runCLI("agent", "auth", "start", type);
        return Response.json(result, { headers });
      }
      if (req.method === "GET" && action === "poll" && sessionId) {
        const result = await runCLI("agent", "auth", "poll", sessionId);
        return Response.json(result, { headers });
      }
    }

    // POST /api/agent/install/:type
    const installMatch = path.match(/^\/api\/agent\/install\/([^/]+)$/);
    if (installMatch && req.method === "POST") {
      const type = installMatch[1];
      const result = await runCLI("agent", "install", type);
      return Response.json(result, { headers });
    }

    // POST /api/agents  (create)
    if (req.method === "POST" && path === "/api/agents") {
      const body = await req.json() as Record<string, string>;
      const args = ["agent", "create", body.name, `--type=${body.type}`];
      if (body.isolation) args.push(`--isolation=${body.isolation}`);
      if (body.channels) args.push(`--channels=${body.channels}`);
      if (body.telegramToken) args.push(`--telegram-token=${body.telegramToken}`);
      if (body.workdir) args.push(`--workdir=${body.workdir}`);
      if (body.authProfile) args.push(`--auth-profile=${body.authProfile}`);
      if (body.deferAuth === "true") args.push("--defer-auth");
      const result = await runCLI(...args);
      return Response.json(result, { headers });
    }

    const nameMatch = path.match(/^\/api\/agents\/([^/]+)(?:\/(.+))?$/);
    if (nameMatch) {
      const name = decodeURIComponent(nameMatch[1]);
      const action = nameMatch[2];

      // DELETE /api/agents/:name
      if (req.method === "DELETE" && !action) {
        const result = await runCLI("agent", "rm", name);
        return Response.json(result, { headers });
      }

      // POST /api/agents/:name/start|stop|restart
      if (req.method === "POST" && (action === "start" || action === "stop" || action === "restart")) {
        const result = await runCLI("agent", action, name);
        return Response.json(result, { headers });
      }

      // GET /api/agents/:name/stats
      if (req.method === "GET" && action === "stats") {
        const result = await runCLI("agent", "stats", name);
        return Response.json(result, { headers });
      }

      // POST /api/agents/:name/send
      if (req.method === "POST" && action === "send") {
        const body = await req.json() as { text: string };
        const result = await runCLI("agent", "send", name, body.text);
        return Response.json(result, { headers });
      }

      // POST /api/agents/:name/config  { key, value }
      if (req.method === "POST" && action === "config") {
        const body = await req.json() as { key: string; value: string };
        const result = await runCLI("agent", "config", name, "set", `${body.key}=${body.value}`);
        return Response.json(result, { headers });
      }

      // POST /api/agents/:name/clone  { newName, channels?, telegramToken?, workdir? }
      if (req.method === "POST" && action === "clone") {
        const body = await req.json() as Record<string, string>;
        const args = ["agent", "clone", name, body.newName];
        if (body.channels) args.push(`--channels=${body.channels}`);
        if (body.telegramToken) args.push(`--telegram-token=${body.telegramToken}`);
        if (body.workdir) args.push(`--workdir=${body.workdir}`);
        const result = await runCLI(...args);
        return Response.json(result, { headers });
      }

      // POST /api/agents/:name/ask  { text, timeout? }
      if (req.method === "POST" && action === "ask") {
        const body = await req.json() as { text: string; timeout?: number };
        const args = ["agent", "ask", name, body.text];
        if (body.timeout) args.push(`--timeout=${body.timeout}`);
        const result = await runCLI(...args);
        return Response.json(result, { headers });
      }

      // GET /api/agents/:name/telegram-access
      if (req.method === "GET" && action === "telegram-access") {
        const result = await runCLI("agent", "telegram-access", "get", name);
        return Response.json(result, { headers });
      }

      // POST /api/agents/:name/telegram-access  (body is the access JSON)
      if (req.method === "POST" && action === "telegram-access") {
        const body = await req.json();
        const result = await new Promise<{ ok: boolean; data?: unknown; error?: string }>((resolve) => {
          const proc = spawn(CLI, ["agent", "telegram-access", "set", name, "--json"], {
            stdio: ["pipe", "pipe", "pipe"],
          });
          let stdout = "";
          let stderr = "";
          proc.stdout.on("data", (d: Buffer) => (stdout += d.toString()));
          proc.stderr.on("data", (d: Buffer) => (stderr += d.toString()));
          proc.on("close", (code) => {
            try { resolve(JSON.parse(stdout.trim())); }
            catch { resolve({ ok: false, error: stderr.trim() || `exit ${code}` }); }
          });
          proc.stdin.write(JSON.stringify(body));
          proc.stdin.end();
        });
        return Response.json(result, { headers });
      }

      // GET /api/agents/:name/logs  (SSE stream)
      if (req.method === "GET" && action === "logs") {
        const lines = parseInt(url.searchParams.get("lines") ?? "100");
        const encoder = new TextEncoder();
        const stream = new ReadableStream({
          async start(controller) {
            await runCLIStream(["agent", "logs", name, `--lines=${lines}`], (line) => {
              controller.enqueue(encoder.encode(`data: ${JSON.stringify(line)}\n\n`));
            });
            controller.enqueue(encoder.encode("data: [EOF]\n\n"));
            controller.close();
          },
        });
        return new Response(stream, {
          headers: {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
          },
        });
      }
    }

    // Serve static frontend in production
    if (SERVE_STATIC) {
      let filePath = join(DIST, url.pathname === "/" ? "index.html" : url.pathname);
      if (!existsSync(filePath)) filePath = join(DIST, "index.html"); // SPA fallback
      const file = Bun.file(filePath);
      return new Response(file);
    }

    return new Response(JSON.stringify({ ok: false, error: "not found" }), { status: 404, headers });
  },
});

// Display "localhost" for the loopback bind so the printed URL is clickable in
// every terminal; print the actual host otherwise so users know what they
// exposed.
const displayHost = HOST === "127.0.0.1" || HOST === "::1" ? "localhost" : HOST;
console.log(`5dive UI at http://${displayHost}:${PORT}${SERVE_STATIC ? "" : " (API only — run `bun run build` for full UI)"}`);
if (HOST !== "127.0.0.1" && HOST !== "::1") {
  console.warn(`⚠  bound to ${HOST} — UI has no auth yet, anyone with network access can spawn agents on this host.`);
  console.warn(`   set up auth: 5dive ui setup     (or bind loopback: HOST=127.0.0.1 ${process.argv[1]})`);
}
