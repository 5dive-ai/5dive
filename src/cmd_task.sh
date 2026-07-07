
# -------- 5dive task — host-shared task queue --------

_task_usage() {
  cat <<USAGE
5dive task — shared task queue (sqlite at ${STATE_DIR}/tasks/tasks.db)

  5dive task init                                    # one-time root bootstrap of the store
  5dive task add <title...> [--body=<text>] [--priority=low|medium|high|urgent]
                            [--assignee=<agent|role:<r>|charter:<kw>>] [--parent=<id|DIVE-N>] [--from=<who>]
                                                     # --assignee token routes via the org chart (DIVE-980); omit = org lead/coordinator
                            [--recurring="<cron>"]  # recurring=template (5-field cron, e.g. "0 2 * * *")
                            [--accept=<criteria>] [--verify=<cmd>] [--max-iters=<n>] [--verifier=<agent>] [--no-verify]
                                                     # DIVE-969: non-trivial tasks are verifier-graded BY DEFAULT (a grader
                                                     # !=maker + derived acceptance criteria). --no-verify opts out (plain
                                                     # 'task done' closes). Trivial/low-priority chores skip it automatically.
                            [--task-budget=<tokens|\$cost>]  # per-run spend cap for the on-host loop (DIVE-824)
                                                     # loop spec: declarative verify loop (DIVE-476). --verify is
                                                     # the default cmd for `task verify`; --verifier grades (writer!=grader)
  5dive task ls [--status=<s>] [--assignee=<agent>] [--mine] [--all] [--recurring]
                                                     # default: open tasks, priority-ordered; --recurring: templates
  5dive task show <id|DIVE-N>                        # full detail + subtasks + blockers
  5dive task assign <id|DIVE-N> <agent>
  5dive task start  <id|DIVE-N>                      # -> in_progress
  5dive task done   <id|DIVE-N> [--result=<text>]    # -> done; --result captures the agent's response
  5dive task verify <id|DIVE-N> [--cmd="<command>"] [--no-done] [--timeout=<s>]
                                                     # run a check; exit 0 => proven-done (flips to done,
                                                     # captures output tail). Verb exits 0/1 = the verdict.
                                                     # --cmd optional: falls back to the task's stored --verify command.
  5dive task reject <id|DIVE-N> [--feedback="<what to fix>"]
                                                     # verifier's FAIL verdict (DIVE-477): bounce back to the maker
                                                     # for another pass, or escalate to a human at max_iterations.
  5dive task loops [--stuck] [--all] [--escalate-stuck] [--runs] [--watch[=secs]] [--kill <loopId>]
                                                     # observability (DIVE-478/597): maker→verifier board + LOOP-7
                                                     # loop_runs control window (topology/stage/iter/tokens-ceiling/
                                                     # status/⚠stuck). --runs=only loop_runs; --watch repaints;
                                                     # --kill flips kill_requested (deferred-safe). Cost: `usage loops`.
                                                     # Tokens/cost per loop: see `5dive usage` (same task ids).
  5dive task cancel <id|DIVE-N> [--result=<text>]    # -> cancelled; --result captures why
  5dive task block   <id|DIVE-N> --by=<id|DIVE-N>    # add a blocks edge, mark blocked
  5dive task unblock <id|DIVE-N> [--by=<id|DIVE-N>]  # drop edge(s); back to todo if clear
  5dive task rm <id|DIVE-N>                          # delete (cascades subtasks + edges)
  5dive task escalate <id|DIVE-N> [--from=<who>]     # flag for attention: bump priority a tier (cap urgent) + ping owning agent & paired human

  # Human Task Inbox — park a task on a human and clear it
  5dive task need <id|DIVE-N> --type=decision|secret|approval|manual --ask="..." [--options=A|B] [--recommend="A"] [--tier=0|1|2]
    --ask: ONE crisp question + ~1 line essential context, recommendation up front. Heavy detail goes in the task BODY, not the ask.
    --recommend: your advised choice (strongly encouraged for decision/approval). Leads the alert as '✅ Recommended: <X>' and ⭐-marks its button. For a decision it must match one of --options.
    --tier (DIVE-891 risk tiers): 0 = auto-clear (rec applies NOW, no ping, digest line; requires --recommend)
             1 = agent-clearable; unanswered 48h -> the heartbeat applies the rec   2 = hard human gate (default for approval/secret/manual)
             Money, public comms, secrets, destructive and brand asks are FLOORED to tier 2 no matter what you pass; secret is always tier 2.
                                                     # -> blocked, awaiting a human (decision/secret/approval/manual)
  5dive task park <id|DIVE-N> --reason="..." [--wake=<YYYY-MM-DD[ HH:MM]|+Nd|+Nh>]
                                                     # QUIET wait (no ping, not in the inbox); --wake auto-unparks
                                                     # back to todo when the time passes (heartbeat sweep, DIVE-891)
  5dive task unpark <id|DIVE-N>                      # clear a park early -> todo (unless task-deps still block it)
  5dive task inbox                                   # list ONLY human-gated tasks, priority-ordered
  5dive task answer <id|DIVE-N> --value="..."        # record the human's answer, unblock, ping the owning agent
                                                     # approval/secret gates are human-only: blocked for agent-* callers,
                                                     # and (DIVE-519) require --proof=<token from `5dive gate-proof`> once
                                                     # `5dive gate-proof enforce on` is set. Trusted paths attach it automatically.

  status: todo | in_progress | blocked | done | cancelled

  Maker→verifier loop (DIVE-477): give a task a --verifier (≠ its assignee) and the
  maker's 'task done' does NOT close it — it hands off to the verifier (re-queued as
  their todo; the heartbeat wakes them). The verifier grades against acceptance_criteria
  / runs 'task verify', then closes it ('task done', which closes for real since
  verifier==assignee) on PASS or 'task reject --feedback=' on FAIL (bounce back to the
  maker, or escalate to a human at max_iterations). Writer never grades itself.

  Any agent (group claude) can run these without sudo. Add --json for machine output.
USAGE
}

cmd_task() {
  [[ $# -gt 0 ]] || { _task_usage; exit "$E_USAGE"; }
  local sub="$1"; shift
  case "$sub" in
    init)            cmd_task_init "$@" ;;
    add|new)         cmd_task_add "$@" ;;
    ls|list)         cmd_task_ls "$@" ;;
    show|view)       cmd_task_show "$@" ;;
    assign)          cmd_task_assign "$@" ;;
    start)           cmd_task_start "$@" ;;
    done|close)      cmd_task_done "$@" ;;
    verify)          cmd_task_verify "$@" ;;
    reject)          cmd_task_reject "$@" ;;
    loop)            cmd_task_loop "$@" ;;
    loops)           cmd_task_loops "$@" ;;
    cancel)          cmd_task_cancel "$@" ;;
    block)           cmd_task_block "$@" ;;
    unblock)         cmd_task_unblock "$@" ;;
    park)            cmd_task_park "$@" ;;
    unpark)          cmd_task_unpark "$@" ;;
    escalate)        cmd_task_escalate "$@" ;;
    need)            cmd_task_need "$@" ;;
    inbox)           cmd_task_inbox "$@" ;;
    answer)          cmd_task_answer "$@" ;;
    rm|delete)       cmd_task_rm "$@" ;;
    -h|--help|help)  _task_usage ;;
    *) fail "$E_USAGE" "unknown task command: $sub (try: 5dive task --help)" ;;
  esac
}

cmd_task_init() {
  require_root "task init"
  tasks_db_init
  ok "tasks store ready at $TASKS_DB" '{path:$p}' --arg p "$TASKS_DB"
}

# Resolve the task-queue coordinator (DIVE-333): the agent who owns unassigned
# tasks so they don't stall (the heartbeat only wakes an assignee). Org-agnostic,
# resolved live from the org chart — never a hardcoded agent:
#   1. an agent explicitly tagged `--role=coordinator` (reuses the existing org
#      role field; the disambiguator a multi-root org sets), when exactly one holds it
#   2. else the lone org root (the single-CEO case — zero config)
#   3. else empty — ambiguous (multi-root, none tagged) or empty org chart; we
#      leave the task unassigned exactly as before rather than guess wrong.
# Prints the coordinator name (or nothing). Safe on an empty/missing org table.
_task_resolve_coordinator() {
  if [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE role='coordinator';")" == "1" ]]; then
    db "SELECT name FROM agents_org WHERE role='coordinator' LIMIT 1;"
    return
  fi
  if [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE reports_to IS NULL OR reports_to NOT IN (SELECT name FROM agents_org);")" == "1" ]]; then
    db "SELECT name FROM agents_org WHERE reports_to IS NULL OR reports_to NOT IN (SELECT name FROM agents_org) LIMIT 1;"
  fi
}

# DIVE-969: verifier-by-default posture (Karpathy autonomy slider). Non-trivial
# work should get graded by someone other than the maker (writer!=grader,
# DIVE-474/477) UNLESS the creator explicitly opts out. These two helpers decide
# WHEN the default engages and WHO grades — deliberately conservative so trivial
# tasks stay frictionless and we never block an add.

# Is this task trivial enough to skip the verifier default? Trivial = low-signal
# work where a grading round-trip is pure overhead: low priority, OR a bodyless
# task whose title reads as a mechanical chore (typo/bump/rename/docs/lint/…).
# Anything with a real body or medium+ priority is treated as non-trivial.
_task_is_trivial() {
  local _title="$1" _body="$2" _priority="$3"
  [[ "$_priority" == "low" ]] && return 0
  if [[ -z "$_body" ]]; then
    local t="${_title,,}"
    [[ "$t" =~ (^|[^a-z])(typo|typos|bump|rename|tweak|nit|nits|lint|format|reformat|comment|comments|whitespace|changelog|readme|docs|doc|wording|copy[[:space:]]fix|version[[:space:]]bump)([^a-z]|$) ]] && return 0
  fi
  return 1
}

# Resolve the lone org root (the single top of the chart — reports_to NULL or a
# dangling manager). Prints the name, or nothing when the org is empty or has
# more than one root (ambiguous — never guess). Mirrors the coordinator's
# lone-root fallback but is exposed on its own so the grader chain can try it
# even in an org that DOES tag a distinct role='coordinator'.
_task_resolve_org_root() {
  [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE reports_to IS NULL OR reports_to NOT IN (SELECT name FROM agents_org);")" == "1" ]] || return
  db "SELECT name FROM agents_org WHERE reports_to IS NULL OR reports_to NOT IN (SELECT name FROM agents_org) LIMIT 1;"
}

# Resolve the org's designated technical deputy — the lone agent whose role or
# title marks them as a CTO / chief-technology / deputy — excluding $1 (the
# maker). This is the grader of last resort for the root/CEO's OWN work: when a
# task auto-coordinates to the lone-root coordinator, the maker IS the top of
# the chart with no manager above, so the chain would otherwise give up. The
# match is a leading-space-anchored keyword scan (so "CTO" matches but "factory"
# does not) and must be UNIQUE — >1 candidate is ambiguous and yields nothing.
_task_resolve_deputy() {
  local _skip="$1"
  local _pred="( lower(' '||COALESCE(role,'')||' '||COALESCE(title,'')) LIKE '% cto%'
                 OR lower(' '||COALESCE(role,'')||' '||COALESCE(title,'')) LIKE '% chief technolog%'
                 OR lower(' '||COALESCE(role,'')||' '||COALESCE(title,'')) LIKE '% deputy%' )
               AND name <> $(sqlq "$_skip")"
  [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE ${_pred};")" == "1" ]] || return
  db "SELECT name FROM agents_org WHERE ${_pred} LIMIT 1;"
}

# Pick a grader distinct from the maker (assignee) — a maker can't grade itself
# (DIVE-474). DIVE-969 established the verifier-by-default posture; DIVE-989
# widens WHO can grade so the default no longer silently no-ops when a task
# auto-coordinates TO the coordinator (maker==coordinator — the common
# default-project case where the lone-root CEO owns all unassigned work). We
# walk an ordered chain of DISTINCT candidates and take the FIRST that exists
# and differs from the maker:
#   1. project lead   — the task's own project owner
#   2. coordinator    — the queue owner (role=coordinator, else the lone root)
#   3. maker's manager — reports_to: the maker's natural up-reviewer
#   4. org root        — the lone top of the chart
#   5. technical deputy — the org's designated CTO/deputy, so the root/CEO's own
#                         work still gets a distinct grader
# The silent no-op survives ONLY when none of these yields a distinct agent (a
# genuinely solo org, or nobody but the maker anywhere). Prints the grader name.
_task_default_verifier() {
  local _assignee="$1" _proj_lead="$2" c=""
  local -a cands=(
    "$_proj_lead"
    "$(_task_resolve_coordinator)"
    "$(db "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$_assignee") LIMIT 1;")"
    "$(_task_resolve_org_root)"
    "$(_task_resolve_deputy "$_assignee")"
  )
  for c in "${cands[@]}"; do
    if [[ -n "$c" && "$c" != "$_assignee" ]]; then
      printf '%s' "$c"; return
    fi
  done
}

# DIVE-980: shared org-chart assignee resolution. Resolve an assignee TOKEN to a
# concrete agent via the org chart (agents_org). Prints the resolved name, or
# NOTHING when a role/charter token has no UNIQUE holder — callers decide whether
# that empty is a hard error (task add) or a fall-through (goal validate).
# Deterministic + explainable: a role/charter routes ONLY on an unambiguous
# single match; >1 holder or unknown -> empty (never guess which one).
#   @name / bare name  -> taken as-is (explicit override; never re-routed)
#   role:<r>           -> the lone agents_org holder whose role == <r> (ci)
#   charter:<kw>       -> the lone holder whose title (charter) contains <kw> (ci)
# Safe on an empty/missing org table (COUNT != 1 -> empty).
_org_resolve_assignee() {
  local v="${1#@}"
  case "$v" in
    role:*)
      local r="${v#role:}"
      [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE role IS NOT NULL AND lower(role)=lower($(sqlq "$r"));" 2>/dev/null)" == "1" ]] || { printf ''; return; }
      db "SELECT name FROM agents_org WHERE role IS NOT NULL AND lower(role)=lower($(sqlq "$r")) LIMIT 1;"
      ;;
    charter:*)
      local kw="${v#charter:}"
      [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE title IS NOT NULL AND lower(title) LIKE '%'||lower($(sqlq "$kw"))||'%';" 2>/dev/null)" == "1" ]] || { printf ''; return; }
      db "SELECT name FROM agents_org WHERE title IS NOT NULL AND lower(title) LIKE '%'||lower($(sqlq "$kw"))||'%' LIMIT 1;"
      ;;
    *)
      printf '%s' "$v"
      ;;
  esac
}

cmd_task_add() {
  tasks_db_init
  local body="" priority="medium" assignee="" parent="" from="" recurring="" fresh="" project="dive"
  local accept="" verify_cmd="" max_iters="" verifier="" task_budget="" no_verify=""
  local -a words=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --body=*)      body="${1#*=}" ;;
      --priority=*)  priority="${1#*=}" ;;
      --assignee=*)  assignee="${1#*=}" ;;
      --parent=*)    parent="${1#*=}" ;;
      --project=*)   project="${1#*=}" ;;
      --from=*)      from="${1#*=}" ;;
      --recurring=*) recurring="${1#*=}" ;;
      --schedule=*)  recurring="${1#*=}" ;;
      --fresh)       fresh="1" ;;
      --no-fresh)    fresh="0" ;;
      # DIVE-476: loop-spec — declarative verify loop persisted on the row so the
      # (c) verify-runner reads its inputs off the task instead of re-passing them.
      --accept=*)    accept="${1#*=}" ;;
      --verify=*)    verify_cmd="${1#*=}" ;;
      --max-iters=*) max_iters="${1#*=}" ;;
      --verifier=*)  verifier="${1#*=}" ;;
      # DIVE-969: explicit opt-out of the verifier-by-default posture. A plain
      # `task done` closes the resulting task directly (no maker→grader handoff).
      --no-verify)   no_verify="1" ;;
      # DIVE-824: per-run spend cap carried on the row (sibling to verify --timeout).
      # Value is either a bare token count or a "$cost" dollar figure.
      --task-budget=*) task_budget="${1#*=}" ;;
      --)            shift; words+=("$@"); break ;;
      -*)            fail "$E_USAGE" "unknown flag: $1" ;;
      *)             words+=("$1") ;;
    esac
    shift
  done
  local title="${words[*]:-}"
  [[ -n "$title" ]] || fail "$E_USAGE" "usage: 5dive task add <title...> [--body=] [--priority=] [--assignee=] [--parent=] [--project=<key>] [--recurring=\"<cron>\"] [--task-budget=<tokens|\$cost>]"
  valid_task_priority "$priority" || fail "$E_VALIDATION" "bad priority '$priority' (low|medium|high|urgent)"
  # DIVE-476: --max-iters is the maker→verifier loop cap; must be a positive int.
  [[ -z "$max_iters" || "$max_iters" =~ ^[1-9][0-9]*$ ]] \
    || fail "$E_VALIDATION" "--max-iters must be a positive integer"
  # DIVE-824: --task-budget is EITHER a bare token count ("50000") OR a dollar
  # cost ("$1.50" / "$2"). Reject anything else so a malformed cap can't silently
  # store as a no-op. Stored verbatim; the loop runner interprets the form.
  [[ -z "$task_budget" || "$task_budget" =~ ^[1-9][0-9]*$ || "$task_budget" =~ ^\$[0-9]+(\.[0-9]+)?$ ]] \
    || fail "$E_VALIDATION" "--task-budget must be a token count (e.g. 50000) or a dollar cost (e.g. \$1.50)"
  # --recurring=<cron> makes this a TEMPLATE (kind='recurring'), not a worked
  # task — the step-2 materializer clones it into a standard todo on schedule.
  # A template + an explicit --parent is nonsensical (instances are top-level),
  # so reject the combo rather than store a confusing row.
  local kind="standard" schedule_sql="NULL"
  if [[ -n "$recurring" ]]; then
    valid_cron_expr "$recurring" || fail "$E_VALIDATION" "bad --recurring '$recurring' (need a 5-field cron expr, e.g. \"0 2 * * *\")"
    [[ -z "$parent" ]] || fail "$E_VALIDATION" "--recurring can't be combined with --parent (a template has no parent)"
    kind="recurring"; schedule_sql=$(sqlq "$recurring")
  fi
  # DIVE-484: resolve the target project (default 'dive'). Accept the key
  # case-insensitively; the row must exist (create one with `5dive project add`).
  project="${project,,}"
  local proj_lead
  proj_lead=$(db "SELECT COALESCE(lead_agent,'') FROM projects WHERE key=$(sqlq "$project") AND status='active';")
  if [[ -z "$proj_lead" ]]; then
    db "SELECT 1 FROM projects WHERE key=$(sqlq "$project") AND status='active';" | grep -q 1 \
      || fail "$E_NOT_FOUND" "no active project '$project' (see: 5dive project ls; create: 5dive project add)"
  fi
  local parent_sql="NULL"
  if [[ -n "$parent" ]]; then
    resolve_task_id "$parent"; parent_sql="$RESOLVED_TASK_ID"
  fi
  # DIVE-980: an explicit --assignee may be a literal agent name OR an org-chart
  # TOKEN (role:<r> / charter:<kw> / @name). Route tokens through the org chart;
  # a literal name is trusted verbatim (explicit --assignee always wins). A token
  # with no UNIQUE holder is a hard, EXPLAINABLE error — never a silent misroute.
  if [[ -n "$assignee" ]]; then
    case "$assignee" in
      role:*|charter:*|@*)
        local _resolved; _resolved=$(_org_resolve_assignee "$assignee")
        [[ -n "$_resolved" ]] || fail "$E_NOT_FOUND" "--assignee='$assignee' has no unique holder in the org chart (see: 5dive org ls) — assign by explicit agent name, or place/disambiguate the role with 5dive org set"
        assignee="$_resolved"
        ;;
    esac
  fi
  # fresh: per-task clean-session pref (DIVE-138). Recurring templates default to
  # fresh=1 (clean each run — Mark's decision for the community/marketing jobs)
  # and carry it onto every materialized instance; an explicit --fresh/--no-fresh
  # overrides. Standard tasks leave it NULL (fall back to the agent-level
  # heartbeat fresh setting at wake).
  local fresh_sql="NULL"
  if [[ -n "$fresh" ]]; then fresh_sql="$fresh"
  elif [[ "$kind" == "recurring" ]]; then fresh_sql="1"; fi
  # DIVE-333: an unassigned STANDARD task stalls — the heartbeat only wakes an
  # assignee. Default it to the org's coordinator so it always has an owner.
  # Recurring TEMPLATES stay unassigned (they're inert until materialized; the
  # instance gets coordinated when it's cloned as a standard task).
  # DIVE-333 + DIVE-484: default an unassigned standard task to a coordinator so
  # the heartbeat can wake an owner. Prefer the PROJECT's own lead_agent; fall
  # back to the org-wide coordinator when the project has none.
  local auto_coordinated=0
  if [[ -z "$assignee" && "$kind" == "standard" ]]; then
    assignee="$proj_lead"
    [[ -z "$assignee" ]] && assignee=$(_task_resolve_coordinator)
    [[ -n "$assignee" ]] && auto_coordinated=1
  fi
  # DIVE-969: verifier-by-default posture. For a NON-TRIVIAL standard task where
  # the creator neither wired the loop themselves (--accept/--verify/--verifier)
  # nor opted out (--no-verify), engage grading by default: derive acceptance
  # criteria from the title and assign a grader distinct from the maker. Trivial
  # chores, recurring templates, low priority, and explicit opt-outs are left
  # untouched so the common cheap case stays frictionless. If no distinct grader
  # exists (e.g. a solo org, or the only coordinator IS the assignee) the default
  # silently no-ops rather than blocking the add. Env kill-switch for the fleet:
  # FIVE_VERIFY_DEFAULT=0.
  local verify_defaulted=0
  if [[ "$kind" == "standard" && -z "$no_verify" && "${FIVE_VERIFY_DEFAULT:-1}" != "0" \
        && -z "$accept" && -z "$verify_cmd" && -z "$verifier" ]] \
     && ! _task_is_trivial "$title" "$body" "$priority"; then
    local _grader; _grader=$(_task_default_verifier "$assignee" "$proj_lead")
    if [[ -n "$_grader" ]]; then
      verifier="$_grader"
      accept="Deliverable meets the intent of: ${title}. Maker records in the done result WHAT was built and HOW it was checked; ${_grader} confirms against this before the task closes (refine these criteria as the work firms up)."
      verify_defaulted=1
    fi
  fi
  local creator; creator=$(task_actor "$from")
  local id
  id=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, parent_id, project_key, kind, schedule, fresh,
                              acceptance_criteria, verify_command, max_iterations, verifier, task_budget)
           VALUES ($(sqlq "$title"), $(sqlq_or_null "$body"), $(sqlq "$priority"),
                   $(sqlq_or_null "$assignee"), $(sqlq "$creator"), ${parent_sql}, $(sqlq "$project"),
                   $(sqlq "$kind"), ${schedule_sql}, ${fresh_sql},
                   $(sqlq_or_null "$accept"), $(sqlq_or_null "$verify_cmd"), ${max_iters:-NULL}, $(sqlq_or_null "$verifier"), $(sqlq_or_null "$task_budget"));
           SELECT last_insert_rowid();")
  # Ident is stamped by the AFTER INSERT trigger from the project's counter, so
  # read it back rather than assuming the DIVE- prefix (DIVE-484).
  local ident; ident=$(db "SELECT ident FROM tasks WHERE id=${id};")
  if [[ "$kind" == "recurring" ]]; then
    ok "created recurring ${ident} (${recurring}, fresh=$([[ "$fresh_sql" == "1" ]] && echo on || echo off)) — $title" \
       '{id:($i|tonumber), ident:$id, project:$pr, title:$t, priority:$p, assignee:$a, created_by:$c, kind:"recurring", schedule:$s, fresh:($f=="1")}' \
       --arg i "$id" --arg id "$ident" --arg pr "$project" --arg t "$title" --arg p "$priority" --arg a "${assignee:-}" --arg c "$creator" --arg s "$recurring" --arg f "$fresh_sql"
  else
    local coord_note=""
    (( auto_coordinated )) && coord_note=" → coordinator: $assignee"
    local verify_note=""
    (( verify_defaulted )) && verify_note=" · verifier-graded by default → $verifier ('task done' hands off to grade; refine with --accept/--verify, or opt out with --no-verify)"
    ok "created ${ident} — $title${coord_note}${verify_note}" \
       '{id:($i|tonumber), ident:$id, project:$pr, title:$t, priority:$p, assignee:$a, created_by:$c, kind:"standard", autoCoordinated:($ac=="1"), verifyDefaulted:($vd=="1"), verifier:$v}' \
       --arg i "$id" --arg id "$ident" --arg pr "$project" --arg t "$title" --arg p "$priority" --arg a "${assignee:-}" --arg c "$creator" --arg ac "$auto_coordinated" --arg vd "$verify_defaulted" --arg v "${verifier:-}"
  fi
}

cmd_task_ls() {
  tasks_db_init
  local status="" assignee="" mine=0 all=0 from="" recurring=0 project=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status=*)   status="${1#*=}" ;;
      --assignee=*) assignee="${1#*=}" ;;
      --project=*)  project="${1#*=}" ;;
      --mine)       mine=1 ;;
      --all)        all=1 ;;
      --recurring)  recurring=1 ;;
      --from=*)     from="${1#*=}" ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ $mine -eq 1 ]] && assignee=$(task_actor "$from")
  # --recurring lists the TEMPLATES (kind='recurring') with their schedule;
  # otherwise we list real work and always exclude templates (they're never
  # worked directly, so they'd be noise in the board).
  local where="1=1" order
  if (( recurring )); then
    where+=" AND kind='recurring'"
    order="ORDER BY id"
  else
    where+=" AND kind='standard'"
    if [[ -n "$status" ]]; then
      valid_task_status "$status" || fail "$E_VALIDATION" "bad status '$status' (todo|in_progress|blocked|done|cancelled)"
      where+=" AND status=$(sqlq "$status")"
    elif [[ $all -ne 1 ]]; then
      where+=" AND status NOT IN ('done','cancelled')"
    fi
    order="ORDER BY CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END, created_at"
  fi
  [[ -n "$assignee" ]] && where+=" AND assignee=$(sqlq "$assignee")"
  # DIVE-484: scope to one project by key (case-insensitive).
  [[ -n "$project" ]] && where+=" AND project_key=$(sqlq "${project,,}")"
  if (( JSON_MODE )); then
    local rows
    # DIVE-583: emit project_key natively so the dashboard keys off a real field
    # (join name/prefix/lead from `project ls`) instead of deriving project from
    # the ident prefix client-side (fragile; couples to naming + the id≠ident bug).
    rows=$(dbfmt -json "SELECT id, ident, title, status, priority, assignee, created_by, parent_id, created_at, done_at, body, result, need_type, ask, need_options, recommend, precedent_ref, need_answer, need_answered_at, need_answered_by, tier, kind, schedule, last_fired_at, parked_at, park_reason, wake_at, project_key FROM tasks WHERE ${where} ${order};")
    [[ -n "$rows" ]] || rows="[]"
    # Feed rows via stdin, not --argjson: a big board (179+ tasks w/ bodies)
    # blows past MAX_ARG_STRLEN (128K per argv string) -> execve E2BIG
    # ("Argument list too long"). stdin has no such cap. (DIVE-222)
    printf '%s' "$rows" | jq -c '{ok:true, data:{tasks:.}}'
  elif (( recurring )); then
    dbfmt -box "SELECT ident, schedule, COALESCE(assignee,'-') AS assignee, COALESCE(last_fired_at,'never') AS last_fired, title FROM tasks WHERE ${where} ${order};"
  else
    dbfmt -box "SELECT ident, status, priority, COALESCE(assignee,'-') AS assignee, title FROM tasks WHERE ${where} ${order};"
  fi
}

cmd_task_show() {
  tasks_db_init
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task show <id|DIVE-N>"
  resolve_task_id "$1"; local id="$RESOLVED_TASK_ID"
  if (( JSON_MODE )); then
    local task subs deps
    task=$(dbfmt -json "SELECT * FROM tasks WHERE id=${id};")
    subs=$(dbfmt -json "SELECT id,ident,title,status FROM tasks WHERE parent_id=${id} ORDER BY id;")
    deps=$(dbfmt -json "SELECT t.id,t.ident,t.title,t.status FROM task_deps d JOIN tasks t ON t.id=d.blocked_by WHERE d.task_id=${id} ORDER BY t.id;")
    [[ -n "$subs" ]] || subs="[]"
    [[ -n "$deps" ]] || deps="[]"
    jq -cn --argjson t "$task" --argjson s "$subs" --argjson b "$deps" \
      '{ok:true, data:{task:($t[0]), subtasks:$s, blocked_by:$b}}'
  else
    dbfmt -line "SELECT ident, title, status, priority, assignee, created_by, parent_id, created_at, started_at, done_at, body, result FROM tasks WHERE id=${id};"
    # DIVE-1064: surface the creator's isolation tier (read-time from the
    # registry, no schema change) so a reader/agent can down-trust a task filed
    # by a lower-privilege peer. Shown only when the creator is a known agent.
    local _cb _ctier=""
    _cb=$(db "SELECT COALESCE(created_by,'') FROM tasks WHERE id=${id};")
    [[ -n "$_cb" ]] && _ctier="$(registry_read | jq -r --arg n "$_cb" '.agents[$n].isolation // empty' 2>/dev/null)"
    [[ -n "$_ctier" ]] && printf 'created_by_tier = %s
' "$_ctier"
    # Human gate (only when set) — mirrors the conditional subtasks/blockers
    # blocks below so an ordinary task's `show` stays clean.
    local gate
    gate=$(db "SELECT 'type: '||need_type||
                      CASE WHEN tier IS NOT NULL THEN '  (tier '||tier||')' ELSE '' END||
                      CASE WHEN need_options IS NOT NULL THEN '  options: '||need_options ELSE '' END||
                      CASE WHEN recommend IS NOT NULL THEN x'0a'||'recommend: '||recommend ELSE '' END||
                      CASE WHEN precedent_ref IS NOT NULL
                           THEN x'0a'||'precedent: '||COALESCE((SELECT ident FROM tasks p WHERE p.id=tasks.precedent_ref),'#'||precedent_ref) ELSE '' END||x'0a'||
                      'ask:  '||COALESCE(ask,'')||
                      CASE WHEN need_answered_at IS NOT NULL
                           THEN x'0a'||'answer: '||CASE WHEN need_type='secret' THEN '(provided — loaded out-of-band)' ELSE COALESCE(need_answer,'') END||'  ('||need_answered_at||')'
                           ELSE x'0a'||'answer: — pending' END
               FROM tasks WHERE id=${id} AND need_type IS NOT NULL;")
    [[ -n "$gate" ]] && { echo; echo "human gate:"; printf '%s\n' "$gate" | indent2; }
    # DIVE-476: loop spec (only when any field is set) — the declarative verify
    # loop the (c) runner executes. Mirrors the conditional human-gate block.
    local loopspec
    loopspec=$(db "SELECT
        CASE WHEN acceptance_criteria IS NOT NULL THEN 'acceptance_criteria: '||acceptance_criteria||x'0a' ELSE '' END||
        CASE WHEN verify_command      IS NOT NULL THEN 'verify_command: '||verify_command||x'0a' ELSE '' END||
        CASE WHEN max_iterations      IS NOT NULL THEN 'max_iterations: '||max_iterations||x'0a' ELSE '' END||
        CASE WHEN task_budget         IS NOT NULL THEN 'task_budget: '||task_budget||x'0a' ELSE '' END||
        CASE WHEN verifier            IS NOT NULL THEN 'verifier: '||verifier||x'0a' ELSE '' END||
        CASE WHEN maker_agent         IS NOT NULL THEN 'maker: '||maker_agent||x'0a' ELSE '' END||
        CASE WHEN iteration           IS NOT NULL THEN 'iteration: '||iteration ELSE '' END
      FROM tasks WHERE id=${id}
        AND (acceptance_criteria IS NOT NULL OR verify_command IS NOT NULL
             OR max_iterations IS NOT NULL OR verifier IS NOT NULL OR task_budget IS NOT NULL
             OR maker_agent IS NOT NULL OR iteration IS NOT NULL);")
    [[ -n "$loopspec" ]] && { echo; echo "loop spec:"; printf '%s\n' "$loopspec" | sed -e 's/[[:space:]]*$//' | indent2; }
    local subs
    subs=$(db "SELECT ident||'  ['||status||']  '||title FROM tasks WHERE parent_id=${id} ORDER BY id;")
    [[ -n "$subs" ]] && { echo; echo "subtasks:"; printf '%s\n' "$subs" | indent2; }
    local deps
    deps=$(db "SELECT t.ident||'  ['||t.status||']  '||t.title FROM task_deps d JOIN tasks t ON t.id=d.blocked_by WHERE d.task_id=${id} ORDER BY t.id;")
    [[ -n "$deps" ]] && { echo; echo "blocked by:"; printf '%s\n' "$deps" | indent2; }
  fi
}

cmd_task_assign() {
  tasks_db_init
  [[ $# -ge 2 ]] || fail "$E_USAGE" "usage: 5dive task assign <id|DIVE-N> <agent>"
  resolve_task_id "$1"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  local who="$2"
  # Handing a task to a NEW owner resets its in_progress clock: SQLite evaluates
  # SET column refs against the pre-update row, so `assignee IS NOT <who>` is the
  # OLD assignee. Without this, an inherited in_progress task keeps the prior
  # owner's started_at, and the heartbeat stale-reaper (_hb_reap_stale) can
  # cancel it on the new owner's very first tick before they touch it.
  db "UPDATE tasks SET assignee=$(sqlq "$who"),
        started_at=CASE WHEN status='in_progress' AND assignee IS NOT $(sqlq "$who")
                        THEN datetime('now') ELSE started_at END
      WHERE id=${id};"
  ok "$ident assigned to $who" '{id:($i|tonumber), ident:$id, assignee:$a}' --arg i "$id" --arg id "$ident" --arg a "$who"
}

_task_status_cmd() {
  local newstatus="$1" extra="$2" verb="$3"; shift 3
  tasks_db_init
  local result="" want_result=0 notify=0
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --result=*) result="${1#*=}"; want_result=1 ;;
      --notify)   notify=1 ;;
      --)         shift; positional+=("$@"); break ;;
      -*)         fail "$E_USAGE" "unknown flag: $1" ;;
      *)          positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task $verb <id|DIVE-N> [--result=<text>] [--notify]"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  # DIVE-477: maker→verifier routing. A `task done` on a task that carries a
  # `verifier` distinct from its current assignee is NOT a close — it's a handoff.
  # The maker is claiming the work is ready; the verifier must grade it before the
  # task can close (writer != grader). Route it to the verifier and let the
  # heartbeat wake them on the next tick; the verifier closes it for real (its own
  # `task done`, where verifier==assignee, falls through to a normal close) or
  # rejects it (`task reject` → bounce back to the maker). Opt-in: ordinary tasks
  # (verifier NULL) and the verifier's own close are untouched.
  if [[ "$verb" == "done" ]]; then
    local _vfier _asignee
    _vfier=$(db "SELECT COALESCE(verifier,'')  FROM tasks WHERE id=${id};")
    _asignee=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${id};")
    if [[ -n "$_vfier" && "$_vfier" != "$_asignee" ]]; then
      _task_route_to_verifier "$id" "$_vfier" "$_asignee" "$result" "$want_result"
      return
    fi
  fi
  # DIVE-555 gate enforcement (DIVE-393/394 class): a `task done` must NOT close
  # a task that still has an UNANSWERED human gate — that's how DIVE-535's
  # public-publish approval got bypassed (the task was marked done while its
  # approval gate sat 'pending', so the public ship happened with no recorded
  # sign-off). Block the close: the gate must be answered (`task answer`) or the
  # task abandoned (`task cancel`, which legitimately closes a gated task).
  # Verifier routing already returned above; only a real `done` reaches here.
  if [[ "$verb" == "done" ]]; then
    local _gt _ga
    _gt=$(db "SELECT COALESCE(need_type,'')        FROM tasks WHERE id=${id};")
    _ga=$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${id};")
    if [[ -n "$_gt" && -z "$_ga" ]]; then
      fail "$E_CONFLICT" "$ident has a pending '${_gt}' gate awaiting a human — answer it (5dive task answer $ident ...) or abandon the task (5dive task cancel $ident) instead of marking done. A gated/public ship must not close ahead of its gate (DIVE-555)."
    fi
  fi
  local set_result=""
  if (( want_result )); then
    set_result=", result=$(sqlq_or_null "$result")"
  fi
  db "UPDATE tasks SET status=$(sqlq "$newstatus")${extra}${set_result} WHERE id=${id};"
  # DIVE-552: if this close finished a LOOP STEP, advance the relay — free the
  # next step (a freed agent step the heartbeat wakes; a freed gate fires its
  # human tap) and close the run when the last step lands. Only on a real `done`
  # of a work step; gate steps advance via their answer, not here. Best-effort:
  # an advance hiccup never fails the close that already committed above.
  if [[ "$verb" == "done" ]]; then
    case "$(_loop_kind "$id")" in
      work) _task_loop_advance "$id" || true ;;
    esac
  fi
  # --notify (done/cancel only): DM the paired human a one-line ✅/⚠️ summary so
  # autonomous queue work surfaces a finish line. Best-effort; never fails the
  # status write above.
  #
  # Suppress the DM for auto-materialized recurring tasks (from_template_id set):
  # those are agent housekeeping the user never asked for per-occurrence — the
  # daily recap, nightly sweeps, weekly cleanups — and pinging on every fire is
  # the noise Mark flagged. Their result still lands on the record + the daily
  # recap; only the redundant live ping is dropped. Manual/delegated closes
  # (no template parent) still notify. Cheap single-column read, fail-open to
  # "notify" so a DB hiccup never silently swallows a real finish line.
  if (( notify )) && [[ "$verb" == "done" || "$verb" == "cancel" ]]; then
    local from_tmpl
    from_tmpl=$(db "SELECT COALESCE(from_template_id,'') FROM tasks WHERE id=${id};" 2>/dev/null || echo "")
    if [[ -z "$from_tmpl" ]]; then
      _task_close_notify "$ident" "$verb" "$result" || true
    fi
  fi
  ok "$ident $verb" '{id:($i|tonumber), ident:$id, status:$s}' --arg i "$id" --arg id "$ident" --arg s "$newstatus"
}

cmd_task_start()  { _task_status_cmd in_progress ", started_at=COALESCE(started_at, datetime('now'))" start "$@"; }
cmd_task_done()   { _task_status_cmd done ", done_at=datetime('now')" done "$@"; }
cmd_task_cancel() { _task_status_cmd cancelled ", done_at=datetime('now')" cancel "$@"; }

# DIVE-477: hand a maker-completed task to its verifier instead of closing it.
# Stash the original maker (first writer wins, so it survives re-routes) so a
# verify FAIL can bounce straight back, bump the iteration counter, keep the
# maker's result, and re-queue the task to the verifier as a fresh todo — the
# heartbeat picks it up on the verifier's next tick exactly like any other todo
# in their queue (no heartbeat change needed). No status='done' is written: the
# work is not closed until the verifier signs off.
_task_route_to_verifier() {
  local id="$1" vfier="$2" maker="$3" result="$4" want_result="$5"
  local set_result=""
  (( want_result )) && set_result=", result=$(sqlq_or_null "$result")"
  db "UPDATE tasks
        SET status='todo', assignee=$(sqlq "$vfier"),
            maker_agent=COALESCE(maker_agent, $(sqlq_or_null "$maker")),
            iteration=COALESCE(iteration,0)+1,
            started_at=NULL${set_result}
      WHERE id=${id};"
  local iter; iter=$(db "SELECT iteration FROM tasks WHERE id=${id};")
  local ident; ident=$(ident_of "$id")
  ok "$ident ready for review — routed to verifier '$vfier' (iteration $iter)" \
     '{id:($i|tonumber), ident:$id, status:"todo", routedTo:$v, role:"verifier", iteration:($n|tonumber)}' \
     --arg i "$id" --arg id "$ident" --arg v "$vfier" --arg n "$iter"
}

# DIVE-477: the verifier's FAIL verdict. The maker's work missed the bar, so
# bounce the task back to the maker with feedback for another pass — UNLESS we've
# reached max_iterations, where the loop is stuck and we park it on a human
# (`task need`) rather than ping-pong forever. Only meaningful mid-loop
# (maker_agent set); a plain task has no maker to bounce to.
cmd_task_reject() {
  tasks_db_init
  local task="" feedback=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --feedback=*) feedback="${1#*=}" ;;
      --reason=*)   feedback="${1#*=}" ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task reject <id|DIVE-N> [--feedback=\"<what to fix>\"]"
  resolve_task_id "$task"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  local maker iter maxi vfier
  maker=$(db "SELECT COALESCE(maker_agent,'')    FROM tasks WHERE id=${id};")
  iter=$(db  "SELECT COALESCE(iteration,0)       FROM tasks WHERE id=${id};")
  maxi=$(db  "SELECT COALESCE(max_iterations,0)  FROM tasks WHERE id=${id};")
  vfier=$(db "SELECT COALESCE(verifier,'')       FROM tasks WHERE id=${id};")
  [[ -n "$maker" ]] || fail "$E_VALIDATION" \
    "$ident is not in a maker→verifier loop (no maker to bounce to) — use 'task need'/'task block' for a plain rejection"
  local fb_txt="❌ verifier '${vfier:-?}' rejected (iteration ${iter}): ${feedback:-no feedback given}"
  # max_iterations reached -> stop bouncing, park it on a human to decide.
  if (( maxi > 0 && iter >= maxi )); then
    db "UPDATE tasks SET result=$(sqlq "$fb_txt") WHERE id=${id};"
    warn "$ident hit max_iterations ($maxi) — escalating to human review"
    cmd_task_need "$id" --type=manual --from="${vfier:-verifier}" \
      --ask="Maker→verifier loop stuck: $ident failed verification ${iter}× (max ${maxi}). Last feedback: ${feedback:-none}. Review + decide."
    return
  fi
  # Otherwise bounce back to the maker for another pass.
  db "UPDATE tasks SET status='todo', assignee=$(sqlq "$maker"), started_at=NULL,
        result=$(sqlq "$fb_txt") WHERE id=${id};"
  ok "$ident rejected — bounced back to maker '$maker' (iteration $iter${maxi:+/$maxi})" \
     '{id:($i|tonumber), ident:$id, status:"todo", bouncedTo:$m, role:"maker", iteration:($n|tonumber)}' \
     --arg i "$id" --arg id "$ident" --arg m "$maker" --arg n "$iter"
}

# DIVE-478: loop observability. The org-wide board of maker→verifier loops (any
# task with a verifier), grouped by task id, showing where each loop sits — the
# maker/verifier pair, who currently holds it, iteration vs its cap, and a ⚠ STUCK
# flag when a loop has burned its whole max_iterations budget but still isn't
# closed (it should have escalated via `task reject` at the cap; this surfaces any
# that slipped through, e.g. a maker that kept re-routing without a clean reject).
# Pairs with `5dive usage`, which attributes tokens/turns/cost to the same task
# ids — so loops here + usage there give iterations AND cost per loop.
#   --stuck            only the stuck loops
#   --all              include closed loops (default: open only)
#   --escalate-stuck   run `task escalate` on every stuck open loop (reuses the
#                      standard escalate path: bump priority + ping agent & human)
cmd_task_loops() {
  tasks_db_init
  local only_stuck=0 show_all=0 escalate=0 kill_id="" watch=0 watch_secs=3 runs_only=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stuck)          only_stuck=1 ;;
      --all)            show_all=1 ;;
      --escalate-stuck) escalate=1; only_stuck=1 ;;
      --runs)           runs_only=1 ;;
      --kill=*)         kill_id="${1#--kill=}" ;;
      --kill)           shift; kill_id="${1:-}" ;;
      --watch)          watch=1 ;;
      --watch=*)        watch=1; watch_secs="${1#--watch=}" ;;
      -*)               fail "$E_USAGE" "unknown flag: $1" ;;
      *)                fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done

  # --kill <loopId>: deferred-safe stop for a LOOP-7 run. Flips kill_requested;
  # the running verb checks it between stages and halts + escalates-with-proof.
  # The control window never authors work — this only sets a flag (design §2/§4).
  if [[ -n "$kill_id" ]]; then
    local exists; exists=$(db "SELECT 1 FROM loop_runs WHERE loop_id=$(sqlq "$kill_id") LIMIT 1;")
    [[ "$exists" == "1" ]] || fail "$E_NOT_FOUND" "no loop run with id '$kill_id'"
    db "UPDATE loop_runs SET kill_requested=1, updated_at=$(date +%s) WHERE loop_id=$(sqlq "$kill_id");"
    ok "kill requested for loop ${kill_id} (deferred — halts at its next stage check)" \
       '{loopId:$l, killRequested:true}' --arg l "$kill_id"
    return
  fi

  [[ "$watch_secs" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--watch=<seconds> must be a positive integer"
  # A loop is "stuck" once it has a cap, has reached it, and still isn't closed.
  local stuck_pred="(verifier IS NOT NULL AND max_iterations IS NOT NULL
                     AND COALESCE(iteration,0) >= max_iterations
                     AND status NOT IN ('done','cancelled'))"
  local where="verifier IS NOT NULL"
  (( show_all )) || where+=" AND status NOT IN ('done','cancelled')"
  (( only_stuck )) && where+=" AND ${stuck_pred}"

  # --escalate-stuck: reuse the standard escalate path on every stuck open loop.
  if (( escalate )); then
    local ids; ids=$(db "SELECT id FROM tasks WHERE ${stuck_pred} ORDER BY id;")
    if [[ -z "$ids" ]]; then
      ok "no stuck loops to escalate" '{escalated:[]}'
      return
    fi
    local eid
    for eid in $ids; do cmd_task_escalate "$eid" --from=loop-watch || true; done
    return
  fi

  # loop_runs (LOOP-7) control-window predicate: open = status 'running'.
  local runs_where="status='running'"; (( show_all )) && runs_where="1=1"

  # One repaint of the board(s). JSON mode emits {loops, runs}; text prints the
  # maker→verifier board (DIVE-478) then the LOOP-7 loop_runs board below it.
  # --runs shows only the loop_runs board. Read-only — never authors work.
  _task_loops_paint() {
    if (( JSON_MODE )); then
      local tloops="[]" runs="[]"
      (( runs_only )) || tloops=$(dbfmt -json "SELECT ident, status,
               COALESCE(maker_agent, assignee) AS maker, verifier,
               COALESCE(iteration,0) AS iteration, max_iterations,
               COALESCE(assignee,'') AS holder,
               CASE WHEN ${stuck_pred} THEN 1 ELSE 0 END AS stuck, title
             FROM tasks WHERE ${where}
             ORDER BY (CASE WHEN ${stuck_pred} THEN 1 ELSE 0 END) DESC, COALESCE(iteration,0) DESC, id;")
      [[ -n "$tloops" ]] || tloops="[]"
      runs=$(dbfmt -json "SELECT loop_id, topology, COALESCE(stage,'') AS stage,
               COALESCE(iteration,0) AS iteration, COALESCE(tokens_spent,0) AS tokens_spent,
               ceiling, status, COALESCE(spawned_by_agent,'') AS by,
               kill_requested, stuck, COALESCE(scorecard_json,'') AS scorecard
             FROM loop_runs WHERE ${runs_where}
             ORDER BY (status='running') DESC, started_at DESC;")
      [[ -n "$runs" ]] || runs="[]"
      jq -cn --argjson l "$tloops" --argjson r "$runs" '{ok:true, data:{loops:$l, runs:$r}}'
    else
      if (( ! runs_only )); then
        dbfmt -box "SELECT ident, status,
                 COALESCE(maker_agent, COALESCE(assignee,'-')) AS maker,
                 COALESCE(verifier,'-') AS verifier,
                 COALESCE(iteration,0)||'/'||COALESCE(CAST(max_iterations AS TEXT),'∞') AS iter,
                 CASE WHEN ${stuck_pred} THEN '⚠' ELSE '' END AS stuck,
                 title
               FROM tasks WHERE ${where}
               ORDER BY (CASE WHEN ${stuck_pred} THEN 1 ELSE 0 END) DESC, COALESCE(iteration,0) DESC, ident;"
        printf '\nLOOP-7 runs:\n'
      fi
      dbfmt -box "SELECT loop_id, topology, COALESCE(NULLIF(stage,''),'-') AS stage,
               COALESCE(iteration,0) AS iter,
               COALESCE(tokens_spent,0)||'/'||COALESCE(CAST(ceiling AS TEXT),'∞') AS tokens,
               status,
               CASE WHEN scorecard_json IS NOT NULL AND json_valid(scorecard_json)
                    THEN COALESCE(CAST(json_extract(scorecard_json,'\$.overall') AS TEXT),'-')||'/100'
                    ELSE '-' END AS score,
               CASE WHEN kill_requested=1 THEN '✗kill' ELSE '' END AS kill,
               CASE WHEN stuck=1 THEN '⚠' ELSE '' END AS stuck,
               COALESCE(spawned_by_agent,'-') AS by
             FROM loop_runs WHERE ${runs_where}
             ORDER BY (status='running') DESC, started_at DESC;"
    fi
  }

  # --watch: repaint on an interval (text only; JSON callers poll themselves).
  if (( watch )) && (( ! JSON_MODE )); then
    while :; do
      printf '\033[2J\033[H'   # clear + home
      printf '5dive loop control — refresh %ss (Ctrl-C to exit)\n\n' "$watch_secs"
      _task_loops_paint
      sleep "$watch_secs"
    done
    return
  fi
  _task_loops_paint
}

# ───────────────────────── DIVE-552 loop engine ─────────────────────────
# A "loop" is an N-step agent relay — the general case of the maker→verifier
# 2-step chain (DIVE-477). It is composed ENTIRELY from existing primitives, so
# NO schema migration: a loop RUN is a parent task; each STEP is a subtask
# (assignee = the step's agent), ordered by block edges (step N+1 blocked_by
# step N). When a step's `task done` fires, the close path advances the loop:
# drop the edge to the next step, which the existing unblock-flip turns into a
# todo the heartbeat wakes. A HUMAN-GATE step is the existing `task need`
# decision gate (Approve →/Do better ↩), fired the moment the loop reaches it.
#
# Loop membership is marked in the task body with an ASCII sentinel (no new
# column): the run carries `[[5dive-loop:run]]`, a step carries
# `[[5dive-loop:work]]` or `[[5dive-loop:gate:approval]]` / `:gate:manual`.
_LOOP_MARK="[[5dive-loop"

# Echo a task's loop-step kind from its body marker: work | gate:approval |
# gate:manual | run, or "" when the task is not part of a loop.
_loop_kind() {
  local id="$1" body
  body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
  case "$body" in
    *"${_LOOP_MARK}:"*) ;;
    *) return ;;
  esac
  printf '%s' "$body" | sed -n 's/.*\[\[5dive-loop:\([^]]*\)\]\].*/\1/p' | head -1
}

# Advance a loop past a just-finished step `sid`. Drop each edge where a sibling
# was blocked_by sid; a freed AGENT step becomes a todo (the unblock-flip the
# existing `task block`/answer paths use) and we best-effort ping its assignee;
# a freed GATE step fires its human tap right when it's reached. When sid has no
# downstream step, the relay is over — close the parent run.
_task_loop_advance() {
  local sid="$1"
  local run; run=$(db "SELECT COALESCE(parent_id,'') FROM tasks WHERE id=${sid};")
  local nexts; nexts=$(db "SELECT task_id FROM task_deps WHERE blocked_by=${sid};")
  if [[ -z "$nexts" ]]; then
    # last step done — close the run (if it's still open) and tell its owner.
    if [[ -n "$run" ]]; then
      local rstatus; rstatus=$(db "SELECT status FROM tasks WHERE id=${run};")
      if [[ "$rstatus" != "done" && "$rstatus" != "cancelled" ]]; then
        db "UPDATE tasks SET status='done', done_at=datetime('now') WHERE id=${run};"
        local owner; owner=$(db "SELECT COALESCE(assignee,created_by) FROM tasks WHERE id=${run};")
        local rident; rident=$(db "SELECT ident FROM tasks WHERE id=${run};")
        [[ -n "$owner" ]] && ( cmd_send "$owner" --from="loop" \
            --message="✅ Loop complete: ${rident} — all steps done." ) >/dev/null 2>&1 || true
      fi
    fi
    return
  fi
  local nid
  while IFS= read -r nid; do
    [[ -n "$nid" ]] || continue
    db "DELETE FROM task_deps WHERE task_id=${nid} AND blocked_by=${sid};"
    # still blocked by another step? leave it.
    [[ "$(db "SELECT COUNT(*) FROM task_deps WHERE task_id=${nid};")" == "0" ]] || continue
    local kind; kind=$(_loop_kind "$nid")
    case "$kind" in
      gate:*)
        local gtype="${kind#gate:}" gask
        gask=$(db "SELECT COALESCE(NULLIF(title,''),'Approve this step?') FROM tasks WHERE id=${nid};")
        if [[ "$gtype" == "manual" ]]; then
          cmd_task_need "$nid" --type=manual --from="loop" --ask="$gask"
        else
          # DIVE-560: a loop approval gate fires as --type=approval, which is
          # HUMAN-enforced (agent-uid block + gate-proof). It used to fire as
          # --type=decision purely for the Approve/Do-better buttons, but a
          # decision gate is agent-clearable — silently undercutting the public
          # "you get the final say at the gate" claim. The standard approval
          # Approve/Deny buttons cover it with no plugin change: a "denied" tap
          # drives the loop's bounce-back-and-redo (see the answer path below).
          cmd_task_need "$nid" --type=approval --from="loop" \
            --ask="$gask" --recommend="approved"
        fi
        ;;
      *)
        # agent step: the unblock-flip turns it todo; wake its owner.
        db "UPDATE tasks SET status='todo'
            WHERE id=${nid} AND status='blocked'
              AND (need_type IS NULL OR need_answered_at IS NOT NULL);"
        local who lbl rident
        who=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${nid};")
        lbl=$(db "SELECT title FROM tasks WHERE id=${nid};")
        rident=$(db "SELECT COALESCE((SELECT ident FROM tasks WHERE id=${run}),'') FROM tasks LIMIT 1;")
        [[ -n "$who" ]] && ( cmd_send "$who" --from="loop" \
            --message="🔁 Your turn in loop ${rident}: ${lbl}" ) >/dev/null 2>&1 || true
        ;;
    esac
  done <<< "$nexts"
}

# `5dive task loop start --title=<name> --steps=<json> [--project=] [--owner=] [--from=]`
# steps JSON = ordered array; each item is either an agent step
#   {"agent":"marcus","label":"Draft it","handoff":"submits for review"}
# or a human gate
#   {"gate":"approval"|"manual","label":"You approve before publish"}
# Materializes the run + chained step subtasks and starts step 1.
cmd_task_loop_start() {
  tasks_db_init
  local title="" steps="" project="dive" owner="" from=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title=*)   title="${1#*=}" ;;
      --steps=*)   steps="${1#*=}" ;;
      --project=*) project="${1#*=}" ;;
      --owner=*)   owner="${1#*=}" ;;
      --from=*)    from="${1#*=}" ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$title" ]] || fail "$E_USAGE" "usage: 5dive task loop start --title=<name> --steps=<json>"
  [[ -n "$steps" ]] || fail "$E_USAGE" "--steps=<json array> is required"
  printf '%s' "$steps" | jq -e 'type=="array" and length>0' >/dev/null 2>&1 \
    || fail "$E_VALIDATION" "--steps must be a non-empty JSON array"
  local creator; creator=$(task_actor "$from")
  [[ -n "$owner" ]] || owner=$(_task_resolve_coordinator)

  # Run parent — marked, assigned to the owner so it always has a home.
  local run_body="Loop run.
${_LOOP_MARK}:run]]"
  local run
  run=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, project_key, kind)
            VALUES ($(sqlq "$title"), $(sqlq "$run_body"), 'medium',
                    $(sqlq_or_null "$owner"), $(sqlq "$creator"), $(sqlq "${project,,}"), 'standard');
            SELECT last_insert_rowid();")
  local run_ident; run_ident=$(db "SELECT ident FROM tasks WHERE id=${run};")

  # Walk the steps, creating one subtask each and chaining N+1 blocked_by N.
  local n; n=$(printf '%s' "$steps" | jq 'length')
  local prev="" i=0 first=""
  while (( i < n )); do
    local item; item=$(printf '%s' "$steps" | jq -c ".[$i]")
    local gate; gate=$(printf '%s' "$item" | jq -r '.gate // empty')
    local label; label=$(printf '%s' "$item" | jq -r '.label // "Step"')
    local kind sassignee
    if [[ -n "$gate" ]]; then
      [[ "$gate" == "approval" || "$gate" == "manual" ]] || gate="approval"
      kind="gate:$gate"; sassignee="$owner"   # human answers; owner-agent holds it
    else
      sassignee=$(printf '%s' "$item" | jq -r '.agent // empty')
      [[ -n "$sassignee" ]] || fail "$E_VALIDATION" "step $i needs an \"agent\" or a \"gate\""
      kind="work"
    fi
    local sbody="${_LOOP_MARK}:${kind}]]"
    local sid
    sid=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, parent_id, project_key, kind)
              VALUES ($(sqlq "$label"), $(sqlq "$sbody"), 'medium',
                      $(sqlq_or_null "$sassignee"), $(sqlq "$creator"), ${run}, $(sqlq "${project,,}"), 'standard');
              SELECT last_insert_rowid();")
    if [[ -n "$prev" ]]; then
      db "INSERT OR IGNORE INTO task_deps (task_id, blocked_by) VALUES (${sid}, ${prev});
          UPDATE tasks SET status='blocked' WHERE id=${sid};"
    else
      first="$sid"
    fi
    prev="$sid"
    i=$((i+1))
  done

  # Kick off step 1 — ping its agent (heartbeat would wake it anyway).
  local who1; who1=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${first};")
  local lbl1; lbl1=$(db "SELECT title FROM tasks WHERE id=${first};")
  [[ -n "$who1" ]] && ( cmd_send "$who1" --from="loop" \
      --message="🔁 Loop ${run_ident} started — your step: ${lbl1}" ) >/dev/null 2>&1 || true

  ok "loop ${run_ident} started — ${n} steps, first: ${who1:-?}" \
     '{run:$r, ident:$id, steps:($n|tonumber), first_assignee:$w}' \
     --arg r "$run" --arg id "$run_ident" --arg n "$n" --arg w "${who1:-}"
}

# `5dive task loop ls` — the board of loop runs (parent tasks marked :run]]),
# with how many of their steps are done.
cmd_task_loop_ls() {
  tasks_db_init
  local show_all=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) show_all=1 ;;
      -*)    fail "$E_USAGE" "unknown flag: $1" ;;
      *)     fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  local run_pred="body LIKE '%${_LOOP_MARK}:run]]%'"
  local status_pred="status NOT IN ('done','cancelled')"
  (( show_all )) && status_pred="1=1"
  # DIVE-860: latest grade scorecard for each run, joined by the graded task's
  # ident (loop grade stamps scorecard_json.target with it). Emitted as the raw
  # JSON string ('' when ungraded) — same shape `task loops` uses for its runs
  # board, so dashboard consumers parse one contract.
  local score_sub="COALESCE((SELECT lr.scorecard_json FROM loop_runs lr
             WHERE lr.scorecard_json IS NOT NULL AND json_valid(lr.scorecard_json)
               AND json_extract(lr.scorecard_json,'\$.target')=tasks.ident
             ORDER BY lr.updated_at DESC LIMIT 1),'')"
  if (( JSON_MODE )); then
    local rows
    rows=$(dbfmt -json "SELECT id, ident, title, status, assignee,
             (SELECT COUNT(*) FROM tasks s WHERE s.parent_id=tasks.id) AS steps,
             (SELECT COUNT(*) FROM tasks s WHERE s.parent_id=tasks.id AND s.status='done') AS done_steps,
             ${score_sub} AS scorecard_json
           FROM tasks WHERE ${run_pred} AND ${status_pred} ORDER BY id DESC;")
    [[ -n "$rows" ]] || rows="[]"
    printf '%s' "$rows" | jq -c '{ok:true, data:{loops:.}}'
  else
    dbfmt -box "SELECT ident, status, COALESCE(assignee,'-') AS owner,
             (SELECT COUNT(*) FROM tasks s WHERE s.parent_id=tasks.id AND s.status='done')||'/'||
             (SELECT COUNT(*) FROM tasks s WHERE s.parent_id=tasks.id) AS progress,
             CASE WHEN ${score_sub} <> ''
                  THEN COALESCE(CAST(json_extract(${score_sub},'\$.overall') AS TEXT),'-')||'/100'
                  ELSE '-' END AS score,
             title
           FROM tasks WHERE ${run_pred} AND ${status_pred} ORDER BY id DESC;"
  fi
}

cmd_task_loop() {
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task loop <start|ls> ..."
  local sub="$1"; shift
  case "$sub" in
    start)          cmd_task_loop_start "$@" ;;
    ls|list)        cmd_task_loop_ls "$@" ;;
    -h|--help|help) echo "5dive task loop start --title=<name> --steps=<json>   |   loop ls [--all]" ;;
    *) fail "$E_USAGE" "unknown loop command: $sub (try: start|ls)" ;;
  esac
}

# DIVE-475: deterministic verify-runner — proven-done, not claimed-done. Run a
# command; its EXIT CODE is the real stop condition. On pass (exit 0) flip the
# task to done with the command + output tail captured in result; on fail leave
# status untouched (just record the failing attempt). The verb itself exits 0 on
# pass / 1 on fail so it can BE a stop condition (heartbeat /goal, scripts) — the
# maker no longer grades itself by asserting status=done (writer != verifier).
# --no-done (alias --check) runs the check and records it WITHOUT flipping.
cmd_task_verify() {
  tasks_db_init
  local task="" cmd="" no_done=0 timeout_s=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cmd=*)      cmd="${1#*=}" ;;
      --no-done|--check) no_done=1 ;;
      --timeout=*)  timeout_s="${1#*=}" ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] \
    || fail "$E_USAGE" "usage: 5dive task verify <id|DIVE-N> [--cmd=\"<command>\"] [--no-done] [--timeout=<seconds>]"
  [[ -z "$timeout_s" || "$timeout_s" =~ ^[1-9][0-9]*$ ]] \
    || fail "$E_VALIDATION" "--timeout must be a positive integer (seconds)"
  resolve_task_id "$task"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  # DIVE-476: --cmd is now optional — when omitted, fall back to the task's stored
  # verify_command (the declarative loop spec). Persisted input, no re-passing.
  if [[ -z "$cmd" ]]; then
    cmd=$(db "SELECT COALESCE(verify_command,'') FROM tasks WHERE id=${id};")
    [[ -n "$cmd" ]] \
      || fail "$E_USAGE" "no --cmd given and task has no stored verify_command (set one: 5dive task add … --verify=\"<cmd>\")"
  fi

  # Run it. Combined stdout+stderr. The `if` wrapper captures the exit code
  # WITHOUT tripping `set -e` (a failing $() in a bare assignment would abort).
  local out rc
  if [[ -n "$timeout_s" ]]; then
    if out=$(timeout "${timeout_s}" bash -c "$cmd" 2>&1); then rc=0; else rc=$?; fi
    (( rc == 124 )) && out="${out}"$'\n'"[timed out after ${timeout_s}s]"
  else
    if out=$(bash -c "$cmd" 2>&1); then rc=0; else rc=$?; fi
  fi
  # Tail the output so a chatty command can't bloat the result row.
  local tail_out; tail_out=$(printf '%s\n' "$out" | tail -n 25)

  local verdict result_txt
  if (( rc == 0 )); then
    verdict="pass"
    result_txt="✅ verify PASS (exit 0): ${cmd}"$'\n'"--- output tail ---"$'\n'"${tail_out}"
  else
    verdict="fail"
    result_txt="❌ verify FAIL (exit ${rc}): ${cmd}"$'\n'"--- output tail ---"$'\n'"${tail_out}"
  fi

  local flipped=0
  if (( rc == 0 )) && (( ! no_done )); then
    db "UPDATE tasks SET status='done', done_at=datetime('now'), result=$(sqlq "$result_txt") WHERE id=${id};"
    flipped=1
  else
    db "UPDATE tasks SET result=$(sqlq "$result_txt") WHERE id=${id};"
  fi

  if (( JSON_MODE )); then
    printf '%s' "$result_txt" | jq -R -s \
      --arg i "$id" --arg id "$ident" --arg v "$verdict" --argjson rc "$rc" \
      --argjson flipped "$([[ $flipped -eq 1 ]] && echo true || echo false)" \
      '{ok:true, data:{id:($i|tonumber), ident:$id, verdict:$v, exit:$rc, flippedToDone:$flipped, output:.}}'
  else
    printf '%s\n' "$result_txt" >&2
    if (( rc == 0 )); then
      (( flipped )) && ok "$ident verify PASS — marked done" \
                    || ok "$ident verify PASS (status unchanged, --no-done)"
    else
      warn "$ident verify FAIL (exit $rc) — status unchanged"
    fi
  fi
  return $(( rc == 0 ? 0 : 1 ))
}

cmd_task_block() {
  tasks_db_init
  local task="" by=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --by=*) by="${1#*=}" ;;
      -*)     fail "$E_USAGE" "unknown flag: $1" ;;
      *)      [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" && -n "$by" ]] || fail "$E_USAGE" "usage: 5dive task block <id|DIVE-N> --by=<id|DIVE-N>"
  resolve_task_id "$task"; local tid="$RESOLVED_TASK_ID" tident="$RESOLVED_TASK_IDENT"
  resolve_task_id "$by";   local bid="$RESOLVED_TASK_ID" bident="$RESOLVED_TASK_IDENT"
  [[ "$tid" != "$bid" ]] || fail "$E_VALIDATION" "a task can't block itself"
  db "INSERT OR IGNORE INTO task_deps (task_id, blocked_by) VALUES (${tid}, ${bid});
      UPDATE tasks SET status='blocked' WHERE id=${tid} AND status NOT IN ('done','cancelled');"
  ok "$tident blocked by $bident" '{task:($t|tonumber), task_ident:$ti, blocked_by:($b|tonumber), blocked_by_ident:$bi}' --arg t "$tid" --arg ti "$tident" --arg b "$bid" --arg bi "$bident"
}

cmd_task_unblock() {
  tasks_db_init
  local task="" by=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --by=*) by="${1#*=}" ;;
      -*)     fail "$E_USAGE" "unknown flag: $1" ;;
      *)      [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task unblock <id|DIVE-N> [--by=<id|DIVE-N>]"
  resolve_task_id "$task"; local tid="$RESOLVED_TASK_ID" tident="$RESOLVED_TASK_IDENT"
  if [[ -n "$by" ]]; then
    resolve_task_id "$by"; local bid="$RESOLVED_TASK_ID"
    db "DELETE FROM task_deps WHERE task_id=${tid} AND blocked_by=${bid};"
  else
    db "DELETE FROM task_deps WHERE task_id=${tid};"
  fi
  # Don't flip a still-pending human gate back to todo (DIVE-109): a task parked
  # on a human has need_type set and need_answered_at NULL. Only edge-blocks clear here.
  db "UPDATE tasks SET status='todo'
      WHERE id=${tid} AND status='blocked'
        AND (need_type IS NULL OR need_answered_at IS NOT NULL)
        AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${tid});"
  ok "$tident unblocked" '{task:($t|tonumber), task_ident:$ti}' --arg t "$tid" --arg ti "$tident"
}

# DIVE-356: `park` is the QUIET counterpart to `need`. A parked task is waiting
# on an external/time event the human need not act on — so it must NOT fire a
# CTA ping the way `need` does, and must NOT show in the human inbox. We set
# status=blocked + parked_at + park_reason and CLEAR any pending gate fields so
# the state is unambiguously "parked, no action" (inbox is need_type IS NOT
# NULL, so clearing need_type also drops it from the inbox). No notify.
# Dashboard reads: status='blocked' AND parked_at IS NOT NULL.
cmd_task_park() {
  tasks_db_init
  local task="" reason="" wake=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason=*) reason="${1#*=}" ;;
      --wake=*)   wake="${1#*=}" ;;
      -*)         fail "$E_USAGE" "unknown flag: $1" ;;
      *)          [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task park <id|DIVE-N> --reason=<why / what unblocks it> [--wake=<YYYY-MM-DD[ HH:MM]|+Nd|+Nh>]"
  resolve_task_id "$task"; local tid="$RESOLVED_TASK_ID" tident="$RESOLVED_TASK_IDENT"
  # DIVE-891: --wake gives a park a wake-up time — the heartbeat's TTL pass
  # auto-unparks (back to todo) once it passes, so "revisit in a week" stops
  # masquerading as a pending human gate. Accepts an absolute UTC timestamp or
  # a +Nd/+Nh relative form. Stored as the same ISO text every other timestamp
  # column uses, so plain string comparison against datetime('now') works.
  local wake_sql="NULL"
  if [[ -n "$wake" ]]; then
    local wake_ts=""
    case "$wake" in
      +*d) local _n="${wake#+}"; _n="${_n%d}"
           [[ "$_n" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "bad --wake '$wake' (use +Nd, +Nh, or 'YYYY-MM-DD[ HH:MM]')"
           wake_ts=$(db "SELECT datetime('now', '+${_n} days');") ;;
      +*h) local _n="${wake#+}"; _n="${_n%h}"
           [[ "$_n" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "bad --wake '$wake' (use +Nd, +Nh, or 'YYYY-MM-DD[ HH:MM]')"
           wake_ts=$(db "SELECT datetime('now', '+${_n} hours');") ;;
      *)   wake_ts=$(db "SELECT datetime($(sqlq "$wake"));")
           [[ -n "$wake_ts" ]] || fail "$E_VALIDATION" "bad --wake '$wake' (use +Nd, +Nh, or 'YYYY-MM-DD[ HH:MM]')" ;;
    esac
    wake_sql=$(sqlq "$wake_ts")
  fi
  db "UPDATE tasks
        SET status='blocked', parked_at=datetime('now'), park_reason=$(sqlq "$reason"),
            wake_at=${wake_sql},
            need_type=NULL, ask=NULL, need_options=NULL, recommend=NULL,
            need_answer=NULL, need_answered_at=NULL
      WHERE id=${tid} AND status NOT IN ('done','cancelled');"
  local wake_note=""; [[ "$wake_sql" != "NULL" ]] && wake_note=" — wakes $(db "SELECT wake_at FROM tasks WHERE id=${tid};") UTC"
  ok "$tident parked (no action needed)${reason:+ — $reason}${wake_note}" \
     '{task:($t|tonumber), task_ident:$ti, parked:true, reason:$r, wake_at:(($w|select(length>0)) // null)}' \
     --arg t "$tid" --arg ti "$tident" --arg r "$reason" --arg w "$([[ "$wake_sql" != "NULL" ]] && db "SELECT wake_at FROM tasks WHERE id=${tid};" || echo "")"
}

# Clear a park -> back to todo (unless real dependency edges still block it).
cmd_task_unpark() {
  tasks_db_init
  local task="${1:-}"
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task unpark <id|DIVE-N>"
  resolve_task_id "$task"; local tid="$RESOLVED_TASK_ID" tident="$RESOLVED_TASK_IDENT"
  db "UPDATE tasks SET parked_at=NULL, park_reason=NULL, wake_at=NULL,
        status=CASE WHEN status='blocked'
                     AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${tid})
                    THEN 'todo' ELSE status END
      WHERE id=${tid} AND status NOT IN ('done','cancelled');"
  ok "$tident unparked" '{task:($t|tonumber), task_ident:$ti}' --arg t "$tid" --arg ti "$tident"
}

# --- Human Task Inbox (DIVE-103; parent feature DIVE-102) ----------------
# `need` parks a task on a human; `inbox` lists what's waiting; `answer`
# records the human's reply, unblocks, and pings the agent that hit the gate.

# DIVE-891 (adopted design DIVE-861): the T2 category floor. Money, public or
# customer-facing comms, secrets, destructive/irreversible actions and
# brand/strategy are ALWAYS a hard human gate, regardless of the tier the
# filing agent asked for — the floor is enforced here, not trusted from the
# filer. Matched case-insensitively over ask + title. The bias is deliberately
# toward false positives: a wrongly-ELEVATED gate costs the human one tap; a
# wrongly-lowered one would let a spend/publish call auto-apply. Bar-raise,
# same posture as gate-proof (a determined agent can still word around it —
# but only by loudly not-naming what it's asking for, which the ask text then
# fails to justify).
_GATE_T2_FLOOR_RX='spend|billing|invoice|charge|payment|refund|subscription|price|pricing|\$[0-9]|€[0-9]|publish|public post|announce|launch post|press|customer email|email customers|newsletter|blast|secret|credential|api key|token|password|delete|destroy|teardown|wipe|purge|drop table|irreversible|revoke|dns|domain transfer|brand'
_gate_tier2_floor_hit() {
  local text; text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$text" =~ $_GATE_T2_FLOOR_RX ]]
}

# OSS-11 (DIVE-976) — _gate_ask_shape <ask>: normalize an ask into its "shape
# key" so two gates that ask structurally the same question but about different
# targets collapse to one key. Precedent matching uses EXACT shape-key equality
# (no fuzzy/embedding match) to bound false positives. Volatile tokens become
# typed placeholders; the ORDER below matters — each rule must run before any
# later rule that could re-consume its output (dates/hosts before the bare-number
# rule; quoted names first so their contents aren't mangled). Placeholders carry
# no digits, hyphenated-digit runs, or dots, so no rule ever re-fires on them.
_gate_ask_shape() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E \
        -e 's/"[^"]*"/<name>/g' \
        -e "s/'[^']*'/<name>/g" \
        -e 's#https?://[^[:space:]]+#<host>#g' \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}/<date>/g' \
        -e 's/\b(today|tomorrow|yesterday)\b/<date>/g' \
        -e 's/([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}/<host>/g' \
        -e 's/\$[0-9][0-9,]*(\.[0-9]+)?[kmb]?/<amount>/g' \
        -e 's/\b[a-z]+-[0-9]+\b/<ident>/g' \
        -e 's/[0-9]+(\.[0-9]+)?/<num>/g' \
        -e 's/[[:space:]]+/ /g' \
        -e 's/^ +//; s/ +$//'
}

cmd_task_need() {
  tasks_db_init
  local type="" ask="" options="" recommend="" from="" tier="" secret_key="" connector=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type=*)      type="${1#*=}" ;;
      --ask=*)       ask="${1#*=}" ;;
      --options=*)   options="${1#*=}" ;;
      --recommend=*) recommend="${1#*=}" ;;
      --tier=*)      tier="${1#*=}" ;;
      --from=*)      from="${1#*=}" ;;
      # DIVE-931 secure credential drop: name WHERE a secret gate's value lands.
      # Both together enable the burnable drop link in the gate message.
      --secret-key=*) secret_key="${1#*=}" ;;
      --connector=*)  connector="${1#*=}" ;;
      --)          shift; positional+=("$@"); break ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task need <id|DIVE-N> --type=decision|secret|approval|manual --ask=\"...\" [--options=A|B] [--recommend=\"A\"]"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  valid_need_type "$type" || fail "$E_VALIDATION" "bad --type '$type' (decision|secret|approval|manual)"
  [[ -n "$ask" ]] || fail "$E_USAGE" "--ask is required (what does the human need to provide?)"
  # Options are the choice list for a decision; reject them on the other types
  # so the gate shape stays honest for the dashboard. (An approval gate is
  # deliberately approved/denied only — the plugin tap handler resolves no
  # option index for it; see DIVE-560 note in _task_loop_advance.)
  if [[ -n "$options" && "$type" != "decision" ]]; then
    fail "$E_VALIDATION" "--options only applies to --type=decision"
  fi
  # DIVE-931: --secret-key / --connector name the drop target and only make sense
  # on a secret gate. Require them together (a key with no connector has nowhere
  # to land, and vice versa) and validate against the same charsets the box-side
  # `secret write` + the api /drop/mint enforce, so a bad value fails here rather
  # than at mint time. Both omitted = legacy secret gate (out-of-band delivery).
  if [[ -n "$secret_key" || -n "$connector" ]]; then
    [[ "$type" == "secret" ]] || fail "$E_VALIDATION" "--secret-key/--connector only apply to --type=secret"
    [[ -n "$secret_key" && -n "$connector" ]] \
      || fail "$E_VALIDATION" "--secret-key and --connector must be given together (both name the drop target)"
    [[ "$secret_key" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] \
      || fail "$E_VALIDATION" "invalid --secret-key '$secret_key' (env-var name: ^[A-Z][A-Z0-9_]{0,63}\$)"
    [[ "$connector" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] \
      || fail "$E_VALIDATION" "invalid --connector '$connector' (^[a-z0-9][a-z0-9-]{0,63}\$)"
  fi
  # DIVE-148: --recommend surfaces the agent's advised choice first in the human
  # alert (and ⭐-marks its button). Only meaningful for the two finite-choice
  # gate types; reject it elsewhere so the gate shape stays honest. For a
  # decision it MUST be one of --options (same split rule as the buttons:
  # split '|', trim, drop empties) or a tapped/displayed recommend wouldn't
  # match any real option. For approval it's free text (e.g. approved/denied).
  if [[ -n "$recommend" ]]; then
    case "$type" in
      decision)
        [[ -n "$options" ]] || fail "$E_VALIDATION" "--recommend on a decision needs --options to match against"
        local _match
        _match=$(printf '%s' "$options" | jq -Rr --arg r "$recommend" '
          [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ]
          | (($r | gsub("^\\s+|\\s+$"; "")) as $rr | any(.[]; . == $rr)) | tostring' 2>/dev/null) || _match="false"
        [[ "$_match" == "true" ]] || fail "$E_VALIDATION" "--recommend \"$recommend\" must match one of --options ($options)"
        ;;
      approval) : ;;
      *) fail "$E_VALIDATION" "--recommend only applies to --type=decision or --type=approval" ;;
    esac
  fi
  local cur; cur=$(db "SELECT status FROM tasks WHERE id=${id};")
  [[ "$cur" == "done" || "$cur" == "cancelled" ]] \
    && fail "$E_CONFLICT" "$ident is $cur — reopen it before gating on a human"

  # DIVE-891: resolve the gate's risk tier (adopted DIVE-861 design).
  #   0 = auto-clear: the recommendation applies immediately, no ping, digest line
  #   1 = agent-clearable; 48h unanswered -> the heartbeat TTL sweep applies the rec
  #   2 = hard human gate: never auto-applies, TTL only batches reminder pings
  # Defaults by type when --tier is omitted: decision -> 1 (agents legitimately
  # resolve these; the human blanket-cleared them in practice), approval/manual/
  # secret -> 2 (today's behavior, unchanged). Explicit --tier can lower an
  # approval/decision/manual gate, EXCEPT: a secret gate is always tier 2, and
  # the T2 category floor below overrides everything.
  if [[ -n "$tier" ]]; then
    [[ "$tier" == "0" || "$tier" == "1" || "$tier" == "2" ]] \
      || fail "$E_VALIDATION" "bad --tier '$tier' (0=auto-clear | 1=48h-TTL-applies-rec | 2=hard human gate)"
  else
    case "$type" in decision) tier=1 ;; *) tier=2 ;; esac
  fi
  local tier_floored=0
  if [[ "$tier" != "2" ]]; then
    if [[ "$type" == "secret" ]]; then
      tier=2; tier_floored=1
    else
      local ttl_title; ttl_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
      if _gate_tier2_floor_hit "${ask} ${ttl_title}"; then
        tier=2; tier_floored=1
      fi
    fi
  fi
  [[ "$tier" == "0" && -z "$recommend" ]] \
    && fail "$E_USAGE" "--tier=0 auto-applies the recommendation, so --recommend is required"

  # OSS-11 (DIVE-976) decision-memory precedent prefill. This runs AFTER the tier
  # + T2 category floor are settled and the tier-0-requires-recommend check above,
  # so precedent can NEVER satisfy that requirement or change the resolved tier —
  # it only sources the VALUE of an advisory recommend. The DIVE-916 invariant
  # holds by construction: no tier mutation, no touch of the clear path
  # (cmd_task_answer / TTL / nonce), and a blank rec is filled ONLY when the tier
  # would have surfaced/applied a rec anyway.
  local ask_shape precedent_ref="" precedent_cite=""
  ask_shape=$(_gate_ask_shape "$ask")
  # Best prior ANSWERED gate: same need_type, EXACT ask_shape, from an equally- or
  # more-scrutinized tier (COALESCE(tier,2) so legacy NULL counts as T2 — a
  # rubber-stamped T0 can never prefill a T2 gate), answered within 90 days; most
  # recent wins. Exclude self (id<>).
  local _prow
  _prow=$(db "SELECT id||x'1f'||ident||x'1f'||COALESCE(need_answer,'')||x'1f'||
                     COALESCE(need_answered_at,'')||x'1f'||COALESCE(need_answered_by,'')
              FROM tasks
              WHERE need_answer IS NOT NULL AND id<>${id}
                AND need_type=$(sqlq "$type")
                AND ask_shape IS NOT NULL AND ask_shape=$(sqlq "$ask_shape")
                AND COALESCE(tier,2) >= ${tier}
                AND need_answered_at >= datetime('now','-90 day')
              ORDER BY need_answered_at DESC LIMIT 1;")
  if [[ -n "$_prow" ]]; then
    local _pid _pident _pans _pat _pby
    IFS=$'\x1f' read -r _pid _pident _pans _pat _pby <<<"$_prow"
    precedent_ref="$_pid"
    local _pwho="${_pby#human:}"; _pwho="${_pwho#auto:}"
    precedent_cite="Precedent: you answered '${_pans}' on ${_pident} (${_pat%% *}${_pwho:+, $_pwho})"
    # Prefill ONLY a blank recommend — never override an explicit filer rec. For a
    # decision the precedent answer must ALSO be one of THIS gate's options (shapes
    # match but option sets can differ); if it isn't, keep the citation but skip
    # the prefill so a tapped/displayed rec always maps to a real option.
    if [[ -z "$recommend" && -n "$_pans" ]]; then
      local _pok=1
      if [[ "$type" == "decision" ]]; then
        _pok=$(printf '%s' "$options" | jq -Rr --arg r "$_pans" '
          [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ]
          | (($r | gsub("^\\s+|\\s+$"; "")) as $rr | any(.[]; . == $rr)) | if . then "1" else "0" end' 2>/dev/null) || _pok=0
      fi
      [[ "$_pok" == "1" ]] && recommend="$_pans"
    fi
  fi

  # assignee=actor: the agent hitting the gate becomes the owner-of-record, so
  # `task answer` knows who to ping to resume. The inbox is defined by the gate
  # (need_type set), not by assignee, so it still surfaces to the human.
  local actor; actor=$(task_actor "$from")
  db "UPDATE tasks
        SET status='blocked', assignee=$(sqlq "$actor"),
            need_type=$(sqlq "$type"), ask=$(sqlq "$ask"),
            need_options=$(sqlq_or_null "$options"),
            recommend=$(sqlq_or_null "$recommend"),
            secret_key=$(sqlq_or_null "$secret_key"),
            connector=$(sqlq_or_null "$connector"),
            ask_shape=$(sqlq_or_null "$ask_shape"),
            precedent_ref=${precedent_ref:-NULL},
            tier=${tier}, need_asked_at=datetime('now'), gate_pinged_at=NULL,
            need_answer=NULL, need_answered_at=NULL
      WHERE id=${id};"

  # DIVE-891 tier 0: apply the recommendation right now — the gate exists only
  # as a signed-off record in the log/digest, never as a ping. Provenance is
  # 'auto:t0' (never human:*, so a loop approval gate can NOT be advanced this
  # way — _task_loop_advance requires human:*). No task_need_notify. The direct
  # answer write here intentionally skips cmd_task_answer's human-only checks:
  # tier 0 was validated above as outside every T2 category, which is exactly
  # the delegation the adopted design grants.
  if [[ "$tier" == "0" ]]; then
    local _ts0; _ts0=$(date -u '+%Y-%m-%d %H:%M:%S')
    db "UPDATE tasks SET need_answer=$(sqlq "$recommend"), need_answered_at=$(sqlq "$_ts0"),
          need_answered_by='auto:t0' WHERE id=${id};
        UPDATE tasks SET status='todo'
          WHERE id=${id} AND status='blocked'
            AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${id});"
    [[ $EUID -eq 0 ]] && audit_log "task need t0-auto" "ok" 0 -- "task=$ident" "type=$type" "applied=$recommend" || true
    ok "$ident tier-0 gate auto-cleared — applied: $recommend" \
       '{id:($i|tonumber), ident:$id, tier:0, auto_applied:$rc, need_type:$ty}' \
       --arg i "$id" --arg id "$ident" --arg rc "$recommend" --arg ty "$type"
    return
  fi

  # DIVE-105: DM the paired human right now so the gate doesn't sit unseen.
  # `|| true` + the helper's own self-gating make this fully best-effort — a
  # failed DM must never fail the gate write that just committed above.
  # DIVE-891: tier 1 gates still notify (they're answerable early); the 48h TTL
  # is a backstop, not a silencer. Only tier 0 skips the ping.
  # DIVE-916: mint the per-gate HUMAN nonce for hard human gates (approval/
  # secret/manual — the types `task answer` enforces as human-only). Store ONLY
  # its hash; the raw nonce is handed to task_need_notify to embed in the tap
  # callback_data. It is never printed to stdout, so the agent that filed the
  # gate never sees it. decision gates are agent-clearable → no nonce.
  local human_nonce=""
  case "$type" in
    approval|secret|manual)
      human_nonce=$(_human_nonce_mint)
      [[ -n "$human_nonce" ]] \
        && db "UPDATE tasks SET human_nonce_hash=$(sqlq "$(_human_nonce_sha "$human_nonce")") WHERE id=${id};"
      ;;
  esac
  task_need_notify "$ident" "$type" "$ask" "$options" "$recommend" "$secret_key" "$connector" "$human_nonce" "$precedent_cite" || true
  local floor_note=""; (( tier_floored )) && floor_note=" [tier forced to 2 — T2 category floor]"
  local prec_note=""; [[ -n "$precedent_cite" ]] && prec_note=" [${precedent_cite}]"
  ok "$ident needs a human ($type, tier $tier)${floor_note}${prec_note} — $ask" \
     '{id:($i|tonumber), ident:$id, status:"blocked", need_type:$ty, tier:($tr|tonumber), tier_floored:($fl=="1"), ask:$ak, need_options:(($op|select(length>0)) // null), recommend:(($rc|select(length>0)) // null), precedent_ref:(($pr|select(length>0))|tonumber? // null), assignee:$ac}' \
     --arg i "$id" --arg id "$ident" --arg ty "$type" --arg tr "$tier" --arg fl "$tier_floored" --arg ak "$ask" --arg op "$options" --arg rc "$recommend" --arg pr "$precedent_ref" --arg ac "$actor"
}

# _task_owner_channel — resolve the filing agent's bot token + the per-type
# access.json that holds the paired human's DM/group targets. Sets globals
# TASK_CH_TOKEN / TASK_CH_ACCESS / TASK_CH_TYPE and returns 0 on success, 1 if
# anything is missing (so callers `_task_owner_channel || return 0` to stay
# best-effort — a missing channel must never fail a committed DB write). Works
# whether run directly as agent-<name> (common — task verbs need no sudo) or via
# sudo (resolved like task_actor; token from the group-claude-readable connector
# file or an inherited env var). Shared by task_need_notify + _task_close_notify.
TASK_CH_TOKEN="" TASK_CH_ACCESS="" TASK_CH_TYPE=""
# DIVE-891: the by-NAME half of the resolution, split out so the heartbeat's
# gate-TTL sweep (which runs as root from cron — no sudo chain, no agent-* USER)
# can resolve a FILING AGENT's channel per gate row instead of from the caller.
_task_agent_channel() {
  TASK_CH_TOKEN="" TASK_CH_ACCESS="" TASK_CH_TYPE=""
  local name="$1"
  [[ -n "$name" ]] || return 1
  local token="" token_file="${CONNECTORS_DIR}/telegram-${name}.env"
  [[ -r "$token_file" ]] && token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$token_file" | head -1)
  [[ -z "$token" ]] && token="${TELEGRAM_BOT_TOKEN:-}"
  [[ -n "$token" ]] || return 1
  local t d
  for t in claude codex grok antigravity; do
    d=$(_tg_access_state_dir "agent-${name}" "$t") || continue
    if [[ -r "${d}/access.json" ]]; then
      TASK_CH_TOKEN="$token" TASK_CH_ACCESS="${d}/access.json" TASK_CH_TYPE="$t"
      return 0
    fi
  done
  return 1
}

_task_owner_channel() {
  local name="" s
  s=$(auto_sender_from_sudo)
  if [[ -n "$s" ]]; then
    name="$s"
  else
    local u="${USER:-$(id -un 2>/dev/null)}"
    [[ "$u" == agent-* ]] && name="${u#agent-}"
  fi
  _task_agent_channel "$name"
}

# _task_send_owner — send ONE message ($1, optional reply_markup $2) to the
# paired human, using the channel resolved by _task_owner_channel. Routing
# (DIVE-259, Mark): follow the conversation — if the telegram plugin recorded
# where the human last talked to this agent (last-human-chat.json beside
# access.json), the alert and its tap buttons go THERE, but only when that
# chat is still allowlisted in access.json (a stale or hand-edited pointer
# must never widen the audience). No pointer (plugin predates the feature) =
# legacy flow: human DMs first (allowFrom — exactly the users who /started
# the bot), then the agent's bound forum topic(s) so nothing is silently
# lost. Always returns 0 (best-effort).
_task_send_owner() {
  local text="$1" reply_markup="${2:-}"
  local token="$TASK_CH_TOKEN" access_file="$TASK_CH_ACCESS"

  local ptr_file="${access_file%/*}/last-human-chat.json"
  if [[ -r "$ptr_file" ]]; then
    local p_chat p_thread
    p_chat=$(jq -r '.chatId // empty' "$ptr_file" 2>/dev/null) || p_chat=""
    p_thread=$(jq -r '.messageThreadId // empty' "$ptr_file" 2>/dev/null) || p_thread=""
    if [[ -n "$p_chat" ]]; then
      if jq -e --arg c "$p_chat" '(.allowFrom // []) | index($c) != null' "$access_file" >/dev/null 2>&1; then
        _mirror_post "$token" "$p_chat" "" "$text" "$access_file" "$reply_markup"
        return 0
      fi
      if jq -e --arg c "$p_chat" '(.groups // {}) | has($c)' "$access_file" >/dev/null 2>&1; then
        _mirror_post "$token" "$p_chat" "$p_thread" "$text" "$access_file" "$reply_markup"
        return 0
      fi
      # Pointer references a chat that is no longer allowed — ignore it.
    fi
  fi

  local dms sent=0 chat
  dms=$(jq -r '(.allowFrom // [])[]' "$access_file" 2>/dev/null) || dms=""
  if [[ -n "$dms" ]]; then
    while IFS= read -r chat; do
      [[ -n "$chat" ]] || continue
      _mirror_post "$token" "$chat" "" "$text" "$access_file" "$reply_markup"
      sent=1
    done <<<"$dms"
  fi
  if (( ! sent )); then
    local groups n i g_chat g_thread
    groups=$(jq -c '(.groups // {}) | to_entries' "$access_file" 2>/dev/null) || groups="[]"
    n=$(jq 'length' <<<"$groups" 2>/dev/null) || n=0
    n=${n:-0}
    for (( i=0; i<n; i++ )); do
      g_chat=$(jq -r ".[$i].key" <<<"$groups" 2>/dev/null) || continue
      g_thread=$(jq -r ".[$i].value.message_thread_id // \"\"" <<<"$groups" 2>/dev/null) || g_thread=""
      [[ -n "$g_chat" ]] || continue
      _mirror_post "$token" "$g_chat" "$g_thread" "$text" "$access_file" "$reply_markup"
    done
  fi
  return 0
}

# _task_close_notify — DM the paired human a one-line ✅/⚠️ summary when a task
# is closed with --notify (used by the heartbeat nudge so autonomous queue work
# surfaces a finish line without full progress streaming). Best-effort: every
# miss returns 0 so it can't fail the status write the caller just committed.
_task_close_notify() {
  local ident="$1" verb="$2" result="$3"
  _task_owner_channel || return 0
  local text
  if [[ "$verb" == "cancel" ]]; then
    text="⚠️ [${ident}] cancelled"
  else
    text="✅ [${ident}] done"
  fi
  # Ping shows only the result's FIRST line — done-results lead with a one-line
  # summary; a full paragraph is too noisy on the owner's phone. The complete
  # result stays on the record (`task show` renders all of it).
  [[ -n "$result" ]] && text+=": ${result%%$'\n'*}"
  _task_send_owner "$text" ""
  return 0
}

# task_need_notify — DIVE-105: the instant a human gate is filed, DM the paired
# human ONE alert so it doesn't sit unseen until someone opens the dashboard.
# Best-effort + self-gating in the shape of mirror_interagent_outbound, and
# reusing its _mirror_post send path (migration self-heal included). EVERY exit
# path returns 0: a missing token / access.json / dead Telegram call must NEVER
# block or fail the gate write (the DB UPDATE already committed before we run).
# The caller also invokes us as `... || true`, so set -e can't trip on anything
# inside either.
#
# Works whether `task need` is run directly as agent-<name> (the common path —
# task verbs need no sudo) OR via sudo: the agent is resolved the same way
# task_actor does; the token comes from the group-claude-readable connector
# file (or an inherited env var); and access.json is found by probing the
# per-type channel dirs (own file when direct, root-readable when sudo).
# _task_mint_drop_link — DIVE-931. Mint a one-time secure credential drop link
# for a secret gate (api POST /drop/mint, box-authed with the box's connectord
# token). Echoes exactly one of:
#   <url>|<ttlMinutes>   a live burnable link (api pushes the value to the box)
#   ONBOX                 api holds no usable token for this box -> on-box path
#   (empty)               mint unavailable (self-hosted / api down) -> legacy text
# Best-effort: never fails the caller and never touches the secret VALUE (only the
# destination coordinates). The value crosses solely via the drop page -> stdin.
_task_mint_drop_link() {
  local ident="$1" secret_key="$2" connector="$3"
  local token="" env_file="/etc/5dive/connectord.env"
  [[ -n "${CONNECTORD_TOKEN:-}" ]] && token="$CONNECTORD_TOKEN"
  [[ -z "$token" && -r "$env_file" ]] && token=$(sed -n 's/^CONNECTORD_TOKEN=//p' "$env_file" | head -1)
  [[ -n "$token" ]] || return 0   # no box identity (self-hosted OSS) -> legacy text
  local api="${FIVE_API_BASE:-https://api.5dive.com}" body resp
  body=$(jq -nc --arg t "$ident" --arg k "$secret_key" --arg c "$connector" \
           '{taskIdent:$t, secretKey:$k, connector:$c, ttlMinutes:30}') || return 0
  resp=$(curl -fsS --max-time 10 -X POST "${api%/}/drop/mint" \
           -H "authorization: Bearer ${token}" -H "content-type: application/json" \
           -d "$body" 2>/dev/null) || return 0
  if [[ "$(printf '%s' "$resp" | jq -r '.useOnBoxPath // false' 2>/dev/null)" == "true" ]]; then
    echo "ONBOX"; return 0
  fi
  local url ttl
  url=$(printf '%s' "$resp" | jq -r '.url // empty' 2>/dev/null)
  ttl=$(printf '%s' "$resp" | jq -r '.ttlMinutes // empty' 2>/dev/null)
  [[ -n "$url" ]] || return 0
  echo "${url}|${ttl:-15}"
}

task_need_notify() {
  local ident="$1" need_type="$2" ask="$3" options="$4" recommend="${5:-}"
  local secret_key="${6:-}" connector="${7:-}" human_nonce="${8:-}"
  local precedent_cite="${9:-}"  # OSS-11: prior-answer citation, empty if none
  # DIVE-916: callback_data suffix carrying the raw per-gate nonce for the tap
  # paths (approval/secret/manual). Empty for decision (agent-clearable, no
  # nonce) so its `tna:<id>:<idx>` payload is byte-unchanged. The plugin `tna:`
  # handler treats a present 4th `:`-field as --human-proof.
  local _np=""; [[ -n "$human_nonce" ]] && _np=":${human_nonce}"

  # Resolve bot token + the human's DM/group targets (TASK_CH_* globals). The
  # matched access type (TASK_CH_TYPE) gates the tap-to-answer buttons below.
  _task_owner_channel || return 0

  # The /task_<n> deep link and tna:<n>:… callback both carry a BARE NUMBER that
  # the plugin re-resolves via `5dive task show/answer <n>` — and a bare number
  # resolves by the GLOBAL ROW ID, not the per-project issue number. Derive it
  # from the row id, never from the ident: `${ident#DIVE-}` yields the issue
  # number, which diverges from the row id once a non-default project consumes
  # global ids (DIVE-484/DIVE-561), and for a non-DIVE prefix wouldn't strip at
  # all — either way the tap would resolve the WRONG row (DIVE-561).
  local numid; numid=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$ident");")

  # One message. Blank lines separate the header / ask / options so a long ask
  # doesn't render as an unreadable wall on mobile. No footer: tap buttons cover
  # decision/approval, and button-less gates (secret/manual) still surface on
  # the dashboard "Needs you" card — a redirect line is just noise in chat.
  # Options are listed one per line (numbered to match the tap buttons) so long
  # labels stay readable even when Telegram crops the button text.
  # DIVE-148: lead with the agent's recommendation (✅ Recommended: <X>) before
  # the ask, so the human sees the advised choice first instead of hunting for
  # it. Applies to decision + approval gates; NULL/empty recommend = no line.
  local text="🙋 [${ident}] needs you"
  [[ -n "$recommend" ]] && text+=$'\n\n'"✅ Recommended: ${recommend}"
  # OSS-11 (DIVE-976): cite the precedent that sourced the recommendation so the
  # human sees WHY this choice is advised and can catch a wrong recall.
  [[ -n "$precedent_cite" ]] && text+=$'\n'"↩︎ ${precedent_cite}"
  # DIVE-390: append a bare, tappable /task_<id> link inline at the end of the
  # description sentence, before the options (Mark 2026-06-15). Telegram
  # auto-linkifies bare /commands, so tapping it fires the plugin's
  # ^/task_(\d+)$ handler -> `5dive task show <id>` (the full detail card). No
  # "details" label, numeric id only. A plain-text host shows an inert link.
  text+=$'\n\n'"${ask} /task_${numid}"
  if [[ "$need_type" == "decision" && -n "$options" ]]; then
    local opts_list
    # ⭐-mark the recommended option in the numbered list (numbering stays the
    # original option order so it still maps to need_options on the dashboard).
    opts_list=$(printf '%s' "$options" | jq -Rr --arg r "$recommend" '
      ($r | gsub("^\\s+|\\s+$"; "")) as $rr
      | [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ]
      | to_entries | map("  \(.key + 1). \(.value)\(if .value == $rr and ($rr|length)>0 then " ⭐" else "" end)") | join("\n")' 2>/dev/null) || opts_list=""
    [[ -n "$opts_list" ]] && text+=$'\n\n'"Options:"$'\n'"${opts_list}"
  fi

  # DIVE-356: secret/manual gates used to carry NO instruction on how to clear
  # them — the core of Mark's "a needs-you that needs no obvious action is
  # confusing" complaint. Add a type-specific CTA telling the human exactly what
  # to do + tap (the matching ✅ button is emitted below for plugin types).
  # DIVE-894: every CTA also carries the on-box CLI line. Boxes with no
  # dashboard (CLI-only self-hosted — lodar hit this live on DIVE-790) had no
  # recovery path when a tap fails; the answer command works on EVERY box, run
  # as a human login (claude/root — the human path clears approval/secret gates).
  case "$need_type" in
    secret)
      # DIVE-931: when the gate names a drop target (secret_key + connector), mint
      # a burnable single-use link so the human drops the credential straight onto
      # the box — the VALUE never transits chat, only the link does. Falls back to
      # the on-box `secret write` (tokenless boxes) or the legacy out-of-band text
      # (self-hosted / api unreachable). The box-side write auto-clears this gate.
      local _drop=""
      if [[ -n "$secret_key" && -n "$connector" ]]; then
        _drop=$(_task_mint_drop_link "$ident" "$secret_key" "$connector")
      fi
      if [[ "$_drop" == "ONBOX" ]]; then
        text+=$'\n\n'"🔑 [${ident}] needs the ${secret_key} credential. On the box, drop it straight in (never paste it here):"$'\n'"  echo -n \"\$SECRET\" | sudo 5dive secret write ${secret_key} --connector=${connector} --task=${ident}"$'\n'"That writes it and clears this gate. Or tap ✅ Provided once it is done."
      elif [[ -n "$_drop" ]]; then
        local _url="${_drop%%|*}" _ttl="${_drop##*|}"
        text+=$'\n\n'"🔑 [${ident}] needs the ${secret_key} credential. Drop it securely (single-use, expires in ${_ttl}m):"$'\n'"${_url}"$'\n'"The value goes straight onto your box and is never shown in chat. Prefer the box? echo -n \"\$SECRET\" | sudo 5dive secret write ${secret_key} --connector=${connector} --task=${ident}"
      else
        text+=$'\n\n'"🔑 Put the key where I expect it (my .env / our channel), then tap ✅ Provided below. Don't paste the key here. Tap not working? On the box: sudo 5dive task answer ${ident}"
      fi
      ;;
    manual) text+=$'\n\n'"✋ Tap ✅ Done below once it is handled, which closes this out. Or on the box: sudo 5dive task answer ${ident} --value=done" ;;
  esac

  # DIVE-117/118 tap-to-answer buttons. GATED to the plugin types whose `tna:`
  # callback_query handler exists AND splits options byte-identically to this
  # emit: claude, codex, grok, antigravity (DIVE-118 — parity verified against
  # the actual handlers). opencode has no `tna:` handler yet, so it stays
  # excluded to avoid dead taps; add it here when its handler lands. Explicit
  # allowlist (not != "") so a future new plugin type never auto-emits dead
  # taps. Only finite-option gates get
  # buttons: decision-with-options (index into need_options) and approval
  # (approved/denied). callback_data is `tna:<numericId>:<idx|approved|denied>`
  # — numeric id + index keeps it under Telegram's 64-byte cap; the value is
  # re-resolved from the DB on tap, never trusted from the payload.
  # The option-split rule here MUST be byte-identical to the plugin's `tna:`
  # handler (split '|', trim, drop empties) or a tapped index resolves the wrong
  # option. Filtering empties also avoids an empty-text button (Telegram rejects
  # it, which would 400 the whole message — see the text-fallback in
  # _mirror_post). If nothing survives the filter, emit no keyboard (plain text).
  local reply_markup=""
  if [[ "$TASK_CH_TYPE" =~ ^(claude|codex|grok|antigravity)$ ]]; then
    if [[ "$need_type" == "decision" && -n "$options" ]]; then
      # Adaptive layout: greedily pack buttons onto a row up to a ~24-char width
      # budget (max 3 per row), so SHORT options share a row while a LONG label
      # breaks onto its own full-width row instead of being cropped. A single
      # over-budget label still lands alone (we always seat the first button of
      # an empty row). Index (to_entries .key) is the tna: payload, unchanged.
      # DIVE-148: ⭐-prefix the recommended option's button and sort it first so
      # the human's eye lands on it. callback_data keeps the ORIGINAL option
      # index (.key) — the tna: handler resolves the value by that index into
      # need_options, so reordering the display must not renumber the payload.
      reply_markup=$(printf '%s' "$options" | jq -Rc --arg id "$numid" --arg r "$recommend" '
        ($r | gsub("^\\s+|\\s+$"; "")) as $rr
        | [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ] as $o
        | ($o | to_entries
           | sort_by(.value == $rr and ($rr|length)>0 | not)
           | reduce .[] as $e ({rows: [], cur: [], w: 0};
               (($e.value | length) + (if $e.value == $rr and ($rr|length)>0 then 2 else 0 end)) as $len
               | {text: (if $e.value == $rr and ($rr|length)>0 then "⭐ " + $e.value else $e.value end), callback_data: ("tna:" + $id + ":" + ($e.key | tostring))} as $btn
               | if (.cur | length) > 0 and ((.cur | length) >= 3 or (.w + $len + 2) > 24)
                 then {rows: (.rows + [.cur]), cur: [$btn], w: $len}
                 else {rows: .rows, cur: (.cur + [$btn]), w: (.w + $len + 2)}
                 end)
           | .rows + (if (.cur | length) > 0 then [.cur] else [] end)) as $kb
        | if ($kb | length) > 0 then {inline_keyboard: $kb} else empty end' 2>/dev/null) || reply_markup=""
    elif [[ "$need_type" == "approval" ]]; then
      # DIVE-148: ⭐-mark whichever button the agent recommended (approved/denied)
      # and seat it first. Default order (Approve, Deny) when no recommendation.
      local _rl; _rl=$(printf '%s' "$recommend" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
      # DIVE-916: ${_np} appends :<nonce> so the tap carries --human-proof.
      local _appr='{"text":"✅ Approve","callback_data":"tna:'"${numid}"':approved'"${_np}"'"}'
      local _deny='{"text":"🚫 Deny","callback_data":"tna:'"${numid}"':denied'"${_np}"'"}'
      case "$_rl" in
        approve|approved) _appr='{"text":"⭐ ✅ Approve","callback_data":"tna:'"${numid}"':approved'"${_np}"'"}'
                          reply_markup='{"inline_keyboard":[['"$_appr"','"$_deny"']]}' ;;
        deny|denied)      _deny='{"text":"⭐ 🚫 Deny","callback_data":"tna:'"${numid}"':denied'"${_np}"'"}'
                          reply_markup='{"inline_keyboard":[['"$_deny"','"$_appr"']]}' ;;
        *)                reply_markup='{"inline_keyboard":[['"$_appr"','"$_deny"']]}' ;;
      esac
    elif [[ "$need_type" == "secret" ]]; then
      # DIVE-356: one-tap "Provided" — the plugin handler runs `task answer <id>`
      # with NO value (the CLI rejects a value for a secret gate). Matches dev's
      # tna:<numid>:provided contract. DIVE-916: ${_np} appends the nonce.
      reply_markup='{"inline_keyboard":[[{"text":"✅ Provided","callback_data":"tna:'"${numid}"':provided'"${_np}"'"}]]}'
    elif [[ "$need_type" == "manual" ]]; then
      # DIVE-356: one-tap "Done" — handler runs `task answer <id> --value=done`.
      reply_markup='{"inline_keyboard":[[{"text":"✅ Done","callback_data":"tna:'"${numid}"':done'"${_np}"'"}]]}'
    fi
  fi

  # DIVE-894: no tap buttons landed (non-tna channel type, or no valid options)
  # — a decision/approval gate would otherwise render with no way to act on a
  # dashboard-less box. Append the copy-pasteable on-box answer line.
  if [[ -z "$reply_markup" ]]; then
    case "$need_type" in
      decision) text+=$'\n\n'"Answer on the box: sudo 5dive task answer ${ident} --value=\"<option>\"" ;;
      approval) text+=$'\n\n'"Answer on the box: sudo 5dive task answer ${ident} --value=approved (or denied)" ;;
    esac
  fi

  _task_send_owner "$text" "$reply_markup"
  return 0
}

cmd_task_inbox() {
  tasks_db_init
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  fail "$E_USAGE" "unexpected arg: $1 (inbox takes no positional args)" ;;
    esac
  done
  # A pending gate, decoupled from the overloaded `status` (a task can be both
  # human-gated and blocked-by another task): need set, not yet answered. We
  # still exclude TERMINAL statuses (done/cancelled) — a closed task waits on
  # no one, so a lingering unanswered gate must not leak into the human inbox.
  local where="need_type IS NOT NULL AND need_answered_at IS NULL AND status NOT IN ('done','cancelled')"
  local order="ORDER BY CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END, created_at"
  if (( JSON_MODE )); then
    local rows
    rows=$(dbfmt -json "SELECT id, ident, title, status, priority, assignee, created_by, parent_id, created_at, need_type, ask, need_options, recommend, precedent_ref, need_answer, need_answered_at FROM tasks WHERE ${where} ${order};")
    [[ -n "$rows" ]] || rows="[]"
    # stdin, not --argjson — same ARG_MAX guard as `task ls`. (DIVE-222)
    printf '%s' "$rows" | jq -c '{ok:true, data:{inbox:.}}'
  else
    local cnt; cnt=$(db "SELECT COUNT(*) FROM tasks WHERE ${where};")
    if [[ "$cnt" == "0" ]]; then
      echo "inbox empty — nothing waiting on a human."
    else
      dbfmt -box "SELECT ident, priority, need_type, COALESCE(assignee,'-') AS owner, COALESCE(recommend,'-') AS recommend, COALESCE((SELECT ident FROM tasks p WHERE p.id=tasks.precedent_ref),'-') AS precedent, ask FROM tasks WHERE ${where} ${order};"
    fi
  fi
}

# DIVE-519: `5dive gate-proof <id|DIVE-N> <approval|secret>` — root-only. Mints a
# human-origin proof token (RAW on stdout, never a --json envelope) that the
# trusted answer paths attach as --proof to clear an approval/secret gate: the
# Telegram plugin tap (mintGateProof shells here), the dashboard/shelld injector,
# and a human on the box (`task answer DIVE-N --proof=$(sudo 5dive gate-proof N approval)`).
# Subcommand `enforce on|off|status` toggles whether a missing/invalid proof is
# REJECTED (default off = audit-only) — see _gate_proof_enforced.
cmd_gate_proof() {
  # DIVE-756: root-only signer for the non-root answer path. Reads the canonical
  # closure payload on STDIN (so the human answer never enters argv) and prints
  # the HMAC raw. cmd_task_answer re-execs this over `sudo -n` when it isn't root.
  if [[ "${1:-}" == "sign" ]]; then
    require_root "gate-proof sign"
    tasks_db_init
    _gate_proof_ensure_key || fail "$E_GENERIC" "cannot provision gate-proof key (need root)"
    local _payload; _payload=$(cat)
    local _mac; _mac=$(_gate_proof_hmac "$_payload") || fail "$E_GENERIC" "failed to sign"
    printf '%s\n' "$_mac"
    return
  fi

  # DIVE-756: verify a stored closure signature. Root-only (needs the key). Recom-
  # putes the HMAC over the row's durable facts and reports signed/valid — a raw-
  # sqlite write that bypassed cmd_task_answer shows signed=absent or valid=false.
  # The detective half of the fix (enforcement of valid-or-reject is a later flip).
  if [[ "${1:-}" == "verify" ]]; then
    require_root "gate-proof verify"
    tasks_db_init
    local vref="${2:-}"
    [[ -n "$vref" ]] || fail "$E_USAGE" "usage: 5dive gate-proof verify <id|DIVE-N>"
    resolve_task_id "$vref"; local vid="$RESOLVED_TASK_ID" vident="$RESOLVED_TASK_IDENT"
    local _row; _row=$(db "SELECT
        COALESCE(need_type,'')||x'1f'||
        COALESCE(need_answer,'')||x'1f'||
        COALESCE(need_answered_by,'')||x'1f'||
        COALESCE(need_answered_at,'')||x'1f'||
        COALESCE(CAST(need_answered_uid AS TEXT),'')||x'1f'||
        COALESCE(need_answer_sig,'')
      FROM tasks WHERE id=${vid};")
    local _nt _na _nb _nat _nuid _nsig
    IFS=$'\x1f' read -r _nt _na _nb _nat _nuid _nsig <<<"$_row"
    [[ -n "$_nt" && -n "$_nat" ]] || fail "$E_CONFLICT" "$vident has no answered gate to verify"
    local _vfs=""; [[ "$_nt" != "secret" ]] && _vfs="$_na"
    local _signed=absent _valid=false
    if [[ -n "$_nsig" ]]; then
      _signed=present
      _gate_closure_verify "$vid" "$_nt" "$_vfs" "$_nb" "$_nat" "$_nuid" "$_nsig" && _valid=true
    fi
    audit_log "gate-proof verify" "$([[ "$_valid" == true ]] && echo ok || echo error)" 0 -- \
      "task=$vident" "type=$_nt" "signed=$_signed" "valid=$_valid" "uid=${_nuid:-}" "by=${_nb:-}"
    if (( JSON_MODE )); then
      ok "gate-proof verify $vident: signed=$_signed valid=$_valid" \
        '{ident:$i, signed:$s, valid:($v=="true"), uid:$u, by:$b}' \
        --arg i "$vident" --arg s "$_signed" --arg v "$_valid" --arg u "${_nuid:-}" --arg b "${_nb:-}"
    else
      echo "ident:  $vident"; echo "signed: $_signed"; echo "valid:  $_valid"
      echo "uid:    ${_nuid:-—}"; echo "by:     ${_nb:-—}"
    fi
    return
  fi

  if [[ "${1:-}" == "enforce" ]]; then
    require_root "gate-proof enforce"
    case "${2:-status}" in
      on)  : > "$GATE_PROOF_ENFORCE"; chmod 0644 "$GATE_PROOF_ENFORCE" 2>/dev/null || true
           ok "gate-proof enforcement ON: approval/secret/manual answers now require human evidence (a valid --human-proof nonce or a non-agent SUDO_UID)" ;;
      off) rm -f "$GATE_PROOF_ENFORCE"
           ok "gate-proof enforcement OFF: audit-only; approval/secret/manual answers allowed without human evidence" ;;
      status)
           local _e _k
           _gate_proof_enforced && _e=on || _e=off
           [[ -s "$GATE_PROOF_KEY" ]] && _k=present || _k=absent
           if (( JSON_MODE )); then
             ok "gate-proof: enforce=$_e key=$_k" '{enforce:$e, key:$k}' --arg e "$_e" --arg k "$_k"
           else
             echo "enforce: $_e"; echo "key: $_k"
           fi ;;
      *) fail "$E_USAGE" "usage: 5dive gate-proof enforce on|off|status" ;;
    esac
    return
  fi
  # DIVE-950: the `gate-proof <id> <type>` MINT path is REMOVED. The --proof token
  # it produced (evidence-form b) was agent-forgeable — `gate-proof` is require_root
  # only, so any agent could `sudo`-mint a valid token and self-clear a gate, no
  # higher a bar than the sudo it already had. Human evidence is now (a) the
  # per-gate --human-proof nonce (plugin tap / dashboard payload) or (c) a non-agent
  # SUDO_UID. `sign`/`verify`/`enforce` above remain (closure tamper-evidence +
  # the enforcement toggle). A stray mint caller gets a loud, AUDITED failure here
  # rather than a silent forge.
  require_root "gate-proof"
  audit_log "gate-proof mint" "error" 1 -- "removed=DIVE-950" "args=${1:-} ${2:-}"
  fail "$E_USAGE" "gate-proof mint is removed (DIVE-950): the --proof evidence form was agent-forgeable. Gates clear via a human tap (per-gate nonce) or a non-agent SUDO_UID. Valid subcommands: gate-proof enforce on|off|status | verify <id> | sign."
}

cmd_task_answer() {
  tasks_db_init
  local value="" value_set=0 from="" human=0 human_proof=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --value=*) value="${1#*=}"; value_set=1 ;;
      --from=*)  from="${1#*=}" ;;
      # DIVE-394: trusted human paths (the Telegram tap handler, the dashboard/API
      # exec) pass --human to mark the answer as human-sourced. Recorded as
      # provenance in need_answered_by; the enforced boundary for hard-line gates
      # is still root (below), so an agent passing --human gains nothing.
      --human)   human=1 ;;
      # DIVE-950: evidence-form (b), the DIVE-519 --proof token, is DROPPED — it
      # was agent-forgeable (`5dive gate-proof` mint is require_root only, so any
      # agent could `sudo`-mint a valid token: the easy one-sudo forge). The flag
      # is still PARSED but IGNORED — a rollout-safe no-op — so an in-flight caller
      # that still sends --proof=AUTO/<token> (an old dashboard/shelld mid-deploy)
      # does not hit "unknown flag"; it falls through to the surviving evidence
      # forms: (a) --human-proof nonce, or (c) a non-agent SUDO_UID.
      --proof=*) : ;;
      # DIVE-916: per-gate HUMAN nonce (from the Telegram tap callback_data /
      # dashboard payload) — the evidence form for the plugin-tap path, whose
      # SUDO_UID is the spawning agent. Verified against human_nonce_hash below.
      --human-proof=*) human_proof="${1#*=}" ;;
      --)        shift; positional+=("$@"); break ;;
      -*)        fail "$E_USAGE" "unknown flag: $1" ;;
      *)         positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task answer <id|DIVE-N> --value=\"...\"  (omit --value for a secret gate)"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  # Must have a pending (unanswered) gate to answer.
  local nt
  nt=$(db "SELECT CASE WHEN need_type IS NOT NULL AND need_answered_at IS NULL THEN need_type ELSE '' END FROM tasks WHERE id=${id};")
  [[ -n "$nt" ]] || fail "$E_CONFLICT" "$ident has no pending human gate (nothing to answer)"

  # DIVE-394: approval/secret are HUMAN-ONLY gates. Reject answers that come from
  # an agent acting as itself — that's the DIVE-391 incident, where an Olivia
  # endorsement (running as agent-<name>) silently cleared a human approval gate.
  # The boundary is the CALLER's unix identity, because the legitimate human
  # paths run as privileged, non-agent users while an agent runs as `agent-<name>`:
  #   - Telegram tap  -> plugin shells `sudo -n 5dive task answer` -> root
  #   - dashboard     -> API exec tunnel -> shelld runs as `claude` (non-root)
  #   - human on box  -> their own (non-agent) login
  #   - agent itself  -> `agent-<name>`  <- the only case we block
  # So: block when the caller is an `agent-*` user. This closes the reported
  # incident WITHOUT breaking either live path (root tap OR claude dashboard),
  # and needs no coordinated plugin/API deploy. decision/manual stay open: agents
  # legitimately resolve those. Residual: an agent that runs `sudo 5dive task
  # answer` becomes root and passes — closing that (require a --human secret the
  # trusted paths inject) is the documented fast-follow; the --human flag is
  # already parsed + recorded as provenance to stage it.
  # DIVE-916: `manual` joins approval/secret as a hard human gate here — it's a
  # step only a person can do, so an agent must not self-answer it either.
  if [[ "$nt" == "approval" || "$nt" == "secret" || "$nt" == "manual" ]]; then
    local _caller; _caller=$(id -un 2>/dev/null || echo '?')
    if [[ "$_caller" == agent-* ]]; then
      # No audit_log here: the blocked caller is an agent user that can't write
      # the root-owned audit log anyway (it would only leak a perms error to
      # stderr). The fail + non-zero exit is the record.
      fail "$E_AUTH_REQUIRED" "$ident is a '$nt' gate — only a human can clear it. Answer it from Telegram (tap the button) or the dashboard; an agent can't self-answer an approval/secret/manual gate."
    fi
  fi

  # DIVE-916/950: hard human gates (approval/secret/manual) need HUMAN evidence
  # beyond the agent-* uid block above — that block sees `sudo`->root as non-agent,
  # so it cannot catch the agent->sudo->root path. The trusted human paths supply
  # ONE of two evidence forms (see below): the per-gate --human-proof nonce (the
  # plugin tap, whose SUDO_UID is the spawning agent) or a non-agent SUDO_UID (the
  # dashboard exec as claude, the DIVE-931 drop write, a human-on-box login). We
  # ALWAYS audit the attempt; we only REJECT when NEITHER form is present, and only
  # once enforcement is flipped on (`gate-proof enforce on`). Ships DORMANT until
  # the nonce-carrying plugin is confirmed live FLEET-WIDE (else a live tap that
  # can't supply the nonce yet would fail closed). DIVE-950 dropped the old DIVE-519
  # --proof form: it was agent-forgeable via the require_root `gate-proof` mint.
  #
  # DIVE-525 (UX): a HUMAN's tap must NEVER be rejected — "you tapped but it's not
  # enough" is the exact confusion lodar hit dogfooding. Under enforcement we reject
  # ONLY when no evidence form is present (the forge: an agent's bare
  # `sudo task answer --human`, SUDO_UID=agent, no nonce). Every trusted path
  # supplies at least one form, so a real human is never blocked. The agent-* uid
  # block above + this rule stop the DIVE-515/516 incident (an agent silently
  # self-clearing). Bar-raise scope: closes the one-liner + the easy sudo-mint
  # forge, NOT a determined root-sudo agent (separate sudo-reduction track).
  if [[ "$nt" == "approval" || "$nt" == "secret" || "$nt" == "manual" ]]; then
    # DIVE-916/950: TWO EQUIVALENT human-evidence forms — accept EITHER one, never
    # require both (double-gating a real tap violates DIVE-525):
    #   (a) --human-proof=<nonce> matching this gate's stored hash — the plugin
    #       tap / dashboard payload, the one path whose SUDO_UID is the agent,
    #   (c) a non-agent SUDO_UID — a claude/root interactive login, the dashboard
    #       exec (shelld runs as SUDO_UID=claude), AND the DIVE-931 secret-drop
    #       write (SUDO_UID=claude survives the nested non-sudo task-answer exec;
    #       verified empirically).
    # DIVE-950 dropped the former form (b), a DIVE-519 --proof token: it was
    # agent-forgeable (`sudo 5dive gate-proof` mint is require_root only), so it
    # raised the bar no higher than the sudo it already required. This still
    # supersedes the DIVE-519 "proof OR bare --human" rule: a bare --human is NOT
    # sufficient — that was the sudo→--human forge (DIVE-916 threat).
    local _hp=0 _su=0
    [[ -n "$human_proof" ]] && _human_nonce_verify "$id" "$human_proof" && _hp=1
    _gate_sudo_uid_nonagent && _su=1
    local _evid=$(( _hp || _su ))
    local _caller2; _caller2=$(id -un 2>/dev/null || echo '?')
    audit_log "task answer gate" "$([[ $_evid -eq 1 ]] && echo ok || echo error)" 0 -- \
      "task=$ident" "type=$nt" \
      "human_proof=$([[ -n "$human_proof" ]] && echo present || echo absent)" "nonce_valid=$_hp" \
      "sudo_nonagent=$_su" "human=$human" "caller=$_caller2" "sudo_uid=${SUDO_UID:-}" \
      "enforce=$(_gate_proof_enforced && echo on || echo off)"
    # DIVE-525: a real human tap is NEVER rejected — every trusted path supplies
    # at least one evidence form (plugin→nonce, dashboard→proof/SUDO_UID=claude,
    # human-on-box→non-agent SUDO_UID, drop→SUDO_UID=claude). Under enforcement,
    # reject only when NONE is present (the forge: an agent's bare
    # `sudo task answer --human`). Ships DORMANT (audit-only) until the plugin
    # --human-proof injection is confirmed live fleet-wide; root then flips
    # `gate-proof enforce on` (Marcus ship-gates the flip).
    if _gate_proof_enforced && (( ! _evid )); then
      fail "$E_AUTH_REQUIRED" "$ident ($nt) needs a human to clear it — tap the button in Telegram or use the dashboard. (An agent can't self-clear an approval/secret/manual gate.)"
    fi
  fi

  # Who resumes: the agent that hit the gate (assignee), else the creator.
  local owner; owner=$(db "SELECT COALESCE(NULLIF(assignee,''), NULLIF(created_by,''), '') FROM tasks WHERE id=${id};")
  # DIVE-394 provenance: record WHO answered. `human:` prefix when a trusted path
  # passed --human; otherwise the resolved actor label.
  local answered_by; answered_by=$(task_actor "$from")
  (( human )) && answered_by="human:${answered_by}"

  # DIVE-756: stamp the REAL invoker uid ($SUDO_UID survives `sudo -u agent-X`,
  # unlike need_answered_by) and a tamper-evidence signature over the closure
  # facts. We compute the timestamp in shell (not datetime('now')) so the exact
  # same string is signed AND stored, letting `gate-proof verify` recompute it.
  # Signing needs the root-only key: in a root context we sign in-process; from
  # the non-root trusted path (dashboard exec as claude) we re-exec the root-only
  # `gate-proof sign` over sudo. Best-effort — a box that can't sign just stores
  # an empty sig (verify reports "unsigned"); the answer NEVER fails on this.
  local _uid="${SUDO_UID:-$(id -u 2>/dev/null || echo "")}"
  local _ts; _ts=$(date -u '+%Y-%m-%d %H:%M:%S')
  local _vfs=""; [[ "$nt" != "secret" ]] && _vfs="$value"
  local _sig=""
  if [[ -n "$_uid" ]]; then
    if [[ $EUID -eq 0 ]]; then
      _gate_proof_ensure_key 2>/dev/null || true
      _sig=$(_gate_closure_sign "$id" "$nt" "$_vfs" "$answered_by" "$_ts" "$_uid" 2>/dev/null || echo "")
    else
      _sig=$(_gate_closure_payload "$id" "$nt" "$_vfs" "$answered_by" "$_ts" "$_uid" \
               | sudo -n 5dive gate-proof sign 2>/dev/null || echo "")
    fi
  fi
  local _uidsql="NULL"; [[ -n "$_uid" ]] && _uidsql="$_uid"

  # Record the answer. A `secret` gate NEVER stores its value — writing a raw
  # key into this group-claude-readable db is a plaintext-secret-at-rest leak.
  # We only stamp need_answered_at (the "provided" signal); the agent loads the
  # key out-of-band. decision/approval/manual store the value in need_answer.
  if [[ "$nt" == "secret" ]]; then
    (( value_set )) && fail "$E_USAGE" "$ident is a secret gate — do not pass --value; the key must not be stored in the shared db. Run: 5dive task answer $ident  (records it as provided + pings the agent to load it from where you placed it)"
    db "UPDATE tasks SET need_answered_at=$(sqlq "$_ts"), need_answered_by=$(sqlq "$answered_by"), need_answered_uid=${_uidsql}, need_answer_sig=$(sqlq "$_sig") WHERE id=${id};"
  else
    (( value_set )) || fail "$E_USAGE" "--value is required (the human's answer)"
    db "UPDATE tasks SET need_answer=$(sqlq "$value"), need_answered_at=$(sqlq "$_ts"), need_answered_by=$(sqlq "$answered_by"), need_answered_uid=${_uidsql}, need_answer_sig=$(sqlq "$_sig") WHERE id=${id};"
  fi

  # DIVE-909: a standalone MANUAL gate answered "done" is the human saying "this
  # is handled / complete" — close the task as DONE, not back to todo. Without
  # this a park-marker holding COMPLETED work had no honest close: the agent
  # can't `task done` (blocked by its own pending gate, DIVE-555) and the only
  # agent-allowed escape was `task cancel`, which mislabels finished work as
  # cancelled (DIVE-524). The already-shipped ✅ Done tap (tna:<id>:done ->
  # `task answer --value=done`, DIVE-356) now lands here and closes cleanly — no
  # plugin/fork change needed. Loop GATE steps are EXEMPT (_lk=gate:*): a manual
  # answer there drives the relay advance below, which owns that status move.
  local _lk; _lk=$(_loop_kind "$id")
  local _close_done=0
  if [[ "$nt" == "manual" && "$_lk" != gate:* ]]; then
    local _dv; _dv=$(printf '%s' "${value:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    [[ "$_dv" == "done" ]] && _close_done=1
  fi
  if (( _close_done )); then
    # Close as done + stamp a result IF empty (never clobber real work notes) so
    # the dashboard/creator sees why it closed rather than a blank card.
    db "UPDATE tasks SET status='done', done_at=datetime('now'),
           result=CASE WHEN COALESCE(result,'')='' THEN 'Closed via manual-gate tap — marked done by '||$(sqlq "$answered_by") ELSE result END
        WHERE id=${id};"
  else
    # Clearing the gate ≠ unblocking. `status='blocked'` is overloaded (human
    # gate AND task-task `block` edges), so RECOMPUTE rather than hardcode todo:
    # flip to todo only if no block edges remain — same edge-check `unblock` does
    # — else stay blocked (still waiting on another task). Answered-ness lives in
    # need_answered_at, so the task already left the inbox regardless of status.
    db "UPDATE tasks SET status='todo'
        WHERE id=${id} AND status='blocked'
          AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${id});"
  fi
  local newstatus; newstatus=$(db "SELECT status FROM tasks WHERE id=${id};")

  # DIVE-552: a loop GATE step was just answered → advance the relay. Approve
  # (decision "Approve →", or any manual answer) closes the gate step and frees
  # the next step; "Do better ↩" bounces to the previous step to redo (re-blocks
  # the gate by it; when that step re-completes the gate re-fires fresh). Reuses
  # _task_loop_advance + the block edges. Best-effort; never fails the answer.
  # (_lk was resolved above for the DIVE-909 close-as-done check — reuse it.)
  # DIVE-560: a loop APPROVAL gate only advances on a HUMAN-cleared answer
  # (need_answered_by=human:*). The answer path above already blocks an agent
  # self-answering an approval gate; this makes the loop's "the final say is
  # yours" guarantee explicit and regression-proof — if a non-human path ever
  # clears it (e.g. a future regression, or the audited sudo-bypass), the relay
  # simply doesn't advance. manual gates stay agent-answerable (agents
  # legitimately resolve those), so they're exempt. Falling through here without
  # advancing still records the answer + emits the success output below.
  local _gate_may_advance=1
  if [[ "$_lk" == "gate:approval" ]]; then
    local _ab; _ab=$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE id=${id};")
    case "$_ab" in human:*) : ;; *) _gate_may_advance=0 ;; esac
  fi
  case "$_lk" in
    gate:*)
      if (( _gate_may_advance )); then
      # Bounce (redo the previous step) vs advance. Match the reject vocabulary
      # of BOTH gate styles: the old decision options ("Do better ↩") and the
      # approval buttons ("denied" — DIVE-560). NB "denied" does NOT contain the
      # substring "deny", so it must be matched explicitly; missing it would let a
      # human's DENY silently ADVANCE the loop. Anything else (approve/approved)
      # advances.
      local _lv; _lv=$(printf '%s' "${value:-}" | tr '[:upper:]' '[:lower:]')
      if [[ "$_lv" == *"better"* || "$_lv" == *"reject"* || "$_lv" == *"deny"* || "$_lv" == *"denied"* || "$_lv" == *"declin"* ]]; then
        local _run _prev
        _run=$(db "SELECT COALESCE(parent_id,'') FROM tasks WHERE id=${id};")
        _prev=$(db "SELECT id FROM tasks WHERE parent_id=${_run:-0} AND id<${id} AND body LIKE '%${_LOOP_MARK}:%' ORDER BY id DESC LIMIT 1;")
        if [[ -n "$_prev" ]]; then
          db "INSERT OR IGNORE INTO task_deps (task_id, blocked_by) VALUES (${id}, ${_prev});
              UPDATE tasks SET status='blocked' WHERE id=${id};
              UPDATE tasks SET status='todo', started_at=NULL WHERE id=${_prev};"
          local _pw _pl; _pw=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${_prev};"); _pl=$(db "SELECT title FROM tasks WHERE id=${_prev};")
          [[ -n "$_pw" ]] && ( cmd_send "$_pw" --from="loop" --message="↩ Loop bounced back — redo: ${_pl}" ) >/dev/null 2>&1 || true
        fi
      else
        db "UPDATE tasks SET status='done', done_at=datetime('now') WHERE id=${id};"
        _task_loop_advance "$id" || true
      fi
      fi
      ;;
  esac

  # Best-effort resume ping over the existing agent-send path. We deliberately
  # do NOT embed the answer value: cmd_send mirrors the outbound into the group
  # chat, so a `secret` answer would leak. The agent reads need_answer itself
  # via `task show` (its own pane only). A stopped or non-agent owner just
  # yields pinged:false — it never fails the answer.
  local pinged=0
  # DIVE-909: a close-as-done manual gate needs no "resume the task" ping — the
  # task is finished, not waiting to resume. Skip it (the `now done` output is
  # the signal); pinging the owner to resume a closed task is just confusing.
  if [[ -n "$owner" ]] && (( ! _close_done )); then
    local pingmsg
    if [[ "$nt" == "secret" ]]; then
      pingmsg="${ident} secret gate marked provided — resume the task and load the key from where it was placed (its .env / your own channel), NOT from the task."
    else
      pingmsg="${ident} gate cleared — your '${nt}' ask was answered. Resume the task; run \`5dive task show ${ident}\` for the value."
    fi
    local actor; actor=$(task_actor "$from")
    if valid_sender_label "$actor"; then
      ( cmd_send "$owner" --from="$actor" --message="$pingmsg" ) >/dev/null 2>&1 && pinged=1 || true
    else
      ( cmd_send "$owner" --message="$pingmsg" ) >/dev/null 2>&1 && pinged=1 || true
    fi
  fi

  local note=""
  [[ $pinged -eq 1 ]] && note=" + pinged $owner"
  ok "$ident answered ($nt) — now ${newstatus}${note}" \
     '{id:($i|tonumber), status:$st, need_type:$nt, provided:true, need_answer:(if $nt=="secret" then null else $v end), owner:(($o|select(length>0)) // null), pinged:($p=="1")}' \
     --arg i "$id" --arg st "$newstatus" --arg nt "$nt" --arg v "$value" --arg o "$owner" --arg p "$pinged"
}

# cmd_task_escalate — DIVE-449: the /task_<id> Telegram "Escalate" button (and a
# plain CLI verb). Semantics A (Mark's call 2026-06-17): "flag for attention" —
# bump the task's priority up ONE tier (capped at urgent) AND ping both the
# owning agent ("get eyes on it / I'm stuck") and the paired human, so a stuck
# task can't sit unseen at its old priority. Does NOT file a human gate (that's
# `task need`) or reassign (that's `task assign`). The bump + escalated_at/by
# audit stamp persist; the two pings are best-effort and never fail the verb.
cmd_task_escalate() {
  tasks_db_init
  local from=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from=*) from="${1#*=}" ;;
      --)       shift; positional+=("$@"); break ;;
      -*)       fail "$E_USAGE" "unknown flag: $1" ;;
      *)        positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task escalate <id|DIVE-N>"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"

  # Don't escalate a finished task — there's nothing to get eyes on.
  local status; status=$(db "SELECT status FROM tasks WHERE id=${id};")
  [[ "$status" == "done" || "$status" == "cancelled" ]] && \
    fail "$E_CONFLICT" "$ident is $status — nothing to escalate."

  local old_pri title assignee created_by
  old_pri=$(db "SELECT COALESCE(priority,'medium') FROM tasks WHERE id=${id};")
  title=$(db "SELECT title FROM tasks WHERE id=${id};")
  # Who to get eyes on it: the assignee, else the creator.
  local owner; owner=$(db "SELECT COALESCE(NULLIF(assignee,''), NULLIF(created_by,''), '') FROM tasks WHERE id=${id};")

  # Bump up one tier, capped at urgent. low/medium -> high keeps the common
  # "this is stuck" tap meaningful; a second tap on a high task reaches urgent.
  local new_pri
  case "$old_pri" in
    low|medium) new_pri="high" ;;
    high)       new_pri="urgent" ;;
    urgent)     new_pri="urgent" ;;
    *)          new_pri="high" ;;
  esac

  local actor; actor=$(task_actor "$from")
  db "UPDATE tasks SET priority=$(sqlq "$new_pri"), escalated_at=datetime('now'), escalated_by=$(sqlq "$actor") WHERE id=${id};"

  local pri_note="$old_pri → $new_pri"
  [[ "$old_pri" == "$new_pri" ]] && pri_note="$new_pri (already top tier)"

  # Ping the owning agent over the existing agent-send path — but never ping the
  # actor about its own task (an agent escalating its own work already knows).
  local pinged=0
  if [[ -n "$owner" && "$owner" != "$actor" ]]; then
    local pingmsg="🔺 ${ident} escalated by ${actor} — flagged as needing attention (priority ${pri_note}). Get eyes on it; run \`5dive task show ${ident}\`."
    if valid_sender_label "$actor"; then
      ( cmd_send "$owner" --from="$actor" --message="$pingmsg" ) >/dev/null 2>&1 && pinged=1 || true
    else
      ( cmd_send "$owner" --message="$pingmsg" ) >/dev/null 2>&1 && pinged=1 || true
    fi
  fi

  # Ping the paired human so an escalation surfaces on their phone (best-effort,
  # mirrors task_need_notify's owner-channel resolution + send path).
  local notified_human=0
  if _task_owner_channel; then
    local htext="🔺 [${ident}] escalated by ${actor} — needs attention"$'\n\n'"${title}"$'\n\n'"priority ${pri_note}"
    _task_send_owner "$htext" "" && notified_human=1 || true
  fi

  local note=""
  [[ $pinged -eq 1 ]] && note=" + pinged $owner"
  ok "$ident escalated — priority ${pri_note}${note}" \
     '{id:($i|tonumber), priority:$np, was:$op, owner:(($o|select(length>0)) // null), pinged:($p=="1"), human_notified:($h=="1")}' \
     --arg i "$id" --arg np "$new_pri" --arg op "$old_pri" --arg o "$owner" --arg p "$pinged" --arg h "$notified_human"
}

cmd_task_rm() {
  tasks_db_init
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task rm <id|DIVE-N>"
  resolve_task_id "$1"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  db "DELETE FROM tasks WHERE id=${id};"
  ok "$ident deleted" '{id:($i|tonumber), deleted:true}' --arg i "$id"
}
