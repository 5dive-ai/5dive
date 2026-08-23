#!/usr/bin/env bash
# DIVE-3349 (build half of DIVE-3348): the per-task token figure comes from a
# signal that NAMES THE ROW, not from a window.
#
# THE DEFECT THIS GRADES. `_spend_scan_task_ids` keys on a row's ASSIGNEE and
# sums every transcript under that seat's home inside [started_at, done_at or
# now]. A transcript line carries a timestamp and a usage block and NOTHING that
# names a task, so the charge is the seat's whole spend for the WIDTH of the
# window — and the width is the row's wall-clock age. Two inversions follow, and
# both are ARMS here rather than assertions about code:
#   - an OPEN, IDLE row outscores an actively worked one (nothing closes its
#     window), and
#   - two rows open on one seat are EACH billed the seat's spend; the figures do
#     not sum to the day, they each approach it.
# That is what DIVE-3343 removed the per-task budget over. Compiled:
#   community/wiki/per-task-token-attribution-the-session-id-is-the-signal.md
#   community/wiki/a-task-attributed-token-figure-measures-the-rows-age-not-its-work.md
#
# TWO-SIDED BY CONSTRUCTION, and this is the point of the harness rather than a
# nicety. Every arithmetic arm runs BOTH readers over the SAME fixture: the new
# session-segment reader and the shipped assignee-window one. A one-sided arm
# asserting "the new reader says 100" would pass against a fixture that simply
# had no other spend in it — it would grade my arithmetic and say nothing about
# attribution. Printing the old reader's answer beside it is what makes each
# fixture non-vacuous: the two numbers DISAGREE, and the disagreement is the
# defect, measured.
#
# THE FIXTURE TRAP (inherited from DIVE-3341's harness, named in the DIVE-3349
# body): a fixture needs its OWN agent and its OWN HOME or it silently re-prices
# every sibling arm — the readers glob a seat's whole `.claude/projects` tree, so
# one shared home makes arm N's decoy transcript part of arm M's answer and the
# expected numbers drift with the arm ORDER. Every arm below gets a distinct
# `seg*` seat and a distinct `$TMP/home-*`, and the decoy transcripts are what
# would leak if that were violated.
#
# Run: bash tests/task_session_segments_unit.sh   (no root, no network.)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE the absence of `2>/dev/null` — the helper's stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: one trap, every exit path.
cd "$(dirname "$0")/.."
# DIVE-2518: identity comes from the uid — impersonate through the sealed seam.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
as_agent() { local _w="$1"; shift; ( actor_seam_as "$_w"; "$@" ); }
SRC=src
TMP="$(mktemp -d /tmp/task-session-seg.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_loop.sh cmd_usage.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init; _tasks_db_migrate

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
jf()    { jq -r "$1" 2>/dev/null; }

now=$(date +%s)
sqlts() { date -u -d "@$1" '+%F %T'; }          # task_sessions / tasks TEXT form
isots() { date -u -d "@$1" '+%FT%TZ'; }         # transcript timestamp form

# turn <file> <epoch> <total-tokens> — one assistant turn worth exactly N of the
# limit-moving metric BOTH readers use (input + output + cache-WRITE; cache-READ
# excluded, so the big cache_read here must NOT show up in any figure).
turn() { printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":%d,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":987654}}}\n' "$(isots "$2")" "$3" >> "$1"; }

# Every fixture seat is registered type=claude: the OLD reader skips non-claude
# seats, and a control arm that was skipped rather than answered would print 0
# and read exactly like a fix.
REGISTRY="$TMP/registry.json"
HOMES_JSON="{}"
# mkhome <seat> — sets $HDIR to that seat's transcript dir and registers the
# seat + its home override. NOT command-substituted on purpose: the home map and
# its export must land in THIS shell, and `dir=$(mkhome x)` would build them in a
# subshell that then exits. The readers would see an empty override map and fall
# back to /home/agent-<seat> — an unwritable path, so every arm would read
# NOT-REACHED and the harness would grade nothing while looking merely red.
mkhome() {
  local seat h
  seat="$1"; h="$TMP/home-$seat"
  mkdir -p "$h/.claude/projects/p"
  HOMES_JSON=$(printf '%s' "$HOMES_JSON" | jq -c --arg k "$seat" --arg v "$h" '.[$k]=$v')
  LOOP_HOME_OVERRIDE_JSON="$HOMES_JSON"; export LOOP_HOME_OVERRIDE_JSON
  reg_add "$seat"
  HDIR="$h/.claude/projects/p"
}
REG_SEATS=""
reg_add() {
  REG_SEATS="$REG_SEATS $1"
  local j='{"agents":{'; local first=1 s
  for s in $REG_SEATS; do [[ $first == 1 ]] || j="$j,"; j="$j\"$s\":{\"type\":\"claude\"}"; first=0; done
  printf '%s}}' "$j" > "$REGISTRY"
}
export REGISTRY

# new <task_id> -> "<rc>:<stdout>". stderr is kept in $TMP/new.err and never
# swallowed: the reader's CAUSE line goes there by design.
new() { local o rc; o=$(_spend_scan_task_sessions "[$1]" 2>"$TMP/new.err"); rc=$?; printf '%s:%s' "$rc" "$o"; }
old() { _spend_scan_task_ids "[$1]" 2>/dev/null; }

mkrow() {  # mkrow <seat> <title> -> task id
  local seat="$1" title="$2" out
  out=$(as_agent "$seat" cmd_task_add --assignee="$seat" -- "$title" 2>"$TMP/err")
  printf '%s' "$out" | jf '.data.id'
}
# Set a row's window in BOTH stores so the two readers are asked about the same
# stretch of time. The real verbs stamp datetime('now'), which gives a
# zero-width window no transcript turn can land in — so the WIRING arms below
# drive the real verbs and these arithmetic arms move the timestamps.
setwin() { # setwin <tid> <sid> <seat> <start-epoch> <end-epoch|-> ; '-' = still open
  local tid="$1" sid="$2" seat="$3" s="$4" e="$5"
  local send="NULL" tend="NULL"
  [[ "$e" != "-" ]] && { send="'$(sqlts "$e")'"; tend="'$(sqlts "$e")'"; }
  db "DELETE FROM task_sessions WHERE task_id=${tid};"
  db "INSERT INTO task_sessions (task_id,session_id,agent,started_at,ended_at)
      VALUES (${tid},'${sid}','${seat}','$(sqlts "$s")',${send});"
  db "UPDATE tasks SET assignee='${seat}', started_at='$(sqlts "$s")', done_at=${tend} WHERE id=${tid};"
}

# ============================================================================
# ARM 1 — THE WIRING, through the REAL verbs. No stub, no hand-written row:
# whatever `task start` / `task done` actually record is what is graded.
# ============================================================================
mkhome segW; dirW="$HDIR"
SIDW="11111111-aaaa-4bbb-8ccc-111111111111"
tW=$(mkrow segW "wiring fixture")
export CLAUDE_CODE_SESSION_ID="$SIDW"
as_agent segW cmd_task_start "$tW" >/dev/null 2>"$TMP/err"
seg_n=$(db "SELECT COUNT(*) FROM task_sessions WHERE task_id=${tW};")
seg_sid=$(db "SELECT session_id FROM task_sessions WHERE task_id=${tW};")
seg_ag=$(db "SELECT agent FROM task_sessions WHERE task_id=${tW};")
seg_end=$(db "SELECT IFNULL(ended_at,'OPEN') FROM task_sessions WHERE task_id=${tW};")
[[ "$seg_n" == "1" && "$seg_sid" == "$SIDW" && "$seg_ag" == "segW" && "$seg_end" == "OPEN" ]] \
  && ok_t "task start records ONE open segment naming the session and the seat" \
  || bad_t "task start segment wrong" "n=$seg_n sid=$seg_sid agent=$seg_ag end=$seg_end"

# A second claim in the SAME session must not open a second segment: two open
# segments on one session would overlap each other and turn the row AMBIGUOUS
# against itself — a row made unmeasurable by being re-claimed.
as_agent segW cmd_task_start "$tW" >/dev/null 2>&1
seg_n2=$(db "SELECT COUNT(*) FROM task_sessions WHERE task_id=${tW};")
[[ "$seg_n2" == "1" ]] \
  && ok_t "re-claim in the same session does NOT open a second (self-overlapping) segment" \
  || bad_t "re-claim opened a duplicate segment" "count=$seg_n2"

# The `agent` column names the home the reader opens a transcript under, so it
# must come from the CALLER'S UID through the sealed seam and not from $SUDO_USER
# — the unverified variable DIVE-2518 closed for actor attribution. This arm sets
# the spoof and asserts the column does not move. (The first cut of the writer
# read $SUDO_USER and this arm is what caught it; it reds on that code.)
tS=$(mkrow segW "sudo_user spoof fixture")
export CLAUDE_CODE_SESSION_ID="$SIDW"
( SUDO_USER=agent-olivia; export SUDO_USER; actor_seam_as segW; cmd_task_start "$tS" ) >/dev/null 2>&1
spoof=$(db "SELECT IFNULL(agent,'NULL') FROM task_sessions WHERE task_id=${tS};")
[[ "$spoof" == "segW" ]] \
  && ok_t "SUDO_USER=agent-olivia does NOT move the segment's seat (stays segW)" \
  || bad_t "SUDO_USER spoofed the seat the reader will look under" "agent=$spoof"

as_agent segW cmd_task_done "$tW" --result="wiring" >/dev/null 2>"$TMP/err"
seg_end2=$(db "SELECT IFNULL(ended_at,'OPEN') FROM task_sessions WHERE task_id=${tW};")
[[ "$seg_end2" != "OPEN" ]] \
  && ok_t "task done stamps ended_at (the segment stops accruing)" \
  || bad_t "task done left the segment OPEN — it would keep charging this row forever" "$(cat "$TMP/err")"

# The delivery fork returns BEFORE the status funnel, so a row with a distinct
# verifier is the one path a funnel-only hook cannot see.
mkhome segV; dirV="$HDIR"
outV=$(as_agent segV cmd_task_add --assignee=segV --verifier=segVR -- "delivery fixture" 2>"$TMP/err")
tV=$(printf '%s' "$outV" | jf '.data.id')
export CLAUDE_CODE_SESSION_ID="22222222-aaaa-4bbb-8ccc-222222222222"
as_agent segV cmd_task_start "$tV" >/dev/null 2>&1
as_agent segV cmd_task_done  "$tV" --result="delivered" >/dev/null 2>"$TMP/err"
vst=$(db "SELECT status FROM tasks WHERE id=${tV};")
vend=$(db "SELECT IFNULL(ended_at,'OPEN') FROM task_sessions WHERE task_id=${tV};")
[[ "$vend" != "OPEN" ]] \
  && ok_t "deliver-to-verifier closes the segment too (status=$vst; it returns before the funnel)" \
  || bad_t "delivered row kept an OPEN segment" "status=$vst end=$vend"

# ============================================================================
# ARM 2 — NO SESSION AT ALL, and the hostile value. Through the real verb.
# NULL must read NOT-REACHED and must NEVER fall back to the window sum: that
# reinstates the quantity DIVE-3343 removed, under a name that sounds measured.
# ============================================================================
mkhome segN; dirN="$HDIR"
turn "$dirN/decoy.jsonl" $((now-100)) 500000        # the seat IS spending
tN=$(mkrow segN "cron-claimed fixture")
unset CLAUDE_CODE_SESSION_ID
as_agent segN cmd_task_start "$tN" >/dev/null 2>&1
nsid=$(db "SELECT IFNULL(session_id,'NULL') FROM task_sessions WHERE task_id=${tN};")
r=$(new "$tN"); rcN="${r%%:*}"; outN="${r#*:}"
[[ "$nsid" == "NULL" && "$rcN" == "4" && "$outN" == "NOT-REACHED" ]] \
  && ok_t "no session id -> NULL segment -> NOT-REACHED rc 4, not a number" \
  || bad_t "sessionless claim did not read NOT-REACHED" "stored=$nsid rc=$rcN out=$outN"

tH=$(mkrow segN "hostile session id fixture")
export CLAUDE_CODE_SESSION_ID='../../../etc/*'
as_agent segN cmd_task_start "$tH" >/dev/null 2>&1
hsid=$(db "SELECT IFNULL(session_id,'NULL') FROM task_sessions WHERE task_id=${tH};")
[[ "$hsid" == "NULL" ]] \
  && ok_t "a session id carrying path/glob metacharacters is stored as NULL, not trusted into a glob" \
  || bad_t "hostile session id was stored verbatim" "stored=$hsid"
unset CLAUDE_CODE_SESSION_ID

# ============================================================================
# ARM 3 — ACCEPTANCE 2. Two rows, ONE seat, ONE session, worked in sequence.
# They must yield DIFFERENT figures, and neither may equal the seat's total.
# The decoy session is the seat's other work: the old reader charges it to both
# rows because it is inside their windows; the new one cannot see it.
# ============================================================================
mkhome segA; dirA="$HDIR"
SIDA="33333333-aaaa-4bbb-8ccc-333333333333"
base=$((now-20000))
turn "$dirA/$SIDA.jsonl" $((base+100))   100     # inside row 1
turn "$dirA/$SIDA.jsonl" $((base+900))   700     # inside row 2
turn "$dirA/$SIDA.jsonl" $((base+5000)) 5000     # inside NEITHER window
turn "$dirA/decoy.jsonl" $((base+120))  4000     # other session, inside row 1's window
turn "$dirA/decoy.jsonl" $((base+700))  3000     # other session, inside row 2's window
SEAT_TOTAL=12800                                  # 100+700+5000+4000+3000

t1=$(mkrow segA "row one, worked first")
t2=$(mkrow segA "row two, worked second")
setwin "$t1" "$SIDA" segA "$base"        $((base+500))
setwin "$t2" "$SIDA" segA $((base+600))  $((base+1200))
r=$(new "$t1"); rc1="${r%%:*}"; f1="${r#*:}"
r=$(new "$t2"); rc2="${r%%:*}"; f2="${r#*:}"
o1=$(old "$t1"); o2=$(old "$t2")
[[ "$rc1" == 0 && "$rc2" == 0 && "$f1" == "100" && "$f2" == "700" ]] \
  && ok_t "acceptance 2: two rows in one session read 100 and 700 — DIFFERENT figures" \
  || bad_t "per-row figures wrong" "rc=$rc1/$rc2 f1=$f1 f2=$f2 $(cat "$TMP/new.err")"
[[ "$f1" != "$SEAT_TOTAL" && "$f2" != "$SEAT_TOTAL" ]] \
  && ok_t "acceptance 2: neither figure is the seat's total ($f1, $f2 vs $SEAT_TOTAL)" \
  || bad_t "a figure equals the seat total" "f1=$f1 f2=$f2 total=$SEAT_TOTAL"
# THE CONTROL. Same rows, same fixture, shipped reader.
[[ "$o1" == "4100" && "$o2" == "3700" ]] \
  && ok_t "control: the assignee-window reader mis-charges the SAME rows 4100/3700 (it eats the decoy session)" \
  || bad_t "control arm did not reproduce the window defect — the fixture may be vacuous" "old1=$o1 old2=$o2"
[[ "$f1" != "$o1" && "$f2" != "$o2" ]] \
  && ok_t "control: the two readers DISAGREE on both rows, so the arm grades attribution, not arithmetic" \
  || bad_t "readers agree — this fixture cannot distinguish them" "new=$f1/$f2 old=$o1/$o2"
# Cache-READ tokens are 987654 per turn and appear in neither figure.
[[ "$f1" == "100" ]] && ok_t "cache-read tokens excluded (987654/turn present, absent from the figure)" \
  || bad_t "cache-read leaked into the figure" "f1=$f1"

# ============================================================================
# ARM 4 — ACCEPTANCE 3. An idle row open 1500h with no work on it. This is the
# leaderboard inversion in its pure form: the seat spent 9M while the row sat.
# ============================================================================
mkhome segI; dirI="$HDIR"
SIDI="44444444-aaaa-4bbb-8ccc-444444444444"
idle_start=$((now-1500*3600))
turn "$dirI/$SIDI.jsonl" $((idle_start-3600)) 250000   # this session's work, BEFORE the claim
turn "$dirI/decoy.jsonl" $((now-7200))      9000000    # the seat's 9M, while the row sat idle
tI=$(mkrow segI "idle row, open 1500h")
setwin "$tI" "$SIDI" segI "$idle_start" -
r=$(new "$tI"); rcI="${r%%:*}"; fI="${r#*:}"
oI=$(old "$tI")
{ [[ "$rcI" == 0 && "$fI" == 0 ]] || { [[ "$rcI" == 4 ]] && [[ "$fI" == "NOT-REACHED" ]]; }; } \
  && ok_t "acceptance 3: idle row open 1500h reads $fI (rc $rcI) — 0 or NOT-REACHED" \
  || bad_t "idle row read as work" "rc=$rcI out=$fI $(cat "$TMP/new.err")"
[[ "$oI" == "9000000" ]] \
  && ok_t "control: the same idle row is charged 9000000 by the assignee-window reader (age, not work)" \
  || bad_t "idle control did not reproduce" "old=$oI"

# ============================================================================
# ARM 5 — the two hard cases from the design note.
# ============================================================================
# (a) one row, SEVERAL sessions -> the segments SUM.
mkhome segM; dirM="$HDIR"
SIDM1="55555555-aaaa-4bbb-8ccc-555555555551"
SIDM2="55555555-aaaa-4bbb-8ccc-555555555552"
mb=$((now-9000))
turn "$dirM/$SIDM1.jsonl" $((mb+50))   200
turn "$dirM/$SIDM2.jsonl" $((mb+1050)) 300
turn "$dirM/$SIDM1.jsonl" $((mb+4000)) 777777    # outside both segments
tM=$(mkrow segM "one row, two sessions")
db "UPDATE tasks SET assignee='segM', started_at='$(sqlts "$mb")', done_at=NULL WHERE id=${tM};"
db "DELETE FROM task_sessions WHERE task_id=${tM};"
db "INSERT INTO task_sessions (task_id,session_id,agent,started_at,ended_at) VALUES
    (${tM},'${SIDM1}','segM','$(sqlts "$mb")','$(sqlts $((mb+500)))'),
    (${tM},'${SIDM2}','segM','$(sqlts $((mb+1000)))','$(sqlts $((mb+1500)))');"
r=$(new "$tM"); rcM="${r%%:*}"; fM="${r#*:}"
[[ "$rcM" == 0 && "$fM" == "500" ]] \
  && ok_t "a row worked across two sessions SUMS its segments (200+300=500)" \
  || bad_t "multi-session sum wrong" "rc=$rcM out=$fM $(cat "$TMP/new.err")"

# (b) two rows INTERLEAVED in one session -> AMBIGUOUS, never a split.
mkhome segO; dirO="$HDIR"
SIDO="66666666-aaaa-4bbb-8ccc-666666666666"
ob=$((now-8000))
turn "$dirO/$SIDO.jsonl" $((ob+100)) 1234
tO1=$(mkrow segO "interleaved row one")
tO2=$(mkrow segO "interleaved row two")
setwin "$tO1" "$SIDO" segO "$ob"       $((ob+1000))
setwin "$tO2" "$SIDO" segO $((ob+500)) $((ob+1500))
r=$(new "$tO1"); rcO="${r%%:*}"; fO="${r#*:}"
[[ "$rcO" == 3 && "$fO" == "AMBIGUOUS" ]] \
  && ok_t "interleaved segments on one session -> AMBIGUOUS rc 3, not a split" \
  || bad_t "overlap did not refuse" "rc=$rcO out=$fO $(cat "$TMP/new.err")"
# The refusal must survive being asked about the OTHER row, and must name the pair.
r=$(new "$tO2"); rcO2="${r%%:*}"
grep -q "interleaved" "$TMP/new.err" 2>/dev/null; named=$?
[[ "$rcO2" == 3 ]] && ok_t "the refusal is symmetric — asking about the other row also refuses" \
  || bad_t "overlap refused for one row only" "rc=$rcO2"
# ...and it is NOT reached by two SEQUENTIAL rows (arm 3 already read 100/700),
# so the refusal is discriminating rather than a blanket.
[[ "$f1" == "100" && "$rcO" == 3 ]] \
  && ok_t "AMBIGUOUS discriminates: sequential rows in one session still measure" \
  || bad_t "refusal is not discriminating" "sequential=$f1 overlap_rc=$rcO"

# (c) a NAMED session whose transcript is missing -> NOT-REACHED, not 0. An
# unreadable read and an idle row must not be the same observation (DIVE-2304).
mkhome segX; dirX="$HDIR"
turn "$dirX/decoy.jsonl" $((now-600)) 400000
tX=$(mkrow segX "named session, no transcript")
setwin "$tX" "77777777-aaaa-4bbb-8ccc-777777777777" segX $((now-3600)) -
r=$(new "$tX"); rcX="${r%%:*}"; fX="${r#*:}"
[[ "$rcX" == 4 && "$fX" == "NOT-REACHED" ]] \
  && ok_t "a named session with no readable transcript is NOT-REACHED rc 4, not 0" \
  || bad_t "missing transcript read as zero" "rc=$rcX out=$fX"

# (d) a row with NO segments at all (never claimed under this scheme) —
# every pre-DIVE-3349 row on the live board is this case.
tZ=$(mkrow segX "row with no segments")
db "DELETE FROM task_sessions WHERE task_id=${tZ};"
r=$(new "$tZ"); rcZ="${r%%:*}"; fZ="${r#*:}"
[[ "$rcZ" == 4 && "$fZ" == "NOT-REACHED" ]] \
  && ok_t "a row with no segments (every row predating this change) reads NOT-REACHED" \
  || bad_t "segmentless row did not read NOT-REACHED" "rc=$rcZ out=$fZ"

# ============================================================================
# ARM 5b — DIVE-3374. THE SHARED SECOND. Two rows worked in sequence in one
# session, where row one's `done` and row two's `start` land in the SAME second,
# and a turn lands on exactly that instant.
#
# This is the seam between the two predicates over the same interval. The overlap
# detector is STRICT, so [b, b+500] and [b+500, b+1000] are legally sequential
# and both must still measure (arm 5b-i). The clip therefore has to agree that
# the boundary instant is in exactly ONE of them — with `<=` on both ends it was
# in both, and the boundary turn was charged TWICE.
#
# Why the 21 arms above cannot see it: every one of them places its turns
# strictly INSIDE a segment, which is what you write when the arms and the code
# come from the same mental model. The boundary is the one timestamp nobody
# chose. So this arm places one there on purpose, and grades the sum of the parts
# against the corpus — the direction the error runs (it OVERSTATES) is exactly
# the direction one addition can falsify.
#
# Compiled: community/wiki/two-inclusive-windows-that-touch-double-charge-the-shared-second.md
# ============================================================================
mkhome segB; dirB="$HDIR"
SIDB="88888888-aaaa-4bbb-8ccc-888888888888"
bb=$((now-30000))
turn "$dirB/$SIDB.jsonl" $((bb+100)) 100         # strictly inside row one
turn "$dirB/$SIDB.jsonl" $((bb+500)) 900         # ON THE SHARED SECOND
turn "$dirB/$SIDB.jsonl" $((bb+700)) 300         # strictly inside row two
turn "$dirB/decoy.jsonl" $((bb+200)) 5000        # the seat's other session
SESSION_CORPUS=1300                               # 100+900+300 — all of THIS session
tB1=$(mkrow segB "boundary row one, handed off")
tB2=$(mkrow segB "boundary row two, claimed the same second")
setwin "$tB1" "$SIDB" segB "$bb"        $((bb+500))
setwin "$tB2" "$SIDB" segB $((bb+500))  $((bb+1000))
r=$(new "$tB1"); rcB1="${r%%:*}"; fB1="${r#*:}"
r=$(new "$tB2"); rcB2="${r%%:*}"; fB2="${r#*:}"
# (i) touching is still SEQUENTIAL, not overlapping: if making the clip exclusive
# had been done to the detector instead, these two would refuse here.
[[ "$rcB1" == 0 && "$rcB2" == 0 ]] \
  && ok_t "DIVE-3374: segments that TOUCH are still sequential (rc 0/0, not AMBIGUOUS)" \
  || bad_t "touching segments stopped measuring" "rc=$rcB1/$rcB2 out=$fB1/$fB2 $(cat "$TMP/new.err")"
# (ii) the boundary turn lands in the LATER segment and in nothing else.
[[ "$fB1" == "100" && "$fB2" == "1200" ]] \
  && ok_t "DIVE-3374: the boundary turn is charged ONCE, to the later segment (100 / 1200)" \
  || bad_t "boundary turn mis-charged" "f1=$fB1 f2=$fB2 (expected 100/1200; 1000/1200 is the double-charge)"
# (iii) THE ARITHMETIC. The parts must sum to the corpus, not to corpus+boundary.
# Both figures are checked for NUMBERHOOD first: the reader's other exits are the
# WORDS AMBIGUOUS / NOT-REACHED, and `$(( AMBIGUOUS + ... ))` under `set -u` is an
# unbound-variable abort that kills the harness mid-file — every arm after this
# point would then be silently unrun rather than red.
if [[ "$fB1" =~ ^[0-9]+$ && "$fB2" =~ ^[0-9]+$ ]]; then
  sumB=$(( fB1 + fB2 ))
  [[ "$sumB" == "$SESSION_CORPUS" ]] \
    && ok_t "DIVE-3374: the two rows SUM to the session corpus ($sumB == $SESSION_CORPUS)" \
    || bad_t "the parts oversum the whole — the shared second is billed twice" \
             "sum=$sumB corpus=$SESSION_CORPUS oversum=$((sumB-SESSION_CORPUS))"
else
  bad_t "the parts cannot be summed — a figure is not a number" "f1=$fB1 f2=$fB2"
fi
# (iv) the control, so the arm is not vacuous: the shipped assignee-window reader
# eats the decoy session AND double-charges the same boundary second.
oB1=$(old "$tB1"); oB2=$(old "$tB2")
[[ "$oB1" == "6000" && "$oB2" == "1200" && $((oB1+oB2)) -gt "$SESSION_CORPUS" ]] \
  && ok_t "control: the assignee-window reader reads 6000/1200 on the same fixture (decoy + boundary)" \
  || bad_t "boundary control did not reproduce — the fixture may be vacuous" "old=$oB1/$oB2"

# ============================================================================
# ARM 7 — DIVE-3692. THE SIDECHAIN. `_spend_scan_task_sessions` globbed
# `projects/*/<sid>.jsonl`: ONE level, `glob.glob`, no `subagents/` descent.
#
# Claude Code does NOT write sidechain turns into the parent session's `.jsonl`
# (the design note this reader was built on asserted it does; measured false on
# two seats). They land in a sibling DIRECTORY named by the session id:
#
#     projects/<proj>/<sid>.jsonl                     the parent transcript
#     projects/<proj>/<sid>/subagents/*.jsonl         the sidechain turns
#
# Every turn in there carries the PARENT's sessionId, so the attribution was
# always correct and only the PATH was out of range. DIVE-3468 fixed exactly this
# for the assignee-window reader beside it and left this one — the actual
# deliverable of DIVE-3348/3349 — untouched, which is why the sibling reader is
# the control below rather than another opinion.
#
# WHY THE 25 ARMS ABOVE CANNOT SEE IT, and it is not an oversight of degree: every
# fixture in this file writes its turns into `<sid>.jsonl` and NONE creates the
# `subagents/` directory, so the harness is blind to the defect BY CONSTRUCTION.
# The arms and the code came from the same wrong mental model of the tree, so no
# amount of arithmetic arms over that fixture shape can reach it. This arm builds
# the other shape, with the sidechain as the MAJORITY of the corpus.
#
# Direction of failure, which is why it needed its own arm rather than a bound:
# no error, no NOT-REACHED, just a smaller CORRECT-LOOKING integer, under-charging
# exactly the rows that fan work out to subagents — i.e. the expensive ones.
# Nothing inside the numbers falsifies it.
#
# Compiled: community/wiki/subagent-turns-live-in-a-sibling-directory-the-transcript-glob-never-reaches.md
#           community/wiki/per-task-token-attribution-the-session-id-is-the-signal.md
# ============================================================================
mkhome segS; dirS="$HDIR"
SIDS="99999999-aaaa-4bbb-8ccc-999999999999"
sb=$((now-40000))
mkdir -p "$dirS/$SIDS/subagents" "$dirS/$SIDS/tool-results"
turn "$dirS/$SIDS.jsonl"                       $((sb+100)) 1000    # the parent session
turn "$dirS/$SIDS/subagents/agent-deadbeef.jsonl" $((sb+200)) 9000 # sidechain — the MAJORITY
turn "$dirS/$SIDS/subagents/agent-cafe0000.jsonl" $((sb+300))  500 # a SECOND fan-out file
# tool-results/ is a sibling of subagents/ in the same session dir and is present
# on every readable seat. It is NOT transcript turns, so a `*/*` sweep — the
# obvious over-broad way to reach the sidechain — would swallow it everywhere.
# The number is large enough that counting it cannot hide inside a rounding.
turn "$dirS/$SIDS/tool-results/leak.jsonl"     $((sb+250)) 777000
# A turn OUTSIDE the segment, inside the sidechain: reaching the file must not
# also mean abandoning the clip.
turn "$dirS/$SIDS/subagents/agent-deadbeef.jsonl" $((sb+9000)) 400000
SIDE_TOTAL=10500          # 1000 parent + 9000 + 500 sidechain, inside the window
tS=$(mkrow segS "row that fanned work out to subagents")
setwin "$tS" "$SIDS" segS "$sb" $((sb+1000))
r=$(new "$tS"); rcS="${r%%:*}"; fS="${r#*:}"
[[ "$rcS" == 0 && "$fS" == "$SIDE_TOTAL" ]] \
  && ok_t "acceptance 2: the sidechain MAJORITY is in the figure ($fS == $SIDE_TOTAL)" \
  || bad_t "the per-task figure excludes the sidechain" \
           "rc=$rcS out=$fS expected=$SIDE_TOTAL (1000 is parent-only — the one-level glob) $(cat "$TMP/new.err")"
# Majority, stated as an arm rather than left to the reader of the constants: if
# a later fixture edit made the sidechain a minority, the arm above would still
# pass while no longer grading the case the row was filed on.
[[ $((SIDE_TOTAL - 1000)) -gt 1000 ]] \
  && ok_t "…and the sidechain IS the majority of the corpus (9500 of $SIDE_TOTAL)" \
  || bad_t "fixture no longer grades the filed case" "sidechain=$((SIDE_TOTAL-1000)) parent=1000"
# Acceptance 4. Falsifiable: were tool-results/ enumerated the figure would be
# 787500, so this is a real negative control and not a restatement of the arm above.
[[ "$fS" =~ ^[0-9]+$ && "$fS" -lt 777000 ]] \
  && ok_t "acceptance 4: tool-results/ beside subagents/ is NOT enumerated (777000 absent from $fS)" \
  || bad_t "tool-results/ swept in — this is a \`*/*\` sweep, not an enumeration" "out=$fS"
# The clip still applies inside the sidechain file.
[[ "$fS" != "$((SIDE_TOTAL+400000))" ]] \
  && ok_t "…and the segment clip still applies to sidechain turns (the +400000 outside is excluded)" \
  || bad_t "reaching the file abandoned the window clip" "out=$fS"
# THE CONTROL, and it is what makes the arm non-vacuous. The SIBLING reader —
# fixed for this exact tree layout under DIVE-3468 — reads the same fixture and
# reaches $SIDE_TOTAL. So the corpus is genuinely on disk, readable by this uid,
# and countable by code in this same file: a per-task figure of 1000 is this
# reader's own blindness and not a property of the fixture.
oS=$(old "$tS")
[[ "$oS" == "$SIDE_TOTAL" ]] \
  && ok_t "control: the sibling assignee-window reader reaches the same $oS on this fixture (DIVE-3468)" \
  || bad_t "control did not reproduce — the fixture may be unreadable rather than unreached" "old=$oS"

# Acceptance 3. An unreadable subagents/ must be NOT-REACHED, not a smaller
# correct-looking integer. This is the `glob.glob`-swallows-OSError trap: reaching
# the files with a SECOND GLOB is only half the fix — glob yields nothing for a
# wildcard level it cannot read, so a chmod 000 subagents/ would rebuild this
# row's own defect one level deeper, by the change meant to remove it.
mkhome segU; dirU="$HDIR"
SIDU="aaaaaaaa-aaaa-4bbb-8ccc-aaaaaaaaaaaa"
ub=$((now-41000))
mkdir -p "$dirU/$SIDU/subagents"
turn "$dirU/$SIDU.jsonl"                          $((ub+100)) 1000
turn "$dirU/$SIDU/subagents/agent-deadbeef.jsonl" $((ub+200)) 9000
tU=$(mkrow segU "row whose sidechain dir is unreadable")
setwin "$tU" "$SIDU" segU "$ub" $((ub+1000))
r=$(new "$tU"); rcU0="${r%%:*}"; fU0="${r#*:}"
if [[ $EUID -eq 0 ]]; then
  # NOT ok_t: a skipped arm and a passing one render the same green, and this is
  # the arm the row's second measured failure lives in.
  printf 'SKIP - unreadable-subagents arm (running as root: chmod 000 does not deny)\n'
else
  chmod 000 "$dirU/$SIDU/subagents"
  r=$(new "$tU"); rcU="${r%%:*}"; fU="${r#*:}"
  [[ "$rcU" == 4 && "$fU" == "NOT-REACHED" ]] \
    && ok_t "acceptance 3: an unreadable subagents/ is NOT-REACHED rc 4, not a short integer" \
    || bad_t "unreadable sidechain returned a correct-looking number" \
             "rc=$rcU out=$fU (1000 is the silent understatement this row was filed on) $(cat "$TMP/new.err")"
  chmod 755 "$dirU/$SIDU/subagents"
  # The heal is the other half: the refusal must be about BLINDNESS, not about
  # the directory existing. If it stayed NOT-REACHED here, the arm above would
  # pass for the wrong reason and every fan-out row would read unmeasurable.
  r=$(new "$tU"); rcU2="${r%%:*}"; fU2="${r#*:}"
  [[ "$rcU2" == 0 && "$fU2" == "10000" ]] \
    && ok_t "…and the SAME dir healed reads 10000 through the same code — blindness, not absence" \
    || bad_t "healed sidechain did not recompute" "rc=$rcU2 out=$fU2 $(cat "$TMP/new.err")"
fi
# A session with NO subagents/ at all is an ordinary absence and must stay
# measurable — ENOENT/ENOTDIR are "nothing unread here", not a failed read. If
# this over-fires, every row that never fanned out now reads NOT-REACHED and the
# guard is disabled just as thoroughly as by understating. (Arms 3-5b are all
# this shape; asserted here so the acceptance-3 arm cannot pass by over-firing.)
[[ "$rcU0" == 0 && "$fU0" == "10000" ]] \
  && ok_t "a readable sidechain reads 10000 (parent 1000 + sidechain 9000)" \
  || bad_t "readable sidechain not summed" "rc=$rcU0 out=$fU0 $(cat "$TMP/new.err")"
# File granularity, one level below the arm above. A transcript we LOCATED and
# could not OPEN was dropped by a bare `continue` as long as some OTHER file in
# the set opened — harmless while the set held exactly one file, reachable the
# moment a row fans out, and the same silent understatement wearing a smaller
# number. Only the sidechain file is locked here; the parent stays readable, so
# a reader that reports 1000 has "successfully" read the row.
if [[ $EUID -ne 0 ]]; then
  chmod 000 "$dirU/$SIDU/subagents/agent-deadbeef.jsonl"
  r=$(new "$tU"); rcF="${r%%:*}"; fF="${r#*:}"
  [[ "$rcF" == 4 && "$fF" == "NOT-REACHED" ]] \
    && ok_t "a LOCATED sidechain file that cannot be opened is NOT-REACHED, not a short total" \
    || bad_t "unopenable sidechain file dropped silently" \
             "rc=$rcF out=$fF (1000 = the parent read fine and the sidechain vanished) $(cat "$TMP/new.err")"
  chmod 644 "$dirU/$SIDU/subagents/agent-deadbeef.jsonl"
else
  printf 'SKIP - unopenable-sidechain-file arm (running as root)\n'
fi

# TWO SURVIVING MUTANTS, both of them the same shape as the defect and neither
# reachable by the arms above, so they are arms rather than a note.
#
# (a) A session dir that EXISTS and holds no `subagents/`. The `if sid in names`
# gate means the ENOENT branch is unreachable for a session with no dir at all —
# so dropping that branch survived the whole harness while turning EVERY session
# that has a `tool-results/` and no fan-out into NOT-REACHED. That is not a
# corner: `tool-results/` is present on every readable seat and most sessions
# never fan out, so the mutant reads unmeasurable for the common case while the
# fan-out arms above stay green.
mkhome segT; dirT="$HDIR"
SIDT="cccccccc-aaaa-4bbb-8ccc-cccccccccccc"
tb=$((now-43000))
mkdir -p "$dirT/$SIDT/tool-results"
turn "$dirT/$SIDT.jsonl" $((tb+100)) 640
turn "$dirT/$SIDT/tool-results/leak.jsonl" $((tb+150)) 555000
tT=$(mkrow segT "session dir present, tool-results only, no fan-out")
setwin "$tT" "$SIDT" segT "$tb" $((tb+1000))
r=$(new "$tT"); rcT="${r%%:*}"; fT="${r#*:}"
[[ "$rcT" == 0 && "$fT" == "640" ]] \
  && ok_t "a session dir holding ONLY tool-results/ measures (640) — absent subagents/ is not blindness" \
  || bad_t "a session with no fan-out reads unmeasurable" \
           "rc=$rcT out=$fT (NOT-REACHED = the ENOENT tolerance is gone; 555640 = tool-results counted) $(cat "$TMP/new.err")"
# ...and a session id that is a regular FILE where the dir would be (ENOTDIR).
mkhome segD; dirD="$HDIR"
SIDD="dddddddd-aaaa-4bbb-8ccc-dddddddddddd"
db_=$((now-43500))
turn "$dirD/$SIDD.jsonl" $((db_+100)) 320
: > "$dirD/$SIDD"                               # ENOTDIR when probed for a subagents/ child
tD=$(mkrow segD "session id also present as a stray file")
setwin "$tD" "$SIDD" segD "$db_" $((db_+1000))
r=$(new "$tD"); rcD="${r%%:*}"; fD="${r#*:}"
[[ "$rcD" == 0 && "$fD" == "320" ]] \
  && ok_t "ENOTDIR (a FILE where the session dir would be) is skipped, not NOT-REACHED (320)" \
  || bad_t "ENOTDIR over-fired" "rc=$rcD out=$fD $(cat "$TMP/new.err")"
#
# (b) The MIDDLE level. `glob.glob(projects/*/<sid>.jsonl)`'s own `*` was
# glob-swallowed too, so an unreadable PROJECT dir was ALREADY dropping out of
# this reader's total silently — a pre-existing hole one level above the filed
# defect, and dropping the reason for it survived the harness. The sibling reader
# has this arm (spend_scan_not_reached_unit.sh); this one did not.
if [[ $EUID -ne 0 ]]; then
  mkhome segP; dirP="$HDIR"
  SIDP="eeeeeeee-aaaa-4bbb-8ccc-eeeeeeeeeeee"
  pb=$((now-44000))
  mkdir -p "$dirP/../locked"
  # THE READABLE HALF is what makes this arm discriminating. With the transcript
  # ONLY in the locked dir, a reader that swallows the EACCES falls through to
  # "no transcript named <sid>.jsonl" and returns NOT-REACHED anyway — so the arm
  # would pass on the swallowing code, for the wrong reason. Splitting the corpus
  # across a readable and an unreadable project dir is what turns the swallow
  # into a PARTIAL reported as a total, which is the shape of the defect.
  turn "$dirP/$SIDP.jsonl"           $((pb+100)) 1000
  turn "$dirP/../locked/$SIDP.jsonl" $((pb+200)) 4242
  tP=$(mkrow segP "transcript inside a project dir that goes unreadable")
  setwin "$tP" "$SIDP" segP "$pb" $((pb+1000))
  r=$(new "$tP"); rcP0="${r%%:*}"; fP0="${r#*:}"
  chmod 000 "$dirP/../locked"
  r=$(new "$tP"); rcP="${r%%:*}"; fP="${r#*:}"
  chmod 755 "$dirP/../locked"
  [[ "$rcP0" == 0 && "$fP0" == "5242" ]] \
    && ok_t "one session spanning TWO project dirs sums both (1000+4242=5242)" \
    || bad_t "second project dir not enumerated" "rc=$rcP0 out=$fP0 $(cat "$TMP/new.err")"
  [[ "$rcP" == 4 && "$fP" == "NOT-REACHED" ]] \
    && ok_t "an unreadable PROJECT dir is NOT-REACHED — the middle wildcard no longer swallows" \
    || bad_t "middle level still silent" \
             "rc=$rcP out=$fP $(cat "$TMP/new.err")"
  [[ "$fP" != "1000" ]] \
    && ok_t "…and never the readable HALF (1000): a partial reported as a total is the same fail-open" \
    || bad_t "PARTIAL reported as a total" "rc=$rcP out=$fP — 4242 of the corpus went missing silently"
else
  printf 'SKIP - unreadable-project-dir arm (running as root)\n'
fi

mkhome segE; dirE="$HDIR"
SIDE="bbbbbbbb-aaaa-4bbb-8ccc-bbbbbbbbbbbb"
eb=$((now-42000))
turn "$dirE/$SIDE.jsonl" $((eb+100)) 250
: > "$dirE/$SIDE"'-stray'                      # a stray FILE in the project dir
tE=$(mkrow segE "row with no fan-out at all")
setwin "$tE" "$SIDE" segE "$eb" $((eb+1000))
r=$(new "$tE"); rcE="${r%%:*}"; fE="${r#*:}"
[[ "$rcE" == 0 && "$fE" == "250" ]] \
  && ok_t "a session with NO subagents/ dir still measures (250), it does not NOT-REACH" \
  || bad_t "absent sidechain over-fired" "rc=$rcE out=$fE $(cat "$TMP/new.err")"

# ============================================================================
# ARM 6 — the queue is untouched. The table is additive and nothing in the task
# path may have started depending on it.
# ============================================================================
cols=$(db "SELECT COUNT(*) FROM pragma_table_info('task_sessions');")
fk=$(db "PRAGMA foreign_key_list(task_sessions);" 2>/dev/null | wc -l)
lsq=$(as_agent segA cmd_task_ls --assignee=segA 2>"$TMP/err" | jf '.data | length')
[[ "$cols" == "6" && "$fk" == "0" && "$lsq" -ge 1 ]] \
  && ok_t "task_sessions is additive (6 cols, no FK) and the queue still lists ($lsq rows)" \
  || bad_t "additive check failed" "cols=$cols fk_rows=$fk ls=$lsq $(cat "$TMP/err")"

printf -- '-----\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
