#!/usr/bin/env bash
# DIVE-2125 — version-uniqueness went RED on every bundle-changing merge, because the
# detector and the performer are triggered by the same push and race each other.
#
# MEASURED TWICE, on the only two bundle-changing merges since DIVE-2118 shipped:
#   186b0e3 (#226): 21:39:15 push -> 21:39:22 assignment commit -> 21:39:33 the
#                   version-uniqueness run on the MERGE COMMIT fails -> 21:39:40 the
#                   dispatched run on the assignment commit passes.
#   6fd082e (#224): same sequence, same outcome.
# In both, main self-healed in ~19s and ended green — but the merge commit keeps a
# permanently red run, because that sha is only ever checked once.
#
# WHY THAT IS NOT COSMETIC. version-uniqueness is the detector that CAUGHT the
# original DIVE-2118 defect. Red on every healthy merge means a reader can no longer
# tell "the assigner repairs this in ten seconds" from "a real collision needs a
# human" without opening the run and checking whether an assignment commit followed.
# The check is not wrong; it is RIGHT ABOUT A TRANSIENT STATE, and being right about a
# transient state on every healthy merge is exactly how a detector stops being read.
# DIVE-2118 exists partly because main sat red and a human had to notice.
#
# THE FIX IS NOT "IGNORE THE COLLISION". A tolerance with no proof that the repair
# actually happened silently recreates DIVE-2118 — main unassigned, nothing red, boxes
# quietly stuck on an old bundle. So the tolerance is bounded and self-proving: when
# the collision is exactly the shape version-assign repairs, WAIT for the repair and
# then verify uniqueness AGAINST THE REPAIRED TIP. If the repair does not arrive, fail
# loudly and say the assigner did not perform.
#
# The "is this the assignable shape?" question is answered by running version-assign.sh
# ITSELF (dry, no --apply) rather than by re-deriving the predicate here. Two copies of
# a predicate drift; the copy that drifts is the one that decides whether to stay
# quiet. Same discipline as the gap#2/stranded predicate sharing in DIVE-2122.
#
# Usage: version-uniqueness-gate.sh <new-ref> <base-ref>
# Exit 0 = no collision, or a transient one PROVEN repaired. Exit 1 = collision that
#          is not the assignable shape, is undeterminable, or was never repaired.
set -uo pipefail

FIVE_UNIQ_ASSIGN_WAIT="${FIVE_UNIQ_ASSIGN_WAIT:-120}"   # ceiling; observed repair ~11s
FIVE_UNIQ_POLL_SECS="${FIVE_UNIQ_POLL_SECS:-10}"
_UNIQ_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Seams. Overridden by tests so the wait loop can be exercised without a network, a
# clock, or a second workflow — the loop is the part most likely to be wrong, so it
# must be the part that is actually graded.
_uniq_scan()         { bash "$_UNIQ_HERE/version-uniqueness-scan.sh" "$1" "$2" >/dev/null 2>&1; }
_uniq_assign_shape() { bash "$_UNIQ_HERE/version-assign.sh" "$1" "$2" 2>&1; }
_uniq_current_main() { git fetch -q origin main 2>/dev/null; git rev-parse FETCH_HEAD 2>/dev/null; }

uniq_gate() {
  local new="$1" base="$2" out rc tip waited=0

  if _uniq_scan "$new" "$base"; then
    echo "version-uniqueness: no new collision in ${base:0:12}..${new:0:12}."
    return 0
  fi

  out=$(_uniq_assign_shape "$new" "$base"); rc=$?

  # An UNDETERMINED shape probe must never buy silence. We know there is a collision;
  # what we do not know is whether anything is coming to fix it, and "unknown" is not
  # "it will be handled" (DIVE-2120's bound message, same rule).
  if (( rc == 2 )); then
    echo "version-uniqueness: COLLISION at ${new:0:12}, and the assignable-shape probe was UNDETERMINED — refusing to wait on a repair that may never have been owed. Treating it as a real collision." >&2
    printf '%s\n' "$out" >&2
    return 1
  fi

  if ! grep -q 'ASSIGNMENT OWED' <<<"$out"; then
    echo "version-uniqueness: COLLISION at ${new:0:12} that version-assign will NOT repair — this is a genuine finding and needs a human. The assignable shape is 'bundle moved AND FIVE_VERSION did not'; this is not that." >&2
    printf '%s\n' "$out" >&2
    return 1
  fi

  echo "version-uniqueness: the collision at ${new:0:12} IS the assignable shape (bundle moved, FIVE_VERSION did not) — version-assign should repair it. Waiting up to ${FIVE_UNIQ_ASSIGN_WAIT}s and then re-checking against main's repaired tip."
  # The bound counts ATTEMPTS, not accumulated sleep. Accumulating the poll interval
  # looks equivalent and is not: at FIVE_UNIQ_POLL_SECS=0 the accumulator never moves
  # and the loop never ends — a CI job that HANGS FOREVER instead of failing, which is
  # the worst outcome for a check whose whole purpose is to be readable. Found by this
  # ticket's own harness, which hung instead of failing; the boundedness arm now grades
  # a counter so a regression fails fast rather than never returning.
  local poll="$FIVE_UNIQ_POLL_SECS" attempts i
  [[ "$poll" =~ ^[0-9]+$ ]] || poll=10
  (( poll > 0 )) || poll=1
  attempts=$(( (FIVE_UNIQ_ASSIGN_WAIT + poll - 1) / poll ))
  (( attempts > 0 )) || attempts=1
  for (( i=1; i<=attempts; i++ )); do
    sleep "$FIVE_UNIQ_POLL_SECS"
    waited=$(( i * poll ))
    tip=$(_uniq_current_main)
    if [[ -z "$tip" || "$tip" == "$new" ]]; then
      echo "  ${waited}s: main is still at ${new:0:12} — no assignment commit yet."
      continue
    fi
    if _uniq_scan "$tip" "$base"; then
      # Say exactly what was and was not measured. Green here does NOT mean the merge
      # commit was clean — it means the transient was repaired and the REPAIRED tip is
      # unique. Reporting it as though the collision never happened would be the same
      # class of lie this ticket is about.
      echo "version-uniqueness: RESOLVED. ${new:0:12} DID collide — that was real, not a false alarm — and version-assign repaired it at ${tip:0:12} within ${waited}s. Uniqueness is verified against the REPAIRED TIP, not against ${new:0:12}."
      return 0
    fi
    echo "  ${waited}s: main moved to ${tip:0:12} but the collision is still there."
  done

  echo "version-uniqueness: COLLISION at ${new:0:12} was the assignable shape, but NO repair landed within ${FIVE_UNIQ_ASSIGN_WAIT}s. main is unassigned right now: the shared-checkout updater is version-triggered (DIVE-2065), so every box on the previous version is silently missing these fixes. Check the version-assign run for this push; bump by hand with scripts/version-assign.sh HEAD <prev> --apply if it is broken." >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  uniq_gate "${1:?usage: version-uniqueness-gate.sh <new-ref> <base-ref>}" \
            "${2:?usage: version-uniqueness-gate.sh <new-ref> <base-ref>}"
  exit $?
fi
