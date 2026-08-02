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
cd "$(dirname "$0")/.."
# DIVE-2518: impersonate through the SEALED seam. `USER=agent-x` no longer moves
# the actor — that env path WAS the forgery this ticket closed, and these arms
# were leaning on it. tests/lib/actor_seam.sh explains the migration.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/task-verifier-rail-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

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
run done "$closed_id" >/dev/null
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
