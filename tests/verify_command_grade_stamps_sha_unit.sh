#!/usr/bin/env bash
# A COMMAND grade states the sha it graded, so the merge gate can clear.
#
# THE DEFECT. A row graded by a command (`--review=check`) recorded
# `✅ verify PASS (exit 0): <cmd>` and nothing else. `_gate_graded_sha` reads only
# a LABELLED `graded-sha:` declaration, so it read empty; `_merge_disp_decide`
# answered `hold:merger:no-graded-sha-stated` (DIVE-2656: a grade is bound to a
# sha, not to a pull request); and `task done` refuses a close whose result states
# no graded sha. A row that had just passed its own acceptance command could
# therefore be closed by nobody — only by an operator typing the sha in by hand or
# spending the audited `--no-graded-sha`. Measured on DIVE-544 / #994.
#
# The sha was never unknown: the command ran against the delivered head and the
# delivery record names it. Every arm below therefore grades WHERE THE SHA CAME
# FROM as well as that one arrived — a stamp from the wrong source is the failure
# this would otherwise trade for the first one.
#
#   bash tests/verify_command_grade_stamps_sha_unit.sh   (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/verify-grade-sha.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e; tasks_db_init >/dev/null 2>&1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { [[ "$1" == *"$2"* ]]; }

HEAD_SHA="a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"   # what gh reports as the PR head
DELV_SHA="0fedcba987654321fedcba9876543210fedcba98"   # what the maker stated at delivery
PR_URL="https://github.com/acme/widget/pull/994"

# --- The gh seam, stubbed: this harness grades the STAMP, not the transport ----
# GH_HEAD empty models "gh cannot read the pull request" (no credential, no
# network, a repo the token is blind to) — the case the fallback exists for.
GH_HEAD="$HEAD_SHA"
_gate_gh_token() { printf 'stub-token'; }
_gate_gh() {
  shift 2
  case "$*" in
    *'--json headRefOid -q .headRefOid'*) [[ -n "$GH_HEAD" ]] && printf '%s' "$GH_HEAD" ;;
    *) printf '' ; return 1 ;;   # the disposition probe's own multi-field read
  esac
  [[ -n "$GH_HEAD" ]]
}

# seed <id> <ident> <delivery_ref> <result>
seed() {
  db "DELETE FROM tasks WHERE id=$1;" >/dev/null 2>&1
  db "INSERT INTO tasks(id, ident, title, status, priority, assignee, created_by, created_at,
                        project_key, delivery_ref, verify_command, result)
      VALUES($1, '$2', 'seeded row', 'in_progress', 'high', 'maker', 'harness', datetime('now'),
             'dive', $(sqlq "$3"), 'true', $(sqlq "$4"));" >/dev/null 2>&1
}
result_of() { db "SELECT COALESCE(result,'') FROM tasks WHERE ident='$1';"; }
status_of() { db "SELECT COALESCE(status,'') FROM tasks WHERE ident='$1';"; }
# `fail` exits, so every run is a subshell.
run_verify() { ( cmd_task_verify "$@" ) >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?"; }

DELIVERY_RECORD="delivered by the maker
CHANGED: src/thing.sh — the fix
DELIVERED-SHA: ${DELV_SHA}
CI: green"

# --- 0) PRECONDITIONS: the arms below are not vacuous ------------------------
seed 601 DIVE-601 "$PR_URL" "$DELIVERY_RECORD"
[[ -z "$(_gate_graded_sha "$DELIVERY_RECORD")" ]] \
  && ok_t "precondition: the delivery record states NO graded-sha (DELIVERED-SHA is a different claim)" \
  || bad_t "precondition: the seeded record states no graded-sha" "it already does; every arm below would pass vacuously"
[[ "$(_merge_disp_decide MERGEABLE CLEAN "$HEAD_SHA" "" low)" == "hold:merger:no-graded-sha-stated" ]] \
  && ok_t "precondition: with no graded sha the disposition really is hold:merger:no-graded-sha-stated" \
  || bad_t "precondition: the gate holds without a graded sha" "got: $(_merge_disp_decide MERGEABLE CLEAN "$HEAD_SHA" "" low)"

# --- A) gh answers: the sha is the PR HEAD AT GRADE TIME ---------------------
GH_HEAD="$HEAD_SHA"
RC="$(run_verify DIVE-601)"
A_RES="$(result_of DIVE-601)"
[[ "$RC" == "0" ]] \
  && ok_t "A0: a passing command grade still exits 0" \
  || bad_t "A0: the grade exits 0" "rc=$RC err: $(head -2 "$TMP/err")"
has "$A_RES" "graded-sha: ${HEAD_SHA}" \
  && ok_t "A1: the recorded result states graded-sha: <the PR head>" \
  || bad_t "A1: the result states the graded sha" "result: ${A_RES:0:400}"
[[ "$(_gate_graded_sha "$A_RES")" == "$HEAD_SHA" ]] \
  && ok_t "A2: ... and the FENCE the gates read returns exactly that sha" \
  || bad_t "A2: _gate_graded_sha reads the stamp" "got '$(_gate_graded_sha "$A_RES")'"
has "$A_RES" "read with gh" \
  && ok_t "A3: ... and the line names where the sha came from" \
  || bad_t "A3: the stamp names its source" "result: ${A_RES:0:400}"
[[ "$(_merge_disp_decide MERGEABLE CLEAN "$HEAD_SHA" "$(_gate_graded_sha "$A_RES")" low)" == "merge" ]] \
  && ok_t "A4: the merge gate no longer holds at no-graded-sha-stated — it says merge" \
  || bad_t "A4: the gate clears" "got: $(_merge_disp_decide MERGEABLE CLEAN "$HEAD_SHA" "$(_gate_graded_sha "$A_RES")" low)"
[[ "$(status_of DIVE-601)" != "done" ]] \
  && ok_t "A5: the bound row still does NOT close itself (DIVE-3330 hold is unchanged)" \
  || bad_t "A5: the bound row stays open" "status=$(status_of DIVE-601)"

# --- B) gh cannot read it: fall back to the maker's DELIVERED-SHA ------------
seed 602 DIVE-602 "$PR_URL" "$DELIVERY_RECORD"
GH_HEAD=""
RC="$(run_verify DIVE-602)"
B_RES="$(result_of DIVE-602)"
[[ "$(_gate_graded_sha "$B_RES")" == "$DELV_SHA" ]] \
  && ok_t "B1: with gh unreadable the stamp is the DELIVERED-SHA the delivery stated" \
  || bad_t "B1: the DELIVERED-SHA fallback" "rc=$RC got '$(_gate_graded_sha "$B_RES")' from: ${B_RES:0:400}"
has "$B_RES" "DELIVERED-SHA stated in the delivery record" \
  && ok_t "B2: ... and says so, rather than passing it off as a gh read" \
  || bad_t "B2: the fallback names its source" "result: ${B_RES:0:400}"
[[ "$(_merge_disp_decide MERGEABLE CLEAN "$DELV_SHA" "$(_gate_graded_sha "$B_RES")" low)" == "merge" ]] \
  && ok_t "B3: ... and the gate clears at that sha too" \
  || bad_t "B3: the gate clears on the fallback" "got: $(_merge_disp_decide MERGEABLE CLEAN "$DELV_SHA" "$(_gate_graded_sha "$B_RES")" low)"

# --- C) Neither source: the hold STAYS, and becomes legible ------------------
seed 603 DIVE-603 "$PR_URL" "delivered with no sha field at all"
GH_HEAD=""
RC="$(run_verify DIVE-603)"
C_RES="$(result_of DIVE-603)"
has "$C_RES" "graded-sha: unreadable" \
  && ok_t "C1: with no source at all the result SAYS the sha is unreadable" \
  || bad_t "C1: the unreadable case is written down" "result: ${C_RES:0:400}"
[[ -z "$(_gate_graded_sha "$C_RES")" ]] \
  && ok_t "C2: ... and that line carries no hex, so the fence still reads EMPTY" \
  || bad_t "C2: the unreadable line must not satisfy the fence" "got '$(_gate_graded_sha "$C_RES")'"
[[ "$(_merge_disp_decide MERGEABLE CLEAN "$HEAD_SHA" "$(_gate_graded_sha "$C_RES")" low)" == "hold:merger:no-graded-sha-stated" ]] \
  && ok_t "C3: ... so the gate still HOLDS — this fix makes the hold legible, never lifts it" \
  || bad_t "C3: the hold survives an unreadable sha" "got: $(_merge_disp_decide MERGEABLE CLEAN "$HEAD_SHA" "$(_gate_graded_sha "$C_RES")" low)"

# --- D) A verifier who stated their own sha is not overwritten ---------------
seed 604 DIVE-604 "$PR_URL" "$DELIVERY_RECORD"
GH_HEAD="$HEAD_SHA"
RC="$(run_verify DIVE-604 --cmd=true --no-done --result="I read the diff. graded-sha: deadbee1234567")"
D_RES="$(result_of DIVE-604)"
[[ "$(_gate_graded_sha "$D_RES")" == "deadbee1234567" ]] \
  && ok_t "D1: a graded-sha the VERIFIER stated in prose wins — the stamp does not overwrite a claim" \
  || bad_t "D1: a stated claim is left alone" "rc=$RC got '$(_gate_graded_sha "$D_RES")'"
! has "$D_RES" "read with gh" \
  && ok_t "D2: ... and no second, machine-written line is added beside it" \
  || bad_t "D2: no stamp is added over a stated claim" "result: ${D_RES:0:400}"

# --- E) An UNBOUND row is untouched -----------------------------------------
db "DELETE FROM tasks WHERE id=605;" >/dev/null 2>&1
db "INSERT INTO tasks(id, ident, title, status, priority, assignee, created_by, created_at, project_key, verify_command)
    VALUES(605, 'DIVE-605', 'unbound row', 'in_progress', 'high', 'maker', 'harness', datetime('now'), 'dive', 'true');" \
  >/dev/null 2>&1
GH_HEAD="$HEAD_SHA"
RC="$(run_verify DIVE-605)"
E_RES="$(result_of DIVE-605)"
! has "$E_RES" "graded-sha" \
  && ok_t "E1: a row binding no delivery gets no stamp — there is no merge gate to answer" \
  || bad_t "E1: unbound rows are not stamped" "result: ${E_RES:0:300}"
[[ "$(status_of DIVE-605)" == "done" ]] \
  && ok_t "E2: ... and it still auto-closes, so a mutation that disabled every close cannot green this file" \
  || bad_t "E2: the unbound row still closes" "status=$(status_of DIVE-605) rc=$RC err: $(head -2 "$TMP/err")"

# --- F) A FAIL owes nobody a merge answer -----------------------------------
seed 606 DIVE-606 "$PR_URL" "$DELIVERY_RECORD"
GH_HEAD="$HEAD_SHA"
RC="$(run_verify DIVE-606 --cmd=false)"
F_RES="$(result_of DIVE-606)"
{ [[ "$RC" != "0" ]] && ! has "${F_RES#*"$DELIVERY_RECORD"}" "graded-sha"; } \
  && ok_t "F1: a FAILING grade stamps nothing — a fail owes the maker a fix, not anyone a merge" \
  || bad_t "F1: the FAIL branch is untouched" "rc=$RC result: ${F_RES:0:400}"

# =============================================================================
# MUTANT — take the stamp back out and the gate must hold again.
# =============================================================================
# BEFORE/AFTER on purpose: "the stamp is gone" is also true of a sed that matched
# nothing, which would make every arm below vacuous.
ORIG="$(declare -f cmd_task_verify)"
MUT="$(printf '%s\n' "$ORIG" | sed 's/^\([[:space:]]*\)if \[\[ -n "\$_vg_dref" \]\].*/\1if false; then/')"
has "$ORIG" '_verify_grade_sha_line' \
  && ok_t "M0a: BEFORE — the shipped verify really does reach the stamp" \
  || bad_t "M0a: the shipped verify stamps" "no stamp found; every mutant arm below is vacuous"
{ has "$MUT" 'if false; then' && ! has "$MUT" 'if [[ -n "$_vg_dref" ]]'; } \
  && ok_t "M0b: AFTER — the mutation really removed the guard's true branch (the sed matched)" \
  || bad_t "M0b: the mutation took" "the sed did not match; the mutant is not mutated"

eval "$MUT"
seed 607 DIVE-607 "$PR_URL" "$DELIVERY_RECORD"
GH_HEAD="$HEAD_SHA"
RC="$(run_verify DIVE-607)"
M_RES="$(result_of DIVE-607)"
[[ "$RC" == "0" && -z "$(_gate_graded_sha "$M_RES")" ]] \
  && ok_t "M1: MUTANT — the grade still PASSES and still states no sha (A1/A2 would be red on it)" \
  || bad_t "M1: mutant records no sha" "rc=$RC got '$(_gate_graded_sha "$M_RES")'"
[[ "$(_merge_disp_decide MERGEABLE CLEAN "$HEAD_SHA" "$(_gate_graded_sha "$M_RES")" low)" == "hold:merger:no-graded-sha-stated" ]] \
  && ok_t "M2: MUTANT — and the merge gate is back to no-graded-sha-stated (A4 would be red on it)" \
  || bad_t "M2: mutant holds the gate" "got: $(_merge_disp_decide MERGEABLE CLEAN "$HEAD_SHA" "$(_gate_graded_sha "$M_RES")" low)"

eval "$ORIG"
seed 608 DIVE-608 "$PR_URL" "$DELIVERY_RECORD"
RC="$(run_verify DIVE-608)"
[[ "$(_gate_graded_sha "$(result_of DIVE-608)")" == "$HEAD_SHA" ]] \
  && ok_t "M3: RESTORE took — the fixed verify is back and stamps again" \
  || bad_t "M3: restore took" "got '$(_gate_graded_sha "$(result_of DIVE-608)")' (later arms would grade the mutant)"

echo "-----"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
