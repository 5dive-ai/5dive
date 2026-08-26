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
#
# DIVE-3753 gave poller-dead a rung-4 RESTART, so the verb it reaches now depends
# on whether the ladder is armed. Both of its escalating states are controlled
# here, because both are what the tick arm below actually drives:
#   - dormant ($_SUP_ACTIONS_FLAG absent, which is this harness's tick fixture) —
#     the pre-3753 human path is kept verbatim rather than downgraded to a silent
#     'planned' row;
#   - armed but rate-limited — the seat a restart did not fix, which is precisely
#     the one that must reach a person.
t "poller-dead reaches escalate when the ladder is DORMANT (positive control)" \
  "escalate rung-4-dormant" "$(_sup_act_plan claude poller-dead 0 0 0 false 0 false)"
t "poller-dead reaches escalate when the restart budget is SPENT" \
  "escalate restart-rate-limited" "$(_sup_act_plan claude poller-dead 0 0 0 false 1 true)"
# ...and the negative of that pair: armed with budget free, it acts instead of
# paging. Without this, the two arms above are equally satisfied by an
# escalate-always plan layer, which is the shape DIVE-3753 exists to remove.
t "armed + budget free -> the rung acts, it does not page a human" \
  "restart" "$(_sup_act_plan claude poller-dead 0 0 0 false 0 true)"

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
# DIVE-3753 extends it with two optional inputs and two extra output fields, so
# the SAME real-tick arm covers the new rung: ARMED touches the actions flag (the
# tick then EXECUTES rungs instead of recording 'planned'), and SEED is SQL run
# against the fixture DB before the tick, which is how a spent restart budget is
# staged. `cmd_restart` is stubbed to record the seat and nothing else — this
# harness must never touch a real unit, and what is under test is that the tick
# ROUTES to it, not what systemd does next.
tick_arm() {  # <snapshot-json> [armed] [seed-sql] -> "ESC=<json>|SENT=<csv>|ACT=<json>|RESTARTED=<csv>"
  SNAP="$1" ARMED="${2:-}" SEED="${3:-}" REPO="$PWD" bash -c '
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
    # `if`, not `[[ … ]] && …`: this subshell runs under the shipped `set -e`, so
    # a false one-liner IS an exit — and it exits before a single arm runs, which
    # reads as an empty result rather than as an error.
    _SUP_ACTIONS_FLAG="$TMP/actions"
    if [[ -n "$ARMED" ]]; then : >"$_SUP_ACTIONS_FLAG"; fi
    require_root()      { :; }                       # the tick is root-only in prod
    _sup_cli_check()    { :; }                        # no network
    _sup_snapshot()     { printf "%s" "$SNAP"; }      # the fixture fleet
    registry_read()     { printf "%s" "{\"agents\":{}}"; }
    _task_agent_channel() { return 1; }               # no telegram anywhere
    : >"$TMP/sent"; : >"$TMP/restarted"
    cmd_send() { printf "%s\n" "$1" >>"$TMP/sent"; return 0; }
    cmd_restart() { printf "%s\n" "$1" >>"$TMP/restarted"; return 0; }
    # The seed writes BEFORE the tick, so it has to create the schema itself —
    # nothing else has touched this fixture DB yet. Both calls are subshelled:
    # `db` reaches `fail`, and `fail` EXITS, which `|| true` cannot catch.
    if [[ -n "$SEED" ]]; then
      ( tasks_db_init ) >/dev/null 2>&1 || true
      ( db "$SEED" )    >/dev/null 2>&1 || true
    fi
    cmd_supervisor_tick >/dev/null 2>&1 || { printf "TICK-RC=%s|" "$?"; }
    printf "ESC=%s|SENT=%s|ACT=%s|RESTARTED=%s" \
      "$(db "SELECT COALESCE(GROUP_CONCAT(signals), \"\") FROM supervisor_events WHERE event=$(sqlq escalate);")" \
      "$(paste -sd, <"$TMP/sent")" \
      "$(db "SELECT COALESCE(GROUP_CONCAT(signals), \"\") FROM supervisor_events WHERE event=$(sqlq action);")" \
      "$(paste -sd, <"$TMP/restarted")"
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

# One field out of the arm's "K=v|K=v|..." line. The old inline ${x##*SENT=} broke
# the moment a field was appended after SENT — a silently-wrong extraction that
# would have read as a passing assertion, so it is a function now.
fld() { # <out> <key>
  local rest="${1#*"$2"=}"
  printf '%s' "${rest%%|*}"
}

sick_out=$(tick_arm "$_SICK_SNAP")
sick_esc="$(fld "$sick_out" ESC)"
# The receipt reaching signals.delivered is the whole chain in one assertion:
# the tick reached the escalate branch, derived stuck/all from ITS OWN snapshot,
# called the deliverer, and wrote what came back rather than only its intent.
t "tick: the audit row carries the delivery RECEIPT, not just the intent" \
  "a2a:ops" "$(jq -r '.delivered // "NO-RECEIPT"' <<<"$sick_esc" 2>/dev/null || echo NO-ESCALATE-ROW)"
# ...and the courier is a seat that is NOT the sick one. Asserted on the send
# itself, not on the receipt, so a receipt that lies about where it went reds.
t "tick: the escalation was actually handed to a courier" \
  "ops" "$(fld "$sick_out" SENT)"

# THE ACCEPTANCE CRITERION'S negative control, at the layer it names: same tick,
# same arm, every poller alive -> no escalate row and NOTHING sent. Paired with
# the arm above it discriminates "delivery is wired" from "delivery fires always".
well_out=$(tick_arm "$_WELL_SNAP")
well_esc="$(fld "$well_out" ESC)"
t "negative control: a healthy fleet writes no escalate row" "" "$well_esc"
t "negative control: a healthy fleet sends nothing" \
  "" "$(fld "$well_out" SENT)"

# ── DIVE-3753: the same real tick, ARMED — rung 4 end to end ─────────────────
# The arms above run dormant, which is why they still see an escalation. Armed,
# the identical poller-dead snapshot must take the ACTION instead: cmd_restart
# called for the sick seat, an 'action' row recording rung=restart, and NO page
# to a human — an auto-recovery that also pings a person is how an escalation
# channel gets muted.
armed_out=$(tick_arm "$_SICK_SNAP" armed)
t "armed tick: the sick seat was actually restarted" "main" "$(fld "$armed_out" RESTARTED)"
t "armed tick: it is audited as an ACT, at rung restart" "restart" \
  "$(jq -r '.rung // "NO-RUNG"' <<<"$(fld "$armed_out" ACT)" 2>/dev/null || echo NO-ACTION-ROW)"
t "armed tick: the act records its result" "ok" \
  "$(jq -r '.result // "NO-RESULT"' <<<"$(fld "$armed_out" ACT)" 2>/dev/null || echo NO-ACTION-ROW)"
t "armed tick: a successful auto-restart pages nobody" "" "$(fld "$armed_out" SENT)"
t "armed tick: and writes no escalate row" "" "$(fld "$armed_out" ESC)"

# ...and the seat a restart did NOT fix. Same snapshot, same armed tick, but the
# seat already spent its budget in-window: no second restart, and the human path
# takes over. This is the pair that proves the limiter both ALLOWS and REFUSES —
# a limiter only ever seen refusing is indistinguishable from one that refuses
# always, which would reproduce the outage the rung exists to end.
_SPENT="INSERT INTO supervisor_events (agent, event, classification, cause, signals)
        VALUES ('main','action','stuck','poller-dead','{\"rung\":\"restart\",\"attempt\":1,\"result\":\"ok\"}');"
limited_out=$(tick_arm "$_SICK_SNAP" armed "$_SPENT")
t "rate-limited tick: no second restart inside the window" "" "$(fld "$limited_out" RESTARTED)"
t "rate-limited tick: it escalates instead, naming the limiter" "restart-rate-limited" \
  "$(jq -r '.reason // "NO-REASON"' <<<"$(fld "$limited_out" ESC)" 2>/dev/null || echo NO-ESCALATE-ROW)"
t "rate-limited tick: and the escalation reaches a courier" "ops" "$(fld "$limited_out" SENT)"

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
