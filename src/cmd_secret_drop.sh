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
# DIVE-5372: how long `secret link` waits for its page to answer over valid TLS
# before it hands the URL out. Under the 30s the dashboard's exec call allows
# (shelld's default), so a slow first certificate degrades to ready:false
# instead of a dead request. ACME on a fresh name took ~4s on chill-gorge.
SECRET_DROP_WAIT_S="${SECRET_DROP_WAIT_S:-20}"
SECRET_DROP_POLL_S="${SECRET_DROP_POLL_S:-1}"
SECRET_DROP_PROBE_ADDR="${SECRET_DROP_PROBE_ADDR:-127.0.0.1}"

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
  domain=$(_secret_drop_domain) || return 1
  printf 'https://secrets.%s' "$domain"
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
  local ref="" ttl="$SECRET_DROP_TTL_MIN" start=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ttl=*)     ttl="${1#*=}" ;;
      --no-start)  start=0 ;;   # tests / a box whose page is supervised elsewhere
      --*)         fail "$E_USAGE" "unknown flag: $1" ;;
      *)           [[ -z "$ref" ]] && ref="$1" || fail "$E_USAGE" "unexpected argument: $1" ;;
    esac
    shift
  done
  require_root secret link
  [[ -n "$ref" ]] || fail "$E_USAGE" "usage: 5dive secret link <DIVE-N> [--ttl=<minutes>] [--json]"
  [[ "$ttl" =~ ^[0-9]+$ ]] && (( ttl >= 1 && ttl <= 60 )) || fail "$E_VALIDATION" "--ttl must be 1-60 minutes"

  resolve_task_id "$ref"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  local row nt answered key connector
  row=$(db "SELECT COALESCE(need_type,'')||x'1f'||COALESCE(need_answered_at,'')||x'1f'||COALESCE(secret_key,'')||x'1f'||COALESCE(connector,'') FROM tasks WHERE id=${id};")
  IFS=$'\x1f' read -r nt answered key connector <<<"$row"
  [[ "$nt" == "secret" ]] || fail "$E_CONFLICT" "$ident has no secret gate open"
  [[ -z "$answered" ]]    || fail "$E_CONFLICT" "$ident secret gate is already answered"
  [[ -n "$key" && -n "$connector" ]] \
    || fail "$E_CONFLICT" "$ident names no place on this box for the value (it was filed --out-of-band), so a link has nowhere to write it"
  _valid_env_key "$key" && _valid_connector "$connector" \
    || fail "$E_VALIDATION" "$ident drop target is malformed (${key} -> ${connector})"

  local base
  base=$(_secret_drop_base_url) \
    || fail "$E_NOT_INSTALLED" "this box has no https name an owner's browser can reach (no FIVE_DOMAIN in $SECRET_DROP_PROVISIONING, no SECRET_DROP_BASE_URL in $SECRET_DROP_CONF). Use the terminal instead: sudo 5dive secret write ${key} --connector=${connector} --task=${ident}"

  ( umask 077; mkdir -p "$SECRET_DROP_DIR" ) || fail "$E_GENERIC" "cannot create $SECRET_DROP_DIR"
  chmod 700 "$SECRET_DROP_DIR" 2>/dev/null || true
  _secret_drop_gc

  local token hash exp
  token=$(_secret_drop_token)
  [[ ${#token} -ge 43 ]] || fail "$E_GENERIC" "could not read 32 random bytes"
  hash=$(_secret_drop_hash "$token")
  exp=$(( $(date +%s) + ttl * 60 ))
  ( umask 077; printf 'task=%s\nkey=%s\nconnector=%s\nexpires=%s\n' "$ident" "$key" "$connector" "$exp" > "$SECRET_DROP_DIR/$hash" ) \
    || fail "$E_GENERIC" "cannot store the link"

  # DIVE-5372: the first link on a box appends the secrets.<domain> route and
  # DEFERS the reload, and Caddy only then asks ACME for the certificate. A URL
  # handed out before that ends in ERR_SSL_PROTOCOL_ERROR on the owner's first
  # tap (lodar on chill-gorge, 2026-10-02 05:34Z). So wait, bounded, until the
  # page answers over valid TLS; past the bound, still return the link, marked
  # ready:false, so the caller can say "getting your secure page ready".
  # "null" = not checked: --no-start, or a SECRET_DROP_BASE_URL (the owner's own
  # tunnel, which this box may not be able to reach by its public name).
  local ready=null
  if (( start )); then
    _secret_drop_ensure_route || true
    _secret_drop_ensure_server || true
    local domain
    if ! _secret_drop_has_base_url && domain=$(_secret_drop_domain); then
      _secret_drop_wait_ready "$domain" "$SECRET_DROP_WAIT_S" && ready=true || ready=false
    fi
  fi

  local url="${base}/${token}" exp_iso note=""
  exp_iso=$(date -u -d "@$exp" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$exp" '+%Y-%m-%dT%H:%M:%SZ')
  [[ "$ready" == false ]] && note="
not ready yet: the secure page is still getting its certificate. If the link does not open, wait a minute and open it again (it stays valid)."
  ok "$url
single use, expires ${exp_iso} (${ttl} min); the value lands as ${key} in ${connector}.env and clears ${ident}${note}" \
     '{url: $u, expires_at: $e, ttl_minutes: ($t|tonumber), task: $i, key: $k, connector: $c, ready: ($r|fromjson)}' \
     --arg u "$url" --arg e "$exp_iso" --arg t "$ttl" --arg i "$ident" --arg k "$key" --arg c "$connector" --arg r "$ready"
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
  local id; id=$(_secret_drop_gate_open "$ident" "$key" "$connector")
  if [[ -z "$id" ]]; then
    _secret_drop_burn_task "$ident"; fail "$E_CONFLICT" "gate no longer open"
  fi
  local ask agent
  ask=$(db "SELECT COALESCE(ask,'') FROM tasks WHERE id=${id};")
  # The seat that filed the gate is the one asking; the assignee can differ (a
  # box's routing may move the row), which made the page name the wrong agent.
  agent=$(db "SELECT COALESCE(NULLIF(gate_filed_by,''),assignee,'') FROM tasks WHERE id=${id};")
  ok "$ident $key" '{task: $i, key: $k, connector: $c, ask: $a, agent: $g, expires: ($x|tonumber)}' \
     --arg i "$ident" --arg k "$key" --arg c "$connector" --arg a "$ask" --arg g "$agent" --arg x "$exp"
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
  if [[ -z "$(_secret_drop_gate_open "$ident" "$key" "$connector")" ]]; then
    _secret_drop_burn_task "$ident"; fail "$E_CONFLICT" "gate no longer open"
  fi
  # The write reads stdin and refuses an empty value BEFORE it touches the file;
  # a refusal leaves the link live for a corrected paste. Its
  # own output is discarded: nothing it says may reach the page but the outcome.
  local rc=0 id
  id=$(_secret_drop_gate_open "$ident" "$key" "$connector")
  ( _secret_write "$key" --connector="$connector" ) >/dev/null 2>&1 || rc=$?
  if (( rc != 0 )); then
    fail "$E_VALIDATION" "value refused (empty, or a newline, space or quote in a tools key)"
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
  grep -qE "^secrets\.${domain//./\\.}[[:space:]]*\{" "$cf" && return 0
  local bak; bak=$(mktemp "${cf}.dive5319.XXXXXX") || return 1
  cp -p "$cf" "$bak" || { rm -f "$bak"; return 1; }
  cat >> "$cf" <<EOF

# DIVE-5319: one-time secret drop links (5dive secret link). Its own name, so TLS
# ends on this box: the root name is proxied by Cloudflare, *.<domain> is not.
secrets.${domain} {
    reverse_proxy 127.0.0.1:${SECRET_DROP_PORT}
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
  body=$(curl -fsS --max-time 3 --resolve "secrets.${domain}:443:${SECRET_DROP_PROBE_ADDR}" \
    "https://secrets.${domain}/healthz" 2>/dev/null) || return 1
  [[ "$body" == *'"ok":true'* ]]
}

# Poll _secret_drop_ready until it holds or <seconds> pass. rc 0 = ready.
_secret_drop_wait_ready() {
  local domain="$1" secs="$2" deadline
  [[ "$secs" =~ ^[0-9]+$ ]] || secs=20
  deadline=$(( $(date +%s) + secs ))
  while :; do
    _secret_drop_ready "$domain" && return 0
    (( $(date +%s) >= deadline )) && return 1
    sleep "$SECRET_DROP_POLL_S"
  done
}

# Start the page if nothing answers on its port. It exits by itself once no link
# is live, so a box carries no listener between gates.
_secret_drop_ensure_server() {
  curl -fsS --max-time 2 "http://127.0.0.1:${SECRET_DROP_PORT}/healthz" >/dev/null 2>&1 && return 0
  command -v python3 >/dev/null 2>&1 || { warn "secret drop: python3 missing, the page cannot start"; return 1; }
  local self; self="$(five_self_bundle || true)"
  [[ -n "$self" ]] || { warn "secret drop: could not find the 5dive bundle"; return 1; }
  if command -v systemd-run >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl reset-failed 5dive-secret-drop.service >/dev/null 2>&1 || true
    systemd-run --quiet --collect --unit=5dive-secret-drop \
      -p PrivateTmp=yes -p NoNewPrivileges=yes \
      "$self" secret serve >/dev/null 2>&1 && return 0
  fi
  setsid nohup "$self" secret serve >/dev/null 2>&1 < /dev/null &
  return 0
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
       "button{width:100%;font:inherit;font-weight:600;padding:.75rem;border:0;border-radius:8px;background:#1b1b1a;color:#fff}"
       "small{color:#666}code{font-size:.9em}"
       "@media (prefers-color-scheme:dark){body{background:#151514;color:#eee}.ask{background:#1f1f1e;border-color:#333}"
       "textarea{background:#1f1f1e;color:#eee;border-color:#444}button{background:#eee;color:#151514}small{color:#aaa}}")

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

def run(args, stdin=None):
    try:
        p = subprocess.run([BUNDLE, "secret"] + args + ["--json"], input=stdin,
                           capture_output=True, timeout=60)
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired:
        return 1, b""

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
        who = html.escape(d.get("agent") or "Your agent")
        ask = d.get("ask") or ""
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
        vals = urllib.parse.parse_qs(raw.decode("utf-8", "replace"), keep_blank_values=True).get("value", [""])
        raw = None
        # A form sends every line break in a textarea as CRLF, whatever was pasted.
        # Back to LF, so a pasted PEM or JSON lands as the owner copied it.
        value = vals[0].replace("\r\n", "\n").replace("\r", "\n").strip()
        vals = None
        if not value:
            return self.send_page(400, page("Not saved", "<h1>Not saved</h1><p>Nothing was pasted. The link still works.</p>"))
        rc, out = run(["_peek", "--hash=" + h])
        if rc != 0:
            value = None
            return self.gone(rc)
        what = json.loads(out).get("data", {})
        rc, out = run(["_redeem", "--hash=" + h], stdin=value.encode())
        value = None
        if rc == 3:
            return self.send_page(400, page("Not saved", "<h1>Not saved</h1><p>The server refused that value. The link still works.</p>"))
        if rc == 6:
            # Saved, but the task row did not take the clear: never claim the task
            # moved. DIVE-5772: never ask the owner to do anything either — the box
            # has already told the agent itself.
            return self.send_page(200, page("Saved", "<h1>Saved on your server</h1><p><code>%s</code> is saved, "
                "and your agent has been told it is there. Nothing else to do. You can close this tab.</p>"
                % html.escape(what.get("key", "The value"))))
        if rc != 0: return self.gone(rc)
        d = json.loads(out).get("data", {})
        return self.send_page(200, page("Saved", "<h1>Saved</h1><p>%s is on your server now, and %s has been told. "
            "You can close this tab.</p>" % (html.escape(d.get("key", "The value")), html.escape(d.get("task", "the task")))))
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
