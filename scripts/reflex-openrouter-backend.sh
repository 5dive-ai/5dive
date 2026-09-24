#!/usr/bin/env bash
# reflex-openrouter-backend.sh — a reference `5dive reflex replay --backend=` that
# asks a real model on OpenRouter (DIVE-4910).
#
#   sudo 5dive reflex replay --since=14d --inputs=titles --timeout=1800 --dump=/tmp/rx.jsonl \
#     --backend="bash /path/to/scripts/reflex-openrouter-backend.sh --model=typesafe/jev-1.13"
#
# THE CONTRACT (src/cmd_reflex.sh, "The backend contract"): one JSON request per
# line on stdin, one JSON response per line on stdout, in the SAME ORDER. This
# script runs up to --concurrency calls at once and still writes line i for
# request i. A call that fails writes {"choice":null,"error":...} on its line, so
# the replay scores it INVALID and the --dump says why (the replay discards a
# backend's stderr).
#
# TWO APIS.
#   decisions  OpenRouter's Decisions API (POST /api/alpha/decisions), for a
#              "text->decisions" model such as TypeSafe's Jev. It picks a typed
#              option and returns confidence + per-option probabilities, which map
#              straight onto the response's confidence / probabilities, with
#              probability_source "head" (a distribution from the model, not
#              logprobs and not self-reported). The default for typesafe/jev*.
#   chat       /api/v1/chat/completions, for any text model: asked to answer with
#              one option id and nothing else, temperature 0. No confidence. The
#              default for every other --model, so the same cases can compare a
#              cheap chat model against Jev.
#
# WHAT IS SENT. The request's own state (ids, labels, counts; plus titles, gate
# asks/options and seat roles only when the replay ran with --inputs=titles), a
# fixed question per policy, and the options. state.current (what today's code
# chose) is DROPPED unless --with-current: a model shown the incumbent answer
# mostly echoes it, and the replay already scores the incumbent on its own.
#
# THE KEY is read from a file, never from argv or the environment, and reaches
# curl through a mode-600 header file, so it is not in `ps`. Default path
# /etc/5dive/reflex-openrouter.key (root-only; run the replay under sudo), or
# FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE. FIVEDIVE_REFLEX_OPENROUTER_URL overrides the
# base URL (default https://openrouter.ai/api).
#
# Flags: --model=<id> (default typesafe/jev-1.13)  --api=decisions|chat
#        --concurrency=N (1-32, default 8)  --request-timeout=S (default 60)
#        --retries=N (on 429/5xx/no answer, default 2)  --with-current
set -uo pipefail

model="typesafe/jev-1.13" api="" conc=8 rto=60 retries=2 with_current=0
for a in "$@"; do
  case "$a" in
    --model=*)           model="${a#*=}" ;;
    --api=*)             api="${a#*=}" ;;
    --concurrency=*)     conc="${a#*=}" ;;
    --request-timeout=*) rto="${a#*=}" ;;
    --retries=*)         retries="${a#*=}" ;;
    --with-current)      with_current=1 ;;
    -h|--help)           sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//;/^set -uo/d'; exit 0 ;;
    *) echo "reflex-openrouter-backend: unknown flag: $a" >&2; exit 2 ;;
  esac
done
[[ -n "$api" ]] || { [[ "$model" =~ ^~?typesafe/jev ]] && api=decisions || api=chat; }
[[ "$api" == decisions || "$api" == chat ]] || { echo "reflex-openrouter-backend: --api must be decisions or chat" >&2; exit 2; }
[[ "$conc" =~ ^[0-9]+$ ]] && (( conc >= 1 && conc <= 32 )) || { echo "reflex-openrouter-backend: --concurrency must be 1-32" >&2; exit 2; }
[[ "$rto" =~ ^[1-9][0-9]*$ ]] || { echo "reflex-openrouter-backend: --request-timeout must be a positive integer" >&2; exit 2; }
[[ "$retries" =~ ^[0-9]$ ]] || { echo "reflex-openrouter-backend: --retries must be 0-9" >&2; exit 2; }
command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "reflex-openrouter-backend: jq and curl are required" >&2; exit 2; }

umask 077
RX_DIR=$(mktemp -d "${TMPDIR:-/tmp}/reflex-openrouter.XXXXXX") || exit 2
trap 'rm -rf "$RX_DIR"' EXIT
mkdir -p "$RX_DIR/req" "$RX_DIR/resp"

n=0
while IFS= read -r line || [[ -n "$line" ]]; do
  printf '%s\n' "$line" >"$RX_DIR/req/$n"; n=$((n + 1))
done

key_file="${FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE:-/etc/5dive/reflex-openrouter.key}"
key=""
[[ -r "$key_file" ]] && key=$(tr -d ' \r\n' <"$key_file")
if [[ -z "$key" ]]; then
  echo "reflex-openrouter-backend: no key readable at $key_file" >&2
  for ((i = 0; i < n; i++)); do
    jq -cn --arg e "no OpenRouter key readable at $key_file" '{choice:null, error:$e}'
  done
  exit 0
fi
if [[ -n "$(find "$key_file" -maxdepth 0 -perm /044 2>/dev/null)" ]]; then
  echo "reflex-openrouter-backend: warning: $key_file is readable by group/other; chmod 600 it" >&2
fi
printf 'Authorization: Bearer %s\n' "$key" >"$RX_DIR/auth"; key=""

export RX_DIR RX_MODEL="$model" RX_API="$api" RX_RTO="$rto" RX_RETRIES="$retries" RX_WITH_CURRENT="$with_current"
export RX_BASE="${FIVEDIVE_REFLEX_OPENROUTER_URL:-https://openrouter.ai/api}"

# The question and its criteria for one request, per policy. criteria maps each
# option id to a line of meaning; the backend must answer with an id.
# shellcheck disable=SC2089,SC2090  # a jq program, exported to the workers as text
RX_QUESTION_JQ='
  def crit($o; $d): $o | map({key: ., value: ($d[.] // null)}) | from_entries;
  (.options // []) as $o | (.state // {}) as $s
  | (if .policy == "task-route" then
       {instructions: "Which seat should own this task? Pick the seat whose role fits the work.",
        criteria: crit($o; ($s.lanes // {}))}
     elif .policy == "retry-action" then
       {instructions: "A verifier rejected this delivery. Send it back to the maker with the verifier'"'"'s feedback for another attempt, or hand it to a human?",
        criteria: crit($o; {retry_with_feedback: "Bounce it back to the maker with the feedback for another attempt.",
                            human: "Stop retrying and hand it to a human."})}
     elif .policy == "stuck" then
       {instructions: "The runtime suspects this seat'"'"'s claim on the task is stuck. Leave the session working, or reclaim the task so it restarts?",
        criteria: crit($o; {leave: "The session is still working; leave it alone.",
                            reclaim: "The session is gone or wedged; take the task back and requeue it."})}
     elif .policy == "gate-answer" then
       {instructions: "A person was asked to answer a gate on this task. Predict which answer they gave.",
        criteria: crit($o; (($s.gate.options // {}) + {approve: "Approve.", deny: "Deny.",
                                                     other: "Some other, free-text answer."}))}
     else {instructions: "Pick the best option.", criteria: crit($o; {})} end)
  + {state: (if env.RX_WITH_CURRENT == "1" then $s else ($s | del(.current)) end), options: $o}'
# shellcheck disable=SC2090
export RX_QUESTION_JQ

_rx_one() { # <index> -> writes $RX_DIR/resp/<index>, exactly one line
  local i="$1"
  local q body url code attempt=0 err="" out="$RX_DIR/resp/$i"
  q=$(jq -c "$RX_QUESTION_JQ" "$RX_DIR/req/$i" 2>/dev/null) \
    || { jq -cn '{choice:null, error:"unparseable request line"}' >"$out"; return 0; }
  if [[ "$RX_API" == decisions ]]; then
    url="$RX_BASE/alpha/decisions"
    body=$(jq -c --arg m "$RX_MODEL" '{model:$m, state:.state,
                  questions:{decision:{type:"choice", instructions, criteria}}}' <<<"$q")
  else
    url="$RX_BASE/v1/chat/completions"
    body=$(jq -c --arg m "$RX_MODEL" '{model:$m, temperature:0, max_tokens:24,
      messages:[{role:"system", content:"You are a decision function. Reply with exactly one option id from the options object, and nothing else: no quotes, no explanation."},
                {role:"user", content:({question:.instructions, options:.criteria, state:.state} | tojson)}]}' <<<"$q")
  fi
  printf '%s' "$body" >"$RX_DIR/body.$i"
  while :; do
    code=$(curl -sS -m "$RX_RTO" -o "$RX_DIR/raw.$i" -w '%{http_code}' -X POST "$url" \
             -H @"$RX_DIR/auth" -H 'Content-Type: application/json' \
             --data-binary @"$RX_DIR/body.$i" 2>"$RX_DIR/err.$i") || code="000"
    case "$code" in
      2??) err=""; break ;;
      429|5??|000) err="http $code: $(cat "$RX_DIR/raw.$i" "$RX_DIR/err.$i" 2>/dev/null | head -c 300 | tr -d '\n')" ;;
      *) err="http $code: $(head -c 300 "$RX_DIR/raw.$i" 2>/dev/null | tr -d '\n')"; break ;;
    esac
    (( attempt >= RX_RETRIES )) && break
    attempt=$((attempt + 1)); sleep $((attempt * 2))
  done
  if [[ -n "$err" ]]; then
    jq -cn --arg e "$err" --arg m "$RX_MODEL" '{choice:null, error:$e, backend:{name:"openrouter", model:$m}}' >"$out"
    return 0
  fi
  jq -c --arg m "$RX_MODEL" --arg api "$RX_API" --argjson opts "$(jq -c '.options' <<<"$q")" '
    if $api == "decisions" then
      (.answers.decision // {}) as $d
      | {choice: ($d.choice // null), confidence: ($d.confidence // null),
         probabilities: ($d.probabilities // null),
         probability_source: (if $d.probabilities then "head" else null end)}
    else
      ((.choices[0].message.content // "") | gsub("^[^A-Za-z0-9_-]+|[^A-Za-z0-9_-]+$"; "")) as $t
      | ([ $t | scan("[A-Za-z0-9_-]+") ]) as $toks
      | ([ $opts[] | select(. as $o | $toks | index([$o]) != null) ]) as $hits
      # The whole reply is an option, else exactly one option is named in it,
      # else the raw reply (not an option, so the replay scores it invalid).
      | {choice: (if ($opts | index([$t])) != null then $t elif ($hits|length) == 1 then $hits[0] else $t end),
         confidence: null, probabilities: null, probability_source: null}
    end
    + {backend: {name: "openrouter", api: $api, model: (.model // $m), cost: (.usage.cost // null)}}' \
    "$RX_DIR/raw.$i" >"$out" 2>/dev/null \
    || jq -cn --arg m "$RX_MODEL" '{choice:null, error:"unparseable response", backend:{name:"openrouter", model:$m}}' >"$out"
  return 0
}
export -f _rx_one

(( n > 0 )) && seq 0 $((n - 1)) | xargs -P "$conc" -I{} bash -c '_rx_one "$1"' _ {}

# In request order, one line each, whatever order the calls finished in.
for ((i = 0; i < n; i++)); do
  if [[ -s "$RX_DIR/resp/$i" ]]; then head -n1 "$RX_DIR/resp/$i"
  else jq -cn '{choice:null, error:"no response written"}'; fi
done
cost=$(cat "$RX_DIR"/resp/* 2>/dev/null | jq -s '[.[].backend.cost // 0] | add // 0 | . * 1000000 | round / 1000000' 2>/dev/null)
errs=$(cat "$RX_DIR"/resp/* 2>/dev/null | jq -s '[.[] | select(.error)] | length' 2>/dev/null)
echo "reflex-openrouter-backend: $n request(s), ${errs:-?} error(s), cost \$${cost:-?} ($RX_API, $model)" >&2
