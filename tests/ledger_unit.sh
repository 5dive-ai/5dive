#!/usr/bin/env bash
# INST-4 unit: the unified lifecycle ledger (lifecycle_events).
#
# What this grades, and why each case exists:
#
#   1. THE MIGRATION. Same class as the DIVE-1922 bug this suite's sibling was
#      reopened for: a new table's DDL nested inside ANOTHER table's existence
#      guard runs only on stores that lack that other table -- i.e. never on a
#      real box. The ledger would silently never exist, `trace` would render an
#      empty section forever, and empty is indistinguishable from "no events".
#      Guard on the table you are creating; prove it on a store that already has
#      the neighbouring tables.
#
#   2. THE START MARKER. An empty ledger has two meanings -- "nothing happened"
#      and "this work predates the ledger" -- and no amount of reading the rows
#      separates them. Only a marker written at init does. If the marker moved on
#      every init it would be useless (it would always say "today"), so the
#      idempotency of the marker is graded, not assumed.
#
#   3. PAYLOADS ARE NEVER STORED. in=/out= take raw content and the table must
#      hold only digests. This is the assertion that keeps the ledger safe to
#      read at a lower privilege than the board it describes, so it is graded by
#      MUTATION (case 6), not just asserted.
#
#   4. IDEMPOTENCY IN BOTH DIRECTIONS. A retried emit must collapse; a genuinely
#      repeated event with its own key must NOT. Grading only the collapse would
#      pass a ledger that drops every repeat -- which is how a "they kept trying"
#      series silently becomes "they tried once".
#
#   5. NEVER FAILS THE CALLER. A lifecycle event that cannot be recorded must not
#      turn a successful action into a failed one.
#
# Isolated: temp sqlite store, no prod DB, no root, no network.
#   bash tests/ledger_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null` -- see the sibling suites; redirecting the
# source's stderr also swallows the helper's own line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

command -v sqlite3 >/dev/null 2>&1 || { echo "skip - sqlite3 not available"; exit 0; }

TMP="$(mktemp -d /tmp/ledger-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ---------------------------------------------------------------------------
# Case 1: THE MIGRATION, on a store shaped like a real box.
# ---------------------------------------------------------------------------
DB="$TMP/legacy.db"
sqlite3 "$DB" "CREATE TABLE tasks (id INTEGER PRIMARY KEY, ident TEXT);
               CREATE TABLE supervisor_events (id INTEGER PRIMARY KEY, agent TEXT, classification TEXT);
               CREATE TABLE ship_events (id INTEGER PRIMARY KEY, sha TEXT);
               CREATE TABLE objective_cycles (id INTEGER PRIMARY KEY);" 2>/dev/null

# Anchor-assert the baseline DIFFERS from the expected end state. Without this
# the migration assertion below would pass just as happily against a store that
# already had the table -- i.e. it would grade nothing.
if [[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE name='lifecycle_events';")" == "0" ]]; then
  ok_t "precondition: legacy store has the neighbouring silos but NOT lifecycle_events"
else
  bad_t "precondition" "lifecycle_events already present before the migration ran"
fi

export STATE_DIR="$TMP/state"
export TASKS_DIR="$STATE_DIR/tasks"
export TASKS_DB="$DB"
mkdir -p "$TASKS_DIR"
: > "$STATE_DIR/tasks/.board-initialized"   # pre-existing board (DIVE-1479 guard)

# Drive the migration directly, and do NOT swallow its rc/stderr: a driver that
# hard-failed must not read as a successful migration (the DIVE-1922 lesson).
# shellcheck disable=SC1091
migrate_out=$( set +e; . src/lib/tasks_db.sh >/dev/null 2>&1; tasks_db_init 2>&1 ); migrate_rc=$?
if (( migrate_rc != 0 )); then
  bad_t "the migration driver itself FAILED (rc=$migrate_rc)" "$migrate_out"
fi

if [[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE name='lifecycle_events';")" == "1" ]]; then
  ok_t "migration: lifecycle_events created on a store that already had the other silos"
else
  bad_t "migration: lifecycle_events NOT created" \
        "the DDL is gated on a neighbouring table's absence -- it will never run on a real box"
fi

# The UNIQUE index is not decoration: it IS the idempotency contract graded in
# case 4. A table created without it passes every row-shape assertion.
if sqlite3 "$DB" "SELECT sql FROM sqlite_master WHERE name='lifecycle_events_idem_idx';" 2>/dev/null | grep -q 'UNIQUE'; then
  ok_t "migration: the UNIQUE idem_key index came with the table"
else
  bad_t "migration: lifecycle_events_idem_idx missing or not UNIQUE" \
        "without it every retried emit double-counts and case 4 cannot bite"
fi

# ---------------------------------------------------------------------------
# Case 2: the start marker exists, and is STAMPED ONCE.
# ---------------------------------------------------------------------------
marker1=$(sqlite3 "$DB" "SELECT value FROM task_prefs WHERE key='ledger_started';" 2>/dev/null)
if [[ -n "$marker1" ]]; then
  ok_t "start marker: ledger_started stamped at init ($marker1)"
else
  bad_t "start marker: ledger_started absent" \
        "trace cannot then distinguish 'no events' from 'predates the ledger'"
fi

# Re-init and confirm the marker did not move. A marker that re-stamps always
# reads "today", so every task looks like it predates the ledger, forever.
sqlite3 "$DB" "UPDATE task_prefs SET value='2000-01-01 00:00:00' WHERE key='ledger_started';" 2>/dev/null
# shellcheck disable=SC1091
( set +e; . src/lib/tasks_db.sh >/dev/null 2>&1; tasks_db_init >/dev/null 2>&1 )
marker2=$(sqlite3 "$DB" "SELECT value FROM task_prefs WHERE key='ledger_started';" 2>/dev/null)
if [[ "$marker2" == "2000-01-01 00:00:00" ]]; then
  ok_t "start marker: a later init does NOT re-stamp it (INSERT OR IGNORE holds)"
else
  bad_t "start marker: re-stamped on the second init (now '$marker2')" \
        "it would always report 'today' and every task would look older than the ledger"
fi

# ---------------------------------------------------------------------------
# Cases 3-5: the writer. Source the libs it actually depends on.
# ---------------------------------------------------------------------------
emit_env() {
  # shellcheck disable=SC1091
  . src/lib/audit.sh    >/dev/null 2>&1
  # shellcheck disable=SC1091
  . src/lib/tasks_db.sh >/dev/null 2>&1
}

SECRET='sk-live-DO-NOT-STORE-THIS'
(
  set +e
  emit_env
  ledger_emit task.created ident=TEST-1 task_id=1 actor=dev in="a title" out="$SECRET" \
    detail="medium -> dev"
) >/dev/null 2>&1

row=$(sqlite3 -separator '|' "$DB" \
  "SELECT kind, ident, task_id, actor, authority, COALESCE(input_hash,''), COALESCE(output_hash,''),
          COALESCE(host,''), COALESCE(detail,'') FROM lifecycle_events WHERE ident='TEST-1';" 2>/dev/null)
if [[ -n "$row" ]]; then
  ok_t "writer: one row landed with the envelope ($row)"
else
  bad_t "writer: no row landed" "ledger_emit wrote nothing"
fi

# The load-bearing privacy property, stated as a property of the TABLE rather
# than of any one column: the raw payload must appear NOWHERE in the row.
dump=$(sqlite3 "$DB" "SELECT * FROM lifecycle_events;" 2>/dev/null)
if [[ -n "$dump" ]] && ! printf '%s' "$dump" | grep -qF "$SECRET"; then
  ok_t "privacy: the raw out= payload is nowhere in the table (digest only)"
else
  bad_t "privacy: the raw payload reached the ledger" \
        "in=/out= must be hashed by ledger_emit, never stored"
fi

# ...and the digest is actually there, so the assertion above is not passing
# merely because the column is empty. A negative needs a liveness proof.
want_hash=$(printf '%s' "$SECRET" | sha256sum | cut -c1-16)
got_hash=$(sqlite3 "$DB" "SELECT COALESCE(output_hash,'') FROM lifecycle_events WHERE ident='TEST-1';" 2>/dev/null)
if [[ "$got_hash" == "$want_hash" ]]; then
  ok_t "privacy: output_hash is the sha256 digest of the payload (not an empty column)"
else
  bad_t "privacy: output_hash is '$got_hash', expected '$want_hash'" \
        "an empty digest would make the no-raw-payload assertion vacuous"
fi

# Case 4a: a RETRIED emit collapses (derived idem key).
(
  set +e
  emit_env
  ledger_emit task.created ident=TEST-1 task_id=1 actor=dev in="a title" out="$SECRET" \
    detail="medium -> dev"
) >/dev/null 2>&1
n=$(sqlite3 "$DB" "SELECT COUNT(*) FROM lifecycle_events WHERE ident='TEST-1';" 2>/dev/null)
if [[ "$n" == "1" ]]; then
  ok_t "idempotency: an identical retried emit collapsed to one row"
else
  bad_t "idempotency: got $n rows for one logical event" "the derived idem key is not deterministic"
fi

# Case 4b: a genuinely repeated event with its OWN key must NOT collapse. The
# mirror assertion -- without it, a writer that dropped every repeat would pass.
(
  set +e
  emit_env
  ledger_emit policy.refused ident=TEST-2 actor=dev policy=push.blocked idem="refuse:1" detail="attempt 1"
  ledger_emit policy.refused ident=TEST-2 actor=dev policy=push.blocked idem="refuse:2" detail="attempt 2"
) >/dev/null 2>&1
n2=$(sqlite3 "$DB" "SELECT COUNT(*) FROM lifecycle_events WHERE ident='TEST-2';" 2>/dev/null)
if [[ "$n2" == "2" ]]; then
  ok_t "idempotency: two distinct attempts with their own keys stayed two rows"
else
  bad_t "idempotency: two distinct attempts collapsed to $n2 row(s)" \
        "'they kept trying' would render as 'they tried once'"
fi

# Case 4c: authority is recorded and is not a constant. Unelevated -> 'self'.
auth=$(sqlite3 "$DB" "SELECT authority FROM lifecycle_events WHERE ident='TEST-1';" 2>/dev/null)
if [[ "$auth" == "self" || "$auth" == root || "$auth" == sudo:* ]]; then
  ok_t "authority: recorded as '$auth' (an elevation state, not a placeholder)"
else
  bad_t "authority: '$auth' is not one of self|root|sudo:<who>"
fi

# Case 5: NEVER fails the caller, even when the store is unusable.
rc=$(
  set +e
  emit_env
  TASKS_DB="$TMP/nonexistent-dir/nope.db"
  ledger_emit task.done ident=TEST-3 task_id=3 detail="should not fail"
  echo $?
)
if [[ "$rc" == "0" ]]; then
  ok_t "never-fails: an unwritable store still returns 0 to the caller"
else
  bad_t "never-fails: ledger_emit returned $rc" \
        "a failed evidence write must not turn a successful action into a failed one"
fi

# ---------------------------------------------------------------------------
# Case 6: MUTATION ARM. Break the hashing and confirm the privacy assertion goes
# RED. An assertion that has never been observed to fail is not yet evidence.
# Differential: the SAME assertion, the SAME driver, one changed line.
# ---------------------------------------------------------------------------
MUT="$TMP/mutant"
mkdir -p "$MUT/src/lib"
cp src/lib/audit.sh src/lib/tasks_db.sh "$MUT/src/lib/"
# The mutation: ledger_hash returns its input verbatim instead of a digest.
python3 - "$MUT/src/lib/tasks_db.sh" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = s.replace(
  '  printf \'%s\' "$raw" | sha256sum 2>/dev/null | cut -c1-16 || printf \'\'',
  '  printf \'%s\' "$raw"')
assert s2 != s, "MUTATION DID NOT LAND -- the anchor line changed; this arm graded nothing"
open(p, 'w').write(s2)
PY
mut_landed=$?
if (( mut_landed != 0 )); then
  bad_t "mutation arm: the mutation did NOT land" "the arm would report a false green"
else
  MDB="$TMP/mutant.db"
  (
    set +e
    cd "$MUT"
    export STATE_DIR="$TMP/mstate" TASKS_DIR="$TMP/mstate/tasks" TASKS_DB="$MDB"
    mkdir -p "$TASKS_DIR"; : > "$TASKS_DIR/.board-initialized"
    sqlite3 "$MDB" "CREATE TABLE tasks (id INTEGER PRIMARY KEY, ident TEXT);" 2>/dev/null
    # shellcheck disable=SC1091
    . src/lib/audit.sh >/dev/null 2>&1
    # shellcheck disable=SC1091
    . src/lib/tasks_db.sh >/dev/null 2>&1
    tasks_db_init >/dev/null 2>&1
    ledger_emit task.created ident=MUT-1 task_id=1 actor=dev out="$SECRET" detail=x
  ) >/dev/null 2>&1
  mdump=$(sqlite3 "$MDB" "SELECT * FROM lifecycle_events;" 2>/dev/null)
  if printf '%s' "$mdump" | grep -qF "$SECRET"; then
    ok_t "mutation arm: with hashing removed the privacy assertion goes RED (it can bite)"
  else
    bad_t "mutation arm: privacy assertion stayed GREEN against a mutant that stores raw payloads" \
          "the assertion is vacuous -- it is not grading the hashing"
  fi
fi

# ---------------------------------------------------------------------------
# Case 7: THE FUNNEL. Drive the real bundle through the maker→verifier rail and
# assert the DELIVERY was recorded as a delivery.
#
# This case exists because the first cut of the change got it wrong. The emit was
# placed in _task_status_cmd on the assumption that every `task done` funnels
# through it; a `done` that DELIVERS forks earlier, into the handoff write, so
# the single event the verifier rail is entirely about was absent from the ledger
# and nothing said so. An absent row is the one shape a ledger cannot
# self-report, so it needs a test that asserts presence AND kind.
#
# Also asserts the negative: a delivery must NOT appear as task.done. Recording
# it as a close would have the ledger attest that work was finished while it is
# still waiting to be graded — our own evidence base overstating autonomy, which
# is worse than a missing row.
# ---------------------------------------------------------------------------
BUNDLE=./5dive
if [[ ! -x "$BUNDLE" ]]; then
  bad_t "funnel case: bundle not built" "run bash build.sh first"
else
  E2E="$TMP/e2e"
  (
    set +e
    export STATE_DIR="$E2E" TASKS_DIR="$E2E/tasks" TASKS_DB="$E2E/tasks/tasks.db"
    mkdir -p "$TASKS_DIR"
    "$BUNDLE" task add "funnel case" --project=DIVE --assignee=dev --verifier=main
    "$BUNDLE" task start DIVE-1 --no-preflight
    "$BUNDLE" task done DIVE-1 --result="delivered, not closed"
  ) >/dev/null 2>&1
  E2EDB="$TMP/e2e/tasks/tasks.db"
  kinds=$(sqlite3 "$E2EDB" "SELECT GROUP_CONCAT(kind, ',') FROM (SELECT kind FROM lifecycle_events ORDER BY id);" 2>/dev/null)
  if [[ "$kinds" == *task.delivered* ]]; then
    ok_t "funnel: the maker→verifier delivery emitted task.delivered ($kinds)"
  else
    bad_t "funnel: no task.delivered row (kinds: ${kinds:-<none>})" \
          "a 'task done' that delivers forks before _task_status_cmd — emit at the handoff write too"
  fi
  if [[ "$kinds" != *task.done* ]]; then
    ok_t "funnel: the delivery was NOT recorded as task.done"
  else
    bad_t "funnel: a delivery was recorded as task.done" \
          "the ledger would attest work was finished while it is still awaiting a grade"
  fi
  # Liveness for the negative above: prove this store recorded ANYTHING, so the
  # "no task.done" assertion is not passing because the ledger is simply empty.
  if [[ -n "$kinds" ]]; then
    ok_t "funnel: the e2e store recorded rows at all (the negative above is not vacuous)"
  else
    bad_t "funnel: the e2e ledger is empty" "every assertion in this case is vacuous"
  fi
fi

echo "-----"
echo "ledger_unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
