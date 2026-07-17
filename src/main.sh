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
  5dive init                                         # interactive first-run wizard (one agent)
  5dive company [--yes]                              # onboarding wizard: stand up a self-steering company (project + objective + planner)
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
  5dive hire <name> [--role="CTO"]  # sugar: agent create (+ org set)
  5dive market [<keyword>] [--role=<r>] [--rarity=<t>]  # browse/search the agent market; preview: 5dive market show <slug>
  5dive hire <role> --from-market [--as=<name>]  # hire from the open market; see `5dive hire --help`
  5dive agent list
  5dive agent info <name>                            # type, CLI version, selected model, channel + state
  5dive agent types
  5dive agent create <name> --type=<type> [--channels=none|telegram|discord|dashboard[,ch...]]
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
                            # provider: BYO API key for one of ${!BYO_PROVIDER_LABEL[*]}.
                            # hermes/openclaw take any of them; claude (Claude Code)
                            # takes the Anthropic-skin subset (deepseek moonshot
                            # openrouter zai) and requires --auth-profile. Mutually
                            # exclusive with --defer-auth.
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
  5dive agent rm <name>                              # aliases: 5dive agent fire <name>  /  5dive fire <name>
  5dive agent config <name> set channels=<none|telegram|discord|dashboard[,ch...]>
                                                     # comma-separable; dashboard (claude-only, no token)
                                                     # enables web-dashboard chat — the one-tap Enable chat
                                                     # path. New claude creates include it by default.
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
                                                     # telegram.token=- / discord.token=- read the token from
                                                     # stdin (argv hygiene; one =- key per invocation). NOTE:
                                                     # passing =- without piping anything blocks on stdin until
                                                     # the caller's timeout — always send the token on stdin.
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
                                                     # telegram-getme/-discover also take --token=- (token on
                                                     # stdin, never argv); =- without piped stdin blocks until
                                                     # the caller's timeout.
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
  5dive agent install <type> [--upgrade]             # install the CLI for a type if missing (--upgrade forces a reinstall)
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
  5dive task add <title...> [--priority=low|medium|high|urgent] [--assignee=<agent>] [--parent=<id>] [--project=<key>]
  5dive task ls [--mine] [--status=<s>] [--all] [--project=<key>]   # open work, priority-ordered
  5dive task show|start|done|cancel|rm <id|PREFIX-N>
  5dive task assign <id|PREFIX-N> <agent>
  5dive task block <id|PREFIX-N> --by=<id|PREFIX-N>
  # full surface: 5dive task --help

Projects (ident namespaces for the queue; default 'dive' = DIVE-N):
  5dive project add <key> --prefix=FROG [--name=] [--goal=] [--folder=] [--lead-agent=<agent>]
  5dive project ls | show <key>
  # tasks then number per project: FROG-1, FROG-2 …

  5dive loop spawn --role=<r> --agent=<a> --prompt="…" [--ceiling=<tok>] [--wait[=<sec>]]  # LOOP-7 orchestration (JSON in/out)
  5dive goal add "<outcome>" [--dry-run] [--max-tasks=N] [--yes]   # outcome -> validated, guardrailed task graph (DIVE-984)
  5dive objective add "<name>" --metric-cmd="<cmd>" --target=<n> [--direction=up|down] [--unit=%] [--public]  # standing goal bound to a read-only metric (OSS-19)
  5dive objective ls | show <name> | tick [<name>] | pause <name> | resume <name> [--force] | rm <name>  # resume preflights the planner role (OSS-33)
  5dive objective replan <name> [--max-new-per-cycle=N] [--no-progress-limit=N] [--dry-run] [--yes] [--force] [--from-gate=<id>]  # re-plan cycle: preflight -> metric -> guardrailed diff -> gate -> apply; explicit stops (OSS-27/OSS-33)

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

Supervisor (observe-only fleet health — detect + classify, ZERO auto-actions):
  5dive supervisor                                   # per-agent board: state, classification, cause, activity
  5dive supervisor --watch[=secs]                    # live repaint (default 5s; q quits)
  5dive supervisor --tick                            # cron-callable observe pass (root): appends audit rows
                                                     # to supervisor_events; no-ops unless
                                                     # /var/lib/5dive/supervisor.enabled exists
  # full surface: 5dive supervisor --help

Usage (per-agent / per-task token burn — subscription tokens, no dollars):
  5dive usage [--7d]                                 # board: top agents + top tasks by tokens (24h default)
  5dive usage <agent> [--7d]                         # one agent: per-model + per-task breakdown
  5dive cost [--7d]                                  # budget-focused: per-agent 24h burn vs soft/ceiling + state
  5dive activity <agent> [--7d] [--task=DIVE-N]      # what the agent actually did: files touched, commands run, cost
  5dive usage budget set <agent> --daily=<tok> [--ceiling=<tok>] [--hard-stop]  # soft warn + optional hard-stop ceiling
  5dive usage budget ls | clear <agent>              # hard-stop is OFF by default (warn-only); check runs on the heartbeat

Memory (queryable team memory — read-path, DIVE-726):
  5dive memory search "<query>" [--limit=N] [--max-tokens=T]  # BM25-ranked snippets from the agent's memory stores + wiki, with provenance

Zero-human proof (publish your own badge — OSS-17):
  5dive proof publish [--dry-run] [--repo=<url>] [--branch=<b>]  # push badge/datapoint/history, computed verbatim from digest
  5dive proof on --repo=<url> [--branch=status] [--at=<0-23>]    # save config + install daily root cron
  5dive proof off | status [--json]                             # remove cron (config kept) | report + staleness
  # methodology + self-publish guide: docs/zero-human.md

Delegated push (one gated bot identity — DIVE-1376):
  5dive push <id|DIVE-N> [--branch=<b>] [--dry-run]  # push ONLY the task's branch, ONLY after its gate clears; author=lodar enforced
  # Branch comes from --branch or a 'Branch: <name>' line in the task body. Credential is a control-plane GitHub App, never a human token.

Health:
  5dive doctor [--fix] [--dry-run] [--category=deps|types|auth|creds|registry|shelld|channels|host|memory]
    Walks deps (tmux/jq/bun/python3/nvm/node/npm), type bins, live auth
    probes, stale shadow-credential heal (creds), registry integrity, channel
    health (allowlist + dead inbound telegram poller), host safety (needrestart
    auto-restart cascade), shelld reachability, and memory hygiene. --fix
    (alias: --repair) attempts reversible self-heals: apt installs, type
    installer recipes, bun, shelld restart, registry reseed, rename a stale
    ~/.claude/.credentials.json that shadows an env-token, restart an agent
    whose telegram poller died (silently drops inbound DMs), and force
    needrestart to list-only so a library upgrade can't bounce the whole fleet.
    A bare `doctor` (no --fix) is a preview — every fixable check tells you so;
    --dry-run previews even alongside --fix. Output envelope always
    {ok:true,data:{...}}; branch on data.summary.errors in CI.

Types: ${!TYPE_BIN[*]}

Exit codes (also surfaced as error.code in --json mode):
  0 ok       2 usage       3 validation   4 not_found    5 conflict
  6 auth_required  7 not_installed  8 not_running  9 pairing
  10 permission  11 timeout         1 generic

Full docs: https://5dive.ai/docs/5dive-cli
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
    _audit_append)
      # DIVE-1268: hidden, privileged, APPEND-ONLY audit primitive. Reachable
      # ONLY via NOPASSWD sudo — the admin whole-CLI grant, or the scoped
      # write_standard_sudoers line for standard agents. It lets a non-root
      # agent-* caller land its mutating action in the 640 root:claude
      # tamper-evident log without loosening perms to a group-writable 660
      # (which would let any group-claude agent rewrite/truncate past entries).
      # Reads ONE NDJSON line from stdin, re-stamps `user` from SUDO_USER so the
      # payload can't spoof the actor, and appends it — nothing else. Never execs
      # caller input (upholds the write_admin_sudoers invariant), never advertised,
      # and is not itself audited (AUDIT_CMD stays unset, so no recursion).
      [[ $EUID -eq 0 ]] || fail "$E_PERMISSION" "_audit_append is a privileged internal primitive"
      audit_init 2>/dev/null || true
      local _al
      IFS= read -r _al || true
      [[ -n "$_al" ]] || exit 0
      printf '%s\n' "$_al" \
        | jq -c --arg u "${SUDO_USER:-unknown}" \
            'if type=="object" then .user=$u else empty end' \
        >> "$AUDIT_LOG" 2>/dev/null || true
      exit 0
      ;;
    _push_mint_token)
      # DIVE-1376: hidden, privileged token-mint primitive. Reachable ONLY via
      # NOPASSWD sudo. Reads the root-600 GitHub App credential, signs a JWT and
      # exchanges it for a short-lived (~1h) installation token, printing ONLY
      # the token to stdout. The agent process never reads the private key. Not
      # audited itself (the parent `push` verb is) and never advertised.
      cmd_push_mint_token "$@"
      exit $? ;;
    market)
      # DIVE-1020: front door to the agent market — browse/search the
      # character-pack registry + preview a persona before hiring. Read-only
      # (curls the public index), so no lock, no root, no audit — same posture
      # as `agent marketplace`, which it supersedes as the top-level surface.
      cmd_market "$@" ;;
    hire)
      # DIVE-603: ergonomic alias for `agent create` (+ `org set`). Mutating —
      # take the registry lock like create; cmd_hire's inner create call is a
      # re-entrant no-op re-lock.
      # DIVE-1013: `hire <role> --from-market --dry-run` is a read-only preview
      # (resolve + DIVE-995 disclosure, creates nothing) — run it OUTSIDE the
      # lock so it needs no root, exactly like `agent inspect`.
      local _hire_market=0 _hire_dry=0 _ha
      for _ha in "$@"; do
        case "$_ha" in --from-market|--market) _hire_market=1 ;; --dry-run) _hire_dry=1 ;; esac
      done
      if (( _hire_market && _hire_dry )); then
        cmd_hire "$@"
      else
        AUDIT_CMD="hire"; AUDIT_ARGS=("$@")
        with_registry_lock cmd_hire "$@"
      fi ;;
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
        # DIVE-1065: hidden privileged delivery primitive. Only reachable via the
        # scoped-sudoers grant a standard agent gets (write_standard_sudoers);
        # `cmd_send` re-execs into it for non-root agent callers. Not advertised.
        _deliver) cmd_deliver "$@" ;;
        # DIVE-1074: hidden privileged READ primitive (bounded reply-window read),
        # the sibling of _deliver. `cmd_ask` re-execs into it for a standard-tier
        # non-root caller to read back the reply. Scoped-sudoers only, not advertised.
        _capture) cmd_capture "$@" ;;
        # DIVE-1088: hidden privileged service-lifecycle primitive (start|stop|restart
        # of a 5dive-owned unit only). Replaces the raw `systemctl 5dive-agent@*` /
        # `5dive-*.service` sudoers lines that sudo-rs (Ubuntu 26.04) rejected. Reached
        # via the admin whole-CLI grant; enforces its 5dive-only scope in code.
        _svc)    cmd_svc "$@" ;;
        stats)   cmd_stats "$@" ;;
        create)
          AUDIT_CMD="agent create"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_create "$@" ;;
        clone)
          AUDIT_CMD="agent clone"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_clone "$@" ;;
        export)
          # DIVE-39: write a portable pack (read-only on the source agent).
          AUDIT_CMD="agent export"; AUDIT_ARGS=("$@")
          cmd_export "$@" ;;
        import)
          AUDIT_CMD="agent import"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_import "$@" ;;
        inspect)
          # DIVE-995: read-only pack disclosure ("this pack runs X") — no lock,
          # no root; the safety precondition before importing a third-party pack.
          AUDIT_CMD="agent inspect"; AUDIT_ARGS=("$@")
          cmd_inspect "$@" ;;
        marketplace)
          # DIVE-473/509: browse the character-pack git registry (read-only).
          AUDIT_CMD="agent marketplace"; AUDIT_ARGS=("$@")
          cmd_marketplace "$@" ;;
        start)
          AUDIT_CMD="agent start"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_start "$@" ;;
        stop)
          AUDIT_CMD="agent stop"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_stop "$@" ;;
        restart)
          AUDIT_CMD="agent restart"; AUDIT_ARGS=("$@")
          with_registry_lock cmd_restart "$@" ;;
        rm|fire)
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
        team-group)
          # DIVE-453: CoS-native team group — same machinery as team-bot but rides
          # the connected Chief-of-Staff bot (token resolved server-side from
          # cos.env), so no separate team-bot token is ever pasted/sent.
          AUDIT_CMD="agent team-group"; AUDIT_ARGS=("$@")
          cmd_agent_team_group "$@" ;;
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
    fire)
      # `5dive fire <name>` — top-level synonym for `agent rm` (fire an agent).
      AUDIT_CMD="agent rm"; AUDIT_ARGS=("$@")
      with_registry_lock cmd_rm "$@" ;;
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
      # Only audit when a mutating run is requested (--fix/--repair); read-only
      # runs (and --dry-run previews) would spam the log.
      for a in "$@"; do
        if [[ "$a" == "--repair" || "$a" == "--fix" ]]; then
          AUDIT_CMD="doctor"; AUDIT_ARGS=("$@")
          break
        fi
      done
      # --dry-run cancels the mutation, so don't audit it as one.
      for a in "$@"; do [[ "$a" == "--dry-run" ]] && AUDIT_CMD=""; done
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
    gate-proof)
      # DIVE-519: mint a human-origin proof token for an approval/secret gate (or
      # toggle enforcement). Root-only (reads the 0400 key); audits its own mint.
      cmd_gate_proof "$@" ;;
    secret)
      # DIVE-930/932 secure credential drop: box-side secret-write primitive.
      # Root-only (writes root-owned /etc/5dive/connectors). The value arrives on
      # STDIN, so auditing argv here never captures the secret.
      AUDIT_CMD="secret"; AUDIT_ARGS=("$@")
      cmd_secret "$@" ;;
    org)
      # Agent org chart (sqlite, same store as tasks). Read/write, no audit/lock.
      cmd_org "$@" ;;
    project|projects)
      # Project namespaces for the task queue (DIVE-484). Same group-writable
      # store as tasks; read/write, no root/lock.
      cmd_project "$@" ;;
    loop)
      # LOOP-7: agent-native multi-agent orchestration over the task queue +
      # loop_runs table. JSON in/out; same group-writable store, no root/lock.
      cmd_loop "$@" ;;
    goal)
      # DIVE-984 (OSS-2): outcome -> validated, guardrailed task graph. A planner
      # agent (via loop spawn) decomposes an outcome into tasks + deps under a
      # project; goal add validates + gates before materializing. Same group-
      # writable store, no root/lock.
      cmd_goal "$@" ;;
    objective|objectives)
      # OSS-19 (OSS-26 phase A1): outcome-loop objectives — a standing goal bound
      # to a read-only metric command. add/ls/show/pause/resume/rm/tick. Same
      # group-writable store as tasks; read/write, no root/lock. OSS-27 adds the
      # re-plan cycle (`objective replan`): the planner reads the metric + its own
      # originated work and emits a guardrailed diff (create/reprioritize/cancel)
      # through the goal materialize path — origination rides ONE count-checkpoint
      # gate, T2 creates gate hard, and it can only touch its own originated tasks.
      cmd_objective "$@" ;;
    crew)
      # DIVE-787 (0.5.0 flagship): 5dive as the always-on runtime for CrewAI
      # crews. install/secret/run/show/list/uninstall. Crew runs in its own venv
      # with BYO LLM key (owner-600 secret), durable memory on the box disk
      # (CREWAI_STORAGE_DIR), and a co-signed receipt per run → ZeroHuman feed.
      cmd_crew "$@" ;;
    heartbeat)
      # Wake-on-work scheduler. on/off mutate the registry (lock taken inside
      # cmd_heartbeat); tick is the root cron driver; ls is read-only. No audit
      # — tick fires every few minutes and would flood the log; the wakes it
      # triggers are visible via each agent's own transcript.
      cmd_heartbeat "$@" ;;
    supervisor)
      # DIVE-724 P1: observe-only fleet supervisor. Board/--watch are read-only;
      # --tick appends rows to the supervisor_events table (tasks.db) and takes
      # ZERO recovery actions. No audit-log wrapper — like heartbeat tick it's
      # cron-frequency and would flood the log; its own events table IS the
      # audit trail (root + registry lock not needed: sqlite serializes writes).
      cmd_supervisor "$@" ;;
    usage)
      # Per-agent / per-task token visibility for subscription agents. Read-only
      # (scans sibling transcripts + the task DB); the `budget` subcommand writes
      # a small soft-cap store. No registry mutation/lock; budget writes take root
      # inside cmd_usage. No audit — pure reporting + a visibility-only cap.
      cmd_usage "$@" ;;
    cost)
      # DIVE-1019: budget-focused burn view (per-agent 24h tokens vs soft/ceiling)
      # + the enforcement subcommands. Same read-only/root posture as `usage`;
      # `cost budget ...` proxies to the same store writes (root inside).
      cmd_cost "$@" ;;
    activity)
      # DIVE-1022: "what your agent actually did" — per-run/per-task trail of
      # files touched + commands run + cost, from the session transcripts. Same
      # read-only posture as `usage` (root to read sibling homes; no lock/audit).
      cmd_activity "$@" ;;
    digest)
      # Deterministic per-fleet standup digest (DIVE-544 Tier 1): task queue +
      # usage + heartbeat health, zero agent tokens. Read-only reporting; no
      # registry mutation/lock, no audit (same posture as usage).
      cmd_digest "$@" ;;
    push)
      # DIVE-1376 (Bobby gripe #1): delegated push. Pushes ONLY the task's
      # branch, ONLY after the task gate clears, with a fail-closed author=lodar
      # scan, using a short-lived GitHub App installation token minted by the
      # root-only _push_mint_token helper (the agent never holds the credential).
      # Mutating + credential-bearing → audited (the token never lands in argv).
      AUDIT_CMD="push"; AUDIT_ARGS=("$@")
      cmd_push "$@" ;;
    proof)
      # OSS-17: publish this box's zero-human proof (badge.json/zero-human.json/
      # history.jsonl) to a git status branch, computed verbatim from `digest`.
      # publish/status are read-mostly; on/off manage a root cron + pref, tick is
      # the root cron driver. No registry mutation/lock, no audit (like digest).
      cmd_proof "$@" ;;
    memory)
      # DIVE-726 Phase 1a: queryable team memory read-path. Read-only (scans
      # markdown memory stores + shared wiki); no registry mutation/lock/audit,
      # same posture as usage/digest.
      cmd_memory "$@" ;;
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
    company)
      # OSS-34: onboarding-wizard sugar for a self-steering company. Thin macro
      # over project + objective (+ goal) — shells back into those commands; no
      # new state or engine. Same group-writable store as tasks; no root/lock
      # (the sub-commands it calls own their own writes).
      cmd_company "$@" ;;
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
