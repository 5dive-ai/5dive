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
| `loops` | [map] | Optional. Recurring work this role OWNS — see `loops:` below. Without it an imported team is a roster with nothing running (DIVE-4022). |
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
- `5dive team import <slug|path> [--prefix=<p>] [--auth-profile=<name>] [--type=<harness>]` —
  resolve a bundled/registry template, optional name-prefix to run multiple orgs on one host,
  run `up`. `--type=` (DIVE-3998) overrides `defaults.type` and every per-agent `type:` for the
  whole roster, and is validated against the box's known harnesses before anything is
  provisioned. Claude-only `model`/`effort` pins are dropped (and reported) when the target
  harness is not claude.
- `5dive export [-o team.yaml]` — NEW. Dump the live fleet (from the registry + each
  agent's config/instructions/reports) back to a v2 spec, so a running org can be saved,
  versioned, and forked into a template. Closes the "exportable" round-trip.

## Phasing
- v1 (DIVE-98): schema v2 keys + `5dive export` + `5dive team import` wrapper + 2-3 curated templates here.
- v2: LLM generator (business description → generated spec).
- v3: visual org composer on the dashboard + community template marketplace.

## `loops:` — the recurring work that makes a roster a company (DIVE-4022)

`goals:` seeds a backlog ONCE, on first `up`. `loops:` declares the work that keeps
coming back. A team imported without loops has agents, roles and reporting lines
with nothing on the board — a roster that sits idle until someone hand-creates the
work.

A loop here is **not a new object**. It ends as exactly what `5dive loop install`
produces: a `kind='recurring'` task template owned by one agent, cloned into a
normal todo by the step-2 materializer on its cadence. Ownership is **per-agent**
because that is how `5dive loop install --onto=<agent>` already models it.

```yaml
agents:
  ceo:
    loops:
      # inline — a recurring task template written straight to the board
      - id: weekly-priorities             # stable key (a-z0-9-), the reconcile key
        title: "Re-set this week's top 3" # the recurring task's title
        cron: "0 9 * * 1"                 # 5-field cron cadence
        prompt: |                         # optional; folded into the task body
          Review the board, pick three, assign owners.
        ceiling: 200000                   # optional advisory tokens/run
      # marketplace — installed via `5dive loop install`, which owns the registry
      # fetch and the skill attach. Nothing about a pack is re-derived here.
      - pack: ci-analyst
        cron: "0 */4 * * *"               # optional; the pack carries its own cadence
```

| key | applies to | meaning |
|---|---|---|
| `id` | inline | Stable key, `a-z0-9-`. Required on an inline loop; the reconcile key. |
| `title` | inline | The recurring task's title. Required on an inline loop. |
| `cron` | both | 5-field cadence. Required inline; on a `pack:` it overrides the pack's own. |
| `prompt` | inline | Optional brief, folded into the task body so every materialized run carries it. |
| `ceiling` | both | Optional advisory tokens/run, recorded for visibility. Bind spend hard with `5dive usage budget`. |
| `pack` | pack | A slug from the `5dive-ai/loops` registry. Mutually exclusive with `title`/`prompt`. |

### Idempotency
`up` is declarative and re-runnable, so a second import must **find** its loops, not
add a second copy. A loop is considered present when the target agent already owns a
`kind='recurring'` row whose body carries this loop's marker (`declared loop: <id>
(5dive.yaml)` or `installed loop: <slug> (5dive marketplace)`) **or** whose title
matches exactly. The title arm matters because `5dive export` also dumps recurring
work created by hand or by `loop install`, which carries no declared-loop marker.

Loops reconcile over the **whole declared roster on every `up`**, not only over
agents created this run — otherwise adding a `loops:` block to a company you already
imported and re-running `up` would do nothing.

### Failure posture
A loop that will not install does **not** fail the import and does **not** count
toward `errors`. The roster is up and useful, and a marketplace fetch needs the
network, which the one-tap dashboard import cannot assume. Failures are restated
after the summary with the exact retry command — same rule as DIVE-2347's failed
skill and DIVE-3994's unset bot token.

### Round-trip
`5dive export` dumps each agent's recurring templates back into a `loops:` block, so
a saved fleet does not silently claim to have no recurring work. A pack-installed
loop exports as `pack: <slug>`; anything else exports as an inline loop, with `id`
taken from the marker or derived from the title.

### Teardown
`5dive down` deletes the TEMPLATE rows for the loops the spec declares, before the
seat is removed — `agent rm` does not, so without this a torn-down company leaves
templates materializing work for an assignee that no longer exists. Already
materialized instances are separate rows and are left alone.

## `pack:` — import a character pack (DIVE-536)

An agent may set `pack: <slug>` instead of `type:`/`instructions:`. The seat is
brought up via `5dive agent import <slug>`, inheriting the pack's persona, skills,
and model/effort from the `5dive-ai/character-packs` registry. `reports_to`,
`role`, `goals`, and an explicit `model`/`effort` override still apply on top.
`channels`, `telegram_token`, `auth_profile`, `workdir`, `defer_auth` pass through.
See the `5dive-team` template for a full company built this way.
