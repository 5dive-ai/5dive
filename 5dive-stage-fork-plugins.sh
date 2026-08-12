#!/usr/bin/env bash
# 5dive-stage-fork-plugins.sh — deliver the FORK telegram plugins (codex/grok/agy/
# pi/opencode) to /usr/local/lib/5dive/telegram-<rt>, from a REF.
#
# Usage:
#   sudo /usr/local/bin/5dive-stage-fork-plugins.sh            # stage; print "changed: <rt>" per fork that moved
#   sudo /usr/local/bin/5dive-stage-fork-plugins.sh --status   # what each fork runs, vs upstream
#
# Called by 5dive-refresh-plugins.sh (itself on the 23:15 host-update cron), which
# reads the `changed:` lines to decide which fork agents to bounce. Standalone-safe
# and idempotent.
#
# SEPARATE FILE, NOT A BLOCK IN THE REFRESH SCRIPT, and the reason is testability:
# 5dive-refresh-plugins.sh refuses without a claude binary and enumerates real
# agents at load, so its fork half could only ever have been exercised on a live
# host. Every path below runs against temp dirs via the FORK_* env overrides, which
# is what tests/refresh_plugins_fork_stage_unit.sh does. A delivery mechanism that
# can only be tested by delivering is the shape this row exists to end.

set -uo pipefail

# WHY THIS EXISTS. 5dive-refresh-plugins.sh serves the CLAUDE lineage, which loads a
# VERSIONED marketplace cache. The five FORK plugins (codex/grok/agy/pi/opencode) do not.
# They load `/usr/local/lib/5dive/telegram-<rt>/server.ts` directly — agent-codex's
# config.toml names that path, and `agent_setup.sh` resolves
# `TELEGRAM_<RT>_PLUGIN_DIR` -> that dir -> the shared checkout, so the staged dir
# always wins because it exists.
#
# NOTHING WAS WRITING IT. Measured 2026-08-11 (DIVE-3269): all five staged copies
# predated DIVE-3224 by an hour, with that row and DIVE-3267 both merged. Not a
# slow schedule — no schedule. "Merged" and "running" were indistinguishable from
# every surface, which is why it went unnoticed rather than unfixed.
#
# THREE DECISIONS, made here rather than assumed, because each has a wrong answer
# that looks reasonable:
#
# 1. STAGE FROM A REF, VIA A BARE MIRROR — never from a working tree. The obvious
#    implementation reads the shared checkout at /home/claude/projects/5dive/
#    5dive-plugins, which on the day this was written sat on a feature branch
#    (dive-1428-gap23-inline-clear, ca36c73). A stage step pointed there ships
#    whatever someone left checked out, to every fork agent, unreviewed. A BARE
#    mirror has no working tree to be parked, so the failure mode is structurally
#    absent rather than merely avoided. It also keeps root's hands off an
#    agent-writable checkout: `sudo git` in a shared checkout leaves root-owned
#    objects behind and breaks the next agent that writes there.
#    The repo is public, so the mirror needs no credentials.
#
# 2. NEVER FALL BACK TO THE TREE. If the ref cannot be resolved this SKIPS, loudly,
#    leaving the previous staged copy in place. Stale-but-reviewed beats
#    fresh-but-unreviewed, and a delivery step that silently degrades to an
#    unreviewed source is worse than one that does not run.
#
# 3. OVERLAY, DO NOT REPLACE. The staged dirs carry `node_modules` (~1 dir per
#    fork) that the repo does not. A clean-and-copy would delete it and leave every
#    fork agent unable to start; `bun install` re-runs only when the lockfile or
#    manifest actually changed.
#
# The checkout fallback in agent_setup.sh is deliberately NOT removed here. It is
# provably never-firing on a staged box and reads like a safety net it is not — but
# it is on the agent-create path, whose smoke cannot run on this host (DIVE-2847),
# and removing a net in the same change that first makes the primary
# self-maintaining is two changes wearing one hat. Recommended as its own row.
FORK_REPO_URL="${FORK_REPO_URL:-https://github.com/5dive-ai/5dive-plugins}"
FORK_MIRROR="${FORK_MIRROR:-/var/lib/5dive/plugins-mirror.git}"
FORK_REF="${FORK_REF:-main}"
FORK_STAGE_ROOT="${FORK_STAGE_ROOT:-/usr/local/lib/5dive}"
FORK_MANIFEST=".5dive-stage.json"
FORK_STAGED_CHANGED=""

# Sync the bare mirror and print the resolved sha. Non-zero rc means "could not
# resolve the ref" — the caller must skip, never substitute another source.
fork_mirror_sync() {
  if [[ ! -d "$FORK_MIRROR" ]]; then
    mkdir -p "$(dirname "$FORK_MIRROR")" || return 1
    git clone --quiet --bare "$FORK_REPO_URL" "$FORK_MIRROR" >/dev/null 2>&1 || return 1
  fi
  # +refs/heads/<ref>: force-update the local ref so a rewritten upstream cannot
  # wedge the mirror at an old sha forever (it would stage stale code and report
  # success, which is this row's defect with a different cause).
  git -C "$FORK_MIRROR" fetch --quiet --prune origin "+refs/heads/${FORK_REF}:refs/heads/${FORK_REF}" >/dev/null 2>&1 \
    || echo "  WARN: fork mirror fetch failed — falling back to the last fetched ref, NOT to any working tree" >&2
  git -C "$FORK_MIRROR" rev-parse --verify --quiet "refs/heads/${FORK_REF}" 2>/dev/null
}

# Which forks does the ref carry? Enumerated from the ref itself, so a fork added
# upstream is staged without editing this list, and `telegram` (the claude-lineage
# base, delivered by the marketplace above) is excluded.
fork_list() {
  git -C "$FORK_MIRROR" ls-tree --name-only "refs/heads/${FORK_REF}:plugins" 2>/dev/null \
    | grep '^telegram-' || true
}

# Stage one fork. Echoes "changed" when the tracked files moved.
fork_stage_one() {
  local rt="$1" sha="$2" dest="$FORK_STAGE_ROOT/$rt" tmp changed=0
  tmp=$(mktemp -d "/tmp/5dive-fork-stage.XXXXXX") || return 1
  if ! git -C "$FORK_MIRROR" archive "refs/heads/${FORK_REF}" "plugins/$rt" 2>/dev/null \
       | tar -x -C "$tmp" --strip-components=2 2>/dev/null; then
    rm -rf "$tmp"; echo "  WARN: $rt — archive from ${FORK_REF} failed, leaving the staged copy alone" >&2
    return 1
  fi
  [[ -f "$tmp/server.ts" ]] || { rm -rf "$tmp"; echo "  WARN: $rt — no server.ts in the ref, skipping" >&2; return 1; }
  mkdir -p "$dest"
  # Compare only what the ref carries: node_modules and local .bak files live in
  # dest and are not the ref's business.
  ( cd "$tmp" && find . -type f -print0 ) | while IFS= read -r -d '' f; do
      cmp -s "$tmp/$f" "$dest/$f" 2>/dev/null || { echo changed; break; }
    done | grep -q changed && changed=1
  if (( changed )); then
    # PER-FILE ATOMIC INSTALL. This runs as root out of the 23:15 cron and
    # overwrites what five live agents execute, with nobody watching. A plain
    # `tar -x` over the live dir can half-write on a crash, a full disk, or a
    # kill — and a truncated server.ts takes the fork agents down until someone
    # notices. Copy beside the target, fsync-free rename into place: a reader
    # either sees the old inode or the new one, never a partial file.
    # The validated temp dir above is the other half: nothing is installed until
    # the archive extracted cleanly AND carried a server.ts.
    local f rc=0
    while IFS= read -r -d '' f; do
      f="${f#./}"
      mkdir -p "$dest/$(dirname "$f")" || { rc=1; break; }
      cp -f "$tmp/$f" "$dest/$f.stage-tmp" 2>/dev/null || { rc=1; break; }
      mv -f "$dest/$f.stage-tmp" "$dest/$f" 2>/dev/null || { rc=1; break; }
    done < <( cd "$tmp" && find . -type f -print0 )
    if (( rc )); then
      # Partially installed is the one state worth shouting about: some files are
      # new, some old, and the next run will not necessarily notice.
      echo "  ERROR: $rt — install failed part-way; the staged copy may be MIXED. Re-run; --status will show it." >&2
      find "$dest" -name '*.stage-tmp' -delete 2>/dev/null
      rm -rf "$tmp"
      return 1
    fi
    printf '{"plugin":"%s","ref":"%s","sha":"%s","staged_at":"%s","source":"%s"}\n' \
      "$rt" "$FORK_REF" "$sha" "$(date -Iseconds)" "$FORK_REPO_URL" > "$dest/$FORK_MANIFEST"
    # Deps only when the lockfile or manifest actually moved — `bun install` on
    # every run would be a minutes-long no-op five times a night.
    if [[ -f "$dest/package.json" ]] && ! cmp -s "$tmp/bun.lock" "$dest/bun.lock.staged" 2>/dev/null; then
      cp -f "$tmp/bun.lock" "$dest/bun.lock.staged" 2>/dev/null || true
      if command -v bun >/dev/null 2>&1; then
        ( cd "$dest" && bun install --silent >/dev/null 2>&1 ) || echo "  WARN: $rt — bun install failed" >&2
      fi
    fi
    echo changed
  fi
  rm -rf "$tmp"
  return 0
}

stage_fork_plugins() {
  local sha
  if ! sha=$(fork_mirror_sync) || [[ -z "$sha" ]]; then
    echo "--- fork plugins: SKIPPED — could not resolve ${FORK_REF} in the mirror (no staging from a working tree) ---" >&2
    return 0
  fi
  echo "--- fork plugins: staging from ${FORK_REF}@${sha:0:7} ---"
  local rt
  for rt in $(fork_list); do
    if [[ "$(fork_stage_one "$rt" "$sha")" == changed ]]; then
      FORK_STAGED_CHANGED="${FORK_STAGED_CHANGED:+$FORK_STAGED_CHANGED }$rt"
      echo "  staged: $rt -> ${sha:0:7} (changed)"
    else
      echo "  up to date: $rt"
    fi
  done
  [[ -n "$FORK_STAGED_CHANGED" ]] || echo "  (no fork plugin changed)"
}

# `--status`: the readout this row exists for as much as the staging does. Merged
# and running were indistinguishable from every surface, so the fix that only
# stages would leave the NEXT drift equally invisible.
# Does the staged tree's CONTENT match the ref's? Returns 0 on match.
#
# THIS IS DERIVED FROM THE BYTES ON DISK, NOT FROM THE MANIFEST, and the
# distinction is the whole row. A status verb that reads a file the stager wrote
# can only ever confirm THE STAGER RAN — it agrees with the writer by
# construction, which is "merged and running are indistinguishable" reproduced one
# layer up. So every file the ref carries is hashed with `git hash-object` and
# compared to the blob id in the ref's tree: a hand-edited server.ts (the box
# carries a server.ts.bak-dive3179-* right now, so this is a state that HAPPENS)
# disagrees here even though the manifest still reads CURRENT.
fork_content_matches() {
  local rt="$1" ref="$2" dest="$FORK_STAGE_ROOT/$rt" line mode type blob path
  local listed=0
  while read -r mode type blob path; do
    [[ "$type" == blob ]] || continue
    listed=1
    path="${path#plugins/$rt/}"
    [[ -f "$dest/$path" ]] || return 1
    [[ "$(git hash-object "$dest/$path" 2>/dev/null)" == "$blob" ]] || return 1
  done < <(git -C "$FORK_MIRROR" ls-tree -r "${ref}:plugins/$rt" --full-name 2>/dev/null \
           || git -C "$FORK_MIRROR" ls-tree -r "$ref" -- "plugins/$rt" 2>/dev/null)
  (( listed )) || return 1
  return 0
}

fork_status() {
  local sha rt m
  sha=$(fork_mirror_sync 2>/dev/null) || sha=""
  if [[ -n "$sha" ]]; then
    echo "fork plugin staging — ${FORK_REF}@${sha:0:7} at $FORK_REPO_URL"
    echo "  (verdicts are hashed from the files on disk, not read from the stage manifest)"
  else
    echo "fork plugin staging — UPSTREAM UNKNOWN (mirror could not resolve ${FORK_REF}); nothing to compare against"
  fi
  for rt in "$FORK_STAGE_ROOT"/telegram-*/; do
    [[ -f "$rt/server.ts" ]] || continue
    rt="$(basename "$rt")"
    m="$FORK_STAGE_ROOT/$rt/$FORK_MANIFEST"
    local ssha="-" sat="?"
    if [[ -r "$m" ]] && command -v jq >/dev/null 2>&1; then
      ssha=$(jq -r '.sha // "-"' "$m" 2>/dev/null); sat=$(jq -r '.staged_at // "?"' "$m" 2>/dev/null)
    fi
    # The manifest is PROVENANCE (when, from where) and is printed as such. It is
    # never the verdict.
    if [[ -z "$sha" ]]; then
      printf '  %-22s %-9s staged %s  UNKNOWN (no upstream to hash against)\n' "$rt" "${ssha:0:7}" "$sat"
    elif fork_content_matches "$rt" "refs/heads/${FORK_REF}"; then
      printf '  %-22s %-9s staged %s  CURRENT (content matches %s)\n' "$rt" "${ssha:0:7}" "$sat" "${sha:0:7}"
    elif [[ "$ssha" != "-" ]] && fork_content_matches "$rt" "$ssha"; then
      # Clean at an older ref: the stager last wrote it and nobody has touched it
      # since. That is BEHIND — a refresh fixes it.
      printf '  %-22s %-9s staged %s  BEHIND %s\n' "$rt" "${ssha:0:7}" "$sat" "${sha:0:7}"
    else
      # Matches neither upstream nor the sha it claims: hand-edited, half-installed,
      # or staged before this mechanism existed. A refresh will overwrite it, and
      # whoever made the edit should know that before it happens.
      printf '  %-22s %-9s staged %s  MODIFIED — matches no ref (hand-edited or pre-DIVE-3269); a refresh will overwrite it\n' "$rt" "${ssha:0:7}" "$sat"
    fi
  done
}


# ---- entrypoint -------------------------------------------------------------
case "${1:-}" in
  --status) fork_status; exit 0 ;;
  "")       ;;
  *)        echo "5dive-stage-fork-plugins: unknown flag: $1" >&2; exit 2 ;;
esac

stage_fork_plugins
for _rt in $FORK_STAGED_CHANGED; do printf 'changed: %s\n' "$_rt"; done
exit 0
