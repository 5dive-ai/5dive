#!/usr/bin/env bash
# TIER: core
# DIVE-6804 — a recurring reminder filed without --assignee is owned by its filer.
#
# Measured on even-branch 2026-10-23: galina filed `task add --recurring=…` with
# no --assignee to remind her owner at 01:50 Bangkok. The template fired on time
# into DIVE-20 with an EMPTY assignee, nothing woke it, and the owner never heard.
# crud.sh left templates unassigned on the promise that the instance "gets
# coordinated when it's cloned", but the materializer's clone is raw SQL that
# copied the empty column, so nothing ever coordinated it.
#
# Arms: A filing stamps the filer; B a template that is already unassigned (filed
# before this fix) fires to its filer; C an explicit assignee is kept; D a filer
# that is not a seat falls to the coordinator; E no seat and no coordinator is
# logged, not silent; F a non-seat filer stays unassigned at filing.
# Run: bash tests/recurring_template_owner_unit.sh   (no root, no network)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/recurring-owner-unit.XXXXXX)"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init; _tasks_db_migrate
cmd_send() { return 0; }; audit_log() { return 0; }
_task_store_audit_log() { return 0; }
LOG="$TMP/log"; : >"$LOG"
_hb_log() { printf '%s\n' "$*" >>"$LOG"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }
has_t() { if [[ "$2" == *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] lacks [$3]"; fi; }

# The box: three seats, two org roots and no coordinator, like an OINOA client
# box where several hired agents sit side by side.
printf '%s\n' '{"agents":{"galina":{},"maya":{},"main":{}}}' >"$STATE_DIR/agents.json"
db "INSERT INTO agents_org (name, reports_to, role) VALUES ('galina', NULL, 'assistant'), ('maya', NULL, 'assistant');"

# A template row written straight to the board, the way every template filed
# before this fix sits on a live box. Fires every minute.
mk_tmpl() {  # mk_tmpl <title> <assignee> <created_by> -> row id
  db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, schedule, status)
      VALUES ($(sqlq "$1"), '', 'medium', $(sqlq_or_null "$2"), $(sqlq "$3"), 'recurring', '* * * * *', 'todo');
      SELECT last_insert_rowid();"
}
inst_owner() { db "SELECT COALESCE(assignee,'') FROM tasks WHERE from_template_id=${1} ORDER BY id DESC LIMIT 1;"; }
inst_count() { db "SELECT COUNT(*) FROM tasks WHERE from_template_id=${1};"; }
fire() { : >"$LOG"; _hb_materialize_recurring "$(date -u +%s)"; }
# Only the arm under test fires; the others are parked so they cannot add noise.
only() { db "UPDATE tasks SET status='blocked' WHERE kind='recurring' AND status='todo' AND id<>${1};"; }

# ── A. filing: no --assignee, an agent files it ─────────────────────────────
OUT=$( (cmd_task_add "remind owner at 01:50" --recurring="* * * * *" --from=galina) 2>&1 ); RC=$?
eq_t "A1: task add --recurring with no --assignee succeeds" "$RC" 0
t_a=$(db "SELECT id FROM tasks WHERE title='remind owner at 01:50';")
eq_t "A2: the template is owned by its filer" "$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${t_a};")" "galina"
only "$t_a"; fire
eq_t "A3: the template fires once" "$(inst_count "$t_a")" 1
eq_t "A4: the instance is owned by the filer" "$(inst_owner "$t_a")" "galina"
db "UPDATE tasks SET status='blocked' WHERE id=${t_a};"

# ── B. an unassigned template already on the board (the DIVE-18 shape) ───────
t_b=$(mk_tmpl "galina's old reminder" "" "galina")
only "$t_b"; fire
eq_t "B1: an unassigned template fires to its filer" "$(inst_owner "$t_b")" "galina"
eq_t "B2: the template itself is not rewritten" "$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${t_b};")" ""
db "UPDATE tasks SET status='blocked' WHERE id=${t_b};"

# ── C. an explicit assignee is kept ─────────────────────────────────────────
t_c=$(mk_tmpl "maya runs it" "maya" "galina")
only "$t_c"; fire
eq_t "C1: an explicit assignee wins over the filer" "$(inst_owner "$t_c")" "maya"
OUT=$( (cmd_task_add "explicit at filing" --recurring="* * * * *" --assignee=maya --from=galina) 2>&1 )
eq_t "C2: --assignee at filing is kept" "$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE title='explicit at filing';")" "maya"
db "UPDATE tasks SET status='blocked' WHERE id=${t_c} OR title='explicit at filing';"

# ── D. the filer is not a seat: the coordinator owns it ─────────────────────
db "INSERT INTO agents_org (name, reports_to, role) VALUES ('main', NULL, 'lead coordinator');"
t_d=$(mk_tmpl "filed from a shell" "" "cli")
only "$t_d"; fire
eq_t "D1: a non-seat filer falls to the coordinator" "$(inst_owner "$t_d")" "main"
db "UPDATE tasks SET status='blocked' WHERE id=${t_d};"
db "DELETE FROM agents_org WHERE name='main';"

# ── E. no seat and no coordinator: logged, never silent ─────────────────────
t_e=$(mk_tmpl "nobody can own this" "" "telegram")
only "$t_e"; fire
eq_t "E1: the slot still fires" "$(inst_count "$t_e")" 1
eq_t "E2: ... unowned, since nothing resolves" "$(inst_owner "$t_e")" ""
has_t "E3: ... and the pass says so" "$(cat "$LOG")" "the instance will be UNOWNED"
db "UPDATE tasks SET status='blocked' WHERE id=${t_e};"

# ── F. a non-seat filer stays unassigned at filing ──────────────────────────
OUT=$( (cmd_task_add "relay reminder" --recurring="* * * * *" --from=telegram) 2>&1 ); RC=$?
eq_t "F1: filed (rc 0)" "$RC" 0
eq_t "F2: a non-seat filer is not stamped as owner" "$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE title='relay reminder';")" ""

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
