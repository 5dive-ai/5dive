# Single getUpdates long-poll round against a Telegram bot token. Returns
# JSON `{found:bool, userId, chatId, username, firstName}` on stdout — the
# dashboard wraps this in a re-call loop so it can show a "send /start to
# your bot" UI and react the moment the user does. Each call clears any
# webhook first (getUpdates is incompatible with a registered webhook), then
# blocks for up to <poll_secs> waiting for an update. <poll_secs> is capped
# below the upstream exec timeout so the HTTP layer doesn't kill the call
# mid-poll. Pure curl + jq — no extra deps.
cmd_telegram_discover() {
  local token="" agent="" poll_secs=50
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token=*)      token="${1#--token=}" ;;
      --agent=*)      agent="${1#--agent=}" ;;
      --poll-secs=*)  poll_secs="${1#--poll-secs=}" ;;
      -*)             fail "$E_USAGE" "unknown flag: $1" ;;
      *)              fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  # --agent=<name>: lookup the bot token from the agent's telegram connector
  # env file. Lets the dashboard discover-for-this-agent without having to
  # round-trip the token through the browser.
  if [[ -n "$agent" ]]; then
    [[ -z "$token" ]] \
      || fail "$E_USAGE" "--agent and --token are mutually exclusive"
    local env_file="${CONNECTORS_DIR}/telegram-${agent}.env"
    [[ -r "$env_file" ]] \
      || fail "$E_NOT_FOUND" "no telegram connector for agent '$agent' (looked at $env_file)"
    token=$(grep -E '^TELEGRAM_BOT_TOKEN=' "$env_file" 2>/dev/null \
            | head -1 | cut -d= -f2-)
    [[ -n "$token" ]] \
      || fail "$E_NOT_FOUND" "no TELEGRAM_BOT_TOKEN in $env_file"
  fi
  # `--token=-` reads the token from stdin so the secret never enters argv
  # (and thus never lands in /proc/<pid>/cmdline, shelld's audit log, or
  # server access logs). Same sentinel as `cos set --token=-` and
  # `auth set --api-key=-`; the dashboard's exec tunnel uses this form. DIVE-880.
  if [[ "$token" == "-" ]]; then
    [[ -t 0 ]] && fail "$E_USAGE" "--token=- expects the bot token on stdin"
    token=$(cat)
    token="${token//[$'\r\n\t ']/}"
  fi
  [[ -n "$token" ]] || fail "$E_USAGE" "usage: 5dive agent telegram-discover {--token=<bot-token>|--token=-|--agent=<name>} [--poll-secs=N]  (--token=- reads the token from stdin)"
  valid_telegram_token "$token" \
    || fail "$E_VALIDATION" "telegram token format looks wrong (expected <digits>:<20+ chars>)"
  [[ "$poll_secs" =~ ^[0-9]+$ ]] && (( poll_secs >= 1 && poll_secs <= 90 )) \
    || fail "$E_VALIDATION" "--poll-secs must be 1..90"

  # deleteWebhook + drop_pending_updates clears any existing webhook AND
  # discards stale updates so the first message we surface is one the user
  # actually just sent (not one queued from a prior session). Best-effort —
  # if Telegram returns non-200 we still try getUpdates; the caller will
  # just see found:false and re-poll.
  curl -sS -m 10 -o /dev/null \
    --data-urlencode "drop_pending_updates=true" \
    "https://api.telegram.org/bot${token}/deleteWebhook" || true

  # Long-poll. timeout=N tells Telegram to hold the connection open for up
  # to N seconds waiting for an update, returning earlier if one arrives.
  # curl's max-time is set just above so the socket survives the wait.
  local resp
  resp=$(curl -sS -m "$((poll_secs + 5))" \
    --data-urlencode "timeout=${poll_secs}" \
    --data-urlencode "limit=1" \
    --data-urlencode "allowed_updates=[\"message\"]" \
    "https://api.telegram.org/bot${token}/getUpdates" 2>/dev/null || true)

  # Empty / non-JSON response → treat as no message yet (dashboard re-polls).
  if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
    ok "" '{found:false}'
    return
  fi
  if [[ "$(jq -r '.ok' <<<"$resp" 2>/dev/null)" != "true" ]]; then
    local desc
    desc=$(jq -r '.description // "telegram api error"' <<<"$resp" 2>/dev/null)
    fail "$E_GENERIC" "telegram: $desc"
  fi
  local count
  count=$(jq -r '.result | length' <<<"$resp")
  if [[ "$count" == "0" ]]; then
    ok "" '{found:false}'
    return
  fi

  # Pull the message's `from` (user) + `chat`. For private DMs they're the
  # same numeric id, but allowing them to differ keeps groups working too.
  local user_id chat_id username first_name
  user_id=$(jq -r '.result[0].message.from.id // empty' <<<"$resp")
  chat_id=$(jq -r '.result[0].message.chat.id // empty' <<<"$resp")
  username=$(jq -r '.result[0].message.from.username // empty' <<<"$resp")
  first_name=$(jq -r '.result[0].message.from.first_name // empty' <<<"$resp")
  [[ -n "$user_id" && -n "$chat_id" ]] \
    || fail "$E_GENERIC" "telegram update missing from.id or chat.id"

  ok "discovered chat $chat_id (user $user_id)" \
     '{found:true, userId:$u, chatId:$c, username:$un, firstName:$fn}' \
     --arg u "$user_id" --arg c "$chat_id" --arg un "$username" --arg fn "$first_name"
}

# Token -> bot username via Telegram getMe. Returns username on stdout (exit 0)
# or empty (exit 1) on any failure (network, malformed response, missing
# username). Used by cmd_create and cmd_telegram_info to backfill the cached
# username in the registry; failures are non-fatal — callers degrade to
# "telegram" text without the @handle link.
fetch_bot_username() {
  local token="$1"
  local resp
  resp=$(curl -sS -m 10 \
    "https://api.telegram.org/bot${token}/getMe" 2>/dev/null) || return 1
  jq -e . >/dev/null 2>&1 <<<"$resp" || return 1
  [[ "$(jq -r '.ok // false' <<<"$resp" 2>/dev/null)" == "true" ]] || return 1
  local username
  username=$(jq -r '.result.username // empty' <<<"$resp")
  [[ -n "$username" ]] || return 1
  echo "$username"
}

# Fast bot-identity lookup. The dashboard fires this once when the user
# reaches the "discovering chat" step so the "open Telegram and send /start"
# instruction can render a t.me/<botusername> deep link rather than a plain
# text mention. Token never leaves the server.
cmd_telegram_getme() {
  local token=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token=*) token="${1#--token=}" ;;
      -*)        fail "$E_USAGE" "unknown flag: $1" ;;
      *)         fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  # `--token=-` reads the token from stdin — same argv-hygiene sentinel as
  # telegram-discover / `cos set --token=-`. DIVE-880.
  if [[ "$token" == "-" ]]; then
    [[ -t 0 ]] && fail "$E_USAGE" "--token=- expects the bot token on stdin"
    token=$(cat)
    token="${token//[$'\r\n\t ']/}"
  fi
  [[ -n "$token" ]] || fail "$E_USAGE" "usage: 5dive agent telegram-getme --token=<bot-token>  (or --token=- to read from stdin)"
  valid_telegram_token "$token" \
    || fail "$E_VALIDATION" "telegram token format looks wrong (expected <digits>:<20+ chars>)"

  local resp
  resp=$(curl -sS -m 10 \
    "https://api.telegram.org/bot${token}/getMe" 2>/dev/null || true)

  if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
    fail "$E_GENERIC" "telegram api unreachable"
  fi
  if [[ "$(jq -r '.ok' <<<"$resp" 2>/dev/null)" != "true" ]]; then
    local desc
    desc=$(jq -r '.description // "telegram api error"' <<<"$resp" 2>/dev/null)
    fail "$E_GENERIC" "telegram: $desc"
  fi

  local bot_id username first_name
  bot_id=$(jq -r '.result.id // empty' <<<"$resp")
  username=$(jq -r '.result.username // empty' <<<"$resp")
  first_name=$(jq -r '.result.first_name // empty' <<<"$resp")
  [[ -n "$username" ]] \
    || fail "$E_GENERIC" "telegram getMe missing username"

  ok "bot @$username" \
     '{botId:$id, username:$un, firstName:$fn}' \
     --arg id "$bot_id" --arg un "$username" --arg fn "$first_name"
}

# Name-based bot identity lookup. Reads the agent's stored telegram token
# server-side (so the dashboard never sees raw bot tokens), calls getMe,
# and caches the result under .agents.<name>.botUsername in the registry.
# Subsequent calls hit the cache and return without touching Telegram. Used
# by the dashboard's agents page to backfill @handles for agents created
# before botUsername-on-create was wired up. --refresh forces a re-fetch.
cmd_telegram_info() {
  local name=""
  local refresh=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --refresh) refresh=1 ;;
      -*)        fail "$E_USAGE" "unknown flag: $1" ;;
      *)         [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent telegram-info <name> [--refresh]"
  ensure_state
  local reg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  local channels
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  [[ ",$channels," == *",telegram,"* ]] \
    || fail "$E_VALIDATION" "agent '$name' has channels=$channels — telegram-info only applies to telegram"

  if (( ! refresh )); then
    local cached
    cached=$(jq -r --arg n "$name" '.agents[$n].botUsername // empty' <<<"$reg")
    if [[ -n "$cached" ]]; then
      ok "bot @$cached" \
         '{username:$un, cached:true}' \
         --arg un "$cached"
      return 0
    fi
  fi

  local token_env="${CONNECTORS_DIR}/telegram-${name}.env"
  local token
  token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$token_env" 2>/dev/null | head -1 || true)
  [[ -n "$token" ]] \
    || fail "$E_AUTH_REQUIRED" "no telegram bot token for agent '$name' (expected ${token_env})"

  local username
  username=$(fetch_bot_username "$token" 2>/dev/null) \
    || fail "$E_GENERIC" "telegram getMe failed (network or invalid token)"

  # Cache to registry so the next list/info call avoids the Telegram round-trip.
  with_registry_lock _persist_bot_username "$name" "$username"

  ok "bot @$username" \
     '{username:$un, cached:false}' \
     --arg un "$username"
}

_persist_bot_username() {
  local name="$1" username="$2"
  local reg
  reg=$(registry_read)
  jq --arg n "$name" --arg u "$username" \
    '.agents[$n].botUsername = $u' <<<"$reg" | registry_write
}

# DIVE-159 team-bot (decision A): the agent's forum topic in the shared team
# supergroup. teamTopic.threadId is the Telegram message_thread_id; teamTopic.chatId
# is the team supergroup id. Single source of truth — the provision createForumTopic
# hook writes it; the single listener reads it to route inbound thread->agent.
cmd_agent_topic_set() {
  local name="" thread_id="" chat_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --thread-id=*) thread_id="${1#--thread-id=}" ;;
      --chat-id=*)   chat_id="${1#--chat-id=}" ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent topic set <name> --thread-id=N --chat-id=N"
  [[ "$thread_id" =~ ^[0-9]+$ ]]  || fail "$E_VALIDATION" "--thread-id must be a positive integer"
  [[ "$chat_id"   =~ ^-?[0-9]+$ ]] || fail "$E_VALIDATION" "--chat-id must be an integer (supergroup ids are negative)"
  ensure_state
  local reg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  jq --arg n "$name" --argjson th "$thread_id" --argjson ch "$chat_id" \
    '.agents[$n].teamTopic = {threadId: $th, chatId: $ch}' <<<"$reg" | registry_write
  ok "team topic set for $name (thread $thread_id in chat $chat_id)" \
     '{agent:$n, threadId:$th, chatId:$ch}' \
     --arg n "$name" --argjson th "$thread_id" --argjson ch "$chat_id"
}

cmd_agent_topic_get() {
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent topic get <name>"
  ensure_state
  local reg tt
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  tt=$(jq -c --arg n "$name" '.agents[$n].teamTopic // null' <<<"$reg")
  if (( JSON_MODE )); then
    jq -cn --argjson d "$tt" '{ok:true, data:$d}'
  else
    [[ "$tt" == "null" ]] && echo "no team topic for $name" || echo "$tt"
  fi
}

