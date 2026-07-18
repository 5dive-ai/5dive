#!/usr/bin/env bash
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
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-stall-sweep.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_heartbeat.sh; do
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
( cmd_task_done "$a" ) >/dev/null 2>&1
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
grep -q $'^main\t.*Delivered-awaiting-verifier' "$SEND_LOG" \
  && ok_t "stale delivery also pings main (never invisible)" || bad_t "main not pinged" "$(cat "$SEND_LOG")"
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
( cmd_task_done "$b" ) >/dev/null 2>&1
db "UPDATE tasks SET handoff_delivered_at=datetime('now','-999 minutes'),
       handoff_ack_at=datetime('now') WHERE id=${b};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ ! -s "$SEND_LOG" ]] \
  && ok_t "acknowledged handoff is never surfaced" \
  || bad_t "acked handoff surfaced" "$(cat "$SEND_LOG")"

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

# --- B3: backdate the persistence clock past the threshold -> alarms main
db "UPDATE task_prefs SET value=datetime('now','-${_HB_STALL_MIN_MINUTES} minutes','-1 minutes')
    WHERE key='stall_first_seen_at';"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
grep -q $'^main\t.*fleet-stall' "$SEND_LOG" \
  && ok_t "persisted stall (past _HB_STALL_MIN_MINUTES) alarms main" \
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

# --- B6: open human gate (not just a stranded todo) also counts as stranded work
reset_all
gate_task=$(addt --assignee=bob -- "needs a call")
( cmd_task_need "$gate_task" --type=decision --options="X|Y" --ask="pick" ) >/dev/null 2>&1
_hb_stall_sweep >/dev/null 2>&1
[[ -n "$(db "SELECT value FROM task_prefs WHERE key='stall_first_seen_at';")" ]] \
  && ok_t "an open human gate alone starts the stall clock" \
  || bad_t "gate not counted as stranded" ""

# =============================================================================
# (c) gap#3 canary — pinger liveness
# =============================================================================

# --- C1: no eligible gates -> no alarm, no tripped record
reset_all
_hb_stall_sweep >/dev/null 2>&1
[[ -z "$(db "SELECT value FROM task_prefs WHERE key='pinger_canary_alerted_at';")" ]] \
  && ok_t "no eligible gates -> canary never trips" || bad_t "canary tripped with nothing eligible" ""

# --- C2: an eligible (stale, unpinged) T2 gate exists + gate_pinged_at has never
#     advanced fleet-wide -> canary trips, alarms main
reset_all
g=$(addt --assignee=dev -- "stale gate")
db "UPDATE tasks SET status='blocked', need_type='approval', tier=2,
       need_asked_at=datetime('now','-10 days'), gate_pinged_at=NULL
     WHERE id=${g};"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
grep -q $'^main\t.*pinger-liveness canary tripped' "$SEND_LOG" \
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
