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
# DIVE-7579 (D4) INSTALL AN UPDATE FILE. The owner picks the file on their own
# laptop or phone and the page uploads it: an office server usually has no
# screen, and Ubuntu Server mounts no USB stick by itself, so a disk in the box
# would still need someone at a terminal. The chat server (5dive-chat) streams
# the upload into its own state folder; `update-install` (no arguments: the
# path is fixed) copies it into a root-only folder, and a transient root unit
# runs `self-update --from=<that copy>` — the same signed-file check as the
# terminal, so a changed or other-key file is refused there. The install runs
# detached because it restarts the agents and the office chat itself, which
# would cut the page's request; `update-status` is what the page polls.
#
# DIVE-7599 INVITE A PERSON, AND FIRST-RUN AI SETUP. The owner has no
# terminal, so two things `sudo 5dive` did are now panel verbs:
#   device-invite <name> <chat|owner>  → `local pair --name=<name> [--owner]`:
#       the same one-use, 15-minute code, the device takes the typed name. The
#       code rides back in the reply only; the audit line has name and role.
#   ai-scan [<address>]                → `account scan`: model servers on the
#       office's private networks (or the models at one typed address).
#   ai-setup <address> <model> <agent> → test it, save it as the box's AI
#       account (office-ai), create the first agent on it in the office chat.
#
# Test seams: FIVE_LOCAL_CHAT_ROOT prefixes every path; with it set,
# FIVE_PANEL_CLI names the 5dive binary the verbs call.

_lp_sock()          { printf '%s/run/5dive-local-panel.sock' "$(_lc_root)"; }
_lp_socket_unit()   { printf '%s/etc/systemd/system/5dive-local-panel.socket' "$(_lc_root)"; }
_lp_service_unit()  { printf '%s/etc/systemd/system/5dive-local-panel@.service' "$(_lc_root)"; }
_lp_audit_file()    { printf '%s/var/log/5dive/local-panel.log' "$(_lc_root)"; }
_lp_update_dir()    { printf '%s/var/lib/5dive/panel-update' "$(_lc_root)"; }
_lp_update_inbox()  { printf '%s/update/incoming.tar' "$(_lc_state)"; }   # written by the chat server
_lp_update_unit()   { printf '5dive-panel-update.service'; }
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
# DIVE-7599: a person's name (same as `local pair --name`), a device role, an AI
# server address on a private network (checked again by valid_base_url and the
# private-address rule in `account scan`), a model name.
readonly LP_PERSON_RE="^[A-Za-z0-9]([A-Za-z0-9 ._'-]{0,38}[A-Za-z0-9._'-])?$"
readonly LP_ROLE_RE='^(chat|owner)$'
readonly LP_URL_RE='^https?://[A-Za-z0-9][A-Za-z0-9.-]{0,252}(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]{0,100})?$'
readonly LP_MODEL_RE='^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,199}$'
readonly LP_SETUP_ACCOUNT=office-ai
readonly LP_VALUE_MAX=8192

# The verb table: <verb> → the pattern for each argument, in order. A verb not
# here is refused; a wrong argument count is refused.
_lp_spec() {
  case "$1" in
    team|board|secrets|settings|update-install|update-status|support-file) printf '' ;;
    agent-add)     printf 'agent account?' ;;
    agent-restart|agent-remove) printf 'agent' ;;
    gate-answer)   printf 'ident value' ;;
    secret-set)    printf 'secret' ;;
    account-test)  printf 'account' ;;
    device-revoke) printf 'device' ;;
    device-invite) printf 'person role' ;;
    ai-scan)       printf 'url?' ;;
    ai-setup)      printf 'url model agent' ;;
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
    person)  [[ "$v" =~ $LP_PERSON_RE ]] ;;
    role)    [[ "$v" =~ $LP_ROLE_RE ]] ;;
    url)     [[ "$v" =~ $LP_URL_RE ]] ;;
    model)   [[ "$v" =~ $LP_MODEL_RE ]] ;;
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
  out=$("$(_lp_cli)" --json "$@" 2>"$ef") && rc=0 || rc=$?
  err=$(tail -n 3 "$ef" 2>/dev/null)
  # DIVE-7603 (n3): LP_CLI_LOG keeps the whole output (the panel update's
  # install log); every other call keeps only the last lines, as before.
  [[ -n "${LP_CLI_LOG:-}" ]] && { cp -f -- "$ef" "$LP_CLI_LOG" && chmod 0600 -- "$LP_CLI_LOG"; } 2>/dev/null
  rm -f -- "$ef"
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
# error message (rc 1). The value for secret-set (and support-file's description) is in $LP_INPUT.
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
      # DIVE-7579: --channels=dashboard, so the new agent is in the office chat.
      # A never-linked box has no chat-only mark, and with no channel flag the
      # agent would come up with no chat at all.
      _lp_cli_json agent create "$name" --type="$h" --auth-profile="$acct" --channels=dashboard </dev/null ;;
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
    # DIVE-7886: a Support file for a box with no internet. The description
    # comes on stdin (free text never rides the socket's argv), the file is
    # exactly what `5dive bug --save` writes — the payload `5dive bug --file`
    # would send — and it goes back to the page as a string so the download is
    # those bytes. Nothing is sent anywhere, and the description stays out of
    # the audit line like a secret value does.
    support-file)
      [[ -n "${LP_INPUT//[[:space:]]/}" ]] || { printf 'Describe the problem first.'; return 1; }
      (( ${#LP_INPUT} <= 2000 )) || { printf 'the description is too long (2000 characters at most)'; return 1; }
      local sf err
      sf=$(mktemp) || { printf 'could not make the file'; return 1; }
      if ! err=$(_lp_cli_json bug --verb=support-file --what="$LP_INPUT" --save="$sf" </dev/null); then
        rm -f -- "$sf"
        [[ "$err" == *token-shaped* ]] && { printf 'Remove the password or key from your text first.'; return 1; }
        printf '%s' "$err"; return 1
      fi
      jq -Rsc --arg n "5dive-support-file-$(date -u +%Y%m%d-%H%M).json" '{name:$n, file:.}' <"$sf"
      rm -f -- "$sf" ;;
    settings)
      jq -cn --argjson lo "$(_lp_local_only_rows)" --argjson a "$(_lp_accounts)" \
        --argjson up "$(_lp_update_ready && echo true || echo false)" --arg v "${FIVE_VERSION:-}" \
        '{localOnly:$lo, accounts:$a, updateFromFile:$up, version:$v}' ;;
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
    device-invite)
      local -a fl=("--name=$1"); [[ "$2" == owner ]] && fl+=(--owner)
      _lp_cli_json local pair "${fl[@]}" </dev/null ;;
    ai-scan)
      if [[ -n "${1:-}" ]]; then _lp_cli_json account scan --url="$1" </dev/null
      else _lp_cli_json account scan </dev/null; fi ;;
    ai-setup) _lp_ai_setup "$@" ;;
    update-install) _lp_update_install ;;
    update-status)  _lp_update_status ;;
    *) printf 'unknown verb'; return 1 ;;
  esac
}

# ai-setup <address> <model> <agent> — the first-run sheet's one button. Only on
# a box with no AI account yet: a second owner tapping it later cannot move the
# office's AI from the panel (that stays `account add --replace`, on purpose).
# Claude first (Ollama speaks its format); a server that only speaks OpenAI's
# gets hermes. Nothing is saved until the test passes.
_lp_ai_setup() {
  local url="$1" model="$2" agent="$3" t h="" r reason=""
  [[ "$(_lp_accounts)" == "[]" ]] || { printf 'This server already has its AI. Change it in Settings.'; return 1; }
  for t in claude hermes; do
    r=$(_lp_cli_json account test --base-url="$url" --model="$model" --harness="$t" </dev/null) || { printf '%s' "$r"; return 1; }
    if [[ "$(jq -r '.ok' <<<"$r")" == true ]]; then h="$t"; break; fi
    reason=$(jq -r '.reason // ""' <<<"$r")
    [[ "$reason" == wrong_format ]] || break
  done
  if [[ -z "$h" ]]; then
    case "$reason" in
      unreachable)   printf 'Nothing answered at %s. Is the AI server on?' "$url" ;;
      bad_key)       printf 'That server wants a key. Set it up from a terminal for now.' ;;
      no_such_model) printf 'That server does not have %s.' "$model" ;;
      no_tools)      printf '%s answered, but cannot use tools, so an agent could not act. Pick another model.' "$model" ;;
      *)             printf '%s' "$(jq -r '.message // "That server did not answer like an AI server."' <<<"$r")" ;;
    esac
    return 1
  fi
  _lp_cli_json account add "$LP_SETUP_ACCOUNT" --provider=custom --base-url="$url" --model="$model" --harness="$h" </dev/null >/dev/null \
    || { printf 'The AI answered, but it could not be saved.'; return 1; }
  r=$(_lp_cli_json agent create "$agent" --type="$h" --auth-profile="$LP_SETUP_ACCOUNT" --channels=dashboard </dev/null) \
    || { printf 'Your AI is saved, but %s could not be created: %s' "$agent" "$r"; return 1; }
  jq -cn --arg a "$LP_SETUP_ACCOUNT" --arg h "$h" --arg u "$url" --arg m "$model" --arg n "$agent" \
    '{account:$a, harness:$h, baseUrl:$u, model:$m, agent:$n}'
}

# "Install update from file" rides `self-update --from=<file>` (DIVE-7577). It
# is in this same bundle, so the card shows whenever its verifier is. DIVE-7579
# (D4): this grepped `self-update --help` for `--from-file`, a flag that never
# existed (the verb is --from=), so the card never showed.
_lp_update_ready() { declare -F _ou_verify >/dev/null 2>&1; }

# The status file the page polls: {state: running|done|failed, message, from, to, at, log}.
# DIVE-7603 (n3): `log` is the last 20 lines the install printed (its stage
# warnings), so the Update card can show them; the whole output stays beside
# it in install.log (root, 0600). Before this, all but 3 lines were deleted.
_lp_update_write_status() { # <state> <message> [to] [log-file]
  local d f log=""; d=$(_lp_update_dir); f="$d/status.json"
  install -d -m 0700 -- "$d" 2>/dev/null || return 0
  [[ -n "${4:-}" && -f "$4" ]] && log=$(tail -n 20 -- "$4" 2>/dev/null | sed -e 's/\x1b\[[0-9;]*m//g' | head -c 3000)
  jq -cn --arg s "$1" --arg m "${2:0:600}" --arg from "${FIVE_VERSION:-}" --arg to "${3:-}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg log "$log" \
    '{state:$s, message:$m, from:$from, to:(if $to == "" then null else $to end), at:$at} + (if $log == "" then {} else {log:$log} end)' >"$f.tmp" 2>/dev/null \
    && chmod 0600 "$f.tmp" && mv -f "$f.tmp" "$f"
  return 0
}

_lp_update_running() { systemctl is-active --quiet "$(_lp_update_unit)" 2>/dev/null; }

_lp_update_status() {
  local f; f="$(_lp_update_dir)/status.json"
  if _lp_update_running; then jq -cn --arg v "${FIVE_VERSION:-}" '{state:"running", from:$v}'; return 0; fi
  if [[ -s "$f" ]] && jq -e . "$f" >/dev/null 2>&1; then
    # A run that ended without writing its verdict (killed, box rebooted).
    jq -c 'if .state == "running" then .state = "failed" | .message = "The update stopped before it finished. Nothing was reported; try it again." else . end' "$f"
    return 0
  fi
  printf '{"state":"none"}'
}

# update-install — take the file the page uploaded and start the install.
_lp_update_install() {
  local src dir copy
  src=$(_lp_update_inbox); dir=$(_lp_update_dir)
  if _lp_update_running; then rm -f -- "$src"; printf 'An update is already being installed. Wait for it to finish.'; return 1; fi
  [[ -f "$src" && ! -L "$src" && -s "$src" ]] || { printf 'No update file arrived. Pick the file again.'; return 1; }
  install -d -m 0700 -- "$dir" || { printf 'could not prepare a folder for the update'; return 1; }
  copy="$dir/update.tar"
  rm -f -- "$copy"
  # -P: a link put in the chat server's folder is copied as a link, then refused.
  if ! cp -P -- "$src" "$copy" 2>/dev/null || [[ -L "$copy" || ! -f "$copy" ]]; then
    rm -f -- "$copy" "$src"; printf 'The uploaded file could not be read. Pick it again.'; return 1
  fi
  rm -f -- "$src"
  chmod 0600 -- "$copy"
  _lp_update_write_status running "Checking the file and installing it."
  if ! _lp_spawn_update; then
    _lp_update_write_status failed "The installer could not be started."
    rm -f -- "$copy"; printf 'The installer could not be started.'; return 1
  fi
  jq -cn --arg v "${FIVE_VERSION:-}" '{state:"running", from:$v}'
}

# A transient root unit, outside this per-call instance (which the install
# would outlive) and outside the chat server it restarts.
_lp_spawn_update() {
  systemd-run --quiet --collect --unit="$(_lp_update_unit)" --description="5dive update from the office panel" \
    /usr/local/bin/5dive local _panel-update-run >/dev/null 2>&1
}

# `local _panel-update-run` (root; the transient unit runs it): install the
# copy, record the verdict in plain words, remove the copy.
_lp_update_run() {
  require_root
  local copy msg to rc log
  copy="$(_lp_update_dir)/update.tar"; log="$(_lp_update_dir)/install.log"
  [[ -f "$copy" && ! -L "$copy" ]] || { _lp_update_write_status failed "No update file was waiting."; return 0; }
  rm -f -- "$log"
  msg=$(export FIVEDIVE_PANEL_UPDATE=1 LP_CLI_LOG="$log"; _lp_cli_json self-update --from="$copy" </dev/null) && rc=0 || rc=$?
  rm -f -- "$copy"
  if (( rc == 0 )); then
    to=$("$(_lp_cli)" --json --version 2>/dev/null | jq -r '.data.version // empty' 2>/dev/null) || to=""
    _lp_update_write_status "done" "Updated${to:+ to $to}." "$to" "$log"
  else
    msg="${msg#update refused: }"
    _lp_update_write_status failed "Not installed: ${msg}" "" "$log"
  fi
  _lp_audit "panel" "update-run" "" "$( (( rc == 0 )) && printf 'ok %s' "$to" || printf 'failed: %s' "${msg:0:200}")"
  return 0
}

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
    [[ ( "${argv[0]:-}" == secret-set || "${argv[0]:-}" == support-file ) && ! -t 0 ]] && LP_INPUT=$(head -c $((LP_VALUE_MAX + 1)))
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
  # DIVE-7579 (D2): `&& rc=0 || rc=$?`, never `; rc=$?` — under the bundle's
  # `set -e` a failed action tripped errexit on the bare assignment, so the
  # helper died before the audit line and the page showed "no answer".
  local out rc
  out=$(_lp_run "${argv[@]}") && rc=0 || rc=$?
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
