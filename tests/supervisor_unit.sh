#!/usr/bin/env bash
# DIVE-857 isolated unit harness for the supervisor P2 act layer.
#
# Same isolation contract as loop_*_unit.sh: sources src/ libs directly and
# points STATE_DIR at a throwaway temp dir so it NEVER touches the live shared
# tasks.db. Asserts: _sup_act_plan's full decision matrix (cause map, all-runtime
# coverage (OSS-23), ladder order, backoff math, exhaustion, rotation gate) and
# _sup_act_history counting action rows from a seeded audit trail.
# Run: bash tests/supervisor_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/supervisor-unit.XXXXXX)"

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
# Source the supervisor AFTER STATE_DIR is final so its flag paths land in TMP.
# shellcheck source=/dev/null
source "$SRC/cmd_supervisor.sh"
tasks_db_init

PASS=0; FAIL=0
t() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"
  fi
}

NOW=1000000

# --- decision matrix: cause map -------------------------------------------
t "service-dead escalates (rung 4 is P3)" \
  "escalate rung-4-needed" "$(_sup_act_plan claude service-dead 0 0 $NOW false)"
t "tmux-dead escalates" \
  "escalate rung-4-needed" "$(_sup_act_plan claude tmux-dead 0 0 $NOW true)"
# DIVE-974: stale-cli is update-pending (not stuck) so it never reaches the act
# loop; the plan guards it too, so no rung — not even escalate — can ever fire.
t "stale-cli defers (update-pending, never a ladder action)" \
  "defer update-pending" "$(_sup_act_plan claude stale-cli 1 0 $NOW true)"

# --- runtime coverage (OSS-23: self-heal every runtime) --------------------
# The ladder is runtime-agnostic — every non-claude runtime gets the SAME
# nudge/resume/rotate as claude on an actionable (session-alive-but-wedged) cause.
t "codex no-progress -> nudge (rung 0, was escalate)" \
  "nudge" "$(_sup_act_plan codex no-progress 0 0 $NOW false)"
t "grok loop-stuck attempt 1 -> resume" \
  "resume" "$(_sup_act_plan grok loop-stuck 1 0 $NOW false)"
t "opencode attempt 2 + rotation on -> rotate" \
  "rotate" "$(_sup_act_plan opencode no-progress 2 0 $NOW true)"
t "antigravity attempt 2 + rotation off -> escalate (rotation gate, not runtime)" \
  "escalate rotation-disabled" "$(_sup_act_plan antigravity no-progress 2 0 $NOW false)"
# rung-4+ causes still escalate for EVERY runtime (restart is P3) — the axis that
# stayed narrow. A dead service/tmux/poller is not something a nudge can fix.
t "codex service-dead still escalates (rung 4 is P3, all runtimes)" \
  "escalate rung-4-needed" "$(_sup_act_plan codex service-dead 0 0 $NOW false)"
t "grok tmux-dead still escalates" \
  "escalate rung-4-needed" "$(_sup_act_plan grok tmux-dead 0 0 $NOW true)"

# --- ladder order -----------------------------------------------------------
t "attempt 0 -> nudge"  "nudge"  "$(_sup_act_plan claude no-progress 0 0 $NOW false)"
t "attempt 1 -> resume" "resume" "$(_sup_act_plan claude loop-stuck 1 0 $NOW false)"
t "attempt 2 + rotation on -> rotate" \
  "rotate" "$(_sup_act_plan claude no-progress 2 0 $NOW true)"
t "attempt 2 + rotation off -> escalate" \
  "escalate rotation-disabled" "$(_sup_act_plan claude no-progress 2 0 $NOW false)"
t "attempts >= max -> escalate exhausted" \
  "escalate ladder-exhausted" "$(_sup_act_plan claude no-progress 3 0 $NOW true)"

# --- backoff math: gap = base * 2^attempts ---------------------------------
# base 20m: attempt 1 needs 40m since last action.
LAST=$(( NOW - 30 * 60 ))   # 30m ago < 40m gap
t "attempt 1 inside 40m backoff -> defer" \
  "defer backoff" "$(_sup_act_plan claude no-progress 1 $LAST $NOW false)"
LAST=$(( NOW - 41 * 60 ))   # 41m ago > 40m gap
t "attempt 1 past 40m backoff -> resume" \
  "resume" "$(_sup_act_plan claude no-progress 1 $LAST $NOW false)"
LAST=$(( NOW - 21 * 60 ))   # attempt 0 gap is 20m; also no last action means no gap
t "attempt 0 past 20m backoff -> nudge" \
  "nudge" "$(_sup_act_plan claude no-progress 0 $LAST $NOW false)"
t "no prior action -> no backoff gate" \
  "nudge" "$(_sup_act_plan claude no-progress 0 0 $NOW false)"

# --- _sup_act_history: counts only 'action' rows inside the window ---------
db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
    VALUES ('unit-a', 'action', 'stuck', 'no-progress', '{\"rung\":\"nudge\"}');"
db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
    VALUES ('unit-a', 'planned', 'stuck', 'no-progress', '{\"rung\":\"resume\"}');"
db "INSERT INTO supervisor_events (agent, event, classification, cause)
    VALUES ('unit-a', 'observe', 'stuck', 'no-progress');"
db "INSERT INTO supervisor_events (agent, event, classification, cause, signals, ts)
    VALUES ('unit-a', 'action', 'stuck', 'no-progress', '{\"rung\":\"resume\"}', datetime('now', '-9 hours'));"
db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
    VALUES ('unit-b', 'action', 'stuck', 'loop-stuck', '{\"rung\":\"nudge\"}');"
read -r ATT LASTE <<<"$(_sup_act_history unit-a)"
t "history counts in-window action rows only (not planned/observe/old/other-agent)" "1" "$ATT"
[[ "$LASTE" =~ ^[0-9]+$ ]] && (( LASTE > 0 )) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: history lastEpoch not a positive epoch: '$LASTE'"; }
read -r ATT _ <<<"$(_sup_act_history unit-none)"
t "history for unseen agent is zero" "0" "$ATT"

# --- DIVE-3753: rung 4 — poller-dead restart, and its rate limiter ---------
#
# BOTH STATES, deliberately. A limiter exercised only in its refusing state is
# indistinguishable from one that refuses always — and a refuse-always limiter
# reproduces exactly the outage this rung exists to end (a correct poller-dead
# detection that produces no action). So: it must ALLOW the first restart and
# REFUSE the second inside the window, and each half must fail on its own.
t "poller-dead with budget free -> restart (rung 4, not escalate)" \
  "restart" "$(_sup_act_plan claude poller-dead 0 0 $NOW false 0)"
t "poller-dead with budget SPENT -> escalate, naming the limiter" \
  "escalate restart-rate-limited" "$(_sup_act_plan claude poller-dead 0 0 $NOW false 1)"
t "poller-dead over budget still escalates (>= not ==)" \
  "escalate restart-rate-limited" "$(_sup_act_plan claude poller-dead 0 0 $NOW false 7)"

# Runtime-agnostic, like every other rung (OSS-23): a seat is a systemd unit
# whatever runtime it hosts, so restart must not be claude-only.
t "poller-dead restarts a codex seat too" \
  "restart" "$(_sup_act_plan codex poller-dead 0 0 $NOW false 0)"
t "poller-dead restarts an opencode seat too" \
  "restart" "$(_sup_act_plan opencode poller-dead 0 0 $NOW true 0)"

# The rung is CAUSE-indexed: a seat that already burned attempts on the 1-3
# ladder for some other cause must still get its restart, and rotation state
# must not gate it. Both were live ways to make the rung unreachable.
t "poller-dead ignores the 1-3 attempt count" \
  "restart" "$(_sup_act_plan claude poller-dead 3 0 $NOW false 0)"
t "poller-dead ignores the ladder backoff gap" \
  "restart" "$(_sup_act_plan claude poller-dead 1 $((NOW - 5)) $NOW false 0)"

# Blast radius: rung 4 is for poller-dead ONLY. Every other rung-4+ cause must
# still escalate — a restart verb that leaked onto service-dead/tmux-dead would
# turn one added remedy into a fleet-wide restart authority.
t "service-dead does NOT get the restart rung" \
  "escalate rung-4-needed" "$(_sup_act_plan claude service-dead 0 0 $NOW false 0)"
t "tmux-dead does NOT get the restart rung" \
  "escalate rung-4-needed" "$(_sup_act_plan claude tmux-dead 0 0 $NOW false 0)"

# Back-compat: the 7th arg is optional and its absence means "nothing spent".
# Every pre-DIVE-3753 6-arg caller in this file relies on that.
t "6-arg call (no restart count) defaults to budget free" \
  "restart" "$(_sup_act_plan claude poller-dead 0 0 $NOW false)"
t "non-numeric restart count is treated as 0, not as unlimited-spent" \
  "restart" "$(_sup_act_plan claude poller-dead 0 0 $NOW false "")"

# The DORMANT ladder must NOT lose the human path. Before this row, poller-dead
# escalated — and an escalation is courier-delivered to a person (DIVE-3727).
# Every other rung degrades to a silent 'planned' row while actions are off; if
# poller-dead did the same, this change would REMOVE the only thing serving the
# cause and give back nothing until the flag is set.
t "dormant ladder still escalates poller-dead (the pre-3753 human path)" \
  "escalate rung-4-dormant" "$(_sup_act_plan claude poller-dead 0 0 $NOW false 0 false)"
t "dormant beats the limiter: budget spent still escalates, not silently" \
  "escalate rung-4-dormant" "$(_sup_act_plan claude poller-dead 0 0 $NOW false 9 false)"
t "armed ladder (explicit true) restarts" \
  "restart" "$(_sup_act_plan claude poller-dead 0 0 $NOW false 0 true)"
t "8th arg defaults to armed, so 7-arg callers are unchanged" \
  "restart" "$(_sup_act_plan claude poller-dead 0 0 $NOW false 0)"
# Dormancy is poller-dead's business only — it must not leak onto the 1-3 ladder,
# whose dormant handling is the dispatch's 'planned' row, not a plan-layer verb.
t "dormancy does not change the 1-3 ladder's verb" \
  "nudge" "$(_sup_act_plan claude no-progress 0 0 $NOW false 0 false)"

# --- DIVE-3753: _sup_restart_history — the limiter's numerator --------------
t "restart history for an untouched seat is 0" "0" "$(_sup_restart_history unit-r)"
db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
    VALUES ('unit-r', 'action', 'stuck', 'poller-dead', '{\"rung\":\"restart\",\"attempt\":1,\"result\":\"ok\"}');"
t "an executed restart counts against the budget" "1" "$(_sup_restart_history unit-r)"
# DIVE-3915: that row's `result` is "ok" — DIVE-3856's probe SAW the poller come
# back — so it is a HEALED restart. It still counts toward the flap bound (the
# total above) and it no longer counts toward the ceiling that means "restarting
# does not fix this seat". Before this change the two were the same number, and a
# recovery that worked spent the allowance for the next, unrelated episode: that
# is exactly how `main` sat deaf for 8 minutes on 2026-09-03 behind a cure that
# took 2.4 seconds.
t "3915: a HEALED restart does not count against the unhealed ceiling" "0" \
  "$(_sup_restart_unhealed_history unit-r)"
t "3915: so the seat is still allowed the restart its next episode needs" \
  "restart" \
  "$(_sup_act_plan claude poller-dead 0 0 $NOW false "$(_sup_restart_unhealed_history unit-r)" true "$(_sup_restart_history unit-r)")"
# ...and the pair that proves the limiter is still wired to the trail: an
# UNHEALED restart (DIVE-3856 probed and the poller was still dead) flips it.
db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
    VALUES ('unit-rd', 'action', 'stuck', 'poller-dead', '{\"rung\":\"restart\",\"attempt\":1,\"result\":\"restart-ran-poller-still-dead\"}');"
t "3915: a restart that left the poller dead DOES count as unhealed" "1" \
  "$(_sup_restart_unhealed_history unit-rd)"
t "seat with an UNHEALED restart on the trail escalates" \
  "escalate restart-rate-limited" \
  "$(_sup_act_plan claude poller-dead 0 0 $NOW false "$(_sup_restart_unhealed_history unit-rd)" true "$(_sup_restart_history unit-rd)")"
# The unprobeable-type outcome. `opencode` is absent from the verify predicate on
# purpose, so EVERY restart of such a seat records `unverified` — and it must
# count as unhealed, or this whole change would widen the ceiling precisely where
# there is no probe to justify widening it.
db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
    VALUES ('unit-ru', 'action', 'stuck', 'poller-dead', '{\"rung\":\"restart\",\"attempt\":1,\"result\":\"restart-ran-poller-unverified\"}');"
t "3915: an UNVERIFIED restart counts as unhealed (no probe, no widening)" "1" \
  "$(_sup_restart_unhealed_history unit-ru)"
t "3915: and an unprobeable seat's ceiling behaves exactly as it did before" \
  "escalate restart-rate-limited" \
  "$(_sup_act_plan claude poller-dead 0 0 $NOW false "$(_sup_restart_unhealed_history unit-ru)" true "$(_sup_restart_history unit-ru)")"
# A restart where cmd_restart itself returned non-zero never reaches the probe;
# `res` is "failed" and that is unhealed too.
db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
    VALUES ('unit-rf', 'action', 'stuck', 'poller-dead', '{\"rung\":\"restart\",\"attempt\":1,\"result\":\"failed\"}');"
t "3915: a restart whose verb failed counts as unhealed" "1" \
  "$(_sup_restart_unhealed_history unit-rf)"
# THE FLAP BOUND. Three healed restarts in the window: nothing is unhealed, so
# the ceiling above never fires — and without a second bound this seat would
# restart forever and never reach a person. It escalates under its own reason,
# because "the remedy keeps being needed" is a different sentence to a human than
# "the remedy keeps failing".
for _i in 1 2 3; do
  db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
      VALUES ('unit-flap', 'action', 'stuck', 'poller-dead', '{\"rung\":\"restart\",\"attempt\":1,\"result\":\"ok\"}');"
done
t "3915 flap: three healed restarts leave the unhealed ceiling untouched" "0" \
  "$(_sup_restart_unhealed_history unit-flap)"
t "3915 flap: but they hit the total bound, and it escalates under its OWN reason" \
  "escalate restart-flapping" \
  "$(_sup_act_plan claude poller-dead 0 0 $NOW false "$(_sup_restart_unhealed_history unit-flap)" true "$(_sup_restart_history unit-flap)")"
t "3915 flap: two healed restarts are still under the bound" \
  "restart" "$(_sup_act_plan claude poller-dead 0 0 $NOW false 0 true 2)"
# The unhealed ceiling wins when BOTH are hit — it is the more specific
# statement, and the reason string a human has been reading for two months.
t "3915: unhealed takes precedence over flapping when both ceilings are hit" \
  "escalate restart-rate-limited" "$(_sup_act_plan claude poller-dead 0 0 $NOW false 1 true 9)"
# BACKWARD COMPATIBILITY OF THE SIGNATURE. Every pre-3915 caller passes 8 args
# or fewer; $9 then defaults to $7, so total==unhealed and the unhealed refusal
# is the one that fires — the exact previous behaviour, arm by arm.
t "3915: an 8-arg caller at the ceiling behaves exactly as before" \
  "escalate restart-rate-limited" "$(_sup_act_plan claude poller-dead 0 0 $NOW false 1 true)"
t "3915: a 7-arg caller at the ceiling behaves exactly as before" \
  "escalate restart-rate-limited" "$(_sup_act_plan claude poller-dead 0 0 $NOW false 1)"
t "3915: a 6-arg caller (no restarts spent) still gets the restart" \
  "restart" "$(_sup_act_plan claude poller-dead 0 0 $NOW false)"
# A nonsensical total (below the unhealed count) is clamped up rather than
# trusted: the two numerators come from the same trail, so total < unhealed is
# impossible in production and a caller bug must not read as extra budget.
t "3915: a total below the unhealed count is clamped, not trusted" \
  "escalate restart-rate-limited" "$(_sup_act_plan claude poller-dead 0 0 $NOW false 2 true 0)"
# The dormant branch still wins over BOTH ceilings — a dormant ladder's job is
# to keep the pre-DIVE-3753 human path exactly as it was.
t "3915: dormancy still precedes both ceilings" \
  "escalate rung-4-dormant" "$(_sup_act_plan claude poller-dead 0 0 $NOW false 5 false 9)"
# And the DIVE-3856 arm this must not violate: the UNHEALED ceiling is still 1.
t "3915: the unhealed ceiling is still 1 — this change did not raise it" "1" "$_SUP_RESTART_MAX"
t "3915: the flap bound defaults to 3" "3" "$_SUP_RESTART_TOTAL_MAX"
t "3915: the window is still 6h" "6" "$_SUP_RESTART_WINDOW_H"
# The dispatch must read BOTH counters and pass them in the right slots. A grep
# is weak evidence (see the note at the foot of this file) but the miswiring it
# guards against is a pure argument-order error, which is a text property: if
# `unhealed` and `restarts` were swapped here, every healed restart would spend
# the ceiling again and this change would be a no-op that looks shipped.
_PLAN_CALL="$(grep -n 'plan=$(_sup_act_plan' "$SRC/cmd_supervisor.sh")"
t "3915 wiring: the dispatch passes unhealed as \$7 and the total as \$9" "yes" \
  "$(grep -q '"\$rot" "\$unhealed" "\$actions_on" "\$restarts"' <<<"$_PLAN_CALL" && printf yes || printf no)"

# A DORMANT tick must not spend the budget: 'planned' is a record of what the
# ladder WOULD do. If planned rows counted, flipping actions on would find every
# poller-dead seat already rate-limited and the rung would never fire once.
db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
    VALUES ('unit-p', 'planned', 'stuck', 'poller-dead', '{\"rung\":\"restart\",\"dormant\":true}');"
t "a PLANNED restart does not spend the budget" "0" "$(_sup_restart_history unit-p)"
# Out-of-window and other-seat rows are excluded, same as _sup_act_history.
db "INSERT INTO supervisor_events (agent, event, classification, cause, signals, ts)
    VALUES ('unit-w', 'action', 'stuck', 'poller-dead', '{\"rung\":\"restart\"}', datetime('now', '-9 hours'));"
t "a restart older than the window has aged out" "0" "$(_sup_restart_history unit-w)"
t "another seat's restart does not spend this seat's budget" "0" "$(_sup_restart_history unit-q)"
# Other rungs are not restarts.
db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
    VALUES ('unit-n', 'action', 'stuck', 'no-progress', '{\"rung\":\"nudge\"}');"
t "a nudge is not counted as a restart" "0" "$(_sup_restart_history unit-n)"

# --- DIVE-3753: the two counters must not contaminate each other ------------
# unit-r has ONE action row and it is a restart. If _sup_act_history counted it,
# the next no-progress on that seat would silently skip nudge and open at
# resume — an attempt-indexed ladder paced by a cause-indexed rung's traffic.
read -r RATT _ <<<"$(_sup_act_history unit-r)"
t "a restart row does not raise the 1-3 attempt count" "0" "$RATT"
t "so the seat's next no-progress still opens at nudge" \
  "nudge" "$(_sup_act_plan claude no-progress "$RATT" 0 $NOW false)"
# ...and the converse: unit-n's nudge (asserted 0 restarts above) leaves the
# restart budget free, so a poller-dead on that seat still gets its rung 4.
read -r NATT _ <<<"$(_sup_act_history unit-n)"
t "a nudge DOES raise the 1-3 attempt count (control for the arm above)" "1" "$NATT"

# --- DIVE-3753: the restart verb is dispatchable and contained --------------
# _sup_act_exec's `*)` default returns 1 for an unknown verb, so a rung the
# planner emits but the executor does not know would be recorded as an action
# that "failed" every single tick — green ladder, zero restarts. Assert the
# planner's verb is one the executor actually has a case for.
t "executor has a case for every verb the planner can emit" "yes" \
  "$(awk '/^_sup_act_exec\(\) \{/,/^\}/' "$SRC/cmd_supervisor.sh" \
     | grep -qE '^[[:space:]]*restart\)' && printf yes || printf no)"

# DIVE-3822: quota recovery must preserve the rotate command's three states.
# A no-target result is not an execution failure, but it is the branch that
# triggers the deduped human capacity alert in cmd_supervisor_tick.
ORIG_WITH_REGISTRY_LOCK=$(declare -f with_registry_lock)
ORIG_ROTATE=$(declare -f cmd_agent_rotation_rotate || true)
with_registry_lock() { "$@"; }
cmd_agent_rotation_rotate() {
  [[ "${2:-}" == "--require-live-headroom" ]] || { printf 'missing-live-headroom-flag\n'; return 0; }
  printf '%s\n' "${QUOTA_ROTATE_FIXTURE}"
}
# DIVE-3856: the fixture carries rotate's REAL envelope. _sup_quota_rotate only
# reads .ok/.data.rotated, so the new keys change nothing here — which is the
# point of pinning them: a fixture that omits what the verb now emits stops
# being evidence about the verb the moment anything downstream reads them.
QUOTA_ROTATE_FIXTURE='{"ok":true,"data":{"rotated":true,"from":"full","to":"roomy","channelBounceScheduled":true,"channelVerified":false}}'
if _sup_quota_rotate unit-q; then QR=0; else QR=$?; fi
t "quota recovery: measured target returns rotated" "0" "$QR"
QUOTA_ROTATE_FIXTURE='{"ok":true,"data":{"rotated":false,"from":"full","to":null,"reason":"no eligible account","channelBounceScheduled":false,"channelVerified":null}}'
if _sup_quota_rotate unit-q; then QR=0; else QR=$?; fi
t "quota recovery: no measured target is distinct" "1" "$QR"
QUOTA_ROTATE_FIXTURE='not-json'
if _sup_quota_rotate unit-q; then QR=0; else QR=$?; fi
t "quota recovery: malformed/failed rotate is distinct" "2" "$QR"
eval "$ORIG_WITH_REGISTRY_LOCK"
if [[ -n "$ORIG_ROTATE" ]]; then eval "$ORIG_ROTATE"; else unset -f cmd_agent_rotation_rotate; fi
# And it is subshell-wrapped: cmd_restart reaches `fail`, which EXITS. Called
# bare, one seat with a missing unit would abort the tick for every later agent.
t "the restart case is subshell-contained (a fail() cannot abort the tick)" "yes" \
  "$(awk '/^_sup_act_exec\(\) \{/,/^\}/' "$SRC/cmd_supervisor.sh" \
     | grep -A1 -E '^[[:space:]]*restart\)' | grep -qE '^\s*\( *cmd_restart ' && printf yes || printf no)"
# The tick must route it too — a verb the planner emits and the dispatch `case`
# does not list falls through to nothing: silently no action, no audit row.
t "the tick's action dispatch lists restart" "yes" \
  "$(grep -qE '^[[:space:]]*nudge\|resume\|rotate\|restart\)' "$SRC/cmd_supervisor.sh" && printf yes || printf no)"

# --- DIVE-971: goal-drift never reaches a ladder rung -----------------------
t "goal-drift defers (class=drift, never a stuck action)" \
  "defer goal-drift" "$(_sup_act_plan claude goal-drift 0 0 $NOW true)"

# --- DIVE-971: _sup_activity_epoch — per-type roots, newest matching mtime --
FH="$TMP/fakehome"
mkdir -p "$FH/.codex/sessions/2026/01/01" \
         "$FH/.grok/sessions/proj" \
         "$FH/.local/share/opencode/storage/msg" \
         "$FH/.gemini/antigravity-cli/brain/x/.system_generated/logs"
touch -d "@1700000000" "$FH/.codex/sessions/2026/01/01/rollout-old.jsonl"
touch -d "@1700000500" "$FH/.codex/sessions/2026/01/01/rollout-new.jsonl"
touch -d "@1700000900" "$FH/.codex/sessions/2026/01/01/notes.txt"  # non-match: ignored
t "codex activity = newest rollout-*.jsonl (ignores .txt)" \
  "1700000500" "$(_sup_activity_epoch codex "$FH")"
touch -d "@1700001111" "$FH/.grok/sessions/proj/prompt_context.json"
t "grok activity = newest sessions json" \
  "1700001111" "$(_sup_activity_epoch grok "$FH")"
touch -d "@1700002222" "$FH/.local/share/opencode/storage/msg/part.json"
t "opencode activity = newest storage json" \
  "1700002222" "$(_sup_activity_epoch opencode "$FH")"
touch -d "@1700003333" "$FH/.gemini/antigravity-cli/brain/x/.system_generated/logs/transcript.jsonl"
t "antigravity activity = newest transcript*.jsonl" \
  "1700003333" "$(_sup_activity_epoch antigravity "$FH")"
t "unknown type -> empty (no probe)" "" "$(_sup_activity_epoch mystery "$FH")"
t "missing root -> empty (unknown age)" "" "$(_sup_activity_epoch codex "$TMP/nope")"

# --- DIVE-971: _sup_goal_drift — structural task-id check -------------------
GH="$TMP/goalhome"; TX="$GH/.claude/projects/p"; mkdir -p "$TX"
NOW_R=$(date +%s)
OLD_TS=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S.000Z)
setline() { printf '{"type":"user","timestamp":"%s","message":{"content":"A session-scoped Stop hook is now active with condition: \\"Task DIVE-%s shows status done. run 5dive task start DIVE-%s\\""}}\n' "$OLD_TS" "$1" "$1"; }
# target task is still todo, agent active elsewhere -> drift on that id
db "INSERT INTO tasks (id, title, status, assignee, kind) VALUES (8971, 'x', 'todo', 'gdrift', 'standard');"
setline 8971 > "$TX/s.jsonl"
t "drift: active goal targets a still-todo task -> echoes id" \
  "8971" "$(_sup_goal_drift claude "$GH" gdrift "$NOW_R" "$NOW_R")"
# non-claude type -> never drift
t "drift: non-claude type -> empty" \
  "" "$(_sup_goal_drift codex "$GH" gdrift "$NOW_R" "$NOW_R")"
# stale activity (older than slow window) -> not drift (that's no-progress/idle)
t "drift: stale activity -> empty (orthogonal to drift)" \
  "" "$(_sup_goal_drift claude "$GH" gdrift "$NOW_R" "$((NOW_R - 3600))")"
# target moved to in_progress (being served) -> not drift
db "UPDATE tasks SET status='in_progress' WHERE id=8971;"
t "drift: target in_progress (served) -> empty" \
  "" "$(_sup_goal_drift claude "$GH" gdrift "$NOW_R" "$NOW_R")"
db "UPDATE tasks SET status='todo' WHERE id=8971;"
# a later /goal clear supersedes the set -> not drift
printf '{"type":"user","message":{"content":"<command-name>/goal</command-name><command-args>clear</command-args>"}}\n' >> "$TX/s.jsonl"
t "drift: /goal clear after set -> empty" \
  "" "$(_sup_goal_drift claude "$GH" gdrift "$NOW_R" "$NOW_R")"
# fresh goal (set within the slow window) -> not drift (set->start race)
FRESH_TS=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
printf '{"type":"user","timestamp":"%s","message":{"content":"A session-scoped Stop hook is now active with condition: \\"Task DIVE-8971 ... 5dive task start DIVE-8971\\""}}\n' "$FRESH_TS" > "$TX/s.jsonl"
t "drift: freshly-armed goal -> empty (grace)" \
  "" "$(_sup_goal_drift claude "$GH" gdrift "$NOW_R" "$NOW_R")"

# ── DIVE-3667: fleet rollup counts every class ──────────────────────────────
# The defect these arms pin: the tick enumerated five classes by hand, so
# `stalled` — actionable work stranded on a seat not working it — was absent
# from the counters, the log line and the heartbeat row's signals, while the
# board printed it correctly. Measured 2026-08-22: six consecutive
# observe/stalled/idle-stranded rows in supervisor_events under a log line
# reading "17 agents — 16 healthy / 0 slow / 0 drift / 0 stuck". The only
# symptom was a total that did not add up, which is why arm 3 asserts the SUM
# and not just the presence of the word.
_snap() {  # <class>:<n> ... -> a snapshot array of that shape
  local out="[]" c n i
  for spec in "$@"; do
    c="${spec%%:*}"; n="${spec##*:}"
    for (( i = 0; i < n; i++ )); do
      out=$(jq -c --arg c "$c" '. + [{classification:$c}]' <<<"$out")
    done
  done
  printf '%s' "$out"
}

# 1. clean fleet — every bucket zero, nothing degraded, line does not grow
CLEAN=$(_snap healthy:17)
t "rollup: clean fleet counts 17 healthy, 0 unclassified" \
  "17	0	0	0	0	0	0	0	0	0" "$(_sup_rollup_counts "$CLEAN")"
read -r H SL ST DR VC SA NO UP QE OT <<<"$(_sup_rollup_counts "$CLEAN")"
t "rollup: clean fleet is healthy" \
  "healthy" "$(_sup_fleet_class $H $SL $ST $DR $VC $SA $NO $UP $QE $OT)"
t "rollup: clean fleet adds no suffix (line must not grow)" \
  "" "$(_sup_rollup_extra 0 0 0 0 0)"

# 2/3. THE MEASURED SHAPE — 17 seats, one stalled. Before this fix the line read
# "17 agents — 16 healthy / 0 slow / 0 drift / 0 stuck" and the seat was unnamed.
STRANDED=$(_snap healthy:16 stalled:1)
read -r H SL ST DR VC SA NO UP QE OT <<<"$(_sup_rollup_counts "$STRANDED")"
t "rollup: the stalled seat is COUNTED" "1" "$SA"
t "rollup: the stalled seat is NAMED in the line" \
  " / 1 stalled" "$(_sup_rollup_extra "$SA" "$NO" "$UP" "$QE" "$OT")"
t "rollup: a stranded fleet is degraded, not healthy" \
  "degraded" "$(_sup_fleet_class $H $SL $ST $DR $VC $SA $NO $UP $QE $OT)"
# The invariant. Its violation ("16 of 17") was the ONLY visible symptom, so it
# is the assertion that would have failed before the fix.
t "rollup: printed buckets sum to the agent count" \
  "17" "$(( H + SL + ST + DR + VC + SA + NO + UP + QE + OT ))"

# 4. a class added AFTER this commit must not vanish the same way
NEWCLS=$(_snap healthy:2 wedged-in-2027:1)
read -r H SL ST DR VC SA NO UP QE OT <<<"$(_sup_rollup_counts "$NEWCLS")"
t "rollup: an unknown class lands in unclassified, not nowhere" "1" "$OT"
t "rollup: an unknown class still degrades the fleet" \
  "degraded" "$(_sup_fleet_class $H $SL $ST $DR $VC $SA $NO $UP $QE $OT)"
t "rollup: an unknown class is flagged in the line" \
  " / ⚠ 1 unclassified" "$(_sup_rollup_extra "$SA" "$NO" "$UP" "$QE" "$OT")"

# 5. The DELIBERATE exclusions. _sup_fleet_class takes all ten counts precisely
# so these are a testable choice and not an argument someone forgot to pass.
# Mutant caught: folding update-pending into the degraded sum paints every box
# degraded the night of a publish; folding in drift does the same on a /goal
# that nothing ever acts on.
UPD=$(_snap healthy:9 update-pending:8)
read -r H SL ST DR VC SA NO UP QE OT <<<"$(_sup_rollup_counts "$UPD")"
t "rollup: update-pending is counted" "8" "$UP"
t "rollup: a fleet that is only update-pending stays HEALTHY" \
  "healthy" "$(_sup_fleet_class $H $SL $ST $DR $VC $SA $NO $UP $QE $OT)"
t "rollup: update-pending is still named in the line" \
  " / 8 update-pending" "$(_sup_rollup_extra $SA $NO $UP $QE $OT)"
DRF=$(_snap healthy:4 drift:2)
read -r H SL ST DR VC SA NO UP QE OT <<<"$(_sup_rollup_counts "$DRF")"
t "rollup: a fleet that is only drift stays HEALTHY" \
  "healthy" "$(_sup_fleet_class $H $SL $ST $DR $VC $SA $NO $UP $QE $OT)"

# 6. the other work-is-not-moving classes DO degrade (mutant: dropping any one
# from the sum leaves an alerting class reported as a healthy fleet)
for cls in slow stuck verify-challenge no-output quota-exhausted stalled; do
  read -r H SL ST DR VC SA NO UP QE OT <<<"$(_sup_rollup_counts "$(_snap healthy:3 "${cls}:1")")"
  t "rollup: ${cls} alone degrades the fleet" \
    "degraded" "$(_sup_fleet_class $H $SL $ST $DR $VC $SA $NO $UP $QE $OT)"
done

# 7. empty fleet must not crash or report a negative unclassified
t "rollup: empty snapshot is all zeros" \
  "0	0	0	0	0	0	0	0	0	0" "$(_sup_rollup_counts '[]')"

# 8. multiple non-zero buckets keep a stable, readable order
t "rollup: suffix order is stalled, no-output, update-pending, quota, unclassified" \
  " / 1 stalled / 2 no-output / 3 update-pending / 4 quota-exhausted / ⚠ 5 unclassified" \
  "$(_sup_rollup_extra 1 2 3 4 5)"

# 9. CALL SITES. The helpers being correct is not the tick USING them — the
# classic "control enforced on one path, absent on the parallel one". The board
# and the tick are exactly that pair, and the tick is the half that had the
# defect. `declare -f` reads the PARSED function body, so this survives comment
# and whitespace drift in the file in a way grep would not.
TICKBODY="$(declare -f cmd_supervisor_tick)"
t "call site: the tick counts via _sup_rollup_counts" \
  "yes" "$(grep -qF '_sup_rollup_counts' <<<"$TICKBODY" && echo yes || echo no)"
t "call site: the tick's heartbeat verdict comes from _sup_fleet_class" \
  "yes" "$(grep -qF '_sup_fleet_class' <<<"$TICKBODY" && echo yes || echo no)"
t "call site: the tick's log line appends _sup_rollup_extra" \
  "yes" "$(grep -qF '_sup_rollup_extra' <<<"$TICKBODY" && echo yes || echo no)"
# The heartbeat row is the DENOMINATOR (DIVE-975). Before this change its JSON
# omitted verifyChallenge — which DROVE fleet_class — so the row could not
# explain its own verdict, and no later query could recover a stalled rate.
# The two JSONs are checked SEPARATELY and by their distinct jq syntax
# (`k:$var` in the heartbeat, `k:($var|tonumber)` in the ok line). Grepping the
# whole function body for "k:" passes on either one alone — the first cut of
# this arm did exactly that and survived a mutant that emptied the heartbeat.
SIGPROG="$(awk '/sig=\$\(jq -nc/,/anomalyRows/' <<<"$TICKBODY")"
OKLINE="$(grep -F 'supervisor tick: ${total} agents' <<<"$TICKBODY")" || OKLINE=""
for k in stalled noOutput updatePending quotaExhausted unclassified verifyChallenge; do
  t "call site: heartbeat signals carry ${k}" \
    "yes" "$(grep -qF "${k}:\$" <<<"$SIGPROG" && echo yes || echo no)"
  t "call site: the tick's --json carries ${k}" \
    "yes" "$(grep -qF "${k}:(\$" <<<"$OKLINE" && echo yes || echo no)"
done

# 10. set -e. This harness runs `set -uo pipefail` WITHOUT -e; the shipped CLI
# runs `set -euo pipefail` (src/header.sh). A helper built from
# `(( n > 0 )) && out+=...` returns non-zero on the all-zero path, so the clean-
# fleet case is exactly the one an -e-less harness cannot see — and a clean
# fleet is the common case, i.e. the tick would abort every night but the bad
# one. Run the real thing under -e in a subshell.
# It has to be a FRESH `bash -c`, not `$( set -e; ... ) || fallback`. In the
# latter the whole substitution is the left arm of an AND-OR list, which
# SUPPRESSES -e inside it — so the obvious spelling of this arm passes against
# a helper that does abort. Measured while writing it: the mutant that returns
# the failed (( )) survived the $( ) form and is caught by this one.
SETE_OUT=$(bash -c '
  set -euo pipefail
  STATE_DIR=$(mktemp -d); JSON_MODE=0
  cd "'"$PWD"'"
  for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
           lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh cmd_supervisor.sh; do
    . "src/$f"
  done
  fc=$(_sup_fleet_class 17 0 0 0 0 0 0 0 0 0)
  ex=$(_sup_rollup_extra 0 0 0 0 0)
  read -r h _ <<<"$(_sup_rollup_counts "[{\"classification\":\"healthy\"},{\"classification\":\"healthy\"}]")"
  printf "%s|%s|%s" "$fc" "$ex" "$h"
' 2>/dev/null) || SETE_OUT="ABORTED-UNDER-SET-E"
t "set -e: the clean-fleet path does not abort the tick" \
  "healthy||2" "$SETE_OUT"

# ── DIVE-3856: rung 4 verifies its own remedy ────────────────────────────────
# THE DEFECT this grades: on 2026-08-31 rung 4 restarted a poller-dead `main`
# and recorded result:"ok" from cmd_restart's EXIT CODE. The seat was still
# deaf; the seat's lifecycle.log shows no launcher line at all for that restart,
# and the supervisor discovered it ten minutes later, whereupon the rate limiter
# refused a second restart and escalated `restart-rate-limited` — a true
# sentence that names the LIMITER as the reason a human is needed, when the
# reason is that the remedy did not work.
#
# The arms fail in OPPOSITE directions and both are graded:
#   FALSE GREEN — scoring ok for a poller nobody counted (the original bug), or
#                 counting the LAUNCHER and calling a still-deaf seat cured.
#   FALSE RED   — probing before the poller can exist (~9s) and escalating a
#                 healthy seat, or escalating a seat whose type we cannot probe.

# --- the predicate: the POLLER, not the launcher -----------------------------
# Measured on this host 2026-08-31 (plugin 0.5.49): a claude seat runs BOTH
#   `bun run --cwd …/5dive-plugins/telegram/0.5.49 … start`  (the launcher)
#   `bun start.ts`                                            (the poller)
# and only the first matches the classifier's _SUP_POLLER_PAT. A verification
# probe that inherited that pattern would grade the launcher it just started.
tp() { ( PGREP_OUT="$1"; pgrep() { [[ -n "$PGREP_OUT" ]] && printf '%s\n' $PGREP_OUT; }
         getent() { return 0; }
         _sup_true_poller_count "${2:-unit-p}" "${3:-claude}" ); }
_PAT_C="${_SUP_TRUE_POLLER_PAT[claude]}"
t "3856 predicate: matches the bare poller argv (\`bun start.ts\`, plugin >= 0.5.49)" "yes" \
  "$(printf '%s\n' 'bun start.ts' | grep -qE "$_PAT_C" && printf yes || printf no)"
t "3856 predicate: matches the OLDER argv (\`bun server.ts\`) — a start.ts-only pattern reads zero on healthy seats" "yes" \
  "$(printf '%s\n' 'bun server.ts' | grep -qE "$_PAT_C" && printf yes || printf no)"
t "3856 predicate: matches the path-qualified telegram-<x> variant" "yes" \
  "$(printf '%s\n' 'bun /home/agent-x/.claude/plugins/cache/telegram-codex/0.4.0/server.ts' | grep -qE "$_PAT_C" && printf yes || printf no)"
t "3856 predicate: does NOT match the LAUNCHER (the whole point — it is state 2 blindness)" "no" \
  "$(printf '%s\n' 'bun run --cwd /home/agent-x/.claude/plugins/cache/5dive-plugins/telegram/0.5.49 --shell=bun --silent start' \
     | grep -qE "$_PAT_C" && printf yes || printf no)"
t "3856 predicate: is NOT the classifier's pattern (that one matches the launcher and misses the poller)" "differ" \
  "$( [[ "${_SUP_TRUE_POLLER_PAT[claude]}" == "${_SUP_POLLER_PAT[claude]}" ]] && printf same || printf differ )"
t "3856 count: one poller process counts as one" "1" "$(tp '4242')"
t "3856 count: the probe's OWN pid is excluded (pgrep -f matches our command line)" "0" "$(tp "$$")"
t "3856 count: no poller is a real zero, not unknown" "0" "$(tp '')"
t "3856 count: a type with no argv-stable poller is n/a, never zero (opencode is \`bun run … start\`)" "n/a" "$(tp '4242' unit-p opencode)"
t "3856 count: opencode is absent from the table ON PURPOSE" "absent" \
  "$( [[ -n "${_SUP_TRUE_POLLER_PAT[opencode]:-}" ]] && printf present || printf absent )"
# `sudo pgrep -u agent-<n>` FAILS OPEN on a 5dive-only sudo grant: "a password is
# required" exits like a real zero, so every seat would read dead and be
# escalated. Plain pgrep needs no sudo — the process table is world-readable.
# Graded on CODE, not on the comments that explain the absence (this file and
# cmd_supervisor.sh both name `sudo pgrep` in prose precisely to forbid it).
_CODE_3856=$(awk '/^_sup_true_poller_count\(\) \{/,/^\}/' "$SRC/cmd_supervisor.sh" | grep -v '^[[:space:]]*#') || _CODE_3856=""
# LIVENESS FIRST. Both arms below assert an ABSENCE, and an empty extraction
# (a renamed function, a comment-stripping pipe that matched nothing) satisfies
# an absence vacuously. Grade that the extraction actually found the probe
# before grading what it does not contain.
t "3856: the code extracted for the absence arms is real (they are not vacuous)" "yes" \
  "$( [[ -n "$_CODE_3856" ]] && grep -q 'pgrep' <<<"$_CODE_3856" && printf yes || printf no )"
t "3856: the verification probe never goes through sudo (a denied sudo exits like a real zero)" "no" \
  "$(grep -q 'sudo' <<<"$_CODE_3856" && printf yes || printf no)"
t "3856: it does not read \`agent info\`'s CACHED supervisor verdict" "no" \
  "$(grep -q 'agent info' <<<"$_CODE_3856" && printf yes || printf no)"

# --- the wait is a POLL, not a sleep -----------------------------------------
# A poller appears ~9s after the bounce. A probe taken the instant cmd_restart
# returns reads ZERO on a perfectly healthy seat — a false RED whose remedy
# would be another restart.
# The stub's call counter lives in a FILE, not a variable: _sup_restart_verify
# reads the probe through a command substitution, which is a subshell, so an
# in-variable counter resets on every call and every probe returns the first
# reading — the "appears late" arm would be unfalsifiable.
rv() { ( _COUNTS="$1"; _CTR="$TMP/rv.$$"; printf '0' >"$_CTR"
         _sup_true_poller_count() {
           local i; i=$(( $(cat "$_CTR") + 1 )); printf '%s' "$i" >"$_CTR"
           printf '%s\n' "$(cut -d, -f"$i" <<<"$_COUNTS")"
         }
         sleep() { :; }
         _sup_restart_verify "${2:-unit-p}" "${3:-claude}" "${4:-5}" ); }
t "3856 verify: a poller already back reads ok on the first probe" "ok" "$(rv '1')"
t "3856 verify: a poller that appears LATE still reads ok — the wait is a poll, not one shot" "ok" "$(rv '0,0,0,1')"
t "3856 verify: still zero at the deadline is still-dead (the 08-31 case)" "still-dead" "$(rv '0,0,0,0,0,0,0')"
t "3856 verify: an unprobeable type is UNVERIFIED — a third outcome, never folded into ok or dead" "unverified" "$(rv 'n/a')"
t "3856 verify: a garbage reading is unverified, never ok" "unverified" "$(rv 'banana')"
# The budget is a real ceiling, and it is per seat inside a 10-minute tick.
t "3856 verify: the budget is configurable and defaults to a bounded number of seconds" "yes" \
  "$( [[ "$_SUP_RESTART_VERIFY_SEC" =~ ^[0-9]+$ ]] && (( _SUP_RESTART_VERIFY_SEC > 0 && _SUP_RESTART_VERIFY_SEC <= 120 )) && printf yes || printf no )"

# --- the wiring: result strings + same-tick escalation ------------------------
# Without these the arms above grade dead code.
_ACT_BLOCK="$(awk '/nudge\|resume\|rotate\|restart\)/,/^      esac/' "$SRC/cmd_supervisor.sh")"
t "3856 wiring: the action branch calls the verifier" "yes" \
  "$(grep -q '_sup_restart_verify "\$name" "\$atype"' <<<"$_ACT_BLOCK" && printf yes || printf no)"
t "3856 wiring: ONLY the poller-dead restart is verified (a nudge succeeds by being delivered)" "yes" \
  "$(grep -qE '"\$verb" == "restart" && .*"\$cause" == "poller-dead"' <<<"$_ACT_BLOCK" && printf yes || printf no)"
t "3856 wiring: a still-dead poller is recorded as such, not as ok" "yes" \
  "$(grep -q 'res="restart-ran-poller-still-dead"' <<<"$_ACT_BLOCK" && printf yes || printf no)"
t "3856 wiring: an unverifiable seat gets its own result string, not ok" "yes" \
  "$(grep -q 'res="restart-ran-poller-unverified"' <<<"$_ACT_BLOCK" && printf yes || printf no)"
t "3856 wiring: a still-dead poller escalates ON THIS TICK (not 10 minutes later, as restart-rate-limited)" "yes" \
  "$(grep -A3 'if \[\[ "\$res" == "restart-ran-poller-still-dead" \]\]' <<<"$_ACT_BLOCK" \
     | grep -q 'event=.escalate.\|SELECT COUNT' && printf yes || printf no)"
t "3856 wiring: UNVERIFIED does not escalate (it would page a person for every healthy unprobeable seat)" "no" \
  "$(grep -q 'restart-ran-poller-unverified" \]\]' <<<"$_ACT_BLOCK" && printf yes || printf no)"
t "3856 wiring: the same-tick escalation carries a courier receipt, like every other escalate row" "yes" \
  "$(grep -q '_sup_escalate_deliver "\$name" "\$cause" "\$v_reason"' <<<"$_ACT_BLOCK" && printf yes || printf no)"
# DO NOT raise the limiter to paper over a failing remedy: a restart that works
# is visible in ~9s, so a second inside the window is the signature of a seat
# restart does not fix. This arm is what stops a future "just allow 2".
t "3856: the rung-4 limiter is UNTOUCHED — max stays 1 per seat" "1" "$_SUP_RESTART_MAX"
t "3856: the limiter window is UNTOUCHED — 6h" "6" "$_SUP_RESTART_WINDOW_H"
# `warm_channel_capability_restart()` verifies `systemctl is-active` — the UNIT,
# not the poller — which is the exact state this outage lives in. Reusing it
# relocates the false green. Graded on code, not on the prose forbidding it.
t "3856: the unit-only warm-up helper is NOT reused" "no" \
  "$(grep -v '^[[:space:]]*#' "$SRC/cmd_supervisor.sh" | grep -q 'warm_channel_capability_restart' && printf yes || printf no)"
# And the retracted design stays retracted: this row must not add a second
# detector in the self-update sweep (quinn rejected iteration 1 for that).
t "3856: no channel detector was added to _pending_restart_sweep (the retracted design)" "no" \
  "$(grep -q '_channel_check' "$SRC/cmd_selfupdate.sh" && printf yes || printf no)"

# --- site 1: rotate's envelope stops over-claiming ---------------------------
# GRADED BY EXECUTION, IN tests/account_rotation_headroom_unit.sh — that harness
# already sources src/cmd_account.sh, so it can CALL the verb and assert on the
# JSON values it emits. Iteration 1 graded site 1 here instead, by grepping an
# awk-extracted copy of the function body. Measured (quinn's grade): widening
# the has_chat case to `*)` makes every headless seat rotate with
# channelVerified:false and "poller check OWED" — the exact false signal the
# code comment forbids — and all five grep arms stayed GREEN, because a grep of
# the source certifies that a line EXISTS, not that the verb emits anything.
# That is this row's own over-claim, committed by its own tests. Do not
# re-add positive grep arms here; extend the behavioural pair over there.
#
# What survives as a grep is an ABSENCE over the whole file, which is a text
# property and not a claim about a value: no site in the account module may
# ever hard-code the verified flag true. It is a cheap belt over the
# behavioural arms, not a substitute for them.
t "3856 rotate: nothing in the account module hard-codes channelVerified true" "no" \
  "$(grep -v '^[[:space:]]*#' "$SRC/cmd_account.sh" \
     | grep -q 'channel_verified=true\|channelVerified:[[:space:]]*true' && printf yes || printf no)"

echo
echo "supervisor_unit: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
(( FAIL == 0 ))
