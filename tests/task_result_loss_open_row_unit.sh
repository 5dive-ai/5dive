#!/usr/bin/env bash
# TIER: nightly — sibling of task_done_over_closed_result_unit.sh (46.2s measured there); does not fit the 300s PR core.
# DIVE-2211 / DIVE-2286: name the tree this harness grades. Sourced BEFORE any cd so
# ${BASH_SOURCE[0]} still resolves relative to tests/.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# DIVE-2483 isolated unit harness for the result guard on an OPEN row.
#
# WHY THIS FILE EXISTS SEPARATELY FROM ITS CLOSED-ROW SIBLING, which is the whole
# point and not a filing preference: the DIVE-2464 guard keyed on the ROW STATE it
# protects ("already closed") rather than on the COLUMN it protects ("the result").
# Every arm anyone wrote for it therefore graded the CLOSED cell — and the cell the
# maker→verifier rail MANUFACTURES on every single loop is the other one. A
# delivered row is OPEN and already carries the maker's record. So the guard
# protected the rare cell and skipped the routine one, and a harness exercising only
# the closed cell passed green throughout the entire life of the defect. The sibling
# harness even had an arm (D4) asserting the wipe as correct behaviour.
#
# Three verbs reached the open cell and each was found separately, months apart:
#   task done    — DIVE-2483, the row that owns this (empty overwrite, killed heredoc)
#   task verify  — DIVE-2624, dev's maker-delivery record replaced by a verify verdict
#   task deliver — DIVE-2476, the same column through the door next door
# ...plus the remedy itself: --append-result was parsed, accepted and SILENTLY INERT
# here (DIVE-2717/DIVE-2712), because the remedy lived inside the refusal's branch.
#
# THE DECISION THIS GRADES (olivia, 2026-08-04, gate on DIVE-2483): on an OPEN row
# carrying another agent's result, a write AUTO-APPENDS rather than refusing.
# Refusing would have been the "uniform" choice and it WEDGES the rail — `task
# reject` writes the VERIFIER'S feedback into `result`, so after any rejection the
# row is open and carries someone else's text, and the maker's next
# `task done --result=` at iteration 2 is exactly this cell. Arm R below is the
# regression arm for that and it is not optional.
#
# Same isolation contract as the sibling task harnesses: sources src/ libs directly
# with STATE_DIR on a throwaway temp dir, so it NEVER touches the live shared tasks.db.
# Run: bash tests/task_result_loss_open_row_unit.sh
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/task-result-loss-open-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh \
         cmd_push.sh cmd_org.sh cmd_project.sh; do
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
no(){ F=$((F+1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "   ${2:0:300}"; }

seedv() { # $1=status $2=result $3=assignee $4=verifier -> row id
  tasks_db_init >/dev/null 2>&1
  db "INSERT INTO tasks (title,status,assignee,verifier,result,kind,priority,created_by,done_at)
      VALUES ('t','$1','$3',$(sqlq "$4"),$(sqlq "$2"),'standard','medium','main',
              CASE WHEN '$1' IN ('done','cancelled') THEN '2026-07-30 21:08:59' ELSE NULL END);" >/dev/null 2>&1
  db "SELECT id FROM tasks ORDER BY id DESC LIMIT 1;"
}
seed() { seedv "$1" "$2" olivia ""; }

THEIRS="dev: maker delivery — implemented the include guard, 7/7 unit, four mutation arms confirmed red."
MINE="main: grade — accepted, evidence checked against the branch."

echo "== A. the acceptance sentence, verbatim: OPEN row + another agent's result =="
# "on an OPEN row carrying agent A's result, agent B running
#  'task done --result=X --append-result' yields A's text VERBATIM followed by X"
id=$(seed in_progress "$THEIRS")
out=$( cmd_task_done "$id" --append-result --result="$MINE" 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
[ "$rc" -eq 0 ] && ok "A1 --append-result on an OPEN row is ACCEPTED (rc=0)" || no "A1 accepted" "rc=$rc $out"
grep -qF "$THEIRS" <<<"$res" && ok "A2 the prior agent's text survives VERBATIM" || no "A2 prior verbatim" "$res"
grep -qF "$MINE"   <<<"$res" && ok "A3 the new text is present too" || no "A3 new text present" "$res"
# ORDER is load-bearing: the existing record is the one that must survive on top.
[ "${res#"$THEIRS"}" != "$res" ] && ok "A4 the prior text comes FIRST" || no "A4 prior text first" "$res"

echo "== B. the flag was the REMEDY, not the mechanism: a BARE write preserves too =="
# DIVE-2717's finding is that an operator reaches for --append-result exactly when
# they perceive the risk and it silently no-opped. Making preservation the DEFAULT
# is what removes the class; if this arm reds, the fix is still a flag.
id=$(seed in_progress "$THEIRS")
out=$( cmd_task_done "$id" --result="$MINE" 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
[ "$rc" -eq 0 ] && ok "B1 a BARE --result= on an open row is accepted (not refused — refusing wedges the rail)" || no "B1 bare accepted" "rc=$rc $out"
grep -qF "$THEIRS" <<<"$res" && ok "B2 and it preserves the prior text with NO flag passed" || no "B2 bare preserves" "$res"
grep -qF "$MINE"   <<<"$res" && ok "B3 and the new text landed" || no "B3 bare new text" "$res"

echo "== C. EMPTY --result= over a non-empty column: refused at EVERY status and flag =="
# The row's headline case: a killed heredoc expanded to nothing and the verb replaced
# a 2.6KB note with a zero-length string, exit 0. This is the least visible loss
# available — a blank field is indistinguishable from one nobody wrote — which is why
# it gets no escape hatch, not even --force-result.
id=$(seed in_progress "$THEIRS")
out=$( cmd_task_done "$id" --result="" 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
[ "$rc" -ne 0 ] && ok "C1 an EMPTY --result= over a non-empty column is REFUSED on an OPEN row (rc=$rc)" || no "C1 empty refused open" "rc=$rc $out"
[ "$res" = "$THEIRS" ] && ok "C2 and the prior text is INTACT after the refusal" || no "C2 intact after refusal" "$res"
grep -q 'DIVE-2483' <<<"$out" && ok "C3 the refusal cites DIVE-2483" || no "C3 cites DIVE-2483" "$out"

id=$(seed done "$THEIRS")
out=$( cmd_task_done "$id" --result="" 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && ok "C4 ...refused on a CLOSED row too (status is not the key)" || no "C4 empty refused closed" "rc=$rc $out"

id=$(seed in_progress "$THEIRS")
out=$( cmd_task_done "$id" --force-result --result="" 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
[ "$rc" -ne 0 ] && ok "C5 ...and --force-result does NOT buy a blanking (the one path with no escape)" || no "C5 force cannot blank" "rc=$rc $out"
[ "$res" = "$THEIRS" ] && ok "C6 the text survived the --force-result attempt" || no "C6 survived force blank" "$res"

echo "== D. --force-result still REPLACES on an open row, and says so =="
# The lossy escape must remain reachable when the recorded text is genuinely wrong,
# and it must remain the only path that announces itself.
id=$(seed in_progress "$THEIRS")
out=$( cmd_task_done "$id" --force-result --result="$MINE" 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
[ "$rc" -eq 0 ] && ok "D1 --force-result on an open row is accepted" || no "D1 force accepted" "rc=$rc $out"
! grep -qF "$THEIRS" <<<"$res" && ok "D2 --force-result REPLACES (that is its job)" || no "D2 force replaces" "$res"
grep -q 'force-result' <<<"$out" && ok "D3 the replace is ANNOUNCED on stderr, not silent" || no "D3 force announced" "$out"

echo "== E. task verify: the THIRD writer, unguarded on the not-done path =="
# DIVE-2624: a delivered row is NOT done, so DIVE-2067's preservation (which sits
# inside `if [[ $_v_st == done ]]`) never ran, and the verify verdict replaced the
# maker's delivery record outright.
id=$(seedv in_progress "$THEIRS" olivia "")
out=$( cmd_task_verify "$id" --cmd="true" --no-done 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
grep -qF "$THEIRS" <<<"$res" && ok "E1 'task verify --cmd' on an OPEN row PRESERVES the prior result (DIVE-2624)" || no "E1 verify preserves" "rc=$rc res=$res"
grep -q 'verify PASS' <<<"$res" && ok "E2 and the verify verdict is recorded too" || no "E2 verdict recorded" "$res"

echo "== R. REGRESSION: the reject -> re-deliver rail is NOT wedged =="
# This is why the decision was auto-append and not refuse. `task reject` writes the
# VERIFIER'S feedback into result, so iteration 2 is a maker writing over someone
# else's text on an open row — the exact cell above. If this reds, every graded task
# on the fleet stops at its second iteration.
id=$(seedv in_progress "olivia: REJECT — the error path is untested, add an arm." dev main)
out=$( cmd_task_done "$id" --result="dev: iteration 2, arm added." 2>&1 ); rc=$?
st=$(db  "SELECT status FROM tasks WHERE id=$id;")
asg=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=$id;")
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
[ "$rc" -eq 0 ] && ok "R1 a re-delivery over the verifier's feedback is NOT refused (rc=0)" || no "R1 re-delivery not refused" "rc=$rc $out"
[ "$asg" = "main" ] && ok "R2 and it still ROUTES to the verifier (DIVE-477 rail intact)" || no "R2 still routes" "assignee=$asg st=$st"
grep -qF "REJECT — the error path is untested" <<<"$res" && ok "R3 and the verifier's feedback was PRESERVED, not overwritten" || no "R3 feedback preserved" "$res"

echo "== N. NON-VACUITY: prove these arms can go red =="
# Every arm above asserts a PRESENCE in a column. A guard that appended unconditionally
# — or one that never wrote at all — could satisfy several of them by accident. These
# two anchors pin the cells where nothing should change, so the arms above are
# measuring the guard and not the fixture.
id=$(seed in_progress "")
out=$( cmd_task_done "$id" --result="$MINE" 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
[ "$rc" -eq 0 ] && [ "$res" = "$MINE" ] && ok "N1 an EMPTY prior column takes the new text CLEANLY (no marker, nothing to preserve)" || no "N1 empty prior clean" "rc=$rc res=$res"
! grep -q 'DIVE-2483' <<<"$res" && ok "N2 and no append marker is added when there was nothing to append to" || no "N2 no spurious marker" "$res"

id=$(seed in_progress "$THEIRS")
out=$( cmd_task_done "$id" --result="$THEIRS" 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
[ "$res" = "$THEIRS" ] && ok "N3 an IDENTICAL --result= is a no-op, not a self-append (no duplication)" || no "N3 identical no-op" "$res"

echo "== O. WHAT THE OPERATOR SEES — a different assertion shape, deliberately =="
# DIVE-2483 iteration 2, from olivia's reject. Every arm above this point ends in
# SELECT result FROM tasks and compares strings. The gate answer named FOUR
# conditions; the two expressible as COLUMN STATE shipped, and the two about what
# the operator SEES were dropped — and this harness had zero arms on either,
# because an arm about stdout needs a different shape than an arm about the DB.
# That is the transferable finding: a state-asserting harness has no natural home
# for an output condition, so those are exactly the conditions a maker's own
# harness declines to grade. These arms are that home.
id=$(seed in_progress "$THEIRS")
out=$( cmd_task_done "$id" --result="$MINE" 2>&1 ); rc=$?
res=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=$id;")
grep -q "PRESERVED, not replaced" <<<"$out" \
  && ok "O1 the append is ANNOUNCED — a bare open-row close no longer prints only 'done'" \
  || no "O1 preservation announced" "operator saw: ${out:0:200}"
grep -qE "[0-9]+ bytes kept" <<<"$out" \
  && ok "O2 the announcement carries the PRIOR BYTE COUNT (falsifiable at a glance)" \
  || no "O2 byte count present" "$out"
grep -qF "${#THEIRS} bytes kept" <<<"$out" \
  && ok "O3 ...and the byte count is CORRECT (${#THEIRS})" \
  || no "O3 byte count correct" "expected ${#THEIRS}; saw: $out"
# THE SEAM IS THE PROVENANCE — there is no result_by column, so an undated marker
# says two texts were joined and nothing about when.
grep -qE 'appended [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z by a later write' <<<"$res" \
  && ok "O4 the seam marker carries a UTC TIMESTAMP, not a static string" \
  || no "O4 seam is dated" "$res"
# NOT NOISE: the announcement must not fire when there was nothing to preserve.
id=$(seed in_progress "")
out=$( cmd_task_done "$id" --result="$MINE" 2>&1 ); rc=$?
! grep -q "PRESERVED, not replaced" <<<"$out" \
  && ok "O5 no announcement when the column was empty (it is a signal, not a banner)" \
  || no "O5 announcement not always-on" "$out"
# AND IT REACHES THE VERIFY PATH, which is the third writer and the one DIVE-2624
# lost a record through.
id=$(seedv in_progress "$THEIRS" olivia "")
out=$( cmd_task_verify "$id" --cmd="true" --no-done 2>&1 ); rc=$?
grep -q "PRESERVED, not replaced" <<<"$out" \
  && ok "O6 'task verify' announces the preservation too (DIVE-2624's writer)" \
  || no "O6 verify announces" "${out:0:200}"

# WHICH STREAM — DIVE-2748. Every arm above captures `2>&1`, which MERGES the two
# channels before comparing, so O1-O3/O6 are satisfied whether the announcement
# lands on stdout or on stderr: the set above cannot fail in the direction of the
# routing half of the condition (the gate answer said "stdout"; the code uses the
# fleet's warn(), which is stderr). That is not a cosmetic gap — a scripted caller,
# a log pipeline or a CI step that keeps only stdout sees the PRE-FIX bytes, and
# automated readers are exactly the population still blind.
#
# The convention is not the defect: an advisory must not corrupt a parsed stdout,
# so fd 2 is right and moving a fleet-wide warn() is not this row's call. What was
# missing is that the limit was a CHANGELOG COMMENT and comments do not go red.
# These three arms make it a measured fact — capture ONE stream per arm, because
# any assertion that merges two channels can grade the CONTENT and never the
# CHANNEL. Keep the merged arms above; they still grade the content.
id=$(seed in_progress "$THEIRS")
err_only=$( cmd_task_done "$id" --result="$MINE" 2>&1 >/dev/null )
grep -q "PRESERVED, not replaced" <<<"$err_only" && grep -qF "${#THEIRS} bytes kept" <<<"$err_only" \
  && ok "O7 the announcement is carried by STDERR ALONE (2>&1 >/dev/null), byte count and all" \
  || no "O7 announcement on stderr" "stderr alone: ${err_only:0:200}"
# The other side of the same fact, and the one a merged arm can never state: the
# operator sees it, a stdout-only reader does NOT. If someone moves the warn() to
# stdout this reds, which is the point — the convention becomes a decision with a
# guard on it rather than a sentence in a changelog.
id=$(seed in_progress "$THEIRS")
out_only=$( cmd_task_done "$id" --result="$MINE" 2>/dev/null )
! grep -q "PRESERVED, not replaced" <<<"$out_only" \
  && ok "O8 ...and STDOUT ALONE (2>/dev/null) does NOT carry it — stderr is the convention" \
  || no "O8 announcement absent from stdout" "stdout alone: ${out_only:0:200}"
# NON-VACUITY for O8, which is a NEGATIVE arm on a capture: an empty $out_only
# would satisfy it for reasons that have nothing to do with routing (a die before
# any print, a changed verb name, a broken fixture). Anchor it on what stdout DOES
# carry, so O8 is graded against real output rather than against silence.
grep -q 'done' <<<"$out_only" \
  && ok "O9 stdout alone is NOT empty — it still carries the close line (O8 grades routing, not silence)" \
  || no "O9 stdout carries the close line" "stdout alone: ${out_only:0:200}"

echo
echo "DIVE-2483 result-loss-on-open-row guard: passed: $P  failed: $F"
[ "$F" -eq 0 ]
