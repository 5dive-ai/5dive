#!/usr/bin/env bash
# DIVE-4104 — isolated unit harness for the three reclaim rules this ticket
# changes, plus the fixture replay of the four rows that actually bounced.
#
# THE BUG, measured over the 7 days to 2026-09-08: the heartbeat reclaimed
# quinn's claimed rows 88 times across 40 distinct rows — 51 `idle`, 31
# `session gone`, 6 real 45m overruns — and 17 deliveries that week carry
# "re-delivery of the same pass, not rework". Three of the four buckets are not
# neglect: a quota-walled pane reads byte-identical to an abandoned one through
# `_hb_agent_idle`; a `session gone` on an already-DELIVERED row hands back as
# buildable work a pass whose maker owes nothing; and a `session gone` that
# left its pushed branch sitting in a local checkout lost no work at all.
#
# WHAT THIS PROVES, arm by arm:
#   1  CONTROL — session gone on a delivery the VERIFIER still holds keeps it on
#      the verifier with the handoff intact. This already held before the fix
#      (_hb_reclaim_to_todo never wrote `assignee`), so the ticket's premise that
#      the reclaim bounces such a row to the maker is WRONG and this arm exists
#      to pin the behaviour, not to grade the change;
#  1b  THE ARM THAT GRADES IT — a live, ungraded delivery found on the MAKER's
#      queue (the shape DIVE-4085 was in when the dispatcher picked it up for dev
#      at 17:00 on 09-08) is returned to the VERIFIER with the handoff intact
#      instead of being requeued as buildable work, and the ledger says so;
#   2  CONTROL — session gone on a row with NO live delivery and no branch
#      reclaims to plain todo on the same seat, exactly as before;
#   3  idle-stall on a seat the supervisor currently classifies
#      `quota-exhausted` -> PARKED: nothing reclaimed, claim left in_progress;
#   4  CONTROL — the same idle-stall on a seat classified `healthy` reclaims
#      normally, so the park is scoped to the wall and not to the seat;
#   5  CONTROL — a walled seat that ALSO overran the 45m budget is still
#      reclaimed by rule (c): the park narrows exactly one arm;
#   6  CONTROL — an EXPIRED park (quota-exhausted observed 7h ago, no parseable
#      deadline) reclaims normally: a park can never wedge a claim forever;
#   7  a parseable `quotaDeadline` parks to the deadline plus one tick, and a
#      deadline already in the past does not park;
#   8  session gone with the row's pushed branch still checked out -> the claim
#      is KEPT IN PLACE (status stays in_progress, started_at untouched);
#   9  CONTROL — the same row with the branch gone reclaims normally, so arm 8
#      rests on positive evidence, never on an unreadable probe;
#  10  REPLAY — the four rows that bounced on 2026-09-08 (DIVE-4085, 4071,
#      4090, 4088), each delivered to quinn and hit by a `session gone`, all
#      stay on quinn as delivered instead of going back to their makers.
#
# Same isolation contract as tests/heartbeat_reclaim_verifier_handoff_unit.sh:
# source src/ directly, throwaway tasks.db, no tmux/network/root.
# Run: bash tests/heartbeat_reclaim_loop_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-reclaim-loop.XXXXXX)"

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
who()  { db "SELECT COALESCE(assignee,'')||'|'||COALESCE(verifier,'')||'|'||COALESCE(maker_agent,'')||'|'||CASE WHEN handoff_delivered_at IS NULL THEN 'nodeliv' ELSE 'deliv' END||'|'||CASE WHEN handoff_ack_at IS NULL THEN 'noack' ELSE 'acked' END FROM tasks WHERE id=$1;"; }
reset_all() { db "DELETE FROM tasks; DELETE FROM supervisor_events; DELETE FROM ship_events;"; }

# Boundaries: no tmux/registry/network/git-on-the-real-host.
REGISTRY="$TMP/registry.json"; printf '{"agents":{}}' >"$REGISTRY"
registry_read()       { cat "$REGISTRY"; }
registry_write()      { cat > "$REGISTRY"; }
_hb_send_line()       { return 0; }
_hb_pane_fingerprint() { echo "fp"; }
cmd_send()            { :; }
cmd_task_escalate()   { :; }
with_registry_lock()  { local fn="$1"; shift; "$fn" "$@"; }
_hb_claude_started()  { echo ""; }   # no proc time by default -> rule (a) never fires
_hb_agent_idle()      { return 0; }  # confident idle by default

# The workspace probe reads real checkouts under this root; point it at a
# throwaway tree so the harness never depends on this host's projects dir.
_HB_PROJECTS_ROOT="$TMP/projects"
mkdir -p "$_HB_PROJECTS_ROOT"

# A real (tiny) git repo, so arm 8 grades `_hb_row_workspace_intact` against
# actual ref resolution rather than a stub of the thing under test.
mk_checkout_with_branch() {
  local branch="$1" d="$_HB_PROJECTS_ROOT/repo-$1"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m seed 2>/dev/null
  git -C "$d" branch -f "$branch" HEAD 2>/dev/null
}

# --- fixtures ---------------------------------------------------------------
# A delivery through the REAL routing path: `task done` on a loop row routes
# assignee -> verifier, status -> todo, handoff_delivered_at stamped, ack NULL.
mk_delivered_unacked() {
  local maker="${1:-dev}" vfier="${2:-quinn}" id
  id=$(addt --assignee="$maker" --verifier="$vfier" -- "ship the widget")
  ( cmd_task_done "$id" --result="closed in fixture setup (DIVE-2773: a first close must carry a reason)" ) >/dev/null 2>&1
  _hb_claim_task "$vfier" "$id" >/dev/null 2>&1
  printf '%s' "$id"
}
# A plain claimed row: no verifier, nothing delivered.
mk_plain_claimed() {
  local who="${1:-dev}" id
  id=$(addt --assignee="$who" -- "plain work")
  _hb_claim_task "$who" "$id" >/dev/null 2>&1
  printf '%s' "$id"
}
# Force rule (a): the claude process started an hour AFTER the claim.
gone_session() {
  local id="$1" e
  e=$(db "SELECT strftime('%s', started_at) FROM tasks WHERE id=${id};")
  eval "_hb_claude_started() { echo $(( e + 3600 )); }"
}
live_session() { _hb_claude_started() { echo ""; }; }

# One supervisor observation. `signals` mirrors the real column's shape --
# the classification is read from the column, the deadline from
# signals.signals.quotaDeadline, which is where the supervisor writes it.
sup_obs() {
  local agent="$1" cls="$2" ago="$3" deadline="${4:-unknown}"
  local dl; if [[ "$deadline" == "unknown" ]]; then dl='"unknown"'; else dl="\"$deadline\""; fi
  db "INSERT INTO supervisor_events (ts, agent, event, classification, cause, signals)
      VALUES (datetime('now','-${ago}'), $(sqlq "$agent"), 'observe', $(sqlq "$cls"), $(sqlq "$cls"),
              '{\"signals\":{\"quotaDeadline\":${dl}}}');"
}

# =============================================================================
# 1) session gone on a LIVE DELIVERY -> verifier queue, delivery preserved
# =============================================================================
reset_all
T1=$(mk_delivered_unacked dev quinn)
[[ "$(row "$T1")" == in_progress\|* ]] \
  && ok_t "fixture: quinn's dispatcher claim on a delivered row landed (in_progress)" \
  || bad_t "fixture: dispatcher claim landed" "got $(row "$T1")"
gone_session "$T1"
read -r RC1 _ < <(_hb_reclaim quinn 30)
live_session
if [[ "$(row "$T1")" == "todo|NULL" && "$(who "$T1")" == "quinn|quinn|dev|deliv|noack" ]] && (( ${RC1:-0} == 1 )); then
  ok_t "[control] session gone on a verifier-HELD delivery -> todo on the verifier, handoff intact (pre-fix behaviour, preserved)"
else
  bad_t "delivered row was not returned to the verifier queue" "reclaimed=${RC1:-?} row=$(row "$T1") who=$(who "$T1")"
fi

# 1b) THE SHAPE THAT ACTUALLY BOUNCED, and the reason arm 1 above is labelled a
# control rather than the fix. `_hb_reclaim_to_todo` never wrote `assignee`, so a
# reclaim of a row the VERIFIER still held always left it on the verifier — the
# ticket's premise that the reclaim itself bounces the row to the maker does not
# hold, and this harness proved it: arm 1 passes on the pre-fix tree too.
#
# What was measured on the board is one state further on. DIVE-4085 was delivered
# to quinn at 07:19 and at 17:00 the dispatcher picked it up FOR DEV, whose picker
# is `assignee=<seat>` — so by then something had moved `assignee` off the verifier
# while handoff_delivered_at was set and handoff_ack_at was still NULL. That writer
# is not identified (no task.reclaimed, no task.rejected, no nudge-enforce
# reassignment on the row), so this fix does not try to name it: it makes the
# reclaim IDEMPOTENT ABOUT THE HANDOFF instead. A live, ungraded delivery goes back
# to the verifier's queue whoever is holding the row, so the churn dies at the
# reclaim regardless of which writer set it up. THIS is the arm the fix has to pass
# and the pre-fix tree cannot.
reset_all
T1B=$(mk_delivered_unacked dev quinn)
db "UPDATE tasks SET assignee='dev', status='in_progress', started_at=datetime('now','-20 minutes') WHERE id=${T1B};"
gone_session "$T1B"
read -r RC1B _ < <(_hb_reclaim dev 30)
live_session
if [[ "$(who "$T1B")" == "quinn|quinn|dev|deliv|noack" ]] && (( ${RC1B:-0} == 1 )); then
  ok_t "a live delivery found on the MAKER (the observed DIVE-4085 shape) is returned to the verifier, not requeued as buildable work"
else
  bad_t "a live delivery on the maker was requeued to the maker" "reclaimed=${RC1B:-?} row=$(row "$T1B") who=$(who "$T1B")"
fi
LED1=$(db "SELECT COUNT(*) FROM lifecycle_events WHERE task_id=${T1B} AND kind='task.reclaimed' AND detail LIKE '%verifier queue, delivery preserved%';")
[[ "$LED1" == "1" ]] \
  && ok_t "the reclaim is recorded as a verifier-queue reclaim, not a bounce" \
  || bad_t "ledger did not record the verifier-queue reclaim" "matching events=${LED1}"

# =============================================================================
# 2) CONTROL — no live delivery, no branch: reclaims to plain todo as before
# =============================================================================
reset_all
T2=$(mk_plain_claimed dev)
gone_session "$T2"
read -r RC2 _ < <(_hb_reclaim dev 30)
live_session
[[ "$(row "$T2")" == "todo|NULL" && "$(who "$T2")" == "dev|||nodeliv|noack" ]] && (( ${RC2:-0} == 1 )) \
  && ok_t "[control] session gone with nothing delivered and no branch -> plain reclaim to todo" \
  || bad_t "[control] plain reclaim changed shape" "reclaimed=${RC2:-?} row=$(row "$T2") who=$(who "$T2")"

# =============================================================================
# 3) idle stall on a quota-exhausted seat -> PARKED, not reclaimed
# =============================================================================
reset_all
T3=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-40 minutes') WHERE id=${T3};"
sup_obs dev quota-exhausted "10 minutes"
read -r RC3 _ < <(_hb_reclaim dev 30)
[[ "$(row "$T3")" == in_progress\|* ]] && (( ${RC3:-1} == 0 )) \
  && ok_t "idle stall on a seat the supervisor classifies quota-exhausted -> claim PARKED" \
  || bad_t "a walled seat's claim was reclaimed as idle" "reclaimed=${RC3:-?} row=$(row "$T3")"

# =============================================================================
# 4) CONTROL — the same idle stall on a healthy seat reclaims normally
# =============================================================================
reset_all
T4=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-40 minutes') WHERE id=${T4};"
sup_obs dev quota-exhausted "40 minutes"
sup_obs dev healthy "5 minutes"
read -r RC4 _ < <(_hb_reclaim dev 30)
[[ "$(row "$T4")" == "todo|NULL" ]] && (( ${RC4:-0} == 1 )) \
  && ok_t "[control] the LATEST classification decides — a healed seat reclaims normally" \
  || bad_t "[control] a healthy seat was parked on a stale wall" "reclaimed=${RC4:-?} row=$(row "$T4")"

# =============================================================================
# 5) CONTROL — a walled seat that overran the 45m budget still reclaims (c)
# =============================================================================
reset_all
T5=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-200 minutes') WHERE id=${T5};"
sup_obs dev quota-exhausted "10 minutes"
read -r RC5 _ < <(_hb_reclaim dev 30)
[[ "$(row "$T5")" == "todo|NULL" ]] && (( ${RC5:-0} == 1 )) \
  && ok_t "[control] the 45m budget arm is untouched — a walled seat's real overrun still reclaims" \
  || bad_t "[control] the park swallowed a hard-cap overrun" "reclaimed=${RC5:-?} row=$(row "$T5")"

# =============================================================================
# 6) CONTROL — an EXPIRED park reclaims: a park cannot wedge a claim
# =============================================================================
reset_all
T6=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-40 minutes') WHERE id=${T6};"
sup_obs dev quota-exhausted "7 hours"       # > the 6h unknown-deadline cap
read -r RC6 _ < <(_hb_reclaim dev 30)
[[ "$(row "$T6")" == "todo|NULL" ]] && (( ${RC6:-0} == 1 )) \
  && ok_t "[control] a park with no parseable deadline expires at 6h and the claim reclaims" \
  || bad_t "[control] an expired park still held the claim" "reclaimed=${RC6:-?} row=$(row "$T6")"

# =============================================================================
# 7) a parseable quotaDeadline parks to deadline + one tick, and only forward
# =============================================================================
reset_all
sup_obs dev quota-exhausted "10 minutes" "$(date -u -d '+30 minutes' '+%Y-%m-%d %H:%M:%S')"
P7=$(_hb_quota_parked dev 5)
[[ "${P7:-}" =~ ^[0-9]+$ ]] && (( P7 >= 30 && P7 <= 40 )) \
  && ok_t "a parseable deadline parks to the deadline plus one tick (~${P7}m left)" \
  || bad_t "parseable deadline did not set the park window" "remaining=${P7:-<empty>}"
db "DELETE FROM supervisor_events;"
sup_obs dev quota-exhausted "10 minutes" "$(date -u -d '-30 minutes' '+%Y-%m-%d %H:%M:%S')"
P7B=$(_hb_quota_parked dev 5)
[[ -z "${P7B:-}" ]] \
  && ok_t "a deadline already in the past does not park" \
  || bad_t "a past deadline still parked the claim" "remaining=${P7B}"

# =============================================================================
# 8) session gone but the pushed branch is still checked out -> claim KEPT
# =============================================================================
reset_all
T8=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-10 minutes') WHERE id=${T8};"
IDENT8=$(db "SELECT ident FROM tasks WHERE id=${T8};")
mk_checkout_with_branch dive-4104-fixture
db "INSERT INTO ship_events (kind, actor, ident, repo, branch, sha)
    VALUES ('ship','agent-dev',$(sqlq "$IDENT8"),'5dive-ai/5dive','dive-4104-fixture','$(printf 'a%039d' 1)');"
BEFORE8=$(row "$T8")
gone_session "$T8"
read -r RC8 _ < <(_hb_reclaim dev 30)
live_session
[[ "$(row "$T8")" == "$BEFORE8" ]] && (( ${RC8:-1} == 0 )) \
  && ok_t "session gone with the row's branch still checked out -> claim kept in place, started_at intact" \
  || bad_t "an intact workspace was still reclaimed" "reclaimed=${RC8:-?} row=$(row "$T8") before=$BEFORE8"

# =============================================================================
# 9) CONTROL — branch gone: no positive evidence, so it reclaims normally
# =============================================================================
rm -rf "$_HB_PROJECTS_ROOT/repo-dive-4104-fixture"
db "UPDATE tasks SET status='in_progress', started_at=datetime('now','-10 minutes') WHERE id=${T8};"
gone_session "$T8"
read -r RC9 _ < <(_hb_reclaim dev 30)
live_session
[[ "$(row "$T8")" == "todo|NULL" ]] && (( ${RC9:-0} == 1 )) \
  && ok_t "[control] the same row with its checkout deleted reclaims — evidence, not a blanket exemption" \
  || bad_t "[control] a missing workspace still held the claim" "reclaimed=${RC9:-?} row=$(row "$T8")"

# =============================================================================
# 10) REPLAY — the four rows that bounced on 2026-09-08 stay on quinn
# =============================================================================
reset_all
declare -A MAKER=( [4085]=dev [4071]=olivia [4090]=dev [4088]=dev )
BOUNCED=0
for n in 4085 4071 4090 4088; do
  TID=$(mk_delivered_unacked "${MAKER[$n]}" quinn)
  # The state each of the four was actually in when it bounced: delivered and
  # ungraded, but sitting on the MAKER's queue (see arm 1b) and claimed there.
  db "UPDATE tasks SET assignee=$(sqlq "${MAKER[$n]}"), status='in_progress',
         started_at=datetime('now','-20 minutes') WHERE id=${TID};"
  gone_session "$TID"
  ( _hb_reclaim "${MAKER[$n]}" 30 ) >/dev/null
  live_session
  if [[ "$(who "$TID")" != "quinn|quinn|${MAKER[$n]}|deliv|noack" ]]; then
    BOUNCED=$((BOUNCED+1))
    printf '   DIVE-%s bounced: who=%s\n' "$n" "$(who "$TID")"
  fi
done
(( BOUNCED == 0 )) \
  && ok_t "[replay] all four 2026-09-08 rows (4085/4071/4090/4088) stay DELIVERED on quinn — none bounced to its maker" \
  || bad_t "[replay] rows still bounce to their makers" "${BOUNCED} of 4 bounced"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
