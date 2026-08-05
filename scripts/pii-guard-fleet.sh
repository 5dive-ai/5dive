#!/usr/bin/env bash
# Fleet enumerator for the pre-push PII guard (DIVE-2788).
#
# THE ROW THIS CLOSES. Four rows of PII program (DIVE-1774 scanner, DIVE-1797
# enforcement, DIVE-2267 range scan, DIVE-2268 push rail) were each scoped to
# one repo, and nobody enumerated the population — so "the class is closed
# going forward" was true for 5dive-ai/5dive and false for the fleet.
#
# SO THIS TOOL'S OUTPUT IS A POPULATION, NOT A VERDICT. Every run prints, above
# any result: which roots it walked, how many checkouts it found, how it
# de-duplicated them into remotes, and — per remote — WHERE the answer came
# from (a local checkout, naming the ref and its date, or a fresh clone). The
# three measurement errors recorded on DIVE-2788 were all the same shape:
#
#   * `ls -d */` at the top level missed 12 nested checkouts and one hidden
#     top-level dir, so a live push remote inside marketing/.work was invisible.
#     Here: `find -name .git` at any depth, hidden included.
#   * `refs/remotes/origin/*` out of a stale checkout reported 11 remote
#     branches where the remote has 1. A remote-tracking ref is a CACHED CLAIM
#     about the remote, not the remote. Here: every row says which it read.
#   * a `--depth=1` clone reported "0 of 1 branches" — that 1 was the shallow
#     clone's only fetched ref. Here: --fresh clones are full.
#
# A repo that cannot be read reads clean, which is indistinguishable from being
# clean. So an unreadable target is its own outcome (UNKNOWN), never folded into
# the clean count. Same for visibility: no `gh` auth means UNKNOWN, not private.
#
# Usage:
#   scripts/pii-guard-fleet.sh                    # enumerate + report, change nothing
#   scripts/pii-guard-fleet.sh --install          # also install the guard on each clone
#   scripts/pii-guard-fleet.sh --scan             # also full-tree scan each clone
#   scripts/pii-guard-fleet.sh --scan --fresh     # scan fresh clones of each REMOTE
#   scripts/pii-guard-fleet.sh --root DIR         # repeatable; default /home/*/projects
#
# A pre-push guard grades the diff being pushed, so it is STRUCTURALLY BLIND to
# what is already committed. --scan is the one-off residue pass that answers the
# other half; installing the guard does not clean the repo.
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SELF_DIR/install-pii-push-guard.sh"
SCANNER="$SELF_DIR/pii-scan.sh"
DENYLIST="${PII_DENYLIST:-$SELF_DIR/../.github/pii-denylist.txt}"

DO_INSTALL=0; DO_SCAN=0; DO_FRESH=0
ROOTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) DO_INSTALL=1 ;;
    --scan)    DO_SCAN=1 ;;
    --fresh)   DO_FRESH=1 ;;
    --root)    shift; ROOTS+=("${1:-}") ;;
    -h|--help) sed -n '1,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
if [[ ${#ROOTS[@]} -eq 0 ]]; then
  for d in /home/*/projects; do [[ -d "$d" ]] && ROOTS+=("$d"); done
fi

hr() { printf '%s\n' "------------------------------------------------------------------------"; }

echo "pii-guard-fleet (DIVE-2788)"
echo "run_at:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "scanner:       $SCANNER"
echo "denylist:      $DENYLIST ($(grep -cE '^[0-9a-fA-F]{64}' "$DENYLIST" 2>/dev/null || echo 0) entries)"
echo "install:       $DO_INSTALL   scan: $DO_SCAN   fresh-clone: $DO_FRESH"
echo "roots walked:  ${ROOTS[*]}"
hr

# ── 1. enumerate checkouts ────────────────────────────────────────────────────
# -name .git catches BOTH a real .git directory and the .git FILE a linked
# worktree carries, and find descends into hidden directories by default — the
# two things the original `ls -d */` enumeration could not do.
CHECKOUTS=()
unreadable=0
while IFS= read -r g; do
  CHECKOUTS+=("$(dirname "$g")")
done < <(for r in "${ROOTS[@]}"; do find "$r" -name .git -prune 2>/dev/null; done | sort -u)
# Count roots we could not fully walk, so "found N" is never read as "there are N".
for r in "${ROOTS[@]}"; do [[ -r "$r" ]] || unreadable=$((unreadable+1)); done

echo "checkouts found:      ${#CHECKOUTS[@]}"
echo "roots unreadable:     $unreadable  (their contents are UNKNOWN, not zero)"

# ── 2. dedupe to CLONES (worktrees share a git-common-dir) and to REMOTES ─────
declare -A CLONE_OF_COMMON=() REMOTE_OF_COMMON=() CLONES_OF_REMOTE=() NOREMOTE=()
for c in "${CHECKOUTS[@]}"; do
  common="$(git -C "$c" rev-parse --git-common-dir 2>/dev/null)" || continue
  case "$common" in /*) ;; *) common="$(cd "$c" && cd "$common" 2>/dev/null && pwd)" || continue ;; esac
  url="$(git -C "$c" config --get remote.origin.url 2>/dev/null || true)"
  if [[ -z "$url" ]]; then NOREMOTE["$common"]="$c"; continue; fi
  # normalise ssh/https/.git to owner/repo
  slug="${url%.git}"; slug="${slug##*github.com[:/]}"; slug="${slug##*github.com/}"; slug="${slug##*github.com:}"
  [[ -z "${CLONE_OF_COMMON[$common]:-}" ]] && CLONE_OF_COMMON["$common"]="$c"
  REMOTE_OF_COMMON["$common"]="$slug"
  CLONES_OF_REMOTE["$slug"]="${CLONES_OF_REMOTE[$slug]:-}${CLONE_OF_COMMON[$common]}
"
done

echo "distinct clones:      ${#CLONE_OF_COMMON[@]}  (worktrees folded by git-common-dir)"
echo "clones with NO origin: ${#NOREMOTE[@]}  (skipped: nothing is pushed anywhere)"
echo "distinct remotes:     ${#CLONES_OF_REMOTE[@]}"
hr

# ── 3. per-remote report ──────────────────────────────────────────────────────
printf '%-42s %-9s %-38s %-22s %s\n' REMOTE VISIBILITY GUARD "RESIDUE(source)" CLONE
guarded=0; unguarded=0; resid_hits=0; resid_unknown=0
tmproot=""; [[ $DO_FRESH -eq 1 ]] && tmproot="$(mktemp -d)"

for slug in $(printf '%s\n' "${!CLONES_OF_REMOTE[@]}" | sort); do
  clone="$(printf '%s' "${CLONES_OF_REMOTE[$slug]}" | head -1)"

  vis=UNKNOWN
  if command -v gh >/dev/null 2>&1; then
    v="$(gh repo view "$slug" --json visibility -q .visibility 2>/dev/null || true)"
    [[ -n "$v" ]] && vis="$v"
  fi

  why=""
  if [[ $DO_INSTALL -eq 1 ]]; then
    ierr="$(bash "$INSTALLER" "$clone" 2>&1 >/dev/null)"; irc=$?
    if [[ $irc -ne 0 ]]; then
      # A failed install that reports only "not installed" is the silent shape
      # this row is about — the reason is the actionable half. The overwhelming
      # case on a multi-agent host is a checkout owned by another uid, so name
      # the owner and RETRY AS THEM, which is the one thing that can fix it.
      owner="$(stat -c %U "$clone/.git" 2>/dev/null || stat -c %U "$clone" 2>/dev/null || echo '?')"
      case "$ierr" in
        *"Permission denied"*|*"could not set core.hooksPath"*)
          if [[ "$owner" != "?" && "$owner" != "$(id -un)" ]] \
             && sudo -n -u "$owner" bash "$INSTALLER" "$clone" >/dev/null 2>&1; then
            why=":installed-as-$owner"
          else
            why=":EPERM(owner=$owner)"
          fi ;;
        *REFUSING*) why=":refused-foreign-hooksPath" ;;
        *)          why=":install-rc$irc" ;;
      esac
    fi
  fi
  guard="$(bash "$INSTALLER" --status "$clone" 2>/dev/null | awk -F'\t' '{print $3}')"
  guard="${guard:-UNKNOWN}${why}"
  case "$guard" in none*|UNKNOWN*) unguarded=$((unguarded+1)) ;; *) guarded=$((guarded+1)) ;; esac

  residue="not-run"
  if [[ $DO_SCAN -eq 1 ]]; then
    src="local:$clone"; scandir="$clone"
    if [[ $DO_FRESH -eq 1 ]]; then
      scandir="$tmproot/${slug//\//__}"
      if gh repo clone "$slug" "$scandir" -- --quiet >/dev/null 2>&1; then
        src="fresh-clone"
      else
        scandir=""; src="fresh-clone-FAILED"
      fi
    fi
    if [[ -z "$scandir" ]]; then
      residue="UNKNOWN"; resid_unknown=$((resid_unknown+1))
    else
      ref="$(git -C "$scandir" rev-parse --short HEAD 2>/dev/null || echo NOHEAD)"
      when="$(git -C "$scandir" log -1 --format=%cs 2>/dev/null || echo '?')"
      # Scan every TRACKED file at HEAD. The whole tree is streamed through ONE
      # scanner process — a per-file loop is O(files) bash spawns and does not
      # finish on a fleet this size, which in practice means it does not get run,
      # which is how the population went unmeasured in the first place.
      if git -C "$scandir" archive HEAD 2>/dev/null | tar -xO 2>/dev/null \
           | PII_DENYLIST="$DENYLIST" bash "$SCANNER" >/dev/null 2>&1; then
        residue="clean($src@$ref/$when)"
      else
        # Only now pay for the per-file pass, and only for this repo: the
        # aggregate scan says THAT there is residue, the per-file pass says
        # WHERE, and a finding nobody can locate is not actionable.
        files=""
        while IFS= read -r f; do
          git -C "$scandir" show "HEAD:$f" 2>/dev/null \
            | PII_DENYLIST="$DENYLIST" bash "$SCANNER" >/dev/null 2>&1 || files="$files $f"
        done < <(git -C "$scandir" ls-tree -r --name-only HEAD 2>/dev/null)
        n=$(wc -w <<<"$files")
        residue="$n HIT($src@$ref/$when)"; resid_hits=$((resid_hits+1))
        HIT_DETAIL="${HIT_DETAIL:-}$slug:$files"$'\n'
      fi
    fi
  fi

  printf '%-42s %-9s %-38s %-22s %s\n' "$slug" "$vis" "$guard" "$residue" "$clone"
done
[[ -n "$tmproot" ]] && rm -rf "$tmproot"

hr
echo "guarded:   $guarded"
echo "unguarded: $unguarded"
if [[ $DO_SCAN -eq 1 ]]; then
  echo "residue:   $resid_hits remote(s) with hits, $resid_unknown UNKNOWN (unreadable — NOT counted clean)"
  if [[ -n "${HIT_DETAIL:-}" ]]; then
    echo
    echo "residue detail (repo: files carrying a denylisted value at HEAD):"
    printf '%s' "$HIT_DETAIL"
  fi
fi
echo
echo "READ THIS AS A POPULATION, NOT A VERDICT: the rows above cover exactly the"
echo "roots printed at the top. A repo cloned somewhere else is neither guarded"
echo "nor reported here, and this tool cannot tell you it exists."
[[ $unguarded -gt 0 || $resid_hits -gt 0 ]] && exit 1
exit 0
