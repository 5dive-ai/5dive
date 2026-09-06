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

Omit the flag and behaviour is exactly as before.

## Templates

| File | Team | Roles |
| --- | --- | --- |
| `5dive-team.5dive.yaml` | 5dive (AI-run company) | CEO, CTO, DevOps, Engineer, Verifier, CMO, Community, Creative |
| `startup.5dive.yaml` | Lean SaaS startup | CEO, CMO, DevOps, Competitor Researcher, Creative |
| `content-studio.5dive.yaml` | Content studio | Editor-in-Chief, Writer, SEO, Designer, Distributor |
| `eng-studio.5dive.yaml` | Eng Studio | CEO, Eng Manager, Designer, Release Manager, Doc Engineer, QA |

## Schema

See [`SCHEMA-v2.md`](./SCHEMA-v2.md) for the full v2 key reference (the `team`
block, `defaults`, per-role identity/instructions/model, and org reporting edges).
v1 compose keys are unchanged; v2 is additive.
