#!/usr/bin/env bash
# DIVE-4724 — a claim that outlived its verdict, and the /clear that produced it.
#
# THE MEASUREMENT (quinn, 2026-09-20, /var/log/5dive-heartbeat.log + the store):
#   17:23:53Z  DIVE-4664 graded pass by quinn
#   17:25:49Z  "due + todo DIVE-4708 — waking (fresh=true)"  <- /clear, hand-back never run
#   17:31:46Z  DIVE-4708 graded pass by quinn
#   17:33:56Z  "idle with 1 background shell(s) -- the turn is over, dispatching"
#   17:34:05Z  "nudged (/goal DIVE-4667, fresh=true)"        <- /clear, same shape
#   17:34Z -> 00:23Z  every tick: "busy — 2 in_progress, skip"; the 45m reaper never fired.
#
# TWO DOORS, ONE CLAIM. The busy-guard counts the row (once the merge lands
# `_TASKS_TFV_SQL` subtracts it, so DIVE-4261's graded-merge discount stops
# applying), and DIVE-2560's verifier-latency skip is why the reaper never
# reaches it. Neither can end the state, so nothing does.
#
# WHAT THIS PROVES, arm by arm:
#   A1  `_hb_fresh_downgrade_reason` names live background shells;
#   A2  ... and a VERDICT this seat recorded and has not handed back (DIVE-4814:
#       the signal is the stranded hand-back, not the grading queue);
#   A2c CONTROL (DIVE-4814) — a delivery merely SITTING unacked in this seat's
#       queue, with no verdict on it, is NOT a reason: nothing about it lives in
#       the session, and treating it as one is what stopped quinn ever being
#       /clear'ed (60 downgrades, 907M quota tokens on 09-21);
#   A3  CONTROL — a seat with neither signal gets NO reason (it still /clears);
#   A4  CONTROL — an ACKed handoff with no verdict is not a reason either;
#   A4b (DIVE-4814) — but an ACKed row DOES downgrade once its verdict is
#       stamped: the predicate keys on the verdict, not on handoff_ack_at, so a
#       verifier who ran `task start` before grading is still protected;
#   A5  CONTROL — a row bounced back to the MAKER (assignee != verifier) is not
#       an open handoff here either;
#   A6  STRUCTURAL — the dispatch path consults the helper and downgrades
#       `eff_fresh`, rather than skipping the tick: a downgrade is strictly
#       weaker than a defer and must stay that way;
#   D1-D4 (DIVE-4814) — the guard may not hold one seat warm twice running:
#       D1  the first fresh wake with a live reason is downgraded;
#       D2  the SECOND consecutive one is not — it reports the reason as
#           SUPPRESSED and the seat gets its /clear;
#       D3  a wake with no reason releases the latch, so protection returns;
#       D4  STRUCTURAL+BEHAVIOURAL — the decision is read from the caller's own
#           shell. A `$(…)` call site puts the assignment in a subshell, the
#           suppression branch becomes unreachable, and nothing else in this
#           file would notice (the latch is a file and keeps working);
#   B1  a verifier-held, unacked row that ALREADY CARRIES A VERDICT and is past
#       the budget is reclaimed to `todo` — and stays on the same seat, which
#       is the seat that owes the hand-back;
#   B2  the same row INSIDE the budget is NOT reclaimed — the verifier gets its
#       ordinary window to run the hand-back itself;
#   B3  CONTROL — no verdict, past the budget: DIVE-2560's skip still holds
#       (this is the arm the fix must not widen);
#   B5  past the idle-stall grace but INSIDE the budget: neither arm takes the
#       row — the fall-through is bounded by the same budget as everything else;
#   B4  CONTROL — a verdict OLDER than the delivery in front of it graded a
#       different iteration and confers nothing;
#   C1  `task doctor` NAMES the class (the repair is the heartbeat's; a store
#       whose heartbeat is not running still has to be able to see it);
#   C2  CONTROL — an ungraded delivery in the verifier's queue is not that class.
#
# Same isolation contract as tests/heartbeat_reclaim_verifier_handoff_unit.sh:
# source src/ directly, throwaway tasks.db, no tmux/network/root.
# Run: bash tests/heartbeat_claim_outlives_verdict_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-claim-outlives-verdict.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/runs.sh cmd_task.sh task/doctor.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
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

addt() { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
rowa() { db "SELECT status||'|'||COALESCE(assignee,'NULL')||'|'||COALESCE(started_at,'NULL') FROM tasks WHERE id=$1;"; }
reset_all() { db "DELETE FROM tasks;"; }

REGISTRY="$TMP/registry.json"; printf '{"agents":{}}' >"$REGISTRY"
registry_read()       { cat "$REGISTRY"; }
registry_write()      { cat > "$REGISTRY"; }
_hb_send_line()       { return 0; }
_hb_pane_fingerprint() { echo "fp"; }
cmd_send()            { :; }
cmd_task_escalate()   { :; }
with_registry_lock()  { local fn="$1"; shift; "$fn" "$@"; }
_hb_claude_started()  { echo ""; }   # no proc time -> rule (a) never fires
_hb_agent_idle()      { return 0; }  # confident idle

# A delivery routed through the real verb, then claimed the way a tick claims it.
mk_delivered_unacked() {
  local id
  id=$(addt --assignee=dev --verifier=olivia --verify -- "ship the widget")
  ( cmd_task_done "$id" --result="closed in fixture setup (DIVE-2773: a first close must carry a reason)" ) >/dev/null 2>&1
  _hb_claim_task olivia "$id" >/dev/null 2>&1
  printf '%s' "$id"
}
# The columns `task verify` stamps on a PASS (DIVE-3430: graded_verdict_at is a
# bare SET on every grade, so it is the CURRENT verdict's own clock).
stamp_verdict() { db "UPDATE tasks SET graded_at=datetime('now'), graded_verdict='pass',
                        graded_verdict_at=datetime('now'), graded_by='olivia' WHERE id=$1;"; }

# =============================================================================
# A) the /clear that destroyed the hand-back
# =============================================================================
reset_all
_HB_IDLE_BG_SHELLS="2"
R=$(_hb_fresh_downgrade_reason olivia)
[[ "$R" == *"background shell"* ]] \
  && ok_t "A1 live background shells are a reason to keep the context warm" \
  || bad_t "A1 background shells produced no reason" "got '${R}'"

reset_all
_HB_IDLE_BG_SHELLS=""
TA2=$(mk_delivered_unacked)
stamp_verdict "$TA2"
R=$(_hb_fresh_downgrade_reason olivia)
[[ "$R" == *"recorded a verdict"* ]] \
  && ok_t "A2 a verdict recorded and not handed back is a reason to keep the context warm" \
  || bad_t "A2 a stranded hand-back produced no reason" "got '${R}' row=$(rowa "$TA2")"
# ... and the line NAMES the row it is protecting, so a run of downgrades can be
# audited row by row against the store instead of reading "3 delivered row(s)".
IDA2=$(db "SELECT ident FROM tasks WHERE id=${TA2};")
[[ -n "$IDA2" && "$R" == *"$IDA2"* ]] \
  && ok_t "A2b the reason names the row whose hand-back it is protecting" \
  || bad_t "A2b the reason does not name the row" "ident='${IDA2}' got '${R}'"

# A2c THE DIVE-4814 CONTROL, and the one arm that fails on the pre-fix tree: an
# ordinary delivery waiting in the grading queue, ungraded. Iteration 1 counted
# exactly this and downgraded on it.
reset_all
TA2C=$(mk_delivered_unacked)
R=$(_hb_fresh_downgrade_reason olivia)
[[ -z "$R" ]] \
  && ok_t "A2c [control] an ungraded delivery sitting in the queue is NOT a reason (DIVE-4814)" \
  || bad_t "A2c the queue itself still downgrades the wake" "got '${R}' row=$(rowa "$TA2C")"

# ... and it is still not a reason when there are several of them, which is the
# state a grading seat is in all day.
reset_all
mk_delivered_unacked >/dev/null; mk_delivered_unacked >/dev/null; mk_delivered_unacked >/dev/null
R=$(_hb_fresh_downgrade_reason olivia)
[[ -z "$R" ]] \
  && ok_t "A2d [control] three ungraded deliveries in the queue are still not a reason" \
  || bad_t "A2d a queue of deliveries downgraded the wake" "got '${R}'"

reset_all
R=$(_hb_fresh_downgrade_reason olivia)
[[ -z "$R" ]] \
  && ok_t "A3 [control] a seat with neither signal is not downgraded" \
  || bad_t "A3 a clean seat was given a reason" "got '${R}'"

reset_all
TA4=$(mk_delivered_unacked)
db "UPDATE tasks SET handoff_ack_at=datetime('now') WHERE id=${TA4};"
R=$(_hb_fresh_downgrade_reason olivia)
[[ -z "$R" ]] \
  && ok_t "A4 [control] an ACKed handoff with no verdict is not a reason — no downgrade" \
  || bad_t "A4 an ACKed handoff still downgraded" "got '${R}'"

# A4b the other half of that, and the reason handoff_ack_at is NOT in the
# predicate: `task start` acks, so a verifier who starts the row before grading
# it would drop out of an ack-keyed guard exactly when it is owed most.
reset_all
TA4B=$(mk_delivered_unacked)
db "UPDATE tasks SET handoff_ack_at=datetime('now') WHERE id=${TA4B};"
stamp_verdict "$TA4B"
R=$(_hb_fresh_downgrade_reason olivia)
[[ "$R" == *"recorded a verdict"* ]] \
  && ok_t "A4b an ACKed row whose verdict is stamped but unhanded still downgrades (DIVE-4814)" \
  || bad_t "A4b the predicate still keys on the ack" "got '${R}'"

reset_all
TA5=$(mk_delivered_unacked)
db "UPDATE tasks SET assignee='dev', handoff_rejected_at=datetime('now') WHERE id=${TA5};"
R=$(_hb_fresh_downgrade_reason olivia)
[[ -z "$R" ]] \
  && ok_t "A5 [control] rework bounced back to the maker is not this seat's open handoff" \
  || bad_t "A5 a bounced row downgraded the verifier's wake" "got '${R}'"

# A6 STRUCTURAL: the dispatch path downgrades, it does not defer. Read the source
# rather than the pane — the surrounding function is the whole tick loop and has
# no seam a unit harness can drive.
A6=$(awk '/_hb_fresh_downgrade_decide "\$name"/{f=1} f&&/eff_fresh="false"/{print "hit"; exit}' "$SRC/cmd_heartbeat.sh")
A6C=$(awk '/_hb_fresh_downgrade_decide "\$name"/{f=1} f&&n++<12&&/continue/{print "defer"; exit}' "$SRC/cmd_heartbeat.sh")
[[ "$A6" == "hit" && -z "$A6C" ]] \
  && ok_t "A6 the dispatch path downgrades eff_fresh and never defers the tick on this signal" \
  || bad_t "A6 dispatch wiring is wrong" "downgrade='${A6}' defer='${A6C}'"

# =============================================================================
# D) DIVE-4814 — the guard may not hold one seat warm twice running
# =============================================================================
# THE BOUND IS COUNTED IN WAKES, NOT MINUTES. Both signals are read from state
# that outlives a turn (a poll shell, a PASS parked on a human's merge), so
# "the reason still holds" is not evidence the SESSION still holds anything.
latch_p() { printf '%s/fresh-downgrade.%s.held' "$STATE_DIR" "$1"; }

reset_all
rm -f "$(latch_p olivia)"
_HB_IDLE_BG_SHELLS=""
TD=$(mk_delivered_unacked)
stamp_verdict "$TD"
_hb_fresh_downgrade_decide olivia 2>/dev/null || true
[[ -n "${_HB_FRESH_DOWNGRADE_WHY:-}" && -z "${_HB_FRESH_DOWNGRADE_SUPPRESSED:-}" && -f "$(latch_p olivia)" ]] \
  && ok_t "D1 the first fresh wake with a live reason is downgraded and latches" \
  || bad_t "D1 first wake did not downgrade/latch" "why='${_HB_FRESH_DOWNGRADE_WHY:-}' supp='${_HB_FRESH_DOWNGRADE_SUPPRESSED:-}' latch=$([[ -f "$(latch_p olivia)" ]] && echo yes || echo no)"

# The store has not changed — same row, same stranded verdict. The SEAT has: it
# already had one warm turn with it in front of it.
_hb_fresh_downgrade_decide olivia 2>/dev/null || true
[[ -z "${_HB_FRESH_DOWNGRADE_WHY:-}" && -n "${_HB_FRESH_DOWNGRADE_SUPPRESSED:-}" && ! -f "$(latch_p olivia)" ]] \
  && ok_t "D2 the second consecutive fresh wake is NOT downgraded — reported suppressed, latch released" \
  || bad_t "D2 the guard fired twice running" "why='${_HB_FRESH_DOWNGRADE_WHY:-}' supp='${_HB_FRESH_DOWNGRADE_SUPPRESSED:-}' latch=$([[ -f "$(latch_p olivia)" ]] && echo yes || echo no)"

# ... and it is a ceiling, not an off switch: the third wake protects again,
# because the state that survived the /clear is a NEW claim on the session.
_hb_fresh_downgrade_decide olivia 2>/dev/null || true
[[ -n "${_HB_FRESH_DOWNGRADE_WHY:-}" ]] \
  && ok_t "D2b the ceiling is every-other-wake, not a permanent disarm" \
  || bad_t "D2b the guard stopped firing altogether" "why='${_HB_FRESH_DOWNGRADE_WHY:-}' supp='${_HB_FRESH_DOWNGRADE_SUPPRESSED:-}'"

# D3 a wake with NOTHING to protect releases the latch, so the next real reason
# is honoured rather than eaten by a stale flag.
reset_all
_hb_fresh_downgrade_decide olivia 2>/dev/null || true
[[ -z "${_HB_FRESH_DOWNGRADE_WHY:-}" && -z "${_HB_FRESH_DOWNGRADE_SUPPRESSED:-}" && ! -f "$(latch_p olivia)" ]] \
  && ok_t "D3 a clean wake releases the latch (no reason, no suppression)" \
  || bad_t "D3 the latch survived a clean wake" "why='${_HB_FRESH_DOWNGRADE_WHY:-}' supp='${_HB_FRESH_DOWNGRADE_SUPPRESSED:-}' latch=$([[ -f "$(latch_p olivia)" ]] && echo yes || echo no)"
TD3=$(mk_delivered_unacked); stamp_verdict "$TD3"
_hb_fresh_downgrade_decide olivia 2>/dev/null || true
[[ -n "${_HB_FRESH_DOWNGRADE_WHY:-}" ]] \
  && ok_t "D3b ... and the next real reason is honoured" \
  || bad_t "D3b a released latch still ate the downgrade" "why='${_HB_FRESH_DOWNGRADE_WHY:-}'"

# D4 THE SUBSHELL TRAP. The decision is TWO answers (warm-because-X, and
# fresh-although-X); only the first can travel through stdout. Capture the call
# the way a `why="$(…)"` call site does and the suppression is invisible — the
# branch that logs it becomes dead code while every other arm here still passes.
# So: the behaviour (the global is set in the CALLER's shell) and the wiring
# (the dispatch site calls it bare) are both asserted.
rm -f "$(latch_p olivia)"
_hb_fresh_downgrade_decide olivia >/dev/null 2>&1 || true   # latch
_HB_FRESH_DOWNGRADE_SUPPRESSED=""
CAP=$(_hb_fresh_downgrade_decide olivia 2>/dev/null)  # the WRONG shape, on purpose
[[ -z "$CAP" && -z "${_HB_FRESH_DOWNGRADE_SUPPRESSED:-}" ]] \
  && ok_t "D4 a \$(…) capture cannot see the decision — which is why the call site must not use one" \
  || bad_t "D4 the subshell capture leaked a value" "cap='${CAP}' supp='${_HB_FRESH_DOWNGRADE_SUPPRESSED:-}'"
rm -f "$(latch_p olivia)"
_hb_fresh_downgrade_decide olivia 2>/dev/null || true
_hb_fresh_downgrade_decide olivia 2>/dev/null || true
[[ -n "${_HB_FRESH_DOWNGRADE_SUPPRESSED:-}" ]] \
  && ok_t "D4b a BARE call sets the suppression in the caller's own shell" \
  || bad_t "D4b the bare call did not export the decision" "supp='${_HB_FRESH_DOWNGRADE_SUPPRESSED:-}'"
D4W=$(grep -c '^ *_hb_fresh_downgrade_decide "\$name"$' "$SRC/cmd_heartbeat.sh")
D4B=$(grep -c '_warm_why="\$(_hb_fresh_downgrade_decide' "$SRC/cmd_heartbeat.sh")
(( D4W >= 1 && D4B == 0 )) \
  && ok_t "D4c the dispatch site calls the decision BARE, not through a capture" \
  || bad_t "D4c the dispatch site re-introduced the subshell" "bare=${D4W} captured=${D4B}"
rm -f "$(latch_p olivia)"
_HB_FRESH_DOWNGRADE_WHY=""; _HB_FRESH_DOWNGRADE_SUPPRESSED=""

# =============================================================================
# B) the claim the reaper could never reach
# =============================================================================
reset_all
TB1=$(mk_delivered_unacked)
stamp_verdict "$TB1"
db "UPDATE tasks SET started_at=datetime('now','-200 minutes') WHERE id=${TB1};"
read -r RCB1 _ < <(_hb_reclaim olivia 30)
[[ "$(rowa "$TB1")" == "todo|olivia|NULL" ]] && (( ${RCB1:-0} == 1 )) \
  && ok_t "B1 a claim that outlived its verdict, past the budget, is reclaimed to todo on the same seat" \
  || bad_t "B1 the orphaned post-verdict claim was not reclaimed" "reclaimed=${RCB1:-?} row=$(rowa "$TB1")"

reset_all
TB2=$(mk_delivered_unacked)
stamp_verdict "$TB2"
db "UPDATE tasks SET started_at=datetime('now','-5 minutes') WHERE id=${TB2};"
read -r RCB2 _ < <(_hb_reclaim olivia 30)
[[ "$(rowa "$TB2")" == in_progress\|olivia\|* ]] && (( ${RCB2:-1} == 0 )) \
  && ok_t "B2 inside the budget the verifier keeps the claim and runs its own hand-back" \
  || bad_t "B2 a fresh post-verdict claim was raced" "reclaimed=${RCB2:-?} row=$(rowa "$TB2")"

# B5 the budget gate itself: past the idle-stall grace (20m) but inside the
# hard-cap budget, with a verdict on the row and the seat reading idle. This is
# the arm that keeps the fall-through BOUNDED — without the budget conjunct the
# idle-stall arm (b) takes the row 65 minutes early, which is a race against the
# verifier's own hand-back rather than a repair of an orphan.
reset_all
TB5=$(mk_delivered_unacked)
stamp_verdict "$TB5"
db "UPDATE tasks SET started_at=datetime('now','-25 minutes') WHERE id=${TB5};"
read -r RCB5 _ < <(_hb_reclaim olivia 30)
[[ "$(rowa "$TB5")" == in_progress\|olivia\|* ]] && (( ${RCB5:-1} == 0 )) \
  && ok_t "B5 past the idle-stall grace but inside the budget — the idle arm does not take it either" \
  || bad_t "B5 the fall-through is not bounded by the budget" "reclaimed=${RCB5:-?} row=$(rowa "$TB5")"

reset_all
TB3=$(mk_delivered_unacked)
db "UPDATE tasks SET started_at=datetime('now','-200 minutes') WHERE id=${TB3};"
read -r RCB3 _ < <(_hb_reclaim olivia 30)
[[ "$(rowa "$TB3")" == in_progress\|olivia\|* ]] && (( ${RCB3:-1} == 0 )) \
  && ok_t "B3 [control] no verdict yet — DIVE-2560's verifier-latency skip still holds" \
  || bad_t "B3 the fix widened DIVE-2560's skip" "reclaimed=${RCB3:-?} row=$(rowa "$TB3")"

reset_all
TB4=$(mk_delivered_unacked)
db "UPDATE tasks SET graded_at=datetime('now','-300 minutes'), graded_verdict='pass',
       graded_verdict_at=datetime('now','-300 minutes'), graded_by='olivia',
       started_at=datetime('now','-200 minutes') WHERE id=${TB4};"
read -r RCB4 _ < <(_hb_reclaim olivia 30)
[[ "$(rowa "$TB4")" == in_progress\|olivia\|* ]] && (( ${RCB4:-1} == 0 )) \
  && ok_t "B4 [control] a verdict older than the delivery graded another iteration — not a hand-back" \
  || bad_t "B4 a stale verdict was read as this iteration's" "reclaimed=${RCB4:-?} row=$(rowa "$TB4")"

# =============================================================================
# C) the class the board can name
# =============================================================================
dreason() { db "SELECT COALESCE($(_task_doctor_reason_case_sql '' '' 0),'') FROM tasks WHERE id=$1;"; }

reset_all
TC1=$(mk_delivered_unacked)
stamp_verdict "$TC1"
[[ "$(dreason "$TC1")" == "claim-outlived-verdict" ]] \
  && ok_t "C1 task doctor names a claim that outlived its verdict" \
  || bad_t "C1 doctor did not name the class" "got '$(dreason "$TC1")'"
[[ -n "$(_task_doctor_explain claim-outlived-verdict)" \
   && "$(_task_doctor_explain claim-outlived-verdict)" != "undispatchable" ]] \
  && ok_t "C1b the class carries a remedy, not the generic fallback" \
  || bad_t "C1b no remedy for the new class" "got '$(_task_doctor_explain claim-outlived-verdict)'"

reset_all
TC2=$(mk_delivered_unacked)
[[ "$(dreason "$TC2")" != "claim-outlived-verdict" ]] \
  && ok_t "C2 [control] an ungraded delivery sitting in the verifier's queue is not that class" \
  || bad_t "C2 doctor named an ordinary open handoff" "got '$(dreason "$TC2")'"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
(( FAIL == 0 ))
