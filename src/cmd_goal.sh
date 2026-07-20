
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
#     leaf task exists; below-threshold + all-low materializes with zero humans.
#     A T2 plan gates at HARD tier 2 (never 48h-auto/agent-cleared) and is built
#     only via `goal add --from-gate=<id>` once a HUMAN answered 'approve'
#     (DIVE-985: --yes waives ONLY the count checkpoint, never a T2 gate)
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
    status)          cmd_goal_status "$@" ;;
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
      [--plan=<json>]       # supply a plan directly (skip the planner)
      [--from-gate=<id>]    # materialize a gated plan AFTER a human approved it:
                            #   recovers the plan from the anchor, requires a
                            #   HUMAN 'approve' (DIVE-916), re-validates, builds.
                            #   The only path that materializes a T2 plan.
      [--from=<who>]        # actor override
      [--wait[=<sec>]]      # scripts only: block for the plan (bounded), legacy
                            #   sync behaviour. DEFAULT is async (see below).

  5dive goal status <job>   # poll an async goal-add job: queued | running |
                            # done (plan/gated/materialized) | failed

  JSON in/out (add --json). A plan is validated (DAG acyclicity, cap, depth,
  tier-floor, assignability) before anything is created. Over the checkpoint
  threshold or carrying any T2 task -> ONE decision gate carries the plan and
  nothing is materialized until a human approves; a T2 plan gates at hard tier 2
  and is materialized only via --from-gate=<id> on a human 'approve'.

  ASYNC (DIVE-1349): by default \`goal add\` returns IMMEDIATELY with a job id
  after spawning the planner (agent-driven planning is inherently async and a
  busy/slow planner must never hold an HTTP request to a gateway 502). Poll
  \`goal status <job>\`. Pass --plan=<json> to skip the planner (synchronous,
  fast) or --wait for the legacy bounded block (scripts). If the planner is
  already idle, \`goal add\` optimistically returns the finished result inline.
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
- Each task: a stable plan-local id in a field named exactly "local_id"
  ("t1","t2",… — NOT "id"), a clear title, an optional
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
  # DIVE-1349: bound the wait explicitly. This path is usually driven behind a
  # single HTTP request (the dashboard goals page, ~180s client budget), so ask
  # for GOAL_PLANNER_WAIT_SECS (150s) — enough for a woken planner to return a
  # plan, but comfortably in-window so a slow plan yields a clean timeout the page
  # renders, never a gateway 502. The spawn also wakes the planner immediately.
  local spawn_json
  spawn_json=$(JSON_MODE=1 cmd_loop_spawn --role=worker --agent="$planner" \
                 --prompt="$contract" --schema="$schema" --ceiling="$ceiling" \
                 --wait="${GOAL_PLANNER_WAIT_SECS:-150}") || return $?
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

# ------- approve->materialize: _goal_approve_from_gate <gate_ref> <from> <max_tasks> <depth_cap> -------
# DIVE-985 gap A: the completion of the human-checkpoint loop. --yes waives ONLY
# the count checkpoint, so a Tier-2-carrying plan can be proposed + gated but has
# no way to be built — this is that path. Given the anchor task that carries a
# plan gate, verify a HUMAN answered it 'approve' (DIVE-916 human-origin rule:
# need_answered_by must be human:*, never auto:/agent), recover the plan from the
# anchor body, RE-VALIDATE it from scratch (never trust the stored blob), then
# materialize. This is the ONLY route that materializes a T2 plan.
_goal_approve_from_gate() {
  local gate_ref="$1" from="$2" max_tasks="$3" depth_cap="$4"
  resolve_task_id "$gate_ref"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"

  # Must be a goal plan anchor ('Goal: …'), not some unrelated gate.
  local title pkey; title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
  pkey=$(db "SELECT COALESCE(project_key,'') FROM tasks WHERE id=${id};")
  [[ "$title" == Goal:* ]] \
    || fail "$E_VALIDATION" "$ident is not a goal plan gate (title is not 'Goal: …') — pass the anchor task 5dive goal add filed"
  [[ -n "$pkey" ]] || fail "$E_VALIDATION" "$ident has no project — cannot materialize"

  # The gate must be ANSWERED, by a HUMAN, with 'approve' (DIVE-916 human-origin).
  local nt nans nat nby
  nt=$(db  "SELECT COALESCE(need_type,'')        FROM tasks WHERE id=${id};")
  nat=$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${id};")
  nans=$(db "SELECT COALESCE(need_answer,'')     FROM tasks WHERE id=${id};")
  nby=$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE id=${id};")
  [[ -n "$nt" ]]  || fail "$E_CONFLICT" "$ident carries no gate to approve"
  [[ -n "$nat" ]] || fail "$E_CONFLICT" "$ident's plan gate is not answered yet — a human must approve it first (tap the button in Telegram / dashboard), then re-run"
  [[ "$nby" == human:* ]] \
    || fail "$E_AUTH_REQUIRED" "$ident's plan gate was not cleared by a human (answered by '${nby:-?}') — a plan may only be materialized on a HUMAN approval (DIVE-916); an agent/TTL-cleared gate cannot build it"
  [[ "$nans" == "approve" ]] \
    || fail "$E_CONFLICT" "$ident's plan gate was answered '${nans}', not 'approve' — nothing materialized (revise via re-planning, DIVE-982)"

  # Recover the plan JSON from the anchor body (after the marker the filer appended)
  # and RE-VALIDATE it — caps/tier/DAG guards run again exactly as on propose.
  local body plan
  body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
  plan=$(printf '%s' "$body" | awk 'f{print} /^--- plan json ---$/{f=1}')
  printf '%s' "$plan" | jq -e . >/dev/null 2>&1 \
    || fail "$E_VALIDATION" "could not recover valid plan JSON from $ident's body (expected a '--- plan json ---' section)"
  _goal_validate_plan "$plan" "$max_tasks" "$depth_cap"   # sets GOAL_* or fails

  # Dup guard: refuse to re-materialize an already-built goal (re-plan = DIVE-982).
  local existing; existing=$(db "SELECT COUNT(*) FROM tasks WHERE project_key=$(sqlq "$pkey") AND kind='standard' AND title NOT LIKE 'Goal:%';")
  [[ "${existing:-0}" -eq 0 ]] \
    || fail "$E_CONFLICT" "project '$pkey' already has $existing materialized task(s) — re-planning is DIVE-982"

  local pprefix; pprefix=$(db "SELECT COALESCE(prefix,'') FROM projects WHERE key=$(sqlq "$pkey");")
  _goal_materialize "$plan" "$pkey" "$from"

  if (( JSON_MODE )); then
    ok "" '{materialized:true, fromGate:$g, project:{key:$k,prefix:$pf}, taskCount:($n|tonumber), criticalPath:($cp|tonumber), created:$c, idents:($ids|split(" ")|map(select(length>0)))}' \
       --arg g "$ident" --arg k "$pkey" --arg pf "$pprefix" --arg n "$GOAL_TASK_COUNT" --arg cp "$GOAL_CRIT_PATH" --argjson c "$GOAL_CREATED_JSON" --arg ids "$GOAL_CREATED_IDENTS"
  else
    ok "goal materialized from approved gate $ident under '$pkey' — $GOAL_TASK_COUNT task(s), critical path $GOAL_CRIT_PATH: $GOAL_CREATED_IDENTS"
  fi
}

cmd_goal_add() {
  tasks_db_init
  local project="" planner="" max_tasks="$GOAL_MAX_TASKS_DEFAULT" depth_cap="$GOAL_DEPTH_CAP_DEFAULT"
  local checkpoint="$GOAL_CHECKPOINT_DEFAULT" ceiling="$GOAL_CEILING_DEFAULT"
  local dry_run="" yes="" plan="" from="" from_gate="" from_job="" wait_flag="" wait_secs=""
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
      --from-gate=*)  from_gate="${1#*=}" ;;
      --from-job=*)   from_job="${1#*=}" ;;
      --from=*)       from="${1#*=}" ;;
      --wait)         wait_flag=1 ;;
      --wait=*)       wait_flag=1; wait_secs="${1#*=}" ;;
      --)             shift; words+=("$@"); break ;;
      -*)             fail "$E_USAGE" "unknown flag: $1" ;;
      *)              words+=("$1") ;;
    esac
    shift
  done
  [[ -z "$wait_secs" || "$wait_secs" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--wait=<seconds> must be a positive integer"

  # DIVE-985 gap A: approve->materialize an already-proposed, human-approved plan.
  # No outcome/planner/plan needed — everything is recovered from the anchor gate.
  if [[ -n "$from_gate" ]]; then
    for v in "$max_tasks" "$depth_cap"; do
      [[ "$v" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--max-tasks/--depth-cap must be positive integers"
    done
    _goal_approve_from_gate "$from_gate" "$from" "$max_tasks" "$depth_cap"
    return
  fi

  # DIVE-1349 create-from-preview: materialize the plan an async job already
  # computed. The dashboard previews with `goal add --dry-run` (async, cached in
  # goal_jobs), then creates with `--from-job=<jobid>` — a small arg that reuses
  # the EXACT previewed plan, so the plan JSON never has to ride the exec tunnel
  # (TASK_ARG_RE caps args at 2000 chars / no newlines, which a real plan blows).
  if [[ -n "$from_job" ]]; then
    _goal_from_job "$from_job" "$from"
    return
  fi

  local outcome="${words[*]:-}"
  [[ -n "$outcome" ]] || fail "$E_USAGE" "usage: 5dive goal add \"<outcome>\" [--project=] [--max-tasks=] [--dry-run] [--yes]"
  for v in "$max_tasks" "$depth_cap" "$checkpoint" "$ceiling"; do
    [[ "$v" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--max-tasks/--depth-cap/--checkpoint/--ceiling must be positive integers"
  done

  # 1. Get the plan and finish.
  #  a) --plan supplied -> synchronous finish, skip the planner (the create path:
  #     the dashboard re-submits the previewed plan, so no planner turn is run).
  #  b) --wait -> legacy synchronous bounded block for scripts.
  #  c) default -> ASYNC: spawn the planner, record a job, return a job id at once
  #     so no HTTP request is ever held to a gateway 502 (DIVE-1349).
  if [[ -n "$plan" ]]; then
    _goal_finish_with_plan "$plan" "$outcome" "$project" "$planner" "$max_tasks" "$depth_cap" "$checkpoint" "$yes" "$dry_run" "$from"
    return $?
  fi

  # Resolve the planner: explicit flag > project lead > org coordinator.
  if [[ -z "$planner" && -n "$project" ]]; then
    planner=$(db "SELECT COALESCE(lead_agent,'') FROM projects WHERE key=$(sqlq "${project,,}") AND status='active';")
  fi
  [[ -n "$planner" ]] || planner=$(_task_resolve_coordinator)
  [[ -n "$planner" ]] || fail "$E_VALIDATION" "no --planner given and no project lead / org coordinator to fall back to"

  if [[ -n "$wait_flag" ]]; then
    step "invoking planner '$planner' (ceiling ${ceiling}tok)…"
    local wplan
    wplan=$(GOAL_PLANNER_WAIT_SECS="${wait_secs:-${GOAL_PLANNER_WAIT_SECS:-150}}" \
              _goal_invoke_planner "$outcome" "$planner" "$ceiling" "$max_tasks") || return $?
    _goal_finish_with_plan "$wplan" "$outcome" "$project" "$planner" "$max_tasks" "$depth_cap" "$checkpoint" "$yes" "$dry_run" "$from"
    return $?
  fi

  _goal_spawn_async_job "$outcome" "$project" "$planner" "$max_tasks" "$depth_cap" "$checkpoint" "$ceiling" "$yes" "$dry_run" "$from"
}

# ------- finish: _goal_finish_with_plan <plan> <outcome> <project> <planner> <max_tasks> <depth_cap> <checkpoint> <yes> <dry_run> <from> -------
# Steps 2-6: validate -> resolve project -> dry-run render / gate / materialize.
# Emits the terminal envelope (dryRun|gated|materialized) in the caller's mode.
# Shared by the synchronous (--plan / --wait) paths and the async `goal status`
# poll once the planner lands a plan.
_goal_finish_with_plan() {
  local plan="$1" outcome="$2" project="$3" planner="$4" max_tasks="$5" depth_cap="$6" checkpoint="$7" yes="$8" dry_run="$9" from="${10}"

  # DIVE-1349: real planners routinely emit project.title/description instead of
  # the schema's name/goal (loop spawn --schema is prompt guidance, not a
  # hard-enforced structured-output contract, so a claude planner drifts). A good
  # plan should not be thrown away over a field-name nit, so alias title->name and
  # description->goal (and, as a last resort, the outcome itself) BEFORE validate.
  # A plan that already carries name/goal is left byte-untouched.
  # DIVE-1551: same non-enforcement bites the task key — a planner emits `id`
  # instead of the schema's `local_id`, crashing validate. Coerce id->local_id
  # per task when local_id is absent/blank (a task already carrying local_id is
  # left untouched).
  local norm
  norm=$(printf '%s' "$plan" | jq -c --arg oc "$outcome" '
    if (.project|type)=="object" then
      .project.name = (if ((.project.name // "")=="") then ((.project.title // "") | if .=="" then $oc else . end) else .project.name end)
      | .project.goal = (if ((.project.goal // "")=="") then ((.project.description // "") | if .=="" then $oc else . end) else .project.goal end)
    else . end
    | if (.tasks|type)=="array" then
        .tasks |= map(if type=="object" and ((.local_id // "")=="") and ((.id // "")!="") then .local_id = .id else . end)
      else . end' 2>/dev/null) && [[ -n "$norm" ]] && plan="$norm"

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
    # DIVE-985 gap B: a T2-carrying plan gates as a HARD tier-2 gate (never
    # 48h-auto-applied, never quietly agent-cleared into a materialize). A
    # count-only checkpoint stays the default agent-clearable tier-1 decision.
    local -a tier_arg=()
    if [[ "$GOAL_HAS_T2" == "1" ]]; then reason="carries a Tier-2 task"; tier_arg=(--tier=2); fi
    local gate_json
    gate_json=$(JSON_MODE=1 cmd_task_need "$anchor_id" --type=decision --options="approve|revise" --recommend="approve" "${tier_arg[@]}" ${from:+--from="$from"} \
                  --ask="Approve this ${GOAL_TASK_COUNT}-task plan for \"${outcome}\"? (${reason}) Full plan in the task body.") \
      || fail "$E_GENERIC" "goal: could not file the plan gate"
    if (( JSON_MODE )); then
      ok "" '{gated:true, project:{key:$k,prefix:$pf}, anchor:$ai, taskCount:($n|tonumber), criticalPath:($cp|tonumber), hasT2:($t2=="1"), reason:$r}' \
         --arg k "$pkey" --arg pf "$pprefix" --arg ai "$anchor_ident" --arg n "$GOAL_TASK_COUNT" --arg cp "$GOAL_CRIT_PATH" --arg t2 "$GOAL_HAS_T2" --arg r "$reason"
    else
      echo "Plan checkpoint: $reason. Filed ONE decision gate on $anchor_ident — nothing materialized."
      echo "After a human approves the gate, materialize with: 5dive goal add --from-gate=$anchor_ident"
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

# ------- async: _goal_spawn_async_job <outcome> <project> <planner> <max_tasks> <depth_cap> <checkpoint> <ceiling> <yes> <dry_run> <from> -------
# Spawn the planner loop WITHOUT blocking, record a goal_jobs row, and return a
# job id at once. If the planner is already idle, optimistically wait a few
# seconds and return the finished result inline; otherwise return the job handle
# and let the caller poll `goal status`.
_goal_spawn_async_job() {
  local outcome="$1" project="$2" planner="$3" max_tasks="$4" depth_cap="$5" checkpoint="$6" ceiling="$7" yes="$8" dry_run="$9" from="${10}"
  local contract; contract=$(_goal_build_contract "$outcome" "$max_tasks")
  local schema; schema=$(_goal_plan_schema)
  local spawn_json
  spawn_json=$(JSON_MODE=1 cmd_loop_spawn --role=worker --agent="$planner" \
                 --prompt="$contract" --schema="$schema" --ceiling="$ceiling") || return $?
  local loop_id task_id task_ident
  loop_id=$(printf '%s' "$spawn_json"   | jq -r '.data.loopId // ""')
  task_id=$(printf '%s' "$spawn_json"   | jq -r '.data.taskId // ""')
  task_ident=$(printf '%s' "$spawn_json" | jq -r '.data.taskIdent // ""')
  [[ -n "$loop_id" && "$task_id" =~ ^[0-9]+$ ]] || fail "$E_GENERIC" "goal: planner spawn failed ($spawn_json)"

  local now; now=$(date +%s)
  local dr=0; [[ -n "$dry_run" ]] && dr=1
  local yn=0; [[ -n "$yes" ]] && yn=1
  db "INSERT INTO goal_jobs (job_id, loop_id, task_id, outcome, project, planner,
        max_tasks, depth_cap, checkpoint, ceiling, dry_run, yes, from_actor, status, created_at, updated_at)
      VALUES ($(sqlq "$loop_id"), $(sqlq "$loop_id"), ${task_id}, $(sqlq "$outcome"),
        $(sqlq_or_null "$project"), $(sqlq "$planner"), ${max_tasks}, ${depth_cap}, ${checkpoint}, ${ceiling},
        ${dr}, ${yn}, $(sqlq_or_null "$from"), 'running', ${now}, ${now});" >/dev/null \
    || fail "$E_GENERIC" "goal: could not record async job"

  # Optimistic fast-return: an idle planner likely runs the task at once, so poll
  # briefly and return the finished result inline (nicer UX, still far under any
  # gateway timeout). A busy planner returns the job id immediately.
  if _hb_agent_idle "$planner" >/dev/null 2>&1; then
    local waited=0 budget="${GOAL_ASYNC_OPTIMISTIC_SECS:-6}" ts
    while (( waited < budget )); do
      ts=$(db "SELECT COALESCE(status,'') FROM tasks WHERE id=${task_id};")
      [[ "$ts" == "done" || "$ts" == "rejected" || "$ts" == "escalated" || "$ts" == "cancelled" ]] && break
      sleep 2; waited=$(( waited + 2 ))
    done
    ts=$(db "SELECT COALESCE(status,'') FROM tasks WHERE id=${task_id};")
    if [[ "$ts" == "done" ]]; then _goal_job_advance "$loop_id"; return $?; fi
  fi

  local jstat="queued"; [[ "$(db "SELECT COALESCE(status,'') FROM tasks WHERE id=${task_id};")" == "in_progress" ]] && jstat="running"
  if (( JSON_MODE )); then
    ok "goal planning queued → job ${loop_id} (planner ${planner})" \
       '{job:$j, status:$s, planner:$p, taskIdent:$ti, dryRun:($dr=="1"), outcome:$o}' \
       --arg j "$loop_id" --arg s "$jstat" --arg p "$planner" --arg ti "$task_ident" --arg dr "$dr" --arg o "$outcome"
  else
    echo "Planning started — job ${loop_id} (planner ${planner}, ${jstat})."
    echo "Poll: 5dive goal status ${loop_id}"
  fi
}

# _goal_job_field <job_id> <column> — one goal_jobs column, '' if null/absent.
_goal_job_field() { db "SELECT COALESCE(${2},'') FROM goal_jobs WHERE job_id=$(sqlq "$1");"; }

# cmd_goal_status <job> — poll an async goal-add job. Emits queued | running |
# done (dryRun/gated/materialized) | failed.
cmd_goal_status() {
  tasks_db_init
  local job=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --job=*) job="${1#*=}" ;;
      -*)      fail "$E_USAGE" "unknown flag: $1" ;;
      *)       job="$1" ;;
    esac
    shift
  done
  [[ -n "$job" ]] || fail "$E_USAGE" "usage: 5dive goal status <job>"
  _goal_job_advance "$job"
}

# _goal_job_advance <job_id> — inspect the backing planner task and emit the job
# state. Once the plan lands, run _goal_finish_with_plan ONCE, caching the
# terminal envelope in goal_jobs.result_json so repeat polls are idempotent (a
# materialize happens exactly once). Shared by `goal status` and the optimistic
# fast-return path.
_goal_job_advance() {
  local job_id="$1"
  local exists; exists=$(db "SELECT 1 FROM goal_jobs WHERE job_id=$(sqlq "$job_id");")
  [[ "$exists" == "1" ]] || fail "$E_NOT_FOUND" "no goal job '$job_id' (pass the job id printed by 5dive goal add)"

  local jstatus; jstatus=$(_goal_job_field "$job_id" status)
  local planner; planner=$(_goal_job_field "$job_id" planner)

  # Terminal + cached -> replay verbatim (idempotent).
  if [[ "$jstatus" == "done" || "$jstatus" == "failed" ]]; then
    local cached; cached=$(_goal_job_field "$job_id" result_json)
    if [[ -n "$cached" ]]; then
      if (( JSON_MODE )); then printf '%s\n' "$cached"; else echo "job ${job_id}: ${jstatus}"; fi
      return 0
    fi
  fi

  local task_id loop_id; task_id=$(_goal_job_field "$job_id" task_id); loop_id=$(_goal_job_field "$job_id" loop_id)
  local tstatus; tstatus=$(db "SELECT COALESCE(status,'') FROM tasks WHERE id=${task_id};")

  # Failure guards (mirror loop spawn --wait): kill, ceiling, or a non-done
  # terminal backing-task state.
  local killed ceil spent
  killed=$(db "SELECT COALESCE(kill_requested,0) FROM loop_runs WHERE loop_id=$(sqlq "$loop_id");")
  ceil=$(_goal_job_field "$job_id" ceiling)
  spent=$(_loop_spent "$loop_id" 2>/dev/null || echo 0); [[ "$spent" =~ ^[0-9]+$ ]] || spent=0
  if [[ "$killed" == "1" ]] \
     || { [[ -n "$ceil" && "$ceil" =~ ^[0-9]+$ ]] && (( spent >= ceil )) && [[ "$tstatus" != "done" ]]; } \
     || [[ "$tstatus" == "escalated" || "$tstatus" == "rejected" || "$tstatus" == "cancelled" ]]; then
    local reason="planner did not return a plan (loop ${tstatus:-halted})"
    [[ "$killed" == "1" ]] && reason="planner loop was killed"
    { [[ -n "$ceil" && "$ceil" =~ ^[0-9]+$ ]] && (( spent >= ceil )); } && reason="planner hit its token ceiling (${spent}/${ceil}tok)"
    local payload
    payload=$(jq -cn --arg j "$job_id" --arg r "$reason" --arg p "$planner" '{ok:true, data:{job:$j, status:"failed", reason:$r, planner:$p}}')
    db "UPDATE goal_jobs SET status='failed', result_json=$(sqlq "$payload"), updated_at=$(date +%s) WHERE job_id=$(sqlq "$job_id");" >/dev/null 2>&1 || true
    db "UPDATE loop_runs SET status='escalated', updated_at=$(date +%s) WHERE loop_id=$(sqlq "$loop_id");" >/dev/null 2>&1 || true
    if (( JSON_MODE )); then printf '%s\n' "$payload"; else echo "job ${job_id}: FAILED — ${reason}"; fi
    return 0
  fi

  # Plan ready -> finish once.
  if [[ "$tstatus" == "done" ]]; then
    local plan; plan=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${task_id};")
    if [[ -z "$plan" ]] || ! printf '%s' "$plan" | jq -e . >/dev/null 2>&1; then
      local payload; payload=$(jq -cn --arg j "$job_id" --arg p "$planner" '{ok:true, data:{job:$j, status:"failed", reason:"planner returned an empty or invalid plan", planner:$p}}')
      db "UPDATE goal_jobs SET status='failed', result_json=$(sqlq "$payload"), updated_at=$(date +%s) WHERE job_id=$(sqlq "$job_id");" >/dev/null 2>&1 || true
      if (( JSON_MODE )); then printf '%s\n' "$payload"; else echo "job ${job_id}: FAILED — empty plan"; fi
      return 0
    fi
    # Claim the job so a finish that materializes runs exactly once. A prior
    # claim that never completed (poll process crashed/killed mid-finish) would
    # otherwise wedge the job in 'finishing' forever, so a stale claim
    # (updated_at older than GOAL_FINISH_STALE_SECS) is reclaimable — safe because
    # the dashboard's async path is dry-run (a pure re-render) and materialize is
    # dup-guarded.
    local nowc; nowc=$(date +%s)
    local stale=$(( nowc - ${GOAL_FINISH_STALE_SECS:-45} ))
    local claimed; claimed=$(db "UPDATE goal_jobs SET status='finishing', updated_at=${nowc} WHERE job_id=$(sqlq "$job_id") AND (status NOT IN ('done','failed','finishing') OR (status='finishing' AND updated_at <= ${stale})); SELECT changes();")
    if [[ "$claimed" != "1" ]]; then
      # Lost the race: another poll is finishing / has finished. Replay if cached,
      # else report running.
      local cached; cached=$(_goal_job_field "$job_id" result_json)
      if [[ -n "$cached" ]]; then if (( JSON_MODE )); then printf '%s\n' "$cached"; else echo "job ${job_id}: done"; fi; return 0; fi
      if (( JSON_MODE )); then ok "" '{job:$j, status:"running", planner:$p}' --arg j "$job_id" --arg p "$planner"; else echo "job ${job_id}: finishing…"; fi
      return 0
    fi
    local outcome project yes dry_run max_tasks depth_cap checkpoint from
    outcome=$(_goal_job_field "$job_id" outcome); project=$(_goal_job_field "$job_id" project)
    yes=$(_goal_job_field "$job_id" yes); [[ "$yes" == "1" ]] || yes=""
    dry_run=$(_goal_job_field "$job_id" dry_run); [[ "$dry_run" == "1" ]] || dry_run=""
    max_tasks=$(_goal_job_field "$job_id" max_tasks); depth_cap=$(_goal_job_field "$job_id" depth_cap)
    checkpoint=$(_goal_job_field "$job_id" checkpoint); from=$(_goal_job_field "$job_id" from_actor)
    # NB `env=$(...)` is guarded with `|| rc=$?` because header.sh runs the binary
    # under `set -e`: an unguarded substitution that exits non-zero would kill the
    # whole process here, wedging the job in 'finishing'. The `||` both captures
    # the exit code and disarms set -e.
    local env="" rc=0
    env=$(JSON_MODE=1 _goal_finish_with_plan "$plan" "$outcome" "$project" "$planner" "$max_tasks" "$depth_cap" "$checkpoint" "$yes" "$dry_run" "$from" 2>/dev/null) || rc=$?
    if (( rc != 0 )) || [[ -z "$env" ]] || [[ "$(printf '%s' "$env" | jq -r '.ok // false' 2>/dev/null)" != "true" ]]; then
      local emsg; emsg=$(printf '%s' "$env" | jq -r '.error.message // "plan finish failed"' 2>/dev/null); [[ -n "$emsg" ]] || emsg="plan finish failed"
      local payload; payload=$(jq -cn --arg j "$job_id" --arg r "$emsg" --arg p "$planner" '{ok:true, data:{job:$j, status:"failed", reason:$r, planner:$p}}')
      db "UPDATE goal_jobs SET status='failed', result_json=$(sqlq "$payload"), updated_at=$(date +%s) WHERE job_id=$(sqlq "$job_id");" >/dev/null 2>&1 || true
      if (( JSON_MODE )); then printf '%s\n' "$payload"; else echo "job ${job_id}: FAILED — ${emsg}"; fi
      return 0
    fi
    local payload; payload=$(printf '%s' "$env" | jq -c --arg j "$job_id" '{ok:true, data:({job:$j, status:"done"} + .data)}')
    db "UPDATE goal_jobs SET status='done', result_json=$(sqlq "$payload"), updated_at=$(date +%s) WHERE job_id=$(sqlq "$job_id");" >/dev/null 2>&1 || true
    db "UPDATE loop_runs SET status='done', updated_at=$(date +%s) WHERE loop_id=$(sqlq "$loop_id");" >/dev/null 2>&1 || true
    if (( JSON_MODE )); then printf '%s\n' "$payload"
    else echo "job ${job_id}: DONE"; printf '%s' "$env" | jq -r '.data | if .dryRun then "  planned "+(.taskCount|tostring)+" task(s)" elif .gated then "  gated on "+.anchor elif .materialized then "  materialized "+(.taskCount|tostring)+" task(s)" else "  done" end' 2>/dev/null; fi
    return 0
  fi

  # Still working: todo -> queued, in_progress -> running.
  local jstat="queued"; [[ "$tstatus" == "in_progress" ]] && jstat="running"
  db "UPDATE goal_jobs SET status=$(sqlq "$jstat"), updated_at=$(date +%s) WHERE job_id=$(sqlq "$job_id") AND status NOT IN ('done','failed','finishing');" >/dev/null 2>&1 || true
  if (( JSON_MODE )); then
    ok "" '{job:$j, status:$s, planner:$p}' --arg j "$job_id" --arg s "$jstat" --arg p "$planner"
  else
    echo "job ${job_id}: ${jstat} (planner ${planner})"
  fi
}

# ------- create-from-preview: _goal_from_job <job_id> <from> -------
# DIVE-1349: materialize (or gate) the plan a preview job already computed. The
# plan is recovered from the job's backing planner task, RE-VALIDATED from
# scratch (never trust a stored blob), and finished with dry-run forced OFF using
# the job's stored guardrail params. Same human-gate semantics as a direct
# create: a T2 / over-checkpoint plan files ONE decision gate and materializes
# nothing. Reuses the previewed plan so the dashboard "Create plan" button sends
# only a small job id, not the (tunnel-oversized) plan JSON.
_goal_from_job() {
  local job_id="$1" from_override="$2"
  local exists; exists=$(db "SELECT 1 FROM goal_jobs WHERE job_id=$(sqlq "$job_id");")
  [[ "$exists" == "1" ]] || fail "$E_NOT_FOUND" "no goal job '$job_id' (pass the job id from the preview)"
  local task_id; task_id=$(_goal_job_field "$job_id" task_id)
  local plan; plan=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${task_id};")
  printf '%s' "$plan" | jq -e . >/dev/null 2>&1 \
    || fail "$E_VALIDATION" "job '$job_id' has no plan yet — poll 5dive goal status $job_id until done, then create"
  local outcome project yes max_tasks depth_cap checkpoint planner from
  outcome=$(_goal_job_field "$job_id" outcome);   project=$(_goal_job_field "$job_id" project)
  yes=$(_goal_job_field "$job_id" yes); [[ "$yes" == "1" ]] || yes=""
  max_tasks=$(_goal_job_field "$job_id" max_tasks); depth_cap=$(_goal_job_field "$job_id" depth_cap)
  checkpoint=$(_goal_job_field "$job_id" checkpoint); planner=$(_goal_job_field "$job_id" planner)
  from="${from_override:-$(_goal_job_field "$job_id" from_actor)}"
  _goal_finish_with_plan "$plan" "$outcome" "$project" "$planner" "$max_tasks" "$depth_cap" "$checkpoint" "$yes" "" "$from"
}
