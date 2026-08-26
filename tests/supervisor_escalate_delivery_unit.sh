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

# The regression this row exists to prevent. `main` is the org lead and the
# obvious escalation target; when main IS the sick seat it must drop out anyway.
t "lead drops out when the lead is the sick seat" \
  "ops,quinn" "$(cour main "main" "ops,main,quinn")"

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

# (b) the real negative control the acceptance asks for: with EVERY poller alive
# nothing is classified stuck, so _sup_act_plan never reaches the escalate verb
# and no delivery is possible. Asserted at the plan, which is the gate above it.
t "healthy fleet: nothing to escalate (plan defers, no escalate verb)" \
  "defer update-pending" "$(_sup_act_plan claude stale-cli 0 0 0 false)"
t "healthy fleet: drift is not an escalation either" \
  "defer goal-drift" "$(_sup_act_plan claude goal-drift 0 0 0 false)"
# and the positive control for that pair — the instrument CAN show the positive,
# otherwise the two defers above prove nothing.
t "poller-dead DOES reach the escalate verb (positive control)" \
  "escalate rung-4-needed" "$(_sup_act_plan claude poller-dead 0 0 0 false)"

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
