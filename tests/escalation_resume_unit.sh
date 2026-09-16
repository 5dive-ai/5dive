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
# The hand-over receipt the ordinary reject bounce sends (src/lib/routing_receipt.sh,
# not sourced here). It prints to the CALLER's stdout, which is why the auto-clear
# helper hands its clause back in a variable instead of on stdout — capturing the
# helper in `$(…)` would swallow this line into the success message.
RECEIPTS="$TMP/receipts"; : >"$RECEIPTS"
routing_receipt() { printf '%s\n' "$*" >>"$RECEIPTS"; printf 'handoff: %s %s\n' "${2:-}" "${3:-}"; return 0; }
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
eq_t "A13: ... at tier 1, not the tier-2 floor 'manual' carries by type"  "$(field ESC-KEEP tier)" "1"
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
# A NEGATED SEGMENT IS NOT A VERB. "do not keep going" carries no drop stem, so
# stem-matching alone read it as a RESUME — the expensive direction, and the exact
# inversion of the answer. It is now the ambiguous branch: the row does not move
# and the answerer is told the two words that work.
eq_t "D7: a negated resume is NOT a resume" \
  "$(_task_escalation_answer_verb "do not keep going")" ""
eq_t "D8: ... and a negated drop is not a drop either — neither is guessed at" \
  "$(_task_escalation_answer_verb "don't drop it")" ""
eq_t "D9: CONTROL — the two shipped buttons carry no negation and still classify" \
  "$(_task_escalation_answer_verb "$_ESCALATION_RECOMMEND")$(_task_escalation_answer_verb "drop it — stop the work, keep the findings")" "resumedrop"

echo
echo "== E. A MERGE ON OUR OWN REPO IS REFUSED, AND NAMES THE ROUTING VERB =="
# PIN THE IDENTITY SEAM FOR THE POPULATION UNDER TEST, not just for the control
# (iteration 3). The refusal's third conjunct reads `_gate_withdraw_actor`, and
# iteration 2 pinned it only around F6. Everywhere else the arm inherited the
# HOST's identity — on an agent seat that resolves `agent <seat>` and the
# precondition arrived free, so E1-E6 and F7 were green here and RED in CI, where
# the runner's uid is in /etc/passwd and resolves `human`. An arm that needs a
# precondition must state it: `agent quinn` is asserted, never inherited.
# (_real_withdraw_actor is restored at the end of section F.)
_real_withdraw_actor=$(declare -f _gate_withdraw_actor || true)
actor_is() { eval "_gate_withdraw_actor() { printf '%s' \"$1\"; }"; }
actor_restore() { if [[ -n "$_real_withdraw_actor" ]]; then eval "$_real_withdraw_actor"; else unset -f _gate_withdraw_actor; fi; }
actor_is 'agent quinn'
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
# THE THIRD CONJUNCT, which had no arm of its own in iteration 1 although the
# delivery note claimed one. The refusal reads the FILER from the uid-resolved
# actor, not from --from, and a person filing this for another person is not the
# population: nobody is being asked to do work a seat here could do instead.
MERGE_ASK="Press Merge on https://github.com/5dive-ai/5dive-chat/pull/11 — plain merge, never Squash."
actor_is 'human'
ctl "F6: CONTROL — the same ask from a HUMAN filer is not the population, and files" files \
    manual "$MERGE_ASK"
actor_is 'agent quinn'
ctl "F7: ... and with the filer an agent seat the very same ask is refused again" refused \
    manual "$MERGE_ASK"
# THE THIRD OUTCOME OF THE RESOLVER, which had no arm at all in iteration 2 and is
# the one the CI runner and root cron take. `_gate_withdraw_actor` prints
# `agent <name>` | `human` | `none`; refusing only the first fails OPEN for the
# other two, in the direction this row exists to close. An unattributable caller
# is by construction not a person handing work to another person, so it is
# refused — and it keeps the audited escape, so nothing becomes unfileable.
actor_is 'none'
ctl "F8: an UNATTRIBUTABLE caller (root cron, a timer) is refused too, not filed" refused \
    manual "$MERGE_ASK"
F8_OUT=$( (cmd_task_need "$(rowid ESC-CTL)" --type=manual --from=quinn --ask="$MERGE_ASK") 2>&1 )
has_t "F8b: ... naming the same hand-over exit a named seat gets" "$F8_OUT" "task assign"
ctl "F8c: CONTROL — an unattributable caller's ORDINARY manual ask still files" files \
    manual "Plug the spare power cable back into the machine under the desk?"
# The refusal must be countable BY CALLER KIND: "how many of these came from
# automation" is the question this row's axis is measured on.
has_t "F9: the audit row records which kind of caller was refused" \
  "$(grep 'ask-capability' "$AUDIT_ROWS" | tail -1)" "caller=none"
actor_restore

echo
echo "== G. AN AUTO-APPLIED ANSWER DOES THE SAME WORK A TYPED ONE DOES =="
# THE DEFECT ITERATION 1 SHIPPED. `cmd_task_answer` is one of five writers of this
# gate's answer; the other four are the auto-clears, which apply it with a DIRECT
# UPDATE and return — never through `task answer`, deliberately. So the resume
# lived on the path a lead's typed tap takes, and not on the path this gate is
# most likely to take at all: every seat that files one of these stops is promoted
# on this host (quinn 93%, dev 94%, ops 100%), the stop carries a --recommend, and
# `track_record` defaults ON in code. The result was `answered_by=auto:record,
# answer=keep going` on a row still held by the VERIFIER at iteration ==
# max_iterations, unstamped, with no human and no lead in the path to notice.
#
# Pin the record seams the same way this harness already pins the route, send and
# actor seams — the point is the EXECUTION, not the promotion arithmetic.
_real_pref_get=$(declare -f _task_pref_get || true)
_real_promoted=$(declare -f _gate_record_promoted || true)
_real_stats=$(declare -f _gate_record_stats || true)
_TR_PREF=on
_task_pref_get()        { [[ "${1:-}" == "track_record" ]] && printf '%s' "$_TR_PREF"; return 0; }
_gate_record_promoted() { return 0; }
_gate_record_stats()    { printf '17 18 5'; }

seed_capped ESC-AUTO
db "UPDATE tasks SET result=$(sqlq "$FB") WHERE ident='ESC-AUTO';"
_real_task_actor=$(declare -f task_actor)
task_actor() { printf 'quinn'; }
G_OUT=$( (cmd_task_reject "$(rowid ESC-AUTO)" --feedback="$FB") 2>&1 ); G_RC=$?
eval "$_real_task_actor"
eq_t "G1: the reject at the cap succeeds"        "$G_RC" "0"
eq_t "G2: ... and the stop is auto-answered on the filer's track record" \
  "$(field ESC-AUTO need_answered_by)" "auto:record"
eq_t "G3: ... and THAT answer hands the row to the MAKER"  "$(field ESC-AUTO assignee)" "dev"
eq_t "G4: ... raises the cap to N+1"                       "$(field ESC-AUTO max_iterations)" "3"
eq_t "G5: ... and leaves it open for work"                 "$(field ESC-AUTO status)" "todo"
[[ "$(field ESC-AUTO handoff_rejected_at)" != "∅" ]] \
  && ok_t "G6: ... with the bounce stamped, as an ordinary reject stamps it" \
  || bad_t "G6: handoff_rejected_at not stamped" "an auto-cleared stop that reads as never bounced"
has_t "G7: ... and the receipt says the row moved, not just that an answer was recorded" \
  "$G_OUT" "back with maker dev"
has_t "G7b: ... the maker gets the same hand-over receipt an ordinary bounce sends" \
  "$(cat "$RECEIPTS")" "dev"
grep -q '^handoff: dev' <<<"$G_OUT" \
  && ok_t "G7c: ... and that receipt reaches the caller's own output, not the success message" \
  || bad_t "G7c: the receipt was swallowed" "capturing the helper in \$(…) folds routing_receipt's line into 'applied: …'"
has_t "G8: ... the verifier's findings survive as the instruction for the pass" "$(field ESC-AUTO result)" "FINDING:"

# THE CONTROL: with the pref off there is no auto-clear, so nothing here may move
# the row — the resume must ride the ANSWER, never the reject.
_TR_PREF=off
seed_capped ESC-AUTO-OFF
db "UPDATE tasks SET result=$(sqlq "$FB") WHERE ident='ESC-AUTO-OFF';"
_real_task_actor=$(declare -f task_actor)
task_actor() { printf 'quinn'; }
( cmd_task_reject "$(rowid ESC-AUTO-OFF)" --feedback="$FB" ) >/dev/null 2>&1
eval "$_real_task_actor"
eq_t "G9: CONTROL — pref off, the stop is left open for a lead" \
  "$(field ESC-AUTO-OFF need_answered_by)" "∅"
eq_t "G10: CONTROL — ... and the row is NOT handed to the maker" "$(field ESC-AUTO-OFF assignee)" "quinn"
eq_t "G11: CONTROL — ... and its cap is NOT raised"              "$(field ESC-AUTO-OFF max_iterations)" "2"

# THE OTHER AUTO WRITER REACHABLE FROM THIS GATE: a tier-0 filing applies the
# recommendation at once on the same direct-write path. Same one line, same
# executor — the cost of covering a writer is a line, which is the whole point of
# lifting the disposition out of `task answer`.
_TR_PREF=off
seed_capped ESC-AUTO-T0
db "UPDATE tasks SET result=$(sqlq "$FB") WHERE ident='ESC-AUTO-T0';"
T0_OUT=$( (cmd_task_need "$(rowid ESC-AUTO-T0)" --type=decision --from=quinn --tier=0 \
    --options="$_ESCALATION_OPTIONS" --recommend="$_ESCALATION_RECOMMEND" \
    --ask="$(_task_escalation_ask "$(rowid ESC-AUTO-T0)" 2 "$FB")") 2>&1 ); T0_RC=$?
eq_t "G12: a tier-0 filing of the same stop applies at once" "$T0_RC" "0"
eq_t "G13: ... and it too hands the row to the maker"        "$(field ESC-AUTO-T0 assignee)" "dev"
eq_t "G14: ... with the cap at N+1"                          "$(field ESC-AUTO-T0 max_iterations)" "3"

echo
echo "== H. THE PRECEDENT AUTO-CLEAR EXECUTES TOO (the third of four writers) =="
# UNGRADED IN ITERATION 2, and found by cutting the line with a 0-count anchor:
# the 69-arm suite stayed 69/69, so the auto:precedent call site was carried by
# the maker's word alone. It is a DIFFERENT writer from auto:record — a different
# predicate, a different answer source (a prior HUMAN tap on the same ask shape,
# not the filer's track record) — and "the same one line is there" is a claim
# about the source, which is what the arm is supposed to stop me asserting.
_TR_PREF=off
_PC_PREF=on
_task_pref_get() {
  case "${1:-}" in
    track_record)        printf '%s' "$_TR_PREF" ;;
    precedent_autoclear) printf '%s' "$_PC_PREF" ;;
  esac
  return 0
}
seed_capped ESC-AUTO-PR
PR_ID=$(rowid ESC-AUTO-PR)
PR_ASK=$(_task_escalation_ask "$PR_ID" 2 "$FB")
db "UPDATE tasks SET result=$(sqlq "$FB") WHERE id=${PR_ID};"
# Pass 1 with the pref OFF records the shape this exact ask hashes to; the seeds
# are then given THAT shape, so the precedent set matches by construction rather
# than by my guess at the normaliser.
_PC_PREF=off
( cmd_task_need "$PR_ID" --type=decision --from=quinn \
    --options="$_ESCALATION_OPTIONS" --recommend="$_ESCALATION_RECOMMEND" --ask="$PR_ASK" ) >/dev/null 2>&1
PR_SHAPE=$(field ESC-AUTO-PR ask_shape)
[[ -n "$PR_SHAPE" && "$PR_SHAPE" != "∅" ]] \
  && ok_t "H0: the cap gate carries an ask shape, so precedent can key on it" \
  || bad_t "H0: no ask_shape on the escalation gate" "section H grades nothing"
# Two nonce-verified HUMAN answers on that shape, agreeing — the qualifying set.
for _n in 1 2; do
  db "INSERT INTO tasks (ident, title, priority, assignee, created_by, kind, status,
                         need_type, tier, ask_shape, need_answer, need_answered_by,
                         human_nonce_hash, need_answered_at)
      VALUES ('ESC-SEED${_n}', 'an earlier stop a person answered', 'medium', 'dev', 'main', 'standard', 'done',
              'decision', 1, $(sqlq "$PR_SHAPE"), $(sqlq "$_ESCALATION_RECOMMEND"), 'human:lodar',
              'nonce${_n}', datetime('now','-1 day'));"
done
# Back to the capped, ungated state and file it again for real.
db "UPDATE tasks SET need_type=NULL, ask=NULL, need_answer=NULL, need_answered_at=NULL,
      need_answered_by=NULL, ask_shape=NULL, recommend=NULL, need_asked_at=NULL, tier=NULL,
      status='todo', assignee='quinn', iteration=2, max_iterations=2, handoff_rejected_at=NULL
    WHERE id=${PR_ID};"
_PC_PREF=on
H_OUT=$( (cmd_task_need "$PR_ID" --type=decision --from=quinn \
    --options="$_ESCALATION_OPTIONS" --recommend="$_ESCALATION_RECOMMEND" --ask="$PR_ASK") 2>&1 )
eq_t "H1: the stop is auto-answered on the human precedent" \
  "$(field ESC-AUTO-PR need_answered_by)" "auto:precedent"
eq_t "H2: ... and THAT answer hands the row to the MAKER" "$(field ESC-AUTO-PR assignee)" "dev"
eq_t "H3: ... raises the cap to N+1"                      "$(field ESC-AUTO-PR max_iterations)" "3"
[[ "$(field ESC-AUTO-PR handoff_rejected_at)" != "∅" ]] \
  && ok_t "H4: ... and stamps the bounce" \
  || bad_t "H4: handoff_rejected_at not stamped" "a precedent-cleared stop that reads as never bounced"
has_t "H5: ... and says the row moved, not just that an answer was recorded" "$H_OUT" "back with maker dev"
# CONTROL: the precedent path with the pref off leaves the stop for a lead.
_PC_PREF=off
seed_capped ESC-AUTO-PR-OFF
PRO_ID=$(rowid ESC-AUTO-PR-OFF)
db "UPDATE tasks SET result=$(sqlq "$FB") WHERE id=${PRO_ID};"
( cmd_task_need "$PRO_ID" --type=decision --from=quinn --options="$_ESCALATION_OPTIONS" \
    --recommend="$_ESCALATION_RECOMMEND" --ask="$(_task_escalation_ask "$PRO_ID" 2 "$FB")" ) >/dev/null 2>&1
eq_t "H6: CONTROL — pref off, no precedent clear"  "$(field ESC-AUTO-PR-OFF need_answered_by)" "∅"
eq_t "H7: CONTROL — ... and the row is not handed to the maker" "$(field ESC-AUTO-PR-OFF assignee)" "quinn"

echo
echo "== I. THE 48h TTL SWEEP EXECUTES TOO — AND ITS PING IS THE NOVEL PART =="
# The fourth writer, and the one iteration 2's self-audit wrongly called "graded
# by arms". It is also the only call site with logic of its own: the sweep's
# "Resume the task" ping goes to the row's ASSIGNEE, which on a stopped loop is
# the VERIFIER — the hand-back that left DIVE-4520 with no owner. Suppressing it
# is a claim, and a claim needs an arm.
if source "$SRC/cmd_heartbeat.sh" 2>/dev/null && declare -F _hb_gate_ttl_sweep >/dev/null 2>&1; then
  ok_t "I0: the real TTL sweep is reachable (not a copy of it)"
  _hb_log() { return 0; }
  seed_capped ESC-TTL
  TTL_ID=$(rowid ESC-TTL)
  db "UPDATE tasks SET result=$(sqlq "$FB") WHERE id=${TTL_ID};"
  ( cmd_task_need "$TTL_ID" --type=decision --from=quinn --options="$_ESCALATION_OPTIONS" \
      --recommend="$_ESCALATION_RECOMMEND" --ask="$(_task_escalation_ask "$TTL_ID" 2 "$FB")" ) >/dev/null 2>&1
  # Age the gate past the 48h TTL; everything else is the shape the cap files.
  db "UPDATE tasks SET need_asked_at=datetime('now','-72 hours') WHERE id=${TTL_ID};"
  : >"$SENT"
  _hb_gate_ttl_sweep >/dev/null 2>&1
  eq_t "I1: the sweep applies the recommendation" "$(field ESC-TTL need_answered_by)" "auto:ttl"
  eq_t "I2: ... and THAT answer hands the row to the MAKER" "$(field ESC-TTL assignee)" "dev"
  eq_t "I3: ... raises the cap to N+1"                      "$(field ESC-TTL max_iterations)" "3"
  [[ "$(field ESC-TTL handoff_rejected_at)" != "∅" ]] \
    && ok_t "I4: ... and stamps the bounce" \
    || bad_t "I4: handoff_rejected_at not stamped" "a TTL-cleared stop that reads as never bounced"
  if grep -q 'Resume the task' "$SENT"; then
    bad_t "I5: the verifier must NOT also be told to resume" "$(cat "$SENT")"
  else
    ok_t "I5: the sweep's own 'Resume the task' ping is suppressed on a resumed loop"
  fi
  has_t "I6: ... and the MAKER got the hand-over receipt instead" "$(cat "$RECEIPTS")" "dev"
  # CONTROL: an ORDINARY tier-1 gate on the same sweep still gets the ping, so
  # the suppression is scoped to the stop and did not silence the sweep.
  db "INSERT INTO tasks (ident, title, priority, assignee, created_by, kind, status,
                         need_type, tier, recommend, ask, need_asked_at)
      VALUES ('TTL-PLAIN', 'an ordinary tier-1 gate', 'medium', 'dev', 'main', 'standard', 'todo',
              'decision', 1, 'widen the cap now', 'Widen the cap now, or fix the rows first?',
              datetime('now','-72 hours'));"
  : >"$SENT"
  _hb_gate_ttl_sweep >/dev/null 2>&1
  eq_t "I7: CONTROL — an ordinary gate is still auto-applied" "$(field TTL-PLAIN need_answered_by)" "auto:ttl"
  grep -q 'Resume the task' "$SENT" \
    && ok_t "I8: CONTROL — ... and its owner still gets the sweep's ping" \
    || bad_t "I8: the suppression silenced the whole sweep" "$(cat "$SENT")"
else
  bad_t "I0: the real TTL sweep is NOT reachable from this harness" \
    "src/cmd_heartbeat.sh did not source; the auto:ttl writer would ship ungraded"
fi

if [[ -n "$_real_pref_get" ]]; then eval "$_real_pref_get"; else unset -f _task_pref_get; fi
if [[ -n "$_real_promoted" ]]; then eval "$_real_promoted"; else unset -f _gate_record_promoted; fi
if [[ -n "$_real_stats" ]];    then eval "$_real_stats";    else unset -f _gate_record_stats; fi

echo
printf 'TOTAL: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
