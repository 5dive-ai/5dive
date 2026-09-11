#!/usr/bin/env bash
# DIVE-4328 — a supervisor park keys to the WALL'S OWN RESET TIME and un-parks
# itself. Invariant 4 of DIVE-4327's loop state machine: a park a human has to
# end is not a park.
#
# THE ROW, measured 2026-09-11: codex held its claim on DIVE-4290 for 5h past
# the reset time its own quota wall printed, and was then reaped one tick after
# a forced wake on a `started_at` left over from before the park. Two distinct
# defects, and this harness grades both:
#
#   A. THE DEADLINE WAS PARSED AND THROWN AWAY. `_sup_quota_deadline` echoes
#      "<state>\x1f<epoch>"; the record builder took field 1 and dropped field 2,
#      so `signals.quotaDeadline` only ever held `live`/`lapsed`/`unknown`. The
#      park then ran `date -d` on that word, which cannot succeed, and fell to
#      the blind 6h cap — REBASED on every fresh observation of the same dead
#      pane, so it never expired at all.
#   B. NOTHING OWNED THE EDGE. When a park does end, the claim ages it froze are
#      still on the clock, and the first tick past the wall reaps exactly the
#      rows the park was protecting.
#
# Every arm is pure or db-only: no tmux, no root, no network, no registry file.
# Run: bash tests/heartbeat_quota_unpark_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-quota-unpark.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_supervisor.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ── boundaries ───────────────────────────────────────────────────────────────
REGISTRY="$TMP/registry.json"; printf '{"agents":{}}' >"$REGISTRY"
registry_read()      { cat "$REGISTRY"; }
registry_write()     { cat > "$REGISTRY"; }
with_registry_lock() { local fn="$1"; shift; "$fn" "$@"; }
_hb_pane_fingerprint() { echo "fp"; }
cmd_send()           { :; }
_hb_claude_started() { echo ""; }    # rule (a) never fires
_hb_agent_idle()     { return 1; }   # no confident idle reading -> rule (b) out of scope
ESC_LOG="$TMP/escalated"; SEND_LOG="$TMP/sent"; WAKE_LOG="$TMP/woke"
cmd_task_escalate()  { printf '%s\n' "$1" >>"$ESC_LOG"; }
_hb_send_line()      { printf '%s\n' "$2" >>"$SEND_LOG"; return 0; }
# The wake is a SPY, not a no-op: arm 4 asserts the un-park actually reaches it,
# and a silent stub would let "never woke anything" pass as success.
_hb_wake()           { printf '%s %s\n' "$1" "$3" >>"$WAKE_LOG"; return 0; }
spies_reset() { : >"$ESC_LOG"; : >"$SEND_LOG"; : >"$WAKE_LOG"; }
escalated()   { [[ -s "$ESC_LOG" ]]; }
woke()        { [[ -s "$WAKE_LOG" ]]; }

addt()  { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
row()   { db "SELECT status||'|'||COALESCE(reap_escalated_n,0) FROM tasks WHERE id=$1;"; }
age_m() { db "SELECT CAST((julianday('now') - julianday(started_at)) * 1440 AS INTEGER) FROM tasks WHERE id=$1;"; }
reset_all() { db "DELETE FROM tasks; DELETE FROM supervisor_events;"; }

# One supervisor observation, shaped like the real column. `epoch` is the
# DIVE-4328 signal: the reset time the wall itself printed, or "" for a wall
# that named none.
sup_obs() {
  local agent="$1" cls="$2" ago="$3" deadline="${4:-unknown}" epoch="${5:-}"
  local ep_json="null"; [[ "$epoch" =~ ^[0-9]+$ ]] && ep_json="$epoch"
  db "INSERT INTO supervisor_events (ts, agent, event, classification, cause, signals)
      VALUES (datetime('now','-${ago}'), $(sqlq "$agent"), 'observe', $(sqlq "$cls"), $(sqlq "$cls"),
              '{\"signals\":{\"quotaDeadline\":\"${deadline}\",\"quotaDeadlineEpoch\":${ep_json}}}');"
}
mk_overrun() {
  local who="$1" mins="$2" id
  id=$(addt --assignee="$who" -- "a walled seat's row")
  _hb_claim_task "$who" "$id" >/dev/null 2>&1
  db "UPDATE tasks SET started_at=datetime('now','-${mins} minutes') WHERE id=${id};"
  printf '%s' "$id"
}

NOW=$(date -u +%s)

# ── 1. the supervisor half: the deadline is PARSED, and it must be STORED ────
# The parser was never the gap — DIVE-4206 taught it this exact phrasing. Pin
# that it still yields BOTH fields, because field 2 is the whole fix.
WALL="You've hit your 5-hour limit · resets 4am (UTC)"
IFS=$'\x1f' read -r DST DEP <<<"$(_sup_quota_deadline "$WALL" "$NOW")"
{ [[ "$DST" == "live" || "$DST" == "lapsed" ]] && [[ "$DEP" =~ ^[0-9]+$ ]]; } \
  && ok_t "the wall's reset time parses to a state AND an epoch (DIVE-4206 pin)" \
  || bad_t "the reset time did not parse to two fields" "state='$DST' epoch='$DEP'"

# THE DEFECT, as a static arm: the record builder must not take field 1 alone.
# This is the line that made every park blind, and it reads as a harmless cut.
if grep -qE '_sup_quota_deadline "\$quota_excerpt" "\$now" \| cut -f1' "$SRC/cmd_supervisor.sh"; then
  bad_t "the record builder still keeps only the STATE of the parse" \
        "cmd_supervisor.sh drops the epoch field again — the park cannot key to a time it is not given"
else
  ok_t "the record builder keeps the epoch, not just the three-state parse"
fi
grep -q 'quotaDeadlineEpoch' "$SRC/cmd_supervisor.sh" \
  && ok_t "supervisor emits signals.quotaDeadlineEpoch" \
  || bad_t "no quotaDeadlineEpoch signal is emitted" "the reclaimer has nothing to read"

# ── 2. the park keys to that time, not to a blind cap ────────────────────────
reset_all
sup_obs codex quota-exhausted "2 minutes" live "$(( NOW + 5400 ))"   # resets in 90m
U=$(_hb_quota_park_until_seat codex 15)
EXP=$(( NOW + 5400 + 15 * 60 ))
if [[ "$U" =~ ^[0-9]+$ ]] && (( U >= EXP - 2 && U <= EXP + 2 )); then
  ok_t "park runs to the wall's own reset time + one tick (not the 6h cap)"
else
  bad_t "park did not key to the wall's reset time" "got '$U', expected ~${EXP} (6h cap would be ~$(( NOW + 21600 )))"
fi

# ── 3. THE WEDGE: a fresh observation of a DEAD wall must not re-park ────────
# This is the 5h hold, reduced to one assertion. The pane goes on rendering the
# refusal, so the supervisor re-observes `quota-exhausted` every tick with a
# CURRENT ts — and a 6h fallback measured from that ts rolls forward forever.
# The wall's own reset time is the only thing in the record that does not move.
reset_all
sup_obs codex quota-exhausted "1 minute" lapsed "$(( NOW - 10800 ))"  # reset 3h ago
if _hb_quota_parked codex 15 >/dev/null; then
  bad_t "a seat is still parked 3h past its wall's reset time" \
        "the newest observation is 1m old — this is the rolling-6h wedge (park until $(_hb_quota_park_until_seat codex 15))"
else
  ok_t "3h past the wall's reset time the seat is NOT parked, however fresh the observation"
fi
# NON-VACUITY: the identical shape with the reset time still ahead stays parked.
reset_all
sup_obs codex quota-exhausted "1 minute" live "$(( NOW + 3600 ))"
_hb_quota_parked codex 15 >/dev/null \
  && ok_t "[control] the same seat, reset time still 1h ahead, IS parked" \
  || bad_t "a live wall stopped parking the claim" "park until '$(_hb_quota_park_until_seat codex 15)'"

# ── 4. the un-park: one tick, and the row is NOT reaped on the next ──────────
# everyMin=15 -> a 45m budget; the row is 100m into a claim it spent parked.
reset_all; spies_reset
sup_obs codex quota-exhausted "1 minute" live "$(( NOW + 3600 ))"
T=$(mk_overrun codex 100)
_hb_reclaim codex 15 >/dev/null 2>&1
{ [[ "$(row "$T")" == "in_progress|0" ]] && ! woke; } \
  && ok_t "tick 1: inside the park the claim is HELD and nothing is woken" \
  || bad_t "the park did not hold the claim" "row=$(row "$T") woke='$(tr '\n' ' ' <"$WAKE_LOG")'"
# The wall lifts: a newer observation carries a reset time that passed 30m ago,
# clear of the deadline-plus-one-tick grace the park deliberately adds. The
# claim is older still (100m), so it is one the park froze.
sup_obs codex quota-exhausted "0 minutes" lapsed "$(( NOW - 1800 ))"
_hb_reclaim codex 15 >/dev/null 2>&1
A=$(age_m "$T")
if [[ "$(row "$T")" == "in_progress|0" ]] && [[ "$A" =~ ^[0-9]+$ ]] && (( A < 5 )); then
  ok_t "tick 2: un-parked, and the budget clock is re-stamped (claim age ${A}m, was 100m)"
else
  bad_t "the un-park did not re-stamp the budget clock" "row=$(row "$T") age=${A}m"
fi
woke \
  && ok_t "tick 2: the un-park WOKE the seat onto the row it still holds" \
  || bad_t "the seat was un-parked and left asleep holding a claim" "nothing reached _hb_wake"
# THE MEASURED SEQUEL: the very next tick reaped the row on the pre-park clock.
_hb_reclaim codex 15 >/dev/null 2>&1
{ [[ "$(row "$T")" == "in_progress|0" ]] && ! escalated; } \
  && ok_t "tick 3: NOT reaped and NOT escalated — the un-parked seat got its full 45m window" \
  || bad_t "the un-parked row was reaped on its pre-park claim age" "row=$(row "$T") escalated='$(tr '\n' ' ' <"$ESC_LOG")'"

# ── 5. controls — the un-park may not fire early, and may not credit a row
#      that was never held under the park ─────────────────────────────────────
reset_all; spies_reset
sup_obs codex quota-exhausted "1 minute" live "$(( NOW + 3600 ))"
T2=$(mk_overrun codex 100)
_hb_reclaim codex 15 >/dev/null 2>&1
_hb_reclaim codex 15 >/dev/null 2>&1   # a second tick, still inside the park
A2=$(age_m "$T2")
{ [[ "$A2" =~ ^[0-9]+$ ]] && (( A2 >= 95 )) && ! woke; } \
  && ok_t "[control] inside the park: clock untouched (${A2}m), no wake" \
  || bad_t "the un-park fired while the wall was still up" "age=${A2}m woke='$(tr '\n' ' ' <"$WAKE_LOG")'"

reset_all; spies_reset
sup_obs codex quota-exhausted "5 minutes" live "$(( NOW + 3600 ))"
T3=$(mk_overrun codex 100)
_hb_reclaim codex 15 >/dev/null 2>&1                       # park + marker
sup_obs codex quota-exhausted "0 minutes" lapsed "$(( NOW - 1800 ))"   # wall lifts
T4=$(mk_overrun codex 100)                                  # a row claimed AFTER the park end
db "UPDATE tasks SET started_at=datetime('now') WHERE id=${T4};"
_hb_reclaim codex 15 >/dev/null 2>&1
A4=$(age_m "$T4")
{ [[ "$A4" =~ ^[0-9]+$ ]] && (( A4 < 5 )); } \
  && ok_t "[control] a row claimed after the park end keeps its own (fresh) clock" \
  || bad_t "the un-park rewrote a clock it did not freeze" "age=${A4}m"

# ── 5c. THE LATCH, and it is the absence of one. The un-park must be a silent
#      no-op on every tick after it fires, or a stale quota-exhausted row
#      re-stamps the claim forever and the budget becomes unreachable.
spies_reset
_hb_reclaim codex 15 >/dev/null 2>&1
! woke \
  && ok_t "[control] a second tick past the same ended park wakes nothing (no re-fire)" \
  || bad_t "the un-park re-fires every tick" "woke='$(tr '\n' ' ' <"$WAKE_LOG")'"

# ── 5d. A BLIND 6h-CAP PARK IS NOT UN-PARKED HERE. The cap is a guess that the
#      wall is probably over; this row's axis is the reset time the WALL NAMED.
#      An expired fallback park releases the row to the ordinary rule exactly as
#      it did before — including the reap, which is what the neighbouring
#      harness (tests/heartbeat_codex_wall_unit.sh, arm 3d) pins.
reset_all; spies_reset
sup_obs codex quota-exhausted "7 hours" unknown ""
T5=$(mk_overrun codex 100)
_hb_reclaim codex 15 >/dev/null 2>&1
# The row is reclaimed by the ordinary hard-cap rule, exactly as on origin/main.
{ [[ "$(row "$T5")" == todo\|* ]] && ! woke; } \
  && ok_t "[control] an expired 6h-cap park (no wall-named time) does NOT re-stamp or wake — the ordinary rule still owns the row" \
  || bad_t "a blind fallback park was treated as a wall-named one" "row=$(row "$T5") woke='$(tr '\n' ' ' <"$WAKE_LOG")'"

# ── 6. back-compat: an event written before this row carries no epoch ────────
# The 6h fallback is what those rows have always had and it must still apply —
# the fix adds a better answer, it does not remove the old one.
reset_all
sup_obs codex quota-exhausted "30 minutes" unknown ""
U6=$(_hb_quota_park_until_seat codex 15)
EXP6=$(( NOW - 1800 + 21600 ))
if [[ "$U6" =~ ^[0-9]+$ ]] && (( U6 >= EXP6 - 120 && U6 <= EXP6 + 120 )); then
  ok_t "a wall naming no reset time still falls to the 6h cap (pre-4328 rows unchanged)"
else
  bad_t "the unknown-deadline fallback changed" "got '$U6', expected ~${EXP6}"
fi

# ── 7. THE COST OF THE COMMON TICK (iteration 3) ─────────────────────────────
# Iteration 2 asked sqlite for the newest observation in its OWN `db` call at
# the top of every `_hb_reclaim` — one extra sqlite3 fork per seat per tick even
# when nothing anywhere is parked, which is the shape of almost every tick and
# of almost every harness in the corpus. The read now rides the SAME invocation
# as the seat's rows, so an ordinary tick must issue exactly ONE query here.
#
# THE NUMBER IS THE ASSERTION, not a comment about one: this arm counts `db`
# invocations across a whole reclaim of a seat that is NOT parked and holds one
# row well inside its budget. It reads 1 with the fold and 2 without it, so
# re-adding an unconditional pre-query reddens this arm rather than quietly
# costing the corpus a fork per tick again.
#
# COUNTED THROUGH A FILE, not a variable: the query runs inside `mapfile < <(…)`,
# a subshell whose increments never reach this shell.
reset_all; spies_reset
DB_LOG="$TMP/dbcalls"
eval "_db_real() $(declare -f db | tail -n +2)"
db() { printf 'x\n' >>"$DB_LOG"; _db_real "$@"; }
sup_obs codex idle "1 minute" unknown ""     # observed, and NOT walled
T7=$(mk_overrun codex 3)                     # a held row, comfortably inside budget
: >"$DB_LOG"
_hb_reclaim codex 15 >/dev/null 2>&1
DBN=$(wc -l <"$DB_LOG" | tr -d ' ')
(( DBN == 1 )) \
  && ok_t "an un-parked tick costs ONE query — the observation rides the row read, not a second fork" \
  || bad_t "the common reclaim tick issues ${DBN} queries, not 1" \
           "the un-park is paying for a read on every tick of every seat again"
# NON-VACUITY: the counter is real, and the row was genuinely judged — a reclaim
# that queried nothing because it did nothing would also read 1.
{ [[ "$(row "$T7")" == in_progress\|* ]] && (( $(wc -l <"$DB_LOG") > 0 )); } \
  && ok_t "[control] the counted tick really ran — the row is still held, inside its budget" \
  || bad_t "the cost arm graded an empty tick" "row=$(row "$T7") calls=$(wc -l <"$DB_LOG")"
unset -f db; eval "db() $(declare -f _db_real | tail -n +2)"

printf '\n%d passed / %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
