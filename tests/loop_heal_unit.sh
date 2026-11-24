#!/usr/bin/env bash
# DIVE-9171 isolated unit harness: every loop heals itself by default.
#   (a) a run that fails once is retried ~15 min later and recovers with no owner message;
#   (b) 3 failures in a row, the retry included, pause the loop and the owner gets ONE message;
#   (c) two empty runs (`task done --empty`) on a loop that messages its owner give ONE plain line;
#   (d) the weekly improve turn changes at most one line, and never grows the text;
#   (e) a healthy run makes no model call (counted).
# Throwaway STATE_DIR — never touches the live tasks.db. Run: bash tests/loop_heal_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/loop-heal-unit.XXXXXX)"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=1
mkdir -p "$TASKS_DIR"
SENT="$TMP/sent"; NOTES="$TMP/notes"; CALLS="$TMP/ai-calls"; : > "$SENT"; : > "$NOTES"; : > "$CALLS"
cmd_send() { printf '%s\n' "$*" >> "$NOTES"; }   # the agent bus: record, never send
_task_agent_channel() { [[ "$1" != "nobot" ]]; }
_task_send_owner() { printf '%s\n---\n' "$1" >> "$SENT"; TASK_SEND_DELIVERED=1; }
# The model: count every call, answer with whatever $TMP/answer holds.
printf '#!/usr/bin/env bash\ncat >/dev/null; echo x >> %q; cat %q\n' "$CALLS" "$TMP/answer" > "$TMP/ai"; chmod +x "$TMP/ai"
export FIVEDIVE_LOOP_IMPROVE_AI="$TMP/ai" FIVEDIVE_LOOP_IMPROVE_SYNC=1
set +e
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   want: %s\n   got:  %s\n' "$1" "$2" "$3"; fi; }
tasks_db_init

ME=$(id -un)
mk_tpl() { db "INSERT INTO tasks (title, body, assignee, created_by, kind, schedule, status)
               VALUES ($(sqlq "$1"), $(sqlq "$3"), $(sqlq "$2"), 'owner', 'recurring', '0 9 * * *', 'todo');
               SELECT ident FROM tasks WHERE id=last_insert_rowid();"; }
mk_run() { db "INSERT INTO tasks (title, body, assignee, created_by, kind, from_template_id, status, started_at)
               SELECT title, body, assignee, created_by, 'standard', id, 'in_progress', datetime('now') FROM tasks WHERE ident=$(sqlq "$1");
               SELECT ident FROM tasks WHERE id=last_insert_rowid();"; }
start() { db "UPDATE tasks SET status='in_progress', started_at=datetime('now'), parked_at=NULL, wake_at=NULL WHERE ident='$1';"; }
close_ok()   { ( AGENT_NAME="$ME" cmd_task_done "$1" --result="${2:-sent the brief: 4 items}" ) >/dev/null 2>&1; }
close_fail() { ( AGENT_NAME="$ME" cmd_task_cancel "$1" --result="${2:-the site would not load}" ) >/dev/null 2>&1; }
close_empty() { ( AGENT_NAME="$ME" cmd_task_done "$1" --empty ) >/dev/null 2>&1; }
ok_run()    { local r; r=$(mk_run "$1"); close_ok "$r"; }
fail_run()  { local r; r=$(mk_run "$1"); close_fail "$r"; }
empty_run() { local r; r=$(mk_run "$1"); close_empty "$r"; }
fails()  { local v; v=$(_loop_pref_get "loop.fails.$1" | jq -r '.n // 0'); printf '%s' "${v:-0}"; }
parked() { db "SELECT status||'|'||CASE WHEN parked_at IS NULL THEN 'live' ELSE 'parked' END FROM tasks WHERE ident='$1';"; }
open_runs() { db "SELECT COUNT(*) FROM tasks WHERE from_template_id=(SELECT id FROM tasks WHERE ident='$1') AND status NOT IN ('done','cancelled');"; }
retry_of() { db "SELECT ident FROM tasks WHERE from_template_id=(SELECT id FROM tasks WHERE ident='$1') AND status NOT IN ('done','cancelled') ORDER BY id DESC LIMIT 1;"; }
sent_n() { grep -c '^---$' "$SENT"; }
calls()  { wc -l < "$CALLS" | tr -d ' '; }
loop_json() { cmd_task_ls --recurring 2>/dev/null | jq -c ".data.tasks[]|select(.ident==\"$1\")|$2"; }

BRIEF='Send the morning brief to your owner.'
L=$(mk_tpl "Morning brief" "$ME" "$BRIEF")

# A — one failure: a retry is parked for ~15 minutes, then recovers. Nobody is told.
fail_run "$L"
R=$(retry_of "$L")
t "A1 a failed run leaves one retry of the same loop" "1" "$(open_runs "$L")"
t "A1 the retry waits ~15 minutes, then the wake sweep starts it" "blocked|parked|1" \
  "$(parked "$R")|$(db "SELECT (julianday(wake_at)-julianday('now'))*1440 BETWEEN 14 AND 16 FROM tasks WHERE ident='$R';")"
t "A1 the retry carries the loop's own text and seat" "1" "$(db "SELECT body=$(sqlq "$BRIEF") AND assignee=$(sqlq "$ME") FROM tasks WHERE ident='$R';")"
t "A1 the failure still counts toward the pause" "1" "$(fails "$L")"
start "$R"; close_ok "$R"
t "A2 the retry recovered: count reset, loop running" "0|todo|live" "$(fails "$L")|$(parked "$L")"
t "A2 no owner message, no extra row" "0|0" "$(sent_n)|$(open_runs "$L")"

# B — fail, its retry fails, the next run fails: paused, exactly one message.
fail_run "$L"; R=$(retry_of "$L"); start "$R"; close_fail "$R"
t "B1 a failed retry is not retried" "0|2" "$(open_runs "$L")|$(fails "$L")"
t "B1 two failures (retry included): still running, nobody told" "todo|live|0" "$(parked "$L")|$(sent_n)"
fail_run "$L"
t "B2 the third failure pauses it" "blocked|parked" "$(parked "$L")"
t "B2 no retry once paused" "0" "$(open_runs "$L")"
t "B2 the owner got exactly one message" "1" "$(sent_n)"
t "B2 it is the paused message" "1" "$(grep -c 'is paused. It failed 3 times in a row.' "$SENT")"
( cmd_task_loop_resume "$L" ) >/dev/null 2>&1
t "B3 resume brings it back" "todo|live" "$(parked "$L")"

# B4 — heal off: no retry, the pause still works as before.
( cmd_task_loop_heal "$L" off ) >/dev/null 2>&1
fail_run "$L"
t "B4 healing off: no retry" "0|1" "$(open_runs "$L")|$(fails "$L")"
( cmd_task_loop_heal "$L" on ) >/dev/null 2>&1
ok_run "$L"

# C — two empty runs on a loop that messages its owner: ONE plain line.
: > "$SENT"
empty_run "$L"
t "C1 one empty run: quiet" "0" "$(sent_n)"
t "C1 --empty closes done with a plain result" "done|1" "$(db "SELECT status||'|'||(result LIKE '%found nothing%') FROM tasks WHERE from_template_id=(SELECT id FROM tasks WHERE ident='$L') ORDER BY id DESC LIMIT 1;")"
t "C1 an empty run is a success for the fail count" "0" "$(fails "$L")"
empty_run "$L"
t "C2 two in a row: the owner gets one line" "1" "$(sent_n)"
line=$(sed '/^---$/,$d' "$SENT")
t "C2 the line, word for word" '"Morning brief" found nothing twice in a row. It may be broken.' "$line"
t "C2 one line, no idents" "1|0" "$(wc -l <<<"$line" | tr -d ' ')|$(grep -cE '[A-Z]+-[0-9]+' <<<"$line")"
t "C2 the seat is told to check its source" "1" "$(grep -c "closed empty 2 times in a row" "$NOTES")"
t "C2 the app reads found nothing, told" "2|true" "$(loop_json "$L" '.found_nothing|"\(.runs)|\(.told)"' | tr -d '"')"
empty_run "$L"
t "C3 a third empty run sends nothing more" "1" "$(sent_n)"
ok_run "$L"
t "C4 a run with something in it ends the streak" "null" "$(loop_json "$L" '.found_nothing')"
empty_run "$L"; empty_run "$L"
t "C4 a new streak is told once more" "2" "$(sent_n)"
ok_run "$L"
I=$(mk_tpl "Index rebuild" "$ME" "Rebuild the search index from the docs folder.")
empty_run "$I"; empty_run "$I"
t "C5 a loop that does not message its owner stays quiet" "2" "$(sent_n)"
( cmd_task_loop_heal "$I" --owner=yes ) >/dev/null 2>&1
empty_run "$I"
t "C5 --owner=yes makes it count" "3" "$(sent_n)"
( cmd_task_loop_heal "$L" off ) >/dev/null 2>&1
empty_run "$L"; empty_run "$L"
t "C6 healing off: no line" "3" "$(sent_n)"
( cmd_task_loop_heal "$L" on ) >/dev/null 2>&1; ok_run "$L"
N=$(mk_tpl "Evening digest" "nobot" "Send the evening digest.")
empty_run "$N"; empty_run "$N"
t "C7 no bot: the seat gets one row with the exact line" "1" "$(db "SELECT COUNT(*) FROM tasks WHERE title='Tell your owner $N found nothing 2 times' AND body LIKE '%found nothing twice in a row. It may be broken.%';")"
plain=$(db "INSERT INTO tasks (title, created_by, status) VALUES ('one-off', 'owner', 'in_progress'); SELECT ident FROM tasks WHERE id=last_insert_rowid();")
( AGENT_NAME="$ME" cmd_task_done "$plain" --empty ) >/dev/null 2>&1; t "C8 --empty on a row that is not a loop run is refused" "1" "$([[ $? -ne 0 ]] && echo 1)"
r=$(mk_run "$L"); ( AGENT_NAME="$ME" cmd_task_cancel "$r" --empty ) >/dev/null 2>&1; t "C8 --empty on cancel is refused" "1" "$([[ $? -ne 0 ]] && echo 1)"
close_ok "$r"

# E — healthy runs make no model call, in a week or across one (the clock starts quietly).
: > "$CALLS"
W=$(mk_tpl "Daily update" "$ME" "Collect the news.
Send your owner the top 3 items.
Keep it short.
Keep it short and plain.")
for _ in 1 2 3 4 5; do ok_run "$W"; done
t "E1 five healthy runs: zero model calls" "0" "$(calls)"
t "E1 the weekly clock started" "1" "$([[ -n "$(_loop_pref_get "loop.improve.weekly_at.$W")" ]] && echo 1)"
t "E1 no rows besides the runs" "0" "$(db "SELECT COUNT(*) FROM tasks WHERE from_template_id IS NULL AND kind='standard' AND title LIKE '%$W%';")"

# D — the week is up: ONE model turn, at most one line changed, never longer.
body0=$(db "SELECT body FROM tasks WHERE ident='$W';")
week_ago() { _loop_pref_set "loop.improve.weekly_at.$W" "$(db "SELECT datetime('now','-8 days');")"; }
printf '%s' '{"criteria":[{"name":"short","score":60,"reason":"repeats itself"}],"overall":60,"proposal":{"change":"Drops the repeated line","reason":"said twice","target":"short","find":"\nKeep it short and plain.","replace":""}}' > "$TMP/answer"
week_ago; ok_run "$W"
t "D1 the week is up: exactly one model call" "1" "$(calls)"
body1=$(db "SELECT body FROM tasks WHERE ident='$W';")
t "D1 one line dropped, nothing else" "1|0" "$(diff <(printf '%s\n' "$body0") <(printf '%s\n' "$body1") | grep -c '^<')|$(diff <(printf '%s\n' "$body0") <(printf '%s\n' "$body1") | grep -c '^>')"
t "D1 the change is on trial in the improve log" "trying" "$(_loop_pref_get "loop.improve.log.$W" | jq -r 'last.status')"
ok_run "$W"
t "D1 the next run in the same week makes no call" "1" "$(calls)"
# The next week judges the trial: it scored lower, so the text goes back by itself.
printf '%s' '{"criteria":[{"name":"short","score":40,"reason":"x"}],"overall":40,"proposal":null}' > "$TMP/answer"
week_ago; ok_run "$W"
t "D2 a weekly trial that scored lower is dropped, text restored" "dropped|1" "$(_loop_pref_get "loop.improve.log.$W" | jq -r 'last.status')|$([[ "$(db "SELECT body FROM tasks WHERE ident='$W';")" == "$body0" ]] && echo 1)"
# An appended line is refused, and so is a longer rewrite.
printf '%s' '{"criteria":[{"name":"short","score":40,"reason":"x"}],"overall":40,"proposal":{"change":"Adds a sign-off","reason":"x","target":"short","find":"","replace":"End with a sign-off."}}' > "$TMP/answer"
week_ago; ok_run "$W"
t "D3 a weekly change that adds a line is refused" "refused|true" "$(_loop_pref_get "loop.improve.log.$W" | jq -r 'last | "\(.status)|\(.note | test("never add"))"')"
printf '%s' '{"criteria":[{"name":"short","score":40,"reason":"x"}],"overall":40,"proposal":{"change":"Longer wording","reason":"x","target":"short","find":"Keep it short.","replace":"Keep it short, plain and friendly, always."}}' > "$TMP/answer"
week_ago; ok_run "$W"
t "D4 a weekly change that grows the text is refused" "refused|true" "$(_loop_pref_get "loop.improve.log.$W" | jq -r 'last | "\(.status)|\(.note | test("longer"))"')"
t "D4 the text is unchanged" "1" "$([[ "$(db "SELECT body FROM tasks WHERE ident='$W';")" == "$body0" ]] && echo 1)"
t "D4 four weeks, four calls" "4" "$(calls)"
( cmd_task_loop_improve "$W" off ) >/dev/null 2>&1
week_ago; ok_run "$W"
t "D5 improve off: no weekly call" "4" "$(calls)"
week_ago; ok_run "$I"
t "D6 an internal loop has no weekly turn by default" "4" "$(calls)"
out=$(cmd_task_loop_improve "$I" weekly 2>&1)
t "D6 'improve weekly' turns it on for any loop" "true" "$(jq -r .data.weekly_improve <<<"$out")"

# H — the status verb and the app field.
out=$(cmd_task_loop_heal "$L" 2>&1)
t "H1 heal status: on, owner-facing" "true|true" "$(jq -r '"\(.data.healing)|\(.data.owner_facing)"' <<<"$out")"
t "H1 the app reads healing" "true" "$(loop_json "$L" '.healing')"
( cmd_task_loop_heal "$L" off ) >/dev/null 2>&1
t "H2 the app reads healing off" "false" "$(loop_json "$L" '.healing')"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
