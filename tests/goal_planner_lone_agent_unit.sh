#!/usr/bin/env bash
# DIVE-7380 — `goal add "<outcome>"` on a box nobody has charted yet.
#
# The README's goal row, run on a fresh box by init-smoke's readme arm, exited 3:
# "no --planner given and no project lead / org coordinator to fall back to".
# `init` makes ONE agent and places it nowhere on the org chart, so every tier of
# `_task_resolve_coordinator` misses. `_task_resolve_planner` adds one rung for
# planner call sites only: empty chart + exactly one agent -> that agent.
#
# Arms: the lone agent plans (resolver + the real `goal add` path); two agents on
# an empty chart stay unresolved (no guessing); a built chart keeps its own
# answer (the rung never fires over a chart); an empty registry stays empty; and
# the coordinator itself is untouched (an unassigned row still has no owner).
# Run: bash tests/goal_planner_lone_agent_unit.sh  (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/goal-lone-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_goal.sh cmd_loop.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
REGISTRY="$STATE_DIR/agents.json"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run() { ( set -e; "$@" ) 2>&1; }
eq_t() { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "got=[$2] want=[$3]"; }

agents() { local j='{"agents":{'; local n; for n in "$@"; do j+="\"$n\":{\"type\":\"claude\"},"; done; printf '%s}}' "${j%,}" > "$REGISTRY"; }

# ---- (1) fresh box: empty chart, one agent -> that agent plans ----
agents my-agent
eq_t "empty chart + one agent: the planner is that agent" "$(_task_resolve_planner "")" "my-agent"
eq_t "the coordinator itself is unchanged (still none on an empty chart)" "$(_task_resolve_coordinator "")" ""

# ---- (2) the README's command on that box no longer refuses ----
_org_resolve_assignee() { printf '%s' "my-agent"; }
out=$(run cmd_goal_add --dry-run -- "Write the launch post"); rc=$?
planner=$(db "SELECT j.planner FROM goal_jobs j ORDER BY rowid DESC LIMIT 1;" 2>/dev/null)
if [[ $rc -eq 0 ]] && ! grep -q "no --planner given" <<<"$out"; then
  ok_t "goal add with no --planner on a fresh box returns a job (rc=0)"
else
  bad_t "goal add with no --planner on a fresh box returns a job (rc=0)" "rc=$rc out=$out"
fi
grep -q '"planner":"my-agent"\|my-agent' <<<"$out$planner" \
  && ok_t "the job is planned by the lone agent" \
  || bad_t "the job is planned by the lone agent" "out=$out planner=$planner"

# ---- (3) two agents, empty chart: no guess ----
agents my-agent ceo
eq_t "empty chart + two agents: still unresolved (no guessing)" "$(_task_resolve_planner "")" ""
out=$(run cmd_goal_add --dry-run -- "Ambiguous"); rc=$?
[[ $rc -ne 0 ]] && grep -q "no --planner given" <<<"$out" \
  && ok_t "goal add still refuses with two uncharted agents" \
  || bad_t "goal add still refuses with two uncharted agents" "rc=$rc out=$out"

# ---- (4) a built chart keeps its own answer ----
agents my-agent
db "INSERT INTO agents_org(name, reports_to) VALUES ('lead', NULL);"
eq_t "a charted lone root wins over the lone-agent rung" "$(_task_resolve_planner "")" "lead"
db "INSERT INTO agents_org(name, reports_to) VALUES ('lead2', NULL);"
eq_t "a built multi-root chart is not overridden by the rung" "$(_task_resolve_planner "")" ""
db "DELETE FROM agents_org;"

# ---- (5) no agents at all ----
agents
eq_t "empty registry: nothing to fall back to" "$(_task_resolve_planner "")" ""

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
