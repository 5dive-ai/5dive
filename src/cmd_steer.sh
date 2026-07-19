# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 5dive steer — the new-work generator (STEER-11, per the STEER-5 design).
#
# When the fleet drains to ZERO dispatchable work, idle must become a *trigger*,
# not a resting state. `5dive steer propose` sources concrete candidate work off
# REAL, auditable signal (active projects with an unrealized goal + no open work,
# ROADMAP.md unchecked items) — never free-invented — and files a CAPPED set of
# review-state tasks routed to the project lead. Candidates are filed BLOCKED
# behind an approve|revise decision gate (assignee=lead), so nothing is ever
# auto-dispatched to a builder: the lead approves → the task becomes dispatchable
# (see _hb_steer_apply_sweep in cmd_heartbeat.sh). A merely-*dammed* queue
# (open-but-blocked work) is STEER-1's lane and does NOT trigger generation.
#
# Sourcing is rule-based on purpose: every candidate carries a traceable source,
# so nothing can be hallucinated (design §2 anti-busywork). A richer LLM planner
# pass (cmd_goal.sh _goal_invoke_planner) can layer on later; the floor is that a
# candidate with no source is never minted.
#
# Guardrails (design §3): cap per cycle (STEER_MAX_PROPOSE, default 3), outstanding
# cap across all unreviewed candidates (STEER_MAX_OUTSTANDING, default 5), de-dup
# by source so the same signal can't be re-proposed, review gate not auto-execute.
# ---------------------------------------------------------------------------

# Tunables (env-overridable; the heartbeat trigger reads STEER_IDLE_TICKS).
_steer_cfg() {
  STEER_MAX_PROPOSE="${STEER_MAX_PROPOSE:-3}"
  STEER_MAX_OUTSTANDING="${STEER_MAX_OUTSTANDING:-5}"
  [[ "$STEER_MAX_PROPOSE"     =~ ^[0-9]+$ ]] || STEER_MAX_PROPOSE=3
  [[ "$STEER_MAX_OUTSTANDING" =~ ^[0-9]+$ ]] || STEER_MAX_OUTSTANDING=5
}

# Count review-state candidates still awaiting a lead decision (the outstanding
# cap + the "no unreviewed candidates already waiting" fire-guard both read this).
_steer_outstanding_count() {
  db "SELECT COUNT(*) FROM tasks
        WHERE ask LIKE '[steer]%' AND need_answered_at IS NULL
          AND status NOT IN ('done','cancelled');" 2>/dev/null || echo 0
}

# True (0) if some OPEN task already carries this source marker — de-dup so a
# drained-board signal is proposed at most once until it's acted on.
_steer_already_sourced() {
  local src="$1" n
  n=$(db "SELECT COUNT(*) FROM tasks
            WHERE status NOT IN ('done','cancelled')
              AND instr(COALESCE(body,''), $(sqlq "steer-source: ${src}")) > 0;" 2>/dev/null || echo 0)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  (( n > 0 ))
}

# Resolve the review reviewer for a project: its lead_agent, else the filer's
# org-chart lead (_gate_route_reviewer), else the org coordinator. Never the
# generator/system actor itself.
_steer_lead_for() {
  local pkey="$1" actor="$2" lead=""
  lead=$(db "SELECT COALESCE(lead_agent,'') FROM projects WHERE key=$(sqlq "$pkey") AND status='active' LIMIT 1;" 2>/dev/null)
  [[ -n "$lead" ]] || lead=$(_gate_route_reviewer "$actor")
  [[ -n "$lead" ]] || lead=$(_task_resolve_coordinator 2>/dev/null)
  printf '%s' "$lead"
}

# File ONE review-state candidate: a task assigned to the lead, held BLOCKED
# behind an approve|revise gate. Echoes the created ident, or nothing on skip.
#   _steer_file_candidate <project_key> <source> <title> <why> <intended_assignee> <actor>
_steer_file_candidate() {
  local pkey="$1" src="$2" title="$3" why="$4" intended="$5" actor="$6"
  local lead; lead=$(_steer_lead_for "$pkey" "$actor")
  [[ -n "$lead" ]] || return 1   # no reviewer -> never auto-dispatch; skip
  local body
  body=$(printf '%s\n\nsteer-source: %s\nsteer-intended-assignee: %s\nAuto-sourced by the STEER-5 new-work generator when the fleet drained to zero dispatchable work. Approve to make this dispatchable (it will be assigned to %s), or revise/decline.' \
                "$why" "$src" "$intended" "${intended:-$lead}")
  local add_json cid cident
  add_json=$(JSON_MODE=1 cmd_task_add --project="$pkey" --priority=medium --assignee="$lead" --from="$actor" \
               --body="$body" -- "$title") || return 1
  cid=$(printf '%s' "$add_json" | jq -r '.data.id // empty')
  cident=$(printf '%s' "$add_json" | jq -r '.data.ident // empty')
  [[ -n "$cid" ]] || return 1
  JSON_MODE=1 cmd_task_need "$cid" --type=decision --options="approve|revise" --recommend="approve" --from="$actor" \
      --ask="[steer] ${title} — approve to mint this work (source: ${src}); revise to edit or decline." >/dev/null 2>&1 \
      || return 1
  # Filing the gate re-routes the task to the filer's org lead (DIVE-1182). Pin it
  # back onto THIS project's lead so the candidate lands in the right reviewer's
  # queue regardless of the generator actor's own position in the org chart, while
  # keeping created_by=steer-generator for the audit trail.
  db "UPDATE tasks SET assignee=$(sqlq "$lead") WHERE id=${cid};" 2>/dev/null || true
  printf '%s' "$cident"
}

# 5dive steer propose [--max=N] [--project=K] [--roadmap=PATH] [--from=ACTOR] [--dry-run]
# Source candidate work off real signal and file up to N review-state tasks.
cmd_steer_propose() {
  _steer_cfg
  local max="$STEER_MAX_PROPOSE" only_project="" roadmap="${STEER_ROADMAP:-}" from="" dry=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max=*)      max="${1#*=}" ;;
      --project=*)  only_project="${1#*=}" ;;
      --roadmap=*)  roadmap="${1#*=}" ;;
      --from=*)     from="${1#*=}" ;;
      --dry-run)    dry=1 ;;
      *) fail "$E_USAGE" "usage: 5dive steer propose [--max=N] [--project=<key>] [--roadmap=<path>] [--dry-run]" ;;
    esac
    shift
  done
  [[ "$max" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "--max must be a non-negative integer"
  local actor; actor=$(task_actor "${from:-steer-generator}")

  # Outstanding cap: if the review pile is already deep, STOP generating and let
  # STEER-1 nudge the human — do not pile more unreviewed candidates on a lead.
  local outstanding; outstanding=$(_steer_outstanding_count)
  [[ "$outstanding" =~ ^[0-9]+$ ]] || outstanding=0
  local room=$(( STEER_MAX_OUTSTANDING - outstanding ))
  (( room < 0 )) && room=0
  (( max > room )) && max="$room"

  local US=$'\x1f' filed=0 skipped=0 considered=0
  local -a idents=()

  # Build the candidate stream (priority order): (1) active projects whose goal is
  # unrealized — status='active', non-empty goal, ZERO open standard tasks; then
  # (2) ROADMAP.md unchecked items. Each line: source<US>title<US>why<US>project<US>intended.
  _steer_candidate_stream() {
    # (1) drained active projects with a goal.
    local prow key name goal lead openc
    while IFS= read -r prow; do
      [[ -n "$prow" ]] || continue
      IFS="$US" read -r key name goal lead <<<"$prow"
      [[ -n "$only_project" && "${only_project,,}" != "${key,,}" ]] && continue
      openc=$(db "SELECT COUNT(*) FROM tasks WHERE project_key=$(sqlq "$key") AND kind='standard' AND status IN ('todo','in_progress');" 2>/dev/null || echo 0)
      [[ "$openc" =~ ^[0-9]+$ ]] || openc=0
      (( openc == 0 )) || continue    # only projects with NO open work are "drained"
      printf '%s%s%s%s%s%s%s%s%s\n' \
        "project:${key}" "$US" \
        "Steer: advance ${name} toward its goal" "$US" \
        "Active project '${key}' has no open work but its goal is unrealized: ${goal}" "$US" \
        "$key" "$US" "${lead}"
    done < <(db "SELECT key||x'1f'||COALESCE(NULLIF(name,''),key)||x'1f'||COALESCE(goal,'')||x'1f'||COALESCE(lead_agent,'')
                   FROM projects
                  WHERE status='active' AND COALESCE(goal,'')!=''
                  ORDER BY created_at;" 2>/dev/null)

    # (2) ROADMAP.md unchecked items -> one candidate each, filed to the default
    # project's lead. Skipped entirely when no roadmap file is configured/present.
    [[ -n "$roadmap" && -f "$roadmap" ]] || return 0
    local line text slug defproj="${STEER_ROADMAP_PROJECT:-dive}"
    while IFS= read -r line; do
      text=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*\[[[:space:]]\][[:space:]]*//')
      [[ -n "$text" ]] || continue
      slug=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//' | cut -c1-48)
      printf '%s%s%s%s%s%s%s%s%s\n' \
        "roadmap:${slug}" "$US" \
        "Steer: ${text}" "$US" \
        "Open ROADMAP item with no active task: ${text}" "$US" \
        "$defproj" "$US" ""
    done < <(grep -E '^[[:space:]]*-[[:space:]]*\[[[:space:]]\]' "$roadmap" 2>/dev/null)
  }

  local row src title why pkey intended ident
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    (( filed >= max )) && break
    IFS="$US" read -r src title why pkey intended <<<"$row"
    considered=$(( considered + 1 ))
    if _steer_already_sourced "$src"; then skipped=$(( skipped + 1 )); continue; fi
    if (( dry )); then
      idents+=("(dry) ${src} -> ${title}"); filed=$(( filed + 1 )); continue
    fi
    ident=$(_steer_file_candidate "$pkey" "$src" "$title" "$why" "$intended" "$actor") || { skipped=$(( skipped + 1 )); continue; }
    [[ -n "$ident" ]] || { skipped=$(( skipped + 1 )); continue; }
    idents+=("$ident"); filed=$(( filed + 1 ))
  done < <(_steer_candidate_stream)

  local list_json; list_json=$(printf '%s\n' "${idents[@]}" | jq -R 'select(length>0)' | jq -cs '.' 2>/dev/null || echo '[]')
  ok "steer propose: filed ${filed} review-state candidate(s), skipped ${skipped} (dry-run=${dry}, outstanding was ${outstanding}/${STEER_MAX_OUTSTANDING})" \
     '{proposed:$f, skipped:$s, considered:$c, outstanding:$o, max:$m, dry_run:($d=="1"), candidates:$cand}' \
     --argjson f "$filed" --argjson s "$skipped" --argjson c "$considered" \
     --argjson o "$outstanding" --argjson m "$max" --arg d "$dry" --argjson cand "$list_json"
}

# 5dive steer status — the current review pile + trigger counters.
cmd_steer_status() {
  _steer_cfg
  local outstanding idle_ticks last_ep
  outstanding=$(_steer_outstanding_count)
  idle_ticks=$(db "SELECT value FROM task_prefs WHERE key='steer_idle_ticks';" 2>/dev/null || echo 0)
  [[ "$idle_ticks" =~ ^[0-9]+$ ]] || idle_ticks=0
  last_ep=$(db "SELECT value FROM task_prefs WHERE key='steer_last_fired_at';" 2>/dev/null)
  if (( JSON_MODE )); then
    ok "" '{outstanding:$o, max_outstanding:$mo, idle_ticks:$it, idle_ticks_to_fire:$tf, last_fired_at:$lf}' \
       --argjson o "$outstanding" --argjson mo "$STEER_MAX_OUTSTANDING" --argjson it "$idle_ticks" \
       --argjson tf "${STEER_IDLE_TICKS:-2}" --arg lf "${last_ep:-}"
  else
    echo "steer: ${outstanding}/${STEER_MAX_OUTSTANDING} candidate(s) awaiting review; idle_ticks=${idle_ticks} (fires at ${STEER_IDLE_TICKS:-2}); last fired ${last_ep:-never}"
  fi
}

cmd_steer() {
  local sub="${1:-}"; [[ $# -gt 0 ]] && shift
  case "$sub" in
    propose) cmd_steer_propose "$@" ;;
    status)  cmd_steer_status "$@" ;;
    ""|-h|--help|help)
      cat <<'USAGE'
5dive steer — new-work generator (fires when the fleet drains to zero dispatchable work)
  5dive steer propose [--max=N] [--project=<key>] [--roadmap=<path>] [--dry-run]
        Source candidate work off real signal (drained active projects, ROADMAP
        items) and file up to N review-state tasks to the project lead, held
        behind an approve|revise gate. Nothing is auto-dispatched.
  5dive steer status
        Show the review pile + idle-trigger counters.
USAGE
      ;;
    *) fail "$E_USAGE" "unknown steer command '$sub' (try: propose|status)" ;;
  esac
}
