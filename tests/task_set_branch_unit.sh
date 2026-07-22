#!/usr/bin/env bash
# DIVE-1697 unit harness for `task set-branch` + `task add --branch`. Same
# isolation contract as task_core_unit.sh: source src/ directly, point STATE_DIR
# at a throwaway temp dir so the live shared tasks.db is NEVER touched. The key
# guarantee: what set-branch/--branch WRITES is exactly what delegated push READS,
# so we assert against cmd_push.sh's own _push_branch_from_body parser (DIVE-1462).
# Run: bash tests/task_set_branch_unit.sh   (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-set-branch-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_push.sh; do
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
# what delegated push would parse off the stored body
pushbranch() { _push_branch_from_body "$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=$1;")"; }

tasks_db_init

# --- T1: set-branch on a bodyless task writes a line push can read
id1=$(run add --assignee=alice -- "bare maker task" | jf '.data.id')
out=$(run set_branch "$id1" feat/dive-1697)
[[ "$(printf '%s' "$out" | jf '.data.branch')" == "feat/dive-1697" ]] \
  && ok_t "set-branch reports the bound branch" || bad_t "set-branch reports the bound branch" "$out"
[[ "$(pushbranch "$id1")" == "feat/dive-1697" ]] \
  && ok_t "push parser reads the branch set-branch wrote" || bad_t "push parser reads the branch set-branch wrote" "got: $(pushbranch "$id1")"

# --- T2: idempotent — re-binding replaces, never duplicates the line
run set_branch "$id1" feat/rebound >/dev/null
n=$(db "SELECT body FROM tasks WHERE id=$id1;" | grep -icP '^\s*branch:')
[[ "$(pushbranch "$id1")" == "feat/rebound" && "$n" -eq 1 ]] \
  && ok_t "re-bind replaces the line (exactly one Branch:)" || bad_t "re-bind replaces the line" "count=$n branch=$(pushbranch "$id1")"

# --- T3: existing body text is preserved when a branch is added
id2=$(run add --body="do the thing
second line" --assignee=alice -- "task with body" | jf '.data.id')
run set_branch "$id2" main >/dev/null
body2=$(db "SELECT body FROM tasks WHERE id=$id2;")
{ printf '%s' "$body2" | grep -q "second line" && [[ "$(pushbranch "$id2")" == "main" ]]; } \
  && ok_t "set-branch preserves the pre-existing body" || bad_t "set-branch preserves the pre-existing body" "$body2"

# --- T4: `task add --branch` seeds the binding at creation
id3=$(run add --branch=release/0.9 --assignee=alice -- "born with a branch" | jf '.data.id')
[[ "$(pushbranch "$id3")" == "release/0.9" ]] \
  && ok_t "task add --branch seeds the Branch line" || bad_t "task add --branch seeds the Branch line" "got: $(pushbranch "$id3")"

# --- T5: whitespace / junk branch names are rejected (push parses one \S+ token)
# In JSON_MODE the `fail` payload is emitted on stdout, so assert against it.
e5=$(run set_branch "$id1" "bad name"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$e5" | grep -q "invalid branch name" \
  && ok_t "set-branch rejects a name with whitespace" || bad_t "set-branch rejects a name with whitespace" "rc=$rc $e5"
# the rejected write left the prior binding intact
[[ "$(pushbranch "$id1")" == "feat/rebound" ]] \
  && ok_t "rejected set-branch leaves the prior binding intact" || bad_t "rejected set-branch leaves the prior binding intact" "$(pushbranch "$id1")"

# --- T6: missing branch arg -> usage error, not a silent no-op
e6=$(run set_branch "$id1"); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$e6" | grep -q "usage: 5dive task set-branch" \
  && ok_t "set-branch with no branch arg errors" || bad_t "set-branch with no branch arg errors" "rc=$rc $e6"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
