# ── DIVE-7558: the office chat server — `5dive local serve|pair|devices|status` ─
#
# A local-only box (DIVE-7557) has no chat page: the hosted app and api.5dive.com
# are outside the office. This serves one from the box itself:
#
#   sudo 5dive local serve [--addr=<office IP>] [--port=8443]   start it (local-only on runs this)
#   sudo 5dive local serve --stop                               stop it, put the API base back
#   sudo 5dive local pair [--owner]                             one-time code + cert fingerprint
#                                                               (--owner: the device may also open /panel, DIVE-7576)
#   sudo 5dive local devices ls | revoke <id>                   who is let in
#        5dive local status
#
# HOW THE AGENT SIDE STAYS UNCHANGED. The server answers the same endpoints the
# dashboard adapter's root rail calls on api.5dive.com, with the same box-token
# bearer, on a loopback listener. `serve` writes that loopback URL into
# /etc/5dive/api-base, which the root rail reads (sudo resets FIVE_API_BASE, so
# the root-owned file is the only redirect a standard seat cannot forge).
#
# THE UNIT. One systemd service, as a dedicated system user (5dive-chat), never
# root: the box token, the cert and its key reach it as systemd credentials
# (LoadCredential), so the user itself reads none of /etc/5dive. The bun source
# is staged root-owned in /usr/local/lib/5dive/local-chat. Admin steps (a pair
# code, the device list) run the same file as 5dive-chat against its own sqlite.
#
# No end-to-end sealing here: the box is the only server and TLS covers the LAN
# hop. `chat e2e enable` is refused while local-only is on (src/lib/local_only.sh).
#
# Test seams: FIVE_LOCAL_CHAT_ROOT prefixes every path this file writes;
# systemctl/useradd/runuser/openssl/ip are looked up on PATH.
_lc_root()   { printf '%s' "${FIVE_LOCAL_CHAT_ROOT:-}"; }
_lc_etc()    { printf '%s/etc/5dive/local-chat' "$(_lc_root)"; }
_lc_conf()   { printf '%s/config' "$(_lc_etc)"; }
_lc_lib()    { printf '%s/usr/local/lib/5dive/local-chat' "$(_lc_root)"; }
_lc_state()  { printf '%s/var/lib/5dive-local-chat' "$(_lc_root)"; }
_lc_unit()   { printf '%s/etc/systemd/system/5dive-local-chat.service' "$(_lc_root)"; }
_lc_user()   { printf '5dive-chat'; }
_lc_svc()    { printf '5dive-local-chat.service'; }
_lc_bun() {
  local c
  for c in /usr/local/bin/bun /home/claude/.bun/bin/bun "$(command -v bun 2>/dev/null)"; do
    [[ -n "$c" && -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  fail "$E_NOT_INSTALLED" "the office chat runs on bun, and this server has none (the 5dive install puts it at /usr/local/bin/bun)."
}

# _lc_conf_get <KEY> — one value from the config file (KEY=value lines); empty
# and 0 when there is no file yet. DIVE-7566: no pipe, so a missing file is not
# a pipefail exit (that killed the first `local serve` on every box with rc 2).
_lc_conf_get() {
  local f v; f=$(_lc_conf)
  [[ -r "$f" ]] || return 0
  v=$(sed -n "s/^$1=//p" "$f" 2>/dev/null) || v=""
  printf '%s' "${v%%$'\n'*}"
}

# DIVE-7566: the token the agents' chat rail and the office chat share. A box
# linked to 5dive.app has one (connectord.env); a box never linked, which is
# exactly the offline office, gets one minted here, root-only, kept across
# restarts. It is never written to connectord.env: other parts of 5dive read
# that file's presence as "linked to the app".
_lc_minted_token() { printf '%s/token.env' "$(_lc_etc)"; }
_lc_token_file() {
  local f; f=$(_sp_connectord_env)
  if [[ -r "$f" ]] && grep -q '^CONNECTORD_TOKEN=..*' "$f" 2>/dev/null; then printf '%s' "$f"; return 0; fi
  f=$(_lc_minted_token)
  if ! grep -q '^CONNECTORD_TOKEN=..*' "$f" 2>/dev/null; then
    local t; t=$(openssl rand -hex 32 2>/dev/null) || t=""
    [[ "$t" =~ ^[0-9a-f]{64}$ ]] || return 1
    ( umask 077; printf 'CONNECTORD_TOKEN=%s\n' "$t" >"$f.tmp" && mv -f "$f.tmp" "$f" ) || return 1
  fi
  chmod 0600 "$f" 2>/dev/null || true
  printf '%s' "$f"
}

# _lc_token_for_base <api base> <default file> — the token file the root rail
# uses for <api base>: the office chat's own when the base is the loopback
# listener `serve` wrote, else <default>. So a minted token goes ONLY to this
# box's own office chat, never to api.5dive.com.
_lc_token_for_base() {
  local base="${1%/}" def="$2" loop tf
  loop=$(_lc_conf_get LOOP_PORT); tf=$(_lc_conf_get TOKEN_FILE)
  if [[ -n "$loop" && -n "$tf" && "$base" == "http://127.0.0.1:${loop}" && -r "$tf" ]]; then printf '%s' "$tf"
  else printf '%s' "$def"; fi
}

# The office address. A public address is never chosen by itself, so the page
# is not put on the internet by accident.
#
# DIVE-7579 (D1): a box on TWO private networks — the model link (a cable to the
# office's AI computer) and the office LAN — was given the FIRST private address,
# which on the run-5 box was the model link: the office could not open the page,
# and `local-only on` still said ON. Now the network the box uses to reach its
# model server is skipped: every saved AI account's address is routed
# (`ip route get`) and that interface is left out. One private address left → it.
# Still more than one → rc 2, and the caller names the choices and --addr=.
#
# `_lc_private_addrs` — "<iface> <IPv4>" per private address, interface order.
_lc_private_addrs() {
  local ifc a seen=" "
  while read -r ifc a; do
    a="${a%%/*}"
    [[ "$a" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]] || continue
    [[ "$seen" == *" $a "* ]] && continue
    seen+="$a "; printf '%s %s\n' "$ifc" "$a"
  done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2, $4}')
  [[ "$seen" != " " ]] && return 0
  for a in $(hostname -I 2>/dev/null); do
    [[ "$a" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]] && printf '%s %s\n' "?" "$a"
  done
  return 0
}

# `_lc_model_ifaces` — the interface this box reaches each saved model server
# on, one per line (only servers on a private network: those are the model link).
_lc_model_ifaces() {
  local d p u host ip r
  for d in "${AUTH_PROFILES_DIR:-/var/lib/5dive/auth-profiles}"/*/; do
    [[ -d "$d" ]] || continue
    p=$(basename "$d")
    while IFS= read -r u; do
      host="${u#*://}"; host="${host%%/*}"; host="${host##*@}"; host="${host%:*}"
      [[ -n "$host" ]] || continue
      if [[ "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then ip="$host"
      else ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 {print $1}') || ip=""; fi
      [[ -n "$ip" && "$ip" != 127.* ]] || continue
      r=$(ip -4 route get "$ip" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1) || r=""
      [[ -n "$r" ]] && printf '%s\n' "$r"
    done < <(_lo_profile_model_urls "$p")
  done | sort -u
  return 0
}

# `_lc_lan_addr` — prints the office address (rc 0); rc 1 = no private address;
# rc 2 = more than one network could be the office's.
_lc_lan_addr() {
  local -a all=() keep=() model=()
  local l
  mapfile -t all < <(_lc_private_addrs)
  (( ${#all[@]} )) || return 1
  (( ${#all[@]} == 1 )) && { printf '%s' "${all[0]#* }"; return 0; }
  mapfile -t model < <(_lc_model_ifaces)
  for l in "${all[@]}"; do
    [[ " ${model[*]} " == *" ${l%% *} "* ]] || keep+=("$l")
  done
  (( ${#keep[@]} == 1 )) && { printf '%s' "${keep[0]#* }"; return 0; }
  return 2
}

# The refusal when the office network cannot be told: the choices, and the flag.
_lc_addr_ambiguous() {
  local l list=""
  while IFS= read -r l; do
    [[ -n "$l" ]] && list+="${list:+, }${l#* }$([[ "${l%% *}" != "?" ]] && printf ' (%s)' "${l%% *}")"
  done < <(_lc_private_addrs)
  fail "$E_VALIDATION" "local chat: this server is on more than one private network (${list}) and cannot tell which one your office uses, so the chat was NOT started. Name the office one: sudo 5dive local serve --addr=<that address>"
}

_lc_usage() {
  printf '%s\n' \
    "usage: sudo 5dive local serve [--addr=<office IP>] [--port=<port>]   # start the office chat" \
    "       sudo 5dive local serve --stop" \
    "       sudo 5dive local pair [--owner]             # a one-time code to connect a phone or laptop" \
    "                                                   # --owner: it may also manage the server at /panel" \
    "       sudo 5dive local devices ls | revoke <id>" \
    "            5dive local status"
}

cmd_local() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    serve)   _lc_serve "$@" ;;
    pair)    _lc_pair "$@" ;;
    devices) _lc_devices "$@" ;;
    status)  _lc_status "$@" ;;
    _agents) _lc_agents_write ;;
    _restage) _lc_restage ;;       # DIVE-7579 (D6): install.sh --upgrade runs it
    _panel-update-run) _lp_update_run ;;   # DIVE-7579 (D4): the panel's transient update unit
    panel-exec) _lp_exec "$@" ;;   # DIVE-7576: the panel's one root entry (src/cmd_local_panel.sh)
    ""|-h|--help|help) _lc_usage ;;
    *) fail "$E_USAGE" "local: unknown subcommand '$sub' (serve, pair, devices, status)." ;;
  esac
}

# Stage the server source root-owned; rewrite only when it changed.
_lc_stage() {
  local lib tmp
  lib=$(_lc_lib)
  [[ -L "$lib" ]] && fail "$E_PERMISSION" "local chat: $lib is a symlink."
  install -d -m 0755 -- "$lib" || fail "$E_GENERIC" "local chat: cannot create $lib."
  tmp=$(mktemp -p "$lib" ".stage.XXXXXX") || fail "$E_GENERIC" "local chat: cannot write in $lib."
  _local_chat_server_ts >"$tmp"
  if cmp -s -- "$tmp" "$lib/server.ts"; then rm -f -- "$tmp"
  else { chmod 0644 -- "$tmp" && mv -fT -- "$tmp" "$lib/server.ts"; } || fail "$E_GENERIC" "local chat: cannot install $lib/server.ts."; fi
}

# DIVE-7579 (D6): `local _restage` — bring a running office chat to THIS CLI's
# server source and units. install.sh --upgrade runs it after every update, from
# a disk or online: before, only `local serve` wrote server.ts, so a fix to the
# page or the panel never reached a box by update. Restarts the chat only when
# something changed; a box with no office chat is left alone.
_lc_restage() {
  require_root
  [[ -f "$(_lc_unit)" ]] || { printf '%s\n' "not set up on this server (nothing to refresh)"; return 0; }
  local lib changed=0 sock_changed=0 before after
  lib=$(_lc_lib)
  before=$(sha256sum "$lib/server.ts" 2>/dev/null | cut -d' ' -f1) || before=""
  _lc_stage
  after=$(sha256sum "$lib/server.ts" 2>/dev/null | cut -d' ' -f1) || after=""
  [[ "$before" == "$after" ]] || changed=1
  # The unit itself, from the saved settings (a newer CLI may write it differently).
  local addr port loop tokf bun want
  addr=$(_lc_conf_get LAN_ADDR); port=$(_lc_conf_get LAN_PORT); loop=$(_lc_conf_get LOOP_PORT); tokf=$(_lc_conf_get TOKEN_FILE)
  if [[ -n "$addr" && -n "$port" && -n "$loop" && -n "$tokf" ]] && bun=$(_lc_bun 2>/dev/null); then
    want=$(_lc_unit_text "$bun" "$addr" "$port" "$loop" "$tokf")
    if [[ "$want" != "$(cat "$(_lc_unit)" 2>/dev/null)" ]]; then
      printf '%s\n' "$want" >"$(_lc_unit)" && changed=1
    fi
  fi
  # The panel's socket and per-call service.
  if [[ -f "$(_lp_socket_unit)" || -f "$(_lp_service_unit)" ]]; then
    [[ "$(_lp_socket_text)" == "$(cat "$(_lp_socket_unit)" 2>/dev/null)" ]] \
      || { _lp_socket_text >"$(_lp_socket_unit)" && sock_changed=1; }
    [[ "$(_lp_service_text)" == "$(cat "$(_lp_service_unit)" 2>/dev/null)" ]] \
      || { _lp_service_text >"$(_lp_service_unit)" && sock_changed=1; }
  fi
  (( changed || sock_changed )) && { systemctl daemon-reload >/dev/null 2>&1 || true; }
  (( sock_changed )) && { systemctl restart 5dive-local-panel.socket >/dev/null 2>&1 || warn "office panel: could not restart 5dive-local-panel.socket"; }
  if (( changed )); then
    systemctl try-restart "$(_lc_svc)" >/dev/null 2>&1 \
      || fail "$E_GENERIC" "local chat: the new server did not start (journalctl -u $(_lc_svc))."
    printf '%s\n' "refreshed and restarted"
  else
    printf '%s\n' "already current$( (( sock_changed )) && printf ' (panel units refreshed)')"
  fi
}

# A self-signed cert for the office address; remade when the address changed.
_lc_cert() {
  local addr="$1" etc; etc=$(_lc_etc)
  if [[ -s "$etc/cert.pem" && -s "$etc/key.pem" ]] \
     && openssl x509 -in "$etc/cert.pem" -noout -ext subjectAltName 2>/dev/null | grep -qF "IP Address:${addr}"; then
    return 0
  fi
  ( umask 077
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 825 \
      -subj "/CN=5dive office chat" -addext "subjectAltName=IP:${addr}" \
      -keyout "$etc/key.pem" -out "$etc/cert.pem" >/dev/null 2>&1 ) \
    || fail "$E_GENERIC" "local chat: could not make the TLS certificate (openssl)."
  chmod 0644 "$etc/cert.pem"; chmod 0600 "$etc/key.pem"
}

_lc_fingerprint() {
  openssl x509 -in "$(_lc_etc)/cert.pem" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
}

# The agent list the page shows, from the seat registry (root, at each start).
_lc_agents_write() {
  require_root
  local out="$(_lc_etc)/agents.json" names
  names=$("$0" --json agent list 2>/dev/null | jq -c '[.data[]?.name | select(type == "string")]' 2>/dev/null) || names=""
  [[ "$names" == \[* ]] || names='[]'
  printf '%s\n' "$names" >"$out.tmp" && chmod 0644 "$out.tmp" && mv -f "$out.tmp" "$out" \
    || warn "local chat: could not write $out (the page's agent list stays as it was)"
  return 0
}

_lc_unit_text() {
  local bun="$1" addr="$2" port="$3" loop="$4" tokf="${5:-$(_sp_connectord_env)}"
  printf '%s\n' \
    "# DIVE-7558: written by \`sudo 5dive local serve\`. Do not edit; re-run it." \
    "[Unit]" \
    "Description=5dive office chat (the box serves its own chat page on the office network)" \
    "After=network-online.target" \
    "Wants=network-online.target" \
    "" \
    "[Service]" \
    "User=$(_lc_user)" \
    "Group=$(_lc_user)" \
    "ExecStartPre=-+/usr/local/bin/5dive local _agents" \
    "ExecStartPre=-+/usr/bin/install -m 0400 -o $(_lc_user) -g $(_lc_user) ${tokf} %t/5dive-local-chat/token" \
    "ExecStartPre=-+/usr/bin/install -m 0400 -o $(_lc_user) -g $(_lc_user) $(_lc_etc)/cert.pem %t/5dive-local-chat/cert" \
    "ExecStartPre=-+/usr/bin/install -m 0400 -o $(_lc_user) -g $(_lc_user) $(_lc_etc)/key.pem %t/5dive-local-chat/key" \
    "ExecStart=${bun} $(_lc_lib)/server.ts serve" \
    "Environment=LC_STATE=$(_lc_state) LC_LAN_ADDR=${addr} LC_LAN_PORT=${port} LC_LOOP_PORT=${loop}" \
    "Environment=LC_AGENTS_FILE=$(_lc_etc)/agents.json" \
    "LoadCredential=token:${tokf}" \
    "LoadCredential=cert:$(_lc_etc)/cert.pem" \
    "LoadCredential=key:$(_lc_etc)/key.pem" \
    "RuntimeDirectory=5dive-local-chat" \
    "RuntimeDirectoryMode=0700" \
    "StateDirectory=5dive-local-chat" \
    "StateDirectoryMode=0700" \
    "NoNewPrivileges=yes" \
    "ProtectSystem=strict" \
    "ProtectHome=read-only" \
    "PrivateTmp=yes" \
    "Restart=on-failure" \
    "RestartSec=3" \
    "" \
    "[Install]" \
    "WantedBy=multi-user.target"
}

_lc_serve() {
  local addr="" port="" stop=0 a
  for a in "$@"; do
    case "$a" in
      --addr=*) addr="${a#--addr=}" ;;
      --port=*) port="${a#--port=}" ;;
      --stop)   stop=1 ;;
      *) fail "$E_USAGE" "unknown flag: $a (see: 5dive local --help)" ;;
    esac
  done
  require_root
  (( stop )) && { _lc_serve_stop; return 0; }
  [[ -n "$addr" ]] || addr=$(_lc_conf_get LAN_ADDR)
  if [[ -z "$addr" ]]; then
    local arc
    addr=$(_lc_lan_addr) && arc=0 || arc=$?
    (( arc == 2 )) && _lc_addr_ambiguous
    (( arc == 0 )) || fail "$E_VALIDATION" "local chat: this server has no office (private) address. Name one: sudo 5dive local serve --addr=<IP>"
  fi
  [[ "$addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail "$E_VALIDATION" "local chat: --addr must be an IPv4 address ($addr)."
  [[ -n "$port" ]] || port=$(_lc_conf_get LAN_PORT); port="${port:-8443}"
  [[ "$port" =~ ^[0-9]{2,5}$ ]] && (( port >= 1024 && port <= 65535 )) \
    || fail "$E_VALIDATION" "local chat: --port must be 1024-65535 ($port)."
  local loop; loop=$(_lc_conf_get LOOP_PORT); loop="${loop:-8480}"
  local bun; bun=$(_lc_bun)

  install -d -m 0755 -- "$(_lc_etc)" || fail "$E_GENERIC" "local chat: cannot create $(_lc_etc)."
  local tokf; tokf=$(_lc_token_file) || fail "$E_GENERIC" "local chat: could not make the chat's access key (openssl)."
  printf 'LAN_ADDR=%s\nLAN_PORT=%s\nLOOP_PORT=%s\nTOKEN_FILE=%s\n' "$addr" "$port" "$loop" "$tokf" >"$(_lc_conf)"
  getent passwd "$(_lc_user)" >/dev/null 2>&1 \
    || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$(_lc_user)" \
    || fail "$E_GENERIC" "local chat: could not create the $(_lc_user) system user."
  _lc_stage
  _lc_cert "$addr"
  _lc_agents_write
  _lc_unit_text "$bun" "$addr" "$port" "$loop" "$tokf" >"$(_lc_unit)" || fail "$E_GENERIC" "local chat: cannot write $(_lc_unit)."
  _lp_install
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable "$(_lc_svc)" >/dev/null 2>&1 || warn "could not enable $(_lc_svc) at boot"
  systemctl restart "$(_lc_svc)" >/dev/null 2>&1 \
    || fail "$E_GENERIC" "local chat: the server did not start (journalctl -u $(_lc_svc))."
  # Point the agents' chat rail here only once the server is up.
  printf 'http://127.0.0.1:%s\n' "$loop" >"$(five_api_base_file).tmp" \
    && chmod 0644 "$(five_api_base_file).tmp" && mv -f "$(five_api_base_file).tmp" "$(five_api_base_file)" \
    || fail "$E_GENERIC" "local chat: cannot write $(five_api_base_file)."
  printf '%s\n' "Office chat is ON: https://${addr}:${port}" \
    "Connect a phone or laptop: sudo 5dive local pair   (the owner's: --owner, to manage at /panel)" \
    "Restart each agent once so its chat moves here: sudo 5dive agent restart <name>"
}

_lc_serve_stop() {
  systemctl disable --now "$(_lc_svc)" >/dev/null 2>&1 || true
  rm -f -- "$(_lc_unit)"
  _lp_remove
  systemctl daemon-reload >/dev/null 2>&1 || true
  # Put the API base back only if it is the one serve wrote.
  local f; f=$(five_api_base_file)
  grep -qE '^http://127\.0\.0\.1:[0-9]+/?$' "$f" 2>/dev/null && rm -f -- "$f"
  printf '%s\n' "Office chat is OFF. Messages and paired devices are kept in $(_lc_state)."
}

# _lc_admin <op> [args] — the server file, run as its own user, on its own db.
_lc_admin() {
  local bun; bun=$(_lc_bun)
  [[ -s "$(_lc_lib)/server.ts" ]] || fail "$E_NOT_FOUND" "local chat is not set up: sudo 5dive local serve"
  runuser -u "$(_lc_user)" -- env LC_STATE="$(_lc_state)" "$bun" "$(_lc_lib)/server.ts" admin "$@"
}

# 8 characters from the 31-letter alphabet, unbiased: a byte is kept only
# below 248 (8 x 31) and maps to b % 31. Reads bounded chunks, no pipe.
_lc_pair_code() {
  local a='ABCDEFGHJKMNPQRSTUVWXYZ23456789' b out="" n=0
  while (( ${#out} < 8 && n < 8 )); do
    n=$((n + 1))
    for b in $(od -An -tu1 -N32 /dev/urandom); do
      (( b < 248 )) || continue
      out+="${a:$(( b % 31 )):1}"
      (( ${#out} == 8 )) && break
    done
  done
  printf '%s' "$out"
}

_lc_pair() {
  local role=chat a
  for a in "$@"; do
    case "$a" in
      --owner) role=owner ;;
      *) fail "$E_USAGE" "local pair takes one flag, --owner (unknown: $a)." ;;
    esac
  done
  require_root
  local addr port code hash exp
  addr=$(_lc_conf_get LAN_ADDR); port=$(_lc_conf_get LAN_PORT)
  [[ -n "$addr" ]] || fail "$E_NOT_FOUND" "local chat is not set up: sudo 5dive local serve"
  # 8 characters from an alphabet with no look-alikes (no 0/O, 1/I/L).
  # DIVE-7566: bounded input, so tr ends on EOF and never takes the SIGPIPE
  # `tr </dev/urandom | head` did under pipefail (rc 141 on every run).
  code=$(_lc_pair_code)
  [[ ${#code} == 8 ]] || fail "$E_GENERIC" "local chat: could not make a code."
  hash=$(printf '%s' "$code" | sha256sum | cut -d' ' -f1)
  exp=$(( $(date +%s) + 900 ))
  _lc_admin pair-add "$hash" "$exp" "$role" >/dev/null || fail "$E_GENERIC" "local chat: could not save the code."
  if (( JSON_MODE )); then
    jq -cn --arg u "https://${addr}:${port}" --arg c "${code:0:4}-${code:4}" --arg f "$(_lc_fingerprint)" --argjson e "$exp" --arg r "$role" \
      '{ok:true, data:{url:$u, code:$c, fingerprint:$f, expires:$e, role:$r}}'
    return 0
  fi
  printf '%s\n' \
    "1. On the phone or laptop, open:  https://${addr}:${port}" \
    "2. Your browser warns the certificate is self-signed. Check it ends with:" \
    "     $(_lc_fingerprint | tail -c 24)" \
    "   (full SHA-256: $(_lc_fingerprint)) — then continue." \
    "3. Type this code:  ${code:0:4}-${code:4}   (works once, for 15 minutes)" \
    "$([[ $role == owner ]] && printf '%s' "This device may also manage the server: https://${addr}:${port}/panel" || printf '%s' "This device can chat. To manage the server too: sudo 5dive local pair --owner")"
}

_lc_devices() {
  local sub="${1:-ls}"; shift || true
  require_root
  case "$sub" in
    ls|list)
      local out; out=$(_lc_admin devices-ls) || fail "$E_GENERIC" "local chat: could not read the device list."
      if (( JSON_MODE )); then jq -c '{ok:true, data:.}' <<<"$out"; return 0; fi
      jq -r 'if length == 0 then "No devices yet. Connect one: sudo 5dive local pair" else
        (["ID","NAME","ROLE","ADDED","LAST SEEN","STATE"] | @tsv),
        (.[] | [.id, .name, (.role // "chat"), (.created | strftime("%Y-%m-%d")), (.last_seen | strftime("%Y-%m-%d %H:%M")),
                (if .revoked == 1 then "revoked" else "active" end)] | @tsv) end' <<<"$out" | column -t -s $'\t' ;;
    revoke)
      (( $# == 1 )) || fail "$E_USAGE" "usage: sudo 5dive local devices revoke <id>"
      _lc_admin devices-revoke "$1" >/dev/null || fail "$E_NOT_FOUND" "no active device with id $1 (sudo 5dive local devices ls)."
      ok "Device $1 can no longer open the office chat." ;;
    *) fail "$E_USAGE" "usage: sudo 5dive local devices ls | revoke <id>" ;;
  esac
}

_lc_status() {
  local addr port state base
  addr=$(_lc_conf_get LAN_ADDR); port=$(_lc_conf_get LAN_PORT)
  state=$(systemctl is-active "$(_lc_svc)" 2>/dev/null) || true
  base=$(five_api_base)
  if (( JSON_MODE )); then
    jq -cn --arg s "${state:-inactive}" --arg u "${addr:+https://${addr}:${port}}" --arg b "$base" \
      '{ok:true, data:{state:$s, url:$u, apiBase:$b}}'
    return 0
  fi
  if [[ "$state" == active ]]; then
    printf '%s\n' "Office chat: on — https://${addr}:${port}" "Agents' chat goes to: ${base}"
  else
    printf '%s\n' "Office chat: off${addr:+ (set up for https://${addr}:${port}; start: sudo 5dive local serve)}"
  fi
}

# local_chat_notice <agent|""> <text> — show a notice in the office chat (a gate
# notice, an owner question) instead of Telegram. 0 only when the server took
# it. Callable by any seat: the notice listener is loopback-only and needs no
# token, so a seat can post a notice, never read the chat or act as an agent's
# reply (the agent rail needs the box token).
local_chat_notice() {
  local agent="$1" text="$2" loop body
  loop=$(_lc_conf_get LOOP_PORT); loop="${loop:-8480}"
  [[ "$loop" =~ ^[0-9]+$ ]] || return 1
  body=$(jq -cn --arg a "$agent" --arg t "${text:0:8000}" '{text:$t} + (if $a == "" then {} else {agent:$a} end)') || return 1
  curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    --data-binary "$body" "http://127.0.0.1:${loop}/local/notice" 2>/dev/null | grep -qx 200
}

# A Telegram-formatted text as plain text: tags out, entities back.
local_chat_plain() {
  sed -e 's/<[^>]*>//g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&#39;/'/g" -e 's/&amp;/\&/g' <<<"$1"
}
