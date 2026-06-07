
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

  5dive heartbeat on  <name> [--every=<dur>] [--no-fresh]
                                          # enrol agent; default every=${_HB_DEFAULT_EVERY}m, fresh on
  5dive heartbeat off <name>              # stop waking the agent (keeps its settings)
  5dive heartbeat ls                      # show enrolled agents + next-wake + queued count
  5dive heartbeat tick                    # cron driver: wake every due agent that has work

  <dur>: minutes (e.g. 30), or 45m / 2h / 1h30m.
  fresh (default on): send /clear before each task so context starts clean;
        --no-fresh keeps the running conversation across tasks.

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
    -h|--help|help)  _hb_usage ;;
    *) fail "$E_USAGE" "unknown heartbeat command: $sub (try: 5dive heartbeat --help)" ;;
  esac
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
  local name="" every="" fresh="true"
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
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive heartbeat on <name> [--every=<dur>] [--no-fresh]"
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
    '.agents[$n].heartbeat = ((.agents[$n].heartbeat // {everyMin: '"$_HB_DEFAULT_EVERY"', fresh: true, lastRunAt: 0}) + {enabled: false})' \
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
    fresh=$(jq -r --arg n "$name"    '(.agents[$n].heartbeat | if has("fresh") then .fresh else true end)' <<<"$reg")
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
    jq -cn --argjson r "$rows" '{ok:true, data:{agents:$r}}'
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

# Inject one literal line + Enter into an agent's tmux pane. Returns nonzero
# (never exits) so a single dead pane can't abort the whole tick.
_hb_send_line() {
  local name="$1" text="$2"
  sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" -l -- "$text" 2>/dev/null || return 1
  sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" Enter 2>/dev/null || return 1
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
  grep -q '❯' <<<"$b" || return 1
  return 0
}

# Flip one in_progress task back to todo. Clears started_at so its age and the
# per-task nudge counter both restart cleanly, and stamps updated_at. Best-effort
# (a dead db or already-moved task is harmless). Logs why.
_hb_reclaim_to_todo() {
  local name="$1" id="$2" why="$3"
  db "UPDATE tasks SET status='todo', started_at=NULL, updated_at=datetime('now')
      WHERE id=${id} AND status='in_progress';" 2>/dev/null || true
  _hb_log "[$name] reclaimed DIVE-${id} -> todo ($why)"
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
#   (c) hard cap           -> cancel. in_progress past everyMin*_HB_STALE_MULT
#       (floored): the deterministic runaway backstop. /goal clear then cancel
#       with an auto-result so the board shows it terminated, not silently stuck.
#
# (a)/(b) reclaim (the work still needs doing); only (c) cancels. Echoes
# "<reclaimed> <cancelled>". Uses started_at (falls back to created_at).
_hb_reclaim() {
  local name="$1" everyMin="$2"
  local budget=$(( everyMin * _HB_STALE_MULT ))
  (( budget < _HB_STALE_MIN_MINUTES )) && budget=$_HB_STALE_MIN_MINUTES
  local proc_start; proc_start=$(_hb_claude_started "$name" 2>/dev/null || true)
  local reclaimed=0 cancelled=0 id started_epoch age_min
  while IFS='|' read -r id started_epoch age_min; do
    [[ -n "$id" ]] || continue
    # (a) the claiming session is gone — process is newer than the claim.
    if [[ -n "$proc_start" && -n "$started_epoch" ]] \
       && (( proc_start > started_epoch + _HB_PROC_SKEW_SEC )); then
      _hb_reclaim_to_todo "$name" "$id" "claiming session gone (claude restarted $(( (proc_start - started_epoch) / 60 ))m after the claim)"
      reclaimed=$((reclaimed + 1)); continue
    fi
    # (c) hard cap before stall: a very old task is cancelled, not re-queued.
    if (( age_min >= budget )); then
      _hb_send_line "$name" "/goal clear" || true
      db "UPDATE tasks SET status='cancelled', done_at=datetime('now'),
            result='auto-cancelled by heartbeat: in_progress exceeded ${budget}m time budget'
          WHERE id=${id} AND status='in_progress';" 2>/dev/null || true
      _hb_log "[$name] reaped stale in_progress DIVE-${id} (>${budget}m)"
      cancelled=$((cancelled + 1)); continue
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
  printf '%s %s\n' "$reclaimed" "$cancelled"
}

# Wake one agent: ensure it's running, optionally clear context, send the nudge.
# $3 is the concrete DIVE id (highest-priority todo) the tick picked for this
# agent — scoping the /goal to one known id makes its completion check reliable
# (a freeform "your tasks" condition is ambiguous to the goal evaluator).
# Returns 0 on a delivered nudge, nonzero on any failure (so the caller skips
# marking lastRunAt and retries next tick).
_hb_wake() {
  local name="$1" fresh="$2" task_id="$3"
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
  local nudge="/goal Task DIVE-${task_id} shows status done or cancelled, or is blocked with a human gate filed, on the 5dive board (verify ONLY by running: 5dive task show DIVE-${task_id}). To achieve it: claim it with '5dive task start DIVE-${task_id}', do the work, then close it with '5dive task done DIVE-${task_id} --result=\"<one or two self-contained sentences — any output the creator needs to see; the dashboard and creator read this>\" --notify'. If it needs a human decision, approval, a secret, or a manual step only a person can do, do NOT cancel — file a gate that pings the owner: '5dive task need DIVE-${task_id} --type=decision --ask=\"<what you need from them>\"' (use --type=approval|secret|manual as fits). Only if the task is genuinely irrelevant or impossible, run '5dive task cancel DIVE-${task_id} --result=\"<why>\" --notify'. Work ONLY this one task — do not start any other. Stop after 6 turns."
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
      _hb_log "[materializer] DIVE-${tid} due but an open instance exists — skip"
      continue
    fi
    if db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, from_template_id, fresh)
           SELECT title, body, priority, assignee, created_by, 'standard', id, fresh FROM tasks WHERE id=${tid};
           UPDATE tasks SET last_fired_at=datetime('now') WHERE id=${tid};" >/dev/null 2>&1; then
      n_made=$((n_made + 1)); _hb_log "[materializer] DIVE-${tid} fired -> new standard todo"
    else
      _hb_log "[materializer] DIVE-${tid} insert failed"
    fi
  done < <(db "SELECT id, schedule, COALESCE(last_fired_at,'') FROM tasks WHERE kind='recurring' AND schedule IS NOT NULL;" 2>/dev/null | tr '|' '\t')
  _hb_log "[materializer] pass done — ${n_made} materialized"
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
    fresh=$(jq -r --arg n "$name"    '(.agents[$n].heartbeat | if has("fresh") then .fresh else true end)' <<<"$reg")

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
      hot=$(db "SELECT COUNT(*) FROM tasks
                WHERE assignee=$(sqlq "$name") AND status='todo' AND kind='standard'
                  AND priority IN ('urgent','high')
                  AND CAST(strftime('%s', created_at) AS INTEGER) > ${lastRun};" 2>/dev/null || echo 0)
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
    task_id=$(db "SELECT id FROM tasks WHERE assignee=$(sqlq "$name") AND status='todo' AND kind='standard'
                  ORDER BY CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END, id
                  LIMIT 1;" 2>/dev/null || echo "")
    if [[ -z "$task_id" ]]; then
      sk_nowork=$((sk_nowork + 1)); _hb_log "[$name] no todo — stay idle"; continue
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
      sk_active=$((sk_active + 1)); _hb_log "[$name] active (mid-turn/conversation) — defer nudge this tick"; continue
    fi

    # Per-task fresh override (DIVE-138): a materialized recurring instance can
    # carry fresh=1 to force a clean /clear before its turn, regardless of the
    # agent-level heartbeat fresh setting. NULL/0 falls back to the agent default.
    local eff_fresh="$fresh" task_fresh
    task_fresh=$(db "SELECT COALESCE(fresh,'') FROM tasks WHERE id=${task_id};" 2>/dev/null || echo "")
    [[ "$task_fresh" == "1" ]] && eff_fresh="true"
    _hb_log "[$name] due + todo DIVE-${task_id} — waking (fresh=${eff_fresh})"
    if _hb_wake "$name" "$eff_fresh" "$task_id"; then
      in_tick_woke[$acct]=$now   # claim the account's slot for the rest of this tick
      local nudge_n
      nudge_n=$(with_registry_lock _hb_mark_run "$name" "$now" "$task_id")
      woke=$((woke + 1)); _hb_log "[$name] nudged (/goal DIVE-${task_id}, nudge #${nudge_n:-?})"
      # Nudged repeatedly but the task never left todo → it's being starved
      # (e.g. listen-loop watchdog yanking the agent before `task start` runs).
      # Surface it instead of silently re-nudging every tick forever.
      if [[ "${nudge_n:-0}" =~ ^[0-9]+$ ]] && (( nudge_n >= _HB_STARVE_AFTER )); then
        starved=$((starved + 1))
        _hb_log "[$name] WARN: DIVE-${task_id} nudged ${nudge_n}x but still todo (never started) — possible listen-loop starvation; check the agent's task-claim path"
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
