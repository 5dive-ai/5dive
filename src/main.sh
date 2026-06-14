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
  5dive self-update                                  # update the CLI + plugins, then restart agents
                                                     # (alias: 5dive update). On-demand upgrade for
                                                     # self-hosted boxes; managed boxes update nightly.
  5dive update --check                               # read-only: is the CLI behind/stale? (no root)
  5dive uninstall [--purge] [--yes]                  # remove 5dive (--purge also wipes state + user)

Live view:
  5dive watch [--interval=N]                         # htop-style live view of every agent;
                                                     # ↑↓ select, ↵ attach, r refresh, q quit.

Compose (declarative agents via 5dive.yaml):
  5dive up   [-f file]                               # bring up agents declared in spec (idempotent)
  5dive down [-f file]                               # tear down declared agents
  5dive ps   [-f file]                               # show declared agents' state
  5dive export [-o file]                             # dump the live fleet to a v2 5dive.yaml
  5dive team import <slug|path> [--auth-profile=]    # provision a whole company template in one call
  5dive team ls                                      # list bundled team templates
  # Default file: 5dive.yaml or 5dive.yml in cwd.
  # Schema (v1) — see 'agents' map keys: type, channels, telegram_token,
  # discord_token, workdir, skills, no_skills, defer_auth, isolation,
  # auth_profile, provider, api_key. Strings expand "\${ENV_VAR}" from the
  # process env (missing vars fail loudly).

Agents:
  5dive agent list
  5dive agent info <name>                            # type, CLI version, selected model, channel + state
  5dive agent types
  5dive agent create <name> --type=<type> [--channels=none|telegram|discord]
                            [--telegram-token=<bot-token>] [--discord-token=<token>]
                            [--workdir=<path>] [--auth-profile=<name>]
                            [--provider=<id> --api-key=<key|->]
                            [--with-skills=<spec>[,<spec>...]] [--no-skills]
                            [--no-team-bot] [--defer-auth]
                            # When the box has a shared team bot configured
                            # (team-bot shared persists it), new no-bot agents
                            # auto-attach: own forum topic, send-only on the
                            # shared token. --no-team-bot opts the agent out.
                            # spec: <id> (defaults to the 5dive skills repo) or <owner/repo>:<id>
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
  5dive agent config <name> set model=<id>           # runtime model (claude/codex/grok/antigravity)
  5dive agent config <name> set effort=<low|medium|high|xhigh|max>
                                                     # claude only — reasoning effort (effortLevel);
                                                     # xhigh/max are Opus-tier (Sonnet caps at high)
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
  5dive agent telegram-discover {--token=<bot-token>|--agent=<name>} [--poll-secs=N]
                                                     # long-polls Telegram getUpdates (timeout N, max 90s).
                                                     # --agent reads the token from the agent's connector env
                                                     # file (so the dashboard can discover without handling the
                                                     # token client-side). On first inbound message returns
                                                     # {found:true, userId, chatId, username, firstName};
                                                     # otherwise {found:false} — callers re-poll until found.
  5dive agent telegram-getme --token=<bot-token>     # fast getMe lookup; returns {botId, username, firstName}.
  5dive agent telegram-info <name> [--refresh]       # name-based getMe; reads token from /etc/5dive/connectors,
                                                     # caches botUsername in the registry. Used by the dashboard
                                                     # to backfill @handles for agents created before the
                                                     # botUsername-on-create change. --refresh forces re-fetch.
  5dive agent telegram-access get <name>             # read access.json: who can DM the bot, group settings.
  5dive agent telegram-access set <name>             # write access.json from {dmPolicy,allowFrom,groups} JSON
                                                     # piped on stdin. Plugin re-reads per-message — no restart.
  5dive agent telegram-pending-ignore <name> <code>  # drop a pending pairing without approving (dashboard inbox).
  5dive agent telegram-resolve-handle <name> <@handle>
                                                     # getChat for @handle via the agent's bot token; returns
                                                     # {id,isBot,displayName} so the dashboard can add bots by
                                                     # handle instead of numeric id.
  5dive agent <name> tui                             # attach your terminal to the agent's tmux session
  5dive agent logs <name> [--follow] [--lines=N] [--tmux]
  5dive agent send <name> <text...> [--from=<sender>] [--raw]
                                    [--reply-to-chat=<id> [--reply-to-msg=<id>]]
                                                     # inject a message (tmux send-keys + Enter).
                                                     # When called from another agent, auto-wraps as
                                                     # [5dive-msg from=<caller> id=<id>] so the
                                                     # receiver sees who's pinging it. --raw skips wrapping.
                                                     # --reply-to-chat adds a hint telling the receiver
                                                     # to reply directly in that Telegram/Discord chat
                                                     # via its own bot (see SKILL.md).
  5dive agent ask <name> <text...> [--from=<sender>] [--timeout=120] [--idle-secs=5] [--poll-secs=2]
                                   [--reply-to-chat=<id> [--reply-to-msg=<id>]]
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
  5dive account usage                                  # per-account 5h/7d limit usage (dashboard dots + /usage)
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

Tasks (shared queue, sqlite — any agent, no sudo):
  5dive task add <title...> [--priority=low|medium|high|urgent] [--assignee=<agent>] [--parent=<id>]
  5dive task ls [--mine] [--status=<s>] [--all]      # open work, priority-ordered
  5dive task show|start|done|cancel|rm <id|DIVE-N>
  5dive task assign <id|DIVE-N> <agent>
  5dive task block <id|DIVE-N> --by=<id|DIVE-N>
  # full surface: 5dive task --help

Org chart (who reports to whom):
  5dive org set <agent> --manager=<agent> [--role=<text>] [--title=<text>]
  5dive org tree | show <agent> | ls | rm <agent>
  # full surface: 5dive org --help

Heartbeat (wake an agent only when it has queued tasks, one per tick):
  5dive heartbeat on  <name> [--every=<dur>] [--no-fresh]   # enrol (default 30m, /clear before each task)
  5dive heartbeat off <name>
  5dive heartbeat ls                                        # enrolled agents + next-wake + queued count
  5dive heartbeat tick                                      # cron driver (root); wakes due agents that have work
  # full surface: 5dive heartbeat --help

Health:
  5dive doctor [--repair] [--category=deps|types|auth|creds|registry|shelld|channels]
    Walks deps (tmux/jq/bun/python3/nvm/node/npm), type bins, live auth
    probes, stale shadow-credential heal (creds), registry integrity, and
    shelld reachability. --repair attempts reversible fixes (apt installs,
    type installer recipes, bun, shelld restart, registry reseed, rename a
    stale ~/.claude/.credentials.json that shadows an env-token). Output
    envelope always {ok:true,data:{...}};
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
        info)    cmd_info "$@" ;;
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
        telegram-pending-ignore)
          AUDIT_CMD="agent telegram-pending-ignore"; AUDIT_ARGS=("$@")
          cmd_telegram_pending_ignore "$@" ;;
        telegram-resolve-handle)
          # Read-only getChat lookup against Telegram. Bot token stays
          # server-side; skip audit so handle probes don't spam the log.
          cmd_telegram_resolve_handle "$@" ;;
        topic)
          # DIVE-159 team-bot: get/set the agent's forum-topic mapping in the
          # registry. get is read-only; set takes the registry lock internally.
          [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive agent topic get|set <name> [--thread-id=N --chat-id=N]"
          local topiccmd="$1"; shift
          case "$topiccmd" in
            get) cmd_agent_topic_get "$@" ;;  # read-only, no audit
            set)
              AUDIT_CMD="agent topic set"; AUDIT_ARGS=("$@")
              with_registry_lock cmd_agent_topic_set "$@" ;;
            *) fail "$E_USAGE" "unknown topic command: $topiccmd" ;;
          esac ;;
        team-bot)
          # DIVE-159: provision/inspect the customer's team group (personal-bot
          # model — a forum topic per agent). status is read-only; provision
          # writes access.json + registry teamTopic (registry lock taken inside).
          AUDIT_CMD="agent team-bot"; AUDIT_ARGS=("$@")
          cmd_agent_team_bot "$@" ;;
        cos)
          # DIVE-320: Chief of Staff managed-bot provisioning. verify/mint-link
          # are read-only probes; claim/rotate fetch+configure a child token via
          # the customer's CoS (no registry mutation here — the caller wires the
          # returned token into `agent create`).
          AUDIT_CMD="agent cos"; AUDIT_ARGS=("$@")
          cmd_agent_cos "$@" ;;
        install)
          AUDIT_CMD="agent install"; AUDIT_ARGS=("$@")
          cmd_install "$@" ;;   # no registry mutation; auditable install recipe
        set-account)
          AUDIT_CMD="agent set-account"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_agent_set_account "$@" ;;
        rotation)
          [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive agent rotation get|set|rotate|cooldown|clear-cooldown <agent> [...]"
          local rotcmd="$1"; shift
          case "$rotcmd" in
            get) cmd_agent_rotation_get "$@" ;;  # read-only, no lock/audit
            set)
              AUDIT_CMD="agent rotation set"; AUDIT_ARGS=("$@")
              with_registry_lock cmd_agent_rotation_set "$@" ;;
            rotate)
              AUDIT_CMD="agent rotation rotate"; AUDIT_ARGS=("$@")
              with_registry_lock cmd_agent_rotation_rotate "$@" ;;
            cooldown)
              AUDIT_CMD="agent rotation cooldown"; AUDIT_ARGS=("$@")
              with_registry_lock cmd_agent_rotation_cooldown "$@" ;;
            clear-cooldown)
              AUDIT_CMD="agent rotation clear-cooldown"; AUDIT_ARGS=("$@")
              with_registry_lock cmd_agent_rotation_clear_cooldown "$@" ;;
            *) fail "$E_USAGE" "unknown rotation command: $rotcmd (get|set|rotate|cooldown|clear-cooldown)" ;;
          esac ;;
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
      [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive account list|show|usage|add|rename|remove|login|set-active-provider"
      local acctcmd="$1"; shift
      case "$acctcmd" in
        list)   cmd_account_list "$@" ;;
        show)   cmd_account_show "$@" ;;
        usage)  cmd_account_usage "$@" ;;
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
    task)
      # Shared task queue (sqlite). Group-writable store, so no root/lock and
      # no audit — these are high-frequency, low-risk ops any agent runs. SQLite
      # serializes its own writes (busy_timeout) so with_registry_lock isn't needed.
      cmd_task "$@" ;;
    org)
      # Agent org chart (sqlite, same store as tasks). Read/write, no audit/lock.
      cmd_org "$@" ;;
    heartbeat)
      # Wake-on-work scheduler. on/off mutate the registry (lock taken inside
      # cmd_heartbeat); tick is the root cron driver; ls is read-only. No audit
      # — tick fires every few minutes and would flood the log; the wakes it
      # triggers are visible via each agent's own transcript.
      cmd_heartbeat "$@" ;;
    fleet)
      # DIVE-204 v0.2: multi-box control plane. Phase 1 = the fleet registry
      # (add/ls/show/rm of peer boxes — host/user/port + key PATH, never key
      # material). add/rm take root + write fleet.json; ls/show are read-only.
      # Fan-out read/command land in later phases.
      cmd_fleet "$@" ;;
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
    export)
      # Read-only — dump the live fleet to a v2 5dive.yaml.
      cmd_compose_export "$@" ;;
    team)
      # Provision a whole company-structure template (wraps `up`); the per-agent
      # create calls take the lock + audit themselves.
      AUDIT_CMD="team"; AUDIT_ARGS=("$@")
      cmd_team "$@" ;;
    uninstall)
      # Thin wrapper: fetch install.sh and exec --uninstall. Keeps a single
      # source of truth for what gets removed (install.sh) and dodges the
      # "old bundles ship stale uninstall logic" problem.
      [[ $EUID -eq 0 ]] || fail "$E_PERMISSION" "uninstall must run as root (sudo 5dive uninstall)"
      local installer
      if command -v curl >/dev/null 2>&1; then
        installer=$(mktemp)
        curl -fsSL "https://raw.githubusercontent.com/$(gh_org)/5dive/main/install.sh" -o "$installer" \
          || fail "$E_GENERIC" "failed to fetch installer"
        chmod +x "$installer"
        exec bash "$installer" --uninstall "$@"
      else
        fail "$E_NOT_FOUND" "curl is required for 5dive uninstall"
      fi ;;
    self-update|self_update|update)
      # `--check` is a read-only version probe (no root, no mutation): compares
      # the installed CLI to the published release so the dashboard maintenance
      # tile can show a "your CLI is behind — update now" prompt. Everything
      # else in this branch mutates the box, so it stays root-gated.
      if [[ "${1:-}" == "--check" ]]; then
        shift
        cmd_update_check "$@"
      else
        # On-demand "update everything + reload" for OSS self-hosters with no
        # scheduler: runs install.sh --upgrade (CLI + plugins) then restarts
        # running agents so the changes load. Mirrors the managed nightly.
        [[ $EUID -eq 0 ]] || fail "$E_PERMISSION" "self-update must run as root (sudo 5dive self-update)"
        AUDIT_CMD="self-update"; AUDIT_ARGS=("$@")
        cmd_self_update "$@"
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
