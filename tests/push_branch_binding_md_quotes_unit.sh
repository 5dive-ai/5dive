#!/usr/bin/env bash
# DIVE-3081 — a markdown-quoted value cannot satisfy a machine-read binding.
#
# THE DEFECT. The `Branch: <name>` line in a task body is simultaneously human
# prose (it renders as markdown on the dashboard) and a machine binding (it is the
# value DIVE-1462's cleared-gate check binds a push to). Both readers parsed it
# with `\S+`, which keeps a markdown wrapper. A maker note opening
#
#     Branch: `dive-2813-ui-once-cleanup-and-race` — head `fd81f7b`, PR #521
#
# therefore bound the gate to a string no git ref can equal. The gate was answered
# and correct; the push refused with the ANTI-SUBSTITUTION error, whose two quoted
# names differ only by two invisible characters — so it reads as "the binding is
# stale, re-file the gate", spending a second human tap for zero semantic change.
#
# WHAT THIS FILE GRADES, and why all three arms are needed. The refusal compares
# two INDEPENDENTLY-PARSED values: `_push_branch_from_body` (cmd_push.sh — the
# value push derives to act on) against `broker_task_target` (lib/broker.sh — the
# authoritative bound value). Fixing one parser and not the other does not fix the
# bug, it produces a DIFFERENT unsatisfiable binding, which is why arm A and arm B
# are separate arms over separate functions and arm C grades them agreeing
# end-to-end through the real `broker_bind_target`.
#
# MUTATION EVIDENCE — four mutants, one per part of the fix, MEASURED on this file
# (a green suite proves nothing about whether it can go red). Pristine tree:
# PASS=17 FAIL=0. Each mutant reproduces the DEFECT — an unsatisfiable binding, or
# a refusal that misattributes one — not merely a changed string:
#
#   m1  drop the strip in _push_branch_from_body   -> 5 red: A(x4) + C1
#   m2  drop the strip in broker_task_target       -> 7 red: B(x2) + C1 + C2 + D(x3)
#   m3  broker_strip_md_quotes -> pass-through     -> 11 red: A + B + C + D
#   m4  blank the look-alike `hint`                -> 2 red: D's NOTE arms
#
# Two results here are load-bearing and were NOT what I predicted before running:
#   * m1 kills only C1, never C2. C2 hands the binder a bare ref and so cannot see
#     a broken cmd_push parser at all. C1 exists because of that measurement — on
#     the first draft of this file (C2 alone) a one-sided fix in cmd_push.sh left
#     the whole end-to-end section GREEN, which is the very "fixed one of the two
#     readers" trap this bug is made of, reproduced inside its own regression test.
#   * m4 is a PARTIAL mutant: blanking `hint` leaves the later `hint+=` appending
#     the repair sentence, so D's third arm survives. Recorded as partial rather
#     than dressed up as a clean kill; the NOTE arms do go red, which is the claim.
#
# See community/wiki/a-markdown-quoted-value-cannot-satisfy-a-machine-read-binding.md
#
# Run: bash tests/push_branch_binding_md_quotes_unit.sh   (no root, no network.)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/push-md-quotes-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh \
         cmd_project.sh cmd_push.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; these arms expect non-zero exits

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
want()  { if eval "$2"; then ok_t "$1"; else bad_t "$1" "${3:-}"; fi; }

tasks_db_init
mk() { # mk <body> -> task id, body set verbatim (the HAND-EDITED path, which is
       # how the real one got in: `task set-branch` and `task add --branch` both
       # already validate, so they cannot produce these bodies.)
  local id; id=$( (cmd_task_add --assignee=alice -- "binding fixture") 2>/dev/null | jq -r '.data.id' )
  db "UPDATE tasks SET body=$(sqlq "$1") WHERE id=${id};"
  printf '%s' "$id"
}

BR=dive-2813-ui-once-cleanup-and-race
PROSE=$'Branch: `'"$BR"$'` — head `fd81f7b`, PR #521, all 24 check-runs green.\n'

echo "== A. cmd_push.sh's parser (_push_branch_from_body)"
want "backticked prose line yields the BARE ref" \
     "[[ \"\$(_push_branch_from_body \"\$PROSE\")\" == \"\$BR\" ]]" \
     "got: $(_push_branch_from_body "$PROSE")"
want "double-quoted value yields the bare ref" \
     "[[ \"\$(_push_branch_from_body 'Branch: \"feat/x\"')\" == 'feat/x' ]]"
want "single-quoted value yields the bare ref" \
     "[[ \"\$(_push_branch_from_body \"Branch: 'feat/x'\")\" == 'feat/x' ]]"
want "angle-bracketed value yields the bare ref" \
     "[[ \"\$(_push_branch_from_body 'Branch: <feat/x>')\" == 'feat/x' ]]"
# Regression fence: the pre-existing contract must not move.
want "a BARE value is untouched" \
     "[[ \"\$(_push_branch_from_body 'Branch: feat/x')\" == 'feat/x' ]]"
want "case + leading/trailing space still tolerated" \
     "[[ \"\$(_push_branch_from_body '  branch:   feat/x  ')\" == 'feat/x' ]]"
want "no Branch: line is still EMPTY (not a spuriously-stripped value)" \
     "[[ -z \"\$(_push_branch_from_body 'no binding here')\" ]]"
# An UNPAIRED wrapper is malformed, and half-repairing it would bind a push to a
# value nobody wrote. Refusing beats guessing, so it must survive verbatim.
want "an UNPAIRED leading backtick is NOT half-stripped" \
     "[[ \"\$(_push_branch_from_body 'Branch: \`feat/x')\" == '\`feat/x' ]]"

echo
echo "== B. the broker's authoritative parser (broker_task_target)"
idp=$(mk "$PROSE")
want "broker_task_target strips the same wrapper on the same body" \
     "[[ \"\$(broker_task_target push \$idp)\" == \"\$BR\" ]]" \
     "got: $(broker_task_target push "$idp")"
idd=$(mk $'Deploy: `app@feat/x`\n')
want "the strip is surface-generic (deploy's own key too)" \
     "[[ \"\$(broker_task_target deploy \$idd)\" == 'app@feat/x' ]]"

echo
echo "== C. THE BUG, end to end: a cleared gate's binding is SATISFIABLE"
# C1 reproduces cmd_push's ACTUAL sequence (cmd_push.sh: derive the branch from
# the body with _push_branch_from_body, then _push_bind_branch it), so it is the
# arm that goes red on a strip applied to EITHER parser alone. C2 hands the bare
# ref straight to the binder, isolating the broker side. Measured: without C1, a
# one-sided fix in cmd_push.sh leaves this whole section green (see m1 above) —
# which is the same "fixed one of two readers" trap the bug itself is made of.
derived=$(_push_branch_from_body "$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${idp};")")
out1=$( (broker_bind_target push "$idp" DIVE-3081 "$derived") 2>&1 ); rc1=$?
want "C1 the real push path (parse body -> bind) is ACCEPTED (rc=0)" \
     "[[ $rc1 -eq 0 ]]" "derived='$derived' rc=$rc1: $out1"
out=$( (broker_bind_target push "$idp" DIVE-3081 "$BR") 2>&1 ); rc=$?
want "C2 pushing the real branch named in a backticked body is ACCEPTED (rc=0)" \
     "[[ $rc -eq 0 ]]" "rc=$rc: $out"
# The guard must still guard: DIVE-1462 is a security control, not a formatter.
out2=$( (broker_bind_target push "$idp" DIVE-3081 some-other-branch) 2>&1 ); rc2=$?
want "a genuinely DIFFERENT branch is still refused (rc!=0)" "[[ $rc2 -ne 0 ]]" "$out2"

echo
echo "== D. the refusal names a look-alike difference instead of implying staleness"
# Force the one-sided case the fix is meant to make impossible, so the hint is
# graded on its own: parse the body, then hand bind the WRAPPED value directly.
wrapped='`'"$BR"'`'
outh=$( (broker_bind_target push "$idp" DIVE-3081 "$wrapped") 2>&1 )
want "look-alike values get the punctuation NOTE" \
     "[[ \"\$outh\" == *'differ only in punctuation/whitespace'* ]]" "$outh"
want "...and say re-filing the gate will NOT help" \
     "[[ \"\$outh\" == *'binding is NOT stale'* ]]" "$outh"
want "...and name the verb that owns the line" \
     "[[ \"\$outh\" == *'5dive task set-branch'* ]]" "$outh"
# Absence-assertion, graded so it cannot pass on empty output (the arm above
# proves outh is non-empty): a real mismatch must NOT be excused as punctuation.
want "a genuinely different branch does NOT get the NOTE" \
     "[[ -n \"\$out2\" && \"\$out2\" != *'differ only in punctuation'* ]]" "$out2"

echo
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
