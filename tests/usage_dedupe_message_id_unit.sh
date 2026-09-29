#!/usr/bin/env bash
# DIVE-677 unit: every transcript scanner that sums `message.usage` must charge
# ONE API response ONCE, not once per transcript line.
#
# The bug this guards: Claude Code writes one JSONL line per CONTENT BLOCK
# (thinking / text / tool_use) of a single API response, and every one of those
# lines repeats the same message.id, the same requestId and an IDENTICAL usage
# object. The scanners summed per line, so a response was billed once per block.
# Measured 2026-09-29: marcus's session 5ff518ff read 195.0M against 84.8M per
# response (2.30x); DIVE-675 was charged 174.87M against the 102.7M its own
# transcripts spent (1.70x) and parked early under the 150M per-row default.
#
# WHY THIS SHAPE:
#   * EVERY READER, not just the headline. The per-row budget and the agent and
#     account rows read usage_collect; the activity trail reads activity_collect;
#     the per-loop ceiling reads _spend_scan_task_ids; the session-segment spend
#     reads _spend_scan_task_sessions. Fixing one leaves the others quoting the
#     inflated figure, so each is driven on the same fixture.
#   * THE CONTROL HALF IS ASSERTED. Dedupe must key on identity, never on value:
#     two DISTINCT responses with identical usage are two charges, and a line
#     carrying neither message.id nor requestId cannot be matched and still
#     counts. A fix that collapses by usage value, or drops unkeyed lines, fails.
#   * EACH FIELD KEEPS ITS LARGEST VALUE. The lines of one response are not
#     always identical: an early block can carry a partial output_tokens (8, then
#     205), fleet-wide 1,454 of 37,140 responses on 2026-09-29, and in 2 of them
#     the last line was not the largest. Keeping the first line or the last line
#     both under-count; the delta agent fails either.
#   * THE ACTIVITY TRAIL still reads tool_use blocks PER LINE: only the usage is
#     deduplicated, never the content.
#
# The fixture (cost basis = in+out+cc; quota basis adds cr):
#   alpha  msg_A written as 3 lines (thinking, text, tool_use Bash)  400 / 40000
#          msg_B, 1 line                                              40 /  4000
#          msg_C, 1 line, SAME usage as msg_B, different id           40 /  4000
#          -> 480 / 48000, 3 turns          (pre-fix: 1280 / 128000, 5 turns)
#   beta   requestId-only response, 2 lines                           10 /  1000
#          two unkeyed lines (no id, no requestId), each               1 /   100
#          -> 12 / 1200                     (pre-fix: 22 / 2200)
#   gamma  msg_G1 x2 in the session file                              20 /  2000
#          msg_G2 x3 in a subagent file of that session                3 /   300
#          msg_G1 once more in a second session file (a copied turn)
#          -> 23 / 2300                     (pre-fix: 69 / 6900)
#   delta  msg_D x3, output_tokens 8 then 205 then 205 (a streaming partial
#          on the first block; in/cc/cr identical)                   307 /  1307
#          msg_E x2, output_tokens 50 then 7 (the LAST line is not the max) 61 / 161
#          -> 368 / 1468  (keep-first reads 171 cost, keep-last 325; pre-fix 803)
#
# NEGATIVE CONTROL (how to re-run it):
#   mkdir -p /tmp/pre677 && for f in cmd_usage.sh cmd_loop.sh; do
#     git show upstream/main:src/$f > /tmp/pre677/$f; done
#   USAGE_SRC_DIR=/tmp/pre677 bash tests/usage_dedupe_message_id_unit.sh   # must FAIL
#
#   bash tests/usage_dedupe_message_id_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

SRC_DIR="${USAGE_SRC_DIR:-src}"
TMP="$(mktemp -d /tmp/usage-dedupe.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1 ($3)" || bad_t "$1" "want $3, got ${2:-<empty>}"; }

command -v sqlite3 >/dev/null || { echo "SKIP - sqlite3 unavailable"; exit 0; }

NOW="$(date +%s)"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
T0=$((NOW-600))          # dispatch / row start
T1="$(iso $((NOW-300)))" # every turn lands here, inside every window

# turn <file> <msg.id|""> <requestId|""> <block> <in> <out> <cc> <cr>
turn() {
  local f="$1" mid="$2" rid="$3" blk="$4" content
  mkdir -p "$(dirname "$f")"
  case "$blk" in
    thinking) content='[{"type":"thinking","thinking":"..."}]' ;;
    text)     content='[{"type":"text","text":"ok"}]' ;;
    bash)     content='[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"true","description":"noop"}}]' ;;
  esac
  jq -cn --arg ts "$T1" --arg mid "$mid" --arg rid "$rid" --argjson c "$content" \
     --argjson i "$5" --argjson o "$6" --argjson cc "$7" --argjson cr "$8" '
    {type:"assistant", timestamp:$ts,
     message:({model:"m", content:$c,
               usage:{input_tokens:$i, output_tokens:$o,
                      cache_creation_input_tokens:$cc, cache_read_input_tokens:$cr}}
              + (if $mid == "" then {} else {id:$mid} end))}
    + (if $rid == "" then {} else {requestId:$rid} end)' >> "$f"
}
goal() {  # goal <file> <ident> — the heartbeat dispatch that opens the session's span
  mkdir -p "$(dirname "$1")"
  jq -cn --arg ts "$(iso "$T0")" --arg id "$2" \
    '{type:"user",timestamp:$ts,message:{role:"user",content:("/goal " + $id + " — your only row this turn; read it.")}}' >> "$1"
}

R="$TMP/homes"
SA="11111111-aaaa-4000-8000-000000000001"
SG="22222222-bbbb-4000-8000-000000000002"
SG2="33333333-cccc-4000-8000-000000000003"
A="$R/agent-alpha/.claude/projects/proj/$SA.jsonl"
goal "$A" DIVE-9001
turn "$A" msg_A req_A thinking 100 50 250 39600
turn "$A" msg_A req_A text     100 50 250 39600
turn "$A" msg_A req_A bash     100 50 250 39600
turn "$A" msg_B req_B text      10  5  25  3960
turn "$A" msg_C req_C text      10  5  25  3960

B="$R/agent-beta/.claude/projects/proj/beta.jsonl"
turn "$B" "" req_R thinking 5 2 3 990
turn "$B" "" req_R text     5 2 3 990
turn "$B" "" ""    text     1 0 0  99
turn "$B" "" ""    text     1 0 0  99

G="$R/agent-gamma/.claude/projects/proj/$SG.jsonl"
goal "$G" DIVE-9002
turn "$G" msg_G1 req_G1 thinking 10 4 6 1980
turn "$G" msg_G1 req_G1 text     10 4 6 1980
GS="$R/agent-gamma/.claude/projects/proj/$SG/subagents/agent-x.jsonl"
turn "$GS" msg_G2 req_G2 thinking 1 1 1 297
turn "$GS" msg_G2 req_G2 text     1 1 1 297
turn "$GS" msg_G2 req_G2 bash     1 1 1 297
turn "$R/agent-gamma/.claude/projects/proj/$SG2.jsonl" msg_G1 req_G1 text 10 4 6 1980

SD="44444444-dddd-4000-8000-000000000004"
D="$R/agent-delta/.claude/projects/proj/$SD.jsonl"
goal "$D" DIVE-9003
turn "$D" msg_D req_D thinking 2   8 100 1000
turn "$D" msg_D req_D text     2 205 100 1000
turn "$D" msg_D req_D bash     2 205 100 1000
turn "$D" msg_E req_E text     1  50  10  100
turn "$D" msg_E req_E text     1   7  10  100

# ============================================================================
# PART A — usage_collect: the agent rows, the per-row task totals, the account.
# Only the FIRST heredoc is usage_collect; the file holds others.
# ============================================================================
awk "/python3 - <<'PY'/{if(++n==1){f=1;next}} f&&/^PY\$/{f=0} f" "$SRC_DIR/cmd_usage.sh" > "$TMP/collect.py"
[[ -s "$TMP/collect.py" ]] || { echo "FAIL - could not extract usage_collect python"; exit 1; }
printf '{"agents":{"alpha":{"type":"claude"},"beta":{"type":"claude"},"gamma":{"type":"claude"},"delta":{"type":"claude"}}}' > "$TMP/reg.json"
sqlite3 "$TMP/board.db" "CREATE TABLE tasks (ident TEXT, title TEXT, assignee TEXT, started_at TEXT, done_at TEXT, iteration INT, status TEXT);
  INSERT INTO tasks VALUES ('DIVE-9001','multi-block row','alpha','$(date -u -d @$T0 +'%F %T')',NULL,NULL,'in_progress');
  INSERT INTO tasks VALUES ('DIVE-9002','subagent row','gamma','$(date -u -d @$T0 +'%F %T')',NULL,NULL,'in_progress');
  INSERT INTO tasks VALUES ('DIVE-9003','streaming row','delta','$(date -u -d @$T0 +'%F %T')',NULL,NULL,'in_progress');"
OUT="$(REGISTRY="$TMP/reg.json" TASK_DB="$TMP/board.db" USAGE_SINCE="$((NOW-3600))" \
       USAGE_HOME_ROOT="$R" python3 "$TMP/collect.py" 2>"$TMP/collect.err")"
[[ -n "$OUT" ]] || { echo "FAIL - collector produced nothing: $(head -3 "$TMP/collect.err")"; exit 1; }
ag() { jq -r --arg n "$1" ".agents[] | select(.name==\$n) | $2" <<<"$OUT"; }
tk() { jq -r --arg n "$1" ".tasks[] | select(.ident==\$n) | $2" <<<"$OUT"; }

eq_t "collector: a 3-block response counts ONCE — alpha quota"          "$(ag alpha .quota)" 48000
eq_t "collector: alpha cost basis follows"                             "$(ag alpha .total)" 480
eq_t "collector: turns count RESPONSES, not lines"                     "$(ag alpha '.models.m.turns')" 3
eq_t "collector: the per-row total (the budget's figure) is deduped"   "$(tk DIVE-9001 .quota)" 48000
eq_t "collector: the per-row turn count is deduped"                    "$(tk DIVE-9001 .turns)" 3
eq_t "collector: requestId dedupes a response with no message.id; unkeyed lines still count" \
                                                                       "$(ag beta .quota)" 1200
eq_t "collector: a subagent response counts once, and a turn copied into a second session file is not re-billed" \
                                                                       "$(ag gamma .quota)" 2300
eq_t "collector: the subagent's once-counted spend reaches its parent's row" \
                                                                       "$(tk DIVE-9002 .quota)" 2300
# control: two distinct responses with EQUAL usage must stay two charges — a
# value-keyed dedupe would read alpha as 44000 and this would catch it.
[[ "$(ag alpha .quota)" != 44000 ]] \
  && ok_t "control: equal usage under DIFFERENT ids is two charges, not one" \
  || bad_t "control: dedupe collapsed by value" "alpha quota 44000 = msg_C dropped"
eq_t "collector: a partial output_tokens on an early block is raised to the final count, once" \
                                                                       "$(ag delta .total)" 368
eq_t "collector: the streaming response's quota and output"           "$(ag delta '[.quota,.output]|join("/")')" 1468/255
eq_t "collector: the streaming row's per-row total"                    "$(tk DIVE-9003 .quota)" 1468
eq_t "collector: the account row sums the deduped agents" \
     "$(jq -r '[.agents[].quota] | add' <<<"$OUT")" 52968

# ============================================================================
# PART B — activity_collect: tokens deduped, tool_use blocks still read per line.
# ============================================================================
# shellcheck disable=SC1091
source src/lib/error_codes.sh 2>/dev/null || { E_USAGE=2; E_GENERIC=1; E_PERMISSION=77; E_VALIDATION=3; }
JSON_MODE=0
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
fail() { printf 'error: %s\n' "${2:-}" >&2; exit "${1:-1}"; }
ok()   { printf 'ok: %s\n' "${1:-}"; }
# shellcheck disable=SC1090
source "$SRC_DIR/cmd_usage.sh"
ACT="$(A_HOME_ROOT="$R" activity_collect alpha "$((NOW-3600))" - - 2>"$TMP/act.err")"
eq_t "activity: token total charges each response once"     "$(jq -r '.tokens.total' <<<"$ACT")" 480
eq_t "activity: output tokens charged once"                 "$(jq -r '.tokens.output' <<<"$ACT")" 60
eq_t "activity: the Bash tool_use on msg_A's third line is still read" \
                                                            "$(jq -r '.counts.bash' <<<"$ACT")" 1
ACT="$(A_HOME_ROOT="$R" activity_collect delta "$((NOW-3600))" - - 2>>"$TMP/act.err")"
eq_t "activity: a streaming response is charged its largest output, once" \
     "$(jq -r '[.tokens.total,.tokens.output]|join("/")' <<<"$ACT")" 368/255

# ============================================================================
# PART C — the loop readers (per-loop ceiling, session-segment spend).
# ============================================================================
for f in header.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  # shellcheck disable=SC1090
  source "src/$f"
done
# shellcheck disable=SC1090
source "$SRC_DIR/cmd_loop.sh"
TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init >/dev/null 2>&1; _tasks_db_migrate >/dev/null 2>&1
st="$(date -u -d @$T0 +'%F %T')"
db "INSERT INTO tasks (ident,title,status,assignee,kind,started_at,created_at,updated_at)
    VALUES ('DIVE-9001','multi-block row','in_progress','alpha','standard','$st','$st','$st');"
TID="$(db "SELECT id FROM tasks WHERE ident='DIVE-9001';")"
db "INSERT INTO tasks (ident,title,status,assignee,kind,started_at,created_at,updated_at)
    VALUES ('DIVE-9003','streaming row','in_progress','delta','standard','$st','$st','$st');"
TID3="$(db "SELECT id FROM tasks WHERE ident='DIVE-9003';")"
REGISTRY="$TMP/reg.json"
LOOP_HOME_OVERRIDE_JSON="{\"alpha\":\"$R/agent-alpha\",\"beta\":\"$R/agent-beta\",\"gamma\":\"$R/agent-gamma\",\"delta\":\"$R/agent-delta\"}"
export REGISTRY LOOP_HOME_OVERRIDE_JSON

SPENT="$(_spend_scan_task_ids "[$TID]" 0 2>"$TMP/loop.err")"
eq_t "loop ceiling: _spend_scan_task_ids charges each response once" "$SPENT" 480
SPENT="$(_spend_scan_task_ids "[$TID3]" 0 2>>"$TMP/loop.err")"
eq_t "loop ceiling: a streaming response is charged its largest output, once" "$SPENT" 368

if db "INSERT INTO task_sessions (task_id,session_id,agent,started_at) VALUES ($TID,'$SA','alpha','$st');" 2>/dev/null; then
  SEG="$(_spend_scan_task_sessions "[$TID]" 2>"$TMP/seg.err")"
  eq_t "session segments: _spend_scan_task_sessions charges each response once" "$SEG" 480
  db "INSERT INTO task_sessions (task_id,session_id,agent,started_at) VALUES ($TID3,'$SD','delta','$st');"
  SEG="$(_spend_scan_task_sessions "[$TID3]" 2>>"$TMP/seg.err")"
  eq_t "session segments: a streaming response is charged its largest output, once" "$SEG" 368
else
  bad_t "session segments: could not seed task_sessions" "$(db ".schema task_sessions" 2>&1 | head -3)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
