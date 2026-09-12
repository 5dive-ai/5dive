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
# DIVE-4385 appended arms 6-10. THE SECOND BUG THIS SUITE DID NOT SEE: rule
# (a)'s DIVE-4104 branch reads a `delivered_live` column that never looked at
# `handoff_rejected_at`. A reject stamps that clock and LEAVES
# handoff_delivered_at set on purpose (it is a token the next delivery spends),
# so a bounced row read "delivered and ungraded" forever — and a maker whose
# session died mid-rework had the rework handed to the verifier who bounced it.
# Arm 4 above is the neighbouring control and stayed green throughout, because
# it only ever exercised the OTHER predicate (`verifier = assignee`).
#
#   6  a BOUNCED row whose maker's session is gone goes back to the MAKER,
#      still todo — rule (a) fires, but not into the verifier's queue;
#   7  CONTROL — an un-rejected live delivery whose holder's session is gone
#      still lands on the verifier WITH the delivery stamps intact. DIVE-4104's
#      behaviour must not regress; this arm is what proves the clause is narrow;
#   8  a reject OLDER than the delivery that followed it (the token was spent)
#      is live again -> verifier. Hand-shaped: the live re-delivery path
#      (task/delivery.sh) NULLs handoff_rejected_at rather than leaving it
#      behind, so both halves of the clause's OR are load-bearing;
#   9  the GUARD INSIDE _hb_reclaim_to_todo's keep-handoff mode, called
#      DIRECTLY on a bounced row — the one call site where it is not already
#      covered by the selector. It must refuse to move the row at all;
#  10  the rule (b) skip (`awaiting_verifier`) on a bounced row PARKED on its
#      verifier. Before this fix that column was 0 only because a reject moves
#      the assignee off the verifier; with the row parked back by hand it was 1,
#      and the skip became a hold with no exit.
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
# DIVE-4385: who holds the row is the whole question below, and row() cannot see it.
rowa() { db "SELECT status||'|'||COALESCE(assignee,'NULL') FROM tasks WHERE id=$1;"; }
# handoff stamps, for the arm that has to prove the delivery SURVIVED the reclaim.
hoff() { db "SELECT CASE WHEN handoff_delivered_at IS NULL THEN 'nodeliv' ELSE 'deliv' END
             || '|' || CASE WHEN handoff_ack_at IS NULL THEN 'unacked' ELSE 'acked' END
             FROM tasks WHERE id=$1;"; }
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
  id=$(addt --assignee=dev --verifier=olivia --verify -- "ship the widget")
  ( cmd_task_done "$id" --result="closed in fixture setup (DIVE-2773: a first close must carry a reason)" ) >/dev/null 2>&1
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

# =============================================================================
# DIVE-4385 — a reject must be visible to the reclaimer.
# =============================================================================
# mk_rejected: the live shape, not a hand-built row. Deliver through the real
# cmd_task_done, then bounce it with EXACTLY the columns src/task/delivery.sh
# writes on a reject (status todo, assignee back to the maker, started_at and
# handoff_ack_at cleared, handoff_rejected_at stamped, done_at cleared) --
# handoff_delivered_at deliberately left in place, which is the whole defect.
mk_rejected() {
  local id
  id=$(addt --assignee=dev --verifier=olivia --verify -- "ship the widget")
  ( cmd_task_done "$id" --result="iteration 1 delivered (fixture)" ) >/dev/null 2>&1
  db "UPDATE tasks SET status='todo', assignee='dev', started_at=NULL, handoff_ack_at=NULL,
        handoff_rejected_at=datetime('now'), done_at=NULL WHERE id=${id};"
  printf '%s' "$id"
}

# --- 6) a bounced row whose maker's session is gone goes back to the MAKER ----
reset_all
T6=$(mk_rejected)
[[ "$(rowa "$T6")" == "todo|dev" && "$(hoff "$T6")" == "deliv|unacked" ]] \
  && ok_t "fixture: the bounce leaves handoff_delivered_at set (the token the reclaimer misread)" \
  || bad_t "fixture: bounce shape" "row=$(rowa "$T6") hoff=$(hoff "$T6")"
_hb_claim_task dev "$T6" >/dev/null 2>&1
CLAIM6=$(db "SELECT strftime('%s', started_at) FROM tasks WHERE id=${T6};")
_hb_claude_started() { echo "$(( CLAIM6 + 3600 ))"; }   # rule (a): the maker's session is gone
read -r RC6_N _ < <(_hb_reclaim dev 30)
_hb_claude_started() { echo ""; }
[[ "$(rowa "$T6")" == "todo|dev" ]] && (( ${RC6_N:-0} == 1 )) \
  && ok_t "bounced row + maker's session gone -> reclaimed to the MAKER, not the verifier who bounced it" \
  || bad_t "bounced rework was handed to the verifier" "reclaimed=${RC6_N:-?} row=$(rowa "$T6")"

# --- 7) CONTROL — an un-rejected live delivery still routes to the verifier ---
# DIVE-4104's own behaviour. If this goes red the clause is too wide: it would
# mean an ordinary ungraded delivery now reclaims as buildable maker work.
reset_all
T7=$(mk_delivered_unacked)
CLAIM7=$(db "SELECT strftime('%s', started_at) FROM tasks WHERE id=${T7};")
_hb_claude_started() { echo "$(( CLAIM7 + 3600 ))"; }
read -r RC7_N _ < <(_hb_reclaim olivia 30)
_hb_claude_started() { echo ""; }
[[ "$(rowa "$T7")" == "todo|olivia" && "$(hoff "$T7")" == "deliv|unacked" ]] && (( ${RC7_N:-0} == 1 )) \
  && ok_t "[control] live ungraded delivery + gone session -> still the verifier's queue, stamps intact (DIVE-4104)" \
  || bad_t "[control] DIVE-4104 regressed" "reclaimed=${RC7_N:-?} row=$(rowa "$T7") hoff=$(hoff "$T7")"

# --- 8) a reject OLDER than the delivery after it: the token was spent --------
reset_all
T8=$(mk_rejected)
# Re-delivery after the bounce. The live path NULLs handoff_rejected_at; this
# arm keeps the older stamp instead, so it grades the PREDICATE (is the reject
# older than the delivery?) rather than the convenience of a cleared column.
db "UPDATE tasks SET assignee='olivia', handoff_rejected_at=datetime('now','-10 minutes'),
      handoff_delivered_at=datetime('now'), handoff_ack_at=NULL WHERE id=${T8};"
_hb_claim_task olivia "$T8" >/dev/null 2>&1
CLAIM8=$(db "SELECT strftime('%s', started_at) FROM tasks WHERE id=${T8};")
_hb_claude_started() { echo "$(( CLAIM8 + 3600 ))"; }
read -r RC8_N _ < <(_hb_reclaim olivia 30)
_hb_claude_started() { echo ""; }
[[ "$(rowa "$T8")" == "todo|olivia" && "$(hoff "$T8")" == "deliv|unacked" ]] && (( ${RC8_N:-0} == 1 )) \
  && ok_t "re-delivery after a bounce is live again -> verifier's queue (stale reject does not stick)" \
  || bad_t "a spent reject still suppressed the handoff" "reclaimed=${RC8_N:-?} row=$(rowa "$T8")"

# --- 9) the keep-handoff GUARD, at the one call site where it stands alone ----
# The selector above already refuses to route a bounced row here, so the guard
# inside _hb_reclaim_to_todo is untested by arms 6-8 (it is subsumed). Call the
# keep-handoff mode DIRECTLY on a bounced row: the UPDATE must match nothing,
# so the row does not move at all -- it must NOT be flipped to todo|olivia.
reset_all
T9=$(mk_rejected)
_hb_claim_task dev "$T9" >/dev/null 2>&1
_hb_reclaim_to_verifier dev "$T9" "direct call: the guard is the only thing standing here" >/dev/null 2>&1
[[ "$(rowa "$T9")" == "in_progress|dev" ]] \
  && ok_t "keep-handoff mode called directly on a bounced row is refused by its own guard" \
  || bad_t "the keep-handoff guard invented a handoff on a bounced row" "row=$(rowa "$T9")"

# --- 10) rule (b)'s skip must not hold a bounced row parked on its verifier ---
# Correct-by-accident before this fix: the skip reads `verifier = assignee`, and
# a reject moves the assignee. Park the bounced row back on olivia by hand (the
# state the delivered_live bug itself produced, 5 times in the ledger) and the
# skip fired -- a hold whose exit is neither seat's act.
reset_all
T10=$(mk_rejected)
db "UPDATE tasks SET assignee='olivia' WHERE id=${T10};"
_hb_claim_task olivia "$T10" >/dev/null 2>&1
db "UPDATE tasks SET started_at=datetime('now','-200 minutes') WHERE id=${T10};"
read -r RC10_N _ < <(_hb_reclaim olivia 30)
[[ "$(row "$T10")" == "todo|NULL" ]] && (( ${RC10_N:-0} == 1 )) \
  && ok_t "a bounced row parked on its verifier is not exempt from the hard cap (rule b skip is narrow)" \
  || bad_t "rule (b) skip held a bounced row with no exit" "reclaimed=${RC10_N:-?} row=$(row "$T10")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
