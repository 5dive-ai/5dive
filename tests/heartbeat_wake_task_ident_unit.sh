#!/usr/bin/env bash
# `heartbeat wake-task` resolves the row's ident instead of inventing DIVE-<id>.
#
# `wake-task <agent> <task_id> [<task_ident>]` took the third argument as
# optional and defaulted it to "DIVE-${task_id}". A row's id and its ident
# NUMBER are independent columns, so that default is right only by coincidence:
# id 553 is DIVE-546. The exit hints tell an operator to pass <task_id> alone,
# which is the path that fabricated. `wake-task claude-qa 553` logged the forced
# wake onto DIVE-553, filed the loop defect against DIVE-553, and typed
# `/goal DIVE-553 … 5dive task show DIVE-553` into the seat; the seat found no
# such row and started nothing, while the verb reported success.
#
# Every arm below runs against a throwaway TASKS_DB holding ONE row whose id and
# ident number deliberately disagree — the shape the old default got wrong. The
# wake itself is stubbed (this harness grades the ident, not the transport).
# Run: bash tests/heartbeat_wake_task_ident_unit.sh  (no root, no network).
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-waketask-ident.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e; tasks_db_init >/dev/null 2>&1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { [[ "$1" == *"$2"* ]]; }

# --- The row the old default got wrong: id 553, ident DIVE-546 ---------------
ROW_ID=553; ROW_IDENT="DIVE-546"; FABRICATED="DIVE-${ROW_ID}"
db "INSERT INTO tasks(id, ident, title, status, priority, assignee, created_by, created_at, project_key)
    VALUES(${ROW_ID}, '${ROW_IDENT}', 'seeded row', 'todo', 'high', 'claude-qa', 'harness', datetime('now'), 'dive');" \
  >/dev/null 2>&1

# --- Stubs: grade the IDENT, not the transport -------------------------------
# The wake itself, the defect record and the fresh probe are graded by their own
# harnesses. Each stub records the ident it was handed, which is the payload.
require_root()                { :; }
_hb_effective_fresh()         { printf 'false'; }
_hb_recall_cite()             { printf ''; }
_hb_carryover_clause()        { printf ''; }
LOG=""; WAKE_IDENT=""; DEFECT_IDENT=""
_hb_log()                     { LOG="${LOG}$*"$'\n'; }
_hb_wake()                    { WAKE_IDENT="${4:-}"; return 0; }
_hb_wake_task_record_defect() { DEFECT_IDENT="${3:-}"; return 0; }

# `fail` exits, so every call runs in a subshell and reports through a file.
run_wake() { # <args...> -> prints "rc|log|wake_ident|defect_ident"
  local out; out="$TMP/run.$$"
  (
    LOG=""; WAKE_IDENT=""; DEFECT_IDENT=""
    cmd_heartbeat_wake_task "$@" >"$TMP/stdout" 2>"$TMP/stderr"
    printf '%s|%s|%s|%s' "0" "${LOG//$'\n'/ }" "$WAKE_IDENT" "$DEFECT_IDENT" > "$out"
  ) || printf '%s|%s||' "1" "$(tr -d '\n' < "$TMP/stderr")" > "$out"
  cat "$out"
}

# --- 0) PRECONDITION: the row's id and ident number really do differ ---------
# Without this the arms below would pass on a tree that fabricates, because
# DIVE-553 and the row's ident would be the same string.
[[ "$ROW_IDENT" != "$FABRICATED" ]] \
  && ok_t "precondition: row id ${ROW_ID} and ident ${ROW_IDENT} disagree (the shape the default got wrong)" \
  || bad_t "precondition: id and ident differ" "both are ${ROW_IDENT}"
[[ "$(db "SELECT ident FROM tasks WHERE id=${ROW_ID};")" == "$ROW_IDENT" ]] \
  && ok_t "precondition: the seeded row is readable and carries ${ROW_IDENT}" \
  || bad_t "precondition: seeded row readable" "got $(db "SELECT ident FROM tasks WHERE id=${ROW_ID};")"

# --- A) <task_ident> omitted: the ident comes from the ROW -------------------
R="$(run_wake claude-qa "$ROW_ID")"
RC="${R%%|*}"; REST="${R#*|}"; R_LOG="${REST%%|*}"; REST="${REST#*|}"
R_WAKE="${REST%%|*}"; R_DEFECT="${REST#*|}"

[[ "$RC" == "0" ]] \
  && ok_t "A0: a wake on an existing id succeeds" \
  || bad_t "A0: a wake on an existing id succeeds" "rc=$RC log=$R_LOG"
has "$R_LOG" "forced wake onto ${ROW_IDENT}" \
  && ok_t "A1: the heartbeat log names ${ROW_IDENT}" \
  || bad_t "A1: the heartbeat log names ${ROW_IDENT}" "log: $R_LOG"
! has "$R_LOG" "$FABRICATED" \
  && ok_t "A1b: ... and never names the fabricated ${FABRICATED}" \
  || bad_t "A1b: log must not name ${FABRICATED}" "log: $R_LOG"
[[ "$R_WAKE" == "$ROW_IDENT" ]] \
  && ok_t "A2: the wake is handed ${ROW_IDENT}" \
  || bad_t "A2: the wake is handed ${ROW_IDENT}" "got '$R_WAKE'"
[[ "$R_DEFECT" == "$ROW_IDENT" ]] \
  && ok_t "A3: the loop defect is filed against ${ROW_IDENT}, not ${FABRICATED}" \
  || bad_t "A3: the loop defect is filed against ${ROW_IDENT}" "got '$R_DEFECT'"

# --- A4) the dispatch the seat actually receives -----------------------------
# The nudge is a pure function of the ident, and it is the surface the operator
# saw go wrong: `/goal DIVE-553 … 5dive task show DIVE-553` typed into a seat.
NUDGE="$(_hb_nudge_text claude-qa "$ROW_ID" "$R_WAKE" 2>/dev/null)"
has "$NUDGE" "/goal ${ROW_IDENT}" \
  && ok_t "A4: the dispatch opens '/goal ${ROW_IDENT}'" \
  || bad_t "A4: the dispatch opens '/goal ${ROW_IDENT}'" "got: ${NUDGE:0:120}"
has "$NUDGE" "5dive task show ${ROW_IDENT}" \
  && ok_t "A4b: ... and tells the seat to read ${ROW_IDENT}" \
  || bad_t "A4b: dispatch reads ${ROW_IDENT}" "got: ${NUDGE:0:200}"
! has "$NUDGE" "$FABRICATED" \
  && ok_t "A4c: ... and the seat is never sent to ${FABRICATED}" \
  || bad_t "A4c: dispatch must not name ${FABRICATED}" "got: ${NUDGE:0:200}"

# --- B) an id with no row is REFUSED, not fabricated -------------------------
R="$(run_wake claude-qa 999999)"
RC="${R%%|*}"; R_ERR="${R#*|}"; R_ERR="${R_ERR%%|*}"
[[ "$RC" != "0" ]] \
  && ok_t "B1: an id with no row is refused" \
  || bad_t "B1: an id with no row is refused" "it succeeded"
has "$R_ERR" "999999" \
  && ok_t "B2: ... and the refusal names the id the operator typed" \
  || bad_t "B2: refusal names the id" "stderr: $R_ERR"

# --- C) the third argument stays an override, but only an AGREEING one -------
R="$(run_wake claude-qa "$ROW_ID" "$ROW_IDENT")"
[[ "${R%%|*}" == "0" ]] \
  && ok_t "C1: an explicit <task_ident> that agrees with the row is accepted" \
  || bad_t "C1: agreeing override accepted" "$R"
R="$(run_wake claude-qa "$ROW_ID" "DIVE-9999")"
RC="${R%%|*}"; R_ERR="${R#*|}"; R_ERR="${R_ERR%%|*}"
[[ "$RC" != "0" ]] \
  && ok_t "C2: an explicit <task_ident> that disagrees is refused, not preferred" \
  || bad_t "C2: disagreeing override refused" "it succeeded"
{ has "$R_ERR" "DIVE-9999" && has "$R_ERR" "$ROW_IDENT"; } \
  && ok_t "C3: ... and the refusal names both what was asked for and what the row is" \
  || bad_t "C3: refusal names both idents" "stderr: $R_ERR"

# --- D) the pre-existing usage check is unchanged ----------------------------
[[ "$(run_wake claude-qa "$ROW_IDENT")" != 0* ]] \
  && ok_t "D1: an ident passed as <task_id> is still refused by the usage check" \
  || bad_t "D1: ident as <task_id> refused"
[[ "$(run_wake "" "$ROW_ID")" != 0* ]] \
  && ok_t "D2: a missing <agent> is still refused" \
  || bad_t "D2: missing agent refused"

# =============================================================================
# MUTANT — re-introduce the exact defect in-process and require the arms to die.
# =============================================================================
# The mutation replaces the row lookup with the old fabrication. M0 is a
# BEFORE/AFTER pair on purpose: "the lookup is gone after the sed" is also true
# of a sed that matched nothing, which would make every arm below vacuous.
ORIG="$(declare -f cmd_heartbeat_wake_task)"
MUT="$(printf '%s\n' "$ORIG" | sed 's|^.*SELECT COALESCE(ident.*$|    row_ident="DIVE-${task_id}"|')"

has "$ORIG" "SELECT COALESCE(ident" \
  && ok_t "M0a: BEFORE — the shipped function really does look the ident up in the row" \
  || bad_t "M0a: shipped function looks the ident up" "no lookup found; every mutant arm below would be vacuous"
! has "$MUT" "SELECT COALESCE(ident" \
  && ok_t "M0b: AFTER — the mutation really removed that lookup (the sed matched)" \
  || bad_t "M0b: mutation removed the lookup" "the sed did not match; the mutant is not mutated"

eval "$MUT"
R="$(run_wake claude-qa "$ROW_ID")"
REST="${R#*|}"; M_LOG="${REST%%|*}"; REST="${REST#*|}"; M_WAKE="${REST%%|*}"; M_DEFECT="${REST#*|}"

has "$M_LOG" "forced wake onto ${FABRICATED}" \
  && ok_t "M1: MUTANT fabricates ${FABRICATED} in the log — A1 would be red on it" \
  || bad_t "M1: mutant fabricates in the log" "log: $M_LOG"
[[ "$M_WAKE" == "$FABRICATED" ]] \
  && ok_t "M2: MUTANT hands the wake ${FABRICATED} — A2 would be red on it" \
  || bad_t "M2: mutant fabricates for the wake" "got '$M_WAKE'"
[[ "$M_DEFECT" == "$FABRICATED" ]] \
  && ok_t "M3: MUTANT files the defect against ${FABRICATED} — A3 would be red on it" \
  || bad_t "M3: mutant fabricates for the defect record" "got '$M_DEFECT'"
M_NUDGE="$(_hb_nudge_text claude-qa "$ROW_ID" "$M_WAKE" 2>/dev/null)"
has "$M_NUDGE" "/goal ${FABRICATED}" \
  && ok_t "M4: MUTANT sends the seat to ${FABRICATED} — A4 would be red on it" \
  || bad_t "M4: mutant sends the seat to the fabricated ident" "got: ${M_NUDGE:0:120}"
[[ "$(run_wake claude-qa 999999)" == 0* ]] \
  && ok_t "M5: MUTANT 'succeeds' on an id with no row — B1 would be red on it" \
  || bad_t "M5: mutant succeeds on a nonexistent id" "it refused"

eval "$ORIG"
R="$(run_wake claude-qa "$ROW_ID")"
REST="${R#*|}"; REST="${REST#*|}"
[[ "${REST%%|*}" == "$ROW_IDENT" ]] \
  && ok_t "M6: RESTORE took — the fixed function is back and resolves ${ROW_IDENT} again" \
  || bad_t "M6: restore took" "got '${REST%%|*}' (later arms would grade the mutant)"

echo "-----"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
