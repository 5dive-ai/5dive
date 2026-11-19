#!/usr/bin/env bash
# DIVE-8718 isolated unit harness for `5dive agent proactive <name>
# [off|little|more] | claim --text= | reaction acted|not-now`: a per-agent level
# (default off) that makes ONE self-improving "Check in with you" loop, and a
# daily cap of first messages (little 1, more 3) enforced by the CLI twice —
# `claim` refuses at the cap, and the scheduler starts no check-in run once it
# is used — never by the loop's text. Off parks the loop (kept); on resumes the
# same one with its learned text. The owner's reaction reaches the loop's grade
# from the runtime (_loop_improve_runtime_note), not from the run's report.
# Throwaway STATE_DIR — never touches the live tasks.db.
# Run: bash tests/agent_proactive_unit.sh (no root, no network).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/agent-proactive-unit.XXXXXX)"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_heartbeat.sh cmd_agent_proactive.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=1
export FIVE_BOX_TZ=UTC FIVEDIVE_PROACTIVE_NO_ROSTER=1
mkdir -p "$TASKS_DIR"
set +e
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   want: %s\n   got:  %s\n' "$1" "$2" "$3"; fi; }
tasks_db_init
LOG="$TMP/hb.log"; : >"$LOG"
_hb_log() { printf '%s\n' "$*" >>"$LOG"; }

# The agent is the harness's own unix user, so the "only itself or root" rule
# lets it through (agent-dev -> dev on a seat, runner on CI).
ME=$(id -un); N="${ME#agent-}"
P() { ( cmd_agent_proactive "$N" "$@" ) 2>"$TMP/err" | tee "$TMP/out"; }
st() { P --json | jq -r ".data | $1"; }

# T1 — default off: nothing made, cap 0, no next check.
t "T1 default off" "off|null|0|0|null|0" "$(st '"\(.level)|\(.loop)|\(.cap)|\(.sent_today)|\(.next_check)|\(.checks_per_day)"')"
t "T1 no loop exists" "0" "$(db "SELECT COUNT(*) FROM tasks WHERE kind='recurring';")"
P claim --text="hello" >/dev/null; t "T1 claim refused while off" "1" "$([[ $? -ne 0 ]] && echo 1)"
t "T1 refusal says send nothing" "1" "$(cat "$TMP/err" "$TMP/out" | grep -m1 -c "Send nothing")"

# T2 — little: one recurring loop for the agent, twice a day, self-improving on,
# fixed criteria that name the owner's reaction.
out=$(P little); t "T2 little ok" "little|off|1" "$(jq -r '.data | "\(.level)|\(.previous)|\(.cap)"' <<<"$out")"
L=$(st .loop); TID=$(db "SELECT id FROM tasks WHERE ident='$L';")
t "T2 loop row" "Check in with you|$N|recurring|0 9,17 * * *|todo|1" \
  "$(db "SELECT title||'|'||assignee||'|'||kind||'|'||schedule||'|'||status||'|'||fresh FROM tasks WHERE id=$TID;")"
t "T2 self-improving on" "on|true" "$(db "SELECT value FROM task_prefs WHERE key='loop.improve.$L';")|$(st .self_improving)"
t "T2 criteria name the owner's reaction" "1" "$(db "SELECT acceptance_criteria FROM tasks WHERE id=$TID;" | grep -c 'acted on the last message')"
t "T2 body asks before sending" "1" "$(db "SELECT body FROM tasks WHERE id=$TID;" | grep -c "proactive $N claim --text=")"
t "T2 status: 2 checks, 0 of 1, a next check" "2|0|1|true" "$(st '"\(.checks_per_day)|\(.sent_today)|\(.cap)|\(.next_check != null)"')"
t "T2 visible as a loop (task ls --recurring)" "$L" "$(JSON_MODE=1 cmd_task_ls --recurring | jq -r ".data.tasks[] | select(.ident==\"$L\") | .ident")"
t "T2 little again: still one loop" "1" "$(P little >/dev/null; db "SELECT COUNT(*) FROM tasks WHERE kind='recurring';")"

# T3 — the cap, in claim: 1 a day at little.
out=$(P claim --text="Your invoice from Acme is due Friday. Want me to draft the payment note?")
t "T3 first claim yes" "true|1|1" "$(jq -r '.data | "\(.allowed)|\(.sent_today)|\(.cap)"' <<<"$out")"
P claim --text="one more thing" >/dev/null; t "T3 second claim refused at cap" "1" "$([[ $? -ne 0 ]] && echo 1)"
t "T3 refusal names the count" "1" "$(cat "$TMP/err" "$TMP/out" | grep -m1 -c "already sent 1 of 1 today")"
# The claim takes a lock fd; a refusal after it must still reach stderr (an
# `exec {fd}>>lock 2>/dev/null` once silenced every refusal for the shell).
t "T3 refusal reaches stderr" "1" "$( (JSON_MODE=0; cmd_agent_proactive "$N" claim --text=again) 2>&1 >/dev/null | grep -c 'already sent')"
t "T3 refused claim not logged" "1" "$(db "SELECT value FROM task_prefs WHERE key='proactive.log.$N';" | jq length)"
tomorrow=$(date -u -d tomorrow +%F)
t "T3 capped: next check is tomorrow's first" "${tomorrow}T09:00:00Z" "$(st .next_check)"

# T4 — the cap, in the scheduler: a due slot does not start a run once it is
# used, and the skip is stamped with its reason.
db "UPDATE tasks SET schedule='* * * * *' WHERE id=$TID;"
t "T4 capped list carries the loop" "$TID" "$(_hb_proactive_capped)"
_hb_materialize_recurring "$(date -u +%s)"
t "T4 capped: no run started" "0" "$(db "SELECT COUNT(*) FROM tasks WHERE from_template_id=$TID;")"
t "T4 capped: skip stamped" "proactive: daily cap reached" "$(db "SELECT last_skip_reason FROM tasks WHERE id=$TID;")"
# Yesterday's message does not count today.
db "UPDATE task_prefs SET value=json_replace(value,'\$[0].day','2000-01-01') WHERE key='proactive.log.$N';"
t "T4 a past day's message is not today's" "" "$(_hb_proactive_capped)"
_hb_materialize_recurring "$(date -u +%s)"
t "T4 under the cap: the run starts" "1" "$(db "SELECT COUNT(*) FROM tasks WHERE from_template_id=$TID;")"
db "DELETE FROM tasks WHERE from_template_id=$TID;"

# T5 — more: the SAME loop, four checks a day, 3 a day.
out=$(P more); t "T5 more keeps the loop" "$L|3" "$(jq -r '.data | "\(.loop)|\(.cap)"' <<<"$out")"
t "T5 four checks" "0 9,13,17,21 * * *|4" "$(db "SELECT schedule FROM tasks WHERE id=$TID;")|$(st .checks_per_day)"
P claim --text="a" >/dev/null; P claim --text="b" >/dev/null; out=$(P claim --text="c")
t "T5 third claim yes" "3" "$(jq -r .data.sent_today <<<"$out")"
P claim --text="d" >/dev/null; t "T5 fourth refused" "1" "$([[ $? -ne 0 ]] && echo 1)"
t "T5 scheduler: capped at 3" "$TID" "$(_hb_proactive_capped)"

# T6 — off parks the loop, keeps it and what it learned; claim refused.
db "UPDATE tasks SET body=body||char(10)||'Learned: lead with the deadline.' WHERE id=$TID;"
out=$(P off); t "T6 off" "off|more|$L" "$(jq -r '.data | "\(.level)|\(.previous)|\(.loop)"' <<<"$out")"
t "T6 loop parked, not deleted" "blocked|1" "$(db "SELECT status||'|'||(parked_at IS NOT NULL) FROM tasks WHERE id=$TID;")"
t "T6 off: not on the capped list (nothing to stop)" "" "$(_hb_proactive_capped)"
t "T6 status off: no next check" "off|null|0" "$(st '"\(.level)|\(.next_check)|\(.cap)"')"
P claim --text="x" >/dev/null; t "T6 claim refused when off" "1" "$([[ $? -ne 0 ]] && echo 1)"

# T7 — on again: the same loop, un-parked, with its learned text.
P little >/dev/null
t "T7 same loop, todo again" "$L|todo|0" "$(st .loop)|$(db "SELECT status||'|'||(parked_at IS NOT NULL) FROM tasks WHERE id=$TID;")"
t "T7 learned text kept" "1" "$(db "SELECT body FROM tasks WHERE id=$TID;" | grep -c 'Learned: lead with the deadline.')"
t "T7 schedule back to twice a day" "0 9,17 * * *" "$(db "SELECT schedule FROM tasks WHERE id=$TID;")"

# T8 — the owner's reaction reaches the grade from the runtime.
later=$(db "SELECT datetime('now','+1 minute');")
t "T8 no answer yet" "1" "$(_loop_improve_runtime_note "$L" "$later" | grep -c 'NOT ANSWERED')"
out=$(P reaction not-now); t "T8 reaction recorded" "not-now" "$(jq -r .data.reaction <<<"$out")"
t "T8 grade note: not now" "1" "$(_loop_improve_runtime_note "$L" "$later" | grep -c 'said NOT NOW')"
P reaction acted >/dev/null
t "T8 grade note: acted" "1" "$(_loop_improve_runtime_note "$L" "$later" | grep -c 'ACTED ON')"
t "T8 a message sent after the run began is not its input" "1" "$(_loop_improve_runtime_note "$L" "2000-01-01 00:00:00" | grep -c 'no check-in message was sent')"
O=$(db "INSERT INTO tasks (title, body, assignee, created_by, kind, schedule, status) VALUES ('Other', 'x', 'scout', 'owner', 'recurring', '0 9 * * *', 'todo'); SELECT ident FROM tasks WHERE id=last_insert_rowid();")
t "T8 any other loop: no note" "" "$(_loop_improve_runtime_note "$O" "$later")"
P reaction maybe >/dev/null; t "T8 bad reaction refused" "1" "$([[ $? -ne 0 ]] && echo 1)"
t "T8 status shows the last reaction" "acted" "$(st .last_message.reaction)"

# T10 — the note is IN the grade's prompt (the model call is a seam: a stub
# that saves the prompt and answers a fixed grade).
cat >"$TMP/ai.sh" <<'EOF2'
#!/usr/bin/env bash
cat >"$AI_DIR/prompt"
jq -cn '{type:"result", result:"{\"criteria\":[{\"name\":\"x\",\"score\":80,\"reason\":\"ok\"}],\"overall\":80,\"proposal\":null}", total_cost_usd:0.001}'
EOF2
chmod +x "$TMP/ai.sh"
R=$(db "INSERT INTO tasks (title, body, assignee, created_by, kind, from_template_id, status, result, created_at)
        SELECT title, body, assignee, created_by, 'standard', id, 'done', 'nothing worth saying', datetime('now','+2 minutes') FROM tasks WHERE id=$TID;
        SELECT ident FROM tasks WHERE id=last_insert_rowid();")
AI_DIR="$TMP" FIVEDIVE_LOOP_IMPROVE_AI="$TMP/ai.sh" _loop_improve_tick "$L" "$R" >/dev/null 2>&1
t "T10 the grade's prompt carries the owner's reaction" "1" "$(grep -c 'FROM THE RUNTIME (not the run): the owner ACTED ON' "$TMP/prompt" 2>/dev/null)"

# T9 — only the agent itself or root.
if [[ "$EUID" != "0" ]]; then
  ( cmd_agent_proactive scout-nobody little ) >/dev/null 2>"$TMP/err"; rc=$?
  t "T9 another agent's level refused" "1|1" "$([[ $rc -ne 0 ]] && echo 1)|$(grep -c 'only scout-nobody itself or root' "$TMP/err")"
  ( cmd_agent_proactive scout-nobody claim --text=hi ) >/dev/null 2>&1; rc=$?
  t "T9 another agent's claim refused" "1" "$([[ $rc -ne 0 ]] && echo 1)"
else
  printf 'skip - T9 runs as root (root is allowed by design)\n'
fi
t "T9 a bad name is refused" "1" "$( ( cmd_agent_proactive 'Bad Name' ) >/dev/null 2>&1 || echo 1)"
t "T9 status is readable by anyone" "0" "$( ( cmd_agent_proactive scout-nobody --json ) >/dev/null 2>&1; echo $?)"

# T11 — DIVE-8765 (lodar 11-19, "human gates are always on"): asks already reach the owner, so the
# loop never lists "something that needs them" as worth a message; the three useful kinds stay.
_b="$(_proactive_body scout)"
t "T11 the loop does not message about what needs them" "0|1|1" "$(grep -c 'something that needs them' <<<"$_b")|$(grep -c 'a result they were waiting for, a problem you found, or one useful idea' <<<"$_b")|$(grep -c 'asks and approvals already reach them' <<<"$_b")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
