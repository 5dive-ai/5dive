#!/usr/bin/env bash
# DIVE-2848 — `task set-title`.
#
# `set-body` has existed since DIVE-1920; the title had no equivalent, so after
# `task add` it was immutable except by a direct sqlite UPDATE that scoped-sudo
# makers cannot run. That asymmetry is the wrong way round: a body correction
# lands where a careful reader finds it, while a WRONG TITLE is what the next
# reader sees first — on the board, in the digest, in every gate alert. This
# ticket's own sibling DIVE-2846 shipped with an overstated title that only a body
# appendix retracts.
#
# Run: bash tests/task_set_title_unit.sh   (no root, no network)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-set-title.XXXXXX)"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init; _tasks_db_migrate
cmd_send() { return 0; }; audit_log() { return 0; }
AUDIT_ROWS="$TMP/audit_rows"; : >"$AUDIT_ROWS"
_task_store_audit_log() { printf '%s\n' "$*" >>"$AUDIT_ROWS"; return 0; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }
has_t() { if [[ "$2" == *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] lacks [$3]"; fi; }
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }
seed()  { db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status)
               VALUES ('$1','${2:-the original title}','medium','dev','main','standard','${3:-todo}');"; }

seed T-1
OUT=$( (cmd_task_set_title T-1 the corrected title) 2>&1 ); RC=$?
eq_t "A1: set-title rewrites the title (rc 0)" "$RC" "0"
eq_t "A1b: ... and the row carries the new title" "$(field T-1 title)" "the corrected title"
has_t "A2: the receipt names the PRIOR title, not just the new one" "$OUT" "the original title"
# The prior title is the payload of the audit row: without it the log records that
# a retitle happened and destroys the only copy of what it replaced.
has_t "A3: the audit row preserves the prior title" "$(cat "$AUDIT_ROWS")" "prior=the original title"

# A no-op must not look like an edit, or the audit trail fills with retitles that
# changed nothing and the real ones stop standing out.
: >"$AUDIT_ROWS"
OUT=$( (cmd_task_set_title T-1 the corrected title) 2>&1 ); RC=$?
eq_t "A4: setting the same title is a no-op (rc 0)" "$RC" "0"
has_t "A4b: ... and says so" "$OUT" "unchanged"
eq_t "A4c: ... and writes NO audit row" "$(wc -l < "$AUDIT_ROWS")" "0"

seed T-2 "a closed row" done
OUT=$( (cmd_task_set_title T-2 a retro edit of a closed row) 2>&1 ); RC=$?
[[ "$RC" != "0" ]] && ok_t "B1: a closed task's title is frozen" \
  || bad_t "B1: a closed task's title is frozen" "rc=$RC"
eq_t "B1b: ... and the title really was not written" "$(field T-2 title)" "a closed row"

seed T-3
OUT=$( (cmd_task_set_title T-3) 2>&1 ); RC=$?
[[ "$RC" != "0" ]] && ok_t "B2: no text is a usage error" || bad_t "B2: no text is a usage error" "rc=$RC"
OUT=$( (cmd_task_set_title T-3 "$(printf 'x%.0s' $(seq 1 210))") 2>&1 ); RC=$?
[[ "$RC" != "0" ]] && ok_t "B3: an over-long title is refused (it truncates in every renderer)" \
  || bad_t "B3: an over-long title is refused" "rc=$RC"
eq_t "B3b: ... and the row is untouched" "$(field T-3 title)" "the original title"

OUT=$( (cmd_task_set_title NOPE-99 whatever) 2>&1 ); RC=$?
[[ "$RC" != "0" ]] && ok_t "B4: an unknown task ref is refused" || bad_t "B4: an unknown task ref is refused" "rc=$RC"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
