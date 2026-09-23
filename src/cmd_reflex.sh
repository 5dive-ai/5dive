# cmd_reflex — decision receipts and the offline replay harness (DIVE-4866).
#
# Phase 0 of lodar's typed-decisions proposal (working name "reflex"). The
# receipts are written by src/lib/reflex.sh at the four places that already
# decide. This file READS them and changes nothing:
#
#   5dive reflex log     [--policy=<p>] [--limit=N] [--json]
#   5dive reflex replay  [--since=14d|YYYY-MM-DD] [--policy=<p>]
#                        [--backend=fake:echo|fake:first|fake:recommend|<command>]
#                        [--timeout=<seconds>] [--dump=<file>] [--json]
#   5dive reflex fake    [--strategy=echo|first|recommend]
#
# ── THE REPLAY ────────────────────────────────────────────────────────────────
# Builds one CASE per past decision, asks a candidate backend what it would have
# picked, and scores that pick against what actually happened. No model is
# involved unless you pass one as --backend.
#
# Where the cases come from. The live receipts (lifecycle_events kind=decision.*)
# where they exist. Before a policy's first live receipt, the same decisions are
# REBUILT from the ledger rows that already recorded them: task.created,
# task.rejected, task.reclaimed, and the answered gates in gate_history and on the
# rows. That is what lets the harness score two weeks of history on the day the
# receipts ship. Each case says which it came from (source=receipt|history).
#
# What "what actually happened" means, per policy. Each one is a PROXY, chosen
# because it is readable off the board today. None is ground truth:
#
#   task-route    the seat that did the work: the last maker to deliver it, else
#                 whoever closed it. Only rows that reached done are scored.
#   retry-action  retry_with_feedback when a delivery followed this reject and
#                 the row reached done. human when the row closed (done or
#                 cancelled) with no delivery after the reject. Open rows are not
#                 scored.
#   stuck         leave when the reaped seat delivered or closed the row within
#                 10 minutes of the reclaim (the session was still working, so the
#                 kill was early). reclaim once 10 minutes pass without that.
#   gate-answer   the answer the gate actually got, as a label (opt<N>, an
#                 approval verb, or other).
#
# The backend contract. One JSON request per line on stdin, one JSON response per
# line on stdout, in the same order (JSONL, so a thousand cases cost one process,
# not a thousand):
#
#   request   {"policy","version","type":"choice","state":{"task","signals",
#              "current"},"options":[...]}
#   response  {"choice":"<one of options>","confidence":<0..1|null>,
#              "probabilities":{...}|null,"probability_source":"logprob|head|verbal"|null}
#
# state.current is what today's code chose. It is absent on gate-answer, because
# there the thing being predicted IS the human's answer. The request never carries
# a title, a body or any gate text (src/lib/reflex.sh, "what a receipt may carry").
# A response whose choice is not one of the options, a malformed line, a missing
# line, or a backend that times out counts as INVALID. The case then falls back to
# state.current, which is the proposal's fail-closed rule, and the report counts
# every fallback.
#
# The fake backend (`reflex fake`, or --backend=fake:<strategy>) is deterministic
# and exists so the harness can be graded with no model at all:
#   echo       state.current (today's behaviour, scored against itself), else
#              the first option
#   first      options[0]
#   recommend  the gate's recommendation, else state.current, else options[0].
#              On gate-answer this reproduces the "answered with the
#              recommendation" rate.

_REFLEX_POLICIES="task-route retry-action stuck gate-answer"

cmd_reflex() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    log)    _reflex_log "$@" ;;
    replay) _reflex_replay "$@" ;;
    fake)   _reflex_fake "$@" ;;
    help|-h|--help)
      cat <<'EOF'
5dive reflex — decision receipts (phase 0: receipts + offline replay, no model)

  5dive reflex log     [--policy=<p>] [--limit=N] [--json]
  5dive reflex replay  [--since=14d|YYYY-MM-DD] [--policy=<p>]
                       [--backend=fake:echo|fake:first|fake:recommend|<command>]
                       [--timeout=<seconds>] [--dump=<file>] [--json]
  5dive reflex fake    [--strategy=echo|first|recommend]   (JSONL stdin -> stdout)

Policies: task-route, retry-action, stuck, gate-answer.
Receipts are written by the decision points themselves. Set
FIVEDIVE_REFLEX_RECEIPTS=0 to stop writing them. Nothing here changes behaviour.
EOF
      ;;
    *) fail "$E_USAGE" "unknown reflex subcommand: $sub (try: 5dive reflex help)" ;;
  esac
}

# Read-only SQL as a JSON array. Straight to sqlite3 and never through tasks_db_init:
# these verbs read, and must not migrate or create a store as a side effect.
_reflex_sql_json() {
  local out
  out=$(sqlite3 -json -cmd ".timeout 5000" "$TASKS_DB" "$1" 2>/dev/null) || out=""
  printf '%s\n' "${out:-[]}"
}

_reflex_need_store() {
  command -v jq >/dev/null 2>&1 || fail "$E_NOT_INSTALLED" "jq is required"
  [[ -r "${TASKS_DB:-}" ]] || fail "$E_NOT_FOUND" "task store not readable: ${TASKS_DB:-<unset>}"
}

_reflex_check_policy() {
  [[ -z "${1:-}" ]] && return 0
  grep -qw -- "$1" <<<"$_REFLEX_POLICIES" \
    || fail "$E_VALIDATION" "--policy must be one of: ${_REFLEX_POLICIES}"
}

_reflex_log() {
  local policy="" limit=20 a
  for a in "$@"; do
    case "$a" in
      --policy=*) policy="${a#*=}" ;;
      --limit=*)  limit="${a#*=}" ;;
      --json)     JSON_MODE=1 ;;
      *) fail "$E_USAGE" "unknown flag: $a" ;;
    esac
  done
  _reflex_check_policy "$policy"
  [[ "$limit" =~ ^[1-9][0-9]{0,4}$ ]] || fail "$E_VALIDATION" "--limit must be a positive integer"
  _reflex_need_store
  local where="kind LIKE 'decision.%'"
  [[ -n "$policy" ]] && where="kind=$(sqlq "decision.${policy}")"
  local rows
  rows=$(_reflex_sql_json "SELECT ts, detail FROM lifecycle_events WHERE ${where} ORDER BY id DESC LIMIT ${limit};")
  if (( JSON_MODE )); then
    jq -c '[ .[] | (.detail | fromjson? // {}) + {ledger_ts: .ts} ]' <<<"$rows"
    return 0
  fi
  local n; n=$(jq 'length' <<<"$rows")
  if [[ "$n" == "0" ]]; then
    printf 'no decision receipts%s yet\n' "${policy:+ for $policy}"
    return 0
  fi
  jq -r '.[] | (.detail | fromjson? // {}) as $r
    | "\(.ts)  \($r.policy // "?")\t\($r.task // "-")\t\($r.result // "?")\t\($r.effect | tostring)"' <<<"$rows"
}

# `reflex fake` — the deterministic backend. JSONL requests in, JSONL out.
_reflex_fake() {
  local strategy="echo" a
  for a in "$@"; do
    case "$a" in
      --strategy=*) strategy="${a#*=}" ;;
      *) fail "$E_USAGE" "unknown flag: $a" ;;
    esac
  done
  case "$strategy" in echo|first|recommend) ;; *) fail "$E_VALIDATION" "--strategy must be echo, first or recommend" ;; esac
  command -v jq >/dev/null 2>&1 || fail "$E_NOT_INSTALLED" "jq is required"
  jq -c --arg s "$strategy" '
    (.options // []) as $o
    | (if $s == "first" then $o[0]
       elif $s == "recommend" then (.state.signals.recommend // .state.current // $o[0])
       else (.state.current // $o[0]) end) as $c
    | {choice:$c, confidence:null, probabilities:null, probability_source:null,
       backend:{name:"fake", strategy:$s}}'
}

# _reflex_since_sql <spec> -> an SQL datetime expression
_reflex_since_sql() {
  local s="${1:-14d}"
  if [[ "$s" =~ ^([0-9]{1,4})d$ ]]; then
    printf "datetime('now', '-%d days')" "${BASH_REMATCH[1]}"
  elif [[ "$s" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf "datetime('%s')" "$s"
  else
    fail "$E_VALIDATION" "--since must be <N>d or YYYY-MM-DD (got: $s)"
  fi
}

# The cases, as JSONL on stdout. Every field a backend will see is built here, and
# the outcome is attached here, from the board as it stands now.
_reflex_build_cases() {
  local since="$1" only="${2:-}" d="$3"
  _reflex_sql_json >"$d/receipts.json" "SELECT ts, ident, task_id, actor, detail FROM lifecycle_events
                               WHERE kind LIKE 'decision.%' AND ts >= ${since} ORDER BY id;"
  _reflex_sql_json >"$d/hist_route.json" "SELECT ts, ident, task_id, actor, detail FROM lifecycle_events
                                 WHERE kind='task.created' AND ts >= ${since} ORDER BY id;"
  _reflex_sql_json >"$d/hist_reject.json" "SELECT ts, ident, task_id, actor, detail FROM lifecycle_events
                                  WHERE kind='task.rejected' AND ts >= ${since} ORDER BY id;"
  _reflex_sql_json >"$d/hist_reap.json" "SELECT ts, ident, task_id, actor, detail FROM lifecycle_events
                                WHERE kind='task.reclaimed' AND ts >= ${since} ORDER BY id;"
  # Answered gates: every retired epoch, plus the live one on the row. An epoch
  # moves to gate_history when it retires and the row's columns are cleared, so
  # the two halves never hold the same epoch. The answer TEXT is read here to be
  # labelled and goes no further than this process.
  _reflex_sql_json >"$d/gates.json" "
    SELECT need_answered_at AS ts, ident, task_id, need_type AS nt, COALESCE(need_options,'') AS opts,
           COALESCE(recommend,'') AS rec, need_answer AS ans, COALESCE(need_answered_by,'') AS \"by\",
           COALESCE(tier,'') AS tier
      FROM gate_history WHERE need_answer IS NOT NULL AND need_answer<>'' AND need_answered_at >= ${since}
    UNION ALL
    SELECT need_answered_at, ident, id, need_type, COALESCE(need_options,''), COALESCE(recommend,''),
           need_answer, COALESCE(need_answered_by,''), COALESCE(tier,'')
      FROM tasks WHERE need_answer IS NOT NULL AND need_answer<>'' AND need_answered_at >= ${since}
    ORDER BY 1;"
  _reflex_sql_json >"$d/tasks.json" "SELECT id, status FROM tasks WHERE id IN
            (SELECT task_id FROM lifecycle_events WHERE ts >= ${since} AND task_id IS NOT NULL);"
  _reflex_sql_json >"$d/events.json" "SELECT task_id, kind, actor, ts FROM lifecycle_events
            WHERE kind IN ('task.delivered','task.done') AND ts >= ${since} AND task_id IS NOT NULL ORDER BY id;"

  # Files and --slurpfile, not --argjson: two weeks of ledger is past ARG_MAX.
  jq -nc --arg only "$only" \
    --slurpfile receipts "$d/receipts.json" --slurpfile route "$d/hist_route.json" \
    --slurpfile reject "$d/hist_reject.json" --slurpfile reap "$d/hist_reap.json" \
    --slurpfile gates "$d/gates.json" --slurpfile tasks "$d/tasks.json" --slurpfile events "$d/events.json" \
    "${_REFLEX_JQ_DEFS}"'
    ($receipts[0]) as $receipts | ($route[0]) as $route | ($reject[0]) as $reject
    | ($reap[0]) as $reap | ($gates[0]) as $gates | ($tasks[0]) as $tasks | ($events[0]) as $events
    | def epoch: (. // "") | sub("T"; " ") | sub("Z$"; "") | sub("\\.[0-9]+$"; "")
                          | (strptime("%Y-%m-%d %H:%M:%S") | mktime)? // null;
    ($tasks | map({key: (.id|tostring), value: .status}) | from_entries) as $status
    | ($events | group_by(.task_id) | map({key: (.[0].task_id|tostring), value: .}) | from_entries) as $ev
    # Receipts first. The earliest receipt per policy is where history stops, so a
    # decision is never counted twice.
    | [ $receipts[] | (.detail | fromjson? // null) as $r | select($r != null)
        | {policy: $r.policy, ts: .ts, ident: .ident, task_id: .task_id, source: "receipt",
           seat: ($r.effect.seat // .actor), current: $r.result,
           options: ($r.candidates // []), signals: ($r.signals // {})} ] as $live
    | ($live | group_by(.policy) | map({key: .[0].policy, value: (map(.ts) | min)}) | from_entries) as $cut
    | def before($p): (.ts < ($cut[$p] // "9999"));
      # Seats that took part in the window, as the candidate set for rebuilt
      # route cases. The live receipts carry the real roster instead.
      ([ $events[].actor, ($route[] | .detail | capture("→ (?<a>[^ ]+)").a? // empty) ]
        | map(select(. != null and . != "unassigned" and (test(":") | not))) | unique) as $seats
    | ( [ $route[] | select(before("task-route"))
          | (.detail | capture("^(?<p>[a-z]+) → (?<a>[^ ]+)")? // {p: null, a: "unassigned"}) as $d
          | {policy: "task-route", ts, ident, task_id, source: "history", seat: null,
             current: $d.a, options: $seats, signals: {via: "add", priority: $d.p}} ]
      + [ $reject[] | select(before("retry-action"))
          | (.detail | capture("iteration (?<i>[0-9]+)(/(?<m>[0-9]+))?")? // {}) as $it
          | {policy: "retry-action", ts, ident, task_id, source: "history", seat: null,
             current: (if (.detail|test("escalated")) then "human" else "retry_with_feedback" end),
             options: ["human", "retry_with_feedback"],
             signals: {iteration: ($it.i | tonumber? // null), max_iterations: ($it.m | tonumber? // null)}} ]
      + [ $reap[] | select(before("stuck"))
          | (.detail | capture("why=(?<w>.*?); cleared started_at=(?<s>.*)$")? // {w: "", s: ""}) as $d
          | (((.ts|epoch) // 0) - (($d.s|epoch) // ((.ts|epoch) // 0))) as $age
          | {policy: "stuck", ts, ident, task_id, source: "history", seat: .actor, current: "reclaim",
             options: ["leave", "reclaim"],
             signals: {reason: ($d.w | rx_reap_class),
                       claim_age_min: (if ($d.s|epoch) then ($age / 60 | floor) else null end),
                       mode: (if (.detail|test("verifier queue")) then "keep-handoff" else "clean" end)}} ]
      + [ $gates[] | select(before("gate-answer")) | rx_gate_case as $g
          | {policy: "gate-answer", ts, ident, task_id, source: "history", seat: null,
             current: $g.result, options: $g.candidates, signals: $g.signals} ]
      + $live ) as $all
    | now as $now
    | $all[] | select($only == "" or .policy == $only)
    | ($status[(.task_id|tostring)] // null) as $st
    | ($ev[(.task_id|tostring)] // []) as $te
    | (.ts|epoch) as $t
    | . + {outcome: (
        if .policy == "task-route" then
          (if $st == "done" then
             ([ $te[] | select(.kind == "task.delivered") ] | last | .actor)
             // ([ $te[] | select(.kind == "task.done") ] | last | .actor)
           else null end)
        elif .policy == "retry-action" then
          ([ $te[] | select(.kind == "task.delivered" and ((.ts|epoch) // 0) > ($t // 0)) ] | length > 0) as $again
          | (if $st == "done" and $again then "retry_with_feedback"
             elif ($st == "done" or $st == "cancelled") then "human"
             else null end)
        elif .policy == "stuck" then
          .seat as $seat
          | ([ $te[] | select(.actor == $seat and ((.ts|epoch) // 0) > ($t // 0)
                              and ((.ts|epoch) // 0) <= (($t // 0) + 600)) ] | length > 0) as $quick
          | (if $quick then "leave" elif ($now - ($t // $now)) >= 600 then "reclaim" else null end)
        elif .policy == "gate-answer" then .current
        else null end)}
    # The request a backend sees. The outcome is never in it, and on gate-answer
    # neither is today'"'"'s "current": there the answer IS the outcome.
    | . + {request: {policy, version: 1, type: "choice",
                     state: ({task: .ident, signals}
                             + (if .policy == "gate-answer" then {} else {current} end)),
                     options}}'
}

_reflex_run_backend() { # <backend> <requests file> <timeout s> -> responses on stdout
  local backend="$1" req="$2" to="$3"
  case "$backend" in
    fake:*) _reflex_fake --strategy="${backend#fake:}" <"$req" ;;
    *)      timeout "$to" bash -c "$backend" <"$req" 2>/dev/null || true ;;
  esac
}

_reflex_replay() {
  local since_spec="14d" policy="" backend="fake:echo" to=300 dump="" a
  for a in "$@"; do
    case "$a" in
      --since=*)   since_spec="${a#*=}" ;;
      --policy=*)  policy="${a#*=}" ;;
      --backend=*) backend="${a#*=}" ;;
      --timeout=*) to="${a#*=}" ;;
      --dump=*)    dump="${a#*=}" ;;
      --json)      JSON_MODE=1 ;;
      *) fail "$E_USAGE" "unknown flag: $a" ;;
    esac
  done
  _reflex_check_policy "$policy"
  [[ "$to" =~ ^[1-9][0-9]{0,4}$ ]] || fail "$E_VALIDATION" "--timeout must be a positive number of seconds"
  case "$backend" in
    fake:echo|fake:first|fake:recommend) ;;
    fake:*) fail "$E_VALIDATION" "unknown fake backend: $backend (fake:echo, fake:first, fake:recommend)" ;;
    "") fail "$E_VALIDATION" "--backend is empty" ;;
  esac
  _reflex_need_store
  local since; since=$(_reflex_since_sql "$since_spec")
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/reflex-replay.XXXXXX") || fail "$E_GENERIC" "mktemp failed"
  if ! _reflex_build_cases "$since" "$policy" "$tmp" >"$tmp/cases.jsonl"; then
    rm -rf "$tmp"; fail "$E_GENERIC" "could not build replay cases from ${TASKS_DB}"
  fi
  jq -c '.request' "$tmp/cases.jsonl" >"$tmp/req.jsonl"
  _reflex_run_backend "$backend" "$tmp/req.jsonl" "$to" >"$tmp/resp.jsonl"
  # Pair case i with response line i. A missing or unparseable line is null, and
  # null is invalid, so a backend that dies halfway scores its tail as fallbacks
  # instead of shifting every later answer onto the wrong case.
  jq -nc --slurpfile cases "$tmp/cases.jsonl" --rawfile resp "$tmp/resp.jsonl" '
    ($resp | split("\n") | map(select(length > 0) | (fromjson? // null))) as $r
    | range(0; $cases|length) as $i
    | $cases[$i] + {response: ($r[$i] // null)}
    # Parenthesised so a null response yields null, not empty: an empty here
    # would silently DROP the case instead of scoring it invalid.
    | ((.response | objects | .choice) // null) as $ch
    | ($ch != null and (.options | index([$ch])) != null) as $valid
    | . + {valid: $valid, choice: (if $valid then $ch else .request.state.current end)}' \
    >"$tmp/paired.jsonl"
  local report
  report=$(jq -sc --arg backend "$backend" --arg since "$since_spec" --arg only "$policy" '
    . as $all
    | {backend: $backend, since: $since, generated_at: (now | todate),
       policies: [ "task-route", "retry-action", "stuck", "gate-answer" | select($only == "" or . == $only) ] | map(. as $p
         | [ $all[] | select(.policy == $p) ] as $cs
         | [ $cs[] | select(.outcome != null) ] as $res
         | [ $res[] | select(.request.state.current != null) ] as $withcur
         | [ $cs[] | select(.request.state.current != null) ] as $cscur
         | {policy: $p, cases: ($cs|length),
            from_receipts: ([ $cs[] | select(.source == "receipt") ] | length),
            from_history: ([ $cs[] | select(.source == "history") ] | length),
            first: ([ $cs[].ts ] | min), last: ([ $cs[].ts ] | max),
            resolved: ($res|length),
            current_behavior_accuracy: (if ($withcur|length) > 0
              then ([ $withcur[] | select(.request.state.current == .outcome) ] | length) / ($withcur|length)
              else null end),
            backend_accuracy: (if ($res|length) > 0
              then ([ $res[] | select(.choice == .outcome) ] | length) / ($res|length)
              else null end),
            agreement_with_current: (if ($cscur|length) > 0
              then ([ $cscur[] | select(.choice == .request.state.current) ] | length) / ($cscur|length)
              else null end),
            invalid: ([ $cs[] | select(.valid | not) ] | length),
            outcome_labels: ([ $res[].outcome ] | group_by(.) | map({key: .[0], value: length}) | from_entries)}
         + (if $p == "gate-answer" then
              ([ $cs[] | select(.signals.recommend != null) ]) as $wr
              | {with_recommend: ($wr|length),
                 matched_recommend_rate: (if ($wr|length) > 0
                   then ([ $wr[] | select(.signals.matched_recommend) ] | length) / ($wr|length)
                   else null end)}
            else {} end)) }' "$tmp/paired.jsonl")
  if [[ -n "$dump" ]]; then
    # The per-case record, for anyone who wants to dig past the summary. Labels,
    # ids and counts only, same as a receipt.
    cp "$tmp/paired.jsonl" "$dump" 2>/dev/null || warn "could not write --dump file: $dump"
  fi
  rm -rf "$tmp"
  if (( JSON_MODE )); then
    printf '%s\n' "$report"
    return 0
  fi
  jq -r '
    def pct: if . == null then "   n/a" else (. * 1000 | round / 10 | tostring | .[0:5] + "%") end;
    "reflex replay — backend \(.backend), since \(.since)",
    "",
    "policy        cases  receipts  history  resolved  current  backend  agree  invalid",
    (.policies[] |
      "\(.policy | .+"            " | .[0:12])  \(.cases|tostring|("     "+.)[-5:])  \(.from_receipts|tostring|("        "+.)[-8:])  \(.from_history|tostring|("       "+.)[-7:])  \(.resolved|tostring|("        "+.)[-8:])  \(.current_behavior_accuracy|pct|("       "+.)[-7:])  \(.backend_accuracy|pct|("       "+.)[-7:])  \(.agreement_with_current|pct|("     "+.)[-5:])  \(.invalid|tostring|("       "+.)[-7:])"),
    "",
    (.policies[] | select(.policy == "gate-answer" and .with_recommend != null) |
      "gate-answer: \(.with_recommend) answered gates carried a recommendation; \(.matched_recommend_rate|pct) were answered with it."),
    (.policies[] | select(.cases > 0) | "  \(.policy): \(.first) → \(.last); outcomes \(.outcome_labels|tostring)"),
    "",
    "current = today'"'"'s recorded decision scored against the outcome proxy; backend = the",
    "candidate'"'"'s pick (a fallback to current where it was invalid); agree = backend == current.",
    "The outcome proxies are documented in `5dive reflex help` source (src/cmd_reflex.sh)."' <<<"$report"
}
