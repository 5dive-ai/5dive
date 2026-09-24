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
# Off switch: FIVEDIVE_REFLEX_RECEIPTS=0 writes nothing, and so does
# `5dive config reflex-receipts=off` (DIVE-4915). The env wins over the box.

REFLEX_RECEIPT_SCHEMA=1

# ── DIVE-4915: reflex's box settings ────────────────────────────────────────
#
# Three settings, each with the SOURCE it came from, so `5dive config` and the
# dashboard can say why a value is what it is:
#   receipts  env FIVEDIVE_REFLEX_RECEIPTS (0 = off, anything else = on), then
#             box.json .reflex_receipts (on|off), then on.
#   model     box.json .reflex_model, then REFLEX_MODEL_DEFAULT. The reference
#             backend's --model flag still wins for a single replay.
#   key       set / unset / unknown — the key FILE's presence, never its bytes.
REFLEX_MODEL_DEFAULT="typesafe/jev-1.13"
REFLEX_MODEL_RE='^[A-Za-z0-9._-]+/[A-Za-z0-9._:-]+$'

_reflex_key_file() { printf '%s' "${FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE:-/etc/5dive/reflex-openrouter.key}"; }

# _reflex_box_get <key> -> the box.json value, or nothing
_reflex_box_get() {
  # DIVE-4932: the same fallback path reflex_shadow_model reads, so a process
  # without _box_config_path (a partial source, the detached sweep) still sees
  # the box's endpoint instead of silently resolving to OpenRouter.
  local f
  if declare -F _box_config_path >/dev/null 2>&1; then f=$(_box_config_path)
  else f="${BOX_CONFIG:-${STATE_DIR:-/var/lib/5dive}/box.json}"; fi
  [[ -r "$f" ]] || return 0
  jq -r --arg k "$1" '.[$k] // empty | strings' "$f" 2>/dev/null || true
}

# Sets _REFLEX_RECEIPTS (on|off) and _REFLEX_RECEIPTS_SRC.
reflex_receipts_resolve() {
  if [[ -n "${FIVEDIVE_REFLEX_RECEIPTS+x}" ]]; then
    if [[ "$FIVEDIVE_REFLEX_RECEIPTS" == "0" ]]; then _REFLEX_RECEIPTS=off; else _REFLEX_RECEIPTS=on; fi
    _REFLEX_RECEIPTS_SRC="FIVEDIVE_REFLEX_RECEIPTS=${FIVEDIVE_REFLEX_RECEIPTS} in this environment (wins over the box setting)"
    return 0
  fi
  local v; v=$(_reflex_box_get reflex_receipts)
  case "$v" in
    on|off) _REFLEX_RECEIPTS="$v"; _REFLEX_RECEIPTS_SRC="box setting" ;;
    *)      _REFLEX_RECEIPTS=on;   _REFLEX_RECEIPTS_SRC="default (on)" ;;
  esac
}

# Sets _REFLEX_MODEL and _REFLEX_MODEL_SRC. On a custom endpoint (DIVE-4932)
# the id is whatever that server calls its models (Laya: `typed-decisions`), so
# only the charset is checked; on OpenRouter it must be provider/model.
reflex_model_resolve() {
  local v re="$REFLEX_MODEL_RE"; v=$(_reflex_box_get reflex_model)
  [[ -n "$(_reflex_box_get reflex_endpoint)" ]] && re="$REFLEX_MODEL_ANY_RE"
  if [[ -n "$v" && ${#v} -le 100 && "$v" =~ $re ]]; then
    _REFLEX_MODEL="$v"; _REFLEX_MODEL_SRC="box setting"
  elif [[ -n "$v" ]]; then
    _REFLEX_MODEL="$REFLEX_MODEL_DEFAULT"; _REFLEX_MODEL_SRC="default (the box's '${v:0:100}' is not an OpenRouter id, and the endpoint is OpenRouter)"
  else
    _REFLEX_MODEL="$REFLEX_MODEL_DEFAULT"; _REFLEX_MODEL_SRC="default"
  fi
}

# set | unset | unknown. Presence only: this function never opens the file.
reflex_key_status() { _reflex_file_status "$(_reflex_key_file)"; }
_reflex_file_status() {
  local f="$1"
  if [[ -s "$f" ]]; then printf 'set'
  elif [[ -x "$(dirname "$f")" ]]; then printf 'unset'
  else printf 'unknown'
  fi
}

# ── DIVE-4932: the endpoint is a setting, OpenRouter is only its default ────
#
# lodar, 2026-09-24: "we should have made custom endpoint option for 5dive
# reflex. not hardcode openrouter." Two box settings:
#   endpoint  box.json .reflex_endpoint: the FULL URL a decision is POSTed to
#             (http://127.0.0.1:8000/v1/systemone for a local Laya). Unset is
#             OpenRouter: ${FIVEDIVE_REFLEX_OPENROUTER_URL:-https://openrouter.ai/api}
#             plus the api's path, exactly as before.
#   api       box.json .reflex_api: decisions | systemone | chat. Unset, it is
#             read off a custom endpoint's path (…/systemone, …/decisions,
#             …/chat/completions), and on OpenRouter it is decisions.
#             decisions and systemone are ONE wire format — {model, state,
#             questions} in, {answers:{decision:{choice, confidence,
#             probabilities}}} out; Laya's serve.py says so and returns the same
#             shape — so they differ only in the name. chat is any
#             OpenAI-compatible chat model, asked for one option id.
#
# THE KEY IS PER ENDPOINT. The OpenRouter key is sent to OpenRouter and nowhere
# else: a custom endpoint gets its OWN bearer (`5dive config
# reflex-endpoint-key=-`, root-only 600 like the OpenRouter one) or none at all.
# Sending the OpenRouter key to whatever URL a box names would hand the key to
# that URL. A custom endpoint's URL may not carry credentials or a query string
# either (refused at `config`, ignored here), so a receipt, a status line or a
# `ps` listing never holds one.
REFLEX_MODEL_ANY_RE='^[A-Za-z0-9._~:/-]+$'
REFLEX_ENDPOINT_RE='^https?://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(:[0-9]{1,5})?(/[A-Za-z0-9._~%/-]*)?$'

_reflex_endpoint_key_file() { printf '%s' "${FIVEDIVE_REFLEX_ENDPOINT_KEY_FILE:-/etc/5dive/reflex-endpoint.key}"; }
reflex_endpoint_key_status() { _reflex_file_status "$(_reflex_endpoint_key_file)"; }

# reflex_endpoint_valid <url> — an http(s) URL with no userinfo, query or fragment.
reflex_endpoint_valid() { [[ ${#1} -le 200 && "$1" =~ $REFLEX_ENDPOINT_RE ]]; }

# reflex_api_from_path <url> -> decisions | systemone | chat, or nothing
reflex_api_from_path() {
  case "${1%/}" in
    */systemone)        printf 'systemone' ;;
    */decisions)        printf 'decisions' ;;
    */chat/completions) printf 'chat' ;;
  esac
}

# Sets _REFLEX_ENDPOINT (the URL, or "default"), _REFLEX_ENDPOINT_SRC,
# _REFLEX_CUSTOM (0|1), _REFLEX_API, _REFLEX_API_SRC and _REFLEX_URL (what is
# POSTed to). An invalid stored value degrades to the default and says so.
reflex_endpoint_resolve() {
  local e a base="${FIVEDIVE_REFLEX_OPENROUTER_URL:-https://openrouter.ai/api}"
  e=$(_reflex_box_get reflex_endpoint); a=$(_reflex_box_get reflex_api)
  _REFLEX_CUSTOM=0; _REFLEX_ENDPOINT=default; _REFLEX_ENDPOINT_SRC="default (OpenRouter)"
  if [[ -n "$e" ]]; then
    if reflex_endpoint_valid "$e"; then
      _REFLEX_CUSTOM=1; _REFLEX_ENDPOINT="$e"; _REFLEX_ENDPOINT_SRC="box setting"
    else
      _REFLEX_ENDPOINT_SRC="default (OpenRouter; the box's endpoint is not a valid URL and was ignored)"
    fi
  fi
  _REFLEX_API=""; _REFLEX_API_SRC=""
  case "$a" in
    decisions|chat) _REFLEX_API="$a"; _REFLEX_API_SRC="box setting" ;;
    systemone) (( _REFLEX_CUSTOM )) && { _REFLEX_API="$a"; _REFLEX_API_SRC="box setting"; } ;;
  esac
  if [[ -z "$_REFLEX_API" ]] && (( _REFLEX_CUSTOM )); then
    _REFLEX_API=$(reflex_api_from_path "$e"); [[ -n "$_REFLEX_API" ]] && _REFLEX_API_SRC="from the endpoint's path"
  fi
  [[ -n "$_REFLEX_API" ]] || { _REFLEX_API=decisions; _REFLEX_API_SRC="default"; }
  if (( _REFLEX_CUSTOM )); then _REFLEX_URL="$e"
  elif [[ "$_REFLEX_API" == chat ]]; then _REFLEX_URL="$base/v1/chat/completions"
  else _REFLEX_URL="$base/alpha/decisions"
  fi
}

# reflex_configured -> true | false | unknown. Can this box make a call at all?
# A custom endpoint is configured by being named (its key is optional); the
# OpenRouter default needs its key, and "unknown" is a caller that cannot see
# /etc/5dive. The dashboard's "set up reflex" card reads this, not `key`.
reflex_configured() {
  reflex_endpoint_resolve
  if (( _REFLEX_CUSTOM )); then printf 'true'; return 0; fi
  case "$(reflex_key_status)" in set) printf 'true' ;; unset) printf 'false' ;; *) printf 'unknown' ;; esac
}

# reflex_adapter_name -> openrouter | endpoint, the receipt's backend.adapter.
reflex_adapter_name() { reflex_endpoint_resolve; (( _REFLEX_CUSTOM )) && printf 'endpoint' || printf 'openrouter'; }

# reflex_endpoint_probe [<timeout s>] -> one JSON object: GET <origin>/health.
# Only the reachability of the endpoint's host is claimed, plus the server's own
# word when it answers JSON (Laya's /health says {status, loaded, device}).
reflex_endpoint_probe() {
  local to="${1:-3}" origin code ms t0 d body="null"
  reflex_endpoint_resolve
  [[ "$_REFLEX_URL" =~ ^(https?://[^/]+) ]] || { jq -cn '{probed:false, ok:false, error:"no url"}'; return 0; }
  origin="${BASH_REMATCH[1]}"
  command -v curl >/dev/null 2>&1 || { jq -cn '{probed:false, ok:false, error:"curl not installed"}'; return 0; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/reflex-probe.XXXXXX") || return 0
  t0=$(date +%s%N)
  code=$(curl -sS -m "$to" -o "$d/raw" -w '%{http_code}' "$origin/health" 2>/dev/null) || code="${code:-000}"
  ms=$(( ($(date +%s%N) - t0) / 1000000 ))
  jq -e 'type=="object"' "$d/raw" >/dev/null 2>&1 && body=$(head -c 2000 "$d/raw" | jq -c '{status, loaded, device} | with_entries(select(.value != null)) | if . == {} then null else . end' 2>/dev/null || printf null)
  rm -rf "$d"
  jq -cn --arg u "$origin/health" --arg c "${code:-000}" --argjson ms "$ms" --argjson b "${body:-null}" \
    '{probed:true, url:$u, http:($c|tonumber? // 0), ok:($c|test("^2")), ms:$ms, server:$b}'
}

# The env is read on every call (a caller may set it for one command); the box
# file is read once per process, because a heartbeat tick writes several
# receipts and a jq per receipt buys nothing.
_reflex_receipts_on() {
  if [[ -n "${FIVEDIVE_REFLEX_RECEIPTS+x}" ]]; then
    [[ "$FIVEDIVE_REFLEX_RECEIPTS" != "0" ]]
    return
  fi
  [[ -n "${_REFLEX_BOX_RECEIPTS:-}" ]] || { _REFLEX_BOX_RECEIPTS=$(_reflex_box_get reflex_receipts); _REFLEX_BOX_RECEIPTS="${_REFLEX_BOX_RECEIPTS:-unset}"; }
  [[ "$_REFLEX_BOX_RECEIPTS" != off ]]
}

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
  _reflex_receipts_on || return 0
  ( _reflex_receipt_write "$@" ) >/dev/null 2>&1 || true
  return 0
}

_reflex_receipt_write() {
  local policy="" pver="1" ident="" task_id="" result="" cands="" effect="{}" signals="{}" actor="" authority="" kv
  # DIVE-4916: a SHADOW receipt (a model's pick, never acted on) names its own
  # backend, mode and scores. Every other call site takes these defaults.
  local backend='{"adapter":"current_behavior"}' mode="observe" conf="null" probs="null" psrc="" fallback="false"
  for kv in "$@"; do
    case "$kv" in
      backend=*)        backend="${kv#*=}" ;;
      mode=*)           mode="${kv#*=}" ;;
      confidence=*)     conf="${kv#*=}" ;;
      probabilities=*)  probs="${kv#*=}" ;;
      probability_source=*) psrc="${kv#*=}" ;;
      fallback=*)       fallback="${kv#*=}" ;;
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
  jq -e 'type=="object"' <<<"$backend" >/dev/null 2>&1 || backend='{"adapter":"unknown"}'
  jq -e 'type=="number" and . >= 0 and . <= 1' <<<"$conf" >/dev/null 2>&1 || conf="null"
  jq -e 'type=="object"' <<<"$probs" >/dev/null 2>&1 || probs="null"
  [[ "$mode" =~ ^(observe|shadow)$ ]] || mode="observe"
  [[ "$fallback" == "true" ]] || fallback="false"
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
    --argjson schema "$REFLEX_RECEIPT_SCHEMA" \
    --argjson backend "$backend" --arg mode "$mode" --argjson conf "$conf" --argjson probs "$probs" \
    --arg psrc "$psrc" --argjson fallback "$fallback" '
    ($cands | split(",") | map(select(length>0)) | unique) as $c
    | {v:$schema, id:$id, time:$time, policy:$policy, policy_version:$pver,
       type:"choice", task:(if $ident=="" then null else $ident end),
       candidates:$c, result:$result,
       confidence:$conf, probabilities:$probs,
       probability_source:(if $psrc=="" then null else $psrc end),
       backend:$backend, mode:$mode, fallback:$fallback,
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
    "${extra[@]}" idem="$id" policy="$(jq -r '.backend.adapter // "current_behavior"' <<<"$receipt")" detail="$receipt"
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
  _reflex_receipts_on || return 0
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
            COALESCE(need_answered_by,'') AS \"by\", COALESCE(tier,'') AS tier,
            COALESCE(need_asked_at,'') AS asked,
            (SELECT json_object('id', json_extract(e.detail,'\$.id'), 'pick', json_extract(e.detail,'\$.result'))
               FROM lifecycle_events e
              WHERE e.kind='decision.gate-answer' AND e.task_id=tasks.id
                AND json_extract(e.detail,'\$.mode')='shadow'
                AND json_extract(e.detail,'\$.effect.gate_asked_at')=tasks.need_asked_at
              ORDER BY e.id DESC LIMIT 1) AS shadow
     FROM tasks WHERE id=${id};" 2>/dev/null) || return 0
  [[ -n "$row" ]] || return 0
  local c ident by
  c=$(jq -c "${_REFLEX_JQ_DEFS}"' .[0] | {ident, by, asked, shadow: (.shadow | fromjson? // null)} + rx_gate_case' <<<"$row") || return 0
  ident=$(jq -r '.ident' <<<"$c"); by=$(jq -r '.by' <<<"$c")
  reflex_receipt policy=gate-answer ident="$ident" task_id="$id" \
    result="$(jq -r '.result' <<<"$c")" \
    candidates="$(jq -r '.candidates | join(",")' <<<"$c")" \
    signals="$(jq -c '.signals' <<<"$c")" actor="${by:-unknown}" \
    effect="$(jq -c '{task: .ident, gate: "cleared"}
      # DIVE-4916: link the answer to the shadow pick for this gate, when the
      # sweep got there first. The report joins on the gate either way.
      + (if .asked != "" then {gate_asked_at: .asked} else {} end)
      + (if .shadow then {shadow: .shadow.id, shadow_pick: .shadow.pick,
                          shadow_matched: (.shadow.pick == .result)} else {} end)' <<<"$c")"
}

# ── DIVE-4916: the gate-answer SHADOW (phase 1, never acts) ───────────────────
#
# WHAT IT DOES. Every new gate is shown to the box's configured model, which
# predicts the answer. The pick lands as a decision.gate-answer receipt with
# mode=shadow and backend=the model, carrying its choice, confidence and
# probabilities. NOTHING reads that pick back into the board: the gate is filed,
# routed, tiered, notified and answered exactly as it would be with no model.
# `5dive reflex report --live` scores the picks against the answers as they land.
#
# WHY THE HEARTBEAT AND NOT `task need`. The key is /etc/5dive/reflex-openrouter.key,
# root-only 600 (DIVE-4910), and `task need` runs as the filing SEAT, which cannot
# read it. The heartbeat tick is root, every minute. So the tick KICKS a detached
# sweep that picks up gates asked in the last hour with no shadow receipt yet.
# That is also what makes the "never delays the gate" property structural rather
# than a timeout: the filing path does not contain a single line of this.
#
# OPT-IN PER BOX. It runs only when BOTH are present:
#   model  box.json .reflex_model, set explicitly (`5dive config reflex-model=`,
#          DIVE-4915). A built-in default is NOT enough: a box that has a key for
#          replays has not thereby agreed to a call on every gate.
#   key    the key file is readable by this process, or a test/operator backend
#          is named in FIVEDIVE_REFLEX_SHADOW_BACKEND (a JSONL command, same
#          contract as `reflex replay --backend=`).
# FIVEDIVE_REFLEX_SHADOW=0 turns it off whatever the box says.
#
# WHAT IS SENT is exactly a `replay --inputs=titles` gate-answer request: the
# row's title and project, the gate's ask, option texts and recommendation, and
# the label-only signals minus the outcome fields. Never the body, and never the
# answer, even when the sweep reaches a gate that was answered before it ran
# (a tier-0 gate is answered at filing).
#
# TIME BOX. Each call is wrapped in `timeout` (FIVEDIVE_REFLEX_SHADOW_TIMEOUT,
# default 20s); a timeout, a failed call, an invalid pick or a missing key is
# written as the receipt's effect.error with result=none and fallback=true, so a
# slow model shows up in the report instead of vanishing. At most
# FIVEDIVE_REFLEX_SHADOW_MAX gates per sweep (default 5).

REFLEX_SHADOW_WINDOW_MIN=60

# reflex_shadow_model -> the model id when the shadow is on for this box, else
# nothing (rc 1). Cheap: one jq over box.json and a readability test.
reflex_shadow_model() {
  [[ "${FIVEDIVE_REFLEX_SHADOW:-1}" == "0" ]] && return 1
  # Receipts off (env, or the box's `5dive config reflex-receipts=off`) stops the
  # shadow too: with no receipt to dedup on, the sweep would re-ask every tick.
  _reflex_receipts_on || return 1
  local f="${BOX_CONFIG:-${STATE_DIR:-/var/lib/5dive}/box.json}" m=""
  [[ -r "$f" ]] || return 1
  m=$(jq -r '.reflex_model // empty | strings' "$f" 2>/dev/null) || return 1
  # DIVE-4932: a custom endpoint names its models its own way, and needs no key
  # (its own bearer is optional); OpenRouter still needs both the id shape and
  # the key.
  reflex_endpoint_resolve
  if (( _REFLEX_CUSTOM )); then
    [[ -n "$m" && ${#m} -le 100 && "$m" =~ $REFLEX_MODEL_ANY_RE ]] || return 1
  else
    [[ -n "$m" && ${#m} -le 100 && "$m" =~ ^[A-Za-z0-9._~-]+/[A-Za-z0-9._:-]+$ ]] || return 1
    if [[ -z "${FIVEDIVE_REFLEX_SHADOW_BACKEND:-}" ]]; then
      [[ -r "${FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE:-/etc/5dive/reflex-openrouter.key}" ]] || return 1
    fi
  fi
  printf '%s' "$m"
}

# reflex_shadow_kick — the heartbeat's entry point. Returns at once; when the
# shadow is on, the sweep runs DETACHED, with every inherited descriptor above
# stderr closed (the tick's own flock lives on one of them, and a sweep holding
# it would skip the next tick) and under a lock of its own, so two ticks never
# run two sweeps.
reflex_shadow_kick() {
  reflex_shadow_model >/dev/null 2>&1 || return 0
  local lock="${FIVEDIVE_REFLEX_SHADOW_LOCK:-/run/lock/5dive-reflex-shadow.lock}"
  (
    local fd n
    for fd in /proc/$BASHPID/fd/*; do
      n="${fd##*/}"
      [[ "$n" =~ ^[0-9]+$ ]] && (( n > 2 )) && eval "exec ${n}>&-" 2>/dev/null
    done
    exec 9>"$lock" || exit 0
    command -v flock >/dev/null 2>&1 && { flock -n 9 || exit 0; }
    reflex_shadow_sweep
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
  return 0
}

# reflex_shadow_sweep — shadow every gate asked in the window that has no shadow
# receipt yet. Synchronous; the kick above is what detaches it. Safe to call
# directly (the harness does).
reflex_shadow_sweep() {
  local model; model=$(reflex_shadow_model) || return 0
  command -v jq >/dev/null 2>&1 && command -v sqlite3 >/dev/null 2>&1 || return 0
  local max="${FIVEDIVE_REFLEX_SHADOW_MAX:-5}"; [[ "$max" =~ ^[1-9][0-9]?$ ]] || max=5
  # Open or answered, on the row or already retired to gate_history: a gate
  # answered and superseded inside the window still gets its shadow. Secrets are
  # skipped: there is nothing to predict, and nothing of theirs may be sent.
  local rows
  rows=$(sqlite3 -json -cmd ".timeout 5000" "$TASKS_DB" "
    WITH g AS (
      SELECT id AS task_id, COALESCE(ident,'') AS ident, need_type AS nt, COALESCE(ask,'') AS ask,
             COALESCE(need_options,'') AS opts, COALESCE(recommend,'') AS rec, COALESCE(tier,'') AS tier,
             need_asked_at AS asked, (COALESCE(need_answer,'')<>'') AS answered,
             COALESCE(title,'') AS title, COALESCE(project_key,'') AS project
        FROM tasks WHERE need_asked_at >= datetime('now','-${REFLEX_SHADOW_WINDOW_MIN} minutes')
                     AND COALESCE(need_type,'') NOT IN ('','secret')
      UNION ALL
      SELECT h.task_id, COALESCE(h.ident,''), h.need_type, COALESCE(h.ask,''), COALESCE(h.need_options,''),
             COALESCE(h.recommend,''), COALESCE(h.tier,''), h.need_asked_at, (COALESCE(h.need_answer,'')<>''),
             COALESCE(t.title,''), COALESCE(t.project_key,'')
        FROM gate_history h LEFT JOIN tasks t ON t.id = h.task_id
       WHERE h.need_asked_at >= datetime('now','-${REFLEX_SHADOW_WINDOW_MIN} minutes')
         AND COALESCE(h.need_type,'') NOT IN ('','secret'))
    SELECT * FROM g
     WHERE NOT EXISTS (SELECT 1 FROM lifecycle_events e
                        WHERE e.kind='decision.gate-answer' AND e.task_id=g.task_id
                          AND json_extract(e.detail,'\$.mode')='shadow'
                          AND json_extract(e.detail,'\$.effect.gate_asked_at')=g.asked)
     GROUP BY task_id, asked ORDER BY asked LIMIT ${max};" 2>/dev/null) || return 0
  [[ -n "$rows" && "$rows" != "[]" ]] || return 0
  local n i
  n=$(jq 'length' <<<"$rows" 2>/dev/null) || return 0
  for ((i = 0; i < n; i++)); do
    _reflex_shadow_one "$model" "$(jq -c ".[$i]" <<<"$rows")" || true
  done
}

# _reflex_shadow_one <model> <gate json> — one request, one receipt.
_reflex_shadow_one() {
  local model="$1" g="$2" req resp err="" choice="" to="${FIVEDIVE_REFLEX_SHADOW_TIMEOUT:-20}" rc
  [[ "$to" =~ ^[1-9][0-9]{0,2}$ ]] || to=20
  # rx_gate_case with NO answer: the candidates and signals it builds never read
  # the answer, and the two outcome fields are deleted before anything leaves.
  req=$(jq -c "${_REFLEX_JQ_DEFS}"'
    . as $g | ({nt, opts, rec, ans: "", by: "", tier} | rx_gate_case) as $c
    | {policy: "gate-answer", version: 1, type: "choice",
       state: {task: $g.ident,
               signals: ($c.signals | del(.matched_recommend, .answered_by)),
               title: ($g.title | if . == "" then null else . end),
               project: ($g.project | if . == "" then null else . end),
               gate: {ask: ($g.ask | if . == "" then null else . end),
                      options: ([ $g.opts | split("|") | to_entries[] | select(.value != "")
                                  | {key: "opt\(.key + 1)", value: .value} ] | from_entries),
                      recommend: ($g.rec | if . == "" then null else . end)}},
       options: $c.candidates}' <<<"$g") || return 0
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/reflex-shadow.XXXXXX") || return 0
  printf '%s\n' "$req" >"$tmp/req"
  if [[ -n "${FIVEDIVE_REFLEX_SHADOW_BACKEND:-}" ]]; then
    timeout "$to" bash -c "$FIVEDIVE_REFLEX_SHADOW_BACKEND" <"$tmp/req" >"$tmp/resp" 2>/dev/null; rc=$?
  else
    _reflex_endpoint_decide "$model" "$to" <"$tmp/req" >"$tmp/resp" 2>/dev/null; rc=$?
  fi
  resp=$(head -n1 "$tmp/resp" 2>/dev/null)
  rm -rf "$tmp"
  if (( rc == 124 )); then err="timeout"
  elif ! jq -e 'type=="object"' <<<"$resp" >/dev/null 2>&1; then err="no_response"
  else
    choice=$(jq -r '.choice // empty | strings' <<<"$resp")
    if [[ -z "$choice" ]]; then err=$(jq -r '.error // "no_choice" | tostring | .[0:120]' <<<"$resp")
    elif ! jq -e --arg c "$choice" '.options | index([$c]) != null' <<<"$req" >/dev/null 2>&1; then err="invalid_choice"; choice=""
    fi
  fi
  local answered; answered=$(jq -r '.answered == 1' <<<"$g")
  reflex_receipt policy=gate-answer mode=shadow \
    ident="$(jq -r '.ident' <<<"$g")" task_id="$(jq -r '.task_id' <<<"$g")" \
    result="${choice:-none}" fallback="$([[ -n "$err" ]] && echo true || echo false)" \
    candidates="$(jq -r '.options | join(",")' <<<"$req")" \
    signals="$(jq -c '.state.signals' <<<"$req")" \
    confidence="$([[ -z "$err" ]] && jq -c '.confidence // null' <<<"$resp" || echo null)" \
    probabilities="$([[ -z "$err" ]] && jq -c '.probabilities // null' <<<"$resp" || echo null)" \
    probability_source="$([[ -z "$err" ]] && jq -r '.probability_source // empty' <<<"$resp")" \
    backend="$(jq -cn --arg m "$model" --arg a "$([[ -n "${FIVEDIVE_REFLEX_SHADOW_BACKEND:-}" ]] && echo command || reflex_adapter_name)" \
                 --arg api "$(reflex_endpoint_resolve; printf '%s' "$_REFLEX_API")" \
                 '{adapter: $a, model: $m} + (if $a == "command" then {} else {api: $api} end)')" \
    effect="$(jq -cn --arg at "$(jq -r '.asked' <<<"$g")" --arg e "$err" --argjson ans "$answered" --argjson to "$to" \
                '{gate_asked_at: $at, acted: false, answered_before_shadow: $ans, time_box_s: $to}
                 + (if $e == "" then {} else {error: $e} end)')" \
    actor="reflex" authority="heartbeat"
}

# _reflex_endpoint_decide <model> <timeout s> — one request on stdin, one
# response on stdout, through the box's endpoint (DIVE-4932; OpenRouter's
# Decisions API when none is set). The same mapping as
# scripts/reflex-openrouter-backend.sh (the replay's reference backend), inlined
# because that script is not installed on a box. A key reaches curl through a
# mode-600 header file, never argv: the OpenRouter key on OpenRouter only, the
# endpoint's own bearer (optional) on a custom endpoint. A request may name its
# own `instructions` and `criteria` (DIVE-4928, `reflex login-marker`); a gate
# request names neither and is sent exactly as before.
_reflex_endpoint_decide() {
  local model="$1" to="$2" key="" key_file d code
  reflex_endpoint_resolve
  local url="$_REFLEX_URL" api="$_REFLEX_API"
  if (( _REFLEX_CUSTOM )); then
    key_file=$(_reflex_endpoint_key_file)
    [[ -r "$key_file" ]] && key=$(tr -d ' \r\n' <"$key_file" 2>/dev/null)
  else
    key_file="${FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE:-/etc/5dive/reflex-openrouter.key}"
    key=$(tr -d ' \r\n' <"$key_file" 2>/dev/null)
    [[ -n "$key" ]] || { jq -cn '{choice:null, error:"no_key"}'; return 0; }
  fi
  d=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/reflex-or.XXXXXX") || return 1
  : >"$d/auth"
  [[ -n "$key" ]] && printf 'Authorization: Bearer %s\n' "$key" >"$d/auth"; key=""
  cat >"$d/req"
  jq -c --arg m "$model" --arg api "$api" '
    (.options // []) as $o | (.state // {}) as $s
    | ((($s.gate.options // {}) + {approve: "Approve.", deny: "Deny.", other: "Some other, free-text answer."})) as $d
    | (.instructions // "A person was asked to answer a gate on this task. Predict which answer they gave.") as $i
    | (.criteria // ($o | map({key: ., value: ($d[.] // null)}) | from_entries)) as $c
    | if $api == "chat" then
        {model: $m, temperature: 0, max_tokens: 24,
         messages: [{role: "system", content: "You are a decision function. Reply with exactly one option id from the options object, and nothing else: no quotes, no explanation."},
                    {role: "user", content: ({question: $i, options: $c, state: $s} | tojson)}]}
      else
        {model: $m, state: $s, questions: {decision: {type: "choice", instructions: $i, criteria: $c}}}
      end' "$d/req" >"$d/body" || { rm -rf "$d"; return 1; }
  code=$(timeout "$to" curl -sS -m "$to" -o "$d/raw" -w '%{http_code}' -X POST "$url" \
           -H @"$d/auth" -H 'Content-Type: application/json' --data-binary @"$d/body" 2>/dev/null); local rc=$?
  if (( rc == 124 || rc == 28 )); then rm -rf "$d"; return 124; fi
  if [[ "$code" != 2?? ]]; then
    jq -cn --arg c "${code:-000}" '{choice:null, error:("http " + $c)}'; rm -rf "$d"; return 0
  fi
  jq -c --arg api "$api" --argjson opts "$(jq -c 'if (.criteria | type) == "object" then (.criteria | keys_unsorted) else (.options // []) end' "$d/req" 2>/dev/null || echo '[]')" '
    if $api == "chat" then
      ((.choices[0].message.content // "") | gsub("^[^A-Za-z0-9_-]+|[^A-Za-z0-9_-]+$"; "")) as $t
      | ([ $t | scan("[A-Za-z0-9_-]+") ]) as $toks
      | ([ $opts[] | select(. as $o | $toks | index([$o]) != null) ]) as $hits
      | {choice: (if ($opts | index([$t])) != null then $t elif ($hits|length) == 1 then $hits[0] elif $t == "" then null else $t end),
         confidence: null, probabilities: null, probability_source: null}
    else
      (.answers.decision // {}) as $x
      | {choice: ($x.choice // null), confidence: ($x.confidence // null),
         probabilities: ($x.probabilities // null),
         probability_source: (if $x.probabilities then "head" else null end)}
    end' "$d/raw" 2>/dev/null \
    || jq -cn '{choice:null, error:"unparseable response"}'
  rm -rf "$d"
}

# The pre-DIVE-4932 name. On a box with no endpoint set it is the same call.
_reflex_openrouter_decide() { _reflex_endpoint_decide "$@"; }
