#!/usr/bin/env bash
# DIVE-4417 isolated unit harness — the grader lane's PROCESS mode.
#
# DIVE-4410 made the lane pick the least-loaded pool seat; it did not make the
# lane parallel, because a spawn there is assign+wake on a seat and a seat runs
# one session at a time. This file grades the mode that launches one HEADLESS
# ONE-SHOT PROCESS per delivery instead, and it grades it as three properties
# that the session-mode harness (tests/grader_tick_unit.sh) structurally cannot:
#
#   A. THE MODE IS DARK BY DEFAULT — a third lock on top of dry-run and the
#      empty pool, and like those it is graded on the SHIPPED default, by an arm
#      that assigns nothing (see the wiki: an-arm-that-assigns-the-flag-cannot-
#      grade-the-default-it-ships-with).
#   B. THE CAP IS READ FROM LIVE PROCESSES, NOT FROM THE LEDGER — DO (2). Graded
#      by making the two DISAGREE in both directions, since an arm where they
#      agree passes against a lane that still reads the ledger.
#   C. THE HARNESS DO (5) NAMES — 3 deliveries + cap 4 => 3 concurrent, no queue
#      line; cap 2 => 2 + 1 queued.
#
# No DB, no fleet, no processes: db, the ledger, the process table and both
# spawn primitives are stubs.
# Run: bash tests/grader_process_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }

E_USAGE=64; E_VALIDATION=65; JSON_MODE=0
PENDING="DIVE-1
DIVE-2
DIVE-3"
INFLIGHT=0        # what the LEDGER says is in flight
SEATLOADS=""      # what the LEDGER says each seat holds
LASTPICK=""
NEXTRUNN=1        # the runs table's high-water mark for the seat
US=$'\x1f'

# `runs` is matched BEFORE the generic *COUNT* arm for the same reason the
# seat-load query is in the session harness: the session-id query is itself a
# MAX(...) over a COUNT-shaped string, and matched after it would be served the
# account-wide in-flight number as a session ordinal.
db(){ case "$*" in
        *"FROM runs"*)                  printf '%s\n' "$NEXTRUNN" ;;
        *"INSERT INTO runs"*)           printf '' ;;
        *"UPDATE runs SET status"*)     printf '%s\n' "$*" >> "$DBWF" ;;
        *"UPDATE tasks SET assignee"*)  printf '%s\n' "$*" >> "$DBWF" ;;
        # THE PENDING SET IS MODELLED, NOT CONSTANT, and that is what makes the
        # F arms below able to regress-catch. The shipped query excludes any
        # ident carrying a later `task.grade.spawned` (grader_pool.sh, the
        # NOT EXISTS clause), so a fixture that returns the same three rows
        # forever cannot tell "the row is still pending" from "the row left
        # pending permanently" — which is exactly the defect quinn found.
        *grade.requested*)              pending_now_ ;;
        *"GROUP BY seat"*)              printf '%s\n' "$SEATLOADS" ;;
        *"ORDER BY s.id DESC LIMIT 1"*) printf '%s\n' "$LASTPICK" ;;
        *COUNT*)                        printf '%s\n' "$INFLIGHT" ;;
        *)                              printf '' ;;
      esac; }
sqlq(){ printf "'%s'" "${1//\'/\'\'}"; }
fail(){ shift; printf 'FAILCALL %s\n' "$*" >&2; return 1; }
# warn is a RECORDER now, not a sink: "the caller warns" is half of the contract
# the failed-launch arms grade, and a sink cannot be asserted against.
warn(){ printf '%s\n' "$*" >> "$WARNF"; }
task_actor(){ printf 'sys'; }

USAGE='{"agents":[{"account":"mark","name":"g1","fiveHourPct":10,"sevenDayPct":20},
                  {"account":"mark","name":"g2","fiveHourPct":10,"sevenDayPct":20}]}'
usage_cmd(){ printf '%s' "$USAGE"; }

# Files, not variables: the lane runs inside `out=$(...)`, a subshell, and a
# variable appended to there is gone when it exits — the trap that made the
# session harness's two safety arms pass vacuously.
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/grader-process.XXXXXX")"
trap 'rc=$?; rm -rf "$TMPD"; echo "HARNESS-RC=$rc"' EXIT
PROCF="$TMPD/procs"; SESSF="$TMPD/sessions"; EMITF="$TMPD/emits"; PSF="$TMPD/ps"
WARNF="$TMPD/warns"; SPAWNF="$TMPD/spawned"; DBWF="$TMPD/dbwrites"
export ASSIGNF="$TMPD/assigns"
: > "$PSF"; : > "$WARNF"; : > "$SPAWNF"; : > "$DBWF"; : > "$ASSIGNF"
# EMITF is this tick's emits; SPAWNF outlives the tick, because the property the
# F arms grade is what the NEXT tick sees.
ledger_emit(){
  printf '%s\n' "$*" >> "$EMITF"
  [[ "${1:-}" == task.grade.spawned ]] && printf '%s\n' "${2#ident=}" >> "$SPAWNF"
  return 0
}
pending_now_(){
  local i
  for i in $PENDING; do
    grep -qxF "$i" "$SPAWNF" 2>/dev/null && continue
    printf '%s\n' "$i"
  done
}
# The assign seam. `_grader_process_spawn` shells out to the CLI, so the arms
# that run the REAL function need somewhere for that call to land that is not
# the live board.
FAKECLI="$TMPD/fake5dive"
cat > "$FAKECLI" <<'CLI'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ASSIGNF"
CLI
chmod +x "$FAKECLI"
launch_fail(){ return 7; }
launch_ok(){   return 0; }

# shellcheck source=/dev/null
source src/task/grader_pool.sh
# shellcheck source=/dev/null
source src/task/grader_process.sh
_GRADER_USAGE_CMD=usage_cmd
probe_ok(){ return 0; }
_GRADER_READ_PROBE=probe_ok
_GRADER_PROCESS_PS_CMD='cat "$PSF"'

# BOTH fleet primitives are recorders, and both are needed in every arm: the
# properties below are about WHICH ONE the lane reaches, so an arm that stubbed
# only one would report "process mode works" for a lane that woke a session.
_grader_spawn_session(){ printf '%s\n' "$1:$2" >> "$SESSF"; return 0; }
_grader_process_spawn(){ printf '%s\n' "$1:$2:$3" >> "$PROCF"; return 0; }

run_keep(){ : > "$PROCF"; : > "$SESSF"; : > "$EMITF"; : > "$WARNF"; : > "$ASSIGNF"; : > "$DBWF"
             cmd_task_grader_tick "$@" 2>/dev/null; }
# `run` forgets what the previous tick spawned; `run_keep` does not. Every arm
# above wants a clean slate per tick; the F arms want two consecutive ticks.
run(){ : > "$SPAWNF"; run_keep "$@"; }
procs_(){ cat "$PROCF" 2>/dev/null; }
warns_(){ cat "$WARNF" 2>/dev/null; }
dbw_(){ cat "$DBWF" 2>/dev/null; }
assigns_(){ cat "$ASSIGNF" 2>/dev/null; }
sess_(){ cat "$SESSF" 2>/dev/null; }
emits_(){ cat "$EMITF" 2>/dev/null; }
jget(){ printf '%s' "$1" | python3 -c "import json,sys;print(json.load(sys.stdin)[sys.argv[1]])" "$2"; }

_GRADER_POOL="g1 g2"

# ── A. THE MODE IS DARK BY DEFAULT, graded on the SHIPPED default ────────────
#
# Assigns NOTHING. It unsets the variable, re-sources the file so the default
# expansion actually runs, re-applies every stub in the same order the header
# does (a mutant that ships `process` must not be able to reach the real
# launcher from inside this subshell), and reads back what the lane says.
#
# IT ASSERTS THE MODE FIELD AND THE SESSION RECORDER TOGETHER. A mutant that
# ships `process` but whose dispatch still calls the session primitive would
# pass a mode-only assertion; one that ships `session` but always dispatches to
# processes would pass a recorder-only assertion in an arm that never set the
# mode. Neither survives both.
defout=$(
  unset _GRADER_SPAWN_MODE
  # BOTH files, in bundle order: the mode's default expansion lives in
  # grader_pool.sh (with the tick that reads it), the machinery in
  # grader_process.sh, and re-sourcing only one would grade a half-built lane.
  # shellcheck source=/dev/null
  source src/task/grader_pool.sh
  # shellcheck source=/dev/null
  source src/task/grader_process.sh
  _GRADER_POOL="g1 g2"
  _GRADER_USAGE_CMD=usage_cmd
  _GRADER_READ_PROBE=probe_ok
  _GRADER_PROCESS_PS_CMD='cat "$PSF"'
  _grader_spawn_session(){ printf '%s\n' "$1:$2" >> "$SESSF"; return 0; }
  _grader_process_spawn(){ printf '%s\n' "$1:$2:$3" >> "$PROCF"; return 0; }
  : > "$PROCF"; : > "$SESSF"
  cmd_task_grader_tick --cap=5 --commit --json 2>/dev/null
)
[[ "$(jget "$defout" mode)" == session ]] \
  && ok_ 'A: the shipped _GRADER_SPAWN_MODE is session (nothing assigned it)' \
  || bad_ 'shipped mode is session' "$defout"
[[ ! -s "$PROCF" ]] \
  && ok_ 'A: --commit on the shipped default launches no grader PROCESS' \
  || bad_ 'shipped default launches no process' "$(procs_)"
[[ -s "$SESSF" ]] \
  && ok_ 'A: --commit on the shipped default still wakes a SESSION (unchanged)' \
  || bad_ 'shipped default still wakes a session' "$(sess_)"
# The per-seat bound must not move with the mode flag alone: 1 is correct for a
# serial seat and a lane that raised it in session mode would be stacking wakes,
# which is precisely the DIVE-4410 defect wearing this row's name.
[[ "$(jget "$defout" seatCap)" == 1 ]] \
  && ok_ 'A: session mode keeps the per-seat cap at 1' || bad_ 'session seatcap 1' "$defout"

_GRADER_SPAWN_MODE=process

# ── C. DO (5): 3 deliveries, cap 4 => 3 concurrent processes, no queue line ───
INFLIGHT=0; SEATLOADS=""; : > "$PSF"
out=$(run --cap=4 --commit)
outj=$(run --cap=4 --commit --json)
[[ "$(jget "$outj" spawned)" == 3 && "$(jget "$outj" queued)" == 0 ]] \
  && ok_ 'C: 3 deliveries + cap 4 => spawn=3 queue=0' || bad_ 'cap4 spawns 3' "$outj"
[[ "$(procs_ | wc -l)" == 3 ]] \
  && ok_ 'C: three grader PROCESSES were launched' || bad_ 'three processes' "$(procs_)"
# ANCHORED, not a bare grep for "queue": the summary line always prints
# "queue=0", so an unanchored match reports a queue on the very tick DO (5) says
# must not have one — the same trap the session harness hit on "dark".
grep -qE '^queue ' <<<"$out" && bad_ 'no queue line at cap 4' "$out" \
  || ok_ 'C: no queue line at cap 4'
# DO (4): the seat's main session is never handed a grading turn, so its
# Telegram and a2a traffic is not blocked behind a grade. This is the whole of
# (4) and it is a NEGATIVE — the only way to grade it is to assert the session
# primitive was never reached.
[[ ! -s "$SESSF" ]] \
  && ok_ 'C/DO4: process mode wakes NO seat session (a2a on the seat stays free)' \
  || bad_ 'process mode wakes no session' "$(sess_)"

# ── C. DO (5): cap 2 => 2 concurrent + 1 queued ──────────────────────────────
outj=$(run --cap=2 --commit --json)
out=$(run --cap=2 --commit)
[[ "$(jget "$outj" spawned)" == 2 && "$(jget "$outj" queued)" == 1 ]] \
  && ok_ 'C: cap 2 => spawn=2 queue=1' || bad_ 'cap2 spawns 2 queues 1' "$outj"
[[ "$(procs_ | wc -l)" == 2 ]] \
  && ok_ 'C: exactly two processes launched under cap 2' || bad_ 'two processes' "$(procs_)"
grep -q 'queue   DIVE-3' <<<"$out" \
  && ok_ 'C: the third delivery is QUEUED, named, not silently dropped' || bad_ 'DIVE-3 queued' "$out"

# ── B. THE CAP IS THE LIVE PROCESS TABLE, NOT THE LEDGER ─────────────────────
#
# BOTH DIRECTIONS, because either alone is passed by a lane that still reads the
# ledger. Direction 1: the ledger claims the lane is full and the process table
# is empty — a ledger-reading lane queues everything, a process-reading lane
# spawns. This is the DIVE-4322/4418 leak class (a PASS parked on an unmergeable
# PR held its slot for three hours) and in process mode it cannot occur at all,
# because the exit condition is the process exiting.
INFLIGHT=99; SEATLOADS=""; : > "$PSF"
outj=$(run --cap=4 --commit --json)
[[ "$(jget "$outj" spawned)" == 3 ]] \
  && ok_ 'B1: a ledger claiming 99 in flight does not block a lane with no live processes' \
  || bad_ 'B1 ledger does not bind' "$outj"
[[ "$(jget "$outj" procs)" == 3 ]] \
  && ok_ 'B1: the tick reports the live process count it acted on' || bad_ 'B1 procs reported' "$outj"

# Direction 2: the ledger is empty and FOUR graders are genuinely running. A
# ledger-reading lane spawns three more onto an account already at its cap.
INFLIGHT=0
cat > "$PSF" <<PS
4001 sudo -n -u agent-g1 bash -lc : 5dive-grader-oneshot seat=g1 ident=DIVE-90 session=g1#1
4002 sudo -n -u agent-g1 bash -lc : 5dive-grader-oneshot seat=g1 ident=DIVE-91 session=g1#2
4003 sudo -n -u agent-g2 bash -lc : 5dive-grader-oneshot seat=g2 ident=DIVE-92 session=g2#1
4004 sudo -n -u agent-g2 bash -lc : 5dive-grader-oneshot seat=g2 ident=DIVE-93 session=g2#2
PS
outj=$(run --cap=4 --commit --json)
[[ "$(jget "$outj" spawned)" == 0 && "$(jget "$outj" queued)" == 3 ]] \
  && ok_ 'B2: four LIVE graders fill a cap of 4 even with an empty ledger' || bad_ 'B2 live binds' "$outj"
[[ ! -s "$PROCF" ]] && ok_ 'B2: nothing was launched over the live cap' || bad_ 'B2 nothing launched' "$(procs_)"

# THE DE-DUPLICATION, and it is not cosmetic: one launch is three or four
# processes that ALL carry the marker in argv (setsid, sudo, bash, then the CLI
# after exec). A line-counting cap binds at a quarter of its number — cap 4
# would admit one grade. Here ONE grade is present as four argv layers and the
# count must read 1.
cat > "$PSF" <<PS
5001 setsid sudo -n -u agent-g1 bash -lc : 5dive-grader-oneshot seat=g1 ident=DIVE-90 session=g1#1
5002 sudo -n -u agent-g1 bash -lc : 5dive-grader-oneshot seat=g1 ident=DIVE-90 session=g1#1
5003 bash -lc : 5dive-grader-oneshot seat=g1 ident=DIVE-90 session=g1#1
5004 claude --print You are a one-shot grader : 5dive-grader-oneshot seat=g1 ident=DIVE-90 session=g1#1
PS
[[ "$(_grader_process_count)" == 1 ]] \
  && ok_ 'B3: four argv layers of ONE grade count as one process, not four' \
  || bad_ 'B3 de-dupes by ident' "$(_grader_process_count)"
[[ "$(_grader_process_count g1)" == 1 && "$(_grader_process_count g2)" == 0 ]] \
  && ok_ 'B3: the per-seat reading de-dupes the same way' \
  || bad_ 'B3 per-seat de-dupe' "g1=$(_grader_process_count g1) g2=$(_grader_process_count g2)"
# THE SPREAD READS A DIFFERENT FUNCTION FROM THE CAP, and it needs its own arm:
# `_grader_process_count` de-duplicates by ident, `_grader_process_seat_loads`
# de-duplicates by seat+ident, and an arm on the first is no evidence about the
# second. Against a mutant that dropped the seat-side de-dup this fixture reads
# g1 at FOUR — four argv layers of one grade — which under a per-seat bound of 4
# takes the busiest seat in the pool out of service on its first grade.
[[ "$(_grader_process_seat_loads)" == "g1${US}1" ]] \
  && ok_ 'B3: the per-SEAT load de-dupes the argv layers too (its own function)' \
  || bad_ 'B3 seat-load de-dupe' "$(_grader_process_seat_loads | tr -d '\037')"

# ── The spread in process mode is read off live processes, per seat ──────────
# g1 is at the per-seat bound and g2 is free: every delivery must land on g2.
_GRADER_MAX_PER_SEAT_PROCESS=1
cat > "$PSF" <<PS
6001 sudo -n -u agent-g1 bash -lc : 5dive-grader-oneshot seat=g1 ident=DIVE-90 session=g1#1
PS
outj=$(run --cap=9 --commit --json)
[[ "$(procs_ | cut -d: -f1 | sort -u)" == g2 ]] \
  && ok_ 'SPREAD: a seat at its process bound is passed over for the free one' \
  || bad_ 'spread skips the busy seat' "$(procs_)"
_GRADER_MAX_PER_SEAT_PROCESS=4

# ── DO (3): attribution — the ledger names the seat AND the session ──────────
: > "$PSF"; INFLIGHT=0; NEXTRUNN=7
out=$(run --cap=4 --commit)
grep -q 'grader session on g[12] (process g[12]#7)' <<<"$(emits_)" \
  && ok_ 'DO3: the spawn row names seat + session id (quinn#N shape)' || bad_ 'DO3 attribution' "$(emits_)"
# THE PREFIX IS LOAD-BEARING. `_GRADER_SEAT_EXPR` reads the seat out of this
# string at a fixed 18-character offset up to the next space, so the suffix may
# grow and the prefix may not. Graded by running the shipped expression's own
# parse over the detail this mode writes — not by eyeballing the string.
det=$(emits_ | sed -n 's/.*detail=//p' | head -1)
seat_parsed="${det#grader session on }"; seat_parsed="${seat_parsed%% *}"
[[ "$seat_parsed" == g1 || "$seat_parsed" == g2 ]] \
  && ok_ 'DO3: the session suffix does not break the seat parse the load query uses' \
  || bad_ 'DO3 seat still parses' "$det"

# ── DO (6): the process count is on the spawn line, with the mode ────────────
grep -qE 'spawn   DIVE-1.*mode=process procs=[0-9]+' <<<"$out" \
  && ok_ 'DO6: the spawn line logs the mode and the live process count' || bad_ 'DO6 spawn line' "$out"
grep -qE 'mode=process procs=[0-9]+ seatcap=[0-9]+' <<<"$out" \
  && ok_ 'DO6: the tick summary carries mode, process count and the seat bound' || bad_ 'DO6 summary' "$out"
# The count must ADVANCE across a tick — a lane that printed the same number on
# every line would be reporting the reading it started with, not what it spent.
n1=$(grep -o 'procs=[0-9]*' <<<"$out" | head -1 | cut -d= -f2)
n3=$(grep -o 'procs=[0-9]*' <<<"$out" | sed -n '3p' | cut -d= -f2)
[[ -n "$n1" && -n "$n3" && "$n3" -gt "$n1" ]] \
  && ok_ 'DO6: the count advances as the tick spends slots' || bad_ 'DO6 count advances' "$out"

# ── The two locks the lane already had still hold in process mode ────────────
: > "$PSF"
out=$(run --cap=4)                       # no --commit
[[ ! -s "$PROCF" && ! -s "$EMITF" ]] \
  && ok_ 'LOCK1 holds in process mode: dry-run launches nothing, writes nothing' \
  || bad_ 'LOCK1 in process mode' "$(procs_) / $(emits_)"
_GRADER_POOL=""
outj=$(run --cap=4 --commit --json)
[[ ! -s "$PROCF" && "$(jget "$outj" dark)" == 3 ]] \
  && ok_ 'LOCK2 holds in process mode: an empty pool launches nothing and reads dark' \
  || bad_ 'LOCK2 in process mode' "$outj"
_GRADER_POOL="g1 g2"

# ── F. A LAUNCH THAT CANNOT START (DIVE-4417 iteration 2, quinn's finding) ───
#
# Iteration 1's 26 arms all stubbed `_grader_process_spawn`, so every one of them
# graded the tick's DECISIONS and none could reach the launch. quinn ran the real
# function against a seat whose unix account does not exist: sudo refused, the
# function returned 0, the caller's warn never fired, and because the ledger row
# was already written the delivery left `pending` forever.
#
# These arms run the REAL `_grader_process_spawn` — re-sourced over the recorder
# stub inside a subshell, with the CLI, the runas probe and the launcher on their
# seams — and grade the three halves of the fix together: the launch reports
# failure, the tick warns and does not claim a spawn, and the NEXT tick still
# sees the row. Asserting them separately would let a lane that warns and still
# strands the row pass.
: > "$PSF"; INFLIGHT=0; SEATLOADS=""; NEXTRUNN=1
real_spawn_env_() {           # the seams, applied in one place for all F arms
  # shellcheck source=/dev/null
  source src/task/grader_process.sh          # the REAL spawn, over the stub
  _GRADER_PROCESS_PS_CMD='cat "$PSF"'
  _GRADER_TASK_CLI="$FAKECLI"
  _GRADER_PROCESS_START_GRACE=0
}

# F1: the runas refusal — quinn's exact measurement, at function level.
f1rc=0
( real_spawn_env_
  _GRADER_PROCESS_RUNAS_CMD='return 1'
  _grader_process_spawn g1 DIVE-1 'g1#1' ) || f1rc=$?
(( f1rc != 0 )) \
  && ok_ 'F1: a seat this caller cannot become => _grader_process_spawn returns non-zero' \
  || bad_ 'F1 runas refusal returns non-zero' "rc=$f1rc"
[[ ! -s "$ASSIGNF" ]] \
  && ok_ 'F1: the runas probe runs BEFORE the assign, so there is nothing to unwind' \
  || bad_ 'F1 probe precedes assign' "$(assigns_)"

# F2: the launch itself fails after the assign — the compensation path.
f2rc=0
( real_spawn_env_
  _GRADER_PROCESS_RUNAS_CMD='return 0'
  _GRADER_PROCESS_LAUNCH=launch_fail
  _grader_process_spawn g1 DIVE-1 'g1#1' ) || f2rc=$?
(( f2rc != 0 )) \
  && ok_ 'F2: a launch that cannot start => _grader_process_spawn returns non-zero' \
  || bad_ 'F2 failed launch returns non-zero' "rc=$f2rc"
grep -q 'did not start' <<<"$(warns_)" \
  && ok_ 'F2: the failure is warned, not swallowed' || bad_ 'F2 warns' "$(warns_)"
grep -q 'UPDATE tasks SET assignee' <<<"$(dbw_)" \
  && ok_ 'F2: the assign is unwound, so the row is not left on a seat that is not grading it' \
  || bad_ 'F2 unwinds the assign' "$(dbw_)"
grep -q 'UPDATE runs SET status' <<<"$(dbw_)" \
  && ok_ 'F2: the run row is closed failed rather than left reading running' \
  || bad_ 'F2 closes the run row' "$(dbw_)"
grep -q 'task.grade.spawn.failed' <<<"$(cat "$EMITF")" \
  && ok_ 'F2: a compensating ledger row records the attempt that did not start' \
  || bad_ 'F2 compensating event' "$(cat "$EMITF")"

# F3: THE PROPERTY THAT WAS BROKEN — two consecutive ticks, failing launch.
PENDING="DIVE-1"; : > "$SPAWNF"
f3a=$( real_spawn_env_
       _GRADER_PROCESS_RUNAS_CMD='return 0'; _GRADER_PROCESS_LAUNCH=launch_fail
       run_keep --cap=4 --commit )
grep -q 'DIVE-1' <<<"$(warns_)" \
  && ok_ 'F3: the tick warns on a launch that never started' || bad_ 'F3 tick warns' "$(warns_)"
grep -qE '^failed  DIVE-1' <<<"$f3a" \
  && ok_ 'F3: the plan names the failed launch instead of printing spawn and moving on' \
  || bad_ 'F3 plan line' "$f3a"
grep -q 'spawn=0 ' <<<"$f3a" \
  && ok_ 'F3: the summary does not count a spawn that did not happen' || bad_ 'F3 spawn=0' "$f3a"
grep -q 'failed=1' <<<"$f3a" \
  && ok_ 'F3: the summary reports the failure as its own number' || bad_ 'F3 failed=1' "$f3a"
grep -q 'task.grade.spawned' <<<"$(cat "$EMITF")" \
  && bad_ 'F3 no spawned row on a failed launch' "$(cat "$EMITF")" \
  || ok_ 'F3: NO task.grade.spawned row is written for a launch that did not start'
f3b=$( real_spawn_env_
       _GRADER_PROCESS_RUNAS_CMD='return 0'; _GRADER_PROCESS_LAUNCH=launch_fail
       run_keep --cap=4 --commit --json )
[[ "$(jget "$f3b" pending)" == 1 ]] \
  && ok_ 'F3: the delivery is STILL PENDING on the next tick (it is re-picked, not stranded)' \
  || bad_ 'F3 row survives to the next tick' "$f3b"

# F4: the positive control. Without it, a lane that returned non-zero from every
# launch — or never emitted the ledger row at all — would pass every arm above,
# and the row would be re-graded on every tick forever.
: > "$SPAWNF"
f4a=$( real_spawn_env_
       _GRADER_PROCESS_RUNAS_CMD='return 0'; _GRADER_PROCESS_LAUNCH=launch_ok
       run_keep --cap=4 --commit --json )
[[ "$(jget "$f4a" spawned)" == 1 && "$(jget "$f4a" failed)" == 0 ]] \
  && ok_ 'F4: a launch that DOES start is still counted as a spawn' || bad_ 'F4 spawn counted' "$f4a"
grep -q 'task.grade.spawned' <<<"$(cat "$EMITF")" \
  && ok_ 'F4: the ledger row is written once the launch is known started' \
  || bad_ 'F4 spawned row written' "$(cat "$EMITF")"
f4b=$( real_spawn_env_
       _GRADER_PROCESS_RUNAS_CMD='return 0'; _GRADER_PROCESS_LAUNCH=launch_ok
       run_keep --cap=4 --commit --json )
[[ "$(jget "$f4b" pending)" == 0 ]] \
  && ok_ 'F4: a started grade LEAVES pending, so the receipt still de-duplicates' \
  || bad_ 'F4 started grade leaves pending' "$f4b"

# F5: the liveness check the DEFAULT launch path depends on, graded directly.
# The F1-F4 arms reach the launcher through the `_GRADER_PROCESS_LAUNCH` seam, so
# `_grader_process_started` — the half that catches a launch which starts and
# then dies — would otherwise ship ungraded, which is the shape of the original
# defect all over again.
( real_spawn_env_; : > "$PSF"
  false & fp=$!
  _grader_process_started "$fp" DIVE-1 ) \
  && bad_ 'F5 a wrapper that exited non-zero is not started' '' \
  || ok_ 'F5: a launch whose wrapper exited non-zero reads as NOT started'
( real_spawn_env_; : > "$PSF"
  true & tp=$!
  _grader_process_started "$tp" DIVE-1 ) \
  && bad_ 'F5 exit 0 with no marker in argv is not proof of life' '' \
  || ok_ 'F5: wrapper gone with status 0 and NO marker in argv reads as NOT started'
( real_spawn_env_
  printf '4242 sudo -n -u agent-g1 bash -lc : 5dive-grader-oneshot seat=g1 ident=DIVE-1 session=g1#1\n' > "$PSF"
  true & tp=$!
  _grader_process_started "$tp" DIVE-1 ) \
  && ok_ 'F5: wrapper gone with status 0 but the one-shot IS in argv reads as started (setsid forked)' \
  || bad_ 'F5 marker resolves the setsid fork' "$(cat "$PSF")"
# THE ZOMBIE BRANCH, graded through the state seam and not through a real
# zombie: bash reaps its own background children from its SIGCHLD handler, so an
# arm that backgrounds `false` and looks for a zombie grades the scheduler. The
# mutant that removes the check survived exactly that arm.
( real_spawn_env_; : > "$PSF"
  sleep 5 & zp=$!
  _GRADER_PID_STATE_CMD='printf Z'
  _grader_process_started "$zp" DIVE-1; rc=$?
  kill "$zp" 2>/dev/null; exit $rc ) \
  && bad_ 'F5 an exited-but-unreaped wrapper is not alive' '' \
  || ok_ 'F5: a wrapper in state Z (exited, not yet reaped) reads as NOT started, though kill -0 succeeds'

( real_spawn_env_
  printf '4242 sudo -n -u agent-g1 bash -lc : 5dive-grader-oneshot seat=g1 ident=DIVE-10 session=g1#1\n' > "$PSF"
  _grader_process_live DIVE-1 ) \
  && bad_ 'F5 DIVE-10 is not DIVE-1' "$(cat "$PSF")" \
  || ok_ 'F5: ident=DIVE-10 is not read as proof of life for DIVE-1 (no prefix match)'
: > "$PSF"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
