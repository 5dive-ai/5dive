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

# DIVE-7573 (D2): the env that keeps Claude Code from dialing out on its own
# (telemetry, error reports, feature flags, auto-update). The local-only drop-in
# gives it to every seat's systemd unit; every OTHER Claude Code run 5dive makes
# (the plugin install at `agent create`, plugin registration, the mod probe)
# goes through sudo and never sees the unit's env, so it takes these by hand.
# The third one: at each start Claude Code tries to install its official plugin
# marketplace (Google storage, then a git clone of GitHub) until that succeeds —
# offline it never does, so every start dialed out (named in Claude Code
# 2.1.316's own strings: "Attempting to auto-install official marketplace").
# DIVE-7574 (N2): the fourth. Claude Code's `plugin install` runs `bun install
# --frozen-lockfile` on the plugin, and bun looks up registry.npmjs.org at every
# install even when every package is already there ("no changes"): 696 lookup
# lines offline under strace, 60 s of a 109 s create in the DIVE-7560 run 3. With
# the registry on this box's own discard port, the same install made 0 lookups and
# still passed; a missing package then fails in milliseconds instead of hanging.
LOCAL_ONLY_CLAUDE_ENV=(CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1
  CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1 NPM_CONFIG_REGISTRY=http://127.0.0.1:9/)
# DIVE-7730: the same for the other agent runtimes, each by its own documented
# switch (read from each one's source, then measured on a firewalled box):
#   pi        PI_OFFLINE turns off every startup network call (version check,
#             model catalog refresh, package checks); PI_TELEMETRY=0 the install
#             ping to pi.dev; PI_SKIP_VERSION_CHECK the pi.dev latest-version call.
#   opencode  auto-update, the models.dev catalog, language-server downloads and
#             the default plugins it fetches from npm at start.
#   openclaw  the gateway's auto-update, its install telemetry, and ClawHub
#             (skills and plugins), which the gateway still looked up ~75 s
#             after start with every config opt-out set: pointed at a closed
#             local port it fails at once. Its hosted model catalog and start-
#             time update hint are openclaw.json switches, written by the seat's
#             start (bin/5dive-agent-start, custom_ai_render_openclaw).
# Harmless to a runtime that does not read them, so every seat gets all of them.
LOCAL_ONLY_HARNESS_ENV=(PI_OFFLINE=1 PI_TELEMETRY=0 PI_SKIP_VERSION_CHECK=1
  OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_MODELS_FETCH=1
  OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_DISABLE_DEFAULT_PLUGINS=1
  OPENCLAW_NO_AUTO_UPDATE=1 OPENCLAW_TELEMETRY=0 OPENCLAW_CLAWHUB_URL=http://127.0.0.1:9)
# DIVE-7573 (D4): a seat on a local/custom model. Claude Code defers the chat's
# reply tool behind tool search, and a small model never calls the search: 0 of
# 4 replies from qwen3:8b in the DIVE-7560 run, every one with this set.
LOCAL_MODEL_SEAT_ENV=(ENABLE_TOOL_SEARCH=false)
# DIVE-7624: a seat on a local/custom model sends its prompts only to that model,
# so it sends Anthropic nothing else either: no usage stats, no error reports.
# Written into every custom-endpoint profile (_apply_byo_claude), local-only or
# not. Auto-update is NOT here: outside local-only mode updates stay on, and
# local-only's own list already silences all of it (NONESSENTIAL_TRAFFIC).
LOCAL_MODEL_QUIET_ENV=(DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1)

# `local_only_claude_env` — one `VAR=VALUE` per line when local-only is on,
# nothing when off. Callers: mapfile -t qe < <(local_only_claude_env); env "${qe[@]}" …
local_only_claude_env() {
  local_only_on || return 0
  printf '%s\n' "${LOCAL_ONLY_CLAUDE_ENV[@]}"
}

# DIVE-7573 (D3): every Claude Code session start refreshes the GitHub-sourced
# plugin marketplaces a seat knows (100-180 outside DNS packets per start in the
# DIVE-7560 run; it alone turned `check` red). On a local-only box a seat's
# marketplaces are its own checkouts, read in place: `directory` sources, which
# Claude Code never fetches. A remote one with no checkout on the box is dropped.
#
# `seat_marketplaces_local <home> on|off` rewrites one seat's settings.json
# extraKnownMarketplaces and plugins/known_marketplaces.json, keeping each file's
# owner and mode. `off` puts our two marketplaces back on GitHub, as a seat
# created online has them. Idempotent both ways; never fails the caller.
# `on` also gives each installed plugin's checkout folder its packages (DIVE-7574).
seat_marketplaces_local() { # <home> on|off
  local home="$1" mode="$2" s k mk have='[]' n org tmp
  s="$home/.claude/settings.json"; k="$home/.claude/plugins/known_marketplaces.json"
  mk="$home/.claude/plugins/marketplaces"
  for n in "$mk"/*/; do
    [[ -d "$n" ]] && have=$(jq -c --arg n "$(basename "$n")" '. + [$n]' <<<"$have")
  done
  org=$(gh_org 2>/dev/null || printf '5dive-ai')
  local f filter
  for f in "$s" "$k"; do
    [[ -f "$f" ]] || continue
    if [[ "$f" == "$s" ]]; then
      filter='if has("extraKnownMarketplaces") then .extraKnownMarketplaces |= (MAP) else . end'
    else
      filter='MAP'
    fi
    if [[ "$mode" == on ]]; then
      # MAP: keep directory sources, point a remote one at its checkout, drop
      # a remote one with none.
      filter=${filter//MAP/'with_entries(.key as $k |
        if (.value.source.source // "") == "directory" then .
        elif ($have | index($k)) != null then
          .value.source = {source: "directory", path: ($mk + "/" + $k)}
          | if .value | has("installLocation") then .value.installLocation = ($mk + "/" + $k) else . end
        else empty end)'}
    else
      filter=${filter//MAP/'with_entries(.key as $k |
        if (.value.source.source // "") == "directory" and (.value.source.path == ($mk + "/" + $k)) then
          if $k == "5dive-plugins" then .value.source = {source: "github", repo: ($org + "/5dive-plugins")}
          elif $k == "claude-plugins-official" then .value.source = {source: "github", repo: "anthropics/claude-plugins-official"}
          else . end
        else . end)'}
      [[ "$f" == "$s" ]] && filter="$filter"' | .extraKnownMarketplaces = ({
          "claude-plugins-official": {source: {source: "github", repo: "anthropics/claude-plugins-official"}},
          "5dive-plugins": {source: {source: "github", repo: ($org + "/5dive-plugins")}}} + (.extraKnownMarketplaces // {}))'
    fi
    tmp=$(jq --argjson have "$have" --arg mk "$mk" --arg org "$org" "$filter" "$f" 2>/dev/null) || continue
    [[ -n "$tmp" ]] || continue
    printf '%s\n' "$tmp" > "$f" 2>/dev/null || true   # in place: owner and mode kept
  done
  # DIVE-7574 (N1): a seat switched to its checkout now runs its plugins from
  # there, so the checkout needs the packages its cache copy had.
  if [[ "$mode" == on ]]; then
    local miss
    while IFS= read -r miss; do
      [[ -n "$miss" ]] && printf 'warning: %s: %s\n' "$(basename "$home")" "$miss" >&2
    done < <(seat_plugin_packages_local "$home")
  fi
  return 0
}

# DIVE-7574 (N1): a directory-source plugin runs IN PLACE, from the seat's
# marketplace checkout, not from the cache copy 5dive gave its packages to. That
# checkout is a git clone (node_modules is gitignored), so the plugin started with
# none, tried `bun install` offline and the seat never heard the office chat.
#
# `plugin_deps_complete <dir>` — 0 when every dependency the plugin's package.json
# names has node_modules/<dep>/package.json (a plugin with no package.json, or no
# dependencies, is complete). An empty node_modules — what a failed install
# leaves — is NOT complete.
plugin_deps_complete() { # <dir>
  local d="$1" dep
  [[ -f "$d/package.json" ]] || return 0
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    [[ -f "$d/node_modules/$dep/package.json" ]] || return 1
  done < <(jq -r '(.dependencies // {}) | keys[]' "$d/package.json" 2>/dev/null || printf '%s\n' '<unreadable package.json>')
  return 0
}

# `seat_plugin_run_dirs <home> <plugin@marketplace>` — every folder Claude Code
# may run that installed plugin from, one per line: its installPath (the cache
# copy) and, when the marketplace is a directory source, the plugin's folder in
# that checkout (where Claude Code actually runs it).
seat_plugin_run_dirs() { # <home> <plugin@marketplace>
  local home="$1" key="$2" p m ip mdir src
  p="${key%@*}"; m="${key#*@}"
  ip=$(jq -r --arg k "$key" '.plugins[$k][0].installPath // empty' "$home/.claude/plugins/installed_plugins.json" 2>/dev/null)
  [[ -n "$ip" && -d "$ip" ]] && printf '%s\n' "$ip"
  mdir=$(jq -r --arg m "$m" '.[$m] | select((.source.source // "") == "directory") | .source.path // empty' \
    "$home/.claude/plugins/known_marketplaces.json" 2>/dev/null)
  [[ -n "$mdir" && -f "$mdir/.claude-plugin/marketplace.json" ]] || return 0
  src=$(jq -r --arg p "$p" '.plugins[]? | select(.name == $p) | .source | strings' "$mdir/.claude-plugin/marketplace.json" 2>/dev/null | head -1)
  [[ -n "$src" && "$src" != /* && "$src" != *..* ]] || return 0
  src="$mdir/${src#./}"
  [[ -d "$src" && "$src" != "$ip" ]] && printf '%s\n' "$src"
  return 0
}

# `seat_plugin_packages_local <home>` — gives every installed plugin's run
# folders their packages, from the box itself: the plugin's own cache copy when
# that one is complete (an online install put them there), else the root-staged
# dashboard copy for the dashboard plugin. Owner of the folder kept. Also drops
# Claude Code's 15-minute failure cache, which a deaf first start wrote. Never
# fails the caller; prints one line per folder it could not fill.
seat_plugin_packages_local() { # <home>
  local home="$1" key dirs d from dash owner
  dash="${FIVEDIVE_OFFLINE_DASHBOARD_DIR:-/usr/local/lib/5dive/dashboard}/node_modules"
  [[ -f "$home/.claude/plugins/installed_plugins.json" ]] || return 0
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    mapfile -t dirs < <(seat_plugin_run_dirs "$home" "$key")
    from=""
    for d in "${dirs[@]}"; do plugin_deps_complete "$d" && [[ -d "$d/node_modules" ]] && { from="$d/node_modules"; break; }; done
    [[ -z "$from" && "${key%@*}" == dashboard && -d "$dash" ]] && from="$dash"
    for d in "${dirs[@]}"; do
      plugin_deps_complete "$d" && continue
      if [[ -n "$from" ]]; then
        owner=$(stat -c '%u:%g' "$d" 2>/dev/null) || owner=""
        rm -rf -- "$d/node_modules" && cp -a -- "$from" "$d/node_modules" \
          && { [[ -z "$owner" ]] || chown -R "$owner" "$d/node_modules" 2>/dev/null || true; }
      fi
      plugin_deps_complete "$d" || printf '%s\n' "no packages for ${key%@*} in $d (this box holds no copy to give it)"
    done
  done < <(jq -r '(.plugins // {}) | keys[]' "$home/.claude/plugins/installed_plugins.json" 2>/dev/null)
  rm -f -- "$home/.claude/mcp-needs-auth-cache.json" 2>/dev/null || true
  return 0
}

# DIVE-7558: five_api_base / five_api_base_file live in src/header.sh (the relay
# and partner harnesses source header.sh, not this file).

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

# DIVE-7579 (D3): a command that CREATES a seat (agent create, hire, agent
# import) may instead name --auth-profile=<account> whose saved model address is
# on the office network: the own-AI account `account add --provider=custom`
# saves (DIVE-7568), or one a `--base-url` create made. That is exactly what the
# office panel's Add agent runs and what `account add` prints as the next step;
# both were refused. An account with no saved address (a cloud sign-in) is
# refused, and so is one where ANY saved address is outside the office. Only the
# create verbs: `auth set --auth-profile=<local account>` writes credentials and
# still needs its own --base-url.
_lo_create_model_ok() {
  local a url="" prof="" creds=0
  for a in "$@"; do
    case "$a" in
      --base-url=*) url="${a#--base-url=}" ;;
      --auth-profile=*) prof="${a#--auth-profile=}" ;;
      --provider=*|--api-key=*|--own-login) creds=1 ;;   # would write new credentials onto it
    esac
  done
  if [[ -z "$url" && -n "$prof" ]] && (( ! creds )); then
    _lo_profile_is_local "$prof" && return 0
    local_only_refuse "The AI account '${prof:0:40}' (it has no model server on your network)"
  fi
  _lo_model_target_ok "$@"
}

# `_lo_profile_model_urls <account>` — the model addresses the account saved,
# one per line (FIVEDIVE_CUSTOM_BASE_URL, ANTHROPIC_BASE_URL, OPENAI_BASE_URL).
# Nothing for a name that is not a valid account name.
_lo_profile_model_urls() {
  local p="$1" v k
  [[ "$p" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || return 0
  declare -F profile_env_value >/dev/null || return 0
  for k in FIVEDIVE_CUSTOM_BASE_URL ANTHROPIC_BASE_URL OPENAI_BASE_URL; do
    v=$(profile_env_value "$p" "$k")
    [[ -n "$v" ]] && printf '%s\n' "$v"
  done
  return 0
}

# `_lo_profile_is_local <account>` — 0 when the account saved at least one model
# address and every one of them is on the office network.
_lo_profile_is_local() {
  local u n=0
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    n=$((n + 1))
    local_only_url_is_local "$u" || return 1
  done < <(_lo_profile_model_urls "$1")
  (( n > 0 ))
}

# `_lo_source_is_local <spec>` — an install source is local when it names an
# existing file or directory on this box. Anything else (owner/repo, a URL, a
# market slug) would be fetched from the internet.
_lo_source_is_local() { [[ -n "$1" && ( "$1" == /* || "$1" == ./* || "$1" == ../* ) && -e "$1" ]]; }

_lo_channels_outside() {   # <csv> → 0 when it names a channel that dials out
  local c
  IFS=',' read -r -a _lo_cs <<<"$1"
  for c in "${_lo_cs[@]}"; do
    case "$c" in telegram|discord|buzz|teams) return 0 ;; esac
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
      --channels=*) _lo_channels_outside "${a#--channels=}" && local_only_refuse "Telegram, Discord, Buzz and Microsoft Teams" ;;
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
  case "${top}" in  # not "$top": install-contract T4 takes the 2nd such line in the bundle as the verb table
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
      _lo_create_model_ok "$@" ;;
    bug)
      for a in "$@"; do
        [[ "$a" == --file ]] && local_only_refuse "Sending a bug report to 5dive"
      done ;;
    self-update|self_update|update)
      case "$sub" in
        --status|--off|--nightly|-h|--help|help) ;;   # --nightly: cmd skips quietly
        --write-pubkey) ;;   # DIVE-7577: pins the key the CLI carries; no network
        # DIVE-7577: a signed file from a disk. Only the two flags that verb takes,
        # so `--check --from=x` (which would dial) is still refused.
        --from=*|--allow-downgrade) for a in "$@"; do [[ "$a" == --from=* ]] && return 0; done
           local_only_refuse "Updating from the internet (to update from a disk: sudo 5dive self-update --from=<file>)" ;;
        *) local_only_refuse "Updating from the internet (to update from a disk: sudo 5dive self-update --from=<file>)" ;;
      esac ;;
    plugin|plugins)
      case "$sub" in
        add|install|upgrade|update)
          _lo_source_is_local "${2:-}" || local_only_refuse "Installing plugins from the internet" ;;
        marketplace)
          # marketplace add <owner/repo|git-url> git-clones from GitHub; a
          # folder on this box is copied. upgrade/update re-fetches every git
          # source (a local one is re-added: remove, then add the folder).
          case "${2:-}" in
            add) _lo_source_is_local "${3:-}" || local_only_refuse "Adding a plugin marketplace from the internet" ;;
            upgrade|update) local_only_refuse "Refreshing plugin marketplaces from the internet" ;;
          esac ;;
      esac ;;
    tool|tools)
      # tool google start|submit run Google's sign-in (accounts.google.com).
      # poll/cancel only read or stop a local session; set/rm store a key.
      [[ "$sub" == google ]] && case "${2:-}" in
        start|submit) local_only_refuse "Signing in to Google" ;;
      esac ;;
    hire-link)
      # Every path calls 5dive's servers: a slug reads the online catalogue and
      # asks for a link, --create drafts on 5dive, --hire hires through it.
      local_only_refuse "Hire links (they are made on 5dive's servers)" ;;
    pkg)
      # apt fetches from the internet mirrors in the box's sources list. An
      # office with its own mirror installs as root with apt directly.
      [[ "$sub" == install ]] && local_only_refuse "Installing system packages from the internet" ;;
    buzz)           [[ "$sub" == enable ]] && local_only_refuse "Buzz" ;;
    chat)
      # DIVE-7558: the office chat on this box is the only server and TLS covers
      # the network hop, so there is no outside server to seal against.
      [[ "$sub" == e2e && "${2:-}" == enable ]] \
        && local_only_refuse "End-to-end chat pairing with 5dive.app (the office chat on this server replaces it)" ;;
    account)
      case "$sub" in
        login) local_only_refuse "Signing in to a cloud AI account" ;;
        set)   _lo_model_target_ok "${@:2}" ;;
        # DIVE-7568: your own AI server — only one on the office network.
        test)  _lo_model_target_ok "${@:2}" ;;
        add)   [[ " ${*:2} " == *" --provider=custom "* ]] && _lo_model_target_ok "${@:2}" ;;
      esac ;;
    agent)
      shift || true
      case "$sub" in
        a2a-vouch)  local_only_refuse "a2a (messages to agents on other servers)" ;;
        first-job|_first_job_run) local_only_refuse "The first-job intro (it runs through 5dive's servers)" ;;
        _tg_connect_greet|_telegram_open|telegram-*|team-bot|team-group|pair|topic|cos)
                    local_only_refuse "Telegram" ;;
        buzz)       [[ "${1:-}" == enable || "${2:-}" == enable ]] && local_only_refuse "Buzz" ;;
        # DIVE-7658: Teams messages go through Microsoft's cloud.
        teams)      [[ "${1:-}" == connect || "${2:-}" == connect ]] && local_only_refuse "Microsoft Teams (it goes through Microsoft's cloud)" ;;
        install)    local_only_refuse "Installing an agent program from the internet" ;;
        pack-sync)  local_only_refuse "Updating agent packs from the internet" ;;
        switch)     local_only_refuse "Switching an agent to another AI service" ;;
        set-account) local_only_refuse "Binding an agent to a cloud AI account" ;;
        create)
          _lo_channel_flags_ok "$@"
          for a in "$@"; do
            case "$a" in --with-skills=?*) local_only_refuse "Installing skills from the internet" ;; esac
          done
          _lo_create_model_ok "$@" ;;
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
          _lo_create_model_ok "$@" ;;
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
              channels=*) _lo_channels_outside "${a#channels=}" && local_only_refuse "Telegram, Discord, Buzz and Microsoft Teams" ;;
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
