# shellcheck shell=bash
# THE MARKETPLACE REGISTRY — ONE definition of the repo, every reader.
#
# WHY ITS OWN FILE and not header.sh: the two harnesses that grade the team
# registry (tests/team_registry_unit.sh, tests/distribution_team_template_unit.sh)
# source src/cmd_compose.sh alone and set their own FIVE_VERSION, so they cannot
# source header.sh (its `readonly FIVE_VERSION` would abort them). A standalone
# lib is sourceable by both the bundle and those harnesses, which is what lets a
# test assert THE CONSTANT instead of re-spelling the URL literal — the drift the
# rename below would otherwise reintroduce one harness at a time.
#
# It depends on gh_org() (header.sh in the bundle, a stub in the harnesses).
# THE MARKETPLACE REGISTRY REPO — one definition, every reader.
# Renamed 5dive-ai/character-packs -> 5dive-ai/5dive-marketplace on 2026-09-11
# (a GitHub rename, not a fork: one source of truth). The old raw/clone URLs still
# resolve through GitHub's redirect, so nothing broke on the rename — this constant
# is what removes the dependency on that redirect, which survives only until
# someone creates a repo at the old name.
# HARD RULE (GitHub docs): never create a repo named `character-packs` under the
# org again — a new repo at the old name kills every redirect at once.
# Read by packs (cmd_pack.sh), team templates (cmd_compose.sh) and the docs. The
# loops registry is a DIFFERENT repo (<org>/loops) and is not covered here.
FIVE_MARKETPLACE_REPO="${FIVE_MARKETPLACE_REPO:-5dive-marketplace}"

# Raw base for that registry. Every packs/teams fetch composes its path onto this
# — no call site spells the org or the repo itself.
_marketplace_raw_base() { printf 'https://raw.githubusercontent.com/%s/%s/main' "$(gh_org)" "$FIVE_MARKETPLACE_REPO"; }

# `<org>/<repo>` for messages and --json payloads that name the registry.
_marketplace_slug() { printf '%s/%s' "$(gh_org)" "$FIVE_MARKETPLACE_REPO"; }
