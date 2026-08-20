#!/usr/bin/env bash
# TIER: nightly — 20.3s measured on the 5dive host, worktree 5dive-cli-wt-2207 (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it. Was 12.4s; DIVE-2207 added 14 arms (the (a3) post-gate-answer rail and the gap#3 label/parked-term arms), each of which drives a full _hb_stall_sweep.
# DIVE-1416 isolated unit harness for _hb_stall_sweep (cmd_heartbeat.sh) —
# fleet-stall self-heal gaps #2 and #3 (gap #1 is _hb_blocked_sweep, covered by
# tests/task_cascade_unblock_unit.sh):
#   (a) gap#2 — surface a maker->verifier delivery that's sat unacknowledged
#       past _HB_VERIFY_STALE_MIN (handoff_delivered_at, stamped by
#       _task_route_to_verifier), throttled once per delivery.
#   (b) gap#3 core — fleet-idle-while-actionable-work-is-open, alarms only once
#       the condition has PERSISTED past _HB_STALL_MIN_MINUTES, re-alarms on
#       the same cadence while it holds, clears when it resolves.
#   (c) gap#3 canary — pinger liveness: eligible-for-ping gates existing while
#       gate_pinged_at hasn't advanced fleet-wide in over an hour.
# Same isolation contract as the other harnesses: source src/ directly,
# throwaway tasks.db (STATE_DIR -> tmp), cmd_send stubbed so no tmux/network is
# touched. Run: bash tests/heartbeat_stall_sweep_unit.sh (no root, no network).
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

TMP="$(mktemp -d /tmp/hb-stall-sweep.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

# --- stubs: record pings, never touch tmux/network ---------------------------
SEND_LOG="$TMP/sent"; : >"$SEND_LOG"
cmd_send() {  # $1 = target agent; --message=… carries the body
  local tgt="$1" msg=""; shift
  for a in "$@"; do case "$a" in --message=*) msg="${a#--message=}";; esac; done
  printf '%s\t%s\n' "$tgt" "$msg" >>"$SEND_LOG"
}
audit_log() { return 0; }

# DIVE-2122 — the stall alarm now probes agent SESSIONS directly, so these must be
# stubbed for the whole run or the sweep reaches the REAL registry and REAL tmux
# panes: measured, the unstubbed probe found a live host agent mid-turn and
# correctly suppressed the alarm, turning two pre-existing arms red. A harness that
# reaches the host is not isolated, and the arm it breaks is the one you trust least.
# Default: an EMPTY fleet (probe unavailable) — the pre-DIVE-2122 behaviour of
# alarming, so every arm above this point grades exactly what it graded before.
PROBE_LOG="$TMP/probe"; : >"$PROBE_LOG"
FLEET='{"agents":{}}'
IDLE_MAP=""
registry_read() { printf '%s' "$FLEET"; }
# rc contract mirrors the real _hb_agent_idle: 0 idle, 1 busy/mid-turn, 2 unknown,
# 3 blocked. Every probed name is logged so the EARLY EXIT is gradeable.
_hb_agent_idle() {
  local n="$1" e
  printf '%s\n' "$n" >>"$PROBE_LOG"
  for e in $IDLE_MAP; do [[ "${e%%:*}" == "$n" ]] && return "${e##*:}"; done
  return 0
}
mkfleet() { local n out='{"agents":{' first=1
  for n in "$@"; do [[ $first == 1 ]] || out+=','; out+="\"$n\":{\"heartbeat\":{\"enabled\":true}}"; first=0; done
  printf '%s}}' "$out"; }


tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

addt()  { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
reset_all() {
  db "DELETE FROM tasks; DELETE FROM loop_runs; DELETE FROM task_prefs;"
  : >"$SEND_LOG"
}

# =============================================================================
# (a) gap#2 — stale maker->verifier delivery surfacing
# =============================================================================

# --- A1: fresh handoff via the real routing path stamps handoff_delivered_at,
#     clears any stale-ping flag, and is untouched by the sweep (too fresh)
reset_all
a=$(addt --assignee=dev --verifier=olivia -- "ship the widget")
( cmd_task_done "$a" --result="closed in fixture setup (DIVE-2773: a first close must carry a reason)" ) >/dev/null 2>&1
delivered=$(db "SELECT COALESCE(handoff_delivered_at,'NULL') FROM tasks WHERE id=${a};")
[[ "$delivered" != "NULL" ]] \
  && ok_t "task done to a verifier stamps handoff_delivered_at" \
  || bad_t "handoff_delivered_at not stamped" "got $delivered"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ ! -s "$SEND_LOG" || "$(cut -f2 "$SEND_LOG" | grep -c 'delivered to you')" == "0" ]] \
  && ok_t "fresh delivery is not surfaced yet (under _HB_VERIFY_STALE_MIN)" \
  || bad_t "fresh delivery surfaced early" "sent=[$(tr '\n' ',' <"$SEND_LOG")]"

# --- A2: backdate the delivery past the staleness window -> verifier + main pinged, flag stamped
db "UPDATE tasks SET handoff_delivered_at=datetime('now','-${_HB_VERIFY_STALE_MIN} minutes','-5 minutes') WHERE id=${a};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
grep -q $'^olivia\t.*delivered to you' "$SEND_LOG" \
  && ok_t "stale delivery pings the verifier" || bad_t "verifier not pinged" "$(cat "$SEND_LOG")"
grep -q $'^ops\t.*Delivered-awaiting-verifier' "$SEND_LOG" \
  && ok_t "stale delivery also pings ops (never invisible)" || bad_t "ops not pinged" "$(cat "$SEND_LOG")"
[[ "$(db "SELECT COALESCE(handoff_stale_pinged_at,'NULL') FROM tasks WHERE id=${a};")" != "NULL" ]] \
  && ok_t "stale-ping flag stamped" || bad_t "flag not stamped" ""

# --- A3: throttle — a second sweep does not re-ping the same delivery
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ ! -s "$SEND_LOG" ]] \
  && ok_t "already-flagged delivery is not re-pinged" \
  || bad_t "delivery re-pinged" "$(cat "$SEND_LOG")"

# --- A4: acknowledged deliveries (handoff_ack_at set) are never surfaced
reset_all
b=$(addt --assignee=dev --verifier=olivia -- "ship the gadget")
( cmd_task_done "$b" --result="closed in fixture setup (DIVE-2773: a first close must carry a reason)" ) >/dev/null 2>&1
db "UPDATE tasks SET handoff_delivered_at=datetime('now','-999 minutes'),
       handoff_ack_at=datetime('now') WHERE id=${b};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ ! -s "$SEND_LOG" ]] \
  && ok_t "acknowledged handoff is never surfaced" \
  || bad_t "acked handoff surfaced" "$(cat "$SEND_LOG")"

# =============================================================================
# (a3) DIVE-2207 — the POST-GATE-ANSWER predicate
#
# THE FIXTURE IS THE POINT. Every arm below starts from a row that defeats every
# OTHER exclusion in this sweep at once: delivered, ack STAMPED, gate ANSWERED, and
# handoff_stale_pinged_at ALREADY BURNED. That is not a contrived shape — it is the
# shape of the rows actually on the board (30 fleet-wide had burned the throttle
# when this was written, including the live specimen DIVE-2146). If any arm here
# goes green with the new predicate deleted, the row was caught for another reason
# and the arm proves nothing.
# =============================================================================

# --- A5: the load-bearing arm. Nothing else in this sweep can see this row.
reset_all
ag=$(addt --assignee=dev --verifier=olivia -- "graded after a gate")
( cmd_task_done "$ag" ) >/dev/null 2>&1
db "UPDATE tasks SET handoff_delivered_at=datetime('now','-999 minutes'),
       handoff_ack_at=datetime('now','-500 minutes'),
       handoff_stale_pinged_at=datetime('now','-400 minutes'),
       need_type='decision', need_asked_at=datetime('now','-300 minutes'),
       need_answered_at=datetime('now','-${_HB_VERIFY_STALE_MIN} minutes','-5 minutes')
     WHERE id=${ag};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
grep -q $'^olivia\t.*gate that was blocking it was ANSWERED' "$SEND_LOG" \
  && ok_t "A5 answered-gate delivery nudges the verifier (ack stamped, old throttle burned)" \
  || bad_t "A5 answered-gate delivery not surfaced" "$(cat "$SEND_LOG")"
grep -q $'^ops\t.*Answered-gate delivery' "$SEND_LOG" \
  && ok_t "A5 it also reaches ops (never invisible)" || bad_t "A5 ops not pinged" "$(cat "$SEND_LOG")"

# --- A6: the MESSAGE must not be gap#2's. "still unacknowledged" is false here —
#     the verifier did act, and DIVE-2196 is the row that proves a false nudge costs
#     more than a missing one.
grep -q 'still unacknowledged' "$SEND_LOG" \
  && bad_t "A6 post-answer nudge reused gap#2's false 'still unacknowledged' text" "$(cat "$SEND_LOG")" \
  || ok_t "A6 the post-answer nudge does NOT claim the verifier never acknowledged"

# --- A7: throttle is the NEW column, and it is stamped
[[ "$(db "SELECT COALESCE(gate_answered_nudged_at,'NULL') FROM tasks WHERE id=${ag};")" != "NULL" ]] \
  && ok_t "A7 gate_answered_nudged_at stamped" || bad_t "A7 new throttle not stamped" ""
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
grep -q 'ANSWERED' "$SEND_LOG" \
  && bad_t "A7 answered-gate row re-nudged despite its throttle" "$(cat "$SEND_LOG")" \
  || ok_t "A7 throttled — a second sweep does not re-nudge"

# --- A8: THE SAFETY ARM. While the gate is still OPEN this rail must be silent.
#     Nudging here prescribes closing a row whose human question is undecided —
#     literally the DIVE-2196 defect this whole thread exists to avoid.
reset_all
ah=$(addt --assignee=dev --verifier=olivia -- "still blocked on a human")
( cmd_task_done "$ah" ) >/dev/null 2>&1
db "UPDATE tasks SET handoff_delivered_at=datetime('now','-999 minutes'),
       handoff_ack_at=datetime('now','-500 minutes'),
       handoff_stale_pinged_at=datetime('now','-400 minutes'),
       need_type='decision', need_asked_at=datetime('now','-300 minutes'),
       need_answered_at=NULL WHERE id=${ah};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
grep -q 'ANSWERED' "$SEND_LOG" \
  && bad_t "A8 nudged a row whose gate is STILL OPEN (DIVE-2196 defect)" "$(cat "$SEND_LOG")" \
  || ok_t "A8 an OPEN gate is never nudged — the rail is post-answer only"

# --- A9: answered, but not yet past the window -> not yet
db "UPDATE tasks SET need_answered_at=datetime('now') WHERE id=${ah};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
grep -q 'ANSWERED' "$SEND_LOG" \
  && bad_t "A9 nudged a gate answered seconds ago" "$(cat "$SEND_LOG")" \
  || ok_t "A9 a freshly-answered gate waits out _HB_VERIFY_STALE_MIN first"

# --- A10: parked rows are left alone. One clause beyond the DIVE-2207 spec,
#     mirroring the (a2) rail; 22 parked rows were live fleet-wide when it was added.
db "UPDATE tasks SET need_answered_at=datetime('now','-${_HB_VERIFY_STALE_MIN} minutes','-5 minutes'),
       parked_at=datetime('now') WHERE id=${ah};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
grep -q 'ANSWERED' "$SEND_LOG" \
  && bad_t "A10 nudged a PARKED row" "$(cat "$SEND_LOG")" \
  || ok_t "A10 a parked row is not nudged"
db "UPDATE tasks SET parked_at=NULL WHERE id=${ah};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
grep -q 'ANSWERED' "$SEND_LOG" \
  && ok_t "A10 CONTROL un-parking the same row makes it fire (A10 was not vacuous)" \
  || bad_t "A10 control failed — the row never fires, so A10 proved nothing" "$(cat "$SEND_LOG")"

# =============================================================================
# (b) gap#3 core — fleet-idle-while-actionable-work-is-open, persisting
# =============================================================================

# --- B1: fleet busy (an in_progress task exists) -> no alarm regardless of backlog
reset_all
busy=$(addt --assignee=dev -- "grinding"); ( cmd_task_start "$busy" ) >/dev/null 2>&1
strand=$(addt --assignee=bob -- "stranded todo")
_hb_stall_sweep >/dev/null 2>&1
[[ -z "$(db "SELECT value FROM task_prefs WHERE key='stall_first_seen_at';")" ]] \
  && ok_t "fleet busy (in_progress>0) never starts the stall clock" \
  || bad_t "stall clock started while busy" ""

# --- B2: fleet idle + stranded todo -> starts the persistence clock, no alarm yet
reset_all
strand=$(addt --assignee=bob -- "stranded todo")
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ -n "$(db "SELECT value FROM task_prefs WHERE key='stall_first_seen_at';")" ]] \
  && ok_t "fleet-idle-with-stranded-work starts the persistence clock" \
  || bad_t "clock not started" ""
[[ ! -s "$SEND_LOG" ]] \
  && ok_t "no alarm yet — condition hasn't persisted _HB_STALL_MIN_MINUTES" \
  || bad_t "alarmed too early" "$(cat "$SEND_LOG")"

# --- B3: backdate the persistence clock past the threshold -> alarms ops
db "UPDATE task_prefs SET value=datetime('now','-${_HB_STALL_MIN_MINUTES} minutes','-1 minutes')
    WHERE key='stall_first_seen_at';"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
grep -q $'^ops\t.*fleet-stall' "$SEND_LOG" \
  && ok_t "persisted stall (past _HB_STALL_MIN_MINUTES) alarms ops" \
  || bad_t "no stall alarm" "$(cat "$SEND_LOG")"
[[ -n "$(db "SELECT value FROM task_prefs WHERE key='stall_alerted_at';")" ]] \
  && ok_t "stall alert throttle key stamped" || bad_t "throttle key missing" ""

# --- B4: throttle — re-running immediately does not re-alarm
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ ! -s "$SEND_LOG" ]] \
  && ok_t "stall alarm throttled (no re-alarm within the window)" \
  || bad_t "re-alarmed" "$(cat "$SEND_LOG")"

# --- B5: condition resolves (agent starts the stranded task) -> clock clears
( cmd_task_start "$strand" ) >/dev/null 2>&1
_hb_stall_sweep >/dev/null 2>&1
[[ -z "$(db "SELECT value FROM task_prefs WHERE key='stall_first_seen_at';")" ]] \
  && ok_t "stall clears once fleet is busy again" || bad_t "clock not cleared" ""

# --- B6: open FLEET-ACTIONABLE gate (decision defaults tier=1) also counts as
#     stranded work, same as an unclaimed todo
reset_all
gate_task=$(addt --assignee=bob -- "needs a call")
( cmd_task_need "$gate_task" --type=decision --options="X|Y" --ask="pick" ) >/dev/null 2>&1
_hb_stall_sweep >/dev/null 2>&1
[[ -n "$(db "SELECT value FROM task_prefs WHERE key='stall_first_seen_at';")" ]] \
  && ok_t "an open tier<=1 (fleet-actionable) gate alone starts the stall clock" \
  || bad_t "gate not counted as stranded" ""

# --- B7 GUARDRAIL: a PINGED tier-2 gate genuinely awaiting the human (e.g.
#     overnight) is PARKED, not stranded — must NOT start the stall clock, or
#     an idle night re-alarms ops every _HB_STALL_MIN_MINUTES for no reason
#     (the alert-fatigue class this design already killed once).
reset_all
g=$(addt --assignee=dev -- "human's court")
db "UPDATE tasks SET status='blocked', need_type='approval', tier=2,
       need_asked_at=datetime('now','-2 days'), gate_pinged_at=datetime('now','-1 days')
     WHERE id=${g};"
_hb_stall_sweep >/dev/null 2>&1
[[ -z "$(db "SELECT value FROM task_prefs WHERE key='stall_first_seen_at';")" ]] \
  && ok_t "idle fleet + a PINGED tier-2 gate only -> no stall clock (parked, not stranded)" \
  || bad_t "pinged tier-2 gate wrongly counted as stranded" ""

# --- B8: an UNpinged-but-already-asked tier-2 gate is also not stranded — the
#     initial notify already reached the human at file time (a separate
#     transport from the reminder batch); need_asked_at being set is what
#     distinguishes it from a truly-never-surfaced row.
reset_all
g=$(addt --assignee=dev -- "human's court, not yet reminder-due")
db "UPDATE tasks SET status='blocked', need_type='approval', tier=2,
       need_asked_at=datetime('now','-2 days'), gate_pinged_at=NULL
     WHERE id=${g};"
_hb_stall_sweep >/dev/null 2>&1
[[ -z "$(db "SELECT value FROM task_prefs WHERE key='stall_first_seen_at';")" ]] \
  && ok_t "idle fleet + an asked-but-unpinged tier-2 gate -> still no stall clock" \
  || bad_t "asked tier-2 gate wrongly counted as stranded" ""

# --- B9: a tier-2 gate that was NEVER surfaced at all (need_asked_at AND
#     gate_pinged_at both NULL — a legacy/malformed row) DOES count: nobody
#     was ever told, so it's genuinely stranded, not parked.
reset_all
g=$(addt --assignee=dev -- "legacy gate, never surfaced")
db "UPDATE tasks SET status='blocked', need_type='approval', tier=2,
       need_asked_at=NULL, gate_pinged_at=NULL
     WHERE id=${g};"
_hb_stall_sweep >/dev/null 2>&1
[[ -n "$(db "SELECT value FROM task_prefs WHERE key='stall_first_seen_at';")" ]] \
  && ok_t "a never-surfaced tier-2 gate (no need_asked_at, no gate_pinged_at) counts as stranded" \
  || bad_t "never-surfaced gate not counted" ""

# --- B10/B11 DIVE-2207: the RENDERED LABELS, and the parked term that must not
#     reach the arithmetic. Fixture: 2 assigned-but-unstarted todos (so the alarm
#     fires at all) + 3 PINGED tier-2 gates (parked). The correct alert says
#     "2 stranded ... (2 assigned-but-unstarted, 0 fleet-actionable gate(s)) ...
#     3 parked on the human". The number that must NOT move is the 2.
reset_all
p1=$(addt --assignee=dev -- "unstarted one"); p2=$(addt --assignee=bob -- "unstarted two")
for _i in 1 2 3; do
  pg=$(addt --assignee=dev -- "parked gate $_i")
  db "UPDATE tasks SET status='blocked', need_type='approval', tier=2,
         need_asked_at=datetime('now','-2 days'), gate_pinged_at=datetime('now','-1 days')
       WHERE id=${pg};"
done
_hb_stall_sweep >/dev/null 2>&1
db "UPDATE task_prefs SET value=datetime('now','-${_HB_STALL_MIN_MINUTES} minutes','-1 minutes')
    WHERE key='stall_first_seen_at';"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
_alert=$(grep $'^ops\t' "$SEND_LOG" | grep 'fleet-stall' | head -1)

[[ -n "$_alert" ]] \
  && ok_t "B10 the stall alert fired (fixture is live, the label arms below are not vacuous)" \
  || bad_t "B10 no alert — every label arm below would pass vacuously" "$(cat "$SEND_LOG")"

[[ "$_alert" == *"assigned-but-unstarted"* && "$_alert" != *"unclaimed todo"* ]] \
  && ok_t "B10 stranded_todo renders as 'assigned-but-unstarted', not the disjoint 'unclaimed todo'" \
  || bad_t "B10 wrong stranded_todo label" "$_alert"

[[ "$_alert" == *"fleet-actionable gate(s)"* && "$_alert" != *"open gate(s)"* ]] \
  && ok_t "B10 open_gates renders as 'fleet-actionable gate(s)', not the superset 'open gate(s)'" \
  || bad_t "B10 wrong open_gates label" "$_alert"

[[ "$_alert" == *"3 parked on the human"* ]] \
  && ok_t "B11 the parked count is rendered as its own term" \
  || bad_t "B11 parked term missing or miscounted" "$_alert"

# THE LOAD-BEARING ONE. 3 parked gates are present; total_stranded must still be 2.
# If parked_gates ever reaches the sum, this reads 5 and the alert re-alarms every
# _HB_STALL_MIN_MINUTES on a night whose only "work" is waiting on a human — the
# alert-fatigue regression DIVE-2207 exists to avoid while still surfacing the count.
[[ "$_alert" == *"2 stranded actionable item(s)"* ]] \
  && ok_t "B11 parked gates do NOT feed total_stranded (2, not 5)" \
  || bad_t "B11 parked gates leaked into total_stranded" "$_alert"

# =============================================================================
# (c) gap#3 canary — pinger liveness
# =============================================================================

# --- C1: no eligible gates -> no alarm, no tripped record
reset_all
_hb_stall_sweep >/dev/null 2>&1
[[ -z "$(db "SELECT value FROM task_prefs WHERE key='pinger_canary_alerted_at';")" ]] \
  && ok_t "no eligible gates -> canary never trips" || bad_t "canary tripped with nothing eligible" ""

# --- C2: an eligible (stale, unpinged) T2 gate exists + gate_pinged_at has never
#     advanced fleet-wide -> canary trips, alarms ops
reset_all
g=$(addt --assignee=dev -- "stale gate")
db "UPDATE tasks SET status='blocked', need_type='approval', tier=2,
       need_asked_at=datetime('now','-10 days'), gate_pinged_at=NULL
     WHERE id=${g};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
grep -q $'^ops\t.*pinger-liveness canary tripped' "$SEND_LOG" \
  && ok_t "eligible gate + no fleet-wide gate_pinged_at advance -> canary trips" \
  || bad_t "canary did not trip" "$(cat "$SEND_LOG")"
[[ -n "$(db "SELECT value FROM task_prefs WHERE key='pinger_canary_alerted_at';")" ]] \
  && ok_t "canary trip is stamped" || bad_t "trip not stamped" ""

# --- C3: throttle — re-running immediately does not re-alarm
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ ! -s "$SEND_LOG" ]] \
  && ok_t "canary alarm throttled (no re-alarm within the window)" \
  || bad_t "canary re-alarmed" "$(cat "$SEND_LOG")"

# --- C4: gate_pinged_at HAS advanced recently fleet-wide -> pinger looks alive, no trip
reset_all
g=$(addt --assignee=dev -- "stale gate but pinger alive")
db "UPDATE tasks SET status='blocked', need_type='approval', tier=2,
       need_asked_at=datetime('now','-10 days'), gate_pinged_at=NULL
     WHERE id=${g};"
other=$(addt --assignee=dev -- "some other already-pinged gate")
db "UPDATE tasks SET status='blocked', need_type='approval', tier=2,
       need_asked_at=datetime('now','-10 days'), gate_pinged_at=datetime('now','-5 minutes')
     WHERE id=${other};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ ! -s "$SEND_LOG" ]] \
  && ok_t "recent fleet-wide gate_pinged_at -> pinger looks alive, canary does not trip" \
  || bad_t "canary false-tripped while pinger is alive" "$(cat "$SEND_LOG")"


# =============================================================================
# (d) DIVE-2122 — the alarm must MEASURE idleness, not infer it from a proxy
#
# in_progress==0 means "nobody used the task verb recently", not "nothing is
# happening". Measured 2026-07-26: the alarm fired while the fleet ran 257 commands
# in ten minutes and dev's last `task start` was 7.5 HOURS earlier. Fifth instance of
# the same false positive. These arms pin the direct session probe that now gates it.
# =============================================================================
# the otherwise-firing condition: one stranded todo, persisted well past the window
arm() { reset_all; local t; t=$(addt --assignee=dev -- "a stranded todo")
  db "INSERT INTO task_prefs (key,value) VALUES ('stall_first_seen_at', datetime('now','-60 minutes'));"
  : >"$SEND_LOG"; : >"$PROBE_LOG"; }
stallmsg() { grep -c 'fleet-stall' "$SEND_LOG"; }

# --- D1: THE FALSE POSITIVE. One agent actively working -> no alarm.
FLEET=$(mkfleet dev olivia); IDLE_MAP="dev:1"; arm
_hb_stall_sweep >/dev/null 2>&1
[[ "$(stallmsg)" == "0" ]] \
  && ok_t "D1 an ACTIVE agent session suppresses the alarm (in_progress is a proxy, the session is the artifact)" \
  || bad_t "D1 active fleet must not alarm" "$(cat "$SEND_LOG")"
[[ -z "$(db "SELECT value FROM task_prefs WHERE key='stall_first_seen_at';")" ]] \
  && ok_t "D1 the idle clock is RESET on observed activity (an 'idle 60m+' claim we just disproved is not carried forward)" \
  || bad_t "D1 clock must reset" "still $(db "SELECT value FROM task_prefs WHERE key='stall_first_seen_at';")"
[[ "$(wc -l <"$PROBE_LOG")" == "1" ]] \
  && ok_t "D1 the probe EARLY-EXITS on the first active agent (the common path costs one pane sample, not eleven)" \
  || bad_t "D1 early exit" "probed: $(tr '\n' ',' <"$PROBE_LOG")"

# --- D2: a genuinely idle fleet still alarms, and says what it measured.
FLEET=$(mkfleet dev olivia); IDLE_MAP=""; arm
_hb_stall_sweep >/dev/null 2>&1
[[ "$(stallmsg)" == "1" ]] \
  && ok_t "D2 a genuinely idle fleet STILL alarms (the fix must not silence the detector)" \
  || bad_t "D2 idle fleet must alarm" "$(cat "$SEND_LOG")"
grep -q 'probed 2 agent session(s): 2 idle' "$SEND_LOG" \
  && ok_t "D2 the alarm NAMES what it checked (an alert that will not name its measurement reads like one that measured nothing)" \
  || bad_t "D2 alarm must name its measurement" "$(cat "$SEND_LOG")"

# --- D3: BLOCKED is not idle. It is the actual root in two recorded recurrences.
FLEET=$(mkfleet dev olivia); IDLE_MAP="olivia:3"; arm
_hb_stall_sweep >/dev/null 2>&1
grep -q '1 BLOCKED (olivia)' "$SEND_LOG" \
  && ok_t "D3 a BLOCKED agent is counted and NAMED, not bucketed with idle (frozen dialog does not self-clear)" \
  || bad_t "D3 blocked must be named" "$(cat "$SEND_LOG")"

# --- D4: UNMEASURABLE is a THIRD state. An uncapturable pane did not prove idleness.
FLEET=$(mkfleet dev olivia); IDLE_MAP="olivia:2"; arm
_hb_stall_sweep >/dev/null 2>&1
grep -q 'UNMEASURABLE' "$SEND_LOG" && grep -q 'did not prove those idle' "$SEND_LOG" \
  && ok_t "D4 an uncapturable pane reads UNMEASURABLE, never idle" \
  || bad_t "D4 unmeasurable must not fold into idle" "$(cat "$SEND_LOG")"
grep -q ': 1 idle' "$SEND_LOG" \
  && ok_t "D4 ...and the idle COUNT excludes it (1 of 2, not 2 of 2)" \
  || bad_t "D4 idle count must exclude the unmeasurable one" "$(cat "$SEND_LOG")"

# --- D5: probe unavailable must still alarm, and must say the idleness is UNVERIFIED.
# Fail-loud, not fail-silent: an unmeasurable probe cannot bless OR suppress.
FLEET='{"agents":{}}'; IDLE_MAP=""; arm
_hb_stall_sweep >/dev/null 2>&1
[[ "$(stallmsg)" == "1" ]] && grep -q 'UNVERIFIED' "$SEND_LOG" \
  && ok_t "D5 an unavailable probe still alarms and marks the idleness UNVERIFIED (never a silent pass)" \
  || bad_t "D5 unavailable probe" "$(cat "$SEND_LOG")"

# --- D6: a DELIVERED maker->verifier row is not 'stranded'. It is awaiting a grade,
# it is on gap#2's clock already, and three of them padded the 2026-07-26 count.
FLEET=$(mkfleet dev); IDLE_MAP=""
reset_all
d=$(addt --assignee=dev --verifier=olivia -- "delivered, awaiting the grade")
( cmd_task_done "$d" --result="closed in fixture setup (DIVE-2773: a first close must carry a reason)" ) >/dev/null 2>&1
db "INSERT INTO task_prefs (key,value) VALUES ('stall_first_seen_at', datetime('now','-60 minutes'));"
: >"$SEND_LOG"; : >"$PROBE_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(stallmsg)" == "0" ]] \
  && ok_t "D6 a delivered-awaiting-verifier row is NOT stranded actionable work (status=todo assigned to the VERIFIER)" \
  || bad_t "D6 delivered row must not count as stranded" "$(cat "$SEND_LOG")"
[[ "$(db "SELECT status||'/'||assignee FROM tasks WHERE id=${d};")" == "todo/olivia" ]] \
  && ok_t "D6 ...and that row really is the todo/verifier shape the alarm used to miscount" \
  || bad_t "D6 fixture shape" "got $(db "SELECT status||'/'||assignee FROM tasks WHERE id=${d};")"


# =============================================================================
# (e) DIVE-3483 — A ROW STRANDED ON A **BUSY** SEAT.
#
# The arm exists because both pre-existing rails take IDLENESS as a precondition
# (the supervisor needs the SEAT idle, (b) needs the whole FLEET idle), so the one
# shape neither can see is a live seat holding a row it never chooses. Every arm
# below therefore keeps a seat ACTIVE — an in_progress row for the same assignee —
# because a fixture with an idle seat would pass against the old code too and
# grade nothing.
# =============================================================================
strandmsg() { grep -c $'^ops\t.*Stranded' "$SEND_LOG"; }

# --- E1: todo, past the window, on a seat that is demonstrably ACTIVE -> surfaced
reset_all
e=$(addt --assignee=dev -- "stranded row")
ebusy=$(addt --assignee=dev -- "what dev is actually doing")
db "UPDATE tasks SET status='in_progress' WHERE id=${ebusy};"
db "UPDATE tasks SET created_at=datetime('now','-${_HB_STRANDED_HOURS} hours','-1 hour') WHERE id=${e};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(strandmsg)" -ge 1 ]] \
  && ok_t "E1 a row stranded past the window on an ACTIVE seat is surfaced (the shape both old rails miss)" \
  || bad_t "E1 stranded row not surfaced" "$(cat "$SEND_LOG")"
[[ "$(db "SELECT COALESCE(stranded_pinged_at,'NULL') FROM tasks WHERE id=${e};")" != "NULL" ]] \
  && ok_t "E1 ...and the per-row stamp is set" || bad_t "E1 stamp not set" ""

# --- E2: it NAMES THE LANE — the active row and the seat's other load. Without
#     this the reader has to re-investigate, which is the cost the row was filed over.
grep -q $'^ops\t.*Stranded.*ACTIVE on' "$SEND_LOG" \
  && ok_t "E2 the alert names what the seat is actively doing" \
  || bad_t "E2 lane not named" "$(grep $'^ops\t.*Stranded' "$SEND_LOG" | head -1)"
grep -q $'^ops\t.*LANE problem' "$SEND_LOG" \
  && ok_t "E2 ...and says it is a lane problem, not a priority problem" \
  || bad_t "E2 remedy not named" ""

# --- E3: THROTTLE. This is the whole design — naive surfacing emits thousands of
#     pings, gets muted, and recreates the silent-monitoring defect of DIVE-3460.
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(strandmsg)" == "0" ]] \
  && ok_t "E3 THROTTLE: a second sweep does not re-ping the same row (once per row, not once per sweep)" \
  || bad_t "E3 re-pinged" "$(cat "$SEND_LOG")"

# --- E4: under the window -> silent. Proves the arm can produce a NEGATIVE at all,
#     so E1 is evidence of a working predicate rather than an unconditional send.
reset_all
f=$(addt --assignee=dev -- "young row")
fbusy=$(addt --assignee=dev -- "seat is busy")
db "UPDATE tasks SET status='in_progress' WHERE id=${fbusy};"
db "UPDATE tasks SET created_at=datetime('now','-1 hour') WHERE id=${f};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(strandmsg)" == "0" ]] \
  && ok_t "E4 a row inside the window is NOT surfaced (the instrument can return a negative)" \
  || bad_t "E4 young row surfaced" "$(cat "$SEND_LOG")"

# --- E5: a RECURRING instance is (a2)'s row, not this arm's. Two rails announcing
#     one row is how a monitor earns its mute.
reset_all
g=$(addt --assignee=dev -- "recurring instance")
gbusy=$(addt --assignee=dev -- "seat is busy")
db "UPDATE tasks SET status='in_progress' WHERE id=${gbusy};"
db "UPDATE tasks SET created_at=datetime('now','-${_HB_STRANDED_HOURS} hours','-1 hour'),
                     from_template_id=${gbusy} WHERE id=${g};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(strandmsg)" == "0" ]] \
  && ok_t "E5 a recurring instance is left to the (a2) rail, not double-announced here" \
  || bad_t "E5 recurring instance double-announced" "$(cat "$SEND_LOG")"

# --- E6: a delivery awaiting its verifier is gap#2's row, not this arm's.
reset_all
h=$(addt --assignee=dev --verifier=olivia -- "delivered, awaiting grade")
( cmd_task_done "$h" --result="closed in fixture setup" ) >/dev/null 2>&1
db "UPDATE tasks SET created_at=datetime('now','-${_HB_STRANDED_HOURS} hours','-1 hour'),
                     handoff_stale_pinged_at=datetime('now') WHERE id=${h};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(strandmsg)" == "0" ]] \
  && ok_t "E6 a maker->verifier delivery is left to gap#2, not double-announced here" \
  || bad_t "E6 delivery double-announced" "$(cat "$SEND_LOG")"

# --- E7: waiting on a HUMAN is not stranded — the remedy is not the seat's, and
#     nagging the seat about it is the DIVE-2196 harm.
reset_all
i=$(addt --assignee=dev -- "blocked on a human gate")
ibusy=$(addt --assignee=dev -- "seat is busy")
db "UPDATE tasks SET status='in_progress' WHERE id=${ibusy};"
db "UPDATE tasks SET created_at=datetime('now','-${_HB_STRANDED_HOURS} hours','-1 hour'),
                     need_type='approval', need_answered_at=NULL WHERE id=${i};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(strandmsg)" == "0" ]] \
  && ok_t "E7 a row with an unanswered human gate is NOT surfaced as stranded" \
  || bad_t "E7 gated row surfaced" "$(cat "$SEND_LOG")"

# --- E8: a PARKED row is a deliberate quiet wait, not a stall.
reset_all
j=$(addt --assignee=dev -- "parked on purpose")
jbusy=$(addt --assignee=dev -- "seat is busy")
db "UPDATE tasks SET status='in_progress' WHERE id=${jbusy};"
db "UPDATE tasks SET created_at=datetime('now','-${_HB_STRANDED_HOURS} hours','-1 hour'),
                     parked_at=datetime('now') WHERE id=${j};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(strandmsg)" == "0" ]] \
  && ok_t "E8 a parked row is a deliberate wait, not a stall" \
  || bad_t "E8 parked row surfaced" "$(cat "$SEND_LOG")"

# --- E9: THE REGRESSION THIS ARM WAS FILED FOR, end to end. A row DROPPED after
#     one start (first_started_at set, started_at NULL) on a seat that is alive and
#     working elsewhere. That is DIVE-3330's exact shape: it sat 3 days while every
#     rail read healthy. Measured from the DROP, not from creation.
reset_all
k=$(addt --assignee=codex -- "started once, dropped, never resumed")
kbusy=$(addt --assignee=codex -- "codex is alive and doing other work")
db "UPDATE tasks SET status='in_progress' WHERE id=${kbusy};"
db "UPDATE tasks SET created_at=datetime('now','-9 days'),
                     first_started_at=datetime('now','-${_HB_STRANDED_HOURS} hours','-1 hour'),
                     started_at=NULL WHERE id=${k};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(strandmsg)" -ge 1 ]] \
  && ok_t "E9 REGRESSION (DIVE-3330 shape): a dropped row on a live, busy seat is surfaced" \
  || bad_t "E9 dropped row not surfaced" "$(cat "$SEND_LOG")"

# --- E10: and the drop clock is the one that governs — a row dropped RECENTLY is
#     silent even though it was CREATED long ago. Without this, E9 would also pass
#     on a naive created_at-only predicate.
reset_all
l=$(addt --assignee=codex -- "old row, restarted recently")
lbusy=$(addt --assignee=codex -- "codex is busy")
db "UPDATE tasks SET status='in_progress' WHERE id=${lbusy};"
db "UPDATE tasks SET created_at=datetime('now','-9 days'),
                     first_started_at=datetime('now','-1 hour'), started_at=NULL WHERE id=${l};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(strandmsg)" == "0" ]] \
  && ok_t "E10 the DROP clock governs, not created_at (a 9-day-old row touched an hour ago is silent)" \
  || bad_t "E10 stale created_at drove the alert" "$(cat "$SEND_LOG")"

# =============================================================================
# E11-E14 (ops, 2026-08-19) — THE ALARM'S SENTENCE MUST NOT ASSERT MORE THAN ITS
# QUERY MEASURED. Precision audit over every firing in the board's history: 6
# post-backfill pings, 0 of them the shape the arm exists to detect. Three
# separate over-claims, each graded below with a POSITIVE CONTROL, because
# "the clause is gone" and "the clause is conditional" pass identically
# otherwise and only one of them is the fix.
# =============================================================================
strandtxt() { grep $'^ops\t.*Stranded' "$SEND_LOG" | head -1; }

# --- E11: SELF-COUNT. The stranded row is itself todo, so an unfiltered COUNT()
#     on the seat returns 1 and the sentence called it "1 OTHER todo row" — the
#     alarm offering the row as evidence of its own lane congestion. Measured on
#     DIVE-3375 (olivia): it was the ONLY support the verdict had.
reset_all
m=$(addt --assignee=dev -- "stranded, and the seat's only todo")
mbusy=$(addt --assignee=dev -- "seat is busy")
db "UPDATE tasks SET status='in_progress' WHERE id=${mbusy};"
db "UPDATE tasks SET created_at=datetime('now','-${_HB_STRANDED_HOURS} hours','-1 hour') WHERE id=${m};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(strandmsg)" -ge 1 ]] && ! grep -q 'other todo row' <<<"$(strandtxt)" \
  && ok_t "E11 a seat whose ONLY todo row is the stranded one claims no OTHER load" \
  || bad_t "E11 the row was counted as its own lane evidence" "$(strandtxt)"

# --- E11b: POSITIVE CONTROL for E11. Real other load must still be reported, or
#     E11 would pass just as well against a deleted clause.
reset_all
n=$(addt --assignee=dev -- "stranded row")
nbusy=$(addt --assignee=dev -- "seat is busy")
nother=$(addt --assignee=dev -- "genuine second todo on the same seat")
db "UPDATE tasks SET status='in_progress' WHERE id=${nbusy};"
db "UPDATE tasks SET created_at=datetime('now','-${_HB_STRANDED_HOURS} hours','-1 hour') WHERE id=${n};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
grep -q 'holds 1 other todo row' <<<"$(strandtxt)" \
  && ok_t "E11b POSITIVE CONTROL: genuine other load is still counted, and counted correctly" \
  || bad_t "E11b real lane load went unreported" "$(strandtxt)"

# --- E12: "WITHOUT BEING STARTED" IS FALSE FOR HALF THE POPULATION. E9 selects a
#     started-then-dropped row on purpose and dates it from the DROP, so the fixed
#     sentence contradicted the arm's own predicate. 4 of the 6 post-backfill
#     firings hit rows already started — one 5 days before its "never started"
#     ping. It fails expensively: "untouched" is what makes a reader reach for
#     cancel. (DIVE-2207, one field over.)
reset_all
o=$(addt --assignee=codex -- "started once, dropped, never resumed")
obusy=$(addt --assignee=codex -- "codex is busy elsewhere")
db "UPDATE tasks SET status='in_progress' WHERE id=${obusy};"
db "UPDATE tasks SET created_at=datetime('now','-9 days'),
                     first_started_at=datetime('now','-${_HB_STRANDED_HOURS} hours','-1 hour'),
                     started_at=NULL WHERE id=${o};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(strandmsg)" -ge 1 ]] && ! grep -q 'without ever being started' <<<"$(strandtxt)" \
  && grep -q 'was started' <<<"$(strandtxt)" \
  && ok_t "E12 a DROPPED row is described as started-and-not-moved, not as never-started" \
  || bad_t "E12 a started row was announced as never started" "$(strandtxt)"

# --- E12b: POSITIVE CONTROL for E12 — the genuinely untouched row must still say so.
reset_all
q=$(addt --assignee=codex -- "never touched at all")
qbusy=$(addt --assignee=codex -- "codex is busy elsewhere")
db "UPDATE tasks SET status='in_progress' WHERE id=${qbusy};"
db "UPDATE tasks SET created_at=datetime('now','-${_HB_STRANDED_HOURS} hours','-1 hour'),
                     first_started_at=NULL WHERE id=${q};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
grep -q 'without ever being started' <<<"$(strandtxt)" \
  && ok_t "E12b POSITIVE CONTROL: a never-started row is still called never-started" \
  || bad_t "E12b never-started row mis-described" "$(strandtxt)"

# --- E13: WITHHOLD A VERDICT THAT WAS NOT MEASURED. sbusy and sload are the only
#     evidence behind "LANE problem, not a priority problem". With both empty the
#     clause is a guess — and it was the clause that prescribed reassign-or-cancel
#     on DIVE-3375, a row that started 17s later exactly as its body said it would.
reset_all
r=$(addt --assignee=quinn -- "stranded on a seat with no other load and nothing in flight")
db "UPDATE tasks SET created_at=datetime('now','-${_HB_STRANDED_HOURS} hours','-1 hour') WHERE id=${r};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(strandmsg)" -ge 1 ]] && ! grep -q 'LANE problem, not a priority problem' <<<"$(strandtxt)" \
  && grep -q 'READ THE ROW' <<<"$(strandtxt)" \
  && ok_t "E13 with neither lane signal present the verdict is withheld, not asserted" \
  || bad_t "E13 asserted a lane cause it did not measure" "$(strandtxt)"

# --- E13b: POSITIVE CONTROL for E13 — with real evidence the verdict still fires.
#     E2 covers the busy-seat half; this covers load-without-an-in-progress-row.
reset_all
u=$(addt --assignee=quinn -- "stranded row")
uother=$(addt --assignee=quinn -- "genuine second todo, seat has nothing in flight")
db "UPDATE tasks SET created_at=datetime('now','-${_HB_STRANDED_HOURS} hours','-1 hour') WHERE id=${u};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
grep -q 'LANE problem, not a priority problem' <<<"$(strandtxt)" \
  && ok_t "E13b POSITIVE CONTROL: measured load alone still earns the lane verdict" \
  || bad_t "E13b withheld a verdict it had evidence for" "$(strandtxt)"

# --- E14: the remedy list offers the THIRD branch. Both original branches are
#     wrong for a row waiting on a date or an event, in opposite directions:
#     reassign re-strands it on the next seat, cancel destroys live work. Measured
#     three times in two days (DIVE-3429 started 9s after its ping, DIVE-3375 17s,
#     DIVE-2037 was event-blocked) — every one a wait written only in the body.
grep -q 'task park --wake=' <<<"$(strandtxt)" \
  && ok_t "E14 the remedy names the park verb, so a body-only wait has a structured fix" \
  || bad_t "E14 remedy still offers only reassign-or-cancel" "$(strandtxt)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
