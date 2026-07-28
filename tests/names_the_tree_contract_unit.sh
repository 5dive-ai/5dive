#!/usr/bin/env bash
# DIVE-2211 -- the corpus invariant: every harness in tests/*.sh NAMES THE TREE
# IT GRADES.
#
# WHAT THIS CREDITS, stated because a control that reds for the wrong reason is
# worse than no control: this file establishes that each harness SOURCES
# tests/lib/grading_tree.sh.  It credits the source line, not the emitted line.
# What the helper actually prints -- and that it prints the right thing in each
# of its three outcomes -- is graded by tests/grading_tree_unit.sh.  Neither
# file is sufficient alone and the pair is only sound together, which is why
# this comment names the other half instead of implying coverage it lacks.
#
# It is a CONTRACT test rather than a run of the corpus because running 200+
# harnesses to observe one line each costs minutes and would grade the corpus,
# not the property.  The cost is the seam above; the seam is named, not hidden.
#
# WHY THIS EXISTS AT ALL: without it the property decays silently on the next
# harness anyone adds, and its absence looks exactly like its presence -- a
# green suite either way.  That is the same wrong-target shape one level up.
set -uo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=lib/grading_tree.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nok() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

HELPER="tests/lib/grading_tree.sh"

# COULD-NOT-RUN IS ITS OWN BRANCH, and it REFUSES.  If the helper is missing or
# the corpus does not enumerate, this file must not fall toward "everything is
# fine" -- a check that cannot run and reports green is the defect this whole
# ticket is about, reintroduced by its own guard.
if [[ ! -f "$HELPER" ]]; then
  printf 'FAIL - could not run: %s is missing; this file asserts nothing\n' "$HELPER"
  exit 1
fi

shopt -s nullglob
CORPUS=(tests/*.sh)
shopt -u nullglob
if (( ${#CORPUS[@]} == 0 )); then
  printf 'FAIL - could not run: tests/*.sh enumerated 0 harnesses; this file asserts nothing\n'
  exit 1
fi
# A corpus that has silently collapsed is could-not-run wearing a green hat.
# The floor is deliberately far below the real count (200+): this is a
# collapse detector, not a pin that has to be maintained on every new harness.
if (( ${#CORPUS[@]} < 50 )); then
  printf 'FAIL - could not run: tests/*.sh enumerated only %d harnesses; expected the full corpus\n' "${#CORPUS[@]}"
  exit 1
fi
ok "corpus enumerates ${#CORPUS[@]} harnesses"

MISSING=()
for t in "${CORPUS[@]}"; do
  # The source line, whatever spelling: what matters is that this harness pulls
  # in the helper, so its log cannot be silent about which tree it graded.
  if grep -qE '(^|[[:space:]])(\.|source)[[:space:]].*lib/grading_tree\.sh' "$t"; then
    continue
  fi
  MISSING+=("$t")
done

if (( ${#MISSING[@]} == 0 )); then
  ok "every harness in tests/*.sh sources $HELPER"
else
  nok "${#MISSING[@]} harness(es) do not source $HELPER -- their logs name no tree:"
  for m in "${MISSING[@]}"; do printf '       %s\n' "$m"; done
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
