#!/usr/bin/env bash
# DIVE-2125 harness for scripts/version-uniqueness-gate.sh.
#
# The gate exists because version-uniqueness and version-assign are triggered by the
# SAME push and race: measured on both bundle-changing merges since DIVE-2118 shipped
# (186b0e3 and 6fd082e), the run on the merge commit failed ~18s in while the assigner
# was still computing the repair, and the dispatched run on the assignment commit
# passed ~7s later. Main self-heals; the merge commit keeps a permanently red run.
#
# The danger in fixing it is over-correcting into silence: a tolerance that does not
# PROVE the repair happened recreates DIVE-2118 with no red at all, which is strictly
# worse. So the arms below weight that direction — four of the seven pin a FAILURE.
#
# The wait loop is stubbed at its seams (_uniq_scan / _uniq_assign_shape /
# _uniq_current_main) rather than driven against a live repo: the loop is the part
# most likely to be wrong, so it has to be the part that is actually exercised, and a
# network-and-clock test would be too slow and flaky to run every push.
# Run: bash tests/version_uniqueness_gate_unit.sh  (no root, no network)
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source scripts/version-uniqueness-gate.sh          # sourced => functions only
FIVE_UNIQ_POLL_SECS=0                              # no real sleeping in tests
FIVE_UNIQ_ASSIGN_WAIT=3                            # 3 polls, so "bounded" is gradeable

P=0; F=0
ok(){ P=$((P+1)); echo "ok   - $1"; }
no(){ F=$((F+1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "   $2"; }

# --- seams, redefined per arm ------------------------------------------------
# STUB STATE LIVES IN FILES, NOT VARIABLES. uniq_gate is called inside $( ), which is
# a SUBSHELL — every variable the stubs mutate there is discarded on return. The first
# cut used shell vars: the tip sequence never advanced (so the "repaired" arm could
# never pass) and the poll counter read 0 forever, which made the boundedness and
# no-wait assertions pass VACUOUSLY. A counter that is always 0 satisfies "<= 3"
# without measuring anything.
SCAN_CLEAN_FOR=""      # refs (space-separated) the scan considers clean
SHAPE_OUT="";  SHAPE_RC=0
TIPS_STR=""
STUBD="$(mktemp -d /tmp/uniq-gate-stub.XXXXXX)"; trap 'rm -rf "$STUBD"' EXIT
POLL_LOG="$STUBD/polls"; TIP_IDX="$STUBD/idx"
reset_stub() { : >"$POLL_LOG"; echo 0 >"$TIP_IDX"; }
polls()      { wc -l <"$POLL_LOG" | tr -d ' '; }
_uniq_scan()         { [[ " $SCAN_CLEAN_FOR " == *" $1 "* ]]; }
_uniq_assign_shape() { printf '%s' "$SHAPE_OUT"; return $SHAPE_RC; }
_uniq_current_main() {
  echo x >>"$POLL_LOG"
  local i; i=$(cat "$TIP_IDX" 2>/dev/null || echo 0)
  local -a arr=($TIPS_STR)
  local v="${arr[$i]:-${arr[${#arr[@]}-1]:-}}"
  echo $(( i + 1 )) >"$TIP_IDX"
  printf '%s' "$v"
}
OWED='version-assign: ASSIGNMENT OWED — bundle changed (aaa -> bbb) with FIVE_VERSION still 0.16.22.'
NOTOWED='version-assign: no assignment needed — the bundle is unchanged since BASE.'

# --- 1. no collision at all: clean through, and it must NOT wait --------------
SCAN_CLEAN_FOR="mergesha"; TIPS_STR="mergesha"; reset_stub
out=$(uniq_gate mergesha basesha 2>&1); rc=$?
(( rc == 0 )) && ok "1 a clean scan passes" || no "1 clean must pass" "rc=$rc $out"
(( $(polls) == 0 )) && ok "1 ...and does not wait on the assigner at all (no cost on the ordinary push)" \
                 || no "1 must not poll when clean" "polls=$(polls)"

# --- 2. THE FIX: the assignable transient, repaired -> passes -----------------
SCAN_CLEAN_FOR="assignsha"; SHAPE_OUT="$OWED"; SHAPE_RC=0
TIPS_STR="mergesha assignsha"; reset_stub
out=$(uniq_gate mergesha basesha 2>&1); rc=$?
(( rc == 0 )) && ok "2 an assignable collision that version-assign repairs no longer fails the merge commit" \
             || no "2 repaired transient must pass" "rc=$rc $out"
grep -q 'DID collide' <<<"$out" \
  && ok "2 ...and the pass states the collision WAS REAL, not a false alarm" \
  || no "2 must not report the collision as never having happened" "$out"
grep -q 'REPAIRED TIP' <<<"$out" \
  && ok "2 ...and names WHICH sha it verified, so green is not read as 'the merge commit was clean'" \
  || no "2 must name the subject it verified" "$out"

# --- 3. THE OVER-CORRECTION GUARD: assignable shape, repair NEVER lands -------
# This is the arm that keeps the fix from silently recreating DIVE-2118.
SCAN_CLEAN_FOR=""; SHAPE_OUT="$OWED"; SHAPE_RC=0
TIPS_STR="mergesha"; reset_stub
out=$(uniq_gate mergesha basesha 2>&1); rc=$?
(( rc == 1 )) && ok "3 an assignable collision that is NEVER repaired still FAILS (the tolerance is not silence)" \
             || no "3 unrepaired must fail" "rc=$rc $out"
grep -q 'main is unassigned right now' <<<"$out" \
  && ok "3 ...and says main is unassigned, naming the DIVE-2065 consequence rather than just 'collision'" \
  || no "3 failure must name the consequence" "$out"
(( $(polls) >= 1 && $(polls) <= 3 )) && ok "3 ...and the wait is BOUNDED (it gave up after $(polls) polls, it did not hang the job)" \
                 || no "3 wait must be bounded" "polls=$(polls)"

# --- 4. a GENUINE collision (not the assignable shape) still fails immediately -
SCAN_CLEAN_FOR=""; SHAPE_OUT="$NOTOWED"; SHAPE_RC=0
TIPS_STR="assignsha"; reset_stub
out=$(uniq_gate mergesha basesha 2>&1); rc=$?
(( rc == 1 )) && ok "4 a collision version-assign will NOT repair still fails — the detector keeps its job" \
             || no "4 genuine collision must fail" "rc=$rc $out"
(( $(polls) == 0 )) && ok "4 ...immediately, without burning the wait window on a repair nobody owes" \
                 || no "4 must not wait on a non-assignable collision" "polls=$(polls)"

# --- 5. UNDETERMINED shape probe must NOT buy silence ------------------------
# We know there IS a collision; what is unknown is whether a repair is coming. Unknown
# is not "it will be handled" — same rule as DIVE-2120's bound message.
SCAN_CLEAN_FOR=""; SHAPE_OUT='version-assign: UNDETERMINED — could not read FIVE_VERSION.'; SHAPE_RC=2
TIPS_STR="assignsha"; reset_stub
out=$(uniq_gate mergesha basesha 2>&1); rc=$?
(( rc == 1 )) && grep -q 'UNDETERMINED' <<<"$out" \
  && ok "5 an UNDETERMINED shape probe is treated as a real collision, never as a pending repair" \
  || no "5 undetermined must not be tolerated" "rc=$rc $out"

# --- 6. main moves but the collision persists -> still fails -----------------
# The repair must be PROVEN by re-scanning, not inferred from "the tip changed".
SCAN_CLEAN_FOR="somethingelse"; SHAPE_OUT="$OWED"; SHAPE_RC=0
TIPS_STR="othersha othersha othersha"; reset_stub
out=$(uniq_gate mergesha basesha 2>&1); rc=$?
(( rc == 1 )) && ok "6 main moving is NOT proof of repair — the new tip is re-scanned and still fails if it collides" \
             || no "6 tip movement must not be taken as repair" "rc=$rc $out"

echo; echo "DIVE-2125 version-uniqueness-gate: passed: $P  failed: $F"
[ "$F" -eq 0 ]
