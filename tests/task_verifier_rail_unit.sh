#!/usr/bin/env bash
# TIER: nightly — 18.0s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-1880 unit harness — the verifier rail's VISIBILITY + its retro-attach verb.
#
# The defect: `task add --priority=low` silently declined the DIVE-969 verifier
# rail (no notice at filing time), and `--verifier` existed only on `task add`,
# so a mis-filed task could never be railed afterwards — `task done` closed it
# outright on work that was supposed to be graded.
#
# Asserts: (a) the auto-skip is ANNOUNCED in text + JSON with a reason, (b) an
# explicit --verifier forces the rail ON at low priority, (c) --no-verify stays
# quiet (already an explicit opt-out), (d) `task verifier` attaches the rail to
# an already-filed task and `task done` then HANDS OFF instead of closing, and
# (e) its guards (self-grading, closed task, recurring template), and (f) the
# DELIVERED/awaiting-verifier middle state — re-pointing a review mid-flight.
#
# Same isolation contract as tests/task_core_unit.sh: source src/ directly and
# point STATE_DIR at a throwaway temp dir so the live shared tasks.db is NEVER
# touched. Run: bash tests/task_verifier_rail_unit.sh   (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
# DIVE-2518: impersonate through the SEALED seam. `USER=agent-x` no longer moves
# the actor — that env path WAS the forgery this ticket closed, and these arms
# were leaning on it. tests/lib/actor_seam.sh explains the migration.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/task-verifier-rail-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
fixture_box_verify_policy always || exit 1
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; tests expect non-zero exits

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run()  { local verb="$1"; shift; ( JSON_MODE=1; "cmd_task_$verb" "$@" ) 2>"$TMP"/err; }
runt() { local verb="$1"; shift; ( JSON_MODE=0; "cmd_task_$verb" "$@" ) 2>"$TMP"/err; }
# DIVE-2007: the delivered-loop close guard reads the ACTOR, so a case about who
# may close has to say who is calling. task_actor() falls back to $USER when there
# is no sudo mapping and no --from.
run_as() { local who="$1" verb="$2"; shift 2
           ( actor_seam_as "${who}"; JSON_MODE=1; "cmd_task_$verb" "$@" ) 2>"$TMP"/err; }
jf()   { jq -r "$1" 2>/dev/null; }
has()  { [[ "$1" == *"$2"* ]]; }

JSON_MODE=1
tasks_db_init
# Org: alice reports to boss, so the DIVE-969 default has a DISTINCT grader to
# find (the chain's "maker's manager" hop). Without this the default no-ops for
# an unrelated reason and the skip assertions would be untrustworthy.
db "INSERT INTO agents_org (name, reports_to) VALUES ('boss',NULL),('alice','boss'),('carol','boss');"

# --- T1: low priority auto-skips the rail, and SAYS SO (text + JSON) ---------
low_json=$(run add --assignee=alice --priority=low -- "wire up the low priority thing")
low_id=$(printf '%s' "$low_json" | jf '.data.id')
[[ "$(printf '%s' "$low_json" | jf '.data.verifySkipped')" == "true" ]] \
  && ok_t "T1a low priority reports verifySkipped=true in JSON" \
  || bad_t "T1a low priority reports verifySkipped=true in JSON" "$low_json"
[[ "$(printf '%s' "$low_json" | jf '.data.verifySkipReason')" == "low priority" ]] \
  && ok_t "T1b JSON carries the reason" \
  || bad_t "T1b JSON carries the reason" "$low_json"
[[ -z "$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${low_id};")" ]] \
  && ok_t "T1c low priority genuinely has NO verifier (behaviour unchanged)" \
  || bad_t "T1c low priority genuinely has NO verifier (behaviour unchanged)"
low_txt=$(runt add --assignee=alice --priority=low -- "another low priority thing")
has "$low_txt" "NOT verifier-graded (low priority)" \
  && ok_t "T1d the human-readable add line announces the skip" \
  || bad_t "T1d the human-readable add line announces the skip" "$low_txt"
has "$low_txt" "task verifier" \
  && ok_t "T1e the skip notice names the remedy verb" \
  || bad_t "T1e the skip notice names the remedy verb" "$low_txt"

# --- T2: medium still engages the rail, and does NOT report a skip -----------
med_json=$(run add --assignee=alice --priority=medium -- "wire up the medium thing")
med_id=$(printf '%s' "$med_json" | jf '.data.id')
[[ "$(printf '%s' "$med_json" | jf '.data.verifySkipped')" == "false" \
   && "$(printf '%s' "$med_json" | jf '.data.verifyDefaulted')" == "true" \
   && "$(db "SELECT verifier FROM tasks WHERE id=${med_id};")" == "boss" ]] \
  && ok_t "T2 medium engages the rail (verifier=boss), no skip reported" \
  || bad_t "T2 medium engages the rail (verifier=boss), no skip reported" "$med_json"

# --- T3: an explicit --verifier FORCES the rail on at low priority -----------
# (the auto-skip is a default, not a ceiling — this is the add-time escape hatch)
f_json=$(run add --assignee=alice --priority=low --verifier=boss -- "low but must be graded")
f_id=$(printf '%s' "$f_json" | jf '.data.id')
[[ "$(db "SELECT verifier FROM tasks WHERE id=${f_id};")" == "boss" \
   && "$(printf '%s' "$f_json" | jf '.data.verifySkipped')" == "false" ]] \
  && ok_t "T3 --verifier forces the rail ON at low priority" \
  || bad_t "T3 --verifier forces the rail ON at low priority" "$f_json"

# --- T4: a bodyless chore title is skipped with its own reason ---------------
chore_json=$(run add --assignee=alice --priority=medium -- "bump the changelog")
[[ "$(printf '%s' "$chore_json" | jf '.data.verifySkipReason')" == "bodyless chore title" ]] \
  && ok_t "T4 a bodyless chore title reports its own skip reason" \
  || bad_t "T4 a bodyless chore title reports its own skip reason" "$chore_json"

# --- T5: --no-verify is an EXPLICIT opt-out — stays quiet --------------------
nv_txt=$(runt add --assignee=alice --priority=medium --no-verify -- "explicitly ungraded work")
! has "$nv_txt" "NOT verifier-graded" \
  && ok_t "T5 --no-verify does not nag (the opt-out was already visible)" \
  || bad_t "T5 --no-verify does not nag (the opt-out was already visible)" "$nv_txt"

# --- T6: `task verifier` attaches the rail to an ALREADY-FILED task ----------
att=$(run verifier "$low_id" boss)
[[ "$(printf '%s' "$att" | jf '.data.verifier')" == "boss" \
   && "$(db "SELECT verifier FROM tasks WHERE id=${low_id};")" == "boss" ]] \
  && ok_t "T6a task verifier attaches a grader to an already-filed task" \
  || bad_t "T6a task verifier attaches a grader to an already-filed task" "$att"
[[ -n "$(db "SELECT COALESCE(acceptance_criteria,'') FROM tasks WHERE id=${low_id};")" ]] \
  && ok_t "T6b it derives acceptance criteria when the task had none" \
  || bad_t "T6b it derives acceptance criteria when the task had none"

# --- T7: and now `task done` HANDS OFF instead of closing -------------------
# This is the whole point: before the fix, this same `done` closed the task.
run start "$low_id" >/dev/null
done_json=$(run done "$low_id" --result="maker says ready")
low_status=$(db "SELECT status FROM tasks WHERE id=${low_id};")
low_owner=$(db "SELECT assignee FROM tasks WHERE id=${low_id};")
[[ "$low_status" != "done" && "$low_owner" == "boss" ]] \
  && ok_t "T7 'task done' on the retro-railed task routes to the verifier, not closed" \
  || bad_t "T7 'task done' on the retro-railed task routes to the verifier, not closed" \
           "status=$low_status owner=$low_owner :: $done_json"

# --- T8: --accept overrides the derived criteria ----------------------------
run verifier "$f_id" carol --accept="ship it green" >/dev/null
[[ "$(db "SELECT acceptance_criteria FROM tasks WHERE id=${f_id};")" == "ship it green" ]] \
  && ok_t "T8 --accept overrides the criteria and the grader can be re-pointed" \
  || bad_t "T8 --accept overrides the criteria and the grader can be re-pointed"

# --- T9: guards --------------------------------------------------------------
self_out=$(run verifier "$med_id" alice); self_rc=$?
(( self_rc != 0 )) && has "$(cat "$TMP"/err)$self_out" "can't grade itself" \
  && ok_t "T9a refuses to make the assignee its own grader" \
  || bad_t "T9a refuses to make the assignee its own grader" "rc=$self_rc $self_out $(cat "$TMP"/err)"

closed_json=$(run add --assignee=alice --priority=low -- "already finished chore")
closed_id=$(printf '%s' "$closed_json" | jf '.data.id')
run done "$closed_id" --result="chore finished (DIVE-2773: a first close must carry a reason)" >/dev/null
cl_out=$(run verifier "$closed_id" boss); cl_rc=$?
(( cl_rc != 0 )) && has "$(cat "$TMP"/err)$cl_out" "task reject" \
  && ok_t "T9b refuses to retro-grade a CLOSED task and points at 'task reject'" \
  || bad_t "T9b refuses to retro-grade a CLOSED task and points at 'task reject'" "rc=$cl_rc $cl_out $(cat "$TMP"/err)"

tmpl_json=$(run add --recurring="0 2 * * *" -- "nightly sweep")
tmpl_id=$(printf '%s' "$tmpl_json" | jf '.data.id')
tm_out=$(run verifier "$tmpl_id" boss); tm_rc=$?
(( tm_rc != 0 )) \
  && ok_t "T9c refuses to rail a recurring TEMPLATE" \
  || bad_t "T9c refuses to rail a recurring TEMPLATE" "rc=$tm_rc $tm_out"

miss_out=$(run verifier "$med_id"); miss_rc=$?
(( miss_rc != 0 )) \
  && ok_t "T9d requires both a task and a grader" \
  || bad_t "T9d requires both a task and a grader" "rc=$miss_rc $miss_out"

# --- T10: the DELIVERED / awaiting-verifier middle state ---------------------
# After the T7 handoff the task sits status='todo' with assignee=boss (the
# GRADER, not the maker) and maker_agent=alice. Re-pointing the grader here must
# move the queue with it, or the row claims a grader who does not hold the task.
mid_before_iter=$(db "SELECT iteration FROM tasks WHERE id=${low_id};")
# DIVE-5098: the outgoing grader's /goal wake has already CLAIMED the review
# (in_progress, started_at stamped) — the state DIVE-618 was re-pointed from.
db "UPDATE tasks SET status='in_progress', started_at=datetime('now') WHERE id=${low_id};"
rp=$(run verifier "$low_id" carol)
mid_status=$(db "SELECT status FROM tasks WHERE id=${low_id};")
mid_started=$(db "SELECT COALESCE(started_at,'') FROM tasks WHERE id=${low_id};")
[[ "$mid_status" == "todo" && -z "$mid_started" ]] \
  && ok_t "T10g a re-point of a CLAIMED review puts it back at todo, so the new grader's tick dispatches it (DIVE-5098)" \
  || bad_t "T10g a re-point of a CLAIMED review puts it back at todo, so the new grader's tick dispatches it (DIVE-5098)" \
           "status=$mid_status started_at=$mid_started :: $rp"
mid_owner=$(db "SELECT assignee FROM tasks WHERE id=${low_id};")
mid_vf=$(db "SELECT verifier FROM tasks WHERE id=${low_id};")
mid_maker=$(db "SELECT maker_agent FROM tasks WHERE id=${low_id};")
mid_ack=$(db "SELECT COALESCE(handoff_ack_at,'') FROM tasks WHERE id=${low_id};")
mid_iter=$(db "SELECT iteration FROM tasks WHERE id=${low_id};")
[[ "$mid_owner" == "carol" && "$mid_vf" == "carol" && "$mid_maker" == "alice" \
   && -z "$mid_ack" && "$mid_iter" == "$mid_before_iter" ]] \
  && ok_t "T10a mid-review re-point moves the queue to the new grader (maker + iteration kept, ACK cleared)" \
  || bad_t "T10a mid-review re-point moves the queue to the new grader (maker + iteration kept, ACK cleared)" \
           "owner=$mid_owner vf=$mid_vf maker=$mid_maker ack=$mid_ack iter=$mid_iter/$mid_before_iter :: $rp"
[[ "$(printf '%s' "$rp" | jf '.data.repointed')" == "true" \
   && "$(printf '%s' "$rp" | jf '.data.midReview')" == "true" ]] \
  && ok_t "T10b the re-point is reported as such in JSON" \
  || bad_t "T10b the re-point is reported as such in JSON" "$rp"

# Pointing at the grader who ALREADY holds it is idempotent, not an error, and
# must not disturb the handoff clock (that clock times the review, not this call).
del_before=$(db "SELECT handoff_delivered_at FROM tasks WHERE id=${low_id};")
noop=$(run verifier "$low_id" carol --accept="refined bar"); noop_rc=$?
del_after=$(db "SELECT handoff_delivered_at FROM tasks WHERE id=${low_id};")
(( noop_rc == 0 )) && [[ "$del_before" == "$del_after" \
   && "$(db "SELECT acceptance_criteria FROM tasks WHERE id=${low_id};")" == "refined bar" ]] \
  && ok_t "T10c re-pointing at the SAME grader is an idempotent no-op on the handoff clock" \
  || bad_t "T10c re-pointing at the SAME grader is an idempotent no-op on the handoff clock" \
           "rc=$noop_rc before=$del_before after=$del_after"

# Mid-review the MAKER is maker_agent — not the assignee (who is the outgoing
# grader). Handing the review back to the maker is still self-grading.
mk_out=$(run verifier "$low_id" alice); mk_rc=$?
(( mk_rc != 0 )) && has "$(cat "$TMP"/err)$mk_out" "maker" \
  && ok_t "T10d mid-review, re-pointing at the MAKER is refused as self-grading" \
  || bad_t "T10d mid-review, re-pointing at the MAKER is refused as self-grading" "rc=$mk_rc $mk_out $(cat "$TMP"/err)"

# DIVE-2007 changed what "the grader's own done" MEANS here. It used to be
# positional — verifier==assignee, satisfied by the re-point alone, so ANY caller
# closed it. It is now the ACTOR: only carol closes carol's review. Both halves
# asserted, maker-first, so the case can no longer pass on position alone.
mk_close=$(run_as alice done "$low_id" --result="maker sneaks a close"); mk_close_rc=$?
(( mk_close_rc != 0 )) && [[ "$(db "SELECT status FROM tasks WHERE id=${low_id};")" == "todo" ]] \
  && ok_t "T10e the MAKER's done on the re-pointed review is refused (DIVE-2007)" \
  || bad_t "T10e the MAKER's done on the re-pointed review is refused (DIVE-2007)" \
           "rc=$mk_close_rc status=$(db "SELECT status FROM tasks WHERE id=${low_id};") $(cat "$TMP"/err)"
run_as carol done "$low_id" --result="graded PASS" >/dev/null
[[ "$(db "SELECT status FROM tasks WHERE id=${low_id};")" == "done" ]] \
  && ok_t "T10f the re-pointed grader's own 'task done' closes the task" \
  || bad_t "T10f the re-pointed grader's own 'task done' closes the task" \
           "status=$(db "SELECT status FROM tasks WHERE id=${low_id};") $(cat "$TMP"/err)"

# --- T11: NO WORD LIST IN CORE (DIVE-9262) ---------------------------------
# The title-word filing cap (DIVE-2681) and its grader skip moved to the devteam
# plugin (its arms: 5dive-plugins tests/devteam/filing_ratio_cap_unit.sh). On a
# box without it, a customer's row that happens to say "harness", "rails" or
# "smoke" must file like any other row and keep its grader, however many such
# titles the board already holds. Declared prod so the arms are not vacuous: the
# old cap only ever enforced on the production board.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
db "DELETE FROM tasks;"
for i in 1 2 3 4 5 6 7 8 9 10; do
  run add --assignee=alice --priority=medium -- "the smoke harness lint rails sweep ${i}" >/dev/null
done
declare -F _task_internal_subject_reason >/dev/null 2>&1 \
  && bad_t "T11a core defines no title-word classifier" "_task_internal_subject_reason is defined" \
  || ok_t "T11a core defines no title-word classifier"
w_json=$(run add --assignee=alice --priority=medium -- "upgrade rails and fix the smoke test harness"); w_rc=$?
w_id=$(printf '%s' "$w_json" | jf '.data.id')
[[ "$w_rc" == 0 && -n "$w_id" && "$w_id" != "null" \
   && "$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${w_id};")" == "boss" \
   && "$(db "SELECT COUNT(*) FROM policy_refusals WHERE policy LIKE 'filing-cap%';")" == "0" ]] \
  && ok_t "T11b on a board of 10 'machinery' titles, an 11th files, keeps its grader, and nothing is refused" \
  || bad_t "T11b on a board of 10 'machinery' titles, an 11th files, keeps its grader, and nothing is refused" \
           "rc=$w_rc $w_json refusals=$(db "SELECT COUNT(*) FROM policy_refusals WHERE policy LIKE 'filing-cap%';") $(cat "$TMP"/err)"
unset FIVEDIVE_PROD_TASKS_DB

# --- T13: DIVE-2812 — an accept-write is RECORDED -----------------------------
# `task verifier --accept=` is the only writer of acceptance_criteria on an
# existing row, and it wrote NOTHING to the audit log: a maker could rewrite the
# bar they are graded against and leave no trace of who did it or what it said
# before. These arms grade the call SITE (condition + payload) by capturing
# `_task_store_audit_log`'s args — the real writer is shared with `set-body` and
# withholds on a non-production store by design (DIVE-2010), so a harness on a
# throwaway db cannot observe the row itself. Capturing the args is therefore
# what is observable here; the arms below still fail if the call is deleted, if
# it fires on a non-edit, or if it drops the actor or the prior text.
db "DELETE FROM tasks;"
AUDIT_CAP="$TMP/audit-capture.log"
: > "$AUDIT_CAP"
_task_store_audit_log() { printf '%s\n' "$*" >> "$AUDIT_CAP"; return 0; }
acc_id=$(run add --assignee=alice --verifier=carol --accept="ORIGINAL BAR: the poll is removed" -- "a row filed with a criterion" | jf '.data.id')

# T13a: re-pointing/refreshing the grader WITHOUT --accept is not an edit to the
# bar and must write NO row. Without this arm a call that fires unconditionally
# would pass T13b and bury real edits in noise.
run verifier "$acc_id" carol >/dev/null
[[ ! -s "$AUDIT_CAP" ]] \
  && ok_t "T13a no --accept writes no accept-audit row (a re-point is not an edit to the bar)" \
  || bad_t "T13a no --accept writes no accept-audit row (a re-point is not an edit to the bar)" "$(cat "$AUDIT_CAP")"

# T13b: an --accept that MOVES the text writes one row carrying the actor and
# the PRIOR criterion, so the bar a row was originally filed under is
# recoverable from the log by someone who was not there.
out13=$(run_as alice verifier "$acc_id" carol --accept="SOFTENED BAR: anything ships")
cap=$(cat "$AUDIT_CAP")
has "$cap" "task verifier set-accept" && has "$cap" "actor=alice" \
  && has "$cap" "prior=ORIGINAL BAR: the poll is removed" && has "$cap" "prior_len=33" \
  && ok_t "T13b an accept-write records cmd + actor + prior text + prior_len" \
  || bad_t "T13b an accept-write records cmd + actor + prior text + prior_len" "$cap"

# T13c: and the person typing it is told the bar moved, with the prior text in
# the JSON — the audit row serves the later reader, this serves the only person
# who can still catch a wrong overwrite while it is undoable.
[[ "$(printf '%s' "$out13" | jf '.data.acceptanceChanged')" == "true" \
   && "$(printf '%s' "$out13" | jf '.data.priorAcceptanceCriteria')" == "ORIGINAL BAR: the poll is removed" ]] \
  && ok_t "T13c the command echoes acceptanceChanged + the prior criterion" \
  || bad_t "T13c the command echoes acceptanceChanged + the prior criterion" "$out13"

# T13d: re-passing the IDENTICAL criterion is a no-op on the bar — no row, and
# the command does not claim a change. (Positive control that T13b's row came
# from the text moving, not merely from --accept being present.)
: > "$AUDIT_CAP"
out13d=$(run verifier "$acc_id" carol --accept="SOFTENED BAR: anything ships")
[[ ! -s "$AUDIT_CAP" && "$(printf '%s' "$out13d" | jf '.data.acceptanceChanged')" == "false" ]] \
  && ok_t "T13d an identical --accept is not an edit (no row, acceptanceChanged=false)" \
  || bad_t "T13d an identical --accept is not an edit (no row, acceptanceChanged=false)" "$(cat "$AUDIT_CAP") $out13d"

# T13e: the write still LANDS — the audit row must not have displaced the
# mutation this verb exists to perform.
[[ "$(db "SELECT acceptance_criteria FROM tasks WHERE id=${acc_id};")" == "SOFTENED BAR: anything ships" ]] \
  && ok_t "T13e the criterion itself is still rewritten (auditing did not replace the write)" \
  || bad_t "T13e the criterion itself is still rewritten (auditing did not replace the write)" "$(db "SELECT acceptance_criteria FROM tasks WHERE id=${acc_id};")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
