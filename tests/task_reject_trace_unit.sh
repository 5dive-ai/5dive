#!/usr/bin/env bash
# DIVE-2777 — a reject must leave a TRACE, and the list surface must show the clocks.
#
# Three properties, one subject (what a bounce records), so one harness:
#
#   A/B  `task reject` on the ORDINARY path — a row DELIVERED to a verifier, i.e.
#        status `todo` — preserves the maker's delivered text. This is the arm the
#        old hand-rolled predicate could not pass: it fired only on `done` rows,
#        and a delivered row is `todo` BY the rail's own contract, so the branch
#        never ran on the path it existed to protect. Graded on status=todo
#        deliberately; the `done` sample is the one that cannot fail.
#   D/E  the bounce emits a `task.rejected` lifecycle event. There was no such kind
#        in the table before this change, so a reject's only trace was
#        handoff_rejected_at — which the NEXT delivery NULLs by design (it is an
#        iteration signal, not a log). Rejected -> re-delivered -> closed left
#        nothing at all, which is why the historical damage count is a floor.
#   C    `task ls --json` carries handoff_delivered_at / handoff_rejected_at.
#        ASSERTED ON A ROW WHOSE DB VALUE IS NON-NULL, and that is the whole point
#        of the arm: this projection drops null-valued keys generally, so a fixture
#        with null clocks passes identically before and after the fix. A null
#        sample cannot separate ABSENCE from EMPTINESS. Arm C2 is the paired
#        negative control — handoff_ack_at, which was never broken, must stay
#        present on a non-null row (this change must not "fix" it).
#
# Run: bash tests/task_reject_trace_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src

TMP="$(mktemp -d /tmp/task-reject-trace-unit.XXXXXX)"

# shellcheck disable=SC1090
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
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
as() { local who="$1"; shift; ( actor_seam_as "${who}"; "$@" ) 2>"$TMP"/err; }

res_of()    { db "SELECT COALESCE(result,'') FROM tasks WHERE ident=$(sqlq "$1");"; }
status_of() { db "SELECT status FROM tasks WHERE ident=$(sqlq "$1");"; }
col_of()    { db "SELECT COALESCE($2,'') FROM tasks WHERE ident=$(sqlq "$1");"; }
events_of() { db "SELECT COUNT(*) FROM lifecycle_events WHERE ident=$(sqlq "$1") AND kind=$(sqlq "$2");"; }

# PRECONDITION, and it is not ceremony: every assertion below reads a row this
# helper built. If impersonation or the seed is broken the arms go vacuous — they
# would report a passing reject that never ran as an actor at all.
[[ "$( ( actor_seam_as dev; task_actor ) )" == "dev" ]] \
  && ok_t "harness can impersonate an actor (task_actor -> dev)" \
  || bad_t "actor impersonation" "every arm below would be vacuous"

MAKER_TEXT="MAKER RESULT: implemented the thing, graded-sha abc1234, 9/9 unit"
# seed -> a task DELIVERED to its verifier: maker=dev, verifier=main, status todo,
# assignee main, handoff_delivered_at NON-NULL. That last property is what arm C
# needs and is the reason the fixture delivers rather than just creating a row.
seed() {
  local out id; out=$(JSON_MODE=1 cmd_task_add "$1" --assignee=dev --verifier=main \
                        --accept="must do the thing" 2>"$TMP"/err)
  id=$(printf '%s' "$out" | jq -r '.data.ident // empty' 2>/dev/null)
  as dev cmd_task_done "$id" --result="$MAKER_TEXT" >/dev/null
  printf '%s' "$id"
}

# --- A: the ORDINARY bounce. status is `todo` — the discriminating sample.
A=$(seed "A verifier bounces a delivered row")
[[ "$(status_of "$A")" == "todo" && -n "$(col_of "$A" handoff_delivered_at)" ]] \
  && ok_t "A fixture is a DELIVERED row (status todo, handoff_delivered_at set)" \
  || bad_t "A fixture" "status=$(status_of "$A") delivered_at='$(col_of "$A" handoff_delivered_at)' — arms A-E would grade the wrong path"
out=$(as main cmd_task_reject "$A" --feedback="needs a test"); rc=$?
(( rc == 0 )) && ok_t "A the verifier's bounce succeeds (rc=0)" \
  || bad_t "A reject broken" "rc=$rc $(cat "$TMP"/err)"

# --- B: THE DEFECT. The maker's text must still be there.
[[ "$(res_of "$A")" == *"$MAKER_TEXT"* ]] \
  && ok_t "B the maker's delivered result SURVIVES a reject on the todo path (DIVE-2762 class)" \
  || bad_t "B maker result destroyed" "this is the defect: result=$(res_of "$A")"
[[ "$(res_of "$A")" == *"main rejected"* ]] \
  && ok_t "B the rejection text is recorded alongside it" || bad_t "B feedback missing" "$(res_of "$A")"

# --- D: the LIFECYCLE EVENT. Absent entirely before this change.
[[ "$(events_of "$A" task.rejected)" == "1" ]] \
  && ok_t "D the bounce emits exactly one task.rejected lifecycle event" \
  || bad_t "D no event" "count=$(events_of "$A" task.rejected) — a reject leaves no durable trace"

# --- E: the event must be READABLE, not just present. Actor, iteration, and the
# hash of the text it superseded — the last is what makes a later reader able to
# say WHICH delivery this bounce displaced (compare to task.delivered's
# output_hash for the same ident).
ev_detail=$(db "SELECT COALESCE(detail,'') FROM lifecycle_events WHERE ident=$(sqlq "$A") AND kind='task.rejected';")
ev_actor=$(db  "SELECT COALESCE(actor,'')  FROM lifecycle_events WHERE ident=$(sqlq "$A") AND kind='task.rejected';")
ev_out=$(db    "SELECT COALESCE(output_hash,'') FROM lifecycle_events WHERE ident=$(sqlq "$A") AND kind='task.rejected';")
dl_out=$(db    "SELECT COALESCE(output_hash,'') FROM lifecycle_events WHERE ident=$(sqlq "$A") AND kind='task.delivered';")
[[ "$ev_actor" == *main* ]] && ok_t "E event attributes the bounce to the actor who ran it" \
  || bad_t "E actor" "actor='$ev_actor'"
[[ "$ev_detail" == *"iteration"* && "$ev_detail" == *"superseded"* ]] \
  && ok_t "E detail names the iteration and that a prior result was superseded" \
  || bad_t "E detail" "detail='$ev_detail'"
# NON-VACUITY on the hash: assert it EQUALS the delivered event's hash rather than
# merely being non-empty. Equality is what proves the event points at the specific
# delivery it displaced; a non-empty check passes on any hash of anything.
[[ -n "$dl_out" && "$ev_out" == "$dl_out" ]] \
  && ok_t "E output_hash == the task.delivered hash: the event names WHICH delivery it displaced" \
  || bad_t "E hash does not tie back" "rejected='$ev_out' delivered='$dl_out'"

# --- C: THE LIST PROJECTION, on a NON-NULL clock.
# C uses a SECOND row, still delivered and never rejected, so handoff_delivered_at
# is non-null and handoff_rejected_at is null. Both states are needed: the first
# discriminates omission from emptiness, the second is the sibling that must not
# regress into an error.
C=$(seed "C list projection carries the handoff clocks")
c_delivered=$(col_of "$C" handoff_delivered_at)
[[ -n "$c_delivered" ]] \
  && ok_t "C fixture has a NON-NULL handoff_delivered_at (a null one cannot falsify)" \
  || bad_t "C fixture" "clock is null — this arm would pass before AND after the fix"
ls_json=$(JSON_MODE=1 cmd_task_ls --all 2>"$TMP"/err)
c_row=$(printf '%s' "$ls_json" | jq -c --arg i "$C" '.data.tasks[] | select(.ident==$i)' 2>/dev/null)
[[ -n "$c_row" ]] && ok_t "C the row is present in task ls --json" \
  || bad_t "C row missing from ls" "$(cat "$TMP"/err)"
# has() distinguishes ABSENT from null; a .get()-style read cannot, which is
# exactly how the original report ("ls NULLS them") came out wrong twice.
[[ "$(printf '%s' "$c_row" | jq -r 'has("handoff_delivered_at")')" == "true" ]] \
  && ok_t "C handoff_delivered_at is PRESENT as a key (has(), not a null-read)" \
  || bad_t "C key absent" "the defect: consumers read None and conclude never-delivered"
[[ "$(printf '%s' "$c_row" | jq -r '.handoff_delivered_at // ""')" == "$c_delivered" ]] \
  && ok_t "C its value matches the DB exactly ('$c_delivered')" \
  || bad_t "C value wrong" "json='$(printf '%s' "$c_row" | jq -r '.handoff_delivered_at')' db='$c_delivered'"
# handoff_rejected_at on a REJECTED row: the second field, also on a non-null value.
a_rejected=$(col_of "$A" handoff_rejected_at)
a_row=$(printf '%s' "$ls_json" | jq -c --arg i "$A" '.data.tasks[] | select(.ident==$i)' 2>/dev/null)
[[ -n "$a_rejected" ]] \
  && ok_t "C2 fixture A has a NON-NULL handoff_rejected_at after the bounce" \
  || bad_t "C2 fixture" "clock is null — the arm below cannot falsify"
[[ "$(printf '%s' "$a_row" | jq -r '.handoff_rejected_at // ""')" == "$a_rejected" ]] \
  && ok_t "C2 handoff_rejected_at is emitted and matches the DB ('$a_rejected')" \
  || bad_t "C2 rejected clock missing from ls" "json='$(printf '%s' "$a_row" | jq -r '.handoff_rejected_at')' db='$a_rejected'"

# --- C3: NEGATIVE CONTROL. handoff_ack_at was never broken and this change must
# not touch it. On a row whose ack clock is NON-NULL it must still be emitted.
# Without this arm, "add the missing fields" and "rewrite the handoff family"
# grade identically.
db "UPDATE tasks SET handoff_ack_at=datetime('now') WHERE ident=$(sqlq "$C");"
ack_db=$(col_of "$C" handoff_ack_at)
c_row2=$(JSON_MODE=1 cmd_task_ls --all 2>/dev/null | jq -c --arg i "$C" '.data.tasks[] | select(.ident==$i)')
[[ -n "$ack_db" && "$(printf '%s' "$c_row2" | jq -r '.handoff_ack_at // ""')" == "$ack_db" ]] \
  && ok_t "C3 handoff_ack_at still emitted unchanged (it already worked; two fields added, not three)" \
  || bad_t "C3 ack clock regressed" "json='$(printf '%s' "$c_row2" | jq -r '.handoff_ack_at')' db='$ack_db'"

# --- F: THE SECOND WRITE SITE. `reject` has TWO `UPDATE ... SET result=` paths:
# the ordinary bounce-back, and the max_iterations ESCALATION, which `return`s
# early. The escalation is the TERMINAL reject — the one that ends the loop and
# parks it on a human — so a trace that covers only the routine bounce goes silent
# on the bounce that matters most. Emitting from one site and not the other would
# rebuild this ticket's own defect inside the fix for it (DIVE-2483 routed three
# verbs through the shared guard and left reject's fourth site hand-rolled).
F=$(seed "F reject at the iteration cap escalates")
db "UPDATE tasks SET max_iterations=1, iteration=1 WHERE ident=$(sqlq "$F");"
out=$(as main cmd_task_reject "$F" --feedback="still wrong at the cap"); rc=$?
[[ "$(db "SELECT COALESCE(need_type,'') FROM tasks WHERE ident=$(sqlq "$F");")" == "manual" ]] \
  && ok_t "F fixture took the ESCALATION branch (a manual gate was filed), not the bounce-back" \
  || bad_t "F wrong branch" "need_type='$(db "SELECT COALESCE(need_type,'') FROM tasks WHERE ident=$(sqlq "$F");")' — arm F below would grade the ordinary path twice"
[[ "$(events_of "$F" task.rejected)" == "1" ]] \
  && ok_t "F the escalating reject ALSO emits task.rejected (both write sites, one emitter)" \
  || bad_t "F escalation emits nothing" "count=$(events_of "$F" task.rejected) — the terminal reject leaves no trace"
f_detail=$(db "SELECT COALESCE(detail,'') FROM lifecycle_events WHERE ident=$(sqlq "$F") AND kind='task.rejected';")
[[ "$f_detail" == *"escalated"* && "$f_detail" == *"cap"* ]] \
  && ok_t "F the event says it ESCALATED rather than bounced — the two dispositions are distinguishable" \
  || bad_t "F disposition" "detail='$f_detail'"

# --- G: idem-key collision. ledger_emit uses INSERT OR IGNORE keyed on
# kind|ident|task_id|hash(detail+in+out), so two bounces that hash alike would
# SILENTLY collapse to one row — and a dropped event is invisible by construction.
# A second reject at the same iteration with the SAME feedback is the shape that
# tests it; the prior text differs (it now contains the first rejection), so the
# hashes must differ and both rows must survive.
G=$(seed "G two bounces with identical feedback both record")
as main cmd_task_reject "$G" --feedback="same words twice" >/dev/null
as main cmd_task_reject "$G" --feedback="same words twice" >/dev/null
[[ "$(events_of "$G" task.rejected)" == "2" ]] \
  && ok_t "G two rejects with identical feedback record TWO events (no idem collision)" \
  || bad_t "G events collapsed" "count=$(events_of "$G" task.rejected) — INSERT OR IGNORE silently dropped a bounce"

printf '\n%s\n' "----------------------------------------"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
