#!/usr/bin/env bash
# DIVE-981 isolated unit harness for `5dive project show` dep-graph + critical path.
#
# Sources src/ libs directly against a throwaway tasks.db (same posture as
# goal_add_unit.sh) so it NEVER touches the shared queue. Builds a small DAG:
#
#   t1 ─┬─> t2 ─> t4        (t4 blocked_by t2,t3 ; t2 blocked_by t1 ; t3 blocked_by t1)
#       └─> t3 ─┘
#   t5 (isolated, no deps)
#
# Longest chain = t1->t2->t4 / t1->t3->t4 (3 nodes). Asserts: JSON graph shape
# (layers, edges, nodes carry layer+critical+blockers), critical_path is a valid
# 3-node chain from t1 to t4, isolated t5 is NOT critical, and the human render
# emits the ◆ marker + a Critical path line. Also asserts the empty-graph path.
# Run: bash tests/project_show_graph_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/projshow-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; tests deliberately expect non-zero exits

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run() { ( "$@" ) 2>/dev/null; }

# ---- seed a project + tasks + deps directly (bypass the planner) ----
db "INSERT INTO projects (key, prefix, name) VALUES ('widget','WID','Widget');"
mk() { # mk <n> <title>  -> project task, returns global id on stdout
  db "INSERT INTO tasks (title, assignee, created_by, project_key, kind, status)
      VALUES ($(sqlq "$2"),'dev','dev','widget','standard','todo');
      SELECT last_insert_rowid();"
}
t1=$(mk 1 "Design widget");  t2=$(mk 2 "Build API")
t3=$(mk 3 "Write docs");     t4=$(mk 4 "Ship widget")
t5=$(mk 5 "Unrelated chore")
dep() { db "INSERT OR IGNORE INTO task_deps (task_id, blocked_by) VALUES ($1,$2);"; }
dep "$t2" "$t1"; dep "$t3" "$t1"; dep "$t4" "$t2"; dep "$t4" "$t3"

id_ident() { db "SELECT ident FROM tasks WHERE id=$1;"; }
I1=$(id_ident "$t1"); I2=$(id_ident "$t2"); I3=$(id_ident "$t3")
I4=$(id_ident "$t4"); I5=$(id_ident "$t5")

# ================= JSON path =================
JSON_MODE=1
out=$(run cmd_project_show widget)
printf '%s' "$out" | jq -e '.ok==true' >/dev/null \
  && ok_t "json envelope ok" || bad_t "json envelope" "$out"

edges=$(printf '%s' "$out" | jq '.data.graph.edges')
[[ "$edges" == "4" ]] && ok_t "edges = 4" || bad_t "edges" "got=$edges"

layers=$(printf '%s' "$out" | jq '.data.graph.layers')
[[ "$layers" == "3" ]] && ok_t "layers = 3 (L0/L1/L2)" || bad_t "layers" "got=$layers"

cp=$(printf '%s' "$out" | jq -c '.data.graph.critical_path')
cplen=$(printf '%s' "$out" | jq '.data.graph.critical_path | length')
[[ "$cplen" == "3" ]] && ok_t "critical path has 3 nodes" || bad_t "cp length" "got=$cplen cp=$cp"

# path must start at t1 and end at t4 (the only source/sink of the longest chain)
first=$(printf '%s' "$out" | jq -r '.data.graph.critical_path[0]')
last=$(printf '%s' "$out" | jq -r '.data.graph.critical_path[-1]')
[[ "$first" == "$I1" && "$last" == "$I4" ]] \
  && ok_t "critical path runs $I1 -> $I4" || bad_t "cp endpoints" "first=$first last=$last (want $I1..$I4)"

# middle node is t2 or t3 (both on a longest path)
mid=$(printf '%s' "$out" | jq -r '.data.graph.critical_path[1]')
[[ "$mid" == "$I2" || "$mid" == "$I3" ]] \
  && ok_t "critical path middle is $I2 or $I3 ($mid)" || bad_t "cp middle" "mid=$mid"

# layers: t1=0, t2/t3=1, t4=2
l1=$(printf '%s' "$out" | jq --arg i "$I1" '.data.graph.nodes[] | select(.ident==$i) | .layer')
l4=$(printf '%s' "$out" | jq --arg i "$I4" '.data.graph.nodes[] | select(.ident==$i) | .layer')
[[ "$l1" == "0" && "$l4" == "2" ]] && ok_t "layer stamps ($I1=0, $I4=2)" || bad_t "layers" "l1=$l1 l4=$l4"

# t4 blockers list both t2 and t3
b4=$(printf '%s' "$out" | jq -r --arg i "$I4" '.data.graph.nodes[] | select(.ident==$i) | .blockers')
[[ "$b4" == *"$I2"* && "$b4" == *"$I3"* ]] && ok_t "$I4 blockers = $I2,$I3" || bad_t "blockers" "b4=$b4"

# isolated t5: layer 0, NOT critical
c5=$(printf '%s' "$out" | jq --arg i "$I5" '.data.graph.nodes[] | select(.ident==$i) | .critical')
[[ "$c5" == "0" ]] && ok_t "isolated $I5 not critical" || bad_t "isolated crit" "c5=$c5"

# t1 and t4 ARE critical
c1=$(printf '%s' "$out" | jq --arg i "$I1" '.data.graph.nodes[] | select(.ident==$i) | .critical')
[[ "$c1" == "1" ]] && ok_t "$I1 is critical" || bad_t "t1 crit" "c1=$c1"

# ================= human render =================
JSON_MODE=0
htxt=$(run cmd_project_show widget)
printf '%s' "$htxt" | grep -q "Dependency graph" && ok_t "human: graph header" || bad_t "human header" "$htxt"
printf '%s' "$htxt" | grep -q "$(printf '\xe2\x97\x86')" && ok_t "human: ◆ critical marker" || bad_t "no ◆ marker" "$htxt"
printf '%s' "$htxt" | grep -q "Critical path:" && ok_t "human: critical path line" || bad_t "no crit line" "$htxt"
printf '%s' "$htxt" | grep -q "<- " && ok_t "human: inline blockers" || bad_t "no blockers shown" "$htxt"

# ================= empty-graph path =================
db "INSERT INTO projects (key, prefix, name) VALUES ('empty','EMP','Empty');"
db "INSERT INTO tasks (title, assignee, created_by, project_key, kind, status)
    VALUES ('lonely','dev','dev','empty','standard','todo');"
etxt=$(run cmd_project_show empty)
printf '%s' "$etxt" | grep -q "no task_deps recorded" \
  && ok_t "empty graph: no-deps notice" || bad_t "empty notice" "$etxt"
JSON_MODE=1
ej=$(run cmd_project_show empty)
epath=$(printf '%s' "$ej" | jq -c '.data.graph.critical_path')
[[ "$epath" == "[]" ]] && ok_t "empty graph: critical_path=[]" || bad_t "empty cp" "$epath"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
