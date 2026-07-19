
# -------- 5dive heartbeat — wake agents that have queued work --------
#
# A per-agent "heartbeat": a single host cron runs `5dive heartbeat tick`
# every few minutes. For each enrolled agent the tick asks one question —
# "does this agent have a todo task on the shared board?" — and acts:
#
#   * no todo            -> do nothing. The agent never wakes, so it burns
#                           zero tokens and never starts its 5h usage window.
#   * already in_progress -> skip. The agent is still chewing on its last
#                           task; piling on a second nudge would interleave work.
#   * has todo + due      -> ensure the agent is running, optionally /clear it
#                           for a fresh context, then inject ONE nudge telling
#                           it to do a single task and then idle.
#
# "One task per tick" is the whole point: 1 nudge = 1 task. The next tick (no
# sooner than the agent's `everyMin`) picks up the next one. The agent process
# stays running between ticks (cheap tmux session) — `fresh` sends `/clear`
# before the nudge so each task starts from a clean conversation without the
# cold-start cost of a full restart.
#
# Config lives per-agent in the registry under .agents[<name>].heartbeat:
#   { enabled: bool, everyMin: int, fresh: bool, lastRunAt: <epoch> }
# lastRunAt throttles *wakes* (not checks): a no-work agent is re-checked every
# tick (a cheap sqlite count) but only counts against everyMin when it actually
# wakes. So everyMin is "minimum minutes between real wakes", honoured even
# though the cron fires more often.

_HB_DEFAULT_EVERY=30
# Deterministic hard cap for the /goal loop. A task left in_progress longer than
# everyMin * _HB_STALE_MULT minutes is force-closed by the tick (see the reaper
# in cmd_heartbeat_tick): /goal clear to stop any runaway loop, then auto-cancel.
# This is the real backstop — /goal's own "stop after N turns" is model-judged
# and was observed to overrun (see _hb_wake). Min floor keeps short everyMin sane.
_HB_STALE_MULT=3
_HB_STALE_MIN_MINUTES=45
# Starvation signal: a todo task that gets nudged this many times but never
# leaves 'todo' (started_at stays empty) is almost certainly being starved —
# e.g. the codex/grok listen-loop watchdog yanking the agent off the task before
# it runs `task start`. The reaper only catches runaway *in_progress* tasks; this
# catches the opposite silent failure (nudged but never started) and surfaces it
# instead of re-nudging forever. Per-task nudge counts live in the registry under
# .agents[<name>].heartbeat.nudges and are pruned once a task leaves todo.
_HB_STARVE_AFTER=3

# A reaped task (in_progress past the budget) is requeued to todo, never
# cancelled — silently losing real mid-flight work is worse than a re-run
# (DIVE-482/200). But a task that keeps overrunning even after a clean requeue
# is genuinely stuck: after this many reaps it's blocked + escalated (pings the
# owner & paired human) so it surfaces instead of churning. Still never cancelled.
_HB_REAP_ESCALATE_AFTER=2
# OSS-12: gate SLA escalation. A T2 gate unanswered for this many days doesn't
# just keep re-pinging the same recipient — the weekly stale-gate batch ALSO
# CCs the filing agent's org-chart parent (agents_org.reports_to), so an
# unanswered gate walks the chain instead of stalling on one lane. NEVER
# auto-answers a T2 gate: escalation changes WHO is pinged, not what clears.
_HB_GATE_ESCALATE_DAYS="${HEARTBEAT_GATE_ESCALATE_DAYS:-5}"
[[ "$_HB_GATE_ESCALATE_DAYS" =~ ^[0-9]+$ ]] || _HB_GATE_ESCALATE_DAYS=5
# DIVE-1140 gate-shipped sweep. Which repos' origin/main to scan for a merged
# commit referencing an OPEN gate's ident (space- or comma-separated stems under
# _HB_REPO_BASE). A DIVE-id can land in any of ~a dozen repos, so this is a
# deliberate allow-list, not a guess — default just the CLI where most gate work
# lands. Grep is on the LOCAL origin/main tracking ref (no fetch: cheap +
# credential-free), so freshness = last time an agent pulled that repo.
_HB_GATE_SHIPPED_REPOS="${HEARTBEAT_GATE_SHIPPED_REPOS:-5dive-cli}"
_HB_REPO_BASE="${HEARTBEAT_REPO_BASE:-/home/claude/projects/5dive}"
_HB_GATE_SHIPPED_REF="${HEARTBEAT_GATE_SHIPPED_REF:-origin/main}"
# DIVE-1416 fleet-stall self-heal (gaps #2/#3 — gap #1 is _hb_blocked_sweep
# above). How long a maker->verifier delivery may sit unacknowledged
# (handoff_delivered_at) before the stall sweep surfaces it (gap#2); how long
# the fleet-idle-while-actionable-work-is-open condition must persist before
# it alarms (gap#3 core, "K min" in the design). Both env-overridable, same
# escape-hatch pattern as _HB_GATE_ESCALATE_DAYS.
_HB_VERIFY_STALE_MIN="${HEARTBEAT_VERIFY_STALE_MIN:-60}"
[[ "$_HB_VERIFY_STALE_MIN" =~ ^[0-9]+$ ]] || _HB_VERIFY_STALE_MIN=60
_HB_STALL_MIN_MINUTES="${HEARTBEAT_STALL_MIN_MINUTES:-30}"
[[ "$_HB_STALL_MIN_MINUTES" =~ ^[0-9]+$ ]] || _HB_STALL_MIN_MINUTES=30
# Orphan reclaim. An in_progress task whose claiming claude session is GONE — the
# agent's claude process started AFTER the task did (rotation, service restart,
# crash, a context reset that exited the process) — is reclaimed to 'todo'
# immediately rather than waiting out the _HB_STALE_MULT hard cap: nobody is
# working it, and the work still needs doing. _HB_PROC_SKEW_SEC absorbs the small
# gap between a process starting and the `task start` it then runs.
_HB_PROC_SKEW_SEC=20
# Backstop for the same-process abandon case (agent claimed a task, then went
# idle without closing it — its claiming process is unchanged, so the restart
# rule above can't see it). Reclaim to 'todo' once the task has sat in_progress
# past this grace AND the agent is idle right now.
_HB_STALL_MIN_MINUTES=20
# DIVE-1486 active-defer reconciliation. The no-clobber guard defers a nudge on a
# confident "active" (rc 1) reading so it never /clears an agent mid-turn. But an
# attached-but-idle session can read "active" indefinitely (a blinking
# cursor/spinner leaves the pane byte-unstable, or the native signal lags), so a
# real todo sits deferred forever while the supervisor calls the same agent
# "idle-stranded" — the two signals disagree and the self-heal never fires
# (the live 2026-07-19 stall this task re-files). Reconcile with output progress:
# fingerprint the pane each active-defer; if it is UNCHANGED across this many
# consecutive deferred ticks (zero output progress) while a dispatchable todo
# waits, the session is idle-stranded, not mid-turn — stop deferring and
# force-nudge. A genuinely working agent streams output, so its fingerprint moves
# and the counter resets, never reaching the ceiling. Env-overridable.
_HB_ACTIVE_DEFER_ESCALATE="${HEARTBEAT_ACTIVE_DEFER_ESCALATE:-3}"
[[ "$_HB_ACTIVE_DEFER_ESCALATE" =~ ^[0-9]+$ ]] || _HB_ACTIVE_DEFER_ESCALATE=3
# Idle probe window. An agent whose pane is byte-identical across this gap (and
# still shows its input prompt) is at rest; a working agent streams output or
# animates a spinner, so its pane changes between two samples. Deliberately dumb
# and CLI-agnostic — see _hb_agent_idle. Used to (a) never /clear+nudge an agent
# mid-turn/conversation and (b) gate idle-stall reclaim.
_HB_IDLE_SAMPLE_SEC=3

_hb_log() { printf '%s [heartbeat] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

_hb_usage() {
  cat <<USAGE
5dive heartbeat — wake agents only when they have queued tasks

  5dive heartbeat on  <name> [--every=<dur>] [--fresh]
                                          # enrol agent; default every=${_HB_DEFAULT_EVERY}m, fresh off
  5dive heartbeat off <name>              # stop waking the agent (keeps its settings)
  5dive heartbeat ls                      # show enrolled agents + next-wake + queued count
  5dive heartbeat tick                    # cron driver: wake every due agent that has work

  <dur>: minutes (e.g. 30), or 45m / 2h / 1h30m.
  fresh (default off, DIVE-1210): --fresh sends /clear before each task so
        context starts clean, at the cost of a full CLAUDE.md/project re-prime
        on every wake (up to ~48x/day on the default 30m cadence). Off keeps
        the running conversation across tasks — cheaper, and what main/
        marketing already ran manually before this became the default.

Wire the driver into cron (root), e.g. every 5 minutes:
  */5 * * * * /usr/local/bin/5dive heartbeat tick >> /var/log/5dive-heartbeat.log 2>&1

Add --json to any subcommand for machine output.
USAGE
}

cmd_heartbeat() {
  [[ $# -gt 0 ]] || { _hb_usage; exit "$E_USAGE"; }
  local sub="$1"; shift
  case "$sub" in
    on|enable)       with_registry_lock cmd_heartbeat_on "$@" ;;
    off|disable)     with_registry_lock cmd_heartbeat_off "$@" ;;
    ls|list|status)  cmd_heartbeat_ls "$@" ;;
    tick)            cmd_heartbeat_tick "$@" ;;
    wake-task)       cmd_heartbeat_wake_task "$@" ;;
    -h|--help|help)  _hb_usage ;;
    *) fail "$E_USAGE" "unknown heartbeat command: $sub (try: 5dive heartbeat --help)" ;;
  esac
}

# DIVE-1349 wake-on-spawn helper (internal plumbing, not in _hb_usage). Nudges
# ONE agent to start a specific just-spawned task now instead of on its next
# tick. Root-gated because it drives systemd + the agent's tmux session; invoked
# by `loop spawn` — directly when already root, else via `sudo -n 5dive heartbeat
# wake-task …` from the claude-owned shelld exec context. Reuses the exact tick
# nudge (_hb_wake, fresh=false: pick the task up in the running context, no
# /clear). Best-effort by contract: _hb_wake's own failures are non-fatal here.
cmd_heartbeat_wake_task() {
  require_root
  local name="${1:-}" task_id="${2:-}" task_ident="${3:-DIVE-${2:-}}"
  [[ -n "$name" && "$task_id" =~ ^[0-9]+$ ]] \
    || fail "$E_USAGE" "usage: 5dive heartbeat wake-task <agent> <task_id> [<task_ident>]"
  _hb_wake "$name" "false" "$task_id" "$task_ident" || true
}

# Parse a duration into whole minutes. Accepts a bare integer (minutes),
# or an h/m combo like 2h, 45m, 1h30m. Echoes minutes on success, returns 1
# on a malformed or zero-length value.
_hb_parse_every() {
  local s="$1"
  [[ -n "$s" ]] || return 1
  if [[ "$s" =~ ^[0-9]+$ ]]; then
    (( s > 0 )) || return 1
    printf '%s' "$s"; return 0
  fi
  [[ "$s" =~ ^([0-9]+h)?([0-9]+m)?$ ]] || return 1
  local h="${BASH_REMATCH[1]%h}" m="${BASH_REMATCH[2]%m}"
  local total=$(( ${h:-0} * 60 + ${m:-0} ))
  (( total > 0 )) || return 1
  printf '%s' "$total"
}

cmd_heartbeat_on() {
  require_root "heartbeat on"
  local name="" every="" fresh="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --every=*)  every="${1#*=}" ;;
      --fresh)    fresh="true" ;;
      --no-fresh) fresh="false" ;;
      -*)         fail "$E_USAGE" "unknown flag: $1" ;;
      *)          [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive heartbeat on <name> [--every=<dur>] [--fresh]"
  require_agent "$name"
  local everyMin="$_HB_DEFAULT_EVERY"
  if [[ -n "$every" ]]; then
    everyMin=$(_hb_parse_every "$every") || fail "$E_VALIDATION" "bad --every '$every' (use minutes, or 45m / 2h / 1h30m)"
  fi
  local reg; reg=$(registry_read)
  # Preserve any existing lastRunAt so toggling on/off doesn't reset the throttle.
  echo "$reg" | jq --arg n "$name" --argjson e "$everyMin" --argjson f "$fresh" \
    '.agents[$n].heartbeat = {
        enabled: true,
        everyMin: $e,
        fresh: $f,
        lastRunAt: (.agents[$n].heartbeat.lastRunAt // 0)
     }' | registry_write
  ok "heartbeat on for '$name' (every ${everyMin}m, fresh=${fresh})" \
     '{name:$n, enabled:true, everyMin:($e|tonumber), fresh:($f=="true")}' \
     --arg n "$name" --arg e "$everyMin" --arg f "$fresh"
}

cmd_heartbeat_off() {
  require_root "heartbeat off"
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive heartbeat off <name>"
  require_agent "$name"
  local reg; reg=$(registry_read)
  echo "$reg" | jq --arg n "$name" \
    '.agents[$n].heartbeat = ((.agents[$n].heartbeat // {everyMin: '"$_HB_DEFAULT_EVERY"', fresh: false, lastRunAt: 0}) + {enabled: false})' \
    | registry_write
  ok "heartbeat off for '$name'" '{name:$n, enabled:false}' --arg n "$name"
}

cmd_heartbeat_ls() {
  # Read-only: the registry is 640 root:claude, so any group-claude agent can
  # inspect its own heartbeat without sudo. No ensure_state (that requires root).
  local reg now; reg=$(registry_read); now=$(date +%s)
  # Enrich each agent that has a heartbeat object with live run-state + queued count.
  local rows="[]" name
  for name in $(jq -r '.agents | to_entries[] | select(.value.heartbeat != null) | .key' <<<"$reg"); do
    local enabled everyMin fresh lastRun running todo nextIn
    enabled=$(jq -r --arg n "$name"  '.agents[$n].heartbeat.enabled  // false' <<<"$reg")
    everyMin=$(jq -r --arg n "$name" '.agents[$n].heartbeat.everyMin // '"$_HB_DEFAULT_EVERY" <<<"$reg")
    fresh=$(jq -r --arg n "$name"    '(.agents[$n].heartbeat | if has("fresh") then .fresh else false end)' <<<"$reg")
    lastRun=$(jq -r --arg n "$name"  '.agents[$n].heartbeat.lastRunAt // 0' <<<"$reg")
    # is-active prints the state word AND exits nonzero for non-active units, so
    # capture its stdout directly — a `|| echo` here would append a second word.
    running=$(systemctl is-active "5dive-agent@${name}.service" 2>/dev/null || true)
    [[ -n "$running" ]] || running="unknown"
    todo=$(db "SELECT COUNT(*) FROM tasks WHERE assignee=$(sqlq "$name") AND status='todo' AND kind='standard';" 2>/dev/null || echo 0)
    # seconds until next eligible wake (0 = due now)
    nextIn=$(( lastRun + everyMin * 60 - now ))
    (( nextIn < 0 )) && nextIn=0
    rows=$(jq -c \
      --arg n "$name" --argjson en "$enabled" --argjson ev "$everyMin" \
      --argjson fr "$fresh" --arg run "$running" --argjson td "${todo:-0}" --argjson ni "$nextIn" \
      '. + [{name:$n, enabled:$en, everyMin:$ev, fresh:$fr, running:$run, todo:$td, nextInSec:$ni}]' <<<"$rows")
  done
  if (( JSON_MODE )); then
    printf '%s' "$rows" | jq -c '{ok:true, data:{agents:.}}'  # stdin, not --argjson (DIVE-222)
  else
    echo "$rows" | jq -r '
      if length == 0 then "no agents enrolled in heartbeat (5dive heartbeat on <name>)" else
        (["NAME","HEARTBEAT","EVERY","FRESH","RUNNING","TODO","NEXT-WAKE"] | @tsv),
        (.[] | [
          .name,
          (if .enabled then "on" else "off" end),
          ((.everyMin|tostring)+"m"),
          (if .fresh then "yes" else "no" end),
          .running,
          (.todo|tostring),
          (if (.enabled|not) then "-"
           elif .nextInSec == 0 then "now (if work)"
           else (((.nextInSec/60)|floor|tostring)+"m") end)
        ] | @tsv)
      end' | column -t -s $'\t'
  fi
}

# Persist a wake timestamp AND bump the per-task nudge counter. Runs under
# with_registry_lock from the tick loop. $3 is the DIVE id just nudged. Prunes
# nudge entries for tasks that have left 'todo' (started/done/cancelled/gone) so
# the map stays bounded and a counter resets cleanly if a task is re-queued.
# Echoes the post-increment nudge count for $task_id so the caller can decide
# whether the task is being starved.
_hb_mark_run() {
  local name="$1" now="$2" task_id="$3"
  local reg; reg=$(registry_read)
  # Current todo ids for this agent, as a JSON number array, to prune the map.
  local todo_ids
  todo_ids=$(db "SELECT id FROM tasks WHERE assignee=$(sqlq "$name") AND status='todo' AND kind='standard';" 2>/dev/null \
             | jq -R 'select(length>0)|tonumber' | jq -cs '.' 2>/dev/null) || todo_ids=""
  [[ -n "$todo_ids" ]] || todo_ids="[]"
  reg=$(echo "$reg" | jq --arg n "$name" --argjson t "$now" --arg tid "$task_id" --argjson todo "$todo_ids" '
    .agents[$n].heartbeat.lastRunAt = $t
    | .agents[$n].heartbeat.nudges = (
        ((.agents[$n].heartbeat.nudges // {})
          | with_entries(select((.key|tonumber) as $k | $todo | index($k) != null)))
        | .[$tid] = ((.[$tid] // 0) + 1)
      )')
  echo "$reg" | registry_write
  jq -r --arg n "$name" --arg tid "$task_id" '.agents[$n].heartbeat.nudges[$tid] // 0' <<<"$reg"
}

# Increment + return this task's consecutive-reap count, stored in the registry
# under .agents[<name>].heartbeat.reaps (parallel to .nudges). Pruned to the
# agent's still-open tasks, so a task that completes (or a relisted id) starts
# fresh. Must run under with_registry_lock, like _hb_mark_run.
_hb_mark_reap() {
  local name="$1" task_id="$2"
  local reg; reg=$(registry_read)
  local open_ids
  open_ids=$(db "SELECT id FROM tasks WHERE assignee=$(sqlq "$name") AND status IN ('todo','in_progress','blocked') AND kind='standard';" 2>/dev/null              | jq -R 'select(length>0)|tonumber' | jq -cs '.' 2>/dev/null) || open_ids=""
  [[ -n "$open_ids" ]] || open_ids="[]"
  reg=$(echo "$reg" | jq --arg n "$name" --arg tid "$task_id" --argjson open "$open_ids" '
    .agents[$n].heartbeat.reaps = (
      ((.agents[$n].heartbeat.reaps // {})
        | with_entries(select((.key|tonumber) as $k | $open | index($k) != null)))
      | .[$tid] = ((.[$tid] // 0) + 1)
    )')
  echo "$reg" | registry_write
  jq -r --arg n "$name" --arg tid "$task_id" '.agents[$n].heartbeat.reaps[$tid] // 0' <<<"$reg"
}

# DIVE-1486 — a cheap content fingerprint of an agent's tmux pane, used to tell an
# attached-but-idle "active" reading (pane frozen, zero output) apart from a
# genuinely mid-turn one (pane streaming). Echoes an md5 of the current pane, or
# empty if the pane can't be captured (dead/absent session) — callers treat empty
# as "no progress signal" and fall back to their existing behaviour.
_hb_pane_fingerprint() {
  local name="$1" user="agent-$1" out
  out=$(sudo -u "$user" tmux capture-pane -p -t "agent-${name}" 2>/dev/null) || { printf ''; return; }
  printf '%s' "$out" | md5sum 2>/dev/null | cut -d' ' -f1
}

# DIVE-1486 — increment + return this agent's consecutive active-defer count,
# stored in the registry under .agents[<name>].heartbeat.activeDefer = {fp,n}
# (parallel to .nudges / .reaps). The count advances ONLY while the pane
# fingerprint is unchanged from the prior deferred tick (zero output progress);
# any change — real streaming output, or a wake landing — resets it to 1, so a
# working agent never climbs to the escalation ceiling. An empty fingerprint
# (uncapturable pane) can't prove no-progress, so it also resets to 1 rather than
# advancing (fail-safe: never force-nudge on a missing signal). Must run under
# with_registry_lock, like _hb_mark_run / _hb_mark_reap.
_hb_mark_active_defer() {
  local name="$1" fp="$2"
  local reg; reg=$(registry_read)
  local prev_fp prev_n n
  prev_fp=$(jq -r --arg n "$name" '.agents[$n].heartbeat.activeDefer.fp // ""' <<<"$reg")
  prev_n=$(jq -r --arg n "$name" '.agents[$n].heartbeat.activeDefer.n // 0' <<<"$reg")
  [[ "$prev_n" =~ ^[0-9]+$ ]] || prev_n=0
  if [[ -n "$fp" && "$fp" == "$prev_fp" ]]; then
    n=$(( prev_n + 1 ))
  else
    n=1
  fi
  reg=$(echo "$reg" | jq --arg n "$name" --arg fp "$fp" --argjson c "$n" '
    .agents[$n].heartbeat.activeDefer = {fp:$fp, n:$c}')
  echo "$reg" | registry_write
  printf '%s' "$n"
}

# DIVE-1486 — clear an agent's active-defer counter once it's no longer being
# deferred (woke, went genuinely idle, or was force-nudged), so the next stall
# episode starts counting from scratch. Best-effort; must run under
# with_registry_lock.
_hb_clear_active_defer() {
  local name="$1"
  local reg; reg=$(registry_read)
  reg=$(echo "$reg" | jq --arg n "$name" 'if .agents[$n].heartbeat then del(.agents[$n].heartbeat.activeDefer) else . end')
  echo "$reg" | registry_write
}

# DIVE-979 — dependency-aware task pick for one agent. Echoes the single DIVE row
# id the heartbeat should wake this agent against, or empty when nothing is
# actionable. Two rules layered on top of the plain priority order:
#   (a) SKIP any todo whose task_deps carries an OPEN blocker — a blocked_by task
#       that is not yet done/cancelled — so we never hand out work that can't start.
#   (b) Within a priority tier, PREFER the critical path: the todo whose downstream
#       dependent chain is longest, so the longest remaining chain starts soonest.
# The recursive CTE walks task_deps forward (blocked_by -> task_id, i.e. toward
# dependents) and is depth-capped at 64 so a pathological/cyclic graph can't spin.
# Priority stays the primary key (an urgent task never waits behind a medium
# critical-path task); critical-path depth is the tiebreaker, then id for stability.
_hb_pick_task() {
  local name="$1"
  db "WITH RECURSIVE
        cp(root, node, depth) AS (
          SELECT id, id, 0 FROM tasks
            WHERE assignee=$(sqlq "$name") AND status='todo' AND kind='standard'
          UNION ALL
          SELECT cp.root, d.task_id, cp.depth+1
            FROM cp JOIN task_deps d ON d.blocked_by = cp.node
            WHERE cp.depth < 64
        ),
        crit(root, cp) AS (SELECT root, MAX(depth) AS cp FROM cp GROUP BY root)
      SELECT t.id
        FROM tasks t LEFT JOIN crit c ON c.root = t.id
        WHERE t.assignee=$(sqlq "$name") AND t.status='todo' AND t.kind='standard'
          AND NOT EXISTS (
            SELECT 1 FROM task_deps dd JOIN tasks b ON b.id = dd.blocked_by
             WHERE dd.task_id = t.id AND b.status NOT IN ('done','cancelled'))
        ORDER BY CASE t.priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1
                                 WHEN 'medium' THEN 2 ELSE 3 END,
                 COALESCE(c.cp,0) DESC, t.id
        LIMIT 1;" 2>/dev/null || echo ""
}

# DIVE-1065: privilege ordering for the auto-wake tier guard. admin > standard >
# sandboxed; 0 for unknown/human — an unknown creator never blocks a wake.
_hb_tier_rank() {
  case "$1" in
    admin)     echo 3 ;;
    standard)  echo 2 ;;
    sandboxed) echo 1 ;;
    *)         echo 0 ;;
  esac
}

# Inject one literal line + Enter into an agent's tmux pane. Returns nonzero
# (never exits) so a single dead pane can't abort the whole tick.
_hb_send_line() {
  local name="$1" text="$2" tries=0
  sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" -l -- "$text" 2>/dev/null || return 1
  # DIVE-1217: `send-keys -l` lands as a bracketed PASTE. Claude commits it
  # synchronously so an immediate Enter submits (leave that path alone). Non-claude
  # TUIs (codex/grok/agy/opencode) render the paste inline and a trailing Enter
  # fired with no gap RACES the paste-commit and is swallowed, so the turn never
  # starts and the nudge is silently dropped. For those: let the paste settle,
  # Enter, then CONFIRM the turn started (agent left idle), re-sending Enter a few
  # times before giving up.
  if [[ -n "$(_hb_claude_pid "$name")" ]]; then
    sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" Enter 2>/dev/null || return 1
    return 0
  fi
  sleep 0.4
  while (( tries < 5 )); do
    sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" Enter 2>/dev/null || return 1
    sleep 0.5
    # idle()==0 means the Enter did not take (still at the prompt) -> retry; any
    # other state (busy/blocked/unknown) means the composer accepted it.
    _hb_agent_idle "$name" 0.4 || return 0
    tries=$((tries+1))
  done
  return 1
}

# PID of this agent's live inner `claude` process, or empty if not found. This is
# the `claude` the `while true; do claude; ...` wrapper respawns. The bash wrapper
# and tmux lines also contain the claude argv, so exclude them (they carry
# 'while true' / 'tmux'). Non-claude agents (codex/grok/agy/opencode) won't match
# → empty, so both the restart-reclaim rule and the native idle probe simply
# don't apply to them (callers fall back).
_hb_claude_pid() {
  local name="$1"
  ps -u "agent-${name}" -o pid=,args= 2>/dev/null \
    | awk '/\/claude .*--dangerously-skip-permissions/ && !/while +true/ && !/tmux/ {print $1; exit}'
}

# Epoch when this agent's live claude process started, or empty if not found. Its
# start time is the agent's "session identity": a rotation, restart, crash, or
# context reset that exits the process gives the replacement a newer start time
# than any task its predecessor had already claimed.
_hb_claude_started() {
  local name="$1" pid lstart
  pid=$(_hb_claude_pid "$name")
  [[ -n "$pid" ]] || return 1
  lstart=$(ps -o lstart= -p "$pid" 2>/dev/null) || return 1
  [[ -n "$lstart" ]] || return 1
  date -d "$lstart" +%s 2>/dev/null || return 1
}

# Native run-state for a claude agent via `claude agents --json` (CC ≥2.1.162).
# Far more reliable than scraping the tmux pane, and it distinguishes a genuine
# block (a permission prompt / dialog / input-needed) from working vs idle — a
# distinction the pane-scrape can't make. We match the JSON entry by the agent's
# inner-claude PID so dispatched background sub-agents in the same list are
# ignored, and read that one session's status:
#   idle    -> "idle"            (at rest, no turn in flight)
#   busy    -> "busy"            (a turn is actively running)
#   waiting -> "blocked:<reason>" (waiting on a permission prompt / worker
#              request / sandbox request / dialog / input — surface, don't reclaim)
# Echoes that word and returns 0 on a definite reading; returns 1 (echoes
# nothing) when the signal is unavailable — non-claude CLI, claude not running,
# the binary is missing, or no matching session — so callers fall back to the
# pane-scrape probe. Runs as the agent's own user (its sessions live under that
# user's ~/.claude); the heartbeat tick runs as root, so the sudo is non-interactive.
_hb_agent_native_state() {
  local name="$1" pid bin out st wf
  pid=$(_hb_claude_pid "$name"); [[ -n "$pid" ]] || return 1
  bin="/home/agent-${name}/.local/bin/claude"
  [[ -x "$bin" ]] || return 1
  out=$(sudo -n -u "agent-${name}" "$bin" agents --json 2>/dev/null) || return 1
  [[ -n "$out" ]] || return 1
  st=$(jq -r --argjson p "$pid" '.[] | select(.pid==$p) | .status // empty' <<<"$out" 2>/dev/null) || return 1
  [[ -n "$st" ]] || return 1
  if [[ "$st" == "waiting" ]]; then
    wf=$(jq -r --argjson p "$pid" '.[] | select(.pid==$p) | .waitingFor // "input needed"' <<<"$out" 2>/dev/null)
    printf 'blocked:%s' "${wf:-input needed}"; return 0
  fi
  printf '%s' "$st"; return 0
}

# Is the agent at rest right now? Prefer the native `claude agents --json` signal
# (reliable, and it can tell a *blocked* agent apart from a working one); fall
# back to the dumb pane-scrape for non-claude CLIs or when the native signal is
# unavailable. Pane-scrape: sample the pane twice across a short gap — an idle
# agent's pane is byte-identical and shows its input prompt; a working one streams
# output / animates, so the two samples differ.
#
# Exit: 0 = idle, 1 = working/active, 2 = unknown (no signal), 3 = blocked
# (waiting on a permission prompt / dialog / input — native-only). When it
# returns 3 it also sets _HB_IDLE_REASON to the block reason for the caller to
# surface. Callers that must not clobber live work defer on 1 OR 3; reclaim-on-idle
# acts only on a confident 0 (a blocked agent is not idle, so it is never reclaimed).
_HB_IDLE_REASON=""
_hb_agent_idle() {
  local name="$1" gap="${2:-$_HB_IDLE_SAMPLE_SEC}"
  _HB_IDLE_REASON=""
  # Native signal first — when present it is authoritative and needs no sampling.
  local native; native=$(_hb_agent_native_state "$name") || native=""
  case "$native" in
    idle)       return 0 ;;
    busy)       return 1 ;;
    blocked:*)  _HB_IDLE_REASON="${native#blocked:}"; return 3 ;;
  esac
  # Fallback: pane-scrape (codex/grok/agy/opencode, or native unavailable).
  local user="agent-${name}" a b
  a=$(sudo -u "$user" tmux capture-pane -p -t "agent-${name}" 2>/dev/null) || return 2
  [[ -n "$a" ]] || return 2
  sleep "$gap"
  b=$(sudo -u "$user" tmux capture-pane -p -t "agent-${name}" 2>/dev/null) || return 2
  [[ "$a" == "$b" ]] || return 1
  # DIVE-1211: the idle-prompt marker is per-runtime. "❯" is CLAUDE's composer
  # glyph only — codex/grok/agy/opencode never render it, so the old hardcoded
  # `grep -q ❯` read every non-claude agent as active FOREVER (byte-stable pane,
  # no ❯ -> return 1) and the heartbeat deferred their nudge every tick, so
  # non-claude agents were never woken to work their board tasks. Byte-stability
  # above is a solid at-rest signal; this marker is the guard that a byte-stable
  # pane is genuinely parked at the composer, not frozen on a permission dialog
  # or a stalled mid-turn (same reason claude required ❯ on top of stability).
  # For a runtime whose idle glyph we haven't verified live, we trust stability
  # alone rather than guess a marker (a wrong marker would re-break idle for it).
  local marker; marker=$(_hb_idle_marker "$(agent_type "$name" 2>/dev/null)")
  [[ -z "$marker" ]] || grep -qF "$marker" <<<"$b" || return 1
  return 0
}

# DIVE-1211: a runtime's IDLE composer marker as a FIXED string (caller matches
# with grep -F), or empty for a runtime whose at-rest glyph hasn't been verified
# live (grok/opencode / unknown) -> callers fall back to byte-stability alone.
# Markers are the pane's ready-for-input signal and are TUI-specific so they
# can't collide: claude "❯", codex "›" (its "gpt-… default · <cwd>" status footer
# accompanies the same composer), antigravity "? for shortcuts" (its idle footer;
# "esc to cancel" is mid-turn and is deliberately NOT an idle marker). Verified
# against live codex/andy + agy panes 2026-07-14. Mirrors wait_agent_input_ready
# (cmd_agent_runtime.sh), but idle-only: it excludes agy's mid-turn "esc to
# cancel" that a *readiness* probe tolerates, so a working agent can't false-read
# as idle here.
_hb_idle_marker() {
  case "$1" in
    claude)       printf '❯' ;;
    codex)        printf '›' ;;
    antigravity)  printf '? for shortcuts' ;;
    *)            printf '' ;;  # grok/opencode/unknown: byte-stability alone
  esac
}

# Resolve a task's DISPLAY ident (e.g. DIVE-560) from its numeric row id. With
# the projects primitive (DIVE-484) the global row id and the per-project display
# number diverge once any non-default project consumes ids, so a goal/nudge built
# from the raw id points at a phantom (e.g. row 570 is really DIVE-560). Every
# agent-facing or logged DIVE-N MUST go through here; the numeric id stays the DB
# and registry key. Falls back to DIVE-<id> if the row vanished, so logs never
# print empty.
_hb_ident() {
  local id="$1" ident
  ident=$(db "SELECT ident FROM tasks WHERE id=${id};" 2>/dev/null) || ident=""
  echo "${ident:-DIVE-${id}}"
}

# Flip one in_progress task back to todo. Clears started_at so its age and the
# per-task nudge counter both restart cleanly, and stamps updated_at. Best-effort
# (a dead db or already-moved task is harmless). Logs why.
_hb_reclaim_to_todo() {
  local name="$1" id="$2" why="$3"
  db "UPDATE tasks SET status='todo', started_at=NULL, updated_at=datetime('now')
      WHERE id=${id} AND status='in_progress';" 2>/dev/null || true
  _hb_log "[$name] reclaimed $(_hb_ident "$id") -> todo ($why)"
}

# Unwedge this agent's stuck in_progress tasks. Three escalating rules, cheapest
# first, so a single stalled task can't block an agent's whole queue for hours:
#
#   (a) orphan-by-restart  -> todo. The claude process that would be doing the
#       work started AFTER the task did, so the session that claimed it is gone
#       (rotation/restart/crash/context-reset). Deterministic, instant — this is
#       the common case and needs no idle guessing.
#   (b) idle stall         -> todo. Same process still running, but the task has
#       sat in_progress past _HB_STALL_MIN_MINUTES AND the agent is idle now:
#       it claimed the task then walked away. Gated on a confident idle reading
#       so we never reclaim work that's actively in flight.
#   (c) hard cap           -> requeue, then escalate on repeat. in_progress past
#       everyMin*_HB_STALE_MULT (floored): the runaway backstop. /goal clear to
#       stop any loop, then reclaim to todo — NEVER cancel, since that silently
#       loses real mid-flight work (DIVE-482/200). A task that keeps overrunning
#       even after a clean requeue is genuinely stuck: on the
#       _HB_REAP_ESCALATE_AFTER'th reap, block it + escalate (ping owner & human)
#       so it's visible, not churning — still never auto-cancelled.
#
# (a)/(b)/(c) all reclaim the work (it still needs doing); (c) additionally
# escalates a repeat offender. Nothing is ever cancelled here. Echoes
# "<reclaimed> <escalated>". Uses started_at (falls back to created_at).
_hb_reclaim() {
  local name="$1" everyMin="$2"
  local budget=$(( everyMin * _HB_STALE_MULT ))
  (( budget < _HB_STALE_MIN_MINUTES )) && budget=$_HB_STALE_MIN_MINUTES
  local proc_start; proc_start=$(_hb_claude_started "$name" 2>/dev/null || true)
  local reclaimed=0 escalated=0 id started_epoch age_min
  while IFS='|' read -r id started_epoch age_min; do
    [[ -n "$id" ]] || continue
    # (a) the claiming session is gone — process is newer than the claim.
    if [[ -n "$proc_start" && -n "$started_epoch" ]] \
       && (( proc_start > started_epoch + _HB_PROC_SKEW_SEC )); then
      _hb_reclaim_to_todo "$name" "$id" "claiming session gone (claude restarted $(( (proc_start - started_epoch) / 60 ))m after the claim)"
      reclaimed=$((reclaimed + 1)); continue
    fi
    # (c) hard cap before stall: in_progress past the budget but rule (a) didn't
    # fire (the claiming process did NOT restart — e.g. an in-process /clear or
    # context reset ended the working session without a new pid) and rule (b)
    # got no confident idle reading. This used to CANCEL, silently losing real
    # mid-flight work (DIVE-482, DIVE-200). Never cancel: stop any runaway, then
    # requeue to a clean slate. A task that keeps overrunning even after a fresh
    # requeue is genuinely stuck → on the _HB_REAP_ESCALATE_AFTER'th reap, block
    # it + escalate (pings owner & paired human) so a person decides its fate.
    if (( age_min >= budget )); then
      _hb_send_line "$name" "/goal clear" || true
      local reap_n
      reap_n=$(with_registry_lock _hb_mark_reap "$name" "$id")
      if [[ "${reap_n:-0}" =~ ^[0-9]+$ ]] && (( reap_n >= _HB_REAP_ESCALATE_AFTER )); then
        db "UPDATE tasks SET status='blocked', updated_at=datetime('now'),
              result='auto-paused by heartbeat: overran the ${budget}m in_progress budget ${reap_n}x even after a clean requeue — needs a human to requeue or close. NEVER auto-cancelled.'
            WHERE id=${id} AND status='in_progress';" 2>/dev/null || true
        # Subshell-wrap: cmd_task_escalate may fail->exit on an edge case; a bare
        # call would kill the whole tick. It bumps priority + pings owner & human.
        ( cmd_task_escalate "$id" --from=heartbeat ) >/dev/null 2>&1 || true
        _hb_log "[$name] $(_hb_ident "$id") overran ${budget}m ${reap_n}x — blocked + escalated (NEVER cancelled)"
        escalated=$((escalated + 1)); continue
      fi
      _hb_reclaim_to_todo "$name" "$id" "overran ${budget}m budget (reap #${reap_n}) — requeued from a clean slate, NOT cancelled"
      reclaimed=$((reclaimed + 1)); continue
    fi
    # (b) idle stall — only if past grace AND a confident idle reading (rc 0).
    if (( age_min >= _HB_STALL_MIN_MINUTES )) && _hb_agent_idle "$name"; then
      _hb_reclaim_to_todo "$name" "$id" "idle ${age_min}m with the task still open (claimed then went idle)"
      reclaimed=$((reclaimed + 1)); continue
    fi
  done < <(db "SELECT id || '|' ||
                 strftime('%s', COALESCE(started_at, created_at)) || '|' ||
                 CAST((julianday('now') - julianday(COALESCE(started_at, created_at))) * 1440 AS INTEGER)
               FROM tasks
               WHERE assignee=$(sqlq "$name") AND status='in_progress';" 2>/dev/null || true)
  printf '%s %s\n' "$reclaimed" "$escalated"
}

# DIVE-992 (OSS-5 item 5) — Recall. Compact, single-line citation of the memory
# hits most relevant to the task being nudged. Search is cheap, so every tick we
# inject the top-k "slug › heading" pointers into the /goal prompt: the agent
# starts the task already knowing which memories to expand (with `5dive memory
# search`) instead of rediscovering them. Best-effort by construction — any
# failure (no node, no stores, no query, zero hits) yields the empty string and
# NEVER blocks the nudge. Single line by construction: the nudge is one tmux
# send-keys line, so we join hits with "; " and strip newlines.
_hb_recall_cite() {
  local name="$1" query="$2" k="${3:-3}"
  [[ -n "$query" ]] || { echo ""; return 0; }
  command -v node >/dev/null 2>&1 || { echo ""; return 0; }
  local out=""
  # --agent scopes the target agent's own 0600 store (we run as root here) plus
  # the shared wiki (store=all default) — exactly the agent's own recall surface.
  out=$(_memory_search "$query" --agent="$name" --limit="$k" --max-tokens=300 2>/dev/null) || out=""
  [[ -n "$out" ]] || { echo ""; return 0; }
  # Keep only the "[score] relpath › heading" provenance lines; drop the score,
  # cap to k, one line. `|| true` so a no-match grep can't trip set -e.
  local cites
  cites=$(printf '%s\n' "$out" \
            | grep -oE '^\[[0-9.]+\] .+' \
            | sed -E 's/^\[[0-9.]+\] +//' \
            | head -n "$k" \
            | paste -sd '@' - 2>/dev/null) || cites=""
  # Flatten any stray newlines and turn the join marker into "; ".
  cites=$(printf '%s' "$cites" | tr '\n' ' ' | sed 's/@/; /g')
  echo "$cites"
}

# DIVE-992 (OSS-5 item 2) — Compile. Does this task look research/knowledge-
# shaped? If so, the tick nudge gains a "compile before you close" line so the
# karpathy method becomes a RUNTIME behavior (injected into the tick) rather than
# a convention that rots in chat. Keyword sniff over title+body — deliberately
# broad; a false positive just adds one reminder line.
_hb_is_knowledge_task() {
  local text="$1"
  printf '%s' "$text" \
    | grep -qiE 'research|digest|competitor|market (scan|intel|research)|\bintel\b|analy[sz]|\bfindings\b|survey|benchmark|landscape|write-?up|\bwiki\b|knowledge|investigat|\brecap\b|\bstudy\b'
}

# Wake one agent: ensure it's running, optionally clear context, send the nudge.
# $3 is the concrete DIVE id (highest-priority todo) the tick picked for this
# agent — scoping the /goal to one known id makes its completion check reliable
# (a freeform "your tasks" condition is ambiguous to the goal evaluator).
# Returns 0 on a delivered nudge, nonzero on any failure (so the caller skips
# marking lastRunAt and retries next tick).
_hb_wake() {
  local name="$1" fresh="$2" task_id="$3" task_ident="${4:-DIVE-$3}"
  # DIVE-1475 status guard: never inject a /goal for a task that isn't actionable.
  # The tick's picker (_hb_pick_task) only ever hands us a live todo, but the direct
  # `heartbeat wake-task` verb — and any buggy or looping caller (e.g. a test harness
  # walking ascending ids against the live host) — can pass a done/cancelled/
  # nonexistent id, and every such call would otherwise spam a bogus /goal into a
  # real agent's pane. Refuse here, the single choke point for ALL wake paths, so a
  # stale or fabricated id is a logged no-op instead of a live goal. A non-numeric
  # id or an absent row yields an empty status -> skip. Returns 0 (handled, not a
  # retriable failure); the tick never reaches this since its pick is always a live
  # todo, so legitimate wakes are unaffected.
  if ! [[ "$task_id" =~ ^[0-9]+$ ]]; then
    _hb_log "[$name] wake skipped — non-numeric task id '${task_id}'; no /goal injected"
    return 0
  fi
  local _wt_status
  _wt_status=$(db "SELECT status FROM tasks WHERE id=${task_id};" 2>/dev/null || echo "")
  if [[ -z "$_wt_status" || "$_wt_status" == "done" || "$_wt_status" == "cancelled" ]]; then
    _hb_log "[$name] wake skipped — ${task_ident} is ${_wt_status:-nonexistent}, not actionable; no /goal injected"
    return 0
  fi
  if ! systemctl is-active --quiet "5dive-agent@${name}.service"; then
    systemctl start "5dive-agent@${name}.service" 2>/dev/null \
      || { _hb_log "[$name] systemctl start failed"; return 1; }
    local i
    for ((i = 0; i < 30; i++)); do
      sudo -u "agent-${name}" tmux has-session -t "agent-${name}" 2>/dev/null && break
      sleep 2
    done
  fi
  sudo -u "agent-${name}" tmux has-session -t "agent-${name}" 2>/dev/null \
    || { _hb_log "[$name] no tmux session after start"; return 1; }

  if [[ "$fresh" == "true" ]]; then
    _hb_send_line "$name" "/clear" || { _hb_log "[$name] /clear failed"; return 1; }
    sleep 4
  fi

  # Issue a /goal scoped to the one task: Claude Code loops turns until the goal
  # evaluator sees the condition met, then auto-clears. "stop after N turns" is a
  # soft, model-judged guard — it does NOT reliably halt a runaway loop, so the
  # real hard cap is the deterministic stale-in_progress reaper in the tick.
  local nudge="/goal Task ${task_ident} shows status done or cancelled, or is blocked with a human gate filed, on the 5dive board (verify ONLY by running: 5dive task show ${task_ident}). To achieve it: claim it with '5dive task start ${task_ident}', do the work, then close it with '5dive task done ${task_ident} --result=\"<one or two self-contained sentences — any output the creator needs to see; the dashboard and creator read this>\"'. If it needs a human decision, approval, a secret, or a manual step only a person can do, do NOT cancel — file a gate that pings the owner: '5dive task need ${task_ident} --type=decision --ask=\"<what you need from them>\"' (use --type=approval|secret|manual as fits). Keep the ask to ONE crisp question + ~1 line of essential context — put heavy detail in the task BODY, not the ask — and ALWAYS surface your recommended choice with --recommend=\"<option>\" (and --options=A|B for a decision) so the owner sees the advised answer first. Only if the task is genuinely irrelevant or impossible, run '5dive task cancel ${task_ident} --result=\"<why>\"'. Before you close (done or cancel), run a fast self-audit — (a) what am I least confident about here, and (b) what did I NOT check or leave missing? If either surfaces a real gap, fix it or file a gate instead of closing silently; otherwise close. Work ONLY this one task — do not start any other. Stop after 6 turns."

  # DIVE-992: enrich the tick prompt from the shared seam. Pull the task's
  # title+body once, then (a) cite the most relevant memory hits so the agent
  # starts warm, and (b) if it looks knowledge-shaped, remind it to compile
  # before closing. Both are best-effort — a failure here must never block the
  # nudge, so each is guarded and flattened to keep the nudge a single line.
  local task_text="" recall="" compile_hint=""
  task_text=$(db "SELECT COALESCE(title,'') || ' ' || COALESCE(body,'') FROM tasks WHERE id=${task_id};" 2>/dev/null | tr '\n' ' ') || task_text=""
  if [[ -n "$task_text" ]]; then
    recall=$(_hb_recall_cite "$name" "$task_text" 3) || recall=""
    if _hb_is_knowledge_task "$task_text"; then
      compile_hint=" This task looks knowledge-shaped: before you close it, COMPILE the durable, non-obvious findings to the team wiki per the karpathy method (compile-knowledge skill, or '5dive memory add --store=wiki' + an index line) — compiling is part of done, not a separate chore."
    fi
  fi
  [[ -n "$recall" ]] && nudge="${nudge} Relevant memory to check first (verify before relying; re-search with '5dive memory search'): ${recall}."
  [[ -n "$compile_hint" ]] && nudge="${nudge}${compile_hint}"

  _hb_send_line "$name" "$nudge" || { _hb_log "[$name] nudge send failed"; return 1; }
  return 0
}

# DIVE-138 step 2: materialize due recurring TEMPLATES into standard todos. Runs
# as its own pass at the TOP of the tick (before the wake loop) so a freshly
# cloned todo is eligible to be picked up in the SAME tick. The caller isolates
# it (|| log) so a materializer failure can NEVER abort the wake loop — the
# heartbeat-never-woke bug class.
#
# For each kind='recurring' template: fire when its cron matches `now` AND it
# hasn't already fired THIS minute (last_fired_at guard — stops a double-fire if
# two ticks land in the same matching minute). DEDUP (skip-if-open): don't
# materialize if an unfinished instance from this template already exists, so
# dailies don't pile up when the assignee is behind. On fire: clone
# title/body/priority/assignee/created_by/fresh into a kind='standard' todo
# stamped with from_template_id, then stamp the template's last_fired_at.
#
# V1 LIMITATION: no catch-up for ticks the host missed — if the box was down over
# a scheduled minute, that occurrence is skipped, not backfilled. Acceptable for
# coarse (daily/hourly) recurring jobs; minute granularity finer than the tick
# interval can also be missed. Both documented in the CHANGELOG.
_hb_materialize_recurring() {
  local now="$1" minute_start tid sched last_fired open n_made=0
  minute_start=$(date -u -d "@${now}" +'%Y-%m-%d %H:%M:00')
  while IFS=$'\t' read -r tid sched last_fired; do
    [[ -n "$tid" ]] || continue
    _cron_matches "$sched" "$now" || continue
    # Already fired this minute? (string compare on ISO 'YYYY-MM-DD HH:MM:SS';
    # last_fired >= minute_start means a tick already materialized it this minute.)
    if [[ -n "$last_fired" ]] && ! [[ "$last_fired" < "$minute_start" ]]; then
      continue
    fi
    open=$(db "SELECT COUNT(*) FROM tasks WHERE from_template_id=${tid} AND status NOT IN ('done','cancelled');" 2>/dev/null || echo 1)
    if [[ "${open:-1}" != "0" ]]; then
      _hb_log "[materializer] $(_hb_ident "$tid") due but an open instance exists — skip"
      continue
    fi
    if db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, from_template_id, fresh)
           SELECT title, body, priority, assignee, created_by, 'standard', id, fresh FROM tasks WHERE id=${tid};
           UPDATE tasks SET last_fired_at=datetime('now') WHERE id=${tid};" >/dev/null 2>&1; then
      n_made=$((n_made + 1)); _hb_log "[materializer] $(_hb_ident "$tid") fired -> new standard todo"
    else
      _hb_log "[materializer] $(_hb_ident "$tid") insert failed"
    fi
  done < <(db "SELECT id, schedule, COALESCE(last_fired_at,'') FROM tasks WHERE kind='recurring' AND schedule IS NOT NULL;" 2>/dev/null | tr '|' '\t')
  _hb_log "[materializer] pass done — ${n_made} materialized"
  return 0
}

# DIVE-891 (adopted design DIVE-861): the gate TTL + wake sweep. Three passes,
# all cheap sqlite scans, run once per tick in root context:
#   (1) WAKE — a parked task whose wake_at passed unparks back to todo, so the
#       wake loop below can hand it to its agent THIS tick.
#   (2) T1 TTL — a tier-1 gate unanswered for 48h gets its recommendation
#       applied. Provenance is 'auto:ttl' + uid 0 and the closure IS signed
#       (root context) so gate-proof verify explains it rather than flagging a
#       raw-sqlite forgery. Deliberately NEVER: secret gates (nothing to
#       apply), loop gate steps (a relay must not advance on a timeout — and
#       _task_loop_advance requires human:* anyway), rows without a
#       recommendation, or rows without a real need_asked_at stamp (legacy
#       gates predate the column; never auto-apply on a fuzzy clock — they're
#       tier NULL = treated as tier 2 regardless).
#   (3) T2 REMINDER — tier-2 (or legacy NULL-tier, or rec-less tier-1) gates
#       stale for 72h batch into ONE message per filing agent's channel,
#       manual asks grouped as a "15 minutes" block. gate_pinged_at throttles
#       the batch to weekly. Never auto-applies, never expires.
# Isolated by the caller (|| log) — a sweep failure must never abort the wake
# loop (the heartbeat-never-woke bug class).
_hb_gate_ttl_sweep() {
  local tid
  # (1) wake parked
  while IFS= read -r tid; do
    [[ -n "$tid" ]] || continue
    db "UPDATE tasks SET parked_at=NULL, park_reason=NULL, wake_at=NULL,
          status=CASE WHEN status='blocked'
                       AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${tid})
                      THEN 'todo' ELSE status END
        WHERE id=${tid};"
    _hb_log "[gate-ttl] $(_hb_ident "$tid") wake_at passed -> unparked"
  done < <(db "SELECT id FROM tasks
               WHERE parked_at IS NOT NULL AND wake_at IS NOT NULL
                 AND wake_at <= datetime('now') AND status NOT IN ('done','cancelled');")

  # (2) T1 48h TTL -> apply the recommendation
  local grow gid gtype grec gowner gident
  while IFS= read -r grow; do
    [[ -n "$grow" ]] || continue
    IFS=$'\x1f' read -r gid gtype grec gowner <<<"$grow"
    [[ -n "$gid" && -n "$grec" ]] || continue
    gident=$(_hb_ident "$gid")
    local _ts; _ts=$(date -u '+%Y-%m-%d %H:%M:%S')
    _gate_proof_ensure_key 2>/dev/null || true
    local _sig; _sig=$(_gate_closure_sign "$gid" "$gtype" "$grec" "auto:ttl" "$_ts" "0" 2>/dev/null || echo "")
    db "UPDATE tasks SET need_answer=$(sqlq "$grec"), need_answered_at=$(sqlq "$_ts"),
          need_answered_by='auto:ttl', need_answered_uid=0, need_answer_sig=$(sqlq "$_sig")
        WHERE id=${gid};
        UPDATE tasks SET status='todo'
          WHERE id=${gid} AND status='blocked'
            AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${gid});"
    audit_log "gate ttl-auto" "ok" 0 -- "task=$gident" "type=$gtype" "applied=$grec" || true
    [[ -n "$gowner" ]] && ( cmd_send "$gowner" --message="⏱ ${gident} tier-1 gate hit its 48h TTL — recommendation applied: ${grec}. Resume the task; run \`5dive task show ${gident}\`." ) >/dev/null 2>&1 || true
    _hb_log "[gate-ttl] ${gident} T1 48h TTL -> applied rec"
  done < <(db "SELECT id||x'1f'||need_type||x'1f'||COALESCE(recommend,'')||x'1f'||COALESCE(assignee,'')
               FROM tasks
               WHERE need_type IS NOT NULL AND need_answered_at IS NULL
                 AND tier=1 AND recommend IS NOT NULL AND need_type != 'secret'
                 AND need_asked_at IS NOT NULL AND need_asked_at <= datetime('now','-48 hours')
                 AND (body IS NULL OR body NOT LIKE '%${_LOOP_MARK}:%')
                 AND status NOT IN ('done','cancelled');")

  # (3) T2 stale-gate reminder batches, one message per filing agent's channel.
  # Age clock: COALESCE(need_asked_at, updated_at) — legacy gates predate
  # need_asked_at; updated_at is a fine fuzzy clock when the worst case is a
  # reminder. The stale filter (need_answered_at IS NULL etc.) matches the
  # canonical inbox definition.
  local _t2_where="need_type IS NOT NULL AND need_answered_at IS NULL
                 AND (tier IS NULL OR tier=2 OR (tier=1 AND recommend IS NULL))
                 AND COALESCE(need_asked_at, updated_at) <= datetime('now','-72 hours')
                 AND (gate_pinged_at IS NULL OR gate_pinged_at <= datetime('now','-7 days'))
                 AND status NOT IN ('done','cancelled')"
  local aname
  while IFS= read -r aname; do
    [[ -n "$aname" ]] || continue
    _task_agent_channel "$aname" || continue
    local lines_main lines_manual reminder_ids
    reminder_ids=$(db "SELECT id FROM tasks WHERE ${_t2_where} AND assignee=$(sqlq "$aname")
                       ORDER BY COALESCE(need_asked_at,updated_at),id;" | paste -sd, -)
    lines_main=$(db "SELECT '• /task_'||id||' ['||ident||'] '||need_type||', '||CAST(julianday('now')-julianday(COALESCE(need_asked_at,updated_at)) AS INT)||'d — '||substr(replace(COALESCE(ask,''), x'0a', ' '),1,90)
                     FROM tasks WHERE ${_t2_where} AND assignee=$(sqlq "$aname") AND need_type != 'manual'
                     ORDER BY COALESCE(need_asked_at,updated_at);")
    lines_manual=$(db "SELECT '• /task_'||id||' ['||ident||'] '||CAST(julianday('now')-julianday(COALESCE(need_asked_at,updated_at)) AS INT)||'d — '||substr(replace(COALESCE(ask,''), x'0a', ' '),1,90)
                       FROM tasks WHERE ${_t2_where} AND assignee=$(sqlq "$aname") AND need_type = 'manual'
                       ORDER BY COALESCE(need_asked_at,updated_at);")
    [[ -n "$lines_main" || -n "$lines_manual" ]] || continue
    local text="⏳ Gate backlog — these have been waiting on you 3+ days:"
    [[ -n "$lines_main" ]] && text+=$'\n'"$lines_main"
    [[ -n "$lines_manual" ]] && text+=$'\n\n'"🛠 Manual steps — one ~15-min batch clears these:"$'\n'"$lines_manual"
    text+=$'\n\n'"Answer from the original alert's buttons, the dashboard, or tap a /task link. Re-pings weekly until answered."
    _task_send_owner "$text" "" "$reminder_ids" || true
    # OSS-12: SLA escalation — walk the org chart. If any of this agent's stale
    # gates has aged past _HB_GATE_ESCALATE_DAYS, also loop in its org-chart
    # parent (agents_org.reports_to) so the gate escalates up the chain instead
    # of stalling on one recipient. Rides this same weekly gate_pinged_at
    # throttle (computed before the UPDATE below). One level (immediate manager);
    # never auto-answers — a human still clears the gate.
    local _mgr _esc_lines
    _mgr=$(db "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$aname");")
    if [[ -n "$_mgr" && "$_mgr" != "$aname" ]] && _task_agent_channel "$_mgr"; then
      _esc_lines=$(db "SELECT '• ['||ident||'] '||need_type||', '||CAST(julianday('now')-julianday(COALESCE(need_asked_at,updated_at)) AS INT)||'d — '||substr(replace(COALESCE(ask,''), x'0a', ' '),1,90)
                       FROM tasks WHERE ${_t2_where} AND assignee=$(sqlq "$aname")
                         AND COALESCE(need_asked_at, updated_at) <= datetime('now','-${_HB_GATE_ESCALATE_DAYS} days')
                       ORDER BY COALESCE(need_asked_at,updated_at);")
      if [[ -n "$_esc_lines" ]]; then
        ( cmd_send "$_mgr" --message="⏫ Gate escalation — your report ${aname} has gate(s) unanswered ${_HB_GATE_ESCALATE_DAYS}d+, still stalling their lane:"$'\n'"${_esc_lines}"$'\n\n'"Help chase the answer or re-scope. Not auto-resolved — a human still clears it." ) >/dev/null 2>&1 || true
        _hb_log "[gate-ttl] escalated ${aname}'s stale gate(s) to org-parent ${_mgr}"
      fi
    fi
    if [[ "${TASK_SEND_DELIVERED:-0}" == "1" ]]; then
      _hb_log "[gate-ttl] stale-gate reminder batch delivered for $aname; message_id=${TASK_SEND_MESSAGE_IDS:-unknown}"
    else
      _hb_log "[gate-ttl] stale-gate reminder delivery unconfirmed for $aname; receipt left unchanged"
    fi
  done < <(db "SELECT DISTINCT COALESCE(assignee,'') FROM tasks WHERE ${_t2_where};")
  return 0
}

# DIVE-1490: receipt-backed gate re-nags. A freshly filed gate gets one follow-
# up after 1h; once a follow-up has been delivered, subsequent reminders are
# 24h apart. Migration-free: gate_pinged_at is both the delivery receipt and
# throttle stamp. An initial receipt is identifiable because it is before
# need_asked_at+1h; a re-nag receipt is at/after that boundary. Failed sends are
# deliberately NOT stamped, so the next heartbeat retries instead of silently
# dropping the gate. T2 uses the filing agent's paired-human channel; T1 routes
# through the existing org-lead resolver. One message/keyboard is built per
# resolved recipient, regardless of how many gates are due.
_HB_GATE_RENAG_WHERE="need_type IS NOT NULL AND need_answered_at IS NULL
  AND status NOT IN ('done','cancelled') AND COALESCE(tier,2) != 0
  AND COALESCE(need_asked_at,updated_at,created_at) <= datetime('now','-1 hour')
  AND NOT (tier=1 AND recommend IS NOT NULL
           AND COALESCE(need_asked_at,updated_at,created_at) <= datetime('now','-48 hours'))
  AND (gate_pinged_at IS NULL
       OR gate_pinged_at < datetime(COALESCE(need_asked_at,updated_at,created_at),'+1 hour')
       OR gate_pinged_at <= datetime('now','-24 hours'))"

_hb_gate_renag_batch() { # <recipient_agent> <comma-separated task ids> <route_label>
  local recipient="$1" idlist="$2" route_label="$3"
  [[ -n "$recipient" && "$idlist" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 0
  if ! _task_agent_channel "$recipient"; then
    warn "gate re-nag for task rows ${idlist}: recipient ${recipient} has no paired channel; will retry next heartbeat"
    _hb_log "[gate-renag] recipient ${recipient} has no paired channel for rows ${idlist}"
    return 0
  fi

  local text="🔁 Gate reminder — unanswered gates (${route_label}):"
  local rows='[]' row id ident ntype options recommend ask nonce="" markup=""
  local -a nonce_ids=() nonce_hashes=()
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS=$'\x1f' read -r id ident ntype options recommend ask <<<"$row"
    [[ -n "$id" && -n "$ident" ]] || continue
    text+=$'\n\n'"• [${ident}] ${ntype} — ${ask} /task_${id}"
    [[ -n "$recommend" ]] && text+=$'\n'"  ✅ Recommended: ${recommend}"
    [[ -n "$options" ]] && text+=$'\n'"  Options: ${options}"

    nonce=""
    case "$ntype" in
      approval|secret|manual)
        nonce=$(_human_nonce_mint)
        if [[ -n "$nonce" ]]; then
          nonce_ids+=("$id")
          nonce_hashes+=("$(_human_nonce_sha "$nonce")")
        fi
        ;;
    esac
    markup=$(_task_gate_reply_markup "$id" "$ntype" "$options" "$recommend" "$nonce" "$TASK_CH_TYPE" "$ident")
    if [[ -n "$markup" ]]; then
      rows=$(jq -cn --argjson a "$rows" --argjson b "$markup" '$a + ($b.inline_keyboard // [])' 2>/dev/null) || rows='[]'
    fi
  done < <(db "SELECT id||x'1f'||ident||x'1f'||need_type||x'1f'||COALESCE(need_options,'')||x'1f'||COALESCE(recommend,'')||x'1f'||substr(replace(COALESCE(ask,''),x'0a',' '),1,240)
               FROM tasks WHERE id IN (${idlist}) ORDER BY COALESCE(need_asked_at,updated_at,created_at),id;")

  local reply_markup=""
  [[ "$rows" != "[]" ]] && reply_markup=$(jq -cn --argjson rows "$rows" '{inline_keyboard:$rows}' 2>/dev/null) || true
  text+=$'\n\n'"Tap a button, open /task links, or answer from the dashboard. First reminder is after 1h; later reminders are batched every 24h until answered."
  _task_send_owner "$text" "$reply_markup" "$idlist"
  if [[ "${TASK_SEND_DELIVERED:-0}" == "1" ]]; then
    # Do not invalidate the original alert's nonce until the new button-bearing
    # message has a confirmed receipt. The tiny post-ack/update interval is far
    # safer than rotating the hash before a send that may never land.
    local i
    for (( i=0; i<${#nonce_ids[@]}; i++ )); do
      db "UPDATE tasks SET human_nonce_hash=$(sqlq "${nonce_hashes[$i]}")
          WHERE id=${nonce_ids[$i]} AND need_answered_at IS NULL;" 2>/dev/null || true
    done
    _hb_log "[gate-renag] delivered ${idlist} via ${recipient}; message_id=${TASK_SEND_MESSAGE_IDS:-unknown}"
  else
    _hb_log "[gate-renag] delivery unconfirmed for ${idlist} via ${recipient}; receipt left unchanged"
  fi
  return 0
}

_hb_gate_renag_sweep() {
  [[ "${FIVEDIVE_GATE_RENAG:-1}" != "0" ]] || return 0
  local owner ids

  # T2/legacy hard-human gates: one batch per filing agent's bot. Different bots
  # cannot be collapsed into one Telegram request, so this is the smallest real
  # push cardinality while preserving channel ownership.
  while IFS= read -r owner; do
    [[ -n "$owner" ]] || continue
    ids=$(db "SELECT id FROM tasks WHERE ${_HB_GATE_RENAG_WHERE}
              AND COALESCE(tier,2)=2
              AND COALESCE(NULLIF(created_by,''),assignee,'')=$(sqlq "$owner")
              ORDER BY COALESCE(need_asked_at,updated_at,created_at),id;" | paste -sd, -)
    [[ -n "$ids" ]] && _hb_gate_renag_batch "$owner" "$ids" "paired human"
  done < <(db "SELECT DISTINCT COALESCE(NULLIF(created_by,''),assignee,'') FROM tasks
               WHERE ${_HB_GATE_RENAG_WHERE} AND COALESCE(tier,2)=2;")

  # T1 gates: group by the existing routed reviewer / org-lead resolution. A
  # lead's own T1 gate uses the coordinator/root channel instead of escalating
  # to the paired-human lane reserved for T2.
  local grow gid filer reviewer routed
  declare -A lead_ids=()
  while IFS= read -r grow; do
    [[ -n "$grow" ]] || continue
    IFS=$'\x1f' read -r gid filer routed <<<"$grow"
    reviewer="$routed"
    [[ -n "$reviewer" ]] || reviewer=$(_gate_route_reviewer "$filer")
    [[ -n "$reviewer" ]] || reviewer=$(_task_resolve_coordinator)
    if [[ -z "$reviewer" ]]; then
      warn "gate re-nag for task row ${gid}: no org lead resolved; will retry next heartbeat"
      _hb_log "[gate-renag] no org lead for T1 row ${gid} (filer=${filer:-unknown})"
      continue
    fi
    lead_ids[$reviewer]+="${lead_ids[$reviewer]:+,}${gid}"
  done < <(db "SELECT id||x'1f'||COALESCE(NULLIF(created_by,''),assignee,'')||x'1f'||COALESCE(routed_reviewer,'')
               FROM tasks WHERE ${_HB_GATE_RENAG_WHERE} AND tier=1
               ORDER BY COALESCE(need_asked_at,updated_at,created_at),id;")
  for reviewer in "${!lead_ids[@]}"; do
    _hb_gate_renag_batch "$reviewer" "${lead_ids[$reviewer]}" "org lead"
  done
  return 0
}

# DIVE-1140: gate-shipped flag sweep. A human gate (approval/decision/manual)
# does NOT auto-close when the underlying fix merges, so the overnight recap
# (DIVE-217/1138) surfaces 'ghost' gates on already-shipped work. This sweep, per
# tick, scans each configured repo's origin/main for a commit referencing an OPEN
# gate's ident; on a hit it FLAGS the gate (stamp shipped_flag_at + ping the
# owner "likely shipped, verify+close"). Flag-only for ALL tiers (lodar
# 2026-07-12): a merge is not a human sign-off (DIVE-555) and a commit may only
# partially fix a gate, so it NEVER auto-answers/closes — a human still clears it.
# shipped_flag_at throttles to one flag per gate. Same isolation contract as the
# other sweeps (caller wraps in `|| log`): a failure must never abort the wake
# loop. Factored git lookup (_hb_repo_grep_ident) so the unit test can stub it.
#
# Look for <ident> on <repo>'s configured ref; echo "<repo> <sha> <subject>" on a
# hit, nothing otherwise. Digit-boundary match so DIVE-114 doesn't match
# DIVE-1140. Best-effort: a missing repo/ref is silently skipped.
_hb_repo_grep_ident() {  # <repo-stem> <ident>
  local repo="$1" ident="$2" dir="${_HB_REPO_BASE}/$1" line
  [[ -d "$dir/.git" || -f "$dir/.git" ]] || return 1
  line=$(git -C "$dir" log "$_HB_GATE_SHIPPED_REF" -E \
           --grep="${ident}([^0-9]|\$)" --format='%h %s' -1 2>/dev/null) || return 1
  [[ -n "$line" ]] || return 1
  printf '%s %s\n' "$repo" "$line"
}

# DIVE-1355 — the safety half of the self-dispatch fix. Two passes, both cheap
# sqlite scans, isolated by the caller (|| log) like every other tick sweep:
#
#  (a) AUTO-RECOVER: a task still 'blocked' whose EVERY blocking edge points to a
#      done/cancelled task. The live cascade (_task_cascade_unblock) handles this
#      the moment a blocker closes; this pass repairs anything it missed — most
#      importantly PRE-EXISTING rot (OSS-27 blocked_by an OSS-26 that finished
#      before the cascade existed). Drop the satisfied edges + flip blocked->todo,
#      subject to the SAME guardrail: never a parked task, never an unanswered
#      human need-gate. Ping each freed assignee + one batched line to main.
#
#  (b) SURFACE (never auto-unblock): a task 'blocked' with NO live reason at all —
#      no dependency edge, no unanswered need-gate, no park. Tonight's audit found
#      most of ~56 blocked tasks are exactly this: manually blocked + forgotten.
#      The guardrail is "only dependency edges auto-clear", so these are only
#      FLAGGED to main (throttled to once/24h so it's not tick-spam), never flipped.
_hb_blocked_sweep() {
  local tid
  # (a) auto-recover: blocked, not parked, no pending human gate, HAS edges, and
  #     no edge points to a still-open blocker (=> every blocker done/cancelled).
  local -a rec=()
  while IFS= read -r tid; do
    [[ -n "$tid" ]] || continue
    db "DELETE FROM task_deps WHERE task_id=${tid};
        UPDATE tasks SET status='todo'
          WHERE id=${tid} AND status='blocked' AND parked_at IS NULL
            AND (need_type IS NULL OR need_answered_at IS NOT NULL);"
    [[ "$(db "SELECT status FROM tasks WHERE id=${tid};")" == "todo" ]] && rec+=("$tid")
  done < <(db "SELECT t.id FROM tasks t
               WHERE t.status='blocked' AND t.parked_at IS NULL
                 AND (t.need_type IS NULL OR t.need_answered_at IS NOT NULL)
                 AND EXISTS (SELECT 1 FROM task_deps d WHERE d.task_id=t.id)
                 AND NOT EXISTS (SELECT 1 FROM task_deps d JOIN tasks b ON b.id=d.blocked_by
                                 WHERE d.task_id=t.id AND b.status NOT IN ('done','cancelled'))
               ORDER BY t.id;")
  if [[ ${#rec[@]} -gt 0 ]]; then
    local idlist="" who dident
    for tid in "${rec[@]}"; do
      who=$(db    "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${tid};")
      dident=$(db "SELECT ident FROM tasks WHERE id=${tid};")
      idlist+="${dident} "
      [[ -n "$who" ]] && ( cmd_send "$who" --from="task-engine" \
          --message="▶️ Unblocked: ${dident} — all blockers done, now on your queue." ) >/dev/null 2>&1 || true
    done
    _hb_log "[blocked-sweep] auto-recovered: ${idlist}"
    ( cmd_send "main" --from="task-engine" \
        --message="🔧 Auto-recovered ${#rec[@]} stale-blocked task(s) whose blockers were all done: ${idlist}" ) >/dev/null 2>&1 || true
  fi

  # (b) surface no-live-reason blocks (never auto-unblock). Throttle to once/24h.
  local orphan; orphan=$(db "SELECT t.ident FROM tasks t
               WHERE t.status='blocked' AND t.parked_at IS NULL
                 AND (t.need_type IS NULL OR t.need_answered_at IS NOT NULL)
                 AND NOT EXISTS (SELECT 1 FROM task_deps d WHERE d.task_id=t.id)
               ORDER BY t.id;" | tr '\n' ' ')
  if [[ -n "${orphan// }" ]]; then
    local last cutoff
    last=$(db "SELECT value FROM task_prefs WHERE key='blocked_sweep_pinged_at';" 2>/dev/null)
    cutoff=$(date -u -d '24 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
    if [[ -z "$last" || ( -n "$cutoff" && "$last" < "$cutoff" ) ]]; then
      ( cmd_send "main" --from="task-engine" \
          --message="⚠️ Blocked with no live reason (no open dependency, no human gate, no park) — likely manually blocked + forgotten. Unblock (5dive task unblock <id>) or cancel if dead: ${orphan}" ) >/dev/null 2>&1 || true
      db "INSERT INTO task_prefs (key,value) VALUES ('blocked_sweep_pinged_at', datetime('now'))
          ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now');"
      _hb_log "[blocked-sweep] surfaced no-reason blocked: ${orphan}"
    fi
  fi
  return 0
}

_hb_gate_shipped_sweep() {
  local grow gid gident gtype gowner repo hit
  # Normalize the repo allow-list: commas or spaces both separate.
  local repos; repos="${_HB_GATE_SHIPPED_REPOS//,/ }"
  [[ -n "${repos// }" ]] || return 0
  while IFS= read -r grow; do
    [[ -n "$grow" ]] || continue
    IFS=$'\x1f' read -r gid gident gtype gowner <<<"$grow"
    [[ -n "$gid" && -n "$gident" ]] || continue
    hit=""
    for repo in $repos; do
      hit=$(_hb_repo_grep_ident "$repo" "$gident") && [[ -n "$hit" ]] && break
      hit=""
    done
    [[ -n "$hit" ]] || continue
    db "UPDATE tasks SET shipped_flag_at=datetime('now') WHERE id=${gid};"
    audit_log "gate shipped-flag" "ok" 0 -- "task=$gident" "type=$gtype" "commit=$hit" || true
    _hb_log "[gate-shipped] ${gident} — commit on ${_HB_GATE_SHIPPED_REF} references it: ${hit} -> flagged"
    if [[ -n "$gowner" ]] && _task_agent_channel "$gowner"; then
      ( cmd_send "$gowner" --message="🚢 ${gident} — a commit referencing this open ${gtype} gate landed on ${_HB_GATE_SHIPPED_REF} (${hit}). Likely shipped: verify and close with \`5dive task show ${gident}\`. Auto-flag only — a merge is not a sign-off, so it stays open until you clear it." ) >/dev/null 2>&1 || true
    fi
  done < <(db "SELECT id||x'1f'||COALESCE(ident,'DIVE-'||id)||x'1f'||need_type||x'1f'||COALESCE(assignee,'')
               FROM tasks
               WHERE need_type IS NOT NULL AND need_answered_at IS NULL
                 AND shipped_flag_at IS NULL
                 AND status NOT IN ('done','cancelled');")
  return 0
}

# DIVE-1416: fleet-stall self-heal, gaps #2 and #3 (gap #1 is _hb_blocked_sweep
# above; DIVE-1415 extended it to every terminal close, not just done/cancel).
# DOGFOOD INCIDENT 2026-07-17: the fleet sat ~100% idle ~3h while actionable
# v0.10 work was stranded, and NOTHING self-corrected or alarmed — supervisor
# read "15 healthy / 0 stuck" because "idle while work sits open" wasn't a
# signal it modeled. Three isolated, independently-throttled passes, same
# `|| _hb_log` isolation contract as every other tick sweep:
#
#  (a) GAP#2 — surface a stale maker->verifier delivery. `_task_route_to_verifier`
#      re-queues the task as the verifier's own todo, which the verifier's
#      heartbeat wake normally picks up — but when that doesn't happen (verifier
#      not enrolled, its everyMin hasn't elapsed yet, wake skipped, wrong
#      channel…) the delivered work sits invisible with no independent signal.
#      Flag once per delivery (handoff_stale_pinged_at, reset on every fresh
#      handoff by _task_route_to_verifier) once it's sat past
#      _HB_VERIFY_STALE_MIN unacknowledged — ping BOTH the verifier (so they can
#      act) and main (so a human-visible trail exists even if the verifier is
#      itself unreachable).
#
#  (b) GAP#3 core — fleet-idle-while-actionable-work-is-open alarm. Zero agents
#      in_progress AND zero running loops (fleet-wide "nobody is doing
#      anything") while >=1 todo task sits assigned to someone, or >=1
#      fleet-actionable human gate sits open, is EXACTLY the incident: dead air
#      that reads as healthy. A gate only counts here if it's tier<=1 (an agent
#      can clear it — genuinely stranded) or never surfaced to the human at all
#      — a PINGED tier-2 gate awaiting the human overnight is legitimately
#      idle, not stranded, and must not re-alarm every cycle (that's the
#      idle-night alert-fatigue class this design already killed once).
#      Tracks how long the condition has persisted in task_prefs
#      (stall_first_seen_at) and only alarms once it's held for
#      _HB_STALL_MIN_MINUTES (the "K min" in the design) — a single idle tick
#      between tasks is normal, not a stall. Re-alarms every
#      _HB_STALL_MIN_MINUTES while it persists (never silent), clears its
#      tracking the moment the fleet is busy again or the backlog clears.
#
#  (c) GAP#3 canary — pinger liveness. DIVE-1434: the gate-ping TTL reminder
#      batch (the T2 pass in _hb_gate_ttl_sweep above) silently stopped writing
#      gate_pinged_at fleet-wide and nothing noticed for days. This check is
#      DELIBERATELY independent of that pass's own code path — a canary that
#      shares the suspect logic can go dark with it. It recomputes, from
#      scratch, whether any gate is eligible for a ping right now (same
#      staleness shape the reminder pass uses, given 30m grace past the 72h
#      mark so a brand-new eligibility isn't a false trip) and compares against
#      the fleet-wide MAX(gate_pinged_at). Eligible gates existing while no ping
#      has landed in over an hour means the batch looks dead — alarm main,
#      throttled to avoid re-alarming every tick while it stays broken.
_hb_stall_sweep() {
  # (a) GAP#2 — surface stale maker->verifier deliveries.
  local vrow vid vident vfier vdelivered vmins
  while IFS= read -r vrow; do
    [[ -n "$vrow" ]] || continue
    IFS=$'\x1f' read -r vid vident vfier vdelivered <<<"$vrow"
    [[ -n "$vid" && -n "$vfier" ]] || continue
    vmins=$(( ($(date -u +%s) - $(date -u -d "$vdelivered" +%s 2>/dev/null || date -u +%s)) / 60 ))
    ( cmd_send "$vfier" --from="task-engine" \
        --message="📥 ${vident} was delivered to you for review ${vmins}m ago and is still unacknowledged — run \`5dive task start ${vident}\` then \`task done\`/\`task reject\` so it doesn't rot in your queue." ) >/dev/null 2>&1 || true
    ( cmd_send "main" --from="task-engine" \
        --message="📥 Delivered-awaiting-verifier: ${vident} handed to '${vfier}' ${vmins}m ago, still unacknowledged — surfaced so it never sits invisible (DIVE-1416 gap#2)." ) >/dev/null 2>&1 || true
    db "UPDATE tasks SET handoff_stale_pinged_at=datetime('now') WHERE id=${vid};"
    _hb_log "[stall-sweep] ${vident} delivered->${vfier} unacked ${vmins}m -> surfaced"
  done < <(db "SELECT id||x'1f'||COALESCE(ident,'DIVE-'||id)||x'1f'||verifier||x'1f'||handoff_delivered_at
               FROM tasks
               WHERE verifier IS NOT NULL AND maker_agent IS NOT NULL
                 AND assignee=verifier AND status NOT IN ('done','cancelled')
                 AND handoff_ack_at IS NULL AND handoff_stale_pinged_at IS NULL
                 AND handoff_delivered_at IS NOT NULL
                 AND handoff_delivered_at <= datetime('now','-${_HB_VERIFY_STALE_MIN} minutes');")

  # (b) GAP#3 core — fleet-idle-while-actionable-work-is-open, persisting.
  local in_prog running_loops stranded_todo open_gates total_stranded
  in_prog=$(db "SELECT COUNT(*) FROM tasks WHERE status='in_progress' AND kind='standard';" 2>/dev/null || echo 0)
  running_loops=$(db "SELECT COUNT(*) FROM loop_runs WHERE status='running';" 2>/dev/null || echo 0)
  [[ "$in_prog" =~ ^[0-9]+$ ]] || in_prog=0
  [[ "$running_loops" =~ ^[0-9]+$ ]] || running_loops=0

  total_stranded=0
  if (( in_prog == 0 && running_loops == 0 )); then
    stranded_todo=$(db "SELECT COUNT(*) FROM tasks
                        WHERE status='todo' AND kind='standard'
                          AND assignee IS NOT NULL AND assignee != '';" 2>/dev/null || echo 0)
    # A gate is STRANDED-actionable (counts toward the alarm) only when it's
    # fleet-actionable (tier<=1, an agent can clear it) OR it has never been
    # surfaced to the human at all (need_asked_at AND gate_pinged_at both
    # NULL — a legacy/malformed row, since a normally-filed gate always stamps
    # need_asked_at at file time). A pinged tier-2 gate genuinely awaiting the
    # human (e.g. overnight) is PARKED, not stranded — main flagged that
    # counting it here re-alarms every _HB_STALL_MIN_MINUTES on a legitimately
    # idle night, exactly the alert-fatigue class already killed once.
    open_gates=$(db "SELECT COUNT(*) FROM tasks
                     WHERE need_type IS NOT NULL AND need_answered_at IS NULL
                       AND status NOT IN ('done','cancelled')
                       AND (COALESCE(tier,2) <= 1
                            OR (need_asked_at IS NULL AND gate_pinged_at IS NULL));" 2>/dev/null || echo 0)
    [[ "$stranded_todo" =~ ^[0-9]+$ ]] || stranded_todo=0
    [[ "$open_gates"    =~ ^[0-9]+$ ]] || open_gates=0
    total_stranded=$(( stranded_todo + open_gates ))
  fi

  if (( total_stranded > 0 )); then
    local first_seen; first_seen=$(db "SELECT value FROM task_prefs WHERE key='stall_first_seen_at';" 2>/dev/null)
    if [[ -z "$first_seen" ]]; then
      db "INSERT INTO task_prefs (key,value) VALUES ('stall_first_seen_at', datetime('now'))
          ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now');"
      first_seen=$(date -u '+%Y-%m-%d %H:%M:%S')
    fi
    local since_secs; since_secs=$(( $(date -u +%s) - $(date -u -d "$first_seen" +%s 2>/dev/null || date -u +%s) ))
    if (( since_secs >= _HB_STALL_MIN_MINUTES * 60 )); then
      local last_alert cutoff
      last_alert=$(db "SELECT value FROM task_prefs WHERE key='stall_alerted_at';" 2>/dev/null)
      cutoff=$(date -u -d "${_HB_STALL_MIN_MINUTES} minutes ago" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
      if [[ -z "$last_alert" || ( -n "$cutoff" && "$last_alert" < "$cutoff" ) ]]; then
        ( cmd_send "main" --from="task-engine" \
            --message="🛑 fleet-stall: 0 agents in_progress, 0 running loops, but ${total_stranded} stranded actionable item(s) (${stranded_todo} unclaimed todo, ${open_gates} open gate(s)) have sat idle $((since_secs / 60))m+ — nothing is self-correcting. Check \`5dive task ls\` / \`5dive task inbox\` (DIVE-1416 gap#3)." ) >/dev/null 2>&1 || true
        db "INSERT INTO task_prefs (key,value) VALUES ('stall_alerted_at', datetime('now'))
            ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now');"
        _hb_log "[stall-sweep] fleet-idle $((since_secs / 60))m with ${total_stranded} stranded item(s) -> alarmed main"
      fi
    fi
  else
    db "DELETE FROM task_prefs WHERE key='stall_first_seen_at';"
  fi

  # (c) GAP#3 canary — pinger liveness (DIVE-1434 class). Independent of
  # _hb_gate_ttl_sweep's own predicate/throttle — a canary sharing the suspect
  # code can go dark with it.
  local eligible; eligible=$(db "SELECT COUNT(*) FROM tasks
               WHERE need_type IS NOT NULL AND need_answered_at IS NULL
                 AND (tier IS NULL OR tier=2 OR (tier=1 AND recommend IS NULL))
                 AND COALESCE(need_asked_at, updated_at) <= datetime('now','-72 hours','-30 minutes')
                 AND (gate_pinged_at IS NULL OR gate_pinged_at <= datetime('now','-7 days'))
                 AND status NOT IN ('done','cancelled');" 2>/dev/null || echo 0)
  [[ "$eligible" =~ ^[0-9]+$ ]] || eligible=0
  if (( eligible == 0 )); then
    db "DELETE FROM task_prefs WHERE key='pinger_canary_alerted_at';"
  else
    local last_ping stale=0
    last_ping=$(db "SELECT MAX(gate_pinged_at) FROM tasks WHERE gate_pinged_at IS NOT NULL;" 2>/dev/null)
    if [[ -z "$last_ping" ]]; then
      stale=1
    else
      local last_epoch; last_epoch=$(date -u -d "$last_ping" +%s 2>/dev/null || echo 0)
      (( $(date -u +%s) - last_epoch >= 3600 )) && stale=1
    fi
    if (( stale )); then
      local last_alert cutoff
      last_alert=$(db "SELECT value FROM task_prefs WHERE key='pinger_canary_alerted_at';" 2>/dev/null)
      cutoff=$(date -u -d '6 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
      if [[ -z "$last_alert" || ( -n "$cutoff" && "$last_alert" < "$cutoff" ) ]]; then
        ( cmd_send "main" --from="task-engine" \
            --message="🚨 pinger-liveness canary tripped: ${eligible} human gate(s) are past their reminder window (72h+ unanswered, unpinged 7d+) but gate_pinged_at hasn't advanced fleet-wide in over an hour — the gate-ping batch looks dead (DIVE-1434 regression class). Check /var/log/5dive-heartbeat.log for batch errors." ) >/dev/null 2>&1 || true
        db "INSERT INTO task_prefs (key,value) VALUES ('pinger_canary_alerted_at', datetime('now'))
            ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now');"
        _hb_log "[pinger-canary] TRIPPED — ${eligible} eligible gate(s), last gate_pinged_at ${last_ping:-never}"
      fi
    fi
  fi
  return 0
}

# DIVE-972: loop token-ceiling enforcement sweep. The --wait poll only policed a
# ceiling while a caller was synchronously waiting; a fire-and-forget loop (no
# --wait, the common case) had NOTHING re-reading its spend, so its ceiling was
# purely advisory. This sweep is the backstop: every tick it recomputes the live
# spend of each running loop from its child tasks' transcripts and, on breach,
# halts the loop (status=escalated + kill_requested so any live poll or future
# round stops) and escalates-with-proof on the originating task — design §4's
# "never ship best-so-far silently", now enforced for async loops too.
_hb_loop_ceiling_sweep() {
  local lrow lid ceil sby kids spent lident
  while IFS= read -r lrow; do
    [[ -n "$lrow" ]] || continue
    IFS=$'\x1f' read -r lid ceil sby kids <<<"$lrow"
    [[ -n "$lid" && "$ceil" =~ ^[0-9]+$ ]] || continue
    spent=$(_loop_refresh_spend "$lid" 2>/dev/null || echo 0)
    [[ "$spent" =~ ^[0-9]+$ ]] || continue
    (( spent >= ceil )) || continue
    db "UPDATE loop_runs SET status='escalated', kill_requested=1, updated_at=$(date +%s)
        WHERE loop_id=$(sqlq "$lid") AND status='running';"
    # OSS-24: kill_requested only stops a DRIVER loop (map/until-dry re-checks it
    # each round). A fire-and-forget `loop spawn` has no driver, so the child task
    # its agent is actively burning tokens on would keep running past the ceiling —
    # leaving the ceiling advisory for exactly the common case. Mirror the
    # cost-budget hard stop, scoped to the loop: PARK the loop's live (non-terminal)
    # child tasks so the spend actually stops, not just the loop_runs bookkeeping.
    # Parked = blocked + parked_at + park_reason with pending-gate fields cleared
    # (same shape as `task park`); never touches done/cancelled/already-parked work.
    local kid_ids
    kid_ids=$(printf '%s' "${kids:-}" | tr -cd '0-9,' | tr ',' ' ')
    if [[ -n "$kid_ids" ]]; then
      local in_list; in_list=$(printf '%s' "$kid_ids" | tr ' ' ',')
      db "UPDATE tasks
            SET status='blocked', parked_at=datetime('now'),
                park_reason=$(sqlq "loop ${lid} hit its token ceiling (~${spent}/${ceil} tok) — halted by heartbeat before finishing"),
                need_type=NULL, ask=NULL, need_options=NULL, recommend=NULL,
                need_answer=NULL, need_answered_at=NULL
          WHERE id IN (${in_list})
            AND status IN ('todo','in_progress')
            AND parked_at IS NULL;"
    fi
    _hb_log "[loop-ceiling] ${lid} breached ceiling (~${spent}/${ceil} tok) — halted (child tasks parked) + escalated"
    # Escalate-with-proof on the originating task (skip if it already has an open
    # need, or isn't a live task). cmd_task_need is bundled + we run as root.
    if [[ "$sby" =~ ^[0-9]+$ ]]; then
      local has_need st
      st=$(db "SELECT status FROM tasks WHERE id=${sby};" 2>/dev/null || echo "")
      has_need=$(db "SELECT COUNT(*) FROM tasks WHERE id=${sby} AND need_type IS NOT NULL AND need_answered_at IS NULL;" 2>/dev/null || echo 0)
      if [[ -n "$st" && "$st" != "done" && "$st" != "cancelled" && "${has_need:-0}" == "0" ]]; then
        ( cmd_task_need "$sby" --type=approval \
            --ask="loop ${lid} hit its token ceiling (~${spent}/${ceil} tok) and was halted before finishing. Continue with a higher --ceiling, or stop?" \
            --recommend="stop" ) >/dev/null 2>&1 || true
      fi
    fi
  done < <(db "SELECT loop_id||x'1f'||COALESCE(ceiling,'')||x'1f'||COALESCE(spawned_by_task,'')||x'1f'||COALESCE(child_task_ids,'[]')
               FROM loop_runs
               WHERE status='running' AND ceiling IS NOT NULL
                 AND child_task_ids IS NOT NULL AND child_task_ids != '[]';")
  return 0
}

# DIVE-1019: run the per-agent token-budget engine once per tick. Idempotent —
# alerts/hard-stops are deduped inside cmd_usage_budget_check, which also
# refreshes the state cache that `watch` reads. Capture stdout so its summary
# never leaks into the tick's own output; mirror it into the heartbeat log.
_hb_budget_sweep() {
  local out
  out=$(cmd_usage_budget_check 2>/dev/null) || return 1
  [[ -n "$out" && "$out" != "no budgets set"* ]] && _hb_log "[budget] ${out}"
  return 0
}

# DIVE-1434 transport-liveness canary. A claude-type agent delivers gate-ping tap
# buttons via its OWN getUpdates poller (task_need_notify curls the button, but the
# TAP that clears the gate arrives as a callback_query the agent's poller must
# consume). The poller bumps its bot.heartbeat beacon every ~3s (DIVE-818); if it
# dies — e.g. a restart left the single getUpdates slot unacquired — buttons still
# SEND but taps never land, so a gate silently can't be cleared from the phone. The
# original incident hid because gate_pinged_at (the stale-reminder batch) is the
# WRONG signal; this watches the RIGHT one. dev2's DIVE-1416 gap#3c canary watches
# the stale-reminder batch — complementary, different code path.
#
# _hb_poller_verdict: PURE decision for ONE agent (headless-tested). Echoes a
# one-line reason when the poller looks DEAD, nothing when healthy or not
# applicable. Only claude runtimes write the beacon; codex/grok/agy/pi use a
# wait_for_message loop with their own liveness, so they are skipped. Only PAIRED
# agents matter — an unpaired bot has no human whose taps could be dropped.
_hb_poller_verdict() {
  local type="$1" mtime="$2" now="$3" allowfrom="$4" thresh="$5" supposed="${6:-1}"
  [[ "$type" == "claude" ]] || return 0            # non-poller runtime — skip
  [[ "${allowfrom:-0}" -ge 1 ]] || return 0        # unpaired — no human to deafen
  # An operator-stopped agent (desiredState=stopped) or a unit that isn't active
  # has a stale beacon BY DEFINITION — that's not a dead transport. A
  # dead-but-desired-running unit is the supervisor's stuck class (it alarms
  # there), not ours; alarming here too would just fuel alarm-blindness. Caller
  # passes supposed=0 for either condition.
  [[ "${supposed}" == "1" ]] || return 0
  if [[ -z "$mtime" || "$mtime" == "0" ]]; then
    echo "no beacon (poller never started)"; return 0
  fi
  local age=$(( now - mtime ))
  (( age > thresh )) && echo "beacon ${age}s stale (poller dead — taps won't land)"
  return 0
}

_hb_poller_liveness_sweep() {
  local reg; reg=$(registry_read 2>/dev/null) || return 0
  local now; now=$(date +%s)
  local thresh=120                                 # >> 3s beat; rides a restart/GC pause
  local -a dead=()
  local name type allowfrom beacon mtime verdict
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    type=$(jq -r --arg n "$name" '.agents[$n].type // "claude"' <<<"$reg")
    # Resolve this agent's paired channel (token + access.json) the same way the
    # gate-ttl sweep does — sets TASK_CH_ACCESS to <state_dir>/access.json.
    _task_agent_channel "$name" || continue
    allowfrom=$(jq -r '(.allowFrom // []) | length' "$TASK_CH_ACCESS" 2>/dev/null || echo 0)
    beacon="${TASK_CH_ACCESS%/*}/bot.heartbeat"
    mtime=0; [[ -f "$beacon" ]] && mtime=$(stat -c %Y "$beacon" 2>/dev/null || echo 0)
    # supposed=1 only when this agent is BOTH desired-running and its unit is
    # actually active — otherwise a stale beacon is expected, not a dead poller.
    local desired supposed=1
    if [[ "$type" == "claude" ]]; then
      desired=$(jq -r --arg n "$name" '.agents[$n].desiredState // "running"' <<<"$reg")
      [[ "$desired" == "stopped" ]] && supposed=0
      (( supposed )) && ! systemctl is-active --quiet "5dive-agent@${name}.service" 2>/dev/null && supposed=0
    fi
    verdict=$(_hb_poller_verdict "$type" "$mtime" "$now" "$allowfrom" "$thresh" "$supposed")
    [[ -n "$verdict" ]] && dead+=("${name}: ${verdict}")
  done < <(jq -r '.agents | keys[]?' <<<"$reg")

  local flag="${STATE_DIR}/poller-liveness.alarmed"
  if [[ ${#dead[@]} -eq 0 ]]; then
    # Self-clear: pollers healthy again → drop the throttle flag so the NEXT death
    # alarms immediately instead of waiting out a stale window.
    rm -f "$flag" 2>/dev/null || true
    return 0
  fi
  # Throttle to one alarm per hour (flag mtime) so a persistent dead poller pings
  # once, not every tick. Always log so the tick record shows it every pass.
  _hb_log "[poller-liveness] DEAD: ${dead[*]}"
  if [[ -f "$flag" ]] && (( now - $(stat -c %Y "$flag" 2>/dev/null || echo 0) < 3600 )); then
    return 0
  fi
  : > "$flag" 2>/dev/null || true
  local coord; coord=$(_task_resolve_coordinator 2>/dev/null)
  if [[ -n "$coord" ]]; then
    ( cmd_send "$coord" --message="🔴 Telegram poller DEAD on: ${dead[*]}. Gate-ping tap buttons still SEND but the human's TAP won't land (getUpdates slot not held) — those gates can't be cleared from the phone. Fix: restart the agent(s) (systemctl restart 5dive-agent@<name>.service) and check the DIVE-818 slot. (DIVE-1434 canary; re-pings hourly until healthy.)" ) >/dev/null 2>&1 || true
  fi
  return 0
}

cmd_heartbeat_tick() {
  require_root "heartbeat tick"
  tasks_db_init
  local reg now; reg=$(registry_read); now=$(date +%s)
  local checked=0 woke=0 reaped=0 reclaimed=0 starved=0 sk_notdue=0 sk_busy=0 sk_nowork=0 sk_fail=0 sk_spread=0 sk_active=0
  # DIVE-138: materialize due recurring templates FIRST so a freshly-cloned todo
  # is eligible for the wake loop below this same tick. Isolated — a failure here
  # must never abort the wake loop.
  _hb_materialize_recurring "$now" || _hb_log "[materializer] pass errored (non-fatal)"
  # DIVE-1490: receipt-backed reminder first, so an old gate whose initial send
  # failed gets a button-bearing + group-fallback attempt before the legacy 72h
  # text backlog can stamp it. Isolated so notification transport never aborts
  # the worker wake loop.
  _hb_gate_renag_sweep || _hb_log "[gate-renag] pass errored (non-fatal)"
  # DIVE-891: gate TTL + wake sweep, same isolation contract as the materializer
  # — runs before the wake loop so a just-unparked/just-unblocked todo is
  # eligible for pickup this same tick. The renag's confirmed gate_pinged_at
  # stamp also preserves pass 3's existing seven-day throttle (no duplicate).
  _hb_gate_ttl_sweep || _hb_log "[gate-ttl] pass errored (non-fatal)"
  # DIVE-1355: the belt-and-suspenders half of the self-dispatch fix. Auto-recover
  # any task still stuck 'blocked' whose every blocking edge is a done/cancelled
  # task (repairs pre-existing rot like OSS-27 + any live cascade miss), and
  # SURFACE (never auto-unblock) tasks blocked with no live reason at all. Runs
  # before the wake loop so a just-recovered todo is eligible this same tick. Same
  # isolation contract — a failure here must never abort the wake loop.
  _hb_blocked_sweep || _hb_log "[blocked-sweep] pass errored (non-fatal)"
  # DIVE-1140: flag open gates whose fix already merged so the overnight recap
  # stops surfacing ghost gates. Flag-only, never auto-closes. Same isolation.
  _hb_gate_shipped_sweep || _hb_log "[gate-shipped] pass errored (non-fatal)"
  # DIVE-1416: fleet-stall self-heal gaps #2/#3 — surface stale maker->verifier
  # deliveries, alarm on fleet-idle-while-actionable-work-is-open persisting past
  # its threshold, and a pinger-liveness canary for the DIVE-1434 dead-batch
  # class. Same isolation contract — a failure here must never abort the wake
  # loop, and must never itself go silent the way the incident it targets did.
  _hb_stall_sweep || _hb_log "[stall-sweep] pass errored (non-fatal)"
  # DIVE-972: enforce per-loop token ceilings for async (non --wait) loops. Same
  # isolation contract — a failure here must never abort the wake loop.
  _hb_loop_ceiling_sweep || _hb_log "[loop-ceiling] pass errored (non-fatal)"
  # DIVE-1019: per-agent token budget guardrails — alert the owner at the soft
  # cap and (only if hard-stop is opted in) turn an agent off at the ceiling, and
  # refresh the state cache `watch` reads. Same isolation contract as above.
  _hb_budget_sweep || _hb_log "[budget] pass errored (non-fatal)"
  # DIVE-1434: transport-liveness canary — alarm if any paired claude agent's
  # Telegram poller died (stale beacon => gate-ping taps won't land). Same
  # isolation contract — a failure here must never abort the wake loop.
  _hb_poller_liveness_sweep || _hb_log "[poller-liveness] pass errored (non-fatal)"
  # Accounts already woken during THIS tick. The $reg snapshot is read once up
  # front, so a wake we do mid-loop isn't visible to later iterations via the
  # registry — this map carries that within-tick fact so two same-account agents
  # can't both wake on one tick.
  local -A in_tick_woke=()
  local name
  # Process oldest-waiting first (smallest lastRunAt). When two same-account
  # agents contend for the one wake slot, the one that has waited longest wins,
  # so neither can be starved by a fresher sibling repeatedly taking the slot.
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    checked=$((checked + 1))
    local everyMin lastRun fresh
    everyMin=$(jq -r --arg n "$name" '.agents[$n].heartbeat.everyMin // '"$_HB_DEFAULT_EVERY" <<<"$reg")
    lastRun=$(jq -r --arg n "$name"  '.agents[$n].heartbeat.lastRunAt // 0' <<<"$reg")
    fresh=$(jq -r --arg n "$name"    '(.agents[$n].heartbeat | if has("fresh") then .fresh else false end)' <<<"$reg")

    # Unwedge stuck in_progress first, every tick (NOT gated by everyMin): an
    # orphaned/stalled/runaway task must clear promptly regardless of the wake
    # throttle, or it blocks the agent's whole queue (the busy-guard below).
    local n_reclaimed n_cancelled
    read -r n_reclaimed n_cancelled < <(_hb_reclaim "$name" "$everyMin") || true
    reclaimed=$((reclaimed + ${n_reclaimed:-0})); reaped=$((reaped + ${n_cancelled:-0}))

    if (( now - lastRun < everyMin * 60 )); then
      # Wake-on-enqueue: don't make an urgent/high task wait out the full cadence.
      # If one landed in this agent's queue since its last wake, allow an early
      # wake this tick (still gated by busy/spread/idle below). created_at is UTC
      # text; strftime('%s') makes it an epoch comparable to lastRun.
      local hot
      # DIVE-979: only an ACTIONABLE (no open blocker) urgent/high task earns an
      # early wake — a hot task stuck behind a dep would just idle the tick.
      hot=$(db "SELECT COUNT(*) FROM tasks t
                WHERE t.assignee=$(sqlq "$name") AND t.status='todo' AND t.kind='standard'
                  AND t.priority IN ('urgent','high')
                  AND CAST(strftime('%s', t.created_at) AS INTEGER) > ${lastRun}
                  AND NOT EXISTS (
                    SELECT 1 FROM task_deps dd JOIN tasks b ON b.id = dd.blocked_by
                     WHERE dd.task_id = t.id AND b.status NOT IN ('done','cancelled'));" 2>/dev/null || echo 0)
      if [[ "${hot:-0}" != "0" ]]; then
        _hb_log "[$name] early wake — ${hot} urgent/high task(s) queued since last wake"
      else
        sk_notdue=$((sk_notdue + 1)); _hb_log "[$name] not due ($(( (lastRun + everyMin*60 - now + 59) / 60 ))m left)"; continue
      fi
    fi
    local inprog
    inprog=$(db "SELECT COUNT(*) FROM tasks WHERE assignee=$(sqlq "$name") AND status='in_progress';" 2>/dev/null || echo 0)
    if [[ "${inprog:-0}" != "0" ]]; then
      sk_busy=$((sk_busy + 1)); _hb_log "[$name] busy — $inprog in_progress, skip"; continue
    fi
    # Pick the single highest-priority todo and wake the agent against that exact
    # id — the /goal condition needs a concrete DIVE-N to evaluate reliably.
    local task_id
    task_id=$(_hb_pick_task "$name")
    if [[ -z "$task_id" ]]; then
      sk_nowork=$((sk_nowork + 1)); _hb_log "[$name] no todo — stay idle"; continue
    fi
    # The /goal + every log below must name the task by its DISPLAY ident, not the
    # raw row id — they diverge once a non-default project exists (DIVE-484).
    local task_ident; task_ident=$(_hb_ident "$task_id")

    # --- DIVE-1065 tier guard --------------------------------------------------
    # Refuse to AUTO-DRIVE a higher-tier agent from a lower-tier creator's task.
    # A standard/sandboxed agent can enqueue work onto an admin agent; without
    # this, the heartbeat would auto-run it (privilege-escalation-by-queue). If
    # the task's creator is strictly LOWER-privileged than its assignee, HOLD the
    # task (don't auto-wake) — a human or the assignee can still run it manually.
    # Isolated + best-effort: any lookup miss falls through to the normal wake and
    # never aborts the tick (a self-assigned task, human/unknown creator, or an
    # equal/higher-tier creator is unaffected).
    local _cby _ctier _atier
    _cby=$(db "SELECT COALESCE(created_by,'') FROM tasks WHERE id=${task_id};" 2>/dev/null || echo "")
    if [[ -n "$_cby" && "$_cby" != "$name" ]]; then
      _ctier=$(jq -r --arg n "$_cby"  '.agents[$n].isolation // empty' <<<"$reg" 2>/dev/null)
      _atier=$(jq -r --arg n "$name"  '.agents[$n].isolation // empty' <<<"$reg" 2>/dev/null)
      local _cr _ar
      _cr=$(_hb_tier_rank "${_ctier:-}"); _ar=$(_hb_tier_rank "${_atier:-}")
      if (( _cr > 0 && _ar > 0 && _cr < _ar )); then
        _hb_log "[$name] task ${task_ident} created by lower-tier ${_cby}(${_ctier}) < assignee(${_atier}) — holding, not auto-running"
        continue
      fi
    fi

    # --- Same-account spread ---------------------------------------------------
    # Never start two agents that share an Anthropic account close together: a
    # simultaneous session start bursts the shared account and trips a 429. The
    # account's most-recent wake is derived from existing lastRunAt values (plus
    # any wake done earlier this tick) — no extra state. Require an even slice of
    # the cadence between same-account wakes: gap = everyMin / agents-on-account
    # (2 agents @ 60m -> 30m apart, 3 -> 20m), and it self-heals as agents join.
    # Single-agent accounts are never deferred. A deferred agent is left due and
    # retried next tick, sliding later until it clears the gap, so the phases
    # converge to even spacing on their own. Agents with no authProfile get a
    # per-name sentinel account, so they never contend with anyone.
    local acct acct_count
    acct=$(jq -r --arg n "$name" '.agents[$n].authProfile // ("@self:" + $n)' <<<"$reg")
    acct_count=$(jq -r --arg a "$acct" '
      [.agents | to_entries[]
       | select(.value.heartbeat.enabled == true)
       | (.value.authProfile // ("@self:" + .key))
       | select(. == $a)] | length' <<<"$reg")
    if (( acct_count > 1 )); then
      local acct_last gap
      acct_last=$(jq -r --arg a "$acct" --arg n "$name" '
        [.agents | to_entries[]
         | select(.value.heartbeat.enabled == true)
         | select(.key != $n)
         | select((.value.authProfile // ("@self:" + .key)) == $a)
         | (.value.heartbeat.lastRunAt // 0)] | max // 0' <<<"$reg")
      if [[ -n "${in_tick_woke[$acct]:-}" ]] && (( in_tick_woke[$acct] > acct_last )); then
        acct_last=${in_tick_woke[$acct]}
      fi
      gap=$(( everyMin * 60 / acct_count ))
      if (( now - acct_last < gap )); then
        sk_spread=$((sk_spread + 1))
        _hb_log "[$name] spread-defer — account '$acct' (${acct_count} agents) last woke $(( (now - acct_last) / 60 ))m ago, need a $(( gap / 60 ))m gap; retry next tick"
        continue
      fi
    fi

    # No-clobber: never /clear + nudge an agent that's mid-turn, in a live
    # conversation (e.g. the orchestrator talking to a human), or blocked on a
    # prompt. The busy-guard above only catches an open *task*; this catches
    # working/interactive/blocked state with no task — a fresh nudge would /clear
    # it out from under the work or bury a pending permission prompt. Defer on a
    # confident "active" (rc 1) or "blocked" (rc 3); unknown (rc 2 — no signal)
    # falls through so the wake can still (re)start a stopped session.
    local idle_rc=0; _hb_agent_idle "$name" || idle_rc=$?
    if (( idle_rc == 3 )); then
      sk_active=$((sk_active + 1))
      _hb_log "[$name] WARN: blocked (${_HB_IDLE_REASON:-input needed}) — surfacing, defer nudge this tick (needs attention, not reclaim)"
      continue
    fi
    if (( idle_rc == 1 )); then
      # DIVE-1486: a confident "active" normally defers — but an attached-but-idle
      # session reads "active" forever (blinking cursor/spinner leaves the pane
      # byte-unstable, or the native signal lags) while ${task_ident} sits todo and
      # the supervisor calls the same agent idle-stranded. Reconcile via output
      # progress: fingerprint the pane; while it keeps CHANGING the agent is really
      # working and we keep deferring, but once it's unchanged for
      # _HB_ACTIVE_DEFER_ESCALATE consecutive deferred ticks (zero output) with a
      # dispatchable todo waiting, it's idle-stranded — stop deferring and fall
      # through to force the nudge instead of stalling forever.
      local defer_fp defer_n=0
      defer_fp=$(_hb_pane_fingerprint "$name")
      defer_n=$(with_registry_lock _hb_mark_active_defer "$name" "$defer_fp")
      if [[ "${defer_n:-0}" =~ ^[0-9]+$ ]] && (( defer_n >= _HB_ACTIVE_DEFER_ESCALATE )); then
        _hb_log "[$name] active-defer escalation — pane unchanged ${defer_n} ticks (>=${_HB_ACTIVE_DEFER_ESCALATE}) with ${task_ident} todo waiting → idle-stranded, force-nudging (DIVE-1486)"
        with_registry_lock _hb_clear_active_defer "$name" >/dev/null 2>&1 || true
        # deliberately no `continue` — fall through to the wake below.
      else
        sk_active=$((sk_active + 1)); _hb_log "[$name] active (mid-turn/conversation) — defer nudge this tick (active-defer #${defer_n})"; continue
      fi
    fi

    # Per-task fresh override (DIVE-138): a materialized recurring instance can
    # carry fresh=1 to force a clean /clear before its turn, regardless of the
    # agent-level heartbeat fresh setting. NULL/0 falls back to the agent default.
    local eff_fresh="$fresh" task_fresh
    task_fresh=$(db "SELECT COALESCE(fresh,'') FROM tasks WHERE id=${task_id};" 2>/dev/null || echo "")
    [[ "$task_fresh" == "1" ]] && eff_fresh="true"
    _hb_log "[$name] due + todo ${task_ident} — waking (fresh=${eff_fresh})"
    if _hb_wake "$name" "$eff_fresh" "$task_id" "$task_ident"; then
      in_tick_woke[$acct]=$now   # claim the account's slot for the rest of this tick
      with_registry_lock _hb_clear_active_defer "$name" >/dev/null 2>&1 || true  # DIVE-1486: episode over
      local nudge_n
      nudge_n=$(with_registry_lock _hb_mark_run "$name" "$now" "$task_id")
      woke=$((woke + 1)); _hb_log "[$name] nudged (/goal ${task_ident}, nudge #${nudge_n:-?})"
      # Nudged repeatedly but the task never left todo → it's being starved
      # (e.g. listen-loop watchdog yanking the agent before `task start` runs).
      # Surface it instead of silently re-nudging every tick forever.
      if [[ "${nudge_n:-0}" =~ ^[0-9]+$ ]] && (( nudge_n >= _HB_STARVE_AFTER )); then
        starved=$((starved + 1))
        _hb_log "[$name] WARN: ${task_ident} nudged ${nudge_n}x but still todo (never started) — possible listen-loop starvation; check the agent's task-claim path"
      fi
    else
      sk_fail=$((sk_fail + 1)); _hb_log "[$name] wake failed — will retry next tick"
    fi
  done < <(jq -r '.agents | to_entries
                  | map(select(.value.heartbeat.enabled == true))
                  | sort_by(.value.heartbeat.lastRunAt // 0)
                  | .[].key' <<<"$reg")

  ok "heartbeat tick: woke ${woke} / reclaimed ${reclaimed} / reaped ${reaped} / starved ${starved} / spread-deferred ${sk_spread} / active-deferred ${sk_active} / checked ${checked}" \
     '{checked:($c|tonumber), woke:($w|tonumber), reclaimed:($rc|tonumber), reaped:($r|tonumber), starved:($st|tonumber),
       skipped:{notDue:($nd|tonumber), busy:($b|tonumber), noWork:($nw|tonumber), spread:($sp|tonumber), active:($ac|tonumber), failed:($sf|tonumber)}}' \
     --arg c "$checked" --arg w "$woke" --arg rc "$reclaimed" --arg r "$reaped" --arg st "$starved" --arg nd "$sk_notdue" --arg b "$sk_busy" --arg nw "$sk_nowork" --arg sp "$sk_spread" --arg ac "$sk_active" --arg sf "$sk_fail"
}
