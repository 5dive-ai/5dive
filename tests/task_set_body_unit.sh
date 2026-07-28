#!/usr/bin/env bash
# DIVE-1920 unit harness for `task set-body`. Same isolation contract as
# task_set_branch_unit.sh: source src/ directly, point STATE_DIR at a
# throwaway temp dir so the live shared tasks.db is NEVER touched.
# Run: bash tests/task_set_body_unit.sh   (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-set-body-unit.XXXXXX)"
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
bodyof() { db "SELECT COALESCE(body,'') FROM tasks WHERE id=$1;"; }

tasks_db_init

# --- T1: set-body on a bodyless task writes the text
id1=$(run add --assignee=alice -- "bare maker task" | jf '.data.id')
out=$(run set_body "$id1" "here is the missing context")
[[ "$(printf '%s' "$out" | jf '.data.mode')" == "replaced" ]] \
  && ok_t "set-body reports mode=replaced" || bad_t "set-body reports mode=replaced" "$out"
[[ "$(bodyof "$id1")" == "here is the missing context" ]] \
  && ok_t "set-body writes the body" || bad_t "set-body writes the body" "got: $(bodyof "$id1")"

# --- T2: default overwrites, not appends
run set_body "$id1" "replacement text" >/dev/null
[[ "$(bodyof "$id1")" == "replacement text" ]] \
  && ok_t "set-body (no --append) overwrites the prior body" || bad_t "set-body overwrites" "got: $(bodyof "$id1")"

# --- T3: --append tacks onto the existing body without clobbering it
run set_body "$id1" "an addendum" --append >/dev/null
b3=$(bodyof "$id1")
{ printf '%s' "$b3" | grep -q "replacement text" && printf '%s' "$b3" | grep -q "an addendum"; } \
  && ok_t "set-body --append preserves the prior body and adds the new text" \
  || bad_t "set-body --append preserves + adds" "$b3"

# --- T4: --append on an empty body just writes the text (no leading blank lines)
id2=$(run add --assignee=alice -- "another bare task" | jf '.data.id')
run set_body "$id2" "first finding" --append >/dev/null
[[ "$(bodyof "$id2")" == "first finding" ]] \
  && ok_t "set-body --append on an empty body writes plain text" || bad_t "set-body --append on empty body" "got: $(bodyof "$id2")"

# --- T5: works on recurring templates (the DIVE-176 case)
tid=$(run add --recurring="0 2 * * *" --assignee=alice -- "nightly template" | jf '.data.id')
run set_body "$tid" "template instructions live here" >/dev/null
[[ "$(bodyof "$tid")" == "template instructions live here" ]] \
  && ok_t "set-body works on a recurring template" || bad_t "set-body on recurring template" "got: $(bodyof "$tid")"

# --- T6: refused on a closed (done) task
id4=$(run add --assignee=alice --no-verify -- "closeable task" | jf '.data.id')
run done "$id4" >/dev/null
e6=$(run set_body "$id4" "too late"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$e6" | grep -q "already done" \
  && ok_t "set-body refuses a closed (done) task" || bad_t "set-body refuses a closed task" "rc=$rc $e6"
[[ "$(bodyof "$id4")" != "too late" ]] \
  && ok_t "rejected set-body left the closed task's body untouched" || bad_t "rejected set-body left body untouched" "$(bodyof "$id4")"

# --- T7: missing text arg -> usage error, not a silent no-op
e7=$(run set_body "$id1"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$e7" | grep -q "usage: 5dive task set-body" \
  && ok_t "set-body with no text errors" || bad_t "set-body with no text errors" "rc=$rc $e7"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
