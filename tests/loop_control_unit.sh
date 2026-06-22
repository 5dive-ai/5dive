#!/usr/bin/env bash
# DIVE-597 isolated unit harness for the loop control window:
#   `task loops` (loop_runs board + --runs + --kill, read-only) and
#   `usage loops` (token aggregation over loop_runs).
# Same isolation as the other loop harnesses: source src/ libs, point STATE_DIR
# at a throwaway temp dir — the live shared tasks.db is NEVER touched
# (memory reference_5dive_cli_smoke_hits_live_taskdb).
# Run: bash tests/loop_control_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/loop-control-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh cmd_usage.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1; LOOP_POLL_SECS=1; export LOOP_POLL_SECS
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# Seed loop_runs directly (control window is read-only; we don't need real verbs).
now=$(date +%s)
db "INSERT INTO loop_runs (loop_id, topology, status, stage, iteration, tokens_spent, ceiling, started_at, updated_at)
    VALUES ('L-aaa','panel','running','panel:correctness',1,40000,200000,$now,$now);"
db "INSERT INTO loop_runs (loop_id, topology, status, tokens_spent, ceiling, started_at, updated_at)
    VALUES ('L-bbb','map','running',10000,200000,$now,$now);"
db "INSERT INTO loop_runs (loop_id, topology, status, tokens_spent, ceiling, started_at, updated_at)
    VALUES ('L-ccc','spawn','done',5000,200000,$((now-100)),$((now-100)));"

# --- T1: task loops --runs (JSON) lists the running loop_runs rows
out=$( cmd_task_loops --runs )
nrun=$(printf '%s' "$out" | jq -r '.data.runs | length')
ids=$(printf '%s' "$out" | jq -r '[.data.runs[].loop_id]|sort|join(",")')
hasL=$(printf '%s' "$out" | jq -r 'has("data") and (.data|has("loops"))')
[[ "$nrun" == "2" && "$ids" == "L-aaa,L-bbb" && "$hasL" == "true" ]] \
  && ok_t "task loops --runs → 2 running runs (L-aaa,L-bbb), {loops,runs} shape" || bad_t "loops runs" "$out"

# --- T2: --all includes the finished run
out=$( cmd_task_loops --runs --all )
nrun=$(printf '%s' "$out" | jq -r '.data.runs | length')
[[ "$nrun" == "3" ]] && ok_t "task loops --runs --all includes finished run (3)" || bad_t "loops all" "$out"

# --- T3: --kill flips kill_requested (deferred-safe), read-only otherwise
out=$( cmd_task_loops --kill L-bbb )
kr=$(db "SELECT kill_requested FROM loop_runs WHERE loop_id='L-bbb';")
killedflag=$(printf '%s' "$out" | jq -r '.data.killRequested')
[[ "$kr" == "1" && "$killedflag" == "true" ]] \
  && ok_t "task loops --kill L-bbb sets kill_requested=1" || bad_t "kill" "$out kr=$kr"

# --- T4: --kill on unknown loop fails
( cmd_task_loops --kill L-nope >/dev/null 2>&1 ); [[ $? -ne 0 ]] \
  && ok_t "task loops --kill <unknown> fails" || bad_t "kill unknown" "exit 0"

# --- T5: --watch=<bad> rejected
( cmd_task_loops --watch=abc >/dev/null 2>&1 ); [[ $? -ne 0 ]] \
  && ok_t "task loops --watch=<non-int> rejected" || bad_t "watch validate" "exit 0"

# --- T6: usage loops — per-topology aggregation (running only)
out=$( cmd_usage loops )
total=$(printf '%s' "$out" | jq -r '.data.total')
panelTok=$(printf '%s' "$out" | jq -r '.data.byTopology[]|select(.topology=="panel")|.tokens')
[[ "$total" == "50000" && "$panelTok" == "40000" ]] \
  && ok_t "usage loops: per-topology, running total=50000 (panel 40000)" || bad_t "usage loops" "$out"

# --- T7: usage loops --all sums finished too; --by-loop lists each run
out=$( cmd_usage loops --all )
total=$(printf '%s' "$out" | jq -r '.data.total')
[[ "$total" == "55000" ]] && ok_t "usage loops --all total=55000 (incl finished)" || bad_t "usage loops all" "$out"
out=$( cmd_usage loops --by-loop --all )
nloops=$(printf '%s' "$out" | jq -r '.data.loops | length')
top=$(printf '%s' "$out" | jq -r '.data.loops[0].loop_id')
[[ "$nloops" == "3" && "$top" == "L-aaa" ]] \
  && ok_t "usage loops --by-loop: 3 rows, ordered by tokens (L-aaa top)" || bad_t "usage by-loop" "$out"

echo "-----"; echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
