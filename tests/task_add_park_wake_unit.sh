#!/usr/bin/env bash
# DIVE-6807 isolated unit harness: a one-off reminder is ONE parked row that
# unparks at its minute. `task add --park-wake` took only +Nh|+Nd, so on
# 2026-10-23 an agent's 10-minute reminder for its owner became a once-a-year
# cron template (and a pace-held yearly slot then slipped a year — that half is
# in heartbeat_materialize_recurring_unit.sh, K7). Arms:
#   W1 +10m parks the row with wake_at = now + 10 minutes
#   W2 the wake sweep leaves it parked before that minute and unparks it at it
#   W3 'YYYY-MM-DD HH:MM' --tz=<zone> is read in that zone
#   W4 with no --tz the box's zone reads it (the rule --recurring follows)
#   W5 refusals: past time, loose date text, --tz on +Nm, a bad zone,
#      --park-wake with --recurring; each writes no row
#   W6 `task park --wake=+Nm` takes minutes too (one grammar)
# Run: bash tests/task_add_park_wake_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/add-park-wake-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
export FIVEDIVE_HARNESS=1 FIVEDIVE_NO_HUMAN_SEND=1 FIVE_WIP_CAP=0
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init >/dev/null 2>&1
_hb_log() { :; }

[[ -f "${TZDIR:-/usr/share/zoneinfo}/Asia/Bangkok" ]] || { printf 'SKIP - no tzdata for Asia/Bangkok\n'; exit 0; }

col()   { db "SELECT COALESCE($2,'') FROM tasks WHERE id=$1;"; }
rows()  { db "SELECT COUNT(*) FROM tasks;"; }
add()   { cmd_task_add --assignee=main --from=main --no-verify "$@" 2>"$TMP/err"; }
add_id() { jq -r '.data.id // empty' <<<"$(add "$@")"; }

# ── W1: +10m ───────────────────────────────────────────────────────────────
before=$(db "SELECT datetime('now','+10 minutes');")
id1=$(add_id --park="remind the owner in 10 minutes" --park-wake=+10m -- "10-minute reminder")
after=$(db "SELECT datetime('now','+10 minutes');")
w1=$(col "$id1" wake_at)
if [[ -n "$id1" && "$(col "$id1" status)" == "blocked" && -n "$(col "$id1" parked_at)" \
      && ! "$w1" < "$before" && ! "$w1" > "$after" && "$(col "$id1" kind)" == "standard" ]]; then
  ok_t "W1 --park-wake=+10m files one parked standard row that wakes in 10 minutes"
else
  bad_t "W1 --park-wake=+10m" "id=$id1 wake_at=$w1 window=[$before,$after] err=$(cat "$TMP/err")"
fi

# ── W2: the real wake sweep, before and at the minute ─────────────────────
_hb_gate_ttl_sweep >/dev/null 2>&1
s_before=$(col "$id1" status)
db "UPDATE tasks SET wake_at=datetime(wake_at,'-10 minutes') WHERE id=${id1};"   # ten minutes pass
_hb_gate_ttl_sweep >/dev/null 2>&1
if [[ "$s_before" == "blocked" && "$(col "$id1" status)" == "todo" && -z "$(col "$id1" parked_at)" ]]; then
  ok_t "W2 the wake sweep keeps it parked before its minute and unparks it to todo at it"
else
  bad_t "W2 wake sweep" "before=$s_before after=$(col "$id1" status) parked_at=$(col "$id1" parked_at)"
fi

# ── W3: wall clock in --tz ─────────────────────────────────────────────────
day=$(TZ=Asia/Bangkok date -d '+2 days' +%Y-%m-%d)
want=$(date -u -d "TZ=\"Asia/Bangkok\" ${day} 20:38" +'%Y-%m-%d %H:%M:%S')
out3=$(add --park="owner reminder" --park-wake="${day} 20:38" --tz=Asia/Bangkok -- "Bangkok reminder")
id3=$(jq -r '.data.id // empty' <<<"$out3")
if [[ -n "$id3" && "$(col "$id3" wake_at)" == "$want" && "$want" == *" 13:38:00" ]]; then
  ok_t "W3 'YYYY-MM-DD 20:38' --tz=Asia/Bangkok wakes at 13:38 UTC that day"
else
  bad_t "W3 tz wall clock" "id=$id3 wake_at=$(col "$id3" wake_at) want=$want err=$(cat "$TMP/err")"
fi
JSON_MODE=0
out3h=$(cmd_task_add --assignee=main --from=main --no-verify --park="owner reminder" --park-wake="${day}T20:38" --tz=Asia/Bangkok -- "Bangkok reminder T" 2>&1)
JSON_MODE=1
if [[ "$out3h" == *"PARKED until ${want%:*} UTC = ${day} 20:38 Asia/Bangkok"* ]]; then
  ok_t "W3 the created line names the wake in UTC and in the zone it was typed in (the T form parses too)"
else
  bad_t "W3 created line" "$out3h"
fi

# ── W4: no --tz -> the box's zone ─────────────────────────────────────────
id4=$(FIVE_BOX_TZ=Asia/Bangkok add_id --park="owner reminder" --park-wake="${day} 21:00" -- "box-zone reminder")
if [[ -n "$id4" && "$(col "$id4" wake_at)" == "$(date -u -d "TZ=\"Asia/Bangkok\" ${day} 21:00" +'%Y-%m-%d %H:%M:%S')" ]]; then
  ok_t "W4 with no --tz a wall-clock wake is read in the box's zone"
else
  bad_t "W4 box zone" "id=$id4 wake_at=$(col "$id4" wake_at) err=$(cat "$TMP/err")"
fi

# ── W5: refusals write nothing ─────────────────────────────────────────────
refused() {  # refused <label> <args...>
  local label="$1"; shift
  local n0 n1 rc
  n0=$(rows)
  ( add "$@" >/dev/null ); rc=$?
  n1=$(rows)
  if (( rc != 0 )) && [[ "$n0" == "$n1" ]]; then
    ok_t "W5 refused, no row: ${label}"
  else
    bad_t "W5 refused, no row: ${label}" "rc=$rc rows $n0 -> $n1 err=$(cat "$TMP/err")"
  fi
}
refused "a wake in the past"          --park=r --park-wake="2020-01-01 09:00" --tz=Asia/Bangkok -- "past"
refused "loose date text"             --park=r --park-wake="tomorrow 20:38" --tz=Asia/Bangkok -- "loose"
refused "+0m (not in the future)"     --park=r --park-wake=+0m -- "zero"
refused "+Nx (unknown unit)"          --park=r --park-wake=+10x -- "unit"
refused "--tz on a relative wake"     --park=r --park-wake=+10m --tz=Asia/Bangkok -- "tz rel"
refused "a zone this box does not know" --park=r --park-wake="${day} 20:38" --tz=Mars/Olympus -- "bad zone"
refused "--park-wake with --recurring" --park=r --park-wake=+10m --recurring="0 9 * * *" -- "both clocks"
refused "--tz with no time at all"    --tz=Asia/Bangkok -- "tz alone"

# ── W6: task park takes minutes too ────────────────────────────────────────
id6=$(add_id -- "park me")
b6=$(db "SELECT datetime('now','+15 minutes');")
cmd_task_park "$id6" --reason="back in a quarter hour" --wake=+15m >/dev/null 2>&1
a6=$(db "SELECT datetime('now','+15 minutes');")
w6=$(col "$id6" wake_at)
if [[ -n "$w6" && ! "$w6" < "$b6" && ! "$w6" > "$a6" ]]; then
  ok_t "W6 task park --wake=+15m wakes in 15 minutes"
else
  bad_t "W6 task park +15m" "wake_at=$w6 window=[$b6,$a6]"
fi
id6b=$(add_id -- "park me by date")
cmd_task_park "$id6b" --reason="dated" --wake="2099-01-02 03:04" >/dev/null 2>&1
if [[ "$(col "$id6b" wake_at)" == "2099-01-02 03:04:00" ]]; then
  ok_t "W6 task park --wake='YYYY-MM-DD HH:MM' is still UTC, unchanged"
else
  bad_t "W6 task park date" "wake_at=$(col "$id6b" wake_at)"
fi

echo "-- ${PASS} passed, ${FAIL} failed --"
[[ $FAIL -eq 0 ]]
