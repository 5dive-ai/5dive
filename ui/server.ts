#!/usr/bin/env bun
// Local API server — wraps the 5dive CLI for the dashboard UI.
// Run: bun run server.ts  (or 5dive ui)
// In production (after `bun run build`), also serves the static frontend.

import { spawn } from "child_process";
import { existsSync } from "fs";
import { join } from "path";

const PORT = parseInt(process.env.PORT ?? "5175");
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

const server = Bun.serve({
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);
    const path = url.pathname;

    // CORS for local dev
    const headers = {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET,POST,DELETE,OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    };
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

    // POST /api/agents  (create)
    if (req.method === "POST" && path === "/api/agents") {
      const body = await req.json() as Record<string, string>;
      const args = ["agent", "create", body.name, `--type=${body.type}`];
      if (body.isolation) args.push(`--isolation=${body.isolation}`);
      if (body.channels) args.push(`--channels=${body.channels}`);
      if (body.telegramToken) args.push(`--telegram-token=${body.telegramToken}`);
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
            "Access-Control-Allow-Origin": "*",
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

console.log(`5dive UI at http://localhost:${PORT}${SERVE_STATIC ? "" : " (API only — run `bun run build` for full UI)"}`);
if (SERVE_STATIC) console.log(`  open http://localhost:${PORT}`);
