#!/usr/bin/env bash
# OSS-32 isolated unit harness for `5dive objective status` — the v0.10
# self-steering status surface (one read-only inspectable view).
#
# Same isolation posture as objective_unit.sh / objective_replan_unit.sh: source
# the src/ libs, point STATE_DIR at a throwaway temp dir (the binary hard-sets
# STATE_DIR so a subprocess test would leak), seed the OSS-26 + OSS-27 store
# directly, and assert every field of the surface + the branch logic:
#   - fields 1-3 (target/current/trend/gap, gap SIGNED per direction)
#   - field 5 (current cycle = MAX(cycle_no) + outcome)
#   - field 4 (active roles = open originated-task assignees)
#   - field 6 (verified THIS cycle = originated+this-cycle+status=done ONLY —
#     the anti-Goodhart field; never the planner cycle's self-reported outcome)
#   - field 7 (spend = SUM(cycle tokens) vs ceiling)
#   - field 8 (next gate = latest gated cycle whose anchor is a PENDING gate;
#     answered gate -> none; terminal outcome -> stop_reason)
#   - read-only contract, text-mode smoke, arg/not-found errors.
# Run: bash tests/objective_status_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/objective-status-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_objective.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; tests deliberately expect non-zero exits

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run()   { ( "$@" ) 2>/dev/null; }

# Seed a task row directly (project 'dive' is seeded by init; ident is UNIQUE).
seed_task() { # ident title status assignee orig_obj orig_cycle need_type need_answered
  db "INSERT INTO tasks(ident,project_key,title,status,assignee,kind,
         originated_by_objective,originated_cycle,need_type,need_answered_at)
      VALUES($(sqlq "$1"),'dive',$(sqlq "$2"),$(sqlq "$3"),$(sqlq "$4"),'standard',
             $5,$6,$(sqlq_or_null "$7"),$(sqlq_or_null "$8"));"
}
seed_cycle() { # obj_id cycle_no reading_value gated gate_anchor tokens outcome
  db "INSERT INTO objective_cycles(objective_id,cycle_no,reading_value,gated,gate_anchor,tokens_spent,outcome)
      VALUES($1,$2,$3,$4,$(sqlq_or_null "$5"),$6,$(sqlq "$7"));"
}

# ============================================================================
# Objective A: 'conv' — up/%, mid-flight, cycle 2 gated with a PENDING gate.
# ============================================================================
run cmd_objective_add "conv" --metric-cmd="echo 7" --target=10 --direction=up --unit=% \
    --budget=100000 --planner=dev >/dev/null
CONV=$(db "SELECT id FROM objectives WHERE name='conv';")

db "INSERT INTO objective_readings(objective_id,value,rc) VALUES($CONV,5,0);"
db "INSERT INTO objective_readings(objective_id,value,rc) VALUES($CONV,7,0);"   # cur=7 prev=5 -> up, gap=3
seed_cycle "$CONV" 1 5 0 "" 12000 "applied"
seed_cycle "$CONV" 2 7 1 "CONV-9" 8000 "gated"                                   # spend total 20000
seed_task "CONV-1" "landing test"   "done"        "marketing" "$CONV" 2 "" ""    # verified THIS cycle
seed_task "CONV-2" "ad variant"     "in_progress" "dev"       "$CONV" 2 "" ""    # open -> active role
seed_task "CONV-8" "old done"       "done"        "marketing" "$CONV" 1 "" ""    # done but PRIOR cycle -> not counted
seed_task "CONV-9" "Replan: conv #2" "blocked"    "main"      "$CONV" 2 "decision" ""  # PENDING gate anchor

out=$(run cmd_objective_status "conv"); rc=$?
[[ $rc -eq 0 ]] && printf '%s' "$out" | jq -e '.data.current==7 and .data.gap==3 and .data.trend=="up"' >/dev/null \
  && ok_t "fields 1-3: current/trend/gap (up)" || bad_t "current/trend/gap" "rc=$rc out=$out"

printf '%s' "$out" | jq -e '.data.cycle==2 and .data.cycle_outcome=="gated"' >/dev/null \
  && ok_t "field 5: current cycle + outcome" || bad_t "current cycle" "$out"

printf '%s' "$out" | jq -e '.data.verified_this_cycle==1' >/dev/null \
  && ok_t "field 6: verified THIS cycle only (prior-cycle done excluded)" || bad_t "verified this cycle" "$out"

# verified_total = cumulative done originated across ALL cycles (CONV-1 cycle2 + CONV-8 cycle1),
# so a steady cycle never hides prior real progress while verified_this_cycle stays per-cycle (DIVE-1441).
printf '%s' "$out" | jq -e '.data.verified_total==2' >/dev/null \
  && ok_t "field 6b: verified_total = cumulative done originated (includes prior cycle)" || bad_t "verified total" "$out"

printf '%s' "$out" | jq -e '.data.originated_open==2' >/dev/null \
  && ok_t "originated_open counts only non-terminal originated tasks" || bad_t "originated_open" "$out"

printf '%s' "$out" | jq -e '(.data.active_roles|sort)==["dev","main"]' >/dev/null \
  && ok_t "field 4: active roles = open originated assignees" || bad_t "active roles" "$out"

printf '%s' "$out" | jq -e '.data.spend==20000 and .data.ceiling_per_cycle==40000 and .data.budget==100000' >/dev/null \
  && ok_t "field 7: spend vs ceiling/budget" || bad_t "spend" "$out"

printf '%s' "$out" | jq -e '.data.next_gate=="CONV-9" and .data.stop_reason==null' >/dev/null \
  && ok_t "field 8: pending gate -> next_gate" || bad_t "next gate (pending)" "$out"

# --- answer the gate: anchor no longer a PENDING gate -> next_gate null ---
db "UPDATE tasks SET need_answered_at=datetime('now') WHERE ident='CONV-9';"
out=$(run cmd_objective_status "conv")
printf '%s' "$out" | jq -e '.data.next_gate==null' >/dev/null \
  && ok_t "answered gate -> next_gate null" || bad_t "answered gate" "$out"

# ============================================================================
# Objective B: 'cost' — down direction, gap must be SIGNED the other way.
# ============================================================================
run cmd_objective_add "cost" --metric-cmd="echo 120" --target=100 --direction=down --unit=$ >/dev/null
COST=$(db "SELECT id FROM objectives WHERE name='cost';")
db "INSERT INTO objective_readings(objective_id,value,rc) VALUES($COST,120,0);"
out=$(run cmd_objective_status "cost")
printf '%s' "$out" | jq -e '.data.gap==20 and .data.trend=="new"' >/dev/null \
  && ok_t "gap signed per direction (down: cur-target)" || bad_t "down gap" "$out"

# ============================================================================
# Objective C: 'done-obj' — terminal cycle, no pending gate -> stop_reason.
# ============================================================================
run cmd_objective_add "done-obj" --metric-cmd="echo 100" --target=100 --direction=up >/dev/null
DONE=$(db "SELECT id FROM objectives WHERE name='done-obj';")
db "INSERT INTO objective_readings(objective_id,value,rc) VALUES($DONE,100,0);"
seed_cycle "$DONE" 1 100 0 "" 5000 "target_reached"
out=$(run cmd_objective_status "done-obj")
printf '%s' "$out" | jq -e '.data.next_gate==null and .data.stop_reason=="target_reached"' >/dev/null \
  && ok_t "terminal outcome -> stop_reason (never a silent blank)" || bad_t "stop reason" "$out"

# ============================================================================
# text-mode smoke + error paths
# ============================================================================
JSON_MODE=0
out=$( (cmd_objective_status "conv") 2>/dev/null )
printf '%s' "$out" | grep -q '^objective: conv' && printf '%s' "$out" | grep -q '^next gate:' \
  && ok_t "text dashboard renders" || bad_t "text mode" "$out"
JSON_MODE=1

out=$(run cmd_objective_status); rc=$?
[[ $rc -eq "$E_USAGE" ]] && ok_t "missing name -> E_USAGE" || bad_t "missing name" "rc=$rc"

out=$(run cmd_objective_status "nope"); rc=$?
[[ $rc -eq "$E_NOT_FOUND" ]] && ok_t "unknown objective -> E_NOT_FOUND" || bad_t "unknown obj" "rc=$rc"

# read-only contract: status must NOT have written any reading or cycle row.
r_before=$(db "SELECT COUNT(*) FROM objective_readings;")
c_before=$(db "SELECT COUNT(*) FROM objective_cycles;")
run cmd_objective_status "conv" >/dev/null
r_after=$(db "SELECT COUNT(*) FROM objective_readings;")
c_after=$(db "SELECT COUNT(*) FROM objective_cycles;")
[[ "$r_before" == "$r_after" && "$c_before" == "$c_after" ]] \
  && ok_t "read-only: status writes no readings/cycles" || bad_t "read-only" "r:$r_before/$r_after c:$c_before/$c_after"

echo "----"
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
