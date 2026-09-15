#!/usr/bin/env bash
# TIER: core
# DIVE-4537 — THE TWO-STRIKE STOP MUST BE A VERB, AND A MERGE IS NOT A GATE.
#
# lodar, 2026-09-14 13:43Z: "why i still get false human gates? i thought we
# fixed this". Two landed on his phone at 13:41Z; neither needed a person, and
# main cleared both in five minutes.
#
#   A. DIVE-4520 — the iteration-cap escalation. DIVE-4476 had already moved it
#      off his phone (`--type=decision`, tier 1, routed to the lead), but the
#      ANSWER still did nothing to the loop: the row kept iteration ==
#      max_iterations, kept no maker, and the reclaimer handed it to the verifier,
#      the one seat forbidden to build it. Executing "keep going" by hand is three
#      verbs in a forced order and the answering lead holds none of them, so the
#      disposition sat written on the row for 83 minutes.
#      (community/wiki/a-withdrawn-iteration-cap-gate-leaves-the-loop-with-no-owner-and-no-resume-verb.md)
#   B. DIVE-4514 — "Press Merge (plain merge, never Squash)" on two pull requests
#      in an org we own, filed `manual` (tier 2 BY TYPE, so it skips the
#      lead-first rail DIVE-4365 shipped) by a seat whose token cannot merge.
#      main's token could, and did.
#
# Section A grades the resume, section B the refusal, and each carries its
# negative control — the arm that fails if the rule got wider than its sentence.
#
# Run: bash tests/escalation_resume_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/escalation-resume.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init
_tasks_db_migrate

# --- stubs: nothing leaves the box -------------------------------------------
SENT="$TMP/sent"; : >"$SENT"
cmd_send()               { printf '%s\n' "$*" >>"$SENT"; return 0; }
_task_agent_channel()    { return 0; }
_task_send_owner()       { return 0; }
task_need_notify()       { return 0; }
_task_gate_retire_buttons() { return 0; }
_task_gate_card_apply()  { return 0; }
audit_log()              { return 0; }
AUDIT_ROWS="$TMP/audit_rows"; : >"$AUDIT_ROWS"
_task_store_audit_log()  { printf '%s\n' "$*" >>"$AUDIT_ROWS"; return 0; }
_task_reclaim_on_close() { return 0; }
# NO LEAD ABOVE THE FILER — the human-fallback route, the only one in which the
# ask rules run at all (DIVE-4431). Section B's refusal is one of those rules.
_gate_route_reviewer()   { printf ''; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }
has_t() { if [[ "$2" == *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] does not contain [$3]"; fi; }
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }
rowid() { db "SELECT id FROM tasks WHERE ident='$1';"; }

# A row mid-loop AT its cap: delivered, graded FAIL twice, maker recorded.
seed_capped() { # <ident> [iteration] [max]
  db "INSERT INTO tasks (ident, title, priority, assignee, created_by, kind, status,
                         maker_agent, verifier, iteration, max_iterations, handoff_ack_at)
      VALUES ('$1', 'a plain piece of work', 'medium', 'quinn', 'main', 'standard', 'todo',
              'dev', 'quinn', ${2:-2}, ${3:-2}, datetime('now'));"
}

FB='❌ quinn rejected (iteration 2): FINDING: the acceptance arm never ran on this branch / FIX: re-run it against origin/main / VERIFY: the arm reds without the patch'

# File the gate EXACTLY as the iteration cap files it — same type, same options,
# same recommendation, same composer. A hand-typed gate would grade a shape the
# product never produces.
file_escalation() { # <ident>
  local _id; _id=$(rowid "$1")
  db "UPDATE tasks SET result=$(sqlq "$FB") WHERE id=${_id};"
  ( cmd_task_need "$_id" --type=decision --from=quinn \
      --options="$_ESCALATION_OPTIONS" --recommend="$_ESCALATION_RECOMMEND" \
      --ask="$(_task_escalation_ask "$_id" 2 "$FB")" ) >/dev/null 2>&1
}

echo "== PRECONDITIONS =="
declare -F _task_escalation_answer_verb >/dev/null 2>&1 \
  && ok_t "P1: the answer classifier is reachable" \
  || bad_t "P1: _task_escalation_answer_verb not sourced" "sections A/C grade nothing"
declare -F _gate_ask_our_repo_write >/dev/null 2>&1 \
  && ok_t "P2: the capability classifier is reachable" \
  || bad_t "P2: _gate_ask_our_repo_write not sourced" "section B grades nothing"
declare -F _task_stuck_loop_pred >/dev/null 2>&1 \
  && ok_t "P3: the SHARED stuck-loop predicate is what the gate test keys on" \
  || bad_t "P3: _task_stuck_loop_pred missing" "the resume would need a second copy of it"

echo
echo "== A. 'keep going' RESTARTS THE LOOP =="
seed_capped ESC-KEEP
file_escalation ESC-KEEP
eq_t "A0: the cap gate is open and is a decision" "$(field ESC-KEEP need_type)" "decision"
A_OUT=$( (cmd_task_answer "$(rowid ESC-KEEP)" --value="$_ESCALATION_RECOMMEND" --from=main) 2>&1 ); A_RC=$?
eq_t "A1: the answer succeeds"                  "$A_RC" "0"
eq_t "A2: the row is back with the MAKER"       "$(field ESC-KEEP assignee)" "dev"
eq_t "A3: ... and open for work"                "$(field ESC-KEEP status)" "todo"
eq_t "A4: ... with the cap raised to N+1"       "$(field ESC-KEEP max_iterations)" "3"
eq_t "A5: ... started_at cleared for a fresh claim" "$(field ESC-KEEP started_at)" "∅"
eq_t "A6: ... the verifier's ACK dropped"       "$(field ESC-KEEP handoff_ack_at)" "∅"
[[ "$(field ESC-KEEP handoff_rejected_at)" != "∅" ]] \
  && ok_t "A7: ... and the bounce stamped, exactly as an ordinary reject stamps it" \
  || bad_t "A7: handoff_rejected_at not stamped" "the reclaimer cannot tell this from a fresh handoff"
has_t "A8: the verifier's findings survive as the instruction for the pass" "$(field ESC-KEEP result)" "FINDING:"
has_t "A9: the resume ping goes to the maker, not the gate's filer" "$(cat "$SENT")" "dev"
# THE POINT OF RAISING THE CAP: the next bounce must bounce, not re-escalate.
db "UPDATE tasks SET status='todo' WHERE ident='ESC-KEEP';"
D_OUT=$( (cmd_task_deliver "$(rowid ESC-KEEP)" --pr=https://github.com/5dive-ai/5dive/pull/1 \
        --result="took the pass: re-ran the arm against origin/main, it greens") 2>&1 ); D_RC=$?
eq_t "A9b: the maker can deliver the authorised pass" "$D_RC" "0"
eq_t "A10: the maker's next delivery is iteration N+1" "$(field ESC-KEEP iteration)" "3"
# The grade is the VERIFIER's, and a reject reads the caller from the seat the
# harness happens to run on (`task_actor`), which is the maker here — DIVE-477
# refuses that correctly. Pin the seam for this one call, the same way the route
# and send seams are pinned above.
_real_task_actor=$(declare -f task_actor)
task_actor() { printf 'quinn'; }
R_OUT=$( (cmd_task_reject "$(rowid ESC-KEEP)" --feedback="FINDING: still red / FIX: do the thing / VERIFY: it greens") 2>&1 ); R_RC=$?
eval "$_real_task_actor"
eq_t "A10b: the verifier can grade the authorised pass" "$R_RC" "0"
# ONE PASS PER ANSWER, and that is the design, not a shortfall: the cap is raised
# to N+1 and no further, so a second failure files a SECOND stop rather than
# letting a lead's one tap authorise an unbounded loop. What must not come back is
# the old shape — a `manual` gate, tier 2 by type, on the paired human's phone.
eq_t "A11: a second failure files a FRESH stop rather than looping unbounded" \
  "$(db "SELECT CASE WHEN need_type IS NOT NULL AND need_answered_at IS NULL THEN 'open' ELSE 'none' END FROM tasks WHERE ident='ESC-KEEP';")" "open"
eq_t "A12: ... and it is a DECISION, the type that routes to the lead" "$(field ESC-KEEP need_type)" "decision"
eq_t "A13: ... at tier 1, not the tier-2 floor `manual` carries by type"  "$(field ESC-KEEP tier)" "1"
eq_t "A14: ... and answering THAT one resumes the loop too" \
  "$( ( cmd_task_answer "$(rowid ESC-KEEP)" --value="$_ESCALATION_RECOMMEND" --from=main ) >/dev/null 2>&1; field ESC-KEEP assignee)" "dev"
eq_t "A15: ... buying exactly one more pass" "$(field ESC-KEEP max_iterations)" "4"

echo
echo "== B. 'drop it' STOPS IT, AND KEEPS THE FINDINGS =="
seed_capped ESC-DROP
file_escalation ESC-DROP
B_OUT=$( (cmd_task_answer "$(rowid ESC-DROP)" --value="drop it — two passes and the approach is wrong" --from=main) 2>&1 ); B_RC=$?
eq_t "B1: the answer succeeds"            "$B_RC" "0"
eq_t "B2: the row is cancelled"           "$(field ESC-DROP status)" "cancelled"
[[ "$(field ESC-DROP done_at)" != "∅" ]] \
  && ok_t "B3: ... with a close clock, through the shared funnel" \
  || bad_t "B3: done_at not stamped" "a cancelled row with no close time"
has_t "B4: ... and the verifier's findings preserved, not overwritten" "$(field ESC-DROP result)" "FINDING:"

echo
echo "== C. AN ANSWER THAT NAMES NEITHER OUTCOME MOVES NOTHING =="
seed_capped ESC-AMBIG
file_escalation ESC-AMBIG
C_OUT=$( (cmd_task_answer "$(rowid ESC-AMBIG)" --value="see my note on the row" --from=main) 2>&1 ); C_RC=$?
eq_t "C1: the answer still succeeds (the gate is answered)" "$C_RC" "0"
eq_t "C2: ... but the row is NOT handed to the maker" "$(field ESC-AMBIG assignee)" "quinn"
eq_t "C3: ... and NOT cancelled"                      "$(field ESC-AMBIG status)" "todo"
has_t "C4: ... and the reader is told how to answer it" "$C_OUT" "keep going"
# THE CONTROL: a decision gate that is NOT the cap escalation must not resume.
db "INSERT INTO tasks (ident, title, priority, assignee, created_by, kind, status,
                       maker_agent, verifier, iteration, max_iterations)
    VALUES ('ESC-OTHER', 'a plain piece of work', 'medium', 'quinn', 'main', 'standard', 'todo',
            'dev', 'quinn', 2, 2);"
( cmd_task_need "$(rowid ESC-OTHER)" --type=decision --from=quinn \
    --options="ship it as it stands|split it in two first" \
    --ask="Should this go out as one change, or be split in two first?" ) >/dev/null 2>&1
( cmd_task_answer "$(rowid ESC-OTHER)" --value="ship it as it stands" --from=main ) >/dev/null 2>&1
eq_t "C5: CONTROL — another decision gate on a capped row does not bounce it" \
  "$(field ESC-OTHER assignee)" "quinn"
eq_t "C6: CONTROL — ... and does not raise its cap" "$(field ESC-OTHER max_iterations)" "2"

echo
echo "== D. THE CLASSIFIER READS THE DECISION SEGMENT, NOT THE PROSE =="
eq_t "D1: the shipped recommendation resumes" "$(_task_escalation_answer_verb "$_ESCALATION_RECOMMEND")" "resume"
eq_t "D2: the shipped drop option drops"      "$(_task_escalation_answer_verb "drop it — stop the work, keep the findings")" "drop"
eq_t "D3: a drop whose REASONING says 'keep going' still drops" \
  "$(_task_escalation_answer_verb "drop it — I would rather keep going on the other row")" "drop"
eq_t "D4: a keep whose REASONING says 'drop' still resumes" \
  "$(_task_escalation_answer_verb "keep going — the fix is one line, do not drop this")" "resume"
eq_t "D5: neither vocabulary is neither verb"  "$(_task_escalation_answer_verb "see my note on the row")" ""
eq_t "D6: an ambiguous opening segment prefers the cheaper mistake" \
  "$(_task_escalation_answer_verb "stop and keep")" "drop"

echo
echo "== E. A MERGE ON OUR OWN REPO IS REFUSED, AND NAMES THE ROUTING VERB =="
db "INSERT INTO tasks (ident, title, priority, assignee, created_by, kind, status)
    VALUES ('ESC-MERGE', 'a plain piece of work', 'medium', 'quinn', 'main', 'standard', 'todo');"
E_OUT=$( (cmd_task_need "$(rowid ESC-MERGE)" --type=manual --from=quinn \
   --ask="Press Merge on https://github.com/5dive-ai/5dive-chat/pull/11 — plain merge, never Squash.") 2>&1 ); E_RC=$?
[[ "$E_RC" -ne 0 ]] && ok_t "E1: the gate is refused" || bad_t "E1: it filed" "rc=$E_RC"
has_t "E2: ... naming the hand-over as the wanted exit" "$E_OUT" "task assign"
has_t "E3: ... in plain English, with no ident or flag in the first sentence" "$E_OUT" "OUR OWN code repositories"
eq_t  "E4: ... and nothing was written to the row" "$(field ESC-MERGE need_type)" "∅"
# THE ESCAPE, because a gate must never become unfileable (DIVE-2216).
E5_OUT=$( (cmd_task_need "$(rowid ESC-MERGE)" --type=manual --from=quinn \
   --ask="Press Merge on https://github.com/5dive-ai/5dive-chat/pull/11 — plain merge, never Squash." \
   --ask-ok="every seat holding a write token on that fork is out of credential until the rotation lands") 2>&1 ); E5_RC=$?
eq_t "E5: the audited escape files it anyway" "$E5_RC" "0"
has_t "E6: ... and the exception is recorded where it can be counted" "$(cat "$AUDIT_ROWS")" "ask-capability"

echo
echo "== F. CONTROLS — the refusal is three conjuncts wide, not one =="
db "INSERT INTO tasks (ident, title, priority, assignee, created_by, kind, status)
    VALUES ('ESC-CTL', 'a plain piece of work', 'medium', 'quinn', 'main', 'standard', 'todo');"
ctl() { # <label> <expect-rc-zero> <ask...>
  local _lbl="$1" _want="$2"; shift 2
  db "UPDATE tasks SET need_type=NULL, ask=NULL, need_answered_at=NULL WHERE ident='ESC-CTL';"
  local _o _r
  _o=$( (cmd_task_need "$(rowid ESC-CTL)" --type="$1" --from=quinn --ask="$2") 2>&1 ); _r=$?
  if [[ "$_want" == "files" ]]; then
    [[ "$_r" -eq 0 ]] && ok_t "$_lbl" || bad_t "$_lbl" "refused: $_o"
  else
    [[ "$_r" -ne 0 ]] && ok_t "$_lbl" || bad_t "$_lbl" "filed when it should not"
  fi
}
ctl "F1: POSITIVE CONTROL — an ordinary manual ask with no repository in it still files" files \
    manual "Plug the spare power cable back into the machine under the desk?"
ctl "F2: a manual ask about a THIRD-PARTY repository is someone else's button and still files" files \
    manual "Press Merge on https://github.com/vercel-labs/agent-browser/pull/4 for us?"
ctl "F3: a JUDGEMENT about our own pull request is a question, not a job, and still files" files \
    manual "Is the approach in https://github.com/5dive-ai/5dive-chat/pull/11 the one we want?"
eq_t "F4: the classifier itself needs BOTH halves — a repo with no write verb is clean" \
  "$(_gate_ask_our_repo_write "Is https://github.com/5dive-ai/5dive/pull/1 the right shape?" && echo caught || echo clean)" "clean"
eq_t "F5: ... and a write verb with no repo of ours is clean" \
  "$(_gate_ask_our_repo_write "Please merge the two paragraphs in the launch email." && echo caught || echo clean)" "clean"

echo
printf 'TOTAL: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
