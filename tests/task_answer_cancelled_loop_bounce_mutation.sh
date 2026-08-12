#!/usr/bin/env bash
# TIER: nightly — 4.9s measured on ubuntu-latest by the core/installed-host runner itself (run 31292045115, 2026-08-09; the tier report's own top-10 line). Demoted under the mutation-harness rule (DIVE-2867): same class as gate_evidence_form_mutation.sh — a copied source tree per mutant, cost fixed by construction. Three of six *_mutation.sh files were already nightly before this change.
# DIVE-2261 connectivity grade: delete the cancelled-status refusal from a
# copied source tree and require the named C1 arm to turn red.
# Run: bash tests/task_answer_cancelled_loop_bounce_mutation.sh
# shellcheck disable=SC2016
set -uo pipefail

# shellcheck source=tests/lib/grading_tree.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.." || exit
TMP="$(mktemp -d /tmp/task-answer-cancelled-loop-bounce-mut.XXXXXX)"
mkdir -p "$TMP/tree"
cp -r src "$TMP/tree/src"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }

target="$TMP/tree/src/task/answer.sh"   # DIVE-3278: was src/cmd_task.sh
old='  if (( _loop_bounce )) && [[ "$_prev_status" == "cancelled" ]]; then'
new='  if false; then'
if OLD="$old" NEW="$new" F="$target" python3 - <<'PY'
import os, sys
p, old, new = os.environ["F"], os.environ["OLD"], os.environ["NEW"]
s = open(p).read()
n = s.count(old)
if n != 1:
    sys.stderr.write("mutation did not apply cleanly: %d matching anchors\n" % n)
    sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
then
  ok_t "mutation anchor applies exactly once"
  if bash -n "$target"; then
    ok_t "mutated source still parses"
    out=$(DIVE2261_SRC_DIR="$TMP/tree/src" bash tests/task_answer_cancelled_loop_bounce_unit.sh 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
      bad_t "suite goes red after deleting the cancelled-step refusal" "$out"
    elif grep -q '^FAIL - C1 cancelled previous step is refused' <<<"$out"; then
      ok_t "landed source mutation kills the C1 refusal arm"
    else
      bad_t "mutant kills the named C1 refusal arm" "$out"
    fi
  else
    bad_t "mutated source still parses" "the mutation produced a syntax error"
  fi
else
  bad_t "mutation anchor applies exactly once" "the anchor is absent or duplicated"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
