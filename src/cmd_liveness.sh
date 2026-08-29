
# -------- 5dive liveness — effect-derived liveness (DIVE-3778) --------
#
# The v0.23 headline capability ("Liveness you cannot fake", ratified 2026-08-26
# on DIVE-3738). Every liveness read this fleet had before this file answers a
# question nobody asked: *is something present?* — a systemd unit is active, a
# tmux session exists, a `pgrep` matches, a pane says the word `Rate-limited`, a
# `lastRunAt` column holds a value. Each of those is a claim ABOUT a seat, made
# by someone else, and each of them read GREEN through every incident the theme
# was named from:
#
#   * DIVE-3726/DIVE-3748 — a dead telegram poller behind every green signal but
#     the process table.
#   * DIVE-3723 — a seat sitting at a login screen, holding the only startable
#     row on the board: alive, scheduled, structurally unable, nothing reporting.
#   * dev3 held four rows for three days on an expired quota while every liveness
#     signal read healthy (main's carrier at ratification).
#   * DIVE-3711 — `memory consolidate` exiting 0 having written nothing.
#
# So this command refuses to read any of them. **A seat is alive here only
# against a timestamped artifact the seat itself WROTE**, dated, and named in the
# output so the operator can go look at it. If the seat produced no effect inside
# the window, it is not alive — however healthy it looks from outside.
#
# WHAT IS DELIBERATELY NOT A PROBE. `signals.service`, `signals.tmux`,
# `signals.poller` and the pane scrapes in `cmd_supervisor.sh` are all absent by
# design, not by omission. Adding one back would make this command exactly as
# fakeable as the thing it replaces: a process can be present having written
# nothing for three days, which is the incident. Supervisor's signals stay useful
# for REMEDIATION (rung 4 restarts a dead poller); they are not evidence of life.
#
# THE THIRD STATE. `not-reached` is a first-class verdict and never folds into
# either neighbour (v0.16 "Fails loud" lineage; the absent-vs-forbidden collapse
# this codebase keeps paying for — DIVE-1927, DIVE-1989, DIVE-2073, DIVE-2210).
# A probe that could not RUN — no tasks store, an audit log this uid cannot read,
# a missing table — tells you nothing about the seat, and:
#
#   * it must not read as `alive`   — that is the false green the theme is named
#     after, and it is the cheap failure: an unreadable store would certify the
#     whole fleet healthy in one pass;
#   * it must not read as `no-effect` either — accusing a working seat of being
#     dead because OUR probe broke burns the operator's trust in the alarm, and
#     after two of those nobody reads the third one.
#
# Positive evidence still wins over a broken probe: one readable source with a
# fresh artifact is proof of life whatever the other sources did, so a degraded
# probe set is recorded in `degraded[]` and does not suppress a real effect.
#
# EFFECT SOURCES — all three are things the seat WROTE, attributed to it, dated:
#   board   the shared task store: `started_at` / `done_at` on a row whose
#           assignee is this seat. The seat wrote those by running `task
#           start` / `task done`. (`updated_at` is NOT read — a third party
#           editing the row bumps it, so it is someone else's effect.)
#   ledger  `lifecycle_events` — the durable-action ledger (INST-8), `actor` =
#           this seat. One row per irreversible act it actually performed.
#   audit   the tamper-evident audit log — a line whose resolved actor is this
#           seat's unix user. Written server-side by the privileged appender,
#           so the seat cannot backdate or drop its own rows (DIVE-1268).
#
# A customer-visible fleet-health PAGE is a public claim and gates lodar (the
# v0.14 badge guardrail, restated on DIVE-3778). This is CLI output and an
# internal verdict: not a publish. Nothing here renders to a web surface.

_LIV_WINDOW_MIN_DEFAULT=60
_LIV_AUDIT_TAIL=4000

_liv_usage() {
  cat <<USAGE
5dive liveness — is a seat alive, measured against artifacts it WROTE (DIVE-3778)

  5dive liveness                         # every registered seat + the box's own claude seat
  5dive liveness --agent=<name>          # one seat (does not need the registry)
  5dive liveness --window=<minutes>      # freshness window (default ${_LIV_WINDOW_MIN_DEFAULT}m)
  5dive liveness --json                  # machine-readable records

Verdicts — three, and the third never collapses into the other two:
  alive         a timestamped artifact this seat wrote, inside the window. Named in the output.
  no-effect     every probe RAN and found nothing this seat wrote inside the window.
  not-reached   at least one probe could not run and nothing positive was found. UNKNOWN,
                not healthy: this is the state a process-presence check silently calls green.

Exit: 0 every seat alive - 4 some seat has no effect - 3 some seat not-reached - 2 usage.

Read-only. No process table, no tmux, no pane scrape — a present process that wrote
nothing for three days is the incident this command exists to catch, not evidence.
USAGE
}

# _liv_epoch <timestamp> -> unix epoch, or rc 1.
# Two formats reach here and they are NOT interchangeable: sqlite's
# datetime('now') is unqualified UTC ("2026-08-28 04:12:33"), while the audit
# log's date -Iseconds carries its own offset. Reading the first as local time
# is a silent hours-wide error in the direction that invents freshness, so the
# unqualified form is pinned to UTC explicitly.
_liv_epoch() {
  local ts="${1:-}" e
  [[ -n "$ts" ]] || return 1
  case "$ts" in
    *T*) e=$(date -d "$ts"     +%s 2>/dev/null) ;;
    *)   e=$(date -d "$ts UTC" +%s 2>/dev/null) ;;
  esac
  [[ "$e" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$e"
}

# _liv_is_fresh <epoch> <now> <window-sec>
# A stamp in the FUTURE counts as an effect: clock skew between the writer and
# this reader is not evidence of death, and treating it as stale would make a
# skewed box report its whole fleet dead.
_liv_is_fresh() {
  local e="${1:-}" now="$2" w="$3"
  [[ "$e" =~ ^[0-9]+$ ]] || return 1
  (( e > now )) && return 0
  (( now - e <= w ))
}

# _liv_verdict <fresh-source-count> <unreadable-source-count> -> verdict
#
# The whole theme is these five lines, in this order. Positive evidence first
# (a real artifact outranks a broken probe); then the third state; only a
# COMPLETE, SUCCESSFUL, EMPTY read is allowed to say a seat produced nothing.
_liv_verdict() {
  local fresh="${1:-0}" unreadable="${2:-0}"
  if (( fresh > 0 ));      then printf 'alive\n';       return 0; fi
  if (( unreadable > 0 )); then printf 'not-reached\n'; return 0; fi
  printf 'no-effect\n'
}

# Each probe prints: <state>|<epoch-or-empty>|<artifact-or-reason>, one line,
# fields split on the unit separator so a reason containing spaces/pipes is safe.
# state is `read` (the probe ran; the epoch may still be empty = ran, found
# nothing) or `unreadable` (the probe did NOT run; the epoch is meaningless).
_liv_probe_out() { printf '%s\037%s\037%s\n' "$1" "${2:-}" "${3:-}"; }

# board — started_at / done_at on rows assigned to this seat.
_liv_probe_board() {
  local seat="$1" row ident stamp
  [[ -f "$TASKS_DB" ]] || { _liv_probe_out unreadable "" "no task store at ${TASKS_DB}"; return 0; }
  [[ -r "$TASKS_DB" ]] || { _liv_probe_out unreadable "" "task store not readable by this uid"; return 0; }
  # Bare `ident` beside MAX(stamp) is sqlite's documented bare-column form: it
  # comes from the row that produced the max, so the artifact named is the one
  # that dated the seat.
  row=$(db "SELECT COALESCE(ident,'?'), MAX(stamp) FROM (
              SELECT ident, done_at    AS stamp FROM tasks WHERE assignee=$(sqlq "$seat") AND done_at    IS NOT NULL
              UNION ALL
              SELECT ident, started_at AS stamp FROM tasks WHERE assignee=$(sqlq "$seat") AND started_at IS NOT NULL
            );" 2>/dev/null) || { _liv_probe_out unreadable "" "task store query failed"; return 0; }
  ident="${row%%|*}"; stamp="${row#*|}"
  [[ "$row" == *"|"* && -n "$stamp" ]] || { _liv_probe_out read "" "no row this seat started or closed"; return 0; }
  local e; e=$(_liv_epoch "$stamp") || { _liv_probe_out read "" "unparseable stamp '${stamp}'"; return 0; }
  _liv_probe_out read "$e" "${ident} @ ${stamp}"
}

# ledger — lifecycle_events rows this seat is the actor of.
# A store predating the table errors here and lands as `unreadable`, which is
# the honest answer: the probe did not run. It is not "the seat did nothing".
_liv_probe_ledger() {
  local seat="$1" row kind stamp
  [[ -f "$TASKS_DB" ]] || { _liv_probe_out unreadable "" "no task store at ${TASKS_DB}"; return 0; }
  [[ -r "$TASKS_DB" ]] || { _liv_probe_out unreadable "" "task store not readable by this uid"; return 0; }
  row=$(db "SELECT COALESCE(kind,'?'), MAX(ts) FROM lifecycle_events WHERE actor=$(sqlq "$seat");" 2>/dev/null) \
    || { _liv_probe_out unreadable "" "lifecycle_events unqueryable (absent table or I/O)"; return 0; }
  kind="${row%%|*}"; stamp="${row#*|}"
  [[ "$row" == *"|"* && -n "$stamp" ]] || { _liv_probe_out read "" "no durable action by this seat"; return 0; }
  local e; e=$(_liv_epoch "$stamp") || { _liv_probe_out read "" "unparseable ts '${stamp}'"; return 0; }
  _liv_probe_out read "$e" "${kind} @ ${stamp}"
}

# audit — a line in the tamper-evident log whose resolved actor is this seat.
# Matched on the unix user (`agent-<seat>`) AND on `derived`, because DIVE-2518
# carries the measured uid separately from the claimed one; either identifies
# the writer. The bare seat name is accepted too for the box's `claude` seat.
_liv_probe_audit() {
  local seat="$1" unix="$2" out cmd stamp
  [[ -e "$AUDIT_LOG" ]] || { _liv_probe_out unreadable "" "audit log absent at ${AUDIT_LOG}"; return 0; }
  [[ -r "$AUDIT_LOG" ]] || { _liv_probe_out unreadable "" "audit log not readable by this uid"; return 0; }
  # `-n` is load-bearing: with -R and no -n, jq applies the filter to the FIRST
  # line and `inputs` yields only lines 2..N, so a single-line log reads as empty
  # — an effect the seat wrote would silently become "no audit row".
  out=$(tail -n "$_LIV_AUDIT_TAIL" "$AUDIT_LOG" 2>/dev/null \
        | jq -nRr --arg u "$unix" --arg n "$seat" '
            [ inputs | fromjson? | select(.ts)
              | select((.user? == $u) or (.derived? == $u) or (.user? == $n) or (.derived? == $n)) ]
            | if length == 0 then "" else (max_by(.ts) | "\(.ts) \(.cmd // "cmd")") end' 2>/dev/null) \
    || { _liv_probe_out unreadable "" "audit log unparseable"; return 0; }
  [[ -n "$out" ]] || { _liv_probe_out read "" "no audit row written by this seat"; return 0; }
  stamp="${out%% *}"; cmd="${out#* }"
  local e; e=$(_liv_epoch "$stamp") || { _liv_probe_out read "" "unparseable ts '${stamp}'"; return 0; }
  _liv_probe_out read "$e" "${cmd} @ ${stamp}"
}

# _liv_seat_record <seat> <unix-user> <now> <window-sec> -> one JSON record
_liv_seat_record() {
  local seat="$1" unix="$2" now="$3" w="$4"
  local fresh=0 unreadable=0 probes="[]" best_src="" best_age=-1 best_art="" degraded=""
  local src rec state epoch note age

  for src in board ledger audit; do
    case "$src" in
      board)  rec=$(_liv_probe_board  "$seat") ;;
      ledger) rec=$(_liv_probe_ledger "$seat") ;;
      audit)  rec=$(_liv_probe_audit  "$seat" "$unix") ;;
    esac
    IFS=$'\037' read -r state epoch note <<<"$rec"
    age=-1
    [[ "$epoch" =~ ^[0-9]+$ ]] && age=$(( now - epoch ))
    if [[ "$state" == "unreadable" ]]; then
      unreadable=$(( unreadable + 1 ))
      degraded+="${degraded:+; }${src}: ${note}"
    elif _liv_is_fresh "$epoch" "$now" "$w"; then
      fresh=$(( fresh + 1 ))
      # Report the FRESHEST artifact as the evidence line: it is the strongest
      # thing we can hand an operator who wants to check the verdict by hand.
      if (( best_age < 0 )) || (( age < best_age )); then
        best_src="$src"; best_age="$age"; best_art="$note"
      fi
    fi
    probes=$(jq -c --arg s "$src" --arg st "$state" --arg n "$note" \
                   --argjson ep "${epoch:-null}" --argjson ag "$age" \
      '. + [{source:$s, state:$st, artifact:(if $n=="" then null else $n end),
             epoch:$ep, ageSec:(if $ag < 0 then null else $ag end)}]' <<<"$probes")
  done

  local verdict; verdict=$(_liv_verdict "$fresh" "$unreadable")
  local reason=""
  case "$verdict" in
    alive)       reason="wrote ${best_src}: ${best_art}" ;;
    no-effect)   reason="all 3 probes ran; nothing written by this seat in the last $(( w / 60 ))m" ;;
    not-reached) reason="${unreadable} of 3 probes did not run and no fresh artifact was found — UNKNOWN, not healthy" ;;
  esac

  jq -cn --arg seat "$seat" --arg unix "$unix" --arg v "$verdict" --arg r "$reason" \
         --arg es "$best_src" --arg ea "$best_art" --arg dg "$degraded" \
         --argjson probes "$probes" --argjson fresh "$fresh" --argjson unread "$unreadable" \
         --argjson w "$w" --argjson age "$best_age" \
    '{seat:$seat, unixUser:$unix, windowSec:$w, verdict:$v, reason:$r,
      evidence:(if $es == "" then null else {source:$es, artifact:$ea, ageSec:$age} end),
      probes:$probes, freshSources:$fresh, unreadableSources:$unread,
      degraded:(if $dg == "" then [] else ($dg|split("; ")) end)}'
}

# The roster. A registry we could not READ is itself a not-reached — it must not
# quietly produce a one-seat or zero-seat fleet that then renders all-green
# (registry_read()'s empty-body fallback is exactly that hazard, which is why
# the checked variant is used here).
_liv_roster() {
  local body rc=0
  body=$(registry_read_checked) || rc=$?
  case "$rc" in
    0) : ;;
    3) printf 'ROSTER-NOT-REACHED\037no agent registry at %s\n' "$REGISTRY"; return 0 ;;
    4) printf 'ROSTER-NOT-REACHED\037agent registry present but unreadable by this uid\n'; return 0 ;;
    *) printf 'ROSTER-NOT-REACHED\037agent registry is not parseable JSON\n'; return 0 ;;
  esac
  local n
  for n in $(jq -r '.agents | keys[]' <<<"$body" 2>/dev/null); do
    printf '%s\037agent-%s\n' "$n" "$n"
  done
  # The box's own main seat writes to all three sources under its own uid and is
  # as capable of dying silently as any agent (DIVE-3748 hit it first).
  printf 'claude\037claude\n'
}

cmd_liveness() {
  local window_min="$_LIV_WINDOW_MIN_DEFAULT" only=""
  local a
  for a in "$@"; do
    case "$a" in
      --json)      JSON_MODE=1 ;;
      --agent=*)   only="${a#--agent=}" ;;
      --window=*)  window_min="${a#--window=}" ;;
      -h|--help)   _liv_usage; return 0 ;;
      *) fail "$E_USAGE" "unknown argument '$a'. See 5dive liveness --help." ;;
    esac
  done
  [[ "$window_min" =~ ^[0-9]+$ ]] && (( window_min > 0 )) \
    || fail "$E_USAGE" "--window takes a positive whole number of minutes, got '${window_min}'."

  local now w; now=$(date +%s); w=$(( window_min * 60 ))

  local -a seats=() unixes=()
  local roster_note=""
  if [[ -n "$only" ]]; then
    seats+=("$only")
    # The box seat's unix user is its own name; every agent seat is agent-<name>.
    if [[ "$only" == "claude" ]]; then unixes+=("claude"); else unixes+=("agent-${only}"); fi
  else
    local line n u
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      n="${line%%$'\037'*}"; u="${line#*$'\037'}"
      if [[ "$n" == "ROSTER-NOT-REACHED" ]]; then roster_note="$u"; continue; fi
      seats+=("$n"); unixes+=("$u")
    done < <(_liv_roster)
  fi

  local records="[]" i rec
  for i in "${!seats[@]}"; do
    rec=$(_liv_seat_record "${seats[$i]}" "${unixes[$i]}" "$now" "$w")
    records=$(jq -c --argjson r "$rec" '. + [$r]' <<<"$records")
  done

  local n_alive n_none n_nr
  n_alive=$(jq '[.[]|select(.verdict=="alive")]|length'       <<<"$records")
  n_none=$(jq  '[.[]|select(.verdict=="no-effect")]|length'   <<<"$records")
  n_nr=$(jq    '[.[]|select(.verdict=="not-reached")]|length' <<<"$records")

  # A roster we could not read is counted as a not-reached in its own right, so
  # it can never be the difference between rc 0 and a silent all-green.
  local rc=0
  if   (( n_none > 0 ));                          then rc=4
  elif (( n_nr > 0 )) || [[ -n "$roster_note" ]]; then rc=3
  fi

  if (( JSON_MODE )); then
    jq -cn --argjson seats "$records" --argjson w "$w" --argjson na "$n_alive" \
           --argjson nn "$n_none" --argjson nr "$n_nr" --arg roster "$roster_note" \
      '{ok:true, data:{windowSec:$w, seats:$seats,
        summary:{alive:$na, noEffect:$nn, notReached:$nr},
        roster:(if $roster == "" then "read" else "not-reached" end),
        rosterNote:(if $roster == "" then null else $roster end)}}'
  else
    printf 'effect-derived liveness — window %dm, evidence is an artifact the seat WROTE\n\n' "$window_min"
    printf '%-14s %-12s %s\n' SEAT VERDICT EVIDENCE
    jq -r '.[] | [.seat, .verdict,
                  (if .evidence then "\(.evidence.source): \(.evidence.artifact) (\(.evidence.ageSec)s ago)" else .reason end)]
                 | @tsv' <<<"$records" \
      | while IFS=$'\t' read -r s v e; do printf '%-14s %-12s %s\n' "$s" "$v" "$e"; done
    jq -r '.[] | select((.degraded|length) > 0) | "  degraded probes on \(.seat): \(.degraded|join("; "))"' <<<"$records"
    [[ -n "$roster_note" ]] && printf '\nroster: NOT-REACHED — %s\n' "$roster_note"
    printf '\n%d alive, %d no-effect, %d NOT-REACHED (of %d seat(s))\n' \
      "$n_alive" "$n_none" "$n_nr" "${#seats[@]}"
    if (( n_nr > 0 )) || [[ -n "$roster_note" ]]; then
      printf 'NOT-REACHED is not a pass: those seats were not measured.\n'
    fi
  fi
  # DIVE-2598: a deliberate non-zero exit must claim its reason, or the EXIT-trap
  # backstop prints "exited N without reporting a reason … the command did NOT run
  # to completion and its effect is UNKNOWN" over a run that completed perfectly.
  # Measured on the built bundle before this line existed: the fleet board printed
  # in full and was then followed by a 500-byte CLI-bug diagnostic. A liveness
  # verdict that ends by telling the operator to distrust it is worse than none.
  (( rc != 0 )) && mark_reported
  return "$rc"
}
