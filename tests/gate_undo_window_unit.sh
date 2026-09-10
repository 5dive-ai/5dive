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
# lib/runs.sh is here for arm 9c ONLY: the e2e filing arm calls the real
# cmd_task_need, whose run-ledger touch (need.sh:2974) is unresolved without it.
# Every other arm drives the deliverer directly and never reaches that line.
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/runs.sh cmd_agent_runtime.sh cmd_task.sh; do
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

export _5DIVE_GATE_UNDO_WINDOW_SECS=4   # keep the harness fast; 120 in the shipped constant.
# 4s, not 1s: the fixture mutates the row AFTER the deferring call returns, and
# under load a sqlite write can take longer than a 1s window — the child then
# wins the race and the arm fails for a reason that is not the property. The
# margin is the harness making the state change unambiguously precede the wake.

# ── 1. THE HOLD ─────────────────────────────────────────────────────────────
reset; mkgate DIVE-9101 high
_task_need_notify_deliver DIVE-9101 decision "ask" "" ; rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "a held gate files clean (rc 0) — the hold is not an error" \
  || fail_t "held gate returned rc=$rc"
delivered DIVE-9101 \
  && fail_t "the push fired SYNCHRONOUSLY — nothing was held" \
  || ok_t "the push did not fire at filing time"
# A RANGE, not the literal window: the hold is the REMAINDER of an absolute
# window (arm 8c), so the second or two between mkgate writing need_asked_at and
# this call is legitimately subtracted. Pinning the exact number grades the
# harness's own scheduling, and fails on a loaded box for a correct implementation.
grep -qE 'hold:[1-4]s' "$FIVEDIVE_GATE_NOTIFY_LOG" \
  && ok_t "the hold is RECORDED as a delivery row (auditable, not a silent drop)" \
  || fail_t "no hold row: $(cat "$FIVEDIVE_GATE_NOTIFY_LOG")"
[[ "${TASK_GATE_DELIVERY_ROWS:-0}" == "1" ]] \
  && ok_t "the hold row is credited, so the delivery assertion does not synthesise an error" \
  || fail_t "TASK_GATE_DELIVERY_ROWS=${TASK_GATE_DELIVERY_ROWS:-0}, expected 1"

# ── 2. THE WINDOW CLOSES ON A LIVE GATE: the push fires ─────────────────────
# The negative control for arms 3 and 4 — without it, "nobody was paged" passes
# for a window that never delivers anything at all.
sleep 6
delivered DIVE-9101 \
  && ok_t "a gate still live when the window closes IS pushed (the hold delays, it does not swallow)" \
  || fail_t "the held push never fired — the window swallowed a real gate"

# ── 3. WITHDRAWN INSIDE THE WINDOW: nobody is paged ─────────────────────────
reset; mkgate DIVE-9102 high
_task_need_notify_deliver DIVE-9102 decision "ask" ""
db "UPDATE tasks SET need_asked_at=NULL WHERE ident='DIVE-9102';"   # `task need --withdraw`
sleep 6
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
sleep 6
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
sleep 6
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
sleep 6

# ── 8b. THE WINDOW IS ABSOLUTE: a re-nag on an OLD gate pings NOW ──────────
# task_need_notify is also driven by the heartbeat gate re-nag and the /inbox
# batch re-send, for gates asked long ago. Holding those would charge a gate a
# window it has already served many times over — and worse, the re-nag is the
# recovery path for a ping this very window lost to a dead box. Holding the
# recovery is how a delay becomes a swallow.
reset; mkgate DIVE-9110 high
db "UPDATE tasks SET need_asked_at=datetime('now','-2 hours') WHERE ident='DIVE-9110';"
_task_need_notify_deliver DIVE-9110 decision "ask" ""
delivered DIVE-9110 \
  && ok_t "a re-nag on a gate past its window pings immediately (the recovery path is never held)" \
  || fail_t "the window held a re-nag — a delayed ping became a swallowed one"
grep -q 'hold:' "$FIVEDIVE_GATE_NOTIFY_LOG" \
  && fail_t "an already-aged gate logged a hold row" \
  || ok_t "no hold row for a gate past its window"

# ── 8c. A PARTLY-SERVED WINDOW IS NOT RESTARTED ────────────────────────────
# Same defect as 8b, one notch smaller: a second call part-way through the window
# must serve only the REMAINDER, or a repeated call (the re-nag ladder) can hold
# a gate indefinitely by restarting its window every time.
#
# Graded on the RECORDED remainder, not on whether a push eventually landed. A
# delivery-based arm cannot see this at all: the FIRST call's child delivers at
# the original deadline either way, so `delivered` reads true for both the fixed
# and the broken shape — an arm that passes against the mutant, and flakes on the
# sleep timings while doing it.
reset; mkgate DIVE-9111 high
db "UPDATE tasks SET need_asked_at=datetime('now','-90 seconds') WHERE ident='DIVE-9111';"
_5DIVE_GATE_UNDO_WINDOW_SECS=120 _task_need_notify_deliver DIVE-9111 decision "ask" ""
if grep -qE 'hold:(2[6-9]|3[0-4])s' "$FIVEDIVE_GATE_NOTIFY_LOG"; then
  ok_t "a gate 90s into a 120s window is held for the ~30s REMAINDER, not a fresh 120"
else
  fail_t "window restarted on re-entry: $(grep -o 'hold:[0-9]*s' "$FIVEDIVE_GATE_NOTIFY_LOG" | head -1) (expected ~30s)"
fi
sleep 1

# ── 9. A GARBAGE DURATION FALLS BACK TO THE CONSTANT, never to 0 or forever ─
reset; mkgate DIVE-9109 high
w=$(_5DIVE_GATE_UNDO_WINDOW_SECS="two minutes" _task_gate_undo_window_secs DIVE-9109)
[[ "$w" == "$_GATE_UNDO_WINDOW_SECS" ]] \
  && ok_t "a non-numeric duration override falls back to the sealed constant ($w s)" \
  || fail_t "non-numeric override yielded '$w', expected $_GATE_UNDO_WINDOW_SECS"
[[ "$_GATE_UNDO_WINDOW_SECS" == "120" ]] \
  && ok_t "the shipped window is 2 minutes, as the row specifies" \
  || fail_t "shipped window is ${_GATE_UNDO_WINDOW_SECS}s, expected 120"


# ── 8d. AN AGE THE CODE CANNOT READ IS DELIVERED, NEVER HELD ───────────────
# The remainder subtraction runs on the value `db` returned. Three ways that
# value is not a non-negative integer, and holding is wrong for every one. These
# arms exist because the failure they guard is a DROPPED ping, not a late one —
# the outcome the whole mechanism is built to be incapable of.

# (i) A malformed need_asked_at. julianday() returns NULL and the CAST yields ''.
# Held, this charges a full window measured from NOW on every call, re-nag
# included: defect 8b reintroduced for that row, and invisible because the row
# still looks pending the whole time.
reset; mkgate DIVE-9113 high
db "UPDATE tasks SET need_asked_at='not-a-timestamp' WHERE ident='DIVE-9113';"
_task_need_notify_deliver DIVE-9113 decision "ask" ""
delivered DIVE-9113 \
  && ok_t "an unparseable need_asked_at pings immediately rather than holding forever" \
  || fail_t "an unparseable timestamp was held — the row can never outrun a window it cannot measure"

# (ii) Clock skew puts need_asked_at in the FUTURE, so the age is negative. Same
# swallow, and while the clock is ahead the row outruns the window on every call.
reset; mkgate DIVE-9114 high
db "UPDATE tasks SET need_asked_at=datetime('now','+300 seconds') WHERE ident='DIVE-9114';"
_task_need_notify_deliver DIVE-9114 decision "ask" ""
delivered DIVE-9114 \
  && ok_t "a future-dated gate (clock skew) pings immediately, not after the skew clears" \
  || fail_t "a negative age was held — clock skew can mute a gate for as long as it lasts"

# (iii) `db` puts an error string on stdout (a locked or corrupt database).
# Bash arithmetic parses a bare word as a variable NAME, so `$(( _secs - abc ))`
# under `set -euo pipefail` dies with "unbound variable" MID-FUNCTION: hold row
# unwritten, ping gone. Not a late page — no page, which is the one outcome this
# mechanism is built to be incapable of.
#
# Driven through the REAL resolver with `db` stubbed for the age query only, not
# against an inline copy of the guard: a copy grades the test, not the product,
# and would stay green against any shape of the shipped code.
reset; mkgate DIVE-9115 high
_orig_db=$(declare -f db)
eval "${_orig_db/#db/_db_real}"          # same body, second name
db() {                                    # intercept ONLY the age query
  if [[ "$*" == *julianday* ]]; then
    printf 'Error: database is locked\n'; : >"$TMP/stub_fired"; return 0
  fi
  _db_real "$@"
}
: >"$TMP/stub_fired"; rm -f "$TMP/stub_fired"
# RUN IT IN A SUBSHELL, AND ATTACH NO `||`. Two separate traps here:
#   - A `set -u` failure inside $(( )) is fatal to the SHELL, not a return code.
#     Called at top level it takes the whole harness down mid-run: no summary
#     line, no FAIL, just rc=1 — which reads like a crashed harness rather than a
#     graded defect, and the next reader "fixes" the harness. The subshell
#     contains the death so this arm can report it.
#   - But `( ... ) || fail_t` would REMOVE the death it is testing for: errexit is
#     exempt on the left of ||, and the exemption propagates INTO the subshell.
#     So: bare subshell, then assert on MARK, which the subshell writes through to
#     the parent as a FILE. Absence of the delivery IS the death.
( _task_need_notify_deliver DIVE-9115 decision "ask" "" ) >/dev/null 2>&1
eval "$_orig_db"; unset -f _db_real       # restore before asserting
# The stub must actually have fired, or this arm grades nothing and reads green
# against every shape of the shipped code.
[[ -f "$TMP/stub_fired" ]] \
  && ok_t "the non-numeric-age stub intercepted the age query (this arm is live)" \
  || fail_t "the db stub never fired — the non-numeric-age arm below is vacuous"
delivered DIVE-9115 \
  && ok_t "a non-numeric age pings immediately — it never reaches \$(( )) to die on set -u" \
  || fail_t "a non-numeric age dropped the ping: the guard is a filter, not the delivery condition"
reset


# ── 9b. `--urgent` SKIPS THE WINDOW ON THE HUMAN PATH TOO ──────────────────
# The env var TASK_GATE_ROUTE_URGENT is exported at ONE call site, the routed
# branch, so a human-bound gate never saw it and `--urgent` was silently ignored
# by this window. The row column is the durable form of the same fact and cannot
# be lost by a call site forgetting to re-export it.
#
# This arm is the PRECONDITION for raising the window: the whole argument that a
# longer delay is safe rests on the filer being able to opt out of it. At 120s a
# missed skip is a nuisance; at 900s it is a 15-minute hold on a gate whose filer
# said it could not wait.
reset; mkgate DIVE-9116 high
db "UPDATE tasks SET gate_urgent=1 WHERE ident='DIVE-9116';"
w=$(_task_gate_undo_window_secs DIVE-9116)
[[ "$w" == "0" ]] \
  && ok_t "gate_urgent=1 skips the window with NO env var set (the human path)" \
  || fail_t "--urgent is ignored on the human path: window=${w}s, so raising it delays urgent gates"

# NEGATIVE CONTROL: the column must not be read as urgent when the filer said
# nothing. Without this, a fix that returned 0 unconditionally reads green above.
reset; mkgate DIVE-9117 high
db "UPDATE tasks SET gate_urgent=0 WHERE ident='DIVE-9117';"
w=$(_task_gate_undo_window_secs DIVE-9117)
# Graded as non-zero, not as a literal: this harness pins the window to 4s for
# speed (line 60), so asserting the shipped 120 here fails for a reason that has
# nothing to do with the claim. The claim is that the skip is not unconditional.
[[ "$w" != "0" && -n "$w" ]] \
  && ok_t "gate_urgent=0 still holds the window (${w}s) — the skip is not unconditional" \
  || fail_t "gate_urgent=0 yielded '${w}', expected a non-zero hold"


# ── 9c. THE WRITE HALF OF 9b, GRADED WHERE IT IS REACHABLE (quinn, iteration 1) ─
# 9b above fixtures the column with a bare UPDATE, so it grades only the READ
# site (notify.sh reads gate_urgent off the row). The fix has a second half — the
# WRITE at need.sh's human-bound filing path, which persists the filer's
# `--urgent`. Deleting that line leaves 9b, gate_route_delivery_unit (51/0, whose
# --urgent case files a tier-1 DECISION and so exercises the OTHER, routed write)
# and the rest of the tree fully green while `--urgent` on a human-bound gate is
# silently ignored again — the exact defect the commit is named for. A harness
# that builds its fixture with SQL cannot grade the code that writes that fixture.
#
# So this arm files through the real cmd_task_need and asserts the COLUMN.
# `manual` is the type that pins it: it is tier-2 BY TYPE and not routable, so it
# takes the human-bound branch with no org chart to arrange, which is what makes
# the arm a control on the routed write as well — routed_reviewer must be empty
# or the arm has drifted onto the branch 9b's sibling already covers.
reset
db "INSERT INTO tasks (ident,title,status,priority,assignee,created_by)
    VALUES ('DIVE-9118','undo window e2e fixture','todo','high','dev','dev');"
cmd_task_need DIVE-9118 --type=manual --urgent \
  --ask="Approve the payment for the new box?" --from=dev >/dev/null 2>&1
[[ "$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-9118';")" == "" ]] \
  && ok_t "9c precondition: the e2e gate is HUMAN-BOUND (routed_reviewer empty) — the write under test is the human-path one" \
  || fail_t "9c drifted onto the ROUTED branch; this arm no longer grades need.sh's human-path write"
[[ "$(db "SELECT COALESCE(gate_urgent,0) FROM tasks WHERE ident='DIVE-9118';")" == "1" ]] \
  && ok_t "--urgent filed through the real cmd_task_need PERSISTS gate_urgent=1 on a human-bound gate" \
  || fail_t "the human-path write is missing: --urgent did not reach the column, so the window will hold an urgent gate"
w=$(_task_gate_undo_window_secs DIVE-9118)
[[ "$w" == "0" ]] \
  && ok_t "end to end: a gate FILED --urgent skips the window (write + read together, no SQL fixture)" \
  || fail_t "filed --urgent still holds for ${w}s end to end"

# NEGATIVE CONTROL for 9c: the same filing WITHOUT --urgent must leave the column
# at 0 and the window standing. Without it, a write that hardcoded 1 reads green.
reset
db "INSERT INTO tasks (ident,title,status,priority,assignee,created_by)
    VALUES ('DIVE-9119','undo window e2e control','todo','high','dev','dev');"
cmd_task_need DIVE-9119 --type=manual \
  --ask="Approve the payment for the new box?" --from=dev >/dev/null 2>&1
[[ "$(db "SELECT COALESCE(gate_urgent,0) FROM tasks WHERE ident='DIVE-9119';")" == "0" ]] \
  && ok_t "9c NEGATIVE: filing without --urgent leaves gate_urgent=0 — the write carries the flag, not a constant" \
  || fail_t "gate_urgent was set without --urgent: the write is unconditional"
w=$(_task_gate_undo_window_secs DIVE-9119)
[[ "$w" != "0" && -n "$w" ]] \
  && ok_t "9c NEGATIVE: the non-urgent e2e gate still holds (${w}s)" \
  || fail_t "the non-urgent e2e gate yielded '${w}', expected a hold"

# ── 10. THE OVERRIDE IS CLAMPED DOWNWARD: it may shorten the hold, never extend ─
# The commit that shipped arm D called the duration "a sealed constant with no
# write path", for the _GATE_HUMAN_CAPABILITIES reason: agents hold NOPASSWD:ALL,
# so a duration they can raise is a mute button on any gate they do not want
# answered. An unclamped env override IS that write path, and it is the UPWARD
# direction that is dangerous — downward only makes the phone ring sooner.
reset; mkgate DIVE-9112 high
w=$(_5DIVE_GATE_UNDO_WINDOW_SECS=604800 _task_gate_undo_window_secs DIVE-9112)
[[ "$w" == "$_GATE_UNDO_WINDOW_SECS" ]] \
  && ok_t "a week-long override is clamped to the sealed constant ($w s) — no mute" \
  || fail_t "override of 604800 yielded '$w': the constant is writable upward, a gate can be muted"
w=$(_5DIVE_GATE_UNDO_WINDOW_SECS=121 _task_gate_undo_window_secs DIVE-9112)
[[ "$w" == "$_GATE_UNDO_WINDOW_SECS" ]] \
  && ok_t "one second over the constant is clamped too — the bound is <=, not a magnitude check" \
  || fail_t "override of 121 yielded '$w', expected $_GATE_UNDO_WINDOW_SECS"

# NEGATIVE CONTROLS. Both of these pass against the UNCLAMPED code, so arm 10
# alone does not prove the clamp is narrow: without them a clamp written as a
# blanket "ignore the override" would read green here and silently break every
# sibling harness, which disables the window by exporting 0.
w=$(_5DIVE_GATE_UNDO_WINDOW_SECS=0 _task_gate_undo_window_secs DIVE-9112)
[[ "$w" == "0" ]] \
  && ok_t "0 still disables the hold — the clamp is one-directional, not an override ban" \
  || fail_t "override of 0 yielded '$w': the clamp swallowed the harness escape hatch"
w=$(_5DIVE_GATE_UNDO_WINDOW_SECS=30 _task_gate_undo_window_secs DIVE-9112)
[[ "$w" == "30" ]] \
  && ok_t "a SHORTER override is honoured verbatim (30s) — operators may only hurry the page" \
  || fail_t "override of 30 yielded '$w', expected 30"

# ── 11. THE LONGER WINDOW IS TARGETED, AND THE CLAMP FOLLOWS THE TYPE ──────
# manual/secret are human-only by definition, so for them the only question is
# how long before the phone rings. Measured cost on that population: zero gates
# lodar answered are delayed at any candidate size. Everything else keeps 120s.
for _t in manual secret; do
  reset; mkgate "DIVE-912${_t:0:1}" high
  db "UPDATE tasks SET need_type='$_t' WHERE ident='DIVE-912${_t:0:1}';"
  w=$(_5DIVE_GATE_UNDO_WINDOW_SECS= _task_gate_undo_window_secs "DIVE-912${_t:0:1}")
  [[ "$w" == "$_GATE_UNDO_WINDOW_SECS_HUMAN_ONLY" ]] \
    && ok_t "a $_t gate gets the long window (${w}s) — no routing arm can take it off the phone" \
    || fail_t "$_t gate window=${w}s, expected $_GATE_UNDO_WINDOW_SECS_HUMAN_ONLY"
done

# NEGATIVE CONTROL: the raise is TARGETED. A fleet-wide raise was the alternative
# and is strictly worse (104 removed but 12 real gates delayed), so a change that
# lengthened everything would be a different, worse product reading green above.
reset; mkgate DIVE-9128 high
w=$(_5DIVE_GATE_UNDO_WINDOW_SECS= _task_gate_undo_window_secs DIVE-9128)
[[ "$w" == "$_GATE_UNDO_WINDOW_SECS" ]] \
  && ok_t "a decision gate still gets the SHORT window (${w}s) — the raise is targeted, not global" \
  || fail_t "decision gate window=${w}s, expected $_GATE_UNDO_WINDOW_SECS"

# THE CLAMP FOLLOWS THE TYPE'S CEILING, in both directions. Without this the mute
# hole reopens sideways: if the clamp still read the BASE constant, an override of
# 900 on a decision gate would pass on a manual-shaped read, and a legitimate 900
# on a manual gate would be knocked back to 120 — silently making the raise a no-op.
reset; mkgate DIVE-9129 high
db "UPDATE tasks SET need_type='manual' WHERE ident='DIVE-9129';"
w=$(_5DIVE_GATE_UNDO_WINDOW_SECS=$((_GATE_UNDO_WINDOW_SECS_HUMAN_ONLY+1)) _task_gate_undo_window_secs DIVE-9129)
[[ "$w" == "$_GATE_UNDO_WINDOW_SECS_HUMAN_ONLY" ]] \
  && ok_t "one second over the manual ceiling is clamped to it (${w}s), not to the base" \
  || fail_t "manual override ceiling+1 yielded ${w}s, expected $_GATE_UNDO_WINDOW_SECS_HUMAN_ONLY"
reset; mkgate DIVE-9130 high
w=$(_5DIVE_GATE_UNDO_WINDOW_SECS=$_GATE_UNDO_WINDOW_SECS_HUMAN_ONLY _task_gate_undo_window_secs DIVE-9130)
[[ "$w" == "$_GATE_UNDO_WINDOW_SECS" ]] \
  && ok_t "the long duration is NOT reachable on a decision gate (clamped to ${w}s) — no sideways mute" \
  || fail_t "decision gate accepted the long override (${w}s): the raise reopened the mute hole"


# ── 11b. THE LONG CEILING MUST STAY UNDER THE HEARTBEAT'S RE-NAG ───────────
# quinn's non-blocking finding on iteration 1, taken as a change because the
# answer to "which contact do you intend" is load-bearing rather than cosmetic.
#
# The heartbeat re-nags a filed-but-unpinged gate at `gate_pinged_at IS NULL AND
# need_asked_at <= now-15 minutes` (_HB_GATE_RENAG_WHERE). At a 900s ceiling that
# predicate and the held ping become eligible in the SAME SECOND, so a
# manual/secret gate's first contact could be the re-nag — the recovery path for
# a ping lost to a dead box — instead of the normal buttoned ping. The intent is
# that the re-nag stays a net, never the first contact on a healthy box.
#
# GRADED STRUCTURALLY, against the heartbeat's own literal parsed out of the
# source, not against a number copied into this file. A copied 900 here would go
# on passing after someone raised either side, which is the whole failure mode.
_renag_min=$(sed -n "s/.*need_asked_at,updated_at,created_at) <= datetime('now','-\([0-9]\+\) minutes').*/\1/p" \
               "$SRC/cmd_heartbeat.sh" | head -1)
if [[ "$_renag_min" =~ ^[0-9]+$ ]]; then
  ok_t "the heartbeat's re-nag eligibility was READ from cmd_heartbeat.sh (${_renag_min} minutes), not assumed"
  if (( _GATE_UNDO_WINDOW_SECS_HUMAN_ONLY < _renag_min * 60 )); then
    ok_t "the long ceiling (${_GATE_UNDO_WINDOW_SECS_HUMAN_ONLY}s) stays strictly under the re-nag ($((_renag_min*60))s) — the buttoned ping is the FIRST contact, the re-nag is the net"
  else
    fail_t "the long ceiling (${_GATE_UNDO_WINDOW_SECS_HUMAN_ONLY}s) reaches the re-nag ($((_renag_min*60))s): a manual/secret gate's first contact can be the recovery path, not the normal ping"
  fi
else
  fail_t "could not read the re-nag threshold out of cmd_heartbeat.sh — this arm is vacuous, fix the parse rather than deleting it"
fi


# ── 12. THIS FILE MAY NOT BUY A MODULE LOAD WITH A COMMENT ────────────────────
# quinn's iteration-2 REJECT. Iteration 2 cited two other modules' globals BY
# NAME in comments — `_HB_GATE_RENAG_WHERE` (cmd_heartbeat) and
# `_GATE_HUMAN_CAPABILITIES` (task__need). Neither is read by any code here. But
# the lazy-dispatch dep scanner is a blunt token match over the WHOLE file,
# comments included, and it is blunt ON PURPOSE: it feeds __MODDEPS, where a
# MISSING provider is an `unbound variable` on a cold path, so it over-reports by
# design (scripts/lib/lazy-dispatch.sh: "matching every word costs us some
# phantom edges and misses none"). Two prose citations therefore became two real
# load edges out of task__notify — which task__dispatch preloads, i.e. every
# `task` verb pays them. Measured: a plain `task ls` went from 6 modules to 12
# (cmd_heartbeat and task__need, plus cmd_goal, cmd_objective, cmd_selfupdate and
# task__loops behind them) and tests/lazy_dispatch_unit.sh's `task ls` ratio arm
# went from ~70% of the eager control to 112%, red-gating a required check.
#
# WHY THE GUARD LIVES HERE AND NOT IN THE SCANNER. Teaching lazy_tokens to skip
# full-line comments would delete HALF its input (53,181 of 102,454 unique tokens
# across the payload) in the one direction that reaches users, and 291 payload
# comment lines carry a `$` expansion — some of them heredoc DATA, where a `#`
# line is not a comment at all. That is a DIVE-4087 change with its own grading
# burden, not a rider on arm D. What is arm D's to own is arm D's own file.
#
# NON-VACUITY IS THE WHOLE PROBLEM with this shape: a checker that finds nothing
# reads exactly like a clean file. So the arm carries a POSITIVE CONTROL — the
# same predicate is run against a copy of this module with iteration 2's citation
# put back, and must flag it.
_comment_only_edges() {   # $1=module file  → "<token> <provider-module>" lines
  local target="$1" f mod
  : >"$TMP/prov"
  for f in "$SRC"/cmd_*.sh "$SRC"/task/*.sh; do
    [[ "$(readlink -f "$f")" == "$(readlink -f "$target")" ]] && continue
    mod=$(basename "$f" .sh); [[ "$f" == "$SRC"/task/* ]] && mod="task__$mod"
    lazy_assigns "$f" | sed "s|\$| $mod|" >>"$TMP/prov"
  done
  # A name assigned by two modules is dropped by the real build (it will not
  # guess a provider), so it cannot be an edge here either.
  awk '{print $1}' "$TMP/prov" | sort | uniq -u >"$TMP/prov1"
  awk 'NR==FNR{u[$1]=1;next} ($1 in u)' "$TMP/prov1" "$TMP/prov" | sort -u >"$TMP/provuniq"
  grep -ohE '[A-Za-z_][A-Za-z0-9_]*' "$target" | sort -u >"$TMP/tok_all"
  grep -vE '^[[:space:]]*#' "$target" | grep -ohE '[A-Za-z_][A-Za-z0-9_]*' | sort -u >"$TMP/tok_code"
  comm -23 "$TMP/tok_all" "$TMP/tok_code" >"$TMP/tok_cmt"
  awk 'NR==FNR{c[$1]=1;next} ($1 in c){print $1, $2}' "$TMP/tok_cmt" "$TMP/provuniq" | sort -u
}

if source "$SRC/../scripts/lib/lazy-dispatch.sh" 2>/dev/null && declare -F lazy_assigns >/dev/null; then
  ok_t "the real dep scanner (scripts/lib/lazy-dispatch.sh) was sourced — this arm grades the build's own predicate, not a copy of it"

  _cmt_edges=$(_comment_only_edges "$SRC/task/notify.sh")
  if [[ -z "$_cmt_edges" ]]; then
    ok_t "no module load edge out of src/task/notify.sh is bought by a comment alone"
  else
    fail_t "src/task/notify.sh cites another module's global in a COMMENT, which is a real __MODDEPS edge and makes every \`task\` verb load that module:
$(printf '%s\n' "$_cmt_edges" | sed 's/^/      /')
      Cite the FILE and the clause, never the identifier."
  fi

  # POSITIVE CONTROL: put iteration 2's citation back and require a flag.
  _probe="$TMP/notify_probe.sh"
  cp "$SRC/task/notify.sh" "$_probe"
  printf '# regression probe: _GATE_HUMAN_CAPABILITIES seal (DIVE-2241/2131)\n' >>"$_probe"
  _probe_edges=$(_comment_only_edges "$_probe")
  if printf '%s\n' "$_probe_edges" | grep -q '^_GATE_HUMAN_CAPABILITIES '; then
    ok_t "positive control: the same predicate DOES flag iteration 2's comment citation, so the clean answer above is a reading and not a silence"
  else
    fail_t "positive control failed — the predicate did not flag a comment naming _GATE_HUMAN_CAPABILITIES, so the arm above is vacuous. Got: ${_probe_edges:-<nothing>}"
  fi
else
  fail_t "could not source scripts/lib/lazy-dispatch.sh — arm 12 is vacuous; fix the path rather than deleting it"
fi


printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
