# cmd_secret_drop — DIVE-5319: the one-time secret drop link, served by the BOX.
#
# An owner answers a secret gate by opening a link to THIS box, pasting the value
# and tapping once. The value goes from the owner's browser to this box only: it
# never touches 5dive's API, its DB, its logs or Sentry, and never sits in a chat.
# (lodar 2026-10-01: "the secret should never touch our api - thats the main
# reason of the task".) It lives here, in the open-source CLI, so a self-hosted
# box gets it too; the hosted layer only routes the name.
#
#   5dive secret link <DIVE-N> [--ttl=<min>] [--json]   root: mint a link for an open gate
#   5dive secret serve [--listen=<host:port>]           root: the page (started on demand)
#
# Where it is served: https://secrets.<FIVE_DOMAIN>/<token>. NOT the root domain:
# a hosted box's root record is Cloudflare-PROXIED, so Cloudflare would end TLS
# and see the POST. The *.<FIVE_DOMAIN> wildcard is DNS-only, so this name goes
# straight to the box's Caddy and its own certificate. One fixed name, one cert:
# the secrecy is the token in the path, not the hostname. A self-hosted box sets
# SECRET_DROP_BASE_URL in /etc/5dive/secret-drop.env (its own tunnel or LAN name,
# https only); with neither, the terminal is the path: `sudo 5dive secret write
# <KEY> --connector=<c> --task=<DIVE-N>` asks for the value with hidden input.
#
# Guards (each one is graded in tests/secret_drop_link_unit.sh):
#   - 32 random bytes per link. Only the SHA-256 is stored, in a root-only dir, so
#     reading the store cannot replay a link, and a lookup by hash leaks nothing
#     about the token through timing.
#   - bound to one gate: the task, its KEY and its connector, copied at mint time.
#     A redeem re-checks that the gate is still open and still names the same pair.
#   - single use: a successful write burns every link for that gate. A rejected
#     value (empty) burns nothing, so a bad paste can be retried.
#   - long and multi-line values (PEM keys, JSON, a block of labelled values) are
#     taken whole in a textarea (DIVE-5384). `secret write` stores one of several
#     lines in its own file and names it from the .env, so no line of the value
#     ever becomes a line of the .env.
#   - expires after --ttl minutes (default 30); an expired link is deleted on sight.
#   - minting is ROOT-only. A link is the right to write one key into a root-owned
#     connector file, so a standard agent seat must never hold one (it has no sudo
#     for this verb, and the raw token is stored nowhere it can read).
#   - the page never echoes the value, and logs no path (the path is the token).
#   - rate limit on failed lookups per client and in total (the server).

SECRET_DROP_DIR="${STATE_DIR}/secret-drop"
SECRET_DROP_CONF="/etc/5dive/secret-drop.env"
SECRET_DROP_PROVISIONING="/etc/5dive/provisioning.env"
SECRET_DROP_CADDYFILE="/etc/caddy/Caddyfile"
SECRET_DROP_PORT=3127
SECRET_DROP_TTL_MIN=30
SECRET_DROP_LOCK="/run/5dive-secret-drop.lock"
# DIVE-6727: a refused paste tells the agent at most once per link in this many
# seconds (an owner retries a few times a minute).
SECRET_DROP_REFUSED_TELL_S=600
# DIVE-5372: how long `secret link` waits for its page to answer over valid TLS
# before it hands the URL out. Under the 30s the dashboard's exec call allows
# (shelld's default), so a slow first certificate degrades to ready:false
# instead of a dead request. ACME on a fresh name took ~4s on chill-gorge.
SECRET_DROP_WAIT_S="${SECRET_DROP_WAIT_S:-20}"
SECRET_DROP_POLL_S="${SECRET_DROP_POLL_S:-1}"
SECRET_DROP_PROBE_ADDR="${SECRET_DROP_PROBE_ADDR:-127.0.0.1}"
# DIVE-5806 (H2): where the kernel lists listening sockets, and how long a freshly
# started page gets to bind before `secret link` looks at who holds the port.
SECRET_DROP_PROC_NET="${SECRET_DROP_PROC_NET:-/proc/net}"
SECRET_DROP_BIND_S="${SECRET_DROP_BIND_S:-5}"

# The https base a link starts with, or nothing when this box has no name an
# owner's browser can reach (the terminal path then).
_secret_drop_base_url() {
  local base="" domain=""
  if [[ -r "$SECRET_DROP_CONF" ]]; then
    base=$(sed -n 's/^SECRET_DROP_BASE_URL=//p' "$SECRET_DROP_CONF" | tail -1)
    base="${base%\"}"; base="${base#\"}"; base="${base%/}"
  fi
  if [[ -n "$base" ]]; then
    # https only: over plain http the value would cross the network in clear.
    [[ "$base" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$ ]] || return 1
    printf '%s' "$base"; return 0
  fi
  if domain=$(_secret_drop_domain); then
    printf 'https://secrets.%s' "$domain"; return 0
  fi
  # DIVE-7113: a self-hosted box's own https front (`secret https`).
  local own; own=$(_secret_https_host) || return 1
  printf 'https://%s' "$own"
}

# FIVE_DOMAIN from provisioning, only in a shape safe to put in a Caddyfile.
_secret_drop_domain() {
  local d=""
  [[ -r "$SECRET_DROP_PROVISIONING" ]] && d=$(sed -n 's/^FIVE_DOMAIN=//p' "$SECRET_DROP_PROVISIONING" | tail -1)
  d="${d%\"}"; d="${d#\"}"
  [[ "$d" =~ ^[a-z0-9_]([a-z0-9_.-]*[a-z0-9])?$ && "$d" == *.* ]] || return 1
  printf '%s' "$d"
}

_secret_drop_token() {
  head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'
}

_secret_drop_hash() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

# Delete links whose time is up. Called on every mint and redeem.
_secret_drop_gc() {
  local now f exp
  now=$(date +%s)
  for f in "$SECRET_DROP_DIR"/*; do
    [[ -f "$f" ]] || continue
    exp=$(sed -n 's/^expires=//p' "$f")
    [[ "$exp" =~ ^[0-9]+$ ]] && (( exp > now )) || rm -f "$f"
  done
}

# DIVE-6205: the latest expiry among this task's live links, or nothing. The
# gate's alert mints one, and an agent that cannot see that mints a second: two
# live links reach the owner, and using either burns both.
_secret_drop_live_for() {
  local ident="$1" now f exp best=""
  now=$(date +%s)
  for f in "$SECRET_DROP_DIR"/*; do
    [[ -f "$f" ]] || continue
    [[ "$(sed -n 's/^task=//p' "$f")" == "$ident" ]] || continue
    exp=$(sed -n 's/^expires=//p' "$f")
    [[ "$exp" =~ ^[0-9]+$ ]] && (( exp > now )) || continue
    if [[ -z "$best" ]] || (( exp > best )); then best="$exp"; fi
  done
  [[ -n "$best" ]] || return 1
  printf '%s' "$best"
}

# Who is asking for the link: an agent seat (directly or through sudo), or
# nothing for a person or the box itself (the app's card, a root login). Its own
# function so a harness can say who is calling.
_secret_link_agent_caller() { _gate_authenticated_actor 2>/dev/null; }

# Echo "<ident>\x1f<key>\x1f<connector>\x1f<expires>" for one stored link.
_secret_drop_read() {
  local f="$1"
  printf '%s\x1f%s\x1f%s\x1f%s' \
    "$(sed -n 's/^task=//p' "$f")" "$(sed -n 's/^key=//p' "$f")" \
    "$(sed -n 's/^connector=//p' "$f")" "$(sed -n 's/^expires=//p' "$f")"
}

# The gate still open, still a secret gate, still naming this pair? Echoes the
# row id when it is, nothing otherwise.
_secret_drop_gate_open() {
  local ident="$1" key="$2" connector="$3"
  [[ "$ident" =~ ^[A-Za-z]+-[0-9]+$ ]] || return 1
  db "SELECT id FROM tasks WHERE ident=$(sqlq "${ident^^}")
        AND need_type='secret' AND need_answered_at IS NULL
        AND secret_key=$(sqlq "$key") AND connector=$(sqlq "$connector") LIMIT 1;" 2>/dev/null
}

_secret_drop_burn_task() {
  local ident="$1" f
  for f in "$SECRET_DROP_DIR"/*; do
    [[ -f "$f" ]] || continue
    [[ "$(sed -n 's/^task=//p' "$f")" == "$ident" ]] && rm -f "$f"
  done
  return 0
}

# ---- secret link -----------------------------------------------------------

_secret_link() {
  local ref="" ttl="$SECRET_DROP_TTL_MIN" start=1 again=0 save="" pair=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ttl=*)     ttl="${1#*=}" ;;
      --save=*)    save="${1#*=}" ;;   # DIVE-6844: a saved value, no task
      --pair)      pair=1 ;;   # DIVE-6973: login + password (+ 2FA key) in one page
      --again)     again=1 ;;   # DIVE-6205: mint although a link for the gate is live
      --no-start)  start=0 ;;   # tests / a box whose page is supervised elsewhere
      --*)         fail "$E_USAGE" "unknown flag: $1" ;;
      *)           [[ -z "$ref" ]] && ref="$1" || fail "$E_USAGE" "unexpected argument: $1" ;;
    esac
    shift
  done
  require_root secret link
  [[ -n "$ref" || -n "$save" ]] || fail "$E_USAGE" "usage: 5dive secret link <DIVE-N> [--ttl=<minutes>] [--again] [--json] | --save=<name>"
  [[ -z "$ref" || -z "$save" ]] || fail "$E_USAGE" "a link is for a task's gate OR a saved value (--save), not both"
  (( ! pair )) || [[ -n "$save" ]] || fail "$E_USAGE" "--pair is for a saved login: secret link --save=<name> --pair"
  [[ "$ttl" =~ ^[0-9]+$ ]] && (( ttl >= 1 && ttl <= 60 )) || fail "$E_VALIDATION" "--ttl must be 1-60 minutes"
  local ident="" key="" connector=""
  if [[ -n "$save" ]]; then
    _saved_name_ok "$save" \
      || fail "$E_VALIDATION" "'$save' is not a usable name: lowercase letters, digits and dashes, starting with a letter, up to 40 (linkedin-password)"
    key=$(_saved_key "$save"); connector="$SECRET_SAVED_CONNECTOR"
  else
    _secret_link_gate "$ref" "$again"
  fi
  _secret_link_mint "$ttl" "$start" "$ident" "$key" "$connector" "$save" "$pair"
}

# The task's open secret gate, checked. Sets ident, key and connector in the
# caller (_secret_link) through bash's dynamic scope.
_secret_link_gate() {
  local ref="$1" again="$2"
  resolve_task_id "$ref"; local id="$RESOLVED_TASK_ID"; ident="$RESOLVED_TASK_IDENT"
  local row nt answered
  row=$(db "SELECT COALESCE(need_type,'')||x'1f'||COALESCE(need_answered_at,'')||x'1f'||COALESCE(secret_key,'')||x'1f'||COALESCE(connector,'') FROM tasks WHERE id=${id};")
  IFS=$'\x1f' read -r nt answered key connector <<<"$row"
  [[ "$nt" == "secret" ]] || fail "$E_CONFLICT" "$ident has no secret gate open"
  [[ -z "$answered" ]]    || fail "$E_CONFLICT" "$ident secret gate is already answered"
  [[ -n "$key" && -n "$connector" ]] \
    || fail "$E_CONFLICT" "$ident names no place on this box for the value (it was filed --out-of-band), so a link has nowhere to write it"
  _valid_env_keys "$key" && _valid_connector "$connector" \
    || fail "$E_VALIDATION" "$ident drop target is malformed (${key} -> ${connector})"

  # DIVE-6205: an AGENT asking while a link for this gate is live gets told so,
  # not a second link. The owner already has one (the gate's alert carries it);
  # a second one in chat is a link that dies the moment the first is used. The
  # app's card asks as the box, not as an agent, and keeps minting its own.
  local _live
  if (( ! again )) && [[ -n "$(_secret_link_agent_caller)" ]] && _live=$(_secret_drop_live_for "$ident"); then
    fail "$E_VALIDATION" "a one-time link for $ident is already live (sent with the gate's alert), until $(date -u -d "@$_live" '+%H:%M' 2>/dev/null || date -u -r "$_live" '+%H:%M') UTC. Do not send another: the owner has it, and using either link burns both. If the owner says theirs is lost, mint a new one with: sudo 5dive secret link ${ident} --again"
  fi
  return 0
}

# Mint and serve one link: for a gate (ident set) or a saved name (save set).
_secret_link_mint() {
  local ttl="$1" start="$2" ident="$3" key="$4" connector="$5" save="${6:-}" pair="${7:-0}"
  local base terminal="sudo 5dive secret write ${key} --connector=${connector} --task=${ident}"
  [[ -n "$save" ]] && terminal="sudo 5dive secret write ${key} --connector=${connector}"
  # DIVE-7113: a self-hosted box with no https name makes one itself, the first
  # time a link is asked for (an IP certificate, then sslip.io). Only when both
  # fail does the owner get a step: a domain, or the terminal.
  if ! base=$(_secret_drop_base_url); then
    (( start )) && _secret_https_auto && base=$(_secret_drop_base_url) \
      || fail "$E_NOT_INSTALLED" "$(_secret_https_no_name_msg "$terminal")"
  fi

  ( umask 077; mkdir -p "$SECRET_DROP_DIR" ) || fail "$E_GENERIC" "cannot create $SECRET_DROP_DIR"
  chmod 700 "$SECRET_DROP_DIR" 2>/dev/null || true
  _secret_drop_gc

  local token hash exp
  token=$(_secret_drop_token)
  [[ ${#token} -ge 43 ]] || fail "$E_GENERIC" "could not read 32 random bytes"
  hash=$(_secret_drop_hash "$token")
  exp=$(( $(date +%s) + ttl * 60 ))
  ( umask 077; printf 'task=%s\nkey=%s\nconnector=%s\nexpires=%s\n' "$ident" "$key" "$connector" "$exp" > "$SECRET_DROP_DIR/$hash"
    [[ -z "$save" ]] || printf 'save=%s\n' "$save" >> "$SECRET_DROP_DIR/$hash"
    (( ! pair )) || printf 'pair=1\n' >> "$SECRET_DROP_DIR/$hash" ) \
    || fail "$E_GENERIC" "cannot store the link"

  # DIVE-5372: the first link on a box appends the secrets.<domain> route and
  # DEFERS the reload, and Caddy only then asks ACME for the certificate. A URL
  # handed out before that ends in ERR_SSL_PROTOCOL_ERROR on the owner's first
  # tap (lodar on chill-gorge, 2026-10-02 05:34Z). So wait, bounded, until the
  # page answers over valid TLS; past the bound, still return the link, marked
  # ready:false, so the caller can say "getting your secure page ready".
  # "null" = not checked: --no-start, or a SECRET_DROP_BASE_URL (the owner's own
  # tunnel, which this box may not be able to reach by its public name).
  local ready=null squat_uid="" srv_rc=0
  if (( start )); then
    _secret_drop_ensure_route || true
    squat_uid=$(_secret_drop_ensure_server) || srv_rc=$?
  else
    # --no-start still refuses a squatted port: the page it trusts to be
    # supervised elsewhere must at least be root's.
    squat_uid=$(_secret_drop_port_holder) || srv_rc=$?
    (( srv_rc == 2 )) || srv_rc=0
  fi
  if (( srv_rc == 2 )); then
    rm -f "$SECRET_DROP_DIR/$hash"
    fail "$E_CONFLICT" "$(_secret_drop_squat_msg "$squat_uid")"
  fi
  if (( start )); then
    local domain own
    if ! _secret_drop_has_base_url && domain=$(_secret_drop_domain); then
      _secret_drop_wait_ready "$domain" "$SECRET_DROP_WAIT_S" && ready=true || ready=false
    elif ! _secret_drop_has_base_url && own=$(_secret_https_host); then
      _secret_drop_wait_ready "$own" "$SECRET_DROP_WAIT_S" own && ready=true || ready=false
    fi
  fi

  local url="${base}/${token}" exp_iso note=""
  exp_iso=$(date -u -d "@$exp" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$exp" '+%Y-%m-%dT%H:%M:%SZ')
  [[ "$ready" == false ]] && note="
not ready yet: the secure page is still getting its certificate. If the link does not open, wait a minute and open it again (it stays valid)."
  local lands="the value lands as ${key} in ${connector}.env and clears ${ident}"
  [[ "$key" == *,* ]] && lands="the page has one box for each of $(_secret_keys_words "$key"); they land in ${connector}.env and clear ${ident}"
  [[ -n "$save" ]] && lands="the value is saved as ${save}, for agents to type into a site"
  (( pair )) && lands="the login, password and optional 2FA key are saved as ${save}, for agents to sign in with"
  # DIVE-7128: the url reaches jq through the environment, not argv, which any
  # seat can list while the root side mints a standard seat's link.
  FIVE_DROP_URL="$url" ok "$url
single use, expires ${exp_iso} (${ttl} min); ${lands}${note}" \
     '{url: $ENV.FIVE_DROP_URL, expires_at: $e, ttl_minutes: ($t|tonumber), task: $i, key: $k, connector: $c, ready: ($r|fromjson)}
      + (if $s == "" then {} else {save: $s, pair: ($p == "1")} end)' \
     --arg e "$exp_iso" --arg t "$ttl" --arg i "$ident" --arg k "$key" --arg c "$connector" --arg r "$ready" \
     --arg s "$save" --arg p "$pair"
}

# DIVE-6844: the saved name a link writes, or empty for a gate's link.
_secret_drop_save_of() { sed -n 's/^save=//p' "$1" | head -n 1; }
# DIVE-6973: 1 when the link asks for a login pair, else 0.
_secret_drop_pair_of() { [[ "$(sed -n 's/^pair=//p' "$1" | head -n 1)" == 1 ]] && printf 1 || printf 0; }

# Burn every live link for one saved name: a value saved through one makes the
# others stale, as a gate's links are.
_secret_drop_burn_save() {
  local name="$1" f
  for f in "$SECRET_DROP_DIR"/*; do
    [[ -f "$f" ]] || continue
    [[ "$(_secret_drop_save_of "$f")" == "$name" ]] && rm -f "$f"
  done
  return 0
}

# `secret _prewarm` (root; install.sh, every install and --upgrade): route
# secrets.<domain> and let Caddy fetch its certificate long before any gate
# needs a link, so even a box's FIRST link opens on the first tap (DIVE-5372).
# Only the route: the page still starts on demand. Best-effort, quiet, rc 0
# when there is nothing to do (no Caddy, no FIVE_DOMAIN, an owner's base URL).
_secret_drop_prewarm() {
  require_root secret _prewarm
  _secret_drop_ensure_route || return 1
  return 0
}

# ---- the page's two internal calls (root; the server runs them) -------------

# _peek --hash=<h>: what a live link is for. No burn — opening the page twice is fine.
_secret_drop_peek() {
  local hash=""
  case "${1:-}" in --hash=*) hash="${1#*=}" ;; esac
  require_root secret _peek
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || fail "$E_NOT_FOUND" "no such link"
  local f="$SECRET_DROP_DIR/$hash"
  [[ -f "$f" ]] || fail "$E_NOT_FOUND" "no such link"
  local ident key connector exp
  IFS=$'\x1f' read -r ident key connector exp <<<"$(_secret_drop_read "$f")"
  if ! [[ "$exp" =~ ^[0-9]+$ ]] || (( exp <= $(date +%s) )); then
    rm -f "$f"; fail "$E_TIMEOUT" "link expired"
  fi
  local save; save=$(_secret_drop_save_of "$f")
  if [[ -n "$save" ]]; then
    local pair; pair=$(_secret_drop_pair_of "$f")
    ok "save $save" '{task: "", save: $s, key: $k, connector: $c, ask: "", agent: "", expires: ($x|tonumber), rule: $r, pair: ($p == "1")}' \
       --arg s "$save" --arg k "$key" --arg c "$connector" --arg x "$exp" --arg r "$(_secret_drop_rule "$connector" "$pair")" --arg p "$pair"
    return 0
  fi
  local id; id=$(_secret_drop_gate_open "$ident" "$key" "$connector")
  if [[ -z "$id" ]]; then
    # DIVE-7184: only THIS link. Burning the task's links here also killed a live
    # link minted for the gate that replaced this one (link 4 of 4, 30 s after
    # the owner opened link 1).
    rm -f "$f"; fail "$E_CONFLICT" "gate no longer open"
  fi
  local ask agent
  ask=$(db "SELECT COALESCE(ask,'') FROM tasks WHERE id=${id};")
  # The seat that filed the gate is the one asking; the assignee can differ (a
  # box's routing may move the row), which made the page name the wrong agent.
  agent=$(db "SELECT COALESCE(NULLIF(gate_filed_by,''),assignee,'') FROM tasks WHERE id=${id};")
  local multi=0; [[ "$key" == *,* ]] && multi=1
  ok "$ident $key" '{task: $i, key: $k, keys: ($k | split(",")), connector: $c, ask: $a, agent: $g, expires: ($x|tonumber), rule: $r}' \
     --arg i "$ident" --arg k "$key" --arg c "$connector" --arg a "$ask" --arg g "$agent" --arg x "$exp" \
     --arg r "$(_secret_drop_rule "$connector" 0 "$multi")"
}

# DIVE-6727: the rule a refused paste broke, in the owner's words, by the gate's
# connector class. Static text: it names the rule and never carries a byte of the
# value. The page shows it on a refusal (from _peek), and the agent is told it.
_secret_drop_rule() { # <connector> [<pair: 1>] [<several keys: 1>]
  [[ "$1" == saved && "${2:-0}" == 1 ]] \
    && { printf '%s' "The login and the password must each be one line. A 2FA setup key is the code of letters A-Z and digits 2-7 the site shows when you add an authenticator app."; return; }
  # DIVE-7184: one box per key, each one line; all are checked before any is saved.
  if [[ "${3:-0}" == 1 ]]; then
    case "$1" in
      tools) printf '%s' "Every box must be filled, each with one line: no spaces and no ' mark, only plain keyboard letters, digits and symbols. Nothing is saved until all of them fit." ;;
      project-*) printf '%s' 'Every box must be filled, each with only letters, digits and these marks: _ . / : + = @ , ~ - (no spaces, quotes, $, # or line breaks). Nothing is saved until all of them fit.' ;;
      *) printf '%s' "Every box must be filled, each with one line. Nothing is saved until all of them are." ;;
    esac
    return
  fi
  case "$1" in
    tools) printf '%s' "It must be one line, with no spaces and no ' mark: only plain keyboard letters, digits and symbols, at most 1024 of them." ;;
    saved) printf '%s' "It must be one line: it is typed into one field of a page." ;;
    project-*) printf '%s' 'It may hold only letters, digits and these marks: _ . / : + = @ , ~ - (no spaces, quotes, $, # or line breaks).' ;;
    *) printf '%s' 'This one takes any value, line breaks included, so the value was not the problem. Try again in a minute.' ;;
  esac
}

# ---- DIVE-5772: the drop closes its own gate, and says so when it cannot ----
#
# lodar, 2026-10-07: "i already click submit why i need to go back to chat and
# press provided". The clear used to be one `task answer ... >/dev/null 2>&1 ||
# true`: a refusal or a busy store was thrown away, the page said "did not
# update", and the owner was told to go and tell the agent himself.

# One line to the journal (`journalctl -t 5dive-secret-drop`). Never the value:
# nothing here ever holds it.
_secret_drop_log() {
  local msg="5dive secret drop: $*"
  printf '%s\n' "$msg" >&2
  command -v logger >/dev/null 2>&1 && logger -t 5dive-secret-drop -- "$msg" 2>/dev/null || true
}

# Where the value now is, in words an agent can act on.
_secret_drop_where() {
  case "$2" in
    tools) printf 'every agent'"'"'s environment, as $%s' "$1" ;;
    project-*) printf 'the %s app'"'"'s env file' "${2#project-}" ;;
    *) printf '%s/%s.env' "${CONNECTORS_DIR:-/etc/5dive/connectors}" "$2" ;;
  esac
}

# Clear the gate with the redeemed link as evidence. A busy store is retried
# (the store is shared by every seat and backed up while it runs); a refusal is
# not, because it would refuse again. Every attempt that does not clear is
# logged with what `task answer` said. 0 = the row reads answered.
_secret_drop_clear() { # <ident> <hash> <id>
  local ident="$1" hash="$2" id="$3" five out rc n
  five=$(five_self_bundle 2>/dev/null) || five=5dive
  for n in 1 2 3 4; do
    rc=0
    out=$("$five" task answer "$ident" --human --from=drop --drop-link="$hash" 2>&1 >/dev/null) || rc=$?
    [[ -n "$id" && -n "$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${id};" 2>/dev/null)" ]] && return 0
    _secret_drop_log "task answer $ident (attempt $n of 4) did not clear the gate: rc=$rc ${out//$'\n'/ | }"
    case "$out" in *locked*|*busy*|*BUSY*) ;; *) (( rc == 0 )) || return 1 ;; esac
    (( n < 4 )) && sleep "$n"
  done
  return 1
}

# The clear did not take: the owner has done his part, so the box tells the
# agent directly (woken), and the owner is asked for nothing.
_secret_drop_tell_agent() { # <ident> <id> <key> <connector>
  local ident="$1" id="$2" key="$3" conn="$4" agent five
  agent=$(db "SELECT COALESCE(NULLIF(gate_filed_by,''),assignee,'') FROM tasks WHERE id=${id};" 2>/dev/null)
  [[ -n "$agent" ]] || { _secret_drop_log "$ident: no agent to tell that $key was saved"; return 0; }
  five=$(five_self_bundle 2>/dev/null) || five=5dive
  "$five" agent send "$agent" --wake --message="${ident}: your owner saved ${key} through the secure link — it is in $(_secret_drop_where "$key" "$conn"). The gate could not be closed on its own (journalctl -t 5dive-secret-drop says why). Use the value; do not ask for it again." >/dev/null 2>&1 \
    || _secret_drop_log "$ident: could not tell $agent that $key was saved"
}

# DIVE-6727: a refused paste used to tell nobody, so the agent re-filed the gate
# while the owner was still retrying the live link. The agent is told the time and
# the rule, never the value; at most once per link per SECRET_DROP_REFUSED_TELL_S,
# stamped in the link file, and detached so a mid-turn wake cannot hold the page.
_secret_drop_tell_refused() { # <ident> <id> <key> <connector> <link file>
  local ident="$1" id="$2" key="$3" conn="$4" f="$5" agent now last
  now=$(date +%s)
  last=$(sed -n 's/^refused_told=//p' "$f" | tail -n 1)
  [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < SECRET_DROP_REFUSED_TELL_S )) && return 0
  agent=$(db "SELECT COALESCE(NULLIF(gate_filed_by,''),assignee,'') FROM tasks WHERE id=${id};" 2>/dev/null)
  [[ -n "$agent" ]] || { _secret_drop_log "$ident: no agent to tell that a paste for $key was refused"; return 0; }
  printf 'refused_told=%s\n' "$now" >> "$f"
  _task_answer_ping_detached "$agent" --wake --message="${ident}: your owner's paste for ${key} on the secure link was refused at $(date -u -d "@$now" +%H:%M) UTC; nothing was saved and the link still works. The rule the page showed them: $(_secret_drop_rule "$conn" 0 "$([[ "$key" == *,* ]] && echo 1 || echo 0)") Do not file a new gate or ask for the value in chat." \
    || _secret_drop_log "$ident: could not tell $agent that a paste for $key was refused"
}

# _redeem --hash=<h>, value on stdin: write it, then burn every link for the gate.
# One lock across check, write and burn, so two tabs posting at once write once.
_secret_drop_redeem() {
  local hash=""
  case "${1:-}" in --hash=*) hash="${1#*=}" ;; esac
  require_root secret _redeem
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || fail "$E_NOT_FOUND" "no such link"
  exec 8>"$SECRET_DROP_LOCK" || fail "$E_GENERIC" "cannot open the drop lock"
  flock 8 || fail "$E_GENERIC" "cannot take the drop lock"
  local f="$SECRET_DROP_DIR/$hash"
  [[ -f "$f" ]] || fail "$E_NOT_FOUND" "no such link"
  local ident key connector exp
  IFS=$'\x1f' read -r ident key connector exp <<<"$(_secret_drop_read "$f")"
  if ! [[ "$exp" =~ ^[0-9]+$ ]] || (( exp <= $(date +%s) )); then
    rm -f "$f"; fail "$E_TIMEOUT" "link expired"
  fi
  # DIVE-6844: a saved value has no gate to re-check, clear or tell. Write it
  # (replacing one saved under the same name), then burn the name's links.
  local save; save=$(_secret_drop_save_of "$f")
  if [[ -n "$save" ]]; then
    [[ "$connector" == "$SECRET_SAVED_CONNECTOR" && "$key" == "$(_saved_key "$save")" ]] \
      || { rm -f "$f"; fail "$E_CONFLICT" "link is malformed"; }
    # DIVE-6973: a pair link writes the whole item (login, password, 2FA key)
    # in one rename, or nothing; the write frees the name's site itself.
    local pair; pair=$(_secret_drop_pair_of "$f")
    if (( pair )); then
      ( _saved_write_pair "$key" ) >/dev/null 2>&1 \
        || fail "$E_VALIDATION" "value refused: $(_secret_drop_rule "$connector" 1)"
    else
      ( _secret_write "$key" --connector="$connector" ) >/dev/null 2>&1 \
        || fail "$E_VALIDATION" "value refused: $(_secret_drop_rule "$connector")"
    fi
    _saved_unbind "$key" || true
    _secret_drop_burn_save "$save"
    exec 8>&-
    ok "saved $save" '{task: "", save: $s, key: $k, connector: $c}' --arg s "$save" --arg k "$key" --arg c "$connector"
    return 0
  fi
  if [[ -z "$(_secret_drop_gate_open "$ident" "$key" "$connector")" ]]; then
    rm -f "$f"; fail "$E_CONFLICT" "gate no longer open"   # DIVE-7184: this link only
  fi
  # The write reads stdin and refuses an empty value BEFORE it touches the file;
  # a refusal leaves the link live for a corrected paste. Its
  # own output is discarded: nothing it says may reach the page but the outcome.
  local rc=0 id
  id=$(_secret_drop_gate_open "$ident" "$key" "$connector")
  ( _secret_write "$key" --connector="$connector" ) >/dev/null 2>&1 || rc=$?
  if (( rc != 0 )); then
    _secret_drop_tell_refused "$ident" "$id" "$key" "$connector" "$f"
    local _multi=0; [[ "$key" == *,* ]] && _multi=1
    fail "$E_VALIDATION" "value refused: $(_secret_drop_rule "$connector" 0 "$_multi")"
  fi
  # Clear the gate with the link as the evidence, BEFORE the burn: task answer
  # reads the link back from the store (_gate_drop_link_ok). The page's unit has
  # no SUDO_UID and no login cgroup, so no other human-evidence form can hold
  # here, and `gate-proof enforce on` refuses a bare --human (main's on-box arm,
  # 2026-10-01: the value landed and the gate stayed open). Called through this
  # same bundle, so the evidence check is the one that minted the link.
  _secret_drop_clear "$ident" "$hash" "$id" || true
  _secret_drop_burn_task "$ident"
  exec 8>&-
  # Say "told" only when the row says so. A distinct code lets the page say the
  # value is saved without claiming a clear that did not happen. DIVE-5772: the
  # owner is never asked to do anything about it — the box tells the agent.
  if [[ -n "$id" && -z "$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${id};")" ]]; then
    _secret_drop_tell_agent "$ident" "$id" "$key" "$connector"
    fail "$E_AUTH_REQUIRED" "saved $key ($(_secret_drop_where "$key" "$connector")), but $ident did not update; its agent was told directly"
  fi
  ok "saved $key for $ident" '{task: $i, key: $k, connector: $c}' \
     --arg i "$ident" --arg k "$key" --arg c "$connector"
}

# ---- Caddy route and the page process --------------------------------------

# Append `secrets.<FIVE_DOMAIN> { reverse_proxy 127.0.0.1:<port> }` once, when
# this box runs the hosted Caddyfile. Validated before it counts; a failed
# validate restores the previous file. The reload is DEFERRED: the dashboard
# reaches this verb through the box's /shell proxy, and a synchronous reload
# would cut the very request asking for the link.
_secret_drop_ensure_route() {
  local cf="$SECRET_DROP_CADDYFILE" domain
  [[ -f "$cf" ]] && command -v caddy >/dev/null 2>&1 || return 0
  _secret_drop_has_base_url && return 0
  domain=$(_secret_drop_domain) || return 0
  local had=0
  grep -qE "^secrets\.${domain//./\\.}[[:space:]]*\{" "$cf" && had=1
  # DIVE-6205: a block from before the closed page is replaced, once.
  if (( had )) && _secret_drop_route_current "$cf" "secrets.${domain}"; then
    return 0
  fi
  local bak; bak=$(mktemp "${cf}.dive5319.XXXXXX") || return 1
  cp -p "$cf" "$bak" || { rm -f "$bak"; return 1; }
  if (( had )); then
    _secret_drop_route_strip "$cf" "secrets.${domain}" || { mv -f "$bak" "$cf"; return 1; }
  fi
  # DIVE-6205: the page exits once no link is live, and a link opened after that
  # (a spent one, or a chat app's link preview) got Caddy's bare, empty 502,
  # which the owner read as a fake link. With the page down no link is live, so
  # Caddy says so itself, in the page's own words (GONE[5]). Built before the
  # heredoc: an unquoted heredoc carries no command substitution.
  local closed_html; closed_html=$(_secret_drop_closed_html)
  cat >> "$cf" <<EOF

# DIVE-5319: one-time secret drop links (5dive secret link). Its own name, so TLS
# ends on this box: the root name is proxied by Cloudflare, *.<domain> is not.
secrets.${domain} {
    reverse_proxy 127.0.0.1:${SECRET_DROP_PORT}
    # DIVE-6205: the page is not running, so no link is live.
    handle_errors {
        @closed expression \`{err.status_code} in [502, 503, 504]\`
        handle @closed {
            header Content-Type "text/html; charset=utf-8"
            header Cache-Control no-store
            respond \`${closed_html}\` 410
        }
    }
}
EOF
  local out
  if out=$(caddy_validate "$cf" 2>&1); then
    rm -f "$bak"
    if command -v systemd-run >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
      systemd-run --quiet --collect --unit="5dive-caddy-reload-dive5319-$$" --on-active=3 \
        /bin/systemctl reload caddy >/dev/null 2>&1 || true
    else
      ( sleep 3; systemctl reload caddy ) >/dev/null 2>&1 &
    fi
    return 0
  fi
  mv -f "$bak" "$cf"
  warn "secret drop: Caddyfile failed validate with the secrets.${domain} block; restored the previous file ($(caddy_validate_why "$out"))"
  return 1
}

# The page Caddy serves for a link while the page is not running. No backtick
# and no newline: it sits inside one backtick-quoted Caddyfile token.
_secret_drop_closed_html() {
  printf '%s' "<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><meta name=robots content=noindex><title>This request is closed</title></head><body style='font:16px/1.5 system-ui,sans-serif;max-width:32rem;margin:3rem auto;padding:0 1rem'><h1>This request is closed</h1><p>The agent no longer needs this, or it was already provided.</p></body></html>"
}

# The Caddyfile's site blocks named <name>: a line "<name> {" to the brace that
# closes it. The name is compared as a string, never used as a regex.
# rc 0 = such a block already carries handle_errors (the DIVE-6205 shape).
_secret_drop_route_current() { # <caddyfile> <name>
  SITE="$2" awk '
    { l = $0; sub(/[[:space:]]*\{[[:space:]]*$/, "", l) }
    !inb && l == ENVIRON["SITE"] && $0 ~ /\{[[:space:]]*$/ { inb = 1; depth = 0 }
    inb { if ($0 ~ /handle_errors/) found = 1
          depth += gsub(/\{/, "{"); depth -= gsub(/\}/, "}")
          if (depth <= 0) inb = 0 }
    END { exit found ? 0 : 1 }' "$1"
}

# Remove those blocks, and the DIVE-5319 comment right above each, in place.
_secret_drop_route_strip() { # <caddyfile> <name>
  local tmp; tmp=$(mktemp "${1}.dive6205.XXXXXX") || return 1
  SITE="$2" awk '
    { l = $0; sub(/[[:space:]]*\{[[:space:]]*$/, "", l) }
    inb { depth += gsub(/\{/, "{"); depth -= gsub(/\}/, "}"); if (depth <= 0) inb = 0; next }
    l == ENVIRON["SITE"] && $0 ~ /\{[[:space:]]*$/ {
      n = 0; inb = 1; depth = gsub(/\{/, "{") - gsub(/\}/, "}"); if (depth <= 0) inb = 0; next }
    { buf[++n] = $0 }
    # Hold the DIVE-5319 comment (and blank lines) until we know what follows.
    /^# DIVE-5319: one-time secret drop links/ || /^# ends on this box: the root name/ || /^[[:space:]]*$/ { next }
    { for (i = 1; i <= n; i++) print buf[i]; n = 0 }
    END { for (i = 1; i <= n; i++) print buf[i] }' "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
  if ! cat "$tmp" > "$1"; then rm -f "$tmp"; return 1; fi
  rm -f "$tmp"
  return 0
}

_secret_drop_has_base_url() {
  [[ -r "$SECRET_DROP_CONF" ]] || return 1
  grep -q '^SECRET_DROP_BASE_URL=.' "$SECRET_DROP_CONF"
}

# DIVE-5372: does https://secrets.<domain>/ answer as the owner will see it?
# A TLS handshake that verifies a certificate for that exact name (curl's
# default; never -k), through this box's Caddy (--resolve to loopback, so no
# hairpin NAT or DNS cache is in the way), reaching the page itself: /healthz
# is the page's own 200, where a route with no page behind it is a 502 and a
# name Caddy has no certificate for fails the handshake. /healthz, not a random
# token path: a 404 there counts against the page's failed-lookup rate limit.
_secret_drop_ready() {
  local domain="$1" body
  if [[ "${2:-}" == own ]]; then
    # DIVE-7113: the self-hosted front's name is the host itself (an IP or a
    # name). --connect-to, not --resolve: curl never resolves an IP literal.
    body=$(curl -fsS --max-time 3 --connect-to "${domain}:443:${SECRET_DROP_PROBE_ADDR}:443" \
      "https://${domain}/healthz" 2>/dev/null) || return 1
  else
    body=$(curl -fsS --max-time 3 --resolve "secrets.${domain}:443:${SECRET_DROP_PROBE_ADDR}" \
      "https://secrets.${domain}/healthz" 2>/dev/null) || return 1
  fi
  [[ "$body" == *'"ok":true'* ]]
}

# Poll _secret_drop_ready until it holds or <seconds> pass. rc 0 = ready.
# A third argument "own" probes a self-hosted front's host (DIVE-7113).
_secret_drop_wait_ready() {
  local domain="$1" secs="$2" kind="${3:-}" deadline
  [[ "$secs" =~ ^[0-9]+$ ]] || secs=20
  deadline=$(( $(date +%s) + secs ))
  while :; do
    _secret_drop_ready "$domain" "$kind" && return 0
    (( $(date +%s) >= deadline )) && return 1
    sleep "$SECRET_DROP_POLL_S"
  done
}

# DIVE-5806 (H2): who holds the drop port. The page exits between gates, so
# 127.0.0.1:3127 is free most of the time, and it is an unprivileged port: any
# seat can bind it and answer /healthz. Probing /healthz alone (the old check)
# then sent the owner's next link to that seat, on secrets.<box>'s valid
# certificate. The kernel's own table says which uid owns each listening socket,
# readable without root and without `ss -p`. Prints the distinct uids, one a line.
_secret_drop_port_uids() {
  local hex; hex=$(printf ':%04X' "$SECRET_DROP_PORT")
  awk -v p="$hex" '$4 == "0A" && substr($2, length($2) - 4) == p { print $8 }' \
    "$SECRET_DROP_PROC_NET/tcp" "$SECRET_DROP_PROC_NET/tcp6" 2>/dev/null | sort -u
}
# rc 0 = only root listens on the port, 1 = nobody does, 2 = someone else does
# (their uid on stdout).
_secret_drop_port_holder() {
  local uids u; uids=$(_secret_drop_port_uids)
  [[ -n "$uids" ]] || return 1
  while read -r u; do
    [[ "$u" == 0 ]] || { printf '%s' "$u"; return 2; }
  done <<<"$uids"
  return 0
}
_secret_drop_squat_msg() {   # <uid>
  local who; who=$(getent passwd "$1" 2>/dev/null | cut -d: -f1)
  printf 'the secure page'"'"'s port 127.0.0.1:%s is held by uid %s%s, not root, so a link would send your owner to that process instead of the real page. Nothing was minted. Stop that listener (sudo ss -tlnp "sport = :%s"), then ask again.' \
    "$SECRET_DROP_PORT" "$1" "${who:+ ($who)}" "$SECRET_DROP_PORT"
}

# Start the page if nothing holds its port. It exits by itself once no link is
# live, so a box carries no listener between gates. rc 2 (DIVE-5806): the port
# is held by a uid other than root, before or after the start; the uid is on
# stdout and no link may be handed out.
_secret_drop_ensure_server() {
  local held=0 uid
  uid=$(_secret_drop_port_holder) || held=$?
  (( held == 2 )) && { printf '%s' "$uid"; return 2; }
  (( held == 0 )) && return 0
  command -v python3 >/dev/null 2>&1 || { warn "secret drop: python3 missing, the page cannot start"; return 1; }
  local self; self="$(five_self_bundle || true)"
  [[ -n "$self" ]] || { warn "secret drop: could not find the 5dive bundle"; return 1; }
  local started=0
  if command -v systemd-run >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl reset-failed 5dive-secret-drop.service >/dev/null 2>&1 || true
    systemd-run --quiet --collect --unit=5dive-secret-drop \
      -p PrivateTmp=yes -p NoNewPrivileges=yes \
      "$self" secret serve >/dev/null 2>&1 && started=1
  fi
  (( started )) || { setsid nohup "$self" secret serve >/dev/null 2>&1 < /dev/null & }
  # A seat can still win the bind between our look and the page's start: look
  # again once something listens (bounded; the page binds in well under a second).
  local deadline=$(( $(date +%s) + SECRET_DROP_BIND_S ))
  while :; do
    held=0; uid=$(_secret_drop_port_holder) || held=$?
    (( held == 2 )) && { printf '%s' "$uid"; return 2; }
    (( held == 0 )) && return 0
    (( $(date +%s) >= deadline )) && return 0
    sleep "$SECRET_DROP_POLL_S"
  done
}

# ---- DIVE-7113: https on a self-hosted box ----------------------------------
#
# A hosted box serves its links at secrets.<FIVE_DOMAIN>. A self-hosted box has
# no FIVE_DOMAIN and no Caddyfile, so it had no link at all and every secret
# went through a terminal. Now it gets https ON THE BOX: its own Caddy, its own
# certificate, and the same page behind it. Nothing about a value passes through
# 5dive's relay, API or app, encrypted or not (lodar 2026-10-27).
#   ip      a Let's Encrypt certificate for the box's public IPv4 (the 6-day
#           "shortlived" profile; Caddy >= 2.11, 2.10 refused IP orders,
#           caddy#7399). No third party's DNS in a secret's path. The default.
#   sslip   <ip-with-dashes>.sslip.io with a normal certificate. The fallback:
#           sslip.io's operator answers for the name, and it is not on the Public
#           Suffix List, so every sslip.io user shares one 50-a-week cert bucket.
#   domain  the owner's own name, pointed at the box (lodar: "sslip or self").
# The first `secret link` on such a box tries ip, then sslip, by itself; only
# when both fail (NAT, closed ports) is the owner asked for a domain or sent to
# the terminal. Not FIVE_DOMAIN: on a box that sets it, the browser plugin takes
# it for a hosted box and looks for the hosted relay.
SECRET_HTTPS_CADDYFILE="/etc/5dive/secret-https.Caddyfile"
SECRET_HTTPS_UNIT="5dive-secret-https"
SECRET_HTTPS_UNIT_DIR="/etc/systemd/system"
SECRET_HTTPS_CADDY_MIN=2.11
SECRET_HTTPS_LOCK="/run/5dive-secret-https.lock"
# How long one way gets to show a valid certificate, and how long a box where
# both automatic ways failed waits before the next `secret link` tries again.
SECRET_HTTPS_WAIT_S="${SECRET_HTTPS_WAIT_S:-60}"
SECRET_HTTPS_RETRY_S="${SECRET_HTTPS_RETRY_S:-3600}"
SECRET_HTTPS_WHY=""
# DIVE-7133: the browser's login screen rides this same front. A self-hosted box
# linked to 5dive.app gets its agents' Connect links on this host, and two fronts
# cannot share 80/443 (the second refused the first). The browser plugin's
# login-link server listens here (its LINK_PORT_DEFAULT); with none running, a
# viewer path gets the same closed page as a spent secret link.
SECRET_HTTPS_VIEWER_PORT=3111

_secret_https_get() { [[ -r "$SECRET_DROP_CONF" ]] && sed -n "s/^$1=//p" "$SECRET_DROP_CONF" | tail -1; }
# The front's host (an IPv4 or a name), only in a shape safe for a Caddyfile and a URL.
_secret_https_host() {
  local h; h=$(_secret_https_get SECRET_HTTPS_HOST)
  [[ "$h" =~ ^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$ && "$h" == *.* ]] || return 1
  printf '%s' "$h"
}
_secret_https_failed_file() { printf '%s' "${STATE_DIR}/secret-https.failed"; }

# The box's public IPv4 from its own interfaces (the browser plugin's filter).
# Empty behind NAT, which is the answer: neither automatic way works there.
_secret_https_public_ipv4() {
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
    | grep -vE '^(10\.|127\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' | head -1
}

# The whole front: /browser/viewer/ to the browser's login screen (DIVE-7133),
# every other path to the page (it 404s what is not a live token), a 410 page
# while either is down, no admin endpoint.
_secret_https_caddyfile() { # <mode> <host>
  local mode="$1" host="$2" closed_html; closed_html=$(_secret_drop_closed_html)
  printf '# Written by `5dive secret https` (DIVE-7113). Re-run it to change this.\n{\n\tadmin off\n'
  [[ "$mode" == ip ]] && printf '\tdefault_sni %s\n' "$host"   # a client never sends an IP as SNI
  printf '}\n\nhttps://%s {\n' "$host"
  [[ "$mode" == ip ]] && printf '\ttls {\n\t\tissuer acme {\n\t\t\tprofile shortlived\n\t\t}\n\t}\n'
  printf '\t@viewer path /browser/viewer/*\n\thandle @viewer {\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n' "$SECRET_HTTPS_VIEWER_PORT"
  printf '\thandle {\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n' "$SECRET_DROP_PORT"
  printf '\thandle_errors {\n\t\t@closed expression `{err.status_code} in [502, 503, 504]`\n\t\thandle @closed {\n'
  printf '\t\t\theader Content-Type "text/html; charset=utf-8"\n\t\t\theader Cache-Control no-store\n'
  printf '\t\t\trespond `%s` 410\n\t\t}\n\t}\n}\n' "$closed_html"
}

# Caddy as user caddy, its config handed in by systemd (DIVE-6980: user caddy
# cannot read 5dive's own dirs, and must not).
_secret_https_unit() {
  cat <<UNIT
# Written by \`5dive secret https\` (DIVE-7113).
[Unit]
Description=5dive one-time secret links: HTTPS on this self-hosted box
After=network-online.target
Wants=network-online.target

[Service]
User=caddy
Group=caddy
StateDirectory=$SECRET_HTTPS_UNIT
Environment=HOME=/var/lib/$SECRET_HTTPS_UNIT XDG_DATA_HOME=/var/lib/$SECRET_HTTPS_UNIT XDG_CONFIG_HOME=/var/lib/$SECRET_HTTPS_UNIT
LoadCredential=Caddyfile:$SECRET_HTTPS_CADDYFILE
ExecStart=/usr/bin/caddy run --config %d/Caddyfile --adapter caddyfile
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
}

_secret_https_caddy_version() { caddy version 2>/dev/null | sed -n 's/^v\([0-9]*\.[0-9]*\).*/\1/p' | head -1; }
_secret_https_ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

# Caddy >= 2.11 from Caddy's own signed apt source (a distro's is too old for IP
# certificates). The package starts a stock caddy.service on port 80: stopped
# and disabled when THIS run installed it, never a Caddy the owner already had.
_secret_https_install_caddy() {
  local v; v=$(_secret_https_caddy_version)
  if [[ -n "$v" ]]; then
    _secret_https_ver_ge "$v" "$SECRET_HTTPS_CADDY_MIN" && id caddy >/dev/null 2>&1 && return 0
    dpkg -s caddy >/dev/null 2>&1 \
      || { SECRET_HTTPS_WHY="this box has Caddy ${v} not from apt, and it needs ${SECRET_HTTPS_CADDY_MIN} or newer with a caddy user"; return 1; }
  fi
  command -v apt-get >/dev/null 2>&1 || { SECRET_HTTPS_WHY="no apt-get here to install Caddy ${SECRET_HTTPS_CADDY_MIN}+"; return 1; }
  local had=0 kr=/usr/share/keyrings/caddy-stable-archive-keyring.gpg
  dpkg -s caddy >/dev/null 2>&1 && had=1
  curl -fsSL --max-time 30 https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o "$kr" 2>/dev/null \
    && printf 'deb [signed-by=%s] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main\n' "$kr" \
         > /etc/apt/sources.list.d/caddy-stable.list \
    && DEBIAN_FRONTEND=noninteractive apt-get -qq update >/dev/null 2>&1 \
    && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y caddy >/dev/null 2>&1 || true
  (( had )) || systemctl disable --now caddy.service >/dev/null 2>&1 || true
  v=$(_secret_https_caddy_version)
  [[ -n "$v" ]] && _secret_https_ver_ge "$v" "$SECRET_HTTPS_CADDY_MIN" && id caddy >/dev/null 2>&1 && return 0
  SECRET_HTTPS_WHY="could not install Caddy ${SECRET_HTTPS_CADDY_MIN}+ (have: ${v:-none})"
  return 1
}

_secret_https_port_busy() { [[ -n "$(ss -Hltn "sport = :$1" 2>/dev/null)" ]]; }

# rc 0 = https://<host>/ completes a handshake on a certificate curl verifies
# (never -k), through this box's own front. Any HTTP status counts: the page
# may be down (410) and that is still a working certificate.
_secret_https_tls_ok() {
  local host="$1" code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
    --connect-to "${host}:443:${SECRET_DROP_PROBE_ADDR}:443" "https://${host}/healthz" 2>/dev/null) || code=000
  [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]
}

_secret_https_conf_set() { # <mode> <host>, keeping every other line of the conf
  local tmp; tmp=$(mktemp "${SECRET_DROP_CONF}.XXXXXX" 2>/dev/null) || return 1
  [[ -f "$SECRET_DROP_CONF" ]] && grep -vE '^SECRET_HTTPS_(MODE|HOST)=' "$SECRET_DROP_CONF" > "$tmp"
  [[ -z "$1" ]] || printf 'SECRET_HTTPS_MODE=%s\nSECRET_HTTPS_HOST=%s\n' "$1" "$2" >> "$tmp"
  chmod 644 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$SECRET_DROP_CONF"
}

# Turn the front on one way. rc 0 = a verified certificate answers and the conf
# names the host; otherwise the front is off again and SECRET_HTTPS_WHY says why.
_secret_https_enable() { # <ip|sslip|domain> [<host>]
  local mode="$1" host="${2:-}" ip=""
  SECRET_HTTPS_WHY=""
  case "$mode" in
    ip|sslip)
      ip=$(_secret_https_public_ipv4)
      [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
        || { SECRET_HTTPS_WHY="this box has no public IPv4 address (it is behind a router or NAT)"; return 1; }
      if [[ "$mode" == ip ]]; then host="$ip"; else host="${ip//./-}.sslip.io"; fi ;;
    domain)
      host="${host,,}"
      [[ "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] \
        || { SECRET_HTTPS_WHY="'${host}' is not a domain name (box.example.com)"; return 1; } ;;
    *) SECRET_HTTPS_WHY="unknown way '${mode}' (ip, sslip or domain)"; return 1 ;;
  esac
  systemctl stop "$SECRET_HTTPS_UNIT" >/dev/null 2>&1 || true
  if _secret_https_port_busy 443 || _secret_https_port_busy 80; then
    SECRET_HTTPS_WHY="another program already uses port 80 or 443 on this box"
    systemctl is-active --quiet 5dive-browser-link-tls 2>/dev/null \
      && SECRET_HTTPS_WHY="the browser's login-link front already uses ports 80 and 443 on this box"
    _secret_https_off; return 1
  fi
  _secret_https_install_caddy || { _secret_https_off; return 1; }
  mkdir -p "${SECRET_HTTPS_CADDYFILE%/*}" "$SECRET_HTTPS_UNIT_DIR" "${SECRET_DROP_CONF%/*}" || { SECRET_HTTPS_WHY="cannot write ${SECRET_HTTPS_CADDYFILE%/*}"; return 1; }
  ( umask 022; _secret_https_caddyfile "$mode" "$host" > "$SECRET_HTTPS_CADDYFILE" ) || { SECRET_HTTPS_WHY="cannot write $SECRET_HTTPS_CADDYFILE"; return 1; }
  local out
  if ! out=$(caddy validate --config "$SECRET_HTTPS_CADDYFILE" --adapter caddyfile 2>&1); then
    SECRET_HTTPS_WHY="Caddy refused the config ($(caddy_validate_why "$out"))"; _secret_https_off; return 1
  fi
  ( umask 022; _secret_https_unit > "$SECRET_HTTPS_UNIT_DIR/$SECRET_HTTPS_UNIT.service" ) || { SECRET_HTTPS_WHY="cannot write the unit"; _secret_https_off; return 1; }
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable "$SECRET_HTTPS_UNIT" >/dev/null 2>&1 || true
  systemctl restart "$SECRET_HTTPS_UNIT" >/dev/null 2>&1 \
    || { SECRET_HTTPS_WHY="the https front did not start (journalctl -u $SECRET_HTTPS_UNIT)"; _secret_https_off; return 1; }
  local deadline=$(( $(date +%s) + SECRET_HTTPS_WAIT_S ))
  until _secret_https_tls_ok "$host"; do
    if (( $(date +%s) >= deadline )); then
      SECRET_HTTPS_WHY="no valid certificate for ${host} after ${SECRET_HTTPS_WAIT_S}s (ports 80 and 443 must reach this box from the internet)"
      _secret_https_off; return 1
    fi
    sleep "$SECRET_DROP_POLL_S"
  done
  _secret_https_conf_set "$mode" "$host" || { SECRET_HTTPS_WHY="cannot write $SECRET_DROP_CONF"; _secret_https_off; return 1; }
  rm -f "$(_secret_https_failed_file)"
  return 0
}

# Everything the front put on the box, gone (Caddy itself stays installed).
_secret_https_off() {
  systemctl disable --now "$SECRET_HTTPS_UNIT" >/dev/null 2>&1 || true
  rm -f "${SECRET_HTTPS_UNIT_DIR:?}/${SECRET_HTTPS_UNIT:?}.service" "${SECRET_HTTPS_CADDYFILE:?}"
  [[ -f "$SECRET_DROP_CONF" ]] && _secret_https_conf_set "" ""
  systemctl daemon-reload >/dev/null 2>&1 || true
  return 0
}

# A self-hosted box: no FIVE_DOMAIN and no owner's own base URL. A hosted box
# never takes any of the paths above.
_secret_https_selfhosted() { ! _secret_drop_domain >/dev/null && ! _secret_drop_has_base_url; }

# The just-in-time step `secret link` takes on a box with no https name: ip,
# then sslip. One at a time (two gates at once must not race for port 443), and
# after both failed, not again for SECRET_HTTPS_RETRY_S (a closed port costs
# two full waits per try).
_secret_https_auto() {
  _secret_https_selfhosted || return 1
  local ff last=0 now; ff=$(_secret_https_failed_file); now=$(date +%s)
  [[ -r "$ff" ]] && last=$(sed -n 's/^at=//p' "$ff" | head -1)
  if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < SECRET_HTTPS_RETRY_S )); then
    SECRET_HTTPS_WHY="$(sed -n 's/^why=//p' "$ff" | head -1)"; return 1
  fi
  exec 9>"$SECRET_HTTPS_LOCK" 2>/dev/null && flock 9 2>/dev/null || true
  _secret_https_host >/dev/null && { exec 9>&-; return 0; }   # another call made it meanwhile
  local why_ip=""
  if _secret_https_enable ip; then exec 9>&-; return 0; fi
  why_ip="$SECRET_HTTPS_WHY"
  # sslip.io only helps where the IP certificate itself failed: no public IP, a
  # busy port or no Caddy fail it the same way, so skip the second wait.
  if [[ "$why_ip" == "no valid certificate"* || "$why_ip" == "Caddy refused"* ]]; then
    if _secret_https_enable sslip; then exec 9>&-; return 0; fi
  fi
  SECRET_HTTPS_WHY="$why_ip"
  ( umask 077; printf 'at=%s\nwhy=%s\n' "$now" "$why_ip" > "$ff" ) 2>/dev/null || true
  exec 9>&-
  return 1
}

# DIVE-7133: a front written before the viewer route serves no login screen.
# Rewrite it for the host it already has; the certificate stays in Caddy's own
# storage, so this is a restart, not a new order. rc 0 = the route is there.
_secret_https_refresh() {
  local h m; h=$(_secret_https_host) || { SECRET_HTTPS_WHY="this box has no https name yet"; return 1; }
  grep -qF '/browser/viewer/' "$SECRET_HTTPS_CADDYFILE" 2>/dev/null && return 0
  m=$(_secret_https_get SECRET_HTTPS_MODE)
  [[ "$m" =~ ^(ip|sslip|domain)$ ]] || { SECRET_HTTPS_WHY="the https conf names no way ($m)"; return 1; }
  ( umask 022; _secret_https_caddyfile "$m" "$h" > "$SECRET_HTTPS_CADDYFILE" ) || { SECRET_HTTPS_WHY="cannot write $SECRET_HTTPS_CADDYFILE"; return 1; }
  systemctl restart "$SECRET_HTTPS_UNIT" >/dev/null 2>&1 \
    || { SECRET_HTTPS_WHY="the https front did not restart (journalctl -u $SECRET_HTTPS_UNIT)"; return 1; }
  return 0
}

# What `secret link` says when there is still no https name: written for the
# agent to pass on as two plain messages (a domain, or the terminal).
_secret_https_no_name_msg() { # <terminal command>
  local ip; ip=$(_secret_https_public_ipv4)
  if ! _secret_https_selfhosted; then
    printf "this box has no https name an owner's browser can reach (no FIVE_DOMAIN in %s, no SECRET_DROP_BASE_URL in %s). Use the terminal instead: %s" \
      "$SECRET_DROP_PROVISIONING" "$SECRET_DROP_CONF" "$1"
    return 0
  fi
  local why=""; [[ -n "$SECRET_HTTPS_WHY" ]] && why=", and it could not make one by itself (${SECRET_HTTPS_WHY})"
  printf 'this box has no secure web address for the link yet%s. Ask your owner first: "Do you have a domain? Point it at %s and tell me the name." With a name, run: sudo 5dive secret https enable --via=domain --host=<name>, then ask for the link again. Without one, the owner types the value on this box instead: %s' \
    "$why" "${ip:-this box}" "$1"
}

# `5dive secret https [status|enable --via=ip|sslip|domain|auto [--host=<name>]|disable]`
_secret_https() {
  local sub="${1:-status}"; shift || true
  local via="" host="" a
  if ! _secret_https_selfhosted; then
    case "$sub" in
      status|-h|--help|help) ok "links on this box already use its own https name ($(_secret_drop_base_url 2>/dev/null)); there is nothing to set up." '{on: true, managed: false}'; return 0 ;;
    esac
    fail "$E_CONFLICT" "this box already has its https name ($(_secret_drop_base_url 2>/dev/null)), so its links work; nothing changed"
  fi
  case "$sub" in
    status)
      local h m; h=$(_secret_https_host) || h=""; m=$(_secret_https_get SECRET_HTTPS_MODE)
      if [[ -n "$h" ]]; then
        ok "secret links: on, via ${m:-?} - https://${h}/..." '{on: true, managed: true, mode: $m, host: $h}' --arg m "$m" --arg h "$h"
      else
        ok "secret links: no https address yet; the first secret link makes one (an IP certificate, then sslip.io). Your own domain: sudo 5dive secret https enable --via=domain --host=<name>" '{on: false, managed: true}'
      fi ;;
    enable)
      for a in "$@"; do
        case "$a" in
          --via=*)  via="${a#*=}" ;;
          --host=*) host="${a#*=}" ;;
          *) fail "$E_USAGE" "unknown: $a (5dive secret https enable --via=ip|sslip|domain|auto [--host=<name>])" ;;
        esac
      done
      require_root secret https
      [[ "$via" =~ ^(ip|sslip|domain|auto)$ ]] || fail "$E_USAGE" "--via must be ip, sslip, domain or auto"
      [[ "$via" == domain && -z "$host" ]] && fail "$E_USAGE" "--via=domain needs --host=<your domain>, pointed at this box"
      [[ "$via" != domain && -n "$host" ]] && fail "$E_USAGE" "--via=$via makes its own name; --host is for --via=domain"
      if [[ "$via" == auto ]]; then
        # DIVE-7133: what the browser plugin calls before it sends a Connect link
        # in 5dive.app: the name the box has, else the first link's own steps
        # (an IP certificate, then sslip.io, with the same retry window).
        { _secret_https_auto && _secret_https_refresh; } \
          || fail "$E_NOT_INSTALLED" "no https name on this box: ${SECRET_HTTPS_WHY:-it could not make one}"
        local h m; h=$(_secret_https_host); m=$(_secret_https_get SECRET_HTTPS_MODE)
        ok "https on this box: on, via ${m:-?} - https://${h}/..." '{on: true, managed: true, mode: $m, host: $h}' --arg m "$m" --arg h "$h"
        return 0
      fi
      _secret_https_enable "$via" "$host" || fail "$E_NOT_INSTALLED" "secret links stay without https: ${SECRET_HTTPS_WHY}. The https front is off now; the next secret link sets one up again (an IP certificate, then sslip.io)."
      local h; h=$(_secret_https_host)
      ok "secret links: on, via ${via} - https://${h}/...$([[ "$via" == sslip ]] && printf '\n  note: sslip.io answers for this name; --via=ip or your own domain keeps any third party out of it.')" \
        '{on: true, managed: true, mode: $m, host: $h}' --arg m "$via" --arg h "$h" ;;
    disable)
      require_root secret https
      _secret_https_off; rm -f "$(_secret_https_failed_file)"
      ok "secret links: https off; Caddy stays installed, nothing listens on 80 or 443 for links." '{on: false, managed: true}' ;;
    -h|--help|help) _secret_usage ;;
    *) fail "$E_USAGE" "secret https: status, enable or disable" ;;
  esac
}

# ---- secret serve ----------------------------------------------------------

_secret_serve() {
  local listen="127.0.0.1:${SECRET_DROP_PORT}" idle=120
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --listen=*)    listen="${1#*=}" ;;
      --idle-exit=*) idle="${1#*=}" ;;
      *) fail "$E_USAGE" "unknown flag: $1" ;;
    esac
    shift
  done
  require_root secret serve
  command -v python3 >/dev/null 2>&1 || fail "$E_NOT_INSTALLED" "secret serve needs python3"
  [[ "$listen" =~ ^([^:]+):([0-9]+)$ ]] || fail "$E_VALIDATION" "--listen must be host:port"
  local host="${BASH_REMATCH[1]}" port="${BASH_REMATCH[2]}"
  # Plain HTTP on loopback only: TLS is Caddy's (or the owner's tunnel's) job.
  [[ "$host" =~ ^(127(\.[0-9]{1,3}){3}|::1|localhost)$ ]] \
    || fail "$E_VALIDATION" "refusing a routable plain-HTTP bind '$host'; keep it on loopback behind HTTPS"
  [[ "$idle" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "--idle-exit must be seconds"
  local self; self="$(five_self_bundle || true)"; [[ -n "$self" ]] || self="${FIVE_SECRET_DROP_BIN:-}"
  [[ -n "$self" ]] || fail "$E_GENERIC" "could not identify the 5dive bundle"
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/5dive-secret-drop.XXXXXX") || fail "$E_GENERIC" "no temp dir"
  chmod 700 "$tmp"
  _secret_drop_server_py > "$tmp/server.py"
  local rc=0
  python3 "$tmp/server.py" "$host" "$port" "$self" "$SECRET_DROP_DIR" "$idle" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

_secret_drop_server_py() {
  cat <<'PY'
import html, json, os, re, subprocess, sys, threading, time, hashlib, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST, PORT, BUNDLE, STORE, IDLE = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5])
TOKEN = re.compile(r"^/([A-Za-z0-9_-]{43})$")
MAX_BODY = 65536
WINDOW, PER_CLIENT, GLOBAL = 600, 10, 60
fails, fails_lock = {}, threading.Lock()

def limited(client):
    now = time.time()
    with fails_lock:
        for k in list(fails):
            fails[k] = [t for t in fails[k] if now - t < WINDOW]
            if not fails[k]: del fails[k]
        total = sum(len(v) for v in fails.values())
        return len(fails.get(client, [])) >= PER_CLIENT or total >= GLOBAL

def record_fail(client):
    with fails_lock:
        fails.setdefault(client, []).append(time.time())

CSS = ("body{font:16px/1.5 system-ui,-apple-system,Segoe UI,sans-serif;margin:0;background:#f6f6f4;color:#1b1b1a}"
       "main{max-width:30rem;margin:0 auto;padding:2rem 1rem}h1{font-size:1.25rem;margin:0 0 .75rem}"
       "p{margin:.5rem 0}.ask{background:#fff;border:1px solid #ddd;border-radius:8px;padding:.75rem;white-space:pre-wrap}"
       "textarea{display:block;width:100%;box-sizing:border-box;font:14px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;"
       "padding:.7rem;border:1px solid #bbb;border-radius:8px;margin:.75rem 0;min-height:9rem;resize:vertical}"
       ".secret{-webkit-text-security:disc}"
       "label{display:block;font-weight:600;margin-top:.75rem}label+textarea{margin-top:.25rem}"
       ".pair textarea{min-height:0;resize:none}.tip{background:#fff6dc;border-radius:8px;padding:.6rem .75rem}"
       "button{width:100%;font:inherit;font-weight:600;padding:.75rem;border:0;border-radius:8px;background:#1b1b1a;color:#fff}"
       "small{color:#666}code{font-size:.9em}"
       "@media (prefers-color-scheme:dark){body{background:#151514;color:#eee}.ask{background:#1f1f1e;border-color:#333}"
       "textarea{background:#1f1f1e;color:#eee;border-color:#444}button{background:#eee;color:#151514}small{color:#aaa}"
       ".tip{background:#3a3220}}")

def page(title, body):
    return ("<!doctype html><html lang=en><head><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            "<meta name=robots content=noindex><title>%s</title><style>%s</style></head>"
            "<body><main>%s</main></body></html>" % (html.escape(title), CSS, body)).encode()

GONE = {
    4: (404, "This link does not work", "It may have been mistyped, or it was already used."),
    11: (410, "This link has expired", "Open the task again in the 5dive app for a new link."),
    5: (410, "This request is closed", "The agent no longer needs this, or it was already provided."),
}

# DIVE-6205: a call that outlives this is NOT "nothing was saved". RAN_LONG is the
# page's own code for it, outside any exit status the CLI returns.
RUN_TIMEOUT = int(os.environ.get("FIVE_SECRET_DROP_RUN_TIMEOUT", "60"))
RAN_LONG = -1

def run(args, stdin=None):
    try:
        p = subprocess.run([BUNDLE, "secret"] + args + ["--json"], input=stdin,
                           capture_output=True, timeout=RUN_TIMEOUT)
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired:
        return RAN_LONG, b""

# DIVE-6844: the page for a saved login or detail. One field, no task, no agent.
# DIVE-6973 (lodar 03:22Z): both save pages say, above the fields, to use an
# account made for the agents. A tip, never a block: some sites only make sense
# on his own account.
SEPARATE = ("<p class=tip>Best to make a separate account for your agents. "
            "On your own account, they can do anything you can.</p>")
# Masked textareas, never type=password: browsers offer to save every password
# field, and a login kept for agents is not one the owner's browser should keep.
FIELD = ("<textarea name=%s class=%s rows=%d autocomplete=off autocapitalize=off "
         "autocorrect=off spellcheck=false data-1p-ignore data-lpignore=true data-bwignore "
         "%s aria-label='%s'></textarea>")

def save_form(d):
    if d.get("pair"):
        return save_pair_form(d)
    return ("<h1>Save <b>%s</b></h1>" % html.escape(d["save"]) + SEPARATE +
            "<p>Your agents can type it into a site for you. They never see it, and it is never shown again.</p>"
            "<form method=post autocomplete=off>" +
            FIELD % ("value", "secret", 2, "required autofocus", "Paste the value") +
            "<button type=submit>Save</button></form>"
            "<p><small>This page is served by your own server. The value goes only there, and this "
            "link then stops working. Expires at %s UTC.</small></p>"
            % time.strftime("%H:%M", time.gmtime(int(d["expires"]))))

# DIVE-6973: one item = a login, a password and an optional 2FA setup key, in one page.
def save_pair_form(d):
    return ("<h1>Save <b>%s</b></h1>" % html.escape(d["save"]) + SEPARATE +
            "<p>Your agents can sign in with it for you. They never see the password, and it is never shown again.</p>"
            "<form method=post autocomplete=off class=pair>"
            "<label for=f-login>Login</label>" +
            FIELD.replace("<textarea ", "<textarea id=f-login ", 1) % ("login", "plain", 1, "required autofocus", "Login") +
            "<label for=f-password>Password</label>" +
            FIELD.replace("<textarea ", "<textarea id=f-password ", 1) % ("password", "secret", 1, "required", "Password") +
            "<label for=f-totp>2FA setup key (optional)</label>" +
            FIELD.replace("<textarea ", "<textarea id=f-totp ", 1) % ("totp", "secret", 1, "", "2FA setup key") +
            "<p><small>With this, your agents can sign in without you. Use it on an account made for them.</small></p>"
            "<button type=submit>Save</button></form>"
            "<p><small>This page is served by your own server. It all goes only there, and this "
            "link then stops working. Expires at %s UTC.</small></p>"
            % time.strftime("%H:%M", time.gmtime(int(d["expires"]))))

# DIVE-7184: a key with several parts (X's four values) is one gate and one
# link: one labelled box per key, all saved by one tap, or none.
def keys_form(d, who, ask):
    keys = d["keys"]
    boxes = "".join(
        "<label for=f-%d>%s</label>" % (i, html.escape(k)) +
        FIELD.replace("<textarea ", "<textarea id=f-%d " % i, 1)
        % ("k%d" % i, "secret", 1, "required" + (" autofocus" if i == 0 else ""), html.escape(k))
        for i, k in enumerate(keys))
    return ("<h1>%s needs %d values</h1>" % (who, len(keys)) +
            ("<p class=ask>%s</p>" % html.escape(ask) if ask else "") +
            "<form method=post autocomplete=off class=pair>" + boxes +
            "<button type=submit>Save on the server</button></form>"
            "<p><small>This page is served by your own server. The values go only there, "
            "in <code>%s</code>, and this link then stops working. Expires at %s UTC.</small></p>"
            % (html.escape(d["connector"]), time.strftime("%H:%M", time.gmtime(int(d["expires"])))))

class Handler(BaseHTTPRequestHandler):
    server_version = "5dive"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    timeout = 20
    def log_message(self, fmt, *args):
        # Never the path: the path IS the token.
        pass
    def client(self):
        xff = self.headers.get("X-Forwarded-For", "")
        return (xff.split(",")[-1].strip() if xff else self.client_address[0]) or "?"
    def send_page(self, code, body, ctype="text/html; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy",
            "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(body)
    def gone(self, rc):
        code, title, msg = GONE.get(rc, (500, "Something went wrong", "Nothing was saved. Try the link again in a minute."))
        if rc in (4, 11): record_fail(self.client())
        return self.send_page(code, page(title, "<h1>%s</h1><p>%s</p>" % (title, msg)))
    def token_hash(self):
        m = TOKEN.match(self.path.split("?", 1)[0])
        return hashlib.sha256(m.group(1).encode()).hexdigest() if m else None
    def do_GET(self):
        if self.path == "/healthz":
            return self.send_page(200, b'{"ok":true}', "application/json")
        if limited(self.client()):
            return self.send_page(429, page("Too many tries", "<h1>Too many tries</h1><p>Wait a few minutes.</p>"))
        h = self.token_hash()
        if not h: return self.gone(4)
        rc, out = run(["_peek", "--hash=" + h])
        if rc != 0: return self.gone(rc)
        d = json.loads(out).get("data", {})
        if d.get("save"):
            return self.send_page(200, page("Save %s" % d["save"], save_form(d)))
        who = html.escape(d.get("agent") or "Your agent")
        ask = d.get("ask") or ""
        if len(d.get("keys") or []) > 1:
            return self.send_page(200, page("Provide %s" % d["key"], keys_form(d, who, ask)))
        body = ("<h1>%s needs %s</h1>" % (who, html.escape(d["key"])) +
                ("<p class=ask>%s</p>" % html.escape(ask) if ask else "") +
                "<form method=post autocomplete=off>"
                # A textarea masked by CSS, never type=password: browsers offer to save every
                # password field, and this value is not the owner's login (lodar 10-02). A
                # textarea because some values are long or span lines (a PEM key, JSON, the
                # three labelled lines OVH shows), and a one-line input flattens newlines
                # to spaces (DIVE-5384).
                "<textarea name=value class=secret rows=6 autocomplete=off autocapitalize=off "
                "autocorrect=off spellcheck=false data-1p-ignore data-lpignore=true data-bwignore "
                "required autofocus aria-label='Paste the value'></textarea>"
                "<button type=submit>Save on the server</button></form>"
                "<p><small>This page is served by your own server. The value goes only there, "
                "saved as <code>%s</code> in <code>%s.env</code>, and this link then stops working. "
                "Expires at %s UTC.</small></p>" % (html.escape(d["key"]), html.escape(d["connector"]),
                time.strftime("%H:%M", time.gmtime(int(d["expires"])))))
        return self.send_page(200, page("Provide %s" % d["key"], body))
    do_HEAD = do_GET
    def do_POST(self):
        if limited(self.client()):
            return self.send_page(429, page("Too many tries", "<h1>Too many tries</h1><p>Wait a few minutes.</p>"))
        h = self.token_hash()
        if not h: return self.gone(4)
        n = self.headers.get("Content-Length")
        if n is None or not n.isdigit() or int(n) > MAX_BODY:
            return self.send_page(413, page("Too long", "<h1>That is too long</h1><p>Nothing was saved.</p>"))
        raw = self.rfile.read(int(n))
        form = urllib.parse.parse_qs(raw.decode("utf-8", "replace"), keep_blank_values=True)
        raw = None
        # A form sends every line break in a textarea as CRLF, whatever was pasted.
        # Back to LF, so a pasted PEM or JSON lands as the owner copied it.
        def field(k):
            return form.get(k, [""])[0].replace("\r\n", "\n").replace("\r", "\n")
        pair = "password" in form
        multi = "k0" in form
        if multi:
            # DIVE-7184: one line per box, in the page's order; the box checks
            # each against its rule before it writes any.
            vals = []
            for i in range(8):
                if "k%d" % i not in form: break
                vals.append(field("k%d" % i).strip())
            value = None
            if vals and all(vals) and not any("\n" in v for v in vals):
                value = "".join(v + "\n" for v in vals)
            vals = None
        elif pair:
            # DIVE-6973: three one-line fields, handed to the box as three lines.
            # A password keeps its own spaces; only the line ends go.
            login, password, totp = field("login").strip(), field("password").strip("\n"), field("totp").strip()
            value = None
            if login and password.strip() and "\n" not in login + password + totp:
                value = "%s\n%s\n%s\n" % (login, password, totp)
            login = password = totp = None
        else:
            value = field("value").strip()
        form = None
        if not value:
            return self.send_page(400, page("Not saved", "<h1>Not saved</h1><p>%s The link still works.</p>"
                % ("Every box is needed, one line each." if multi else
                   "Each of login and password is needed, one line each." if pair else "Nothing was pasted.")))
        rc, out = run(["_peek", "--hash=" + h])
        if rc != 0:
            value = None
            return self.gone(rc)
        what = json.loads(out).get("data", {})
        if pair != bool(what.get("pair")) or (multi and value.count("\n") != len(what.get("keys") or [])) \
                or (not multi and len(what.get("keys") or []) > 1):
            # A form from another page: never write half an item into this one.
            value = None
            return self.send_page(400, page("Not saved", "<h1>Not saved</h1><p>Open the link again and use "
                "the form it shows. The link still works.</p>"))
        rc, out = run(["_redeem", "--hash=" + h], stdin=value.encode())
        value = None
        if rc == 3:
            # DIVE-6727: name the rule the paste broke (static, from _peek, by the
            # gate's connector), never the value and never what the write said.
            rule = what.get("rule") or "The server refused that value."
            return self.send_page(400, page("Not saved", "<h1>Not saved</h1><p>%s</p>"
                "<p>The link still works.</p>" % html.escape(rule)))
        if rc == 6:
            # Saved, but the task row did not take the clear: never claim the task
            # moved. DIVE-5772: never ask the owner to do anything either — the box
            # has already told the agent itself.
            return self.send_page(200, page("Saved", "<h1>Saved on your server</h1><p><code>%s</code> is saved, "
                "and your agent has been told it is there. Nothing else to do. You can close this tab.</p>"
                % html.escape(", ".join(what.get("keys") or [what.get("key", "The value")]))))
        if rc == RAN_LONG:
            # The value may well be on the server by now: the write comes first and
            # the link may already be burned, so "try the link again" would be wrong.
            return self.send_page(504, page("Not sure yet", "<h1>Not sure it saved</h1><p>Your server is still "
                "working on it. It may have been saved. Ask your agent before trying again.</p>"))
        if rc != 0: return self.gone(rc)
        d = json.loads(out).get("data", {})
        if d.get("save") and pair:
            return self.send_page(200, page("Saved", "<h1>Saved</h1><p><b>%s</b> is on your server now. "
                "Your agents can sign in with it; nobody can see the password. You can close this tab.</p>"
                % html.escape(d["save"])))
        if d.get("save"):
            return self.send_page(200, page("Saved", "<h1>Saved</h1><p><b>%s</b> is on your server now. "
                "Your agents can type it into a site; nobody can see it. You can close this tab.</p>"
                % html.escape(d["save"])))
        return self.send_page(200, page("Saved", "<h1>Saved</h1><p>%s %s on your server now, and %s has been told. "
            "You can close this tab.</p>" % (html.escape(d.get("key", "The value").replace(",", ", ")),
            "are" if "," in d.get("key", "") else "is", html.escape(d.get("task", "the task")))))
    def other(self):
        return self.send_page(405, page("Not allowed", "<h1>Not allowed</h1>"))
    do_PUT = do_PATCH = do_DELETE = other

def live_links():
    now = time.time()
    try:
        for name in os.listdir(STORE):
            try:
                with open(os.path.join(STORE, name)) as fh:
                    for line in fh:
                        if line.startswith("expires=") and int(line[8:].strip()) > now: return True
            except (OSError, ValueError): pass
    except OSError: pass
    return False

def idle_watch(srv):
    quiet = 0
    while True:
        time.sleep(15)
        quiet = 0 if live_links() else quiet + 15
        if IDLE and quiet >= IDLE:
            srv.shutdown(); return

if __name__ == "__main__":
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    threading.Thread(target=idle_watch, args=(srv,), daemon=True).start()
    sys.stderr.write("secret drop page on http://%s:%d\n" % (HOST, PORT)); sys.stderr.flush()
    srv.serve_forever()
PY
}
