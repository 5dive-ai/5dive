#!/usr/bin/env bash
# DIVE-5507 — `5dive task followup`: the owner's follow-up from the Mini App task view.
#
# lodar, 2026-10-04: "in single task details view can be something like send follow
# up or link to chat with the task id". The exec tunnel carries `task` free text and
# refuses `agent send`, so the box gets one verb that does both halves: the text is
# appended to the row's body (it survives a fresh-context wake) and sent to the
# assignee, naming the row, with --wake and the owner's chat as the reply target.
#
# Each refusal carries its negative control: the same call on an open, assigned row
# goes through, so a refusal that widened to every row would red the happy path.
#
# Run: bash tests/task_followup_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-followup.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
REGISTRY="$TMP/registry.json"
printf '{"agents":{"dev":{},"ops":{}}}' >"$REGISTRY"
JSON_MODE=0
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init >/dev/null 2>&1

# --- stubs: nothing leaves the box -------------------------------------------
SENT="$TMP/sent"
SEND_RC=0
cmd_send() {
  { printf 'notify=%s\n' "${_5DIVE_A2A_NOTIFY:-0}"; printf '%s\n' "$@"; } >"$SENT"
  (( SEND_RC == 0 )) || { printf "tmux session 'agent-%s' not found\n" "$1" >&2; return 1; }
  return 0
}
OWNER_TG="1234567890"
_owner_ask_route() { OA_OWNER_TG="$OWNER_TG"; [[ -n "$OWNER_TG" ]]; }
_task_store_audit_log() { return 0; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }
has_t() { if [[ "$2" == *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] does not contain [$3]"; fi; }
not_t() { if [[ "$2" != *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] should not contain [$3]"; fi; }
body()  { db "SELECT COALESCE(body,'') FROM tasks WHERE ident='$1';"; }
# `fail` exits, so every call runs in a subshell.
run()   { : >"$SENT"; ( cmd_task followup "$@" ) >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?"; }

seed() { # <ident> <status> <assignee> [body]
  db "INSERT INTO tasks (ident, title, priority, assignee, created_by, status, body)
      VALUES ('$1', 'Fix the login page', 'medium', $( [[ -n "$3" ]] && sqlq "$3" || echo NULL ), 'telegram', '$2', $(sqlq "${4:-}"));"
}
seed DIVE-1 in_progress dev "Original brief."
seed DIVE-2 done dev
seed DIVE-3 todo ""
seed DIVE-4 todo lodar
seed DIVE-5 cancelled dev
seed DIVE-6 todo ops
# The seeds name their idents, so move the project counter past them: a child
# filed through `task add` takes its ident from the counter (DIVE-6157).
db "UPDATE projects SET counter=100 WHERE key='dive';"

# --- A. an open, assigned row: recorded AND sent ------------------------------
rc=$(run DIVE-1 --text="  use the staging database, not prod  " --from=telegram)
eq_t  "A1: an open assigned row exits 0" "$rc" "0"
b=$(body DIVE-1)
has_t "A2: the original body is kept" "$b" "Original brief."
has_t "A3: the follow-up is appended under a dated owner heading" "$b" "--- Follow-up from the owner, "
has_t "A4: the text lands trimmed" "$b" $'\nuse the staging database, not prod'
not_t "A5: no trailing whitespace from the input" "$b" "prod  "
s=$(cat "$SENT")
has_t "A6: the send goes to the assignee" "$(sed -n 2p "$SENT")" "dev"
has_t "A7: the message names the ident and the title" "$s" 'DIVE-1 "Fix the login page"'
has_t "A8: the message carries the text" "$s" "use the staging database, not prod"
has_t "A9: the agent is woken if idle" "$s" "--wake"
has_t "A10: the reply target is the owner's chat on that bot" "$s" "--reply-to-chat=1234567890"
has_t "A11: the sender is the principal passed in" "$s" "--from=telegram"
has_t "A12: the send rides outside the a2a round cap" "$s" "notify=1"
has_t "A13: the receipt says sent" "$(cat "$TMP/out")" "recorded and sent to dev"

# JSON mode: the Mini App reads delivered from here.
JSON_MODE=1; rc=$(run DIVE-6 --text="ship it"); JSON_MODE=0
eq_t  "A14: --json exits 0" "$rc" "0"
eq_t  "A15: --json says delivered" "$(jq -r '(.data // .) | .delivered' "$TMP/out" 2>/dev/null)" "true"
not_t "A16: no --from means no forged sender label" "$(cat "$SENT")" "--from=telegram"

# A body with nothing in it gets the note alone, no leading blank lines.
db "UPDATE tasks SET body=NULL WHERE ident='DIVE-6';"
run DIVE-6 --text="second" >/dev/null
eq_t  "A17: an empty body becomes the note alone" "$(body DIVE-6 | head -c 26)" "--- Follow-up from the own"

# Positional text is the same as --text.
run DIVE-6 just checking in >/dev/null
has_t "A18: positional words are the text" "$(body DIVE-6)" "just checking in"

# --- B. no owner route: still sent, with no reply target ----------------------
OWNER_TG=""; run DIVE-6 --text="no route" >/dev/null; OWNER_TG="1234567890"
not_t "B1: no paired owner means no --reply-to-chat" "$(cat "$SENT")" "--reply-to-chat"
has_t "B2: ... and the message still goes" "$(cat "$SENT")" "no route"
OWNER_TG=$'111\n222'; run DIVE-6 --text="two owners" >/dev/null; OWNER_TG="1234567890"
not_t "B3: two paired chats is no single reply target" "$(cat "$SENT")" "--reply-to-chat"

# --- C. the send fails: the note is still on the row, exit 0, delivered:false ---
SEND_RC=1; JSON_MODE=1
rc=$(run DIVE-6 --text="are you there")
JSON_MODE=0; SEND_RC=0
eq_t  "C1: a failed send still exits 0 (the note is the record)" "$rc" "0"
has_t "C2: ... the note is on the row" "$(body DIVE-6)" "are you there"
eq_t  "C3: ... and delivered is false" "$(jq -r '(.data // .) | .delivered' "$TMP/out" 2>/dev/null)" "false"
has_t "C4: ... with the reason" "$(cat "$TMP/out")" "not found"

# --- F. a finished row: a new child row, never a reopen (DIVE-6157) ----------
# lodar 2026-10-13: "even finished tasks should have a follow-up option". The
# finished row stays exactly as it was; the follow-up becomes a child row for
# the same assignee, carrying the text and citing the row it follows.
db "UPDATE tasks SET result='Login page fixed and deployed.' WHERE ident='DIVE-2';"
kids() { db "SELECT COUNT(*) FROM tasks WHERE parent_id=(SELECT id FROM tasks WHERE ident='$1');"; }
for spec in "DIVE-2:done" "DIVE-5:cancelled"; do
  i=${spec%%:*} st=${spec#*:}
  before=$(body "$i")
  JSON_MODE=1; rc=$(run "$i" --text="now do the same for the signup page" --from=telegram); JSON_MODE=0
  [[ "$rc" == 0 ]] || { cat "$TMP/out" "$TMP/err"; }
  eq_t  "F: a $st row exits 0" "$rc" "0"
  eq_t  "F: ... and gets exactly one child ($st)" "$(kids "$i")" "1"
  kid=$(jq -r '(.data // .) | .child' "$TMP/out" 2>/dev/null)
  eq_t  "F: ... the JSON names the child the store holds ($st)" "$kid" \
        "$(db "SELECT ident FROM tasks WHERE parent_id=(SELECT id FROM tasks WHERE ident='$i');")"
  eq_t  "F: ... the JSON says delivered ($st)" "$(jq -r '(.data // .) | .delivered' "$TMP/out" 2>/dev/null)" "true"
  eq_t  "F: ... the child goes to the same assignee ($st)" "$(db "SELECT assignee FROM tasks WHERE ident='$kid';")" "dev"
  eq_t  "F: ... the child is open ($st)" "$(db "SELECT status FROM tasks WHERE ident='$kid';")" "todo"
  has_t "F: ... the child's title names the follow-up ($st)" "$(db "SELECT title FROM tasks WHERE ident='$kid';")" "Follow-up: now do the same for the signup page"
  has_t "F: ... the child's body carries the text ($st)" "$(body "$kid")" "now do the same for the signup page"
  has_t "F: ... and cites the row it follows ($st)" "$(body "$kid")" "Follows $i: Fix the login page"
  eq_t  "F: ... the finished row's body is untouched ($st)" "$(body "$i")" "$before"
  eq_t  "F: ... and it stays $st" "$(db "SELECT status FROM tasks WHERE ident='$i';")" "$st"
  has_t "F: ... the assignee is woken ($st)" "$(cat "$SENT")" "--wake"
  has_t "F: ... and told the new ident ($st)" "$(cat "$SENT")" "filed as a new task, $kid"
  has_t "F: ... with the owner's chat as the reply target ($st)" "$(cat "$SENT")" "--reply-to-chat=1234567890"
done
has_t "F1: the done row's result is carried to the child" "$(body "$(db "SELECT ident FROM tasks WHERE parent_id=(SELECT id FROM tasks WHERE ident='DIVE-2');")")" "Its result: Login page fixed and deployed."
long=$(printf 'y%.0s' {1..80})
run DIVE-2 --text="$long" >/dev/null
has_t "F2: a long text is cut to ~60 chars in the child title" "$(db "SELECT title FROM tasks WHERE parent_id=(SELECT id FROM tasks WHERE ident='DIVE-2') ORDER BY id DESC LIMIT 1;")" "Follow-up: $(printf 'y%.0s' {1..60})…"
SEND_RC=1; JSON_MODE=1; rc=$(run DIVE-5 --text="still there?"); JSON_MODE=0; SEND_RC=0
eq_t  "F3: a failed send on a finished row still files the child and exits 0" "$rc" "0"
eq_t  "F4: ... delivered is false" "$(jq -r '(.data // .) | .delivered' "$TMP/out" 2>/dev/null)" "false"
eq_t  "F5: ... and the child is there" "$(kids DIVE-5)" "2"
db "UPDATE tasks SET status='done' WHERE ident='DIVE-3';"
rc=$(run DIVE-3 --text="hello")
[[ "$rc" != "0" ]] && ok_t "F6: a finished row with no assignee is still refused" || bad_t "F6: a finished row with no assignee is still refused" "rc=$rc"
eq_t  "F7: ... and files nothing" "$(kids DIVE-3)" "0"
db "UPDATE tasks SET status='todo' WHERE ident='DIVE-3';"

# --- D. refusals, and nothing is written ---------------------------------------
rc=$(run DIVE-3 --text="hello")
[[ "$rc" != "0" ]] && ok_t "D1: a row with no assignee is refused" || bad_t "D1: a row with no assignee is refused" "rc=$rc"
has_t "D2: ... naming the fix" "$(cat "$TMP/err")" "assign it first"
eq_t  "D3: ... and nothing is written" "$(body DIVE-3)" ""
rc=$(run DIVE-4 --text="hello")
[[ "$rc" != "0" ]] && ok_t "D4: a row assigned to a non-agent is refused" || bad_t "D4: a row assigned to a non-agent is refused" "rc=$rc"
eq_t  "D5: ... and nothing is written" "$(body DIVE-4)" ""
rc=$(run DIVE-1 --text="   ")
[[ "$rc" != "0" ]] && ok_t "D6: blank text is refused" || bad_t "D6: blank text is refused" "rc=$rc"
rc=$(run DIVE-1 --text="$(printf 'x%.0s' {1..2001})")
[[ "$rc" != "0" ]] && ok_t "D7: text over 2000 characters is refused" || bad_t "D7: text over 2000 characters is refused" "rc=$rc"
rc=$(run DIVE-1)
[[ "$rc" != "0" ]] && ok_t "D8: no text at all is refused" || bad_t "D8: no text at all is refused" "rc=$rc"

# --- E. the verb is on the task surface ---------------------------------------
has_t "E1: task --help lists followup" "$( ( cmd_task --help ) 2>&1 )" "followup <id> --text="

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
