# -------- 5dive task — doctor (DIVE-3784) --------
#
# Split file, loaded by src/cmd_task.sh and cat into the bundle by build.sh.
# Function definitions only — never execute this file directly.
#
# THE DEFECT THIS ANSWERS. On 2026-08-28 05:00Z the board read 31 open rows and
# `5dive-ai/5dive` main had not moved in ~42h. Of the 31: 30 `blocked`, exactly 1
# `todo`. A reader of `task ls` sees a BUSY fleet; the dispatcher sees an IDLE
# one, and neither view says which of the two is true. `task orphans` (DIVE-3344)
# already answers ONE of the four ways a row becomes undispatchable — the name in
# `assignee` is not a registered agent. This is the same idea widened to the rest.
#
# WHY A NEW VERB AND NOT A WIDER `orphans`. `orphans` answers "is this NAME real",
# and it REFUSES outright when the roster is unestablished, correctly: with no
# roster every row looks orphaned. Three of the four classes here are pure board
# SQL and need no roster at all, so folding them into a verb that refuses without
# one would make an unreadable registry hide the stale edges too. `doctor` runs
# the roster-free classes ALWAYS and degrades only the lane class. `orphans` is
# kept and is still the verb with the did-you-mean hints.
#
# REPORT BY DEFAULT; FIX ONE NAMED ROW ON REQUEST (DIVE-3826). Mass-clearing a
# board is its own failure mode: the DIVE-1355 heartbeat sweep auto-recovers
# exactly one class (every blocker closed) because the edges themselves prove it
# safe, and deliberately only SURFACES the rest. A bare `task doctor` inherits
# that split exactly — it names the verb per finding and runs none of them.
# `--fix <id>` runs that one verb for that ONE row, re-deriving the finding
# first. What is NOT inherited is the retyping: the rail worth keeping is "one
# row is one decision", not "the operator must be the clipboard". There is no
# --all and there must never be one. See the --fix block below.
#
# WHY A PULL COMMAND WHEN THE HEARTBEAT ALREADY SWEEPS. `_hb_blocked_sweep` pings
# `ops` at most once per 24h over a2a. That is a push to one seat's inbox, it is
# throttled, it covers two of these four classes, and it is unavailable to the
# person actually looking at a stalled board right now. "See the jam in one
# command instead of opening 31 rows" is a different job from "tell ops once a
# day", and the row was filed on the second one having failed to prevent the 42h.

# _task_doctor_lane_wakeable <name> — 0 when the heartbeat tick would ever WAKE
# this seat.
#
# THIS IS THE "REGISTERED AND DEAD" HALF, and it is a stricter test than
# `_task_roster_has`. The roster is the UNION of agents.json and the `agents_org`
# chart (see _task_roster), so a seat that exists only on the org chart passes
# `orphans` and is still never woken. And the wake loop's own population is
# narrower still: `jq '.agents | map(select(.value.heartbeat.enabled == true))'`
# (cmd_heartbeat.sh, the tick's final `done < <(…)`). A seat whose heartbeat key
# is absent or false is never iterated, so nothing ever hands it a row — it is
# registered, it is not dispatchable, and `task orphans` calls it healthy.
#
# Measured 2026-08-28 on this host: 4 of 17 registered agents carry no heartbeat
# key at all, and one of them held an open row.
#
# THE SECOND HALF: `desiredState`. An operator-stopped seat (`desiredState:
# "stopped"`) IS iterated by the wake loop and the wake then FAILS — the tick logs
# "wake failed — will retry next tick" and moves on, forever. That is a different
# mechanism from the heartbeat key and the same outcome for the row, so it is the
# same finding. It is deliberately NOT treated as a registry error: an operator
# stopped that seat on purpose, and the honest report is "these rows are parked on
# a seat you turned off", not "your registry is broken".
#
# Returns 2 (NOT 1) when the registry could not be read, so the caller can tell
# "this seat is dead" from "I could not find out" and degrade instead of
# reporting every lane as dead — the failure direction `orphans` refuses over.
_task_doctor_lane_wakeable() {
  local name="${1:-}" reg="" v
  [[ -n "$name" ]] || return 2
  reg="${STATE_DIR:-/var/lib/5dive}/agents.json"
  [[ -r "$reg" ]] || return 2
  # ONE jq read for both facts: an agent absent from the file yields "false|running",
  # which is correctly not wakeable and needs no separate existence probe.
  v=$(jq -r --arg n "$name" '((.agents[$n].heartbeat.enabled // false)|tostring) + "|" + (.agents[$n].desiredState // "running")' "$reg" 2>/dev/null) || return 2
  [[ -n "$v" ]] || return 2
  [[ "${v%%|*}" == "true" ]] || return 1
  [[ "${v##*|}" != "stopped" ]]
}

# The four classes, as SQL predicates over open standard rows. Kept as one
# function so the report and the --json payload cannot drift apart.
#
#   no-anchor    blocked, no dependency edge, no park, no unanswered gate. This is
#                _task_has_block_anchor's negation (src/task/loops.sh, DIVE-1357)
#                — the state that verb makes unreachable going FORWARD. Rows
#                predating it, or rows a park/gate was cleared out from under,
#                still sit here and nothing revisits them.
#   stale-edge   blocked, HAS edges, and every blocker is done/cancelled. The
#                DIVE-1355 tick sweep auto-recovers this; seeing one here means
#                the tick has not run since the blocker closed (or is not running
#                at all), which is itself the finding.
#   wake-passed  parked with a wake_at already in the past. The gate-TTL pass
#                unparks these; same reading as above.
#   park-no-wake parked with NO wake_at. `task park` has required --wake since
#                DIVE-1357, so this is only reachable on older rows or a direct
#                write — and it is the purest form of the defect: a hold with no
#                revisit at all. It is ALSO why the anchor predicate demands
#                `parked_at IS NOT NULL AND wake_at IS NOT NULL`.
#
# The lane class (assignee undispatchable) is scanned separately: it needs the
# roster, which the three above do not.
_task_doctor_board_sql() {
  cat <<'SQL'
SELECT ident, status, COALESCE(assignee,'') AS assignee,
       CASE
         WHEN status='blocked'
              AND parked_at IS NULL
              AND (need_type IS NULL OR need_answered_at IS NOT NULL)
              AND NOT EXISTS (SELECT 1 FROM task_deps d WHERE d.task_id=tasks.id)
           THEN 'no-anchor'
         WHEN status='blocked'
              AND parked_at IS NULL
              AND (need_type IS NULL OR need_answered_at IS NOT NULL)
              AND EXISTS (SELECT 1 FROM task_deps d WHERE d.task_id=tasks.id)
              AND NOT EXISTS (SELECT 1 FROM task_deps d JOIN tasks b ON b.id=d.blocked_by
                              WHERE d.task_id=tasks.id AND b.status NOT IN ('done','cancelled'))
           THEN 'stale-edge'
         WHEN parked_at IS NOT NULL AND wake_at IS NULL           THEN 'park-no-wake'
         WHEN parked_at IS NOT NULL AND wake_at <= datetime('now') THEN 'wake-passed'
       END AS reason,
       COALESCE(wake_at,'') AS wake_at,
       (SELECT GROUP_CONCAT(b.ident || '/' || b.status, ' ') FROM task_deps d JOIN tasks b ON b.id=d.blocked_by
        WHERE d.task_id=tasks.id) AS blockers,
       substr(title,1,58) AS title
  FROM tasks
 WHERE kind='standard' AND status IN ('todo','in_progress','blocked')
SQL
}

# What each finding means and which verb clears it. The remedy is the payload:
# the row was filed because an operator read `status = blocked`, reached for the
# verb that names that status, and got "OK — DIVE-3614 unblocked" over a row that
# did not move. `unblock` drops EDGES; a parked row has none, so it is a no-op
# that reports success. Naming the verb per CLASS is the fix for that, and it is
# why this table is not a generic "look into it".
_task_doctor_explain() {
  case "${1:-}" in
    no-anchor)    printf '%s' "blocked with no revisit anchor — no dependency edge, no open gate, no park. Nothing will ever clear it. -> 5dive task unblock <id>  (or cancel it if it is dead)" ;;
    stale-edge)   printf '%s' "blocked by rows that are ALL closed — a stale edge the cascade missed. -> 5dive task unblock <id>" ;;
    wake-passed)  printf '%s' "parked, and its wake time has already passed — the heartbeat TTL pass should have unparked it. -> 5dive task unpark <id>  (NOT unblock: unblock only drops edges, and a park has none, so it reports success and changes nothing)" ;;
    park-no-wake) printf '%s' "parked with NO wake time — it will never revisit itself. -> 5dive task unpark <id>, or re-park with a --wake" ;;
    dead-lane)    printf '%s' "assigned to a seat nothing wakes (no heartbeat, or operator-stopped) — nothing will pick it up. -> 5dive task assign <id> <agent>   (roster: 5dive agent list)" ;;
    *)            printf '%s' "undispatchable" ;;
  esac
}

# ============================ --fix (DIVE-3826) ==============================
#
# THE HOLE THIS CLOSES. `doctor` computes, per row, the exact verb that clears
# it — and then makes the operator retype it. That is fine for one row and is
# the whole job for twenty, which is the shape the board was actually in when
# DIVE-3784 was filed. So the remediation becomes executable, and the rail that
# made "report only" the right first cut is kept by NARROWING it, not by
# dropping it:
#
#   REPORT IS STILL THE DEFAULT. A bare `task doctor` mutates nothing, exactly
#   as before. `--fix` is opt-in and it takes ONE NAMED ROW. There is no --all,
#   and there must never be one: "mass-clearing a board is its own failure mode"
#   is not a limitation of the first cut, it is the finding. Twenty rows is
#   twenty decisions; this makes each one one command instead of two.
#
#   THE FINDING IS RE-DERIVED AT FIX TIME, never read from the report the
#   operator is looking at. A printed report is a claim about a board that has
#   kept moving — the heartbeat tick unparks and the cascade unblocks while you
#   read it. Fixing off the render would apply a remedy to a row that already
#   healed, and `unpark` on a healthy row silently drops park state. So `--fix`
#   classifies the row again itself and REFUSES if it is not a finding now,
#   naming what the row actually is.
#
#   IT APPLIES THE VERB THE TABLE PRINTS, by CALLING that verb. Each class maps
#   to the command in its own `-> ` slot in _task_doctor_explain and runs it
#   through the real `cmd_task_*` function, so the semantics cannot drift from
#   the ones the report promised — the filed symptom was precisely a remedy that
#   did not match the state (`unblock` over a park, "OK" over a row that did not
#   move). The parenthetical ALTERNATIVES in that table ("or cancel it if it is
#   dead", "or re-park with a --wake") are operator judgement and are NOT
#   automated: one is destructive and the other needs a date only a person has.
#
# WHY DEAD-LANE IS THE ONE THAT NEEDED A FLAG. Four of the five remedies are
# total functions of the row — `unblock`/`unpark` need no argument. `assign`
# needs a destination, and there is no honest way to derive one: created_by is
# frequently the seat that is dead, and picking "any live agent" would route
# real work by coin flip. So `--to=` is required for that class, and the target
# is checked with the SAME wakeability test that produced the finding — moving a
# row from one seat nothing wakes to another is the defect, performed by the
# tool that reports it.

# _task_doctor_row_reason <task-id> — classify ONE row.
#
# IT WRITES GLOBALS AND ECHOES NOTHING, deliberately. The obvious shape here is
# to echo the class and let the caller take it with `$(...)` — and that shape
# silently loses the second output. A command substitution is a SUBSHELL, so the
# lane note assigned inside it never reaches the caller, which then reads it
# under `set -u` and dies. Two return values means two globals.
#
#   _TASK_DOCTOR_ROW_REASON     the class, or "" when the row is not a finding
#   _TASK_DOCTOR_FIX_LANE_NOTE  set when the lane half could not be DECIDED, so
#                               the caller says "I could not find out" rather
#                               than "healthy" — the same failure direction
#                               _task_doctor_lane_wakeable's rc=2 exists for.
#
# PRECEDENCE MATCHES THE REPORT: the board classes win over dead-lane, because
# the report keeps a row's first classification and a row can be both. If the
# two disagreed, `--fix <ident>` would apply a remedy for a class the operator
# never saw printed next to that ident.
_TASK_DOCTOR_ROW_REASON=""
_TASK_DOCTOR_FIX_LANE_NOTE=""
_task_doctor_row_reason() {
  local id="${1:-}" r asg rc
  _TASK_DOCTOR_ROW_REASON=""
  _TASK_DOCTOR_FIX_LANE_NOTE=""
  [[ -n "$id" ]] || return 0
  r=$(db "SELECT COALESCE(reason,'') FROM ($(_task_doctor_board_sql)) WHERE ident=(SELECT ident FROM tasks WHERE id=${id});" 2>/dev/null || true)
  if [[ -n "$r" ]]; then _TASK_DOCTOR_ROW_REASON="$r"; return 0; fi
  asg=$(db "SELECT COALESCE(assignee,'') FROM tasks
              WHERE id=${id} AND kind='standard' AND status IN ('todo','in_progress','blocked');" 2>/dev/null || true)
  [[ -n "$asg" ]] || return 0
  _task_doctor_lane_wakeable "$asg" && rc=0 || rc=$?
  case "$rc" in
    1) _TASK_DOCTOR_ROW_REASON="dead-lane" ;;
    2) _TASK_DOCTOR_FIX_LANE_NOTE="the agent registry (${STATE_DIR:-/var/lib/5dive}/agents.json) could not be read, so whether '${asg}' is a lane anything wakes is UNKNOWN, not healthy" ;;
  esac
  return 0
}

# _task_doctor_fix <ident-or-id> <--to value> <dry-run 0|1>
_task_doctor_fix() {
  local target="${1:-}" to="${2:-}" dry="${3:-0}"
  resolve_task_id "$target"
  local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  local st asg kind park_reason
  st=$(db "SELECT status FROM tasks WHERE id=${id};")
  kind=$(db "SELECT COALESCE(kind,'') FROM tasks WHERE id=${id};")
  asg=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${id};")

  _task_doctor_row_reason "$id"
  local reason="$_TASK_DOCTOR_ROW_REASON"
  if [[ -z "$reason" ]]; then
    local why="it is not one of the classes doctor reports"
    [[ "$kind" == "standard" ]] || why="it is a '${kind}' row, and doctor only classifies standard rows"
    case "$st" in done|cancelled) why="it is already ${st}" ;; esac
    [[ -z "$_TASK_DOCTOR_FIX_LANE_NOTE" ]] || why="$_TASK_DOCTOR_FIX_LANE_NOTE"
    fail "$E_VALIDATION" "${ident} is not an undispatchable row right now — ${why} (status=${st}${asg:+, assignee=${asg}}). --fix applies only the remedy doctor computes for a CURRENT finding, and it re-derives that finding rather than trusting a printed report: run '5dive task doctor' for the live list."
  fi

  # The command for this class, as the report's own `-> ` slot names it.
  local -a apply=(); local shown=""
  case "$reason" in
    no-anchor|stale-edge)
      [[ -z "$to" ]] || fail "$E_USAGE" "--to is only meaningful for a dead-lane row; ${ident} is '${reason}', whose remedy is '5dive task unblock ${ident}' and takes no destination (re-point the lane separately with '5dive task assign')."
      apply=(cmd_task_unblock "$ident"); shown="5dive task unblock ${ident}" ;;
    wake-passed|park-no-wake)
      [[ -z "$to" ]] || fail "$E_USAGE" "--to is only meaningful for a dead-lane row; ${ident} is '${reason}', whose remedy is '5dive task unpark ${ident}' and takes no destination (re-point the lane separately with '5dive task assign')."
      park_reason=$(db "SELECT COALESCE(park_reason,'') FROM tasks WHERE id=${id};" 2>/dev/null || true)
      apply=(cmd_task_unpark "$ident"); shown="5dive task unpark ${ident}" ;;
    dead-lane)
      [[ -n "$to" ]] || fail "$E_USAGE" "${ident} is assigned to a lane nothing wakes ('${asg}'), and re-routing needs a destination this command cannot invent — the row's creator is often the dead seat itself. Name one: 5dive task doctor --fix ${ident} --to=<agent>   (roster: 5dive agent list)"
      # The destination gets the SAME test that produced the finding. Without
      # this, the verb that reports dead lanes is also the fastest way to make
      # one, and the row reads as repaired.
      local trc; _task_doctor_lane_wakeable "$to" && trc=0 || trc=$?
      if [[ "$trc" == "2" ]]; then
        fail "$E_GENERIC" "cannot verify --to='${to}': ${STATE_DIR:-/var/lib/5dive}/agents.json could not be read, so this command cannot tell a live seat from another dead one — and moving the row blind is the failure it is meant to repair. Fix the registry first: 5dive doctor"
      elif [[ "$trc" != "0" ]]; then
        fail "$E_VALIDATION" "--to='${to}' is itself a lane nothing wakes (no heartbeat enabled, or the seat is operator-stopped) — ${ident} would be exactly as undispatchable at the new address. Pick a live seat: 5dive agent list"
      fi
      apply=(cmd_task_assign "$ident" "$to"); shown="5dive task assign ${ident} ${to}" ;;
    *)
      fail "$E_GENERIC" "no automatic remedy for class '${reason}' on ${ident} — $(_task_doctor_explain "$reason")" ;;
  esac

  local detail; detail=$(_task_doctor_explain "$reason")
  if [[ "$dry" == "1" ]]; then
    warn "DRY RUN — nothing was changed.
  ${ident}  [${st}${asg:+ · }${asg}]  ${reason}
        ${detail}
  would run: ${shown}${park_reason:+
  and would DROP the park reason: ${park_reason}}"
    ok "" '{fix:{ident:$i, reason:$r, command:$c, applied:false, dryRun:true}}' \
       --arg i "$ident" --arg r "$reason" --arg c "$shown"
    return 0
  fi

  # Run the real verb, in a subshell, with its own stdout captured: in JSON mode
  # each cmd_task_* prints its own envelope and two envelopes on one stdout is
  # not parseable output. On failure the sibling's envelope and message are the
  # honest answer, so they are re-emitted rather than swallowed — `fail` exits
  # the process, and inside the subshell that exit is the rc we read here.
  local errf; errf=$(mktemp "${TMPDIR:-/tmp}/task-doctor-fix.XXXXXX")
  local subout rc
  subout=$( ( "${apply[@]}" ) 2>"$errf" ) && rc=0 || rc=$?
  if [[ "$rc" != "0" ]]; then
    cat "$errf" >&2; rm -f "$errf"
    [[ -z "$subout" ]] || printf '%s\n' "$subout"
    mark_reported
    exit "$rc"
  fi
  rm -f "$errf"

  warn "${ident} was '${reason}' — applied: ${shown}${park_reason:+
  park reason dropped: ${park_reason}}
Re-read the board with '5dive task doctor'; one row was changed and nothing else."
  ok "${ident}: ${reason} — ran ${shown}" \
     '{fix:{ident:$i, reason:$r, command:$c, applied:true, dryRun:false}}' \
     --arg i "$ident" --arg r "$reason" --arg c "$shown"
}

cmd_task_doctor() {
  tasks_db_init
  # NO FLAG HIDES THE REPORT, deliberately. The first cut carried a --quiet that
  # suppressed the census, and the census is the answer to the question the row
  # was filed on ("31 open, 1 dispatchable") — a flag that hides it is a flag
  # that reproduces the 42h. It was also accepted and then ignored, which is
  # worse than absent, and that is still the bar every flag here is held to:
  # --to and --dry-run are REFUSED without --fix rather than parsed into
  # nothing (DIVE-3826).
  local fix_target="" fix_to="" fix_dry=0 have_fix=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fix=*)   have_fix=1; fix_target="${1#*=}" ;;
      --fix)     have_fix=1
                 [[ $# -ge 2 && "$2" != -* ]] \
                   || fail "$E_USAGE" "--fix needs the row to repair: 5dive task doctor --fix <id|DIVE-N> [--to=<agent>] [--dry-run]  (there is no --fix-all: one row is one decision)"
                 fix_target="$2"; shift ;;
      --to=*)    fix_to="${1#*=}" ;;
      --dry-run) fix_dry=1 ;;
      -*) fail "$E_USAGE" "unknown flag: $1 (usage: 5dive task doctor [--fix <id|DIVE-N> [--to=<agent>] [--dry-run]])" ;;
      *)  fail "$E_USAGE" "unexpected argument '$1' (usage: 5dive task doctor [--fix <id|DIVE-N> [--to=<agent>] [--dry-run]])" ;;
    esac
    shift
  done
  if [[ "$have_fix" == "0" ]]; then
    [[ -z "$fix_to" ]] || fail "$E_USAGE" "--to only applies with --fix: 5dive task doctor --fix <id|DIVE-N> --to=<agent>"
    [[ "$fix_dry" == "0" ]] || fail "$E_USAGE" "--dry-run only applies with --fix — a bare 'doctor' already changes nothing"
  else
    [[ -n "$fix_target" ]] || fail "$E_USAGE" "--fix needs the row to repair: 5dive task doctor --fix <id|DIVE-N> [--to=<agent>] [--dry-run]"
    _task_doctor_fix "$fix_target" "$fix_to" "$fix_dry"
    return $?
  fi

  # ---- pass 1: the three roster-free classes -------------------------------
  # dbfmt -json prints NOTHING for an empty result set (DIVE-1610), not "[]".
  # Normalise before jq so a clean board is a clean board and not a parse error
  # reported as zero findings.
  local rows; rows=$(dbfmt -json "$(_task_doctor_board_sql);")
  [[ -n "$rows" ]] || rows='[]'
  local findings; findings=$(printf '%s' "$rows" | jq -c '[.[] | select(.reason != null)]')

  # ---- pass 2: the lane class ---------------------------------------------
  # DEGRADE, never refuse: the classes above are already computed and are true
  # whatever the registry says. A verb that threw them away because agents.json
  # was unreadable would hide the stale edges behind a registry problem.
  local lane_note="" lanes=""
  lanes=$(_task_roster_sql_notin)
  if [[ -z "$lanes" ]]; then
    lane_note="lane check SKIPPED — the agent roster is ${_TASK_ROSTER_STATE:-unknown}; with no roster every lane would read as dead. Fix the registry first: 5dive doctor"
  else
    # Two sub-cases, ONE finding class, because the operator's remedy is the same
    # verb either way: the name is not on the roster at all (what `orphans`
    # reports, repeated here so one command is one answer), or it is on the
    # roster and the heartbeat tick will never iterate it.
    local lane seen="" bad_lanes=""
    while IFS= read -r lane; do
      [[ -n "$lane" ]] || continue
      case " $seen " in *" $lane "*) continue ;; esac
      seen+=" $lane"
      # `&& rc=0 || rc=$?`, never `; rc=$?`: under the bundle's `set -euo
      # pipefail` an assignment taking a non-zero substitution kills the verb
      # before the next line, which is how `orphans` once died mid-listing.
      local rc; _task_doctor_lane_wakeable "$lane" && rc=0 || rc=$?
      if [[ "$rc" == "2" ]]; then
        [[ -n "$lane_note" ]] || lane_note="heartbeat check SKIPPED for some lanes — ${STATE_DIR:-/var/lib/5dive}/agents.json could not be read"
        continue
      fi
      [[ "$rc" == "0" ]] && continue
      bad_lanes+="${bad_lanes:+,}$(sqlq "$lane")"
    done < <(db "SELECT DISTINCT assignee FROM tasks
                  WHERE kind='standard' AND status IN ('todo','in_progress','blocked')
                    AND assignee IS NOT NULL AND assignee!='';" 2>/dev/null || true)
    if [[ -n "$bad_lanes" ]]; then
      local lrows; lrows=$(dbfmt -json "SELECT ident, status, COALESCE(assignee,'') AS assignee,
              'dead-lane' AS reason, '' AS wake_at, NULL AS blockers, substr(title,1,58) AS title
         FROM tasks
        WHERE kind='standard' AND status IN ('todo','in_progress','blocked')
          AND assignee IN (${bad_lanes}) ORDER BY id;")
      [[ -n "$lrows" ]] || lrows='[]'
      # A row can be BOTH (parked AND on a dead lane). Keep the first classification
      # so a finding is counted once; the lane is still named in its own line below.
      findings=$(jq -c -n --argjson a "$findings" --argjson b "$lrows" \
        '$a + [ $b[] | select( . as $r | ($a | map(.ident) | index($r.ident)) == null ) ]')
    fi
  fi

  local n; n=$(printf '%s' "$findings" | jq 'length')

  # ---- census: what the REST of the open board is waiting on ---------------
  # The row was filed on "31 open, 1 dispatchable" — so the count of rows that
  # are legitimately waiting, and what each is waiting FOR, is the answer to the
  # question that was actually asked. Without it a clean run prints "no findings"
  # over a board that is still 30-deep in holds, which is how the 42h happened.
  local census; census=$(db "SELECT
      (SELECT COUNT(*) FROM tasks WHERE kind='standard' AND status IN ('todo','in_progress','blocked')) || '|' ||
      (SELECT COUNT(*) FROM tasks WHERE kind='standard' AND status='todo' AND parked_at IS NULL) || '|' ||
      (SELECT COUNT(*) FROM tasks WHERE kind='standard' AND status='in_progress') || '|' ||
      (SELECT COUNT(*) FROM tasks WHERE kind='standard' AND status NOT IN ('done','cancelled')
          AND parked_at IS NOT NULL AND wake_at IS NOT NULL AND wake_at > datetime('now')) || '|' ||
      (SELECT COUNT(*) FROM tasks WHERE kind='standard' AND status NOT IN ('done','cancelled')
          AND need_type IS NOT NULL AND need_answered_at IS NULL) || '|' ||
      (SELECT COUNT(*) FROM tasks t WHERE t.kind='standard' AND t.status='blocked'
          AND EXISTS (SELECT 1 FROM task_deps d JOIN tasks b ON b.id=d.blocked_by
                      WHERE d.task_id=t.id AND b.status NOT IN ('done','cancelled'))) || '|' ||
      (SELECT COALESCE(MIN(wake_at),'') FROM tasks WHERE kind='standard' AND status NOT IN ('done','cancelled')
          AND parked_at IS NOT NULL AND wake_at IS NOT NULL AND wake_at > datetime('now'));" 2>/dev/null || echo "")
  local c_open c_todo c_prog c_park c_gate c_dep c_nextwake
  IFS='|' read -r c_open c_todo c_prog c_park c_gate c_dep c_nextwake <<<"${census:-0|0|0|0|0|0|}"
  local census_line="open ${c_open:-0}: ${c_todo:-0} dispatchable now, ${c_prog:-0} in progress, ${c_park:-0} parked${c_nextwake:+ (next wakes ${c_nextwake}Z)}, ${c_gate:-0} awaiting a human gate, ${c_dep:-0} behind a live blocker"

  local payload='{findings:($f|length), rows:$f, census:{open:($o|tonumber), dispatchable:($t|tonumber), inProgress:($p|tonumber), parked:($pk|tonumber), gated:($g|tonumber), blockedLive:($d|tonumber), nextWake:(($w|select(length>0)) // null)}, laneCheck:(($ln|select(length>0)) // null)}'
  local -a jargs=( --argjson f "$findings" --arg o "${c_open:-0}" --arg t "${c_todo:-0}" --arg p "${c_prog:-0}"
                   --arg pk "${c_park:-0}" --arg g "${c_gate:-0}" --arg d "${c_dep:-0}"
                   --arg w "${c_nextwake:-}" --arg ln "$lane_note" )

  [[ -z "$lane_note" ]] || warn "$lane_note"

  if [[ "${n:-0}" == "0" ]]; then
    ok "no undispatchable rows — every open row has a live revisit anchor and a wakeable assignee
  ${census_line}" "$payload" "${jargs[@]}"
    return 0
  fi

  # Read the JSON back rather than raw `db` output: the default `|` separator
  # would split any title containing one.
  local out="" line ident st asg reason wake blockers title
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ident=$(printf '%s' "$line"   | jq -r '.ident')
    st=$(printf '%s' "$line"      | jq -r '.status')
    asg=$(printf '%s' "$line"     | jq -r '.assignee // ""')
    reason=$(printf '%s' "$line"  | jq -r '.reason')
    wake=$(printf '%s' "$line"    | jq -r '.wake_at // ""')
    blockers=$(printf '%s' "$line"| jq -r '.blockers // ""')
    title=$(printf '%s' "$line"   | jq -r '.title // ""')
    out+="  ${ident}  [${st}${asg:+ · }${asg}]  ${reason}"$'\n'
    out+="        ${title}"$'\n'
    out+="        $(_task_doctor_explain "$reason")"$'\n'
    [[ -n "$wake"     ]] && out+="        wake_at: ${wake}Z"$'\n'
    [[ -n "$blockers" ]] && out+="        blockers: ${blockers}"$'\n'
  done < <(printf '%s' "$findings" | jq -c '.[]')

  warn "${n} open row(s) nothing will dispatch — each is counted as work in flight and none of them is:
${out}${census_line}
Nothing above was changed: mass-clearing a board is its own failure mode. Run the named verb per row,
or have this command run it for ONE row: 5dive task doctor --fix <ident> [--to=<agent> for a dead lane] [--dry-run]"
  ok "" "$payload" "${jargs[@]}"
}
