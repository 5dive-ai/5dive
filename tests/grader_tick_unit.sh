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
db(){ case "$*" in *grade.requested*) printf '%s\n' "$PENDING" ;; *COUNT*) printf '%s\n' "$INFLIGHT" ;; *) printf '' ;; esac; }
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

# ── structural: exactly one function may touch the fleet ─────────────────────
tickbody=$(awk '/^cmd_task_grader_tick\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' src/task/grader_pool.sh)
hits=$(grep -vE '^[[:space:]]*#' <<<"$tickbody" | grep -nE '5dive agent send|systemctl|agent create' || true)
[[ -z "$hits" ]] && ok_ 'structural: the tick body touches no fleet verb directly' \
  || bad_ 'structural: tick touches the fleet' "$hits"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
