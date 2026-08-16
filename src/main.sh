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
  5dive hire <role> --from-market [--as=<name>]  # hire from the open market; see '5dive hire --help'
  5dive agent list
  5dive agent info <name>                            # type, CLI version, model, channel, state + OUTPUT (DIVE-3274:
                                                     # whether the seat is transacting, not only whether it is up)
  5dive agent types
  5dive agent create <name> --type=<type> [--channels=none|telegram|discord|dashboard|buzz[,ch...]]
                            [--telegram-token=<bot-token>] [--discord-token=<token>]
                            [--workdir=<path>] [--auth-profile=<name>]
                            [--provider=<id> --api-key=<key|->]
                            [--with-skills=<spec>[,<spec>...]] [--no-skills]
                            [--no-team-bot] [--defer-auth] [--can-push]
                            # --can-push grants a STANDARD (builder) agent the
                            # delegated-push capability: a scoped NOPASSWD sudoers
                            # grant for '5dive push' (exact-path _push_do). Off by
                            # default; admin agents already have it, sandboxed
                            # can't. See docs/delegated-push.md.
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
  5dive agent rm <name> [--purge-home]               # aliases: 5dive agent fire <name>  /  5dive fire <name>
                                                     # home is quarantined to /home/.5dive-reaped/ (root 0700);
                                                     # --purge-home deletes it instead (irreversible)
  5dive agent config <name> set channels=<none|telegram|discord|dashboard|buzz[,ch...]>
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
  5dive agent send <name> <text...>|--message=<text>|--message-file=<path>
                                    [--from=<sender>] [--raw] [--wake]
                                    [--reply-to-chat=<id> [--reply-to-msg=<id>]]
                                                     # --message-file reads the body VERBATIM from a file (DIVE-2627).
                                                     # Use it for ANY message that quotes CLI verbs: inside a double-quoted
                                                     # --message=, backtick-quoted verbs RUN as command substitution (as you),
                                                     # the words are deleted, and the send still prints OK.
                                                     # inject a message (tmux send-keys + Enter).
                                                     # When called from another agent, auto-wraps as
                                                     # [5dive-msg from=<caller> id=<id>] so the
                                                     # receiver sees who's pinging it. --raw skips wrapping.
                                                     # --from is a CLAIM. When it does not match the
                                                     # measured caller the envelope also carries
                                                     # via=<real-caller>; an unverifiable
                                                     # claim reads via=unknown:no-caller.
                                                     # --reply-to-chat adds a hint telling the receiver
                                                     # to reply directly in that Telegram/Discord chat
                                                     # via its own bot (see SKILL.md).
                                                     # --wake: if the target is NOT running, start its unit
                                                     # and deliver once its session is up, instead of
                                                     # failing with exit 8. Use it for SCHEDULED work
                                                     # (cron / systemd timers), where a send into a
                                                     # sleeping agent is dropped with no queue and no
                                                     # retry. Needs root; refuses if the agent was
                                                     # deliberately stopped (desiredState=stopped).
                                                     # WORST CASE 105s: the wake and the wait for the
                                                     # agent's input prompt share ONE budget, so size a
                                                     # timer's TimeoutStartSec above that (override with
                                                     # AGENT_WAKE_BUDGET_SECS). On this path a prompt that
                                                     # never renders is FATAL (exit 8) rather than
                                                     # best-effort: a scheduler with nobody reading its
                                                     # output needs a truthful exit code more than a
                                                     # keystroke that may have been dropped. --json then
                                                     # reports ready=proven, or ready=unprovable for a
                                                     # runtime whose prompt cannot be detected at all.
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
                              [--base-url=<url>] [--model=<slug>]
                                                       # --provider=<id> required for hermes/openclaw;
                                                       # id is one of: ${!BYO_PROVIDER_LABEL[*]}
                                                       # --base-url (claude only) restates a custom
                                                       # endpoint; without it a profile pinned off the
                                                       # catalog is refused, not reverted (DIVE-2809)
  5dive agent auth start <type> [--auth-profile=<name>]      # non-TTY device-code: returns session id
  5dive agent auth poll <session_id>                         # {state, url, error}
  5dive agent auth submit <session_id> --code=<callback>     # paste the claude callback code
  5dive agent auth cancel <session_id>
  5dive agent auth reap [--ttl=<secs>] [--max-age=<secs>] [--dry-run]
                                                       # kill abandoned login processes + drop old session dirs
  # NB each session's login TUI lives on a PRIVATE tmux socket, so a plain
  # 'tmux ls' shows nothing. To watch one live:
  #   tmux -S /var/lib/5dive/auth-sessions/<session_id>/tmux.sock attach -t auth-<session_id>

Tasks (shared queue, sqlite — any agent, no sudo):
  5dive task add <title...> [--priority=low|medium|high|urgent] [--assignee=<agent>] [--parent=<id>] [--project=<key>]
  5dive task ls [--mine] [--status=<s>] [--all] [--project=<key>]   # open work, priority-ordered
  5dive task show|gate-history|start|done|cancel|rm <id|PREFIX-N>
  5dive task assign <id|PREFIX-N> <agent>
  5dive task block <id|PREFIX-N> --by=<id|PREFIX-N>
  # full surface: 5dive task --help

Projects (ident namespaces for the queue; default 'dive' = DIVE-N):
  5dive project add <key> --prefix=FROG [--name=] [--goal=] [--folder=] [--lead-agent=<agent>]
  5dive project ls | show <key>
  # tasks then number per project: FROG-1, FROG-2 …

  5dive loop spawn --role=<r> --agent=<a> --prompt="…" [--ceiling=<tok>] [--wait[=<sec>]]  # orchestration (JSON in/out)
  5dive goal add "<outcome>" [--dry-run] [--max-tasks=N] [--yes]   # outcome -> validated, guardrailed task graph
  5dive objective add "<name>" --metric-cmd="<cmd>" --target=<n> [--direction=up|down] [--unit=%] [--public]  # standing goal bound to a read-only metric
  5dive objective ls | show <name> | tick [<name>] | pause <name> | resume <name> [--force] | rm <name>  # resume preflights the planner role
  5dive objective replan <name> [--max-new-per-cycle=N] [--no-progress-limit=N] [--dry-run] [--yes] [--force] [--from-gate=<id>]  # re-plan cycle: preflight -> metric -> guardrailed diff -> gate -> apply; explicit stops (/)

Org chart (who reports to whom):
  5dive org set <agent> --manager=<agent> [--role=<text>] [--title=<text>]
  5dive org tree | show <agent> | ls | rm <agent>
  # full surface: 5dive org --help

Human accounts (who may CLEAR a gate — one identity, all transports):
  5dive human add <id> [--name=] [--telegram=<chat id>] [--buzz=<npub>] [--discord=<id>]
  5dive human link <id> --agent=<name>               # that human owns that agent's gates
  5dive human ls | show <id> | owner <agent> | recipient <ident> | rm <id>
  # With NO human accounts, gate delivery is unchanged. full surface: 5dive human --help

Web UI for this host (org chart, queue, gates):
  5dive ui [--port=8735] [--host=127.0.0.1]          # open the three views in a browser. Read-only, no sign-in.
  5dive ui --data | --html                           # the JSON the views render / the page itself
  # full surface: 5dive ui --help

Heartbeat (wake an agent only when it has queued tasks, one per tick):
  5dive heartbeat on  <name> [--every=<dur>] [--fresh]      # enrol (default 30m, fresh off: no /clear between tasks)
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

Trace (causal timeline for one task, goal → ship —):
  5dive trace <id|DIVE-N> [--json] [--no-audit]      # read-only: origin (goal/parent/objective/loop) + lifecycle + gate provenance + verdict

Memory (queryable team memory — read-path,):
  5dive memory search "<query>" [--limit=N] [--max-tokens=T]  # BM25-ranked snippets from the agent's memory stores + wiki, with provenance

Zero-human proof (publish your own badge —):
  5dive proof publish [--dry-run] [--repo=<url>] [--branch=<b>]  # push badge/datapoint/history, computed verbatim from digest
  5dive proof on --repo=<url> [--branch=status] [--at=<0-23>]    # save config + install daily root cron
  5dive proof off | status [--json]                             # remove cron (config kept) | report + staleness
  # methodology + self-publish guide: docs/zero-human.md

Delegated push (bring your own GitHub App —):
  5dive push <id|DIVE-N> [--branch=<b>] [--dry-run]  # push ONLY the task's branch, ONLY after its gate clears; author enforced
  5dive push <id|DIVE-N> --open-pr[=<base>]          # ...and open its pull request on the same root-side rail, as 5dive-bot (DIVE-2605)
  5dive deploy <id|DIVE-N> [--target=<project@ref>] [--env=production|preview] [--dry-run]
                                                     # deploy ONLY the project@ref the task declares, ONLY after its gate clears
  5dive push setup                                   # scaffold + check the GitHub App credential (bring-your-own; root)
  # Branch comes from --branch or a 'Branch: <name>' line in the task body. The credential is YOUR GitHub App
  # (contents:write, installed on your ship repos), held root-side in /etc/5dive/connectors — never a human token.
  # Full setup walkthrough: docs/delegated-push.md

Actor-routed gh:
  5dive gh <gh args...>                    # writes go out as the machine account; admin + reads stay on your credential
  5dive gh --as=bot|caller <gh args...>    # force one identity | --explain prints the decision and runs nothing
  5dive gh whoami                          # resolve BOTH identities, so "who did that write go out as" is measurable
  # An agent gh write authenticates as the HUMAN account, so the audit trail cannot tell agent from human
  #. The PAT stays root-side in /etc/5dive/connectors/github-bot.env — the agent never holds it.

Identity:
  5dive whoami [--json]                    # the CURRENT process: actor, authority, tier + the SOURCE of each; exit 6 if unmeasurable
  5dive whoami --for=<id|DIVE-N> [--json]  # the RECORDED authority chain for one row; EXIT 1 when a link that HAPPENED is unmeasurable
                                           # scope it: --for=task:DIVE-N | gate:DIVE-N | action:DIVE-N
    Who is acting, under whose authority, at what tier — and the SOURCE of each.
    Identity is uid-first: \$EUID (or sudo's \$SUDO_UID at real root) resolved
    against /etc/passwd in pure bash. Never argv/--from, \$USER, \$SUDO_USER or
    \$FIVEDIVE_AUDIT_USER, and never \`id\`/\`getent\` (both PATH-resolved).
    An UNMEASURABLE actor exits 6 (auth_required) — it is never printed as
    \`unknown\` with a success status.

Models:
  5dive models [--json]
    Current Claude model id per short alias (opus / sonnet / fable / haiku).
    Single source of truth for the agent-create pin and the telegram /model
    picker — a model release is a one-line change in src/lib/models.sh.

Health:
  5dive selfcheck [--json] [--only=<probe,...>] [--full] [--strict] [--allow=<probe,...>] [--report=<f>] [--label=<env>] [--list]
    Does each rail ACT? Runs gate delivery, the audit log (root AND non-root),
    the test-harness mutation probe, bundle integrity, the crontab snapshot and
    the scorecard FOR REAL in an isolated state dir and asserts the EFFECT, not
    the string printed. Every probe is pass | fail | NOT-REACHED — NOT-REACHED
    is a first-class third state, never folded into pass, and one with no reason
    exits non-zero. Where doctor asks whether the box is healthy, this asks
    whether our own instruments can still tell. Union the --report= files from
    two environments (tests/meta/selfcheck-union.sh) to prove no probe is
    skipped everywhere.

  5dive bug --what=<text> [--verb=<name>] [--exit=<code>] [--argv=<line>]
            [--no-probes] [--file]
    Preview (default) or file a diagnostic bug report against 5dive-ai/5dive.
    Payload is a fixed ALLOWLIST — version, OS, bash version, install method,
    the verb that failed + its exit code, selfcheck probe name+verdict pairs
    (never the free-text reason/detail fields underneath them), and the two
    fields you supply: --what and --argv. --what is REQUIRED to --file: a TTY
    is prompted for it, and with no TTY an empty report is REFUSED rather than
    opened against a public repo (DIVE-3136). Bare \`5dive bug\` only builds and
    prints the payload; NEVER auto-files. --file re-prints the identical
    payload and then opens it (via \`5dive gh issue create\`, so it lands as
    5dive-bot); a TTY also gets an interactive y/N. Agents take the same --file
    flag a human does — no separate unattended path.

  5dive acp
    Speak ACP (Agent Client Protocol) over stdin/stdout so an ACP client — Buzz
    (block/buzz), Zed — can select 5dive as a coding-agent runtime. NOT
    interactive: the client spawns it. A session ATTACHES to a named fleet agent
    (its memory, tasks, org position and heartbeat intact) rather than opening a
    blank one; the roster travels as ACP availableCommands, so /<name> or
    /attach <name> picks the agent and /agents re-lists them. Runs on bun.

  5dive host unit list [--pattern=<unit-glob>]       # systemd units, --no-pager pinned in code
  5dive host unit show --unit=<unit>                 # a FIXED property set (User, WorkingDirectory,
                                                     # ExecStart, DropInPaths, Result, ...)
  5dive host unit repoint --unit=<u>.service --workdir=<abs-path> [--no-restart]
                                                     # write a fixed one-directive drop-in
                                                     # (<unit>.d/50-5dive-workdir.conf), daemon-reload,
                                                     # restart — one audited operation.
                                                     # REFUSES a unit that runs as root: WorkingDirectory
                                                     # is a code pointer whenever ExecStart carries a
                                                     # relative argument, so repointing a root unit would
                                                     # exec caller-chosen content as root.
  5dive host unit revert --unit=<u>.service [--no-restart]
                                                     # remove exactly that drop-in, reload, restart
  5dive host journal --unit=<unit> [--lines=N] [--since=<N>m|<N>h|<N>d]
                                                     # journalctl --no-pager; --since is structured,
                                                     # free-form time strings are refused
  5dive host cron show|snapshot|diff --user=<user>   # READ-ONLY. \`crontab -l -u\` only; there is no
                                                     # write/edit path (crontab -e is an EDITOR escape).
                                                     # diff compares against the CLI's own snapshot,
                                                     # never a caller-supplied file.
    Host remediation for a privileged seat, delivered as scoped subcommands
    rather than raw systemctl/journalctl/crontab grants (DIVE-3221; DIVE-1088
    excluded those grants because each is a one-line root escape via the pager
    or an editor). Needs root for the mutating and journal/cron verbs — an admin
    agent reaches them through its existing \`/usr/local/bin/5dive *\` grant.

  5dive doctor [--fix] [--dry-run] [--caps] [--category=deps|types|auth|creds|registry|shelld|channels|host|memory|policy|plugins|caps|models]
    Walks deps (tmux/jq/bun/python3/nvm/node/npm), type bins, live auth
    probes, stale shadow-credential heal (creds), registry integrity, channel
    health (allowlist + dead inbound telegram poller), host safety (needrestart
    auto-restart cascade), shelld reachability, and memory hygiene. --fix
    (alias: --repair) attempts reversible self-heals: apt installs, type
    installer recipes, bun, shelld restart, registry reseed, rename a stale
    ~/.claude/.credentials.json that shadows an env-token, restart an agent
    whose telegram poller died (silently drops inbound DMs), and force
    needrestart to list-only so a library upgrade can't bounce the whole fleet.
    --caps (= --category=caps) answers, for THIS seat and without guessing,
    whether it can read GitHub and how: github:read is derived from the seat's
    measured sudo runas AND a live \`sudo -u claude gh auth status\`, since a
    permitted uid switch says nothing about whether that token still works.
    Roughly half the seats on a box have no such path, so a NO always names its
    reason. It rides in data.capabilities, NOT in checks — a capability is not
    a passed check. github:write stays NO: push identity is per-seat and the
    claude-uid borrow is retired for pushes (DIVE-3017).
    A bare 'doctor' (no --fix) is a preview — every fixable check tells you so;
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

# _five_is_passthrough_verb <verb> — 0 when the verb hands its remaining argv to
# ANOTHER program verbatim, so 5dive's own global flags must stop being parsed at
# it (DIVE-3135). Kept as a named list rather than a heuristic: adding a verb here
# is a deliberate statement that its tail belongs to someone else, and getting it
# wrong in the permissive direction would silently disable `--json` for a verb
# that implements it.
_five_is_passthrough_verb() {
  case "${1:-}" in
    gh) return 0 ;;
    *)  return 1 ;;
  esac
}

main() {
  # DIVE-2249: mark that this process entered through the real CLI entrypoint.
  # The tasks-store fence (src/lib/tasks_db.sh) allows writes to the PRODUCTION
  # board only from here — a harness that sources the libraries directly never
  # runs main, so its writes are refused instead of appending real-looking fixture
  # rows to the live board. Keep this the FIRST statement in main: anything above
  # it that touched the store would be fenced against its own entrypoint.
  _TASKS_STORE_ENTRY=cli

  # The argv this process was invoked with, so require_root's hint can name the
  # command the caller actually typed instead of a bare `sudo 5dive `.
  FIVE_ARGV=("$@")

  # Global --json: strip every occurrence before dispatch so each subcommand
  # gets the same arg shape regardless of where the flag was placed.
  #
  # EXCEPT after a PASSTHROUGH verb (DIVE-3135). `5dive gh` documents
  # `<gh args...>` and hands them to another tool, so a flag after it is that
  # tool's, not ours. Stripping `--json` out of `gh pr view 51 --json state` left
  # `state` behind as a stray positional and gh's own parser answered "accepts at
  # most 1 arg(s), received 2" — public issues #526 and #553, and the reason a
  # credential-less seat could not read a PR at all. A passthrough verb therefore
  # ENDS global flag parsing, the same way `--` does. `5dive --json gh ...` still
  # works: the flag is before the verb, which is where a 5dive-level flag belongs.
  local -a rest=()
  local a passthrough=0 seen_verb=0
  for a in "$@"; do
    if (( passthrough )); then rest+=("$a"); continue; fi
    if [[ "$a" == "--json" ]]; then
      JSON_MODE=1
      continue
    fi
    # The first token that is not a global flag IS the verb — test it once, so a
    # later argument that merely spells `gh` (`5dive task add "fix gh routing"`)
    # cannot turn global parsing off midway.
    if (( ! seen_verb )); then
      seen_verb=1
      _five_is_passthrough_verb "$a" && passthrough=1
    fi
    rest+=("$a")
  done
  set -- "${rest[@]+"${rest[@]}"}"

  [[ $# -gt 0 ]] || { usage; mark_reported; exit "$E_USAGE"; }
  local top="$1"; shift
  # DIVE-2323: the one place that sees every dispatch, so fail()'s E_GENERIC
  # hint can name the verb that broke. Set unconditionally, even for a $top
  # the case below rejects — that path fails E_USAGE, which the hint never
  # fires on, so an unvalidated verb string never actually reaches it.
  CURRENT_VERB="$top"
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
    _task_answer)
      # DIVE-3160: hidden, privileged, delegated SIGNED gate clear. Reachable ONLY
      # via NOPASSWD sudo (the scoped render_standard_sudoers line). Reads the
      # `task answer` arguments NUL-separated on STDIN — never argv, so the grant
      # stays an exact command path with no wildcard — re-derives the caller from
      # SUDO_UID and its lead-clear standing FROM THE ROW as root, refuses every
      # human-evidence form, and only then runs cmd_task_answer at EUID 0, where
      # the DIVE-756 closure signs in-process instead of shelling out to a
      # `gate-proof sign` grant a cli-scoped seat does not have.
      #
      # Not audited HERE, for the _gh_do reason: the parent `task answer` verb is
      # audited and reaches this primitive through a PIPE, not `exec`, so the
      # outer EXIT trap still fires and attribution survives (DIVE-2797 is about
      # the exec case, which this deliberately is not). Never advertised.
      cmd_task_answer_delegated
      exit $? ;;
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
    gh)
      # DIVE-2448 (last mile of DIVE-2232): actor-routed `gh`. A WRITE goes out as
      # the machine account so the actor field means something; admin-class and
      # read operations stay on the caller's own credential (the bot is
      # admin=false everywhere, and a read has no actor field to attribute). The
      # decision is printed on every call. Credential-bearing → audited; the
      # token is read root-side in _gh_do and never lands in argv.
      AUDIT_CMD="gh"; AUDIT_ARGS=("$@")
      cmd_gh "$@" ;;
    _merge_do)
      # DIVE-3474 arm 1: hidden, privileged. Reachable ONLY via NOPASSWD sudo (the
      # UNCONDITIONAL render_standard_sudoers line — it confers no authority of its
      # own, exactly like _task_answer). Reads ONE task ident on STDIN and nothing
      # else, re-derives the caller from SUDO_UID and its merge standing from the
      # ROW as root (graded_by = this seat, over the shared graded-awaiting-merge
      # predicate), and merges the pull request the ROW names — never one the
      # caller does. Not audited here; the parent `task merge` verb is, and the
      # primitive writes its own store-audit row naming the grader.
      cmd_task_merge_do
      exit $? ;;
    _gh_do)
      # DIVE-2448: hidden, privileged. Reachable ONLY via NOPASSWD sudo. Reads the
      # gh argv NUL-separated on STDIN (never argv, so the grant stays exact-path
      # / sudo-rs safe), re-derives the routing class authoritatively, reads the
      # machine account's PAT from the root-only connector and execs gh with it as
      # an environment prefix. The agent process never holds the token. Not
      # audited itself (the parent `gh` verb is) and never advertised.
      cmd_gh_do "$@"
      exit $? ;;
    _deploy_do)
      # INST-5: hidden, privileged, ATOMIC delegated deploy — the capability
      # broker's SECOND surface, same template as _push_do. Reachable ONLY via
      # NOPASSWD sudo. Reads <ident> <project> <ref> <env> on STDIN (never argv,
      # so the grant stays exact-path / sudo-rs safe), re-verifies the cleared
      # gate under signature, re-binds the target to the task's own Deploy line,
      # reads VERCEL_TOKEN root-only and fires ONE deployment of the repo the
      # project is ALREADY linked to. The agent process never holds the token.
      # Not audited itself (the parent `deploy` verb is) and never advertised.
      cmd_deploy_do "$@"
      exit $? ;;
    _push_do)
      # DIVE-1376/1460: hidden, privileged, ATOMIC delegated push. Reachable ONLY
      # via NOPASSWD sudo. Reads <ident> <repo-path> <branch> <repo-url> on STDIN
      # (never argv, so the grant stays exact-path / sudo-rs safe), re-verifies the
      # human gate + author scan authoritatively, mints a repo-SCOPED installation
      # token, pushes the one branch, and discards the token — all as root. The
      # agent process never holds a token. Not audited itself (the parent `push`
      # verb is) and never advertised.
      cmd_push_do "$@"
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
      [[ $# -gt 0 ]] || { usage; mark_reported; exit "$E_USAGE"; }
      local sub="$1"; shift
      case "$sub" in
        -h|--help|help) usage ;;
        list)    cmd_list "$@" ;;
        info)    cmd_info "$@" ;;
        types)   cmd_types "$@" ;;
        logs)    cmd_logs "$@" ;;
        # DIVE-2797: the send rail is AUDITED. `task inbox send` had 78 rows in
        # agent-audit.log and `agent send` had zero, so an inter-agent message —
        # including an admin-tier one carrying a forgeable `--from=` — left no
        # artifact naming who sent it. A recipient could re-verify the CLAIM and
        # never the SOURCE, because no source record existed.
        #
        # AUDIT_ARGS is a PLACEHOLDER here, not the payload. The handler rewrites
        # it once it has parsed its flags (see cmd_send / cmd_ask / cmd_deliver),
        # because the dispatcher cannot tell a target from a `--message=` body and
        # the message body must never land in a shared log. If the handler fails
        # before that point the row still carries the verb, the exit code and the
        # derived actor — attribution survives a usage error.
        send)
          AUDIT_CMD="agent send"; AUDIT_ARGS=("to=<unparsed>")
          cmd_send "$@" ;;
        ask)
          AUDIT_CMD="agent ask"; AUDIT_ARGS=("to=<unparsed>")
          cmd_ask "$@" ;;
        # DIVE-1065: hidden privileged delivery primitive. Only reachable via the
        # scoped-sudoers grant a standard agent gets (write_standard_sudoers);
        # `cmd_send` re-execs into it for non-root agent callers. Not advertised.
        # DIVE-2797: audited for the same reason, and it is NOT redundant with the
        # `send` row above. cmd_send reaches this primitive with `exec`, which
        # replaces the process — the outer EXIT trap never fires, so a scoped
        # (standard-tier) a2a send would have been audited by NOBODY if only
        # `send` were wired. That is the DIVE-2788 shape this ticket names as its
        # sibling: a guard covering a narrower population than its name.
        _deliver)
          AUDIT_CMD="agent _deliver"; AUDIT_ARGS=("to=<unparsed>")
          cmd_deliver "$@" ;;
        # DIVE-1074: hidden privileged READ primitive (bounded reply-window read),
        # the sibling of _deliver. `cmd_ask` re-execs into it for a standard-tier
        # non-root caller to read back the reply. Scoped-sudoers only, not advertised.
        _capture) cmd_capture "$@" ;;
        # DIVE-1088: hidden privileged service-lifecycle primitive (start|stop|restart
        # of a 5dive-owned unit only). Replaces the raw `systemctl 5dive-agent@*` /
        # `5dive-*.service` sudoers lines that sudo-rs (Ubuntu 26.04) rejected. Reached
        # via the admin whole-CLI grant; enforces its 5dive-only scope in code.
        _svc)    cmd_svc "$@" ;;
        # DIVE-1813: hidden privileged SELF-restart primitive (deferred restart
        # of the CALLER'S OWN unit, derived from SUDO_USER — no argv target).
        # Reached via the scoped render_standard_sudoers grant so a standard
        # agent's /restart + /model work without a raw systemd-run/sudo grant.
        _self_restart) cmd_self_restart "$@" ;;
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
          [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive agent auth status|login|set|start|poll|submit|cancel|reap"
          local authcmd="$1"; shift
          case "$authcmd" in
            -h|--help|help) usage ;;
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
            reap)
              AUDIT_CMD="agent auth reap"; AUDIT_ARGS=("$@")
              cmd_auth_reap "$@" ;;
            *) fail "$E_USAGE" "unknown auth command: $authcmd (status|login|set|start|poll|submit|cancel|reap)" ;;
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
    whoami)
      # DIVE-2517 (v0.18 "Proof of who"): the one sealed actor derivation, printed
      # with the provenance of every field. Read-only — no state, no lock, and
      # deliberately NO audit row: a verb whose whole job is to report the caller's
      # identity must not need the caller's identity to be writable first.
      cmd_whoami "$@" ;;
    models)
      # DIVE-1883: print the alias -> current model id map (source of truth in
      # src/lib/models.sh). Read-only. The telegram plugin reads
      # `5dive models --json` at boot so its /model picker can't drift again.
      cmd_models "$@" ;;
    host)
      # DIVE-3221: hardened host-remediation verbs, reached through the CLI-root
      # grant an `admin` agent already holds (no new sudoers class, no new tier —
      # lodar answered B on DIVE-3213). Every verb takes structured, validated
      # parameters only: no unit-file content, no shell string, no editor, no
      # caller-supplied path. See the header of src/cmd_host.sh for the finite
      # set of commands each verb can exec as root, and why `repoint` refuses a
      # root-running unit.
      #
      # Audited as a whole: `unit list`/`unit show`/`journal`/`cron show` are
      # reads, but they are reads a privileged seat performs about ANOTHER user's
      # box state, and the row that answers "who repointed this unit" is worth
      # more than the noise it costs.
      AUDIT_CMD="host"; AUDIT_ARGS=("$@")
      cmd_host "$@" ;;
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
    selfcheck)
      # DIVE-2039 (v0.16 "Fails loud"): run each critical rail for real in an
      # ISOLATED state dir and assert the EFFECT, not the report. Every write it
      # makes lands under its own throwaway STATE_DIR/TASKS_DB/AUDIT_LOG, so this
      # never touches the live store, never pings a human, and needs no lock. Not
      # audited: it mutates nothing outside its own temp dirs (same posture as
      # doctor without --fix).
      cmd_selfcheck "$@" ;;
    bug)
      # DIVE-2323: diagnostic bug-report verb against 5dive-ai/5dive. Preview
      # (the default) only builds and prints an allowlisted payload — no lock,
      # no audit, nothing leaves the box. Only --file performs the network
      # write (via `5dive gh issue create`), so that's the only arm audited,
      # same gating style as doctor's --repair/--fix above.
      for a in "$@"; do
        if [[ "$a" == "--file" ]]; then
          AUDIT_CMD="bug"; AUDIT_ARGS=("$@")
          break
        fi
      done
      cmd_bug "$@" ;;
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
    human|humans)
      # DIVE-3342: human accounts — one identity per person carrying their
      # telegram/buzz/discord ids, so a gate can name the PERSON who may clear it
      # instead of delivery guessing from whoever last DM'd the bot. Same store as
      # tasks/org; reads unprivileged, writes take root themselves (the table is
      # trusted input to gate delivery). No lock: plain sqlite writes, like org.
      cmd_human "$@" ;;
    ui)
      # DIVE-2655: the free single-host web UI (org chart / queue / gates).
      # Reads the same group-writable store as tasks + org; GET/HEAD only, no
      # root, no lock, no write path. Loopback bind unless the caller opts out.
      cmd_ui "$@" ;;
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
      # DIVE-1376/1460 (Bobby gripe #1): delegated push. Pushes ONLY the task's
      # branch, ONLY after the task gate clears, with a fail-closed author scan
      # (config-only committer). The privileged gate+author+mint+push runs atomically in the root-only
      # _push_do helper (repo-scoped token, agent never holds a credential).
      # Mutating + credential-bearing → audited (no token ever lands in argv).
      # `push setup` (DIVE-1461) is the BYO-GitHub-App onboarding sub-verb —
      # intercepted before cmd_push so "setup" isn't parsed as a task id.
      if [[ "${1:-}" == "setup" ]]; then
        shift
        AUDIT_CMD="push setup"; AUDIT_ARGS=("$@")
        cmd_push_setup "$@"
      else
        AUDIT_CMD="push"; AUDIT_ARGS=("$@")
        cmd_push "$@"
      fi ;;
    deploy)
      # INST-5: delegated PRODUCTION deploy — the capability broker generalized
      # off delegated push. Deploys ONLY the project@ref the task declares, ONLY
      # after that task's gate clears, and only into the repo the Vercel project
      # is already linked to. The privileged gate+bind+credential+deploy runs
      # atomically in the root-only _deploy_do helper; the agent never holds the
      # token. Mutating + credential-bearing -> audited.
      AUDIT_CMD="deploy"; AUDIT_ARGS=("$@")
      cmd_deploy "$@" ;;
    proof)
      # OSS-17: publish this box's zero-human proof (badge.json/zero-human.json/
      # history.jsonl) to a git status branch, computed verbatim from `digest`.
      # publish/status are read-mostly; on/off manage a root cron + pref, tick is
      # the root cron driver. No registry mutation/lock, no audit (like digest).
      cmd_proof "$@" ;;
    trace)
      # INST-1: causal timeline for one task (goal → ship). Read-only view over
      # existing data — task transition columns + project/parent/objective/loop
      # origin + gate provenance + the audit log. No mutation/lock/audit line,
      # same posture as usage/digest/memory.
      cmd_trace "$@" ;;
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
    council)
      # CNCL-6 (v0.11): standalone deliberation council. Embeds a node engine
      # materialized to a temp dir; reads are unprivileged, bench add/rm + the
      # receipt seal (gate-proof) take root themselves. No registry lock (the
      # persisted bench file is a plain jq write behind the sudo gate).
      cmd_council "$@" ;;
    constitution)
      # DIVE-1742: top-level front door onto the machine-enforced constitution.
      # `show` (READ) composes one JSON envelope (guardrails/thresholds/veto +
      # seal/verify state + amendment receipts) the dashboard consumes instead
      # of parsing constitution.yaml in-browser. Read-only; init (DIVE-1701) +
      # set (DIVE-1743) land next. Aliases into cmd_council internals.
      cmd_constitution "$@" ;;
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
    acp)
      # DIVE-3017: ACP over stdio, spawned BY a client (Buzz's runtime picker), so
      # this verb's stdout is the wire. AUDIT_CMD is deliberately NOT set: cmd_acp
      # `exec`s into bun, which replaces the process before the dispatcher's EXIT
      # trap can fire (DIVE-2797), so the row is written inside cmd_acp instead.
      cmd_acp "$@" ;;
    -h|--help|help) usage ;;
    *) fail "$E_USAGE" "unknown command: $top" ;;
  esac
}

# EXIT trap picks up AUDIT_CMD set by the dispatcher + real exit code and
# appends one NDJSON line to the audit log. Installed once at script load so
# every code path (including fail/exit) passes through it.
trap on_exit_audit EXIT

main "$@"
