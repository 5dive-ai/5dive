#!/usr/bin/env bash
# doctor's registry lane must not print [ok] over a seat the LAUNCHER already
# declared degraded.
#
# The defect: the per-seat registry check ended at "entry + user + env file all
# present" — three PRESENCE facts about the box. A seat can hold all three and
# still have been launched without a usable credential, which is exactly what
# happened on a customer box with 35 seats: `5dive-agent-start` logged "claude
# credential absent after 45s wait — launched DEGRADED and cannot reach its
# provider", `agent info` said `startup: degraded` / `state: degraded`, `agent
# auth status` said `needs_login` — and `5dive doctor`, the one command an
# operator runs to ask "is this box well?", said [ok] for that seat on every
# nightly restart for a day. The only other trace was a memory/consolidate error
# that blamed the provider API.
#
# The verdict already exists and is already persisted: `_agent_startup_credential_health`
# reads the seat-owned `.5dive-cred-seed-failed` breadcrumb the launcher writes
# and `agent info`/`agent list` already derive their `startup:` word from it.
# doctor simply never asked. So this harness grades the JOIN, not a new probe.
#
# Arms:
#   - a seat whose home carries the breadcrumb is ERROR, and the launcher's own
#     reason is in the message (an operator must not have to go to the journal)
#   - the message names the recovery commands
#   - the same seat without the breadcrumb is ok — the non-vacuity control that
#     makes the arm above a discrimination rather than a constant
#   - a home doctor cannot read (`unknown|...`) stays ok: doctor must not
#     manufacture an error out of its own permission boundary
#   - MUTANT: strip the join back out and the degraded seat goes green again
#
# Runs against a synthetic AGENT_HOME_ROOT and a throwaway registry: no root, no
# systemd, no network, no real agent home or live registry touched.
# Run: bash tests/doctor_registry_degraded_seat_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/doctor-registry-degraded.XXXXXX)"
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
# The lane under test calls ACROSS a module boundary. In the shipped bundle that
# is an autoload stub; a harness that sources src/ directly has to load the
# provider itself. Sourcing it (rather than stubbing it) is deliberate: the
# breadcrumb reader is half of the behaviour this file is about, so a stub would
# grade the harness's idea of a degraded seat instead of the launcher's.
# shellcheck disable=SC1091
source src/cmd_agent.sh
# shellcheck disable=SC1091
source src/cmd_doctor.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

if ! declare -f _agent_startup_credential_health >/dev/null; then
  bad_t "src/cmd_agent.sh provides the startup-credential reader" \
        "the provider did not load; every arm below would be vacuous"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi
ok_t "src/cmd_agent.sh provides the startup-credential reader (arms below are not vacuous)"

# ---- seams -------------------------------------------------------------------
# Everything the lane reads before it reaches the per-seat verdict, and nothing
# else. doctor_check_orphan_seats is stubbed because it enumerates the HOST's
# passwd/group/units; it has its own harness (tests/doctor_orphan_seats_unit.sh).
export AGENT_HOME_ROOT="$TMP/homes"
mkdir -p "$AGENT_HOME_ROOT" "$ENV_DIR"
require_root()              { :; }
doctor_check_orphan_seats() { :; }
id() {                      # every agent-<name> user this fixture declares exists
  if [[ "${1:-}" == "-u" ]]; then
    [[ " $KNOWN_USERS " == *" ${2:-} "* ]] && { printf '4242\n'; return 0; }
    return 1
  fi
  command id "$@"
}
KNOWN_USERS=""

# seat <name> <clear|degraded|noreason|nohome> — build one registry seat.
seat() {
  local name="$1" kind="$2" home
  home="$AGENT_HOME_ROOT/agent-$name"
  KNOWN_USERS+=" agent-$name"
  : >"$ENV_DIR/${name}.env"
  case "$kind" in
    nohome) return 0 ;;                       # unreadable from here -> unknown|
    *)      mkdir -p "$home" ;;
  esac
  case "$kind" in
    degraded) printf '%s\n' "$DEGRADED_REASON" >"$home/.5dive-cred-seed-failed" ;;
    noreason) : >"$home/.5dive-cred-seed-failed" ;;
  esac
}

DEGRADED_REASON='claude credential absent after 45s wait — launched DEGRADED and cannot reach its provider; supply a credential and restart'

write_registry() {          # write_registry <name>...
  local n; local reg='{"schemaVersion":2,"agents":{}}'
  for n in "$@"; do
    reg=$(jq -c --arg n "$n" '.agents[$n] = {type:"claude"}' <<<"$reg")
  done
  printf '%s\n' "$reg" >"$REGISTRY"
}

run_lane() {                # -> the registry rows, one JSON object per line
  DOCTOR_CHECKS='[]'
  cmd_doctor --category=registry >/dev/null 2>&1
  jq -c '.[] | select(.category == "registry")' <<<"$DOCTOR_CHECKS"
}

row_for() {                 # row_for <seat-name>
  run_lane | jq -c --arg n "agent:$1" 'select(.name == $n)'
}

# ---- fixture: three seats, identical but for the launcher's breadcrumb -------
seat quiet    clear
seat degraded degraded
seat opaque   nohome
write_registry quiet degraded opaque

# 1. THE ACCEPTING ARM. The launcher said DEGRADED; doctor must say error.
row=$(row_for degraded)
jq -e '.severity == "error"' <<<"$row" >/dev/null \
  && ok_t "a seat the launcher marked DEGRADED is an ERROR, not [ok]" \
  || bad_t "a seat the launcher marked DEGRADED is an ERROR" "$row"

# 2. The launcher's OWN reason travels with the row. Without it an operator is
#    sent back to the journal, which can be shorter-lived than the fault.
jq -e --arg r "$DEGRADED_REASON" '.message | contains($r)' <<<"$row" >/dev/null \
  && ok_t "the launcher's reason is carried in the message verbatim" \
  || bad_t "the launcher's reason is carried in the message" "$row"

# 3. The row names what to run. A red row with no next step is a red row an
#    operator reads twice and acts on once.
jq -e '.message | test("agent auth status --agent=degraded") and test("restart")' <<<"$row" >/dev/null \
  && ok_t "the row names the recovery commands (auth status, then restart)" \
  || bad_t "the row names the recovery commands" "$row"

# 4. NON-VACUITY CONTROL. Same registry, same user, same env file, no breadcrumb:
#    the lane must still be able to say ok, or arm 1 grades a constant.
row=$(row_for quiet)
jq -e '.severity == "ok" and (.message | test("entry \\+ user \\+ env file all present"))' <<<"$row" >/dev/null \
  && ok_t "a seat with no breadcrumb keeps the ok line (control: the lane can say ok)" \
  || bad_t "a seat with no breadcrumb keeps the ok line" "$row"

# 5. A home we cannot LOOK at is not a seat we know is broken. `unknown|...`
#    must not become an error — doctor's own permission boundary is not evidence
#    about the seat, and the unit harnesses run unprivileged.
row=$(row_for opaque)
jq -e '.severity == "ok"' <<<"$row" >/dev/null \
  && ok_t "an unreadable home reads unknown and keeps ok (no error manufactured)" \
  || bad_t "an unreadable home keeps ok" "$row"

# 6. An EMPTY breadcrumb is `unknown|`, not `degraded|` — the reader draws that
#    line and the lane must respect it rather than treating presence as verdict.
seat hollow noreason
write_registry quiet degraded opaque hollow
row=$(row_for hollow)
jq -e '.severity == "ok"' <<<"$row" >/dev/null \
  && ok_t "an empty breadcrumb is unknown, not degraded (presence is not a verdict)" \
  || bad_t "an empty breadcrumb is unknown, not degraded" "$row"

# 7. The other seats are unaffected — this is a per-seat verdict, not a fleet one.
rows=$(run_lane)
n=$(jq -s '[.[] | select(.severity == "error") | select(.name | startswith("agent:"))] | length' <<<"$rows")
[[ "$n" == "1" ]] \
  && ok_t "exactly one of the four seats is red (a per-seat verdict, not a fleet one)" \
  || bad_t "exactly one of the four seats is red" "errors=$n rows=$(tr '\n' ' ' <<<"$rows")"

# =============================================================================
# MUTANT — take the join back out and the degraded seat goes green again.
# =============================================================================
# BEFORE/AFTER, because "the call is gone" is also true of a sed that matched
# nothing, and that would make the arm below pass against any tree at all.
ORIG="$(declare -f cmd_doctor)"
MUT="$(printf '%s\n' "$ORIG" | sed 's/^\([[:space:]]*\)seat_health=\$(_agent_startup_credential_health .*$/\1seat_health=""/')"
grep -q '_agent_startup_credential_health' <<<"$ORIG" \
  && ok_t "M0a: BEFORE — the shipped lane really does read the launcher's verdict" \
  || bad_t "M0a: the shipped lane reads the launcher's verdict" "not found; the mutant arm below is vacuous"
{ [[ "$MUT" != "$ORIG" ]] && ! grep -q '_agent_startup_credential_health' <<<"$MUT"; } \
  && ok_t "M0b: AFTER — the mutation really removed it (the sed matched)" \
  || bad_t "M0b: the mutation took" "the sed did not match; the mutant is not mutated"

eval "$MUT"
row=$(row_for degraded)
jq -e '.severity == "ok"' <<<"$row" >/dev/null \
  && ok_t "M1: MUTANT — without the join the degraded seat reads [ok] again (arms 1-3 are red on it)" \
  || bad_t "M1: the mutant reproduces the defect" "$row"

eval "$ORIG"
row=$(row_for degraded)
jq -e '.severity == "error"' <<<"$row" >/dev/null \
  && ok_t "M2: RESTORE took — the shipped lane is back and reds again" \
  || bad_t "M2: restore took" "$row"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
