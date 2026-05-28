
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
    fresh=$(jq -r --arg n "$name"    '.agents[$n].heartbeat.fresh    // true' <<<"$reg")
    lastRun=$(jq -r --arg n "$name"  '.agents[$n].heartbeat.lastRunAt // 0' <<<"$reg")
    # is-active prints the state word AND exits nonzero for non-active units, so
    # capture its stdout directly — a `|| echo` here would append a second word.
    running=$(systemctl is-active "5dive-agent@${name}.service" 2>/dev/null || true)
    [[ -n "$running" ]] || running="unknown"
    todo=$(db "SELECT COUNT(*) FROM tasks WHERE assignee=$(sqlq "$name") AND status='todo';" 2>/dev/null || echo 0)
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

# Persist a wake timestamp. Runs under with_registry_lock from the tick loop.
_hb_mark_run() {
  local name="$1" now="$2"
  local reg; reg=$(registry_read)
  echo "$reg" | jq --arg n "$name" --argjson t "$now" \
    '.agents[$n].heartbeat.lastRunAt = $t' | registry_write
}

# Inject one literal line + Enter into an agent's tmux pane. Returns nonzero
# (never exits) so a single dead pane can't abort the whole tick.
_hb_send_line() {
  local name="$1" text="$2"
  sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" -l -- "$text" 2>/dev/null || return 1
  sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" Enter 2>/dev/null || return 1
}

# Wake one agent: ensure it's running, optionally clear context, send the nudge.
# Returns 0 on a delivered nudge, nonzero on any failure (so the caller skips
# marking lastRunAt and retries next tick).
_hb_wake() {
  local name="$1" fresh="$2" todo="$3"
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

  local nudge="Heartbeat tick. You have ${todo} open task(s) assigned to you on the shared 5dive board. Do exactly ONE now: run '5dive task ls --mine' to list them, pick the single highest-priority todo, claim it with '5dive task start <id>', do the work, then close it with '5dive task done <id>'. Handle only ONE task this turn — when it's done, stop and wait; the heartbeat wakes you again for the next one. If a task is blocked or unclear, note it via 5dive task and move on without starting more."
  _hb_send_line "$name" "$nudge" || { _hb_log "[$name] nudge send failed"; return 1; }
  return 0
}

cmd_heartbeat_tick() {
  require_root "heartbeat tick"
  tasks_db_init
  local reg now; reg=$(registry_read); now=$(date +%s)
  local checked=0 woke=0 sk_notdue=0 sk_busy=0 sk_nowork=0 sk_fail=0
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    checked=$((checked + 1))
    local everyMin lastRun fresh
    everyMin=$(jq -r --arg n "$name" '.agents[$n].heartbeat.everyMin // '"$_HB_DEFAULT_EVERY" <<<"$reg")
    lastRun=$(jq -r --arg n "$name"  '.agents[$n].heartbeat.lastRunAt // 0' <<<"$reg")
    fresh=$(jq -r --arg n "$name"    '.agents[$n].heartbeat.fresh // true' <<<"$reg")

    if (( now - lastRun < everyMin * 60 )); then
      sk_notdue=$((sk_notdue + 1)); _hb_log "[$name] not due ($(( (lastRun + everyMin*60 - now + 59) / 60 ))m left)"; continue
    fi
    local inprog
    inprog=$(db "SELECT COUNT(*) FROM tasks WHERE assignee=$(sqlq "$name") AND status='in_progress';" 2>/dev/null || echo 0)
    if [[ "${inprog:-0}" != "0" ]]; then
      sk_busy=$((sk_busy + 1)); _hb_log "[$name] busy — $inprog in_progress, skip"; continue
    fi
    local todo
    todo=$(db "SELECT COUNT(*) FROM tasks WHERE assignee=$(sqlq "$name") AND status='todo';" 2>/dev/null || echo 0)
    if [[ "${todo:-0}" == "0" ]]; then
      sk_nowork=$((sk_nowork + 1)); _hb_log "[$name] no todo — stay idle"; continue
    fi

    _hb_log "[$name] due + ${todo} todo — waking (fresh=${fresh})"
    if _hb_wake "$name" "$fresh" "$todo"; then
      with_registry_lock _hb_mark_run "$name" "$now"
      woke=$((woke + 1)); _hb_log "[$name] nudged"
    else
      sk_fail=$((sk_fail + 1)); _hb_log "[$name] wake failed — will retry next tick"
    fi
  done < <(jq -r '.agents | to_entries[] | select(.value.heartbeat.enabled == true) | .key' <<<"$reg")

  ok "heartbeat tick: woke ${woke} / checked ${checked}" \
     '{checked:($c|tonumber), woke:($w|tonumber),
       skipped:{notDue:($nd|tonumber), busy:($b|tonumber), noWork:($nw|tonumber), failed:($sf|tonumber)}}' \
     --arg c "$checked" --arg w "$woke" --arg nd "$sk_notdue" --arg b "$sk_busy" --arg nw "$sk_nowork" --arg sf "$sk_fail"
}
