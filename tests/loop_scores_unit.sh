#!/usr/bin/env bash
# DIVE-5564 isolated unit harness for loop scores + the weekly suggestion:
# a finished run of a loop (a scheduled task) asks for its score (runner, or the team's
# grader), `task loop score`/`rate` record it (the owner's vote beats the score),
# `task loop review --force` asks for a change to the lowest-scoring loop, and
# `suggest`/`apply`/`dismiss`/`revert`/`auto` move the loop's instructions.
# Throwaway STATE_DIR — never touches the live tasks.db. Run: bash tests/loop_scores_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/loop-scores-unit.XXXXXX)"
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

# Two loops (scheduled tasks: one from a loop pack, one from 5dive.yaml) and a
# third made by hand, and one ordinary task that is not a loop.
mk_tpl() { db "INSERT INTO tasks (title, body, assignee, created_by, kind, schedule, status)
               VALUES ($(sqlq "$1"), $(sqlq "$2"), $(sqlq "$3"), 'owner', 'recurring', '0 9 * * *', 'todo');
               SELECT ident FROM tasks WHERE id=last_insert_rowid();"; }
A=$(mk_tpl "Daily digest" "Write the digest.

— installed loop: digest (5dive marketplace). runs on '0 9 * * *'." scout)
B=$(mk_tpl "Inbox triage" "Triage the inbox.

— declared loop: triage (5dive.yaml)" scout)
C=$(mk_tpl "Hand-made cron" "Check the prices." scout)
P=$(db "INSERT INTO tasks (title, body, assignee, created_by, status) VALUES ('One-off', 'Not a loop.', 'scout', 'owner', 'in_progress');
        SELECT ident FROM tasks WHERE id=last_insert_rowid();")
# A run = an instance cloned from the template (what the heartbeat materializer writes).
mk_run() { db "INSERT INTO tasks (title, body, assignee, created_by, kind, from_template_id, status)
               SELECT title, body, assignee, created_by, 'standard', id, 'in_progress' FROM tasks WHERE ident=$(sqlq "$1");
               SELECT ident FROM tasks WHERE id=last_insert_rowid();"; }
close_run() { ( AGENT_NAME=scout cmd_task_done "$1" --result="ran" ) >/dev/null 2>"$TMP/done.err"; }
req_for() { db "SELECT COALESCE(assignee,'')||'|'||status FROM tasks WHERE title='Score loop run $1';"; }

# T1 — a finished loop run asks the RUNNER for its score (no grader on the team).
R1=$(mk_run "$A"); close_run "$R1"
t "T1 run closed done" "done" "$(db "SELECT status FROM tasks WHERE ident='$R1';")"
t "T1 score request filed to the runner" "scout|todo" "$(req_for "$R1")"
# Closing twice (any second close path) does not file a second ask.
_loop_score_request "$(db "SELECT id FROM tasks WHERE ident='$R1';")"
t "T1 no duplicate score request" "1" "$(db "SELECT COUNT(*) FROM tasks WHERE title='Score loop run $R1';")"
# An ordinary task asks for nothing; a hand-made scheduled task is a loop too.
close_run "$P"
t "T1 one-off task: no score request" "0" "$(db "SELECT COUNT(*) FROM tasks WHERE title='Score loop run $P';")"
RC=$(mk_run "$C"); close_run "$RC"
t "T1 hand-made scheduled task's run: score request" "scout|todo" "$(req_for "$RC")"
t "T1 score request is a fresh one-turn row with no grader" "1|none" "$(db "SELECT fresh||'|'||COALESCE(review_mode,'none') FROM tasks WHERE title='Score loop run $RC';")"

# T2 — with a grader on the team, the grader is asked instead.
db "INSERT INTO agents_org(name, role) VALUES ('quinn','grader');"
R2=$(mk_run "$B"); close_run "$R2"
t "T2 score request filed to the grader" "quinn|todo" "$(req_for "$R2")"

# T3 — score + rate; the vote beats the score; validation.
out=$( cmd_task_loop_score "$R1" --score=40 --note="missed two sources" --from=scout 2>&1 )
t "T3 score recorded" "40" "$(jq -r '.data.score' <<<"$out")"
( cmd_task_loop_score "$R1" --score=101 ) >/dev/null 2>&1; t "T3 score >100 refused" "1" "$([[ $? -ne 0 ]] && echo 1)"
( cmd_task_loop_score "$P" --score=50 ) >/dev/null 2>&1;  t "T3 scoring a non-run refused" "1" "$([[ $? -ne 0 ]] && echo 1)"
( cmd_task_loop_score "$R2" --score=090 ) >/dev/null 2>&1; t "T3 zero-padded score accepted" "0" "$?"
board=$( cmd_task_loop_scores | jq -c '.data.loops' )
t "T3 board lists the three loops, not the one-off" "$A $B $C" "$(jq -r '[.[].ident]|join(" ")' <<<"$board")"
t "T3 loop A score = its run score" "40" "$(jq -r ".[]|select(.ident==\"$A\").score" <<<"$board")"
( cmd_task_loop_rate "$R2" down ) >/dev/null 2>&1
t "T3 owner thumbs-down beats the grader's 90" "0" "$(cmd_task_loop_scores | jq -r ".data.loops[]|select(.ident==\"$B\").score")"
( cmd_task_loop_rate "$R2" clear ) >/dev/null 2>&1
t "T3 clearing the vote restores the score" "90" "$(cmd_task_loop_scores | jq -r ".data.loops[]|select(.ident==\"$B\").score")"
db "DELETE FROM task_prefs WHERE key='loop.review.last';"   # the score above already ran an unforced review

# T4 — forced weekly review asks for a change to the LOWEST loop (A, 40 < 90).
db "DELETE FROM tasks WHERE title LIKE 'Suggest a change to loop %';"
out=$( cmd_task_loop_review --force 2>&1 )
t "T4 review filed for the lowest loop" "true $A" "$(jq -r '"\(.data.filed) \(.data.loop)"' <<<"$out")"
ask=$(jq -r .data.task <<<"$out")
t "T4 suggestion ask goes to the grader" "quinn" "$(db "SELECT assignee FROM tasks WHERE ident='$ask';")"
t "T4 ask carries the run's note" "1" "$(db "SELECT body LIKE '%missed two sources%' FROM tasks WHERE ident='$ask';")"
t "T4 unforced review inside the week is a no-op" "false" "$(cmd_task_loop_review | jq -r .data.filed)"
t "T4 a second forced review does not double-ask" "already asked" "$(cmd_task_loop_review --force | jq -r .data.reason)"

# T5 — suggest -> pending; dismiss; suggest again -> apply -> revert.
ORIG=$(db "SELECT body FROM tasks WHERE ident='$A';")
printf 'Write the digest. Cover every source on the list; say which ones had nothing new.\n' > "$TMP/new.txt"
out=$( cmd_task_loop_suggest "$A" --body-file="$TMP/new.txt" --reason="runs skipped sources" --from=quinn 2>&1 )
t "T5 suggestion waits for the owner" "pending" "$(jq -r .data.status <<<"$out")"
t "T5 instructions unchanged while pending" "$ORIG" "$(db "SELECT body FROM tasks WHERE ident='$A';")"
( cmd_task_loop_decide dismiss "$A" ) >/dev/null 2>&1
t "T5 dismiss" "dismissed" "$(_loop_pref_get "loop.suggest.$A" | jq -r .status)"
( cmd_task_loop_decide apply "$A" ) >/dev/null 2>&1; t "T5 apply after dismiss refused" "1" "$([[ $? -ne 0 ]] && echo 1)"
( cmd_task_loop_suggest "$A" --body-file="$TMP/new.txt" ) >/dev/null 2>&1
( cmd_task_loop_decide apply "$A" ) >/dev/null 2>&1
NEW=$(db "SELECT body FROM tasks WHERE ident='$A';")
t "T5 apply rewrote the instructions" "1" "$([[ "$NEW" == "Write the digest. Cover every source"* ]] && echo 1)"
t "T5 apply kept the loop marker (still a loop)" "1" "$(db "SELECT COUNT(*) FROM tasks WHERE ident='$A' AND ${_LOOP_TPL_PRED};")"
R3=$(mk_run "$A")
t "T5 the next run carries the new instructions" "$NEW" "$(db "SELECT body FROM tasks WHERE ident='$R3';")"
( cmd_task_loop_decide revert "$A" ) >/dev/null 2>&1
t "T5 revert restored the original instructions" "$ORIG" "$(db "SELECT body FROM tasks WHERE ident='$A';")"
( cmd_task_loop_decide revert "$A" ) >/dev/null 2>&1; t "T5 second revert refused" "1" "$([[ $? -ne 0 ]] && echo 1)"
( cmd_task_loop_suggest "$A" --body="$ORIG" ) >/dev/null 2>&1; t "T5 no-op suggestion refused" "1" "$([[ $? -ne 0 ]] && echo 1)"
( cmd_task_loop_suggest "$P" --body="x" ) >/dev/null 2>&1; t "T5 suggest on a non-loop refused" "1" "$([[ $? -ne 0 ]] && echo 1)"

# T6 — the self-improvement switch: off by default; on applies unasked.
t "T6 switch off by default" "false" "$(cmd_task_loop_scores | jq -r ".data.loops[]|select(.ident==\"$B\").auto")"
( cmd_task_loop_auto "$B" on ) >/dev/null 2>&1
t "T6 switch on" "true" "$(cmd_task_loop_scores | jq -r ".data.loops[]|select(.ident==\"$B\").auto")"
out=$( cmd_task_loop_suggest "$B" --body="Triage the inbox. Reply to anything older than a day first." 2>&1 )
t "T6 suggestion applied without asking" "applied true" "$(jq -r '"\(.data.status) \(.data.auto)"' <<<"$out")"
t "T6 instructions changed" "1" "$(db "SELECT body LIKE 'Triage the inbox. Reply%' AND body LIKE '%declared loop: triage%' FROM tasks WHERE ident='$B';")"
( cmd_task_loop_decide revert "$B" ) >/dev/null 2>&1
t "T6 revert undoes the auto-applied change" "1" "$(db "SELECT body LIKE 'Triage the inbox.%' AND body NOT LIKE '%Reply to anything%' FROM tasks WHERE ident='$B';")"
( cmd_task_loop_auto "$B" off ) >/dev/null 2>&1
( cmd_task_loop_suggest "$B" --body="Triage the inbox, newest first." ) >/dev/null 2>&1
t "T6 switch off -> back to waiting for the owner" "pending" "$(_loop_pref_get "loop.suggest.$B" | jq -r .status)"
# Turning the switch on with a suggestion waiting applies it.
out=$( cmd_task_loop_auto "$B" on 2>&1 )
t "T6 switching on applies the waiting suggestion" "true" "$(jq -r .data.applied <<<"$out")"

# T7 — a loop that already scores well gets no suggestion: A thumbs-up (100),
# B 90, C unscored -> nothing under 80, nothing filed.
( cmd_task_loop_rate "$R1" up ) >/dev/null 2>&1
db "DELETE FROM tasks WHERE title LIKE 'Suggest a change to loop %';"
t "T7 nothing under 80 -> no suggestion ask" "false|no loop needs a fix" "$(cmd_task_loop_review --force | jq -r '"\(.data.filed)|\(.data.reason)"')"
t "T7 and no row filed" "0" "$(db "SELECT COUNT(*) FROM tasks WHERE title LIKE 'Suggest a change to loop %';")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
