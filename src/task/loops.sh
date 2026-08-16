# -------- 5dive task — loops --------
#
# Split out of src/cmd_task.sh (DIVE-3278): maker->verifier LOOPS: the loop board, loop advance / cascade-unblock, verify,
# and the block / unblock / park / unpark verbs.
#
# Concatenated into the single-file bundle by build.sh, and sourced by
# src/cmd_task.sh when the split tree is used (tests source src/cmd_task.sh).
# Function definitions only — never execute this file directly.
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
  # OSS-37: the definition moved to _task_stuck_loop_pred (lib/tasks_db.sh) when the
  # objective planner became its second caller. Held here as a local it could only be
  # reused by re-typing, and two copies that agree today is the thing DIVE-1963 named.
  local stuck_pred; stuck_pred="$(_task_stuck_loop_pred)"
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
               CASE WHEN maker_agent IS NOT NULL AND assignee=verifier AND status NOT IN ('done','cancelled')
                    THEN CASE WHEN handoff_ack_at IS NOT NULL THEN 'reviewing' ELSE 'delivered' END
                    ELSE NULL END AS handoff_state,
               handoff_ack_at,
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
                 CASE WHEN maker_agent IS NOT NULL AND assignee=verifier AND status NOT IN ('done','cancelled')
                      THEN CASE WHEN handoff_ack_at IS NOT NULL THEN 'reviewing' ELSE 'delivered' END
                      ELSE '-' END AS handoff,
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

# DIVE-1355 — the task-engine self-dispatch fix. When a task CLOSES (done or
# cancelled), free any dependent this close finished off: drop the now-satisfied
# blocking edge, and if the dependent has NO blocking edges left, flip it
# blocked->todo and ping its assignee so it dispatches now instead of rotting.
# This is the same unblock-flip `task unblock`, the relay advance, and the
# park-wake sweep all use (a task with no task_deps edge is, by convention,
# unblocked). It is what makes a finished blocker actually release its dependents
# — the OSS-26 -> OSS-27 rot that idled the whole builder queue overnight
# (dependents stayed status=blocked forever because NOTHING cleared their edge).
#
# GUARDRAIL (lodar/main): ONLY dependency edges auto-clear. A dependent is left
# blocked (not flipped) when it has another live hold — an unanswered human
# need-gate (need_type set, need_answered_at NULL) or a park (parked_at set: a
# deliberate hold / future wake the park-wake sweep owns). The satisfied edge is
# still dropped (the blocker really is done), so once the gate is answered / the
# park wakes, the existing NOT-EXISTS-edge flip releases it correctly.
#
# Best-effort + isolated by the caller (|| true): a cascade hiccup must never
# fail the close that already committed. Runs on done AND cancel — a cancelled
# blocker is as "cleared" as a done one for its dependents.
_task_cascade_unblock() {
  local closed_id="$1" dep
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    # This blocker is now done/cancelled — drop its (satisfied) edge.
    db "DELETE FROM task_deps WHERE task_id=${dep} AND blocked_by=${closed_id};"
    # Still blocked by another unfinished edge? leave it.
    [[ "$(db "SELECT COUNT(*) FROM task_deps WHERE task_id=${dep};")" == "0" ]] || continue
    # Flip blocked->todo ONLY when no non-dependency hold remains (guardrail).
    db "UPDATE tasks SET status='todo'
        WHERE id=${dep} AND status='blocked'
          AND parked_at IS NULL
          AND (need_type IS NULL OR need_answered_at IS NOT NULL);"
    [[ "$(db "SELECT status FROM tasks WHERE id=${dep};")" == "todo" ]] || continue
    # Ping the freed dependent's assignee (best-effort; subshell contains cmd_send's
    # fail-closed exit + scoped-send exec exactly like _task_loop_advance).
    local who dident dtitle
    who=$(db    "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${dep};")
    dident=$(db "SELECT ident FROM tasks WHERE id=${dep};")
    dtitle=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${dep};")
    [[ -n "$who" ]] && ( cmd_send "$who" --from="task-engine" \
        --message="▶️ Unblocked: ${dident} — all its blockers are done. It's on your queue now: ${dtitle}" ) >/dev/null 2>&1 || true
  done < <(db "SELECT task_id FROM task_deps WHERE blocked_by=${closed_id};")
  return 0
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
        # DIVE-1415: a closed loop RUN can itself be a blocker of other tasks —
        # release its dependents on this terminal close too.
        _task_cascade_unblock "$run" || true
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
  local task="" cmd="" no_done=0 timeout_s="" prose="" have_prose=0 prose_src=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cmd=*)      cmd="${1#*=}" ;;
      --no-done|--check) no_done=1 ;;
      # DIVE-2832: the verifier's own words. Every other writer of this column is
      # either the MAKER's verb (deliver) or machine output, so a verifier who
      # graded by READING had no way to put a prose PASS on an OPEN row at all.
      --result=*)   _prose_flag_dupe --result "$prose_src"
                    prose="${1#*=}"; have_prose=1; prose_src="--result" ;;
      # DIVE-3018: same file sibling as `task done` / `task deliver`. A verifier's
      # verdict is the LONGEST prose any of these verbs takes, so this is the one
      # most exposed to the quoting trap the argv form carries.
      --result-file=*) _prose_flag_dupe --result-file "$prose_src"
                    _read_prose_file --result-file "${1#*=}"
                    prose="$_PROSE_FILE_VALUE"; have_prose=1; prose_src="--result-file" ;;
      --timeout=*)  timeout_s="${1#*=}" ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] \
    || fail "$E_USAGE" "usage: 5dive task verify <id|DIVE-N> [--cmd=\"<command>\"] [--result=\"<prose verdict>\"|--result-file=<path>] [--no-done] [--timeout=<seconds>]"
  [[ -z "$timeout_s" || "$timeout_s" =~ ^[1-9][0-9]*$ ]] \
    || fail "$E_VALIDATION" "--timeout must be a positive integer (seconds)"
  resolve_task_id "$task"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  # DIVE-2832: --result is a RECORDING path, never a closing one. A prose verdict is
  # an assertion about work; it is not evidence that anything reached main, and the
  # DIVE-1830 merge gate this verb already bypasses (DIVE-2938) is exactly what would
  # otherwise be riding on it. So --result requires --no-done and says so.
  if (( have_prose )) && (( ! no_done )); then
    fail "$E_USAGE" "--result records a verifier's prose verdict WITHOUT closing, so it requires --no-done (alias --check). A prose PASS asserts the work is good; it is not evidence the work MERGED, and \`task verify\`'s close does not run the DIVE-1830 merge gate (DIVE-2938). To record the grade: 5dive task verify $task --no-done --result=\"<verdict>\". To close on evidence, pass a --cmd whose EXIT STATUS proves what you are claiming."
  fi
  if (( have_prose )) && [[ -z "${prose//[[:space:]]/}" ]]; then
    fail "$E_VALIDATION" "--result was given an EMPTY value. A zero-length verdict is indistinguishable from one that was never written (DIVE-2483), so it is refused rather than stored."
  fi
  # DIVE-476: --cmd is now optional — when omitted, fall back to the task's stored
  # verify_command (the declarative loop spec). Persisted input, no re-passing.
  #
  # DIVE-2832: and with --result there may be NO command at all, which is the whole
  # point. The row's receipts were graded by READING a diff, and this fail() was the
  # reason the "record without flipping" flag could not reach them: it demanded a
  # runnable acceptance test, so the only way in was to contrive one — manufacturing
  # a green to satisfy a gate, which is the anti-pattern the row exists to name.
  local ran_cmd=1
  if [[ -z "$cmd" ]]; then
    cmd=$(db "SELECT COALESCE(verify_command,'') FROM tasks WHERE id=${id};")
    if [[ -z "$cmd" ]]; then
      (( have_prose )) \
        || fail "$E_USAGE" "no --cmd given and task has no stored verify_command (set one: 5dive task add … --verify=\"<cmd>\"). If you graded by READING rather than by running something, record it as prose instead: 5dive task verify $task --no-done --result=\"<your verdict>\" (DIVE-2832)."
      ran_cmd=0
    fi
  fi

  # Run it. Combined stdout+stderr. The `if` wrapper captures the exit code
  # WITHOUT tripping `set -e` (a failing $() in a bare assignment would abort).
  local out rc
  if (( ! ran_cmd )); then
    out=""; rc=0
  elif [[ -n "$timeout_s" ]]; then
    if out=$(timeout "${timeout_s}" bash -c "$cmd" 2>&1); then rc=0; else rc=$?; fi
    (( rc == 124 )) && out="${out}"$'\n'"[timed out after ${timeout_s}s]"
  else
    if out=$(bash -c "$cmd" 2>&1); then rc=0; else rc=$?; fi
  fi
  # Tail the output so a chatty command can't bloat the result row.
  local tail_out; tail_out=$(printf '%s\n' "$out" | tail -n 25)

  local verdict result_txt
  # DIVE-2832: with a prose verdict and no command, the record must not LOOK like a
  # machine verdict. The whole value of the existing text is that "exit 0" is a fact
  # a reader can re-derive; a grader's assertion is not, and rendering them the same
  # way would buy the recording path at the cost of the one property that made the
  # machine path trustworthy. So the prose is labelled as UNEXECUTED and attributed.
  if (( have_prose )) && (( ! ran_cmd )); then
    verdict="pass"
    result_txt="✅ verify PASS (verifier's prose grade — NO command was run, DIVE-2832): recorded by $(task_actor "")"$'\n'"${prose}"
  elif (( rc == 0 )); then
    verdict="pass"
    result_txt="✅ verify PASS (exit 0): ${cmd}"$'\n'"--- output tail ---"$'\n'"${tail_out}"
    # Both given: the command's evidence AND the grader's words, prose first, because
    # the prose is the part a human wrote and the tail is the part they were reading.
    (( have_prose )) && result_txt="${prose}"$'\n'"--- evidence ---"$'\n'"${result_txt}"
  else
    verdict="fail"
    result_txt="❌ verify FAIL (exit ${rc}): ${cmd}"$'\n'"--- output tail ---"$'\n'"${tail_out}"
  fi

  # DIVE-2483: `task verify` is the THIRD writer of this column and the only one
  # that reached the OPEN cell completely unguarded. DIVE-2067 added preservation
  # here, but inside `if [[ "$_v_st" == 'done' ]]` — so every not-done write below
  # (the pending-gate refusal, the auth-failure exit, the done-flip, and the FAIL
  # branch) put result_txt straight over whatever was there.
  #
  # A DELIVERED row is not done, which is what makes this live rather than
  # theoretical: it is the cell a maker→verifier loop is in for its whole life.
  # Measured on DIVE-2624 — dev's maker-delivery record was replaced by
  # "✅ verify PASS (exit 0): bash /tmp/.../prove_2624.sh" and was gone from the
  # board. That path is not an accident either: the DIVE-2318 merge-gate refuses a
  # `task done` with no gh credential and suggests handing the close to an agent
  # that holds one, DIVE-477 forbids that, and the refusal at :2707 then NAMES
  # `task verify --cmd=` among its exits — so a no-gh verifier is ROUTED here by
  # construction. The verb that a whole class of agents is funnelled into is the
  # last one that should be the unguarded one.
  #
  # Deliberately scoped to the NOT-done cell: the closed cell already has
  # DIVE-2067's own refusal and its "superseded result (DIVE-2067, preserved)"
  # append below, and running both would append twice. This is keyed on status at
  # the CALL SITE — which is fine and is not the defect this ticket is about — to
  # avoid two preservation mechanisms overlapping on one write.
  # DIVE-2835: run the deployed-vs-claimed comparison on THIS close's own text,
  # deliberately before the guard below prepends the prior result. After that
  # prepend the cell also carries the MAKER's words, and warning "this verify
  # states it verified on vX" about a sentence the verifier did not write would be
  # a true finding attributed to the wrong author — the same misattribution
  # DIVE-2725 spent two iterations removing from a probe verdict.
  _gate_version_vs_installed "$ident" verify "$result_txt"
  local _v_guard_st
  _v_guard_st=$(db "SELECT COALESCE(status,'') FROM tasks WHERE id=${id};")
  if [[ "$_v_guard_st" != "done" && "$_v_guard_st" != "cancelled" ]]; then
    _task_guard_result_over_closed "$id" "$ident" verify "$result_txt" 0 0 verify-result-over-open
    result_txt="$_TASK_GUARDED_RESULT"
  fi

  local flipped=0 self_verified_close=0
  local self_verify_maker="" self_verify_verifier="" self_verify_iteration=""
  if (( rc == 0 )) && (( ! no_done )); then
    # DIVE-2196: this auto-close is a TERMINAL CLOSE reached by raw UPDATE, so it
    # never saw DIVE-555's pending-gate refusal — `task verify --cmd=true` closed a
    # task out from under an unanswered human gate, and the question then vanished
    # from every open-gate view (they all require an open status). That is the same
    # bypass DIVE-2067 recorded on the ACK axis: the refusal on `task done` NAMES
    # `task verify` as an alternative, and the named alternative carried no
    # equivalent check. Refusing here is what makes the `done`/`reject` rails real
    # rather than advisory. The verify RESULT is still recorded first — the evidence
    # is worth keeping and is not what the gate is protecting; only the close waits.
    local _vg_t _vg_a
    _vg_t=$(db "SELECT COALESCE(need_type,'')        FROM tasks WHERE id=${id};")
    _vg_a=$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${id};")
    if [[ -n "$_vg_t" && -z "$_vg_a" ]]; then
      db "UPDATE tasks SET result=$(sqlq "$result_txt") WHERE id=${id};"
      policy_refuse "$E_CONFLICT" verify-close-over-open-gate DIVE-2196 "$ident" \
        "$ident has a pending '${_vg_t}' gate awaiting a human — the verify verdict is RECORDED, but the auto-close is refused: closing here would drop the human's question out of every open-gate view without anyone answering it, which is DIVE-555's bypass reached by a different verb. Exits: let them answer it ('5dive task answer $ident --value=...'), withdraw it if your result makes it moot ('5dive task need $ident --withdraw'), or re-run with --no-done to record evidence without closing."
    fi
    # DIVE-2015: a maker is deliberately ALLOWED to rescue a stalled delivered
    # loop with `task verify --cmd=...`; refusing it would remove the only
    # zero-human exit when the assigned verifier never runs. Permitted must not
    # mean invisible, though. When the kernel-authenticated caller is the recorded
    # maker and the still-live row is held by its verifier, stamp the durable task
    # result, emit a separately classifiable audit event, and warn on stderr. The
    # mark names every fact a later reader needs to weigh the close: maker,
    # verifier who never recorded a grade, and loop iteration. An unidentified
    # caller cannot safely be classified as maker or verifier, so its passing
    # evidence is retained but it cannot close a live delivered loop.
    #
    # This belongs in audit_log, not policy_refusals: nothing was refused. Route
    # through the task-store fence so fixture DBs cannot write real-looking task
    # telemetry into the fleet audit log (DIVE-2010).
    local _svc_auth_actor _svc_row _svc_assignee _svc_status
    _svc_auth_actor=$(_gate_authenticated_actor)
    _svc_row=$(db "SELECT COALESCE(maker_agent,'')||x'1f'||
                        COALESCE(verifier,'')||x'1f'||
                        COALESCE(assignee,'')||x'1f'||
                        COALESCE(iteration,0)||x'1f'||status
                   FROM tasks WHERE id=${id};")
    IFS=$'\x1f' read -r self_verify_maker self_verify_verifier \
      _svc_assignee self_verify_iteration _svc_status <<<"$_svc_row"
    if [[ -n "$self_verify_maker" && -n "$self_verify_verifier" \
          && "$_svc_assignee" == "$self_verify_verifier" \
          && "$_svc_status" != "done" && "$_svc_status" != "cancelled" ]]; then
      if [[ -z "$_svc_auth_actor" ]]; then
        db "UPDATE tasks SET result=$(sqlq "$result_txt") WHERE id=${id};"
        fail "$E_PERMISSION" "$ident verify passed and was recorded, but auto-close was refused: the caller identity could not be authenticated"
      fi
      if [[ "$_svc_auth_actor" == "$self_verify_maker" ]]; then
        self_verified_close=1
        result_txt="⚠ self-verified-close: maker=${self_verify_maker}; verifier=${self_verify_verifier} never graded; iteration=${self_verify_iteration}"$'\n'"${result_txt}"
      fi
    fi
    # DIVE-2067: `task verify --cmd` had NO guard against closing an ALREADY-CLOSED task,
    # so a second close REPLACED the result field outright. Measured on DIVE-2059: the
    # verifier closed it with the ACK at 10:22:37, the MAKER closed it again 39s later via
    # `verify --cmd`, and the ACK — two operational caveats, the red-team evidence, and a
    # follow-up split — was silently discarded. It survived only because the verifier had
    # also compiled it to the wiki.
    #
    # Note this path is a SANCTIONED escape: the DIVE-2007 refusal message names
    # `task verify --cmd` as a real exit for a maker whose delivery was refused. So the fix
    # must NOT close that door — it blocks only the case where there is nothing to escape
    # FROM, i.e. the task is already done and the closer is not the recorded verifier.
    #
    # RE-LAND NOTE (main, DIVE-2389): this compares `task_actor`, a PROVENANCE string the
    # caller can set, and not the kernel-authenticated identity DIVE-2330 introduced after
    # this fix was written. That is deliberate and it is a real limitation, so read it
    # before extending this guard. The measured incident was an ACCIDENTAL clobber (a maker
    # re-closing 39s later), not a forgery, and the cost of the two failure modes is not
    # symmetric here: a forged actor loses one result field, whereas keying on the
    # authenticated actor breaks every harness that models a verifier by setting USER —
    # exactly what DIVE-2330 did to the gate suite. I tried the authenticated form first
    # ($_svc_auth_actor is already in scope three lines up) and it takes C1 red for that
    # reason. Hardening it needs a caller-uid seam in this harness, which is its own row,
    # not a re-land.
    local _v_st _v_vfier _v_actor _v_prev
    _v_st=$(db "SELECT COALESCE(status,'') FROM tasks WHERE id=${id};")
    _v_vfier=$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${id};")
    _v_actor=$(task_actor "")
    if [[ "$_v_st" == 'done' && -n "$_v_vfier" && "$_v_actor" != "$_v_vfier" ]]; then
      policy_refuse "$E_CONFLICT" verify-over-closed DIVE-2067 "$ident" \
        "$ident is ALREADY done and its recorded verifier is '${_v_vfier}', not '${_v_actor}'. A second close here would REPLACE the verifier's result field and silently discard their ACK (DIVE-2067). There is nothing to escape from: the grade already exists. To ADD evidence, send it to '${_v_vfier}' (5dive agent send ${_v_vfier} \"...\") and let them fold it in; to reopen, '5dive task reject $ident --feedback=...'."
    fi
    # DIVE-2067 rec 3: never silently discard. If a close still lands on an already-done
    # task (the verifier re-closing their own), PRESERVE the prior result by appending.
    if [[ "$_v_st" == 'done' ]]; then
      _v_prev=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${id};")
      [[ -n "$_v_prev" ]] && result_txt="${result_txt}"$'\n'"--- superseded result (DIVE-2067, preserved) ---"$'\n'"${_v_prev}"
    fi
    # DIVE-2938: THIS CLOSE DOES NOT RUN THE MERGE GATE, AND UNTIL NOW IT DID NOT SAY SO.
    #
    # The DIVE-1830 merge gate lives in `_task_status_cmd` (the done/cancel verbs). This
    # flip is a raw UPDATE in a different function, so a row can reach status=done with
    # its delivery unmerged and nothing anywhere records that the question was never
    # asked. Measured: DIVE-2743 closed on `verify --cmd` running a unit test inside a
    # LOCAL WORKTREE and its test file is absent from main today; DIVE-2645 was graded
    # "at worktree tip c2baa6b" with its PR still open.
    #
    # This is NOT the gate. Gating here would re-create the deadlock DIVE-2318 routes
    # OUT of — its no-credential refusal names `task verify --cmd` as the authorised
    # terminal move for a verifier who holds no gh, so refusing here without a working
    # `--no-done` (still unreachable for a read-grader per DIVE-2832) would strand
    # exactly the seat the exit was built for. That build waits on DIVE-2832.
    #
    # What ships instead is LEGIBILITY: when the row carries a binding the merge gate
    # WOULD have checked, say on the record that it was not checked. Two properties
    # earn it. (1) The reader of a done row currently cannot distinguish "merged and
    # graded" from "graded on a branch" — both render as a green result. (2) It is the
    # only way to FIND the class: `task merge-audit` scans for PR *numbers*, so a row
    # binding a bare `Branch:` line — which is what both receipts did — is structurally
    # invisible to it. A fixed token in the result field is greppable where the audit is
    # blind.
    #
    # Deliberately scoped to rows that HAVE a binding. A row with nothing to merge has
    # no question to leave unanswered, and stamping it would be noise that trains people
    # to skip the line — the failure mode of every warning that fires too often.
    local _mg_body _mg_dref _mg_bind=""
    _mg_dref=$(db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE id=${id};")
    _mg_body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
    if [[ -n "$_mg_dref" ]]; then
      _mg_bind="delivery_ref ${_mg_dref}"
    elif _gate_text_names_a_ref "$_mg_body"; then
      _mg_bind="a PR named in the body"
    else
      # DIVE-2577's own discovery rule, reused rather than re-spelt: a branch the row's
      # prose names, anchored on the "<ident>-" prefix. Reusing it is the point — if the
      # gate's idea of a binding changes, this stamp must change with it or it will go
      # quiet on exactly the rows the gate started catching.
      # DIVE-3265: AN EMPTY BRANCH SET IS AN ANSWER, NOT A FAILURE — `|| _mg_branches=""`
      # is load-bearing and its absence killed the verb outright. The extractor is a
      # PROBE that legitimately finds nothing (most rows name no branch). Its pipeline
      # ends in `grep`, which exits 1 on no-match; `pipefail` promotes that out of the
      # function and through `head | paste`, and a bare `var=$(...)` under `set -euo
      # pipefail` (src/header.sh) then kills the whole run. Measured on DIVE-3264 with
      # the CLI's own suggested trace, last lines before exit:
      #     ++ paste -sd, - / + _mg_branches= / + on_exit_audit / + local code=1
      # That is why the two verbs behaved DIFFERENTLY on one row: `task done` found a
      # (bogus) branch, so extraction succeeded and it refused cleanly, while `task
      # verify --cmd` found none and CRASHED before any error path could print.
      # DIVE-2603 fixed exactly this at the sibling call site ~2000 lines up; this site
      # shipped later (DIVE-2938) and re-introduced it. Grepped the class, not the form:
      # these two are the only callers of the extractor and both are guarded now, and
      # tests/verify_close_merge_gate_stamp_unit.sh arm C pins THIS one from both ends.
      local _mg_branches
      _mg_branches=$(_gate_branch_refs_from_text "$_mg_body" "$ident" 2>/dev/null | head -3 | paste -sd, -) || _mg_branches=""
      [[ -n "$_mg_branches" ]] && _mg_bind="branch(es) named in the body: ${_mg_branches}"
    fi
    if [[ -n "$_mg_bind" ]]; then
      result_txt="⚠ merge-gate NOT EVALUATED (DIVE-2938) — closed via \`task verify\`, which does not run the DIVE-1830 gate. This row binds ${_mg_bind}; whether it reached main was NOT checked by this close. Confirm with a positive existence test on the canonical ref (e.g. \`git cat-file -e origin/main:<a file the change created>\`) before relying on it."$'\n'"${result_txt}"
    fi
    # DIVE-2477: the THIRD close writer. DIVE-2067 taught this lesson one column
    # over — when you guard one verb, ask which OTHERS write the field. A
    # verifier re-verifying their own already-done row (the case DIVE-2067's
    # refusal deliberately allows) refreshed done_at here, same as the close
    # verbs did. COALESCE for the same reason and by the same rule: first close wins.
    db "UPDATE tasks SET status='done', done_at=COALESCE(done_at, datetime('now')), result=$(sqlq "$result_txt") WHERE id=${id};"
    flipped=1
    if (( self_verified_close )); then
      _task_store_audit_log "task.verify-self-close" "self-verified-close" 0 -- \
        "task=$ident" "maker=$self_verify_maker" "verifier=$self_verify_verifier" \
        "iteration=$self_verify_iteration"
      warn "$ident self-verified-close: maker '$self_verify_maker' selected the passing verify command; verifier '$self_verify_verifier' never graded iteration $self_verify_iteration. Close allowed and visibly recorded."
    fi
    # DIVE-1415: `task verify` auto-done is a terminal close like `task done`, so
    # it must release this task's dependents too. DIVE-1355 wired the cascade
    # only into `_task_status_cmd` (the done/cancel verbs); a task closed via
    # verify (or the gate paths below) left its dependents stuck 'blocked' with
    # a satisfied edge — the exact stall that froze OSS-32/33 behind OSS-27
    # overnight (OSS-27 closed via `task verify`, cascade never ran).
    _task_cascade_unblock "$id" || true
  else
    # DIVE-3098: --no-done records a VERIFIER GRADE. Stamp it structurally as well
    # as in prose, because the predicate that exempts this row from the goal hook
    # and the rot-nudger must not be forgeable. `task deliver --result=` is the
    # MAKER's verb and writes the same column; if the predicate keyed on result
    # TEXT, a maker could satisfy it by typing the right words and walking away —
    # exactly the fail-open _hb_loop_terminal_clause already warns about one layer
    # up. graded_by is the ACTOR, so terminal_for_verifier can additionally require
    # grader != maker and a self-verified close cannot buy the exemption.
    # COALESCE: first grade wins, same rule as done_at (DIVE-2477).
    #
    # DIVE-3430: and stamp WHAT the verdict was. graded_at alone records only THAT
    # someone graded, so a FAIL recorded here rendered `graded->merge` — the
    # DIVE-3315 instruction, with no reject token for DIVE-3428's conjunct to catch.
    #
    # DERIVED FROM $rc, NEVER FROM WHICH BRANCH THIS IS. This else is entered on
    # `rc != 0` (a FAIL, any flags) AND on `--no-done` with `rc == 0` (a PASS
    # recorded without closing). Calling it "the FAIL branch" and hardcoding 'fail'
    # would record every --no-done PASS as a failure and drop correctly-delivered
    # rows out of graded->merge — the exact INVERSE of the bug being fixed, and the
    # `--cmd=false` probe on the row would not have caught it because it exercises
    # both cases with rc != 0.
    #
    # BARE SET, NOT COALESCE, and this asymmetry with the two lines above is
    # deliberate — see the CREATE TABLE comment. graded_at/graded_by are provenance
    # (who first graded, when) and must not be rewritten by a re-grade; the verdict
    # is a CURRENT STATE and must be, or a verifier could never clear their own
    # earlier FAIL and a legitimately re-graded row would be permanently unmergeable.
    # graded_verdict_at carries the current verdict's own clock so the skew from a
    # frozen graded_at is readable rather than silent.
    db "UPDATE tasks SET result=$(sqlq "$result_txt"),
           graded_at=COALESCE(graded_at, datetime('now')),
           graded_by=COALESCE(graded_by, $(sqlq "$(task_actor "")")),
           graded_verdict=$( (( rc == 0 )) && printf "'pass'" || printf "'fail'" ),
           graded_verdict_at=datetime('now')
        WHERE id=${id};"
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

# DIVE-1357: a 'blocked' task is only legitimate if it carries a REVISIT anchor —
# a dependency edge (revisits via the DIVE-1355 cascade), a human need-gate
# (revisits on answer), or a park with a wake_at (revisits when the heartbeat
# passes it). This predicate is the single source of truth the block-producing
# verbs (block/need/park) all satisfy; it is what keeps the DIVE-1355 'blocked
# with no live reason' surface set permanently empty. 0 if $1 has >=1 anchor.
_task_has_block_anchor() {
  local id="$1"
  [[ "$(db "SELECT CASE WHEN
       EXISTS (SELECT 1 FROM task_deps WHERE task_id=${id})
         OR need_type IS NOT NULL
         OR (parked_at IS NOT NULL AND wake_at IS NOT NULL)
     THEN 1 ELSE 0 END FROM tasks WHERE id=${id};")" == "1" ]]
}

cmd_task_block() {
  tasks_db_init
  local task="" by="" reason="" wake=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --by=*)     by="${1#*=}" ;;
      --reason=*) reason="${1#*=}" ;;
      --wake=*)   wake="${1#*=}" ;;
      -*)         fail "$E_USAGE" "unknown flag: $1" ;;
      *)          [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task block <id|DIVE-N> --by=<id|DIVE-N>   (or --reason=<why> --wake=<when> to hold it as a timed park)"
  # DIVE-1357: with --by this is a dependency edge (the normal, self-revisiting
  # block). WITHOUT --by, the only honest hold is a timed park — so route a
  # reason+wake block through `task park`, and REFUSE a bare reasonless/dateless
  # block outright: that unreachable state is what filled the block graveyard.
  # Norm: attempt first — blocking is the exception you must justify with an anchor.
  if [[ -z "$by" ]]; then
    if [[ -n "$reason" && -n "$wake" ]]; then
      cmd_task_park "$task" --reason="$reason" --wake="$wake"
      return
    fi
    policy_refuse "$E_USAGE" bare-block-forbidden DIVE-1357 "$task" "a bare 'task block $task' needs a revisit anchor — add --by=<id>, or use 'task park --reason --wake'"
  fi
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
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task park <id|DIVE-N> --reason=<why / what unblocks it> --wake=<YYYY-MM-DD[ HH:MM]|+Nd|+Nh>"
  # DIVE-1357: a park is anchor #3 for a 'blocked' task, and an anchor MUST carry
  # a revisit or it silently becomes the block graveyard DIVE-1355 has to sweep.
  # Require BOTH a --reason (why it's held / what unblocks it) and a --wake (when
  # to revisit). No known date? Pick a re-check date (--wake=+7d). Waiting on a
  # person is a human gate (`task need`), not a park.
  [[ -n "$reason" ]] || fail "$E_USAGE" "park needs --reason=<why / what unblocks it> — a reasonless hold is exactly the block graveyard DIVE-1357 forbids"
  [[ -n "$wake" ]]   || fail "$E_USAGE" "park needs --wake=<when> (e.g. +7d, +12h, YYYY-MM-DD) — unknown date? pick a re-check; waiting on a person? 'task need'"
  resolve_task_id "$task"; local tid="$RESOLVED_TASK_ID" tident="$RESOLVED_TASK_IDENT"
  # DIVE-1453: park and a human gate share `status='blocked'` plus overlapping
  # need_* columns, so the UPDATE below would NULL an OPEN, UNANSWERED gate's
  # fields — silently destroying it (no answer, no audit row; the heartbeat wake
  # then unparks it to todo as if a human had cleared it). REFUSE to park over a
  # live gate: the task is already `blocked` on the human, so answer it first.
  # Predicate matches the gate_live flag used by inbox/show: need_type set, not
  # yet answered, task still open.
  local _live_gate; _live_gate=$(db "SELECT CASE WHEN need_type IS NOT NULL
        AND need_answered_at IS NULL AND status NOT IN ('done','cancelled')
      THEN 1 ELSE 0 END FROM tasks WHERE id=${tid};")
  if [[ "$_live_gate" == "1" ]]; then
    local _gt; _gt=$(db "SELECT COALESCE(need_type,'gate') FROM tasks WHERE id=${tid};")
    policy_refuse "$E_USAGE" park-over-open-gate DIVE-1453 "$tident" "$tident has an open ${_gt} gate awaiting a human — it is already blocked; answer the gate instead of parking"
  fi
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
  # DIVE-2119: park retires a gate too (an ANSWERED one — a live gate is refused
  # above), so it goes through the same archive-then-clear as file/withdraw
  # rather than nulling half the columns itself. One transaction: the archive
  # must not survive without the reset, or the reset without the archive.
  db "BEGIN IMMEDIATE;
      $(_gate_archive_and_clear_sql park "id=${tid} AND status NOT IN ('done','cancelled')")
      UPDATE tasks
        SET status='blocked', parked_at=datetime('now'), park_reason=$(sqlq "$reason"),
            wake_at=${wake_sql},
            need_type=NULL, ask=NULL, need_options=NULL, recommend=NULL,
            -- DIVE-2354: a parked row holds no gate, so it must not keep reporting
            -- which ORDER that gate was in. The archive above copied it to history.
            gate_mode=NULL
      WHERE id=${tid} AND status NOT IN ('done','cancelled');
      COMMIT;"
  # DIVE-2410: park clears the gate columns, so whatever button that gate put in a
  # human's chat now points at a question the task no longer holds.
  _task_gate_retire_buttons "$tident" "parked" || true
  # DIVE-2877: A PARK'S BLAST RADIUS EXCEEDS THE ROW IT IS APPLIED TO, and until
  # now nothing said so at the moment of the park. On an instance materialized
  # from a recurring template (from_template_id set) a park is not a delay of one
  # row — it is a stop of the whole beat, with no catch-up:
  #
  #   - the materializer dedups on `status NOT IN ('done','cancelled')`
  #     (_hb_materialize_recurring, src/cmd_heartbeat.sh) and a park sets
  #     status='blocked', so the parked instance HOLDS the template's only open
  #     slot. Every occurrence inside the park window is DROPPED, not deferred —
  #     the materializer carries an explicit `V1 LIMITATION: no catch-up`.
  #   - the DIVE-2693 stall ladder requires `status='todo' AND parked_at IS NULL`
  #     at BOTH rungs (rung 2 added by DIVE-2853), so the row that stopped the
  #     beat is the one state the watchdog cannot see.
  #
  # THE LADDER IS NOT THE DEFECT and this guard is deliberately not there. Rung 2's
  # remedy is AUTO-CANCEL: widening its population to parked rows would convert an
  # operator's "not now" into a destruction, on exactly the rows most likely to have
  # been frozen for a real reason. Rung 1 is the same argument one notch softer — a
  # parked row is pending BY DESIGN, and pinging it every beat is the false-positive
  # class already fixed once (DIVE-639/711). Both clauses are correct FOR THE ACTION
  # EACH RUNG TAKES, which is why the guard belongs here instead: the fact is
  # knowable at park time from the row itself, so it needs no watchdog at all.
  #
  # WARN, NEVER REFUSE. This command cannot know whether the operator means to stop
  # the beat (DIVE-2694 was parked by a legitimate fleet-wide token freeze), and a
  # refusal would be a confident claim about intent. Naming the template and the two
  # levers that actually mean "pause the job" is the whole job here.
  #
  # Cost of not having had it: DIVE-2694 (daily character drip) parked 2026-08-07,
  # 9 days of dropped occurrences, downstream +3 days, and nothing red anywhere.
  # CLASS: this is the SECOND entry into the DIVE-2237 trap (skip-if-open switches a
  # template off silently) and strictly worse, because park also mutes the watchdog
  # that surfaced the first. Fixing an entry path is not fixing the trap.
  local _tmpl_ident=""
  local _park_landed; _park_landed=$(db "SELECT CASE WHEN parked_at IS NOT NULL THEN 1 ELSE 0 END FROM tasks WHERE id=${tid};" 2>/dev/null || echo 0)
  if [[ "$_park_landed" == "1" ]]; then
    # ident has no spaces, so one row split on the first space keeps this to a
    # single query. Empty when the row is not a materialized instance.
    local _tmpl_row=""
    # DIVE-2272: carry the template's overlap policy. A park's blast radius is
    # policy-dependent — under skip it stops the beat outright, under spawn it
    # consumes one bounded slot — and a warning that names the wrong one is worse
    # than none: it teaches the operator the warning does not mean what it says.
    # ident/schedule/policy/bound are all whitespace-free EXCEPT schedule (a cron
    # expr has spaces), so the tail fields are peeled off the RIGHT and whatever
    # remains in the middle is the schedule.
    _tmpl_row=$(db "SELECT p.ident || ' ' || COALESCE(p.schedule,'?') || ' ' || COALESCE(p.on_overlap,'skip') || ' ' || COALESCE(p.overlap_bound, ${TASKS_OVERLAP_BOUND_DEFAULT:-3})
                    FROM tasks t JOIN tasks p ON p.id = t.from_template_id
                    WHERE t.id=${tid};" 2>/dev/null || echo "")
    if [[ -n "$_tmpl_row" ]]; then
      local _tmpl_rest _tmpl_pol _tmpl_bound
      _tmpl_ident="${_tmpl_row%% *}"; _tmpl_rest="${_tmpl_row#* }"
      _tmpl_bound="${_tmpl_rest##* }"; _tmpl_rest="${_tmpl_rest% *}"
      _tmpl_pol="${_tmpl_rest##* }";   _tmpl_rest="${_tmpl_rest% *}"
      local _tmpl_sched="$_tmpl_rest"
      local _park_blast
      if [[ "$_tmpl_pol" == "spawn" ]]; then
        # Under spawn the beat keeps firing, so the honest warning is about the
        # BOUND, not a stop. Still worth saying: a parked row counts open forever,
        # the stall watchdog skips parked rows, and enough of them silently
        # convert a spawn template into a suppressed one.
        local _park_open
        _park_open=$(db "SELECT COUNT(*) FROM tasks i JOIN tasks p ON p.id=i.from_template_id WHERE p.ident=$(sqlq "$_tmpl_ident") AND i.status NOT IN ('done','cancelled');" 2>/dev/null) || _park_open="?"
        [[ "$_park_open" =~ ^[0-9]+$ ]] || _park_open="?"
        _park_blast="this park does NOT stop that beat — ${_tmpl_ident} is on-overlap=spawn, so later slots keep firing — but it does CONSUME one of its ${_tmpl_bound} overlap slots for as long as it stays parked (the materializer counts a parked instance as open; ${_park_open} open now). At the bound the template degrades to skip-and-stamp, i.e. the beat stops after all, and the recurring-stall watchdog skips parked rows so nothing will report the drift."
      else
        _park_blast="this park STOPS THAT BEAT, it does not delay one row (DIVE-2877). The materializer counts a parked instance as ${_tmpl_ident}'s open slot, so ${_tmpl_ident} will not fire again until this row is unparked or closed, and the occurrences inside the window are DROPPED with no catch-up. The recurring-stall watchdog skips parked rows, so nothing will report it."
      fi
      warn "$tident is a recurring INSTANCE of ${_tmpl_ident} (schedule: ${_tmpl_sched}) — ${_park_blast} If you meant to pause the JOB: park the template instead — '5dive task park ${_tmpl_ident} --reason=<why> --wake=<when>' (a blocked template is skipped by the materializer, and unparking it resumes the schedule). If you meant to skip just THIS occurrence: '5dive task cancel $tident --result=\"<why>\"' — a cancel frees the slot, so the next tick fires normally."
    fi
  fi
  local wake_note=""; [[ "$wake_sql" != "NULL" ]] && wake_note=" — wakes $(db "SELECT wake_at FROM tasks WHERE id=${tid};") UTC"
  ok "$tident parked (no action needed)${reason:+ — $reason}${wake_note}" \
     '{task:($t|tonumber), task_ident:$ti, parked:true, reason:$r, wake_at:(($w|select(length>0)) // null), stops_recurring_template:(($tm|select(length>0)) // null)}' \
     --arg t "$tid" --arg ti "$tident" --arg r "$reason" --arg w "$([[ "$wake_sql" != "NULL" ]] && db "SELECT wake_at FROM tasks WHERE id=${tid};" || echo "")" \
     --arg tm "$_tmpl_ident"
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

