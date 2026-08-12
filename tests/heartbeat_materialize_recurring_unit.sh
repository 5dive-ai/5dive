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
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-materializer-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
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

# ---------------------------------------------------------------------------
# DIVE-2237: a SKIP must leave a trace on the row, not only in _hb_log.
#
# The dedup itself is unchanged and is not under test here — what is under test
# is whether the board can tell "the materializer looked at this template and
# declined" apart from "the scheduler never reached it". Before this change both
# readings were the same one: a stale last_fired_at.
#
# NOTE ON THE CLOCK. _hb_materialize_recurring has a same-minute guard that
# `continue`s BEFORE the dedup check, so two passes in one wall-clock minute
# would never reach the skip branch and every arm below would be vacuously
# green. Each pass is therefore handed a `now` two minutes after the last, and
# the cron is '* * * * *' so it still matches.
last_skipped_of() { db "SELECT COALESCE(last_skipped_at,'') FROM tasks WHERE id=${1};"; }
ident_of_instance() { db "SELECT ident FROM tasks WHERE from_template_id=${1} ORDER BY id LIMIT 1;"; }

t_sup=$(mk_template "suppressed template" todo)
t0=$(date -u +%s)

# Pass 1 — nothing open yet, so it fires. This is also the ANCHOR for the skip
# stamp: the FIRE path must not touch last_skipped_at, or a non-empty value
# below would prove nothing about the skip path.
_hb_materialize_recurring "$t0"
if [[ "$(instances_of "$t_sup")" == "1" ]]; then
  ok_t "2237 anchor: first pass fires (one instance)"
else
  bad_t "2237 anchor: first pass fires (one instance)" "got $(instances_of "$t_sup")"
fi
if [[ -z "$(last_skipped_of "$t_sup")" ]]; then
  ok_t "2237 anchor: a FIRE does not stamp last_skipped_at"
else
  bad_t "2237 anchor: a FIRE does not stamp last_skipped_at" "got $(last_skipped_of "$t_sup")"
fi

# Differential for the last_fired arm. Both passes land in the same wall-clock
# second, so "unchanged" would be trivially true even if the skip path DID
# write last_fired_at = datetime('now'). Park it on a sentinel first: any write
# by the skip path now shows up as a value that is obviously not the sentinel.
# (The sentinel is far in the past, so the same-minute guard still lets the
# pass through to the dedup.)
SENTINEL='2000-01-01 00:00:00'
db "UPDATE tasks SET last_fired_at='${SENTINEL}' WHERE id=${t_sup};" >/dev/null

# Pass 2 — the pass-1 instance is still open, so this is the skip.
_hb_materialize_recurring "$((t0 + 120))"
if [[ "$(instances_of "$t_sup")" == "1" ]]; then
  ok_t "2237 skip: open instance still suppresses the fire (dedup unchanged)"
else
  bad_t "2237 skip: open instance still suppresses the fire (dedup unchanged)" \
        "expected 1 instance, got $(instances_of "$t_sup")"
fi
if [[ "$(last_fired_of "$t_sup")" == "$SENTINEL" ]]; then
  ok_t "2237 skip: last_fired_at is NOT advanced by a skip"
else
  bad_t "2237 skip: last_fired_at is NOT advanced by a skip" \
        "sentinel was '${SENTINEL}', now '$(last_fired_of "$t_sup")'"
fi
skipped_after_skip=$(last_skipped_of "$t_sup")
if [[ -n "$skipped_after_skip" ]]; then
  ok_t "2237 skip: last_skipped_at IS stamped"
else
  bad_t "2237 skip: last_skipped_at IS stamped" "still empty after a skipped tick"
fi

# The listing is the surface. Both renderers, because this harness runs with
# JSON_MODE=1 and would otherwise never execute the -box branch at all.
inst_ident=$(ident_of_instance "$t_sup")
json_list=$(cmd_task_ls --recurring)
JSON_MODE=0 box_list=$(cmd_task_ls --recurring)

if grep -q '"last_skipped_at"' <<<"$json_list" \
   && [[ "$(jq -r --arg i "$inst_ident" '.data.tasks[] | select(.title=="suppressed template") | .blocked_by' <<<"$json_list")" == "$inst_ident" ]]; then
  ok_t "2237 surface: --json carries last_skipped_at + names the blocking instance"
else
  bad_t "2237 surface: --json carries last_skipped_at + names the blocking instance" "$json_list"
fi
if grep -q 'last_skipped' <<<"$box_list" && grep -q 'blocked_by' <<<"$box_list" \
   && grep -q "$inst_ident" <<<"$box_list"; then
  ok_t "2237 surface: task ls --recurring table shows the skip + the blocker"
else
  bad_t "2237 surface: task ls --recurring table shows the skip + the blocker" "$box_list"
fi
# Liveness for that box arm: a template with NO open instance must NOT be
# reported as blocked, or the two greps above would pass on a table that marks
# everything.
if [[ "$(awk -v t='todo template' '$0 ~ t' <<<"$box_list" | grep -c "$inst_ident")" == "0" ]]; then
  ok_t "2237 surface: an unblocked template is not marked blocked"
else
  bad_t "2237 surface: an unblocked template is not marked blocked" "$box_list"
fi

# Pass 3 — close the blocker; the template must fire again, and the historical
# skip stamp must survive (it records what happened, it is not a live flag).
db "UPDATE tasks SET status='done' WHERE from_template_id=${t_sup};" >/dev/null
_hb_materialize_recurring "$((t0 + 240))"
if [[ "$(instances_of "$t_sup")" == "2" ]]; then
  ok_t "2237 recovery: closing the blocker lets the template fire again"
else
  bad_t "2237 recovery: closing the blocker lets the template fire again" \
        "expected 2 instances, got $(instances_of "$t_sup")"
fi
if [[ "$(last_fired_of "$t_sup")" != "$SENTINEL" ]]; then
  ok_t "2237 recovery: a real fire DOES advance last_fired_at"
else
  bad_t "2237 recovery: a real fire DOES advance last_fired_at" "still on the sentinel"
fi
if [[ "$(last_skipped_of "$t_sup")" == "$skipped_after_skip" ]]; then
  ok_t "2237 recovery: the fire leaves the skip history intact"
else
  bad_t "2237 recovery: the fire leaves the skip history intact" \
        "was '${skipped_after_skip}', now '$(last_skipped_of "$t_sup")'"
fi

# ---------------------------------------------------------------------------
# DIVE-2273: a FAILED count read is NOT a suppression.
#
# The materializer decided "an open instance exists" from
#   open=$(db "SELECT COUNT(*) ..." 2>/dev/null || echo 1)
# so an unreadable DB was absorbed into the legitimate magnitude 1, took the
# skip branch, and — since DIVE-2237 — STAMPED last_skipped_at. That forges a
# suppression the scheduler never observed, and the DIVE-2237 reading table
# sends a human to close a blocker that does not exist.
#
# A healthy DB cannot see any of this, so these arms FORCE THE READ TO FAIL.
# The stub intercepts by the materializer's own query text keyed to ONE
# template id, which buys the control below: a second template in the SAME pass
# reads normally and must still fire. Without that control, "did not spawn"
# would also be satisfied by a pass that did nothing at all.
eval "orig_db() $(declare -f db | tail -n +2)"
DB_FAIL_MATCH=''      # substring of the SQL to intercept; '' disables the stub
DB_FAIL_MODE='error'  # error = stderr + non-zero rc | empty = rc 0, no output
db() {
  if [[ -n "$DB_FAIL_MATCH" && "$1" == *"$DB_FAIL_MATCH"* ]]; then
    if [[ "$DB_FAIL_MODE" == 'error' ]]; then
      printf 'Error: database disk image is malformed\n' >&2
      return 11
    fi
    return 0   # the other half of the old collapse: `${open:-1}` made "" mean 1
  fi
  orig_db "$1"
}

t_err=$(mk_template "unreadable-count template" todo)
t_ctl=$(mk_template "healthy control template"  todo)
# Park both on the sentinel so "nothing was stamped" is a real observation
# rather than two writes that happen to land in the same second.
db "UPDATE tasks SET last_fired_at='${SENTINEL}' WHERE id IN (${t_err}, ${t_ctl});" >/dev/null
: >"$LOG"

DB_FAIL_MATCH="from_template_id=${t_err} AND status NOT IN"
DB_FAIL_MODE='error'
_hb_materialize_recurring "$((t0 + 360))"
DB_FAIL_MATCH=''

# Grade the guard's own decision first: if the stub never fired, every arm
# below is vacuous and this one is the only thing that says so.
if grep -q 'UNREADABLE' "$LOG"; then
  ok_t "2273 read-error: the failed count is logged AS a failed read"
else
  bad_t "2273 read-error: the failed count is logged AS a failed read" "$(cat "$LOG")"
fi
if [[ "$(last_skipped_of "$t_err")" == "" ]]; then
  ok_t "2273 read-error: NO last_skipped_at — an error is not a suppression"
else
  bad_t "2273 read-error: NO last_skipped_at — an error is not a suppression" \
        "forged suppression stamped at '$(last_skipped_of "$t_err")'"
fi
if [[ "$(instances_of "$t_err")" == "0" ]]; then
  ok_t "2273 read-error: still skips (fire decision unchanged, deliberately)"
else
  bad_t "2273 read-error: still skips (fire decision unchanged, deliberately)" \
        "expected 0 instances, got $(instances_of "$t_err")"
fi
if [[ "$(last_fired_of "$t_err")" == "$SENTINEL" ]]; then
  ok_t "2273 read-error: last_fired_at untouched (the tick stamped nothing)"
else
  bad_t "2273 read-error: last_fired_at untouched (the tick stamped nothing)" \
        "sentinel was '${SENTINEL}', now '$(last_fired_of "$t_err")'"
fi
# The control. Same pass, same clock, read NOT intercepted.
if [[ "$(instances_of "$t_ctl")" == "1" && "$(last_fired_of "$t_ctl")" != "$SENTINEL" ]]; then
  ok_t "2273 control: a healthy template in the SAME pass still fires"
else
  bad_t "2273 control: a healthy template in the SAME pass still fires" \
        "instances=$(instances_of "$t_ctl") last_fired=$(last_fired_of "$t_ctl")"
fi

# Second forging input: rc 0 with EMPTY output. `${open:-1}` turned that into 1
# too, so it forged a suppression down a path the rc check alone never touches.
: >"$LOG"
DB_FAIL_MATCH="from_template_id=${t_err} AND status NOT IN"
DB_FAIL_MODE='empty'
_hb_materialize_recurring "$((t0 + 480))"
DB_FAIL_MATCH=''
if grep -q 'UNREADABLE' "$LOG" && [[ "$(last_skipped_of "$t_err")" == "" ]] \
   && [[ "$(instances_of "$t_err")" == "0" ]]; then
  ok_t "2273 empty read: rc 0 with no output is also NOT a suppression"
else
  bad_t "2273 empty read: rc 0 with no output is also NOT a suppression" \
        "log=$(cat "$LOG") last_skipped='$(last_skipped_of "$t_err")' instances=$(instances_of "$t_err")"
fi

# THE DIFFERENTIAL. With the stub off and nothing else changed, the same
# template must fire. This is what makes the three arms above mean "the read
# failure suppressed it" instead of "something else made it ineligible" — a
# wrong-target success looks identical to a right one until you show the target
# recovers when the injected fault is removed.
_hb_materialize_recurring "$((t0 + 600))"
if [[ "$(instances_of "$t_err")" == "1" ]]; then
  ok_t "2273 differential: the same template fires once the read recovers"
else
  bad_t "2273 differential: the same template fires once the read recovers" \
        "expected 1 instance, got $(instances_of "$t_err")"
fi
if [[ "$(last_skipped_of "$t_err")" == "" ]]; then
  ok_t "2273 differential: no suppression was ever recorded for it"
else
  bad_t "2273 differential: no suppression was ever recorded for it" \
        "got '$(last_skipped_of "$t_err")'"
fi

echo "-- ${PASS} passed, ${FAIL} failed --"
[[ $FAIL -eq 0 ]]
