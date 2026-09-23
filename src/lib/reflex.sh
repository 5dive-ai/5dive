#!/usr/bin/env bash
# ── reflex decision receipts, phase 0 (DIVE-4866) ─────────────────────────────
#
# WHAT THIS IS. lodar's typed-decisions proposal (working name "reflex"; main's
# review is on DIVE-4866) puts a small, user-chosen model in front of decisions
# the runtime already makes: 5dive computes the legal options, the backend picks
# one, 5dive acts, and every pick leaves a RECEIPT. Phase 0 builds the receipts
# and nothing else. No model is called, and no behaviour changes. The four places
# that already decide today each write down what they decided, in the receipt
# format, with backend=current_behavior:
#
#   task-route      task add (first owner) and task assign (a reassignment)
#   retry-action    a verifier reject: bounce back to the maker, or park on a human
#   stuck           the heartbeat reaper taking a claim back (_hb_reclaim_to_todo)
#   gate-answer     a gate answered, and whether the answer matched --recommend
#
# Those receipts are the dataset. `5dive reflex replay` (src/cmd_reflex.sh) feeds
# them, plus the older ledger history, to a candidate backend and scores it
# against what actually happened. The v0.1 backend and scope get picked from
# those numbers.
#
# ── WHERE THEY LIVE ──────────────────────────────────────────────────────────
# One lifecycle_events row per receipt: kind=decision.<policy>, idem_key=the
# receipt id, detail=the receipt as one line of JSON. Not a new table, for three
# reasons. ledger_emit is already append-only and already never fails its caller.
# A receipt sits on the same timeline as the task.created / task.rejected /
# gate.answered row it explains, which is the "allow correlation with task
# events" property the proposal asks for. And there is no migration to run on a
# live box: a new table needs _tasks_db_migrate, and a fresh-DB harness never
# exercises that path (DIVE-2512).
#
# ── WHAT A RECEIPT MAY CARRY ────────────────────────────────────────────────
# lifecycle_events is read by lower-privileged consumers, and ledger_emit hashes
# in=/out= so a call site cannot leak content through them. detail= is NOT hashed,
# so the rule moves here: a receipt carries ids, seat names, enum labels and
# counts. Never a title, a body, a gate ask, an option's text or a gate answer's
# text. A gate answer is reduced to WHICH option it was (opt1..optN), a short
# approval verb, or "other". A secret gate's answer is "provided" and nothing
# else. Main's review, change 3: remote backends get numbers and ids, never raw
# text.
#
# ── ADDITIVE ONLY ───────────────────────────────────────────────────────────
# Same contract as routing_receipt (DIVE-3499). No new refusal, no new exit code,
# no output. The body runs in a subshell with stderr closed and `|| true` outside
# it, so a missing jq, an unreadable roster or a locked board cannot reach the
# verb's exit status. Call sites add `2>/dev/null || true` as well, because a
# harness that sources only part of src/ has no reflex_receipt at all, and bash
# turns that into rc=127 on a verb that already succeeded.
#
# Off switch: FIVEDIVE_REFLEX_RECEIPTS=0 writes nothing.

REFLEX_RECEIPT_SCHEMA=1

# reflex_receipt policy=<p> [policy_version=<n>] [ident=] [task_id=] result=<label>
#                [candidates=<a,b,c>] [effect=<json obj>] [signals=<json obj>]
#                [actor=<seat>] [authority=<a>]
#
# actor/authority MIRROR the ledger row the decision sits beside. That matters:
# _hb_seat_advanced reads any lifecycle_events row by a seat whose authority is
# not heartbeat/dispatcher as proof the seat did work, so a reaper receipt that
# took the default authority would make the reaper's own kill read as the reaped
# seat's progress. The stuck call site passes authority=dispatcher, as its
# task.reclaimed row does.
reflex_receipt() {
  [[ "${FIVEDIVE_REFLEX_RECEIPTS:-1}" == "0" ]] && return 0
  ( _reflex_receipt_write "$@" ) >/dev/null 2>&1 || true
  return 0
}

_reflex_receipt_write() {
  local policy="" pver="1" ident="" task_id="" result="" cands="" effect="{}" signals="{}" actor="" authority="" kv
  for kv in "$@"; do
    case "$kv" in
      policy=*)         policy="${kv#*=}" ;;
      policy_version=*) pver="${kv#*=}" ;;
      ident=*)          ident="${kv#*=}" ;;
      task_id=*)        task_id="${kv#*=}" ;;
      result=*)         result="${kv#*=}" ;;
      candidates=*)     cands="${kv#*=}" ;;
      effect=*)         effect="${kv#*=}" ;;
      signals=*)        signals="${kv#*=}" ;;
      actor=*)          actor="${kv#*=}" ;;
      authority=*)      authority="${kv#*=}" ;;
    esac
  done
  [[ "$policy" =~ ^[a-z][a-z0-9-]{0,39}$ && -n "$result" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # A malformed effect or signals blob degrades to {} rather than dropping the
  # receipt: the decision happened, and "what it decided" is worth more than the
  # side detail.
  jq -e 'type=="object"' <<<"$effect"  >/dev/null 2>&1 || effect="{}"
  jq -e 'type=="object"' <<<"$signals" >/dev/null 2>&1 || signals="{}"
  [[ "$pver" =~ ^[0-9]+$ ]] || pver=1
  local ns id now
  ns=$(date -u +%s%N 2>/dev/null) || ns="$(date -u +%s)000000000"
  # Nanoseconds plus 32 random bits. The idem key is UNIQUE, and a collision is a
  # silent no-op (the task.started lesson in _hb_reclaim_to_todo), so two receipts
  # in one nanosecond must not share an id.
  id="dec_$(printf '%x' "$ns")$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local receipt
  receipt=$(jq -cn \
    --arg id "$id" --arg time "$now" --arg policy "$policy" --argjson pver "$pver" \
    --arg ident "$ident" --arg result "$result" --arg cands "$cands" \
    --argjson effect "$effect" --argjson signals "$signals" \
    --argjson schema "$REFLEX_RECEIPT_SCHEMA" '
    ($cands | split(",") | map(select(length>0)) | unique) as $c
    | {v:$schema, id:$id, time:$time, policy:$policy, policy_version:$pver,
       type:"choice", task:(if $ident=="" then null else $ident end),
       candidates:$c, result:$result,
       confidence:null, probabilities:null, probability_source:null,
       backend:{adapter:"current_behavior"}, mode:"observe", fallback:false,
       signals:$signals, effect:$effect}') || return 0
  # The hashes the proposal names. candidate_hash covers the legal set, and
  # state_hash covers everything a backend would have been shown. Both are
  # computed over the canonical (-S) JSON so key order cannot change them.
  local ch sh
  ch=$(jq -cS '.candidates' <<<"$receipt" | sha256sum | cut -c1-16)
  sh=$(jq -cS '{policy,task,candidates,signals}' <<<"$receipt" | sha256sum | cut -c1-16)
  receipt=$(jq -c --arg ch "sha256:$ch" --arg sh "sha256:$sh" \
    '. + {candidate_hash:$ch, state_hash:$sh}' <<<"$receipt") || return 0
  declare -F ledger_emit >/dev/null 2>&1 || return 0
  local -a extra=()
  [[ -n "$actor" ]] && extra+=("actor=$actor")
  [[ -n "$authority" ]] && extra+=("authority=$authority")
  ledger_emit "decision.${policy}" ident="$ident" task_id="$task_id" \
    "${extra[@]}" idem="$id" policy="current_behavior" detail="$receipt"
}

# reflex_roster_csv — the legal candidate set for a routing decision: every lane
# the board would accept (`_task_require_lane`'s roster). Empty when the roster
# is unreadable, and a receipt with no candidates still records the pick.
reflex_roster_csv() {
  declare -F _task_roster >/dev/null 2>&1 || { printf ''; return 0; }
  _task_roster >/dev/null 2>&1 || true
  [[ "${_TASK_ROSTER_STATE:-}" == "ok" ]] || { printf ''; return 0; }
  printf '%s' "${_TASK_ROSTER:-}" | awk 'NF{printf "%s%s", (n++?",":""), $0}'
}

# ── the labels, defined ONCE, in jq ─────────────────────────────────────────
# The live receipts and the replay's history reader (cmd_reflex.sh) both label
# through these definitions, so a receipt written today and one reconstructed
# from last month's ledger cannot disagree about what "opt2" or "idle" means.
# jq and not bash so the replay can label a thousand history rows in one pass.
#
#   rx_reap_class   the reaper's free-text reason -> budget|idle|orphan|halted|other
#   rx_gate_label   a gate answer -> opt<N> (it equals option N, case- and
#                   space-insensitive, or is N's letter/number: "b", "2") |
#                   the approval verb it OPENS with, from a closed list
#                   ("Approved — push it" -> approve) |
#                   "other" | "provided" (a secret, and nothing else survives)
#   rx_gate_case    {nt,opts,rec,ans,by,tier} -> {result,candidates,signals}.
#                   candidates is the legal set 5dive would offer a backend, and
#                   is built WITHOUT the answer (options, approve/deny on an
#                   approval, the recommendation, "other"), so a replay request
#                   cannot leak its own label.
#                   matched_recommend: the raw strings are equal, or both land
#                   on the same option/verb. Two different free-text answers both
#                   label "other", and they did not match.
_REFLEX_JQ_DEFS='
def rx_norm: (. // "") | ascii_downcase | gsub("^\\s+|\\s+$"; "");
def rx_reap_class:
  (. // "") as $w
  | if ($w|startswith("overran")) then "budget"
    elif ($w|startswith("idle")) then "idle"
    elif ($w|startswith("halted")) then "halted"
    elif ($w|test("session gone|orphan|restart")) then "orphan"
    else "other" end;
def rx_gate_label($nt; $ans; $opts):
  if $nt == "secret" then "provided"
  else ($ans|rx_norm) as $a
    | [ ($opts // "") | split("|")[] | rx_norm ] as $o
    | ([ range(0; $o|length) | select($o[.] != "" and $o[.] == $a) ] | first) as $i
    | (if ($a|test("^[a-z]$")) then (($a|explode[0]) - 96)
       elif ($a|test("^[0-9]{1,2}$")) then ($a|tonumber)
       else 0 end) as $k
    | if $a != "" and $i != null then "opt\($i + 1)"
      elif $k >= 1 and $k <= ($o|length) then "opt\($k)"
      else ($a | gsub("[^a-z ]"; " ") | split(" ") | map(select(length > 0)) | .[0] // "") as $w
        | {approve:"approve", approved:"approve", deny:"deny", denied:"deny",
           reject:"reject", rejected:"reject", yes:"yes", no:"no", ok:"ok",
           cancel:"cancel", done:"done", resume:"resume", drop:"drop",
           withdraw:"withdraw", hold:"hold"}[$w] // "other"
      end
  end;
def rx_gate_case:
  . as $g
  | ([ ($g.opts // "") | split("|")[] ] | length) as $n
  | rx_gate_label($g.nt; $g.ans; $g.opts) as $label
  | (if ($g.rec // "") == "" then null else rx_gate_label($g.nt; $g.rec; $g.opts) end) as $rl
  | { result: $label,
      candidates: ([ range(1; $n + 1) | "opt\(.)" ]
                   + (if $g.nt == "approval" then ["approve","deny"] else [] end)
                   + (if $rl then [$rl] else [] end) + ["other"] | unique),
      signals: { need_type: $g.nt,
                 tier: ($g.tier | tonumber? // null),
                 answered_by: ((($g.by // "") | split(":")[0]) | if . == "" then "unknown" else . end),
                 n_options: $n,
                 recommend: $rl,
                 matched_recommend: ($g.nt != "secret" and ($g.rec|rx_norm) != ""
                                     and ((($g.rec|rx_norm) == ($g.ans|rx_norm))
                                          or ($rl == $label and $label != "other"))) } };
'

# reflex_reap_reason_class <why> -> budget | idle | orphan | halted | other
reflex_reap_reason_class() {
  jq -rn --arg w "${1:-}" "${_REFLEX_JQ_DEFS}"' $w | rx_reap_class' 2>/dev/null || printf 'other'
}

# reflex_gate_receipt <task id> — the gate-answer receipt, read off the ROW after
# the answer has landed (same reason the gate.answered ledger row reads provenance
# back: the persisted column is what landed, the shell variable is only intent).
reflex_gate_receipt() {
  [[ "${FIVEDIVE_REFLEX_RECEIPTS:-1}" == "0" ]] && return 0
  ( _reflex_gate_receipt_write "$@" ) >/dev/null 2>&1 || true
  return 0
}

_reflex_gate_receipt_write() {
  local id="${1:-}"
  [[ "$id" =~ ^[0-9]+$ ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # -json, not db's `|`-joined rows: need_options is itself `|`-separated.
  local row
  row=$(sqlite3 -json -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT COALESCE(ident,'') AS ident, COALESCE(need_type,'') AS nt, COALESCE(need_options,'') AS opts,
            COALESCE(recommend,'') AS rec, COALESCE(need_answer,'') AS ans,
            COALESCE(need_answered_by,'') AS \"by\", COALESCE(tier,'') AS tier
     FROM tasks WHERE id=${id};" 2>/dev/null) || return 0
  [[ -n "$row" ]] || return 0
  local c ident by
  c=$(jq -c "${_REFLEX_JQ_DEFS}"' .[0] | {ident, by} + rx_gate_case' <<<"$row") || return 0
  ident=$(jq -r '.ident' <<<"$c"); by=$(jq -r '.by' <<<"$c")
  reflex_receipt policy=gate-answer ident="$ident" task_id="$id" \
    result="$(jq -r '.result' <<<"$c")" \
    candidates="$(jq -r '.candidates | join(",")' <<<"$c")" \
    signals="$(jq -c '.signals' <<<"$c")" actor="${by:-unknown}" \
    effect="$(jq -cn --arg t "$ident" '{task:$t, gate:"cleared"}')"
}
