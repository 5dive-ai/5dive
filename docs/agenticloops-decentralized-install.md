# agenticloops.dev — decentralized loop install (skills.sh model)

DIVE-779. lodar requirement: **NOT a centralized registry — the skills.sh model.**
Anyone can publish/install a loop from a source THEY host; our repo is an optional
discovery index, never a gate. Domain: agenticloops.dev (lodar greenlit; purchase = his
spend call). This doc specs the CLI-side resolver change (Marcus owns CLI/user-integration);
the catalog site is a separate frontend slice (dev).

## Today (centralized — what changes)
`src/cmd_loop_pack.sh`: `_loops_base()` is hardcoded to
`raw.githubusercontent.com/<org>/loops/main`; `install <slug>` resolves the slug against
that one repo's `index.json`. To publish you must land in OUR repo. That's the central gate
to remove.

## Target: a loop ref resolves from ANY source
`5dive loop install <ref>` where `<ref>` is one of:
- `github:user/repo[@ref][:path]`   — manifest in the author's GitHub repo (default path
  `loop.json`, default ref `main`). e.g. `github:alice/ci-watcher`.
- `https://…/loop.json`             — any raw manifest URL the author controls.
- `<slug>`                          — bare slug: resolved against the **discovery index**
  (see below) for backward-compat + convenience. NOT the only path, just the friendly one.

Resolution order for a bare slug: look it up in the configured index(es) -> the index entry
carries a `source` (a `github:`/`https:` ref) -> fetch the manifest from THAT source. So even
"listed" loops are fetched from the author's source; the index only maps name -> source.

## The discovery index demotes to optional
`<org>/loops/index.json` stays, but its role changes: it is a **curated discovery list**
(name -> source ref + display metadata), not the store. Properties:
- Being in it is NOT required to install (`github:`/`https:` refs bypass it entirely).
- Multiple indexes allowed: `LOOPS_INDEXES` env / config = comma-list of index URLs; ours is
  just the default. Users/orgs can point at their own.
- The index never holds the loop body — only a pointer to the author's source.

## Manifest format (`loop.json`, author-hosted)
```
{
  "schema": "agenticloops/v1",
  "slug": "ci-analyst",
  "title": "CI Analyst",
  "description": "...",
  "author": "alice",
  "starterPrompt": "...",            // required (current install needs it)
  "skills":   ["github:alice/skill-x", ...],   // refs, also author-hosted
  "cron": "0 * * * *",               // default schedule (overridable at install)
  "ceiling": 200000,                 // default token ceiling
  "model": "opus", "effort": "high", // optional defaults
  "signature": "<ed25519 ...>",      // OPTIONAL — see trust
  "publisher_did": "did:key:..."     // OPTIONAL — who signed
}
```
This is a superset of today's registry entry, so the existing install path
(`cmd_loop_pack_install`) keeps working once it reads `source`-fetched JSON instead of the
central index row.

## Trust: signing is an OPTIONAL badge, never a gate
Reuse the OpenAgent ed25519 registry signing (see openagent registry signing notes).
- Unsigned loops **install fine** (open!) — CLI prints a one-line "unverified publisher" note.
- Signed loops: CLI verifies `signature` against `publisher_did`; on pass shows a
  "✓ verified: <publisher>" mark. On a signature that's present-but-bad: warn loudly, still
  let the user proceed with explicit `--allow-unverified` (fail-closed on tampering, not on
  absence).
- The catalog site shows the same verified badge. Trust is a SIGNAL layered on openness, not
  permission to exist.

## Install-time consent (loops carry skills + a schedule)
A loop wires skills onto an agent + schedules recurring spend. Install must surface, before
committing: the source, signed/unsigned, the skills it will add, the cron, the token ceiling.
`--yes` to skip the prompt for scripted installs. (This is the same consent surface Agent
Packs (DIVE-777) will need, scaled up — build it reusably.)

## curl bootstrap (CLI-less users)
`curl -fsSL agenticloops.dev/install | sh` installs the OSS 5dive CLI (reuse install.sh
machinery), then `5dive loop install <ref>` works. Top-of-funnel: browse + install free, but
running a loop 24/7 needs a host = 5dive. Open front door, proprietary runtime = the funnel.

## Build split
- CLI (Marcus): ref parser + multi-source resolver + manifest fetch/validate + signature
  verify + consent surface. Backward-compatible: bare slug still works.
- Site (dev): agenticloops.dev catalog over the discovery index, per-loop pages (SEO +
  social unfurl), copy-paste install command, the curl bootstrap, verified badges.
- Registry repo (claude push): convert `<org>/loops/index.json` to name->source pointers.

## Gates
- **Domain purchase = lodar spend call** (~a .dev/yr). DNS: 5dive.com is on Cloudflare, no CF
  token on this box -> new-domain DNS needs a setup step.
- Public catalog launch = the usual public-facing ship gate (Marcus + lodar nod).
