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
# DIVE-3059 instance 1, and it is this file's own defect: the SKIP below used to
# exit 0, so a tree that had not run ./build.sh reported this harness as GREEN. That
# is what let main stay red for six commits while every local check said fine. A
# precondition this harness NEEDS is a FAILURE, not a skip — the escape is explicit
# and local-only, matching ACP_ALLOW_SKIP in tests/acp_stdio_unit.sh.
if [[ ! -x "$CLI" ]]; then
  if [[ "${BUNDLE_ALLOW_SKIP:-}" == "1" ]]; then
    echo "SKIP - no built bundle at $CLI (BUNDLE_ALLOW_SKIP=1); NOTHING WAS GRADED"; exit 0
  fi
  echo "FAIL - no built bundle at $CLI — run ./build.sh. This harness grades the CLI"
  echo "       end-to-end and cannot run without one; refusing to exit 0 and be read as"
  echo "       coverage. Set BUNDLE_ALLOW_SKIP=1 to skip deliberately (local only)."
  echo "0 passed, 1 failed"; exit 1
fi

# DIVE-3059: TASKS_DB, not FIVE_TASKS_DB — the CLI never read the latter, so this
# harness wrote its fixtures to the real board on a stateful host and failed 0/N on
# a fresh runner. See the sibling harness for the full note.
TMP=$(mktemp -d); export TASKS_DB="$TMP/tasks.db" TASKS_DIR="$TMP" STATE_DIR="$TMP/state" HOME="$TMP"

# The isolated store must exist before the bundle is driven, and `5dive task init`
# is require_root by design (src/cmd_task.sh) because it writes /var/lib — so a
# non-root CI runner can NEVER create one that way, and every `task add` refuses
# with "tasks store not initialised". That is the whole CI failure. The root check
# is on the COMMAND, not the library, so init IN-PROCESS the way every other
# harness does, then hand the bundle the path and keep grading the CLI end-to-end
# as a black box. DIVE-3059.
( for _f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
            lib/state.sh lib/tasks_db.sh; do . "${ROOT:-$PWD}/src/$_f"; done
  set +e; mkdir -p "$(dirname "$TASKS_DB")"; tasks_db_init; _tasks_db_migrate ) >/dev/null 2>&1
[[ -s "$TASKS_DB" ]] || { echo "FAIL - could not create the isolated tasks store at $TASKS_DB"; echo "0 passed, 1 failed"; exit 1; }

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

# DIVE-3018. This arm used to assert ONLY that the row stayed todo, and that graded
# NOTHING: replace the guard it names with `if false; then` and the suite still went
# 9/0, because the now-open prose+close path dies under `set -euo pipefail` with the
# generic "exited 1 without reporting a reason" BEFORE it can flip the row. "Did it
# fail?" and "is the state unchanged?" are the SAME predicate in a system where
# failing early is how nothing happens — any abort satisfies both, including a crash,
# a typo'd ident or an unrelated guard firing first. So the status check stays (it is
# the property we care about) but it can no longer carry the arm alone: we assert the
# refusal's OWN output, which only this guard can produce.
# See community/wiki/a-negative-arm-that-greps-for-failure-passes-on-any-failure.md
B=$(mk "prose B")
b_out=$("$CLI" task verify "$B" --result="should be refused" 2>&1); b_rc=$?
[[ "$b_rc" -eq 2 ]] \
  && ok_t "B NEGATIVE: the refusal exits E_USAGE(2), not a generic abort" \
  || bad_t "B NEGATIVE: the refusal exits E_USAGE(2)" "got rc=$b_rc — any nonzero would satisfy a state-only assertion"
grep -q "requires --no-done" <<<"$b_out" \
  && ok_t "B NEGATIVE: and says 'requires --no-done' — a token only THIS guard emits" \
  || bad_t "B NEGATIVE: the refusal names itself" "got: $(head -c 120 <<<"$b_out")"
[[ "$(st "$B")" == "status=todo" ]] \
  && ok_t "B NEGATIVE: --result without --no-done cannot close the row" \
  || bad_t "B NEGATIVE: --result without --no-done cannot close" "got $(st "$B")"
res "$B" | grep -q "should be refused" \
  && bad_t "B NEGATIVE: a refused call must record nothing" "wrote a result on a refusal" \
  || ok_t "B NEGATIVE: a refused call recorded nothing"

# DIVE-3018: C carried the same defect as B in a different costume — an ABSENCE
# assertion ("no verdict was stored") is satisfied by every abort too. Same cure.
C=$(mk "prose C")
c_out=$("$CLI" task verify "$C" --no-done --result="   " 2>&1); c_rc=$?
[[ "$c_rc" -eq 3 ]] \
  && ok_t "C NEGATIVE: the empty-verdict refusal exits E_VALIDATION(3)" \
  || bad_t "C NEGATIVE: the empty-verdict refusal exits E_VALIDATION(3)" "got rc=$c_rc"
grep -q "EMPTY value" <<<"$c_out" \
  && ok_t "C NEGATIVE: and names the empty value — not a generic abort" \
  || bad_t "C NEGATIVE: the refusal names the empty value" "got: $(head -c 120 <<<"$c_out")"
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

# ── DIVE-3018 item 2: --result-file= on the verbs that already take --result= ──
# `task done` got this in DIVE-2627; `task deliver` and `task verify` did not. The
# argv form only fails once the text is long enough to hit a shell-quoting mistake,
# so it fails invisibly in exactly the cases nobody tests with — and what lands is a
# permanently wrong record, not an error. These arms assert the FILE form on both
# verbs plus the two refusals that make it safe to reach for.
F=$(mk "prose F")
printf 'graded by reading the diff.\n\nSecond paragraph with a `backtick`, an apostrophe'"'"'s worth of trouble, and $NOT_A_VAR.\n' > "$TMP/verdict.txt"
"$CLI" task verify "$F" --no-done --result-file="$TMP/verdict.txt" >/dev/null 2>&1
f_rc=$?
[[ "$f_rc" -eq 0 ]] \
  && ok_t "F: task verify --result-file records a prose verdict on an OPEN row" \
  || bad_t "F: task verify --result-file exits 0" "got rc=$f_rc"
res "$F" | grep -q 'a `backtick`' \
  && ok_t "F: backticks/apostrophes/\$vars survive the FILE path verbatim" \
  || bad_t "F: the file text survives verbatim" "the quoting trap this flag exists to remove"
[[ "$(st "$F")" == "status=todo" ]] \
  && ok_t "F: --result-file is a RECORDING path too — the row stays open" \
  || bad_t "F: --result-file must not close the row" "got $(st "$F")"

# NEGATIVE, and asserted on the refusal's own words rather than on absence.
G=$(mk "prose G")
g_out=$("$CLI" task verify "$G" --no-done --result=inline --result-file="$TMP/verdict.txt" 2>&1); g_rc=$?
[[ "$g_rc" -eq 2 ]] && grep -q "conflicts with" <<<"$g_out" \
  && ok_t "G NEGATIVE: --result and --result-file together are REFUSED (E_USAGE + names the conflict)" \
  || bad_t "G NEGATIVE: inline+file must be refused" "rc=$g_rc out=$(head -c 120 <<<"$g_out")"
: > "$TMP/empty.txt"
h_out=$("$CLI" task verify "$G" --no-done --result-file="$TMP/empty.txt" 2>&1); h_rc=$?
[[ "$h_rc" -eq 3 ]] && grep -q "is empty" <<<"$h_out" \
  && ok_t "G NEGATIVE: an EMPTY file is refused, not recorded as blank (E_VALIDATION)" \
  || bad_t "G NEGATIVE: an empty file must be refused" "rc=$h_rc out=$(head -c 120 <<<"$h_out")"
i_out=$("$CLI" task verify "$G" --no-done --result-file="$TMP/nope.txt" 2>&1); i_rc=$?
[[ "$i_rc" -eq 2 ]] && grep -q "no such file" <<<"$i_out" \
  && ok_t "G NEGATIVE: a missing file is refused by NAME (E_USAGE)" \
  || bad_t "G NEGATIVE: a missing file must be refused" "rc=$i_rc out=$(head -c 120 <<<"$i_out")"

# The other verb the ticket names. deliver needs a --pr= URL to run at all.
J=$(mk "prose J")
"$CLI" task deliver "$J" --pr=https://github.com/5dive-ai/5dive/pull/1 --result-file="$TMP/verdict.txt" >/dev/null 2>&1
j_rc=$?
[[ "$j_rc" -eq 0 ]] \
  && ok_t "J: task deliver --result-file works too (the second verb the ticket names)" \
  || bad_t "J: task deliver --result-file exits 0" "got rc=$j_rc"
res "$J" | grep -q 'a `backtick`' \
  && ok_t "J: and deliver's file text survives verbatim" \
  || bad_t "J: deliver's file text survives verbatim"
k_out=$("$CLI" task deliver "$J" --pr=https://github.com/5dive-ai/5dive/pull/1 --result=x --result-file="$TMP/verdict.txt" 2>&1); k_rc=$?
[[ "$k_rc" -eq 2 ]] && grep -q "conflicts with" <<<"$k_out" \
  && ok_t "J NEGATIVE: deliver refuses inline+file too — one answer per question" \
  || bad_t "J NEGATIVE: deliver must refuse inline+file" "rc=$k_rc out=$(head -c 120 <<<"$k_out")"

E=$(mk "prose E")
"$CLI" task verify "$E" --no-done --cmd=true --result="both given" >/dev/null 2>&1
r=$(res "$E")
{ grep -q "both given" <<<"$r" && grep -q "exit 0" <<<"$r"; } \
  && ok_t "E: --cmd AND --result keeps both the evidence and the grader's words" \
  || bad_t "E: --cmd AND --result keeps both"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
