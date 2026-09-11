# Parser fixtures — NOT a bundled template dir

DIVE-4196 moved the shipped team templates to the marketplace registry
(`5dive-ai/5dive-marketplace`, `teams/`). Nothing here is staged by `install.sh`,
copied by `docker/Dockerfile`, or resolvable by `5dive team import <slug>` — a
slug resolves in the registry and nowhere else.

These copies exist for one reason: the harnesses in `tests/` that grade the
COMPOSE PARSER (`_compose_parse`, the v2 schema, `loops:`) need real, non-toy
specs, and a unit test must not depend on the network.

So they grade the PARSER, not the CATALOGUE. The catalogue — index.json
advertising exactly what the repo contains, each entry's `schemaVersion`
matching its template's own `version:`, each roster matching its `agents:`
block — is graded where it now lives, by
`scripts/check-teams.sh` in the registry repo.

Drift here is therefore expected and harmless in one direction only: if a
template changes in the registry and not here, these harnesses still grade the
parser correctly against a valid v2 spec. Do NOT "fix" that by making the
harnesses fetch the registry — that trades a deterministic unit test for a
network dependency, and the catalogue guard already covers the real drift.
