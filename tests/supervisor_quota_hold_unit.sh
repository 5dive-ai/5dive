#!/usr/bin/env bash
# DIVE-4097 — the capacity wall's SECOND door. A seat behind a usage wall reads
# `quota-exhausted` on the ticks where the wall is in its pane and `stuck /
# no-progress` on the ticks where it is not; door 1 mutes the human leg while
# the wall is self-healing (DIVE-3940/3970) and door 2 had no mute at all, so
# the same benign wall paged lodar's phone through the P2 ladder
# (measured 2026-09-08 13:22Z, codex, `no-progress: rotation-disabled`).
#
# Grades the two halves of the fix, both PURE — no db, no tmux, no clock:
#   _sup_quota_hold_live  is this wall still inside the horizon it self-heals on
#   _sup_act_plan  arg 10 the ladder holds instead of walking rungs at it
# The db half (_sup_quota_hold) is two queries over rows this file already
# writes and is deliberately not graded here; what it decides IS graded here.
# Run: bash tests/supervisor_quota_hold_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh cmd_supervisor.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

PASS=0; FAIL=0
t() {  # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"
  fi
}

H=3600
NOW=1757340000            # fixed clock; every epoch below is relative to it

# The wall text the incident actually carried, and the two other shapes
# _sup_quota_selfheal recognises. Asserted here rather than assumed: if a copy
# change stops one of these reading as self-healing, this harness says so
# instead of the hold silently never firing.
# NOW is 14:00 UTC, so "resets at 5pm" is a deadline still 3h ahead of the
# episode's own clock (12:00) — a LIVE dated wall, which is what the incident had.
CLOCK_SIG='Usage limit reached - continuing automatically, resets at 5pm'
CLOCK_DUE=$((NOW + 3*H))
WEEK_SIG='5h: 42% 1w: 100%'
JUNK_SIG='api error: request rejected 429'

k() { _sup_quota_selfheal "$1" "$2" | cut -d$'\x1f' -f1; }
t "clock signature reads as a dated self-heal" "clock" "$(k "$CLOCK_SIG" $((NOW - 2*H)))"
t "weekly signature reads as a weekly self-heal" "week" "$(k "$WEEK_SIG" $((NOW - 2*H)))"
t "unrecognised refusal reads as no self-heal" "no" "$(k "$JUNK_SIG" $((NOW - 2*H)))"

# ── _sup_quota_hold_live ────────────────────────────────────────────────────
# A dated wall whose own resume time is still ahead: quiet. This is the case the
# row was filed on.
first=$((NOW - 2*H))
t "dated wall, reset still ahead -> HOLD" "true" \
  "$(_sup_quota_hold_live "$first" "$CLOCK_SIG" "$first" "$NOW")"

# The same wall read AFTER the reset it promised. Nothing is muted past the
# horizon — this is the hard wall the mute exists not to hide. The horizon is the
# wall's OWN resume time, so one hour past it is already loud.
lateNOW=$((CLOCK_DUE + H))
t "dated wall, one hour past its own reset -> PAGE" "false" \
  "$(_sup_quota_hold_live "$first" "$CLOCK_SIG" $((lateNOW - H)) "$lateNOW")"
t "dated wall, one minute before its reset -> HOLD" "true" \
  "$(_sup_quota_hold_live "$first" "$CLOCK_SIG" "$first" $((CLOCK_DUE - 60)))"

# Weekly walls get the long horizon (_SUP_SELFHEAL_WEEK_H, 168h) because that is
# the reset they are actually waiting for; the DIVE-3970 finding was a benign
# weekly wall taking the phone back six days early.
wfirst=$((NOW - 100*H))
t "weekly wall, 100h in (< 168h) -> HOLD" "true" \
  "$(_sup_quota_hold_live "$wfirst" "$WEEK_SIG" $((NOW - H)) "$NOW")"
wold=$((NOW - 200*H))
t "weekly wall, 200h in (> 168h) -> PAGE" "false" \
  "$(_sup_quota_hold_live "$wold" "$WEEK_SIG" $((NOW - H)) "$NOW")"

# An episode we have not SEEN inside the continuity gap is not a live wall, even
# when its horizon has not lapsed. Errs LOUD: the ladder escalates as today.
t "weekly wall, last seen past the episode gap -> PAGE" "false" \
  "$(_sup_quota_hold_live "$wfirst" "$WEEK_SIG" $((NOW - 40*H)) "$NOW")"
t "weekly wall, last seen just inside the gap -> HOLD" "true" \
  "$(_sup_quota_hold_live "$wfirst" "$WEEK_SIG" $((NOW - 35*H)) "$NOW")"

# Door 2 must never be QUIETER than door 1: an unrecognised refusal keeps the
# human leg armed in _sup_capacity_notify_human, so it must not hold here.
t "unrecognised refusal -> PAGE (never quieter than the alert path)" "false" \
  "$(_sup_quota_hold_live "$first" "$JUNK_SIG" "$first" "$NOW")"
t "episode with no stored signature -> PAGE" "false" \
  "$(_sup_quota_hold_live "$first" "" "$first" "$NOW")"

# Absence must not read as a hold. Every non-numeric arg is "no episode".
t "no episode start -> PAGE" "false" "$(_sup_quota_hold_live "" "$CLOCK_SIG" "$first" "$NOW")"
t "no last alert -> PAGE"    "false" "$(_sup_quota_hold_live "$first" "$CLOCK_SIG" "" "$NOW")"
t "no clock -> PAGE"         "false" "$(_sup_quota_hold_live "$first" "$CLOCK_SIG" "$first" "")"

# ── _sup_act_plan arg 10 ────────────────────────────────────────────────────
# THE REGRESSION ARM: byte-for-byte the incident's inputs. rung 3 with rotation
# disabled is the branch that produced the 🚨.
t "no-progress rung 3, rotation off, NO hold -> escalates (unchanged)" \
  "escalate rotation-disabled" \
  "$(_sup_act_plan claude no-progress 2 $((NOW - 6*H)) "$NOW" false 0 true 0)"
t "no-progress rung 3, rotation off, hold -> held, not paged" \
  "defer quota-hold" \
  "$(_sup_act_plan claude no-progress 2 $((NOW - 6*H)) "$NOW" false 0 true 0 true)"

# The hold is also what stops the wall SPENDING the attempt counter — the ticks
# that walked codex to rung 3 in the first place.
t "no-progress rung 1 under a hold -> held (counter not spent)" \
  "defer quota-hold" \
  "$(_sup_act_plan claude no-progress 0 0 "$NOW" true 0 true 0 true)"
t "loop-stuck under a hold -> held" \
  "defer quota-hold" \
  "$(_sup_act_plan claude loop-stuck 1 $((NOW - 6*H)) "$NOW" true 0 true 0 true)"

# SCOPE. A capacity wall explains a quiet session; it does not explain a dead
# unit, a dead tmux or a dead poller — a walled seat can also be genuinely dead,
# and those causes must still reach a person.
t "poller-dead under a hold -> still acts (hold does not reach rung-4 causes)" \
  "restart" \
  "$(_sup_act_plan claude poller-dead 0 0 "$NOW" false 0 true 0 true)"
t "service-dead under a hold -> still escalates" \
  "escalate rung-4-needed" \
  "$(_sup_act_plan claude service-dead 0 0 "$NOW" false 0 true 0 true)"
t "tmux-dead under a hold -> still escalates" \
  "escalate rung-4-needed" \
  "$(_sup_act_plan claude tmux-dead 0 0 "$NOW" false 0 true 0 true)"

# Arg 10 is OPTIONAL and defaults to false: a 9-arg call is exactly the ladder
# as it shipped, and a garbage 10th arg is not a hold.
t "9-arg call is unchanged" "nudge" \
  "$(_sup_act_plan claude no-progress 0 0 "$NOW" true 0 true 0)"
t "non-'true' 10th arg is not a hold" "nudge" \
  "$(_sup_act_plan claude no-progress 0 0 "$NOW" true 0 true 0 yes)"

# ── the WIRING, with `db` stubbed ───────────────────────────────────────────
# The pure decision above can be complete and still reach nobody if the two
# queries that feed it do not compose (a-control-can-be-authorization-complete-
# and-unreachable). So `db` is stubbed to answer the two SELECTs the way sqlite
# would and _sup_quota_hold is driven end to end — episode row -> signature ->
# last alert -> verdict — with no sqlite, no root and no live store.
_STUB_EP_TS=""; _STUB_EP_SIG=""; _STUB_LAST=""
db() {
  case "$1" in
    *"event='alert'"*"ORDER BY id DESC"*)
      # The class is matched, not ignored: a hold that read the wrong
      # classification would otherwise pass every arm below (measured — that
      # exact mutation survived the first draft of this stub).
      [[ "$1" == *"classification='quota-exhausted'"* ]] || return 0
      [[ -n "$_STUB_EP_TS" ]] || return 0
      printf '%s\x1f%s\n' "$_STUB_EP_TS" \
        "$(jq -cn --arg s "$_STUB_EP_SIG" '{signals:{quotaSignature:$s}}')" ;;
    *"MAX(ts)"*)
      [[ "$1" == *"classification='quota-exhausted'"* ]] || return 0
      [[ "$1" == *"event='alert'"* ]] || return 0
      printf '%s\n' "$_STUB_LAST" ;;
  esac
}
sqlq() { printf "'%s'" "$1"; }

_STUB_EP_TS="$first"; _STUB_EP_SIG="$CLOCK_SIG"; _STUB_LAST="$first"
t "wired: live dated wall -> HOLD" "true" "$(_sup_quota_hold codex "$NOW")"
_STUB_LAST=$((NOW - 40*H))
t "wired: episode last seen past the gap -> PAGE" "false" "$(_sup_quota_hold codex "$NOW")"
_STUB_EP_TS=""; _STUB_EP_SIG=""; _STUB_LAST=""
t "wired: seat with no quota episode at all -> PAGE" "false" "$(_sup_quota_hold devnull "$NOW")"

echo "supervisor quota-hold unit: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
