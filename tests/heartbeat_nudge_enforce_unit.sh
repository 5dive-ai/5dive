#!/usr/bin/env bash
# TIER: core
#
# DIVE-3218 — nudge-threshold ENFORCEMENT: the rung that CONSUMES the counter.
#
# WHY THIS HARNESS IS BEHAVIOURAL AND NOT A PREDICATE ONE. The defect it guards is
# not a wrong SELECT — there is no SELECT. `_hb_mark_run` has echoed a per-task
# nudge count since DIVE-1486 "so the caller can decide whether the task is being
# starved", and the only caller that read it wrote a WARN to the log and changed
# nothing. Measured 2026-08-11: dev3 was woken about ONE urgent row (DIVE-2896)
# 173 times over 3.5 days with zero state change, each wake a full fresh-context
# session. The count was correct the whole time. Correct detection wired to no
# lever is the whole bug, so every arm below grades an ACTION.
#
# THE ARM THAT MATTERS MOST IS THE BODY WRITE-BACK. A fresh-context seat has no
# memory of its own previous wakes; the row body is the only thing it re-reads. An
# enforcement action that changes state silently just relocates the
# re-deliberation — the next seat finds a row at a priority it cannot account for
# and reasons from zero again. A future refactor that keeps the escalate and drops
# the note would pass any state assertion and restore the measured defect, so the
# note is asserted by CONTENT, not by "body changed".
#
# Reserved-fake values only: synthetic DIVE-9xxx idents, no live row is touched.
set -euo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: one trap, every exit path.

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

cd "$(dirname "$0")/.."
SRC=src
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not present"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }
TMP=$(mktemp -d /tmp/nudge-enforce.XXXXXX)

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate

# The send rail is REAL here (cmd_agent.sh is sourced), so stub it or a unit test
# injects into live tmux panes. Same posture as heartbeat_recurring_stall_escalate_unit.sh.
AGENT_SEND_LOG="$TMP/agent_sends"; : >"$AGENT_SEND_LOG"
cmd_send() {
  local to="$1" a msg=""; shift
  for a in "$@"; do [[ "$a" == --message=* ]] && msg="${a#--message=}"; done
  printf '%s\t%s\n' "$to" "$msg" >>"$AGENT_SEND_LOG"
  return 0
}
_hb_log() { :; }
audit_log() { :; }

# The registry rail is REAL here too (lib/registry.sh is sourced). Its LOCK path
# runs ensure_state, which makes/chowns a state dir under /var/lib and EXITS the
# process when it cannot — and its writer chowns root:claude. Neither is available
# to an unprivileged unit test, and an exit mid-harness reads as a silent pass on
# every arm after it. Bypass the lock (this harness is single-process, so there is
# no concurrency for it to guard) and redirect the write to the fixture registry.
# The jq transform under test — which key is deleted — is untouched by both.
IN_REGISTRY_LOCK=1
registry_write() { cat > "$REGISTRY"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

REGISTRY="$TMP/registry.json"
# Heartbeat-enabled roster. Who is FREE is decided by the task store, not by this
# list — "free" must be a fact the board holds.
write_registry() {   # $1: optional JSON for .config
  local cfg="${1:-null}"
  jq -n --argjson cfg "$cfg" '{
    agents: {
      main:     {heartbeat:{enabled:true,everyMin:15}},
      dev:      {heartbeat:{enabled:true,everyMin:15}},
      dev2:     {heartbeat:{enabled:true,everyMin:15}},
      creative: {heartbeat:{enabled:true,everyMin:15}},
      asleep:   {heartbeat:{enabled:false,everyMin:15}}
    }
  } + (if $cfg == null then {} else {config: $cfg} end)' >"$REGISTRY"
}

# Lane = org parent. dev and dev2 share one; creative sits under a different head,
# so "lane first" is observable rather than an accident of sort order.
# agents_org.reports_to is a SELF-FK (REFERENCES agents_org(name)), so the two
# heads must land before anyone reporting to them — and '' is not NULL, it is a
# dangling reference the constraint rejects. Getting this wrong is silent in the
# worst way: the inserts fail, every lane lookup returns empty, and arm 4's
# "lane-mate preferred" assertion still passes on the any-free-agent fallback.
db "DELETE FROM agents_org;
    INSERT INTO agents_org (name,reports_to) VALUES ('main',NULL),('anton',NULL);
    INSERT INTO agents_org (name,reports_to) VALUES
      ('dev','main'),('dev2','main'),('creative','anton');"
[[ "$(db "SELECT COUNT(*) FROM agents_org;")" == "5" ]] \
  || { echo "HARNESS BUG: agents_org fixture did not land — lane arms would pass on the fallback"; exit 1; }

col()  { db "SELECT COALESCE($2,'NULL') FROM tasks WHERE id=$1;"; }
body() { db "SELECT COALESCE(body,'') FROM tasks WHERE id=$1;"; }
sent() { cut -f1 "$AGENT_SEND_LOG" | sort -u | tr '\n' ' '; }
notes(){ body "$1" | grep -c 'nudge-enforcement (DIVE-3218)'; }

# One todo row assigned to dev, plus a nudge counter for it in the registry.
# $1 id, $2 ident, $3 priority, $4 nudge count to seed, $5 optional verifier
mk_row() {
  db "DELETE FROM tasks; DELETE FROM lifecycle_events;"
  : >"$AGENT_SEND_LOG"
  db "INSERT INTO tasks (id,ident,title,body,status,kind,priority,assignee,created_by,created_at,verifier)
      VALUES ($1,$(sqlq "$2"),'synthetic starved row','ORIGINAL FILER TEXT.','todo','standard',
              $(sqlq "$3"),'dev','main',datetime('now','-3 days'),$(sqlq "${5:-}"));"
  jq --arg tid "$1" --argjson n "$4" '.agents.dev.heartbeat.nudges = {($tid): $n}' \
     "$REGISTRY" >"$REGISTRY.t" && mv "$REGISTRY.t" "$REGISTRY"
}
# Occupy an agent so _hb_free_agents does not offer them.
busy() { db "INSERT INTO tasks (ident,title,status,kind,assignee,created_at)
             VALUES ($(sqlq "DIVE-9000-busy-$1"),'other work','in_progress','standard',$(sqlq "$1"),datetime('now','-2 hours'));"; }
nudge_count() { jq -r --arg tid "$1" '.agents.dev.heartbeat.nudges[$tid] // "ABSENT"' "$REGISTRY"; }
# Put a row into "rung 1 already fired at count $2" — the only state from which
# rung 2 is reachable. Rung 2 is deliberately never a first contact.
stamp_rung1() { db "UPDATE tasks SET nudge_escalated_at=datetime('now','-1 hours'), nudge_escalated_n=$2 WHERE id=$1;"; }

write_registry

# ---------------------------------------------------------------------------
# 1. BELOW the band threshold: the ladder is silent. A row nudged a few times is
#    ordinary scheduling, not starvation — firing here would escalate the whole
#    board on its first slow morning.
# ---------------------------------------------------------------------------
mk_row 1 'DIVE-9001' high 7
_hb_nudge_enforce dev 1 DIVE-9001 7 >/dev/null 2>&1
[[ "$(col 1 nudge_escalated_at)" == "NULL" && "$(col 1 priority)" == "high" ]] \
  && ok_t "below N (7 of 16, band high) nothing fires — no escalate, no stamp" \
  || bad_t "below N nothing fires" "stamp=[$(col 1 nudge_escalated_at)] priority=[$(col 1 priority)]"
[[ "$(notes 1)" == "0" ]] \
  && ok_t "below N the body is left alone" \
  || bad_t "below N the body is left alone" "note count=[$(notes 1)]"

# ---------------------------------------------------------------------------
# 2. RUNG 1 at N: priority changes AND the reason is written into the row.
# ---------------------------------------------------------------------------
mk_row 2 'DIVE-9002' high 16
_hb_nudge_enforce dev 2 DIVE-9002 16 >/dev/null 2>&1
[[ "$(col 2 priority)" == "urgent" ]] \
  && ok_t "rung 1 escalates the row (high -> urgent) — a CHANGED state, not another nudge" \
  || bad_t "rung 1 escalates the row" "priority=[$(col 2 priority)] want urgent"
[[ "$(col 2 nudge_escalated_at)" != "NULL" ]] \
  && ok_t "rung 1 stamps nudge_escalated_at (the once-per-row latch)" \
  || bad_t "rung 1 stamps nudge_escalated_at" "stamp is NULL"
[[ "$(notes 2)" == "1" ]] \
  && ok_t "rung 1 writes exactly ONE dated line into the row body" \
  || bad_t "rung 1 writes one dated line into the body" "note count=[$(notes 2)]"
case "$(body 2)" in
  *"ORIGINAL FILER TEXT."*) ok_t "the note is APPENDED — the filer's words survive" ;;
  *) bad_t "the note is appended, not a rewrite" "filer text gone from body" ;;
esac
case "$(body 2)" in
  *"WRITE WHY"*) ok_t "the note instructs the next seat to RECORD a not-starting decision (the 173-wake fix)" ;;
  *) bad_t "the note instructs the next seat to record its decision" "body: $(body 2)" ;;
esac
case "$(body 2)" in
  *"$(date -u +%Y-%m-%d)"*) ok_t "the note is DATED, so a later reader can tell it from the filer's text" ;;
  *) bad_t "the note is dated" "body: $(body 2)" ;;
esac
[[ -n "$(db "SELECT 1 FROM lifecycle_events WHERE kind='task.nudge_enforced' AND ident='DIVE-9002' LIMIT 1;")" ]] \
  && ok_t "rung 1 is on the append-only ledger, not only in the body" \
  || bad_t "rung 1 is on the ledger" "no task.nudge_enforced row for DIVE-9002"

# ---------------------------------------------------------------------------
# 3. The rung-1 LATCH. Without it the ladder re-fires every tick between N and
#    2N: a row would be escalated a dozen times and its body would grow one
#    identical paragraph per wake — trading a nudge loop for a write loop.
# ---------------------------------------------------------------------------
_hb_nudge_enforce dev 2 DIVE-9002 17 >/dev/null 2>&1
_hb_nudge_enforce dev 2 DIVE-9002 18 >/dev/null 2>&1
[[ "$(notes 2)" == "1" ]] \
  && ok_t "rung 1 fires ONCE per row — re-ticks below rung 2 add no second note" \
  || bad_t "rung 1 fires once per row" "note count after 3 calls=[$(notes 2)] want 1"
# THE REGRESSION THIS HARNESS FOUND. Rung 1 escalated DIVE-9002 high -> urgent, and
# urgent carries a SMALLER N (8) than high (16). Keyed to a recomputed 2*N, rung 2
# would be 16 — a count the row was already at when rung 1 fired, so escalate and
# reassign landed on the same wake and the ladder had one rung. Keyed to
# nudge_escalated_n + N it is 24, which is what "a further threshold of fruitless
# wakes AFTER we escalated" actually means.
[[ "$(col 2 nudge_parked_at)" == "NULL" && "$(col 2 assignee)" == "dev" ]] \
  && ok_t "rung 2 does NOT ride along on rung 1's wake — escalating shrinks the band's N, and the ladder is immune to that" \
  || bad_t "rung 2 does not fire on rung 1's wake" "parked_at=[$(col 2 nudge_parked_at)] assignee=[$(col 2 assignee)]"
_hb_nudge_enforce dev 2 DIVE-9002 24 >/dev/null 2>&1
[[ "$(col 2 nudge_parked_at)" != "NULL" ]] \
  && ok_t "and it DOES fire at nudge_escalated_n + N (16+8=24) — the ladder still has a second rung" \
  || bad_t "rung 2 fires at nudge_escalated_n + N" "parked_at still NULL at 24"

# ---------------------------------------------------------------------------
# 3b. RUNG 2 IS NEVER A FIRST CONTACT. A row inherited at a huge count (the
#     measured shape: 173 nudges before anything consumed the counter) gets rung
#     1 — escalate AND a written explanation — before its hands are changed. A
#     reassignment nobody was warned about, on a row whose body says nothing, is
#     the same silent state change from the other direction.
# ---------------------------------------------------------------------------
mk_row 3 'DIVE-9003' urgent 173
_hb_nudge_enforce dev 3 DIVE-9003 173 >/dev/null 2>&1
[[ "$(col 3 nudge_escalated_at)" != "NULL" && "$(col 3 nudge_parked_at)" == "NULL" && "$(col 3 assignee)" == "dev" ]] \
  && ok_t "a row arriving at 173 nudges takes rung 1 FIRST — never a cold reassign" \
  || bad_t "rung 2 is never a first contact" "esc=[$(col 3 nudge_escalated_at)] parked=[$(col 3 nudge_parked_at)] assignee=[$(col 3 assignee)]"

# ---------------------------------------------------------------------------
# 4. RUNG 2 at 2N with a free LANE-MATE: the row changes hands.
# ---------------------------------------------------------------------------
mk_row 4 'DIVE-9004' high 32
stamp_rung1 4 16
busy creative                     # only dev2 (dev's lane) is free
_hb_nudge_enforce dev 4 DIVE-9004 32 >/dev/null 2>&1
[[ "$(col 4 assignee)" == "dev2" ]] \
  && ok_t "rung 2 reassigns to a FREE agent in the same org lane" \
  || bad_t "rung 2 reassigns to a free lane-mate" "assignee=[$(col 4 assignee)] want dev2"
[[ "$(col 4 status)" == "todo" && "$(col 4 nudge_parked_at)" != "NULL" ]] \
  && ok_t "the row stays OPEN and is stamped (rung 2's once-per-row latch)" \
  || bad_t "the row stays open and is stamped" "status=[$(col 4 status)] stamp=[$(col 4 nudge_parked_at)]"
[[ "$(notes 4)" == "1" ]] \
  && ok_t "rung 2 also writes its reason into the body — a silent reassignment teaches the new seat nothing" \
  || bad_t "rung 2 writes its reason into the body" "note count=[$(notes 4)]"
[[ "$(nudge_count 4)" == "ABSENT" ]] \
  && ok_t "the OLD assignee's counter is CLEARED — the row left their hands, so the count must not read as a live starvation" \
  || bad_t "the old assignee's nudge counter is cleared" "still [$(nudge_count 4)]"
case " $(sent) " in *" dev2 "*) ok_t "the NEW hands are told" ;; *) bad_t "the new hands are told" "sends: [$(sent)]" ;; esac
case " $(sent) " in *" dev "*) ok_t "the OLD assignee is told (never a silent move)" ;; *) bad_t "the old assignee is told" "sends: [$(sent)]" ;; esac

# ---------------------------------------------------------------------------
# 5. RUNG 2 with NOBODY free: PARK with a wake date. NEVER cancel.
#
#    This is where the ladder deliberately parts from DIVE-2853, whose fallback
#    IS a cancel. That one cancels because an open recurring instance suppresses
#    every later slot of its beat, so leaving it open is an ongoing outage. A
#    standard row suppresses nothing — it is merely starved, and a starved row is
#    not an unwanted row. An auto-cancel here destroys asked-for work on the
#    evidence that nobody got to it.
# ---------------------------------------------------------------------------
mk_row 5 'DIVE-9005' high 32
stamp_rung1 5 16
busy creative; busy dev2; busy main
_hb_nudge_enforce dev 5 DIVE-9005 32 >/dev/null 2>&1
[[ "$(col 5 status)" == "blocked" && "$(col 5 wake_at)" != "NULL" ]] \
  && ok_t "rung 2 with no free agent PARKS with a wake date (auto-unparks later)" \
  || bad_t "rung 2 parks with a wake date" "status=[$(col 5 status)] wake_at=[$(col 5 wake_at)]"
[[ "$(col 5 status)" != "cancelled" && "$(col 5 assignee)" == "dev" ]] \
  && ok_t "NEVER cancelled, and the row is not silently orphaned off its assignee" \
  || bad_t "never cancelled" "status=[$(col 5 status)] assignee=[$(col 5 assignee)]"
[[ "$(col 5 park_reason)" != "NULL" && "$(notes 5)" == "1" ]] \
  && ok_t "the park carries a written reason in BOTH park_reason and the body" \
  || bad_t "the park carries a written reason" "park_reason=[$(col 5 park_reason)] notes=[$(notes 5)]"
[[ "$(nudge_count 5)" == "ABSENT" ]] \
  && ok_t "parking clears the counter, so the row does not re-trip the ladder on unpark" \
  || bad_t "parking clears the counter" "still [$(nudge_count 5)]"

# ---------------------------------------------------------------------------
# 6. A row blocked on an UNANSWERED HUMAN GATE is never parked over. Park and a
#    gate share status='blocked' and overlapping need_* columns, so writing a park
#    across a live gate destroys it (DIVE-1453) — the wait there is on a person,
#    and the nudges are the gate's own renag, not starvation.
# ---------------------------------------------------------------------------
mk_row 6 'DIVE-9006' high 32
stamp_rung1 6 16
db "UPDATE tasks SET need_type='decision', need_asked_at=datetime('now','-2 days') WHERE id=6;"
busy creative; busy dev2; busy main
_hb_nudge_enforce dev 6 DIVE-9006 32 >/dev/null 2>&1
[[ "$(col 6 status)" == "todo" && "$(col 6 park_reason)" == "NULL" ]] \
  && ok_t "a row with a live human gate is NOT parked over (DIVE-1453 guard holds)" \
  || bad_t "a live human gate is not parked over" "status=[$(col 6 status)] park_reason=[$(col 6 park_reason)]"

# ---------------------------------------------------------------------------
# 7. The row's own VERIFIER is never the reassign target — landing them as
#    assignee manufactures the assignee==verifier, no-handoff shape DIVE-2899
#    named, this time self-inflicted by the heartbeat (the DIVE-3097 scope).
# ---------------------------------------------------------------------------
mk_row 7 'DIVE-9007' high 32 dev2
stamp_rung1 7 16
busy creative; busy main
_hb_nudge_enforce dev 7 DIVE-9007 32 >/dev/null 2>&1
[[ "$(col 7 assignee)" != "dev2" ]] \
  && ok_t "the row's VERIFIER is skipped as a reassign target (falls through to park)" \
  || bad_t "the verifier is skipped as a reassign target" "assignee=[$(col 7 assignee)] — dev2 is this row's verifier"
# ANCHOR: same fixture, no verifier -> dev2 IS chosen. Proves arm 7 is the
# exclusion firing and not incidental candidate ordering.
mk_row 8 'DIVE-9008' high 32
stamp_rung1 8 16
busy creative; busy main
_hb_nudge_enforce dev 8 DIVE-9008 32 >/dev/null 2>&1
[[ "$(col 8 assignee)" == "dev2" ]] \
  && ok_t "ANCHOR: with no verifier the same fixture DOES pick dev2 — arm 7 is the exclusion, not luck" \
  || bad_t "ANCHOR: with no verifier the same fixture picks dev2" "assignee=[$(col 8 assignee)]"

# ---------------------------------------------------------------------------
# 8. BAND SCALING. Same count, different band, different answer — the burn per
#    wake is equal but the tolerable latency is not.
# ---------------------------------------------------------------------------
mk_row 9 'DIVE-9009' urgent 8
_hb_nudge_enforce dev 9 DIVE-9009 8 >/dev/null 2>&1
[[ "$(col 9 nudge_escalated_at)" != "NULL" ]] \
  && ok_t "an URGENT row crosses rung 1 at 8 nudges (~2h at the 15m cadence, hours not days)" \
  || bad_t "an urgent row crosses at 8" "stamp is NULL"
mk_row 10 'DIVE-9010' low 8
_hb_nudge_enforce dev 10 DIVE-9010 8 >/dev/null 2>&1
[[ "$(col 10 nudge_escalated_at)" == "NULL" ]] \
  && ok_t "a LOW row at the SAME count does not (N=64) — the threshold is per band" \
  || bad_t "a low row at 8 nudges does not fire" "stamp=[$(col 10 nudge_escalated_at)]"

# ---------------------------------------------------------------------------
# 9. CONFIG, not a hardcode: the registry overrides N.
# ---------------------------------------------------------------------------
write_registry '{"heartbeat":{"nudgeEnforceAfter":{"urgent":3}}}'
mk_row 11 'DIVE-9011' urgent 3
_hb_nudge_enforce dev 11 DIVE-9011 3 >/dev/null 2>&1
[[ "$(col 11 nudge_escalated_at)" != "NULL" ]] \
  && ok_t "registry .config.heartbeat.nudgeEnforceAfter.urgent lowers N to 3 (tunable without a release cut)" \
  || bad_t "registry config lowers N" "stamp is NULL with config urgent=3"

# ---------------------------------------------------------------------------
# 10. A GARBLED config falls back to the DEFAULT, never to "off". An unreadable
#     config silently restoring the 173-wake world is the exact failure this
#     ladder exists to end, so there is no config value that disables it.
# ---------------------------------------------------------------------------
write_registry '{"heartbeat":{"nudgeEnforceAfter":{"urgent":"soon"}}}'
mk_row 12 'DIVE-9012' urgent 8
_hb_nudge_enforce dev 12 DIVE-9012 8 >/dev/null 2>&1
[[ "$(col 12 nudge_escalated_at)" != "NULL" ]] \
  && ok_t "a non-numeric config value falls back to the default N — it does NOT disable the ladder" \
  || bad_t "garbled config falls back to the default" "stamp is NULL"
write_registry '{"heartbeat":{"nudgeEnforceAfter":{"urgent":0}}}'
mk_row 13 'DIVE-9013' urgent 8
_hb_nudge_enforce dev 13 DIVE-9013 8 >/dev/null 2>&1
[[ "$(col 13 nudge_escalated_at)" != "NULL" ]] \
  && ok_t "N=0 is rejected as a disable-by-config back door — the default stands" \
  || bad_t "N=0 does not disable the ladder" "stamp is NULL"
write_registry

# ---------------------------------------------------------------------------
# 11. THE WIRING. Every arm above calls _hb_nudge_enforce directly, which grades
#     the ladder and says NOTHING about whether the tick path invokes it — delete
#     the call site and all 31 arms above still pass, which is precisely the
#     shape of the bug being fixed (a correct mechanism nobody calls). Asserted
#     against the source because the tick loop needs tmux, a fleet and a real
#     registry that a unit harness cannot stand up. It is a weak check by design:
#     it proves the call EXISTS and sits after _hb_mark_run (whose echoed count it
#     consumes), not that a live tick reaches it.
# ---------------------------------------------------------------------------
_wire=$(grep -n '_hb_nudge_enforce "\$name" "\$task_id"' "$SRC/cmd_heartbeat.sh" | cut -d: -f1 | head -1)
_mark=$(grep -n 'nudge_n=\$(with_registry_lock _hb_mark_run' "$SRC/cmd_heartbeat.sh" | cut -d: -f1 | head -1)
[[ -n "$_wire" && -n "$_mark" ]] && (( _wire > _mark )) \
  && ok_t "the tick path CALLS the ladder, after _hb_mark_run — a consumer that is never invoked is the original bug" \
  || bad_t "the tick path calls the ladder after _hb_mark_run" "call site line=[${_wire:-none}] _hb_mark_run line=[${_mark:-none}]"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
