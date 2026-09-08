# Team templates

Ready-made multi-agent team definitions (`*.5dive.yaml`, schema v2) you can stand
up in one command. Each template describes a small company of agents — roles,
per-role instructions, model/effort, channels, and who reports to whom — that the
compose engine brings up idempotently.

## Use one

```bash
5dive team import startup --auth-profile=<account>
# or, equivalently, point at the file directly:
5dive up -f startup.5dive.yaml
```

`5dive team import <name>` resolves a bundled template here and runs `5dive up`.
Per-role Telegram bot tokens are read from the environment (`${...}`) — set them
before importing. Templates default to one shared account; split roles across
accounts later to avoid the shared-account burst rate-limit.

### Import onto a non-Claude harness

Every template here sets `defaults.type: claude`. `--type=<harness>` overrides that
for the whole roster, so a company import is not Claude-Code-only:

```bash
5dive team import content-studio --type=codex
```

`5dive team import --help` lists the harnesses this box knows. Two things worth
knowing before you use it:

- It applies to **every** agent, including one that names its own `type:` and one
  imported from a character pack. A half-migrated company is worse than none.
- The templates pin Claude models (`model: opus|sonnet`) and `effort:`, which mean
  nothing on another harness — those pins are **dropped** when the target is not
  claude, and the agents they were dropped from are named in the output. Set a
  model afterwards with `5dive agent config <name> set model=<id>`.

Pass the same flag to `5dive ps -f <spec> --type=<harness>` — it reports the harness the spec
declares, so without it the status view would call a codex roster "claude".

Omit the flag and behaviour is exactly as before.

## Templates

| File | Team | Roles |
| --- | --- | --- |
| `5dive-team.5dive.yaml` | 5dive (AI-run company) | CEO, CTO, DevOps, Engineer, Verifier, CMO, Community, Creative |
| `deploy-team.5dive.yaml` | Deploy Team | CTO, DevOps and Delivery, Engineer, Verifier / QA |
| `startup.5dive.yaml` | Lean SaaS startup | CEO, CMO, DevOps, Competitor Researcher, Creative |
| `content-studio.5dive.yaml` | Content studio | Editor-in-Chief, Writer, SEO, Designer, Distributor |
| `eng-studio.5dive.yaml` | Eng Studio | CEO, Eng Manager, Designer, Release Manager, Doc Engineer, QA |


## Deploy Team: the two things "our GitHub loop" means

`deploy-team` is the four-seat engineering subtree — CTO, Ops, Engineer,
Verifier — plus the recurring work that makes it ship. It is our own subtree,
not an invented roster: the same four character packs the `5dive-team` template
already carries.

```bash
5dive team import deploy-team
```

No `--auth-profile=` here: this template pins no account (its seats come up with
deferred auth, which is what lets a one-tap import from the dashboard work), so
the flag has nothing to bind and the import says so. Sign each seat in afterwards
with `5dive agent auth <name>`.

The loops it ships are **two different mechanisms**, and it is worth knowing
which is which before you change one.

**1. The queue rail — already in the CLI, nothing installed.** The maker pushes
and runs `5dive task deliver <id> --pr=<url>`; the row hands off to the verifier,
who grades at the delivered commit; a maker's `task done` on a rail row
re-delivers rather than closes; the push-capable seat merges. Nothing in the
template turns this on — it engages because **exactly one seat carries a
verifier/QA role marker** (`vesper`, role `Verifier / QA`), so `task add` binds
that seat as the grader by default. Give a second seat a role containing "QA",
"verifier", "test" or "quality" and the auto-pick goes ambiguous, reports it, and
**skips the rung** — rows then get filed with no grader at all. If you rename
roles, keep the marker unique.

**2. The cron loops (`loops:`) — what keeps the rail fed.** CTO: weekly
priorities, plus a daily board sweep that unblocks and re-assigns. Ops: a daily
sweep of open pull requests, read straight from `gh pr list` because a PR is not
a task row and the board cannot see it — merge what the verifier passed, bounce
what CI reddened back onto the row. Verifier: drain the grade queue. Engineer:
take the oldest runnable row and deliver it **on push, not on CI green** — the
verifier re-derives the result at the delivered commit anyway, so a maker sitting
on a check is spending, not waiting.

### Push capability is a property of the box, not of a seat

Schema v2 has no per-agent "can push" key, because the GitHub credential is
box-wide. So the separation is a mandate, not a permission: the Engineer opens
pull requests, and the Verifier is told never to merge what it graded — the
writer is never the grader, and a grader that can also merge is both.

What the import *can* check is whether the box holds a credential at all, which
is what `team.requires:` is for.

## `team.requires:` — what a team needs from the box

A template may declare the capabilities it needs to do its job:

```yaml
team:
  slug: deploy-team
  requires: [github_push]
```

Before anything is provisioned, `5dive up` (and therefore `team import`) probes
each key and says what it found. **A missing capability never fails the import.**
The roster comes up in a reduced mode, and the reduced mode is named — the
failure this prevents is not "no team", it is a team that silently cannot do the
one thing it was imported for.

| key | probe | absent |
| --- | --- | --- |
| `github_push` | `gh auth token` (offline; no network call) | the team imports **review-only**: it reads, grades, files and rejects, but nothing it approves is pushed or merged |
| `browser` | `5dive browser --help` | the team imports **API-only**: steps needing an authenticated browser session do not run |

The probes live in the CLI and a template only names a key — a template that
could name its own shell command would be arbitrary code run by an import. A key
the CLI has no probe for is reported as **unchecked**, never as satisfied and
never as absent.

## Schema

See [`SCHEMA-v2.md`](./SCHEMA-v2.md) for the full v2 key reference (the `team`
block, `defaults`, per-role identity/instructions/model, and org reporting edges).
v1 compose keys are unchanged; v2 is additive.
