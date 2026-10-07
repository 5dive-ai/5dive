#!/usr/bin/env bash
# DIVE-5777 isolated unit harness for outcome loops: `task loop outcome <loop>
# --cmd=` makes a number, read by the runtime as the loop's seat after each run,
# the loop's score instead of an agent's opinion; 3 days without a rise pauses the
# loop (its template is parked) and asks its lead, once, to tell the owner;
# `task loop resume`, the owner's Apply, or a plain unpark restarts it with a fresh
# 3 days; self-improvement stays off. The clock is faked by moving the stored
# `since` back, the same instant the code compares against.
# Throwaway STATE_DIR — never touches the live tasks.db. Run: bash tests/loop_outcome_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/loop-outcome-unit.XXXXXX)"
chmod 755 "$TMP"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=1
mkdir -p "$TASKS_DIR"
cmd_send() { :; }   # no agent bus in the harness
set +e
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   want: %s\n   got:  %s\n' "$1" "$2" "$3"; fi; }
tasks_db_init

# The loop's seat is the user running the harness, so the command really runs
# (as root the harness is the seat too: _loop_seat_user resolves "root").
ME=$(id -un)
mk_tpl() { db "INSERT INTO tasks (title, body, assignee, created_by, kind, schedule, status)
               VALUES ($(sqlq "$1"), 'Post the listing.', $(sqlq "$2"), 'owner', 'recurring', '0 9 * * *', 'todo');
               SELECT ident FROM tasks WHERE id=last_insert_rowid();"; }
mk_run() { db "INSERT INTO tasks (title, body, assignee, created_by, kind, from_template_id, status)
               SELECT title, body, assignee, created_by, 'standard', id, 'in_progress' FROM tasks WHERE ident=$(sqlq "$1");
               SELECT ident FROM tasks WHERE id=last_insert_rowid();"; }
run_once() { local r; r=$(mk_run "$1"); ( AGENT_NAME="$ME" cmd_task_done "$r" --result="ran" ) >/dev/null 2>&1; printf '%s' "$r"; }
st() { _loop_pref_get "loop.outcome.$1"; }
days_ago() { db "SELECT datetime('now', '-$1 days');"; }
rewind() { _loop_pref_set "loop.outcome.$1" "$(st "$1" | jq -c --arg s "$(days_ago "$2")" '.since=$s')"; }
tell_rows() { db "SELECT COUNT(*) FROM tasks WHERE title='Tell your owner loop $1 paused itself';"; }
parked() { db "SELECT status||'|'||CASE WHEN parked_at IS NULL THEN 'live' ELSE 'parked' END FROM tasks WHERE ident='$1';"; }
COUNT="$TMP/signups"; echo 4 > "$COUNT"; chmod 644 "$COUNT"

L=$(mk_tpl "Lane: reddit" "$ME")

# O1 — setting the command: self-improvement goes off, a baseline is pending.
_loop_pref_set "loop.auto.$L" on
out=$( cmd_task_loop_outcome "$L" --cmd="cat $COUNT" 2>&1 )
t "O1 outcome set" "cat $COUNT" "$(jq -r .data.outcome.cmd <<<"$out")"
t "O1 self-improvement switched off" "" "$(_loop_pref_get "loop.auto.$L")"
( cmd_task_loop_auto "$L" on ) >/dev/null 2>&1; t "O1 self-improvement refused on an outcome loop" "1" "$([[ $? -ne 0 ]] && echo 1)"
t "O1 --check reads the number now" "4" "$(cmd_task_loop_outcome "$L" --check | jq -r .data.value)"
( cmd_task_loop_outcome "$L" ) >/dev/null 2>&1; t "O1 bare outcome is a usage error" "1" "$([[ $? -ne 0 ]] && echo 1)"

# O2 — a finished run is scored by the number; nobody is asked for an opinion.
R1=$(run_once "$L")
t "O2 the run's score is the number" "4|outcome" "$(_loop_pref_get "loop.score.$R1" | jq -r '"\(.outcome)|\(.by)"')"
t "O2 no opinion score asked" "0" "$(db "SELECT COUNT(*) FROM tasks WHERE title='Score loop run $R1';")"
t "O2 first reading is the baseline, not a rise" "4|$(st "$L" | jq -r .set_at)" "$(st "$L" | jq -r '"\(.best)|\(.since)"')"
t "O2 board shows the number, no opinion score" "4|null|false" "$(cmd_task_loop_scores | jq -r ".data.loops[]|select(.ident==\"$L\")|\"\(.outcome.last)|\(.score)|\(.paused)\"")"

# O3 — a rise moves the window; flat for 2 days is not yet 3.
rewind "$L" 5; echo 6 > "$COUNT"; run_once "$L" >/dev/null
t "O3 a rise restarts the 3 days, even after 5 flat ones" "6|live" "$(st "$L" | jq -r .best)|$(parked "$L" | cut -d'|' -f2)"
t "O3 since is now" "1" "$(db "SELECT julianday('now') - julianday($(sqlq "$(st "$L" | jq -r .since)")) < 0.01;")"
rewind "$L" 2; run_once "$L" >/dev/null
t "O3 flat for 2 days: still running" "todo|live" "$(parked "$L")"
echo 5 > "$COUNT"; rewind "$L" 2; run_once "$L" >/dev/null
t "O3 a fall is not a rise" "6|5" "$(st "$L" | jq -r '"\(.best)|\(.last)"')"

# O4 — flat for 3 days: the loop pauses itself and the lead is told once.
rewind "$L" 3; run_once "$L" >/dev/null
t "O4 paused: template parked (the materializer skips it)" "blocked|parked" "$(parked "$L")"
t "O4 the park never wakes by itself" "" "$(db "SELECT COALESCE(wake_at,'') FROM tasks WHERE ident='$L';")"
t "O4 the park names the way back" "1" "$(db "SELECT park_reason LIKE '%5dive task loop resume $L%' FROM tasks WHERE ident='$L';")"
t "O4 the lead is asked to tell the owner" "1|$ME|high" "$(tell_rows "$L")|$(db "SELECT assignee||'|'||priority FROM tasks WHERE title='Tell your owner loop $L paused itself';")"
t "O4 the ask carries the number and the resume verb" "1" "$(db "SELECT body LIKE '%stayed at 5 for 3 days%' AND body LIKE '%5dive task loop resume $L%' FROM tasks WHERE title='Tell your owner loop $L paused itself';")"
t "O4 a paused loop scores 0, the lowest" "0|true" "$(cmd_task_loop_scores | jq -r ".data.loops[]|select(.ident==\"$L\")|\"\(.score)|\(.paused)\"")"
JSON_MODE=0 cmd_task_loop_scores > "$TMP/board.txt" 2>&1
t "O4 the board line says PAUSED" "1" "$(grep -c "$L  outcome 5 PAUSED" "$TMP/board.txt")"
# A run still in flight when it paused closes without a second ask.
run_once "$L" >/dev/null
t "O4 told once: a later close files no second ask" "1" "$(tell_rows "$L")"

# O5 — the weekly review picks the paused loop and asks for a different lane.
db "DELETE FROM task_prefs WHERE key='loop.review.last';"
out=$( cmd_task_loop_review --force 2>&1 )
t "O5 review picks the paused loop" "true $L" "$(jq -r '"\(.data.filed) \(.data.loop)"' <<<"$out")"
t "O5 the ask says why and asks for a different lane" "1" "$(db "SELECT body LIKE '%paused itself%' AND body LIKE '%a different lane%' FROM tasks WHERE ident='$(jq -r .data.task <<<"$out")';")"

# O6 — the owner's Apply on the suggestion is the redirect: it resumes the loop.
( cmd_task_loop_suggest "$L" --body="Post the listing on a different board." ) >/dev/null 2>&1
t "O6 suggestion waits for the owner (no self-improvement)" "pending" "$(_loop_pref_get "loop.suggest.$L" | jq -r .status)"
out=$( cmd_task_loop_decide apply "$L" 2>&1 )
t "O6 apply resumes the paused loop" "true|todo|live" "$(jq -r .data.resumed <<<"$out")|$(parked "$L")"
t "O6 with a fresh 3 days" "|1" "$(st "$L" | jq -r '.paused_at // ""')|$(db "SELECT julianday('now') - julianday($(sqlq "$(st "$L" | jq -r .since)")) < 0.01;")"

# O7 — task loop resume: the owner's tap.
rewind "$L" 4; run_once "$L" >/dev/null
t "O7 paused again after 3 more flat days" "blocked|parked" "$(parked "$L")"
db "UPDATE tasks SET status='done' WHERE title='Tell your owner loop $L paused itself';"
out=$( cmd_task_loop_resume "$L" 2>&1 )
t "O7 resume unparks" "false|todo|live" "$(jq -r .data.paused <<<"$out")|$(parked "$L")"
( cmd_task_loop_resume "$L" ) >/dev/null 2>&1; t "O7 resume on a running loop refused" "1" "$([[ $? -ne 0 ]] && echo 1)"

# O8 — a plain `task unpark` is a resume too: the next reading starts a fresh
# window instead of pausing it again at once.
rewind "$L" 4; run_once "$L" >/dev/null
t "O8 paused" "blocked|parked" "$(parked "$L")"
( cmd_task_unpark "$L" ) >/dev/null 2>&1
run_once "$L" >/dev/null
t "O8 unparked by hand: not re-paused by the next run" "todo|live|" "$(parked "$L")|$(st "$L" | jq -r '.paused_at // ""')"
t "O8 the second pause filed its own ask (the first was closed)" "2" "$(tell_rows "$L")"

# O9 — a command that fails or prints no number is not a rise: the clock runs on.
M=$(mk_tpl "Lane: broken" "$ME")
( cmd_task_loop_outcome "$M" --cmd="echo no number here" ) >/dev/null 2>&1
R=$(run_once "$M")
t "O9 a non-number is recorded as no reading" "null" "$(_loop_pref_get "loop.score.$R" | jq -r .outcome)"
( cmd_task_loop_outcome "$M" --check ) >/dev/null 2>&1; t "O9 --check fails on no number" "1" "$([[ $? -ne 0 ]] && echo 1)"
rewind "$M" 3; run_once "$M" >/dev/null
t "O9 a broken command for 3 days pauses the loop" "blocked|parked" "$(parked "$M")"
( cmd_task_loop_outcome "$M" --cmd="printf '007\n'" ) >/dev/null 2>&1
t "O9 a zero-padded number reads as a number" "7" "$(cmd_task_loop_outcome "$M" --check | jq -r .data.value)"

# O10 — it runs in the seat's home, and only ever as the loop's seat.
H=$(mk_tpl "Lane: home" "$ME")
( cmd_task_loop_outcome "$H" --cmd='[ "$PWD" = "$HOME" ] && echo 1 || echo 0' ) >/dev/null 2>&1
t "O10 the command runs in the seat's home" "1" "$(cmd_task_loop_outcome "$H" --check | jq -r .data.value)"
S=$(mk_tpl "Lane: someone else" "nosuchseat-5777")
if [[ "$EUID" != "0" ]]; then
  ( cmd_task_loop_outcome "$S" --cmd="echo 1" ) >/dev/null 2>&1
  t "O10 another seat may not plant a command on this loop" "1" "$([[ $? -ne 0 ]] && echo 1)"
  t "O10 nothing stored" "" "$(st "$S")"
fi
_loop_pref_set "loop.outcome.$S" "$(jq -cn --arg n "$(days_ago 4)" '{cmd:"echo 1", set_at:$n, since:$n, best:null}')"
t "O10 a command is never run as a seat it cannot become" "125" "$(_loop_outcome_read nosuchseat-5777 'echo 1' | cut -d'|' -f2)"

# O11 — --clear goes back to opinion scores.
( cmd_task_loop_outcome "$H" --clear ) >/dev/null 2>&1
R=$(run_once "$H")
t "O11 cleared: the next run asks for an opinion score again" "1" "$(db "SELECT COUNT(*) FROM tasks WHERE title='Score loop run $R';")"

# O12 — help names the field (task loop --help, and 5dive loop help).
t "O12 task loop help names outcome and resume" "1|1" "$(cmd_task_loop --help | grep -c 'loop outcome <loop> --cmd=')|$(cmd_task_loop --help | grep -c 'loop resume <loop>')"
t "O12 5dive loop help points at it" "1" "$(_loop_help | grep -c 'task loop outcome <loop> --cmd=')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
