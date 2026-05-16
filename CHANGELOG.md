# Changelog

All notable changes to `5dive-cli` are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [SemVer](https://semver.org/spec/v2.0.0.html).

Unreleased changes accumulate at the top until they're cut into a tagged
release.

## [Unreleased]

### Added

- `5dive-cli` agent skill is now shipped with the install. Lives at
  `/usr/local/lib/5dive/skills/5dive-cli/` (SKILL.md + references/).
  Teaches a Claude Code / Codex / Gemini agent how to drive `5dive` —
  spawn agents, inter-agent comms, doctor, account management.
- README — split the "have your agent install it" section into two
  copy-paste prompts: (a) same-machine install, (b) laptop-agent
  installs onto a remote VM over SSH. Both now also instruct the agent
  to drop the `5dive-cli` skill into its own `~/.claude/skills/` so the
  user can keep managing agents through that same agent — no manual
  CLI dance after the install.

## [0.1.1] — 2026-05-16

### Fixed

- `install.sh` now installs `unzip`. The bun installer (`curl … | bash`)
  requires it, and on a clean ubuntu:22.04 it isn't preinstalled — the
  one-liner install was failing silently mid-script. Caught by the new
  install-smoke CI job on its first run.

### Added

- README — copy-paste prompt block for users who'd rather have their
  existing AI agent run the install (instead of pasting the curl line
  themselves).

## [0.1.0] — 2026-05-16

First public release.

### CLI

- `5dive agent` — create, list, send to, ask, watch, stop, delete agents.
- `5dive auth` — set / login / status / clear, with profile sharing across
  agents via `5dive account`.
- `5dive skill` — install + remove agent skills (incl. the bundled
  `notify-user` skill).
- `5dive compose` — declare an agent team in a YAML file and stand it up.
- `5dive doctor` — health check across systemd units, agent state, and
  per-type install status.
- `5dive init` — interactive first-run wizard for picking agent types,
  channels, and registering an initial agent.
- `5dive watch` — follow agent activity in the terminal.
- `5dive uninstall` (and `install.sh --uninstall`) — clean removal.
- `5dive --version` / `-v` sourced from a single `FIVE_VERSION` constant.
- Agent-to-agent messaging: every agent can `send` / `ask` any other agent
  on the same host.

### Dashboard (`5dive ui`)

- Local dashboard at `127.0.0.1:5175` by default; Vite + React + HeroUI v3
  on Tailwind v4.
- Full CLI surface coverage: agents (create wizard, clone, watch, logs),
  accounts, skills, health, config, Telegram pairing, agent-to-agent Ask
  panel.
- `5dive ui setup` — argon2id password auth + HMAC-signed session cookies.
- Server refuses public bind without auth (`--insecure` to override, with
  a 60s-loud warning log).
- CORS locked down to same-origin.
- Mobile layout polish, brand SVG icons for agent types and channels.
- Empty-state CTA + auto-select after creating an agent.

### Installer

- One-liner installer (`curl install.5dive.com | sudo bash`).
- Sets up nvm + Node + Bun for the dashboard.
- Idempotent: re-running won't touch your registry, auth profiles, or
  agents.
- `install.sh --upgrade` — refresh CLI binaries, systemd unit, and hooks
  only (skips apt/nvm/bun).
- Runs `5dive doctor` automatically after install.

### Telegram

- Stop hook auto-relays missed replies for telegram-paired agents.
- `notify-user` skill for sending progress updates from agents.
- Dashboard "Pair" tab with auto-discover and access policy controls.

### Docker

- Demo container under `docker/` for tire-kickers — runs without needing
  systemd or root on the host.

### Docs

- README — quickstart, auth model, agent-to-agent example, securing-your-server,
  telemetry policy, reverse-proxy recipe.
- `ui/README.md` — UI auth model, Caddy + Nginx recipes, OIDC/SSO via
  forward-auth (Authelia / Authentik / oauth2-proxy).
- Offline / air-gapped install recipe.
- Pointer for non-systemd / non-root users at the Docker path.
- SECURITY.md — private vulnerability reporting via GitHub advisories.
- CONTRIBUTING.md — dev setup, scope guardrails, bundle rule, PR expectations.
- Issue + PR templates.

### CI

- `bundle-drift` workflow — fails any push where the committed `5dive`
  bundle disagrees with `./build.sh` output from `src/`.

[Unreleased]: https://github.com/5dive-com/5dive-cli/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/5dive-com/5dive-cli/releases/tag/v0.1.1
[0.1.0]: https://github.com/5dive-com/5dive-cli/releases/tag/v0.1.0
