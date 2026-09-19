#!/usr/bin/env bash
# DIVE-4589 unit: the two append-only stores — auth-profile binding events and
# provider quota samples — and the rules that make them evidence rather than
# decoration.
#
# WHAT THIS GRADES, and why each arm exists:
#   * A binding is resolved AT A TIMESTAMP, not from the current config. The
#     defect this row was filed for is that `usage` stamped every historical turn
#     with the seat's CURRENT authProfile, so one rotation re-attributed the whole
#     past (DIVE-4584 had to hand-type a constant to work around it).
#   * A REBIND NEVER REWRITES PRIOR ATTRIBUTION (criterion 5). Asserted by
#     re-reading an OLD timestamp after a rebind and getting the OLD account.
#   * A RECALLED reading never enters the sample table as a fresh observation
#     (criterion 7): no source agent -> no row, and re-reading the same cache
#     (same as_of) inserts once, not twice.
#   * An absent answer is DISTINGUISHABLE from a wrong one: no event at or before
#     a timestamp returns EMPTY, so the caller must label its fallback.
#
# NEGATIVE CONTROL (how to re-run it against the pre-fix tree):
#   mkdir -p /tmp/pre4589 && git show origin/main:src/lib/tasks_db.sh > /tmp/pre4589/tasks_db.sh
#   # src/lib/account_history.sh does not exist on origin/main at all, so every
#   # arm below fails at source time — the strongest possible control.
#
# Run: bash tests/account_binding_history_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

command -v sqlite3 >/dev/null 2>&1 || { echo "skip - sqlite3 not available"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "skip - jq not available"; exit 0; }

TMP="$(mktemp -d /tmp/acct-hist.XXXXXX)"
export STATE_DIR="$TMP"
export TASKS_DIR="$TMP/tasks"
export TASKS_DB="$TMP/tasks/tasks.db"
mkdir -p "$TASKS_DIR"
# A store that exists but has NEITHER table: the pre-migration board. Every
# helper must self-heal onto it rather than failing the caller.
sqlite3 "$TASKS_DB" "CREATE TABLE tasks (ident TEXT);" >/dev/null 2>&1

# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# The store fence (tasks_db.sh) must see a non-production store; STATE_DIR above
# is a scratch dir, which is exactly the condition it checks.
# shellcheck source=/dev/null
source src/lib/tasks_db.sh
# shellcheck source=/dev/null
source src/lib/account_history.sh

PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"
      else FAIL=$((FAIL+1)); printf 'FAIL - %s\n       expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; }

NOW=$(date +%s)
T0=$((NOW-7200))   # coder bound to max-a
T1=$((NOW-3600))   # rotated to max-b
T2=$((NOW-1800))   # a second seat joins max-b

# --- binding events -------------------------------------------------------
account_binding_record coder max-a create   "$T0"
account_binding_record coder max-b rotation "$T1"
account_binding_record quinn max-b create   "$T2"

t "a turn before any event has no proven binding" "" "$(account_binding_at coder $((T0-60)))"
t "a turn inside the first binding resolves to it"  "max-a" "$(account_binding_at coder $((T0+60)))"
t "a turn at the rebind instant resolves to the NEW account" "max-b" "$(account_binding_at coder "$T1")"
t "a turn one second before the rebind still resolves to the OLD account" \
  "max-a" "$(account_binding_at coder $((T1-1)))"
t "a turn after the rebind resolves to the new account" "max-b" "$(account_binding_at coder $((T1+600)))"
t "an unrelated seat is not affected by another seat's rebind" \
  "max-b" "$(account_binding_at quinn $((T2+60)))"
t "a seat with no history at all returns empty, never a guess" \
  "" "$(account_binding_at nosuch "$NOW")"

# criterion 5: a LATER rebind must not change what an EARLIER timestamp answers.
account_binding_record coder max-c config-set "$NOW"
t "criterion 5 — a later rebind does not rewrite prior attribution (old ts)" \
  "max-a" "$(account_binding_at coder $((T0+60)))"
t "criterion 5 — the middle binding also survives the later rebind" \
  "max-b" "$(account_binding_at coder $((T1+600)))"
t "the newest binding is the newest event" "max-c" "$(account_binding_latest coder)"

# a no-op rebind to the SAME account writes nothing (else every `config set` of
# an unrelated key would forge a rebind that never happened)
before=$(sqlite3 "$TASKS_DB" "SELECT COUNT(*) FROM account_binding_events;")
account_binding_record coder max-c config-set "$((NOW+1))"
after=$(sqlite3 "$TASKS_DB" "SELECT COUNT(*) FROM account_binding_events;")
t "re-binding to the same account appends nothing" "$before" "$after"

# an explicit UNBIND is a recorded fact, distinct from "no event"
account_binding_record coder "" agent-remove "$((NOW+2))"
t "an unbind records an empty account, not a missing row" "" "$(account_binding_at coder $((NOW+3)))"
t "an unbind is visible as an explicit event, not as absence" \
  "-" "$(account_binding_latest coder)"
t "the store is append-only — nothing was deleted or updated" \
  "5" "$(sqlite3 "$TASKS_DB" "SELECT COUNT(*) FROM account_binding_events;")"

# --- provider quota samples ----------------------------------------------
account_usage_sample_record max-a "$T0" 10 "2026-09-19T12:00:00Z" 30 "2026-09-22T00:00:00Z" coder
account_usage_sample_record max-a "$T1" 40 "2026-09-19T12:00:00Z" 45 "2026-09-22T00:00:00Z" coder
t "two readings at different asOf are two rows" \
  "2" "$(sqlite3 "$TASKS_DB" "SELECT COUNT(*) FROM account_usage_samples WHERE account='max-a';")"

# criterion 7 + "never insert a recalled reading as fresh": re-reading the SAME
# cache (identical asOf) is idempotent, and a reading with no seat behind it is
# refused outright.
account_usage_sample_record max-a "$T1" 40 "2026-09-19T12:00:00Z" 45 "2026-09-22T00:00:00Z" coder
t "re-reading the same cache (same asOf) inserts once, not twice" \
  "2" "$(sqlite3 "$TASKS_DB" "SELECT COUNT(*) FROM account_usage_samples WHERE account='max-a';")"
account_usage_sample_record max-z "$T1" 40 "" 45 "" ""
t "a reading with NO source agent is refused (it is a recall, not an observation)" \
  "0" "$(sqlite3 "$TASKS_DB" "SELECT COUNT(*) FROM account_usage_samples WHERE account='max-z';")"
account_usage_sample_record max-y "$T1" "" "" "" "" coder
t "a reading with no percentages at all stores nothing" \
  "0" "$(sqlite3 "$TASKS_DB" "SELECT COUNT(*) FROM account_usage_samples WHERE account='max-y';")"
t "the earlier sample was NOT overwritten by the later one (append, not replace)" \
  "10.0" "$(sqlite3 "$TASKS_DB" "SELECT five_pct FROM account_usage_samples WHERE account='max-a' AND as_of=$T0;")"

# --- the history view's reset guard (criterion 8) -------------------------
H=$(account_usage_history_rows 0 max-a)
t "a clean bracket yields a 7d delta" "15" "$(jq -r '.[0].sevenDayPpDelta' <<<"$H")"
t "and a 5h delta"                    "30" "$(jq -r '.[0].fiveHourPpDelta' <<<"$H")"
t "the row names which seats produced the readings" \
  "coder" "$(jq -r '.[0].sourceAgents | join(",")' <<<"$H")"

# a reset between the two samples: the vendor's reset stamp moves AND the pct
# falls. The delta must be withheld, not computed across the seam.
account_usage_sample_record max-r "$T0" 80 "2026-09-19T12:00:00Z" 90 "2026-09-22T00:00:00Z" coder
account_usage_sample_record max-r "$T1"  5 "2026-09-19T18:00:00Z" 12 "2026-09-29T00:00:00Z" coder
HR=$(account_usage_history_rows 0 max-r)
t "criterion 8 — a reset between snapshots withholds the 7d delta" \
  "null" "$(jq -r '.[0].sevenDayPpDelta' <<<"$HR")"
t "criterion 8 — and says so explicitly" "true" "$(jq -r '.[0].resetCrossed' <<<"$HR")"

# a single sample is not a delta
account_usage_sample_record max-1 "$T0" 10 "" 20 "" coder
H1=$(account_usage_history_rows 0 max-1)
t "one sample yields no delta (not a zero)" "null" "$(jq -r '.[0].sevenDayPpDelta' <<<"$H1")"

# --- no store at all: best-effort, never fatal ---------------------------
( TASKS_DB="$TMP/nope/tasks.db" account_binding_record ghost max-a create "$NOW" ) >/dev/null 2>&1
t "a missing store makes a record a no-op, not a failure" "0" "$?"
t "and a read of a missing store returns empty" "" \
  "$(TASKS_DB="$TMP/nope/tasks.db" account_binding_at ghost "$NOW")"
t "and the samples reader returns an empty array, not an error" "[]" \
  "$(TASKS_DB="$TMP/nope/tasks.db" account_usage_samples_json 0)"

# ===========================================================================
# PART C — the MIGRATION reaches an EXISTING board.
#
# The population this row is about is not fresh boxes. Every live 5dive store was
# stamped at the previous schema epoch, and _tasks_db_migration_needed SKIPS the
# whole migration when the stamp equals the shipped value — so a new table added
# without bumping the epoch ships green on every harness (they all start from an
# empty dir and take the canonical schema) and reaches no existing board at all.
# Case 2 is the negative control that keeps case 1 from measuring nothing.
# ===========================================================================
PREV_EPOCH='3932-2'   # the stamp every live store carries before this change
NEW_TABLES=(account_binding_events account_usage_samples)

MIGDIRS=()
have_table() {
  sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$1' LIMIT 1;" 2>/dev/null
}
count_tables() { local n=0 x; for x in "$@"; do [[ "$(have_table "$x")" == 1 ]] && n=$((n+1)); done; printf '%s' "$n"; }
stamped()   { sqlite3 -cmd ".timeout 5000" "$TASKS_DB" "SELECT value FROM task_prefs WHERE key='schema_epoch';" 2>/dev/null; }
# A NEW tree per case. Never re-use one by deleting its db: DIVE-1479 stamps a
# durable "this board existed" sentinel, and a missing table on such a board is
# the silent-recreate trap — tasks_db_init correctly ALARMS and exits instead of
# quietly re-creating, which would kill this harness mid-run.
born_prev() {
  local d; d="$(mktemp -d /tmp/acct-hist-mig.XXXXXX)"; MIGDIRS+=("$d")
  STATE_DIR="$d"; TASKS_DIR="$d/tasks"; TASKS_DB="$d/tasks/tasks.db"; mkdir -p "$TASKS_DIR"
  tasks_db_init >/dev/null 2>&1
  local x; for x in "${NEW_TABLES[@]}"; do
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" "DROP TABLE IF EXISTS $x;" >/dev/null 2>&1
  done
  sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "INSERT INTO task_prefs(key,value,updated_at) VALUES ('schema_epoch','$PREV_EPOCH',datetime('now'))
       ON CONFLICT(key) DO UPDATE SET value=excluded.value;" >/dev/null 2>&1
}

born_prev
t "fixture: a store stamped at the previous epoch starts WITHOUT the new tables" \
  "0" "$(count_tables "${NEW_TABLES[@]}")"
tasks_db_init >/dev/null 2>&1
t "an existing board re-migrates and gains both tables" \
  "2" "$(count_tables "${NEW_TABLES[@]}")"
t "and is re-stamped to the shipped epoch" "$_TASKS_SCHEMA_EPOCH" "$(stamped)"
t "the shipped epoch is not the previous one (or no live store would re-migrate)" \
  "yes" "$([[ "$_TASKS_SCHEMA_EPOCH" != "$PREV_EPOCH" ]] && echo yes || echo no)"

# Negative control: put the epoch back and the same store stays stranded. If this
# does not go red, the arm above is not measuring the gate.
SHIPPED="$_TASKS_SCHEMA_EPOCH"
_TASKS_SCHEMA_EPOCH="$PREV_EPOCH"
born_prev
tasks_db_init >/dev/null 2>&1
t "control — with the epoch un-bumped the existing board is STRANDED (0 tables)" \
  "0" "$(count_tables "${NEW_TABLES[@]}")"
_TASKS_SCHEMA_EPOCH="$SHIPPED"
for d in "${MIGDIRS[@]}"; do rm -rf "$d"; done

echo "-----"
echo "account_binding_history_unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
