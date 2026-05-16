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
# → opens http://localhost:5175 (loopback only by default)
```

Flags:

```sh
5dive ui --port=8080              # change port
5dive ui --host=0.0.0.0           # bind all interfaces (requires auth, see below)
5dive ui --host=0.0.0.0 --insecure # bind public without auth (DON'T)
5dive ui setup                    # configure a password (interactive)
```

## Authentication

By default the dashboard runs on `127.0.0.1` and has no auth — anyone on
your machine can use it. The moment you bind a non-loopback address the
server refuses to start unless you've set up a password.

### Set up a password

```sh
5dive ui setup
```

Walks you through an interactive prompt and writes `~/.config/5dive/ui.json`
(mode `0600`) containing an argon2id hash of your password and a random
session-signing secret. Idempotent — rerun to rotate the password.

Once set, the SPA shows a sign-in screen on load. Successful login issues
an `HttpOnly; SameSite=Strict` cookie valid for 7 days.

### Disable auth again

Edit `~/.config/5dive/ui.json` and set `"auth": { "mode": "none" }`. Or just
delete the file — the server falls back to no-auth defaults.

## Exposing the UI publicly

For LAN-only access on a trusted network you can run `5dive ui --host=0.0.0.0`
after `5dive ui setup`, but that puts a plain-HTTP login form on the wire.
For anything beyond a private LAN, **always front the UI with a reverse proxy
that terminates TLS**.

### Caddy (recommended — auto-HTTPS via Let's Encrypt)

```caddyfile
dashboard.example.com {
    reverse_proxy 127.0.0.1:5175 {
        header_up X-Forwarded-Proto {scheme}
    }
}
```

`X-Forwarded-Proto` matters: the server reads it to set the `Secure` cookie
flag when the original request came in over HTTPS.

Run `5dive ui` bound to `127.0.0.1` (the default) — Caddy handles the public
side. With this setup the API stays loopback-only and only Caddy can reach it.

### Nginx

```nginx
server {
    listen 443 ssl http2;
    server_name dashboard.example.com;

    ssl_certificate /etc/letsencrypt/live/dashboard.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/dashboard.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:5175;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Required for SSE log streaming
        proxy_buffering off;
        proxy_read_timeout 24h;
    }
}
```

### What `--insecure` is for

`--host=0.0.0.0 --insecure` lets you bind a public address without auth. The
server logs a loud warning every 60s while it runs. **This is only ever the
right answer if** (a) you're on a trusted LAN and (b) you understand that
anyone on that LAN can spawn agents that execute shell commands on your host.

### Roadmap

OIDC / SSO (Authelia, Authentik, etc.) is on the day-2 list. The current
single-password model is intentionally simple for v1.

## Architecture

- **`server.ts`** — Bun HTTP server that wraps `5dive` CLI commands as JSON API endpoints. Also serves the built SPA from `dist/` in production.
- **`src/`** — React + Vite + Tailwind frontend.
- **`lib/config.ts`** — reads/writes `~/.config/5dive/ui.json`.
- **`lib/auth.ts`** — HMAC-signed session cookie helpers.
- **`setup.ts`** — `5dive ui setup` entry point.

The server runs at `127.0.0.1:5175` by default; the Vite dev server proxies `/api/*` to it.

## API endpoints

Auth surface (always public):

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/auth-status` | `{ mode, configured, authenticated }` — drives the SPA's setup/login/dashboard routing |
| `POST` | `/api/setup` | One-shot: set a password from the browser (refuses once `passwordHash` is configured) |
| `POST` | `/api/login` | `{ password }` → session cookie |
| `POST` | `/api/logout` | clears the session cookie |

Everything below requires a valid session when `auth.mode = password`:

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
| `POST` | `/api/agents/:name/ask` | `5dive agent ask` |
| `POST` | `/api/agents/:name/clone` | `5dive agent clone` |
| `POST` | `/api/agents/:name/config` | `5dive agent config set` |
| `GET` | `/api/agents/:name/logs` | `5dive agent logs` (SSE) |
| `GET` | `/api/agents/:name/telegram-access` | `5dive agent telegram-access get` |
| `POST` | `/api/agents/:name/telegram-access` | `5dive agent telegram-access set` |
| `GET` | `/api/accounts` | `5dive account list` |
| `POST` | `/api/accounts` | `5dive account add` |
| `GET` | `/api/accounts/:name` | `5dive account show` |
| `DELETE` | `/api/accounts/:name` | `5dive account remove` |
| `PATCH` | `/api/accounts/:name` | `5dive account rename` |
| `GET` | `/api/auth/:type` | `5dive agent auth status` |
| `POST` | `/api/auth/:type` | `5dive agent auth set` |
| `POST` | `/api/auth/:type/start` | `5dive agent auth start` |
| `GET` | `/api/auth/:type/poll/:session` | `5dive agent auth poll` |
| `POST` | `/api/agent/install/:type` | `5dive agent install` |
| `GET` | `/api/doctor` | `5dive doctor` |
| `POST` | `/api/doctor/repair` | `5dive doctor --repair` |

## CORS / cross-origin

The API is **same-origin only**. There are no `Access-Control-Allow-*`
headers, and any request whose `Origin` doesn't match `Host` is rejected
with 403. The SPA is served by the same server in production, and Vite
proxies `/api/*` in dev — so cross-origin is never the right path. If
you need to consume the API from another origin, use a reverse proxy.
