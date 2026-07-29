#!/usr/bin/env bash
# DIVE-2325 — a harness must not inherit the caller's product knobs.
#
# THE INCIDENT. task_core_unit (28/7) and task_verifier_rail_unit (17/6) were red on
# the control-plane host and green in CI at the same commit. It presented as host
# state — the DIVE-1919 class where a harness leaks out of its isolation, which the
# unit-tests workflow comments warn about and which test-installed-host exists to
# catch. It was not host state, and no amount of seeding a runner would have
# reproduced it: `FIVE_VERIFY_DEFAULT=0` is in the caller's ENVIRONMENT. The DIVE-969
# rail reads `${FIVE_VERIFY_DEFAULT:-1}`, so the whole mechanism goes inert — not a
# wrong value, no mechanism at all (verifyDefaulted:false, verifySkipped:false,
# verifier:"").
#
# THE KNOB IS DELIBERATE FLEET POLICY — DO NOT DELETE IT TO GO GREEN. lodar set it
# for sixteen agents on 2026-07-29 00:49 via `EnvironmentFile=-/var/lib/5dive/agents.d/%i.env`,
# with the decision and a revert instruction written into each file. That is exactly
# why the fix lives HERE: the configuration is correct and permanent, so the harness
# is the only thing that can move. A harness asserting DIVE-969's DEFAULT behaviour
# while reading that default from the environment is grading fleet policy, not code.
#
# WHY IT MATTERS MORE THAN 13 ASSERTIONS: a suite that is red on the box everyone
# works on and green in CI trains the whole team to ignore red, and then a real
# failure reads as the usual noise. It had already cost one near-miss — a false
# regression nearly reported against a clean merge.
#
# WHAT IS GRADED HERE. The helper (T1-T4), THE SEAM that applies it to all 235
# harnesses (T5, with T6 as its differential anchor), and the incident itself
# end-to-end (T7). T8 pins the three-state behaviour of an unreachable helper.
#
# MUTATION GRADE — RUN, not predicted (2026-07-29; 12/0 clean):
#   * delete the `. .../env_isolation.sh` line from grading_tree.sh -> 7/3: T5, T7
#     and T8's UNRESOLVED arm. T7's captured output shows the rail harness back at
#     "17 passed, 6 failed" — the original incident, reproducing.
#   * unset without printing            -> 8/2: both T2 arms.
#   * print unconditionally             -> 9/1: T3.
#   * filter matches PATHY as well      -> 9/1: T4.
#   * VOID MUTATION, recorded so nobody wastes a run on it: widening the filter to
#     `grep ''` does NOT grade T4. It tries to unset BASHOPTS and dies on `!v:
#     unbound variable`, so the harness never reaches its summary — an absent
#     summary is not a red arm, it is a broken run. Mutate the filter to match one
#     EXTRA named variable instead. That run is also what surfaced the readonly
#     hazard the helper is now hardened against, so the void mutation was not
#     worthless — it just was not evidence about T4.
# Run: bash tests/env_isolation_unit.sh  (no root, no network.)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
LIB="tests/lib/env_isolation.sh"
SEAM="tests/lib/grading_tree.sh"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- T1: the helper UNSETS an inherited knob (not "sets it to a default"). -----
# Unset is the load-bearing choice: it restores the `:-` default that ships in
# src/, which is by construction what CI runs with. A hardcoded default here would
# be a second copy of a constant that lives in src/ and would drift out of it.
got=$(FIVE_VERIFY_DEFAULT=0 bash -c '. '"$LIB"' 2>/dev/null; printf "[%s]" "${FIVE_VERIFY_DEFAULT-UNSET}"')
[[ "$got" == "[UNSET]" ]] \
  && ok_t 'T1 an inherited FIVE_ knob is UNSET, so the src default applies' \
  || bad_t 'T1 knob not unset' "got=$got"

# --- T2: it ANNOUNCES what it cleared, on stderr. ------------------------------
# The line is the payload, not decoration: the operator whose shell carries the
# knob needs to know, because it is affecting their REAL `5dive` invocations too,
# which is the more expensive half and which no test can fix for them.
err=$(FIVE_VERIFY_DEFAULT=0 bash -c '. '"$LIB" 2>&1 >/dev/null)
[[ "$err" == *"CLEARED"* && "$err" == *"FIVE_VERIFY_DEFAULT=0"* ]] \
  && ok_t 'T2 it names the knob AND its value on stderr' \
  || bad_t 'T2 no announcement' "err=$err"
[[ "$err" == *"your real"* || "$err" == *"real \`5dive\`"* ]] \
  && ok_t 'T2 the line says the knob also affects real invocations, not just tests' \
  || bad_t 'T2 line must point past the test run' "err=$err"

# --- T3: SILENT on a clean environment, so the line means something when it appears.
err=$(env -u FIVE_VERIFY_DEFAULT bash -c '. '"$LIB" 2>&1 >/dev/null)
[[ -z "$err" ]] \
  && ok_t 'T3 silent when nothing was inherited (CI logs stay quiet)' \
  || bad_t 'T3 should be silent' "err=$err"

# --- T4: it touches ONLY the FIVE_ namespace. ---------------------------------
got=$(FIVE_X=1 PATHY=keepme bash -c '. '"$LIB"' 2>/dev/null; printf "[%s][%s]" "${PATHY-GONE}" "${FIVE_X-UNSET}"')
[[ "$got" == "[keepme][UNSET]" ]] \
  && ok_t 'T4 non-FIVE_ variables survive; the whole FIVE_ namespace does not' \
  || bad_t 'T4 wrong blast radius' "got=$got"

# --- T5: THE SEAM. This is what makes the fix cover all 235 harnesses rather
#     than the two that happened to be red. Every harness sources grading_tree.sh
#     near the top, before any fixture setup, so applying isolation there reaches
#     all of them without touching 235 files.
got=$(FIVE_VERIFY_DEFAULT=0 bash -c '. '"$SEAM"' 2>/dev/null; printf "[%s]" "${FIVE_VERIFY_DEFAULT-UNSET}"')
[[ "$got" == "[UNSET]" ]] \
  && ok_t 'T5 SEAM: sourcing grading_tree.sh alone clears the knob (covers every harness)' \
  || bad_t 'T5 seam not wired' "got=$got"

# --- T6: DIFFERENTIAL ANCHOR for T5. Without the source, the knob survives. A
#     harness asserting "the variable is unset" proves nothing if the variable was
#     never going to be set in the first place.
got=$(FIVE_VERIFY_DEFAULT=0 bash -c 'printf "[%s]" "${FIVE_VERIFY_DEFAULT-UNSET}"')
[[ "$got" == "[0]" ]] \
  && ok_t 'T6 ANCHOR: without the seam the knob IS inherited — T5 is not vacuous' \
  || bad_t 'T6 anchor broken' "got=$got"

# --- T7: THE INCIDENT, end to end. The knob that caused it, against the harness
#     it caused to fail. Pre-fix this is 17 passed / 6 failed. This arm is the one
#     that reds if someone removes the seam, and it is deliberately an integration
#     arm rather than another assertion about the helper: the helper being correct
#     and the harnesses being protected are different claims.
out=$(FIVE_VERIFY_DEFAULT=0 bash tests/task_verifier_rail_unit.sh 2>/dev/null | tail -3)
[[ "$out" == *"0 failed"* ]] \
  && ok_t 'T7 INCIDENT: the rail harness is GREEN with the knob leaked (was 17/6)' \
  || bad_t 'T7 incident reproduces' "out=$out"

# --- T8: an unreachable helper is its own third state — it must SAY so and must
#     not kill a `set -e` harness. Same discipline grading_tree.sh applies to
#     itself; a fix that turns a knob leak into a dead suite is not a fix.
tmp=$(mktemp -d /tmp/env-iso-unit.XXXXXX); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/lib"; cp "$SEAM" "$tmp/lib/"          # copy the seam WITHOUT the helper
out=$(set -e; bash -c 'set -e; . '"$tmp"'/lib/grading_tree.sh || printf "fallback\n" >&2; printf STILLALIVE' 2>"$tmp/err"); rc=$?
[[ $rc -eq 0 && "$out" == "STILLALIVE" ]] \
  && ok_t 'T8 a missing helper does not kill a set -e harness' \
  || bad_t 'T8 set -e survival' "rc=$rc out=$out err=$(cat "$tmp/err")"
grep -q 'env isolation: UNRESOLVED' "$tmp/err" \
  && ok_t 'T8 and it says UNRESOLVED — knobs NOT cleared, rather than falling silent' \
  || bad_t 'T8 must announce the third state' "err=$(cat "$tmp/err")"

# --- T9: a knob that CANNOT be cleared is reported as stuck and NOT as cleared,
#     and does not kill a `set -e` harness. Both halves found by mutation rather
#     than review: `unset` on a readonly variable fails, and the first cut of the
#     rollback (`${cleared% *}`) silently does nothing when there is exactly one
#     entry — so the helper announced the SAME knob as stuck and cleared at once.
#     A reporter for "work that did not happen was reported as done" does not get
#     to contain that bug.
err=$(bash -c 'declare -r FIVE_VERIFY_DEFAULT=0; set -e; . '"$LIB"'; printf ALIVE' 2>&1)
[[ "$err" == *"ALIVE"* ]] \
  && ok_t 'T9 a readonly knob does not kill a set -e harness' \
  || bad_t 'T9 set -e survival on readonly' "err=$err"
[[ "$err" == *"COULD NOT clear"* && "$err" == *"STILL IN EFFECT"* ]] \
  && ok_t 'T9 it is reported as stuck, and says the knob is still in effect' \
  || bad_t 'T9 stuck knob must be announced' "err=$err"
[[ "$err" != *"CLEARED inherited"* ]] \
  && ok_t 'T9 and it is NOT also announced as cleared — no report of work that did not happen' \
  || bad_t 'T9 stuck knob double-reported as cleared' "err=$err"

echo "-----"
printf 'env_isolation_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
