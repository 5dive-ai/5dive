#!/usr/bin/env bash
# DIVE-4825 — NO MODEL IN THE MECHANICAL GRADE.
#
# A grade of a PR delivery was ~78 model turns executing a procedure that is
# deterministic given the delivered sha (15.7M cache-read tokens for ONE grade,
# 98 % of it cache reads re-sent per shell call). The procedure is now COMPUTED
# and the model is kept for what a script cannot do. This harness grades the
# computed pass at the five places the claim actually lives:
#
#   PART 1  THE CONTROL ARM   the same harness with the changed SOURCE reverted
#                             to the merge-base must go RED, its failing set is
#                             named, and a control that stays GREEN is a FLAG —
#                             a harness that does not test the change.
#   PART 2  THE CLAIM         the maker's `failing={…}` is compared, and a
#                             MISMATCH flags. Negative control: the matching
#                             claim must NOT flag.
#   PART 3  MANY MUTANTS      tests/mutants/<ident>.sh gives one arm per mutant;
#                             each is killed BY NAME, and a survivor prints
#                             SURVIVED — never MATCH.
#   PART 4  THE ROUTE         green closes with NO grader session · flagged does
#                             NOT refuse: the table lands on the ROW (which is
#                             where a grader's goal is built from) with the
#                             re-derive-the-flagged-line-only rule, and a grader
#                             IS routed · the green-table READ sample is a knob.
#   PART 5  THE DEFAULT FLIP  the check is DERIVED from the maker's CHECKED
#                             line, and is refused for a pinned grader, for an
#                             ambiguous CHECKED, and with the knob off.
#   PART 7  THE SEAT        the bounded grading packet CARRIES the table (the
#                             goal says to use only the packet, so a table in the
#                             row body alone never reaches the woken seat), and
#                             the grader's method clause forbids rebuilding the
#                             control and mutant trees. Both with negative
#                             controls on a row that has no table.
#   PART 6  MUTATION          the load-bearing predicates are cut out of the
#                             SHIPPING functions and the arms above must go RED.
#                             Each cut is checked to have LANDED first.
#
# WHY REAL REPOSITORIES. Every claim here is "…from a clean checkout at the
# delivered sha", and a stubbed git would prove only that something named git
# was called. The scratch repos are four commits in a temp dir and cost
# milliseconds; `refs/remotes/origin/main` is set by hand because the merge-base
# is the whole input to the control arm.
#
# Isolation: src/ sourced directly, STATE_DIR on a throwaway dir, BOX_CONFIG
# inside it, every git operation inside $TMP. No root, no network.
# Run: bash tests/task_computed_grade_table_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/computed-grade.XXXXXX)"
REPO_ROOT="$PWD"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/verify_policy.sh lib/tasks_db.sh \
         lib/actor.sh cmd_task.sh cmd_push.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
BOX_CONFIG="$TMP/box.json"; JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e
printf '{"verify":"always"}\n' > "$BOX_CONFIG"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

PASS=0; FAILN=0
ok_t()  { PASS=$((PASS+1));  printf 'ok   - %s\n' "$1"; }
bad_t() { FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init >/dev/null 2>&1
_task_default_verifier() { printf 'grader'; }
_task_require_lane()      { return 0; }
_task_deliver_reach_probe() { return 0; }
SPAWNS="$TMP/spawns"; : > "$SPAWNS"
_grader_spawn_request() { printf '%s\n' "${1:-}" >> "$SPAWNS"; return 0; }
spawn_count() { wc -l < "$SPAWNS" | tr -d ' '; }

add_row() { local t="$1"; shift
  cmd_task_add "$t $RANDOM" --assignee=dev --from=main --priority=high "$@" 2>/dev/null \
    | jq -r '.data.ident // empty' 2>/dev/null; }
col() { db "SELECT COALESCE($2,'') FROM tasks WHERE ident=$(sqlq "$1");"; }

# ── the fixture: base has plain source and no harness; HEAD adds the guard AND
# the harness that tests it, which is the ordinary shape of a delivered diff.
HARNESS_BODY='#!/usr/bin/env bash
f=0
if grep -q GUARDTOKEN src/foo.sh; then echo "ok   - A1 the guard is present"; else echo "FAIL - A1 the guard is present"; f=1; fi
if grep -q SECOND src/foo.sh;     then echo "ok   - A2 the second guard is present"; else echo "FAIL - A2 the second guard is present"; f=1; fi
echo "ok   - A3 unconditional"
exit $f
'
mkrepo() { # <name> [harness-body] -> path, with refs/remotes/origin/main at base
  local d="$TMP/$1" hb="${2:-$HARNESS_BODY}"
  mkdir -p "$d/src" "$d/tests"
  git -C "$d" init -q 2>/dev/null
  printf 'echo hello\n' > "$d/src/foo.sh"
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm base
  git -C "$d" update-ref refs/remotes/origin/main "$(git -C "$d" rev-parse HEAD)"
  printf 'echo hello\nGUARDTOKEN\nSECOND\n' > "$d/src/foo.sh"
  printf '%s' "$hb" > "$d/tests/h.sh"
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm guard
  printf '%s' "$d"
}
wt_count() { git -C "$1" worktree list 2>/dev/null | wc -l | tr -d ' '; }
CHK='bash tests/h.sh'
MUT='sed -i s/GUARDTOKEN/xxx/ src/foo.sh'

echo "── PART 1 — the control arm: the harness must go RED on the old source ───"

R1=$(mkrepo repo1); B1=$(wt_count "$R1")
cd "$R1" || exit 1
_task_grade_table X-1 "$CHK" "$MUT" >/dev/null 2>&1; rc=$?
T="$_TASK_GRADE_TABLE"
(( rc == 0 )) && ok_t "a healthy diff computes a PASS table" \
  || bad_t "a healthy diff computes a PASS table" "rc=$rc table='$T'"
grep -q 'suite ' <<<"$T" && grep -q '3 pass 0 fail  rc=0' <<<"$T" \
  && ok_t "the suite line carries the arm counts at the delivered sha, not just an exit status" \
  || bad_t "the suite line carries the arm counts at the delivered sha" "table='$T'"
grep -q 'control src/foo.sh' <<<"$T" \
  && ok_t "the control line names the SOURCE it reverted (tests/ is deliberately not reverted)" \
  || bad_t "the control line names the SOURCE it reverted" "table='$T'"
grep -q '1 pass 2 fail' <<<"$T" && grep -q 'failing={A1,A2}' <<<"$T" \
  && ok_t "the control ran the NEW harness against the OLD source and named the failing arms" \
  || bad_t "the control ran the NEW harness against the OLD source and named the failing arms" "table='$T'"
grep -q 'VERDICT computed: PASS — 0 flags' <<<"$T" \
  && ok_t "the verdict is COMPUTED and printed in the table" \
  || bad_t "the verdict is COMPUTED and printed in the table" "table='$T'"
cd "$REPO_ROOT" || exit 1
[[ "$(wt_count "$R1")" == "$B1" ]] && ok_t "no worktree is leaked in the maker's repo" \
  || bad_t "no worktree is leaked in the maker's repo" "$B1 -> $(wt_count "$R1")"

# THE NEGATIVE CONTROL FOR THE CONTROL ARM. A harness that passes on the old
# source too does not test the change — a green exit status cannot see that, and
# it is the defect the whole arm exists to find. It must FLAG, never pass.
R2=$(mkrepo repo2 '#!/usr/bin/env bash
if grep -q hello src/foo.sh; then echo "ok   - A1 hello (true at BASE too)"; else echo "FAIL - A1 hello"; exit 1; fi
exit 0
')
cd "$R2" || exit 1
_task_grade_table X-2 "$CHK" "sed -i s/hello/xxx/ src/foo.sh" >/dev/null 2>&1; rc=$?
T2="$_TASK_GRADE_TABLE"
(( rc != 0 )) && grep -q '^CONTROL-GREEN' <<<"$_TASK_GRADE_FLAGS" \
  && ok_t "a harness that stays GREEN on the old source is FLAGGED, not passed" \
  || bad_t "a harness that stays GREEN on the old source is FLAGGED, not passed" "rc=$rc flags='$_TASK_GRADE_FLAGS'"
grep -q 'GREEN: the harness does not test this change' <<<"$T2" \
  && ok_t "…and the table SAYS so in the words a reader needs" \
  || bad_t "…and the table SAYS so in the words a reader needs" "table='$T2'"
cd "$REPO_ROOT" || exit 1

# A diff that touches no source at all: the control has nothing to revert, and
# that must be stated, never silently counted as a healthy red.
R3="$TMP/repo3"; mkdir -p "$R3/src" "$R3/tests"
git -C "$R3" init -q 2>/dev/null
printf 'echo hello\nGUARDTOKEN\nSECOND\n' > "$R3/src/foo.sh"
git -C "$R3" add -A >/dev/null; git -C "$R3" commit -qm base
git -C "$R3" update-ref refs/remotes/origin/main "$(git -C "$R3" rev-parse HEAD)"
printf '%s' "$HARNESS_BODY" > "$R3/tests/h.sh"
git -C "$R3" add -A >/dev/null; git -C "$R3" commit -qm "tests only"
cd "$R3" || exit 1
_task_grade_table X-3 "$CHK" "$MUT" >/dev/null 2>&1
grep -q 'control NOT RUN — the diff touches no non-test file' <<<"$_TASK_GRADE_TABLE" \
  && ok_t "a tests-only diff SAYS the control had nothing to revert" \
  || bad_t "a tests-only diff SAYS the control had nothing to revert" "table='$_TASK_GRADE_TABLE'"
cd "$REPO_ROOT" || exit 1

# A DIFF THAT ADDS A FILE. `git checkout <base> -- <paths>` fails ATOMICALLY on a
# path absent at the base, so one added file (every delivery adds a changelog
# fragment) silently reverts NOTHING and the control grades the delivered tree
# twice. Measured on DIVE-4814's real delivery, 2026-09-22.
R4=$(mkrepo repo4)
printf 'brand new\n' > "$R4/src/added.sh"
git -C "$R4" add -A >/dev/null; git -C "$R4" commit -qm "add a file too"
cd "$R4" || exit 1
_task_grade_table X-ADD "$CHK" "$MUT" >/dev/null 2>&1; rc=$?
TA="$_TASK_GRADE_TABLE"
grep -q 'control DID NOT APPLY' <<<"$TA" \
  && bad_t "a diff that ADDS a file still reverts the file it MODIFIED" "table='$TA'" \
  || ok_t "a diff that ADDS a file still reverts the file it MODIFIED (the added path is removed, not checked out)"
grep -q 'failing={A1,A2}' <<<"$TA" && (( rc == 0 )) \
  && ok_t "…and the control still goes red with the same failing set" \
  || bad_t "…and the control still goes red with the same failing set" "rc=$rc table='$TA'"
cd "$REPO_ROOT" || exit 1

# A row that names NO mutant but whose control went RED is RECORDED, not flagged:
# re-booking a session for every such row is the burn this work removes.
cd "$R1" || exit 1
_task_grade_table X-NOMUT "$CHK" "" >/dev/null 2>&1; rc=$?
(( rc == 0 )) && grep -q 'the control above is what shows' <<<"$_TASK_GRADE_TABLE" \
  && ok_t "no mutant + a HEALTHY control is recorded, not flagged" \
  || bad_t "no mutant + a HEALTHY control is recorded, not flagged" "rc=$rc table='$_TASK_GRADE_TABLE'"
cd "$REPO_ROOT" || exit 1
# …and the negative control: no mutant AND no red control IS flagged.
cd "$R2" || exit 1
_task_grade_table X-NOEV "$CHK" "" >/dev/null 2>&1; rc=$?
(( rc != 0 )) && grep -q '^NO-EVIDENCE-CAN-FAIL' <<<"$_TASK_GRADE_FLAGS" \
  && ok_t "…but no mutant AND no red control IS flagged (nothing proves the check can fail)" \
  || bad_t "…but no mutant AND no red control IS flagged" "rc=$rc flags='$_TASK_GRADE_FLAGS'"
cd "$REPO_ROOT" || exit 1

echo "── PART 2 — the maker's claim is compared, both ways ─────────────────────"

cd "$R1" || exit 1
_task_grade_table X-4 "$CHK" "$MUT" "A1,A2" >/dev/null 2>&1; rc=$?
(( rc == 0 )) && grep -q 'claimed={A1,A2} MATCH' <<<"$_TASK_GRADE_TABLE" \
  && ok_t "a claim that matches the computed failing set prints MATCH and does not flag" \
  || bad_t "a claim that matches prints MATCH and does not flag" "rc=$rc table='$_TASK_GRADE_TABLE'"
_task_grade_table X-5 "$CHK" "$MUT" "A1" >/dev/null 2>&1; rc=$?
(( rc != 0 )) && grep -q 'MISMATCH' <<<"$_TASK_GRADE_TABLE" \
  && grep -q '^CONTROL-CLAIM-MISMATCH' <<<"$_TASK_GRADE_FLAGS" \
  && ok_t "a claim that does NOT match the computed set is FLAGGED" \
  || bad_t "a claim that does NOT match the computed set is FLAGGED" "rc=$rc table='$_TASK_GRADE_TABLE'"
cd "$REPO_ROOT" || exit 1
CLAIM=$(_task_grade_claimed_failing 'CHECKED: 14 pass 12 fail failing={A2,A4b,D1}')
[[ "$CLAIM" == "A2,A4b,D1" ]] && ok_t "the claim is read out of the maker's CHECKED line" \
  || bad_t "the claim is read out of the maker's CHECKED line" "got '$CLAIM'"
[[ -z "$(_task_grade_claimed_failing 'CHECKED: 17 arms, 17 pass')" ]] \
  && ok_t "…and a CHECKED line with no claim yields NO claim (absent is absent)" \
  || bad_t "…and a CHECKED line with no claim yields NO claim" "got '$(_task_grade_claimed_failing 'CHECKED: 17 arms, 17 pass')'"

echo "── PART 3 — many mutants, each killed BY NAME ────────────────────────────"

R5=$(mkrepo repo5)
mkdir -p "$R5/tests/mutants"
cat > "$R5/tests/mutants/X-6.sh" <<'MEOF'
m1() { sed -i s/GUARDTOKEN/xxx/ src/foo.sh; }
m2() { sed -i s/SECOND/yyy/ src/foo.sh; }
m3() { : ; }
MEOF
git -C "$R5" add -A >/dev/null; git -C "$R5" commit -qm mutants
cd "$R5" || exit 1
_task_grade_table X-6 "$CHK" "" >/dev/null 2>&1; rc=$?
T6="$_TASK_GRADE_TABLE"
grep -q 'mutant  m1  killed-by A1' <<<"$T6" && grep -q 'mutant  m2  killed-by A2' <<<"$T6" \
  && ok_t "every mutant in tests/mutants/<ident>.sh runs, and the table names the arm that killed it" \
  || bad_t "every mutant runs and names its killer" "table='$T6'"
grep -q 'mutant  m3  DID NOT APPLY' <<<"$T6" \
  && ok_t "a mutant that changes nothing prints DID NOT APPLY — never a silent MATCH" \
  || bad_t "a mutant that changes nothing prints DID NOT APPLY" "table='$T6'"
(( rc == 4 )) && ok_t "…and a mutant that was never applied is VACUITY, refused rather than read" \
  || bad_t "…and a mutant that was never applied is VACUITY" "rc=$rc (want 4)"
cd "$REPO_ROOT" || exit 1

R6=$(mkrepo repo6 '#!/usr/bin/env bash
echo "ok   - A1 the guard is present"
grep -q SECOND src/foo.sh || { echo "FAIL - A2 the second guard is present"; exit 1; }
echo "ok   - A2 the second guard is present"
exit 0
')
cd "$R6" || exit 1
_task_grade_table X-7 "$CHK" 'sed -i s/GUARDTOKEN/xxx/ src/foo.sh' >/dev/null 2>&1; rc=$?
grep -q 'SURVIVED' <<<"$_TASK_GRADE_TABLE" && (( rc == 4 )) \
  && ok_t "a mutant the check cannot kill prints SURVIVED and is refused as vacuous" \
  || bad_t "a mutant the check cannot kill prints SURVIVED" "rc=$rc table='$_TASK_GRADE_TABLE'"
grep -q 'MATCH' <<<"$_TASK_GRADE_TABLE" \
  && bad_t "a SURVIVED mutant never prints MATCH" "table='$_TASK_GRADE_TABLE'" \
  || ok_t "a SURVIVED mutant never prints MATCH (the criterion-1 negative control)"
cd "$REPO_ROOT" || exit 1

echo "── PART 4 — the route: green is free, flagged is a hand-off ──────────────"

EV() { printf 'CHANGED: src/foo.sh\nCHECKED: %s — %s\nDELIVERED-SHA: %s\nCI: green\nCRITERIA: the guard is present\n' "$1" "${3:-3 arms}" "$2"; }
PR=https://github.com/5dive-ai/5dive/pull/999

RG=$(mkrepo repoG); SHAG=$(git -C "$RG" rev-parse HEAD)
IDG=$(add_row "green table" --review=check --verify="$CHK" --mutant="$MUT")
: > "$SPAWNS"; export FIVEDIVE_GRADE_SAMPLE_N=0
( cd "$RG" && cmd_task_deliver "$IDG" --pr="$PR" --result="$(EV "$CHK" "$SHAG")" >/dev/null 2>&1 ); rc=$?
(( rc == 0 )) && ok_t "a GREEN computed table delivers" || bad_t "a GREEN computed table delivers" "exit $rc"
[[ "$(spawn_count)" == "0" && -z "$(col "$IDG" verifier)" ]] \
  && ok_t "…for ZERO grader tokens: no session booked and no grader attached" \
  || bad_t "…for ZERO grader tokens" "spawns=$(spawn_count) verifier='$(col "$IDG" verifier)'"
grep -q 'VERDICT computed: PASS' <<<"$(col "$IDG" result)" \
  && ok_t "…and the table is on the row, where the merge owner reads it" \
  || bad_t "…and the table is on the row" "result='$(col "$IDG" result)'"

# A FLAGGED TABLE IS A HAND-OFF, NOT A REFUSAL — the half that keeps the depth.
RF=$(mkrepo repoF '#!/usr/bin/env bash
if grep -q hello src/foo.sh; then echo "ok   - A1 hello (true at BASE too)"; else echo "FAIL - A1 hello"; exit 1; fi
exit 0
')
SHAF=$(git -C "$RF" rev-parse HEAD)
IDF=$(add_row "flagged table" --review=check --verify="$CHK" --mutant="sed -i s/hello/xxx/ src/foo.sh")
: > "$SPAWNS"
( cd "$RF" && cmd_task_deliver "$IDF" --pr="$PR" --result="$(EV "$CHK" "$SHAF")" >/dev/null 2>&1 ); rc=$?
(( rc == 0 )) && ok_t "a FLAGGED table does NOT refuse the delivery" \
  || bad_t "a FLAGGED table does NOT refuse the delivery" "exit $rc"
BODY="$(col "$IDF" body)"
grep -q 'COMPUTED GRADE (DIVE-4825) — FLAGGED' <<<"$BODY" \
  && ok_t "the table lands in the ROW BODY, which is where a grader's goal is built from" \
  || bad_t "the table lands in the ROW BODY" "body tail='${BODY: -400}'"
grep -q 'Re-derive the FLAGGED line ONLY' <<<"$BODY" \
  && ok_t "…carrying the rule that makes the hand-off cheap" \
  || bad_t "…carrying the rule that makes the hand-off cheap" "body tail='${BODY: -400}'"
[[ -n "$(col "$IDF" verifier)" ]] && ok_t "…and a grader IS routed (the depth is not dropped)" \
  || bad_t "…and a grader IS routed" "verifier empty"

# THE QUALITY KNOB: a share of GREEN tables still reaches a reader.
RS=$(mkrepo repoS); SHAS=$(git -C "$RS" rev-parse HEAD)
IDS=$(add_row "sampled green" --review=check --verify="$CHK" --mutant="$MUT")
: > "$SPAWNS"; export FIVEDIVE_GRADE_SAMPLE_N=1
( cd "$RS" && cmd_task_deliver "$IDS" --pr="$PR" --result="$(EV "$CHK" "$SHAS")" >/dev/null 2>&1 )
BODYS="$(col "$IDS" body)"
grep -q 'GREEN TABLE, DRAWN FOR A READ' <<<"$BODYS" && [[ -n "$(col "$IDS" verifier)" ]] \
  && ok_t "with the sample at 1-in-1 a GREEN table is still READ by a grader" \
  || bad_t "with the sample at 1-in-1 a GREEN table is still READ" "verifier='$(col "$IDS" verifier)' body tail='${BODYS: -300}'"
grep -q 'must NOT be re-run' <<<"$BODYS" \
  && ok_t "…and the read is explicitly NOT a re-run" \
  || bad_t "…and the read is explicitly NOT a re-run" "body tail='${BODYS: -300}'"
export FIVEDIVE_GRADE_SAMPLE_N=0
RS2=$(mkrepo repoS2); SHAS2=$(git -C "$RS2" rev-parse HEAD)
IDS2=$(add_row "unsampled green" --review=check --verify="$CHK" --mutant="$MUT")
( cd "$RS2" && cmd_task_deliver "$IDS2" --pr="$PR" --result="$(EV "$CHK" "$SHAS2")" >/dev/null 2>&1 )
[[ -z "$(col "$IDS2" verifier)" ]] && ok_t "…and with the sample at 0 the same green table costs nothing" \
  || bad_t "…and with the sample at 0 the same green table costs nothing" "verifier='$(col "$IDS2" verifier)'"

echo "── PART 5 — the default flip: the check is DERIVED from CHECKED ──────────"

RD=$(mkrepo repoD); SHAD=$(git -C "$RD" rev-parse HEAD)
DERIVED_RESULT=$(printf 'CHANGED: src/foo.sh — adds the guard\nCHECKED: bash tests/h.sh — 3 arms, 3 pass\nDELIVERED-SHA: %s\nCI: green\nCRITERIA: the guard is present\n' "$SHAD")
IDD=$(add_row "derived check")   # NO --review, NO --verify: the ordinary row
: > "$SPAWNS"
( cd "$RD" && cmd_task_deliver "$IDD" --pr="$PR" --result="$DERIVED_RESULT" >/dev/null 2>&1 ); rc=$?
[[ "$(col "$IDD" review_mode)" == "check" ]] && [[ "$(col "$IDD" verify_command)" == "bash tests/h.sh" ]] \
  && ok_t "an ordinary PR delivery is flipped to the computed pass, with the check read off CHECKED" \
  || bad_t "an ordinary PR delivery is flipped to the computed pass" "mode='$(col "$IDD" review_mode)' cmd='$(col "$IDD" verify_command)'"

# THE NEGATIVE CONTROLS FOR THE FLIP — each one must NOT derive.
RD2=$(mkrepo repoD2); SHAD2=$(git -C "$RD2" rev-parse HEAD)
IDD2=$(add_row "two harnesses named")
AMBIG=$(printf 'CHANGED: src/foo.sh\nCHECKED: bash tests/h.sh and bash tests/other.sh\nDELIVERED-SHA: %s\nCI: green\nCRITERIA: x\n' "$SHAD2")
( cd "$RD2" && cmd_task_deliver "$IDD2" --pr="$PR" --result="$AMBIG" >/dev/null 2>&1 )
# DIVE-4906 changed this arm's meaning: a named harness that is not AT the sha
# is dropped, not counted, so this CHECKED names ONE runnable harness. (Refusing
# every two-name CHECKED refused 4 of the 25 field deliveries DIVE-4828 read.)
[[ "$(col "$IDD2" review_mode)" == "check" && "$(col "$IDD2" verify_command)" == "bash tests/h.sh" ]] \
  && ok_t "a second harness that is not at the sha is dropped, and the one that is IS derived (DIVE-4906)" \
  || bad_t "a second harness not at the sha is dropped" "mode='$(col "$IDD2" review_mode)' cmd='$(col "$IDD2" verify_command)'"

# …and the cap: four harnesses that all exist and that the diff did not touch
# is a suite, not a check — the computed pass runs the check once per arm.
mkrepo_suite() { # <name> -> path; four harnesses at BASE, HEAD changes source only
  local d="$TMP/$1" h
  mkdir -p "$d/src" "$d/tests"; git -C "$d" init -q 2>/dev/null
  printf 'echo hello\n' > "$d/src/foo.sh"
  for h in a b c d; do printf '%s' "$HARNESS_BODY" > "$d/tests/$h.sh"; done
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm base
  git -C "$d" update-ref refs/remotes/origin/main "$(git -C "$d" rev-parse HEAD)"
  printf 'echo hello\nGUARDTOKEN\nSECOND\n' > "$d/src/foo.sh"
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm guard
  printf '%s' "$d"
}
SUITE4='bash tests/a.sh, bash tests/b.sh, bash tests/c.sh and bash tests/d.sh, all green'
RD8=$(mkrepo_suite repoD8); SHAD8=$(git -C "$RD8" rev-parse HEAD)
IDD8=$(add_row "four untouched harnesses named")
( cd "$RD8" && cmd_task_deliver "$IDD8" --pr="$PR" \
    --result="$(printf 'CHANGED: src/foo.sh\nCHECKED: %s\nDELIVERED-SHA: %s\nCI: green\nCRITERIA: x\n' "$SUITE4" "$SHAD8")" >/dev/null 2>&1 )
[[ "$(col "$IDD8" review_mode)" != "check" ]] \
  && ok_t "more harnesses than FIVEDIVE_DERIVE_MAX_HARNESSES (3) is a suite and is NOT derived" \
  || bad_t "more harnesses than the cap is NOT derived" "mode='$(col "$IDD8" review_mode)' cmd='$(col "$IDD8" verify_command)'"

RD3=$(mkrepo repoD3); SHAD3=$(git -C "$RD3" rev-parse HEAD)
IDD3=$(add_row "pinned grader" --review=quinn)
( cd "$RD3" && cmd_task_deliver "$IDD3" --pr="$PR" \
    --result="$(printf 'CHANGED: x\nCHECKED: bash tests/h.sh\nDELIVERED-SHA: %s\nCI: green\nCRITERIA: x\n' "$SHAD3")" >/dev/null 2>&1 )
[[ "$(col "$IDD3" review_mode)" == *quinn* ]] \
  && ok_t "a row that PINS a named grader is never downgraded to a computed table" \
  || bad_t "a row that PINS a named grader is never downgraded" "mode='$(col "$IDD3" review_mode)'"

RD4=$(mkrepo repoD4); SHAD4=$(git -C "$RD4" rev-parse HEAD)
IDD4=$(add_row "knob off")
export FIVEDIVE_DERIVE_GRADE_CHECK=0
( cd "$RD4" && cmd_task_deliver "$IDD4" --pr="$PR" \
    --result="$(printf 'CHANGED: x\nCHECKED: bash tests/h.sh\nDELIVERED-SHA: %s\nCI: green\nCRITERIA: x\n' "$SHAD4")" >/dev/null 2>&1 )
[[ "$(col "$IDD4" review_mode)" != "check" ]] \
  && ok_t "the flip is a KNOB: FIVEDIVE_DERIVE_GRADE_CHECK=0 turns it off in one place" \
  || bad_t "the flip is a KNOB" "mode='$(col "$IDD4" review_mode)'"
unset FIVEDIVE_DERIVE_GRADE_CHECK

RD5=$(mkrepo repoD5); SHAD5=$(git -C "$RD5" rev-parse HEAD)
IDD5=$(add_row "harness absent at sha")
( cd "$RD5" && cmd_task_deliver "$IDD5" --pr="$PR" \
    --result="$(printf 'CHANGED: x\nCHECKED: bash tests/not_pushed.sh\nDELIVERED-SHA: %s\nCI: green\nCRITERIA: x\n' "$SHAD5")" >/dev/null 2>&1 )
[[ "$(col "$IDD5" review_mode)" != "check" ]] \
  && ok_t "a harness that is not AT the delivered sha is not derived from" \
  || bad_t "a harness that is not AT the delivered sha is not derived from" "mode='$(col "$IDD5" review_mode)'"

# DIVE-4825 iteration 2 — THE HARNESS WE ARE RUNNING INSIDE IS NEVER DERIVED.
# The derived command is EXECUTED, not merely recorded, so deriving the harness
# that is currently the caller re-enters it: a nested run of this whole suite
# whose exit status grades nothing and whose nesting does not terminate. That is
# the shape iteration 1 regressed on — four escalation-resume arms deliver from
# inside the harness their own CHECKED line names, and the nested run's non-zero
# exit made `task deliver` REFUSE (exit 5) a delivery the row had always taken.
#
# This arm is the control for that: same row shape as the PART 5 positive above,
# only the harness NAME changed to this script's own, so a pass here and a pass
# there together say the guard is narrow — it declines the self-named case and
# nothing else.
SELFH="${0##*/}"
RD6=$(mkrepo repoD6); SHAD6=$(git -C "$RD6" rev-parse HEAD)
cp "$RD6/tests/h.sh" "$RD6/tests/$SELFH"
git -C "$RD6" add -A >/dev/null; git -C "$RD6" commit -qm selfharness >/dev/null
SHAD6=$(git -C "$RD6" rev-parse HEAD)
IDD6=$(add_row "CHECKED names the running harness")
( cd "$RD6" && cmd_task_deliver "$IDD6" --pr="$PR" \
    --result="$(printf 'CHANGED: x\nCHECKED: bash tests/%s\nDELIVERED-SHA: %s\nCI: green\nCRITERIA: x\n' "$SELFH" "$SHAD6")" >/dev/null 2>&1 ); RC6=$?
[[ "$(col "$IDD6" review_mode)" != "check" ]] \
  && ok_t "the harness we are running INSIDE is never derived (no recursive self-grade)" \
  || bad_t "the harness we are running INSIDE is never derived" "mode='$(col "$IDD6" review_mode)'"
# …and the delivery still goes through. The regression was not the flip, it was
# the flip taking a delivery AWAY, so the arm that matters is the exit status.
(( RC6 == 0 )) \
  && ok_t "…and that delivery is still ACCEPTED, not refused (the iteration-1 regression)" \
  || bad_t "…and that delivery is still ACCEPTED" "cmd_task_deliver exited $RC6"

echo "── PART 6 — mutation: cut the predicates, the arms above must go RED ─────"

# THE EVAL HAPPENS IN THE PARENT SHELL. Done inside `r=$(mutate …)` the cut
# function would live and die in the command substitution's subshell and every
# arm here would pass having mutated nothing.
CUT="$TMP/cut.sh"
mutate() { # <fn> <sed-expr> <marker-that-must-disappear>
  local fn="$1" expr="$2" gone="$3" body
  body=$(declare -f "$fn") || { printf 'NOFN'; return 1; }
  local cut; cut=$(printf '%s\n' "$body" | sed "$expr")
  [[ "$cut" == "$body" ]] && { printf 'NOOP'; return 1; }
  # Herestring, not `printf | grep -q`: under `pipefail` an early `grep -q` match
  # SIGPIPEs the producer and the pipeline exits 141, so a SUCCESSFUL match reads
  # as a failed assertion (DIVE-4811's swept shape).
  grep -q -- "$gone" <<<"$cut" && { printf 'STILLTHERE'; return 1; }
  printf '%s\n' "$cut" > "$CUT"
  bash -n "$CUT" || { printf 'BADSYNTAX'; return 1; }
  printf 'OK'
}

ORIG_TABLE=$(declare -f _task_grade_table)
r=$(mutate _task_grade_table 's/flags+="CONTROL-GREEN"/: /' 'flags+="CONTROL-GREEN"')
if [[ "$r" == "OK" ]] && . "$CUT"; then
  ok_t "mutation A landed: the CONTROL-GREEN flag is cut out of the shipping function"
  ( cd "$R2" && _task_grade_table X-2 "$CHK" "sed -i s/hello/xxx/ src/foo.sh" >/dev/null 2>&1 ); rc=$?
  (( rc == 0 )) && ok_t "…and the 'harness does not test the change' arm goes red (rc=0, no longer flagged)" \
    || bad_t "…and the 'harness does not test the change' arm goes red" "still rc=$rc — the arm is not testing the flag"
else bad_t "mutation A landed" "$r"; fi
eval "$ORIG_TABLE"
( cd "$R2" && _task_grade_table X-2 "$CHK" "sed -i s/hello/xxx/ src/foo.sh" >/dev/null 2>&1 )
(( $? != 0 )) && ok_t "the original table function is restored" || bad_t "the original table function is restored" "still mutated"

r=$(mutate _task_grade_table 's/flags+="MUTANT-NOT-APPLIED:\${mid}"/: /' 'MUTANT-NOT-APPLIED:\${mid}')
if [[ "$r" == "OK" ]] && . "$CUT"; then
  ok_t "mutation B landed: the 'the mutation did not apply' detector is cut out"
  ( cd "$R5" && _task_grade_table X-6 "$CHK" "" >/dev/null 2>&1 ); rc=$?
  (( rc != 4 )) && ok_t "…and the no-op-mutant arm goes red (rc=$rc, no longer vacuous)" \
    || bad_t "…and the no-op-mutant arm goes red" "still 4 with the detector removed"
else bad_t "mutation B landed" "$r"; fi
eval "$ORIG_TABLE"

r=$(mutate _task_grade_table 's/_c_new+=("\$_cp")/_c_have+=("$_cp")/' '_c_new+=')
if [[ "$r" == "OK" ]] && . "$CUT"; then
  ok_t "mutation F landed: the added-vs-existing split is cut out of the control arm"
  # NOT a subshell: `$_TASK_GRADE_TABLE` is set by the function, and a value set
  # inside ( ) never reaches the parent — an arm that grades a leaked global
  # through a subshell reads the PREVIOUS call's table and passes on it.
  cd "$R4" || exit 1
  _task_grade_table X-ADD "$CHK" "$MUT" >/dev/null 2>&1
  cd "$REPO_ROOT" || exit 1
  grep -q 'control DID NOT APPLY' <<<"$_TASK_GRADE_TABLE" \
    && ok_t "…and the added-file arm goes red (the whole revert fails atomically again)" \
    || bad_t "…and the added-file arm goes red" "the arm is not testing the split: table='$_TASK_GRADE_TABLE'"
else bad_t "mutation F landed" "$r"; fi
eval "$ORIG_TABLE"

ORIG_SAMPLE=$(declare -f _task_grade_sample_hit)
# The control first: at a large N this ident is NOT drawn. Without that, the
# mutated arm below would be green whether or not the cut changed anything.
export FIVEDIVE_GRADE_SAMPLE_N=100000
NOTDRAWN=DIVE-SAMPLE-CONTROL
_task_grade_sample_hit 1 "$NOTDRAWN" >/dev/null 2>&1
(( $? != 0 )) && ok_t "control: at 1-in-100000 this ident is NOT drawn for a read" \
  || bad_t "control: at 1-in-100000 this ident is NOT drawn" "drawn anyway — the mutation arm below would be vacuous"
r=$(mutate _task_grade_sample_hit 's/(( h % n == 0 )) || return 1/: /' 'h % n == 0')
if [[ "$r" == "OK" ]] && . "$CUT"; then
  ok_t "mutation C landed: the 1-in-N sample predicate is cut out"
  _task_grade_sample_hit 1 "$NOTDRAWN" >/dev/null 2>&1
  (( $? == 0 )) && ok_t "…and the sample-rate arm goes red (every green table is now drawn)" \
    || bad_t "…and the sample-rate arm goes red" "still not drawn with the predicate removed — the arm is not testing the rate"
else bad_t "mutation C landed" "$r"; fi
export FIVEDIVE_GRADE_SAMPLE_N=0
eval "$ORIG_SAMPLE"

ORIG_DERIVE=$(declare -f _task_grade_derive_check)
r=$(mutate _task_grade_derive_check 's/(( n <= max )) || return 1/: /' 'n <= max')
if [[ "$r" == "OK" ]] && . "$CUT"; then
  ok_t "mutation D landed: the harness-count cap is cut out"
  RM=$(mkrepo_suite repoM); SHAM=$(git -C "$RM" rev-parse HEAD)
  IDM=$(add_row "mutated cap")
  ( cd "$RM" && cmd_task_deliver "$IDM" --pr="$PR" \
      --result="$(printf 'CHANGED: x\nCHECKED: %s\nDELIVERED-SHA: %s\nCI: green\nCRITERIA: x\n' "$SUITE4" "$SHAM")" >/dev/null 2>&1 )
  [[ "$(col "$IDM" verify_command)" == *"tests/d.sh"* ]] \
    && ok_t "…and the cap arm goes red (a four-harness suite now derives)" \
    || bad_t "…and the cap arm goes red" "mode='$(col "$IDM" review_mode)' — the arm is not testing the cap"
else bad_t "mutation D landed" "$r"; fi
eval "$ORIG_DERIVE"

echo "── PART 7 — the table reaches the SEAT: the packet, and the method clause ─"

# THE GOAL TELLS THE GRADER TO USE ONLY THE PACKET (`_grader_process_goal` ->
# `5dive task grade-context`), so a table that lives only in the row body never
# reaches the seat that was woken because of it. These arms grade the two hops.
PKT=$( cd "$RF" && cmd_task_grade_context "$IDF" 2>/dev/null )
grep -q 'COMPUTED GRADE TABLE (DIVE-4825' <<<"$PKT" \
  && ok_t "the bounded grading packet CARRIES the computed table" \
  || bad_t "the bounded grading packet CARRIES the computed table" "packet='${PKT: -400}'"
grep -q 'VERDICT computed' <<<"$PKT" \
  && ok_t "…including its verdict line, which is the reason the seat was woken" \
  || bad_t "…including its verdict line" "packet='${PKT: -400}'"
grep -q 'do NOT re-run the unflagged lines' <<<"$PKT" \
  && ok_t "…and the packet says the unflagged lines are not to be re-run" \
  || bad_t "…and the packet says the unflagged lines are not to be re-run" "packet='${PKT: -400}'"

# NEGATIVE CONTROL: a row with no computed table must not grow the section.
PKTG=$( cd "$RG" && cmd_task_grade_context "$IDG" 2>/dev/null )
grep -q 'COMPUTED GRADE TABLE (DIVE-4825' <<<"$PKTG" \
  && bad_t "a row with NO table does not grow the section" "packet='${PKTG: -300}'" \
  || ok_t "a row with NO table does not grow the section (the arm above is not vacuous)"

if [[ -f src/task/grader_process.sh ]]; then
  # shellcheck disable=SC1091
  source src/task/grader_process.sh 2>/dev/null
fi
if declare -F _grader_grade_method_clause >/dev/null 2>&1; then
  CL=$(_grader_grade_method_clause "$IDF" 2>/dev/null)
  grep -q 'do not build a control or a mutant tree' <<<"$CL" \
    && ok_t "the grader's METHOD clause forbids rebuilding the control and mutant trees" \
    || bad_t "the grader's METHOD clause forbids rebuilding the trees" "clause='$CL'"
  grep -q 're-derive ONLY the flagged line' <<<"$CL" \
    && ok_t "…and names the one thing this seat was woken for" \
    || bad_t "…and names the one thing this seat was woken for" "clause='$CL'"
  CLG=$(_grader_grade_method_clause "$IDG" 2>/dev/null)
  grep -q 'do not build a control or a mutant tree' <<<"$CLG" \
    && bad_t "a row with NO table gets the ORDINARY clause" "clause='$CLG'" \
    || ok_t "a row with NO table gets the ORDINARY clause (the arms above are not vacuous)"
  ORIG_CL=$(declare -f _grader_grade_method_clause)
  r=$(mutate _grader_grade_method_clause 's/if \[\[ -n "\$tbl" \]\]; then/if false; then/' 'n "\$tbl" \]\]; then')
  if [[ "$r" == "OK" ]] && . "$CUT"; then
    ok_t "mutation E landed: the computed-table branch is cut out of the method clause"
    CLM=$(_grader_grade_method_clause "$IDF" 2>/dev/null)
    grep -q 're-derive ONLY the flagged line' <<<"$CLM" \
      && bad_t "…and the method-clause arms go red" "still names the rule with the branch removed" \
      || ok_t "…and the method-clause arms go red (the flagged-line rule is gone)"
  else bad_t "mutation E landed" "$r"; fi
  eval "$ORIG_CL"
else
  bad_t "grader method clause reachable" "_grader_grade_method_clause not defined — PART 7's clause arms did not run"
fi

echo "── PART 8 — mutation: cut the self-recursion guard ───────────────────────"
# Without a mutant this arm is a predicate that has never been shown able to
# fail: the row could stop deriving for an unrelated reason and the control
# above would still read green.
ORIG_DERIVE2=$(declare -f _task_grade_derive_check)
r=$(mutate _task_grade_derive_check 's|\[\[ "\${_self##\*/}" == "\${cand##\*/}" \]\] && return 1|:|' '_self##\*/')
if [[ "$r" == "OK" ]] && . "$CUT"; then
  ok_t "mutation F landed: the self-harness guard is cut out of the derive"
  RD7=$(mkrepo repoD7)
  cp "$RD7/tests/h.sh" "$RD7/tests/$SELFH"
  git -C "$RD7" add -A >/dev/null; git -C "$RD7" commit -qm selfharness >/dev/null
  SHAD7=$(git -C "$RD7" rev-parse HEAD)
  IDD7=$(add_row "CHECKED names the running harness, guard cut")
  ( cd "$RD7" && cmd_task_deliver "$IDD7" --pr="$PR" \
      --result="$(printf 'CHANGED: x\nCHECKED: bash tests/%s\nDELIVERED-SHA: %s\nCI: green\nCRITERIA: x\n' "$SELFH" "$SHAD7")" >/dev/null 2>&1 )
  [[ "$(col "$IDD7" review_mode)" == "check" ]] \
    && ok_t "…and the self-harness arm goes red (the running harness now derives)" \
    || bad_t "…and the self-harness arm goes red" "mode='$(col "$IDD7" review_mode)' — the arm would pass with the guard gone, so it proves nothing"
else bad_t "mutation F landed" "$r"; fi
eval "$ORIG_DERIVE2"


echo
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAILN"
(( FAILN == 0 )) || exit 1
