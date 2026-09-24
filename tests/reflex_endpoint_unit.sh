#!/usr/bin/env bash
# DIVE-4932 unit: reflex's endpoint is a SETTING, and OpenRouter is only its
# default. `5dive config reflex-endpoint=<url>`, `reflex-api=`,
# `reflex-endpoint-key=-`, the relaxed `reflex-model=` on a custom endpoint,
# `reflex status` (endpoint / api / configured / --probe), and the one transport
# every caller shares (the gate shadow, login-marker) plus the replay's reference
# backend script.
#
# WHAT IS ASSERTED HERE
#   ROUND.     each new key round-trips through `config --json`; the api is read
#              off the endpoint's path; `default` clears; a Laya checkpoint name
#              is a valid model on a custom endpoint and refused on OpenRouter,
#              in either order within one call.
#   BAD.       a URL with credentials, a query, a fragment, a non-http scheme or
#              over 200 characters is refused, and so is systemone on OpenRouter.
#              Nothing is written.
#   CONFIGURED. a keyless custom endpoint is configured; OpenRouter with no key
#              is not. status and config say so.
#   KEY.       the OpenRouter key NEVER reaches a custom endpoint; the endpoint's
#              own bearer does, and never appears in any output.
#   WIRE.      a Laya-shaped /v1/systemone answer maps to choice/confidence/
#              probabilities; chat on a custom endpoint parses; the default is
#              byte-for-byte the old OpenRouter call.
#   SHADOW.    the gate shadow turns on for a custom endpoint with no OpenRouter
#              key, and its receipt names adapter=endpoint, api=systemone.
#   REPLAY.    scripts/reflex-openrouter-backend.sh follows the box endpoint.
#   PROBE.     `reflex status --probe` reports the endpoint host's /health.
#   MUTANT.    a transport that sends the OpenRouter key to a custom endpoint
#              reds KEY.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.." || exit 2
TMP="$(mktemp -d "${TMPDIR:-/tmp}/reflex-endpoint-unit.XXXXXX")"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/state.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh lib/routing_receipt.sh lib/verify_policy.sh \
         lib/reflex.sh cmd_box_config.sh cmd_reflex.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
export BOX_CONFIG="$TMP/box.json"
export FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE="$TMP/etc/reflex-openrouter.key"
export FIVEDIVE_REFLEX_ENDPOINT_KEY_FILE="$TMP/etc/reflex-endpoint.key"
mkdir -p "$TASKS_DIR" "$TMP/etc"
REGISTRY="$TMP/agents.json"; printf '{"agents":{"dev":{}}}\n' >"$REGISTRY"
unset FIVEDIVE_REFLEX_RECEIPTS FIVEDIVE_REFLEX_SHADOW FIVEDIVE_REFLEX_SHADOW_BACKEND FIVEDIVE_REFLEX_OPENROUTER_URL
require_root() { return 0; }   # the setter's logic is the subject, not sudo
audit_log() { return 0; }
JSON_MODE=0
set +e
tasks_db_init >/dev/null 2>&1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if [[ "$2" == 0 ]]; then ok_t "$1"; else bad_t "$1" "${3:-}"; fi; }

cfg()  { ( JSON_MODE=1; cmd_box_config "$@" ) 2>&1; }
get()  { ( JSON_MODE=1; cmd_box_config ) 2>/dev/null | jq -r ".data.$1"; }
st()   { ( JSON_MODE=1; _reflex_status --json "$@" ) 2>/dev/null; }
refused() { grep -q '"ok":true' <<<"$1"; [[ $? -ne 0 ]]; echo $?; }

LAYA="http://127.0.0.1:8765/v1/systemone"

# A curl stand-in. Logs the URL and the Authorization header FILE's content (the
# transport passes the key as -H @file, so the file is what reaches the wire),
# and answers like the server at that URL: /v1/systemone and /alpha/decisions in
# Laya's own response shape (laya/serve.py returns router.predict: {model,
# answers, usage, routing}), /chat/completions as a chat model, /health as Laya.
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
out="" body="" url="" auth=""
while (( $# )); do
  case "$1" in
    -o) out="$2"; shift ;;
    -H) [[ "$2" == @* ]] && auth=$(cat "${2#@}" 2>/dev/null); shift ;;
    --data-binary) body="${2#@}"; shift ;;
    -m|-w|-X) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf 'URL=%s AUTH=[%s]\n' "$url" "$auth" >>"$FAKE_CURL_LOG"
[[ -n "$body" ]] && cp "$body" "$FAKE_CURL_LOG.lastbody"
case "$url" in
  */health) printf '{"status":"ok","loaded":["typed-decisions"],"device":"cpu"}' >"$out"; printf 200 ;;
  */chat/completions)
    jq -c '.messages[1].content | fromjson | .options | keys_unsorted | last as $k
      | {model: "local/chat", choices: [{message: {content: " \($k). "}}]}' "$body" >"$out"; printf 200 ;;
  *)
    jq -c '.questions.decision.criteria | keys_unsorted | first as $k
      | {model: "typed-decisions", answers: {decision: {type: "choice", choice: $k,
         probabilities: {($k): 0.81}, confidence: 0.62}},
         usage: {input_tokens: 42, output_tokens: 1}, routing: {checkpoint: "typed-decisions"}}' "$body" >"$out"; printf 200 ;;
esac
EOF
chmod +x "$TMP/fakebin/curl"
export FAKE_CURL_LOG="$TMP/curl.log"
ORKEY="sk-or-v1-ORSENTINEL$(date +%s%N)abc"
EPKEY="laya-EPSENTINEL$(date +%s%N)xyz"
printf '%s\n' "$ORKEY" >"$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE"; chmod 600 "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE"
GREQ='{"policy":"gate-answer","version":1,"type":"choice","state":{"task":"DIVE-1","gate":{"options":{"opt1":"ship","opt2":"hold"}}},"options":["opt1","opt2","other"]}'
decide() { : >"$FAKE_CURL_LOG"; PATH="$TMP/fakebin:$PATH" _reflex_endpoint_decide "$1" 5 <<<"$GREQ" 2>/dev/null; }

echo "── ROUND ───────────────────────────────────────────────────────────────"
check "default: endpoint default, api decisions, provider openrouter" \
  "$([[ "$(get reflex_endpoint)" == default && "$(get reflex_api)" == decisions && "$(st | jq -r .provider)" == openrouter ]]; echo $?)"
OUT=$(cfg reflex-endpoint="$LAYA" reflex-model=typed-decisions)
check "reflex-endpoint=<laya> reflex-model=typed-decisions in one call" \
  "$([[ "$(get reflex_endpoint)" == "$LAYA" && "$(get reflex_model)" == typed-decisions && "$(get reflex_model_source)" == "box setting" ]]; echo $?)" "$OUT"
check "the api is read off the path: /v1/systemone -> systemone" \
  "$([[ "$(get reflex_api)" == systemone && "$(get reflex_api_source)" == "from the endpoint's path" ]]; echo $?)"
cfg reflex-endpoint=default reflex-model=default >/dev/null
OUT=$(cfg reflex-model=english reflex-endpoint="$LAYA")
check "the same pair in the other order is accepted too" "$([[ "$(get reflex_model)" == english ]]; echo $?)" "$OUT"
cfg reflex-api=chat >/dev/null
check "reflex-api=chat on the custom endpoint round-trips" "$([[ "$(get reflex_api)" == chat && "$(get reflex_api_source)" == "box setting" ]]; echo $?)"
cfg reflex-api=default >/dev/null
check "reflex-api=default clears it (back to the path's systemone)" \
  "$([[ "$(get reflex_api)" == systemone && "$(jq 'has("reflex_api")' "$BOX_CONFIG")" == false ]]; echo $?)"
cfg reflex-endpoint=default >/dev/null
check "reflex-endpoint=default clears it; the Laya model name degrades to the default and says why" \
  "$([[ "$(get reflex_endpoint)" == default && "$(jq 'has("reflex_endpoint")' "$BOX_CONFIG")" == false \
        && "$(get reflex_model)" == typesafe/jev-1.13 && "$(get reflex_model_source)" == *"not an OpenRouter id"* ]]; echo $?)"
cfg reflex-model=default >/dev/null

echo "── BAD ─────────────────────────────────────────────────────────────────"
before=$(cat "$BOX_CONFIG")
for bad in "reflex-endpoint=http://user:pw@127.0.0.1:8000/v1/systemone" \
           "reflex-endpoint=http://127.0.0.1:8000/v1/systemone?key=abc" \
           "reflex-endpoint=http://127.0.0.1:8000/v1/systemone#x" \
           "reflex-endpoint=ftp://127.0.0.1/x" "reflex-endpoint=127.0.0.1:8000" \
           "reflex-endpoint=http://127.0.0.1/a b" \
           "reflex-endpoint=http://h/$(printf 'x%.0s' {1..200})" \
           "reflex-api=systemone" "reflex-api=grpc" "reflex-model=typed-decisions"; do
  out=$(cfg "$bad")
  check "refused: ${bad:0:60}" "$(refused "$out")" "$out"
done
check "no refusal wrote anything" "$([[ "$(cat "$BOX_CONFIG")" == "$before" ]]; echo $?)"

echo "── CONFIGURED ──────────────────────────────────────────────────────────"
mv "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE" "$TMP/or.bak"
check "OpenRouter, no key: configured false (status and config)" \
  "$([[ "$(st | jq -r .configured)" == false && "$(get reflex_configured)" == false ]]; echo $?)"
cfg reflex-endpoint="$LAYA" reflex-model=typed-decisions >/dev/null
check "a custom endpoint with no key at all: configured true, provider custom" \
  "$(st | jq -e '.configured == true and .provider == "custom" and .endpoint == "'"$LAYA"'" and .api == "systemone" and .endpoint_key == "unset"' >/dev/null; echo $?)" "$(st)"
mv "$TMP/or.bak" "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE"

echo "── KEY ─────────────────────────────────────────────────────────────────"
R=$(decide typed-decisions)
check "custom endpoint, no endpoint key: POSTed to the endpoint with NO Authorization (the OpenRouter key stays home)" \
  "$(grep -qF "URL=$LAYA AUTH=[]" "$FAKE_CURL_LOG" && ! grep -qF "$ORKEY" "$FAKE_CURL_LOG"; echo $?)" "$(cat "$FAKE_CURL_LOG")"
SET_OUT=$(printf '%s\n' "$EPKEY" | cfg reflex-endpoint-key=-)
check "reflex-endpoint-key=- writes a 600 file and reads back set" \
  "$([[ "$(cat "$FIVEDIVE_REFLEX_ENDPOINT_KEY_FILE")" == "$EPKEY" && "$(stat -c %a "$FIVEDIVE_REFLEX_ENDPOINT_KEY_FILE")" == 600 \
        && "$(st | jq -r .endpoint_key)" == set ]]; echo $?)" "$SET_OUT"
R=$(decide typed-decisions)
check "with its own key: the endpoint gets Bearer <endpoint key>, never the OpenRouter key" \
  "$(grep -qF "AUTH=[Authorization: Bearer $EPKEY]" "$FAKE_CURL_LOG" && ! grep -qF "$ORKEY" "$FAKE_CURL_LOG"; echo $?)" "$(cat "$FAKE_CURL_LOG")"
ALL="$SET_OUT $(cfg) $( ( JSON_MODE=0; cmd_box_config ) 2>&1) $(st) $( ( JSON_MODE=0; _reflex_status ) 2>&1) $R $(grep -v AUTH "$FAKE_CURL_LOG")"
check "the endpoint key appears in no output (set, config, status, the answer)" "$(grep -qF "$EPKEY" <<<"$ALL"; [[ $? -ne 0 ]]; echo $?)"
out=$(printf '%s\n' "$EPKEY" | cfg reflex-endpoint-key=- reflex-key=-)
check "two stdin keys in one call are refused" "$(refused "$out")" "$out"
out=$(cfg "reflex-endpoint-key=$EPKEY")
check "an inline endpoint key is refused and not echoed" "$( [[ "$(refused "$out")" == 0 ]] && ! grep -qF "$EPKEY" <<<"$out"; echo $?)" "$out"

echo "── WIRE ────────────────────────────────────────────────────────────────"
check "a Laya /v1/systemone answer maps to choice, confidence, probabilities (source head)" \
  "$(jq -e '.choice == "opt1" and .confidence == 0.62 and .probabilities.opt1 == 0.81 and .probability_source == "head"' <<<"$R" >/dev/null; echo $?)" "$R"
check "the body is the decisions body: {model, state, questions.decision{type choice, criteria}}" \
  "$(jq -e '.model == "typed-decisions" and .state.task == "DIVE-1" and .questions.decision.type == "choice"
            and (.questions.decision.criteria | keys) == ["opt1","opt2","other"]' "$FAKE_CURL_LOG.lastbody" >/dev/null; echo $?)" "$(cat "$FAKE_CURL_LOG.lastbody")"
cfg reflex-endpoint=http://127.0.0.1:8766/v1/chat/completions >/dev/null
R=$(decide local/chat)
check "a custom chat endpoint: chat body, the padded one-option reply parses" \
  "$(jq -e '.choice == "other" and .confidence == null' <<<"$R" >/dev/null && grep -q 'URL=http://127.0.0.1:8766/v1/chat/completions' "$FAKE_CURL_LOG"; echo $?)" "$R"
cfg reflex-endpoint=default >/dev/null
R=$(decide typesafe/jev-1.13)
check "the default is the old call: OpenRouter /alpha/decisions with the OpenRouter key" \
  "$(grep -qF "URL=https://openrouter.ai/api/alpha/decisions AUTH=[Authorization: Bearer $ORKEY]" "$FAKE_CURL_LOG" && jq -e '.choice == "opt1"' <<<"$R" >/dev/null; echo $?)" "$(cat "$FAKE_CURL_LOG")"
R=$( ( FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE="$TMP/none"; decide typesafe/jev-1.13 ) )
check "the default with no key still refuses before any call (no_key)" \
  "$(jq -e '.error == "no_key"' <<<"$R" >/dev/null && [[ ! -s "$FAKE_CURL_LOG" ]]; echo $?)" "$R"

echo "── SHADOW ──────────────────────────────────────────────────────────────"
cfg reflex-endpoint="$LAYA" reflex-model=typed-decisions >/dev/null
M=$( ( FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE="$TMP/none"; reflex_shadow_model ) )
check "the shadow is ON for a custom endpoint with a Laya model and no OpenRouter key" "$([[ "$M" == typed-decisions ]]; echo $?)" "$M"
cfg reflex-endpoint=default >/dev/null
M=$(reflex_shadow_model; echo "rc=$?")
check "the same box.json model on OpenRouter keeps the shadow OFF (not an OpenRouter id)" "$([[ "$M" == rc=1 ]]; echo $?)" "$M"
cfg reflex-endpoint="$LAYA" >/dev/null
G='{"task_id":7,"ident":"DIVE-7","nt":"decision","ask":"ship?","opts":"ship|hold","rec":"ship","tier":"1","asked":"2026-09-24 12:00:00","answered":0,"title":"t","project":""}'
( unset _REFLEX_BOX_RECEIPTS; PATH="$TMP/fakebin:$PATH"; _reflex_shadow_one typed-decisions "$G" )
RC=$(db "SELECT detail FROM lifecycle_events WHERE kind='decision.gate-answer' ORDER BY id DESC LIMIT 1;")
check "the shadow receipt: adapter endpoint, api systemone, the pick and its confidence; no URL in it" \
  "$(jq -e '.mode == "shadow" and .backend == {adapter: "endpoint", model: "typed-decisions", api: "systemone"}
            and .result == "opt1" and .confidence == 0.62' <<<"$RC" >/dev/null && ! grep -q 127.0.0.1 <<<"$RC"; echo $?)" "$RC"

echo "── REPLAY ──────────────────────────────────────────────────────────────"
: >"$FAKE_CURL_LOG"
RQ=$(jq -c '.options = ["leave","reclaim"] | .policy = "stuck"' <<<"$GREQ")
RR=$(printf '%s\n%s\n' "$GREQ" "$RQ" | PATH="$TMP/fakebin:$PATH" bash scripts/reflex-openrouter-backend.sh --concurrency=2 2>/dev/null)
check "the replay backend follows the box endpoint: two lines, both valid, backend endpoint/systemone" \
  "$(jq -e -s 'length == 2 and .[0].choice == "opt1" and .[1].choice == "leave"
               and all(.backend.name == "endpoint" and .backend.api == "systemone" and .confidence == 0.62)' <<<"$RR" >/dev/null; echo $?)" "$RR"
check "…to the endpoint URL with the endpoint key, never the OpenRouter key" \
  "$([[ "$(grep -c "URL=$LAYA AUTH=\[Authorization: Bearer $EPKEY\]" "$FAKE_CURL_LOG")" == 2 ]] && ! grep -qF "$ORKEY" "$FAKE_CURL_LOG"; echo $?)" "$(cat "$FAKE_CURL_LOG")"
: >"$FAKE_CURL_LOG"
RR=$(printf '%s\n' "$GREQ" | PATH="$TMP/fakebin:$PATH" bash scripts/reflex-openrouter-backend.sh --endpoint=default --model=typesafe/jev-1.13 2>/dev/null)
check "--endpoint=default on the replay backend is OpenRouter again, with its key" \
  "$(grep -qF "URL=https://openrouter.ai/api/alpha/decisions AUTH=[Authorization: Bearer $ORKEY]" "$FAKE_CURL_LOG" \
     && jq -e '.backend.name == "openrouter"' <<<"$RR" >/dev/null; echo $?)" "$RR"
out=$(bash scripts/reflex-openrouter-backend.sh --endpoint=default --api=systemone </dev/null 2>&1; echo "rc=$?")
check "the replay backend refuses systemone on OpenRouter" "$(grep -q 'rc=2' <<<"$out"; echo $?)" "$out"

echo "── PROBE ───────────────────────────────────────────────────────────────"
S=$(PATH="$TMP/fakebin:$PATH" st --probe)
check "status --probe: GET <endpoint host>/health, ok, and Laya's own word (loaded checkpoints)" \
  "$(jq -e '.health.probed and .health.ok and .health.url == "http://127.0.0.1:8765/health" and .health.server.loaded == ["typed-decisions"]' <<<"$S" >/dev/null; echo $?)" "$S"
check "status without --probe makes no call (health null)" "$(: >"$FAKE_CURL_LOG"; S=$(PATH="$TMP/fakebin:$PATH" st); [[ "$(jq -c .health <<<"$S")" == null && ! -s "$FAKE_CURL_LOG" ]]; echo $?)"
cfg reflex-endpoint=http://127.0.0.1:1/v1/systemone >/dev/null
S=$(st --probe)   # the real curl, port 1: nothing listens there
cfg reflex-endpoint="$LAYA" >/dev/null
check "a dead endpoint probes as not ok, and status still exits 0" \
  "$(jq -e '.health.probed and (.health.ok | not)' <<<"$S" >/dev/null; echo $?)" "$S"

echo "── MUTANT ──────────────────────────────────────────────────────────────"
# A transport that reads the OpenRouter key for every endpoint. KEY must red.
MUT=$(mktemp "$TMP/mut.XXXXXX.sh")
sed 's|key_file=\$(_reflex_endpoint_key_file)$|key_file="${FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE}"|' src/lib/reflex.sh >"$MUT"
if cmp -s "$MUT" src/lib/reflex.sh; then
  bad_t "MUTANT: the anchor for the key-leak mutant moved" "update the sed in this harness"
else
  # shellcheck source=/dev/null
  ( source "$MUT"; decide typed-decisions >/dev/null )
  if grep -qF "$ORKEY" "$FAKE_CURL_LOG"; then ok_t "MUTANT: sending the OpenRouter key to a custom endpoint is caught by the KEY probe"
  else bad_t "MUTANT: the key-leak mutant did not leak — the probe is not proven" "$(cat "$FAKE_CURL_LOG")"; fi
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
