#!/usr/bin/env bash
# DIVE-4071 — task doctor's dead-lane predicate must model the wake path
# `_hb_wake` actually has. The tick's population is `heartbeat.enabled == true`
# ALONE (cmd_heartbeat.sh) and `_hb_wake` never reads `desiredState` — it STARTS a
# down unit. So `_task_doctor_lane_wakeable` must key on heartbeat.enabled only.
#
# THE DISCRIMINATING ARM this file exists for: a seat with desiredState=stopped
# AND heartbeat.enabled=true is WOKEN by the tick (its unit is started), so it is
# NOT a dead lane. The predicate used to fold desiredState=stopped into "not
# wakeable" and manufacture a FALSE dead-lane whose remedy (`task assign`)
# re-points a row off a seat that is actively working it.
# Run: bash tests/task_doctor_lane_wakeable_unit.sh (no root, no network)
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/doctor-lane-wakeable.XXXXXX)"
export STATE_DIR="$TMP"
REG="$STATE_DIR/agents.json"

# shellcheck disable=SC1091
source src/task/doctor.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected rc=$2, got rc=$3"; fi; }

set_reg() { printf '%s' "$1" >"$REG"; }
probe()   { _task_doctor_lane_wakeable "$1"; echo $?; }

# ARM 1 — enabled, desiredState absent: the ordinary live seat.
set_reg '{"agents":{"a":{"type":"claude","heartbeat":{"enabled":true}}}}'
eq_t "enabled + no desiredState is wakeable" 0 "$(probe a)"

# ARM 2 — THE DISCRIMINATING ARM. enabled AND desiredState=stopped: the tick
# iterates it (enabled==true) and _hb_wake starts the stopped unit -> wakeable.
# Before DIVE-4071 this returned rc=1 and printed a false dead-lane.
set_reg '{"agents":{"a":{"type":"claude","heartbeat":{"enabled":true},"desiredState":"stopped"}}}'
eq_t "enabled + desiredState=stopped is wakeable (not a dead lane)" 0 "$(probe a)"

# ARM 3 — heartbeat disabled: genuinely outside the tick's population -> dead lane.
set_reg '{"agents":{"a":{"type":"claude","heartbeat":{"enabled":false}}}}'
eq_t "heartbeat disabled is a dead lane" 1 "$(probe a)"

# ARM 4 — heartbeat key absent entirely: also never iterated -> dead lane.
set_reg '{"agents":{"a":{"type":"claude"}}}'
eq_t "no heartbeat key is a dead lane" 1 "$(probe a)"

# ARM 5 — an agent absent from the registry reads as not-enabled -> dead lane.
set_reg '{"agents":{"b":{"type":"claude","heartbeat":{"enabled":true}}}}'
eq_t "agent absent from registry is a dead lane" 1 "$(probe a)"

# ARM 6 — desiredState=stopped WITHOUT an enabled heartbeat stays a dead lane:
# the fix must not turn desiredState into a wakeability SIGNAL, only stop it being
# a disqualifier. Absent enabled -> false -> dead lane.
set_reg '{"agents":{"a":{"type":"claude","desiredState":"stopped"}}}'
eq_t "desiredState=stopped with no enabled heartbeat is still a dead lane" 1 "$(probe a)"

# ARM 7 — registry unreadable is UNKNOWN (rc=2), never silently "dead".
rm -f "$REG"
eq_t "missing registry is unknown, not dead" 2 "$(probe a)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
