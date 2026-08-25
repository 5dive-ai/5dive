#!/usr/bin/env bash
# DIVE-3628 unit harness for _hb_memory_consolidate_sweep — THE SCHEDULER.
#
# The verb was already covered by tests/memory_consolidate_unit.sh. What was
# never covered, and what quinn bounced iteration 1 for, is that anything FIRES
# it: "a verb with no scheduler is not an async pipeline". So every arm here is
# about the firing decision, not about distillation.
#
# The arms that matter are the ones that would let COST run away, because that is
# the failure this sweep is one tick away from at all times (the tick fires every
# 5 minutes; a distiller call costs real money and takes ~35s):
#   - the cadence gate is proved by a SECOND call in the same window making no
#     further invocation — a gate that let everything through would still pass a
#     "did it run at all" arm.
#   - the stamp is written BEFORE the run, proved by a distiller that FAILS
#     still leaving a stamp. Stamping after would re-enter a wedged pass on
#     every tick and multiply the spend by however many ticks it outlives.
#   - the off switch is proved by zero invocations, not by a flag being read.
#   - a failing seat is proved to be COUNTED, not swallowed: a fleet auth lapse
#     must not read as a quiet box (the same succeeding-in-appearance trap the
#     verb's own DISTILLER FAILED class exists for).
# Run: bash tests/heartbeat_memory_consolidate_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/hb-consol-unit.XXXXXX)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

# --- Extract the sweep + its constants from the module ------------------------
# cmd_heartbeat.sh is ~4000 lines and sourcing it whole drags in a registry, a
# DB and root checks. The sweep is self-contained, so the harness lifts exactly
# it. Extraction is ASSERTED (not assumed): if the function is renamed or moved,
# this harness fails loudly instead of testing an empty string and going green.
SWEEP_SRC=$(awk '/^_hb_memory_consolidate_sweep\(\) \{/,/^\}/' "$SRC/cmd_heartbeat.sh")
if [ -z "$SWEEP_SRC" ]; then
  echo "  FAIL — could not extract _hb_memory_consolidate_sweep from $SRC/cmd_heartbeat.sh"
  echo "PASS=0 FAIL=1"; exit 1
fi
grep -q '^_HB_CONSOLIDATE_EVERY_MIN=' "$SRC/cmd_heartbeat.sh" \
  && ok "the cadence constant _HB_CONSOLIDATE_EVERY_MIN is defined in the module" \
  || bad "_HB_CONSOLIDATE_EVERY_MIN is not defined in the module"
grep -q '^_HB_CONSOLIDATE_TIMEOUT_S=' "$SRC/cmd_heartbeat.sh" \
  && ok "the timeout constant _HB_CONSOLIDATE_TIMEOUT_S is defined in the module" \
  || bad "_HB_CONSOLIDATE_TIMEOUT_S is not defined in the module"

eval "$SWEEP_SRC"
_HB_CONSOLIDATE_EVERY_MIN=360
_HB_CONSOLIDATE_TIMEOUT_S=300
STATE_DIR="$TMP/state"
SELF_BIN="$TMP/fake-5dive"
CALLS="$TMP/calls.log"

_hb_log() { :; }
registry_read() { printf '%s' "${REG:-{\"agents\":{}\}}"; }
# Stub the whole invocation chain. `timeout` and `sudo` are the two commands the
# sweep shells out through, so both are replaced by recorders — otherwise a
# "green" arm could be green because sudo refused.
timeout() { shift; "$@"; }
sudo()    { local u=""; while [ $# -gt 0 ]; do case "$1" in -u) u="$2"; shift 2;; -n|-H) shift;; *) break;; esac; done
            printf '%s\t%s\n' "$u" "$*" >> "$CALLS"
            # DIVE-3711: the stub must be able to SPEAK, because the sweep now
            # grades what the verb printed rather than how it exited. A recorder
            # that only returns an rc could not express the defect this row is
            # about (rc 0, nothing written).
            printf '%s' "${STUB_OUT:-}"; return "${STUB_RC:-0}"; }
id()      { case "${2:-}" in agent-alice|agent-bob) return 0;; *) return 1;; esac; }

REG='{"agents":{"alice":{},"bob":{}}}'
# Default: a healthy pass that actually produced something. Every arm that is
# not about failure inherits this, so "green" means "the sweep saw atoms".
_STUB_OK='{"ok":true,"data":{"atoms_written":2,"processed":1,"distiller_failed":0}}'
reset() { rm -rf "$STATE_DIR" "$CALLS"; : > "$CALLS"; STUB_RC=0; STUB_OUT="$_STUB_OK"; unset MEMORY_CONSOLIDATE MEMORY_CONSOLIDATE_EVERY_MIN; }
STUB_OUT="$_STUB_OK"; STUB_RC=0
ncalls() { wc -l < "$CALLS" | tr -d ' '; }
NOW=1000000000

echo "== scheduler fires at all =="
reset
_hb_memory_consolidate_sweep "$NOW"
check "both enrolled seats get exactly one pass on a cold start" "$(ncalls)" "2"
check "_HB_CONS_RAN counts them"                                 "$_HB_CONS_RAN" "2"
grep -q '^agent-alice	' "$CALLS" && ok "the pass runs as the SEAT's user (agent-alice), not root" \
  || bad "the pass did not run as agent-alice"
grep -q 'memory consolidate --max-sessions=1' "$CALLS" \
  && ok "the pass is bounded to ONE session per run (the cost bound)" \
  || bad "the invocation is not capped at --max-sessions=1"

echo "== the cadence gate (the runaway-cost arm) =="
_hb_memory_consolidate_sweep "$NOW"
check "a second tick inside the window invokes NOTHING further" "$(ncalls)" "2"
check "and reports the seats as not-due"                        "$_HB_CONS_SKIPPED" "2"
_hb_memory_consolidate_sweep "$((NOW + 359*60))"
check "one minute short of the cadence is still not due"        "$(ncalls)" "2"
_hb_memory_consolidate_sweep "$((NOW + 361*60))"
check "past the cadence it runs again"                          "$(ncalls)" "4"

echo "== NEGATIVE CONTROL: the gate is a clock, not a constant refusal =="
# Without this arm, "invokes nothing further" is satisfied by a sweep that is
# simply broken after its first call.
reset
MEMORY_CONSOLIDATE_EVERY_MIN=1
_hb_memory_consolidate_sweep "$NOW"
_hb_memory_consolidate_sweep "$((NOW + 120))"
check "a 1-minute cadence DOES re-fire two minutes later"       "$(ncalls)" "4"

echo "== the off switch =="
reset
MEMORY_CONSOLIDATE=off
_hb_memory_consolidate_sweep "$NOW"
check "MEMORY_CONSOLIDATE=off invokes nothing"                  "$(ncalls)" "0"
check "and leaves no stamp behind to skew the next run"         "$(ls "$STATE_DIR/memory-consolidate" 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "== stamp BEFORE the run, so a wedged pass cannot be re-entered =="
reset
STUB_RC=1; STUB_OUT=""
_hb_memory_consolidate_sweep "$NOW"
check "a FAILING pass is counted, not swallowed"                "$_HB_CONS_FAILED" "2"
check "and still stamped (a failure must not re-run every 5m)"  "$(ls "$STATE_DIR/memory-consolidate" 2>/dev/null | wc -l | tr -d ' ')" "2"
STUB_RC=0; STUB_OUT="$_STUB_OK"
_hb_memory_consolidate_sweep "$NOW"
check "so the very next tick invokes nothing"                   "$(ncalls)" "2"

echo "== DIVE-3711: the success bucket must be able to produce a negative =="
# THE regression arm for this row. A pass that exits ZERO having written nothing
# — because the distiller could not answer — must not land in the bucket the log
# calls "distilled". rc 0 is deliberately kept here: if this arm passes only
# because the verb now also exits non-zero, the sweep is still counting attempts.
reset
STUB_OUT='{"ok":false,"data":{"atoms_written":0,"processed":1,"distiller_failed":1}}'
STUB_RC=0
_hb_memory_consolidate_sweep "$NOW"
check "a zero-atom distiller failure is NOT counted as distilled" "$_HB_CONS_RAN"    "0"
check "it lands in its own third bucket"                          "$_HB_CONS_DFAIL"  "2"
check "and contributes no atoms to the headline number"           "$_HB_CONS_ATOMS"  "0"
check "and is not conflated with could-not-invoke"                "$_HB_CONS_FAILED" "0"
reset
STUB_OUT='{"ok":false,"data":{"atoms_written":0,"processed":1,"distiller_failed":1}}'
STUB_RC=6
_hb_memory_consolidate_sweep "$NOW"
check "same verdict when the verb ALSO exits non-zero"            "$_HB_CONS_DFAIL"  "2"

echo "== NEGATIVE CONTROL: a producing pass is still counted =="
# Without this, "not counted as distilled" is satisfied by a sweep that counts
# nothing at all.
reset
STUB_OUT='{"ok":true,"data":{"atoms_written":3,"processed":1,"distiller_failed":0}}'
_hb_memory_consolidate_sweep "$NOW"
check "a pass that wrote atoms IS counted distilled"              "$_HB_CONS_RAN"    "2"
check "and its atoms are summed across seats"                     "$_HB_CONS_ATOMS"  "6"
check "with both failure buckets empty"                           "$((_HB_CONS_DFAIL + _HB_CONS_FAILED))" "0"

echo "== 'ran, nothing to distil' is not 'distilled' =="
reset
STUB_OUT='{"ok":true,"data":{"atoms_written":0,"processed":0,"distiller_failed":0}}'
_hb_memory_consolidate_sweep "$NOW"
check "an empty backlog does not inflate the distilled count"     "$_HB_CONS_RAN"    "0"
check "it is its own bucket"                                      "$_HB_CONS_IDLE"   "2"
check "and it is NOT a failure either"                            "$((_HB_CONS_DFAIL + _HB_CONS_FAILED))" "0"

echo "== TWO envelopes on the stream still grade as one result =="
# On a non-zero exit the CLI's EXIT-trap backstop appends its own
# {"ok":false,"error":{...}} after the real result. A naive `jq -r .data.x` over
# both prints "0\nnull", fails the numeric test, and files every distiller
# failure under could-not-run — this row's defect, moved one bucket left.
reset
STUB_OUT='{"ok":false,"data":{"atoms_written":0,"processed":1,"distiller_failed":1}}
{"ok":false,"error":{"code":6,"class":"generic","message":"exited 6 without reporting a reason"}}'
STUB_RC=6
_hb_memory_consolidate_sweep "$NOW"
check "a trailing error envelope does not hide the real result" "$_HB_CONS_DFAIL"  "2"
check "and it is not misfiled as could-not-run"                 "$_HB_CONS_FAILED" "0"

echo "== unparseable output is a failure, never a silent success =="
reset
STUB_OUT='not json'; STUB_RC=0
_hb_memory_consolidate_sweep "$NOW"
check "garbage on stdout with rc 0 counts as could-not-run"       "$_HB_CONS_FAILED" "2"
check "and never as distilled"                                    "$_HB_CONS_RAN"    "0"

echo "== the seat's own auth env reaches the distiller =="
# `sudo -H` resets the environment, so the seat's CLAUDE_CODE_OAUTH_TOKEN never
# reached the CLI and every call answered "Not logged in" — the cause behind the
# zero atoms. Asserted on the invocation, which is all this harness can see.
reset
_hb_memory_consolidate_sweep "$NOW"
grep -q 'alice-auth.env' "$CALLS" \
  && ok "the invocation carries the SEAT's own auth env path" \
  || bad "the invocation does not reference <seat>-auth.env — sudo -H drops the token"
grep -q -- '--json' "$CALLS" \
  && ok "the pass is invoked with --json (the counter reads output, not rc)" \
  || bad "the pass is not invoked with --json"
case "$(cat "$CALLS")" in
  *CLAUDE_CODE_OAUTH_TOKEN*) bad "the token is passed as an ARGUMENT — visible in ps to every user" ;;
  *) ok "and no secret is placed on the command line" ;;
esac

echo "== the log line reports the ARTIFACT, not the attempt =="
LOGLINE=$(grep -n 'memory-consolidate\]' "$SRC/cmd_heartbeat.sh" | grep _hb_log)
case "$LOGLINE" in
  *_HB_CONS_ATOMS*) ok "the tick summary names the atom count" ;;
  *) bad "the tick summary still reports only attempt counts" ;;
esac
case "$LOGLINE" in
  *_HB_CONS_DFAIL*) ok "and surfaces the distiller-failed bucket" ;;
  *) bad "the distiller-failed bucket never reaches the log" ;;
esac

echo "== a seat with no unix user is skipped, not run as root =="
reset
REG='{"agents":{"alice":{},"ghost":{}}}'
_hb_memory_consolidate_sweep "$NOW"
check "only the resolvable seat runs"                           "$(ncalls)" "1"
grep -q 'ghost' "$CALLS" && bad "the unresolvable seat was invoked anyway" \
  || ok "the unresolvable seat was skipped"
REG='{"agents":{"alice":{},"bob":{}}}'

echo "== a broken registry is survivable =="
reset
REG='not json'
_hb_memory_consolidate_sweep "$NOW"; rc=$?
check "an unparseable registry returns 0 (never aborts the tick)" "$rc" "0"
check "and invokes nothing"                                       "$(ncalls)" "0"
REG='{"agents":{"alice":{},"bob":{}}}'

echo "== the tick actually CALLS the sweep (the whole point) =="
grep -q '_hb_memory_consolidate_sweep "\$now"' "$SRC/cmd_heartbeat.sh" \
  && ok "cmd_heartbeat_tick invokes _hb_memory_consolidate_sweep" \
  || bad "the sweep exists but the tick never calls it — a verb with no scheduler"
# NOT `awk ... | grep -q`. This harness runs under `set -o pipefail` (corpus
# convention) and `grep -q` exits on its FIRST match, SIGPIPEing awk — so the
# pipeline reports 141 and the arm reads FALSE on code that is present and
# correct. Cost the first time: two red arms accusing correct code. Buffer the
# text, then match it.
TICK_BODY=$(awk '/^cmd_heartbeat_tick\(\) /,/^\}/' "$SRC/cmd_heartbeat.sh")
case "$TICK_BODY" in
  *_hb_memory_consolidate_sweep*) ok "and the call is INSIDE cmd_heartbeat_tick, not merely in the file" ;;
  *) bad "the call is not inside cmd_heartbeat_tick" ;;
esac
case "$TICK_BODY" in
  *"_hb_memory_consolidate_sweep \"\$now\" || _hb_log"*) ok "the call carries the non-fatal isolation contract every sweep owes" ;;
  *) bad "the sweep call is not isolated — a failure could abort the wake loop" ;;
esac

echo "== the instruction surfaces describe the POST-pipeline workflow =="
# lodar's acceptance: "a reviewer can read each surface and see it describes the
# post-pipeline workflow". Asserted mechanically so the text cannot silently
# revert to the pre-pipeline wording.
surf() {
  if grep -q "memory consolidate" "$1"; then ok "$2 names the pipeline"; else bad "$2 does not name the pipeline"; fi
}
surf "$SRC/cmd_heartbeat.sh"     "the knowledge-task nudge (cmd_heartbeat.sh)"
surf "$SRC/cmd_agent_create.sh"  "the seeded per-seat MEMORY.md (cmd_agent_create.sh)"
surf "$SRC/task/crud.sh"         "the filing-cap guidance (task/crud.sh)"
surf "telegram-agent-CLAUDE.md"  "the shipped per-seat CLAUDE.md template"
# ...and STILL tell agents to hand-compile judgement. lodar: "It must NOT tell
# agents to stop compiling." A surface that only announced the pipeline would
# pass the arm above and fail the intent.
for f in "$SRC/cmd_heartbeat.sh" "$SRC/cmd_agent_create.sh" "telegram-agent-CLAUDE.md"; do
  grep -qi "compile" "$f" && ok "$(basename "$f") still instructs hand-compiling" \
    || bad "$(basename "$f") dropped the hand-compile instruction"
done
grep -q 'MEMORY_CONSOLIDATE=off' "$SRC/cmd_memory.sh" \
  && ok "the help states the off switch" || bad "the help does not state the off switch"
grep -qE '\$0\.(244|081)' "$SRC/cmd_memory.sh" \
  && ok "the help states the MEASURED per-session cost" || bad "the help does not state a measured cost"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
