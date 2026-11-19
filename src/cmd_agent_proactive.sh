# -------- 5dive agent proactive (DIVE-8718) --------
#
# lodar 2026-11-18, "like Muse": an agent may message its owner FIRST, unasked,
# when something is worth it. Per agent, three levels, shown as Normal / High /
# Very high (DIVE-8767, lodar 11-19: never "Off", since every agent already answers,
# reports back and asks). The arguments stay off|little|more:
#
#   off    Normal (the default)  nothing changes: answers and reports back, as usual.
#   little High                  one check-in loop, twice a day; at most 1 message a day.
#   more   Very high             the same loop, four times a day; at most 3 messages a day.
#
#   5dive agent proactive <name> [--json]                 status (the app's sheet)
#   5dive agent proactive <name> off|little|more          set the level
#   5dive agent proactive <name> claim --text="<msg>"     the check-in run asks to send ONE message
#   5dive agent proactive <name> reaction acted|not-now   how the owner took the last one
#   5dive agent proactive <name> offer yes|not-now        the owner's answer to a level-up offer
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
#   proactive.offer.<name>   {"at","from","to","acted","sent","answer","answer_at"}  the latest offer
#   proactive.seeded.<name>  {"at","atoms","why"}   day-one memory seed, done once
#
# TRUST GROWS WITH TRACK RECORD (DIVE-8838, lodar 11-19, from LangChain's "What
# we've learned building proactive agents"):
#   - acted_last_10 in the status: of its last 10 messages, how many the owner
#     acted on.
#   - THE OFFER. Once at least 8 of the last 10 were acted on and the level is
#     not Very high, the next `claim` yes carries ONE offer line ("You acted on 8
#     of my last 10. Want me to message you a bit more (Very high)?"). It rides
#     that message, so it spends no extra one and the daily cap holds. One offer
#     per 30 days: Not now, or no answer, means none for 30 days.
#   - ONLY THE OWNER'S TAP RAISES THE LEVEL. Raising it is root-only (the app,
#     over the exec rail), and so is `offer yes`. The agent may lower its own
#     level or record a Not now, never raise it. So no loop text, learned or
#     rewritten (DIVE-8692), can add or trigger an offer the CLI did not make:
#     `offer yes` needs the open offer `claim` recorded. Going down stays
#     automatic and silent (self-improving grades a low act rate); no prompt.
#   - DAY-ONE MEMORY. The first time the level is raised above Normal for an
#     agent that knows little of its owner (under 3 owner facts), it is seeded
#     once from this box: the owner's name, the job the owner gave it at hire,
#     and owner facts (type user) the owner's other agents here already hold.
#     Each seeded fact is marked (seeded: proactive, low confidence, a valid_to)
#     so memory consolidation can expire or replace it. Never copied: anything
#     that looks like a secret, task content (an ident like DIVE-12), customer or
#     client facts, another owner's agents' facts, or a fact that was itself seeded.
# A "day" is the box's local calendar day (the zone the loop's schedule reads).

_PROACTIVE_TITLE="Check in with you"
_PROACTIVE_LOG_KEEP=30
_PROACTIVE_OFFER_DAYS=30
_PROACTIVE_OFFER_MIN_ACTED=8
_PROACTIVE_SEED_MAX=12
_PROACTIVE_SEED_KEEP_DAYS=60

_proactive_is_root() { [[ "$EUID" == "0" ]]; }   # seam: harnesses drive it
_proactive_rank() { case "$1" in more) echo 2 ;; little) echo 1 ;; *) echo 0 ;; esac; }
_proactive_label() { case "$1" in more) echo "Very high" ;; little) echo "High" ;; *) echo "Normal" ;; esac; }
_proactive_next_level() { case "$1" in off) echo little ;; little) echo more ;; *) echo "" ;; esac; }
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
_proactive_offer_state() {
  local s; s=$(_proactive_pref_get "proactive.offer.$1")
  jq -e 'type=="object"' <<<"$s" >/dev/null 2>&1 && printf '%s' "$s" || printf '{}'
}
# Of the last 10 messages, how many the owner acted on: {"acted":n,"sent":m}.
_proactive_acted_last10() {
  jq -c '.[-10:] | {acted: (map(select(.reaction == "acted")) | length), sent: length}' <<<"$(_proactive_log "$1")"
}
# rc 0 when <sqlite datetime> is less than <days> days ago.
_proactive_within_days() {
  [[ -n "$1" ]] || return 1
  [[ "$(db "SELECT CASE WHEN julianday('now') - julianday($(sqlq "$1")) < $2 THEN 1 ELSE 0 END;")" == "1" ]]
}
# The level an offer may go to now, or '' (THE CLI'S RULE, the only place an
# offer is made): a full window of 10 sent, at least 8 acted on, a level with a
# next one, and no offer in the last 30 days, whatever its answer was.
_proactive_offer_due() {
  local name="$1" level="$2" to a10 acted sent last_at
  [[ "$level" == "off" ]] && return 0
  to=$(_proactive_next_level "$level"); [[ -n "$to" ]] || return 0
  a10=$(_proactive_acted_last10 "$name")
  acted=$(jq -r .acted <<<"$a10"); sent=$(jq -r .sent <<<"$a10")
  (( sent >= 10 && acted >= _PROACTIVE_OFFER_MIN_ACTED )) || return 0
  last_at=$(jq -r '.at // empty' <<<"$(_proactive_offer_state "$name")")
  _proactive_within_days "$last_at" "$_PROACTIVE_OFFER_DAYS" && return 0
  printf '%s' "$to"
}
_proactive_offer_line() { # <acted> <to>
  printf 'You acted on %s of my last 10. Want me to message you a bit more (%s)?' "$1" "$(_proactive_label "$2")"
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
  _proactive_is_root && return 0
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

Then decide if ONE thing is worth their attention now: a result they were waiting for, a problem you found, or one useful idea that fits what they care about. Their asks and approvals already reach them, so never repeat one here. If nothing is worth it, send nothing. A quiet day is a good day.

If something is worth it, ask first: 5dive agent proactive ${name} claim --text="<the message>". Only if it says yes, send that message to your owner where you normally talk to them. If it refuses, send nothing.

Only when that yes gives you an offer line, end the message with it, word for word. Never offer to message more on your own, and never raise your own level: only your owner's Yes tap can. If your owner said no to an offer, record it: 5dive agent proactive ${name} offer not-now.

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
  local offer seeded
  offer=$(jq -c 'if .at then {at, from, to, line, answer: (.answer // null), answer_at: (.answer_at // null)} else null end' \
          <<<"$(_proactive_offer_state "$name")")
  seeded=$(_proactive_pref_get "proactive.seeded.${name}")
  jq -e 'type=="object"' <<<"$seeded" >/dev/null 2>&1 || seeded=null
  jq -cn --arg n "$name" --arg l "$level" --arg loop "$loop" --argjson s "$sent" --argjson c "$cap" \
        --arg nx "$(_proactive_next_check "$level" "$capped")" --arg h "$(_proactive_hours "$level")" \
        --arg tz "$(_proactive_tz)" --argjson last "$last" \
        --argjson a10 "$(_proactive_acted_last10 "$name")" --argjson offer "$offer" --argjson seeded "$seeded" \
        --argjson on "$improving" '
    {agent:$n, level:$l, loop:(if $loop == "" then null else $loop end),
     self_improving:$on, sent_today:$s, cap:$c,
     checks_per_day:(if $l == "off" then 0 else ($h | split(",") | length) end),
     next_check:(if $nx == "" then null else $nx end), tz:$tz, last_message:$last,
     acted_last_10:$a10, offer:$offer, seeded:$seeded}'
}

_proactive_status() {
  local name="$1" view
  view=$(_proactive_status_json "$name")
  if (( JSON_MODE )); then
    jq -c '{ok:true, data:.}' <<<"$view"
    return 0
  fi
  jq -r '
    if .level == "off" then "\(.agent): Proactive · Normal — answers and reports back, as usual; never messages first"
    else "\(.agent): Proactive · \(if .level == "more" then "Very high" else "High" end) — checks in \(.checks_per_day) times a day · \(.sent_today) of \(.cap) today · acted on \(.acted_last_10.acted) of the last \(.acted_last_10.sent) · next check \(.next_check // "-") · loop \(.loop // "-")" end' <<<"$view"
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
  # Only the owner raises it: the app (root, over the exec rail) or the offer's
  # Yes tap (`offer yes`, root). The agent may lower or keep its own level.
  if (( $(_proactive_rank "$level") > $(_proactive_rank "$prev") )) && ! _proactive_is_root; then
    fail "$E_PERMISSION" "no: only your owner can raise ${name}'s Proactive level (a tap in the app, or Yes on an offer). It stays $(_proactive_label "$prev")."
  fi
  if [[ "$level" == "off" ]]; then
    tid=$(_proactive_tid "$name")
    if [[ -n "$tid" ]]; then
      # Paused, not deleted: on again resumes this task with its learned text.
      db "UPDATE tasks SET status='blocked', parked_at=datetime('now'), wake_at=NULL,
            park_reason='Proactive is at Normal. Raise it: 5dive agent proactive ${name} little'
          WHERE id=${tid} AND status NOT IN ('done','cancelled')
            AND (need_type IS NULL OR need_answered_at IS NOT NULL);"
    fi
  else
    tid=$(_proactive_loop_on "$name" "$level" "$actor")
    # Day one: the first check-in already knows the owner. Never fails the set.
    [[ -z "$(_proactive_pref_get "proactive.seeded.${name}")" ]] && { _proactive_seed "$name" || true; }
  fi
  [[ -n "$tid" ]] && ident=$(db "SELECT ident FROM tasks WHERE id=${tid};")
  _proactive_pref_set "proactive.agent.${name}" "$(jq -cn --arg l "$level" --arg t "$tid" --arg i "$ident" \
      --arg a "${actor:-}" --arg at "$(db "SELECT datetime('now');")" \
      '{level:$l, tid:(if $t == "" then null else ($t|tonumber) end), loop:(if $i == "" then null else $i end), set_at:$at, set_by:$a}')"
  local msg
  case "$level" in
    off)    msg="${name}: Proactive · Normal — it answers and reports back, as usual${ident:+ (loop ${ident} paused, kept)}" ;;
    little) msg="${name}: Proactive · High — checks in twice a day, at most 1 message a day (loop ${ident})" ;;
    more)   msg="${name}: Proactive · Very high — checks in 4 times a day, at most 3 messages a day (loop ${ident})" ;;
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
    fail "$E_VALIDATION" "no: Proactive is at Normal for ${name}: no check-in messages. Send nothing."
  fi
  if (( sent >= cap )); then
    [[ -n "${_pfd:-}" ]] && exec {_pfd}>&-
    fail "$E_VALIDATION" "no: ${name} already sent ${sent} of ${cap} today. Send nothing."
  fi
  # The offer is decided on the 10 messages BEFORE this one, and rides it.
  local now to line="" acted=0
  now=$(db "SELECT datetime('now');")
  to=$(_proactive_offer_due "$name" "$level")
  if [[ -n "$to" ]]; then
    acted=$(jq -r .acted <<<"$(_proactive_acted_last10 "$name")")
    line=$(_proactive_offer_line "$acted" "$to")
    _proactive_pref_set "proactive.offer.${name}" "$(jq -cn --arg at "$now" --arg f "$level" --arg t "$to" \
        --argjson a "$acted" --arg line "$line" \
        '{at:$at, from:$f, to:$t, acted:$a, sent:10, line:$line, answer:null, answer_at:null}')"
  fi
  local log; log=$(_proactive_log "$name")
  log=$(jq -c --arg at "$now" --arg d "$(_proactive_today)" --arg t "$text" --argjson k "$_PROACTIVE_LOG_KEEP" \
        --arg o "$to" '. + [{at:$at, day:$d, text:$t, reaction:null} + (if $o == "" then {} else {offer:$o} end)] | .[-$k:]' <<<"$log")
  _proactive_pref_set "proactive.log.${name}" "$log"
  [[ -n "${_pfd:-}" ]] && exec {_pfd}>&-
  local say="yes: send it now, where you normally talk to your owner ($((sent + 1)) of ${cap} today)"
  [[ -n "$line" ]] && say+=$'\n'"End the message with this line, word for word (your owner answers Yes or Not now): ${line}"
  ok "$say" \
     '{agent:$n, allowed:true, sent_today:($s|tonumber), cap:($c|tonumber),
       offer:(if $line == "" then null else {line:$line, to:$to, label:$lb} end)}' \
     --arg n "$name" --arg s "$((sent + 1))" --arg c "$cap" --arg line "$line" --arg to "$to" \
     --arg lb "$(_proactive_label "${to:-off}")"
}

# The owner's answer to the latest offer. Yes is root-only (the app's tap, or a
# relay of the owner's tap) and goes through the same set verb; Not now may also
# be recorded by the agent, since it can only keep the level where it is.
_proactive_offer() {
  local name="$1" a="${2:-}"
  case "$a" in
    yes) ;; not-now|not_now|notnow|no) a="not-now" ;;
    *) fail "$E_USAGE" "usage: 5dive agent proactive ${name} offer yes|not-now" ;;
  esac
  _proactive_authorize "$name"
  local o level
  o=$(_proactive_offer_state "$name"); level=$(_proactive_level "$name")
  if [[ "$(jq -r '.at // empty' <<<"$o")" == "" || "$(jq -r '.answer // empty' <<<"$o")" != "" ]] \
     || ! _proactive_within_days "$(jq -r '.at' <<<"$o")" "$_PROACTIVE_OFFER_DAYS"; then
    fail "$E_VALIDATION" "no open offer for ${name}: nothing changed"
  fi
  if [[ "$a" == "yes" ]]; then
    _proactive_is_root || fail "$E_PERMISSION" "no: only your owner's Yes tap can raise ${name}'s level. It stays $(_proactive_label "$level")."
    [[ "$level" == "$(jq -r .from <<<"$o")" ]] \
      || fail "$E_VALIDATION" "the offer was made at $(_proactive_label "$(jq -r .from <<<"$o")"); ${name} is at $(_proactive_label "$level") now: nothing changed"
  fi
  _proactive_pref_set "proactive.offer.${name}" "$(jq -c --arg a "$a" --arg at "$(db "SELECT datetime('now');")" \
      '.answer = $a | .answer_at = $at' <<<"$o")"
  if [[ "$a" == "yes" ]]; then
    _proactive_set "$name" "$(jq -r .to <<<"$o")"
    return
  fi
  ok "${name}: offer declined; it stays $(_proactive_label "$level") and will not ask again for ${_PROACTIVE_OFFER_DAYS} days" \
     '{agent:$n, answer:"not-now", level:$l}' --arg n "$name" --arg l "$level"
}

# -------- day-one memory (DIVE-8838) --------
# Seams: harnesses point these at a throwaway tree.
_proactive_home() {
  local h=""
  if [[ -n "${AGENT_HOME_ROOT:-}" ]]; then printf '%s/agent-%s' "$AGENT_HOME_ROOT" "$1"; return 0; fi
  h=$(getent passwd "agent-$1" 2>/dev/null | cut -d: -f6) || h=""
  [[ -z "$h" && "$1" == "claude" ]] && h=$(getent passwd claude 2>/dev/null | cut -d: -f6)
  printf '%s' "${h:-/home/agent-$1}"
}
_proactive_seed_seats() { _task_roster 2>/dev/null; printf '%s\n' "${_TASK_ROSTER:-}"; }
_proactive_seed_chown() { # <name> <dir>
  local u="agent-$1"; [[ "$1" == "claude" ]] && u=claude
  _proactive_is_root && chown -R "$u":"$u" "$2" 2>/dev/null; return 0
}
_proactive_workdir() {
  local w; w=$(registry_read 2>/dev/null | jq -r --arg n "$1" '.agents[$n].workdir // empty' 2>/dev/null) || w=""
  printf '%s' "${w:-${DEFAULT_WORKDIR:-/home/claude/projects/5dive}}"
}
# The agent's memory store: the one with an index, else any, else the one its
# workdir's sessions load (made now).
_proactive_store() {
  local home d first=""
  home=$(_proactive_home "$1")
  for d in "$home"/.claude/projects/*/memory; do
    [[ -d "$d" ]] || continue
    [[ -f "$d/MEMORY.md" ]] && { printf '%s' "$d"; return 0; }
    [[ -z "$first" ]] && first="$d"
  done
  [[ -n "$first" ]] && { printf '%s' "$first"; return 0; }
  d="$home/.claude/projects/$(printf '%s' "$(_proactive_workdir "$1")" | sed 's:/:-:g')/memory"
  mkdir -p "$d" 2>/dev/null && chmod 700 "$d" && printf '%s' "$d"
}
# The human who owns <agent>'s gates, or '' (the box owner).
_proactive_owner_of() {
  db "SELECT human_id FROM human_agents WHERE agent=$(sqlq "$1") ORDER BY human_id LIMIT 1;" 2>/dev/null
}
_proactive_atom_type() { # <file> -> the type field of its frontmatter
  awk 'NR == 1 && $0 != "---" {exit} NR > 1 && $0 == "---" {exit} NR > 1 {print}' "$1" 2>/dev/null \
    | sed -n 's/^[[:blank:]]*type:[[:blank:]]*\([a-z]*\).*/\1/p' | head -1
}
_PROACTIVE_SEED_SECRET_RX='BOT_TOKEN|API_KEY|-----BEGIN|sk-[A-Za-z0-9]{8,}|[0-9]{8,}:[A-Za-z0-9_-]{30,}|password|passwd|passphrase|secret|token|api[ _-]?key|credential|private key|seed phrase|[0-9]{13,19}|iban'
_PROACTIVE_SEED_SKIP_RX='\b[A-Z][A-Z0-9]{1,9}-[0-9]+\b'
_PROACTIVE_SEED_OTHERS_RX='customer|client'
# rc 0 when <file> may be copied: an owner fact, not seeded itself, nothing
# secret, no task content, no customer's data.
_proactive_seed_ok() {
  local f="$1"
  [[ -f "$f" && ! -L "$f" ]] || return 1
  [[ "$(_proactive_atom_type "$f")" == "user" ]] || return 1
  grep -qE '^[[:blank:]]*seeded:' "$f" && return 1
  grep -qiE "$_PROACTIVE_SEED_SECRET_RX" "$f" && return 1
  grep -qE "$_PROACTIVE_SEED_SKIP_RX" "$f" && return 1
  grep -qiE "$_PROACTIVE_SEED_OTHERS_RX" "$f" && return 1
  return 0
}
_proactive_seed_write() { # <store> <slug> <from> <description> <body>
  local store="$1" slug="$2" from="$3" desc="$4" body="$5" f
  f="$store/user_seeded_$(printf '%s' "$slug" | tr '-' '_').md"
  [[ -e "$f" ]] && return 1
  { printf -- '---\nname: seeded-%s\ndescription: "%s"\nmetadata:\n  type: user\n  seeded: proactive\n  seeded_from: %s\n  compiled_at: %s\n  confidence: low\n  valid_to: %s\n  provenance: "seeded on day one by 5dive agent proactive (DIVE-8838) from what this box knew about the owner; replace it with what you learn"\n---\n\n%s\n' \
      "$slug" "$(printf '%s' "$desc" | sed 's/"/\\"/g')" "$from" "$(date -u +%F)" \
      "$(date -u -d "+${_PROACTIVE_SEED_KEEP_DAYS} days" +%F)" "$body"
  } >"$f" || return 1
  chmod 600 "$f" 2>/dev/null
  printf -- '- [seeded-%s](%s) — %s\n' "$slug" "$(basename "$f")" "$desc" >>"$store/MEMORY.md"
}
_proactive_body_of() { awk 'BEGIN{n=0} /^---$/ && n<2 {n++; next} n>=2 {print}' "$1" | sed '/./,$!d'; }
_proactive_desc_of() {
  sed -n 's/^description:[[:blank:]]*"\{0,1\}\(.*\)$/\1/p' "$1" | head -1 | sed 's/"[[:blank:]]*$//'
}

# Seed once. Records proactive.seeded.<name> whatever it found, so it never runs
# twice; root only (only root raises the level, and other seats' stores are 0600).
_proactive_seed() {
  local name="$1" store n_user=0 f seeded=0 why="" owner seat slug body desc
  _proactive_is_root || return 0
  store=$(_proactive_store "$name") || store=""
  if [[ -z "$store" ]]; then
    why="no memory store"
  else
    for f in "$store"/*.md; do
      [[ -f "$f" ]] || continue
      [[ "$(_proactive_atom_type "$f")" == "user" ]] && ! grep -qE '^[[:blank:]]*seeded:' "$f" && n_user=$((n_user + 1))
    done
    if (( n_user >= 3 )); then
      why="already knows its owner (${n_user} owner facts)"
    else
      owner=$(_proactive_owner_of "$name")
      # The owner's profile: their name, from the box's people.
      local oname
      if [[ -n "$owner" ]]; then
        oname=$(db "SELECT display_name FROM humans WHERE id=$(sqlq "$owner");" 2>/dev/null)
      else
        oname=$(db "SELECT display_name FROM humans WHERE role='owner' AND NULLIF(display_name,'') IS NOT NULL ORDER BY created_at LIMIT 1;" 2>/dev/null)
      fi
      if [[ -n "$oname" ]] && ! grep -qiE "$_PROACTIVE_SEED_SECRET_RX" <<<"$oname"; then
        _proactive_seed_write "$store" owner-name box "Your owner's name is ${oname}" \
          "Your owner's name is ${oname}. Address them by it." && seeded=$((seeded + 1))
      fi
      # The hire answer: the first job the owner gave THIS agent.
      local jf job
      for jf in "${FIRST_JOB_DIR:-$STATE_DIR/first-jobs}"/*.json; do
        [[ -f "$jf" ]] || continue
        [[ "$(jq -r '.name // empty' "$jf" 2>/dev/null)" == "$name" ]] || continue
        job=$(jq -r '.job // empty' "$jf" 2>/dev/null)
        [[ -n "$job" ]] || continue
        grep -qiE "$_PROACTIVE_SEED_SECRET_RX" <<<"$job" && continue
        _proactive_seed_write "$store" hire-first-job hire "What your owner asked you for first, when they hired you" \
          "When your owner hired you, the first thing they asked for was: ${job}" && seeded=$((seeded + 1))
        break
      done
      # Owner facts the owner's other agents on this box already hold.
      while read -r seat; do
        [[ -n "$seat" && "$seat" != "$name" ]] || continue
        (( seeded >= _PROACTIVE_SEED_MAX )) && break
        [[ "$(_proactive_owner_of "$seat")" == "$owner" ]] || continue
        local d sh; sh=$(_proactive_home "$seat")
        for d in "$sh"/.claude/projects/*/memory; do
          [[ -d "$d" ]] || continue
          for f in "$d"/*.md; do
            (( seeded >= _PROACTIVE_SEED_MAX )) && break 2
            _proactive_seed_ok "$f" || continue
            slug=$(basename "$f" .md); slug="${slug#user_}"; slug=$(printf '%s' "$slug" | tr '_A-Z' '-a-z' | tr -cd 'a-z0-9-')
            body=$(_proactive_body_of "$f"); desc=$(_proactive_desc_of "$f")
            [[ -n "${body//[[:space:]]/}" ]] || continue
            _proactive_seed_write "$store" "${slug:0:50}" "$seat" "${desc:-An owner fact from ${seat}}" "$body" \
              && seeded=$((seeded + 1))
          done
        done
      done < <(_proactive_seed_seats | awk 'NF && !seen[$0]++')
      why="seeded ${seeded} owner facts"
      _proactive_seed_chown "$name" "$store"
    fi
  fi
  _proactive_pref_set "proactive.seeded.${name}" "$(jq -cn --arg at "$(db "SELECT datetime('now');")" \
      --argjson n "$seeded" --arg w "$why" '{at:$at, atoms:$n, why:$w}')"
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
5dive agent proactive <name> [--json]                 Normal / High / Very high, messages today, next check
5dive agent proactive <name> off|little|more          off = Normal (default): answers and reports back, as
                                                      usual. little = High: checks in twice a day, at most
                                                      1 message a day. more = Very high: 4 checks a day, at
                                                      most 3 messages. High or Very high = one self-improving
                                                      loop, "Check in with you"; off pauses it (kept).
5dive agent proactive <name> claim --text="<msg>"     a check-in run asks before it sends; refused at the cap
5dive agent proactive <name> reaction acted|not-now   how the owner took the last message (feeds its score)
5dive agent proactive <name> offer yes|not-now        the owner's answer to "message you a bit more?" (offered
                                                      once 8 of the last 10 were acted on; at most every 30
                                                      days). Yes, like any raise, is the owner's tap only (root).
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
    offer)              _proactive_offer "$name" "${rest[@]}" ;;
    *) fail "$E_USAGE" "unknown: $verb (try: off|little|more|claim|reaction|offer, or nothing for the status)" ;;
  esac
}
