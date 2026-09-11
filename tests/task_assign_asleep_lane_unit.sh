#!/usr/bin/env bash
# TIER: nightly — builds a scratch board plus a registry fixture, same shape and
# cost as tests/task_doctor_unit.sh.
#
# DIVE-4269 — addressing a row to a REGISTERED seat that nothing wakes must SAY
# SO, at the moment the row is addressed.
#
# THE DEFECT. `_task_require_lane` checked roster membership only. "Registered"
# and "iterated by the heartbeat tick" are two different things, and only the
# first was ever checked — so `task assign <id> <seat>` reported plain success
# over a seat no tick will ever reach. On the customer box that filed this row
# that silence scaled: 30 of 37 seats unenrolled, 65 open rows addressed to them,
# every surface reporting success.
#
# WHY THE ARMS ARE SHAPED THIS WAY:
#   T1  assign to an unenrolled-but-registered seat WARNS and still SUCCEEDS.
#       Both halves are load-bearing. A human-driven seat is a legitimate target,
#       so a refusal would break the deliberate case to protect the accidental
#       one — the arm asserts the row actually moved.
#   T2  the warning names the seat and the one command that changes it.
#   T3  a seat with NO heartbeat key at all warns identically to one with
#       enabled=false. Those are the only two unwakeable shapes and the tick
#       cannot tell them apart, so neither may this.
#   T4  NEGATIVE: an enrolled seat produces NO warning. Without this arm a helper
#       that warned unconditionally would pass every arm above.
#   T5  NEGATIVE: an operator-STOPPED but heartbeat-enabled seat produces no
#       warning — the tick iterates it and STARTS the down unit (DIVE-4071), so
#       it is wakeable. This is the false-positive shape doctor already fixed
#       once; a second copy of the rule here would be how it comes back.
#   T6  `task add --assignee=` and `task verifier` warn too — one predicate, every
#       door onto the dispatch rail, because a row addressed at `add` time is
#       just as undispatchable as one addressed at `assign` time.
#   T7  DEGRADE: an unreadable registry warns about NOTHING. "Could not measure"
#       must never be rendered as "it is dead" — the failure direction the whole
#       doctor lane check is built around.
# Run: bash tests/task_assign_asleep_lane_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/task-assign-asleep.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init

# Fixture seats, not real names. `live` is enrolled; `zombie` carries no
# heartbeat key at all; `offhb` carries enabled=false; `stopped` is enrolled but
# operator-stopped (still wakeable — the tick starts the unit).
cat > "$TMP/agents.json" <<'JSON'
{"agents":{
  "live":   {"type":"claude","heartbeat":{"enabled":true}},
  "zombie": {"type":"claude"},
  "offhb":  {"type":"claude","heartbeat":{"enabled":false}},
  "stopped":{"type":"claude","heartbeat":{"enabled":true},"desiredState":"stopped"}
}}
JSON
reroster() { _TASK_ROSTER=""; _TASK_ROSTER_STATE=""; }
reroster

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
addt()  { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }

# Run a verb keeping BOTH streams apart: the advisory is `warn` (stderr), the
# envelope is `ok` (stdout). An arm that read them merged could not tell a
# warning from a refusal.
run() { ( "$@" ) >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?"; }
asgn_of() { db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=$1;"; }

ASLEEP='is a registered seat that NOTHING WAKES'

# ---- T1/T2: assign to an unenrolled seat warns AND succeeds ------------------
t1=$(addt --assignee=live -- "a row that will be re-addressed")
rc=$(run cmd_task_assign "$t1" zombie)
{ [[ "$rc" == "0" ]] && [[ "$(asgn_of "$t1")" == "zombie" ]] && grep -qF -- "$ASLEEP" "$TMP/err"; } \
  && ok_t "assign to an unenrolled-but-registered seat WARNS and still moves the row" \
  || bad_t "assign to an unenrolled seat" "rc=$rc assignee=$(asgn_of "$t1") err=$(cat "$TMP/err")"

{ grep -qF -- "zombie" "$TMP/err" && grep -qF -- "5dive heartbeat on zombie" "$TMP/err"; } \
  && ok_t "the warning names the seat and the exact command that enrols it" \
  || bad_t "warning is not actionable" "$(cat "$TMP/err")"

# ---- T3: enabled=false warns identically to a missing heartbeat key ---------
t3=$(addt --assignee=live -- "second row")
rc=$(run cmd_task_assign "$t3" offhb)
{ [[ "$rc" == "0" ]] && grep -qF -- "$ASLEEP" "$TMP/err"; } \
  && ok_t "heartbeat.enabled=false warns the same as no heartbeat key at all" \
  || bad_t "enabled=false did not warn" "rc=$rc err=$(cat "$TMP/err")"

# ---- T4: NEGATIVE — an enrolled seat says nothing ---------------------------
t4=$(addt --assignee=zombie -- "third row")
rc=$(run cmd_task_assign "$t4" live)
{ [[ "$rc" == "0" ]] && ! grep -qF -- "$ASLEEP" "$TMP/err"; } \
  && ok_t "an ENROLLED seat produces no warning (the arm that fails an unconditional warn)" \
  || bad_t "false positive on a live seat" "rc=$rc err=$(cat "$TMP/err")"

# ---- T5: NEGATIVE — operator-stopped but enabled is wakeable ----------------
rc=$(run cmd_task_assign "$t4" stopped)
{ [[ "$rc" == "0" ]] && ! grep -qF -- "$ASLEEP" "$TMP/err"; } \
  && ok_t "an operator-stopped but heartbeat-ENABLED seat is wakeable and produces no warning" \
  || bad_t "false positive on a stopped-but-enabled seat" "rc=$rc err=$(cat "$TMP/err")"

# ---- T6: every door onto the dispatch rail, not just `assign` ---------------
rc=$(run cmd_task_add --assignee=zombie -- "addressed asleep at filing time")
{ [[ "$rc" == "0" ]] && grep -qF -- "$ASLEEP" "$TMP/err"; } \
  && ok_t "task add --assignee=<asleep seat> warns at filing time too" \
  || bad_t "task add did not warn" "rc=$rc err=$(cat "$TMP/err")"

t6=$(addt --assignee=live -- "a row that gets an asleep grader")
rc=$(run cmd_task_verifier "$t6" offhb)
{ [[ "$rc" == "0" ]] && grep -qF -- "$ASLEEP" "$TMP/err"; } \
  && ok_t "task verifier <id> <asleep seat> warns — a delivery lands there and strands" \
  || bad_t "task verifier did not warn" "rc=$rc err=$(cat "$TMP/err")"

# ---- T7: DEGRADE — an unreadable registry accuses nobody --------------------
mv "$TMP/agents.json" "$TMP/agents.json.hidden"
reroster
t7=$(addt --assignee=live -- "row addressed with no registry")
rc=$(run cmd_task_assign "$t7" live)
{ ! grep -qF -- "$ASLEEP" "$TMP/err"; } \
  && ok_t "an unreadable registry warns about nothing — 'could not measure' is never 'it is dead'" \
  || bad_t "accused a lane with no registry to read" "$(cat "$TMP/err")"
mv "$TMP/agents.json.hidden" "$TMP/agents.json"
reroster

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
