
# -------- 5dive goal — outcome -> materialized task graph (DIVE-984 / OSS-2) --------
#
# `5dive goal add "<outcome>"` turns an outcome into a living plan: a planner
# agent decomposes it into tasks + dependencies + assignees, filed under a
# project, which the fleet then executes via the existing heartbeat + loops.
#
# Design principle (DIVE-978): orchestrate existing primitives, build almost
# nothing new. Plan storage = a project + its tasks + task_deps. Planner
# invocation = `loop spawn --wait --schema` (schema-forced structured output).
# Materialize = `task add --project` per node + `task block --by` per edge +
# the acceptance/verify/verifier fields task add already carries on leaves.
#
# The safety spine (all enforced HERE, never trusted from the planner):
#   - hard task cap (--max-tasks, reject-not-truncate) + a dep-DAG depth cap
#   - no tier-lowering: a task whose TEXT hits the T2 category floor
#     (spend/publish/secret/destructive/brand) but is declared risk=low is
#     rejected — the planner can never launder a high-tier task as low
#   - human checkpoint: a plan over the count threshold OR carrying any T2 task
#     files exactly ONE decision gate (carrying the dry-run plan) before any
#     leaf task exists; below-threshold + all-low materializes with zero humans
#   - --dry-run renders the graph and creates nothing
#   - DAG validity: no cycles, every depends_on resolves, every task assignable
#
# Soft-deps that v1 degrades gracefully without (DIVE-980 org routing, DIVE-981
# dry-run render, DIVE-979 dep-aware scheduling): role:<x> resolves through the
# org chart when unambiguous else the plan is rejected with a clear error;
# --dry-run renders a plain list; scheduling is the existing heartbeat.

GOAL_MAX_TASKS_DEFAULT=12    # hard cap on plan size (guardrail 1)
GOAL_DEPTH_CAP_DEFAULT=5     # hard cap on dep-DAG longest path (guardrail 1)
GOAL_CHECKPOINT_DEFAULT=6    # > this many tasks -> human checkpoint (guardrail 3)
GOAL_CEILING_DEFAULT=40000   # planner token budget (guardrail 5)

# Valid values for a plan task's declared risk category. Anything but 'low' is
# a Tier-2 task (triggers the human checkpoint); the mapping to the gate floor
# reuses cmd_task_need's _gate_tier2_floor_hit classifier so goal + need agree.
_GOAL_RISK_RX='^(low|spend|publish|secret|destructive|brand)$'

cmd_goal() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    add|new)         cmd_goal_add "$@" ;;
    -h|--help|help|"") _goal_usage ;;
    *)               fail "$E_USAGE" "unknown goal command: $sub (try: 5dive goal --help)" ;;
  esac
}

_goal_usage() {
  cat <<USAGE
5dive goal — turn an outcome into a materialized, guardrailed task graph

  5dive goal add "<outcome>"
      [--project=<key>]     # else derive a key/prefix from the outcome
      [--planner=<agent>]   # default: project lead_agent, else org coordinator
      [--max-tasks=N]       # hard plan-size cap (default ${GOAL_MAX_TASKS_DEFAULT}; over -> reject)
      [--depth-cap=N]       # hard dep-DAG depth cap (default ${GOAL_DEPTH_CAP_DEFAULT})
      [--checkpoint=K]      # > K tasks -> human checkpoint (default ${GOAL_CHECKPOINT_DEFAULT})
      [--ceiling=<tokens>]  # planner budget (default ${GOAL_CEILING_DEFAULT})
      [--dry-run]           # plan + render, create nothing
      [--yes]               # waive the COUNT checkpoint (a T2 plan still gates)
      [--plan=<json>]       # supply a plan directly (skip the planner; also the
                            #   approve->materialize path for a gated plan)
      [--from=<who>]        # actor override

  JSON in/out (add --json). A plan is validated (DAG acyclicity, cap, depth,
  tier-floor, assignability) before anything is created. Over the checkpoint
  threshold or carrying any T2 task -> ONE decision gate carries the plan and
  nothing is materialized until a human approves.
USAGE
}

# ------- plan schema (planner output; passed verbatim to loop spawn --schema) -------
_goal_plan_schema() {
  cat <<'SCHEMA'
{"type":"object","required":["project","tasks"],"properties":{
  "project":{"type":"object","required":["name","goal"],"properties":{
    "key":{"type":"string"},"name":{"type":"string"},"goal":{"type":"string"}}},
  "tasks":{"type":"array","minItems":1,"items":{"type":"object",
    "required":["local_id","title","assignee_or_role"],"properties":{
      "local_id":{"type":"string"},"title":{"type":"string"},"body":{"type":"string"},
      "assignee_or_role":{"type":"string"},
      "priority":{"type":"string","enum":["low","medium","high","urgent"]},
      "acceptance":{"type":"string"},"verify":{"type":"string"},"verifier":{"type":"string"},
      "depends_on":{"type":"array","items":{"type":"string"}},
      "risk":{"type":"string","enum":["low","spend","publish","secret","destructive","brand"]}}}}}}
SCHEMA
}

# ------- org roster for the CONTRACT (roles/charters for routing) -------
_goal_roster() {
  local rows
  rows=$(db "SELECT name || CASE WHEN role IS NOT NULL THEN ' (role: '||role||')'
                                 WHEN title IS NOT NULL THEN ' — '||title ELSE '' END
             FROM agents_org ORDER BY name;" 2>/dev/null)
  if [[ -z "$rows" ]]; then
    printf '(org chart empty — assign tasks by literal agent name)'
  else
    printf '%s' "$rows"
  fi
}

# ------- CONTRACT prompt builder: _goal_build_contract <outcome> <max_tasks> -------
_goal_build_contract() {
  local outcome="$1" max_tasks="$2" roster; roster=$(_goal_roster)
  cat <<PROMPT
You are a planning agent. Decompose the OUTCOME below into a directed task graph.

OUTCOME: ${outcome}

Return ONLY a JSON object matching the provided schema (project + tasks). Rules:
- At most ${max_tasks} tasks. Fewer is better; do not pad.
- Each task: a stable plan-local id ("t1","t2",…), a clear title, an optional
  body, an assignee_or_role, and depends_on (ids of tasks that must finish first).
- assignee_or_role is EITHER a literal agent name from the roster OR "role:<role>"
  (routed through the org chart). Roster:
${roster}
- risk classifies the task: low | spend | publish | secret | destructive | brand.
  Be HONEST — anything touching money, public posts, secrets, destructive or
  brand actions is NOT low. You CANNOT lower a task's tier by mislabeling it; a
  low-labeled task whose text implies a high-risk action is rejected outright.
- The graph must be acyclic. Leaves (deliverable tasks) should carry acceptance
  criteria and a verify command where non-trivial.
PROMPT
}

# ------- assignee/role resolution: echoes agent or "" (unresolvable) -------
# Shares the org-chart resolver with `task add` (DIVE-980) so the planner and a
# direct `task add --assignee=role:<r>` route identically. role:/charter: tokens
# resolve to their unique org holder (else ""); a literal name passes through.
_goal_resolve_assignee() { _org_resolve_assignee "$1"; }

# ------- plan validation (the core testable unit) -------
# _goal_validate_plan <plan_json> <max_tasks> <depth_cap>
# Fails (via fail()) on: malformed JSON/shape, over-cap, bad priority/risk,
# duplicate/blank local_id, unknown depends_on, cycle, over-depth, unresolvable
# assignee, or a tier-lowered task. On success sets:
#   GOAL_TASK_COUNT, GOAL_CRIT_PATH (longest dep chain), GOAL_HAS_T2 (0/1).
GOAL_TASK_COUNT=0 GOAL_CRIT_PATH=0 GOAL_HAS_T2=0
_goal_validate_plan() {
  local plan="$1" max_tasks="$2" depth_cap="$3"
  printf '%s' "$plan" | jq -e . >/dev/null 2>&1 || fail "$E_VALIDATION" "plan is not valid JSON"
  printf '%s' "$plan" | jq -e 'has("project") and has("tasks") and (.tasks|type=="array")' >/dev/null 2>&1 \
    || fail "$E_VALIDATION" "plan must be an object with a 'project' and a 'tasks' array"
  printf '%s' "$plan" | jq -e '(.project.name // "")!="" and (.project.goal // "")!=""' >/dev/null 2>&1 \
    || fail "$E_VALIDATION" "plan.project needs a non-empty name and goal"

  local n; n=$(printf '%s' "$plan" | jq '.tasks|length')
  [[ "$n" -ge 1 ]] || fail "$E_VALIDATION" "plan has no tasks"
  # Reject over-cap — never silently truncate; name the overflow (guardrail 1).
  if [[ "$n" -gt "$max_tasks" ]]; then
    local dropped; dropped=$(printf '%s' "$plan" | jq -r ".tasks[${max_tasks}:] | map(.local_id) | join(\", \")")
    fail "$E_VALIDATION" "plan has $n tasks, over the --max-tasks=$max_tasks cap (would drop: $dropped) — tighten the goal or raise the cap"
  fi

  # local_id: present, non-blank, unique.
  printf '%s' "$plan" | jq -e '[.tasks[].local_id] | all(. != null and (tostring|length>0))' >/dev/null 2>&1 \
    || fail "$E_VALIDATION" "every task needs a non-empty local_id"
  local dup; dup=$(printf '%s' "$plan" | jq -r '[.tasks[].local_id] | (length) as $l | (unique|length) as $u | if $l==$u then "" else "dup" end')
  [[ -z "$dup" ]] || fail "$E_VALIDATION" "duplicate local_id in plan (ids must be unique)"

  # title, priority, risk, assignee shape per task.
  local bad
  bad=$(printf '%s' "$plan" | jq -r '.tasks[] | select((.title//"")=="") | .local_id' | head -1)
  [[ -z "$bad" ]] || fail "$E_VALIDATION" "task $bad has an empty title"
  bad=$(printf '%s' "$plan" | jq -r '.tasks[] | select((.priority//"medium") as $p | ($p|IN("low","medium","high","urgent"))|not) | .local_id' | head -1)
  [[ -z "$bad" ]] || fail "$E_VALIDATION" "task $bad has a bad priority (low|medium|high|urgent)"
  bad=$(printf '%s' "$plan" | jq -r ".tasks[] | select((.risk//\"low\") | test(\"${_GOAL_RISK_RX}\")|not) | .local_id" | head -1)
  [[ -z "$bad" ]] || fail "$E_VALIDATION" "task $bad has a bad risk (low|spend|publish|secret|destructive|brand)"
  bad=$(printf '%s' "$plan" | jq -r '.tasks[] | select((.assignee_or_role//"")=="") | .local_id' | head -1)
  [[ -z "$bad" ]] || fail "$E_VALIDATION" "task $bad has no assignee_or_role"

  # Assignability: every assignee_or_role must resolve (role:<x> -> unique holder).
  # Buffer first — _goal_resolve_assignee calls db (sqlite3) for role: forms.
  local -a arows=(); mapfile -t arows < <(printf '%s' "$plan" | jq -r '.tasks[] | "\(.local_id)\t\(.assignee_or_role)"')
  local arow lid aor resolved
  for arow in "${arows[@]}"; do
    IFS=$'\t' read -r lid aor <<<"$arow"
    [[ -n "$lid" ]] || continue
    resolved=$(_goal_resolve_assignee "$aor")
    [[ -n "$resolved" ]] || fail "$E_VALIDATION" "task $lid: assignee_or_role '$aor' does not resolve to an agent (unknown/ambiguous role)"
  done

  # Tier-lowering guard (guardrail 2): a task declared low whose title+body TEXT
  # hits the T2 category floor is a laundering attempt — reject it. Reuses
  # cmd_task_need's classifier so goal + need never disagree.
  local risk text
  while IFS=$'\t' read -r lid risk text; do
    [[ -n "$lid" ]] || continue
    if [[ "$risk" == "low" ]] && _gate_tier2_floor_hit "$text"; then
      fail "$E_VALIDATION" "task $lid is declared risk=low but its text implies a Tier-2 action (spend/publish/secret/destructive/brand) — the planner cannot lower a tier"
    fi
  done < <(printf '%s' "$plan" | jq -r '.tasks[] | "\(.local_id)\t\(.risk//"low")\t\(.title) \(.body//"")"')

  # DAG: depends_on must reference known ids; no cycles; depth <= cap.
  _goal_dag_check "$plan" "$depth_cap"   # sets GOAL_CRIT_PATH or fails

  GOAL_TASK_COUNT="$n"
  GOAL_HAS_T2=$(printf '%s' "$plan" | jq '[.tasks[] | (.risk//"low")] | any(. != "low") | if . then 1 else 0 end')
  return 0
}

# _goal_dag_check <plan_json> <depth_cap> — Kahn topological sort over the
# dependency edges: detects unknown refs + cycles and computes the longest
# dependency chain (critical path). Sets GOAL_CRIT_PATH. Plans are tiny (<= cap)
# so a bash implementation is plenty.
_goal_dag_check() {
  local plan="$1" depth_cap="$2"
  local -A known=() indeg=() depth=()
  local -A deps=()      # node -> space-separated ids it depends on
  local id
  while read -r id; do [[ -n "$id" ]] && known["$id"]=1; done \
    < <(printf '%s' "$plan" | jq -r '.tasks[].local_id')

  # Edges: "child<TAB>parent" == child depends_on parent.
  local child parent
  while IFS=$'\t' read -r child parent; do
    [[ -n "$child" && -n "$parent" ]] || continue
    [[ -n "${known[$parent]:-}" ]] || fail "$E_VALIDATION" "task $child depends_on unknown id '$parent'"
    [[ "$child" != "$parent" ]] || fail "$E_VALIDATION" "task $child depends on itself"
    deps["$child"]+=" $parent"
    indeg["$child"]=$(( ${indeg["$child"]:-0} + 1 ))
  done < <(printf '%s' "$plan" | jq -r '.tasks[] | .local_id as $t | (.depends_on // [])[] | "\($t)\t\(.)"')

  # Kahn: seed queue with zero-indegree nodes (depend on nothing) at depth 1.
  local -a queue=()
  for id in "${!known[@]}"; do
    if [[ "${indeg[$id]:-0}" -eq 0 ]]; then queue+=("$id"); depth["$id"]=1; fi
  done
  local removed=0 max=0 u p
  while [[ ${#queue[@]} -gt 0 ]]; do
    u="${queue[0]}"; queue=("${queue[@]:1}"); removed=$(( removed + 1 ))
    [[ "${depth[$u]:-1}" -gt "$max" ]] && max="${depth[$u]:-1}"
    # Relax every node that depends on u.
    for id in "${!deps[@]}"; do
      for p in ${deps[$id]}; do
        if [[ "$p" == "$u" ]]; then
          local nd=$(( ${depth[$u]:-1} + 1 ))
          [[ "$nd" -gt "${depth[$id]:-0}" ]] && depth["$id"]="$nd"
          indeg["$id"]=$(( ${indeg[$id]:-0} - 1 ))
          [[ "${indeg[$id]}" -eq 0 ]] && queue+=("$id")
        fi
      done
    done
  done
  [[ "$removed" -eq "${#known[@]}" ]] || fail "$E_VALIDATION" "plan dependency graph has a cycle"
  [[ "$max" -le "$depth_cap" ]] || fail "$E_VALIDATION" "plan dependency depth $max exceeds --depth-cap=$depth_cap"
  GOAL_CRIT_PATH="$max"
}

# ------- dry-run / gate render: _goal_render_plan <plan_json> -------
_goal_render_plan() {
  local plan="$1"
  printf '%s' "$plan" | jq -r '
    "Goal: \(.project.goal)",
    "Project: \(.project.name)\(if .project.key then " ("+.project.key+")" else "" end)",
    "Tasks: \(.tasks|length)",
    "",
    (.tasks[] |
      "  [\(.local_id)] \(.title)"
      + "  ->\(.assignee_or_role)"
      + (if (.risk//"low")!="low" then "  ⚠\(.risk)" else "" end)
      + (if ((.depends_on//[])|length)>0 then "  (after \((.depends_on)|join(", ")))" else "" end))'
}

# ------- materializer: _goal_materialize <plan> <project_key> <from> -------
# task add per node (assignee resolved, leaf accept/verify/verifier carried),
# then task block per edge. Sets GOAL_CREATED_JSON (map local_id->ident) +
# GOAL_CREATED_IDENTS (space list). Assumes the project row already exists.
GOAL_CREATED_JSON="{}" GOAL_CREATED_IDENTS=""
_goal_materialize() {
  local plan="$1" pkey="$2" from="$3"
  local -A id_of=()   # local_id -> numeric row id
  local map='{}'
  GOAL_CREATED_IDENTS=""

  # Pass 1: create every task. Pull fields per-task with jq (NOT a shared @tsv
  # line — tab is IFS-whitespace so an empty middle field like body would collapse
  # and shift columns; and a body may itself contain tabs/newlines).
  local ntask; ntask=$(printf '%s' "$plan" | jq '.tasks|length')
  local i lid title body aor prio accept verify verifier resolved add_json rid rident
  for ((i=0; i<ntask; i++)); do
    lid=$(printf '%s' "$plan"      | jq -r ".tasks[$i].local_id")
    title=$(printf '%s' "$plan"    | jq -r ".tasks[$i].title")
    body=$(printf '%s' "$plan"     | jq -r ".tasks[$i].body // \"\"")
    aor=$(printf '%s' "$plan"      | jq -r ".tasks[$i].assignee_or_role")
    prio=$(printf '%s' "$plan"     | jq -r ".tasks[$i].priority // \"medium\"")
    accept=$(printf '%s' "$plan"   | jq -r ".tasks[$i].acceptance // \"\"")
    verify=$(printf '%s' "$plan"   | jq -r ".tasks[$i].verify // \"\"")
    verifier=$(printf '%s' "$plan" | jq -r ".tasks[$i].verifier // \"\"")
    [[ -n "$lid" ]] || continue
    resolved=$(_goal_resolve_assignee "$aor")
    add_json=$(JSON_MODE=1 cmd_task_add --project="$pkey" --assignee="$resolved" \
                 --priority="${prio:-medium}" ${from:+--from="$from"} \
                 ${body:+--body="$body"} ${accept:+--accept="$accept"} \
                 ${verify:+--verify="$verify"} ${verifier:+--verifier="$verifier"} \
                 -- "$title") || return $?
    rid=$(printf '%s' "$add_json" | jq -r '.data.id')
    rident=$(printf '%s' "$add_json" | jq -r '.data.ident')
    [[ "$rid" =~ ^[0-9]+$ ]] || fail "$E_GENERIC" "goal: task create failed for $lid ($add_json)"
    id_of["$lid"]="$rid"
    map=$(jq -cn --argjson m "$map" --arg k "$lid" --arg v "$rident" '$m + {($k):$v}')
    GOAL_CREATED_IDENTS+="${rident} "
  done

  # Pass 2: wire dependency edges (child blocked_by parent). Same buffering.
  local -a edges=()
  mapfile -t edges < <(printf '%s' "$plan" | jq -r '.tasks[] | .local_id as $t | (.depends_on // [])[] | "\($t)\t\(.)"')
  local edge child parent
  for edge in "${edges[@]}"; do
    IFS=$'\t' read -r child parent <<<"$edge"
    [[ -n "$child" && -n "$parent" ]] || continue
    JSON_MODE=1 cmd_task_block "${id_of[$child]}" --by="${id_of[$parent]}" >/dev/null || return $?
  done

  GOAL_CREATED_JSON="$map"
  GOAL_CREATED_IDENTS="${GOAL_CREATED_IDENTS% }"
}

# ------- planner invocation: _goal_invoke_planner <outcome> <planner> <ceiling> <max_tasks> -------
# Wraps `loop spawn --wait --schema` and returns the plan JSON on stdout. The
# planner agent, when done, closes its backing task with the plan as its result.
_goal_invoke_planner() {
  local outcome="$1" planner="$2" ceiling="$3" max_tasks="$4"
  local contract; contract=$(_goal_build_contract "$outcome" "$max_tasks")
  local schema; schema=$(_goal_plan_schema)
  local spawn_json
  spawn_json=$(JSON_MODE=1 cmd_loop_spawn --role=worker --agent="$planner" \
                 --prompt="$contract" --schema="$schema" --ceiling="$ceiling" --wait) || return $?
  local status result
  status=$(printf '%s' "$spawn_json" | jq -r '.data.status // ""')
  result=$(printf '%s' "$spawn_json" | jq -r '.data.result // ""')
  [[ "$status" == "done" ]] || fail "$E_TIMEOUT" "planner did not return a plan (loop $status) — inspect: 5dive task loops"
  [[ -n "$result" ]] || fail "$E_GENERIC" "planner returned an empty plan"
  printf '%s' "$result"
}

# _goal_free_prefix <base> — echo a project prefix (UPPERCASE letters) not yet
# taken. Two goals whose keys share a letter-stem would otherwise collide on the
# derived prefix; append a letter until free. Falls back to the base (the caller
# then surfaces the collision) if all suffixes are taken.
_goal_free_prefix() {
  local base="${1:-GOAL}" p suffix
  [[ -n "$base" ]] || base="GOAL"
  if [[ "$(db "SELECT 1 FROM projects WHERE prefix=$(sqlq "$base");")" != "1" ]]; then printf '%s' "$base"; return; fi
  for suffix in {A..Z}; do
    p="${base}${suffix}"
    [[ "$(db "SELECT 1 FROM projects WHERE prefix=$(sqlq "$p");")" != "1" ]] && { printf '%s' "$p"; return; }
  done
  printf '%s' "$base"
}

cmd_goal_add() {
  tasks_db_init
  local project="" planner="" max_tasks="$GOAL_MAX_TASKS_DEFAULT" depth_cap="$GOAL_DEPTH_CAP_DEFAULT"
  local checkpoint="$GOAL_CHECKPOINT_DEFAULT" ceiling="$GOAL_CEILING_DEFAULT"
  local dry_run="" yes="" plan="" from=""
  local -a words=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project=*)    project="${1#*=}" ;;
      --planner=*)    planner="${1#*=}" ;;
      --max-tasks=*)  max_tasks="${1#*=}" ;;
      --depth-cap=*)  depth_cap="${1#*=}" ;;
      --checkpoint=*) checkpoint="${1#*=}" ;;
      --ceiling=*)    ceiling="${1#*=}" ;;
      --dry-run)      dry_run=1 ;;
      --yes)          yes=1 ;;
      --plan=*)       plan="${1#*=}" ;;
      --from=*)       from="${1#*=}" ;;
      --)             shift; words+=("$@"); break ;;
      -*)             fail "$E_USAGE" "unknown flag: $1" ;;
      *)              words+=("$1") ;;
    esac
    shift
  done
  local outcome="${words[*]:-}"
  [[ -n "$outcome" ]] || fail "$E_USAGE" "usage: 5dive goal add \"<outcome>\" [--project=] [--max-tasks=] [--dry-run] [--yes]"
  for v in "$max_tasks" "$depth_cap" "$checkpoint" "$ceiling"; do
    [[ "$v" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--max-tasks/--depth-cap/--checkpoint/--ceiling must be positive integers"
  done

  # 1. Get the plan: --plan supplies it directly (test seam + approve->materialize
  #    path); otherwise invoke the planner agent via loop spawn.
  if [[ -z "$plan" ]]; then
    # Resolve the planner: explicit flag > project lead > org coordinator.
    if [[ -z "$planner" && -n "$project" ]]; then
      planner=$(db "SELECT COALESCE(lead_agent,'') FROM projects WHERE key=$(sqlq "${project,,}") AND status='active';")
    fi
    [[ -n "$planner" ]] || planner=$(_task_resolve_coordinator)
    [[ -n "$planner" ]] || fail "$E_VALIDATION" "no --planner given and no project lead / org coordinator to fall back to"
    step "invoking planner '$planner' (ceiling ${ceiling}tok)…"
    plan=$(_goal_invoke_planner "$outcome" "$planner" "$ceiling" "$max_tasks") || return $?
  fi

  # 2. Validate (DAG/cap/depth/tier/assignability) — sets GOAL_* globals or fails.
  _goal_validate_plan "$plan" "$max_tasks" "$depth_cap"

  # 3. Resolve the target project key/prefix: --project > planner key > derived.
  local pkey="" pprefix=""
  if [[ -n "$project" ]]; then
    pkey="${project,,}"
  else
    pkey=$(printf '%s' "$plan" | jq -r '.project.key // ""'); pkey="${pkey,,}"
  fi
  if [[ -z "$pkey" ]] || ! valid_project_key "$pkey"; then
    pkey=$(printf '%s' "$outcome" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-24 | sed -E 's/-+$//')
    [[ "$pkey" =~ ^[a-z] ]] || pkey="goal-${pkey}"
    valid_project_key "$pkey" || pkey="goal"
  fi
  pprefix=$(printf '%s' "$pkey" | tr -cd '[:alpha:]' | tr '[:lower:]' '[:upper:]' | cut -c1-5)
  [[ -n "$pprefix" ]] || pprefix="GOAL"
  pprefix=$(_goal_free_prefix "$pprefix")   # dodge collisions (two goals -> same base)

  # 4. Dry-run: render and stop — create NOTHING.
  if [[ -n "$dry_run" ]]; then
    if (( JSON_MODE )); then
      ok "" '{dryRun:true, project:{key:$k,prefix:$pf}, taskCount:($n|tonumber), criticalPath:($cp|tonumber), hasT2:($t2=="1"), plan:$plan}' \
         --arg k "$pkey" --arg pf "$pprefix" --arg n "$GOAL_TASK_COUNT" --arg cp "$GOAL_CRIT_PATH" --arg t2 "$GOAL_HAS_T2" --argjson plan "$plan"
    else
      echo "DRY RUN — nothing created:"; echo
      _goal_render_plan "$plan"
      echo; echo "Project would be: $pkey ($pprefix-), $GOAL_TASK_COUNT task(s), critical path $GOAL_CRIT_PATH."
    fi
    return 0
  fi

  # 5. Human checkpoint (guardrail 3): over the count threshold OR any T2 task ->
  #    file ONE decision gate carrying the plan; materialize NOTHING. --yes waives
  #    ONLY the count threshold — a T2 plan always gates.
  local over_count=0; [[ "$GOAL_TASK_COUNT" -gt "$checkpoint" ]] && over_count=1
  local needs_gate=0
  [[ "$GOAL_HAS_T2" == "1" ]] && needs_gate=1
  [[ "$over_count" == "1" && -z "$yes" ]] && needs_gate=1

  # Ensure the project exists (represents the goal). Reuse if present.
  local proj_exists; proj_exists=$(db "SELECT 1 FROM projects WHERE key=$(sqlq "$pkey");")
  local pname; pname=$(printf '%s' "$plan" | jq -r '.project.name // ""')
  [[ -n "$pname" ]] || pname="$outcome"
  if [[ "$proj_exists" != "1" ]]; then
    JSON_MODE=1 cmd_project_add "$pkey" --prefix="$pprefix" --name="$pname" \
      --goal="$outcome" ${planner:+--lead-agent="$planner"} >/dev/null \
      || fail "$E_GENERIC" "goal: could not create project '$pkey'"
  fi

  if [[ "$needs_gate" == "1" ]]; then
    # Idempotency: if we already filed a plan gate for this goal, don't double up.
    local anchor_id anchor_ident
    anchor_id=$(db "SELECT id FROM tasks WHERE project_key=$(sqlq "$pkey") AND title LIKE 'Goal:%' AND kind='standard' ORDER BY id LIMIT 1;")
    if [[ -z "$anchor_id" ]]; then
      local add_json
      add_json=$(JSON_MODE=1 cmd_task_add --project="$pkey" --priority=high ${planner:+--assignee="$planner"} ${from:+--from="$from"} \
                   --body="$(printf 'Goal: %s\n\nProposed plan (%s tasks, critical path %s) — approve to materialize:\n\n%s\n\n--- plan json ---\n%s' \
                             "$outcome" "$GOAL_TASK_COUNT" "$GOAL_CRIT_PATH" "$(_goal_render_plan "$plan")" "$plan")" \
                   -- "Goal: $outcome") || return $?
      anchor_id=$(printf '%s' "$add_json" | jq -r '.data.id')
      anchor_ident=$(printf '%s' "$add_json" | jq -r '.data.ident')
    else
      anchor_ident=$(db "SELECT ident FROM tasks WHERE id=${anchor_id};")
    fi
    local reason="over checkpoint (${GOAL_TASK_COUNT}>${checkpoint})"
    [[ "$GOAL_HAS_T2" == "1" ]] && reason="carries a Tier-2 task"
    local gate_json
    gate_json=$(JSON_MODE=1 cmd_task_need "$anchor_id" --type=decision --options="approve|revise" --recommend="approve" ${from:+--from="$from"} \
                  --ask="Approve this ${GOAL_TASK_COUNT}-task plan for \"${outcome}\"? (${reason}) Full plan in the task body.") \
      || fail "$E_GENERIC" "goal: could not file the plan gate"
    if (( JSON_MODE )); then
      ok "" '{gated:true, project:{key:$k,prefix:$pf}, anchor:$ai, taskCount:($n|tonumber), criticalPath:($cp|tonumber), hasT2:($t2=="1"), reason:$r}' \
         --arg k "$pkey" --arg pf "$pprefix" --arg ai "$anchor_ident" --arg n "$GOAL_TASK_COUNT" --arg cp "$GOAL_CRIT_PATH" --arg t2 "$GOAL_HAS_T2" --arg r "$reason"
    else
      echo "Plan checkpoint: $reason. Filed ONE decision gate on $anchor_ident — nothing materialized."
      echo "Approve, then: 5dive goal add \"$outcome\" --project=$pkey --plan='<plan>' --yes"
    fi
    return 0
  fi

  # 6. Zero-human path: below threshold + all-low (or --yes over count) -> materialize.
  # Guard against re-materializing an already-built project (dup protection).
  local existing; existing=$(db "SELECT COUNT(*) FROM tasks WHERE project_key=$(sqlq "$pkey") AND kind='standard' AND title NOT LIKE 'Goal:%';")
  [[ "${existing:-0}" -eq 0 ]] \
    || fail "$E_CONFLICT" "project '$pkey' already has $existing materialized task(s) — re-planning is DIVE-982"
  _goal_materialize "$plan" "$pkey" "$from"

  if (( JSON_MODE )); then
    ok "" '{materialized:true, project:{key:$k,prefix:$pf}, taskCount:($n|tonumber), criticalPath:($cp|tonumber), created:$c, idents:($ids|split(" ")|map(select(length>0)))}' \
       --arg k "$pkey" --arg pf "$pprefix" --arg n "$GOAL_TASK_COUNT" --arg cp "$GOAL_CRIT_PATH" --argjson c "$GOAL_CREATED_JSON" --arg ids "$GOAL_CREATED_IDENTS"
  else
    ok "goal materialized under '$pkey' — $GOAL_TASK_COUNT task(s), critical path $GOAL_CRIT_PATH: $GOAL_CREATED_IDENTS"
  fi
}
