
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
#                           it to do a single task and then idle — and CLAIM
#                           that task (status=in_progress + started_at) in the
#                           same breath. DIVE-2244: the claim is the dispatcher's
#                           job, not the agent's. Until it was, the "already
#                           in_progress" arm above and the entire recovery layer
#                           (reaper / orphan reclaim / unwedge / stall detector)
#                           read a field nothing ever wrote — see _hb_claim_task.
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
# Starvation signal: a task nudged this many times without ever reaching 'done'
# is almost certainly being starved — e.g. the codex/grok listen-loop watchdog
# yanking the agent off the task right after the nudge. Per-task nudge counts
# live in the registry under .agents[<name>].heartbeat.nudges and are pruned once
# a task leaves todo.
#
# DIVE-2244 changed the MECHANISM this detects, not the conclusion. Before, the
# dispatcher never claimed, so a starved task simply sat in 'todo' and got
# re-nudged every cadence; this counter was the only thing that noticed. Now the
# dispatcher claims at the nudge, so reaching this count means the task was
# claimed and then RECLAIMED back to todo (rule a/b/c) that many times. Either
# way: nudges are not converting into finished work, and re-nudging forever
# without saying so is the failure. Note the counter still works only because
# the claim is stamped AFTER _hb_mark_run — see the call site.
_HB_STARVE_AFTER=3

# DIVE-3218 — nudge-threshold ENFORCEMENT, the rung above _HB_STARVE_AFTER.
#
# _hb_mark_run has echoed a per-task nudge count since DIVE-1486 "so the caller
# can decide whether the task is being starved". Until now the only caller that
# read it LOGGED (the WARN under _HB_STARVE_AFTER, at the call site) and changed
# nothing. Measured 2026-08-11: dev3 was woken about ONE urgent row, DIVE-2896,
# 173 times over 3.5 days with zero state change — every wake a full fresh-context
# opus session that re-read the same stale in-row note, re-derived the same "wait"
# conclusion and exited, with no memory that it had done so 172 times already.
# A counter nobody consumes is detection, not enforcement:
#   community/wiki/a-nudge-counter-nobody-consumes-is-detection-not-enforcement.md
#
# _HB_STARVE_AFTER STAYS AS IT IS. It is a cheap, early, per-tick observation at
# n>=3 feeding the `starved` tally in the tick summary; this ladder is a separate,
# far higher bar that ACTS. Lowering the log threshold to meet the action, or
# raising it to hide it, would silently redefine an emitted signal — the readers
# of `starved` are the tick summary line and its JSON, both in this file, and
# neither is touched here.
#
# THRESHOLDS ARE PER PRIORITY BAND: the cost of a wasted wake is identical across
# bands but the tolerable latency is not — an urgent row must cross in HOURS, a
# low one may take a day. They count NUDGES, not hours, because the count is the
# burn: a row nudged 8 times has cost 8 whole sessions whatever the wall clock
# says. At the common 15-minute cadence these are roughly 2h / 4h / 8h / 16h to
# the first rung, and double that to the second.
_HB_NUDGE_ENFORCE_AFTER_URGENT=8
_HB_NUDGE_ENFORCE_AFTER_HIGH=16
_HB_NUDGE_ENFORCE_AFTER_MEDIUM=32
_HB_NUDGE_ENFORCE_AFTER_LOW=64

# Resolve the first-rung threshold N for a priority band. Registry
# `.config.heartbeat.nudgeEnforceAfter.<band>` wins when it is a positive
# integer; otherwise the compiled default above. Config rather than a bare
# hardcode (DIVE-3218) because the right N is fleet-shaped — it moves with tick
# cadence and roster size — and must be tunable without a release cut.
#
# A MISSING OR GARBLED CONFIG FALLS BACK TO THE DEFAULT, NEVER TO "OFF". An
# unreadable registry silently restoring the 173-wake world is the exact failure
# this ladder exists to end, so there is deliberately no value that disables it
# from config; raise N instead.
_hb_nudge_enforce_after() {
  local band="$1" reg="${2:-}" v="" dflt
  case "$band" in
    urgent) dflt=$_HB_NUDGE_ENFORCE_AFTER_URGENT ;;
    high)   dflt=$_HB_NUDGE_ENFORCE_AFTER_HIGH ;;
    low)    dflt=$_HB_NUDGE_ENFORCE_AFTER_LOW ;;
    *)      dflt=$_HB_NUDGE_ENFORCE_AFTER_MEDIUM ;;
  esac
  [[ -n "$reg" ]] || reg=$(registry_read 2>/dev/null) || reg=""
  if [[ -n "$reg" ]]; then
    v=$(jq -r --arg b "$band" '.config.heartbeat.nudgeEnforceAfter[$b] // empty' <<<"$reg" 2>/dev/null || echo "")
  fi
  if [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 )); then printf '%s' "$v"; else printf '%s' "$dflt"; fi
}

# DIVE-2716 — how many of an agent's runnable todos the wake loop will step
# through looking for one the tier guard clears. Bounded on purpose: each
# candidate costs two small queries plus a registry read, and a queue where the
# first 25 rows are ALL held is a tier misconfiguration, not a scheduling
# problem. Hitting the cap is logged loudly (it means runnable rows past it were
# never examined) rather than passed off as "nothing to do".
_HB_PICK_SCAN=25

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
# DIVE-2693: how long a materialized RECURRING instance may sit todo-and-never-
# started before the sweep surfaces it. Hours, not minutes: a daily beat is
# allowed to be worked late in its own day, and only becomes a fault once it has
# outlived its own cadence and started suppressing the NEXT slot.
_HB_RECURRING_STALL_HOURS="${HEARTBEAT_RECURRING_STALL_HOURS:-24}"
[[ "$_HB_RECURRING_STALL_HOURS" =~ ^[0-9]+$ ]] || _HB_RECURRING_STALL_HOURS=24
# DIVE-2853: how long AFTER that one-shot notice an instance may still sit
# todo-and-never-started before the ladder CHANGES HANDS. Same default window as
# the first rung, so a daily beat gets one full extra cadence with its original
# assignee before the row moves. Detection bounds how long an outage is invisible;
# only this rung bounds the outage.
_HB_RECURRING_ESCALATE_HOURS="${HEARTBEAT_RECURRING_ESCALATE_HOURS:-24}"
[[ "$_HB_RECURRING_ESCALATE_HOURS" =~ ^[0-9]+$ ]] || _HB_RECURRING_ESCALATE_HOURS=24
# DIVE-2272: the fleet-wide fallback bound for on_overlap='spawn' templates that
# do not set their own overlap_bound. Defined ONCE in lib/tasks_db.sh because the
# scheduler and `task ls --recurring` must not be able to disagree about it — the
# DIVE-2055 rule for that table is that the listing cannot tell a different story
# than the materializer, and two independently-defaulted constants is exactly how
# that drifts.
_HB_OVERLAP_BOUND_DEFAULT="${TASKS_OVERLAP_BOUND_DEFAULT:-3}"
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
# DIVE-1666 usage-limit self-heal. A genuine permission/plan dialog is real
# in-flight work, so the no-clobber guard defers its nudge (rc 3) and never
# reclaims — correct. But the Claude Code USAGE/SPEND-LIMIT dialog ("You've hit
# your monthly spend limit / 1. Stop and wait for limit to reset  2. Upgrade
# your plan") is a DEAD-END: it never self-clears, so the same defer rule
# freezes the session permanently even after the account's 5h window rolls back
# to headroom (root cause of the 2026-07-21 ~4h fleet-stall). The heartbeat
# CLASSIFIES the open dialog: a usage-limit match is a reclaimable frozen
# session (agents are fresh:true → restart loses no context), throttled to this
# many minutes between self-heal restarts of the same agent so a still-limited
# account can't be churn-restarted every tick. Env-overridable.
_HB_USAGE_HEAL_THROTTLE_MIN="${HEARTBEAT_USAGE_HEAL_THROTTLE_MIN:-25}"
[[ "$_HB_USAGE_HEAL_THROTTLE_MIN" =~ ^[0-9]+$ ]] || _HB_USAGE_HEAL_THROTTLE_MIN=25
# DIVE-1677 — when a healthy peer proves the account has headroom (there's no
# real limit to reset), prefer PRESS-CONTINUE-in-place over a hard restart: the
# stale dialog is dismissed and the SAME session resumes (no /clear, no restart
# → conversation + context preserved). This many consecutive press-continue
# attempts (one per tick) may fire before we give up and fall back to the v1
# hard restart; keeps "resume in place, else restart within a couple ticks".
_HB_USAGE_PRESS_MAX="${HEARTBEAT_USAGE_PRESS_MAX:-2}"
[[ "$_HB_USAGE_PRESS_MAX" =~ ^[0-9]+$ ]] || _HB_USAGE_PRESS_MAX=2
# Idle probe window. An agent whose pane is byte-identical across this gap (and
# still shows its input prompt) is at rest; a working agent streams output or
# animates a spinner, so its pane changes between two samples. Deliberately dumb
# and CLI-agnostic — see _hb_agent_idle. Used to (a) never /clear+nudge an agent
# mid-turn/conversation and (b) gate idle-stall reclaim.
_HB_IDLE_SAMPLE_SEC=3

# --- DIVE-1858 Phase-1 wake-on-alert: opt-in wake_mode + wake-budget ----------
# Stage 1 (main 2026-07-24, staged plan A): a per-agent opt-in wake mode plus a
# wakes/day budget cap with cost-per-wake visibility. There is NO live auto-sleep
# here — that is Stage 2, held for main's pre-run lead review on a disposable
# non-critical test agent. The always-on dispatcher IS cmd_heartbeat_tick, which
# is already self-monitored (DIVE-1434 poller-liveness canary); Stage 1 only
# teaches it to respect the flag + budget so a chatty trigger can't thrash a
# cold agent into repeated cold-start wakes. always_on / un-capped agents are
# wholly unaffected — every gate below is additive and defaults to the current
# behaviour when no wake config exists.
_HB_WAKE_DEFAULT_CAP="${HEARTBEAT_WAKE_CAP:-24}"   # default wakes/day per cold agent
[[ "$_HB_WAKE_DEFAULT_CAP" =~ ^[0-9]+$ ]] || _HB_WAKE_DEFAULT_CAP=24
# Cost-per-wake display estimate (cold-start cost). DISPLAY ONLY — Phase 1 carries
# ZERO billing surface (olivia condition 4); pay-per-wake billing is a firewalled
# future lodar-only SPEND gate.
_HB_WAKE_COST_EST="${HEARTBEAT_WAKE_COST_EST:-cold-start (est. tokens; billing is Phase 2)}"

# Agents that must NEVER go cold (olivia condition 3: customer-facing/critical
# stay always-on). main + marketing are pinned; extend via the space-separated
# HEARTBEAT_WAKE_PROTECTED env. Returns 0 when the agent is protected.
_hb_wake_protected() {
  local name="$1" p
  for p in main marketing ${HEARTBEAT_WAKE_PROTECTED:-}; do
    [[ "$name" == "$p" ]] && return 0
  done
  return 1
}

# Echo an agent's wake mode (always_on | cold); defaults always_on when unset.
# Arg2 optional registry snapshot to avoid a re-read in hot paths.
_hb_wake_mode() {
  jq -r --arg n "$1" '.agents[$n].wake.mode // "always_on"' \
    <<<"${2:-$(registry_read)}" 2>/dev/null || echo always_on
}

# Budget check: return 0 if this agent may wake now, 1 if a cold agent has spent
# today's cap. always_on agents and cold agents with no cap set are never
# budgeted (return 0). Arg2 = today (YYYY-MM-DD), Arg3 = optional reg snapshot.
_hb_wake_budget_ok() {
  local name="$1" today="$2" reg="${3:-$(registry_read)}"
  [[ "$(_hb_wake_mode "$name" "$reg")" == "cold" ]] || return 0
  local cap day used
  cap=$(jq -r --arg n "$name" '.agents[$n].wake.budget.capPerDay // empty' <<<"$reg")
  [[ "$cap" =~ ^[0-9]+$ ]] || return 0   # no numeric cap => unlimited
  day=$(jq -r --arg n "$name" '.agents[$n].wake.budget.day // ""' <<<"$reg")
  used=$(jq -r --arg n "$name" '.agents[$n].wake.budget.wakesToday // 0' <<<"$reg")
  [[ "$day" == "$today" ]] || used=0     # a new day resets the counter
  [[ "$used" =~ ^[0-9]+$ ]] || used=0
  (( used < cap ))
}

# Record a wake against today's budget (day-rollover aware). No-op for
# always_on agents. Call under with_registry_lock, like _hb_mark_run.
_hb_wake_budget_inc() {
  local name="$1" today="$2"
  local reg; reg=$(registry_read)
  [[ "$(_hb_wake_mode "$name" "$reg")" == "cold" ]] || return 0
  jq --arg n "$name" --arg d "$today" --argjson defcap "$_HB_WAKE_DEFAULT_CAP" '
      ( .agents[$n].wake.budget // {} ) as $b
      | .agents[$n].wake.budget = {
          capPerDay: ($b.capPerDay // $defcap),
          day: $d,
          wakesToday: (if ($b.day // "") == $d then (($b.wakesToday // 0) + 1) else 1 end)
        }' <<<"$reg" | registry_write
}

# --- DIVE-1858 Phase-1 Stage 2: live auto-sleep -------------------------------
# Stage 2 (held for main's pre-run lead review): the reactive path's second half.
# The WAKE half already exists — _hb_wake does `systemctl start` on a stopped unit,
# so the tick already wakes a cold agent that has a due todo (budget-gated). What
# was missing is the SLEEP half: a cold + running agent that is confidently idle
# with NO open work is stopped after N idle minutes, so an on-demand agent isn't
# left burning a session between triggers. Every guard below is additive and only
# ever touches wake_mode=cold agents:
#   · always_on agents are never considered (default) — zero behaviour change;
#   · protected agents (main/marketing/HEARTBEAT_WAKE_PROTECTED) are never slept
#     even if mis-flagged cold (olivia condition 3, belt-and-suspenders);
#   · sleep fires ONLY on a CONFIRMED idle reading (_hb_agent_idle rc 0) with no
#     open assigned task — a busy/blocked/unknown pane disarms the timer;
#   · the dispatcher (this tick) stays always-on + self-monitored via the shipped
#     DIVE-1434 poller-liveness canary (olivia condition 2), so a slept agent with
#     a later trigger is always woken by a subsequent tick.
_HB_SLEEP_AFTER_MIN="${HEARTBEAT_SLEEP_AFTER_MIN:-15}"   # idle minutes before a cold agent sleeps
[[ "$_HB_SLEEP_AFTER_MIN" =~ ^[0-9]+$ ]] || _HB_SLEEP_AFTER_MIN=15

# Per-agent idle-before-sleep threshold (minutes); falls back to the global default.
_hb_sleep_after_min() {
  local name="$1" reg="${2:-$(registry_read)}" v
  v=$(jq -r --arg n "$name" '.agents[$n].wake.sleepAfterMin // empty' <<<"$reg" 2>/dev/null)
  if [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 )); then echo "$v"; else echo "$_HB_SLEEP_AFTER_MIN"; fi
}

# Does this agent have open work that should keep it awake? A still-open assigned
# task (todo or in_progress) means keep the session up. Fail-closed: on any db
# error we report "has work" (echo via return 0) so a transient error never
# sleeps an agent mid-flight.
_hb_agent_has_work() {
  local name="$1" n
  n=$(db "SELECT COUNT(*) FROM tasks WHERE assignee=$(sqlq "$name") AND status IN ('todo','in_progress') AND kind='standard';" 2>/dev/null) || return 0
  [[ "$n" =~ ^[0-9]+$ ]] || return 0
  (( n > 0 ))
}

# Registry mutations (run under with_registry_lock, like _hb_mark_run): arm/disarm
# the idle timer and stamp the last sleep for observability.
_hb_autosleep_arm()    { local name="$1" now="$2" reg; reg=$(registry_read); jq --arg n "$name" --argjson t "$now" '.agents[$n].wake.idleSince = $t' <<<"$reg" | registry_write; }
_hb_autosleep_disarm() { local name="$1" reg; reg=$(registry_read); jq --arg n "$name" 'if .agents[$n].wake then .agents[$n].wake |= del(.idleSince) else . end' <<<"$reg" | registry_write; }
_hb_mark_slept()       { local name="$1" now="$2" reg; reg=$(registry_read); jq --arg n "$name" --argjson t "$now" '.agents[$n].wake |= ((. // {}) + {lastSleptAt: $t}) | .agents[$n].wake |= del(.idleSince)' <<<"$reg" | registry_write; }

# The auto-sleep pass. Runs once per tick (isolated by the caller — a failure here
# must NEVER abort the wake loop). Arms an idle timer the first idle+no-work tick,
# then `systemctl stop`s the unit once idle has persisted past the threshold.
# Returns the count via the _HB_SLEPT/_HB_SLEEP_ARMED globals for the tick summary.
_HB_SLEPT=0; _HB_SLEEP_ARMED=0
_hb_autosleep_sweep() {
  local now="$1" reg name mode since after irc
  _HB_SLEPT=0; _HB_SLEEP_ARMED=0
  reg=$(registry_read) || return 0
  for name in $(jq -r '.agents | keys[]' <<<"$reg" 2>/dev/null); do
    mode=$(_hb_wake_mode "$name" "$reg")
    [[ "$mode" == "cold" ]] || continue
    _hb_wake_protected "$name" && continue
    since=$(jq -r --arg n "$name" '.agents[$n].wake.idleSince // 0' <<<"$reg" 2>/dev/null)
    [[ "$since" =~ ^[0-9]+$ ]] || since=0
    # A stopped unit needs no timer — clean up any stale arm and move on.
    if ! systemctl is-active --quiet "5dive-agent@${name}.service" 2>/dev/null; then
      (( since != 0 )) && { with_registry_lock _hb_autosleep_disarm "$name" >/dev/null 2>&1 || true; }
      continue
    fi
    # Open work OR not-confidently-idle => stay awake; disarm the timer.
    if _hb_agent_has_work "$name"; then
      (( since != 0 )) && { with_registry_lock _hb_autosleep_disarm "$name" >/dev/null 2>&1 || true; }
      continue
    fi
    _hb_agent_idle "$name" 0.4; irc=$?
    if (( irc != 0 )); then
      (( since != 0 )) && { with_registry_lock _hb_autosleep_disarm "$name" >/dev/null 2>&1 || true; }
      continue
    fi
    after=$(_hb_sleep_after_min "$name" "$reg")
    if (( since == 0 )); then
      with_registry_lock _hb_autosleep_arm "$name" "$now" >/dev/null 2>&1 || true
      _HB_SLEEP_ARMED=$((_HB_SLEEP_ARMED + 1))
      _hb_log "[$name] cold + idle + no open work — arming auto-sleep (fires after ${after}m idle)"
    elif (( now - since >= after * 60 )); then
      _hb_log "[$name] cold + idle ${after}m+ with no open work — sleeping (systemctl stop)"
      if systemctl stop "5dive-agent@${name}.service" 2>/dev/null; then
        with_registry_lock _hb_mark_slept "$name" "$now" >/dev/null 2>&1 || true
        _HB_SLEPT=$((_HB_SLEPT + 1))
      else
        _hb_log "[$name] systemctl stop failed — will retry next tick"
      fi
    fi
  done
  _hb_log "[autosleep] pass done — ${_HB_SLEPT} slept, ${_HB_SLEEP_ARMED} armed"
  return 0
}

_hb_log() { printf '%s [heartbeat] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

_hb_usage() {
  cat <<USAGE
5dive heartbeat — wake agents only when they have queued tasks

  5dive heartbeat on  <name> [--every=<dur>] [--fresh]
                                          # enrol agent; default every=${_HB_DEFAULT_EVERY}m, fresh off
  5dive heartbeat off <name>              # stop waking the agent (keeps its settings)
  5dive heartbeat ls                      # show enrolled agents + next-wake + queued count
  5dive heartbeat tick                    # cron driver: wake every due agent that has work
  5dive heartbeat wake-mode <name> [always_on|cold] [--cap=<n>] [--sleep-after=<min>]
                                          # opt-in reactive wake mode + wake-budget + auto-sleep.
                                          # no args after <name> => show current mode/budget/sleep/cost.

  <dur>: minutes (e.g. 30), or 45m / 2h / 1h30m.
  wake-mode ( Phase 1): 'cold' opts an agent into reactive
        wake-on-alert with a wakes/day budget cap (default ${_HB_WAKE_DEFAULT_CAP}) so a chatty
        trigger can't thrash it; cost-per-wake is surfaced (display only, zero
        billing). A cold agent that goes idle with no open work is auto-slept
        (systemctl stop) after --sleep-after minutes (default ${_HB_SLEEP_AFTER_MIN}m) and is
        woken again by the next trigger. 'always_on' (default) is unchanged;
        main + marketing are pinned always-on and refuse 'cold'.
  fresh (default off,): --fresh sends /clear before each task so
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
  [[ $# -gt 0 ]] || { _hb_usage; mark_reported; exit "$E_USAGE"; }
  local sub="$1"; shift
  case "$sub" in
    on|enable)       with_registry_lock cmd_heartbeat_on "$@" ;;
    off|disable)     with_registry_lock cmd_heartbeat_off "$@" ;;
    ls|list|status)  cmd_heartbeat_ls "$@" ;;
    tick)            cmd_heartbeat_tick "$@" ;;
    wake-task)       cmd_heartbeat_wake_task "$@" ;;
    wake-mode)       cmd_heartbeat_wake_mode "$@" ;;
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

# DIVE-1858 Stage 1: get/set an agent's wake mode + wake-budget cap. A read (no
# mode + no --cap) is lock-free like `ls` (any group-claude agent can inspect its
# own). A write takes root + the registry lock and refuses 'cold' on a protected
# always-on agent (main/marketing — olivia condition 3). NO live sleep is wired
# here; Stage 2 (auto-sleep smoke) is held for main's pre-run lead review.
cmd_heartbeat_wake_mode() {
  local name="" mode="" cap="" sleep_after=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cap=*)         cap="${1#*=}" ;;
      --sleep-after=*) sleep_after="${1#*=}" ;;
      -*)      fail "$E_USAGE" "unknown flag: $1" ;;
      *)       if [[ -z "$name" ]]; then name="$1"
               elif [[ -z "$mode" ]]; then mode="$1"
               else fail "$E_USAGE" "unexpected arg: $1"; fi ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive heartbeat wake-mode <name> [always_on|cold] [--cap=<n>] [--sleep-after=<min>]"
  require_agent "$name"

  # Read-only path: no mode + no cap + no sleep-after => print current state, no root needed.
  if [[ -z "$mode" && -z "$cap" && -z "$sleep_after" ]]; then
    local reg cur jcap jused jday jslp
    reg=$(registry_read)
    cur=$(_hb_wake_mode "$name" "$reg")
    jcap=$(jq -r --arg n "$name" '.agents[$n].wake.budget.capPerDay // "-"' <<<"$reg")
    jused=$(jq -r --arg n "$name" '.agents[$n].wake.budget.wakesToday // 0' <<<"$reg")
    jday=$(jq -r --arg n "$name" '.agents[$n].wake.budget.day // "-"' <<<"$reg")
    jslp=$(_hb_sleep_after_min "$name" "$reg")
    ok "wake mode for '$name': ${cur} (cap ${jcap}/day, used ${jused} on ${jday}; sleeps after ${jslp}m idle; cost/wake ${_HB_WAKE_COST_EST})" \
       '{name:$n, mode:$m, capPerDay:$c, wakesToday:($u|tonumber), day:$d, sleepAfterMin:($s|tonumber), costPerWake:$cost}' \
       --arg n "$name" --arg m "$cur" --arg c "$jcap" --arg u "$jused" --arg d "$jday" --arg s "$jslp" --arg cost "$_HB_WAKE_COST_EST"
    return 0
  fi

  require_root "heartbeat wake-mode"
  [[ -z "$mode" ]] && mode="cold"   # `--cap`/`--sleep-after` alone implies opting into cold
  case "$mode" in
    always_on|cold) ;;
    *) fail "$E_VALIDATION" "bad mode '$mode' (use: always_on | cold)" ;;
  esac
  if [[ "$mode" == "cold" ]] && _hb_wake_protected "$name"; then
    fail "$E_VALIDATION" "'$name' is a protected always-on agent — refusing wake_mode=cold"
  fi
  [[ -z "$cap" || "$cap" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "bad --cap '$cap' (whole number of wakes/day)"
  [[ -z "$sleep_after" || ( "$sleep_after" =~ ^[0-9]+$ && "$sleep_after" -gt 0 ) ]] || fail "$E_VALIDATION" "bad --sleep-after '$sleep_after' (whole number of idle minutes > 0)"

  with_registry_lock _hb_wake_mode_write "$name" "$mode" "$cap" "$sleep_after"
}

# Registry mutation for cmd_heartbeat_wake_mode (runs under the lock). Preserves
# any existing wakesToday/day counter so flipping mode or re-capping mid-day
# doesn't reset the budget.
_hb_wake_mode_write() {
  local name="$1" mode="$2" cap="$3" sleep_after="${4:-}"
  local reg; reg=$(registry_read)
  # Preserve an existing sleepAfterMin unless the caller passed a new one; drop it
  # (fall back to the global default) when flipping back to always_on.
  reg=$(jq --arg n "$name" --arg m "$mode" --arg cost "$_HB_WAKE_COST_EST" \
           --argjson cap "${cap:-null}" --argjson defcap "$_HB_WAKE_DEFAULT_CAP" \
           --argjson slp "${sleep_after:-null}" '
      ( .agents[$n].wake // {} ) as $w
      | ( $w.budget // {} ) as $b
      | ( if $slp != null then $slp elif $m == "cold" then $w.sleepAfterMin else null end ) as $eff_slp
      | .agents[$n].wake = ({
          mode: $m,
          costPerWake: $cost,
          budget: {
            capPerDay: (if $cap != null then $cap
                        elif $m == "cold" then ($b.capPerDay // $defcap)
                        else $b.capPerDay end),
            wakesToday: ($b.wakesToday // 0),
            day: ($b.day // "")
          }
        } + (if $eff_slp != null then {sleepAfterMin: $eff_slp} else {} end)
          + (if $w.lastSleptAt != null then {lastSleptAt: $w.lastSleptAt} else {} end))' <<<"$reg")
  echo "$reg" | registry_write
  local shown_cap shown_slp
  shown_cap=$(jq -r --arg n "$name" '.agents[$n].wake.budget.capPerDay // "-"' <<<"$reg")
  shown_slp=$(_hb_sleep_after_min "$name" "$reg")
  ok "wake mode for '$name' set to '$mode' (cap ${shown_cap}/day; sleeps after ${shown_slp}m idle; cost/wake ${_HB_WAKE_COST_EST})" \
     '{name:$n, mode:$m, capPerDay:$c, sleepAfterMin:($s|tonumber)}' --arg n "$name" --arg m "$mode" --arg c "$shown_cap" --arg s "$shown_slp"
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

# DIVE-3218 — drop ONE task's nudge entry for one agent, under the registry lock.
# _hb_mark_run's own prune already clears an entry once the row leaves 'todo', so
# park and start reset the counter for free. The RE-ASSIGN rung does not: it
# leaves the row in 'todo' under new hands, and without this the previous
# assignee's count stays pegged at 2N forever — a stale number that reads as an
# ongoing starvation nobody is experiencing. Must run under with_registry_lock,
# like _hb_mark_run.
_hb_clear_nudge() {
  local name="$1" task_id="$2" reg
  reg=$(registry_read) || return 1
  echo "$reg" | jq --arg n "$name" --arg tid "$task_id" '
    if (.agents[$n].heartbeat.nudges? // null) != null
    then .agents[$n].heartbeat.nudges |= del(.[$tid])
    else . end' | registry_write
}

# DIVE-3218 — append ONE dated line to a task body.
#
# THIS IS THE LOAD-BEARING HALF OF THE LADDER, not its bookkeeping. A
# fresh-context seat has no memory of its own previous wakes; the row body is the
# only thing it re-reads. An enforcement action that changes state without
# writing WHY into the body therefore just relocates the re-deliberation instead
# of ending it — the next seat wakes, finds a row at a priority it cannot account
# for, and reasons from zero again. With the note, wake N+1 starts from a
# recorded decision.
#
# APPEND, NEVER REWRITE: the body carries the filer's words and every earlier
# note, and the ladder is the last thing that should be trusted to summarise
# them.
_hb_row_note() {
  local id="$1" note="$2"
  db "UPDATE tasks
      SET body = COALESCE(body,'')
                 || CASE WHEN COALESCE(body,'') = '' THEN '' ELSE char(10)||char(10) END
                 || $(sqlq "$note"),
          updated_at=datetime('now')
      WHERE id=${id};" 2>/dev/null || true
}

# DIVE-3218 — consume the nudge count. Called once per delivered nudge, straight
# after _hb_mark_run, with the post-increment count.
#
# TWO RUNGS, deliberately mirroring the DIVE-2853 recurring-stall ladder rather
# than inventing a second shape: surface-then-change-hands, once per row each,
# stamped in the ROW so the throttle survives a registry prune. What differs is
# only what the two ladders can read — 2853 keys on HOURS since materialisation
# for a beat whose later slots are being eaten by skip-if-open; this one keys on
# COUNT of fruitless wakes for any standard row, and the two predicates cannot
# see each other's rows.
#
#   RUNG 1, at N: escalate once (existing `task escalate` semantics — one
#   priority band, capped at urgent, pings the owner) and write a dated line into
#   the body. Escalation alone is a weak lever on a row that is already urgent —
#   that is precisely why the body note is not optional.
#
#   RUNG 2, at 2N: change hands, or park with a wake date. Reassign to a FREE
#   agent (never the current assignee — handing the row back to the party whose
#   not-starting-it IS the fault is the no-op this rung exists to stop — and
#   never the row's own verifier, the DIVE-3097 guard, since that manufactures
#   the assignee==verifier shape by heartbeat). Lane first: a free agent under
#   the same org parent, then any free agent. If nobody is free, PARK with a wake
#   date so the row stops being nudged until then.
#
# NEVER CANCEL, and this is where the ladder parts company with DIVE-2853's
# fallback. That one cancels because an open recurring instance SUPPRESSES every
# later slot of its beat, so leaving it open is an ongoing outage. A standard row
# suppresses nothing; it is merely starved. A starved row is not an unwanted row,
# and auto-cancelling one would destroy work lodar asked for on the evidence that
# nobody got to it.
# DIVE-3218 (main, 2026-08-11) — the SIBLING of the unanswered-gate hold.
#
# `_hb_nudge_enforce` reads the priority band, the row's own stamps and the gate
# hold. It reads NOTHING about the assignee's SEAT — so a seat working a
# deliberate multi-row order accumulates nudges on rows 2..N BY CONSTRUCTION,
# precisely because it is productively working row 1. At the `high` default of 8
# those rows get reassigned out from under a seat doing exactly what it was told.
# Measured, not hypothetical: two such notices fired on quinn's DIVE-3229 and
# DIVE-3238 on the morning of 2026-08-11, both actively planned in an order main
# had given them.
#
#   "A row waiting on an unanswered human gate is not starved — the wait is on a
#    person." Its sibling: a row waiting behind its own assignee's OTHER work is
#   not starved either — the wait is on a QUEUE.
#
# NO NEW SIGNAL. The question is answerable from rows this function already
# reaches: did this seat advance ANYTHING between rung 1 firing and now? Two
# independent readings, OR'd, because each covers the other's blind spot.
#
# THE TRAP THAT MAKES THE NAIVE VERSION USELESS: the engine's own writes are
# attributed to the SEAT, so "any row of this assignee changed" is true even for
# a seat that is completely dead.
#   * rung 1 stamps `updated_at` on THIS row, and on every OTHER row of the same
#     seat it fires on -> exclude $tid, and exclude rows carrying an engine
#     nudge stamp inside the same window.
#   * lifecycle_events rows written when the DISPATCHER claims a row carry
#     `authority='dispatcher'` and the SEAT'S OWN NAME as `actor` (measured:
#     olivia/dev/ops/quinn all appear this way). That is the engine claiming on
#     the seat's behalf, NOT seat work -> excluded, together with 'heartbeat'.
#     Measured on the live board 2026-08-11: zero seat events carry
#     authority='heartbeat', so that exclusion costs nothing real.
#
# FAILS TOWARD HOLD, DELIBERATELY. An unreadable store, a missing column or a
# missing lifecycle_events table yields "" from `db`, which reads as "no evidence
# of advance" -> the ladder still fires. So the TASKS reading is primary (its
# columns are the ones this function already selects) and the ledger reading only
# WIDENS the hold; a store without lifecycle_events degrades to the tasks reading
# rather than to a hold that silently never holds.
_hb_seat_advanced() {
  local name="$1" tid="$2" since="$3" asg="${4:-}"
  [[ -n "$since" ]] || return 1
  [[ "${tid:-}" =~ ^[0-9]+$ ]] || return 1
  local seats hit=""
  seats="$(sqlq "$name")"
  [[ -n "$asg" && "$asg" != "$name" ]] && seats="${seats},$(sqlq "$asg")"

  # (A) TASKS — "closed, delivered, rejected or updated any row in that window".
  # `updated_at` is the broad one and the only one that catches a body note, so it
  # is what we read; the engine-stamp exclusion is what keeps it honest.
  hit=$(db "SELECT 1 FROM tasks
             WHERE assignee IN (${seats})
               AND id <> ${tid}
               AND COALESCE(updated_at,'') > $(sqlq "$since")
               AND NOT (COALESCE(nudge_escalated_at,'') > $(sqlq "$since")
                     OR COALESCE(nudge_parked_at,'')    > $(sqlq "$since"))
             LIMIT 1;" 2>/dev/null || echo "")
  [[ -n "$hit" ]] && return 0

  # (B) LEDGER — catches seat work that leaves no `updated_at` of its own,
  # including work on THIS row. Absent table => "" => contributes nothing.
  hit=$(db "SELECT 1 FROM lifecycle_events
             WHERE actor IN (${seats})
               AND actor <> 'task-engine'
               AND authority NOT IN ('heartbeat','dispatcher')
               AND ts > $(sqlq "$since")
             LIMIT 1;" 2>/dev/null || echo "")
  [[ -n "$hit" ]] && return 0
  return 1
}

_hb_nudge_enforce() {
  local name="$1" tid="$2" tident="$3" nudge_n="$4"
  [[ "${nudge_n:-}" =~ ^[0-9]+$ ]] || return 0
  [[ "${tid:-}" =~ ^[0-9]+$ ]] || return 0

  local band n
  band=$(db "SELECT COALESCE(NULLIF(priority,''),'medium') FROM tasks WHERE id=${tid};" 2>/dev/null || echo "medium")
  [[ -n "$band" ]] || band="medium"
  n=$(_hb_nudge_enforce_after "$band")
  (( nudge_n >= n )) || return 0

  local stamps esc_at="" esc_n="" park_at="" asg="" ver=""
  stamps=$(db "SELECT COALESCE(nudge_escalated_at,'')||x'1f'||COALESCE(nudge_escalated_n,'')||x'1f'||COALESCE(nudge_parked_at,'')||x'1f'||COALESCE(assignee,'')||x'1f'||COALESCE(verifier,'')
               FROM tasks WHERE id=${tid};" 2>/dev/null || echo "")
  [[ -n "$stamps" ]] || return 0
  IFS=$'\x1f' read -r esc_at esc_n park_at asg ver <<<"$stamps"
  [[ "$esc_n" =~ ^[0-9]+$ ]] || esc_n=0

  local today; today=$(date -u +%Y-%m-%d)

  # ---- RUNG 2 --------------------------------------------------------------
  # ALWAYS behind rung 1, and keyed to the count rung 1 fired at rather than to
  # 2*N recomputed now: rung 1 ESCALATES, escalation raises the band, and a higher
  # band has a SMALLER N — so a row escalated at the `high` threshold of 16 is
  # already past an `urgent` 2N of 16 and both rungs would fire on one wake, which
  # is not a ladder. One rung per wake, and rung 2 means "a further N fruitless
  # wakes after we escalated and said so in the body".
  if [[ -n "$esc_at" ]] && (( nudge_n >= esc_n + n )) && [[ -z "$park_at" ]]; then
    # A row waiting on an UNANSWERED HUMAN GATE is not starved — the wait is on a
    # person, and its nudges are the gate's own renag. NEITHER rung-2 lever
    # applies: parking over a gate destroys it (DIVE-1453) and reassigning it
    # only moves a row the new hands cannot act on either. Hold, say nothing, and
    # leave the counter alone — we did not act, so nothing may read as if we had.
    if [[ -n "$(db "SELECT 1 FROM tasks WHERE id=${tid} AND need_type IS NOT NULL AND need_answered_at IS NULL;" 2>/dev/null || echo "")" ]]; then
      _hb_log "[nudge-enforce] ${tident} rung 2 HELD: unanswered human gate — not starvation; nothing written, nothing sent, counter left intact"
      return 0
    fi

    # SIBLING HOLD (DIVE-3218, main 2026-08-11). A row waiting behind its own
    # assignee's OTHER work is queued, not starved — the wait is on a queue, and
    # neither rung-2 lever addresses a queue. Reassigning it takes a row off a
    # seat that is demonstrably working and hands it to one that is merely idle.
    # Same discipline as the gate hold above: hold, log, write nothing, send
    # nothing, and leave the counter alone — we did not act, so nothing may read
    # as if we had. Logged rather than silent because a silent hold is
    # indistinguishable from a ladder that never armed.
    if _hb_seat_advanced "$name" "$tid" "$esc_at" "$asg"; then
      _hb_log "[nudge-enforce] ${tident} rung 2 HELD: assignee '${asg:-$name}' advanced other rows since rung 1 (${esc_at}) — queued behind its own work, not starved; nothing written, nothing sent, counter left intact"
      return 0
    fi

    local free="" target="" cand lane cand_lane applied=0
    lane=$(db "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$name");" 2>/dev/null || echo "")
    if free=$(_hb_free_agents 2>/dev/null); then
      while IFS= read -r cand; do
        [[ -n "$cand" ]] || continue
        [[ "$cand" == "$name" ]] && continue
        [[ -n "$asg" && "$cand" == "$asg" ]] && continue
        [[ -n "$ver" && "$cand" == "$ver" ]] && continue
        if [[ -n "$lane" ]]; then
          cand_lane=$(db "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$cand");" 2>/dev/null || echo "")
          if [[ "$cand_lane" == "$lane" ]]; then target="$cand"; break; fi
        fi
        [[ -z "$target" ]] && target="$cand"
      done <<<"$free"
    else
      # An unreadable registry is not evidence that nobody is free. Fall through
      # to the park rung rather than reassigning on an unread fleet — the park is
      # reversible and dated, a wrong reassignment is neither.
      _hb_log "[nudge-enforce] ${tident} registry unreadable — no reassignment attempted; parking instead"
    fi

    if [[ -n "$target" ]]; then
      # ACT FIRST, NARRATE ONLY WHAT LANDED. This UPDATE is GUARDED; when the
      # guard matches zero rows the row is unchanged, and a body note, a ping and
      # a ledger event emitted ahead of it are a lie told to the one reader with
      # no other memory. On a design whose load-bearing half IS the body
      # write-back, a false note is worse than no note. changes() is read in the
      # SAME sqlite3 connection as the UPDATE — a second `db` invocation would
      # report on its own statement, not this one.
      # `nudge_parked_at IS NULL` is the ONCE-PER-ROW clause, and it belongs here
      # rather than in the `[[ -z "$park_at" ]]` pre-read above. The pre-read is
      # an optimisation: it is taken from a stamps SELECT that a concurrent tick
      # can have run before either caller wrote, so both see empty and both
      # proceed. A status-only guard cannot refuse the second one — reassign does
      # not change status, so changes() is 1 for both and the row changes hands
      # twice with two identical notes on the artifact this design calls
      # load-bearing. With the latch column in the WHERE, changes()==0 IS the
      # second caller's refusal and the branch below already does the right thing.
      applied=$(db "UPDATE tasks SET assignee=$(sqlq "$target"), nudge_parked_at=datetime('now'), updated_at=datetime('now')
          WHERE id=${tid} AND status IN ('todo','in_progress')
            AND nudge_parked_at IS NULL;
          SELECT changes();" 2>/dev/null || echo 0)
      [[ "$applied" =~ ^[0-9]+$ ]] || applied=0
      if (( applied == 0 )); then
        _hb_log "[nudge-enforce] ${tident} rung 2 reassign REFUSED by its own guard (row not todo/in_progress, or nudge_parked_at already set by a concurrent tick) — this caller wrote nothing and sent nothing"
        return 0
      fi
      _hb_row_note "$tid" "[${today}] nudge-enforcement (DIVE-3218): REASSIGNED ${asg:-unassigned} -> ${target} after ${nudge_n} heartbeat nudges (>= 2x the ${band} threshold of ${n}) produced no state change. Each of those nudges was a full fresh-context session that read this row and did not start it, so this is a hand-off, not a reprimand: whatever stopped ${asg:-the previous assignee} is not something another nudge to them can clear. ${target}: if you also decide NOT to start this, write WHY into this body before you exit — that sentence is the only memory the next seat has."
      with_registry_lock _hb_clear_nudge "$name" "$tid" >/dev/null 2>&1 || true
      ( cmd_send "$target" --from="task-engine" \
          --message="🔁 ${tident} has been REASSIGNED to you by nudge enforcement: it was nudged ${nudge_n}x at '${asg:-unassigned}' with no state change (DIVE-3218). The reason is written into the row body — read it, then \`5dive task start ${tident}\`. If you decide not to start it, write why into the body rather than leaving it to be re-derived." ) >/dev/null 2>&1 || true
      [[ -n "$asg" ]] && ( cmd_send "$asg" --from="task-engine" \
          --message="🔁 ${tident} has been moved OFF you to '${target}' — ${nudge_n} nudges, no state change (DIVE-3218). Nothing for you to do; if you were mid-thought on it, say so to ${target} rather than both starting it." ) >/dev/null 2>&1 || true
      ledger_emit "task.nudge_enforced" ident="$tident" task_id="$tid" \
        actor="task-engine" authority="heartbeat" \
        detail="rung2 reassign ${asg:-unassigned}->${target} after ${nudge_n} nudges (band ${band}, N=${n})" || true
      _hb_log "[nudge-enforce] ${tident} nudged ${nudge_n}x (band ${band}, N=${n}) -> REASSIGNED ${asg:-unassigned} -> ${target}, reason written to body"
    else
      local wake_days=1
      # Same discipline as the reassign branch above: the park UPDATE carries the
      # DIVE-1453 gate guard AND a status guard, either of which can match zero
      # rows. Run it, confirm it moved a row, and only then write the body note,
      # ping the assignee and emit the ledger event. The gate clause is redundant
      # with the hold at the top of rung 2 and stays anyway — it is the guard that
      # protects a live human gate, and it should not depend on a caller's
      # pre-check to be correct.
      applied=$(db "UPDATE tasks SET status='blocked', parked_at=datetime('now'),
                           park_reason=$(sqlq "parked by nudge enforcement (DIVE-3218): ${nudge_n} nudges at '${asg:-unassigned}' with no state change and no free agent to reassign to; auto-unparks on wake_at"),
                           wake_at=datetime('now','+${wake_days} day'),
                           nudge_parked_at=datetime('now'), updated_at=datetime('now')
          WHERE id=${tid} AND status IN ('todo','in_progress')
            AND NOT (need_type IS NOT NULL AND need_answered_at IS NULL)
            AND nudge_parked_at IS NULL;
          SELECT changes();" 2>/dev/null || echo 0)
      [[ "$applied" =~ ^[0-9]+$ ]] || applied=0
      if (( applied == 0 )); then
        _hb_log "[nudge-enforce] ${tident} rung 2 park REFUSED by its own guard (live human gate, row not todo/in_progress, or nudge_parked_at already set by a concurrent tick) — this caller wrote nothing and sent nothing"
        return 0
      fi
      _hb_row_note "$tid" "[${today}] nudge-enforcement (DIVE-3218): PARKED for ${wake_days}d after ${nudge_n} heartbeat nudges (>= 2x the ${band} threshold of ${n}) produced no state change, and no free agent was available to hand it to. NOT cancelled and NOT unwanted — parking only stops the wakes, which were costing a full fresh-context session each and buying nothing. It auto-unparks to todo on its wake date. Whoever picks it up next: if you decide not to start it, write WHY into this body before you exit."
      with_registry_lock _hb_clear_nudge "$name" "$tid" >/dev/null 2>&1 || true
      [[ -n "$asg" ]] && ( cmd_send "$asg" --from="task-engine" \
          --message="⏸ ${tident} has been PARKED for ${wake_days}d by nudge enforcement — ${nudge_n} nudges, no state change, no free agent to hand it to (DIVE-3218). It is not cancelled; it auto-unparks to todo on its wake date. The reason is in the row body. If it should come back sooner, \`5dive task start ${tident}\` unparks it." ) >/dev/null 2>&1 || true
      ledger_emit "task.nudge_enforced" ident="$tident" task_id="$tid" \
        actor="task-engine" authority="heartbeat" \
        detail="rung2 park +${wake_days}d after ${nudge_n} nudges, no free agent (band ${band}, N=${n})" || true
      _hb_log "[nudge-enforce] ${tident} nudged ${nudge_n}x (band ${band}, N=${n}), no free agent -> PARKED +${wake_days}d, reason written to body"
    fi
    return 0
  fi

  # ---- RUNG 1 --------------------------------------------------------------
  if [[ -z "$esc_at" ]]; then
    # Same act-then-narrate order as rung 2, for the same reason. The latch is
    # stamped FIRST, under the one guard that can refuse it, so a closed row
    # (nothing left to escalate) is never told in its own body that it was.
    # `nudge_escalated_at IS NULL` is what makes "once per row" a FACT rather than
    # a hope. The `[[ -z "$esc_at" ]]` above is a stale pre-read: cron starts tick
    # N+1 while N is still running (src/cmd_heartbeat.sh:4 — one host cron, no
    # flock, and a tick runs long whenever a relay seat never shows a prompt), so
    # two callers read the same empty stamp and a status-only guard says 1 to
    # both. Measured on a fixture, 5 runs of 5: a `low` row went low -> HIGH (two
    # escalations, medium skipped), TWO identical dated notes in the body, two
    # ledger events, and nudge_escalated_n — the number rung 2's threshold is
    # keyed to — set by whichever write won. Put the latch column in the WHERE
    # clause that sets it and changes()==0 becomes the second caller's refusal.
    local applied1
    applied1=$(db "UPDATE tasks SET nudge_escalated_at=datetime('now'), nudge_escalated_n=${nudge_n}, updated_at=datetime('now')
                   WHERE id=${tid} AND status IN ('todo','in_progress')
                     AND nudge_escalated_at IS NULL;
                   SELECT changes();" 2>/dev/null || echo 0)
    [[ "$applied1" =~ ^[0-9]+$ ]] || applied1=0
    if (( applied1 == 0 )); then
      _hb_log "[nudge-enforce] ${tident} rung 1 REFUSED by its own guard (row not todo/in_progress, or nudge_escalated_at already set by a concurrent tick) — this caller wrote nothing; the latch is whatever the winning caller left"
      return 0
    fi
    ( cmd_task_escalate "$tid" --from=heartbeat ) >/dev/null 2>&1 || true
    # Re-read the band AFTER escalating, for two reasons. (a) The note must state
    # what actually happened: `task escalate` is capped at urgent, so on an
    # already-urgent row it is a no-op and this note is the whole lever — say so
    # rather than claiming a bump that did not occur. (b) The wake number the note
    # promises must be the one rung 2 fires on: rung 2 recomputes N from the
    # RAISED band, and a higher band carries a SMALLER N, so the pre-escalation N
    # promised 32 where the code fires at 24.
    local band2 n2 rung1_did
    band2=$(db "SELECT COALESCE(NULLIF(priority,''),'medium') FROM tasks WHERE id=${tid};" 2>/dev/null || echo "$band")
    [[ -n "$band2" ]] || band2="$band"
    n2=$(_hb_nudge_enforce_after "$band2")
    if [[ "$band2" == "$band" ]]; then
      rung1_did="the row was ALREADY ${band} and escalation is capped there, so this written note is the only lever this rung has"
    else
      rung1_did="ESCALATED ${band} -> ${band2}"
    fi
    _hb_row_note "$tid" "[${today}] nudge-enforcement (DIVE-3218): ${rung1_did} — after ${nudge_n} heartbeat nudges (>= the ${band} threshold of ${n}) with no state change. Every one of those was a full fresh-context session that woke on this row, decided not to start it, and left no record of deciding — so the same conclusion was re-derived from zero each time. IF YOU WAKE ON THIS ROW AND DECIDE NOT TO START IT, WRITE WHY HERE before you exit; an unwritten decision is re-paid in full at the next wake. At $(( nudge_n + n2 )) nudges this row is reassigned or parked automatically."
    ledger_emit "task.nudge_enforced" ident="$tident" task_id="$tid" \
      actor="task-engine" authority="heartbeat" \
      detail="rung1 escalate ${band}->${band2} after ${nudge_n} nudges (band ${band}, N=${n}); rung 2 at $(( nudge_n + n2 ))" || true
    _hb_log "[nudge-enforce] ${tident} nudged ${nudge_n}x (band ${band}, N=${n}) -> rung 1 (${band}->${band2}), reason written to body; rung 2 at $(( nudge_n + n2 ))"
  fi
  return 0
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
  reg=$(echo "$reg" | jq --arg n "$name" 'if .agents[$n].heartbeat then del(.agents[$n].heartbeat.activeDefer, .agents[$n].heartbeat.usageHeal, .agents[$n].heartbeat.usagePress) else . end')
  echo "$reg" | registry_write
}

# DIVE-1666 — pure matcher (unit-testable, no tmux) for the Claude Code
# USAGE/SPEND-LIMIT dialog. Requires TWO independent signature lines so ordinary
# output that merely mentions "limit" can't false-match: a HEADER line (hit your
# monthly-spend / usage / 5-hour limit, or "usage limit reached") AND an ACTION
# line ("Upgrade your plan", or "wait for … limit to reset" / "resets at|in").
# Case-insensitive and tolerant of CC copy drift across the monthly-spend and
# 5-hour variants. Callers reach this ONLY on a confirmed rc==3 "blocked" pane,
# so the pane really is parked on a dialog, not mid-turn text.
_hb_pane_is_usage_limit() {
  local pane="$1"
  grep -qiE 'hit your (monthly[ -]?spend|usage|5[ -]?hour) limit|usage limit reached|reached your .* limit|limit reached' <<<"$pane" || return 1
  grep -qiE 'upgrade your plan|wait for .*limit to reset|limit will reset|resets? (at|in) ' <<<"$pane" || return 1
  return 0
}

# DIVE-1666 — is THIS agent's session frozen on the usage-limit dialog right now?
# Scrapes the pane and applies the pure matcher above. Returns 0 (frozen on the
# usage dialog) / 1 (any other dialog, or pane uncapturable → fail-safe: treat as
# a real prompt and keep deferring, never restart on a missing signal).
_hb_usage_limit_frozen() {
  local name="$1" pane
  pane=$(sudo -u "agent-${name}" tmux capture-pane -p -t "agent-${name}" 2>/dev/null) || return 1
  [[ -n "$pane" ]] || return 1
  _hb_pane_is_usage_limit "$pane"
}

# DIVE-1666 — does this agent's auth account have PROVEN headroom right now? The
# account is pooled, so a sibling agent sharing the same authProfile that is
# currently healthy (native state idle or busy — i.e. NOT blocked/frozen) is
# ground-truth proof the pool is under its limit. Returns 0 (headroom proven) /
# 1 (no proof: solo on the account, or every peer is itself blocked/frozen). The
# per-agent 5h% in `usage --json` is only a heuristic; a live healthy peer is the
# real signal (a healthy peer on the same account is exactly how the 2026-07-21
# stall was diagnosed as headroom, not a genuine limit).
_hb_account_has_headroom() {
  local name="$1" acct="$2" reg="$3" peer
  while IFS= read -r peer; do
    [[ -n "$peer" && "$peer" != "$name" ]] || continue
    case "$(_hb_agent_native_state "$peer" 2>/dev/null)" in
      idle|busy) return 0 ;;
    esac
  done < <(jq -r --arg a "$acct" '
      .agents | to_entries
      | map(select((.value.authProfile // ("@self:" + .key)) == $a))
      | .[].key' <<<"$reg" 2>/dev/null)
  return 1
}

# DIVE-1666 — record a self-heal restart of a frozen agent and return the running
# heal count. Stored under .agents[<name>].heartbeat.usageHeal = {at,n} (parallel
# to .activeDefer); `at` gates the restart throttle, `n` is for the log/surface
# copy. Cleared by _hb_clear_active_defer once the agent escapes the dialog (any
# wake / genuine-idle recovery), so a recovered agent's throttle resets. Must run
# under with_registry_lock, like _hb_mark_run / _hb_mark_active_defer.
_hb_mark_usage_heal() {
  local name="$1" now="$2"
  local reg; reg=$(registry_read)
  local n; n=$(jq -r --arg n "$name" '.agents[$n].heartbeat.usageHeal.n // 0' <<<"$reg")
  [[ "$n" =~ ^[0-9]+$ ]] || n=0; n=$(( n + 1 ))
  reg=$(echo "$reg" | jq --arg n "$name" --argjson at "$now" --argjson c "$n" \
    '.agents[$n].heartbeat.usageHeal = {at:$at, n:$c}')
  echo "$reg" | registry_write
  printf '%s' "$n"
}

# DIVE-1666 — epoch of this agent's last self-heal restart (0 if none). Used to
# throttle restarts against a genuinely still-limited account.
_hb_usage_heal_last() {
  local name="$1" reg; reg=$(registry_read)
  jq -r --arg n "$name" '.agents[$n].heartbeat.usageHeal.at // 0' <<<"$reg" 2>/dev/null || echo 0
}

# DIVE-1677 — record a press-continue-in-place attempt and return the running
# count. Stored under .agents[<name>].heartbeat.usagePress = {at,n} (parallel to
# usageHeal). `n` gates how many in-place resumes we try before falling back to a
# hard restart; cleared by _hb_clear_active_defer once the agent escapes the
# dialog (a resumed session is no longer rc-3 frozen), so a later freeze starts
# fresh. Must run under with_registry_lock, like _hb_mark_usage_heal.
_hb_mark_usage_press() {
  local name="$1" now="$2"
  local reg; reg=$(registry_read)
  local n; n=$(jq -r --arg n "$name" '.agents[$n].heartbeat.usagePress.n // 0' <<<"$reg")
  [[ "$n" =~ ^[0-9]+$ ]] || n=0; n=$(( n + 1 ))
  reg=$(echo "$reg" | jq --arg n "$name" --argjson at "$now" --argjson c "$n" \
    '.agents[$n].heartbeat.usagePress = {at:$at, n:$c}')
  echo "$reg" | registry_write
  printf '%s' "$n"
}

# DIVE-1677 — how many consecutive press-continue attempts this agent has made on
# the current freeze (0 if none). Read before the next attempt to decide press vs
# restart-fallback.
_hb_usage_press_count() {
  local name="$1" reg; reg=$(registry_read)
  jq -r --arg n "$name" '.agents[$n].heartbeat.usagePress.n // 0' <<<"$reg" 2>/dev/null || echo 0
}

# DIVE-1677 — press CONTINUE on a stale usage-limit dialog and resume the session
# IN PLACE (no restart, no /clear → conversation + context preserved), mirroring
# the telegram resume-after-reset keystrokes: dismiss the "Stop and wait" menu
# with '1'+Enter (the option that returns to the prompt without upgrading), then
# type a bare "continue" so claude picks its interrupted work back up. Reached
# ONLY when a healthy peer proves the pooled account has headroom — there's no
# real limit to reset, so waking claude won't just re-hit it. Returns 0 if the
# keystrokes were delivered, 1 if the pane was uncapturable / send failed (the
# caller escalates to a hard restart after a couple failed ticks). Whether it
# ACTUALLY unstuck is confirmed on the NEXT tick by re-testing _hb_usage_limit_frozen.
_hb_press_continue() {
  local name="$1"
  sudo -u "agent-${name}" tmux has-session -t "agent-${name}" 2>/dev/null || return 1
  # Dismiss the "1. Stop and wait for limit to reset" menu, same as resume-after-
  # reset phase 1. '1' returns to the prompt without hitting "Upgrade your plan".
  sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" -l -- "1" 2>/dev/null || return 1
  sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" Enter 2>/dev/null || return 1
  sleep 2
  # Resume the in-place conversation with the same bare wake word resume-after-
  # reset types; the agent's existing /goal loop picks back up (no re-nudge).
  _hb_send_line "$name" "continue" || return 1
  return 0
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
#
# DIVE-2716 — this is now the LIST form. It used to be `_hb_pick_task`, hard
# LIMIT 1, and that single row was the agent's entire chance to be woken this
# tick: when the tier guard below held it, the tick gave up on the AGENT, and
# because selection is deterministic the same row was re-picked and re-held every
# five minutes forever. Five held rows head-of-line blocked 122 runnable ones.
# Handing the caller an ORDERED list is what lets a held head be stepped over
# without weakening the guard — the order is unchanged, so the first runnable
# candidate is exactly the row the old picker would have returned once the held
# ones ahead of it are gone. `_hb_pick_task` is kept as the LIMIT-1 wrapper.
_hb_pick_tasks() {
  local name="$1" lim="${2:-1}"
  # A non-numeric/zero limit must not become an unbounded scan.
  [[ "$lim" =~ ^[1-9][0-9]*$ ]] || lim=1
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
        LIMIT ${lim};" 2>/dev/null || echo ""
}

# The historical single-row picker: same rows, same order, first one only. Kept
# because the direct-claim path and tests/heartbeat_pick_unit.sh want exactly
# one id, and because it keeps DIVE-979's ordering rules stated in ONE query.
_hb_pick_task() { _hb_pick_tasks "$1" 1; }

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
  # DIVE-2137: the heartbeat is the FOURTH typed-send site (send / ask / _deliver
  # are the three in cmd_agent_runtime.sh) and had the same blind spot — it types
  # a nudge into whatever the pane happens to be showing. An agent that booted
  # unauthenticated is parked on its login menu, so an autonomous wake/nudge
  # would write "continue" (or a whole task line) into the API-key field and
  # submit it. Worse than the reported path, because no human is watching a tick.
  # Same fail-closed predicate, one shared definition (cmd_agent_runtime.sh).
  # DIVE-2159: name the REAL cause. The guard now also refuses when it could not
  # read the pane at all, and logging that as "pane is a credential/login prompt"
  # would assert a state nobody measured — the same could-not-measure-reads-as-
  # measured shape the guard exists to stop. A tick is the one place with no human
  # watching, so the log line is the whole record.
  _agent_pane_safe_to_type "$name" || {
    if [[ "${_AGENT_PANE_REFUSAL_REASON:-}" == "unreadable" ]]; then
      _hb_log "skip send to ${name}: could not read the pane (tmux capture-pane failed after retries) — fail-closed, nothing typed (DIVE-2159)" 2>/dev/null || true
    else
      _hb_log "skip send to ${name}: pane is a credential/login prompt, not a chat input (DIVE-2137)" 2>/dev/null || true
    fi
    return 1
  }
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
    # devin renders ❭ for BOTH the composer AND menu selections (the
    # workspace-trust dialog is '❭ 1 Yes, trust …'), and ❭ U+276D sits two
    # codepoints from claude's ❯ U+276F. Key off the composer placeholder
    # instead: unambiguous, and it cannot match a menu row.
    devin)        printf 'Ask Devin' ;;
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

# DIVE-2244 — THE DISPATCHER CLAIMS. Stamp status='in_progress' + started_at at
# the moment the heartbeat nudges an agent against a specific task.
#
# WHY THIS EXISTS. The whole stuck-work recovery layer keys on this one field:
# the deterministic hard cap, the runaway reaper, orphan reclaim, unwedge, and
# the busy-guard in the tick all read status='in_progress' / started_at. The
# only writer was an INSTRUCTION — the /goal nudge text says "claim it with
# 5dive task start DIVE-N" — and an instruction an agent must remember at the
# moment of action is not a control (DIVE-2146). The dispatcher is the
# mechanism; the instruction is a hope.
#
# WHAT THE BOARD ACTUALLY SHOWS, re-measured at implementation time rather than
# inherited from the ticket. Compliance is PARTIAL and erratic, not zero:
# of tasks closed per day, the share that ever had started_at set ran 23% (14 of
# 61, 2026-07-28), 51% (35 of 68, 07-27), 60% (50 of 83, 07-26). The filing
# ticket reported 0 of 24 and "0 tasks with started_at in 48h"; its six NAMED
# tasks are genuinely NULL, but the aggregate does not hold — 48 rows were
# claimed in that same window. So `in_progress == 0` is a TRANSIENT, not the
# permanent condition the ticket diagnosed.
#
# That correction moves which half of this fix does which job, so state it
# plainly rather than let the ticket's ordering stand:
#   * the false-positive ALARM is only partly a claim problem. in_progress was
#     genuinely 0 at 08:15Z on 2026-07-28 — a real quiet moment, not a dead
#     field. Claiming raises the floor (an agent under nudge now holds a row)
#     but does not by itself make the predicate sound; the probe-conclusiveness
#     half of DIVE-2244, in _hb_stall_sweep, is what addresses the reported
#     firing.
#   * the SILENT half is the one this function fixes outright, and it is the
#     costly one. At 23-60% coverage, most in-flight work was invisible to
#     every recovery rule above: a genuinely runaway or orphaned task in that
#     majority had no recovery path at all and would present as a
#     permanently-todo row nobody notices. Claiming at the nudge takes coverage
#     of dispatcher-driven work to 100% by construction.
#
# The heartbeat already knows the exact task it woke the agent for, so the claim
# belongs here.
#
# KNOWN PROPERTY, not an accident of where the UPDATE landed: THIS CLAIMS ON
# DELIVERY, NOT ON ACCEPTANCE. _hb_wake succeeding means the nudge was SENT into
# the pane. It does not mean the agent read it, understood it, or began. So a
# nudge that lands in a wedged pane produces a row that reads "someone is on
# this" while nobody is — the board asserts work-in-progress from a send. There
# is no acceptance signal available at this layer to claim on instead (the agent
# reading its own nudge is unobservable from here), so delivery is the honest
# ceiling of what the dispatcher can know, and it is stated rather than implied.
#
# What keeps that from becoming a silent permanent stall is that the recovery
# net behind it does NOT depend on the same unreliable liveness read. Of the
# three reclaim rules in _hb_reclaim, rule (c) — the hard cap at
# everyMin*_HB_STALE_MULT — is UNCONDITIONAL: pure arithmetic on age_min, no
# _hb_agent_idle call, and its `/goal clear` is best-effort (`|| true`) so a dead
# pane cannot gate the requeue. Only rule (b) consults the idle probe. So if the
# probe is wrong in the busy direction (a hung process that still reads alive),
# rule (b) misses and the worst case is a BOUNDED stall to the budget, then a
# requeue; a second overrun blocks + escalates to a human rather than churning.
# A wrong probe cannot produce a task that is neither re-nudged nor reclaimed.
# tests/heartbeat_dispatcher_claim_unit.sh fences this directly rather than
# leaving it to a reading of the code.
#
# NARROW BY CONSTRUCTION — this must not become a way for a tick to rewrite rows:
#   * called ONLY inside the _hb_wake success branch, so a tick that wakes nobody
#     (not due / busy / no work / spread-deferred / wake failed) mutates nothing;
#   * WHERE status='todo' AND kind='standard' — never stomps a row something else
#     already moved between the wake and this stamp, and never touches a
#     recurring TEMPLATE (starting one silently retires it, DIVE-2055/2059);
#   * started_at=COALESCE(started_at, ...) — same idempotence as `task start`, so
#     an agent that DOES run `task start` afterwards is a no-op, not a re-clock.
#
# Returns nonzero when the claim did not land, so the caller can say so out loud
# rather than logging a claim it never made. Never exits: the agent is already
# awake by this point, and a db hiccup must not abort the tick.
_hb_claim_task() {
  local name="$1" id="$2" n=""
  # DIVE-3251: first_started_at is stamped by the SAME COALESCE, because DIVE-2244
  # moved the authoritative start to this function — a first-start record written
  # only by `task start` would be NULL for the majority of rows, which is the
  # blindness this column exists to remove. Seeded from started_at too, so a row
  # already claimed when this ships keeps its real start.
  db "UPDATE tasks SET status='in_progress',
        started_at=COALESCE(started_at, datetime('now')),
        first_started_at=COALESCE(first_started_at, started_at, datetime('now')),
        updated_at=datetime('now')
      WHERE id=${id} AND status='todo' AND kind='standard';" 2>/dev/null || return 1
  # Confirm from the ROW, not from the UPDATE's exit code — sqlite exits 0 on an
  # UPDATE that matched nothing, which is precisely the case we must not report
  # as a claim.
  n=$(db "SELECT COUNT(*) FROM tasks WHERE id=${id} AND status='in_progress' AND started_at IS NOT NULL;" 2>/dev/null) || return 1
  [[ "$n" == "1" ]] || return 1
  # DIVE-2541: THE CLAIM IS A START, SO IT GOES ON THE LEDGER.
  #
  # DIVE-2244 moved the authoritative start from `task start` to this function, and
  # the ledger emit stayed behind on the verb. Measured 2026-08-02 over the ledger's
  # whole life: the dispatcher claimed 94 distinct tasks and 85 of them carry NO
  # task.started event, while the verb fired 13 times. The instrumentation was still
  # attached to the path that had stopped being the main one, and it fired often
  # enough to look alive — which is why nobody caught it for four days.
  #
  # authority=dispatcher, NOT self. The agent has not acted at this point; the
  # dispatcher moved the row on its behalf. Writing `self` here would be a false
  # claim of exactly the kind v0.18 exists to delete — actor keeps its meaning
  # (whose queue this is) and authority says who actually moved it, so a reader can
  # tell a dispatcher claim from an agent that ran the verb.
  #
  # The DEFAULT idem_key (kind|ident|task_id|hash(detail)) is deliberate: it is
  # constant per task, so a task reclaimed to todo and re-claimed records its FIRST
  # claim only. The chain reader asks "was this started, and under whose authority",
  # not "how many times" — and a UNIQUE collision is a silent no-op, so this can
  # never inflate the ledger. Losing re-claim COUNT is the safe direction; a
  # per-claim key would let a nudge loop write unbounded rows.
  ledger_emit "task.started" ident="$(_hb_ident "$id")" task_id="$id" \
    actor="$name" authority="dispatcher" \
    detail="heartbeat claim (DIVE-2244)" || true
  return 0
}

# Flip one in_progress task back to todo. Clears started_at so its age and the
# per-task nudge counter both restart cleanly, and stamps updated_at. Best-effort
# (a dead db or already-moved task is harmless). Logs why.
#
# DIVE-3251 — WHAT THIS CLEARS AND WHAT IT MUST NOT.
# The started_at=NULL is DELIBERATE and stays: this function's whole job is to
# hand the row back as a clean slate, and the age math below
# (COALESCE(started_at, created_at)) plus the per-task nudge counter both key off
# it. What was WRONG was that started_at was also the only board-visible evidence
# that work had ever happened, so every reclaim silently converted "worked on for
# 90 minutes" into "never started" — 58 rows fleet-wide, 16 of them still open,
# and main could only defend a working seat by going and reading git.
# `first_started_at` now carries that evidence and IS NOT IN THIS UPDATE. Do not
# add it: the reset field and the evidence field are separate on purpose, and
# putting them back together re-opens this defect.
#
# The reclaim also EMITS ITS OWN LEDGER EVENT. It could not be counted before:
# the task.started emit above deliberately uses a constant per-task idem_key, so
# a UNIQUE collision silently drops every re-claim and the ledger records the
# FIRST claim only. That is the right trade there (a nudge loop must not be able
# to write unbounded rows) but it left reclaim cycles invisible to any reader —
# and `task start` writes no audit row either, so separating "the start never
# wrote" from "it wrote and something cleared it" took a second store and a lot
# of luck. This event carries a per-reclaim idem_key (kind|id|epoch) so cycles
# ARE countable, and its detail records the started_at value being erased, which
# is the fact the row itself is about to stop carrying.
_hb_reclaim_to_todo() {
  local name="$1" id="$2" why="$3"
  # Read the value BEFORE the UPDATE destroys it — the whole point is that the
  # erased timestamp survives somewhere a reader can find it.
  local prev_started
  prev_started=$(db "SELECT COALESCE(started_at,'') FROM tasks WHERE id=${id};" 2>/dev/null) || prev_started=""
  db "UPDATE tasks SET status='todo', started_at=NULL, updated_at=datetime('now')
      WHERE id=${id} AND status='in_progress';" 2>/dev/null || true
  # NANOSECONDS, not seconds. lifecycle_events has a UNIQUE index on idem_key and
  # a collision is a SILENT no-op — exactly how task.started lost its re-claims.
  # A second-granularity key is enough for the real cadence and NOT enough for a
  # guarantee, and "enough in practice" is what makes a counter quietly wrong
  # later. Caught by tests/task_first_started_at_unit.sh, whose two reclaims land
  # in the same second.
  local now_stamp; now_stamp=$(date -u +%s%N 2>/dev/null) || now_stamp=""
  ledger_emit "task.reclaimed" ident="$(_hb_ident "$id")" task_id="$id" \
    actor="$name" authority="dispatcher" \
    idem="task.reclaimed|${id}|${now_stamp}" \
    detail="reclaim -> todo (DIVE-3251); why=${why}; cleared started_at=${prev_started:-<empty>}" || true
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
#
# DIVE-2560: (b) and (c) both read claim age as evidence of stall, but a row
# the CURRENT holder is verifying — delivered by its maker, assignee flipped to
# the verifier, handoff_ack_at still NULL — is not stalled at all: the maker's
# job is done and the age on the claim is verifier think-time, not neglect.
# Before this fix that state was indistinguishable from ordinary abandoned
# work, so a verifier who claimed a delivery and sat with it (reading, or just
# between heartbeat ticks) got it yanked back to todo and re-nudged on a loop —
# the exact "claimed then went idle" churn _hb_stall_sweep already has a
# correct, slower-cadence nag for. Rows in that state now skip (b) and (c)
# entirely; (a) still fires, because a truly gone session is a real reason to
# re-present the row fresh regardless of handoff state.
_hb_reclaim() {
  local name="$1" everyMin="$2"
  local budget=$(( everyMin * _HB_STALE_MULT ))
  (( budget < _HB_STALE_MIN_MINUTES )) && budget=$_HB_STALE_MIN_MINUTES
  local proc_start; proc_start=$(_hb_claude_started "$name" 2>/dev/null || true)
  local reclaimed=0 escalated=0 id started_epoch age_min awaiting_verifier
  while IFS='|' read -r id started_epoch age_min awaiting_verifier; do
    [[ -n "$id" ]] || continue
    # (a) the claiming session is gone — process is newer than the claim.
    if [[ -n "$proc_start" && -n "$started_epoch" ]] \
       && (( proc_start > started_epoch + _HB_PROC_SKEW_SEC )); then
      _hb_reclaim_to_todo "$name" "$id" "claiming session gone (claude restarted $(( (proc_start - started_epoch) / 60 ))m after the claim)"
      reclaimed=$((reclaimed + 1)); continue
    fi
    # DIVE-2560: a row currently held by its own VERIFIER, delivered but not yet
    # ACKed (same predicate _hb_stall_sweep already uses to nag the verifier
    # instead), is not stalled — it is sitting in the reviewer's queue, and the
    # clock that matters is the verifier's latency, not this claim's age. Neither
    # the hard-cap nor the idle-stall arm below may reclaim it; only rule (a)
    # above (the holder's session is actually gone) still applies. A row bounced
    # BACK to the maker by a reject is NOT this state — assignee != verifier once
    # that happens — so ordinary rework still reclaims normally.
    if (( awaiting_verifier )); then
      continue
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
                 CAST((julianday('now') - julianday(COALESCE(started_at, created_at))) * 1440 AS INTEGER) || '|' ||
                 CASE WHEN verifier IS NOT NULL AND verifier = assignee
                           AND handoff_delivered_at IS NOT NULL AND handoff_ack_at IS NULL
                      THEN 1 ELSE 0 END
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
  ensure_node_on_path || { echo ""; return 0; }
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

# DIVE-2063 / DIVE-2111: the maker→verifier terminal-state clause appended to the
# /goal nudge. Emits ONE sentence (leading space) when the woken agent stands on a
# live verifier loop — the MAKER variant before the handoff, the VERIFIER variant
# after it — empty otherwise. Never fails the wake: any DB trouble yields "".
#
# WHY EACH HALF EXISTS. The /goal condition accepts exactly three terminal states
# (done, cancelled, human gate). A loop rail has THREE roles and each has a correct,
# complete action that reaches NONE of them:
#   - maker: `task done` DELIVERS (status stays todo, assignee moves to the
#     verifier). Fixed by DIVE-2063.
#   - verifier AFTER the handoff: `task reject` returns a FAIL verdict (status back
#     to todo, assignee back to the maker). DIVE-2063 declined this half on the
#     premise that "for the verifier, the terminal close really is theirs" — false:
#     accept is only ONE of the verifier's two terminal actions, and the other one
#     wedges the session the same way (measured on DIVE-2090). A terminal-state
#     clause has to enumerate TERMINAL ACTIONS, not the happy-path close.
#   - verifier-of-record BEFORE any handoff (maker_agent EMPTY): the row was routed
#     here for a DECISION, not to be built or graded. Its complete action is to make
#     the call and ROUTE THE ROW ON — `task assign`. DIVE-2111's comment called this
#     agent "just an ordinary owner" and gave it nothing, which is right about
#     `reject` (genuinely refused with no maker) and wrong about the role: an
#     ordinary owner is not a null role, it is the third one. Measured six times,
#     last on DIVE-2745 where it wedged olivia's session across ~8 stop attempts.
#     Fixed by DIVE-2834.
#
# WHY THE CLAUSE TELLS THE AGENT TO RE-READ (DIVE-2834, the sharper half). This
# generator runs ONCE, at wake, and its output is frozen into the goal text — but
# `maker_agent` is a LIVE COLUMN, and the tick cannot re-mint the clause mid-session
# because its own busy-guard skips an agent whose task is already in_progress (see
# the header of this file). So a role-derived instruction is cached against a role
# that is not stable for the life of the instruction: on DIVE-2745 the row began
# with no maker, was reassigned out, was built and delivered BACK, and at that point
# the verifier variant's predicate was satisfied — about the same row and the same
# agent, with no event in between other than the rail working as designed. The only
# variant that can be overtaken this way is the third one (the other two are already
# at the end of their role's life), so IT, and only it, also names the role it can
# turn into and points at `task show` as the authority at the moment of acting.
# Re-evaluation still happens — moved from generator-time to act-time, and done by
# the reader against the source of truth rather than by a snapshot that cannot know.
#
# WHY IT IS NOT A FAIL-OPEN. The obvious wrong version of this ("a todo task with
# something in its result field counts as done") would let a maker satisfy the goal
# by writing a result and walking away — worse than the wedge it fixes. So:
#   1. It is keyed on the LOOP SPEC, not on status text: a `verifier` must exist,
#      and whether it equals the woken agent is what SELECTS the variant — it is
#      never inferred from prose.
#   2. The agent must currently OWN the task (assignee = the woken agent), i.e. be
#      the maker about to deliver or the verifier holding the handoff — never a
#      bystander.
#   3. Maker variant: the state it names is the `handoff: delivered (awaiting
#      verifier ACK)` line, which `task show` prints ONLY when maker_agent is set
#      AND assignee=verifier AND the task is still open — i.e. only after
#      `_task_route_to_verifier` has actually recorded the handoff. Nothing the
#      agent can write by hand produces that line; only a real `task done` on a
#      real loop does. maker_agent is stamped from the pre-route assignee, so it
#      equals the woken agent by construction — a state the maker can genuinely
#      reach.
#   4. Verifier variant: gated on maker_agent being set, i.e. the SAME predicate
#      `task show` uses to print the handoff line — so it never names `task
#      reject`, which `cmd_task_reject` refuses unless a maker exists.
#   5. Routing variant: the mirror image — gated on maker_agent being EMPTY, so it
#      and (4) are mutually exclusive by construction and neither can fire on the
#      other's state. The state it names is `assignee = <someone else>`, which the
#      agent cannot reach while still holding the row: satisfying it means actually
#      DIVESTING the task, not writing a field. It is not a "punt anywhere" either
#      — it names ONE default destination, `created_by`, the agent that filed the
#      row and is asking for the answer, and it requires the decision to be
#      recorded on the row BEFORE the routing (a routed row with no reason is the
#      DIVE-2683 empty-cancel defect one verb over).
#
#      AND IT ASSERTS NO ROLE IT CANNOT DERIVE (olivia, iteration 1 reject). The
#      first cut of this variant stated "this row was routed to you for a DECISION,
#      not to build and not to grade" as flat fact. The predicate does not select
#      that: `verifier == assignee && maker_agent EMPTY` is ALSO the shape of a row
#      that is simply the owner's to do. Measured on the live board, 12 closed rows
#      have ever been in this shape and 6 are in the guard's firing set; of those 6,
#      DIVE-2456, DIVE-1956 and DIVE-1789 were owners doing or grading their own
#      work, and in each the correct terminal was the `done` the first cut warned
#      against and never offered. Those rows got silence before the change and would
#      have got a confident wrong premise after it — the worse direction, and this
#      row's own defect class one role over. So the clause now states only what the
#      spec settles (nothing delivered, no handoff, `reject` would refuse), says
#      outright that routed-vs-yours-to-do is indistinguishable here, and lists BOTH
#      terminals: `task assign` for the routed case, `task done` for the do-it-
#      yourself case. It stays silent when
#      created_by is empty or is the woken agent itself, i.e. whenever there is no
#      named party to route to — silence is the correct output there, and the base
#      nudge's own gate path is the exit.
_hb_loop_terminal_clause() {
  local name="$1" task_id="$2" task_ident="$3"
  [[ "$task_id" =~ ^[0-9]+$ ]] || return 0
  local row vfier maker creator rest
  # One read, three fields: the verifier selects the variant, maker_agent proves
  # (or disproves) the handoff, created_by names the routing variant's destination.
  # '|' is safe as a separator — all three are agent names (validated slugs).
  row=$(db "SELECT COALESCE(verifier,'')||'|'||COALESCE(maker_agent,'')||'|'||COALESCE(created_by,'')
              FROM tasks
               WHERE id=${task_id} AND assignee=$(sqlq "$name")
                 AND status NOT IN ('done','cancelled');" 2>/dev/null) || return 0
  vfier="${row%%|*}"; rest="${row#*|}"; maker="${rest%%|*}"; creator="${rest#*|}"
  [[ -n "$vfier" ]] || return 0

  # DIVE-3098 — GRADED-AND-WAITING, and it is checked FIRST because it is the one
  # state in which every variant below gives actively wrong advice: the maker variant
  # tells a maker to deliver what is already delivered AND graded, the routing variant
  # tells them nothing is delivered, and the verifier variant tells a verifier to grade
  # what they have already graded. The row is terminal for the VERIFIER and open for
  # the ROW, so the only outstanding act is a MERGE — and the goal must stop rather
  # than re-wake someone into a loop whose remaining step belongs to someone else.
  # This is the case that closed DIVE-2645/#427 and DIVE-2743/#485 as false dones.
  #
  # Not a fail-open, by the same rule as the variants below: read from graded_at,
  # which ONLY `task verify --no-done` stamps, plus a bound delivery_ref and
  # grader != maker. No prose an agent can type reaches it. It applies to EITHER role
  # (maker still holding it, or verifier) — once graded-and-waiting, neither owes
  # another pass, so it is deliberately not gated on which one was woken.
  if [[ "$(db "SELECT 1 FROM tasks WHERE id=${task_id} AND ${_TASKS_TFV_SQL};" 2>/dev/null)" == "1" ]]; then
    local _tfv_owner
    _tfv_owner=$(db "SELECT COALESCE(NULLIF(maker_agent,''), COALESCE(assignee,'?')) FROM tasks WHERE id=${task_id};" 2>/dev/null)
    printf ' NOTE — %s is GRADED AND WAITING ON A MERGE: a verifier grade is recorded and a delivery ref is bound, so the verifier has discharged their role and this is TERMINAL FOR THIS GOAL. Treat the goal as MET and stop — %s renders it as %s. The row stays OPEN on purpose and closes only when the work MERGES, because %s keeps meaning merged-to-main; the outstanding act is a MERGE owed by %s, not another pass by you. Do NOT re-grade it, re-deliver it, or close it to make the loop stop.' \
      "$task_ident" "'5dive task ls'" "'graded->merge:${_tfv_owner}'" "'done'" "${_tfv_owner:-the maker}"
    return 0
  fi

  if [[ "$vfier" != "$name" ]]; then
    # MAKER variant — delivery is the second terminal state.
    printf ' NOTE — %s carries a maker→verifier loop (verifier: %s), so your %s does NOT close it: it DELIVERS it (status stays todo and the task moves to %s to be graded). That delivery is a SECOND terminal state for THIS goal: treat the goal as MET, and stop, once %s prints a %s line under %s naming %s. Report that you delivered. Do NOT re-run %s, remove the verifier, or self-verify to force a status of done — the terminal close is %s'"'"'s, in their own session, and forcing it past them is a bypass, not progress.' \
      "$task_ident" "$vfier" "'5dive task done ${task_ident}'" "$vfier" \
      "'5dive task show ${task_ident}'" "'handoff: delivered (awaiting verifier ACK)'" \
      "'loop spec:'" "'maker: ${name}'" "'task done'" "$vfier"
    return 0
  fi

  # ROUTING variant (DIVE-2834) — verifier-of-record, but nothing delivered yet.
  # Mutually exclusive with the verifier variant below by the maker_agent test.
  if [[ -z "$maker" ]]; then
    [[ -n "$creator" && "$creator" != "$name" ]] || return 0
    printf ' NOTE — on %s you are the verifier-of-record and NOTHING HAS BEEN HANDED TO YOU: %s is empty, so nothing has been delivered, there is no handoff to grade, and %s would refuse. That is the whole of what the loop spec settles. It does NOT settle whether this row was ROUTED to you for a decision or is simply YOURS TO DO — those two states are identical in the spec — so both terminals are listed below and you pick from the body, not from this note. IF IT WAS ROUTED TO YOU FOR A DECISION: make the call, write it and its reason onto the row (%s), then run %s and treat the goal as MET, and stop, once %s prints an %s line naming someone other than you; %s filed this row and is the default destination, pick a different agent only if the body says so. IF THE WORK IS YOURS TO DO: do it and close it with %s — that is the honest terminal for this state and nothing here is steering you off it. Not available either way: grading an empty handoff, recording a done for work nobody did, or cancelling a live row to clear your board. AND RE-READ %s AT THE MOMENT YOU ACT, because this note was written when the row had no maker and that is a live column: if the work is built and delivered BACK to you inside this same session, %s will then print %s under %s and a %s line, and your terminal action becomes the VERIFIER'"'"'s — accept with %s, or return a FAIL verdict with %s.' \
      "$task_ident" "'maker_agent'" "'task reject'" \
      "'5dive task set-body ${task_ident}' or a gate answer" \
      "'5dive task assign ${task_ident} ${creator}'" \
      "'5dive task show ${task_ident}'" "'assignee ='" "$creator" \
      "'5dive task done ${task_ident}'" \
      "'5dive task show ${task_ident}'" "'5dive task show ${task_ident}'" \
      "'maker: ${creator}'" "'loop spec:'" \
      "'handoff: delivered (awaiting verifier ACK)'" \
      "'5dive task done ${task_ident}'" \
      "'5dive task reject ${task_ident} --feedback=\"<what to fix>\"'"
    return 0
  fi

  # VERIFIER variant — only once the maker has actually handed off.
  [[ "$maker" != "$name" ]] || return 0
  printf ' NOTE — you are the VERIFIER on %s (maker: %s) and the handoff is already delivered, so you are here to GRADE the work, not to build or rescue it. A FAIL verdict is a complete, terminal outcome: if it does not pass, run %s and treat the goal as MET, and stop — the reject is a SECOND terminal state for THIS goal even though it leaves status todo, because it bounces the task back to %s (%s will show %s and a %s result line). Report that you rejected and why. Do NOT record a done you do not believe, cancel work that is verified-good, or file a human gate for something %s can fix in another pass — a correct reject IS the terminal action, and forcing a done/cancel past it writes a false record to the board.' \
    "$task_ident" "$maker" "'5dive task reject ${task_ident} --feedback=\"<what to fix>\"'" \
    "$maker" "'5dive task show ${task_ident}'" "'assignee = ${maker}'" \
    "'❌ ${name} rejected'" "$maker"
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

  # DIVE-2063: a task carrying a maker→verifier loop can NEVER reach any of the
  # three terminal states above by the MAKER's own hand. A correct 'task done'
  # DELIVERS it (status stays todo, assignee moves to the verifier) — the rail
  # working as designed, and the one outcome the condition refuses. So the goal
  # re-fires every turn while the maker has nothing left to do but wait on a
  # peer's independent session, and the only actions that WOULD satisfy it are
  # the fail-open ones (a second 'task done', dropping the verifier). Teach the
  # nudge a second terminal state for loop tasks specifically. See the helper for
  # why this can't be satisfied by writing a result and walking away.
  #
  # DIVE-2111: and the same is true on the OTHER side of the rail. A verifier has
  # TWO terminal actions, not one — accept ('task done', which does close) and
  # REJECT (a FAIL verdict, which returns the task to the maker at status todo).
  # DIVE-2063 declined the verifier half on the premise that its close is always
  # terminal; measured false on DIVE-2090, where a correct reject left the grader
  # with no honest exit and the goal re-fired five times. The helper now emits the
  # role-appropriate variant, keyed on the loop spec either way.
  local loop_clause=""
  loop_clause=$(_hb_loop_terminal_clause "$name" "$task_id" "$task_ident") || loop_clause=""
  [[ -n "$loop_clause" ]] && nudge="${nudge}${loop_clause}"

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
# DIVE-2055: the query used to key on kind+schedule alone, so a cancelled,
# blocked, or parked template kept firing forever — none of `task cancel`,
# `task block`, or `task park` (all of which move status off 'todo') had any
# effect on the scheduler. status='todo' is now part of the fire predicate,
# so any of those three verbs is a real stop lever; no new CLI verb needed.
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
  local now="$1" minute_start tid sched last_fired policy bound open open_read open_rc stamp_err n_made=0
  minute_start=$(date -u -d "@${now}" +'%Y-%m-%d %H:%M:00')
  # DIVE-2272: x'1f' + IFS=$'\x1f', NOT '|' + tr + IFS=$'\t'. Tab is an IFS
  # WHITESPACE character, so bash collapses runs of it and an EMPTY field in the
  # middle of the row silently disappears, shifting every column after it. The
  # old 3-column form survived only because its one nullable field was LAST;
  # adding on_overlap/overlap_bound after last_fired_at put an empty field in the
  # middle, and the symptom was not a parse error but `last_fired` holding the
  # policy string — after which the same-minute guard rejected every template and
  # the materializer silently stopped firing anything. x'1f' is not IFS
  # whitespace, so empty fields survive. Same separator the stall sweeps below
  # already use, for the same reason.
  while IFS=$'\x1f' read -r tid sched last_fired policy bound; do
    [[ -n "$tid" ]] || continue
    _cron_matches "$sched" "$now" || continue
    # Already fired this minute? (string compare on ISO 'YYYY-MM-DD HH:MM:SS';
    # last_fired >= minute_start means a tick already materialized it this minute.)
    if [[ -n "$last_fired" ]] && ! [[ "$last_fired" < "$minute_start" ]]; then
      continue
    fi
    # DIVE-2273: "the count is non-zero" and "the count could not be read" are
    # DIFFERENT STATES and only one of them is a suppression. The old form
    # (`... 2>/dev/null || echo 1`, plus `${open:-1}`) collapsed the failure
    # into a legitimate magnitude, so an unreadable DB took the skip branch --
    # and since DIVE-2237 that branch STAMPS last_skipped_at, writing a
    # suppression that never happened. The DIVE-2237 reading table defines
    # "stale last_fired + recent last_skipped" as "a human must close the
    # blocker"; after this path there IS no blocker to close, so the human is
    # sent after nothing and learns to distrust the column. An instrument must
    # not report a cause it did not observe.
    #
    # The FIRE/NO-FIRE decision is deliberately unchanged: an unreadable count
    # still skips. Not spawning is the conservative outcome while every
    # template is dedup'd, and the error DEFAULT is a policy question that
    # belongs with --on-overlap (DIVE-2270 decision / DIVE-2272) -- for a
    # spawn-class template an unreadable count should FIRE. What changes here
    # is only that the error is recorded AS an error and stamps nothing.
    #
    # NOTE FOR DIVE-2272: this branch is where the spawn-class error default
    # belongs, and the error must NOT fall through to the bound comparison. The
    # old sentinel 1 is conservative against a boolean test and PERMISSIVE
    # against a bound of 3, and the bound is spawn's safety valve computed from
    # the very read it backstops -- a failing read would pin `open` at 1 so the
    # valve never trips. Keep the failure out of the magnitude entirely.
    #
    # 2>&1 (not 2>/dev/null) so the sqlite error itself reaches _hb_log; the
    # shape check is what keeps that stderr from being mistaken for a count.
    open_rc=0
    open_read=$(db "SELECT COUNT(*) FROM tasks WHERE from_template_id=${tid} AND status NOT IN ('done','cancelled');" 2>&1) || open_rc=$?
    if (( open_rc != 0 )) || [[ ! "$open_read" =~ ^[0-9]+$ ]]; then
      _hb_log "[materializer] $(_hb_ident "$tid") open-instance count UNREADABLE (rc=${open_rc}: ${open_read//$'\n'/ }) — skipping, NOT recording a suppression"
      continue
    fi
    open="$open_read"
    # DIVE-2272 (decision DIVE-2270): the PER-TEMPLATE overlap policy. Reached
    # ONLY with a count that was actually read -- the UNREADABLE branch above
    # `continue`s, so a failed read can never reach the bound comparison below.
    # That ordering is the whole point of the DIVE-2273 prerequisite and it is
    # load-bearing, not stylistic: the old sentinel 1 is CONSERVATIVE against a
    # boolean test ("nonzero -> skip") and PERMISSIVE against a bound of 3
    # ("1 < 3 -> spawn"), so promoting `open` from a boolean to a magnitude
    # re-aims the error default without touching the error handling. Worse, the
    # bound is spawn's safety valve and it is computed FROM THE SAME READ IT
    # BACKSTOPS -- a failing read pins `open` at 1, the bound never trips, and
    # the degrade path never engages in exactly the conditions that call for it.
    # THE GENERAL RULE, worth more than this feature: when you widen how a value
    # is CONSUMED, re-audit its error sentinel, because the sentinel was chosen
    # against the OLD consumer. Keep the failure out of the magnitude entirely.
    #
    # NULL/'' policy = 'skip' = today's behaviour byte for byte, so this is a
    # no-op migration for every template that predates the column.
    if [[ "${policy:-}" == "spawn" ]]; then
      # NULL/unparseable bound falls back to the built-in default. The default is
      # a JUDGMENT CALL, NOT A MEASUREMENT (3 open recaps is unmistakable to a
      # human; 300 is a different outage) -- tunable per template so the number
      # is never mistaken for something derived.
      [[ "${bound:-}" =~ ^[1-9][0-9]*$ ]] || bound="$_HB_OVERLAP_BOUND_DEFAULT"
      if (( open < bound )); then
        # Fire DESPITE open instances. For a reading-of-the-present job the
        # pile-up is the signal, not the noise: Tuesday's recap is not
        # discharged by Wednesday's run.
        _hb_log "[materializer] $(_hb_ident "$tid") on-overlap=spawn — ${open} open (< ${bound}) — firing anyway"
      else
        # AT OR OVER THE BOUND: degrade to EXACTLY today's skip-and-stamp. This
        # is deliberately the existing, already-legible suppression path rather
        # than new alarm machinery -- `task ls --recurring` and the DIVE-2237
        # reading table keep working unchanged, and a spawn-class template that
        # has genuinely run away reads the same as any other suppressed one.
        stamp_err=$(db "UPDATE tasks SET last_skipped_at=datetime('now') WHERE id=${tid};" 2>&1) \
          || _hb_log "[materializer] $(_hb_ident "$tid") last_skipped_at stamp FAILED: ${stamp_err//$'\n'/ }" \
          || true
        _hb_log "[materializer] $(_hb_ident "$tid") on-overlap=spawn but ${open} open >= bound ${bound} — skip (bounded)"
        continue
      fi
    elif [[ "$open" != "0" ]]; then
      # DIVE-2237: RECORD the skip. The dedup decision is unchanged -- we still
      # skip -- but a skip now leaves a trace on the row itself, not only in
      # _hb_log (which nothing surfaces and nobody reads). Without this, a
      # template suppressed for days reads on `task ls --recurring` exactly like
      # one the scheduler never reached, and a monitor implemented as a
      # recurring task can switch itself off in silence. Best-effort: a failed
      # stamp must never change whether the pass fires anything.
      stamp_err=$(db "UPDATE tasks SET last_skipped_at=datetime('now') WHERE id=${tid};" 2>&1) \
        || _hb_log "[materializer] $(_hb_ident "$tid") last_skipped_at stamp FAILED: ${stamp_err//$'\n'/ }" \
        || true
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
  done < <(db "SELECT id||x'1f'||schedule||x'1f'||COALESCE(last_fired_at,'')||x'1f'||COALESCE(on_overlap,'skip')||x'1f'||COALESCE(overlap_bound,'') FROM tasks WHERE kind='recurring' AND schedule IS NOT NULL AND status='todo';" 2>/dev/null)
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
#       raw-sqlite forgery. Deliberately NEVER: HUMAN-CLASS gates
#       (_gate_human_class — DIVE-2235; this used to exclude only 'secret', so
#       a tier-1 APPROVAL/MANUAL/ACCESS self-applied its own recommendation
#       after 48h with no human: tier was downgrading class), loop gate steps
#       (a relay must not advance on a timeout — and
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
    # DIVE-2054: task-store auto-clear (TTL) — fenced on STORE IDENTITY, same
    # primitive as cmd_task.sh's _task_store_audit_log (DIVE-2010).
    _task_store_audit_log "gate ttl-auto" "ok" 0 -- "task=$gident" "type=$gtype" "applied=$grec" || true
    [[ -n "$gowner" ]] && ( cmd_send "$gowner" --message="⏱ ${gident} tier-1 gate hit its 48h TTL — recommendation applied: ${grec}. Resume the task; run \`5dive task show ${gident}\`." ) >/dev/null 2>&1 || true
    _hb_log "[gate-ttl] ${gident} T1 48h TTL -> applied rec"
  done < <(db "SELECT id||x'1f'||need_type||x'1f'||COALESCE(recommend,'')||x'1f'||COALESCE(assignee,'')
               FROM tasks
               WHERE need_type IS NOT NULL AND need_answered_at IS NULL
                 AND tier=1 AND recommend IS NOT NULL
                 AND need_type NOT IN ${_GATE_HUMAN_CLASS_SQL}
                 AND need_asked_at IS NOT NULL AND need_asked_at <= datetime('now','-48 hours')
                 AND (body IS NULL OR body NOT LIKE '%${_LOOP_MARK}:%')
                 AND status NOT IN ('done','cancelled');")

  # (3) T2 stale-gate reminder batches, one message per filing agent's channel.
  # Age clock: COALESCE(need_asked_at, updated_at) — legacy gates predate
  # need_asked_at; updated_at is a fine fuzzy clock when the worst case is a
  # reminder. The stale filter (need_answered_at IS NULL etc.) matches the
  # canonical inbox definition.
  # DIVE-2235: the tier-1 human-class arm is NOT cosmetic. Pass (2) just stopped
  # TTL-applying those gates, and pass (3) previously only covered tier-1 gates
  # with NO recommendation — so a tier-1 approval WITH a recommendation would
  # have become an orphan: never auto-applied, never reminded, invisible. The
  # two predicates are complementary BY CONSTRUCTION on the same list; when one
  # stops resolving a gate the other has to start reminding about it.
  local _t2_where="need_type IS NOT NULL AND need_answered_at IS NULL
                 AND (tier IS NULL OR tier=2 OR (tier=1 AND recommend IS NULL)
                      OR (tier=1 AND need_type IN ${_GATE_HUMAN_CLASS_SQL}))
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
    # DIVE-3342: a gate reminder is a gate send — it goes to the person who may
    # clear these rows. A batch spanning two owners is refused and logged by the
    # send (never delivered to the wrong person); those rows still re-nag
    # per-owner through _hb_gate_renag_sweep, which partitions.
    _task_send_gate_owner "$text" "" "$reminder_ids" || true
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
  AND (COALESCE(need_asked_at,updated_at,created_at) <= datetime('now','-1 hour')
       OR (gate_pinged_at IS NULL
           AND COALESCE(need_asked_at,updated_at,created_at) <= datetime('now','-15 minutes')))
  AND NOT (tier=1 AND recommend IS NOT NULL
           AND COALESCE(need_asked_at,updated_at,created_at) <= datetime('now','-48 hours'))
  AND (gate_pinged_at IS NULL
       OR gate_pinged_at < datetime(COALESCE(need_asked_at,updated_at,created_at),'+1 hour')
       OR gate_pinged_at <= datetime('now','-24 hours'))"

# DIVE-3342: partition a re-nag batch by the PERSON each gate belongs to, then
# run the renderer once per owner. This sweep is the surface that caused the
# reported harm — a customer CTO re-nagged nightly for six days on rows he had no
# relationship to — and the reason was structural: the batch renders one message
# for every gate a recipient agent holds and then sent it to whoever last DM'd
# that agent's bot. Rendering per owner is what makes "deliver to the clearer"
# expressible for a batch; without it, a mixed batch can only be refused.
# Rows nobody owns (group `-`) still go through the renderer: it calls
# _task_send_gate_owner, which holds them on the agent rail and records why,
# rather than falling back to the allowlist.
_hb_gate_renag_batch() { # <recipient_agent> <comma-separated task ids> <route_label>
  local recipient="$1" idlist="$2" label="${3:-}"
  if ! _human_registry_active; then
    _hb_gate_renag_batch_one "$recipient" "$idlist" "$label"
    return $?
  fi
  local line owner ids rc=0
  while IFS=$'\t' read -r owner ids; do
    [[ -n "$ids" ]] || continue
    _hb_log "[gate-renag] owner=${owner} rows=${ids} (partitioned by human owner)"
    _hb_gate_renag_batch_one "$recipient" "$ids" "$label" || rc=$?
  done < <(_human_gate_ids_by_owner "$idlist")
  return $rc
}

_hb_gate_renag_batch_one() { # <recipient_agent> <comma-separated task ids> <route_label>
  local recipient="$1" idlist="$2" route_label="$3"
  [[ -n "$recipient" && "$idlist" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 0
  # DIVE-1927: an unpaired recipient used to mean "retry next heartbeat" forever —
  # the same silent hole as the file-time path. A channel-less filer's gate can
  # NEVER become deliverable by waiting, so walk UP reports_to to the nearest
  # paired agent instead (this sweep runs as root, so every access.json is
  # readable) and name the original filer in the message. Only when nobody in the
  # whole chain is paired do we log and retry.
  local _escalated_from=""
  if ! _task_agent_channel "$recipient"; then
    # Direct call, never $( ) — _task_chain_channel resolves TASK_CH_* into the
    # CURRENT shell and a command substitution would discard exactly that.
    local _up=""
    _task_chain_channel "$recipient" && _up="$TASK_CH_AGENT"
    if [[ -n "$_up" ]]; then
      _escalated_from="$recipient"
      route_label="${route_label} — escalated off unpaired ${recipient}"
      _hb_log "[gate-renag] ${recipient} unpaired; escalated rows ${idlist} to ${_up}"
    else
      warn "gate re-nag for task rows ${idlist}: recipient ${recipient} has no paired channel and neither does anyone above it; will retry next heartbeat"
      _hb_log "[gate-renag] no paired channel for ${recipient} or anyone above it for rows ${idlist}"
      return 0
    fi
  fi

  local text="🔁 Gate reminder — unanswered gates (${route_label}):"
  [[ -n "$_escalated_from" ]] \
    && text+=$'\n'"↑ filed by ${_escalated_from} (no channel of its own) — escalated to you"
  local rows='[]' row id ident ntype options recommend gtier ask nonce="" markup="" _mint_n=0
  local -a nonce_ids=() nonce_hashes=()
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS=$'\x1f' read -r id ident ntype options recommend gtier ask <<<"$row"
    [[ -n "$id" && -n "$ident" ]] || continue
    text+=$'\n\n'"• [${ident}] ${ntype} — ${ask} /task_${id}"
    [[ -n "$recommend" ]] && text+=$'\n'"  ✅ Recommended: ${recommend}"
    [[ -n "$options" ]] && text+=$'\n'"  Options: ${options}"

    # DIVE-2356: hard-human TYPE **or** tier>=2 (matches the cmd_task_need mint).
    # This sweep is the rescue path for gates filed BEFORE the widened mint — a
    # tier-2 decision that has been sitting nonce-less picks one up on its first
    # re-nag rather than waiting to be re-filed. `tier` is now selected below.
    nonce=""; _mint_n=0
    case "$ntype" in approval|secret|manual) _mint_n=1 ;; esac
    [[ "${gtier:-}" =~ ^[0-9]+$ ]] && (( gtier >= 2 )) && _mint_n=1
    if (( _mint_n )); then
      nonce=$(_human_nonce_mint)
      if [[ -n "$nonce" ]]; then
        nonce_ids+=("$id")
        nonce_hashes+=("$(_human_nonce_sha "$nonce")")
      fi
    fi
    markup=$(_task_gate_reply_markup "$id" "$ntype" "$options" "$recommend" "$nonce" "$TASK_CH_TYPE" "$ident")
    if [[ -n "$markup" ]]; then
      rows=$(jq -cn --argjson a "$rows" --argjson b "$markup" '$a + ($b.inline_keyboard // [])' 2>/dev/null) || rows='[]'
    fi
    # `ask` stays LAST so it remains the greedy tail of the `read`; tier is
    # spliced in ahead of it rather than appended after it.
  done < <(db "SELECT id||x'1f'||ident||x'1f'||need_type||x'1f'||COALESCE(need_options,'')||x'1f'||COALESCE(recommend,'')||x'1f'||COALESCE(tier,'')||x'1f'||substr(replace(COALESCE(ask,''),x'0a',' '),1,240)
               FROM tasks WHERE id IN (${idlist}) ORDER BY COALESCE(need_asked_at,updated_at,created_at),id;")

  local reply_markup=""
  [[ "$rows" != "[]" ]] && reply_markup=$(jq -cn --argjson rows "$rows" '{inline_keyboard:$rows}' 2>/dev/null) || true
  text+=$'\n\n'"Tap a button, open /task links, or answer from the dashboard. First reminder is after 1h; later reminders are batched every 24h until answered."
  # DIVE-2073: mark the rail so the delivery row can say which path it is on.
  # This sweep runs as root from cron with no invoking user, so `user` on the row
  # is root and names no agent; without this every :NN:02 delivery is
  # indistinguishable from a file-time send by the same uid.
  TASK_GATE_RENAG=1
  _task_send_gate_owner "$text" "$reply_markup" "$idlist"
  TASK_GATE_RENAG=""
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

# DIVE-2587 — the AGENT RAIL for lead-routed re-nags.
#
# MEASURED, not inferred (prod board + /var/log/5dive-heartbeat.log, 2026-08-03):
# every engineering approval that reached the human that day on the T1 lane was
# ALREADY correctly routed. One row isolates it — a push-for-review approval
# filed 09:20:21 with routed_reviewer=olivia, gate_pinged_at 09:40:02, and the
# heartbeat log carries the matching `[gate-renag] delivered <row> via olivia`
# line for that exact second. The ping came from THIS sweep, not from filing:
# the file-time routed rail (_task_need_route_deliver) never touches Telegram at
# all, it hands off over `5dive agent send`, and every gate it filed that day
# still has gate_pinged_at NULL. Routing was never the defect.
#
# WHY MORE ROUTING CANNOT FIX IT: `_task_agent_channel olivia` resolves olivia's
# PAIRED channel, and on this host every paired agent is paired to the SAME human
# chat. "Send it to the lead" and "send it to the human" are the same Bot API
# call with a different bot token. Routing decides who may CLEAR a gate; it has
# never decided whose phone rings. This sweep predates the lead-route rail and
# has no agent branch at all, so it converts a correctly routed gate back into a
# human ping — with tap buttons, which is why the human then answers it and the
# record reads `human:olivia` on a row nobody mis-routed.
#
# So an AGENT reviewer's re-nag goes over the agent rail, the same rail the
# file-time handoff already uses. It falls back to the paired-human channel when
# that rail cannot deliver, and the caller keeps the human channel for gates past
# _HB_GATE_AGENT_RAIL_HOURS. That backstop is what makes this a QUIETING change
# and not a SILENCING one: a lead-routed gate nobody clears still reaches a
# person, just not inside the first day.
#
# Synchronous by choice, unlike the file-time rail's detached poll: the org-parent
# escalation a few lines up already calls `cmd_send` synchronously in this same
# sweep, there are at most a handful of reviewers per tick, and an rc we can
# branch on is the whole basis of the fallback. An unobserved send here would
# reproduce DIVE-2011 on a fresh rail.
_hb_gate_renag_agent_rail() { # <reviewer> <ids> -> 0 delivered, 1 = caller must fall back
  local reviewer="$1" idlist="$2"
  [[ "${FIVEDIVE_GATE_RENAG_AGENT_RAIL:-1}" != "0" ]] || return 1
  [[ -n "$reviewer" && "$idlist" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
  # Only an agent has a terminal to read this in. A reviewer who is not on the
  # org chart is not one, and keeps the human channel.
  [[ -n "$(db "SELECT name FROM agents_org WHERE name=$(sqlq "$reviewer");")" ]] || return 1
  local text row
  text="🔁 Gate reminder — gate(s) routed to you for review, still unanswered:"
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    text+=$'\n'"• ${row}"
  done < <(db "SELECT '['||ident||'] '||COALESCE(need_type,'gate')||' — '||substr(replace(COALESCE(ask,''),x'0a',' '),1,240)
               FROM tasks WHERE id IN (${idlist}) ORDER BY COALESCE(need_asked_at,updated_at,created_at),id;")
  text+=$'\n\n'"Clear one with: 5dive task answer <ident> --value=\"<choice>\" — or re-file to escalate to the human."
  local out="" rc=0
  out=$(cmd_send "$reviewer" --message="$text" 2>&1) || rc=$?
  if (( rc != 0 )); then
    _hb_log "[gate-renag] agent rail to ${reviewer} FAILED rc=${rc} for rows ${idlist}; falling back to the paired channel: ${out//$'\n'/ }"
    return 1
  fi
  # gate_pinged_at is the receipt AND the throttle (see _HB_GATE_RENAG_WHERE).
  # Not stamping it here would re-send to the lead on EVERY tick.
  db "UPDATE tasks SET gate_pinged_at=datetime('now')
      WHERE id IN (${idlist}) AND need_type IS NOT NULL AND need_answered_at IS NULL;" 2>/dev/null || true
  _task_gate_delivery_log ok "$idlist" "agent:${reviewer}" "" \
    "gate re-nag delivered to ${reviewer} over the agent rail (no human channel send)" || true
  _hb_log "[gate-renag] delivered ${idlist} via agent rail to ${reviewer}"
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
  # DIVE-1945: this lane resolves the reviewer FROM the filer's org position, so
  # it is a whose-ask-is-this question and takes gate_filed_by — unlike the T2
  # sweep above, which batches by the channel OWNER and correctly stays on
  # created_by. Same COALESCE fallback for pre-column gates.
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
  done < <(db "SELECT id||x'1f'||COALESCE(NULLIF(gate_filed_by,''),NULLIF(created_by,''),assignee,'')||x'1f'||COALESCE(routed_reviewer,'')
               FROM tasks WHERE ${_HB_GATE_RENAG_WHERE} AND tier=1
               ORDER BY COALESCE(need_asked_at,updated_at,created_at),id;")
  # DIVE-2587: split each reviewer's batch by AGE. Fresh gates go over the agent
  # rail (quiet, in-band, no human push); anything past the backstop window keeps
  # the paired-human channel, because in-band nagging has demonstrably not worked
  # by then. A rail that refuses or fails hands its rows straight back to the
  # human batch — the failure direction is LOUD, never dropped.
  local _rail_h _fresh _stale
  _rail_h="${FIVEDIVE_GATE_RENAG_AGENT_RAIL_HOURS:-24}"
  [[ "$_rail_h" =~ ^[0-9]+$ ]] || _rail_h=24
  for reviewer in "${!lead_ids[@]}"; do
    _fresh=$(db "SELECT id FROM tasks WHERE id IN (${lead_ids[$reviewer]})
                 AND COALESCE(need_asked_at,updated_at,created_at) > datetime('now','-${_rail_h} hours')
                 ORDER BY id;" | paste -sd, -)
    _stale=$(db "SELECT id FROM tasks WHERE id IN (${lead_ids[$reviewer]})
                 AND COALESCE(need_asked_at,updated_at,created_at) <= datetime('now','-${_rail_h} hours')
                 ORDER BY id;" | paste -sd, -)
    if [[ -n "$_fresh" ]] && ! _hb_gate_renag_agent_rail "$reviewer" "$_fresh"; then
      _stale="${_stale:+${_stale},}${_fresh}"
    fi
    [[ -n "$_stale" ]] && _hb_gate_renag_batch "$reviewer" "$_stale" "org lead"
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
           --grep="${ident}([^0-9]|\$)" --format='%h %ct %s' -1 2>/dev/null) || return 1
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
  local grow gid gident gtype gowner repo hit _c_epoch _asked
  # Normalize the repo allow-list: commas or spaces both separate.
  local repos; repos="${_HB_GATE_SHIPPED_REPOS//,/ }"
  [[ -n "${repos// }" ]] || return 0
  # DIVE-2414: resolve the read-only gh credential ONCE for the whole sweep, not
  # per gate — _gate_gh_token can shell out to sudo and the sweep runs every tick.
  # Empty is a first-class answer: the subject reader returns UNKNOWN, never a
  # silent accept.
  local _gs_tok=""
  command -v gh >/dev/null 2>&1 && _gs_tok=$(_gate_gh_token)
  while IFS= read -r grow; do
    [[ -n "$grow" ]] || continue
    IFS=$'\x1f' read -r gid gident gtype gowner <<<"$grow"
    [[ -n "$gid" && -n "$gident" ]] || continue
    # DIVE-2068: type=secret is satisfied ONLY by a human handing over a
    # credential — that event cannot appear in a commit or a merged PR, ever.
    # So for this type a commit/PR hit carries ZERO information and "likely
    # shipped, verify and close" would be a false positive 100% of the time.
    # Skip both evidence paths below (subject-PR and row-commit) up front;
    # decision/approval/manual are unaffected — a commit genuinely can be
    # evidence for those.
    if [[ "$gtype" == "secret" ]]; then
      _hb_log "[gate-shipped] ${gident} — type=secret: a commit/PR can never be evidence a credential was handed over (DIVE-2068); NOT flagging, gate stays eligible"
      _task_store_audit_log "gate shipped-flag" "skip" 0 -- "task=$gident" "reason=type-secret" || true
      continue
    fi
    # DIVE-2414: READ WHAT THE GATE IS ABOUT BEFORE READING THE ROW.
    # The commit-stream lookup below is row-level evidence: it answers "did
    # something naming this ROW land", which on a multi-item row is routinely a
    # different item than the one the ask is about (DIVE-2382 — flagged "likely
    # shipped, verify+close" while its live approval asked about something else).
    # So when the ASK names a pull request, that PR's MEASURED state is
    # authoritative and the row's commits are not consulted at all:
    #   OPEN     -> withhold the flag even if the row has commits. The ask is live.
    #   UNKNOWN  -> withhold. A state that could not be read is not a negative
    #               (DIVE-2318). No stamp, so a later tick retries.
    #   MERGED   -> flag, with the SUBJECT as the named evidence.
    # A gate that names NO subject falls through to the row-level path, which
    # keeps its DIVE-1140 behaviour and now SAYS which evidence class it used.
    # Fetched per row rather than in the sweep query on purpose: an ask is
    # multi-line and would break the x'1f' line-per-row read above.
    local _ask _sbody _sslug _sv _svd
    _ask=$(db "SELECT COALESCE(ask,'') FROM tasks WHERE id=${gid};")
    _sbody=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${gid};")
    _sslug=$(_gate_task_repo_slug "" "$_sbody")
    _sv=$(_gate_subject_verdict "$_ask" "$_gs_tok" "$gident" "$_sslug")
    _svd="${_sv#*|}"
    case "${_sv%%|*}" in
      OPEN)
        _hb_log "[gate-shipped] ${gident} — the PR its ASK names is still OPEN (${_svd}); NOT flagging, and the row's own commits are NOT evidence about this gate (DIVE-2414). Gate stays eligible."
        _task_store_audit_log "gate shipped-flag" "skip" 0 -- "task=$gident" "reason=subject-open" "subject=$_svd" || true
        continue ;;
      UNKNOWN)
        _hb_log "[gate-shipped] ${gident} — its ASK names a PR whose state could NOT be read (${_svd}); NOT flagging (a non-verdict is not a negative), no stamp, will retry (DIVE-2414)."
        _task_store_audit_log "gate shipped-flag" "skip" 0 -- "task=$gident" "reason=subject-unreadable" "subject=$_svd" || true
        continue ;;
      MERGED)
        db "UPDATE tasks SET shipped_flag_at=datetime('now') WHERE id=${gid};"
        _task_store_audit_log "gate shipped-flag" "ok" 0 -- "task=$gident" "type=$gtype" "evidence=subject-pr" "subject=$_svd" || true
        _hb_log "[gate-shipped] ${gident} — the PR its ASK names is MERGED (${_svd}) -> flagged on SUBJECT state, not on the row's commits (DIVE-2414)"
        if [[ -n "$gowner" ]] && _task_agent_channel "$gowner"; then
          ( cmd_send "$gowner" --message="🚢 ${gident} — the pull request this open ${gtype} gate ASKS ABOUT is now merged (${_svd}). Likely settled: verify and close with \`5dive task show ${gident}\`. Auto-flag only — a merge is not a sign-off (DIVE-555), so it stays open until you clear it." ) >/dev/null 2>&1 || true
        fi
        continue ;;
    esac
    # NO-SUBJECT from here down: the ask names no pull request, so nothing can
    # retire it automatically and the row-level nudge has to say what it is.
    hit=""
    for repo in $repos; do
      hit=$(_hb_repo_grep_ident "$repo" "$gident") && [[ -n "$hit" ]] && break
      hit=""
    done
    [[ -n "$hit" ]] || continue
    # DIVE-2001: a merge that PREDATES the open ask cannot be evidence the ask is
    # satisfied. The flag fired on DIVE-1968 citing a commit merged ~2h before the
    # gate existed, telling the owner "likely shipped, verify and close" about work
    # the open ask had nothing to do with. On a ticket that lands in pieces that
    # nudge points the right way for the wrong reason, arrives with the authority
    # of an automatic check, and agrees with what the assignee already wants to do.
    # Deliberately does NOT stamp shipped_flag_at: the gate stays eligible, so a
    # genuinely later merge still flags on a subsequent tick.
    _c_epoch=$(awk '{print $3}' <<<"$hit")
    _asked=$(db "SELECT COALESCE(strftime('%s', need_asked_at),'') FROM tasks WHERE id=${gid};")
    # DIVE-2003: the epoch is field 3 of _hb_repo_grep_ident's output — git's
    # '%h %ct %s' with the repo stem PREPENDED. That field index is a contract
    # between two functions and the unit test STUBS the producer, so a drift in
    # the real --format string is invisible to the suite. Measured by olivia:
    # reverting the stub to a no-epoch format and DELETING this guard outright
    # give the IDENTICAL 8/2 signature, and the fall-through wrote nothing to
    # _hb_log or audit_log — so the guard could vanish leaving no trace anywhere.
    # Fail-open remains correct (withholding a legitimate flag is itself a
    # silence), but it must never again be silent.
    if [[ ! "$_c_epoch" =~ ^[0-9]+$ ]]; then
      _hb_log "[gate-shipped] ${gident} — commit epoch UNPARSEABLE from lookup (\"${hit}\"); flagging anyway, but the predates-ask guard could NOT run (lookup format drift?)"
      # DIVE-2054: task-store gate-sweep telemetry — fenced.
      _task_store_audit_log "gate shipped-flag" "degraded" 0 -- "task=$gident" "reason=epoch-unparseable" "commit=$hit" || true
    elif [[ ! "$_asked" =~ ^[0-9]+$ ]]; then
      # Deliberately a DIFFERENT message from the drift case above: legacy gates
      # predate need_asked_at, so this is expected and routine. Folding the two
      # together would bury the drift signal in noise that operators learn to skip.
      # And deliberately a different DURABILITY: the drift branch writes an audit
      # row, this one does not. A routine event does not belong in the audit table
      # — filling it with the expected case is how the exceptional case stops being
      # findable in it.
      _hb_log "[gate-shipped] ${gident} — no need_asked_at stamp; predates-ask guard not applicable (legacy gate)"
    elif (( _c_epoch < _asked )); then
      _hb_log "[gate-shipped] ${gident} — newest matching commit PREDATES the open ask ($(date -u -d @"$_c_epoch" +%FT%TZ) < $(date -u -d @"$_asked" +%FT%TZ)); NOT flagging, gate stays eligible"
      # DIVE-2054: same reasoning as the "degraded" case above — fenced.
      _task_store_audit_log "gate shipped-flag" "skip" 0 -- "task=$gident" "reason=commit-predates-ask" "commit=$hit" || true
      continue
    fi
    db "UPDATE tasks SET shipped_flag_at=datetime('now') WHERE id=${gid};"
    # DIVE-2054: same reasoning as the two branches above — fenced.
    _task_store_audit_log "gate shipped-flag" "ok" 0 -- "task=$gident" "type=$gtype" "evidence=row-commit" "commit=$hit" || true
    _hb_log "[gate-shipped] ${gident} — its ask names NO PR subject; falling back to ROW-level evidence: commit on ${_HB_GATE_SHIPPED_REF} references the row: ${hit} -> flagged"
    if [[ -n "$gowner" ]] && _task_agent_channel "$gowner"; then
      # DIVE-2414: name the EVIDENCE CLASS in the nudge. This flag says a commit
      # named the ROW, and the ask names no PR to check instead — so on a row
      # carrying several items it may well be about a different one (DIVE-2382).
      # The old wording asserted "likely shipped" with no way to tell the two apart.
      ( cmd_send "$gowner" --message="🚢 ${gident} — a commit referencing this open ${gtype} gate's ROW landed on ${_HB_GATE_SHIPPED_REF} (${hit}). This ask names no pull request, so the evidence is ROW-level: if the row carries several items, the commit may be about a different one — check before you clear. Verify with \`5dive task show ${gident}\`. Auto-flag only — a merge is not a sign-off, so it stays open until you clear it." ) >/dev/null 2>&1 || true
    fi
  done < <(db "SELECT id||x'1f'||COALESCE(ident,'DIVE-'||id)||x'1f'||need_type||x'1f'||COALESCE(assignee,'')
               FROM tasks
               WHERE need_type IS NOT NULL AND need_answered_at IS NULL
                 AND shipped_flag_at IS NULL
                 AND status NOT IN ('done','cancelled');")
  return 0
}

# CNCL-12: the recurring rot-triage scan. A tier-2 gate left unanswered 48h+ gets a council
# convene that ONLY re-briefs it sharper for the human — it NEVER clears a tier-2 gate (the
# fail-closed rule lives in the pure mapper + a belt-and-suspenders check in `council rot-triage`).
# DEFAULT OFF: a live convene injects into seat sessions, so this stays gated on an explicit
# COUNCIL_ROT_TRIAGE=on opt-in AND a seeded genesis, until main's CNCL-7 live-dispatch window.
# Throttled to once/6h fleet-wide so the same backlog isn't re-convened every wake.
_HB_COUNCIL_ROT="${COUNCIL_ROT_TRIAGE:-off}"
_hb_council_rot_sweep() {
  [[ "$_HB_COUNCIL_ROT" == "on" || "$_HB_COUNCIL_ROT" == "1" ]] || return 0
  [[ -f "${STATE_DIR}/council/genesis.json" ]] || return 0   # no seeded council -> nothing to convene
  ensure_node_on_path || return 0
  # Fleet-wide throttle: skip if a rot sweep ran within the last 6h.
  local last; last="$(db "SELECT value FROM task_prefs WHERE key='council_rot_swept_at';" 2>/dev/null)"
  if [[ -n "$last" ]]; then
    local recent; recent="$(db "SELECT CASE WHEN $(sqlq "$last") > datetime('now','-6 hours') THEN 1 ELSE 0 END;" 2>/dev/null)"
    [[ "$recent" == "1" ]] && return 0
  fi
  db "INSERT INTO task_prefs (key,value) VALUES ('council_rot_swept_at', datetime('now'))
        ON CONFLICT(key) DO UPDATE SET value=datetime('now');" 2>/dev/null || true
  # cmd_council owns the convene + the never-clear guarantee; JSON output kept quiet.
  local n; n="$(JSON_MODE=1 cmd_council rot-triage --all --older-than-hours=48 2>/dev/null | jq -r '.data.count // 0' 2>/dev/null)" || n=0
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) && _hb_log "[council-rot] re-briefed ${n} stale tier-2 gate(s) (none cleared)"
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
# DIVE-2122 — READ THE ARTIFACT, NOT A PROXY FOR IT.
#
# The gap#3 alarm below asserts "nothing is self-correcting" on the strength of
# tasks.status='in_progress' == 0. That is a PROXY for "an agent is doing work", and
# it is wrong in exactly the productive case. Measured 2026-07-26 20:06, when the
# alarm fired while the fleet was working: 257 agent commands in the preceding ten
# minutes (dev 112, main 42, olivia 38, marketing 25, codex 20, community 10,
# creative 10), dev running `gh pr` seconds before the alert, 12 tasks closed in 3h,
# all 10 units active. dev's last `task start` was SEVEN AND A HALF HOURS earlier.
# Agents do substantial work without ever holding a row in in_progress: builders work
# in worktrees against a branch, a delivered maker->verifier task sits at status=todo
# assigned to the VERIFIER, and verification / wiki compiles / review / inter-agent
# exchange never touch task status at all. So in_progress==0 means "nobody used the
# task verb recently", which is not the claim the alert makes.
# This is the fifth recorded instance of the same false positive (2026-07-19, 07-21,
# 07-22 x2, 07-26); the takeaway was written down after the third and never built.
#
# WHY THIS PROBE AND NOT THE OBVIOUS ONES — both alternatives were measured and both
# would have SILENCED the detector, which is far worse than the false positive it
# fixes (a noisy alarm is visible; a dead one is not):
#   * session-transcript mtime — the heartbeat NUDGES agents during a genuine stall,
#     and a nudge appends to the transcript. Freshness would be manufactured by the
#     very condition we are trying to detect.
#   * raw command count from the sudo journal — ~90% of it is automated polling. In a
#     20-minute sample: 140 `5dive task coordinator`, 20 `task inbox`, 20 `agent
#     info`, 22 `tmux has-session`, 18 `capture-pane`, 20 codex version probes. A
#     dead fleet still emits all of it, so any threshold over raw volume reads busy
#     forever. Excluding the pollers needs a hand-maintained allowlist that nobody
#     owns and that rots toward "everything looks busy" — the DIVE-2118 shape, a rule
#     whose performance half has no owner.
# `_hb_agent_idle` is the existing, already-maintained read of the actual artifact:
# the agent session itself (native runtime state where available, pane-stability plus
# a per-runtime composer marker otherwise). Reusing it means this probe cannot drift
# away from the fleet's own notion of busy.
#
# COST is paid only when the alarm would otherwise fire (rare, and throttled to once
# per _HB_STALL_MIN_MINUTES): a pane probe samples twice _HB_IDLE_SAMPLE_SEC apart.
# It early-exits on the first ACTIVE agent, so the common false-positive path is one
# probe, not eleven.
#
# Sets _HB_ACT_{CHECKED,ACTIVE,IDLE,BLOCKED,UNKNOWN} and _HB_ACT_{ACTIVE,BLOCKED}_NAMES.
# UNKNOWN is a THIRD state and is never folded into idle: an uncapturable pane did
# not prove the agent idle, and an alert that cannot tell "measured idle" from "could
# not measure" is asserting something it never measured.
_HB_ACT_CHECKED=0; _HB_ACT_ACTIVE=0; _HB_ACT_IDLE=0; _HB_ACT_BLOCKED=0; _HB_ACT_UNKNOWN=0
_HB_ACT_ACTIVE_NAMES=""; _HB_ACT_BLOCKED_NAMES=""
_hb_fleet_activity_probe() {
  local stop_on_active="${1:-1}" reg name rc
  _HB_ACT_CHECKED=0; _HB_ACT_ACTIVE=0; _HB_ACT_IDLE=0; _HB_ACT_BLOCKED=0; _HB_ACT_UNKNOWN=0
  _HB_ACT_ACTIVE_NAMES=""; _HB_ACT_BLOCKED_NAMES=""
  reg=$(registry_read 2>/dev/null) || reg=""
  [[ -n "$reg" ]] || return 0
  for name in $(jq -r '.agents | to_entries[] | select(.value.heartbeat != null) | .key' <<<"$reg" 2>/dev/null); do
    _HB_ACT_CHECKED=$((_HB_ACT_CHECKED + 1))
    _hb_agent_idle "$name" >/dev/null 2>&1; rc=$?
    case "$rc" in
      0) _HB_ACT_IDLE=$((_HB_ACT_IDLE + 1)) ;;
      1) _HB_ACT_ACTIVE=$((_HB_ACT_ACTIVE + 1))
         _HB_ACT_ACTIVE_NAMES="${_HB_ACT_ACTIVE_NAMES:+${_HB_ACT_ACTIVE_NAMES},}${name}"
         (( stop_on_active )) && return 0 ;;
      # A BLOCKED agent (permission/usage dialog) is not idle and not working — it is
      # the actual root in two of the recorded recurrences, so it is counted and named
      # rather than silently bucketed with idle.
      3) _HB_ACT_BLOCKED=$((_HB_ACT_BLOCKED + 1))
         _HB_ACT_BLOCKED_NAMES="${_HB_ACT_BLOCKED_NAMES:+${_HB_ACT_BLOCKED_NAMES},}${name}" ;;
      *) _HB_ACT_UNKNOWN=$((_HB_ACT_UNKNOWN + 1)) ;;
    esac
  done
  return 0
}

# _hb_free_agents — the agents the BOARD can already see are free, one per line.
#
# "Free" is two facts we hold, not an inference from silence: the registry says the
# agent has heartbeat config and it is ENABLED, and the task store says it holds no
# in_progress standard row. Deterministically ordered (LC_ALL=C sort) so the
# reassignment target a stalled row gets is reproducible and gradeable rather than
# whatever jq happened to emit first.
#
# FAIL-CLOSED ON AN UNREADABLE REGISTRY, and that is the whole reason this is a
# function with an exit code instead of an inline jq. registry_read() collapses "no
# registry file", "unreadable (perms/IO)" and "genuinely empty fleet" onto
# {"agents":{}} — indistinguishable. An empty list is NOT a harmless no-op for the
# only caller: it is precisely the input that sends the escalation ladder to its
# CANCEL rung. So this uses registry_read_checked and propagates its non-zero, and
# the caller skips the tick entirely rather than closing a live row on evidence it
# never actually had.
_hb_free_agents() {
  local reg name busy
  reg=$(registry_read_checked 2>/dev/null) || return $?
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    busy=$(db "SELECT COUNT(*) FROM tasks
               WHERE kind='standard' AND status='in_progress'
                 AND assignee=$(sqlq "$name");" 2>/dev/null || echo 1)
    # A failed/garbled count reads as BUSY, never as free — the cost of wrongly
    # calling an agent busy is that this row waits one more tick; the cost of
    # wrongly calling one free is handing it work it cannot take.
    [[ "$busy" =~ ^[0-9]+$ ]] || busy=1
    (( busy == 0 )) && printf '%s\n' "$name"
  done < <(jq -r '.agents | to_entries[]
                  | select(.value.heartbeat != null and ((.value.heartbeat.enabled // false) == true))
                  | .key' <<<"$reg" 2>/dev/null | LC_ALL=C sort)
  return 0
}

_hb_stall_sweep() {
  # (a) GAP#2 — surface stale maker->verifier deliveries.
  #
  # DIVE-2196: a row BLOCKED on an unanswered human gate is excluded. 'blocked' is
  # not in ('done','cancelled'), so such a row used to pass the filter and get
  # nagged — but the wait there is on a HUMAN, not on the verifier, and the remedy
  # this ping prescribes is the harmful action: on a maker->verifier task the
  # verifier's ACK *is* the close, so "run task start then task done/task reject"
  # asks them to resolve a pending human gate by side effect. Fired live on
  # DIVE-2146, whose gate asked lodar to choose between leaving it open and closing
  # it as delivered — i.e. the nag pushed option B in a question nobody had
  # answered. The gate-live predicate matches the one inbox/show/park use
  # (need_type set AND not yet answered; status is already constrained above).
  # An ANSWERED gate does not exclude: the wait is back on the verifier.
  # (gap#3's stranded_todo below keeps its own predicate — it counts status='todo'
  # rows, and a gate-blocked row is 'blocked'; open gates are counted by open_gates,
  # where a pinged tier-2 gate is deliberately PARKED rather than stranded.)
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
                 AND NOT (need_type IS NOT NULL AND need_answered_at IS NULL)
                 AND NOT (${_TASKS_TFV_SQL})
                 AND handoff_delivered_at <= datetime('now','-${_HB_VERIFY_STALE_MIN} minutes');")

  # (a2) DIVE-2693 — a materialized RECURRING instance that was never STARTED.
  #
  # WHY THIS IS NOT COVERED BY (a) ABOVE, which is the whole reason it needed its
  # own predicate: gap#2 keys on handoff_delivered_at, and a plain never-started
  # todo has none — it was never delivered to anyone, it was simply never picked
  # up. The two stall shapes are disjoint and a query for one cannot see the other.
  #
  # WHY IT MATTERS MORE THAN ONE LATE TASK: the materializer is skip-if-open, so
  # while an instance sits open the template's NEXT slot is suppressed. One
  # unworked instance therefore does not delay a beat, it DELETES every subsequent
  # occurrence of it for as long as it sits. Measured twice on DIVE-1237: DIVE-2026
  # ate 07-27..07-28, DIVE-2403 ate 07-31..08-04 (five slots, nothing shipped).
  #
  # WHY IT STAYED INVISIBLE BOTH TIMES: the downstream producer's own precondition
  # check absorbs the stall correctly — it declines to activate, so nothing errors
  # and the only symptom is a green-looking no-op a day or two later. A fault whose
  # recovery is clean is a fault nobody reports.
  #
  # NOT KEYED TO ANY IDENT. DIVE-1237 is only where we noticed it; the defect is a
  # property of skip-if-open dedup on ANY template, and DIVE-1155/DIVE-1236 sit on
  # the same mechanism and would fail identically and just as quietly.
  local rrow rid rident rasg rcreated rtmpl rpol rhours rsupp rsupp_main
  while IFS= read -r rrow; do
    [[ -n "$rrow" ]] || continue
    IFS=$'\x1f' read -r rid rident rasg rcreated rtmpl rpol <<<"$rrow"
    [[ -n "$rid" ]] || continue
    rhours=$(( ($(date -u +%s) - $(date -u -d "$rcreated" +%s 2>/dev/null || date -u +%s)) / 3600 ))
    # DIVE-2272: this notice's whole urgency claim — "the next slot is suppressed,
    # so the beat is not late, it is NOT HAPPENING" — is only true under
    # skip-if-open. On an on_overlap='spawn' template later slots keep firing, so
    # asserting suppression there would be an instrument reporting a cause it did
    # not observe (the DIVE-2273 defect class, one layer out). The row is still
    # worth surfacing — a never-started instance is a real stall, and under spawn
    # it also counts toward the bound that will eventually suppress the beat —
    # but it must be described as what it is.
    if [[ "$rpol" == "spawn" ]]; then
      rsupp="Later slots are still firing (${rtmpl} is on-overlap=spawn), so the beat is LATE, not stopped — but this row counts toward the overlap bound, and once the bound is reached the beat suppresses like any other."
      rsupp_main="template ${rtmpl} is on-overlap=spawn so the beat is still firing, but this row counts toward the bound that suppresses it (DIVE-2272)"
    else
      rsupp="While it sits open the schedule's next slot is SUPPRESSED (skip-if-open), so the beat is not late, it is not happening."
      rsupp_main="every slot since is suppressed by skip-if-open (DIVE-2693)"
    fi
    if [[ -n "$rasg" ]]; then
      ( cmd_send "$rasg" --from="task-engine" \
          --message="⏳ ${rident} is a RECURRING instance you have never started — ${rhours}h old. ${rsupp} Work it or close it: \`5dive task start ${rident}\`, or \`5dive task cancel ${rident} --result=...\` to let the schedule re-fire." ) >/dev/null 2>&1 || true
    fi
    # DIVE-2853: NAME whether the addressee could even act, instead of leaving it to
    # be inferred from another day of silence. An assignee already holding an
    # in_progress row is the shape that produced the 28h non-response on DIVE-2694:
    # under a single-task goal, taking this row would break an explicit instruction,
    # so the notice is misaddressed at SEND time and no re-ping can fix it. Reported
    # here (not acted on) because the remedy is the ladder's second rung below —
    # holding a row's original assignee for one window is deliberate, and 'busy now'
    # is not yet evidence of a stall that needs hands changed.
    local rbusy
    rbusy=$(db "SELECT COALESCE(ident,'DIVE-'||id) FROM tasks
                WHERE kind='standard' AND status='in_progress'
                  AND assignee=$(sqlq "${rasg:-}") ORDER BY id LIMIT 1;" 2>/dev/null || echo "")
    ( cmd_send "main" --from="task-engine" \
        --message="⏳ Recurring beat stalled: ${rident} (from template ${rtmpl}) has sat todo and never-started for ${rhours}h, assignee '${rasg:-unassigned}'${rbusy:+ — who is OCCUPIED on ${rbusy}, so this notice may be undeliverable-in-effect (a goal-fenced assignee cannot take a second row)} — ${rsupp_main}. If it is still unstarted in ${_HB_RECURRING_ESCALATE_HOURS}h the ladder reassigns or cancels it (DIVE-2853)." ) >/dev/null 2>&1 || true
    db "UPDATE tasks SET recurring_stall_pinged_at=datetime('now') WHERE id=${rid};"
    _hb_log "[recurring-stall] ${rident} never-started ${rhours}h (template ${rtmpl}) -> surfaced"
  done < <(db "SELECT t.id||x'1f'||COALESCE(t.ident,'DIVE-'||t.id)||x'1f'||COALESCE(t.assignee,'')||x'1f'||t.created_at||x'1f'||COALESCE(p.ident,'DIVE-'||t.from_template_id)||x'1f'||COALESCE(p.on_overlap,'skip')
               FROM tasks t LEFT JOIN tasks p ON p.id=t.from_template_id
               WHERE t.kind='standard' AND t.from_template_id IS NOT NULL
                 AND t.status='todo' AND t.started_at IS NULL
                 AND t.recurring_stall_pinged_at IS NULL
                 AND NOT (t.need_type IS NOT NULL AND t.need_answered_at IS NULL)
                 AND t.parked_at IS NULL
                 AND t.created_at <= datetime('now','-${_HB_RECURRING_STALL_HOURS} hours');")

  # (a3) DIVE-2853 — the SECOND RUNG, on a row (a2) already surfaced and that is
  # still todo-and-never-started a full window later.
  #
  # WHY A LOUDER OR REPEATED NOTICE CANNOT BE THIS RUNG. (a2)'s single notice is
  # addressed to the row's assignee — i.e. to the one party whose not picking the
  # row up IS the observed fault. Measured on DIVE-2694: flagged on time
  # (recurring_stall_pinged_at 2026-08-05 04:00:08, exactly once, correctly), then
  # sat unstarted another 28h. The cause was NOT a missed message. dev had the
  # message, replied to it, and was mid-delivery on DIVE-2801 under a single-task
  # goal — STRUCTURALLY BARRED from starting a second row. A fence outlives every
  # re-ping, so volume at that same addressee is a guaranteed no-op and the row
  # stays dark for as long as the other goal runs.
  #
  # SO THIS RUNG CHANGES HANDS INSTEAD OF RAISING VOLUME:
  #   1. reassign to an agent the board can see is FREE (_hb_free_agents), the
  #      template's creator first when they are free — that is who owns the beat's
  #      inputs and who unstuck it by hand both previous times;
  #   2. if nobody is free, CANCEL with a written reason so the template re-fires.
  #
  # WHY CANCEL IS THE FALLBACK AND NOT A 'blocked' PARK, which is the posture used
  # for a reaped in_progress row a few hundred lines up: skip-if-open counts EVERY
  # instance with status NOT IN ('done','cancelled'), so 'blocked' would keep
  # suppressing later slots — it renames the outage instead of ending it. Cancel is
  # also the documented manual unstick (main did exactly this on the DIVE-2237 sweep
  # and on DIVE-2403), and it never runs with an empty result: the reason is written
  # into the row, and the old assignee is told in the same breath, so a cancel here
  # is never indistinguishable from the beat having never fired.
  #
  # ONCE PER INSTANCE (recurring_stall_escalated_at), so a reassignment cannot
  # thrash a row around a fleet — and if the NEW hands do not start it either, the
  # next window's rung is the cancel, which is what actually restores the beat.
  local erow eid eident easg etmpl etcreator ehours ever ecand etarget epol esupp
  local efree="" efree_read=0 efree_ok=0 ecancel_reason emsg
  while IFS= read -r erow; do
    [[ -n "$erow" ]] || continue
    IFS=$'\x1f' read -r eid eident easg etmpl etcreator ehours ever epol <<<"$erow"
    # DIVE-2272: every message and the cancel REASON below justify themselves with
    # "skip-if-open suppresses the later slots". On an on_overlap='spawn' template
    # that premise is false — later slots keep firing — so the same sentence would
    # be a fabricated cause. The ladder's ACTION is deliberately unchanged for both
    # policies (a never-started row is a stall either way, and under spawn it still
    # consumes the bound), but what the record CLAIMS about the beat must match what
    # the scheduler actually does.
    if [[ "$epol" == "spawn" ]]; then
      esupp="the beat's later slots are still firing (on-overlap=spawn), but this row consumes one of the template's bounded overlap slots"
    else
      esupp="the beat's later slots are SUPPRESSED while it sits open (skip-if-open)"
    fi
    [[ -n "$eid" ]] || continue
    if (( efree_read == 0 )); then
      efree_read=1
      if efree=$(_hb_free_agents); then
        efree_ok=1
      else
        _hb_log "[recurring-escalate] registry unreadable — escalation SKIPPED this tick; no row was reassigned or cancelled on an unread fleet"
      fi
    fi
    (( efree_ok )) || break

    etarget=""
    while IFS= read -r ecand; do
      [[ -n "$ecand" ]] || continue
      # The current assignee is not a target: handing the row back to the addressee
      # that already had a full window with it is the no-op this rung exists to stop.
      [[ -n "$easg" && "$ecand" == "$easg" ]] && continue
      # DIVE-3097: nor is this row's own verifier. This ladder is a raw
      # reassignment with no maker/grader check of its own — the row is still
      # todo/never-started (no maker_agent, no delivery), so landing the
      # verifier here as the new assignee would manufacture the exact
      # assignee==verifier, no-handoff-ever-recorded shape DIVE-2899 named,
      # except this time self-inflicted by the heartbeat rather than a human
      # flag combo. Same "don't create it fresh" scope as the rest of DIVE-3097
      # — a row where this already happened before the fix is not touched here.
      [[ -n "$ever" && "$ecand" == "$ever" ]] && continue
      if [[ -n "$etcreator" && "$ecand" == "$etcreator" ]]; then etarget="$ecand"; break; fi
      [[ -z "$etarget" ]] && etarget="$ecand"
    done <<<"$efree"

    if [[ -n "$etarget" ]]; then
      db "UPDATE tasks SET assignee=$(sqlq "$etarget"), recurring_stall_escalated_at=datetime('now'),
                           updated_at=datetime('now')
          WHERE id=${eid} AND status='todo' AND started_at IS NULL;" 2>/dev/null || true
      ( cmd_send "$etarget" --from="task-engine" \
          --message="🔁 ${eident} (recurring beat from template ${etmpl}) has been REASSIGNED to you: it sat never-started for ${ehours}h with '${easg:-unassigned}', who was surfaced once and could not take it. ${esupp^}. \`5dive task start ${eident}\`, or \`5dive task cancel ${eident} --result=...\` if it is genuinely not workable, which lets the schedule re-fire." ) >/dev/null 2>&1 || true
      if [[ -n "$easg" ]]; then
        ( cmd_send "$easg" --from="task-engine" \
            --message="🔁 ${eident} has been moved OFF you to '${etarget}' — it was never started ${ehours}h after being flagged, and ${esupp}. Nothing for you to do; if you were about to start it, say so to ${etarget} rather than both starting it." ) >/dev/null 2>&1 || true
      fi
      ( cmd_send "main" --from="task-engine" \
          --message="🔁 Recurring-stall ESCALATED: ${eident} (template ${etmpl}) reassigned '${easg:-unassigned}' -> '${etarget}' after ${ehours}h unstarted past its flag — a re-ping to the original assignee cannot clear a goal-fenced one, so the ladder changes hands (DIVE-2853)." ) >/dev/null 2>&1 || true
      ledger_emit "task.recurring_stall_escalated" ident="$eident" task_id="$eid" \
        actor="task-engine" authority="heartbeat" \
        detail="reassigned ${easg:-unassigned}->${etarget} after ${ehours}h never-started (template ${etmpl})" || true
      _hb_log "[recurring-escalate] ${eident} ${ehours}h unstarted -> reassigned ${easg:-unassigned} -> ${etarget}"
    else
      ecancel_reason="auto-cancelled by the recurring-stall ladder (DIVE-2853): materialized from template ${etmpl}, never started, surfaced once to '${easg:-unassigned}' and still unstarted ${ehours}h later, and no free agent was available to take it. Cancelled rather than left open BECAUSE ${esupp} — the schedule re-fires on its next slot. Not a judgement that the work is unwanted."
      db "UPDATE tasks SET status='cancelled', done_at=datetime('now'), updated_at=datetime('now'),
                           result=$(sqlq "$ecancel_reason"), recurring_stall_escalated_at=datetime('now')
          WHERE id=${eid} AND status='todo' AND started_at IS NULL;" 2>/dev/null || true
      emsg="🗑 ${eident} (recurring beat from template ${etmpl}) was AUTO-CANCELLED after sitting never-started ${ehours}h past its stall flag, with no free agent to hand it to. The reason is written into the row's result; the template re-fires on its next slot (${esupp})."
      if [[ -n "$easg" ]]; then
        ( cmd_send "$easg" --from="task-engine" --message="$emsg If you still want this instance, the next materialization is yours to start on time — or reply to say the row should not be assigned to you." ) >/dev/null 2>&1 || true
      fi
      ( cmd_send "main" --from="task-engine" --message="$emsg No free agent existed at escalation time, so reassignment had nowhere to go (DIVE-2853)." ) >/dev/null 2>&1 || true
      ledger_emit "task.recurring_stall_escalated" ident="$eident" task_id="$eid" \
        actor="task-engine" authority="heartbeat" \
        detail="auto-cancelled after ${ehours}h never-started, no free agent (template ${etmpl})" || true
      _hb_log "[recurring-escalate] ${eident} ${ehours}h unstarted, no free agent -> auto-cancelled so template ${etmpl} re-fires"
    fi
  done < <(db "SELECT t.id||x'1f'||COALESCE(t.ident,'DIVE-'||t.id)||x'1f'||COALESCE(t.assignee,'')||x'1f'||COALESCE(p.ident,'DIVE-'||t.from_template_id)||x'1f'||COALESCE(p.created_by,'')||x'1f'||CAST((julianday('now')-julianday(t.created_at))*24 AS INTEGER)||x'1f'||COALESCE(t.verifier,'')||x'1f'||COALESCE(p.on_overlap,'skip')
               FROM tasks t LEFT JOIN tasks p ON p.id=t.from_template_id
               WHERE t.kind='standard' AND t.from_template_id IS NOT NULL
                 AND t.status='todo' AND t.started_at IS NULL
                 AND t.recurring_stall_pinged_at IS NOT NULL
                 AND t.recurring_stall_escalated_at IS NULL
                 AND NOT (t.need_type IS NOT NULL AND t.need_answered_at IS NULL)
                 AND t.parked_at IS NULL
                 AND t.recurring_stall_pinged_at <= datetime('now','-${_HB_RECURRING_ESCALATE_HOURS} hours');")

  # (a4) DIVE-2207 — gap#2's SECOND predicate: a delivery whose blocking gate has
  # since been ANSWERED.
  #
  # WHY (a) ABOVE CANNOT SEE THIS, which is the whole reason it needs its own
  # predicate rather than a widened one. (a) carries `handoff_ack_at IS NULL`, and
  # DIVE-2196 correctly excludes gate-blocked rows from it. But the ack has more
  # than one writer: any verifier who ran `task start` and THEN hit the blocker has
  # already stamped it. So the moment the human answers and the wait comes back to
  # the verifier, (a) is permanently blind to that row — not throttled, structurally
  # excluded. Measured on the live board 2026-07-28: the clean population (gate
  # answered at or after handoff_delivered_at) is 20 rows; 17 were graded inside the
  # hour, 2 took 1-6h, one took over 24h. It bites rarely and silently, which is the
  # case for a rail and not against one.
  #
  # WHY NOT CLEAR/REFRESH handoff_ack_at INSTEAD (shape (a) of DIVE-2206, rejected):
  # un-stamping erases a record of something that DID happen — the verifier reviewed
  # and escalated. DIVE-2196 existed because the record lied by omission; clearing
  # makes it lie in the other direction, and on a row whose ack was earned by a
  # genuine `task start` it re-arms (a)'s "still unacknowledged" message against a
  # verifier who demonstrably acknowledged. That false nudge IS the DIVE-2196 defect.
  #
  # THE MESSAGE IS DIFFERENT ON PURPOSE. (a) says "still unacknowledged", which is
  # false here — the verifier acted. Per
  # community/wiki/on-a-maker-verifier-task-the-ack-is-the-close.md a nudge that
  # names a verb authors an instruction, so this one may only exist POST-answer:
  # while the gate is open, "close it" is a disguised policy answer on a question
  # the human has not decided. After the answer it is safe, and it is the point.
  #
  # THROTTLE: its own column. handoff_stale_pinged_at is already burned on 30 rows
  # fleet-wide including the live specimen this was written for (DIVE-2146) —
  # reusing it ships the fix dead on arrival for exactly its target population.
  #
  # `parked_at IS NULL` is one clause BEYOND the DIVE-2207 spec (olivia's constraint
  # 2), added deliberately and mirroring the (a2) rail directly above: a parked row
  # was set aside on purpose and nudging it is noise. Measured when added: 22 parked
  # rows live fleet-wide, 0 of them inside this window, so it changes no count today
  # and closes the exposure before it has a victim.
  local grow gid gident gfier ganswered gmins
  while IFS= read -r grow; do
    [[ -n "$grow" ]] || continue
    IFS=$'\x1f' read -r gid gident gfier ganswered <<<"$grow"
    [[ -n "$gid" && -n "$gfier" ]] || continue
    gmins=$(( ($(date -u +%s) - $(date -u -d "$ganswered" +%s 2>/dev/null || date -u +%s)) / 60 ))
    ( cmd_send "$gfier" --from="task-engine" \
        --message="✅ ${gident}: the human gate that was blocking it was ANSWERED ${gmins}m ago, so grading is genuinely yours again — nothing is waiting on a person. Pick it back up: \`5dive task start ${gident}\` then \`task done\`/\`task reject\` (DIVE-2207)." ) >/dev/null 2>&1 || true
    ( cmd_send "main" --from="task-engine" \
        --message="✅ Answered-gate delivery: ${gident} is back on verifier '${gfier}' — its gate was answered ${gmins}m ago and the row had left gap#2's view, so it is surfaced here rather than sitting invisible (DIVE-2207)." ) >/dev/null 2>&1 || true
    db "UPDATE tasks SET gate_answered_nudged_at=datetime('now') WHERE id=${gid};"
    _hb_log "[stall-sweep] ${gident} gate answered ${gmins}m ago, back on ${gfier} -> surfaced"
  done < <(db "SELECT id||x'1f'||COALESCE(ident,'DIVE-'||id)||x'1f'||verifier||x'1f'||need_answered_at
               FROM tasks
               WHERE verifier IS NOT NULL AND maker_agent IS NOT NULL
                 AND assignee=verifier AND status NOT IN ('done','cancelled')
                 AND handoff_delivered_at IS NOT NULL
                 -- `need_answered_at IS NOT NULL` is SUBSUMED by the comparison at
                 -- the bottom and is kept only to state the intent (post-answer
                 -- only) where a reader looks first. Proven, not assumed: in SQLite
                 -- `NULL <= datetime(...)` is NULL, not true, so an open gate is
                 -- already excluded by the window clause. Deleting this line reds
                 -- NOTHING — it is the one clause here that no mutation can grade,
                 -- so do not read arm A8 as evidence that it works. A8 grades the
                 -- BEHAVIOUR (an open gate is never nudged); the window clause is
                 -- what guards it.
                 AND need_type IS NOT NULL AND need_answered_at IS NOT NULL
                 AND gate_answered_nudged_at IS NULL
                 AND parked_at IS NULL
                 AND need_answered_at <= datetime('now','-${_HB_VERIFY_STALE_MIN} minutes');")

  # (b) GAP#3 core — fleet-idle-while-actionable-work-is-open, persisting.
  local in_prog running_loops stranded_todo open_gates parked_gates total_stranded
  in_prog=$(db "SELECT COUNT(*) FROM tasks WHERE status='in_progress' AND kind='standard';" 2>/dev/null || echo 0)
  running_loops=$(db "SELECT COUNT(*) FROM loop_runs WHERE status='running';" 2>/dev/null || echo 0)
  [[ "$in_prog" =~ ^[0-9]+$ ]] || in_prog=0
  [[ "$running_loops" =~ ^[0-9]+$ ]] || running_loops=0

  total_stranded=0
  if (( in_prog == 0 && running_loops == 0 )); then
    # DIVE-2122: a DELIVERED maker->verifier row is status='todo' assigned to the
    # VERIFIER. It is neither unclaimed nor stranded — it is awaiting a grade, and
    # gap#2 above already surfaces it on its own clock. Counting it here inflated the
    # stranded number with work that was moving (three such rows at the 2026-07-26
    # alert). Same predicate as the gap#2 query, so the two cannot disagree.
    # DIVE-2207 — THE LABELS BELOW ARE LOAD-BEARING; both were renamed after a
    # reader acted on the wrong one. A count whose NAME is broader than its
    # PREDICATE cannot be read correctly by anyone who has not read the query, and
    # it fails in the expensive direction: it under-reports, so it reads as "nothing
    # is pending" exactly when something is. Two instances were live in one message:
    #   * open_gates rendered as "open gate(s)" — a SUPERSET label (open ⊃
    #     fleet-actionable), so it over-promised. main read "0 open gate(s)" against
    #     12 genuinely open gates and reported the query as broken; the query was
    #     right. Now "fleet-actionable gate(s)".
    #   * stranded_todo rendered as "unclaimed todo" — worse, a DISJOINT label. The
    #     predicate REQUIRES assignee IS NOT NULL, and todo/standard rows with no
    #     assignee measured ZERO on the live board, so the word pointed at the empty
    #     set and always would: no reader chasing genuinely unowned work could ever
    #     find it here. Now "assigned-but-unstarted". (It also excludes 21 recurring
    #     rows by kind and 2 awaiting-grade rows — both deliberate, DIVE-2693 and
    #     DIVE-2122 own those shapes.)
    # The rule, if you add an aggregate here: name it after its predicate, not after
    # the concept the predicate approximates.
    stranded_todo=$(db "SELECT COUNT(*) FROM tasks
                        WHERE status='todo' AND kind='standard'
                          AND assignee IS NOT NULL AND assignee != ''
                          AND NOT (verifier IS NOT NULL AND maker_agent IS NOT NULL
                                   AND assignee=verifier
                                   AND handoff_delivered_at IS NOT NULL
                                   AND handoff_ack_at IS NULL);" 2>/dev/null || echo 0)
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
    # DIVE-2207: the PARKED count — context, never alarm input. Deliberately NOT
    # folded into total_stranded below: these are the rows open_gates excludes on
    # purpose, and adding them back is the alert-fatigue regression the comment
    # above exists to prevent. It is rendered so a reader can tell "the fleet has
    # stopped" from "the fleet is waiting on a human", which is the distinction the
    # alert could not previously express in either direction.
    parked_gates=$(db "SELECT COUNT(*) FROM tasks
                       WHERE need_type IS NOT NULL AND need_answered_at IS NULL
                         AND status NOT IN ('done','cancelled')
                         AND COALESCE(tier,2) >= 2
                         AND (need_asked_at IS NOT NULL OR gate_pinged_at IS NOT NULL);" 2>/dev/null || echo 0)
    [[ "$stranded_todo" =~ ^[0-9]+$ ]] || stranded_todo=0
    [[ "$open_gates"    =~ ^[0-9]+$ ]] || open_gates=0
    [[ "$parked_gates"  =~ ^[0-9]+$ ]] || parked_gates=0
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
        # DIVE-2122: before asserting "nothing is self-correcting", MEASURE it.
        _hb_fleet_activity_probe 1
        if (( _HB_ACT_ACTIVE > 0 )); then
          # The fleet is working; the proxy was wrong, not the fleet. Reset the clock
          # too — "idle Nm+" is a claim about elapsed idleness, and we just observed
          # the opposite, so carrying N forward would report a number we disproved.
          db "DELETE FROM task_prefs WHERE key='stall_first_seen_at';"
          _hb_log "[stall-sweep] SUPPRESSED: ${total_stranded} stranded item(s) and 0 in_progress, but agent '${_HB_ACT_ACTIVE_NAMES}' is actively working — in_progress is a proxy, the session is the artifact (DIVE-2122)"
        else
          # Nothing active. Re-probe WITHOUT the early exit so the alert can say what
          # it actually checked; an alarm that will not name its measurement cannot be
          # told apart from one that measured nothing.
          _hb_fleet_activity_probe 0
          local _act_detail="probed ${_HB_ACT_CHECKED} agent session(s): ${_HB_ACT_IDLE} idle"
          (( _HB_ACT_BLOCKED > 0 )) && _act_detail="${_act_detail}, ${_HB_ACT_BLOCKED} BLOCKED (${_HB_ACT_BLOCKED_NAMES}) — a frozen permission/usage dialog is the usual root and does NOT self-clear"
          (( _HB_ACT_UNKNOWN > 0 )) && _act_detail="${_act_detail}, ${_HB_ACT_UNKNOWN} UNMEASURABLE (pane uncapturable) — this alert did not prove those idle"
          (( _HB_ACT_CHECKED == 0 )) && _act_detail="session probe UNAVAILABLE (no agents readable) — idleness is UNVERIFIED, not measured"
          # DIVE-2244, second (separable) defect in the SAME alert. The probe arm
          # is honest about what it could not read — "this alert did not prove
          # those idle" — and that honesty is right and is kept. But the sentence
          # it sat inside was still a flat assertion: "🛑 fleet-stall", a
          # fleet-wide claim, while the same message admitted it could not
          # measure a third of the population. An alarm may not assert what it
          # just said it did not measure.
          #
          # So the HEADLINE now tracks conclusiveness of the probe. Deliberately
          # a language change, not a firing change: requiring a conclusive probe
          # to fire at all would fail OPEN — an uncapturable-pane outage is
          # exactly when the fleet is most likely to be genuinely wedged, and
          # suppressing there loses the alarm when it matters most. Downgrading
          # the claim to a question keeps the signal and drops the overreach.
          # (This is the ticket's own second option; cf. NOT-REACHED-is-a-third-
          # state, v0.16 "Fails loud".)
          #
          # The in_progress clause is now a real reading, not the permanent
          # constant it was before the claim above landed — so it is worth
          # printing. Pre-DIVE-2244 "0 in_progress" was true on every tick
          # forever and told the reader nothing.
          local _hdr _tail
          if (( _HB_ACT_CHECKED > 0 && _HB_ACT_UNKNOWN == 0 )); then
            _hdr="🛑 fleet-stall"; _tail="Check \`5dive task ls\` / \`5dive task inbox\`"
          else
            _hdr="❓ possible fleet-stall (UNPROVEN)"
            _tail="The session probe could not measure every agent, so this is a QUESTION, not a finding — is the fleet actually stalled? Check \`5dive task ls\` / \`5dive task inbox\`"
          fi
          ( cmd_send "main" --from="task-engine" \
              --message="${_hdr}: ${total_stranded} stranded actionable item(s) (${stranded_todo} assigned-but-unstarted, ${open_gates} fleet-actionable gate(s)) idle $((since_secs / 60))m+ with 0 in_progress and 0 running loops, ${parked_gates} parked on the human (context, not counted) — and ${_act_detail}. ${_tail} (DIVE-1416 gap#3, session probe DIVE-2122, claim/probe honesty DIVE-2244, labels DIVE-2207)." ) >/dev/null 2>&1 || true
          db "INSERT INTO task_prefs (key,value) VALUES ('stall_alerted_at', datetime('now'))
              ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now');"
          _hb_log "[stall-sweep] fleet-idle $((since_secs / 60))m with ${total_stranded} stranded item(s), ${_act_detail} -> sent '${_hdr}' to main"
        fi
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
                 AND (tier IS NULL OR tier=2 OR (tier=1 AND recommend IS NULL)
                      OR (tier=1 AND need_type IN ${_GATE_HUMAN_CLASS_SQL}))
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
    # DIVE-2304: `2>/dev/null || echo 0` turned every failed read into "0 tokens
    # spent", which is indistinguishable from an idle loop — so the sweep, the
    # ONLY ceiling enforcement a fire-and-forget loop has, silently passed every
    # breached loop while its recompute was broken. A read that did not happen
    # is NOT-REACHED: say so in the log (the producer's stderr is deliberately
    # not swallowed here either) and verify nothing this tick. tokens_spent is
    # left at its last good value rather than clobbered to 0. Same shape as the
    # DIVE-2273 materializer guard above: an instrument must not report a cause
    # it did not observe.
    spent=$(_loop_refresh_spend "$lid") || {
      _hb_log "[loop-ceiling] ${lid} spend NOT-REACHED — ceiling NOT verified this tick (last good total left intact)"
      continue
    }
    [[ "$spent" =~ ^[0-9]+$ ]] || {
      _hb_log "[loop-ceiling] ${lid} spend NOT-REACHED (non-numeric '${spent}') — ceiling NOT verified this tick"
      continue
    }
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
      # DIVE-2119: this auto-park retires gates on a whole SET of child tasks, so
      # it runs the same archive-then-clear as `task park` — scoped to exactly the
      # rows the park will touch, in one transaction. A fix scoped to the gate
      # verbs alone would have left this path producing orphaned provenance.
      local _park_pred="id IN (${in_list}) AND status IN ('todo','in_progress') AND parked_at IS NULL"
      db "BEGIN IMMEDIATE;
          $(_gate_archive_and_clear_sql loop-ceiling "$_park_pred")
          UPDATE tasks
            SET status='blocked', parked_at=datetime('now'),
                park_reason=$(sqlq "loop ${lid} hit its token ceiling (~${spent}/${ceil} tok) — halted by heartbeat before finishing"),
                need_type=NULL, ask=NULL, need_options=NULL, recommend=NULL
          WHERE ${_park_pred};
          COMMIT;"
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

# ── DIVE-3343: the per-TASK token budget is NOT enforced, and cannot be ───────
#
# `_hb_task_budget_sweep` lived here from DIVE-2794 to DIVE-3343 and is gone.
# Its enforcement is removed, not relocated, not softened. This block is the
# decision record, because the field it read (`task_budget`) is still stored,
# validated and displayed, and the next reader WILL be tempted to wire a
# consequence back to it.
#
# WHY IT IS GONE, and it is not "the number was badly chosen". The number could
# not be MEASURED. `_spend_scan_task_ids` keys its window by ASSIGNEE and sums
# every transcript under that agent's home inside [started_at, done_at or now].
# Nothing in the scan filters by task, because THERE IS NO PER-TASK TOKEN SIGNAL
# IN A TRANSCRIPT TO FILTER ON. So the charge was "everything this agent spent
# on anything while the row happened to be open":
#
#   * it grew with the row's WALL-CLOCK AGE and was independent of any work done
#     on it — an idle row parked for existing;
#   * the sweep was called once per task id, so two rows open on one agent were
#     EACH billed that agent's full spend. The double-billing was structural.
#
# DIVE-3341 removed the built-in 5M default, which removed the POPULATION the
# bad measurement was applied to (an unbudgeted row is never evaluated). It did
# not fix the arithmetic, and a row with an EXPLICIT budget was still graded by
# it. This row finishes that: no row is graded by it, because the grade was
# never about the row.
#
# WHAT WAS REJECTED, written down because it is the attractive wrong answer:
# splitting an agent's spend across its open rows. That INVENTS attribution
# rather than measuring it, and an invented number with a park wired to it is
# the same failure wearing a better disguise. Renaming the guard to what it
# actually measured (per-agent spend since the row opened) was also rejected:
# the honest name does not make the consequence proportionate — that figure
# still cannot justify halting a row's live work.
#
# WHAT IS LOST, stated plainly rather than left for a future incident to find:
# the two rows that motivated DIVE-2794 (DIVE-2814, 27% of one fleet day;
# DIVE-3045, 19.1M in 24h on a LOW row blocked on a credential) are once again
# seen by NO hard control. The per-AGENT cost guard (rolling 24h, whole seat)
# and the per-LOOP ceiling (loop-scoped) both still hold and both still measure
# something real, but neither is row-scoped. Restoring a row-scoped control
# requires emitting a real per-task token signal FIRST and reinstating a budget
# on top of it — a project on its own merits, not a bugfix.
#
# WHAT STAYS, and why it is not dead weight: `--task-budget=`, `task set-budget`
# and `task_budget_default` still accept and store a value, and both surfaces
# now SAY that it is advisory. Removing the flags would break callers' scripts
# for no safety gain; leaving them silent would let an operator believe they had
# a guard they do not have.
#
# `_spend_scan_task_ids` (src/cmd_loop.sh) is NOT removed — the per-LOOP ceiling
# still uses it, and there the claim is different: a loop's child tasks are the
# work that loop dispatched, inside that loop's own window. That is a weaker
# claim than per-task attribution, not the same one.
#
# tests/task_budget_enforce_unit.sh is the guard on this decision: it asserts
# the sweep is absent, that an explicit budget is never even SCANNED, and that
# two rows on one agent are not double-billed — each with a control that RUNS
# the removed comparison, so restoring enforcement goes red instead of quietly
# re-arming every box.

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
  local type="$1" mtime="$2" now="$3" allowfrom="$4" thresh="$5" supposed="${6:-1}" uptime="${7:-}"
  [[ "$type" == "claude" ]] || return 0            # non-poller runtime — skip
  [[ "${allowfrom:-0}" -ge 1 ]] || return 0        # unpaired — no human to deafen
  # An operator-stopped agent (desiredState=stopped) or a unit that isn't active
  # has a stale beacon BY DEFINITION — that's not a dead transport. A
  # dead-but-desired-running unit is the supervisor's stuck class (it alarms
  # there), not ours; alarming here too would just fuel alarm-blindness. Caller
  # passes supposed=0 for either condition.
  [[ "${supposed}" == "1" ]] || return 0
  # DIVE-2384 restart grace. thresh carries the author's intent ("rides a
  # restart") but a restart could never reach it: the plugin's shutdown() UNLINKS
  # bot.heartbeat (telegram-pi/server.ts, telegram-codex/server.ts) and systemd
  # still reports the unit ACTIVE across the bounce, so a tick landing in the
  # unlink->first-bump gap fell into the mtime==0 branch below and returned
  # BEFORE thresh was ever read. Beacon age cannot measure a beacon that does not
  # exist — so grace on how long the UNIT has been active instead. Inside thresh
  # seconds of ActiveEnterTimestamp the poller has not had a fair chance to bump,
  # whether the beacon is absent (restart) or stale (rough kill left the file).
  # A genuinely dead poller keeps its unit active well past thresh and still
  # alarms, just one grace window later.
  #
  # uptime unresolvable (empty / non-numeric / clock skew) is NOT graced: the
  # caller passes "" and we fall through to alarm. A broken probe degrades to
  # the pre-fix behaviour and can never silently delete detection — the failure
  # this canary guards (a deaf channel = gates unclearable from the phone) is
  # real, so the safe default is a false alarm, not a missed death.
  if [[ "$uptime" =~ ^[0-9]+$ ]] && (( uptime <= thresh )); then
    return 0
  fi
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
  local name type allowfrom beacon mtime verdict uptime
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
    # DIVE-2384: seconds since the unit last entered ACTIVE, for the verdict's
    # restart grace. Left EMPTY when unresolvable (no such unit, systemd
    # unreachable, unparseable stamp, or a stamp in the future) — the verdict
    # reads empty as "not in grace" and alarms, so a broken probe never mutes a
    # real death.
    local aet aet_epoch
    uptime=""
    if [[ "$type" == "claude" ]] && (( supposed )); then
      aet=$(systemctl show -p ActiveEnterTimestamp --value "5dive-agent@${name}.service" 2>/dev/null)
      if [[ -n "$aet" ]] && aet_epoch=$(date -d "$aet" +%s 2>/dev/null) \
         && [[ "$aet_epoch" =~ ^[0-9]+$ ]] && (( aet_epoch <= now )); then
        uptime=$(( now - aet_epoch ))
      fi
    fi
    verdict=$(_hb_poller_verdict "$type" "$mtime" "$now" "$allowfrom" "$thresh" "$supposed" "$uptime")
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
    # The remedy must NOT say "restart the agent(s)" (DIVE-2384): a restart is the
    # action that CREATES this condition — shutdown() unlinks the beacon — so
    # anyone who believed the alarm and followed it re-armed it within seconds and
    # wiped every agent's running context on each pass. Confirm first, restart the
    # ONE agent only if the poller process is genuinely gone. DIVE-818 / DIVE-1434
    # are provenance refs from code comments, NOT board rows — say so, or the
    # reader looks them up and hits "no such task".
    ( cmd_send "$coord" --message="🔴 Telegram poller DEAD on: ${dead[*]}. Gate-ping tap buttons still SEND but the human's TAP won't land (getUpdates slot not held) — those gates can't be cleared from the phone. CONFIRM BEFORE ACTING — do NOT blanket-restart: a restart deletes the beacon and re-arms this alarm. Check the named agent's channel dir: is bot.pid's process alive, and is bot.heartbeat's mtime advancing? Only if the poller is genuinely gone, restart THAT ONE agent (systemctl restart 5dive-agent@<name>.service). (Canary provenance — code refs, not board rows: DIVE-1434 canary, DIVE-818 single-getUpdates-slot incident, DIVE-2384 restart grace. Re-pings hourly until healthy.)" ) >/dev/null 2>&1 || true
  fi
  return 0
}

# DIVE-1737: async self-heal materialize sweep. An objective planner loop that
# times out past OBJ_PLANNER_WAIT_DEFAULT records an 'awaiting_planner' cycle
# stamped with the backing loop/task ids (see cmd_objective.sh) instead of the
# old hard E_TIMEOUT that orphaned the late diff. This sweep pulls the diff once
# the planner task completes and re-drives the EXISTING `objective replan --diff`
# path (validate → gate/materialize), so a slow planner materializes on the next
# tick instead of never. Single-threaded (the tick is one host-cron process), so
# no claim-lock is needed; isolated by the caller (|| _hb_log) like every sweep.
_hb_objective_reconcile() {
  local rows; rows=$(db "SELECT oc.id||'|'||oc.objective_id||'|'||oc.cycle_no||'|'||COALESCE(oc.planner_task_id,'')||'|'||COALESCE(oc.planner_loop_id,'')||'|'||o.name||'|'||COALESCE(o.planner,'')
                         FROM objective_cycles oc JOIN objectives o ON o.id=oc.objective_id
                         WHERE oc.outcome='awaiting_planner';" 2>/dev/null)
  [[ -n "$rows" ]] || return 0
  local line
  while IFS='|' read -r row_id obj_id cyc tid lid oname planner; do
    [[ -n "$row_id" ]] || continue
    # No backing task id recorded — can't reconcile; surface as failed once.
    if [[ -z "$tid" || ! "$tid" =~ ^[0-9]+$ ]]; then
      db "UPDATE objective_cycles SET outcome='planner_failed' WHERE id=${row_id};"
      _hb_log "[obj-reconcile] ${oname} #${cyc}: no backing task id — marked planner_failed"
      continue
    fi
    local tstatus; tstatus=$(db "SELECT status FROM tasks WHERE id=${tid};")
    case "$tstatus" in
      "")  # backing task vanished (purged/board-wipe) — surface, don't loop forever
        db "UPDATE objective_cycles SET outcome='planner_failed' WHERE id=${row_id};"
        _hb_log "[obj-reconcile] ${oname} #${cyc}: backing planner task ${tid} gone — planner_failed"
        ;;
      done)
        local result; result=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${tid};")
        # The late close must be a diff JSON object. If it's prose (a human ACK
        # salvage) or empty, don't guess — mark failed and let the stall/gate
        # surfacing pick it up for manual `replan --diff`.
        if ! printf '%s' "$result" | jq -e 'type=="object"' >/dev/null 2>&1; then
          db "UPDATE objective_cycles SET outcome='planner_failed' WHERE id=${row_id};"
          _hb_log "[obj-reconcile] ${oname} #${cyc}: planner task ${tid} closed non-diff (prose/empty) — planner_failed (salvage: replan --diff)"
          local coord; coord=$(_task_resolve_coordinator 2>/dev/null)
          [[ -n "$coord" ]] && ( cmd_send "$coord" --message="⚠️ objective '${oname}' cycle ${cyc}: planner loop ${lid:-?} finished but its close-result isn't a diff — no auto-materialize. Salvage: 5dive objective replan \"${oname}\" --diff='<json from task ${tid}>' (DIVE-1737 reconciler)." ) >/dev/null 2>&1 || true
          continue
        fi
        # Parseable diff: drop the marker so `replan --diff` reuses cycle ${cyc}
        # (MAX(cycle_no) falls back to ${cyc}-1), then re-drive the existing path.
        db "DELETE FROM objective_cycles WHERE id=${row_id};"
        local from_arg="$planner"; [[ -n "$from_arg" ]] || from_arg=$(_task_resolve_coordinator 2>/dev/null)
        if ( JSON_MODE=0 cmd_objective_replan "$oname" --diff="$result" ${from_arg:+--from="$from_arg"} ) >/dev/null 2>&1; then
          _hb_log "[obj-reconcile] ${oname} #${cyc}: materialized late planner diff (loop ${lid:-?}, task ${tid})"
        else
          # Diff parsed but failed deeper validation/gating — re-record so the
          # cycle isn't silently lost, and surface for a human.
          _objective_record_cycle "$obj_id" "$cyc" "" 0 0 0 0 0 "" 0 "planner_failed"
          _hb_log "[obj-reconcile] ${oname} #${cyc}: late diff failed validate/apply — planner_failed"
        fi
        ;;
      cancelled|rejected|escalated)
        db "UPDATE objective_cycles SET outcome='planner_failed' WHERE id=${row_id};"
        _hb_log "[obj-reconcile] ${oname} #${cyc}: planner task ${tid} ${tstatus} — planner_failed"
        ;;
      *)  # todo/in_progress/blocked — planner still working; leave it pending
        : ;;
    esac
  done <<< "$rows"
  return 0
}

# DIVE-2102: re-verify each registered agent's capabilities against its INSTALLED
# sudoers file. Measurement, not a timestamp bump — see
# capability_reverify_from_sudoers.
_hb_capability_reverify_sweep() {
  local reg name
  reg=$(registry_read) || return 0
  for name in $(jq -r '.agents | keys[]' <<<"$reg" 2>/dev/null); do
    [[ -n "$name" ]] || continue
    capability_reverify_from_sudoers "agent-${name}" || true
  done
  return 0
}

cmd_heartbeat_tick() {
  require_root "heartbeat tick"
  tasks_db_init
  local reg now; reg=$(registry_read); now=$(date +%s)
  local checked=0 woke=0 reaped=0 reclaimed=0 starved=0 sk_notdue=0 sk_busy=0 sk_nowork=0 sk_fail=0 sk_spread=0 sk_active=0 sk_budget=0 sk_held=0
  local today; today=$(date +%F)   # DIVE-1858 wake-budget day key (YYYY-MM-DD)
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
  # DIVE-1858 Stage 2: live auto-sleep pass. Stops cold + idle + no-open-work
  # agents after the idle threshold. Isolated like every other sweep — a failure
  # here must NEVER abort the wake loop (the heartbeat-never-woke bug class). No-op
  # unless at least one agent is opt-in wake_mode=cold.
  _hb_autosleep_sweep "$now" || _hb_log "[autosleep] pass errored (non-fatal)"
  # DIVE-2102: renew capability rows from the installed sudoers files. Without
  # this the 7d TTL expires every row and the registry converges on permanently
  # empty. Isolated like every other sweep — and note the failure direction is
  # already safe: if this never runs, rows go stale and stale reads as ABSENT,
  # which is today's behaviour. It can lose confirmations, never invent them.
  _hb_capability_reverify_sweep || _hb_log "[capability-reverify] pass errored (non-fatal)"
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
  # CNCL-12: rot-triage stale tier-2 gates via a council convene (re-brief only,
  # NEVER clears). Default OFF (COUNCIL_ROT_TRIAGE=on) — a live convene injects into
  # seat sessions, so it stays gated on an explicit opt-in until main's CNCL-7 window.
  # Same isolation contract — a failure here must never abort the wake loop.
  _hb_council_rot_sweep || _hb_log "[council-rot] pass errored (non-fatal)"
  # DIVE-1416: fleet-stall self-heal gaps #2/#3 — surface stale maker->verifier
  # deliveries, alarm on fleet-idle-while-actionable-work-is-open persisting past
  # its threshold, and a pinger-liveness canary for the DIVE-1434 dead-batch
  # class. Same isolation contract — a failure here must never abort the wake
  # loop, and must never itself go silent the way the incident it targets did.
  _hb_stall_sweep || _hb_log "[stall-sweep] pass errored (non-fatal)"
  # DIVE-972: enforce per-loop token ceilings for async (non --wait) loops. Same
  # isolation contract — a failure here must never abort the wake loop.
  _hb_loop_ceiling_sweep || _hb_log "[loop-ceiling] pass errored (non-fatal)"
  # DIVE-3343: there is NO per-TASK budget sweep here any more, and its absence
  # is deliberate — see the block above _hb_loop_ceiling_sweep's neighbours in
  # this file for why the figure it enforced could not be attributed to a row.
  # DIVE-1019: per-agent token budget guardrails — alert the owner at the soft
  # cap and (only if hard-stop is opted in) turn an agent off at the ceiling, and
  # refresh the state cache `watch` reads. Same isolation contract as above.
  _hb_budget_sweep || _hb_log "[budget] pass errored (non-fatal)"
  # DIVE-1434: transport-liveness canary — alarm if any paired claude agent's
  # Telegram poller died (stale beacon => gate-ping taps won't land). Same
  # isolation contract — a failure here must never abort the wake loop.
  _hb_poller_liveness_sweep || _hb_log "[poller-liveness] pass errored (non-fatal)"
  # DIVE-1737: async self-heal materialize — pull a late objective-planner diff
  # (recorded 'awaiting_planner' when its loop timed out past the wait window) and
  # re-drive the existing `objective replan --diff` path. Same isolation contract
  # — a failure here must never abort the wake loop.
  _hb_objective_reconcile || _hb_log "[obj-reconcile] pass errored (non-fatal)"
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
    # Wake the agent against ONE concrete todo — the /goal condition needs a
    # concrete DIVE-N to evaluate reliably — but consider the queue IN ORDER
    # until one is actually runnable.
    #
    # DIVE-2716: the tier guard below is a per-TASK verdict, and it used to be
    # spent as a per-AGENT one. With a single pick, a held head meant `continue`
    # on the whole agent; selection is deterministic, so the identical row was
    # re-picked and re-held every tick and the runnable rows behind it were
    # unreachable FOREVER (measured 2026-08-04: 5 held rows head-of-line blocking
    # 122, fleet idle 2h35m, main's queue stuck 5 days). The guard's own comment
    # bounded the wrong axis — "a hold skips ONE agent's wake this tick" is true
    # per tick and says nothing about a tick that repeats with identical input.
    # Stepping past the held row keeps the guard's whole safety property (a held
    # task is still never auto-run, and still names itself in the log) and lets
    # everything behind it flow.
    local task_id="" task_ident="" _cand _cand_n=0 _picked=0
    while IFS= read -r _cand; do
      [[ -n "$_cand" ]] || continue
      _cand_n=$((_cand_n + 1))
      task_id="$_cand"
      # The /goal + every log below must name the task by its DISPLAY ident, not
      # the raw row id — they diverge once a non-default project exists (DIVE-484).
      task_ident=$(_hb_ident "$task_id")

    # --- DIVE-1065 tier guard --------------------------------------------------
    # Refuse to AUTO-DRIVE a higher-tier agent from a lower-tier creator's task.
    # A standard/sandboxed agent can enqueue work onto an admin agent; without
    # this, the heartbeat would auto-run it (privilege-escalation-by-queue). If
    # the task's creator is strictly LOWER-privileged than its assignee, HOLD the
    # task (don't auto-wake) — a human or the assignee can still run it manually.
    #
    # DIVE-2213 — this used to read the two tiers with `jq ... 2>/dev/null` and
    # rank an empty result 0, then skip itself whenever either rank was 0. That
    # made a lookup that NEVER HAPPENED indistinguishable from a creator who
    # legitimately has no tier, and the tie went to running the work: an
    # unmeasured tier DISABLED the guard. Same collapse as DIVE-2210's envelope,
    # one class worse because this is a decision, not a display.
    #
    # The ticket framed the fix as a binary — hold everything unmeasured (fail
    # closed, may stall the fleet) or wake with a loud log (fail open, no longer
    # silent). It is a FALSE binary, and rank-0 is what disguised it. Two
    # populations were sharing that bucket and they want OPPOSITE policies:
    #
    #   MEASURED, no tier  — the creator is not a registered agent: a human, or
    #     an external filer. This is the majority of the board. Falling through
    #     is not a failure mode, it is DIVE-1065's intent. Holding here would
    #     stall every human-filed task fleet-wide, which is the cost the ticket
    #     was (correctly) afraid of.
    #   NOT MEASURED       — registry absent/unreadable/unparsable, jq errored,
    #     or the agent IS registered and its isolation is missing/malformed. We
    #     have no basis to rank either side, so ranking them 0 asserts something
    #     we do not know. HOLD.
    #
    # Holding only the second is cheap: a healthy registry never produces it, so
    # this cannot stall the fleet in steady state, and each cause names itself in
    # the log so a hold is repairable rather than mysterious. agent_tier() +
    # tier_unmeasured() (src/lib/registry.sh) draw exactly that line — note they
    # are NOT envelope_tier(), which folds both populations into
    # `unknown:unregistered` because a wire format has no decision to make.
    #
    # Isolation, restated correctly (DIVE-2716). This block used to claim "a hold
    # skips ONE agent's wake this tick and never aborts the tick". Both halves
    # are true PER TICK and the conclusion still did not hold: the tick repeats
    # with identical input, so a per-tick skip of a deterministically re-picked
    # row is a PERMANENT skip of that agent. The hold is now what it always said
    # it was — scoped to the TASK: the held row is not auto-run, the next
    # candidate in the same priority order is considered, and a self-assigned
    # task or an equal/higher-tier creator is unaffected.
    local _cby _ctier _atier
    _cby=$(db "SELECT COALESCE(created_by,'') FROM tasks WHERE id=${task_id};" 2>/dev/null || echo "")
    if [[ -n "$_cby" && "$_cby" != "$name" ]]; then
      _ctier=$(agent_tier "$_cby"); _atier=$(agent_tier "$name")
      if tier_unmeasured "$_ctier" || tier_unmeasured "$_atier"; then
        _hb_log "[$name] task ${task_ident} tier NOT MEASURED (creator ${_cby}=${_ctier}, assignee ${name}=${_atier}) — holding, not auto-running (DIVE-2213); considering the next candidate"
        continue
      fi
      # Only measured values reach the ranking. `unknown:unregistered` ranks 0
      # via the catch-all, which is the human/external fall-through above.
      local _cr _ar
      _cr=$(_hb_tier_rank "$_ctier"); _ar=$(_hb_tier_rank "$_atier")
      if (( _cr > 0 && _ar > 0 && _cr < _ar )); then
        _hb_log "[$name] task ${task_ident} created by lower-tier ${_cby}(${_ctier}) < assignee(${_atier}) — holding, not auto-running; considering the next candidate"
        continue
      fi
    fi
    # --- end DIVE-1065 tier guard ----------------------------------------------
    # (Sentinel for tests/heartbeat_tier_guard_unmeasured_unit.sh, which extracts
    # the block above VERBATIM and evals it: everything below closes the candidate
    # loop and must stay outside that extraction.)

      _picked=1; break
    done < <(_hb_pick_tasks "$name" "$_HB_PICK_SCAN")
    if (( _picked == 0 )); then
      task_id=""; task_ident=""
      if (( _cand_n == 0 )); then
        sk_nowork=$((sk_nowork + 1)); _hb_log "[$name] no todo — stay idle"; continue
      fi
      # Every candidate we looked at was held. Not silent, and it names the cap:
      # if _cand_n hit _HB_PICK_SCAN there may be runnable rows we never reached,
      # which is a different (and much louder) situation than "the queue is held".
      sk_held=$((sk_held + _cand_n))
      if (( _cand_n >= _HB_PICK_SCAN )); then
        _hb_log "[$name] tier guard held all ${_cand_n} candidate(s) SCANNED — scan cap _HB_PICK_SCAN=${_HB_PICK_SCAN} reached, runnable rows past it were NOT examined; authorize a held task (5dive task authorize) or fix the creator/assignee tiers"
      else
        _hb_log "[$name] tier guard held all ${_cand_n} runnable todo(s) — stay idle"
      fi
      continue
    fi
    if (( _cand_n > 1 )); then
      sk_held=$((sk_held + _cand_n - 1))
      _hb_log "[$name] tier guard held $((_cand_n - 1)) higher-priority todo(s); waking on ${task_ident} instead (DIVE-2716)"
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
      # DIVE-1666: CLASSIFY the open dialog. A genuine permission/plan prompt is
      # real in-flight work → defer, never interrupt (the else branch, unchanged).
      # But the Claude Code usage/spend-limit dialog is a dead-end that never
      # self-clears, so deferring it every tick froze whole sessions permanently
      # even after the 5h window rolled back to headroom (the 2026-07-21 stall).
      # Self-heal: restart to clear the stale dialog (fresh:true → no context
      # lost), throttled so a still-limited account isn't churn-restarted, and
      # only surface to the human when NO account headroom is provable (a real
      # capacity/billing call, not a stuck dialog).
      if _hb_usage_limit_frozen "$name"; then
        local heal_last heal_gap headroom=1
        _hb_account_has_headroom "$name" "$acct" "$reg" && headroom=0
        # DIVE-1677: headroom is PROVEN (a healthy peer on the pooled account), so
        # there is no real limit to reset — prefer resuming the SAME session in
        # place over a hard restart. Dismiss the stale dialog + type "continue"
        # (conversation + context preserved), and only after _HB_USAGE_PRESS_MAX
        # consecutive presses fail to unstick it (re-checked next tick via
        # _hb_usage_limit_frozen) fall through to the v1 hard-restart path below.
        # No headroom → skip press-continue entirely: restart-once-to-test-the-5h-
        # window is the correct probe when the limit might be genuinely live.
        if (( headroom == 0 )); then
          local press_n; press_n=$(_hb_usage_press_count "$name")
          [[ "$press_n" =~ ^[0-9]+$ ]] || press_n=0
          if (( press_n < _HB_USAGE_PRESS_MAX )); then
            local pn; pn=$(with_registry_lock _hb_mark_usage_press "$name" "$now")
            if _hb_press_continue "$name"; then
              reclaimed=$((reclaimed + 1))
              _hb_log "[$name] usage-limit dialog frozen; account '$acct' has headroom → pressed continue to resume IN PLACE, session preserved (DIVE-1677 press #${pn}/${_HB_USAGE_PRESS_MAX})"
            else
              _hb_log "[$name] usage-limit dialog frozen; press-continue keystrokes FAILED to send (pane?) — retry/restart next tick (DIVE-1677 press #${pn})"
            fi
            sk_active=$((sk_active + 1))
            continue
          fi
          _hb_log "[$name] usage-limit dialog STILL frozen after ${press_n} press-continue attempt(s) with headroom → falling back to hard restart (DIVE-1677 → DIVE-1666)"
        fi
        heal_last=$(_hb_usage_heal_last "$name")
        [[ "$heal_last" =~ ^[0-9]+$ ]] || heal_last=0
        heal_gap=$(( (now - heal_last) / 60 ))
        if (( heal_last == 0 || heal_gap >= _HB_USAGE_HEAL_THROTTLE_MIN )); then
          local hn; hn=$(with_registry_lock _hb_mark_usage_heal "$name" "$now")
          if systemctl restart "5dive-agent@${name}.service" 2>/dev/null; then
            reclaimed=$((reclaimed + 1))
            if (( headroom == 0 )); then
              _hb_log "[$name] usage-limit dialog frozen; account '$acct' has headroom (healthy peer) → restarted to self-heal (DIVE-1666 heal #${hn:-?})"
            else
              _hb_log "[$name] WARN: usage-limit dialog frozen; NO healthy peer on '$acct' → restarted once to test the 5h window (DIVE-1666 heal #${hn:-?}); will surface if it re-freezes"
            fi
          else
            _hb_log "[$name] usage-limit dialog frozen — self-heal restart FAILED (systemctl); retry next window"
          fi
          continue
        fi
        # Throttled: we restarted within the window and it's frozen on the SAME
        # dialog again → the account is genuinely limited right now, not a stuck
        # dialog. When no peer proves headroom, that's a capacity/billing call →
        # surface loudly to the fleet coordinator (throttled), then defer.
        if (( headroom == 1 )); then
          local ua_key="usage_limit_alert_${name}" ua_last ua_cut
          ua_last=$(db "SELECT value FROM task_prefs WHERE key='${ua_key}';" 2>/dev/null)
          ua_cut=$(date -u -d '60 minutes ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
          if [[ -z "$ua_last" || ( -n "$ua_cut" && "$ua_last" < "$ua_cut" ) ]]; then
            ( cmd_send "main" --from="task-engine" \
                --message="🟠 Capacity/billing check: agent '${name}' is frozen on the Claude Code usage-limit dialog and STILL frozen ${heal_gap}m after a self-heal restart, with no healthy peer on account '${acct}' to prove headroom — account '${acct}' appears genuinely rate/spend-limited right now (not a stuck dialog). If this is a plan/spend ceiling it's a human call for lodar. (DIVE-1666)" ) >/dev/null 2>&1 || true
            db "INSERT INTO task_prefs (key,value) VALUES ('${ua_key}', datetime('now'))
                ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now');" 2>/dev/null || true
            _hb_log "[$name] usage-limit dialog frozen ${heal_gap}m post-restart, no headroom on '$acct' → surfaced capacity/billing to main (DIVE-1666)"
          fi
        fi
        sk_active=$((sk_active + 1))
        _hb_log "[$name] WARN: usage-limit dialog frozen ${heal_gap}m after self-heal restart (throttle ${_HB_USAGE_HEAL_THROTTLE_MIN}m) — deferring this tick (DIVE-1666)"
        continue
      fi
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

    # DIVE-1858 Stage 1: wake-budget guardrail. A cold-mode agent that has spent
    # today's wake cap is skipped this tick so a chatty trigger can't thrash it
    # into repeated cold-start wakes (cost-per-wake surfaced via `wake-mode`).
    # always_on / un-capped agents are never budgeted — pure additive gate, and
    # the $reg snapshot's counter is close enough at day granularity. NO sleep.
    if ! _hb_wake_budget_ok "$name" "$today" "$reg"; then
      sk_budget=$((sk_budget + 1))
      _hb_log "[$name] wake-budget spent for ${today} (cold-mode cap reached) — skip wake this tick"
      continue
    fi

    _hb_log "[$name] due + todo ${task_ident} — waking (fresh=${eff_fresh})"
    if _hb_wake "$name" "$eff_fresh" "$task_id" "$task_ident"; then
      in_tick_woke[$acct]=$now   # claim the account's slot for the rest of this tick
      with_registry_lock _hb_wake_budget_inc "$name" "$today" >/dev/null 2>&1 || true  # DIVE-1858: count this wake
      with_registry_lock _hb_clear_active_defer "$name" >/dev/null 2>&1 || true  # DIVE-1486: episode over
      local nudge_n
      # _hb_mark_run FIRST, then the claim. Its prune keys on "still todo", so
      # claiming first would evict this task's own nudge entry every tick and peg
      # the counter at 1 — the starvation signal below would never fire again.
      nudge_n=$(with_registry_lock _hb_mark_run "$name" "$now" "$task_id")
      # DIVE-2244: THE DISPATCHER CLAIMS. See _hb_claim_task.
      local _claimed=0; _hb_claim_task "$name" "$task_id" && _claimed=1
      woke=$((woke + 1))
      if (( _claimed == 1 )); then
        _hb_log "[$name] nudged (/goal ${task_ident}, nudge #${nudge_n:-?}) — claimed in_progress (DIVE-2244)"
      else
        # Loud, not silent: an unclaimed nudge is exactly the pre-DIVE-2244 world
        # for THIS task — reaper, orphan reclaim and unwedge cannot see it, and
        # the busy-guard will re-nudge it next tick.
        _hb_log "[$name] WARN: nudged (/goal ${task_ident}, nudge #${nudge_n:-?}) but the CLAIM did not land (row no longer todo, or db write failed) — recovery rules are blind to this task this tick (DIVE-2244)"
      fi
      # Nudged repeatedly for the SAME task → it is being starved. Pre-DIVE-2244
      # this meant "never left todo" (the listen-loop watchdog yanking the agent
      # before `task start` ran). Now the dispatcher claims, so reaching this
      # count means the task keeps coming BACK to todo — it was claimed, then
      # reclaimed by rule (a)/(b)/(c), repeatedly. Different mechanism, same
      # conclusion: the agent is not converting nudges into finished work.
      if [[ "${nudge_n:-0}" =~ ^[0-9]+$ ]] && (( nudge_n >= _HB_STARVE_AFTER )); then
        starved=$((starved + 1))
        _hb_log "[$name] WARN: ${task_ident} nudged ${nudge_n}x and is still not done (claimed then requeued each time) — possible listen-loop starvation; check the agent's task-claim path"
      fi
      # DIVE-3218: and CONSUME that count. The WARN above is the observation; this
      # is the lever. Separate threshold, separate ladder — see _hb_nudge_enforce.
      _hb_nudge_enforce "$name" "$task_id" "$task_ident" "${nudge_n:-0}" || true
    else
      sk_fail=$((sk_fail + 1)); _hb_log "[$name] wake failed — will retry next tick"
    fi
  done < <(jq -r '.agents | to_entries
                  | map(select(.value.heartbeat.enabled == true))
                  | sort_by(.value.heartbeat.lastRunAt // 0)
                  | .[].key' <<<"$reg")

  ok "heartbeat tick: woke ${woke} / slept ${_HB_SLEPT} / reclaimed ${reclaimed} / reaped ${reaped} / starved ${starved} / tier-held ${sk_held} / spread-deferred ${sk_spread} / active-deferred ${sk_active} / budget-skipped ${sk_budget} / checked ${checked}" \
     '{checked:($c|tonumber), woke:($w|tonumber), slept:($sl|tonumber), sleepArmed:($sa|tonumber), reclaimed:($rc|tonumber), reaped:($r|tonumber), starved:($st|tonumber),
       skipped:{notDue:($nd|tonumber), busy:($b|tonumber), noWork:($nw|tonumber), spread:($sp|tonumber), active:($ac|tonumber), budget:($bu|tonumber), failed:($sf|tonumber), tierHeld:($th|tonumber)}}' \
     --arg c "$checked" --arg w "$woke" --arg sl "$_HB_SLEPT" --arg sa "$_HB_SLEEP_ARMED" --arg rc "$reclaimed" --arg r "$reaped" --arg st "$starved" --arg nd "$sk_notdue" --arg b "$sk_busy" --arg nw "$sk_nowork" --arg sp "$sk_spread" --arg ac "$sk_active" --arg bu "$sk_budget" --arg sf "$sk_fail" --arg th "$sk_held"
}
