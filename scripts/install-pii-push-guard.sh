#!/usr/bin/env bash
# Install the pre-push PII guard (DIVE-1797 enforcement; DIVE-2788 fleet reach).
#
# ── TWO MODES, AND WHY ────────────────────────────────────────────────────────
#
# in-repo   (5dive-ai/5dive only)  core.hooksPath=scripts/git-hooks — a RELATIVE
#           path, so each push is gated by the hook committed on the branch it
#           is pushing, and that hook carries this repo's other guards
#           (version-bump, harness-tree, actionlint) alongside PII. One install
#           per CLONE covers the whole worktree family: core.hooksPath lives in
#           the shared clone config, so every existing linked worktree and every
#           future `git worktree add` inherits it.
#
# portable  (every other repo)     core.hooksPath=<guard home> — an ABSOLUTE
#           path to a directory outside every repo, holding a PII-only hook, a
#           copy of scripts/pii-scan.sh and a copy of .github/pii-denylist.txt.
#           See scripts/git-hooks-portable/pre-push.
#
# Until DIVE-2788 the relative path was the ONLY mode, and it is why the guard
# could not be installed anywhere else: a relative hooksPath resolves inside the
# target repo, and no other repo on the fleet carries scripts/git-hooks,
# scripts/pii-scan.sh or .github/pii-denylist.txt. The measured consequence was
# four rows of PII program, twenty-two remotes, one repo covered — while this
# script's own docstring said "fleet-wide".
#
# ── WHY THE DENYLIST IS READ FROM A HOST PATH AND NOT SHIPPED TO EACH REPO ────
#
# DIVE-2788 asked for this decision to be made deliberately and written down.
#
# It is NOT a secrecy constraint. The denylist stores sha256 hashes only, never
# plaintext (DIVE-1774's design), and is already committed to a PUBLIC repo.
# Publishing it to twenty-two more would leak nothing.
#
# The constraint is DRIFT, and it is the same defect this row exists to fix.
# Shipping scanner+denylist into each repo creates N copies that must each be
# updated when an identifier is added. A denylist current in one repo and stale
# in twenty-one is a guard that reports itself installed while grading against a
# population that no longer matches — which is exactly how "the class is closed
# going forward" came to be written down and be false. One host copy is one
# update point, and `--sync` re-materialises it for every repo at once.
#
# Secondary, and decisive on its own: shipping into each repo needs a COMMIT in
# each repo — twenty-two PRs, on public repos, each with its own review and CI,
# with the guard dead until every one of them merges.
#
# THE COST, STATED. An absolute hooksPath is not versioned with the branch and
# does not travel with a fresh clone on a new box: a repo cloned somewhere the
# installer has not run is unguarded, silently. That is why
# `scripts/pii-guard-fleet.sh` exists and why it PRINTS its population instead
# of returning a verdict — "which checkouts are covered" has to be answerable by
# measurement, never by assuming the installer reached them.
#
# Idempotent. Safe to re-run from the daily update path and from install.sh.
#
# Usage:
#   scripts/install-pii-push-guard.sh [repo-dir]        # default: this repo
#   scripts/install-pii-push-guard.sh --sync            # refresh guard home only
#   scripts/install-pii-push-guard.sh --status [dir]    # report, change nothing
#
# Env:
#   PII_GUARD_HOME      override the guard home (default below)
#   PII_GUARD_SRC_SHA   provenance for the INSTALLED stamp when this script runs
#                       from a STAGED copy with no .git (install.sh's provisioning
#                       path, DIVE-2803). Ignored whenever $SRC_REPO is a git tree.
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC_REPO="$(cd -- "$SELF_DIR/.." && pwd)"

# Default guard home: a shared host path, so every agent uid on the box reads
# ONE copy. Falls back to a per-user path when the shared one is not writable
# and sudo is unavailable — announced, never silent, because a per-user guard
# home reintroduces exactly the drift the shared one exists to avoid.
GUARD_HOME_SHARED="/usr/local/share/5dive/pii-guard"
GUARD_HOME_USER="${XDG_DATA_HOME:-$HOME/.local/share}/5dive/pii-guard"

MODE=install
TARGET=""
for a in "$@"; do
  case "$a" in
    --sync)    MODE=sync ;;
    --status)  MODE=status ;;
    -h|--help) sed -n '1,64p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)         TARGET="$a" ;;
  esac
done
DIR="${TARGET:-$SRC_REPO}"

say() { echo "pii-push-guard: $*" >&2; }

resolve_guard_home() {
  if [[ -n "${PII_GUARD_HOME:-}" ]]; then printf '%s' "$PII_GUARD_HOME"; return 0; fi
  if [[ -w "$GUARD_HOME_SHARED" ]] || mkdir -p "$GUARD_HOME_SHARED" 2>/dev/null; then
    printf '%s' "$GUARD_HOME_SHARED"; return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n mkdir -p "$GUARD_HOME_SHARED" 2>/dev/null; then
    sudo -n chmod 0755 "$GUARD_HOME_SHARED" 2>/dev/null || true
    printf '%s' "$GUARD_HOME_SHARED"; return 0
  fi
  printf '%s' "$GUARD_HOME_USER"
}

# Materialise the guard home from THIS checkout. Copies are stamped with their
# provenance, so a reader of an installed guard can say which tree it came from
# and when — an installed artifact that cannot name its source is the same
# unnamed-target problem as a harness that cannot name its tree.
sync_guard_home() {
  local home="$1" rc=0 sudo_pfx=""
  if ! mkdir -p "$home" 2>/dev/null; then
    if command -v sudo >/dev/null 2>&1 && sudo -n mkdir -p "$home" 2>/dev/null; then
      sudo_pfx="sudo -n"
    else
      say "cannot create guard home $home"; return 1
    fi
  fi
  [[ -z "$sudo_pfx" && ! -w "$home" ]] && sudo_pfx="sudo -n"
  local hook="$SRC_REPO/scripts/git-hooks-portable/pre-push"
  local scan="$SRC_REPO/scripts/pii-scan.sh"
  local deny="$SRC_REPO/.github/pii-denylist.txt"
  local f
  for f in "$hook" "$scan" "$deny"; do
    [[ -f "$f" ]] || { say "source file missing: $f — guard home NOT synced"; return 1; }
  done
  $sudo_pfx cp -f "$hook" "$home/pre-push"          || rc=1
  $sudo_pfx cp -f "$scan" "$home/pii-scan.sh"       || rc=1
  $sudo_pfx cp -f "$deny" "$home/pii-denylist.txt"  || rc=1
  $sudo_pfx chmod 0755 "$home/pre-push" 2>/dev/null || true
  $sudo_pfx chmod 0644 "$home/pii-scan.sh" "$home/pii-denylist.txt" 2>/dev/null || true
  # The stamp must not name a sha that does not contain what was just copied.
  # Syncing from a dirty tree is the NORMAL case while a change is in review, so
  # a bare sha here would assert provenance the bytes do not have — this row's
  # own defect class, inside the artifact meant to make provenance readable.
  # Three states, never two: clean sha, sha+uncommitted, or UNKNOWN.
  #
  # DIVE-2803 adds a FOURTH source, not a fourth state. Provisioning stages this
  # script and its three payload files out of the pinned release tree into
  # $LIB_DIR (a fresh box has no checkout to run from), so $SRC_REPO there is a
  # plain directory with no .git — every run would stamp UNKNOWN for a payload
  # whose commit is precisely known. PII_GUARD_SRC_SHA supplies it, and is read
  # ONLY when there is no git tree to contradict it: a dirty checkout must never
  # be able to launder itself into a clean sha by exporting the variable. It is
  # also shape-checked, because a stamp that names a non-sha is worse than one
  # that admits UNKNOWN.
  local sha
  if sha="$(git -C "$SRC_REPO" rev-parse --short HEAD 2>/dev/null)" && [[ -n "$sha" ]]; then
    if ! git -C "$SRC_REPO" diff --quiet HEAD -- scripts .github/pii-denylist.txt 2>/dev/null; then
      sha="$sha+uncommitted"
    fi
  elif [[ "${PII_GUARD_SRC_SHA:-}" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    sha="${PII_GUARD_SRC_SHA:0:12}"
  else
    sha=UNKNOWN
  fi
  printf 'source_repo=%s\nsource_sha=%s\ninstalled_at=%s\ndenylist_entries=%s\n' \
    "$SRC_REPO" "$sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(grep -cE '^[0-9a-fA-F]{64}' "$deny" 2>/dev/null || echo 0)" \
    | $sudo_pfx tee "$home/INSTALLED" >/dev/null || rc=1
  return $rc
}

GUARD_HOME="$(resolve_guard_home)"
if [[ "$GUARD_HOME" == "$GUARD_HOME_USER" && -z "${PII_GUARD_HOME:-}" ]]; then
  say "NOTE: shared guard home not writable; using per-user $GUARD_HOME (one copy PER UID — re-run as each uid)."
fi

if [[ "$MODE" == sync ]]; then
  sync_guard_home "$GUARD_HOME" && { say "guard home synced: $GUARD_HOME"; exit 0; }
  exit 1
fi

# ── target classification ─────────────────────────────────────────────────────
url="$(git -C "$DIR" config --get remote.origin.url 2>/dev/null || true)"
top="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
common="$(git -C "$DIR" rev-parse --git-common-dir 2>/dev/null || true)"
current="$(git -C "$DIR" config --local --get core.hooksPath 2>/dev/null || true)"

if [[ -z "$top" ]]; then
  say "$DIR has no worktree — skipping."
  exit 0
fi
if [[ -z "$url" ]]; then
  # No origin: a scratch or local-only repo. Nothing reaches a remote, and
  # listing it as "unguarded" in a fleet report would be a false positive.
  say "$DIR has no remote.origin.url — skipping (nothing is pushed anywhere)."
  exit 0
fi

# Match the origin so ssh/https and with/without .git all resolve, but anchor on
# the repo NAME so 5dive-ai/5dive-plugins and 5dive-ai/5dive-mcp are NOT swept
# into in-repo mode by a `*5dive-ai/5dive*` prefix match. They carry no
# scripts/git-hooks, so the old loose glob would have set a relative hooksPath
# pointing at a directory that does not exist — a guard installed onto nothing.
case "$url" in
  *5dive-ai/5dive|*5dive-ai/5dive.git|*5dive-ai/5dive/) kind=in-repo ;;
  *)                                                    kind=portable ;;
esac

if [[ "$MODE" == status ]]; then
  installed=none
  if [[ -z "$current" ]]; then
    installed=none
  elif [[ "$kind" == in-repo && "$current" == "scripts/git-hooks" ]]; then
    installed=in-repo
  elif [[ "$kind" == portable && "$current" == "$GUARD_HOME" ]]; then
    installed=portable
  else
    installed="other"
  fi
  printf '%s\t%s\t%s\t%s\n' "$url" "$kind" "$installed" "$common"
  exit 0
fi

if [[ "$kind" == in-repo ]]; then
  if [[ "$current" != "scripts/git-hooks" ]]; then
    git -C "$DIR" config --local core.hooksPath scripts/git-hooks
  fi
  [[ -f "$top/scripts/git-hooks/pre-push" ]] && chmod +x "$top/scripts/git-hooks/pre-push" 2>/dev/null || true
  echo "pii-push-guard: in-repo mode — core.hooksPath=scripts/git-hooks on $common"
  exit 0
fi

# ── portable mode ─────────────────────────────────────────────────────────────
sync_guard_home "$GUARD_HOME" || { say "guard home not usable — $DIR left UNGUARDED."; exit 1; }

# A pre-existing hooksPath that is neither ours nor unset is somebody else's
# control. REFUSE rather than clobber: hooksPath is single-valued, so "install"
# here would silently mean "delete theirs", and this row exists precisely
# because a guard that covers less than it claims did real damage.
if [[ -n "$current" && "$current" != "$GUARD_HOME" ]]; then
  say "REFUSING: $DIR already has core.hooksPath=$current (not ours). Chain it manually or unset it first."
  exit 1
fi

# $GIT_DIR/hooks/pre-push is NOT clobbered — the portable hook chains to it.
# lodar/5dive-frontend has one (the DIVE-2203 direct-push-to-main reminder), and
# a naive install would have disabled it while reporting a guard installed.
# Resolved from the git COMMON dir, NOT via `rev-parse --git-path hooks/...`:
# that form honours core.hooksPath, so once ours is set it reports the guard
# home's own hook back to us. See the chain() note in git-hooks-portable/pre-push.
own_hook=""
if [[ -n "$common" ]]; then
  case "$common" in /*) abs_common="$common" ;; *) abs_common="$(cd -- "$DIR" && cd -- "$common" 2>/dev/null && pwd)" ;; esac
  [[ -n "${abs_common:-}" && -x "$abs_common/hooks/pre-push" ]] && own_hook="$abs_common/hooks/pre-push"
fi
chained=""
[[ -n "$own_hook" ]] && chained=" (chaining existing $own_hook)"

git -C "$DIR" config --local core.hooksPath "$GUARD_HOME" || {
  say "could not set core.hooksPath on $DIR"; exit 1; }

echo "pii-push-guard: portable mode — core.hooksPath=$GUARD_HOME on $common$chained"
