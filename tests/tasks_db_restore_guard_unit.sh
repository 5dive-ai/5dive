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

echo
echo "tasks-db restore guard: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
