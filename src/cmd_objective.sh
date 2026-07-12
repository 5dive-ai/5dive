
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
    pause)            cmd_objective_setstatus paused "$@" ;;
    resume)           cmd_objective_setstatus active "$@" ;;
    rm|remove|delete) cmd_objective_rm "$@" ;;
    tick)             cmd_objective_tick "$@" ;;
    *) fail "$E_USAGE" "unknown objective command: $sub (add|ls|show|pause|resume|rm|tick)" ;;
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
  local project="" maxnew="3" budget="" public="0"
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
      --public)              public="1" ;;
      -*)                    fail "$E_USAGE" "unknown flag: $1" ;;
      *)                     words+=("$1") ;;
    esac
    shift
  done
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
         max_new_per_cycle, budget, public, created_by)
      VALUES ($(sqlq "$name"), $(sqlq "$metric"), $(sqlq_or_null "$target"),
              $(sqlq "$direction"), $(sqlq_or_null "$unit"), $(sqlq_or_null "$review"),
              $(sqlq_or_null "$planner"), $(sqlq_or_null "$project"),
              $maxnew, $(sqlq_or_null "$budget"), $public, $(sqlq "$by"));"

  ok "objective '$name' created (${direction} to ${target:-?}${unit:-}) — take first reading: 5dive objective tick \"$name\"" \
     '{name:$n, direction:$d, target:$t, unit:$u, public:($p=="1")}' \
     --arg n "$name" --arg d "$direction" --arg t "${target:-}" --arg u "${unit:-}" --arg p "$public"
}

cmd_objective_ls() {
  tasks_db_init
  if (( JSON_MODE )); then
    # Attach the latest reading (value + ts) per objective.
    local rows
    rows=$(dbfmt -json "
      SELECT o.id, o.name, o.metric_cmd, o.target, o.direction, o.unit, o.public,
             o.status, o.project_key, o.created_at,
             (SELECT value FROM objective_readings r WHERE r.objective_id=o.id ORDER BY r.id DESC LIMIT 1) AS current,
             (SELECT ts    FROM objective_readings r WHERE r.objective_id=o.id ORDER BY r.id DESC LIMIT 1) AS current_ts
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
  local ref="${1:-}"
  [[ -n "$ref" ]] || fail "$E_USAGE" "usage: 5dive objective ${status/active/resume} <name>"
  _objective_resolve "$ref"
  db "UPDATE objectives SET status=$(sqlq "$status"), updated_at=datetime('now') WHERE id=$OBJECTIVE_ID;"
  ok "objective '$OBJECTIVE_NAME' -> $status" '{name:$n, status:$s}' --arg n "$OBJECTIVE_NAME" --arg s "$status"
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
