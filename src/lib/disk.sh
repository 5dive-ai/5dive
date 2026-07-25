# -------- disk headroom + worktree reclaim (DIVE-1966 / DIVE-1967) --------
#
# Two jobs, in one file because they are the same lesson.
#
# 1. A FULL DISK IS NEVER AN ALERT. It surfaces as a failure in whatever touched
#    it next: an agent's memory write dying with ENOSPC mid-edit, a shell losing
#    stdout because the harness could not write its temp dir. Both read as "that
#    tool is broken", not "the host is out of disk". `5dive doctor` reporting
#    free space is how the host gets to report exhaustion AS ITSELF.
#
# 2. WHAT FILLS IT HERE IS STRUCTURAL: worktree-per-task with a full `npm
#    install` per worktree and no teardown at close. On 2026-07-25 the control
#    plane hit 100% of 75G with 184 worktrees live; `app-wt-*/node_modules`
#    alone was ~7.7GB at ~988MB each, most of it belonging to tasks already done.
#
# THE SAFETY BOUNDARY — nothing in this file may blur it:
#
#   node_modules INSIDE a worktree  -> SAFE to delete automatically.
#     gitignored, regenerable with `npm ci`. No commit or branch can live there,
#     so removal is STRUCTURALLY data-loss-free, not merely "probably fine".
#
#   the worktree DIRECTORY itself   -> NEVER deleted here, only REPORTED.
#     it may hold unpushed commits. Pruning it is a human/lead call, per the
#     refusal discipline in DIVE-1869/1955.

# Absolute free-space floors, in KiB. Absolute rather than percentage on purpose:
# ENOSPC is caused by bytes, not by ratios. 3% free is fine on a 2TB box and
# fatal on a 20G one, whereas "under 3 GiB" is a problem everywhere — one npm
# install is ~1 GiB. Overridable so a test harness can force each branch.
DISK_ERROR_KB="${FIVEDIVE_DISK_ERROR_KB:-3145728}"   # 3 GiB
DISK_WARN_KB="${FIVEDIVE_DISK_WARN_KB:-10485760}"    # 10 GiB

# Where per-task worktrees live. Depth 1 (<root>/app-wt-1959) and depth 2
# (<root>/5dive/5dive-cli-wt-1967) are both real layouts on this host.
WORKTREE_ROOT="${FIVEDIVE_WORKTREE_ROOT:-$DEFAULT_WORKDIR}"

disk_mount()    { df -P -k "$1" 2>/dev/null | awk 'NR==2{print $6}'; }
disk_free_kb()  { df -P -k "$1" 2>/dev/null | awk 'NR==2{print $4}'; }
disk_used_pct() { df -P -k "$1" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}'; }
disk_gb()       { awk -v kb="${1:-0}" 'BEGIN{printf "%.1f", kb/1048576}'; }

# wt_task_num <id|DIVE-N> — the bare number a worktree name would carry.
wt_task_num() {
  local n="${1##*-}"
  [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n"
}

# wt_candidates <num> — worktree dirs belonging to task <num>, one per line.
wt_candidates() {
  local num="$1" d base
  [[ "$num" =~ ^[0-9]+$ ]] || return 0
  [[ -d "$WORKTREE_ROOT" ]] || return 0
  while IFS= read -r d; do
    [[ -L "$d" ]] && continue
    base="${d##*/}"
    # The number must be INTRODUCED by a wt-/dive- marker and TERMINATED by a
    # non-digit or end-of-name. Without the terminator, closing DIVE-196 would
    # match app-wt-1960 — a different, possibly in-flight task's worktree.
    [[ "$base" =~ (^|[-_])(wt|dive)[-_]?(dive)?${num}([^0-9]|$) ]] || continue
    # A git WORKTREE has .git as a FILE (a `gitdir:` pointer); a primary clone
    # has it as a DIRECTORY. This single test is what keeps reclaim off the real
    # repos that sit in the same parent directory.
    [[ -f "$d/.git" ]] || continue
    printf '%s\n' "$d"
  done < <(find "$WORKTREE_ROOT" -mindepth 1 -maxdepth 2 \
             \( -name node_modules -o -name .git -o -name .next -o -name .venv \) -prune \
             -o -type d -print 2>/dev/null)
}

# wt_all — every git worktree under WORKTREE_ROOT, one per line.
wt_all() {
  local d
  while IFS= read -r d; do
    [[ -L "$d" ]] && continue
    [[ -f "$d/.git" ]] || continue
    printf '%s\n' "$d"
  done < <(find "$WORKTREE_ROOT" -mindepth 1 -maxdepth 2 \
             \( -name node_modules -o -name .git -o -name .next -o -name .venv \) -prune \
             -o -type d -print 2>/dev/null)
}

# wt_node_modules <worktree> — each node_modules tree inside it (pruned, so a
# monorepo's packages/*/node_modules are listed but not descended into).
wt_node_modules() {
  local wt="$1"
  [[ -d "$wt" && -f "$wt/.git" ]] || return 0
  find "$wt" -mindepth 1 -maxdepth 4 -type d -name node_modules -prune -print 2>/dev/null
}

# wt_size_kb <path> — apparent size, best effort.
#
# MEASUREMENT TRAP (DIVE-1966): `du` run as a NON-ROOT user silently undercounts
# — it skips what it cannot read and still exits 0. Treat this as a FLOOR, never
# as a figure to reconcile against `df`. The first survey of this incident showed
# /home at 34G against an actual 57G for exactly this reason.
wt_size_kb() {
  local kb
  kb=$(du -sk "$1" 2>/dev/null | awk '{print $1}')
  printf '%s' "${kb:-0}"
}

# wt_unpushed <worktree> — one line saying why the DIRECTORY must not be pruned,
# or nothing when it is provably reclaimable.
#
# FAIL-CLOSED: every unreadable case (not a repo, no upstream, git missing)
# returns a REASON, because "I could not look" must never render as "nothing
# there" — the DIVE-1869 empty-output-is-not-an-empty-answer class.
wt_unpushed() {
  local wt="$1" dirty br ahead
  command -v git >/dev/null 2>&1 || { printf 'git unavailable — cannot prove pushed\n'; return 0; }
  if ! dirty=$(git -C "$wt" status --porcelain 2>/dev/null); then
    printf 'not a readable git worktree — cannot prove pushed\n'; return 0
  fi
  if [[ -n "$dirty" ]]; then
    printf '%s uncommitted path(s)\n' "$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')"; return 0
  fi
  br=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null) || br=""
  [[ -n "$br" ]] || { printf 'unreadable HEAD — cannot prove pushed\n'; return 0; }
  if ! ahead=$(git -C "$wt" rev-list --count '@{upstream}..HEAD' 2>/dev/null) \
     || [[ ! "$ahead" =~ ^[0-9]+$ ]]; then
    printf 'no upstream for %s — cannot prove pushed\n' "$br"; return 0
  fi
  (( ahead > 0 )) && printf '%s unpushed commit(s) on %s\n' "$ahead" "$br"
  return 0
}

# wt_reclaim_node_modules <worktree> [dry] — delete every node_modules tree in
# it. Echoes "<kb> <removed> <failed>". `dry` measures without deleting.
#
# Cross-user reclaim is NOT attempted with elevated rights: a worktree owned by
# another agent (mode 0755) fails the rm and is counted in <failed> rather than
# silently skipped, so the caller can report the residue instead of implying it
# reclaimed it. The common case — an agent closing its own task, whose worktree
# it created — is owner-writable and succeeds.
wt_reclaim_node_modules() {
  local wt="$1" dry="${2:-}" nm sz kb=0 removed=0 failed=0
  while IFS= read -r nm; do
    [[ -n "$nm" ]] || continue
    # Re-assert every invariant AT THE POINT OF DELETION, not only at discovery.
    [[ "${nm##*/}" == "node_modules" ]] || continue
    [[ "$nm" == "$wt"/* ]] || continue
    [[ -L "$nm" ]] && continue
    sz=$(wt_size_kb "$nm")
    if [[ -n "$dry" ]]; then
      kb=$((kb + sz)); removed=$((removed + 1)); continue
    fi
    if rm -rf -- "$nm" 2>/dev/null && [[ ! -e "$nm" ]]; then
      kb=$((kb + sz)); removed=$((removed + 1))
    else
      failed=$((failed + 1))
    fi
  done < <(wt_node_modules "$wt")
  printf '%s %s %s\n' "$kb" "$removed" "$failed"
}
