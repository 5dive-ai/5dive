#!/usr/bin/env bash
# OSS-12 isolated unit harness for gate SLA escalation in _hb_gate_ttl_sweep
# (cmd_heartbeat.sh). A T2 gate unanswered past _HB_GATE_ESCALATE_DAYS must, on
# the weekly stale-gate re-ping, ALSO loop in the filing agent's org-chart parent
# (agents_org.reports_to) — walking the chain instead of stalling on one lane.
# Never auto-answers: this only adds a recipient. Runs on a throwaway tasks.db
# (STATE_DIR -> tmp), stubbing the send helpers to capture who got pinged.
# Run: bash tests/heartbeat_gate_escalate_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-gate-esc.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_agent.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init
# tasks_db_init only runs the ALTER migrations on the ELSE branch (store already
# exists); a fresh store gets the base _tasks_schema CREATE TABLE, which omits
# the additive columns (parked_at, wake_at, ...). In production init is called
# every command so the 2nd call migrates; a one-shot harness must migrate itself
# or pass 1 of the sweep (wake-parked) errors on a missing parked_at each tick.
_tasks_db_migrate

# --- stubs: capture escalation recipients instead of sending -----------------
ESC_LOG="$TMP/escalated"; : >"$ESC_LOG"
cmd_send()            { printf '%s\n' "$1" >>"$ESC_LOG"; }   # $1 = target agent
_task_agent_channel() { return 0; }                          # everyone has a channel
_task_send_owner()    { return 0; }                          # owner re-ping = no-op here
audit_log()           { return 0; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# org chart: worker reports to boss; boss reports to nobody
db "INSERT INTO agents_org (name, reports_to) VALUES ('worker','boss'),('boss',NULL);"

# helper: a stale T2 gate assigned to <agent>, asked <n> days ago, not yet pinged
mk_gate() {  # <assignee> <days_old>
  db "INSERT INTO tasks (title, priority, assignee, created_by, kind, status,
                         need_type, tier, ask, need_asked_at, gate_pinged_at)
      VALUES ('stuck gate', 'medium', $(sqlq "$1"), 'main', 'standard', 'blocked',
              'decision', 2, 'need a human call', datetime('now','-$2 days'), NULL);
      SELECT last_insert_rowid();"
}
reset() { db "DELETE FROM tasks;"; : >"$ESC_LOG"; }

# --- Case 1: gate older than the SLA → org-parent escalated -------------------
reset
mk_gate worker 6 >/dev/null           # 6d > default 5d escalate threshold
_hb_gate_ttl_sweep
grep -qx 'boss' "$ESC_LOG" \
  && ok_t "6d-old T2 gate escalates to org-parent (boss pinged)" \
  || bad_t "expected boss escalation" "escalated=[$(tr '\n' ',' <"$ESC_LOG")]"

# --- Case 2: gate past 72h re-ping but under escalate SLA → NO escalation -----
reset
mk_gate worker 4 >/dev/null           # 4d: >72h so it re-pings, but <5d escalate
_hb_gate_ttl_sweep
grep -qx 'boss' "$ESC_LOG" \
  && bad_t "4d gate must NOT escalate yet" "escalated=[$(tr '\n' ',' <"$ESC_LOG")]" \
  || ok_t "4d-old gate re-pings owner but does NOT escalate up-chain"

# --- Case 3: filing agent has no org-parent → no escalation, no error ---------
reset
mk_gate boss 9 >/dev/null             # boss.reports_to is NULL
_hb_gate_ttl_sweep
[[ ! -s "$ESC_LOG" ]] \
  && ok_t "agent with no manager: aged gate does not escalate (graceful)" \
  || bad_t "no-manager gate must not escalate" "escalated=[$(tr '\n' ',' <"$ESC_LOG")]"

# --- Case 4: answered gate never escalates -----------------------------------
reset
gid=$(mk_gate worker 10)
db "UPDATE tasks SET need_answered_at=datetime('now') WHERE id=${gid};"
_hb_gate_ttl_sweep
[[ ! -s "$ESC_LOG" ]] \
  && ok_t "already-answered gate never escalates" \
  || bad_t "answered gate escalated" "escalated=[$(tr '\n' ',' <"$ESC_LOG")]"

# --- Case 5: never auto-answers — escalation leaves need_answered_at NULL -----
reset
gid=$(mk_gate worker 8)
_hb_gate_ttl_sweep
ans=$(db "SELECT COALESCE(need_answered_at,'NULL') FROM tasks WHERE id=${gid};")
[[ "$ans" == "NULL" ]] \
  && ok_t "escalation NEVER auto-answers the T2 gate (need_answered_at still NULL)" \
  || bad_t "T2 gate was auto-answered by escalation" "need_answered_at=$ans"

# --- DIVE-1298: tier-1 48h TTL applies the recommendation -------------------
# The core "missed taps auto-resolve" contract (DIVE-891 pass 2 of the sweep):
# a tier-1 gate with a recommendation, unanswered past 48h, is auto-closed with
# provenance auto:ttl / uid 0 and the task is unblocked. Under 48h, or with no
# recommendation, it must NOT auto-apply.
mk_t1_gate() {  # <assignee> <hours_old> <recommend|-> ; echoes id
  local rec="NULL"; [[ "$3" != "-" ]] && rec="$(sqlq "$3")"
  db "INSERT INTO tasks (title, priority, assignee, created_by, kind, status,
                         need_type, tier, ask, recommend, need_asked_at)
      VALUES ('t1 gate', 'medium', $(sqlq "$1"), 'main', 'standard', 'blocked',
              'decision', 1, 'lead call', ${rec}, datetime('now','-$2 hours'));
      SELECT last_insert_rowid();"
}

# Case 6: tier-1 gate + rec, 60h old (>48h) → rec applied, auto:ttl, unblocked
reset
gid=$(mk_t1_gate worker 60 approve)
_hb_gate_ttl_sweep
row=$(db "SELECT COALESCE(need_answer,'x')||'|'||COALESCE(need_answered_by,'x')||'|'||COALESCE(need_answered_uid,'x')||'|'||status FROM tasks WHERE id=${gid};")
[[ "$row" == "approve|auto:ttl|0|todo" ]] \
  && ok_t "T1 gate >48h: rec applied via auto:ttl (uid 0) + task unblocked to todo" \
  || bad_t "T1 48h TTL did not apply the rec as expected" "got=[$row] want=[approve|auto:ttl|0|todo]"

# Case 7: tier-1 gate + rec, only 24h old (<48h) → left untouched
reset
gid=$(mk_t1_gate worker 24 approve)
_hb_gate_ttl_sweep
ans=$(db "SELECT COALESCE(need_answered_at,'NULL') FROM tasks WHERE id=${gid};")
[[ "$ans" == "NULL" ]] \
  && ok_t "T1 gate <48h: NOT auto-applied (still open)" \
  || bad_t "T1 gate auto-applied before 48h" "need_answered_at=$ans"

# Case 8: tier-1 gate with NO recommendation, 60h old → falls through, not applied
reset
gid=$(mk_t1_gate worker 60 -)
_hb_gate_ttl_sweep
ans=$(db "SELECT COALESCE(need_answered_at,'NULL') FROM tasks WHERE id=${gid};")
[[ "$ans" == "NULL" ]] \
  && ok_t "T1 gate w/o recommendation: never auto-applied (routes to T2 reminder)" \
  || bad_t "rec-less T1 gate was auto-applied" "need_answered_at=$ans"

# Case 9: pass 1 (wake-parked) — a parked, blocked task whose wake_at has passed
# is unparked and, with no open deps, flipped back to todo. Previously this pass
# errored non-fatally on the missing parked_at column and was never exercised.
reset
gid=$(db "INSERT INTO tasks (title, priority, assignee, created_by, kind, status,
                             parked_at, park_reason, wake_at)
          VALUES ('snoozed', 'medium', 'worker', 'main', 'standard', 'blocked',
                  datetime('now','-2 days'), 'waiting', datetime('now','-1 hours'));
          SELECT last_insert_rowid();")
_hb_gate_ttl_sweep
row=$(db "SELECT COALESCE(parked_at,'NULL')||'|'||COALESCE(wake_at,'NULL')||'|'||status FROM tasks WHERE id=${gid};")
[[ "$row" == "NULL|NULL|todo" ]] \
  && ok_t "wake-parked pass: due parked task unparked + unblocked to todo" \
  || bad_t "wake-parked pass did not fire" "got=[$row] want=[NULL|NULL|todo]"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
