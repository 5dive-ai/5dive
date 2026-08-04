#!/usr/bin/env bash
# DIVE-2692 corpus contract: every harness in tests/*.sh carries the
# HARNESS-RC EXIT trap (DIVE-2573 landed the mechanism; DIVE-2692 extended it
# from 13 to the full corpus).
#
# WHY THIS EXISTS AT ALL (olivia, reviewing DIVE-2692): the ticket's own body
# is that DIVE-2573 shipped covering "the 12 graded harnesses" when that 12
# was a SUBSET, not the corpus — and while DIVE-2692 was in flight, 4 more
# harnesses landed on origin/main via unrelated PRs, uncovered, which is the
# exact same shape recurring a third time. A follow-up ticket for the next
# batch just ages into the next residue the moment one more harness lands.
# This file converts that unbounded recurring chore into a one-time gate: the
# next harness that lands without the trap fails THIS check, in CI, on its
# own PR — not a future ticket someone has to notice is needed.
#
# It is a CONTRACT test rather than a run of the corpus (see
# tests/names_the_tree_contract_unit.sh, the DIVE-2211 sibling this is
# modeled on) because executing 300+ harnesses to observe one line each costs
# minutes and would grade the corpus, not the property. The cost is the seam
# above; the seam is named, not hidden. tests/lib/*.sh is out of scope by
# construction (the tests/*.sh glob does not reach it) — DIVE-2692's own body
# argues sourced libraries stay excluded, since a trap or shell option in a
# sourced file leaks into every caller.
#
# Sources src/ nothing at all (no root, no network). Run:
#   bash tests/harness_rc_corpus_contract_unit.sh
set -uo pipefail
trap 'rc=$?; rm -rf "${MUTTMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: this file is itself part of the corpus it enforces; folds in the mutation tempdir cleanup below so a second `trap ... EXIT` doesn't silently replace this one.

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nok() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# COULD-NOT-RUN IS ITS OWN BRANCH, and it REFUSES rather than reporting green —
# a corpus enumeration that silently collapsed is the exact "green suite either
# way" failure mode this file exists to close off.
shopt -s nullglob
CORPUS=(tests/*.sh)
shopt -u nullglob
if (( ${#CORPUS[@]} == 0 )); then
  printf 'FAIL - could not run: tests/*.sh enumerated 0 harnesses; this file asserts nothing\n'
  exit 1
fi
# Floor deliberately far below the real count (300+): a collapse detector, not
# a pin that has to be bumped on every new harness.
if (( ${#CORPUS[@]} < 50 )); then
  printf 'FAIL - could not run: tests/*.sh enumerated only %d harnesses; expected the full corpus\n' "${#CORPUS[@]}"
  exit 1
fi
ok "corpus enumerates ${#CORPUS[@]} harnesses"

# What matters is "a trap that fires on every EXIT and echoes the marker",
# not one exact spelling. Every author's cleanup differs (rm -rf a tempdir,
# a named cleanup() with rc threaded through as $1, folding into a
# pre-existing ABORT-marker trap, ${VAR:-} hardening for set -u, ...) — the
# invariant is trap ... HARNESS-RC=$rc ... EXIT co-occurring on one line,
# which is how bash traps are written throughout this corpus.
#
# olivia (reviewing this file at e6524ed): presence-and-reference alone is
# not enough. `trap 'cleanup; rc=$?; echo "HARNESS-RC=$rc"' EXIT` matches a
# looser regex here but is the EXACT hazard this ticket hand-fixed in 3 files
# and threaded through cleanup's own $1 in gate_answer_audit_unit.sh: if
# cleanup runs (or fails) before `rc=$?` captures the real exit code, $? has
# already been overwritten by cleanup's own status by the time it's read.
# Measured: `cleanup(){ :; }; trap 'cleanup; rc=$?; echo HARNESS-RC=$rc' EXIT;
# exit 7` reports HARNESS-RC=0, not 7. The invariant this regex enforces is
# therefore narrower than "references $rc somewhere" — it requires `rc=$?` to
# be the FIRST thing the trap body does, before any cleanup can run and
# disturb $?. Measured against the pushed tree: rejects 0 of 309 (every
# current file already opens this way).
RC_RE='trap .rc=\$\?;.*HARNESS-RC=\$rc.*EXIT'

MISSING=()
for t in "${CORPUS[@]}"; do
  grep -qE "$RC_RE" "$t" && continue
  MISSING+=("$t")
done

if (( ${#MISSING[@]} == 0 )); then
  ok "every harness in tests/*.sh carries the HARNESS-RC EXIT trap"
else
  nok "${#MISSING[@]} harness(es) do not carry the HARNESS-RC EXIT trap:"
  for m in "${MISSING[@]}"; do printf '       %s\n' "$m"; done
  printf '\n       FIX -- add, immediately after your set -[e]uo pipefail line (BEFORE any\n'
  printf '       early SKIP/precondition exit, so that path is covered too):\n\n'
  printf '           trap '"'"'rc=$?; <fold in any existing cleanup here>; echo "HARNESS-RC=$rc"'"'"' EXIT\n\n'
  printf '       bash keeps only the LAST trap registered per signal, so an existing\n'
  printf '       `trap ... EXIT` must be FOLDED into this one line, never left as a second\n'
  printf '       trap alongside it -- the second registration silently replaces the first.\n'
  printf '       See tests/names_the_tree_contract_unit.sh for the sibling corpus contract\n'
  printf '       this file is modeled on, and DIVE-2692 for the full writeup.\n'
fi

# MUTATION, not just reading the regex: a check that cannot fail proves
# nothing (this file's own sibling on DIVE-2211 exists partly to name that
# risk). Stage a throwaway harness missing the trap and confirm THIS FILE's
# own detector -- run against a corpus of exactly one -- calls it missing;
# then stage one carrying it and confirm the same detector calls it present.
# Never touches the real tests/ tree.
MUTTMP="$(mktemp -d /tmp/harness-rc-contract-mut.XXXXXX)"

printf '#!/usr/bin/env bash\nset -uo pipefail\necho hi\n' > "$MUTTMP/no_trap_unit.sh"
if grep -qE "$RC_RE" "$MUTTMP/no_trap_unit.sh"; then
  nok "mutation: a harness with NO trap at all is (wrongly) reported present"
else
  ok "mutation: a harness with no trap at all is correctly reported MISSING"
fi

printf '#!/usr/bin/env bash\nset -uo pipefail\ntrap '"'"'rc=$?; echo "HARNESS-RC=$rc"'"'"' EXIT\necho hi\n' > "$MUTTMP/has_trap_unit.sh"
if grep -qE "$RC_RE" "$MUTTMP/has_trap_unit.sh"; then
  ok "mutation: a harness carrying the trap is correctly reported PRESENT (the check can pass, not just fail)"
else
  nok "mutation: a harness carrying the trap is (wrongly) reported missing"
fi

# A trap missing the ECHO (cleanup only, no marker) must still be caught --
# guards against a detector that fires on the bare word "trap ... EXIT".
printf '#!/usr/bin/env bash\nset -uo pipefail\ntrap '"'"'rm -rf /tmp/whatever'"'"' EXIT\necho hi\n' > "$MUTTMP/cleanup_only_unit.sh"
if grep -qE "$RC_RE" "$MUTTMP/cleanup_only_unit.sh"; then
  nok "mutation: a trap with cleanup but no HARNESS-RC echo is (wrongly) reported present"
else
  ok "mutation: a trap with cleanup but no HARNESS-RC echo is correctly reported MISSING"
fi

# THE HAZARDOUS ORDERING (olivia's finding): cleanup BEFORE rc=$? captures the
# real exit code, so by the time it's read $? has already been overwritten by
# cleanup's own status. This is a static grep check, but its value is what it
# discriminates at RUNTIME, so confirm both halves: the static detector must
# reject the file, AND actually running the hazardous form on a real non-zero
# exit must misreport 0 -- proving there is a live bug here for the detector
# to be worth rejecting, not just a shape the regex happens to dislike.
printf '#!/usr/bin/env bash\nset -uo pipefail\ncleanup() { :; }\ntrap '"'"'cleanup; rc=$?; echo "HARNESS-RC=$rc"'"'"' EXIT\nexit 7\n' > "$MUTTMP/hazardous_order_unit.sh"
if grep -qE "$RC_RE" "$MUTTMP/hazardous_order_unit.sh"; then
  nok "mutation: the hazardous cleanup-before-rc ordering is (wrongly) reported present"
else
  ok "mutation: the hazardous cleanup-before-rc ordering is correctly reported MISSING"
fi
HAZ_OUT="$(bash "$MUTTMP/hazardous_order_unit.sh" 2>&1)"
if [[ "$HAZ_OUT" == *"HARNESS-RC=0"* ]]; then
  ok "mutation: the hazardous form is a LIVE bug, not just a disliked shape -- exit 7 misreports as HARNESS-RC=0 at runtime"
else
  nok "mutation: expected the hazardous form to misreport rc at runtime (got: $HAZ_OUT) -- the arm above is not grading a real hazard"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
