#!/usr/bin/env bash
# DIVE-2512 migration guard: the tombstone columns must reach a store whose
# `objectives` table PREDATES them, not just a fresh one.
#
# Why this is its own harness and not another case in objective_unit.sh: that
# harness runs `tasks_db_init` on an empty dir, so it only ever exercises the
# CANONICAL schema in _tasks_schema(). Every live box on this fleet has an
# existing tasks.db and takes the OTHER copy — the ALTER block in
# _tasks_db_migrate(). A change that lands the columns in only one of the two
# passes objective_unit.sh completely while `objective rm` fails on every real
# store with "no such column: retired_at". schema_sync_unit.sh compares the two
# CREATE TABLE copies, which is a different check: it cannot see an ALTER that
# was never written.
#
# The positive control is load-bearing here. This harness first proves the
# pre-migration store genuinely LACKS the columns (otherwise "they're present
# afterwards" is vacuous), then migrates, then proves a real retire+resume round
# trip WRITES and CLEARS them on that migrated store.
# Run: bash tests/objective_tombstone_migration_unit.sh  (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/objective-tombstone-mig.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_objective.sh; do
  # shellcheck source=/dev/null
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
run()   { ( "$@" ) 2>/dev/null; }
cols()  { sqlite3 "$TASKS_DB" "SELECT name FROM pragma_table_info('objectives');"; }

# ---- build a PRE-DIVE-2512 store: full current schema, then drop the four
# columns back off the objectives table (sqlite3 >= 3.35 supports DROP COLUMN).
# Recreating the whole legacy schema by hand would rot; subtracting exactly the
# columns under test keeps the fixture honest and minimal.
tasks_db_init >/dev/null 2>&1
for c in retired_at retired_by retired_reason retired_ref; do
  sqlite3 "$TASKS_DB" "ALTER TABLE objectives DROP COLUMN $c;" 2>/dev/null
done

missing=0
for c in retired_at retired_by retired_reason retired_ref; do
  grep -qx "$c" <<<"$(cols)" || missing=$((missing+1))
done
if [[ "$missing" -ne 4 ]]; then
  echo "skip - could not build a pre-DIVE-2512 fixture (sqlite3 $(sqlite3 -version | awk '{print $1}') lacks DROP COLUMN?); migration path UNTESTED here"
  echo "-----"
  echo "objective_tombstone_migration_unit: SKIPPED (fixture unavailable)"
  exit 0
fi
ok_t "positive control: fixture store LACKS all four tombstone columns"

# a retire against the un-migrated store must fail — proves the columns are what
# the code needs, so their arrival below is the thing actually being measured.
run cmd_objective_add "legacy" --metric-cmd="echo 1" --target=2 >/dev/null
out=$(run cmd_objective_rm "legacy"); rc=$?
st=$(sqlite3 "$TASKS_DB" "SELECT status FROM objectives WHERE name='legacy';")
[[ "$st" != "retired" ]] && ok_t "pre-migration: retire cannot succeed without the columns (status=$st)" \
  || bad_t "pre-migration control" "retire succeeded on a store with no retired_* columns (rc=$rc)"

# ---- migrate ----
_tasks_db_migrate >/dev/null 2>&1
present=0
for c in retired_at retired_by retired_reason retired_ref; do
  grep -qx "$c" <<<"$(cols)" && present=$((present+1))
done
[[ "$present" -eq 4 ]] && ok_t "migration adds all four tombstone columns to an existing store" \
  || bad_t "migration columns" "present=$present/4 cols=$(cols | paste -sd, -)"

# ---- partial-expand convergence: lose ONE column, re-migrate, it comes back.
# The obvious implementation guards all four on retired_at's absence, which leaves
# a store that took a partial expand permanently one column short.
sqlite3 "$TASKS_DB" "ALTER TABLE objectives DROP COLUMN retired_ref;" 2>/dev/null
if grep -qx "retired_ref" <<<"$(cols)"; then
  echo "ok   - (partial-expand case not exercisable on this sqlite3; skipped)"
else
  _tasks_db_migrate >/dev/null 2>&1
  grep -qx "retired_ref" <<<"$(cols)" \
    && ok_t "migration re-converges a store that lost ONE column (not guarded on retired_at alone)" \
    || bad_t "partial expand" "retired_ref did not come back"
fi

# ---- end-to-end on the MIGRATED store: retire writes, resume clears ----
oid=$(sqlite3 "$TASKS_DB" "SELECT id FROM objectives WHERE name='legacy';")
sqlite3 "$TASKS_DB" "INSERT INTO objective_cycles (objective_id, cycle_no, outcome) VALUES ($oid, 1, 'applied');"
out=$(run cmd_objective_rm "legacy" --reason="migrated-store round trip" --ref=DIVE-2512); rc=$?
IFS="|" read -r st r_at r_ref kept < <(sqlite3 "$TASKS_DB" \
  "SELECT status, COALESCE(retired_at,''), COALESCE(retired_ref,''),
          (SELECT COUNT(*) FROM objective_cycles WHERE objective_id=$oid)
     FROM objectives WHERE id=$oid;")
[[ $rc -eq 0 && "$st" == "retired" && -n "$r_at" && "$r_ref" == "DIVE-2512" && "$kept" == "1" ]] \
  && ok_t "migrated store: retire stamps the tombstone and keeps the cycle row" \
  || bad_t "migrated retire" "rc=$rc status=$st at=$r_at ref=$r_ref cycles=$kept"

run cmd_objective_setstatus active "legacy" >/dev/null
IFS="|" read -r st2 r_at2 < <(sqlite3 "$TASKS_DB" "SELECT status, COALESCE(retired_at,'') FROM objectives WHERE id=$oid;")
[[ "$st2" == "active" && -z "$r_at2" ]] \
  && ok_t "migrated store: resume un-retires and clears the stamp" \
  || bad_t "migrated resume" "status=$st2 retired_at=$r_at2"

echo "-----"
echo "objective_tombstone_migration_unit: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
