# ── DIVE-7557: local-only mode — one switch, nothing leaves the office ───────
#
# /etc/5dive/local-only (root 0644, EXISTS = ON) is THE switch every component
# reads: this CLI, the plugins (DIVE-7559) and the office chat server
# (DIVE-7558). Absent = today's behaviour, byte for byte — every function here
# returns "allowed" when the file is not there, so a box that never turns the
# mode on pays one stat per command and nothing else.
#
# This file holds the READ side (is it on, is this URL on the office network,
# may this command run). The WRITE side — `sudo 5dive config local-only
# on|off|status|check` — is src/cmd_local_only.sh.
#
# The refusals are a promise to the OWNER, not a sandbox: a seat that wants to
# reach the internet can run curl. What the switch guarantees is that nothing
# 5dive does on its own, and no 5dive command anyone types, opens an outside
# connection while it is on, and that `check` proves it.

local_only_file() { printf '%s' "${FIVE_LOCAL_ONLY_FILE:-/etc/5dive/local-only}"; }
local_only_on()   { [[ -e "$(local_only_file)" ]]; }

# `_lo_host_is_local <host>` — 0 when the host is this box or on a private
# network: loopback, RFC1918 (10/8, 172.16/12, 192.168/16), link-local, IPv6
# loopback/ULA/link-local, `localhost`, a single-label name, or a name under a
# suffix that cannot be a public DNS name (.local .lan .internal .home.arpa
# .localhost). A public name or address is refused: the whole point is that a
# lawyer's prompt never reaches a server outside the building.
_lo_host_is_local() {
  local h="${1,,}" a b
  h="${h#[}"; h="${h%]}"
  [[ -n "$h" ]] || return 1
  if [[ "$h" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
    (( a <= 255 && b <= 255 && BASH_REMATCH[3] <= 255 && BASH_REMATCH[4] <= 255 )) || return 1
    (( a == 127 || a == 10 )) && return 0
    (( a == 172 && b >= 16 && b <= 31 )) && return 0
    (( a == 192 && b == 168 )) && return 0
    (( a == 169 && b == 254 )) && return 0
    return 1
  fi
  if [[ "$h" == *:* ]]; then
    [[ "$h" == "::1" ]] && return 0
    [[ "$h" =~ ^f[cd][0-9a-f]{0,2}: ]] && return 0      # fc00::/7 unique-local
    [[ "$h" =~ ^fe[89ab][0-9a-f]?: ]] && return 0       # fe80::/10 link-local
    [[ "$h" =~ ^::ffff:([0-9.]+)$ ]] && { _lo_host_is_local "${BASH_REMATCH[1]}"; return; }
    return 1
  fi
  [[ "$h" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || return 1
  [[ "$h" == localhost || "$h" != *.* ]] && return 0
  case "$h" in
    *.local|*.lan|*.internal|*.home.arpa|*.localhost) return 0 ;;
  esac
  return 1
}

# `local_only_url_is_local <url>` — 0 for an http(s) URL whose host passes
# _lo_host_is_local. Userinfo and port are stripped; any other scheme is not a
# model endpoint and is refused.
local_only_url_is_local() {
  local url="$1" rest host
  case "$url" in
    http://*)  rest="${url#http://}" ;;
    https://*) rest="${url#https://}" ;;
    *) return 1 ;;
  esac
  rest="${rest%%/*}"; rest="${rest%%\?*}"; rest="${rest%%#*}"
  rest="${rest##*@}"
  if [[ "$rest" == \[*\]* ]]; then host="${rest%%\]*}]"; else host="${rest%:*}"; fi
  _lo_host_is_local "$host"
}

# The one refusal sentence. Plain words: the owner reads this, not a developer.
local_only_refuse() {
  fail "$E_PERMISSION" "$1 is turned off on this box: local-only mode is on, so nothing may connect outside your network. To allow it again, an admin runs: sudo 5dive config local-only off"
}

# `_lo_model_target_ok <args...>` — a model credential or endpoint command
# (agent create, account set, agent auth set) is allowed only with a --base-url
# on the office network. With no --base-url the agent would talk to a cloud
# provider (Anthropic, OpenAI, OpenRouter…), so it is refused.
_lo_model_target_ok() {
  local a url=""
  for a in "$@"; do
    case "$a" in --base-url=*) url="${a#--base-url=}" ;; esac
  done
  [[ -n "$url" ]] || local_only_refuse "A cloud AI model (no --base-url on your network was given)"
  local_only_url_is_local "$url" \
    || local_only_refuse "The model server '${url:0:120}' (it is outside your network)"
}

# `_lo_source_is_local <spec>` — an install source is local when it names an
# existing file or directory on this box. Anything else (owner/repo, a URL, a
# market slug) would be fetched from the internet.
_lo_source_is_local() { [[ -n "$1" && ( "$1" == /* || "$1" == ./* || "$1" == ../* ) && -e "$1" ]]; }

_lo_channels_outside() {   # <csv> → 0 when it names a channel that dials out
  local c
  IFS=',' read -r -a _lo_cs <<<"$1"
  for c in "${_lo_cs[@]}"; do
    case "$c" in telegram|discord|buzz) return 0 ;; esac
  done
  return 1
}

# `_lo_channel_flags_ok <args...>` — refuse Telegram/Discord/Buzz channels and
# bot tokens on create/clone.
_lo_channel_flags_ok() {
  local a
  for a in "$@"; do
    case "$a" in
      --telegram-*|--discord-token=*) local_only_refuse "Telegram and Discord" ;;
      --channels=*) _lo_channels_outside "${a#--channels=}" && local_only_refuse "Telegram, Discord and Buzz" ;;
    esac
  done
  return 0
}

# `local_only_gate <top> [args...]` — called once by main() before dispatch.
# Returns 0 when the command may run; otherwise fail()s with the refusal (which
# exits). With the switch off it returns at the first line. Pure function of
# argv + the flag file, so the unit harness drives it without running a verb.
local_only_gate() {
  local_only_on || return 0
  local a
  for a in "$@"; do case "$a" in -h|--help) return 0 ;; esac; done   # asking is never refused
  local top="${1:-}"; shift || true
  local sub="${1:-}"
  case "$top" in
    a2a)            local_only_refuse "a2a (messages to agents on other servers)" ;;
    market)         local_only_refuse "The agent market" ;;
    telegram-app)   local_only_refuse "The Telegram app" ;;
    partner)        [[ "$sub" == hire ]] && local_only_refuse "Hiring through a partner" ;;
    hire)
      # hire creates a seat (cmd_create in-process, so this gate never sees
      # that inner call): the same channel and model rules as agent create.
      for a in "$@"; do
        case "$a" in --from-market|--market) local_only_refuse "Hiring from the agent market" ;; esac
      done
      _lo_channel_flags_ok "$@"
      _lo_model_target_ok "$@" ;;
    bug)
      for a in "$@"; do
        [[ "$a" == --file ]] && local_only_refuse "Sending a bug report to 5dive"
      done ;;
    self-update|self_update|update)
      case "$sub" in
        --status|--off|--nightly|-h|--help|help) ;;   # --nightly: cmd skips quietly
        *) local_only_refuse "Updating from the internet" ;;
      esac ;;
    plugin|plugins)
      case "$sub" in
        add|install|upgrade|update)
          _lo_source_is_local "${2:-}" || local_only_refuse "Installing plugins from the internet" ;;
      esac ;;
    buzz)           [[ "$sub" == enable ]] && local_only_refuse "Buzz" ;;
    account)
      case "$sub" in
        login) local_only_refuse "Signing in to a cloud AI account" ;;
        set)   _lo_model_target_ok "${@:2}" ;;
      esac ;;
    agent)
      shift || true
      case "$sub" in
        a2a-vouch)  local_only_refuse "a2a (messages to agents on other servers)" ;;
        first-job|_first_job_run) local_only_refuse "The first-job intro (it runs through 5dive's servers)" ;;
        _tg_connect_greet|_telegram_open|telegram-*|team-bot|team-group|pair|topic|cos)
                    local_only_refuse "Telegram" ;;
        buzz)       [[ "${1:-}" == enable || "${2:-}" == enable ]] && local_only_refuse "Buzz" ;;
        install)    local_only_refuse "Installing an agent program from the internet" ;;
        pack-sync)  local_only_refuse "Updating agent packs from the internet" ;;
        switch)     local_only_refuse "Switching an agent to another AI service" ;;
        set-account) local_only_refuse "Binding an agent to a cloud AI account" ;;
        create)
          _lo_channel_flags_ok "$@"
          for a in "$@"; do
            case "$a" in --with-skills=?*) local_only_refuse "Installing skills from the internet" ;; esac
          done
          _lo_model_target_ok "$@" ;;
        clone)      _lo_channel_flags_ok "$@" ;;
        import)
          # agent import <slug|./pack.tar.gz> | --from-persona=<file> — a pack
          # from the registry or a URL is fetched; a file on this box is not.
          # It then creates the seat, so the model rule applies too.
          local src="" persona=""
          for a in "$@"; do
            case "$a" in
              --report-import) local_only_refuse "Reporting a pack import to 5dive" ;;
              --from-url=*)    local_only_refuse "Installing an agent pack from the internet" ;;
              --from-persona=*) persona="${a#--from-persona=}" ;;
              -*) ;;
              *) [[ -n "$src" ]] || src="$a" ;;
            esac
          done
          _lo_source_is_local "${persona:-$src}" || local_only_refuse "Installing an agent pack from the internet"
          _lo_channel_flags_ok "$@"
          _lo_model_target_ok "$@" ;;
        skill)
          # agent skill <name>|--all add --source=<owner/repo> … — always GitHub
          # unless the source is a directory on this box. list/rm/give are local.
          if [[ "${2:-}" == add ]]; then
            local srcs=""
            for a in "$@"; do case "$a" in --source=*) srcs="${a#--source=}" ;; esac; done
            _lo_source_is_local "$srcs" || local_only_refuse "Installing skills from the internet"
          fi ;;
        config)
          # agent config <name> set k=v [k=v...]
          [[ "${2:-}" == set ]] || return 0
          for a in "${@:3}"; do
            case "$a" in
              telegram.*|discord.*) local_only_refuse "Telegram and Discord" ;;
              channels=*) _lo_channels_outside "${a#channels=}" && local_only_refuse "Telegram, Discord and Buzz" ;;
            esac
          done ;;
        auth)
          case "${1:-}" in
            login|start|submit) local_only_refuse "Signing in to a cloud AI account" ;;
            set) _lo_model_target_ok "${@:2}" ;;
          esac ;;
      esac ;;
  esac
  return 0
}
