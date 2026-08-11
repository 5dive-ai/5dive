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
# 10b. WHAT MUST NOT BE SAID WHEN THE WRITE DID NOT LAND (iteration 2 — quinn's
#      reject). Every rung-2 write is GUARDED, and arms 5/6 grade only the
#      resulting STATE (status, park_reason), which is identical whether the
#      narration ran or not. So the whole load-bearing half — the body note, the
#      pings, the ledger event — could fire ahead of an UPDATE that matched ZERO
#      rows and every arm above would still pass. That is not a cosmetic ordering
#      bug on THIS design: the body note is the only memory a fresh-context seat
#      has, so a note claiming a park that never happened is strictly worse than
#      silence — the next seat reasons from a state that does not exist. And
#      because the once-per-row latch rides in the same refused statement, the
#      false note, the false ping and the false ledger event RE-FIRE every N
#      nudges forever.
#
#      These arms grade the NEGATIVE: on a refused write, note count 0, empty
#      send log, no ledger event, latch still NULL, counter untouched.
# ---------------------------------------------------------------------------
led() { db "SELECT COUNT(*) FROM lifecycle_events WHERE kind='task.nudge_enforced' AND ident=$(sqlq "$1");"; }
silent() {   # $1 id, $2 ident, $3 what-was-refused (for the failure text)
  local id="$1" ident="$2" what="$3" bad=""
  [[ "$(notes "$id")" == "0" ]]              || bad+=" note-count=[$(notes "$id")]"
  [[ -z "$(sent)" ]]                         || bad+=" sends=[$(sent)]"
  [[ "$(col "$id" nudge_parked_at)" == "NULL" ]] || bad+=" nudge_parked_at=[$(col "$id" nudge_parked_at)]"
  [[ "$(led "$ident")" == "0" ]]             || bad+=" ledger-rows=[$(led "$ident")]"
  [[ -z "$bad" ]] \
    && ok_t "${what}: the row is told NOTHING — no body note, no ping, no ledger event, latch unarmed" \
    || bad_t "${what}: nothing is said when the write did not land" "$bad"
}

# A. A live human gate + a FREE agent. Arm 6 covers the park side; the reassign
#    side had no guard at all, so a gated row would have CHANGED HANDS — moving a
#    row whose wait is on a person to a second agent who also cannot act on it.
mk_row 14 'DIVE-9014' high 32
stamp_rung1 14 16
db "UPDATE tasks SET need_type='decision', need_asked_at=datetime('now','-2 days') WHERE id=14;"
busy creative; busy main          # dev2 is free and IS a lane-mate — it would be picked
_hb_nudge_enforce dev 14 DIVE-9014 32 >/dev/null 2>&1
[[ "$(col 14 assignee)" == "dev" && "$(col 14 status)" == "todo" ]] \
  && ok_t "a row on a live human gate is not REASSIGNED either — a gate is not starvation, whoever is free" \
  || bad_t "a gated row is not reassigned" "assignee=[$(col 14 assignee)] status=[$(col 14 status)]"
silent 14 DIVE-9014 "gated row, free agent available"
[[ "$(nudge_count 14)" == "32" ]] \
  && ok_t "and the counter is LEFT INTACT — clearing it would read as an enforcement that never happened" \
  || bad_t "a held rung 2 leaves the counter intact" "count=[$(nudge_count 14)] want 32"

# B. Same gate, nobody free — arm 6's fixture, graded for its NARRATION. This is
#    the exact case quinn reproduced: status and park_reason both correct, and the
#    body still claiming "PARKED for 1d ... auto-unparks on its wake date".
mk_row 15 'DIVE-9015' high 32
stamp_rung1 15 16
db "UPDATE tasks SET need_type='decision', need_asked_at=datetime('now','-2 days') WHERE id=15;"
busy creative; busy dev2; busy main
_hb_nudge_enforce dev 15 DIVE-9015 32 >/dev/null 2>&1
[[ "$(col 15 status)" == "todo" && "$(col 15 park_reason)" == "NULL" ]] \
  && ok_t "gated + nobody free: still not parked (the DIVE-1453 guard holds)" \
  || bad_t "gated + nobody free is not parked" "status=[$(col 15 status)] park_reason=[$(col 15 park_reason)]"
silent 15 DIVE-9015 "gated row, nobody free"
[[ "$(nudge_count 15)" == "32" ]] \
  && ok_t "counter intact there too, so the row does not silently restart its ladder every N nudges" \
  || bad_t "a refused park leaves the counter intact" "count=[$(nudge_count 15)] want 32"

# C. The STATUS guard, with no gate in play — proving the changes() check itself
#    and not just the early hold above. A row that reaches rung 2 outside
#    todo/in_progress gets no note and nobody gets pinged about a move that the
#    guard refused.
mk_row 16 'DIVE-9016' high 32
stamp_rung1 16 16
db "UPDATE tasks SET status='done' WHERE id=16;"
busy creative; busy main          # dev2 free, so a target IS selected
_hb_nudge_enforce dev 16 DIVE-9016 32 >/dev/null 2>&1
[[ "$(col 16 assignee)" == "dev" ]] \
  && ok_t "rung 2's status guard refuses the reassign of a closed row" \
  || bad_t "rung 2's status guard refuses a closed row" "assignee=[$(col 16 assignee)]"
silent 16 DIVE-9016 "reassign refused by the status guard"

# D. Rung 1 under the same discipline. Its latch UPDATE is the statement a guard
#    can refuse, so it runs FIRST and nothing is written on a zero-row result.
mk_row 17 'DIVE-9017' high 16
db "UPDATE tasks SET status='cancelled' WHERE id=17;"
_hb_nudge_enforce dev 17 DIVE-9017 16 >/dev/null 2>&1
[[ "$(col 17 nudge_escalated_at)" == "NULL" && "$(col 17 priority)" == "high" && "$(notes 17)" == "0" && "$(led DIVE-9017)" == "0" ]] \
  && ok_t "rung 1 on a closed row says nothing and arms no latch" \
  || bad_t "rung 1 on a closed row is silent" "esc=[$(col 17 nudge_escalated_at)] pri=[$(col 17 priority)] notes=[$(notes 17)] ledger=[$(led DIVE-9017)]"

# E. The COSMETIC LIE quinn also caught: rung 1's note promised rung 2 at
#    nudge_n + N(pre-escalation band), but rung 2 recomputes N from the RAISED
#    band, and a higher band carries a SMALLER N — the note said 32 where the
#    code fires at 24. A wrong number in the one artifact a fresh seat reads is a
#    wrong number, not a typo.
mk_row 18 'DIVE-9018' high 16
_hb_nudge_enforce dev 18 DIVE-9018 16 >/dev/null 2>&1
case "$(body 18)" in
  *"At 24 nudges"*) ok_t "rung 1's note names the wake rung 2 ACTUALLY fires on (16 + urgent's 8 = 24, not high's 16)" ;;
  *) bad_t "rung 1's note names the real rung-2 wake" "body: $(body 18)" ;;
esac
case "$(body 18)" in
  *"ESCALATED high -> urgent"*) ok_t "and it states the bump that actually landed, read back from the row" ;;
  *) bad_t "rung 1's note states the bump that landed" "body: $(body 18)" ;;
esac
# An ALREADY-urgent row: `task escalate` is capped there, so the note must not
# claim a bump. The note is the whole lever on exactly these rows.
mk_row 19 'DIVE-9019' urgent 8
_hb_nudge_enforce dev 19 DIVE-9019 8 >/dev/null 2>&1
case "$(body 19)" in
  *"ALREADY urgent"*) ok_t "on an already-urgent row the note says escalation was capped, not that it escalated" ;;
  *) bad_t "an already-urgent row's note does not claim a bump" "body: $(body 19)" ;;
esac

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
_wire=$(grep -n '_hb_nudge_enforce "\$name" "\$task_id"' "$SRC/cmd_heartbeat.sh" | cut -d: -f1 | head -1) || _wire=""
_mark=$(grep -n 'nudge_n=\$(with_registry_lock _hb_mark_run' "$SRC/cmd_heartbeat.sh" | cut -d: -f1 | head -1) || _mark=""
[[ -n "$_wire" && -n "$_mark" ]] && (( _wire > _mark )) \
  && ok_t "the tick path CALLS the ladder, after _hb_mark_run — a consumer that is never invoked is the original bug" \
  || bad_t "the tick path calls the ladder after _hb_mark_run" "call site line=[${_wire:-none}] _hb_mark_run line=[${_mark:-none}]"

# ---------------------------------------------------------------------------
# 12. THE SIBLING HOLD (main, 2026-08-11). The gate hold in arm 6 says a row
#     waiting on a person is not starved. Its sibling: a row waiting behind its
#     own assignee's OTHER work is not starved either — the wait is on a QUEUE,
#     and neither rung-2 lever addresses a queue. A seat working a deliberate
#     multi-row order accumulates nudges on rows 2..N BY CONSTRUCTION, precisely
#     because it is productively working row 1.
#
#     Every arm here is fixtured so that WITHOUT the hold rung 2 would PARK
#     (all other agents busy), so "did not fire" is a real observation and not
#     the reassign branch quietly failing to find a target. 12b is the anchor
#     that proves it.
# ---------------------------------------------------------------------------
# A row `dev` demonstrably moved AFTER rung 1 fired (rung 1 is stamped -1 hour).
adv_row() { db "INSERT INTO tasks (ident,title,status,kind,assignee,created_at,updated_at)
                VALUES ($(sqlq "$1"),'the row dev is actually working','in_progress','standard','dev',
                        datetime('now','-3 days'),datetime('now'));"; }
led() { db "INSERT INTO lifecycle_events (kind,actor,authority,idem_key,ts)
            VALUES ('task.update',$(sqlq "$1"),$(sqlq "$2"),$(sqlq "idem-$1-$2-$3"),datetime('now'));"; }
held() {  # $1 id -> "1" when rung 2 did nothing at all
  [[ "$(col "$1" status)" == "todo" && "$(col "$1" nudge_parked_at)" == "NULL" \
     && "$(col "$1" assignee)" == "dev" && "$(notes "$1")" == "0" ]] && echo 1 || echo 0; }

# 12a — the measured case: dev advanced a DIFFERENT row since rung 1.
mk_row 20 'DIVE-9020' high 32
stamp_rung1 20 16
busy creative; busy dev2; busy main
adv_row 'DIVE-9020-other'
_hb_nudge_enforce dev 20 DIVE-9020 32 >/dev/null 2>&1
[[ "$(held 20)" == "1" ]] \
  && ok_t "rung 2 HOLDS when the assignee advanced another row since rung 1 — queued behind its own work, not starved" \
  || bad_t "rung 2 holds for a productively-working seat" "status=[$(col 20 status)] parked=[$(col 20 nudge_parked_at)] assignee=[$(col 20 assignee)] notes=[$(notes 20)]"
[[ "$(nudge_count 20)" == "32" ]] \
  && ok_t "a HOLD leaves the counter intact — we did not act, so nothing may read as if we had" \
  || bad_t "the hold leaves the counter intact" "count=[$(nudge_count 20)] want 32"
[[ -z "$(sent)" ]] \
  && ok_t "a HOLD sends nothing — no seat is told about an action that did not happen" \
  || bad_t "the hold sends nothing" "sends: [$(sent)]"

# 12b — ANCHOR. Byte-identical fixture MINUS the advanced row: rung 2 DOES fire.
# Without this, 12a passes just as well against a rung 2 that is broken outright.
mk_row 21 'DIVE-9021' high 32
stamp_rung1 21 16
busy creative; busy dev2; busy main
_hb_nudge_enforce dev 21 DIVE-9021 32 >/dev/null 2>&1
[[ "$(held 21)" == "0" ]] \
  && ok_t "ANCHOR: the same fixture with NO seat advance still fires (parks) — 12a is the hold, not a dead rung" \
  || bad_t "ANCHOR: rung 2 fires when the seat advanced nothing" "status=[$(col 21 status)] parked=[$(col 21 nudge_parked_at)]"

# 12c — TRAP ONE. Rung 1 stamps `updated_at` on every row it fires on, so a seat
# whose OTHER rows the ENGINE touched looks busy to a naive "any row changed"
# read — and a completely dead seat would hold forever. An engine-stamped row is
# NOT evidence of seat work.
mk_row 22 'DIVE-9022' high 32
stamp_rung1 22 16
busy creative; busy dev2; busy main
db "INSERT INTO tasks (ident,title,status,kind,assignee,created_at,updated_at,nudge_escalated_at)
    VALUES ('DIVE-9022-engine','a row the ENGINE escalated, not dev','todo','standard','dev',
            datetime('now','-3 days'),datetime('now'),datetime('now'));"
_hb_nudge_enforce dev 22 DIVE-9022 32 >/dev/null 2>&1
[[ "$(held 22)" == "0" ]] \
  && ok_t "an ENGINE-stamped sibling row is not counted as seat advance — a dead seat cannot hold the ladder off with the engine's own writes" \
  || bad_t "engine-stamped rows do not count as advance" "status=[$(col 22 status)] parked=[$(col 22 nudge_parked_at)]"

# 12d — TRAP TWO. Dispatcher claims are written to lifecycle_events with the
# SEAT'S OWN NAME as actor (measured on the live board 2026-08-11: olivia, dev,
# ops, quinn all appear this way under authority='dispatcher'). That is the
# engine claiming ON the seat's behalf, not the seat working.
mk_row 23 'DIVE-9023' high 32
stamp_rung1 23 16
busy creative; busy dev2; busy main
led dev dispatcher 23
led task-engine heartbeat 23
_hb_nudge_enforce dev 23 DIVE-9023 32 >/dev/null 2>&1
[[ "$(held 23)" == "0" ]] \
  && ok_t "a dispatcher claim and a task-engine event are not seat advance — the engine cannot vouch for the seat it is judging" \
  || bad_t "dispatcher/heartbeat ledger rows do not count as advance" "status=[$(col 23 status)] parked=[$(col 23 nudge_parked_at)]"

# 12e — the ledger reading WIDENS the hold: seat work that left no `updated_at`
# of its own on another row is still an advance.
mk_row 24 'DIVE-9024' high 32
stamp_rung1 24 16
busy creative; busy dev2; busy main
led dev self 24
_hb_nudge_enforce dev 24 DIVE-9024 32 >/dev/null 2>&1
[[ "$(held 24)" == "1" ]] \
  && ok_t "seat work visible only on the ledger (authority='self') also holds rung 2" \
  || bad_t "ledger-only seat work holds rung 2" "status=[$(col 24 status)] parked=[$(col 24 nudge_parked_at)]"

# 12f — a SILENT hold is indistinguishable from a ladder that never armed, which
# is the DIVE-3218 defect wearing a different hat. Assert the narration by
# CONTENT, the same way the body notes are asserted above.
mk_row 25 'DIVE-9025' high 32
stamp_rung1 25 16
busy creative; busy dev2; busy main
adv_row 'DIVE-9025-other'
_HB_LOG_CAP="$TMP/hold.log"; : >"$_HB_LOG_CAP"
_hb_log() { printf '%s\n' "$1" >>"$_HB_LOG_CAP"; }
_hb_nudge_enforce dev 25 DIVE-9025 32 >/dev/null 2>&1
_hb_log() { :; }
case "$(cat "$_HB_LOG_CAP")" in
  *"rung 2 HELD"*"advanced other rows"*) ok_t "the hold NARRATES itself — a silent hold reads as a ladder that never armed" ;;
  *) bad_t "the hold narrates itself" "log: [$(cat "$_HB_LOG_CAP")]" ;;
esac

# 12g — the hold is scoped to RUNG 2. A productively-working seat still gets
# rung 1 (escalate + the written note), which costs the row nothing and is the
# half that ends the re-derivation. Holding rung 1 too would restore the
# 173-wake world for every busy seat on the fleet.
mk_row 26 'DIVE-9026' high 16
adv_row 'DIVE-9026-other'
_hb_nudge_enforce dev 26 DIVE-9026 16 >/dev/null 2>&1
[[ "$(col 26 nudge_escalated_at)" != "NULL" && "$(notes 26)" == "1" ]] \
  && ok_t "the hold is RUNG 2 ONLY — rung 1 still escalates and writes its note for a busy seat" \
  || bad_t "rung 1 is unaffected by the seat-advance hold" "esc=[$(col 26 nudge_escalated_at)] notes=[$(notes 26)]"

# 12h — WIRING, same posture as arm 11: the helper existing proves nothing about
# rung 2 consulting it. Assert the call sits inside rung 2 and AFTER the gate
# hold, so the two holds cannot be reordered into one that shadows the other.
_gate=$(grep -n 'rung 2 HELD: unanswered human gate' "$SRC/cmd_heartbeat.sh" | cut -d: -f1 | head -1) || _gate=""
_seat=$(grep -n 'if _hb_seat_advanced "\$name" "\$tid" "\$esc_at"' "$SRC/cmd_heartbeat.sh" | cut -d: -f1 | head -1) || _seat=""
_free=$(grep -n 'local free="" target="" cand lane' "$SRC/cmd_heartbeat.sh" | cut -d: -f1 | head -1) || _free=""
[[ -n "$_gate" && -n "$_seat" && -n "$_free" ]] && (( _seat > _gate && _seat < _free )) \
  && ok_t "rung 2 CONSULTS the seat-advance hold, after the gate hold and before any lever — a helper nobody calls is the original bug" \
  || bad_t "rung 2 consults the seat-advance hold in place" "gate=[${_gate:-none}] seat=[${_seat:-none}] levers=[${_free:-none}]"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
