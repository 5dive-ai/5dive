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
# ...and with it counted, the plan flips. This is the pair that proves the
# limiter is wired to the trail, not just to a literal in the test above.
t "seat with a restart on the trail now escalates" \
  "escalate restart-rate-limited" \
  "$(_sup_act_plan claude poller-dead 0 0 $NOW false "$(_sup_restart_history unit-r)")"

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

echo
echo "supervisor_unit: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
(( FAIL == 0 ))
