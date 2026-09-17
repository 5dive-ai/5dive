#!/usr/bin/env bash
# `task verifier` printed "task: command not found" on every success.
#
# THE DEFECT. cmd_task_verifier's UPDATE is a DOUBLE-QUOTED bash string handed to
# `db`, and two of the SQL `--` comment lines inside it quoted a command name in
# BACKTICKS, markdown-style. Backticks inside a double-quoted string are command
# substitution, so bash RAN `task add --verify` before sqlite3 ever saw the
# statement: one `5dive: line N: task: command not found` on stderr per call, and
# an empty string spliced into the comment. The row was written correctly and the
# exit status was 0 — which is exactly why it survived: every signal a caller
# normally reads said the verb worked.
#
# WHY A COMMENT IS NOT A HARMLESS PLACE FOR THIS. The text is inert to sqlite and
# live to bash, so the review question ("does this comment read well?") and the
# runtime question ("what does bash do with these four characters?") are asked of
# different languages. The same two lines are correct prose and a command
# substitution at once. Prose review cannot catch that; a harness can.
#
# THE ARMS, and why the mutant one is the one that matters. A clean arm alone
# proves nothing here: stderr is EMPTY on a passing run either way if the caller
# forgot to capture it. So ARM B rebuilds cmd_task_verifier from the working tree
# with the backticks PUT BACK and asserts the marker DOES appear. If B ever goes
# quiet, this file has stopped grading the defect and A's silence is worth
# nothing. B2 records the property that hid it: under the mutant, rc is still 0
# and the row is still correct.
#
# Run: bash tests/task_verifier_sql_comment_backticks_unit.sh   (no root, no network)
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE the absence of `2>/dev/null`: the helper writes its line to stderr by
# design, so hiding the source's stderr would swallow the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-verifier-backticks.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init; _tasks_db_migrate
cmd_send() { return 0; }; audit_log() { return 0; }
_task_store_audit_log() { return 0; }

# A fixture seat, enrolled, so _task_require_lane is satisfied and its own
# advisory never lands in the stderr this file grades.
cat > "$TMP/agents.json" <<'JSON'
{"agents":{"grader":{"type":"claude","heartbeat":{"enabled":true}}}}
JSON
_TASK_ROSTER=""; _TASK_ROSTER_STATE=""

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }
has_t() { if [[ "$2" == *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] lacks [$3]"; fi; }
lacks_t() { if [[ "$2" != *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] contains [$3]"; fi; }

seed() { db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status)
              VALUES ('$1','a row that needs a grader','medium','maker','main','standard','todo');"; }
field() { db "SELECT COALESCE($2,'') FROM tasks WHERE ident='$1';"; }
# BOTH STREAMS KEPT APART. The receipt is stdout and the defect is stderr; an arm
# that read them merged could not tell a receipt from a bash diagnostic.
run() { ( cmd_task_verifier "$@" ) >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?"; }

MARKER='command not found'

# ---- ARM A: the fixed function -----------------------------------------------
seed T-1
RC="$(run T-1 grader)"
eq_t  "A1: task verifier succeeds"                          "$RC" "0"
lacks_t "A2: ... and stderr carries no bash diagnostic"     "$(cat "$TMP/err")" "$MARKER"
eq_t  "A3: ... and the verifier column is set"              "$(field T-1 verifier)" "grader"
eq_t  "A4: ... and the grade demand is flagged (DIVE-4251)" "$(field T-1 verify_forced)" "1"

# ---- ARM B: THE MUTANT — backticks put back ----------------------------------
# Rebuilt from the working tree, so this grades the function on disk rather than a
# copy that can drift away from it.
awk '/^cmd_task_verifier\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SRC/task/crud.sh" >"$TMP/fn.sh"
sed -e "s/'task add --verify'/\`task add --verify\`/" \
    -e "s/'verify=never'/\`verify=never\`/" "$TMP/fn.sh" >"$TMP/mutant.sh"
# The mutation is asserted BEFORE it is relied on. If the comment text is ever
# reworded, the sed above silently no-ops and B1 would red with a confusing
# message; this arm says plainly that the mutant failed to mutate.
if grep -qE '^\s*--.*`' "$TMP/mutant.sh" && ! cmp -s "$TMP/fn.sh" "$TMP/mutant.sh"; then
  ok_t "B0: the mutant really re-introduced a backticked SQL comment"
else
  bad_t "B0: the mutant really re-introduced a backticked SQL comment" \
        "the sed did not apply — reword it to match src/task/crud.sh, or this file grades nothing"
fi

# shellcheck source=/dev/null
source "$TMP/mutant.sh"
seed T-2
RC="$(run T-2 grader)"
has_t "B1: the mutant DOES print the bash diagnostic (this file can fail)" \
      "$(cat "$TMP/err")" "$MARKER"
# Why it went unnoticed for so long: nothing a caller checks changes.
eq_t  "B2: ... while rc is STILL 0"            "$RC" "0"
eq_t  "B2b: ... and the row is STILL correct"  "$(field T-2 verifier)" "grader"

# ---- ARM C: restore, and prove A's silence was the fix and not the ordering ---
# shellcheck source=/dev/null
source "$TMP/fn.sh"
seed T-3
RC="$(run T-3 grader)"
eq_t    "C1: the restored function succeeds"        "$RC" "0"
lacks_t "C2: ... and stderr is clean again"         "$(cat "$TMP/err")" "$MARKER"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
