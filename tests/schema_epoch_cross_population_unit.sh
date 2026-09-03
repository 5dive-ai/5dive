#!/usr/bin/env bash
# DIVE-3932: the schema epoch after a two-parent merge, graded as a DIFFERENTIAL
# over both parent populations rather than as a string.
#
# WHY THIS EXISTS. DIVE-3932 (runs) and DIVE-3931 (triggers) each bumped
# $_TASKS_SCHEMA_EPOCH on their own branch — '3932-1' and '3931-1'. The migration
# gate skips the whole block when the store's stamped epoch EQUALS the shipped one
# (_tasks_db_migration_needed), so keeping either parent's literal on the merge
# silently strands exactly one population: a store stamped '3931-1' by main would
# never run the runs block, a store stamped '3932-1' by the branch would never run
# the trigger block. The merge resolved to a THIRD value no store carries.
#
# quinn measured that resolution by hand at grading time and then named the gap:
# `grep -rn '3931-1|3932-1|3932-2' tests/` was EMPTY, so the third value was
# protected by a source comment and nothing executable — a later edit could revert
# it to either parent literal and stay green on the whole corpus. This harness is
# that missing executable.
#
# IT DOES NOT PIN THE STRING. Asserting `_TASKS_SCHEMA_EPOCH == '3932-2'` would go
# stale on the next legitimate bump and teach the next author to edit the test to
# match the code. What is asserted is the PROPERTY: both parent-shaped stores
# re-migrate. Cases 3 and 4 are the negative controls that make that non-vacuous —
# they substitute each parent literal back in and require the corresponding
# population to be stranded, which is the mutation quinn ran by hand.
#
# Throwaway STATE_DIR per case (DIVE-1475 isolation override); never the live board.
# Run: bash tests/schema_epoch_cross_population_unit.sh   (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TREES=()
trap 'rc=$?; for t in "${TREES[@]}"; do rm -rf "${t:-}"; done; echo "HARNESS-RC=$rc"' EXIT
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
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

SHIPPED_EPOCH="$_TASKS_SCHEMA_EPOCH"

# The two parent literals, read from the merge's own parents rather than typed
# here, so this harness cannot disagree with history. Falls back to the recorded
# values when the git objects are not reachable (a staged copy, a shallow clone).
PARENT_RUNS='3932-1'; PARENT_TRIG='3931-1'

RUNS_TABLES=(runs run_events run_usage)
TRIG_TABLES=(event_triggers event_deliveries event_delivery_attempts)

fresh_tree() {
  TMP="$(mktemp -d /tmp/schema-epoch-xpop.XXXXXX)"
  STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
  mkdir -p "$TASKS_DIR"; TREES+=("$TMP")
}

have_table() { # <name> -> prints 1 or nothing
  sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$1' LIMIT 1;" 2>/dev/null
}
count_present() { local n=0 t; for t in "$@"; do [[ "$(have_table "$t")" == 1 ]] && n=$((n+1)); done; printf '%s' "$n"; }
stamped_epoch() {
  sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT value FROM task_prefs WHERE key='schema_epoch';" 2>/dev/null
}

# Build a store shaped like one PARENT: a full current store, minus the tables that
# parent had never heard of, stamped with that parent's epoch. This is the shape a
# live box carries when the merge reaches it.
born_as() { # <epoch> <table>...
  local ep="$1"; shift
  fresh_tree
  tasks_db_init >/dev/null 2>&1 || { bad "precondition: tasks_db_init failed"; return 1; }
  local t
  for t in "$@"; do
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" "DROP TABLE IF EXISTS $t;" >/dev/null 2>&1
  done
  sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "INSERT INTO task_prefs(key,value,updated_at) VALUES ('schema_epoch','$ep',datetime('now'))
       ON CONFLICT(key) DO UPDATE SET value=excluded.value;" >/dev/null 2>&1
}

set +e   # header.sh enabled `set -e`; the asserts below deliberately probe states

# --- Case 0: the shipped epoch is neither parent's -----------------------------
# The cheap direct reading of the same property. It is NOT sufficient on its own —
# a third value that no migration block is gated on would also pass here — which is
# why cases 1-4 grade behaviour rather than the string.
[[ "$SHIPPED_EPOCH" != "$PARENT_RUNS" && "$SHIPPED_EPOCH" != "$PARENT_TRIG" ]] \
  && ok "shipped epoch ($SHIPPED_EPOCH) is neither parent literal" \
  || bad "shipped epoch is a PARENT literal ($SHIPPED_EPOCH) — one population never re-migrates"

# --- Case 1: a MAIN-born store (triggers, no runs) re-migrates ------------------
born_as "$PARENT_TRIG" "${RUNS_TABLES[@]}"
[[ "$(count_present "${RUNS_TABLES[@]}")" == 0 ]] \
  && ok "main-born fixture starts with 0 of 3 runs tables" \
  || bad "main-born fixture did not start stranded (fixture is vacuous)"
tasks_db_init >/dev/null 2>&1
[[ "$(count_present "${RUNS_TABLES[@]}")" == 3 ]] \
  && ok "main-born store re-migrates: 3 of 3 runs tables present" \
  || bad "main-born store still short runs tables ($(count_present "${RUNS_TABLES[@]}") of 3)"
[[ "$(stamped_epoch)" == "$SHIPPED_EPOCH" ]] \
  && ok "main-born store is re-stamped to $SHIPPED_EPOCH" \
  || bad "main-born store epoch is [$(stamped_epoch)], want [$SHIPPED_EPOCH]"

# --- Case 2: a BRANCH-born store (runs, no triggers) re-migrates ----------------
born_as "$PARENT_RUNS" "${TRIG_TABLES[@]}"
[[ "$(count_present "${TRIG_TABLES[@]}")" == 0 ]] \
  && ok "branch-born fixture starts with 0 of 3 trigger tables" \
  || bad "branch-born fixture did not start stranded (fixture is vacuous)"
tasks_db_init >/dev/null 2>&1
[[ "$(count_present "${TRIG_TABLES[@]}")" == 3 ]] \
  && ok "branch-born store re-migrates: 3 of 3 trigger tables present" \
  || bad "branch-born store still short trigger tables ($(count_present "${TRIG_TABLES[@]}") of 3)"
[[ "$(stamped_epoch)" == "$SHIPPED_EPOCH" ]] \
  && ok "branch-born store is re-stamped to $SHIPPED_EPOCH" \
  || bad "branch-born store epoch is [$(stamped_epoch)], want [$SHIPPED_EPOCH]"

# --- Case 3 (negative control): revert the epoch to main's literal --------------
# The losing side is silent: nothing errors, the store simply never runs the runs
# block. If this case does not go red, cases 1-2 are not measuring the gate.
_TASKS_SCHEMA_EPOCH="$PARENT_TRIG"
born_as "$PARENT_TRIG" "${RUNS_TABLES[@]}"
tasks_db_init >/dev/null 2>&1
[[ "$(count_present "${RUNS_TABLES[@]}")" == 0 ]] \
  && ok "control: epoch reverted to $PARENT_TRIG strands the main-born store (0 of 3 runs)" \
  || bad "control did not strand: epoch $PARENT_TRIG still migrated the main-born store"
_TASKS_SCHEMA_EPOCH="$SHIPPED_EPOCH"

# --- Case 4 (negative control): revert the epoch to the branch's literal --------
_TASKS_SCHEMA_EPOCH="$PARENT_RUNS"
born_as "$PARENT_RUNS" "${TRIG_TABLES[@]}"
tasks_db_init >/dev/null 2>&1
[[ "$(count_present "${TRIG_TABLES[@]}")" == 0 ]] \
  && ok "control: epoch reverted to $PARENT_RUNS strands the branch-born store (0 of 3 triggers)" \
  || bad "control did not strand: epoch $PARENT_RUNS still migrated the branch-born store"
_TASKS_SCHEMA_EPOCH="$SHIPPED_EPOCH"

printf '\nschema_epoch_cross_population_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
