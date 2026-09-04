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
#
# DIVE-3822 adds REGISTRY, ROTATE_RESULT and TICKS. The rotate implementation is
# replaced at its destructive boundary, but `_sup_quota_rotate` and the REAL
# tick remain in the path. Recording argv proves the tick asks the production
# selector for `--require-live-headroom`; running two ticks against one DB proves
# the no-target alert is deduped by behavior, not merely by a helper predicate.
tick_arm() {  # <snapshot-json> [armed] [seed-sql] [registry-json] [rotated|no-target|failed] [ticks] [poller-after-restart]
  local fixture_registry="${4:-}"
  [[ -n "$fixture_registry" ]] || fixture_registry='{"agents":{}}'
  # DIVE-3856: what the post-restart poller probe SEES, as a fixture. Default 1
  # (the poller came back), which is what every pre-existing arm here assumes.
  # It has to be injected: rung 4 now re-probes after its own restart, and the
  # probe is a `pgrep` against the REAL process table. Left unstubbed this
  # harness reads whatever this host happens to be running — it passed locally
  # only because seats named in the fixture have live pollers, and CI, which has
  # none, went red on three arms. A fixture that is realistic in its DATA is
  # still not hermetic if one of its probes reaches outside the fixture.
  SNAP="$1" ARMED="${2:-}" SEED="${3:-}" POLLER_AFTER="${7:-1}" \
    FIXTURE_REGISTRY="$fixture_registry" ROTATE_RESULT="${5:-no-target}" TICKS="${6:-1}" \
    REPO="$PWD" bash -c '
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
    registry_read()     { printf "%s" "$FIXTURE_REGISTRY"; }
    _task_agent_channel() { return 1; }               # no telegram anywhere
    : >"$TMP/sent"; : >"$TMP/restarted"; : >"$TMP/rotated"; : >"$TMP/capacity-alerts"; : >"$TMP/capacity-human"; : >"$TMP/capacity-excerpt"
    cmd_send() { printf "%s\n" "$1" >>"$TMP/sent"; return 0; }
    cmd_restart() { printf "%s\n" "$1" >>"$TMP/restarted"; return 0; }
    # DIVE-3856: rung 4 re-probes the poller after its own restart. Both stubs
    # keep that hermetic — the count comes from the fixture, and the poll does
    # not spend real seconds waiting for a process that will never exist.
    _sup_true_poller_count() { printf "%s\n" "$POLLER_AFTER"; }
    sleep() { :; }
    with_registry_lock() { "$@"; }
    cmd_agent_rotation_rotate() {
      printf "%s\n" "$*" >>"$TMP/rotated"
      case "$ROTATE_RESULT" in
        # DIVE-3856: the rotate envelope now names the bounce it SCHEDULED and
        # the poller check it OWES. Pinned here so this stub stays a model of the
        # verb as it ships rather than of an older one. (No apostrophes in this
        # comment on purpose: the whole block lives inside a single-quoted
        # `bash -c` string, and one would end it.)
        rotated)   printf "%s\n" "{\"ok\":true,\"data\":{\"rotated\":true,\"channelBounceScheduled\":true,\"channelVerified\":false}}" ;;
        no-target) printf "%s\n" "{\"ok\":true,\"data\":{\"rotated\":false,\"channelBounceScheduled\":false,\"channelVerified\":null}}" ;;
        *)         return 1 ;;
      esac
    }
    # DIVE-3940: capture the 4th arg (notify_human) into its own field so an arm
    # can grade the classification->human-leg wiring. name:class stays in
    # capacity-alerts unchanged; the human decision lands in capacity-human.
    # DIVE-3970 it.3: the EXCERPT is captured too. The persistence annotation
    # ("the self-healing mute has EXPIRED") is the only observable difference
    # between "there was a mute and it expired" and "this wall was always loud",
    # so without it the guard that tells those apart has no arm that can red.
    _sup_capacity_alert() { printf "%s:%s\n" "$1" "$2" >>"$TMP/capacity-alerts"; printf "%s:%s\n" "$1" "${4:-true}" >>"$TMP/capacity-human"; printf "%s\n" "${3:-}" >>"$TMP/capacity-excerpt"; }
    # The seed writes BEFORE the tick, so it has to create the schema itself —
    # nothing else has touched this fixture DB yet. Both calls are subshelled:
    # `db` reaches `fail`, and `fail` EXITS, which `|| true` cannot catch.
    if [[ -n "$SEED" ]]; then
      ( tasks_db_init ) >/dev/null 2>&1 || true
      ( db "$SEED" )    >/dev/null 2>&1 || true
    fi
    tick_n=0
    while (( tick_n < TICKS )); do
      cmd_supervisor_tick >/dev/null 2>&1 || { printf "TICK-RC=%s|" "$?"; }
      tick_n=$((tick_n + 1))
    done
    printf "ESC=%s|SENT=%s|ACT=%s|RESTARTED=%s|ROTATED=%s|ALERTS=%s|ALERT_ROWS=%s|NUDGE_ROWS=%s|HUMAN=%s|EXCERPT=%s" \
      "$(db "SELECT COALESCE(GROUP_CONCAT(signals), \"\") FROM supervisor_events WHERE event=$(sqlq escalate);")" \
      "$(paste -sd, <"$TMP/sent")" \
      "$(db "SELECT COALESCE(GROUP_CONCAT(signals), \"\") FROM supervisor_events WHERE event=$(sqlq action);")" \
      "$(paste -sd, <"$TMP/restarted")" \
      "$(paste -sd, <"$TMP/rotated")" \
      "$(paste -sd, <"$TMP/capacity-alerts")" \
      "$(db "SELECT COUNT(*) FROM supervisor_events WHERE event=$(sqlq alert) AND classification=$(sqlq quota-exhausted);")" \
      "$(db "SELECT COUNT(*) FROM supervisor_events WHERE event=$(sqlq action) AND signals LIKE $(sqlq %\\\"rung\\\":\\\"nudge\\\"%);")" \
      "$(paste -sd, <"$TMP/capacity-human")" \
      "$(paste -sd, <"$TMP/capacity-excerpt" | tr "|" "/")"
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
# DIVE-3856: the three arms above now depend on the poller having come BACK, and
# say so — the fixture supplies that reading rather than the host process table.

# ── DIVE-3856: the restart that RAN and did not work ─────────────────────────
# The defect this pair grades, measured on `main` 2026-08-31: rung 4 restarted a
# poller-dead seat, recorded result:"ok" from cmd_restart EXIT CODE, and the seat
# stayed deaf for another fifteen minutes. The failure surfaced only on the NEXT
# tick, as reason `restart-rate-limited` — a true sentence that names the limiter
# as the reason a human is needed, when the reason is that the remedy did not
# work. So: same snapshot, same armed tick, same successful cmd_restart, and the
# ONLY difference is that the poller did not come back.
deaf_out=$(tick_arm "$_SICK_SNAP" armed "" "" "" "" 0)
t "3856: the restart still RAN (this is not the limiter refusing)" "main" "$(fld "$deaf_out" RESTARTED)"
t "3856: a restart whose poller did not return is NOT recorded ok" "restart-ran-poller-still-dead" \
  "$(jq -r '.result // "NO-RESULT"' <<<"$(fld "$deaf_out" ACT)" 2>/dev/null || echo NO-ACTION-ROW)"
t "3856: and it escalates on THIS tick, naming the remedy — not ten minutes later, naming the limiter" \
  "restart-ran-poller-still-dead" \
  "$(jq -r '.reason // "NO-REASON"' <<<"$(fld "$deaf_out" ESC)" 2>/dev/null || echo NO-ESCALATE-ROW)"
t "3856: the same-tick escalation reaches a courier (a page nobody receives is not a page)" "ops" \
  "$(fld "$deaf_out" SENT)"
# The third outcome must not page anyone: a type whose poller has no argv-stable
# shape reads `unverified`, and escalating that would alert every healthy seat of
# that type. n/a is what _sup_true_poller_count returns for such a type.
unv_out=$(tick_arm "$_SICK_SNAP" armed "" "" "" "" "n/a")
t "3856: an UNVERIFIABLE seat is recorded as such, never as ok" "restart-ran-poller-unverified" \
  "$(jq -r '.result // "NO-RESULT"' <<<"$(fld "$unv_out" ACT)" 2>/dev/null || echo NO-ACTION-ROW)"
t "3856: and it pages nobody (it is 'I could not tell', not 'it is broken')" "" "$(fld "$unv_out" SENT)"
t "3856: …and writes no escalate row" "" "$(fld "$unv_out" ESC)"

# ...and the seat a restart did NOT fix. Same snapshot, same armed tick, but the
# seat already spent its budget in-window: no second restart, and the human path
# takes over. This is the pair that proves the limiter both ALLOWS and REFUSES —
# a limiter only ever seen refusing is indistinguishable from one that refuses
# always, which would reproduce the outage the rung exists to end.
#
# DIVE-3915 corrects this fixture's ROW to match its own prose. It seeded
# `result:"ok"` and called it "the seat a restart did NOT fix" — which was
# coherent only while `ok` meant cmd_restart's exit code and said nothing about
# the poller. DIVE-3856 gave the trail a real reading, and DIVE-3915 makes the
# ceiling count it: an unhealed restart is what refuses a second one.
_SPENT="INSERT INTO supervisor_events (agent, event, classification, cause, signals)
        VALUES ('main','action','stuck','poller-dead','{\"rung\":\"restart\",\"attempt\":1,\"result\":\"restart-ran-poller-still-dead\"}');"
limited_out=$(tick_arm "$_SICK_SNAP" armed "$_SPENT")
t "rate-limited tick: no second restart inside the window" "" "$(fld "$limited_out" RESTARTED)"
t "rate-limited tick: it escalates instead, naming the limiter" "restart-rate-limited" \
  "$(jq -r '.reason // "NO-REASON"' <<<"$(fld "$limited_out" ESC)" 2>/dev/null || echo NO-ESCALATE-ROW)"
t "rate-limited tick: and the escalation reaches a courier" "ops" "$(fld "$limited_out" SENT)"

# ── DIVE-3915: a recovery that WORKED does not spend the next episode's cure ──
# THE MEASURED OUTAGE, 2026-09-03. `main` and `olivia` both went deaf on telegram
# within two minutes, same lifecycle signature. The supervisor classified `main`
# correctly and could not act: `ESCALATE main (poller-dead: rung-4-needed)` then
# `(poller-dead: restart-rate-limited)`. The budget had been spent hours earlier
# by an UNRELATED episode whose restart had worked. The cure, once a human ran
# it, took 2.4 seconds — 00:47:25 restart, 00:47:27.841 `boot ok`.
#
# Same snapshot, same armed tick, and the ONLY difference from the pair above is
# that the prior restart's recorded result is `ok`: DIVE-3856's probe saw the
# poller return. The rung must fire.
_HEALED="INSERT INTO supervisor_events (agent, event, classification, cause, signals)
         VALUES ('main','action','stuck','poller-dead','{\"rung\":\"restart\",\"attempt\":1,\"result\":\"ok\"}');"
healed_out=$(tick_arm "$_SICK_SNAP" armed "$_HEALED")
t "3915: a prior restart that HEALED the poller does not refuse the next one" "main" \
  "$(fld "$healed_out" RESTARTED)"
t "3915: and no restart-rate-limited escalation is written" "" \
  "$(jq -r '.reason // ""' <<<"$(fld "$healed_out" ESC)" 2>/dev/null || echo "")"
t "3915: so nobody is paged for a seat the supervisor just cured" "" "$(fld "$healed_out" SENT)"

# THE FLAP BOUND, at the tick. Three healed restarts in the window: nothing is
# unhealed, so the ceiling above never fires — and without a second bound this
# seat restarts forever and never reaches a person. It escalates under its own
# reason, because "the remedy keeps being needed" sends a human somewhere else
# than "the remedy keeps failing".
_FLAP=""
for _i in 1 2 3; do
  _FLAP+="INSERT INTO supervisor_events (agent, event, classification, cause, signals)
          VALUES ('main','action','stuck','poller-dead','{\"rung\":\"restart\",\"attempt\":1,\"result\":\"ok\"}');"
done
flap_out=$(tick_arm "$_SICK_SNAP" armed "$_FLAP")
t "3915 flap: the fourth restart in the window is refused" "" "$(fld "$flap_out" RESTARTED)"
t "3915 flap: and it escalates under its OWN reason, not the limiter's" "restart-flapping" \
  "$(jq -r '.reason // "NO-REASON"' <<<"$(fld "$flap_out" ESC)" 2>/dev/null || echo NO-ESCALATE-ROW)"
t "3915 flap: which reaches a courier, like every other escalation" "ops" "$(fld "$flap_out" SENT)"

# ── DIVE-3822: weekly exhaustion, real tick wiring ───────────────────────────
_QUOTA_SNAP='[{"name":"ops","type":"claude","classification":"quota-exhausted","cause":"quota-exhausted","detail":"Opus 5 5h: 0% 7d: 100%"},
                 {"name":"quinn","type":"claude","classification":"healthy"}]'
_QUOTA_REG='{"agents":{"ops":{"rotation":{"enabled":true}}}}'

quota_rotated_out=$(tick_arm "$_QUOTA_SNAP" armed "" "$_QUOTA_REG" rotated)
t "quota tick: invokes rotation through the measured-headroom fence" \
  "ops --require-live-headroom" "$(fld "$quota_rotated_out" ROTATED)"
t "quota tick: an eligible target records the rotate action" "rotate" \
  "$(jq -r '.rung // "NO-RUNG"' <<<"$(fld "$quota_rotated_out" ACT)" 2>/dev/null || echo NO-ACTION-ROW)"
t "quota tick: successful rotation is quiet" "" "$(fld "$quota_rotated_out" ALERTS)"
t "quota tick: successful rotation never reaches the nudge ladder" "0" \
  "$(fld "$quota_rotated_out" NUDGE_ROWS)"

quota_no_target_out=$(tick_arm "$_QUOTA_SNAP" armed "" "$_QUOTA_REG" no-target 2)
t "quota tick: no measured target still uses the headroom-fenced selector" \
  "ops --require-live-headroom,ops --require-live-headroom" "$(fld "$quota_no_target_out" ROTATED)"
t "quota tick: no measured target emits one capacity alert across two ticks" \
  "ops:quota-exhausted" "$(fld "$quota_no_target_out" ALERTS)"
t "quota tick: the dedup ledger contains exactly one alert row" "1" \
  "$(fld "$quota_no_target_out" ALERT_ROWS)"
t "quota tick: no measured target never falls into the nudge ladder" "0" \
  "$(fld "$quota_no_target_out" NUDGE_ROWS)"

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

# ── DIVE-3940: the self-healing quota wall mutes ONLY the human leg ──────────
# lodar 2026-09-03: the [FLEET-HEALTH quota-exhausted] pings are noise when the
# wall self-heals — a shared profile's 5h window with a resume deadline still in
# the future (quotaDeadline=live). The machine leg (main triages, DIVE-3272 cover)
# and the audited row must stay; only lodar's phone goes quiet, and only for the
# CONFIRMED-benign case.

# (a) the pure decision, graded in isolation — no I/O, so the wiring is exact.
t "notify_human: live-deadline quota wall is the one mute" \
  "false" "$(_sup_capacity_notify_human quota-exhausted live)"
t "notify_human: unknown-deadline (possible hard wall) keeps the human" \
  "true" "$(_sup_capacity_notify_human quota-exhausted unknown)"
t "notify_human: a non-quota class is never muted by a live deadline" \
  "true" "$(_sup_capacity_notify_human no-output live)"
t "notify_human: quota-exhausted with no deadline defaults to loud" \
  "true" "$(_sup_capacity_notify_human quota-exhausted "")"

# (b) the guard inside the real _sup_capacity_alert. Both legs are observed: the
# machine leg (5dive agent send main) must fire UNCONDITIONALLY; the human leg
# obeys notify_human. `5dive` is a leading-digit function name, which bash allows.
MACHINE_FIRED=0; HUMAN_FIRED=0
5dive() { MACHINE_FIRED=1; return 0; }
_task_agent_channel() { return 0; }
_task_send_owner() { HUMAN_FIRED=1; return 0; }

MACHINE_FIRED=0; HUMAN_FIRED=0; _sup_capacity_alert ops quota-exhausted "d" true
t "capacity_alert: notify_human=true fires the human leg"  "1" "$HUMAN_FIRED"
t "capacity_alert: the machine leg fires regardless (true)" "1" "$MACHINE_FIRED"

MACHINE_FIRED=0; HUMAN_FIRED=0; _sup_capacity_alert ops quota-exhausted "d" false
t "capacity_alert: notify_human=false MUTES the human leg"  "0" "$HUMAN_FIRED"
t "capacity_alert: the machine leg still fires when muted"  "1" "$MACHINE_FIRED"

MACHINE_FIRED=0; HUMAN_FIRED=0; _sup_capacity_alert ops quota-exhausted "d"
t "capacity_alert: default (no 4th arg) preserves the old loud behavior" "1" "$HUMAN_FIRED"
unset -f 5dive

# (c) end-to-end through the real tick: classification -> deadline -> human leg.
# Unarmed, so quota-exhausted skips the rotation remedy and reaches the alert.
_SELFHEAL_SNAP='[{"name":"ops","type":"claude","classification":"quota-exhausted","cause":"quota-exhausted","detail":"pane refusal [resume deadline still in the FUTURE — the refusal is live]","signals":{"quotaDeadline":"live"}}]'
selfheal_out=$(tick_arm "$_SELFHEAL_SNAP")
t "3940 tick: a self-healing wall still records the capacity alert" \
  "ops:quota-exhausted" "$(fld "$selfheal_out" ALERTS)"
t "3940 tick: a self-healing wall still writes the audited alert row" \
  "1" "$(fld "$selfheal_out" ALERT_ROWS)"
t "3940 tick: a self-healing wall MUTES the human leg" \
  "ops:false" "$(fld "$selfheal_out" HUMAN)"

_HARDWALL_SNAP='[{"name":"ops","type":"claude","classification":"quota-exhausted","cause":"quota-exhausted","detail":"pane refusal [names no resume deadline]","signals":{"quotaDeadline":"unknown"}}]'
t "3940 tick: an unknown-deadline wall keeps the human leg" \
  "ops:true" "$(fld "$(tick_arm "$_HARDWALL_SNAP")" HUMAN)"

_NOOUT_SNAP='[{"name":"ops","type":"claude","classification":"no-output","cause":"no-output","detail":"3 open row(s), nothing closed in 5d"}]'
t "3940 tick: a no-output stall is unaffected — human leg still fires" \
  "ops:true" "$(fld "$(tick_arm "$_NOOUT_SNAP")" HUMAN)"

# ── DIVE-3970: the OTHER self-healing shapes, and the escape from the mute ───
# Every string below is a real refusal, copied off supervisor_events
# 2026-08-31..09-04 — the population that produced one DM per walled seat. All
# of them parse to quotaDeadline=unknown, which DIVE-3940 keeps LOUD.
#
# The clock is pinned: _sup_quota_selfheal takes `now` as an argument precisely
# so `resets 11:30am` is assertable as live-or-lapsed without waiting for a time
# of day. 2026-09-04 09:30 is the clock dev's real refusal was read at.
_SH_NOW=$(date -d '2026-09-04 09:30:00' +%s)
sh() { _sup_quota_selfheal "$1" "$_SH_NOW" | tr $'\x1f' ' '; }

t "selfheal: the DIVE-3880 phrasing still reads as a live clock" \
  "clock" "$(sh '● Usage limit reached · continuing automatically at 11:30am · esc or' | cut -d' ' -f1)"
t "selfheal: 'your session limit resets 11:30am' (dev, the DM that prompted this)" \
  "clock" "$(sh "⎿  You've hit your monthly spend limit · your session limit resets 11:30am" | cut -d' ' -f1)"
t "selfheal: a clock line carries its resume epoch, not just its kind" \
  "$(date -d '2026-09-04 11:30:00' +%s)" "$(sh "your session limit resets 11:30am" | cut -d' ' -f2)"
t "selfheal: a WEEKLY reset clock takes the week horizon, not the nearest-day clock" \
  "week" "$(sh "⎿  You've hit your monthly spend limit · your weekly limit resets 1am (UTC)" | cut -d' ' -f1)"
t "selfheal: ...and the session-scoped clock on the same shape is still a clock" \
  "clock" "$(sh "⎿  You've hit your monthly spend limit · your session limit resets 11:30am" | cut -d' ' -f1)"
t "selfheal: a weekly window meter at the wall (community, 5h: 0% 1w: 100%)" \
  "week" "$(sh 'Sonnet 5 5h: 0% 1w: 100%' | cut -d' ' -f1)"
t "selfheal: 5h: 30% 1w: 100% is walled on the WEEK, not the 5h window" \
  "week" "$(sh 'Sonnet 5 5h: 30% 1w: 100%' | cut -d' ' -f1)"
t "selfheal: a 5h meter at the wall takes the short horizon" \
  "soon" "$(sh 'Sonnet 5 5h: 100% 1w: 40%' | cut -d' ' -f1)"
t "selfheal: 'continuing shortly' resumes by itself and says no clock" \
  "soon" "$(sh '● Usage limit reached · continuing shortly · esc to cancel' | cut -d' ' -f1)"

# THE HARD-WALL SAFETY, in the same function. These must NOT be recognised —
# DIVE-3880's rule that a deadline-free refusal is an indefinite freeze is
# unchanged for every shape 3970 did not name.
t "selfheal: meters below the wall are not a self-healing signal at all" \
  "no" "$(sh 'Sonnet 5 5h: 30% 1w: 40%' | cut -d' ' -f1)"
t "selfheal: 'credit balance is too low' stays a hard wall" \
  "no" "$(sh 'credit balance is too low' | cut -d' ' -f1)"
t "selfheal: a bare 429 stays a hard wall" \
  "no" "$(sh 'API Error: 429 insufficient_quota' | cut -d' ' -f1)"
t "selfheal: an empty signature is never self-healing" "no" "$(sh '' | cut -d' ' -f1)"
# A promised reset that has already PASSED, with the wall still on screen, is
# the hard wall — so a lapsed clock short-circuits to `no` and never falls
# through to a meter on the same line.
t "selfheal: a LAPSED resume clock is not self-healing (it promised and failed)" \
  "no" "$(sh '● Usage limit reached · continuing automatically at 9am · esc or type to' | cut -d' ' -f1)"
t "selfheal: a lapsed clock does not fall through to a 100% meter" \
  "no" "$(sh 'continuing automatically at 9am · Sonnet 5 5h: 0% 1w: 100%' | cut -d' ' -f1)"

# The widened human-leg decision, and its escape.
t "notify_human: a recognised self-healing shape mutes on an unknown deadline" \
  "false" "$(_sup_capacity_notify_human quota-exhausted unknown week)"
t "notify_human: an unrecognised shape still keeps the human (hard wall)" \
  "true" "$(_sup_capacity_notify_human quota-exhausted unknown no)"
t "notify_human: persistence overrides the mute" \
  "true" "$(_sup_capacity_notify_human quota-exhausted unknown week true)"
t "notify_human: persistence overrides the DIVE-3940 live-deadline mute too" \
  "true" "$(_sup_capacity_notify_human quota-exhausted live no true)"
t "notify_human: a non-quota class is never muted by a self-healing kind" \
  "true" "$(_sup_capacity_notify_human no-output unknown week)"

# The horizons. Relative to the FIRST alert for the shapes that name no clock;
# the clock itself when one was named.
t "escalate_after: a named clock escalates at that clock" \
  "1000" "$(_sup_quota_escalate_after clock 1000 500)"
t "escalate_after: a 5h-window shape escalates 6h after the first alert" \
  "$(( 21600 ))" "$(_sup_quota_escalate_after soon "" 0)"
t "escalate_after: a weekly shape escalates a conservative 7 days after the first alert" \
  "$(( 604800 ))" "$(_sup_quota_escalate_after week "" 0)"
# ITERATION 2 (codex): the weekly horizon must be at least the weekly reset it
# is waiting for, and a weekly reset is up to 7 days out — so it deliberately
# OUTLIVES the 24h dedup window. That is only reachable because persistence is
# measured from the wall EPISODE and not from the window (see
# _sup_quota_episode_first); iteration 1 measured it from the window, which
# forced 12h and took lodar's phone back six days before the reset. This arm is
# the inverse of the one it replaces: if someone re-scopes persistence to the
# window, the horizon has to come back below 24h and this reds.
t "escalate_after: the weekly horizon reaches PAST the dedup window it survives" \
  "yes" "$([[ $_SUP_SELFHEAL_WEEK_H -ge $_SUP_ALERT_WINDOW_H && $_SUP_SELFHEAL_WEEK_H -ge 168 ]] && echo yes || echo no)"
t "escalate_after: the short horizon still fits inside one window (mid-window escape)" \
  "yes" "$([[ $_SUP_SELFHEAL_SOON_H -lt $_SUP_ALERT_WINDOW_H ]] && echo yes || echo no)"
t "escalate_after: a live-deadline mute with no stored signature still escalates" \
  "$(( 21600 ))" "$(_sup_quota_escalate_after no "" 0)"

# ── the same real tick: classification -> signature -> human leg ─────────────
# The signature is what the tick reads now (signals.quotaSignature), so these
# arms grade the WIRING, not just the classifier.
_sh_snap() {  # <signature>
  printf '[{"name":"ops","type":"claude","classification":"quota-exhausted","cause":"quota-exhausted","detail":"pane shows a model-capacity refusal: %s","signals":{"quotaDeadline":"unknown","quotaSignature":"%s"}}]' "$1" "$1"
}
_METER_SIG='Sonnet 5 5h: 100% 1w: 40%'
meter_out=$(tick_arm "$(_sh_snap "$_METER_SIG")")
t "3970 tick: a window-meter wall MUTES the human leg" \
  "ops:false" "$(fld "$meter_out" HUMAN)"
t "3970 tick: ...and still writes the audited alert row" "1" "$(fld "$meter_out" ALERT_ROWS)"
t "3970 tick: ...and still fires the machine leg to main" \
  "ops:quota-exhausted" "$(fld "$meter_out" ALERTS)"
t "3970 tick: an unrecognised refusal still pings the human" \
  "ops:true" "$(fld "$(tick_arm "$(_sh_snap 'credit balance is too low')")" HUMAN)"

# PERSISTENCE, end to end. The seed is the first alert of the window, carrying
# the same self-healing signature, aged past its horizon (6h for a 5h meter).
# The tick must let ONE more alert through, with the human leg back on.
_sh_seed() {  # <hours-ago> [rows]
  local sig; sig=$(printf '{"signals":{"quotaDeadline":"unknown","quotaSignature":"%s"}}' "$_METER_SIG")
  printf "INSERT INTO supervisor_events (agent, event, classification, cause, signals, ts) VALUES ('ops','alert','quota-exhausted','quota-exhausted','%s', datetime('now','-%s hours'));" "$sig" "$1"
}
persist_out=$(tick_arm "$(_sh_snap "$_METER_SIG")" "" "$(_sh_seed 7)")
t "3970 tick: a wall still up past its horizon takes the human leg BACK" \
  "ops:true" "$(fld "$persist_out" HUMAN)"
t "3970 tick: the escalation is an ordinary alert row (seed + one escalation)" \
  "2" "$(fld "$persist_out" ALERT_ROWS)"

# The negative control at the same layer: identical seed, still inside the
# horizon -> the dedup window holds and NOTHING is sent to anyone.
fresh_out=$(tick_arm "$(_sh_snap "$_METER_SIG")" "" "$(_sh_seed 1)")
t "3970 tick: inside the horizon the dedup window still suppresses everything" \
  "" "$(fld "$fresh_out" HUMAN)"
t "3970 tick: ...and writes no second alert row" "1" "$(fld "$fresh_out" ALERT_ROWS)"

# Exactly once per window: with the escalation already on the ledger (2 rows),
# a third tick past the horizon must add nothing — otherwise the escape from
# the mute becomes a 10-minute alarm.
# (the second row is dated AFTER the horizon the first one set — that row IS
# the escalation, which is what makes it exactly-once rather than a 10-min alarm)
twice_out=$(tick_arm "$(_sh_snap "$_METER_SIG")" "" "$(_sh_seed 7)$(_sh_seed 0)")
t "3970 tick: the escalation fires exactly once per dedup window" \
  "" "$(fld "$twice_out" HUMAN)"
t "3970 tick: ...and adds no third alert row" "2" "$(fld "$twice_out" ALERT_ROWS)"

# A seat whose FIRST alert was already loud must not be re-pinged by the
# persistence path — it would double a ping the human already has.
loud_seed=$(printf "INSERT INTO supervisor_events (agent, event, classification, cause, signals, ts) VALUES ('ops','alert','quota-exhausted','quota-exhausted','%s', datetime('now','-7 hours'));" '{"signals":{"quotaDeadline":"unknown","quotaSignature":"credit balance is too low"}}')
t "3970 tick: a first alert that was LOUD is not escalated a second time" \
  "" "$(fld "$(tick_arm "$(_sh_snap "$_METER_SIG")" "" "$loud_seed")" HUMAN)"

# ── ITERATION 2 (codex): the WEEKLY wall, end to end, across dedup windows ──
# The rejection: "a weekly 100% meter is muted initially but re-enables lodar's
# DM after 12h, even though the expected weekly reset may be up to 7 days away."
# These four arms are the acceptance criterion — muted until the reset it is
# waiting on, loud after — and the first two RED under any window-scoped
# persistence, because a window-scoped horizon cannot exceed 24h.
_WEEK_SIG='Sonnet 5 5h: 0% 1w: 100%'
_wk_seed() {  # <hours-ago>
  local sig; sig=$(printf '{"signals":{"quotaDeadline":"unknown","quotaSignature":"%s"}}' "$_WEEK_SIG")
  printf "INSERT INTO supervisor_events (agent, event, classification, cause, signals, ts) VALUES ('ops','alert','quota-exhausted','quota-exhausted','%s', datetime('now','-%s hours'));" "$sig" "$1"
}
# NEGATIVE CONTROL AT 12h (the exact hour iteration 1 escalated at): inside the
# dedup window, 13h past the first alert, weekly reset still days away -> the
# mute holds and NOTHING reaches anyone.
week_12_out=$(tick_arm "$(_sh_snap "$_WEEK_SIG")" "" "$(_wk_seed 13)")
t "3970/wk: 13h in, a weekly wall is still muted (iteration 1 pinged here)" \
  "" "$(fld "$week_12_out" HUMAN)"
t "3970/wk: ...and files no escalation row" "1" "$(fld "$week_12_out" ALERT_ROWS)"
# THE CARRY ACROSS WINDOWS: the dedup window has rolled (last alert 30h ago), so
# this tick files a FRESH alert — which must still be MUTED. Iteration 1 could
# not express this: every rolled window restarted its own horizon.
week_carry_out=$(tick_arm "$(_sh_snap "$_WEEK_SIG")" "" "$(_wk_seed 30)")
t "3970/wk: a new dedup window files a fresh alert that is STILL muted" \
  "ops:false" "$(fld "$week_carry_out" HUMAN)"
# POSITIVE, ONLY POST-RESET: an unbroken chain one window apart reaching back
# past 7 days. The episode start is 170h ago, the conservative weekly reset has
# passed, the seat is still walled -> lodar hears about it.
_wk_chain="$(_wk_seed 170)$(_wk_seed 146)$(_wk_seed 122)$(_wk_seed 98)$(_wk_seed 74)$(_wk_seed 50)$(_wk_seed 26)"
t "3970/wk: past the weekly reset and still walled, the human leg comes back" \
  "ops:true" "$(fld "$(tick_arm "$(_sh_snap "$_WEEK_SIG")" "" "$_wk_chain")" HUMAN)"
# A GAP IS A NEW WALL: the seat recovered between the 200h alert and the 30h
# one, so the episode starts at 30h and the mute starts over. Without the gap
# rule the 200h row would be read as this wall's start and escalate immediately.
t "3970/wk: a recovered-then-rewalled seat starts a NEW mute, not an expired one" \
  "ops:false" "$(fld "$(tick_arm "$(_sh_snap "$_WEEK_SIG")" "" "$(_wk_seed 200)$(_wk_seed 30)")" HUMAN)"

# ── ITERATION 3 (codex): THE CLOCK TRANSITION ────────────────────────────────
# The rejection: "a named reset-clock wall does not re-enable lodar's human leg
# when that clock passes inside the 24h dedup window. In the real tick the
# current signature becomes qkind=no once lapsed, so the persistence branch is
# skipped and dedup continues."
#
# This is the ONE shape where the mute's expiry and the loss of recognition are
# the SAME event: a clock lapses, and lapsing is both "the promise came due" and
# "this no longer reads self-healing". Reading the episode at `now` therefore
# erases the deadline it is being held to, and the fix is to read the episode's
# stored signature AT THE EPISODE'S OWN ts. That property is graded twice below:
# once pure (the two readings of one string disagree, and which one is used
# decides the outcome) and once end-to-end through the real tick.
#
# The clocks are computed from the real wall clock because the tick's `now` is
# the real one; they are wall-clock times of day, so the nearest-day parser
# places both on the correct side of `now` at both instants, including across
# midnight (a 23:30 read at 00:30 is nearest YESTERDAY, i.e. 1h ago).
_CLK_PAST=$(date -d '-1 hour' +'%-I:%M%P')     # lapsed 1h ago, live 2h ago
_CLK_FUTURE=$(date -d '+1 hour' +'%-I:%M%P')   # still 1h away
_clk_sig() { printf "⎿  You've hit your monthly spend limit · your session limit resets %s" "$1"; }
# The apostrophe in the real refusal ("You've hit your monthly spend limit") is
# a SQL string terminator, and a seed that fails to insert leaves the arm
# looking like a FIRST sighting — which is a green negative control for the
# wrong reason. Doubled here; sqlite stores the single character.
_clk_seed() {  # <signature> <hours-ago>
  local sig; sig=$(printf '{"signals":{"quotaDeadline":"unknown","quotaSignature":"%s"}}' "$1")
  sig=${sig//\'/\'\'}
  printf "INSERT INTO supervisor_events (agent, event, classification, cause, signals, ts) VALUES ('ops','alert','quota-exhausted','quota-exhausted','%s', datetime('now','-%s hours'));" "$sig" "$2"
}
_ep2=$(date -d '-2 hours' +%s)
# (a) pure: the SAME stored string reads two different ways at the two instants,
#     and only the episode's own instant preserves the deadline.
t "3970/clk: the episode's clock was LIVE when that alert chose to stay quiet" \
  "clock" "$(_sup_quota_selfheal "$(_clk_sig "$_CLK_PAST")" "$_ep2" | cut -d$'\x1f' -f1)"
t "3970/clk: ...and reads as NOT self-healing now that it has passed" \
  "no" "$(_sup_quota_selfheal "$(_clk_sig "$_CLK_PAST")" "$(date +%s)" | cut -d$'\x1f' -f1)"
t "3970/clk: the preserved reading carries the clock the expiry is owed to" \
  "yes" "$([[ "$(_sup_quota_selfheal "$(_clk_sig "$_CLK_PAST")" "$_ep2" | cut -d$'\x1f' -f2)" =~ ^[0-9]+$ ]] && echo yes || echo no)"

# (b) POSITIVE, end to end: alert 2h ago muted on a clock that has since passed,
#     still inside the 24h dedup window. lodar must hear about it now.
clk_out=$(tick_arm "$(_sh_snap "$(_clk_sig "$_CLK_PAST")")" "" "$(_clk_seed "$(_clk_sig "$_CLK_PAST")" 2)")
t "3970/clk: a muted clock wall takes the human leg back when its clock passes" \
  "ops:true" "$(fld "$clk_out" HUMAN)"
t "3970/clk: ...as one ordinary escalation row (seed + one)" "2" "$(fld "$clk_out" ALERT_ROWS)"

# (c) NEGATIVE at the same layer: identical shape, clock still in the FUTURE ->
#     the mute holds and nothing is sent or filed. Without this the positive is
#     equally satisfied by "a lapsed-clock wall always alerts".
clk_live_out=$(tick_arm "$(_sh_snap "$(_clk_sig "$_CLK_FUTURE")")" "" "$(_clk_seed "$(_clk_sig "$_CLK_FUTURE")" 2)")
t "3970/clk: before the clock passes the mute holds — nothing sent" \
  "" "$(fld "$clk_live_out" HUMAN)"
t "3970/clk: ...and no escalation row is filed" "1" "$(fld "$clk_live_out" ALERT_ROWS)"

# (d) exactly-once survives the transition: the escalation is already on the
#     ledger (a row dated after the clock), so a later tick adds nothing.
clk_twice_out=$(tick_arm "$(_sh_snap "$(_clk_sig "$_CLK_PAST")")" "" "$(_clk_seed "$(_clk_sig "$_CLK_PAST")" 2)$(_clk_seed "$(_clk_sig "$_CLK_PAST")" 0)")
t "3970/clk: the clock escalation still fires exactly once" \
  "" "$(fld "$clk_twice_out" HUMAN)"
t "3970/clk: ...and adds no third row" "2" "$(fld "$clk_twice_out" ALERT_ROWS)"

# (e) THE COST OF THE WIDENED ENTRY, graded where it is actually observable.
#     Widening the branch to every quota wall means an episode that was never
#     muted now reaches the horizon arithmetic. "a first alert that was LOUD is
#     not escalated a second time" (above) already pins the in-window half via
#     the was-the-episode-muted gate — and it pins it so completely that a
#     second arm on the same shape would be vacuous
#     (community/wiki/two-redundant-guards-hide-a-vacuous-arm.md). The half only
#     the horizon guard holds is the ANNOTATION: at a ROLLED window this wall
#     alerts either way, and the difference is whether it is stamped as an
#     expired mute. It was never muted, so stamping it tells main and lodar that
#     a mute they were never given has run out.
clk_loud_rolled=$(tick_arm "$(_sh_snap "$(_clk_sig "$_CLK_PAST")")" "" "$(_clk_seed 'credit balance is too low' 30)")
t "3970/clk: a never-muted wall in a rolled window still reaches the human" \
  "ops:true" "$(fld "$clk_loud_rolled" HUMAN)"
t "3970/clk: ...and is NOT stamped as an expired mute it never had" \
  "no" "$(case "$(fld "$clk_loud_rolled" EXCERPT)" in *"mute has EXPIRED"*) echo yes ;; *) echo no ;; esac)"
# ...and the positive control for that instrument: the arm CAN see the stamp,
# so the negative above is a measurement and not a broken matcher.
t "3970/clk: the stamp IS present when a real mute expired" \
  "yes" "$(case "$(fld "$clk_out" EXCERPT)" in *"mute has EXPIRED"*) echo yes ;; *) echo no ;; esac)"

# (f) the FIRST sighting of a lapsed-clock wall is loud on its own merits (no
#     episode to preserve) — the hard-wall safety, unchanged by any of the above.
t "3970/clk: a lapsed-clock wall with no history is loud on first sighting" \
  "ops:true" "$(fld "$(tick_arm "$(_sh_snap "$(_clk_sig "$_CLK_PAST")")")" HUMAN)"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
