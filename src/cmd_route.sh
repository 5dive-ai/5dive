# ── DIVE-5396: `5dive route add|rm|ls` — put an agent's app online ───────────
#
# A static page needs no route (/srv/sites, DIVE-5167). An app with its own
# backend needs Caddy to proxy to it, and until now only the claude seat could
# do that, by piping a WHOLE Caddyfile into `sudo 5dive-write-caddyfile`. That
# helper is free-form on purpose and must stay off agents: a free-form Caddyfile
# can drop the /shell/* handle's protection.
#
# So this verb does exactly one shape of edit, and any agent can run it:
#   route add <name>  --port=N   ->  <name>.<FIVE_DOMAIN> { reverse_proxy 127.0.0.1:N }
#   route add /<name> --port=N   ->  handle_path /<name>/* inside the main site
#   route rm  <name>|/<name>     ->  removes a block this verb added (yours only)
#   route ls                     ->  the blocks this verb added
# Each block is fenced by `# 5dive-route:begin/end` comments, so rm can never
# touch a block it did not write. The box's own names are refused, and a seat
# may only publish a port IT is listening on: a route to shelld's port (3101)
# would put a shell on the internet with no login in front of it.
#
# Root half: `_route_do`, one exact-path NOPASSWD line in every standard seat's
# sudoers (render_standard_sudoers). The operation travels NUL-separated on
# stdin and the seat is derived from SUDO_UID, so no argument names the owner.
# The candidate file is validated with `caddy validate` (caddy_validate: with the
# unit's EnvironmentFiles loaded, DIVE-5430) before it replaces the
# live one, and a failed reload restores the previous file.

# Test seams. Under sudo (root, SUDO_UID set) they are ignored whatever the
# environment carries, ROUTE_RELOAD_CMD (an eval) above all: env_reset strips
# them today, and the root half must not depend on that staying true.
# $1 stands in for a root euid in the harness; it can only narrow (reset to defaults).
_route_trust_env() {
  [[ $EUID -eq 0 || "${1:-}" == 0 ]] || return 0
  [[ -n "${SUDO_UID:-}" ]] || return 0
  ROUTE_CADDYFILE=/etc/caddy/Caddyfile ROUTE_PROVISIONING=/etc/5dive/provisioning.env
  ROUTE_CADDY_BIN=caddy ROUTE_LOCK=/run/5dive-route.lock
  unset ROUTE_RELOAD_CMD
}
ROUTE_CADDYFILE="${ROUTE_CADDYFILE:-/etc/caddy/Caddyfile}"
ROUTE_PROVISIONING="${ROUTE_PROVISIONING:-/etc/5dive/provisioning.env}"
ROUTE_CADDY_BIN="${ROUTE_CADDY_BIN:-caddy}"
ROUTE_LOCK="${ROUTE_LOCK:-/run/5dive-route.lock}"
_route_trust_env
# Names the box itself serves or will serve. A subdomain block for one of these
# would shadow (or be shadowed by) the box's own.
ROUTE_RESERVED_SUBS=" shell secrets paperclip buzz relay www mail api admin dashboard "
# Path prefixes the main site already routes (services.sh, agent-sites.sh).
ROUTE_RESERVED_PATHS=" shell browser s a files api "
# The box's own backends. Refused for every caller, root included, so a typo
# cannot publish one of them; a seat is also held to ports it listens on.
ROUTE_RESERVED_PORTS=" 2019 3101 3106 3127 5432 6379 "

_route_name_ok() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]]; }

# FIVE_DOMAIN from provisioning, only in a shape safe to put in a Caddyfile.
_route_domain() {
  local d=""
  [[ -r "$ROUTE_PROVISIONING" ]] && d=$(sed -n 's/^FIVE_DOMAIN=//p' "$ROUTE_PROVISIONING" | tail -1)
  d="${d%\"}"; d="${d#\"}"
  [[ "$d" =~ ^[a-z0-9_]([a-z0-9_.-]*[a-z0-9])?$ && "$d" == *.* ]] || return 1
  printf '%s' "$d"
}

# _route_url <name|/name> — the public link a route answers on.
_route_url() {
  local d; d=$(_route_domain) || d="<your-domain>"
  if [[ "$1" == /* ]]; then printf 'https://%s%s/' "$d" "$1"; else printf 'https://%s.%s/' "$1" "$d"; fi
}

# The managed blocks: one "<name> <port> <by>" line each.
_route_list_lines() {
  local cf="${1:-$ROUTE_CADDYFILE}"
  [[ -r "$cf" ]] || return 0
  sed -n 's/^[[:space:]]*# 5dive-route:begin \([^ ]*\) port=\([0-9]*\) by=\([a-z0-9_-]*\)$/\1 \2 \3/p' "$cf"
}

# _route_taken <caddyfile> <name|/name> <domain> — true when the name is
# already served, by this verb or by anything else in the file.
_route_taken() {
  local cf="$1" name="$2" d="$3" n rows
  rows=$(_route_list_lines "$cf")
  while read -r n _; do [[ -n "$n" && "$n" == "$name" ]] && return 0; done <<<"$rows"
  if [[ "$name" == /* ]]; then
    grep -qE "^[[:space:]]*(handle|handle_path|route|redir)[[:space:]]+${name}(/|\\*|[[:space:]]|\$)" "$cf"
  else
    grep -qE "^[[:space:]]*(https?://)?${name}\\.${d//./\\.}(:[0-9]+)?[[:space:]]*(,|\\{|\$)" "$cf"
  fi
}

# _route_port_owner_ok <port> <uid> — every process listening on the port runs
# as <uid>. Root-side only (ss -p sees other users' sockets only as root).
_route_port_owner_ok() {
  local port="$1" uid="$2" line pid seen=0 puid socks
  socks=$(ss -Hltnp "( sport = :${port} )" 2>/dev/null)
  while IFS= read -r line; do
    while [[ "$line" =~ pid=([0-9]+) ]]; do
      pid="${BASH_REMATCH[1]}"; line="${line/pid=${pid}/}"
      puid=$(stat -c %u "/proc/$pid" 2>/dev/null) || return 1
      [[ "$puid" == "$uid" ]] || return 1
      seen=1
    done
  done <<<"$socks"
  (( seen ))
}

# _route_reload — apply the validated file. A synchronous reload: the verb is
# run from an agent's shell, never through the box's /shell proxy.
_route_reload() {
  [[ -n "${ROUTE_RELOAD_CMD:-}" ]] && { eval "$ROUTE_RELOAD_CMD"; return; }
  systemctl reload caddy >/dev/null 2>&1
}

# _route_apply <candidate> — validate, swap in, reload; on any failure the live
# file is left (or put back) exactly as it was.
_route_apply() {
  local cand="$1" cf="$ROUTE_CADDYFILE" bak
  local out
  if ! out=$(caddy_validate "$cand" "$ROUTE_CADDY_BIN" 2>&1); then
    rm -f "$cand"
    fail "$E_VALIDATION" "the new route did not pass caddy validate; nothing changed ($(caddy_validate_why "$out"))"
  fi
  bak=$(mktemp "${cf}.route.XXXXXX") || { rm -f "$cand"; fail "$E_GENERIC" "could not back up $cf"; }
  cp -p "$cf" "$bak"
  chmod 644 "$cand"; chown --reference="$cf" "$cand" 2>/dev/null || true
  mv -f "$cand" "$cf"
  if ! _route_reload; then
    mv -f "$bak" "$cf"; _route_reload || true
    fail "$E_GENERIC" "caddy did not reload with the new route; the previous Caddyfile is back"
  fi
  rm -f "$bak"
}

_route_usage() {
  printf '%s\n' \
    "usage: 5dive route add <name>|/<name> --port=<port>   # publish an app you run on 127.0.0.1:<port>" \
    "       5dive route rm  <name>|/<name>                 # take down a route you added" \
    "       5dive route ls  [--json]                       # the routes added this way" \
    "" \
    "  <name>   https://<name>.<your-domain>/  (its own subdomain)" \
    "  /<name>  https://<your-domain>/<name>/  (a path; the app sees paths from /)" \
    "  Start the app first: a route is refused for a port you are not listening on."
}

cmd_route() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    add|rm|remove|ls|list) ;;
    -h|--help|"") _route_usage; return 0 ;;
    *) fail "$E_USAGE" "unknown route subcommand '$sub' (add, rm, ls)" ;;
  esac
  local name="" port="" a
  for a in "$@"; do
    case "$a" in
      --json) JSON_MODE=1 ;;
      --port=*) port="${a#*=}" ;;
      -*) fail "$E_USAGE" "unknown flag: $a" ;;
      *) [[ -z "$name" ]] || fail "$E_USAGE" "one route at a time"; name="$a" ;;
    esac
  done

  if [[ "$sub" == ls || "$sub" == list ]]; then
    local rows; rows=$(_route_list_lines)
    if (( ${JSON_MODE:-0} )); then
      local out="[]" n p by
      while read -r n p by; do
        [[ -n "$n" ]] || continue
        out=$(jq -c --arg n "$n" --argjson p "$p" --arg b "$by" --arg u "$(_route_url "$n")" \
          '. + [{name:$n, port:$p, by:$b, url:$u}]' <<<"$out")
      done <<<"$rows"
      ok "routes" '{routes:$r}' --argjson r "$out"
    else
      [[ -n "$rows" ]] || { echo "no routes added with 5dive route"; return 0; }
      local n p by
      while read -r n p by; do printf '%-20s port %-5s by %-12s %s\n' "$n" "$p" "$by" "$(_route_url "$n")"; done <<<"$rows"
    fi
    return 0
  fi

  [[ "$sub" == remove ]] && sub=rm
  [[ -n "$name" ]] || fail "$E_USAGE" "$(_route_usage | head -2 | tail -1 | sed 's/^ *//')"
  if [[ "$sub" == add ]]; then
    [[ "$port" =~ ^[0-9]+$ ]] || fail "$E_USAGE" "route add needs --port=<port> (the port your app listens on)"
  else
    [[ -z "$port" ]] || fail "$E_USAGE" "route rm takes no --port"
  fi

  # Root runs it in-process (SUDO_UID is sudo's stamp, read only under this guard);
  # a non-root caller crosses the scoped root rail.
  if [[ $EUID -eq 0 ]]; then
    _route_exec "$sub" "$name" "$port" "${SUDO_UID:-0}"
    return
  fi
  local mode=text rc=0
  (( ${JSON_MODE:-0} )) && mode=json
  if [[ "$sub" == add ]]; then
    printf '%s\0' "$mode" add "$name" "$port" | sudo -n /usr/local/bin/5dive _route_do || rc=$?
  else
    printf '%s\0' "$mode" rm "$name" | sudo -n /usr/local/bin/5dive _route_do || rc=$?
  fi
  (( rc == 0 )) || mark_reported
  exit "$rc"
}

# Root half. Reached ONLY through the exact-path NOPASSWD grant (or by root).
cmd_route_delegated() {
  _gate_is_root || fail "$E_PERMISSION" "_route_do is a privileged internal primitive (reachable only through the exact-path NOPASSWD grant)."
  [[ $# -eq 0 ]] || fail "$E_USAGE" "_route_do takes no arguments (the operation is read from stdin, the caller from sudo)."
  local -a wire=(); local a
  while IFS= read -r -d '' a; do wire+=("$a"); done
  (( ${#wire[@]} >= 3 )) || fail "$E_VALIDATION" "_route_do requires an output mode, an operation and a name on stdin."
  case "${wire[0]}" in json) JSON_MODE=1 ;; text) JSON_MODE=0 ;; *) fail "$E_VALIDATION" "_route_do output mode must be json or text." ;; esac
  case "${wire[1]}" in
    add) (( ${#wire[@]} == 4 )) || fail "$E_VALIDATION" "_route_do add takes a name and a port." ;;
    rm)  (( ${#wire[@]} == 3 )) || fail "$E_VALIDATION" "_route_do rm takes a name." ;;
    *)   fail "$E_VALIDATION" "_route_do allows only add or rm." ;;
  esac
  _route_exec "${wire[1]}" "${wire[2]}" "${wire[3]:-}" "${SUDO_UID:-0}"
}

# _route_exec <add|rm> <name> <port> <caller uid> — runs as root.
_route_exec() {
  _route_trust_env
  local op="$1" name="$2" port="$3" uid="$4" by="" privileged=0
  [[ "$uid" =~ ^[0-9]+$ ]] || fail "$E_AUTH_REQUIRED" "route: no caller uid"
  if [[ "$uid" == 0 ]]; then
    by=root; privileged=1
  elif [[ "$(getent passwd "$uid" | cut -d: -f1)" == claude ]]; then
    # The claude seat already holds unrestricted sudo; holding it to its own
    # listeners would protect nothing.
    by=claude; privileged=1
  else
    by=$(_gate_uid_to_agent "$uid")
    [[ -n "$by" ]] || fail "$E_AUTH_REQUIRED" "route: caller uid ${uid} is not an agent seat"
  fi

  local bare="${name#/}" kind=sub
  [[ "$name" == /* ]] && kind=path
  _route_name_ok "$bare" || fail "$E_VALIDATION" "route name '${name:0:40}': lowercase letters, digits and dashes, up to 32 (e.g. myapp or /myapp)"
  local cf="$ROUTE_CADDYFILE" domain
  [[ -f "$cf" ]] || fail "$E_NOT_FOUND" "no Caddyfile at $cf (this box does not serve a public domain)"
  domain=$(_route_domain) || fail "$E_NOT_FOUND" "this box has no public domain (FIVE_DOMAIN in $ROUTE_PROVISIONING)"

  # One writer at a time; best-effort (no lock dir means no concurrent writer).
  { exec 9>"$ROUTE_LOCK"; } 2>/dev/null && flock -w 30 9 2>/dev/null || true

  if [[ "$op" == rm ]]; then
    local n p owner found="" rows
    rows=$(_route_list_lines "$cf")
    while read -r n p owner; do [[ -n "$n" && "$n" == "$name" ]] && found="$owner"; done <<<"$rows"
    [[ -n "$found" ]] || fail "$E_NOT_FOUND" "no route '$name' added with 5dive route (route ls lists them)"
    (( privileged )) || [[ "$found" == "$by" ]] \
      || fail "$E_PERMISSION" "route '$name' belongs to ${found}; only it (or the claude seat) can remove it"
    local cand; cand=$(mktemp "${cf}.new.XXXXXX") || fail "$E_GENERIC" "could not stage $cf"
    # The blank line add put above the block goes with it, so add then rm
    # leaves the file byte for byte as it was.
    awk -v n="$name" '
      { line = $0; sub(/^[ \t]+/, "", line) }
      line ~ "^# 5dive-route:begin " && $3 == n { skip = 1; held = 0; next }
      skip { if (line == "# 5dive-route:end " n) skip = 0; next }
      held { print ""; held = 0 }
      $0 == "" { held = 1; next }
      { print }
      END { if (held) print "" }' "$cf" > "$cand"
    _route_apply "$cand"
    audit_log "_route_do rm" ok 0 -- "by=$by" "$name"
    ok "removed route $name" '{name:$n, removed:true}' --arg n "$name"
    return 0
  fi

  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 )) \
    || fail "$E_VALIDATION" "port must be 1024-65535 (got '${port:0:12}')"
  [[ "$ROUTE_RESERVED_PORTS" != *" $port "* ]] \
    || fail "$E_PERMISSION" "port $port is one of the box's own services; publish your app's port"
  if [[ "$kind" == sub ]]; then
    [[ "$ROUTE_RESERVED_SUBS" != *" $bare "* ]] || fail "$E_PERMISSION" "'$bare' is reserved for the box itself; pick another name"
  else
    [[ "$ROUTE_RESERVED_PATHS" != *" $bare "* ]] || fail "$E_PERMISSION" "'/$bare' is reserved for the box itself; pick another path"
  fi
  _route_taken "$cf" "$name" "$domain" && fail "$E_CONFLICT" "'$name' is already routed on this box (route ls; route rm it first if it is yours)"
  if (( ! privileged )); then
    _route_port_owner_ok "$port" "$uid" \
      || fail "$E_PERMISSION" "nothing of yours is listening on port $port; start the app on 127.0.0.1:$port first"
  fi

  local cand; cand=$(mktemp "${cf}.new.XXXXXX") || fail "$E_GENERIC" "could not stage $cf"
  if [[ "$kind" == sub ]]; then
    { cat "$cf"; printf '\n# 5dive-route:begin %s port=%s by=%s\n%s.%s {\n    reverse_proxy 127.0.0.1:%s\n}\n# 5dive-route:end %s\n' \
        "$name" "$port" "$by" "$name" "$domain" "$port" "$name"; } > "$cand"
  else
    # Inside the main site, before its `handle /files/* {` (the anchor the
    # box's own heals insert at), at that block's indent.
    local ind
    ind=$(sed -n 's/^\([[:space:]]\{1,\}\)handle \/files\/\* {.*/\1/p' "$cf" | head -1)
    if [[ -z "$ind" ]]; then
      rm -f "$cand"
      fail "$E_NOT_FOUND" "this box's Caddyfile has no main-site anchor for a path route; use a subdomain (route add $bare --port=$port)"
    fi
    awk -v i="$ind" -v n="$name" -v p="$port" -v b="$by" '
      !done && $0 ~ /^[ \t]+handle \/files\/\* \{/ {
        print i "# 5dive-route:begin " n " port=" p " by=" b
        print i "redir " n " " n "/ 308"
        print i "handle_path " n "/* {"
        print i i "reverse_proxy 127.0.0.1:" p
        print i "}"
        print i "# 5dive-route:end " n
        done = 1
      }
      { print }' "$cf" > "$cand"
  fi
  _route_apply "$cand"
  audit_log "_route_do add" ok 0 -- "by=$by" "$name" "--port=$port"
  local url; url=$(_route_url "$name")
  ok "$url -> 127.0.0.1:$port (a new subdomain can take a minute for its certificate)" \
    '{name:$n, port:$p, url:$u}' --arg n "$name" --argjson p "$port" --arg u "$url"
}
