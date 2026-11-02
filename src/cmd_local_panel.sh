# ── DIVE-7576: the office control panel's ONE root entry ─────────────────────
#
# The office chat (src/cmd_local_chat.sh) serves /panel beside the chat page:
# the owner manages agents, approvals, secrets and settings from the office
# network with local-only on. The server stays the unprivileged, sandboxed
# 5dive-chat user. Every panel action crosses to root through exactly one door:
#
#   /run/5dive-local-panel.sock   (root:5dive-chat 0660, socket-activated)
#     → 5dive-local-panel@.service (root, one instance per call)
#     → /usr/local/bin/5dive local panel-exec --socket
#
# WHY A SOCKET AND NOT SUDO. The chat unit runs NoNewPrivileges=yes and
# ProtectSystem=strict: sudo cannot gain root under the first, and a root child
# would still see a read-only /etc and /home under the second. Socket
# activation starts panel-exec OUTSIDE that sandbox, as root, and only the
# 5dive-chat group may connect. Same one-entry, fixed-allowlist shape a sudoers
# drop-in would give, without loosening the network-facing process.
#
# THE REQUEST. One JSON line {"argv":["<verb>", ...], "device":"<id>"}, then
# (secret verbs only) the value, then EOF. argv is checked against a fixed
# verb table and a per-argument pattern; nothing is ever eval'd, no argument
# is passed where it could be read as a flag, and a secret value travels on
# stdin only, never argv. The answer is one JSON envelope {ok, data|error}.
# Every call, refused or run, appends one line to the audit log (root 0600);
# a secret value is never in it.
#
#   5dive local panel-exec <verb> [args]     (root; value on stdin for secret-set)
#   5dive local panel-exec --socket          (what the socket unit runs)
#
# Test seams: FIVE_LOCAL_CHAT_ROOT prefixes every path; with it set,
# FIVE_PANEL_CLI names the 5dive binary the verbs call.

_lp_sock()          { printf '%s/run/5dive-local-panel.sock' "$(_lc_root)"; }
_lp_socket_unit()   { printf '%s/etc/systemd/system/5dive-local-panel.socket' "$(_lc_root)"; }
_lp_service_unit()  { printf '%s/etc/systemd/system/5dive-local-panel@.service' "$(_lc_root)"; }
_lp_audit_file()    { printf '%s/var/log/5dive/local-panel.log' "$(_lc_root)"; }
_lp_cli() {
  if [[ -n "${FIVE_LOCAL_CHAT_ROOT:-}" && -n "${FIVE_PANEL_CLI:-}" ]]; then printf '%s' "$FIVE_PANEL_CLI"
  else printf '/usr/local/bin/5dive'; fi
}

# Per-argument patterns. Each starts with a letter or digit, so none can be a
# flag; none admits a space, quote, ; $ ` | < > \ or a newline.
readonly LP_AGENT_RE='^[a-z][a-z0-9-]{0,15}$'
readonly LP_IDENT_RE='^[A-Z][A-Z0-9]{0,9}-[0-9]{1,7}$'
readonly LP_SECRET_RE='^[A-Z][A-Z0-9_]{1,63}$'
readonly LP_ACCOUNT_RE='^[a-z][a-z0-9_-]{0,31}$'
readonly LP_DEVICE_RE='^[a-f0-9]{8,32}$'
readonly LP_VALUE_MAX=8192

# The verb table: <verb> → the pattern for each argument, in order. A verb not
# here is refused; a wrong argument count is refused.
_lp_spec() {
  case "$1" in
    team|board|secrets|settings) printf '' ;;
    agent-add)     printf 'agent account?' ;;
    agent-restart|agent-remove) printf 'agent' ;;
    gate-answer)   printf 'ident value' ;;
    secret-set)    printf 'secret' ;;
    account-test)  printf 'account' ;;
    device-revoke) printf 'device' ;;
    *) return 1 ;;
  esac
}

# _lp_arg_ok <kind> <value> — rc 0 when value fits kind.
_lp_arg_ok() {
  local k="${1%\?}" v="$2"
  case "$k" in
    agent)   [[ "$v" =~ $LP_AGENT_RE ]] ;;
    ident)   [[ "$v" =~ $LP_IDENT_RE ]] ;;
    secret)  [[ "$v" =~ $LP_SECRET_RE ]] ;;
    account) [[ "$v" =~ $LP_ACCOUNT_RE ]] ;;
    device)  [[ "$v" =~ $LP_DEVICE_RE ]] ;;
    # A gate answer is checked again against the gate's own options before it
    # runs; this is the shape floor: 1-200 chars, no leading dash, no control
    # character, none of ; $ ` | < > \ (Turkish and other letters pass).
    value)   (( ${#v} >= 1 && ${#v} <= 200 )) && [[ "$v" != -* ]] \
               && ! [[ "$v" =~ [[:cntrl:]] ]] && [[ "$v" != *[\;\$\`\|\<\>\\]* ]] ;;
    *) return 1 ;;
  esac
}

# _lp_validate <verb> [args] — rc 0 when the call is in the table and every
# argument fits; prints the reason on refusal.
_lp_validate() {
  local verb="${1:-}" spec kinds=() i n
  [[ -n "$verb" ]] || { printf 'no verb'; return 1; }
  spec=$(_lp_spec "$verb") || { printf 'unknown verb'; return 1; }
  shift
  read -ra kinds <<<"$spec"
  n=0; for i in "${kinds[@]}"; do [[ "$i" == *\? ]] || n=$((n + 1)); done
  (( $# >= n && $# <= ${#kinds[@]} )) || { printf 'wrong number of arguments'; return 1; }
  local -a av=("$@"); local a
  for (( i = 0; i < ${#av[@]}; i++ )); do
    a="${av[$i]}"
    (( ${#a} <= 200 )) || { printf 'argument %d is too long' "$((i + 1))"; return 1; }
    _lp_arg_ok "${kinds[$i]}" "$a" || { printf 'argument %d is not a valid %s' "$((i + 1))" "${kinds[$i]%\?}"; return 1; }
  done
  return 0
}

# One audit line: time, device, verb, args, result. Tabs and newlines in any
# field become spaces (args are validated first, so this is belt and braces).
_lp_audit() {
  local f; f=$(_lp_audit_file)
  install -d -m 0750 -- "${f%/*}" 2>/dev/null || return 0
  local line
  line=$(printf '%s\t%s\t%s\t%s\t%s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${1:-cli}" "${2:-?}" "${3:-}" "${4:-}" | tr '\n\r' '  ')
  ( umask 077; printf '%s\n' "$line" >>"$f" ) 2>/dev/null || true
}

_lp_reply_ok()   { jq -cn --argjson d "${1:-null}" '{ok:true, data:$d}'; }
_lp_reply_fail() { jq -cn --arg e "$1" '{ok:false, error:$e}'; }

# _lp_cli_json <args...> — run the 5dive CLI with --json; print its .data on
# success (rc 0), the error message on failure (rc 1). stdin passes through.
_lp_cli_json() {
  local out err rc ef; ef=$(mktemp) || return 1
  out=$("$(_lp_cli)" --json "$@" 2>"$ef"); rc=$?
  err=$(tail -n 3 "$ef" 2>/dev/null); rm -f -- "$ef"
  if (( rc == 0 )) && jq -e '.ok == true' <<<"$out" >/dev/null 2>&1; then
    jq -c '.data // null' <<<"$out"; return 0
  fi
  local msg
  msg=$(jq -r '.error.message // .error // empty' <<<"$out" 2>/dev/null | head -c 600)
  [[ -n "$msg" ]] || msg=$(sed -e 's/^error: //' <<<"$err" | tail -n 1 | head -c 600)
  printf '%s' "${msg:-that did not work (exit $rc)}"; return 1
}

# The box's own-AI accounts (DIVE-7568): name, harness, address, model.
_lp_accounts() {
  local d n out="[]" u
  for d in "${AUTH_PROFILES_DIR}"/*/; do
    [[ -d "$d" ]] || continue
    n=$(basename "$d"); [[ "$n" =~ $LP_ACCOUNT_RE ]] || continue
    u=$(profile_env_value "$n" FIVEDIVE_CUSTOM_BASE_URL)
    [[ -n "$u" ]] || continue
    out=$(jq -c --arg n "$n" --arg h "$(profile_env_value "$n" FIVEDIVE_CUSTOM_HARNESS)" --arg u "$u" \
      --arg m "$(profile_env_value "$n" FIVEDIVE_CUSTOM_MODEL)" '. + [{name:$n, harness:$h, baseUrl:$u, model:$m}]' <<<"$out")
  done
  printf '%s' "$out"
}

# `config local-only check --status` as rows {ok, item, state}.
_lp_local_only_rows() {
  local out
  out=$("$(_lp_cli)" config local-only check --status 2>/dev/null) || true
  jq -Rsc '[split("\n")[] | capture("^(?<s>ok|LEAK) +(?<item>.+?)  +(?<state>.*)$")? | {ok:(.s == "ok"), item, state}]' <<<"$out"
}

# _lp_run <verb> [args] — the allowlisted action; prints data JSON (rc 0) or an
# error message (rc 1). The value for secret-set is in $LP_INPUT.
_lp_run() {
  local verb="$1"; shift
  local d
  case "$verb" in
    team) _lp_cli_json agent list ;;
    agent-add)
      local name="$1" acct="${2:-}" h
      if [[ -z "$acct" ]]; then acct=$(_lp_accounts | jq -r '.[0].name // empty'); fi
      [[ -n "$acct" ]] || { printf 'This server has no local AI yet. Add one first: sudo 5dive account add office-ai --provider=custom --base-url=<address> --model=<name> --harness=claude'; return 1; }
      h=$(profile_env_value "$acct" FIVEDIVE_CUSTOM_HARNESS)
      [[ -n "$h" ]] || { printf "account '%s' is not a local AI account" "$acct"; return 1; }
      _lp_cli_json agent create "$name" --type="$h" --auth-profile="$acct" </dev/null ;;
    agent-restart) _lp_cli_json agent restart "$1" </dev/null ;;
    agent-remove)  _lp_cli_json agent rm "$1" </dev/null ;;
    board)
      local tasks gates
      tasks=$(_lp_cli_json task ls </dev/null) || { printf '%s' "$tasks"; return 1; }
      gates=$(_lp_cli_json task inbox </dev/null) || { printf '%s' "$gates"; return 1; }
      jq -cn --argjson t "$tasks" --argjson g "$gates" \
        '{tasks: ($t.tasks // $t // []), gates: ($g.inbox // [])}' ;;
    gate-answer)
      local ident="$1" value="$2" gates row
      gates=$(_lp_cli_json task inbox </dev/null) || { printf '%s' "$gates"; return 1; }
      row=$(jq -c --arg i "$ident" '[.inbox[]? | select(.ident == $i)][0] // empty' <<<"$gates")
      [[ -n "$row" ]] || { printf '%s is not waiting for an answer' "$ident"; return 1; }
      # The answer must be one the gate offers: its listed options, or
      # approve/reject on an approval, done on a manual step.
      local allowed
      allowed=$(jq -r '((.need_options // "") | split("|") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != "")))
        + (if .need_type == "approval" then ["approve","reject"] elif .need_type == "manual" then ["done"] else [] end) | .[]' <<<"$row")
      grep -qxF -- "$value" <<<"$allowed" || { printf 'that is not one of the answers %s offers' "$ident"; return 1; }
      _lp_cli_json task answer "$ident" --value="$value" --human --from=office-panel </dev/null ;;
    secrets)
      lazy_need _tool_set_vars
      local names; names=$(_tool_set_vars 2>/dev/null | sort -u)
      jq -Rsc 'split("\n") | map(select(. != ""))' <<<"$names" ;;
    secret-set)
      [[ -n "$LP_INPUT" ]] || { printf 'the value is empty'; return 1; }
      _lp_cli_json secret write "$1" --connector=tools < <(printf '%s' "$LP_INPUT") >/dev/null || return 1
      jq -cn --arg n "$1" '{name:$n, saved:true}' ;;
    settings)
      jq -cn --argjson lo "$(_lp_local_only_rows)" --argjson a "$(_lp_accounts)" \
        --argjson up "$(_lp_update_ready && echo true || echo false)" \
        '{localOnly:$lo, accounts:$a, updateFromFile:$up}' ;;
    account-test)
      local acct="$1" u m h k
      u=$(profile_env_value "$acct" FIVEDIVE_CUSTOM_BASE_URL)
      [[ -n "$u" ]] || { printf "no local AI account named '%s'" "$acct"; return 1; }
      m=$(profile_env_value "$acct" FIVEDIVE_CUSTOM_MODEL); h=$(profile_env_value "$acct" FIVEDIVE_CUSTOM_HARNESS)
      k=$(profile_env_value "$acct" FIVEDIVE_CUSTOM_API_KEY)
      if [[ -n "$k" ]]; then
        _lp_cli_json account test --base-url="$u" --model="$m" --harness="$h" --api-key=- < <(printf '%s' "$k")
      else
        _lp_cli_json account test --base-url="$u" --model="$m" --harness="$h" </dev/null
      fi ;;
    device-revoke) _lp_cli_json local devices revoke "$1" </dev/null ;;
    *) printf 'unknown verb'; return 1 ;;
  esac
}

# "Install update from file" rides the offline update verb from the sibling row;
# until a CLI carries it the panel hides the button.
_lp_update_ready() { local h; h=$("$(_lp_cli)" self-update --help 2>&1); grep -q -- '--from-file' <<<"$h"; }

_lp_exec() {
  require_root
  local -a argv=(); local device="" line n
  LP_INPUT=""
  if [[ "${1:-}" == --socket ]]; then
    IFS= read -r -n 4096 line || true
    if ! jq -e '(.argv | type == "array") and (.argv | length >= 1 and length <= 4)
                and all(.argv[]; type == "string") and ((.device // "") | type == "string")' <<<"$line" >/dev/null 2>&1; then
      _lp_audit "?" "?" "" "refused: bad request"
      _lp_reply_fail "bad request"; return 0
    fi
    mapfile -t argv < <(jq -r '.argv[]' <<<"$line")
    n=$(jq '.argv | length' <<<"$line")
    device=$(jq -r '.device // ""' <<<"$line")
    [[ -z "$device" || "$device" =~ $LP_DEVICE_RE ]] || device="invalid"
    # A newline inside an argument splits it into two lines above.
    if (( ${#argv[@]} != n )); then
      _lp_audit "$device" "${argv[0]:-?}" "" "refused: an argument holds a line break"
      _lp_reply_fail "argument holds a line break"; return 0
    fi
    LP_INPUT=$(head -c $((LP_VALUE_MAX + 1)))
  else
    argv=("$@")
    [[ "${argv[0]:-}" == secret-set && ! -t 0 ]] && LP_INPUT=$(head -c $((LP_VALUE_MAX + 1)))
  fi
  local verb="${argv[0]:-}" why args
  args=$(printf '%s ' "${argv[@]:1}"); args="${args% }"
  if ! why=$(_lp_validate "${argv[@]}"); then
    _lp_audit "$device" "${verb:0:40}" "${args:0:300}" "refused: $why"
    _lp_reply_fail "refused: $why"; return 0
  fi
  if (( ${#LP_INPUT} > LP_VALUE_MAX )); then
    _lp_audit "$device" "$verb" "$args" "refused: value over $LP_VALUE_MAX bytes"
    _lp_reply_fail "the value is too long"; return 0
  fi
  local out rc
  out=$(_lp_run "${argv[@]}"); rc=$?
  if (( rc == 0 )) && jq -e . <<<"${out:-null}" >/dev/null 2>&1; then
    _lp_audit "$device" "$verb" "$args" ok
    _lp_reply_ok "${out:-null}"
  else
    _lp_audit "$device" "$verb" "$args" "failed: ${out:0:200}"
    _lp_reply_fail "${out:-that did not work}"
  fi
  return 0
}

# ── the socket + service units (written by `local serve`) ────────────────────
_lp_socket_text() {
  printf '%s\n' \
    "# DIVE-7576: written by \`sudo 5dive local serve\`. Do not edit; re-run it." \
    "[Unit]" \
    "Description=5dive office control panel (the one root entry the office chat may call)" \
    "" \
    "[Socket]" \
    "ListenStream=/run/5dive-local-panel.sock" \
    "SocketUser=root" \
    "SocketGroup=$(_lc_user)" \
    "SocketMode=0660" \
    "Accept=yes" \
    "MaxConnections=8" \
    "" \
    "[Install]" \
    "WantedBy=sockets.target"
}

_lp_service_text() {
  printf '%s\n' \
    "# DIVE-7576: written by \`sudo 5dive local serve\`. Do not edit; re-run it." \
    "[Unit]" \
    "Description=5dive office control panel action" \
    "" \
    "[Service]" \
    "User=root" \
    "ExecStart=/usr/local/bin/5dive local panel-exec --socket" \
    "StandardInput=socket" \
    "StandardOutput=socket" \
    "StandardError=journal" \
    "TimeoutStopSec=15" \
    "RuntimeMaxSec=900"
}

# Called by _lc_serve after the chat unit is written; a failure here leaves the
# chat working and the panel saying its helper is not running.
_lp_install() {
  _lp_socket_text >"$(_lp_socket_unit)" && _lp_service_text >"$(_lp_service_unit)" \
    || { warn "office panel: cannot write its units; the chat works, the panel will not"; return 0; }
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now 5dive-local-panel.socket >/dev/null 2>&1 \
    || warn "office panel: could not start 5dive-local-panel.socket (journalctl -u 5dive-local-panel.socket)"
}

_lp_remove() {
  systemctl disable --now 5dive-local-panel.socket >/dev/null 2>&1 || true
  rm -f -- "$(_lp_socket_unit)" "$(_lp_service_unit)"
}
