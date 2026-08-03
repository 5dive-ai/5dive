#!/usr/bin/env bash
# TIER: nightly — 41.0s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-1967: closing a task reclaims its worktree's node_modules — and NOTHING
# else. The whole value of this feature is the boundary it refuses to cross, so
# most of what is asserted below is what must SURVIVE a reclaim:
#   - a sibling task's worktree whose number merely shares a prefix (196/1960)
#   - a primary clone that happens to sit in the same parent directory
#   - a worktree whose task is still in_progress
#   - the worktree DIRECTORY itself, always, even when provably clean
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/wt-reclaim-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/disk.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
jf()    { jq -r "$1" 2>/dev/null; }
# DIVE-2062: _task_reclaim_on_close's own "task reclaim" audit_log call (routed
# through _task_store_audit_log, DIVE-2010/2054) was reached by NO tests_*/
# gate_*/heartbeat_*/audit_* suite per the DIVE-2054 verifier pass (dev3,
# 2026-07-26) — a scope artifact of that sweep's glob (this file is named
# worktree_*, not task_*), not evidence the site itself was unreached; every
# `cmd_task_done` call below already drives it. Stub audit_log so the two new
# cases further down can assert on/off-store behaviour without ever touching
# the real fleet log.
AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }

ROOT="$TMP/projects"
WORKTREE_ROOT="$ROOT"     # disk.sh reads this global on every call
mkdir -p "$ROOT"

# A fake worktree: .git as a FILE is the marker git itself uses (a primary clone
# has .git as a DIRECTORY), and it is the only thing standing between this
# reclaim and a real repo.
mk_wt() {
  local d="$ROOT/$1"
  mkdir -p "$d/node_modules/some-pkg" "$d/src"
  printf 'gitdir: /nonexistent/.git/worktrees/%s\n' "$1" >"$d/.git"
  head -c 4096 /dev/zero >"$d/node_modules/some-pkg/index.js"
  printf 'real source, must survive\n' >"$d/src/keep.txt"
}
mk_clone() {
  local d="$ROOT/$1"
  mkdir -p "$d/.git" "$d/node_modules/some-pkg"
  head -c 4096 /dev/zero >"$d/node_modules/some-pkg/index.js"
}

mk_wt proj-wt-196
mk_wt proj-wt-1960
mk_wt proj-wt-500
mk_clone proj

# ---------------------------------------------------------------- matching
got=$(wt_candidates 196 | sed "s#^$ROOT/##" | sort | tr '\n' ' ')
[[ "$got" == "proj-wt-196 " ]] \
  && ok_t "task 196 matches only proj-wt-196, not the prefix-sharing proj-wt-1960" \
  || bad_t "anchored number match" "got='$got'"

got=$(wt_candidates 500 | sed "s#^$ROOT/##" | tr -d '\n')
[[ "$got" == "proj-wt-500" ]] && ok_t "task 500 matches its own worktree" || bad_t "basic match" "got='$got'"

got=$(wt_all | sed "s#^$ROOT/##" | sort | tr '\n' ' ')
[[ "$got" == "proj-wt-196 proj-wt-1960 proj-wt-500 " ]] \
  && ok_t "wt_all sees the 3 worktrees and NOT the primary clone" \
  || bad_t "wt_all excludes primary clone" "got='$got'"

# ---------------------------------------------------------------- close reclaims
tasks_db_init
mkt() { # mkt <forced-id> <title> -> id
  local out tid
  out=$(USER=agent-dev cmd_task_add --assignee=dev -- "$2" 2>/dev/null)
  tid=$(printf '%s' "$out" | jf '.data.id')
  # A worktree name encodes the IDENT number (DIVE-1967), which is a per-project
  # counter — NOT the row id. Force the ident so the fixture matches reality.
  db "UPDATE tasks SET ident='DIVE-$1' WHERE id=${tid};"
  printf '%s' "$1"
}
mkt 196  "reclaim fixture 196"  >/dev/null
mkt 1960 "reclaim fixture 1960" >/dev/null
mkt 500  "reclaim fixture 500"  >/dev/null
db "UPDATE tasks SET status='in_progress' WHERE ident='DIVE-500';"

USER=agent-dev cmd_task_done DIVE-196 --result="done" >/dev/null 2>"$TMP/err"
[[ ! -d "$ROOT/proj-wt-196/node_modules" ]] \
  && ok_t "close reclaimed the closed task's node_modules" \
  || bad_t "close reclaim" "$(cat "$TMP/err")"
[[ -d "$ROOT/proj-wt-196" && -f "$ROOT/proj-wt-196/src/keep.txt" && -f "$ROOT/proj-wt-196/.git" ]] \
  && ok_t "the worktree DIRECTORY and its tracked files survive the reclaim" \
  || bad_t "worktree survives"
[[ -d "$ROOT/proj-wt-1960/node_modules" ]] \
  && ok_t "the prefix-sharing sibling worktree is untouched" \
  || bad_t "sibling untouched"
[[ -d "$ROOT/proj/node_modules" ]] \
  && ok_t "the primary clone in the same parent dir is untouched" \
  || bad_t "primary clone untouched"

# ---------------------------------------------------------------- audit fence
# DIVE-2062: the "task reclaim" row _task_reclaim_on_close writes is
# task-store state (a reclaim stat for THIS task's worktrees), so it is fenced
# on store identity exactly like the other DIVE-2054 sites. Mirrors
# tests/heartbeat_gate_shipped_unit.sh Case 12's on/off-store pattern for this
# cmd_task.sh site.
mk_wt proj-wt-800
mkt 800 "reclaim fixture 800 (audit on-store)" >/dev/null
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
USER=agent-dev cmd_task_done DIVE-800 --result="done" >/dev/null 2>"$TMP/err-onstore"
grep -q 'task reclaim.*DIVE-800.*worktrees=1' "$AUDIT_CALLS" \
  && ok_t "on-store: closing a task with a reclaimable worktree audits 'task reclaim'" \
  || bad_t "on-store audit row" "$(cat "$AUDIT_CALLS")"
unset FIVEDIVE_PROD_TASKS_DB

: >"$AUDIT_CALLS"
unset _TASK_STORE_AUDIT_FENCED
mk_wt proj-wt-801
mkt 801 "reclaim fixture 801 (audit off-store)" >/dev/null
USER=agent-dev cmd_task_done DIVE-801 --result="done" >/dev/null 2>"$TMP/err-offstore"
[[ ! -d "$ROOT/proj-wt-801/node_modules" ]] \
  && ok_t "off-store: the reclaim itself still runs (fail-open on the WRITE side)" \
  || bad_t "off-store reclaim still runs" "$(ls "$ROOT/proj-wt-801" 2>&1)"
[[ ! -s "$AUDIT_CALLS" ]] \
  && ok_t "off the prod store, task reclaim writes NO audit row" \
  || bad_t "off-store must not audit" "$(cat "$AUDIT_CALLS")"
grep -q "telemetry withheld" "$TMP/err-offstore" \
  && ok_t "the withholding is ANNOUNCED, not silent" \
  || bad_t "fence must announce" "err=$(cat "$TMP/err-offstore")"
unset _TASK_STORE_AUDIT_FENCED

# ---------------------------------------------------------------- escape hatches
# These are what an operator reaches for when the reclaim misbehaves at 3am, so
# each is asserted WITH a negative control: the same fixture, the same close,
# hatch removed, must reclaim. Without the control, a hatch assertion passes just
# as happily when the reclaim is broken outright (Marcus, DIVE-1967 review).
USER=agent-dev cmd_task_done DIVE-1960 --keep-worktree --result="keep" >/dev/null 2>"$TMP/err"
[[ -d "$ROOT/proj-wt-1960/node_modules" ]] \
  && ok_t "--keep-worktree skips the reclaim" \
  || bad_t "--keep-worktree" "$(cat "$TMP/err")"
db "UPDATE tasks SET status='todo' WHERE ident='DIVE-1960';"
USER=agent-dev cmd_task_done DIVE-1960 --result="control" >/dev/null 2>"$TMP/err"
[[ ! -d "$ROOT/proj-wt-1960/node_modules" ]] \
  && ok_t "negative control: the same close WITHOUT --keep-worktree does reclaim" \
  || bad_t "--keep-worktree negative control" "$(cat "$TMP/err")"

mk_wt proj-wt-1960
db "UPDATE tasks SET status='todo' WHERE ident='DIVE-1960';"
FIVEDIVE_NO_WT_RECLAIM=1 USER=agent-dev cmd_task_done DIVE-1960 --result="off" >/dev/null 2>"$TMP/err"
[[ -d "$ROOT/proj-wt-1960/node_modules" ]] \
  && ok_t "FIVEDIVE_NO_WT_RECLAIM=1 disables the reclaim" \
  || bad_t "env kill-switch" "$(cat "$TMP/err")"
db "UPDATE tasks SET status='todo' WHERE ident='DIVE-1960';"
USER=agent-dev cmd_task_done DIVE-1960 --result="control" >/dev/null 2>"$TMP/err"
[[ ! -d "$ROOT/proj-wt-1960/node_modules" ]] \
  && ok_t "negative control: with FIVEDIVE_NO_WT_RECLAIM unset the same close does reclaim" \
  || bad_t "env kill-switch negative control" "$(cat "$TMP/err")"

# ---------------------------------------------------------------- sweep
mk_wt proj-wt-1960
db "UPDATE tasks SET status='done' WHERE ident='DIVE-1960';"
# --dry-run must measure and delete nothing.
out=$(USER=agent-dev cmd_task_reclaim --all --dry-run 2>"$TMP/err")
[[ "$(printf '%s' "$out" | jf '.data.dry_run')" == "true" && -d "$ROOT/proj-wt-1960/node_modules" ]] \
  && ok_t "--dry-run reports without deleting" \
  || bad_t "--dry-run" "$out $(cat "$TMP/err")"

# The live task's worktree must be skipped by the sweep, reported as skipped.
out=$(USER=agent-dev cmd_task_reclaim --all 2>"$TMP/err")
skipped=$(printf '%s' "$out" | jf '.data.skipped_live')
[[ "$skipped" == "1" && -d "$ROOT/proj-wt-500/node_modules" ]] \
  && ok_t "--all skips the in_progress task's worktree and says so" \
  || bad_t "live-task skip" "skipped=$skipped out=$out"
[[ ! -d "$ROOT/proj-wt-1960/node_modules" ]] \
  && ok_t "--all reclaims the closed/absent tasks' worktrees" \
  || bad_t "sweep reclaims dead"
# A reclaim that silently declines to act is indistinguishable from one that
# found nothing to do — the skip must be NAMED on the acting path too.
grep -q "skip .*proj-wt-500.*live" "$TMP/err" \
  && ok_t "the non-dry-run sweep names each skipped worktree and why" \
  || bad_t "skip is logged" "$(cat "$TMP/err")"

db "UPDATE tasks SET status='blocked' WHERE ident='DIVE-500';"
out=$(USER=agent-dev cmd_task_reclaim --all 2>"$TMP/err")
[[ "$(printf '%s' "$out" | jf '.data.skipped_live')" == "1" && -d "$ROOT/proj-wt-500/node_modules" ]] \
  && ok_t "--all also skips a BLOCKED task's worktree" \
  || bad_t "blocked skip" "$out"

# ---------------------------------------------------------------- prune verdict
# wt_unpushed must FAIL CLOSED: every case it cannot read comes back with a
# reason, because "I could not look" must never render as "nothing there".
why=$(wt_unpushed "$ROOT/proj-wt-500")
[[ -n "$why" ]] \
  && ok_t "unreadable/non-git worktree reports a prune blocker instead of 'clean'" \
  || bad_t "fail-closed on unreadable" "why='$why'"

if command -v git >/dev/null 2>&1; then
  GH="$TMP/upstream"; git init -q --bare "$GH"
  WK="$ROOT/real-wt-777"
  git init -q "$WK" 2>/dev/null
  git -C "$WK" config user.email t@t; git -C "$WK" config user.name t
  git -C "$WK" remote add origin "$GH"
  printf 'a\n' >"$WK/a.txt"; git -C "$WK" add -A; git -C "$WK" commit -qm one
  why=$(wt_unpushed "$WK")
  [[ "$why" == *"no upstream"* ]] \
    && ok_t "a branch with no upstream cannot be proven pushed" \
    || bad_t "no-upstream blocker" "why='$why'"

  git -C "$WK" push -q -u origin HEAD 2>/dev/null
  why=$(wt_unpushed "$WK")
  [[ -z "$why" ]] && ok_t "a fully pushed clean worktree reports no prune blocker" \
                  || bad_t "clean worktree" "why='$why'"

  printf 'b\n' >"$WK/b.txt"; git -C "$WK" add -A; git -C "$WK" commit -qm two
  why=$(wt_unpushed "$WK")
  [[ "$why" == *"1 unpushed commit"* ]] \
    && ok_t "an unpushed commit blocks the prune verdict" \
    || bad_t "unpushed blocker" "why='$why'"

  printf 'c\n' >"$WK/c.txt"
  why=$(wt_unpushed "$WK")
  [[ "$why" == *"uncommitted path"* ]] \
    && ok_t "uncommitted work blocks the prune verdict" \
    || bad_t "dirty blocker" "why='$why'"
else
  printf 'SKIP - git-backed prune verdict: git not on PATH (precondition unavailable)\n'
fi

# ---------------------------------------------------------------- doctor math
[[ "$(disk_gb 1048576)" == "1.0" && "$(disk_gb 0)" == "0.0" ]] \
  && ok_t "disk_gb converts KiB to GiB" || bad_t "disk_gb" "$(disk_gb 1048576)"
free=$(disk_free_kb /); mnt=$(disk_mount /)
[[ "$free" =~ ^[0-9]+$ && -n "$mnt" ]] \
  && ok_t "disk_free_kb/disk_mount read a real filesystem" || bad_t "df read" "free=$free mnt=$mnt"
# The floors must actually bracket the incident: 75G at 100% full = 0 free.
(( 0 < DISK_ERROR_KB && DISK_ERROR_KB < DISK_WARN_KB )) \
  && ok_t "error floor sits below the warn floor and above zero" \
  || bad_t "thresholds" "err=$DISK_ERROR_KB warn=$DISK_WARN_KB"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
