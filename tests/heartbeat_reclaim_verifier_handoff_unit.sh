#!/usr/bin/env bash
# DIVE-2560 — isolated unit harness for the _hb_reclaim guard against
# reclaiming a row that is sitting DELIVERED and awaiting its verifier's ACK.
#
# THE BUG. _hb_reclaim's idle-stall (b) and hard-cap (c) arms read only claim
# age + the idle probe. Once the dispatcher claims a nudge on the VERIFIER's
# behalf (status -> in_progress, assignee already flipped to the verifier by
# _task_route_to_verifier on delivery), a verifier who is legitimately reading
# / thinking about a delivery — not stalled — reads identically to an agent
# that abandoned real work. Reclaimed rows sat in the SAME state
# _hb_stall_sweep already has a correct, slower nag for (DIVE-1416 gap#2), so
# the two mechanisms fought: the sweep waited, the reclaim didn't.
#
# WHAT THIS PROVES, arm by arm:
#   1  an unacked verifier-held delivery, aged past the idle-stall grace AND
#      read as idle, is NOT reclaimed (rule b suppressed);
#   2  the same row, aged past the hard-cap budget, is NOT reclaimed either
#      (rule c suppressed) — neither arm fires just because the other didn't;
#   3  CONTROL — once the verifier explicitly ACKs (handoff_ack_at set), the
#      SAME row aged the SAME way IS reclaimed normally: the guard is scoped to
#      the unacked state, not a blanket exemption for verifier-owned rows;
#   4  CONTROL — a row bounced back to its MAKER by a reject (assignee no
#      longer equals the row's verifier, even though handoff_delivered_at is
#      still set from the original delivery) reclaims normally: ordinary
#      rework is not mistaken for an open handoff;
#   5  rule (a) — the claiming session actually gone — still fires on an
#      unacked verifier-held row; only (b)/(c) are guarded, never (a).
#
# Same isolation contract as tests/heartbeat_dispatcher_claim_unit.sh: source
# src/ directly, throwaway tasks.db, no tmux/network/root.
# Run: bash tests/heartbeat_reclaim_verifier_handoff_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-reclaim-verifier-handoff.XXXXXX)"

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
reset_all() { db "DELETE FROM tasks;"; }

# Boundaries: no tmux/registry/network. _hb_agent_idle and _hb_claude_started
# are steerable per-arm below.
REGISTRY="$TMP/registry.json"; printf '{"agents":{}}' >"$REGISTRY"
registry_read()       { cat "$REGISTRY"; }
registry_write()      { cat > "$REGISTRY"; }
_hb_send_line()      { return 0; }
_hb_pane_fingerprint() { echo "fp"; }
cmd_send()            { :; }
cmd_task_escalate()   { :; }
with_registry_lock()  { local fn="$1"; shift; "$fn" "$@"; }
_hb_claude_started()  { echo ""; }   # no proc time by default -> rule (a) never fires
_hb_agent_idle()      { return 0; }  # confident idle by default

# --- fixture: a real delivery through the real routing path ------------------
# addt --assignee=dev --verifier=olivia, then cmd_task_done routes it exactly
# like tests/heartbeat_stall_sweep_unit.sh's A1: assignee -> olivia, status ->
# todo, handoff_delivered_at stamped, handoff_ack_at NULL. The dispatcher claim
# is simulated the same way the real tick would do it on olivia's next nudge.
mk_delivered_unacked() {
  local id
  id=$(addt --assignee=dev --verifier=olivia -- "ship the widget")
  ( cmd_task_done "$id" ) >/dev/null 2>&1
  _hb_claim_task olivia "$id" >/dev/null 2>&1
  printf '%s' "$id"
}

# =============================================================================
# 1) idle-stall (b) suppressed on an unacked verifier-held delivery
# =============================================================================
reset_all
T1=$(mk_delivered_unacked)
[[ "$(row "$T1")" == in_progress\|* ]] \
  && ok_t "fixture: dispatcher claim landed (in_progress)" \
  || bad_t "fixture: dispatcher claim landed" "got $(row "$T1")"
db "UPDATE tasks SET started_at=datetime('now','-25 minutes') WHERE id=${T1};"
read -r RC1_N _ < <(_hb_reclaim olivia 30)
[[ "$(row "$T1")" == in_progress\|* ]] && (( ${RC1_N:-1} == 0 )) \
  && ok_t "unacked verifier delivery, past idle-stall grace + idle probe -> NOT reclaimed" \
  || bad_t "idle-stall arm reclaimed an unacked delivery" "reclaimed=${RC1_N:-?} row=$(row "$T1")"

# =============================================================================
# 2) hard cap (c) suppressed on the same state, aged well past the budget
# =============================================================================
reset_all
T2=$(mk_delivered_unacked)
db "UPDATE tasks SET started_at=datetime('now','-200 minutes') WHERE id=${T2};"
read -r RC2_N _ < <(_hb_reclaim olivia 30)
[[ "$(row "$T2")" == in_progress\|* ]] && (( ${RC2_N:-1} == 0 )) \
  && ok_t "unacked verifier delivery, past the hard-cap budget -> NOT reclaimed" \
  || bad_t "hard-cap arm reclaimed an unacked delivery" "reclaimed=${RC2_N:-?} row=$(row "$T2")"

# =============================================================================
# 3) CONTROL — once ACKed, the same aging reclaims normally (guard is narrow)
# =============================================================================
reset_all
T3=$(mk_delivered_unacked)
db "UPDATE tasks SET started_at=datetime('now','-200 minutes'),
       handoff_ack_at=datetime('now') WHERE id=${T3};"
read -r RC3_N _ < <(_hb_reclaim olivia 30)
[[ "$(row "$T3")" == "todo|NULL" ]] && (( ${RC3_N:-0} == 1 )) \
  && ok_t "[control] an ACKed handoff is not exempt — hard cap reclaims it normally" \
  || bad_t "[control] ACKed handoff was not reclaimed" "reclaimed=${RC3_N:-?} row=$(row "$T3")"

# =============================================================================
# 4) CONTROL — a reject bounced back to the MAKER reclaims normally
# =============================================================================
# Shape a reject by hand (same fields _task_route_to_verifier's counterpart in
# cmd_task_reject writes): assignee back to the maker, verifier column
# unchanged (so verifier != assignee), handoff_delivered_at still set from the
# original delivery, handoff_ack_at cleared. The predicate this fix adds is
# `verifier = assignee` — a rejected row fails that on purpose.
reset_all
T4=$(mk_delivered_unacked)
db "UPDATE tasks SET assignee='dev', handoff_ack_at=NULL WHERE id=${T4};"
_hb_claim_task dev "$T4" >/dev/null 2>&1
db "UPDATE tasks SET started_at=datetime('now','-200 minutes') WHERE id=${T4};"
read -r RC4_N _ < <(_hb_reclaim dev 30)
[[ "$(row "$T4")" == "todo|NULL" ]] && (( ${RC4_N:-0} == 1 )) \
  && ok_t "[control] rework bounced back to the maker is not exempt — reclaims normally" \
  || bad_t "[control] rejected/rework row was not reclaimed" "reclaimed=${RC4_N:-?} row=$(row "$T4")"

# =============================================================================
# 5) rule (a) — claiming session gone — still fires on an unacked delivery
# =============================================================================
reset_all
T5=$(mk_delivered_unacked)
CLAIM_EPOCH=$(db "SELECT strftime('%s', started_at) FROM tasks WHERE id=${T5};")
# proc started well AFTER the claim -> rule (a)'s restart condition.
_hb_claude_started() { echo "$(( ${CLAIM_EPOCH} + 3600 ))"; }
read -r RC5_N _ < <(_hb_reclaim olivia 30)
_hb_claude_started() { echo ""; }   # restore
[[ "$(row "$T5")" == "todo|NULL" ]] && (( ${RC5_N:-0} == 1 )) \
  && ok_t "rule (a) still reclaims an unacked delivery when the claiming session is actually gone" \
  || bad_t "rule (a) did not fire on a gone session" "reclaimed=${RC5_N:-?} row=$(row "$T5")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
