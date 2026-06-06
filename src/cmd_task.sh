
# -------- 5dive task — host-shared task queue --------

_task_usage() {
  cat <<USAGE
5dive task — shared task queue (sqlite at ${STATE_DIR}/tasks/tasks.db)

  5dive task init                                    # one-time root bootstrap of the store
  5dive task add <title...> [--body=<text>] [--priority=low|medium|high|urgent]
                            [--assignee=<agent>] [--parent=<id|DIVE-N>] [--from=<who>]
  5dive task ls [--status=<s>] [--assignee=<agent>] [--mine] [--all]
                                                     # default: open tasks, priority-ordered
  5dive task show <id|DIVE-N>                        # full detail + subtasks + blockers
  5dive task assign <id|DIVE-N> <agent>
  5dive task start  <id|DIVE-N>                      # -> in_progress
  5dive task done   <id|DIVE-N> [--result=<text>]    # -> done; --result captures the agent's response
  5dive task cancel <id|DIVE-N> [--result=<text>]    # -> cancelled; --result captures why
  5dive task block   <id|DIVE-N> --by=<id|DIVE-N>    # add a blocks edge, mark blocked
  5dive task unblock <id|DIVE-N> [--by=<id|DIVE-N>]  # drop edge(s); back to todo if clear
  5dive task rm <id|DIVE-N>                          # delete (cascades subtasks + edges)

  # Human Task Inbox — park a task on a human and clear it
  5dive task need <id|DIVE-N> --type=decision|secret|approval|manual --ask="..." [--options=A|B]
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

cmd_task_add() {
  tasks_db_init
  local body="" priority="medium" assignee="" parent="" from=""
  local -a words=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --body=*)     body="${1#*=}" ;;
      --priority=*) priority="${1#*=}" ;;
      --assignee=*) assignee="${1#*=}" ;;
      --parent=*)   parent="${1#*=}" ;;
      --from=*)     from="${1#*=}" ;;
      --)           shift; words+=("$@"); break ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            words+=("$1") ;;
    esac
    shift
  done
  local title="${words[*]:-}"
  [[ -n "$title" ]] || fail "$E_USAGE" "usage: 5dive task add <title...> [--body=] [--priority=] [--assignee=] [--parent=]"
  valid_task_priority "$priority" || fail "$E_VALIDATION" "bad priority '$priority' (low|medium|high|urgent)"
  local parent_sql="NULL"
  if [[ -n "$parent" ]]; then
    resolve_task_id "$parent"; parent_sql="$RESOLVED_TASK_ID"
  fi
  local creator; creator=$(task_actor "$from")
  local id
  id=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, parent_id)
           VALUES ($(sqlq "$title"), $(sqlq_or_null "$body"), $(sqlq "$priority"),
                   $(sqlq_or_null "$assignee"), $(sqlq "$creator"), ${parent_sql});
           SELECT last_insert_rowid();")
  ok "created DIVE-$id — $title" \
     '{id:($i|tonumber), ident:("DIVE-"+$i), title:$t, priority:$p, assignee:$a, created_by:$c}' \
     --arg i "$id" --arg t "$title" --arg p "$priority" --arg a "${assignee:-}" --arg c "$creator"
}

cmd_task_ls() {
  tasks_db_init
  local status="" assignee="" mine=0 all=0 from=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status=*)   status="${1#*=}" ;;
      --assignee=*) assignee="${1#*=}" ;;
      --mine)       mine=1 ;;
      --all)        all=1 ;;
      --from=*)     from="${1#*=}" ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ $mine -eq 1 ]] && assignee=$(task_actor "$from")
  local where="1=1"
  if [[ -n "$status" ]]; then
    valid_task_status "$status" || fail "$E_VALIDATION" "bad status '$status' (todo|in_progress|blocked|done|cancelled)"
    where+=" AND status=$(sqlq "$status")"
  elif [[ $all -ne 1 ]]; then
    where+=" AND status NOT IN ('done','cancelled')"
  fi
  [[ -n "$assignee" ]] && where+=" AND assignee=$(sqlq "$assignee")"
  local order="ORDER BY CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END, created_at"
  if (( JSON_MODE )); then
    local rows
    rows=$(dbfmt -json "SELECT id, ident, title, status, priority, assignee, created_by, parent_id, created_at, done_at, body, result, need_type, ask, need_options, need_answer, need_answered_at FROM tasks WHERE ${where} ${order};")
    [[ -n "$rows" ]] || rows="[]"
    jq -cn --argjson r "$rows" '{ok:true, data:{tasks:$r}}'
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
                      CASE WHEN need_options IS NOT NULL THEN '  options: '||need_options ELSE '' END||x'0a'||
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
  db "UPDATE tasks SET assignee=$(sqlq "$who") WHERE id=${id};"
  ok "DIVE-$id assigned to $who" '{id:($i|tonumber), assignee:$a}' --arg i "$id" --arg a "$who"
}

_task_status_cmd() {
  local newstatus="$1" extra="$2" verb="$3"; shift 3
  tasks_db_init
  local result="" want_result=0
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --result=*) result="${1#*=}"; want_result=1 ;;
      --)         shift; positional+=("$@"); break ;;
      -*)         fail "$E_USAGE" "unknown flag: $1" ;;
      *)          positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task $verb <id|DIVE-N> [--result=<text>]"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID"
  local set_result=""
  if (( want_result )); then
    set_result=", result=$(sqlq_or_null "$result")"
  fi
  db "UPDATE tasks SET status=$(sqlq "$newstatus")${extra}${set_result} WHERE id=${id};"
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
  db "UPDATE tasks SET status='todo'
      WHERE id=${tid} AND status='blocked'
        AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${tid});"
  ok "DIVE-$tid unblocked" '{task:($t|tonumber)}' --arg t "$tid"
}

# --- Human Task Inbox (DIVE-103; parent feature DIVE-102) ----------------
# `need` parks a task on a human; `inbox` lists what's waiting; `answer`
# records the human's reply, unblocks, and pings the agent that hit the gate.

cmd_task_need() {
  tasks_db_init
  local type="" ask="" options="" from=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type=*)    type="${1#*=}" ;;
      --ask=*)     ask="${1#*=}" ;;
      --options=*) options="${1#*=}" ;;
      --from=*)    from="${1#*=}" ;;
      --)          shift; positional+=("$@"); break ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task need <id|DIVE-N> --type=decision|secret|approval|manual --ask=\"...\" [--options=A|B]"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID"
  valid_need_type "$type" || fail "$E_VALIDATION" "bad --type '$type' (decision|secret|approval|manual)"
  [[ -n "$ask" ]] || fail "$E_USAGE" "--ask is required (what does the human need to provide?)"
  # Options are the choice list for a decision; reject them on the other types
  # so the gate shape stays honest for the dashboard.
  if [[ -n "$options" && "$type" != "decision" ]]; then
    fail "$E_VALIDATION" "--options only applies to --type=decision"
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
            need_answer=NULL, need_answered_at=NULL
      WHERE id=${id};"
  ok "DIVE-$id needs a human ($type) — $ask" \
     '{id:($i|tonumber), ident:("DIVE-"+$i), status:"blocked", need_type:$ty, ask:$ak, need_options:(($op|select(length>0)) // null), assignee:$ac}' \
     --arg i "$id" --arg ty "$type" --arg ak "$ask" --arg op "$options" --arg ac "$actor"
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
  # human-gated and blocked-by another task): need set, not yet answered.
  local where="need_type IS NOT NULL AND need_answered_at IS NULL"
  local order="ORDER BY CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END, created_at"
  if (( JSON_MODE )); then
    local rows
    rows=$(dbfmt -json "SELECT id, ident, title, status, priority, assignee, created_by, parent_id, created_at, need_type, ask, need_options, need_answer, need_answered_at FROM tasks WHERE ${where} ${order};")
    [[ -n "$rows" ]] || rows="[]"
    jq -cn --argjson r "$rows" '{ok:true, data:{inbox:$r}}'
  else
    local cnt; cnt=$(db "SELECT COUNT(*) FROM tasks WHERE ${where};")
    if [[ "$cnt" == "0" ]]; then
      echo "inbox empty — nothing waiting on a human."
    else
      dbfmt -box "SELECT ident, priority, need_type, COALESCE(assignee,'-') AS owner, ask FROM tasks WHERE ${where} ${order};"
    fi
  fi
}

cmd_task_answer() {
  tasks_db_init
  local value="" value_set=0 from=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --value=*) value="${1#*=}"; value_set=1 ;;
      --from=*)  from="${1#*=}" ;;
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
  # Who resumes: the agent that hit the gate (assignee), else the creator.
  local owner; owner=$(db "SELECT COALESCE(NULLIF(assignee,''), NULLIF(created_by,''), '') FROM tasks WHERE id=${id};")

  # Record the answer. A `secret` gate NEVER stores its value — writing a raw
  # key into this group-claude-readable db is a plaintext-secret-at-rest leak.
  # We only stamp need_answered_at (the "provided" signal); the agent loads the
  # key out-of-band. decision/approval/manual store the value in need_answer.
  if [[ "$nt" == "secret" ]]; then
    (( value_set )) && fail "$E_USAGE" "DIVE-$id is a secret gate — do not pass --value; the key must not be stored in the shared db. Run: 5dive task answer DIVE-$id  (records it as provided + pings the agent to load it from where you placed it)"
    db "UPDATE tasks SET need_answered_at=datetime('now') WHERE id=${id};"
  else
    (( value_set )) || fail "$E_USAGE" "--value is required (the human's answer)"
    db "UPDATE tasks SET need_answer=$(sqlq "$value"), need_answered_at=datetime('now') WHERE id=${id};"
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

cmd_task_rm() {
  tasks_db_init
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task rm <id|DIVE-N>"
  resolve_task_id "$1"; local id="$RESOLVED_TASK_ID"
  db "DELETE FROM tasks WHERE id=${id};"
  ok "DIVE-$id deleted" '{id:($i|tonumber), deleted:true}' --arg i "$id"
}
