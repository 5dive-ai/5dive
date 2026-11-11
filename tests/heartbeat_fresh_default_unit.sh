#!/usr/bin/env bash
# DIVE-8189 — a worker seat with no human chat starts each task fresh by
# default: heartbeat enrolment picks fresh=on from the org chart.
#
# lodar, 2026-11-11 (forwarded from his other box): his worker and reviewer
# seats were not fresh, because only a hand-typed `heartbeat on <seat> --fresh`
# made them so. The REAL cmd_heartbeat_on / cmd_org_set / _hb_fresh_default run
# against a scratch registry + tasks.db; only require_root/ensure_state are
# stubbed. Reserved-fake seat names only.
#
# Arms:
#   F1 reports to an agent + channels=none          -> fresh on, reason printed
#   F2 reports to an agent + telegram               -> fresh off
#   F3 pinned reviewer (review_mode='seat:<name>')   -> fresh on
#   F4 explicit --no-fresh wins over F1's default   -> fresh off
#   F5 an existing enrolment keeps its mode on a re-run with no flag
#   F6 org set re-derives a DEFAULT-sourced mode, never an explicit one
#   F7 codex seat stays off even when the chart says on
#   F8 org root (reports to no agent)               -> fresh off
#   C1-C3 `agent create`: the enrolment passes --fresh/--no-fresh through, and
#         the line create prints after it names the mode and the reason
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not present"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }
TMP=$(mktemp -d)
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh cmd_heartbeat.sh \
         cmd_agent_create.sh; do
  source "$SRC/$f"
done
set +e
export STATE_DIR="$TMP" TASKS_DIR="$TMP/tasks" TASKS_DB="$TMP/tasks/tasks.db"
export REGISTRY="$TMP/agents.json" REGISTRY_LOCK="$TMP/agents.lock"
export FIVEDIVE_HARNESS=1 FIVEDIVE_NO_HUMAN_SEND=1
mkdir -p "$TASKS_DIR"
require_root() { :; }
ensure_state() { :; }
audit_log() { :; }

pass=0; fail=0
ok_t()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
bad_t() { printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

cat > "$REGISTRY" <<'JSON'
{"schemaVersion":2,"agents":{
  "lead-x":   {"type":"claude","channels":"telegram"},
  "worker-x": {"type":"claude","channels":"none"},
  "chatty-x": {"type":"claude","channels":"telegram"},
  "review-x": {"type":"claude","channels":"telegram"},
  "pinned-x": {"type":"claude","channels":"none"},
  "codex-x":  {"type":"codex","channels":"none"},
  "moved-x":  {"type":"claude","channels":"none"},
  "manual-x": {"type":"claude","channels":"none"}
}}
JSON
tasks_db_init >/dev/null 2>&1 || { bad_t 'F0 tasks_db_init failed — every arm is vacuous'; exit 1; }
for s in worker-x chatty-x pinned-x codex-x; do
  cmd_org_set "$s" --manager=lead-x >/dev/null 2>&1
done
db "INSERT INTO tasks (title, review_mode) VALUES ('fixture row', 'seat:review-x');" 2>"$TMP/ins.err" \
  || bad_t 'F0 could not seed a pinned-reviewer row' "$(cat "$TMP/ins.err")"

fresh_of() { jq -r --arg n "$1" '.agents[$n].heartbeat.fresh' "$REGISTRY"; }
src_of()   { jq -r --arg n "$1" '.agents[$n].heartbeat.freshSource // ""' "$REGISTRY"; }
on() { ( with_registry_lock cmd_heartbeat_on "$@" ) 2>&1; }

# F1
out=$(on worker-x)
[[ "$(fresh_of worker-x)" == true && "$out" == *"fresh=on (reports to lead-x, no human channel)"* ]] \
  && ok_t 'F1 reports to an agent, no human channel -> fresh=on, and says why' \
  || bad_t 'F1' "fresh=$(fresh_of worker-x) out=$out"

# F2
out=$(on chatty-x)
[[ "$(fresh_of chatty-x)" == false && "$out" == *"fresh=off (reports to lead-x but holds a human chat (telegram))"* ]] \
  && ok_t 'F2 reports to an agent but holds a telegram chat -> fresh=off' \
  || bad_t 'F2' "fresh=$(fresh_of chatty-x) out=$out"

# F3
out=$(on review-x)
[[ "$(fresh_of review-x)" == true && "$out" == *"pinned reviewer on 1 row(s)"* ]] \
  && ok_t 'F3 pinned reviewer (a row names it with --review=<seat>) -> fresh=on' \
  || bad_t 'F3' "fresh=$(fresh_of review-x) out=$out"

# F4
out=$(on pinned-x --no-fresh)
[[ "$(fresh_of pinned-x)" == false && "$(src_of pinned-x)" == explicit && "$out" == *"fresh=off (--no-fresh)"* ]] \
  && ok_t 'F4 explicit --no-fresh wins over the org-chart default (on)' \
  || bad_t 'F4' "fresh=$(fresh_of pinned-x) src=$(src_of pinned-x) out=$out"

# F5: an existing enrolment is never changed by a flagless re-run
cmd_heartbeat_off pinned-x >/dev/null 2>&1
out=$(on pinned-x)
[[ "$(fresh_of pinned-x)" == false && "$out" == *"kept from the existing enrolment"* ]] \
  && ok_t 'F5 off + on with no flag keeps the existing mode (explicit off stays off)' \
  || bad_t 'F5' "fresh=$(fresh_of pinned-x) out=$out"
# ...and a pre-DIVE-8189 enrolment (fresh:false, no freshSource) also stays
jq '.agents["manual-x"].heartbeat = {enabled:true, everyMin:30, fresh:false, lastRunAt:0}' "$REGISTRY" > "$TMP/r" && mv "$TMP/r" "$REGISTRY"
cmd_org_set manual-x --manager=lead-x >/dev/null 2>&1
on manual-x >/dev/null
[[ "$(fresh_of manual-x)" == false ]] \
  && ok_t 'F5b a pre-existing enrolment is untouched by org set and by a flagless heartbeat on' \
  || bad_t 'F5b' "fresh=$(fresh_of manual-x)"

# F6: org set moves a default-sourced seat, never an explicit one
on moved-x >/dev/null
[[ "$(fresh_of moved-x)" == false ]] || bad_t 'F6 precondition: unparented seat should start off' "$(fresh_of moved-x)"
out=$(cmd_org_set moved-x --manager=lead-x 2>&1)
[[ "$(fresh_of moved-x)" == true && "$out" == *"fresh=on (reports to lead-x, no human channel)"* ]] \
  && ok_t 'F6 org set under an agent flips a default-sourced seat to fresh=on and says so' \
  || bad_t 'F6' "fresh=$(fresh_of moved-x) out=$out"
cmd_org_set pinned-x --manager=none >/dev/null 2>&1; cmd_org_set pinned-x --manager=lead-x >/dev/null 2>&1
[[ "$(fresh_of pinned-x)" == false ]] \
  && ok_t 'F6b org set never re-derives an explicit --no-fresh' \
  || bad_t 'F6b' "fresh=$(fresh_of pinned-x)"

# F7
out=$(on codex-x)
[[ "$(fresh_of codex-x)" == false && "$out" == *"codex seat"* ]] \
  && ok_t 'F7 codex seat stays fresh=off until a codex fresh wake works' \
  || bad_t 'F7' "fresh=$(fresh_of codex-x) out=$out"

# F8
out=$(on lead-x)
[[ "$(fresh_of lead-x)" == false && "$out" == *"reports to no agent"* ]] \
  && ok_t 'F8 an org root (reports to no agent) keeps its context: fresh=off' \
  || bad_t 'F8' "fresh=$(fresh_of lead-x) out=$out"

# C1: the line create prints, for the F1 seat (the body's exact wording)
out=$(_create_heartbeat_fresh_line worker-x 2>&1)
[[ "$out" == *"heartbeat fresh=on (reports to lead-x, no human channel)"* && "$out" == *"heartbeat on worker-x --no-fresh"* ]] \
  && ok_t 'C1 create prints "fresh=on (reports to lead-x, no human channel)" and the opt-out' \
  || bad_t 'C1' "out=$out"
out=$(_create_heartbeat_fresh_line lead-x 2>&1)
[[ "$out" == *"heartbeat fresh=off (reports to no agent)"* && "$out" == *"heartbeat on lead-x --fresh"* ]] \
  && ok_t 'C2 create prints "fresh=off (reports to no agent)" for a fresh seat with no lead, and the opt-in' \
  || bad_t 'C2' "out=$out"
# C3: cmd_create wires it — flags parsed, passed to the enrolment, line printed after it
body=$(declare -f cmd_create)
[[ "$body" == *'--fresh)'*'heartbeat_fresh="--fresh"'* && "$body" == *'--no-fresh)'*'heartbeat_fresh="--no-fresh"'* \
   && "$body" == *'_hb_args+=("$heartbeat_fresh")'* && "$body" == *'_create_heartbeat_fresh_line "$name"'* ]] \
  && ok_t 'C3 agent create parses --fresh/--no-fresh, hands it to the enrolment, and prints the reason line' \
  || bad_t 'C3 cmd_create is not wired' "$(grep -n 'heartbeat_fresh\|_create_heartbeat_fresh_line' src/cmd_agent_create.sh)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
