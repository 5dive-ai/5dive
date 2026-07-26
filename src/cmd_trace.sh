# cmd_trace — causal timeline for one task: goal → ship (INST-1).
#
# A READ-ONLY view over data that ALREADY exists. No new plumbing, no new
# tables, no external SaaS. It reconstructs the causal story of a single unit
# of work from the transition columns every task row already carries
# (created_at/started_at/handoff_delivered_at/handoff_ack_at/need_answered_at/
# shipped_flag_at/done_at) plus the surrounding append-only context — the
# project goal it descends from, its parent chain, the objective/loop that
# originated it, the human gate that cleared it, and the tamper-evident audit
# log lines that reference its ident.
#
# This IS the zero-human proof story compiled into one command: who was
# authorized to act, why, what they changed, who independently verified it,
# and whether a human ever had to step in. The verdict line reads that off the
# gate provenance — 0 human touchpoints => "zero-human", otherwise it names the
# human gate(s) that were required.
#
# Read-only: touches only the shared task DB (+ a best-effort read of the audit
# log). No registry mutation, no lock, no audit line of its own — same posture
# as `usage`/`digest`/`memory`.
#
# Usage:
#   5dive trace <id|DIVE-N> [--json] [--no-audit]

cmd_trace() {
  tasks_db_init
  local want_audit=1
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-audit) want_audit=0 ;;
      --json)     JSON_MODE=1 ;;   # tolerate a trailing --json (global preparse already handles it)
      --)         shift; positional+=("$@"); break ;;
      -*)         fail "$E_USAGE" "unknown flag: $1" ;;
      *)          positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive trace <id|DIVE-N> [--json] [--no-audit]"
  resolve_task_id "${positional[0]}"
  local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"

  # ---- timeline events, as a JSON array {ts,phase,actor,detail} ----------
  # One UNION ALL branch per transition column; NULL timestamps drop out, so an
  # in-progress task shows exactly the phases it has reached and no more. jq
  # sorts by ts (SQLite datetimes are lexically sortable) — we do NOT rely on
  # aggregate ordering.
  local events
  events=$(dbfmt -json "
    SELECT ts, phase, actor, detail FROM (
      SELECT created_at AS ts, 'created' AS phase, COALESCE(created_by,'-') AS actor,
             title AS detail
        FROM tasks WHERE id=${id} AND created_at IS NOT NULL
      UNION ALL
      SELECT started_at, 'started', COALESCE(assignee,'-'), 'work begins'
        FROM tasks WHERE id=${id} AND started_at IS NOT NULL
      UNION ALL
      SELECT handoff_delivered_at, 'handoff', COALESCE(maker_agent, assignee, '-'),
             'delivered to verifier '||COALESCE(verifier,'?')
        FROM tasks WHERE id=${id} AND handoff_delivered_at IS NOT NULL
      UNION ALL
      SELECT handoff_ack_at, 'review', COALESCE(verifier,'-'), 'verifier began review'
        FROM tasks WHERE id=${id} AND handoff_ack_at IS NOT NULL
      UNION ALL
      SELECT need_answered_at, 'gate', COALESCE(need_answered_by,'-'),
             COALESCE(need_type,'gate')||' cleared: '||
               CASE WHEN need_type='secret' THEN '(secret provided out-of-band)'
                    ELSE COALESCE(need_answer,'(answered)') END
        FROM tasks WHERE id=${id} AND need_answered_at IS NOT NULL
      UNION ALL
      SELECT shipped_flag_at, 'ship-detected', '-',
             'commit referencing '||ident||' seen on origin/main'
        FROM tasks WHERE id=${id} AND shipped_flag_at IS NOT NULL
      UNION ALL
      SELECT done_at,
             CASE WHEN status='cancelled' THEN 'cancelled' ELSE 'done' END,
             COALESCE(assignee,'-'),
             COALESCE(result,'(no result recorded)')
        FROM tasks WHERE id=${id} AND done_at IS NOT NULL
    );")
  [[ -n "$events" ]] || events='[]'
  events=$(printf '%s' "$events" | jq -c 'sort_by(.ts)')

  # ---- headline facts + verdict inputs -----------------------------------
  local status assignee title human_gates pending_gate
  status=$(db "SELECT status FROM tasks WHERE id=${id};")
  assignee=$(db "SELECT COALESCE(assignee,'-') FROM tasks WHERE id=${id};")
  title=$(db "SELECT title FROM tasks WHERE id=${id};")
  # human touchpoints = answered gates whose clearer is a verified human
  # (need_answered_by is prefixed 'human:' on the verified-human path, DIVE-394).
  human_gates=$(db "SELECT COUNT(*) FROM tasks
                    WHERE id=${id} AND need_answered_at IS NOT NULL
                      AND need_answered_by LIKE 'human:%';")
  pending_gate=$(db "SELECT COALESCE(need_type,'') FROM tasks
                     WHERE id=${id} AND need_type IS NOT NULL AND need_answered_at IS NULL;")
  human_gates=${human_gates:-0}

  local verdict
  case "$status" in
    done)
      if [[ "$human_gates" -eq 0 ]]; then
        verdict="zero-human — goal to done with 0 human touchpoints"
      else
        verdict="human-in-the-loop — ${human_gates} human gate(s) required"
      fi ;;
    cancelled) verdict="cancelled" ;;
    *)
      if [[ -n "$pending_gate" ]]; then
        verdict="in progress — blocked on a pending ${pending_gate} gate"
      else
        verdict="in progress — ${human_gates} human touchpoint(s) so far"
      fi ;;
  esac

  # ---- origin (why this work exists) -------------------------------------
  # project + its standing goal, the parent chain (root -> immediate parent),
  # the objective that originated it, and the loop it ran inside (if any).
  local proj proj_goal objective loop
  proj=$(db "SELECT p.key||CASE WHEN p.name IS NOT NULL THEN '  ('||p.name||')' ELSE '' END
             FROM tasks t JOIN projects p ON p.key=t.project_key WHERE t.id=${id};")
  proj_goal=$(db "SELECT p.goal FROM tasks t JOIN projects p ON p.key=t.project_key
                  WHERE t.id=${id} AND p.goal IS NOT NULL AND p.goal!='';")
  local ancestors
  ancestors=$(db "WITH RECURSIVE anc(id,ident,title,parent_id,depth) AS (
                    SELECT id,ident,title,parent_id,0 FROM tasks WHERE id=${id}
                    UNION ALL
                    SELECT t.id,t.ident,t.title,t.parent_id,anc.depth+1
                      FROM tasks t JOIN anc ON t.id=anc.parent_id)
                  SELECT ident||'  '||title FROM anc WHERE id!=${id} ORDER BY depth DESC;")
  objective=$(db "SELECT o.name||CASE WHEN t.originated_cycle IS NOT NULL
                                      THEN '  (cycle '||t.originated_cycle||')' ELSE '' END
                  FROM tasks t JOIN objectives o ON o.id=t.originated_by_objective
                  WHERE t.id=${id};" 2>/dev/null)
  # loop linkage is best-effort — child_task_ids is a JSON array of ids; a store
  # without the column (or a non-JSON value) must not error the whole trace.
  loop=$(db "SELECT loop_id||'  ['||topology||']' FROM loop_runs
             WHERE EXISTS (SELECT 1 FROM json_each(loop_runs.child_task_ids)
                           WHERE json_each.value=${id});" 2>/dev/null || true)

  # ---- audit-log references (best-effort, read-only) ---------------------
  # The tamper-evident agent-audit log (640 root:claude) records mutating verbs
  # with their real caller. Lines mentioning this ident are extra provenance —
  # skipped silently if the log is unreadable or --no-audit was passed.
  local audit_json='[]'
  if [[ "$want_audit" -eq 1 && -r "$AUDIT_LOG" ]]; then
    # grep exits 1 on no-match; { …; || true; } stops that poisoning pipefail
    # and double-firing the fallback (which would concat two '[]' → invalid JSON).
    audit_json=$({ grep -F -- "$ident" "$AUDIT_LOG" 2>/dev/null || true; } | tail -20 \
      | jq -c -s 'map({ts,user,cmd,result})' 2>/dev/null)
    [[ -n "$audit_json" ]] || audit_json='[]'
  fi

  # ---- render ------------------------------------------------------------
  if (( JSON_MODE )); then
    jq -cn \
      --arg ident "$ident" --arg title "$title" --arg status "$status" \
      --arg assignee "$assignee" --arg verdict "$verdict" \
      --argjson human_gates "$human_gates" --arg pending "$pending_gate" \
      --arg proj "$proj" --arg proj_goal "$proj_goal" --arg objective "$objective" \
      --arg loop "$loop" \
      --argjson events "$events" --argjson audit "$audit_json" \
      --arg ancestors "$ancestors" \
      '{ok:true, data:{
         ident:$ident, title:$title, status:$status, assignee:$assignee,
         verdict:$verdict, human_touchpoints:$human_gates,
         pending_gate:(if $pending=="" then null else $pending end),
         origin:{
           project:(if $proj=="" then null else $proj end),
           project_goal:(if $proj_goal=="" then null else $proj_goal end),
           ancestors:(if $ancestors=="" then [] else ($ancestors|split("\n")) end),
           objective:(if $objective=="" then null else $objective end),
           loop:(if $loop=="" then null else $loop end)
         },
         timeline:$events,
         audit_refs:$audit
       }}'
    return 0
  fi

  echo "trace — ${ident}: ${title}"
  printf 'status: %s    assignee: %s\n' "$status" "$assignee"
  echo
  echo "origin (why this work exists):"
  {
    if [[ -n "$proj" ]];      then printf 'project:   %s\n' "$proj"; fi
    if [[ -n "$proj_goal" ]]; then printf 'goal:      %s\n' "$proj_goal"; fi
    if [[ -n "$ancestors" ]]; then echo "parent chain:"; printf '%s\n' "$ancestors" | indent2; fi
    if [[ -n "$objective" ]]; then printf 'objective: %s\n' "$objective"; fi
    if [[ -n "$loop" ]];      then printf 'loop:      %s\n' "$loop"; fi
    if [[ -z "$proj$proj_goal$ancestors$objective$loop" ]]; then
      echo "(top-level task — no parent goal/objective/loop)"
    fi
  } | indent2
  echo
  echo "timeline (goal → ship):"
  printf '%s' "$events" | jq -r '.[] |
    "  \(.ts)  \(.phase | (. + "            ")[0:13])  \(.actor | (. + "            ")[0:12])  \(.detail)"'
  if [[ -n "$pending_gate" ]]; then
    printf '  %-18s  %-13s  %-12s  %s\n' "(pending)" "gate" "-" "awaiting a human ${pending_gate}"
  fi
  echo
  if [[ "$(printf '%s' "$audit_json" | jq 'length')" -gt 0 ]]; then
    echo "audit-log references:"
    printf '%s' "$audit_json" | jq -r '.[] | "  \(.ts)  \(.user)  \(.cmd)  [\(.result)]"' | indent2
    echo
  fi
  echo "verdict: ${verdict}"
}
