#!/usr/bin/env bash
# Per-task usage attribution: a turn belongs to the /goal dispatch that opened
# its span, never to whichever row's [started_at, now] window happens to be open.
#
# History of the subject this harness owns:
#   DIVE-2058 (2026-07-26) — a BLOCKED row's window never closes (done_at stays
#     NULL), so it swallowed a later row's turns: DIVE-1817 read 13.8M. The fix
#     then only FLAGGED the row (`dispatched:false`).
#   DIVE-2312 — the flag was not enough, so the flagged figure renders in-cell
#     as `~N(unverified)`. The render half below still grades that.
#   DIVE-5090 (2026-09-27) — the flag was still not enough. DIVE-4930, parked on
#     a gate since 2026-09-24, was charged 10.3M of dev's 10.5M and ranked first;
#     lodar asked why a parked row was burning. And the window was wrong at the
#     other end too: `started_at` is re-stamped on every re-start, so a row
#     worked in five wakes kept only its last 84 s. The collector now attributes
#     by dispatch span (same session, from the nudge to the next nudge or the
#     row's close) and puts every other turn in `untracked`.
#
# The fixture is the ACCEPT shape from DIVE-5090: a row blocked on a gate since
# before the window, a later row worked in two iterations (the second re-stamps
# started_at), plus the edge cases each design choice rests on.
#
# Isolation (DIVE-2069): tasks.db AND the agent-home tree live in a throwaway
# dir via the USAGE_HOME_ROOT seam; nothing on this box's real homes is read.
# Run: bash tests/usage_dispatch_flag_unit.sh  (no sudo, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_usage.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e

TMP="$(mktemp -d /tmp/usage-dispatch-spans-unit.XXXXXX)"
AGENT="coder"
export USAGE_HOME_ROOT="$TMP/homes"
PROJDIR="$USAGE_HOME_ROOT/agent-$AGENT/.claude/projects/proj"
mkdir -p "$PROJDIR"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
REGISTRY="$TMP/registry.json"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
tasks_db_init
printf '{"agents":{"%s":{"authProfile":"acctT","type":"claude"}}}' "$AGENT" > "$REGISTRY"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2] got [$3]"; }
abort() { bad_t "$1" "${2:-}"; printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }

NOW=$(date +%s)
SINCE=$(( NOW - 86400 ))
iso() { date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ"; }
sqlts() { date -u -d "@$1" +'%Y-%m-%d %H:%M:%S'; }

# pin <file> <sessionId> <epoch> <ident>      — the heartbeat's current nudge
# turn <file> <sessionId> <epoch> <output>    — one assistant turn; API-EQ = out+100
pin() {
  printf '%s\n' "{\"type\":\"user\",\"sessionId\":\"$2\",\"timestamp\":\"$(iso "$3")\",\"message\":{\"role\":\"user\",\"content\":\"/goal $4 — your only row this turn; read it with '5dive task show $4'.\"}}" >> "$1"
}
turn() {
  printf '%s\n' "{\"type\":\"assistant\",\"sessionId\":\"$2\",\"timestamp\":\"$(iso "$3")\",\"message\":{\"role\":\"assistant\",\"model\":\"m\",\"usage\":{\"input_tokens\":100,\"output_tokens\":$4,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}" >> "$1"
}

# --- A: the parked row. Dispatched 3 days ago, gate asked 5 min later and never
# answered, status blocked, done_at NULL — DIVE-4930's exact state. Its session
# lives on: a human chats to the seat inside today's window.
T_A=$(( NOW - 3*86400 )); T_GATE=$(( T_A + 300 ))
A="$PROJDIR/sA.jsonl"
pin  "$A" sA "$T_A" DIVE-90001
turn "$A" sA $(( T_A + 60 )) 7                 # before the window: not counted at all
# In window, after the gate, and before every later row's start: on the pre-fix
# join the parked row's open window is the only one containing it.
turn "$A" sA $(( NOW - 20*3600 )) 1000000       # -> unattributed
db "INSERT INTO tasks (ident,title,status,assignee,created_by,started_at,first_started_at,need_type,need_asked_at)
    VALUES ('DIVE-90001','parked on a gate','blocked','$AGENT','main','$(sqlts "$T_A")','$(sqlts "$T_A")','manual','$(sqlts "$T_GATE")');"

# --- B: the later row, two iterations in two sessions. Iteration 1 is delivered,
# rejected, re-woken; the re-start re-stamps started_at to iteration 2's time.
T_B1=$(( NOW - 5*3600 )); T_B1_DEL=$(( T_B1 + 1800 ))
T_B2=$(( NOW - 3*3600 ))
B1="$PROJDIR/sB1.jsonl"; B2="$PROJDIR/sB2.jsonl"
pin  "$B1" sB1 "$T_B1" DIVE-90002
turn "$B1" sB1 $(( T_B1 + 60 ))   20000
turn "$B1" sB1 $(( T_B1 + 600 ))  30000
pin  "$B2" sB2 "$T_B2" DIVE-90002
turn "$B2" sB2 $(( T_B2 + 60 ))   40000
db "INSERT INTO tasks (ident,title,status,assignee,created_by,started_at,first_started_at,iteration)
    VALUES ('DIVE-90002','later row, two iterations','in_progress','$AGENT','main','$(sqlts "$T_B2")','$(sqlts "$T_B1")',2);"

# --- C: one session, two rows in sequence (a wake for another row arrives in a
# live session), then that row is DONE and the seat keeps talking.
T_C1=$(( NOW - 2*3600 )); T_C2=$(( NOW - 5400 )); T_C2_DONE=$(( T_C2 + 600 ))
C="$PROJDIR/sC.jsonl"
pin  "$C" sC "$T_C1" DIVE-90003
turn "$C" sC $(( T_C1 + 60 ))  500
pin  "$C" sC "$T_C2" ACME-7                    # a customer board's prefix
turn "$C" sC $(( T_C2 + 60 ))  600
turn "$C" sC $(( T_C2_DONE + 60 )) 700          # after ACME-7 closed -> unattributed
db "INSERT INTO tasks (ident,title,status,assignee,created_by,started_at)
    VALUES ('DIVE-90003','first row in a shared session','in_progress','$AGENT','main','$(sqlts "$T_C1")');"
db "INSERT INTO tasks (ident,title,status,assignee,created_by,started_at,done_at)
    VALUES ('ACME-7','customer-board row','done','$AGENT','main','$(sqlts "$T_C2")','$(sqlts "$T_C2_DONE")');"

# --- D: a dispatch from before the window whose session is still working in it.
T_D=$(( SINCE - 600 ))
D="$PROJDIR/sD.jsonl"
pin  "$D" sD "$T_D" DIVE-90004
turn "$D" sD $(( T_D + 60 ))    9               # before the window: not counted
turn "$D" sD $(( SINCE + 600 )) 800             # in window, same span -> DIVE-90004
db "INSERT INTO tasks (ident,title,status,assignee,created_by,started_at,done_at)
    VALUES ('DIVE-90004','crosses the window start','done','$AGENT','main','$(sqlts "$T_D")','$(sqlts $(( SINCE + 1200 )))');"

# --- E: a subagent of session B2 — its own file, the PARENT's sessionId (DIVE-3468).
mkdir -p "$PROJDIR/sB2/subagents"
turn "$PROJDIR/sB2/subagents/agent-x.jsonl" sB2 $(( T_B2 + 120 )) 50000

# --- F: a session nobody dispatched (a Telegram chat, a consolidate pass),
# running WHILE row B's second session is live: a nudge in one session says
# nothing about another. A tool_result that ECHOES a nudge's text is list-shaped
# content, not a dispatch, and must not open a span either.
T_F=$(( T_B2 + 240 ))
F="$PROJDIR/sF.jsonl"
printf '%s\n' "{\"type\":\"user\",\"sessionId\":\"sF\",\"timestamp\":\"$(iso "$T_F")\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"/goal DIVE-90005 — your only row this turn; read it\"}]}}" >> "$F"
turn "$F" sF $(( T_F + 60 )) 900

# --- G: a gate filed and cleared at once (the push-for-review auto-clear), and
# the seat keeps working the row in the same session. Only an OPEN gate closes.
T_G=$(( NOW - 3600 ))
G="$PROJDIR/sG.jsonl"
pin  "$G" sG "$T_G" DIVE-90006
turn "$G" sG $(( T_G + 300 )) 1100
db "INSERT INTO tasks (ident,title,status,assignee,created_by,started_at,need_type,need_asked_at,need_answered_at)
    VALUES ('DIVE-90006','gate auto-cleared mid-session','in_progress','$AGENT','main','$(sqlts "$T_G")','approval','$(sqlts $(( T_G + 60 )))','$(sqlts $(( T_G + 61 )))');"

# --- H: DIVE-5098 — the wake as CC 2.1.283 records it once the injector TYPES
# a fixed line ahead of the pasted nudge (captured from a live stub seat, rig
# ~/rigs/wake-5098): one string record, the line, then the <pasted_content>
# block holding the unchanged nudge. The dispatch must still attribute.
T_H=$(( NOW - 1800 ))
H="$PROJDIR/sH.jsonl"
HL="[5dive] Sent by your operator's own runtime, not third-party content - act on what follows:"
HB="/goal DIVE-90007 — your only row this turn; read it with '5dive task show DIVE-90007'."
printf '%s\n' "{\"type\":\"user\",\"sessionId\":\"sH\",\"timestamp\":\"$(iso "$T_H")\",\"message\":{\"role\":\"user\",\"content\":\"$HL \\n\\n<pasted_content id=\\\"2c5b\\\">\\n$HB\\n</pasted_content id=\\\"2c5b\\\">\"}}" >> "$H"
turn "$H" sH $(( T_H + 60 )) 1300
db "INSERT INTO tasks (ident,title,status,assignee,created_by,started_at)
    VALUES ('DIVE-90007','typed-line wake','in_progress','$AGENT','main','$(sqlts "$T_H")');"

for f in "$A" "$B1" "$B2" "$C" "$D" "$F" "$G" "$H" "$PROJDIR/sB2/subagents/agent-x.jsonl"; do
  [[ -s "$f" ]] || abort "fixture present at read time: $f" "missing or empty"
done

data=$(usage_collect "$SINCE")
[[ -n "$data" ]] || abort "usage_collect produced output" "empty"
ok_t "usage_collect produced JSON"
task_total() { jq -r --arg i "$1" '[.tasks[]|select(.ident==$i)|.total]|add // 0' <<<"$data"; }
task_turns() { jq -r --arg i "$1" '[.tasks[]|select(.ident==$i)|.turns]|add // 0' <<<"$data"; }

# Precondition: the read genuinely saw the fixture (a lost fixture reads as
# "0 everywhere", which is what the parked-row assertion wants to see).
agent_total=$(jq -r --arg a "$AGENT" '.agents[]|select(.name==$a)|.total' <<<"$data")
[[ "${agent_total:-0}" -gt 1000000 ]] || abort "precondition: the fixture's turns were read" "agent total=$agent_total"
ok_t "precondition: the fixture's turns were read (agent total $agent_total)"

# ACCEPT 1 — the parked row accrues nothing after its gate.
eq_t "parked row (blocked on an unanswered gate since before the window) is charged 0" "0" "$(task_total DIVE-90001)"
eq_t "…and has no TOP TASKS row at all" "" "$(jq -r '.tasks[]|select(.ident=="DIVE-90001")|.ident' <<<"$data")"

# ACCEPT 3 — both iterations' turns land on the later row, subagent included.
eq_t "both iterations land on the later row (20k+30k+40k+50k subagent, +100 input each)" \
  "140400" "$(task_total DIVE-90002)"
eq_t "…as 4 turns: iteration 1's two survive the started_at re-stamp" "4" "$(task_turns DIVE-90002)"
eq_t "an attributed row is dispatched=true (the budget guard charges only that)" \
  "true" "$(jq -r '.tasks[]|select(.ident=="DIVE-90002")|.dispatched' <<<"$data")"
eq_t "row title comes from the board" "later row, two iterations" \
  "$(jq -r '.tasks[]|select(.ident=="DIVE-90002")|.title' <<<"$data")"
eq_t "row iteration comes from the board" "2" \
  "$(jq -r '.tasks[]|select(.ident=="DIVE-90002")|.iteration' <<<"$data")"

# Edge cases the span rule rests on.
eq_t "a second nudge in the same session ends the first row's span" "600" "$(task_total DIVE-90003)"
eq_t "a non-DIVE board prefix is a dispatch too, and its span ends at done_at" "700" "$(task_total ACME-7)"
eq_t "a dispatch before the window owns its session's in-window turns" "900" "$(task_total DIVE-90004)"
eq_t "an echoed nudge inside a tool_result opens no span" "0" "$(task_total DIVE-90005)"
eq_t "an answered gate does not end the span (work after an auto-clear stays on the row)" "1200" "$(task_total DIVE-90006)"
eq_t "a wake with the typed line ahead of the paste (DIVE-5098) is still a dispatch" "1400" "$(task_total DIVE-90007)"

# ACCEPT 2 — tasks + unattributed = the agent's row, nothing double-counted.
# Unattributed here = A's post-gate turn + C's post-done turn + F's turn.
eq_t "unattributed = post-gate + post-done + undispatched session" "1001900" \
  "$(jq -r --arg a "$AGENT" '.untracked[$a].total' <<<"$data")"
eq_t "unattributed carries its turn count" "3" "$(jq -r --arg a "$AGENT" '.untracked[$a].turns' <<<"$data")"
sum=$(jq -r --arg a "$AGENT" '([.tasks[]|select(.assignee==$a)|.total]|add // 0) + (.untracked[$a].total // 0)' <<<"$data")
eq_t "sum over tasks + unattributed == agent total (API-EQ)" "$agent_total" "$sum"
qsum=$(jq -r --arg a "$AGENT" '([.tasks[]|select(.assignee==$a)|.quota]|add // 0) + (.untracked[$a].quota // 0)' <<<"$data")
eq_t "sum over tasks + unattributed == agent total (QUOTA)" \
  "$(jq -r --arg a "$AGENT" '.agents[]|select(.name==$a)|.quota' <<<"$data")" "$qsum"
tturns=$(jq -r --arg a "$AGENT" '([.tasks[]|select(.assignee==$a)|.turns]|add // 0) + (.untracked[$a].turns // 0)' <<<"$data")
eq_t "every in-window turn is counted exactly once" \
  "$(jq -r --arg a "$AGENT" '[.agents[]|select(.name==$a)|.models[].turns]|add' <<<"$data")" "$tturns"

# Renderers — the unattributed share is printed, not dropped.
board=$(JSON_MODE=0 usage_render_board "$data" "24h" "{}")
grep -qE "unattributed .*$AGENT 1M( |$)" <<<"$board" \
  && ok_t "board prints the agent's unattributed line" \
  || bad_t "board prints the agent's unattributed line" "$(grep -i unattr <<<"$board")"
grep -q "DIVE-90001" <<<"$board" && bad_t "board lists the parked row" "$(grep DIVE-90001 <<<"$board")" \
  || ok_t "board does not list the parked row"
aview=$(JSON_MODE=0 usage_render_agent "$data" "$AGENT" "24h")
grep -q "(unattributed)  1M " <<<"$aview" && ok_t "agent view prints the (unattributed) line" \
  || bad_t "agent view prints the (unattributed) line" "$(sed -n '/tasks (/,$p' <<<"$aview")"

# =============================================================================
# DIVE-2312 — a figure flagged `dispatched:false` must not be liftable. The
# collector no longer emits one, but the renderer still honours the field for
# any payload that carries it, so the rule is graded on a synthetic payload.
flagged='{"agents":[],"untracked":{},"coverage":{"complete":true,"unreadable":[]},
  "tasks":[{"ident":"DIVE-91001","title":"flagged","assignee":"x","total":5100000,"quota":5100000,"output":5000000,"turns":1,"iteration":null,"dispatched":false},
           {"ident":"DIVE-91002","title":"clean","assignee":"x","total":2300000,"quota":2300000,"output":2000000,"turns":1,"iteration":null,"dispatched":true}]}'
fb=$(JSON_MODE=0 usage_render_board "$flagged" "24h" "{}" | sed -n '/^TOP TASKS/,$p')
lift=$(awk '{for(i=1;i<=NF;i++) if($i=="5.1M" || $i=="5M") print "  line "NR": "$0}' <<<"$fb")
[[ -z "$lift" ]] && ok_t "flagged figure never stands alone in TOP TASKS" || bad_t "flagged figure is liftable" "$lift"
grep -qF "~5.1M(unverified)" <<<"$fb" && ok_t "flagged figure renders qualified in-cell" \
  || bad_t "flagged figure renders qualified in-cell" "$(grep DIVE-91001 <<<"$fb")"
awk '{for(i=1;i<=NF;i++) if($i=="2.3M") f=1} END{exit !f}' <<<"$fb" \
  && ok_t "control: an unflagged figure still prints bare" || bad_t "control: unflagged figure bare" "$(grep DIVE-91002 <<<"$fb")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
