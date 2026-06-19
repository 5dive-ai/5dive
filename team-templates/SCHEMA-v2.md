# 5dive.yaml v2 — Team / company-structure schema (DRAFT, DIVE-97/98)

Extends the existing compose engine (`5dive up/down/ps`, parser at `5dive-cli/5dive`
~L8585). v1 keys are unchanged; v2 adds role identity, per-role instructions,
model/effort, and org reporting edges, plus a top-level `team` block and `defaults`.

`5dive up -f team.yaml` already does idempotent multi-agent bring-up. v2 = teach the
parser the new keys + wire them at create time. `5dive team import <template>` is a thin
wrapper that resolves a bundled template and runs `up`.

## Top level

```yaml
version: "2"

team:                      # NEW — template metadata (display + marketplace)
  name: "Lean SaaS startup"
  description: "5-role founding team: CEO + CMO + DevOps + Researcher + Creative"
  slug: startup            # used by `5dive team import startup`

defaults:                  # NEW — merged into every agent (agent-level keys win)
  type: claude
  channels: telegram
  isolation: standard
  auth_profile: "${TEAM_AUTH_PROFILE}"   # one account for the whole org by default

agents:
  <name>: { ... }          # name = system id (a-z0-9-), used by `5dive agent send`
```

## Per-agent keys

### v1 (unchanged)
`type` · `channels` · `telegram_token` · `discord_token` · `workdir` · `skills[]` ·
`no_skills` · `defer_auth` · `isolation` · `auth_profile` · `provider` · `api_key`

### v2 additions
| key | type | meaning |
|---|---|---|
| `role` | string | Human title ("CEO", "CMO"). Display + org-chart label, distinct from `name`. |
| `instructions` | string (multiline) | Role mandate. Written into the agent's `~/.claude/CLAUDE.md` at create, BELOW the shared telegram CLAUDE.md fragment (does not replace it). The key gap v1 lacks. |
| `instructions_file` | path | Alternative to inline; path resolved against the spec dir. Mutually exclusive with `instructions`. |
| `model` | enum/string | `opus\|sonnet\|haiku` (claude) or a provider model id. Applied via the existing `agent config set model=` path. |
| `effort` | enum | `low\|medium\|high` → settings.json effortLevel. |
| `reports_to` | string \| [string] | `name`(s) of this role's manager(s). Builds org-chart edges AND a generated "Reporting" block appended to instructions (who you answer to, who reports to you, reach them via `5dive agent send <name>`). Root role omits it. |
| `goals` | [string] | Optional. Seeded into the shared task queue (`5dive task add --assignee=<name> --from=<manager>`) on first `up`, so the role starts with a backlog. |

### Reporting-line semantics
`reports_to` is the single source of org truth. From it the importer derives, per agent:
- org-chart edges (feeds the existing paperclip-derived chart),
- a `## Reporting` section appended to that agent's CLAUDE.md listing manager + direct
  reports + the exact `5dive agent send` invocation for each, so delegation is real, not
  decorative.

## Validation / safety
- Every `reports_to` target must be a `name` in `agents:` (else fail loudly, like the v1
  `${VAR}` unset check).
- Reject cycles in the reporting graph.
- `instructions` + `instructions_file` mutually exclusive.
- Unknown keys warn (forward-compat) rather than hard-fail.

## New CLI surface
- `5dive up -f team.yaml` — unchanged entry point; parser learns v2 keys.
- `5dive team import <slug|path> [--prefix=<p>] [--auth-profile=<name>]` — resolve a
  bundled/registry template, optional name-prefix to run multiple orgs on one host, run `up`.
- `5dive export [-o team.yaml]` — NEW. Dump the live fleet (from the registry + each
  agent's config/instructions/reports) back to a v2 spec, so a running org can be saved,
  versioned, and forked into a template. Closes the "exportable" round-trip.

## Phasing
- v1 (DIVE-98): schema v2 keys + `5dive export` + `5dive team import` wrapper + 2-3 curated templates here.
- v2: LLM generator (business description → generated spec).
- v3: visual org composer on the dashboard + community template marketplace.

## `pack:` — import a character pack (DIVE-536)

An agent may set `pack: <slug>` instead of `type:`/`instructions:`. The seat is
brought up via `5dive agent import <slug>`, inheriting the pack's persona, skills,
and model/effort from the `5dive-ai/character-packs` registry. `reports_to`,
`role`, `goals`, and an explicit `model`/`effort` override still apply on top.
`channels`, `telegram_token`, `auth_profile`, `workdir`, `defer_auth` pass through.
See the `5dive-team` template for a full company built this way.
