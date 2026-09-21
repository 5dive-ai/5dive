#!/usr/bin/env bash
# DIVE-4754 — resolve the 5dive-plugins tree the harnesses grade against, PINNED.
#
# WHY THIS FILE EXISTS. DIVE-4452 pinned every clone of 5dive-plugins in
# `.github/workflows/`, and its guard greps that directory. The clone that
# actually resolves $FIVEDIVE_PLUGIN_REGISTRY — the subject of the T5a/T5b/T6
# arms in tests/plugin_bundled_install_unit.sh — is not in a workflow: it was in
# scripts/run-harnesses.sh, tracking `main`. On 2026-09-21 05:49Z a delete in
# 5dive-plugins (#102, DIVE-4734) took `browser` out of that live tree and the
# required `test` context on 5dive-ai/5dive@main went 23/5 red with ZERO commits
# of its own, freezing every merge and release cut (DIVE-4752). The same class
# fired the day before (DIVE-4708). The guard printed
# `OK: 5dive-plugins is pinned, consistently, everywhere it is graded.`
#
# THE RULE, and it is the one the incident bought:
# community/wiki/a-pin-guard-that-greps-a-directory-is-scoped-to-a-location-not-a-behaviour.md
# — a guard is scoped to the BEHAVIOUR it forbids, over the whole repo, with a
# named allowlist. The forbidden behaviour is "CI resolves the plugins tree from
# a moving ref". So the resolution lives in ONE function, it refuses anything
# that is not a 40-hex sha, and tests/plugins_registry_pin_unit.sh drives this
# function directly rather than grepping the source text around it.
#
# WHY REFUSING IS RIGHT AND SILENT IS NOT. With no pin the arms report NOT RUN,
# loudly, on stderr and in the harness banner — the corpus still grades. That is
# strictly better than the alternative it replaces, which was grading a tree
# another repo can change between two runs of an unchanged commit. A required
# check must be a function of this tree alone.

# fivedive_resolve_plugin_registry
#   Exports FIVEDIVE_PLUGIN_REGISTRY pointing at a checkout of
#   <org>/5dive-plugins at exactly $PLUGINS_REF, and prints what it resolved.
#   Returns 0 when there is nothing to do or the pin resolved; 1 when it did
#   not. NEVER fatal: the caller grades a corpus, and losing the plugin corpus
#   must not abort the tier (the harnesses say the arms did not run).
fivedive_resolve_plugin_registry() {
  # Already pointed at a local checkout (every local run, and the seam the
  # harnesses use to install a fixture) — leave it exactly alone.
  [[ -n "${FIVEDIVE_PLUGIN_REGISTRY:-}" ]] && return 0
  # On CI, and ONLY on CI: one fetch here rather than in each of the six jobs.
  [[ -n "${CI:-}" ]] || return 0

  local reg="${RUNNER_TEMP:-/tmp}/5dive-plugins-registry"
  local org="${GITHUB_REPOSITORY_OWNER:-5dive-ai}"
  local ref="${PLUGINS_REF:-}"

  # A moving ref is the defect, not a lesser form of the pin. `main`, a tag, a
  # branch and a short sha are all refused by the same test, and the empty
  # string with them: an unset PLUGINS_REF must not silently mean `main`.
  if [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'plugin registry: UNRESOLVED — PLUGINS_REF is %s, not a 40-hex sha. An unpinned plugins tree froze this repo'"'"'s merge queue on 2026-09-21 (DIVE-4752/DIVE-4754), so the registry arms will report NOT RUN rather than grade a moving ref.\n' \
      "${ref:-unset}" >&2
    return 1
  fi

  # Idempotent across repeated calls in one job, but only when what is on disk
  # IS the pin. A checkout at some other sha is re-fetched, never accepted:
  # "a directory exists" is not evidence about its contents.
  local have=""
  [[ -d "$reg/.git" ]] && have="$(git -C "$reg" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$have" != "$ref" ]]; then
    # Fetch-by-sha, depth 1 — the same shape the workflows use for the sibling
    # clone. Deliberately NOT `git clone`: a clone resolves a branch, and the
    # repo-wide guard forbids that spelling anywhere CI can reach it.
    if ! (
      git init --quiet "$reg" \
        && (git -C "$reg" remote add origin "https://github.com/$org/5dive-plugins.git" \
            || git -C "$reg" remote set-url origin "https://github.com/$org/5dive-plugins.git") \
        && timeout 60 git -C "$reg" fetch --quiet --depth 1 origin "$ref" \
        && git -C "$reg" checkout --quiet --force FETCH_HEAD
    ) 2>/dev/null; then
      printf 'plugin registry: UNRESOLVED — could not fetch %s/5dive-plugins@%s; the registry arms will report NOT RUN\n' \
        "$org" "$ref" >&2
      return 1
    fi
  fi

  export FIVEDIVE_PLUGIN_REGISTRY="$reg"
  printf 'plugin registry: %s @ %s (PINNED to PLUGINS_REF, DIVE-4754)\n' "$reg" "$ref"
  return 0
}
