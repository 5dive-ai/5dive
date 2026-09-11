#!/usr/bin/env bash
# DIVE-4281 — pending means delivered-and-ungraded, and a stale request may not
# steal an in-progress row from its maker.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"

SRC=src
TMP="$(mktemp -d /tmp/grader-pending.XXXXXX)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/verify_policy.sh lib/tasks_db.sh \
         lib/actor.sh cmd_task.sh cmd_push.sh cmd_org.sh cmd_project.sh; do
  # shellcheck disable=SC1090
  source "$SRC/$f"
done
source "$SRC/task/grader_pool.sh"

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
BOX_CONFIG="$TMP/box.json"; JSON_MODE=0
mkdir -p "$TASKS_DIR"
printf '{"verify":"always"}\n' > "$BOX_CONFIG"
set +e
PASS=0; FAILN=0
ok_t()  { PASS=$((PASS+1));  printf 'ok   - %s\n' "$1"; }
bad_t() { FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
tasks_db_init >/dev/null 2>&1

seed() { # <status> <assignee> -> ident
  local status="$1" assignee="$2" title="grader pending $RANDOM"
  db "INSERT INTO tasks
        (title,status,assignee,verifier,maker_agent,kind,priority,created_by,
         handoff_delivered_at,delivery_ref)
      VALUES ($(sqlq "$title"),$(sqlq "$status"),$(sqlq_or_null "$assignee"),
              'quinn','dev','standard','high','main','2026-01-01 00:00:00',
              'https://github.com/o/r/pull/1');" >/dev/null
  db "SELECT ident FROM tasks ORDER BY id DESC LIMIT 1;"
}
request() { # <ident> <timestamp>
  db "INSERT INTO lifecycle_events (ts,kind,ident,actor,idem_key,detail)
      VALUES ($(sqlq "$2"),'task.grade.requested',$(sqlq "$1"),'sys',
              $(sqlq "request-$1-$RANDOM"),'fixture');" >/dev/null
}

UNGRADED=$(seed todo quinn); request "$UNGRADED" '2026-01-01 00:01:00'
GRADED=$(seed todo quinn); request "$GRADED" '2026-01-01 00:01:00'
db "UPDATE tasks SET graded_at='2026-01-01 00:02:00', graded_by='quinn',
                     graded_verdict='pass', graded_verdict_at='2026-01-01 00:02:00'
      WHERE ident=$(sqlq "$GRADED");" >/dev/null
OWNER=$(seed in_progress dev); request "$OWNER" '2026-01-01 00:01:00'
POOL_WORKING=$(seed in_progress quinn); request "$POOL_WORKING" '2026-01-01 00:01:00'

# A finished grade session is not in flight, even with duplicate historical
# spawn receipts for the same task.
FINISHED=$(seed done quinn)
db "INSERT INTO lifecycle_events (ts,kind,ident,actor,idem_key,detail) VALUES
    ('2026-01-01 00:01:00','task.grade.spawned',$(sqlq "$FINISHED"),'sys','spawn-a','fixture'),
    ('2026-01-01 00:02:00','task.grade.spawned',$(sqlq "$FINISHED"),'sys','spawn-b','fixture'),
    ('2026-01-01 00:03:00','task.done',$(sqlq "$FINISHED"),'quinn','done-a','fixture');" >/dev/null

_GRADER_POOL="quinn main2"
_GRADER_USAGE_CMD=_gp_usage
_gp_usage(){ printf '{"agents":[{"account":"a","name":"quinn","fiveHourPct":1,"sevenDayPct":1}]}'; }
_grader_can_read(){ return 0; }

# BODY-ONLY means body-only: no second request may appear on a graded row.
before=$(db "SELECT COUNT(*) FROM lifecycle_events WHERE ident=$(sqlq "$GRADED") AND kind='task.grade.requested';")
cmd_task_set_body "$GRADED" --append 'operator note only' >/dev/null 2>&1
after=$(db "SELECT COUNT(*) FROM lifecycle_events WHERE ident=$(sqlq "$GRADED") AND kind='task.grade.requested';")
[[ "$before" == 1 && "$after" == "$before" ]] \
  && ok_t 'body append on a graded row emits no new grade request' \
  || bad_t 'body append does not request a grade' "before=$before after=$after"

# Dry-run is the externally consumed classification: the graded row vanishes,
# the genuinely ungraded delivery spawns, and the active maker is an explicit
# skip rather than an assignment target.
out=$(cmd_task_grader_tick --cap=1 2>/dev/null)
grep -q "spawn   $UNGRADED" <<<"$out" \
  && ok_t 'delivered row with no later verdict is pending' \
  || bad_t 'ungraded row is pending' "$out"
grep -q "$GRADED" <<<"$out" \
  && bad_t 'graded row is not pending' "$out" \
  || ok_t 'recorded PASS after request is not pending'
grep -q "skip    $OWNER  (owner is dev, not a pool seat)" <<<"$out" \
  && ok_t 'in-progress non-pool owner gets the required skip line' \
  || bad_t 'owner skip line' "$out"
grep -q "$POOL_WORKING" <<<"$out" \
  && bad_t 'pool seat already grading is not pending again' "$out" \
  || ok_t 'pool seat already holding the claim is not double-spawned'
grep -q 'cap 1 reached' <<<"$out" \
  && bad_t 'spawned plus later done counts as zero in flight' "$out" \
  || ok_t 'spawned plus later done counts as zero in flight'
grep -q 'pending=1 spawn=1 queue=0 dark=1' <<<"$out" \
  && ok_t 'summary counts only the eligible delivery as pending' \
  || bad_t 'pending summary excludes owner and grade' "$out"

# Defence in depth at the mutation boundary itself: even if a caller bypasses
# the planner, _grader_spawn_session must refuse before either fleet verb.
CALLS="$TMP/calls"; : > "$CALLS"
5dive(){ printf '%s\n' "$*" >> "$CALLS"; }
spawn_out=$(_grader_spawn_session quinn "$OWNER" 2>&1); spawn_rc=$?
[[ $spawn_rc -ne 0 && ! -s "$CALLS" ]] \
  && ok_t 'spawn primitive refuses before task assign or agent send' \
  || bad_t 'spawn primitive cannot steal owner' "rc=$spawn_rc calls=$(cat "$CALLS") out=$spawn_out"

# Commit turns the already-known verdict into an append-only supersession
# receipt; the row still remains absent from the plan.
cmd_task_grader_tick --commit --only="$GRADED" --json >/dev/null 2>&1
sup=$(db "SELECT COUNT(*) FROM lifecycle_events WHERE ident=$(sqlq "$GRADED")
          AND kind='task.grade.request.superseded';")
[[ "$sup" == 1 ]] \
  && ok_t 'commit marks the resolved request superseded' \
  || bad_t 'resolved request has a supersession receipt' "count=$sup"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAILN"
[[ "$FAILN" == 0 ]]
