# -------- 5dive agent proactive (DIVE-8718) --------
#
# lodar 2026-11-18, "like Muse": an agent may message its owner FIRST, unasked,
# when something is worth it. Per agent, three levels:
#
#   off    (the default)  nothing changes: the agent only answers.
#   little                one check-in loop, twice a day; at most 1 message a day.
#   more                  the same loop, four times a day; at most 3 messages a day.
#
#   5dive agent proactive <name> [--json]                 status (the app's sheet)
#   5dive agent proactive <name> off|little|more          set the level
#   5dive agent proactive <name> claim --text="<msg>"     the check-in run asks to send ONE message
#   5dive agent proactive <name> reaction acted|not-now   how the owner took the last one
#
# THE LOOP. Turning it on makes ONE scheduled task for that agent, titled
# "Check in with you", visible in Tasks > Loops like any loop, with
# self-improving on (DIVE-8692). Off parks that task (kept, so the text it has
# learned survives); on again un-parks the same one.
#
# THE CAP LIVES HERE, NOT IN THE LOOP TEXT. The improver may rewrite the loop's
# text (it can never widen it, but the cap must not depend on that), so the
# daily cap is enforced twice, both outside the text:
#   1. `claim` refuses once today's messages reach the level's cap, so a run
#      that follows its text cannot get a yes;
#   2. the scheduler (src/cmd_heartbeat.sh) does not even start a check-in run
#      once today's cap is used, so there is no run to send anything.
#
# THE SCORE. The owner's reaction to each message (acted on it, said not now, or
# no answer) is fed to the loop's grade by the runtime (src/task/improve.sh,
# _loop_improve_runtime_note), and the loop's criteria name it, so
# self-improving learns what this owner wants.
#
# State (task_prefs, no schema change):
#   proactive.agent.<name>   {"level","tid","loop","set_at","set_by"}
#   proactive.tpl.<ident>    <name>   (the reverse map the grader reads)
#   proactive.log.<name>     [ {"at","day","text","reaction","reaction_at"} … ]  last 30
# A "day" is the box's local calendar day (the zone the loop's schedule reads).

_PROACTIVE_TITLE="Check in with you"
_PROACTIVE_LOG_KEEP=30

_proactive_cap() { case "$1" in little) echo 1 ;; more) echo 3 ;; *) echo 0 ;; esac; }
_proactive_hours() { case "$1" in more) echo "9,13,17,21" ;; *) echo "9,17" ;; esac; }
_proactive_sched() { printf '0 %s * * *' "$(_proactive_hours "$1")"; }
_proactive_tz() { local tz; tz=$(_task_box_tz 2>/dev/null) || tz=UTC; printf '%s' "${tz:-UTC}"; }
_proactive_today() { TZ="$(_proactive_tz)" date +%F; }

_proactive_pref_get() { db "SELECT value FROM task_prefs WHERE key=$(sqlq "$1");" 2>/dev/null; }
_proactive_pref_set() {
  db "INSERT INTO task_prefs (key, value, updated_at) VALUES ($(sqlq "$1"), $(sqlq "$2"), datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;"
}
_proactive_state() {
  local s; s=$(_proactive_pref_get "proactive.agent.$1")
  jq -e 'type=="object"' <<<"$s" >/dev/null 2>&1 && printf '%s' "$s" || printf '{}'
}
_proactive_log() {
  local s; s=$(_proactive_pref_get "proactive.log.$1")
  jq -e 'type=="array"' <<<"$s" >/dev/null 2>&1 && printf '%s' "$s" || printf '[]'
}
_proactive_level() { local l; l=$(jq -r '.level // "off"' <<<"$(_proactive_state "$1")"); printf '%s' "${l:-off}"; }
_proactive_sent_today() {
  jq --arg d "$(_proactive_today)" '[.[] | select(.day == $d)] | length' <<<"$(_proactive_log "$1")"
}

# Only the agent itself or root (the app runs over the exec rail as root) may
# change the level or claim a send for it. A teammate cannot spend another
# agent's messages, and cannot switch another agent on.
_proactive_authorize() {
  local name="$1" u
  [[ "$EUID" == "0" ]] && return 0
  u=$(_loop_seat_user "$name" 2>/dev/null) || u=""
  [[ -n "$u" && "$(id -un)" == "$u" ]] && return 0
  fail "$E_PERMISSION" "only ${name} itself or root may change ${name}'s proactive level"
}

# The loop's text: what every check-in run is told to do. Its limits sit in
# sentences the improver may not edit (DIVE-8692: a sentence with a limit word
# is read-only), and the cap does not depend on them anyway.
_proactive_body() {
  local name="$1"
  cat <<EOF
Check in with your owner. Look at what you know: your memory, your open tasks and loops (5dive task ls --mine, 5dive task ls --recurring), and the sites you are connected to.

First, if your owner answered your last check-in message, record how they took it: 5dive agent proactive ${name} reaction acted (they used it) or 5dive agent proactive ${name} reaction not-now (they waved it off).

Then decide if ONE thing is worth their attention now: something that needs them, a result they were waiting for, a problem you found, or one useful idea that fits what they care about. If nothing is worth it, send nothing. A quiet day is a good day.

If something is worth it, ask first: 5dive agent proactive ${name} claim --text="<the message>". Only if it says yes, send that message to your owner where you normally talk to them. If it refuses, send nothing.

The message: at most 40 words, plain words, no task numbers. If you offer to do something, ask; do not do it. Never spend money, post, or contact anyone new without your owner's Approve.

Close this task with: 5dive task done <this task> --result="sent: <the message>" or --result="nothing worth saying".
EOF
}

# Fixed criteria (the template's acceptance_criteria), so every run is graded on
# the same scale and the owner's reaction is one of them.
_proactive_criteria() {
  cat <<'EOF'
The owner acted on the last message it sent; a "not now" or no answer scores low
It sent nothing when nothing needed the owner, and never a filler message
A message it sent was short, plain and about one thing the owner cares about
It recorded the owner's reaction to its last message before deciding
EOF
}

# <name> -> the template's id when the agent has a live check-in loop, else ''.
_proactive_tid() {
  local tid; tid=$(jq -r '.tid // empty' <<<"$(_proactive_state "$1")")
  [[ "$tid" =~ ^[0-9]+$ ]] || return 0
  db "SELECT id FROM tasks WHERE id=${tid} AND kind='recurring' AND status NOT IN ('done','cancelled');"
}

# The next check, as UTC ISO, or '' when off. A day whose cap is used has no
# more runs (the scheduler skips them), so its next check is tomorrow's first.
_proactive_next_check() {
  local level="$1" capped="$2" tz h day now_ep ep
  [[ "$level" == "off" ]] && return 0
  tz=$(_proactive_tz); now_ep=$(date +%s)
  for day in 0 1; do
    (( day == 0 && capped )) && continue
    local hours; hours=$(_proactive_hours "$level")
    for h in ${hours//,/ }; do
      ep=$(TZ="$tz" date -d "$(TZ="$tz" date -d "+${day} day" +%F) ${h}:00" +%s 2>/dev/null) || continue
      if (( ep > now_ep )); then date -u -d "@${ep}" +%Y-%m-%dT%H:%M:%SZ; return 0; fi
    done
  done
}

_proactive_status_json() {
  local name="$1" level tid="" loop="" sent cap capped=0 last improving=false
  level=$(_proactive_level "$name")
  tid=$(_proactive_tid "$name")
  [[ -n "$tid" ]] && loop=$(db "SELECT ident FROM tasks WHERE id=${tid};")
  [[ -n "$loop" && "$(_proactive_pref_get "loop.improve.${loop}")" == "on" ]] && improving=true
  sent=$(_proactive_sent_today "$name"); cap=$(_proactive_cap "$level")
  (( cap > 0 && sent >= cap )) && capped=1
  last=$(jq -c 'last // null | if . == null then null else {at, reaction: (.reaction // null)} end' <<<"$(_proactive_log "$name")")
  jq -cn --arg n "$name" --arg l "$level" --arg loop "$loop" --argjson s "$sent" --argjson c "$cap" \
        --arg nx "$(_proactive_next_check "$level" "$capped")" --arg h "$(_proactive_hours "$level")" \
        --arg tz "$(_proactive_tz)" --argjson last "$last" \
        --argjson on "$improving" '
    {agent:$n, level:$l, loop:(if $loop == "" then null else $loop end),
     self_improving:$on, sent_today:$s, cap:$c,
     checks_per_day:(if $l == "off" then 0 else ($h | split(",") | length) end),
     next_check:(if $nx == "" then null else $nx end), tz:$tz, last_message:$last}'
}

_proactive_status() {
  local name="$1" view
  view=$(_proactive_status_json "$name")
  if (( JSON_MODE )); then
    jq -c '{ok:true, data:.}' <<<"$view"
    return 0
  fi
  jq -r '
    if .level == "off" then "\(.agent): Proactive · Off — only answers, never messages first"
    else "\(.agent): Proactive · \(if .level == "more" then "More" else "A little" end) — checks in \(.checks_per_day) times a day · \(.sent_today) of \(.cap) today · next check \(.next_check // "-") · loop \(.loop // "-")" end' <<<"$view"
}

# Make, resume or re-time the agent's check-in loop. Echoes its id.
_proactive_loop_on() {
  local name="$1" level="$2" actor="$3" tid sched tz
  sched=$(_proactive_sched "$level"); tz=$(_proactive_tz)
  tid=$(_proactive_tid "$name")
  if [[ -n "$tid" ]]; then
    # The same task: keep its text (whatever it has learned) and its history.
    db "UPDATE tasks SET schedule=$(sqlq "$sched"), schedule_tz=$(sqlq "$tz"),
          parked_at=NULL, park_reason=NULL, wake_at=NULL,
          status=CASE WHEN status='blocked' AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${tid})
                      THEN 'todo' ELSE status END
        WHERE id=${tid};"
  else
    tid=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, schedule, schedule_tz,
                                 status, fresh, project_key, acceptance_criteria)
              VALUES ($(sqlq "$_PROACTIVE_TITLE"), $(sqlq "$(_proactive_body "$name")"), 'low',
                      $(sqlq "$name"), $(sqlq "$name"), 'recurring', $(sqlq "$sched"), $(sqlq "$tz"),
                      'todo', 1, 'dive', $(sqlq "$(_proactive_criteria)"));
              SELECT last_insert_rowid();")
  fi
  local ident; ident=$(db "SELECT ident FROM tasks WHERE id=${tid};")
  _proactive_pref_set "proactive.tpl.${ident}" "$name"
  _proactive_pref_set "loop.improve.${ident}" on
  printf '%s' "$tid"
}

_proactive_set() {
  local name="$1" level="$2" actor tid="" ident="" prev
  _proactive_authorize "$name"
  actor=$(task_actor "" 2>/dev/null) || actor=""
  prev=$(_proactive_level "$name")
  if [[ "$level" == "off" ]]; then
    tid=$(_proactive_tid "$name")
    if [[ -n "$tid" ]]; then
      # Paused, not deleted: on again resumes this task with its learned text.
      db "UPDATE tasks SET status='blocked', parked_at=datetime('now'), wake_at=NULL,
            park_reason='Proactive is off. Turn it on: 5dive agent proactive ${name} little'
          WHERE id=${tid} AND status NOT IN ('done','cancelled')
            AND (need_type IS NULL OR need_answered_at IS NOT NULL);"
    fi
  else
    tid=$(_proactive_loop_on "$name" "$level" "$actor")
  fi
  [[ -n "$tid" ]] && ident=$(db "SELECT ident FROM tasks WHERE id=${tid};")
  _proactive_pref_set "proactive.agent.${name}" "$(jq -cn --arg l "$level" --arg t "$tid" --arg i "$ident" \
      --arg a "${actor:-}" --arg at "$(db "SELECT datetime('now');")" \
      '{level:$l, tid:(if $t == "" then null else ($t|tonumber) end), loop:(if $i == "" then null else $i end), set_at:$at, set_by:$a}')"
  local msg
  case "$level" in
    off)    msg="${name}: Proactive · Off — it only answers now${ident:+ (loop ${ident} paused, kept)}" ;;
    little) msg="${name}: Proactive · A little — checks in twice a day, at most 1 message a day (loop ${ident})" ;;
    more)   msg="${name}: Proactive · More — checks in 4 times a day, at most 3 messages a day (loop ${ident})" ;;
  esac
  ok "$msg" '{agent:$n, level:$l, previous:$p, loop:(if $i == "" then null else $i end), cap:($c|tonumber)}' \
     --arg n "$name" --arg l "$level" --arg p "$prev" --arg i "$ident" --arg c "$(_proactive_cap "$level")"
}

# The check-in run asks before it sends. Yes = the message is counted now (a
# send that then fails still spends it: the cap errs toward fewer messages).
_proactive_claim() {
  local name="$1"; shift
  local text=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --text=*) text="${1#*=}" ;;
      *) fail "$E_USAGE" "usage: 5dive agent proactive ${name} claim --text=\"<the message>\"" ;;
    esac
    shift
  done
  [[ -n "${text//[[:space:]]/}" ]] || fail "$E_USAGE" "usage: 5dive agent proactive ${name} claim --text=\"<the message>\""
  _proactive_authorize "$name"
  local level cap sent
  # One claim at a time per box: two runs racing must not both get the last slot.
  local lock="${TASKS_DIR:-/tmp}/.proactive-${name}.lock"
  # (A bare `exec {fd}>>f 2>/dev/null` would also send this shell's stderr to
  # /dev/null for good, and every refusal below would print nothing.)
  local _pfd=""
  { exec {_pfd}>>"$lock"; } 2>/dev/null || _pfd=""
  [[ -n "$_pfd" ]] && { flock -w 10 "$_pfd" 2>/dev/null || true; }
  level=$(_proactive_level "$name"); cap=$(_proactive_cap "$level"); sent=$(_proactive_sent_today "$name")
  if [[ "$level" == "off" ]]; then
    [[ -n "${_pfd:-}" ]] && exec {_pfd}>&-
    fail "$E_VALIDATION" "no: Proactive is off for ${name}. Send nothing."
  fi
  if (( sent >= cap )); then
    [[ -n "${_pfd:-}" ]] && exec {_pfd}>&-
    fail "$E_VALIDATION" "no: ${name} already sent ${sent} of ${cap} today. Send nothing."
  fi
  local log; log=$(_proactive_log "$name")
  log=$(jq -c --arg at "$(db "SELECT datetime('now');")" --arg d "$(_proactive_today)" --arg t "$text" --argjson k "$_PROACTIVE_LOG_KEEP" \
        '. + [{at:$at, day:$d, text:$t, reaction:null}] | .[-$k:]' <<<"$log")
  _proactive_pref_set "proactive.log.${name}" "$log"
  [[ -n "${_pfd:-}" ]] && exec {_pfd}>&-
  ok "yes: send it now, where you normally talk to your owner ($((sent + 1)) of ${cap} today)" \
     '{agent:$n, allowed:true, sent_today:($s|tonumber), cap:($c|tonumber)}' \
     --arg n "$name" --arg s "$((sent + 1))" --arg c "$cap"
}

# How the owner took the latest message. The app's buttons call it (Draft it =
# acted, Not now = not-now), and so does the next check-in run.
_proactive_reaction() {
  local name="$1" r="${2:-}"
  case "$r" in
    acted) ;; not-now|not_now|notnow) r="not-now" ;;
    *) fail "$E_USAGE" "usage: 5dive agent proactive ${name} reaction acted|not-now" ;;
  esac
  _proactive_authorize "$name"
  local log; log=$(_proactive_log "$name")
  [[ "$(jq 'length' <<<"$log")" != "0" ]] || fail "$E_VALIDATION" "${name} has not sent a check-in message yet"
  log=$(jq -c --arg r "$r" --arg at "$(db "SELECT datetime('now');")" '.[-1].reaction = $r | .[-1].reaction_at = $at' <<<"$log")
  _proactive_pref_set "proactive.log.${name}" "$log"
  ok "${name}: recorded \"${r}\" for the last check-in message" '{agent:$n, reaction:$r}' --arg n "$name" --arg r "$r"
}

cmd_agent_proactive() {
  tasks_db_init
  local name="" verb="" rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) JSON_MODE=1 ;;
      -h|--help) verb=help ;;
      *) if [[ -z "$name" ]]; then name="$1"
         elif [[ -z "$verb" ]]; then verb="$1"
         else rest+=("$1"); fi ;;
    esac
    shift
  done
  if [[ "$verb" == "help" || -z "$name" ]]; then
    cat <<'HELP'
5dive agent proactive <name> [--json]                 Off / A little / More, messages today, next check
5dive agent proactive <name> off|little|more          off (default): only answers. little: checks in twice
                                                      a day, at most 1 message a day. more: 4 checks a day,
                                                      at most 3 messages. On = one self-improving loop,
                                                      "Check in with you"; off pauses it (kept).
5dive agent proactive <name> claim --text="<msg>"     a check-in run asks before it sends; refused at the cap
5dive agent proactive <name> reaction acted|not-now   how the owner took the last message (feeds its score)
HELP
    [[ -n "$name" ]] && return 0
    fail "$E_USAGE" "name the agent: 5dive agent proactive <name> [off|little|more]"
  fi
  name="${name#agent-}"
  [[ "$name" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || fail "$E_VALIDATION" "not an agent name: $name"
  if [[ -z "${FIVEDIVE_PROACTIVE_NO_ROSTER:-}" ]] && declare -F _task_roster_has >/dev/null 2>&1; then
    _task_roster_has "$name" || fail "$E_NOT_FOUND" "no agent named ${name} on this box"
  fi
  case "$verb" in
    ""|status)          _proactive_status "$name" ;;
    off|more)           _proactive_set "$name" "$verb" ;;
    little|a-little)    _proactive_set "$name" little ;;
    claim)              _proactive_claim "$name" "${rest[@]}" ;;
    reaction)           _proactive_reaction "$name" "${rest[@]}" ;;
    *) fail "$E_USAGE" "unknown: $verb (try: off|little|more|claim|reaction, or nothing for the status)" ;;
  esac
}
