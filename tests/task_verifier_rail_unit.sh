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
rp=$(run verifier "$low_id" carol)
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

# --- T11: THE FILING CAP (DIVE-2681) ----------------------------------------
# Folded into this harness rather than given its own file: it is a second reason
# the SAME rail declines, and it reaches the board through the SAME announced
# skip path T1 covers. A separate harness would re-pay this file's setup to
# assert against the same code (5dive-cli/CLAUDE.md: merge by subject).
#
# The window is fleet-wide over the last 20 standard rows, so these arms build
# their own ratio explicitly instead of inheriting whatever T1-T10 happened to
# leave behind — an assertion that depends on the arms above it is not an
# assertion, it is an ordering.
db "DELETE FROM tasks;"
for i in 1 2 3 4 5 6 7 8 9 10; do
  run add --assignee=alice --priority=medium -- "ship customer feature number ${i}" >/dev/null
done

# T11a: the classifier is a candidate set — assert it on a title, not a vibe.
[[ -n "$(_task_internal_subject_reason 'the smoke-gate harness dies on pipefail')" \
   && -z "$(_task_internal_subject_reason 'web push on the dashboard PWA')" ]] \
  && ok_t "T11a classifier hits our own machinery and leaves a product title alone" \
  || bad_t "T11a classifier hits our own machinery and leaves a product title alone" \
           "internal='$(_task_internal_subject_reason 'the smoke-gate harness dies on pipefail')' product='$(_task_internal_subject_reason 'web push on the dashboard PWA')'"

# T11b: UNDER the cap, an internal row is accepted — and books NO grading pass.
# This is the half that moves tokens: the row used to cost a grading round-trip.
int_json=$(run add --assignee=alice --priority=high -- "the release-cut harness is red")
int_id=$(printf '%s' "$int_json" | jf '.data.id')
[[ -n "$int_id" && "$int_id" != "null" \
   && "$(printf '%s' "$int_json" | jf '.data.verifySkipReason')" == "internal machinery" \
   && -z "$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${int_id};")" ]] \
  && ok_t "T11b an internal row under the cap is accepted and books NO verifier" \
  || bad_t "T11b an internal row under the cap is accepted and books NO verifier" "$int_json"

# T11c: an explicit --verifier still forces grading ON. The skip is a default,
# not a ceiling — same contract T3 asserts for the low-priority skip.
fv_json=$(run add --assignee=alice --priority=high --verifier=boss -- "the CI job budget-report must be graded")
fv_id=$(printf '%s' "$fv_json" | jf '.data.id')
[[ "$(db "SELECT verifier FROM tasks WHERE id=${fv_id};")" == "boss" ]] \
  && ok_t "T11c --verifier forces grading ON for an internal row" \
  || bad_t "T11c --verifier forces grading ON for an internal row" "$fv_json"

# T11d: OVER the cap, the next internal row is REFUSED at the keystroke.
for i in 1 2 3 4 5; do
  run add --assignee=alice --priority=medium -- "worktree cleanup sweep ${i}" >/dev/null
done
over_out=$(run add --assignee=alice --priority=high -- "another harness is flaky"); over_rc=$?
(( over_rc != 0 )) && has "$(cat "$TMP"/err)$over_out" "filing cap" \
  && ok_t "T11d over the cap, an internal row is REFUSED" \
  || bad_t "T11d over the cap, an internal row is REFUSED" "rc=$over_rc $over_out $(cat "$TMP"/err)"

# T11e: the refusal NAMES both escapes. A gate that refuses without naming the
# way through is the defect DIVE-1880 fixed one control over.
has "$(cat "$TMP"/err)$over_out" "--already-blocked" \
  && has "$(cat "$TMP"/err)$over_out" "--customer" \
  && ok_t "T11e the refusal names both declared escapes" \
  || bad_t "T11e the refusal names both declared escapes" "$(cat "$TMP"/err)"

# T11f: a CUSTOMER-facing row is never capped, however full the window is.
cust_json=$(run add --assignee=alice --priority=high -- "dashboard billing page renders a stale plan")
cust_id=$(printf '%s' "$cust_json" | jf '.data.id')
[[ -n "$cust_id" && "$cust_id" != "null" ]] \
  && ok_t "T11f a customer-surface row is unaffected by a full window" \
  || bad_t "T11f a customer-surface row is unaffected by a full window" "$cust_json"

# T11g: --customer overrides a WRONG classification. The product row that named
# this arm is real: "Free OSS web UI: three views (org chart, queue, gates)" is a
# customer surface that matches the scan on two words.
fp_json=$(run add --assignee=alice --priority=high --customer -- "free OSS web UI: org chart, queue and gates served by the CLI")
fp_id=$(printf '%s' "$fp_json" | jf '.data.id')
[[ -n "$fp_id" && "$fp_id" != "null" \
   && "$(db "SELECT verifier FROM tasks WHERE id=${fp_id};")" == "boss" ]] \
  && ok_t "T11g --customer clears a false positive AND restores its grading" \
  || bad_t "T11g --customer clears a false positive AND restores its grading" "$fp_json"

# T11h: --already-blocked lands the row over the cap AND records why on it.
# An exception that leaves no trace is an opt-out, not an exception.
ab_json=$(run add --assignee=alice --priority=high --already-blocked="took task done down fleet-wide for 40m" -- "the merge gate harness is wrong")
ab_id=$(printf '%s' "$ab_json" | jf '.data.id')
[[ -n "$ab_id" && "$ab_id" != "null" ]] \
  && has "$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${ab_id};")" "took task done down fleet-wide" \
  && ok_t "T11h --already-blocked lands over the cap and records the reason in the body" \
  || bad_t "T11h --already-blocked lands over the cap and records the reason in the body" "$ab_json"

# T11i: the fleet kill-switch, so an incident is never gated by a filing rule.
kill_json=$(FIVE_FILING_CAP=0 run add --assignee=alice --priority=high -- "yet another harness is flaky")
[[ "$(printf '%s' "$kill_json" | jf '.data.id')" != "null" \
   && -n "$(printf '%s' "$kill_json" | jf '.data.id')" ]] \
  && ok_t "T11i FIVE_FILING_CAP=0 disables the refusal fleet-wide" \
  || bad_t "T11i FIVE_FILING_CAP=0 disables the refusal fleet-wide" "$kill_json"

# --- T12: THE CAP PATH SURVIVES `set -e`, which is how it ships -------------
# This harness runs under `set +e` (line ~52) so that arms can assert non-zero
# exits. That is correct for the arms — and it meant T11a-i could not see the
# defect they were supposedly covering: `_task_internal_recent_ratio` printed
# with no trailing newline, the caller's `read` returned 1 at EOF, and under
# src/header.sh's real `set -euo pipefail` `task add` died before any error
# path printed. 32/32 green, and the shipped command was broken for every
# internal title. A test that disables the condition it is testing under is
# not a test of that condition.
#
# So this arm restores the SHIPPING shell options around the call and asserts
# the classifier path returns a value instead of killing the shell.
db "DELETE FROM tasks;"
for i in 1 2 3 4 5 6 7 8; do
  run add --assignee=alice --priority=medium -- "ship customer feature ${i}" >/dev/null
done
sete_out=$( set -euo pipefail
            _task_internal_recent_ratio 20 ) ; sete_rc=$?
[[ $sete_rc -eq 0 && "$sete_out" =~ ^[0-9]+\ [0-9]+$ ]] \
  && ok_t "T12a the ratio helper returns 'N M' under set -euo pipefail (not a silent death)" \
  || bad_t "T12a the ratio helper returns 'N M' under set -euo pipefail (not a silent death)" "rc=$sete_rc out='$sete_out'"

# T12b: the CALLER's read is the site that actually died. Reproduce the exact
# construct under the shipping options, with a positive control on the value.
readback=$( set -euo pipefail
            _h=0; _w=0; read -r _h _w < <(_task_internal_recent_ratio 20) || true
            printf 'h=%s w=%s' "$_h" "$_w" ) ; read_rc=$?
[[ $read_rc -eq 0 && "$readback" == "h=0 w=8" ]] \
  && ok_t "T12b the caller's read survives set -e AND reads the right window (0 internal of 8)" \
  || bad_t "T12b the caller's read survives set -e AND reads the right window (0 internal of 8)" "rc=$read_rc '$readback'"

# T12c: end-to-end — an internal-titled add under the shipping options either
# creates a row or refuses, but ALWAYS says something. Silence is the bug.
e2e_out=$( set -euo pipefail
           JSON_MODE=0; cmd_task_add --assignee=alice --priority=high -- "the nightly sweep harness is flaky" 2>&1 ) ; e2e_rc=$?
[[ -n "$e2e_out" ]] \
  && ok_t "T12c an internal-titled add under set -e produces OUTPUT, never a silent exit" \
  || bad_t "T12c an internal-titled add under set -e produces OUTPUT, never a silent exit" "rc=$e2e_rc (empty output)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
