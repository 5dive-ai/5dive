# Pre-Launch Tasks

Punch list for the public launch of `5dive-cli` (post-OSS-prep, pre-announce).
Items are ordered roughly by priority. Each completed task is **deleted** from
this file. Commit messages reference the task number so history is recoverable
from `git log`.

Resume prompt: `continue pre-launch tasks from 5dive-cli/PRE_LAUNCH_TASKS.md — pick up the next pending item`

---

## P0 — Repo hygiene (read-as-maintained signal)

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
