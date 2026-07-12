#!/usr/bin/env bash
# DIVE-972: prove the token ceiling is ENFORCEABLE, not advisory — _loop_refresh_spend
# recomputes real spend from a child task's assignee transcript and persists it, so a
# fire-and-forget loop over its ceiling is caught. Isolated: throwaway STATE_DIR + a
# synthetic ~/.claude transcript under a temp HOME. Never touches the live queue.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/loop-ceil-enforce.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh cmd_usage.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1; mkdir -p "$TASKS_DIR"; set +e
tasks_db_init; _tasks_db_migrate   # migrate adds parked_at/park_reason (prod stores are always migrated)
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
tasks_db_init

# Registry with one claude agent whose home we control (home_of() reads pwd first,
# so point at a fake home via a shim: we override home_of by exporting a matching
# transcript path). _loop_refresh_spend's python uses pwd.getpwnam("agent-<n>").
# We can't add a system user, so use the real invoking user's agent name if present;
# instead we test the python attribution directly through a controllable REGISTRY +
# HOME by using a name whose home_of falls back to /home/agent-<n> — we create that.
AG="ceiltest"
FAKEHOME="$TMP/home-$AG"
mkdir -p "$FAKEHOME/.claude/projects/proj"
REGISTRY="$TMP/registry.json"
printf '{"agents":{"%s":{"type":"claude"}}}' "$AG" > "$REGISTRY"

now=$(date +%s); start=$((now-300))
# Backing task assigned to AG, started in-window.
db "INSERT INTO tasks (ident,title,status,assignee,kind,started_at,created_at,updated_at)
    VALUES ('DIVE-1','t','in_progress','$AG','standard',datetime($start,'unixepoch'),datetime($start,'unixepoch'),datetime($start,'unixepoch'));"
tid=$(db "SELECT id FROM tasks WHERE ident='DIVE-1';")
db "INSERT INTO loop_runs (loop_id,topology,status,tokens_spent,ceiling,child_task_ids,spawned_by_task,started_at,updated_at)
    VALUES ('L-enf','spawn','running',0,50000,'[$tid]',$tid,$start,$start);"

# Synthetic transcript: 2 assistant turns in-window, total input+output+cache_creation.
ts1=$(date -u -d "@$((start+10))" +%FT%TZ); ts2=$(date -u -d "@$((start+20))" +%FT%TZ)
{
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-opus-4-8","usage":{"input_tokens":10000,"output_tokens":5000,"cache_creation_input_tokens":15000,"cache_read_input_tokens":999999}}}\n' "$ts1"
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-opus-4-8","usage":{"input_tokens":20000,"output_tokens":10000,"cache_creation_input_tokens":0,"cache_read_input_tokens":5}}}\n' "$ts2"
} > "$FAKEHOME/.claude/projects/proj/session.jsonl"

# Resolve the agent's home via the test override hook (unset in production).
export REGISTRY LOOP_HOME_OVERRIDE_JSON
LOOP_HOME_OVERRIDE_JSON=$(printf '{"%s":"%s"}' "$AG" "$FAKEHOME")
CLEAN_LINK="x"
spent=$(_loop_refresh_spend "L-enf")
# expected total = (10000+5000+15000) + (20000+10000+0) = 30000 + 30000 = 60000 (cache-read excluded)
if [[ -n "$CLEAN_LINK" ]]; then
  [[ "$spent" == "60000" ]] && ok_t "refresh sums real transcript spend, cache-read excluded (=$spent)" || bad_t "refresh spend" "got $spent want 60000"
  persisted=$(db "SELECT tokens_spent FROM loop_runs WHERE loop_id='L-enf';")
  [[ "$persisted" == "60000" ]] && ok_t "spend persisted to loop_runs.tokens_spent" || bad_t "persist" "$persisted"
  # 60000 >= ceiling 50000 → a ceiling check now fires (was 0 → advisory no-op before)
  [[ "$spent" -ge 50000 ]] && ok_t "spend over ceiling → breach now detectable (enforceable)" || bad_t "breach" "$spent"
  # OSS-24: the heartbeat sweep must actually HALT a fire-and-forget loop, not just
  # mark loop_runs. Run the sweep and assert the live child task gets PARKED
  # (blocked + parked_at), so the agent stops burning tokens past the ceiling.
  cmd_task_need() { :; }   # stub the escalate gate (no owner/channel in the harness)
  _hb_loop_ceiling_sweep >/dev/null 2>&1
  lstat=$(db "SELECT status FROM loop_runs WHERE loop_id='L-enf';")
  [[ "$lstat" == "escalated" ]] && ok_t "sweep marks breached loop escalated" || bad_t "loop escalated" "got $lstat"
  cstat=$(db "SELECT status FROM tasks WHERE id=${tid};")
  cparked=$(db "SELECT CASE WHEN parked_at IS NOT NULL THEN 1 ELSE 0 END FROM tasks WHERE id=${tid};")
  [[ "$cstat" == "blocked" && "$cparked" == "1" ]] \
    && ok_t "sweep PARKS the live child task (blocked+parked) → spend actually halts (=$cstat)" \
    || bad_t "child parked" "status=$cstat parked=$cparked"
  rm -f "$CLEAN_LINK"
else
  printf 'skip - could not symlink /home/agent-%s (no perms); refresh path untested here\n' "$AG"
fi
printf -- '-----\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
