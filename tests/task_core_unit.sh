#!/usr/bin/env bash
# OSS-7 isolated unit harness for the task-core verbs — the most-used surface
# that had no coverage (only the loop/gate slices were tested). Same isolation
# contract as the loop harnesses: source src/ directly, point STATE_DIR at a
# throwaway temp dir so the live shared tasks.db is NEVER touched. Asserts:
# project ident minting, add/show round-trip, the status lifecycle
# (start/done/cancel/block/park), decision need/answer, recurring templates,
# ls filters, and validation rejections.
# Run: bash tests/task_core_unit.sh   (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-core-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; tests expect non-zero exits

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run() { local verb="$1"; shift; ( "cmd_task_$verb" "$@" ) 2>"$TMP"/err; }
jf()  { jq -r "$1" 2>/dev/null; }

tasks_db_init

# --- T1: add mints DIVE-N idents from the per-project counter
id1=$(run add --assignee=alice -- "first task" | jf '.data.id')
ident1=$(db "SELECT ident FROM tasks WHERE id=$id1;")
id2=$(run add -- "second task" | jf '.data.id')
ident2=$(db "SELECT ident FROM tasks WHERE id=$id2;")
n1=${ident1#DIVE-}; n2=${ident2#DIVE-}
[[ "$ident1" == DIVE-* && "$ident2" == DIVE-* && "$n2" -eq $((n1 + 1)) ]] \
  && ok_t "sequential DIVE-N idents ($ident1, $ident2)" || bad_t "ident mint" "got $ident1 / $ident2"

# --- T2: project add + tasks in it mint PREFIX-1, PREFIX-2
( cmd_project_add frog --prefix=FROG --name="Frog" ) >/dev/null 2>"$TMP"/err
pid1=$(run add --project=frog -- "frog one" | jf '.data.ident')
pid2=$(run add --project=frog -- "frog two" | jf '.data.ident')
[[ "$pid1" == "FROG-1" && "$pid2" == "FROG-2" ]] \
  && ok_t "per-project counter (FROG-1, FROG-2)" || bad_t "project idents" "got $pid1 / $pid2"

# --- T3: show round-trips body/priority/assignee
id3=$(run add --assignee=bob --priority=high --body="the body" -- "show me" | jf '.data.id')
row=$(run show "$id3")
[[ "$(echo "$row" | jf '.data.task.title')" == "show me" && \
   "$(echo "$row" | jf '.data.task.priority')" == "high" && \
   "$(echo "$row" | jf '.data.task.assignee')" == "bob" && \
   "$(echo "$row" | jf '.data.task.body')" == "the body" ]] \
  && ok_t "add/show round-trip (title/priority/assignee/body)" || bad_t "round-trip" "$row"

# --- T4: lifecycle start -> in_progress -> done (+result), done_at stamped
run start "$id3" >/dev/null
st=$(db "SELECT status FROM tasks WHERE id=$id3;")
run done "$id3" --result="all good" >/dev/null
st2=$(db "SELECT status FROM tasks WHERE id=$id3;")
res=$(db "SELECT result FROM tasks WHERE id=$id3;")
da=$(db "SELECT done_at IS NOT NULL FROM tasks WHERE id=$id3;")
[[ "$st" == "in_progress" && "$st2" == "done" && "$res" == "all good" && "$da" == "1" ]] \
  && ok_t "lifecycle start->done with result + done_at" || bad_t "lifecycle" "st=$st st2=$st2 res=$res"

# --- T5: cancel is terminal with done_at
idc=$(run add -- "doomed" | jf '.data.id')
run cancel "$idc" --result="not needed" >/dev/null
[[ "$(db "SELECT status FROM tasks WHERE id=$idc;")" == "cancelled" && \
   "$(db "SELECT done_at IS NOT NULL FROM tasks WHERE id=$idc;")" == "1" ]] \
  && ok_t "cancel -> cancelled + done_at" || bad_t "cancel" "$(db "SELECT status FROM tasks WHERE id=$idc;")"

# --- T6: block --by creates a dep edge; unblock clears deps and restores todo
idb=$(run add -- "blocked task" | jf '.data.id')
idby=$(run add -- "the blocker" | jf '.data.id')
run block "$idb" --by="$idby" >/dev/null
stb=$(db "SELECT status FROM tasks WHERE id=$idb;")
dep=$(db "SELECT COUNT(*) FROM task_deps WHERE task_id=$idb AND blocked_by=$idby;")
run unblock "$idb" >/dev/null
stu=$(db "SELECT status FROM tasks WHERE id=$idb;")
depu=$(db "SELECT COUNT(*) FROM task_deps WHERE task_id=$idb;")
[[ "$stb" == "blocked" && "$dep" == "1" && "$stu" == "todo" && "$depu" == "0" ]] \
  && ok_t "block --by dep edge / unblock round-trip" || bad_t "block" "blocked=$stb dep=$dep unblocked=$stu depu=$depu"

# --- T7: decision need blocks the task and records the gate shape
idn=$(run add -- "needs a call" | jf '.data.id')
run need "$idn" --type=decision --ask="A or B?" --options="A|B" --recommend="A" >/dev/null
[[ "$(db "SELECT status FROM tasks WHERE id=$idn;")" == "blocked" && \
   "$(db "SELECT need_type FROM tasks WHERE id=$idn;")" == "decision" && \
   "$(db "SELECT need_options FROM tasks WHERE id=$idn;")" == "A|B" ]] \
  && ok_t "decision need -> blocked with gate shape" || bad_t "need" "$(db "SELECT status,need_type FROM tasks WHERE id=$idn;")"

# --- T8: decision answer unblocks (agent-clearable type) and stores the value
run answer "$idn" --value="A" >/dev/null
[[ "$(db "SELECT status FROM tasks WHERE id=$idn;")" == "todo" && \
   "$(db "SELECT need_answer FROM tasks WHERE id=$idn;")" == "A" ]] \
  && ok_t "decision answer -> unblocked, value stored" || bad_t "answer" "$(db "SELECT status,need_answer FROM tasks WHERE id=$idn;")"

# --- T9: need rejects --options on non-decision types
ida=$(run add -- "approval shaped" | jf '.data.id')
run need "$ida" --type=approval --ask="ok?" --options="A|B" >/dev/null 2>&1
[[ $? -ne 0 ]] && ok_t "--options rejected on approval gate" || bad_t "options guard" "exit 0"

# --- T10: park stores wake_at + park_reason; unpark clears them
idp=$(run add -- "sleepy" | jf '.data.id')
run park "$idp" --wake="2030-01-01" --reason="waiting on winter" >/dev/null
pw=$(db "SELECT wake_at IS NOT NULL FROM tasks WHERE id=$idp;")
run unpark "$idp" >/dev/null
[[ "$pw" == "1" && "$(db "SELECT status FROM tasks WHERE id=$idp;")" == "todo" ]] \
  && ok_t "park --wake / unpark round-trip" || bad_t "park" "wake_set=$pw status=$(db "SELECT status FROM tasks WHERE id=$idp;")"

# --- T11: recurring add creates a template, listed by ls --recurring only
idr=$(run add --recurring="0 2 * * *" -- "nightly job" | jf '.data.id')
kind=$(db "SELECT kind FROM tasks WHERE id=$idr;")
rec_seen=$(run ls --recurring | jf '.data.tasks | map(.id) | index('"$idr"') != null')
open_seen=$(run ls | jf '.data.tasks | map(.id) | index('"$idr"') != null')
[[ "$kind" == "recurring" && "$rec_seen" == "true" && "$open_seen" == "false" ]] \
  && ok_t "recurring template hidden from open ls, shown by --recurring" \
  || bad_t "recurring" "kind=$kind rec=$rec_seen open=$open_seen"

# --- T12: ls --assignee filter
seen=$(run ls --assignee=alice | jf '.data.tasks | map(.id) | index('"$id1"') != null')
other=$(run ls --assignee=alice | jf '.data.tasks | map(.id) | index('"$id2"') != null')
[[ "$seen" == "true" && "$other" == "false" ]] \
  && ok_t "ls --assignee filters" || bad_t "ls filter" "seen=$seen other=$other"

# --- T13: validation — bad priority and unknown id rejected
run add --priority=ludicrous -- "nope" >/dev/null 2>&1
rc1=$?
run done 999999 >/dev/null 2>&1
rc2=$?
[[ $rc1 -ne 0 && $rc2 -ne 0 ]] \
  && ok_t "bad priority + unknown id rejected" || bad_t "validation" "rc1=$rc1 rc2=$rc2"

# --- T14: ident resolution — verbs accept DIVE-N as well as raw id
idz=$(run add -- "by ident" | jf '.data.id')
identz=$(db "SELECT ident FROM tasks WHERE id=$idz;")
run start "$identz" >/dev/null
[[ "$(db "SELECT status FROM tasks WHERE id=$idz;")" == "in_progress" ]] \
  && ok_t "verbs resolve DIVE-N idents ($identz)" || bad_t "ident resolve" "$(db "SELECT status FROM tasks WHERE id=$idz;")"

# --- T15: DIVE-969 verifier-by-default posture
# Stand up a coordinator so a grader distinct from the maker can be resolved.
( cmd_org_set carol --role=coordinator ) >/dev/null 2>"$TMP"/err
# non-trivial task (has a body) assigned to a different agent → verifier defaulted
vd=$(run add --assignee=alice --body="real work here" -- "build the widget pipeline")
[[ "$(echo "$vd" | jf '.data.verifyDefaulted')" == "true" && \
   "$(echo "$vd" | jf '.data.verifier')" == "carol" ]] \
  && ok_t "non-trivial task gets a default grader (carol != alice)" \
  || bad_t "verify default" "vd=$(echo "$vd" | jf '.data.verifyDefaulted') v=$(echo "$vd" | jf '.data.verifier')"
vdid=$(echo "$vd" | jf '.data.id')
[[ -n "$(db "SELECT acceptance_criteria FROM tasks WHERE id=$vdid;")" ]] \
  && ok_t "default engages derived acceptance_criteria" || bad_t "default accept" "empty"

# --no-verify opts out: no verifier, no acceptance criteria
nov=$(run add --assignee=alice --no-verify --body="real work" -- "another non-trivial job")
novid=$(echo "$nov" | jf '.data.id')
[[ "$(echo "$nov" | jf '.data.verifyDefaulted')" == "false" && \
   -z "$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=$novid;")" ]] \
  && ok_t "--no-verify opts out of the default" || bad_t "no-verify" "verifier=$(db "SELECT verifier FROM tasks WHERE id=$novid;")"

# trivial chore (bodyless, mechanical title) skips the default silently
triv=$(run add --assignee=alice -- "fix typo in readme")
[[ "$(echo "$triv" | jf '.data.verifyDefaulted')" == "false" ]] \
  && ok_t "trivial chore skips the verifier default" || bad_t "trivial skip" "$(echo "$triv" | jf '.data.verifyDefaulted')"

# low priority is trivial regardless of body
lowp=$(run add --assignee=alice --priority=low --body="some work" -- "nice to have")
[[ "$(echo "$lowp" | jf '.data.verifyDefaulted')" == "false" ]] \
  && ok_t "low-priority task skips the verifier default" || bad_t "low-prio skip" "$(echo "$lowp" | jf '.data.verifyDefaulted')"

# explicit --verifier is respected (not overridden) and stays engaged
expl=$(run add --assignee=alice --verifier=dave --body="work" -- "explicit grader task")
[[ "$(echo "$expl" | jf '.data.verifier')" == "dave" ]] \
  && ok_t "explicit --verifier is preserved" || bad_t "explicit verifier" "$(echo "$expl" | jf '.data.verifier')"

# no distinct grader available (assignee IS the only coordinator) → silent no-op
selfg=$(run add --assignee=carol --body="work" -- "carol's own task")
[[ "$(echo "$selfg" | jf '.data.verifyDefaulted')" == "false" ]] \
  && ok_t "no self-grading when maker is the only grader" || bad_t "self-grade guard" "$(echo "$selfg" | jf '.data.verifyDefaulted')"

echo "-----"
echo "task_core_unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
