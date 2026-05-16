# -------- top-level dispatch --------

usage() {
  cat <<USAGE
5dive — 5dive agent manager

Global flags:
  --json                              Emit machine-readable output on stdout
                                      ({ok:true,data:...} | {ok:false,error:{...}}).
                                      Works on any subcommand below.

Maintenance:
  5dive --version                                    # print version
  5dive init                                         # interactive first-run wizard
  5dive uninstall [--purge] [--yes]                  # remove 5dive (--purge also wipes state + user)

Live dashboard:
  5dive watch [--interval=N]                         # htop-style live view of every agent;
                                                     # ↑↓ select, ↵ attach, r refresh, q quit.
  5dive ui [--host=<addr>] [--port=<n>]              # local web dashboard. Defaults to
                                                     # 127.0.0.1:5175 (loopback). Setting --host
                                                     # to a non-loopback address exposes the API
                                                     # to your network — set up auth first via
                                                     # '5dive ui setup'.

Compose (declarative agents via 5dive.yaml):
  5dive up   [-f file]                               # bring up agents declared in spec (idempotent)
  5dive down [-f file]                               # tear down declared agents
  5dive ps   [-f file]                               # show declared agents' state
  # Default file: 5dive.yaml or 5dive.yml in cwd.
  # Schema (v1) — see 'agents' map keys: type, channels, telegram_token,
  # discord_token, workdir, skills, no_skills, defer_auth, isolation,
  # auth_profile, provider, api_key. Strings expand "\${ENV_VAR}" from the
  # process env (missing vars fail loudly).

Agents:
  5dive agent list
  5dive agent types
  5dive agent create <name> --type=<type> [--channels=none|telegram|discord]
                            [--telegram-token=<bot-token>] [--discord-token=<token>]
                            [--workdir=<path>] [--auth-profile=<name>]
                            [--provider=<id> --api-key=<key|->]
                            [--with-skills=<spec>[,<spec>...]] [--no-skills]
                            [--defer-auth]
                            # spec: <id> (defaults to ${DEFAULT_SKILL_SOURCE}) or <owner/repo>:<id>
                            # provider: hermes/openclaw only — BYO API key for one of
                            # ${!BYO_PROVIDER_LABEL[*]}. Mutually exclusive with --defer-auth.
                            # When called by another agent on a claude-typed agent,
                            # defaults to --with-skills=5dive-cli so the new agent
                            # inherits inter-agent comms knowledge. Use --no-skills
                            # to opt out. --defer-auth skips the auth gate so the
                            # agent can be created before credentials exist; useful
                            # when the agent's own first-run UI handles sign-in.
  5dive agent clone <src> <dst> [--channels=...] [--telegram-token=...]
                                [--discord-token=...] [--workdir=...]
  5dive agent start <name>
  5dive agent stop <name>
  5dive agent restart <name>
  5dive agent rm <name>
  5dive agent config <name> set channels=<none|telegram|discord>
  5dive agent config <name> set workdir=<path>       # tmux cwd; "default" clears override
  5dive agent config <name> set auth-profile=<name>  # swap profile; "default" clears override
  5dive agent config <name> set telegram.token=<bot-token>
                                                     # combine with channels=telegram to attach a Telegram bot
                                                     # post-create (also runs install_channel_for_agent so the
                                                     # claude plugin / openclaw channels.add / hermes ~/.hermes/.env
                                                     # land in step with the registry).
  5dive agent config <name> set discord.token=<token>
  5dive agent config <name> set telegram.home-channel=<chat-id>
                                                     # hermes only — chat id the gateway posts unsolicited
                                                     # messages to; ignored by claude/openclaw.
  5dive agent config <name> set telegram.allowed-users=<id1,id2,...>
                                                     # comma-separated numeric user ids; seeds
                                                     # access.json/openclaw.allowFrom/hermes env so the bot
                                                     # forwards DMs from these users without a pair-code gate.
  5dive agent pair <name> [--code=<code> | --user-id=<id> [--chat-id=<id>]]
                                                     # telegram/discord pairing. --code accepts the bot reply or
                                                     # bare pairing code. --user-id seeds access.json directly
                                                     # (auto-detected via telegram-discover; chat_id defaults
                                                     # to user_id for private DMs).
  5dive agent telegram-discover --token=<bot-token> [--poll-secs=N]
                                                     # long-polls Telegram getUpdates (timeout N, max 90s).
                                                     # On first inbound message returns {found:true, userId,
                                                     # chatId, username, firstName}; otherwise {found:false} —
                                                     # callers re-poll until found.
  5dive agent telegram-getme --token=<bot-token>     # fast getMe lookup; returns {botId, username, firstName}.
  5dive agent telegram-info <name> [--refresh]       # name-based getMe; reads token from /etc/5dive/connectors,
                                                     # caches botUsername in the registry. Used by the dashboard
                                                     # to backfill @handles for agents created before the
                                                     # botUsername-on-create change. --refresh forces re-fetch.
  5dive agent telegram-access get <name>             # read access.json: who can DM the bot, group settings.
  5dive agent telegram-access set <name>             # write access.json from {dmPolicy,allowFrom,groups} JSON
                                                     # piped on stdin. Plugin re-reads per-message — no restart.
  5dive agent <name> tui                             # attach your terminal to the agent's tmux session
  5dive agent logs <name> [--follow] [--lines=N] [--tmux]
  5dive agent send <name> <text...> [--from=<sender>] [--raw]
                                                     # inject a message (tmux send-keys + Enter).
                                                     # When called from another agent, auto-wraps as
                                                     # [5dive-msg from=<caller> id=<id>] so the
                                                     # receiver sees who's pinging it. --raw skips wrapping.
  5dive agent ask <name> <text...> [--from=<sender>] [--timeout=120] [--idle-secs=5] [--poll-secs=2]
                                                     # synchronous send + wait. Polls scrollback after
                                                     # the marker line until it stops growing for
                                                     # --idle-secs, then prints the reply body.
  5dive agent stats <name>                           # state, restart count, last exit
  5dive agent install <type>                         # install the CLI for a type if missing
  5dive agent set-account <agent> <account|default>  # rebind to a named account; "default" clears

Default workdir: ${DEFAULT_WORKDIR}

Accounts (a named auth profile — group sign-ins so multiple agents share one login):
  5dive account list                                   # name, types signed in, # agents bound
  5dive account show <name>                            # detail incl. env keys present
  5dive account add <name>                             # create empty account; sign in next
  5dive account login <name> --type=<type>             # interactive TTY login into an account
  5dive account rename <old> <new>                     # repoints all bound agents + restarts them
  5dive account remove <name>                          # refuses if any agents still bound

Auth (lower-level; the dashboard uses these — prefer 'account' for human-driven flows):
  5dive agent auth status [--probe] [--type=<type>]    # real --print probe reveals stale creds
  5dive agent auth login <type>                        # interactive TTY (hands off this process)
  5dive agent auth set <type> --api-key=<key|-> [--auth-profile=<name>] [--provider=<id>]
                                                       # --provider=<id> required for hermes/openclaw;
                                                       # id is one of: ${!BYO_PROVIDER_LABEL[*]}
  5dive agent auth start <type> [--auth-profile=<name>]      # non-TTY device-code: returns session id
  5dive agent auth poll <session_id>                         # {state, url, error}
  5dive agent auth submit <session_id> --code=<callback>     # paste the claude callback code
  5dive agent auth cancel <session_id>

Health:
  5dive doctor [--repair] [--category=deps|types|auth|registry|shelld]
    Walks deps (tmux/jq/bun/python3/nvm/node/npm), type bins, live auth
    probes, registry integrity, and shelld reachability. --repair attempts
    reversible fixes (apt installs, type installer recipes, bun, shelld
    restart, registry reseed). Output envelope always {ok:true,data:{...}};
    branch on data.summary.errors in CI.

Types: ${!TYPE_BIN[*]}

Exit codes (also surfaced as error.code in --json mode):
  0 ok       2 usage       3 validation   4 not_found    5 conflict
  6 auth_required  7 not_installed  8 not_running  9 pairing
  10 permission  11 timeout         1 generic
USAGE
}

main() {
  # Global --json: strip every occurrence before dispatch so each subcommand
  # gets the same arg shape regardless of where the flag was placed.
  local -a rest=()
  local a
  for a in "$@"; do
    if [[ "$a" == "--json" ]]; then
      JSON_MODE=1
      continue
    fi
    rest+=("$a")
  done
  set -- "${rest[@]+"${rest[@]}"}"

  [[ $# -gt 0 ]] || { usage; exit "$E_USAGE"; }
  local top="$1"; shift
  # Handle --version / -v / version before the dispatch table so it stays a
  # zero-dependency one-liner check (reviewers grep for it first).
  case "$top" in
    -v|--version|version)
      if [[ "${JSON_MODE:-0}" == 1 ]]; then
        printf '{"ok":true,"data":{"version":"%s"}}\n' "$FIVE_VERSION"
      else
        echo "5dive $FIVE_VERSION"
      fi
      exit 0
      ;;
  esac
  # Mutating commands run under with_registry_lock so adduser/registry_write
  # can't race across concurrent dashboard clicks. Read-only commands (list,
  # logs, stats, types, auth status/poll) bypass the lock and the audit log.
  case "$top" in
    agent)
      [[ $# -gt 0 ]] || { usage; exit "$E_USAGE"; }
      local sub="$1"; shift
      case "$sub" in
        list)    cmd_list "$@" ;;
        types)   cmd_types "$@" ;;
        logs)    cmd_logs "$@" ;;
        send)    cmd_send "$@" ;;
        ask)     cmd_ask "$@" ;;
        stats)   cmd_stats "$@" ;;
        create)
          AUDIT_CMD="agent create"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_create "$@" ;;
        clone)
          AUDIT_CMD="agent clone"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_clone "$@" ;;
        start)
          AUDIT_CMD="agent start"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_start "$@" ;;
        stop)
          AUDIT_CMD="agent stop"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_stop "$@" ;;
        restart)
          AUDIT_CMD="agent restart"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_restart "$@" ;;
        rm)
          AUDIT_CMD="agent rm"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_rm "$@" ;;
        config)
          AUDIT_CMD="agent config"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_config "$@" ;;
        pair)
          AUDIT_CMD="agent pair"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_pair "$@" ;;
        telegram-discover)
          # Read-only Telegram getUpdates poll — no registry mutation, no
          # state changes. Bot token would clutter the audit log if it were
          # passed verbatim, so skip auditing too (the post-pair allowlist
          # write is auditable on its own through cmd_pair).
          cmd_telegram_discover "$@" ;;
        telegram-getme)
          # Read-only bot identity lookup. Same audit/lock rationale as
          # telegram-discover.
          cmd_telegram_getme "$@" ;;
        telegram-info)
          # Mostly read; cache miss takes the registry lock internally to
          # write back the resolved botUsername. No audit — backfill is
          # idempotent and not worth log noise.
          cmd_telegram_info "$@" ;;
        telegram-access)
          [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive agent telegram-access get|set <name>"
          local accesscmd="$1"; shift
          case "$accesscmd" in
            get) cmd_telegram_access_get "$@" ;;  # read-only, no audit
            set)
              AUDIT_CMD="agent telegram-access set"; AUDIT_ARGS=("$@")
              cmd_telegram_access_set "$@" ;;
            *) fail "$E_USAGE" "unknown telegram-access command: $accesscmd" ;;
          esac ;;
        install)
          AUDIT_CMD="agent install"; AUDIT_ARGS=("$@")
          cmd_install "$@" ;;   # no registry mutation; auditable install recipe
        set-account)
          AUDIT_CMD="agent set-account"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_agent_set_account "$@" ;;
        skill)
          AUDIT_CMD="agent skill"; AUDIT_ARGS=("$@")
          cmd_skill "$@" ;;     # add/list/rm operate on the agent type's skills dir
        auth)
          [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive agent auth status|login|set|start|poll|submit|cancel"
          local authcmd="$1"; shift
          case "$authcmd" in
            status) cmd_auth_status "$@" ;;
            poll)   cmd_auth_poll "$@" ;;
            login)
              # exec-handoff — EXIT trap won't fire, so log the intent now.
              audit_log "agent auth login" "started" 0 -- "$@"
              cmd_auth_login "$@" ;;
            set)
              AUDIT_CMD="agent auth set"; AUDIT_ARGS=("$@")
              cmd_auth_set "$@" ;;
            start)
              AUDIT_CMD="agent auth start"; AUDIT_ARGS=("$@")
              cmd_auth_start "$@" ;;
            submit)
              AUDIT_CMD="agent auth submit"; AUDIT_ARGS=("$@")
              cmd_auth_submit "$@" ;;
            cancel)
              AUDIT_CMD="agent auth cancel"; AUDIT_ARGS=("$@")
              cmd_auth_cancel "$@" ;;
            *) fail "$E_USAGE" "unknown auth command: $authcmd" ;;
          esac ;;
        *)
          # `5dive agent <name> tui` — name-first form for terminal attach.
          if [[ "${1:-}" == "tui" ]]; then
            cmd_tui "$sub"
          else
            fail "$E_USAGE" "unknown agent command: $sub"
          fi ;;
      esac ;;
    account)
      [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive account list|show|add|rename|remove|login|set-active-provider"
      local acctcmd="$1"; shift
      case "$acctcmd" in
        list)   cmd_account_list "$@" ;;
        show)   cmd_account_show "$@" ;;
        add)
          AUDIT_CMD="account add"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_account_add "$@" ;;
        rename)
          AUDIT_CMD="account rename"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_account_rename "$@" ;;
        remove|rm)
          AUDIT_CMD="account remove"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_account_remove "$@" ;;
        login)
          # exec-handoff like `agent auth login` — log intent now, the
          # EXIT trap won't fire after exec.
          audit_log "account login" "started" 0 -- "$@"
          cmd_account_login "$@" ;;
        set-active-provider)
          AUDIT_CMD="account set-active-provider"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_account_set_active_provider "$@" ;;
        *) fail "$E_USAGE" "unknown account command: $acctcmd" ;;
      esac ;;
    doctor)
      # Only audit when --repair is set (read-only runs would spam the log).
      for a in "$@"; do
        if [[ "$a" == "--repair" ]]; then
          AUDIT_CMD="doctor"; AUDIT_ARGS=("$@")
          break
        fi
      done
      cmd_doctor "$@" ;;
    paperclip-seed)
      # Internal: backfill /home/claude/.<type>/ symlinks from registered
      # agents so paperclipai (running as user `claude`) sees the same auth
      # the agents use. Called from update.sh; safe to invoke manually too.
      ensure_state
      paperclip_seed_all_from_registry
      ok "paperclip credentials seeded from registry" '{seeded:true}' ;;
    watch)
      # Live multi-agent dashboard (htop-style). Read-only — no audit, no lock.
      cmd_watch "$@" ;;
    init)
      # Interactive first-run wizard: pick a type → install → auth → create
      # → "send hello". Calls back into the same CLI for each step.
      AUDIT_CMD="init"; AUDIT_ARGS=("$@")
      cmd_init "$@" ;;
    up)
      # Compose-style: bring up agents declared in 5dive.yaml. Mutating but
      # the per-agent `agent create` calls take the registry lock + audit
      # themselves, so no need to wrap here.
      AUDIT_CMD="up"; AUDIT_ARGS=("$@")
      cmd_compose_up "$@" ;;
    down)
      AUDIT_CMD="down"; AUDIT_ARGS=("$@")
      cmd_compose_down "$@" ;;
    ps)
      # Read-only — no audit, no lock.
      cmd_compose_ps "$@" ;;
    ui)
      # Local dashboard UI.
      #   5dive ui                       # start server (loopback by default)
      #   5dive ui setup                 # configure password auth (interactive)
      #   5dive ui --host=0.0.0.0 ...    # expose to network (requires setup)
      local ui_dir
      if [[ -d "$(dirname "$(realpath "$0")")/ui" ]]; then
        ui_dir="$(dirname "$(realpath "$0")")/ui"
      elif [[ -d /usr/local/lib/5dive/ui ]]; then
        ui_dir="/usr/local/lib/5dive/ui"
      else
        fail "$E_NOT_FOUND" "5dive UI not found — install it at /usr/local/lib/5dive/ui or run from the 5dive-cli repo directory"
      fi

      # `5dive ui setup` — one-shot interactive password setup
      if [[ "${1:-}" == "setup" ]]; then
        shift
        cd "$ui_dir"
        exec bun run setup.ts "$@"
      fi

      # Defaults to 127.0.0.1:5175 — loopback-only because without auth the
      # API exposes shell-level agent control. Override with --host= /
      # --port=; non-loopback bind will refuse to start unless `ui setup`
      # has been run (or --insecure is passed).
      local ui_host=""
      local ui_port=""
      local ui_insecure=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --host=*)   ui_host="${1#--host=}"; shift ;;
          --port=*)   ui_port="${1#--port=}"; shift ;;
          --host)     ui_host="${2:-}"; shift 2 ;;
          --port)     ui_port="${2:-}"; shift 2 ;;
          --insecure) ui_insecure=1; shift ;;
          [0-9]*)     ui_port="$1"; shift ;;  # legacy positional port
          *)          fail "$E_USAGE" "unknown ui flag: $1" ;;
        esac
      done
      cd "$ui_dir"
      # Only set env vars when the flag was actually given, so direct
      # `HOST=... 5dive ui` still flows through to the server.
      local -a ui_env=()
      [[ -n "$ui_host" ]] && ui_env+=("HOST=$ui_host")
      [[ -n "$ui_port" ]] && ui_env+=("PORT=$ui_port")
      [[ -n "$ui_insecure" ]] && ui_env+=("INSECURE=$ui_insecure")
      if [[ ${#ui_env[@]} -gt 0 ]]; then
        exec env "${ui_env[@]}" bun run server.ts
      else
        exec bun run server.ts
      fi ;;
    uninstall)
      # Thin wrapper: fetch install.sh and exec --uninstall. Keeps a single
      # source of truth for what gets removed (install.sh) and dodges the
      # "old bundles ship stale uninstall logic" problem.
      [[ $EUID -eq 0 ]] || fail "$E_PERMISSION" "uninstall must run as root (sudo 5dive uninstall)"
      local installer
      if command -v curl >/dev/null 2>&1; then
        installer=$(mktemp)
        curl -fsSL "https://raw.githubusercontent.com/5dive-com/5dive-cli/main/install.sh" -o "$installer" \
          || fail "$E_GENERIC" "failed to fetch installer"
        chmod +x "$installer"
        exec bash "$installer" --uninstall "$@"
      else
        fail "$E_NOT_FOUND" "curl is required for 5dive uninstall"
      fi ;;
    -h|--help|help) usage ;;
    *) fail "$E_USAGE" "unknown command: $top" ;;
  esac
}

# EXIT trap picks up AUDIT_CMD set by the dispatcher + real exit code and
# appends one NDJSON line to the audit log. Installed once at script load so
# every code path (including fail/exit) passes through it.
trap on_exit_audit EXIT

main "$@"
