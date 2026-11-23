#!/usr/bin/env bash
# DIVE-9121 isolated unit harness: a scheduled job (a loop: a recurring template)
# whose runs fail 3 times in a row pauses itself (its template is parked, so the
# materializer, which fires only status='todo' templates, skips it), the owner is
# told ONCE in that agent's chat in plain words, `task ls --recurring` carries
# failure_pause for the app, and `task loop resume` brings it back with the
# count cleared. A run that goes done resets the count.
# Throwaway STATE_DIR — never touches the live tasks.db. Run: bash tests/loop_fail_pause_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/loop-fail-pause-unit.XXXXXX)"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=1
mkdir -p "$TASKS_DIR"
SENT="$TMP/sent"; NOTES="$TMP/notes"; : > "$SENT"; : > "$NOTES"
cmd_send() { printf '%s\n' "$*" >> "$NOTES"; }   # the agent bus: record, never send
# The owner's chat: a seat with a channel takes the message; "nobot" has none.
_task_agent_channel() { [[ "$1" != "nobot" ]]; }
_task_send_owner() { printf '%s\n---\n' "$1" >> "$SENT"; TASK_SEND_DELIVERED=1; }
set +e
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   want: %s\n   got:  %s\n' "$1" "$2" "$3"; fi; }
tasks_db_init

ME=$(id -un)
mk_tpl() { db "INSERT INTO tasks (title, body, assignee, created_by, kind, schedule, status)
               VALUES ($(sqlq "$1"), 'Send the morning brief.', $(sqlq "$2"), 'owner', 'recurring', '0 9 * * *', 'todo');
               SELECT ident FROM tasks WHERE id=last_insert_rowid();"; }
mk_run() { db "INSERT INTO tasks (title, body, assignee, created_by, kind, from_template_id, status, started_at)
               SELECT title, body, assignee, created_by, 'standard', id, 'in_progress', datetime('now') FROM tasks WHERE ident=$(sqlq "$1");
               SELECT ident FROM tasks WHERE id=last_insert_rowid();"; }
ok_run()   { local r; r=$(mk_run "$1"); ( AGENT_NAME="$ME" cmd_task_done "$r" --result="sent" ) >/dev/null 2>&1; }
fail_run() { local r; r=$(mk_run "$1"); ( AGENT_NAME="$ME" cmd_task_cancel "$r" --result="${2:-DIVE-77 could not open https://mail.example.com: login expired at /home/agent-x/.state. See 3f9a2bc1}" ) >/dev/null 2>&1; }
fails()  { local v; v=$(_loop_pref_get "loop.fails.$1" | jq -r '.n // 0'); printf '%s' "${v:-0}"; }
parked() { db "SELECT status||'|'||CASE WHEN parked_at IS NULL THEN 'live' ELSE 'parked' END FROM tasks WHERE ident='$1';"; }
sent_n() { grep -c '^---$' "$SENT"; }
# The materializer's own template read (src/cmd_heartbeat.sh _hb_materialize_recurring).
fires() { db "SELECT COUNT(*) FROM tasks WHERE ident='$1' AND kind='recurring' AND schedule IS NOT NULL AND status='todo';"; }
loop_json() { cmd_task_ls --recurring 2>/dev/null | jq -c ".data.tasks[]|select(.ident==\"$1\")|.failure_pause"; }

L=$(mk_tpl "Morning brief" "$ME")

# F1 — a failure counts; a success resets the count.
fail_run "$L"; fail_run "$L"
t "F1 two failures are counted" "2" "$(fails "$L")"
ok_run "$L"
t "F1 a success resets the count" "0" "$(fails "$L")"
t "F1 nothing paused, nobody told" "todo|live|0" "$(parked "$L")|$(sent_n)"

# F2 — 2 failures in a row do not pause.
fail_run "$L"; fail_run "$L"
t "F2 two in a row: still running" "todo|live|1" "$(parked "$L")|$(fires "$L")"
t "F2 nobody told yet" "0" "$(sent_n)"
t "F2 the app sees the job, not paused" "null" "$(loop_json "$L")"
t "F2 the job is in the list" "1" "$(cmd_task_ls --recurring | jq "[.data.tasks[]|select(.ident==\"$L\")]|length")"

# F3 — a run cancelled before it ever started is a tidy-up: it counts neither way.
r=$(db "INSERT INTO tasks (title, assignee, created_by, kind, from_template_id, status)
        SELECT title, assignee, created_by, 'standard', id, 'todo' FROM tasks WHERE ident='$L';
        SELECT ident FROM tasks WHERE id=last_insert_rowid();")
( AGENT_NAME="$ME" cmd_task_cancel "$r" --result="not needed today" ) >/dev/null 2>&1
t "F3 a never-started cancel neither counts nor resets" "2|todo|live" "$(fails "$L")|$(parked "$L")"

# F4 — the third failure in a row pauses the job and tells the owner once.
fail_run "$L"
t "F4 three in a row: paused (template parked)" "blocked|parked" "$(parked "$L")"
t "F4 the materializer no longer fires it" "0" "$(fires "$L")"
t "F4 the park never wakes by itself and names the way back" "|1" "$(db "SELECT COALESCE(wake_at,'')||'|'||(park_reason LIKE '%5dive task loop resume $L%') FROM tasks WHERE ident='$L';")"
t "F4 the owner got ONE message" "1" "$(sent_n)"
msg=$(sed '/^---$/,$d' "$SENT")
t "F4 the message names the job and the count" "1" "$(grep -c '"Morning brief" is paused. It failed 3 times in a row.' <<<"$msg")"
t "F4 the message says what went wrong, in plain words" "1" "$(grep -c '^Last time: could not open https://mail.example.com: login expired at.$' <<<"$msg")"
t "F4 no task numbers, commit ids or paths in it" "0" "$(grep -cE 'DIVE-|[A-Z]+-[0-9]+|3f9a2bc1|/home/' <<<"$msg")"
t "F4 the message says how to resume" "1" "$(grep -c 'say "resume", or tap Resume in the app' <<<"$msg")"
words=$(wc -w <<<"$msg")
t "F4 under 60 words" "1" "$(( words <= 60 ))"
t "F4 the seat is told the resume verb" "1" "$(grep -c "5dive task loop resume $L" "$NOTES")"
t "F4 delivered: no fallback row" "0" "$(db "SELECT COUNT(*) FROM tasks WHERE title LIKE 'Tell your owner $L paused%';")"
t "F4 the app reads Paused, failed 3 times" "3|true" "$(loop_json "$L" | jq -r '"\(.failed)|\(.paused_at != null)"')"
t "F4 the paused job stays in the recurring list, as blocked" "blocked" "$(cmd_task_ls --recurring | jq -r ".data.tasks[]|select(.ident==\"$L\")|.status")"
t "F4 the app has the plain reason" "1" "$(loop_json "$L" | jq -r '.why' | grep -c '^could not open')"

# F5 — told once: a run still in flight that fails or succeeds changes nothing.
fail_run "$L"; ok_run "$L"
t "F5 still paused, still one message" "blocked|parked|1" "$(parked "$L")|$(sent_n)"

# F6 — resume clears the count and the next slot fires.
out=$(cmd_task_loop_resume "$L" 2>&1)
t "F6 resume unparks" "false|todo|live" "$(jq -r .data.paused <<<"$out")|$(parked "$L")"
t "F6 the materializer fires it again" "1" "$(fires "$L")"
t "F6 the count starts over" "0|null" "$(fails "$L")|$(loop_json "$L")"
t "F6 the template is listed again as a plain schedule" "todo" "$(cmd_task_ls --recurring | jq -r ".data.tasks[]|select(.ident==\"$L\")|.status")"
( cmd_task_loop_resume "$L" ) >/dev/null 2>&1; t "F6 resume on a running job is refused" "1" "$([[ $? -ne 0 ]] && echo 1)"
fail_run "$L"; fail_run "$L"
t "F6 after resume, two more failures do not pause" "todo|live|1" "$(parked "$L")|$(sent_n)"

# F7 — a plain `task unpark` is a resume too: the count starts over.
fail_run "$L"
t "F7 paused again on the third" "blocked|parked|2" "$(parked "$L")|$(sent_n)"
( cmd_task_unpark "$L" ) >/dev/null 2>&1
fail_run "$L"
t "F7 after unpark, one failure is one, not four" "1|todo|live" "$(fails "$L")|$(parked "$L")"

# F8 — no bot reaches the owner: the seat is asked, once, to send the message.
N=$(mk_tpl "Weekly report" "nobot")
fail_run "$N" "the report site was down"; fail_run "$N" "the report site was down"; fail_run "$N" "the report site was down"
t "F8 paused" "blocked|parked" "$(parked "$N")"
t "F8 the seat gets one row with the exact message" "1|nobot" "$(db "SELECT COUNT(*)||'|'||MAX(assignee) FROM tasks WHERE title='Tell your owner $N paused after 3 failed runs';")"
t "F8 the row carries the plain message and the resume verb" "1" "$(db "SELECT body LIKE '%Last time: the report site was down.%' AND body LIKE '%5dive task loop resume $N%' FROM tasks WHERE title='Tell your owner $N paused after 3 failed runs';")"

# F9 — the plain-words reducer.
t "F9 an empty result still says something" "it stopped without saying why" "$(_loop_fail_plain "")"
t "F9 only the first line and sentence" "the API said no" "$(_loop_fail_plain "the API said no. Trace follows
  at foo (bar.js:1)")"
t "F9 help names the failure resume" "1" "$(cmd_task_loop --help 2>&1 | grep -c 'paused after 3 failed runs')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
