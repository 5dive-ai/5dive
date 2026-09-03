#!/usr/bin/env bash
# DIVE-3932 — RUNS v1: first-class execution attempts beneath tasks.
#
# A run is one attempt by ONE agent to advance ONE task. Before this, "what
# exactly happened during this one activation?" had no answer: a task spans hours
# and several agents, a journal stream spans many tasks, and nothing joined them.
#
# WHAT THIS GRADES (each arm names the property, not the call):
#   1  a claim OPENS a run, and a second claim in the same activation REUSES it —
#      `attempt` must count attempts, not keystrokes.
#   2  the DISPATCHER claim opens the run for the SEAT it claimed for, not for
#      the root process that executed the line. One arm per write site: the
#      heartbeat carries most real claims (DIVE-2244), so grading only the verb
#      would leave the majority path unlocked.
#   3  every end boundary closes the run with the RIGHT status, and the four are
#      not interchangeable: done=completed, deliver=completed/handed_to_verifier,
#      cancel=abandoned, blocked=parked. Scoring a park as a failure is the
#      specific mis-reading the reliability metrics exist to avoid.
#   4  A CRASH LEAVES A CLOSED RUN, NOT NO RUN — the reclaim sweep is the only
#      observer left once the seat's process is gone.
#   5  a retry opens a NEW run linked by retry_of and leaves the retried run
#      BYTE-FOR-BYTE UNCHANGED. The whole value of the lineage is that failure
#      survives recovery.
#   6  a live run cannot be retried (that would double-count one attempt).
#   7  human_touch is set by a tier-1/2 gate and NOT by a tier-0 gate — tier 0
#      pings nobody, and counting it would report a person in work no person saw.
#   8  run_usage enforces PROVENANCE: an unknown source/quality is not stored as
#      if it were known, and quality='unavailable' stores a NULL value so
#      "we looked and it isn't exposed" cannot render as a measurement.
#   9  `run metrics` prints NO DATA on an empty window rather than 0%.
#  10  RUNS DO NOT REPLACE TRACE — `trace` still renders its own timeline and
#      ledger and shows runs as ANCHORS. This is the proposal's hard rule and it
#      is graded, because the cheapest way to "add runs" is to turn trace into
#      them.
#  11  the schema reaches a PRE-EXISTING store through _tasks_db_migrate, not
#      only through the canonical schema (DIVE-2512: a fresh-DB harness never
#      exercises the migration at all, so a table added in one place only exists
#      on harnesses and on no real box).
#
# Same isolation contract as tests/task_first_started_at_unit.sh: source src/
# directly, throwaway tasks.db, no tmux/network/root.
# Run: bash tests/runs_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/runs-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/runs.sh lib/actor.sh cmd_task.sh cmd_org.sh \
         cmd_project.sh cmd_heartbeat.sh cmd_run.sh cmd_trace.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# FIXTURE SEAT NAMES ARE NEVER REAL SEAT NAMES. `_run_role` compares the row's
# `verifier`/`maker_agent` against the SEAT EXECUTING THE SUITE, so a fixture
# that writes a real board name is red on exactly that one seat and green on
# every other — `--verifier=quinn` here was 43/43 for dev and 42/43 for quinn.
#
# MUTATION TESTING CANNOT SEE THIS CLASS: a mutant is graded on one seat too, so
# mutation grades the ASSERTION while only a SECOND SEAT grades the FIXTURE.
# Section 0 below closes that by making the collision gradable from one seat.
FIX_MAKER=fixture-maker-noseat
FIX_VERIFIER=fixture-verifier-noseat

addt() { ( JSON_MODE=1 cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
rfld() { db "SELECT COALESCE($2,'NULL') FROM runs WHERE id=$(sqlq "$1");"; }
runs_of() { db "SELECT COUNT(*) FROM runs WHERE task_id=$1;"; }
open_of() { db "SELECT COALESCE((SELECT id FROM runs WHERE task_id=$1 AND status='running' ORDER BY id DESC LIMIT 1),'');"; }

# Boundaries: no tmux/registry/network/audit.
REGISTRY="$TMP/registry.json"; printf '{"agents":{}}' >"$REGISTRY"
registry_read()  { cat "$REGISTRY"; }
registry_write() { cat > "$REGISTRY"; }
audit_log()            { :; }
_hb_send_line()        { return 0; }
_hb_pane_fingerprint() { echo "fp"; }
_hb_log()              { :; }
cmd_send()             { :; }
cmd_task_escalate()    { :; }
with_registry_lock()   { local fn="$1"; shift; "$fn" "$@"; }
_task_human_send_allowed() { return 0; }
# journalctl is not assumed present in a test container; the cursor reader is
# best-effort by design and must degrade to an empty cursor, never to an error.
_run_journal_cursor()  { printf ''; }

# Resolved AFTER the boundary stubs above, so the seat is read under exactly the
# conditions every arm below runs under.
SEAT=$(_run_seat)

# ---------------------------------------------------------------------------
# 0. THIS SUITE IS SEAT-INDEPENDENT. Every fixture agent name must be a name no
#    seat holds, so the result is the same on dev, on quinn and on CI. The one
#    deliberate exception is the verifier-role arm below, which uses $SEAT
#    precisely because it is grading that the RUNNING seat resolves.
# ---------------------------------------------------------------------------
_collide=""
for _n in "$FIX_MAKER" "$FIX_VERIFIER" someseat crashseat someoneelse nobody-ever-ran; do
  [[ -n "$SEAT" && "$_n" == "$SEAT" ]] && _collide="$_n"
done
[[ -z "$_collide" ]] \
  && ok_t "no fixture agent name is the running seat (same result on every seat)" \
  || bad_t "a fixture agent name IS the running seat" "seat=[$SEAT] name=[$_collide]"

# ---------------------------------------------------------------------------
# 1. A claim OPENS a run; a second claim in the same activation REUSES it.
# ---------------------------------------------------------------------------
id1=$(addt "alpha" --assignee="$FIX_MAKER")
( cmd_task_start "$id1" --no-preflight ) >/dev/null 2>&1
r1=$(open_of "$id1")
[[ -n "$r1" ]] && ok_t "claim opens a run" || bad_t "claim opened no run"
[[ "$(rfld "$r1" attempt)" == "1" ]] && ok_t "first attempt is numbered 1" \
  || bad_t "attempt mis-numbered" "got=[$(rfld "$r1" attempt)]"
[[ "$(rfld "$r1" ident)" == "$(db "SELECT ident FROM tasks WHERE id=$id1;")" ]] \
  && ok_t "run carries the task ident" || bad_t "run ident not stamped"
[[ "$(db "SELECT COUNT(*) FROM run_events WHERE run_id=$(sqlq "$r1") AND kind='run.started';")" == "1" ]] \
  && ok_t "run.started event written" || bad_t "no run.started event"
# The re-claim. `task start` on an already-started row is a no-op path in places,
# so drive run_open directly — this arm is about IDEMPOTENCE of the run writer,
# which is the property that keeps `attempt` meaningful.
r1b=$(run_open "$id1" "DIVE-x" "second claim")
[[ "$r1b" == "$r1" ]] && ok_t "a re-claim REUSES the open run (attempt counts attempts, not keystrokes)" \
  || bad_t "a re-claim opened a SECOND run" "first=[$r1] second=[$r1b]"
[[ "$(runs_of "$id1")" == "1" ]] && ok_t "still exactly one run on the row" \
  || bad_t "row grew a spurious run" "count=[$(runs_of "$id1")]"

# ---------------------------------------------------------------------------
# 2. The DISPATCHER claim opens the run for the SEAT, not for the caller.
# ---------------------------------------------------------------------------
id2=$(addt "beta" --assignee=someseat)
rd=$(run_open "$id2" "DIVE-y" "heartbeat dispatch" "" "someseat")
[[ "$(rfld "$rd" agent)" == "someseat" ]] \
  && ok_t "dispatcher-opened run belongs to the seat it claimed for" \
  || bad_t "dispatcher run attributed to the wrong agent" "got=[$(rfld "$rd" agent)]"
[[ "$(rfld "$rd" wake_reason)" == "heartbeat dispatch" ]] \
  && ok_t "wake_reason recorded" || bad_t "wake_reason missing"
[[ "$(rfld "$rd" session_id)" == "NULL" ]] \
  && ok_t "a dispatcher run stores NO session id (it cannot know the seat's)" \
  || bad_t "dispatcher run invented a session id" "got=[$(rfld "$rd" session_id)]"

# ---------------------------------------------------------------------------
# 3. End boundaries close with the RIGHT status. Four arms, not one.
# ---------------------------------------------------------------------------
( cmd_task_done "$id1" --result="finished" ) >/dev/null 2>&1
[[ "$(rfld "$r1" status)" == "completed" && "$(rfld "$r1" outcome)" == "task_done" ]] \
  && ok_t "done -> completed/task_done" \
  || bad_t "done closed wrong" "status=[$(rfld "$r1" status)] outcome=[$(rfld "$r1" outcome)]"
[[ "$(rfld "$r1" ended_at)" != "NULL" ]] && ok_t "done stamps ended_at" || bad_t "ended_at not stamped"

id3=$(addt "gamma" --assignee="$FIX_MAKER" --verifier="$FIX_VERIFIER")
( cmd_task_start "$id3" --no-preflight ) >/dev/null 2>&1
r3=$(open_of "$id3")
( cmd_task_done "$id3" --result="for review" ) >/dev/null 2>&1
[[ "$(rfld "$r3" status)" == "completed" && "$(rfld "$r3" outcome)" == "handed_to_verifier" ]] \
  && ok_t "deliver -> completed/handed_to_verifier (the maker's end boundary)" \
  || bad_t "deliver closed wrong" "status=[$(rfld "$r3" status)] outcome=[$(rfld "$r3" outcome)]"
[[ "$(rfld "$r3" role)" == "maker" ]] && ok_t "role resolved to maker" \
  || bad_t "role not resolved" "got=[$(rfld "$r3" role)]"

# ROLE IS READ FROM THE ROW, NOT GUESSED FROM THE VERB — and both values must be
# reachable. One seat is maker on one row and verifier on the next, and the whole
# reason role is stored is that "verifier rejection rate" has to be separable
# from "maker failure rate". An arm that only ever sees `maker` passes
# identically against a resolver hardcoded to return it (caught by mutation).
id3v=$(addt "gamma-verify" --assignee="$SEAT")
db "UPDATE tasks SET verifier=$(sqlq "$SEAT"), maker_agent='someoneelse' WHERE id=$id3v;"
r3v=$(run_open "$id3v" "DIVE-gv" "verifier claim")
[[ "$(rfld "$r3v" role)" == "verifier" ]] \
  && ok_t "the SAME seat resolves to verifier on a row it verifies" \
  || bad_t "verifier role not resolved" "seat=[$SEAT] got=[$(rfld "$r3v" role)]"

# A DOUBLE CLOSE IS A NO-OP. A verb that funnels twice, or a crash sweep racing a
# seat's own close, must not be able to rewrite a terminal record — the run's
# fate is decided by whatever reached the boundary FIRST, and a later writer
# silently overwriting it is the same silent-rewrite the retry lineage exists to
# forbid, one field down.
run_close "$r3v" completed first_boundary
snap=$(db "SELECT status||'|'||COALESCE(outcome,'')||'|'||COALESCE(ended_at,'') FROM runs WHERE id=$(sqlq "$r3v");")
run_close "$r3v" failed second_boundary 9 someclass
snap2=$(db "SELECT status||'|'||COALESCE(outcome,'')||'|'||COALESCE(ended_at,'') FROM runs WHERE id=$(sqlq "$r3v");")
[[ "$snap" == "$snap2" ]] \
  && ok_t "closing an already-closed run is a NO-OP (the first boundary wins)" \
  || bad_t "a second close rewrote a terminal run" "first=[$snap] second=[$snap2]"

id4=$(addt "delta" --assignee="$FIX_MAKER")
( cmd_task_start "$id4" --no-preflight ) >/dev/null 2>&1
r4=$(open_of "$id4")
( cmd_task_cancel "$id4" --result="not needed" ) >/dev/null 2>&1
[[ "$(rfld "$r4" status)" == "abandoned" ]] \
  && ok_t "cancel -> abandoned (an attempt that did not reach its boundary is not a success)" \
  || bad_t "cancel closed wrong" "got=[$(rfld "$r4" status)]"

# PARK and BLOCK are graded through their REAL VERBS, and each on its own arm.
# Both write status='blocked' with their own UPDATE and never cross the status
# funnel, so a hook placed only in the funnel closes neither — which is exactly
# what a mutation sweep caught: the funnel's `blocked` arm survived every mutant
# because nothing reachable ever entered it.
id5=$(addt "epsilon" --assignee="$FIX_MAKER")
( cmd_task_start "$id5" --no-preflight ) >/dev/null 2>&1
r5=$(open_of "$id5")
( cmd_task_park "$id5" --reason="waiting on upstream" --wake="+7d" ) >/dev/null 2>&1
[[ "$(db "SELECT status FROM tasks WHERE id=$id5;")" == "blocked" ]] \
  && ok_t "precondition: park really reached status='blocked'" \
  || bad_t "park did not block the row" "got=[$(db "SELECT status FROM tasks WHERE id=$id5;")]"
[[ "$(rfld "$r5" status)" == "parked" && "$(rfld "$r5" outcome)" == "task_parked" ]] \
  && ok_t "park -> parked, NOT failed (a deliberate hold is neither success nor failure)" \
  || bad_t "park closed wrong" "status=[$(rfld "$r5" status)] outcome=[$(rfld "$r5" outcome)]"

id5b=$(addt "epsilon-blocker" --assignee="$FIX_MAKER")
id5c=$(addt "epsilon-blocked" --assignee="$FIX_MAKER")
( cmd_task_start "$id5c" --no-preflight ) >/dev/null 2>&1
r5c=$(open_of "$id5c")
( cmd_task_block "$id5c" --by="$id5b" ) >/dev/null 2>&1
[[ "$(rfld "$r5c" status)" == "parked" && "$(rfld "$r5c" outcome)" == "task_blocked" ]] \
  && ok_t "block --by -> parked/task_blocked (the dependency-edge door closes it too)" \
  || bad_t "block closed wrong" "status=[$(rfld "$r5c" status)] outcome=[$(rfld "$r5c" outcome)]"

# ---------------------------------------------------------------------------
# 4. A CRASH LEAVES A CLOSED RUN. The reclaim sweep is the only observer left.
# ---------------------------------------------------------------------------
id6=$(addt "zeta" --assignee=crashseat)
db "UPDATE tasks SET status='in_progress', assignee='crashseat', started_at=datetime('now') WHERE id=$id6;"
r6=$(run_open "$id6" "DIVE-z" "heartbeat dispatch" "" "crashseat")
_hb_reclaim_to_todo "crashseat" "$id6" "orphan-by-restart"
[[ "$(rfld "$r6" status)" == "abandoned" ]] \
  && ok_t "a reclaimed (crashed) attempt closes ABANDONED, not left running forever" \
  || bad_t "crash left the run open" "got=[$(rfld "$r6" status)]"
[[ "$(rfld "$r6" error_class)" == "orphan-by-restart" ]] \
  && ok_t "the sweep's REASON is recorded, not a fault nobody witnessed" \
  || bad_t "reclaim reason not recorded" "got=[$(rfld "$r6" error_class)]"

# ---------------------------------------------------------------------------
# 5/6. Retry: a NEW run, linked; the retried run UNCHANGED; a live run refused.
# ---------------------------------------------------------------------------
before=$(db "SELECT id||'|'||status||'|'||COALESCE(outcome,'')||'|'||COALESCE(ended_at,'')||'|'||attempt
               FROM runs WHERE id=$(sqlq "$r4");")
out=$( JSON_MODE=1 cmd_run_retry "$r4" 2>/dev/null )
newr=$(printf '%s' "$out" | jq -r '.data.run // ""')
[[ -n "$newr" && "$newr" != "$r4" ]] && ok_t "retry opens a NEW run" \
  || bad_t "retry did not open a new run" "out=[$out]"
[[ "$(rfld "$newr" retry_of)" == "$r4" ]] && ok_t "the new run is linked by retry_of" \
  || bad_t "retry lineage missing" "got=[$(rfld "$newr" retry_of)]"
after=$(db "SELECT id||'|'||status||'|'||COALESCE(outcome,'')||'|'||COALESCE(ended_at,'')||'|'||attempt
              FROM runs WHERE id=$(sqlq "$r4");")
[[ "$before" == "$after" ]] \
  && ok_t "the retried run is UNCHANGED (failure survives recovery)" \
  || bad_t "retry rewrote the run it retried" "before=[$before] after=[$after]"
[[ "$(rfld "$newr" attempt)" == "2" ]] && ok_t "the retry is attempt 2" \
  || bad_t "retry attempt mis-numbered" "got=[$(rfld "$newr" attempt)]"
( cmd_run_retry "$newr" ) >/dev/null 2>&1
[[ $? -ne 0 ]] && ok_t "retrying a LIVE run is refused (it would double-count one attempt)" \
  || bad_t "a live run was retried"

# ---------------------------------------------------------------------------
# 7. human_touch: a tier-1/2 gate sets it; a TIER-0 gate does not.
# ---------------------------------------------------------------------------
id7=$(addt "eta" --assignee="$FIX_MAKER")
( cmd_task_start "$id7" --no-preflight ) >/dev/null 2>&1
r7=$(open_of "$id7")
( cmd_task_need "$id7" --type=decision --ask="pick" --options="A|B" --recommend="A" \
    --tier=2 --needs=human_tap ) >/dev/null 2>&1
[[ "$(rfld "$r7" human_touch)" == "1" ]] \
  && ok_t "a tier-2 gate marks the run human-touched" \
  || bad_t "tier-2 gate did not mark human_touch" "got=[$(rfld "$r7" human_touch)]"
id8=$(addt "theta" --assignee="$FIX_MAKER")
( cmd_task_start "$id8" --no-preflight ) >/dev/null 2>&1
r8=$(open_of "$id8")
( cmd_task_need "$id8" --type=decision --ask="pick" --options="A|B" --recommend="A" --tier=0 ) >/dev/null 2>&1
[[ "$(rfld "$r8" human_touch)" == "0" ]] \
  && ok_t "a TIER-0 gate does NOT mark human_touch (it pings nobody)" \
  || bad_t "tier-0 gate falsely counted a human" "got=[$(rfld "$r8" human_touch)]"

# ---------------------------------------------------------------------------
# 8. run_usage enforces provenance.
# ---------------------------------------------------------------------------
run_usage_add "$r7" tokens 1234 tokens runtime exact run
run_usage_add "$r7" tokens_guess 999 tokens "made-up-source" "very-sure" cosmos
run_usage_add "$r7" api_cost 0.83 usd provider unavailable run
u1=$(db "SELECT source||'/'||quality||'/'||scope FROM run_usage WHERE run_id=$(sqlq "$r7") AND metric='tokens';")
[[ "$u1" == "runtime/exact/run" ]] && ok_t "an exact datum keeps its provenance" || bad_t "provenance lost" "got=[$u1]"
u2=$(db "SELECT source||'/'||quality||'/'||scope FROM run_usage WHERE run_id=$(sqlq "$r7") AND metric='tokens_guess';")
[[ "$u2" == "inferred/unavailable/run" ]] \
  && ok_t "an UNKNOWN source/quality degrades to inferred/unavailable, never stored as known" \
  || bad_t "an unvalidated provenance was stored verbatim" "got=[$u2]"
u3=$(db "SELECT COALESCE(CAST(value AS TEXT),'NULL') FROM run_usage WHERE run_id=$(sqlq "$r7") AND metric='api_cost';")
[[ "$u3" == "NULL" ]] \
  && ok_t "quality='unavailable' stores a NULL value — an absent measurement cannot render as a measured one" \
  || bad_t "an unavailable metric kept a number" "got=[$u3]"

# ---------------------------------------------------------------------------
# 9. `run metrics` says NO DATA on an empty window, never 0%.
# ---------------------------------------------------------------------------
# An empty window, made empty by a filter rather than by a clock: everything
# above ran seconds ago, so any --since short enough to exclude it would also be
# racy. `--agent=` a seat that never ran is deterministically empty.
m=$( cmd_run_metrics --since=7d --agent=nobody-ever-ran 2>/dev/null )
for _rate_line in 'success rate' 'first-attempt success' 'verifier rejection rate' 'human touches'; do
  printf '%s' "$m" | grep -qE "^ +${_rate_line} +NO DATA$" \
    && ok_t "empty window: '${_rate_line}' prints NO DATA, not a 0% that reads as measured" \
    || bad_t "empty window produced a rate for '${_rate_line}'" "out=[$m]"
done
m2=$( cmd_run_metrics --since=7d 2>/dev/null )
printf '%s' "$m2" | grep -qE 'success rate +[0-9]+% \([0-9]+/[0-9]+\)' \
  && ok_t "every rate names its own denominator" || bad_t "a rate printed without its denominator" "out=[$m2]"

# ---------------------------------------------------------------------------
# 10. RUNS DO NOT REPLACE TRACE.
# ---------------------------------------------------------------------------
tr=$( cmd_trace "$(db "SELECT ident FROM tasks WHERE id=$id3;")" --no-audit 2>/dev/null )
printf '%s' "$tr" | grep -q 'timeline (goal' \
  && ok_t "trace still renders its own causal timeline" || bad_t "trace lost its timeline"
printf '%s' "$tr" | grep -q 'lifecycle ledger' \
  && ok_t "trace still renders the lifecycle ledger" || bad_t "trace lost the ledger section"
printf '%s' "$tr" | grep -q "attempts (runs" \
  && ok_t "trace shows runs as ANCHORS beneath the narrative" || bad_t "trace does not link runs"
printf '%s' "$tr" | grep -q "$r3" \
  && ok_t "the anchor names the actual run id" || bad_t "run id absent from trace" "out=[$tr]"

# ---------------------------------------------------------------------------
# 11. The tables reach a PRE-EXISTING store through the MIGRATION.
#
# DIVE-2512: a fresh-DB harness never enters _tasks_db_migrate, so everything
# above proves only that the canonical schema has these tables. This arm builds a
# store that has tasks but NO runs — the shape every live board is in — and
# asserts the migration creates all three.
# ---------------------------------------------------------------------------
OLD_DB="$TASKS_DB"
TASKS_DB="$TMP/legacy.db"
sqlite3 "$TASKS_DB" "CREATE TABLE tasks(id INTEGER PRIMARY KEY); CREATE TABLE task_prefs(key TEXT PRIMARY KEY, value TEXT, updated_at TEXT);" 2>/dev/null
_tasks_db_migrate >/dev/null 2>&1
for t in runs run_events run_usage; do
  [[ "$(sqlite3 "$TASKS_DB" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$t';" 2>/dev/null)" == "1" ]] \
    && ok_t "migration creates '$t' on a pre-existing store" \
    || bad_t "'$t' missing after migration on a legacy store"
done
TASKS_DB="$OLD_DB"

printf -- '-----\nruns_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
