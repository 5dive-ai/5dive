# ---------------------------------------------------------------------------
# DIVE-5894: a standard seat's dashboard chat, without the box token.
#
# DIVE-5690 closed /etc/5dive/connectord.env to standard seats (0640
# root:claude-keys). The dashboard chat adapter (dashboard@5dive-plugins, and
# the same server.ts under the Codex dispatcher) runs AS THE SEAT and read the
# token from that file itself, so from the first nightly that carried 0.78 it
# exited 1 on every standard seat: claude seats lost dashboard chat silently,
# and a Codex dispatcher seat died with it and never drained its inbox.
#
# Handing the adapter the token would hand the seat the token. So the adapter's
# three control-plane calls cross ONE root rail instead, on the _self_account
# template (DIVE-5367):
#
#   * ONE sudoers line, exact path, NO args, NO wildcard
#     (render_standard_sudoers). The operation travels NUL-separated on stdin.
#   * The seat is derived from SUDO_UID, never from the caller, and it is the
#     `agent` of every call. So a seat reads, acks and replies as ITSELF only:
#     narrower than the token, which speaks for every agent on the box.
#   * Four operations, each a fixed URL: ping (no network, says the rail and the
#     token are there), pending, ack <id>..., event <chat_id> <text> [file]...
#     The root side builds every body with jq. sudo resets the environment, so
#     the caller cannot redirect the API base.
#   * An ack names only ids this seat's own pending poll returned. The control
#     plane scopes a DM ack by owner, not by agent, so without this one seat
#     could mark another agent's messages collected and hold them back.
#   * A reply attachment must be a regular file directly in the shared
#     chat-downloads outbox (the adapter already copies there). This is checked
#     when the reply is POSTED only: the outbox is group-writable, and the
#     download is served later by shelld, which runs as `claude`, checks the path
#     lexically against /home and follows symlinks. So a seat can still swap the
#     file for a symlink after the post. What that reaches is what `claude` can
#     read, and it goes to the OWNER's download, never back to the seat; the
#     owner's own Files browser already reaches the same set. Closing it is
#     shelld's job (5dive-api), not this rail's.
#
# Output is the control plane's answer: the HTTP status on the first line, the
# body after it. The adapter rebuilds a Response from it, so its retry, ack and
# lifecycle logic is the same on both paths. A transport failure exits non-zero.
#
# Not audited: the adapter polls every five minutes per seat, and the control
# plane records every message it stores. The token is re-read on every call, so
# a rotation by shelld is picked up with no reload.

_dash_relay_api_base() { local b="${FIVE_API_BASE:-https://api.5dive.com}"; printf '%s' "${b%/}"; }
_dash_relay_outbox()   { local d="${DASHBOARD_OUTBOX:-/home/claude/chat-downloads}"; printf '%s' "${d%/}"; }
_dash_relay_seen_dir() { printf '%s' "${FIVEDIVE_DASHBOARD_RELAY_DIR:-/var/lib/5dive/dashboard-relay}"; }

# The box token, read as root. Empty when there is none.
_dash_relay_token() {
  local f t=""
  f=$(_sp_connectord_env)
  [[ -r "$f" ]] || return 0
  t=$(sed -n 's/^CONNECTORD_TOKEN=//p' "$f" 2>/dev/null | head -n 1) || t=""
  t="${t%$'\r'}"; t="${t#\"}"; t="${t%\"}"; t="${t#\'}"; t="${t%\'}"
  printf '%s' "$t"
}

# _dash_relay_call <method> <url> <json-body|""> <token> — print "<status>\n<body>".
#
# THE TOKEN NEVER TOUCHES ARGV (the DIVE-5168 rule, src/cmd_partner.sh). /proc is
# not mounted hidepid on our boxes, so a root curl's command line is readable by
# the very seat this rail keeps the token from: the bearer goes in on curl's
# STDIN (`-H @-`), and the body, which carries the owner's messages, from a
# root-only temp file (`--data-binary @file`). `ps` shows neither.
_dash_relay_call() {
  local method="$1" url="$2" body="${3:-}" tok="$4" out bodyf="" code rc=0
  out=$(mktemp) || fail "$E_GENERIC" "_dashboard_relay: cannot create a temp file."
  local -a args=(-sS --max-time 30 -o "$out" -w '%{http_code}' -X "$method" -H @-)
  if [[ -n "$body" ]]; then
    bodyf=$(mktemp) || { rm -f "$out"; fail "$E_GENERIC" "_dashboard_relay: cannot create a temp file."; }
    printf '%s' "$body" >"$bodyf"
    args+=(-H 'Content-Type: application/json' --data-binary "@${bodyf}")
  fi
  code=$(printf 'Authorization: Bearer %s\n' "$tok" | curl "${args[@]}" "$url") || rc=$?
  tok=""
  [[ -n "$bodyf" ]] && rm -f "$bodyf"
  if (( rc != 0 )) || [[ ! "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
    rm -f "$out"
    fail "$E_GENERIC" "_dashboard_relay: the control plane did not answer (curl rc=${rc})."
  fi
  printf '%s\n' "$code"
  cat "$out"
  rm -f "$out"
}

# _dash_relay_remember <seat> <body> — keep the ids a 200 pending answer
# offered this seat (the last 2000), root-only, so its ack can be checked.
_dash_relay_remember() {
  local seat="$1" body="$2" d f ids
  ids=$(jq -r '.pending[]?.id | select(type == "number") | tostring' <<<"$body" 2>/dev/null) || return 0
  [[ -n "$ids" ]] || return 0
  d=$(_dash_relay_seen_dir); f="$d/${seat}.ids"
  install -d -m 700 "$d" 2>/dev/null || return 0
  { cat "$f" 2>/dev/null; printf '%s\n' "$ids"; } | awk '!seen[$0]++' | tail -n 2000 > "$f.tmp" \
    && chmod 600 "$f.tmp" && mv -f "$f.tmp" "$f"
  return 0
}

# A reply file: an existing regular file directly inside the outbox. Prints the
# resolved path, or nothing.
_dash_relay_file_ok() {
  local f="$1" box real
  box=$(_dash_relay_outbox)
  [[ "$f" == "$box"/* && "${f#"$box"/}" != */* && "$f" != *$'\n'* ]] || return 1
  [[ -f "$f" && ! -L "$f" ]] || return 1
  real=$(realpath -e -- "$f" 2>/dev/null) || return 1
  [[ "$real" == "$(realpath -e -- "$box" 2>/dev/null)"/* ]] || return 1
  printf '%s' "$real"
}

# Root half. Reached ONLY through the exact-path NOPASSWD grant (or by root).
cmd_dashboard_relay() {
  _gate_is_root || fail "$E_PERMISSION" "_dashboard_relay is a privileged internal primitive (reachable only through the exact-path NOPASSWD grant)."
  [[ $# -eq 0 ]] || fail "$E_USAGE" "_dashboard_relay takes no arguments (the operation is read from stdin, the seat from the sudo caller)."

  local ruid="${SUDO_UID:-}" seat=""
  [[ "$ruid" =~ ^[0-9]+$ && "$ruid" != 0 ]] \
    || fail "$E_AUTH_REQUIRED" "_dashboard_relay requires sudo from an agent seat."
  seat=$(_gate_uid_to_agent "$ruid")
  [[ "$seat" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] \
    || fail "$E_AUTH_REQUIRED" "_dashboard_relay caller uid ${ruid} is not an agent seat."

  local -a wire=(); local a
  while IFS= read -r -d '' a; do wire+=("$a"); done
  (( ${#wire[@]} >= 1 )) || fail "$E_VALIDATION" "_dashboard_relay requires an operation on stdin."

  local tok base
  tok=$(_dash_relay_token)
  [[ -n "$tok" ]] || fail "$E_NOT_FOUND" "_dashboard_relay: this box has no connectord token ($(_sp_connectord_env))."
  base=$(_dash_relay_api_base)

  case "${wire[0]}" in
    ping)
      (( ${#wire[@]} == 1 )) || fail "$E_VALIDATION" "_dashboard_relay ping takes no arguments."
      printf '200\n{"ok":true,"agent":"%s"}' "$seat" ;;
    pending)
      (( ${#wire[@]} == 1 )) || fail "$E_VALIDATION" "_dashboard_relay pending takes no arguments."
      local ans
      ans=$(_dash_relay_call GET "${base}/server/messages/pending?agent=${seat}" "" "$tok") || exit $?
      [[ "${ans%%$'\n'*}" == 200 ]] && _dash_relay_remember "$seat" "${ans#*$'\n'}"
      printf '%s' "$ans" ;;
    ack)
      local n=$(( ${#wire[@]} - 1 )) id ids="" body
      (( n >= 1 && n <= 500 )) || fail "$E_VALIDATION" "_dashboard_relay ack takes 1 to 500 message ids."
      for id in "${wire[@]:1}"; do
        [[ "$id" =~ ^[0-9]{1,18}$ ]] || fail "$E_VALIDATION" "_dashboard_relay ack: a message id is a number."
        ids+="${ids:+,}$((10#$id))"
        grep -qxF "$((10#$id))" "$(_dash_relay_seen_dir)/${seat}.ids" 2>/dev/null \
          || fail "$E_VALIDATION" "_dashboard_relay ack: message $((10#$id)) was not offered to this seat."
      done
      body=$(jq -nc --arg a "$seat" --argjson ids "[$ids]" '{agent:$a, ids:$ids}') \
        || fail "$E_GENERIC" "_dashboard_relay: could not build the ack."
      _dash_relay_call POST "${base}/server/messages/pending/ack" "$body" "$tok" ;;
    event)
      (( ${#wire[@]} >= 3 && ${#wire[@]} <= 13 )) \
        || fail "$E_VALIDATION" "_dashboard_relay event takes a chat id, the text and at most 10 files."
      local chat="${wire[1]}" text="${wire[2]}" f real body
      [[ "$chat" =~ ^[A-Za-z0-9][A-Za-z0-9:_.@-]{0,127}$ ]] \
        || fail "$E_VALIDATION" "_dashboard_relay event: invalid chat id."
      [[ -n "${text//[[:space:]]/}" ]] || fail "$E_VALIDATION" "_dashboard_relay event: the text is empty."
      (( ${#text} <= 65536 )) || fail "$E_VALIDATION" "_dashboard_relay event: the text is over 64 KiB."
      local -a files=()
      for f in "${wire[@]:3}"; do
        real=$(_dash_relay_file_ok "$f") \
          || fail "$E_VALIDATION" "_dashboard_relay event: a reply file must be a file in $(_dash_relay_outbox) ($f)."
        files+=("$real")
      done
      body=$(jq -nc --arg a "$seat" --arg b "$text" --arg c "$chat" '$ARGS.positional as $f
          | {agent:$a, body:$b, metadata:({chat_id:$c} + (if ($f|length) > 0 then {files:$f} else {} end))}' \
          --args "${files[@]}") \
        || fail "$E_GENERIC" "_dashboard_relay: could not build the reply."
      _dash_relay_call POST "${base}/server/messages/event" "$body" "$tok" ;;
    *)
      fail "$E_VALIDATION" "_dashboard_relay allows only ping, pending, ack or event." ;;
  esac
}
