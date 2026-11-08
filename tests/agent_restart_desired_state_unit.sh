#!/usr/bin/env bash
# DIVE-7916 — `agent restart` on a stopped seat must leave the registry agreeing
# with the unit (desiredState=running), and ONLY the operator verb may do that.
#
# The defect: cmd_restart ran `systemctl restart` and never touched
# desiredState, so `agent stop X; agent restart X` left a RUNNING unit with
# desiredState=stopped. DIVE-4033's park guard (`_agent_is_parked`) then held
# every nightly update restart for X forever, while `agent list` said ready —
# one customer seat ran an old release through eight nights.
#
# Arms:
#   1. stop, then the verb main.sh routes `agent restart` to -> desiredState=
#      running, unit restarted, and the update sweep's own park predicate says
#      "not parked" (so the sweep bounces it; no "restart HELD" for X)
#   2. NEGATIVE CONTROL: the pre-fix tree (origin/main's lifecycle file, read
#      through git) leaves desiredState=stopped after the same sequence
#   3. supervisor rung 4 (`_sup_act_exec <x> restart`) on a stopped seat does
#      NOT change desiredState; neither does `agent recover`'s root half
#   4. `agent restart --defer` records the same intent as the plain verb
#   5. a FAILED systemctl restart records nothing and exits non-zero
#   6. structural: main.sh routes `agent restart` through cmd_restart_verb
#
# Stubbed systemctl / systemd-run, synthetic registry: no root, no systemd, no
# live registry touched.
# Run: bash tests/agent_restart_desired_state_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/agent-restart-desired.XXXXXX)"
export STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"

# shellcheck disable=SC1091
source src/header.sh
for f in lib/error_codes.sh lib/output.sh lib/validation.sh lib/state.sh \
         lib/registry.sh cmd_selfupdate.sh cmd_agent_runtime.sh \
         cmd_agent_lifecycle.sh cmd_supervisor.sh cmd_account.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e

STATE_DIR="$TMP/state"
REGISTRY="$STATE_DIR/agents.json"
JSON_MODE=1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

SEAT=iris
UNIT="5dive-agent@${SEAT}.service"

# ---- seams -------------------------------------------------------------------
SYSLOG="$TMP/systemctl.log"
SYSTEMCTL_RC=0
systemctl()   { printf 'systemctl %s\n' "$*" >> "$SYSLOG"; return "$SYSTEMCTL_RC"; }
systemd-run() { printf 'systemd-run %s\n' "$*" >> "$SYSLOG"; return 0; }
chown()       { :; }   # registry_write/ensure_state chown to root:claude; not root here
chmod()       { :; }
require_root() { :; }
ensure_state() { :; }  # root-only dir/perm setup; the lock file is created below
ENV_DIR="$TMP/env"
REGISTRY_LOCK="$TMP/registry.lock"
FIVEDIVE_REGISTRY_LOCK_WAIT=5
: > "$REGISTRY_LOCK"
normalize_restart_profile_perms() { :; }
restart_push_openclaw_state()     { :; }

seed() { # <desiredState|absent>
  if [[ "$1" == absent ]]; then
    printf '{"agents":{"%s":{"type":"claude"}}}\n' "$SEAT" > "$REGISTRY"
  else
    printf '{"agents":{"%s":{"type":"claude","desiredState":"%s"}}}\n' "$SEAT" "$1" > "$REGISTRY"
  fi
  : > "$SYSLOG"
}
desired() { jq -r --arg n "$SEAT" '.agents[$n].desiredState // "absent"' "$REGISTRY"; }
restarted() { grep -qF "systemctl restart ${UNIT}" "$SYSLOG"; }

for fn in cmd_restart_verb cmd_restart cmd_stop _agent_is_parked _sup_act_exec _agent_recover_do; do
  declare -F "$fn" >/dev/null \
    && ok_t "$fn is defined (arms below are not vacuous)" \
    || bad_t "$fn is defined" "an arm below would grade nothing"
done

# ---- 1. stop -> restart (the operator verb) ---------------------------------
seed running
( cmd_stop "$SEAT" ) >/dev/null 2>&1
[[ "$(desired)" == stopped ]] \
  && ok_t "precondition: agent stop records desiredState=stopped" \
  || bad_t "precondition: agent stop" "got $(desired)"
: > "$SYSLOG"
( with_registry_lock cmd_restart_verb "$SEAT" ) >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && "$(desired)" == running ]] \
  && ok_t "arm 1: agent stop; agent restart -> desiredState=running" \
  || bad_t "arm 1: restart records running" "rc=$rc desired=$(desired)"
restarted \
  && ok_t "arm 1: the unit was restarted" \
  || bad_t "arm 1: unit restarted" "$(cat "$SYSLOG")"
! _agent_is_parked "$SEAT" \
  && ok_t "arm 1: the update sweep's park predicate says NOT parked (sweep bounces it, no 'restart HELD')" \
  || bad_t "arm 1: _agent_is_parked" "the sweep would still hold the seat's restart"

# ---- 2. negative control: the pre-fix tree ----------------------------------
PRE="$TMP/prefix_lifecycle.sh"
PRE_REF="${PREFIX_REF:-origin/main}"
if git show "${PRE_REF}:src/cmd_agent_lifecycle.sh" > "$PRE" 2>/dev/null \
   && ! grep -q 'cmd_restart_verb' "$PRE"; then
  seed running
  (
    # shellcheck source=/dev/null
    source "$PRE"
    normalize_restart_profile_perms() { :; }
    restart_push_openclaw_state()     { :; }
    cmd_stop "$SEAT"
    with_registry_lock cmd_restart "$SEAT"   # what pre-fix main.sh routed to
  ) >/dev/null 2>&1
  [[ "$(desired)" == stopped ]] \
    && ok_t "arm 2: on the pre-fix tree ($PRE_REF) the same sequence leaves desiredState=stopped (red)" \
    || bad_t "arm 2: negative control" "pre-fix tree gave $(desired) — arm 1 would not discriminate"
else
  printf '# arm 2 skipped: %s already carries the fix or is unreadable (set PREFIX_REF to a pre-fix ref)\n' "$PRE_REF"
fi

# ---- 3. internal callers never un-park --------------------------------------
seed stopped
_sup_act_exec "$SEAT" restart unused >/dev/null 2>&1; rc=$?
[[ "$(desired)" == stopped ]] \
  && ok_t "arm 3: supervisor rung 4 on a stopped seat leaves desiredState=stopped (rc=$rc)" \
  || bad_t "arm 3: supervisor rung 4 un-parked the seat" "desired=$(desired)"
restarted \
  && ok_t "arm 3: rung 4 still bounced the unit (the arm reached cmd_restart)" \
  || bad_t "arm 3: rung 4 reached cmd_restart" "$(cat "$SYSLOG")"

seed stopped
( _agent_recover_do "$SEAT" ) >/dev/null 2>&1
[[ "$(desired)" == stopped ]] && restarted \
  && ok_t "arm 3: agent recover's root half bounces the unit and leaves desiredState=stopped" \
  || bad_t "arm 3: agent recover" "desired=$(desired) log=$(cat "$SYSLOG")"

# ---- 4. --defer --------------------------------------------------------------
seed stopped
( with_registry_lock cmd_restart_verb "$SEAT" --defer ) >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && "$(desired)" == running ]] \
  && ok_t "arm 4: agent restart --defer -> desiredState=running" \
  || bad_t "arm 4: --defer records running" "rc=$rc desired=$(desired)"
grep -q "^systemd-run .*systemctl restart ${UNIT}\$" "$SYSLOG" \
  && ok_t "arm 4: --defer scheduled the fixed restart" \
  || bad_t "arm 4: deferred restart scheduled" "$(cat "$SYSLOG")"

seed absent
( with_registry_lock cmd_restart_verb "$SEAT" ) >/dev/null 2>&1
[[ "$(desired)" == running ]] \
  && ok_t "arm 4b: a seat with no recorded intent ends up running (same as agent start)" \
  || bad_t "arm 4b: absent intent" "desired=$(desired)"

# ---- 5. a failed restart records nothing ------------------------------------
seed stopped; SYSTEMCTL_RC=1
( with_registry_lock cmd_restart_verb "$SEAT" ) >/dev/null 2>&1; rc=$?
SYSTEMCTL_RC=0
[[ $rc -ne 0 && "$(desired)" == stopped ]] && restarted \
  && ok_t "arm 5: a failed systemctl restart exits $rc and leaves desiredState=stopped" \
  || bad_t "arm 5: failed restart" "rc=$rc desired=$(desired)"

# ---- 6. routing --------------------------------------------------------------
ROUTE=$(grep -A2 -E '^[[:space:]]+restart\)$' src/main.sh | grep -E 'with_registry_lock cmd_restart' || true)
[[ "$ROUTE" == *"with_registry_lock cmd_restart_verb "* ]] \
  && ok_t "arm 6: main.sh routes 'agent restart' through cmd_restart_verb" \
  || bad_t "arm 6: main.sh routing" "got: ${ROUTE:-<none>}"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
