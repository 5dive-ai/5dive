#!/usr/bin/env bash
# DIVE-5007: `5dive agent _restart_decide <name>` — the self-update ledger's
# restart-or-defer answer, exposed for 5dive-host-updates.sh (5dive-api), which
# restarted every seat mid-turn after a Claude Code upgrade because it carried no
# busy check of its own.
#
# The verb DECIDES and RECORDS; it must never restart. Graded on the shipped
# bytes: the DIVE-3173 block is extracted from src/cmd_selfupdate.sh and run
# against temp dirs with `db`/`sqlq`/`_hb_agent_native_state` stubbed per arm,
# plus a `systemctl` stub that records any call so "never restarts" is measured,
# not assumed.
#
#   KILLS WORK   — a busy / unknown / mid-turn seat answers `restart`.
#   NEVER FIRES  — a deferral with no marker behind it: nothing would bounce it.
#   RESURRECTS   — a parked seat answers `restart`.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

block="$(sed -n '/^# >>> DIVE-3173 deferred restart for a busy agent/,/^# <<< DIVE-3173 deferred restart for a busy agent/p' \
  src/cmd_selfupdate.sh)"
if grep -q '^_restart_decide()' <<<"$block" && grep -q '^cmd_agent_restart_decide()' <<<"$block"; then
  ok_t "_restart_decide lives inside the DIVE-3173 fence (graded with the ledger it reads)"
else
  bad_t "_restart_decide not found inside the DIVE-3173 fence" "the harness would grade nothing"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
if grep -qE '^ +_restart_decide\) cmd_agent_restart_decide "\$@" ;;' src/main.sh; then
  ok_t "'agent _restart_decide' is dispatched to cmd_agent_restart_decide"
else
  bad_t "'agent _restart_decide' is not dispatched" "host-updates would get 'unknown command' and fall back"
fi

WORK="$(mktemp -d)"
export PENDING_RESTART_DIR="$WORK/pending"
SYSCALLS="$WORK/systemctl.calls"
RUNNING='{"agents":{"alice":{"desiredState":"running"}}}'
PARKED='{"agents":{"alice":{"desiredState":"stopped"}}}'
BOARD_IDLE='db(){ echo 0; }; sqlq(){ printf "%s" "$1"; }'
BOARD_BUSY='db(){ echo 2; }; sqlq(){ printf "%s" "$1"; }'
BOARD_DEAD='db(){ return 1; }; sqlq(){ printf "%s" "$1"; }'
NATIVE_IDLE='_hb_agent_native_state(){ printf idle; }'
NATIVE_BUSY='_hb_agent_native_state(){ printf busy; }'

# rdc <registry-json> <board-stubs> <native-stubs> [reason] -> the verb's line
rdc() {
  rm -rf "$PENDING_RESTART_DIR"; : > "$SYSCALLS"
  printf '%s' "$1" > "$WORK/agents.json"
  ( REGISTRY="$WORK/agents.json"
    systemctl(){ echo "systemctl $*" >> "$SYSCALLS"; }
    eval "$2"; eval "$3"; eval "$block"
    _restart_decide alice "${4:-claude code upgraded}" )
}
marker() { [[ -f "$PENDING_RESTART_DIR/alice" ]]; }
reason() { sed -n 's/^reason=//p' "$PENDING_RESTART_DIR/alice" 2>/dev/null; }
no_restart() { [[ ! -s "$SYSCALLS" ]]; }

# 1. idle: restart, and NOTHING owed.
out="$(rdc "$RUNNING" "$BOARD_IDLE" "$NATIVE_IDLE")"
{ [[ "$out" == "restart idle" ]] && ! marker && no_restart; } \
  && ok_t "IDLE seat -> 'restart idle', no marker, and the verb itself restarts nothing" \
  || bad_t "idle seat" "out='$out' marker=$(marker && echo yes || echo no) calls=$(cat "$SYSCALLS")"

# 2. holds an in_progress row: deferred, marker carries the caller's reason.
out="$(rdc "$RUNNING" "$BOARD_BUSY" "$NATIVE_IDLE" "claude code 2.1.283")"
{ [[ "$out" == "deferred busy" ]] && marker && [[ "$(reason)" == "claude code 2.1.283" ]] && no_restart; } \
  && ok_t "BUSY (row) -> 'deferred busy', marker written with the caller's reason, no systemctl" \
  || bad_t "busy seat was not deferred — KILLS WORK" "out='$out' reason='$(reason)' calls=$(cat "$SYSCALLS")"

# 3. no row, but mid-turn (chat-driven — main on 09-25): deferred.
out="$(rdc "$RUNNING" "$BOARD_IDLE" "$NATIVE_BUSY")"
{ [[ "$out" == "deferred busy" ]] && marker && no_restart; } \
  && ok_t "MID-TURN with no row -> 'deferred busy' (the live session signal, not only the board)" \
  || bad_t "a mid-turn seat with no row was restarted — the 09-25 shape" "out='$out'"

# 4. board unreadable: unknown defers.
out="$(rdc "$RUNNING" "$BOARD_DEAD" "$NATIVE_IDLE")"
{ [[ "$out" == "deferred unknown" ]] && marker && no_restart; } \
  && ok_t "UNREADABLE board -> 'deferred unknown' (not knowing is not free)" \
  || bad_t "unknown folded into restart — KILLS WORK" "out='$out'"

# 5. parked: held + marked, even when idle.
out="$(rdc "$PARKED" "$BOARD_IDLE" "$NATIVE_IDLE")"
{ [[ "$out" == "held parked" ]] && marker && [[ "$(reason)" == *"(while parked)" ]] && no_restart; } \
  && ok_t "PARKED (desiredState=stopped) -> 'held parked', marker owed, never restarted" \
  || bad_t "parked seat — RESURRECTS" "out='$out' reason='$(reason)'"

# 6. the marker is the SAME ledger the heartbeat sweep fires from.
out="$(rdc "$RUNNING" "$BOARD_BUSY" "$NATIVE_IDLE")"
verdict="$( ( eval "$block"; _pending_restart_decide "$(_pending_restart_marked_at alice)" 0 idle "$(date +%s)" 0 ) )"
[[ "$verdict" == fire ]] \
  && ok_t "the deferred marker is read by _pending_restart_decide -> 'fire' once the seat is idle (NEVER FIRES is closed)" \
  || bad_t "the marker is not one the sweep would fire" "verdict='$verdict'"

# 7. marker unwritable on a busy seat: restart now, said out loud.
( rm -rf "$PENDING_RESTART_DIR"; : > "$WORK/blocker" )
out="$( PENDING_RESTART_DIR="$WORK/blocker/sub" rdc "$RUNNING" "$BOARD_BUSY" "$NATIVE_IDLE" )"
[[ "$out" == "restart mark-failed" ]] \
  && ok_t "BUSY but marker unwritable -> 'restart mark-failed' (self-update's trade: loud bounce over a forgotten restart)" \
  || bad_t "mark failure" "out='$out'"

# 8. parked and marker unwritable: still held, never a restart.
out="$( PENDING_RESTART_DIR="$WORK/blocker/sub" rdc "$PARKED" "$BOARD_IDLE" "$NATIVE_IDLE" )"
[[ "$out" == "held parked-unmarked" ]] \
  && ok_t "PARKED with marker unwritable -> 'held parked-unmarked', still not a restart" \
  || bad_t "parked + mark failure resurrected the seat" "out='$out'"

# 9. the wrapper refuses a bad name (the caller derives names from unit ids).
out="$( ( eval "$block"; require_root(){ :; }; E_USAGE=2
          valid_name(){ [[ "$1" =~ ^[a-z][a-z0-9-]{0,15}$ ]]; }
          fail(){ echo "FAIL:$2"; exit "$1"; }
          cmd_agent_restart_decide '../etc' ) )"; rc=$?
{ [[ $rc -eq 2 && "$out" == FAIL:* ]]; } \
  && ok_t "wrapper refuses a name that is not an agent name (rc 2)" \
  || bad_t "wrapper accepted a bad name" "rc=$rc out='$out'"

echo; echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
