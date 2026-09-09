#!/usr/bin/env bash
# DIVE-4111 — isolated unit harness for the heartbeat hard-cap AUTO-PAUSE:
# it must fire ONCE per (row, owner), and it must hand the row back with a
# CLEAN CLOCK so the remedy for it actually works.
#
# THE BUG, both halves. `_hb_reclaim`'s hard-cap arm had two branches. Below
# _HB_REAP_ESCALATE_AFTER it called _hb_reclaim_to_todo, which clears
# started_at. At or above it, it blocked + escalated and did NOT.
#
#   (1) `reap_n >= _HB_REAP_ESCALATE_AFTER` is a THRESHOLD ON A MONOTONIC
#       COUNTER, not a latch. _hb_mark_reap only increments, so the 3rd, 4th
#       and 5th reap of the same row each re-ran the whole escalation —
#       re-block, priority bump, ping the owner, PING THE PAIRED HUMAN'S PHONE.
#       Measured 2026-09-08: 12 of the fleet's 14 escalations were reaps 2..5
#       of four codex rows.
#   (2) started_at SURVIVED the pause, and every path back to todo COALESCEs
#       it (`cmd_task_unblock` sets status only; `cmd_task_start` is
#       `COALESCE(started_at, now)`). So the unblocked row re-entered
#       in_progress carrying an hours-old timestamp, `age_min >= budget` was
#       true immediately, and it was reaped on the FIRST tick after the
#       unblock. `task unblock` is the verb `task doctor` prescribes for the
#       no-anchor finding the pause produces, so the remedy fed the loop.
#
# WHAT THIS PROVES, arm by arm:
#   1  CONTROL — a reap BELOW the threshold still reclaims to todo, clean
#      clock, no escalation (the arm this fix does not touch);
#   2  the threshold reap blocks + escalates ONCE, stamps the latch, and
#      CLEARS started_at (defect 2);
#   3  THE LOOP ITSELF — unblock + re-claim the paused row and reap in the
#      same instant: it is NOT reaped, i.e. it actually gets its full budget
#      window back. Fails pre-fix on the surviving started_at alone;
#   4  the next reap of the same row requeues it to todo and DOES NOT call
#      cmd_task_escalate — no second page (defect 1);
#   5  NEGATIVE CONTROL for arm 4 — the SAME reap count with the latch NULL
#      escalates normally, so the guard keys on the latch and not on the
#      count having grown;
#   6  `task assign` to a DIFFERENT owner clears the latch (the reap count is
#      per-agent in the registry, so the latch must be too), and — the other
#      edge — assigning to the SAME owner leaves it standing;
#   7  `task unblock` does NOT clear the latch: re-arming the pause on the
#      exact verb that clears it is the loop this row was filed for.
#
# Same isolation contract as tests/heartbeat_reclaim_verifier_handoff_unit.sh:
# source src/ directly, throwaway tasks.db, no tmux/network/root.
# Run: bash tests/heartbeat_reap_escalate_latch_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-reap-escalate-latch.XXXXXX)"

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

addt() { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
row()  { db "SELECT status||'|'||COALESCE(started_at,'NULL') FROM tasks WHERE id=$1;"; }
latch(){ db "SELECT COALESCE(reap_escalated_at,'NULL')||'|'||COALESCE(reap_escalated_n,'NULL') FROM tasks WHERE id=$1;"; }
reset_all() { db "DELETE FROM tasks;"; printf '{"agents":{}}' >"$REGISTRY"; }

# Boundaries: no tmux/registry/network. The escalation is counted, not run:
# The escalation count is the proxy for "a human's phone buzzed" — the cost the
# threshold-not-a-latch defect multiplied.
REGISTRY="$TMP/registry.json"; printf '{"agents":{}}' >"$REGISTRY"
registry_read()       { cat "$REGISTRY"; }
registry_write()      { cat > "$REGISTRY"; }
_hb_send_line()       { return 0; }
_hb_pane_fingerprint(){ echo "fp"; }
cmd_send()            { :; }
# The count lives in a FILE, not a variable: _hb_reclaim is read through a
# process substitution and the real call site is subshell-wrapped, so every
# increment happens two subshells deep and a shell variable would read 0 on
# every arm — including the ones that are supposed to prove an escalation DID
# fire, which is the direction that passes silently.
ESC_FILE="$TMP/escalates"; : >"$ESC_FILE"
cmd_task_escalate()   { echo x >>"$ESC_FILE"; }
esc_reset()           { : >"$ESC_FILE"; }
esc_n()               { wc -l <"$ESC_FILE" | tr -d ' '; }
with_registry_lock()  { local fn="$1"; shift; "$fn" "$@"; }
_hb_claude_started()  { echo ""; }   # no proc time -> rule (a) never fires
_hb_agent_idle()      { return 1; }  # never a confident idle -> rule (b) never fires

BUDGET=30   # _hb_reclaim <name> <everyMin>; budget = everyMin * _HB_STALE_MULT, floored

# A row claimed by dev and aged past the budget. Fresh registry each time, so
# the reap counter starts at 0 and each arm drives it explicitly.
mk_overrun() {
  local id
  id=$(addt --assignee=dev --no-verify -- "a runaway row")
  _hb_claim_task dev "$id" >/dev/null 2>&1
  db "UPDATE tasks SET started_at=datetime('now','-200 minutes') WHERE id=${id};"
  printf '%s' "$id"
}
age_out() { db "UPDATE tasks SET started_at=datetime('now','-200 minutes') WHERE id=$1;"; }

# =============================================================================
# 1) CONTROL — reap #1, below the escalate threshold: reclaim, clean clock
# =============================================================================
reset_all
T1=$(mk_overrun)
esc_reset
read -r RC1 ES1 < <(_hb_reclaim dev "$BUDGET")
[[ "$(row "$T1")" == "todo|NULL" ]] && (( ${RC1:-0} == 1 )) && (( ${ES1:-1} == 0 )) && (( $(esc_n) == 0 )) \
  && [[ "$(latch "$T1")" == "NULL|NULL" ]] \
  && ok_t "[control] reap #1 (below threshold) -> todo, started_at cleared, no escalation, latch unset" \
  || bad_t "reap #1 did not reclaim cleanly" "reclaimed=${RC1:-?} escalated=${ES1:-?} calls=$(esc_n) row=$(row "$T1") latch=$(latch "$T1")"

# =============================================================================
# 2) reap #2 (== _HB_REAP_ESCALATE_AFTER): block + escalate ONCE, CLEAR the clock
# =============================================================================
reset_all
T2=$(mk_overrun)
esc_reset
read -r _ _ < <(_hb_reclaim dev "$BUDGET")      # reap #1 -> todo
_hb_claim_task dev "$T2" >/dev/null 2>&1; age_out "$T2"
read -r RC2 ES2 < <(_hb_reclaim dev "$BUDGET")  # reap #2 -> pause
[[ "$(row "$T2")" == "blocked|NULL" ]] && (( ${ES2:-0} == 1 )) && (( $(esc_n) == 1 )) \
  && ok_t "reap #2 -> blocked, escalated exactly once, and started_at CLEARED (defect 2)" \
  || bad_t "the threshold reap did not pause cleanly" "escalated=${ES2:-?} calls=$(esc_n) row=$(row "$T2")"
[[ "$(latch "$T2")" == *"|2" && "$(latch "$T2")" != NULL\|* ]] \
  && ok_t "the pause stamps reap_escalated_at + reap_escalated_n=2" \
  || bad_t "latch not stamped by the pause" "latch=$(latch "$T2")"

# =============================================================================
# 3) THE LOOP — unblock + re-claim the paused row, then reap in the SAME instant.
#    Pre-fix the row carried a 200-minute-old started_at through the pause and
#    was reaped on the very first tick after the unblock, so `task unblock` —
#    the verb `task doctor` prescribes — could never rescue it.
# =============================================================================
( cmd_task_unblock "$T2" ) >/dev/null 2>&1
_hb_claim_task dev "$T2" >/dev/null 2>&1        # NOT aged: this is a fresh window
esc_reset
read -r RC3 ES3 < <(_hb_reclaim dev "$BUDGET")
[[ "$(row "$T2")" == in_progress\|* ]] && (( ${RC3:-1} == 0 )) && (( ${ES3:-1} == 0 )) && (( $(esc_n) == 0 )) \
  && ok_t "after unblock + re-claim the row gets its full budget window — NOT reaped on the first tick" \
  || bad_t "the unblocked row was reaped immediately (the loop)" "reclaimed=${RC3:-?} escalated=${ES3:-?} row=$(row "$T2")"

# =============================================================================
# 4) reap #3 of the SAME row: requeue to todo, and NO second page
# =============================================================================
age_out "$T2"
esc_reset
read -r RC4 ES4 < <(_hb_reclaim dev "$BUDGET")
[[ "$(row "$T2")" == "todo|NULL" ]] && (( ${RC4:-0} == 1 )) && (( ${ES4:-1} == 0 )) && (( $(esc_n) == 0 )) \
  && ok_t "reap #3 past the threshold -> reclaimed to todo with NO second escalation (defect 1)" \
  || bad_t "a repeat reap escalated again" "reclaimed=${RC4:-?} escalated=${ES4:-?} calls=$(esc_n) row=$(row "$T2")"
[[ "$(latch "$T2")" == *"|2" ]] \
  && ok_t "the latch still records the FIRST pause (n=2), not the reap that just ran" \
  || bad_t "latch was overwritten by a later reap" "latch=$(latch "$T2")"

# =============================================================================
# 5) NEGATIVE CONTROL for arm 4 — same reap count, latch NULL: it DOES escalate.
#    Without this, arm 4 passes against code that simply stopped escalating
#    above the threshold at all.
# =============================================================================
db "UPDATE tasks SET reap_escalated_at=NULL, reap_escalated_n=NULL WHERE id=${T2};"
_hb_claim_task dev "$T2" >/dev/null 2>&1; age_out "$T2"
esc_reset
read -r _ ES5 < <(_hb_reclaim dev "$BUDGET")
[[ "$(row "$T2")" == "blocked|NULL" ]] && (( ${ES5:-0} == 1 )) && (( $(esc_n) == 1 )) \
  && ok_t "[negative control] a high reap count with the latch UNSET still pauses — the guard is the latch, not the count" \
  || bad_t "an unlatched row past the threshold failed to escalate" "escalated=${ES5:-?} calls=$(esc_n) row=$(row "$T2")"

# =============================================================================
# 6) `task assign` — both edges. A DIFFERENT owner clears the latch (the reap
#    count is per-agent in the registry, so a latch that outlived the owner
#    would disarm the pause permanently for the new seat); the SAME owner does
#    not, or a no-op reassign would re-arm the page.
# =============================================================================
( cmd_task_assign "$T2" olivia ) >/dev/null 2>&1
[[ "$(latch "$T2")" == "NULL|NULL" ]] \
  && ok_t "assign to a DIFFERENT owner clears the latch" \
  || bad_t "assign to a different owner left the latch standing" "latch=$(latch "$T2")"
db "UPDATE tasks SET reap_escalated_at=datetime('now'), reap_escalated_n=2 WHERE id=${T2};"
( cmd_task_assign "$T2" olivia ) >/dev/null 2>&1
[[ "$(latch "$T2")" == *"|2" ]] \
  && ok_t "[other edge] re-assigning to the SAME owner leaves the latch standing" \
  || bad_t "a no-op reassign re-armed the pause" "latch=$(latch "$T2")"

# =============================================================================
# 7) `task unblock` does NOT clear the latch — that verb is the loop's feed
# =============================================================================
reset_all
T7=$(mk_overrun)
read -r _ _ < <(_hb_reclaim dev "$BUDGET")
_hb_claim_task dev "$T7" >/dev/null 2>&1; age_out "$T7"
read -r _ _ < <(_hb_reclaim dev "$BUDGET")
[[ "$(row "$T7")" == blocked\|* ]] || bad_t "arm 7 fixture: row not paused" "row=$(row "$T7")"
( cmd_task_unblock "$T7" ) >/dev/null 2>&1
[[ "$(row "$T7")" == todo\|* && "$(latch "$T7")" == *"|2" ]] \
  && ok_t "unblock returns the row to todo and leaves the latch spent — the remedy cannot re-arm the page" \
  || bad_t "unblock cleared the latch" "row=$(row "$T7") latch=$(latch "$T7")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
