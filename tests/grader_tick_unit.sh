#!/usr/bin/env bash
# DIVE-4164 isolated unit harness — the grader POOL LANE (`task grader-tick`).
#
# This is the one verb in the row that starts real sessions on a live fleet, so
# the arms that matter are the two safety locks, and they are tested as locks —
# i.e. by trying to make the lane spawn and asserting that it does not:
#
#   LOCK 1  dry-run is the default: no --commit, no spawn, ever.
#   LOCK 2  the pool is empty by default: --commit with no pool spawns nothing.
#
# Both must hold INDEPENDENTLY, so each is probed with the other lock released.
# A single test that passes --commit with an empty pool would be satisfied by
# either lock alone and could not tell which one was doing the work.
#
# No DB, no fleet: db/ledger_emit/the spawn primitive are stubs.
# Run: bash tests/grader_tick_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
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
INFLIGHT=0
# DIVE-4410: the per-seat reading and the round-robin cursor are two more reads
# off the same table. They are matched BEFORE `*COUNT*` because the seat-load
# query is itself a COUNT — matched after, it would be served the account-wide
# number and every seat would read as equally loaded, which is the defect.
SEATLOADS=""   # "<seat><US><n>" lines, one per busy pool seat
LASTPICK=""    # the seat the previous spawn landed on
US=$'\x1f'
db(){ case "$*" in
        *grade.requested*)              printf '%s\n' "$PENDING" ;;
        *"GROUP BY seat"*)              printf '%s\n' "$SEATLOADS" ;;
        *"ORDER BY s.id DESC LIMIT 1"*) printf '%s\n' "$LASTPICK" ;;
        *COUNT*)                        printf '%s\n' "$INFLIGHT" ;;
        *)                              printf '' ;;
      esac; }
fail(){ shift; printf 'FAILCALL %s\n' "$*" >&2; return 1; }
warn(){ :; }
task_actor(){ printf 'sys'; }
# ══ RECORDED TO FILES, NOT SHELL VARIABLES, AND THIS IS NOT A STYLE CHOICE ══
# Every probe below runs the lane inside `out=$(...)`, which is a SUBSHELL: a
# variable the stub appends to there is discarded when it exits. The first cut
# recorded into $SPAWNS and every safety arm asserted "$SPAWNS is empty" — which
# is unconditionally true in the parent, so the two locks this file exists to
# defend passed VACUOUSLY and would have passed just as loudly against a lane
# that spawned on every call. A file survives the subshell; a variable does not.
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/grader-tick.XXXXXX")"
trap 'rc=$?; rm -rf "$TMPD"; echo "HARNESS-RC=$rc"' EXIT
SPAWNF="$TMPD/spawns"; EMITF="$TMPD/emits"
ledger_emit(){ printf '%s\n' "$*" >> "$EMITF"; }
# The usage document both the floor and the account map read.
# g2 is a SECOND HEALTHY seat, and it exists for one arm: the fall-through past
# an unreadable seat. Written against g9 that arm passed for the wrong reason —
# g9's account is over the floor, so it is skipped before the credential probe is
# ever consulted, and the arm would have passed with the probe deleted.
USAGE='{"agents":[{"account":"mark","name":"g1","fiveHourPct":10,"sevenDayPct":20},
                  {"account":"mark","name":"g2","fiveHourPct":10,"sevenDayPct":20},
                  {"account":"spent","name":"g9","fiveHourPct":99,"sevenDayPct":99}]}'
# A FUNCTION, not a command string: `$_GRADER_USAGE_CMD` is expanded unquoted by
# the lane, so any stub carrying quotes or spaces word-splits into nonsense. The
# real default (`5dive usage --json`) is a clean word list; a stub must be too.
usage_cmd(){ printf '%s' "$USAGE"; }
# shellcheck source=/dev/null
source src/task/grader_pool.sh
_GRADER_USAGE_CMD=usage_cmd
# The credential probe is stubbed permissive by default so the arms above keep
# measuring what they were written to measure; the arms below flip it.
probe_ok(){ return 0; }
probe_no(){ return 1; }
probe_only_g1(){ [[ "$1" == g1 ]]; }
_GRADER_READ_PROBE=probe_ok
# ══ THE PRE-DIVE-4410 ARMS RUN WITH THE PER-SEAT CAP LIFTED, DELIBERATELY ══
# Everything above the DIVE-4410 section grades the FLOOR, the credential probe
# and errexit survival, and every one of those arms does it with a ONE-SEAT pool
# and three pending rows — i.e. by asserting all 3 land. Under the shipped
# per-seat cap of 1 they would instead be measuring the cap, and would report a
# spread regression as a floor regression. Lifting it here keeps each arm
# measuring the property it was written for; the cap gets its own section, and
# its SHIPPED default gets an arm that assigns nothing (see LOCK 2 THE SETTING
# for why an arm that assigns the flag cannot grade the default).
_GRADER_MAX_PER_SEAT=9
# Replace the ONLY fleet-touching function with a recorder.
SPAWNS=""
_grader_spawn_session(){ printf '%s\n' "$1:$2" >> "$SPAWNF"; return 0; }

run(){ : > "$SPAWNF"; : > "$EMITF"; cmd_task_grader_tick "$@" 2>/dev/null; }
spawns(){ cat "$SPAWNF" 2>/dev/null; }
emits(){ cat "$EMITF" 2>/dev/null; }

# ── LOCK 1: dry-run default, WITH a pool configured (lock 2 released) ─────────
_GRADER_POOL="g1"
out=$(run --cap=5)
[[ ! -s "$SPAWNF" ]] && ok_ 'LOCK1 dry-run: a configured pool still spawns nothing' \
  || bad_ 'LOCK1 dry-run spawns nothing' "spawned: $(spawns)"
grep -q 'spawn   DIVE-1' <<<"$out" && ok_ 'LOCK1 dry-run still PLANS the spawn' \
  || bad_ 'dry-run plans the spawn' "$out"
grep -q 'dry-run' <<<"$out" && ok_ 'LOCK1 says it is a dry run' || bad_ 'says dry-run' "$out"
[[ ! -s "$EMITF" ]] && ok_ 'LOCK1 dry-run writes no ledger row' || bad_ 'dry-run writes nothing' "$(emits)"

# ── LOCK 2: empty pool, WITH --commit (lock 1 released) ──────────────────────
_GRADER_POOL=""
out=$(run --cap=5 --commit)
[[ ! -s "$SPAWNF" ]] && ok_ 'LOCK2 --commit with no pool spawns nothing' \
  || bad_ 'LOCK2 empty pool spawns nothing' "spawned: $(spawns)"
# COUNTED, not grepped. The summary line always prints "dark=N", so a bare
# grep for "dark" matches even when the count is zero — it reported the lane
# dark against a mutant that had stopped treating it as dark at all.
outj=$(run --cap=5 --commit --json)
[[ "$(printf '%s' "$outj" | python3 -c 'import json,sys;print(json.load(sys.stdin)["dark"])')" == 3 ]] \
  && ok_ 'LOCK2 counts all 3 as dark (not merely queued)' \
  || bad_ 'LOCK2 counts them dark' "$outj"

# ── LOCK 2, THE SETTING: the pool the lane SHIPS WITH, not one we handed it ───
#
# Every arm in this file — LOCK 2 above included — assigns `_GRADER_POOL` in its
# own setup, so all of them grade the lock's MECHANISM (an empty pool refuses)
# and none of them grade its SHIPPED DEFAULT. Measured on the graded sha
# (DIVE-4164, f4178890): flipping `src/task/grader_pool.sh`'s
# `_GRADER_POOL="${_GRADER_POOL:-}"` to name a live seat left this file 19/0
# GREEN. "Ships dark" is exactly the half a reviewer is asked to accept, and it
# was the half nothing measured.
# See community/wiki/an-arm-that-assigns-the-flag-cannot-grade-the-default-it-ships-with.md
#
# So this arm assigns NOTHING: it unsets the variable, re-sources the lane so the
# default expansion actually runs, and reads what the lane says its pool is.
#
# WHY IT RE-APPLIES THE STUBS. Re-sourcing restores the REAL
# `_grader_spawn_session` and the real `_GRADER_USAGE_CMD`. Against a mutant that
# ships a non-empty default, an un-stubbed subshell would reach the live fleet
# verb — a harness that spawns for real is a worse failure than the one it is
# hunting. The stubs are re-applied after the source, in the same order the file
# header does it, so the fleet primitive is never reachable.
#
# WHY IT ASSERTS THE POOL FIELD AND THE DARK COUNT, NOT "NOTHING SPAWNED".
# A mutant naming a seat the usage fixture does not know (`quinn`) resolves to an
# empty account, is refused by the floor, and spawns nothing — so a spawn-count
# assertion passes against it. `pool` and `dark` separate "empty by default" from
# "non-empty but unlucky", which is the whole distinction.
#
# `--commit` HAS NO EQUIVALENT ARM AND DOES NOT NEED ONE. Its default is
# `local commit=0` inside `cmd_task_grader_tick`: no caller can assign it from
# outside, so no arm here can be blind to it the way these were blind to the
# pool, and LOCK 1 already kills the `local commit=1` mutant directly.
: > "$SPAWNF"; : > "$EMITF"
defj=$(
  unset _GRADER_POOL
  # shellcheck source=/dev/null
  source src/task/grader_pool.sh
  _GRADER_USAGE_CMD=usage_cmd
  _GRADER_READ_PROBE=probe_ok
  _grader_spawn_session(){ printf '%s\n' "$1:$2" >> "$SPAWNF"; return 0; }
  cmd_task_grader_tick --cap=5 --commit --json 2>/dev/null
)
[[ "$(printf '%s' "$defj" | python3 -c 'import json,sys;print(json.load(sys.stdin)["pool"])')" == "" ]] \
  && ok_ 'DEFAULT: the shipped _GRADER_POOL is empty (nothing assigned it)' \
  || bad_ 'shipped default pool is empty' "$defj"
[[ "$(printf '%s' "$defj" | python3 -c 'import json,sys;print(json.load(sys.stdin)["dark"])')" == 3 ]] \
  && ok_ 'DEFAULT: --commit on the shipped default counts all 3 dark, not queued' \
  || bad_ 'shipped default is dark' "$defj"
[[ ! -s "$SPAWNF" ]] && ok_ 'DEFAULT: --commit on the shipped default spawns nothing' \
  || bad_ 'shipped default spawns nothing' "spawned: $(spawns)"

# ── both released: it actually works, or the locks prove nothing ─────────────
_GRADER_POOL="g1"
out=$(run --cap=5 --commit)
[[ $(grep -c . "$SPAWNF") == 3 ]] && ok_ 'both locks off: spawns all 3 pending' \
  || bad_ 'both locks off spawns 3' "got: $(spawns)"
grep -q 'task.grade.spawned' "$EMITF" && ok_ 'records task.grade.spawned' || bad_ 'records spawn' "$(emits)"

# ── an active non-pool owner is never reassigned ────────────────────────────
# The query may encounter a stale request while its maker is already working
# again.  This guard runs before the cap/meter/read probes and must explain the
# refusal in the plan, not quietly turn the row into a verifier assignment.
_grader_non_pool_working_owner(){ [[ "$1" == DIVE-2 ]] && printf 'dev'; }
out=$(run --cap=5 --commit)
grep -q 'skip    DIVE-2  (owner is dev, not a pool seat)' <<<"$out" \
  && ok_ 'OWNER: plan names the non-pool working owner' \
  || bad_ 'owner skip line' "$out"
grep -q ':DIVE-2$' "$SPAWNF" \
  && bad_ 'OWNER: active maker is never assigned away' "$(spawns)" \
  || ok_ 'OWNER: active maker is never assigned away'
[[ "$(grep -c . "$SPAWNF")" == 2 ]] \
  && ok_ 'OWNER control: other pending rows still spawn' \
  || bad_ 'owner control spawns the other rows' "$(spawns)"
_grader_non_pool_working_owner(){ return 1; }
_grader_row_is_in_progress(){ return 1; }

# ── the cap ──────────────────────────────────────────────────────────────────
out=$(run --cap=1 --commit)
[[ $(grep -c . "$SPAWNF") == 1 ]] && ok_ 'cap=1 spawns exactly one' || bad_ 'cap=1' "got: $(spawns)"
grep -q 'queue   DIVE-2' <<<"$out" && ok_ 'cap=1 queues the rest' || bad_ 'cap queues rest' "$out"
INFLIGHT=5; out=$(run --cap=2 --commit)
[[ ! -s "$SPAWNF" ]] && ok_ 'already over cap: spawns nothing' || bad_ 'over cap spawns nothing' "$(spawns)"
INFLIGHT=0

# ── the floor: a seat whose account is exhausted must not be chosen ──────────
_GRADER_POOL="g9"
out=$(run --cap=5 --commit)
[[ ! -s "$SPAWNF" ]] && ok_ 'exhausted account: no spawn' || bad_ 'exhausted account' "$(spawns)"
grep -q 'queue' <<<"$out" && ok_ 'exhausted account queues' || bad_ 'exhausted queues' "$out"
# and a healthy seat later in the pool is still reachable past an exhausted one
_GRADER_POOL="g9 g1"
out=$(run --cap=5 --commit)
[[ $(grep -c . "$SPAWNF") == 3 ]] && ok_ 'falls through an exhausted seat to a healthy one' \
  || bad_ 'falls through to healthy seat' "$(spawns)"
grep -q '^g1:' "$SPAWNF" && ok_ 'chose the healthy seat, not the exhausted one' \
  || bad_ 'chose healthy seat' "$(spawns)"

# ── guardrail 2: never a grader without read access to the repo it grades ────
_GRADER_POOL="g1"; _GRADER_READ_PROBE=probe_no
out=$(run --cap=5 --commit)
[[ ! -s "$SPAWNF" ]] && ok_ 'no read access: spawns nothing even with headroom' \
  || bad_ 'no read access spawns nothing' "$(spawns)"
grep -q 'cannot read the delivery ref' <<<"$out" \
  && ok_ 'says WHY it declined (cannot read the ref)' || bad_ 'names the reason' "$out"
# A seat that can read is still reachable past one that cannot.
_GRADER_POOL="g2 g1"; _GRADER_READ_PROBE=probe_only_g1
out=$(run --cap=5 --commit)
grep -q '^g1:' "$SPAWNF" && ok_ 'falls through an unreadable seat to a readable one' \
  || bad_ 'falls through unreadable seat' "$(spawns)"
_GRADER_READ_PROBE=probe_ok

# ══ THE REFUSAL PATH, UNDER THE REGIME THE SHIPPED CLI ACTUALLY RUNS ═════════
#                                                                  (DIVE-4380)
# THE FOUR FLOOR ARMS ABOVE CANNOT SEE THIS CLASS OF DEFECT, and that is why
# this section is a REGIME and not a fifth fixture. They already make the meter
# refuse, and they were green against a lane that in production died inside pool
# iteration 1: this harness runs `set -uo pipefail` (line 17) while the bundle
# runs `set -euo pipefail` (src/header.sh:14).
#
# `_grader_window_ok` is dual-channel by design — verdict on stdout, DECISION in
# the exit status — so a refusing seat returns non-zero as its ANSWER. Written
# `verdict=$(…); rc=$?` that is harmless without errexit and fatal with it: the
# shell aborts on the ASSIGNMENT, so `rc` is never read, the second pool seat is
# never tried, and `queue (no seat with headroom — …)` is unreachable. Measured
# on 0.35.1, 2026-09-12: `_GRADER_POOL="quinn main2" 5dive task grader-tick`
# exited non-zero printing no plan at all, and the caller saw only the CLI's
# generic `exited 1 without reporting a reason`.
# community/wiki/a-refusal-verdict-captured-into-a-variable-dies-under-set-e.md
#
# THE SENTINEL IS READ OFF STDOUT, AND THE RUN IS NEVER PUT IN A `||` OR `if`
# CONTEXT. bash's errexit exemption propagates INTO a subshell on the left of
# `||`, so `( set -e; … ) || echo DIED` can never print DIED — attaching the
# catch removes the death it was written to catch. `run_e` therefore prints
# `RC=0` as its LAST statement inside the errexit subshell: the line is present
# only if the lane both returned 0 and was not killed on the way, and its
# ABSENCE is the death.
run_e(){  # run(), but under the bundle's own `set -euo pipefail`
  : > "$SPAWNF"; : > "$EMITF"
  (
    set -euo pipefail
    cmd_task_grader_tick "$@" 2>/dev/null
    printf 'RC=0\n'
  )
}
# A: a refusing FIRST seat must not kill the tick — seat 2 is reached and chosen.
_GRADER_POOL="g9 g1"; _GRADER_READ_PROBE=probe_ok
oute=$(run_e --cap=5 --commit)
grep -q '^RC=0$' <<<"$oute" \
  && ok_ 'ERREXIT: a seat over the floor is a branch, not a death (lane survives)' \
  || bad_ 'ERREXIT refusing seat does not abort' "lane died before its sentinel; got: $oute"
grep -q '^g1:' "$SPAWNF" \
  && ok_ 'ERREXIT: the SECOND pool seat is still reached past a refusing first' \
  || bad_ 'ERREXIT reaches seat 2' "spawned: $(spawns)"
[[ "$(grep -c . "$SPAWNF")" == 3 ]] \
  && ok_ 'ERREXIT: all 3 pending rows are still planned past the refusal' \
  || bad_ 'ERREXIT spawns 3 past a refusal' "spawned: $(spawns)"
# B: a pool where EVERY seat refuses must PRINT the queue line, not vanish.
#    This is the lane's whole throttle-and-park behaviour; unreachable, it has
#    no observable form at all.
_GRADER_POOL="g9"
oute=$(run_e --cap=5 --commit)
grep -q '^RC=0$' <<<"$oute" \
  && ok_ 'ERREXIT: an all-refusing pool exits 0, not a silent non-zero' \
  || bad_ 'ERREXIT all-refusing pool exits 0' "lane died; got: $oute"
grep -q 'queue   DIVE-1  (no seat with headroom — ' <<<"$oute" \
  && ok_ 'ERREXIT: prints queue (no seat with headroom — …) — the park behaviour' \
  || bad_ 'ERREXIT prints the queue line' "$oute"
grep -q 'g9: queue: spent is at 99%' <<<"$oute" \
  && ok_ 'ERREXIT: the queue line carries the refusing seat own verdict' \
  || bad_ 'queue line names the verdict' "$oute"
[[ ! -s "$SPAWNF" ]] && ok_ 'ERREXIT: an all-refusing pool still spawns nothing' \
  || bad_ 'all-refusing pool spawns nothing' "spawned: $(spawns)"
# C: THE OTHER non-zero channel. `_grader_window_ok` returns 1 for "no
#    measurement" and 2 for "over floor"; a seat the usage document does not
#    know at all resolves to an empty account and takes the rc=1 door, which is
#    the exact status the live tick surfaced. Both doors must branch.
_GRADER_POOL="gNOTINMETER g1"
oute=$(run_e --cap=5 --commit)
grep -q '^RC=0$' <<<"$oute" \
  && ok_ 'ERREXIT: an UNMEASURED seat (rc=1) is a branch too, not a death' \
  || bad_ 'ERREXIT unmeasured seat does not abort' "lane died; got: $oute"
grep -q '^g1:' "$SPAWNF" \
  && ok_ 'ERREXIT: falls through an unmeasured seat to a measured one' \
  || bad_ 'falls through unmeasured seat' "spawned: $(spawns)"
# D: THE ADMIT PATH UNDER THE SAME REGIME, which is what grades the `rc=0`
#    initialiser. `|| rc=$?` leaves `rc` untouched when the guard admits, so
#    without the initialiser `(( rc == 0 ))` reads an unset variable and
#    `set -u` kills the tick on the HEALTHY path — the fix's own failure mode,
#    and the one a refusal fixture can never reach.
_GRADER_POOL="g1"
oute=$(run_e --cap=5 --commit)
grep -q '^RC=0$' <<<"$oute" \
  && ok_ 'ERREXIT: the ADMIT path survives set -u (rc is initialised)' \
  || bad_ 'ERREXIT admit path survives nounset' "lane died; got: $oute"
[[ "$(grep -c . "$SPAWNF")" == 3 ]] \
  && ok_ 'ERREXIT: the admit path still spawns all 3' || bad_ 'errexit admit spawns 3' "$(spawns)"

# ── structural: exactly one function may touch the fleet ─────────────────────
tickbody=$(awk '/^cmd_task_grader_tick\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' src/task/grader_pool.sh)
hits=$(grep -vE '^[[:space:]]*#' <<<"$tickbody" | grep -nE '5dive agent send|systemctl|agent create' || true)
[[ -z "$hits" ]] && ok_ 'structural: the tick body touches no fleet verb directly' \
  || bad_ 'structural: tick touches the fleet' "$hits"


# ── _grader_can_read: the REAL body, which no arm above ever executes ────────
#
# Every arm in this file replaces the credential probe through
# `_GRADER_READ_PROBE`, so the lane's DECISION logic is graded twenty ways and
# the probe's own body is graded nowhere. That blind spot shipped a defect.
#
# A SEAT NAME IS NOT A UNIX ACCOUNT. The pool, the ledger, `task assign` and
# `agent send` all take `quinn`; the account this host switches to is
# `agent-quinn`, which is how every other seat-targeting sudo in the CLI spells
# it. The body ran `sudo -n -u "$seat"`, so on the live host it exited 1 with
# "unknown user quinn" — and an unknown user exits exactly like a refused one.
# Measured 2026-09-10 (DIVE-4217) against the live store with a real pool:
# pending=8 spawn=0 queue=8, every line reading "has headroom but cannot read
# the delivery ref", while the same probe spelled `agent-quinn` / `agent-main2`
# returned 0 for both seats. The lane could not spawn, and said nothing that
# pointed at why.
#
# THIS ARM ASSERTS THE ARGV, NOT THE EXIT STATUS, and that is the lesson: a
# wrong account and an unreadable ref produce the SAME non-zero, so no
# outcome-shaped arm can see this class of bug. Compare
# community/wiki/an-arm-that-assigns-the-flag-cannot-grade-the-default-it-ships-with.md
# — there behaviour masked the setting; here it masks the callee.
#
# THE STUB IS A FUNCTION, NOT A SCRIPT ON $PATH, and that is not a style choice.
# This corpus installs a `sudo` shell FUNCTION (tests/lib/env_isolation.sh) that
# refuses with rc=125, and a function shadows every $PATH entry — a PATH stub
# here is unreachable and records nothing, which reads as "the probe never ran".
# The reachability control below is what caught that; keep it first.
SUDO_ARGVF="$TMPD/sudo.argv"
probe_argv=$(
  : > "$SUDO_ARGVF"
  sudo(){ printf '%s\n' "$*" >> "$SUDO_ARGVF"; return 0; }
  db(){ case "$*" in *delivery_ref*) printf '%s\n' 'https://github.com/o/r/pull/1' ;; *) printf '' ;; esac; }
  sqlq(){ printf "'%s'" "$1"; }
  _GRADER_READ_PROBE=
  _grader_can_read g1 DIVE-1 >/dev/null 2>&1
  cat "$SUDO_ARGVF"
)
[[ -n "$probe_argv" ]] && ok_ 'PROBE control: the real _grader_can_read body reached sudo' \
  || bad_ 'probe body reached sudo' 'nothing recorded — every arm below would be vacuous'
grep -qE '(^| )-u agent-g1( |$)' <<<"$probe_argv" \
  && ok_ 'PROBE: switches to the UNIX ACCOUNT agent-g1, not the seat name' \
  || bad_ 'probe names agent-<seat>' "argv: $probe_argv"
grep -qE '(^| )-u g1( |$)' <<<"$probe_argv" \
  && bad_ 'probe must not pass the bare seat name' "argv: $probe_argv" \
  || ok_ 'PROBE: never hands sudo a bare seat name (unknown user == a false refusal)'
grep -qE 'gh pr view https://github.com/o/r/pull/1( |$)' <<<"$probe_argv" \
  && ok_ 'PROBE: reads the row own delivery ref, not a substitute' \
  || bad_ 'probe reads the delivery ref' "argv: $probe_argv"
# The inverted guardrail, kept as a named arm because the mutant is a REVERT.
# `merge-gate-selftest --pr=` demands a MERGED control PR and returns non-zero on
# anything else, so using it on the subject refuses every OPEN delivery — i.e.
# every delivery worth grading — and admits only already-merged refs.
grep -q 'merge-gate-selftest' <<<"$probe_argv" \
  && bad_ 'probe must not use the merged-control selftest on the subject' "argv: $probe_argv" \
  || ok_ 'PROBE: does not ask a merged-control selftest about an open PR'

# STATE-AGNOSTIC: an OPEN pull request is READABLE. This is the arm the shipped
# code failed; it is the difference between "the rail answered" and "the answer
# was the one we like".
for st in OPEN CLOSED MERGED; do
  rc_st=$(
    sudo(){ printf '%s\n' "$st"; return 0; }
    db(){ case "$*" in *delivery_ref*) printf '%s\n' 'https://github.com/o/r/pull/1' ;; *) printf '' ;; esac; }
    sqlq(){ printf "'%s'" "$1"; }
    _GRADER_READ_PROBE=
    _grader_can_read g1 DIVE-1 >/dev/null 2>&1; echo $?
  )
  [[ "$rc_st" == 0 ]] && ok_ "PROBE: a PR reading $st counts as READABLE" \
    || bad_ "PR state $st is readable" "rc=$rc_st"
done
# ...and a rail that answers NOTHING is a refusal, not a pass. This is the
# fail-CLOSED half; without it the change above would be a widening.
rc_blind=$(
  sudo(){ printf ''; return 1; }
  db(){ case "$*" in *delivery_ref*) printf '%s\n' 'https://github.com/o/r/pull/1' ;; *) printf '' ;; esac; }
  sqlq(){ printf "'%s'" "$1"; }
  _GRADER_READ_PROBE=
  _grader_can_read g1 DIVE-1 >/dev/null 2>&1; echo $?
)
[[ "$rc_blind" != 0 ]] && ok_ 'PROBE: a blind seat (empty answer) is REFUSED, not admitted' \
  || bad_ 'blind seat refused' "rc=$rc_blind"

# The early guard: a row with no delivery_ref must be refused before the probe,
# not probed with --pr= empty.
noref_argv=$(
  : > "$TMPD/sudo.noref"
  sudo(){ printf '%s\n' "$*" >> "$TMPD/sudo.noref"; return 0; }
  db(){ printf ''; }
  sqlq(){ printf "'%s'" "$1"; }
  _GRADER_READ_PROBE=
  _grader_can_read g1 DIVE-1 >/dev/null 2>&1
  cat "$TMPD/sudo.noref"
)
[[ -z "$noref_argv" ]] && ok_ 'PROBE: a row with no delivery_ref is refused without spending a sudo' \
  || bad_ 'no ref means no sudo' "argv: $noref_argv"


# ── --only=<ident>: one named delivery, and no collateral ───────────────────
# The control that made the owed end-to-end arm runnable at all: without it the
# tick is all-or-nothing over the pending set, so a first live run also spawns
# graders onto rows whose verifier is someone else. It must FILTER, never
# RELEASE — --commit is still the lock, an unnamed pool is still dark.
_GRADER_POOL="g1"; _GRADER_READ_PROBE=probe_ok
out=$(run --cap=5 --commit --only=DIVE-2)
[[ "$(grep -c . "$SPAWNF")" == 1 ]] && ok_ 'ONLY: spawns exactly one' || bad_ 'only spawns one' "$(spawns)"
grep -q ':DIVE-2$' "$SPAWNF" && ok_ 'ONLY: spawns the NAMED row' || bad_ 'only spawns the named row' "$(spawns)"
grep -qE 'DIVE-(1|3)' <<<"$out" && bad_ 'only must not report the unnamed rows' "$out" \
  || ok_ 'ONLY: the rest of the queue is untouched and unreported'
outj=$(run --cap=5 --commit --only=DIVE-2 --json)
[[ "$(printf '%s' "$outj" | python3 -c 'import json,sys;print(json.load(sys.stdin)["pending"])')" == 1 ]] \
  && ok_ 'ONLY: counts only the named row as pending' || bad_ 'only counts 1 pending' "$outj"
out=$(run --cap=5 --commit --only=DIVE-NOPE)
[[ ! -s "$SPAWNF" ]] && ok_ 'ONLY: an ident that is not pending spawns nothing' || bad_ 'only unknown ident' "$(spawns)"
# It filters; it does not release either lock.
out=$(run --cap=5 --only=DIVE-2)
[[ ! -s "$SPAWNF" ]] && ok_ 'ONLY: still honours LOCK 1 (no --commit, no spawn)' || bad_ 'only + dry-run' "$(spawns)"
_GRADER_POOL=""
out=$(run --cap=5 --commit --only=DIVE-2)
[[ ! -s "$SPAWNF" ]] && ok_ 'ONLY: still honours LOCK 2 (empty pool, no spawn)' || bad_ 'only + empty pool' "$(spawns)"
_GRADER_POOL="g1"

# ══ DIVE-4410: THE POOL IS A SET OF SEATS, NOT A PREFERENCE LIST ═════════════
#
# The lane was first-fit over `$_GRADER_POOL`, gated only by ACCOUNT headroom and
# repo readability — neither of which is per-SEAT. MEASURED on main 2026-09-13:
# 126 consecutive spawns, every one `-> quinn`, and one tick putting DIVE-4404,
# 4397, 4401 and 4405 onto quinn together while main2 idled. A spawn is
# assign+wake and a seat runs ONE session, so that tick's `spawn=4` was a 4-deep
# serial queue, not four graders.
#
# WHY EVERY ARM HERE USES A TWO-SEAT POOL ON ONE ACCOUNT (g1 and g2 both read
# account `mark`): a two-ACCOUNT pool would spread for the wrong reason — the
# floor is already per-account, so the old first-fit lane passes such a fixture.
# One account is the shape the defect lives in and the shape the fleet runs.
_GRADER_POOL="g1 g2"; _GRADER_READ_PROBE=probe_ok
_GRADER_MAX_PER_SEAT=1
SEATLOADS=""; LASTPICK=""; INFLIGHT=0

# ── the ordering primitive, graded on its own ────────────────────────────────
# Load DOMINATES the cursor: a seat at 0 is never passed over for one at 1, and
# the cursor only breaks the tie. Asserted separately because the two rules are
# independently wrong-able and the tick can only show one of them at a time.
ord(){ printf '%s' "$2" | _grader_pool_order "$1" | tr '\n' ' '; }
[[ "$(ord '' '')" == 'g1 g2 ' ]] \
  && ok_ 'ORDER: an idle pool with no cursor keeps pool order' || bad_ 'order idle' "$(ord '' '')"
[[ "$(ord g1 '')" == 'g2 g1 ' ]] \
  && ok_ 'ORDER: the cursor rotates past the last-picked seat' || bad_ 'order rotates' "$(ord g1 '')"
[[ "$(ord g2 '')" == 'g1 g2 ' ]] \
  && ok_ 'ORDER: the rotation wraps' || bad_ 'order wraps' "$(ord g2 '')"
[[ "$(ord g1 'g2=1
g1=0
')" == 'g1 g2 ' ]] \
  && ok_ 'ORDER: LOAD BEATS THE CURSOR — a busy g2 loses to an idle g1 it points at' \
  || bad_ 'order load beats cursor' "$(ord g1 'g2=1
g1=0
')"
[[ "$(ord gGONE '')" == 'g1 g2 ' ]] \
  && ok_ 'ORDER: a cursor naming a seat no longer in the pool degrades to pool order' \
  || bad_ 'order unknown cursor' "$(ord gGONE '')"

# ── two idle seats, two pending rows: ONE EACH ───────────────────────────────
PENDING="DIVE-1
DIVE-2"
out=$(run --cap=5 --commit)
[[ "$(grep -c . "$SPAWNF")" == 2 ]] && ok_ 'SPREAD: both rows spawn' || bad_ 'spread spawns 2' "$(spawns)"
{ grep -q '^g1:' "$SPAWNF" && grep -q '^g2:' "$SPAWNF"; } \
  && ok_ 'SPREAD: one spawn per seat — g1 AND g2, not two onto g1' \
  || bad_ 'SPREAD one per seat' "spawned: $(spawns)"
# THE NEGATIVE HALF. Two spawns landing on two seats is also what a lane that
# alternates blindly would produce; what must be true is that NEITHER seat took
# both, i.e. the second row read the first row's spawn.
[[ "$(cut -d: -f1 "$SPAWNF" | sort -u | wc -l)" == 2 ]] \
  && ok_ 'SPREAD: no seat took both rows (the in-tick reading is maintained)' \
  || bad_ 'no seat takes both' "$(spawns)"
grep -q 'spawn   DIVE-1  -> g1' <<<"$out" && grep -q 'spawn   DIVE-2  -> g2' <<<"$out" \
  && ok_ 'SPREAD: the PLAN NAMES BOTH seats' || bad_ 'plan names both seats' "$out"

# ── the pick reason rides on the spawn line ──────────────────────────────────
grep -q 'spawn   DIVE-2  -> g2  (in-flight g1=1 g2=0; g1 busy:1;' <<<"$out" \
  && ok_ 'REASON: the spawn line says which seats were busy and what the loads were' \
  || bad_ 'spawn line carries the pick reason' "$out"

# ── a third row with BOTH seats busy QUEUES; it does not stack ───────────────
PENDING="DIVE-1
DIVE-2
DIVE-3"
SEATLOADS="g1${US}1
g2${US}1"
out=$(run --cap=9 --commit)
[[ ! -s "$SPAWNF" ]] && ok_ 'BUSY: every pool seat at its per-seat cap spawns nothing' \
  || bad_ 'busy pool spawns nothing' "spawned: $(spawns)"
grep -q 'queue   DIVE-1  (no free seat — g1 busy:1; g2 busy:1;' <<<"$out" \
  && ok_ 'BUSY: queues and NAMES the busy seats' || bad_ 'busy queue line' "$out"
outj=$(run --cap=9 --commit --json)
[[ "$(printf '%s' "$outj" | python3 -c 'import json,sys;print(json.load(sys.stdin)["queued"])')" == 3 ]] \
  && ok_ 'BUSY: all 3 counted QUEUED (not spawned, not dark)' || bad_ 'busy queues 3' "$outj"

# ── never a seat at 1 while another is at 0 ──────────────────────────────────
PENDING="DIVE-1"
SEATLOADS="g1${US}1"
LASTPICK="g1"
out=$(run --cap=9 --commit)
[[ "$(cat "$SPAWNF")" == 'g2:DIVE-1' ]] \
  && ok_ 'LEAST-LOADED: a busy g1 is skipped for an idle g2' || bad_ 'least loaded' "$(spawns)"
# and the mirror image, so the arm is not just "g2 always wins"
SEATLOADS="g2${US}1"
LASTPICK="g2"
out=$(run --cap=9 --commit)
[[ "$(cat "$SPAWNF")" == 'g1:DIVE-1' ]] \
  && ok_ 'LEAST-LOADED: mirrored — a busy g2 is skipped for an idle g1' || bad_ 'least loaded mirror' "$(spawns)"

# ── the cursor breaks the all-idle tie, so a drained pool does not re-first-fit ─
SEATLOADS=""; LASTPICK="g1"
out=$(run --cap=9 --commit)
[[ "$(cat "$SPAWNF")" == 'g2:DIVE-1' ]] \
  && ok_ 'ROUND-ROBIN: with both seats idle the pick follows the cursor, not pool order' \
  || bad_ 'round robin tie' "$(spawns)"
LASTPICK="g2"
out=$(run --cap=9 --commit)
[[ "$(cat "$SPAWNF")" == 'g1:DIVE-1' ]] \
  && ok_ 'ROUND-ROBIN: the cursor wraps back to the head of the pool' || bad_ 'round robin wrap' "$(spawns)"

# ── the floor still wins over the load: an idle seat on a spent account loses ─
# The account floor is UNCHANGED by this row and must stay the harder gate —
# spreading onto an exhausted account is a worse failure than a serial queue.
_GRADER_POOL="g9 g1"; SEATLOADS="g1${US}0"; LASTPICK="g9"
out=$(run --cap=9 --commit)
[[ "$(cat "$SPAWNF")" == 'g1:DIVE-1' ]] \
  && ok_ 'FLOOR: an idle seat whose ACCOUNT is spent is still refused' || bad_ 'floor beats load' "$(spawns)"
_GRADER_POOL="g1 g2"; LASTPICK=""; SEATLOADS=""

# ── the SHIPPED per-seat cap, assigned by nobody ─────────────────────────────
# Same reasoning as LOCK 2 THE SETTING: every arm above assigns
# `_GRADER_MAX_PER_SEAT`, so none of them can see a lane that ships with it at 4.
# This one unsets it, re-sources the lane so the default expansion runs, reads
# what the lane says, and re-applies the stubs in the header's own order so the
# real fleet primitive is never reachable from here.
( unset _GRADER_MAX_PER_SEAT
  # shellcheck source=/dev/null
  source src/task/grader_pool.sh
  [[ "$_GRADER_MAX_PER_SEAT" == 1 ]] ) \
  && ok_ 'DEFAULT: the shipped per-seat cap is 1 — one grading session per seat' \
  || bad_ 'shipped per-seat cap is 1' "got: ${_GRADER_MAX_PER_SEAT}"
# shellcheck source=/dev/null
source src/task/grader_pool.sh
_GRADER_USAGE_CMD=usage_cmd
_GRADER_READ_PROBE=probe_ok
_grader_spawn_session(){ printf '%s\n' "$1:$2" >> "$SPAWNF"; return 0; }
_GRADER_MAX_PER_SEAT=1

# ── the account-wide cap is untouched and still binds ────────────────────────
# Two idle seats must NOT become a way past `--cap`: the per-seat rule narrows
# the lane, it never widens it.
PENDING="DIVE-1
DIVE-2"
SEATLOADS=""; INFLIGHT=5
out=$(run --cap=2 --commit)
[[ ! -s "$SPAWNF" ]] && ok_ 'CAP: a full account cap still blocks both idle seats' \
  || bad_ 'account cap still binds' "$(spawns)"
INFLIGHT=0
PENDING="DIVE-1
DIVE-2
DIVE-3"
_GRADER_POOL="g1"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
