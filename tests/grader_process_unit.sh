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
        # DIVE-4521: the row's id and its MAKER, both modelled so the lineage
        # gate below can be graded. Empty by default, which is what every arm
        # above was already reading out of the `*)` catch-all — so a default-off
        # fixture keeps those arms byte-identical and the gate cannot silently
        # start refusing seats in tests that never mention lineage.
        *"SELECT id FROM tasks WHERE ident"*) printf '%s\n' "$TASKID" ;;
        *maker_agent*)                  printf '%s\n' "$MAKER" ;;
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

TASKID=""
MAKER=""
USAGE='{"agents":[{"account":"mark","name":"g1","fiveHourPct":10,"sevenDayPct":20},
                  {"account":"mark","name":"g2","fiveHourPct":10,"sevenDayPct":20}]}'
usage_cmd(){ printf '%s' "$USAGE"; }

# Files, not variables: the lane runs inside `out=$(...)`, a subshell, and a
# variable appended to there is gone when it exits — the trap that made the
# session harness's two safety arms pass vacuously.
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/grader-process.XXXXXX")"
trap 'rc=$?; rm -rf "$TMPD"; echo "HARNESS-RC=$rc"' EXIT
PROCF="$TMPD/procs"; SESSF="$TMPD/sessions"; EMITF="$TMPD/emits"; PSF="$TMPD/ps"
RMF="$TMPD/removed"
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
# DIVE-4496: the counting fixture is a list of LIVE CLONE SEATS, not argv lines.
# One line per clone, exactly what `_grader_clone_ls` reads out of the registry.
_GRADER_CLONE_LS_CMD='cat "$PSF"'
_GRADER_CLONE_PRUNE_CMD='return 0'

# BOTH fleet primitives are recorders, and both are needed in every arm: the
# properties below are about WHICH ONE the lane reaches, so an arm that stubbed
# only one would report "process mode works" for a lane that woke a session.
_grader_spawn_session(){ printf '%s\n' "$1:$2" >> "$SESSF"; return 0; }
_grader_process_spawn(){ printf '%s\n' "$1:$2:$3" >> "$PROCF"; return 0; }

run_keep(){ : > "$PROCF"; : > "$SESSF"; : > "$EMITF"; : > "$WARNF"; : > "$ASSIGNF"; : > "$DBWF"; : > "$RMF"
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
# DIVE-4496: the per-tick CREATE budget is 1 in the shipped default and would
# bind every cap arm below at 1 regardless of the cap, hiding whichever bound was
# actually under test. Lifted here and graded on its own, with the SHIPPED value,
# in the BUDGET arms at the end.
_GRADER_CLONE_MAX_CREATES_PER_TICK=99

# ── A. THE MODE IS LIVE BY DEFAULT (DIVE-4521), graded on the SHIPPED default ─
#
# INVERTED, and deliberately in place rather than deleted: this arm was the
# dark-ship lock ("the shipped mode is session, --commit launches no process"),
# and the flip's only real risk is that the default is not what the bundle
# actually ships. So the SAME arm now asserts the opposite three facts, and the
# explicit-session control below keeps the old path covered — a flip that
# deleted its own guard would leave the default graded by nothing.
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
  # DIVE-4496: the counting fixture is a list of LIVE CLONE SEATS, not argv lines.
# One line per clone, exactly what `_grader_clone_ls` reads out of the registry.
_GRADER_CLONE_LS_CMD='cat "$PSF"'
_GRADER_CLONE_PRUNE_CMD='return 0'
  _grader_spawn_session(){ printf '%s\n' "$1:$2" >> "$SESSF"; return 0; }
  _grader_process_spawn(){ printf '%s\n' "$1:$2:$3" >> "$PROCF"; return 0; }
  : > "$PROCF"; : > "$SESSF"
  cmd_task_grader_tick --cap=5 --commit --json 2>/dev/null
)
[[ "$(jget "$defout" mode)" == process ]] \
  && ok_ 'A: the shipped _GRADER_SPAWN_MODE is process (nothing assigned it)' \
  || bad_ 'shipped mode is process' "$defout"
[[ -s "$PROCF" ]] \
  && ok_ 'A: --commit on the shipped default LAUNCHES a grader clone process' \
  || bad_ 'shipped default launches a process' "$(procs_)"
[[ ! -s "$SESSF" ]] \
  && ok_ 'A: --commit on the shipped default wakes NO session (the old path is off)' \
  || bad_ 'shipped default wakes no session' "$(sess_)"
# The per-seat bound moves WITH the mode and only with it: a serial seat must
# stay at 1 (DIVE-4410 — a second wake on a live seat is a queue, not a grader),
# and a lane of separate clone seats is the only thing that may exceed it.
[[ "$(jget "$defout" seatCap)" == 4 ]] \
  && ok_ 'A: the shipped default carries the PROCESS per-seat cap' || bad_ 'shipped seatcap 4' "$defout"

# ── A2. THE EXPLICIT SESSION CONTROL, in its own subshell ────────────────────
#
# The arm the flip would otherwise have deleted. `_GRADER_SPAWN_MODE=session`
# must still reach the session primitive and NOTHING in the clone machinery, and
# it must still report the serial per-seat cap — a flip is only reversible if the
# behaviour it flipped away from is still graded.
sessout=$(
  # shellcheck source=/dev/null
  source src/task/grader_pool.sh
  # shellcheck source=/dev/null
  source src/task/grader_process.sh
  _GRADER_SPAWN_MODE=session
  _GRADER_POOL="g1 g2"
  _GRADER_USAGE_CMD=usage_cmd
  _GRADER_READ_PROBE=probe_ok
  _GRADER_CLONE_LS_CMD='cat "$PSF"'
  _GRADER_CLONE_PRUNE_CMD='return 0'
  _grader_spawn_session(){ printf '%s\n' "$1:$2" >> "$SESSF"; return 0; }
  _grader_process_spawn(){ printf '%s\n' "$1:$2:$3" >> "$PROCF"; return 0; }
  : > "$PROCF"; : > "$SESSF"
  # SPAWNF outlives a tick on purpose (it models the pending query's
  # "excludes any ident with a later task.grade.spawned"), and arm A above just
  # spawned into it — so without this reset the pending set A2 reads is EMPTY and
  # a session lane that woke nothing would pass for the right reason.
  : > "$SPAWNF"
  cmd_task_grader_tick --cap=5 --commit --json 2>/dev/null
)
[[ "$(jget "$sessout" mode)" == session ]] \
  && ok_ 'A2: an explicit session mode still reads as session' || bad_ 'A2 explicit session mode' "$sessout"
[[ -s "$SESSF" && ! -s "$PROCF" ]] \
  && ok_ 'A2: explicit session mode wakes a SESSION and launches no clone' \
  || bad_ 'A2 session path intact' "$(sess_)/$(procs_)"
[[ "$(jget "$sessout" seatCap)" == 1 ]] \
  && ok_ 'A2: explicit session mode keeps the per-seat cap at 1' || bad_ 'A2 session seatcap 1' "$sessout"

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
[[ "$(jget "$outj" clones)" == 3 ]] \
  && ok_ 'B1: the tick reports the live clone count it acted on' || bad_ 'B1 clones reported' "$outj"

# Direction 2: the ledger is empty and FOUR graders are genuinely running. A
# ledger-reading lane spawns three more onto an account already at its cap.
INFLIGHT=0
cat > "$PSF" <<PS
gr-g1-1
gr-g1-2
gr-g2-1
gr-g2-2
PS
outj=$(run --cap=4 --commit --json)
[[ "$(jget "$outj" spawned)" == 0 && "$(jget "$outj" queued)" == 3 ]] \
  && ok_ 'B2: four LIVE clone seats fill a cap of 4 even with an empty ledger' || bad_ 'B2 live binds' "$outj"
[[ ! -s "$PROCF" ]] && ok_ 'B2: nothing was launched over the live cap' || bad_ 'B2 nothing launched' "$(procs_)"

# ══ THE CLONE NAME IS THE OWNERSHIP RECORD, so it is graded in both directions ══
# DIVE-4417's de-duplication arms lived here: one launch was three or four argv
# layers and a line-counting cap bound at a quarter of its number. A clone is ONE
# registry row, so that class is gone by construction — and what replaced it is
# the mapping the whole lane now rests on. `gr-quinn-3` must be derivable from
# session `quinn#3` and `quinn` must be recoverable from `gr-quinn-3`; if either
# direction drifts, the cap counts clones against the wrong pool seat's budget
# and the sweep reads live grades as orphans.
[[ "$(_grader_clone_name 'quinn#3')" == 'gr-quinn-3' ]] \
  && ok_ 'B3: a session id mints its clone seat name' || bad_ 'B3 clone name' "$(_grader_clone_name 'quinn#3')"
[[ "$(_grader_clone_pool_seat 'gr-quinn-3')" == 'quinn' ]] \
  && ok_ 'B3: the clone name yields back the pool seat whose budget it spends' \
  || bad_ 'B3 pool seat' "$(_grader_clone_pool_seat 'gr-quinn-3')"
# THE REFUSAL, and it is the arm that matters: `valid_name` caps a seat at 16
# lowercase chars, so a pool seat with a long name cannot be cloned. A TRUNCATING
# implementation still creates a seat — one whose name maps back to no session, so
# the sweep reads it as an orphan and reaps a live grade on the very next tick.
( _grader_clone_name 'a-very-long-pool-seat#12' ) >/dev/null 2>&1 \
  && bad_ 'B3 an unclonable name is refused, not truncated' "$(_grader_clone_name 'a-very-long-pool-seat#12' 2>/dev/null)" \
  || ok_ 'B3: a pool seat name too long to clone is REFUSED, never truncated'
( _grader_clone_name 'quinn' ) >/dev/null 2>&1 \
  && bad_ 'B3 a session id with no # is refused' '' \
  || ok_ 'B3: a malformed session id mints no clone name'
[[ "$(_grader_process_count)" == 4 ]] \
  && ok_ 'B3: the cap counts one per clone seat' || bad_ 'B3 count' "$(_grader_process_count)"
[[ "$(_grader_process_count g1)" == 2 && "$(_grader_process_count g2)" == 2 ]] \
  && ok_ 'B3: the per-pool-seat reading attributes each clone to its own seat' \
  || bad_ 'B3 per-seat count' "g1=$(_grader_process_count g1) g2=$(_grader_process_count g2)"
# THE SPREAD READS A DIFFERENT FUNCTION FROM THE CAP, and it needs its own arm:
# `_grader_process_count` tallies clones, `_grader_process_seat_loads` buckets
# them by pool seat, and an arm on the first is no evidence about the second.
[[ "$(_grader_process_seat_loads | sort | tr '\n' ' ' | tr -d '\037')" == "g12 g22 " ]] \
  && ok_ 'B3: the per-SEAT load buckets the clones by pool seat (its own function)' \
  || bad_ 'B3 seat-load buckets' "$(_grader_process_seat_loads | sort | tr -d '\037' | tr '\n' ' ')"

# ── The spread in process mode is read off live CLONE SEATS, per pool seat ──
# g1 is at the per-seat bound and g2 is free: every delivery must land on g2.
_GRADER_MAX_PER_SEAT_PROCESS=1
cat > "$PSF" <<PS
gr-g1-1
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
grep -qE 'spawn   DIVE-1.*mode=process clones=[0-9]+' <<<"$out" \
  && ok_ 'DO6: the spawn line logs the mode and the live clone count' || bad_ 'DO6 spawn line' "$out"
grep -qE 'mode=process clones=[0-9]+ swept=[0-9]+ seatcap=[0-9]+' <<<"$out" \
  && ok_ 'DO6: the tick summary carries mode, clone count, sweep count and the seat bound' || bad_ 'DO6 summary' "$out"
# The count must ADVANCE across a tick — a lane that printed the same number on
# every line would be reporting the reading it started with, not what it spent.
n1=$(grep -o 'clones=[0-9]*' <<<"$out" | head -1 | cut -d= -f2)
n3=$(grep -o 'clones=[0-9]*' <<<"$out" | sed -n '3p' | cut -d= -f2)
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
  _GRADER_CLONE_LS_CMD='cat "$PSF"'
  _GRADER_CLONE_PRUNE_CMD='return 0'
  _GRADER_TASK_CLI="$FAKECLI"
  # DIVE-4496: every fleet-touching step of the launch is on its own seam, so an
  # arm can fail exactly ONE of them and watch what the other three do. That is
  # the whole point of there being four seams rather than one: the ordering (row
  # untouched before the clone exists, clone removed if the row cannot be written)
  # is the property, and a single whole-launch seam could not express it.
  _GRADER_CLONE_CREATE_CMD='return 0'
  _GRADER_CLONE_CREDS_CMD='return 0'
  _GRADER_CLONE_REMOVE_CMD='printf "%s\n" "$clone" >> "$RMF"; return 0'
  _GRADER_CLONE_WAKE_CMD='return 0'
}
rms_(){ cat "$RMF" 2>/dev/null; }

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

# F2: the WAKE fails after the assign — the compensation path.
#
# The wake is the step this arm drives because it is the ONLY one that fails after
# the row has been touched. A create or a creds refusal happens before the assign
# by construction (the ORDER arms below grade that), so there is nothing to
# compensate for there — which is the point of the order.
f2rc=0
( real_spawn_env_
  _GRADER_PROCESS_RUNAS_CMD='return 0'
  _GRADER_CLONE_WAKE_CMD='return 1'
  _grader_process_spawn g1 DIVE-1 'g1#1' ) || f2rc=$?
(( f2rc != 0 )) \
  && ok_ 'F2: a clone that cannot be woken => _grader_process_spawn returns non-zero' \
  || bad_ 'F2 failed wake returns non-zero' "rc=$f2rc"
grep -q 'did not start grading' <<<"$(warns_)" \
  && ok_ 'F2: the failure is warned, not swallowed' || bad_ 'F2 warns' "$(warns_)"
grep -q 'UPDATE tasks SET assignee' <<<"$(dbw_)" \
  && ok_ 'F2: the assign is unwound, so the row is not left on a clone that is not grading it' \
  || bad_ 'F2 unwinds the assign' "$(dbw_)"
grep -q 'UPDATE runs SET status' <<<"$(dbw_)" \
  && ok_ 'F2: the run row is closed failed rather than left reading running' \
  || bad_ 'F2 closes the run row' "$(dbw_)"
grep -q 'task.grade.spawn.failed' <<<"$(cat "$EMITF")" \
  && ok_ 'F2: a compensating ledger row records the attempt that did not start' \
  || bad_ 'F2 compensating event' "$(cat "$EMITF")"
# THE SEAT MUST NOT SURVIVE THE FAILURE. Without this arm a lane that unwinds the
# row perfectly and leaves a clone behind passes everything above — and lodar's
# 06:07Z worry ("mid turn death and then we forget to delete clone") is precisely
# a clone nobody removed.
grep -qx 'gr-g1-1' <<<"$(rms_)" \
  && ok_ 'F2: the clone is removed too — a failed launch leaves no seat behind' \
  || bad_ 'F2 removes the clone' "$(rms_)"

# ── ORDER: NOTHING TOUCHES THE ROW UNTIL THE CLONE EXISTS ────────────────────
#
# The two failures that must cost nothing. A create that fails, or a clone that
# cannot be given a read credential, must leave the board byte-identical: no
# assign, no run row, no ledger row, nothing to unwind. If either of these
# touched the row first, its compensation would be a second code path — and the
# one that ran less often would be the one that was wrong.
: > "$ASSIGNF"; : > "$DBWF"; : > "$RMF"
ocrc=0
( real_spawn_env_
  _GRADER_PROCESS_RUNAS_CMD='return 0'
  _GRADER_CLONE_CREATE_CMD='return 1'
  _grader_process_spawn g1 DIVE-1 'g1#1' ) || ocrc=$?
(( ocrc != 0 )) && [[ ! -s "$ASSIGNF" && ! -s "$DBWF" ]] \
  && ok_ 'ORDER: a create that fails assigns nothing and writes nothing — the next tick just retries' \
  || bad_ 'ORDER create failure is free' "rc=$ocrc assigns=$(assigns_) dbw=$(dbw_)"
[[ ! -s "$RMF" ]] \
  && ok_ 'ORDER: a create that failed has no clone to remove' || bad_ 'ORDER no phantom remove' "$(rms_)"

: > "$ASSIGNF"; : > "$DBWF"; : > "$RMF"
odrc=0
( real_spawn_env_
  _GRADER_PROCESS_RUNAS_CMD='return 0'
  _GRADER_CLONE_CREDS_CMD='return 4'
  _grader_process_spawn g1 DIVE-1 'g1#1' ) || odrc=$?
(( odrc != 0 )) && [[ ! -s "$ASSIGNF" && ! -s "$DBWF" ]] \
  && ok_ 'ORDER: a clone with no read credential never reaches the row' \
  || bad_ 'ORDER creds failure is free' "rc=$odrc assigns=$(assigns_) dbw=$(dbw_)"
grep -qx 'gr-g1-1' <<<"$(rms_)" \
  && ok_ 'ORDER: a clone that cannot read its delivery is UNWOUND ON THE SPOT, not left to grade blind' \
  || bad_ 'ORDER creds failure removes the clone' "$(rms_)"

# ── THE CLONE'S OWN READ IS PROBED, NOT INFERRED FROM THE POOL SEAT'S ───────
#
# The tick already ran `_grader_can_read` — against the POOL SEAT, which is the
# name it was choosing between. Whether the COPIED credential works is a property
# of the CLONE, and the two come apart on an expired token (they live ~1 hour), a
# copy that landed empty, or an account that cannot reach what it now owns. A
# blind grader does not fail quietly: it returns a confident verdict about a diff
# it never read.
: > "$ASSIGNF"; : > "$DBWF"; : > "$RMF"
oprc=0
( real_spawn_env_
  _GRADER_PROCESS_RUNAS_CMD='return 0'
  _GRADER_READ_PROBE=probe_no
  probe_no(){ [[ "$1" == gr-* ]] && return 1; return 0; }   # the POOL seat reads; the CLONE does not
  _grader_process_spawn g1 DIVE-1 'g1#1' ) || oprc=$?
(( oprc != 0 )) && [[ ! -s "$ASSIGNF" && ! -s "$DBWF" ]] \
  && ok_ 'PROBE: a clone whose copied credential cannot read the delivery never reaches the row' \
  || bad_ 'PROBE clone read failure is free' "rc=$oprc assigns=$(assigns_) dbw=$(dbw_)"
grep -qx 'gr-g1-1' <<<"$(rms_)" \
  && ok_ 'PROBE: a clone that cannot read its own delivery is unwound on the spot' \
  || bad_ 'PROBE unwinds a blind clone' "$(rms_)"
# POSITIVE CONTROL: a probe that admits the clone must let the launch through, or
# the arm above is passed by a lane that refuses every clone there is.
: > "$RMF"
oqrc=0
( real_spawn_env_
  _GRADER_PROCESS_RUNAS_CMD='return 0'
  _GRADER_READ_PROBE=probe_ok
  _grader_process_spawn g1 DIVE-1 'g1#1' ) || oqrc=$?
(( oqrc == 0 )) && [[ ! -s "$RMF" ]] \
  && ok_ 'PROBE: a clone that CAN read its delivery is kept and woken (positive control)' \
  || bad_ 'PROBE admits a reading clone' "rc=$oqrc rm=$(rms_)"

# ── THE CREDENTIAL COPY REFUSES A WRITE-CAPABLE TOKEN ───────────────────────
#
# The real `_grader_clone_creds`, over a fixture home. The mint script's own rule
# is that the 5dive-bot classic PAT (scopes `repo, workflow`) must never be handed
# to a seat — it is full write on everything and it routes around the delegated
# push review gate. Graded as a CONTENT test, with a positive control beside it,
# because a path-based refusal would pass the negative arm and copy the token the
# day it arrives in a differently-named file.
credhome="$TMPD/homes"
mkdir -p "$credhome/agent-g1/.config/gh" "$credhome/agent-g1/.config/5dive"
printf 'github.com:\n  oauth_token: ghs_readonlyinstallationtoken\n' > "$credhome/agent-g1/.config/gh/hosts.yml"
printf 'GH_READ_TOKEN_5DIVE_AI=ghs_readonlyinstallationtoken\n'      > "$credhome/agent-g1/.config/5dive/gh-read-tokens.env"
mkdir -p "$credhome/agent-gr-g1-1"
printf 'GH_TOKEN=ghp_averyrealclassicpersonalaccesstoken\n' >> "$credhome/agent-g1/.config/5dive/gh-read-tokens.env"
: > "$WARNF"
# SCOPED TO THE ONE FILE THAT CARRIES THE BAD TOKEN. With both files in the list
# the copy stops on the FIRST one (install(1) cannot chown to an account that does
# not exist in this harness) and the arm would pass on an unrelated failure —
# reporting a refusal the code never reached.
# ON THE EXIT CODE, not merely on non-zero. Every failure in this function is
# non-zero — a missing file and a chown that cannot resolve the clone's account
# included — so `!= 0` would pass for a lane that removed the token test entirely
# and simply failed to copy. 4 is the refusal; 3 is "could not read/install".
credrc=0
( _GRADER_HOME_ROOT="$credhome"
  _GRADER_CLONE_CREDS_CMD=''
  _GRADER_CLONE_CRED_FILES='.config/5dive/gh-read-tokens.env'
  install(){ command install -D -m 0600 "${@: -2:1}" "${@: -1}"; }
  _grader_clone_creds gr-g1-1 g1 ) >/dev/null 2>&1 || credrc=$?
(( credrc == 4 )) \
  && ok_ 'CREDS: a write-capable ghp_ token in the source REFUSES the copy (rc=4, not a copy error)' \
  || bad_ 'CREDS a ghp_ token in the source is refused' "rc=$credrc"
grep -q 'REFUSED to copy' <<<"$(warns_)" \
  && ok_ 'CREDS: the refusal says why, naming the token class' || bad_ 'CREDS refusal is explained' "$(warns_)"
# THE POSITIVE CONTROL. Without it, a `return 1` at the top of the function passes
# the arm above and the lane never copies a credential at all.
# DIVE-4521 (precondition 3): the two shapes the alphabet did NOT cover. Each is
# graded on its own so a half-widened pattern cannot pass on the other's arm.
sed -i '/ghp_/d' "$credhome/agent-g1/.config/5dive/gh-read-tokens.env"
for _tok in 'GH_TOKEN=ghu_averyrealusertoservertoken' 'GH_TOKEN=github_pat_11ABCDEFG0aVeryFineGrained'; do
  printf '%s\n' "$_tok" >> "$credhome/agent-g1/.config/5dive/gh-read-tokens.env"
  credrc=0
  ( _GRADER_HOME_ROOT="$credhome"
    _GRADER_CLONE_CREDS_CMD=''
    _GRADER_CLONE_CRED_FILES='.config/5dive/gh-read-tokens.env'
    _grader_clone_creds gr-g1-1 g1 ) >/dev/null 2>&1 || credrc=$?
  [[ "$credrc" == 4 ]] \
    && ok_ "CREDS: a write-capable ${_tok%%=*}=${_tok#*=} token REFUSES the copy (rc=4)" \
    || bad_ "CREDS ${_tok#*=} is refused" "rc=$credrc"
  sed -i "\|${_tok#*=}|d" "$credhome/agent-g1/.config/5dive/gh-read-tokens.env"
done
: > "$WARNF"
( _GRADER_HOME_ROOT="$credhome"; _GRADER_CLONE_CREDS_CMD=''
  _GRADER_CLONE_CRED_FILES='.config/5dive/gh-read-tokens.env'
  # -D is KEPT and only the chown is dropped: the clone's account does not exist
  # in this harness, but the parent directories still have to be made or the arm
  # would red on a missing directory and read as a refusal.
  install(){ if [[ "$1" == -d ]]; then command mkdir -p "${@: -1}"; else command install -D -m 0600 "${@: -2:1}" "${@: -1}"; fi; }
  _grader_clone_creds gr-g1-1 g1 ) >/dev/null 2>&1 \
  && ok_ 'CREDS: a read-only ghs_ installation token IS copied (positive control)' \
  || bad_ 'CREDS copies a read-only token' "$(warns_)"
# ══ THE DIRECTORY MUST BE CREATED OWNED BY THE CLONE, and this arm is the one
# the first live arm bought. `gh` WRITES config.yml into its config dir on first
# use, so a root-owned ~/.config/gh presents three layers away as "this seat holds
# no gh credential" — which is what the live run actually reported. Graded on the
# ownership flags reaching an `install -d`, because that is the only form that
# applies an owner to every component it creates; `install -D` chowns the file and
# leaves the parents to root.
: > "$WARNF"; instlog="$TMPD/instargs"; : > "$instlog"
( _GRADER_HOME_ROOT="$credhome"; _GRADER_CLONE_CREDS_CMD=''
  _GRADER_CLONE_CRED_FILES='.config/5dive/gh-read-tokens.env'
  install(){ printf '%s\n' "$*" >> "$instlog"; if [[ "$1" == -d ]]; then command mkdir -p "${@: -1}"; else command install -D -m 0600 "${@: -2:1}" "${@: -1}"; fi; }
  _grader_clone_creds gr-g1-1 g1 ) >/dev/null 2>&1
grep -qE '^-d -o agent-gr-g1-1 -g agent-gr-g1-1 -m 0700 .*/agent-gr-g1-1/\.config/5dive$' "$instlog" \
  && ok_ 'CREDS: the credential DIRECTORY is created owned by the clone (gh writes into it)' \
  || bad_ 'CREDS creates the dir owned by the clone' "$(cat "$instlog")"
# A MISSING SOURCE IS A REFUSAL, not an empty copy: a clone with an absent
# hosts.yml grades blind, which is the state the row says must be unwound.
( _GRADER_HOME_ROOT="$credhome"; _GRADER_CLONE_CREDS_CMD=''
  _GRADER_CLONE_CRED_FILES='.config/gh/nonexistent.yml'
  _grader_clone_creds gr-g1-1 g1 ) >/dev/null 2>&1 \
  && bad_ 'CREDS a missing source is refused' '' \
  || ok_ 'CREDS: a credential file the pool seat does not have refuses the clone'

# F3: THE PROPERTY THAT WAS BROKEN — two consecutive ticks, failing wake.
PENDING="DIVE-1"; : > "$SPAWNF"
f3a=$( real_spawn_env_
       _GRADER_PROCESS_RUNAS_CMD='return 0'; _GRADER_CLONE_WAKE_CMD='return 1'
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
       _GRADER_PROCESS_RUNAS_CMD='return 0'; _GRADER_CLONE_WAKE_CMD='return 1'
       run_keep --cap=4 --commit --json )
[[ "$(jget "$f3b" pending)" == 1 ]] \
  && ok_ 'F3: the delivery is STILL PENDING on the next tick (it is re-picked, not stranded)' \
  || bad_ 'F3 row survives to the next tick' "$f3b"

# F4: the positive control. Without it, a lane that returned non-zero from every
# launch — or never emitted the ledger row at all — would pass every arm above,
# and the row would be re-graded on every tick forever.
: > "$SPAWNF"
f4a=$( real_spawn_env_
       _GRADER_PROCESS_RUNAS_CMD='return 0'
       run_keep --cap=4 --commit --json )
[[ "$(jget "$f4a" spawned)" == 1 && "$(jget "$f4a" failed)" == 0 ]] \
  && ok_ 'F4: a launch that DOES start is still counted as a spawn' || bad_ 'F4 spawn counted' "$f4a"
grep -q 'task.grade.spawned' <<<"$(cat "$EMITF")" \
  && ok_ 'F4: the ledger row is written once the launch is known started' \
  || bad_ 'F4 spawned row written' "$(cat "$EMITF")"
# THE ROW GOES TO THE CLONE, NOT THE POOL SEAT. The verdict path, the double-spawn
# guard and the reclaim rails all read `assignee`; a row owned by g1 while
# gr-g1-1 grades it is a grade no rail can attribute to the thing doing it.
grep -q 'task assign DIVE-1 gr-g1-' <<<"$(assigns_)" \
  && ok_ 'F4: the row is assigned to the CLONE, not to the pool seat' || bad_ 'F4 assigns the clone' "$(assigns_)"
[[ ! -s "$RMF" ]] \
  && ok_ 'F4: a launch that started removes nothing — the sweep owns the remove' || bad_ 'F4 no early remove' "$(rms_)"
f4b=$( real_spawn_env_
       _GRADER_PROCESS_RUNAS_CMD='return 0'
       run_keep --cap=4 --commit --json )
[[ "$(jget "$f4b" pending)" == 0 ]] \
  && ok_ 'F4: a started grade LEAVES pending, so the receipt still de-duplicates' \
  || bad_ 'F4 started grade leaves pending' "$f4b"

# ══ S. THE SWEEP: A CLONE MUST NEVER OUTLIVE ITS RUN BY MORE THAN ONE TICK ══
#
# Five states, each with its own fixture, because they take different branches and
# only two of them re-queue. The db stub answers the sweep's three questions from
# shell variables so each state can be posed exactly.
SW_RUN=""; SW_VERDICT=0; SW_STALE=0; SW_PASTGRACE=0
# ══ THE TWO AGE QUESTIONS ARE ANSWERED SEPARATELY, AND THAT IS NOT A DETAIL ══
# The sweep asks `_grader_clone_run_older_than` twice — once against the six-hour
# staleness bound and once against the start grace — and a stub that answered both
# from ONE variable made the STALE branch fire in every fixture meant for the DEAD
# one. Measured: with a single flag, a mutant that removed the liveness test
# entirely (`&& ! _grader_clone_live` -> `&& false`) SURVIVED all four S4 arms,
# because they were never reaching that branch. The stub therefore keys on the
# threshold the query carries: 21600 seconds is the bound, 300 is the grace.
sweep_db_() {
  case "$*" in
    *"FROM runs"*"status='running'"*) printf '%s' "$SW_RUN" ;;
    *"kind IN ('task.done'"*)         printf '%s' "$SW_VERDICT" ;;
    *"> 21600"*)                      printf '%s' "$SW_STALE" ;;
    *"julianday('now')-julianday"*)   printf '%s' "$SW_PASTGRACE" ;;
    *"COALESCE(verifier,'')"*)        printf 'quinn' ;;
    *"SET assignee=verifier"*)        printf '%s\n' "$*" >> "$DBWF" ;;
    *)                                printf '%s\n' "$*" >> "$DBWF" ;;
  esac
}
sweep_env_() {
  # shellcheck source=/dev/null
  source src/task/grader_process.sh
  db(){ sweep_db_ "$@"; }
  _GRADER_CLONE_LS_CMD='printf "gr-g1-1\n"'
  _GRADER_CLONE_PRUNE_CMD='printf PRUNED >> "$RMF"; return 0'
  _GRADER_CLONE_REMOVE_CMD='printf "%s\n" "$clone" >> "$RMF"; return 0'
  _GRADER_CLONE_LIVE_CMD='return 0'
  _GRADER_TASK_CLI="$FAKECLI"
}
sweep_(){ : > "$RMF"; : > "$EMITF"; : > "$DBWF"
          ( sweep_env_; eval "$1"; _grader_clone_sweep --commit ); }

# S1 LIVE: run open, no verdict, inside the bound, CLI running. Left alone.
n=$(sweep_ 'SW_RUN="gr-1-1'$US'DIVE-7'$US'2026-09-14 08:00:00"; SW_VERDICT=0')
[[ "$n" == 0 && ! "$(rms_)" =~ gr-g1-1 ]] \
  && ok_ 'S1: a clone whose grade is running is NOT swept' || bad_ 'S1 live clone survives' "swept=$n rm=$(rms_)"

# S1b LIVE PAST THE GRACE — the regime EVERY REAL GRADE OCCUPIES, and until this
# arm existed nothing graded it. S1 above poses a live clone but leaves the run
# row YOUNG, so `past the start grace AND not live` short-circuits on the FIRST
# conjunct and the liveness test is never reached: S1 passes because of the
# grace, not because of liveness. S4 poses the second conjunct only in the
# reap-it direction. So `_grader_clone_live` was graded in one direction only,
# and deleting it left all 83 arms green (main2's surviving mutant M3b,
# `&& ! _grader_clone_live "$clone"` -> `&& true`).
#
# THE GRACE IS 300s AND A GRADE RUNS 4-9 MINUTES, so a running grade spends most
# of its life here. Reaping a dead clone costs one re-queued delivery; reaping a
# LIVE one destroys a grade in flight, which is the expensive direction.
n=$(sweep_ 'SW_RUN="gr-1-1'$US'DIVE-7'$US'2026-09-14 08:00:00"; SW_PASTGRACE=1; _GRADER_CLONE_LIVE_CMD="return 0"')
[[ "$n" == 0 ]] && [[ ! "$(rms_)" =~ gr-g1-1 ]] && ! grep -q 'SET assignee=verifier' <<<"$(dbw_)" \
  && ok_ 'S1b: a clone PAST its start grace with a grading CLI still running is NOT swept' \
  || bad_ 'S1b live clone past the grace survives' "swept=$n rm=$(rms_) dbw=$(dbw_)"

# S2 RESOLVED: a verdict landed. Removed, and the run row is CLOSED — which is
# this row's live specimen: gr-20260914T054510Z-1554431-1 still read
# `running (open)` 37 minutes after its process was gone, because the record's
# liveness was asserted at INSERT and never checked again.
n=$(sweep_ 'SW_RUN="gr-1-1'$US'DIVE-7'$US'2026-09-14 08:00:00"; SW_VERDICT=1')
[[ "$n" == 1 ]] && grep -qx 'gr-g1-1' <<<"$(rms_)" \
  && ok_ 'S2: a clone whose verdict landed is removed on the next tick' || bad_ 'S2 resolved swept' "swept=$n rm=$(rms_)"
grep -q "UPDATE runs SET status='ok'" <<<"$(dbw_)" \
  && ok_ 'S2: the run record is CLOSED by the sweep, not left asserting running forever' \
  || bad_ 'S2 closes the run record' "$(dbw_)"
grep -q 'SET assignee=verifier' <<<"$(dbw_)" \
  && bad_ 'S2 a graded delivery is not restored to its verifier' "$(dbw_)" \
  || ok_ 'S2: a delivery that WAS graded is not handed back to its verifier'

# S3 ORPHAN: no open run row at all. Removed, nothing re-queued — there is no
# delivery to put back.
n=$(sweep_ 'SW_RUN=""')
[[ "$n" == 1 ]] && grep -qx 'gr-g1-1' <<<"$(rms_)" && ! grep -q 'task.grade' <<<"$(cat "$EMITF")" \
  && ok_ 'S3: a clone with no open run record is removed and no row is touched' \
  || bad_ 'S3 orphan swept' "swept=$n rm=$(rms_) emits=$(cat "$EMITF")"

# S4 DEAD: THE MUTANT THE ROW NAMES. run open, no verdict, inside the bound, past
# the start grace, and NO grading CLI running as the clone — i.e. someone SIGKILLed
# it mid-grade. It must be removed AND the delivery re-queued; before this, that
# state was contained only by the six-hour staleness bound.
n=$(sweep_ 'SW_RUN="gr-1-1'$US'DIVE-7'$US'2026-09-14 08:00:00"; SW_PASTGRACE=1; _GRADER_CLONE_LIVE_CMD="return 1"')
[[ "$n" == 1 ]] && grep -qx 'gr-g1-1' <<<"$(rms_)" \
  && ok_ 'S4: a clone killed mid-grade is removed on the next tick' || bad_ 'S4 dead swept' "swept=$n rm=$(rms_)"
# THE DELIVERY GOES BACK TO ITS ROUTED VERIFIER, which is where a swept grade
# recovers — the clone lane cannot re-request without a second
# `_grader_spawn_request` call site, and arm1b of grader_spawn_trigger_unit.sh
# asserts structurally that there is only one.
grep -q "SET assignee=verifier" <<<"$(dbw_)" \
  && ok_ 'S4: the delivery is handed back to its routed verifier, so it is graded on the next pass' \
  || bad_ 'S4 restores the row to its verifier' "$(dbw_)"
grep -q "status='abandoned'" <<<"$(dbw_)" \
  && ok_ 'S4: the run is closed ABANDONED, not failed — we saw it stop, not error (DIVE-3932)' \
  || bad_ 'S4 closes the run abandoned' "$(dbw_)"
grep -q 'task.grade.spawn.failed' <<<"$(cat "$EMITF")" \
  && ok_ 'S4: the swept attempt is on the ledger, not silently reverted' \
  || bad_ 'S4 compensating row' "$(cat "$EMITF")"
# THE GRACE IS LOAD-BEARING: without it every clone is swept during its own
# startup, because `agent create` returns before the CLI is up. Same fixture, run
# row young.
n=$(sweep_ 'SW_RUN="gr-1-1'$US'DIVE-7'$US'2026-09-14 08:00:00"; SW_PASTGRACE=0; _GRADER_CLONE_LIVE_CMD="return 1"')
[[ "$n" == 0 ]] \
  && ok_ 'S4: a clone still inside its start grace is not swept for having no CLI yet' \
  || bad_ 'S4 grace protects a starting clone' "swept=$n rm=$(rms_)"

# S4b STALE: run open past the six-hour bound, and the CLI is still running — a
# grade that is alive and wedged. Removed and re-queued all the same: the bound is
# what says a grade this old is no longer a grade. It is its OWN arm because it is
# a different branch from S4, and one flag answering both age questions is what let
# a liveness mutant survive here (see the stub).
n=$(sweep_ 'SW_RUN="gr-1-1'$US'DIVE-7'$US'2026-09-14 01:00:00"; SW_STALE=1; _GRADER_CLONE_LIVE_CMD="return 0"')
[[ "$n" == 1 ]] && grep -qx 'gr-g1-1' <<<"$(rms_)" && grep -q 'SET assignee=verifier' <<<"$(dbw_)" \
  && ok_ 'S4b: a clone still running past the staleness bound is swept and handed back' \
  || bad_ 'S4b stale swept' "swept=$n rm=$(rms_) emits=$(cat "$EMITF")"

# S5 DRY-RUN: the sweep must REPORT without removing, like the stale bound does.
: > "$RMF"; : > "$EMITF"
n=$( sweep_env_; SW_RUN=""; _grader_clone_sweep )
[[ "$n" == 1 && ! -s "$RMF" ]] \
  && ok_ 'S5: a dry-run sweep counts what it would remove and removes nothing' \
  || bad_ 'S5 dry-run removes nothing' "swept=$n rm=$(rms_)"
# The quarantine prune is a COMMIT-only act for the same reason.
n=$(sweep_ 'SW_RUN=""')
grep -q PRUNED <<<"$(rms_)" \
  && ok_ 'S5: a committed sweep also caps the age of the reap quarantine' || bad_ 'S5 prunes' "$(rms_)"

# ── THE TICK SWEEPS ON THE SAME TICK THAT CREATES ───────────────────────────
# The row's acceptance, asserted on the tick rather than on the function: a
# grader-tick in process mode must report the sweep on its own line and in its
# JSON, in dry-run as well as committed.
: > "$PSF"; INFLIGHT=0; SEATLOADS=""
swout=$( _GRADER_CLONE_SWEEP_STUB=1
         _grader_clone_sweep(){ printf 2; }
         run --cap=4 --commit )
grep -qE '^sweep   2 grader clone\(s\) removed' <<<"$swout" \
  && ok_ 'TICK: the tick that creates a clone reports the clones it swept' || bad_ 'TICK sweep line' "$swout"
grep -q 'swept=2' <<<"$swout" \
  && ok_ 'TICK: swept= is on the tick summary line' || bad_ 'TICK swept on summary' "$swout"
swoutj=$( _grader_clone_sweep(){ printf 2; }; run --cap=4 --commit --json )
[[ "$(jget "$swoutj" swept)" == 2 ]] \
  && ok_ 'TICK: swept is in the JSON too' || bad_ 'TICK swept in json' "$swoutj"
swoutd=$( _grader_clone_sweep(){ printf 2; }; run --cap=4 )
grep -qE 'would be removed \(dry-run\); [0-9]+ clone seat\(s\) present' <<<"$swoutd" \
  && ok_ 'TICK: a dry-run tick says what it WOULD remove, and does not call them "still grading"' \
  || bad_ 'TICK dry-run sweep line' "$swoutd"
# And in session mode it must not run at all — the default path must not reach
# into the clone machinery, which is the same property LOCK1/LOCK2 protect.
swouts=$( _GRADER_SPAWN_MODE=session
          _grader_clone_sweep(){ printf 'SWEEPRAN' >> "$WARNF"; printf 0; }
          run --cap=4 --commit )
grep -q SWEEPRAN <<<"$(warns_)" \
  && bad_ 'TICK session mode does not sweep' "$(warns_)" \
  || ok_ 'TICK: session mode never reaches the sweep'

# ── THE PER-TICK CREATE BUDGET, on the SHIPPED value ────────────────────────
PENDING="DIVE-1
DIVE-2
DIVE-3"
#
# A clone create is synchronous wall time inside a tick whose cron carries no
# flock, so the lane creates ONE per tick and reaches its cap over consecutive
# ticks. Graded with the budget at its default, which is the value that ships.
: > "$PSF"; INFLIGHT=0; SEATLOADS=""
_GRADER_CLONE_MAX_CREATES_PER_TICK=
unset _GRADER_CLONE_MAX_CREATES_PER_TICK
[[ "$(_grader_clone_create_budget)" == 1 ]] \
  && ok_ 'BUDGET: the shipped default is one clone create per tick' || bad_ 'BUDGET default' "$(_grader_clone_create_budget)"
bout=$(run --cap=4 --commit)
boutj=$(run --cap=4 --commit --json)
[[ "$(jget "$boutj" spawned)" == 1 && "$(jget "$boutj" queued)" == 2 ]] \
  && ok_ 'BUDGET: three deliveries under cap 4 create ONE clone and queue two' \
  || bad_ 'BUDGET binds at 1' "$boutj"
grep -q "clone-create budget of 1 is spent" <<<"$bout" \
  && ok_ 'BUDGET: the queue line names the budget, not the cap — two different facts' \
  || bad_ 'BUDGET queue reason' "$bout"
# A GARBAGE VALUE DEGRADES TO THE DEFAULT rather than to zero (which would stop
# the lane) or to an arithmetic error.
( _GRADER_CLONE_MAX_CREATES_PER_TICK=abc; [[ "$(_grader_clone_create_budget)" == 1 ]] ) \
  && ok_ 'BUDGET: a garbage budget degrades to 1, never to 0' || bad_ 'BUDGET garbage' ''
_GRADER_CLONE_MAX_CREATES_PER_TICK=99

# ── LINEAGE: A SAME-ORIGIN SEAT IS REFUSED (DIVE-4521, live case DIVE-4514) ──
#
# `writer != grader` compares NAMES, so `main2` grading `main`'s delivery passes
# it while carrying main's inherited blind spots. The gate is graded on the
# DISPATCHER because that is where it has to hold: the manual seat-level
# self-refusal that saved DIVE-4514 is a person noticing, not a control.
_GRADER_CLONE_MAX_CREATES_PER_TICK=99
PENDING="DIVE-1"
# The row id has to be REAL for these arms (the maker column is read behind it),
# which brings the verification-policy check at the top of the loop into play —
# that one reads the box's config and declines a row on a `verify=never` box. It
# is not what these arms grade, so it is stubbed to the granting answer.
_task_verify_grants(){ return 0; }
TASKID=42

# The three origin sources, each on its own arm.
[[ "$(_grader_seat_origin gr-quinn-3)" == quinn ]] \
  && ok_ 'LINEAGE: a clone this lane minted carries its origin in its NAME' \
  || bad_ 'LINEAGE clone name origin' "$(_grader_seat_origin gr-quinn-3)"
( _GRADER_SEAT_ORIGINS="main2=main"; [[ "$(_grader_seat_origin main2)" == main ]] ) \
  && ok_ 'LINEAGE: the operator map places a pool clone minted before lineage existed' \
  || bad_ 'LINEAGE operator map' ''
[[ "$(_grader_seat_origin quinn)" == quinn ]] \
  && ok_ 'LINEAGE: an agent nothing can place is its own origin (fails toward spawning)' \
  || bad_ 'LINEAGE unplaceable is itself' "$(_grader_seat_origin quinn)"
( _GRADER_SEAT_ORIGINS="main2=main"; _grader_same_origin main2 main ) \
  && ok_ 'LINEAGE: a clone and its origin are same-origin under two different names' \
  || bad_ 'LINEAGE same-origin across names' ''
_grader_same_origin "" main \
  && bad_ 'LINEAGE an unnamed maker is not a collision' '' \
  || ok_ 'LINEAGE: an unnamed maker collides with nothing (an unknown maker must not refuse the pool)'

# THE DISPATCHER ARM. g1 is the maker's own origin, g2 is independent: the pick
# must land on g2 whatever the round-robin cursor would otherwise have said.
: > "$PSF"; INFLIGHT=0; SEATLOADS=""; LASTPICK=g2
MAKER=g1
lout=$( _GRADER_SEAT_ORIGINS="g1=g1 g2=g2" run --cap=4 --commit )
grep -qE 'spawn   DIVE-1  -> g2' <<<"$lout" \
  && ok_ 'LINEAGE: the tick routes past the same-origin seat to the independent one' \
  || bad_ 'LINEAGE routes to independent seat' "$lout"
grep -q "g1 same-origin:g1" <<<"$lout" \
  && ok_ 'LINEAGE: the SPAWN line names the seat the lineage guard refused' \
  || bad_ 'LINEAGE refusal named on the spawn line' "$lout"
grep -q "same origin as maker main2" <<<"$loutq_seen" 2>/dev/null || true

# AND THE WHOLE POOL SAME-ORIGIN IS A QUEUE, NOT A GRADE. The failure this
# guards is a lane that, having refused every seat, grades anyway on the last one.
: > "$PSF"; INFLIGHT=0; SEATLOADS=""
MAKER=main2
loutq=$( _GRADER_SEAT_ORIGINS="g1=main g2=main main2=main" run --cap=4 --commit )
[[ ! -s "$PROCF" ]] \
  && ok_ 'LINEAGE: an all-same-origin pool launches NOTHING (it queues)' \
  || bad_ 'LINEAGE all same-origin queues' "$(procs_)"
grep -qE 'queue   DIVE-1' <<<"$loutq" \
  && ok_ 'LINEAGE: and says so as a queue line' || bad_ 'LINEAGE queue line' "$loutq"
# CONTROL: same fixture, lineage map removed => it spawns. Without this the two
# arms above would pass on any lane that simply refused to spawn at all.
: > "$PSF"; INFLIGHT=0; SEATLOADS=""
loutc=$( run --cap=4 --commit )
[[ -s "$PROCF" ]] \
  && ok_ 'LINEAGE control: with no lineage to read, the same delivery DOES spawn' \
  || bad_ 'LINEAGE control spawns' "$loutc"
MAKER=""; TASKID=""; LASTPICK=""

# ── THE LINEAGE FIELD IS WRITTEN AT CREATE (what the registry cannot infer) ──
REGF="$TMPD/agents.json"
printf '{"agents":{"gr-g1-1":{"type":"claude"}}}\n' > "$REGF"
registry_write(){ cat > "$REGF.new"; mv "$REGF.new" "$REGF"; }
( REGISTRY="$REGF"; _GRADER_CLONE_ORIGIN_CMD=''; _grader_clone_record_origin gr-g1-1 g1 ) >/dev/null 2>&1
[[ "$(jq -r '.agents["gr-g1-1"].origin' "$REGF")" == g1 ]] \
  && ok_ 'ORIGIN: a created clone records origin=<pool seat> in the registry' \
  || bad_ 'ORIGIN recorded' "$(cat "$REGF")"
# A NON-FATAL FAILURE, because the seat can grade without the annotation and the
# dispatcher reads the same fact out of the name.
orc=0
( REGISTRY="$TMPD/nope/agents.json"; _GRADER_CLONE_ORIGIN_CMD=''
  _grader_clone_record_origin gr-g1-1 g1 ) >/dev/null 2>&1 || orc=$?
[[ "$orc" == 0 ]] \
  && ok_ 'ORIGIN: an unwritable registry warns and does NOT fail the create' || bad_ 'ORIGIN non-fatal' "rc=$orc"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
