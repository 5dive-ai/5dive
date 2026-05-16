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

---

## P1 — CLI hygiene (small, high-signal for OSS)

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
