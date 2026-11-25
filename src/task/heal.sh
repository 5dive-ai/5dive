# -------- 5dive task — self-healing loops (DIVE-9171) --------
#
# lodar 2026-11-24: "if its broke why dont we add self healing alongside with
# self improving to the 5dive loops" — and he picked "healing by default,
# improving weekly". The case it is built against: X changed its site, the
# x-spotter collect step got 0 posts and exited 0, the digest had one stale
# item, and the seat chose "send nothing". Every step succeeded and the owner
# just got silence.
#
# Three parts, all on by default, none of them a model turn while a loop works:
#   1. RETRY. A run that fails (cancelled after it started, the DIVE-9121
#      definition) is tried ONCE more, about ${_LOOP_HEAL_RETRY_MIN} minutes later,
#      as a parked run of the same loop (the heartbeat's wake sweep unparks it).
#      Both failures count toward DIVE-9121's 3-in-a-row pause, so the pause and
#      its one message are unchanged. A retry is never retried.
#   2. SILENCE IS A FAILURE. A run that ran and had nothing for the owner closes
#      with `task done --empty`. ${_LOOP_EMPTY_TELL_AT} empty runs in a row, on a
#      loop that messages its owner, send the owner ONE plain line from that
#      seat's own bot. A run with something in it resets the count.
#      Proactive check-ins are exempt: their quiet is the designed result (DIVE-9261).
#   3. WEEKLY SELF-IMPROVING. Owner-facing loops get DIVE-8692's improver once a
#      week instead of after every run: one model turn reads the week's runs and
#      makes at most ONE change, which may only merge or drop a line, never grow
#      the text (src/task/improve.sh, _LOOP_IMPROVE_MODE=weekly). Internal loops:
#      off unless switched on.
# Per loop: `task loop heal <loop> on|off` (retry + the empty line) and
# `task loop improve <loop> weekly|off` (the weekly turn).
#
# A LAZY module like improve.sh: loops.sh calls into it by name through
# _loop_improve_call, and only when a run closed that it has something to do
# with, so `heartbeat ls` and `task ls` never parse it.
#
# State (task_prefs):
#   loop.heal.<tpl ident>             "off" | absent (= on)
#   loop.owner.<tpl ident>            "yes" | "no" | absent (= read from the loop's text)
#   loop.retry.of.<run ident>         the run this one retries
#   loop.empty.run.<run ident>        "1": that run closed with --empty
#   loop.empty.<tpl ident>            {"n","last_at","told_at","told"}
#   loop.improve.weekly.<tpl ident>   "on" | "off" | absent (= on when owner-facing)
#   loop.improve.weekly_at.<tpl ident>  when the weekly turn last ran (or the clock started)
_LOOP_HEAL_RETRY_MIN=15
_LOOP_EMPTY_TELL_AT=2
_LOOP_WEEKLY_DAYS=7
_LOOP_WEEKLY_RUNS=7
# A loop "messages its owner" when its text says so. Read once per check, from
# the title and the body; `task loop heal <loop> --owner=yes|no` overrides it.
_LOOP_OWNER_RX='owner|telegram|whatsapp|tell (me|him|her|them|the user)|send (me|him|her|them|the user)|message (me|him|her|them|the user)|notify|remind|digest|brief|morning|evening|daily (report|update|summary)|weekly (report|update|summary)|check in|check-in|report to|summary (for|to)'

_loop_heal_on() { [[ "$(_loop_pref_get "loop.heal.${1}")" != "off" ]]; }

# <tpl ident> -> rc 0 when the loop messages its owner.
_loop_owner_facing() {
  local tident="$1" v txt
  v=$(_loop_pref_get "loop.owner.${tident}")
  case "$v" in yes) return 0 ;; no) return 1 ;; esac
  [[ -n "$(_loop_pref_get "proactive.tpl.${tident}")" ]] && return 0
  txt=$(db "SELECT lower(COALESCE(title,'')||' '||COALESCE(body,'')) FROM tasks WHERE ident=$(sqlq "$tident");")
  grep -qE "(^|[^[:alpha:]])(${_LOOP_OWNER_RX})" <<<"$txt"
}

# <tpl ident> -> rc 0 when the weekly improve turn runs for this loop.
_loop_heal_weekly_on() {
  local tident="$1"
  [[ -z "$(_loop_pref_get "loop.outcome.${tident}")" ]] || return 1   # DIVE-5777: the owner picks its next lane
  case "$(_loop_pref_get "loop.improve.weekly.${tident}")" in
    on) return 0 ;; off) return 1 ;;
  esac
  _loop_owner_facing "$tident"
}

# Called by _loop_fail_tick for a failed run that did not pause the loop.
_loop_heal_retry() {  # <run id> <template id> <template ident>
  local id="$1" tid="$2" tident="$3" rident new
  _loop_heal_on "$tident" || return 0
  rident=$(db "SELECT ident FROM tasks WHERE id=${id};")
  # A retry is not retried: its failure counts, and the next slot is the next try.
  [[ -z "$(_loop_pref_get "loop.retry.of.${rident}")" ]] || return 0
  # Something of this loop is already open (the next slot fired, or a retry): no second.
  [[ "$(db "SELECT COUNT(*) FROM tasks WHERE from_template_id=${tid} AND status NOT IN ('done','cancelled');")" == "0" ]] || return 0
  new=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, from_template_id, fresh,
                               status, parked_at, wake_at, park_reason)
            SELECT p.title, p.body, p.priority, COALESCE(r.assignee, p.assignee), p.created_by, 'standard', p.id, p.fresh,
                   'blocked', datetime('now'), datetime('now', '+${_LOOP_HEAL_RETRY_MIN} minutes'),
                   $(sqlq "a retry of ${rident}, which failed; it starts by itself in about ${_LOOP_HEAL_RETRY_MIN} minutes (DIVE-9171)")
            FROM tasks p JOIN tasks r ON r.id=${id} WHERE p.id=${tid} AND p.status NOT IN ('done','cancelled');
            SELECT ident FROM tasks WHERE id=last_insert_rowid() AND from_template_id=${tid};")
  [[ -n "$new" ]] || return 0
  _loop_pref_set "loop.retry.of.${new}" "$rident"
  return 0
}

# Called by _loop_score_request for a run that closed done.
_loop_heal_empty_tick() {  # <template id> <template ident> <run ident>
  local tid="$1" tident="$2" rident="$3" st n ttitle seat text told=0
  # DIVE-9261: a proactive check-in that sent nothing did its job ("a quiet day
  # is a good day"), so quiet runs never build a "may be broken" streak. Its
  # signal is the owner's reaction score; retry and the weekly turn still run.
  if [[ -z "$(_loop_pref_get "loop.empty.run.${rident}")" || -n "$(_loop_pref_get "proactive.tpl.${tident}")" ]]; then
    # Something for the owner: the streak is over.
    _loop_pref_del "loop.empty.${tident}"; return 0
  fi
  st=$(_loop_pref_get "loop.empty.${tident}")
  jq -e 'type=="object"' <<<"$st" >/dev/null 2>&1 || st='{}'
  n=$(( $(jq -r '.n // 0' <<<"$st") + 1 ))
  st=$(jq -c --argjson n "$n" '.n=$n | .last_at=(now|todate)' <<<"$st")
  _loop_pref_set "loop.empty.${tident}" "$st"
  (( n >= _LOOP_EMPTY_TELL_AT )) || return 0
  [[ -z "$(jq -r '.told_at // ""' <<<"$st")" ]] || return 0   # one line per streak
  _loop_heal_on "$tident" && _loop_owner_facing "$tident" || return 0
  ttitle=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${tid};")
  seat=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${tid};")
  text="\"${ttitle}\" found nothing ${n} times in a row. It may be broken."
  (( n == 2 )) && text="\"${ttitle}\" found nothing twice in a row. It may be broken."
  if [[ -n "$seat" ]] && _task_agent_channel "$seat" 2>/dev/null; then
    _task_send_owner "$text" "" "" || true
    [[ "${TASK_SEND_DELIVERED:-0}" == "1" ]] && told=1
  fi
  _loop_pref_set "loop.empty.${tident}" "$(jq -c --argjson t "$told" '.told_at=(now|todate) | .told=($t == 1)' <<<"$st")"
  [[ -n "$seat" ]] || return 0
  # The seat learns it too, so it can look at the source before the next run.
  ( _5DIVE_SYSTEM_NOTICE=1 cmd_send "$seat" --from="task-engine" \
      --message="Your scheduled job ${tident} (\"${ttitle}\") closed empty ${n} times in a row; your owner was told it may be broken. Check what it reads from before its next run." ) >/dev/null 2>&1 || true
  (( told )) && return 0
  local title="Tell your owner ${tident} found nothing ${n} times"
  [[ "$(db "SELECT COUNT(*) FROM tasks WHERE title=$(sqlq "$title") AND status NOT IN ('done','cancelled');")" == "0" ]] || return 0
  ( JSON_MODE=1 cmd_task_add "$title" --materialized --review=none --fresh --from=loop \
      --assignee="$seat" --priority=high \
      --body="Your scheduled job ${tident} (\"${ttitle}\") closed empty ${n} times in a row, and the runtime could not reach your owner.

1. Send your owner this ONE line, where you normally talk to them, as it is:

${text}

2. Close this row with task done once it is sent." ) >/dev/null 2>&1 || true
  return 0
}

# Called by _loop_score_request for a run that closed done, once loops.sh has
# seen the week is up (or the clock never started). Starts the clock on first
# sight, so a loop's first week costs nothing.
_loop_heal_weekly_kick() {  # <template ident> <run ident>
  local tident="$1" rident="$2" at
  at=$(_loop_pref_get "loop.improve.weekly_at.${tident}")
  # The clock moves for every loop, improving or not, so loops.sh loads this
  # module at most once a week per loop.
  _loop_pref_set "loop.improve.weekly_at.${tident}" "$(db "SELECT datetime('now');")"
  [[ -n "$at" ]] || return 0
  [[ "$(db "SELECT julianday('now') - julianday($(sqlq "$at")) >= ${_LOOP_WEEKLY_DAYS};")" == "1" ]] || return 0
  _loop_heal_weekly_on "$tident" || return 0
  if [[ "${FIVEDIVE_LOOP_IMPROVE_SYNC:-0}" == "1" ]]; then
    ( _LOOP_IMPROVE_MODE=weekly; _loop_improve_call _loop_improve_tick "$tident" "$rident" ) >/dev/null 2>&1 || true
    return 0
  fi
  local self="${FIVEDIVE_SELF:-$(command -v 5dive || echo /usr/local/bin/5dive)}"
  ( setsid nohup "$self" task loop improve "$tident" tick --run="$rident" --weekly \
      >>"${TASKS_DIR:-/tmp}/loop-improve.log" 2>&1 </dev/null & ) 2>/dev/null || true
  return 0
}

# What the weekly turn reads: the last runs, each with how it ended, what it
# reported, its score note (an owner complaint lands there) and the owner's thumb.
_loop_heal_week_digest() {  # <template id>
  local tid="$1" rident rst res note vote out=""
  while IFS=$'\x1f' read -r rident rst res; do
    [[ -n "$rident" ]] || continue
    note=$(_loop_pref_get "loop.score.${rident}" | jq -r '.note // ""' 2>/dev/null)
    vote=$(_loop_pref_get "loop.vote.${rident}")
    [[ -n "$(_loop_pref_get "loop.empty.run.${rident}")" ]] && rst="done, found nothing"
    out+="- ${rident} (${rst}): $(_loop_clip "${res:-nothing reported}")"
    [[ -n "$note" ]] && out+=" [runtime: $(_loop_clip "$note")]"
    [[ -n "$vote" ]] && out+=" [owner: thumbs ${vote}]"
    out+=$'\n'
  done < <(db "SELECT ident||x'1f'||status||x'1f'||replace(COALESCE(result,''),char(10),' ') FROM tasks
               WHERE from_template_id=${tid} AND status IN ('done','cancelled') ORDER BY id DESC LIMIT ${_LOOP_WEEKLY_RUNS};")
  printf '%s' "$out"
}

# `task loop heal <loop> [on|off] [--owner=yes|no|auto] [--json]`
cmd_task_loop_heal() {
  tasks_db_init
  local ref="" sw="" owner=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      on|off)    sw="$1" ;;
      --owner=*) owner="${1#*=}"
                 [[ "$owner" =~ ^(yes|no|auto)$ ]] || fail "$E_USAGE" "--owner is yes, no or auto" ;;
      --json)    JSON_MODE=1 ;;
      -*)        fail "$E_USAGE" "unknown flag: $1" ;;
      *)         [[ -z "$ref" ]] && ref="$1" || fail "$E_USAGE" "usage: 5dive task loop heal <loop> [on|off] [--owner=yes|no|auto]" ;;
    esac
    shift
  done
  local tid tident
  _loop_tpl_resolve "$ref"; tid="$_LOOP_TID"; tident="$_LOOP_TIDENT"
  case "$sw" in
    off) _loop_pref_set "loop.heal.${tident}" off ;;
    on)  _loop_pref_del "loop.heal.${tident}" ;;
  esac
  case "$owner" in
    yes|no) _loop_pref_set "loop.owner.${tident}" "$owner" ;;
    auto)   _loop_pref_del "loop.owner.${tident}" ;;
  esac
  local heal=false facing=false weekly=false empty
  _loop_heal_on "$tident" && heal=true
  _loop_owner_facing "$tident" && facing=true
  _loop_heal_weekly_on "$tident" && weekly=true
  empty=$(_loop_pref_get "loop.empty.${tident}"); jq -e 'type=="object"' <<<"$empty" >/dev/null 2>&1 || empty='{}'
  local msg="${tident} self-healing $([[ $heal == true ]] && echo on || echo off): a failed run is $([[ $heal == true ]] && echo "tried again once after ${_LOOP_HEAL_RETRY_MIN} minutes" || echo "not retried")"
  if [[ $facing == true ]]; then
    msg+="; it messages its owner, so ${_LOOP_EMPTY_TELL_AT} empty runs in a row $([[ $heal == true ]] && echo "tell them it may be broken" || echo "stay quiet")"
  else
    msg+="; it does not message its owner, so empty runs stay quiet"
  fi
  msg+="; weekly self-improving $([[ $weekly == true ]] && echo on || echo off)"
  ok "$msg" '{loop:$t, healing:$h, owner_facing:$f, weekly_improve:$w, empty_runs:($e.n // 0)}' \
     --arg t "$tident" --argjson h "$heal" --argjson f "$facing" --argjson w "$weekly" --argjson e "$empty"
}
