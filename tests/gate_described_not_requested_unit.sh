#!/usr/bin/env bash
# DIVE-3307 isolated unit harness: `_GATE_PUSH_NOT_INERT_RX` reads SUBJECT MATTER,
# so a push-for-review ask that merely DESCRIBES a merge/deploy is classified as a
# request to perform one — and the DIVE-3117 lead route is un-suppressed back onto
# the verifier, the one agent structurally unable to answer it.
#
# THE DEFECT (measured against origin/main 289b35d, DIVE-3302's live gate ask):
#   'approve delegated push for review of branch dive-3302-core-budget —
#    coverage-neutral perf fix reclaiming CPU in identity_stub_guard toward the
#    core-tier overage freezing all merges.'
# The trigger word is `merges`, inside "freezing all merges" — a description of what
# is BLOCKED. dev is not requesting a merge; a delegated push cannot merge anything.
# Drop that one clause and the same ask routes to the LEAD.
#
# WHY IT IS THE SHARP KIND (DIVE-2089 shape, recursive): the better you describe the
# merge freeze you are trying to fix, the more reliably the gate to fix it misroutes.
# The most accurate ask is the most likely to be blocked, and it fires exactly when
# urgency is highest, because that is when people explain the blockage in the ask.
#
# THE FIX IS A DISCRIMINATOR, NOT A SHORTER LIST. `_GATE_PUSH_NOT_INERT_RX` keeps
# every term it had: it exists so a push ask that genuinely ALSO asks to merge or
# deploy keeps its routing and its DIVE-2629 tier-2 subject floor. What is added is
# `_GATE_ACTION_DESCRIBED_RX` — the bounded set of frames in which one of those
# terms is unambiguously a NOUN naming a blocked state, never a requested verb.
# Those spans are redacted before the not-inert test, exactly as DIVE-2629 redacts
# branch identifiers before the tier floor, and for the same reason: the ask must be
# graded on the action it AUTHORISES.
#
# BOTH AXES MOVE TOGETHER, BY CONSTRUCTION. `_gate_push_for_review_hit` is shared by
# DIVE-3117's routing floor (need.sh cmd_task_need) and DIVE-2629's tier floor
# (_gate_tier2_floor_hit / _gate_tier2_floor_term), and need.sh:2696 requires the two
# to agree about what an inert push is. T20-T22 grade the tier axis for that reason —
# a routing-only assertion would be satisfied by a fix that split them.
#
# MUTATION GRADE (all run, all go red where stated):
#   M1  remove the _gate_redact_described_actions call from _gate_push_for_review_hit
#       -> T1/T2/T3 red (the fix is gone).
#   M2  redact on the bare trigger words instead of the described FRAMES (i.e. delete
#       terms from _GATE_PUSH_NOT_INERT_RX, the fix the ticket forbids)
#       -> T10/T11/T12 red (a genuine "then merge to main" would go inert).
#   M3  drop the leading word boundary from _GATE_ACTION_DESCRIBED_RX
#       -> T13 red ("delegated release of ..." contains "gated release" and would be
#       eaten mid-word, taking a real release request with it).
#   M4  apply the redaction to the whole text rather than only to the not-inert test
#       -> T14 red (_GATE_PUSH_FOR_REVIEW_RX must still see the original ask).
#   M5  omit the tier-axis half -> T20 red (the two axes disagree about inertness).
#
# Run: bash tests/gate_described_not_requested_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src

SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154  # rc is assigned inside the trap body
trap 'rc=$?; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - gate_described_not_requested_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT

# The predicate lives in src/task/need.sh, which is sourced by cmd_task.sh. Source the
# same set gate_floor_branch_name_unit.sh does so the functions under test are the
# SHIPPED ones and not a restatement of them.
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n     %s\n' "$1" "${2-}"; }

# inert <ask> -> prints "inert" or "not-inert". This is the single predicate both the
# routing floor and the tier floor consult; asserting on it directly is what lets the
# mutation grades above be checked without standing up a DB fixture.
inert() { if _gate_push_for_review_hit "$1"; then printf 'inert'; else printf 'not-inert'; fi; }

exp() { # exp <expected> <ask> <label>
  local got; got="$(inert "$2")"
  [[ "$got" == "$1" ]] && ok "$3" || bad "$3" "expected=$1 got=$got ask=<<$2>>"
}

echo "== T1-T3: the live DIVE-3302 ask, and the described-merge class =="

# T1 IS THE LIVE INSTANCE, byte-for-byte off DIVE-3302's filed gate. Before this
# change it returned not-inert and the gate went to the verifier.
exp inert \
  'approve delegated push for review of branch dive-3302-core-budget — coverage-neutral perf fix reclaiming CPU in identity_stub_guard toward the core-tier overage freezing all merges.' \
  'T1 the live DIVE-3302 ask is INERT (was routed to the verifier on "merges")'

exp inert \
  'approve delegated push for review of branch dive-3307-x — unblocks the merge freeze' \
  'T2 "merge freeze" as a state noun is a DESCRIPTION, not a request'

exp inert \
  'approve delegated push for review of branch dive-3307-x while all merges are frozen' \
  'T3 "merges are frozen" is a DESCRIPTION, not a request'

echo "== T4-T9: the rest of the described frames =="

exp inert 'approve delegated push for review of branch dive-3307-x — blocking deploys since 02:00' \
  'T4 "blocking deploys" is described'
exp inert 'approve delegated push for review of branch dive-3307-x, held releases pending' \
  'T5 "held releases" is described'
exp inert 'approve delegated push for review of branch dive-3307-x during the deploy window' \
  'T6 "deploy window" is a state noun'
exp inert 'approve delegated push for review of branch dive-3307-x — the release queue is stalled' \
  'T7 "release queue" is a state noun'
exp inert 'approve delegated push for review of branch dive-3307-x; freeze on all merges still on' \
  'T8 "freeze on all merges" (preposition between) is described'
exp inert 'approve delegated push for review of branch dive-3307-x — rollouts are paused' \
  'T9 "rollouts are paused" is described'

echo "== T10-T15: NEGATIVE CONTROLS — a REQUESTED action still kills the exemption =="

# T10-T12 are the arms that make this file more than "assert the false positive is
# gone". They fail against the non-fix the ticket forbids (deleting terms from
# _GATE_PUSH_NOT_INERT_RX) and against redacting the bare trigger words.
exp not-inert 'push branch dive-3117-pfr-lead-route for review, then merge to main' \
  'T10 a requested merge to main is NOT inert (the DIVE-3117 negative control)'
exp not-inert 'approve delegated push for review of branch dive-3307-x and deploy it' \
  'T11 a requested deploy is NOT inert'
exp not-inert 'approve delegated push for review of branch dive-3307-x then cut the release' \
  'T12 a requested release is NOT inert'
# T13 is M3: without a leading word boundary, "delegated" ends in "gated" and
# "gated release" would be redacted as a described frame — eating a real request.
exp not-inert 'approve delegated release of branch dive-3307-x to production' \
  'T13 "delegated release" is not a described frame (boundary holds mid-word)'
# T14 is M4: the push-for-review RX must still read the ORIGINAL ask. If redaction
# were applied to the whole text this would stop being recognised as a push at all
# and would fall out of the class entirely (returning not-inert for the wrong reason).
exp inert 'approve delegated push for review of branch dive-3307-x — merge freeze in effect' \
  'T14 redaction is scoped to the not-inert test, not to class recognition'
exp not-inert 'approve delegated push of branch dive-3307-x to 5dive-frontend main' \
  'T15 the DIVE-1940 destination clause still fires (a repo name in between)'

echo "== T16-T19: a described clause NEXT TO a requested one keeps the request =="

# The discriminator must not be a whole-ask escape hatch: one described clause cannot
# launder a request sitting beside it. This is the fail-closed direction, deliberately.
exp not-inert 'approve delegated push for review of branch dive-3307-x — merge freeze is lifted, so merge it to main after' \
  'T16 a described clause does not launder a requested merge beside it'
exp not-inert 'approve delegated push for review of branch dive-3307-x while deploys are blocked, then deploy the fix' \
  'T17 described deploys + a requested deploy stays NOT inert'
exp inert 'approve delegated push for review of branch dive-3307-core-budget' \
  'T18 a bare inert push is unchanged'
exp not-inert 'merge branch dive-3307-x to main' \
  'T19 a non-push ask is not in the class at all'

echo "== T20-T22: the TIER axis inherits the same verdict (need.sh:2696) =="

# DIVE-2629's floor redacts branch identifiers ONLY for an ask the same predicate calls
# inert. Before this change the DIVE-3302-shaped ask was not inert, so a branch name
# carrying a floor term still forced tier 2 — the two axes disagreeing about what an
# inert push is, which need.sh:2696 forbids. M5 reds here.
#
# `_gate_tier2_floor_term` is an rc-BEARING function (need.sh:2075) — it returns 1
# when nothing floored — and header.sh puts this shell under `set -e`. Every
# production caller absorbs the rc with `|| _t=""`; a harness that calls it bare
# dies mid-run and the DIVE-2190 trap above is the only thing that says so.
if _gate_tier2_floor_hit 'approve delegated push for review of branch dive-3307-token-sweep — freezing all merges'; then
  _t20_term=$(_gate_tier2_floor_term 'approve delegated push for review of branch dive-3307-token-sweep — freezing all merges' 2>/dev/null) || _t20_term=""
  bad 'T20 a described-merge push floors on its BRANCH NAME (tier axis follows routing axis)' \
      "floored on term='$_t20_term'"
else
  ok 'T20 a described-merge push no longer floors on its BRANCH NAME (tier axis follows routing axis)'
fi

# T21: the floor is SCOPED, not removed — a spend named in the PROSE still floors,
# described merge clause or not. This is the arm that fails a wholesale exemption.
if _gate_tier2_floor_hit 'approve delegated push for review of branch dive-3307-x and the $900 runner spend — freezing all merges'; then
  ok 'T21 a spend in the prose still floors to tier 2 (scoped, not exempted)'
else
  bad 'T21 a spend in the prose still floors to tier 2' 'did not floor'
fi

# T22: DIVE-2629's mirrored-helper invariant — _gate_tier2_floor_term must never
# report a term the floor itself did not use.
_t22_ask='approve delegated push for review of branch dive-3307-token-sweep — freezing all merges'
_t22_term=$(_gate_tier2_floor_term "$_t22_ask" 2>/dev/null) || _t22_term=""
if _gate_tier2_floor_hit "$_t22_ask"; then _t22_hit=1; else _t22_hit=0; fi
if [[ "$_t22_hit" == "0" && -z "$_t22_term" ]] || [[ "$_t22_hit" == "1" && -n "$_t22_term" ]]; then
  ok 'T22 _gate_tier2_floor_term agrees with the floor it reports for'
else
  bad 'T22 _gate_tier2_floor_term agrees with the floor it reports for' "hit=$_t22_hit term='$_t22_term'"
fi

echo "-----"
echo "gate_described_not_requested_unit: $PASS passed, $FAIL failed"
SUMMARY_PRINTED=1
[[ "$FAIL" == "0" ]]
