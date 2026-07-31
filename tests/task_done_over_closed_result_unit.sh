#!/usr/bin/env bash
# DIVE-2211 / DIVE-2286: name the tree this harness grades. Sourced BEFORE any cd so
# ${BASH_SOURCE[0]} still resolves relative to tests/. Three-state on purpose: if the
# helper is unreachable the log says NO TREE WAS NAMED rather than falling silent.
# Deliberately NO `2>/dev/null` — redirecting it also swallows the helper's own stderr
# line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# DIVE-2464 isolated unit harness for the `task done|cancel` over-a-CLOSED-ROW guard.
#
# The bug: `task done --result=` on a row that was ALREADY done REPLACED the result
# column — no warning, no refusal, no merge, exit 0. Hit live 2026-07-30 21:11 on
# DIVE-2451: main2 closed at 21:08:59, main closed again at 21:11:43, and main2's
# record was gone from the board. `5dive trace` shows both task.done events but its
# `out:` field is a sha256 OF the result, not the text — it proves the record changed
# and cannot restore it. Recovery came from a tasks-backups snapshot that happened to
# fall between the two writes; a 3-minute window inside a 5-minute cadence is luck,
# not a designed path.
#
# DIVE-2067 fixed exactly this clobber in `task verify` (see
# tests/task_verify_over_closed_unit.sh). `task done` was left unguarded, and the
# DIVE-2007 guard above it falls THROUGH for closed rows on the stated grounds that
# "a repeat done stays idempotent" — true of the status write, false of the result.
#
# WHAT THIS HARNESS MUST ALSO PROVE, not just the refusal: the guard is narrow. The
# legitimate second close (a maker closes, then the owner of the other half adds
# theirs) is COMMON here, so --append-result has to keep the prior text VERBATIM,
# and none of the idempotent shapes (no --result at all, identical --result, an empty
# stored result, an OPEN row) may start refusing.
#
# Same isolation contract as the sibling task harnesses: sources src/ libs directly
# with STATE_DIR on a throwaway temp dir, so it NEVER touches the live shared
# tasks.db.
# Run: bash tests/task_done_over_closed_result_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/task-done-over-closed-unit.XXXXXX)"
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
no(){ F=$((F+1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "   ${2:0:260}"; }

# verifier and maker_agent are left NULL on purpose: a row carrying a live
# maker/verifier pair is the DIVE-2007 / DIVE-477 rail's business, and seeding one
# here would let THAT guard produce the refusal and fake a green for this one.
seed() { # $1=status $2=result -> echoes the row id
  tasks_db_init >/dev/null 2>&1
  db "INSERT INTO tasks (title,status,assignee,result,kind,priority,created_by,done_at)
      VALUES ('t','$1','olivia',$(sqlq "$2"),'standard','medium','main',
              CASE WHEN '$1' IN ('done','cancelled') THEN '2026-07-30 21:08:59' ELSE NULL END);" >/dev/null 2>&1
  db "SELECT id FROM tasks ORDER BY id DESC LIMIT 1;"
}

THEIRS="main2: verifier ACK — release cut 0.9.14 confirmed green, two caveats recorded."
MINE="main: closing after the follow-up landed."

# --- A. the defect: a second close with a DIFFERENT result is REFUSED ----------
id=$(seed done "$THEIRS")
out=$( cmd_task_done "$id" --result="$MINE" 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
[ "$rc" -ne 0 ] && ok "A1 a second 'task done --result=' on a done row is REFUSED (rc=$rc)" || no "A1 second done is REFUSED" "rc=$rc $out"
grep -q 'DIVE-2464' <<<"$out" && ok "A2 the refusal cites DIVE-2464" || no "A2 the refusal cites DIVE-2464" "$out"
[ "$res" = "$THEIRS" ] && ok "A3 the prior closer's result is INTACT after the refusal" || no "A3 prior result intact" "$res"
grep -q '2026-07-30 21:08:59' <<<"$out" && ok "A4 the refusal names the close TIMESTAMP" || no "A4 refusal names the timestamp" "$out"
grep -q "olivia" <<<"$out" && ok "A5 the refusal names the recorded holder" || no "A5 refusal names the holder" "$out"

# --- B. the legitimate case: --append-result keeps BOTH ------------------------
# This is the arm that matters most. The refusal is worthless if the common
# second-closer case has no non-destructive route, because then everyone reaches
# for the lossy flag.
id=$(seed done "$THEIRS")
out=$( cmd_task_done "$id" --append-result --result="$MINE" 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
[ "$rc" -eq 0 ] && ok "B1 --append-result is ACCEPTED (rc=0)" || no "B1 --append-result accepted" "rc=$rc $out"
grep -qF "$THEIRS" <<<"$res" && ok "B2 the prior result survives VERBATIM" || no "B2 prior result verbatim" "$res"
grep -qF "$MINE" <<<"$res" && ok "B3 the new text is present too" || no "B3 new text present" "$res"
# Order is load-bearing: the record that already existed must read first, so the
# board shows the original close and the addition beneath it.
[ "${res:0:20}" = "${THEIRS:0:20}" ] && ok "B4 the prior result comes FIRST" || no "B4 prior result first" "$res"

# --- C. --force-result replaces, but never silently ---------------------------
id=$(seed done "$THEIRS")
out=$( cmd_task_done "$id" --force-result --result="$MINE" 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
[ "$rc" -eq 0 ] && ok "C1 --force-result is ACCEPTED (rc=0)" || no "C1 --force-result accepted" "rc=$rc $out"
[ "$res" = "$MINE" ] && ok "C2 --force-result REPLACES the result (that is its job)" || no "C2 force replaces" "$res"
grep -q 'REPLACED the result' <<<"$out" && ok "C3 the replace is announced on stderr, not silent" || no "C3 replace announced" "$out"

# --- D. nothing idempotent regressed ------------------------------------------
# Each of these was legal before the guard and must stay legal. A guard that
# starts refusing a replay would break the heartbeat and half the corpus.
id=$(seed done "$THEIRS")
out=$( cmd_task_done "$id" 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
[ "$rc" -eq 0 ] && [ "$res" = "$THEIRS" ] && ok "D1 a bare re-close (no --result) still succeeds and touches nothing" || no "D1 bare re-close" "rc=$rc res=$res $out"

id=$(seed done "$THEIRS")
out=$( cmd_task_done "$id" --result="$THEIRS" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "D2 a replay with the IDENTICAL result is a no-op, not a refusal" || no "D2 identical result replay" "rc=$rc $out"

id=$(seed done "")
out=$( cmd_task_done "$id" --result="$MINE" 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
[ "$rc" -eq 0 ] && [ "$res" = "$MINE" ] && ok "D3 a done row with an EMPTY result accepts one (nothing to destroy)" || no "D3 empty prior result" "rc=$rc res=$res $out"

id=$(seed in_progress "notes so far")
out=$( cmd_task_done "$id" --result="$MINE" 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
[ "$rc" -eq 0 ] && [ "$res" = "$MINE" ] && ok "D4 a FIRST close of an open row is untouched by the guard" || no "D4 first close of open row" "rc=$rc res=$res $out"

# --- E. cancel writes the same column, so it is guarded the same --------------
id=$(seed done "$THEIRS")
out=$( cmd_task_cancel "$id" --result="abandoning" 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
[ "$rc" -ne 0 ] && ok "E1 'task cancel --result=' over a closed row is REFUSED too" || no "E1 cancel over closed refused" "rc=$rc $out"
[ "$res" = "$THEIRS" ] && ok "E2 the prior result is INTACT after the cancel refusal" || no "E2 prior result intact after cancel" "$res"

echo; echo "DIVE-2464 done-over-closed-result guard: passed: $P  failed: $F"
[ "$F" -eq 0 ]
