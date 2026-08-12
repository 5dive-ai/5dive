#!/usr/bin/env bash
# TIER: core
# DIVE-2261 — a loop rejection must not resurrect a cancelled prior step.
#
# The DIVE-552 bounce used to select the immediately preceding loop step without
# reading its status, then unconditionally write it to todo.  A cancellation is
# an explicit abandonment record, so the conservative behaviour is to refuse the
# answer before recording it.  The gate stays open and the cancelled row stays
# byte-for-byte unchanged.  The done-row control proves the ordinary redo path
# still works.
# Run: bash tests/task_answer_cancelled_loop_bounce_unit.sh
# shellcheck disable=SC2015,SC2034
set -uo pipefail

# shellcheck source=tests/lib/grading_tree.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.." || exit
# shellcheck source=tests/lib/actor_seam.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"

SRC="${DIVE2261_SRC_DIR:-src}"
TMP="$(mktemp -d /tmp/task-answer-cancelled-loop-bounce.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh \
         cmd_push.sh cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1; mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }

tasks_db_init
as() { local who="$1"; shift; ( actor_seam_as "$who"; "$@" ); }
add() { JSON_MODE=1 cmd_task_add "$@" 2>"$TMP/err" | jq -r '.data.ident // empty'; }
id_of() { db "SELECT id FROM tasks WHERE ident=$(sqlq "$1");"; }
field() { db "SELECT COALESCE($2,'') FROM tasks WHERE ident=$(sqlq "$1");"; }

seed_loop_gate() {
  local previous_status="$1" prefix="$2" gate_type="${3:-decision}"
  local run prev gate run_id prev_id gate_id
  run=$(add "$prefix run" --assignee=main)
  prev=$(add "$prefix previous work" --assignee=dev)
  gate=$(add "$prefix review gate" --assignee=dev2)
  run_id=$(id_of "$run"); prev_id=$(id_of "$prev"); gate_id=$(id_of "$gate")
  db "UPDATE tasks SET body='[[5dive-loop:run]]' WHERE id=${run_id};
      UPDATE tasks SET parent_id=${run_id}, body='[[5dive-loop:work]]',
        status=$(sqlq "$previous_status"), started_at='2001-02-03 04:05:06',
        done_at='2001-02-03 05:06:07' WHERE id=${prev_id};
      UPDATE tasks SET parent_id=${run_id}, body=$(sqlq "[[5dive-loop:gate:${gate_type}]]"),
        status='blocked', need_type=$(sqlq "$gate_type"), ask='approve or redo?', tier=1,
        need_asked_at='2001-02-03 06:07:08', need_answered_at=NULL,
        need_answered_by=NULL WHERE id=${gate_id};"
  printf '%s|%s|%s' "$run" "$prev" "$gate"
}

# C1 — the reported residual. Refusal must happen before any answer/bounce write.
IFS='|' read -r _c_run c_prev c_gate <<<"$(seed_loop_gate cancelled c)"
c_before=$(db "SELECT status||'|'||COALESCE(started_at,'')||'|'||COALESCE(done_at,'') FROM tasks WHERE ident=$(sqlq "$c_prev");")
c_out=$(as dev2 cmd_task_answer "$c_gate" --value="Do better ↩" 2>&1); c_rc=$?
[[ $c_rc -ne 0 ]] \
  && ok_t "C1 cancelled previous step is refused" \
  || bad_t "C1 cancelled previous step is refused" "rc=0; output=$c_out"
[[ "$c_out" == *"$c_prev"* && "$c_out" == *"cancelled"* && "$c_out" == *"still open"* ]] \
  && ok_t "C1 refusal names the abandoned step and the open gate" \
  || bad_t "C1 refusal names the abandoned step and the open gate" "$c_out"
[[ "$(db "SELECT status||'|'||COALESCE(started_at,'')||'|'||COALESCE(done_at,'') FROM tasks WHERE ident=$(sqlq "$c_prev");")" == "$c_before" ]] \
  && ok_t "C1 cancelled row is byte-for-byte unchanged across its lifecycle fields" \
  || bad_t "C1 cancelled row is byte-for-byte unchanged across its lifecycle fields" "before=$c_before after=$(field "$c_prev" status)|$(field "$c_prev" started_at)|$(field "$c_prev" done_at)"
[[ "$(field "$c_gate" status)" == "blocked" && -z "$(field "$c_gate" need_answered_at)" ]] \
  && ok_t "C1 gate stays blocked and unanswered" \
  || bad_t "C1 gate stays blocked and unanswered" "status=$(field "$c_gate" status) answered_at=$(field "$c_gate" need_answered_at)"
[[ "$(db "SELECT COUNT(*) FROM task_deps WHERE task_id=$(id_of "$c_gate");")" == "0" ]] \
  && ok_t "C1 refusal creates no synthetic dependency edge" \
  || bad_t "C1 refusal creates no synthetic dependency edge" "edge was inserted despite refusal"
[[ "$(db "SELECT COUNT(*) FROM policy_refusals WHERE policy='task_loop_bounce_cancelled_previous' AND ident=$(sqlq "$c_gate");")" == "1" ]] \
  && ok_t "C1 refusal is audit-visible under the DIVE-2261 policy" \
  || bad_t "C1 refusal is audit-visible under the DIVE-2261 policy" "policy_refusal count was not 1"

# C2 — current loop gates are approvals and spell the same direction "denied".
IFS='|' read -r _c2_run c2_prev c2_gate <<<"$(seed_loop_gate cancelled c2 approval)"
c2_out=$(as dev2 cmd_task_answer "$c2_gate" --value="denied" 2>&1); c2_rc=$?
[[ $c2_rc -ne 0 && "$c2_out" == *"$c2_prev"* && "$c2_out" == *"cancelled"* ]] \
  && ok_t "C2 approval-gate denied vocabulary takes the same refusal" \
  || bad_t "C2 approval-gate denied vocabulary takes the same refusal" "rc=$c2_rc; output=$c2_out"
[[ "$(field "$c2_prev" status)" == "cancelled" && -z "$(field "$c2_gate" need_answered_at)" ]] \
  && ok_t "C2 denied leaves both approval rows untouched" \
  || bad_t "C2 denied leaves both approval rows untouched" "previous=$(field "$c2_prev" status) answered_at=$(field "$c2_gate" need_answered_at)"

# W1 — positive control. A completed prior step is exactly what bounce is for.
IFS='|' read -r _w_run w_prev w_gate <<<"$(seed_loop_gate "done" w)"
w_out=$(as dev2 cmd_task_answer "$w_gate" --value="Do better ↩" 2>&1); w_rc=$?
[[ $w_rc -eq 0 ]] \
  && ok_t "W1 bounce from a done previous step still succeeds" \
  || bad_t "W1 bounce from a done previous step still succeeds" "rc=$w_rc; output=$w_out"
[[ "$(field "$w_prev" status)" == "todo" && -z "$(field "$w_prev" started_at)" ]] \
  && ok_t "W1 completed work is reopened for redo" \
  || bad_t "W1 completed work is reopened for redo" "status=$(field "$w_prev" status) started_at=$(field "$w_prev" started_at)"
[[ "$(field "$w_gate" status)" == "blocked" && -n "$(field "$w_gate" need_answered_at)" ]] \
  && ok_t "W1 answered gate is re-blocked behind the redo" \
  || bad_t "W1 answered gate is re-blocked behind the redo" "status=$(field "$w_gate" status) answered_at=$(field "$w_gate" need_answered_at)"
[[ "$(db "SELECT COUNT(*) FROM task_deps WHERE task_id=$(id_of "$w_gate") AND blocked_by=$(id_of "$w_prev");")" == "1" ]] \
  && ok_t "W1 bounce installs the expected dependency edge" \
  || bad_t "W1 bounce installs the expected dependency edge" "expected gate -> previous edge"


# ============================================================================
# DIVE-2572 — WHICH ANSWERS BOUNCE AT ALL. Folded in from loop_bounce_anchor_unit.sh
# rather than shipped as its own file: the core tier was AT its cap (the runner's
# own words, "the next few guards will not be" inside it), and past the cap a new
# guard MERGES with an existing one rather than being added. This is the same
# subject as the arms above — the arms above grade what a bounce DOES, these grade
# which answers ARE one — so folding drops no assertion and reclaims the whole
# library-sourcing cost of a second file (measured: 494ms standalone, and its
# assertions are pure-function).
# ============================================================================
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
  [ "$r" = "BOUNCE" ] && ok_t "A: '${v:0:34}' -> BOUNCE" || bad_t "A: '${v:0:34}' should BOUNCE" "got $r"
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
    && ok_t "B: $id ADVANCES (and the advisory fires) — old matcher bounced it" \
    || bad_t "B: $id must ADVANCE with the advisory" "got $r"
done

echo "== C. the advisory is NOT noise: a clean advance stays silent =="
for v in "approve" "approve — merged and closing, PR #411 squashed as 808323a" "A" "yes, ship it"; do
  r=$(bounce "$v")
  [ "$r" = "ADVANCE" ] && ok_t "C: '${v:0:34}' -> ADVANCE, no advisory" || bad_t "C: '${v:0:34}' should be a silent ADVANCE" "got $r"
done

echo "== D. inflections are ENUMERATED, not stemmed (DIVE-2614 three-times-confirmed gap) =="
# With \b, `reject` does NOT match `rejected`. Each form must be listed by hand.
for v in "rejects the premise" "rejecting this" "denies the claim" "denying it" \
         "declines" "declining — rework"; do
  r=$(bounce "$v")
  [ "$r" = "BOUNCE" ] && ok_t "D: leading '${v%% *}' bounces (inflection enumerated)" || bad_t "D: '$v' inflection" "got $r"
done
# ...and the boundary really is a boundary: these must NOT bounce.
for v in "betterment of the codebase — approve" "rejection sampling is fine, approve" \
         "denylist updated, approve"; do
  r=$(bounce "$v")
  [ "${r#ADVANCE}" != "$r" ] && ok_t "D: '${v:0:32}' does NOT bounce (word boundary holds)" || bad_t "D: boundary on '$v'" "got $r"
done

echo "== E. FIRST NON-BLANK LINE, not line 1 — the fail-OPEN direction =="
# main caught this exact trap in review on DIVE-2614: anchoring to line 1
# literally makes a leading blank line read as an empty verdict. Here empty means
# ADVANCE, i.e. a false APPROVE — the worse direction.
r=$(bounce "$(printf '\n\nreject — the arm is untested')")
[ "$r" = "BOUNCE" ] && ok_t "E1 a leading blank line does NOT hide a genuine bounce" || bad_t "E1 leading blank line" "got $r"
r=$(bounce "$(printf '\n   \n  denied')")
[ "$r" = "BOUNCE" ] && ok_t "E2 blank + whitespace-only lines skipped, indent trimmed" || bad_t "E2 blank/ws lines" "got $r"
r=$(bounce "")
[ "$r" = "ADVANCE" ] && ok_t "E3 an empty answer does not crash and does not bounce" || bad_t "E3 empty answer" "got $r"
r=$(bounce "$(printf '\n \n')")
[ "$r" = "ADVANCE" ] && ok_t "E4 an all-blank answer survives grep rc=1 under pipefail" || bad_t "E4 all-blank answer" "got $r"

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
  && ok_t "G1 a decision word AFTER the separator advances WITH the advisory (known limit, not silent)" \
  || bad_t "G1 known limit" "got $r"
r=$(bounce "approve")
[ "$r" = "ADVANCE" ] && ok_t "G2 ...and the advisory is not simply always-on" || bad_t "G2 advisory not always-on" "got $r"

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
  && ok_t "F1 the OLD matcher bounces all 5 real approvals — the arms above are measuring the fix" \
  || bad_t "F1 old matcher non-vacuity" "old matcher bounced $_oldhits/5; if this is not 5 the B arms prove nothing"
# ...and it agrees with the new one on the true bounces, so the fix is a NARROWING
# and not a rewrite of the verdict.
_agree=0
for v in "denied" "reject — the error path is untested" "deny" "declined, see feedback"; do
  old_bounce "$v" && _agree=$((_agree+1))
done
[ "$_agree" -eq 4 ] && ok_t "F2 old and new agree on all 4 true bounces (this is a narrowing, not a rewrite)" \
  || bad_t "F2 narrowing check" "old matcher bounced $_agree/4 true bounces"

echo

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
