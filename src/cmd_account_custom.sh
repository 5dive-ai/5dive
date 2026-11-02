# «Your own AI»: a model server the owner runs, on any harness (DIVE-7568).
#
# Two verbs:
#   5dive account add <name> --provider=custom --base-url=<url> --model=<m> --harness=<h> [--api-key=-]
#   5dive account test --base-url=<url> --model=<m> --harness=<h> [--api-key=-] [--json]
#
# ONE RECORD, SIX RENDERINGS. The account keeps the address once, in its
# combined.env (FIVEDIVE_CUSTOM_{HARNESS,BASE_URL,MODEL,API_KEY}). systemd loads
# that file into every seat bound to the account, and 5dive-agent-start turns it
# into the harness's own config at each start (custom_ai_render_* there). Claude
# is the exception: it reads its endpoint from the environment directly, so its
# ANTHROPIC_* variables are written here, through the same _apply_byo_claude the
# --base-url create path uses.
#
# WHAT EACH HARNESS NEEDS FROM THE SERVER (and why `account test` asks):
#   claude                      Anthropic Messages  (POST <root>/v1/messages)
#   codex                       OpenAI Responses    (POST <root>/v1/responses) —
#                               codex 0.153+ refuses wire_api="chat", so a server
#                               that speaks only chat completions cannot run it.
#   hermes, openclaw, pi, opencode  OpenAI Chat     (POST <root>/v1/chat/completions)
# Ollama, vLLM and LM Studio serve all three. A server that serves only one is
# told which harnesses it can run (reason=wrong_format), never silently set up.

CUSTOM_AI_HARNESSES="claude codex hermes openclaw pi opencode"

custom_ai_harness_ok() { [[ " $CUSTOM_AI_HARNESSES " == *" ${1:-} "* ]]; }

# The wire format a harness needs: anthropic | responses | chat.
custom_ai_harness_wire() {
  case "$1" in
    claude) printf 'anthropic' ;;
    codex)  printf 'responses' ;;
    *)      printf 'chat' ;;
  esac
}

# URL shapes. The owner types the address the server prints: with or without
# /v1, with or without a trailing slash. Anthropic clients append /v1/messages
# themselves, OpenAI clients want the /v1 base.
custom_ai_trim_url() { local u="${1%/}"; printf '%s' "$u"; }
custom_ai_anthropic_url() {
  local u; u=$(custom_ai_trim_url "$1")
  printf '%s' "${u%/v1}"
}
custom_ai_openai_url() {
  local u rest; u=$(custom_ai_trim_url "$1")
  [[ "$u" == */v1 ]] && { printf '%s' "$u"; return; }
  rest="${u#*://}"
  # No path at all (http://host:port): the OpenAI base is /v1. A path that is
  # not /v1 (a gateway's /api/openai) is the owner's, kept as typed.
  if [[ "$rest" != */* ]]; then printf '%s/v1' "$u"; else printf '%s' "$u"; fi
}

# Read --api-key=- from stdin. Empty is allowed: a server on the office network
# often has no key at all.
_custom_ai_read_key() {
  local k="$1"
  if [[ "$k" == "-" ]]; then
    [[ -t 0 ]] && fail "$E_USAGE" "--api-key=- expects the key on stdin, stdin is a TTY"
    k=$(cat)
    k="${k%$'\n'}"
  fi
  [[ "$k" != *[[:space:]]* ]] || fail "$E_VALIDATION" "the key has a space or a line break in it"
  printf '%s' "$k"
}

_custom_ai_check_url() {
  valid_base_url "$1" \
    || fail "$E_VALIDATION" "invalid --base-url '${1:0:120}' (https:// anywhere; http:// only to this box or an office address: 10.x, 172.16-31.x, 192.168.x, 127.x)"
  # Every harness and the probe APPEND a path (/responses, /chat/completions,
  # /v1/messages); after a '?' or '#' that path lands in the query or fragment.
  [[ "$1" != *[?#]* ]] \
    || fail "$E_VALIDATION" "invalid --base-url '${1:0:120}' (no ? or # in the address: the server path is added after it)"
}

_custom_ai_check_model() {
  [[ -n "$1" ]] || fail "$E_USAGE" "--model=<name> is required (the model name your server serves, e.g. qwen3:32b)"
  [[ "$1" =~ ^[A-Za-z0-9._:/@+-]{1,200}$ ]] \
    || fail "$E_VALIDATION" "invalid --model '${1:0:80}' (letters, digits and . _ : / @ + - only)"
}

# custom_ai_save <profile> <harness> <base_url> <model> <key> — write the record.
custom_ai_save() {
  local profile="$1" harness="$2" url="$3" model="$4" key="$5"
  ensure_profile_dir "$profile" >/dev/null
  step "Saving your own AI on account '$profile' (${harness} → ${url}, model ${model})"
  printf '%s' "$harness" | profile_set_var "$profile" FIVEDIVE_CUSTOM_HARNESS
  printf '%s' "$url"     | profile_set_var "$profile" FIVEDIVE_CUSTOM_BASE_URL
  printf '%s' "$model"   | profile_set_var "$profile" FIVEDIVE_CUSTOM_MODEL
  printf '%s' "$key"     | profile_set_var "$profile" FIVEDIVE_CUSTOM_API_KEY
  if [[ "$harness" == claude ]]; then
    # Claude Code will not start on a base URL with no token, and a keyless
    # local server ignores the one it gets.
    _apply_byo_claude custom "${key:-no-key-required}" "$profile" "$model" "$(custom_ai_anthropic_url "$url")"
  fi
}

_account_add_custom_usage() {
  cat <<'ACCTCUSTOM'
usage: 5dive account add <name> --provider=custom --base-url=<url> --model=<name> --harness=<harness> [--api-key=-]

  Save your own AI server (Ollama, vLLM, LM Studio, a GPU box in the office) as
  an account. Agents bound to it run on that server.

  --harness   claude | codex | hermes | openclaw | pi | opencode
  --api-key=- the key on stdin. Leave it out when the server has none.

  Check it first: 5dive account test --base-url=<url> --model=<name> --harness=<harness>
ACCTCUSTOM
}

# `account add <name> --provider=custom ...` (cmd_account_add hands over here).
cmd_account_add_custom() {
  local name="" provider="" url="" model="" harness="" key="" replace=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provider=*) provider="${1#--provider=}" ;;
      --base-url=*) url="${1#--base-url=}" ;;
      --model=*)    model="${1#--model=}" ;;
      --harness=*|--type=*) harness="${1#--*=}" ;;
      --api-key=*)  key="${1#--api-key=}" ;;
      --replace)    replace=1 ;;
      -*)           fail "$E_USAGE" "unknown flag: $1"$'\n'"$(_account_add_custom_usage)" ;;
      *)            [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ "$provider" == custom ]] || fail "$E_USAGE" "$(_account_add_custom_usage)"
  [[ -n "$name" && -n "$url" && -n "$harness" ]] || fail "$E_USAGE" "$(_account_add_custom_usage)"
  valid_profile_name "$name" \
    || fail "$E_VALIDATION" "invalid account name (lowercase letters/digits/_-, start letter, <=32 chars)"
  [[ "$name" != "default" ]] \
    || fail "$E_VALIDATION" "'default' is reserved (clears an agent's account binding)"
  custom_ai_harness_ok "$harness" \
    || fail "$E_VALIDATION" "--harness must be one of: ${CUSTOM_AI_HARNESSES// /, } (got: ${harness:0:40})"
  _custom_ai_check_url "$url"
  _custom_ai_check_model "$model"
  key=$(_custom_ai_read_key "$key") || exit $?
  require_root
  local had_url=""
  [[ -d "${AUTH_PROFILES_DIR}/${name}" ]] && had_url=$(profile_env_value "$name" FIVEDIVE_CUSTOM_BASE_URL)
  if [[ -n "$had_url" ]] && (( ! replace )); then
    fail "$E_CONFLICT" "account '$name' already points at ${had_url}. Re-run with --replace to move it (every agent on it moves on its next restart)."
  fi
  custom_ai_save "$name" "$harness" "$url" "$model" "$key"
  # Seats already on the account pick the new address up on restart. An
  # operator park (desiredState=="stopped", written only by `5dive agent stop`)
  # survives the move: `systemctl restart` on a stopped unit STARTS it (DIVE-4399),
  # so a parked agent is skipped and gets the new address when it is next started.
  # Only the exact "stopped" skips; absent or anything else restarts (an unknown
  # must not freeze the agent on the old address).
  local _agent _parked
  while IFS=$'\t' read -r _agent _parked; do
    [[ -n "$_agent" ]] || continue
    if [[ "$_parked" == stopped ]]; then
      step "Leaving 5dive-agent@${_agent}.service down (parked); it uses the new address when started"
      continue
    fi
    step "Restarting 5dive-agent@${_agent}.service"
    systemctl restart "5dive-agent@${_agent}.service" >&2 2>&1 \
      || warn "restart of agent '$_agent' failed — check journalctl -u 5dive-agent@${_agent}"
  done < <(registry_read | jq -r --arg p "$name" '.agents | to_entries[] | select(.value.authProfile == $p) | [.key, ((.value.desiredState // "") | tostring)] | @tsv')
  ok "account '$name' saved: ${harness} on ${url} (model ${model})${key:+, with a key}. New agent: sudo 5dive agent create <name> --type=${harness} --auth-profile=${name}" \
     '{name:$n, provider:"custom", harness:$h, baseUrl:$u, model:$m, hasKey:$k}' \
     --arg n "$name" --arg h "$harness" --arg u "$url" --arg m "$model" --argjson k "$([[ -n "$key" ]] && echo true || echo false)"
}

# ---------------------------------------------------------------------------
# account test
# ---------------------------------------------------------------------------
# ONE request per wire format, each asking for a tool call. The answer is read
# for what it proves:
#   unreachable    nothing answered (connect refused, DNS, timeout, TLS)
#   bad_key        401/403
#   no_such_model  the server answered and named the model as unknown
#   no_tools       it answered, but with no tool call: the model wrote the call
#                  as text (qwen3:4b, DIVE-7560) or refused tools outright
#   wrong_format   it answers, but not in the format this harness needs
# format is what the server speaks (anthropic | openai), detected, never asked.

CUSTOM_AI_TEST_TIMEOUT="${CUSTOM_AI_TEST_TIMEOUT:-90}"

_custom_ai_tool_prompt='Call the add tool with a=2 and b=3. Do not answer in text.'

# _custom_ai_post <url> <key> <anthropic:0|1> <body> <outfile> → prints "<curl_rc> <http_code>"
_custom_ai_post() {
  local url="$1" key="$2" anth="$3" body="$4" out="$5" code rc=0
  # The key rides a header file, never argv (ps).
  local hf; hf=$(mktemp); chmod 600 "$hf"
  {
    echo 'content-type: application/json'
    (( anth )) && echo 'anthropic-version: 2023-06-01'
    if [[ -n "$key" ]]; then
      (( anth )) && echo "x-api-key: ${key}"
      echo "authorization: Bearer ${key}"
    fi
  } > "$hf"
  code=$(curl -sS -o "$out" -w '%{http_code}' --connect-timeout 10 --max-time "$CUSTOM_AI_TEST_TIMEOUT" \
           -H @"$hf" -X POST --data-binary @- "$url" <<<"$body" 2>/dev/null) || rc=$?
  rm -f "$hf"
  printf '%s %s' "$rc" "${code:-000}"
}

_custom_ai_body() {   # <wire> <model>
  local wire="$1" model="$2"
  case "$wire" in
    anthropic)
      jq -cn --arg m "$model" --arg p "$_custom_ai_tool_prompt" '{model:$m, max_tokens:256,
        messages:[{role:"user", content:$p}],
        tools:[{name:"add", description:"Add two integers.",
                input_schema:{type:"object", properties:{a:{type:"integer"}, b:{type:"integer"}}, required:["a","b"]}}]}' ;;
    responses)
      jq -cn --arg m "$model" --arg p "$_custom_ai_tool_prompt" '{model:$m, input:$p, max_output_tokens:256,
        tools:[{type:"function", name:"add", description:"Add two integers.",
                parameters:{type:"object", properties:{a:{type:"integer"}, b:{type:"integer"}}, required:["a","b"]}}]}' ;;
    chat)
      jq -cn --arg m "$model" --arg p "$_custom_ai_tool_prompt" '{model:$m, max_tokens:256, stream:false,
        messages:[{role:"user", content:$p}],
        tools:[{type:"function", function:{name:"add", description:"Add two integers.",
                parameters:{type:"object", properties:{a:{type:"integer"}, b:{type:"integer"}}, required:["a","b"]}}}]}' ;;
  esac
}

# _custom_ai_probe <wire> <base_url> <model> <key> → one verdict word:
#   ok | no_tools | no_such_model | bad_key | unreachable | absent
# "absent" = something answered, but this route/format is not served there.
_custom_ai_probe() {
  local wire="$1" url="$2" model="$3" key="$4" out res rc code target anth=0
  case "$wire" in
    anthropic) target="$(custom_ai_anthropic_url "$url")/v1/messages"; anth=1 ;;
    responses) target="$(custom_ai_openai_url "$url")/responses" ;;
    chat)      target="$(custom_ai_openai_url "$url")/chat/completions" ;;
  esac
  out=$(mktemp)
  res=$(_custom_ai_post "$target" "$key" "$anth" "$(_custom_ai_body "$wire" "$model")" "$out")
  rc="${res%% *}"; code="${res##* }"
  local body; body=$(head -c 20000 "$out" 2>/dev/null); rm -f "$out"
  if [[ "$rc" != 0 && "$code" == 000 ]]; then echo unreachable; return; fi
  [[ "$code" == 401 || "$code" == 403 ]] && { echo bad_key; return; }
  local msg; msg=$(jq -r '[.error.message?, .error?, .message?, .detail?] | map(select(type=="string")) | first // ""' <<<"$body" 2>/dev/null)
  [[ -n "$msg" ]] || msg="$body"
  msg="${msg,,}"
  if [[ "$code" == 2* ]]; then
    local shape
    case "$wire" in
      anthropic) shape=$(jq -r 'if (.content|type)=="array" then (if any(.content[]; .type=="tool_use") then "tool" else "text" end) else "bad" end' <<<"$body" 2>/dev/null) ;;
      responses) shape=$(jq -r 'if (.output|type)=="array" then (if any(.output[]; .type=="function_call") then "tool" else "text" end) else "bad" end' <<<"$body" 2>/dev/null) ;;
      chat)      shape=$(jq -r 'if (.choices|type)=="array" and (.choices|length)>0 then (if ((.choices[0].message.tool_calls // [])|length)>0 then "tool" else "text" end) else "bad" end' <<<"$body" 2>/dev/null) ;;
    esac
    case "$shape" in
      tool) echo ok ;;
      text) echo no_tools ;;
      *)    echo absent ;;
    esac
    return
  fi
  # A refusal that names the model: unknown model (Ollama "model \"x\" not
  # found, try pulling it first", vLLM "The model `x` does not exist").
  if [[ "$msg" == *model* ]] && [[ "$msg" == *"not found"* || "$msg" == *"does not exist"* || "$msg" == *"unknown model"* || "$msg" == *"no such model"* || "$msg" == *"not available"* ]]; then
    echo no_such_model; return
  fi
  # A refusal of tools themselves (Ollama: "<model> does not support tools").
  if [[ "$msg" == *"support tools"* || "$msg" == *"tool use is not supported"* || "$msg" == *"tools are not supported"* || "$msg" == *"tool_choice"* ]]; then
    echo no_tools; return
  fi
  echo absent
}

_account_test_usage() {
  cat <<'ACCTTEST'
usage: 5dive account test --base-url=<url> --model=<name> --harness=<harness> [--api-key=-] [--json]

  Send your AI server ONE request that needs a tool call, and say whether an
  agent on <harness> can work with it. Nothing is saved.

  --harness   claude | codex | hermes | openclaw | pi | opencode
  --api-key=- the key on stdin. Leave it out when the server has none.

  JSON: {ok, format: anthropic|openai|null, reason: null|unreachable|bad_key|no_such_model|no_tools|wrong_format, ...}
ACCTTEST
}

cmd_account_test() {
  local url="" model="" harness="" key=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base-url=*) url="${1#--base-url=}" ;;
      --model=*)    model="${1#--model=}" ;;
      --harness=*|--type=*) harness="${1#--*=}" ;;
      --api-key=*)  key="${1#--api-key=}" ;;
      -h|--help)    _account_test_usage; return 0 ;;
      *)            fail "$E_USAGE" "unknown argument: ${1:0:40}"$'\n'"$(_account_test_usage)" ;;
    esac
    shift
  done
  [[ -n "$url" && -n "$harness" ]] || fail "$E_USAGE" "$(_account_test_usage)"
  custom_ai_harness_ok "$harness" \
    || fail "$E_VALIDATION" "--harness must be one of: ${CUSTOM_AI_HARNESSES// /, } (got: ${harness:0:40})"
  _custom_ai_check_url "$url"
  _custom_ai_check_model "$model"
  key=$(_custom_ai_read_key "$key") || exit $?

  local want wire v reason="" format="" r_want=""
  want=$(custom_ai_harness_wire "$harness")
  # The harness's own format first: when it works, that is the whole answer.
  r_want=$(_custom_ai_probe "$want" "$url" "$model" "$key")
  case "$r_want" in
    ok)          format="$want" ;;
    unreachable|bad_key|no_such_model) reason="$r_want"; format="" ;;
    no_tools)    reason=no_tools; format="$want" ;;
    absent)
      # Not served in the format this harness needs. Ask in the other family to
      # say what it DOES speak (the app shows the harnesses that would work).
      local -a others=()
      case "$want" in
        anthropic) others=(chat) ;;
        responses) others=(chat anthropic) ;;
        chat)      others=(anthropic) ;;
      esac
      reason=wrong_format
      for wire in "${others[@]}"; do
        v=$(_custom_ai_probe "$wire" "$url" "$model" "$key")
        case "$v" in
          ok|no_tools) format="$wire"; break ;;
          no_such_model|bad_key) format="$wire"; reason="$v"; break ;;
        esac
      done ;;
  esac
  # The contract's format is the family: anthropic | openai.
  local fam=""
  case "$format" in anthropic) fam=anthropic ;; chat|responses) fam=openai ;; esac

  local good=false say
  [[ -z "$reason" ]] && good=true
  case "$reason" in
    "")            say="works: ${model} answered with a tool call, ${harness} can use it" ;;
    unreachable)   say="nothing answered at ${url} (is the server running, and reachable from this box?)" ;;
    bad_key)       say="the server refused the key" ;;
    no_such_model) say="the server does not have the model ${model} (for Ollama: ollama pull ${model})" ;;
    no_tools)      say="${model} answered, but without using the tool, so an agent could not act. Pick a model made for tool calling" ;;
    wrong_format)
      if [[ -n "$fam" ]]; then
        say="the server speaks the ${fam} format, which ${harness} cannot use"
        [[ "$harness" == codex && "$fam" == openai ]] && say="the server speaks OpenAI chat but not the Responses API codex needs. Use hermes, openclaw, pi or opencode instead"
      else
        say="the server answered, but not as an AI model server ${harness} can use"
      fi ;;
  esac
  # A probe that ran is a RESULT, not a CLI error: the verdict rides the normal
  # envelope ({ok:true, data:{ok, format, reason, ...}}) and the verb exits 0.
  # fail() stays for usage and validation errors only. The app reads data.ok
  # and data.reason (DIVE-7569).
  local prose="$say"
  [[ "$good" == true ]] || prose="NOT OK (${reason}) — $say"
  if (( JSON_MODE )); then
    ok "$prose" \
      '{ok:$ok, format:(if $f=="" then null else $f end), reason:(if $r=="" then null else $r end),
        harness:$h, model:$m, baseUrl:$u, needs:$w, message:$s}' \
      --argjson ok "$good" --arg f "$fam" --arg r "$reason" --arg h "$harness" --arg m "$model" \
      --arg u "$url" --arg w "$( [[ "$want" == anthropic ]] && echo anthropic || echo openai )" --arg s "$say"
  elif [[ "$good" == true ]]; then
    echo "OK — $say"
  else
    echo "$prose"
  fi
  return 0
}
