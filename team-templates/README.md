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

## Templates

| File | Team | Roles |
| --- | --- | --- |
| `startup.5dive.yaml` | Lean SaaS startup | CEO, CMO, DevOps, Competitor Researcher, Creative |
| `content-studio.5dive.yaml` | Content studio | Editor-in-Chief, Writer, SEO, Designer, Distributor |

## Schema

See [`SCHEMA-v2.md`](./SCHEMA-v2.md) for the full v2 key reference (the `team`
block, `defaults`, per-role identity/instructions/model, and org reporting edges).
v1 compose keys are unchanged; v2 is additive.
