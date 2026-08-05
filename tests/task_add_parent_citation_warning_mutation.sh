#!/usr/bin/env bash
# TIER: core
# DIVE-2449 connection proof. Disconnect the production advisory with a
# syntax-valid source mutation, then prove only the warning arm goes red while
# the prose/--parent/nonexistent-ident controls remain green.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# set -e harness is not killed by a failed source. Keep stderr visible: the
# helper's own stderr line is the payload.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${MUT_TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT="$ROOT/tests/task_add_parent_citation_warning_unit.sh"
MUT_TMP="$(mktemp -d /tmp/task-add-parent-citation-mut.XXXXXX)"
PASS=0
FAIL=0
ok_t()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

set +e
base_out=$(DIVE_TEST_SRC="$ROOT/src" bash "$UNIT" 2>&1)
base_rc=$?
if (( base_rc == 0 )) && [[ "$base_out" == *'RESULT: 9 passed, 0 failed'* ]]; then
  ok_t "baseline harness is green before mutation"
else
  bad_t "baseline harness is green before mutation" "$base_out"
fi

cp -a "$ROOT/src" "$MUT_TMP/src"
target="$MUT_TMP/src/cmd_task.sh"
# shellcheck disable=SC2016
anchor='  _target_ident="$_TASK_FOLLOWUP_IDENT"'
anchor_count=$(grep -Fxc "$anchor" "$target")
if [[ "$anchor_count" == "1" ]]; then
  # shellcheck disable=SC2016
  sed -i 's/  _target_ident="$_TASK_FOLLOWUP_IDENT"/  _target_ident="" # DIVE-2449 mutation: parser result disconnected/' "$target"
fi
if [[ "$anchor_count" == "1" ]] \
   && grep -Fq 'DIVE-2449 mutation: parser result disconnected' "$target" \
   && ! grep -Fq "$anchor" "$target"; then
  ok_t "mutation anchor applied exactly once"
else
  bad_t "mutation anchor applied exactly once" "anchor_count=$anchor_count"
fi

if bash -n "$target"; then
  ok_t "mutated production source remains syntax-valid"
else
  bad_t "mutated production source remains syntax-valid"
fi

mut_out=$(DIVE_TEST_SRC="$MUT_TMP/src" bash "$UNIT" 2>&1)
mut_rc=$?
if (( mut_rc != 0 )) \
   && [[ "$mut_out" == *'FAIL - T1a'* ]] \
   && [[ "$mut_out" == *'FAIL - T1b'* ]] \
   && [[ "$mut_out" == *'FAIL - T1c'* ]]; then
  ok_t "disconnected advisory makes the required warning receipts fail"
else
  bad_t "disconnected advisory makes the required warning receipts fail" "$mut_out"
fi

if [[ "$mut_out" != *'FAIL - T2'* \
   && "$mut_out" != *'FAIL - T3'* \
   && "$mut_out" != *'FAIL - T4'* \
   && "$mut_out" != *'FAIL - T5'* \
   && "$mut_out" != *'FAIL - T6'* ]]; then
  ok_t "mutation leaves every false-positive and linked-child control green"
else
  bad_t "mutation leaves every false-positive and linked-child control green" "$mut_out"
fi

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
