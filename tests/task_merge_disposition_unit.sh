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
#   _merge_disp_probe  the one gh read      [section E stubs `_gate_gh` UNDER it;
#                                           sections C/D stub the probe itself]
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
# ITERATION 2 adds section E and the mutants it exists to kill. Quinn found at
# iteration 1 that _merge_disp_probe was stubbed in every arm, so two mutants of
# the one function that can fail OPEN survived a green suite:
#   M5  whole body -> `printf merge; return 0`        killed 14 arms (E1-E3, E5,
#                                                     E6, E7 x3, E8, E9, E10,
#                                                     E12, E13a, E13b)
#   M6  `hold:merger:pr-state-unreadable` -> `merge`  killed  2 arms (E2, E3)
#   M7  the new empty-slug guard deleted              killed  2 arms (E7, E12)
#   M8  files re-joined onto ONE line before the risk
#       check (the line-anchored patterns then miss)  killed  3 arms (E8, E13a,
#                                                                    E13b)
# M5 and M6 are quinn's own two survivors from iteration 1, restated. M1 also
# picks up E6 now, so the sha comparison is graded through the read as well as
# from a fixture.
#
# DIVE-4512 adds section C's arm C8 — the shape none of the above could see,
# because every earlier arm grades a row ONCE. Its mutants, driven by hand the
# same way:
#   M9   loops.sh `_md_owner=$(db "SELECT ...graded_by...")` restored to the bare
#        `_md_owner=$(task_actor "")`              killed 3 arms (C8d, C8e, C8f)
#   M10  the empty-graded_by fallback line deleted killed 1 arm  (C8h)
#   M11  the read points at `maker_agent` instead
#        of `graded_by`                            killed 7 arms (C1a, C1b, C8b,
#                                                  C8d, C8e, C8f, C8h)
# M9 is the defect DIVE-4512 exists to fix, stated as a mutant.
#
# Run: bash tests/task_merge_disposition_unit.sh   (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/merge-disp-unit.XXXXXX)"

# DIVE-4326 — the roster the hold-seat resolver reads, pinned to a FIXTURE before
# the source loop below, because the constants that name it are `readonly` and are
# resolved from the environment at source time. Without this every arm that
# touches a hold would depend on whether the box this suite runs on happens to
# have agent-ops enabled, i.e. the suite would grade the host and not the code.
ROSTER="$TMP/agents.json"
roster() { printf '{"agents":{"ops":{"heartbeat":{"enabled":%s}},"main":{"heartbeat":{"enabled":true}}}}\n' "${1:-true}" >"$ROSTER"; }
roster true
export FIVE_MERGE_HOLD_ROSTER="$ROSTER"

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
eq "A3  head MOVED since the grade                             -> hold:merger" \
   "hold:merger:graded-sha-is-not-the-head" \
   "$(_merge_disp_decide MERGEABLE CLEAN "$SHA40" 0123456789abcdef0123456789abcdef01234567 low)"
eq "A4  verifier stated NO graded-sha at all                   -> hold:merger" \
   "hold:merger:no-graded-sha-stated" "$(_merge_disp_decide MERGEABLE CLEAN "$SHA40" '' low)"

# THE ONE MAKER CASE. Everything else that is not clean is a LOOK.
eq "A5  CONFLICTING                                            -> hold:MAKER" \
   "hold:maker:conflicting-needs-rebase" \
   "$(_merge_disp_decide CONFLICTING BLOCKED "$SHA40" "$SHA40" low)"
eq "A6  mergeStateStatus DIRTY (conflict by the other name)    -> hold:MAKER" \
   "hold:maker:conflicting-needs-rebase" \
   "$(_merge_disp_decide MERGEABLE DIRTY "$SHA40" "$SHA40" low)"

# (ii) required checks / required review at that sha.
eq "A7  BLOCKED (red-or-pending required check, OR CODEOWNERS) -> hold:merger" \
   "hold:merger:merge-state-BLOCKED" "$(_merge_disp_decide MERGEABLE BLOCKED "$SHA40" "$SHA40" low)"
eq "A8  UNSTABLE — mergeable, a NON-required check is red      -> hold:merger" \
   "hold:merger:merge-state-UNSTABLE" "$(_merge_disp_decide MERGEABLE UNSTABLE "$SHA40" "$SHA40" low)"
eq "A9  a merge state this function has never been taught      -> hold:merger" \
   "hold:merger:merge-state-SOMETHING_NEW" \
   "$(_merge_disp_decide MERGEABLE SOMETHING_NEW "$SHA40" "$SHA40" low)"
eq "A10 mergeable UNKNOWN (GitHub still computing)             -> hold:merger" \
   "hold:merger:mergeable-UNKNOWN" "$(_merge_disp_decide UNKNOWN CLEAN "$SHA40" "$SHA40" low)"
eq "A11 head sha unreadable                                    -> hold:merger" \
   "hold:merger:head-sha-unreadable" "$(_merge_disp_decide MERGEABLE CLEAN '' "$SHA40" low)"

# (iii) the risk verdict is carried through with its reason intact, so the board
# can say WHY a look is owed rather than only that one is.
eq "A12 risk verdict reaches the disposition                   -> hold:merger" \
   "hold:merger:user-facing-surface" \
   "$(_merge_disp_decide MERGEABLE CLEAN "$SHA40" "$SHA40" look:user-facing-surface)"

# NEGATIVE CONTROL on the ORDER of the checks. A9's unknown state must beat a low
# risk, and A3's sha mismatch must beat everything — if the risk check ran first,
# a low-risk diff at the wrong sha would merge.
eq "A13 sha mismatch OUTRANKS a low-risk clean-and-green PR    -> hold:merger" \
   "hold:merger:graded-sha-is-not-the-head" \
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
# E. _merge_disp_probe — THE FUNCTION THAT MANUFACTURES THE UNKNOWNS.
#
# It runs HERE, before section C, because C replaces this very function with a
# fixture stub. Do not move it below C.
#
# WHY THIS SECTION EXISTS (quinn, iteration 1, and the finding is correct): at
# iteration 1 the probe body was stubbed in all 43 arms, so two mutants of it
# survived a fully green suite — (1) the whole function replaced by
# `printf merge; return 0`, and (2) its unreadable-read guard flipped from
# `hold:ops:pr-state-unreadable` to `merge`. The polarity claim ("every unknown
# is a HOLD") is the entire safety case of this row, and it was asserted for the
# two PURE functions and NOT for the one impure function that can fail OPEN into
# an unreviewed squash to main. Sections A/B grade the decision; this section
# grades the READ, by stubbing one layer lower — `_gate_gh` — so the probe's own
# parsing, slug extraction and file-list handling are the shipped code.
# ===================================================================
GH_RAW=""; GH_RC=0
_gate_gh_token() { printf 'fixture-token'; }
_gate_gh() { [[ -n "$GH_RAW" ]] && printf '%s' "$GH_RAW"; return "$GH_RC"; }
US=$'\x1f'
rec() { # rec <mergeable> <state> <head> <url> <file>... -> one US-joined record
  local m="$1" st="$2" hd="$3" u="$4"; shift 4
  local f=""; if (( $# )); then printf -v f '%s\n' "$@"; f="${f%$'\n'}"; fi
  printf '%s%s%s%s%s%s%s%s%s' "$m" "$US" "$st" "$US" "$hd" "$US" "$u" "$US" "$f"
}
PRURL=https://github.com/5dive-ai/5dive/pull/809
APIURL=https://github.com/lodar/5dive-api/pull/7

# --- the read never happened, or came back with nothing to parse.
GH_RAW=""; GH_RC=0
eq "E1  no delivery ref at all                                 -> hold:ops" \
   "hold:ops:no-delivery-ref" "$(_merge_disp_probe "" "$SHA40")"
eq "E2  the read SUCCEEDS but returns nothing                  -> hold:ops" \
   "hold:ops:pr-state-unreadable" "$(_merge_disp_probe "$PRURL" "$SHA40")"
GH_RC=1
eq "E3  the read FAILS (no rail, timeout, 404)                 -> hold:ops" \
   "hold:ops:pr-state-unreadable" "$(_merge_disp_probe "$PRURL" "$SHA40")"
GH_RC=0

# --- the baseline. Without a real `merge` reachable through the shipped body,
# every hold below could be produced by a probe that holds unconditionally, and
# the section would grade nothing.
GH_RAW=$(rec MERGEABLE CLEAN "$SHA40" "$PRURL" src/task/loops.sh tests/foo_unit.sh)
eq "E4  a well-formed CLEAN record at the graded sha           -> merge" \
   "merge" "$(_merge_disp_probe "$PRURL" "$SHA40")"

# --- and the converse: the parsed fields actually reach the decision. Kills the
# `printf merge; return 0` mutant that survived iteration 1.
GH_RAW=$(rec CONFLICTING BLOCKED "$SHA40" "$PRURL" src/task/loops.sh)
eq "E5  a CONFLICTING record is parsed and routed to the MAKER" \
   "hold:maker:conflicting-needs-rebase" "$(_merge_disp_probe "$PRURL" "$SHA40")"
GH_RAW=$(rec MERGEABLE CLEAN 0123456789abcdef0123456789abcdef01234567 "$PRURL" src/task/loops.sh)
eq "E6  the HEAD field is the one compared against the grade" \
   "hold:ops:graded-sha-is-not-the-head" "$(_merge_disp_probe "$PRURL" "$SHA40")"

# --- MISSHAPEN RECORDS. Fewer separators than expected: bash's `${rest#*$US}` on
# a string with no US returns the string UNCHANGED, so a truncated record does not
# error — it silently shifts every field left and would otherwise be parsed as if
# it were whole. Each of these must hold; none may merge.
for _shape in "MERGEABLE" "MERGEABLE${US}CLEAN" "MERGEABLE${US}CLEAN${US}${SHA40}"; do
  GH_RAW="$_shape"
  _got=$(_merge_disp_probe "$PRURL" "$SHA40")
  case "$_got" in
    hold:*) ok_t "E7  a truncated record ($(( $(grep -o "$US" <<<"$_shape" | wc -l) + 1 )) of 5 fields) holds: $_got" ;;
    *)      bad_t "E7  a truncated record must hold" "got '$_got'" ;;
  esac
done
GH_RAW=$(rec MERGEABLE CLEAN "$SHA40" "$PRURL")
eq "E8  a whole record whose FILE LIST is empty                -> hold:ops" \
   "hold:ops:file-list-unreadable" "$(_merge_disp_probe "$PRURL" "$SHA40")"

# --- THE SLUG COMES FROM THE RESOLVED URL, NOT FROM THE CALLER'S REF. The ref
# can be a bare `#7`, and a caller that named a different repo must not be able to
# talk the risk check out of the sharp one. E9/E10/E11 are one experiment: the
# file list is IDENTICAL in all three and only the url moves.
GH_RAW=$(rec MERGEABLE CLEAN "$SHA40" "$APIURL" src/db/queries.ts)
eq "E9  ref is a bare '#7'; the URL names the api repo         -> look" \
   "hold:ops:api-db-path" "$(_merge_disp_probe "#7" "$SHA40")"
eq "E10 ...and the CALLER naming a different repo cannot undo it" \
   "hold:ops:api-db-path" "$(_merge_disp_probe "$PRURL" "$SHA40")"
GH_RAW=$(rec MERGEABLE CLEAN "$SHA40" "$PRURL" src/db/queries.ts)
eq "E11 NEGATIVE CONTROL: same paths, url is NOT the api repo  -> merge" \
   "merge" "$(_merge_disp_probe "$APIURL" "$SHA40")"

# --- an UNRESOLVABLE url is an unknown, so it holds. Before this arm it fell
# through with repo='' and the `*/5dive-api` test could never fire — an unreadable
# url failed OPEN on precisely the repo where a merge pushes schema.
GH_RAW=$(rec MERGEABLE CLEAN "$SHA40" "" src/db/queries.ts)
eq "E12 the url field did not come back                        -> hold:ops" \
   "hold:ops:repo-unresolved" "$(_merge_disp_probe "$PRURL" "$SHA40")"

# --- THE FILE LIST IS A LIST, and the look patterns are LINE-ANCHORED. If the
# list ever collapses to one line, `install.sh` is only found when it happens to
# be LAST — so put it FIRST. This arm reds on a probe that stopped splitting.
GH_RAW=$(rec MERGEABLE CLEAN "$SHA40" "$PRURL" install.sh src/task/loops.sh)
eq "E13a a look-worthy path that is NOT last is still found" \
   "hold:ops:codeowners-path" "$(_merge_disp_probe "$PRURL" "$SHA40")"
# ...and the iteration-1 shape quinn flagged: joined with a space and re-split
# with `tr`, `a dir/install.sh` became `a` + `dir/install.sh`. It matched anyway
# through the basename anchor, which is why it was non-blocking — but a path with
# a space must stay ONE token, or a pattern ever loosened to a directory prefix
# turns a look into a low.
GH_RAW=$(rec MERGEABLE CLEAN "$SHA40" "$PRURL" "a dir/install.sh")
eq "E13b a path containing a SPACE stays one token" \
   "hold:ops:codeowners-path" "$(_merge_disp_probe "$PRURL" "$SHA40")"

unset -f _gate_gh _gate_gh_token

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
# Keep the REAL probe reachable under a second name before stubbing it — section F
# grades the shipped decide->resolve chain end to end and needs it back.
eval "_merge_disp_probe_real() $(declare -f _merge_disp_probe | tail -n +2)"
_merge_disp_probe() { printf '%s' "$DISP_ANSWER"; }
# DIVE-4999: the hint below is printed only when this box's merge account may push
# to the repo. That read is its own leaf (graded in
# tests/merge_hint_push_permission_unit.sh); here the account CAN, which is the
# shape every C-arm about the hint's wording was written for.
_merge_push_probe() { printf 'push 5dive-ai/5dive'; }

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
# DIVE-4520: WHICH VERB. Before this ticket the cell read `run `5dive task done``
# — and on a loop row that verb re-delivers an unchanged pass, moves the delivery
# clock past the verdict clock, and strips merge standing from the seat named one
# field to the left. The board's own instruction was what stalled DIVE-4491. Both
# halves are asserted, because "contains task merge" alone would still pass a cell
# that offered both verbs.
_c1c=$(col "$c1" merge_hold_reason)
if [[ "$_c1c" == *"task merge"* && "$_c1c" != *"task done"* ]]; then
  ok_t "C1c ...and the reason cell says to run \`task merge\`, never \`task done\` (DIVE-4520)"
else
  bad_t "C1c ...and the reason cell says to run \`task merge\`, never \`task done\` (DIVE-4520)" "$_c1c"
fi
if [[ "$_c1c" == *"task merge ${_c1ident:=$(db "SELECT ident FROM tasks WHERE id=$c1;")}"* ]]; then
  ok_t "C1d ...naming THIS row, so the line is runnable as printed"
else
  bad_t "C1d ...naming THIS row, so the line is runnable as printed" "$_c1c"
fi

# --- C2: a diverged PR owes a LOOK from ops (DIVE-4326; `main` before). THIS IS
# THE DEFECT DIVE-4137 fixed: before it this row read `graded->merge:dev` and
# woke a maker with nothing to do.
DISP_ANSWER="hold:ops:graded-sha-is-not-the-head"
c2=$(mkrow "head moved since the grade")
grade_prose "$c2"
eq "C2a routed to ops, NOT to the maker 'dev' (the DIVE-4137 defect)" \
   "ops" "$(col "$c2" merge_owner)"
eq "C2b ...the board renders merge:ops" "graded->merge:ops" "$(board "$c2")"
eq "C2c ...and the reason is recorded, not just the owner" \
   "graded-sha-is-not-the-head" "$(col "$c2" merge_hold_reason)"

# --- C3: a CODEOWNERS PR renders merge:ops (the row's third acceptance case)
DISP_ANSWER="hold:ops:codeowners-path"
c3=$(mkrow "touches install.sh")
grade_prose "$c3"
eq "C3a a CODEOWNERS-covered diff renders merge:ops" "graded->merge:ops" "$(board "$c3")"
eq "C3b ...naming the path class as the reason" "codeowners-path" "$(col "$c3" merge_hold_reason)"

# --- C4: the ONE hold a maker alone can clear still reaches the maker.
DISP_ANSWER="hold:maker:conflicting-needs-rebase"
c4=$(mkrow "conflicting branch")
grade_prose "$c4"
eq "C4  a CONFLICTING branch is the one hold that names the MAKER" \
   "graded->merge:dev" "$(board "$c4")"

# --- C5: the OTHER verifier shape reaches the same recording.
DISP_ANSWER="hold:ops:merge-state-BLOCKED"
c5=$(mkrow "graded by --cmd, not by prose")
grade_cmd "$c5"
eq "C5  \`verify --cmd\` on a bound row records the disposition too" \
   "ops" "$(col "$c5" merge_owner)"

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

# --- C8: A ROW GRADED TWICE (DIVE-4512). THE ARM THIS SECTION WAS MISSING.
#
# Every arm above grades once, so `graded_by` and the current actor are the same
# seat and the skew cannot show. The default shape on this board grades TWICE: a
# temp grader session records the first PASS, the loop's own verifier then ACKs
# it. `graded_by` is COALESCE-frozen at the FIRST grader; `_task_merge_preflight`
# keys the rail on `graded_by == actor`. So if this stamp names the CURRENT actor,
# the board hands a "run `5dive task done`" instruction to a seat the rail refuses
# BY NAME — and `_merge_at_close_do` reprints that same refusal, leaving the row
# with no self-service exit. Measured on DIVE-4491 / 5dive-ai/5dive#963.
#
# THE ASSERTION IS BEHAVIOURAL, not a field comparison: the arm asks the SHIPPED
# standing predicate whether the seat the board just named can actually run the
# rail. A stamp that names the wrong seat cannot pass it.
DISP_ANSWER="merge"
c9=$(mkrow "graded by a temp session, then ACKed by the loop verifier")
HARNESS_ACTOR=main2 grade_prose "$c9"      # first grade — a DIFFERENT seat
eq "C8a the first grader is frozen into graded_by" "main2" "$(col "$c9" graded_by)"
eq "C8b ...and owns the merge after one grade"     "main2" "$(col "$c9" merge_owner)"
grade_prose "$c9"                          # second grade — quinn, the loop's ACK
eq "C8c a re-grade does NOT repaint graded_by (provenance is frozen)"    "main2" "$(col "$c9" graded_by)"
eq "C8d ...so the merge owner must STAY the seat the rail accepts, not the ACKer"    "main2" "$(col "$c9" merge_owner)"
eq "C8e ...and the board renders it" "graded->merge:main2" "$(board "$c9")"
# The behavioural half: the seat the board named holds standing over the SHIPPED
# predicate, and the seat a bare `task_actor ""` would have named does not.
_c9id=$(db "SELECT ident FROM tasks WHERE id=${c9};")
_stands() { db "SELECT COUNT(*) FROM tasks WHERE ident=$(sqlq "$_c9id") AND $(_task_merge_standing_sql "$1");"; }
eq "C8f the seat the board names can actually run the rail" "1" "$(_stands "$(col "$c9" merge_owner)")"
eq "C8g negative control: the ACKing seat holds no standing (the refusal DIVE-4512 measured)" \
   "0" "$(_stands quinn)"

# --- C8h: THE FALLBACK IS NOT DEAD CODE, so it gets a fixture rather than a
# comment. A row whose `graded_by` is present but EMPTY has no frozen grader to
# read; without the fallback that empty read falls through to the UPDATE's own
# `${_md_owner:-main}` default and silently routes the row to `main` — a seat that
# never graded it and that the rail refuses just as firmly. It must degrade to the
# pre-DIVE-4512 behaviour (the grading seat) instead.
DISP_ANSWER="merge"
c10=$(mkrow "no frozen grader to read")
db "UPDATE tasks SET graded_by='' WHERE id=${c10};"
grade_prose "$c10"
eq "C8h an EMPTY graded_by falls back to the grading seat, never to 'main'" \
   "quinn" "$(col "$c10" merge_owner)"

# ===================================================================
# C9. DIVE-4520 — `task done` ON A MERGE-PENDING ROW REFUSES INSTEAD OF
#     RE-DELIVERING.
#
# The other half of the same defect. Section C1c above stops the BOARD printing
# the destructive verb; these arms make the verb itself safe, because a hint we
# do not compose (an older board line, a quoted screenshot, a person) can still
# point at it — and text-only enforcement is a proven repeat-defect class here
# (DIVE-4440). The rule was already written down on the wiki before this row
# existed and it did not stop the tap that measured it.
#
# THE HARM, measured on DIVE-4491 / 5dive-ai/5dive#963: on a loop row `task done`
# is not a close. It takes the maker->verifier routing fork and re-delivers, which
# stamps handoff_delivered_at=now. `_TASKS_TFV_SQL`'s DIVE-4357 conjunct then
# reads a delivery clock later than every verdict clock as "a delivery the grade
# did not grade", and `_task_merge_preflight` refuses the seat `graded_by` names —
# the ONE seat the rail accepts. Exit 0, nothing red, strictly worse than before.
#
# THE ASSERTION IS BEHAVIOURAL AND IT IS THE SAME QUESTION SECTION C8 ASKS: not
# "did a refusal print" but "does the seat the board named still hold standing
# under the SHIPPED predicate afterwards". A refusal that printed while the row
# was written anyway would pass a message-only arm.
#
# THE NEGATIVE CONTROL IS IN-POPULATION AND THERE ARE TWO of them, because this
# guard can fail in both directions:
#   * C9g — the ACKing seat (quinn) holds no standing before OR after. A guard
#     that "preserved standing" by widening the rail would pass every other arm.
#   * C9h/C9i — a row with a LIVE reject is NOT merge-pending, and its `task done`
#     MUST still re-deliver. A guard that refused every `task done` on a bound row
#     would strand exactly the rework this rail exists to carry.
# ===================================================================
DISP_ANSWER="merge"
_stands_on() { # <row id> <seat> -> 1 when the SHIPPED rail would accept that seat
  db "SELECT COUNT(*) FROM tasks WHERE id=$1 AND $(_task_merge_standing_sql "$2");"
}

# The DIVE-4491 shape exactly: graded by a temp session (main2), the loop's own
# verifier (quinn) still on the row, and the row assigned to a THIRD state — the
# maker's seat — so `verifier != assignee` and the close takes the routing fork.
c11=$(mkrow "graded, bound, and waiting on a merge")
db "UPDATE tasks SET assignee='dev' WHERE id=${c11};"
HARNESS_ACTOR=main2 grade_prose "$c11"
# The delivery clock is stamped BEHIND the verdict clock, which is what makes the
# row merge-pending rather than delivered-and-ungraded.
#
# AND THE VERDICT CLOCK IS PUSHED BACK TOO, deliberately, because without it the
# arms below cannot fail. Both clocks are datetime('now') at ONE-SECOND resolution
# (the tie DIVE-2624 measured on this very column pair): a re-delivery landing in
# the same second as the grade leaves the standing conjunct tied and TRUE, so an
# unguarded `task done` would still read as standing-intact and C9f would pass
# against the defect. Thirty minutes of separation is what makes "the delivery
# clock overtook the verdict clock" observable at all.
db "UPDATE tasks SET handoff_delivered_at=datetime('now','-1 hour'),
       graded_verdict_at=datetime('now','-30 minutes'), assignee='dev' WHERE id=${c11};"
_c11ident=$(db "SELECT ident FROM tasks WHERE id=${c11};")
eq "C9a the fixture IS merge-pending (the state the board paints graded->merge)" \
   "1" "$(db "SELECT COUNT(*) FROM tasks WHERE id=${c11} AND ${_TASKS_TFV_SQL};")"
eq "C9b ...and the grading seat holds standing BEFORE the tap" "1" "$(_stands_on "$c11" main2)"
_c11_before=$(col "$c11" handoff_delivered_at)
_c11_iter_before=$(col "$c11" iteration)
_c11_out=$( set +e; cmd_task_done "$_c11ident" --result="re-asserting the pass. CHANGED: src/x.sh CHECKED: bash tests/x.sh 3/3 pass DELIVERED-SHA: 1f2e3d4c5b6a79880123456789abcdef01234567 CI: green CRITERIA: (1) -> the run above" 2>&1 ); _c11_rc=$?
if (( _c11_rc != 0 )); then
  ok_t "C9c \`task done\` on a merge-pending row REFUSES (rc=$_c11_rc, not the exit-0 no-op)"
else
  bad_t "C9c \`task done\` on a merge-pending row REFUSES" "rc=0; output: $_c11_out"
fi
eq "C9d ...and handoff_delivered_at did NOT move (nothing was written)" \
   "$_c11_before" "$(col "$c11" handoff_delivered_at)"
eq "C9e ...nor did the iteration counter" "$_c11_iter_before" "$(col "$c11" iteration)"
eq "C9f ...so the grading seat STILL holds standing under the shipped predicate" \
   "1" "$(_stands_on "$c11" main2)"
eq "C9g NEGATIVE CONTROL: the ACKing seat holds none before or after (the rail was not widened)" \
   "0" "$(_stands_on "$c11" quinn)"
if [[ "$_c11_out" == *"task merge ${_c11ident}"* ]]; then
  ok_t "C9h ...and the refusal names the verb that works, on this row"
else
  bad_t "C9h ...and the refusal names the verb that works, on this row" "$_c11_out"
fi
if [[ "$_c11_out" == *main2* ]]; then
  ok_t "C9i ...and the seat that can run it, read from graded_by"
else
  bad_t "C9i ...and the seat that can run it, read from graded_by" "$_c11_out"
fi

# --- C9q-C9t (DIVE-4520 iteration 2): THE ALREADY-MERGED BRANCH, which is the
# one the fleet's own instructions send people to.
#
# `_TASKS_TFV_SQL` HAS NO NOTION OF MERGE STATE and this guard adds no probe —
# DIVE-4137 wants the close path probe-free, and a GitHub read that failed open
# would make the refusal non-deterministic. The consequence, measured by main2 on
# iteration 1: the fixture below is BYTE-IDENTICAL in the store to a row whose
# pull request landed ten minutes ago, so the guard fires on both and cannot tell
# them apart. That is a decision, not an oversight — and it is exactly why the
# TEXT has to carry the case the predicate cannot see. On a landed pull request
# the hand-off to the verifier IS the unchanged re-delivery `--force-redeliver`
# exists for (the standing it spends is already spent), and `task assign` reaches
# the same end with no delivery clock at all. Naming neither is what made the
# refusal un-followable where `cmd_heartbeat.sh`'s wake dispatch sends the merge
# owner.
#
# The mutant these exist for is deleting the already-merged clause from the
# refusal; it reds C9q, C9r and C9s and nothing else.
if [[ "$_c11_out" == *"ALREADY MERGED"* ]]; then
  ok_t "C9q ...and the refusal ADDRESSES the case the predicate cannot see (already merged)"
else
  bad_t "C9q ...and the refusal ADDRESSES the case the predicate cannot see (already merged)" "$_c11_out"
fi
if [[ "$_c11_out" == *"task assign ${_c11ident} quinn"* ]]; then
  ok_t "C9r ...naming the escape that applies there, on THIS row and its own verifier"
else
  bad_t "C9r ...naming the escape that applies there, on THIS row and its own verifier" "$_c11_out"
fi
# C9s is keyed on the REASON the audited escape applies there, not on the flag's
# name — the flag is named a sentence earlier for the unmerged case, so a grep for
# it alone survives the clause-deletion mutant and would be decoration.
if [[ "$_c11_out" == *"already spent"* ]]; then
  ok_t "C9s ...and says WHY the audited escape applies there (the standing is already spent)"
else
  bad_t "C9s ...and says WHY the audited escape applies there (the standing is already spent)" "$_c11_out"
fi
# C9t-C9w: AND THE ESCAPE IS NOT DECORATION — GRADED BY RUNNING IT.
#
# Iteration 2 asserted this branch by WRITING the end state by hand
# (`UPDATE tasks SET assignee='quinn'`) and checking the consequences. quinn
# bounced that at iteration 2 and was right: `grep -c cmd_task_assign` over this
# suite returned 0, so the arms certified what the refusal SAYS and never once
# ran the verb it names. `cmd_task_assign` refused it — DIVE-3097's guard fired
# on `assignee != verifier`, which is the precondition of the fork the refusal is
# printed on, so the advice could not be followed on any row that ever saw it.
# DIVE-4520 narrows that guard to the column its own comment means
# (`handoff_delivered_at IS NULL`). These arms drive the SHIPPED verb.
#
# `_task_require_lane` is stubbed for these calls and nothing else: it reads the
# agent registry, this board is a temp fixture with a two-agent roster, and lane
# registration is not what is under test here. The guard under test sits below
# it.
assign_run() { # assign_run <ident> <seat> -> runs the shipped verb, lane check stubbed
  ( set +e; _task_require_lane() { return 0; }; cmd_task_assign "$1" "$2" 2>&1 )
}
_c11_assign_before=$(col "$c11" handoff_delivered_at)
_c11_assign_out=$(assign_run "$_c11ident" quinn); _c11_assign_rc=$?
if (( _c11_assign_rc == 0 )); then
  ok_t "C9t the escape the refusal prints RUNS on the row it is printed on"
else
  bad_t "C9t the escape the refusal prints RUNS on the row it is printed on" \
        "rc=$_c11_assign_rc; output: $_c11_assign_out"
fi
eq "C9u ...moving the row off the guarded fork (verifier == assignee)" \
   "quinn|quinn" "$(col "$c11" verifier)|$(col "$c11" assignee)"
eq "C9v ...without stamping a delivery clock" \
   "$_c11_assign_before" "$(col "$c11" handoff_delivered_at)"
eq "C9w ...so the grading seat still holds standing for the merge" \
   "1" "$(_stands_on "$c11" main2)"
db "UPDATE tasks SET assignee='dev' WHERE id=${c11};"     # restore, the row is not reused but say so

# C9x: THE IN-POPULATION POSITIVE CONTROL for C9t. The same verb, same row, a
# seat that is NOT the verifier — the shape DIVE-3097 never refused. If C9t went
# green because the verb became a no-op rather than because the guard stopped
# firing, this arm is unchanged and C9t's move is the difference.
_c11_pc_out=$(assign_run "$_c11ident" ops); _c11_pc_rc=$?
eq "C9x POSITIVE CONTROL: the same verb to a NON-verifier seat runs too (rc 0, moved)" \
   "0|ops" "${_c11_pc_rc}|$(col "$c11" assignee)"
db "UPDATE tasks SET assignee='dev' WHERE id=${c11};"

# C9y: THE NEGATIVE CONTROL THE NARROWING MUST NOT EAT. DIVE-2899's shape is a
# row that has NEVER been delivered (handoff_delivered_at NULL) being reassigned
# straight onto its own verifier — that manufactures a maker who is also the
# grader with no handoff ever recorded, and it must still be refused. Identical
# to the C9 fixture in every column the guard reads EXCEPT the delivery clock.
# A mutant that drops the narrowing conjunct reds C9t/C9u/C9w/C9x; a mutant that
# deletes the guard outright reds this one.
c11f=$(mkrow "never delivered, being pointed at its own verifier")
db "UPDATE tasks SET assignee='dev', handoff_delivered_at=NULL WHERE id=${c11f};"
_c11f_ident=$(db "SELECT ident FROM tasks WHERE id=${c11f};")
_c11f_out=$(assign_run "$_c11f_ident" quinn); _c11f_rc=$?
eq "C9y NEGATIVE CONTROL: the never-delivered row is STILL refused onto its own verifier" \
   "3|dev" "${_c11f_rc}|$(col "$c11f" assignee)"
if [[ "$_c11f_out" == *"a maker can't grade itself"* ]]; then
  ok_t "C9z ...by DIVE-3097's own refusal, not by an unrelated failure"
else
  bad_t "C9z ...by DIVE-3097's own refusal, not by an unrelated failure" "$_c11f_out"
fi

# --- C9j: THE IN-POPULATION NEGATIVE CONTROL. A row carrying a LIVE reject is
# NOT merge-pending — the maker owes a fix and `task done` is exactly the verb
# that delivers it. Identical fixture, one column different.
c12=$(mkrow "bounced back, maker re-delivering")
db "UPDATE tasks SET assignee='dev' WHERE id=${c12};"
HARNESS_ACTOR=main2 grade_prose "$c12"
db "UPDATE tasks SET handoff_delivered_at=datetime('now','-1 hour'),
       handoff_rejected_at=datetime('now'), assignee='dev' WHERE id=${c12};"
_c12ident=$(db "SELECT ident FROM tasks WHERE id=${c12};")
eq "C9j the reject makes the row NOT merge-pending" \
   "0" "$(db "SELECT COUNT(*) FROM tasks WHERE id=${c12} AND ${_TASKS_TFV_SQL};")"
_c12_before=$(col "$c12" handoff_delivered_at)
_c12_out=$( set +e; cmd_task_done "$_c12ident" --result="FIX: addressed the finding. CHANGED: src/x.sh CHECKED: bash tests/x.sh 3/3 pass DELIVERED-SHA: 1f2e3d4c5b6a79880123456789abcdef01234567 CI: green CRITERIA: (1) -> the run above" 2>&1 ); _c12_rc=$?
if (( _c12_rc == 0 )); then
  ok_t "C9k ...so its \`task done\` still DELIVERS (rc=0) — the guard did not widen"
else
  bad_t "C9k ...so its \`task done\` still DELIVERS (rc=0) — the guard did not widen" "rc=$_c12_rc; $_c12_out"
fi
if [[ "$(col "$c12" handoff_delivered_at)" != "$_c12_before" ]]; then
  ok_t "C9l ...and the delivery clock DID move, which is what a real delivery does"
else
  bad_t "C9l ...and the delivery clock DID move" "still $_c12_before"
fi

# --- C9m: the audited escape. `--force-redeliver=<why>` (DIVE-4144) already means
# "this unchanged re-delivery is correct"; reusing it keeps ONE sentence for one
# meaning. A refusal with no escape is a stall wearing a different hat.
c13=$(mkrow "escape hatch")
db "UPDATE tasks SET assignee='dev' WHERE id=${c13};"
HARNESS_ACTOR=main2 grade_prose "$c13"
db "UPDATE tasks SET handoff_delivered_at=datetime('now','-1 hour'),
       graded_verdict_at=datetime('now','-30 minutes'), assignee='dev' WHERE id=${c13};"
_c13ident=$(db "SELECT ident FROM tasks WHERE id=${c13};")
_c13_out=$( set +e; cmd_task_done "$_c13ident" --result="restoring a lost handoff. CHANGED: src/x.sh CHECKED: bash tests/x.sh 3/3 pass DELIVERED-SHA: 1f2e3d4c5b6a79880123456789abcdef01234567 CI: green CRITERIA: (1) -> the run above" \
              --force-redeliver="the handoff record was lost; the pass is unchanged" 2>&1 ); _c13_rc=$?
if (( _c13_rc == 0 )); then
  ok_t "C9m --force-redeliver proceeds (rc=0), so the refusal is recoverable"
else
  bad_t "C9m --force-redeliver proceeds (rc=0)" "rc=$_c13_rc; $_c13_out"
fi
# The cost is asserted as the WARNING, not as a standing flip. Both clocks are
# datetime('now') at ONE-SECOND resolution, so a forced re-delivery inside the same
# second as the grade leaves the standing conjunct tied and true — the tie
# DIVE-2624 measured on this very column pair. An arm that asserted standing was
# lost would pass only on a slow box and is exactly the shape that reds in CI and
# not on a desk. What is deterministic, and what the escape owes its caller, is
# that it SAYS what it is spending.
_c13_seen=0
[[ "$_c13_out" == *"--force-redeliver"* && "$_c13_out" == *"merge standing"* && "$_c13_out" == *main2* ]] && _c13_seen=1
eq "C9n ...and the cost is stated rather than silent (the warning names the seat that loses standing)" \
   "1" "$_c13_seen"
# C9n2 (DIVE-4520 iteration 2): AND IT IS STATED AS A CONDITION, not as a fact.
# The escape's whole point is that an unchanged re-delivery is sometimes right —
# and the case where it is MOST right is a pull request that has already merged,
# where there is no merge left to hold standing for. A warn that asserts the loss
# flatly argues against the escape exactly there, which is what iteration 1
# shipped. The mutant is the revert to the flat sentence; it reds here only.
_c13_cond=0
[[ "$_c13_out" == *"has NOT merged yet"* && "$_c13_out" == *"already merged"* ]] && _c13_cond=1
eq "C9n2 ...and the cost is CONDITIONAL on the pull request not having landed" \
   "1" "$_c13_cond"
eq "C9o ...and the forced re-delivery really did happen (the row is back with the verifier)" \
   "quinn" "$(col "$c13" assignee)"
# ...and the warning was not decoration: with the verdict clock 30 minutes back,
# the new delivery clock really does overtake it, so the standing the escape spent
# is measurably gone. This is the harm the refusal above prevents, exercised once
# on purpose so the suite holds a witness of it rather than only a description.
eq "C9p ...and the spent cost is REAL: the grading seat no longer holds standing" \
   "0" "$(_stands_on "$c13" main2)"

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
# DIVE-4428 iteration 2 moved the run-record-reread body out of the close and into
# `_merge_at_close_do`, so the harness could EXECUTE its branches instead of
# grepping them (a mutant that disabled the enqueue arm passed every source-level
# arm). The property here is unchanged and still worth pinning at source: the
# close must DELEGATE, and the thing it delegates to must RE-READ.
_hookfn=$(sed -n '/^_merge_at_close_do() {/,/^}/p' "$SRC/task/status.sh")
if grep -q '_merge_at_close_do "\$ident"' <<<"$_hook" \
   && grep -q '_gate_pr_state "\$_dref"' <<<"$_hookfn"; then
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

# ===================================================================
# F. DIVE-4326 — WHO THE HOLD IS RESOLVED TO.
#
# The defect, measured 2026-09-11: `main` was a CONSTANT in every hold branch, so
# `merge_owner` read `main` on every graded-and-waiting row and the heartbeat's
# DIVE-4206 rule made those rows dispatchable to main ALONE. The want is ops by
# default, main only where ops cannot reach — and, critically, a seat the
# heartbeat will actually wake, or the row is dispatchable to NOBODY (DIVE-4220).
#
# THE NON-VACUITY ARM IS F2/F5: with ops disabled or the repo outside ops's
# credential, the SAME input must resolve to `main`. Without those two, every arm
# here would pass against a function that returned the constant `ops` — the
# original defect with a different constant in it.
# ===================================================================

eq "F1  an in-org repo resolves to ops (the default this row installs)" \
   "ops" "$(_merge_hold_seat 5dive-ai/5dive)"
eq "F1b ...for the api repo too" "ops" "$(_merge_hold_seat lodar/5dive-api)"

eq "F2  a repo OUTSIDE ops's credential falls back to main" \
   "main" "$(_merge_hold_seat someone-else/their-repo)"

eq "F3  an UNRESOLVED slug is not evidence ops cannot read it -> still ops" \
   "ops" "$(_merge_hold_seat '')"

# F4/F5 — the roster half. A seat the heartbeat will not wake is not an owner.
roster false
eq "F4  ops present but heartbeat DISABLED -> main, not a dead row" \
   "main" "$(_merge_hold_seat 5dive-ai/5dive)"
printf '{"agents":{"main":{"heartbeat":{"enabled":true}}}}\n' >"$ROSTER"
eq "F5  ops ABSENT from the roster entirely -> main" \
   "main" "$(_merge_hold_seat 5dive-ai/5dive)"
roster true
eq "F5b ...and it goes back to ops once the roster says so (the arm is live)" \
   "ops" "$(_merge_hold_seat 5dive-ai/5dive)"

# F6 — FAIL OPEN on an unreadable roster, deliberately. Re-pinning every merge
# onto main when a file cannot be read is the constant this row removes,
# reintroduced as a failure mode; a wrong yes costs one bounce.
chmod 000 "$ROSTER"
if [[ -r "$ROSTER" ]]; then
  ok_t "F6  SKIPPED (running as a user that can read a 000 file) — no claim made"
else
  eq "F6  an unreadable roster still resolves to ops (fail open, not to main)" \
     "ops" "$(_merge_hold_seat 5dive-ai/5dive)"
fi
chmod 600 "$ROSTER"; roster true

# F7 — the ROLE boundary. The pure decider must never name a seat, and the
# resolver must leave everything that is not the `merger` role alone.
eq "F7a the pure decider emits a ROLE, never a seat" \
   "hold:merger:merge-state-BLOCKED" "$(_merge_disp_decide MERGEABLE BLOCKED "$SHA40" "$SHA40" low)"
eq "F7b the resolver turns that role into a seat" \
   "hold:ops:merge-state-BLOCKED" "$(_merge_hold_resolve hold:merger:merge-state-BLOCKED 5dive-ai/5dive)"
eq "F7c ...and leaves the MAKER role untouched (it is resolved from the row, not the repo)" \
   "hold:maker:conflicting-needs-rebase" "$(_merge_hold_resolve hold:maker:conflicting-needs-rebase 5dive-ai/5dive)"
eq "F7d ...and passes a plain merge straight through" \
   "merge" "$(_merge_hold_resolve merge 5dive-ai/5dive)"
if grep -qE "printf 'hold:main" "$SRC/task/delivery.sh"; then
  bad_t "F7e no seat constant survives in the disposition branches" \
        "a hold branch still prints the literal 'main' instead of the merger role"
else
  ok_t "F7e no seat constant survives in the disposition branches"
fi

# F8 — END TO END through the recording, which is what the board reads. The probe
# is the real one here; only the gh read is stubbed, so this grades the whole
# chain decide -> resolve -> loops.sh -> merge_owner.
# Section C unset them (line "unset -f _gate_gh _gate_gh_token"); restore the
# section-E stubs so the READ is fixtured and everything above it is shipped code.
_gate_gh_token() { printf 'fixture-token'; }
_gate_gh() { [[ -n "$GH_RAW" ]] && printf '%s' "$GH_RAW"; return "$GH_RC"; }
GH_RAW=$(rec MERGEABLE CLEAN 0123456789abcdef0123456789abcdef01234567 "$PRURL" src/task/loops.sh)
GH_RC=0
eq "F8  the live probe resolves an in-org hold to ops" \
   "hold:ops:graded-sha-is-not-the-head" "$(_merge_disp_probe_real "$PRURL" "$SHA40")"
roster false
eq "F8b ...and to main when ops is not wakeable (same input, same read)" \
   "hold:main:graded-sha-is-not-the-head" "$(_merge_disp_probe_real "$PRURL" "$SHA40")"
roster true

# F9 — loops.sh's own net for the ONE disposition the probe cannot resolve
# itself: its own failure. The role must not reach the board as the word
# `merger`, which is not a seat and would dispatch to nobody.
DISP_ANSWER="hold:merger:disposition-probe-failed"
f2=$(mkrow "the probe itself fell over")
grade_prose "$f2"
eq "F9  a bare \`merger\` role is resolved to a seat before it is recorded" \
   "ops" "$(col "$f2" merge_owner)"
eq "F9b ...and the reason survives intact" \
   "disposition-probe-failed" "$(col "$f2" merge_hold_reason)"


# ===================================================================
# G. DIVE-4337 — THE MERGE QUEUE, WHICH IS THE ONE DISPOSITION INPUT THE
#    PULL REQUEST DOES NOT REPORT.
#
# Folded into THIS file rather than given its own (CLAUDE.md's first way out of
# the core budget: merge by subject). The subject is the same one — what the
# board should tell a merge owner about a graded pull request — and the setup
# above is already paid for. The core tier was 310s against a 300s cap in the
# 18:40-19:01Z cycle of 2026-09-11, so a new file here would have been a new
# harness added to a tier that was at that moment ejecting graded passes.
#
# THE DEFECT: after the queue evicts a PR, `state`, `merged`, `mergeable` and
# `mergeStateStatus` all read exactly as they do for a PR nobody ever pressed.
# `_gate_mq_classify` is PURE over the six-field projection, so every one of the
# three states — and the NOT-MEASURED non-state — is gradable here with no
# network at all, which is the only way the ejected arm is ever gradable: it is
# the branch that does not fire when things are healthy.
#
# Mutants driven by hand against the shipped functions (5dive rule: evidence is
# killed mutants, not arm counts):
#   M9   `printf UNKNOWN|queue-state-unreadable` -> `printf NEVER` on the
#        field-count guard                                 killed 3 arms (G8, G9, G12)
#   M10  membership test `[[ $inq == 1 || -n $pos ]]` -> `[[ -n $pos ]]`
#                                                          killed 1 arm  (G2)
#   M11  the add-vs-removal comparison deleted (any removal reads EJECTED)
#                                                          killed 1 arm  (G5)
#   M12  `_gate_mq_note` UNKNOWN arm -> the NEVER wording   killed 1 arm  (G16)
#   M13  the whole reason `case` reverted to the order-only removal arm this
#        iteration replaced (any trailing removal reads EJECTED)
#                        killed 7 arms (G4, G21, G22, G24, G25, G26, G27)
#   M14  the unrecognised-reason case -> EJECTED   killed 3 arms (G4, G25, G26)
#   M15  `_gate_mq_note`'s MERGED arm reworded with the EJECTED sentence
#                                                          killed 1 arm  (G22)
# M9 and M12 are the polarity this section exists to protect, in the two places
# it can be lost: an unreadable read must never classify as, or READ as, "nobody
# pressed merge" (DIVE-2318 — an unreached question printed as a measured no).
# ===================================================================
US=$'\x1f'
mq() { # mq <inQueue> <position> <entryState> <addedAt> <removedAt> <reason>
  printf '%s%s%s%s%s%s%s%s%s%s%s' "$1" "$US" "$2" "$US" "$3" "$US" "$4" "$US" "$5" "$US" "$6"
}
T1=2026-09-11T18:15:27Z
T2=2026-09-11T19:00:56Z

# --- the three world states, which is the whole ticket ---
eq "G1  a live entry                     -> QUEUED at its position" \
   "QUEUED|1|AWAITING_CHECKS" "$(_gate_mq_classify "$(mq 1 1 AWAITING_CHECKS "$T1" '' '')")"
eq "G2  isInMergeQueue true, entry unreadable under this scope -> still QUEUED" \
   "QUEUED|?|state-unread" "$(_gate_mq_classify "$(mq 1 '' '' "$T1" '' '')")"
eq "G3  added, then REMOVED for failed_checks, no entry -> EJECTED, time and reason" \
   "EJECTED|$T2|failed_checks" \
   "$(_gate_mq_classify "$(mq 0 '' '' "$T1" "$T2" 'failed_checks')")"
eq "G4  ...and a removal GitHub stated NO reason for is NOT an ejection — UNKNOWN" \
   "UNKNOWN|removal-reason-unrecognised" \
   "$(_gate_mq_classify "$(mq 0 '' '' "$T1" "$T2" '')")"
eq "G5  RE-ENQUEUED after an eviction (add is LATER than the removal) -> not ejected" \
   "ENQUEUED|2026-09-11T19:05:00Z" \
   "$(_gate_mq_classify "$(mq 0 '' '' 2026-09-11T19:05:00Z "$T2" 'failed_checks')")"
eq "G6  no add event has ever existed    -> NEVER ENQUEUED" \
   "NEVER" "$(_gate_mq_classify "$(mq 0 '' '' '' '' '')")"
eq "G7  a removal with no add at all (history truncated) -> still EJECTED, not NEVER" \
   "EJECTED|$T2|failed_checks" "$(_gate_mq_classify "$(mq 0 '' '' '' "$T2" 'failed_checks')")"

# --- THE POLARITY. An unreached question is never a measured no. ---
eq "G8  EMPTY payload                    -> UNKNOWN, never NEVER" \
   "UNKNOWN|queue-state-unreadable" "$(_gate_mq_classify "")"
eq "G9  a GraphQL error envelope (too few fields) -> UNKNOWN" \
   "UNKNOWN|queue-state-unreadable" "$(_gate_mq_classify "0${US}${US}")"

# --- the impure leaf's guards, all reachable with no network ---
eq "G10 a delivery_ref that names no PR number -> UNKNOWN, no read attempted" \
   "UNKNOWN|pr-number-unreadable" "$(_gate_pr_queue_state "https://example.com/x" "" "o/r")"
eq "G11 an unresolved repo slug                -> UNKNOWN, no read attempted" \
   "UNKNOWN|repo-unresolved" "$(_gate_pr_queue_state "https://github.com/o/r/pull/897" "" "notaslug")"
GH_RAW=""; GH_RC=1
_gate_gh() { [[ -n "$GH_RAW" ]] && printf '%s' "$GH_RAW"; return "$GH_RC"; }
eq "G12 the ONE gh read fails             -> UNKNOWN (the read is the only input)" \
   "UNKNOWN|queue-state-unreadable" \
   "$(_gate_pr_queue_state "https://github.com/o/r/pull/897" tok "o/r")"
GH_RAW="$(mq 0 '' '' "$T1" "$T2" 'failed_checks')"; GH_RC=0
eq "G13 the read ANSWERS with an eviction -> EJECTED, through the live leaf" \
   "EJECTED|$T2|failed_checks" \
   "$(_gate_pr_queue_state "https://github.com/o/r/pull/897" tok "o/r")"
eq "G14 a bare PR number resolves the same way" \
   "EJECTED|$T2|failed_checks" "$(_gate_pr_queue_state "897" tok "o/r")"

# --- the WORDING, because both call sites (the DIVE-1830 close refusal and
#     `task show`'s merge_queue line) render through this one function, and a
#     NOT-MEASURED that reads like a NEVER is the defect with a new coat. ---
case "$(_gate_mq_note "$(_gate_mq_classify "$(mq 0 '' '' "$T1" "$T2" 'failed_checks')")")" in
  *EJECTED*"$T2"*failed_checks*) ok_t "G15 the ejected note names WHEN and WHY" ;;
  *) bad_t "G15 the ejected note names WHEN and WHY" "got: $(_gate_mq_note "EJECTED|$T2|failed_checks")" ;;
esac
_g16=$(_gate_mq_note "UNKNOWN|queue-state-unreadable")
if [[ "$_g16" == *"NOT MEASURED"* && "$_g16" != *"NEVER ENQUEUED"* ]]; then
  ok_t "G16 an unreadable queue reads as NOT MEASURED and NEVER as never-enqueued"
else
  bad_t "G16 an unreadable queue reads as NOT MEASURED and NEVER as never-enqueued" "got: $_g16"
fi
case "$(_gate_mq_note "QUEUED|1|AWAITING_CHECKS")" in
  *"position 1"*) ok_t "G17 the queued note names the position" ;;
  *) bad_t "G17 the queued note names the position" "got: $(_gate_mq_note "QUEUED|1|AWAITING_CHECKS")" ;;
esac

# --- WIRED, asserted against the shipped source. Both call sites are inside
#     branches that need a live pull request, so their PLACEMENT is what a unit
#     harness can grade — the same move section D makes for the merge itself. ---
if grep -q '_gate_mq_note "$(_gate_pr_queue_state' "$SRC/task/status.sh"; then
  ok_t "G18 the DIVE-1830 close refusal reads the queue state"
else
  bad_t "G18 the DIVE-1830 close refusal reads the queue state" "no call in src/task/status.sh"
fi
if grep -q 'merge_queue = ' "$SRC/task/crud.sh"; then
  ok_t "G19 \`task show\` carries a merge_queue line beside graded->merge"
else
  bad_t "G19 \`task show\` carries a merge_queue line beside graded->merge" "no line in src/task/crud.sh"
fi
# The fence is part of the claim: an unconditional live read on the board's
# most-called verb is a cost nobody agreed to.
if grep -q 'FIVE_TASK_SHOW_QUEUE' "$SRC/task/crud.sh"; then
  ok_t "G20 ...and that read is fenced and switchable off"
else
  bad_t "G20 ...and that read is fenced and switchable off" "no fence in src/task/crud.sh"
fi

# --- G21-G27  THE REASON, NOT THE ORDER (iteration 1, quinn's finding).
#     A SUCCESSFUL MERGE ALSO EMITS RemovedFromMergeQueueEvent — with
#     reason=merged. Deciding EJECTED on add-vs-removal ORDER therefore reported
#     the PR that LANDED as thrown out, and `task show`'s fence (merge_owner set
#     + row open + a pull URL, blind to PR state) reaches that window in
#     production: 24 minutes of merged-but-not-yet-closed on DIVE-4299.
#
#     The payloads below are the LIVE ones ops read off 5dive-ai/5dive on
#     2026-09-11, so these arms are the canned-payload harness's answer to the
#     one class of fixture it could not invent for itself. #897 carries one
#     removal of EACH kind, so the ejection arm and its inverse sit on the same
#     pull request.
#
#     LIVE CONTROL, run from this seat through the machine-account rail against
#     5dive-ai/5dive on 2026-09-11, so the payloads below are TRANSCRIBED and
#     not invented: #897 -> `0|||19:01:41Z|19:42:26Z|merged` and #894 — evicted
#     on a ONE-SECOND overage, re-enqueued, then landed ->
#     `0|||18:29:56Z|19:21:54Z|merged`. BOTH read EJECTED before this iteration.
#     #894's 19:00:56Z eviction has dropped off its own timeline, so the live
#     failed_checks fixture that survives is #897's earlier removal (G23).
#
#     Mutants for this arm are listed with the rest at the head of section G
#     (M13, M14, M15).
P897_MERGED="$(mq 0 '' '' 2026-09-11T19:01:41Z 2026-09-11T19:42:26Z merged)"
P897_EJECT="$(mq 0 '' '' 2026-09-11T18:15:27Z 2026-09-11T19:00:30Z failed_checks)"
P894_MERGED="$(mq 0 '' '' 2026-09-11T18:29:56Z 2026-09-11T19:21:54Z merged)"

GH_RAW="$P897_MERGED"; GH_RC=0
eq "G21 #897's real removal reason=merged -> MERGED, NOT ejected (through the leaf)" \
   "MERGED|2026-09-11T19:42:26Z" \
   "$(_gate_pr_queue_state "https://github.com/5dive-ai/5dive/pull/897" tok "5dive-ai/5dive")"
_g22=$(_gate_mq_note "$(_gate_pr_queue_state "https://github.com/5dive-ai/5dive/pull/897" tok "5dive-ai/5dive")")
if [[ "$_g22" == *"MERGED at 2026-09-11T19:42:26Z"* && "$_g22" == *"LANDED"* \
      && "$_g22" != *EJECTED* && "$_g22" != *unmerged* ]]; then
  ok_t "G22 ...and the note a merge owner reads says it landed, never ejected/unmerged"
else
  bad_t "G22 ...and the note a merge owner reads says it landed, never ejected/unmerged" "got: $_g22"
fi
GH_RAW="$P897_EJECT"; GH_RC=0
eq "G23 the SAME pull request's earlier removal, reason=failed_checks -> EJECTED" \
   "EJECTED|2026-09-11T19:00:30Z|failed_checks" \
   "$(_gate_pr_queue_state "https://github.com/5dive-ai/5dive/pull/897" tok "5dive-ai/5dive")"
GH_RAW="$P894_MERGED"; GH_RC=0
eq "G24 #894 — ejected on a 1s overage, re-enqueued, LANDED: its last removal is the merge" \
   "MERGED|2026-09-11T19:21:54Z" \
   "$(_gate_pr_queue_state "https://github.com/5dive-ai/5dive/pull/894" tok "5dive-ai/5dive")"
eq "G25 a reason outside the observed enum -> UNKNOWN, never an ejection" \
   "UNKNOWN|removal-reason-unrecognised" \
   "$(_gate_mq_classify "$(mq 0 '' '' "$T1" "$T2" 'dequeued_by_a_human')")"
_g26=$(_gate_mq_note "$(_gate_mq_classify "$(mq 0 '' '' "$T1" "$T2" 'dequeued_by_a_human')")")
if [[ "$_g26" == *"NOT MEASURED"* && "$_g26" != *EJECTED* && "$_g26" != *"NEVER ENQUEUED"* ]]; then
  ok_t "G26 ...and it RENDERS as NOT MEASURED — not an ejection and not a never-pressed"
else
  bad_t "G26 ...and it RENDERS as NOT MEASURED — not an ejection and not a never-pressed" "got: $_g26"
fi
eq "G27 the enum arrives upper-cased -> still MERGED, not 'unrecognised'" \
   "MERGED|$T2" "$(_gate_mq_classify "$(mq 0 '' '' "$T1" "$T2" 'MERGED')")"

printf '\n%s\n' "----------------------------------------------------------"
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
