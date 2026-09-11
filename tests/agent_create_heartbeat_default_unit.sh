#!/usr/bin/env bash
# TIER: core — a pure static read of one source file, no fixtures, no root.
#
# DIVE-4269 — `agent create` ENROLS the new seat in the heartbeat by default.
#
# WHY THIS HARNESS IS STATIC, SAID PLAINLY SO NOBODY MISREADS IT AS COVERAGE.
# The behaviour it guards lives in the middle of a real provision (a unix user,
# a systemd unit, a credential). That is a live-box smoke, not a unit, and this
# file is NOT a substitute for one — it cannot observe an enrolment. What it CAN
# do is fail the three inversions that would silently undo the change and that a
# reviewer reading a 3000-line diff would not catch:
#
#   T1  the two flags are PARSED. `--no-heartbeat` is the opt-out the whole
#       default rests on; dropped from the case arm it becomes "unknown flag"
#       and the only escape from the new default is a usage error.
#   T2  the enrolment call is SUBSHELL-wrapped. `cmd_heartbeat_on` ends in `ok`
#       and guards itself with `require_root`/`require_agent` — all three EXIT.
#       Called inline, a successful provision would end at its last step, and it
#       would end SILENTLY (via `ok`). This is the arm that matters: the failure
#       it prevents looks like a clean create right up to the missing summary.
#   T3  the self-check reports `--no-heartbeat` as a CHOICE and an unexplained
#       absence as an ISSUE. Collapsing them back into one branch re-creates the
#       warning-nobody-reads that this row exists to end.
#   T4  the usage string offers the opt-out. A default with an undiscoverable
#       escape hatch is a default with no escape hatch.
# Run: bash tests/agent_create_heartbeat_default_unit.sh   (no root, no network)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src/cmd_agent_create.sh

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

[[ -r "$SRC" ]] || { printf 'FAIL - %s is not readable\n' "$SRC"; exit 1; }

# T1
{ grep -qF -- '--no-heartbeat)' "$SRC" && grep -qF -- '--heartbeat-every=*)' "$SRC"; } \
  && ok_t "both flags are parsed by the case arm (--no-heartbeat, --heartbeat-every=)" \
  || bad_t "flag not parsed" "$(grep -n -- '--no-heartbeat\|--heartbeat-every' "$SRC")"

# T2 — the call must sit inside ( ), on one line, so an exit inside it is a status
call=$(grep -n -- 'cmd_heartbeat_on "${_hb_args\[@\]}"' "$SRC")
{ [[ -n "$call" ]] && grep -qF -- 'if ( with_registry_lock cmd_heartbeat_on "${_hb_args[@]}" )' "$SRC"; } \
  && ok_t "the enrolment call is subshell-wrapped, so ok/require_root cannot end the create" \
  || bad_t "enrolment call is not subshell-wrapped" "${call:-<no call site found>}"

# T3 — three distinct branches: enrolled / opted out / unexplained absence
{ grep -qF -- 'elif (( no_heartbeat )); then' "$SRC" \
    && grep -qF -- "_hc_issues+=(\"no heartbeat (agent is ASLEEP" "$SRC"; } \
  && ok_t "the self-check separates 'off by request' from 'no heartbeat', instead of one branch for both" \
  || bad_t "self-check collapsed the choice and the defect" "$(grep -n 'no_heartbeat ))\|_hc_issues+=("no heartbeat' "$SRC")"

# T4
grep -qF -- '[--no-heartbeat]' "$SRC" \
  && ok_t "the usage string names the opt-out" \
  || bad_t "usage does not mention --no-heartbeat" "$(grep -n 'usage: 5dive agent create' "$SRC" | head -1)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
