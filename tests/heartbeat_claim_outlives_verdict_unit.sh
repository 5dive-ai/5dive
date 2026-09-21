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
#   A2  ... and an unacked delivery this seat holds AS VERIFIER;
#   A3  CONTROL — a seat with neither signal gets NO reason (it still /clears);
#   A4  CONTROL — once ACKed, no reason: the signal is the open handoff, not
#       "this seat is a verifier";
#   A5  CONTROL — a row bounced back to the MAKER (assignee != verifier) is not
#       an open handoff here either;
#   A6  STRUCTURAL — the dispatch path consults the helper and downgrades
#       `eff_fresh`, rather than skipping the tick: a downgrade is strictly
#       weaker than a defer and must stay that way;
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
R=$(_hb_fresh_downgrade_reason olivia)
[[ "$R" == *"unacked"* ]] \
  && ok_t "A2 an unacked delivery held AS VERIFIER is a reason to keep the context warm" \
  || bad_t "A2 unacked verifier delivery produced no reason" "got '${R}' row=$(rowa "$TA2")"

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
  && ok_t "A4 [control] an ACKed handoff is not an open handoff — no downgrade" \
  || bad_t "A4 an ACKed handoff still downgraded" "got '${R}'"

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
A6=$(awk '/_warm_why="\$\(_hb_fresh_downgrade_reason/{f=1} f&&/eff_fresh="false"/{print "hit"; exit}' "$SRC/cmd_heartbeat.sh")
A6C=$(awk '/_warm_why="\$\(_hb_fresh_downgrade_reason/{f=1} f&&n++<12&&/continue/{print "defer"; exit}' "$SRC/cmd_heartbeat.sh")
[[ "$A6" == "hit" && -z "$A6C" ]] \
  && ok_t "A6 the dispatch path downgrades eff_fresh and never defers the tick on this signal" \
  || bad_t "A6 dispatch wiring is wrong" "downgrade='${A6}' defer='${A6C}'"

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
