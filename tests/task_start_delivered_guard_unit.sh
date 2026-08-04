#!/usr/bin/env bash
# TIER: nightly — 14.4s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-2510 unit harness — `task start` over a LIVE DELIVERED maker→verifier loop.
#
# THE DEFECT: `task start` was the last status writer with no delivered-loop
# guard. `task done` refuses a non-verifier over a live delivery (DIVE-2007),
# `task reject` refuses the maker (DIVE-2112), `task start` refuses a CLOSED row
# (DIVE-2113) — but a DELIVERED row could still be re-claimed by its own maker,
# and the /goal nudge the heartbeat writes literally instructs it ("claim it with
# '5dive task start <id>'"). So the documented workflow walks a maker into it.
#
# THE HARM IS A MISREPRESENTED STATE, and this harness is where the scope is
# pinned. T6 measures the un-guarded write on the exempt `cli` path: the columns
# a loop delivery actually populates (handoff_delivered_at, maker_agent,
# iteration, result) are untouched, and `task show` keeps printing the handoff
# line at status=in_progress. What moves is status (todo -> in_progress) and
# started_at.
#
# T6 deliberately does NOT assert survival of delivered_at/delivery_ref/
# handoff_ack_at. Those are NULL on a `task done` delivery by construction —
# delivered_at/delivery_ref have exactly one writer (cmd_task_deliver, the
# `task deliver --pr=` flow) and handoff_ack_at is nulled by
# _task_route_to_verifier as part of delivering. T6d pins that directly. An arm
# asserting a NULL column "survived" a write would pass no matter what the code
# did, and stating it in prose invites a reader to hunt a data-loss bug that the
# schema makes impossible.
#
# Arms:
#   T1 liveness — an ordinary (non-delivered) start still works. Without this the
#      whole file passes on a CLI that refuses everything.
#   T2 the fix — the MAKER is refused, and (per the standing rule that rc alone
#      grades the wrong refusal) the ACTION never ran: status/started_at unmoved,
#      and the reason names the verifier and the delivered condition.
#   T3 a THIRD party is refused too (the guard is about the delivered shape, not
#      about the maker specifically).
#   T4 DIVE-1378 must not regress — the VERIFIER's own start is the ACK and works.
#   T5 the REMEDY the refusal promises is real: after `task reject` bounces the
#      row back, the maker's `task start` works again.
#   T6 the `cli` sentinel (unattributable caller: CI, root cron) stays EXEMPT —
#      same carve-out as DIVE-2007, and the arm that measures what the un-guarded
#      write does (and, in T6d, which columns are NULL by construction).
#   T7 SCOPE: this guard is NOT an iteration fix, and it was proposed as one.
#      A maker's re-claim cannot inflate `iteration` — measured, not assumed.
#
# Same isolation contract as tests/task_verifier_rail_unit.sh: source src/
# directly and point STATE_DIR at a throwaway temp dir so the live shared
# tasks.db is NEVER touched. Run: bash tests/task_start_delivered_guard_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NOTE the absence of 2>/dev/null —
# redirecting the source's stderr also swallows the helper's own stderr line,
# which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
# DIVE-2518: impersonate through the SEALED seam. `USER=agent-x` no longer moves
# the actor — that env path WAS the forgery this ticket closed, and these arms
# were leaning on it. tests/lib/actor_seam.sh explains the migration.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/task-start-delivered-unit.XXXXXX)"

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
# The guard reads the ACTOR, so every arm has to SAY who is calling. task_actor()
# falls back to $USER when there is no sudo mapping and no --from.
run_as() { local who="$1" verb="$2"; shift 2
           ( actor_seam_as "${who}"; JSON_MODE=1; "cmd_task_$verb" "$@" ) 2>"$TMP"/err; }
rc_of()  { local who="$1" verb="$2"; shift 2
           ( actor_seam_as "${who}"; JSON_MODE=1; "cmd_task_$verb" "$@" ) >/dev/null 2>"$TMP"/err; printf '%s' "$?"; }
show_of() { ( actor_seam_as nobody; JSON_MODE=0; cmd_task_show "$1" ) 2>&1; }
jf()   { jq -r "$1" 2>/dev/null; }
has()  { [[ "$1" == *"$2"* ]]; }
st()   { db "SELECT status FROM tasks WHERE id=$1;"; }
started() { db "SELECT COALESCE(started_at,'NULL') FROM tasks WHERE id=$1;"; }

JSON_MODE=1
tasks_db_init
db "INSERT INTO agents_org (name, reports_to) VALUES ('boss',NULL),('mak','boss'),('vfy','boss'),('bystander','boss');"

# Build a delivered row: mak files + works it, vfy is the grader, mak delivers.
mk_delivered() {
  local j id
  j=$(run_as mak add --assignee=mak --verifier=vfy --priority=high -- "a real deliverable that needs grading and review")
  id=$(printf '%s' "$j" | jf '.data.id')
  run_as mak start "$id" >/dev/null
  run_as mak done  "$id" --result="the work, as delivered" >/dev/null
  printf '%s' "$id"
}

# --- T1: LIVENESS — an ordinary start is untouched ---------------------------
# A guard that refuses everything would pass every other arm in this file.
plain=$(run_as mak add --assignee=mak --no-verify --priority=high -- "an ordinary task with no verifier rail on it")
plain_id=$(printf '%s' "$plain" | jf '.data.id')
plain_rc=$(rc_of mak start "$plain_id")
[[ "$plain_rc" == "0" && "$(st "$plain_id")" == "in_progress" ]] \
  && ok_t "T1 liveness: an ordinary (non-delivered) 'task start' still works" \
  || bad_t "T1 liveness: an ordinary (non-delivered) 'task start' still works" "rc=$plain_rc status=$(st "$plain_id")"

# --- T2: the MAKER is refused, and the write never happened ------------------
t2=$(mk_delivered)
[[ "$(st "$t2")" == "todo" && "$(started "$t2")" == "NULL" ]] \
  && ok_t "T2a fixture is genuinely DELIVERED (status=todo, started_at cleared)" \
  || bad_t "T2a fixture is genuinely DELIVERED (status=todo, started_at cleared)" "status=$(st "$t2") started=$(started "$t2")"
t2_rc=$(rc_of mak start "$t2")
t2_err=$(cat "$TMP"/err)
[[ "$t2_rc" == "$E_CONFLICT" ]] \
  && ok_t "T2b the maker's 'task start' over a live delivery exits E_CONFLICT" \
  || bad_t "T2b the maker's 'task start' over a live delivery exits E_CONFLICT" "rc=$t2_rc want=$E_CONFLICT :: $t2_err"
# rc alone grades the wrong refusal: assert the ACTION never ran.
[[ "$(st "$t2")" == "todo" && "$(started "$t2")" == "NULL" ]] \
  && ok_t "T2c the refused start did NOT write (status still todo, started_at still NULL)" \
  || bad_t "T2c the refused start did NOT write (status still todo, started_at still NULL)" "status=$(st "$t2") started=$(started "$t2")"
# ...and that the reason names the CONDITION, not just any conflict.
has "$t2_err" "DELIVERED to verifier 'vfy'" \
  && ok_t "T2d the refusal names the verifier holding the row" \
  || bad_t "T2d the refusal names the verifier holding the row" "$t2_err"
# ...and names the REMEDY it promises. T5 grades that the remedy actually works;
# this arm grades that the refusal tells the reader about it. (The DIVE-2510
# ticket arg is policy_refuse's record field, not part of the printed message,
# so asserting on it here would be grading the wrong artifact.)
has "$t2_err" "task reject $(db "SELECT ident FROM tasks WHERE id=${t2};")" \
  && ok_t "T2e the refusal names the bounce that returns the row to the maker" \
  || bad_t "T2e the refusal names the bounce that returns the row to the maker" "$t2_err"

# --- T3: a third party is refused too ----------------------------------------
t3=$(mk_delivered)
t3_rc=$(rc_of bystander start "$t3")
[[ "$t3_rc" == "$E_CONFLICT" && "$(st "$t3")" == "todo" ]] \
  && ok_t "T3 a third party's 'task start' over a live delivery is refused, no write" \
  || bad_t "T3 a third party's 'task start' over a live delivery is refused, no write" "rc=$t3_rc status=$(st "$t3")"

# --- T4: DIVE-1378 must not regress — the VERIFIER's start is the ACK --------
t4=$(mk_delivered)
t4_rc=$(rc_of vfy start "$t4")
[[ "$t4_rc" == "0" && "$(st "$t4")" == "in_progress" ]] \
  && ok_t "T4a the VERIFIER's own 'task start' still works (not caught by the guard)" \
  || bad_t "T4a the VERIFIER's own 'task start' still works (not caught by the guard)" "rc=$t4_rc status=$(st "$t4") :: $(cat "$TMP"/err)"
[[ -n "$(db "SELECT COALESCE(handoff_ack_at,'') FROM tasks WHERE id=${t4};")" ]] \
  && ok_t "T4b ...and it still records the DIVE-1378 handoff ACK" \
  || bad_t "T4b ...and it still records the DIVE-1378 handoff ACK"

# --- T5: the remedy the refusal PROMISES is real ------------------------------
# The refusal tells the maker to wait for the bounce. Grade the remedy half, not
# only the predicate: after `task reject`, the maker's start must work again.
t5=$(mk_delivered)
run_as vfy reject "$t5" --feedback="needs another pass" >/dev/null
[[ "$(db "SELECT assignee FROM tasks WHERE id=${t5};")" == "mak" ]] \
  && ok_t "T5a a reject bounces the row back to the maker" \
  || bad_t "T5a a reject bounces the row back to the maker" "assignee=$(db "SELECT assignee FROM tasks WHERE id=${t5};")"
t5_rc=$(rc_of mak start "$t5")
[[ "$t5_rc" == "0" && "$(st "$t5")" == "in_progress" ]] \
  && ok_t "T5b ...and the maker's 'task start' then works again (the promised remedy)" \
  || bad_t "T5b ...and the maker's 'task start' then works again (the promised remedy)" "rc=$t5_rc status=$(st "$t5") :: $(cat "$TMP"/err)"

# --- T6: `cli` stays EXEMPT — and this is where the SURVIVAL claim is measured -
# An unattributable caller (CI, root cron) is the DIVE-2007 carve-out and keeps
# its old behaviour. That un-guarded write is exactly the mutation the escalation
# described, so measure what it actually does to the row.
t6=$(mk_delivered)
before=$(db "SELECT COALESCE(handoff_delivered_at,'')||'|'||COALESCE(maker_agent,'')||'|'||COALESCE(iteration,0)||'|'||length(COALESCE(result,'')) FROM tasks WHERE id=${t6};")
# CONSTRUCT the caller, never inherit it: task_actor falls through $USER to
# `id -un`, so an EMPTY $USER resolves to whoever is running the harness (an
# agent-* box yields a real agent name and this arm would grade the runner, not
# the sentinel). A non-agent $USER is the shape that actually reaches 'cli'.
t6_rc=$( ( actor_seam_as root; JSON_MODE=1; cmd_task_start "$t6" ) >/dev/null 2>"$TMP"/err; printf '%s' "$?" )
t6_actor=$( actor_seam_as root; task_actor )
if [[ "$t6_actor" != "cli" ]]; then
  # Do not silently grade a carve-out we could not construct.
  bad_t "T6 precondition: a non-agent \$USER must resolve to the 'cli' sentinel" "task_actor=$t6_actor"
else
  t6_wrote=0
  if [[ "$t6_rc" == "0" && "$(st "$t6")" == "in_progress" ]]; then
    t6_wrote=1
    ok_t "T6a the 'cli' sentinel stays exempt (same carve-out as DIVE-2007)"
  else
    bad_t "T6a the 'cli' sentinel stays exempt (same carve-out as DIVE-2007)" "rc=$t6_rc status=$(st "$t6") :: $(cat "$TMP"/err)"
  fi
  # NON-VACUITY: T6b/T6c grade what the UNGUARDED write did to the row. If the
  # write never landed (T6a red — the exemption regressed and `cli` got refused)
  # then the columns are trivially unchanged and the handoff line trivially still
  # renders, so both would pass while measuring NOTHING. Fail them instead of
  # letting a green line stand for an unmeasured claim.
  if [[ $t6_wrote -eq 0 ]]; then
    bad_t "T6b THE SCOPE: the un-guarded write touches ONLY status and started_at" "UNGRADED — the write never landed (T6a red), so survival is vacuous here"
    bad_t "T6c ...and 'task show' STILL renders the handoff line at status=in_progress" "UNGRADED — the write never landed (T6a red)"
  else
    after=$(db "SELECT COALESCE(handoff_delivered_at,'')||'|'||COALESCE(maker_agent,'')||'|'||COALESCE(iteration,0)||'|'||length(COALESCE(result,'')) FROM tasks WHERE id=${t6};")
    [[ "$after" == "$before" && "$before" != "|||0" ]] \
      && ok_t "T6b THE SCOPE: the un-guarded write touches ONLY status and started_at — handoff_delivered_at/maker_agent/iteration/result are all unmoved" \
      || bad_t "T6b THE SCOPE: the un-guarded write touches ONLY status and started_at" "before=$before after=$after"
    has "$(show_of "$t6")" "handoff: delivered (awaiting verifier ACK)" \
      && ok_t "T6c ...and 'task show' STILL renders the handoff line at status=in_progress" \
      || bad_t "T6c ...and 'task show' STILL renders the handoff line at status=in_progress" "$(show_of "$t6")"
    # T6d: the columns a reader might expect to have been "cleared" are NULL by
    # CONSTRUCTION on a `task done` delivery, so observing them NULL after a
    # stray start says nothing about that start. Pinned here so nobody re-derives
    # a data-loss bug from a schema fact.
    nulls=$(db "SELECT COALESCE(delivered_at,'N')||COALESCE(delivery_ref,'N')||COALESCE(handoff_ack_at,'N') FROM tasks WHERE id=${t6};")
    [[ "$nulls" == "NNN" ]] \
      && ok_t "T6d delivered_at/delivery_ref/handoff_ack_at are NULL by construction on a 'task done' delivery (they belong to 'task deliver --pr='), so their NULLness is never evidence of a clearing write" \
      || bad_t "T6d delivered_at/delivery_ref/handoff_ack_at are NULL by construction on a 'task done' delivery" "got=$nulls want=NNN"
  fi
fi

# --- T7: SCOPE — this guard is NOT the iteration fix --------------------------
# It was proposed as one: "the iteration inflation is downstream of the same
# thing and should stop with it." Measured instead of assumed. `iteration` has
# exactly one writer, _task_route_to_verifier, reached only by a `task done` that
# was NOT refused — and DIVE-2007 refuses the maker's done regardless of what
# status a stray start left behind. So a re-claim/re-close cycle cannot inflate
# it, and a climbing iteration means real reject/re-deliver cycles instead.
# This arm is deliberately actor-'mak' (not the exempt `cli`) so it measures the
# refusal path a goal re-issue actually takes.
t7=$(mk_delivered)
t7_i0=$(db "SELECT iteration FROM tasks WHERE id=${t7};")
for _ in 1 2 3; do
  rc_of mak start "$t7" >/dev/null
  rc_of mak done  "$t7" --result="a re-issued goal trying to redeliver" >/dev/null
done
t7_i1=$(db "SELECT iteration FROM tasks WHERE id=${t7};")
[[ "$t7_i0" == "1" && "$t7_i1" == "1" ]] \
  && ok_t "T7 three goal re-issues (start+done as the maker) do NOT inflate iteration — it stays $t7_i1, so this guard is not the iteration fix and a climbing counter has a different cause" \
  || bad_t "T7 three goal re-issues do NOT inflate iteration" "before=$t7_i0 after=$t7_i1 (expected 1 -> 1)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
