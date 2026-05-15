# 5dive UI

Lightweight local dashboard for the 5dive CLI. Runs entirely on your machine — no cloud required.

## Quick start

```sh
# From the repo root
cd ui
bun install
bun run dev
```

Then open http://localhost:5174

## Or via the CLI

Once the UI is installed at `/usr/local/lib/5dive/ui`:

```sh
5dive ui
# → opens http://localhost:5175
```

## Architecture

- **`server.ts`** — Bun HTTP server that wraps `5dive` CLI commands as JSON API endpoints
- **`src/`** — React + Vite + Tailwind frontend

The server runs at port `5175` by default; Vite dev server proxies `/api/*` to it.

## API endpoints

| Method | Path | CLI equivalent |
|--------|------|----------------|
| `GET` | `/api/agents` | `5dive agent list` |
| `POST` | `/api/agents` | `5dive agent create` |
| `DELETE` | `/api/agents/:name` | `5dive agent rm` |
| `POST` | `/api/agents/:name/start` | `5dive agent start` |
| `POST` | `/api/agents/:name/stop` | `5dive agent stop` |
| `POST` | `/api/agents/:name/restart` | `5dive agent restart` |
| `GET` | `/api/agents/:name/stats` | `5dive agent stats` |
| `POST` | `/api/agents/:name/send` | `5dive agent send` |
| `GET` | `/api/agents/:name/logs` | `5dive agent logs` (SSE) |
| `GET` | `/api/doctor` | `5dive doctor` |
