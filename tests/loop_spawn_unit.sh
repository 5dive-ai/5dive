#!/usr/bin/env bash
# DIVE-593 isolated unit harness for `5dive loop spawn` (the atom).
#
# Sources the src/ libs directly and points STATE_DIR at a throwaway temp dir,
# so it NEVER touches the live shared tasks.db (see memory
# reference_5dive_cli_smoke_hits_live_taskdb — STATE_DIR is otherwise hardcoded
# and a stray real verb migrates+writes the live queue). Asserts: row + backing
# task created, schema/arg validation, ceiling halt, kill halt, clean done
# passthrough. Run: bash tests/loop_spawn_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

# temp state dir we own → mkdir works as a normal user, live db untouched.
TMP="$(mktemp -d /tmp/loop-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Source in build.sh order, minus main.sh (we call functions directly).
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

# Re-point state at the temp dir AFTER sourcing (header.sh hardcodes it).
STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
LOOP_POLL_SECS=1
export LOOP_POLL_SECS
mkdir -p "$TASKS_DIR"   # init refuses to mkdir as non-root; we own this temp dir
set +e   # header.sh enabled `set -e` on source; tests deliberately expect non-zero exits

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
# run a verb in a subshell so its `fail`→exit can't kill the harness
run() { ( cmd_loop_spawn "$@" ) 2>"$TMP"/loop-unit.err; }

tasks_db_init
# sanity: default project must exist (cmd_task_add validates it)
proj=$(db "SELECT key FROM projects WHERE key='dive' AND status='active';")
[[ "$proj" == "dive" ]] && ok_t "default 'dive' project present" || bad_t "default project" "got '$proj'"

# --- T1: spawn (no --wait) creates row + backing task, status running
out=$(run --role=maker --agent=main --prompt="do a thing")
st=$(printf '%s' "$out" | jq -r '.data.status' 2>/dev/null)
lid=$(printf '%s' "$out" | jq -r '.data.loopId' 2>/dev/null)
tid=$(printf '%s' "$out" | jq -r '.data.taskId' 2>/dev/null)
[[ "$st" == "running" && "$lid" == L-* && "$tid" =~ ^[0-9]+$ ]] \
  && ok_t "spawn returns {running, loopId, taskId}" || bad_t "spawn basic" "$out $(cat "$TMP"/loop-unit.err)"
rowtopo=$(db "SELECT topology FROM loop_runs WHERE loop_id='$lid';")
child=$(db "SELECT child_task_ids FROM loop_runs WHERE loop_id='$lid';")
[[ "$rowtopo" == "spawn" && "$child" == "[$tid]" ]] \
  && ok_t "loop_runs row linked to backing task ($child)" || bad_t "loop_runs row" "topo=$rowtopo child=$child"
tbody=$(db "SELECT body FROM tasks WHERE id=$tid;")
[[ "$tbody" == *"loop_id=$lid"* ]] && ok_t "backing task carries loop marker" || bad_t "task marker" "$tbody"
tassignee=$(db "SELECT assignee FROM tasks WHERE id=$tid;")
[[ "$tassignee" == "main" ]] && ok_t "backing task assigned to --agent" || bad_t "assignee" "$tassignee"

# --- T2: validation
run --agent=main >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "missing --prompt fails" || bad_t "missing prompt" "exit 0"
run --prompt=x   >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "missing --agent fails"  || bad_t "missing agent" "exit 0"
run --agent=main --prompt=x --role=bogus >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "bad --role rejected" || bad_t "bad role" "exit 0"
run --agent=main --prompt=x --ceiling=abc >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "non-int --ceiling rejected" || bad_t "bad ceiling" "exit 0"
run --agent=main --prompt=x --schema='{bad' >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "invalid --schema json rejected" || bad_t "bad schema" "exit 0"

# --- T3: ceiling default resolution
out=$(run --agent=main --prompt=y); c=$(printf '%s' "$out" | jq -r '.data.ceiling')
[[ "$c" == "200000" ]] && ok_t "built-in ceiling default applied ($c)" || bad_t "ceiling default" "$c"
out=$(LOOP_CEILING_DEFAULT=50000 run --agent=main --prompt=y); c=$(printf '%s' "$out" | jq -r '.data.ceiling')
[[ "$c" == "50000" ]] && ok_t "env LOOP_CEILING_DEFAULT override ($c)" || bad_t "env ceiling" "$c"
out=$(run --agent=main --prompt=y --ceiling=12345); c=$(printf '%s' "$out" | jq -r '.data.ceiling')
[[ "$c" == "12345" ]] && ok_t "--ceiling beats env+builtin ($c)" || bad_t "flag ceiling" "$c"

# resolve a loop row deterministically by its child task's unique prompt
# (avoids started_at ties when several rows land in the same second).
loop_by_prompt() { db "SELECT lr.loop_id FROM loop_runs lr, tasks t WHERE lr.child_task_ids='['||t.id||']' AND t.body LIKE '%$1%' ORDER BY t.id DESC LIMIT 1;"; }
task_by_prompt() { db "SELECT t.id FROM tasks t WHERE t.body LIKE '%$1%' ORDER BY t.id DESC LIMIT 1;"; }

# --- T4: --wait halts on KILL (flip kill_requested mid-wait)
( cmd_loop_spawn --agent=main --prompt="UNIQ_killme" --wait=20 >"$TMP"/loop-kill.out 2>&1 ) &
bgpid=$!
sleep 1; klid=$(loop_by_prompt UNIQ_killme)
db "UPDATE loop_runs SET kill_requested=1 WHERE loop_id='$klid';"
wait $bgpid
kst=$(jq -r '.data.status' "$TMP"/loop-kill.out 2>/dev/null)
[[ "$kst" == "killed" ]] && ok_t "--wait halts on kill_requested → killed" || bad_t "kill halt" "$(cat "$TMP"/loop-kill.out)"

# --- T5: --wait halts on CEILING breach
( cmd_loop_spawn --agent=main --prompt="UNIQ_spendy" --ceiling=1000 --wait=20 >"$TMP"/loop-ceil.out 2>&1 ) &
bgpid=$!
sleep 1; clid=$(loop_by_prompt UNIQ_spendy)
db "UPDATE loop_runs SET tokens_spent=5000 WHERE loop_id='$clid';"
wait $bgpid
cst=$(jq -r '.data.status' "$TMP"/loop-ceil.out 2>/dev/null)
[[ "$cst" == "escalated" ]] && ok_t "--wait halts on ceiling breach → escalated" || bad_t "ceiling halt" "$(cat "$TMP"/loop-ceil.out)"

# --- T6: --wait returns clean done + result passthrough
( cmd_loop_spawn --agent=main --prompt="UNIQ_finish" --wait=20 >"$TMP"/loop-done.out 2>&1 ) &
bgpid=$!
sleep 1; dtid=$(task_by_prompt UNIQ_finish)
db "UPDATE tasks SET status='done', result='shipped clean' WHERE id=$dtid;"
wait $bgpid
dst=$(jq -r '.data.status' "$TMP"/loop-done.out 2>/dev/null)
dres=$(jq -r '.data.result' "$TMP"/loop-done.out 2>/dev/null)
[[ "$dst" == "done" && "$dres" == "shipped clean" ]] \
  && ok_t "--wait → done with result passthrough" || bad_t "done passthrough" "$(cat "$TMP"/loop-done.out)"

echo "-----"; echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
