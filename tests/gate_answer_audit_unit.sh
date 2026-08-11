#!/usr/bin/env bash
# TIER: nightly — 9.4s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-2090 isolated unit harness — a stored gate answer must carry an audit row.
#
# WHY THIS EXISTS. `cmd_task_answer` emitted `task answer gate` rows from its
# PRE-CHECKS only: the approval/secret/manual/access human-evidence block, and
# the tier-2 provenance-floor refusal. Neither fires for a `decision` gate below
# tier 2, so the answer UPDATE — which stamps need_answer, need_answered_at,
# need_answered_by, need_answered_uid and a DIVE-756 closure signature — ran with
# NO audit event behind it at all. Scale when this landed: at least 78 answered
# `decision` gates on the live board, none auditable (2026-07-26 17:16 UTC — a
# lower bound at a moment, it climbs with every gate answered). That is the defect
# reported three times (DIVE-2051 twice, DIVE-2084 once): a stored, signed,
# nonce-bearing gate answer with nothing in the audit log to attribute it to,
# which is precisely the property DIVE-756 exists to provide.
#
# The divergence ran BOTH ways, which is why the fix is a row at the WRITE and
# not a louder pre-check: the pre-check row is logged BEFORE the write and says
# a CHECK passed, so an approval that clears the evidence block and then trips
# the tier-2 floor (or one of the two `--value` usage `fail`s) leaves an `ok`
# row with no answer stored.
#
# What is pinned here:
#   1. LIVENESS: a tier-1 `decision` answer both STORES the answer and emits a
#      `task answer gate` row — the case that produced nothing before this fix;
#   2. the row is the WRITE-SITE row, discriminated by `answered_by=` (a field
#      no pre-check site carries) and it reports the provenance AS STORED;
#   3. NON-VACUITY the other way: a refused tier-2 answer stores NOTHING and
#      emits NO `answered_by=` row — the write-site row cannot appear without a
#      write, so its presence is evidence of an answer, not of an attempt;
#   4. the row is fenced on STORE IDENTITY (DIVE-2054/2010): off the prod store
#      it is withheld and the withholding is ANNOUNCED, never silent. We diff
#      the FENCE'S OWN allow/withhold decision, not the resulting DB row —
#      measuring the row would measure the stub;
#   5. the real fleet audit log is never touched by this suite, whichever case
#      runs and whatever $EUID this suite happens to run under.
# Run: bash tests/gate_answer_audit_unit.sh   (no root, no network)
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
TMP="$(mktemp -d /tmp/gate-answer-audit.XXXXXX)"
FAILURES=()
# DIVE-2187: an unexplained rc=1 under concurrent runs (11/12) was only ever
# seen live, because a green-or-red exit both nuked $TMP on the way out — the
# next occurrence had nothing to inspect and needed a repro. On failure, keep
# the dir and dump every captured artifact instead of deleting the evidence.
cleanup() {
  local rc="$1"
  if [[ "${FAIL:-0}" -gt 0 || "$rc" -ne 0 ]]; then
    printf '\n=== FAILURE: TMP preserved for inspection: %s ===\n' "$TMP" >&2
    if [[ ${#FAILURES[@]} -gt 0 ]]; then
      printf -- '--- failing assertions (repeated so scrollback does not need a repro) ---\n' >&2
      printf '%s\n' "${FAILURES[@]}" >&2
    fi
    for f in "${AUDIT_CALLS:-}" "$TMP"/*.out "$TMP"/*.err; do
      [[ -n "$f" && -s "$f" ]] || continue
      printf -- '--- %s ---\n' "$f" >&2
      cat "$f" >&2
    done
  else
    rm -rf "$TMP"
  fi
}
trap 'rc=$?; cleanup "$rc"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: cleanup() used to read $? itself; now takes it as $1 so this wrapper's own `rc=$?` doesn't clobber it before cleanup runs.

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

# Suite guard: remember where the REAL log ended before this run, so the check at
# the bottom can read ONLY the bytes appended during it.
#
# DIVE-3250: this used to compare the offset before/after and fail if it MOVED.
# That measured "did the file grow", not "did I grow it" — and every agent on this
# box appends to it continuously, so on a live host it was a false red BY
# CONSTRUCTION (measured: two full gate-corpus sweeps red on a frozen clean tree,
# 6/6 green standalone on a quiet box; one unrelated line appended mid-run
# reproduces it exactly). Do NOT restore the byte-equality arm here, and do not
# copy it from tests/audit_task_store_fence_unit.sh / audit_nonroot_unit.sh /
# audit_exit_trap_row_unit.sh — they still carry the defective shape (DIVE-3251).
# The property this suite actually wants is "no row from THIS suite reached the
# real log", which is an identity filter, not an offset. Same shape as the arm
# already proven on main in tests/gate_evidence_form_unit.sh, which fences the
# identical command surface.
REALLOG=/var/log/5dive/agent-audit.log
REALLOG_OFFSET=0
[[ -r "$REALLOG" ]] && REALLOG_OFFSET=$(wc -c <"$REALLOG" 2>/dev/null || echo 0)

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # AFTER sourcing: header.sh turns `set -e` back on.
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() {
  FAIL=$((FAIL+1))
  printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"
  FAILURES+=("FAIL - $1"$'\n'"   ${2:-}")
}
addt()  { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }

AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
# Preconditions, not observables: never ping a channel, and keep the tier-2
# floor switched on so case 3 is deterministic on any box.
task_need_notify() { return 0; }
_gate_proof_enforced() { return 0; }
reset() { : >"$AUDIT_CALLS"; unset _TASK_STORE_AUDIT_FENCED; }

nat() { db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${1};"; }
nby() { db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE id=${1};"; }
# The write-site row is the one carrying `answered_by=`; no pre-check site does.
writerows() { grep -c 'task answer gate.*answered_by=' "$AUDIT_CALLS"; }

# --- 1+2. ON the prod store: a tier-1 decision answer audits at the write -----
# This is the exact shape that produced a stored answer and zero audit rows.
reset
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"        # active store IS prod -> allowed
t1=$(addt --assignee=dev -- "fixture decision gate")
cmd_task_need "$t1" --type=decision --options="A|B" --recommend="A" \
  --ask="pick one" --tier=1 >/dev/null 2>&1
cmd_task_answer "$t1" --value="B" --human >/dev/null 2>&1
STORED_AT=$(nat "$t1"); STORED_BY=$(nby "$t1")
if [[ -n "$STORED_AT" ]]; then
  ok_t "tier-1 decision answer is STORED (liveness — the path under test ran)"
else
  bad_t "answer was not stored, so nothing below measures the fix" "at='$STORED_AT'"
fi
if [[ "$(writerows)" == "1" ]]; then
  ok_t "a stored tier-1 decision answer emits exactly one write-site audit row"
else
  bad_t "stored answer must emit ONE write-site audit row" \
        "count=$(writerows) calls=$(cat "$AUDIT_CALLS")"
fi
ROW=$(grep 'task answer gate.*answered_by=' "$AUDIT_CALLS" | head -1)
if [[ "$ROW" == *"answered_by=$STORED_BY"* && -n "$STORED_BY" ]]; then
  ok_t "the row reports the provenance AS STORED (answered_by=$STORED_BY)"
else
  bad_t "row must echo the stored need_answered_by" "stored='$STORED_BY' row='$ROW'"
fi
if [[ "$ROW" == *"type=decision"* && "$ROW" == *"task="* ]]; then
  ok_t "the row names the gate type and the task"
else
  bad_t "row must name type + task" "row='$ROW'"
fi
if grep -q 'task answer gate.*value=' "$AUDIT_CALLS"; then
  bad_t "the answer VALUE must never reach the fleet audit log" "$ROW"
else
  ok_t "the answer value is not logged"
fi

# --- 3. NON-VACUITY: a REFUSED tier-2 answer writes nothing and audits no ----
#        write-site row. The refusal `fail`s, so run it in a subshell.
reset
t2=$(addt --assignee=dev -- "fixture hard gate")
cmd_task_need "$t2" --type=decision --options="A|B" --recommend="A" \
  --ask="spend money on ads" --tier=2 >/dev/null 2>&1
( cmd_task_answer "$t2" --value="A" ) >/dev/null 2>&1
RC=$?
if [[ "$RC" != "0" && -z "$(nat "$t2")" ]]; then
  ok_t "a non-human tier-2 answer is refused and stores nothing"
else
  bad_t "tier-2 floor must refuse and store nothing" "rc=$RC at='$(nat "$t2")'"
fi
if [[ "$(writerows)" == "0" ]]; then
  ok_t "a refused answer emits NO write-site row (row implies a write)"
else
  bad_t "write-site row appeared without a write" "$(cat "$AUDIT_CALLS")"
fi
if grep -q 'task answer gate.*reason=non-human answer on tier-2 floor' "$AUDIT_CALLS"; then
  ok_t "the refusal still audits through its own (pre-check) row"
else
  bad_t "the tier-2 refusal row went missing" "$(cat "$AUDIT_CALLS")"
fi

# --- 4. OFF the prod store: the row is fenced, and the fence ANNOUNCES it -----
reset
export FIVEDIVE_PROD_TASKS_DB="$TMP/somewhere-else/tasks.db"
t3=$(addt --assignee=dev -- "fixture off-store gate")
cmd_task_need "$t3" --type=decision --options="A|B" --recommend="A" \
  --ask="pick one" --tier=1 >/dev/null 2>&1
reset
cmd_task_answer "$t3" --value="B" --human >"$TMP/off.out" 2>"$TMP/off.err"
if [[ -n "$(nat "$t3")" ]]; then
  ok_t "off the prod store the answer still lands (the fence gates the LOG only)"
else
  bad_t "the fence must not cost the answer itself" "at='$(nat "$t3")'"
fi
if [[ "$(writerows)" == "0" ]]; then
  ok_t "off the prod store the write-site row is WITHHELD"
else
  bad_t "fixture store leaked a gate-answer row" "$(cat "$AUDIT_CALLS")"
fi
if grep -q 'telemetry withheld' "$TMP/off.err" && grep -q 'DIVE-2010' "$TMP/off.err"; then
  ok_t "the withholding is ANNOUNCED, never silent"
else
  bad_t "a silent fence is the same fail-open shape as no fence" "$(cat "$TMP/off.err")"
fi

# --- 5. suite guard: no row from THIS suite reached the real fleet log -------
# Read only the bytes appended since we started, then keep only rows bearing this
# run's identity (our user + the command surface this suite exercises). Rows from
# the other agents writing to this box concurrently are EXPECTED and must not red.
LEAKED=""
PROBED=0
if [[ -r "$REALLOG" ]]; then
  PROBED=1
  LEAKED=$(tail -c "+$((REALLOG_OFFSET + 1))" "$REALLOG" 2>/dev/null \
    | jq -rc --arg me "$(id -un 2>/dev/null)" \
        'select(.user == $me)
         | select(.cmd | startswith("task answer") or startswith("task need"))
         | .cmd + " " + ((.args // []) | join(" "))' \
        2>/dev/null | head -5)
fi
if [[ "$PROBED" -eq 0 ]]; then
  # An unreadable log is not a pass — it is an UNPROBED guard, and it says so
  # rather than scoring green (same reasoning as gate_lead_clear_stamp_unit.sh).
  printf 'skip - real fleet log not readable here; leak guard UNPROBED (not a pass)\n'
elif [[ -z "$LEAKED" ]]; then
  ok_t "no row from THIS suite reached the real fleet audit log"
else
  bad_t "this suite LEAKED fixture rows into the REAL audit log" "$LEAKED"
fi
# Report the offset delta as CONTEXT so no reader mistakes this for a proof that
# the file never moved. It moves; other agents write to it.
[[ -r "$REALLOG" ]] && printf '# note: real log grew %s bytes during this run (concurrent agents; expected)\n' \
  "$(( $(wc -c <"$REALLOG" 2>/dev/null || echo 0) - REALLOG_OFFSET ))"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
