#!/usr/bin/env bash
# DIVE-6106: balance-mode account rotation. Every acceptance criterion on the
# row is an arm here, named on the arm:
#   1. a week, 4 accounts, 12 seats: balance on keeps the 7d spread (max-min)
#      <= SPREAD_BOUND all week; balance off exceeds it (negative control);
#   2. a seat mid-turn is never moved (the sim offers EVERY seat EVERY tick, so
#      a mid-turn move is a countable gate failure, plus a direct decision arm);
#   3. damping: a trace that flaps between two accounts moves at most once per
#      3h per seat, and at most one seat per tick fleet-wide;
#   4. tie-break: equal 7d, 3 active seats vs 0 -> the empty account;
#   5. near-wall unchanged with balance off (rotate verb, pool order).
# The simulator (tests/lib/rotation_balance_sim.jq) is prepended with the
# PRODUCTION jq text (ROTATION_BALANCE_JQ), so it grades the shipped rule.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

for f in lib/error_codes.sh lib/output.sh header.sh lib/state.sh lib/registry.sh \
         lib/tasks_db.sh lib/account_history.sh cmd_account.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e
TMP=$(mktemp -d /tmp/rotation-balance-unit.XXXXXX)
JSON_MODE=1

PASS=0; FAIL=0
t() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL - %s — expected [%s], got [%s]\n' "$1" "$2" "$3"
  fi
}
[[ -n "${ROTATION_BALANCE_JQ:-}" ]] && declare -F rotation_balance_rotate >/dev/null \
  || { echo "FAIL - production balance code not found in src/cmd_account.sh"; exit 1; }

K=$(rotation_balance_knobs_json)
NOW=$(date +%s)

# --- 1. the week -------------------------------------------------------------
# 10-minute ticks, 7 days. Capacity 1000 units/account/week; a 5h window holds
# 12% of a week. Demand ~66% of the four accounts, placed the way the fleet sat
# before balance existed: six seats on one account. main + marketing are
# non-fresh (never balance-moved); `pinned` is one live turn the whole week.
SPREAD_BOUND=25
week() {
  jq -cn --argjson bal "$1" --argjson k "$K" '{balance:$bal, knobs:($k | .freshSecs = 100000000),
   ticks:1008, tickSecs:600, cap7:1000, cap5:120, win5:30, warmup:0,
   accounts:["chemmonitor","mark","mp","mp-team"],
   seats:[
    {name:"main",acct:"mark",rate:0.56,fresh:false,seed:11},
    {name:"marketing",acct:"mp",rate:0.28,fresh:false,seed:12},
    {name:"dev",acct:"mark",rate:0.49,fresh:true,seed:13},
    {name:"dev2",acct:"mark",rate:0.35,fresh:true,seed:14},
    {name:"quinn",acct:"mark",rate:0.42,fresh:true,seed:15},
    {name:"ops",acct:"mark",rate:0.21,fresh:true,seed:16},
    {name:"community",acct:"chemmonitor",rate:0.21,fresh:true,seed:17},
    {name:"creative",acct:"mark",rate:0.21,fresh:true,seed:18},
    {name:"olivia",acct:"chemmonitor",rate:0.14,fresh:true,seed:19},
    {name:"oinoa",acct:"mp",rate:0.28,fresh:true,seed:20},
    {name:"ads",acct:"mp",rate:0.14,fresh:true,seed:21},
    {name:"pinned",acct:"mp-team",rate:0.17,fresh:true,seed:22,pinBusy:true}
   ]}' | jq -c "${ROTATION_BALANCE_JQ} $(cat tests/lib/rotation_balance_sim.jq)"
}
ON=$(week true); OFF=$(week false)
echo "  week, balance on : $ON"
echo "  week, balance off: $OFF"
t "1 balance ON keeps the week's 7d spread <= ${SPREAD_BOUND} points" "true" \
  "$(jq --argjson b "$SPREAD_BOUND" '.spread <= $b' <<<"$ON")"
t "1 negative control: balance OFF exceeds ${SPREAD_BOUND} points" "true" \
  "$(jq --argjson b "$SPREAD_BOUND" '.spread > $b' <<<"$OFF")"
t "1 balance ON: no seat ever blocked on a walled account" "0" "$(jq '.blockedTicks' <<<"$ON")"
t "1 control: balance OFF does block seats on a wall" "true" "$(jq '.blockedTicks > 0' <<<"$OFF")"
t "1 balance ON actually moved seats (the spread is the policy's, not the trace's)" "true" \
  "$(jq '.balanceMoves > 0' <<<"$ON")"
t "2 week: zero moves issued for a seat mid-turn" "0" "$(jq '.busyMoves' <<<"$ON")"
t "2 week: the seat in one live turn all week is never moved" "0" "$(jq '.pinnedMoves' <<<"$ON")"
t "non-fresh seats (main, marketing) are never balance-moved" "0" "$(jq '.nonFreshMoves' <<<"$ON")"
t "3 week: at most one balance move per tick fleet-wide" "true" "$(jq '.maxMovesPerTick <= 1' <<<"$ON")"
t "3 week: at most one balance move per seat per 3h" "true" "$(jq '.maxSeatMovesIn3h <= 1' <<<"$ON")"

# --- 2. mid-turn, directly ---------------------------------------------------
dec() { # <idle> <fresh> <newtask> <fleet> <last> <accounts>
  rotation_balance_decide "$(jq -cn --argjson now "$NOW" --argjson k "$K" \
    --argjson i "$1" --argjson f "$2" --argjson n "$3" --argjson fm "$4" --argjson l "$5" --argjson a "$6" \
    '{current:"hot", now:$now, seatLastMoveAt:$l, fleetMoved:$fm,
      boundary:{idle:$i, fresh:$f, newTask:$n}, accounts:$a, knobs:$k}')"
}
GAP=$(jq -cn --argjson now "$NOW" '[{name:"hot",fivePct:20,sevenPct:80,asOf:$now,activeSeats:4},
  {name:"cool",fivePct:5,sevenPct:10,asOf:$now,activeSeats:0}]')
t "2 positive control: idle, fresh, new row, 70-point gap -> move" "true cool" \
  "$(dec true true true false null "$GAP" | jq -r '"\(.move) \(.to)"')"
t "2 a live turn (idle=false) yields no move" "false" "$(dec false true true false null "$GAP" | jq '.move')"
t "a non-fresh wake yields no move" "false" "$(dec true false true false null "$GAP" | jq '.move')"
t "a reclaimed (already started) row is not a boundary" "false" "$(dec true true false false null "$GAP" | jq '.move')"
STALE=$(jq -c --argjson old "$((NOW - 3600))" 'map(if .name=="hot" then .asOf=$old else . end)' <<<"$GAP")
t "a stale current reading is unmeasured, not a reason to move" "false" "$(dec true true true false null "$STALE" | jq '.move')"
BURST=$(jq -c 'map(if .name=="cool" then .fivePct=70 else . end)' <<<"$GAP")
t "never onto an account over the 5h burst floor" "false" "$(dec true true true false null "$BURST" | jq '.move')"
SMALL=$(jq -c 'map(if .name=="cool" then .sevenPct=66 else . end)' <<<"$GAP")
t "a 14-point gap (<= 15) does not move" "false" "$(dec true true true false null "$SMALL" | jq '.move')"

# --- 3. damping on a flapping trace ------------------------------------------
# Readings swap every 10 minutes for 6h: A hot/B cool, then B hot/A cool. With
# no damping the seat would chase the cool one every tick.
flap() { # <seatMinSecs>
  jq -cn --argjson k "$K" --argjson sm "$1" --argjson now "$NOW" "${ROTATION_BALANCE_JQ}"'
    reduce range(0; 36) as $i ({cur:"A", last:null, moves:0};
      ($now + $i * 600) as $t
      | (if ($i % 2) == 0 then {A:80, B:20} else {A:20, B:80} end) as $p
      | ({current:.cur, now:$t, seatLastMoveAt:.last, fleetMoved:false,
          boundary:{idle:true, fresh:true, newTask:true}, knobs:($k | .seatMinSecs = $sm),
          accounts:[{name:"A",fivePct:10,sevenPct:$p.A,asOf:$t,activeSeats:0},
                    {name:"B",fivePct:10,sevenPct:$p.B,asOf:$t,activeSeats:0}]} | balance_decide) as $v
      | if $v.move then .cur = $v.to | .last = $t | .moves += 1 else . end) | .moves'
}
t "3 control: the trace DOES flap with damping off (>= 10 moves in 6h)" "true" \
  "$( (( $(flap 0) >= 10 )) && echo true || echo false)"
t "3 damping holds: the flapping 6h trace yields at most 2 moves (one per 3h)" "true" \
  "$( (( $(flap "$ROTATION_BALANCE_SEAT_MIN_SECS") <= 2 )) && echo true || echo false)"
t "3 fleet damping: a second seat in the same tick is held" "false" "$(dec true true true true null "$GAP" | jq '.move')"
t "3 seat damping: moved 1h ago -> held" "false" "$(dec true true true false "$((NOW - 3600))" "$GAP" | jq '.move')"

# --- 4. tie-break --------------------------------------------------------------
TIE=$(jq -cn --argjson now "$NOW" '[{name:"hot",fivePct:20,sevenPct:80,asOf:$now,activeSeats:1},
  {name:"busy",fivePct:10,sevenPct:30,asOf:$now,activeSeats:3},
  {name:"empty",fivePct:10,sevenPct:30,asOf:$now,activeSeats:0}]')
t "4 equal 7d: 3 active seats vs 0 -> the empty account" "empty" "$(dec true true true false null "$TIE" | jq -r '.to')"
NEAR=$(jq -c 'map(if .name=="empty" then .sevenPct=33 else . end)' <<<"$TIE")
t "4 within the 5-point tie band the emptier account still wins" "empty" "$(dec true true true false null "$NEAR" | jq -r '.to')"
FAR=$(jq -c 'map(if .name=="empty" then .sevenPct=45 else . end)' <<<"$TIE")
t "4 outside the band the lower 7d wins whatever its seat count" "busy" "$(dec true true true false null "$FAR" | jq -r '.to')"

# --- 5. near-wall path with balance OFF / ON -----------------------------------
REG0='{"agents":{"seat":{"type":"claude","authProfile":"full","rotation":{"enabled":true,"accounts":["full","a-first","b-low"],"cooldowns":{}}}}}'
# File-backed: the hook runs the verb inside $( ), so a variable-only registry
# would lose every write the verb makes — production writes a file too.
REGF="$TMP/agents.json"
registry_read() { cat "$REGF"; }
registry_write() { cat >"$REGF.tmp" && mv "$REGF.tmp" "$REGF"; }
setreg() { printf '%s' "$1" >"$REGF"; }
require_root() { :; }; ensure_state() { :; }; ensure_state_ro() { :; }
with_registry_lock() { "$@"; }
CONFIG_CALLS="$TMP/config"; : >"$CONFIG_CALLS"
setreg "$REG0"
cmd_config() {
  printf '%s\n' "$*" >>"$CONFIG_CALLS"
  registry_read | jq -c --arg a "$1" --arg p "${3#auth-profile=}" '.agents[$a].authProfile = $p' | registry_write
}
account_near_wall_state() { [[ "$1" == full ]] && printf near || printf clear; }
account_has_live_headroom() { [[ "$1" != full ]]; }
db() { printf ''; }
# readings for the balance ordering: a-first is the drained one, b-low the roomy one
account_balance_reading() {
  case "$1" in
    a-first) jq -cn --argjson n "$NOW" '{asOf:$n,fiveHourPct:10,sevenDayPct:70}' ;;
    b-low)   jq -cn --argjson n "$NOW" '{asOf:$n,fiveHourPct:10,sevenDayPct:20}' ;;
    full)    jq -cn --argjson n "$NOW" '{asOf:$n,fiveHourPct:95,sevenDayPct:60}' ;;
  esac
}
t "5 balance OFF: near-wall picks the first measured account in pool order, as before" "a-first" \
  "$(cmd_agent_rotation_rotate seat --if-current-near-wall --require-live-headroom | jq -r '.data.to')"
setreg "$(registry_read | jq -c '.agents.seat.authProfile = "full" | .agents.seat.rotation.balance = true')"
t "5 balance ON: near-wall picks the least-drained account instead" "b-low" \
  "$(cmd_agent_rotation_rotate seat --if-current-near-wall --require-live-headroom | jq -r '.data.to')"

# --- heartbeat hook ------------------------------------------------------------
# Real _hb_rotate_at_dispatch_boundary + real rotation_balance_rotate; only the
# near-wall verdict and readings are stubbed.
setreg '{"agents":{
  "s1":{"type":"claude","authProfile":"hot","rotation":{"enabled":true,"allAccounts":false,"accounts":["hot","cool"],"cooldowns":{},"balance":true}},
  "s2":{"type":"claude","authProfile":"hot","rotation":{"enabled":true,"allAccounts":false,"accounts":["hot","cool"],"cooldowns":{},"balance":true}},
  "s3":{"type":"claude","authProfile":"hot","rotation":{"enabled":true,"allAccounts":false,"accounts":["hot","cool"],"cooldowns":{},"balance":false}}}}'
REG=$(registry_read)
account_near_wall_state() { printf clear; }
account_balance_reading() {
  case "$1" in
    hot)  jq -cn --argjson n "$NOW" '{asOf:$n,fiveHourPct:20,sevenDayPct:75}' ;;
    cool) jq -cn --argjson n "$NOW" '{asOf:$n,fiveHourPct:5,sevenDayPct:25}' ;;
  esac
}
: >"$CONFIG_CALLS"; _HB_BALANCE_TICK_MOVED=0
_hb_rotate_at_dispatch_boundary s1 "$REG"; rc=$?
t "hook: a two-argument call carries no boundary facts and never balance-moves" "1" "$rc"
_hb_rotate_at_dispatch_boundary s1 "$REG" true false true; rc=$?
t "hook: idle=false (mid-turn / live shell) -> no move" "1 0" "$rc $(wc -l <"$CONFIG_CALLS" | tr -d ' ')"
_hb_rotate_at_dispatch_boundary s1 "$REG" true true true; rc=$?
t "hook: clear account + fresh boundary + 50-point gap -> balance move" "0 balance hot->cool 75->25" \
  "$rc $_HB_BOUNDARY_ROTATION_KIND ${_HB_BOUNDARY_ROTATION_FROM}->${_HB_BOUNDARY_ROTATION_TO} ${_HB_BOUNDARY_ROTATION_FROM7}->${_HB_BOUNDARY_ROTATION_TO7}"
t "hook: the move went through cmd_config (one binding emitter)" "s1 set auth-profile=cool" "$(tail -1 "$CONFIG_CALLS")"
t "hook: the seat's lastBalanceAt is stamped" "true" "$(registry_read | jq --argjson n "$NOW" '.agents.s1.rotation.lastBalanceAt >= $n')"
t "hook: the registry now binds the seat to the destination" "cool" "$(registry_read | jq -r '.agents.s1.authProfile')"
_hb_rotate_at_dispatch_boundary s2 "$REG" true true true; rc=$?
t "hook: second seat in the SAME tick is held by fleet damping" "1" "$rc"
_HB_BALANCE_TICK_MOVED=0
_hb_rotate_at_dispatch_boundary s3 "$REG" true true true; rc=$?
t "hook: balance off on the seat -> near-wall answer stands, no move" "1 1" "$rc $(wc -l <"$CONFIG_CALLS" | tr -d ' ')"

# call-site fence: the dispatch loop hands the three facts, idle needs idle_rc==0
# with no live background shell, and new-task needs a never-started row.
grep -qF '_hb_rotate_at_dispatch_boundary "$name" "$reg" "$eff_fresh" "$_bal_idle" "$_bal_new"' src/cmd_heartbeat.sh
t "fence: the dispatch call passes eff_fresh, idle and new-task" "0" "$?"
grep -qF '(( idle_rc == 0 )) && [[ -z "${_HB_IDLE_BG_SHELLS:-}" ]] && _bal_idle=true' src/cmd_heartbeat.sh
t "fence: idle means idle_rc 0 AND no background shell" "0" "$?"
grep -qF 'first_started_at IS NULL AND started_at IS NULL' src/cmd_heartbeat.sh
t "fence: new-task means the row was never started" "0" "$?"

# --- readings you can trust ----------------------------------------------------
unset -f account_balance_reading
source <(sed -n '/^account_balance_reading() {/,/^}/p' src/cmd_account.sh)
AUTH_PROFILES_DIR="$TMP/profiles"; mkdir -p "$AUTH_PROFILES_DIR/acc"
probe_ok() { printf 'HTTP/2 200 \r\nanthropic-ratelimit-unified-5h-utilization: 0.11\r\nanthropic-ratelimit-unified-7d-utilization: 0.49\r\nanthropic-ratelimit-unified-5h-reset: 1791824400\r\nanthropic-ratelimit-unified-7d-reset: 1792242000\r\n'; }
probe_429() { printf 'HTTP/2 429 \r\nx-other: 1\r\n'; }
_ROTATION_PROBE_CMD=probe_ok
t "live headers: 0.11 / 0.49 parse to 11% / 49% with their resets" "11 49 1792242000" \
  "$(account_live_ratelimits acc | jq -r '"\(.fiveHourPct) \(.sevenDayPct) \(.sevenResetsAt)"')"
_ROTATION_PROBE_CMD=probe_429
t "live headers: a 429 with no headers is no reading (never 0%)" "" "$(account_live_ratelimits acc)"
probe_walled() { printf 'HTTP/2 429 \r\nanthropic-ratelimit-unified-5h-utilization: 1.0\r\nanthropic-ratelimit-unified-7d-utilization: 0.77\r\n'; }
_ROTATION_PROBE_CMD=probe_walled
t "live headers: a walled 429 that carries them is a real 100% reading" "100 77" \
  "$(account_live_ratelimits acc | jq -r '"\(.fiveHourPct) \(.sevenDayPct)"')"

# a seat moved onto `acc` 60s ago still holds a cache from its previous account
account_agents_bound() { printf '["moved"]'; }
usage_read_ratelimits() { jq -cn --argjson a "$((NOW - 300))" '{asOf:$a,fiveHourPct:98,sevenDayPct:98}'; }
account_binding_since() { printf '%s' "$((NOW - 60))"; }
t "trusted reading skips a cache rendered before the seat's binding" "" "$(account_trusted_ratelimits acc)"
account_binding_since() { printf '%s' "$((NOW - 900))"; }
t "a cache rendered after the binding is the account's own" "98" "$(account_trusted_ratelimits acc | jq -r '.sevenDayPct')"
account_binding_since() { printf '%s' "$((NOW - 60))"; }
_ROTATION_PROBE_CMD=probe_ok
t "stale/missing -> refreshed from the live headers" "49" "$(account_balance_reading acc | jq -r '.sevenDayPct')"
t "the probed reading is remembered on the account as source=probe" "probe 49" \
  "$(jq -r '"\(.source) \(.sevenDay.pct)"' "$AUTH_PROFILES_DIR/acc/usage.json")"
_ROTATION_PROBE_CMD=probe_429
t "a fresh remembered probe is reused without another call" "49" "$(account_balance_reading acc | jq -r '.sevenDayPct')"

printf '\nrotation_balance_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
