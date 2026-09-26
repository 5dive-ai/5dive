#!/usr/bin/env bash
# The Telegram poller-dead alarm reaches each dead seat's own human when the
# coordinator has no paired channel, and it promises the supervisor's rung-4
# restart only where the supervisor may act.
#
# THE DEFECT (measured 2026-09-26 on 0.54.0): `_hb_poller_liveness_sweep` sent its
# alarm through `cmd_send "$coord"` and nowhere else. The coordinator is an agent;
# on that box it had no paired channel, so after an update restart left 16 seats
# with no poller the alarm landed in one pane, no person saw it, and the seats
# stayed deaf for 50 minutes. The same alarm said "The supervisor restarts a
# poller-dead seat on its own at rung 4" on a box whose supervisor.actions.enabled
# was absent, i.e. a ladder that records 'planned' rows and restarts nothing.
#
# Arms:
#   A  a coordinator with NO channel: one sendMessage per allowFrom id of each dead
#      seat, through that seat's OWN bot; a healthy seat's human gets nothing
#   B  no coordinator at all: the same per-seat fan-out
#   C  CONTROL: a coordinator WITH a channel keeps today's cmd_send path and sends
#      nothing per seat
#   D  the rung-4 sentence: absent without the actions sentinel, present with it
#   E  the hourly throttle flag still suppresses a second alarm inside the hour
#   L  LIVE BOX: the file the alarm keys on is the one the supervisor reads, and
#      on THIS box's state dir the sentence matches what the supervisor would do;
#      CONTROL: an absent state dir (a clean CI runner) reads as "actions off"
#   M  MUTANT: the pre-fix sweep (cmd_send only, unconditional rung 4) turns A and
#      D red
#
# Stubs: _gate_channel_api (the Bot API seam), cmd_send, _task_resolve_coordinator,
# systemctl, _tg_access_state_dir (points each seat's channel dir into the temp
# tree). No root, no network, no box path written.
#
#   bash tests/poller_alarm_human_fallback_unit.sh
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

TMP="$(mktemp -d /tmp/poller-alarm-fallback.XXXXXX)"

# The live box's state dir, read BEFORE anything below points STATE_DIR at the
# temp tree: header.sh's own default unless the environment already overrides it.
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_agent_pairing.sh cmd_supervisor.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e
LIVE_STATE_DIR="$STATE_DIR"
LIVE_SUP_ACTIONS_FLAG="$_SUP_ACTIONS_FLAG"

STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
REGISTRY="$STATE_DIR/agents.json"; CONNECTORS_DIR="$TMP/connectors"; JSON_MODE=0
mkdir -p "$TASKS_DIR" "$CONNECTORS_DIR"; tasks_db_init >/dev/null 2>&1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { [[ "$1" == *"$2"* ]]; }

# --- The fleet: two dead seats, one healthy one, and the coordinator ---------
# alpha has two paired humans, bravo one; charlie's poller is alive. Each seat's
# bot token is distinct so the harness can see WHOSE bot carried each message.
NOW=$(date +%s)
seat() { # <name> <allowFrom json array> <beacon: fresh|none>
  local d="$TMP/home/agent-$1/.claude/channels/telegram"
  mkdir -p "$d"
  printf '{"dmPolicy":"allowlist","allowFrom":%s}\n' "$2" > "$d/access.json"
  printf 'TELEGRAM_BOT_TOKEN=tok-%s\n' "$1" > "$CONNECTORS_DIR/telegram-$1.env"
  [[ "$3" == fresh ]] && : > "$d/bot.heartbeat"
}
seat alpha   '["111","112"]' none
seat bravo   '[221]'         none
seat charlie '["331"]'       fresh
printf '{"agents":{"alpha":{"type":"claude"},"bravo":{"type":"claude"},"charlie":{"type":"claude"}}}\n' > "$REGISTRY"

_tg_access_state_dir() { printf '%s/home/%s/.%s/channels/telegram' "$TMP" "$1" "$2"; }
# Every seat's unit has been active since long before the tick: no restart grace.
systemctl() { case "$1" in is-active) return 0 ;; show) printf 'Thu 2026-01-01 00:00:00 UTC\n' ;; esac; }
COORD=""
_task_resolve_coordinator() { printf '%s' "$COORD"; }
_gate_channel_api() { # <token> <method> [curl args...] -> one line: token|method|chat|text
  local tok="$1" m="$2" chat="" text=""; shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d) [[ "$2" == chat_id=* ]] && chat="${2#chat_id=}"; shift ;;
      --data-urlencode) [[ "$2" == text=* ]] && text="${2#text=}"; shift ;;
    esac
    shift
  done
  printf '%s|%s|%s|%s\n' "$tok" "$m" "$chat" "$text" >> "$TMP/api.log"
}
cmd_send() { printf '%s|%s\n' "$1" "${2#--message=}" >> "$TMP/send.log"; }
_hb_log() { printf '%s\n' "$*" >> "$TMP/hb.log"; }

# One tick, from a clean slate unless told to keep the throttle flag.
tick() { # [keep-flag]
  [[ "${1:-}" == keep-flag ]] || rm -f "$STATE_DIR/poller-liveness.alarmed"
  : > "$TMP/api.log"; : > "$TMP/send.log"; : > "$TMP/hb.log"
  _hb_poller_liveness_sweep
}
coord_with_channel() { mkdir -p "$TMP/home/agent-coord/.claude/channels/telegram"
  printf '{"allowFrom":["999"]}\n' > "$TMP/home/agent-coord/.claude/channels/telegram/access.json"
  printf 'TELEGRAM_BOT_TOKEN=tok-coord\n' > "$CONNECTORS_DIR/telegram-coord.env"; }
coord_without_channel() { rm -rf "$TMP/home/agent-coord" "$CONNECTORS_DIR/telegram-coord.env"; }
api_lines() { grep -c . "$TMP/api.log"; }
sorted_sends() { cut -d'|' -f1-3 "$TMP/api.log" | sort | paste -sd' ' -; }
EXPECT_SENDS='tok-alpha|sendMessage|111 tok-alpha|sendMessage|112 tok-bravo|sendMessage|221'

# --- P) preconditions: the fixture really is two dead seats and one alive -----
COORD=coord; coord_with_channel; tick
has "$(cat "$TMP/hb.log")" "DEAD: alpha: no beacon" && has "$(cat "$TMP/hb.log")" "bravo: no beacon" \
  && ! has "$(cat "$TMP/hb.log")" "charlie" \
  && ok_t "P1: the sweep sees alpha and bravo dead and charlie alive" \
  || bad_t "P1: alpha+bravo dead, charlie alive" "hb.log: $(cat "$TMP/hb.log")"

# --- A) coordinator present but unpaired: each dead seat's own humans ---------
COORD=coord; coord_without_channel; tick
[[ "$(sorted_sends)" == "$EXPECT_SENDS" ]] \
  && ok_t "A1: one sendMessage per allowFrom id of each dead seat, through the seat's own bot" \
  || bad_t "A1: per-seat sendMessage fan-out" "got: [$(sorted_sends)] want: [$EXPECT_SENDS]"
! grep -q '|331|' "$TMP/api.log" \
  && ok_t "A2: the healthy seat's human is not messaged" \
  || bad_t "A2: charlie's human must get nothing" "$(cat "$TMP/api.log")"
T_ALPHA=$(awk -F'|' '$3=="111"{print $4}' "$TMP/api.log")
[[ "$T_ALPHA" == "alpha cannot receive your Telegram messages right now (its poller is not running). Fix: sudo 5dive agent restart alpha" ]] \
  && ok_t "A3: the text names the seat and the one command that fixes it" \
  || bad_t "A3: per-seat alarm text" "got: $T_ALPHA"
has "$(cat "$TMP/hb.log")" "coordinator coord has no paired channel" \
  && ok_t "A4: the tick log says why the alarm went per seat" \
  || bad_t "A4: fallback logged" "$(cat "$TMP/hb.log")"
[[ "$(cut -d'|' -f1 "$TMP/send.log")" == coord ]] \
  && ok_t "A5: the coordinator's pane still gets the full alarm (unchanged)" \
  || bad_t "A5: cmd_send to the unpaired coordinator unchanged" "send.log: $(cat "$TMP/send.log")"

# --- B) no coordinator resolved at all ------------------------------------------
COORD=""; tick
[[ "$(sorted_sends)" == "$EXPECT_SENDS" ]] \
  && ok_t "B1: with no coordinator the same per-seat fan-out goes out" \
  || bad_t "B1: per-seat fan-out with no coordinator" "got: [$(sorted_sends)]"
[[ ! -s "$TMP/send.log" ]] \
  && ok_t "B2: ...and there is no agent to cmd_send to" \
  || bad_t "B2: no cmd_send without a coordinator" "$(cat "$TMP/send.log")"

# --- C) CONTROL: a coordinator with a channel keeps today's path ---------------
COORD=coord; coord_with_channel; tick
[[ "$(api_lines)" == 0 ]] \
  && ok_t "C1: CONTROL: a paired coordinator means no per-seat sendMessage" \
  || bad_t "C1: no per-seat send when the coordinator is paired" "$(cat "$TMP/api.log")"
[[ "$(grep -c '^coord|' "$TMP/send.log")" == 1 ]] && has "$(cat "$TMP/send.log")" "Telegram poller DEAD on: alpha" \
  && ok_t "C2: CONTROL: the coordinator gets the alarm through cmd_send, once" \
  || bad_t "C2: cmd_send to the paired coordinator" "$(cat "$TMP/send.log")"

# --- D) the rung-4 sentence follows the supervisor's actions sentinel ----------
rm -f "$STATE_DIR/supervisor.actions.enabled"; tick
! has "$(cat "$TMP/send.log")" "at rung 4" && has "$(cat "$TMP/send.log")" "the supervisor's actions are off" \
  && ok_t "D1: without supervisor.actions.enabled the alarm promises no rung-4 restart" \
  || bad_t "D1: rung 4 absent without the actions flag" "$(cat "$TMP/send.log")"
: > "$STATE_DIR/supervisor.actions.enabled"; tick
has "$(cat "$TMP/send.log")" "The supervisor restarts a poller-dead seat on its own at rung 4" \
  && ok_t "D2: with the sentinel present the rung-4 sentence is there" \
  || bad_t "D2: rung 4 present with the actions flag" "$(cat "$TMP/send.log")"
rm -f "$STATE_DIR/supervisor.actions.enabled"

# --- E) the hourly throttle still holds ------------------------------------------
COORD=coord; coord_without_channel; tick
tick keep-flag
[[ "$(api_lines)" == 0 && ! -s "$TMP/send.log" ]] \
  && ok_t "E1: a second tick inside the hour sends nothing (throttle flag kept)" \
  || bad_t "E1: throttle suppresses the repeat" "api: $(cat "$TMP/api.log") send: $(cat "$TMP/send.log")"
has "$(cat "$TMP/hb.log")" "[poller-liveness] DEAD:" \
  && ok_t "E2: ...while the tick log still records the dead seats" \
  || bad_t "E2: throttled tick still logs" "$(cat "$TMP/hb.log")"

# --- L) LIVE BOX: the sentinel the alarm reads is the one the supervisor reads -
# The fix keys on a box fact (a file's presence), so this reads it off the box the
# harness runs on rather than off a fixture: the supervisor's own constant, taken
# with header.sh's state dir before this harness moved it. Read-only. On a clean
# runner the directory is absent and both sides say "off"; on an installed box
# they must agree with whatever is really there.
[[ "$LIVE_SUP_ACTIONS_FLAG" == "${LIVE_STATE_DIR}/supervisor.actions.enabled" ]] \
  && ok_t "L1: the supervisor reads its actions sentinel at <state dir>/supervisor.actions.enabled, the path the alarm keys on" \
  || bad_t "L1: alarm and supervisor read the same sentinel" "supervisor: $LIVE_SUP_ACTIONS_FLAG; alarm: ${LIVE_STATE_DIR}/supervisor.actions.enabled"
LIVE_SENT=$(STATE_DIR="$LIVE_STATE_DIR" _hb_poller_rung4_sentence)
if [[ -f "$LIVE_SUP_ACTIONS_FLAG" ]]; then LIVE_STATE=present; else LIVE_STATE=absent; fi
if [[ "$LIVE_STATE" == present ]]; then has "$LIVE_SENT" "at rung 4"; else ! has "$LIVE_SENT" "at rung 4"; fi \
  && ok_t "L2: on this box ($LIVE_SUP_ACTIONS_FLAG $LIVE_STATE) the alarm's rung-4 sentence matches what the supervisor would do" \
  || bad_t "L2: live sentinel $LIVE_STATE, sentence disagrees" "$LIVE_SENT"

# L3: the pristine-runner shape, whatever box this runs on: a state dir that does
# not exist (CI has no /var/lib/5dive) reads as "actions off", and nothing errors.
PRISTINE="$TMP/no-such-state-dir"
[[ ! -e "$PRISTINE" ]] && ! has "$(STATE_DIR="$PRISTINE" _hb_poller_rung4_sentence)" "at rung 4" \
  && has "$(STATE_DIR="$PRISTINE" _hb_poller_rung4_sentence)" "the supervisor's actions are off" \
  && ok_t "L3: CONTROL: with no state dir at all (a clean runner) the alarm says the supervisor will not restart it" \
  || bad_t "L3: absent state dir reads as actions off" "$(STATE_DIR="$PRISTINE" _hb_poller_rung4_sentence)"

# --- M) MUTANT: the pre-fix sweep --------------------------------------------------
# Re-introduce the defect in-process: cmd_send to the coordinator only, rung 4
# promised unconditionally. A and D must go red on it, or they grade nothing.
eval "$(awk '/^_hb_poller_liveness_sweep\(\) \{/,/^\}/' "$SRC/cmd_heartbeat.sh" \
  | sed -e 's/^  if \[\[ -z "\$coord" \]\] || ! _task_agent_channel "\$coord"; then$/  if false; then/' \
        -e 's/^  local rung4; rung4=\$(_hb_poller_rung4_sentence)$/  local rung4="The supervisor restarts a poller-dead seat on its own at rung 4."/')"
MUT_DEF=$(declare -f _hb_poller_liveness_sweep)
has "$MUT_DEF" "if false; then" && has "$MUT_DEF" 'rung4="The supervisor restarts' \
  && ok_t "M0: (anchor) both mutations landed in the evaluated sweep" \
  || bad_t "M0: mutation anchors" "the sed patterns no longer match src/cmd_heartbeat.sh"
COORD=coord; coord_without_channel; tick
[[ "$(sorted_sends)" != "$EXPECT_SENDS" ]] \
  && ok_t "M1: MUTANT (coordinator only): A1's per-seat fan-out is gone — A goes red" \
  || bad_t "M1: mutant must break the per-seat fan-out" "still sent: $(sorted_sends)"
COORD=coord; coord_with_channel; rm -f "$STATE_DIR/supervisor.actions.enabled"; tick
has "$(cat "$TMP/send.log")" "at rung 4" \
  && ok_t "M2: MUTANT (unconditional rung 4): D1's absence goes red" \
  || bad_t "M2: mutant must promise rung 4 without the flag" "$(cat "$TMP/send.log")"

echo "-----"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
