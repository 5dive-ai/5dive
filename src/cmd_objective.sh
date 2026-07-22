
# -------- objectives (OSS-19 outcome loops, OSS-26 phase A1) --------
#
# An objective is a standing goal bound to a READ-ONLY metric command: the
# company steers a single number toward a target. See
# community/wiki/outcome-loops-design-jul11.md.
#
# This build is MEASUREMENT ONLY (phase A1): store + readings + digest block +
# a `tick` that runs the metric and appends a reading. There is NO origination
# and NO planner cycle here — that is the successor build (blocked on this one).
#
# The anti-Goodhart core, enforced from day one: the metric command is run ONLY
# by `objective tick` and the digest. A planner NEVER runs, computes, or owns
# the metric — it will only ever receive the readings this module records. The
# append-only objective_readings table is the audit trail (a failed metric-cmd
# writes value=NULL + rc!=0 so it shows as a visible gap, never a silent skip).
#
# Same group-writable store as tasks (lib/tasks_db.sh); read/write, no root/lock.

cmd_objective() {
  local sub="${1:-ls}"; shift || true
  case "$sub" in
    add|new)          cmd_objective_add "$@" ;;
    ls|list)          cmd_objective_ls "$@" ;;
    show|view)        cmd_objective_show "$@" ;;
    status|dash|dashboard) cmd_objective_status "$@" ;;
    pause)            cmd_objective_setstatus paused "$@" ;;
    resume)           cmd_objective_setstatus active "$@" ;;
    shadow)           cmd_objective_setmode shadow "$@" ;;
    live)             cmd_objective_setmode live "$@" ;;
    rm|remove|delete) cmd_objective_rm "$@" ;;
    tick)             cmd_objective_tick "$@" ;;
    replan|cycle|re-plan) cmd_objective_replan "$@" ;;
    *) fail "$E_USAGE" "unknown objective command: $sub (add|ls|show|status|pause|resume|shadow|live|rm|tick|replan)" ;;
  esac
}

# name slug: printable, non-empty, no leading/trailing space; kept liberal (it's
# a human label, UNIQUE-enforced by the schema) but bounded so it stays a handle.
valid_objective_name() { [[ -n "$1" && ${#1} -le 120 && "$1" != *$'\n'* ]]; }
_is_number()           { [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }

# Resolve an objective name (or numeric id) into OBJECTIVE_ID + OBJECTIVE_NAME,
# or fail. Sets globals so `fail`'s exit runs in the caller (not a $() subshell).
_objective_resolve() {
  local ref="$1" row
  [[ -n "$ref" ]] || fail "$E_USAGE" "objective name required"
  if [[ "$ref" =~ ^[0-9]+$ ]]; then
    row=$(db "SELECT id||'|'||name FROM objectives WHERE id=$(sqlq "$ref");")
  else
    row=$(db "SELECT id||'|'||name FROM objectives WHERE name=$(sqlq "$ref");")
  fi
  [[ -n "$row" ]] || fail "$E_NOT_FOUND" "no such objective: $ref"
  OBJECTIVE_ID="${row%%|*}"; OBJECTIVE_NAME="${row#*|}"
}

# Run a metric command under the read-only contract: stdout -> ONE number. Echoes
# "<value>|<rc>". value is empty when the command failed OR its first stdout line
# isn't a number (rc forced to 1 so the reading records the failure honestly).
_objective_metric_run() {
  local cmd="$1" out rc first
  out=$(bash -c "$cmd" 2>/dev/null); rc=$?
  first=$(printf '%s\n' "$out" | head -n1)
  # trim surrounding whitespace
  first="${first#"${first%%[![:space:]]*}"}"; first="${first%"${first##*[![:space:]]}"}"
  if [[ $rc -eq 0 ]] && _is_number "$first"; then
    printf '%s|0' "$first"
  else
    [[ $rc -eq 0 ]] && rc=1
    printf '|%s' "$rc"
  fi
}

cmd_objective_add() {
  tasks_db_init
  local metric="" target="" direction="up" unit="" review="" planner=""
  local project="" maxnew="3" budget="" public="0" run_mode="live"
  local -a words=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --metric-cmd=*)        metric="${1#*=}" ;;
      --target=*)            target="${1#*=}" ;;
      --direction=*)         direction="${1#*=}" ;;
      --unit=*)              unit="${1#*=}" ;;
      --review=*)            review="${1#*=}" ;;
      --planner=*)           planner="${1#*=}" ;;
      --project=*)           project="${1#*=}" ;;
      --max-new-per-cycle=*) maxnew="${1#*=}" ;;
      --budget=*)            budget="${1#*=}" ;;
      --run-mode=*)          run_mode="${1#*=}" ;;
      --shadow)              run_mode="shadow" ;;   # OSS-27/OSS-35 shadow-first
      --public)              public="1" ;;
      -*)                    fail "$E_USAGE" "unknown flag: $1" ;;
      *)                     words+=("$1") ;;
    esac
    shift
  done
  case "$run_mode" in live|shadow) ;; *) fail "$E_VALIDATION" "bad --run-mode '$run_mode' (live|shadow)" ;; esac
  local name="${words[*]:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" 'usage: 5dive objective add "<name>" --metric-cmd="<cmd>" --target=<n> [--direction=up|down] [--unit=%] [--review="<cron>"] [--planner=<a>] [--project=<key>] [--max-new-per-cycle=N] [--budget=<tok>] [--public]'
  valid_objective_name "$name" || fail "$E_VALIDATION" "bad name (non-empty, <=120 chars, no newlines)"
  [[ -n "$metric" ]] || fail "$E_VALIDATION" "--metric-cmd is required (read-only command whose stdout is one number)"
  case "$direction" in up|down) ;; *) fail "$E_VALIDATION" "bad --direction '$direction' (up|down)" ;; esac
  [[ -z "$target" ]]  || _is_number "$target" || fail "$E_VALIDATION" "--target must be a number"
  [[ -z "$budget" ]]  || _is_number "$budget" || fail "$E_VALIDATION" "--budget must be a number (tokens)"
  [[ "$maxnew" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "--max-new-per-cycle must be a non-negative integer"
  if [[ -n "$project" ]]; then
    project="${project,,}"
    [[ "$(db "SELECT 1 FROM projects WHERE key=$(sqlq "$project");")" == "1" ]] \
      || fail "$E_NOT_FOUND" "no such project: $project"
  fi
  [[ "$(db "SELECT 1 FROM objectives WHERE name=$(sqlq "$name");")" == "1" ]] \
    && fail "$E_CONFLICT" "objective '$name' already exists"

  local by; by="$(auto_sender_from_sudo 2>/dev/null || true)"; [[ -n "$by" ]] || by="${USER:-unknown}"
  db "INSERT INTO objectives
        (name, metric_cmd, target, direction, unit, review, planner, project_key,
         max_new_per_cycle, budget, public, run_mode, created_by)
      VALUES ($(sqlq "$name"), $(sqlq "$metric"), $(sqlq_or_null "$target"),
              $(sqlq "$direction"), $(sqlq_or_null "$unit"), $(sqlq_or_null "$review"),
              $(sqlq_or_null "$planner"), $(sqlq_or_null "$project"),
              $maxnew, $(sqlq_or_null "$budget"), $public, $(sqlq "$run_mode"), $(sqlq "$by"));"

  ok "objective '$name' created (${direction} to ${target:-?}${unit:-}) — take first reading: 5dive objective tick \"$name\"" \
     '{name:$n, direction:$d, target:$t, unit:$u, public:($p=="1")}' \
     --arg n "$name" --arg d "$direction" --arg t "${target:-}" --arg u "${unit:-}" --arg p "$public"
}

cmd_objective_ls() {
  tasks_db_init
  if (( JSON_MODE )); then
    # Attach the latest reading (value + ts) per objective, plus the company-view
    # fields (DIVE-1452): planner, replan cadence (review cron), per-cycle cap, and
    # verified_total — originated tasks a DISTINCT verifier accepted across ALL
    # cycles (status='done'), the same integrity rule as `status`'s per-cycle count
    # but unbounded by cycle. Never the planner's self-reported cycle outcome.
    local rows
    rows=$(dbfmt -json "
      SELECT o.id, o.name, o.metric_cmd, o.target, o.direction, o.unit, o.public,
             o.status, o.project_key, o.planner, o.review, o.max_new_per_cycle,
             o.created_at,
             (SELECT value FROM objective_readings r WHERE r.objective_id=o.id ORDER BY r.id DESC LIMIT 1) AS current,
             (SELECT ts    FROM objective_readings r WHERE r.objective_id=o.id ORDER BY r.id DESC LIMIT 1) AS current_ts,
             (SELECT COUNT(*) FROM tasks t WHERE t.originated_by_objective=o.id AND t.status='done') AS verified_total
      FROM objectives o ORDER BY o.created_at;")
    [[ -n "$rows" ]] || rows="[]"
    printf '%s' "$rows" | jq -c '{ok:true, data:{objectives:(map(.public=(.public==1)))}}'
    return
  fi
  local n; n=$(db "SELECT COUNT(*) FROM objectives;")
  if [[ "$n" == "0" ]]; then
    echo "no objectives yet — add one: 5dive objective add \"<name>\" --metric-cmd=… --target=…"
    return
  fi
  dbfmt -box "
    SELECT o.name AS name,
           o.direction AS dir,
           COALESCE(printf('%g', (SELECT value FROM objective_readings r WHERE r.objective_id=o.id ORDER BY r.id DESC LIMIT 1)), '-') AS current,
           COALESCE(printf('%g', o.target), '-') || COALESCE(o.unit,'') AS target,
           o.status AS status,
           CASE o.public WHEN 1 THEN 'yes' ELSE 'no' END AS public,
           COALESCE(o.project_key, '-') AS project
    FROM objectives o ORDER BY o.created_at;"
}

cmd_objective_show() {
  tasks_db_init
  local ref="${1:-}"
  [[ -n "$ref" ]] || fail "$E_USAGE" "usage: 5dive objective show <name>"
  _objective_resolve "$ref"

  # current + previous readings for the trend, and inflight open tasks in the
  # linked project (no origination yet, so this is 0 unless the project is used
  # for other work — kept honest, not synthesized).
  local cur prev trend inflight
  cur=$(db "SELECT value FROM objective_readings WHERE objective_id=$OBJECTIVE_ID AND value IS NOT NULL ORDER BY id DESC LIMIT 1;")
  prev=$(db "SELECT value FROM objective_readings WHERE objective_id=$OBJECTIVE_ID AND value IS NOT NULL ORDER BY id DESC LIMIT 1 OFFSET 1;")
  trend=$(_objective_trend "$cur" "$prev")
  inflight=$(db "SELECT COUNT(*) FROM tasks t JOIN objectives o ON o.id=$OBJECTIVE_ID
                 WHERE o.project_key IS NOT NULL AND t.project_key=o.project_key
                   AND t.kind='standard' AND t.status NOT IN ('done','cancelled');")

  if (( JSON_MODE )); then
    dbfmt -json "SELECT * FROM objectives WHERE id=$OBJECTIVE_ID;" \
      | jq -c --arg cur "${cur:-}" --arg trend "$trend" --argjson inflight "${inflight:-0}" \
          '{ok:true, data:{objective:(.[0] + {public:(.[0].public==1),
             current:(if $cur=="" then null else ($cur|tonumber) end),
             trend:$trend, inflight:$inflight})}}'
    # readings are shown in text mode; JSON callers can pull them via a follow-up
    # if needed — kept out of the summary to keep this shape small.
    return
  fi
  dbfmt -line "SELECT name, metric_cmd, target, direction, unit, review, planner,
                      project_key, max_new_per_cycle, budget, public, status,
                      created_by, created_at FROM objectives WHERE id=$OBJECTIVE_ID;"
  printf '\ncurrent: %s%s   trend: %s   inflight: %s\n' \
    "${cur:-—}" "$( [[ -n "$cur" ]] && db "SELECT COALESCE(unit,'') FROM objectives WHERE id=$OBJECTIVE_ID;")" \
    "$trend" "${inflight:-0}"
  printf '\nrecent readings (newest first):\n'
  dbfmt -box "SELECT ts, COALESCE(printf('%g', value), '(failed)') AS value, rc
              FROM objective_readings WHERE objective_id=$OBJECTIVE_ID
              ORDER BY id DESC LIMIT 12;" 2>/dev/null || echo "  (none yet)"
}

# OSS-32 — one inspectable status surface for a running self-steering loop.
# READ-ONLY: renders stored objective + readings + cycle + originated-task state.
# It NEVER runs the metric-cmd and NEVER originates/mutates. The integrity point:
# "verified this cycle" counts only originated tasks a DISTINCT verifier accepted
# (status='done'), NEVER the planner cycle's self-described `outcome` — the
# company cannot fake its own progress. All fields source from the OSS-26 store
# (objectives/objective_readings) + the OSS-27 store (objective_cycles +
# tasks.originated_by_objective/originated_cycle).
cmd_objective_status() {
  tasks_db_init
  local ref="${1:-}"
  [[ -n "$ref" ]] || fail "$E_USAGE" "usage: 5dive objective status <name>"
  _objective_resolve "$ref"
  local obj_id="$OBJECTIVE_ID" oname="$OBJECTIVE_NAME"

  # --- objective config ---
  local o_status o_target o_dir o_unit o_planner o_budget o_runmode
  o_status=$(db  "SELECT status FROM objectives WHERE id=$obj_id;")
  o_target=$(db  "SELECT COALESCE(target,'') FROM objectives WHERE id=$obj_id;")
  o_dir=$(db     "SELECT direction FROM objectives WHERE id=$obj_id;")
  o_unit=$(db    "SELECT COALESCE(unit,'') FROM objectives WHERE id=$obj_id;")
  o_planner=$(db "SELECT COALESCE(planner,'') FROM objectives WHERE id=$obj_id;")
  o_budget=$(db  "SELECT COALESCE(budget,'') FROM objectives WHERE id=$obj_id;")
  o_runmode=$(db "SELECT COALESCE(run_mode,'live') FROM objectives WHERE id=$obj_id;")

  # --- (1-3) current / trend / gap (signed by direction; <=0 means target met) ---
  local cur prev trend gap=""
  cur=$(db  "SELECT value FROM objective_readings WHERE objective_id=$obj_id AND value IS NOT NULL ORDER BY id DESC LIMIT 1;")
  prev=$(db "SELECT value FROM objective_readings WHERE objective_id=$obj_id AND value IS NOT NULL ORDER BY id DESC LIMIT 1 OFFSET 1;")
  trend=$(_objective_trend "$cur" "$prev")
  if [[ -n "$o_target" && -n "$cur" ]]; then
    gap=$(awk -v c="$cur" -v t="$o_target" -v d="$o_dir" 'BEGIN{ if(d=="down") printf "%g", c-t; else printf "%g", t-c }')
  fi

  # --- (5) current cycle = MAX(cycle_no) + its outcome ---
  local cyc cyc_outcome
  cyc=$(db "SELECT COALESCE(MAX(cycle_no),0) FROM objective_cycles WHERE objective_id=$obj_id;")
  cyc_outcome=$(db "SELECT COALESCE(outcome,'') FROM objective_cycles WHERE objective_id=$obj_id AND cycle_no=$cyc;")

  # --- (4) active roles = distinct assignee of OPEN originated tasks (+ planner) ---
  local roles
  roles=$(db "SELECT COALESCE(assignee,'(unassigned)') FROM tasks
              WHERE originated_by_objective=$obj_id AND status NOT IN ('done','cancelled')
              GROUP BY assignee ORDER BY assignee;")

  # --- (6) verified outcomes THIS cycle: originated + this cycle + verifier-accepted (done) ---
  # done => a DISTINCT verifier accepted (existing maker/verifier loop). This is
  # the integrity-critical field — never the planner cycle's self-reported outcome.
  # verified_this_cycle RESETS each cycle (anti-Goodhart: a steady cycle honestly
  # reads 0); verified_total is the cumulative lifetime tally so a steady cycle is
  # never a silent blank about prior real progress (DIVE-1441).
  local verified verified_total originated_open
  verified=$(db "SELECT COUNT(*) FROM tasks
                 WHERE originated_by_objective=$obj_id AND originated_cycle=$cyc AND status='done';")
  verified_total=$(db "SELECT COUNT(*) FROM tasks
                 WHERE originated_by_objective=$obj_id AND status='done';")
  originated_open=$(db "SELECT COUNT(*) FROM tasks
                 WHERE originated_by_objective=$obj_id AND status NOT IN ('done','cancelled');")

  # --- (7) spend vs ceiling ---
  local spent
  spent=$(db "SELECT COALESCE(SUM(tokens_spent),0) FROM objective_cycles WHERE objective_id=$obj_id;")

  # --- (8) next gate = latest gated cycle whose anchor task is STILL a pending gate ---
  local gate_anchor="" next_gate="none"
  gate_anchor=$(db "SELECT gate_anchor FROM objective_cycles
                    WHERE objective_id=$obj_id AND gated=1 AND gate_anchor IS NOT NULL
                    ORDER BY cycle_no DESC LIMIT 1;")
  if [[ -n "$gate_anchor" ]]; then
    local pending
    pending=$(db "SELECT COUNT(*) FROM tasks
                  WHERE ident=$(sqlq "$gate_anchor")
                    AND need_type IS NOT NULL AND need_answered_at IS NULL
                    AND status NOT IN ('done','cancelled');")
    [[ "$pending" == "1" ]] && next_gate="$gate_anchor"
  fi
  # No pending gate -> surface the stop-reason from the latest cycle outcome, so a
  # halted loop is never a silent blank (mirrors replan's terminal outcomes).
  local stop_reason=""
  if [[ "$next_gate" == "none" ]]; then
    case "$cyc_outcome" in
      target_reached|budget_exhausted) stop_reason="$cyc_outcome" ;;
      *) [[ "$o_status" != "active" ]] && stop_reason="$o_status" ;;
    esac
  fi

  if (( JSON_MODE )); then
    local roles_json; roles_json=$(printf '%s\n' "$roles" | jq -R . | jq -sc 'map(select(length>0))')
    jq -cn \
      --arg name "$oname" --arg status "$o_status" --arg mode "$o_runmode" \
      --arg dir "$o_dir" --arg unit "$o_unit" --arg planner "$o_planner" \
      --arg cur "$cur" --arg target "$o_target" --arg gap "$gap" --arg trend "$trend" \
      --argjson cyc "${cyc:-0}" --arg cyc_outcome "$cyc_outcome" \
      --argjson roles "$roles_json" \
      --argjson verified "${verified:-0}" --argjson verified_total "${verified_total:-0}" --argjson open "${originated_open:-0}" \
      --argjson spent "${spent:-0}" --arg budget "$o_budget" --argjson ceiling "$OBJ_CEILING_DEFAULT" \
      --arg next_gate "$next_gate" --arg stop_reason "$stop_reason" \
      '{ok:true, data:{objective:$name, status:$status, mode:$mode,
        target:(if $target=="" then null else ($target|tonumber) end), direction:$dir, unit:$unit,
        current:(if $cur=="" then null else ($cur|tonumber) end),
        gap:(if $gap=="" then null else ($gap|tonumber) end), trend:$trend,
        planner:(if $planner=="" then null else $planner end),
        active_roles:$roles, cycle:$cyc, cycle_outcome:(if $cyc_outcome=="" then null else $cyc_outcome end),
        verified_this_cycle:$verified, verified_total:$verified_total, originated_open:$open,
        spend:$spent, budget:(if $budget=="" then null else ($budget|tonumber) end),
        ceiling_per_cycle:$ceiling,
        next_gate:(if $next_gate=="none" then null else $next_gate end),
        stop_reason:(if $stop_reason=="" then null else $stop_reason end)}}'
    return
  fi

  # ---- text dashboard ----
  # %g normalizes REAL columns (10.0 -> 10), matching the `show`/`ls` renders.
  local t_disp c_disp g_disp
  t_disp=$( [[ -n "$o_target" ]] && printf '%g' "$o_target" || printf '—' )
  c_disp=$( [[ -n "$cur" ]]      && printf '%g' "$cur"      || printf '—' )
  g_disp=$( [[ -n "$gap" ]]      && printf '%g' "$gap"      || printf '—' )
  local spend_of; spend_of="${o_budget:-∞}"
  local roles_line; roles_line=$(printf '%s' "$roles" | paste -sd', ' -); [[ -n "$roles_line" ]] || roles_line="—"
  local gate_line="$next_gate"
  [[ "$next_gate" == "none" && -n "$stop_reason" ]] && gate_line="none (stopped: $stop_reason)"
  printf 'objective: %s   status: %s   mode: %s\n' "$oname" "$o_status" "$o_runmode"
  printf 'target:    %s%s (%s)\n' "$t_disp" "$o_unit" "$o_dir"
  printf 'current:   %s%s   trend: %s   gap: %s%s\n' \
    "$c_disp" "$( [[ -n "$cur" ]] && printf '%s' "$o_unit")" "$trend" \
    "$g_disp" "$( [[ -n "$gap" ]] && printf '%s' "$o_unit")"
  printf 'cycle:     #%s   outcome: %s\n' "${cyc:-0}" "${cyc_outcome:-—}"
  printf 'roles:     %s%s\n' "$roles_line" "$( [[ -n "$o_planner" ]] && printf '   (planner: %s)' "$o_planner")"
  printf 'verified this cycle: %s   (total: %s, originated open: %s)\n' "${verified:-0}" "${verified_total:-0}" "${originated_open:-0}"
  printf 'spend:     %s / %s tok   (ceiling %s/cycle)\n' "${spent:-0}" "$spend_of" "$OBJ_CEILING_DEFAULT"
  printf 'next gate: %s\n' "$gate_line"
}

# trend from the two most recent successful readings: up|down|flat|new
_objective_trend() {
  local cur="$1" prev="$2"
  [[ -n "$cur" ]] || { printf 'none'; return; }
  [[ -n "$prev" ]] || { printf 'new'; return; }
  awk -v c="$cur" -v p="$prev" 'BEGIN{ if (c>p) print "up"; else if (c<p) print "down"; else print "flat" }'
}

cmd_objective_setstatus() {
  local status="$1"; shift
  tasks_db_init
  local ref="" force=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1 ;;
      -*)      fail "$E_USAGE" "unknown flag: $1" ;;
      *)       [[ -z "$ref" ]] && ref="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$ref" ]] || fail "$E_USAGE" "usage: 5dive objective ${status/active/resume} <name> [--force]"
  _objective_resolve "$ref"
  # OSS-33 PREFLIGHT: refuse to RESUME (status->active) a loop whose planner role
  # cannot do the work — an explicit, reasoned refusal (never a silent no-op start).
  # --force overrides for a deliberate human who knows the gap (e.g. wiring an org
  # up next). Pausing is always allowed.
  if [[ "$status" == "active" && -z "$force" ]]; then
    if ! _objective_preflight "$OBJECTIVE_ID" "$OBJECTIVE_NAME"; then
      if (( JSON_MODE )); then
        fail "$E_CONFLICT" "preflight failed (${PREFLIGHT_REASON}): ${PREFLIGHT_DETAIL} — fix it or resume --force"
      else
        fail "$E_CONFLICT" "objective '$OBJECTIVE_NAME' preflight failed [${PREFLIGHT_REASON}]: ${PREFLIGHT_DETAIL}
  fix the gap, or force it (deliberate): 5dive objective resume \"$OBJECTIVE_NAME\" --force"
      fi
    fi
  fi
  db "UPDATE objectives SET status=$(sqlq "$status"), updated_at=datetime('now') WHERE id=$OBJECTIVE_ID;"
  local note=""; [[ "$status" == "active" && -n "$PREFLIGHT_DETAIL" && -z "$PREFLIGHT_REASON" ]] && note=" (${PREFLIGHT_DETAIL})"
  ok "objective '$OBJECTIVE_NAME' -> ${status}${note}" '{name:$n, status:$s}' --arg n "$OBJECTIVE_NAME" --arg s "$status"
}

# OSS-27/OSS-35 shadow-first: flip an objective's run mode. shadow => every
# re-plan cycle is PROPOSE-ONLY (the whole diff rides a gate, nothing auto-applies,
# --yes cannot waive it); live => the default (origination still gates, but the
# objective's own-task reprioritize/cancel apply within its autonomy).
cmd_objective_setmode() {
  local mode="$1"; shift
  tasks_db_init
  local ref="${1:-}"
  [[ -n "$ref" ]] || fail "$E_USAGE" "usage: 5dive objective ${mode} <name>"
  _objective_resolve "$ref"
  db "UPDATE objectives SET run_mode=$(sqlq "$mode"), updated_at=datetime('now') WHERE id=$OBJECTIVE_ID;"
  local note; [[ "$mode" == "shadow" ]] && note=" — re-plan cycles now PROPOSE-ONLY (every change gated, nothing auto-applies)" || note=" — re-plan cycles apply own-task changes directly again (origination still gates)"
  ok "objective '$OBJECTIVE_NAME' run mode -> ${mode}${note}" '{name:$n, run_mode:$m}' --arg n "$OBJECTIVE_NAME" --arg m "$mode"
}

cmd_objective_rm() {
  tasks_db_init
  local ref="${1:-}"
  [[ -n "$ref" ]] || fail "$E_USAGE" "usage: 5dive objective rm <name>"
  _objective_resolve "$ref"
  # readings cascade via the FK (foreign_keys=ON in db()).
  db "DELETE FROM objectives WHERE id=$OBJECTIVE_ID;"
  ok "objective '$OBJECTIVE_NAME' removed (readings deleted)" '{name:$n, removed:true}' --arg n "$OBJECTIVE_NAME"
}

# Run the metric for one objective (by name/id) or ALL active objectives, append
# a reading each. This is one of only two callers allowed to run the metric (the
# other is the digest). Cron-wirable: `5dive objective tick`.
cmd_objective_tick() {
  tasks_db_init
  local ref="${1:-}"
  local ids
  if [[ -n "$ref" ]]; then
    _objective_resolve "$ref"; ids="$OBJECTIVE_ID"
  else
    ids=$(db "SELECT id FROM objectives WHERE status='active' ORDER BY id;")
  fi
  [[ -n "$ids" ]] || { ok "no active objectives to tick" '{ticked:0}'; return; }

  local id cmd res value rc name ticked=0
  local -a results=()
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    cmd=$(db "SELECT metric_cmd FROM objectives WHERE id=$id;")
    name=$(db "SELECT name FROM objectives WHERE id=$id;")
    res=$(_objective_metric_run "$cmd")
    value="${res%%|*}"; rc="${res#*|}"
    db "INSERT INTO objective_readings (objective_id, value, rc)
        VALUES ($id, $(sqlq_or_null "$value"), $rc);"
    ticked=$((ticked+1))
    if (( JSON_MODE )); then
      results+=("$(jq -cn --arg n "$name" --arg v "$value" --argjson rc "$rc" \
        '{name:$n, value:(if $v=="" then null else ($v|tonumber) end), rc:$rc, ok:($rc==0)}')")
    else
      if [[ "$rc" == "0" ]]; then
        step "objective '$name': $value"
      else
        warn "objective '$name': metric failed (rc=$rc) — recorded as gap"
      fi
    fi
  done <<< "$ids"

  if (( JSON_MODE )); then
    printf '%s\n' "$(printf '%s\n' "${results[@]}" | jq -sc '{ok:true, data:{ticked:length, readings:.}}')"
  else
    ok "ticked $ticked objective(s)"
  fi
}

# ============ OSS-27: the objective re-plan cycle (OSS-19 phase A2, DIVE-982) ============
#
# `5dive objective replan <name>` is the standing planner cycle — the recurring
# tick (a DIVE-1059-shaped template assigned to the objective's planner, woken by
# the heartbeat) that finally closes the outcome loop. Each cycle the planner
# reads the metric reading + trend + target gap + its own open originated tasks +
# last-cycle outcomes (all INJECTED — it never runs the metric), then emits a
# BOUNDED, schema-validated DIFF that deterministic code validates and applies.
#
# The anti-Goodhart spine (all enforced HERE, never trusted from the planner) is
# inherited WHOLESALE from cmd_goal.sh — originated tasks ride the EXACT goal
# materialize path:
#   - create ops are wrapped into a goal-plan and run through _goal_validate_plan
#     (max_new_per_cycle cap = reject-not-truncate, tier-lowering guard via the
#     shared _gate_tier2_floor_hit classifier, DAG acyclicity/depth, assignability)
#     then _goal_materialize (task add per node + block per edge).
#   - ONE count-checkpoint decision gate per origination batch (phase A default
#     checkpoint=0 => ANY origination gates; --yes waives ONLY the count check).
#   - a T2 create ALWAYS gates at HARD tier 2 (never --yes-waived, never
#     auto-cleared) and is built only via `objective replan --from-gate=<id>` on a
#     HUMAN 'approve' (re-validated from scratch).
#   - reprioritize / cancel are HARD-restricted to tasks THIS objective originated
#     (originated_by_objective = its id): a planner can never touch a human or
#     other-objective task — that stays impossible in code, not merely discouraged.
# Stop-conditions are explicit + audited (never a silent stall): paused,
# target-reached, and budget-exhausted each record a cycle with a clear reason and
# originate nothing. Every cycle appends an objective_cycles row (the audit trail).

OBJ_CHECKPOINT_DEFAULT=0     # phase A: ANY origination rides ONE count-checkpoint gate
OBJ_DEPTH_CAP_DEFAULT=5      # inherited dep-DAG depth cap
OBJ_CEILING_DEFAULT=40000    # planner token budget per cycle
OBJ_PLANNER_WAIT_DEFAULT=150 # in-window bound (same rationale as the goal planner, DIVE-1349)

# ---- diff schema (planner structured output; three OPTIONAL arrays) ----
_objective_diff_schema() {
  cat <<'SCHEMA'
{"type":"object","properties":{
  "create":{"type":"array","items":{"type":"object",
    "required":["local_id","title","assignee_or_role"],"properties":{
      "local_id":{"type":"string"},"title":{"type":"string"},"body":{"type":"string"},
      "assignee_or_role":{"type":"string"},
      "priority":{"type":"string","enum":["low","medium","high","urgent"]},
      "acceptance":{"type":"string"},"verify":{"type":"string"},"verifier":{"type":"string"},
      "depends_on":{"type":"array","items":{"type":"string"}},
      "risk":{"type":"string","enum":["low","spend","publish","secret","destructive","brand"]}}}},
  "reprioritize":{"type":"array","items":{"type":"object","required":["ident","priority"],
    "properties":{"ident":{"type":"string"},
      "priority":{"type":"string","enum":["low","medium","high","urgent"]}}}},
  "cancel":{"type":"array","items":{"type":"object","required":["ident"],
    "properties":{"ident":{"type":"string"},"reason":{"type":"string"}}}}}}
SCHEMA
}

# DIVE-1551: loop spawn --schema is prompt guidance, NOT a hard-enforced
# structured-output contract, so a planner routinely emits the create key as `id`
# instead of the schema's `local_id` — which then crashes _goal_validate_plan
# ("every task needs a non-empty local_id") on EVERY create-bearing cycle. Coerce
# id->local_id per create item when local_id is absent/blank, BEFORE validate/apply.
# A diff already carrying local_id (or invalid JSON) is returned byte-untouched so
# validate still emits its own precise error.
_objective_normalize_diff() {
  local norm
  norm=$(printf '%s' "$1" | jq -c '
    if (.create|type)=="array" then
      .create |= map(if type=="object" and ((.local_id // "")=="") and ((.id // "")!="") then .local_id = .id else . end)
    else . end' 2>/dev/null) && [[ -n "$norm" ]] && { printf '%s' "$norm"; return; }
  printf '%s' "$1"
}

# _objective_owns_open <obj_id> <ident> -> 0 iff <ident> is an OPEN task this
# objective originated. The ownership invariant behind reprioritize/cancel.
_objective_owns_open() {
  [[ "$(db "SELECT COUNT(*) FROM tasks WHERE ident=$(sqlq "$2") AND originated_by_objective=${1} AND status NOT IN ('done','cancelled');")" == "1" ]]
}

# target met? up => cur>=target; down => cur<=target.
_objective_target_met() {
  awk -v c="$1" -v t="$2" -v d="$3" 'BEGIN{ if (d=="down") exit !(c<=t); else exit !(c>=t) }'
}

# ============ OSS-33: preflight + explicit stop-conditions (OSS-31 MVP 4 & 5) ============
#
# A self-steering loop must never START or RESUME against a role that cannot do
# the work, and must never STOP without a stated reason. OSS-27 already closes the
# cycle and records the terminal reasons paused / target_reached / budget_exhausted;
# OSS-33 adds the missing guards: a PREFLIGHT that refuses resume/drive when the
# planner role is unassigned / not-in-org / asleep / over-budget / has no distinct
# verifier, and two more explicit stops — a pending Tier-2 HARD GATE (wait, don't
# re-plan on top of it) and NO-PROGRESS after N cycles (pause + explain, never a
# silent spin). Every guard carries a machine reason + a human detail.
#
# Preflight is deliberately CONSERVATIVE: a bare box with no org chart and no
# configured planner is "not yet org-wired" (single-operator / manual), not a
# misconfig, so it PASSES with an advisory. Preflight only REFUSES when it can
# positively see a broken role — it never false-fails an unconfigured objective.
OBJ_NOPROGRESS_DEFAULT=3   # consecutive no-improvement cycles before the loop stops (0=off)

PREFLIGHT_REASON="" PREFLIGHT_DETAIL="" PREFLIGHT_PLANNER=""
# _objective_preflight <obj_id> <oname> -> 0 ok (PREFLIGHT_PLANNER set) / 1 refuse
# (PREFLIGHT_REASON machine slug + PREFLIGHT_DETAIL human line set). Never silent.
_objective_preflight() {
  local obj_id="$1" oname="$2"
  PREFLIGHT_REASON="" PREFLIGHT_DETAIL="" PREFLIGHT_PLANNER=""
  local planner budget spent orgn
  planner=$(db "SELECT COALESCE(planner,'') FROM objectives WHERE id=$obj_id;")
  [[ -n "$planner" ]] || planner=$(_task_resolve_coordinator)
  orgn=$(db "SELECT COUNT(*) FROM agents_org;")

  # over-budget: checkable with no org — a spent-out objective can't drive at all.
  budget=$(db "SELECT COALESCE(budget,'') FROM objectives WHERE id=$obj_id;")
  spent=$(db "SELECT COALESCE(SUM(tokens_spent),0) FROM objective_cycles WHERE objective_id=$obj_id;")
  if [[ -n "$budget" ]] && awk -v s="$spent" -v b="$budget" 'BEGIN{exit !(s>=b)}'; then
    PREFLIGHT_REASON="over_budget"
    PREFLIGHT_DETAIL="spent ${spent} >= budget ${budget} tokens — raise --budget before driving again"
    return 1
  fi

  # Bare box (no org chart AND no derivable planner): not yet org-wired, nothing to
  # assert -> PASS with an advisory. Single-operator / manual case; never false-fail.
  if [[ "$orgn" == "0" && -z "$planner" ]]; then
    PREFLIGHT_PLANNER=""
    PREFLIGHT_DETAIL="no org chart or planner configured — running unconfigured (no role to preflight)"
    return 0
  fi

  # A planner is expected now (org exists or one is configured) but none resolved.
  if [[ -z "$planner" ]]; then
    PREFLIGHT_REASON="role_unassigned"
    PREFLIGHT_DETAIL="no planner set and no org coordinator to plan with — set one (objective ... --planner=<agent>) or assign a coordinator (5dive org)"
    return 1
  fi
  PREFLIGHT_PLANNER="$planner"

  if [[ "$orgn" -gt 0 ]]; then
    # Distinct verifier: a non-trivial originated task closes only on a grader who
    # is NOT the maker. If the whole org is just the planner, nothing this loop
    # builds could ever be verified -> refuse.
    local others; others=$(db "SELECT COUNT(*) FROM agents_org WHERE name<>$(sqlq "$planner");")
    if [[ "$others" -lt 1 ]]; then
      PREFLIGHT_REASON="missing_verifier"
      PREFLIGHT_DETAIL="planner '$planner' is the only agent in the org — a distinct verifier is required to grade originated work (add a teammate: 5dive org add)"
      return 1
    fi
    # Planner must actually be assigned in the org, not a dangling name.
    if [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE name=$(sqlq "$planner");")" == "0" ]]; then
      PREFLIGHT_REASON="role_unreachable"
      PREFLIGHT_DETAIL="planner '$planner' is not in the org chart — assign it (5dive org add '$planner') or point --planner at a listed agent"
      return 1
    fi
  fi

  # Best-effort liveness from the agent registry (root-owned; may be unreadable to
  # a group agent -> we DEGRADE to a pass rather than false-fail). A deliberately
  # stopped unit (desiredState=stopped) reads as ASLEEP.
  local reg; reg=$(registry_read 2>/dev/null || echo '{"agents":{}}')
  if [[ -n "$(jq -r --arg n "$planner" '.agents[$n] // empty' <<<"$reg" 2>/dev/null)" ]]; then
    local dstate; dstate=$(jq -r --arg n "$planner" '.agents[$n].desiredState // ""' <<<"$reg" 2>/dev/null)
    if [[ "$dstate" == "stopped" ]]; then
      PREFLIGHT_REASON="role_asleep"
      PREFLIGHT_DETAIL="planner '$planner' is stopped (desiredState=stopped) — start it: 5dive agent start '$planner'"
      return 1
    fi
    # Unauthenticated: the registry entry exists but carries NO auth profile and NO
    # rotation accounts to draw from -> the planner runtime can't make a model call.
    # Conservative: fires only when BOTH are clearly empty (a BYO/self-authed agent
    # that keeps creds out of band still has an authProfile or rotation entry).
    local authp nrot
    authp=$(jq -r  --arg n "$planner" '.agents[$n].authProfile // ""' <<<"$reg" 2>/dev/null)
    nrot=$(jq -r   --arg n "$planner" '(.agents[$n].rotation.accounts // [])|length' <<<"$reg" 2>/dev/null)
    if [[ -z "$authp" && "${nrot:-0}" == "0" ]]; then
      PREFLIGHT_REASON="role_unauthenticated"
      PREFLIGHT_DETAIL="planner '$planner' has no auth profile or rotation account — authenticate it (5dive account) before it can plan"
      return 1
    fi
  fi
  return 0
}

# no-progress stop: the metric has not moved favorably across the last N cycles.
# _objective_no_progress <obj_id> <direction> <limit> -> 0 STOP (no progress) /
# 1 keep going (progress, or not enough history yet, or disabled). Compares the
# newest cycle reading to the reading N cycles earlier over cycles that recorded a
# numeric reading — a flat/adverse window means the loop is spending without
# steering the number and should pause for a human, not spin silently.
_objective_no_progress() {
  local obj_id="$1" dir="$2" lim="$3"
  [[ "$lim" =~ ^[0-9]+$ && "$lim" -gt 0 ]] || return 1
  local vals n
  vals=$(db "SELECT reading_value FROM objective_cycles WHERE objective_id=$obj_id AND reading_value IS NOT NULL ORDER BY id DESC LIMIT $lim;")
  n=$(printf '%s\n' "$vals" | grep -c .)
  [[ "$n" -ge "$lim" ]] || return 1         # need at least lim recorded readings to judge
  local newest oldest stop
  newest=$(printf '%s\n' "$vals" | head -n1)
  oldest=$(printf '%s\n' "$vals" | sed -n "${lim}p")
  stop=$(awk -v a="$oldest" -v b="$newest" -v d="$dir" 'BEGIN{ imp=(d=="down")?(b<a):(b>a); print (imp?0:1) }')
  [[ "$stop" == "1" ]]
}

# Is there a still-pending approval gate this objective already filed in a prior
# cycle? Echoes "<ident>|<tier>" (empty if none). ANY unresolved own-gate — a
# Tier-2 HARD gate awaiting a human, OR a Tier-1 count-checkpoint awaiting a
# lead/precedent clear — means the loop must WAIT: planning again would stack a
# fresh proposal on top of one still awaiting a decision. (Tier is reported so the
# caller can name a hard gate specifically; the gate's filed tier is decided by
# cmd_task_need's own risk classifier, so detection must not hinge on it.)
_objective_pending_gate() {
  local obj_id="$1"
  db "SELECT c.gate_anchor||'|'||COALESCE(t.tier,0) FROM objective_cycles c JOIN tasks t ON t.ident=c.gate_anchor
      WHERE c.objective_id=$obj_id AND c.gate_anchor IS NOT NULL
        AND t.need_type IS NOT NULL AND t.need_answered_at IS NULL
        AND t.status NOT IN ('done','cancelled')
      ORDER BY c.id DESC LIMIT 1;"
}

# Derive + create a project for an objective that has none, and link it. Echoes
# the pkey. Originated tasks need a home + ident namespace.
_objective_ensure_project() {
  local obj_id="$1" oname="$2" planner="$3" pkey pprefix
  pkey=$(printf '%s' "$oname" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-20 | sed -E 's/-+$//')
  [[ "$pkey" =~ ^[a-z] ]] || pkey="obj-${pkey}"
  valid_project_key "$pkey" || pkey="obj-${obj_id}"
  [[ "$(db "SELECT 1 FROM projects WHERE key=$(sqlq "$pkey");")" == "1" ]] && pkey="obj-${obj_id}"
  pprefix=$(printf '%s' "$pkey" | tr -cd '[:alpha:]' | tr '[:lower:]' '[:upper:]' | cut -c1-5); [[ -n "$pprefix" ]] || pprefix="OBJ"
  pprefix=$(_goal_free_prefix "$pprefix")
  JSON_MODE=1 cmd_project_add "$pkey" --prefix="$pprefix" --name="$oname" --goal="objective: $oname" \
    ${planner:+--lead-agent="$planner"} >/dev/null 2>&1 || true
  db "UPDATE objectives SET project_key=$(sqlq "$pkey"), updated_at=datetime('now') WHERE id=${obj_id};"
  printf '%s' "$pkey"
}

# Append one objective_cycles audit row.
# _objective_record_cycle <obj_id> <cycle_no> <reading> <proposed> <applied> <reprioritized> <cancelled> <gated> <gate_anchor> <tokens> <outcome> [planner_loop_id] [planner_task_id]
# DIVE-1737: the trailing planner_loop_id/planner_task_id are OPTIONAL — set only
# on an 'awaiting_planner' row so the heartbeat reconciler can find the backing
# loop/task; every other outcome passes 11 args and stores NULL for both.
_objective_record_cycle() {
  db "INSERT INTO objective_cycles
        (objective_id, cycle_no, reading_value, proposed, applied, reprioritized, cancelled, gated, gate_anchor, tokens_spent, outcome, planner_loop_id, planner_task_id)
      VALUES (${1}, ${2}, $(sqlq_or_null "$3"), ${4}, ${5}, ${6}, ${7}, ${8}, $(sqlq_or_null "$9"), ${10}, $(sqlq "${11}"), $(sqlq_or_null "${12:-}"), $(sqlq_or_null "${13:-}"));"
}

# ---- diff validation (creates via goal guardrails; reprioritize/cancel own-only) ----
# Sets OBJ_N_CREATE/REPRI/CANCEL + (via _goal_validate_plan) GOAL_HAS_T2, GOAL_TASK_COUNT, GOAL_CRIT_PATH.
OBJ_N_CREATE=0 OBJ_N_REPRI=0 OBJ_N_CANCEL=0
_objective_validate_diff() {
  local diff="$1" obj_id="$2" oname="$3" max_new="$4" depth_cap="$5"
  printf '%s' "$diff" | jq -e . >/dev/null 2>&1 || fail "$E_VALIDATION" "diff is not valid JSON"
  printf '%s' "$diff" | jq -e 'type=="object"' >/dev/null 2>&1 || fail "$E_VALIDATION" "diff must be a JSON object"
  local ncre nrep ncan
  ncre=$(printf '%s' "$diff" | jq '(.create // [])|length')
  nrep=$(printf '%s' "$diff" | jq '(.reprioritize // [])|length')
  ncan=$(printf '%s' "$diff" | jq '(.cancel // [])|length')

  GOAL_TASK_COUNT=0 GOAL_HAS_T2=0 GOAL_CRIT_PATH=0
  if [[ "$ncre" -gt 0 ]]; then
    # Wrap creates into a goal-plan and run ALL goal guardrails WHOLESALE. The
    # cap passed as max_tasks IS max_new_per_cycle (reject-not-truncate).
    local plan; plan=$(printf '%s' "$diff" | jq -c --arg n "$oname" \
      '{project:{name:$n, goal:("objective: "+$n)}, tasks:.create}')
    _goal_validate_plan "$plan" "$max_new" "$depth_cap"
  fi

  local i ident prio
  for ((i=0; i<nrep; i++)); do
    ident=$(printf '%s' "$diff" | jq -r ".reprioritize[$i].ident")
    prio=$(printf '%s' "$diff"  | jq -r ".reprioritize[$i].priority")
    [[ "$prio" =~ ^(low|medium|high|urgent)$ ]] || fail "$E_VALIDATION" "reprioritize $ident: bad priority '$prio' (low|medium|high|urgent)"
    _objective_owns_open "$obj_id" "$ident" \
      || fail "$E_VALIDATION" "reprioritize $ident: not an OPEN task this objective originated — a planner may reprioritize ONLY its own originated tasks"
  done
  for ((i=0; i<ncan; i++)); do
    ident=$(printf '%s' "$diff" | jq -r ".cancel[$i].ident")
    _objective_owns_open "$obj_id" "$ident" \
      || fail "$E_VALIDATION" "cancel $ident: not an OPEN task this objective originated — a planner may propose-cancel ONLY its own originated tasks (touching human/other tasks stays a gate)"
  done
  OBJ_N_CREATE="$ncre" OBJ_N_REPRI="$nrep" OBJ_N_CANCEL="$ncan"
}

# ---- planner invocation (loop spawn --wait --schema; captures tokensSpent) ----
# DIVE-1737: on a non-'done' loop (timeout/escalated past the wait window) this no
# longer hard-fails. The backing planner task SURVIVES and typically completes
# minutes-to-an-hour later (the real planner run far outlasts OBJ_PLANNER_WAIT_DEFAULT);
# we expose loopId/taskId/status so the caller records an 'awaiting_planner' cycle
# and the heartbeat reconciler pulls the late diff → the existing --diff path.
# Results land in globals (NOT stdout) so the caller must NOT wrap this in a
# command substitution — $(...) would run it in a subshell and the loop/task/
# status stamps (needed to record the awaiting_planner cycle) would be lost.
OBJ_PLANNER_TOKENS=0 OBJ_PLANNER_LOOP_ID="" OBJ_PLANNER_TASK_ID="" OBJ_PLANNER_STATUS="" OBJ_PLANNER_DIFF=""
_objective_invoke_planner() {
  local contract="$1" planner="$2" ceiling="$3" wait_secs="$4"
  local schema; schema=$(_objective_diff_schema)
  local spawn_json
  spawn_json=$(JSON_MODE=1 cmd_loop_spawn --role=worker --agent="$planner" \
                 --prompt="$contract" --schema="$schema" --ceiling="$ceiling" --wait="$wait_secs") || return $?
  local status result
  status=$(printf '%s' "$spawn_json" | jq -r '.data.status // ""')
  result=$(printf '%s' "$spawn_json" | jq -r '.data.result // ""')
  OBJ_PLANNER_TOKENS=$(printf '%s' "$spawn_json" | jq -r '.data.tokensSpent // 0')
  OBJ_PLANNER_LOOP_ID=$(printf '%s' "$spawn_json" | jq -r '.data.loopId // ""')
  OBJ_PLANNER_TASK_ID=$(printf '%s' "$spawn_json" | jq -r '.data.taskId // ""')
  OBJ_PLANNER_STATUS="$status"
  OBJ_PLANNER_DIFF=""
  # Not done => planner still working; leave the diff empty and let the caller
  # hand off to the reconciler. Only a done-but-empty result is a genuine error.
  [[ "$status" == "done" ]] || return 0
  [[ -n "$result" ]] || fail "$E_GENERIC" "planner returned an empty diff"
  OBJ_PLANNER_DIFF="$result"
}

# ---- injected-context contract ----
_objective_build_contract() {
  local oname="$1" obj_id="$2" cur="$3" prev="$4" trend="$5" target="$6" direction="$7" unit="$8" max_new="$9"
  local gap="n/a"; [[ -n "$target" && -n "$cur" ]] && gap=$(awk -v t="$target" -v c="$cur" 'BEGIN{printf "%g", t-c}')
  local open_tasks; open_tasks=$(db "SELECT '  ['||ident||']  ('||status||', '||priority||')  '||title FROM tasks WHERE originated_by_objective=${obj_id} AND status NOT IN ('done','cancelled') ORDER BY id;")
  [[ -n "$open_tasks" ]] || open_tasks="  (none yet)"
  local last_out; last_out=$(db "SELECT '  ['||ident||']  '||status||COALESCE('  — '||NULLIF(result,''),'') FROM tasks WHERE originated_by_objective=${obj_id} AND status IN ('done','cancelled') ORDER BY id DESC LIMIT 12;")
  [[ -n "$last_out" ]] || last_out="  (none yet)"
  local roster; roster=$(_goal_roster)
  cat <<PROMPT
You are the PLANNER for a standing company OBJECTIVE. Each cycle you read the
objective's latest metric reading and its originated work, then emit a small
DIFF that steers the metric toward its target. You do NOT run or compute the
metric — it is measured for you, and only verifier-accepted closes count as
real progress (your own narration never does).

OBJECTIVE: ${oname}
  direction: ${direction} to target ${target:-?}${unit}
  latest reading: ${cur:-none}    previous: ${prev:-none}    trend: ${trend}    gap to target: ${gap}

YOUR OPEN ORIGINATED TASKS (only these are yours to reprioritize/cancel):
${open_tasks}

RECENT CLOSED ORIGINATED OUTCOMES:
${last_out}

Return ONLY a JSON object matching the schema. All three arrays are OPTIONAL —
an empty diff (steady) is a valid plan; fewer, higher-leverage changes are better.
- create: up to ${max_new} NEW tasks that move the metric. Each has a plan-local
  id in a field named exactly "local_id" (e.g. "t1","t2" — NOT "id"), a title, an
  optional body, an assignee_or_role (a literal agent
  name from the roster OR "role:<role>"), optional depends_on, and an HONEST risk
  (low|spend|publish|secret|destructive|brand). Anything touching money, public
  posts, secrets, destructive or brand actions is NOT low — you CANNOT lower a
  task's tier by mislabeling it; a mislabeled task is rejected outright. Roster:
${roster}
- reprioritize: [{ident, priority}] — YOUR open originated tasks only.
- cancel: [{ident, reason}] — YOUR open originated tasks only.
PROMPT
}

# ---- file the ONE count-checkpoint gate carrying the diff ----
OBJ_GATE_ANCHOR=""
_objective_file_gate() {
  local obj_id="$1" oname="$2" pkey="$3" cycle_no="$4" diff="$5" from="$6"
  local title="Replan: ${oname} #${cycle_no}"
  local anchor_id anchor_ident
  anchor_id=$(db "SELECT id FROM tasks WHERE project_key=$(sqlq "$pkey") AND title=$(sqlq "$title") AND kind='standard' ORDER BY id LIMIT 1;")
  if [[ -z "$anchor_id" ]]; then
    local add_json
    add_json=$(JSON_MODE=1 cmd_task_add --project="$pkey" --priority=high ${from:+--from="$from"} \
                 --body="$(printf 'Objective re-plan cycle %s for "%s".\nProposed diff — create:%s reprioritize:%s cancel:%s. Approve to apply the origination batch.\n\n--- objective diff json ---\n%s' \
                           "$cycle_no" "$oname" "$OBJ_N_CREATE" "$OBJ_N_REPRI" "$OBJ_N_CANCEL" "$diff")" \
                 -- "$title") || return $?
    anchor_id=$(printf '%s' "$add_json" | jq -r '.data.id')
    anchor_ident=$(printf '%s' "$add_json" | jq -r '.data.ident')
  else
    anchor_ident=$(db "SELECT ident FROM tasks WHERE id=${anchor_id};")
  fi
  # T2 create -> HARD tier-2 gate (never --yes-waived, never auto-cleared). Else a
  # count-only checkpoint stays the default agent-clearable tier-1 decision.
  local reason="create ${OBJ_N_CREATE}, reprioritize ${OBJ_N_REPRI}, cancel ${OBJ_N_CANCEL}"; local -a tier_arg=()
  if [[ "$GOAL_HAS_T2" == "1" ]]; then reason="carries a Tier-2 task — ${reason}"; tier_arg=(--tier=2); fi
  JSON_MODE=1 cmd_task_need "$anchor_id" --type=decision --options="approve|revise" --recommend="approve" "${tier_arg[@]}" ${from:+--from="$from"} \
    --ask="Approve objective '${oname}' re-plan cycle ${cycle_no}? (${reason}) Full diff in the task body." >/dev/null \
    || fail "$E_GENERIC" "objective replan: could not file the plan gate"
  OBJ_GATE_ANCHOR="$anchor_ident"
}

# ---- apply the diff (materialize creates + stamp provenance; reprioritize; cancel) ----
OBJ_APPLIED_CREATE=0 OBJ_APPLIED_REPRI=0 OBJ_APPLIED_CANCEL=0 OBJ_CREATED_IDENTS=""
_objective_apply_diff() {
  local diff="$1" obj_id="$2" pkey="$3" cycle_no="$4" from="$5"
  OBJ_APPLIED_CREATE=0 OBJ_APPLIED_REPRI=0 OBJ_APPLIED_CANCEL=0 OBJ_CREATED_IDENTS=""
  local ncre; ncre=$(printf '%s' "$diff" | jq '(.create // [])|length')
  if [[ "$ncre" -gt 0 ]]; then
    local plan; plan=$(printf '%s' "$diff" | jq -c --arg n "obj-${obj_id}" '{project:{name:$n, goal:$n}, tasks:.create}')
    _goal_materialize "$plan" "$pkey" "$from"    # sets GOAL_CREATED_IDENTS
    OBJ_CREATED_IDENTS="$GOAL_CREATED_IDENTS"
    local id
    for id in $GOAL_CREATED_IDENTS; do
      db "UPDATE tasks SET originated_by_objective=${obj_id}, originated_cycle=${cycle_no} WHERE ident=$(sqlq "$id");"
    done
    OBJ_APPLIED_CREATE=$(printf '%s' "$GOAL_CREATED_IDENTS" | wc -w | tr -d ' ')
  fi
  local i ident prio reason nrep ncan
  nrep=$(printf '%s' "$diff" | jq '(.reprioritize // [])|length')
  for ((i=0; i<nrep; i++)); do
    ident=$(printf '%s' "$diff" | jq -r ".reprioritize[$i].ident")
    prio=$(printf '%s' "$diff"  | jq -r ".reprioritize[$i].priority")
    _objective_owns_open "$obj_id" "$ident" || continue   # defense-in-depth re-check
    db "UPDATE tasks SET priority=$(sqlq "$prio") WHERE ident=$(sqlq "$ident") AND originated_by_objective=${obj_id} AND status NOT IN ('done','cancelled');"
    OBJ_APPLIED_REPRI=$((OBJ_APPLIED_REPRI+1))
  done
  ncan=$(printf '%s' "$diff" | jq '(.cancel // [])|length')
  for ((i=0; i<ncan; i++)); do
    ident=$(printf '%s' "$diff" | jq -r ".cancel[$i].ident")
    reason=$(printf '%s' "$diff" | jq -r ".cancel[$i].reason // \"objective re-plan: no longer needed\"")
    _objective_owns_open "$obj_id" "$ident" || continue   # own-only, re-checked at apply
    ( JSON_MODE=1 cmd_task_cancel "$ident" --result="$reason" ${from:+--from="$from"} ) >/dev/null 2>&1 || true
    OBJ_APPLIED_CANCEL=$((OBJ_APPLIED_CANCEL+1))
  done
}

# ---- approve->apply a gated diff (the T2 / over-checkpoint completion path) ----
_objective_apply_from_gate() {
  local gate_ref="$1" obj_id="$2" oname="$3" pkey="$4" max_new="$5" depth_cap="$6" from="$7"
  resolve_task_id "$gate_ref"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  local title; title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
  [[ "$title" == Replan:* ]] || fail "$E_VALIDATION" "$ident is not an objective re-plan gate (title is not 'Replan: …')"
  # Must be ANSWERED, by a HUMAN, with 'approve' (DIVE-916 human-origin rule).
  local nat nans nby
  nat=$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${id};")
  nans=$(db "SELECT COALESCE(need_answer,'')     FROM tasks WHERE id=${id};")
  nby=$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE id=${id};")
  [[ -n "$nat" ]] || fail "$E_CONFLICT" "$ident's gate is not answered yet — a human must approve it first, then re-run"
  [[ "$nby" == human:* ]] || fail "$E_AUTH_REQUIRED" "$ident's gate was not cleared by a human (answered by '${nby:-?}') — an objective diff may only be applied on a HUMAN approval (DIVE-916)"
  [[ "$nans" == "approve" ]] || fail "$E_CONFLICT" "$ident's gate was answered '${nans}', not 'approve' — nothing applied (re-plan to revise)"
  # Recover the diff from the anchor body + RE-VALIDATE from scratch.
  local body diff; body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
  diff=$(printf '%s' "$body" | awk 'f{print} /^--- objective diff json ---$/{f=1}')
  printf '%s' "$diff" | jq -e . >/dev/null 2>&1 || fail "$E_VALIDATION" "could not recover a valid diff from $ident's body"
  diff=$(_objective_normalize_diff "$diff")   # DIVE-1551: tolerate pre-fix gates that stored `id`
  _objective_validate_diff "$diff" "$obj_id" "$oname" "$max_new" "$depth_cap"
  [[ -n "$pkey" ]] || fail "$E_VALIDATION" "objective '$oname' has no project — cannot apply"
  # Find the gated cycle this anchor filed (so we update, not duplicate).
  local cyc; cyc=$(db "SELECT cycle_no FROM objective_cycles WHERE objective_id=${obj_id} AND gate_anchor=$(sqlq "$ident") ORDER BY id DESC LIMIT 1;")
  [[ -n "$cyc" ]] || cyc=$(db "SELECT COALESCE(MAX(cycle_no),0)+1 FROM objective_cycles WHERE objective_id=${obj_id};")
  _objective_apply_diff "$diff" "$obj_id" "$pkey" "$cyc" "$from"
  # Update the gated cycle row to applied (or record one if none existed).
  db "UPDATE objective_cycles SET outcome='applied', applied=${OBJ_APPLIED_CREATE}, reprioritized=${OBJ_APPLIED_REPRI}, cancelled=${OBJ_APPLIED_CANCEL}
      WHERE objective_id=${obj_id} AND gate_anchor=$(sqlq "$ident");"
  if (( JSON_MODE )); then
    ok "" '{applied:true, fromGate:$g, objective:$o, cycle:($c|tonumber), created:($cr|tonumber), reprioritized:($rp|tonumber), cancelled:($cx|tonumber), idents:($ids|split(" ")|map(select(length>0)))}' \
       --arg g "$ident" --arg o "$oname" --arg c "$cyc" --arg cr "$OBJ_APPLIED_CREATE" --arg rp "$OBJ_APPLIED_REPRI" --arg cx "$OBJ_APPLIED_CANCEL" --arg ids "$OBJ_CREATED_IDENTS"
  else
    ok "objective '$oname' diff applied from approved gate $ident — +${OBJ_APPLIED_CREATE} created, ${OBJ_APPLIED_REPRI} reprioritized, ${OBJ_APPLIED_CANCEL} cancelled: ${OBJ_CREATED_IDENTS}"
  fi
}

cmd_objective_replan() {
  tasks_db_init
  local ref="" planner="" max_new="" checkpoint="$OBJ_CHECKPOINT_DEFAULT" depth_cap="$OBJ_DEPTH_CAP_DEFAULT"
  local ceiling="$OBJ_CEILING_DEFAULT" wait_secs="$OBJ_PLANNER_WAIT_DEFAULT"
  local dry_run="" yes="" diff="" from="" from_gate="" propose_only="" force=""
  local no_prog_limit="$OBJ_NOPROGRESS_DEFAULT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --planner=*)           planner="${1#*=}" ;;
      --max-new-per-cycle=*) max_new="${1#*=}" ;;
      --checkpoint=*)        checkpoint="${1#*=}" ;;
      --depth-cap=*)         depth_cap="${1#*=}" ;;
      --ceiling=*)           ceiling="${1#*=}" ;;
      --wait=*)              wait_secs="${1#*=}" ;;
      --no-progress-limit=*) no_prog_limit="${1#*=}" ;;   # OSS-33 stop: N flat cycles (0=off)
      --dry-run)             dry_run=1 ;;
      --yes)                 yes=1 ;;
      --force)               force=1 ;;                    # OSS-33: bypass preflight refusal
      --propose-only|--shadow) propose_only=1 ;;   # OSS-27/OSS-35 shadow-first
      --diff=*)              diff="${1#*=}" ;;
      --from-gate=*)         from_gate="${1#*=}" ;;
      --from=*)              from="${1#*=}" ;;
      -*)                    fail "$E_USAGE" "unknown flag: $1" ;;
      *)                     [[ -z "$ref" ]] && ref="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$ref" ]] || fail "$E_USAGE" 'usage: 5dive objective replan <name> [--max-new-per-cycle=N] [--no-progress-limit=N] [--dry-run] [--yes] [--force] [--diff=<json>] [--from-gate=<id>] [--planner=<a>]'
  _objective_resolve "$ref"
  local obj_id="$OBJECTIVE_ID" oname="$OBJECTIVE_NAME"

  local o_status o_planner o_project o_maxnew o_budget o_target o_dir o_unit
  o_status=$(db  "SELECT status FROM objectives WHERE id=$obj_id;")
  o_planner=$(db "SELECT COALESCE(planner,'') FROM objectives WHERE id=$obj_id;")
  o_project=$(db "SELECT COALESCE(project_key,'') FROM objectives WHERE id=$obj_id;")
  o_maxnew=$(db  "SELECT max_new_per_cycle FROM objectives WHERE id=$obj_id;")
  o_budget=$(db  "SELECT COALESCE(budget,'') FROM objectives WHERE id=$obj_id;")
  o_target=$(db  "SELECT COALESCE(target,'') FROM objectives WHERE id=$obj_id;")
  o_dir=$(db     "SELECT direction FROM objectives WHERE id=$obj_id;")
  o_unit=$(db    "SELECT COALESCE(unit,'') FROM objectives WHERE id=$obj_id;")
  local o_runmode; o_runmode=$(db "SELECT COALESCE(run_mode,'live') FROM objectives WHERE id=$obj_id;")
  # OSS-27/OSS-35 shadow-first: a shadow objective (or an explicit --propose-only)
  # forces PROPOSE-ONLY — the WHOLE non-empty diff rides ONE gate, nothing
  # auto-applies (not even own-task reprioritize/cancel), and --yes cannot waive it.
  [[ "$o_runmode" == "shadow" ]] && propose_only=1
  [[ -n "$max_new" ]] || max_new="$o_maxnew"
  [[ "$max_new"    =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "--max-new-per-cycle must be a non-negative integer"
  [[ "$checkpoint" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "--checkpoint must be a non-negative integer"
  [[ "$depth_cap"  =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--depth-cap must be a positive integer"
  [[ -n "$planner" ]] || planner="$o_planner"

  # --- from-gate: apply an already-proposed, human-approved diff ---
  if [[ -n "$from_gate" ]]; then
    _objective_apply_from_gate "$from_gate" "$obj_id" "$oname" "$o_project" "$max_new" "$depth_cap" "$from"
    return
  fi

  # --- stop-conditions (never a silent stall) ---
  [[ "$o_status" == "active" ]] || fail "$E_CONFLICT" "objective '$oname' is ${o_status} — resume it before re-planning (5dive objective resume \"$oname\")"

  local cur prev trend
  cur=$(db  "SELECT value FROM objective_readings WHERE objective_id=$obj_id AND value IS NOT NULL ORDER BY id DESC LIMIT 1;")
  prev=$(db "SELECT value FROM objective_readings WHERE objective_id=$obj_id AND value IS NOT NULL ORDER BY id DESC LIMIT 1 OFFSET 1;")
  trend=$(_objective_trend "$cur" "$prev")

  local cycle_no; cycle_no=$(db "SELECT COALESCE(MAX(cycle_no),0)+1 FROM objective_cycles WHERE objective_id=$obj_id;")

  local spent; spent=$(db "SELECT COALESCE(SUM(tokens_spent),0) FROM objective_cycles WHERE objective_id=$obj_id;")
  if [[ -n "$o_budget" ]] && awk -v s="$spent" -v b="$o_budget" 'BEGIN{exit !(s>=b)}'; then
    _objective_record_cycle "$obj_id" "$cycle_no" "$cur" 0 0 0 0 0 "" 0 "budget_exhausted"
    _objective_terminal_out "$oname" "$cycle_no" "budget_exhausted" "spent ${spent} >= budget ${o_budget} tokens — re-planning halted; raise --budget to continue"
    return
  fi
  if [[ -n "$o_target" && -n "$cur" ]] && _objective_target_met "$cur" "$o_target" "$o_dir"; then
    _objective_record_cycle "$obj_id" "$cycle_no" "$cur" 0 0 0 0 0 "" 0 "target_reached"
    _objective_terminal_out "$oname" "$cycle_no" "target_reached" "current ${cur}${o_unit} meets target ${o_target}${o_unit} (${o_dir}) — nothing to originate"
    return
  fi

  [[ -n "$o_project" ]] || o_project=$(_objective_ensure_project "$obj_id" "$oname" "$planner")

  # OSS-33 loop stop-conditions + preflight, on the AUTONOMOUS path only (a live
  # planner is about to be invoked). A manual --diff / --from-gate is an operator
  # override that legitimately bypasses these loop guards. Each guard records a
  # cycle row with an explicit outcome and returns — the loop never stalls silently.
  if [[ -z "$diff" ]]; then
    [[ "$no_prog_limit" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "--no-progress-limit must be a non-negative integer"

    # (a) PREFLIGHT: a required role can't do the work -> refuse, with a reason.
    if [[ -z "$force" ]] && ! _objective_preflight "$obj_id" "$oname"; then
      _objective_record_cycle "$obj_id" "$cycle_no" "$cur" 0 0 0 0 0 "" 0 "blocked_${PREFLIGHT_REASON}"
      _objective_terminal_out "$oname" "$cycle_no" "blocked_${PREFLIGHT_REASON}" "preflight: ${PREFLIGHT_DETAIL} — nothing originated (fix it, or replan --force)"
      return
    fi

    # (b) GATE in flight: a prior cycle filed a gate still awaiting a decision.
    # Wait; do not stack a fresh proposal on top of one not yet approved. A Tier-2
    # gate needs a human; a Tier-1 checkpoint needs a lead/precedent clear.
    local pend_row pend_gate pend_tier
    pend_row=$(_objective_pending_gate "$obj_id")
    if [[ -n "$pend_row" ]]; then
      pend_gate="${pend_row%%|*}"; pend_tier="${pend_row#*|}"
      _objective_record_cycle "$obj_id" "$cycle_no" "$cur" 0 0 0 0 0 "$pend_gate" 0 "gate_pending"
      local how="approval"; [[ "${pend_tier:-0}" -ge 2 ]] && how="Tier-2 hard-gate human approval"
      _objective_terminal_out "$oname" "$cycle_no" "gate_pending" "waiting on the ${how} of ${pend_gate} — apply it once approved (objective replan \"$oname\" --from-gate=${pend_gate}); nothing new proposed"
      return
    fi

    # (c) NO PROGRESS: the metric has not moved favorably across N cycles -> PAUSE
    # (a genuine terminal state so the heartbeat stops respinning) and explain.
    if _objective_no_progress "$obj_id" "$o_dir" "$no_prog_limit"; then
      _objective_record_cycle "$obj_id" "$cycle_no" "$cur" 0 0 0 0 0 "" 0 "no_progress"
      db "UPDATE objectives SET status='paused', updated_at=datetime('now') WHERE id=$obj_id;"
      _objective_terminal_out "$oname" "$cycle_no" "no_progress" "metric flat/adverse for ${no_prog_limit} cycles (now ${cur:-none}${o_unit}) — objective PAUSED; a human should adjust the plan then resume (5dive objective resume \"$oname\")"
      return
    fi

    [[ -n "$planner" ]] || planner=$(_task_resolve_coordinator)
    [[ -n "$planner" ]] || fail "$E_VALIDATION" "no --planner, objective planner, or org coordinator to plan with"
    local contract; contract=$(_objective_build_contract "$oname" "$obj_id" "$cur" "$prev" "$trend" "$o_target" "$o_dir" "$o_unit" "$max_new")
    step "objective '$oname' cycle ${cycle_no}: invoking planner '$planner' (ceiling ${ceiling}tok)…"
    # NB: NOT $(...) — invoke_planner returns via globals (OBJ_PLANNER_DIFF +
    # the loop/task/status stamps); a subshell would drop the stamps we need to
    # record the awaiting_planner cycle.
    _objective_invoke_planner "$contract" "$planner" "$ceiling" "$wait_secs" || return $?
    diff="$OBJ_PLANNER_DIFF"

    # DIVE-1737: planner loop timed out past the wait window but its backing task
    # SURVIVES and will finish later. Record an 'awaiting_planner' cycle stamped
    # with the loop/task ids and hand off — the heartbeat reconciler pulls the
    # late diff and re-drives THIS same command via --diff. This replaces the old
    # hard E_TIMEOUT that dropped the cycle (and orphaned the diff) on the floor.
    if [[ "$OBJ_PLANNER_STATUS" != "done" ]]; then
      _objective_record_cycle "$obj_id" "$cycle_no" "$cur" 0 0 0 0 0 "" "$OBJ_PLANNER_TOKENS" "awaiting_planner" "$OBJ_PLANNER_LOOP_ID" "$OBJ_PLANNER_TASK_ID"
      _objective_terminal_out "$oname" "$cycle_no" "awaiting_planner" "planner loop ${OBJ_PLANNER_LOOP_ID:-?} still running past ${wait_secs}s (backing task ${OBJ_PLANNER_TASK_ID:-?}); the heartbeat reconciler will materialize its diff on completion — nothing dropped"
      return
    fi
  fi

  diff=$(_objective_normalize_diff "$diff")   # DIVE-1551: id->local_id tolerance
  _objective_validate_diff "$diff" "$obj_id" "$oname" "$max_new" "$depth_cap"

  if [[ -n "$dry_run" ]]; then
    _objective_terminal_out "$oname" "$cycle_no" "dry-run" "would create ${OBJ_N_CREATE}, reprioritize ${OBJ_N_REPRI}, cancel ${OBJ_N_CANCEL} (T2=${GOAL_HAS_T2}); nothing applied"
    return
  fi

  # ONE count-checkpoint gate: ANY origination over --checkpoint (default 0 => any)
  # OR any T2 create. --yes waives ONLY the count check; a T2 create ALWAYS gates.
  local over_count=0; [[ "$OBJ_N_CREATE" -gt "$checkpoint" ]] && over_count=1
  local needs_gate=0
  [[ "$GOAL_HAS_T2" == "1" ]] && needs_gate=1
  [[ "$over_count" == "1" && -z "$yes" ]] && needs_gate=1
  # PROPOSE-ONLY (shadow / --propose-only): gate the WHOLE diff on ANY non-empty
  # change — including own-task reprioritize/cancel that live mode would apply
  # directly — and IGNORE --yes (shadow is a hard, unwaivable mode). This is the
  # OSS-35 shadow-first lever: run #1 can dogfood green without auto-executing.
  local nonempty=0; (( OBJ_N_CREATE + OBJ_N_REPRI + OBJ_N_CANCEL > 0 )) && nonempty=1
  [[ -n "$propose_only" && "$nonempty" == "1" ]] && needs_gate=1

  if [[ "$needs_gate" == "1" ]]; then
    _objective_file_gate "$obj_id" "$oname" "$o_project" "$cycle_no" "$diff" "$from"
    _objective_record_cycle "$obj_id" "$cycle_no" "$cur" "$OBJ_N_CREATE" 0 0 0 1 "$OBJ_GATE_ANCHOR" "$OBJ_PLANNER_TOKENS" "gated"
    if (( JSON_MODE )); then
      ok "" '{gated:true, proposeOnly:($po=="1"), objective:$o, cycle:($c|tonumber), anchor:$a, proposedCreate:($nc|tonumber), reprioritize:($nr|tonumber), cancel:($nx|tonumber), hasT2:($t2=="1")}' \
         --arg o "$oname" --arg c "$cycle_no" --arg a "$OBJ_GATE_ANCHOR" --arg nc "$OBJ_N_CREATE" --arg nr "$OBJ_N_REPRI" --arg nx "$OBJ_N_CANCEL" --arg t2 "$GOAL_HAS_T2" --arg po "${propose_only:-0}"
    else
      local how="origination gated"; [[ -n "$propose_only" ]] && how="PROPOSE-ONLY (shadow) — whole diff gated"
      echo "Objective '$oname' cycle ${cycle_no}: ${how} on $OBJ_GATE_ANCHOR (create ${OBJ_N_CREATE}, reprioritize ${OBJ_N_REPRI}, cancel ${OBJ_N_CANCEL}$([[ "$GOAL_HAS_T2" == "1" ]] && echo ", Tier-2 hard gate")). Nothing applied."
      echo "After a human approves the gate: 5dive objective replan \"$oname\" --from-gate=$OBJ_GATE_ANCHOR"
    fi
    return
  fi

  _objective_apply_diff "$diff" "$obj_id" "$o_project" "$cycle_no" "$from"
  _objective_record_cycle "$obj_id" "$cycle_no" "$cur" "$OBJ_N_CREATE" "$OBJ_APPLIED_CREATE" "$OBJ_APPLIED_REPRI" "$OBJ_APPLIED_CANCEL" 0 "" "$OBJ_PLANNER_TOKENS" "applied"
  if (( JSON_MODE )); then
    ok "" '{applied:true, objective:$o, cycle:($c|tonumber), created:($cr|tonumber), reprioritized:($rp|tonumber), cancelled:($cx|tonumber), idents:($ids|split(" ")|map(select(length>0)))}' \
       --arg o "$oname" --arg c "$cycle_no" --arg cr "$OBJ_APPLIED_CREATE" --arg rp "$OBJ_APPLIED_REPRI" --arg cx "$OBJ_APPLIED_CANCEL" --arg ids "$OBJ_CREATED_IDENTS"
  else
    ok "objective '$oname' cycle ${cycle_no} applied — +${OBJ_APPLIED_CREATE} created, ${OBJ_APPLIED_REPRI} reprioritized, ${OBJ_APPLIED_CANCEL} cancelled: ${OBJ_CREATED_IDENTS}"
  fi
}

# Terminal/no-op cycle output (stop-conditions + dry-run). Records nothing here;
# the caller already recorded the cycle. Always returns 0.
_objective_terminal_out() {
  local oname="$1" cycle_no="$2" outcome="$3" msg="$4"
  if (( JSON_MODE )); then
    ok "" '{objective:$o, cycle:($c|tonumber), outcome:$oc, applied:false, message:$m}' \
       --arg o "$oname" --arg c "$cycle_no" --arg oc "$outcome" --arg m "$msg"
  else
    ok "objective '$oname' cycle ${cycle_no}: ${outcome} — ${msg}"
  fi
  return 0
}
