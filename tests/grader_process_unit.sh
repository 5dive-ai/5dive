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
        *grade.requested*)              printf '%s\n' "$PENDING" ;;
        *"GROUP BY seat"*)              printf '%s\n' "$SEATLOADS" ;;
        *"ORDER BY s.id DESC LIMIT 1"*) printf '%s\n' "$LASTPICK" ;;
        *COUNT*)                        printf '%s\n' "$INFLIGHT" ;;
        *)                              printf '' ;;
      esac; }
sqlq(){ printf "'%s'" "${1//\'/\'\'}"; }
fail(){ shift; printf 'FAILCALL %s\n' "$*" >&2; return 1; }
warn(){ :; }
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
: > "$PSF"
ledger_emit(){ printf '%s\n' "$*" >> "$EMITF"; }

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

run(){ : > "$PROCF"; : > "$SESSF"; : > "$EMITF"; cmd_task_grader_tick "$@" 2>/dev/null; }
procs_(){ cat "$PROCF" 2>/dev/null; }
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
