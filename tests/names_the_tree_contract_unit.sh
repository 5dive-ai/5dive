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
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# DIVE-2286: the detection regex below is shared with the push-time guard
# (scripts/harness-tree-guard.sh) via this one file, so the two cannot drift
# into checking two different things under the same name.
# shellcheck source=lib/grading_tree_source_re.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree_source_re.sh"

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

MISSING=(); PRESENT=()
for t in "${CORPUS[@]}"; do
  # The source line, whatever spelling: what matters is that this harness pulls
  # in the helper, so its log cannot be silent about which tree it graded.
  if grep -qE "$GRADING_TREE_SOURCE_RE" "$t"; then
    PRESENT+=("$t")
    continue
  fi
  MISSING+=("$t")
done

if (( ${#MISSING[@]} == 0 )); then
  ok "every harness in tests/*.sh sources $HELPER"
else
  nok "${#MISSING[@]} harness(es) do not source $HELPER -- their logs name no tree:"
  for m in "${MISSING[@]}"; do printf '       %s\n' "$m"; done

  # STATE THE FIX, do not merely name the file.  A corpus-wide invariant is a
  # STANDING OBLIGATION on every future harness author, and it is a MERGE-ORDER
  # hazard: two PRs each green in isolation red on merge, and whoever merges
  # second takes the hit through no fault of their own.  That author gets a red
  # they did not cause, in a file they did not write, and if the message only
  # names their file they will green it by whatever works -- which is exactly
  # how the `2>/dev/null` spelling that silenced the whole corpus gets
  # reintroduced.  The obligation ships WITH the invariant or the invariant
  # decays.  See also CONTRIBUTING.md "Testing".
  #
  # The block is COPIED FROM A LIVE PASSING HARNESS at failure time rather than
  # stored as a literal here.  Two reasons, both from this ticket: a stored copy
  # is a second target that drifts out of sync with the corpus and nothing would
  # grade the seam between them; and a literal source line in THIS file would
  # match the grep above, so deleting this file's own call site would still
  # report present -- the control weakened by the message that explains it.
  SNIPPET=""; EXEMPLAR=""
  for t in "${PRESENT[@]}"; do
    [[ "$t" == "tests/names_the_tree_contract_unit.sh" ]] && continue
    SNIPPET="$(awk '/^# DIVE-2211: name the tree/,/no tree named/' "$t")"
    # An unclosed awk range runs to EOF and would dump a whole harness, so the
    # extraction has to be confirmed, not assumed.
    if [[ -n "$SNIPPET" ]] \
       && [[ "$(printf '%s\n' "$SNIPPET" | wc -l)" -le 15 ]] \
       && printf '%s\n' "$SNIPPET" | grep -q 'no tree named'; then
      EXEMPLAR="$t"
      break
    fi
    SNIPPET=""
  done
  # Could-not-run is its own branch here too: if no exemplar can be extracted,
  # say that instead of printing an empty fix that reads like there isn't one.
  if [[ -n "$SNIPPET" ]]; then
    printf '\n       FIX -- paste this immediately after `set -uo pipefail`, copied verbatim from %s:\n\n' "$EXEMPLAR"
    printf '%s\n' "$SNIPPET" | sed 's/^/           /'
    printf '\n       Keep the ABSENCE of `2>/dev/null` on the source line: it would swallow the\n'
    printf '       helper stderr line, which IS the payload, and no other check would notice.\n'
  else
    printf '\n       FIX -- could not extract the canonical block from any passing harness;\n'
    printf '       copy the lines following `set -uo pipefail` in tests/grading_tree_unit.sh.\n'
  fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
