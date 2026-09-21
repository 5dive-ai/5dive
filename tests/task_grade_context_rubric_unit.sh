#!/usr/bin/env bash
# DIVE-4634 — bounded packet, immutable detached grade tree, rubric escalation.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src; TMP=$(mktemp -d /tmp/task-grade-context.XXXXXX)
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
  lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh lib/registry.sh \
  lib/disk.sh lib/verify_policy.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh \
  cmd_push.sh cmd_org.sh cmd_project.sh; do source "$SRC/$f"; done
source "$SRC/task/grader_process.sh"
STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
BOX_CONFIG="$TMP/box.json"; HOME="$TMP/grader-home"; XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$TASKS_DIR" "$HOME"; chmod 700 "$HOME"; JSON_MODE=0; set +e
printf '{"verify":"always"}\n' >"$BOX_CONFIG"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
PASS=0; FAILN=0; SKIPN=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
# THREE OUTCOMES, NOT TWO: the DIVE-4803 permission arms below cannot run as
# root (root writes through a cleared write bit, so the denial they need does
# not exist), and an arm that cannot run must say so rather than report either
# verdict. It is a SKIP and not a FAIL because root is a legitimate way to run
# this harness, and a red that means "wrong uid" trains people to ignore reds.
skip_t(){ SKIPN=$((SKIPN+1)); printf 'SKIP - %s\n   %s\n' "$1" "${2:-}"; }
tasks_db_init >/dev/null 2>&1

REPO="$TMP/repo"; mkdir -p "$REPO/src"; git -C "$REPO" init -q
printf 'old\n' >"$REPO/src/x.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm base
BASE=$(git -C "$REPO" rev-parse HEAD); git -C "$REPO" branch origin/main "$BASE"
printf 'old\nnew guard\n' >"$REPO/src/x.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm change
SHA=$(git -C "$REPO" rev-parse HEAD)
SENTINEL=BODY_SENTINEL_4634
BODY=$(awk -v s="$SENTINEL" 'BEGIN{for(i=0;i<4000;i++) printf "%s word%d ",s,i}')
RESULT=$'CHANGED: src/x.txt adds the guard\nCHECKED: grep -q "new guard" src/x.txt — PASS output: matched\nDELIVERED-SHA: '"$SHA"$'\nCI: green\nCRITERIA: guard is present — CHECKED above\n\nROUTING-HISTORY-SHOULD-NOT-LEAK'
ID=$(db "INSERT INTO tasks (title,body,status,assignee,verifier,maker_agent,kind,priority,created_by,acceptance_criteria,result,review_mode,delivery_repo_path,delivered_sha,delivery_ref,delivered_at)
 VALUES ('bounded packet',$(sqlq "$BODY"),'todo','quinn','quinn','codex','standard','high','codex','The delivered diff adds and tests the guard.',$(sqlq "$RESULT"),'temp',$(sqlq "$REPO/.git"),$(sqlq "$SHA"),'https://example.invalid/pull/1',datetime('now')); SELECT last_insert_rowid();")
IDENT=$(db "SELECT ident FROM tasks WHERE id=$ID;")

OUT=$(cmd_task_grade_context "$IDENT" 2>&1); RC=$?
(( RC == 0 )) && ok_t "bounded packet materializes" || bad_t "bounded packet materializes" "rc=$RC ${OUT:0:200}"
[[ "$OUT" == *"CHANGED: src/x.txt"* && "$OUT" == *"diff --git"* ]] \
  && ok_t "packet contains claim block and delivered-sha diff" || bad_t "packet contains claim block and delivered-sha diff"
[[ "$OUT" != *"$SENTINEL"* && "$OUT" != *"ROUTING-HISTORY-SHOULD-NOT-LEAK"* ]] \
  && ok_t "4000-word body and post-claim routing prose are absent" || bad_t "body/routing prose leaked"
TREE=$(sed -n 's/^GRADE_TREE: //p' <<<"$OUT" | head -1)
[[ "$(git -C "$TREE" rev-parse HEAD 2>/dev/null)" == "$SHA" && -z "$(git -C "$TREE" status --porcelain)" ]] \
  && ok_t "grade tree is detached at exact delivered sha and clean" || bad_t "grade tree sha/clean invariant"
[[ "$(stat -c %a "${TREE%/*}")" == "700" ]] && ok_t "grader state is private from the maker" \
  || bad_t "grader state is private" "mode=$(stat -c %a "${TREE%/*}" 2>/dev/null)"
( cmd_task_grade_context "$IDENT" --check="$TREE" >/dev/null 2>&1 ); RC=$?
(( RC == 0 )) && ok_t "pre-verdict check accepts the sealed tree" || bad_t "pre-verdict check accepts" "rc=$RC"
printf 'maker race\n' >>"$TREE/src/x.txt"
( cmd_task_grade_context "$IDENT" --check="$TREE" >/dev/null 2>&1 ); RC=$?
(( RC != 0 )) && ok_t "dirty/mutated grade tree is refused" || bad_t "dirty/mutated grade tree is refused"
git -C "$TREE" checkout -q -- src/x.txt
git -C "$TREE" checkout -q --detach "$BASE"
( cmd_task_grade_context "$IDENT" --check="$TREE" >/dev/null 2>&1 ); RC=$?
(( RC != 0 )) && ok_t "wrong-sha grade tree is refused" || bad_t "wrong-sha grade tree is refused"

# Prompt size is independent of narrative body length.
SIZE1=${#OUT}; db "UPDATE tasks SET body='' WHERE id=$ID;"
rm -rf "$TREE"; git -C "$REPO" worktree prune >/dev/null 2>&1
OUT2=$(cmd_task_grade_context "$IDENT" 2>&1)
[[ ${#OUT2} -eq $SIZE1 ]] && ok_t "packet size is unchanged when the 4000-word body is removed" \
  || bad_t "packet size ignores body" "$SIZE1 vs ${#OUT2}"

# ── DIVE-4803 — A GRADER ON ANOTHER SEAT CAN BUILD THE PACKET ──────────────
# The maker delivers from their own home; the grader runs as a different unix
# user with READ but not WRITE on that checkout. `git worktree add` writes its
# admin record into the SOURCE repo, so the packet could not be materialized at
# all on any maker != verifier pair (measured grading DIVE-4802). The fixture is
# the same shape: a maker repo whose git dir this process cannot write.
R2="$TMP/maker-repo"; mkdir -p "$R2/src"; git -C "$R2" init -q
printf 'one\n' >"$R2/src/y.txt"; git -C "$R2" add -A; git -C "$R2" commit -qm base2
B2=$(git -C "$R2" rev-parse HEAD); git -C "$R2" branch origin/main "$B2"
printf 'one\ntwo\n' >"$R2/src/y.txt"; git -C "$R2" add -A; git -C "$R2" commit -qm change2
S2=$(git -C "$R2" rev-parse HEAD)
R2RESULT=$'CHANGED: src/y.txt adds the second line\nCHECKED: grep -qx two src/y.txt — PASS\nDELIVERED-SHA: '"$S2"$'\nCI: green\nCRITERIA: second line present — CHECKED above'
ID2=$(db "INSERT INTO tasks (title,body,status,assignee,verifier,maker_agent,kind,priority,created_by,acceptance_criteria,result,review_mode,delivery_repo_path,delivered_sha,delivery_ref,delivered_at)
 VALUES ('cross-seat packet','','todo','quinn','quinn','main','standard','high','main','The delivered diff adds the second line.',$(sqlq "$R2RESULT"),'temp',$(sqlq "$R2/.git"),$(sqlq "$S2"),'https://example.invalid/pull/2',datetime('now')); SELECT last_insert_rowid();")
IDENT2=$(db "SELECT ident FROM tasks WHERE id=$ID2;")
ro2(){ chmod -R a-w "$R2/.git" 2>/dev/null; }
rw2(){ chmod -R u+w "$R2/.git" 2>/dev/null; }
# Is the write actually denied to THIS process? A cleared write bit is not a
# denial for root, and every arm below would then be grading nothing.
maker_repo_is_readonly(){ ! ( mkdir "$R2/.git/.probe-4803" ) 2>/dev/null || { rmdir "$R2/.git/.probe-4803" 2>/dev/null; return 1; }; }
# Removing the tree is not enough to reset the PRE-FIX path: `git worktree add`
# leaves an admin record behind, and a second run then dies on the stale
# registration instead of on the permission it was meant to grade. Pruning here
# (while the repo is still writable) keeps the control run's red honest.
drop_tree2(){ rm -rf "$HOME/.local/state/5dive/grades/${IDENT2}-${S2:0:12}"; git -C "$R2" worktree prune >/dev/null 2>&1 || true; }

OUT3=$(cmd_task_grade_context "$IDENT2" 2>&1); RC=$?
TREE2=$(sed -n 's/^GRADE_TREE: //p' <<<"$OUT3" | head -1)
(( RC == 0 )) && [[ "$(git -C "$TREE2" rev-parse HEAD 2>/dev/null)" == "$S2" && -z "$(git -C "$TREE2" status --porcelain -uall 2>&1)" ]] \
  && ok_t "packet materializes from a maker repo this process does not own" \
  || bad_t "packet materializes from a maker repo this process does not own" "rc=$RC tree=$TREE2 ${OUT3:0:200}"
[[ "$OUT3" == *"diff --git"* && "$OUT3" == *"+two"* ]] \
  && ok_t "the borrowed object store still yields the delivered-sha diff" \
  || bad_t "borrowed object store yields the diff" "${OUT3:0:300}"
# THE PROPERTY, stated where a uid cannot make it vacuous: the grade writes
# nothing into the maker's repository. This arm holds for any uid, including
# root, and it is the one the mutation below turns red.
[[ ! -e "$R2/.git/worktrees" ]] \
  && ok_t "grading leaves no bookkeeping behind in the maker's repo" \
  || bad_t "grading leaves no bookkeeping behind in the maker's repo" "$(ls "$R2/.git/worktrees" 2>/dev/null)"

drop_tree2; ro2
if maker_repo_is_readonly; then
  OUT4=$(cmd_task_grade_context "$IDENT2" 2>&1); RC=$?
  (( RC == 0 )) && [[ "$(git -C "$TREE2" rev-parse HEAD 2>/dev/null)" == "$S2" ]] \
    && ok_t "packet materializes with the maker's git dir NOT writable (DIVE-4803)" \
    || bad_t "packet materializes with the maker's git dir NOT writable (DIVE-4803)" "rc=$RC ${OUT4:0:300}"
  # MUTATION: put the pre-fix materialization back and the same arm must go red.
  # Without this the arm above could be passing because the fixture never denied
  # anything — a permission arm that grades nothing looks exactly like one that
  # grades everything.
  rw2
  _orig_materialize=$(declare -f _task_grade_materialize_tree)
  _task_grade_materialize_tree(){ git --git-dir="$1" worktree add --detach -q "$3" "$2" >/dev/null 2>&1; }
  if declare -f _task_grade_materialize_tree | grep -q 'worktree add'; then
    drop_tree2; ro2
    ( cmd_task_grade_context "$IDENT2" >/dev/null 2>&1 ); RC=$?
    (( RC != 0 )) \
      && ok_t "MUTANT: the pre-fix worktree materialization fails on an unwritable maker repo" \
      || bad_t "MUTANT SURVIVED: pre-fix materialization succeeded — the permission arm above grades nothing" "rc=$RC"
    rw2; drop_tree2
    ( cmd_task_grade_context "$IDENT2" >/dev/null 2>&1 )
    [[ -e "$R2/.git/worktrees" ]] \
      && ok_t "MUTANT: the pre-fix materialization does write into the maker's repo" \
      || bad_t "MUTATION NOT APPLIED: pre-fix materialization left no worktree record — the no-bookkeeping arm grades nothing" "$(ls -a "$R2/.git" 2>/dev/null | tr '\n' ' ')"
  else
    bad_t "MUTATION NOT APPLIED: could not install the pre-fix materialization"
  fi
  eval "$_orig_materialize"
  rw2; git -C "$R2" worktree prune >/dev/null 2>&1; rm -rf "$R2/.git/worktrees"; drop_tree2
else
  rw2
  skip_t "maker-repo permission arms (DIVE-4803) — this process writes through a cleared write bit (root?), so no denial exists to grade" \
    "uid=$(id -u); the uid-independent no-bookkeeping arm above still ran"
fi

db "UPDATE tasks SET review_mode='rubric', verify_forced=NULL, verify_command=NULL WHERE id=$ID;"
_task_delivery_paths(){ printf 'docs/readme.md\n'; }
_task_deliver_rubric_escalate "$ID" "$IDENT" "" >/dev/null 2>&1; RC=$?
[[ $RC -ne 0 && "$(db "SELECT review_mode FROM tasks WHERE id=$ID;")" == rubric ]] \
  && ok_t "clean non-blast rubric stays cheap" || bad_t "clean rubric stays cheap"
_task_delivery_paths(){ printf 'src/lib/shared.sh\n'; }
_task_deliver_rubric_escalate "$ID" "$IDENT" "" >/dev/null 2>&1
[[ "$(db "SELECT review_mode FROM tasks WHERE id=$ID;")" == temp ]] \
  && ok_t "shared-lib blast path escalates rubric to full grade" || bad_t "blast path escalation"

db "UPDATE tasks SET review_mode='rubric' WHERE id=$ID;"
PROMPT=$(_grader_grade_method_clause "$IDENT")
for q in 'test exercise' 'mutant arm' 'outside stated scope' 'changelog/result' 'secret or real identifier' 'CHECKED contradict'; do
  [[ "$PROMPT" == *"$q"* ]] || bad_t "rubric prompt contains '$q'" "$PROMPT"
done
[[ "$PROMPT" != *'task show'* && "$PROMPT" == *'grade-context'* ]] \
  && ok_t "rubric prompt uses bounded context, never task show" || bad_t "rubric prompt boundary" "$PROMPT"
REGISTRY="$TMP/agents.json"; printf '{"agents":{"pool":{"authProfile":"cheap-acct"}}}\n' >"$REGISTRY"
CREATE_ARGS="$TMP/create-args"
mock_create(){ printf '%s\n' "$*" >"$CREATE_ARGS"; }
_GRADER_TASK_CLI=mock_create; _grader_clone_record_origin(){ :; }
_grader_clone_create gr-pool-1 pool "$IDENT" >/dev/null 2>&1
grep -q -- '--model=sonnet' "$CREATE_ARGS" \
  && ok_t "rubric clone is pinned to the cheap model" || bad_t "rubric cheap model pin" "$(cat "$CREATE_ARGS" 2>/dev/null)"
grep -q -- '--effort=low' "$CREATE_ARGS" \
  && ok_t "rubric clone is pinned to low effort" || bad_t "rubric low-effort pin" "$(cat "$CREATE_ARGS" 2>/dev/null)"

# The clone path passes --model without a BYO provider. Create must preserve
# that auth-profile-backed model request in the runtime preseed; otherwise the
# live seat silently starts on Opus while the mock-argument arm above stays green.
CREATE_SRC=$(<src/cmd_agent_create.sh)
[[ "$CREATE_SRC" == *'_claude_create_model="$byo_model"'* \
  && "$CREATE_SRC" == *'preseed_claude_agent "$name" "$channels" "$_claude_create_model" "${byo_effort:-high}"'* ]] \
  && ok_t "auth-profile clone applies the cheap model at create" \
  || bad_t "auth-profile clone applies the cheap model at create"

printf '%s\nSKIP=%d\nPASS=%d FAIL=%d\n' '-----' "$SKIPN" "$PASS" "$FAILN"
(( FAILN == 0 ))
