#!/usr/bin/env bash
# DIVE-4164 isolated unit harness — the ephemeral grader's SPAWN TRIGGER.
#
# Grades three claims the design makes, one of which is STRUCTURAL and is
# therefore graded structurally rather than behaviourally:
#
#   1. NEVER MAKER-SPAWNED. The claim is not "the maker does not call it today",
#      it is "there is no path by which a maker can". That is a property of the
#      CALL GRAPH, so arm 1 asserts the only call site is inside
#      _task_route_to_verifier — the one funnel every delivery passes through.
#      A behavioural test cannot see this: it would pass just as well on a build
#      where `task deliver` ALSO called it directly, which is the defect.
#   2. A REQUEST, NOT A SPAWN. It writes a ledger row and returns; it must not
#      start anything, because `task done` blocking on a grader is the polling
#      wait deliver-on-push forbids.
#   3. NEVER FATAL. A bookkeeping write must not fail a delivery the store has
#      already durably recorded.
#
# Run: bash tests/grader_spawn_trigger_unit.sh
set -uo pipefail
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
PASS=0; FAIL=0
ok_()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_()  { FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }

# ── ARM 1 (structural): the ONLY call site is the system funnel ───────────────
# Body of _task_route_to_verifier = from its definition to the next line that is
# a bare `}` in column 1.
fn_body=$(awk '/^_task_route_to_verifier\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC/task/delivery.sh")
if [[ -z "$fn_body" ]]; then
  bad_ 'arm1: located _task_route_to_verifier' 'could not extract the function body'
else
  ok_ 'arm1a: _task_route_to_verifier body located'
fi
# EVERY reference outside its own file must lie INSIDE the funnel body.
# Stated as containment, not as a count: the invocation is guarded by a
# `declare -F` probe that names the function on its own line, so "one call site"
# is two matching LINES and a count would encode that incidental detail. The
# property being defended is containment — nothing calls it from outside the
# funnel — and containment is what is asserted.
outside=""
while IFS= read -r ln; do
  [[ -n "$ln" ]] || continue
  txt="${ln#*:*:}"
  [[ "$txt" =~ ^[[:space:]]*# ]] && continue
  grep -qF -- "$txt" <<<"$fn_body" || outside+="$ln"$'\n'
done < <(grep -rn '_grader_spawn_request' "$SRC" | grep -v 'src/task/grader_pool.sh' || true)
if [[ -z "$outside" ]]; then ok_ 'arm1b: no reference outside the funnel body'
else bad_ 'arm1b: no reference outside the funnel body' "$outside"; fi
# NON-COMMENT invocation, and the qualifier is load-bearing. Graded first as a
# bare `grep _grader_spawn_request` over the body, this arm SURVIVED a mutant
# that deleted the call outright — because the explanatory comment above the
# call says the function's name too, so the grep matched prose and reported the
# wiring present when it was gone. A test that can be satisfied by a comment is
# measuring the comment.
fn_calls=$(grep -v '^[[:space:]]*#' <<<"$fn_body" | grep -c '_grader_spawn_request "' || true)
if (( fn_calls >= 1 )); then
  ok_ 'arm1c: the funnel body contains a real (non-comment) invocation'
else
  bad_ 'arm1c: the funnel body contains a real (non-comment) invocation' \
       'only prose mentions it — the wiring is absent'
fi
# The maker-facing verbs must not call it directly, which is the defect shape.
for fn in cmd_task_deliver cmd_task_done; do
  body=$(awk -v f="^${fn}\\\\(\\\\) \\\\{" '$0~f{s=1} s{print} s&&/^\}$/{exit}' "$SRC"/task/*.sh 2>/dev/null)
  if grep -q '_grader_spawn_request' <<<"${body:-}"; then
    bad_ "arm1d: $fn does not call it directly" 'direct call found — a maker verb spawning its own judge'
  else ok_ "arm1d: $fn does not call it directly"; fi
done

# ── ARMS 2-3 (behavioural), against a recording stub ──────────────────────────
EMITS=""
ledger_emit() { EMITS+="$*"$'\n'; }
task_actor()  { printf 'dev'; }
# shellcheck source=/dev/null
source "$SRC/task/grader_pool.sh"

EMITS=""; _grader_spawn_request DIVE-1 42 main2 3; rc=$?
[[ $rc == 0 ]] && ok_ 'arm2a: returns 0' || bad_ 'arm2a: returns 0' "rc=$rc"
grep -q 'task.grade.requested' <<<"$EMITS" \
  && ok_ 'arm2b: emits task.grade.requested' || bad_ 'arm2b: emits task.grade.requested' "$EMITS"
grep -q 'iteration 3' <<<"$EMITS" \
  && ok_ 'arm2c: carries the iteration' || bad_ 'arm2c: carries the iteration' "$EMITS"
[[ $(grep -c . <<<"$EMITS") == 1 ]] \
  && ok_ 'arm2d: exactly one row — a request, not a spawn' || bad_ 'arm2d: one row' "$EMITS"

# No ident is a no-op, not an error, and writes nothing.
EMITS=""; _grader_spawn_request "" 42 main2 1; rc=$?
[[ $rc == 0 && -z "$EMITS" ]] && ok_ 'arm3a: empty ident is a silent no-op' \
  || bad_ 'arm3a: empty ident is a silent no-op' "rc=$rc emits=$EMITS"

# THE FATALITY ARM: with no ledger_emit in scope at all it must still return 0,
# because the delivery is already recorded by the time this runs.
( unset -f ledger_emit
  _grader_spawn_request DIVE-1 42 main2 1 ) >/dev/null 2>&1
[[ $? == 0 ]] && ok_ 'arm3b: no ledger_emit in scope still returns 0' \
  || bad_ 'arm3b: no ledger_emit in scope still returns 0' 'returned non-zero — would fail a recorded delivery'

# ── checkpoint ───────────────────────────────────────────────────────────────
EMITS=""; _grader_checkpoint DIVE-1 mutant-3 pass abc123
grep -q 'task.grade.checkpoint' <<<"$EMITS" && grep -q 'arm=mutant-3' <<<"$EMITS" \
  && grep -q 'verdict=pass' <<<"$EMITS" \
  && ok_ 'arm4a: checkpoint records arm+verdict+sha' || bad_ 'arm4a: checkpoint' "$EMITS"
EMITS=""; _grader_checkpoint DIVE-1 "" pass abc; rc=$?
[[ $rc == 0 && -z "$EMITS" ]] && ok_ 'arm4b: nameless arm is a no-op' || bad_ 'arm4b' "rc=$rc $EMITS"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
