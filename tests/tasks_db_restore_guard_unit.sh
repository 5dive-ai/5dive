#!/usr/bin/env bash
# DIVE-1479 isolated unit harness for the tasks-db silent-recreate trap guard.
#
# The 2026-07-19 04:20 wipe: tasks.db was unlinked, then a routine reader ran
# tasks_db_init which SILENTLY recreated it empty and everyone proceeded on a
# blank board. The guard added in src/lib/tasks_db.sh makes that class LOUD +
# self-healing: a durable sentinel records that the board was initialized once;
# a missing table alongside that sentinel (or a backup snapshot) triggers an
# alarm + auto-restore from the newest tasks-backups snapshot, and a loud fail
# when there is nothing to restore — never a silent empty create.
#
# Everything runs on a throwaway STATE_DIR (DIVE-1475 isolation override), so it
# never touches the live board. Run: bash tests/tasks_db_restore_guard_unit.sh
# (no root, no network).
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

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/tasks_db.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

JSON_MODE=0
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# Fresh isolated tree per case so state never leaks between assertions.
fresh_tree() {
  TMP="$(mktemp -d /tmp/tasksdb-restore-unit.XXXXXX)"
  STATE_DIR="$TMP"
  TASKS_DIR="$STATE_DIR/tasks"
  TASKS_DB="$TASKS_DIR/tasks.db"
  mkdir -p "$TASKS_DIR"          # simulate the group-writable dir already present
  TREES+=("$TMP")
}
TREES=()
trap 'for t in "${TREES[@]}"; do rm -rf "$t"; done' EXIT

# Emulate 5dive-tasks-backup.sh: snapshot the (non-empty) live db into tasks-backups.
snapshot() {
  local dir="$STATE_DIR/tasks-backups"; mkdir -p "$dir"
  local out="$dir/tasks-$1.db"
  sqlite3 "$TASKS_DB" ".backup '$out'" >/dev/null 2>&1
  gzip -f "$out"
}

seed_rows() { db "INSERT INTO tasks(title) VALUES('alpha'),('beta'),('gamma');" >/dev/null 2>&1; }
row_count() { sqlite3 "$TASKS_DB" "SELECT count(*) FROM tasks;" 2>/dev/null || echo ERR; }

set +e   # header.sh enabled `set -e`; asserts below deliberately probe states

# --- Case 1: genuine fresh box -> silent create is CORRECT, sentinel stamped ---
fresh_tree
out=$(tasks_db_init 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "fresh: init succeeds" || bad "fresh: init rc=$rc ($out)"
[[ -f "$(_tasks_sentinel)" ]] && ok "fresh: sentinel stamped" || bad "fresh: no sentinel"
grep -q 'AUTO-RESTORED\|MISSING' <<<"$out" && bad "fresh: unexpected alarm ($out)" || ok "fresh: no alarm"

# --- Case 2: pre-1479 board (no sentinel) -> init BACKFILLS the sentinel --------
fresh_tree
tasks_db_init >/dev/null 2>&1
seed_rows
rm -f "$(_tasks_sentinel)"                       # simulate a board that predates this fix
[[ ! -f "$(_tasks_sentinel)" ]] || bad "case2: sentinel not cleared for setup"
tasks_db_init >/dev/null 2>&1                     # healthy table present -> migrate + backfill
[[ -f "$(_tasks_sentinel)" ]] && ok "backfill: sentinel re-stamped on healthy re-init" || bad "backfill: sentinel missing"
[[ "$(row_count)" == "3" ]] && ok "backfill: rows untouched" || bad "backfill: rows=$(row_count)"

# --- Case 3: wipe WITH a backup -> loud alarm + auto-restore of the rows --------
fresh_tree
tasks_db_init >/dev/null 2>&1
seed_rows
snapshot "20260719T050000Z"                       # a good snapshot exists
rm -f "$TASKS_DB" "$TASKS_DB-wal" "$TASKS_DB-shm"  # the wipe: unlink the db, sentinel survives
[[ -f "$(_tasks_sentinel)" ]] || bad "case3: sentinel should survive a bare rm tasks.db"
out=$(tasks_db_init 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "restore: init succeeds after wipe" || bad "restore: rc=$rc ($out)"
[[ "$(row_count)" == "3" ]] && ok "restore: 3 rows recovered from snapshot" || bad "restore: rows=$(row_count)"
grep -q 'AUTO-RESTORED 3 rows' <<<"$out" && ok "restore: emitted AUTO-RESTORED alarm" || bad "restore: no alarm ($out)"
[[ -f "$STATE_DIR/tasks-backups/RESTORE-INCIDENTS.log" ]] && ok "restore: incident log written" || bad "restore: no incident log"

# --- Case 4: wipe with sentinel but NO backup -> LOUD FAIL, never silent empty --
fresh_tree
tasks_db_init >/dev/null 2>&1
seed_rows
rm -f "$TASKS_DB" "$TASKS_DB-wal" "$TASKS_DB-shm"  # wipe, and there is no snapshot to restore from
out=$( ( tasks_db_init ) 2>&1 ); rc=$?             # fail() exits the subshell
[[ $rc -ne 0 ]] && ok "no-backup: init fails LOUDLY (rc=$rc)" || bad "no-backup: init silently succeeded"
grep -q 'MANUAL recovery required\|no backup' <<<"$out" && ok "no-backup: alarm names manual recovery" || bad "no-backup: weak msg ($out)"

# --- Case 5: idempotency -> healthy re-init preserves rows, no alarm ------------
fresh_tree
tasks_db_init >/dev/null 2>&1
seed_rows
out=$(tasks_db_init 2>&1); rc=$?
[[ $rc -eq 0 && "$(row_count)" == "3" ]] && ok "idempotent: re-init keeps rows" || bad "idempotent: rc=$rc rows=$(row_count)"
grep -q 'MISSING\|AUTO-RESTORED' <<<"$out" && bad "idempotent: spurious alarm ($out)" || ok "idempotent: no alarm"

# --- Case 6 (DIVE-1986): TASKS_DB aimed elsewhere must NOT inherit this board --
# The reported shape: TASKS_DB overridden ALONE at a throwaway path, STATE_DIR (and
# so TASKS_DIR + tasks-backups) left pointing at a populated board. Before the fix
# the sentinel and the snapshots of THIS board answered "has the board existed?"
# for a store they have never met, and init auto-restored every row of it into the
# throwaway path. Here the populated tree stands in for prod, so the case runs the
# real shape without going near the live board.
fresh_tree
tasks_db_init >/dev/null 2>&1
seed_rows
snapshot "20260725T154721Z"                        # this board HAS a restorable history
home_db="$TASKS_DB"; home_sentinel="$(_tasks_sentinel)"
foreign="$TMP/foreign"; mkdir -p "$foreign"        # a dir the caller just created
TASKS_DB="$foreign/tasks.db"                       # ONLY TASKS_DB moves — the reported shape
out=$(tasks_db_init 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "foreign: init succeeds" || bad "foreign: rc=$rc ($out)"
[[ "$(row_count)" == "0" ]] && ok "foreign: store is EMPTY (no rows imported)" \
  || bad "foreign: imported $(row_count) rows from another board"
grep -q 'AUTO-RESTORED' <<<"$out" && bad "foreign: auto-restored into a foreign store ($out)" \
  || ok "foreign: no auto-restore alarm"
[[ -f "$foreign/.board-initialized" ]] && ok "foreign: sentinel stamped BESIDE the foreign store" \
  || bad "foreign: sentinel not scoped to the store"
[[ ! -e "$TASKS_DIR/.recover.lock" ]] && ok "foreign: no recover lock left in the other board's dir" \
  || bad "foreign: wrote .recover.lock into the other board's dir"
# The board that was NOT the target must be untouched by any of the above.
[[ "$(sqlite3 "$home_db" 'SELECT count(*) FROM tasks;' 2>/dev/null)" == "3" ]] \
  && ok "foreign: the other board still has its 3 rows" || bad "foreign: the other board changed"
[[ -f "$home_sentinel" ]] && ok "foreign: the other board's sentinel intact" || bad "foreign: other sentinel gone"

# --- Case 7 (DIVE-1986): a foreign store still gets the guard ON ITS OWN TERMS --
# Scoping the lookup must not disarm the guard for non-prod stores: once a store
# has its own sentinel, a vanished table there is still an incident, and with no
# snapshot of ITS OWN it must fail loudly rather than silently create an empty
# board — and must not reach for the other board's snapshots to fill the gap.
rm -f "$TASKS_DB" "$TASKS_DB-wal" "$TASKS_DB-shm"   # wipe the foreign store; its sentinel survives
[[ -f "$foreign/.board-initialized" ]] || bad "case7: foreign sentinel should survive a bare rm"
out=$( ( tasks_db_init ) 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && ok "foreign-wipe: fails LOUDLY (rc=$rc)" || bad "foreign-wipe: silently succeeded"
grep -q 'MANUAL recovery required\|no backup' <<<"$out" \
  && ok "foreign-wipe: alarm names manual recovery" || bad "foreign-wipe: weak msg ($out)"
[[ "$(row_count)" == "ERR" || "$(row_count)" == "0" ]] \
  && ok "foreign-wipe: no rows pulled from the other board's snapshot" \
  || bad "foreign-wipe: imported $(row_count) rows from the other board"

# --- Case 8 (DIVE-1986): an explicit TASKS_BACKUP_DIR pairing still restores ----
# The caller who names a backup dir is pairing it with their store deliberately,
# so the scoping check must not fence that off — otherwise recovering a relocated
# board by hand becomes impossible.
fresh_tree
tasks_db_init >/dev/null 2>&1
seed_rows
snapshot "20260725T160000Z"
paired_backups="$STATE_DIR/tasks-backups"
elsewhere="$TMP/elsewhere"; mkdir -p "$elsewhere"
TASKS_DB="$elsewhere/tasks.db"
out=$(TASKS_BACKUP_DIR="$paired_backups" tasks_db_init 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "paired: init succeeds" || bad "paired: rc=$rc ($out)"
[[ "$(row_count)" == "3" ]] && ok "paired: explicit TASKS_BACKUP_DIR still restores" \
  || bad "paired: rows=$(row_count) ($out)"

echo
echo "tasks-db restore guard: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
