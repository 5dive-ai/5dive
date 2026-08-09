#!/usr/bin/env bash
# DIVE-2832: a verifier who graded by READING had no way to record a PASS on an OPEN row.
#
# Every writer of tasks.result was either the MAKER's verb (task deliver), a REJECTION,
# or machine output from `task verify`. `--no-done` looked like the answer and was not:
# it demanded a runnable --cmd, so the only way in was to contrive one — manufacturing a
# green to satisfy a gate, which is the anti-pattern the row exists to name.
#
# The negative arms carry most of the weight. --result must NOT be able to close (a prose
# PASS asserts the work is good, never that it MERGED, and this verb's close does not run
# the DIVE-1830 gate — DIVE-2938), and the recorded text must not be mistakable for a
# machine verdict, or the recording path is bought by destroying the property that made
# the machine path worth trusting.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "${TMP:-}" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
CLI="$PWD/5dive"
[[ -x "$CLI" ]] || { echo "SKIP - no built bundle (run ./build.sh)"; exit 0; }
TMP=$(mktemp -d); export FIVE_TASKS_DB="$TMP/tasks.db" HOME="$TMP"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
mk() { "$CLI" task add "$1" --assignee=main 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | head -1; }
res() { "$CLI" task show "$1" 2>/dev/null | sed -n '/result =/,$p'; }
st()  { "$CLI" task show "$1" 2>/dev/null | grep -m1 'status' | tr -d ' '; }

A=$(mk "prose A")
"$CLI" task verify "$A" --no-done --result="graded by reading the diff; no runnable test exists" >/dev/null 2>&1
res "$A" | grep -q "graded by reading the diff" \
  && ok_t "A: a verifier's PROSE lands in an OPEN row's result (requirement 1)" \
  || bad_t "A: a verifier's PROSE lands in an OPEN row's result (requirement 1)"
[[ "$(st "$A")" == "status=todo" ]] \
  && ok_t "A: status stays unflipped — recorded, not closed" \
  || bad_t "A: status stays unflipped" "got $(st "$A")"
res "$A" | grep -q "NO command was run" \
  && ok_t "A: the record says NO COMMAND RAN — not mistakable for a machine verdict" \
  || bad_t "A: the record says NO COMMAND RAN" "an unexecuted grade renders like an exit-0 one"

B=$(mk "prose B")
"$CLI" task verify "$B" --result="should be refused" >/dev/null 2>&1
[[ "$(st "$B")" == "status=todo" ]] \
  && ok_t "B NEGATIVE: --result without --no-done cannot close the row" \
  || bad_t "B NEGATIVE: --result without --no-done cannot close" "got $(st "$B")"
res "$B" | grep -q "should be refused" \
  && bad_t "B NEGATIVE: a refused call must record nothing" "wrote a result on a refusal" \
  || ok_t "B NEGATIVE: a refused call recorded nothing"

C=$(mk "prose C")
"$CLI" task verify "$C" --no-done --result="   " >/dev/null 2>&1
res "$C" | grep -qE "verify (PASS|FAIL)" \
  && bad_t "C NEGATIVE: an EMPTY --result must be refused" "stored a blank verdict" \
  || ok_t "C NEGATIVE: an empty --result is refused, not stored (DIVE-2483)"

D=$(mk "prose D")
out=$("$CLI" task verify "$D" --no-done 2>&1)
grep -q "task has no stored verify_command" <<<"$out" \
  && ok_t "D: no cmd and no prose still refuses (the old behaviour is intact)" \
  || bad_t "D: no cmd and no prose still refuses"
grep -qi "graded by READING" <<<"$out" \
  && ok_t "D: and that refusal now NAMES --result as the exit" \
  || bad_t "D: the refusal names --result as the exit" "a refusal that hides its own exit is what this row is about"

E=$(mk "prose E")
"$CLI" task verify "$E" --no-done --cmd=true --result="both given" >/dev/null 2>&1
r=$(res "$E")
{ grep -q "both given" <<<"$r" && grep -q "exit 0" <<<"$r"; } \
  && ok_t "E: --cmd AND --result keeps both the evidence and the grader's words" \
  || bad_t "E: --cmd AND --result keeps both"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
