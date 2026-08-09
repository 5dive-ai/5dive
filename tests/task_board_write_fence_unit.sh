#!/usr/bin/env bash
# DIVE-3077 — the board WRITE fence, and the runner marker that raises its signal.
#
# WHAT THIS GRADES, and why each arm is here rather than only the happy one:
#
#   1. The runner exports a marker AT ALL. DIVE-3075 measured the failure mode this
#      closes: `_task_human_send_allowed` has read FIVEDIVE_TEST since DIVE-1506, and
#      across 344 harnesses FIVEDIVE_TEST was set by ZERO files. A control that reads
#      a flag nobody sets is an absent control wearing a control's shape, so "the
#      predicate exists" is NOT the property to assert — "something raises it" is.
#
#   2. The marker the runner exports is NOT FIVEDIVE_TEST. That was the filed fix and
#      it was measured to break 25 of the 29 harnesses that point
#      FIVEDIVE_PROD_TASKS_DB at their own fixture store to exercise the SEND
#      predicate's allowed arm. This arm pins the separation so a later "simplifying"
#      edit that collapses the two flags back together goes red here instead of in
#      those 25.
#
#   3. The fence REFUSES a marked run writing to the real prod board.
#   4. The fence ALLOWS a marked run writing to its own throwaway store — the case
#      nearly every harness in the corpus is, and the one an inverted send-predicate
#      would have broken.
#   5. The fence ALLOWS an unmarked run against prod — this is an ORDINARY agent
#      filing a real row, and a fence that blocked it would be a product outage.
#      Without this arm every other arm is satisfied by a fence that refuses always.
#   6. The refusal is ANNOUNCED and non-zero. A silent no-op fence is the same
#      fail-open shape as no fence (DIVE-1968 assertion 2).
#   7. FIVEDIVE_PROD_TASKS_DB cannot talk the fence out of the real prod path — the
#      deliberate asymmetry with the send predicate, asserted so it is not "fixed".
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
D=$(mktemp -d)
# DIVE-2692: the corpus HARNESS-RC contract. The temp-dir cleanup is FOLDED IN
# rather than registered as a second EXIT trap — bash keeps only the last one.
trap 'rc=$?; rm -rf "$D"; echo "HARNESS-RC=$rc"' EXIT
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 2

PASS=0; FAIL=0
ok() { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
no() { printf 'FAIL - %s\n' "$1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------- arms 1 and 2
RUNNER=scripts/run-harnesses.sh
if grep -Eq '^export FIVEDIVE_HARNESS=1' "$RUNNER"; then
  ok "the runner exports FIVEDIVE_HARNESS=1 (something raises the signal the fence reads)"
else
  no "$RUNNER does not export FIVEDIVE_HARNESS=1 — the fence reads a flag nobody sets"
fi
if grep -Eq '^export FIVEDIVE_TEST=' "$RUNNER"; then
  no "$RUNNER exports FIVEDIVE_TEST — that forces _task_human_send_allowed to refuse regardless of store path and reds the 29 harnesses that simulate prod (measured 25/29)"
else
  ok "the runner does NOT export FIVEDIVE_TEST (send rail left alone)"
fi

# ------------------------------------------------- load the predicate under test
# Source the built bundle's function in isolation. Sourcing the whole CLI would run
# its dispatcher, so extract just what this fence needs.
# Extract to a file and source it: the definition spans continuation lines, which
# `eval "$(...)"` mangles.
# NB `_task_real_prod_tasks_db` is a ONE-LINER — its closing brace is not at column
# 0, so a `/^}/`-terminated range would run past it and swallow the next function.
grep -E '^_task_real_prod_tasks_db\(\)' src/cmd_task.sh  >"$D/fence.sh"
sed -n '/^_task_board_write_allowed()/,/^}/p' src/cmd_task.sh >>"$D/fence.sh"
# shellcheck disable=SC1090
. "$D/fence.sh"

if ! declare -F _task_board_write_allowed >/dev/null; then
  no "could not load _task_board_write_allowed out of src/cmd_task.sh"
  printf '%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi

# With the seam UNSET the fence must resolve the real board — otherwise every arm
# below grades a fence pointed at nothing.
PROD=$(unset FIVEDIVE_FENCE_PROD_DB; _task_real_prod_tasks_db)
[[ "$PROD" == "/var/lib/5dive/tasks/tasks.db" ]] \
  && ok "with FIVEDIVE_FENCE_PROD_DB unset the fence's prod path is the REAL board ($PROD)" \
  || no "unexpected prod path with the seam unset: $PROD"

# From here on, "prod" is a FAKE in a temp dir. The e2e arms drive a real `task add`
# down the refuse path, and if the fence regresses that call SUCCEEDS — so pointing
# it at the real board would file a live fixture row on exactly the run that is
# telling you the guard broke. That happened during this ticket's mutation testing
# and put DIVE-3084 on the live board. The test for a fence must not be able to
# commit the act the fence prevents.
FAKE_PROD="$D/fakeprod/tasks/tasks.db"
mkdir -p "$D/fakeprod/tasks"
export FIVEDIVE_FENCE_PROD_DB="$FAKE_PROD"
PROD="$FAKE_PROD"

# ------------------------------------------------------------------- arms 3-5,7
for m in FIVEDIVE_HARNESS FIVEDIVE_TEST FIVEDIVE_E2E COUNCIL_MOCK FIVEDIVE_NO_HUMAN_SEND; do
  ( export "$m=1"; export TASKS_DB="$PROD"; unset FIVEDIVE_PROD_TASKS_DB
    _task_board_write_allowed ) && rc=0 || rc=1
  [[ "$rc" == "1" ]] \
    && ok "REFUSED: $m set + TASKS_DB is the prod board" \
    || no "$m set + prod board was ALLOWED — the fence is open"
done

( export FIVEDIVE_HARNESS=1; export TASKS_DB="$D/tasks.db"; _task_board_write_allowed ) && rc=0 || rc=1
[[ "$rc" == "0" ]] \
  && ok "ALLOWED: marked run writing to its OWN throwaway store (the normal harness case)" \
  || no "a marked run was refused against its own store — this would break the corpus"

# The control arm whose expected value is NON-ZERO: without it, a fence that always
# refuses passes every arm above.
( unset FIVEDIVE_HARNESS FIVEDIVE_TEST FIVEDIVE_E2E COUNCIL_MOCK FIVEDIVE_NO_HUMAN_SEND
  export TASKS_DB="$PROD"; _task_board_write_allowed ) && rc=0 || rc=1
[[ "$rc" == "0" ]] \
  && ok "ALLOWED: UNMARKED run against the prod board (an ordinary agent filing a real row)" \
  || no "an unmarked run was refused against prod — the fence is a product outage"

# arm 7: the caller may not redefine what it is being fenced away from.
( export FIVEDIVE_HARNESS=1; export TASKS_DB="$PROD"
  export FIVEDIVE_PROD_TASKS_DB="$D/not-prod.db"; _task_board_write_allowed ) && rc=0 || rc=1
[[ "$rc" == "1" ]] \
  && ok "FIVEDIVE_PROD_TASKS_DB cannot talk the fence off the real prod path" \
  || no "an override of FIVEDIVE_PROD_TASKS_DB opened the fence — fail-open by construction"

# --------------------------------------------------- arm 6: announced, end to end
# Drive the real built CLI, not the extracted function, so the wiring at the
# cmd_task_add call site is graded and not only the predicate.
BUNDLE=./5dive
if [[ -x "$BUNDLE" ]]; then
  out=$(FIVEDIVE_HARNESS=1 FIVEDIVE_FENCE_PROD_DB="$FAKE_PROD" TASKS_DB="$PROD" TASKS_DIR="$D/fakeprod/tasks" STATE_DIR="$D/fakeprod" "$BUNDLE" task add "fence probe DIVE-3077" 2>&1); rc=$?
  [[ "$rc" != "0" ]] \
    && ok "e2e: \`task add\` under the marker against prod EXITS NON-ZERO (rc=$rc)" \
    || no "e2e: \`task add\` under the marker against prod exited 0 — the row landed"
  # Match the fence's OWN sentence, not merely a non-zero exit: `task add` has other
  # rc!=0 paths (an uninitialised store also exits 10), so a bare rc check would be
  # satisfied by the CLI failing for an unrelated reason.
  grep -qi 'refusing to write to the production task board' <<<"$out" \
    && ok "e2e: the refusal is ANNOUNCED by the fence itself, not a silent no-op or an unrelated error" \
    || no "e2e: no fence refusal in output; got: ${out:0:200}"
  # And the corresponding non-zero control: the same call against a throwaway store
  # must SUCCEED, or the arm above is satisfied by the CLI being broken.
  # tasks_db_init refuses to create TASKS_DIR as non-root, so seed it the way the
  # rest of the corpus does.
  mkdir -p "$D/state/tasks"
  out2=$(FIVEDIVE_HARNESS=1 STATE_DIR="$D/state" TASKS_DIR="$D/state/tasks" \
         TASKS_DB="$D/state/tasks/tasks.db" \
         "$BUNDLE" task add "fence control DIVE-3077" 2>&1); rc2=$?
  [[ "$rc2" == "0" ]] \
    && ok "e2e control: the same call against a throwaway store SUCCEEDS (rc=0)" \
    || no "e2e control: throwaway-store add failed rc=$rc2 — ${out2:0:200}"
else
  no "no built bundle at $BUNDLE — run ./build.sh first (the e2e arms did not run)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
# The EXIT trap emits HARNESS-RC — do not echo it here too (DIVE-2692).
[[ "$FAIL" == "0" ]] || exit 1
exit 0
