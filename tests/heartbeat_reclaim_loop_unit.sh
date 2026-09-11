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
#  8d  THE HOLD IS BOUNDED — the same intact workspace 600m past the 45m budget
#      is reclaimed: rule (a)'s `continue` never touches started_at, so an
#      unbounded hold re-fires forever and (b)/(c) are never reached;
# 8e/f  the bound IS the budget — 44m still holds, 46m lapses;
#  8g  a LAPSED hold is not swallowed by DIVE-2560's verifier-latency skip, the
#      one rule between (a) and (c) that could re-create the wedge;
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

# Real (tiny) git checkouts, so arms 8/8b/8c grade `_hb_row_workspace_intact`
# against actual git state rather than a stub of the thing under test.
#
# THE TOPOLOGY IS THE POINT (DIVE-4104 iteration 2). The first cut of this
# fixture stood up ONE standalone repo and created the branch with
# `git branch -f` — no worktree. In that shape a ref lookup and a worktree
# lookup are indistinguishable, so it passed against a probe that only asked
# `rev-parse refs/heads/<x>` and would have kept passing after that probe was
# inverted. Prod's shape is many worktrees sharing one `.git`, with refs for
# branches checked out nowhere, so the fixture is built that way: a base
# checkout plus linked worktrees, and a branch that exists only as a ref.
_FX_BASE="$_HB_PROJECTS_ROOT/repo-base"
mk_base_clone() {
  rm -rf "$_HB_PROJECTS_ROOT"; mkdir -p "$_FX_BASE"
  git -C "$_FX_BASE" init -q -b trunk 2>/dev/null
  git -C "$_FX_BASE" -c user.email=t@example.com -c user.name=t \
      commit -q --allow-empty -m seed 2>/dev/null
}
# A branch CHECKED OUT in its own linked worktree, sharing the base .git.
mk_worktree_on_branch() {
  local branch="$1" d="$_HB_PROJECTS_ROOT/wt-$1"
  rm -rf "$d"
  git -C "$_FX_BASE" worktree add -q -b "$branch" "$d" HEAD 2>/dev/null
  printf '%s' "$d"
}
# A branch that exists only as a ref in the shared clone — checked out nowhere.
mk_ref_only_branch() { git -C "$_FX_BASE" branch -f "$1" HEAD 2>/dev/null; }
# Bind a row to a pushed branch the way a real push does.
bind_branch() {
  local id="$1" branch="$2" ident
  ident=$(db "SELECT ident FROM tasks WHERE id=${id};")
  db "INSERT INTO ship_events (kind, actor, ident, repo, branch, sha)
      VALUES ('ship','agent-dev',$(sqlq "$ident"),'5dive-ai/5dive',$(sqlq "$branch"),'$(printf 'a%039d' "$id")');"
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
# 5) a walled seat that overran the budget is HELD by rule (c) too (DIVE-4171)
#
# THIS ARM IS INVERTED FROM ITS FIRST FORM, deliberately, and the inversion is
# the ticket. DIVE-4104 narrowed the park to rule (b) only and asserted here
# that "a walled seat that also overran its 45m budget is still a real
# overrun". Measured on codex 2026-09-09, that premise fails for any wall
# OUTLASTING the budget — which every ChatGPT usage wall does: DIVE-4119 was
# reaped at 11:20 ("overran 45m budget (reap #1)"), re-nudged into the same wall
# at 11:30, and blocked + escalated at 12:21. A human gate was filed for a seat
# that had lost nothing. DIVE-4171 extends the park to rule (c); the hold is
# bounded by the SAME park (deadline+tick, else the 6h fallback), so arm 5b
# below is the control that replaces this one's old job.
# =============================================================================
reset_all
T5=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-200 minutes') WHERE id=${T5};"
sup_obs dev quota-exhausted "10 minutes"
read -r RC5 _ < <(_hb_reclaim dev 30)
[[ "$(row "$T5")" == in_progress\|* ]] && (( ${RC5:-1} == 0 )) \
  && ok_t "a walled seat 200m past the budget is HELD by rule (c), not reaped (DIVE-4171)" \
  || bad_t "a walled seat's overrun still reaped" "reclaimed=${RC5:-?} row=$(row "$T5")"

# 5b) CONTROL — the hold is BOUNDED. The same row, same overrun, but the wall
# observation is older than the 6h fallback cap (_HB_QUOTA_PARK_FALLBACK_SEC),
# so the park has expired and rule (c) owns the row again. This is what keeps
# arm 5 from being the wedge DIVE-4104's own comment calls worse than churn.
reset_all
T5B=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-200 minutes') WHERE id=${T5B};"
sup_obs dev quota-exhausted "7 hours"
read -r RC5B _ < <(_hb_reclaim dev 30)
[[ "$(row "$T5B")" == "todo|NULL" ]] && (( ${RC5B:-0} == 1 )) \
  && ok_t "[control] an EXPIRED park releases the overrun to rule (c) — the hold cannot outlive its reason" \
  || bad_t "[control] the park outlived its 6h cap" "reclaimed=${RC5B:-?} row=$(row "$T5B")"

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
# The window is tight ON PURPOSE and the tick is asserted as a DELTA. A
# 30..40m window accepts a park that dropped `+ everyMin * 60` entirely, so
# the "plus ONE TICK" half of the acceptance went unmeasured; reading the same
# deadline at two tick lengths pins the tick itself, whatever the clock did
# between the two calls.
P7T=$(_hb_quota_parked dev 20)
[[ "${P7:-}" =~ ^[0-9]+$ ]] && (( P7 >= 33 && P7 <= 35 )) \
  && ok_t "a parseable deadline parks to the deadline plus one tick (~${P7}m left)" \
  || bad_t "parseable deadline did not set the park window" "remaining=${P7:-<empty>}"
# 14 or 15: the remainder is floor-divided into minutes and the two calls do
# not share a clock second, so a whole-minute equality would be flaky. Zero is
# what dropping the tick scores.
[[ "${P7T:-}" =~ ^[0-9]+$ ]] && (( P7T - P7 >= 14 && P7T - P7 <= 15 )) \
  && ok_t "the park's tail IS one tick: a 20m tick parks exactly 15m longer than a 5m tick" \
  || bad_t "the park did not scale with the tick length (expected +15m for a 20m tick)" "park5=${P7:-<empty>} park20=${P7T:-<empty>}"
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
mk_base_clone
mk_worktree_on_branch dive-4104-fixture >/dev/null
T8=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-10 minutes') WHERE id=${T8};"
bind_branch "$T8" dive-4104-fixture
BEFORE8=$(row "$T8")
gone_session "$T8"
read -r RC8 _ < <(_hb_reclaim dev 30)
live_session
[[ "$(row "$T8")" == "$BEFORE8" ]] && (( ${RC8:-1} == 0 )) \
  && ok_t "session gone with the row's branch still checked out -> claim kept in place, started_at intact" \
  || bad_t "an intact workspace was still reclaimed" "reclaimed=${RC8:-?} row=$(row "$T8") before=$BEFORE8"

# =============================================================================
# 8d) THE HOLD IS BOUNDED — quinn's repro (iteration 3 reject). Rule (a)'s
# intact-workspace branch reacts with a bare `continue` and never touches
# started_at, so `proc_start > started_epoch` stays true forever: unbounded, the
# hold re-fires every tick and (b)/(c) are never reached, leaving a claim ten
# hours past its budget that nothing can take back. Same fixtures as arm 8, the
# only difference is the age. Arm 8 sets -10 minutes, which is why it cannot see
# this.
# =============================================================================
T8D=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-600 minutes') WHERE id=${T8D};"
bind_branch "$T8D" dive-4104-fixture
gone_session "$T8D"
read -r RC8D _ < <(_hb_reclaim dev 5)
live_session
[[ "$(row "$T8D")" == "todo|NULL" ]] && (( ${RC8D:-0} >= 1 )) \
  && ok_t "an intact workspace 600m past the 45m budget is reclaimed — the hold expires, it does not wedge" \
  || bad_t "an intact workspace held a claim 600m past the budget — the hold is unbounded" \
          "reclaimed=${RC8D:-?} row=$(row "$T8D")"

# =============================================================================
# 8e/8f) THE BOUND IS THE BUDGET, and it is the 45m floor either side of it —
# 44m still holds, 46m does not. Without the pair, a mutant that deletes the
# hold outright (always reclaim) or one that widens the comparison passes.
# =============================================================================
T8E=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-44 minutes') WHERE id=${T8E};"
bind_branch "$T8E" dive-4104-fixture
BEFORE8E=$(row "$T8E")
gone_session "$T8E"
read -r RC8E _ < <(_hb_reclaim dev 5)
live_session
[[ "$(row "$T8E")" == "$BEFORE8E" ]] && (( ${RC8E:-1} == 0 )) \
  && ok_t "inside the budget (44m of 45m) an intact workspace still keeps the claim in place" \
  || bad_t "the hold lapsed while still inside the budget" "reclaimed=${RC8E:-?} row=$(row "$T8E") before=$BEFORE8E"

T8F=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-46 minutes') WHERE id=${T8F};"
bind_branch "$T8F" dive-4104-fixture
gone_session "$T8F"
read -r RC8F _ < <(_hb_reclaim dev 5 2>"$TMP/8f.err")
live_session
[[ "$(row "$T8F")" == "todo|NULL" ]] && (( ${RC8F:-0} >= 1 )) \
  && ok_t "one minute past the budget (46m of 45m) the hold lapses and the ordinary rules take the row" \
  || bad_t "the hold survived past the budget boundary" "reclaimed=${RC8F:-?} row=$(row "$T8F")"
# A hold that lapses SILENTLY reads, in the log, exactly like the wedge it fixes:
# the last line about the row says "claim KEPT in place" and nothing ever
# retracts it. The lapse is the interesting event, so it is a graded one.
grep -q "hold LAPSED" "$TMP/8f.err" \
  && ok_t "the lapse is written to the ledger — a silent lapse is indistinguishable from the wedge" \
  || bad_t "the hold lapsed without saying so" "log=$(tail -3 "$TMP/8f.err")"

# =============================================================================
# 8g) THE LAPSE HAS NO SECOND DOOR. A lapsed hold falls through to the ordinary
# rules, and DIVE-2560's verifier-latency skip sits between rule (a) and (c).
# It normally cannot catch such a row (assignee=verifier + delivered + unACKed
# reads `delivered_live` and is handled inside rule (a)) — EXCEPT when
# maker_agent is NULL, which reads awaiting_verifier=1 and delivered_live=0.
# Built here directly, because the defect being fixed is a hold with no exit and
# an exit that exists in one shape only is not an exit.
# =============================================================================
T8G=$(mk_plain_claimed quinn)
db "UPDATE tasks SET started_at=datetime('now','-600 minutes'),
        verifier='quinn', maker_agent=NULL,
        handoff_delivered_at=datetime('now','-590 minutes'), handoff_ack_at=NULL
      WHERE id=${T8G};"
bind_branch "$T8G" dive-4104-fixture
gone_session "$T8G"
read -r RC8G _ < <(_hb_reclaim quinn 5)
live_session
[[ "$(row "$T8G")" == "todo|NULL" ]] && (( ${RC8G:-0} >= 1 )) \
  && ok_t "a lapsed hold is not swallowed by the verifier-latency skip — it reaches the ordinary rules" \
  || bad_t "the verifier-latency skip re-created the unbounded hold one level down" \
          "reclaimed=${RC8G:-?} row=$(row "$T8G")"

# =============================================================================
# 8b) CONTROL — the ref survives but NO worktree holds it -> reclaims
#
# This is the arm the old fixture could not have: a second branch in the SAME
# shared clone, created with `git branch` and checked out nowhere. `rev-parse
# refs/heads/<x>` resolves it from any of the sibling checkouts, so a probe
# that asks the ref store answers INTACT and wedges the claim; only a
# per-worktree probe reclaims. Measured on the real host root the same way:
# dive-1002-least-priv-isolation resolves as a ref and is checked out in zero
# worktrees.
# =============================================================================
mk_ref_only_branch dive-4104-ref-only
T8B=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-10 minutes') WHERE id=${T8B};"
bind_branch "$T8B" dive-4104-ref-only
gone_session "$T8B"
read -r RC8B _ < <(_hb_reclaim dev 30)
live_session
[[ "$(row "$T8B")" == "todo|NULL" ]] && (( ${RC8B:-0} >= 1 )) \
  && ok_t "[control] a branch whose ref exists in the shared clone but whose worktree does not still reclaims" \
  || bad_t "a ref with no worktree held the claim — the probe is reading the ref store, not a workspace" \
          "reclaimed=${RC8B:-?} row=$(row "$T8B")"

# =============================================================================
# 8c) CONTROL — the worktree DIRECTORY is deleted while git's admin record and
# the ref both survive (the shape this host leaves behind: nothing ever runs
# `git worktree prune`, so `worktree list` keeps naming checkouts that are
# gone) -> reclaims
# =============================================================================
rm -rf "$_HB_PROJECTS_ROOT/wt-dive-4104-fixture"
db "UPDATE tasks SET status='in_progress', started_at=datetime('now','-10 minutes') WHERE id=${T8};"
gone_session "$T8"
read -r RC8C _ < <(_hb_reclaim dev 30)
live_session
[[ "$(row "$T8")" == "todo|NULL" ]] && (( ${RC8C:-0} >= 1 )) \
  && ok_t "[control] a deleted checkout whose git admin record survives reclaims — a listed worktree is not a live one" \
  || bad_t "a worktree entry whose directory is gone still held the claim" "reclaimed=${RC8C:-?} row=$(row "$T8")"

# =============================================================================
# 9) CONTROL — the whole projects root is gone: unknown is not intact
# =============================================================================
rm -rf "$_HB_PROJECTS_ROOT"
T9=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-10 minutes') WHERE id=${T9};"
bind_branch "$T9" dive-4104-fixture
gone_session "$T9"
read -r RC9 _ < <(_hb_reclaim dev 30)
live_session
mkdir -p "$_HB_PROJECTS_ROOT"
[[ "$(row "$T9")" == "todo|NULL" ]] && (( ${RC9:-0} >= 1 )) \
  && ok_t "[control] an unreadable checkout root reclaims — evidence, not a blanket exemption" \
  || bad_t "[control] a missing workspace still held the claim" "reclaimed=${RC9:-?} row=$(row "$T9")"

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

# =============================================================================
# DIVE-4206 — THE WALL IS THE ACCOUNT'S, NOT THE SEAT'S
# =============================================================================
# 2026-09-10 02:24-02:45Z: dev, dev3 and ops were all frozen on the same
# session-limit banner (shared `mark` auth profile), but the reclaimer asks only
# about the seat it is reclaiming from — and a classification exists only where
# the supervisor got a pane capture. One readable pane on the pool now parks
# every claim on it.
#
# `_hb_agent_native_state` is stubbed rather than left to the real tmux probe:
# it is what the headroom veto reads, and the harness's contract is no tmux.
_NATIVE_STATE=""   # what every peer reads as, unless a case says otherwise
_hb_agent_native_state() { printf '%s' "$_NATIVE_STATE"; }
prof() {   # prof <profile> <seat>...  — put these seats on one auth profile
  local a="$1"; shift; local j='{"agents":{}}' n
  for n in "$@"; do j=$(jq --arg n "$n" --arg a "$a" '.agents[$n]={authProfile:$a}' <<<"$j"); done
  printf '%s' "$j" >"$REGISTRY"
}

reset_all
prof mark dev dev3
_NATIVE_STATE="blocked"
TP1=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-40 minutes') WHERE id=${TP1};"
sup_obs dev3 quota-exhausted "10 minutes"          # the PEER's pane, not dev's
read -r RCP1 _ < <(_hb_reclaim dev 30)
[[ "$(row "$TP1")" == in_progress\|* ]] && (( ${RCP1:-1} == 0 )) \
  && ok_t "a peer on the same auth profile is walled -> this seat's claim is PARKED too" \
  || bad_t "a shared-profile wall did not park the claim" "reclaimed=${RCP1:-?} row=$(row "$TP1")"

# CONTROL — the headroom veto. Peer evidence is second-hand, so it parks only
# while the pool has NO proven headroom. A seat that is natively idle/busy on
# the same profile is ground truth that the account is under its limit
# (DIVE-1666), and that beats another seat's stale observation.
reset_all
prof mark dev dev3
_NATIVE_STATE="idle"
TP2=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-40 minutes') WHERE id=${TP2};"
sup_obs dev3 quota-exhausted "10 minutes"
read -r RCP2 _ < <(_hb_reclaim dev 30)
[[ "$(row "$TP2")" == "todo|NULL" ]] && (( ${RCP2:-0} == 1 )) \
  && ok_t "[control] a natively idle peer proves headroom — the stale peer wall does NOT park" \
  || bad_t "[control] peer evidence parked a pool with proven headroom" "reclaimed=${RCP2:-?} row=$(row "$TP2")"

# CONTROL — a wall on a DIFFERENT account says nothing about this one.
reset_all
prof mark dev
prof other dev3
_NATIVE_STATE="blocked"
TP3=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-40 minutes') WHERE id=${TP3};"
sup_obs dev3 quota-exhausted "10 minutes"
read -r RCP3 _ < <(_hb_reclaim dev 30)
[[ "$(row "$TP3")" == "todo|NULL" ]] && (( ${RCP3:-0} == 1 )) \
  && ok_t "[control] a wall on a DIFFERENT auth profile does not park this seat" \
  || bad_t "[control] an unrelated account's wall parked this seat" "reclaimed=${RCP3:-?} row=$(row "$TP3")"

# CONTROL — the seat's OWN reading is first-hand and is never vetoed by headroom.
# Pins that the veto narrows the PEER arm only; folding it over both would undo
# DIVE-4104 for the seat we can actually see.
reset_all
prof mark dev dev3
_NATIVE_STATE="idle"
TP4=$(mk_plain_claimed dev)
db "UPDATE tasks SET started_at=datetime('now','-40 minutes') WHERE id=${TP4};"
sup_obs dev quota-exhausted "10 minutes"
read -r RCP4 _ < <(_hb_reclaim dev 30)
[[ "$(row "$TP4")" == in_progress\|* ]] && (( ${RCP4:-1} == 0 )) \
  && ok_t "[control] the seat's OWN wall parks regardless of a healthy peer" \
  || bad_t "[control] the headroom veto swallowed the seat's own reading" "reclaimed=${RCP4:-?} row=$(row "$TP4")"

# Leave the fixture as the rest of the file expects it: empty registry, no stub
# opinion. A case that ran after this block on a `mark` profile would otherwise
# inherit a peer wall it never set up.
printf '{"agents":{}}' >"$REGISTRY"; _NATIVE_STATE=""

# =============================================================================
# DIVE-4206 — graded, and the MERGE is another seat's: the row RECLAIMS, and
#             the seat stays dispatchable. The picker is the half that refuses.
# =============================================================================
# The shape DIVE-4161 went round four times and DIVE-4108 ten: a verifier has
# graded the pass, the delivery is bound, and the outstanding act is a merge
# owed by main. Iteration 1 of this ticket answered that by holding the claim
# here in _hb_reclaim. That inverted the ticket's own axis: the dispatch tick's
# busy-guard counts EVERY in_progress row for the seat and returns one level
# ABOVE the picker, so a standing claim on a row nobody here owes made the seat
# undispatchable onto ANY row until another seat merged -- 57% wasted attempts
# becoming 0 attempts, and an unbounded hold whose exit is not this seat's act,
# the exact class arms 6 and 8d of this file exist to forbid.
#
# The correct half is the PICKER clause (tests/heartbeat_pick_unit.sh): the row
# reclaims to todo, the seat is dispatchable again, and the picker still refuses
# to hand the graded row back. Zero wasted re-pick AND zero wedge. Nothing is
# lost by reclaiming: the board paints the row graded-to-merge off _TASKS_TFV_SQL
# whether it is todo or in_progress.
mk_graded_awaiting_merge() {   # <maker> <merge-owner>
  local maker="${1:-dev}" owner="${2:-main}" id
  id=$(mk_delivered_unacked "$maker" quinn)
  db "UPDATE tasks
         SET assignee=$(sqlq "$maker"), status='in_progress',
             started_at=datetime('now','-40 minutes'),
             -- DIVE-4327: the delivery clock is back-dated with the rest of them.
             -- mk_delivered_unacked stamps handoff_delivered_at at NOW, and this
             -- helper then wrote a grade THIRTY MINUTES EARLIER, i.e. graded_at
             -- BEFORE handoff_delivered_at.
             --
             -- That ordering is NOT impossible -- it is one of the commonest
             -- shapes on the board. 75 live rows carried it when this was
             -- measured (2026-09-11), among them DIVE-4323, DIVE-4310,
             -- DIVE-3963, DIVE-4288, DIVE-4295, DIVE-4239, DIVE-4280 and
             -- DIVE-4289. What it MEANS is that the standing grade belongs to a
             -- PREVIOUS iteration: the row was graded, then re-delivered, so the
             -- grade is stale rather than current.
             --
             -- So the ordering is exactly what cannot hold on a row that is
             -- genuinely graded-and-awaiting-merge, which is the state this
             -- helper's name claims to build -- there, the delivery precedes the
             -- grade that is waiting on it. The iteration bind in _TASKS_TFV_SQL
             -- reads the two clocks and is right to call a delivery newer than
             -- its grade an UNGRADED iteration; the old helper was building the
             -- state its own name contradicted.
             --
             -- Do NOT read this as: the clause guards an impossible state and is
             -- safe to relax. The shape this fixture means (delivered, then
             -- graded, merge owed) is unchanged; only the contradictory ordering
             -- is. The stale-grade ordering itself is pinned by inv3a in
             -- tests/loop_state_machine_invariants_unit.sh.
             handoff_delivered_at=datetime('now','-35 minutes'),
             graded_at=datetime('now','-30 minutes'), graded_by='quinn',
             graded_verdict='pass', merge_owner=$(sqlq "$owner"),
             delivery_ref='https://example.com/pr/1'
       WHERE id=${id};"
  printf '%s' "$id"
}
inprog() { db "SELECT COUNT(*) FROM tasks WHERE assignee=$(sqlq "$1") AND status='in_progress';"; }

reset_all
TM1=$(mk_graded_awaiting_merge dev main)
read -r RCM1 _ < <(_hb_reclaim dev 30)
[[ "$(row "$TM1")" != in_progress\|* ]] && (( ${RCM1:-0} >= 1 )) && (( $(inprog dev) == 0 )) \
  && ok_t "graded, merge owed by main: the idle stall RECLAIMS it — the seat is not wedged behind another seat's merge" \
  || bad_t "the graded row kept its claim and left the seat undispatchable" "reclaimed=${RCM1:-?} row=$(row "$TM1") inprog=$(inprog dev)"

# THE ARM THE VERIFIER ASKED FOR, end to end: the wedge is a DISPATCH-tick
# property, not a row property, so it is asserted with a second, ordinary row
# in the same queue. After the reclaim tick the seat must have inprog=0 (the
# busy-guard would otherwise skip it before the picker is ever reached) AND the
# picker must offer the ordinary row while still omitting the graded one.
reset_all
TM1b=$(mk_graded_awaiting_merge dev main)
TODO1=$(addt "an ordinary urgent row" --assignee=dev --priority=urgent)
read -r _ _ < <(_hb_reclaim dev 30)
PICKED=$(_hb_pick_tasks dev 5 | tr '\n' ' ')
(( $(inprog dev) == 0 )) && [[ " $PICKED " == *" $TODO1 "* ]] && [[ " $PICKED " != *" $TM1b "* ]] \
  && ok_t "after a reclaim tick the seat is dispatchable (inprog=0) and the picker offers the ordinary row but NOT the graded one" \
  || bad_t "the seat is still wedged, or the picker re-handed the graded row" "inprog=$(inprog dev) picked=[$PICKED] graded=$TM1b todo=$TODO1"

# Rule (a) is checked before the idle arm and has its own path: a gone session
# on a live delivery routes to the VERIFIER (DIVE-4104), which also clears the
# maker's claim. Either way the seat is left dispatchable.
reset_all
TM2=$(mk_graded_awaiting_merge dev main)
gone_session "$TM2"
read -r RCM2 _ < <(_hb_reclaim dev 30)
live_session
[[ "$(row "$TM2")" != in_progress\|* ]] && (( $(inprog dev) == 0 )) \
  && ok_t "graded, merge owed by main: a GONE SESSION clears the claim too — no wedge on rule (a)" \
  || bad_t "rule (a) left a graded row claimed" "reclaimed=${RCM2:-?} row=$(row "$TM2") inprog=$(inprog dev)"

# The hard-cap arm too — the runaway backstop is not disarmed by a merge that
# belongs to someone else. This is the boundedness assertion for the new state.
reset_all
TM3=$(mk_graded_awaiting_merge dev main)
db "UPDATE tasks SET started_at=datetime('now','-200 minutes') WHERE id=${TM3};"
read -r RCM3 _ < <(_hb_reclaim dev 30)
[[ "$(row "$TM3")" != in_progress\|* ]] && (( $(inprog dev) == 0 )) \
  && ok_t "graded, merge owed by main: the 200m hard cap still fires — the hold is bounded" \
  || bad_t "the hard-cap arm was disarmed by another seat's merge" "reclaimed=${RCM3:-?} row=$(row "$TM3") inprog=$(inprog dev)"

# CONTROL — the merge owner's OWN row is still ordinary work. Same fixture with
# the owner flipped to dev. The merge_elsewhere column is still SELECTed (it is
# logged), so this pins that it drives nothing but the log line: both owners
# reclaim identically.
reset_all
TM4=$(mk_graded_awaiting_merge dev dev)
read -r RCM4 _ < <(_hb_reclaim dev 30)
[[ "$(row "$TM4")" != in_progress\|* ]] && (( ${RCM4:-0} >= 1 )) \
  && ok_t "[control] graded with the merge owed by THIS seat — the ordinary rules still fire" \
  || bad_t "[control] the merge owner's own row stopped reclaiming" "reclaimed=${RCM4:-?} row=$(row "$TM4")"

# CONTROL — delivered but NOT yet graded is a different state and keeps its
# DIVE-4104 behaviour (back to the verifier's queue, delivery intact). Pins the
# graded_at half of the predicate.
reset_all
TM5=$(mk_delivered_unacked dev quinn)
db "UPDATE tasks SET assignee='dev', status='in_progress',
       started_at=datetime('now','-20 minutes') WHERE id=${TM5};"
gone_session "$TM5"
read -r RCM5 _ < <(_hb_reclaim dev 30)
live_session
[[ "$(who "$TM5")" == "quinn|quinn|dev|deliv|noack" ]] \
  && ok_t "[control] delivered but UNGRADED still routes to the verifier (DIVE-4104 unchanged)" \
  || bad_t "[control] the 4206 change swallowed an ungraded delivery" "who=$(who "$TM5") reclaimed=${RCM5:-?}"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
