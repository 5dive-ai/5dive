#!/usr/bin/env bash
# DIVE-2067 isolated unit harness for the `task verify --cmd` over-a-closed-task guard.
#
# The bug: DIVE-2007 made the DELIVERED state durable against its own maker for
# `task done` — but `task verify --cmd` had NO equivalent guard and UPDATEs
# status/done_at/result unconditionally. Measured on DIVE-2059: the verifier closed
# with the ACK at 10:22:37, the MAKER closed again 39s later via `verify --cmd`, and
# the ACK was REPLACED — two operational caveats, the red-team evidence and a
# follow-up split, gone. It survived only because the verifier had also compiled it.
#
# The subtlety the guard must respect: `task verify --cmd` is a SANCTIONED escape.
# The DIVE-2007 refusal text names it as a real exit for a maker whose delivery was
# refused. So this must block only the case with nothing to escape FROM — already
# done, closer is not the recorded verifier.
#
# Same isolation contract as the sibling task harnesses: sources src/ libs directly
# with STATE_DIR on a throwaway temp dir, so it NEVER touches the live shared
# tasks.db. Actor is forced per-case via FIVE_SENDER/USER rather than sudo.
# Run: bash tests/task_verify_over_closed_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/task-verify-closed-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/disk.sh lib/tasks_db.sh cmd_task.sh cmd_push.sh cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

P=0; F=0
ok(){ P=$((P+1)); echo "ok   - $1"; }
no(){ F=$((F+1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "   ${2:0:220}"; }

seed() { # $1=status $2=verifier $3=result  -> echoes the row id
  tasks_db_init >/dev/null 2>&1
  db "INSERT INTO tasks (title,status,assignee,verifier,maker_agent,result,kind,priority,created_by)
      VALUES ('t','$1','olivia','$2','dev2',$(sqlq "$3"),'standard','medium','main');" >/dev/null 2>&1
  db "SELECT id FROM tasks ORDER BY id DESC LIMIT 1;"
}

ACK="ACK: accepted — c97a4f9 was ALREADY merged with a version bump; red-team evidence recorded; DIVE-2066 split filed."

# --- A. the defect: maker verify-closes an already-done task -------------------
id=$(seed done olivia "$ACK")
out=$( FIVE_SENDER=dev2 USER=agent-dev2 cmd_task_verify "$id" --cmd=true 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
[ "$rc" -ne 0 ] && ok "A1 maker's verify --cmd over a done task is REFUSED (rc=$rc)" || no "A1 maker's verify --cmd over a done task is REFUSED" "rc=$rc $out"
grep -q 'DIVE-2067' <<<"$out" && ok "A2 the refusal cites DIVE-2067" || no "A2 the refusal cites DIVE-2067" "$out"
[ "$res" = "$ACK" ] && ok "A3 the verifier's ACK is INTACT after the refusal" || no "A3 the verifier's ACK is INTACT" "$res"

# --- B. the sanctioned escape must still work ---------------------------------
# A maker whose delivery was refused uses verify --cmd on a task that is NOT done.
id=$(seed todo olivia "")
out=$( FIVE_SENDER=dev2 USER=agent-dev2 cmd_task_verify "$id" --cmd=true 2>&1 ); rc=$?
st=$(db "SELECT status FROM tasks WHERE id=$id;")
[ "$st" = done ] && ok "B1 verify --cmd still closes a NOT-done task (escape preserved)" || no "B1 escape preserved" "rc=$rc st=$st $out"

# --- C. the verifier's own re-close preserves the prior record (rec 3) ---------
id=$(seed done olivia "$ACK")
out=$( FIVE_SENDER=olivia USER=agent-olivia cmd_task_verify "$id" --cmd=true 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
grep -q 'superseded result' <<<"$res" && ok "C1 a re-close PRESERVES the prior result rather than replacing it" || no "C1 prior result preserved" "$res"
grep -q 'ALREADY merged with a version bump' <<<"$res" && ok "C2 the original ACK text survives in full" || no "C2 original ACK survives" "$res"

# --- D. no verifier recorded => no guard (nothing to protect) ------------------
id=$(seed done "" "prior")
out=$( FIVE_SENDER=dev2 USER=agent-dev2 cmd_task_verify "$id" --cmd=true 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "D1 a task with no recorded verifier is not blocked" || no "D1 no-verifier task not blocked" "rc=$rc $out"

echo; echo "DIVE-2067 verify-over-closed guard: passed: $P  failed: $F"
[ "$F" -eq 0 ]
