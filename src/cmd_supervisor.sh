
# -------- 5dive supervisor — fleet health brain (DIVE-724, P1: observe-only) --------
#
# The unifying layer ON TOP of heartbeat/rotation/auto-resume/loops (design:
# docs/fleet-supervisor-design.md). Per agent it runs DETECT -> CLASSIFY and
# surfaces the result on a board; the cron-callable `--tick` additionally
# APPENDS to the supervisor_events audit table. P1 takes ZERO recovery
# actions — no restarts, no nudges, no mutations beyond that audit table —
# so the stuck/slow classifier can be validated against real fleet behavior
# with no risk before P2 turns the recovery ladder on.
#
# Signals (all read-only; cheap ones implemented, flaky ones stubbed):
#   service   systemctl is-active on 5dive-agent@<name> (claude-session.service
#             for the box's main `claude` user, when that unit is meant to run)
#   tmux      tmux has-session -t agent-<name>, as the agent's own user
#   poller    telegram bridge process alive, per-type (DIVE-971): claude runs
#             the forked plugin as a bun proc carrying …/5dive-plugins/telegram;
#             codex/grok/antigravity run the telegram-<type> MCP server (bun
#             <dir>/server.ts); opencode's telegram-opencode relay IS its main
#             proc. One pgrep pattern per type (_SUP_POLLER_PAT) — telegram
#             channel only; other channels/types stay "n/a".
#   activity  newest session-transcript mtime, per-type (DIVE-971). Every
#             assistant turn appends to the runtime's transcript, so its mtime
#             IS the last-token-progress timestamp — cheaper and wider-coverage
#             than loop_runs.updated_at (loop work only) and far less flaky than
#             pane-scraping. Per-type roots+globs in _sup_activity_epoch:
#             claude ~/.claude/projects/*.jsonl, codex ~/.codex/sessions/
#             rollout-*.jsonl, grok ~/.grok/sessions, opencode
#             ~/.local/share/opencode/storage, antigravity
#             ~/.gemini/antigravity-cli/brain/**/transcript*.jsonl. A missing/
#             empty root => age unknown => never stuck (false-negative bias).
#   goalDrift claude-only (DIVE-971): an active /goal targets a specific DIVE
#             task that is still untouched (status=todo) while the agent is
#             actively progressing on something else. Structural, not semantic
#             — no relevance heuristic. Observe-only: never feeds the act ladder.
#   activeWork in_progress tasks assigned to the agent + its running loops
#   cliStale  one `update --check`-shaped probe per pass (box-level, best-effort)

# Conservative classification knobs (design §4). Bias FALSE-NEGATIVE: missing a
# stuck agent is better than flagging a healthy one, because the P2 ladder's
# restart is disruptive. Env-overridable so the P1 instrumentation phase can
# tune thresholds per box without a release (the _HB_* heartbeat constants are
# the sibling pattern; these add the env escape hatch because tuning IS the
# point of P1). Non-numeric overrides fall back to the defaults.
_SUP_T_STUCK_MIN="${SUPERVISOR_T_STUCK_MIN:-30}"   # active work + no progress this long -> stuck/no-progress
_SUP_T_SLOW_MIN="${SUPERVISOR_T_SLOW_MIN:-10}"     # active work + no progress this long -> slow (record only)
[[ "$_SUP_T_STUCK_MIN" =~ ^[0-9]+$ ]] || _SUP_T_STUCK_MIN=30
[[ "$_SUP_T_SLOW_MIN"  =~ ^[0-9]+$ ]] || _SUP_T_SLOW_MIN=10
# Ignore a missing poller right after a service start — the plugin's bun server
# takes a moment to boot, and a false poller-dead there would flag every
# freshly-restarted agent.
_SUP_POLLER_GRACE_SEC=120
# Ship-behind-a-flag (design §8): `--tick` no-ops with a notice unless this
# sentinel exists. Same file-sentinel pattern as gate-proof.enforce — root
# touches it to enable, removes it to disable; no registry churn.
_SUP_ENABLED_FLAG="${STATE_DIR}/supervisor.enabled"
# P2 (DIVE-857): actions have their OWN sentinel, separate from observe — ticks
# collect audit evidence while the ladder stays dormant. Absent flag => the
# tick records 'planned' rows (what WOULD have fired) instead of acting.
# lodar pre-cleared enabling (gate answered 2026-07-02) conditional on a clean
# zero-false-positive audit week; root touches this file on/after Jul 9.
_SUP_ACTIONS_FLAG="${STATE_DIR}/supervisor.actions.enabled"
# Ladder pacing (design §5): gap before the NEXT action on an agent is
# base * 2^attempts (20m/40m/80m against the 10m tick); past max attempts the
# supervisor stops acting and escalates once per window.
_SUP_ACT_BASE_MIN="${SUPERVISOR_ACT_BASE_MIN:-20}"
[[ "$_SUP_ACT_BASE_MIN" =~ ^[0-9]+$ ]] || _SUP_ACT_BASE_MIN=20
_SUP_ACT_WINDOW_H=6
_SUP_ACT_MAX_ATTEMPTS=3

# DIVE-971: per-type telegram-bridge pgrep pattern (matched against the agent
# user's process argv, -f). claude's forked plugin argv carries the cache path
# …/5dive-plugins/telegram/<ver>; codex/grok/antigravity run the telegram-<x>
# MCP server as `bun <plugin>/server.ts`; opencode launches its relay via
# `bun run --cwd <plugin> … start` — every non-claude plugin dir is
# telegram-<name>, so the dir name is a unique, argv-stable match. A type
# absent here has no probeable bridge -> poller stays "n/a" (never classifies).
declare -A _SUP_POLLER_PAT=(
  [claude]='5dive-plugins/telegram'
  [codex]='telegram-codex'
  [grok]='telegram-grok'
  [antigravity]='telegram-agy'
  [opencode]='telegram-opencode'
)

# DIVE-971: per-type "<relroot>|<find-args>" for the last-activity probe. relroot
# is under the agent's $HOME; find-args select the append-on-progress transcript
# files so the newest mtime IS the last-token-progress time (see header). A type
# absent here (or a missing/empty root) => age unknown => never stuck.
declare -A _SUP_ACTIVITY_PROBE=(
  [claude]=".claude/projects|-name *.jsonl"
  [codex]=".codex/sessions|-name rollout-*.jsonl"
  [grok]=".grok/sessions|( -name *.json -o -name *.sqlite* )"
  [opencode]=".local/share/opencode/storage|-name *.json"
  [antigravity]=".gemini/antigravity-cli/brain|-name transcript*.jsonl"
)

# Newest matching transcript mtime (epoch, or empty) for one agent, per type.
# Read-only; unreadable/absent root => empty (caller treats as unknown age).
_sup_activity_epoch() {  # <type> <home>
  local type="$1" home="$2" probe root fargs
  probe="${_SUP_ACTIVITY_PROBE[$type]:-}"
  [[ -n "$probe" ]] || return 0
  root="${probe%%|*}"; fargs="${probe#*|}"
  [[ -d "$home/$root" ]] || return 0
  # shellcheck disable=SC2086 -- fargs is a deliberate word-split find predicate
  { find "$home/$root" -type f $fargs -printf '%T@\n' 2>/dev/null || true; } \
    | sort -rn | head -1 | cut -d. -f1
}

# Goal-drift (DIVE-971): claude-only, transcript-scoped, STRUCTURAL — no
# semantic relevance heuristic. Echoes the drifting DIVE task id when ALL hold,
# empty otherwise (false-negative bias — any missing/ambiguous signal => empty):
#   * the agent is actively progressing (activity within the slow window) — this
#     is "working the wrong thing", orthogonal to no-progress/idle/stuck;
#   * an active /goal exists (last set-marker not superseded by a later
#     `/goal clear`) and is older than the slow window (so the set->start race
#     right after the heartbeat arms a goal never flags);
#   * the goal condition names a DIVE task whose status is still `todo` —
#     untouched by ANY agent (in_progress-by-anyone or terminal => not drift).
_sup_goal_drift() {  # <type> <home> <name> <now> <act_epoch>
  local type="$1" home="$2" name="$3" now="$4" act_epoch="$5"
  [[ "$type" == "claude" ]] || return 0
  [[ "$act_epoch" =~ ^[0-9]+$ ]] || return 0
  (( now - act_epoch < _SUP_T_SLOW_MIN * 60 )) || return 0
  local tx
  tx=$( { find "$home/.claude/projects" -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null || true; } \
        | sort -rn | head -1 | cut -d' ' -f2-)
  [[ -n "$tx" && -r "$tx" ]] || return 0
  # One JSONL record == one physical line, so a line match == a record match.
  local set_ln clr_ln
  set_ln=$(grep -n 'session-scoped Stop hook is now active with condition' "$tx" 2>/dev/null | tail -1 | cut -d: -f1)
  [[ -n "$set_ln" ]] || return 0
  # A `/goal clear` record carries the short args tag; set records carry the
  # long condition text, so this exact string never matches a set line.
  clr_ln=$(grep -n '<command-args>clear</command-args>' "$tx" 2>/dev/null | tail -1 | cut -d: -f1)
  [[ -n "$clr_ln" ]] && (( clr_ln > set_ln )) && return 0
  local setline set_ts set_epoch
  setline=$(sed -n "${set_ln}p" "$tx")
  set_ts=$(grep -oE '"timestamp":"[^"]+"' <<<"$setline" | head -1 | cut -d'"' -f4)
  [[ -n "$set_ts" ]] && set_epoch=$(date -d "$set_ts" +%s 2>/dev/null) || set_epoch=""
  [[ "$set_epoch" =~ ^[0-9]+$ ]] && (( now - set_epoch < _SUP_T_SLOW_MIN * 60 )) && return 0
  local task
  task=$(grep -oE 'DIVE-[0-9]+' <<<"$setline" | head -1 | grep -oE '[0-9]+')
  [[ -n "$task" ]] || return 0
  local st
  st=$(db "SELECT status FROM tasks WHERE id=${task};" 2>/dev/null || echo "")
  # Only a still-untouched (todo) target is drift; in_progress (by anyone) or
  # any terminal/blocked state means the goal is being served or is satisfied.
  [[ "$st" == "todo" ]] || return 0
  echo "$task"
}

_sup_usage() {
  cat <<USAGE
5dive supervisor — observe-only fleet health board (DIVE-724 P1)

  5dive supervisor                 # per-agent board: detect + classify, zero actions
  5dive supervisor --watch[=secs]  # live repaint (default 5s; q quits)
  5dive supervisor --tick          # cron-callable observe pass (root): detect +
                                   # classify + append audit rows to the
                                   # supervisor_events table (tasks.db).
                                   # No-ops unless ${_SUP_ENABLED_FLAG} exists.

Classification (conservative — see docs/fleet-supervisor-design.md §4):
  healthy         running + progressing, or legitimately idle/stopped with no active work
  slow            active work but no transcript progress for ${_SUP_T_SLOW_MIN}m+ — recorded, never acted on
  update-pending  box CLI is behind the published release — an update signal, NOT
                  a wedged agent (cause: stale-cli); recorded, NEVER acted on (DIVE-974)
  stuck           service/tmux/poller dead, a loop self-flagged stuck, or no progress
                  for ${_SUP_T_STUCK_MIN}m+ with active work
                  (cause: service-dead|tmux-dead|poller-dead|loop-stuck|no-progress)
  drift           active /goal targets a still-todo DIVE task while the agent
                  progresses elsewhere (cause: goal-drift) — recorded, NEVER acted on

Poller + activity signals cover claude/codex/grok/antigravity/opencode (DIVE-971).
P1 takes ZERO recovery actions. Add --json to any form for machine output.
USAGE
}

# One box-level CLI-staleness probe per process (the fleet shares one binary,
# so this is NOT per-agent). Mirrors cmd_update_check's read-only logic:
# behind = installed < published; stale = behind AND the nightly soft-update
# isn't closing the gap. Best-effort — no network / no published version means
# staleness stays "unknown" and NEVER classifies anyone stuck (a flaky probe
# must not be a stuck signal).
_SUP_CLI_CHECKED=0
_SUP_CLI_LATEST=""
_SUP_CLI_BEHIND="unknown"
_SUP_CLI_STALE="unknown"
_sup_cli_check() {
  (( _SUP_CLI_CHECKED )) && return 0
  _SUP_CLI_CHECKED=1
  command -v curl >/dev/null 2>&1 || return 0
  local latest
  latest=$(curl -fsSL --max-time 5 "https://raw.githubusercontent.com/$(gh_org)/5dive/main/5dive" 2>/dev/null \
    | grep -m1 -oP '(?<=^readonly FIVE_VERSION=")[^"]+') || true
  [[ -n "$latest" ]] || return 0
  _SUP_CLI_LATEST="$latest"
  if ! version_lt "$FIVE_VERSION" "$latest"; then
    _SUP_CLI_BEHIND="false"; _SUP_CLI_STALE="false"
    return 0
  fi
  _SUP_CLI_BEHIND="true"
  # Same nightly-log heuristic as cmd_update_check: a healthy recent nightly
  # means the gap closes on its own (behind-but-fine); a failed/absent/old one
  # means the box is genuinely running old code.
  # No readable nightly log => UNKNOWN, never stale (day-1 audit finding,
  # 2026-07-02): the control host has no soft-updates log, so "behind"
  # minutes after a release cut flagged every claude agent stuck/stale-cli.
  # Absence of evidence is not a stuck signal — same doctrine as the probe
  # itself. A box is only STALE on positive evidence: the last nightly
  # attempt failed, or the last successful one is older than the update
  # window (nightly had its chance and the gap is still open).
  local log="/tmp/claude-soft-updates.log" stale="unknown"
  if [[ -r "$log" ]]; then
    local start_line ok_last=true last_at last_epoch=""
    start_line=$(grep -n "soft updates start" "$log" | tail -1 | cut -d: -f1) || start_line=""
    if [[ -n "$start_line" ]] && tail -n "+${start_line}" "$log" | grep -q "CLI upgrade via install.5dive.com failed"; then
      ok_last=false
    fi
    last_at=$(grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:+-]+ soft updates done" "$log" \
      | tail -1 | grep -oE "^[^ ]+") || last_at=""
    [[ -n "$last_at" ]] && last_epoch=$(date -d "$last_at" +%s 2>/dev/null) || last_epoch=""
    if [[ "$ok_last" == false ]]; then
      stale=true
    elif [[ -n "$last_epoch" ]]; then
      if (( $(date +%s) - last_epoch <= UPDATE_STALE_AFTER_SECS )); then
        stale=false
      else
        stale=true
      fi
    fi
  fi
  _SUP_CLI_STALE="$stale"
}

# Detect + classify ONE agent -> one compact JSON record on stdout.
# args: name type channels unit user tmux-session home now-epoch
_sup_agent_record() {
  local name="$1" type="$2" channels="$3" unit="$4" user="$5" sess="$6" home="$7" now="$8" desired="${9:-}"

  # --- signal: systemd unit state + uptime (for the poller boot grace) ---
  local props active sub ts_str uptime=0
  props=$(systemctl show "$unit" --property=ActiveState,SubState,ActiveEnterTimestamp --no-page 2>/dev/null || true)
  active=$(awk -F= '/^ActiveState=/{print $2}'         <<<"$props")
  sub=$(awk    -F= '/^SubState=/{print $2}'            <<<"$props")
  ts_str=$(awk -F= '/^ActiveEnterTimestamp=/{print $2}' <<<"$props")
  local svc_running=0
  case "$active" in active|activating|reloading) svc_running=1 ;; esac
  if (( svc_running )) && [[ -n "$ts_str" && "$ts_str" != "n/a" ]]; then
    local since; since=$(date -d "$ts_str" +%s 2>/dev/null || echo "")
    [[ -n "$since" ]] && uptime=$((now - since))
  fi

  # --- signal: tmux session liveness (as the agent's own user) ---
  # Only probeable with root (the sudo hop); without it — or with the service
  # down, where "no session" is implied and uninteresting — report "unknown",
  # which never classifies (false-negative bias).
  local tmux_state="unknown"
  if (( svc_running )) && [[ $EUID -eq 0 ]]; then
    if sudo -n -u "$user" tmux has-session -t "$sess" 2>/dev/null; then
      tmux_state="alive"
    else
      tmux_state="dead"
    fi
  fi

  # --- signal: telegram poller liveness (per-type, DIVE-971) ---
  # Each type's telegram bridge is a bun process whose argv carries its plugin
  # dir (_SUP_POLLER_PAT); a pgrep against the agent user is cheaper than
  # doctor's MCP-log reasoning and answers "alive right now". Grace window right
  # after a service start (bridge boot lag). Types with no probeable bridge, or
  # any non-telegram channel set, stay "n/a" (never classifies).
  local poller="n/a" poller_pat="${_SUP_POLLER_PAT[$type]:-}"
  if [[ -n "$poller_pat" && ",${channels}," == *",telegram,"* ]]; then
    if pgrep -u "$user" -f "$poller_pat" >/dev/null 2>&1; then
      poller="alive"
    elif (( ! svc_running )) || (( uptime > 0 && uptime < _SUP_POLLER_GRACE_SEC )); then
      poller="unknown"
    else
      poller="dead"
    fi
  fi

  # --- signals from the shared store: loop stuck flag + active work ---
  local loop_stuck running_loops inprog
  loop_stuck=$(db "SELECT COUNT(*) FROM loop_runs WHERE spawned_by_agent=$(sqlq "$name") AND status='running' AND stuck=1;" 2>/dev/null || echo 0)
  running_loops=$(db "SELECT COUNT(*) FROM loop_runs WHERE spawned_by_agent=$(sqlq "$name") AND status='running';" 2>/dev/null || echo 0)
  inprog=$(db "SELECT COUNT(*) FROM tasks WHERE assignee=$(sqlq "$name") AND status='in_progress' AND kind='standard';" 2>/dev/null || echo 0)
  [[ "$loop_stuck"    =~ ^[0-9]+$ ]] || loop_stuck=0
  [[ "$running_loops" =~ ^[0-9]+$ ]] || running_loops=0
  [[ "$inprog"        =~ ^[0-9]+$ ]] || inprog=0
  local has_work=0
  (( inprog > 0 || running_loops > 0 )) && has_work=1

  # --- signal: last-activity / progress timestamp (per-type transcript mtime) ---
  # DIVE-971: per-type roots+globs (_sup_activity_epoch) replace the claude-only
  # probe — codex/grok/antigravity/opencode now get a real progress age. A type
  # with no probe, or an empty/unreadable root, leaves age unknown and can never
  # be classified stuck/no-progress (false-negative bias).
  local act_epoch act_age=-1
  act_epoch=$(_sup_activity_epoch "$type" "$home")
  [[ "$act_epoch" =~ ^[0-9]+$ ]] && act_age=$(( now - act_epoch ))

  # --- signal: goal-drift (per-type; claude-only inside the helper) ---
  # DIVE-971: an active /goal targets a still-untouched DIVE task while the agent
  # progresses elsewhere. Observe-only — never feeds the P2 act ladder.
  local goal_drift_task; goal_drift_task=$(_sup_goal_drift "$type" "$home" "$name" "$now" "$act_epoch")

  # --- CLASSIFY (design §4) — first matching rule wins, dead-signals first.
  # Every "stuck" here is a DEFINITE reading; anything unknown/ambiguous falls
  # through toward healthy. An intentionally-stopped agent (unit inactive, not
  # failed, nothing assigned in flight) is "healthy (stopped)", NOT stuck —
  # `5dive agent stop` is an operator choice, and the registry has no
  # desired-state field to tell us otherwise.
  local class="healthy" cause="" detail=""
  # desiredState (P2, DIVE-857 prereq b): an operator's explicit stop/start
  # beats inference. Recorded by `5dive agent stop|start`; absent on legacy
  # agents => the P1 inference path below, unchanged.
  if [[ "$desired" == "stopped" ]] && (( ! svc_running )) && [[ "$active" != "failed" ]]; then
    detail="stopped (desired)"
  elif (( ! svc_running )); then
    if [[ "$active" == "failed" ]] || (( has_work )) || [[ "$desired" == "running" ]]; then
      class="stuck"; cause="service-dead"; detail="unit ${active:-unknown}${desired:+ (desired: $desired)}"
    else
      detail="stopped (no active work)"
    fi
  elif [[ "$tmux_state" == "dead" ]]; then
    class="stuck"; cause="tmux-dead"; detail="unit active but tmux session '${sess}' gone"
  elif [[ "$poller" == "dead" ]]; then
    class="stuck"; cause="poller-dead"; detail="telegram poller process not running"
  elif (( loop_stuck > 0 )); then
    class="stuck"; cause="loop-stuck"; detail="${loop_stuck} running loop(s) self-flagged stuck"
  elif (( has_work )) && (( act_age >= 0 )) && (( act_age >= _SUP_T_STUCK_MIN * 60 )); then
    class="stuck"; cause="no-progress"; detail="active work, no transcript progress for $((act_age / 60))m"
  elif [[ "$_SUP_CLI_STALE" == "true" ]]; then
    # Box-level: the shared CLI is behind AND the nightly isn't catching up
    # (the /tmp-clobber class) — every agent is executing old code. Requires a
    # confirmed probe; "unknown" never lands here. This is an UPDATE-PENDING
    # signal, NOT a wedged agent (DIVE-974): the agents are healthy, just one
    # release behind, so it MUST NOT classify as stuck — the P2 act loop only
    # touches class=="stuck", and a stale-cli tick right after every release cut
    # would otherwise nudge/resume/rotate/escalate the entire healthy fleet.
    class="update-pending"; cause="stale-cli"; detail="box CLI ${FIVE_VERSION} stale behind ${_SUP_CLI_LATEST}"
  elif (( has_work )) && (( act_age >= 0 )) && (( act_age >= _SUP_T_SLOW_MIN * 60 )); then
    class="slow"; detail="active work, no transcript progress for $((act_age / 60))m"
  elif [[ -n "$goal_drift_task" ]]; then
    # Disjoint from slow/stuck by construction (drift needs recent activity).
    # Observe-only: the P2 act loop is gated on class=="stuck", so this never
    # nudges/resumes/rotates — surfaced for the audit trail and board only.
    class="drift"; cause="goal-drift"
    detail="active /goal targets DIVE-${goal_drift_task} (still todo); agent progressing elsewhere"
  elif (( has_work )); then
    detail="active"
  else
    detail="idle"
  fi

  jq -cn \
    --arg name "$name" --arg type "$type" --arg channels "$channels" --arg unit "$unit" \
    --arg service "${active:-unknown}" --arg sub "${sub:-}" \
    --arg tmux "$tmux_state" --arg poller "$poller" \
    --argjson loopStuck "$loop_stuck" --argjson runningLoops "$running_loops" \
    --argjson inProgress "$inprog" --argjson age "$act_age" --argjson uptime "$uptime" \
    --arg goalDrift "$goal_drift_task" \
    --arg class "$class" --arg cause "$cause" --arg detail "$detail" \
    '{name:$name, type:$type, channels:$channels, unit:$unit,
      signals:{service:$service, sub:$sub, uptimeSec:$uptime, tmux:$tmux, poller:$poller,
               loopStuck:$loopStuck, runningLoops:$runningLoops, inProgress:$inProgress,
               lastActivityAgeSec:(if $age < 0 then null else $age end),
               goalDriftTask:(if $goalDrift == "" then null else ($goalDrift|tonumber) end)},
      classification:$class,
      cause:(if $cause == "" then null else $cause end),
      detail:$detail}'
}

# Full-fleet snapshot -> JSON array. Registered agents plus the box's main
# `claude` user (claude-session.service) when that unit is meant to run —
# enabled or currently active. A disabled+inactive unit means the box's main
# user doesn't operate that way; listing it would be a permanent false alarm.
_sup_snapshot() {
  local reg now
  reg=$(registry_read)
  now=$(date +%s)
  # NB: callers must run _sup_cli_check in THEIR shell first — _sup_snapshot is
  # invoked via $(…), so globals the probe sets in here would die with the
  # subshell and the summary/JSON would report "unknown". This call is then a
  # guarded no-op (already-checked) that only matters if snapshot is called bare.
  _sup_cli_check
  local rows="" name type channels
  for name in $(jq -r '.agents | keys[]' <<<"$reg" 2>/dev/null); do
    type=$(jq     -r --arg n "$name" '.agents[$n].type // "claude"'     <<<"$reg")
    channels=$(jq -r --arg n "$name" '.agents[$n].channels // "none"'   <<<"$reg")
    local desired; desired=$(jq -r --arg n "$name" '.agents[$n].desiredState // ""' <<<"$reg")
    rows+=$(_sup_agent_record "$name" "$type" "$channels" \
      "5dive-agent@${name}.service" "agent-${name}" "agent-${name}" "/home/agent-${name}" "$now" "$desired")
    rows+=$'\n'
  done
  local cs_enabled cs_active
  cs_enabled=$(systemctl is-enabled claude-session.service 2>/dev/null || true)
  cs_active=$(systemctl is-active  claude-session.service 2>/dev/null || true)
  if [[ "$cs_enabled" == "enabled" || "$cs_active" == "active" ]]; then
    # Session name "claude" per the unit's ExecStop; transcripts under /home/claude.
    rows+=$(_sup_agent_record "claude" "claude" "none" \
      "claude-session.service" "claude" "claude" "/home/claude" "$now")
    rows+=$'\n'
  fi
  printf '%s' "$rows" | jq -s -c '.'
}

# Text board: one row per agent. Activity age humanized; "-" = unknown.
_sup_render_board() {
  local snap="$1"
  jq -r '
    def age: if . == null then "-"
             elif . < 3600 then "\(. / 60 | floor)m"
             elif . < 86400 then "\(. / 3600 | floor)h \((. % 3600) / 60 | floor)m"
             else "\(. / 86400 | floor)d \((. % 86400) / 3600 | floor)h" end;
    if length == 0 then "no agents registered (5dive agent create <name> --type=claude)" else
      (["AGENT","TYPE","SERVICE","CLASS","CAUSE","ACTIVITY","DETAIL"] | @tsv),
      (.[] | [ .name, .type, .signals.service, .classification, (.cause // "-"),
               (.signals.lastActivityAgeSec | age), (.detail // "-") ] | @tsv)
    end' <<<"$snap" | column -t -s $'\t'
}

# Post-table summary: counts + the box-level CLI probe result.
_sup_summary_line() {
  local snap="$1"
  jq -r --arg stale "$_SUP_CLI_STALE" --arg cur "$FIVE_VERSION" --arg lat "$_SUP_CLI_LATEST" '
    "\(length) agents — " +
    "\([.[] | select(.classification == "healthy")]        | length) healthy / " +
    "\([.[] | select(.classification == "slow")]           | length) slow / " +
    "\([.[] | select(.classification == "drift")]          | length) drift / " +
    "\([.[] | select(.classification == "update-pending")] | length) update-pending / " +
    "\([.[] | select(.classification == "stuck")]          | length) stuck" +
    (if $stale == "true" then " · CLI \($cur) STALE (latest \($lat))"
     elif $stale == "unknown" then " · CLI staleness unknown (probe unavailable)"
     else " · CLI \($cur) ok" end)' <<<"$snap"
}

# --watch[=secs]: repaint inside the alt-screen (cmd_watch's escape constants),
# q / Ctrl-C to quit. Deliberately simpler than cmd_watch — no selection or
# attach; this is a health board, not a control surface (P1 = zero actions).
_sup_watch() {
  local interval="$1"
  [[ -t 1 && -t 0 ]] || fail "$E_USAGE" "supervisor --watch requires a TTY (try running it directly, not piped)"
  _sup_watch_teardown() { printf '%s%s%s' "$WATCH_SHOW" "$WATCH_RESET" "$WATCH_ALT_OFF"; }
  trap '_sup_watch_teardown; exit 130' INT TERM
  trap '_sup_watch_teardown' EXIT
  printf '%s%s' "$WATCH_ALT_ON" "$WATCH_HIDE"
  _sup_cli_check   # once per watch session, in this shell (see _sup_snapshot)
  while true; do
    local snap board summary out
    snap=$(_sup_snapshot)
    board=$(_sup_render_board "$snap")
    summary=$(_sup_summary_line "$snap")
    out="${WATCH_BOLD}${WATCH_CYAN}5dive supervisor${WATCH_RESET} · observe-only · $(date '+%F %T')"$'\n\n'
    out+="$board"$'\n\n'
    out+="${WATCH_DIM}${summary} · refresh: ${interval}s · q quit${WATCH_RESET}"
    printf '%s%s%s' "$WATCH_HOME" "$out" "$WATCH_CLR_DOWN"
    local key=""
    if IFS= read -rsn1 -t "$interval" key; then
      case "$key" in q|Q) break ;; esac
    fi
  done
}

# --tick: the cron-callable observe pass — detect + classify + AUDIT, nothing
# else. Appends to supervisor_events (see tasks_db.sh): one 'observe' row per
# agent per tick when classification != healthy, plus one 'transition' row
# whenever an agent's classification changed since its last recorded row
# (including recovery back to healthy, so the trail shows both edges). The
# previous classification is derived from the agent's latest event row —
# healthy when it has none — so the tick needs no extra state file.
# ── P2 (DIVE-857): recovery ladder — ACT + ESCALATE (design §5–6) ───────────
# Auto-act is deliberately narrow: claude-type agents, causes where the session
# is alive but wedged (no-progress, loop-stuck). Everything else stuck needs
# rung 4+ (restart/reprovision = P3/manual), so it ESCALATES: one audit row per
# window, zero mutations. Rungs, in order: nudge -> resume -> rotate.

# attempts + last-action epoch for an agent inside the rolling window, straight
# from the audit trail (no extra state file — same principle as the tick's
# transition detection). Echoes "attempts lastEpoch" (lastEpoch=0 when none).
_sup_act_history() {
  local name="$1" n last
  n=$(db "SELECT COUNT(*) FROM supervisor_events
          WHERE agent=$(sqlq "$name") AND event='action'
            AND ts >= datetime('now', '-${_SUP_ACT_WINDOW_H} hours');" 2>/dev/null || echo 0)
  last=$(db "SELECT COALESCE(strftime('%s', MAX(ts)), 0) FROM supervisor_events
             WHERE agent=$(sqlq "$name") AND event='action'
               AND ts >= datetime('now', '-${_SUP_ACT_WINDOW_H} hours');" 2>/dev/null || echo 0)
  echo "${n:-0} ${last:-0}"
}

# Pure decision, no side effects: echoes "verb [reason]" where verb is one of
# nudge|resume|rotate|escalate|defer. Attempt N picks rung N+1; the gap before
# the next action is base * 2^attempts; ladder exhausted / unreachable rung
# => escalate.
_sup_act_plan() {  # <type> <cause> <attempts> <last_epoch> <now> <rotation_enabled>
  local type="$1" cause="$2" attempts="$3" last="$4" now="$5" rot="$6"
  case "$cause" in
    no-progress|loop-stuck) : ;;
    # DIVE-974: stale-cli is update-pending, not stuck — it never reaches this
    # loop (gated on class=="stuck") but guard here too so no rung, including
    # escalate, can EVER fire on a stale-cli-only classification.
    stale-cli) echo "defer update-pending"; return ;;
    # DIVE-971: goal-drift is class=="drift", not "stuck", so it never reaches
    # this loop (gated on stuck) — guard here too so no rung, not even escalate,
    # can EVER fire on a drift classification.
    goal-drift) echo "defer goal-drift"; return ;;
    *) echo "escalate rung-4-needed"; return ;;
  esac
  [[ "$type" == "claude" ]] || { echo "escalate non-claude-runtime"; return; }
  (( attempts >= _SUP_ACT_MAX_ATTEMPTS )) && { echo "escalate ladder-exhausted"; return; }
  local gap=$(( _SUP_ACT_BASE_MIN * 60 * (1 << attempts) ))
  if (( last > 0 && now - last < gap )); then echo "defer backoff"; return; fi
  case "$attempts" in
    0) echo "nudge" ;;
    1) echo "resume" ;;
    2) if [[ "$rot" == "true" ]]; then echo "rotate"; else echo "escalate rotation-disabled"; fi ;;
  esac
}

# Execute one rung. Returns nonzero, never exits — one bad agent can't abort
# the tick (rotation's fail() is contained in a subshell).
_sup_act_exec() {  # <name> <verb> <cause>
  local name="$1" verb="$2" cause="$3"
  case "$verb" in
    nudge)
      _hb_send_line "$name" "[supervisor] You look stalled (${cause}). Pick your in-progress task back up and continue; if genuinely blocked, say why on the task." ;;
    resume)
      # Clear a wedged modal/prompt first, then ask for plain continuation.
      sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" Escape 2>/dev/null || return 1
      sleep 1
      _hb_send_line "$name" "continue" ;;
    rotate)
      ( with_registry_lock cmd_agent_rotation_rotate "$name" ) >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

cmd_supervisor_tick() {
  require_root "supervisor --tick"
  if [[ ! -f "$_SUP_ENABLED_FLAG" ]]; then
    ok "supervisor tick: disabled — observe pass skipped (enable: sudo touch ${_SUP_ENABLED_FLAG})" \
       '{enabled:false, skipped:true}'
    return 0
  fi
  tasks_db_init
  _sup_cli_check   # in this shell, not the $(…) subshell — see _sup_snapshot
  local snap; snap=$(_sup_snapshot)
  local events=0 row name class cause last
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    name=$(jq -r '.name' <<<"$row")
    class=$(jq -r '.classification' <<<"$row")
    cause=$(jq -r '.cause // ""' <<<"$row")
    last=$(db "SELECT classification FROM supervisor_events WHERE agent=$(sqlq "$name") ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
    [[ -n "$last" ]] || last="healthy"
    if [[ "$class" != "$last" ]]; then
      db "INSERT INTO supervisor_events (agent, event, classification, cause, prev_classification, signals)
          VALUES ($(sqlq "$name"), 'transition', $(sqlq "$class"), $(sqlq_or_null "$cause"), $(sqlq "$last"), $(sqlq "$row"));" \
        2>/dev/null && events=$((events + 1)) || warn "supervisor: transition insert failed for $name"
    fi
    if [[ "$class" != "healthy" ]]; then
      db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
          VALUES ($(sqlq "$name"), 'observe', $(sqlq "$class"), $(sqlq_or_null "$cause"), $(sqlq "$row"));" \
        2>/dev/null && events=$((events + 1)) || warn "supervisor: observe insert failed for $name"
    fi
  done < <(jq -c '.[]' <<<"$snap")

  # ── P2 (DIVE-857): ACT + ESCALATE — pre-cleared by lodar 2026-07-02, gated on
  # $_SUP_ACTIONS_FLAG until the audit week (started 2026-07-02) is clean.
  # Dormant mode writes 'planned' rows: the Jul 9 review reads exactly what the
  # ladder WOULD have done all week. restart stays P3; reprovision manual.
  local actions_on="false" acted=0 planned=0 escalated=0 now_s
  [[ -f "$_SUP_ACTIONS_FLAG" ]] && actions_on="true"
  now_s=$(date +%s)
  local reg_now; reg_now=$(registry_read)
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    class=$(jq -r '.classification' <<<"$row")
    [[ "$class" == "stuck" ]] || continue
    name=$(jq -r '.name' <<<"$row"); cause=$(jq -r '.cause // ""' <<<"$row")
    local atype rot attempts last plan verb reason
    atype=$(jq -r '.type' <<<"$row")
    rot=$(jq -r --arg n "$name" '.agents[$n].rotation.enabled // false' <<<"$reg_now")
    read -r attempts last <<<"$(_sup_act_history "$name")"
    plan=$(_sup_act_plan "$atype" "$cause" "$attempts" "$last" "$now_s" "$rot")
    read -r verb reason <<<"$plan"
    case "$verb" in
      defer|"") continue ;;
      escalate)
        local esc
        esc=$(db "SELECT COUNT(*) FROM supervisor_events
                  WHERE agent=$(sqlq "$name") AND event='escalate'
                    AND ts >= datetime('now', '-${_SUP_ACT_WINDOW_H} hours');" 2>/dev/null || echo 0)
        (( esc > 0 )) && continue
        db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
            VALUES ($(sqlq "$name"), 'escalate', 'stuck', $(sqlq_or_null "$cause"),
                    $(sqlq "{\"reason\":\"${reason}\",\"attempts\":${attempts}}"));" 2>/dev/null \
          && { escalated=$((escalated + 1)); events=$((events + 1)); } \
          || warn "supervisor: escalate insert failed for $name"
        warn "supervisor: ESCALATE $name ($cause: $reason) — needs rung-4+/human"
        ;;
      nudge|resume|rotate)
        if [[ "$actions_on" == "true" ]]; then
          local rc=0 res="ok"
          _sup_act_exec "$name" "$verb" "$cause" || { rc=$?; res="failed"; }
          db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
              VALUES ($(sqlq "$name"), 'action', 'stuck', $(sqlq_or_null "$cause"),
                      $(sqlq "{\"rung\":\"${verb}\",\"attempt\":$((attempts + 1)),\"result\":\"${res}\"}"));" 2>/dev/null \
            && { acted=$((acted + 1)); events=$((events + 1)); } \
            || warn "supervisor: action insert failed for $name"
        else
          # One planned row per agent per window — evidence, not spam.
          local pln
          pln=$(db "SELECT COUNT(*) FROM supervisor_events
                    WHERE agent=$(sqlq "$name") AND event='planned'
                      AND ts >= datetime('now', '-${_SUP_ACT_WINDOW_H} hours');" 2>/dev/null || echo 0)
          (( pln > 0 )) && continue
          db "INSERT INTO supervisor_events (agent, event, classification, cause, signals)
              VALUES ($(sqlq "$name"), 'planned', 'stuck', $(sqlq_or_null "$cause"),
                      $(sqlq "{\"rung\":\"${verb}\",\"attempt\":$((attempts + 1)),\"dormant\":true}"));" 2>/dev/null \
            && { planned=$((planned + 1)); events=$((events + 1)); } \
            || warn "supervisor: planned insert failed for $name"
        fi
        ;;
    esac
  done < <(jq -c '.[]' <<<"$snap")

  local total healthy slow stuck drift
  total=$(jq 'length' <<<"$snap")
  healthy=$(jq '[.[] | select(.classification == "healthy")] | length' <<<"$snap")
  slow=$(jq  '[.[] | select(.classification == "slow")]    | length' <<<"$snap")
  stuck=$(jq '[.[] | select(.classification == "stuck")]   | length' <<<"$snap")
  drift=$(jq '[.[] | select(.classification == "drift")]   | length' <<<"$snap")

  # DIVE-975: one 'heartbeat' row per tick — the observation DENOMINATOR. The
  # transition/observe rows above are sporadic by nature (a clean fleet writes
  # none), so an all-healthy week left supervisor_events empty and DIVE-970 had
  # no window to measure a false-positive RATE against. This additive summary
  # row makes the table grow on every cron tick and records the fleet snapshot;
  # reviewers filter it out by event='heartbeat'. agent='(fleet)' is a sentinel.
  local fleet_class="healthy"
  (( slow + stuck > 0 )) && fleet_class="degraded"
  db "INSERT INTO supervisor_events (agent, event, classification, signals)
      VALUES ('(fleet)', 'heartbeat', $(sqlq "$fleet_class"),
              $(sqlq "{\"total\":${total},\"healthy\":${healthy},\"slow\":${slow},\"drift\":${drift},\"stuck\":${stuck},\"anomalyRows\":${events}}"));" \
    2>/dev/null && events=$((events + 1)) || warn "supervisor: heartbeat insert failed"

  local act_note=""
  if [[ "$actions_on" == "true" ]]; then act_note=" · actions ON: ${acted} acted / ${escalated} escalated"
  elif (( planned + escalated > 0 )); then act_note=" · dormant: ${planned} planned / ${escalated} escalated"
  fi
  ok "supervisor tick: ${total} agents — ${healthy} healthy / ${slow} slow / ${drift} drift / ${stuck} stuck · ${events} audit row(s)${act_note}" \
     '{enabled:true, agents:($t|tonumber), healthy:($h|tonumber), slow:($sl|tonumber), drift:($dr|tonumber), stuck:($st|tonumber), auditRows:($e|tonumber), actionsEnabled:($ae == "true"), acted:($ac|tonumber), planned:($pl|tonumber), escalated:($es|tonumber)}' \
     --arg t "$total" --arg h "$healthy" --arg sl "$slow" --arg dr "$drift" --arg st "$stuck" --arg e "$events" \
     --arg ae "$actions_on" --arg ac "$acted" --arg pl "$planned" --arg es "$escalated"
}

cmd_supervisor() {
  local mode="board" interval=5
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tick)         mode="tick" ;;
      --watch)        mode="watch" ;;
      --watch=*)      mode="watch"; interval="${1#--watch=}" ;;
      -h|--help|help) _sup_usage; return 0 ;;
      *) fail "$E_USAGE" "unknown supervisor flag: $1 (try: 5dive supervisor --help)" ;;
    esac
    shift
  done
  case "$mode" in
    tick) cmd_supervisor_tick ;;
    watch)
      [[ "$interval" =~ ^[0-9]+$ ]] && (( interval >= 1 && interval <= 300 )) \
        || fail "$E_VALIDATION" "--watch seconds must be 1-300"
      _sup_watch "$interval" ;;
    board)
      _sup_cli_check   # in this shell, not the $(…) subshell — see _sup_snapshot
      local snap; snap=$(_sup_snapshot)
      if (( JSON_MODE )); then
        # stdin, not --argjson (DIVE-222) — the snapshot can be large.
        printf '%s' "$snap" | jq -c \
          --arg cur "$FIVE_VERSION" --arg lat "$_SUP_CLI_LATEST" \
          --arg beh "$_SUP_CLI_BEHIND" --arg stl "$_SUP_CLI_STALE" \
          --argjson tstuck "$_SUP_T_STUCK_MIN" --argjson tslow "$_SUP_T_SLOW_MIN" \
          '{ok:true, data:{agents:.,
             cli:{current:$cur, latest:(if $lat == "" then null else $lat end), behind:$beh, stale:$stl},
             tStuckMin:$tstuck, tSlowMin:$tslow}}'
      else
        _sup_render_board "$snap"
        echo ""
        _sup_summary_line "$snap"
      fi ;;
  esac
}
