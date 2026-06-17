
# -------- 5dive task — host-shared task queue --------

_task_usage() {
  cat <<USAGE
5dive task — shared task queue (sqlite at ${STATE_DIR}/tasks/tasks.db)

  5dive task init                                    # one-time root bootstrap of the store
  5dive task add <title...> [--body=<text>] [--priority=low|medium|high|urgent]
                            [--assignee=<agent>] [--parent=<id|DIVE-N>] [--from=<who>]
                            [--recurring="<cron>"]  # recurring=template (5-field cron, e.g. "0 2 * * *")
  5dive task ls [--status=<s>] [--assignee=<agent>] [--mine] [--all] [--recurring]
                                                     # default: open tasks, priority-ordered; --recurring: templates
  5dive task show <id|DIVE-N>                        # full detail + subtasks + blockers
  5dive task assign <id|DIVE-N> <agent>
  5dive task start  <id|DIVE-N>                      # -> in_progress
  5dive task done   <id|DIVE-N> [--result=<text>]    # -> done; --result captures the agent's response
  5dive task cancel <id|DIVE-N> [--result=<text>]    # -> cancelled; --result captures why
  5dive task block   <id|DIVE-N> --by=<id|DIVE-N>    # add a blocks edge, mark blocked
  5dive task unblock <id|DIVE-N> [--by=<id|DIVE-N>]  # drop edge(s); back to todo if clear
  5dive task rm <id|DIVE-N>                          # delete (cascades subtasks + edges)
  5dive task escalate <id|DIVE-N> [--from=<who>]     # flag for attention: bump priority a tier (cap urgent) + ping owning agent & paired human

  # Human Task Inbox — park a task on a human and clear it
  5dive task need <id|DIVE-N> --type=decision|secret|approval|manual --ask="..." [--options=A|B] [--recommend="A"]
    --ask: ONE crisp question + ~1 line essential context, recommendation up front. Heavy detail goes in the task BODY, not the ask.
    --recommend: your advised choice (strongly encouraged for decision/approval). Leads the alert as '✅ Recommended: <X>' and ⭐-marks its button. For a decision it must match one of --options.
                                                     # -> blocked, awaiting a human (decision/secret/approval/manual)
  5dive task inbox                                   # list ONLY human-gated tasks, priority-ordered
  5dive task answer <id|DIVE-N> --value="..."        # record the human's answer, unblock, ping the owning agent

  status: todo | in_progress | blocked | done | cancelled
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

cmd_task_add() {
  tasks_db_init
  local body="" priority="medium" assignee="" parent="" from="" recurring="" fresh=""
  local -a words=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --body=*)      body="${1#*=}" ;;
      --priority=*)  priority="${1#*=}" ;;
      --assignee=*)  assignee="${1#*=}" ;;
      --parent=*)    parent="${1#*=}" ;;
      --from=*)      from="${1#*=}" ;;
      --recurring=*) recurring="${1#*=}" ;;
      --schedule=*)  recurring="${1#*=}" ;;
      --fresh)       fresh="1" ;;
      --no-fresh)    fresh="0" ;;
      --)            shift; words+=("$@"); break ;;
      -*)            fail "$E_USAGE" "unknown flag: $1" ;;
      *)             words+=("$1") ;;
    esac
    shift
  done
  local title="${words[*]:-}"
  [[ -n "$title" ]] || fail "$E_USAGE" "usage: 5dive task add <title...> [--body=] [--priority=] [--assignee=] [--parent=] [--recurring=\"<cron>\"]"
  valid_task_priority "$priority" || fail "$E_VALIDATION" "bad priority '$priority' (low|medium|high|urgent)"
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
  local parent_sql="NULL"
  if [[ -n "$parent" ]]; then
    resolve_task_id "$parent"; parent_sql="$RESOLVED_TASK_ID"
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
  local auto_coordinated=0
  if [[ -z "$assignee" && "$kind" == "standard" ]]; then
    assignee=$(_task_resolve_coordinator)
    [[ -n "$assignee" ]] && auto_coordinated=1
  fi
  local creator; creator=$(task_actor "$from")
  local id
  id=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, parent_id, kind, schedule, fresh)
           VALUES ($(sqlq "$title"), $(sqlq_or_null "$body"), $(sqlq "$priority"),
                   $(sqlq_or_null "$assignee"), $(sqlq "$creator"), ${parent_sql},
                   $(sqlq "$kind"), ${schedule_sql}, ${fresh_sql});
           SELECT last_insert_rowid();")
  if [[ "$kind" == "recurring" ]]; then
    ok "created recurring DIVE-$id (${recurring}, fresh=$([[ "$fresh_sql" == "1" ]] && echo on || echo off)) — $title" \
       '{id:($i|tonumber), ident:("DIVE-"+$i), title:$t, priority:$p, assignee:$a, created_by:$c, kind:"recurring", schedule:$s, fresh:($f=="1")}' \
       --arg i "$id" --arg t "$title" --arg p "$priority" --arg a "${assignee:-}" --arg c "$creator" --arg s "$recurring" --arg f "$fresh_sql"
  else
    local coord_note=""
    (( auto_coordinated )) && coord_note=" → coordinator: $assignee"
    ok "created DIVE-$id — $title${coord_note}" \
       '{id:($i|tonumber), ident:("DIVE-"+$i), title:$t, priority:$p, assignee:$a, created_by:$c, kind:"standard", autoCoordinated:($ac=="1")}' \
       --arg i "$id" --arg t "$title" --arg p "$priority" --arg a "${assignee:-}" --arg c "$creator" --arg ac "$auto_coordinated"
  fi
}

cmd_task_ls() {
  tasks_db_init
  local status="" assignee="" mine=0 all=0 from="" recurring=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status=*)   status="${1#*=}" ;;
      --assignee=*) assignee="${1#*=}" ;;
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
  if (( JSON_MODE )); then
    local rows
    rows=$(dbfmt -json "SELECT id, ident, title, status, priority, assignee, created_by, parent_id, created_at, done_at, body, result, need_type, ask, need_options, need_answer, need_answered_at, kind, schedule, last_fired_at, parked_at, park_reason FROM tasks WHERE ${where} ${order};")
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
    # Human gate (only when set) — mirrors the conditional subtasks/blockers
    # blocks below so an ordinary task's `show` stays clean.
    local gate
    gate=$(db "SELECT 'type: '||need_type||
                      CASE WHEN need_options IS NOT NULL THEN '  options: '||need_options ELSE '' END||
                      CASE WHEN recommend IS NOT NULL THEN x'0a'||'recommend: '||recommend ELSE '' END||x'0a'||
                      'ask:  '||COALESCE(ask,'')||
                      CASE WHEN need_answered_at IS NOT NULL
                           THEN x'0a'||'answer: '||CASE WHEN need_type='secret' THEN '(provided — loaded out-of-band)' ELSE COALESCE(need_answer,'') END||'  ('||need_answered_at||')'
                           ELSE x'0a'||'answer: — pending' END
               FROM tasks WHERE id=${id} AND need_type IS NOT NULL;")
    [[ -n "$gate" ]] && { echo; echo "human gate:"; printf '%s\n' "$gate" | indent2; }
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
  resolve_task_id "$1"; local id="$RESOLVED_TASK_ID"
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
  ok "DIVE-$id assigned to $who" '{id:($i|tonumber), assignee:$a}' --arg i "$id" --arg a "$who"
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
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID"
  local set_result=""
  if (( want_result )); then
    set_result=", result=$(sqlq_or_null "$result")"
  fi
  db "UPDATE tasks SET status=$(sqlq "$newstatus")${extra}${set_result} WHERE id=${id};"
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
      _task_close_notify "DIVE-$id" "$verb" "$result" || true
    fi
  fi
  ok "DIVE-$id $verb" '{id:($i|tonumber), status:$s}' --arg i "$id" --arg s "$newstatus"
}

cmd_task_start()  { _task_status_cmd in_progress ", started_at=COALESCE(started_at, datetime('now'))" start "$@"; }
cmd_task_done()   { _task_status_cmd done ", done_at=datetime('now')" done "$@"; }
cmd_task_cancel() { _task_status_cmd cancelled ", done_at=datetime('now')" cancel "$@"; }

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
  resolve_task_id "$task"; local tid="$RESOLVED_TASK_ID"
  resolve_task_id "$by";   local bid="$RESOLVED_TASK_ID"
  [[ "$tid" != "$bid" ]] || fail "$E_VALIDATION" "a task can't block itself"
  db "INSERT OR IGNORE INTO task_deps (task_id, blocked_by) VALUES (${tid}, ${bid});
      UPDATE tasks SET status='blocked' WHERE id=${tid} AND status NOT IN ('done','cancelled');"
  ok "DIVE-$tid blocked by DIVE-$bid" '{task:($t|tonumber), blocked_by:($b|tonumber)}' --arg t "$tid" --arg b "$bid"
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
  resolve_task_id "$task"; local tid="$RESOLVED_TASK_ID"
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
  ok "DIVE-$tid unblocked" '{task:($t|tonumber)}' --arg t "$tid"
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
  local task="" reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason=*) reason="${1#*=}" ;;
      -*)         fail "$E_USAGE" "unknown flag: $1" ;;
      *)          [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task park <id|DIVE-N> --reason=<why / what unblocks it>"
  resolve_task_id "$task"; local tid="$RESOLVED_TASK_ID"
  db "UPDATE tasks
        SET status='blocked', parked_at=datetime('now'), park_reason=$(sqlq "$reason"),
            need_type=NULL, ask=NULL, need_options=NULL, recommend=NULL,
            need_answer=NULL, need_answered_at=NULL
      WHERE id=${tid} AND status NOT IN ('done','cancelled');"
  ok "DIVE-$tid parked (no action needed)${reason:+ — $reason}" \
     '{task:($t|tonumber), parked:true, reason:$r}' --arg t "$tid" --arg r "$reason"
}

# Clear a park -> back to todo (unless real dependency edges still block it).
cmd_task_unpark() {
  tasks_db_init
  local task="${1:-}"
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task unpark <id|DIVE-N>"
  resolve_task_id "$task"; local tid="$RESOLVED_TASK_ID"
  db "UPDATE tasks SET parked_at=NULL, park_reason=NULL,
        status=CASE WHEN status='blocked'
                     AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${tid})
                    THEN 'todo' ELSE status END
      WHERE id=${tid} AND status NOT IN ('done','cancelled');"
  ok "DIVE-$tid unparked" '{task:($t|tonumber)}' --arg t "$tid"
}

# --- Human Task Inbox (DIVE-103; parent feature DIVE-102) ----------------
# `need` parks a task on a human; `inbox` lists what's waiting; `answer`
# records the human's reply, unblocks, and pings the agent that hit the gate.

cmd_task_need() {
  tasks_db_init
  local type="" ask="" options="" recommend="" from=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type=*)      type="${1#*=}" ;;
      --ask=*)       ask="${1#*=}" ;;
      --options=*)   options="${1#*=}" ;;
      --recommend=*) recommend="${1#*=}" ;;
      --from=*)      from="${1#*=}" ;;
      --)          shift; positional+=("$@"); break ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task need <id|DIVE-N> --type=decision|secret|approval|manual --ask=\"...\" [--options=A|B] [--recommend=\"A\"]"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID"
  valid_need_type "$type" || fail "$E_VALIDATION" "bad --type '$type' (decision|secret|approval|manual)"
  [[ -n "$ask" ]] || fail "$E_USAGE" "--ask is required (what does the human need to provide?)"
  # Options are the choice list for a decision; reject them on the other types
  # so the gate shape stays honest for the dashboard.
  if [[ -n "$options" && "$type" != "decision" ]]; then
    fail "$E_VALIDATION" "--options only applies to --type=decision"
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
    && fail "$E_CONFLICT" "DIVE-$id is $cur — reopen it before gating on a human"
  # assignee=actor: the agent hitting the gate becomes the owner-of-record, so
  # `task answer` knows who to ping to resume. The inbox is defined by the gate
  # (need_type set), not by assignee, so it still surfaces to the human.
  local actor; actor=$(task_actor "$from")
  db "UPDATE tasks
        SET status='blocked', assignee=$(sqlq "$actor"),
            need_type=$(sqlq "$type"), ask=$(sqlq "$ask"),
            need_options=$(sqlq_or_null "$options"),
            recommend=$(sqlq_or_null "$recommend"),
            need_answer=NULL, need_answered_at=NULL
      WHERE id=${id};"
  # DIVE-105: DM the paired human right now so the gate doesn't sit unseen.
  # `|| true` + the helper's own self-gating make this fully best-effort — a
  # failed DM must never fail the gate write that just committed above.
  task_need_notify "DIVE-$id" "$type" "$ask" "$options" "$recommend" || true
  ok "DIVE-$id needs a human ($type) — $ask" \
     '{id:($i|tonumber), ident:("DIVE-"+$i), status:"blocked", need_type:$ty, ask:$ak, need_options:(($op|select(length>0)) // null), recommend:(($rc|select(length>0)) // null), assignee:$ac}' \
     --arg i "$id" --arg ty "$type" --arg ak "$ask" --arg op "$options" --arg rc "$recommend" --arg ac "$actor"
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
_task_owner_channel() {
  TASK_CH_TOKEN="" TASK_CH_ACCESS="" TASK_CH_TYPE=""
  local name="" s
  s=$(auto_sender_from_sudo)
  if [[ -n "$s" ]]; then
    name="$s"
  else
    local u="${USER:-$(id -un 2>/dev/null)}"
    [[ "$u" == agent-* ]] && name="${u#agent-}"
  fi
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
task_need_notify() {
  local ident="$1" need_type="$2" ask="$3" options="$4" recommend="${5:-}"

  # Resolve bot token + the human's DM/group targets (TASK_CH_* globals). The
  # matched access type (TASK_CH_TYPE) gates the tap-to-answer buttons below.
  _task_owner_channel || return 0

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
  # DIVE-390: append a bare, tappable /task_<id> link inline at the end of the
  # description sentence, before the options (Mark 2026-06-15). Telegram
  # auto-linkifies bare /commands, so tapping it fires the plugin's
  # ^/task_(\d+)$ handler -> `5dive task show <id>` (the full detail card). No
  # "details" label, numeric id only. A plain-text host shows an inert link.
  text+=$'\n\n'"${ask} /task_${ident#DIVE-}"
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
  case "$need_type" in
    secret) text+=$'\n\n'"🔑 Put the key where I expect it (my .env / our channel), then tap ✅ Provided below. Don't paste the key here." ;;
    manual) text+=$'\n\n'"✋ Tap ✅ Done below once it's handled." ;;
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
  local reply_markup="" numid="${ident#DIVE-}"
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
      local _appr='{"text":"✅ Approve","callback_data":"tna:'"${numid}"':approved"}'
      local _deny='{"text":"🚫 Deny","callback_data":"tna:'"${numid}"':denied"}'
      case "$_rl" in
        approve|approved) _appr='{"text":"⭐ ✅ Approve","callback_data":"tna:'"${numid}"':approved"}'
                          reply_markup='{"inline_keyboard":[['"$_appr"','"$_deny"']]}' ;;
        deny|denied)      _deny='{"text":"⭐ 🚫 Deny","callback_data":"tna:'"${numid}"':denied"}'
                          reply_markup='{"inline_keyboard":[['"$_deny"','"$_appr"']]}' ;;
        *)                reply_markup='{"inline_keyboard":[['"$_appr"','"$_deny"']]}' ;;
      esac
    elif [[ "$need_type" == "secret" ]]; then
      # DIVE-356: one-tap "Provided" — the plugin handler runs `task answer <id>`
      # with NO value (the CLI rejects a value for a secret gate). Matches dev's
      # tna:<numid>:provided contract.
      reply_markup='{"inline_keyboard":[[{"text":"✅ Provided","callback_data":"tna:'"${numid}"':provided"}]]}'
    elif [[ "$need_type" == "manual" ]]; then
      # DIVE-356: one-tap "Done" — handler runs `task answer <id> --value=done`.
      reply_markup='{"inline_keyboard":[[{"text":"✅ Done","callback_data":"tna:'"${numid}"':done"}]]}'
    fi
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
    rows=$(dbfmt -json "SELECT id, ident, title, status, priority, assignee, created_by, parent_id, created_at, need_type, ask, need_options, recommend, need_answer, need_answered_at FROM tasks WHERE ${where} ${order};")
    [[ -n "$rows" ]] || rows="[]"
    # stdin, not --argjson — same ARG_MAX guard as `task ls`. (DIVE-222)
    printf '%s' "$rows" | jq -c '{ok:true, data:{inbox:.}}'
  else
    local cnt; cnt=$(db "SELECT COUNT(*) FROM tasks WHERE ${where};")
    if [[ "$cnt" == "0" ]]; then
      echo "inbox empty — nothing waiting on a human."
    else
      dbfmt -box "SELECT ident, priority, need_type, COALESCE(assignee,'-') AS owner, COALESCE(recommend,'-') AS recommend, ask FROM tasks WHERE ${where} ${order};"
    fi
  fi
}

cmd_task_answer() {
  tasks_db_init
  local value="" value_set=0 from="" human=0
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
      --)        shift; positional+=("$@"); break ;;
      -*)        fail "$E_USAGE" "unknown flag: $1" ;;
      *)         positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task answer <id|DIVE-N> --value=\"...\"  (omit --value for a secret gate)"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID"
  # Must have a pending (unanswered) gate to answer.
  local nt
  nt=$(db "SELECT CASE WHEN need_type IS NOT NULL AND need_answered_at IS NULL THEN need_type ELSE '' END FROM tasks WHERE id=${id};")
  [[ -n "$nt" ]] || fail "$E_CONFLICT" "DIVE-$id has no pending human gate (nothing to answer)"

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
  if [[ "$nt" == "approval" || "$nt" == "secret" ]]; then
    local _caller; _caller=$(id -un 2>/dev/null || echo '?')
    if [[ "$_caller" == agent-* ]]; then
      # No audit_log here: the blocked caller is an agent user that can't write
      # the root-owned audit log anyway (it would only leak a perms error to
      # stderr). The fail + non-zero exit is the record.
      fail "$E_AUTH_REQUIRED" "DIVE-$id is a '$nt' gate — only a human can clear it. Answer it from Telegram (tap the button) or the dashboard; an agent can't self-answer an approval/secret gate."
    fi
  fi

  # Who resumes: the agent that hit the gate (assignee), else the creator.
  local owner; owner=$(db "SELECT COALESCE(NULLIF(assignee,''), NULLIF(created_by,''), '') FROM tasks WHERE id=${id};")
  # DIVE-394 provenance: record WHO answered. `human:` prefix when a trusted path
  # passed --human; otherwise the resolved actor label.
  local answered_by; answered_by=$(task_actor "$from")
  (( human )) && answered_by="human:${answered_by}"

  # Record the answer. A `secret` gate NEVER stores its value — writing a raw
  # key into this group-claude-readable db is a plaintext-secret-at-rest leak.
  # We only stamp need_answered_at (the "provided" signal); the agent loads the
  # key out-of-band. decision/approval/manual store the value in need_answer.
  if [[ "$nt" == "secret" ]]; then
    (( value_set )) && fail "$E_USAGE" "DIVE-$id is a secret gate — do not pass --value; the key must not be stored in the shared db. Run: 5dive task answer DIVE-$id  (records it as provided + pings the agent to load it from where you placed it)"
    db "UPDATE tasks SET need_answered_at=datetime('now'), need_answered_by=$(sqlq "$answered_by") WHERE id=${id};"
  else
    (( value_set )) || fail "$E_USAGE" "--value is required (the human's answer)"
    db "UPDATE tasks SET need_answer=$(sqlq "$value"), need_answered_at=datetime('now'), need_answered_by=$(sqlq "$answered_by") WHERE id=${id};"
  fi

  # Clearing the gate ≠ unblocking. `status='blocked'` is overloaded (human
  # gate AND task-task `block` edges), so RECOMPUTE rather than hardcode todo:
  # flip to todo only if no block edges remain — same edge-check `unblock` does
  # — else stay blocked (still waiting on another task). Answered-ness lives in
  # need_answered_at, so the task already left the inbox regardless of status.
  db "UPDATE tasks SET status='todo'
      WHERE id=${id} AND status='blocked'
        AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${id});"
  local newstatus; newstatus=$(db "SELECT status FROM tasks WHERE id=${id};")

  # Best-effort resume ping over the existing agent-send path. We deliberately
  # do NOT embed the answer value: cmd_send mirrors the outbound into the group
  # chat, so a `secret` answer would leak. The agent reads need_answer itself
  # via `task show` (its own pane only). A stopped or non-agent owner just
  # yields pinged:false — it never fails the answer.
  local pinged=0
  if [[ -n "$owner" ]]; then
    local pingmsg
    if [[ "$nt" == "secret" ]]; then
      pingmsg="DIVE-${id} secret gate marked provided — resume the task and load the key from where it was placed (its .env / your own channel), NOT from the task."
    else
      pingmsg="DIVE-${id} gate cleared — your '${nt}' ask was answered. Resume the task; run \`5dive task show DIVE-${id}\` for the value."
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
  ok "DIVE-$id answered ($nt) — now ${newstatus}${note}" \
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
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID"

  # Don't escalate a finished task — there's nothing to get eyes on.
  local status; status=$(db "SELECT status FROM tasks WHERE id=${id};")
  [[ "$status" == "done" || "$status" == "cancelled" ]] && \
    fail "$E_CONFLICT" "DIVE-$id is $status — nothing to escalate."

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
    local pingmsg="🔺 DIVE-${id} escalated by ${actor} — flagged as needing attention (priority ${pri_note}). Get eyes on it; run \`5dive task show DIVE-${id}\`."
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
    local htext="🔺 [DIVE-${id}] escalated by ${actor} — needs attention"$'\n\n'"${title}"$'\n\n'"priority ${pri_note}"
    _task_send_owner "$htext" "" && notified_human=1 || true
  fi

  local note=""
  [[ $pinged -eq 1 ]] && note=" + pinged $owner"
  ok "DIVE-$id escalated — priority ${pri_note}${note}" \
     '{id:($i|tonumber), priority:$np, was:$op, owner:(($o|select(length>0)) // null), pinged:($p=="1"), human_notified:($h=="1")}' \
     --arg i "$id" --arg np "$new_pri" --arg op "$old_pri" --arg o "$owner" --arg p "$pinged" --arg h "$notified_human"
}

cmd_task_rm() {
  tasks_db_init
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task rm <id|DIVE-N>"
  resolve_task_id "$1"; local id="$RESOLVED_TASK_ID"
  db "DELETE FROM tasks WHERE id=${id};"
  ok "DIVE-$id deleted" '{id:($i|tonumber), deleted:true}' --arg i "$id"
}
