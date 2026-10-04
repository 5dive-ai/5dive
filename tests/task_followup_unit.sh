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

# --- D. refusals, and nothing is written ---------------------------------------
for spec in "DIVE-2:done" "DIVE-5:cancelled"; do
  i=${spec%%:*} st=${spec#*:}
  before=$(body "$i")
  rc=$(run "$i" --text="hello")
  [[ "$rc" != "0" ]] && ok_t "D: a $st row is refused" || bad_t "D: a $st row is refused" "rc=$rc"
  eq_t  "D: ... and its body is untouched ($st)" "$(body "$i")" "$before"
  eq_t  "D: ... and nothing is sent ($st)" "$(cat "$SENT")" ""
done
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
