#!/usr/bin/env bash
# DIVE-5815 isolated unit harness: a loop with no outcome command is scored by
# the RUNTIME from signals (errors, unfinished, owner complaint, rework), with no
# "Score loop run" row and no human. A complaint only lowers, only inside 24h.
# Throwaway STATE_DIR — never touches the live tasks.db. Run: bash tests/loop_runtime_score_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/loop-runtime-score-unit.XXXXXX)"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=1
mkdir -p "$TASKS_DIR"
# The harness's own registry: quinn is a seat, lodar is not. Without this the
# host's registry (or CI's lack of one) decides who is a person.
REGISTRY="$TMP/registry.json"
printf '{"agents":{"quinn":{"isolation":"user"}}}' >"$REGISTRY"
cmd_send() { :; }   # no agent bus in the harness
# The Decisions call, stubbed: the harness never spends. RX_CHOICE/RX_CONF set the answer.
RX_ON=false; RX_CHOICE=neutral; RX_CONF=0.9; RX_CALLS=0
reflex_configured() { printf '%s' "$RX_ON"; }
reflex_model_resolve() { _REFLEX_MODEL=stub/model; }
_reflex_endpoint_decide() { cat >"$TMP/rx.req"; echo $((RX_CALLS+1)) >"$TMP/rx.calls"
  jq -cn --arg c "$RX_CHOICE" --argjson f "$RX_CONF" '{choice:$c, confidence:$f}'; }
set +e
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   want: %s\n   got:  %s\n' "$1" "$2" "$3"; fi; }
tasks_db_init

mk_tpl() { db "INSERT INTO tasks (title, body, assignee, created_by, kind, schedule, status)
               VALUES ($(sqlq "$1"), 'Do the job.', 'scout', 'owner', 'recurring', '0 9 * * *', 'todo');
               SELECT ident FROM tasks WHERE id=last_insert_rowid();"; }
mk_run() { db "INSERT INTO tasks (title, body, assignee, created_by, kind, from_template_id, status)
               SELECT title, body, assignee, created_by, 'standard', id, 'in_progress' FROM tasks WHERE ident=$(sqlq "$1");
               SELECT ident FROM tasks WHERE id=last_insert_rowid();"; }
idof() { db "SELECT id FROM tasks WHERE ident='$1';"; }
close_run() { ( AGENT_NAME=scout cmd_task_done "$1" --result="ran" ) >/dev/null 2>"$TMP/done.err"; }
cancel_run() { ( AGENT_NAME=scout cmd_task_cancel "$1" --result="source site was down" ) >/dev/null 2>"$TMP/cancel.err"; }
score() { _loop_pref_get "loop.score.$1" | jq -r "${2:-.score}"; }
rows() { db "SELECT COUNT(*) FROM tasks WHERE title LIKE 'Score loop run %';"; }
db "INSERT INTO agents_org(name, role) VALUES ('scout','member'), ('quinn','grader');"
L=$(mk_tpl "Daily digest")
M=$(mk_tpl "Price watch")

# S1 — a run that errored: scored low, the note names the error, no row.
R=$(mk_run "$L")
db "INSERT INTO runs (id, task_id, ident, agent, status, outcome, error_class, error_summary)
    VALUES ('run-e1', $(idof "$R"), '$R', 'scout', 'failed', 'process_exit', 'tool_error', 'curl: (22) 500 from the feed');"
close_run "$R"
t "S1 errored run scored low" "30" "$(score "$R")"
t "S1 note names the error" "error: tool_error: curl: (22) 500 from the feed" "$(score "$R" .note)"
t "S1 written by the runtime" "runtime" "$(score "$R" .by)"
t "S1 no Score loop run row" "0" "$(rows)"
RE=$R

# S2 — an attempt that stopped mid-run (reclaimed): also an error.
R=$(mk_run "$L")
db "INSERT INTO runs (id, task_id, ident, agent, status, outcome, error_class)
    VALUES ('run-a1', $(idof "$R"), '$R', 'scout', 'abandoned', 'reclaimed_to_todo', 'stall');"
close_run "$R"
t "S2 stopped-mid-run scored low" "30|error: stopped mid-run (reclaimed_to_todo, stall)" "$(score "$R" '"\(.score)|\(.note)"')"

# S3 — a cancelled run did not end done.
R=$(mk_run "$L"); cancel_run "$R"
t "S3 cancelled run scored lowest" "10|did not finish: cancelled (source site was down)" "$(score "$R" '"\(.score)|\(.note)"')"

# S4 — a clean run scores 80, no row.
R=$(mk_run "$L"); close_run "$R"; RC=$R
t "S4 clean run scored 80" "80|clean run|runtime" "$(score "$R" '"\(.score)|\(.note)|\(.by)"')"
t "S4 no Score loop run row" "0" "$(rows)"

# S5 — an owner reply inside the window lowers an already-scored run.
out=$(cmd_task_loop_feedback "$RC" --text="this is wrong, half the sources are missing" 2>&1)
t "S5 keyword complaint lowers 80 -> 20" "true|keyword|20" "$(jq -r '"\(.data.lowered)|\(.data.by)|\(.data.score)"' <<<"$out")"
t "S5 note names the complaint" "owner complained: this is wrong, half the sources are missing" "$(score "$RC" .note)"
t "S5 no model call for a keyword hit" "" "$(cat "$TMP/rx.calls" 2>/dev/null)"
# The same reply again (same --at) is counted once.
R=$(mk_run "$M"); close_run "$R"; RW=$R
cmd_task_loop_feedback "$RW" --text="bad" --at="$(db "SELECT done_at FROM tasks WHERE ident='$RW';")" >/dev/null 2>&1
cmd_task_loop_feedback "$RW" --text="bad" --at="$(db "SELECT done_at FROM tasks WHERE ident='$RW';")" >/dev/null 2>&1
t "S5 one reply counted once" "1" "$(score "$RW" '.signals|length')"
# Outside the window: a reply 25h after the run closed changes nothing.
R=$(mk_run "$M"); close_run "$R"; RO=$R
db "UPDATE tasks SET done_at=datetime('now','-25 hours') WHERE ident='$RO';"
out=$(cmd_task_loop_feedback "$RO" --text="this is wrong" 2>&1)
t "S5 reply outside the window: not lowered" "false|outside window|80" "$(jq -r '"\(.data.lowered)|\(.data.reason)"' <<<"$out")|$(score "$RO")"
# A reply BEFORE the run closed is outside the window too.
out=$(cmd_task_loop_feedback "$RO" --text="this is wrong" --at="2020-01-01 00:00:00" 2>&1)
t "S5 reply before the run: not lowered" "false" "$(jq -r .data.lowered <<<"$out")"
# Never raises: a complaint on a run already at 10 keeps 10.
cmd_task_loop_feedback "$(db "SELECT ident FROM tasks WHERE from_template_id=$(idof "$L") AND status='cancelled';")" --text="bad run" >/dev/null 2>&1
t "S5 complaint never raises a lower score" "10" "$(score "$(db "SELECT ident FROM tasks WHERE from_template_id=$(idof "$L") AND status='cancelled';")")"

# S6 — no keyword: one Decisions call decides; reflex off = not a complaint.
R=$(mk_run "$M"); close_run "$R"; RN=$R
out=$(cmd_task_loop_feedback "$RN" --text="hmm, I expected the Berlin listings too" 2>&1)
t "S6 reflex not configured: no model call, not lowered" "false|80|" "$(jq -r .data.lowered <<<"$out")|$(score "$RN")|$(cat "$TMP/rx.calls" 2>/dev/null)"
RX_ON=true; RX_CHOICE=complaint; RX_CONF=0.3
out=$(cmd_task_loop_feedback "$RN" --text="hmm, I expected the Berlin listings too" 2>&1)
t "S6 low-confidence complaint: not lowered" "false|80" "$(jq -r .data.lowered <<<"$out")|$(score "$RN")"
t "S6 the call asked one question with the reply" "complaint,neutral,praise|hmm, I expected the Berlin listings too" "$(jq -r '"\(.options|join(","))|\(.state.reply)"' "$TMP/rx.req")"
RX_CONF=0.92
out=$(cmd_task_loop_feedback "$RN" --text="hmm, I expected the Berlin listings too" 2>&1)
t "S6 confident complaint: lowered by the model" "true|model|20" "$(jq -r '"\(.data.lowered)|\(.data.by)|\(.data.score)"' <<<"$out")"
R=$(mk_run "$M"); close_run "$R"; RP=$R; RX_CHOICE=praise
out=$(cmd_task_loop_feedback "$RP" --text="nice one, keep it like this" 2>&1)
t "S6 praise does not raise or lower" "false|80" "$(jq -r .data.lowered <<<"$out")|$(score "$RP")"
RX_ON=false

# S7 — a row that names the run, inside the window: by a person = complaint,
# by an agent = rework; outside the window or a different ident = nothing.
N=$(mk_tpl "News scan"); R1=$(mk_run "$N"); close_run "$R1"; R2=$(mk_run "$N"); close_run "$R2"; R3=$(mk_run "$N"); close_run "$R3"
db "INSERT INTO tasks (title, body, created_by, status) VALUES ('Digest $R1 skipped the paywalled sources', 'see it', 'lodar', 'todo');"
db "INSERT INTO tasks (title, body, created_by, status) VALUES ('Fix the dedupe', 'redo of ${R2}: duplicates', 'quinn', 'todo');"
db "INSERT INTO tasks (title, body, created_by, status, created_at) VALUES ('Old note', 'about ${R3}', 'lodar', 'todo', datetime('now','+2 days'));"
db "INSERT INTO tasks (title, body, created_by, status) VALUES ('Unrelated', 'about ${R3}9 and x${R3}', 'lodar', 'todo');"
cmd_task_loop_scores >/dev/null 2>&1
t "S7 person files a row naming it: complaint" "20|owner complained: filed" "$(score "$R1" '"\(.score)|\(.note|split(" DIVE")[0]|split(" ")[0:3]|join(" "))"')"
t "S7 agent files a fix row naming it: rework" "40" "$(score "$R2")"
t "S7 rework note names the row" "1" "$(score "$R2" '.note|startswith("rework: ")' | grep -c true)"
t "S7 row outside the window / other ident: nothing" "80" "$(score "$R3")"
cmd_task_loop_scores >/dev/null 2>&1
t "S7 a second sweep counts each row once" "1" "$(score "$R1" '.signals|length')"
# No registry file on the box: nobody is registered, so a name not on the team is
# still a person (CI runs with none). An unreadable registry is not a measurement.
REG_SAVED="$REGISTRY"; REGISTRY="$TMP/absent.json"
_loop_is_person lodar; t "S7 no registry file: a person is still a person" "0" "$?"
printf 'not json' >"$TMP/bad.json"; REGISTRY="$TMP/bad.json"
_loop_is_person lodar; t "S7 unreadable registry: not called a person" "1" "$?"
REGISTRY="$REG_SAVED"

# S8 — reopened inside the window: complaint.
R=$(mk_run "$N"); close_run "$R"
db "UPDATE tasks SET status='todo' WHERE ident='$R';"
cmd_task_loop_scores >/dev/null 2>&1
t "S8 reopened run lowered" "20|owner complained: reopened it" "$(score "$R" '"\(.score)|\(.note)"')"

# S9 — a run still open when the next run started did not end done.
K=$(mk_tpl "Inbox"); R1=$(mk_run "$K"); db "UPDATE tasks SET status='blocked' WHERE ident='$R1';"; R2=$(mk_run "$K"); close_run "$R2"
t "S9 stuck run scored lowest" "10|did not finish: still blocked when $R2 started" "$(score "$R1" '"\(.score)|\(.note)"')"
t "S9 the open run with no successor is left alone" "" "$(R3=$(mk_run "$K"); cmd_task_loop_scores >/dev/null 2>&1; _loop_pref_get "loop.score.$R3")"

# S10 — an old "Score loop run" row nobody started is closed WITH a result;
# one a seat already started is left to finish.
Q=$(mk_tpl "Legacy"); R1=$(mk_run "$Q"); R2=$(mk_run "$Q")
db "UPDATE tasks SET status='done', done_at=datetime('now') WHERE ident IN ('$R1','$R2');"
db "INSERT INTO tasks (title, body, created_by, assignee, status) VALUES ('Score loop run $R1', 'x', 'loop', 'quinn', 'todo'), ('Score loop run $R2', 'x', 'loop', 'quinn', 'in_progress');"
cmd_task_loop_scores >/dev/null 2>&1
t "S10 unstarted legacy row closed done" "done" "$(db "SELECT status FROM tasks WHERE title='Score loop run $R1';")"
t "S10 with a result naming the runtime score" "1" "$(db "SELECT result LIKE 'Scored by the runtime from signals instead (DIVE-5815): 80/100, clean run.%' FROM tasks WHERE title='Score loop run $R1';")"
t "S10 started legacy row left alone" "in_progress" "$(db "SELECT status FROM tasks WHERE title='Score loop run $R2';")"
t "S10 the legacy runs are scored" "80 80" "$(score "$R1") $(score "$R2")"

# S11 — the board lists cancelled and unfinished runs with their scores, and the
# weekly review still reads them (Daily digest: 30,30,10,20 -> the lowest).
board=$(cmd_task_loop_scores | jq -c '.data.loops')
t "S11 board shows the cancelled run" "1" "$(jq "[.[]|select(.ident==\"$L\").runs[]|select(.effective==10)]|length" <<<"$board")"
db "DELETE FROM task_prefs WHERE key='loop.review.last';"; db "DELETE FROM tasks WHERE title LIKE 'Suggest a change to loop %';"
out=$(cmd_task_loop_review --force 2>&1)
t "S11 weekly review picks the lowest runtime-scored loop" "true $L" "$(jq -r '"\(.data.filed) \(.data.loop)"' <<<"$out")"
t "S11 the ask carries the runtime's notes" "1" "$(db "SELECT body LIKE '%error: tool_error%' FROM tasks WHERE ident='$(jq -r .data.task <<<"$out")';")"
ask=$(jq -r .data.task <<<"$out")
# The ask lists the runs by ident. It is excluded by its TITLE, not only by
# created_by='loop' (a hand-filed or re-attributed copy must still not read as rework).
db "UPDATE tasks SET created_by='quinn' WHERE ident='$ask';"
t "S11 (the ask names the errored run)" "1" "$(db "SELECT body LIKE '%${RE}%' FROM tasks WHERE ident='$ask';")"
before=$(db "SELECT group_concat(value, '|') FROM task_prefs WHERE key LIKE 'loop.score.%' ORDER BY key;")
cmd_task_loop_scores >/dev/null 2>&1
t "S11 the suggestion ask is not read as rework" "$before" "$(db "SELECT group_concat(value, '|') FROM task_prefs WHERE key LIKE 'loop.score.%' ORDER BY key;")"

# S12 — usage + validation.
( cmd_task_loop_feedback "$RC" ) >/dev/null 2>&1;            t "S12 feedback without --text refused" "1" "$([[ $? -ne 0 ]] && echo 1)"
( cmd_task_loop_feedback "$L" --text="bad" ) >/dev/null 2>&1; t "S12 feedback on a loop (not a run) refused" "1" "$([[ $? -ne 0 ]] && echo 1)"

# The acceptance grep: nothing on the new path filed a "Score loop run" row.
t "ACCEPT no 'Score loop run' row created by the runtime" "0" "$(db "SELECT COUNT(*) FROM tasks WHERE title LIKE 'Score loop run %' AND body <> 'x';")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
