# Pre-Launch Tasks

Punch list for the public launch of `5dive-cli` (post-OSS-prep, pre-announce).
Items are ordered roughly by priority. Each completed task is **deleted** from
this file. Commit messages reference the task number so history is recoverable
from `git log`.

Resume prompt: `continue pre-launch tasks from 5dive-cli/PRE_LAUNCH_TASKS.md — pick up the next pending item`

---

## P0 — Repo hygiene (read-as-maintained signal)

### 3. Issue + PR templates
`.github/ISSUE_TEMPLATE/bug_report.md`, `.github/ISSUE_TEMPLATE/feature_request.md`,
`.github/pull_request_template.md`. Short, low-friction.

---

## P1 — Release artifact

### 4. CHANGELOG.md + v0.1.0 tagged release
Walk `git log` since project start, group into Added / Changed / Fixed. Tag
`v0.1.0`, push, cut GitHub Release with the changelog body. Lets users pin
a version instead of tracking `main`.

---

## P1 — CI guard for install path

### 5. CI: run install smoke on PRs touching install / agent-create paths
`./scripts/test-vm.sh smoke` already exists and provisions a real Hetzner box.
Wire to GitHub Actions on PRs that touch `install.sh`, `scripts/inc/5dive-cli.sh`,
or `src/agent/`. Probably gated (manual trigger or label) since it costs real
money per run; nightly cron as a fallback.

---

## P2 — Launch comms (delegate)

### 6. Launch blog post + HN/X thread
Owner: `agent-marketing`. Short blog post on 5dive-blog covering what 5dive-cli
is, why we built it, how to install. HN "Show HN" post + X thread.
Coordinate with whatever else marketing has queued.
