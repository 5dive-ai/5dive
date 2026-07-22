# Read ~/.claude/channels/telegram/access.json for a claude-type agent. Used
# by the dashboard's access-control modal to render the current allowlist /
# groups / dmPolicy. Returns the parsed JSON in `data`. If the file doesn't
# exist yet (plugin hasn't persisted state), returns the same defaults the
# plugin would write on first run.
# Resolve the telegram-plugin state dir (where access.json lives) for an agent
# by type. claude, codex and grok each store it under ~/.<type>/channels/telegram/
# — the home subdir name matches the agent type, and all use the same
# access.json schema {dmPolicy, allowFrom, groups}. Echoes the dir on success;
# returns nonzero for types that have no telegram access.json (openclaw/hermes
# manage approvals through their own tooling, not this file). antigravity is the
# odd one out: its home subdir is ~/.gemini (not ~/.antigravity) because agy
# reuses Google's ~/.gemini parent, so it gets an explicit branch.
_tg_access_state_dir() {
  local user="$1" type="$2"
  case "$type" in
    claude|codex|grok|pi) printf '/home/%s/.%s/channels/telegram' "$user" "$type" ;;
    antigravity)       printf '/home/%s/.gemini/channels/telegram' "$user" ;;
    *) return 1 ;;
  esac
}

cmd_telegram_access_get() {
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent telegram-access get <name>"
  ensure_state
  local reg type channels
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  [[ ",$channels," == *",telegram,"* ]] \
    || fail "$E_VALIDATION" "agent '$name' has channels=$channels — telegram-access only applies to telegram"

  local user="agent-${name}"
  local state_dir
  state_dir=$(_tg_access_state_dir "$user" "$type") \
    || fail "$E_VALIDATION" "telegram-access supports claude, codex, grok, pi and antigravity agents (got type=$type)"
  local access="${state_dir}/access.json"
  local raw
  raw=$(sudo -u "$user" cat "$access" 2>/dev/null || true)
  if [[ -z "$raw" ]] || ! jq -e . >/dev/null 2>&1 <<<"$raw"; then
    raw='{"dmPolicy":"pairing","allowFrom":[],"groups":{}}'
  fi
  ok "" '{access: $a, botUsername: $u}' \
     --argjson a "$raw" \
     --arg u "$(jq -r --arg n "$name" '.agents[$n].botUsername // ""' <<<"$reg")"
}

# Write the telegram access.json for a claude/codex/grok agent (path resolved
# by type via _tg_access_state_dir — all three share the same schema).
# The new JSON body comes in on stdin (the dashboard sends it via the
# `stdin` field on /server/agents/exec so it never lands in argv).
#
# Schema validated server-side: dmPolicy in {pairing,allowlist,disabled},
# allowFrom = array of numeric-string ids, groups = object keyed by chat id
# whose values are {requireMention: bool, allowFrom: string[]}. Any keys we
# don't expose (pending, mentionPatterns, replyToMode, textChunkLimit,
# chunkMode, ackReaction) are merged from the existing file rather than
# clobbered, so opaque settings the dashboard hasn't surfaced survive a
# save. Plugin re-reads on every inbound message — no agent restart needed.
cmd_telegram_access_set() {
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent telegram-access set <name>  (JSON body on stdin)"
  ensure_state
  local reg type channels
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  [[ ",$channels," == *",telegram,"* ]] \
    || fail "$E_VALIDATION" "agent '$name' has channels=$channels — telegram-access only applies to telegram"
  local user="agent-${name}"
  local state_dir
  state_dir=$(_tg_access_state_dir "$user" "$type") \
    || fail "$E_VALIDATION" "telegram-access supports claude, codex, grok, pi and antigravity agents (got type=$type)"

  local body
  body=$(cat)
  [[ -n "$body" ]] || fail "$E_USAGE" "telegram-access set expects JSON on stdin"
  jq -e . >/dev/null 2>&1 <<<"$body" \
    || fail "$E_VALIDATION" "stdin is not valid JSON"

  step "Updating telegram access for agent '$name'"
  # Validation + atomic write live in the same python step so a bad shape
  # exits non-zero before we touch the file. STATE is the agent's plugin
  # state dir; PATCH is the dashboard's proposed {dmPolicy, allowFrom,
  # groups, botToBot?} blob. Unknown keys in the existing file (pending,
  # mentionPatterns, replyToMode, textChunkLimit, chunkMode, ackReaction)
  # survive the merge — only the dashboard-owned keys are replaced, and
  # botToBot (DIVE-161) only when the patch includes it.
  local script
  script=$(cat <<'PY'
import json, os, re, sys, tempfile

ID_RE = re.compile(r"^-?[0-9]+$")
state = os.environ['STATE']
try:
    patch = json.loads(os.environ['PATCH'])
except json.JSONDecodeError as e:
    print(f"invalid JSON: {e}", file=sys.stderr); sys.exit(2)

def bad(msg):
    print(msg, file=sys.stderr); sys.exit(2)

if not isinstance(patch, dict):
    bad("top-level must be an object")
if patch.get('dmPolicy') not in ('pairing', 'allowlist', 'disabled'):
    bad("dmPolicy must be one of pairing|allowlist|disabled")
allow = patch.get('allowFrom')
if not isinstance(allow, list) or not all(isinstance(s, str) and ID_RE.match(s) for s in allow):
    bad("allowFrom must be an array of numeric-string ids")
groups = patch.get('groups')
if not isinstance(groups, dict):
    bad("groups must be an object")
for gid, gcfg in groups.items():
    if not ID_RE.match(gid):
        bad(f"group key '{gid}' is not numeric")
    if not isinstance(gcfg, dict):
        bad(f"group '{gid}' value must be an object")
    if 'requireMention' in gcfg and not isinstance(gcfg['requireMention'], bool):
        bad(f"group '{gid}'.requireMention must be a boolean")
    if 'allowFrom' in gcfg:
        gallow = gcfg['allowFrom']
        if not isinstance(gallow, list) or not all(isinstance(s, str) and ID_RE.match(s) for s in gallow):
            bad(f"group '{gid}'.allowFrom must be an array of numeric-string ids")

# botToBot (DIVE-161) is OPTIONAL — present only when the dashboard's bot-to-bot
# section is in play. Shape mirrors the plugin's BotToBotConfig (botguard.ts):
# {enabled:bool, allowFrom?:[bot username/id strings], maxPerMin?:int>0,
# dedupeWindowMs?:int>=0}. Omitting the key leaves any existing config untouched.
b2b = patch.get('botToBot')
if b2b is not None:
    if not isinstance(b2b, dict):
        bad("botToBot must be an object")
    if not isinstance(b2b.get('enabled'), bool):
        bad("botToBot.enabled must be a boolean")
    if 'allowFrom' in b2b:
        ba = b2b['allowFrom']
        if not isinstance(ba, list) or not all(isinstance(s, str) and s for s in ba):
            bad("botToBot.allowFrom must be an array of non-empty strings (bot @usernames or ids)")
    if 'maxPerMin' in b2b and not (isinstance(b2b['maxPerMin'], int) and not isinstance(b2b['maxPerMin'], bool) and b2b['maxPerMin'] > 0):
        bad("botToBot.maxPerMin must be a positive integer")
    if 'dedupeWindowMs' in b2b and not (isinstance(b2b['dedupeWindowMs'], int) and not isinstance(b2b['dedupeWindowMs'], bool) and b2b['dedupeWindowMs'] >= 0):
        bad("botToBot.dedupeWindowMs must be a non-negative integer")

os.makedirs(state, mode=0o700, exist_ok=True)
path = os.path.join(state, 'access.json')

try:
    with open(path) as f:
        existing = json.load(f)
except FileNotFoundError:
    existing = {}

merged = dict(existing)
for k in ('dmPolicy', 'allowFrom', 'groups'):
    merged[k] = patch[k]
if b2b is not None:
    merged['botToBot'] = b2b

fd, tmp = tempfile.mkstemp(dir=state, prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(merged, f, indent=2)
os.replace(tmp, path)
PY
)
  local err
  if ! err=$(sudo -u "$user" env STATE="$state_dir" PATCH="$body" python3 -c "$script" 2>&1 >/dev/null); then
    fail "$E_VALIDATION" "${err:-telegram access.json write failed for agent '$name'}"
  fi

  ok "telegram access updated for '$name'" \
     '{name:$n, updated:true}' \
     --arg n "$name"
}

# Drop a pending pairing entry without approving it. The dashboard's inbox
# UI calls this when the operator clicks "Ignore" on a stranger's DM —
# removes the code from access.json's pending map so it stops showing in
# the modal, but does NOT add the senderId to allowFrom. The plugin will
# re-prompt with a fresh code if the same sender messages again.
cmd_telegram_pending_ignore() {
  local name="" code=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  if [[ -z "$name" ]]; then name="$1"
          elif [[ -z "$code" ]]; then code="$1"
          else fail "$E_USAGE" "extra arg: $1"; fi ;;
    esac
    shift
  done
  [[ -n "$name" && -n "$code" ]] \
    || fail "$E_USAGE" "usage: 5dive agent telegram-pending-ignore <name> <code>"
  [[ "$code" =~ ^[A-Za-z0-9]{4,16}$ ]] \
    || fail "$E_VALIDATION" "invalid code format"
  ensure_state
  local reg type channels
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  [[ ",$channels," == *",telegram,"* ]] \
    || fail "$E_VALIDATION" "agent '$name' has channels=$channels — telegram-pending-ignore only applies to telegram"

  local user="agent-${name}"
  local state_dir
  state_dir=$(_tg_access_state_dir "$user" "$type") \
    || fail "$E_VALIDATION" "telegram-pending-ignore supports claude, codex, grok, pi and antigravity agents (got type=$type)"
  local access="${state_dir}/access.json"
  local err
  err=$(sudo -u "$user" env ACCESS="$access" CODE="$code" python3 - <<'PY' 2>&1 >/dev/null
import json, os, sys, tempfile

path = os.environ['ACCESS']
code = os.environ['CODE']

try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    print("access.json not found — nothing pending", file=sys.stderr); sys.exit(2)

pending = data.get('pending') or {}
if code not in pending:
    print(f"code '{code}' is not pending", file=sys.stderr); sys.exit(2)
pending.pop(code, None)
data['pending'] = pending

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
PY
  ) || fail "$E_PAIRING" "${err:-pending-ignore failed}"

  ok "ignored pending pairing '$code' for '$name'" \
     '{name:$n, code:$c, ignored:true}' \
     --arg n "$name" --arg c "$code"
}

# Resolve a Telegram chat reference — either a public @handle or a numeric
# chat id — to its full identity (id, displayName, type, isBot) via the
# agent's own bot token calling getChat. Used by the dashboard's
# add-allowlist UX (paste @handle instead of digging up an id) AND by the
# load-time name enrichment (turn cryptic ids in allowFrom into "Mark ·
# @lodar"). Token stays server-side. Returned id can then be written into
# allowFrom by the regular telegram-access set path — no schema change.
cmd_telegram_resolve_handle() {
  local name="" handle=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -[0-9]*) # leading-minus numeric — a group/channel id, not a flag
        if [[ -z "$name" ]]; then name="$1"
        elif [[ -z "$handle" ]]; then handle="$1"
        else fail "$E_USAGE" "extra arg: $1"; fi ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  if [[ -z "$name" ]]; then name="$1"
          elif [[ -z "$handle" ]]; then handle="$1"
          else fail "$E_USAGE" "extra arg: $1"; fi ;;
    esac
    shift
  done
  [[ -n "$name" && -n "$handle" ]] \
    || fail "$E_USAGE" "usage: 5dive agent telegram-resolve-handle <name> <@handle|chat_id>"
  # Note on arg parsing: a leading '-' on the handle arg (e.g. group id
  # -100123…) would normally match the -* flag glob and error out. The
  # case branch above handles this by accepting -[0-9]* positionally.
  # Normalise: accept "@foo", "foo", or a numeric chat id. Anything else is
  # rejected. Numeric ids may be negative for groups/channels.
  local lookup
  if [[ "$handle" =~ ^-?[0-9]{1,20}$ ]]; then
    # Numeric id — pass through verbatim. getChat accepts these for chats
    # the bot can see (users who've messaged it, groups it's in, public
    # channels). Failures map to NOT_FOUND below.
    lookup="$handle"
  else
    handle="${handle#@}"
    [[ "$handle" =~ ^[A-Za-z][A-Za-z0-9_]{3,31}$ ]] \
      || fail "$E_VALIDATION" "invalid handle (expected 5-32 chars, letters/digits/underscore, or a numeric id)"
    lookup="@${handle}"
  fi
  ensure_state
  local reg type channels
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  case "$type" in
    claude|codex|grok|pi|antigravity) ;;
    *) fail "$E_VALIDATION" "telegram-resolve-handle supports claude, codex, grok, pi and antigravity agents (got type=$type)" ;;
  esac
  [[ ",$channels," == *",telegram,"* ]] \
    || fail "$E_VALIDATION" "agent '$name' has channels=$channels — telegram-resolve-handle only applies to telegram"

  local token_env="${CONNECTORS_DIR}/telegram-${name}.env"
  local token
  token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$token_env" 2>/dev/null | head -1 || true)
  [[ -n "$token" ]] \
    || fail "$E_AUTH_REQUIRED" "no telegram bot token for agent '$name' (expected ${token_env})"

  local resp
  resp=$(curl -sS -m 10 --get \
    --data-urlencode "chat_id=${lookup}" \
    "https://api.telegram.org/bot${token}/getChat" 2>/dev/null || true)
  if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
    fail "$E_GENERIC" "telegram api unreachable"
  fi
  if [[ "$(jq -r '.ok' <<<"$resp" 2>/dev/null)" != "true" ]]; then
    local desc
    desc=$(jq -r '.description // "telegram api error"' <<<"$resp" 2>/dev/null)
    # getChat returns "Bad Request: chat not found" for unknown handles; map
    # to NOT_FOUND so the dashboard can show a friendly "no such bot" message.
    case "$desc" in
      *"chat not found"*|*"chat_id is empty"*) fail "$E_NOT_FOUND" "telegram: $desc" ;;
      *) fail "$E_GENERIC" "telegram: $desc" ;;
    esac
  fi

  # Per Bot API: getChat returns a Chat object (not User), which has no
  # is_bot field — that lives on User and is only delivered with inbound
  # messages. We derive isBot from the handle convention: Telegram requires
  # all bot usernames to end in "bot" at registration (case-insensitive),
  # so the suffix is a reliable signal for type=private chats.
  #
  # Chat objects: users/bots have first_name + optional last_name + optional
  # username. Groups/supergroups/channels have title + optional username.
  # We read both branches and prefer whichever populates.
  local chat_id chat_type username first_name last_name title
  chat_id=$(jq -r '.result.id // empty'         <<<"$resp")
  chat_type=$(jq -r '.result.type // empty'     <<<"$resp")
  username=$(jq -r '.result.username // empty'  <<<"$resp")
  first_name=$(jq -r '.result.first_name // empty' <<<"$resp")
  last_name=$(jq -r '.result.last_name // empty'   <<<"$resp")
  title=$(jq -r '.result.title // empty'        <<<"$resp")
  [[ -n "$chat_id" ]] \
    || fail "$E_GENERIC" "telegram getChat returned no id"

  local is_bot=false
  if [[ "$chat_type" == "private" ]] && [[ "${username,,}" == *bot ]]; then
    is_bot=true
  fi

  # Compose displayName by chat type. Falls back through: title (group/channel)
  # → first+last (user/bot) → @username → @handle from input → numeric id.
  local display="$title"
  if [[ -z "$display" ]]; then
    display="$first_name"
    [[ -n "$last_name" ]] && display="${display:+$display }${last_name}"
  fi
  if [[ -z "$display" ]]; then
    if [[ -n "$username" ]]; then display="@${username}"
    elif [[ -n "${handle:-}" ]]; then display="@${handle}"
    else display="$chat_id"
    fi
  fi

  local label="$display"
  [[ -n "$username" && "$display" != "@${username}" ]] && label="$display · @${username}"

  ok "resolved $label → $chat_id" \
     '{id:$id, isBot:($b == "true"), type:$t, username:$u, displayName:$d}' \
     --arg id "$chat_id" \
     --arg b  "$is_bot" \
     --arg t  "$chat_type" \
     --arg u  "$username" \
     --arg d  "$display"
}

# Interactive pairing for a telegram- or discord-enabled claude-family agent.
# Two paths:
#   --code=<code>     classic: user DMs bot, bot replies with "pair <code>",
#                     dashboard pastes that here. We pop <code> from access.json's
#                     pending map, add the senderId to allowFrom, drop
#                     approved/<senderId>.
#   --user-id=<id>    auto: caller already discovered the chat (via
#                     cmd_telegram_discover or out-of-band) and wants to seed
#                     access.json directly. Skips the code roundtrip — writes
#                     allowFrom/approved with the supplied id immediately.
#                     For private DMs chat_id == user_id, so --chat-id is
#                     optional.
#
# Telegram and Discord plugins use the same access.json schema + approved/
# dir layout, so the JSON patch is identical — only the paths, token env
# var, and welcome-delivery mechanism differ.
cmd_pair() {
  local name="" precode="" preuser="" prechat=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --code=*)     precode="${1#--code=}" ;;
      --user-id=*)  preuser="${1#--user-id=}" ;;
      --chat-id=*)  prechat="${1#--chat-id=}" ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent pair <name> [--code=<code> | --user-id=<id> [--chat-id=<id>]]"
  if [[ -n "$precode" && -n "$preuser" ]]; then
    fail "$E_USAGE" "--code and --user-id are mutually exclusive"
  fi
  if [[ -n "$preuser" ]]; then
    valid_telegram_chat_id "$preuser" \
      || fail "$E_VALIDATION" "invalid --user-id (numeric, optionally negative)"
    if [[ -n "$prechat" ]]; then
      valid_telegram_chat_id "$prechat" \
        || fail "$E_VALIDATION" "invalid --chat-id (numeric, optionally negative)"
    else
      # Private DM convention: chat_id matches user_id. Groups need explicit --chat-id.
      prechat="$preuser"
    fi
  fi
  ensure_state
  local reg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  local type channels
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  # channels is a comma-separable list (DIVE-856) — match membership, not the
  # whole string, so telegram+dashboard (the default claude combo) still pairs.
  # Mirrors the ",telegram," idiom the telegram-* subcommands already use.
  if [[ ",$channels," != *",telegram,"* && ",$channels," != *",discord,"* ]]; then
    fail "$E_VALIDATION" "agent '$name' has channels=$channels — pairing only applies to telegram or discord"
  fi
  # channels may be a comma-separated list (e.g. telegram,dashboard — the default
  # claude combo). Everything below (token env/var, access.json path, welcome,
  # INTRO copy) operates on ONE pairable channel, so pick it with the same
  # membership idiom: telegram takes precedence, else discord. Using the raw
  # $channels string here produced token_var unbound + a bogus
  # channels/telegram,dashboard/ path (DIVE-1767).
  local pair_channel
  if [[ ",$channels," == *",telegram,"* ]]; then
    pair_channel="telegram"
  else
    pair_channel="discord"
  fi
  # cmd_pair applies to claude, codex, grok and antigravity — their
  # telegram/discord plugins use a code-roundtrip (user DMs bot, bot replies with a code,
  # dashboard pastes the code back to seed access.json) and share the same
  # access.json schema + path layout (~/.<type>/channels/<channel>/). openclaw
  # and hermes are token-only: the bot token alone is enough to authorise the
  # agent, and inbound user approvals flow through openclaw's own `pairing`
  # subcommand rather than this code path.
  case "$type" in
    claude|codex|grok|antigravity) ;;
    openclaw|hermes)
      fail "$E_VALIDATION" "type=$type doesn't use pair codes — the bot token configured at create time is sufficient. To approve specific Telegram/Discord users for an openclaw agent, run: sudo -u agent-${name} openclaw pairing list" ;;
    *)
      fail "$E_VALIDATION" "pairing only applies to claude, codex, grok and antigravity agents (got type=$type)" ;;
  esac

  local user="agent-${name}"
  local access="/home/${user}/.${type}/channels/${pair_channel}/access.json"
  local token_env token_var
  case "$pair_channel" in
    telegram) token_env="${CONNECTORS_DIR}/telegram-${name}.env"; token_var="TELEGRAM_BOT_TOKEN" ;;
    discord)  token_env="${CONNECTORS_DIR}/discord-${name}.env";  token_var="DISCORD_BOT_TOKEN"  ;;
  esac

  local bot_token
  bot_token=$(sed -n "s/^${token_var}=//p" "$token_env" 2>/dev/null | head -1 || true)
  [[ -n "$bot_token" ]] \
    || fail "$E_AUTH_REQUIRED" "no bot token for agent '$name' — run: sudo 5dive agent config $name set ${pair_channel}.token=<token>"

  # Auto-pair path: caller already knows the (user_id, chat_id) — typically
  # because cmd_telegram_discover surfaced them from getUpdates. Seed
  # access.json directly without waiting for the plugin: the plugin only
  # writes access.json when it has state to persist (a pending pairing
  # entry, etc.), so on a freshly-created agent that's never received a
  # message the file may never appear. Writing it ourselves means the
  # plugin reads our allowFrom on first message — same end state as the
  # code-roundtrip path, no race with a pending entry.
  if [[ -n "$preuser" ]]; then
    local chat_id="$prechat"
    local state_dir="/home/${user}/.${type}/channels/${pair_channel}"
    sudo -u "$user" env SENDER="$preuser" CHAT="$chat_id" STATE="$state_dir" python3 - <<'PY' >&2 \
      || fail "$E_PAIRING" "auto-pair seed failed"
import json, os, tempfile

state = os.environ['STATE']
sender = os.environ['SENDER']
chat = os.environ['CHAT']

os.makedirs(state, mode=0o700, exist_ok=True)
path = os.path.join(state, 'access.json')

try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {"dmPolicy": "pairing", "allowFrom": [], "groups": {}, "pending": {}}

allow = list(data.get('allowFrom') or [])
if sender not in allow:
    allow.append(sender)
data['allowFrom'] = allow

approved = os.path.join(state, 'approved')
os.makedirs(approved, mode=0o700, exist_ok=True)
with open(os.path.join(approved, sender), 'w') as f:
    f.write(chat)

fd, tmp = tempfile.mkstemp(dir=state, prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
print(f"Auto-paired user {sender} (chat {chat})")
PY

    # Remember this operator id box-wide so future agents auto-pair to it
    # (shared operator allowlist — DIVE-320/325).
    _operator_record "$preuser"
    if [[ ",$channels," == *",telegram,"* ]]; then
      send_welcome_message "$chat_id" "$bot_token" "$name" "$type"
    fi
    ok "agent '$name' paired with chat $chat_id." \
       '{name:$n, channels:$ch, chatId:$c, paired:true}' \
       --arg n "$name" --arg ch "$channels" --arg c "$chat_id"
    return
  fi

  # Pair-code path: the bot writes access.json with a pending entry when the
  # user DMs it, so wait for that before trying to consume the code. Cold
  # start can take ~45s on a fresh box (skill preinstalls + plugin install
  # run during agent startup), so wait 90s.
  step "Waiting for $pair_channel plugin on agent '$name'..."
  local waited=0
  for _ in $(seq 1 90); do
    if sudo -u "$user" test -f "$access" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited+1))
  done
  sudo -u "$user" test -f "$access" 2>/dev/null \
    || fail "$E_TIMEOUT" "$access not found after 90s. Is the agent running? (systemctl status 5dive-agent@${name})"

  # Interactive INTRO is only shown to a human at a TTY. JSON callers must
  # pass --code=<code>; the non-precode path is unreachable over the API.
  if [[ -z "$precode" && "$JSON_MODE" == "0" ]]; then
    local app_label example_code
    case "$pair_channel" in
      telegram) app_label="Telegram"; example_code="d13dc3" ;;
      discord)  app_label="Discord";  example_code="a4f2b1" ;;
    esac
    cat >&2 <<INTRO
Open $app_label and send any message to your bot. The bot will reply with
something like:

    Pairing required — run in Claude Code:
    /${pair_channel}:access pair ${example_code}

Paste the reply (or just the code) below.

INTRO
  fi

  # Either prompt interactively (TTY) or consume --code once (exec path).
  local msg code chat_id tries_left=5
  [[ -n "$precode" ]] && tries_left=1
  while (( tries_left-- > 0 )); do
    if [[ -n "$precode" ]]; then
      msg="$precode"
    else
      read -r -p "Paste: " msg
    fi

    # grep with no match is expected when the user pastes just the bare code.
    code=$(printf '%s' "$msg" \
      | grep -oE 'pair[[:space:]]+[A-Za-z0-9]+' \
      | head -1 | awk '{print $2}' || true)
    if [[ -z "$code" ]]; then
      code=$(printf '%s' "$msg" | tr -d '[:space:]')
    fi
    if [[ ! "$code" =~ ^[A-Za-z0-9]{4,16}$ ]]; then
      warn "Could not extract a pair code from that. Paste the full bot reply or just the code."
      [[ -n "$precode" ]] && fail "$E_VALIDATION" "invalid --code=<code>"
      continue
    fi

    if chat_id=$(sudo -u "$user" env CODE="$code" ACCESS="$access" python3 - <<'PY'
import json, os, sys, tempfile

path = os.environ['ACCESS']
code = os.environ['CODE']

with open(path) as f:
    data = json.load(f)

pending = data.get('pending') or {}
entry = pending.pop(code, None)
if entry is None:
    print(f"Pair code '{code}' is not pending. Message the bot within the "
          "last hour, then retry.", file=sys.stderr)
    sys.exit(2)

sender = str(entry.get('senderId', '')).strip()
chat = str(entry.get('chatId', '')).strip()
if not sender:
    print("Pending entry missing senderId", file=sys.stderr)
    sys.exit(3)

allow = list(data.get('allowFrom') or [])
if sender not in allow:
    allow.append(sender)

data['allowFrom'] = allow
data['pending'] = pending

approved = os.path.join(os.path.dirname(path), 'approved')
os.makedirs(approved, mode=0o700, exist_ok=True)
with open(os.path.join(approved, sender), 'w') as f:
    f.write(chat)

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
print(f"Paired user {sender}", file=sys.stderr)
print(chat)
PY
    ); then
      if [[ -n "$chat_id" ]]; then
        break
      fi
      warn "Pairing returned no chat id. Try again."
      [[ -n "$precode" ]] && fail "$E_PAIRING" "pairing failed"
    else
      warn "That code isn't pending. Message the bot first, then paste the reply."
      [[ -n "$precode" ]] && fail "$E_PAIRING" "pairing code not pending"
    fi
  done

  [[ -n "${chat_id:-}" ]] || fail "$E_PAIRING" "exhausted retries without a successful pairing"

  # Telegram: CLI sends a welcome DM via Telegram's HTTP API.
  # Discord: the plugin's channel server polls approved/<senderId> and sends
  # its own "you're in" DM through the gateway — we don't need (and don't
  # have) a simple HTTP send path here.
  if [[ ",$channels," == *",telegram,"* ]]; then
    send_welcome_message "$chat_id" "$bot_token" "$name"
  fi
  ok "agent '$name' paired with chat $chat_id." \
     '{name:$n, channels:$ch, chatId:$c, paired:true}' \
     --arg n "$name" --arg ch "$channels" --arg c "$chat_id"
}

# One-shot "it works" DM after a successful pairing — labelled with the agent
# name + type so users running many bots can tell them apart. Token goes via
# URL-encoded POST body (not argv) so it doesn't show up in `ps`. Copy is
# per-type: claude surfaces its model/effort + voice (Claude-plugin features);
# codex/grok drop those lines since they're Claude-specific (and reading
# claude's settings.local.json would render wrong values for them).
send_welcome_message() {
  local chat_id="$1" bot_token="$2" agent_name="${3:-}" agent_type="${4:-claude}" text

  # FIVE_DOMAIN is the host's public subdomain (e.g. agent.example.com),
  # set during provisioning. Folded into the message only when present so
  # self-hosted boxes / dev VMs don't surface a half-rendered URL.
  local domain=""
  if [[ -r /etc/5dive/provisioning.env ]]; then
    domain=$(sed -n 's/^FIVE_DOMAIN=//p' /etc/5dive/provisioning.env 2>/dev/null | head -1)
  fi
  local live_line=""
  if [[ -n "$domain" ]]; then
    live_line=" Anything you build goes live at https://${domain} ready to share, or ask me to add your own domain."
  fi

  # "'<name>', " when we know the agent name, else "" → "I'm your X agent."
  local name_q=""
  [[ -n "$agent_name" ]] && name_q="'${agent_name}', "

  case "$agent_type" in
    codex|grok|antigravity)
      local kind
      if [[ "$agent_type" == "codex" ]]; then kind="Codex agent (OpenAI Codex)"
      elif [[ "$agent_type" == "antigravity" ]]; then kind="Antigravity agent (Google Gemini)"
      else kind="Grok agent (xAI Grok)"; fi
      text=$(cat <<EOF
👋 We're connected! I'm ${name_q}your ${kind}.

Here 24/7, ready to pick up where we left off. Send text, photos, or files.

Tell me what to build: app, site, bot, report, campaign. Consider it shipped.${live_line} Need more hands? Siblings on demand, working in parallel.
EOF
)
      ;;
    hermes|openclaw)
      # Hermes/OpenClaw are multi-provider runtimes — NEVER call them "Claude"
      # or read the base claude user's model (that's the DIVE bug a customer hit:
      # a Hermes+DeepSeek agent greeted as "Claude agent. Running opus."). Read
      # the REAL provider/model the agent actually signed in with.
      local kind
      [[ "$agent_type" == "hermes" ]] && kind="Hermes agent" || kind="OpenClaw agent"
      local detail provider model plabel
      detail=$(account_signin_detail "$agent_name" "$agent_type" 2>/dev/null || echo '{}')
      provider=$(jq -r '.provider // empty' <<<"$detail" 2>/dev/null || true)
      model=$(jq -r '.model // empty' <<<"$detail" 2>/dev/null || true)
      case "$provider" in
        deepseek)   plabel="DeepSeek" ;;
        anthropic)  plabel="Anthropic" ;;
        openai)     plabel="OpenAI" ;;
        openrouter) plabel="OpenRouter" ;;
        google)     plabel="Google" ;;
        "")         plabel="" ;;
        *)          plabel="${provider^}" ;;
      esac
      local model_line="Model and provider are switchable anytime, just ask."
      if [[ -n "$plabel" ]]; then
        if [[ -n "$model" ]]; then
          model_line="Running ${plabel} (${model}). Switchable anytime, just ask."
        else
          model_line="Running ${plabel}. Switchable anytime, just ask."
        fi
      fi
      text=$(cat <<EOF
👋 We're connected! I'm ${name_q}your ${kind}.

${model_line}

Here 24/7 with memory. Send text, photos, or files.

Tell me what to build: app, site, bot, report, campaign. Consider it shipped.${live_line} Need more hands? Siblings on demand, working in parallel.
EOF
)
      ;;
    *)
      # Read the agent's REAL model/effort from its own settings.json (where the
      # per-agent default — opus — is seeded). Fall back to the base claude user
      # and the legacy shared projects file. Never surface a raw "default"
      # placeholder: if we can't read a concrete model, show a generic line.
      local model="" effort="" f
      local candidates=()
      [[ -n "$agent_name" ]] && candidates+=("/home/agent-${agent_name}/.claude/settings.json")
      candidates+=("/home/claude/.claude/settings.json" "/home/claude/projects/.claude/settings.local.json")
      for f in "${candidates[@]}"; do
        [[ -r "$f" ]] || continue
        model=$(jq -r '.model // empty' "$f" 2>/dev/null)
        effort=$(jq -r '.effortLevel // empty' "$f" 2>/dev/null)
        [[ -n "$model" ]] && break
      done
      local model_line="Model and effort are switchable anytime, just ask."
      if [[ -n "$model" && "$model" != "default" ]]; then
        if [[ -n "$effort" && "$effort" != "default" ]]; then
          model_line="Running ${model} at ${effort} effort. Switchable anytime, just ask."
        else
          model_line="Running ${model}. Switchable anytime, just ask."
        fi
      fi
      text=$(cat <<EOF
👋 We're connected! I'm ${name_q}your Claude agent.

${model_line}

Here 24/7 with memory. Send text, photos, or files, or ask for voice if you'd rather talk.

Tell me what to build: app, site, bot, report, campaign. Consider it shipped.${live_line} Need more hands? Siblings on demand, working in parallel.
EOF
)
      ;;
  esac

  # DIVE-1571: first-contact CONTROL-PLANE welcome. An admin-isolation agent can actually
  # run `company` / `agent create` / `council` / `goal`, so it LEADS with the approved
  # (lodar, 2026-07-20) capability pitch instead of the plain per-type welcome above. A
  # standard/sandboxed agent keeps that per-type text — it must NOT claim powers it lacks.
  # Isolation is read from the agent's env file (written at create/init BEFORE this pair
  # fires). The fallback is FAIL-SAFE: an unreadable/missing isolation defaults to STANDARD
  # (plain welcome), never admin — a mis-seeded/edge agent wrongly telling a user "i can spin
  # up a team/company/council" is worse than an admin agent missing the pitch (main gate,
  # DIVE-1571). No em-dashes (public-copy rule). {name}=agent name; a nameless agent drops
  # the name clause.
  local iso=""
  [[ -n "$agent_name" ]] && iso=$(sed -n 's/^AGENT_ISOLATION=//p' "${ENV_DIR}/${agent_name}.env" 2>/dev/null | head -1)
  iso="${iso:-standard}"
  if [[ "$iso" == "admin" ]]; then
    local intro="hey, i'm your agent, and i'm not alone."
    [[ -n "$agent_name" ]] && intro="hey, i'm ${agent_name}, your agent, and i'm not alone."
    text=$(cat <<EOF
${intro} through 5dive i can spin up a whole team, stand up a company, run a council, or turn a goal into a plan. tell me what you're building, or say 'show me what you can do'.

Here 24/7 with memory. Send text, photos, or files.${live_line}
EOF
)
  fi

  curl -sS -o /dev/null \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${text}" \
    "https://api.telegram.org/bot${bot_token}/sendMessage" \
    && echo "Sent welcome message to chat ${chat_id}" >&2 \
    || warn "Failed to send welcome message"
}

# -------- lifecycle / inspection (start, stop, logs, send, clone, stats) --------

