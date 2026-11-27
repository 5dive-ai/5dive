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
# DIVE-8838: raising the level is root-only (the owner's tap in the app). ROOT=1
# plays the app; ROOT=0 plays the agent itself.
ROOT=1
_proactive_is_root() { [[ "$ROOT" == "1" ]]; }
export AGENT_HOME_ROOT="$TMP/home" FIRST_JOB_DIR="$TMP/first-jobs"
mkdir -p "$AGENT_HOME_ROOT/agent-$N/.claude/projects/-w/memory" "$FIRST_JOB_DIR"
_proactive_seed_seats() { printf '%s\n' ${SEATS:-}; }
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
  ROOT=0
  ( cmd_agent_proactive scout-nobody little ) >/dev/null 2>"$TMP/err"; rc=$?
  t "T9 another agent's level refused" "1|1" "$([[ $rc -ne 0 ]] && echo 1)|$(grep -c 'only scout-nobody itself or root' "$TMP/err")"
  ( cmd_agent_proactive scout-nobody claim --text=hi ) >/dev/null 2>&1; rc=$?
  t "T9 another agent's claim refused" "1" "$([[ $rc -ne 0 ]] && echo 1)"
  ROOT=1
else
  printf 'skip - T9 runs as root (root is allowed by design)\n'
fi
t "T9 a bad name is refused" "1" "$( ( cmd_agent_proactive 'Bad Name' ) >/dev/null 2>&1 || echo 1)"
t "T9 status is readable by anyone" "0" "$( ( cmd_agent_proactive scout-nobody --json ) >/dev/null 2>&1; echo $?)"

# T11 — DIVE-8765 (lodar 11-19, "human gates are always on"): asks already reach the owner, so the
# loop never lists "something that needs them" as worth a message; the three useful kinds stay.
_b="$(_proactive_body scout)"
t "T11 the loop does not message about what needs them" "0|1|1" "$(grep -c 'something that needs them' <<<"$_b")|$(grep -c 'a result they were waiting for, a problem you found, or one useful idea' <<<"$_b")|$(grep -c 'asks and approvals already reach them' <<<"$_b")"

# ---------------- DIVE-8838: track record, earned level-up, day-one memory ----------------
# A clean agent per block: its log, offer and level are prefs keyed by name.
seed_log() { # <name> <acted count> <total> [day] — <total> past messages, the first <acted> acted on
  local nm="$1" a="$2" tot="$3" d="${4:-2000-01-01}"
  db "INSERT INTO task_prefs (key,value,updated_at) VALUES ('proactive.log.$nm',
      (SELECT json_group_array(json_object('at','2000-01-01 00:00:00','day','$d','text','m'||value,
         'reaction', CASE WHEN value <= $a THEN 'acted' ELSE 'not-now' END))
       FROM generate_series(1,$tot)), datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value=excluded.value;" 2>/dev/null \
  || db "INSERT OR REPLACE INTO task_prefs (key,value,updated_at) VALUES ('proactive.log.$nm',
      '$(jq -cn --argjson a "$a" --argjson t "$tot" --arg d "$d" '[range(1;$t+1) | {at:"2000-01-01 00:00:00", day:$d, text:("m\(.)"), reaction:(if . <= $a then "acted" else "not-now" end)}]')', datetime('now'));"
}
clear_agent() { db "DELETE FROM task_prefs WHERE key LIKE 'proactive.%.$1';"; }
P off >/dev/null; clear_agent "$N"; P little >/dev/null

# T12 — acted_last_10 in --json, over the last 10 only.
seed_log "$N" 9 14
t "T12 acted_last_10 is over the last 10" '{"acted":5,"sent":10}' "$(P --json | jq -c .data.acted_last_10)"
seed_log "$N" 2 3
t "T12 fewer than 10 sent" '{"acted":2,"sent":3}' "$(P --json | jq -c .data.acted_last_10)"
t "T12 human status names it" "1" "$( (JSON_MODE=0; cmd_agent_proactive "$N") | grep -c 'acted on 2 of the last 3')"

# T13 — the offer fires at 8/10, not at 7/10, rides the claim (no extra message).
seed_log "$N" 7 10
out=$(P claim --text="hello")
t "T13 7 of 10: yes, no offer" "true|null" "$(jq -r '.data | "\(.allowed)|\(.offer)"' <<<"$out")"
t "T13 7 of 10: no offer recorded" "null" "$(st .offer)"
seed_log "$N" 8 10
out=$(P claim --text="Your Acme invoice is due Friday. Want me to draft the payment note?")
t "T13 8 of 10: offer on the yes" "more|Very high" "$(jq -r '.data.offer | "\(.to)|\(.label)"' <<<"$out")"
t "T13 the offer line" "You acted on 8 of my last 10. Want me to message you a bit more (Very high)?" "$(jq -r .data.offer.line <<<"$out")"
t "T13 human output says to end the message with it" "1" "$(seed_log "$N" 8 10; db "DELETE FROM task_prefs WHERE key='proactive.offer.$N';"; (JSON_MODE=0; cmd_agent_proactive "$N" claim --text=x 2>/dev/null) | grep -c 'End the message with this line, word for word')"
t "T13 it rode one claimed message (counted against the cap)" "1" "$(db "SELECT value FROM task_prefs WHERE key='proactive.log.$N';" | jq '[.[] | select(.offer == "more")] | length')"
t "T13 status shows the open offer" "little|more|null" "$(st '.offer | "\(.from)|\(.to)|\(.answer)"')"
# The cap holds: a capped day has no claim, so no offer.
db "DELETE FROM task_prefs WHERE key='proactive.offer.$N';"
seed_log "$N" 10 10 "$(date -u +%F)"
P claim --text="again" >/dev/null; rc=$?
t "T13 at the cap: refused, no offer" "1|null" "$([[ $rc -ne 0 ]] && echo 1)|$(st .offer)"

# T14 — the level does not change without the owner's tap.
seed_log "$N" 8 10; db "DELETE FROM task_prefs WHERE key='proactive.offer.$N';"
P claim --text="x" >/dev/null
t "T14 an open offer changes nothing by itself" "little" "$(st .level)"
ROOT=0
P more >/dev/null; rc=$?
t "T14 the agent cannot raise itself" "1|little" "$([[ $rc -ne 0 ]] && echo 1)|$(st .level)"
t "T14 the refusal says so" "1" "$( (ROOT=0; JSON_MODE=0; cmd_agent_proactive "$N" more) 2>&1 | grep -m1 -c "only your owner can raise")"
P offer yes >/dev/null; rc=$?
t "T14 the agent cannot say Yes for the owner" "1|little|null" "$([[ $rc -ne 0 ]] && echo 1)|$(st .level)|$(st .offer.answer)"
P off >/dev/null; t "T14 the agent may lower itself" "off" "$(st .level)"
ROOT=1; P offer yes >/dev/null; rc=$?
t "T14 Yes needs the level the offer was made at (now Normal): refused" "1|off" "$([[ $rc -ne 0 ]] && echo 1)|$(st .level)"
P little >/dev/null
out=$(P offer yes 2>/dev/null)
t "T14 the owner's Yes (root) raises it through the set verb" "more|little" "$(jq -r '.data | "\(.level)|\(.previous)"' <<<"$out")"
t "T14 offer answered yes" "yes" "$(st .offer.answer)"
P offer yes >/dev/null; rc=$?
t "T14 a second Yes: no open offer" "1|more" "$([[ $rc -ne 0 ]] && echo 1)|$(st .level)"
db "DELETE FROM task_prefs WHERE key='proactive.offer.$N';"
P offer yes >/dev/null; rc=$?
t "T14 Yes with no offer at all is refused" "1" "$([[ $rc -ne 0 ]] && echo 1)"

# T15 — never at Very high; not again within 30 days after Not now or no answer.
seed_log "$N" 10 10
out=$(P claim --text="x")
t "T15 Very high: never an offer, even at 10 of 10" "null|null" "$(jq -r .data.offer <<<"$out")|$(st .offer)"
ROOT=1; P little >/dev/null; seed_log "$N" 9 10
out=$(P claim --text="x"); t "T15 High again: offer" "more" "$(jq -r .data.offer.to <<<"$out")"
ROOT=0; out=$(P offer not-now); ROOT=1
t "T15 Not now recorded (the agent may record a no)" "not-now|little" "$(st .offer.answer)|$(st .level)"
seed_log "$N" 10 10; out=$(P claim --text="x")
t "T15 within 30 days of Not now: no offer" "null" "$(jq -r .data.offer <<<"$out")"
db "UPDATE task_prefs SET value=json_set(value,'\$.at',datetime('now','-29 days')) WHERE key='proactive.offer.$N';"
seed_log "$N" 10 10; out=$(P claim --text="x")
t "T15 day 29: still none" "null" "$(jq -r .data.offer <<<"$out")"
db "UPDATE task_prefs SET value=json_set(value,'\$.at',datetime('now','-31 days')) WHERE key='proactive.offer.$N';"
seed_log "$N" 10 10; out=$(P claim --text="x")
t "T15 after 30 days: offered again" "more" "$(jq -r .data.offer.to <<<"$out")"
# No answer at all also blocks for 30 days.
seed_log "$N" 10 10; out=$(P claim --text="x")
t "T15 an unanswered offer: none again within 30 days" "null" "$(jq -r .data.offer <<<"$out")"
db "UPDATE task_prefs SET value=json_set(value,'\$.at',datetime('now','-31 days')) WHERE key='proactive.offer.$N';"
ROOT=1; P offer yes >/dev/null; rc=$?
t "T15 an offer older than 30 days cannot be answered Yes" "1|little" "$([[ $rc -ne 0 ]] && echo 1)|$(st .level)"

# T16 — the loop text: offers only from claim, never raise itself (read-only limit sentence).
_b="$(_proactive_body scout)"
t "T16 body: offer line only from claim, never raise itself" "1|1" "$(grep -c 'Only when that yes gives you an offer line' <<<"$_b")|$(grep -c 'never raise your own level' <<<"$_b")"

# T17 — day-one memory: seeded once, from the owner's own agents, never a secret.
mk_atom() { # <seat> <file> <type> <body>
  local d="$AGENT_HOME_ROOT/agent-$1/.claude/projects/-w/memory"; mkdir -p "$d"
  printf -- '---\nname: %s\ndescription: "%s"\nmetadata:\n  type: %s\n---\n\n%s\n' "${2%.md}" "about the owner" "$3" "$4" >"$d/$2"
}
S=seedme; T="$AGENT_HOME_ROOT/agent-$S/.claude/projects/-w/memory"; mkdir -p "$T"
mk_atom olivia user_owner_bakery.md user "Owner runs a bakery in Porto and reads on a phone."
mk_atom olivia user_owner_password.md user "Owner's bank password is in the notes app."
mk_atom olivia user_owner_task.md user "Owner asked for DIVE-123 to ship by Friday."
mk_atom olivia user_owner_clients.md user "Owner's client Acme pays late."
mk_atom olivia feedback_style.md feedback "Keep replies short."
mk_atom olivia user_owner_seeded_once.md user "x"; printf '  seeded: proactive\n' >>"$AGENT_HOME_ROOT/agent-olivia/.claude/projects/-w/memory/user_owner_seeded_once.md"
mk_atom theo user_owner_mornings.md user "Owner prefers messages in the morning."
mk_atom stranger user_other_owner.md user "Someone else's owner likes jazz."
db "INSERT INTO humans (id, display_name, role) VALUES ('h-owner','Lodar','owner'), ('h-other','Kim','member');
    INSERT INTO human_agents (human_id, agent) VALUES ('h-other','stranger');"
jq -cn --arg n "$S" '{token:"t", name:$n, job:"Find three wholesale flour suppliers near Porto", status:"done"}' >"$FIRST_JOB_DIR/t.json"
jq -cn '{token:"u", name:"theo", job:"Theo task content", status:"done"}' >"$FIRST_JOB_DIR/u.json"
export SEATS="olivia theo stranger $S"
NS() { ( cmd_agent_proactive "$S" "$@" ) 2>"$TMP/err"; }
NS little >/dev/null
t "T17 seeded once, recorded" "4" "$(NS --json | jq -r .data.seeded.atoms)"
t "T17 the owner's own agents' owner facts copied" "1|1" "$(grep -l 'bakery in Porto' "$T"/user_seeded_*.md | wc -l)|$(grep -l 'in the morning' "$T"/user_seeded_*.md | wc -l)"
t "T17 owner's name and hire answer" "1|1" "$(grep -l 'name is Lodar' "$T"/user_seeded_*.md | wc -l)|$(grep -l 'wholesale flour suppliers' "$T"/user_seeded_*.md | wc -l)"
t "T17 secrets skipped" "0" "$(cat "$T"/*.md | grep -ci 'password')"
t "T17 task content, client facts, feedback, re-seeds, another owner's agent skipped" "0|0|0|0|0|0" \
  "$(cat "$T"/*.md | grep -c 'DIVE-123')|$(cat "$T"/*.md | grep -c 'Acme')|$(cat "$T"/*.md | grep -c 'Keep replies short')|$(grep -lx 'x' "$T"/*.md 2>/dev/null | wc -l)|$(cat "$T"/*.md | grep -c 'jazz')|$(cat "$T"/*.md | grep -c 'Theo task content')"
t "T17 every seeded atom is marked for consolidation" "4|4|4" \
  "$(grep -l '^  seeded: proactive' "$T"/user_seeded_*.md | wc -l)|$(grep -l '^  valid_to: ' "$T"/user_seeded_*.md | wc -l)|$(grep -l '^  confidence: low' "$T"/user_seeded_*.md | wc -l)"
t "T17 indexed in MEMORY.md" "4" "$(grep -c 'seeded-' "$T/MEMORY.md")"
mk_atom olivia user_owner_new.md user "Owner just bought a second shop."
NS off >/dev/null; NS more >/dev/null
t "T17 runs once: off and up again seeds nothing new" "4|0" "$(ls "$T"/user_seeded_*.md | wc -l)|$(cat "$T"/*.md | grep -c 'second shop')"
# An agent that already knows its owner is not seeded.
K=knows; KT="$AGENT_HOME_ROOT/agent-$K/.claude/projects/-w/memory"
mk_atom "$K" user_a.md user "a"; mk_atom "$K" user_b.md user "b"; mk_atom "$K" user_c.md user "c"
( cmd_agent_proactive "$K" little ) >/dev/null 2>&1
t "T17 knows its owner already: nothing seeded" "0|0" "$(ls "$KT"/user_seeded_*.md 2>/dev/null | wc -l)|$( ( cmd_agent_proactive "$K" --json ) | jq -r .data.seeded.atoms)"
# A seed never follows a link the agent planted, and writes as the agent.
O="$TMP/outside"; mkdir -p "$O/real"
SL=linker; SLT="$AGENT_HOME_ROOT/agent-$SL/.claude/projects/-w/memory"; mkdir -p "$SLT"
ln -s "$O/idx" "$SLT/MEMORY.md"; ln -s "$O/atom" "$SLT/user_seeded_owner_name.md"
( cmd_agent_proactive "$SL" little ) >/dev/null 2>&1
t "T17 dangling links planted for MEMORY.md and an atom: nothing at either target, 0 seeded" "0|0|0" \
  "$(ls -A "$O" | grep -cv '^real$')|$( ( cmd_agent_proactive "$SL" --json ) | jq -r .data.seeded.atoms)|$(ls "$SLT" | grep -cv -e '^MEMORY.md$' -e '^user_seeded_owner_name.md$')"
SD=dirlink; mkdir -p "$AGENT_HOME_ROOT/agent-$SD/.claude/projects/-w"; ln -s "$O/real" "$AGENT_HOME_ROOT/agent-$SD/.claude/projects/-w/memory"
( cmd_agent_proactive "$SD" little ) >/dev/null 2>&1
t "T17 the memory dir is a link out of the home: nothing written through it" "0" "$(ls -A "$O/real" | wc -l)"
DR=dropper; DRH="$AGENT_HOME_ROOT/agent-$DR"; mkdir -p "$DRH"; : >"$TMP/as.log"
( _proactive_as_agent() { printf '%s %s\n' "$1" "$2" >>"$TMP/as.log"; shift; "$@"; }; cmd_agent_proactive "$DR" little ) >/dev/null 2>&1
_n=$(ls "$DRH"/.claude/projects/*/memory/user_seeded_*.md 2>/dev/null | wc -l)
t "T17 every seed write runs as the agent: its store made, each atom and index line" "1|1|$((_n * 2 + 1))|0" \
  "$([[ $_n -ge 1 ]] && echo 1)|$(grep -c "^$DR mkdir" "$TMP/as.log")|$(grep -c "^$DR " "$TMP/as.log")|$(grep -vc "^$DR " "$TMP/as.log")"
# Not root: no seed (and no raise).
ROOT=0; NR=nr; mkdir -p "$AGENT_HOME_ROOT/agent-$NR/.claude/projects/-w/memory"
( cmd_agent_proactive "$NR" little ) >/dev/null 2>&1; rc=$?
t "T17 the agent raising itself: refused, nothing seeded" "1|null" "$([[ $rc -ne 0 ]] && echo 1)|$( ( cmd_agent_proactive "$NR" --json ) | jq -r .data.seeded)"
ROOT=1

# T18 — DIVE-9418 one sender per issue. Two agents of one owner on Proactive: the
# second's check-in does not repeat what the first already TOLD the owner today.
# ROOT=1 plays each agent's own run (the "itself or root" rule lets root claim).
db "DELETE FROM task_prefs WHERE key LIKE 'proactive.log.%';"
db "INSERT INTO humans (id, display_name, role) VALUES ('h1','Ann','owner'), ('h2','Bob','member');
    INSERT INTO human_agents (human_id, agent) VALUES ('h1','ceo'), ('h1','sales'), ('h2','other');"
PA() { local a="$1"; shift; ( cmd_agent_proactive "$a" "$@" ) 2>"$TMP/err" | tee "$TMP/out"; }
PA ceo little >/dev/null; PA sales more >/dev/null; PA other more >/dev/null
NEWS="The stock fix shipped: the shop shows real stock again."
out=$(PA ceo claim --text="$NEWS")
t "T18 first agent, empty team: yes" "true|false|1" "$(jq -r '.data | "\(.allowed)|\(.wait)|\(.sent_today)"' <<<"$out")"
t "T18 claimed, not sent: the team has heard nothing" "0" "$(PA sales recent | jq '.data.told | length')"
t "T18 claimed, not sent: logged delivered:false" "false" "$(db "SELECT value FROM task_prefs WHERE key='proactive.log.ceo';" | jq -r '.[-1].delivered')"
out=$(PA ceo sent); t "T18 sent marks it told" "true" "$(jq -r .data.delivered <<<"$out")"
at1=$(db "SELECT value FROM task_prefs WHERE key='proactive.log.ceo';" | jq -r '.[-1].delivered_at')
PA ceo sent >/dev/null
t "T18 sent is idempotent (delivered_at kept)" "$at1" "$(db "SELECT value FROM task_prefs WHERE key='proactive.log.ceo';" | jq -r '.[-1].delivered_at')"
t "T18 recent, from the second agent: the first's message" "ceo|$NEWS" "$(PA sales recent | jq -r '.data.told | map("\(.agent)|\(.text)") | join(",")')"
t "T18 recent, text view says never tell it again" "1" "$( (JSON_MODE=0; cmd_agent_proactive sales recent) | grep -c 'Never tell it again')"
# A repeat in other words is refused even with --new, and spends nothing.
PA sales claim --text="Stock fix shipped, the shop shows the real stock again" --new >/dev/null; rc=$?
t "T18 second agent repeats the news (--new): refused, names who told it" "1|1" "$([[ $rc -ne 0 ]] && echo 1)|$(grep -c 'already heard this from ceo' "$TMP/err")"
_sl=$(db "SELECT value FROM task_prefs WHERE key='proactive.log.sales';" | jq 'length')
t "T18 the refused repeat is not logged" "0" "${_sl:-0}"
# Anything else: first a wait with the team's list, then a yes only with --new.
out=$(PA sales claim --text="Two customers asked about bulk prices this week. Want me to draft a price list?")
t "T18 different message without --new: wait, with the list, nothing spent" "false|true|1|0" \
  "$(jq -r '.data | "\(.allowed)|\(.wait)|\(.team_recent | length)"' <<<"$out")|$(PA sales --json | jq -r .data.sent_today)"
t "T18 the wait's text lists the told message" "1" "$( (JSON_MODE=0; cmd_agent_proactive sales claim --text=y) | grep -c "ceo (.*): $NEWS")"
txt=$( (JSON_MODE=0; cmd_agent_proactive sales claim --text="Two customers asked about bulk prices this week. Want me to draft a price list?" --new) 2>&1)
t "T18 with --new: yes, 1 of 3, and it says to record the send" "1|1" "$(grep -c 'yes: send it now.*(1 of 3 today)' <<<"$txt")|$(grep -c 'record it: 5dive agent proactive sales sent' <<<"$txt")"
# Another owner's agent never sees, and is never blocked by, this owner's news.
t "T18 another owner's agent: nothing told" "0" "$(PA other recent | jq '.data.told | length')"
out=$(PA other claim --text="$NEWS"); t "T18 another owner's agent may say the same thing" "true" "$(jq -r .data.allowed <<<"$out")"
# Window and legacy: a log entry with no delivered field counts as told; one older
# than 24 h does not.
db "INSERT OR REPLACE INTO task_prefs (key,value,updated_at) VALUES ('proactive.log.old',
    '$(jq -cn --arg now "$(db "SELECT datetime('now','-1 hour');")" '[{at:"2000-01-01 00:00:00",day:"2000-01-01",text:"ancient"},{at:$now,day:"x",text:"legacy told"}]')', datetime('now'));
    INSERT INTO human_agents (human_id, agent) VALUES ('h1','old');"
t "T18 legacy entry (no delivered) counts, a 24 h+ one does not" "legacy told" "$(PA sales recent | jq -r '.data.told | map(select(.agent == "old")) | map(.text) | join(",")')"
t "T18 sent with nothing claimed: refused" "1" "$( ( cmd_agent_proactive nobody2 sent ) >/dev/null 2>&1 || echo 1)"
# The loop's text, for new loops: read the team first, --new, sent, and the promise rule.
B=$(db "SELECT body FROM tasks WHERE ident='$(PA sales --json | jq -r .data.loop)';")
t "T18 body: recent, --new, sent, parked promise" "1|1|1|1" \
  "$(grep -c 'proactive sales recent' <<<"$B")|$(grep -c 'claim --text="<the message>" --new' <<<"$B")|$(grep -c 'proactive sales sent' <<<"$B")|$(grep -c -- '--assignee=sales --park="<why>" --park-wake=<when>' <<<"$B")"

# T19 — DIVE-9418 a promise becomes a parked task. The rule is in every seat's
# instructions (Claude team block, Codex baseline), and the command it names
# files a parked row with an owner and a wake time.
t "T19 team block carries the rule" "1" "$(grep -c -- '--park="<why>" --park-wake=<when>' prompts/team-CLAUDE.md)"
t "T19 Codex baseline carries the rule" "1" "$(_codex_operating_baseline_doc sales | grep -c -- '--assignee=sales --park="<why>" --park-wake=<when>')"
( cmd_task_add "Check the Acme invoice was paid" --assignee=sales --priority=low \
    --park="told the owner I would check tomorrow" --park-wake=+1d ) >"$TMP/add" 2>&1
r=$(db "SELECT assignee||'|'||status||'|'||(parked_at IS NOT NULL)||'|'||(wake_at > datetime('now','+23 hours'))||'|'||park_reason FROM tasks WHERE title='Check the Acme invoice was paid';")
t "T19 parked reminder: owner, parked, wakes in a day, why" "sales|blocked|1|1|told the owner I would check tomorrow" "$r"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
