#!/usr/bin/env bash
# DIVE-1349 isolated unit harness for the goals-page 502 fix (wake-on-spawn +
# bounded --wait). The 502 came from `goal add` behind one HTTP request holding
# its socket for the 30-min default --wait while the planner agent was never
# woken. Asserts:
#   * _loop_wake_agent is a safe no-op for a non-enrolled agent (no crash, rc 0)
#     — the best-effort contract that lets a wake degrade to heartbeat pickup.
#   * _goal_invoke_planner passes an EXPLICIT bounded --wait (150s default,
#     GOAL_PLANNER_WAIT_SECS override) so the plan returns in-window, never a 502.
#   * a bare `loop spawn --wait` honors the bounded LOOP_SPAWN_WAIT_DEFAULT and
#     returns a clean timeout instead of hanging 30 minutes.
# Run: bash tests/loop_wake_wait_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/loop-wake-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_goal.sh cmd_loop.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- T1: _loop_wake_agent no-ops safely for a non-enrolled agent -------------
# (there is no unix user agent-nobody-xyz, so the id -u guard short-circuits).
out=$(_loop_wake_agent "nobody-xyz-$$" 1 "DIVE-1" 2>&1); rc=$?
[[ $rc -eq 0 && -z "$out" ]] \
  && ok_t "_loop_wake_agent is a safe no-op for a non-enrolled agent (rc=0, silent)" \
  || bad_t "wake guard" "rc=$rc out=$out"

# --- T2: _goal_invoke_planner passes an explicit bounded --wait -------------
CAP="$TMP/captured"
cmd_loop_spawn() {  # stub — capture args (to a FILE; caller runs us in $()), return done+plan
  printf '%s' "$*" >"$CAP"
  printf '%s' '{"ok":true,"data":{"status":"done","result":"{\"project\":{\"name\":\"P\",\"goal\":\"g\"},\"tasks\":[{\"local_id\":\"t1\",\"title\":\"x\",\"assignee_or_role\":\"alice\"}]}"}}'
}
plan=$(_goal_invoke_planner "ship it" "alice" 40000 12)
grep -q -- '--wait=150' "$CAP" \
  && ok_t "goal planner spawn carries explicit --wait=150 (bounded, in-window)" \
  || bad_t "goal wait flag" "captured: $(cat "$CAP")"
grep -qE -- '--wait( |$)' "$CAP" && bad_t "goal wait flag" "still passes bare --wait" || ok_t "no bare (30-min-default) --wait on the goal path"

# override honored
GOAL_PLANNER_WAIT_SECS=90 _goal_invoke_planner "x" "alice" 40000 12 >/dev/null
grep -q -- '--wait=90' "$CAP" \
  && ok_t "GOAL_PLANNER_WAIT_SECS overrides the planner wait" || bad_t "wait override" "captured: $(cat "$CAP")"
unset -f cmd_loop_spawn
source "$SRC/cmd_loop.sh"   # restore the real spawn for T3

# --- T3: bare `loop spawn --wait` honors the bounded default (no 30-min hang) -
# No agent ever works the backing task, so with a 1s bound the poll must return a
# terminal (timeout-mapped) status in ~seconds, proving the default is bounded.
start=$(date +%s)
out=$(LOOP_SPAWN_WAIT_DEFAULT=1 LOOP_POLL_SECS=1 cmd_loop_spawn --agent=nobody-xyz --prompt="hang" --wait 2>/dev/null)
elapsed=$(( $(date +%s) - start ))
status=$(printf '%s' "$out" | jq -r '.data.status' 2>/dev/null)
[[ "$elapsed" -le 15 && -n "$status" && "$status" != "running" ]] \
  && ok_t "bare --wait honors LOOP_SPAWN_WAIT_DEFAULT (returned '$status' in ${elapsed}s, not a 30-min hang)" \
  || bad_t "bounded wait default" "elapsed=${elapsed}s status=$status"

echo "-----"
echo "loop_wake_wait_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
