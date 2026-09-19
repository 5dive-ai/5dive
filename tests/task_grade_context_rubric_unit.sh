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
PASS=0; FAILN=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
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

printf '%s\nPASS=%d FAIL=%d\n' '-----' "$PASS" "$FAILN"
(( FAILN == 0 ))
