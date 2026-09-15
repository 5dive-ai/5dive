#!/usr/bin/env bash
# TIER: nightly — 16.8s measured (this host, 2026-09-15): nine real gate filings
#   through `cmd_task_need` at ~0.9s each, and they cannot be seamed out — the
#   archive under test is produced by the REAL displacement path, so a fixture
#   that writes gate_history directly would grade my own reimplementation of it.
#   Same cost shape and same reason as its sibling tests/gate_history_unit.sh
#   (14.0s, nightly, DIVE-2525), so it takes the same tier. 5.6% of the 300s core
#   budget for one harness is the trade; a verifier who judges core has room
#   flips this one line.
# DIVE-4552 — `trace`'s human-touchpoint count must come from the DURABLE gate
# record, not from the one epoch the live tasks row happens to still hold.
#
# THE DEFECT. `cmd_trace` counted human gates with
#   SELECT COUNT(*) FROM tasks WHERE id=? AND need_answered_at IS NOT NULL
#                                     AND need_answered_by LIKE 'human:%'
# and built the timeline's `gate` event off the same two live columns. A tasks
# row carries at most ONE gate epoch: `_gate_archive_and_clear_sql` copies the
# answered epoch into gate_history and nulls those columns on every re-file,
# withdraw, park and loop-ceiling park. So a SECOND gate on the row erased the
# human who cleared the FIRST one, and the verdict went to `zero-human` on a row
# a human demonstrably touched — the product's headline claim, stated falsely.
# Customer report (agent luca, teal-fox box-1, 0.40.0, 2026-09-15): one `trace`
# invocation printed the append-only audit line "gate cleared by human:… (human
# touchpoint)" and, three lines later, "0 human touchpoint(s) so far".
#
# What is pinned here — the row's four acceptance arms, plus the two shapes that
# make the fix non-vacuous:
#   1. human-answered gate + a SECOND gate filed over it => count 1 (was 0), the
#      archived epoch appears as a `gate` TIMELINE event, and the verdict names
#      the touchpoint even though a gate is currently pending;
#   2. both epochs human-answered + done => "human-in-the-loop — 2 human gate(s)";
#   3. NO REGRESSION: one human-answered live epoch, never displaced => still 1,
#      counted exactly once (the double-count the UNION could have introduced);
#   4. agent-answered epochs only => 0 and `zero-human` on done — the verdict is
#      still capable of saying zero, so arms 1-3 are not passing by saturation;
#   5. the two readers cannot disagree: the count and the timeline are fed by one
#      SQL fragment, which is the contradiction luca saw;
#   6. an UNANSWERED archived epoch (withdrawn before an answer) is not a
#      touchpoint — the archive is not a proxy for "a human was here".
# Run: bash tests/trace_human_touchpoint_history_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/trace-touchpoints.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh \
         cmd_project.sh cmd_trace.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"
set +e   # AFTER sourcing: header.sh turns `set -e` back on.
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
# JSON_MODE is 0 for this harness (the TEXT verdict is half of what is under
# test), so the subshell asks for JSON per call rather than flipping it globally.
addt()  { ( JSON_MODE=1; cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }

# Preconditions, not observables (same seams as tests/gate_history_unit.sh):
# never ping a channel, never write the fleet audit log, keep gate-proof
# enforcement deterministic on any box.
task_need_notify() { return 0; }
audit_log() { return 0; }
_gate_proof_enforced() { return 0; }
_gate_withdraw_actor() { printf 'human'; }

ident_of() { db "SELECT ident FROM tasks WHERE id=${1};"; }
# ONE `trace` pair per state under test, cached — not because the reads are
# expensive on their own, but because the arms below assert the TEXT verdict and
# the JSON count of the SAME invocation. Re-invoking per assertion would let two
# arms grade two different runs, which is the class of evidence this row is about.
# --no-audit so the fleet log (unreadable as a non-root agent, and not the
# subject here) cannot change the surface.
TR_TXT="" TR_JSON=""
snap() {
  local i; i=$(ident_of "$1")
  TR_TXT=$( ( JSON_MODE=0; cmd_trace "$i" --no-audit ) 2>/dev/null )
  TR_JSON=$( ( JSON_MODE=1; cmd_trace "$i" --no-audit ) 2>/dev/null )
}
verdict_of()     { printf '%s\n' "$TR_TXT" | sed -n 's/^verdict: //p'; }
touchpoints_of() { printf '%s' "$TR_JSON" | jq -r '.data.human_touchpoints'; }
# Count of `gate` rows in the DERIVED timeline — the second reader of the same
# fact, and the one whose disagreement with the count was the customer report.
gate_events_of() { printf '%s' "$TR_JSON" | jq -r '[.data.timeline[] | select(.phase=="gate")] | length'; }

# File a gate and answer it, written directly so the arm does not depend on the
# answer path's own policy checks (the pattern tests/gate_history_unit.sh uses).
# $2 is the answerer exactly as the column holds it: 'human:<id>' is the
# verified-human path (DIVE-394), anything else is an agent.
plant_answered() {
  local id="$1" who="$2" ans="${3:-B}"
  ( cmd_task_need "$id" --type=decision --options="A|B" \
      --ask-ok="fixture gate: the options ARE the input under test, not prose a person reads (DIVE-4462)" \
      --recommend="A" --ask="fixture gate on $id" --tier=1 ) >/dev/null 2>&1
  db "UPDATE tasks SET need_answer=$(sqlq "$ans"), need_answered_at=datetime('now'),
        need_answered_by=$(sqlq "$who"), need_answered_uid=1000,
        need_answer_sig='sig-fixture'
      WHERE id=${id};"
}
# Filing a second gate is what ARCHIVES the first one — the displacement under test.
file_second() {
  ( cmd_task_need "$1" --type=manual --ask="the SECOND gate on $1" --tier=1 ) >/dev/null 2>&1
}

# The fixture store is FRESH, so gate_history_coverage is stamped `fresh:` before
# the first task and every arm below has COMPLETE archive coverage. That is what
# lets the arms assert the unqualified verdict strings; a partial-coverage store
# appends a caveat to the zero, which arm 4b pins separately.
COV=$(_task_pref_get gate_history_coverage)
case "$COV" in
  fresh:*) ok_t "fixture store has fresh archive coverage ($COV)" ;;
  *)       bad_t "fixture must be a fresh store or the arms below grade the caveat, not the count" "coverage='$COV'" ;;
esac

# --- ARM 1: displaced human epoch still counts, and still shows -------------
t1=$(addt --assignee=dev -- "fixture: human gate displaced by a second gate")
plant_answered "$t1" 'human:1234567890'
snap "$t1"
# Precondition, not an observable: with only the live epoch the count is already
# 1. If this reads 0 the fixture never planted a gate and arm 1 would pass
# vacuously after the displacement too.
if [[ "$(touchpoints_of "$t1")" == "1" ]]; then
  ok_t "precondition: the un-displaced human epoch counts 1"
else
  bad_t "fixture did not plant a countable human epoch" "got=$(touchpoints_of "$t1")"
fi
file_second "$t1"
snap "$t1"
if [[ "$(db "SELECT COUNT(*) FROM gate_history WHERE task_id=${t1};")" == "1" ]]; then
  ok_t "precondition: filing the second gate archived the first epoch"
else
  bad_t "the second filing must displace the first epoch into gate_history" \
        "rows=$(db "SELECT COUNT(*) FROM gate_history WHERE task_id=${t1};")"
fi
if [[ "$(db "SELECT COALESCE(need_answered_by,'.') FROM tasks WHERE id=${t1};")" == "." ]]; then
  ok_t "precondition: the live row no longer holds the human answerer"
else
  bad_t "the archive must clear the live answer provenance (else this arm is not the defect)"
fi
N1=$(touchpoints_of "$t1")
if [[ "$N1" == "1" ]]; then
  ok_t "ARM 1: the displaced human touchpoint still counts (1)"
else
  bad_t "ARM 1: a human-cleared gate must survive its own displacement" "human_touchpoints=$N1"
fi
G1=$(gate_events_of "$t1")
if [[ "$G1" == "1" ]]; then
  ok_t "ARM 1: the archived epoch appears as a \`gate\` timeline event"
else
  bad_t "ARM 1: the timeline must show the archived gate event" "gate events=$G1"
fi
V1=$(verdict_of "$t1")
if [[ "$V1" == *"1 human touchpoint(s)"* ]]; then
  ok_t "ARM 1: the verdict names the touchpoint ($V1)"
else
  bad_t "ARM 1: a pending gate must not erase the touchpoints already cleared" "verdict='$V1'"
fi
if [[ "$V1" == *"pending manual gate"* ]]; then
  ok_t "ARM 1: the verdict still discloses the pending gate"
else
  bad_t "ARM 1: the pending gate disclosure must survive the fix" "verdict='$V1'"
fi
# THE CONTRADICTION ITSELF: one invocation must not say two different things.
if [[ "$N1" == "$G1" ]]; then
  ok_t "ARM 1: count and timeline agree — one source feeds both readers"
else
  bad_t "the two readers of the same fact disagree (the reported defect)" "count=$N1 timeline=$G1"
fi

# --- ARM 2: both epochs human-answered, row done ----------------------------
t2=$(addt --assignee=dev -- "fixture: two human gates, then done")
plant_answered "$t2" 'human:1234567890'
file_second "$t2"
db "UPDATE tasks SET need_answer='ok', need_answered_at=datetime('now'),
      need_answered_by='human:1234567890', need_answered_uid=1000,
      need_answer_sig='sig-fixture-2' WHERE id=${t2};"
db "UPDATE tasks SET status='done', done_at=datetime('now'), result='fixture done' WHERE id=${t2};"
snap "$t2"
N2=$(touchpoints_of "$t2"); V2=$(verdict_of "$t2")
if [[ "$N2" == "2" ]]; then
  ok_t "ARM 2: both human epochs count (2)"
else
  bad_t "ARM 2: archived + live human epochs must both count" "human_touchpoints=$N2"
fi
if [[ "$V2" == "human-in-the-loop — 2 human gate(s) required" ]]; then
  ok_t "ARM 2: verdict is human-in-the-loop with 2 gates"
else
  bad_t "ARM 2: wrong verdict on a two-human-gate done row" "verdict='$V2'"
fi
if [[ "$(gate_events_of "$t2")" == "2" ]]; then
  ok_t "ARM 2: both epochs appear in the timeline"
else
  bad_t "ARM 2: the timeline must carry both gate events" "gate events=$(gate_events_of "$t2")"
fi

# --- ARM 3: NO REGRESSION and NO DOUBLE COUNT -------------------------------
# The live-only row is the shape that already worked; the UNION is the new way
# it could break, by counting one epoch twice.
t3=$(addt --assignee=dev -- "fixture: one human gate, never displaced")
plant_answered "$t3" 'human:1234567890'
db "UPDATE tasks SET status='done', done_at=datetime('now'), result='fixture done' WHERE id=${t3};"
snap "$t3"
N3=$(touchpoints_of "$t3"); V3=$(verdict_of "$t3")
if [[ "$N3" == "1" ]]; then
  ok_t "ARM 3: an un-displaced human epoch counts exactly once (no double count)"
else
  bad_t "ARM 3: the live epoch must be counted exactly once" "human_touchpoints=$N3"
fi
if [[ "$V3" == "human-in-the-loop — 1 human gate(s) required" ]]; then
  ok_t "ARM 3: verdict unchanged for the pre-existing shape"
else
  bad_t "ARM 3: regression on the shape that already worked" "verdict='$V3'"
fi
if [[ "$(db "SELECT COUNT(*) FROM gate_history WHERE task_id=${t3};")" == "0" ]]; then
  ok_t "ARM 3: nothing was archived, so the count came from the live row alone"
else
  bad_t "ARM 3: fixture accidentally displaced the epoch — the arm is not the no-regression case"
fi

# --- ARM 4: the verdict can still say ZERO ----------------------------------
t4=$(addt --assignee=dev -- "fixture: agent-answered gates only")
plant_answered "$t4" 'agent:dev'
file_second "$t4"
db "UPDATE tasks SET need_answer='ok', need_answered_at=datetime('now'),
      need_answered_by='agent:dev', need_answered_uid=1001,
      need_answer_sig='sig-fixture-3' WHERE id=${t4};"
db "UPDATE tasks SET status='done', done_at=datetime('now'), result='fixture done' WHERE id=${t4};"
snap "$t4"
N4=$(touchpoints_of "$t4"); V4=$(verdict_of "$t4")
if [[ "$N4" == "0" ]]; then
  ok_t "ARM 4: agent-answered epochs are not human touchpoints (0)"
else
  bad_t "ARM 4: only 'human:%' answerers are touchpoints" "human_touchpoints=$N4"
fi
if [[ "$V4" == "zero-human — goal to done with 0 human touchpoints" ]]; then
  ok_t "ARM 4: zero-human is still reachable, so arms 1-3 are not saturation"
else
  bad_t "ARM 4: a genuinely agent-only row must verdict zero-human, unqualified, on a fresh store" "verdict='$V4'"
fi
if [[ "$(gate_events_of "$t4")" == "2" ]]; then
  ok_t "ARM 4: the archived agent epoch is still VISIBLE in the timeline (not a touchpoint, but an event)"
else
  bad_t "ARM 4: agent epochs belong in the timeline even when they score 0" "gate events=$(gate_events_of "$t4")"
fi

# --- ARM 4b: a ZERO from a PARTIAL archive says so --------------------------
# gate_history reaches back only to its own coverage boundary (DIVE-2133). On a
# task older than that boundary, epochs displaced in the blind era were
# destroyed, so the count is "recorded", not "all there were" — and the one
# reading that must not be stated unqualified from a partial record is the zero.
db "INSERT OR REPLACE INTO task_prefs(key,value)
      VALUES('gate_history_coverage','inferred:2099-01-01 00:00:00');" >/dev/null 2>&1
snap "$t4"
V4b=$(verdict_of "$t4")
if [[ "$V4b" == *"zero-human"* && "$V4b" == *"earlier gate history is not covered"* ]]; then
  ok_t "ARM 4b: a zero from a partial archive is qualified, not asserted ($V4b)"
else
  bad_t "ARM 4b: zero-human off a partial archive must disclose the boundary" "verdict='$V4b'"
fi
snap "$t2"
V2b=$(verdict_of "$t2")
if [[ "$V2b" == "human-in-the-loop — 2 human gate(s) required" ]]; then
  ok_t "ARM 4b: a NON-zero count is not caveated — the caveat is about the zero"
else
  bad_t "ARM 4b: the coverage caveat must not leak onto a positive count" "verdict='$V2b'"
fi
db "INSERT OR REPLACE INTO task_prefs(key,value) VALUES('gate_history_coverage',$(sqlq "$COV"));" >/dev/null 2>&1

# --- ARM 5: an UNANSWERED archived epoch is not a touchpoint ----------------
# The archive holds withdrawn-before-answer gates too. Counting archive ROWS
# instead of ANSWERED archive rows would turn "a gate was filed at this human"
# into "a human cleared a gate" — the absent-vs-forbidden conflation again.
t5=$(addt --assignee=dev -- "fixture: gate filed, never answered, then displaced")
( cmd_task_need "$t5" --type=manual --ask="first gate on $t5, never answered" --tier=1 ) >/dev/null 2>&1
db "UPDATE tasks SET human_nonce_hash='deadbeef' WHERE id=${t5};"   # forces the archive predicate
file_second "$t5"
snap "$t5"
if [[ "$(db "SELECT COUNT(*) FROM gate_history WHERE task_id=${t5};")" -ge 1 ]]; then
  ok_t "precondition: an unanswered epoch was archived"
else
  bad_t "fixture did not archive the unanswered epoch — arm 5 is vacuous" \
        "rows=$(db "SELECT COUNT(*) FROM gate_history WHERE task_id=${t5};")"
fi
N5=$(touchpoints_of "$t5")
if [[ "$N5" == "0" ]]; then
  ok_t "ARM 5: an archived but UNANSWERED epoch is not a human touchpoint"
else
  bad_t "ARM 5: the archive is not a proxy for 'a human was here'" "human_touchpoints=$N5"
fi
if [[ "$(gate_events_of "$t5")" == "0" ]]; then
  ok_t "ARM 5: an unanswered epoch produces no 'cleared' timeline event either"
else
  bad_t "ARM 5: an unanswered epoch must not render as cleared" "gate events=$(gate_events_of "$t5")"
fi

# --- ARM 6: the JSON coverage envelope --------------------------------------
# A JSON consumer gets the same disclosure the text verdict carries, or it will
# publish the bare number the text refused to assert.
snap "$t4"
CJ=$(printf '%s' "$TR_JSON" | jq -c '.data.human_touchpoints_coverage')
if [[ "$(printf '%s' "$CJ" | jq -r '.complete')" == "true" && \
      "$(printf '%s' "$CJ" | jq -r '.started_at')" != "null" ]]; then
  ok_t "ARM 6: --json states the archive coverage behind the count ($CJ)"
else
  bad_t "ARM 6: --json must carry the coverage envelope" "got='$CJ'"
fi

printf '\n%s\n' "trace human-touchpoint history: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
