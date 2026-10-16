#!/usr/bin/env bash
# doctor's registry lane must name a seat that is PARKED in the registry
# (desiredState=stopped) while its unit is RUNNING (DIVE-6382).
#
# The defect: the pending-restart sweep holds every owed update restart for such
# a seat (DIVE-4033) and says so only in the heartbeat log. With the supervisor
# off nothing reconciles it, and on a customer box one seat ran a deleted Claude
# Code build through every release for 19 days while `agent list` said ready and
# doctor said nothing.
#
# Arms:
#   1. stopped + active unit -> one WARN naming the seat, the owed restart's age
#      and both exits (`agent stop` / `agent start`)
#   2. stopped + active unit with no marker -> WARN says "no restart owed"
#   3. NEGATIVE: running + active unit -> no finding
#   4. NEGATIVE: stopped + inactive unit (a real park) -> no finding
#   5. none parked-and-running -> one ok line
#   M. MUTANT: with the check deleted, arm 1 goes red
#
# Synthetic registry, pending-restart dir and a stubbed `systemctl`: no root, no
# systemd, no live registry touched.
# Run: bash tests/doctor_parked_running_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/doctor-parked-running.XXXXXX)"
export STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/lib/state.sh
# shellcheck disable=SC1091
source src/lib/registry.sh
# The owed-restart age is read through the sweep's own marker reader; sourced,
# not stubbed, so the harness grades the real marker format.
# shellcheck disable=SC1091
source src/cmd_selfupdate.sh
# shellcheck disable=SC1091
source src/cmd_doctor.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

declare -F _pending_restart_marked_at >/dev/null \
  && ok_t "src/cmd_selfupdate.sh provides the marker reader (age arms are not vacuous)" \
  || bad_t "src/cmd_selfupdate.sh provides the marker reader" "every age arm below would be vacuous"

# ---- seams -------------------------------------------------------------------
export PENDING_RESTART_DIR="$TMP/pending-restart"
mkdir -p "$PENDING_RESTART_DIR" "$ENV_DIR"
require_root()              { :; }
doctor_check_orphan_seats() { :; }
_agent_startup_credential_health() { printf 'clear|\n'; }
id() { [[ "${1:-}" == "-u" ]] && { printf '4242\n'; return 0; }; command id "$@"; }
ACTIVE_SEATS=""             # seat names whose unit `systemctl is-active` reports up
systemctl() {               # only `is-active --quiet <unit>` is answered
  if [[ "${1:-}" == "is-active" ]]; then
    local s="${*: -1}"
    s="${s#5dive-agent?}"; s="${s%.service}"
    [[ " $ACTIVE_SEATS " == *" $s "* ]]; return
  fi
  return 0
}

# write_registry <name>:<desiredState>...
write_registry() {
  local spec reg='{"schemaVersion":'"$REGISTRY_SCHEMA_VERSION"',"agents":{}}'
  for spec in "$@"; do
    reg=$(jq -c --arg n "${spec%%:*}" --arg d "${spec#*:}" \
      '.agents[$n] = {type:"claude", desiredState:$d}' <<<"$reg")
    : >"$ENV_DIR/${spec%%:*}.env"
  done
  printf '%s\n' "$reg" >"$REGISTRY"
}

mark() {                    # mark <name> <seconds-ago>
  printf 'marked_at=%s\nreason=nightly box update (while parked)\n' \
    "$(( $(date +%s) - $2 ))" >"$PENDING_RESTART_DIR/$1"
}

rows() {                    # -> parked-running rows, one JSON object per line
  DOCTOR_CHECKS='[]'
  cmd_doctor --category=registry >/dev/null 2>&1
  jq -c '.[] | select(.category == "registry" and .name == "parked-running")' <<<"$DOCTOR_CHECKS"
}

# ---- fixture -----------------------------------------------------------------
# alex: parked + running + owed restart 11d 3h (the reported shape)
# bea:  parked + running, no marker
# cal:  running + running (normal)
# dan:  parked + unit down (a real park)
write_registry alex:stopped bea:stopped cal:running dan:stopped
mark alex $(( 11 * 86400 + 3 * 3600 + 120 ))
ACTIVE_SEATS="alex bea cal"

out=$(rows)
warns=$(jq -s '[.[] | select(.severity == "warn")]' <<<"$out")

# 1. The reported shape.
r=$(jq -c '.[] | select(.message | test("agent .alex. is RUNNING"))' <<<"$warns")
[[ -n "$r" ]] \
  && ok_t "1a: a parked seat with an active unit is a WARN that names the seat" \
  || bad_t "1a: parked+running seat is a WARN" "$out"
jq -e '.message | test("owed for 11d 3h")' <<<"$r" >/dev/null 2>&1 \
  && ok_t "1b: the WARN carries the owed restart's age (11d 3h)" \
  || bad_t "1b: the WARN carries the restart age" "$r"
jq -e '.message | test("5dive agent stop alex") and test("5dive agent start alex")' <<<"$r" >/dev/null 2>&1 \
  && ok_t "1c: the WARN names both exits (agent stop / agent start)" \
  || bad_t "1c: the WARN names both exits" "$r"

# 2. No marker -> says so rather than inventing an age.
r=$(jq -c '.[] | select(.message | test("agent .bea. is RUNNING"))' <<<"$warns")
jq -e '.message | test("no restart owed")' <<<"$r" >/dev/null 2>&1 \
  && ok_t "2: a parked+running seat with no marker reads 'no restart owed'" \
  || bad_t "2: no marker reads 'no restart owed'" "${r:-<no row>} / $out"

# 3 + 4. Negative controls.
jq -e '[.[] | select(.message | test("agent .cal."))] | length == 0' <<<"$warns" >/dev/null \
  && ok_t "3: NEGATIVE — desiredState=running with an active unit gives no finding" \
  || bad_t "3: running+active gives no finding" "$out"
jq -e '[.[] | select(.message | test("agent .dan."))] | length == 0' <<<"$warns" >/dev/null \
  && ok_t "4: NEGATIVE — a real park (stopped, unit down) gives no finding" \
  || bad_t "4: stopped+inactive gives no finding" "$out"
[[ "$(jq 'length' <<<"$warns")" == "2" ]] \
  && ok_t "exactly two WARNs for the four seats (alex, bea)" \
  || bad_t "exactly two WARNs" "$out"

# 5. Clean box -> one ok line.
ACTIVE_SEATS="cal"
out=$(rows)
jq -s -e 'length == 1 and .[0].severity == "ok"' <<<"$out" >/dev/null \
  && ok_t "5: nothing parked-and-running gives one ok line" \
  || bad_t "5: clean box gives one ok line" "$out"

# =============================================================================
# MUTANT — delete the check and arm 1 goes red.
# =============================================================================
ACTIVE_SEATS="alex bea cal"
ORIG="$(declare -f cmd_doctor)"
MUT="$(printf '%s\n' "$ORIG" | sed '/doctor_check_parked_running/d')"
grep -q 'doctor_check_parked_running' <<<"$ORIG" \
  && ok_t "M0a: BEFORE — the shipped registry lane calls the check" \
  || bad_t "M0a: the shipped lane calls the check" "not found; the mutant arm is vacuous"
{ [[ "$MUT" != "$ORIG" ]] && ! grep -q 'doctor_check_parked_running' <<<"$MUT"; } \
  && ok_t "M0b: AFTER — the mutation really removed it" \
  || bad_t "M0b: the mutation took" "the sed matched nothing"
eval "$MUT"
out=$(rows)
[[ -z "$out" ]] \
  && ok_t "M1: MUTANT — without the check the parked+running seat is invisible again (arm 1 red)" \
  || bad_t "M1: the mutant reproduces the defect" "$out"
eval "$ORIG"
out=$(rows)
jq -s -e '[.[] | select(.severity == "warn")] | length == 2' <<<"$out" >/dev/null \
  && ok_t "M2: RESTORE — the check is back and warns again" \
  || bad_t "M2: restore took" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
