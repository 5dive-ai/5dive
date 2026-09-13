#!/usr/bin/env bash
# DIVE-4409: `_hb_wake` (src/cmd_heartbeat.sh) started an operator-parked agent.
# It runs `systemctl start "5dive-agent@<name>.service"` INSIDE
# `if ! systemctl is-active --quiet …` — it starts the unit PRECISELY BECAUSE it
# is not active — and the dispatch loop that reaches it read no `desiredState`.
# So a seat a person deliberately parked, holding one due todo, was restarted on
# the 15-minute tick with no operator in the loop: the third instance of
# DIVE-4033's consent failure (DIVE-4399 was the second) and the only one
# measurable on this host.
#
# WHY THIS HARNESS EXISTS ALONGSIDE tests/refresh_plugins_parked_agent_unit.sh.
# That harness's arm A2 asserts every path it marks GUARDED contains the string
# `desiredState`. For this file that check passes VACUOUSLY — cmd_heartbeat.sh
# already carried three hits (a comment and a read in the poller-liveness sweep,
# and a log string), none of them in the dispatch path, at the moment the file
# was resurrecting a parked agent. A presence grep is a necessary condition, not
# a sufficient one; the behavioural proof that the WAKE honours the park has to
# live somewhere, and it lives here.
#
# Two ways this fix can be wrong, failing in OPPOSITE directions:
#
#   RESURRECTS — the check is absent, or consulted after the start, and the
#                parked agent comes back on the next tick. The original bug.
#   FREEZES    — something merely UNKNOWN (no registry, no jq, corrupt JSON, an
#                agent absent from the file, no such field) reads as "parked",
#                and an agent nobody parked silently never wakes for its due
#                work. That is the worse direction here: an agent that does not
#                wake is indistinguishable from an idle fleet, while a wrong
#                start is loud and recoverable.
#
# So every positive arm is paired with a NEGATIVE CONTROL that only passes
# because the skip does NOT fire on an unknown.
#
# Hermetic in the shape DIVE-4033/DIVE-4399 established: the block is extracted
# VERBATIM from src/cmd_heartbeat.sh between its fence markers and run as the
# SHIPPED BYTES. `systemctl` and `sudo` are shadowed by PATH stubs that only
# record their argv, so no unit, no agent and no registry outside $WORK is
# touched.
#
# Run: bash tests/heartbeat_wake_parked_agent_unit.sh   (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NO `2>/dev/null` — the helper's
# stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154  # rc is $? captured at trap time
trap 'rc=$?; rm -rf "${WORK:-}"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - heartbeat_wake_parked_agent_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
SRC="$ROOT/src/cmd_heartbeat.sh"
SIB="$ROOT/tests/refresh_plugins_parked_agent_unit.sh"

FENCE='DIVE-4409 an operator-parked agent stays parked (the heartbeat wake)'
block="$(sed -n "/^# >>> ${FENCE}\$/,/^# <<< ${FENCE}\$/p" "$SRC")"
if [[ -n "$block" ]] && grep -q '_hb_agent_is_parked()' <<<"$block" \
   && grep -q '_hb_wake_start_unit_if_needed()' <<<"$block"; then
  ok_t "E1 the parked block is extractable from src/cmd_heartbeat.sh"
else
  bad_t "E1 parked block missing" "markers '# >>> / # <<< $FENCE' not found in $SRC"
  echo; echo "$PASS passed, $FAIL failed"; SUMMARY_PRINTED=1; exit 1
fi

# The START must live INSIDE the fence with the guard. A start outside it would
# be absent from the bytes every arm below runs, so this harness would be
# grading a skip the box never reaches.
if grep -q 'systemctl start "5dive-agent@' <<<"$block"; then
  ok_t "E2 the unit start ships INSIDE the fence — these arms run the bytes the box runs"
else
  bad_t "E2 the unit start is outside the fence" "the arms below would grade a skip that cannot fire in production"
fi

# A fenced guard nothing calls is DIVE-1095's shape (a fix that ships dormant),
# and a SECOND start outside the guarded function is the same defect surviving
# next to its own fix.
starts=$(grep -c 'systemctl start "5dive-agent@' "$SRC")
if grep -qE '^\s*_hb_wake_start_unit_if_needed "\$name" "\$task_ident" \|\| return \$\?' "$SRC" \
   && [[ "$starts" == 1 ]]; then
  ok_t "E3 _hb_wake routes through the guarded function, and it is the file's ONLY agent-unit start"
else
  bad_t "E3 an unguarded start path survives in the file" \
        "callers: $(grep -c '_hb_wake_start_unit_if_needed' "$SRC") ; 'systemctl start \"5dive-agent@' occurrences: $starts (expected exactly 1, inside the fence)"
fi

# The RC must be branched on by BOTH callers. A parked skip that falls through
# the generic success branch would have the dispatcher CLAIM the row in_progress
# for a seat that never received the goal — stranding it until the reaper — and
# one falling through the failure branch would log a deliberate, operator-
# authored skip as a wake failure to retry, every tick.
if [[ "$(grep -c '_HB_WAKE_RC_PARKED' "$SRC")" -ge 4 ]] \
   && grep -q '_wake_rc == _HB_WAKE_RC_PARKED' "$SRC" \
   && grep -q '_fw_rc == _HB_WAKE_RC_PARKED' "$SRC"; then
  ok_t "E4 both wake callers (the tick dispatch and 'heartbeat wake-task') branch on the parked rc"
else
  bad_t "E4 a caller does not distinguish the parked exit" \
        "a parked skip reaching the success branch claims the row; reaching the failure branch logs it as a retriable failure"
fi

WORK="$(mktemp -d)"
mkdir -p "$WORK/bin" "$WORK/state"
# A systemctl that starts nothing and records its argv. Shadowing PATH is how a
# start is observed without a start happening. `is-active` answers from
# $UNIT_ACTIVE so both sides of the branch are reachable.
# `#!/bin/bash`, not `#!/usr/bin/env bash`: U7 empties PATH to reproduce a box
# with no jq, and `env` would not be found either — the stub would fail to exec
# and U7 would pass for the wrong reason (nothing started because the STUB
# broke, read as "the guard fired").
cat > "$WORK/bin/systemctl" <<'STUB'
#!/bin/bash
if [[ "${1:-}" == "is-active" ]]; then exit "${UNIT_ACTIVE:-1}"; fi
printf '%s\n' "$*" >> "${STUB_LOG:?}"
exit 0
STUB
# sudo is only reached on the START path (the tmux settle loop). Exiting 0 makes
# the loop break on its first iteration instead of sleeping 60s per arm.
cat > "$WORK/bin/sudo" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$WORK/bin/systemctl" "$WORK/bin/sudo"

REG_STOPPED='{"agents":{"katya":{"desiredState":"stopped"},"nova":{"desiredState":"running"}}}'
REG_RUNNING='{"agents":{"katya":{"desiredState":"running"}}}'
REG_NOFIELD='{"agents":{"katya":{},"nova":{}}}'
REG_EMPTY='{"agents":{}}'
REG_CORRUPT='{"agents":{"katya":{"desiredState":"stop'

# run_wake <registry-body|MISSING> <agent> [nojq] [active]
# -> echoes the rc; $WORK/started.log holds the units started, $WORK/hb.log the
#    operator-facing notes. The fenced bytes run VERBATIM.
RC=0
run_wake() {
  local body="$1" agent="$2" nojq="${3:-}" active="${4:-}"
  : > "$WORK/started.log"; : > "$WORK/hb.log"
  local rc=0
  (
    export STUB_LOG="$WORK/started.log"
    export UNIT_ACTIVE=$([[ "$active" == active ]] && echo 0 || echo 1)
    export STATE_DIR="$WORK/state"
    if [[ "$nojq" == nojq ]]; then
      mkdir -p "$WORK/emptybin"; cp "$WORK/bin/systemctl" "$WORK/bin/sudo" "$WORK/emptybin/"
      # Shadowing PATH is the POINT — it reproduces a box with no jq without
      # uninstalling anything. Scoped to this subshell.
      # shellcheck disable=SC2123
      PATH="$WORK/emptybin"
    else
      PATH="$WORK/bin:$PATH"
    fi
    export PATH
    if [[ "$body" == MISSING ]]; then
      REGISTRY="$WORK/no-such-registry.json"
    else
      REGISTRY="$WORK/agents.json"; printf '%s' "$body" > "$REGISTRY"
    fi
    # The two collaborators the fenced bytes call, in the shapes src/ ships:
    # registry_read collapses an unreadable registry onto an empty-but-valid
    # body (src/lib/registry.sh:15), and _hb_log is the tick's log line.
    registry_read() { [[ -f "$REGISTRY" ]] && cat "$REGISTRY" || echo '{"agents":{}}'; }
    _hb_log() { printf '%s\n' "$*" >> "$WORK/hb.log"; }
    _hb_wake_fail() { printf 'FAIL-STEP %s\n' "${2:-}" >> "$WORK/hb.log"; return 1; }
    # The post-start tmux settle is a collaborator outside the fence (it polls a
    # real session for up to 60s); the arms grade the start decision, not the wait.
    _hb_wake_settle_tmux() { printf 'settled %s\n' "${1:-}" >> "$WORK/hb.log"; }
    eval "$block"
    _hb_wake_start_unit_if_needed "$agent" "DIVE-1234"
  )
  rc=$?
  RC=$rc
  return 0
}
started() { grep -q "start 5dive-agent@${1}.service" "$WORK/started.log"; }
noted()   { grep -q 'desiredState=stopped' "$WORK/hb.log"; }

run_wake "$REG_STOPPED" katya
if ! started katya && (( RC == 4 )); then
  ok_t "U1 a parked agent with a due todo is NOT started, and the skip has its own rc"
else
  bad_t "U1 the parked agent was resurrected" "started.log=$(cat "$WORK/started.log") rc=$RC"
fi
noted && ok_t "U2 the skip says why, on the operator's line" \
  || bad_t "U2 the skip is silent" "hb.log=$(cat "$WORK/hb.log")"

# --- the FREEZES direction: six negative controls, one per unknown ------------
run_wake "$REG_RUNNING" katya
started katya && (( RC == 0 )) && ok_t "U3 desiredState=running starts (negative control)" \
  || bad_t "U3 an agent nobody parked did not start" "rc=$RC log=$(cat "$WORK/started.log")"

run_wake "$REG_NOFIELD" katya
started katya && ok_t "U4 an agent with NO desiredState field starts (absent is not stopped)" \
  || bad_t "U4 an absent field read as parked" "rc=$RC"

run_wake "$REG_EMPTY" katya
started katya && ok_t "U5 an agent absent from the registry starts (unknown is not stopped)" \
  || bad_t "U5 an unknown agent read as parked" "rc=$RC"

run_wake MISSING katya
started katya && ok_t "U6 a missing registry starts (unreadable is not stopped)" \
  || bad_t "U6 a missing registry read as parked" "rc=$RC"

run_wake "$REG_CORRUPT" katya
started katya && ok_t "U7 a corrupt registry body starts" \
  || bad_t "U7 corrupt JSON read as parked" "rc=$RC"

run_wake "$REG_STOPPED" katya nojq
started katya && ok_t "U8 a box with no jq starts (the fleet does not freeze on a missing tool)" \
  || bad_t "U8 absent jq read as parked" "rc=$RC"

run_wake '{"agents":{"katya":{"desiredState":"Stopped"}}}' katya
started katya && ok_t "U9 only an EXACT 'stopped' skips (a near-miss value starts)" \
  || bad_t "U9 a non-exact value read as parked" "rc=$RC"

run_wake '{"agents":{"katya":{"desiredState":null}}}' katya
started katya && ok_t "U10 an explicit null desiredState starts" \
  || bad_t "U10 null read as parked" "rc=$RC"

run_wake "$REG_STOPPED" nova
started nova && ok_t "U11 a running sibling in the SAME registry still starts" \
  || bad_t "U11 the skip is not scoped to the parked agent" "rc=$RC"

# The guard is scoped to the START, deliberately: a nudge into an agent that is
# already running is not a resurrection, and stopping it is the supervisor's job.
run_wake "$REG_STOPPED" katya "" active
if ! started katya && (( RC == 0 )) && ! noted; then
  ok_t "U12 a parked-but-RUNNING agent is neither started nor skipped — the guard covers the start only"
else
  bad_t "U12 the guard fired on an already-active unit" "rc=$RC log=$(cat "$WORK/hb.log")"
fi

# --- the note is throttled, and the throttle expires -------------------------
: > "$WORK/state/wake-parked.katya.skipped"
run_wake "$REG_STOPPED" katya
if (( RC == 4 )) && ! noted; then
  ok_t "U13 a second skip inside the hour is still a skip, but does not re-log (96 lines/day is not a signal)"
else
  bad_t "U13 the per-agent note is not throttled" "rc=$RC log=$(cat "$WORK/hb.log")"
fi
touch -d '2 hours ago' "$WORK/state/wake-parked.katya.skipped"
run_wake "$REG_STOPPED" katya
if (( RC == 4 )) && noted; then
  ok_t "U14 the throttle EXPIRES — a park that outlives the window is re-stated, not forgotten"
else
  bad_t "U14 the throttle never expires" "rc=$RC log=$(cat "$WORK/hb.log")"
fi
rm -f "$WORK/state/wake-parked.katya.skipped"

# --- the note names BOTH exits ------------------------------------------------
run_wake "$REG_STOPPED" katya
note="$(cat "$WORK/hb.log")"
if grep -q "5dive agent start katya" <<<"$note" && grep -qE "task park|reassign" <<<"$note"; then
  ok_t "U15 the note names BOTH exits — clear the park, or move the row off the parked seat"
else
  bad_t "U15 the note names one exit or none" "a bare 'skipped' reads as a decision already taken for the operator: $note"
fi
if grep -q "stays todo" <<<"$note"; then
  ok_t "U16 the note says what happened to the WORK — the row is still owed, not dropped"
else
  bad_t "U16 the note is silent about the todo" "$note"
fi

# --- the sibling inventory is moved off its wrong verdict ---------------------
if grep -qE '^\s*\[src/cmd_heartbeat\.sh\]=GUARDED\s*$' "$SIB"; then
  ok_t "A1 the DIVE-4399 inventory now carries src/cmd_heartbeat.sh as GUARDED, not AUTOMATIC-RESIDUAL"
else
  bad_t "A1 the inventory still records the pre-fix verdict" \
        "$(grep -n 'cmd_heartbeat' "$SIB" | head -3)"
fi
if grep -q 'heartbeat_wake_parked_agent_unit.sh' "$SIB"; then
  ok_t "A2 the inventory points at the behavioural proof, so its presence-grep is not read as sufficient"
else
  bad_t "A2 the inventory's A2 grep stands alone for this file" \
        "cmd_heartbeat.sh contained 'desiredState' while it was resurrecting a parked agent — the grep passes vacuously without this pointer"
fi

echo; echo "$PASS passed, $FAIL failed"; SUMMARY_PRINTED=1
[[ "$FAIL" == 0 ]] || exit 1
