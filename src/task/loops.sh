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
#
# DIVE-2489: the `maker` column renders a MEASURED maker and an INFERRED one
# differently, because the difference is a governance claim. It used to be
# `COALESCE(maker_agent, assignee)`, and after a maker→verifier handoff the
# assignee IS the verifier — so a row that never stamped a maker rendered as
# maker == verifier, byte-identical to a task whose maker really did grade their
# own work. Measured on the live store 2026-08-16: 15 of 1184 verifier-carrying
# rows read as self-graded through that fallback and ZERO of them had a recorded
# maker_agent; 277 have no maker_agent at all. It fooled two agents in one day
# and marketing nearly published "12 of 576 tasks were self-graded" off it.
# Now: text prints the recorded maker, or `holder:<assignee>` when there is none
# (the fallback is kept but MARKED, so inferred and measured are never the same
# glyph), or `-` when the row has neither. JSON emits `maker: null` when it was
# never stamped — the assignee is already carried separately as `holder`, so no
# caller loses information. Same rule as the NOT-REACHED third state: a value you
# did not measure must not render as one you did.
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
               maker_agent AS maker, verifier,
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
                 CASE WHEN maker_agent IS NOT NULL THEN maker_agent
                      WHEN assignee IS NOT NULL THEN 'holder:'||assignee
                      ELSE '-' END AS maker,
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
# DIVE-5729: how many open rows a hired team's KICKOFF still holds (0 for any
# other row). The kickoff is a plain row on the lead, so every generic close
# path — `task done`, `task cancel`, a manual-gate tap, `task verify` — would
# otherwise release the team through the cascade below the moment the lead
# closes it, and the owner's yes or no would never have been asked. Only
# `team start` / `team decline` may empty it: they unblock or cancel each held
# row FIRST, so by the time they close the kickoff this count is 0.
_task_team_kickoff_holds() {
  db "SELECT COUNT(*) FROM task_deps d JOIN tasks t ON t.id=d.task_id
      WHERE d.blocked_by=${1} AND t.status NOT IN ('done','cancelled')
        AND EXISTS (SELECT 1 FROM tasks k WHERE k.id=${1} AND k.kind='standard'
                      AND k.body LIKE '%team kickoff: % (5dive.yaml)%');" 2>/dev/null || echo 0
}

_task_cascade_unblock() {
  local closed_id="$1" dep
  # DIVE-5729: a team kickoff closed by anything but `team start`/`team decline`
  # releases nothing — what is still behind it stays held (edge kept), and
  # `team plan|start|decline <lead>` still finds it to answer properly.
  if [[ "$(_task_team_kickoff_holds "$closed_id")" != "0" ]]; then
    _loop_score_request "$closed_id" || true
    return 0
  fi
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
    [[ -n "$who" ]] && ( _5DIVE_SYSTEM_NOTICE=1 cmd_send "$who" --from="task-engine" \
        --message="▶️ Unblocked: ${dident} — all its blockers are done. It's on your queue now: ${dtitle}" ) >/dev/null 2>&1 || true
  done < <(db "SELECT task_id FROM task_deps WHERE blocked_by=${closed_id};")
  # DIVE-5564: a finished loop run asks for its score (no-op for every other row).
  _loop_score_request "$closed_id" || true
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
        [[ -n "$owner" ]] && ( _5DIVE_SYSTEM_NOTICE=1 cmd_send "$owner" --from="loop" \
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
        [[ -n "$who" ]] && ( _5DIVE_SYSTEM_NOTICE=1 cmd_send "$who" --from="loop" \
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
  [[ -n "$owner" ]] || owner=$(_task_resolve_coordinator "$creator")   # DIVE-4823: the loop's creator names the team

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
  [[ -n "$who1" ]] && ( _5DIVE_SYSTEM_NOTICE=1 cmd_send "$who1" --from="loop" \
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

# ───────────────── DIVE-5564 loop scores + weekly suggestion ─────────────────
# lodar 2026-10-05, "keep it simple": a LOOP is a scheduled task (a kind='recurring'
# template — DIVE-5563 made the dashboard list every scheduled task as a loop,
# whether a loop pack, a 5dive.yaml or a person made it). Each finished run (an
# instance stamped with from_template_id) gets a 0-100 score — from the team's
# grader if there is one, else from the agent that ran it. The owner's thumbs
# up/down on a run beats the score (up = 100, down = 0). Once a week the
# lowest-scoring loop gets ONE suggested change to its instructions (the
# template body, which every future run copies); the owner applies or dismisses
# it, or a per-loop switch (off by default) applies it unasked. Revert puts the
# body from before the last applied change back.
#
# No schema change: everything lives in task_prefs under a loop.* namespace —
#   loop.score.<run ident>          {"score":N,"by":"<agent>","note":"…","at":"…"}
#   loop.vote.<run ident>           up | down
#   loop.auto.<template ident>      on   (absent = off)
#   loop.suggest.<template ident>   {"status":"pending|applied|dismissed|reverted",
#                                    "body","prev","reason","by","at","applied_at"}
#   loop.review.last                when the weekly review last filed a suggestion ask
# The weekly review has no timer of its own: every score and vote asks "is one
# due?" — a loop that is not running has nothing new to suggest from anyway.
# Dashboard: Tasks > Loops reads `task loop scores` and taps rate/apply/dismiss/
# revert/auto over the exec tunnel (the api already allows any `task loop` verb).

_LOOP_TPL_PRED="kind='recurring'"
_LOOP_RUNS_SCORED=5      # a loop's score = mean over its last N finished runs
_LOOP_REVIEW_DAYS=7
_LOOP_REVIEW_BELOW=80    # a loop at or above this (the green band) needs no fix

_loop_pref_get() { db "SELECT value FROM task_prefs WHERE key=$(sqlq "$1");" 2>/dev/null; }
_loop_pref_set() {
  db "INSERT INTO task_prefs(key,value,updated_at) VALUES ($(sqlq "$1"),$(sqlq "$2"),datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;"
}
_loop_pref_del() { db "DELETE FROM task_prefs WHERE key=$(sqlq "$1");"; }

# Who scores a run: the team's grader, else a verifier, else the runner itself.
_loop_scorer() {
  local runner="$1" g
  g=$(_org_role_holders grader 2>/dev/null | head -1)
  [[ -n "$g" ]] || g=$(_org_role_holders verifier 2>/dev/null | head -1)
  printf '%s' "${g:-$runner}"
}

# <ref> -> sets _LOOP_TID / _LOOP_TIDENT for a loop TEMPLATE, or fails. Sets
# globals rather than printing so a refusal is not swallowed by a $( ) subshell.
_loop_tpl_resolve() {
  local ref="$1"
  [[ -n "$ref" ]] || fail "$E_USAGE" "name the loop (its scheduled task, e.g. DIVE-12)"
  resolve_task_id "$ref"
  _LOOP_TIDENT=$(db "SELECT ident FROM tasks WHERE id=${RESOLVED_TASK_ID} AND ${_LOOP_TPL_PRED};")
  [[ -n "$_LOOP_TIDENT" ]] || fail "$E_VALIDATION" "$ref is not a loop (a scheduled task)"
  _LOOP_TID="$RESOLVED_TASK_ID"
}

# Called from _task_cascade_unblock on EVERY close; acts only when a run of a
# loop just closed. Best-effort.
#   - an outcome loop (DIVE-5777): a run that went done is scored by its number;
#   - every other loop (DIVE-5815): the RUNTIME scores the run from signals it
#     can read, and nobody is asked for an opinion. It used to file a "Score
#     loop run" row, and on lodar's box every run of a week stayed unscored.
_loop_score_request() {
  local id="$1" row rident st tid tident
  row=$(db "SELECT t.ident||x'1f'||t.status||x'1f'||p.id||x'1f'||p.ident
            FROM tasks t JOIN tasks p ON p.id=t.from_template_id
            WHERE t.id=${id} AND t.status IN ('done','cancelled') AND p.${_LOOP_TPL_PRED//body/p.body};" 2>/dev/null)
  [[ -n "$row" ]] || return 0
  IFS=$'\x1f' read -r rident st tid tident <<<"$row"
  if [[ -n "$(_loop_pref_get "loop.outcome.${tident}")" ]]; then
    [[ "$st" == "done" && -z "$(_loop_pref_get "loop.score.${rident}")" ]] || return 0
    local tpl; tpl=$(db "SELECT id||x'1f'||COALESCE(assignee,'') FROM tasks WHERE ident=$(sqlq "$tident");")
    _loop_outcome_tick "${tpl%%$'\x1f'*}" "$tident" "$rident" "${tpl#*$'\x1f'}" || true
    return 0
  fi
  _loop_signals_sweep "$tid" || true
  ( cmd_task_loop_review ) >/dev/null 2>&1 || true
  return 0
}

# ───────────── DIVE-5815 the runtime scores a run from signals ─────────────
# lodar 2026-10-07: "human will never score by hand - agent should know if it
# didnt go well (errors, human complain, etc)". For a loop with no outcome
# command the runtime writes each run's score (by=runtime), and the note names
# the signal. The bad ones first:
#   1. the run did not end done (cancelled, or still open when the next run
#      started), or one of its attempts failed or stopped mid-run (the runs
#      journal: status failed|abandoned, or a reclaim).
#   2. a complaint inside the window: the run was reopened, a PERSON filed a row
#      that names it, or the owner's reply about it reads as negative
#      (`task loop feedback`, a keyword floor then one Decisions call).
#   3. rework: an AGENT filed a row that names it (a fix, a redo).
#   4. none of these: 80. No news is weak evidence, not 100.
# A complaint or rework only ever LOWERS a score, and only inside the window:
# nothing filed or said after it is read. The weekly review reads these scores
# exactly as it read the opinion ones.
_LOOP_SIGNAL_HOURS=24
_LOOP_SCORE_CLEAN=80
_LOOP_SCORE_ERROR=30
_LOOP_SCORE_UNFINISHED=10
_LOOP_SCORE_COMPLAINT=20
_LOOP_SCORE_REWORK=40
# The keyword floor: a reply that says any of these is a complaint without a
# model call. English and Russian (lodar's and the OINOA boxes' languages).
_LOOP_COMPLAINT_RE="(^|[^[:alpha:]])(wrong|bad|broken|useless|terrible|awful|garbage|not what|didn'?t|did not|doesn'?t work|not working|missing|mistake|redo|again\?|why did|stop doing|failed|error)([^[:alpha:]]|$)|плох|не то|не так|ошиб|переделай|исправь|не работает|ужасн|зачем"

# _loop_score_put <run ident> <score> <note> <by> [signals json array]
_loop_score_put() {
  _loop_pref_set "loop.score.${1}" "$(jq -cn --argjson s "$2" --arg n "$3" --arg b "$4" --argjson g "${5:-[]}" \
      '{score:$s, by:$b, note:$n, at:(now|todate)} + (if ($g|length) > 0 then {signals:$g} else {} end)')"
}

# _loop_score_lower <run ident> <score> <note> <signal key> — a complaint or
# rework. Never raises: the score becomes min(current, score). A signal already
# counted (same key) is a no-op, so a sweep that runs again changes nothing.
_loop_score_lower() {
  local rident="$1" s="$2" note="$3" key="$4" cur
  cur=$(_loop_pref_get "loop.score.${rident}"); [[ -n "$cur" ]] || cur='{}'
  if jq -e --arg k "$key" '(.signals // []) | index([$k]) != null' <<<"$cur" >/dev/null 2>&1; then return 0; fi
  _loop_pref_set "loop.score.${rident}" "$(jq -c --argjson s "$s" --arg n "$note" --arg k "$key" '
      .score = ([.score // $s, $s] | min) | .by = "runtime" | .lowered_at = (now|todate)
      | .note = (if (.note // "") == "" or .note == "clean run" then $n else .note + "; " + $n end)
      | .signals = ((.signals // []) + [$k])' <<<"$cur")"
}

# _loop_first_score <run id> — the score a closed run gets from signal 1, or 80.
_loop_first_score() {
  local id="$1" rident st res bad
  IFS=$'\x1f' read -r rident st res < <(db "SELECT ident||x'1f'||status||x'1f'||COALESCE(result,'') FROM tasks WHERE id=${id};")
  if [[ "$st" == "cancelled" ]]; then
    _loop_score_put "$rident" "$_LOOP_SCORE_UNFINISHED" "did not finish: cancelled${res:+ ($(_loop_clip "$res"))}" runtime '["cancelled"]'
    return 0
  fi
  bad=$(db "SELECT status||x'1f'||COALESCE(outcome,'')||x'1f'||COALESCE(error_class,'')||x'1f'||COALESCE(error_summary,'')
            FROM runs WHERE task_id=${id} AND status IN ('failed','abandoned')
            ORDER BY started_at DESC, rowid DESC LIMIT 1;" 2>/dev/null)
  if [[ -n "$bad" ]]; then
    local rs out ec es; IFS=$'\x1f' read -r rs out ec es <<<"$bad"
    if [[ "$rs" == "failed" ]]; then
      _loop_score_put "$rident" "$_LOOP_SCORE_ERROR" "error: $(_loop_clip "${ec:-failed}${es:+: $es}")" runtime '["error"]'
    else
      _loop_score_put "$rident" "$_LOOP_SCORE_ERROR" "error: stopped mid-run ($(_loop_clip "${out:-abandoned}${ec:+, $ec}"))" runtime '["error"]'
    fi
    return 0
  fi
  if [[ "$(db "SELECT COUNT(*) FROM lifecycle_events WHERE kind='task.reclaimed' AND task_id=${id};" 2>/dev/null)" =~ ^[1-9] ]]; then
    _loop_score_put "$rident" "$_LOOP_SCORE_ERROR" "error: reclaimed (its seat stopped mid-run)" runtime '["error"]'
    return 0
  fi
  _loop_score_put "$rident" "$_LOOP_SCORE_CLEAN" "clean run" runtime
}

_loop_clip() { local t="${1//$'\n'/ }"; (( ${#t} > 120 )) && t="${t:0:117}..."; printf '%s' "$t"; }

# _loop_is_person <name> — rc 0 when a row's creator is a person, not an agent:
# not on the team, not a registered seat, and not the runtime itself.
_loop_is_person() {
  local who="$1"
  [[ -n "$who" && "$who" != loop && "$who" != task-engine && "$who" != heartbeat ]] || return 1
  [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE name=$(sqlq "$who");" 2>/dev/null)" == "0" ]] || return 1
  declare -F agent_tier >/dev/null || return 0
  [[ "$(agent_tier "$who" 2>/dev/null)" == unknown:unregistered ]]
}

# _loop_complaints <run id> — signals 2 and 3 for a scored run, inside the window.
_loop_complaints() {
  local id="$1" rident st done_at within
  IFS=$'\x1f' read -r rident st done_at < <(db "SELECT ident||x'1f'||status||x'1f'||COALESCE(done_at,'') FROM tasks WHERE id=${id};")
  [[ -n "$done_at" ]] || return 0
  within="julianday($(sqlq "$done_at")) + ${_LOOP_SIGNAL_HOURS}/24.0"
  # Reopened after it closed, while the window is still open.
  if [[ "$st" != "done" && "$st" != "cancelled" ]] \
     && [[ "$(db "SELECT julianday('now') <= ${within};")" == "1" ]]; then
    _loop_score_lower "$rident" "$_LOOP_SCORE_COMPLAINT" "owner complained: reopened it" reopened
  fi
  # A row filed inside the window that names the run (not its own steps, not the
  # runtime's rows). By a person: a complaint. By an agent: rework.
  local n nident ntitle nby
  while IFS=$'\x1f' read -r n nident ntitle nby; do
    [[ -n "$n" ]] || continue
    if _loop_is_person "$nby"; then
      _loop_score_lower "$rident" "$_LOOP_SCORE_COMPLAINT" "owner complained: filed ${nident} ($(_loop_clip "$ntitle"))" "row:${nident}"
    else
      _loop_score_lower "$rident" "$_LOOP_SCORE_REWORK" "rework: ${nident} redoes it ($(_loop_clip "$ntitle"))" "row:${nident}"
    fi
  done < <(db "SELECT id||x'1f'||ident||x'1f'||COALESCE(title,'')||x'1f'||COALESCE(created_by,'')
               FROM tasks
               WHERE id<>${id} AND COALESCE(parent_id,0)<>${id}
                 AND COALESCE(created_by,'') <> 'loop'
                 AND title NOT LIKE 'Score loop run %' AND title NOT LIKE 'Suggest a change to loop %'
                 AND julianday(created_at) >= julianday($(sqlq "$done_at"))
                 AND julianday(created_at) <= ${within}
                 AND (' '||COALESCE(title,'')||' '||COALESCE(body,'')||' ') GLOB $(sqlq "*[^0-9A-Za-z]${rident}[^0-9]*")
               ORDER BY id;" 2>/dev/null)
}

# _loop_signals_sweep [<template id>] — the runtime's pass over the last runs of
# every loop with no outcome command (or one loop): score what closed unscored,
# score a run still open when the next one started, read complaints inside the
# window, and close any "Score loop run" row the old path filed and nobody has
# started (with a result, not empty). Pure SQL: the one model call lives in
# `task loop feedback`, at the moment a reply arrives.
_loop_signals_sweep() {
  local only="${1:-}" tid tident rid rident st scored nxt
  while IFS=$'\x1f' read -r tid tident; do
    [[ -n "$tid" ]] || continue
    [[ -z "$(_loop_pref_get "loop.outcome.${tident}")" ]] || continue
    while IFS=$'\x1f' read -r rid rident st scored nxt; do
      [[ -n "$rid" ]] || continue
      if [[ "$scored" == "0" ]]; then
        case "$st" in
          done|cancelled) _loop_first_score "$rid" ;;
          *) [[ -n "$nxt" ]] || continue
             _loop_score_put "$rident" "$_LOOP_SCORE_UNFINISHED" "did not finish: still ${st} when ${nxt} started" runtime '["unfinished"]' ;;
        esac
      fi
      _loop_complaints "$rid"
      local sc; sc=$(_loop_pref_get "loop.score.${rident}")
      [[ -n "$sc" ]] && db "UPDATE tasks SET status='done', done_at=datetime('now'),
            result=$(sqlq "Scored by the runtime from signals instead (DIVE-5815): $(jq -r '"\(.score)/100, \(.note)"' <<<"$sc"). No opinion needed.")
          WHERE title=$(sqlq "Score loop run ${rident}") AND status='todo' AND COALESCE(created_by,'')='loop';" 2>/dev/null
    done < <(db "SELECT r.id||x'1f'||r.ident||x'1f'||r.status||x'1f'||
                        (SELECT COUNT(*) FROM task_prefs WHERE key='loop.score.'||r.ident)||x'1f'||
                        COALESCE((SELECT n.ident FROM tasks n WHERE n.from_template_id=r.from_template_id AND n.id>r.id ORDER BY n.id LIMIT 1),'')
                 FROM tasks r WHERE r.from_template_id=${tid}
                 ORDER BY r.id DESC LIMIT ${_LOOP_RUNS_SCORED};")
  done < <(db "SELECT id||x'1f'||ident FROM tasks WHERE ${_LOOP_TPL_PRED} ${only:+AND id=${only}} ORDER BY id;")
  return 0
}

# _loop_reply_is_complaint <text> -> prints "keyword", "model" or nothing.
# The keyword floor first (free); then ONE Decisions call (~$0.0005) when the
# box has reflex configured. An error, a timeout or a low-confidence pick is
# not a complaint: a score is lowered only on evidence.
_loop_reply_is_complaint() {
  local text="$1" req resp choice conf
  if grep -qiE "$_LOOP_COMPLAINT_RE" <<<"$text"; then printf 'keyword'; return 0; fi
  declare -F reflex_configured >/dev/null && declare -F _reflex_endpoint_decide >/dev/null || return 0
  [[ "$(reflex_configured 2>/dev/null)" == true ]] || return 0
  reflex_model_resolve 2>/dev/null || true
  req=$(jq -cn --arg t "$text" '{policy:"loop-reply", version:1, type:"choice",
     instructions:"The owner of a recurring agent job replied to one of its runs. Is the reply a complaint about the run?",
     criteria:{complaint:"It says the run was wrong, poor, incomplete, unwanted or must be redone.",
               neutral:"A question, an instruction for next time, or an acknowledgement; no judgement of the run.",
               praise:"It says the run was good or useful."},
     options:["complaint","neutral","praise"], state:{reply:$t}}') || return 0
  resp=$(_reflex_endpoint_decide "${_REFLEX_MODEL:-typesafe/jev-1.13}" 10 <<<"$req" 2>/dev/null) || return 0
  choice=$(jq -r '.choice // empty | strings' <<<"${resp%%$'\n'*}" 2>/dev/null)
  conf=$(jq -r '.confidence // 1 | numbers' <<<"${resp%%$'\n'*}" 2>/dev/null)
  [[ "$choice" == complaint ]] && jq -en --argjson c "${conf:-1}" '$c >= 0.6' >/dev/null 2>&1 && printf 'model'
  return 0
}

# `task loop feedback <run> --text="<the owner's reply>" [--at=<UTC time>]` —
# the owner said something about a run (a reply in its channel). Called by the
# channel bridge or the seat that received it. Inside the window a complaint
# LOWERS the run's score; outside it, or not a complaint, nothing changes.
cmd_task_loop_feedback() {
  tasks_db_init
  local ref="" text="" at=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --text=*) text="${1#*=}" ;;
      --at=*)   at="${1#*=}" ;;
      --from=*) ;;
      -*)       fail "$E_USAGE" "unknown flag: $1" ;;
      *)        [[ -z "$ref" ]] && ref="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$ref" && -n "${text//[[:space:]]/}" ]] || fail "$E_USAGE" "usage: 5dive task loop feedback <run> --text=\"<the owner's reply>\" [--at=<UTC time>]"
  resolve_task_id "$ref"
  local id="$RESOLVED_TASK_ID" row rident done_at tident
  row=$(db "SELECT t.ident||x'1f'||COALESCE(t.done_at,'')||x'1f'||p.ident FROM tasks t JOIN tasks p ON p.id=t.from_template_id
            WHERE t.id=${id} AND p.${_LOOP_TPL_PRED//body/p.body};")
  [[ -n "$row" ]] || fail "$E_VALIDATION" "$ref is not a run of a loop"
  IFS=$'\x1f' read -r rident done_at tident <<<"$row"
  [[ -n "$at" ]] || at=$(db "SELECT datetime('now');")
  [[ "$(db "SELECT julianday($(sqlq "$at")) IS NOT NULL;")" == "1" ]] || fail "$E_VALIDATION" "--at is not a time: $at"
  if [[ -z "$done_at" ]] \
     || [[ "$(db "SELECT julianday($(sqlq "$at")) BETWEEN julianday($(sqlq "$done_at")) AND julianday($(sqlq "$done_at")) + ${_LOOP_SIGNAL_HOURS}/24.0;")" != "1" ]]; then
    ok "${rident}: reply is outside its ${_LOOP_SIGNAL_HOURS}h window, score unchanged" '{run:$r, lowered:false, reason:"outside window"}' --arg r "$rident"
    return 0
  fi
  local how; how=$(_loop_reply_is_complaint "$text")
  if [[ -z "$how" ]]; then
    ok "${rident}: reply is not a complaint, score unchanged" '{run:$r, lowered:false, reason:"not a complaint"}' --arg r "$rident"
    return 0
  fi
  [[ -n "$(_loop_pref_get "loop.score.${rident}")" ]] || _loop_first_score "$id"
  _loop_score_lower "$rident" "$_LOOP_SCORE_COMPLAINT" "owner complained: $(_loop_clip "$text")" "reply:${at}"
  ( cmd_task_loop_review ) >/dev/null 2>&1 || true
  ok "${rident}: owner complaint, score lowered to $(_loop_pref_get "loop.score.${rident}" | jq -r .score)/100" \
     '{run:$r, lowered:true, by:$h, score:($s|tonumber)}' --arg r "$rident" --arg h "$how" \
     --arg s "$(_loop_pref_get "loop.score.${rident}" | jq -r .score)"
}

# `task loop score <run> --score=<0-100> [--note=]`
cmd_task_loop_score() {
  tasks_db_init
  local ref="" score="" note="" from=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --score=*) score="${1#*=}" ;;
      --note=*)  note="${1#*=}" ;;
      --from=*)  from="${1#*=}" ;;
      -*)        fail "$E_USAGE" "unknown flag: $1" ;;
      *)         [[ -z "$ref" ]] && ref="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$ref" ]] || fail "$E_USAGE" "usage: 5dive task loop score <run> --score=<0-100> [--note=\"…\"]"
  [[ "$score" =~ ^[0-9]{1,3}$ ]] && (( 10#$score <= 100 )) || fail "$E_VALIDATION" "--score must be a whole number 0-100"
  resolve_task_id "$ref"
  local rident
  rident=$(db "SELECT t.ident FROM tasks t JOIN tasks p ON p.id=t.from_template_id
               WHERE t.id=${RESOLVED_TASK_ID} AND p.${_LOOP_TPL_PRED//body/p.body};")
  [[ -n "$rident" ]] || fail "$E_VALIDATION" "$ref is not a run of a loop"
  local by; by=$(task_actor "$from")
  _loop_pref_set "loop.score.${rident}" "$(jq -cn --argjson s "$((10#$score))" --arg b "$by" --arg n "$note" \
      '{score:$s, by:$b, note:$n, at:(now|todate)}')"
  ( cmd_task_loop_review ) >/dev/null 2>&1 || true
  ok "scored ${rident}: ${score}/100" '{run:$r, score:($s|tonumber), by:$b}' \
     --arg r "$rident" --arg s "$((10#$score))" --arg b "$by"
}

# `task loop rate <run> up|down|clear` — the owner's thumbs; beats the score.
cmd_task_loop_rate() {
  tasks_db_init
  local ref="${1:-}" vote="${2:-}"
  [[ -n "$ref" && "$vote" =~ ^(up|down|clear)$ ]] || fail "$E_USAGE" "usage: 5dive task loop rate <run> up|down|clear"
  resolve_task_id "$ref"
  local rident
  rident=$(db "SELECT t.ident FROM tasks t JOIN tasks p ON p.id=t.from_template_id
               WHERE t.id=${RESOLVED_TASK_ID} AND p.${_LOOP_TPL_PRED//body/p.body};")
  [[ -n "$rident" ]] || fail "$E_VALIDATION" "$ref is not a run of a loop"
  if [[ "$vote" == "clear" ]]; then _loop_pref_del "loop.vote.${rident}"; else _loop_pref_set "loop.vote.${rident}" "$vote"; fi
  ( cmd_task_loop_review ) >/dev/null 2>&1 || true
  ok "rated ${rident}: ${vote}" '{run:$r, vote:$v}' --arg r "$rident" --arg v "$vote"
}

# The board as one JSON array: each loop with its last runs, score, switch and
# suggestion. score = mean of the runs' effective scores (vote up=100, down=0,
# else the agent's score); null until a run is scored or rated.
_loop_board_json() {
  local rows
  rows=$(db "SELECT json_group_array(json_object(
          'ident', p.ident, 'title', p.title, 'assignee', p.assignee, 'schedule', p.schedule,
          'instructions', p.body,
          'auto', (SELECT value='on' FROM task_prefs WHERE key='loop.auto.'||p.ident),
          'outcome', (SELECT json(value) FROM task_prefs WHERE key='loop.outcome.'||p.ident AND json_valid(value)),
          'paused', p.parked_at IS NOT NULL,
          'suggestion', (SELECT json(value) FROM task_prefs WHERE key='loop.suggest.'||p.ident AND json_valid(value)),
          'runs', (SELECT json_group_array(json_object('ident', r.ident, 'done_at', r.done_at,
                     'score', (SELECT json(value) FROM task_prefs WHERE key='loop.score.'||r.ident AND json_valid(value)),
                     'vote', (SELECT value FROM task_prefs WHERE key='loop.vote.'||r.ident)))
                   FROM (SELECT ident, done_at FROM tasks WHERE from_template_id=p.id
                           AND (status IN ('done','cancelled') OR ident IN (SELECT substr(key,12) FROM task_prefs WHERE key LIKE 'loop.score.%'))
                         ORDER BY id DESC LIMIT ${_LOOP_RUNS_SCORED}) r)))
         FROM (SELECT * FROM tasks WHERE ${_LOOP_TPL_PRED} AND status <> 'cancelled' ORDER BY id) p;")
  [[ -n "$rows" ]] || rows="[]"
  # DIVE-5777: an outcome loop has no opinion score. Paused by its outcome it
  # scores 0, the lowest, so the weekly review asks for its new instructions;
  # running, it scores nothing and the board shows its number instead.
  jq -c 'map(.auto = (.auto == 1) | .paused = (.paused == 1)
         | .runs = (.runs | map(.effective = (if .vote == "up" then 100 elif .vote == "down" then 0
                                              else (.score.score // null) end)))
         | .score = (if .outcome != null then (if .outcome.paused_at then 0 else null end)
                     else ([.runs[].effective | select(. != null)] | if length == 0 then null
                                                                     else (add / length | round) end) end))' <<<"$rows"
}

# `task loop scores` — the loops board.
cmd_task_loop_scores() {
  tasks_db_init
  # DIVE-5815: the board is what the dashboard polls, so it is where the runtime
  # catches up: score what closed unscored, read complaints inside the window.
  ( _loop_signals_sweep ) >/dev/null 2>&1 || true
  local board; board=$(_loop_board_json)
  if (( JSON_MODE )); then
    jq -c '{ok:true, data:{loops:.}}' <<<"$board"
  else
    jq -r 'if length == 0 then "no loops (a loop is a scheduled task: add one with --recurring=<cron>)" else
      .[] | "\(.ident)  \(if .outcome != null then "outcome \(.outcome.last // "unread")\(if .outcome.paused_at then " PAUSED (no rise since \(.outcome.since))" else "" end)"
                     elif .score == null then "unscored" else "\(.score)/100" end)  \(.title)  [\(.assignee // "-")]"
        + (if .auto then "  self-improve:on" else "" end)
        + (if .suggestion.status == "pending" then "  suggestion: pending" else "" end) end' <<<"$board"
  fi
}

# `task loop review [--force]` — the weekly pass: ask for one change to the
# lowest-scoring loop, if it scores under 80. Not due (under 7 days since the
# last ask) is a no-op unless --force.
cmd_task_loop_review() {
  tasks_db_init
  local force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1 ;;
      *)       fail "$E_USAGE" "usage: 5dive task loop review [--force]" ;;
    esac
    shift
  done
  local last; last=$(_loop_pref_get loop.review.last)
  if (( ! force )) && [[ -n "$last" ]] \
     && [[ "$(db "SELECT julianday('now') - julianday($(sqlq "$last")) < ${_LOOP_REVIEW_DAYS};")" == "1" ]]; then
    ok "weekly loop review not due (last: ${last})" '{filed:false, reason:"not due", last:$l}' --arg l "$last"
    return 0
  fi
  local pick
  pick=$(_loop_board_json | jq -c --argjson below "$_LOOP_REVIEW_BELOW" \
    '[.[] | select(.score != null and .score < $below and .suggestion.status != "pending")]
     | sort_by(.score) | .[0] // empty')
  if [[ -z "$pick" ]]; then
    ok "no loop scores under ${_LOOP_REVIEW_BELOW}, nothing to suggest" '{filed:false, reason:"no loop needs a fix"}'
    return 0
  fi
  local tident ttitle tscore owner title runs
  tident=$(jq -r .ident <<<"$pick"); ttitle=$(jq -r '.title // ""' <<<"$pick")
  tscore=$(jq -r .score <<<"$pick"); owner=$(jq -r '.assignee // ""' <<<"$pick")
  title="Suggest a change to loop ${tident}"
  if [[ "$(db "SELECT COUNT(*) FROM tasks WHERE title=$(sqlq "$title") AND status NOT IN ('done','cancelled');")" != "0" ]]; then
    ok "a suggestion for ${tident} is already being written" '{filed:false, reason:"already asked", loop:$t}' --arg t "$tident"
    return 0
  fi
  local lead_line="Loop ${tident} (\"${ttitle}\") scores ${tscore}/100, the lowest of the loops this week. Suggest ONE change to its instructions that would raise the score."
  if [[ "$(jq -r '.outcome.paused_at // ""' <<<"$pick")" != "" ]]; then
    lead_line="Loop ${tident} (\"${ttitle}\") paused itself: the number it is measured by ($(jq -r .outcome.cmd <<<"$pick")) has stayed at $(jq -r '.outcome.last // "no reading"' <<<"$pick") since $(jq -r .outcome.since <<<"$pick") UTC. Suggest ONE change to its instructions that would make that number rise: a different lane, not more of the same work."
  fi
  runs=$(jq -r '.runs[] | "- \(.ident): \(.effective // .score.outcome // "unscored")\(if .vote then " (owner: \(.vote))" else "" end)\(if (.score.note // "") != "" then " — \(.score.note)" else "" end)"' <<<"$pick")
  local out ident
  out=$(JSON_MODE=1 cmd_task_add "$title" --materialized --review=none --fresh --from=loop \
      --assignee="$(_loop_scorer "$owner")" --priority=medium \
      --body="${lead_line}

Recent runs:
${runs}

1. Read the current instructions (the body): 5dive task show ${tident}
2. Write the full new instructions to a file, then record them:
   5dive task loop suggest ${tident} --body-file=<path> --reason=\"<one line: what changes and why>\"
3. Close this row with task done. The owner taps Apply or Dismiss on the dashboard (or it applies itself if the loop's self-improvement switch is on)." 2>/dev/null) || true
  ident=$(jq -r '.data.ident // empty' <<<"$out" 2>/dev/null)
  [[ -n "$ident" ]] || fail "$E_GENERIC" "could not file the suggestion ask for ${tident}"
  _loop_pref_set loop.review.last "$(db "SELECT datetime('now');")"
  ok "asked for a change to ${tident} (${tscore}/100) on ${ident}" '{filed:true, loop:$t, score:($s|tonumber), task:$i}' \
     --arg t "$tident" --arg s "$tscore" --arg i "$ident"
}

# `task loop suggest <loop> --body=…|--body-file=<path> [--reason=]` — record the
# suggested instructions. A loop pack's or 5dive.yaml's marker line is carried
# over if the new text drops it (`loop uninstall` and `team import` find their
# loops by it). With the switch on, applies.
cmd_task_loop_suggest() {
  tasks_db_init
  local ref="" body="" body_file="" reason="" from="" have_body=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --body=*)      body="${1#*=}"; have_body=1 ;;
      --body-file=*) body_file="${1#*=}" ;;
      --reason=*)    reason="${1#*=}" ;;
      --from=*)      from="${1#*=}" ;;
      -*)            fail "$E_USAGE" "unknown flag: $1" ;;
      *)             [[ -z "$ref" ]] && ref="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  if [[ -n "$body_file" ]]; then
    [[ -r "$body_file" ]] || fail "$E_VALIDATION" "cannot read --body-file: $body_file"
    body=$(cat "$body_file"); have_body=1
  fi
  (( have_body )) || fail "$E_USAGE" "usage: 5dive task loop suggest <loop> --body=\"…\"|--body-file=<path> [--reason=\"…\"]"
  local tid tident cur markers
  _loop_tpl_resolve "$ref"; tid="$_LOOP_TID"; tident="$_LOOP_TIDENT"
  [[ -n "${body//[[:space:]]/}" ]] || fail "$E_VALIDATION" "the suggested instructions are empty"
  cur=$(db "SELECT body FROM tasks WHERE id=${tid};")
  markers=$(grep -E 'installed loop: |declared loop: ' <<<"$cur" || true)
  if [[ -n "$markers" ]] && ! grep -qE 'installed loop: |declared loop: ' <<<"$body"; then
    body="${body}

${markers}"
  fi
  [[ "$body" != "$cur" ]] || fail "$E_VALIDATION" "the suggestion is the same as the current instructions"
  local by; by=$(task_actor "$from")
  _loop_pref_set "loop.suggest.${tident}" "$(jq -cn --arg b "$body" --arg r "$reason" --arg by "$by" \
      '{status:"pending", body:$b, reason:$r, by:$by, at:(now|todate)}')"
  if [[ "$(_loop_pref_get "loop.auto.${tident}")" == "on" ]]; then
    _loop_apply "$tid" "$tident" "self-improvement"
    ok "suggestion for ${tident} applied (self-improvement is on)" '{loop:$t, status:"applied", auto:true}' --arg t "$tident"
  else
    ok "suggestion for ${tident} is waiting for the owner" '{loop:$t, status:"pending", auto:false}' --arg t "$tident"
  fi
}

# Apply the pending suggestion: keep the current body as `prev` for Revert.
_loop_apply() {
  local tid="$1" tident="$2" by="$3" sug cur
  sug=$(_loop_pref_get "loop.suggest.${tident}")
  [[ "$(jq -r '.status // ""' <<<"$sug" 2>/dev/null)" == "pending" ]] || fail "$E_VALIDATION" "no pending suggestion for ${tident}"
  cur=$(db "SELECT body FROM tasks WHERE id=${tid};")
  db "UPDATE tasks SET body=$(sqlq "$(jq -r .body <<<"$sug")") WHERE id=${tid};"
  _loop_pref_set "loop.suggest.${tident}" "$(jq -c --arg p "$cur" --arg by "$by" \
      '.status="applied" | .prev=$p | .applied_by=$by | .applied_at=(now|todate)' <<<"$sug")"
}

# `task loop apply|dismiss|revert <loop>` — the owner's three taps.
cmd_task_loop_decide() {
  tasks_db_init
  local verb="$1" ref="${2:-}" tid tident sug st
  _loop_tpl_resolve "$ref"; tid="$_LOOP_TID"; tident="$_LOOP_TIDENT"
  sug=$(_loop_pref_get "loop.suggest.${tident}")
  st=$(jq -r '.status // ""' <<<"$sug" 2>/dev/null)
  case "$verb" in
    apply)
      _loop_apply "$tid" "$tident" "$(task_actor "")"
      # DIVE-5777: new instructions on a loop its outcome paused are the
      # redirect, so the owner's Apply also resumes it with a fresh 3 days.
      if _loop_outcome_resume "$tid" "$tident"; then
        ok "applied the suggestion to ${tident} and resumed it" '{loop:$t, status:"applied", resumed:true}' --arg t "$tident"
      else
        ok "applied the suggestion to ${tident}" '{loop:$t, status:"applied"}' --arg t "$tident"
      fi ;;
    dismiss)
      [[ "$st" == "pending" ]] || fail "$E_VALIDATION" "no pending suggestion for ${tident}"
      _loop_pref_set "loop.suggest.${tident}" "$(jq -c '.status="dismissed" | .dismissed_at=(now|todate)' <<<"$sug")"
      ok "dismissed the suggestion for ${tident}" '{loop:$t, status:"dismissed"}' --arg t "$tident" ;;
    revert)
      [[ "$st" == "applied" ]] || fail "$E_VALIDATION" "no applied change to revert on ${tident}"
      db "UPDATE tasks SET body=$(sqlq "$(jq -r .prev <<<"$sug")") WHERE id=${tid};"
      _loop_pref_set "loop.suggest.${tident}" "$(jq -c '.status="reverted" | .reverted_at=(now|todate)' <<<"$sug")"
      ok "reverted ${tident} to its instructions before the last change" '{loop:$t, status:"reverted"}' --arg t "$tident" ;;
  esac
}

# `task loop auto <loop> on|off` — the self-improvement switch (off by default).
# Turning it on with a suggestion already waiting applies that one too.
cmd_task_loop_auto() {
  tasks_db_init
  local ref="${1:-}" state="${2:-}" tid tident applied=false
  [[ "$state" =~ ^(on|off)$ ]] || fail "$E_USAGE" "usage: 5dive task loop auto <loop> on|off"
  _loop_tpl_resolve "$ref"; tid="$_LOOP_TID"; tident="$_LOOP_TIDENT"
  if [[ "$state" == "on" ]]; then
    [[ -z "$(_loop_pref_get "loop.outcome.${tident}")" ]] \
      || fail "$E_VALIDATION" "${tident} is scored by its outcome, and its next lane is the owner's call: self-improvement stays off (DIVE-5777)"
    _loop_pref_set "loop.auto.${tident}" on
    if [[ "$(jq -r '.status // ""' <<<"$(_loop_pref_get "loop.suggest.${tident}")" 2>/dev/null)" == "pending" ]]; then
      _loop_apply "$tid" "$tident" "self-improvement"; applied=true
    fi
  else
    _loop_pref_del "loop.auto.${tident}"
  fi
  ok "self-improvement ${state} for ${tident}" '{loop:$t, auto:($s=="on"), applied:($a=="true")}' \
     --arg t "$tident" --arg s "$state" --arg a "$applied"
}

# ───────────── DIVE-5777 an outcome command replaces the opinion score ─────────────
# An opinion score grades ACTIVITY: the chill-gorge distribution team's runs did
# their job every day for 8 days and its lane produced 0 sign-ups (wiki:
# a-loop-scored-by-opinion-grades-activity). So a loop may carry ONE optional
# outcome command that prints one number. When it is set:
#   - after each run the runtime runs it, as the loop's own seat, in that seat's
#     home, and records the number on the run. No agent is asked for a score;
#   - the number has not risen for 3 days (the first reading is the baseline, so
#     a lane that never moves pauses 3 days after the command was set): the loop
#     pauses itself (its template is parked, which the materializer skips) and
#     its lead is asked, once, to tell the owner;
#   - a paused loop scores 0, the lowest, so the weekly review asks for new
#     instructions for it; the owner's Apply on that suggestion resumes it with a
#     fresh 3 days, as does `task loop resume` (or a plain `task unpark`);
#   - self-improvement stays OFF: choosing the next lane is the owner's call.
# State, beside the DIVE-5564 keys:
#   loop.outcome.<template ident>  {"cmd","set_by","set_at","since","best","last",
#                                   "last_at","paused_at"}
# since = when the number last rose (or the command was set / the loop resumed).
_LOOP_OUTCOME_FLAT_DAYS=3
_LOOP_OUTCOME_TIMEOUT=60

# The unix user a seat runs as (agent-<name>, or <name> for a seat with its own).
_loop_seat_user() {
  if id -u "agent-$1" >/dev/null 2>&1; then printf 'agent-%s' "$1"; return 0; fi
  if id -u "$1" >/dev/null 2>&1; then printf '%s' "$1"; return 0; fi
  return 1
}

# The command is stored on the shared board and run later by whatever closes a
# run, so it only ever runs AS THE LOOP'S SEAT: root switches to that user, the
# seat itself runs it directly, and any other process does not run it at all.
# Otherwise one seat could plant a command that another seat, or root, runs.
# <seat> <cmd> -> stdout of the command; rc 125 = could not run it as that seat.
_loop_outcome_exec() {
  local u
  u=$(_loop_seat_user "$1") || return 125
  if [[ "$EUID" == "0" && "$u" != "root" ]]; then
    runuser -u "$u" -- timeout "$_LOOP_OUTCOME_TIMEOUT" bash -c 'cd ~ 2>/dev/null; eval "$1"' _ "$2" </dev/null 2>/dev/null
  elif [[ "$(id -un)" == "$u" ]]; then
    ( cd ~ 2>/dev/null; timeout "$_LOOP_OUTCOME_TIMEOUT" bash -c "$2" </dev/null 2>/dev/null )
  else
    return 125
  fi
}

# <seat> <cmd> -> "<number>|0", or "|<rc>" when it failed or printed no number.
_loop_outcome_read() {
  local out rc first
  out=$(_loop_outcome_exec "$1" "$2"); rc=$?
  first=$(printf '%s\n' "$out" | head -n1)
  first="${first#"${first%%[![:space:]]*}"}"; first="${first%"${first##*[![:space:]]}"}"
  if (( rc == 0 )) && [[ "$first" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s|0' "$(jq -n --arg v "$first" '$v | tonumber')"
  else
    (( rc == 0 )) && rc=1
    printf '|%s' "$rc"
  fi
}

# A loop whose outcome state says paused but whose template is no longer parked
# was resumed by hand (`task unpark`): start a fresh window instead of pausing
# it again on the next reading.
_loop_outcome_resumed_sql() {  # <template id>
  db "SELECT CASE WHEN parked_at IS NULL AND status NOT IN ('done','cancelled') THEN 1 ELSE 0 END FROM tasks WHERE id=$1;"
}

# Called by _loop_score_request for a finished run of an outcome loop.
_loop_outcome_tick() {  # <template id> <template ident> <run ident> <seat>
  local tid="$1" tident="$2" rident="$3" seat="$4" st cmd reading val rc now
  st=$(_loop_pref_get "loop.outcome.${tident}")
  cmd=$(jq -r '.cmd // ""' <<<"$st" 2>/dev/null)
  [[ -n "$cmd" ]] || return 0
  now=$(db "SELECT datetime('now');")
  if [[ -n "$(jq -r '.paused_at // ""' <<<"$st")" && "$(_loop_outcome_resumed_sql "$tid")" == "1" ]]; then
    st=$(jq -c --arg n "$now" 'del(.paused_at) | .since=$n' <<<"$st")
  fi
  reading=$(_loop_outcome_read "$seat" "$cmd"); val="${reading%|*}"; rc="${reading##*|}"
  if [[ -n "$val" ]]; then
    _loop_pref_set "loop.score.${rident}" "$(jq -cn --argjson v "$val" \
        '{outcome:$v, by:"outcome", note:"the outcome command printed \($v)", at:(now|todate)}')"
    st=$(jq -c --argjson v "$val" --arg n "$now" \
        'if .best == null then .best=$v elif $v > .best then .best=$v | .since=$n else . end
         | .last=$v | .last_at=$n' <<<"$st")
  else
    local why="the outcome command failed (exit ${rc}) or printed no number"
    (( rc == 125 )) && why="the outcome command could not run as ${seat}"
    _loop_pref_set "loop.score.${rident}" "$(jq -cn --arg w "$why" '{outcome:null, by:"outcome", note:$w, at:(now|todate)}')"
  fi
  _loop_pref_set "loop.outcome.${tident}" "$st"
  # The clock runs on readings that failed too: a broken command is not a rise.
  [[ -z "$(jq -r '.paused_at // ""' <<<"$st")" ]] || return 0
  [[ "$(db "SELECT julianday($(sqlq "$now")) - julianday($(sqlq "$(jq -r '.since // .set_at' <<<"$st")")) >= ${_LOOP_OUTCOME_FLAT_DAYS};")" == "1" ]] || return 0
  _loop_outcome_pause "$tid" "$tident" "$st"
}

# Park the template (the materializer skips it; nothing else wakes it) and ask
# the lead, once, to tell the owner.
_loop_outcome_pause() {  # <template id> <template ident> <state json>
  local tid="$1" tident="$2" st="$3" ttitle seat lead last since num title
  db "UPDATE tasks SET status='blocked', parked_at=datetime('now'), wake_at=NULL,
        park_reason=$(sqlq "paused by its outcome: the number has not risen in ${_LOOP_OUTCOME_FLAT_DAYS} days (DIVE-5777). Resume: 5dive task loop resume ${tident}")
      WHERE id=${tid} AND status NOT IN ('done','cancelled')
        AND (need_type IS NULL OR need_answered_at IS NOT NULL);"
  [[ "$(db "SELECT CASE WHEN parked_at IS NULL THEN 0 ELSE 1 END FROM tasks WHERE id=${tid};")" == "1" ]] || return 0
  _loop_pref_set "loop.outcome.${tident}" "$(jq -c '.paused_at=(now|todate)' <<<"$st")"
  ttitle=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${tid};")
  seat=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${tid};")
  lead=$(_task_org_root_of "$seat" 2>/dev/null); lead="${lead:-$seat}"
  [[ -n "$lead" ]] || return 0
  last=$(jq -r '.last // "no reading"' <<<"$st"); since=$(jq -r '.since // .set_at' <<<"$st")
  num=$(jq -r '.cmd' <<<"$st")
  title="Tell your owner loop ${tident} paused itself"
  [[ "$(db "SELECT COUNT(*) FROM tasks WHERE title=$(sqlq "$title") AND status NOT IN ('done','cancelled');")" == "0" ]] || return 0
  ( JSON_MODE=1 cmd_task_add "$title" --materialized --review=none --fresh --from=loop \
      --assignee="$lead" --priority=high \
      --body="Loop ${tident} (\"${ttitle}\") paused itself: its number has not risen since ${since} UTC. Last reading: ${last}. The number comes from: ${num}

1. Send your owner ONE message, where you normally talk to them. At most 60 words, plain words, no task numbers: what this loop was doing, that its number stayed at ${last} for ${_LOOP_OUTCOME_FLAT_DAYS} days so it stopped, and ask: try it again as it is, change what it does, or leave it stopped?
2. Their answer: again as it is = 5dive task loop resume ${tident}. Change it = write what they want as its new instructions (5dive task loop suggest ${tident} --body-file=<path>), then 5dive task loop apply ${tident}, which also resumes it. Leave it stopped = nothing to do.
3. Close this row with task done once the message is sent. Do not ask them again." ) >/dev/null 2>&1 || true
  return 0
}

# `task loop outcome <loop> --cmd="<command>" | --clear | --check`
cmd_task_loop_outcome() {
  tasks_db_init
  local ref="" cmd="" clear=0 check=0 have_cmd=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cmd=*)  cmd="${1#*=}"; have_cmd=1 ;;
      --clear)  clear=1 ;;
      --check)  check=1 ;;
      -*)       fail "$E_USAGE" "unknown flag: $1" ;;
      *)        [[ -z "$ref" ]] && ref="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  local usage='usage: 5dive task loop outcome <loop> --cmd="<command that prints one number>" | --clear | --check'
  (( have_cmd + clear + check == 1 )) || fail "$E_USAGE" "$usage"
  local tid tident seat st
  _loop_tpl_resolve "$ref"; tid="$_LOOP_TID"; tident="$_LOOP_TIDENT"
  seat=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${tid};")
  st=$(_loop_pref_get "loop.outcome.${tident}")
  if (( check )); then
    [[ -n "$st" ]] || fail "$E_VALIDATION" "${tident} has no outcome command"
    local reading; reading=$(_loop_outcome_read "$seat" "$(jq -r .cmd <<<"$st")")
    [[ -n "${reading%|*}" ]] || fail "$E_VALIDATION" "the outcome command for ${tident} printed no number (exit ${reading##*|}; it runs as ${seat}, in that seat's home)"
    ok "${tident} outcome now: ${reading%|*}" '{loop:$t, value:($v|tonumber)}' --arg t "$tident" --arg v "${reading%|*}"
    return 0
  fi
  # Whoever sets the command picks code the loop's seat will run, so only that
  # seat, or root, may set or clear it.
  local u; u=$(_loop_seat_user "$seat" 2>/dev/null) || u=""
  [[ "$EUID" == "0" || ( -n "$u" && "$(id -un)" == "$u" ) ]] \
    || fail "$E_PERMISSION" "only ${seat:-its seat} or root may set ${tident}'s outcome command (it runs as that seat)"
  if (( clear )); then
    [[ -n "$st" ]] || fail "$E_VALIDATION" "${tident} has no outcome command"
    _loop_pref_del "loop.outcome.${tident}"
    ok "${tident} is scored by opinion again" '{loop:$t, outcome:null}' --arg t "$tident"
    return 0
  fi
  [[ -n "${cmd//[[:space:]]/}" ]] || fail "$E_VALIDATION" "--cmd is empty"
  local now; now=$(db "SELECT datetime('now');")
  # A changed command is a new measure: a fresh baseline and a fresh 3 days.
  _loop_pref_set "loop.outcome.${tident}" "$(jq -cn --arg c "$cmd" --arg b "$(task_actor "")" --arg n "$now" \
      '{cmd:$c, set_by:$b, set_at:$n, since:$n, best:null}')"
  _loop_pref_del "loop.auto.${tident}"
  ok "${tident} is now scored by its outcome; it pauses if the number has not risen in ${_LOOP_OUTCOME_FLAT_DAYS} days (self-improvement is off)" \
     '{loop:$t, outcome:{cmd:$c}, auto:false}' --arg t "$tident" --arg c "$cmd"
}

# `task loop resume <loop>` — the owner's tap on a paused outcome loop.
_loop_outcome_resume() {  # <template id> <template ident> -> 0 resumed, 1 was not paused
  local tid="$1" tident="$2" st
  st=$(_loop_pref_get "loop.outcome.${tident}")
  [[ -n "$(jq -r '.paused_at // ""' <<<"$st" 2>/dev/null)" ]] || return 1
  db "UPDATE tasks SET parked_at=NULL, park_reason=NULL, wake_at=NULL,
        status=CASE WHEN status='blocked' AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${tid})
                    THEN 'todo' ELSE status END
      WHERE id=${tid} AND status NOT IN ('done','cancelled');"
  _loop_pref_set "loop.outcome.${tident}" "$(jq -c --arg n "$(db "SELECT datetime('now');")" 'del(.paused_at) | .since=$n' <<<"$st")"
}
cmd_task_loop_resume() {
  tasks_db_init
  local tid tident
  _loop_tpl_resolve "${1:-}"; tid="$_LOOP_TID"; tident="$_LOOP_TIDENT"
  _loop_outcome_resume "$tid" "$tident" || fail "$E_VALIDATION" "${tident} is not paused by its outcome"
  ok "resumed ${tident}; it has ${_LOOP_OUTCOME_FLAT_DAYS} days for its number to rise" '{loop:$t, paused:false}' --arg t "$tident"
}

cmd_task_loop() {
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task loop <start|ls> ..."
  local sub="$1"; shift
  case "$sub" in
    start)          cmd_task_loop_start "$@" ;;
    ls|list)        cmd_task_loop_ls "$@" ;;
    score)          cmd_task_loop_score "$@" ;;
    feedback)       cmd_task_loop_feedback "$@" ;;
    rate)           cmd_task_loop_rate "$@" ;;
    scores)         cmd_task_loop_scores "$@" ;;
    review)         cmd_task_loop_review "$@" ;;
    suggest)        cmd_task_loop_suggest "$@" ;;
    apply|dismiss|revert) cmd_task_loop_decide "$sub" "$@" ;;
    auto)           cmd_task_loop_auto "$@" ;;
    outcome)        cmd_task_loop_outcome "$@" ;;
    resume)         cmd_task_loop_resume "$@" ;;
    -h|--help|help) cat <<'HELP'
5dive task loop start --title=<name> --steps=<json>   |   loop ls [--all]
DIVE-5564 loop scores (a loop = a scheduled task):
  loop scores                                   the loops, each with its score and recent runs
  loop score <run> --score=<0-100> [--note=]    override a run's score (the runtime scores every run
                                                itself from signals: errors, unfinished, complaints,
                                                rework; a clean run is 80. DIVE-5815)
  loop feedback <run> --text="<reply>" [--at=]  the owner's reply about a run: a complaint inside 24h
                                                of the run lowers its score, never raises it
  loop rate <run> up|down|clear                 the owner's thumbs; beats the score
  loop review [--force]                         weekly: ask for one change to the lowest-scoring loop
  loop suggest <loop> --body-file=<path> [--reason=]   record suggested instructions
  loop apply|dismiss|revert <loop>              act on the suggestion; revert undoes the last apply
  loop auto <loop> on|off                       self-improvement: apply suggestions unasked (off by default)
DIVE-5777 outcome loops (score by a number, not an opinion):
  loop outcome <loop> --cmd="<command>"         after each run, run it as the loop's seat (in its home);
                                                the ONE number it prints is the run's score. No rise in
                                                3 days: the loop pauses and its lead tells the owner once.
                                                Self-improvement stays off.
  loop outcome <loop> --check | --clear         read the number now | go back to signal scores
  loop resume <loop>                            restart a paused loop with a fresh 3 days (Apply does too)
HELP
    ;;
    *) fail "$E_USAGE" "unknown loop command: $sub (try: start|ls|scores|score|feedback|rate|review|suggest|apply|dismiss|revert|auto|outcome|resume)" ;;
  esac
}

# DIVE-3330: return the binding that makes a verify PASS a grade, not proof that
# the work reached main. This deliberately reuses the merge gate's PR and branch
# discovery helpers. It does not attempt a second ancestry check: a credentialless
# verifier can finish its own job by recording the grade, while `task done` remains
# the one close path that answers the merge question.
_task_verify_merge_binding() {
  local id="$1" ident="$2" body dref branches=""
  dref=$(db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE id=${id};")
  body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
  if [[ -n "$dref" ]]; then
    printf 'delivery_ref %s' "$dref"
  elif _gate_text_names_a_ref "$body"; then
    printf 'a PR named in the body'
  else
    branches=$(_gate_branch_refs_from_text "$body" "$ident" 2>/dev/null | head -3 | paste -sd, -) || branches=""
    # Explicit `return 0`: a trailing `[[ -n ... ]] && printf` supplies this
    # function's exit status, so an empty $branches (no binding — the common,
    # correct case) would make the helper return 1 to every caller.
    if [[ -n "$branches" ]]; then
      printf 'branch(es) named in the body: %s' "$branches"
    fi
  fi
  return 0
}

# _verify_grade_line <delivery_ref> <row_result> <tree_head> — the one line a
# COMMAND grade owes the merge gate, and it is only a STAMP when it is a proof.
#
# WHAT WAS MISSING. A command-graded row (`--review=check`) recorded
# `✅ verify PASS (exit 0): <cmd>` and nothing else, so `_gate_graded_sha` read
# EMPTY off it. `_merge_disp_decide` therefore answered
# `hold:merger:no-graded-sha-stated`, and `task done` refuses a close whose result
# states no `graded-sha` either. So a row that had just PASSED its own acceptance
# command could be closed by nobody: not the grader, not the merge owner, only an
# operator typing the sha in by hand or spending the audited `--no-graded-sha`.
#
# WHAT `graded-sha` MEANS, and why the obvious fix is the wrong one. Its contract
# is stated in `_merge_disp_decide`: a grade is bound to a SHA, not to a pull
# request. So it answers WHICH TREE THIS GRADE EXERCISED. "What was the pull
# request head while the command ran" is a DIFFERENT question, and the two diverge
# the moment a command does not read that head — a grade of `git show
# origin/main:<file>`, run because the work landed by another route, reads a tree
# the pull request head never was. Stamping it from the head would make the gate
# CLEAR on an inference, which inverts the failure direction of a control that
# exists to refuse: today an unstampable grade holds and a person looks, which is
# expensive but safe. (lodar, review on #1001.)
#
# SO THE STAMP IS ISSUED ONLY AGAINST A MATCH. `<tree_head>` is `git rev-parse
# HEAD` in the cwd the verify command ran in. When that tree IS the pull request
# head — prefix comparison, the same rule `_merge_disp_decide` uses — the grade
# demonstrably ran against the thing that would merge, and the sha stamped is the
# TREE's, because the tree is the fact and the head is the corroboration.
#
# EVERY OTHER CASE GETS `graded-head-at:`, a label `_gate_graded_sha` does NOT
# parse. The operator reading the row still gets both shas and can see exactly why
# nothing was stamped; the gate keeps holding. That is the same instinct as the
# no-source line this replaces — an unstamped PASS is indistinguishable from a rail
# that never ran, and the cure for that is legibility, never a looser gate.
#
# THE LABEL MUST NOT PARSE, and that is load-bearing rather than cosmetic: the
# phrase `graded-sha:` never appears in that line, and `(tree graded: <sha>)`
# cannot match either, because the fence wants `graded` + `[-_ ]` + `sha`. The
# harness asserts `_gate_graded_sha` reads EMPTY off both shapes.
_verify_grade_line() {
  local dref="$1" prior="${2:-}" tree="${3:-}" head="" tok line stated="" src=""
  if declare -F _gate_gh >/dev/null 2>&1 && declare -F _gate_gh_token >/dev/null 2>&1; then
    tok=$(_gate_gh_token 2>/dev/null) || tok=""
    head=$(_gate_gh "$tok" 20 pr view "$dref" --json headRefOid -q '.headRefOid' 2>/dev/null) || head=""
  fi
  [[ "$head" =~ ^[0-9a-fA-F]{7,40}$ ]] || head=""
  [[ "$tree" =~ ^[0-9a-fA-F]{7,40}$ ]] || tree=""
  # The maker's stated sha CORROBORATES the tree when gh cannot answer; it never
  # stands in for it. LAST occurrence wins, the same rule `_gate_graded_sha` uses
  # on its own label: a re-delivery prepends the earlier record.
  while IFS= read -r line; do
    if [[ "$line" =~ [Dd][Ee][Ll][Ii][Vv][Ee][Rr][Ee][Dd][-_\ ][Ss][Hh][Aa][[:space:]]*[:=][[:space:]]*([0-9a-fA-F]{7,40}) ]]; then
      stated="${BASH_REMATCH[1]}"
    fi
  done <<<"$prior"
  if [[ -n "$tree" ]]; then
    if [[ -n "$head" && ( "$tree" == "$head"* || "$head" == "$tree"* ) ]]; then
      src="the pull request head, read with gh"
    elif [[ -z "$head" && -n "$stated" && ( "$tree" == "$stated"* || "$stated" == "$tree"* ) ]]; then
      src="the DELIVERED-SHA stated in the delivery record (gh could not read ${dref})"
    fi
  fi
  if [[ -n "$src" ]]; then
    printf 'graded-sha: %s (the tree this grade ran in, and it matches %s)' "${tree,,}" "$src"
    return 0
  fi
  printf 'graded-head-at: %s (tree graded: %s) — this grade did not demonstrably run against that head, so it is NOT a merge-gate stamp and the row keeps holding' \
    "${head:-unreadable}" "${tree:-unreadable}"
}

# DIVE-475: deterministic verify-runner — proven-done, not claimed-done. Run a
# command; its EXIT CODE is the real stop condition. On pass (exit 0), an unbound
# task flips to done; a task carrying a merge binding records a structural grade
# and stays open for `task done` (DIVE-3330). On fail leave status untouched. The verb exits 0 on
# pass / 1 on fail so it can BE a stop condition (heartbeat /goal, scripts) — the
# maker no longer grades itself by asserting status=done (writer != verifier).
# --no-done (alias --check) runs the check and records it WITHOUT flipping.
cmd_task_verify() {
  tasks_db_init
  local task="" cmd="" no_done=0 timeout_s="" prose="" have_prose=0 prose_src="" merge_proof=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cmd=*)      cmd="${1#*=}" ;;
      --no-done|--check) no_done=1 ;;
      # DIVE-3823: RECORD THIS COMMAND AS MERGE EVIDENCE the close gate may read.
      # The merge gate's own no-credential refusal already tells a verifier seat to
      # run `verify --no-done --cmd=<ancestry/grep script>` "whose EXIT STATUS proves
      # the merge" — and then nothing read it, so the row it rescued was closable by
      # nobody (DIVE-3808, merged and stuck). This flag is that reading: it stamps
      # the run structurally against the row's CURRENT delivery binding.
      #
      # Deliberately OPT-IN and not inferred from the command text. Most --cmd runs
      # are acceptance tests, not merge proofs; accepting every passing verify as
      # merge evidence would fail the gate OPEN on every graded row, which is the
      # inverse of the bug. The flag is the caller SAYING which one this is, and it
      # is recorded with the command text and the actor so the claim is readable.
      --merge-proof) merge_proof=1 ;;
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
    || fail "$E_USAGE" "usage: 5dive task verify <id|DIVE-N> [--cmd=\"<command>\"] [--result=\"<prose verdict>\"|--result-file=<path>] [--no-done] [--merge-proof] [--timeout=<seconds>]"
  [[ -z "$timeout_s" || "$timeout_s" =~ ^[1-9][0-9]*$ ]] \
    || fail "$E_VALIDATION" "--timeout must be a positive integer (seconds)"
  resolve_task_id "$task"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  # DIVE-2832: --result is a RECORDING path, never a closing one. A prose verdict is
  # an assertion about work; it is not evidence that anything reached main, and the
  # DIVE-1830 merge gate this verb already bypasses (DIVE-2938) is exactly what would
  # otherwise be riding on it. So --result requires --no-done and says so.
  if (( have_prose )) && (( ! no_done )); then
    fail "$E_USAGE" "--result records a verifier's prose verdict WITHOUT closing, so it requires --no-done (alias --check). A prose PASS asserts the work is good; it is not evidence the work MERGED. To record the grade: 5dive task verify $task --no-done --result=\"<verdict>\". A passing --cmd also records a grade rather than closing whenever the row carries a delivery binding (DIVE-3330); the merge owner then closes through task done after the binding reaches main."
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

  # DIVE-3823: what --merge-proof requires, refused BEFORE the command runs so a
  # caller is never told "it passed but was not recorded" after paying for the run.
  local mp_dref=""
  if (( merge_proof )); then
    (( ran_cmd )) || fail "$E_USAGE" "--merge-proof records the EXIT STATUS of a command as evidence that the delivery landed, so there must be a command to run: pass --cmd=\"<script>\" (e.g. 'git fetch -q origin main && git merge-base --is-ancestor <merge-sha> origin/main && git grep -q <a-symbol-the-PR-added> origin/main -- <path>'). A prose verdict asserts a merge rather than proving one, which is the distinction this flag exists to keep (DIVE-2832)."
    mp_dref=$(db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE id=${id};")
    [[ -n "$mp_dref" ]] || fail "$E_USAGE" "$ident binds NO delivery ref, so there is nothing for --merge-proof to be evidence ABOUT. The proof is recorded against a specific binding and the close gate accepts it only while that binding is still the row's current one. Bind it first: 5dive task deliver $ident --pr=https://github.com/<owner>/<repo>/pull/N"
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
    # A COMMAND GRADE STATES THE SHA IT GRADED — see _verify_grade_line above.
    # Only on a BOUND row: an unbound one has no merge gate to answer and auto-closes
    # here anyway. And never over a claim that is already stated — a verifier who put
    # `graded-sha:` in their own prose has said which sha they graded, and that is
    # theirs to say, not ours to overwrite.
    local _vg_dref _vg_prior _vg_tree
    _vg_dref=$(db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE id=${id};")
    if [[ -n "$_vg_dref" ]] && declare -F _gate_graded_sha >/dev/null 2>&1 \
       && [[ -z "$(_gate_graded_sha "$result_txt")" ]]; then
      # THE TREE THIS GRADE RAN IN — the cwd `bash -c "$cmd"` inherited, read here
      # rather than beside the run only because nothing between the two can move a
      # checkout. Unreadable (not a git tree) is an ANSWER, not an error: it means
      # nothing can be proven, which `_verify_grade_line` renders as a hold.
      _vg_tree=$(git rev-parse HEAD 2>/dev/null) || _vg_tree=""
      _vg_prior=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${id};")
      result_txt="${result_txt}"$'\n'"$(_verify_grade_line "$_vg_dref" "$_vg_prior" "$_vg_tree")"
    fi
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
  # `task verify --cmd=` among its exits. DIVE-3330 corrects that refusal and holds
  # bound rows open, but this result-preservation rail remains independently needed.
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

  # DIVE-3330: the old raw UPDATE below bypassed the DIVE-1830 ancestry gate.
  # DIVE-2832 and DIVE-3098 now provide the rail DIVE-2938 was waiting for: keep
  # a passing, bound row open and stamp the structural grade. This is terminal
  # for the credentialless verifier and renders graded->merge when delivery_ref
  # is present; the merge owner closes later through the gated `task done` path.
  local merge_hold=0 merge_binding=""
  if (( rc == 0 )) && (( ! no_done )) \
      && [[ "$_v_guard_st" != "done" && "$_v_guard_st" != "cancelled" ]]; then
    merge_binding=$(_task_verify_merge_binding "$id" "$ident") || merge_binding=""
    if [[ -n "$merge_binding" ]]; then
      no_done=1
      merge_hold=1
      result_txt="⏸ merge-gate hold (DIVE-3330) — verify evidence recorded, but this row binds ${merge_binding}; the command's exit status does not by itself prove that binding reached main. Row remains open for the merge owner to close through \`task done\`."$'\n'"${result_txt}"
    fi
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
      _five_flush_write_notes   # recorded BEFORE the refusal below, so the note is true
      policy_refuse "$E_CONFLICT" verify-close-over-open-gate DIVE-2196 "$ident" \
        "$ident has a pending '${_vg_t}' gate awaiting a human — the verify verdict is RECORDED, but the auto-close is refused: closing here would drop the human's question out of every open-gate view without anyone answering it, which is DIVE-555's bypass reached by a different verb. Exits: let them answer it ('5dive task answer $ident --value=...'), withdraw it if your result makes it moot ('5dive task need $ident --withdraw'), or re-run with --no-done to record evidence without closing."
    fi
    # DIVE-2015: on an unbound delivered loop, a maker is deliberately ALLOWED to
    # rescue a stalled verifier with `task verify --cmd=...`. A bound delivery has
    # already been diverted to graded->merge by DIVE-3330 above. When the
    # kernel-authenticated caller is the recorded
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
        _five_flush_write_notes   # recorded before the refusal below
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
    # This path also protects already-done rows independent of whether current
    # guidance advertises verify as a closing escape: a repeat must not clobber ACK.
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
    # DIVE-2477: the THIRD close writer. DIVE-2067 taught this lesson one column
    # over — when you guard one verb, ask which OTHERS write the field. A
    # verifier re-verifying their own already-done row (the case DIVE-2067's
    # refusal deliberately allows) refreshed done_at here, same as the close
    # verbs did. COALESCE for the same reason and by the same rule: first close wins.
    db "UPDATE tasks SET status='done', done_at=COALESCE(done_at, datetime('now')), result=$(sqlq "$result_txt") WHERE id=${id};"
    _five_flush_write_notes
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
        _five_flush_write_notes   # the graded write lands here

    # DIVE-4137: RECORD WHO OWES THE MERGE, at the moment the grade is stamped.
    #
    # Until now the board DERIVED that owner per render, as maker_agent, and that
    # is wrong in the common case (measured by main 2026-09-09 across #799, #807,
    # #809 and the frontend #220): the maker has nothing left to do on a branch
    # that is green and clean and merely needs a person's eyes, and waking them
    # costs a full reload of a pull request they had closed out. The disposition
    # (src/task/delivery.sh) answers who owes the LOOK, and the answer is recorded
    # rather than re-derived, so the board renders a decision that was made.
    #
    # BOTH VERIFIER SHAPES REACH HERE, which is why the call site is this one and
    # not the DIVE-3330 divert above: `verify --cmd=<script>` on a bound row is
    # diverted into this else-branch by that divert, and `verify --no-done
    # --result=<prose>` — the shape a credential-less verifier actually uses, and
    # the one that carries the `graded-sha:` line — enters it directly.
    #
    # ONLY ON A PASS, and only with a binding. A FAIL owes the MAKER a fix, not
    # anyone a look, and this must not paint one. Non-fatal by construction: the
    # probe is one read whose every failure mode already returns a hold, and the
    # `|| true` covers a tree that sourced a subset of src/ without delivery.sh.
    if (( rc == 0 )); then
      local _md_dref _md_disp _md_owner _md_why
      local _md_held=0 _md_asg='' _md_landed=0
      _md_dref=$(db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE id=${id};")
      if [[ -n "$_md_dref" ]] && declare -F _merge_disp_probe >/dev/null 2>&1; then
        _md_disp=$(_merge_disp_probe "$_md_dref" "$(_gate_graded_sha "$result_txt")" 2>/dev/null) \
          || _md_disp="hold:merger:disposition-probe-failed"
        # DIVE-4899's rule, applied here too: THE PRIMARY IS NOT THE ROW. A
        # companion bound beside a merged primary that has not landed is still
        # owed a merge, so the row stays a hold for the seat that can give it.
        if [[ "$_md_disp" == "merged" ]] && declare -F _task_companions_unlanded >/dev/null 2>&1 \
           && [[ -n "$(_task_companions_unlanded "$id" 2>/dev/null)" ]]; then
          _md_disp="hold:merger:companion-not-merged"
        fi
        if [[ "$_md_disp" == "merged" ]]; then
          # DIVE-5048: THE PULL REQUEST ALREADY LANDED, so nobody owes a merge and
          # the row gets the close path, not a hold. Before this, GitHub's
          # mergeable=UNKNOWN on a merged pull request became
          # `hold:merger:mergeable-UNKNOWN`: the row went back to todo, was handed
          # to the merge seat, and sat there until a person closed it (DIVE-616 on
          # teal-fox, twice in nine minutes, after the forge poll had ALREADY
          # recorded the landing).
          #
          # THE CLOSE PATH IS `task merge-landed`'s, not a close from here. Record
          # the landing (unless the forge poll or the verb already has — its
          # provenance is not ours to overwrite), retire the hold, and hand the
          # row to the seat whose close is ungated. Deliberately NOT an auto-close:
          # a merged pull request is not a finished row (main2, 2026-09-10;
          # DIVE-4520), a PASS can carry an owed clause, and DIVE-2656's
          # landed-vs-graded comparison lives in `task done`'s gate, not here.
          _md_landed=1
          if [[ "$(db "SELECT 1 FROM tasks WHERE id=${id} AND ${_TASKS_MERGE_LANDED_SQL};" 2>/dev/null)" != "1" ]] \
             && declare -F _task_merge_landed_record >/dev/null 2>&1; then
            local _md_ml="" _md_lsha="" _md_lat=""
            # The sha and mergedAt from the credential-free read `merge-landed`
            # uses. Unreadable is not a veto: the probe above already read MERGED
            # with this seat's token, and the record renders a missing sha as such.
            declare -F _merge_landed_read >/dev/null 2>&1 \
              && { _md_ml=$(_merge_landed_read "$_md_dref" "$(_gate_slug_from_url "$_md_dref" 2>/dev/null || printf '')" 2>/dev/null) || _md_ml=""; }
            [[ -n "$_md_ml" ]] && { _md_lsha="${_md_ml%%|*}"; _md_lat="${_md_ml#*|}"; }
            _task_merge_landed_record "$id" "$_md_lsha" "$_md_lat" "$(task_actor "")" "$_md_dref" || true
          else
            db "UPDATE tasks SET merge_owner=NULL, merge_hold_reason=NULL WHERE id=${id};" || true
          fi
          warn "$ident: ${_md_dref} is ALREADY MERGED — no merge is owed, so no merge hold was recorded and the row was not handed to a merge seat (DIVE-5048). It is owed a CLOSE: \`5dive task done ${ident}\` from the row's verifier, after any clause the PASS verdict left owed."
        elif [[ "$_md_disp" == "merge" ]]; then
          # Auto-mergeable at the graded sha. The MERGE itself is not done here —
          # it belongs to `task done`, where the DIVE-1830 gate can re-derive that
          # it landed and DIVE-2656 can compare what landed against what was
          # graded. Recording the GRADER's name is what turns the board line into
          # an instruction that seat can act on immediately.
          # THE SEAT NAMED HERE MUST BE THE SEAT THE RAIL ACCEPTS, AND IT IS NOT
          # ALWAYS THIS ONE (DIVE-4512). `_task_merge_preflight` keys on
          # `graded_by == actor`, and `graded_by` is COALESCE-frozen at the FIRST
          # grade by the write directly above. Stamping the CURRENT actor agrees
          # with that only while a row is graded ONCE. Graded twice — the default
          # shape of a maker->verifier loop, where a temp grader session records
          # the PASS and the loop's verifier then ACKs it — the two fields cannot
          # agree, and the board prints `run \`5dive task done\`` at a seat the rail
          # refuses BY NAME. `task done` is no escape either: _merge_at_close_do
          # routes the close through the same disposition and reprints the same
          # refusal, so the row has no self-service exit at all. Measured on
          # DIVE-4491 / 5dive-ai/5dive#963: green, clean, 21/21 checks, graded PASS
          # twice, refused to both graded seats.
          #
          # READ THE FROZEN COLUMN, do not widen the rail. The alternative fix —
          # letting any seat that recorded a PASS use the rail — moves DIVE-3474's
          # standing invariant, and that is a separate decision. This one only
          # makes the board name the seat the invariant already blesses.
          #
          # The fallback is the old expression and covers exactly one shape: a
          # tree where the write above did not land a graded_by (a row graded
          # before the column existed, re-graded here). Never a bare set.
          _md_owner=$(db "SELECT COALESCE(NULLIF(graded_by,''),'') FROM tasks WHERE id=${id};")
          [[ -n "$_md_owner" ]] || _md_owner=$(task_actor "")
          # DIVE-4520: THE VERB THIS PRINTS MUST NOT BE THE ONE THAT REVOKES THE
          # STANDING IT JUST STAMPED. `task done` on a loop row does not merge and
          # does not close: it takes the maker->verifier routing fork and
          # re-delivers an UNCHANGED pass at exit 0, which moves
          # handoff_delivered_at past every recorded verdict clock — and
          # `_TASKS_TFV_SQL`'s DIVE-4357 conjunct then reads the row as a delivery
          # the grade did not grade, stripping merge standing from the one seat
          # named on the line above. Measured on DIVE-4491 / 5dive-ai/5dive#963:
          # the board's own instruction is what stalled the row.
          # `5dive task merge <ident>` is the verb the DIVE-3474 rail accepts from
          # exactly this seat. The re-delivery is separately REFUSED at the close
          # (src/task/status.sh, same ticket) so that a hint we do not compose —
          # an older board line, a quoted screenshot, a human — cannot spend it
          # either; this half removes the trigger, that half makes the verb safe.
          #
          # DIVE-4999: AND ONLY WHEN THIS BOX'S MERGE ACCOUNT CAN MERGE IT. The
          # rail merges with the machine account, and on a box where that
          # account is pull-only upstream (or absent) the verb above can only
          # fail — the seats that followed it filed a secret gate for a token
          # nobody would issue and an approval gate to a lead with no rights.
          # Only a measured `push` prints the verb; `unknown` (a failed read, a
          # refused sudo, an older installed binary) fails closed on the HINT
          # and still writes the line, so the board render never waits on it.
          local _md_push="" _md_repo=""
          if declare -F _merge_push_probe >/dev/null 2>&1; then
            _md_push=$(_merge_push_probe "$ident" 2>/dev/null) || _md_push=""
          fi
          [[ "$_md_push" == *" "* ]] && _md_repo="${_md_push#* }"
          case "${_md_push%% *}" in
            push)
              _md_why="auto-mergeable at the graded sha — run \`5dive task merge ${ident}\`" ;;
            pull-only)
              _md_why="mergeable at the graded sha, waiting on the ${_md_repo} maintainer — this box's merge account is pull-only there, so no seat here can merge it" ;;
            no-credential)
              _md_why="mergeable at the graded sha, waiting on the ${_md_repo} maintainer — this box holds no merge account, so no seat here can merge it" ;;
            *)
              _md_why="mergeable at the graded sha, but this box could not confirm its merge account may push to the repo — no merge is suggested until it can" ;;
          esac
        else
          _md_held=1
          _md_owner="${_md_disp#hold:}"; _md_why="${_md_owner#*:}"; _md_owner="${_md_owner%%:*}"
          # `maker` is a ROLE in the disposition's vocabulary, resolved to a seat
          # only here, where the row is in hand.
          [[ "$_md_owner" == "maker" ]] \
            && _md_owner=$(db "SELECT COALESCE(NULLIF(maker_agent,''), COALESCE(assignee,'')) FROM tasks WHERE id=${id};")
          # `merger` is the other ROLE (DIVE-4326). The probe resolves it to a
          # seat itself, because it is the half that knows the repo; this is the
          # net for the one disposition the probe cannot produce — its own
          # failure, above — and for any tree that called the pure decider directly.
          # DIVE-4571: and it can resolve to NOBODY — `ops` and the `main`
          # fallback are both names that exist on one box. The old `|| printf
          # 'main'` (and the `${_md_owner:-main}` below it) stamped that name
          # anyway, so a customer box recorded a merge_owner the roster has
          # never heard of: a row assigned on its face and dispatchable to no
          # one. Degrade to the seat the row GUARANTEES instead.
          if [[ "$_md_owner" == "merger" ]]; then
            _md_owner=$(_merge_hold_seat '' 2>/dev/null) || _md_owner=""
            if [[ -z "$_md_owner" ]]; then
              _md_owner=$(db "SELECT COALESCE(NULLIF(maker_agent,''), COALESCE(assignee,'')) FROM tasks WHERE id=${id};")
              _md_why="${_md_why}-no-merge-seat"
            fi
          fi
        fi
        # An EMPTY owner is left empty, never backfilled with a seat name:
        # `_tasks_merge_owner_sql` COALESCEs '' to maker_agent and then to the
        # assignee, so the render degrades to a seat that exists rather than to
        # a constant that may not (DIVE-4571).
        # A LANDED row (DIVE-5048) is owed no merge, so it gets no owner written.
        (( _md_landed )) || db "UPDATE tasks SET merge_owner=$(sqlq "${_md_owner:-}"),
               merge_hold_reason=$(sqlq "$_md_why")
            WHERE id=${id};" || true
        # ---- upstream #1009: A HELD ROW MUST LAND SOMEWHERE, NOT JUST BE LABELLED ----
        #
        # Writing `merge_owner` named the seat that owed the merge and dispatched
        # the row to NOBODY. Both pickers missed it: the assignee arm because the
        # assignee is the grading seat (increasingly an ephemeral pool clone that
        # is already gone), and the merge-owner arm at `cmd_heartbeat.sh:2097` —
        # which exists for exactly this row and is correct — because the enclosing
        # `WHERE t.status='todo'` filtered the row out one line earlier. The
        # grading session STARTED the row and was torn down without resetting it,
        # so it sat at `in_progress` looking like work in flight. Measured by the
        # maintainer: six rows graded ACCEPT, five with their pull requests
        # already merged, ages up to three days.
        #
        # (1) THE STATUS PAIR IS THE OPERATIVE HALF, and it is unconditional.
        # `status='todo', started_at=NULL` is the pair `_hb_reclaim` already
        # writes (`cmd_heartbeat.sh:2868`) and it restores the invariant
        # `cmd_heartbeat.sh:5541` states outright: a delivered maker->verifier row
        # sits at todo. With the row back at todo the merge-owner arm at :2097
        # reaches it ON ITS OWN — that arm keys on `merge_owner`, not on the
        # assignee — so acceptance 1 needs no ownership change at all, and the
        # claim at `:2766` (which re-asserts `status='todo'`) keeps working
        # unmodified.
        #
        # (2) THE HELD ROW ENDS UP WITH ONE OWNER, NOT TWO. DIVE-4604 measured
        # the narrower rule — move the assignee only when that seat is GONE —
        # leaving the stranding in place on a live box: 2026-09-19, DIVE-4574
        # (assignee `main`, live) and DIVE-4632 (assignee `quinn`, live) were both
        # back at `in_progress` with `merge_owner=ops`, and `task doctor` called
        # both undispatchable. The status half above is necessary and not
        # sufficient, because it only holds until something claims the row again:
        # every OTHER dispatch path keys on the ASSIGNEE, not on `merge_owner` —
        # the loop-defect forced wake (`forced wake of quinn onto DIVE-4632:
        # stage_owner=quinn`), a goal wake, a hand `task assign`. The picker's
        # merge-owner arm is the only reader of `merge_owner` there is, so one
        # claim by the old assignee puts the row at `in_progress` and hides it
        # from that arm again, permanently. Leaving two owners on one row is the
        # confusion the filing named in as many words.
        #
        # HAND IT OVER ONLY TO A SEAT THE HEARTBEAT WAKES, ON POSITIVE KNOWLEDGE.
        # `_task_merge_hold_owner_takes_it` says yes only when the roster READ
        # and carries that owner with a heartbeat. When it cannot be read the
        # pre-DIVE-4604 rule stands unchanged — move only a seat that is provably
        # gone — so an unreadable registry can never route a row onto a name
        # nothing iterates, the failure DIVE-4571 removed and DIVE-4220 before it,
        # and the A7 arm holds either way.
        #
        # DEGRADE, NEVER GUESS: if the roster cannot be read, the assignee is left
        # alone. An unreadable registry is not evidence that a seat is gone, and
        # the status half above already restores dispatch either way. Same posture
        # as `task doctor`'s lane check, which skips rather than calling every
        # lane dead when the roster is unknown.
        db "UPDATE tasks
               SET status='todo',
                   started_at=NULL,
                   updated_at=datetime('now')
             WHERE id=${id}
               AND status NOT IN ('done','cancelled');" || true
        _md_asg=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${id};")
        if (( ${_md_held:-0} )) && [[ -n "${_md_owner:-}" && "$_md_asg" != "$_md_owner" ]] \
           && { _task_merge_hold_owner_takes_it "$_md_owner" || _task_seat_is_gone "$_md_asg"; }; then
          db "UPDATE tasks
                 SET assignee=$(sqlq "$_md_owner"),
                     updated_at=datetime('now')
               WHERE id=${id}
                 AND status NOT IN ('done','cancelled');" || true
          _task_store_audit_log "task.merge-hold-reassigned" ok 0 -- \
            "$ident" "from=${_md_asg:-<none>} to=$_md_owner reason=$_md_why"
          warn "$ident: held for merge — handed from '${_md_asg:-<none>}' to '${_md_owner}', the seat that owes the merge."
        fi
        # DIVE-5048: a landed row goes where `task merge-landed` puts it — the
        # verifier, whose close is ungated on a loop row. A no-op when it is
        # already there, which is the common case (the grader IS the verifier).
        if (( _md_landed )) && declare -F _task_merge_landed_handoff >/dev/null 2>&1; then
          local _md_vf _md_mv
          _md_vf=$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${id};")
          _md_mv=$(_task_merge_landed_handoff "$id" "$ident" "$_md_asg" "$_md_vf" 2>/dev/null) || _md_mv=""
          [[ -n "$_md_mv" ]] && warn "$ident:${_md_mv}"
        fi
      fi
    fi
  fi

  # DIVE-3823: stamp the proof. AFTER the verdict write above, and only on a PASS —
  # a FAILING command is evidence the delivery did NOT land, and recording it as a
  # proof would hand the gate the opposite of what it asked for.
  #
  # BARE SET, not COALESCE (graded_verdict's rule, not graded_at's): this is CURRENT
  # STATE about one binding. A row re-pointed to a different PR and re-proved must
  # overwrite, or the second proof could never replace the first — and the gate's
  # equality test against the live delivery_ref is what makes a stale proof inert
  # rather than dangerous.
  if (( merge_proof )); then
    if (( rc == 0 )); then
      db "UPDATE tasks SET merge_proof_at=datetime('now'),
             merge_proof_by=$(sqlq "$(task_actor "")"),
             merge_proof_ref=$(sqlq "$mp_dref"),
             merge_proof_cmd=$(sqlq "$cmd")
          WHERE id=${id};"
      _task_store_audit_log "task.merge-proof" ok 0 -- \
        "$ident" "ref=$mp_dref" "by=$(task_actor "")" "cmd=$cmd"
      warn "$ident: merge proof RECORDED against ${mp_dref} by $(task_actor "") — \`task done\` may now close this row from a seat that holds no gh credential (DIVE-3823, audited). Re-point the binding and this proof stops counting."
    else
      warn "$ident: --merge-proof was given but the command FAILED (exit ${rc}) — nothing recorded. A failing proof is evidence the delivery did not land, not evidence that it did."
    fi
  fi


  # ── DIVE-4322: A GRADE ENDS AT THE VERDICT, NOT AT THE CLOSE ────────────────
  #
  # The pool's concurrency cap counted a grade as "in flight" from
  # `task.grade.spawned` until the ROW closed (`task.done`/`task.rejected`). But
  # a PASS on a bound row does not close here — DIVE-3330 deliberately holds it
  # open as graded->merge, and the close then waits on a human's merge and the
  # grader's own `task done`, which is hours. Measured 2026-09-11: two rows
  # parked on main's merge (one PR unmergeable, one merged with the close still
  # owed) held both slots of a --cap=2 lane for three hours and starved 19 queued
  # grades while the pool seat's heartbeat read "no todo — stay idle".
  #
  # So the ledger needs the event the lane actually wants to key on: the moment a
  # verdict is STORED. Emitted from here, after both branches have written it,
  # because this function is the only writer of graded_verdict and both shapes a
  # grader uses reach it — the `--no-done --result=` prose grade and the passing
  # `--cmd` that DIVE-3330 diverts into the same else-branch.
  #
  # BOTH VERDICTS, and the flipped close too. A FAIL is just as much an end of
  # grading as a PASS (the maker owes the next iteration, not the pool), and the
  # auto-close above reaches `status='done'` by RAW UPDATE, so it emits no
  # `task.done` at all — an unbound row closed by `verify --cmd=true` held a slot
  # forever on the old query. One emit at the one place covers all three.
  #
  # AN EXPLICIT CLOCK-NONCE IDEM KEY, for policy_refuse's reason: a re-grade
  # after a reject is a genuinely second event, and the derived key digests the
  # payload — two identical FAIL verdicts on one ident would collapse into one
  # row, and the lane would then read the re-spawned grade as still in flight
  # forever. Never fatal: `ledger_emit` swallows its own failure, and a verdict
  # that is already durably stored must not be undone by a bookkeeping write.
  # HOISTED out of the ledger branch below so the AUDIT row and the LEDGER event
  # report the same sha. Read once, used twice: a reader comparing the two must
  # never be able to find them disagreeing about the same verdict.
  local _g_sha=""
  declare -F _gate_graded_sha >/dev/null 2>&1 \
    && _g_sha=$(_gate_graded_sha "$result_txt" 2>/dev/null || printf '')
  if declare -F ledger_emit >/dev/null 2>&1; then
    ledger_emit task.graded ident="$ident" task_id="$id" actor="$(task_actor "")" \
      idem="task.graded:${ident}:$(date +%s%N 2>/dev/null || echo $$)" \
      detail="verdict=${verdict} sha=${_g_sha:-unknown} closed=${flipped} merge-hold=${merge_hold}"
  fi
  # And the AUDIT row, carrying the same fields. The ledger event and the audit
  # log are different readers: the ledger is the pool's in-flight lane (it keys on
  # this event to free a slot), the audit log is the fleet trail a person reads
  # when asking who graded what. A verdict stored with a lifecycle event but no
  # audit row is exactly the `deliver` gap one verb over. Not conditional on
  # ledger_emit being defined — the trail must not go quiet because the ledger is
  # absent.
  _task_store_audit_log "task.graded" ok 0 -- "$ident" "verdict=$verdict" \
    "sha=${_g_sha:-unknown}" "closed=$flipped" "merge-hold=$merge_hold"

  if (( JSON_MODE )); then
    printf '%s' "$result_txt" | jq -R -s \
      --arg i "$id" --arg id "$ident" --arg v "$verdict" --argjson rc "$rc" \
      --argjson flipped "$([[ $flipped -eq 1 ]] && echo true || echo false)" \
      --argjson held "$([[ $merge_hold -eq 1 ]] && echo true || echo false)" \
      '{ok:true, data:{id:($i|tonumber), ident:$id, verdict:$v, exit:$rc, flippedToDone:$flipped, mergeHeld:$held, output:.}}'
  else
    printf '%s\n' "$result_txt" >&2
    if (( rc == 0 )); then
      # Three EXCLUSIVE branches. A bare `A && B || C && D || E` chain cannot
      # express that: bash groups it left-to-right, so with flipped=1 the first
      # ok() returns 0, the `||` short-circuits past the merge_hold test, and the
      # 'merge still owed' message runs unconditionally — telling the operator a
      # merge is owed on the unbound row that binds nothing (main, iteration 1).
      if (( flipped )); then
        ok "$ident verify PASS — marked done"
      elif (( merge_hold )); then
        ok "$ident verify PASS — graded; merge still owed"
      else
        ok "$ident verify PASS (status unchanged, --no-done)"
      fi
    else
      warn "$ident verify FAIL (exit $rc) — status unchanged"
      # A FAIL VERDICT IS A REPORTED OUTCOME, NOT A SILENT DEATH. `warn` does not
      # set the reported flag (only `fail` does), so the DIVE-2598 backstop on the
      # EXIT trap saw a non-zero exit with nothing claimed and printed "5dive task
      # exited 1 without reporting a reason. This is a bug in the CLI, not a
      # refusal … Please file it: 5dive bug." over a grade that had just been
      # recorded correctly on the row. The exit status stays 1 so a shell caller
      # can still branch on the verdict; only the false crash report goes.
      mark_reported
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
  # DIVE-3932: same end boundary as a park, reached by the dependency-edge door.
  # `task block --by` also writes status directly rather than through the status
  # funnel, so the funnel's `blocked` arm never sees it.
  _run_close_for_task "$tid" parked task_blocked || true
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
  # DIVE-3932: a park is an END BOUNDARY for the attempt — the row stops moving
  # and nobody is working it. Hooked HERE and not only in the status funnel
  # because park writes `status='blocked'` with its own UPDATE and never crosses
  # that funnel; a run left open by this path would sit in `run metrics` as
  # "stuck (>6h, no close)" forever, reporting a wedged fleet where the fleet
  # correctly deferred work. PARKED, never failed: a deliberate hold is neither a
  # success nor a failure and must be scored as neither.
  _run_close_for_task "$tid" parked task_parked || true
  # DIVE-2410: park clears the gate columns, so whatever button that gate put in a
  # human's chat now points at a question the task no longer holds.
  _task_gate_card_apply "$tident" die "parked" || true
  # DIVE-2877: A PARK'S BLAST RADIUS EXCEEDS THE ROW IT IS APPLIED TO, and until
  # now nothing said so at the moment of the park. On an instance materialized
  # from a recurring template (from_template_id set) a park is not a delay of one
  # row — it is a stop of the whole beat, with no catch-up:
  #
  #   - the materializer dedups on `status NOT IN ('done','cancelled')`
  #     (_hb_materialize_recurring, src/cmd_heartbeat.sh) and a park sets
  #     status='blocked', so the parked instance HOLDS the template's only open
  #     slot. Every occurrence inside the park window is DROPPED, not deferred —
  #     DIVE-5218's catch-up covers only minutes NO pass evaluated, never a
  #     slot the dedup skipped.
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
