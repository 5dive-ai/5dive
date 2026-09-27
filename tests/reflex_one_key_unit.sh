#!/usr/bin/env bash
# DIVE-5043 unit: ONE OpenRouter key per box. Reflex resolves its key as the
# root-only /etc/5dive/reflex-openrouter.key when it is non-empty, else the
# connector store's OPENROUTER_API_KEY — the key `5dive config openrouter-key=-`
# writes and voice reads. Nothing is moved or re-permissioned.
#
# WHAT IS ASSERTED HERE (the row's acceptance, one arm each)
#   CONNECTOR. only the connector key is set: config and status say set, source
#              connector, configured; a real `reflex replay` through the
#              reference backend, the in-CLI transport (gate shadow,
#              login-marker, pick-ref) and the shadow's opt-in all authenticate
#              with the CONNECTOR key.
#   BOTH.      the root-only file is ALSO set: it wins — source file, and every
#              call carries the file's key, never the connector's. An empty
#              override file does not shadow the connector.
#   NEITHER.   no key anywhere: unset / none / not configured, and every refusal
#              (replay backend, login-marker, pick-ref) names
#              `5dive config openrouter-key=-`.
#   PERMS.     the resolver moves and re-permissions nothing: the connector stays
#              640, the override 600, and neither file is rewritten by a read.
#   NOLEAK.    neither key appears in config (--json and text) or status output.
#   MUTANT.    a resolver with the connector branch deleted reds CONNECTOR; a
#              backend that prefers the connector reds BOTH.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.." || exit 2
ROOT="$PWD"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/reflex-one-key-unit.XXXXXX")"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh lib/state.sh \
         lib/audit.sh lib/registry.sh lib/tasks_db.sh lib/actor.sh lib/routing_receipt.sh lib/verify_policy.sh \
         lib/reflex.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh cmd_box_config.sh cmd_reflex.sh \
         cmd_reflex_pick_ref.sh cmd_reflex_login_marker.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
export BOX_CONFIG="$TMP/box.json"
export FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE="$TMP/etc/reflex-openrouter.key"
export FIVEDIVE_REFLEX_ENDPOINT_KEY_FILE="$TMP/etc/reflex-endpoint.key"
export CONNECTORS_DIR="$TMP/connectors"
mkdir -p "$TASKS_DIR" "$TMP/etc" "$CONNECTORS_DIR"
REGISTRY="$TMP/agents.json"; printf '{"agents":{"main":{},"dev":{}}}\n' >"$REGISTRY"
unset FIVEDIVE_REFLEX_RECEIPTS FIVEDIVE_REFLEX_SHADOW FIVEDIVE_REFLEX_SHADOW_BACKEND FIVEDIVE_REFLEX_OPENROUTER_URL
require_root() { return 0; }   # the setters' logic is the subject, not sudo
audit_log() { return 0; }
task_need_notify() { return 0; }
chown() { return 0; }          # root:claude needs root; the modes are still asserted
JSON_MODE=0
set +e
tasks_db_init >/dev/null 2>&1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if [[ "$2" == 0 ]]; then ok_t "$1"; else bad_t "$1" "${3:-}"; fi; }

cfg()  { ( JSON_MODE=1; cmd_box_config "$@" ) 2>&1; }
cfgt() { ( JSON_MODE=0; cmd_box_config ) 2>&1; }
get()  { ( JSON_MODE=1; cmd_box_config ) 2>/dev/null | jq -r ".data.$1"; }
st()   { ( JSON_MODE=1; _reflex_status --json ) 2>/dev/null; }
stt()  { ( JSON_MODE=0; _reflex_status ) 2>&1; }

# A curl stand-in: logs the URL and the Authorization header FILE's content
# (the key reaches curl as -H @file, so the file is what goes on the wire), and
# answers as OpenRouter's Decisions API.
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
jq -c '.questions.decision.criteria | keys_unsorted | first as $k
  | {model: "typesafe/jev-1.13", answers: {decision: {type: "choice", choice: $k,
     probabilities: {($k): 0.9}, confidence: 0.7}}, usage: {cost: 0.00001}}' "$body" >"$out"
printf 200
EOF
chmod +x "$TMP/fakebin/curl"
export FAKE_CURL_LOG="$TMP/curl.log"

CONNKEY="sk-or-v1-CONNSENTINEL$(date +%s%N)abc"
FILEKEY="sk-or-v1-FILESENTINEL$(date +%s%N)xyz"
GREQ='{"policy":"gate-answer","version":1,"type":"choice","state":{"task":"DIVE-1","gate":{"options":{"opt1":"ship","opt2":"hold"}}},"options":["opt1","opt2","other"]}'
BK="bash $ROOT/scripts/reflex-openrouter-backend.sh"

# One routed row, so `reflex replay` has a decision to replay.
( JSON_MODE=1; cmd_task_add --assignee=dev --priority=high -- "route me" ) >/dev/null 2>&1
replay() { # [backend script] -> the dump's JSONL on stdout; curl log in $FAKE_CURL_LOG
  : >"$FAKE_CURL_LOG"; rm -f "$TMP/dump.jsonl"
  PATH="$TMP/fakebin:$PATH" _reflex_replay --since=7d --backend="bash ${1:-$ROOT/scripts/reflex-openrouter-backend.sh}" \
    --dump="$TMP/dump.jsonl" --json >/dev/null 2>&1
  cat "$TMP/dump.jsonl" 2>/dev/null
}
decide() { : >"$FAKE_CURL_LOG"; PATH="$TMP/fakebin:$PATH" _reflex_endpoint_decide typesafe/jev-1.13 5 <<<"$GREQ" 2>/dev/null; }
authed_with() { # <key> — every logged call carried exactly this bearer
  [[ -s "$FAKE_CURL_LOG" ]] && ! grep -vqF "AUTH=[Authorization: Bearer $1]" "$FAKE_CURL_LOG"
}
noleak() { # <label> <output>
  if grep -qF -e "$CONNKEY" -e "$FILEKEY" -e "${CONNKEY:9:16}" -e "${FILEKEY:9:16}" <<<"$2"; then
    bad_t "NOLEAK: $1" "key material in output"
  else ok_t "NOLEAK: $1"; fi
}

echo "── NEITHER ─────────────────────────────────────────────────────────────"
check "no key anywhere: reflex_key unset, source none, not configured" \
  "$([[ "$(get reflex_key)" == unset && "$(get reflex_key_source)" == none && "$(get reflex_configured)" == false ]]; echo $?)" \
  "$(cfg | jq -c '.data | {reflex_key, reflex_key_source, reflex_configured}')"
R=$(replay)
check "a replay with no key: every case is an error that names 5dive config openrouter-key=-, and nothing was sent" \
  "$(jq -e -s 'length >= 1 and all((.valid | not) and (.response.error | test("5dive config openrouter-key=-")))' <<<"$R" >/dev/null \
     && [[ ! -s "$FAKE_CURL_LOG" ]]; echo $?)" "$R"
out=$( (reflex_model_resolve; reflex_key_readable || fail "$E_PERMISSION" "$(reflex_key_unreadable_msg pick-ref), or pass --backend=fake:first.") 2>&1)
check "the pick-ref / login-marker refusal names 5dive config openrouter-key=-" \
  "$(grep -qF '5dive config openrouter-key=-' <<<"$out"; echo $?)" "$out"
printf '<a href="/login">Log in</a>' >"$TMP/out.html"
out=$( (JSON_MODE=1; _reflex_login_marker example.test --logged-out="$TMP/out.html" --url=https://example.test/) 2>&1)
check "…and login-marker itself refuses with it" "$(grep -qF 'openrouter-key=-' <<<"$out"; echo $?)" "$out"
D=$(decide)
check "the in-CLI transport with no key: no_key, nothing sent" \
  "$(jq -e '.error == "no_key"' <<<"$D" >/dev/null && [[ ! -s "$FAKE_CURL_LOG" ]]; echo $?)" "$D"

echo "── CONNECTOR ───────────────────────────────────────────────────────────"
SETOUT=$(printf '%s\n' "$CONNKEY" | cfg openrouter-key=-)
check "openrouter-key=- (the Voice/Reflex settings field) writes the connector" \
  "$(grep -q '"ok":true' <<<"$SETOUT" && grep -qx "OPENROUTER_API_KEY=$CONNKEY" "$CONNECTORS_DIR/openrouter.env"; echo $?)" "$SETOUT"
check "…and its own response already says reflex has a key from the connector" \
  "$(jq -e '.data.reflex_key == "set" and .data.reflex_key_source == "connector" and .data.reflex_configured == true' <<<"$SETOUT" >/dev/null; echo $?)" "$SETOUT"
check "config: reflex_key set, source connector, configured; openrouter_key set" \
  "$([[ "$(get reflex_key)" == set && "$(get reflex_key_source)" == connector && "$(get reflex_configured)" == true && "$(get openrouter_key)" == set ]]; echo $?)"
check "config text names the source in words" \
  "$(grep -q "^reflex-key-source = connector (the box's openrouter-key, shared with voice)" <<<"$(cfgt)"; echo $?)" "$(cfgt | grep reflex-key)"
check "reflex status: key set, key_source connector, configured" \
  "$(jq -e '.key == "set" and .key_source == "connector" and .configured == true' <<<"$(st)" >/dev/null; echo $?)" "$(st)"
R=$(replay)
check "a reflex replay authenticates with the CONNECTOR key (reference backend)" \
  "$(jq -e -s 'length >= 1 and all(.valid)' <<<"$R" >/dev/null && authed_with "$CONNKEY"; echo $?)" "$R $(cat "$FAKE_CURL_LOG")"
D=$(decide)
check "the in-CLI transport (shadow, login-marker, pick-ref) authenticates with the connector key" \
  "$(jq -e '.choice == "opt1"' <<<"$D" >/dev/null && authed_with "$CONNKEY"; echo $?)" "$D $(cat "$FAKE_CURL_LOG")"
check "reflex_key_readable holds" "$(reflex_key_readable; echo $?)"
printf '{"reflex_model":"typesafe/jev-1.13"}\n' >"$BOX_CONFIG"
check "the gate shadow's opt-in sees the connector key (model set explicitly)" \
  "$([[ "$(reflex_shadow_model)" == typesafe/jev-1.13 ]]; echo $?)"
printf '{}\n' >"$BOX_CONFIG"
check "a quoted connector line (voice's parser accepts one) is read unquoted" \
  "$(printf 'OTHER=1\nOPENROUTER_API_KEY="%s"\n' "$CONNKEY" >"$TMP/q.env"; \
     [[ "$(CONNECTORS_DIR="$TMP/qdir"; mkdir -p "$TMP/qdir"; cp "$TMP/q.env" "$TMP/qdir/openrouter.env"; _reflex_openrouter_key)" == "$CONNKEY" ]]; echo $?)"

echo "── BOTH ────────────────────────────────────────────────────────────────"
SETOUT=$(printf '%s\n' "$FILEKEY" | cfg reflex-key=-)
check "reflex-key=- writes the root-only override (600) next to the connector" \
  "$(grep -q '"ok":true' <<<"$SETOUT" && [[ "$(stat -c %a "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE")" == 600 ]]; echo $?)" "$SETOUT"
check "both set: source file, still set and configured" \
  "$([[ "$(get reflex_key)" == set && "$(get reflex_key_source)" == file && "$(get reflex_configured)" == true ]]; echo $?)"
check "config text: the root-only key wins" \
  "$(grep -q '^reflex-key-source = file (the root-only reflex key; it wins over openrouter-key)' <<<"$(cfgt)"; echo $?)"
R=$(replay)
check "both set: the replay authenticates with the root-only FILE key, never the connector's" \
  "$(jq -e -s 'length >= 1 and all(.valid)' <<<"$R" >/dev/null && authed_with "$FILEKEY" && ! grep -qF "$CONNKEY" "$FAKE_CURL_LOG"; echo $?)" "$(cat "$FAKE_CURL_LOG")"
D=$(decide)
check "both set: the in-CLI transport uses the file key, never the connector's" \
  "$(authed_with "$FILEKEY" && ! grep -qF "$CONNKEY" "$FAKE_CURL_LOG"; echo $?)" "$(cat "$FAKE_CURL_LOG")"
: >"$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE"
check "an EMPTY override does not shadow the connector: source connector" \
  "$([[ "$(get reflex_key_source)" == connector ]] && { decide >/dev/null; authed_with "$CONNKEY"; }; echo $?)" "$(cat "$FAKE_CURL_LOG")"
printf '%s\n' "$FILEKEY" >"$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE"; chmod 600 "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE"
if (( EUID != 0 )); then
  chmod 000 "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE"
  check "an override this caller cannot read is still the source: not readable, and the connector is not silently used" \
    "$([[ "$(reflex_key_source)" == file ]] && ! reflex_key_readable && [[ -z "$(_reflex_openrouter_key)" ]]; echo $?)"
  chmod 600 "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE"
else
  ok_t "an unreadable override (skipped: root reads mode 000)"
fi

echo "── PERMS ───────────────────────────────────────────────────────────────"
M0=$(stat -c '%a %Y' "$CONNECTORS_DIR/openrouter.env" "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE")
sleep 1; get reflex_key >/dev/null; st >/dev/null; decide >/dev/null; replay >/dev/null
check "reads move nothing: connector 640, override 600, neither rewritten" \
  "$([[ "$(stat -c '%a %Y' "$CONNECTORS_DIR/openrouter.env" "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE")" == "$M0" \
        && "$(stat -c %a "$CONNECTORS_DIR/openrouter.env")" == 640 ]]; echo $?)" "$M0"

echo "── NOLEAK ──────────────────────────────────────────────────────────────"
noleak "config --json" "$(cfg)"
noleak "config text" "$(cfgt)"
noleak "reflex status --json" "$(st)"
noleak "reflex status text" "$(stt)"
rm -f "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE"
noleak "config --json (connector only)" "$(cfg)"
noleak "reflex status text (connector only)" "$(stt)"

echo "── MUTANT ──────────────────────────────────────────────────────────────"
# 1. The resolver with its connector branch deleted: reflex is blind to the
#    shared key again. CONNECTOR must go red.
ML="$TMP/reflex.mut.sh"
sed '/^reflex_key_source() {/,/^}/{/if \[\[ -r "\$c" \]\]; then/,/^  fi$/d}' src/lib/reflex.sh >"$ML"
if cmp -s "$ML" src/lib/reflex.sh; then bad_t "MUTANT 1: the connector-branch anchor moved" "update the sed in this harness"
else
  MR=$( ( source "$ML"; [[ "$(reflex_key_source)" == connector ]] && { decide >/dev/null; authed_with "$CONNKEY"; }; echo $? ) )
  check "MUTANT 1: a resolver without the connector branch reds CONNECTOR" "$([[ "$MR" != 0 ]]; echo $?)" "rc=$MR"
fi
# 2. A backend that tries the connector FIRST: BOTH must go red.
printf '%s\n' "$FILEKEY" >"$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE"; chmod 600 "$FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE"
MB="$TMP/backend.mut.sh"
sed 's|^  if \[\[ -s "\$key_file" \]\]; then$|  if false; then|' scripts/reflex-openrouter-backend.sh >"$MB"
if cmp -s "$MB" scripts/reflex-openrouter-backend.sh; then bad_t "MUTANT 2: the override anchor moved" "update the sed in this harness"
else
  replay "$MB" >/dev/null
  check "MUTANT 2: a backend that prefers the connector reds BOTH" \
    "$(authed_with "$FILEKEY"; [[ $? != 0 ]]; echo $?)" "$(cat "$FAKE_CURL_LOG")"
  replay >/dev/null
  check "…and the real backend, same state, is green" "$(authed_with "$FILEKEY"; echo $?)" "$(cat "$FAKE_CURL_LOG")"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
