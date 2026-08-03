#!/usr/bin/env bash
# DIVE-2211 / DIVE-2286: name the tree this harness grades. Sourced BEFORE any cd so
# ${BASH_SOURCE[0]} still resolves relative to tests/. Three-state on purpose: if the
# helper is unreachable the log says NO TREE WAS NAMED rather than falling silent.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# DIVE-2476 isolated unit harness for the `task deliver --result=` over-a-CLOSED-ROW
# guard — the sibling verb of the one DIVE-2464 guarded.
#
# The bug: `cmd_task_deliver` ended in an unconditional `UPDATE tasks SET result=`
# with no status check anywhere in the function, so `task deliver --pr=… --result=`
# on an already done/cancelled row REPLACED the recorded result exactly the way
# `task done` did before DIVE-2464 — no warning, no refusal, exit 0. It also stamped
# delivery_ref/delivered_at over that closed row on the line above. Measured by
# main's probe arm P4 against origin/main e935d82 AND #357's tip, so it is
# pre-existing and not a #357 regression.
#
# WHY IT IS A SEPARATE HARNESS AND NOT A DIVE-2464 ARM: the property that makes the
# clobber unrecoverable (the ledger keeps a sha256 of the result, not the text)
# belongs to the COLUMN, not to the verb. Guarding one writer leaves the value just
# as destroyable through the next one. So the thing this harness has to prove is not
# only "deliver refuses" but "deliver refuses IDENTICALLY" — same refusal text, same
# --append-result ordering, same audited --force-result escape — because a reader who
# learns the rule from one verb must not be surprised by another.
#
# TWO SHAPES ARE GRADED, and the D2 arm is why. `cmd_task_deliver` forks on
# `verifier != assignee`: the routed rail hands off through
# `_task_route_to_verifier` (its own unconditional result write) and the unrouted
# rail writes the column directly. main's P4 only ever measured the unrouted one.
# Excluding the routed shape because "the DIVE-477 rail handles it" is precisely the
# reasoning DIVE-2464's own review demolished, so both rails are measured here.
#
# Same isolation contract as the sibling task harnesses: sources src/ libs directly
# with STATE_DIR on a throwaway temp dir, so it NEVER touches the live shared
# tasks.db.
# Run: bash tests/task_deliver_over_closed_result_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/task-deliver-over-closed-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/disk.sh lib/tasks_db.sh lib/broker.sh \
         cmd_task.sh cmd_push.sh cmd_org.sh cmd_project.sh; do
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
no(){ F=$((F+1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "   ${2:0:260}"; }

seed() { # $1=status $2=result -> echoes the row id (verifier NULL: the unrouted rail)
  seedv "$1" "$2" olivia ""
}
seedv() { # $1=status $2=result $3=assignee $4=verifier -> echoes the row id
  tasks_db_init >/dev/null 2>&1
  db "INSERT INTO tasks (title,status,assignee,verifier,result,kind,priority,created_by,done_at)
      VALUES ('t','$1','$3',$(sqlq "$4"),$(sqlq "$2"),'standard','medium','main',
              CASE WHEN '$1' IN ('done','cancelled') THEN '2026-07-30 21:08:59' ELSE NULL END);" >/dev/null 2>&1
  db "SELECT id FROM tasks ORDER BY id DESC LIMIT 1;"
}
dref() { db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE id=$1;"; }
dat()  { db "SELECT COALESCE(delivered_at,'') FROM tasks WHERE id=$1;"; }
res()  { db "SELECT COALESCE(result,'')       FROM tasks WHERE id=$1;"; }
st()   { db "SELECT COALESCE(status,'')       FROM tasks WHERE id=$1;"; }

PR=https://github.com/5dive-ai/5dive/pull/999
THEIRS="main2: verifier ACK — release cut 0.9.14 confirmed green, two caveats recorded."
MINE="olivia: delivering the follow-up."

# --- D1. the defect, unrouted rail (main's probe P4) --------------------------
id=$(seed done "$THEIRS")
out=$( cmd_task_deliver "$id" --pr="$PR" --result="$MINE" 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && ok "D1a 'task deliver --result=' on a done row is REFUSED (rc=$rc)" || no "D1a deliver over closed is REFUSED" "rc=$rc $out"
[ "$(res "$id")" = "$THEIRS" ] && ok "D1b the prior closer's result is INTACT" || no "D1b prior result INTACT" "$(res "$id")"
grep -q 'DIVE-2464' <<<"$out" && ok "D1c the refusal cites DIVE-2464 (same rule, same citation as the close verbs)" || no "D1c refusal cites DIVE-2464" "$out"
grep -q "5dive task deliver .* --append-result" <<<"$out" && ok "D1d the refusal names the non-destructive route for THIS verb" || no "D1d refusal names deliver --append-result" "$out"
grep -q '2026-07-30 21:08:59' <<<"$out" && ok "D1e the refusal names the close TIMESTAMP" || no "D1e refusal names the timestamp" "$out"
# ORDERING, which is half the fix: the stamp on the line after the guard must not
# have run. A refusal that rewrote delivery_ref/delivered_at on a row it declined to
# touch would leave the board asserting a delivery that was refused.
[ -z "$(dref "$id")" ] && ok "D1f delivery_ref was NOT stamped on the refused row" || no "D1f delivery_ref not stamped" "$(dref "$id")"
[ -z "$(dat  "$id")" ] && ok "D1g delivered_at was NOT stamped on the refused row" || no "D1g delivered_at not stamped" "$(dat "$id")"

# --- D2. the defect, ROUTED rail (verifier != assignee) -----------------------
# The shape P4 never measured. Here the write happens inside
# `_task_route_to_verifier` after an early return, so a guard placed below the fork
# would miss it entirely — and that rail ALSO sets status='todo', which would
# resurrect a closed row on top of destroying its result.
id=$(seedv done "$THEIRS" olivia main)
out=$( cmd_task_deliver "$id" --pr="$PR" --result="$MINE" 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && ok "D2a deliver over a closed row is REFUSED on the ROUTED rail too (rc=$rc)" || no "D2a routed rail REFUSED" "rc=$rc $out"
[ "$(res "$id")" = "$THEIRS" ] && ok "D2b prior result INTACT on the routed rail" || no "D2b routed prior result intact" "$(res "$id")"
[ "$(st "$id")" = "done" ] && ok "D2c the closed row was not RESURRECTED to 'todo' by the refused delivery" || no "D2c row not resurrected" "$(st "$id")"
[ -z "$(dref "$id")" ] && ok "D2d delivery_ref not stamped on the refused routed row" || no "D2d routed delivery_ref not stamped" "$(dref "$id")"

# --- D3. the legitimate second half: --append-result --------------------------
id=$(seed done "$THEIRS")
out=$( cmd_task_deliver "$id" --pr="$PR" --append-result --result="$MINE" 2>&1 ); rc=$?
r=$(res "$id")
[ "$rc" -eq 0 ] && ok "D3a deliver --append-result is ACCEPTED (rc=0)" || no "D3a append accepted" "rc=$rc $out"
grep -qF "$THEIRS" <<<"$r" && ok "D3b the prior result survives VERBATIM" || no "D3b prior result verbatim" "$r"
grep -qF "$MINE"   <<<"$r" && ok "D3c the new text is present too" || no "D3c new text present" "$r"
[ "${r:0:20}" = "${THEIRS:0:20}" ] && ok "D3d the prior result comes FIRST (same ordering as the close verbs)" || no "D3d prior result first" "$r"
[ "$(dref "$id")" = "$PR" ] && ok "D3e an ACCEPTED delivery does stamp delivery_ref" || no "D3e accepted delivery stamps" "$(dref "$id")"

# --- D4. --force-result replaces, but never silently -------------------------
id=$(seed done "$THEIRS")
out=$( cmd_task_deliver "$id" --pr="$PR" --force-result --result="$MINE" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "D4a deliver --force-result is ACCEPTED (rc=0)" || no "D4a force accepted" "rc=$rc $out"
[ "$(res "$id")" = "$MINE" ] && ok "D4b --force-result REPLACES the result (that is its job)" || no "D4b force replaces" "$(res "$id")"
grep -q 'REPLACED the result' <<<"$out" && ok "D4c the replace is announced on stderr, not silent" || no "D4c replace announced" "$out"

# --- D5..D8. the guard must stay NARROW --------------------------------------
# Every shape below was working before this change and must keep working; a guard
# that starts refusing them trades one broken verb for another.
id=$(seed in_progress "")
out=$( cmd_task_deliver "$id" --pr="$PR" --result="$MINE" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && [ "$(res "$id")" = "$MINE" ] && ok "D5 an OPEN row still records the delivery result (no new refusal)" || no "D5 open row unaffected" "rc=$rc $(res "$id")"

id=$(seed done "$THEIRS")
out=$( cmd_task_deliver "$id" --pr="$PR" --result="$THEIRS" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && [ "$(res "$id")" = "$THEIRS" ] && ok "D6 an IDENTICAL result is not refused (nothing is being destroyed)" || no "D6 identical result idempotent" "rc=$rc $out"

id=$(seed done "")
out=$( cmd_task_deliver "$id" --pr="$PR" --result="$MINE" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && [ "$(res "$id")" = "$MINE" ] && ok "D7 an EMPTY stored result is not refused (there is no record to lose)" || no "D7 empty stored result" "rc=$rc $out"

id=$(seed done "$THEIRS")
out=$( cmd_task_deliver "$id" --pr="$PR" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && [ "$(res "$id")" = "$THEIRS" ] && ok "D8 a BARE deliver (no --result=) is not refused and leaves the result alone" || no "D8 bare deliver untouched" "rc=$rc $(res "$id")"
# Recorded, NOT asserted as correct: that bare deliver DID re-stamp delivery_ref and
# delivered_at on a closed row. It is the no-result population this guard cannot see
# (there is no result to protect), it is named in the source comment, and it is
# unfixed here rather than quietly claimed.
echo "     note: bare deliver re-stamped delivery_ref='$(dref "$id")' on the closed row — known, out of scope, named in cmd_task.sh"

echo
echo "=== DIVE-2476 deliver-over-closed unit: $P passed, $F failed ==="
[ "$F" -eq 0 ] || exit 1
