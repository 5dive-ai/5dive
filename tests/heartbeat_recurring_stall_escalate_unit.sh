#!/usr/bin/env bash
# TIER: core
#
# DIVE-2853 — the recurring-stall ladder's SECOND RUNG: the one that CHANGES HANDS.
#
# WHY THIS IS A BEHAVIOURAL HARNESS AND NOT A PREDICATE ONE (its sibling
# heartbeat_recurring_stall_unit.sh grades the first rung's SELECT and explains why
# a predicate test is right there): here the SELECT is the cheap half. What can be
# wrong in a way nobody notices is the ACTION — who the row lands on, and whether a
# tick that cannot read the fleet closes a live row anyway. An escalation that
# reassigns to the same fenced assignee, or that auto-cancels because a registry
# read failed, passes any predicate test and is worse than no escalation at all.
#
# The rung exists because volume cannot be rung 2. Measured on DIVE-2694: flagged on
# time, exactly once, correctly — then unstarted another 28h, because its assignee
# was mid-delivery under a single-task goal and structurally could not take a second
# row. Every arm below is one way that fix could be wrong.
set -euo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: one trap, every exit path.

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

cd "$(dirname "$0")/.."
SRC=src
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not present"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }
TMP=$(mktemp -d /tmp/rec-stall-esc.XXXXXX)

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

# The rail is REAL in this harness (cmd_agent.sh is sourced), so stub it or a unit
# test injects into live tmux panes. Same posture as heartbeat_gate_renag_unit.sh.
AGENT_SEND_LOG="$TMP/agent_sends"; : >"$AGENT_SEND_LOG"
cmd_send() {
  local to="$1" a msg=""; shift
  for a in "$@"; do [[ "$a" == --message=* ]] && msg="${a#--message=}"; done
  printf '%s\t%s\n' "$to" "$msg" >>"$AGENT_SEND_LOG"
  return 0
}
_hb_log() { :; }
audit_log() { :; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

REGISTRY="$TMP/registry.json"
# Every agent here has heartbeat ENABLED; who is free is decided by the task store,
# which is the point — "free" must be a fact the board holds, not a name list.
write_registry() {
  cat >"$REGISTRY" <<'JSON'
{"agents":{
  "main":     {"heartbeat":{"enabled":true,"everyMin":15}},
  "dev":      {"heartbeat":{"enabled":true,"everyMin":15}},
  "creative": {"heartbeat":{"enabled":true,"everyMin":15}},
  "anton":    {"heartbeat":{"enabled":true,"everyMin":15}},
  "asleep":   {"heartbeat":{"enabled":false,"everyMin":15}}
}}
JSON
}
write_registry

# ---------------------------------------------------------------------------
# Fixture builders. One template (created_by=creative, who owns the beat's inputs
# and unstuck it by hand both previous times) plus instances that differ from the
# ESCALATED row in exactly one column each.
# ---------------------------------------------------------------------------
mk_fixture() {
  db "DELETE FROM tasks; DELETE FROM lifecycle_events;"
  : >"$AGENT_SEND_LOG"
  db "INSERT INTO tasks (id,ident,title,status,kind,schedule,assignee,created_by,created_at)
      VALUES (100,'DIVE-1237','openagent drip','todo','recurring','0 4 * * *','dev','creative',datetime('now','-30 days'));"
  # ESCALATE: pinged 25h ago, never started, still todo.
  db "INSERT INTO tasks (id,ident,title,status,kind,assignee,created_by,created_at,from_template_id,recurring_stall_pinged_at)
      VALUES (1,'DIVE-2694','drip slot','todo','standard','dev','task-engine',datetime('now','-3 days'),100,datetime('now','-25 hours'));"
  # never flagged by rung 1 -> rung 2 must not run ahead of it
  db "INSERT INTO tasks (id,ident,title,status,kind,assignee,created_at,from_template_id)
      VALUES (2,'DIVE-2695','drip slot','todo','standard','dev',datetime('now','-3 days'),100);"
  # flagged only 1h ago -> inside the window
  db "INSERT INTO tasks (id,ident,title,status,kind,assignee,created_at,from_template_id,recurring_stall_pinged_at)
      VALUES (3,'DIVE-2696','drip slot','todo','standard','dev',datetime('now','-3 days'),100,datetime('now','-1 hours'));"
  # started -> being worked, not stalled
  db "INSERT INTO tasks (id,ident,title,status,kind,assignee,created_at,started_at,from_template_id,recurring_stall_pinged_at)
      VALUES (4,'DIVE-2697','drip slot','todo','standard','dev',datetime('now','-3 days'),datetime('now','-2 days'),100,datetime('now','-25 hours'));"
  # parked with a wake date -> deliberately asleep
  db "INSERT INTO tasks (id,ident,title,status,kind,assignee,created_at,from_template_id,recurring_stall_pinged_at,parked_at)
      VALUES (5,'DIVE-2698','drip slot','todo','standard','dev',datetime('now','-3 days'),100,datetime('now','-25 hours'),datetime('now','-2 days'));"
  # unanswered human gate -> the wait is on a person, never auto-moved or cancelled
  db "INSERT INTO tasks (id,ident,title,status,kind,assignee,created_at,from_template_id,recurring_stall_pinged_at,need_type)
      VALUES (6,'DIVE-2699','drip slot','todo','standard','dev',datetime('now','-3 days'),100,datetime('now','-25 hours'),'decision');"
  # not from a template -> no beat to restore
  db "INSERT INTO tasks (id,ident,title,status,kind,assignee,created_at,recurring_stall_pinged_at)
      VALUES (7,'DIVE-2700','one-off','todo','standard','dev',datetime('now','-3 days'),datetime('now','-25 hours'));"
}
# dev is OCCUPIED: this is the DIVE-2694 shape — the flagged row's assignee holds an
# in_progress row, so a re-ping to them is undeliverable-in-effect. It also keeps
# gap#3's fleet-idle branch (and its tmux probe) out of this harness.
busy() { db "INSERT INTO tasks (ident,title,status,kind,assignee,created_at)
             VALUES ($(sqlq "DIVE-28-busy-$1"),'other work','in_progress','standard',$(sqlq "$1"),datetime('now','-2 hours'));"; }

col()   { db "SELECT COALESCE($2,'NULL') FROM tasks WHERE id=$1;"; }
sent()  { cut -f1 "$AGENT_SEND_LOG" | sort -u | tr '\n' ' '; }
msgto() { awk -F'\t' -v w="$1" '$1==w{print $2}' "$AGENT_SEND_LOG"; }

# ---------------------------------------------------------------------------
# 1. REASSIGN to a free agent, template creator preferred.
# ---------------------------------------------------------------------------
mk_fixture; busy dev
_hb_stall_sweep >/dev/null 2>&1
got_asg=$(col 1 assignee); got_esc=$(col 1 recurring_stall_escalated_at); got_st=$(col 1 status)
[[ "$got_asg" == "creative" ]] \
  && ok_t "reassigns the stalled instance to the TEMPLATE CREATOR when they are free" \
  || bad_t "reassigns the stalled instance to the TEMPLATE CREATOR when they are free" "assignee=[$got_asg] want creative (free agents: anton, creative, main)"
[[ "$got_st" == "todo" && "$got_esc" != "NULL" ]] \
  && ok_t "the row stays open and is stamped escalated (once-per-instance latch)" \
  || bad_t "the row stays open and is stamped escalated" "status=[$got_st] escalated_at=[$got_esc]"
case " $(sent) " in
  *" creative "*) ok_t "the NEW hands are told (they are the only party who can act)" ;;
  *)              bad_t "the NEW hands are told" "sends went to: [$(sent)]" ;;
esac
case " $(sent) " in
  *" dev "*) ok_t "the OLD assignee is told in the same breath (never a silent move)" ;;
  *)         bad_t "the OLD assignee is told in the same breath" "sends went to: [$(sent)]" ;;
esac
case " $(sent) " in
  *" main "*) ok_t "the coordinator is told" ;;
  *)          bad_t "the coordinator is told" "sends went to: [$(sent)]" ;;
esac
[[ -n "$(db "SELECT 1 FROM lifecycle_events WHERE kind='task.recurring_stall_escalated' AND ident='DIVE-2694' LIMIT 1;")" ]] \
  && ok_t "the escalation is on the append-only ledger, not only in a chat message" \
  || bad_t "the escalation is on the append-only ledger" "no task.recurring_stall_escalated row for DIVE-2694"

# Exclusions, asserted BY NAME so a future predicate that drops one arm reds the arm
# that owns it. Each of these rows differs from DIVE-2694 in exactly one column.
for spec in "2:never flagged by rung 1" \
            "3:flagged inside the escalation window" \
            "4:already started" \
            "5:parked with a wake date" \
            "6:blocked on an unanswered human gate" \
            "7:not materialized from a template"; do
  rid="${spec%%:*}"; why="${spec#*:}"
  a=$(col "$rid" assignee); s=$(col "$rid" status); e=$(col "$rid" recurring_stall_escalated_at)
  [[ "$a" == "dev" && "$s" == "todo" && "$e" == "NULL" ]] \
    && ok_t "leaves row $rid alone — $why" \
    || bad_t "leaves row $rid alone — $why" "assignee=[$a] status=[$s] escalated_at=[$e]"
done

# ---------------------------------------------------------------------------
# 2. ONCE PER INSTANCE. A second tick must not thrash the row onward.
# ---------------------------------------------------------------------------
: >"$AGENT_SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(col 1 assignee)" == "creative" && -z "$(sent | tr -d ' ')" ]] \
  && ok_t "a second tick neither re-sends nor moves the row again (escalated_at latch holds)" \
  || bad_t "a second tick neither re-sends nor moves the row again" "assignee=[$(col 1 assignee)] sends=[$(sent)]"

# ---------------------------------------------------------------------------
# 3. NO FREE AGENT -> cancel WITH a written reason, so the template re-fires.
#    'blocked' would not do: skip-if-open counts every non-closed instance, so a
#    park renames the outage instead of ending it.
# ---------------------------------------------------------------------------
mk_fixture
for a in dev creative anton main; do busy "$a"; done
_hb_stall_sweep >/dev/null 2>&1
st=$(col 1 status); res=$(col 1 result)
[[ "$st" == "cancelled" ]] \
  && ok_t "with no free agent, the instance is CANCELLED so the schedule can re-fire" \
  || bad_t "with no free agent, the instance is CANCELLED" "status=[$st] — a row left open keeps suppressing every later slot"
[[ "$res" != "NULL" && ${#res} -gt 40 && "$res" == *"template"* ]] \
  && ok_t "the cancel carries a written reason naming the template (never an empty result)" \
  || bad_t "the cancel carries a written reason naming the template" "result=[$res]"
# Asserted on the TEXT, not just the recipient: dev is also the recipient of the
# reassign message, so a recipient-only check would pass on the wrong branch.
case "$(msgto dev)" in
  *AUTO-CANCELLED*) ok_t "the assignee whose row was cancelled is told THAT it was cancelled" ;;
  *)                bad_t "the assignee whose row was cancelled is told THAT it was cancelled" "text to dev: [$(msgto dev)]" ;;
esac

# ---------------------------------------------------------------------------
# 4. FAIL-CLOSED ON AN UNREADABLE REGISTRY. This is the arm that matters most: an
#    unreadable fleet reads as "nobody is free", which is exactly the input that
#    reaches the cancel rung. A tick that cannot see the fleet must do NOTHING.
# ---------------------------------------------------------------------------
mk_fixture; busy dev
REGISTRY="$TMP/does-not-exist.json"
_hb_stall_sweep >/dev/null 2>&1
st=$(col 1 status); a=$(col 1 assignee); e=$(col 1 recurring_stall_escalated_at)
[[ "$st" == "todo" && "$a" == "dev" && "$e" == "NULL" ]] \
  && ok_t "an unreadable registry escalates NOTHING — no reassign, and above all no cancel" \
  || bad_t "an unreadable registry escalates NOTHING" "status=[$st] assignee=[$a] escalated_at=[$e] — a failed fleet read must never close a live row"
REGISTRY="$TMP/registry.json"

# ---------------------------------------------------------------------------
# 5. NON-VACUITY + MUTATION. Arms 1-4 all pass on a sweep whose (a3) block does
#    nothing at all except arm 1, so arm 1 IS the anchor — assert it moved the row
#    from its fixture value, then break the latch and prove the latch is what stops
#    the second tick, rather than something else silently doing so.
# ---------------------------------------------------------------------------
mk_fixture; busy dev
before=$(col 1 assignee)
_hb_stall_sweep >/dev/null 2>&1
after=$(col 1 assignee)
[[ "$before" == "dev" && "$after" != "dev" ]] \
  && ok_t "ANCHOR: the sweep demonstrably MUTATES the fixture (dev -> $after), so the exclusion arms are not vacuous" \
  || bad_t "ANCHOR: the sweep demonstrably mutates the fixture" "before=[$before] after=[$after] — every 'leaves row alone' arm above is passing for free"
db "UPDATE tasks SET recurring_stall_escalated_at=NULL, assignee='dev' WHERE id=1;"
: >"$AGENT_SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(col 1 assignee)" != "dev" ]] \
  && ok_t "MUTATION: clearing recurring_stall_escalated_at makes the row eligible again (the latch is load-bearing, not incidental)" \
  || bad_t "MUTATION: clearing recurring_stall_escalated_at makes the row eligible again" "assignee=[$(col 1 assignee)] — the second tick's no-op in arm 2 was NOT caused by the latch, so its cause is unknown"

# ---------------------------------------------------------------------------
# 6. A HAND REASSIGN RESTARTS THE LADDER, it does not hand the new owner a row the
#    machine yanks back on its first tick. The clock is time-since-FLAG, so without
#    this a row flagged two days ago is eligible the instant a person reassigns it —
#    the ladder would overrule a routing decision seconds after it was made, having
#    measured nothing about the new hands. Same hazard cmd_task_assign already
#    guards for the stale-reaper (started_at), one layer over. Live case: creative
#    hand-moved DIVE-2694 hours before this code would first run.
# ---------------------------------------------------------------------------
mk_fixture; busy dev
cmd_task_assign 1 anton >/dev/null 2>&1
[[ "$(col 1 recurring_stall_pinged_at)" == "NULL" && "$(col 1 recurring_stall_escalated_at)" == "NULL" ]] \
  && ok_t "an explicit reassign CLEARS both stall stamps (the ladder restarts at detection)" \
  || bad_t "an explicit reassign clears both stall stamps" "pinged=[$(col 1 recurring_stall_pinged_at)] escalated=[$(col 1 recurring_stall_escalated_at)]"
: >"$AGENT_SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(col 1 assignee)" == "anton" && "$(col 1 status)" == "todo" ]] \
  && ok_t "the very next tick does NOT move or cancel the freshly reassigned row" \
  || bad_t "the very next tick does NOT move or cancel the freshly reassigned row" "assignee=[$(col 1 assignee)] status=[$(col 1 status)] — the machine overruled a hand routing decision"
# ...and it is not immune forever: re-flag it, age the flag, and rung 2 applies again.
db "UPDATE tasks SET recurring_stall_pinged_at=datetime('now','-25 hours') WHERE id=1;"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(col 1 assignee)" != "anton" || "$(col 1 status)" == "cancelled" ]] \
  && ok_t "MUTATION: re-flagging the reassigned row makes rung 2 apply again (the reset delays, it does not exempt)" \
  || bad_t "MUTATION: re-flagging the reassigned row makes rung 2 apply again" "assignee=[$(col 1 assignee)] status=[$(col 1 status)] — the reset is a permanent exemption, which would hide the next stall"

# ---------------------------------------------------------------------------
# 7. SAME HANDS (DIVE-2878). The guard in cmd_task_assign has TWO branches, and
#    section 6 only ever exercises the taken one: it assigns row 1 (assignee dev)
#    to anton, so `assignee IS NOT <who>` is TRUE in every arm above and the ELSE
#    is dead code as far as this harness is concerned. Measured by olivia on
#    a0190a2: delete the condition, collapse both lines to an unconditional
#    `=NULL`, and the harness still reports 22/0. A surviving mutant is an
#    uncovered branch whatever the pass count says.
#
#    The ELSE branch is the ANTI-DEFER property: a no-op reassign to the agent who
#    already holds the row must NOT restart the ladder, or escalation is postponed
#    indefinitely by re-assigning a row to its current owner — a move that costs
#    nothing and looks like activity.
#
#    BOTH STAMPS ARE SET TO KNOWN NON-NULL VALUES FIRST, and that is load-bearing
#    rather than tidiness: mk_fixture leaves recurring_stall_escalated_at NULL, so
#    an arm that merely asserted "still NULL" would be satisfied by the very
#    unconditional-NULL mutant it exists to kill. Asserting the EXACT prior values
#    also catches a mutant that rewrites the stamps to now() instead of nulling
#    them, which "IS NOT NULL" would wave through.
# ---------------------------------------------------------------------------
mk_fixture; busy dev
db "UPDATE tasks SET recurring_stall_pinged_at='2026-01-01 00:00:00',
                     recurring_stall_escalated_at='2026-01-02 00:00:00' WHERE id=1;"
cmd_task_assign 1 dev >/dev/null 2>&1
[[ "$(col 1 recurring_stall_pinged_at)" == "2026-01-01 00:00:00" \
   && "$(col 1 recurring_stall_escalated_at)" == "2026-01-02 00:00:00" ]] \
  && ok_t "SAME HANDS: reassigning to the CURRENT assignee PRESERVES both stall stamps" \
  || bad_t "SAME HANDS: reassigning to the current assignee preserves both stall stamps" "pinged=[$(col 1 recurring_stall_pinged_at)] escalated=[$(col 1 recurring_stall_escalated_at)] — an in-place reassign restarts the ladder, so escalation can be deferred forever by re-assigning a row to whoever already holds it"

# The state assert above pins the columns; this one pins what they are FOR. Under
# the unconditional-NULL mutant the stamps are cleared here, the row reads as
# freshly routed, rung 2 declines to touch it, and the deferral is achieved — so
# this arm fails on the mutant for the reason the property exists, not just
# because a value changed.
db "UPDATE tasks SET recurring_stall_pinged_at=datetime('now','-25 hours'),
                     recurring_stall_escalated_at=NULL WHERE id=1;"
cmd_task_assign 1 dev >/dev/null 2>&1
: >"$AGENT_SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(col 1 assignee)" != "dev" || "$(col 1 status)" == "cancelled" ]] \
  && ok_t "SAME HANDS: a no-op reassign cannot DEFER rung 2 — the sweep still acts on the aged flag" \
  || bad_t "SAME HANDS: a no-op reassign cannot defer rung 2" "assignee=[$(col 1 assignee)] status=[$(col 1 status)] pinged=[$(col 1 recurring_stall_pinged_at)] — re-assigning a row to its current owner bought it another full window"

# ---------------------------------------------------------------------------
# 8. DIVE-3097: the ladder must not hand the assignee to the row's OWN VERIFIER.
#    This row is still todo/never-started (no maker_agent, no delivery) — exactly
#    the shape a raw reassignment can corrupt — so landing the verifier here as
#    the new assignee would manufacture the assignee==verifier, no-handoff-ever
#    shape DIVE-2899 named, except self-inflicted by the heartbeat rather than a
#    human flag combo. The template's creator (creative) is normally the
#    FIRST-preference free target (see arm 1); this row's verifier IS creative,
#    so the fixed ladder must skip it and fall to the next free agent instead.
# ---------------------------------------------------------------------------
mk_fixture
db "INSERT INTO tasks (id,ident,title,status,kind,assignee,verifier,created_by,created_at,from_template_id,recurring_stall_pinged_at)
    VALUES (8,'DIVE-2901','drip slot','todo','standard','dev','creative','task-engine',datetime('now','-3 days'),100,datetime('now','-25 hours'));"
busy dev
: >"$AGENT_SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
got_asg8=$(col 8 assignee); got_vf8=$(col 8 verifier)
[[ "$got_asg8" != "$got_vf8" ]] \
  && ok_t "never lands the assignee on the row's own verifier (self-grade guard)" \
  || bad_t "never lands the assignee on the row's own verifier" "assignee=[$got_asg8] verifier=[$got_vf8] — this is the exact DIVE-2899 shape, produced fresh"
[[ "$got_asg8" == "anton" ]] \
  && ok_t "skips the verifier (creative, the preferred template-creator target) and falls to the next free agent (anton)" \
  || bad_t "falls to the next free agent past the excluded verifier" "assignee=[$got_asg8] want anton (free agents were anton, creative, main; creative is this row's verifier)"

# ANCHOR / MUTATION: without a verifier on the row, the SAME fixture (same free
# agents, same template creator) picks creative — proving arm 8 above is the
# exclusion firing, not incidental candidate ordering that happened to avoid it.
mk_fixture
db "INSERT INTO tasks (id,ident,title,status,kind,assignee,created_by,created_at,from_template_id,recurring_stall_pinged_at)
    VALUES (9,'DIVE-2902','drip slot','todo','standard','dev','task-engine',datetime('now','-3 days'),100,datetime('now','-25 hours'));"
busy dev
_hb_stall_sweep >/dev/null 2>&1
[[ "$(col 9 assignee)" == "creative" ]] \
  && ok_t "ANCHOR: with no verifier on the row, the same fixture picks creative — arm 8's skip is the verifier exclusion, not luck" \
  || bad_t "ANCHOR: with no verifier the ladder still prefers the template creator" "assignee=[$(col 9 assignee)] want creative"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
