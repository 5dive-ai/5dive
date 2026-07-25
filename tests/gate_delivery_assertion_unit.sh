#!/usr/bin/env bash
# DIVE-1968 criterion 3 — THE DELIVERY ASSERTION.
#
# A gate that records neither an `ok` row nor an `error` row must not report as
# filed-and-pinged. Measured motivation: 5 of 9 real post-DIVE-1927 gates left NO
# delivery row at all, so they were invisible to the only audit this ticket rests
# on. This asserts the invariant at the wrapper, which is where it holds for exits
# that do not exist yet — the four that exist today were each written intending to
# record something, and the hole appeared anyway.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/gate-delivery-assert.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_agent_runtime.sh cmd_task.sh; do
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
# Keep the rows out of production telemetry (DIVE-1968's own fence) AND capture
# them locally so this test can read what it wrote — the safe case the fence wants.
export FIVEDIVE_NO_HUMAN_SEND=1
FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"

PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
rows()   { [[ -f "$FIVEDIVE_GATE_NOTIFY_LOG" ]] && wc -l <"$FIVEDIVE_GATE_NOTIFY_LOG" || echo 0; }
reset()  { : >"$FIVEDIVE_GATE_NOTIFY_LOG"; }

# ── 1. SILENT EXIT: inner path returns 0 having recorded nothing ──────────────
# The measured hole. Must synthesise an error verdict and downgrade rc 0 -> 3.
reset
_task_need_notify_deliver() { return 0; }
out=$(task_need_notify DIVE-9001 decision "ask" "" 2>&1); rc=$?
[[ $rc -eq 3 ]] \
  && ok_t "silent notify path is rc 3 (filed unnotified), not a bare rc 0" \
  || fail_t "silent notify path returned rc=$rc, expected 3 — a gate nobody was pinged for reported as pinged"
grep -q 'result=error' "$FIVEDIVE_GATE_NOTIFY_LOG" \
  && ok_t "a synthetic error row is written for the unrecorded delivery" \
  || fail_t "no error row written — the gate stays invisible to the audit"
grep -q 'UNVERIFIABLE\|no delivery verdict recorded' "$FIVEDIVE_GATE_NOTIFY_LOG" \
  && ok_t "the row names the hole (no verdict) rather than guessing a cause" \
  || fail_t "row detail does not name the missing verdict"
grep -qi 'UNVERIFIABLE' <<<"$out" \
  && ok_t "the filer is warned loudly on stderr" \
  || fail_t "silent to the filer: $out"
[[ "$(rows)" == "1" ]] \
  && ok_t "exactly one synthetic row (not one per branch)" \
  || fail_t "expected 1 row, got $(rows)"

# ── 1b. DELIVERED BUT UNRECORDED: backfill an ok row, do NOT call it a failure ─
# The larger half of the measured 5. Labelling a confirmed send as an error would
# re-contaminate the dataset with the opposite bias — on the ticket about a
# mis-measured one. Caught by two pre-existing tests going red on the first cut.
reset
_task_need_notify_deliver() { TASK_SEND_DELIVERED=1; TASK_SEND_MESSAGE_IDS=77; return 0; }
task_need_notify DIVE-9011 decision "ask" "" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "a confirmed-but-unrecorded send keeps rc 0" \
  || fail_t "confirmed delivery downgraded to rc=$rc"
grep -q 'result=ok' "$FIVEDIVE_GATE_NOTIFY_LOG" && [[ "$(rows)" == "1" ]] \
  && ok_t "the missing row is backfilled as ok, not invented as error" \
  || fail_t "wrong verdict for a confirmed send: $(cat "$FIVEDIVE_GATE_NOTIFY_LOG")"
# detail is written through %q, so spaces arrive backslash-escaped — match on a
# single token rather than a phrase, or this passes/fails on the quoting.
grep -q 'backfilled' "$FIVEDIVE_GATE_NOTIFY_LOG" \
  && ok_t "the backfilled row is marked as such (not passed off as a first-hand receipt)" \
  || fail_t "backfilled row is indistinguishable from a real receipt"

# ── 2. NON-ZERO SILENT EXIT: rc is preserved, not overwritten ────────────────
reset
_task_need_notify_deliver() { return 4; }
task_need_notify DIVE-9002 approval "ask" "" >/dev/null 2>&1; rc=$?
[[ $rc -eq 4 ]] \
  && ok_t "a non-zero rc from the inner path survives the assertion" \
  || fail_t "assertion clobbered rc=4 -> $rc"
grep -q 'rc=4' "$FIVEDIVE_GATE_NOTIFY_LOG" \
  && ok_t "the synthesised row carries the inner rc for diagnosis" \
  || fail_t "inner rc not recorded"

# ── 3. FALSE-POSITIVE GUARD: a recorded verdict must not be re-recorded ──────
# The assertion firing on a path that DID log would double-count every delivery
# and re-inflate the telemetry this ticket spent a round decontaminating.
reset
_task_need_notify_deliver() {
  _task_gate_delivery_log ok "$1" 123 456 "confirmed Bot API send"
  return 0
}
task_need_notify DIVE-9003 decision "ask" "" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "a delivered gate still returns rc 0" \
  || fail_t "delivered gate downgraded to rc=$rc"
[[ "$(rows)" == "1" ]] && ! grep -q 'result=error' "$FIVEDIVE_GATE_NOTIFY_LOG" \
  && ok_t "no synthetic row added on top of a real ok row" \
  || fail_t "assertion double-logged a successful delivery: $(cat "$FIVEDIVE_GATE_NOTIFY_LOG")"

# ── 4. A LOGGED FAILURE IS A VERDICT ────────────────────────────────────────
reset
_task_need_notify_deliver() {
  _task_gate_delivery_log error "$1" "" "" "no paired channel for filer x or anyone above it; shape=top-of-org"
  return 3
}
task_need_notify DIVE-9004 manual "ask" "" >/dev/null 2>&1; rc=$?
[[ $rc -eq 3 && "$(rows)" == "1" ]] \
  && ok_t "an already-logged failure is left alone (rc 3, one row)" \
  || fail_t "assertion re-logged a logged failure: rc=$rc rows=$(rows)"

# ── 5. COUNTER RESET BETWEEN GATES ──────────────────────────────────────────
# The counter is a global; if it leaked, gate N+1 would inherit gate N's verdict
# and the assertion would go quietly inert — the same fail-open shape as the
# unfenced log itself.
reset
_task_need_notify_deliver() { _task_gate_delivery_log ok "$1" 1 2 ok; return 0; }
task_need_notify DIVE-9005 decision "ask" "" >/dev/null 2>&1
_task_need_notify_deliver() { return 0; }
task_need_notify DIVE-9006 decision "ask" "" >/dev/null 2>&1; rc=$?
[[ $rc -eq 3 ]] \
  && ok_t "the verdict counter resets per gate (no leak from the previous gate)" \
  || fail_t "counter leaked: a silent gate after a delivered one returned rc=$rc"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
