#!/usr/bin/env bash
# DIVE-3474 arm 2, SECOND acceptance clause: "Assert the gate is discoverable at
# the lead's next wake."
#
# Arm 2 removes the file-time `agent send`. That is only safe because two NEW
# escalation terms replace it, and quinn's iteration-3 reject found that NEITHER
# was graded anywhere in tests/ — both could be deleted silently:
#
#   1. the `_gq` queue-count block in `_hb_wake` (cmd_heartbeat.sh) — the natural
#      wake is where a queued gate is MET. Its own comment says "without this
#      line the change trades an interrupt for a lost decision", and that was
#      exactly the untested claim: deleting the whole nudge line left
#      gate_route_delivery_unit at 51/51.
#   2. `_HB_GATE_RENAG_GRACE_HOURS` + the routed/urgent/2h conjunct in
#      `_HB_GATE_RENAG_WHERE` — the grace that stops the interrupt simply moving
#      fifteen minutes downstream. It DELAYS a real escalation rung for every
#      routed non-urgent gate, so it is a safety-relevant behaviour change and it
#      had zero assertions.
#
# This harness pins both, at the seam each actually lives on: the nudge through a
# real `_hb_wake` call with the send line captured, the grace through a real
# `_hb_gate_renag_sweep`. The count is read through the REAL
# `_task_agent_gate_pred` (via the product code) rather than a re-typed WHERE
# clause, per the same rule the other queue observers were migrated under.
#
# Both are pinned with the DELETION MUTANT quinn asked for, not just a positive
# arm: a mutant section at the end re-runs each assertion against a copy of the
# helper with the line/conjunct removed, and FAILS if the assertion still passes.
# A vacuous arm is worse than no arm — it reads as coverage.
#
# TIER: core (the default, declared here only to say it was a decision). Measured
# 8.09s on this host — ~2x the corpus mean, because the mutant section re-runs the
# whole file twice. That is the cost and it is worth naming: `nightly` is exactly
# where this arm would be invisible again, and invisibility in the nightly tier is
# how iteration 3's four send-rail observers escaped core, changed-harnesses AND a
# selected re-grade all at once. 8s against the 300s core budget is 2.7%.
#
# Run: bash tests/heartbeat_queue_discovery_unit.sh   (no root, no network)
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
SRC=src

TMP="$(mktemp -d /tmp/hb-queue-discovery.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_agent.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; asserts below deliberately probe states

tasks_db_init; _tasks_db_migrate
db "INSERT INTO agents_org (name,reports_to,role) VALUES ('main',NULL,'coordinator'),('dev','main',NULL);"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- Stubs: keep _hb_wake hermetic (no systemd, no tmux, no live pane) --------
INJECTED="$TMP/injected"; : >"$INJECTED"
systemctl()        { return 0; }
sudo()             { return 0; }
sleep()            { :; }
_hb_send_line()    { printf '%s\n' "$2" >>"$INJECTED"; return 0; }
_hb_log()          { :; }
_hb_recall_cite()  { echo ""; }
_hb_is_knowledge_task() { return 1; }
audit_log()        { :; }

# --- Stubs for the re-nag sweep's two rails ----------------------------------
SEND_LOG="$TMP/sends"; : >"$SEND_LOG"
_task_agent_channel() { TASK_CH_TYPE=claude TASK_CH_TOKEN=x TASK_CH_ACCESS=/dev/null; return 0; }
_task_send_owner() {
  local ids="$3"
  printf '%s\n' "$ids" >>"$SEND_LOG"
  TASK_SEND_MESSAGE_IDS="901"; TASK_SEND_DELIVERED=1
  db "UPDATE tasks SET gate_pinged_at=datetime('now') WHERE id IN (${ids});"
}
AGENT_SEND_LOG="$TMP/agent_sends"; : >"$AGENT_SEND_LOG"
cmd_send() { printf '%s\n' "$1" >>"$AGENT_SEND_LOG"; return 0; }
_task_gate_delivery_log() { return 0; }

nsel() { # rows the re-nag WHERE actually selects, straight off the product string
  db "SELECT COUNT(*) FROM tasks WHERE ${_HB_GATE_RENAG_WHERE};"
}

mk_task() { # <title> -> row id   (the live todo the wake is FOR)
  db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, status)
      VALUES ($(sqlq "$1"), '', 'medium', 'main', 'main', 'standard', 'todo');
      SELECT last_insert_rowid();"
}

mk_gate() { # <ident> <routed_reviewer> <tier> <asked_modifier> <urgent> <answered:0|1>
  local routed="NULL"; [[ -n "$2" ]] && routed="$(sqlq "$2")"
  local answered="NULL"; [[ "${6:-0}" == "1" ]] && answered="datetime('now')"
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,
                         need_type,tier,ask,recommend,need_asked_at,gate_pinged_at,
                         need_answered_at,routed_reviewer,gate_urgent)
      VALUES ($(sqlq "$1"),'gate','high','dev','dev','standard','blocked',
              'decision',$3,'choose now','A',datetime('now','$4'),NULL,
              ${answered},${routed},${5:-0});
      SELECT last_insert_rowid();"
}

# DIVE-3674 helpers. The grace now reads the REVIEWER's own queue, so "what work
# does main have" stopped being scenery and became an input: every arm below that
# asserts the grace HOLDS has to stand up a wake for it to defer to, or it is
# asserting the new conjunct instead of the old one.
mk_task_for() { # <agent> <status> -> row id
  db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, status)
      VALUES ('reviewer work', '', 'medium', $(sqlq "$1"), 'main', 'standard', $(sqlq "$2"));
      SELECT last_insert_rowid();"
}
# A todo behind an OPEN blocker. `_hb_pick_tasks` skips it, so the seat is never
# woken against it — it looks like work on the board and is not a wake.
mk_blocked_task_for() { # <agent> -> row id
  local t b
  t=$(mk_task_for "$1" todo)
  # The blocker is assigned to a DIFFERENT seat on purpose: parked on the
  # reviewer it would itself be a runnable todo, and the arm would then be
  # measuring that row instead of the blocked one.
  b=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, status)
          VALUES ('blocker', '', 'medium', 'dev', 'main', 'standard', 'todo');
          SELECT last_insert_rowid();")
  db "INSERT INTO task_deps (task_id, blocked_by) VALUES (${t}, ${b});"
  printf '%s' "$t"
}

reset_db() { db "DELETE FROM task_deps; DELETE FROM tasks;"; : >"$INJECTED"; : >"$SEND_LOG"; : >"$AGENT_SEND_LOG"; }

# Last line of injected wake text; the nudge is a single line by construction.
last_nudge() { tail -1 "$INJECTED" 2>/dev/null; }

# =============================================================================
# PART 1 — the wake NUDGE carries the queue count and names the verb
# =============================================================================

# 1a. A routed, unanswered gate makes the wake nudge carry the count AND name
#     `task queue`. This is the whole discovery mechanism: if the count is not
#     on the wake, nothing tells the lead the gate exists.
reset_db
T=$(mk_task "live todo for main")
mk_gate DIVE-Q1 main 1 '-5 minutes' 0 0 >/dev/null
_hb_wake main false "$T" "DIVE-$T" >/dev/null 2>&1
n="$(last_nudge)"
if [[ "$n" == *"1 gate(s) are ROUTED TO YOU"* && "$n" == *"task queue"* ]]; then
  ok_t "nudge: one routed gate puts the count on main's wake and names 'task queue'"
else
  bad_t "nudge: routed gate absent from the wake" "got: [${n:0:200}]"
fi

# 1b. The count is a COUNT, not a boolean — two gates say two. A mechanism that
#     said "you have gates" would hide the size of the queue from the seat that
#     has to drain it before finishing the turn.
reset_db
T=$(mk_task "live todo for main")
mk_gate DIVE-Q2 main 1 '-5 minutes' 0 0 >/dev/null
mk_gate DIVE-Q3 main 1 '-5 minutes' 0 0 >/dev/null
_hb_wake main false "$T" "DIVE-$T" >/dev/null 2>&1
[[ "$(last_nudge)" == *"2 gate(s) are ROUTED TO YOU"* ]] \
  && ok_t "nudge: the count is a count — two routed gates report 2" \
  || bad_t "nudge: two routed gates did not report 2" "got: [$(last_nudge)]"

# 1c. Zero gates adds NOTHING. The nudge is injected into an unrelated goal on
#     every wake, so a block that fires empty is a per-wake tax on every seat.
reset_db
T=$(mk_task "live todo for main")
_hb_wake main false "$T" "DIVE-$T" >/dev/null 2>&1
[[ "$(last_nudge)" != *"ROUTED TO YOU"* ]] \
  && ok_t "nudge: zero routed gates adds nothing to the wake" \
  || bad_t "nudge: empty queue still appended a gate block" "got: [$(last_nudge)]"

# 1d. An ANSWERED gate drops out of the count. Without this the queue never
#     empties and the nudge becomes noise the seat learns to skip — which is the
#     same lost decision by a slower route.
reset_db
T=$(mk_task "live todo for main")
mk_gate DIVE-Q4 main 1 '-5 minutes' 0 1 >/dev/null
_hb_wake main false "$T" "DIVE-$T" >/dev/null 2>&1
[[ "$(last_nudge)" != *"ROUTED TO YOU"* ]] \
  && ok_t "nudge: an answered routed gate drops out of the count" \
  || bad_t "nudge: answered gate still counted" "got: [$(last_nudge)]"

# 1e. SCOPING, the negative the count needs: a gate routed to a PEER is not on
#     main's wake. A count that ignored routed_reviewer would pull every seat's
#     queue into every seat's nudge.
reset_db
T=$(mk_task "live todo for main")
mk_gate DIVE-Q5 dev 1 '-5 minutes' 0 0 >/dev/null
_hb_wake main false "$T" "DIVE-$T" >/dev/null 2>&1
[[ "$(last_nudge)" != *"ROUTED TO YOU"* ]] \
  && ok_t "nudge: a gate routed to a peer is not counted on main's wake" \
  || bad_t "nudge: peer-routed gate leaked into main's count" "got: [$(last_nudge)]"

# 1f. A T2 gate is the HUMAN's and is not in an agent queue. Pinned here because
#     the count is what would make an agent believe it may answer one.
reset_db
T=$(mk_task "live todo for main")
mk_gate DIVE-Q6 main 2 '-5 minutes' 0 0 >/dev/null
_hb_wake main false "$T" "DIVE-$T" >/dev/null 2>&1
[[ "$(last_nudge)" != *"ROUTED TO YOU"* ]] \
  && ok_t "nudge: a tier-2 gate is not in an agent's queue count" \
  || bad_t "nudge: T2 gate leaked into the agent queue count" "got: [$(last_nudge)]"

# 1g. The nudge must not SWALLOW the goal it was appended to. The block is a
#     suffix on an existing line, so a mistake here loses the wake itself.
reset_db
T=$(mk_task "live todo for main")
mk_gate DIVE-Q7 main 1 '-5 minutes' 0 0 >/dev/null
_hb_wake main false "$T" "DIVE-$T" >/dev/null 2>&1
n="$(last_nudge)"
[[ "$n" == *"/goal Task DIVE-$T"* && "$n" == *"ROUTED TO YOU"* ]] \
  && ok_t "nudge: the queue block is appended to the goal, not substituted for it" \
  || bad_t "nudge: goal text lost when the queue block fired" "got: [${n:0:200}]"

# =============================================================================
# PART 2 — the re-nag GRACE for routed, non-urgent gates
# =============================================================================
# Read directly off `_HB_GATE_RENAG_WHERE` (the product string, interpolated not
# re-typed) so a change to the conjunct moves these arms.

# 2a. A routed non-urgent gate YOUNGER than the grace is NOT selected. This is
#     the whole point: the natural wake gets first refusal.
#     DIVE-3674: the todo is REQUIRED, not decoration. The grace is granted
#     because main has a runnable row and will therefore be woken; without it
#     there is no wake for the sweep to defer to and 2g is the arm that applies.
reset_db
mk_task_for main todo >/dev/null
mk_gate DIVE-G1 main 1 '-30 minutes' 0 0 >/dev/null
[[ "$(nsel)" == "0" ]] \
  && ok_t "grace: routed non-urgent gate at 30m is NOT re-nagged (< 2h grace)" \
  || bad_t "grace: young routed gate was re-nagged anyway" "selected=$(nsel)"

# 2b. The SAME row past the grace IS selected. The grace delays; it must not
#     cancel — a queued gate that is never escalated is the lost decision.
reset_db
mk_gate DIVE-G2 main 1 '-3 hours' 0 0 >/dev/null
[[ "$(nsel)" == "1" ]] \
  && ok_t "grace: the same routed gate at 3h IS re-nagged (grace delays, never cancels)" \
  || bad_t "grace: routed gate past the grace was never escalated" "selected=$(nsel)"

# 2c. `--urgent` skips the grace and re-nags on the old 15-minute clock. This is
#     the escape hatch the ticket requires be a SEPARATE field from recommend —
#     every row here carries recommend='A', so if urgency were reading the
#     recommendation, 2a would already have been selected.
reset_db
mk_gate DIVE-G3 main 1 '-30 minutes' 1 0 >/dev/null
[[ "$(nsel)" == "1" ]] \
  && ok_t "grace: an --urgent routed gate skips the grace (old 15-minute clock)" \
  || bad_t "grace: --urgent did not bypass the grace" "selected=$(nsel)"

# 2d. An UNROUTED gate is unaffected. It belongs to the human, who has no wake
#     this queue is visible at, so nothing in arm 2 may quiet it.
reset_db
mk_gate DIVE-G4 '' 1 '-30 minutes' 0 0 >/dev/null
[[ "$(nsel)" == "1" ]] \
  && ok_t "grace: an UNROUTED gate is untouched by the grace (human has no queue)" \
  || bad_t "grace: the grace quieted a human-owned gate" "selected=$(nsel)"

# 2e. The grace window is CONFIGURABLE and the env var is the knob named in the
#     source. Pinned so the 2h default cannot be silently hard-coded.
reset_db
mk_task_for main todo >/dev/null   # DIVE-3674: keep the 2h grace the only thing under test here
mk_gate DIVE-G5 main 1 '-30 minutes' 0 0 >/dev/null
sel_override=$(
  FIVEDIVE_GATE_RENAG_ROUTED_GRACE_HOURS=0 bash -c '
    cd "$1"; set +e
    for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
             lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
             lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
             cmd_agent.sh cmd_heartbeat.sh; do source "src/$f"; done
    STATE_DIR="$2"; TASKS_DIR="$2/tasks"; TASKS_DB="$2/tasks/tasks.db"
    db "SELECT COUNT(*) FROM tasks WHERE ${_HB_GATE_RENAG_WHERE};"
  ' _ "$PWD" "$TMP" 2>/dev/null
)
[[ "$sel_override" == "1" ]] \
  && ok_t "grace: FIVEDIVE_GATE_RENAG_ROUTED_GRACE_HOURS=0 restores the pre-3474 clock" \
  || bad_t "grace: the grace window is not driven by its env knob" "selected=[$sel_override]"

# 2f. END-TO-END through the real sweep, not just the WHERE string: a young
#     routed gate produces no ping on EITHER rail, and the same row past the
#     grace does. The WHERE arms above could both be true while the sweep still
#     pinged through some other path.
reset_db
mk_task_for main todo >/dev/null   # DIVE-3674: the wake the grace defers to
mk_gate DIVE-G6 main 1 '-30 minutes' 0 0 >/dev/null
_hb_gate_renag_sweep >/dev/null 2>&1
young_sends=$(( $(grep -c . "$SEND_LOG") + $(grep -c . "$AGENT_SEND_LOG") ))
reset_db
mk_gate DIVE-G7 main 1 '-3 hours' 0 0 >/dev/null
_hb_gate_renag_sweep >/dev/null 2>&1
old_sends=$(( $(grep -c . "$SEND_LOG") + $(grep -c . "$AGENT_SEND_LOG") ))
[[ "$young_sends" == "0" && "$old_sends" -ge 1 ]] \
  && ok_t "grace: real sweep sends nothing inside the grace and does send past it" \
  || bad_t "grace: real sweep behaviour does not match the WHERE" \
           "young=$young_sends old=$old_sends"

# =============================================================================
# PART 2b — DIVE-3674: the grace is CONDITIONED on the wake it defers to
# =============================================================================
# The defect these arms pin is not a broken signal. Every liveness reading on the
# stranded seat was CORRECT — it really had no work, it really was idle, the sweep
# really was silent by design. So an arm shaped "assert the seat is healthy"
# proves nothing here; what has to be asserted is that a seat with 0 runnable
# rows and a routed gate is NOT granted a grace whose whole premise is a wake it
# will not get.

# 2g. THE DEFECT. Same row as 2a, same age, same tier, same urgency — the ONLY
#     difference is that the reviewer's queue is empty, so `_hb_wake` is never
#     reached for it and the natural wake never comes. It must be selected.
reset_db
mk_gate DIVE-G8 main 1 '-30 minutes' 0 0 >/dev/null
[[ "$(nsel)" == "1" ]] \
  && ok_t "no-wake: a routed gate on a 0-todo reviewer is NOT granted the grace" \
  || bad_t "no-wake: 0-todo reviewer still got the 2h grace — the strand is unfixed" "selected=$(nsel)"

# 2h. A reviewer that is MID-TURN has a wake. `in_progress` is the busy-guard's
#     own condition, and typing at that seat is the clobber the no-clobber guard
#     exists to prevent — so the grace must still hold.
reset_db
mk_task_for main in_progress >/dev/null
mk_gate DIVE-G9 main 1 '-30 minutes' 0 0 >/dev/null
[[ "$(nsel)" == "0" ]] \
  && ok_t "no-wake: an in_progress reviewer keeps the grace (mid-turn, do not clobber)" \
  || bad_t "no-wake: the sweep un-quieted a reviewer that is mid-turn" "selected=$(nsel)"

# 2i. A todo behind an OPEN blocker is NOT a wake — `_hb_pick_tasks` skips it and
#     the seat logs `no todo — stay idle` all the same. Counting rows instead of
#     RUNNABLE rows would read this seat as busy and re-strand the gate, which is
#     the same proxy-for-the-artifact mistake in a new place.
reset_db
mk_blocked_task_for main >/dev/null
mk_gate DIVE-G10 main 1 '-30 minutes' 0 0 >/dev/null
[[ "$(nsel)" == "1" ]] \
  && ok_t "no-wake: a todo held behind an OPEN blocker does not count as a wake" \
  || bad_t "no-wake: a blocked todo was read as a natural wake" "selected=$(nsel)"

# 2j. Same row once the blocker CLOSES: the todo becomes runnable, the wake is
#     real again, the grace returns. The negative control for 2i — without it,
#     2i would also pass if the conjunct ignored task_deps entirely and simply
#     never granted the grace.
reset_db
bt=$(mk_blocked_task_for main)
db "UPDATE tasks SET status='done' WHERE id IN (SELECT blocked_by FROM task_deps WHERE task_id=${bt});"
mk_gate DIVE-G11 main 1 '-30 minutes' 0 0 >/dev/null
[[ "$(nsel)" == "0" ]] \
  && ok_t "no-wake: the grace RETURNS once the blocker closes (control for 2i)" \
  || bad_t "no-wake: a runnable todo was still read as no wake" "selected=$(nsel)"

# 2k. TIER 2 IS OUT OF SCOPE and that is deliberate. A tier-2 re-nag reaches a
#     paired HUMAN, whose attention was never a function of the seat's queue, so
#     the premise this conjunct repairs was never load-bearing there. Un-quieting
#     the human lane would be a widening nobody asked for.
reset_db
mk_gate DIVE-G12 main 2 '-30 minutes' 0 0 >/dev/null
[[ "$(nsel)" == "0" ]] \
  && ok_t "no-wake: a TIER-2 routed gate keeps the grace (human lane untouched)" \
  || bad_t "no-wake: the conjunct widened the human re-nag lane" "selected=$(nsel)"

# 2l. An UNKNOWN reviewer is not PROVABLY wakeless — it is unmeasured. A name
#     absent from `agents_org` has no queue we can read, and asserting "no wake"
#     from a failed lookup is the could-not-measure-reads-as-measured shape.
#     Keep the grace; the 2h rung still fires.
reset_db
mk_gate DIVE-G13 ghost 1 '-30 minutes' 0 0 >/dev/null
[[ "$(nsel)" == "0" ]] \
  && ok_t "no-wake: an unknown reviewer keeps the grace (unmeasured is not proven-idle)" \
  || bad_t "no-wake: an unreadable queue was read as an empty one" "selected=$(nsel)"

# 2m. END-TO-END through the real sweep. The WHERE arms could all be right while
#     the sweep still delivered nowhere: what makes this a fix rather than a
#     re-labelling is that the row leaves on the AGENT rail (`cmd_send` into the
#     reviewer's pane), which is the wake the seat was missing — not a human push.
reset_db
mk_gate DIVE-G14 main 1 '-30 minutes' 0 0 >/dev/null
_hb_gate_renag_sweep >/dev/null 2>&1
[[ "$(grep -c . "$AGENT_SEND_LOG")" -ge 1 && "$(grep -c . "$SEND_LOG")" == "0" ]] \
  && ok_t "no-wake: the real sweep wakes the idle reviewer over the AGENT rail, no human push" \
  || bad_t "no-wake: real sweep did not deliver on the agent rail" \
           "agent=$(grep -c . "$AGENT_SEND_LOG") human=$(grep -c . "$SEND_LOG")"

# =============================================================================
# PART 3 — DELETION MUTANTS. quinn's iteration-3 reject was precisely that both
# mechanisms could be deleted with every harness still green. So each assertion
# above is re-run against a tree with the line/conjunct REMOVED, and this section
# fails if the assertion survives the deletion — i.e. if the arm is vacuous.
# =============================================================================
MUT="$TMP/mut"; mkdir -p "$MUT"
cp -r src "$MUT/src"; cp -r tests "$MUT/tests"

# <arm-substring> is the arm's FAILURE label (the bad_t text), not its ok text —
# a red arm only ever prints the former, and grepping the ok text is how this
# whole section silently reported "vacuous" while the mutants were biting fine.
run_mutant() { # <label> <sed-program-on-src/cmd_heartbeat.sh> <arm-failure-label>
  local label="$1" prog="$2" arm="$3"
  cp src/cmd_heartbeat.sh "$MUT/src/cmd_heartbeat.sh"
  sed -i "$prog" "$MUT/src/cmd_heartbeat.sh" || { bad_t "mutant: $label" "sed failed"; return; }
  if cmp -s src/cmd_heartbeat.sh "$MUT/src/cmd_heartbeat.sh"; then
    bad_t "mutant: $label" "the mutation changed nothing — the line it targets has moved or been renamed"
    return
  fi
  local out; out=$(cd "$MUT" && bash tests/heartbeat_queue_discovery_unit.sh 2>&1)
  if printf '%s' "$out" | grep -q "^FAIL - .*${arm}"; then
    ok_t "mutant: $label reds the arm that pins it"
  else
    bad_t "mutant: $label left every arm GREEN — that arm is vacuous" \
          "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi
}

# Guard against infinite recursion: the mutant copy runs this same file, so it
# must not itself spawn mutants. The parent sets the flag; the child sees it.
if [[ -z "${_HB_QD_MUTANT:-}" ]]; then
  export _HB_QD_MUTANT=1

  # Mutant 1 — remove the append inside the _gq block. This is the exact deletion
  # quinn performed that left gate_route_delivery_unit at 51/51. Replaced with a
  # no-op rather than `d`: deleting the only line of an `if` body is a bash SYNTAX
  # error, and a mutant that dies at parse time reds every arm indiscriminately,
  # which proves nothing about the arm under test.
  run_mutant "wake nudge line deleted" \
    's|^\(  *\)nudge="${nudge} Separately: .*$|\1:|' \
    "nudge: routed gate absent from the wake"

  # Mutant 2 — drop the grace conjunct from _HB_GATE_RENAG_WHERE by neutering
  # the routed/urgent/age OR-group to a tautology, i.e. the pre-3474 behaviour.
  run_mutant "renag grace conjunct neutered" \
    "s|AND ( COALESCE(routed_reviewer,'') = ''|AND ( 1=1 OR COALESCE(routed_reviewer,'') = ''|" \
    "grace: young routed gate was re-nagged anyway"

  # Mutant 3 — DIVE-3674. Neuter the no-natural-wake conjunct back to the
  # pre-3674 behaviour (grace granted unconditionally). Targets the OR-arm rather
  # than the helper string so a mutant that merely renames the variable does not
  # read as a kill.
  run_mutant "renag no-natural-wake conjunct neutered" \
    "s|        OR ( \${_HB_GATE_RENAG_NO_NATURAL_WAKE} ) )|        OR ( 1=0 ) )|" \
    "no-wake: 0-todo reviewer still got the 2h grace"

  # Mutant 4 — count ROWS instead of RUNNABLE rows: drop the open-blocker test.
  # This is the plausible-looking simplification, and 2i is the only arm that
  # separates it from the real thing.
  run_mutant "no-natural-wake ignores open blockers" \
    "s|AND b.status NOT IN ('done','cancelled')|AND 1=0|" \
    "no-wake: a blocked todo was read as a natural wake"

  unset _HB_QD_MUTANT
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
