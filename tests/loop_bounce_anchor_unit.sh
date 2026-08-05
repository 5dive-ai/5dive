#!/usr/bin/env bash
# TIER: core — pure-function harness, no DB, no network, sub-second.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# DIVE-2572 — the loop bounce/advance decision is read from the LEADING TOKEN.
#
# It used to be five BARE SUBSTRING tests over the whole free-text answer, so any
# answer containing "better"/"reject"/"deny"/"denied"/"declin" ANYWHERE was
# classified as a bounce whatever it decided.
#
# EVERY SPECIMEN IN SECTION B IS A REAL ANSWER OFF THE LIVE BOARD, quoted rather
# than invented, because the row asked for a measurement rather than a hunch and
# invented fixtures would grade the fix against my own imagination. Measured
# 2026-08-05: 268 answered gates, 14 carry a trigger substring, and of the human
# decisions on loop-shaped rows FIVE OF FIVE would have been misclassified — all
# five APPROVE.
#
# The failure is SYSTEMATIC, which is what makes it worth a guard: an approval
# that resolves a previous bounce naturally CITES that bounce ("see my reject
# feedback"), and a decision between options names the one it turned down ("B
# rejected"). The most careful reviewer is the most likely to be misread.
#
# Run: bash tests/loop_bounce_anchor_unit.sh
set -uo pipefail
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

# shellcheck source=/dev/null
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh \
         cmd_push.sh cmd_org.sh cmd_project.sh; do
  source "src/$f"
done
set +e

P=0; F=0
ok(){ P=$((P+1)); echo "ok   - $1"; }
no(){ F=$((F+1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "   ${2:0:240}"; }

# bounce <value> -> prints BOUNCE|ADVANCE, and AMBIG when the advisory fired.
bounce() {
  local v; v=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  if _loop_answer_is_bounce "$v"; then printf 'BOUNCE'
  else printf 'ADVANCE%s' "$( (( ${_LOOP_BOUNCE_AMBIGUOUS:-0} )) && printf '+AMBIG' )"; fi
}

echo "== A. real BOUNCES still bounce (the guard must not go vacuous) =="
for v in "denied" "reject — the error path is untested" "Rejected: needs a rebase first" \
         "deny" "declined, see feedback" "better: rework the guard first" "DENIED" "Do better" "Do better ↩"; do
  r=$(bounce "$v")
  [ "$r" = "BOUNCE" ] && ok "A: '${v:0:34}' -> BOUNCE" || no "A: '${v:0:34}' should BOUNCE" "got $r"
done

echo "== B. the five REAL board answers that the old matcher misread =="
# Each is an APPROVE/ADVANCE whose prose contains a trigger word. Quoted from the
# live task store (idents named so the claim is checkable, not asserted).
b_2552='approve — cleared at my level (team-decidable). down:malformed-caller, uppercase is rejected, empty gives unknown:no-caller'
b_2565='approve — push for review only, not a merge. th-memory reuses the existing two-phase deny-by-default flow rather than minting a second'
b_2596='approve — push-for-review on the feature branch only, NOT a merge approval. return VERDICT=absent rc=1. See my reject feedback on this task for the fix.'
b_cncl9='Clear-now (main re-gate): security core VERIFIED-GOOD. the rebase-onto-main I filed in the reject (branch predates DIVE-1492)'
b_1572='A — render inline tier<2 clear buttons in /inbox. B rejected: its stale-nonce story does not hold'
for pair in "DIVE-2552:$b_2552" "DIVE-2565:$b_2565" "DIVE-2596:$b_2596" "CNCL-9:$b_cncl9" "DIVE-1572:$b_1572"; do
  id="${pair%%:*}"; v="${pair#*:}"
  r=$(bounce "$v")
  [ "$r" = "ADVANCE+AMBIG" ] \
    && ok "B: $id ADVANCES (and the advisory fires) — old matcher bounced it" \
    || no "B: $id must ADVANCE with the advisory" "got $r"
done

echo "== C. the advisory is NOT noise: a clean advance stays silent =="
for v in "approve" "approve — merged and closing, PR #411 squashed as 808323a" "A" "yes, ship it"; do
  r=$(bounce "$v")
  [ "$r" = "ADVANCE" ] && ok "C: '${v:0:34}' -> ADVANCE, no advisory" || no "C: '${v:0:34}' should be a silent ADVANCE" "got $r"
done

echo "== D. inflections are ENUMERATED, not stemmed (DIVE-2614 three-times-confirmed gap) =="
# With \b, `reject` does NOT match `rejected`. Each form must be listed by hand.
for v in "rejects the premise" "rejecting this" "denies the claim" "denying it" \
         "declines" "declining — rework"; do
  r=$(bounce "$v")
  [ "$r" = "BOUNCE" ] && ok "D: leading '${v%% *}' bounces (inflection enumerated)" || no "D: '$v' inflection" "got $r"
done
# ...and the boundary really is a boundary: these must NOT bounce.
for v in "betterment of the codebase — approve" "rejection sampling is fine, approve" \
         "denylist updated, approve"; do
  r=$(bounce "$v")
  [ "${r#ADVANCE}" != "$r" ] && ok "D: '${v:0:32}' does NOT bounce (word boundary holds)" || no "D: boundary on '$v'" "got $r"
done

echo "== E. FIRST NON-BLANK LINE, not line 1 — the fail-OPEN direction =="
# main caught this exact trap in review on DIVE-2614: anchoring to line 1
# literally makes a leading blank line read as an empty verdict. Here empty means
# ADVANCE, i.e. a false APPROVE — the worse direction.
r=$(bounce "$(printf '\n\nreject — the arm is untested')")
[ "$r" = "BOUNCE" ] && ok "E1 a leading blank line does NOT hide a genuine bounce" || no "E1 leading blank line" "got $r"
r=$(bounce "$(printf '\n   \n  denied')")
[ "$r" = "BOUNCE" ] && ok "E2 blank + whitespace-only lines skipped, indent trimmed" || no "E2 blank/ws lines" "got $r"
r=$(bounce "")
[ "$r" = "ADVANCE" ] && ok "E3 an empty answer does not crash and does not bounce" || no "E3 empty answer" "got $r"
r=$(bounce "$(printf '\n \n')")
[ "$r" = "ADVANCE" ] && ok "E4 an all-blank answer survives grep rc=1 under pipefail" || no "E4 all-blank answer" "got $r"

echo "== G. THE RULE'S KNOWN LIMIT, graded rather than glossed =="
# The decision segment is the first non-blank line up to the first dash/colon/
# comma/stop. A decision word placed AFTER that separator reads as reasoning, so
# "needs work — reject" ADVANCES. That is a real limit and it is the deliberate
# failure direction: it does not silently misread, it advances AND says so, which
# is the safe polarity here (a wrong bounce reopens finished work; a wrong advance
# is caught by the verifier still holding the row). Graded so the boundary moves
# only on purpose.
r=$(bounce "needs work — reject")
[ "$r" = "ADVANCE+AMBIG" ] \
  && ok "G1 a decision word AFTER the separator advances WITH the advisory (known limit, not silent)" \
  || no "G1 known limit" "got $r"
r=$(bounce "approve")
[ "$r" = "ADVANCE" ] && ok "G2 ...and the advisory is not simply always-on" || no "G2 advisory not always-on" "got $r"

echo "== F. NON-VACUITY: the old matcher must FAIL section B =="
# Without this, every arm above is satisfied by a function that always returns
# ADVANCE. Re-implement the ORIGINAL predicate and prove it disagrees.
old_bounce() {
  local _lv; _lv=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$_lv" == *"better"* || "$_lv" == *"reject"* || "$_lv" == *"deny"* || "$_lv" == *"denied"* || "$_lv" == *"declin"* ]]
}
_oldhits=0
for v in "$b_2552" "$b_2565" "$b_2596" "$b_cncl9" "$b_1572"; do
  old_bounce "$v" && _oldhits=$((_oldhits+1))
done
[ "$_oldhits" -eq 5 ] \
  && ok "F1 the OLD matcher bounces all 5 real approvals — the arms above are measuring the fix" \
  || no "F1 old matcher non-vacuity" "old matcher bounced $_oldhits/5; if this is not 5 the B arms prove nothing"
# ...and it agrees with the new one on the true bounces, so the fix is a NARROWING
# and not a rewrite of the verdict.
_agree=0
for v in "denied" "reject — the error path is untested" "deny" "declined, see feedback"; do
  old_bounce "$v" && _agree=$((_agree+1))
done
[ "$_agree" -eq 4 ] && ok "F2 old and new agree on all 4 true bounces (this is a narrowing, not a rewrite)" \
  || no "F2 narrowing check" "old matcher bounced $_agree/4 true bounces"

echo
printf 'loop_bounce_anchor: %d passed, %d failed\n' "$P" "$F"
[ "$F" -eq 0 ]
