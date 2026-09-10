#!/usr/bin/env bash
# DIVE-4171 — a codex seat's usage-limit wall, end to end through the two
# instruments that have to agree about it.
#
# THE ROW, measured on the codex seat 2026-09-09 (/var/log/5dive-heartbeat.log +
# pane): the seat hit `Codex could not complete this turn: You've hit your usage
# limit. Upgrade to Pro`, and because nothing classified that as a wall the 45m
# reaper took DIVE-4119 at 11:20 ("overran 45m budget (reap #1)"), re-nudged the
# seat into the same wall at 11:30, and at 12:21 filed the human gate:
# "overran 45m 2x — blocked + escalated". Nothing had been lost. DIVE-4161 took
# the same shape 14 minutes later.
#
# Grades three things, all pure or db-only — no tmux, no network, no root:
#   1  the SUPERVISOR reads the codex wording (regression pin on the DIVE-4206
#      widening this row depends on) and reports deadline `unknown`, which is the
#      input `_hb_quota_park_until_seat` turns into the 6h fallback park;
#   2  the HEARTBEAT's pane matcher reads the same line (DIVE-4171's fix) --
#      with the two-signature discipline still intact, and the wall CLASSIFIER
#      abstaining (`undetermined`) because codex names no reset time;
#   3  `_hb_reclaim` rule (c): a row 100m into a 45m budget on a quota-parked
#      seat is HELD -- not reaped, not blocked, no `cmd_task_escalate` -- and the
#      identical row on an UNPARKED seat still blocks + escalates (the control
#      that keeps arm 3 from passing vacuously), and the park EXPIRING hands the
#      row back to the ordinary rule.
#
# Same isolation contract as tests/heartbeat_reclaim_loop_unit.sh.
# Run: bash tests/heartbeat_codex_wall_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-codex-wall.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_supervisor.sh cmd_heartbeat.sh; do
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

# THE LITERAL PANE LINE from the 2026-09-09 codex pane. Every arm below reads
# this one string; a future copy change fails here rather than in six places.
CODEX_WALL="Codex could not complete this turn: You've hit your usage limit. Upgrade to Pro"

# ── 1. the supervisor half ───────────────────────────────────────────────────
# Pinned, not authored, by this row: DIVE-4206 widened `_SUP_QUOTA_PAT` to
# `hit your (…|usage|…) limit` for the Claude Code session banner and picked the
# codex wording up with it. That is load-bearing for arm 3 — no
# `quota-exhausted` classification, no park — so it gets a regression pin here
# instead of being assumed.
M=$(printf '%s\n' "$CODEX_WALL" | _sup_quota_match 1757500000)
[[ "$M" == "$CODEX_WALL" ]] \
  && ok_t "supervisor matches the codex wall line (DIVE-4206 pin)" \
  || bad_t "supervisor missed the codex wall line" "got '$M'"

# codex names NO resume time, so the deadline parser must abstain rather than
# invent one. `unknown` is the input that sends the park to the 6h fallback cap
# (_HB_QUOTA_PARK_FALLBACK_SEC) rather than to a deadline+tick park.
D=$(_sup_quota_deadline "$CODEX_WALL" 1757500000 | tr '\037' '/')
[[ "$D" == unknown/* ]] \
  && ok_t "deadline on the codex wall is 'unknown' (park falls to the 6h cap)" \
  || bad_t "deadline on the codex wall was not 'unknown'" "got '$D'"

# ── 2. the heartbeat half — the matcher this row fixes ───────────────────────
if _hb_pane_is_usage_limit "$CODEX_WALL"; then
  ok_t "heartbeat pane matcher reads the codex wall (DIVE-4171 fix)"
else
  bad_t "heartbeat pane matcher still blind to the codex wall" "line: $CODEX_WALL"
fi

# NON-VACUITY OF THE WIDENING, both halves. The fix added ONE action phrasing;
# it must not have collapsed the two-signature discipline that stops ordinary
# output mentioning a limit from false-matching.
if _hb_pane_is_usage_limit "You've hit your usage limit."; then
  bad_t "header alone must NOT match (two-signature discipline)" "matched a bare header"
else
  ok_t "header alone still does not match — two signatures still required"
fi
if _hb_pane_is_usage_limit "Upgrade to Pro for more capacity"; then
  bad_t "action line alone must NOT match" "matched a bare action line"
else
  ok_t "action line alone still does not match"
fi

# The wall CLASSIFIER abstains on codex: the header is not a spend cap and the
# pane carries no reset time, so neither discriminator holds. `undetermined` is
# the correct third state (DIVE-3778's rule) — folding it into `rate-limit`
# would license a press-continue into a wall that names no resume.
W=$(_hb_wall_class "$CODEX_WALL")
[[ "$W" == "undetermined" ]] \
  && ok_t "wall class on the codex wall is 'undetermined', not a guessed retry" \
  || bad_t "wall class on the codex wall" "expected undetermined, got '$W'"

# ── 3. rule (c): a walled seat must never manufacture a human gate ───────────
# Boundaries: no tmux, no registry file, no real escalation.
REGISTRY="$TMP/registry.json"; printf '{"agents":{}}' >"$REGISTRY"
registry_read()      { cat "$REGISTRY"; }
registry_write()     { cat > "$REGISTRY"; }
_hb_pane_fingerprint() { echo "fp"; }
cmd_send()           { :; }
with_registry_lock() { local fn="$1"; shift; "$fn" "$@"; }
_hb_claude_started() { echo ""; }    # rule (a) never fires
_hb_agent_idle()     { return 1; }   # NOT a confident idle reading -> rule (b) is out of scope
# Spies: the two side effects the 2026-09-09 incident produced.
# FILE spies, not variables: the reclaimer calls `( cmd_task_escalate … )` in a
# SUBSHELL on purpose (a fail->exit there would otherwise kill the whole tick),
# so an assignment made inside it never reaches this shell. A variable spy here
# reads empty on a real escalation and every control below passes vacuously —
# which is exactly what the first cut of this harness did.
ESC_LOG="$TMP/escalated"; SEND_LOG="$TMP/sent"
cmd_task_escalate()  { printf '%s\n' "$1" >>"$ESC_LOG"; }
_hb_send_line()      { printf '%s\n' "$2" >>"$SEND_LOG"; return 0; }
spies_reset() { : >"$ESC_LOG"; : >"$SEND_LOG"; }
escalated()   { [[ -s "$ESC_LOG" ]]; }
sent()        { [[ -s "$SEND_LOG" ]]; }

addt() { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
row()  { db "SELECT status||'|'||COALESCE(reap_escalated_n,0) FROM tasks WHERE id=$1;"; }
reset_all() { db "DELETE FROM tasks; DELETE FROM supervisor_events;"; }

# One supervisor observation, shaped like the real column: classification in its
# own column, deadline under signals.signals.quotaDeadline.
sup_obs() {
  local agent="$1" cls="$2" ago="$3" deadline="${4:-unknown}"
  db "INSERT INTO supervisor_events (ts, agent, event, classification, cause, signals)
      VALUES (datetime('now','-${ago}'), $(sqlq "$agent"), 'observe', $(sqlq "$cls"), $(sqlq "$cls"),
              '{\"signals\":{\"quotaDeadline\":\"${deadline}\"}}');"
}
# A claimed row whose claim is <mins> old — the 45m-budget overrun, seeded
# directly so the arm does not depend on wall-clock during the run.
# The re-nudge that happens between two reaps on the real board: the reclaimed
# row is re-dispatched to the same seat and immediately overruns again (the wall
# is still up). Without this the second `_hb_reclaim` sees a `todo` row and does
# nothing, and the control below would pass for the wrong reason.
renudge() {
  local who="$1" id="$2" mins="$3"
  _hb_claim_task "$who" "$id" >/dev/null 2>&1
  db "UPDATE tasks SET started_at=datetime('now','-${mins} minutes') WHERE id=${id};"
}
mk_overrun() {
  local who="$1" mins="$2" id
  id=$(addt --assignee="$who" -- "a codex-lane row")
  _hb_claim_task "$who" "$id" >/dev/null 2>&1
  db "UPDATE tasks SET started_at=datetime('now','-${mins} minutes') WHERE id=${id};"
  printf '%s' "$id"
}

# 3a) THE INCIDENT. everyMin=15 -> a 45m budget; the row is 100m in.
reset_all; spies_reset
sup_obs codex quota-exhausted "30 minutes" unknown
T=$(mk_overrun codex 100)
_hb_reclaim codex 15 >/dev/null 2>&1
renudge codex "$T" 100
_hb_reclaim codex 15 >/dev/null 2>&1   # second pass: the reap that escalated on 09-09
if [[ "$(row "$T")" == "in_progress|0" ]] && ! escalated; then
  ok_t "walled seat, 100m overrun, two passes: claim HELD — not blocked, not escalated"
else
  bad_t "a walled seat still manufactured a human gate" "row=$(row "$T") escalated='$(tr '\n' ' ' <"$ESC_LOG")'"
fi
! sent \
  && ok_t "no '/goal clear' nudged into the wall (the codex thread is not grown)" \
  || bad_t "a line was sent into the wall" "sent='$(tr '\n' ' ' <"$SEND_LOG")'"

# 3b) CONTROL — the SAME row, same age, same passes, with NO quota observation.
# This is the pre-fix behaviour and it must be untouched: an unexplained 100m
# overrun is still a real overrun and still reaches the human.
reset_all; spies_reset
T=$(mk_overrun codex 100)
_hb_reclaim codex 15 >/dev/null 2>&1
renudge codex "$T" 100
_hb_reclaim codex 15 >/dev/null 2>&1
if [[ "$(row "$T")" == blocked\|* ]] && escalated; then
  ok_t "[control] unwalled seat, same overrun: still blocked + escalated (fix is not a blanket amnesty)"
else
  bad_t "control: an unexplained overrun stopped escalating" "row=$(row "$T") escalated='$(tr '\n' ' ' <"$ESC_LOG")'"
fi

# 3c) CONTROL — a seat classified `stalled`, which is what a walled codex seat
# read as BEFORE arm 1's pattern matched. Only `quota-exhausted` parks.
reset_all; spies_reset
sup_obs codex stalled "30 minutes" unknown
T=$(mk_overrun codex 100)
_hb_reclaim codex 15 >/dev/null 2>&1
renudge codex "$T" 100
_hb_reclaim codex 15 >/dev/null 2>&1
{ [[ "$(row "$T")" == blocked\|* ]] && escalated; } \
  && ok_t "[control] a 'stalled' classification does NOT park — only quota-exhausted does" \
  || bad_t "a non-quota classification parked the claim" "row=$(row "$T") escalated='$(tr '\n' ' ' <"$ESC_LOG")'"

# 3d) THE HOLD IS BOUNDED. An observation older than the 6h fallback cap means
# the park has expired, and the ordinary rule owns the row again. This is what
# stops the hold being the wedge DIVE-4104's own comment calls worse than churn.
reset_all; spies_reset
sup_obs codex quota-exhausted "7 hours" unknown
T=$(mk_overrun codex 100)
_hb_reclaim codex 15 >/dev/null 2>&1
renudge codex "$T" 100
_hb_reclaim codex 15 >/dev/null 2>&1
{ [[ "$(row "$T")" == blocked\|* ]] && escalated; } \
  && ok_t "an EXPIRED park (obs 7h old > 6h cap) releases the row to the ordinary rule" \
  || bad_t "the park outlived its 6h cap" "row=$(row "$T") escalated='$(tr '\n' ' ' <"$ESC_LOG")'"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
