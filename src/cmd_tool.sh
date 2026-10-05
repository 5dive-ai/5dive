# cmd_tool — the box's tool keys (DIVE-5366): GitHub, Vercel, Stripe, Cloudflare,
# Meta, ElevenLabs, fal and Higgsfield, saved by pasting a key in the Telegram
# Mini App (Settings -> Tools), never at a terminal.
#
# The dashboard's Connect tools are CLI logins run in a terminal (`gh auth
# login`, `vercel login`, ...), and a login writes a credentials file for the
# ONE user who ran it, so no agent seat sees it. Here every tool is the env var
# its own CLI or SDK already reads (GH_TOKEN, VERCEL_TOKEN, STRIPE_API_KEY, ...),
# kept in one file every agent's shell loads:
#
#   /etc/5dive/connectors/tools.sh   640 root:claude, lines `export KEY='value'`
#
# 5dive-agent@.service points BASH_ENV at /usr/local/lib/5dive/tool-env.sh, a
# 644 shim install.sh writes that sources this file when the seat can read it,
# so each command an agent runs (every Bash tool call is a fresh non-interactive
# bash) reads the CURRENT keys: a save or a remove reaches a running agent on
# its next command, no restart. Missing file = no keys. A sandboxed seat (not in
# group claude) reads neither the keys nor an error (DIVE-5373).
#
# The Mini App reaches the box over the exec tunnel (`sudo -n 5dive tool ...`,
# the box key stays in the app, DIVE-462), the same way it saves an AI key.
# Values cross on STDIN only, one line per field, never argv: argv is audited.

TOOLS_ENV_FILE="${CONNECTORS_DIR}/tools.sh"
TOOLS_WRITE_LOCK="/run/5dive-tool-write.lock"

# id -> the env vars it fills, in the order the values arrive on stdin. Higgsfield
# is its REST key + secret (HF_API_KEY/HF_API_SECRET, what its SDK reads): its
# CLI logs in only by OAuth to the box's own localhost (DIVE-4489), so an agent
# calls the API with these instead. Meta's ads CLI reads ACCESS_TOKEN and
# AD_ACCOUNT_ID by those exact names.
declare -gA TOOL_ENV=(
  [github]="GH_TOKEN"
  [vercel]="VERCEL_TOKEN"
  [stripe]="STRIPE_API_KEY"
  [cloudflare]="CLOUDFLARE_API_TOKEN"
  [meta]="ACCESS_TOKEN AD_ACCOUNT_ID"
  [elevenlabs]="ELEVENLABS_API_KEY"
  [fal]="FAL_KEY"
  [higgsfield]="HF_API_KEY HF_API_SECRET"
  # Business apps (DIVE-5513): CRMs, calendars and accounting a partner cabinet
  # saves for its clients. Bitrix24 is its whole inbound-webhook URL (portal, user
  # and code in one), amoCRM is the account's domain then its token, and Pipedrive
  # is its token alone (api.pipedrive.com needs no company domain). An app outside
  # this list goes through --env below, not into this table.
  [bitrix24]="BITRIX24_WEBHOOK_URL"
  [amocrm]="AMOCRM_DOMAIN AMOCRM_TOKEN"
  [hubspot]="HUBSPOT_TOKEN"
  [pipedrive]="PIPEDRIVE_TOKEN"
  [notion]="NOTION_TOKEN"
  [asana]="ASANA_TOKEN"
  [calendly]="CALENDLY_TOKEN"
  [lexoffice]="LEXOFFICE_API_KEY"
  [sevdesk]="SEVDESK_API_TOKEN"
  [holded]="HOLDED_API_KEY"
)
TOOL_IDS=(github vercel stripe cloudflare meta elevenlabs fal higgsfield
  bitrix24 amocrm hubspot pipedrive notion asana calendly lexoffice sevdesk
  holded)

# Any other app (DIVE-5627): the CALLER names its variables, so a partner keeps
# its own app list in its own code and this catalog stays the shared one.
#   tool set <id> --env="A_TOKEN B_LOGIN"   tool rm <id> --env=A_TOKEN,B_LOGIN
#   tool ls --tool=<id>:A_TOKEN,B_LOGIN     (repeatable; listed after the catalog)
# Nothing but the keys themselves is stored. A variable must be a credential name
# or end in _LOGIN, _USER or _DOMAIN, under the same reserved prefixes as a
# secret-gate key (_tools_var_reserved), and may not be a catalog tool's own
# variable: a custom id must never overwrite GH_TOKEN. --env on a catalog id must
# name exactly its catalog variables.
TOOL_CUSTOM_ID_RE='^[a-z][a-z0-9-]{0,31}$'
TOOL_CUSTOM_MAX_VARS=4

# Printable ASCII with no space and no single quote: every real key and token
# fits, and the value can then sit inside '...' in a file bash sources with no
# way to end the quote.
_tool_value_ok() {
  local LC_ALL=C
  [[ "$1" =~ ^[!-~]{1,1024}$ && "$1" != *"'"* ]]
}

_tool_usage() {
  cat >&2 <<'EOF'
5dive tool — keys for the tools your agents use (GitHub, Vercel, Stripe, ...)

  5dive tool ls [--json]       which tools have a key (never the key)
  5dive tool set <tool>        save its key; values on STDIN, one line per field
  5dive tool rm <tool>         forget its key

  Tools and the variables each fills, in stdin order:
    github GH_TOKEN · vercel VERCEL_TOKEN · stripe STRIPE_API_KEY
    cloudflare CLOUDFLARE_API_TOKEN · meta ACCESS_TOKEN AD_ACCOUNT_ID
    elevenlabs ELEVENLABS_API_KEY · fal FAL_KEY
    higgsfield HF_API_KEY HF_API_SECRET

  Business apps:
    bitrix24 BITRIX24_WEBHOOK_URL · amocrm AMOCRM_DOMAIN AMOCRM_TOKEN
    hubspot HUBSPOT_TOKEN · pipedrive PIPEDRIVE_TOKEN
    notion NOTION_TOKEN · asana ASANA_TOKEN · calendly CALENDLY_TOKEN
    lexoffice LEXOFFICE_API_KEY · sevdesk SEVDESK_API_TOKEN · holded HOLDED_API_KEY

  Any other app: name its variables (credential names, or *_LOGIN/_USER/_DOMAIN)
    5dive tool set <id> --env="APP_LOGIN APP_TOKEN"
    5dive tool rm <id> --env="APP_LOGIN APP_TOKEN"
    5dive tool ls --tool=<id>:APP_LOGIN,APP_TOKEN    (repeatable)

  Every agent's commands see them as environment variables, from their next
  command on. set and rm are root-only.
EOF
}

cmd_tool() {
  local sub="${1:-}"; shift || true
  local a rest=()
  _TOOL_ENV_ARG="" _TOOL_ENV_GIVEN=0 _TOOL_LS_EXTRA=()
  for a in "$@"; do
    case "$a" in
      --json) JSON_MODE=1 ;;
      # Commas or spaces: a remote caller sends one argv word with no space in it.
      --env=*) _TOOL_ENV_ARG="${a#--env=}"; _TOOL_ENV_ARG="${_TOOL_ENV_ARG//,/ }"; _TOOL_ENV_GIVEN=1 ;;
      --tool=*) _TOOL_LS_EXTRA+=("${a#--tool=}") ;;
      *) rest+=("$a") ;;
    esac
  done
  case "$sub" in
    ls|list|"") _tool_ls ;;
    set) _tool_set "${rest[@]}" ;;
    rm|remove) _tool_rm "${rest[@]}" ;;
    -h|--help|help) _tool_usage ;;
    *) fail "$E_USAGE" "unknown tool command: $sub (ls|set|rm)" ;;
  esac
}

_tool_known() { [[ -n "${1:-}" && -n "${TOOL_ENV[$1]+x}" ]]; }

# A custom tool's variable (see TOOL_CUSTOM_ID_RE above). Returns 0 when usable.
_tool_custom_var_ok() {
  local n="$1" v
  [[ "$n" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || return 1
  for v in "${TOOL_ENV[@]}"; do [[ " $v " == *" $n "* ]] && return 1; done
  case "$n" in
    # The suffix stands in for a credential one; the prefix rules still apply.
    ?*_LOGIN|?*_USER|?*_DOMAIN) ! _tools_var_reserved "${n}_KEY" ;;
    *) ! _tools_var_reserved "$n" ;;
  esac
}

# The variables of <id>, space-separated, into _TOOL_VARS: the catalog's for a
# catalog id, else the caller's own list (validated). Fails with a usage error.
_tool_resolve() {
  local id="${1:-}" given="${3:-0}" v seen=" " n=0 list
  local -a words=()
  read -ra words <<<"${2:-}"
  list="${words[*]}"
  if _tool_known "$id"; then
    if (( given )) && [[ "$list" != "${TOOL_ENV[$id]}" ]]; then
      fail "$E_USAGE" "$id is a catalog tool; its variables are ${TOOL_ENV[$id]}"
    fi
    _TOOL_VARS="${TOOL_ENV[$id]}"
    return 0
  fi
  (( given )) || fail "$E_USAGE" "unknown tool '${id}' (one of: ${TOOL_IDS[*]}; any other app takes --env=\"VAR ...\")"
  [[ "$id" =~ $TOOL_CUSTOM_ID_RE ]] || fail "$E_USAGE" "tool id must be lower-case letters, digits and dashes: '${id:0:40}'"
  for v in "${words[@]}"; do
    _tool_custom_var_ok "$v" \
      || fail "$E_VALIDATION" "$v cannot be a tool variable: use a credential name (*_KEY, *_TOKEN, *_SECRET, *_PASSWORD) or *_LOGIN/_USER/_DOMAIN, not one another tool or the box already uses"
    [[ "$seen" == *" $v "* ]] && fail "$E_USAGE" "$v is named twice in --env"
    seen+="$v "; n=$((n+1))
  done
  (( n >= 1 && n <= TOOL_CUSTOM_MAX_VARS )) || fail "$E_USAGE" "--env names 1 to $TOOL_CUSTOM_MAX_VARS variables, space-separated"
  _TOOL_VARS="$list"
}

# The vars that have a non-empty line in the file. Names only: the value is
# never read into a variable. A file with no key left in it (rm of the last
# one keeps the header) is a grep no-match, exit 1, which pipefail would turn
# into a reasonless `tool ls` failure — the Mini App's Tools screen then could
# not list at all (divine-owl, 2026-10-03). No match means no keys, not an error.
_tool_set_vars() {
  [[ -r "$TOOLS_ENV_FILE" ]] || return 0
  { grep -oE "^export [A-Z_][A-Z0-9_]*='[^']" "$TOOLS_ENV_FILE" 2>/dev/null || true; } \
    | sed -E "s/^export ([A-Z0-9_]+)=.*/\1/"
}

_tool_ls() {
  local have id v connected out="[]" spec ids=() envs=() i
  for id in "${TOOL_IDS[@]}"; do ids+=("$id"); envs+=("${TOOL_ENV[$id]}"); done
  for spec in "${_TOOL_LS_EXTRA[@]}"; do
    id="${spec%%:*}"
    [[ "$spec" == *:* ]] || fail "$E_USAGE" "--tool takes <id>:VAR[,VAR...], got '${spec:0:60}'"
    _tool_known "$id" && continue
    v="${spec#*:}"
    _tool_resolve "$id" "${v//,/ }" 1
    ids+=("$id"); envs+=("$_TOOL_VARS")
  done
  have=" $(_tool_set_vars | tr '\n' ' ') "
  for i in "${!ids[@]}"; do
    connected=true
    for v in ${envs[$i]}; do [[ "$have" == *" $v "* ]] || connected=false; done
    out=$(jq -c --arg id "${ids[$i]}" --arg env "${envs[$i]}" --argjson c "$connected" \
      '. + [{id: $id, env: ($env | split(" ")), connected: $c}]' <<<"$out")
  done
  if (( JSON_MODE )); then
    jq -cn --argjson t "$out" '{ok:true, data:{tools:$t}}'
  else
    jq -r '.[] | "\(.id)\t\(if .connected then "connected" else "-" end)\t\(.env | join(" "))"' <<<"$out"
  fi
}

# Rewrite the file without `drop` vars, then append `add` lines. Atomic (temp in
# the same dir + rename) and serialized, as `secret write` does.
_tool_rewrite() {
  local drop="$1" add="$2" tmp v pat=""
  for v in $drop; do pat+="${pat:+|}$v"; done
  [[ -d "$CONNECTORS_DIR" ]] || install -d -m 750 -g claude "$CONNECTORS_DIR" 2>/dev/null || mkdir -p "$CONNECTORS_DIR"
  exec 9>"$TOOLS_WRITE_LOCK" || fail "$E_GENERIC" "cannot open the tool-key lock"
  flock 9 || fail "$E_GENERIC" "cannot take the tool-key lock"
  tmp=$(umask 077; mktemp "${TOOLS_ENV_FILE}.XXXXXX") || fail "$E_GENERIC" "could not stage the tool keys"
  {
    if [[ -f "$TOOLS_ENV_FILE" ]]; then
      grep -vE "^export (${pat})=" "$TOOLS_ENV_FILE" || true
    else
      printf '# 5dive tool keys (DIVE-5366). Written by `5dive tool`; loaded by every agent through BASH_ENV.\n'
    fi
    [[ -n "$add" ]] && printf '%s' "$add"
  } > "$tmp"
  chown root:claude "$tmp" 2>/dev/null || true
  chmod 640 "$tmp"
  mv -f "$tmp" "$TOOLS_ENV_FILE" || { rm -f "$tmp"; fail "$E_GENERIC" "could not save the tool keys"; }
  exec 9>&-
}

# One var into the shared file, for `secret write --connector=tools` (DIVE-5370):
# a key the owner pastes through a secret gate's one-time link lands where every
# agent reads it, under the same quote rule. The caller is root and holds the value.
_tool_put_var() {
  local key="$1" value="$2"
  _tool_value_ok "$value" \
    || fail "$E_VALIDATION" "$key must be one line of printable characters, no spaces or quotes. Nothing was saved"
  _tool_rewrite "$key" "export ${key}='${value}'"$'\n'
}

_tool_set() {
  local id="${1:-}"
  require_root tool set
  _tool_resolve "$id" "$_TOOL_ENV_ARG" "$_TOOL_ENV_GIVEN"
  local env="$_TOOL_VARS"
  [[ -t 0 ]] && fail "$E_USAGE" "the key goes on stdin, one line per field: $env"
  local vars=($env) vals=() line i add=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    vals+=("$line")
  done
  # One field per var, no more: an extra line is a paste gone wrong, not a key.
  (( ${#vals[@]} == ${#vars[@]} )) \
    || fail "$E_VALIDATION" "$id takes ${#vars[@]} value(s) ($env), got ${#vals[@]}. Nothing was saved"
  for i in "${!vars[@]}"; do
    _tool_value_ok "${vals[$i]}" \
      || fail "$E_VALIDATION" "${vars[$i]} must be one line of printable characters, no spaces or quotes. Nothing was saved"
    add+="export ${vars[$i]}='${vals[$i]}'"$'\n'
  done
  _tool_rewrite "$env" "$add"
  ok "$id key saved; agents see $env from their next command" \
     '{tool: $t, env: ($e | split(" ")), connected: true}' --arg t "$id" --arg e "$env"
}

_tool_rm() {
  local id="${1:-}"
  require_root tool rm
  _tool_resolve "$id" "$_TOOL_ENV_ARG" "$_TOOL_ENV_GIVEN"
  [[ -f "$TOOLS_ENV_FILE" ]] && _tool_rewrite "$_TOOL_VARS" ""
  ok "$id key removed" '{tool: $t, connected: false}' --arg t "$id"
}
