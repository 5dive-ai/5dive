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
#   * Fixed operations, each a fixed URL: ping (no network, says the rail and the
#     token are there), pending, ack <id>..., event <chat_id> <text> [file]...,
#     status <chat_id> <0|1> [label] (the live step the chat shows, DIVE-6715)
#     and ask <chat_id> <text> <question_id> (<label> <description>){2,10} (a
#     question with buttons, DIVE-6715; an empty description is left out).
#     The root side builds every body with jq. sudo resets the environment, so
#     the caller cannot redirect the API base. DIVE-6816 adds `pending [wait]`
#     (a long poll, wait clamped to 25 s) and, for a chat-only box, `fetch
#     <path>` and `put <path>` (see the block above the root half). DIVE-7502
#     adds the two sealed ops of an encrypted chat (see the block above the
#     root half): `event-e2e <chat_id> <envelope> [file.e2e]...` and
#     `status-e2e <chat_id> <0|1> [envelope]`.
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
# Not audited: the adapter polls every five minutes per seat (on a chat-only
# box, one held long poll at a time), and the control plane records every
# message it stores. The token is re-read on every call, so
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
  local method="$1" url="$2" body="${3:-}" tok="$4" maxt="${5:-30}" out bodyf="" code rc=0
  out=$(mktemp) || fail "$E_GENERIC" "_dashboard_relay: cannot create a temp file."
  local -a extra=()
  if [[ -n "$body" ]]; then
    bodyf=$(mktemp) || { rm -f "$out"; fail "$E_GENERIC" "_dashboard_relay: cannot create a temp file."; }
    printf '%s' "$body" >"$bodyf"
    extra=(-H 'Content-Type: application/json' --data-binary "@${bodyf}")
  fi
  code=$(_dash_relay_curl "$method" "$url" "$tok" "$out" "$maxt" "${extra[@]}") || rc=$?
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

# _dash_relay_curl <method> <url> <token> <out-file> <max-time> [curl args...]
# — the ONE curl line of this rail: print the HTTP code, return curl's rc. The
# bearer rides curl's stdin (-H @-), never argv; every op goes through here.
_dash_relay_curl() {
  local method="$1" url="$2" tok="$3" out="$4" maxt="$5" code rc=0
  shift 5
  local -a args=(-sS --max-time "$maxt" -o "$out" -w '%{http_code}' "$@" -X "$method" -H @-)
  code=$(printf 'Authorization: Bearer %s\n' "$tok" | curl "${args[@]}" "$url") || rc=$?
  tok=""
  printf '%s' "$code"
  return "$rc"
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

# --- DIVE-6816: a chat-only box (no shelld, nothing listens) -----------------
# The API cannot drop an upload on the box or read a reply file back, so the
# adapter moves the bytes itself: `fetch <path>` pulls an upload the owner sent
# (GET /server/selfhost/files) and writes it where the message says it is,
# `put <path>` sends a reply file (POST /server/selfhost/files). Each names ONE
# path, in ITS dir and this seat's own corner of it only:
#   fetch  <uploads>/<seat>/<name>      written root-side, atomically, as the
#          files API writes it (claude:claude 0644, dirs 0755), so the seat
#          reads it and cannot swap the dir: it is not the seat's to write.
#   put    <outbox>/<seat>-<name>       a regular file the SEAT owns, read from
#          ONE descriptor opened without following a link, then
#          copied root-only before curl sees it. The outbox is group-writable,
#          so a path check alone would let a seat swap in a symlink to a
#          root-only file between the check and the read; an O_NOFOLLOW open
#          closes that, and the owner check keeps it to this seat's own copies.
# Both are capped at 20 MB, the API's own cap.
_dash_relay_uploads()    { local d="${FIVEDIVE_CHAT_UPLOADS:-/home/claude/chat-uploads}"; printf '%s' "${d%/}"; }
_dash_relay_file_owner() { printf '%s' "${FIVEDIVE_CHAT_FILE_OWNER:-claude:claude}"; }
_dash_relay_file_max()   { printf '%s' "${FIVEDIVE_CHAT_FILE_MAX:-20971520}"; }
_dash_relay_uri()        { jq -rn --arg p "$1" '$p|@uri'; }

# _dash_relay_upload_ok <seat> <path> — a file name directly in this seat's own
# chat-uploads dir: one component, no leading dot, no slash, nothing to resolve.
_dash_relay_upload_ok() {
  local seat="$1" p="$2" root name
  root=$(_dash_relay_uploads)
  [[ "$p" == "$root/$seat/"* ]] || return 1
  name="${p#"$root/$seat/"}"
  [[ "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,199}$ ]]
}

# _dash_relay_seat_dir <seat> — make <uploads>/<seat> as the files API does and
# print it, only when it is a real dir (no symlink) right where it is named.
_dash_relay_seat_dir() {
  local seat="$1" root dir own
  root=$(_dash_relay_uploads); dir="$root/$seat"; own=$(_dash_relay_file_owner)
  [[ -d "$root" ]] || install -d -m 0755 -o "${own%%:*}" -g "${own#*:}" -- "$root" 2>/dev/null || return 1
  [[ -e "$dir" || -L "$dir" ]] || install -d -m 0755 -o "${own%%:*}" -g "${own#*:}" -- "$dir" 2>/dev/null || return 1
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  [[ "$(realpath -e -- "$dir" 2>/dev/null)" == "$(realpath -e -- "$root" 2>/dev/null)/$seat" ]] || return 1
  printf '%s' "$dir"
}

# _dash_relay_fetch <url> <token> <dir> <dest> — download into a root-only temp
# file in <dir>, then hand it to the files owner and rename it over <dest>.
_dash_relay_fetch() {
  local url="$1" tok="$2" dir="$3" dest="$4" tmp code rc=0 size max own
  max=$(_dash_relay_file_max); own=$(_dash_relay_file_owner)
  tmp=$(mktemp -p "$dir" .fetch.XXXXXX) || fail "$E_GENERIC" "_dashboard_relay fetch: cannot create a temp file in ${dir}."
  code=$(_dash_relay_curl GET "$url" "$tok" "$tmp" 90 --max-filesize "$max") || rc=$?
  tok=""
  if (( rc == 63 )); then
    rm -f "$tmp"; printf '413\n{"error":"the file is over %s bytes"}' "$max"; return 0
  fi
  if (( rc != 0 )) || [[ ! "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
    rm -f "$tmp"
    fail "$E_GENERIC" "_dashboard_relay: the control plane did not answer (curl rc=${rc})."
  fi
  if [[ "$code" != 200 ]]; then
    printf '%s\n' "$code"; head -c 2000 -- "$tmp"; rm -f "$tmp"; return 0
  fi
  size=$(stat -c %s -- "$tmp" 2>/dev/null) || size=-1
  if (( size < 0 || size > max )); then
    rm -f "$tmp"; printf '413\n{"error":"the file is over %s bytes"}' "$max"; return 0
  fi
  if ! { chown -- "$own" "$tmp" && chmod 0644 -- "$tmp" && mv -fT -- "$tmp" "$dest"; } 2>/dev/null; then
    rm -f "$tmp"
    fail "$E_GENERIC" "_dashboard_relay fetch: could not write ${dest}."
  fi
  printf '200\n'
  jq -nc --arg p "$dest" --argjson b "$size" '{ok:true, path:$p, bytes:$b}'
}

# _dash_relay_put <url> <token> <path> <uid> — post one reply file. It is read
# ONCE, through a descriptor opened with O_NOFOLLOW|O_NONBLOCK (a symlink or a
# FIFO swapped in after the path check is refused, never followed or waited
# on), and must be a regular file owned by <uid>, at most the cap. The bytes
# go to a root-only copy, and curl posts the copy.
_dash_relay_put() {
  local url="$1" tok="$2" f="$3" uid="$4" max copy out code rc=0 why
  max=$(_dash_relay_file_max)
  copy=$(mktemp) || fail "$E_GENERIC" "_dashboard_relay: cannot create a temp file."
  python3 -I -c '
import os, stat, sys
path, uid, cap, dest = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
except OSError:
    sys.exit(3)
st = os.fstat(fd)
if not stat.S_ISREG(st.st_mode) or st.st_uid != uid:
    sys.exit(4)
if st.st_size > cap:
    sys.exit(5)
n = 0
with open(dest, "wb") as out:
    while True:
        b = os.read(fd, 1 << 20)
        if not b:
            break
        n += len(b)
        if n > cap:
            sys.exit(5)
        out.write(b)
' "$f" "$uid" "$max" "$copy" || rc=$?
  if (( rc != 0 )); then
    rm -f "$copy"
    case "$rc" in
      3) why="cannot be opened (or is a symlink)" ;;
      4) why="is not a regular file of this seat" ;;
      5) why="is over ${max} bytes" ;;
      *) why="could not be read (rc=${rc})" ;;
    esac
    fail "$E_VALIDATION" "_dashboard_relay put: ${f} ${why}."
  fi
  out=$(mktemp) || { rm -f "$copy"; fail "$E_GENERIC" "_dashboard_relay: cannot create a temp file."; }
  code=$(_dash_relay_curl POST "$url" "$tok" "$out" 90 \
    -H 'Content-Type: application/octet-stream' --data-binary "@${copy}") || rc=$?
  tok=""
  rm -f "$copy"
  if (( rc != 0 )) || [[ ! "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
    rm -f "$out"
    fail "$E_GENERIC" "_dashboard_relay: the control plane did not answer (curl rc=${rc})."
  fi
  printf '%s\n' "$code"
  cat "$out"
  rm -f "$out"
}

# --- DIVE-7502: an encrypted chat (dashboard plugin docs/chat-e2e.md) --------
# A standard seat on a 5dive server replies through this rail, so a sealed
# reply needs its own ops; without them the plugin's reply fails closed. The
# seat seals through `_chat_e2e` (the box key stays root's) and hands this rail
# only ciphertext:
#   event-e2e  <chat_id> <envelope> [file]...  the body is ONE envelope (64 KiB,
#              the API's cap), each file a sealed blob `<seat>-*.e2e` in the
#              outbox whose bytes are an envelope too (the chat's 20 MB cap). A
#              plain file never rides an encrypted reply: the owner would get
#              it from shelld in the clear. The metadata says e2e {v:1}.
#   status-e2e <chat_id> <0|1> [envelope]      the "working: ..." step, sealed
#              (8 KiB, the API's cap); no envelope = plain "working".
# The shape is the API's own check (box -> device: h.v 1, h.d "out"): the API
# re-checks, but a non-envelope must never leave this rail marked sealed.
_dash_relay_e2e_body_max()   { printf '%s' 65536; }
_dash_relay_e2e_status_max() { printf '%s' 8192; }
_DASH_RELAY_ENVELOPE_JQ='type == "object" and (.h | type) == "object" and .h.v == 1 and .h.d == "out"
  and (.h.t | type) == "number"
  and ([.h.s, .h.c, .h.m, .h.salt] | all(type == "string" and length > 0))
  and (.iv | type) == "string" and (.ct | type) == "string"
  and (.k | type) == "object" and (.k | length) > 0'

# _dash_relay_envelope_ok <text> <max-bytes> — one envelope, at most max bytes.
_dash_relay_envelope_ok() {
  local e="$1" max="$2"
  (( $(printf '%s' "$e" | wc -c) <= max )) || return 1
  jq -se "length == 1 and (.[0] | $_DASH_RELAY_ENVELOPE_JQ)" >/dev/null 2>&1 <<<"$e"
}

# _dash_relay_e2e_file_ok <seat> <path> — a sealed blob of this seat directly
# in the outbox (`<seat>-*.e2e`), its bytes one envelope within the file cap.
# Prints the resolved path, or nothing.
_dash_relay_e2e_file_ok() {
  local seat="$1" f="$2" real size
  real=$(_dash_relay_file_ok "$f") || return 1
  [[ "${real##*/}" == "${seat}-"?*.e2e ]] || return 1
  size=$(stat -c %s -- "$real" 2>/dev/null) || return 1
  (( size <= $(_dash_relay_file_max) )) || return 1
  jq -se "length == 1 and (.[0] | $_DASH_RELAY_ENVELOPE_JQ)" >/dev/null 2>&1 <"$real" || return 1
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
      # DIVE-6816: an optional wait (seconds, clamped to 25) holds the poll on
      # the control plane until a message lands; curl waits longer than that.
      (( ${#wire[@]} <= 2 )) || fail "$E_VALIDATION" "_dashboard_relay pending takes at most a wait in seconds."
      local ans wait="${wire[1]:-0}" q=""
      [[ "$wait" =~ ^[0-9]{1,3}$ ]] || fail "$E_VALIDATION" "_dashboard_relay pending: the wait is a number of seconds."
      wait=$((10#$wait)); (( wait > 25 )) && wait=25
      (( wait > 0 )) && q="&wait=${wait}"
      ans=$(_dash_relay_call GET "${base}/server/messages/pending?agent=${seat}${q}" "" "$tok" $((wait + 15 > 30 ? wait + 15 : 30))) || exit $?
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
    status)
      (( ${#wire[@]} >= 3 && ${#wire[@]} <= 4 )) \
        || fail "$E_VALIDATION" "_dashboard_relay status takes a chat id, 0 or 1, and at most one label."
      local chat="${wire[1]}" flag="${wire[2]}" label="${wire[3]:-}" body
      [[ "$chat" =~ ^[A-Za-z0-9][A-Za-z0-9:_.@-]{0,127}$ ]] \
        || fail "$E_VALIDATION" "_dashboard_relay status: invalid chat id."
      [[ "$flag" == 0 || "$flag" == 1 ]] || fail "$E_VALIDATION" "_dashboard_relay status: the flag is 0 or 1."
      (( ${#label} <= 120 )) || fail "$E_VALIDATION" "_dashboard_relay status: the label is over 120 characters."
      [[ "$label" != *[[:cntrl:]]* ]] || fail "$E_VALIDATION" "_dashboard_relay status: the label has a control character."
      body=$(jq -nc --arg a "$seat" --arg c "$chat" --arg f "$flag" --arg l "$label" \
          '{agent:$a, chat_id:$c, active:($f == "1"), label:(if $l == "" then null else $l end)}') \
        || fail "$E_GENERIC" "_dashboard_relay: could not build the status."
      _dash_relay_call POST "${base}/server/messages/status" "$body" "$tok" ;;
    ask)
      local n=$(( ${#wire[@]} - 4 )) i
      (( n >= 4 && n <= 20 && n % 2 == 0 )) \
        || fail "$E_VALIDATION" "_dashboard_relay ask takes a chat id, the text, a question id and 2 to 10 label/description pairs."
      local chat="${wire[1]}" text="${wire[2]}" qid="${wire[3]}" body
      [[ "$chat" =~ ^[A-Za-z0-9][A-Za-z0-9:_.@-]{0,127}$ ]] \
        || fail "$E_VALIDATION" "_dashboard_relay ask: invalid chat id."
      [[ -n "${text//[[:space:]]/}" ]] || fail "$E_VALIDATION" "_dashboard_relay ask: the text is empty."
      (( ${#text} <= 65536 )) || fail "$E_VALIDATION" "_dashboard_relay ask: the text is over 64 KiB."
      [[ "$qid" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
        || fail "$E_VALIDATION" "_dashboard_relay ask: invalid question id."
      for (( i = 4; i < ${#wire[@]}; i += 2 )); do
        [[ -n "${wire[i]//[[:space:]]/}" ]] || fail "$E_VALIDATION" "_dashboard_relay ask: an option label is empty."
        (( ${#wire[i]} <= 120 )) || fail "$E_VALIDATION" "_dashboard_relay ask: an option label is over 120 characters."
        (( ${#wire[i+1]} <= 200 )) || fail "$E_VALIDATION" "_dashboard_relay ask: an option description is over 200 characters."
      done
      body=$(jq -nc --arg a "$seat" --arg b "$text" --arg c "$chat" --arg q "$qid" '$ARGS.positional as $o
          | {agent:$a, body:$b, metadata:{chat_id:$c, question:{id:$q, options:[range(0; $o|length; 2) as $i
              | {label:$o[$i]} + (if $o[$i+1] == "" then {} else {description:$o[$i+1]} end)]}}}' \
          --args "${wire[@]:4}") \
        || fail "$E_GENERIC" "_dashboard_relay: could not build the question."
      _dash_relay_call POST "${base}/server/messages/event" "$body" "$tok" ;;
    event-e2e)
      (( ${#wire[@]} >= 3 && ${#wire[@]} <= 13 )) \
        || fail "$E_VALIDATION" "_dashboard_relay event-e2e takes a chat id, the envelope and at most 10 sealed files."
      local chat="${wire[1]}" env="${wire[2]}" f real body
      [[ "$chat" =~ ^[A-Za-z0-9][A-Za-z0-9:_.@-]{0,127}$ ]] \
        || fail "$E_VALIDATION" "_dashboard_relay event-e2e: invalid chat id."
      _dash_relay_envelope_ok "$env" "$(_dash_relay_e2e_body_max)" \
        || fail "$E_VALIDATION" "_dashboard_relay event-e2e: the body is not one encrypted envelope (at most $(_dash_relay_e2e_body_max) bytes); nothing was sent."
      local -a files=()
      for f in "${wire[@]:3}"; do
        real=$(_dash_relay_e2e_file_ok "$seat" "$f") \
          || fail "$E_VALIDATION" "_dashboard_relay event-e2e: a file must be this seat's sealed blob in $(_dash_relay_outbox) (${seat}-....e2e, an envelope); nothing was sent ($f)."
        files+=("$real")
      done
      body=$(jq -nc --arg a "$seat" --arg b "$env" --arg c "$chat" '$ARGS.positional as $f
          | {agent:$a, body:$b, metadata:({chat_id:$c} + (if ($f|length) > 0 then {files:$f} else {} end) + {e2e:{v:1}})}' \
          --args "${files[@]}") \
        || fail "$E_GENERIC" "_dashboard_relay: could not build the reply."
      _dash_relay_call POST "${base}/server/messages/event" "$body" "$tok" ;;
    status-e2e)
      (( ${#wire[@]} >= 3 && ${#wire[@]} <= 4 )) \
        || fail "$E_VALIDATION" "_dashboard_relay status-e2e takes a chat id, 0 or 1, and at most one envelope."
      local chat="${wire[1]}" flag="${wire[2]}" env="${wire[3]:-}" body
      [[ "$chat" =~ ^[A-Za-z0-9][A-Za-z0-9:_.@-]{0,127}$ ]] \
        || fail "$E_VALIDATION" "_dashboard_relay status-e2e: invalid chat id."
      [[ "$flag" == 0 || "$flag" == 1 ]] || fail "$E_VALIDATION" "_dashboard_relay status-e2e: the flag is 0 or 1."
      [[ -z "$env" ]] || _dash_relay_envelope_ok "$env" "$(_dash_relay_e2e_status_max)" \
        || fail "$E_VALIDATION" "_dashboard_relay status-e2e: the label is not one encrypted envelope (at most $(_dash_relay_e2e_status_max) bytes)."
      body=$(jq -nc --arg a "$seat" --arg c "$chat" --arg f "$flag" --arg l "$env" \
          '{agent:$a, chat_id:$c, active:($f == "1"), label:(if $l == "" then null else $l end), e2e:{v:1}}') \
        || fail "$E_GENERIC" "_dashboard_relay: could not build the status."
      _dash_relay_call POST "${base}/server/messages/status" "$body" "$tok" ;;
    fetch)
      (( ${#wire[@]} == 2 )) || fail "$E_VALIDATION" "_dashboard_relay fetch takes one path."
      local p="${wire[1]}" dir
      _dash_relay_upload_ok "$seat" "$p" \
        || fail "$E_VALIDATION" "_dashboard_relay fetch: the path must name a file in $(_dash_relay_uploads)/${seat}/ ($p)."
      dir=$(_dash_relay_seat_dir "$seat") \
        || fail "$E_VALIDATION" "_dashboard_relay fetch: $(_dash_relay_uploads)/${seat} is not a plain directory."
      _dash_relay_fetch "${base}/server/selfhost/files?path=$(_dash_relay_uri "$p")" "$tok" "$dir" "$p" ;;
    put)
      (( ${#wire[@]} == 2 )) || fail "$E_VALIDATION" "_dashboard_relay put takes one path."
      local p="${wire[1]}" real
      real=$(_dash_relay_file_ok "$p") && [[ "${real##*/}" == "${seat}-"?* ]] \
        || fail "$E_VALIDATION" "_dashboard_relay put: the path must be this seat's file in $(_dash_relay_outbox) (${seat}-...): $p"
      _dash_relay_put "${base}/server/selfhost/files?path=$(_dash_relay_uri "$real")" "$tok" "$real" "$ruid" ;;
    *)
      fail "$E_VALIDATION" "_dashboard_relay allows only ping, pending, ack, event, event-e2e, status, status-e2e, ask, fetch or put." ;;
  esac
}
