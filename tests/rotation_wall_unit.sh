#!/usr/bin/env bash
# DIVE-6121: a seat that hits its account's usage limit moves to an account in
# its pool with measured headroom, on its OWN trigger (its telegram plugin's
# StopFailure hook), including a standard seat whose grant never held
# `agent rotation rotate`. Arms, by the row's numbers:
#   1  wall + a measured-headroom account in the pool -> the seat moves, and the
#      walled account is parked until its reset (the NEGATIVE CONTROL arm: run
#      with WALL_MUTANT=1 and the `--wall` trigger is cut out of the verb; this
#      arm must go red)
#   1s a standard seat reaches that move for ITSELF through _self_account, and
#      for no other seat
#   3  no headroom anywhere -> no move, the seat stays put and waits
#   4  a second wall inside the chain window does not chain
#   5  the boundary forms (--if-current-near-wall, plain rotate) are unchanged
# Arm 2 (the message that hit the wall is answered) lives in the plugin: its
# StopFailure hook arms the resume marker before calling this verb.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
TMP=$(mktemp -d /tmp/rotation-wall.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

source src/lib/error_codes.sh
source src/lib/output.sh
source src/header.sh
if [[ "${WALL_MUTANT:-0}" == 1 ]]; then
  # The mutation: the verb no longer knows the wall trigger.
  source <(sed '/--wall=\*) wall=1;/d' src/cmd_account.sh)
  echo "MUTANT: --wall trigger removed from cmd_agent_rotation_rotate"
else
  source src/cmd_account.sh
fi
set +e

PASS=0; FAIL=0
t() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; else
    FAIL=$((FAIL+1)); printf 'FAIL %s — expected %s, got %s\n' "$1" "$2" "$3" >&2
  fi
}

# Boundaries this harness does not own: root, the state dir, the registry FILE
# (real reads and writes, so a park or a stamp persists between calls), and
# cmd_config, whose job here is to re-point the binding and schedule the bounce.
REG="$TMP/agents.json"
require_root()   { :; }
ensure_state()   { :; }
registry_read()  { cat "$REG"; }
registry_write() { cat >"$REG.tmp" && mv "$REG.tmp" "$REG"; }
cmd_config() {   # <name> set auth-profile=<target>
  local n="$1" v="${3#auth-profile=}"
  registry_read | jq --arg n "$n" --arg v "$v" '.agents[$n].authProfile = $v' | registry_write
}
with_registry_lock() { local fn="$1"; shift; "$fn" "$@"; }
# Headroom is measured by another live seat's statusline; the fixture names the
# accounts that measure under the threshold right now.
HEADROOM=""
account_has_live_headroom() { [[ " $HEADROOM " == *" $1 "* ]]; }
account_near_wall_state() { printf '%s' "${SOURCE_STATE:-unmeasured}"; }

NOW=$(date +%s); RESET=$((NOW + 6420))   # the 03:00Z reset, 1h47m out
# chatseat's shape on 2026-10-13: rotation on, every account in the pool, on mp.
seed() {  # [enabled] [lastWallRotateAt]
  jq -cn --argjson en "${1:-true}" --argjson lw "${2:-0}" '{agents:{chatseat:{
      type:"claude", channels:"telegram", authProfile:"mp",
      rotation:({enabled:$en, accounts:["mp","mark","weekly","mp-team"], cooldowns:{}}
                + (if $lw > 0 then {lastWallRotateAt:$lw} else {} end))}}}' >"$REG"
}
wall() ( JSON_MODE=1 cmd_agent_rotation_rotate chatseat "--wall=$RESET" 2>/dev/null )
bound() { jq -r '.agents.chatseat.authProfile' "$REG"; }
cool()  { jq -r --arg a "$1" '.agents.chatseat.rotation.cooldowns[$a] // "none"' "$REG"; }
J() { jq -r "$2" <<<"$1" 2>/dev/null; }

# ── 1: the wall moves the seat to the account with headroom ──────────────────
# mark (100% 5h) and weekly (97% 7d) are earlier in the pool but measure
# no headroom; mp-team (4%/1%) does.
seed; HEADROOM="mp-team"
OUT=$(wall)
t "1 wall with a headroom account in the pool rotates" "true" "$(J "$OUT" '.data.rotated')"
t "1 lands on the measured-headroom account, skipping walled ones ahead of it" "mp-team" "$(bound)"
t "1 parks the walled account until its reset" "$RESET" "$(cool mp)"
t "1 the envelope names the wall trigger" "true" "$(J "$OUT" '.data.wall')"
t "1 the move is stamped for the chain guard" "true" \
  "$(jq -r --argjson n "$NOW" '(.agents.chatseat.rotation.lastWallRotateAt // 0) >= $n' "$REG")"

# ── 3: no headroom anywhere: no move, the seat waits for its reset ──────────
seed; HEADROOM=""
OUT=$(wall)
t "3 no measured headroom: no rotation" "false" "$(J "$OUT" '.data.rotated')"
t "3 no measured headroom: the seat stays on its account" "mp" "$(bound)"
t "3 no measured headroom: the walled account is still parked" "$RESET" "$(cool mp)"
t "3 no measured headroom: nothing stamped" "null" "$(jq -r '.agents.chatseat.rotation.lastWallRotateAt' "$REG")"
# A merely-unparked account is not headroom: mark is not cooling, but walled.
t "3 an uncooled but unmeasured account is never the target" "true" "$(J "$OUT" '.data.to == null')"

# ── 4: never a chain ────────────────────────────────────────────────────────
# The seat moved 10 minutes ago and has walled again: the destination was not
# what it measured. Even with headroom on offer, it waits.
seed true $((NOW - 600)); HEADROOM="mp-team weekly"
OUT=$(wall)
t "4 a second wall inside the window does not rotate" "false" "$(J "$OUT" '.data.rotated')"
t "4 the refusal says why" "true" "$(J "$OUT" '.data.chainGuard')"
t "4 the binding is untouched" "mp" "$(bound)"
t "4 the walled account is still parked" "$RESET" "$(cool mp)"
# ...and the guard expires: a wall after the window moves again.
seed true $((NOW - ROTATION_WALL_CHAIN_SECS - 5)); HEADROOM="mp-team"
OUT=$(wall)
t "4 a wall after the window moves again" "mp-team" "$(bound)"
# Two walls in a row through the verb: the second does not chain.
seed; HEADROOM="mark mp-team"
wall >/dev/null; FIRST=$(bound)
HEADROOM="mp-team"; OUT=$(wall)
t "4 back-to-back walls: the first moves" "mark" "$FIRST"
t "4 back-to-back walls: the second stays on the account it landed on" "mark" "$(bound)"

# ── refusals ────────────────────────────────────────────────────────────────
seed false; HEADROOM="mp-team"
( wall ) >/dev/null 2>&1; rc=$?
t "rotation off: refused, binding untouched" "nonzero:mp" "$( ((rc)) && echo nonzero || echo zero ):$(bound)"
seed; ( JSON_MODE=1 cmd_agent_rotation_rotate chatseat --wall=soon ) >/dev/null 2>&1; rc=$?
t "a non-epoch reset is refused" "nonzero:mp" "$( ((rc)) && echo nonzero || echo zero ):$(bound)"
seed; ( JSON_MODE=1 cmd_agent_rotation_rotate chatseat "--wall=$RESET" --if-current-near-wall ) >/dev/null 2>&1; rc=$?
t "--wall and the boundary trigger are not combined" "nonzero" "$( ((rc)) && echo nonzero || echo zero )"

# ── 5: the boundary forms are unchanged ─────────────────────────────────────
seed; HEADROOM="mp-team"; SOURCE_STATE=clear
OUT=$(JSON_MODE=1 cmd_agent_rotation_rotate chatseat --if-current-near-wall --require-live-headroom)
t "5 boundary: a clear account still does not rotate" "false:mp" "$(J "$OUT" '.data.rotated'):$(bound)"
SOURCE_STATE=near
OUT=$(JSON_MODE=1 cmd_agent_rotation_rotate chatseat --if-current-near-wall --require-live-headroom)
t "5 boundary: a near-wall account still rotates" "true:mp-team" "$(J "$OUT" '.data.rotated'):$(bound)"
t "5 boundary: a boundary move does not stamp the wall guard" "null" "$(jq -r '.agents.chatseat.rotation.lastWallRotateAt' "$REG")"
# ...and a boundary move inside a wall chain window is not blocked by it.
seed true $((NOW - 60)); SOURCE_STATE=near
OUT=$(JSON_MODE=1 cmd_agent_rotation_rotate chatseat --if-current-near-wall --require-live-headroom)
t "5 boundary: the wall chain guard does not hold a boundary move" "true" "$(J "$OUT" '.data.rotated')"
seed; HEADROOM=""
OUT=$(JSON_MODE=1 cmd_agent_rotation_rotate chatseat)
t "5 plain rotate keeps its preference-order pick" "true:mark" "$(J "$OUT" '.data.rotated'):$(bound)"

# ── 1s: a standard seat runs the wall move on ITSELF, and only on itself ─────
CALLS="$TMP/calls"; WIRE="$TMP/wire"; SUDOS="$TMP/sudos"
_gate_uid_to_agent() { [[ "$1" == 1010 ]] && printf 'chatseat' || printf ''; }
# root half: the executor re-derives the seat from SUDO_UID
cmd_agent_rotation_rotate() { printf 'rotate %s\n' "$*" >>"$CALLS"; }
_gate_is_root() { return 0; }
run_root() { local uid="$1"; shift; : >"$CALLS"
  ( export SUDO_UID="$uid"; printf '%s\0' "$@" | cmd_self_account_delegated ) >/dev/null 2>&1; }
run_root 1010 json rotate "$RESET"; rc=$?
t "1s the rail rotates the CALLER seat with --wall" "0:rotate chatseat --wall=$RESET" "$rc:$(cat "$CALLS")"
neg() { local label="$1"; shift; run_root "$@"; local r=$?
  t "1s refused: $label" "nonzero:" "$( ((r)) && echo nonzero || echo zero ):$(cat "$CALLS")"; }
neg 'a second value cannot name another seat'  1010 json rotate "$RESET" quinn
neg 'a reset that is not an epoch'             1010 json rotate soon
neg 'rotate with no reset'                     1010 json rotate
neg 'a flag smuggled as the reset'             1010 json rotate --require-live-headroom
neg 'a uid that is not a seat'                 1000 json rotate "$RESET"

# caller half: `agent rotation rotate <self> --wall=E` crosses, nothing else does
GRANTED=1
sudo() {
  printf '%s\n' "$*" >>"$SUDOS"
  if [[ "$2" == "-l" ]]; then [[ "$GRANTED" == 1 && "$3" == /usr/local/bin/5dive && "$4" == _self_account && $# == 4 ]]; return; fi
  python3 -c 'import sys; print(sys.stdin.buffer.read().decode().replace("\0","|"))' >"$WIRE"
  printf '{"ok":true}\n'
}
_gate_is_root() { return 1; }
_gate_caller_uid() { printf 1010; }
disp() { : >"$CALLS"; : >"$WIRE"; : >"$SUDOS"; ( JSON_MODE=1; agent_rotation_rotate_dispatch "$@" ) >/dev/null 2>&1; }
disp chatseat "--wall=$RESET"
t "1s self wall move crosses the rail with json|rotate|<reset>" "json|rotate|$RESET|" "$(cat "$WIRE")"
t "1s ...as the exact granted argv" "yes" "$(grep -qx -- '-n /usr/local/bin/5dive _self_account' "$SUDOS" && echo yes || echo no)"
t "1s ...and never also runs the root path" "" "$(cat "$CALLS")"
disp quinn "--wall=$RESET"
t "1s another seat stays on the root path" "rotate quinn --wall=$RESET:" "$(cat "$CALLS"):$(cat "$WIRE")"
disp chatseat --cooldown-current="$RESET"
t "1s a self rotate that is not a wall move stays on the root path" "rotate chatseat --cooldown-current=$RESET:" "$(cat "$CALLS"):$(cat "$WIRE")"
disp chatseat "--wall=$RESET" --require-live-headroom
t "1s extra flags keep a self wall move on the root path" "rotate chatseat --wall=$RESET --require-live-headroom:" "$(cat "$CALLS"):$(cat "$WIRE")"
GRANTED=0; disp chatseat "--wall=$RESET"
t "1s an ungranted seat keeps today's path" "rotate chatseat --wall=$RESET:" "$(cat "$CALLS"):$(cat "$WIRE")"

grep -q 'agent_rotation_rotate_dispatch "\$@"' <<<"$(grep -A3 '^            rotate)' src/main.sh)" \
  && t "1s main.sh routes rotation rotate through the dispatch" y y \
  || t "1s main.sh routes rotation rotate through the dispatch" y n

echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
