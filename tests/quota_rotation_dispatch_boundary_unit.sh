#!/usr/bin/env bash
# DIVE-4055: task-boundary account rotation.  The current profile must be
# measured near its wall, the destination must have live headroom, and a
# successful flip must defer `_hb_wake` so the first turn cannot race the
# scheduled service bounce.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/registry.sh cmd_account.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e

TMP=$(mktemp -d /tmp/quota-boundary-unit.XXXXXX)
WAKE_CALLS="$TMP/wakes"; CONFIG_CALLS="$TMP/config"; : >"$WAKE_CALLS"; : >"$CONFIG_CALLS"
JSON_MODE=1

PASS=0; FAIL=0
t() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL - %s — expected [%s], got [%s]\n' "$1" "$2" "$3"
  fi
}

REG='{"agents":{"seat":{"type":"claude","authProfile":"full","rotation":{"enabled":true,"accounts":["full","roomy"],"cooldowns":{}}}}}'
SOURCE_STATE=near
DEST_ROOMY=1
registry_read() { printf '%s' "$REG"; }
registry_write() { cat >/dev/null; }
require_root() { :; }
ensure_state() { :; }
with_registry_lock() { "$@"; }
account_near_wall_state() { printf '%s' "$SOURCE_STATE"; }
account_has_live_headroom() { [[ "$DEST_ROOMY" == 1 && "$1" == roomy ]]; }
cmd_config() { printf '%s\n' "$*" >>"$CONFIG_CALLS"; }

# Model the production call-site rule with the production helper: success means
# return before first-turn delivery; every no-op keeps the existing wake path.
attempt_dispatch() {
  if _hb_rotate_at_dispatch_boundary seat "$REG"; then
    return 0
  fi
  printf 'first-turn\n' >>"$WAKE_CALLS"
}

attempt_dispatch
t "near-wall boundary selects the measured-headroom profile" \
  "seat set auth-profile=roomy" "$(tail -1 "$CONFIG_CALLS")"
t "successful boundary rotation defers the first turn" "0" "$(wc -l <"$WAKE_CALLS" | tr -d ' ')"
t "helper reports the exact boundary switch" "full->roomy" \
  "${_HB_BOUNDARY_ROTATION_FROM}->${_HB_BOUNDARY_ROTATION_TO}"

SOURCE_STATE=clear
attempt_dispatch
t "clear current account keeps the ordinary first-turn path" "1" "$(wc -l <"$WAKE_CALLS" | tr -d ' ')"

SOURCE_STATE=near
DEST_ROOMY=0
attempt_dispatch
t "no measured destination does not pretend a switch happened" "1" \
  "$([[ "$_HB_BOUNDARY_ROTATION_REASON" == no\ eligible\ account* ]] && printf 1 || printf 0)"
t "no measured destination falls through to the existing wall/alert path" "2" "$(wc -l <"$WAKE_CALLS" | tr -d ' ')"

# Placement fence: the real heartbeat call must precede `_hb_wake`; a helper
# that works but is called after submission would still rotate mid-task.
ROT_LINE=$(grep -n '_hb_rotate_at_dispatch_boundary "\$name" "\$reg"' src/cmd_heartbeat.sh | tail -1 | cut -d: -f1)
WAKE_LINE=$(grep -n 'if _hb_wake "\$name"' src/cmd_heartbeat.sh | tail -1 | cut -d: -f1)
if [[ "$ROT_LINE" =~ ^[0-9]+$ && "$WAKE_LINE" =~ ^[0-9]+$ ]] && (( ROT_LINE < WAKE_LINE )); then
  PASS=$((PASS+1)); printf 'ok   - production boundary check is before _hb_wake\n'
else
  FAIL=$((FAIL+1)); printf 'FAIL - production boundary check must precede _hb_wake (rotate=%s wake=%s)\n' "$ROT_LINE" "$WAKE_LINE"
fi

printf '\nquota_rotation_dispatch_boundary_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
