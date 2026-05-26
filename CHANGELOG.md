# Changelog

All notable changes to `5dive` are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [SemVer](https://semver.org/spec/v2.0.0.html).

Unreleased changes accumulate at the top until they're cut into a tagged
release.

## [Unreleased]

### Added

- `5dive doctor` gained a `channels` category that verifies
  `/etc/claude-code/managed-settings.json` carries `channelsEnabled: true`
  + a `telegram@5dive-plugins` entry, and reads each agent's latest
  telegram-plugin MCP log to confirm whether claude's channel
  subscription is `registered` vs `skipped`. A `skipped` result is
  flagged as a likely Anthropic Teams org override and points the
  operator at the README setup snippet.
- `5dive init` prints a Teams-org heads-up after the Telegram pairing
  step pointing at `sudo 5dive doctor --category=channels` and the
  Anthropic Console setup snippet.

## [0.1.6] — 2026-05-25

### Changed

- `preseed_claude_agent` no longer wires the standalone StopFailure hook
  (`/usr/local/lib/5dive/stop-failure-telegram.sh`) into new fork
  (`telegram@5dive-plugins`) agents' `settings.json`. Plugin v0.4.4
  bundles the same hook via `hooks.json`, so preseeding the standalone
  copy would double-fire on every rate-limit (two DMs, two
  `resume-after-reset.sh` forks both pressing "1" on claude's
  Stop-and-wait menu). The standalone file stays installed by
  `scripts/install/agent-cli.sh` + `scripts/update.sh` for backward
  compatibility — agents on upstream `telegram@claude-plugins-official`
  still reference it. New upstream agents are unaffected by this
  change (channels=telegram defaults to the fork anyway since v0.1.5).

### Notes

- Companion change in `5dive-api/scripts/update.sh` strips the
  standalone StopFailure entry from existing fork agents' settings.json
  on the next 03:00 UTC customer-VM update cron — same shape as the
  existing `on_upstream_telegram()`-gated backfills, just inverted.

### Changed

- New `telegram` agents now preseed on the `telegram@5dive-plugins` fork
  instead of upstream `claude-plugins-official`. The fork bundles
  PreToolUse / Stop / PostToolUse hooks via `hooks.json` and ships
  richer slash commands (`/model`, `/effort`, `/agents`, `/status`,
  silence-watchdog). `agent_setup.sh` preseeds
  `enabledPlugins → telegram@5dive-plugins`, adds the fork repo to
  `extraKnownMarketplaces` alongside upstream, drops the duplicate
  hook entries (plugin owns them now), and writes
  `AGENT_CHANNEL_MARKETPLACE=5dive-plugins` into the agent env file so
  `5dive-agent-start` builds the right `--channels` arg.
  `install.sh` now also writes `/etc/claude-code/managed-settings.json`
  on first install so the channel-plugin allowlist permits both
  marketplaces (idempotent — preserves an operator-customized file).
  Existing telegram agents are unaffected; they stay on upstream until
  a 5dive-api `update.sh` pass migrates them.

### Fixed

- `stop-failure-telegram` now parses the rate-limit reset time from
  the StopFailure transcript instead of scraping the tmux pane.
  When claude shows the "Stop and wait" menu the pane switches to
  the alt screen and the "resets Xpm (TZ)" line is no longer visible
  to `tmux capture-pane`, so the fallback DM "Usage limit hit —
  waiting for reset." fired without the time-left tail and the
  resume-after-reset helper got no epoch. Transcript parse reads the
  structured rate-limit message claude logs
  (`isApiErrorMessage=true`, text containing "resets Xpm (TZ)") —
  authoritative and immune to tmux screen state. Pane scrape kept as
  last resort. Supersedes the 0.5s pre-capture sleep workaround.
- Plugin install pins the explicit `https://` URL for the marketplace
  `add` step. `claude plugin marketplace add owner/repo` resolves the
  GitHub shorthand to `git@github.com:owner/repo` (SSH) on some
  claude versions, which fails for `agent-<name>` users on customer
  VMs with no SSH key (`ERR_STREAM_PREMATURE_CLOSE` during clone).
  Affects both the new-agent install path and `update.sh` migration.

## [0.1.4] — 2026-05-23

### Fixed

- `antigravity` auth sentinel path. The scaffold's first ship guessed
  `~/.gemini/antigravity-cli/credentials.json` but agy 1.0.1 actually
  writes the token blob at `~/.gemini/antigravity-cli/antigravity-oauth-token`
  (no `.json` extension). The cmd_auth_poll mtime-check never noticed the
  successful OAuth landing and reported `error: antigravity exited without
  writing ...`. Confirmed empirically via the live-VM pair-test. Patches
  TYPE_AUTH + profile_type_auth_path + the comment block in cmd_auth_poll.
- Usage-limit Telegram pings narrowed to the calling chat. When an agent
  is paired with multiple chats (personal DM + team group), hitting the
  Claude usage limit was fanning the "Usage limit hit — resumes in …"
  alert (and its later "agent resumed" follow-up) to every chat in
  `access.json`. `stop-failure-telegram.sh` now scans the StopFailure
  payload's transcript for the most-recent telegram inbound and pings
  only that chat — same idiom `stop-telegram-reply-check.sh` already
  uses. Falls back to the full access.json list when no inbound is
  found (autonomous/cron-triggered sessions) so the alert isn't
  silenced.

### Added

- `grok` agent type. xAI's CLI. Binary lands at `~/.local/bin/grok`
  (symlinked from `~/.grok/bin/grok`); state under `~/.grok/`. OAuth uses
  the xAI device-auth flow (`grok login --device-auth` → URL
  `accounts.x.ai/oauth2/device` + a 4-dash-4 user code like `XJ9P-ZW8T`;
  CLI polls the endpoint itself and writes `~/.grok/auth.json`). Same UX
  shape as codex's device-auth — no callback paste. Also supports BYO API
  key via `XAI_API_KEY`. Run flag: `--permission-mode bypassPermissions`.
  Installer drops a competing `agent` symlink alongside `grok`; the
  TYPE_INSTALL recipe removes it post-install so future tooling isn't
  shadowed.

- `antigravity` agent type. Google's native-Go successor to gemini-cli.
  Installer lands `agy` at `~/.local/bin/agy` (no Node/nvm dependency).
  Run flag: `--dangerously-skip-permissions` (mirrors the claude family
  default). OAuth uses Google's consumer flow with redirect to
  `antigravity.google/oauth-callback` — UX is identical to the deleted
  gemini flow (URL displayed, waits 30s for either an OAuth callback OR
  a pasted authorization code). Wired into the device-code flow alongside
  claude/codex/hermes/openclaw. State dir is `~/.gemini/antigravity-cli/`
  — the binary identifies as `product=antigravity` but reuses Google's
  `~/.gemini` parent directory.

### Removed

- `gemini` agent type. Google's Gemini CLI is being sunsetted by Google in
  favor of Antigravity. Drops the `[gemini]` entries from all `TYPE_*` and
  `SKILLS_*` lookup tables, the `gemini` branch in the init wizard,
  `extract_gemini_url`, the gemini paperclip-seed case, the
  `GEMINI_SANDBOX` / `GEMINI_CLI_TRUST_WORKSPACE` overrides in the
  paperclipai drop-in, and the `gemini.env` connector path. Hermes /
  openclaw routing to Google's Gemini-2.0-flash model via a BYO API key
  is unchanged — that's a model id in Google's provider catalog, not a
  5dive agent type.

## [0.1.3] — 2026-05-22

### Changed

- Inter-agent group mirror moved to the sender side. `5dive agent send`
  (and `agent ask`) now posts `@<receiver>\n<body>` to the **sender's**
  group via the **sender's** bot, so both halves of an exchange show up
  under the correct identity. The previous receiver-side hooks
  (`userprompt-mirror-inter-agent.sh`, `stop-mirror-inter-agent.sh`) are
  retired as no-ops — they posted via the receiver's bot, so
  `marketing → main` showed up under `main`'s identity, and the reply
  hook double-posted (once as the payload, once as transcript
  narration). Files stay on disk so existing agents' `settings.json`
  don't error; new agents wire only the sender-side path.
- `stop-telegram-reply-check.sh` now decides at the **turn level**, not
  per text block. If the agent called `reply` or `edit_message` anywhere
  in the turn, all auto-relay is suppressed — every loose transcript
  block (preamble, progress, end-of-turn summary) is narration, not a
  missed answer. Eliminates the trailing `(auto-relay) ...` duplicates
  that landed in the user's DM right after the real reply.
- StopFailure Telegram alerts include the upstream API error string
  (e.g. "API Error: 529 Overloaded") pulled from the claude pane
  capture, instead of just naming the high-level `server_error` reason.
- Per-agent Telegram guidance moved out of the shared
  `projects-CLAUDE.md`. Telegram-paired claude agents now get a
  dedicated `telegram-agent-CLAUDE.md` dropped at
  `$HOME/.claude/CLAUDE.md` during agent setup, alongside the
  `notify-user` skill. Non-Telegram agents (codex on single-agent hosts,
  for instance) no longer carry the reply mandate or the bot
  references that didn't apply to them. `projects-CLAUDE.md` is trimmed
  to host-wide invariants only.
- Both `projects-CLAUDE.md` and `telegram-agent-CLAUDE.md` tightened —
  smaller token footprint on every agent's session prompt.

### Removed

- `posttool-telegram-relay.sh` retired as a no-op. The mid-turn relay's
  premise (loose mid-turn text = message the user should see) was
  wrong; preambles and progress narration are transcript text too and
  were getting curled to the user as noise. The legitimate "talked to
  the transcript instead of replying" miss is now caught by the
  turn-level Stop hook above.
- `SECURITY.md` removed. Security-reporting instructions inlined into
  the README, with `CONTRIBUTING.md` pointing at GitHub's private
  advisory page directly. Removes the "Security" community pill so the
  README/Contributing/License row stops overflowing on mobile.

### Fixed

- `install-smoke` CI workflow now ships `telegram-agent-CLAUDE.md` in
  the bundle. Without this, `install.sh`'s new curl for that file hit
  a missing source and bailed (curl exit 37).

### Documentation

- README: "How it works" clarifies that agents share CLI binaries and
  subscriptions, with a diagram showing two claude agents alongside one
  codex.
- `hooks/README.md` surfaces the three Telegram-plugin deadlocks in
  the table.
- README prose stripped of em-dashes (kept in the agent-type table
  where they mark n/a entries).

## [0.1.2] — 2026-05-20

### Added

- `5dive init` first-run wizard now includes a Telegram channel picker
  with auto-discovery — the wizard probes the bot's recent updates and
  offers detected chats as one-tap choices instead of asking the user
  to paste a chat id.
- `5dive agent send` / `5dive agent ask` accept `--reply-to-chat` and
  `--reply-to-msg`, so an agent can thread its inter-agent message into
  a specific Telegram conversation rather than picking the first paired
  chat blindly.
- `5dive telegram-pending-ignore` and `5dive telegram-resolve-handle` —
  CLI shortcuts the dashboard and the channel pairing flow lean on.
  `resolve-handle` accepts numeric chat ids and group titles in
  addition to `@usernames`.
- Default-on UI install: the local web dashboard install path is gone
  from OSS (see "Changed" below), but the underlying `--no-ui` flag was
  flipped to default-on for the install bits that remain.
- Ship `projects-CLAUDE.md`: `install.sh` drops a slim project-level
  `CLAUDE.md` at `/home/claude/projects/CLAUDE.md` (only if absent),
  symlinked as `AGENTS.md`. Gives every newly-spawned agent baseline
  guidance for switching its own model/effort, the Telegram reply
  mandate for paired agents, and the inter-agent messaging primitives.
- `hooks/README.md` documents the four (now six, after this release's
  inter-agent mirror split) hook scripts and their failure modes.
- README badges for CI status, latest release, and license.
- README — split the "have your agent install it" section into a
  same-machine prompt and a laptop-agent-installs-onto-remote-VM
  prompt; both end with the agent installing the `5dive-cli` skill
  so the user can keep managing 5dive through the same agent.
- README — `codex → hermes` image-to-animation example.
- README OG social-preview image.

### Changed

- Repo renamed `5dive-com/5dive-cli` → `5dive-com/5dive`. The
  short-url installer (`curl install.5dive.com | sudo bash`) keeps
  working unchanged; only direct `raw.githubusercontent.com` URLs in
  third-party docs need updating.
- Local web dashboard removed from OSS. The managed dashboard at
  5dive.com continues to ship for cloud customers; self-hosted users
  drive 5dive entirely from the CLI. Dropping the bundled Next.js app
  cuts the install footprint and removes a long tail of port-conflict
  / reverse-proxy questions.
- `install.sh --upgrade --no-ui` tolerated as a deprecated no-op (was
  previously rejected after the dashboard removal made the flag
  meaningless).
- README rewrite: tighter Quickstart, "Why 5dive" reframed around the
  three isolation tiers (Docker / systemd-user / dedicated-VM), "How
  it works" promoted above the fold, hero demo served via GitHub
  assets / jsDelivr so the inline `<video>` gets the right mp4 mime.

### Fixed

- `5dive auth login claude` now captures the token from
  `claude setup-token`'s TTY login flow (the upstream CLI started
  printing to its own /dev/tty, bypassing the redirected stdout we
  were grepping). Caught by `pair-test` against a fresh Hetzner box.
- UI new-agent flow: full OAuth state machine + Discord token handling
  + error recovery. The previous version assumed every OAuth attempt
  succeeded on the first poll and got stuck on the loading spinner
  when the upstream URL took two ticks to land.
- `init` ASCII logo spelled out 5DIVE properly; opencode reframed as
  BYO-provider (it ships with free models but the wizard implied you
  had to sign in).
- `src/header.sh` prepends `/usr/sbin` to PATH so `adduser`,
  `usermod`, `userdel` always resolve — first-agent-create was failing
  inside systemd-spawned shells where /usr/sbin wasn't on PATH.
- Hooks reliability pass surfaced by live use:
  - `stop-telegram-reply-check.sh` catches trailing assistant text
    that lands after a successful telegram tool call (the agent
    sometimes appends a sign-off the user never sees).
  - Inter-agent mirror split: the old sender-side `PreToolUse` mirror
    couldn't see heredoc-built command bodies. Replaced with a
    receiver-side `UserPromptSubmit` hook
    (`userprompt-mirror-inter-agent.sh`) plus a `Stop` reply mirror
    (`stop-mirror-inter-agent.sh`).
  - Rate-limit-resume text unified between the immediate ping and the
    detached `resume-after-reset.sh`; the auto-press-1 helper moved
    into the detached helper so it survives session teardown.
  - `pretool-telegram-question.sh` typographic-quote bug fixed (the
    template literal was getting smart-quoted somewhere in the
    pipeline and the deny message rendered with U+201C/U+201D).
  - Three follow-up fixes against the inter-agent mirror after first
    live use against `agent-marketing`.

[Unreleased]: https://github.com/5dive-com/5dive/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/5dive-com/5dive/releases/tag/v0.1.2

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

### Installer

- One-liner installer (`curl install.5dive.com | sudo bash`).
- Sets up nvm + Node for the agent runtimes that need it.
- Idempotent: re-running won't touch your registry, auth profiles, or
  agents.
- `install.sh --upgrade` — refresh CLI binaries, systemd unit, and hooks
  only (skips apt/nvm).
- Runs `5dive doctor` automatically after install.

### Telegram

- Stop hook auto-relays missed replies for telegram-paired agents.
- `notify-user` skill for sending progress updates from agents.

### Docker

- Demo container under `docker/` for tire-kickers — runs without needing
  systemd or root on the host.

### Docs

- README — quickstart, auth model, agent-to-agent example, securing-your-server,
  telemetry policy, reverse-proxy recipe.
- Offline / air-gapped install recipe.
- Pointer for non-systemd / non-root users at the Docker path.
- SECURITY.md — private vulnerability reporting via GitHub advisories.
- CONTRIBUTING.md — dev setup, scope guardrails, bundle rule, PR expectations.
- Issue + PR templates.

### CI

- `bundle-drift` workflow — fails any push where the committed `5dive`
  bundle disagrees with `./build.sh` output from `src/`.

[0.1.1]: https://github.com/5dive-com/5dive/releases/tag/v0.1.1
[0.1.0]: https://github.com/5dive-com/5dive/releases/tag/v0.1.0
