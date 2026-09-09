#!/usr/bin/env bash
# DIVE-4154 arm D — THE PHONE-PING UNDO WINDOW.
#
# Measured motivation (DIVE-4150, gate_history 30d to 2026-09-09): of 193
# human-facing gates, 138 were withdrawn by the FILING SEAT itself after the
# phone had already rung; 76 of those inside 2 minutes. This harness grades the
# one claim that makes holding the ping safe: the HOLD IS ON THE PUSH AND ONLY
# ON THE PUSH, it is skipped whenever the filer said the gate cannot wait, and a
# held ping is never delivered for a gate that is no longer the live one.
#
# What it deliberately does NOT grade: whether the gate is visible on the
# dashboard / in `task inbox` during the window. That is not a property of this
# code — the gate row is written and committed by cmd_task_need BEFORE
# task_need_notify is reached, so those surfaces are unconditional. A test here
# asserting them would grade the fixture, not the change.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/gate-undo-window.XXXXXX)

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_agent_runtime.sh cmd_task.sh; do
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
export FIVEDIVE_NO_HUMAN_SEND=1
FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"

PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

MARK="$TMP/delivered"
# The stub stands in for the unchanged pre-DIVE-4154 deliverer. It must signal
# through a FILE, not a variable: on the held path it runs in a detached
# subshell, so an exported variable would never reach this shell and every
# "was it delivered?" assertion would read false — passing the withdrawal arms
# for the wrong reason and failing arm 3 for the wrong reason.
_task_need_notify_deliver_now() { printf '%s\n' "$1" >>"$MARK"; TASK_SEND_DELIVERED=1; return 0; }
delivered() { grep -qx "$1" "$MARK" 2>/dev/null; }

mkgate() {   # $1=ident $2=priority
  local ident="$1" prio="${2:-high}"
  db "INSERT INTO tasks (ident,title,status,priority,assignee,created_by)
      VALUES ($(sqlq "$ident"),'undo window fixture','blocked',$(sqlq "$prio"),'dev','dev');"
  db "UPDATE tasks SET need_asked_at=datetime('now'), need_type='decision'
        WHERE ident=$(sqlq "$ident");"
}
reset() { : >"$FIVEDIVE_GATE_NOTIFY_LOG"; : >"$MARK"; TASK_GATE_DELIVERY_ROWS=0; TASK_GATE_ROUTE_URGENT=0; }

export _5DIVE_GATE_UNDO_WINDOW_SECS=1   # keep the harness fast; 120 in the shipped constant

# ── 1. THE HOLD ─────────────────────────────────────────────────────────────
reset; mkgate DIVE-9101 high
_task_need_notify_deliver DIVE-9101 decision "ask" "" ; rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "a held gate files clean (rc 0) — the hold is not an error" \
  || fail_t "held gate returned rc=$rc"
delivered DIVE-9101 \
  && fail_t "the push fired SYNCHRONOUSLY — nothing was held" \
  || ok_t "the push did not fire at filing time"
grep -q 'hold:1s' "$FIVEDIVE_GATE_NOTIFY_LOG" \
  && ok_t "the hold is RECORDED as a delivery row (auditable, not a silent drop)" \
  || fail_t "no hold row: $(cat "$FIVEDIVE_GATE_NOTIFY_LOG")"
[[ "${TASK_GATE_DELIVERY_ROWS:-0}" == "1" ]] \
  && ok_t "the hold row is credited, so the delivery assertion does not synthesise an error" \
  || fail_t "TASK_GATE_DELIVERY_ROWS=${TASK_GATE_DELIVERY_ROWS:-0}, expected 1"

# ── 2. THE WINDOW CLOSES ON A LIVE GATE: the push fires ─────────────────────
# The negative control for arms 3 and 4 — without it, "nobody was paged" passes
# for a window that never delivers anything at all.
sleep 2
delivered DIVE-9101 \
  && ok_t "a gate still live when the window closes IS pushed (the hold delays, it does not swallow)" \
  || fail_t "the held push never fired — the window swallowed a real gate"

# ── 3. WITHDRAWN INSIDE THE WINDOW: nobody is paged ─────────────────────────
reset; mkgate DIVE-9102 high
_task_need_notify_deliver DIVE-9102 decision "ask" ""
db "UPDATE tasks SET need_asked_at=NULL WHERE ident='DIVE-9102';"   # `task need --withdraw`
sleep 2
delivered DIVE-9102 \
  && fail_t "a gate withdrawn inside the window still paged the human — the whole arm" \
  || ok_t "a withdrawal inside the window pages NOBODY"
grep -q 'hold:withdrawn' "$FIVEDIVE_GATE_NOTIFY_LOG" \
  && ok_t "the non-page is recorded, not merely absent" \
  || fail_t "no withdrawn row: $(cat "$FIVEDIVE_GATE_NOTIFY_LOG")"

# ── 4. ANSWERED INSIDE THE WINDOW: nobody is paged ──────────────────────────
reset; mkgate DIVE-9103 high
_task_need_notify_deliver DIVE-9103 decision "ask" ""
db "UPDATE tasks SET need_answer='merge' WHERE ident='DIVE-9103';"
sleep 2
delivered DIVE-9103 \
  && fail_t "a gate answered inside the window still paged" \
  || ok_t "an answer inside the window pages nobody"

# ── 5. RE-FILE INSIDE THE WINDOW: the OLD child must not deliver ────────────
# Keying liveness on "something is pending" rather than on need_asked_at would
# let the retracted gate's child deliver the REPLACEMENT gate's page — an extra
# page, off a stale ask, with the new gate's own child still to come.
reset; mkgate DIVE-9104 high
_task_need_notify_deliver DIVE-9104 decision "old ask" ""
db "UPDATE tasks SET need_asked_at=datetime('now','+1 second') WHERE ident='DIVE-9104';"
sleep 2
delivered DIVE-9104 \
  && fail_t "the withdrawn gate's child delivered the RE-FILED gate's page" \
  || ok_t "a re-file inside the window is a different gate; the old child stands down"

# ── 6. priority=urgent SKIPS the window ─────────────────────────────────────
reset; mkgate DIVE-9105 urgent
_task_need_notify_deliver DIVE-9105 decision "ask" ""
delivered DIVE-9105 \
  && ok_t "an urgent ROW pushes immediately (no hold)" \
  || fail_t "the window delayed an urgent row's page"
grep -q 'hold:' "$FIVEDIVE_GATE_NOTIFY_LOG" \
  && fail_t "an urgent row logged a hold row" \
  || ok_t "no hold row for an urgent row"

# ── 7. --urgent on the GATE skips the window ────────────────────────────────
reset; mkgate DIVE-9106 high
TASK_GATE_ROUTE_URGENT=1 _task_need_notify_deliver DIVE-9106 decision "ask" ""
delivered DIVE-9106 \
  && ok_t "--urgent on the gate pushes immediately (no hold)" \
  || fail_t "the window delayed a gate the filer marked --urgent"

# ── 8. THE KILL SWITCH ──────────────────────────────────────────────────────
reset; mkgate DIVE-9107 high
_task_pref_set gate_undo_window off
_task_need_notify_deliver DIVE-9107 decision "ask" ""
delivered DIVE-9107 \
  && ok_t "gate-undo-window off restores the immediate push" \
  || fail_t "the kill switch did not restore the pre-DIVE-4154 push"
_task_pref_set gate_undo_window on
reset; mkgate DIVE-9108 high
_task_need_notify_deliver DIVE-9108 decision "ask" ""
delivered DIVE-9108 \
  && fail_t "gate-undo-window on did not re-enable the hold" \
  || ok_t "gate-undo-window on re-enables the hold"
sleep 2

# ── 9. A GARBAGE DURATION FALLS BACK TO THE CONSTANT, never to 0 or forever ─
reset; mkgate DIVE-9109 high
w=$(_5DIVE_GATE_UNDO_WINDOW_SECS="two minutes" _task_gate_undo_window_secs DIVE-9109)
[[ "$w" == "$_GATE_UNDO_WINDOW_SECS" ]] \
  && ok_t "a non-numeric duration override falls back to the sealed constant ($w s)" \
  || fail_t "non-numeric override yielded '$w', expected $_GATE_UNDO_WINDOW_SECS"
[[ "$_GATE_UNDO_WINDOW_SECS" == "120" ]] \
  && ok_t "the shipped window is 2 minutes, as the row specifies" \
  || fail_t "shipped window is ${_GATE_UNDO_WINDOW_SECS}s, expected 120"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
