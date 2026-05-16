# OSS Launch Tasks

Pre-launch punch list for opening `5dive-cli` to the public. Items are ordered;
work top-down. Each completed task is **deleted** from this file (per the
working agreement). Commit message references the task title so history is
recoverable from `git log`.

Resume prompt: `continue OSS launch tasks from 5dive-cli/OSS_LAUNCH_TASKS.md — pick up the next pending item`

---

## P0 — Auth & expose-to-public (the thing the user asked about)

> Item numbers are stable — completed items are removed but the surviving
> items keep their original IDs so they're easy to refer to in chat / commits.

### 4. UI auth: session cookie + middleware
- Cookie: `HttpOnly; SameSite=Strict; Path=/`. `Secure` flag set when request
  came in over HTTPS (`X-Forwarded-Proto` or direct TLS).
- HMAC-signed with `sessionSecret`. 7-day sliding expiry.
- Middleware: all `/api/*` requests → check cookie; 401 if invalid.
- `/api/login` POST { password } → check hash → issue cookie.
- `/api/logout` POST → clear cookie.

### 5. UI auth: refuse public bind without auth
On startup, if `bind.host != 127.0.0.1` and `auth.mode != password`, refuse to
start with an error pointing to `5dive ui setup`. Exception: `--insecure` flag
for trusted-LAN power users (logs a loud warning every 60s).

### 6. UI onboarding: first-run setup + login screens
- If `auth.mode=password` and no `passwordHash` set → SPA shows full-screen
  "Set admin password" form. POST `/api/setup` writes config, issues cookie.
- If `passwordHash` set and no valid cookie → login screen.
- Logout button in sidebar footer.

### 7. UI onboarding: empty-state agent wizard
When `agents.length === 0` after auth, show a "Create your first agent"
walkthrough instead of a blank dashboard:
1. Pick a type (Claude / Codex / Gemini / Hermes / OpenClaw / OpenCode)
2. Install binary if missing (stream `agent install <type>` output)
3. Auth (reuse existing `CreateAgentModal` step 2)
4. Name + optional channel
5. Auto-open detail view with Send tab focused

### 8. README: public-exposure docs
Add a "Exposing the UI publicly" section to `ui/README.md`:
- One-page Caddyfile reverse-proxy snippet with auto-HTTPS
- Warning about `--host=0.0.0.0 --insecure`
- Note that OIDC/SSO is on the roadmap but not in v1

---

## P1 — CLI hygiene (small, high-signal for OSS)

### 9. `5dive --version` / `-v`
Read from a single source — bake `5DIVE_VERSION` into `header.sh` (or read from
a top-level `VERSION` file). `build.sh` should fail if the bundled file is
missing the version line. Every OSS CLI has this; reviewers check first.

### 10. `5dive uninstall` (or `install.sh --uninstall`)
Remove `/usr/local/bin/5dive`, `/usr/local/bin/5dive-agent-start`,
`/usr/local/lib/5dive`, `/etc/systemd/system/5dive-agent@.service`. Prompt
before deleting `/var/lib/5dive` and the `claude` user (default: keep). Run
`systemctl daemon-reload` after.

### 11. `5dive init` — first-run wizard
Interactive: pick a type → run `agent install <type>` if missing → auth flow →
create first agent → send "hello" and tail the reply. Single command from the
README quickstart instead of five.

### 12. README: telemetry policy line
One sentence in README near the top. Even "5dive collects no telemetry, ever"
is positive signal; silence reads as "they'll add it later."

### 13. Idempotent install / `install.sh --upgrade`
Verify rerunning `install.sh` on a populated host doesn't clobber registry,
auth profiles, or agents. Add an explicit `--upgrade` path that only refreshes
binaries and the systemd unit. Add a smoke test.

### 14. Run `5dive doctor` after install
Append `5dive doctor` to the end of `install.sh` so the user sees their health
state immediately. Fail-soft if any check fails.

### 15. Strip / reword managed-platform refs
- `cmd_agent.sh:1586` — `FIVE_DOMAIN` comment mentions `warm-hawk.5dive.com`;
  reword to a generic placeholder.
- `cmd_doctor.sh:270` — `shelld` check already short-circuits for non-managed;
  confirm the message text reads cleanly for OSS users.

---

## P2 — UI quality polish (subset of UI_TASKS.md that gates a credible launch)

These reference `ui/UI_TASKS.md` — do not duplicate; mark them done there too.

### 16. UI_TASKS T01 — sidebar nav + layout
### 17. UI_TASKS T02 — toast notification system
### 18. UI_TASKS T04 — skeleton loaders
### 19. UI_TASKS T05 — agent detail full tab set (Config / Pair / Send / Logs)
### 20. UI_TASKS T07 — clone agent
### 21. UI_TASKS T09 — accounts page
### 22. `5dive ui` UX polish: auto-open browser, detect missing `bun` with a clear error pointing to install.sh.

---

## P3 — Day-2 (post-launch, ordered by likely demand)

### 23. Docker `docker run` one-liner for tire-kickers who don't want root install
### 24. `--user` mode (tmux-managed, no systemd)
### 25. Offline / air-gapped install (release tarball + manual steps)
### 26. UI_TASKS T10 + T11 — health page + install missing type binaries
### 27. UI_TASKS T08 — ask / sync send
### 28. UI_TASKS T12 — telegram access management
### 29. UI_TASKS T13 — mobile responsive layout
### 30. OIDC / SSO adapter (Authelia / Authentik compatible)
