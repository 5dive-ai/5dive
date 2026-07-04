#!/usr/bin/env bash
# DIVE-857 isolated unit harness for the supervisor P2 act layer.
#
# Same isolation contract as loop_*_unit.sh: sources src/ libs directly and
# points STATE_DIR at a throwaway temp dir so it NEVER touches the live shared
# tasks.db. Asserts: _sup_act_plan's full decision matrix (cause map, runtime
# guard, ladder order, backoff math, exhaustion, rotation gate) and
# _sup_act_history counting action rows from a seeded audit trail.
# Run: bash tests/supervisor_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/supervisor-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
# Source the supervisor AFTER STATE_DIR is final so its flag paths land in TMP.
# shellcheck source=/dev/null
source "$SRC/cmd_supervisor.sh"
tasks_db_init

PASS=0; FAIL=0
t() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"
  fi
}

NOW=1000000

# --- decision matrix: cause map -------------------------------------------
t "service-dead escalates (rung 4 is P3)" \
  "escalate rung-4-needed" "$(_sup_act_plan claude service-dead 0 0 $NOW false)"
t "tmux-dead escalates" \
  "escalate rung-4-needed" "$(_sup_act_plan claude tmux-dead 0 0 $NOW true)"
# DIVE-974: stale-cli is update-pending (not stuck) so it never reaches the act
# loop; the plan guards it too, so no rung — not even escalate — can ever fire.
t "stale-cli defers (update-pending, never a ladder action)" \
  "defer update-pending" "$(_sup_act_plan claude stale-cli 1 0 $NOW true)"

# --- runtime guard ----------------------------------------------------------
t "non-claude runtime escalates even on actionable cause" \
  "escalate non-claude-runtime" "$(_sup_act_plan codex no-progress 0 0 $NOW false)"

# --- ladder order -----------------------------------------------------------
t "attempt 0 -> nudge"  "nudge"  "$(_sup_act_plan claude no-progress 0 0 $NOW false)"
t "attempt 1 -> resume" "resume" "$(_sup_act_plan claude loop-stuck 1 0 $NOW false)"
t "attempt 2 + rotation on -> rotate" \
  "rotate" "$(_sup_act_plan claude no-progress 2 0 $NOW true)"
t "attempt 2 + rotation off -> escalate" \
  "escalate rotation-disabled" "$(_sup_act_plan claude no-progress 2 0 $NOW false)"
t "attempts >= max -> escalate exhausted" \
  "escalate ladder-exhausted" "$(_sup_act_plan claude no-progress 3 0 $NOW true)"

# --- backoff math: gap = base * 2^attempts ---------------------------------
# base 20m: attempt 1 needs 40m since last action.
LAST=$(( NOW - 30 * 60 ))   # 30m ago < 40m gap
t "attempt 1 inside 40m backoff -> defer" \
  "defer backoff" "$(_sup_act_plan claude no-progress 1 $LAST $NOW false)"
LAST=$(( NOW - 41 * 60 ))   # 41m ago > 40m gap
t "attempt 1 past 40m backoff -> resume" \
  "resume" "$(_sup_act_plan claude no-progress 1 $LAST $NOW false)"
LAST=$(( NOW - 21 * 60 ))   # attempt 0 gap is 20m; also no last action means no gap
t "attempt 0 past 20m backoff -> nudge" \
  "nudge" "$(_sup_act_plan claude no-progress 0 $LAST $NOW false)"
t "no prior action -> no backoff gate" \
  "nudge" "$(_sup_act_plan claude no-progress 0 0 $NOW false)"

# --- _sup_act_history: counts only 'action' rows inside the window ---------
db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
    VALUES ('unit-a', 'action', 'stuck', 'no-progress', '{\"rung\":\"nudge\"}');"
db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
    VALUES ('unit-a', 'planned', 'stuck', 'no-progress', '{\"rung\":\"resume\"}');"
db "INSERT INTO supervisor_events (agent, event, classification, cause)
    VALUES ('unit-a', 'observe', 'stuck', 'no-progress');"
db "INSERT INTO supervisor_events (agent, event, classification, cause, signals, ts)
    VALUES ('unit-a', 'action', 'stuck', 'no-progress', '{\"rung\":\"resume\"}', datetime('now', '-9 hours'));"
db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
    VALUES ('unit-b', 'action', 'stuck', 'loop-stuck', '{\"rung\":\"nudge\"}');"
read -r ATT LASTE <<<"$(_sup_act_history unit-a)"
t "history counts in-window action rows only (not planned/observe/old/other-agent)" "1" "$ATT"
[[ "$LASTE" =~ ^[0-9]+$ ]] && (( LASTE > 0 )) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: history lastEpoch not a positive epoch: '$LASTE'"; }
read -r ATT _ <<<"$(_sup_act_history unit-none)"
t "history for unseen agent is zero" "0" "$ATT"

echo
echo "supervisor_unit: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
