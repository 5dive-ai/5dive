#!/usr/bin/env bash
# DIVE-857 isolated unit harness for the supervisor P2 act layer.
#
# Same isolation contract as loop_*_unit.sh: sources src/ libs directly and
# points STATE_DIR at a throwaway temp dir so it NEVER touches the live shared
# tasks.db. Asserts: _sup_act_plan's full decision matrix (cause map, runtime
# guard, ladder order, backoff math, exhaustion, rotation gate) and
# _sup_act_history counting action rows from a seeded audit trail.
# Run: bash tests/supervisor_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/supervisor-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

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

# --- runtime guard ----------------------------------------------------------
t "non-claude runtime escalates even on actionable cause" \
  "escalate non-claude-runtime" "$(_sup_act_plan codex no-progress 0 0 $NOW false)"

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

echo
echo "supervisor_unit: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
(( FAIL == 0 ))
