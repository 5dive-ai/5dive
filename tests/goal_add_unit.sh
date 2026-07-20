#!/usr/bin/env bash
# DIVE-984 isolated unit harness for `5dive goal add` (goal decomposition v1).
#
# Sources the src/ libs directly and points STATE_DIR at a throwaway temp dir so
# it NEVER touches the live shared tasks.db (same posture as loop_spawn_unit.sh).
# Exercises the validated-materialize pipeline WITHOUT a live planner agent by
# feeding plans via --plan=<json>. Asserts: schema/shape reject, over-cap reject,
# cycle reject, depth reject, tier-lowering reject, unresolvable-role reject,
# --dry-run creates nothing, below-threshold materializes (tasks+deps), over-cap
# threshold files exactly ONE gate, T2 plan gates even with --yes.
# Run: bash tests/goal_add_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/goal-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_goal.sh cmd_loop.sh; do
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

# run a verb in a subshell so its `fail`->exit can't kill the harness; capture
# stdout+status.
run() { ( "$@" ) 2>/dev/null; }

# ---- a well-formed below-threshold, all-low plan (2 tasks, 1 edge) ----
PLAN_OK='{"project":{"key":"widget","name":"Ship widget","goal":"Ship the widget"},
  "tasks":[
    {"local_id":"t1","title":"Design widget","assignee_or_role":"dev","risk":"low"},
    {"local_id":"t2","title":"Build widget","assignee_or_role":"dev","depends_on":["t1"],
     "acceptance":"tests pass","verify":"npm test","verifier":"qa","risk":"low"}]}'

# ---- (1) validation: shape/schema reject ----
out=$(run cmd_goal_add --plan='{"nope":1}' -- "x"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q "project" \
  && ok_t "malformed plan (no tasks/project) rejected" \
  || bad_t "malformed plan rejected" "rc=$rc out=$out"

# ---- (2) over-cap reject (not silent truncate; names the overflow) ----
BIG='{"project":{"name":"n","goal":"g"},"tasks":['
for i in 1 2 3; do BIG+="{\"local_id\":\"t$i\",\"title\":\"T$i\",\"assignee_or_role\":\"dev\"},"; done
BIG="${BIG%,}]}"
out=$(run cmd_goal_add --plan="$BIG" --max-tasks=2 -- "x"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -qi "cap" \
  && ok_t "over --max-tasks cap rejected" \
  || bad_t "over-cap rejected" "rc=$rc out=$out"

# ---- (3) cycle reject ----
CYC='{"project":{"name":"n","goal":"g"},"tasks":[
  {"local_id":"a","title":"A","assignee_or_role":"dev","depends_on":["b"]},
  {"local_id":"b","title":"B","assignee_or_role":"dev","depends_on":["a"]}]}'
out=$(run cmd_goal_add --plan="$CYC" -- "x"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -qi "cycle" \
  && ok_t "cyclic dependency graph rejected" \
  || bad_t "cycle rejected" "rc=$rc out=$out"

# ---- (3b) unknown depends_on reject ----
UNK='{"project":{"name":"n","goal":"g"},"tasks":[
  {"local_id":"a","title":"A","assignee_or_role":"dev","depends_on":["ghost"]}]}'
out=$(run cmd_goal_add --plan="$UNK" -- "x"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -qi "unknown" \
  && ok_t "unknown depends_on rejected" \
  || bad_t "unknown dep rejected" "rc=$rc out=$out"

# ---- (4) depth-cap reject (chain of 4 with --depth-cap=2) ----
CHAIN='{"project":{"name":"n","goal":"g"},"tasks":[
  {"local_id":"t1","title":"1","assignee_or_role":"dev"},
  {"local_id":"t2","title":"2","assignee_or_role":"dev","depends_on":["t1"]},
  {"local_id":"t3","title":"3","assignee_or_role":"dev","depends_on":["t2"]},
  {"local_id":"t4","title":"4","assignee_or_role":"dev","depends_on":["t3"]}]}'
out=$(run cmd_goal_add --plan="$CHAIN" --depth-cap=2 -- "x"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -qi "depth" \
  && ok_t "over --depth-cap rejected" \
  || bad_t "depth rejected" "rc=$rc out=$out"

# ---- (5) tier-lowering reject (text implies destructive but risk=low) ----
LOWER='{"project":{"name":"n","goal":"g"},"tasks":[
  {"local_id":"t1","title":"Delete the production database and wipe backups","assignee_or_role":"dev","risk":"low"}]}'
out=$(run cmd_goal_add --plan="$LOWER" -- "x"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -qi "lower a tier" \
  && ok_t "tier-lowered task (low label, T2 text) rejected" \
  || bad_t "tier-lower rejected" "rc=$rc out=$out"

# ---- (5b) unresolvable role reject ----
BADROLE='{"project":{"name":"n","goal":"g"},"tasks":[
  {"local_id":"t1","title":"do it","assignee_or_role":"role:doesnotexist"}]}'
out=$(run cmd_goal_add --plan="$BADROLE" -- "x"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -qi "resolve" \
  && ok_t "unresolvable role rejected" \
  || bad_t "bad role rejected" "rc=$rc out=$out"

# ---- (6) --dry-run creates nothing ----
before=$(db "SELECT COUNT(*) FROM tasks;")
out=$(run cmd_goal_add --plan="$PLAN_OK" --dry-run -- "ship widget"); rc=$?
after=$(db "SELECT COUNT(*) FROM tasks;")
projn=$(db "SELECT COUNT(*) FROM projects WHERE key='widget';")
[[ $rc -eq 0 && "$before" == "$after" && "$projn" == "0" ]] \
  && printf '%s' "$out" | jq -e '.data.dryRun==true' >/dev/null 2>&1 \
  && ok_t "--dry-run creates no tasks and no project" \
  || bad_t "dry-run creates nothing" "rc=$rc before=$before after=$after proj=$projn out=$out"

# ---- (7) below-threshold materializes (tasks + dep edge + leaf fields) ----
out=$(run cmd_goal_add --plan="$PLAN_OK" --project=widget -- "ship widget"); rc=$?
mat=$(printf '%s' "$out" | jq -r '.data.materialized // false' 2>/dev/null)
ntasks=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='widget' AND kind='standard';")
nedges=$(db "SELECT COUNT(*) FROM task_deps td JOIN tasks t ON t.id=td.task_id WHERE t.project_key='widget';")
leaf_verifier=$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE project_key='widget' AND title='Build widget';")
[[ $rc -eq 0 && "$mat" == "true" && "$ntasks" == "2" && "$nedges" == "1" && "$leaf_verifier" == "qa" ]] \
  && ok_t "below-threshold plan materializes tasks + dep edge + leaf verifier" \
  || bad_t "materialize" "rc=$rc mat=$mat ntasks=$ntasks nedges=$nedges verifier=$leaf_verifier out=$out"

# ---- (7a) DIVE-1551: tasks using key 'id' instead of 'local_id' are coerced ----
PLAN_IDKEY='{"project":{"name":"idkey","goal":"g"},"tasks":[
  {"id":"t1","title":"Alpha","assignee_or_role":"dev","risk":"low"},
  {"id":"t2","title":"Beta","assignee_or_role":"dev","depends_on":["t1"],"risk":"low"}]}'
out=$(run cmd_goal_add --plan="$PLAN_IDKEY" --project=idkey --yes -- "ship idkey"); rc=$?
mat=$(printf '%s' "$out" | jq -r '.data.materialized // false' 2>/dev/null)
ntasks=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='idkey' AND kind='standard';")
nedges=$(db "SELECT COUNT(*) FROM task_deps td JOIN tasks t ON t.id=td.task_id WHERE t.project_key='idkey';")
[[ $rc -eq 0 && "$mat" == "true" && "$ntasks" == "2" && "$nedges" == "1" ]] \
  && ok_t "DIVE-1551: tasks keyed 'id' coerced to local_id (materializes + dep edge)" \
  || bad_t "id->local_id coercion" "rc=$rc mat=$mat ntasks=$ntasks nedges=$nedges out=$out"

# ---- (7b) re-materialize guard (dup protection) ----
out=$(run cmd_goal_add --plan="$PLAN_OK" --project=widget -- "ship widget"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -qi "already has" \
  && ok_t "re-materialize into a populated project refused" \
  || bad_t "dup guard" "rc=$rc out=$out"

# ---- (8) over-count threshold files exactly ONE gate ----
FOUR='{"project":{"key":"beta","name":"Beta","goal":"beta goal"},"tasks":[
  {"local_id":"t1","title":"one","assignee_or_role":"dev"},
  {"local_id":"t2","title":"two","assignee_or_role":"dev"},
  {"local_id":"t3","title":"three","assignee_or_role":"dev"},
  {"local_id":"t4","title":"four","assignee_or_role":"dev"}]}'
out=$(run cmd_goal_add --plan="$FOUR" --project=beta --checkpoint=2 -- "beta"); rc=$?
gated=$(printf '%s' "$out" | jq -r '.data.gated // false' 2>/dev/null)
ngates=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='beta' AND need_type IS NOT NULL AND need_answered_at IS NULL;")
nstd=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='beta' AND kind='standard' AND title NOT LIKE 'Goal:%';")
[[ $rc -eq 0 && "$gated" == "true" && "$ngates" == "1" && "$nstd" == "0" ]] \
  && ok_t "over-count plan files exactly ONE gate and materializes no leaves" \
  || bad_t "over-count gate" "rc=$rc gated=$gated ngates=$ngates nstd=$nstd out=$out"

# ---- (8b) --yes waives the COUNT checkpoint ----
FOUR2=$(printf '%s' "$FOUR" | jq -c '.project.key="beta2"')
out=$(run cmd_goal_add --plan="$FOUR2" --project=beta2 --checkpoint=2 --yes -- "beta2"); rc=$?
mat=$(printf '%s' "$out" | jq -r '.data.materialized // false' 2>/dev/null)
nstd=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='beta2' AND kind='standard' AND title NOT LIKE 'Goal:%';")
[[ $rc -eq 0 && "$mat" == "true" && "$nstd" == "4" ]] \
  && ok_t "--yes waives the count checkpoint (materializes)" \
  || bad_t "--yes count waive" "rc=$rc mat=$mat nstd=$nstd out=$out"

# ---- (9) a T2 plan gates even WITH --yes (never auto-materializes) ----
T2='{"project":{"key":"pay","name":"Pay","goal":"pay goal"},"tasks":[
  {"local_id":"t1","title":"Send the customer invoice and charge payment","assignee_or_role":"dev","risk":"spend"}]}'
out=$(run cmd_goal_add --plan="$T2" --project=pay --yes -- "pay"); rc=$?
gated=$(printf '%s' "$out" | jq -r '.data.gated // false' 2>/dev/null)
ngates=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='pay' AND need_type IS NOT NULL AND need_answered_at IS NULL;")
nstd=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='pay' AND kind='standard' AND title NOT LIKE 'Goal:%';")
[[ $rc -eq 0 && "$gated" == "true" && "$ngates" == "1" && "$nstd" == "0" ]] \
  && ok_t "T2 plan gates even with --yes (no leaf materialized)" \
  || bad_t "T2 gate over --yes" "rc=$rc gated=$gated ngates=$ngates nstd=$nstd out=$out"

# ---- (9b) the T2 gate is filed at HARD tier 2 (gap B: not agent-clearable/48h-auto) ----
t2_tier=$(db "SELECT COALESCE(tier,'') FROM tasks WHERE project_key='pay' AND need_type IS NOT NULL ORDER BY id LIMIT 1;")
[[ "$t2_tier" == "2" ]] \
  && ok_t "T2 plan gate is filed at hard tier 2" \
  || bad_t "T2 gate tier 2" "tier=$t2_tier"

# ---- (10) --from-gate refuses an UNANSWERED gate ----
pay_gate=$(db "SELECT id FROM tasks WHERE project_key='pay' AND title LIKE 'Goal:%' ORDER BY id LIMIT 1;")
out=$(run cmd_goal_add --from-gate="$pay_gate"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -qi "not answered yet" \
  && ok_t "--from-gate refuses an unanswered plan gate" \
  || bad_t "from-gate unanswered" "rc=$rc out=$out"

# ---- (10b) --from-gate refuses a NON-HUMAN answer (DIVE-916 human-origin) ----
# Simulate an agent/TTL clear: answered, approve, but need_answered_by is NOT human:*.
db "UPDATE tasks SET need_answer='approve', need_answered_at=datetime('now'), need_answered_by='auto:t1' WHERE id=${pay_gate};" >/dev/null
out=$(run cmd_goal_add --from-gate="$pay_gate"); rc=$?
nstd=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='pay' AND kind='standard' AND title NOT LIKE 'Goal:%';")
[[ $rc -ne 0 && "$nstd" == "0" ]] && printf '%s' "$out" | grep -qi "human" \
  && ok_t "--from-gate refuses a non-human (auto/agent) approval" \
  || bad_t "from-gate non-human" "rc=$rc nstd=$nstd out=$out"

# ---- (10c) --from-gate refuses a human answer that is NOT 'approve' ----
db "UPDATE tasks SET need_answer='revise', need_answered_by='human:mark' WHERE id=${pay_gate};" >/dev/null
out=$(run cmd_goal_add --from-gate="$pay_gate"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -qi "not 'approve'" \
  && ok_t "--from-gate refuses a human 'revise' (only 'approve' builds)" \
  || bad_t "from-gate non-approve" "rc=$rc out=$out"

# ---- (10d) --from-gate MATERIALIZES on a human 'approve' (the completed loop) ----
db "UPDATE tasks SET need_answer='approve', need_answered_by='human:mark' WHERE id=${pay_gate};" >/dev/null
out=$(run cmd_goal_add --from-gate="$pay_gate"); rc=$?
mat=$(printf '%s' "$out" | jq -r '.data.materialized // false' 2>/dev/null)
fg=$(printf '%s' "$out" | jq -r '.data.fromGate // ""' 2>/dev/null)
nstd=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='pay' AND kind='standard' AND title NOT LIKE 'Goal:%';")
[[ $rc -eq 0 && "$mat" == "true" && "$nstd" == "1" && -n "$fg" ]] \
  && ok_t "--from-gate materializes a T2 plan on a HUMAN approve" \
  || bad_t "from-gate materialize" "rc=$rc mat=$mat nstd=$nstd fg=$fg out=$out"

# ---- (10e) --from-gate is idempotent: refuses to re-materialize a built goal ----
out=$(run cmd_goal_add --from-gate="$pay_gate"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -qi "already has" \
  && ok_t "--from-gate refuses to re-materialize an already-built goal" \
  || bad_t "from-gate dup guard" "rc=$rc out=$out"

# ---- (10f) --from-gate rejects a non-goal task ----
out=$(run cmd_goal_add --from-gate="$(db "SELECT id FROM tasks WHERE project_key='widget' AND title='Build widget';")"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$out" | grep -qi "not a goal plan gate" \
  && ok_t "--from-gate rejects a non-goal task" \
  || bad_t "from-gate non-goal" "rc=$rc out=$out"

echo
echo "goal add unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
