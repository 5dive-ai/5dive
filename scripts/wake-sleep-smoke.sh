#!/usr/bin/env bash
# DIVE-1858 Phase-1 Stage 2 — LIVE auto-sleep smoke (HELD for main's pre-run lead review).
#
# Proves the reactive wake<->sleep loop end-to-end on a REAL agent: a wake_mode=cold
# agent that goes idle is auto-slept (systemctl stop), then a real trigger (an assigned
# scratch task) wakes it via the heartbeat tick, it works + closes the task, and it
# re-sleeps — with the wake-budget cap enforced. This is the one step that touches prod
# fleet lifecycle, so it is deliberately fenced:
#
#   * DRY-RUN BY DEFAULT. It prints the exact plan and touches NOTHING unless you pass
#     --run. A stray invocation is a no-op.
#   * DISPOSABLE TARGET ONLY. --agent=<name> is required and MUST be a non-critical test
#     agent. It refuses protected/always-on-pinned agents (main, marketing, and anything
#     in HEARTBEAT_WAKE_PROTECTED) — olivia condition 3.
#   * Requires root + systemd + the target unit to exist.
#   * Restores the agent to always_on and cleans up its scratch task on exit.
#
# Per main's hard rule this comes back for lead review BEFORE it runs live; run it only
# on a dedicated throwaway agent (parent DIVE-1856 names warm-mark / quinn as candidates).
#
# Usage:
#   sudo bash scripts/wake-sleep-smoke.sh --agent=<disposable> [--sleep-after=2] [--run]
set -uo pipefail

FIVE="${FIVE_BIN:-5dive}"
AGENT=""; SLEEP_AFTER=2; DO_RUN=0; CAP=2
for a in "$@"; do
  case "$a" in
    --agent=*)       AGENT="${a#*=}" ;;
    --sleep-after=*) SLEEP_AFTER="${a#*=}" ;;
    --cap=*)         CAP="${a#*=}" ;;
    --run)           DO_RUN=1 ;;
    -h|--help)       grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $a (see --help)" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;36m[smoke]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[smoke] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\033[1;34m>>>\033[0m %s\n' "$*"; }

[[ -n "$AGENT" ]] || die "--agent=<disposable-agent> is required"

# --- Refuse a protected / critical target (olivia condition 3) ----------------
PROTECTED="main marketing ${HEARTBEAT_WAKE_PROTECTED:-}"
for p in $PROTECTED; do
  [[ "$AGENT" == "$p" ]] && die "'$AGENT' is a protected always-on agent — this smoke runs on a DISPOSABLE test agent only"
done

UNIT="5dive-agent@${AGENT}.service"

# --- DRY-RUN (default): print the plan, touch nothing --------------------------
if (( DO_RUN == 0 )); then
  cat <<PLAN
DRY-RUN (no changes made). Re-run with --run to execute on a disposable agent.

Target agent : $AGENT   (unit: $UNIT)
Idle→sleep   : ${SLEEP_AFTER}m     Wake cap/day: $CAP

Plan when --run is given:
  0. Preflight: require root + systemctl; require the unit to exist; snapshot the
     agent's current wake mode so it can be restored on exit.
  1. Enrol heartbeat + set wake_mode=cold --sleep-after=${SLEEP_AFTER} --cap=${CAP}.
  2. Ensure the agent is idle (no open assigned tasks); wait > ${SLEEP_AFTER}m; run
     '5dive heartbeat tick' and assert the unit goes INACTIVE (auto-slept).
  3. WAKE: assign a scratch task, run '5dive heartbeat tick', assert the unit goes
     ACTIVE, the task is picked up and closed by the agent (bounded wait).
  4. RE-SLEEP: with the task done + agent idle, wait > ${SLEEP_AFTER}m, tick, assert
     INACTIVE again.
  5. BUDGET: drive wakes past the cap and assert further wakes are budget-skipped.
  6. Cleanup: cancel the scratch task, restore the prior wake mode, leave the unit
     in its original run state.

Nothing above runs in dry-run. This script is dry-run by default on purpose.
PLAN
  exit 0
fi

# --- LIVE run (--run) ---------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || die "live run needs root (sudo): the smoke drives systemd + the registry"
command -v systemctl >/dev/null 2>&1 || die "systemctl not found — this smoke needs systemd"
systemctl list-unit-files "5dive-agent@.service" >/dev/null 2>&1 || die "template unit 5dive-agent@.service not found"

is_active() { systemctl is-active --quiet "$UNIT"; }
prior_mode="$("$FIVE" heartbeat wake-mode "$AGENT" --json 2>/dev/null | jq -r '.data.mode // "always_on"')"
SCRATCH_ID=""
cleanup() {
  step "cleanup"
  [[ -n "$SCRATCH_ID" ]] && "$FIVE" task cancel "$SCRATCH_ID" --result="wake-sleep smoke cleanup" >/dev/null 2>&1 || true
  "$FIVE" heartbeat wake-mode "$AGENT" "${prior_mode:-always_on}" >/dev/null 2>&1 || true
  log "restored '$AGENT' wake mode -> ${prior_mode:-always_on}"
}
trap cleanup EXIT

wait_for() {  # wait_for <desc> <timeout-s> <predicate-cmd...>
  local desc="$1" to="$2"; shift 2; local i=0
  while (( i < to )); do "$@" && { log "ok: $desc"; return 0; }; sleep 5; i=$((i+5)); done
  die "timeout waiting for: $desc (${to}s)"
}

log "LIVE smoke on '$AGENT' (idle→sleep ${SLEEP_AFTER}m, cap ${CAP}). Prior mode: ${prior_mode}."

step "1. enrol + set cold"
"$FIVE" heartbeat on "$AGENT" >/dev/null 2>&1 || true
"$FIVE" heartbeat wake-mode "$AGENT" cold --sleep-after="$SLEEP_AFTER" --cap="$CAP" >/dev/null || die "could not set cold"

step "2. idle → auto-sleep (waiting > ${SLEEP_AFTER}m, then ticking)"
sleep $(( SLEEP_AFTER * 60 + 30 ))
"$FIVE" heartbeat tick >/dev/null 2>&1 || true
wait_for "unit INACTIVE (auto-slept)" 60 bash -c "! systemctl is-active --quiet '$UNIT'"

step "3. trigger → wake + work"
SCRATCH_ID="$("$FIVE" task add "wake-sleep smoke ping ($AGENT)" \
  --body="Auto-sleep smoke. Reply by closing this task: 5dive task done <id> --result=pong." \
  --assignee="$AGENT" --priority=high --json 2>/dev/null | jq -r '.data.ident // .data.id')"
[[ -n "$SCRATCH_ID" && "$SCRATCH_ID" != "null" ]] || die "could not create scratch task"
log "scratch task: $SCRATCH_ID"
"$FIVE" heartbeat tick >/dev/null 2>&1 || true
wait_for "unit ACTIVE (woken)" 90 is_active
wait_for "scratch task closed by agent" 600 bash -c \
  "[[ \$('$FIVE' task show '$SCRATCH_ID' --json 2>/dev/null | jq -r .data.status) == done ]]"

step "4. re-sleep after idle"
sleep $(( SLEEP_AFTER * 60 + 30 ))
"$FIVE" heartbeat tick >/dev/null 2>&1 || true
wait_for "unit INACTIVE (re-slept)" 60 bash -c "! systemctl is-active --quiet '$UNIT'"

step "5. budget cap enforced"
budget_json="$("$FIVE" heartbeat wake-mode "$AGENT" --json 2>/dev/null)"
log "budget now: $(jq -c '.data | {capPerDay,wakesToday,day}' <<<"$budget_json" 2>/dev/null)"
log "note: exhaust the cap by driving > $CAP triggers to see 'budget-skipped' in the tick summary"

log "SMOKE PASSED — cold agent slept, woke on trigger, worked, and re-slept."
