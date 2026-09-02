# -------- 5dive a2a — read the agent-to-agent round ledger (DIVE-3903) --------
#
# WHY THIS VERB EXISTS. DIVE-3902 asked for per-seat "a2a recaps" on the floor
# and instructed: BIND THE SEND LOG, DO NOT INVENT IT. dev2 followed that and
# produced a negative result that is the durable finding — the send log exists
# and NO amount of 5dive-api work can reach it
# (community/wiki/the-a2a-send-log-exists-and-is-unreachable-from-the-api.md):
#
#   * `/files` clamps every path to ROOT="/home", so /var/lib and /var/log are
#     out of range BY CONSTRUCTION, not by permission.
#   * `/shell/exec` executes `5dive <verb>` argv. There is no `cat`, and until
#     this file there was no verb that emitted either source as JSON.
#
# The floor is a projection of `5dive <verb> --json` calls, so "can the floor
# show X" always reduces to "is there a verb that prints X". This is that verb.
# No field may be added to the floor payload before it (DIVE-3902 constraint A:
# a field that reads nothing on every existing box is decoration, and a dead
# field is worse than an absent one because absence is visible on the board).
#
# WHY THE LEDGER AND NOT THE AUDIT LOG. Two sources carry this traffic:
#
#   /var/log/5dive/agent-audit.log   0640 root:claude   one row per send, with
#                                                       from_derived= and bytes=
#   /var/lib/5dive/a2a-rounds.tsv    0660 root:claude   from⇥to⇥topic⇥unix_ts
#
# The ledger wins on both axes that matter here. It needs NO ROOT for a member
# of group `claude` — which every agent seat is, and which the audit log's 0640
# is not — and it carries NO MESSAGE TEXT AT ALL. A recap wants "who talked to
# whom about what, when"; a source that structurally cannot carry customer prose
# is one fewer clause-3 argument to have, not a weaker source. The ONE field that
# is message-derived is `topic`, and it is bounded to /[A-Z][A-Z0-9]+-[0-9]+/ or
# the literal `pair` by a2a_topic_of — so it can carry an ident-shaped token that
# is not a row of ours (`GPT-5` is in the live ledger) but it cannot carry prose.
# `bytes=` per
# sender stays where it already is, on `5dive digest` (a2a_rounds_report), which
# says so out loud when it cannot read the log rather than rendering a quiet
# fleet.
#
# THIS IS A READ AND A GROUP-BY, NOT A NEW TABLE. DIVE-3902's row said a new
# table here is a wrong turn and that still holds: the ledger already has
# exactly the four columns a recap needs. Nothing in this file writes, prunes,
# locks or chmods anything — the writer half of that contract lives in
# `a2a_record_round` / `a2a_round_prune` (src/lib/a2a_rounds.sh) and DIVE-3658
# paid for its mode handling twice. A reader that repairs the file it reads is a
# writer wearing a reader's name.
#
# THREE SOURCE STATES, AND THE THIRD NEVER FOLDS INTO THE OTHER TWO. This is the
# absent-vs-forbidden collapse this codebase keeps paying for (DIVE-1927,
# DIVE-1989, DIVE-2073, DIVE-2210, and `not-reached` in cmd_liveness.sh):
#
#   read        the ledger was read. Zero rows means zero traffic.
#   absent      no ledger file. A fresh box that has never had a send. Zero
#               rows means zero traffic here TOO, and that is a real answer.
#   unreadable  the file is there and this uid cannot read it. UNKNOWN. It must
#               NOT render as a quiet fleet — a silent ledger and an unreadable
#               one are byte-identical downstream, and the quiet one is the
#               cheap wrong answer. Exits 3 for the same reason liveness does.
#
# MALFORMED ROWS ARE COUNTED, NOT DROPPED SILENTLY, for the same reason: a
# corrupt ledger that reads as an idle fleet is the failure mode, so
# `source.malformedRows` is on every payload and the text mode prints it.
#
# THE WINDOW CANNOT EXCEED WHAT THE LEDGER KEEPS. `a2a_round_prune` trims the
# file to A2A_ROUND_WINDOW_SECS (24h) on the record path, so a `--window=168h`
# read is not a week of history — it is 24h of history with a week-shaped label
# on it. Asking for more than retention sets `source.windowExceedsRetention`
# and says so in text mode. Silently answering a question the data cannot
# support is the same class as the collapse above.

_A2A_WINDOW_HOURS_DEFAULT=24

_a2a_usage() {
  cat <<USAGE
5dive a2a — read-only views over the agent-to-agent round ledger (DIVE-3903)

  5dive a2a rounds                          # who has been talking to whom, per seat
  5dive a2a rounds --json                   # machine-readable; this is what the floor projects
  5dive a2a rounds --window=<hours>         # default ${_A2A_WINDOW_HOURS_DEFAULT}h (= the ledger's own retention)
  5dive a2a rounds --agent=<seat>           # one seat's partners and topics
  5dive a2a rounds --topic=<ident>          # one topic (a task ident, or 'pair' for identless chat)

Read-only and non-root: the ledger is 0660 root:claude and every agent seat is in
group claude. Nothing here writes, prunes or re-modes the file.

The ledger carries NO MESSAGE TEXT — only from, to, topic and a timestamp. 'topic'
is the first IDENT-SHAPED token in the message body (/[A-Z][A-Z0-9]+-[0-9]+/, so
usually a task row but 'GPT-5' also matches — measured live), or the literal
'pair' when there was none. See a2a_topic_of.

Source state is one of three and the third is not a pass:
  read        the ledger was read; zero rows means zero traffic
  absent      no ledger on this box yet; zero rows is a real answer
  unreadable  present and unreadable by this uid. UNKNOWN, exits 3, never green.
USAGE
}

cmd_a2a() {
  local sub="${1:-}"
  case "$sub" in
    rounds)      shift; cmd_a2a_rounds "$@" ;;
    ''|-h|--help) _a2a_usage; return 0 ;;
    *) fail "$E_USAGE" "unknown subcommand 'a2a ${sub}'. See 5dive a2a --help." ;;
  esac
}

cmd_a2a_rounds() {
  local window_hours="$_A2A_WINDOW_HOURS_DEFAULT" only="" topic_only=""
  local a
  for a in "$@"; do
    case "$a" in
      --json)      JSON_MODE=1 ;;
      --window=*)  window_hours="${a#--window=}" ;;
      --agent=*)   only="${a#--agent=}" ;;
      --topic=*)   topic_only="${a#--topic=}" ;;
      -h|--help)   _a2a_usage; return 0 ;;
      *) fail "$E_USAGE" "unknown argument '$a'. See 5dive a2a --help." ;;
    esac
  done
  [[ "$window_hours" =~ ^[0-9]+$ ]] && (( window_hours > 0 )) \
    || fail "$E_USAGE" "--window takes a positive whole number of hours, got '${window_hours}'."

  local ledger="$A2A_ROUND_LEDGER"
  local now w cutoff ret
  now=$(date +%s)
  w=$(( window_hours * 3600 ))
  cutoff=$(( now - w ))
  ret="$A2A_ROUND_WINDOW_SECS"

  # The three states, resolved BEFORE any read, so `absent` and `unreadable` are
  # distinguished by the filesystem rather than by an empty result.
  local state note=""
  if [[ ! -e "$ledger" ]]; then
    state="absent"
    note="no round ledger on this box yet — nothing has been sent through the a2a rail here"
  elif [[ ! -r "$ledger" ]]; then
    state="unreadable"
    # Report the mode/owner we actually STAT, never the 0660 root:claude the
    # writer intends. A note that asserts a mode it did not read is a guess
    # printed as a measurement, and the interesting case is precisely the one
    # where the file is NOT the mode it should be (DIVE-3658: a prune from a
    # root-capable seat used to leave 0644 behind and cut every scoped seat out
    # of the ledger — silently, because a quiet ledger reads as no traffic).
    local mode_seen
    mode_seen="$(stat -c '%a %U:%G' "$ledger" 2>/dev/null)" || mode_seen="mode unreadable"
    note="${ledger} exists and is not readable by $(id -un 2>/dev/null || echo "uid $EUID") (it is ${mode_seen}; the writer's intended mode is 0660 root:claude, so a seat in group claude should be able to read it). This is UNKNOWN, not an idle fleet."
  else
    state="read"
  fi

  # Filter in awk (window + optional seat/topic), group in jq. Malformed rows are
  # counted on a separate stream rather than discarded: see the header.
  local rows="" malformed=0
  if [[ "$state" == "read" ]]; then
    rows=$(awk -F'\t' -v c="$cutoff" -v only="$only" -v top="$topic_only" '
      NF == 0 { next }
      NF != 4 || $4 !~ /^[0-9]+$/ || $1 == "" || $2 == "" || $3 == "" { bad++; next }
      $4 < c { next }
      only != "" && $1 != only && $2 != only { next }
      top  != "" && $3 != top { next }
      { printf "%s\t%s\t%s\t%s\n", $1, $2, $3, $4 }
      END { printf "\037%d\n", bad+0 }
    ' "$ledger" 2>/dev/null) || {
      # An awk that could not run is not an empty ledger. Same third state.
      state="unreadable"
      note="the ledger scan failed on ${ledger} — the file was readable but could not be parsed. UNKNOWN, not an idle fleet."
      rows=""
    }
    if [[ -n "$rows" ]]; then
      malformed="${rows##*$'\037'}"
      malformed="${malformed%%$'\n'*}"
      rows="${rows%$'\037'*}"
      # Strip the trailing newline the marker line left behind.
      rows="${rows%$'\n'}"
    fi
    [[ "$malformed" =~ ^[0-9]+$ ]] || malformed=0
  fi

  local payload
  payload=$(printf '%s\n' "$rows" | jq -Rn \
      --argjson now "$now" --argjson w "$w" --argjson ret "$ret" \
      --argjson cap "$A2A_ROUND_CAP" --argjson mal "$malformed" \
      --arg path "$ledger" --arg state "$state" --arg note "$note" \
      --arg only "$only" --arg topicOnly "$topic_only" '
    def rows: [ inputs
                | select(length > 0)
                | split("\t")
                | select(length == 4)
                | {from: .[0], to: .[1], topic: .[2], ts: (.[3] | tonumber)} ];
    ( if $state == "read" then rows else [] end ) as $r
    # The seat list is the union of both endpoints, so a seat that only RECEIVED
    # in the window is still a row in the recap. Narrowed to the requested seat
    # when --agent is given, rather than also listing its partners at top level.
    | ( if $only != "" then [$only]
        else ([ $r[].from ] + [ $r[].to ] | unique) end ) as $seats
    | [ $r | group_by([.from, .to, .topic])[]
            | {from: .[0].from, to: .[0].to, topic: .[0].topic,
               rounds: length,
               lastAt: ([.[].ts] | max),
               # a2a_round_guard counts BEFORE it records, so a pair sitting at
               # exactly the cap is one where the NEXT send warns. Same predicate
               # a2a_rounds_report uses; named for what it predicts.
               nextSendWarns: (length >= $cap)} ]
      | sort_by(-.rounds, .from, .to, .topic) as $pairs
    # ONE pass per seat. An earlier shape grouped partners with `... as $p`
    # inside the object constructor, which jq rejects — group_by feeding map is
    # the form that composes, and it keeps topics on the same pass instead of
    # re-walking $r a second time.
    | [ $seats[]
        | . as $s
        | ( [ $r[] | select(.from == $s or .to == $s) ] ) as $mine
        | {seat: $s,
           sent: ([ $mine[] | select(.from == $s) ] | length),
           received: ([ $mine[] | select(.to == $s) ] | length),
           lastAt: (if ($mine | length) > 0 then ([ $mine[].ts ] | max) else null end),
           partners: ( [ $mine[]
                         | {peer: (if .from == $s then .to else .from end),
                            dir: (if .from == $s then "sent" else "received" end),
                            ts: .ts} ]
                       | group_by(.peer)
                       | map({seat: .[0].peer,
                              sent: ([ .[] | select(.dir == "sent") ] | length),
                              received: ([ .[] | select(.dir == "received") ] | length),
                              rounds: length,
                              lastAt: ([ .[].ts ] | max)})
                       | sort_by(-.rounds, .seat) ),
           topics: ( $mine
                     | group_by(.topic)
                     | map({topic: .[0].topic, rounds: length,
                            lastAt: ([ .[].ts ] | max)})
                     | sort_by(-.rounds, .topic) )} ]
      | sort_by(-(.sent + .received), .seat) as $seatRecords
    | {ok: true,
       data: {
         generatedAt: ($now | todate),
         windowSec: $w,
         roundCap: $cap,
         filter: {agent: (if $only == "" then null else $only end),
                  topic: (if $topicOnly == "" then null else $topicOnly end)},
         source: {path: $path,
                  state: $state,
                  note: (if $note == "" then null else $note end),
                  retentionSec: $ret,
                  windowExceedsRetention: ($w > $ret),
                  malformedRows: $mal},
         summary: {rounds: ($r | length),
                   seats: ($seatRecords | length),
                   pairs: ($pairs | length),
                   topics: ([ $r[].topic ] | unique | length),
                   pairsOverCap: ([ $pairs[] | select(.nextSendWarns) ] | length)},
         seats: $seatRecords,
         pairs: $pairs}}
  ') || fail "$E_GENERIC" "could not assemble the a2a rounds payload from ${ledger}."

  if (( JSON_MODE )); then
    printf '%s\n' "$payload"
  else
    _a2a_rounds_text "$payload" "$window_hours"
  fi

  # rc 3 = the source could not be read: UNKNOWN, and never rendered as a quiet
  # fleet. `absent` is rc 0 — it is a real answer, not a failed probe.
  # DIVE-2598: a deliberate non-zero exit must claim its reason, or the EXIT-trap
  # backstop prints a CLI-bug diagnostic over a run that completed perfectly.
  if [[ "$state" == "unreadable" ]]; then
    mark_reported
    return 3
  fi
  return 0
}

# Text mode. Rendered FROM the same payload the --json mode prints, so the two
# can never disagree about what was measured.
_a2a_rounds_text() {
  local payload="$1" hours="$2"
  local state rounds
  state=$(jq -r '.data.source.state' <<<"$payload")
  rounds=$(jq -r '.data.summary.rounds' <<<"$payload")

  printf '\U0001F4EC a2a rounds — last %sh, from %s\n' \
    "$hours" "$(jq -r '.data.source.path' <<<"$payload")"
  printf '   the ledger carries no message text: from, to, topic, timestamp only\n\n'

  if [[ "$state" != "read" ]]; then
    printf '%s: %s\n' "$(tr '[:lower:]' '[:upper:]' <<<"$state")" \
      "$(jq -r '.data.source.note // "(no detail)"' <<<"$payload")"
    [[ "$state" == "unreadable" ]] && printf 'This is not "no traffic" — nothing was measured.\n'
    _a2a_rounds_caveats "$payload" "$hours"
    return 0
  fi

  if [[ "$rounds" == "0" ]]; then
    printf '(no rounds in the window)\n'
  else
    printf '%-14s %5s %5s  %s\n' SEAT SENT RECV PARTNERS
    jq -r '.data.seats[]
           | [.seat, (.sent|tostring), (.received|tostring),
              ([.partners[] | "\(.seat)(\(.rounds))"] | join(" ")),
              ([.topics[]   | "\(.topic)×\(.rounds)"] | join(" "))]
           | @tsv' <<<"$payload" \
      | while IFS=$'\t' read -r s sent recv partners topics; do
          printf '%-14s %5s %5s  %s\n' "$s" "$sent" "$recv" "$partners"
          printf '%-14s %11s  on %s\n' "" "" "$topics"
        done
    local hot
    hot=$(jq -r '.data.summary.pairsOverCap' <<<"$payload")
    if [[ "$hot" != "0" ]]; then
      printf '\nat or over the cap of %s (the next send in that direction warns):\n' \
        "$(jq -r '.data.roundCap' <<<"$payload")"
      jq -r '.data.pairs[] | select(.nextSendWarns)
             | "  • \(.from) -> \(.to) on \(.topic): \(.rounds) rounds"' <<<"$payload"
    fi
    printf '\n%s rounds, %s seats, %s directed pairs, %s topics\n' \
      "$rounds" \
      "$(jq -r '.data.summary.seats'  <<<"$payload")" \
      "$(jq -r '.data.summary.pairs'  <<<"$payload")" \
      "$(jq -r '.data.summary.topics' <<<"$payload")"
  fi

  _a2a_rounds_caveats "$payload" "$hours"
  return 0
}

# The two ways this output can be quietly wrong: a window wider than the ledger's
# own retention, and a row that could not be parsed. Both are printed rather than
# only carried in the JSON, and both print on EVERY exit path — a mislabelled
# window is mislabelled whether or not the file was readable.
_a2a_rounds_caveats() {
  local payload="$1" hours="$2"
  if [[ "$(jq -r '.data.source.windowExceedsRetention' <<<"$payload")" == "true" ]]; then
    printf 'NOTE: asked for %sh but the ledger is pruned to %sh on write — this is %sh of history, labelled wider.\n' \
      "$hours" "$(( $(jq -r '.data.source.retentionSec' <<<"$payload") / 3600 ))" \
      "$(( $(jq -r '.data.source.retentionSec' <<<"$payload") / 3600 ))"
  fi
  local mal; mal=$(jq -r '.data.source.malformedRows' <<<"$payload")
  [[ "$mal" != "0" ]] && printf 'NOTE: %s malformed ledger row(s) skipped — the counts above are a floor, not a total.\n' "$mal"
  return 0
}
