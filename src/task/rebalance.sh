# shellcheck shell=bash
# ---------------------------------------------------------------------------
# DIVE-5191 — REBALANCE UN-STARTED WORK BETWEEN SIBLING SEATS.
#
# The shape it removes: one builder holds a queue of rows nobody has touched
# while its sibling sits at an empty prompt. Measured 2026-09-29 05:25Z: dev had
# 7 todo + 1 in_progress + 2 blocked, dev2 had 0 open rows and had been idle ~2h
# on the SAME account at 19% of its week. main moved 5 rows by hand. The queue
# works priority-then-age per seat and has no notion of a sibling, so nothing
# ever noticed.
#
# WHAT IT IS, in the order the heartbeat tick runs it (`_hb_rebalance_sweep`):
#
#   POOLS    opt-in. `task rebalance pool builders dev,dev2` declares seats that
#            may take each other's work. No pool, no reads beyond one pref: a
#            seat outside every pool is never touched. A seat is in at most one.
#   TRIGGER  a member holds >= N un-started todo rows (min-todo, default 4) AND
#            another member has NOTHING it can pick up (no todo, no in_progress —
#            a blocked or gated row is waiting on someone else, so it does not
#            make a seat busy) AND that member's account has headroom. The
#            quota is read BEFORE anything moves: a seat can be idle BECAUSE it
#            is walled, and handing it work would only strand the work there.
#            Headroom fails CLOSED — parked, blind, soft, hard all read "no".
#   WHAT     status=todo, never started, no gate, no park, no open dependency,
#            a standard row (never a recurring template or its clone), not
#            linked to the busy seat's live work (parent/child, a dependency
#            edge, a shared `Branch:`, or its body naming one of those rows), and
#            not pinned to the seat in its body (`Seat: dev`, `@dev`,
#            `agent-dev`). Taken from the END of the busy seat's queue — lowest
#            priority, then newest — because that is what it would reach last.
#   SAFETY   at most K moves per tick (max-moves, default 2) and never more than
#            half of a busy seat's un-started rows in one tick. A moved row is
#            held 24h (task_prefs `rebalance_moved:<id>`), so nothing
#            ping-pongs. Each move appends one line to the row's body; one line
#            per tick goes to the lead. NOTHING goes to either seat: the queue is
#            the message, and a ping would cost the receiver a reload for a row
#            the heartbeat hands it anyway.
#
# WHY A BARE MENTION OF THE SEAT NAME DOES NOT PIN A ROW. It was the first
# rule tried and it is wrong on the evidence: 3 of the 5 rows main moved by hand
# on 2026-09-29 contain the word `dev` (maker notes, "reassigned from dev",
# a list of seats). A pin has to be a statement about the row, not prose.
#
# NO SCHEMA CHANGE, on purpose: a column costs a `_tasks_db_migrate` rung and a
# restore-guard run on every live board (DIVE-2512). Pools, knobs and the 24h
# hold are all `task_prefs` keys, the same KV the ops digest throttle uses.
# ---------------------------------------------------------------------------

_REBAL_HOLD_SEC="${REBALANCE_HOLD_SEC:-86400}"
_REBAL_WIP=(); _REBAL_WIP_BRANCHES=""; _REBAL_WIP_IDS=""
[[ "$_REBAL_HOLD_SEC" =~ ^[0-9]+$ ]] || _REBAL_HOLD_SEC=86400

# The pools document: {"<pool>": ["seat", ...]} or {} when none is declared.
_rebal_pools_json() {
  local v; v=$(_task_pref_get rebalance_pools 2>/dev/null || printf '')
  [[ -n "$v" ]] && jq -e 'type=="object"' >/dev/null 2>&1 <<<"$v" || v='{}'
  printf '%s' "$v"
}

# _rebal_knob <key> <default> — a positive integer pref, or the default.
_rebal_knob() {
  local v; v=$(_task_pref_get "$1" 2>/dev/null || printf '')
  [[ "$v" =~ ^[1-9][0-9]*$ ]] && { printf '%s' "$v"; return 0; }
  printf '%s' "$2"
}

# Rows a seat could pick up now: todo or in_progress. Blocked/gated rows are
# owed by someone else and leave the seat idle.
_rebal_workable_count() {
  db "SELECT COUNT(*) FROM tasks WHERE assignee=$(sqlq "$1") AND kind='standard'
        AND status IN ('todo','in_progress');" 2>/dev/null || printf '0'
}

_rebal_unstarted_count() {
  db "SELECT COUNT(*) FROM tasks WHERE assignee=$(sqlq "$1") AND kind='standard'
        AND status='todo' AND first_started_at IS NULL AND started_at IS NULL;" 2>/dev/null || printf '0'
}

# _rebal_dispatchable <seat> — rc 0 = the heartbeat will actually wake this seat;
# the reason is on stdout when it will not. A seat an operator parked
# (desiredState=stopped) or one with heartbeat.enabled not true is idle FOREVER,
# because the wake loop skips it — and a row handed to it strands there behind
# the 24h hold. Quota headroom cannot see either, so this is its own check, run
# before the meter. FAILS CLOSED: no parked predicate in this process, or a
# registry that does not name the seat, reads as "will not be woken".
_rebal_dispatchable() {
  local seat="$1" reg="" enabled=""
  declare -F _hb_agent_is_parked >/dev/null 2>&1 || { printf 'no parked check in this process'; return 1; }
  if _hb_agent_is_parked "$seat"; then printf 'parked by operator (desiredState=stopped)'; return 1; fi
  reg=$(registry_read 2>/dev/null) || reg=""
  [[ -n "$reg" ]] || reg='{}'
  enabled=$(jq -r --arg n "$seat" '.agents[$n].heartbeat.enabled // false' <<<"$reg" 2>/dev/null) || enabled=""
  if [[ "$enabled" != "true" ]]; then printf 'heartbeat off (the tick never dispatches it)'; return 1; fi
  return 0
}

# _rebal_headroom <seat> <now> <usage-json> — rc 0 = the seat's account can take
# work; the reason is on stdout either way. Split out so a harness can stand in
# for the meter. FAILS CLOSED: an unreadable meter, an unresolved account, and
# every band but `open` all read as no headroom.
_rebal_headroom() {
  local seat="$1" now="$2" usage="${3:-}" acct="" band="" rc=0 mins=""
  if declare -F _hb_quota_parked >/dev/null 2>&1 && mins=$(_hb_quota_parked "$seat" 5 2>/dev/null); then
    printf 'quota-parked (%sm left)' "$mins"; return 1
  fi
  if ! declare -F _pace_band >/dev/null 2>&1 || ! declare -F _grader_account_of >/dev/null 2>&1; then
    printf 'no meter in this process'; return 1
  fi
  acct=$(_grader_account_of "$seat" <<<"$usage" 2>/dev/null || printf '')
  [[ -n "$acct" ]] || { printf 'no account resolves for %s' "$seat"; return 1; }
  band=$(_pace_band "$acct" "$now" <<<"$usage" 2>/dev/null) || rc=$?
  if (( rc == 0 )); then printf 'account %s open' "$acct"; return 0; fi
  printf 'account %s %s: %s' "$acct" "$(_pace_band_name "$rc" 2>/dev/null || printf 'unknown')" "${band:-no reading}"
  return 1
}

# Branch names a body declares on a `Branch:` line, one per line, trailing
# punctuation and backticks trimmed (the merge gate trims the same way).
_rebal_branches() {
  local line b re='^[[:space:]]*[*_]*[Bb]ranch:[*_]*[[:space:]]*`?([^[:space:]`]+)'
  while IFS= read -r line; do
    [[ "$line" =~ $re ]] || continue
    b="${BASH_REMATCH[1]}"; b="${b%%[.,;:)]}"
    [[ -n "$b" ]] && printf '%s\n' "$b"
  done <<<"$1"
}

# Is this body pinned to <seat>? An explicit statement, never a bare mention.
_rebal_pinned() {
  local body="$1" seat="$2" line lc s
  s=$(printf '%s' "$seat" | sed 's/[][\.^$*+?(){}|/]/\\&/g')
  local tok="(^|[^A-Za-z0-9_-])(@${s}|agent-${s})([^A-Za-z0-9_-]|$)"
  local key="^[[:space:]]*[*_]*(seat|assignee|owner|lane|pin|pinned)[[:space:]]*[:=][*_]*[[:space:]]*\`?${s}([^A-Za-z0-9_-]|$)"
  while IFS= read -r line; do
    [[ "$line" =~ $tok ]] && return 0
    lc=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
    [[ "$lc" =~ $key ]] && return 0
  done <<<"$body"
  return 1
}

# Does <body> name <ident> as a whole token (DIVE-12 is not DIVE-123)?
_rebal_names_ident() {
  local re="(^|[^A-Za-z0-9_-])${2}([^0-9]|$)"
  [[ "$1" =~ $re ]]
}

# _rebal_why_not <id> <busy> <receiver> <now> — empty when the row may move,
# else the one reason it may not. Reads the busy seat's live work from
# _REBAL_WIP_* (filled by _rebal_load_wip for that seat).
_rebal_why_not() {
  local id="$1" busy="$2" to="$3" now="$4" row
  row=$(db "SELECT COALESCE(first_started_at,'')||x'1f'||COALESCE(started_at,'')
              ||x'1f'||status||x'1f'||kind||x'1f'||COALESCE(from_template_id,'')
              ||x'1f'||CASE WHEN need_type IS NOT NULL AND need_answered_at IS NULL THEN need_type ELSE '' END
              ||x'1f'||COALESCE(parked_at,'')||x'1f'||COALESCE(parent_id,'')||x'1f'||COALESCE(verifier,'')
              ||x'1f'||(SELECT COUNT(*) FROM task_deps d JOIN tasks b ON b.id=d.blocked_by
                          WHERE d.task_id=tasks.id AND b.status NOT IN ('done','cancelled'))
            FROM tasks WHERE id=${id};" 2>/dev/null) || row=""
  [[ -n "$row" ]] || { printf 'row not found'; return 0; }
  local fsa sa st kind tmpl gate parked parent vfier deps
  IFS=$'\x1f' read -r fsa sa st kind tmpl gate parked parent vfier deps <<<"$row"
  [[ "$st" == "todo" ]]          || { printf 'status %s' "$st"; return 0; }
  [[ -z "$fsa" && -z "$sa" ]]    || { printf 'started'; return 0; }
  [[ "$kind" == "standard" && -z "$tmpl" ]] || { printf 'recurring'; return 0; }
  [[ -z "$gate" ]]               || { printf 'gated (%s)' "$gate"; return 0; }
  [[ -z "$parked" ]]             || { printf 'parked'; return 0; }
  [[ "${deps:-0}" == "0" ]]      || { printf 'blocked by an open dependency'; return 0; }
  [[ "$vfier" != "$to" ]]        || { printf 'its verifier is %s' "$to"; return 0; }
  local held; held=$(_task_pref_get "rebalance_moved:${id}" 2>/dev/null || printf '')
  if [[ "$held" =~ ^[0-9]+$ ]] && (( now - held < _REBAL_HOLD_SEC )); then
    printf 'moved %sh ago (24h hold)' "$(( (now - held) / 3600 ))"; return 0
  fi
  local body; body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};" 2>/dev/null || printf '')
  if _rebal_pinned "$body" "$busy"; then printf 'pinned to %s in its body' "$busy"; return 0; fi
  local w wident link=""
  if (( ${#_REBAL_WIP[@]} )); then
    # One query for every structural link to the live rows, not two per row.
    link=$(db "SELECT CASE WHEN w.id=${parent:-0} THEN 'child of '
                           WHEN w.parent_id=${id} THEN 'parent of '
                           ELSE 'dependency edge with ' END||COALESCE(w.ident,w.id)
                 FROM tasks w
                WHERE w.id IN (${_REBAL_WIP_IDS})
                  AND (w.id=${parent:-0} OR w.parent_id=${id}
                       OR EXISTS (SELECT 1 FROM task_deps d
                                   WHERE (d.task_id=w.id AND d.blocked_by=${id})
                                      OR (d.task_id=${id} AND d.blocked_by=w.id)))
                ORDER BY w.id LIMIT 1;" 2>/dev/null) || link=""
  fi
  [[ -z "$link" ]] || { printf '%s' "$link"; return 0; }
  for w in "${_REBAL_WIP[@]}"; do
    wident="${w#*:}"
    if [[ -n "$wident" ]] && _rebal_names_ident "$body" "$wident"; then
      printf 'names %s' "$wident"; return 0
    fi
  done
  local b branches
  branches=$(_rebal_branches "$body")
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    if grep -qxF -- "$b" <<<"$_REBAL_WIP_BRANCHES"; then printf 'shares Branch: %s' "$b"; return 0; fi
  done <<<"$branches"
  return 0
}

# _rebal_load_wip <seat> — the seat's live work (in_progress + blocked) as
# "<id>:<ident>" in _REBAL_WIP, and the branches those rows declare.
_rebal_load_wip() {
  _REBAL_WIP=(); _REBAL_WIP_BRANCHES=""; _REBAL_WIP_IDS=""
  local id ident rows
  rows=$(db "SELECT id||x'1f'||COALESCE(ident,'') FROM tasks
              WHERE assignee=$(sqlq "$1") AND status IN ('in_progress','blocked') ORDER BY id;" 2>/dev/null)
  while IFS=$'\x1f' read -r id ident; do
    [[ -n "$id" ]] || continue
    _REBAL_WIP+=("${id}:${ident}"); _REBAL_WIP_IDS+="${_REBAL_WIP_IDS:+,}${id}"
    _REBAL_WIP_BRANCHES+="$(_rebal_branches "$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};" 2>/dev/null)")"$'\n'
  done <<<"$rows"
}

# _rebal_plan <now> <usage-json> — the decision, with no write. One TSV line per
# fact, so the dry run and the tick print from the same source:
#   pool   <pool> <members-csv>
#   seat   <seat> <unstarted> <workable> <role: busy|idle|-> <note>
#   move   <id> <ident> <from> <to> <pool> <priority>
#   keep   <id> <ident> <from> <reason>
#   none   <pool> <reason>
_rebal_plan() {
  local now="$1" usage="${2:-}" pools min_todo max_moves moves=0
  pools=$(_rebal_pools_json)
  min_todo=$(_rebal_knob rebalance_min_todo 4)
  max_moves=$(_rebal_knob rebalance_max_moves 2)
  local pool names
  names=$(jq -r 'keys[]' <<<"$pools" 2>/dev/null)
  while IFS= read -r pool; do
    [[ -n "$pool" ]] || continue
    local -a members=() busy=() idle=()
    local m u w list
    list=$(jq -r --arg p "$pool" '.[$p][]? // empty' <<<"$pools")
    [[ -z "$list" ]] || mapfile -t members <<<"$list"
    printf 'pool\t%s\t%s\n' "$pool" "$(IFS=,; printf '%s' "${members[*]}")"
    for m in "${members[@]}"; do
      u=$(_rebal_unstarted_count "$m"); w=$(_rebal_workable_count "$m")
      if (( u >= min_todo )); then
        busy+=("$u:$m"); printf 'seat\t%s\t%s\t%s\tbusy\t%s un-started (trigger %s)\n' "$m" "$u" "$w" "$u" "$min_todo"
      elif (( w == 0 )); then
        local why rc=0
        if ! why=$(_rebal_dispatchable "$m"); then
          printf 'seat\t%s\t%s\t%s\t-\tidle but %s\n' "$m" "$u" "$w" "$why"
          continue
        fi
        why=$(_rebal_headroom "$m" "$now" "$usage") || rc=$?
        if (( rc == 0 )); then
          idle+=("$m"); printf 'seat\t%s\t%s\t%s\tidle\t%s\n' "$m" "$u" "$w" "$why"
        else
          printf 'seat\t%s\t%s\t%s\t-\tidle but no headroom: %s\n' "$m" "$u" "$w" "$why"
        fi
      else
        printf 'seat\t%s\t%s\t%s\t-\tworking\n' "$m" "$u" "$w"
      fi
    done
    if (( ${#busy[@]} == 0 )); then printf 'none\t%s\tno member holds %s+ un-started rows\n' "$pool" "$min_todo"; continue; fi
    if (( ${#idle[@]} == 0 )); then printf 'none\t%s\tno member is idle with headroom\n' "$pool"; continue; fi
    # Heaviest queue first.
    local b from total taken=0 ri=0 id ident prio to why sorted rows
    sorted=$(printf '%s\n' "${busy[@]}" | sort -t: -k1,1nr -k2,2)
    mapfile -t busy <<<"$sorted"
    for b in "${busy[@]}"; do
      total="${b%%:*}"; from="${b#*:}"; taken=0
      _rebal_load_wip "$from"
      rows=$(db "SELECT id||x'1f'||COALESCE(ident,'DIVE-'||id)||x'1f'||priority FROM tasks
                  WHERE assignee=$(sqlq "$from") AND kind='standard' AND status='todo'
                  ORDER BY CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1
                                         WHEN 'medium' THEN 2 ELSE 3 END DESC, id DESC;" 2>/dev/null)
      while IFS=$'\x1f' read -r id ident prio; do
        [[ -n "$id" ]] || continue
        (( moves < max_moves )) || break
        (( taken < total / 2 )) || break
        to="${idle[$(( ri % ${#idle[@]} ))]}"
        why=$(_rebal_why_not "$id" "$from" "$to" "$now")
        if [[ -n "$why" ]]; then printf 'keep\t%s\t%s\t%s\t%s\n' "$id" "$ident" "$from" "$why"; continue; fi
        printf 'move\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$ident" "$from" "$to" "$pool" "$prio"
        moves=$((moves + 1)); taken=$((taken + 1)); ri=$((ri + 1))
      done <<<"$rows"
    done
  done <<<"$names"
  return 0
}

# _rebal_move <id> <from> <to> <pool> <now> <why-line> — the one write. Guarded
# on the row still being the un-started todo the plan saw, so a seat that claims
# it between the plan and the write keeps it. rc 0 = moved.
_rebal_move() {
  local id="$1" from="$2" to="$3" pool="$4" now="$5" note="$6" n
  # The resets are cmd_task_assign's, for its reasons (DIVE-2853, DIVE-4111): a
  # latch that outlives the owner acts on the new one's first tick.
  n=$(db "UPDATE tasks SET assignee=$(sqlq "$to"),
            body=COALESCE(body,'')||$(sqlq "$(printf '\n\n%s' "$note")"),
            handoff_ack_at=NULL, recurring_stall_pinged_at=NULL,
            recurring_stall_escalated_at=NULL, reap_escalated_at=NULL, reap_escalated_n=NULL,
            updated_at=datetime('now')
          WHERE id=${id} AND assignee=$(sqlq "$from") AND status='todo'
            AND first_started_at IS NULL AND started_at IS NULL;
          SELECT changes();" 2>/dev/null) || n=0
  [[ "$n" == "1" ]] || return 1
  _task_pref_set "rebalance_moved:${id}" "$now" >/dev/null 2>&1 || true
  return 0
}

# _rebal_lead <seat> — who hears about a move off <seat>: its manager on the
# org chart, else the box's escalation recipient.
_rebal_lead() {
  local l; l=$(db "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$1");" 2>/dev/null || printf '')
  if [[ -z "$l" ]] && declare -F _hb_escalation_recipient >/dev/null 2>&1; then l=$(_hb_escalation_recipient); fi
  printf '%s' "$l"
}

# _rebal_apply <now> <usage-json> — plan, write, record. Echoes the moved rows
# as "<ident> <from>-><to>" lines; sends one line per lead.
_rebal_apply() {
  local now="$1" usage="${2:-}" plan kind a b c d e f
  plan=$(_rebal_plan "$now" "$usage")
  local -A seat_note=() lead_msg=()
  while IFS=$'\t' read -r kind a b c d e; do
    [[ "$kind" == "seat" ]] && seat_note["$a"]="$b un-started, $c workable; $e"
  done <<<"$plan"
  local stamp; stamp=$(date -u -d "@${now}" '+%Y-%m-%d %H:%MZ' 2>/dev/null || date -u '+%Y-%m-%d %H:%MZ')
  while IFS=$'\t' read -r kind a b c d e f; do
    [[ "$kind" == "move" ]] || continue
    # a=id b=ident c=from d=to e=pool f=priority
    local note="REBALANCED ${stamp}: ${c} -> ${d} (pool ${e}). ${c} held ${seat_note[$c]%%,*} and ${d} had nothing workable (${seat_note[$d]#*; }); this ${f} row is the one ${c} would reach last. Never started, so no context is lost. Undo: 5dive task assign ${b} ${c} (DIVE-5191)."
    if _rebal_move "$a" "$c" "$d" "$e" "$now" "$note"; then
      printf '%s %s->%s\n' "$b" "$c" "$d"
      local lead; lead=$(_rebal_lead "$c")
      lead_msg["${lead:--}"]+="${b} ${c}->${d}, "
    fi
  done <<<"$plan"
  local l msg
  for l in "${!lead_msg[@]}"; do
    msg="🔀 Rebalanced un-started rows between sibling seats: ${lead_msg[$l]%, } (a seat held a long un-started queue while its sibling was idle with quota; each row's body says why). Nothing to do; undo with 5dive task assign <row> <seat>. Preview the next pass: 5dive task rebalance --dry-run"
    if [[ "$l" == "-" ]]; then continue; fi
    if declare -F _hb_escalate >/dev/null 2>&1; then
      _hb_escalate "rebalance" "task-engine" "rebalance" "$msg" "$l"
    else
      ( cmd_send "$l" --from="task-engine" --message="$msg" ) >/dev/null 2>&1 || true
    fi
  done
  return 0
}

_rebal_usage() {
  cat <<'USAGE'
usage: 5dive task rebalance [--dry-run] [--json]    print what the next heartbeat pass would move (default)
       5dive task rebalance --apply                 run one pass now (root)
       5dive task rebalance pools                   list pools and knobs
       5dive task rebalance pool <name> <seat,seat,...>   declare a pool (root; a seat is in at most one)
       5dive task rebalance pool <name> --clear     remove a pool (root)
       5dive task rebalance set min-todo=<N>|max-moves=<K>   knobs (root; defaults 4 and 2)
USAGE
}

# The usage document the plan reads its quota from: the tick's cached snapshot
# when this process has one, else a fresh read. Empty is a real (blind) state.
_rebal_usage_json() {
  if declare -F _pace_usage_snapshot >/dev/null 2>&1; then
    _pace_usage_snapshot 2>/dev/null || printf ''
  else
    ${_PACE_USAGE_CMD:-sudo -n 5dive usage --json} 2>/dev/null || printf ''
  fi
}

cmd_task_rebalance() {
  tasks_db_init
  local mode="dry" sub="${1:-}"
  case "$sub" in
    pools)
      shift
      local pools; pools=$(_rebal_pools_json)
      ok "" '{pools:$p, min_todo:($n|tonumber), max_moves:($k|tonumber), hold_sec:($h|tonumber)}' \
        --argjson p "$pools" --arg n "$(_rebal_knob rebalance_min_todo 4)" \
        --arg k "$(_rebal_knob rebalance_max_moves 2)" --arg h "$_REBAL_HOLD_SEC"
      if (( ! JSON_MODE )); then
        if [[ "$pools" == "{}" ]]; then echo "no pools declared — rebalancing is off (5dive task rebalance pool <name> <seat,seat>)"
        else jq -r 'to_entries[] | "\(.key): \(.value | join(", "))"' <<<"$pools"; fi
        echo "min-todo=$(_rebal_knob rebalance_min_todo 4) max-moves=$(_rebal_knob rebalance_max_moves 2) hold=${_REBAL_HOLD_SEC}s"
      fi
      return 0 ;;
    pool)
      shift
      require_root "task rebalance pool"
      local name="${1:-}" spec="${2:-}"
      [[ "$name" =~ ^[A-Za-z0-9_-]+$ && -n "$spec" ]] || fail "$E_USAGE" "$(_rebal_usage)"
      local pools; pools=$(_rebal_pools_json)
      if [[ "$spec" == "--clear" ]]; then
        _task_pref_set rebalance_pools "$(jq -c --arg p "$name" 'del(.[$p])' <<<"$pools")"
        ok "pool '$name' removed" '{pool:$p, removed:true}' --arg p "$name"; return 0
      fi
      local -a seats=(); local s
      IFS=, read -r -a seats <<<"$spec"
      (( ${#seats[@]} >= 2 )) || fail "$E_VALIDATION" "a pool needs at least two seats to move work between (got '${spec}')"
      for s in "${seats[@]}"; do
        [[ "$s" =~ ^[A-Za-z0-9_-]+$ ]] || fail "$E_VALIDATION" "'${s}' is not a seat name"
        _task_require_lane "$s" "pool member"
        local other; other=$(jq -r --arg p "$name" --arg s "$s" 'to_entries[] | select(.key != $p and (.value | index($s))) | .key' <<<"$pools" | head -1)
        [[ -z "$other" ]] || fail "$E_VALIDATION" "'${s}' is already in pool '${other}' — a seat belongs to at most one pool, or one tick could move a row twice"
      done
      _task_pref_set rebalance_pools "$(jq -c --arg p "$name" --arg s "$spec" '.[$p] = ($s | split(",") | unique)' <<<"$pools")"
      ok "pool '$name' = ${spec} (a member with $(_rebal_knob rebalance_min_todo 4)+ un-started rows hands up to $(_rebal_knob rebalance_max_moves 2) per tick to an idle member with quota)" \
        '{pool:$p, seats:($s|split(","))}' --arg p "$name" --arg s "$spec"
      return 0 ;;
    set)
      shift
      require_root "task rebalance set"
      local kv k v
      for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        [[ "$v" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "'${kv}': the value must be a positive integer"
        case "$k" in
          min-todo)  _task_pref_set rebalance_min_todo "$v" ;;
          max-moves) _task_pref_set rebalance_max_moves "$v" ;;
          *) fail "$E_USAGE" "unknown knob '${k}' (min-todo, max-moves)" ;;
        esac
      done
      ok "knobs: min-todo=$(_rebal_knob rebalance_min_todo 4) max-moves=$(_rebal_knob rebalance_max_moves 2)"
      return 0 ;;
  esac
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) mode="dry" ;;
      --apply)   mode="apply" ;;
      *) fail "$E_USAGE" "$(_rebal_usage)" ;;
    esac
    shift
  done
  local now usage; now=$(date +%s); usage=$(_rebal_usage_json)
  if [[ "$mode" == "apply" ]]; then
    require_root "task rebalance --apply"
    local moved; moved=$(_rebal_apply "$now" "$usage")
    ok "${moved:-nothing moved}" '{moved:($m | split("\n") | map(select(length>0)))}' --arg m "$moved"
    return 0
  fi
  local plan; plan=$(_rebal_plan "$now" "$usage")
  if (( JSON_MODE )); then
    ok "" '{dry_run:true, plan:($p | split("\n") | map(select(length>0) | split("\t")))}' --arg p "$plan"
    return 0
  fi
  [[ -n "$plan" ]] || { echo "no pools declared — rebalancing is off (5dive task rebalance pool <name> <seat,seat>)"; return 0; }
  local kind a b c d e f
  echo "DRY RUN — nothing changes. What the next heartbeat pass would do:"
  while IFS=$'\t' read -r kind a b c d e f; do
    case "$kind" in
      pool) printf '\npool %s: %s\n' "$a" "$b" ;;
      seat) printf '  %-12s %s\n' "$a" "$e" ;;
      move) printf '  MOVE %s %s -> %s (%s)\n' "$b" "$c" "$d" "$f" ;;
      keep) printf '  keep %s on %s: %s\n' "$b" "$c" "$d" ;;
      none) printf '  nothing to move: %s\n' "$b" ;;
    esac
  done <<<"$plan"
}
