#!/usr/bin/env bash
# DIVE-4623 — A CHECK THAT CANNOT FAIL IS NOT A GRADE.
#
# `--review=check` grades a row with a command and spends no grader session. It
# was never safe as the DEFAULT for one reason: nothing proved the command could
# go red, and `--verify=true` is a passing grade on every tree that will ever
# exist. This harness grades the negative control that closes that hole — the
# mutant arm — at the three places it has to hold:
#
#   PART 1  FILING      `--review=check` is refused without a control, and the
#                       control (or its audited waiver) is PERSISTED.
#   PART 2  THE ARMS    `_task_grade_table` against REAL git repositories
#                       (not a stub): healthy, vacuous, red-at-sha, broken-mutant,
#                       no-git — and it leaks no worktree in any of them.
#   PART 3  DELIVERY    a vacuous check is REFUSED at `task deliver`, the row
#                       carries both arms afterwards, and NO grader session is
#                       booked to discover what a command already found.
#   PART 4  MUTATION    the two load-bearing predicates are cut out of the
#                       SHIPPING functions (`declare -f` + sed + re-eval) and the
#                       arms above must go RED. Each cut is checked to have
#                       LANDED first — a sed that matched nothing would otherwise
#                       leave the arm green having mutated nothing.
#
# WHY PART 2 USES REAL REPOSITORIES. The claim is "both arms run from a clean
# checkout at the delivered sha", and a stubbed `git worktree` would prove only
# that the function calls something named git. The scratch repos here are three
# commits in a temp dir; they cost milliseconds and they are the only way the
# "the check passed on the maker's dirty tree and fails at the sha" arm can exist
# at all.
#
# Isolation: src/ sourced directly, STATE_DIR on a throwaway dir, BOX_CONFIG
# inside it, every git operation inside $TMP. No root, no network.
# Run: bash tests/task_check_mutant_arm_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-check-mutant.XXXXXX)"
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

add_row() { # <title> [flags...] -> ident on stdout, stderr swallowed
  local t="$1"; shift
  cmd_task_add "$t $RANDOM" --assignee=dev --from=main --priority=high "$@" 2>/dev/null \
    | jq -r '.data.ident // empty' 2>/dev/null
}
add_rc() { # same, but returns the exit code and prints nothing
  local t="$1"; shift
  ( cmd_task_add "$t $RANDOM" --assignee=dev --from=main --priority=high "$@" >/dev/null 2>&1 )
}
col() { db "SELECT COALESCE($2,'') FROM tasks WHERE ident=$(sqlq "$1");"; }
rows() { db "SELECT COUNT(*) FROM tasks;"; }

CHK='grep -q GUARDTOKEN src/foo.sh'
MUT='sed -i s/GUARDTOKEN/xxx/ src/foo.sh'

echo "── PART 1 — filing: check needs a control, and the control is stored ─────"

BEFORE=$(rows)
add_rc "vacuous by omission" --review=check --verify="$CHK"
rc=$?
(( rc != 0 )) && ok_t "--review=check with NO control is REFUSED" \
  || bad_t "--review=check with NO control is REFUSED" "exit $rc"
[[ "$(rows)" == "$BEFORE" ]] && ok_t "the refusal wrote NO row" \
  || bad_t "the refusal wrote NO row" "rows $BEFORE -> $(rows)"

ID1=$(add_row "controlled" --review=check --verify="$CHK" --mutant="$MUT")
[[ -n "$ID1" ]] && ok_t "--review=check WITH a control is accepted" \
  || bad_t "--review=check WITH a control is accepted" "no ident"
[[ "$(col "$ID1" review_mode)" == "check" ]] && ok_t "it resolves to review=check" \
  || bad_t "it resolves to review=check" "mode='$(col "$ID1" review_mode)'"
[[ "$(col "$ID1" mutant_command)" == "$MUT" ]] && ok_t "the control is PERSISTED verbatim" \
  || bad_t "the control is PERSISTED verbatim" "got '$(col "$ID1" mutant_command)'"

ID2=$(add_row "waived" --review=check --verify="$CHK" --no-mutant="probes a live box; there is no tree to break")
[[ "$(col "$ID2" mutant_command)" == "none: probes a live box; there is no tree to break" ]] \
  && ok_t "the audited waiver is stored WITH its reason" \
  || bad_t "the audited waiver is stored WITH its reason" "got '$(col "$ID2" mutant_command)'"
[[ "$(mutant_escape_reason "$(col "$ID2" mutant_command)")" == "probes a live box; there is no tree to break" ]] \
  && ok_t "mutant_escape_reason reads the waiver back" \
  || bad_t "mutant_escape_reason reads the waiver back" "got '$(mutant_escape_reason "$(col "$ID2" mutant_command)")'"
mutant_escape_reason "$MUT" >/dev/null 2>&1 \
  && bad_t "a real command is NOT read as a waiver" "escape claimed" \
  || ok_t "a real command is NOT read as a waiver"

add_rc "both" --review=check --verify="$CHK" --mutant="$MUT" --no-mutant="why" \
  && bad_t "--mutant and --no-mutant contradict" "accepted" \
  || ok_t "--mutant and --no-mutant contradict"
add_rc "orphan control" --mutant="$MUT" \
  && bad_t "--mutant with no check command is refused" "accepted" \
  || ok_t "--mutant with no check command is refused"
add_rc "empty reason" --review=check --verify="$CHK" --no-mutant="   " \
  && bad_t "--no-mutant with an EMPTY reason is refused" "accepted" \
  || ok_t "--no-mutant with an EMPTY reason is refused"

# BACK-COMPAT, and it is a deliberate choice, not an oversight: refusing a bare
# --verify=<cmd> would re-book a grader session for every existing caller, which
# is the burn this row exists to remove. The gap is RECORDED (NULL control) and
# named at delivery instead.
ID3=$(add_row "legacy bare verify" --verify="$CHK")
[[ -n "$ID3" && "$(col "$ID3" review_mode)" == "check" ]] \
  && ok_t "a bare --verify=<cmd> still files and still resolves to check" \
  || bad_t "a bare --verify=<cmd> still files and still resolves to check" "id='$ID3' mode='$(col "$ID3" review_mode)'"
[[ -z "$(col "$ID3" mutant_command)" ]] && ok_t "…and records NO control rather than inventing one" \
  || bad_t "…and records NO control rather than inventing one" "got '$(col "$ID3" mutant_command)'"

echo "── PART 2 — the arms, against real git repositories ──────────────────────"

mkrepo() { # <name> -> path; three commits, a guard token in src/foo.sh at HEAD
  local d="$TMP/$1"; mkdir -p "$d/src"
  git -C "$d" init -q 2>/dev/null
  printf 'echo hello\n' > "$d/src/foo.sh"; git -C "$d" add -A; git -C "$d" commit -qm base
  printf 'echo hello\nGUARDTOKEN\n' > "$d/src/foo.sh"; git -C "$d" add -A; git -C "$d" commit -qm guard
  printf '%s' "$d"
}
wt_count() { git -C "$1" worktree list 2>/dev/null | wc -l | tr -d ' '; }

R1=$(mkrepo repo1); B1=$(wt_count "$R1")
( cd "$R1" && _task_grade_table X-1 "$CHK" "$MUT" >/dev/null 2>&1 ); rc=$?
(( rc == 0 )) && ok_t "healthy control: check passes as delivered, fails on the mutated tree" \
  || bad_t "healthy control: check passes as delivered, fails on the mutated tree" "rc=$rc"
RCPT=$( cd "$R1" && _task_grade_table X-1 "$CHK" "$MUT" >/dev/null 2>&1; printf '%s' "$_TASK_GRADE_TABLE" )
grep -q 'suite ' <<<"$RCPT" && grep -qE 'mutant  M1  killed-by' <<<"$RCPT" \
  && grep -q 'VERDICT computed: PASS' <<<"$RCPT" \
  && ok_t "the TABLE records the suite arm, the killed mutant and a computed verdict (DIVE-4825)" \
  || bad_t "the TABLE records the suite arm, the killed mutant and a computed verdict (DIVE-4825)" "table='$RCPT'"
[[ "$(wt_count "$R1")" == "$B1" ]] && ok_t "no worktree is leaked in the maker's repo" \
  || bad_t "no worktree is leaked in the maker's repo" "$B1 -> $(wt_count "$R1")"

# THE CRITERION-3 ARM at the unit level: a check that cannot fail.
R2=$(mkrepo repo2); B2=$(wt_count "$R2")
( cd "$R2" && _task_grade_table X-2 "true" "true" >/dev/null 2>&1 ); rc=$?
(( rc == 4 )) && ok_t "VACUOUS: a check of 'true' with a mutant that changes nothing is caught" \
  || bad_t "VACUOUS: a check of 'true' with a mutant that changes nothing is caught" "rc=$rc (want 4)"
[[ "$(wt_count "$R2")" == "$B2" ]] && ok_t "…and still leaks no worktree" \
  || bad_t "…and still leaks no worktree" "$B2 -> $(wt_count "$R2")"

# A check that passes only in the DIRTY tree: the token is untracked, so the
# clean checkout at HEAD does not carry it.
R3=$(mkrepo repo3)
printf 'ONLY_IN_THE_DIRTY_TREE\n' > "$R3/src/untracked.sh"
( cd "$R3" && _task_grade_table X-3 "grep -q ONLY_IN_THE_DIRTY_TREE src/untracked.sh" "$MUT" >/dev/null 2>&1 ); rc=$?
(( rc == 3 )) && ok_t "arm A red: a check that passes only in the maker's dirty tree is caught at the sha" \
  || bad_t "arm A red: a check that passes only in the maker's dirty tree is caught at the sha" "rc=$rc (want 3)"

R4=$(mkrepo repo4); B4=$(wt_count "$R4")
cd "$R4" || exit 1
_task_grade_table X-4 "$CHK" "exit 7" >/dev/null 2>&1; rc=$?   # NOT a subshell: the flags are read below
(( rc == 1 )) && grep -q '^MUTANT-BROKEN' <<<"$_TASK_GRADE_FLAGS" \
  && ok_t "a mutant that ITSELF fails is FLAGGED for a reader, never a healthy control" \
  || bad_t "a mutant that ITSELF fails is FLAGGED for a reader, never a healthy control" "rc=$rc (want 1) flags='$_TASK_GRADE_FLAGS'"
[[ "$(wt_count "$R4")" == "$B4" ]] && ok_t "…and cleans up the worktree it had already made" \
  || bad_t "…and cleans up the worktree it had already made" "$B4 -> $(wt_count "$R4")"
cd "$REPO_ROOT" || exit 1

NOGIT="$TMP/nogit"; mkdir -p "$NOGIT"
( cd "$NOGIT" && _task_grade_table X-5 "$CHK" "$MUT" >/dev/null 2>&1 ); rc=$?
(( rc == 2 )) && ok_t "outside a git checkout the control is 'not run', not 'passed'" \
  || bad_t "outside a git checkout the control is 'not run', not 'passed'" "rc=$rc (want 2)"

echo "── PART 3 — delivery: a vacuous check is refused, and costs no session ───"

EV() { printf 'CHANGED: src/foo.sh\nCHECKED: %s\nDELIVERED-SHA: %s\nCI: green\nCRITERIA: the guard is present\n' "$1" "$2"; }
PR=https://github.com/5dive-ai/5dive/pull/999

R5=$(mkrepo repo5); SHA5=$(git -C "$R5" rev-parse HEAD)
IDV=$(add_row "vacuous at delivery" --review=check --verify="true" --mutant="true")
: > "$SPAWNS"
( cd "$R5" && cmd_task_deliver "$IDV" --pr="$PR" --result="$(EV true "$SHA5")" >/dev/null 2>&1 ); rc=$?
(( rc != 0 )) && ok_t "the delivery of a VACUOUS check is REFUSED" \
  || bad_t "the delivery of a VACUOUS check is REFUSED" "exit 0"
grep -q 'VACUOUS' <<<"$(col "$IDV" result)" && ok_t "the finding is on the ROW, not only in the caller's scrollback" \
  || bad_t "the finding is on the ROW, not only in the caller's scrollback" "result='$(col "$IDV" result)'"
[[ "$(spawn_count)" == "0" ]] && ok_t "NO grader session was booked to discover it" \
  || bad_t "NO grader session was booked to discover it" "spawns=$(spawn_count)"
[[ -z "$(col "$IDV" verifier)" ]] && ok_t "no grader was attached either" \
  || bad_t "no grader was attached either" "verifier='$(col "$IDV" verifier)'"

R6=$(mkrepo repo6); SHA6=$(git -C "$R6" rev-parse HEAD)
IDH=$(add_row "healthy at delivery" --review=check --verify="$CHK" --mutant="$MUT")
: > "$SPAWNS"
( cd "$R6" && cmd_task_deliver "$IDH" --pr="$PR" --result="$(EV "$CHK" "$SHA6")" >/dev/null 2>&1 ); rc=$?
(( rc == 0 )) && ok_t "a controlled, passing check DELIVERS" \
  || bad_t "a controlled, passing check DELIVERS" "exit $rc"
RES="$(col "$IDH" result)"
grep -q 'GRADE ' <<<"$RES" && grep -qE 'mutant  M1  killed-by' <<<"$RES" \
  && grep -q 'VERDICT computed: PASS' <<<"$RES" \
  && ok_t "the computed TABLE is recorded on the delivered row (DIVE-4825)" \
  || bad_t "the computed TABLE is recorded on the delivered row (DIVE-4825)" "result='$RES'"
[[ "$(spawn_count)" == "0" ]] && ok_t "…for no grader session" \
  || bad_t "…for no grader session" "spawns=$(spawn_count)"

R7=$(mkrepo repo7); SHA7=$(git -C "$R7" rev-parse HEAD)
IDL=$(add_row "legacy uncontrolled" --verify="$CHK")
: > "$SPAWNS"
( cd "$R7" && cmd_task_deliver "$IDL" --pr="$PR" --result="$(EV "$CHK" "$SHA7")" >/dev/null 2>&1 ); rc=$?
(( rc == 0 )) && ok_t "a legacy uncontrolled row still delivers (no re-booked session)" \
  || bad_t "a legacy uncontrolled row still delivers (no re-booked session)" "exit $rc"
grep -q 'NONE RECORDED' <<<"$(col "$IDL" result)" \
  && ok_t "…and the row SAYS its grade was uncontrolled" \
  || bad_t "…and the row SAYS its grade was uncontrolled" "result='$(col "$IDL" result)'"

echo "── PART 4 — mutation: cut the predicates, the arms above must go RED ─────"

# THE EVAL HAPPENS IN THE PARENT SHELL, and that is the whole trick: an earlier
# shape of this helper did the `eval` inside `r=$(mutate …)`, so the cut function
# lived and died in the command substitution's subshell and every mutation arm
# passed while mutating nothing — the exact green-on-a-no-op failure this part
# exists to prevent, reached by the harness itself. So `mutate` only WRITES the
# cut body and reports; the caller sources it.
CUT="$TMP/cut.sh"
mutate() { # <fn> <sed-expr> <marker-that-must-disappear> -> writes $CUT, echoes status
  local fn="$1" expr="$2" gone="$3" body
  body=$(declare -f "$fn") || { printf 'NOFN'; return 1; }
  local cut; cut=$(printf '%s\n' "$body" | sed "$expr")
  if [[ "$cut" == "$body" ]]; then printf 'NOOP'; return 1; fi
  if grep -q -- "$gone" <<<"$cut"; then printf 'STILLTHERE'; return 1; fi
  printf '%s\n' "$cut" > "$CUT"
  bash -n "$CUT" || { printf 'BADSYNTAX'; return 1; }
  printf 'OK'
}

ORIG_ARMS=$(declare -f _task_grade_table)
r=$(mutate _task_grade_table 's/^\( *\)return 4$/\1return 0/' 'return 4')
if [[ "$r" == "OK" ]] && . "$CUT"; then
  ok_t "mutation A landed: the vacuity verdict is cut out of the shipping function"
  ( cd "$R2" && _task_grade_table X-2 "true" "true" >/dev/null 2>&1 ); rc=$?
  (( rc != 4 )) && ok_t "…and the VACUOUS arm goes red (rc=$rc, no longer 4)" \
    || bad_t "…and the VACUOUS arm goes red" "still returns 1 with the verdict removed — the arm is not testing it"
else
  bad_t "mutation A landed" "$r"
fi
eval "$ORIG_ARMS"
( cd "$R2" && _task_grade_table X-2 "true" "true" >/dev/null 2>&1 )
(( $? == 4 )) && ok_t "the original function is restored" || bad_t "the original function is restored" "still mutated"

ORIG_ADD=$(declare -f cmd_task_add)
r=$(mutate cmd_task_add 's/\[\[ -n "\$mutant_cmd" || -n "\$mutant_waiver" \]\] || fail/[[ 1 == 1 ]] || fail/' 'n "\$mutant_cmd" || -n "\$mutant_waiver" \]\] || fail')
if [[ "$r" == "OK" ]] && . "$CUT"; then
  ok_t "mutation B landed: the filing-time control requirement is cut out"
  add_rc "mutated filing" --review=check --verify="$CHK"
  (( $? == 0 )) && ok_t "…and the filing refusal arm goes red (an uncontrolled check now files)" \
    || bad_t "…and the filing refusal arm goes red" "still refused with the requirement removed"
else
  bad_t "mutation B landed" "$r"
fi
eval "$ORIG_ADD"
add_rc "restored filing" --review=check --verify="$CHK"
(( $? != 0 )) && ok_t "the original refusal is restored" || bad_t "the original refusal is restored" "still mutated"

echo
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAILN"
(( FAILN == 0 )) || exit 1
