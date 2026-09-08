#!/usr/bin/env bash
# DIVE-4097 isolated unit harness for DOOR 2 — the P2 act ladder's capacity hold.
#
# The row: the stuck-detector paged a human 🚨 for a seat that was throttled on a
# usage limit and self-healing ("Agent codex is stuck and needs a person —
# no-progress (rotation-disabled)"). DIVE-4052 / PR #798 closed door 1 (the
# quota-exhausted ALERT leg) and left this one open, because that string is
# classified no-progress, not quota-exhausted, so the per-class flag never sees it.
#
# Grades three things:
#   1. _sup_ladder_quota_hold  — the pure decision (cause scope, the pane's lapsed
#      release, the audit window, and every not-a-number/absent input falling to
#      false so the hold is NEVER quieter than the code without it).
#   2. _sup_act_plan's optional 10th argument — the hold defers BEFORE the rungs
#      (so the attempt counter is not spent) and cannot reach the dead-signal
#      causes; every 9-arg caller keeps its exact previous meaning.
#   3. _sup_ladder_quota_age — the db half, against a seeded audit trail.
#
# Same isolation contract as supervisor_unit.sh: sources src/ directly and points
# STATE_DIR at a throwaway temp dir, so it NEVER touches the live shared tasks.db.
# Run: bash tests/supervisor_quota_hold_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NOTE the absence of 2>/dev/null —
# the helper's stderr line IS the payload (see supervisor_unit.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d "${TMPDIR:-/tmp}/supervisor-quota-hold.XXXXXX")"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
# shellcheck source=/dev/null
source "$SRC/cmd_supervisor.sh"
tasks_db_init

PASS=0; FAIL=0
t() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"
  fi
}

WIN=$(( _SUP_ALERT_WINDOW_H * 3600 ))
FRESH=3600

# ── 1. _sup_ladder_quota_hold — cause scope ────────────────────────────────
# Only the two causes a capacity wall actually EXPLAINS may be held.
t "no-progress with a fresh quota row holds" \
  "true"  "$(_sup_ladder_quota_hold no-progress "" $FRESH)"
t "loop-stuck with a fresh quota row holds" \
  "true"  "$(_sup_ladder_quota_hold loop-stuck "" $FRESH)"
# A walled seat can ALSO be genuinely dead, and a down unit is the more specific
# reading — trading a false page for a missed outage is not the trade this row makes.
t "service-dead is NEVER held" \
  "false" "$(_sup_ladder_quota_hold service-dead "" $FRESH)"
t "tmux-dead is NEVER held" \
  "false" "$(_sup_ladder_quota_hold tmux-dead "" $FRESH)"
t "poller-dead is NEVER held" \
  "false" "$(_sup_ladder_quota_hold poller-dead "" $FRESH)"
t "stale-cli is NEVER held" \
  "false" "$(_sup_ladder_quota_hold stale-cli "" $FRESH)"
t "goal-drift is NEVER held" \
  "false" "$(_sup_ladder_quota_hold goal-drift "" $FRESH)"
t "an empty cause is NEVER held" \
  "false" "$(_sup_ladder_quota_hold "" "" $FRESH)"

# ── 2. the pane's LAPSED release ───────────────────────────────────────────
# This is the arm that stops the hold going quiet forever: _sup_quota_deadline
# (which survives #798) saying the refusal on screen has EXPIRED is a positive
# statement that the seat resumed. Still not progressing => genuinely stuck.
t "a LAPSED pane refusal releases the hold however fresh the audit row" \
  "false" "$(_sup_ladder_quota_hold no-progress lapsed $FRESH)"
t "a LAPSED pane refusal releases it at age 0 too" \
  "false" "$(_sup_ladder_quota_hold no-progress lapsed 0)"
# live/unknown cannot reach door 2 (_sup_classify routes both to quota-exhausted),
# but if they ever did they must not be QUIETER-breaking: they hold.
t "a live pane refusal holds" \
  "true"  "$(_sup_ladder_quota_hold no-progress live $FRESH)"
t "an unknown-deadline pane refusal holds" \
  "true"  "$(_sup_ladder_quota_hold no-progress unknown $FRESH)"

# ── 3. the audit window is the oracle AND the expiry ───────────────────────
# Door 1 re-files a quota-exhausted row every _SUP_ALERT_WINDOW_H for as long as
# the wall is up (#798's own words). Outside that window the wall stopped being
# re-attested, so the hold lapses with no second threshold laid on top.
t "a row exactly at the window boundary still holds" \
  "true"  "$(_sup_ladder_quota_hold no-progress "" $WIN)"
t "a row one second past the window releases" \
  "false" "$(_sup_ladder_quota_hold no-progress "" $(( WIN + 1 )))"
t "a row a full day past the window releases" \
  "false" "$(_sup_ladder_quota_hold no-progress "" $(( WIN + 86400 )))"
t "age 0 (a row written this tick) holds" \
  "true"  "$(_sup_ladder_quota_hold no-progress "" 0)"

# ── 4. absence is not a hold — every unreadable input falls to false ───────
# The hold must never be quieter than the code without it, so a missing or
# unparseable oracle pages exactly as it did before this change.
t "no quota row at all releases" \
  "false" "$(_sup_ladder_quota_hold no-progress "" "")"
t "a non-numeric age releases" \
  "false" "$(_sup_ladder_quota_hold no-progress "" abc)"
t "a NULL-ish age releases" \
  "false" "$(_sup_ladder_quota_hold no-progress "" NULL)"
# A row dated in the FUTURE (clock skew between writer and reader) is not
# evidence of a live wall — it is a broken reading, and a broken reading pages.
t "a negative age (row in the future) releases" \
  "false" "$(_sup_ladder_quota_hold no-progress "" -60)"
t "a fractional age releases" \
  "false" "$(_sup_ladder_quota_hold no-progress "" 3600.5)"
t "a missing third argument releases" \
  "false" "$(_sup_ladder_quota_hold no-progress "")"
t "a missing second AND third argument releases" \
  "false" "$(_sup_ladder_quota_hold no-progress)"

# ── 5. _sup_act_plan arg 10 — THE ROW'S OWN PAGE, suppressed ───────────────
NOW=1000000
# This is the exact string that opened DIVE-4097. attempts=2 + rotation disabled
# is rung 3, and rung 3 is a courier-delivered page to a human.
t "THE ROW: rung 3 on a walled seat defers instead of paging" \
  "defer quota-hold" "$(_sup_act_plan claude no-progress 2 0 $NOW false 0 true 0 true)"
# CONTROL, and it is the one that proves the arm above is not vacuous: the same
# call with the hold off still pages.
t "CONTROL: the same seat with no hold still escalates rotation-disabled" \
  "escalate rotation-disabled" "$(_sup_act_plan claude no-progress 2 0 $NOW false 0 true 0 false)"
t "rung 0 (nudge) is held too — the hold is before the rungs, not after" \
  "defer quota-hold" "$(_sup_act_plan claude no-progress 0 0 $NOW false 0 true 0 true)"
t "rung 1 (resume) on loop-stuck is held" \
  "defer quota-hold" "$(_sup_act_plan grok loop-stuck 1 0 $NOW false 0 true 0 true)"
t "rung 2 (rotate) is held even with rotation ENABLED" \
  "defer quota-hold" "$(_sup_act_plan claude no-progress 2 0 $NOW true 0 true 0 true)"
t "an exhausted ladder is held rather than escalating" \
  "defer quota-hold" "$(_sup_act_plan claude no-progress 3 0 $NOW true 0 true 0 true)"
t "the hold beats the backoff deferral (same verb family, its own reason)" \
  "defer quota-hold" "$(_sup_act_plan claude no-progress 1 $NOW $NOW false 0 true 0 true)"

# ── 6. arg 10 cannot reach the dead-signal causes ──────────────────────────
t "poller-dead still restarts under a hold" \
  "restart" "$(_sup_act_plan claude poller-dead 0 0 $NOW false 0 true 0 true)"
t "service-dead still escalates under a hold" \
  "escalate rung-4-needed" "$(_sup_act_plan claude service-dead 0 0 $NOW false 0 true 0 true)"
t "tmux-dead still escalates under a hold" \
  "escalate rung-4-needed" "$(_sup_act_plan grok tmux-dead 0 0 $NOW true 0 true 0 true)"
t "poller-dead's rate-limit refusal still escalates under a hold" \
  "escalate restart-rate-limited" \
  "$(_sup_act_plan claude poller-dead 0 0 $NOW false $_SUP_RESTART_MAX true $_SUP_RESTART_MAX true)"
t "stale-cli keeps its own deferral reason under a hold" \
  "defer update-pending" "$(_sup_act_plan claude stale-cli 1 0 $NOW true 0 true 0 true)"
t "goal-drift keeps its own deferral reason under a hold" \
  "defer goal-drift" "$(_sup_act_plan claude goal-drift 1 0 $NOW true 0 true 0 true)"

# ── 7. arg 10 is OPTIONAL — every existing caller is unchanged ─────────────
t "6-arg caller unchanged" \
  "escalate rotation-disabled" "$(_sup_act_plan claude no-progress 2 0 $NOW false)"
t "9-arg caller unchanged" \
  "escalate rotation-disabled" "$(_sup_act_plan claude no-progress 2 0 $NOW false 0 true 0)"
t "an empty 10th arg is not a hold" \
  "escalate rotation-disabled" "$(_sup_act_plan claude no-progress 2 0 $NOW false 0 true 0 "")"
t "a non-'true' 10th arg is not a hold" \
  "escalate rotation-disabled" "$(_sup_act_plan claude no-progress 2 0 $NOW false 0 true 0 yes)"

# ── 8. _sup_ladder_quota_age — the db half ─────────────────────────────────
seed() { # <agent> <event> <classification> <hours-ago>
  db "INSERT INTO supervisor_events (agent, event, classification, cause, signals, ts)
      VALUES ($(sqlq "$1"), $(sqlq "$2"), $(sqlq "$3"), NULL, '{}',
              datetime('now', '-$4 hours'));" >/dev/null 2>&1
}
near() { # <desc> <expected-sec> <actual> — 60s tolerance, this reads a real clock
  local d="$1" e="$2" a="$3"
  if [[ "$a" =~ ^[0-9]+$ ]] && (( a >= e - 60 && a <= e + 60 )); then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL: $d — expected ~$e, got '$a'"; fi
}

t "a seat with no events at all reads empty" "" "$(_sup_ladder_quota_age nobody)"

seed alpha alert quota-exhausted 1
near "a quota-exhausted alert 1h back reads ~3600s" 3600 "$(_sup_ladder_quota_age alpha)"

# Intervening stuck rows must not blind the oracle: once door 2 has paged once,
# the newest row overall is 'stuck', and keying on THAT would never re-arm.
seed alpha escalate stuck 0
near "a NEWER stuck row does not hide the quota row" 3600 "$(_sup_ladder_quota_age alpha)"

# Only 'stuck' rows -> no attestation of a wall -> no hold.
seed bravo escalate stuck 1
t "a seat with only stuck rows reads empty" "" "$(_sup_ladder_quota_age bravo)"

# DIVE-3822's profile-flip row is an ACTION, not an alert, and it is equally the
# tick stating it found this seat behind a capacity wall.
seed charlie action quota-exhausted 2
near "a quota-exhausted ACTION row counts" 7200 "$(_sup_ladder_quota_age charlie)"

# Newest wins when a seat has several.
seed charlie alert quota-exhausted 5
near "the NEWEST quota row wins, not the oldest" 7200 "$(_sup_ladder_quota_age charlie)"

# Per-agent scoping: a fleet-wide wall must not hold a seat that never walled.
t "another seat's quota row does not leak" "" "$(_sup_ladder_quota_age delta)"

# ── 9. composed: the trail -> the hold -> the plan, end to end ─────────────
# This is DIVE-4097's incident driven through the real db half.
seed codex alert quota-exhausted 1
CODEX_AGE=$(_sup_ladder_quota_age codex)
CODEX_HOLD=$(_sup_ladder_quota_hold no-progress "" "$CODEX_AGE")
t "composed: codex walled 1h ago holds" "true" "$CODEX_HOLD"
t "composed: and rung 3 defers instead of paging lodar" \
  "defer quota-hold" "$(_sup_act_plan claude no-progress 2 0 $NOW false 0 true 0 "$CODEX_HOLD")"

# The release, composed the same way: a seat whose wall stopped being re-attested
# a day and a half ago is no longer covered, and the ladder resumes.
seed echo0 alert quota-exhausted $(( _SUP_ALERT_WINDOW_H + 12 ))
ECHO_AGE=$(_sup_ladder_quota_age echo0)
ECHO_HOLD=$(_sup_ladder_quota_hold no-progress "" "$ECHO_AGE")
t "composed: a stale wall releases the hold" "false" "$ECHO_HOLD"
t "composed: and the ladder pages again" \
  "escalate rotation-disabled" \
  "$(_sup_act_plan claude no-progress 2 0 $NOW false 0 true 0 "$ECHO_HOLD")"

# And the pane's lapsed release, composed: fresh trail, but the screen says the
# refusal it is showing expired -> the seat resumed and is still not progressing.
FOX_HOLD=$(_sup_ladder_quota_hold no-progress lapsed "$CODEX_AGE")
t "composed: a fresh trail + a LAPSED pane still pages" "false" "$FOX_HOLD"
t "composed: and that is a real page, not a deferral" \
  "escalate rotation-disabled" \
  "$(_sup_act_plan claude no-progress 2 0 $NOW false 0 true 0 "$FOX_HOLD")"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
