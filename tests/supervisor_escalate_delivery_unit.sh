#!/usr/bin/env bash
# DIVE-3727 — isolated unit harness for the escalation DELIVERY path in
# cmd_supervisor.sh (_sup_escalate_couriers / _sup_escalate_deliver), the half
# DIVE-3726 measured as missing: poller-dead on `main` was classified correctly,
# audited correctly, and reached nobody.
#
# The property under test is not "a message was sent" — it is WHICH SEAT carries
# it. Both rails are stubbed, so this needs no fleet, no channel state and no
# network; what it grades is the selection, which is where the defect lived.
# Run: bash tests/supervisor_escalate_delivery_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh cmd_supervisor.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

PASS=0; FAIL=0
t() {  # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"
  fi
}

# ── selection: who may carry a report about a sick seat ──────────────────────
cour() { _sup_escalate_couriers "$@" | paste -sd, -; }

t "sick seat is never a courier for itself" \
  "ops,quinn,dev" "$(cour main "main" "main,ops,quinn,dev")"

# ...and the arm above does NOT grade that on its own. quinn, iteration 1: every
# arm that named the sick seat also listed it in the stuck csv, so the STUCK
# exclusion covered for the SICK one and deleting `[[ $n == $sick ]] && continue`
# left the harness fully green — including the two arms named for the property
# this row exists to protect. Both guards were true at once, so neither was
# measured (community/wiki/two-redundant-guards-hide-a-vacuous-arm.md).
# This arm is the discriminator: the sick seat is HEALTHY in the snapshot, so the
# stuck exclusion cannot reach it and only the sick exclusion can drop it.
t "a HEALTHY sick seat is still excluded (only the sick rule can drop it)" \
  "quinn" "$(cour main "ops" "main,ops,quinn")"

# The regression this row exists to prevent. `main` is the org lead and the
# obvious escalation target; when main IS the sick seat it must drop out anyway.
# Same discriminator applied to it: `main` is not in the stuck csv here either.
t "lead drops out when the lead is the sick seat" \
  "ops,quinn" "$(cour main "dev" "ops,main,quinn")"

t "a second stuck seat is never used as the relay" \
  "quinn" "$(cour main "main,ops,dev" "main,ops,quinn,dev")"

# Zero couriers must surface as zero, NOT fall back to the sick seat: that
# fallback is the bug, not a degraded mode.
t "fleet-wide stuck yields no courier rather than the sick seat" \
  "" "$(cour main "main,ops" "main,ops")"

t "duplicate names in the snapshot are not double-tried" \
  "ops,quinn" "$(cour main "main" "ops,ops,main,quinn")"

t "whitespace/empty entries are dropped" \
  "ops" "$(cour main "main" ",main,ops,")"

# ── delivery: rail order, receipt, and the negative control ──────────────────
SENT=""
_task_agent_channel() { return 1; }          # default: no telegram anywhere
cmd_send() { SENT="$SENT a2a:$1"; return 0; }

_SUP_ESC_DELIVER=1
t "falls back to a2a when no telegram channel resolves" \
  "a2a:ops" "$(_sup_escalate_deliver main poller-dead rung-4-needed "main" "main,ops,quinn")"

# Telegram is preferred when it CONFIRMS. Confirmation is TASK_SEND_DELIVERED=1;
# a send that merely ran must not count (that is the silent-failure shape).
_task_agent_channel() { [[ "$1" == "quinn" ]]; }
_task_send_owner() { TASK_SEND_DELIVERED=1; SENT="$SENT tg:quinn"; return 0; }
t "telegram rail wins when it confirms" \
  "telegram:quinn" "$(_sup_escalate_deliver main poller-dead rung-4-needed "main" "main,quinn")"

_task_send_owner() { TASK_SEND_DELIVERED=0; return 0; }   # ran, unconfirmed
t "an UNCONFIRMED telegram send falls through to a2a, it does not count" \
  "a2a:quinn" "$(_sup_escalate_deliver main poller-dead rung-4-needed "main" "main,quinn")"

_task_agent_channel() { return 1; }
cmd_send() { return 1; }
t "couriers existed and every rail failed is distinguishable" \
  "none:all-rails-failed" "$(_sup_escalate_deliver main poller-dead rung-4-needed "main" "main,ops")"

t "no courier at all is a DIFFERENT receipt from all-rails-failed" \
  "none:no-courier" "$(_sup_escalate_deliver main poller-dead rung-4-needed "main,ops" "main,ops")"

# NEGATIVE CONTROL. Two of them, because they answer different questions.
# (a) the knob: with delivery disabled nothing is attempted at all.
SENT=""; cmd_send() { SENT="$SENT a2a:$1"; return 0; }
_SUP_ESC_DELIVER=0
t "knob off: receipt says disabled" \
  "none:disabled" "$(_sup_escalate_deliver main poller-dead rung-4-needed "main" "main,ops")"
t "knob off: nothing was sent" "" "$SENT"
_SUP_ESC_DELIVER=1

# (b) the plan-layer gate above delivery. Kept as CONTEXT for the tick arms
# below, not as the acceptance criterion's negative control — quinn, iteration 1:
# these sit two layers above the send, on different causes, and never touch it.
t "plan layer: a stale CLI is not an escalation" \
  "defer update-pending" "$(_sup_act_plan claude stale-cli 0 0 0 false)"
t "plan layer: drift is not an escalation either" \
  "defer goal-drift" "$(_sup_act_plan claude goal-drift 0 0 0 false)"
# and the positive control for that pair — the instrument CAN show the positive,
# otherwise the two defers above prove nothing.
t "poller-dead DOES reach the escalate verb (positive control)" \
  "escalate rung-4-needed" "$(_sup_act_plan claude poller-dead 0 0 0 false)"

# ── the WIRING, driven not inspected ─────────────────────────────────────────
# quinn, iteration 1: deleting the whole `esc_via=$(_sup_escalate_deliver …)`
# line from cmd_supervisor_tick left this harness AND supervisor_unit green.
# Every arm above tests the delivery functions in isolation, so nothing proved
# the tick CALLS them, that the snapshot extraction feeds them, or that the
# receipt reaches the audit row's signals. A `declare -f` grep would answer
# "is the call present"; it would not answer "does the receipt arrive", so this
# arm RUNS the real cmd_supervisor_tick over a fixture snapshot and a fixture
# tasks DB and reads the row back out of sqlite
# (community/wiki/a-check-that-forces-a-path-to-run-finds-more-than-one-that-inspects-it).
#
# Fresh `bash -c` under the shipped `set -euo pipefail`, not this harness's
# looser -uo: the tick is the function that runs under -e in production, and a
# subshell here also keeps the tick's stubs from leaking into the arms above.
# Root, network, channel state and a real fleet are all stubbed out; what is
# REAL is cmd_supervisor_tick's own body, _sup_escalate_deliver,
# _sup_escalate_couriers, _sup_act_plan, and the sqlite write/read.
tick_arm() {  # <snapshot-json> -> "ESC=<signals-json>|SENT=<csv>"
  SNAP="$1" REPO="$PWD" bash -c '
    set -euo pipefail
    TMP=$(mktemp -d)
    export STATE_DIR="$TMP/state" TASKS_DIR="$TMP/tasks" TASKS_DB="$TMP/tasks/tasks.db"
    mkdir -p "$STATE_DIR" "$TASKS_DIR"
    JSON_MODE=0
    cd "$REPO"
    for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
             lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh cmd_supervisor.sh; do
      . "src/$f"
    done
    _SUP_ENABLED_FLAG="$TMP/enabled"; : >"$_SUP_ENABLED_FLAG"
    require_root()      { :; }                       # the tick is root-only in prod
    _sup_cli_check()    { :; }                        # no network
    _sup_snapshot()     { printf "%s" "$SNAP"; }      # the fixture fleet
    registry_read()     { printf "%s" "{\"agents\":{}}"; }
    _task_agent_channel() { return 1; }               # no telegram anywhere
    : >"$TMP/sent"
    cmd_send() { printf "%s\n" "$1" >>"$TMP/sent"; return 0; }
    cmd_supervisor_tick >/dev/null 2>&1 || { printf "TICK-RC=%s|" "$?"; }
    printf "ESC=%s|SENT=%s" \
      "$(db "SELECT COALESCE(GROUP_CONCAT(signals), \"\") FROM supervisor_events WHERE event=$(sqlq escalate);")" \
      "$(paste -sd, <"$TMP/sent")"
  '   # stderr deliberately NOT swallowed: the arm already fails closed (an abort
      # yields an empty receipt, which reds), but a red with no reason costs the
      # next reader a repro. The tick's own warns are silenced at its call above.
}

_SICK_SNAP='[{"name":"main","type":"claude","classification":"stuck","cause":"poller-dead"},
                 {"name":"ops","type":"claude","classification":"healthy"},
                 {"name":"quinn","type":"claude","classification":"healthy"}]'
_WELL_SNAP='[{"name":"main","type":"claude","classification":"healthy"},
                 {"name":"ops","type":"claude","classification":"healthy"},
                 {"name":"quinn","type":"claude","classification":"healthy"}]'

sick_out=$(tick_arm "$_SICK_SNAP")
sick_esc="${sick_out%%|SENT=*}"; sick_esc="${sick_esc#*ESC=}"
# The receipt reaching signals.delivered is the whole chain in one assertion:
# the tick reached the escalate branch, derived stuck/all from ITS OWN snapshot,
# called the deliverer, and wrote what came back rather than only its intent.
t "tick: the audit row carries the delivery RECEIPT, not just the intent" \
  "a2a:ops" "$(jq -r '.delivered // "NO-RECEIPT"' <<<"$sick_esc" 2>/dev/null || echo NO-ESCALATE-ROW)"
# ...and the courier is a seat that is NOT the sick one. Asserted on the send
# itself, not on the receipt, so a receipt that lies about where it went reds.
t "tick: the escalation was actually handed to a courier" \
  "ops" "${sick_out##*SENT=}"

# THE ACCEPTANCE CRITERION'S negative control, at the layer it names: same tick,
# same arm, every poller alive -> no escalate row and NOTHING sent. Paired with
# the arm above it discriminates "delivery is wired" from "delivery fires always".
well_out=$(tick_arm "$_WELL_SNAP")
well_esc="${well_out%%|SENT=*}"; well_esc="${well_esc#*ESC=}"
t "negative control: a healthy fleet writes no escalate row" "" "$well_esc"
t "negative control: a healthy fleet sends nothing" \
  "" "${well_out##*SENT=}"

# ── the human-facing text ────────────────────────────────────────────────────
txt=$(_sup_escalate_text main poller-dead rung-4-needed quinn)
t "text names the sick seat" "yes" "$([[ "$txt" == *"'main'"* ]] && echo yes || echo no)"
t "text names the courier so it does not read as a misroute" \
  "yes" "$([[ "$txt" == *"'quinn'"* ]] && echo yes || echo no)"
t "text carries the re-check command" \
  "yes" "$([[ "$txt" == *"telegram-discover --agent=main"* ]] && echo yes || echo no)"
# The wiki's trap: the healthy answer arrives as an error. If the text omits that,
# the human re-runs the probe and reads ALIVE as broken.
t "text warns that a 409 means ALIVE" \
  "yes" "$([[ "$txt" == *"409"* ]] && echo yes || echo no)"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
