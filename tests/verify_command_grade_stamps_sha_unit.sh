#!/usr/bin/env bash
# A COMMAND grade states the sha it graded — but only when it can PROVE it.
#
# THE DEFECT. A row graded by a command (`--review=check`) recorded
# `✅ verify PASS (exit 0): <cmd>` and nothing else. `_gate_graded_sha` reads only
# a LABELLED `graded-sha:` declaration, so it read empty; `_merge_disp_decide`
# answered `hold:merger:no-graded-sha-stated`; and `task done` refuses a close
# whose result states no graded sha. A row that had just passed its own acceptance
# command could therefore be closed by nobody.
#
# AND THE OBVIOUS FIX IS A WORSE DEFECT. `graded-sha` answers WHICH TREE THIS
# GRADE EXERCISED. "What was the pull request head while the command ran" is a
# different question: a grade of `git show origin/main:<file>` — run because the
# work landed by another route — reads a tree the head never was. Stamping from
# the head would make the gate CLEAR ON AN INFERENCE, inverting the failure
# direction of a control built to refuse (lodar, review on #1001). So the stamp is
# issued only when the tree the command ran in IS the head, and every other case
# gets `graded-head-at:` — legible, and a label the fence does not parse.
#
# Every arm below therefore drives a REAL `git rev-parse HEAD` in a REAL cwd: the
# harness makes its own throwaway checkout and runs the verb inside it, because a
# stubbed tree would grade the fixture rather than the probe.
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

# --- The two cwds every arm chooses between ----------------------------------
# TREE is a real git checkout whose HEAD this harness knows; NOTGIT is a plain
# directory, which is what "the grade did not run in a git tree" looks like.
TREE="$TMP/tree"; NOTGIT="$TMP/notgit"
mkdir -p "$TREE" "$NOTGIT"
git -C "$TREE" init -q >/dev/null 2>&1
git -C "$TREE" -c user.email=harness@example.invalid -c user.name=harness \
    commit -q --allow-empty -m 'seed' >/dev/null 2>&1
TREE_SHA="$(git -C "$TREE" rev-parse HEAD 2>/dev/null)"
OTHER_SHA="00112233445566778899aabbccddeeff00112233"   # a head the command never read
PR_URL="https://github.com/acme/widget/pull/994"

# --- The gh seam, stubbed: this harness grades the STAMP, not the transport ---
# GH_HEAD empty models "gh cannot read the pull request" (no credential, no
# network, a repo the token is blind to).
GH_HEAD="$TREE_SHA"
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
# `fail` exits, so every run is a subshell — and the cwd is the point of the arm.
run_in() { local d="$1"; shift; ( cd "$d" && cmd_task_verify "$@" ) >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?"; }
disp_at() { _merge_disp_decide MERGEABLE CLEAN "$1" "$2" low; }

record_with() { printf 'delivered by the maker\nCHANGED: src/thing.sh — the fix\nDELIVERED-SHA: %s\nCI: green' "$1"; }
RECORD_TREE="$(record_with "$TREE_SHA")"
RECORD_OTHER="$(record_with "$OTHER_SHA")"

# --- 0) PRECONDITIONS: the arms below are not vacuous ------------------------
[[ "$TREE_SHA" =~ ^[0-9a-f]{40}$ ]] \
  && ok_t "precondition: the harness made a real checkout and knows its HEAD (${TREE_SHA:0:12})" \
  || bad_t "precondition: a throwaway git checkout exists" "git rev-parse gave '$TREE_SHA' — every arm below would grade nothing"
[[ -z "$(_gate_graded_sha "$RECORD_TREE")" ]] \
  && ok_t "precondition: a delivery record states NO graded-sha (DELIVERED-SHA is a different claim)" \
  || bad_t "precondition: the seeded record states no graded-sha" "it already does; the arms below would pass vacuously"
[[ "$(disp_at "$TREE_SHA" "")" == "hold:merger:no-graded-sha-stated" ]] \
  && ok_t "precondition: with no graded sha the disposition really is hold:merger:no-graded-sha-stated" \
  || bad_t "precondition: the gate holds without a graded sha" "got: $(disp_at "$TREE_SHA" "")"

# --- A) THE TREE IS THE HEAD: stamped, and the gate clears -------------------
seed 601 DIVE-601 "$PR_URL" "$RECORD_TREE"
GH_HEAD="$TREE_SHA"
RC="$(run_in "$TREE" DIVE-601)"
A_RES="$(result_of DIVE-601)"
[[ "$RC" == "0" ]] \
  && ok_t "A0: a passing command grade still exits 0" \
  || bad_t "A0: the grade exits 0" "rc=$RC err: $(head -2 "$TMP/err")"
[[ "$(_gate_graded_sha "$A_RES")" == "$TREE_SHA" ]] \
  && ok_t "A1: the tree the command ran in IS the head -> graded-sha: <that tree>" \
  || bad_t "A1: a proven grade is stamped" "got '$(_gate_graded_sha "$A_RES")' from: ${A_RES:0:400}"
has "$A_RES" "the tree this grade ran in" \
  && ok_t "A2: ... and the line says that is what the sha IS, not what the head was" \
  || bad_t "A2: the stamp states what it proves" "result: ${A_RES:0:400}"
[[ "$(disp_at "$TREE_SHA" "$(_gate_graded_sha "$A_RES")")" == "merge" ]] \
  && ok_t "A3: ... so the merge gate clears instead of holding at no-graded-sha-stated" \
  || bad_t "A3: the gate clears on a proven stamp" "got: $(disp_at "$TREE_SHA" "$(_gate_graded_sha "$A_RES")")"
[[ "$(status_of DIVE-601)" != "done" ]] \
  && ok_t "A4: the bound row still does NOT close itself (DIVE-3330 hold is unchanged)" \
  || bad_t "A4: the bound row stays open" "status=$(status_of DIVE-601)"

# --- B) lodar's case: the command graded a tree that is not the head ---------
# `git show origin/main:<file>` in a checkout sitting at some other commit. The
# head is readable and fine; it is simply not what was graded.
seed 602 DIVE-602 "$PR_URL" "$RECORD_TREE"
GH_HEAD="$OTHER_SHA"
RC="$(run_in "$TREE" DIVE-602)"
B_RES="$(result_of DIVE-602)"
[[ "$RC" == "0" ]] \
  && ok_t "B0: the grade still PASSES — this is about what is stamped, not about the verdict" \
  || bad_t "B0: the grade passes" "rc=$RC err: $(head -2 "$TMP/err")"
[[ -z "$(_gate_graded_sha "$B_RES")" ]] \
  && ok_t "B1: head != the tree graded -> NOTHING is stamped (the inference is refused)" \
  || bad_t "B1: a head the grade never read is not stamped" "got '$(_gate_graded_sha "$B_RES")'"
{ has "$B_RES" "graded-head-at: ${OTHER_SHA}" && has "$B_RES" "tree graded: ${TREE_SHA}"; } \
  && ok_t "B2: ... and both shas are on the row under graded-head-at, so the hold is legible" \
  || bad_t "B2: the provenance is written down" "result: ${B_RES:0:500}"
[[ "$(disp_at "$OTHER_SHA" "$(_gate_graded_sha "$B_RES")")" == "hold:merger:no-graded-sha-stated" ]] \
  && ok_t "B3: ... and the merge gate KEEPS HOLDING — a person still looks at this one" \
  || bad_t "B3: the gate holds on an unproven grade" "got: $(disp_at "$OTHER_SHA" "$(_gate_graded_sha "$B_RES")")"

# --- C) The command did not run in a git tree at all ------------------------
seed 603 DIVE-603 "$PR_URL" "$RECORD_TREE"
GH_HEAD="$TREE_SHA"
RC="$(run_in "$NOTGIT" DIVE-603)"
C_RES="$(result_of DIVE-603)"
{ [[ -z "$(_gate_graded_sha "$C_RES")" ]] && has "$C_RES" "tree graded: unreadable"; } \
  && ok_t "C1: no readable tree -> nothing proven, nothing stamped, and the row says which half was missing" \
  || bad_t "C1: an unreadable tree holds" "got '$(_gate_graded_sha "$C_RES")' from: ${C_RES:0:500}"

# --- D) gh unreadable: DELIVERED-SHA may CORROBORATE the tree ----------------
seed 604 DIVE-604 "$PR_URL" "$RECORD_TREE"
GH_HEAD=""
RC="$(run_in "$TREE" DIVE-604)"
D_RES="$(result_of DIVE-604)"
{ [[ "$(_gate_graded_sha "$D_RES")" == "$TREE_SHA" ]] && has "$D_RES" "DELIVERED-SHA stated in the delivery record"; } \
  && ok_t "D1: gh silent but DELIVERED-SHA == the tree graded -> stamped, and it names the corroborating source" \
  || bad_t "D1: the corroborated fallback stamps" "got '$(_gate_graded_sha "$D_RES")' from: ${D_RES:0:400}"

# --- E) ... and never STANDS IN for the tree ---------------------------------
seed 605 DIVE-605 "$PR_URL" "$RECORD_OTHER"
GH_HEAD=""
RC="$(run_in "$TREE" DIVE-605)"
E_RES="$(result_of DIVE-605)"
[[ -z "$(_gate_graded_sha "$E_RES")" ]] \
  && ok_t "E1: DELIVERED-SHA disagreeing with the tree graded stamps NOTHING — it corroborates, it does not substitute" \
  || bad_t "E1: an uncorroborated DELIVERED-SHA is not a stamp" "got '$(_gate_graded_sha "$E_RES")'"
has "$E_RES" "graded-head-at: unreadable" \
  && ok_t "E2: ... and with gh silent too the line says the head itself was unreadable" \
  || bad_t "E2: the unreadable head is named" "result: ${E_RES:0:500}"

# --- F) THE LABEL MUST NOT PARSE. This is the whole safety property ---------
# Asserted on the rendered text directly as well as through the rows above: if
# `graded-head-at:` ever satisfied the fence, every held case in this file would
# silently become a clear, which is the exact failure the review objected to.
for probe in \
  "graded-head-at: ${OTHER_SHA} (tree graded: ${TREE_SHA})" \
  "graded-head-at: unreadable (tree graded: unreadable)" \
  "graded-head-at: ${OTHER_SHA} (tree graded: unreadable)"; do
  [[ -n "$(_gate_graded_sha "$probe")" ]] && { bad_t "F1: 'graded-head-at' must not satisfy _gate_graded_sha" "it parsed '$probe' as '$(_gate_graded_sha "$probe")'"; F_BAD=1; }
done
[[ -z "${F_BAD:-}" ]] \
  && ok_t "F1: none of the three graded-head-at shapes parses as a graded sha" \
  || true
[[ -n "$(_gate_graded_sha "graded-sha: ${TREE_SHA}")" ]] \
  && ok_t "F2: ... while the real label still does — F1 is a discrimination, not a broken fence" \
  || bad_t "F2: the fence still parses a real graded-sha" "it no longer matches anything"

# --- G) A verifier who stated their own sha is not overwritten ---------------
seed 606 DIVE-606 "$PR_URL" "$RECORD_TREE"
GH_HEAD="$TREE_SHA"
RC="$(run_in "$TREE" DIVE-606 --cmd=true --no-done --result="I read the diff. graded-sha: deadbee1234567")"
G_RES="$(result_of DIVE-606)"
{ [[ "$(_gate_graded_sha "$G_RES")" == "deadbee1234567" ]] && ! has "$G_RES" "the tree this grade ran in"; } \
  && ok_t "G1: a graded-sha the VERIFIER stated wins — the stamp fills a silence, it does not overrule a claim" \
  || bad_t "G1: a stated claim is left alone" "rc=$RC got '$(_gate_graded_sha "$G_RES")'"

# --- H) An UNBOUND row is untouched -----------------------------------------
db "DELETE FROM tasks WHERE id=607;" >/dev/null 2>&1
db "INSERT INTO tasks(id, ident, title, status, priority, assignee, created_by, created_at, project_key, verify_command)
    VALUES(607, 'DIVE-607', 'unbound row', 'in_progress', 'high', 'maker', 'harness', datetime('now'), 'dive', 'true');" \
  >/dev/null 2>&1
GH_HEAD="$TREE_SHA"
RC="$(run_in "$TREE" DIVE-607)"
H_RES="$(result_of DIVE-607)"
{ ! has "$H_RES" "graded-sha" && ! has "$H_RES" "graded-head-at"; } \
  && ok_t "H1: a row binding no delivery gets no line at all — there is no merge gate to answer" \
  || bad_t "H1: unbound rows are untouched" "result: ${H_RES:0:300}"
[[ "$(status_of DIVE-607)" == "done" ]] \
  && ok_t "H2: ... and it still auto-closes, so a mutation that disabled every close cannot green this file" \
  || bad_t "H2: the unbound row still closes" "status=$(status_of DIVE-607) rc=$RC err: $(head -2 "$TMP/err")"

# --- I) A FAIL owes nobody a merge answer -----------------------------------
seed 608 DIVE-608 "$PR_URL" "$RECORD_TREE"
GH_HEAD="$TREE_SHA"
RC="$(run_in "$TREE" DIVE-608 --cmd=false)"
I_RES="$(result_of DIVE-608)"
{ [[ "$RC" != "0" ]] && ! has "${I_RES#*"$RECORD_TREE"}" "graded-sha" \
  && ! has "${I_RES#*"$RECORD_TREE"}" "graded-head-at"; } \
  && ok_t "I1: a FAILING grade writes neither line — a fail owes the maker a fix, not anyone a merge" \
  || bad_t "I1: the FAIL branch is untouched" "rc=$RC result: ${I_RES:0:400}"

# =============================================================================
# MUTANT — take the stamp back out and the gate must hold on the PROVEN case.
# =============================================================================
# BEFORE/AFTER on purpose: "the stamp is gone" is also true of a sed that matched
# nothing, which would make every arm below vacuous.
ORIG="$(declare -f cmd_task_verify)"
MUT="$(printf '%s\n' "$ORIG" | sed 's/^\([[:space:]]*\)if \[\[ -n "\$_vg_dref" \]\].*/\1if false; then/')"
has "$ORIG" '_verify_grade_line' \
  && ok_t "M0a: BEFORE — the shipped verify really does reach the stamp" \
  || bad_t "M0a: the shipped verify stamps" "no stamp found; every mutant arm below is vacuous"
{ has "$MUT" 'if false; then' && ! has "$MUT" 'if [[ -n "$_vg_dref" ]]'; } \
  && ok_t "M0b: AFTER — the mutation really removed the guard's true branch (the sed matched)" \
  || bad_t "M0b: the mutation took" "the sed did not match; the mutant is not mutated"

eval "$MUT"
seed 609 DIVE-609 "$PR_URL" "$RECORD_TREE"
GH_HEAD="$TREE_SHA"
RC="$(run_in "$TREE" DIVE-609)"
M_RES="$(result_of DIVE-609)"
[[ "$RC" == "0" && -z "$(_gate_graded_sha "$M_RES")" ]] \
  && ok_t "M1: MUTANT — the grade still PASSES and states no sha (A1 would be red on it)" \
  || bad_t "M1: mutant records no sha" "rc=$RC got '$(_gate_graded_sha "$M_RES")'"
[[ "$(disp_at "$TREE_SHA" "$(_gate_graded_sha "$M_RES")")" == "hold:merger:no-graded-sha-stated" ]] \
  && ok_t "M2: MUTANT — and the merge gate is back to no-graded-sha-stated (A3 would be red on it)" \
  || bad_t "M2: mutant holds the gate" "got: $(disp_at "$TREE_SHA" "$(_gate_graded_sha "$M_RES")")"

# A second mutation, aimed at the REVIEW's defect rather than the original one:
# stamp from the head without proving the tree, and arm B goes green when it must
# not. This is the arm that would have caught the shape lodar rejected.
#
# The dispatcher is restored FIRST — with cmd_task_verify still mutated the helper
# is never reached, and both arms below would "pass" on an empty result, which is
# the vacuous shape M0a/M0b exist to rule out one level up.
eval "$ORIG"
ORIG_LINE="$(declare -f _verify_grade_line)"
_verify_grade_line() { printf 'graded-sha: %s (the pull request head at grade time, read with gh)' "$GH_HEAD"; }
seed 610 DIVE-610 "$PR_URL" "$RECORD_TREE"
GH_HEAD="$OTHER_SHA"
RC="$(run_in "$TREE" DIVE-610)"
M3_RES="$(result_of DIVE-610)"
[[ "$(_gate_graded_sha "$M3_RES")" == "$OTHER_SHA" ]] \
  && ok_t "M3: INFERRING MUTANT — stamping from the head alone puts a tree the grade never read on the row (B1 would be red on it)" \
  || bad_t "M3: the inferring mutant stamps the head" "got '$(_gate_graded_sha "$M3_RES")'"
[[ "$(disp_at "$OTHER_SHA" "$(_gate_graded_sha "$M3_RES")")" == "merge" ]] \
  && ok_t "M4: ... and the gate CLEARS on it — the exact inversion this shape exists to prevent (B3 would be red on it)" \
  || bad_t "M4: the inferring mutant clears the gate" "got: $(disp_at "$OTHER_SHA" "$(_gate_graded_sha "$M3_RES")")"

eval "$ORIG_LINE"
seed 611 DIVE-611 "$PR_URL" "$RECORD_TREE"
GH_HEAD="$TREE_SHA"
RC="$(run_in "$TREE" DIVE-611)"
[[ "$(_gate_graded_sha "$(result_of DIVE-611)")" == "$TREE_SHA" ]] \
  && ok_t "M5: RESTORE took — the fixed verify and helper are back and stamp the proven case again" \
  || bad_t "M5: restore took" "got '$(_gate_graded_sha "$(result_of DIVE-611)")' (later arms would grade the mutant)"

echo "-----"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
