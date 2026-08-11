#!/usr/bin/env bash
# DIVE-3251 — the reclaim ladder erased the only evidence that work happened.
#
# A row that was really started could silently revert to `todo` with `started_at`
# cleared, so the board showed nothing where 90 minutes of real work had been:
# 58 rows fleet-wide carried a `task.started` ledger event and an empty
# started_at, 16 of them still open. The fix is TWO FIELDS, not deleting the
# NULL — the ladder's reset is a real requirement (it restarts the age and the
# per-task nudge counter), so `started_at` keeps being resettable and
# `first_started_at` carries the evidence nothing in the nudge path may touch.
#
# WHAT THIS GRADES
#   1  `task start` stamps BOTH clocks, and writes an audit row (FINDING 2).
#   2  each of the THREE reclaim rules — (a) session gone, (b) idle stall,
#      (c) overran budget — clears started_at and PRESERVES first_started_at.
#      They are graded one arm per rule and not treated as interchangeable,
#      because they reach the erasure by different predicates.
#   3  the reclaim emits its own `task.reclaimed` ledger event, and CYCLES ARE
#      COUNTABLE: two reclaims write two rows, where `task.started`'s constant
#      idem_key can only ever record the first claim.
#   4  a re-claim after a reclaim re-stamps started_at fresh (the ladder gets its
#      clean slate) while first_started_at is UNCHANGED. This is the whole point:
#      "is a seat on it now" and "did real work happen" stop being one field.
#   5  the migration BACKFILLS first_started_at FROM THE LEDGER, never from
#      now(); does NOT flip status; and LEAVES A ROW WITH NO USABLE LEDGER
#      TIMESTAMP UNREPAIRED rather than fabricating one.
#   6  `task show` SURFACES it — the DONE WHEN is "distinguishable from the board
#      alone", which a column nobody prints does not satisfy.
#
# Same isolation contract as tests/heartbeat_reclaim_verifier_handoff_unit.sh:
# source src/ directly, throwaway tasks.db, no tmux/network/root.
# Run: bash tests/task_first_started_at_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/task-first-started-at.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

addt()   { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
fld()    { db "SELECT COALESCE($2,'NULL') FROM tasks WHERE id=$1;"; }
status_of() { db "SELECT status FROM tasks WHERE id=$1;"; }
evn()    { db "SELECT COUNT(*) FROM lifecycle_events WHERE task_id=$1 AND kind=$(sqlq "$2");"; }

# Boundaries: no tmux/registry/network. The idle + proc-start readings are what
# select which reclaim rule fires, so they are steered per-arm below.
REGISTRY="$TMP/registry.json"; printf '{"agents":{}}' >"$REGISTRY"
registry_read()        { cat "$REGISTRY"; }
registry_write()       { cat > "$REGISTRY"; }
_hb_send_line()        { return 0; }
_hb_pane_fingerprint() { echo "fp"; }
cmd_send()             { :; }
cmd_task_escalate()    { :; }
with_registry_lock()   { local fn="$1"; shift; "$fn" "$@"; }
_hb_claude_started()   { echo ""; }   # no proc time -> rule (a) does not fire
_hb_agent_idle()       { return 1; }  # not idle -> rule (b) does not fire

# ---------------------------------------------------------------------------
# 1. `task start` stamps both clocks, and leaves an audit row.
# ---------------------------------------------------------------------------
AUDIT_ROWS="$TMP/audit-rows"
: >"$AUDIT_ROWS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_ROWS"; }
_task_human_send_allowed() { return 0; }

id1=$(addt "alpha" --assignee=dev2)
( cmd_task_start "$id1" --no-preflight ) >/dev/null 2>&1
s1=$(fld "$id1" started_at); f1=$(fld "$id1" first_started_at)
[[ "$s1" != "NULL" && -n "$s1" ]] && ok_t "start: started_at stamped" \
  || bad_t "start: started_at not stamped" "got=[$s1]"
[[ "$f1" == "$s1" ]] && ok_t "start: first_started_at stamped to the same instant" \
  || bad_t "start: first_started_at disagrees with started_at" "started=[$s1] first=[$f1]"
grep -q 'task start' "$AUDIT_ROWS" \
  && ok_t "FINDING 2: \`task start\` leaves an audit row" \
  || bad_t "FINDING 2: \`task start\` still writes no audit row" "rows=[$(cat "$AUDIT_ROWS")]"

# ---------------------------------------------------------------------------
# 1b. The DISPATCHER claim stamps first_started_at from NULL.
#
# One arm per WRITE SITE, and each must start from NULL. `task start` is not the
# majority path: DIVE-2244 moved the authoritative start to `_hb_claim_task`, so
# a fix graded only through the verb leaves the path that carries most rows
# unlocked. The re-claim arm further down asserts first_started_at is UNMOVED,
# which cannot see this write at all — its fixture arrives with the field already
# populated by `task start`, and "unmoved" passes identically when the write is
# gone, because NULL staying NULL has no delta either. Found by quinn's mutation
# of exactly this line (src/cmd_heartbeat.sh, the first_started_at= clause of
# _hb_claim_task): 31/0 green with the original defect reproduced underneath.
# ---------------------------------------------------------------------------
idd=$(addt "dispatcher-claim" --assignee=dev2)
[[ "$(fld "$idd" first_started_at)" == "NULL" && "$(fld "$idd" started_at)" == "NULL" ]] \
  && ok_t "dispatcher claim: fixture starts from NULL on BOTH clocks (never through \`task start\`)" \
  || bad_t "dispatcher claim: fixture was not NULL to begin with — the arm would prove nothing" \
       "started=[$(fld "$idd" started_at)] first=[$(fld "$idd" first_started_at)]"
_hb_claim_task dev2 "$idd" >/dev/null 2>&1
sd=$(fld "$idd" started_at); fd=$(fld "$idd" first_started_at)
[[ "$(status_of "$idd")" == "in_progress" ]] && ok_t "dispatcher claim: row moved to in_progress" \
  || bad_t "dispatcher claim: row not claimed" "status=[$(status_of "$idd")]"
[[ "$fd" != "NULL" && -n "$fd" ]] \
  && ok_t "dispatcher claim: first_started_at STAMPED — the majority path is locked, not just \`task start\`" \
  || bad_t "dispatcher claim: first_started_at left NULL by _hb_claim_task" "got=[$fd] started=[$sd]"
[[ "$fd" == "$sd" ]] && ok_t "dispatcher claim: both clocks stamped to the same instant" \
  || bad_t "dispatcher claim: clocks disagree" "started=[$sd] first=[$fd]"

# And the composite the defect actually presented as: a DISPATCHER-claimed row
# that is then reclaimed must still read its first start from the board. Without
# the write above this is status=todo / started_at=NULL / first_started_at=NULL —
# the original bug exactly, with every other arm in this file green.
# Age the CLAIM clock only — first_started_at keeps whatever _hb_claim_task wrote,
# which is the value under test. Rule (a) compares the claiming process against
# started_at, so a claim stamped this second is never "older than the process".
db "UPDATE tasks SET started_at=datetime('now','-30 minutes') WHERE id=${idd};"
_hb_claude_started() { date -u +%s; }            # rule (a): claiming session gone
_hb_reclaim dev2 100000 >/dev/null 2>&1
_hb_claude_started() { echo ""; }
[[ "$(status_of "$idd")" == "todo" && "$(fld "$idd" started_at)" == "NULL" ]] \
  && ok_t "dispatcher claim + reclaim: row reverted to todo with started_at cleared" \
  || bad_t "dispatcher claim + reclaim: row not reclaimed" \
       "status=[$(status_of "$idd")] started=[$(fld "$idd" started_at)]"
[[ "$(fld "$idd" first_started_at)" == "$fd" && "$fd" != "NULL" ]] \
  && ok_t "dispatcher claim + reclaim: first_started_at SURVIVES — a dispatcher-claimed row is not blind" \
  || bad_t "dispatcher claim + reclaim: first_started_at lost on the dispatcher path" \
       "before=[$fd] after=[$(fld "$idd" first_started_at)]"

# ---------------------------------------------------------------------------
# 2/3/4. The three reclaim rules. One arm per rule — they are NOT
# interchangeable: (a) reads the claiming process, (c) reads the budget, (b)
# reads an idle sample, and each could regress on its own.
# ---------------------------------------------------------------------------
# Helper: put a row in_progress with a started_at that is `$1` minutes old.
age_row() {
  local id="$1" mins="$2"
  db "UPDATE tasks SET status='in_progress', assignee='dev2',
        started_at=datetime('now','-${mins} minutes'),
        first_started_at=datetime('now','-${mins} minutes')
      WHERE id=${id};"
}

# --- rule (a): the claiming session is gone (process newer than the claim) ---
ida=$(addt "rule-a" --assignee=dev2); age_row "$ida" 30
fa_before=$(fld "$ida" first_started_at)
_hb_claude_started() { date -u +%s; }          # claude restarted just now -> newer than the claim
_hb_reclaim dev2 10 >/dev/null 2>&1
_hb_claude_started() { echo ""; }
[[ "$(status_of "$ida")" == "todo" ]] && ok_t "rule (a): row reclaimed to todo" \
  || bad_t "rule (a): row not reclaimed" "status=[$(status_of "$ida")]"
[[ "$(fld "$ida" started_at)" == "NULL" ]] && ok_t "rule (a): started_at cleared (the reset the ladder needs)" \
  || bad_t "rule (a): started_at survived the reclaim" "got=[$(fld "$ida" started_at)]"
[[ "$(fld "$ida" first_started_at)" == "$fa_before" ]] \
  && ok_t "rule (a): first_started_at PRESERVED — the work is still visible from the board" \
  || bad_t "rule (a): reclaim erased first_started_at" "before=[$fa_before] after=[$(fld "$ida" first_started_at)]"
[[ "$(evn "$ida" task.reclaimed)" == "1" ]] && ok_t "rule (a): reclaim emitted a task.reclaimed ledger event" \
  || bad_t "rule (a): no task.reclaimed ledger event" "n=[$(evn "$ida" task.reclaimed)]"

# --- rule (c): overran the in_progress budget ------------------------------
idc=$(addt "rule-c" --assignee=dev2); age_row "$idc" 600
fc_before=$(fld "$idc" first_started_at)
_hb_reclaim dev2 10 >/dev/null 2>&1             # budget = 10 * _HB_STALE_MULT, floored
[[ "$(status_of "$idc")" == "todo" ]] && ok_t "rule (c): row reclaimed to todo" \
  || bad_t "rule (c): row not reclaimed" "status=[$(status_of "$idc")]"
[[ "$(fld "$idc" started_at)" == "NULL" ]] && ok_t "rule (c): started_at cleared" \
  || bad_t "rule (c): started_at survived" "got=[$(fld "$idc" started_at)]"
[[ "$(fld "$idc" first_started_at)" == "$fc_before" ]] \
  && ok_t "rule (c): first_started_at PRESERVED" \
  || bad_t "rule (c): reclaim erased first_started_at" "before=[$fc_before] after=[$(fld "$idc" first_started_at)]"

# --- rule (b): idle stall ---------------------------------------------------
idb=$(addt "rule-b" --assignee=dev2)
age_row "$idb" "$(( _HB_STALL_MIN_MINUTES + 5 ))"
fb_before=$(fld "$idb" first_started_at)
_hb_agent_idle() { return 0; }                  # a confident idle reading
_hb_reclaim dev2 100000 >/dev/null 2>&1         # budget enormous -> (c) cannot fire, only (b)
_hb_agent_idle() { return 1; }
[[ "$(status_of "$idb")" == "todo" ]] && ok_t "rule (b): row reclaimed to todo" \
  || bad_t "rule (b): row not reclaimed" "status=[$(status_of "$idb")]"
[[ "$(fld "$idb" started_at)" == "NULL" ]] && ok_t "rule (b): started_at cleared" \
  || bad_t "rule (b): started_at survived" "got=[$(fld "$idb" started_at)]"
[[ "$(fld "$idb" first_started_at)" == "$fb_before" ]] \
  && ok_t "rule (b): first_started_at PRESERVED" \
  || bad_t "rule (b): reclaim erased first_started_at" "before=[$fb_before] after=[$(fld "$idb" first_started_at)]"

# --- the negative control: WITHOUT the fix this suite would still pass on the
# started_at arms. The discriminating assertion is that a row reclaimed and then
# RE-CLAIMED gets a fresh started_at while first_started_at does not move. That
# is the property the single-field design cannot have, whatever it does to NULLs.
_hb_claim_task dev2 "$idc" >/dev/null 2>&1
s_new=$(fld "$idc" started_at)
[[ "$s_new" != "NULL" && "$s_new" != "$fc_before" ]] \
  && ok_t "re-claim: started_at re-stamped fresh (the ladder still gets a clean slate)" \
  || bad_t "re-claim: started_at not re-stamped" "got=[$s_new] first=[$fc_before]"
[[ "$(fld "$idc" first_started_at)" == "$fc_before" ]] \
  && ok_t "re-claim: first_started_at UNMOVED — it records the FIRST start, not the latest" \
  || bad_t "re-claim: first_started_at moved on re-claim" "before=[$fc_before] after=[$(fld "$idc" first_started_at)]"

# --- cycles are countable, which the ledger could not do before -------------
# Second cycle via rule (a), NOT rule (c) again: the reap counter is per-task and
# the _HB_REAP_ESCALATE_AFTER'th overrun BLOCKS + escalates instead of reclaiming,
# so a second (c) would never reach the erasure at all. That is correct ladder
# behaviour and it is also why this arm must not reuse the same rule.
db "UPDATE tasks SET status='in_progress', started_at=datetime('now','-30 minutes') WHERE id=${idc};"
_hb_claude_started() { date -u +%s; }
_hb_reclaim dev2 100000 >/dev/null 2>&1
_hb_claude_started() { echo ""; }
n_recl=$(evn "$idc" task.reclaimed); n_start=$(evn "$idc" task.started)
[[ "$n_recl" == "2" ]] \
  && ok_t "ledger: TWO reclaims record TWO task.reclaimed rows — cycles are countable" \
  || bad_t "ledger: reclaim cycles collapsed" "task.reclaimed=[$n_recl]"
[[ "$n_start" == "1" ]] \
  && ok_t "ledger: task.started still records the FIRST claim only (constant idem_key, unchanged)" \
  || bad_t "ledger: task.started row count changed" "task.started=[$n_start]"

# ---------------------------------------------------------------------------
# 5. The backfill. From the LEDGER, never from now(); status untouched; a row
#    with nothing usable left UNREPAIRED rather than fabricated.
# ---------------------------------------------------------------------------
LEDGER_TS='2026-08-11 07:30:53'

# (i) the DIVE-3228 shape: a real start on the ledger, both clocks empty.
idr=$(addt "reclaimed-before-the-fix" --assignee=dev)
db "UPDATE tasks SET status='todo', started_at=NULL, first_started_at=NULL WHERE id=${idr};"
db "INSERT INTO lifecycle_events(ts,kind,ident,task_id,actor,authority,idem_key)
      VALUES($(sqlq "$LEDGER_TS"),'task.started','X-1',${idr},'dev','dispatcher','bf|${idr}');"

# (ii) a row with NOTHING usable — no ledger event, no started_at. Must stay NULL.
idu=$(addt "no-evidence-anywhere" --assignee=dev)
db "UPDATE tasks SET status='todo', started_at=NULL, first_started_at=NULL WHERE id=${idu};"

# (iii) a healthy in-flight row whose first_started_at predates the column.
idh=$(addt "in-flight-at-upgrade" --assignee=dev)
db "UPDATE tasks SET status='in_progress', started_at='2026-08-10 12:00:00',
      first_started_at=NULL WHERE id=${idh};"

# Force the store back to a pre-3251 epoch so tasks_db_init really enters the
# migration — the same path every existing seat takes at CLI upgrade, not a
# hand-called helper.
db "UPDATE task_prefs SET value='2730-1' WHERE key='schema_epoch';"
tasks_db_init >/dev/null 2>&1

[[ "$(fld "$idr" first_started_at)" == "$LEDGER_TS" ]] \
  && ok_t "backfill: first_started_at restored from the LEDGER timestamp, exactly" \
  || bad_t "backfill: value is not the ledger timestamp" "want=[$LEDGER_TS] got=[$(fld "$idr" first_started_at)]"
[[ "$(fld "$idr" first_started_at)" != *"$(date -u +%Y-%m-%d)"* || "$LEDGER_TS" == *"$(date -u +%Y-%m-%d)"* ]] \
  && ok_t "backfill: no now() fabrication (the value is the recorded start, not today)" \
  || bad_t "backfill: stamped today instead of the recorded start" "got=[$(fld "$idr" first_started_at)]"
[[ "$(status_of "$idr")" == "todo" ]] \
  && ok_t "backfill: status NOT flipped — 'did work happen' and 'is a seat on it' stay separate" \
  || bad_t "backfill: repair flipped status" "status=[$(status_of "$idr")]"
[[ "$(fld "$idr" started_at)" == "NULL" ]] \
  && ok_t "backfill: started_at left NULL — a backfilled claim clock would arrive at rule (c) instantly ancient" \
  || bad_t "backfill: wrote started_at, re-arming the bug on the repaired row" "got=[$(fld "$idr" started_at)]"
[[ "$(fld "$idu" first_started_at)" == "NULL" ]] \
  && ok_t "backfill: a row with no usable timestamp is LEFT UNREPAIRED, not fabricated" \
  || bad_t "backfill: invented a timestamp for a row with no evidence" "got=[$(fld "$idu" first_started_at)]"
[[ "$(fld "$idh" first_started_at)" == "2026-08-10 12:00:00" ]] \
  && ok_t "backfill: an in-flight row falls back to its own started_at" \
  || bad_t "backfill: in-flight row not seeded from started_at" "got=[$(fld "$idh" first_started_at)]"

# Idempotence: the migration is re-entered on every upgrade, and must not move a
# value it already wrote.
before_r=$(fld "$idr" first_started_at)
db "UPDATE task_prefs SET value='2730-1' WHERE key='schema_epoch';"
tasks_db_init >/dev/null 2>&1
[[ "$(fld "$idr" first_started_at)" == "$before_r" ]] \
  && ok_t "backfill: idempotent — a second migration pass moves nothing" \
  || bad_t "backfill: second pass rewrote the value" "before=[$before_r] after=[$(fld "$idr" first_started_at)]"

# ---------------------------------------------------------------------------
# 6. The board surface. "Distinguishable from the board alone" is the DONE WHEN,
#    so a column that `task show` does not print does not satisfy this row.
# ---------------------------------------------------------------------------
JSON_MODE=0
show_out=$( ( cmd_task_show "$idr" ) 2>&1 )
JSON_MODE=1
grep -q 'first_started_at' <<<"$show_out" \
  && ok_t "task show: first_started_at is printed" \
  || bad_t "task show: the field is invisible from the board" "out=[$show_out]"
grep -q "$LEDGER_TS" <<<"$show_out" \
  && ok_t "task show: a reclaimed row now READS as started, not as never-touched" \
  || bad_t "task show: reclaimed row still reads as never-started" "out=[$show_out]"

# ---------------------------------------------------------------------------
# 6b. INTERACTION WITH ops's RUNG-2 HOLD, which this row explicitly owed and
#     which must not be assumed in either direction.
#
#     _hb_seat_advanced decides whether the nudge ladder HOLDS at rung 2 because
#     the seat has advanced something. Its ledger arm reads lifecycle_events by
#     actor and excludes `authority IN ('heartbeat','dispatcher')` — the engine
#     acting on the seat's behalf is not seat work. The new task.reclaimed event
#     carries actor=<seat> and authority='dispatcher' for exactly that reason: a
#     reclaim is the ENGINE taking a row back, and if it counted as seat advance
#     it would hold the ladder on the strength of the engine's own action —
#     the ladder would be quietly disarmed by the thing it is supposed to catch.
#     Graded, not reasoned about, because "which way does this cut" was the open
#     question on the row.
# ---------------------------------------------------------------------------
# THE EVENT UNDER TEST IS EMITTED BY THE PRODUCT, NOT INSERTED BY THIS HARNESS.
# The first version of this arm hand-wrote a lifecycle_events row with
# authority='dispatcher' baked into the INSERT, and a mutant that flipped the
# real emit to authority='self' SURVIVED it — 30/30 green over a defect that
# would have disarmed the ladder. A fixture that carries the property being
# asserted grades the fixture. So: run a real reclaim and read what it wrote.
#
# The SUBJECT is the reclaimed row itself. _hb_seat_advanced's tasks arm excludes
# `id <> tid`, so asking about the reclaimed row removes the updated_at the
# reclaim stamps on it and leaves the LEDGER arm as the only thing that can
# answer — which is the arm this change adds to.
#
# A SEAT WITH NO HISTORY: the arms above wrote real task.started rows for dev2 at
# authority='self', which legitimately read as seat advance. A control has to
# start where the thing under test is the only thing that can move the answer.
idz=$(addt "rung2-subject" --assignee=rung2seat)
since='2026-08-11 00:00:00'
db "UPDATE tasks SET status='in_progress', assignee='rung2seat',
      started_at=datetime('now','-30 minutes'),
      first_started_at=datetime('now','-30 minutes') WHERE id=${idz};"
db "UPDATE tasks SET updated_at='2026-08-10 00:00:00' WHERE assignee='rung2seat';"
_hb_seat_advanced rung2seat "$idz" "$since" rung2seat
[[ $? -ne 0 ]] && ok_t "rung 2 (precondition): a quiet seat does NOT read as advanced" \
  || bad_t "rung 2 (precondition): seat already reads as advanced — the arm below proves nothing" ""
_hb_claude_started() { date -u +%s; }           # rule (a): a REAL reclaim, real emit
_hb_reclaim rung2seat 10 >/dev/null 2>&1
_hb_claude_started() { echo ""; }
[[ "$(evn "$idz" task.reclaimed)" == "1" ]] \
  && ok_t "rung 2 (precondition): the reclaim really did emit its event" \
  || bad_t "rung 2 (precondition): no event emitted — the arm below proves nothing" "n=[$(evn "$idz" task.reclaimed)]"
db "UPDATE tasks SET updated_at='2026-08-10 00:00:00' WHERE assignee='rung2seat';"
_hb_seat_advanced rung2seat "$idz" "$since" rung2seat
[[ $? -ne 0 ]] \
  && ok_t "rung 2: the reclaim's OWN event does NOT read as seat advance — the ladder stays armed" \
  || bad_t "rung 2: the reclaim event disarms the nudge ladder it is supposed to make visible" ""

# ---------------------------------------------------------------------------
# 7. Structural: all three rules reach the erasure through ONE function. This is
#    what makes the three arms above a complete grade of the erasure rather than
#    three samples of it — if a fourth rule ever inlines its own UPDATE, the
#    per-rule arms would still pass while the evidence was destroyed again.
# ---------------------------------------------------------------------------
# Count SQL sites only — the prose above _hb_reclaim_to_todo names the field on
# purpose, and a comment that explains why the erasure is deliberate must not
# read to this guard as a second erasure.
inline=$(grep -c "UPDATE tasks SET.*started_at=NULL" src/cmd_heartbeat.sh)
inline=$(( inline - 1 ))   # the one legitimate site, inside _hb_reclaim_to_todo
sites=$(grep -c "_hb_reclaim_to_todo \"\$name\"" src/cmd_heartbeat.sh)
[[ "$inline" == "0" ]] \
  && ok_t "structural: cmd_heartbeat.sh clears started_at in exactly one place" \
  || bad_t "structural: an inlined started_at=NULL bypasses the shared reclaim" "extra=[$inline]"
[[ "$sites" == "3" ]] \
  && ok_t "structural: all THREE reclaim rules route through _hb_reclaim_to_todo" \
  || bad_t "structural: reclaim call sites changed — re-grade the per-rule arms" "sites=[$sites]"

printf '\ntask first_started_at: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
