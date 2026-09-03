# -------- DIVE-3932: `5dive run` — the operational attempt surface ------------
#
# Read-mostly view over runs/run_events/run_usage (src/lib/runs.sh writes them).
# Same posture as `trace`/`usage`/`digest`: group-writable store, no root, no
# registry lock, no audit line. `run retry` is the one writer, and it only ever
# APPENDS a new attempt — it can neither edit nor delete the run it retries.

_run_usage() {
  cat >&2 <<'USAGE'
usage:
  5dive run ls [--task=DIVE-N] [--agent=<name>] [--role=maker|verifier]
               [--status=running|completed|failed|abandoned|parked]
               [--outcome=<s>] [--since=<24h|7d|YYYY-MM-DD>] [--limit=N] [--json]
  5dive run show <RUN-ID> [--json]
  5dive run events <RUN-ID> [--json]
  5dive run logs <RUN-ID> [--follow] [--lines=N]
  5dive run retry <RUN-ID> [--json]
  5dive run metrics [--since=<24h|7d>] [--agent=<name>] [--json]

A run is ONE attempt by ONE agent to advance ONE task. `5dive trace <task>` is
still the causal story across those attempts; this is the unit beneath it.
USAGE
}

# _run_since_sql <spec> — a SQL datetime literal for --since, or ''. Accepts
# 24h/7d/30m style offsets and a plain ISO date. An unparseable value is REFUSED
# rather than silently ignored: a filter that quietly matches everything is how a
# reader concludes "nothing failed overnight" from a query that never filtered.
_run_since_sql() {
  local spec="${1:-}"
  [[ -n "$spec" ]] || return 0
  case "$spec" in
    *[0-9]m) printf "datetime('now','-%s minutes')" "${spec%m}" ;;
    *[0-9]h) printf "datetime('now','-%s hours')"   "${spec%h}" ;;
    *[0-9]d) printf "datetime('now','-%s days')"    "${spec%d}" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) sqlq "$spec" ;;
    *) fail "$E_USAGE" "unrecognised --since '${spec}' — use 30m, 24h, 7d or YYYY-MM-DD" ;;
  esac
}

# _run_resolve <id-or-prefix> — a full run id, or fail. Accepts a unique prefix
# so a reader can retype the first few characters off a listing; an AMBIGUOUS
# prefix is an error, never a silent "first match", because acting on the wrong
# attempt is exactly what `run retry` must not do.
_run_resolve() {
  local want="${1:-}"
  [[ -n "$want" ]] || fail "$E_USAGE" "usage: 5dive run <verb> <RUN-ID>"
  local exact
  exact=$(db "SELECT id FROM runs WHERE id=$(sqlq "$want") LIMIT 1;" 2>/dev/null) || exact=""
  [[ -n "$exact" ]] && { printf '%s' "$exact"; return 0; }
  local -a hits=()
  mapfile -t hits < <(db "SELECT id FROM runs WHERE id LIKE $(sqlq "${want}%") LIMIT 5;" 2>/dev/null)
  case "${#hits[@]}" in
    0) fail "$E_NOT_FOUND" "no run '${want}' — list them with: 5dive run ls" ;;
    1) printf '%s' "${hits[0]}" ;;
    *) fail "$E_USAGE" "run id '${want}' is ambiguous: ${hits[*]}" ;;
  esac
}

cmd_run_ls() {
  local task="" agent="" role="" status="" outcome="" since="" limit=30
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task=*)    task="${1#*=}" ;;
      --agent=*)   agent="${1#*=}" ;;
      --role=*)    role="${1#*=}" ;;
      --status=*)  status="${1#*=}" ;;
      --outcome=*) outcome="${1#*=}" ;;
      --since=*)   since="${1#*=}" ;;
      --limit=*)   limit="${1#*=}" ;;
      --json)      JSON_MODE=1 ;;
      -h|--help)   _run_usage; return 0 ;;
      *)           fail "$E_USAGE" "unknown argument: $1" ;;
    esac
    shift
  done
  [[ "$limit" =~ ^[0-9]+$ ]] || fail "$E_USAGE" "--limit must be a number"
  local where="1=1"
  if [[ -n "$task" ]]; then
    resolve_task_id "$task"
    where+=" AND r.task_id=${RESOLVED_TASK_ID}"
  fi
  [[ -n "$agent"   ]] && where+=" AND r.agent=$(sqlq "$agent")"
  [[ -n "$role"    ]] && where+=" AND r.role=$(sqlq "$role")"
  [[ -n "$status"  ]] && where+=" AND r.status=$(sqlq "$status")"
  [[ -n "$outcome" ]] && where+=" AND r.outcome=$(sqlq "$outcome")"
  local since_sql; since_sql=$(_run_since_sql "$since")
  [[ -n "$since_sql" ]] && where+=" AND r.started_at >= ${since_sql}"

  # duration_s is computed in SQL and left NULL for a still-running attempt. NOT
  # "now - started_at": a run whose seat died three days ago would render a
  # 72-hour duration that no work occupied, and a NULL a reader can see beats a
  # number that looks measured.
  local sel="SELECT r.id, COALESCE(t.ident,'-') AS task, COALESCE(r.agent,'-') AS agent,
                    COALESCE(r.role,'-') AS role, r.attempt, r.status,
                    COALESCE(r.outcome,'') AS outcome,
                    CAST((julianday(r.ended_at)-julianday(r.started_at))*86400 AS INTEGER) AS duration_s,
                    r.human_touch, r.started_at, r.ended_at, r.retry_of
               FROM runs r LEFT JOIN tasks t ON t.id=r.task_id
              WHERE ${where}
              ORDER BY r.started_at DESC, r.id DESC LIMIT ${limit};"
  if (( JSON_MODE )); then
    local rows; rows=$(dbfmt -json "$sel"); [[ -n "$rows" ]] || rows='[]'
    ok "" '$r|fromjson' --arg r "$rows"
    return 0
  fi
  local out; out=$(dbfmt -list "$sel" 2>/dev/null)
  if [[ -z "$out" ]]; then echo "no runs match"; return 0; fi
  printf '%-7s %-16s %-12s %-14s %-9s %-8s %-9s %s\n' \
         STATUS RUN TASK AGENT ROLE ATTEMPT DURATION OUTCOME
  printf '%s\n' "$out" \
    | while IFS='|' read -r rid task agent role attempt status outcome dur touch _s _e _r; do
        local mark
        case "$status" in
          completed) mark='ok' ;;
          failed)    mark='FAIL' ;;
          abandoned) mark='lost' ;;
          parked)    mark='park' ;;
          *)         mark='...' ;;
        esac
        printf '%-7s %-16s %-12s %-14s %-9s %-8s %-9s %s%s\n' \
          "$mark" "$rid" "$task" "$agent" "$role" "$attempt" \
          "$([[ -n "$dur" ]] && _run_dur "$dur" || printf -- '-')" \
          "${outcome:--}" "$([[ "$touch" == "1" ]] && printf ' [human]')"
      done
}

# _run_dur <seconds> — 18m / 2h14m / 41s.
_run_dur() {
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || { printf -- '-'; return 0; }
  if   (( s < 60 ));   then printf '%ds' "$s"
  elif (( s < 3600 )); then printf '%dm' "$((s/60))"
  else printf '%dh%dm' "$((s/3600))" "$(((s%3600)/60))"; fi
}

cmd_run_show() {
  local want="" ; while [[ $# -gt 0 ]]; do
    case "$1" in --json) JSON_MODE=1 ;; -h|--help) _run_usage; return 0 ;;
                 -*) fail "$E_USAGE" "unknown flag: $1" ;; *) want="$1" ;; esac; shift
  done
  local rid; rid=$(_run_resolve "$want")
  if (( JSON_MODE )); then
    local j ev us
    j=$(dbfmt -json "SELECT r.*, COALESCE(t.ident,'') AS task_ident, COALESCE(t.title,'') AS task_title
                       FROM runs r LEFT JOIN tasks t ON t.id=r.task_id WHERE r.id=$(sqlq "$rid");")
    ev=$(dbfmt -json "SELECT ts, kind, actor, data_json FROM run_events WHERE run_id=$(sqlq "$rid") ORDER BY id;")
    us=$(dbfmt -json "SELECT metric, value, unit, source, quality, scope, observed_at
                        FROM run_usage WHERE run_id=$(sqlq "$rid") ORDER BY id;")
    [[ -n "$ev" ]] || ev='[]'; [[ -n "$us" ]] || us='[]'
    ok "" '($r|fromjson)[0] + {events:($e|fromjson), usage:($u|fromjson)}' \
       --arg r "$j" --arg e "$ev" --arg u "$us"
    return 0
  fi
  dbfmt -line "SELECT r.id AS run, COALESCE(t.ident,'-')||' '||COALESCE(t.title,'') AS task,
                      COALESCE(r.agent,'-') AS agent, COALESCE(r.role,'-') AS role,
                      r.attempt, COALESCE(r.retry_of,'-') AS retry_of,
                      COALESCE(r.parent_run_id,'-') AS parent_run,
                      COALESCE(r.wake_reason,'-') AS wake_reason,
                      COALESCE(r.runtime_type,'-') AS runtime,
                      COALESCE(r.model,'-') AS model,
                      COALESCE(r.session_id,'-') AS session,
                      r.started_at, COALESCE(r.ended_at,'-') AS ended_at,
                      r.status, COALESCE(r.outcome,'-') AS outcome,
                      COALESCE(r.error_class,'-') AS error_class,
                      COALESCE(r.error_summary,'-') AS error_summary,
                      CASE r.human_touch WHEN 1 THEN 'yes' ELSE 'no' END AS human_touch,
                      COALESCE(r.journal_unit,'-') AS journal_unit
                 FROM runs r LEFT JOIN tasks t ON t.id=r.task_id WHERE r.id=$(sqlq "$rid");"
  echo
  echo "Timeline"
  local ev; ev=$(dbfmt -list "SELECT ts||'  '||kind||COALESCE('  '||actor,'')||COALESCE('  '||data_json,'')
                                FROM run_events WHERE run_id=$(sqlq "$rid") ORDER BY id;" 2>/dev/null)
  [[ -n "$ev" ]] && printf '%s\n' "$ev" || echo "  (no events recorded)"
  echo
  echo "Usage"
  # EVERY datum renders its provenance, and a metric with quality='unavailable'
  # prints the word `unavailable` rather than a zero or a blank. That is the
  # proposal's product rule made mechanical: an absent measurement must never be
  # displayable as a measured one.
  local us; us=$(dbfmt -list "SELECT '  '||metric||': '||
                                COALESCE(CAST(value AS TEXT)||COALESCE(' '||unit,''),'unavailable')||
                                '   ['||source||' / '||quality||' / '||scope||']'
                                FROM run_usage WHERE run_id=$(sqlq "$rid") ORDER BY id;" 2>/dev/null)
  if [[ -n "$us" ]]; then printf '%s\n' "$us"; else
    echo "  tokens: unavailable            [runtime did not expose a per-run count]"
    echo "  API cost: n/a                  [subscription runtime — no marginal per-run price]"
  fi
  echo
  echo "trace: 5dive trace $(db "SELECT COALESCE(t.ident,'') FROM runs r LEFT JOIN tasks t ON t.id=r.task_id WHERE r.id=$(sqlq "$rid");" 2>/dev/null)"
}

cmd_run_events() {
  local want="" ; while [[ $# -gt 0 ]]; do
    case "$1" in --json) JSON_MODE=1 ;; -*) fail "$E_USAGE" "unknown flag: $1" ;; *) want="$1" ;; esac; shift
  done
  local rid; rid=$(_run_resolve "$want")
  local q="SELECT ts, kind, COALESCE(actor,'-') AS actor, COALESCE(data_json,'') AS data
             FROM run_events WHERE run_id=$(sqlq "$rid") ORDER BY id;"
  if (( JSON_MODE )); then
    local rows; rows=$(dbfmt -json "$q"); [[ -n "$rows" ]] || rows='[]'
    ok "" '$r|fromjson' --arg r "$rows"; return 0
  fi
  dbfmt -column "$q"
}

# `run logs` — re-open the JOURNAL WINDOW this run occupied. Nothing is copied
# into sqlite (an explicit non-goal); we stored a unit plus cursors, and the time
# span is the fallback when no cursor was readable at open time.
cmd_run_logs() {
  local want="" follow=0 lines=200
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --follow|-f) follow=1 ;;
      --lines=*)   lines="${1#*=}" ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           want="$1" ;;
    esac; shift
  done
  [[ "$lines" =~ ^[0-9]+$ ]] || fail "$E_USAGE" "--lines must be a number"
  local rid; rid=$(_run_resolve "$want")
  local unit cur_s started ended
  unit=$(db    "SELECT COALESCE(journal_unit,'')         FROM runs WHERE id=$(sqlq "$rid");")
  cur_s=$(db   "SELECT COALESCE(journal_cursor_start,'') FROM runs WHERE id=$(sqlq "$rid");")
  started=$(db "SELECT COALESCE(started_at,'')           FROM runs WHERE id=$(sqlq "$rid");")
  ended=$(db   "SELECT COALESCE(ended_at,'')             FROM runs WHERE id=$(sqlq "$rid");")
  [[ -n "$unit" ]] || fail "$E_NOT_FOUND" \
    "run ${rid} recorded no journal unit — it was opened by a caller with no systemd seat, so there is no interval to reopen."
  command -v journalctl >/dev/null 2>&1 || fail "$E_NOT_INSTALLED" "journalctl not available on this host"
  local -a args=(-u "$unit" --no-pager)
  if [[ -n "$cur_s" ]]; then args+=(--after-cursor "$cur_s"); else args+=(--since "$started"); fi
  # The END of the window is applied only when the run has ended AND we are not
  # following: a --until on a live run would cut off the output the caller asked
  # to watch.
  if (( ! follow )) && [[ -n "$ended" ]]; then args+=(--until "$ended"); fi
  (( follow )) && args+=(-f)
  (( follow )) || args+=(-n "$lines")
  journalctl "${args[@]}"
}

# `run retry` — a NEW attempt, linked. The retried run is read and never written:
# preserving the failed attempt unchanged is the whole point of the lineage, and
# it is what lets "auto-recovered failures" be counted at all.
cmd_run_retry() {
  local want="" ; while [[ $# -gt 0 ]]; do
    case "$1" in --json) JSON_MODE=1 ;; -*) fail "$E_USAGE" "unknown flag: $1" ;; *) want="$1" ;; esac; shift
  done
  local rid; rid=$(_run_resolve "$want")
  local tid ident agent st
  tid=$(db   "SELECT COALESCE(task_id,'') FROM runs WHERE id=$(sqlq "$rid");")
  agent=$(db "SELECT COALESCE(agent,'')   FROM runs WHERE id=$(sqlq "$rid");")
  st=$(db    "SELECT status               FROM runs WHERE id=$(sqlq "$rid");")
  [[ "$tid" =~ ^[0-9]+$ ]] || fail "$E_USAGE" "run ${rid} is not bound to a task — nothing to retry"
  [[ "$st" == "running" ]] && fail "$E_USAGE" \
    "run ${rid} is still running — retrying a live attempt would double-count it. Let it reach a boundary first."
  ident=$(db "SELECT COALESCE(t.ident,'') FROM runs r LEFT JOIN tasks t ON t.id=r.task_id WHERE r.id=$(sqlq "$rid");")
  local new; new=$(run_open "$tid" "$ident" "manual retry of ${rid}" "$rid" "$agent")
  [[ -n "$new" ]] || fail "$E_GENERIC" "could not open a retry run for ${rid}"
  run_event "$new" run.retried "{\"retry_of\":$(_run_json_str "$rid")}"
  ok "retry of ${rid} opened as ${new} (${ident:-task ${tid}}) — ${rid} is unchanged" \
     '{run:$n, retryOf:$o, task:$t}' --arg n "$new" --arg o "$rid" --arg t "${ident:-$tid}"
}

# `run metrics` — the LOCAL operational metrics this row exists to make possible.
#
# Every rate names its denominator in the output. A percentage whose denominator
# is 3 and one whose denominator is 300 read identically otherwise, and the
# fleet-reliability numbers are exactly where that difference decides whether a
# reader should act. `n=0` prints NO DATA rather than 0% — the same rule the ship
# scorecard already follows, for the same reason: a zero that means "we never
# measured" is worse than an absent number.
cmd_run_metrics() {
  local since="7d" agent=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since=*) since="${1#*=}" ;;
      --agent=*) agent="${1#*=}" ;;
      --json)    JSON_MODE=1 ;;
      -*)        fail "$E_USAGE" "unknown flag: $1" ;;
      *)         fail "$E_USAGE" "unknown argument: $1" ;;
    esac; shift
  done
  local since_sql; since_sql=$(_run_since_sql "$since")
  local where="r.started_at >= ${since_sql}"
  [[ -n "$agent" ]] && where+=" AND r.agent=$(sqlq "$agent")"
  # One pass, one row. Definitions, stated because a metric whose definition is
  # implicit is a metric two readers will disagree about:
  #   total          — attempts that STARTED in the window (running ones included)
  #   settled        — attempts that reached a boundary; the denominator of every rate
  #   success        — settled AND status='completed' (parked/abandoned are neither)
  #   first_attempt  — completed runs with attempt=1: the fleet got it right first go
  #   rejected       — runs whose outcome was a verifier bounce
  #   human          — runs that required a person at any point
  #   stuck          — still 'running' with no event for 6h; the overnight question
  local j
  j=$(dbfmt -json "
    SELECT
      (SELECT COUNT(*) FROM runs r WHERE ${where}) AS total,
      (SELECT COUNT(*) FROM runs r WHERE ${where} AND r.status<>'running') AS settled,
      (SELECT COUNT(*) FROM runs r WHERE ${where} AND r.status='completed') AS completed,
      (SELECT COUNT(*) FROM runs r WHERE ${where} AND r.status='abandoned') AS abandoned,
      (SELECT COUNT(*) FROM runs r WHERE ${where} AND r.status='parked') AS parked,
      (SELECT COUNT(*) FROM runs r WHERE ${where} AND r.status='completed' AND r.attempt=1) AS first_attempt_ok,
      (SELECT COUNT(*) FROM runs r WHERE ${where} AND r.outcome='verifier_rejected') AS verifier_rejected,
      (SELECT COUNT(*) FROM runs r WHERE ${where} AND r.retry_of IS NOT NULL) AS retries,
      (SELECT COUNT(*) FROM runs r WHERE ${where} AND r.human_touch=1) AS human_touched,
      (SELECT COUNT(*) FROM runs r WHERE ${where} AND r.status='running'
          AND r.started_at < datetime('now','-6 hours')) AS stuck,
      (SELECT CAST(AVG((julianday(r.ended_at)-julianday(r.started_at))*86400) AS INTEGER)
         FROM runs r WHERE ${where} AND r.ended_at IS NOT NULL) AS mean_duration_s;")
  [[ -n "$j" ]] || j='[{}]'
  if (( JSON_MODE )); then
    ok "" '($j|fromjson)[0] + {window:$w}' --arg j "$j" --arg w "$since"; return 0
  fi
  local total settled completed first rej retries human stuck dur abandoned parked
  read -r total settled completed abandoned parked first rej retries human stuck dur < <(
    printf '%s' "$j" | jq -r '.[0] | [(.total//0),(.settled//0),(.completed//0),(.abandoned//0),
                                      (.parked//0),(.first_attempt_ok//0),(.verifier_rejected//0),
                                      (.retries//0),(.human_touched//0),(.stuck//0),
                                      (.mean_duration_s//"")] | @tsv')
  _run_rate() { # <numerator> <denominator>
    (( ${2:-0} > 0 )) || { printf 'NO DATA'; return 0; }
    printf '%s%% (%s/%s)' "$(( $1 * 100 / $2 ))" "$1" "$2"
  }
  echo "runs — last ${since}${agent:+ · agent ${agent}}"
  echo "  attempts started        ${total}"
  echo "  settled                 ${settled}  (completed ${completed} · abandoned ${abandoned} · parked ${parked})"
  echo "  success rate            $(_run_rate "$completed" "$settled")"
  echo "  first-attempt success   $(_run_rate "$first" "$settled")"
  echo "  verifier rejection rate $(_run_rate "$rej" "$settled")"
  echo "  retries opened          ${retries}"
  echo "  human touches           $(_run_rate "$human" "$settled")"
  echo "  stuck (>6h, no close)   ${stuck}"
  echo "  mean duration           $([[ -n "$dur" ]] && _run_dur "$dur" || printf 'NO DATA')"
  echo
  echo "  Token and dollar figures are deliberately absent: they belong to run_usage,"
  echo "  where each datum carries its own provenance. See 5dive run show <id>."
}

cmd_run() {
  tasks_db_init
  local sub="${1:-ls}"; [[ $# -gt 0 ]] && shift
  case "$sub" in
    ls|list)   cmd_run_ls "$@" ;;
    show)      cmd_run_show "$@" ;;
    events)    cmd_run_events "$@" ;;
    logs)      cmd_run_logs "$@" ;;
    retry)     cmd_run_retry "$@" ;;
    metrics)   cmd_run_metrics "$@" ;;
    -h|--help|help) _run_usage ;;
    *)         _run_usage; fail "$E_USAGE" "unknown run subcommand: ${sub}" ;;
  esac
}
