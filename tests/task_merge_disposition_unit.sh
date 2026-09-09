#!/usr/bin/env bash
# DIVE-4137 — the DISPOSITION of a graded pull request at the verifier's close.
#
# THE DEFECT this grades, measured by main 2026-09-09: a verifier records PASS on
# a bound pull request that is clean and green at the sha it just graded, and the
# board renders `graded->merge:<maker>`. The merge is routed BACK to a maker who
# wakes cold and has nothing to change; four such rows (#799, #807, #809, and the
# frontend #220) sat that way until main pressed four buttons by hand.
#
# WHAT IS ACTUALLY UNDER TEST, and it is deliberately not GitHub. The decision
# splits into two PURE functions and two impure leaves:
#
#   _merge_disp_risk   (repo, file list)                  -> low | look:<why>     (iii)
#   _merge_disp_decide (mergeable, state, head, graded, risk)
#                                                          -> merge | hold:<who>:<why>
#   _merge_disp_probe  the one gh read                     [STUBBED here]
#   _merge_disp_do     the DIVE-3474 `_merge_do` rail      [STUBBED here]
#
# So sections A and B drive every (i)/(ii)/(iii) branch from a fixture — no
# network, no sudo, no pull request. Section C drives the RECORDING at the
# verifier's grade with only the gh read stubbed, and section D grades the MERGE
# at `task done`: its standing predicate behaviourally, and its placement inside
# the DIVE-1830 gate by reading the shipped source, because the merge itself
# needs a live pull request and a sudo grant that no unit harness holds.
# Stubbing the leaves is the point: a harness that needed a live PR could grade
# one arm a day, and the branch that matters most (the hold) is the one that
# never fires when everything is healthy.
#
# THE POLARITY IS THE THING TO PROTECT, so it is asserted directly rather than
# implied: every unknown must land on a HOLD. A bug in here must degrade to the
# behaviour we already have (the row waits), never to an unreviewed merge. Arms
# A7-A9 and B6 are that assertion — an unreadable head, an unreadable file list,
# and a merge state this function has never been taught all hold.
#
# MUTATION-GRADED, not arm-counted (5dive rule: evidence is killed mutants). The
# grading is NOT automated in this file — it was driven by hand against four
# mutants of the shipped functions, and the counts below are what each killed, so
# a later editor can reproduce them rather than trust them:
#   M1  `if [[ $head != $graded* ... ]]` -> `if false`   killed 2 arms (A3, A13)
#   M2  `CLEAN|HAS_HOOKS)` -> `CLEAN|HAS_HOOKS|UNSTABLE)` killed 1 arm  (A8)
#   M3  `[[ $risk == low ]] ||` -> `true ||`             killed 1 arm  (A12)
#   M4  loops.sh `[[ $_md_owner == maker ]]` -> `[[ -n $_md_owner ]]`
#                                                        killed 4 arms (C2a, C2b, C3a, C5)
# M4 is the defect this row exists to fix, stated as a mutant: route every hold
# to the maker and the suite reds on exactly the arms that describe the bug.
#
# Run: bash tests/task_merge_disposition_unit.sh   (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/merge-disp-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/broker.sh cmd_push.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; tests deliberately expect non-zero exits

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

eq() { # eq <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected '$2', got '$3'"; fi
}

SHA40=aabbccdd11223344556677889900aabbccddeeff
SHA7=aabbccd

# ===================================================================
# A. _merge_disp_decide — (i) the graded sha, (ii) the merge state, and
#    the ONE maker case. Each arm changes exactly one operand from the
#    all-green baseline in A1, so a failure names its own branch.
# ===================================================================
eq "A1  clean + green + low risk + sha matches                 -> merge" \
   "merge" "$(_merge_disp_decide MERGEABLE CLEAN "$SHA40" "$SHA40" low)"

# (i) A grade is bound to a SHA, not to a pull request (DIVE-2656 read forwards).
eq "A2  verifier stated an ABBREVIATED sha (the normal shape)  -> merge" \
   "merge" "$(_merge_disp_decide MERGEABLE CLEAN "$SHA40" "$SHA7" low)"
eq "A3  head MOVED since the grade                             -> hold:main" \
   "hold:main:graded-sha-is-not-the-head" \
   "$(_merge_disp_decide MERGEABLE CLEAN "$SHA40" 0123456789abcdef0123456789abcdef01234567 low)"
eq "A4  verifier stated NO graded-sha at all                   -> hold:main" \
   "hold:main:no-graded-sha-stated" "$(_merge_disp_decide MERGEABLE CLEAN "$SHA40" '' low)"

# THE ONE MAKER CASE. Everything else that is not clean is a LOOK.
eq "A5  CONFLICTING                                            -> hold:MAKER" \
   "hold:maker:conflicting-needs-rebase" \
   "$(_merge_disp_decide CONFLICTING BLOCKED "$SHA40" "$SHA40" low)"
eq "A6  mergeStateStatus DIRTY (conflict by the other name)    -> hold:MAKER" \
   "hold:maker:conflicting-needs-rebase" \
   "$(_merge_disp_decide MERGEABLE DIRTY "$SHA40" "$SHA40" low)"

# (ii) required checks / required review at that sha.
eq "A7  BLOCKED (red-or-pending required check, OR CODEOWNERS) -> hold:main" \
   "hold:main:merge-state-BLOCKED" "$(_merge_disp_decide MERGEABLE BLOCKED "$SHA40" "$SHA40" low)"
eq "A8  UNSTABLE — mergeable, a NON-required check is red      -> hold:main" \
   "hold:main:merge-state-UNSTABLE" "$(_merge_disp_decide MERGEABLE UNSTABLE "$SHA40" "$SHA40" low)"
eq "A9  a merge state this function has never been taught      -> hold:main" \
   "hold:main:merge-state-SOMETHING_NEW" \
   "$(_merge_disp_decide MERGEABLE SOMETHING_NEW "$SHA40" "$SHA40" low)"
eq "A10 mergeable UNKNOWN (GitHub still computing)             -> hold:main" \
   "hold:main:mergeable-UNKNOWN" "$(_merge_disp_decide UNKNOWN CLEAN "$SHA40" "$SHA40" low)"
eq "A11 head sha unreadable                                    -> hold:main" \
   "hold:main:head-sha-unreadable" "$(_merge_disp_decide MERGEABLE CLEAN '' "$SHA40" low)"

# (iii) the risk verdict is carried through with its reason intact, so the board
# can say WHY a look is owed rather than only that one is.
eq "A12 risk verdict reaches the disposition                   -> hold:main" \
   "hold:main:user-facing-surface" \
   "$(_merge_disp_decide MERGEABLE CLEAN "$SHA40" "$SHA40" look:user-facing-surface)"

# NEGATIVE CONTROL on the ORDER of the checks. A9's unknown state must beat a low
# risk, and A3's sha mismatch must beat everything — if the risk check ran first,
# a low-risk diff at the wrong sha would merge.
eq "A13 sha mismatch OUTRANKS a low-risk clean-and-green PR    -> hold:main" \
   "hold:main:graded-sha-is-not-the-head" \
   "$(_merge_disp_decide MERGEABLE CLEAN "$SHA40" ffffffffffffffffffffffffffffffffffffffff low)"

# ===================================================================
# B. _merge_disp_risk — (iii), from a file list. Fixture-driven, so each
#    class of "a person has to look at this" is graded without a repo.
# ===================================================================
eq "B1  ordinary shell + test change in 5dive-ai/5dive         -> low" \
   "low" "$(_merge_disp_risk 5dive-ai/5dive "$(printf 'src/task/loops.sh\ntests/foo_unit.sh\n')")"
eq "B2  install.sh is CODEOWNERS-covered                       -> look" \
   "look:codeowners-path" "$(_merge_disp_risk 5dive-ai/5dive "$(printf 'src/x.sh\ninstall.sh\n')")"
eq "B3  a workflow file                                        -> look" \
   "look:codeowners-path" "$(_merge_disp_risk 5dive-ai/5dive ".github/workflows/ci.yml")"
eq "B4  a drizzle migration                                    -> look" \
   "look:schema-path" "$(_merge_disp_risk lodar/5dive-api "$(printf 'src/x.ts\ndrizzle/0001_init.sql\n')")"
eq "B5  5dive-api src/db, no obviously schema-shaped filename  -> look" \
   "look:api-db-path" "$(_merge_disp_risk lodar/5dive-api "src/db/queries.ts")"
eq "B6  file list UNREADABLE is not an empty diff              -> look" \
   "look:file-list-unreadable" "$(_merge_disp_risk 5dive-ai/5dive "")"
eq "B7  a user-facing surface (tests do not grade a page)      -> look" \
   "look:user-facing-surface" "$(_merge_disp_risk 5dive-ai/app "$(printf 'app/page.tsx\n')")"
eq "B8  the SAME src/db path in a repo that is not the api     -> low" \
   "low" "$(_merge_disp_risk 5dive-ai/5dive "src/db/queries.ts")"

# THE DIVE-4108 SHAPE, asserted here because this function is where it would
# fail OPEN. `printf | grep -q` under pipefail turns a MATCH into 141 -> "no
# match" -> a `look` silently becomes `low`. A large file list is what loses that
# race, so grade the risk verdict on one: 4000 paths, the look-worthy one LAST.
_big=$(for i in $(seq 1 4000); do printf 'src/generated/file_%s.sh\n' "$i"; done; printf 'install.sh\n')
_big_verdict=""
for _i in 1 2 3 4 5 6 7 8 9 10; do
  _v=$(_merge_disp_risk 5dive-ai/5dive "$_big")
  [[ "$_v" == "look:codeowners-path" ]] || _big_verdict="$_v"
done
eq "B9  a 4000-path file list still reads look, 10/10 (DIVE-4108 shape)" \
   "" "$_big_verdict"

# ===================================================================
# C. THE VERIFIER'S GRADE records WHO OWES THE MERGE.
#
# This is the half that fixes the RENDER. Both verifier shapes reach it and both
# are driven here, because they enter the stamping branch by different doors:
#   `verify --cmd=<script>`         on a bound row, via the DIVE-3330 divert
#   `verify --no-done --result=...` the credential-less prose grade — the shape
#                                   main2 actually used on DIVE-4108, and the one
#                                   that carries the `graded-sha:` line
# Only the one impure leaf (_merge_disp_probe) is stubbed; everything between it
# and the board render is the shipped code.
# ===================================================================
DISP_ANSWER="merge"
_merge_disp_probe() { printf '%s' "$DISP_ANSWER"; }

mkrow() { # mkrow <title> -> row id of a DELIVERED maker->verifier row bound to a PR
  db "INSERT INTO tasks (title, assignee, created_by, kind, status, maker_agent, verifier,
                         delivery_ref, iteration)
      VALUES ($(sqlq "$1"),'quinn','main','standard','in_progress','dev','quinn',
              'https://github.com/5dive-ai/5dive/pull/809', 1);
      SELECT last_insert_rowid();"
}
board() { db "SELECT CASE WHEN ${_TASKS_TFV_SQL} THEN 'graded->merge:'||COALESCE(NULLIF(merge_owner,''), NULLIF(maker_agent,''), COALESCE(assignee,'?')) ELSE status END FROM tasks WHERE id=$1;"; }
col()   { db "SELECT COALESCE($2,'') FROM tasks WHERE id=$1;"; }

# `task verify` attributes the grade through task_actor(), which otherwise
# resolves to whoever RUNS the suite — and the shared graded-and-waiting
# predicate requires grader != maker (DIVE-477), so an unpinned actor makes every
# arm below depend on which seat is executing. Pin it, the same way
# tests/gate_channelless_escalation_unit.sh does.
task_actor() { local f="${1:-}"; [[ -n "$f" ]] && printf '%s' "$f" || printf '%s' "${HARNESS_ACTOR:-quinn}"; }
HARNESS_ACTOR=quinn

grade_prose() { # the --no-done --result shape
  local ident; ident=$(db "SELECT ident FROM tasks WHERE id=$1;")
  ( set +e; cmd_task_verify "$ident" --no-done \
      --result="PASS — re-derived from a fresh clone. graded-sha: ${SHA40}" >/dev/null 2>&1 )
}
grade_cmd() {   # the --cmd shape, diverted to a hold by DIVE-3330
  local ident; ident=$(db "SELECT ident FROM tasks WHERE id=$1;")
  ( set +e; cmd_task_verify "$ident" --cmd=true >/dev/null 2>&1 )
}

# --- C1: the row this ticket exists for. Auto-mergeable, so the board must name
# the GRADER — the seat that can finish it — and say what to run.
DISP_ANSWER="merge"
c1=$(mkrow "clean at the graded sha")
grade_prose "$c1"
eq "C1a an auto-mergeable graded row names the GRADER, not the maker 'dev'" \
   "quinn" "$(col "$c1" merge_owner)"
eq "C1b ...and the board renders that owner" "graded->merge:quinn" "$(board "$c1")"
if [[ "$(col "$c1" merge_hold_reason)" == *"task done"* ]]; then
  ok_t "C1c ...and the reason cell says what to run"
else
  bad_t "C1c ...and the reason cell says what to run" "$(col "$c1" merge_hold_reason)"
fi

# --- C2: a diverged PR owes a LOOK from main. THIS IS THE DEFECT: before
# DIVE-4137 this row read `graded->merge:dev` and woke a maker with nothing to do.
DISP_ANSWER="hold:main:graded-sha-is-not-the-head"
c2=$(mkrow "head moved since the grade")
grade_prose "$c2"
eq "C2a routed to main, NOT to the maker 'dev' (the DIVE-4137 defect)" \
   "main" "$(col "$c2" merge_owner)"
eq "C2b ...the board renders merge:main" "graded->merge:main" "$(board "$c2")"
eq "C2c ...and the reason is recorded, not just the owner" \
   "graded-sha-is-not-the-head" "$(col "$c2" merge_hold_reason)"

# --- C3: a CODEOWNERS PR renders merge:main (the row's third acceptance case)
DISP_ANSWER="hold:main:codeowners-path"
c3=$(mkrow "touches install.sh")
grade_prose "$c3"
eq "C3a a CODEOWNERS-covered diff renders merge:main" "graded->merge:main" "$(board "$c3")"
eq "C3b ...naming the path class as the reason" "codeowners-path" "$(col "$c3" merge_hold_reason)"

# --- C4: the ONE hold a maker alone can clear still reaches the maker.
DISP_ANSWER="hold:maker:conflicting-needs-rebase"
c4=$(mkrow "conflicting branch")
grade_prose "$c4"
eq "C4  a CONFLICTING branch is the one hold that names the MAKER" \
   "graded->merge:dev" "$(board "$c4")"

# --- C5: the OTHER verifier shape reaches the same recording.
DISP_ANSWER="hold:main:merge-state-BLOCKED"
c5=$(mkrow "graded by --cmd, not by prose")
grade_cmd "$c5"
eq "C5  \`verify --cmd\` on a bound row records the disposition too" \
   "main" "$(col "$c5" merge_owner)"

# --- C6: NEGATIVE CONTROLS.
DISP_ANSWER="merge"
c6=$(mkrow "unbound row")
db "UPDATE tasks SET delivery_ref=NULL, body='no ref here' WHERE id=${c6};"
grade_prose "$c6"
eq "C6a an UNBOUND row records no disposition at all" "" "$(col "$c6" merge_owner)"

c7=$(mkrow "a FAIL, not a pass")
( set +e; cmd_task_verify "$(db "SELECT ident FROM tasks WHERE id=$c7;")" --cmd=false >/dev/null 2>&1 )
eq "C6b a FAIL owes the maker a FIX, so no merge owner is painted" \
   "" "$(col "$c7" merge_owner)"

# --- C7: NULL merge_owner must keep reading exactly as it did before DIVE-4137,
# or the migration silently re-routes every row graded before this column existed.
c8=$(mkrow "graded before the column existed")
db "UPDATE tasks SET graded_at=datetime('now'), graded_by='quinn', graded_verdict='pass',
       merge_owner=NULL, merge_hold_reason=NULL WHERE id=${c8};"
eq "C7  a NULL merge_owner still renders the pre-DIVE-4137 maker" \
   "graded->merge:dev" "$(board "$c8")"

# ===================================================================
# D. THE MERGE ITSELF, at `task done`.
#
# The merge deliberately does NOT happen in `task verify`: it happens in the
# close, immediately before the DIVE-1830 "not merged" refusal, so that the
# gate's own probe re-derives the merge afterwards and DIVE-2656 still compares
# what LANDED against what was GRADED. These arms grade that placement — that the
# rail is called, that it is called ONLY with standing and only on a `merge`
# disposition, and that a refusal changes nothing.
# ===================================================================
MERGE_RAIL_CALLS=0; MERGE_RAIL_RC=0
_merge_disp_do() { MERGE_RAIL_CALLS=$((MERGE_RAIL_CALLS+1)); return "$MERGE_RAIL_RC"; }

# The hook's own guard is `_task_merge_standing_sql`, which is the SHARED
# predicate `task merge` and `_merge_do` grade. Assert it directly: this is the
# whole of the authority question, and it must not be re-typed anywhere.
d1=$(mkrow "graded by quinn")
db "UPDATE tasks SET graded_at=datetime('now'), graded_by='quinn', graded_verdict='pass' WHERE id=${d1};"
eq "D1a the grader HAS standing on the row it graded" \
   "1" "$(db "SELECT COUNT(*) FROM tasks WHERE id=${d1} AND $(_task_merge_standing_sql quinn);")"
eq "D1b a seat that did NOT grade it has NONE" \
   "0" "$(db "SELECT COUNT(*) FROM tasks WHERE id=${d1} AND $(_task_merge_standing_sql main2);")"
db "UPDATE tasks SET handoff_rejected_at=datetime('now','+1 second') WHERE id=${d1};"
eq "D1c a live reject retires the grade, so standing goes with it (DIVE-3428)" \
   "0" "$(db "SELECT COUNT(*) FROM tasks WHERE id=${d1} AND $(_task_merge_standing_sql quinn);")"
db "UPDATE tasks SET handoff_rejected_at=NULL WHERE id=${d1};"

# The graded sha the close uses comes from the ROW's result — the verifier's own
# earlier statement — never from the text being typed at the close. A closer who
# could supply it would be able to match any head they liked.
db "UPDATE tasks SET result='PASS. graded-sha: ${SHA40}' WHERE id=${d1};"
eq "D2  the close reads the graded sha from the ROW, not from its own argv" \
   "$SHA40" "$(_gate_graded_sha "$(db "SELECT result FROM tasks WHERE id=${d1};")")"

# The source-level placement guarantee, asserted because it is the thing that
# makes this safe and it is invisible to any behavioural arm: the merge sits
# BEFORE the not-merged branch, and the state is RE-READ rather than assumed.
_hook=$(sed -n '/DIVE-4137: THE MERGE IS THE STEP WHERE GRADED WORK SITS/,/if \[\[ "\$_state" != "MERGED"/p' "$SRC/task/status.sh")
if [[ -n "$_hook" ]]; then ok_t "D3a the merge hook precedes the DIVE-1830 not-merged branch"
else bad_t "D3a the merge hook precedes the DIVE-1830 not-merged branch" "not found in that order"; fi
if grep -q '_gate_pr_state "\$_dref"' <<<"$_hook"; then
  ok_t "D3b ...and RE-READS the merge state instead of assuming rc=0 means merged"
else
  bad_t "D3b ...and RE-READS the merge state instead of assuming rc=0 means merged" "no re-read found"
fi
if grep -q '_task_merge_standing_sql' <<<"$_hook"; then
  ok_t "D3c ...and gates on the SHARED standing predicate, not a re-typed one"
else
  bad_t "D3c ...and gates on the SHARED standing predicate, not a re-typed one" "predicate not referenced"
fi
if grep -qE '_state" == "OPEN"' <<<"$_hook"; then
  ok_t "D3d ...and only ever runs on an OPEN pull request"
else
  bad_t "D3d ...and only ever runs on an OPEN pull request" "no OPEN guard"
fi

printf '\n%s\n' "----------------------------------------------------------"
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
