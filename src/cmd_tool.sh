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
  # AWS (DIVE-5934): an IAM access key pair, the two names the aws CLI and every
  # AWS SDK read before any config file.
  [aws]="AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY"
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
TOOL_IDS=(github vercel stripe cloudflare meta elevenlabs fal higgsfield aws
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
    aws AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

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

  Google signs in instead of taking a key (one sign-in serves every agent):
    5dive tool google start            -> {session, state}
    5dive tool google poll <session>   -> state, url to open, account when done
    5dive tool google submit <session> the code Google shows, on STDIN
    5dive tool google cancel <session>
    5dive tool rm google               sign out
  Every google verb, and rm google, is root-only.
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
    google) _tool_google "${rest[@]}" ;;
    -h|--help|help) _tool_usage ;;
    *) fail "$E_USAGE" "unknown tool command: $sub (ls|set|rm|google)" ;;
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
  [[ "$id" == "$TOOL_GOOGLE_ID" ]] \
    && fail "$E_USAGE" "google signs in rather than taking a key: 5dive tool google start (and tool rm google to sign out)"
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
      '. + [{id: $id, kind: "key", env: ($env | split(" ")), connected: $c}]' <<<"$out")
  done
  # The sign-ins after every key tool (DIVE-5934). Read from gcloud's own files,
  # never by running gcloud: ls must answer on a box that has not installed it.
  local account
  account=$(_tool_google_account)
  connected=false
  [[ -n "$account" && -s "$TOOL_GCLOUD_CONFIG/credentials.db" ]] && connected=true
  [[ "$connected" == true ]] || account=""
  out=$(jq -c --arg id "$TOOL_GOOGLE_ID" --arg a "$account" --argjson c "$connected" \
    '. + [{id: $id, kind: "signin", env: [], connected: $c, account: $a}]' <<<"$out")
  if (( JSON_MODE )); then
    jq -cn --argjson t "$out" '{ok:true, data:{tools:$t}}'
  else
    jq -r '.[] | "\(.id)\t\(if .connected then "connected" else "-" end)\t\(if .kind == "signin" then (.account // "") else (.env | join(" ")) end)"' <<<"$out"
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
  if [[ "$id" == "$TOOL_GOOGLE_ID" ]] && (( ! _TOOL_ENV_GIVEN )); then
    _tool_google_rm
    return 0
  fi
  _tool_resolve "$id" "$_TOOL_ENV_ARG" "$_TOOL_ENV_GIVEN"
  [[ -f "$TOOLS_ENV_FILE" ]] && _tool_rewrite "$_TOOL_VARS" ""
  ok "$id key removed" '{tool: $t, connected: false}' --arg t "$id"
}

# ── Google: a sign-in, not a key (DIVE-5934) ─────────────────────────────────
# Google's tools have no one key to paste: gcloud signs in with OAuth. Every
# agent already shares ONE gcloud login, because /etc/profile.d/5dive-shared-
# configs.sh points CLOUDSDK_CONFIG at /home/claude/.config/gcloud (2770
# claude:claude) for the whole claude group. So the box runs a single
# `gcloud auth login` as user claude, and every agent's gcloud (and Drive through
# --enable-gdrive-access) sees that account from its next command.
#
# The Mini App drives it over the exec tunnel, which must answer in seconds, so it
# is the same non-TTY machine `agent auth start|poll|submit|cancel` uses
# (cmd_auth.sh): a session dir under $AUTH_SESSIONS_DIR with meta.json (type
# "google"), the login in a tmux server on the session's private socket under
# script(1), the same teardown and the same reaper (an abandoned session expires
# after AUTH_SESSION_MAX_AGE_SECS, its dir goes after AUTH_SESSION_TTL_SECS).
#
#   start  -> {session, state: installing|pending_url}
#   poll   -> {session, state, url, account, error}
#             installing -> pending_url -> awaiting_code -> submitted -> ok
#             (error and expired are terminal too)
#   submit -> the code Google shows after sign-in, on STDIN (argv is audited)
#   cancel -> tear the login down
#
# gcloud is not preinstalled: start runs /usr/local/bin/5dive-ensure-cli gcloud
# (the API repo's on-demand installer, apt google-cloud-cli) DETACHED and returns
# `installing`; the poll that sees it finish starts the login. A cancel never
# stops an install half-way: killing apt mid-install leaves dpkg to repair.
TOOL_GOOGLE_ID="google"
TOOL_GCLOUD_CONFIG="${FIVEDIVE_GCLOUD_CONFIG:-/home/claude/.config/gcloud}"
TOOL_ENSURE_CLI="${FIVEDIVE_ENSURE_CLI:-/usr/local/bin/5dive-ensure-cli}"
TOOL_GCLOUD_INSTALL_LOCK="${FIVEDIVE_GCLOUD_INSTALL_LOCK:-/run/5dive-gcloud-install.lock}"
# Free space on /usr's filesystem below which start refuses to install gcloud:
# 1.5 GiB. google-cloud-cli unpacks to roughly 1 GB (it bundles its own Python)
# plus the .deb in apt's cache during the install, and a 4 GB box that fills its
# root filesystem takes every agent down with it.
TOOL_GCLOUD_MIN_FREE_KB="${FIVEDIVE_GCLOUD_MIN_FREE_KB:-1572864}"

# The gcloud binary, or non-zero when it is not installed. apt puts it in
# /usr/bin; the others are the SDK's own tree, the snap and a tarball install.
_tool_gcloud_bin() {
  local b
  if [[ -n "${FIVEDIVE_GCLOUD_BIN:-}" ]]; then
    [[ -x "$FIVEDIVE_GCLOUD_BIN" ]] || return 1
    printf '%s\n' "$FIVEDIVE_GCLOUD_BIN"
    return 0
  fi
  for b in /usr/bin/gcloud /usr/lib/google-cloud-sdk/bin/gcloud /snap/bin/gcloud /usr/local/bin/gcloud; do
    [[ -x "$b" ]] && { printf '%s\n' "$b"; return 0; }
  done
  return 1
}

# The active gcloud configuration's file: its name is in active_config (missing
# means "default"), its properties in configurations/config_<name>.
_tool_google_config_file() {
  local cfg="$TOOL_GCLOUD_CONFIG" active=""
  [[ -r "$cfg/active_config" ]] && { IFS= read -r active <"$cfg/active_config" || true; }
  active="${active//[[:space:]]/}"
  [[ "$active" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || active="default"
  printf '%s\n' "$cfg/configurations/config_${active}"
  return 0
}

# The signed-in account (`account = ` under [core]), empty when none. Reads the
# file gcloud writes, never runs gcloud: `tool ls` must stay cheap and answer on
# a box without it.
_tool_google_account() {
  local f
  f=$(_tool_google_config_file)
  [[ -r "$f" ]] || return 0
  awk '/^[[:space:]]*\[/ { sec = $0; gsub(/[[:space:]]/, "", sec); next }
       sec == "[core]" && /^[[:space:]]*account[[:space:]]*=/ {
         sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit
       }' "$f" 2>/dev/null || true
  return 0
}

# Free KiB on the filesystem holding <path>, empty when df cannot say.
_tool_free_kb() {
  df -Pk -- "$1" 2>/dev/null | awk 'NR == 2 { print $4 }' || true
  return 0
}

_tool_google() {
  local verb="${1:-}"; shift || true
  case "$verb" in
    start)  _tool_google_start "$@" ;;
    poll)   _tool_google_poll "$@" ;;
    submit) _tool_google_submit "$@" ;;
    cancel) _tool_google_cancel "$@" ;;
    *) fail "$E_USAGE" "usage: 5dive tool google start|poll <session>|submit <session> (code on stdin)|cancel <session>" ;;
  esac
  return 0
}

# Session <sid> into _TG_DIR, refusing a malformed id and any session that is not
# a Google sign-in (an `agent auth` session shares the directory). Sets a global
# instead of printing: a `fail` inside $(...) would swallow its JSON error.
_tool_google_dir() {
  local sid="${1:-}"
  [[ "$sid" =~ ^[0-9a-f]{16}$ ]] || fail "$E_VALIDATION" "invalid session id"
  _TG_DIR="${AUTH_SESSIONS_DIR}/${sid}"
  [[ -s "$_TG_DIR/meta.json" && "$(jq -r '.type // ""' "$_TG_DIR/meta.json" 2>/dev/null)" == "$TOOL_GOOGLE_ID" ]] \
    || fail "$E_NOT_FOUND" "no such Google sign-in session: $sid"
  return 0
}

# Apply a jq filter to <dir>'s meta.json and stamp updatedAt. Extra args go to jq.
_tg_meta() {
  local dir="$1" filter="$2"; shift 2
  local meta="${dir}/meta.json"
  jq "$@" --arg ts "$(date -Iseconds)" "${filter} | .updatedAt = \$ts" "$meta" > "${meta}.tmp" \
    && mv -f "${meta}.tmp" "$meta" || return 1
  return 0
}

# Start gcloud's sign-in in <dir>'s tmux, as claude, against the shared config.
# --no-launch-browser prints the accounts.google.com link and then waits for the
# code the browser shows; --enable-gdrive-access adds the Drive scope.
_tool_google_spawn_login() {
  local dir="$1" gc="$2"
  auth_spawn_pty "$dir" "$gc auth login --no-launch-browser --enable-gdrive-access" 200 \
    "CLOUDSDK_CONFIG=$TOOL_GCLOUD_CONFIG" "" || return 1
  _tg_meta "$dir" '.state = "pending_url" | .urlDeadline = $ud' \
    --argjson ud "$(( $(date +%s) + AUTH_URL_TIMEOUT_SECS ))"
  return 0
}

# Expire every Google session still in flight: two logins writing one
# credential store race, and the newest start is the one the owner is looking at.
_tool_google_cancel_live() {
  local meta dir state
  [[ -d "$AUTH_SESSIONS_DIR" ]] || return 0
  for meta in "$AUTH_SESSIONS_DIR"/*/meta.json; do
    [[ -s "$meta" ]] || continue
    dir="${meta%/meta.json}"
    [[ "$(basename "$dir")" =~ ^[0-9a-f]{16}$ ]] || continue
    [[ "$(jq -r '.type // ""' "$meta" 2>/dev/null)" == "$TOOL_GOOGLE_ID" ]] || continue
    state=$(jq -r '.state // ""' "$meta" 2>/dev/null)
    case "$state" in ok|error|expired) continue ;; esac
    auth_teardown_session "$dir"
    _tg_meta "$dir" '.state = "expired" | .error = "replaced by a newer Google sign-in"' || true
  done
  return 0
}

_tool_google_start() {
  require_root tool google start
  (( $# == 0 )) || fail "$E_USAGE" "usage: 5dive tool google start"
  local gc="" free_kb
  gc=$(_tool_gcloud_bin) || gc=""
  if [[ -z "$gc" ]]; then
    [[ -x "$TOOL_ENSURE_CLI" ]] \
      || fail "$E_NOT_INSTALLED" "Google sign-in needs the Google Cloud CLI, and this server has no installer for it ($TOOL_ENSURE_CLI is missing). Update the server, then try again"
    free_kb=$(_tool_free_kb /usr)
    if [[ "$free_kb" =~ ^[0-9]+$ ]] && (( free_kb < TOOL_GCLOUD_MIN_FREE_KB )); then
      fail "$E_VALIDATION" "Google sign-in needs the Google Cloud CLI (about 1 GB), and this server has $(( free_kb / 1024 )) MB free; it needs $(( TOOL_GCLOUD_MIN_FREE_KB / 1024 )) MB. Free some space, then try again"
    fi
  fi

  require_auth_session_root
  auth_reap_quiet
  _tool_google_cancel_live

  local sid dir baseline=0 state
  sid=$(gen_session_id)
  dir="${AUTH_SESSIONS_DIR}/${sid}"
  mkdir -p "$dir"
  chown claude:claude "$dir"
  chmod 2750 "$dir"
  : > "${dir}/login.log"
  chown claude:claude "${dir}/login.log"
  chmod 640 "${dir}/login.log"
  [[ -f "$TOOL_GCLOUD_CONFIG/credentials.db" ]] \
    && baseline=$(stat -c %Y "$TOOL_GCLOUD_CONFIG/credentials.db" 2>/dev/null || echo 0)
  state="pending_url"
  [[ -z "$gc" ]] && state="installing"
  jq -n --arg sid "$sid" --arg t "$TOOL_GOOGLE_ID" --arg s "$state" --arg ts "$(date -Iseconds)" \
        --argjson ab "$baseline" '{
    sessionId: $sid, type: $t, profile: "", state: $s,
    url: null, code: null, error: null, account: null,
    authBaselineMtime: $ab, urlDeadline: 0, panePid: null, installPid: null,
    createdAt: $ts, updatedAt: $ts
  }' > "${dir}/meta.json"
  chmod 640 "${dir}/meta.json"
  chown claude:claude "${dir}/meta.json"

  if [[ -z "$gc" ]]; then
    # Detached, so the exec tunnel returns now; the lock serialises two starts.
    # install.rc appears (atomically) only once the installer has exited.
    setsid bash -c '
      flock -w 1200 "$1" "$2" gcloud >"$3/install.log" 2>&1
      echo $? >"$3/install.rc.tmp" && mv -f "$3/install.rc.tmp" "$3/install.rc"
    ' _ "$TOOL_GCLOUD_INSTALL_LOCK" "$TOOL_ENSURE_CLI" "$dir" </dev/null >/dev/null 2>&1 &
    _tg_meta "$dir" '.installPid = $p' --argjson p "$!"
    step "Installing the Google Cloud CLI for Google sign-in (session $sid)"
  else
    _tool_google_spawn_login "$dir" "$gc" || fail "$E_GENERIC" "failed to start the Google sign-in"
    step "Started Google sign-in session $sid"
  fi

  ok "Google sign-in started: 5dive tool google poll $sid" \
     '{session: $s, state: $st}' --arg s "$sid" --arg st "$state"
}

# installing -> pending_url once 5dive-ensure-cli has exited 0 and gcloud is there.
_tool_google_poll_install() {
  local dir="$1" rc pid gc last=""
  if [[ ! -s "${dir}/install.rc" ]]; then
    pid=$(jq -r '.installPid // 0' "${dir}/meta.json" 2>/dev/null)
    [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )) && kill -0 "$pid" 2>/dev/null && return 0
    # Gone without writing its exit code: killed, or the box rebooted.
    _tg_meta "$dir" '.state = "error" | .error = "the Google Cloud CLI install stopped before it finished; start again"'
    return 0
  fi
  rc=$(tr -dc '0-9' <"${dir}/install.rc")
  gc=$(_tool_gcloud_bin) || gc=""
  if [[ "$rc" == 0 && -n "$gc" ]]; then
    _tool_google_spawn_login "$dir" "$gc" && return 0
    _tg_meta "$dir" '.state = "error" | .error = "failed to start the Google sign-in"'
    return 0
  fi
  [[ -s "${dir}/install.log" ]] && last=$(grep -v '^[[:space:]]*$' "${dir}/install.log" | tail -1 | cut -c1-300) || last=""
  _tg_meta "$dir" '.state = "error" | .error = $e' \
    --arg e "the Google Cloud CLI did not install (exit ${rc:-?})${last:+: $last}"
  return 0
}

_tool_google_poll() {
  require_root tool google poll
  local sid="${1:-}"
  [[ -n "$sid" && $# -eq 1 ]] || fail "$E_USAGE" "usage: 5dive tool google poll <session>"
  _tool_google_dir "$sid"
  local dir="$_TG_DIR"
  local meta="${dir}/meta.json" sock="${dir}/tmux.sock" session="auth-${sid}"
  local state alive=1 text="" url="" account="" err="" deadline baseline current=0 cfg_account
  local re_url='(https://accounts\.google\.com/o/oauth2/[^[:space:]]+)'
  local re_ok='You are now logged in as \[([^]]+)\]'
  local re_err="(ERROR: [^"$'\n'"]*)"

  state=$(jq -r '.state' "$meta")
  if [[ "$state" == installing ]]; then
    _tool_google_poll_install "$dir"
    state=$(jq -r '.state' "$meta")
  fi
  case "$state" in
    pending_url|awaiting_code|submitted)
      sudo -u claude tmux -S "$sock" has-session -t "$session" 2>/dev/null || alive=0
      # The PTY log without colour escapes or carriage returns.
      [[ -s "${dir}/login.log" ]] \
        && text=$(LC_ALL=C sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\r//g' "${dir}/login.log" 2>/dev/null || true)
      [[ "$text" =~ $re_ok ]] && account="${BASH_REMATCH[1]}"
      [[ "$text" =~ $re_err ]] && err="${BASH_REMATCH[1]}"
      if [[ -n "$account" ]]; then
        # gcloud prints this after it stored the credential and set the account,
        # then exits on its own; tear down now only once the account is on disk.
        cfg_account=$(_tool_google_account)
        (( alive )) && [[ "$cfg_account" == "$account" ]] && auth_teardown_session "$dir"
        _tg_meta "$dir" '.state = "ok" | .account = $a | .error = null' --arg a "$account"
      elif [[ "$state" == pending_url ]]; then
        [[ "$text" =~ $re_url ]] && url="${BASH_REMATCH[1]}"
        deadline=$(jq -r '.urlDeadline // 0' "$meta")
        if [[ -n "$url" ]]; then
          _tg_meta "$dir" '.state = "awaiting_code" | .url = $u' --arg u "$url"
        elif (( ! alive )); then
          _tg_meta "$dir" '.state = "error" | .error = $e' \
            --arg e "gcloud stopped before it printed a sign-in link${err:+: $err}"
        elif [[ "$deadline" =~ ^[0-9]+$ ]] && (( deadline > 0 && $(date +%s) > deadline )); then
          auth_teardown_session "$dir"
          _tg_meta "$dir" '.state = "error" | .error = $e' \
            --arg e "gcloud printed no sign-in link within ${AUTH_URL_TIMEOUT_SECS}s"
        fi
      elif (( ! alive )); then
        # The login is gone without its success line (a log cut short): trust the
        # files only when this session's sign-in rewrote the credential store.
        cfg_account=$(_tool_google_account)
        baseline=$(jq -r '.authBaselineMtime // 0' "$meta")
        [[ -f "$TOOL_GCLOUD_CONFIG/credentials.db" ]] \
          && current=$(stat -c %Y "$TOOL_GCLOUD_CONFIG/credentials.db" 2>/dev/null || echo 0)
        if [[ -n "$cfg_account" && "$current" =~ ^[0-9]+$ && "$baseline" =~ ^[0-9]+$ ]] && (( current > baseline )); then
          _tg_meta "$dir" '.state = "ok" | .account = $a | .error = null' --arg a "$cfg_account"
        else
          _tg_meta "$dir" '.state = "error" | .error = $e' \
            --arg e "${err:-the sign-in ended without signing in (a wrong or expired code?)}; start again"
        fi
      fi
      ;;
  esac

  if (( JSON_MODE )); then
    jq -c '{ok: true, data: {session: .sessionId, state, url, account, error}}' "$meta"
  else
    jq -r '"session: \(.sessionId)\nstate:   \(.state)\nurl:     \(.url // "-")\naccount: \(.account // "-")\nerror:   \(.error // "-")"' "$meta"
  fi
}

# The code Google shows after sign-in: one line of printable ASCII, no spaces,
# no quotes or backslash (real codes are like 4/0AVG7f...-_ only).
_tool_google_code_ok() {
  local LC_ALL=C
  [[ "$1" =~ ^[!-~]{4,512}$ && "$1" != *[\'\"\`\\]* ]]
}

_tool_google_submit() {
  require_root tool google submit
  local sid="" a argv_code="the code goes on stdin, never in the command line (the command line is logged)"
  for a in "$@"; do
    case "$a" in
      --code|--code=*) fail "$E_USAGE" "$argv_code" ;;
      -*) fail "$E_USAGE" "unknown flag: $a" ;;
      *) [[ -z "$sid" ]] && sid="$a" || fail "$E_USAGE" "$argv_code" ;;
    esac
  done
  [[ -n "$sid" ]] || fail "$E_USAGE" "usage: printf '%s\\n' <code> | 5dive tool google submit <session>"
  _tool_google_dir "$sid"
  local dir="$_TG_DIR"
  local meta="${dir}/meta.json" sock="${dir}/tmux.sock" session="auth-${sid}" state code="" extra=""
  [[ -t 0 ]] && fail "$E_USAGE" "$argv_code: printf '%s\\n' <code> | 5dive tool google submit $sid"
  IFS= read -r code || true
  code="${code%$'\r'}"
  extra=$(head -c 4096 || true)
  [[ -z "${extra//[[:space:]]/}" ]] || fail "$E_VALIDATION" "the code is one line; nothing was sent"
  _tool_google_code_ok "$code" \
    || fail "$E_VALIDATION" "the code must be one line of printable characters with no spaces or quotes; nothing was sent"

  state=$(jq -r '.state' "$meta")
  case "$state" in
    awaiting_code|submitted) ;;
    installing|pending_url) fail "$E_VALIDATION" "the sign-in is not waiting for a code yet; poll until it shows a url" ;;
    *) fail "$E_VALIDATION" "the sign-in already ended ($state); start again" ;;
  esac
  sudo -u claude tmux -S "$sock" has-session -t "$session" 2>/dev/null \
    || fail "$E_NOT_RUNNING" "the sign-in is no longer running; start again"
  sudo -u claude tmux -S "$sock" send-keys -t "$session" C-u 2>/dev/null || true
  sudo -u claude tmux -S "$sock" send-keys -t "$session" -l -- "$code"
  sudo -u claude tmux -S "$sock" send-keys -t "$session" Enter
  _tg_meta "$dir" '.state = "submitted"'
  ok "code sent; poll for the result" '{session: $s, state: "submitted"}' --arg s "$sid"
}

_tool_google_cancel() {
  require_root tool google cancel
  local sid="${1:-}"
  [[ -n "$sid" && $# -eq 1 ]] || fail "$E_USAGE" "usage: 5dive tool google cancel <session>"
  _tool_google_dir "$sid"
  local dir="$_TG_DIR" state
  auth_teardown_session "$dir"
  _tg_meta "$dir" 'if .state == "ok" then . else .state = "expired" end'
  state=$(jq -r '.state' "${dir}/meta.json")
  ok "Google sign-in cancelled" '{session: $s, state: $st}' --arg s "$sid" --arg st "$state"
}

# `tool rm google`: sign the box out. Revokes every gcloud credential when gcloud
# is installed (best effort: offline, the local copies still go), then makes sure
# the account line is gone so ls reads disconnected. Never deletes the config dir:
# it holds the agents' other gcloud settings.
_tool_google_rm() {
  local gc f
  _tool_google_cancel_live
  gc=$(_tool_gcloud_bin) || gc=""
  if [[ -n "$gc" ]]; then
    sudo -u claude -H env CLOUDSDK_CONFIG="$TOOL_GCLOUD_CONFIG" timeout 60 "$gc" auth revoke --all --quiet \
      >/dev/null 2>&1 || true
  fi
  if [[ -n "$(_tool_google_account)" ]]; then
    f=$(_tool_google_config_file)
    # As claude, so the file keeps the owner every agent's gcloud writes as.
    sudo -u claude sed -i -E '/^[[:space:]]*account[[:space:]]*=/d' "$f" 2>/dev/null \
      || { sed -i -E '/^[[:space:]]*account[[:space:]]*=/d' "$f" && chown claude:claude "$f" 2>/dev/null; } || true
  fi
  [[ -z "$(_tool_google_account)" ]] || fail "$E_GENERIC" "could not sign Google out: the account is still set in $(_tool_google_config_file)"
  ok "Google signed out" '{tool: $t, connected: false}' --arg t "$TOOL_GOOGLE_ID"
}
