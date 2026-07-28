#!/usr/bin/env bash
# DIVE-2055 isolated unit harness for the recurring-template materializer's
# fire predicate.
#
# The materializer used to key on kind='recurring' AND schedule IS NOT NULL
# alone — no status check — so a template moved to cancelled/blocked (via
# `task cancel`, `task block`, or `task park`, all of which write a non-todo
# status) kept firing on schedule forever. This exercises _hb_materialize_
# recurring directly against a throwaway tasks.db, one template per status,
# all sharing a schedule that always matches "now". Asserts: only the
# status='todo' template fires (spawns a standard instance + last_fired_at);
# cancelled/blocked/done templates spawn nothing.
# Run: bash tests/heartbeat_materialize_recurring_unit.sh (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-materializer-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; asserts below deliberately probe states

tasks_db_init

LOG="$TMP/log"; : >"$LOG"
_hb_log() { printf '%s\n' "$*" >>"$LOG"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# Every minute (5-field cron '* * * * *') so it always matches whatever `now`
# the materializer is called with.
mk_template() {  # mk_template <title> <status> -> row id
  local title="$1" status="$2"
  db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, schedule, status)
      VALUES ($(sqlq "$title"), '', 'medium', 'main', 'main', 'recurring', '* * * * *', $(sqlq "$status"));
      SELECT last_insert_rowid();"
}

instances_of() {  # instances_of <template_id> -> count of spawned standard todos
  db "SELECT COUNT(*) FROM tasks WHERE from_template_id=${1};"
}

last_fired_of() { db "SELECT COALESCE(last_fired_at,'') FROM tasks WHERE id=${1};"; }

t_todo=$(mk_template "todo template"      todo)
t_cancelled=$(mk_template "cancelled template" cancelled)
t_blocked=$(mk_template "blocked template"     blocked)
t_done=$(mk_template "done template"           done)

now=$(date -u +%s)
_hb_materialize_recurring "$now"

if [[ "$(instances_of "$t_todo")" == "1" ]]; then
  ok_t "todo template fires"
else
  bad_t "todo template fires" "expected 1 spawned instance, got $(instances_of "$t_todo")"
fi
if [[ -n "$(last_fired_of "$t_todo")" ]]; then
  ok_t "todo template stamps last_fired_at"
else
  bad_t "todo template stamps last_fired_at" "last_fired_at still empty"
fi

for pair in "cancelled:$t_cancelled" "blocked:$t_blocked" "done:$t_done"; do
  name="${pair%%:*}"; tid="${pair##*:}"
  if [[ "$(instances_of "$tid")" == "0" ]]; then
    ok_t "$name template does NOT fire"
  else
    bad_t "$name template does NOT fire" "expected 0 spawned instances, got $(instances_of "$tid")"
  fi
  if [[ -z "$(last_fired_of "$tid")" ]]; then
    ok_t "$name template last_fired_at stays unset"
  else
    bad_t "$name template last_fired_at stays unset" "got $(last_fired_of "$tid")"
  fi
done

# DIVE-2055 defect 2: `task ls --recurring` must key on the same live
# predicate as the materializer — default listing shows only the todo
# template; --all shows every template regardless of status.
default_list=$(cmd_task_ls --recurring)
all_list=$(cmd_task_ls --recurring --all)

if grep -q "todo template" <<<"$default_list" && ! grep -q "cancelled template" <<<"$default_list" \
   && ! grep -q "blocked template" <<<"$default_list" && ! grep -q "done template" <<<"$default_list"; then
  ok_t "task ls --recurring default shows only the live template"
else
  bad_t "task ls --recurring default shows only the live template" "$default_list"
fi

if grep -q "todo template" <<<"$all_list" && grep -q "cancelled template" <<<"$all_list" \
   && grep -q "blocked template" <<<"$all_list" && grep -q "done template" <<<"$all_list"; then
  ok_t "task ls --recurring --all shows every template"
else
  bad_t "task ls --recurring --all shows every template" "$all_list"
fi

echo "-- ${PASS} passed, ${FAIL} failed --"
[[ $FAIL -eq 0 ]]
