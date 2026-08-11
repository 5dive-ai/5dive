#!/usr/bin/env bash
# 5dive agent management CLI — runs on user's runtime VM.
# State: /var/lib/5dive/agents.json (registry) + agents.d/<name>.env (per-agent systemd env).
# Each agent = Linux user `agent-<name>` in `claude` group (inherits shared
# /home/claude/.config|.claude|.codex|.aws) + systemd unit 5dive-agent@<name>.service
# running tmux session `agent-<name>` with the chosen CLI in a restart loop.
#
# Output contract:
#   - `--json` is accepted as a GLOBAL flag on any subcommand; stdout is then an
#     envelope `{ok:true,data:...}` on success or `{ok:false,error:{code,class,message}}`
#     on error. Text-mode stderr stays human-readable. Exit code always matches
#     error.code (see E_* below) so shell pipelines can branch without parsing.
#   - Progress `==>` lines always go to stderr so JSON stdout parses cleanly.
set -euo pipefail

# Some sbin tools (adduser, usermod, userdel) live in /usr/sbin and /sbin. On
# a normal interactive shell they're on PATH already, but when this script is
# spawned from a systemd unit that overrides PATH= (or any other restricted
# parent), /usr/sbin can be missing and the very first agent-create fails
# with "adduser: command not found". Prepend them unconditionally — duplicate
# entries are harmless.
case ":$PATH:" in
  *":/usr/sbin:"*) ;;
  *) export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH" ;;
esac

# NOT A VERSION, AND NOT BUMPED HERE (DIVE-2247). Since assignment moved to tag
# time, main carries this sentinel and release-cut.yml writes the real version onto
# the detached release commit it builds. `build.sh` checks the line exists; CI fails
# the bundle-drift check if it's missing or empty.
#
# IF YOU ARE RESOLVING A MERGE CONFLICT ON THIS LINE, read this first: the other
# side is a hand-assigned version from the era this ticket ended. Keeping the
# sentinel is correct — but that version was CLAIMED, and possibly installed
# somewhere, so it must not be re-issued. Check it is <= .release-floor and raise
# the floor if it is not. Graded by tests/release_cut_assign_unit.sh.
readonly FIVE_VERSION="0.0.0-dev"

# Build identity, not a release number. build.sh replaces this sentinel only in
# the generated bundle with the 40-hex commit whose clean source it concatenated
# (or <sha>-dirty when the bytes do not equal HEAD). Both sentinels are non-hex,
# so neither an unbuilt nor a dirty artifact can masquerade as identity whose
# ancestry install.sh can verify (DIVE-2603).
readonly FIVE_BUILD_SHA="unbuilt"

# GitHub org our repos live under. The org is being renamed
# 5dive-com -> 5dive-ai (2026-06); fetches must work on either side of the
# rename, so probe the new org once per process and fall back to the old
# name. GH_ORG env overrides the probe (CI, forks, air-gapped mirrors).
# NOTE: install.sh carries a standalone copy of this probe (it runs before
# the bundle exists) — change the two together.
gh_org() {
  if [[ -z "${_GH_ORG_RESOLVED:-}" ]]; then
    if [[ -n "${GH_ORG:-}" ]]; then
      _GH_ORG_RESOLVED="$GH_ORG"
    elif curl -fsI --max-time 8 "https://raw.githubusercontent.com/5dive-ai/5dive/main/install.sh" >/dev/null 2>&1; then
      _GH_ORG_RESOLVED="5dive-ai"
    else
      _GH_ORG_RESOLVED="5dive-com"
    fi
  fi
  printf '%s' "$_GH_ORG_RESOLVED"
}

# DIVE-1475: honor an env-set STATE_DIR instead of unconditionally reopening the
# LIVE store. Lets a test isolate to a temp tree that STICKS through sourcing (and
# survives into forked subprocesses via `sudo -E`/env_keep) — the isolation-failure
# class behind the 2026-07-19 /goal-spam AND the board wipe. Prod is unaffected:
# with the env var unset this is exactly "/var/lib/5dive".
STATE_DIR="${STATE_DIR:-/var/lib/5dive}"
REGISTRY="${STATE_DIR}/agents.json"
ENV_DIR="${STATE_DIR}/agents.d"

# DIVE-2336: the payload meaning "the env-override reporter did not run". Defined HERE, not
# in lib/env_overrides.sh, because it is the fallback for that file being unavailable — a
# fallback must not live inside the thing it is a fallback for. Caught by the full suite:
# tests/selfcheck_unit.sh sources only header/error_codes/output/cmd_selfcheck, so a
# call-site fallback that invoked `_env_ov_unavailable` found NO function, produced an
# empty string, and `jq --argjson eov ""` killed the whole --json contract (33/0 -> 26/7).
# NOT named FIVE_* on purpose: tests/lib/env_isolation.sh (DIVE-2325) blanket-clears that
# namespace, which would delete this constant inside every harness that needs it.
_5D_ENV_OV_UNAVAILABLE='{"process":[],"configured":[],"configured_state":"unavailable","configured_unreadable":[]}'
SYSTEMD_UNIT="5dive-agent@"

# Bumped when the on-disk registry shape changes in a way that older CLIs
# can't read. ensure_state stamps this into agents.json on create + migrates
# v0 (no version field) registries in place. Keep migrations pure-jq so they
# run without extra deps.
readonly REGISTRY_SCHEMA_VERSION=2

# Exclusive lock for mutating commands. Two dashboard clicks on "create" with
# the same name used to race on adduser + registry_write; now every mutation
# goes through with_registry_lock so there's exactly one writer at a time.
REGISTRY_LOCK="${STATE_DIR}/registry.lock"

# Append-only audit trail. Every mutating CLI invocation emits one NDJSON
# line with {ts,user,cmd,args,result,code}. Sensitive flags (api keys, bot
# tokens, callback codes) are redacted before write. The HTTP/exec path can
# pass the Clerk user via FIVEDIVE_AUDIT_USER; otherwise we fall back to
# SUDO_USER / USER.
AUDIT_LOG="/var/log/5dive/agent-audit.log"

# Named auth profiles let two agents of the same type authenticate against
# different accounts/keys. Each profile is a directory of env files (one per
# type) + any captured CLI config (e.g. a per-profile ~/.claude). The default
# profile has no name and uses the shared /etc/5dive/connectors/*.env files
# so existing single-account setups keep working unchanged.
AUTH_PROFILES_DIR="${STATE_DIR}/auth-profiles"

# Device-code login sessions for the non-TTY auth flow. Each live session is
# a tmux window owned by the `claude` user, driving `claude setup-token` (or
# equivalent). State lives under sessions/<id>/ — the dashboard polls it via
# `5dive agent auth poll` so no PTY bridge is required.
AUTH_SESSIONS_DIR="${STATE_DIR}/auth-sessions"

# Default tmux cwd for a newly-created agent. Per-agent override goes in the
# registry as .agents[name].workdir and is written to AGENT_WORKDIR in the
# systemd env file — 5dive-agent-start.sh reads it and falls back to this
# path if the configured dir isn't accessible.
DEFAULT_WORKDIR="/home/claude/projects"

# Per-agent channel secrets live here (readable by the agent user via
# EnvironmentFile in 5dive-agent@.service). Mode 0640 root:claude is written
# by the 5dive-write-connector helper — we call it so perms stay consistent.
# DIVE-1500: FIVEDIVE_CONNECTOR_DIR lets a test harness point channel
# resolution at fixture configs so it never picks up a real paired token
# (same env-honor class as STATE_DIR/TASKS_DIR/TASKS_DB). Note _task_agent_channel
# still falls back to $TELEGRAM_BOT_TOKEN from the process env, so a fixture
# harness should ALSO set FIVEDIVE_NOTIFY_DRYRUN=1 — the physical send guard.
CONNECTORS_DIR="${FIVEDIVE_CONNECTOR_DIR:-/etc/5dive/connectors}"

# Known agent types -> (bin path, supports channels yes/no).
# auth_file is the shared-config path that indicates the type is authenticated.
# Extend here to add a new agent type.
#
# ADDING A TYPE — the absent-vs-zero contract for every TYPE_* map below.
# These maps are read under `set -uo pipefail`, so whether an omitted key
# DEGRADES or CRASHES is a per-map decision that has to be written down. Two
# kinds, and the difference is not guessable from the declaration:
#
#   REQUIRED  — TYPE_BIN. It IS the type registry: is_known_type is literally
#               `[[ -n "${TYPE_BIN[$1]+x}" ]]` (lib/validation.sh), and readers
#               loop `${!TYPE_BIN[@]}`. A type absent here does not exist, so
#               bare reads are correct by construction.
#   OPTIONAL  — everything else (TYPE_CHANNELS, TYPE_AUTH, TYPE_INSTALL,
#               TYPE_API_FILE, TYPE_API_VAR, TYPE_PROBE, TYPE_SKILLS_DIR).
#               Omission is a MEANINGFUL signal with a documented default, so
#               every reader MUST supply it: `${TYPE_X[$type]:-<default>}`.
#               A bare read turns a supported state into an unbound-variable
#               crash that names the ARRAY and not the type — which is exactly
#               the bug DIVE-2076 fixed in five readers, and DIVE-2076's sweep
#               found again in cmd_auth_set, where the crash pre-empted a
#               graceful `fail` written for that very case one line below.
#
# Registering a new type: add TYPE_BIN (mandatory) and then decide each optional
# map explicitly. Prefer an explicit entry over relying on the default — write
# `[newtype]=0` in TYPE_CHANNELS rather than omitting it, so the intent is
# reviewable. tests/type_map_registration_contract_unit.sh enforces both halves:
# every optional-map reader carries a default, and TYPE_BIN keys are covered.
declare -A TYPE_BIN=(
  [claude]="/home/claude/.local/bin/claude"
  # codex is an npm global under nvm's per-version bin dir. Rather than hardcode
  # a single version path (the `v24` alias lags real node upgrades — a fresh box on
  # v24.18.0 left /home/claude/.nvm/.../v24/bin/codex stale and surfaced as
  # not_installed, DIVE-1329), the TYPE_INSTALL recipe symlinks the freshly
  # installed codex into ~/.local/bin (same dance as opencode/grok/pi) so
  # TYPE_BIN resolves on every box regardless of the active node version.
  [codex]="/home/claude/.local/bin/codex"
  [hermes]="/home/claude/.local/bin/hermes"
  [openclaw]="/home/claude/.local/bin/openclaw"
  [opencode]="/home/claude/.local/bin/opencode"
  # antigravity is Google's native-Go successor to gemini-cli. The installer
  # lands it at ~/.local/bin/agy. State dir is ~/.gemini/antigravity-cli/
  # (the binary identifies as product=antigravity but reuses Google's
  # ~/.gemini parent — see launch log in the antigravity scaffold landed
  # in 5dive@<post-removal>).
  [antigravity]="/home/claude/.local/bin/agy"
  # grok is xAI's CLI. Installer drops the binary at ~/.grok/bin/grok and
  # symlinks ~/.local/bin/grok — we point TYPE_BIN at the symlink to match
  # the convention of the other types.
  [grok]="/home/claude/.local/bin/grok"
  # pi is earendil-works' (Armin Ronacher) TypeScript/Node20 coding agent, the
  # backbone of OpenClaw. `npm i -g @earendil-works/pi-coding-agent` drops the
  # `pi` binary in nvm's per-version bin dir; the TYPE_INSTALL recipe symlinks
  # it into ~/.local/bin so TYPE_BIN resolves on every box (same dance as
  # opencode/openclaw). MIT, ~70.8k stars. Added for the v0.9 pi epic (DIVE-1196).
  [pi]="/home/claude/.local/bin/pi"
  # devin is Cognition's CLI (native binary). The cli.devin.ai installer
  # drops a versioned store at ~/.local/share/devin/cli/_versions/ and
  # symlinks ~/.local/bin/devin — TYPE_BIN points at the symlink, same
  # convention as grok/opencode.
  [devin]="/home/claude/.local/bin/devin"
)
# Which types accept --channels=telegram|discord. Each type wires the channel
# differently (see install_channel_for_<type>_agent below):
#   claude   — installs claude-plugins-official's telegram/discord plugin into
#              the agent user's ~/.claude/plugins; the bun server writes
#              ~/.claude/channels/<plugin>/access.json on first launch and
#              cmd_pair pops a pairing code into it.
#   openclaw — `openclaw channels add --channel <ch> --token <token>` writes
#              the credential into the openclaw gateway config; the openclaw
#              `pairing` subcommand handles inbound user approvals separately.
#   hermes   — writes TELEGRAM_BOT_TOKEN / DISCORD_BOT_TOKEN to the agent
#              user's ~/.hermes/.env; hermes' gateway picks it up at startup.
#   codex    — writes the bot token + access.json into the agent user's
#              ~/.codex/channels/telegram/; 5dive-agent-start wires the
#              telegram-codex MCP server + lifecycle hooks into config.toml
#              and launches codex with --dangerously-bypass-hook-trust.
#              telegram only (no discord build for codex yet).
#   grok     — same shape as codex: writes ~/.grok/channels/telegram/{.env,
#              access.json}; 5dive-agent-start writes [mcp_servers.telegram]
#              + [[hooks.*]] into ~/.grok/config.toml. grok runs with
#              --always-approve (set in 5dive-agent-start), which also
#              auto-trusts plugin/MCP commands. telegram only.
# Only claude needs the pair-code roundtrip — see cmd_pair's dispatch.
#
# OPTIONAL map, default 0 (see the absent-vs-zero contract above TYPE_BIN).
# An omitted key now reads as "no channel support" and `--channels` fails with
# the normal validation error naming the type; before DIVE-2076 it hard-crashed
# `agent types` with an unbound-variable error naming this array instead.
# Still write `[newtype]=0` explicitly rather than omitting: the default keeps a
# customer's box from crashing, it is not a substitute for declaring intent.
declare -A TYPE_CHANNELS=(
  [claude]=1
  [openclaw]=1
  [hermes]=1
  [codex]=1
  [grok]=1
  # opencode ships a telegram bridge too, but as a STANDALONE RELAY (not an MCP
  # server): telegram-opencode/server.ts IS the agent's main process and spawns
  # `opencode serve` over loopback HTTP. 5dive-agent-start launches `bun run
  # --cwd <plugin> start` instead of the opencode TUI; install writes the token
  # + access.json into ~/.opencode/channels/telegram. telegram only.
  [opencode]=1
  # antigravity (agy) ships the same telegram MCP bridge as grok/codex —
  # ~/.gemini/channels/telegram/{.env,access.json} + a shared plugin checkout
  # whose MCP server + lifecycle hooks 5dive-agent-start writes into the
  # GLOBAL ~/.gemini/config/{mcp_config.json,hooks.json} at boot (agy doesn't
  # auto-load a plugin's mcp_config/hooks — only skills/agents). telegram only.
  [antigravity]=1
  # pi ships a telegram bridge as a native pi EXTENSION (fork of benedict2310/
  # TelePi — pi has no MCP-server plugin model like codex/grok; it exposes an
  # in-process extension API). The channel installer (install_channel_for_pi_agent)
  # + telegram-pi plugin land in DIVE-1201/DIVE-1202; until then this flag only
  # marks pi channel-capable — creating a pi agent WITH --channels will fail at
  # install_channel_for_agent's dispatch until 1201 adds the `pi)` case. telegram only.
  [pi]=1
  # devin has no telegram/discord bridge yet — reachable via agent send/ask,
  # the task queue, and sibling agents. Explicit 0 (not omission) to declare
  # the no-channel intent, per the DIVE-2076 note above this map.
  [devin]=0
)
# Auth sentinel per type. Agent users run as agent-<name> (in group `claude`)
# and cannot read /home/claude/.claude/settings.json (mode 0600), so for
# claude-family types we check /etc/5dive/connectors/anthropic.env (0640
# root:claude) — that's the file systemd injects via EnvironmentFile.
# Format: "<path>"          -> file must exist and be non-empty
#         "<path>:<KEY>"    -> if path ends in .env, grep ^KEY=; else jq .env[KEY]
# Omit a type entirely to mark it auth-optional — auth_status_one returns "ok"
# without checking. opencode is the canonical example: it ships with free models
# and runs out of the box, so the dashboard shouldn't gate `agent create` on a
# sign-in the user doesn't need.
declare -A TYPE_AUTH=(
  [claude]="/etc/5dive/connectors/anthropic.env:CLAUDE_CODE_OAUTH_TOKEN"
  [codex]="/home/claude/.codex/auth.json"
  # Apr 2026 Anthropic policy change: third-party harnesses can no longer ride
  # the user's Claude Pro/Max subscription token (suspension risk). hermes and
  # openclaw both sign in via OpenAI's /codex/device flow now. hermes writes
  # ~/.hermes/auth.json; openclaw writes its agent-scoped auth-profiles.json
  # under the default agent id "main" (resolved by openclaw's resolveAgentDir).
  [hermes]="/home/claude/.hermes/auth.json"
  [openclaw]="/home/claude/.openclaw/agents/main/agent/auth-profiles.json"
  # antigravity tries the OS keyring first (via DBus secret-service) and
  # falls back to a file at ~/.gemini/antigravity-cli/antigravity-oauth-token
  # (mode 0600). Verified empirically against agy 1.0.1: after the device-
  # code flow completes (user pastes the Google OAuth callback code), the
  # binary writes the token-blob file with this exact name — no .json
  # extension, just the bare filename. Agent users run without a DBus
  # session, so the file path is always the live sentinel.
  [antigravity]="/home/claude/.gemini/antigravity-cli/antigravity-oauth-token"
  # grok writes ~/.grok/auth.json on successful `grok login --device-auth`.
  # Verified empirically — auth.json.lock pre-exists the actual auth.json
  # file (created on first device-auth attempt for the locking mechanism).
  [grok]="/home/claude/.grok/auth.json"
  # pi writes credentials to ~/.pi/agent/auth.json on `/login` (API-key provider
  # selection or OAuth for subscription providers; tokens auto-refresh). Verified
  # against @earendil-works/pi-coding-agent docs + benedict2310/TelePi 2026-07-14.
  # Same file-sentinel shape as codex/grok. NOTE: pi ALSO accepts a bare
  # ANTHROPIC_API_KEY/OPENAI_API_KEY env var (no file written) — the api-key
  # injection path (TYPE_API_FILE/VAR + cmd_auth) is finalized in DIVE-1200.
  [pi]="/home/claude/.pi/agent/auth.json"
  # devin writes ~/.local/share/devin/credentials.toml on `devin auth login`
  # (browser OAuth against the user's Devin account — no API key). Verified
  # empirically against devin 3000.2.17.
  [devin]="/home/claude/.local/share/devin/credentials.toml"
)
# Installer recipe per type. Run as `claude` user via `sudo -u claude -i bash -lc <recipe>`
# so $HOME/.nvm and PATH resolve correctly. Empty string => no automated installer
# (caller must hand-install). Idempotent: each recipe checks first.
declare -A TYPE_INSTALL=(
  # Gate on the EXACT TYPE_BIN path, never `command -v claude` — DIVE-2075,
  # reported by A-MO7SEN (github #196) and hit live during `5dive init` on a box
  # carrying an old npm-global claude. `command -v` answers "is something named
  # claude on PATH", which is a different question from "is the binary I am about
  # to hand to the systemd unit present": the stray wins, the recipe no-ops in
  # 0s, ~/.local/bin/claude is never created, and cmd_install fails with
  # "install reported success but $bin still missing" — permanently, because the
  # gate can never flip no matter how many times you retry. Same defect class as
  # DIVE-2061 (`command -v 5dive` grading the installed CLI instead of the bundle
  # under test). This is the question the codex comment below already prescribes.
  [claude]="[[ -x /home/claude/.local/bin/claude ]] || curl -fsSL https://claude.ai/install.sh | bash"
  # devin: same exact-path guard; the installer self-manages the versioned
  # store + ~/.local/bin symlink, so -x makes the recipe idempotent.
  [devin]="[[ -x /home/claude/.local/bin/devin ]] || curl -fsSL https://cli.devin.ai/install.sh | bash"
  # Verify the EXACT TYPE_BIN path (not `command -v codex`): a stray
  # /usr/bin/codex from apt or a codex left over under a non-v24 nvm major
  # would short-circuit the install and surface as "install reported success
  # but bin missing". `nvm install 24` provisions the pinned runtime on a fresh
  # box and selects it, forcing the npm install -g to land in v24's real bin
  # dir even when the `v24` alias has drifted (same drift the nightly
  # soft-updates hit — DIVE-1189). We then one-hop-symlink the just-installed
  # codex into ~/.local/bin (where TYPE_BIN[codex] and the agent unit's PATH
  # look). We resolve its real path as `$(npm prefix -g)/bin/codex` — NOT
  # `command -v codex`, which can land on a stray /usr/bin/codex, and NOT
  # `dirname $(nvm which 24)`, which is what this recipe used until DIVE-2596.
  #
  # DIVE-2596: `nvm which 24` and `npm prefix -g` are NOT the same directory,
  # and the comment that used to sit here asserted they were ("== `npm prefix
  # -g`/bin, so the symlink is guaranteed to point at the codex we just
  # installed"). They are two different questions:
  #   nvm which 24  — which node did nvm SELECT   (an intent)
  #   npm prefix -g — which node is RUNNING npm   (the outcome of this install)
  # They diverge because ~/.local/bin precedes nvm's bin dir on PATH and holds a
  # `node` symlink planted by the openclaw recipe below, pinned at whatever
  # `nvm which 24` meant on the day openclaw was last installed. npm is a
  # `#!/usr/bin/env node` script, so nvm's npm gets EXECUTED BY that pinned
  # node, and `npm prefix -g` (derived from process.execPath) reports the
  # pinned node's prefix — which is where `npm install -g` then puts the
  # binary. `nvm use` cannot correct this: it edits PATH, and the shadow is
  # EARLIER on PATH. Measured on the 5dive host: nvm which 24 -> v24.19.0,
  # npm prefix -g -> v24.18.0, codex under v24.18.0/bin, symlink dangling,
  # create aborting with "install reported success but bin still missing" on a
  # box where codex works fine.
  #
  # `npm prefix -g` is immune by construction: the same npm process answers the
  # locator query and performs the install, so target and outcome cannot
  # disagree. Mirrors openclaw below, which already derives its target this way.
  # Note we do NOT copy openclaw's `nvm use 24 --silent`: measured on the host,
  # it does not move `npm prefix -g` (the shadow is earlier on PATH than
  # anything `nvm use` edits), and tests/codex_install_node24_unit.sh forbids
  # the substring outright because `nvm use` alone cannot provision a fresh box
  # (DIVE-1329). Adding it would buy nothing and cost that guard.
  #
  # `nvm install 24` also resolves 24 against the REMOTE, so it downloads and
  # installs a brand-new v24 whenever upstream cuts one — which is what makes
  # `nvm which 24` move out from under a box that has not changed. That is why
  # the -x short-circuit stays FIRST: an already-installed codex must not drag
  # a node download onto every create.
  #
  # The trailing `-x` assert is the second half of the fix: a dangling symlink
  # now fails the recipe with an honest rc instead of being reported as a
  # successful install and re-diagnosed downstream (cmd_auth.sh) as a missing
  # binary, which is a true statement about the wrong object — codex IS
  # installed; the LOCATOR was wrong.
  # DIVE-1189: `5dive agent install codex --upgrade` sets FORCE_INSTALL=1 to skip
  # the -x short-circuit and reinstall @latest in place; without it (the
  # provisioning path) an existing codex is left untouched. \$-escaped so the
  # var expands when the recipe runs under `bash -lc`, not at array-definition time.
  [codex]="{ [[ -z \"\${FORCE_INSTALL:-}\" ]] && [[ -x /home/claude/.local/bin/codex ]]; } || { . /home/claude/.nvm/nvm.sh && nvm install 24 >/dev/null && npm install -g @openai/codex@latest && mkdir -p /home/claude/.local/bin && ln -sfn \"\$(npm prefix -g)/bin/codex\" /home/claude/.local/bin/codex && [[ -x /home/claude/.local/bin/codex ]]; }"
  # opencode.ai's installer drops the binary at ~/.opencode/bin/opencode and
  # only adds it to PATH via .bashrc — but bash -lc skips .bashrc on
  # non-interactive shells, so neither the verify check below nor the agent
  # systemd unit (which uses TYPE_BIN's path directly) would find it.
  # Symlink into ~/.local/bin so TYPE_BIN[opencode] resolves on every box.
  [opencode]="[[ -x /home/claude/.local/bin/opencode ]] || { curl -fsSL https://opencode.ai/install | bash && mkdir -p /home/claude/.local/bin && ln -sf /home/claude/.opencode/bin/opencode /home/claude/.local/bin/opencode; }"
  # Both upstreams launch an interactive setup wizard that opens /dev/tty
  # after the binary lands. shelld runs us without a controlling terminal,
  # so the wizard's `exec </dev/tty` blows up with ENXIO and the recipe
  # exits non-zero even though install itself succeeded. Pass the upstream
  # opt-outs (--skip-setup / --no-onboard) to land at the binary and stop.
  # openclaw also defaults to an npm install that drops the binary in
  # nvm's per-version bin dir, not ~/.local/bin — symlink it so TYPE_BIN
  # resolves on every box (same dance as opencode above).
  # hermes' upstream installer recreates /home/claude/.hermes at mode 0700,
  # overriding the 2770 from users.sh and blocking agent-* (claude-group)
  # users from traversing it to exec the venv binary — the unit then
  # crash-loops with `binary not installed`. chmod back to 0775 to match
  # the live perms of /home/claude/.opencode and .local/share/claude.
  [hermes]="[[ -x /home/claude/.local/bin/hermes ]] || { curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup && chmod 0775 /home/claude/.hermes; }"
  # openclaw's launcher is `#!/usr/bin/env node`, so symlinking only the CLI
  # into ~/.local/bin leaves it unexecutable in systemd/create-time envs where
  # nvm's per-version bin directory is absent from PATH. Install a supported
  # Node 24 and give both executables stable one-hop links in ~/.local/bin.
  # Install the npm package directly under the active Node 24 prefix. The
  # upstream wrapper re-selects nvm's default Node and may attempt a privileged
  # NodeSource upgrade, which fails in our non-interactive `sudo -u claude`
  # installer. FORCE_INSTALL makes --upgrade refresh this exact Node-24 global.
  [openclaw]="{ . /home/claude/.nvm/nvm.sh && nvm install 24 >/dev/null && nvm use 24 --silent; } && { [[ \"\${FORCE_INSTALL:-0}\" != 1 && -x \"\$(npm prefix -g)/bin/openclaw\" ]] || npm --loglevel=error --no-fund --no-audit install -g openclaw@latest; } && mkdir -p /home/claude/.local/bin && ln -sfn \"\$(nvm which 24)\" /home/claude/.local/bin/node && ln -sfn \"\$(npm prefix -g)/bin/openclaw\" /home/claude/.local/bin/openclaw && [[ -x /home/claude/.local/bin/openclaw ]]"
  # antigravity's installer drops the native-Go binary at ~/.local/bin/agy
  # and self-updates in the background on each run, so no daily-cron
  # equivalent of @google/gemini-cli's npm update is needed.
  # DIVE-901: gate and verify must agree. `command -v agy` can hit a copy
  # outside TYPE_BIN (PATH drift, image pre-seed) — the recipe then no-ops in
  # 0s and the -x TYPE_BIN guard fails even though agy works. Same class as
  # grok's opportunistic-symlink gap below: ensure the TYPE_BIN symlink
  # ourselves instead of trusting where the binary happened to land.
  # DIVE-2075: the gate itself was still `command -v agy`, so a stray agy on PATH
  # skipped the install and left us hoping the fallback could symlink something.
  # Gate on TYPE_BIN; the trailing `command -v agy` stays, because there the
  # question really is "where did the installer put it".
  [antigravity]="[ -x /home/claude/.local/bin/agy ] || curl -fsSL https://antigravity.google/cli/install.sh | bash; [ -x /home/claude/.local/bin/agy ] || { mkdir -p /home/claude/.local/bin; p=\$(command -v agy 2>/dev/null || true); [ -n \"\$p\" ] && ln -sf \"\$p\" /home/claude/.local/bin/agy; }"
  # grok's installer drops the binary at ~/.grok/bin/grok but only creates the
  # ~/.local/bin/grok symlink *opportunistically* (its line 328 requires
  # ~/.local/bin already on PATH and ~/.grok/bin not on PATH). On a fresh VM
  # those conditions often don't hold, so it just appends ~/.grok/bin to
  # .bashrc and never makes the symlink TYPE_BIN expects — hence we create the
  # symlink ourselves here rather than trusting the installer. We also drop the
  # installer's ~/.local/bin/agent symlink so it can't shadow future tooling.
  # The binary self-updates on launch; no daily-cron entry needed.
  # DIVE-2075: gate on TYPE_BIN, not `command -v grok` — a stray grok on PATH
  # skipped the install, ~/.grok/bin/grok then did not exist so the symlink
  # branch no-oped too, and the recipe still exited 0 via the trailing `rm -f`.
  [grok]="[ -x /home/claude/.local/bin/grok ] || curl -fsSL https://x.ai/cli/install.sh | bash; mkdir -p /home/claude/.local/bin; [ -e /home/claude/.grok/bin/grok ] && ln -sf /home/claude/.grok/bin/grok /home/claude/.local/bin/grok; rm -f /home/claude/.local/bin/agent"
  # pi is a plain npm package. Install-on-demand like codex (nvm install 24 so the
  # global install lands in v24's bin dir even when the default alias drifted),
  # then symlink into ~/.local/bin like opencode/openclaw so TYPE_BIN[pi]
  # resolves on every box (the systemd unit uses TYPE_BIN's path directly, and
  # bash -lc skips .bashrc so npm's bin dir isn't on PATH). Idempotent via the
  # -x guard. \$-escaped so npm prefix expands when the recipe runs under bash -lc.
  [pi]="[[ -x /home/claude/.local/bin/pi ]] || { . /home/claude/.nvm/nvm.sh && nvm install 24 >/dev/null && npm install -g @earendil-works/pi-coding-agent && mkdir -p /home/claude/.local/bin && ln -sf \"\$(npm prefix -g)/bin/pi\" /home/claude/.local/bin/pi; }"
)

# vercel-labs/skills CLI agent ID per 5dive type. `npx skills add --agent <id>`
# uses this to drop SKILL.md into the right per-type dir. openclaw isn't in
# the upstream registry — passing through its own name makes the CLI fall
# back to a generic project install at ./skills/<id>, which is what we want.
declare -A SKILLS_AGENT_ID=(
  [claude]=claude-code
  [codex]=codex
  [hermes]=hermes-agent
  [openclaw]=openclaw
  [opencode]=opencode
  # `npx skills add --agent antigravity` is NOT in the upstream registry, but
  # the CLI silently falls back to a generic install path (.agents/skills/) —
  # which is exactly where agy itself reads from (see SKILLS_INSTALL_DIR below).
  # So passing it through works, even though it's an "unknown" agent id.
  [antigravity]=antigravity
  # pi, like grok, is a manual-install type (see _skill_needs_manual_install):
  # `npx skills add --agent pi` lands skills in ~/.pi/skills, which pi's resource
  # loader does NOT scan, so pi is git-clone+cp'd into SKILLS_INSTALL_DIR[pi]
  # instead. This id is retained only for the `skill list` annotation, mirroring
  # [grok]=grok (the manual path ignores it for install) (DIVE-1265).
  [pi]=pi
  [grok]=grok
)
# Where the skills CLI lands SKILL.md inside the agent user's $HOME, per type.
# Used for post-install verification, the cmd_skill_list dir-scan fallback,
# and cmd_skill_rm. Probed empirically against npx skills v0.x — if upstream
# changes a path, update here. Unknown types fall through to ".claude/skills"
# in the lookup sites below.
#
# DIVE-2583 — THE CONTRACT, because prose elsewhere in this repo contradicted it:
# every value here is $HOME-RELATIVE (it is joined to /home/agent-<name>/ at every
# call site), and EVERY known type has one. There is no such thing as a 5dive type
# "with no skills directory": an unmapped type does not get nothing, it gets the
# .claude/skills fallback. Any sentence claiming a harness has no skills dir is
# false about this map — see skills_install_dir() below for the resolver that
# decides it, and use that rather than restating a type list in prose.
#
# What this map does NOT claim: that the harness READS the directory. Landing a
# body is our side; loading it is the harness's. Two entries here are landed-but-
# unverified and are marked as such (codex/opencode, antigravity) — do not upgrade
# either note without a live seat.
declare -A SKILLS_INSTALL_DIR=(
  [claude]=".claude/skills"
  # codex/opencode: the upstream `npx skills --agent {codex,opencode}` install
  # path.
  #
  # codex: MEASURED 2026-08-03 (DIVE-2583), codex-cli 0.146.0 — it DOES scan
  # $HOME/.agents/skills. Method, because it matters: two canary SKILL.md files
  # in one throwaway HOME, one under .agents/skills and one under .codex/skills,
  # then `codex debug prompt-input` — BOTH appear in the injected
  # <skills_instructions> block with their real paths. The .codex one is the
  # positive control (it proves the probe can see a skill at all), so the
  # .agents one is a discovery, not an absence.
  #
  # THE TRAP, worth more than the result: `strings` on the real binary shows
  # $CODEX_HOME/skills everywhere and ZERO hits for "agents/skills". Grepping the
  # binary for the path constant would have concluded the exact opposite of the
  # truth. That is the same method the antigravity note below rests on — treat it
  # as a hint, never as the measurement.
  #
  # opencode: still UNMEASURED. Not installed on this box, so nothing to run.
  [codex]=".agents/skills"
  [hermes]=".hermes/skills"
  [openclaw]="skills"
  [opencode]=".agents/skills"
  # agy reads skills from {workspace}/.agents/skills/{name}/SKILL.md — confirmed
  # by grepping the antigravity binary for the path constant. Earlier map said
  # .gemini/antigravity-cli/skills (matching its state dir), which was a guess
  # — wrong. Upstream npx skills fallback already lands at .agents/skills.
  #
  # ...and per the codex entry above, a binary grep is NOT a measurement: codex
  # scans a root whose constant does not appear in its binary at all. So read the
  # claim below as an open question, not as a finding.
  #
  # DIVE-2583, the unreconciled half of that note: {workspace} is NOT $HOME for a
  # 5dive agy seat (workdir is a project dir under /home/claude/projects), while
  # every writer we have — preseed_antigravity_agent, the notify-user seed in the
  # channel installer, install_default_skill_for_agent — joins this value to
  # /home/agent-<name>/. If the binary really is workspace-relative, those bodies
  # are present-but-inert, the same "present is not in effect" trap DIVE-2568 hit
  # for memory. Nobody has run an agy seat to settle it (no antigravity agent
  # exists in the fleet — DIVE-2037), so it stays recorded, not resolved.
  [antigravity]=".agents/skills"
  # pi reads user skills from ~/.pi/agent/skills AND ~/.agents/skills (per its
  # resource-loader). We target .agents/skills — the cross-CLI shared dir agy/
  # codex/opencode also use, and where pi's notify-user seed already lands. This
  # is the manual git-clone+cp destination (pi is manual-install; DIVE-1265),
  # and it drives the list/rm dir-scan — add and list now agree here.
  [pi]=".agents/skills"
  [grok]=".grok/skills"
)

# skill_default_source <id> -> the repo a 5dive DEFAULT skill is installed from,
# or non-zero for any id that is not one of ours.
#
# DIVE-2678 iteration 3. The manifest is the authoritative provenance record, but
# it only ever describes skills that arrived via `agent skill add` — and MEASURED
# 2026-08-04, zero seats on this fleet carry one, because the create path
# (install_default_skill_for_agent) never wrote it. So on every seat that exists
# today the manifest answers nothing, and a default skill installed from a repo
# that is NOT <org>/skills exported bare and came back unresolvable.
#
# find-skills is exactly that case and it is not an edge: it ships on EVERY seat
# of every type, from vercel-labs/skills, and it was in the 18 skipped names on
# the measured export. This table is what lets provenance be recovered for a
# skill installed before the writer existed, with no network and no manifest.
#
# It must agree with the install_default_skill_for_agent call sites in
# agent_setup.sh; tests/pack_skill_source_roundtrip_unit.sh asserts that it does,
# so adding a default skill there without adding it here reds the suite.
skill_default_source() {
  case "$1" in
    find-skills) echo "vercel-labs/skills" ;;
    5dive-cli|compile-knowledge|openagent) echo "$(gh_org)/skills" ;;
    *) return 1 ;;
  esac
}

# skills_install_dir <type> -> the $HOME-relative dir an installed skill body
# lands in for that type. THE resolver: this is the expression cmd_pack.sh's
# import path, cmd_skill add/list/rm and agent_setup.sh each spell by hand, and
# DIVE-2583 exists because a rendered sentence stated a DIFFERENT answer than the
# one the installer computed. Anything that TELLS a user where skills go must ask
# this function, so the claim and the behaviour cannot drift apart. Total by
# construction — never empty, for any input — which is exactly why "a harness with
# no skills directory" describes nothing here.
skills_install_dir() {
  printf '%s\n' "${SKILLS_INSTALL_DIR[${1:-}]:-.claude/skills}"
}

# api-key target per type: the env file (in /etc/5dive/connectors for the
# default profile) and the env var inside it. Claude-family is special-cased
# in cmd_auth_set — `sk-ant-oat01-*` tokens write CLAUDE_CODE_OAUTH_TOKEN,
# everything else is ANTHROPIC_API_KEY. Non-claude types use a single var
# that matches what their CLI reads natively.
declare -A TYPE_API_FILE=(
  [claude]="anthropic.env"
  # hermes and openclaw intentionally omitted: both now sign in via OpenAI's
  # /codex/device flow and store credentials in their own files (~/.hermes/
  # auth.json, ~/.openclaw/agents/main/agent/auth-profiles.json). The
  # anthropic.env path no longer feeds either CLI. cmd_auth_set already
  # fails gracefully when a type isn't in this map.
  [codex]="openai.env"
  [opencode]="openai.env"
  [grok]="xai.env"
  # pi is multi-provider (see PI_PROVIDER_VAR): the connector file holds a
  # per-provider *_API_KEY var chosen by `auth set pi --provider`. It's listed
  # here (not in TYPE_API_VAR) so auth_creds_present's default-profile fallback
  # recognizes a pi key written to this file; cmd_auth_set resolves the var
  # itself rather than reading a single TYPE_API_VAR entry. DIVE-1200.
  [pi]="pi.env"
)
declare -A TYPE_API_VAR=(
  [claude]="ANTHROPIC_API_KEY"
  [codex]="OPENAI_API_KEY"
  [opencode]="OPENAI_API_KEY"
  [grok]="XAI_API_KEY"
  # pi is deliberately absent: it's multi-provider (no single native var).
  # cmd_auth_set resolves pi's target var from --provider via PI_PROVIDER_VAR.
)

# DIVE-2223: the file each harness ACTUALLY reads for its persona / standing
# instructions, relative to the agent user's $HOME. Before this map every persona
# was appended to ~/.claude/CLAUDE.md regardless of type: on a codex / opencode /
# pi / antigravity seat that write SUCCEEDS into a path with no consumer, so the
# agent runs bare while every file census counts a persona (same family as
# DIVE-1930). Rows were measured with a before/after role probe on a live seat,
# not read from docs — see community/wiki/per-harness-persona-file-paths.md.
#
# OPTIONAL map whose default is deliberately NOT the claude path: an unmapped
# type makes persona_target() REFUSE and warn loudly (src/lib/agent_setup.sh).
# Silently defaulting to ~/.claude/CLAUDE.md IS the bug this map removes, so an
# unknown type has to be loud rather than quietly wrong.
declare -A TYPE_PERSONA_FILE=(
  [claude]=".claude/CLAUDE.md"
  # grok lands here by DOCUMENTED BEHAVIOUR, not by accident: its
  # docs/user-guide/12-project-rules.md says Claude compatibility is ON by
  # default, so it scans home-level ~/.claude/ for CLAUDE.md / AGENTS.md. One
  # path, two harnesses.
  [grok]=".claude/CLAUDE.md"
  # codex ALREADY holds the DIVE-1410 return-channel doc here (preseeded during
  # create by preseed_codex_return_channel), so persona_install_doc PREPENDS —
  # an overwrite would delete operational plumbing to install an identity.
  [codex]=".codex/AGENTS.md"
  [opencode]=".config/opencode/AGENTS.md"
  # note the /agent segment: pi's resource loader does not read ~/.pi/AGENTS.md
  # (same trap as SKILLS_INSTALL_DIR[pi], DIVE-1265).
  [pi]=".pi/agent/AGENTS.md"
  # antigravity reuses Google's ~/.gemini parent (see the TYPE_BIN note).
  [antigravity]=".gemini/GEMINI.md"
  # hermes: NOT ~/.hermes/AGENTS.md, which is the path everyone guesses (DIVE-2245
  # said so itself). hermes' prompt_builder loads AGENTS.md / CLAUDE.md from the
  # CWD ONLY — a home-level one is never read — while SOUL.md is the identity slot
  # it reads from HERMES_HOME (~/.hermes) and always injects. Measured on a live
  # seat: NOT TOLD -> "I am Quill, the Release Archivist". `hermes gateway install`
  # PRESEEDS SOUL.md with the Nous default identity during create, so this is an
  # occupied slot like codex's — persona_install_doc PREPENDS, and an overwrite
  # would delete the harness's own default persona.
  [hermes]=".hermes/SOUL.md"
  # openclaw injects a fixed set of WORKSPACE files every session (AGENTS.md,
  # SOUL.md, TOOLS.md, IDENTITY.md, USER.md); the workspace root is ~/.openclaw/
  # workspace, NOT the agent's --workdir and NOT a pi-shaped path. AGENTS.md is
  # the operating-instructions slot, which is where a role + reporting line
  # belongs (SOUL.md is tone/boundaries). Measured on a live seat: NOT TOLD ->
  # "my job title on this team is Ledger Steward". openclaw's first-run bootstrap
  # writes all of these during create, so this is an occupied slot too.
  [openclaw]=".openclaw/workspace/AGENTS.md"
)

# OpenCode reads provider API keys directly from standard environment variables.
# Keep this catalog deliberately small: these are the providers the 5dive auth
# path has explicitly verified and can inject without writing OpenCode's native
# auth.json. OpenRouter is the broad multi-model option; OpenAI remains available
# for backwards compatibility with the old provider-less auth-set path.
declare -A OPENCODE_PROVIDER_VAR=(
  [openai]="OPENAI_API_KEY"
  [openrouter]="OPENROUTER_API_KEY"
)

# pi provider -> native env var. pi is API-key multi-provider (NO OAuth): it
# reads the standard per-provider *_API_KEY var straight from the environment
# (verified against @earendil-works/pi-coding-agent 0.80.6 dist — it recognizes
# ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY / OPENROUTER_API_KEY /
# DEEPSEEK_API_KEY / ZAI_API_KEY / MOONSHOT_API_KEY / XAI_API_KEY / ...). 5dive
# injects the chosen var via the connector env file / profile combined.env the
# same way codex/opencode/grok do their single native var. DIVE-1200 wired the
# three core providers; DIVE-1205 adds OpenRouter + the Chinese models
# (DeepSeek / GLM-Zhipu[=zai] / Kimi-Moonshot / Qwen). IMPORTANT: these are ALL
# built-in pi providers — pi ships each provider's base_url in its own model
# registry (docs/providers.md "For each provider, pi knows all available
# models"), so 5dive does NOT need a custom base_url; injecting the right
# *_API_KEY var is sufficient and pi resolves the endpoint itself. Qwen has no
# standalone pi provider var, so it routes through OpenRouter. Provider ids
# below match pi's `--provider` / auth.json-key column (docs/providers.md table)
# so a `--model` pin resolves to the correct built-in provider. DIVE-1205.
declare -A PI_PROVIDER_VAR=(
  [anthropic]="ANTHROPIC_API_KEY"
  [openai]="OPENAI_API_KEY"
  [google]="GEMINI_API_KEY"
  [openrouter]="OPENROUTER_API_KEY"
  [deepseek]="DEEPSEEK_API_KEY"
  [moonshotai]="MOONSHOT_API_KEY"
  [kimi-coding]="KIMI_API_KEY"
  [zai]="ZAI_API_KEY"
  [minimax]="MINIMAX_API_KEY"
)

# BYO provider catalog for hermes/openclaw. The dashboard's new-agent
# wizard collects a canonical id (lowercase, vendor-style) from the user;
# this table maps it to the provider id each agent CLI's native registry
# recognizes plus a sensible default model so the agent's first launch
# doesn't sit at a "model not configured" prompt. Empty string in the
# native column means the type's registry doesn't have that vendor — the
# wizard hides that tile for that agent type.
#
# Native ids were verified empirically:
#   - hermes auth add <p> --type api-key --api-key <k>   (writes ~/.hermes/auth.json,
#       auto-resolves base_url from the in-tree provider catalog).
#   - openclaw writes auth-profiles.json with type:"api_key" entries; provider
#       ids must match openclaw's built-in provider registry (anthropic, openai,
#       google, deepseek, moonshot, openrouter all present).
#
# hermes-moonshot is a special case: its registry has a Kimi provider but no
# `hermes auth add moonshot` subcommand — the key is read from KIMI_API_KEY in
# ~/.hermes/.env at gateway startup (see .env.example upstream). _apply_byo_hermes
# branches on canonical=="moonshot" to take the env-var path instead of `auth add`,
# and cmd_create copies the value into agent-<name>'s own .env before the gateway
# is started. The HERMES_PROVIDER_ID value for moonshot ("kimi") is used as the
# argument to `hermes config set model.provider`, not as an `auth add` id.
declare -A HERMES_PROVIDER_ID=(
  [openai]=""
  [anthropic]="anthropic"
  [google]="gemini"
  [deepseek]="deepseek"
  [moonshot]="kimi"
  [openrouter]="openrouter"
  [nous]="nous"
  [zai]="zai"
  [minimax]="minimax"
  [qwen]="alibaba"
  [huggingface]="huggingface"
)
# Explicit BYO base_url override for hermes, keyed by canonical id. hermes
# normally auto-resolves model.base_url from its own provider catalog, but for
# z.ai that catalog resolves an endpoint the GLM Coding-Plan key does NOT auth
# against, so hermes+zai fails "Provider authentication failed" even with a
# correct key (DIVE-1819). We pin the verified anthropic-wire endpoint z.ai
# actually serves the coding models on (same one pi and the claude anthropic-skin
# use — CLAUDE_PROVIDER_BASEURL[zai]). Only providers with a known-good override
# are listed; everything else falls through to hermes' catalog resolution
# (base_url left unset, see _apply_byo_hermes).
declare -A HERMES_PROVIDER_URL=(
  [zai]="https://api.z.ai/api/anthropic"
)
declare -A OPENCLAW_PROVIDER_ID=(
  [openai]="openai"
  [anthropic]="anthropic"
  [google]="google"
  [deepseek]="deepseek"
  [moonshot]="moonshot"
  [openrouter]="openrouter"
  [nous]=""
  # DIVE-3130: openclaw 2026.7.1-2's catalog enumerates NO zai models
  # (`models list --provider zai --plain` → "No models found"; the GLM ids it
  # carries sit under byteplus/, novita/, nvidia/, together/ and volcengine/).
  # zai is KEPT rather than dropped, deliberately: an unenumerated namespace is a
  # NO-ORACLE state, not a proof of unroutability (see
  # community/wiki/a-byo-model-pin-can-only-be-graded-off-ci.md), and the
  # DIVE-1826 coding-endpoint pin in OPENCLAW_PROVIDER_URL still applies. What
  # changed is that a zai seat can no longer be created WITHOUT a model: with no
  # OPENCLAW_PROVIDER_MODEL row, _apply_byo_openclaw now refuses unless the
  # operator passes --model. Do not add a [zai] model row here until an id is
  # graded against `models list --provider zai --plain` on the installed version.
  # DIVE-3184 makes that NO-ORACLE reading provable rather than assumed: on the
  # same version, `models list --provider notaprovider --plain` prints "No models
  # found." at exit 0, BYTE-IDENTICAL (diff-clean) to what zai, qwen and
  # huggingface return. The oracle is one-sided — a hit is authoritative, a miss
  # says nothing — so those three stay listed. Do not read them as
  # measured-unroutable and delete them.
  [zai]="zai"
  [minimax]="minimax"
  [qwen]="qwen"
  [huggingface]="huggingface"
)
# Explicit BYO provider base_url override for openclaw, keyed by canonical id.
# openclaw's own provider catalog resolves each provider's endpoint, and for most
# providers that's correct so no entry is listed here. z.ai is the exception
# (DIVE-1826, the openclaw sibling of the DIVE-1819 hermes fix):
#
#   1. openclaw's zai provider speaks z.ai's OpenAI-compatible REST surface
#      (`/paas/v4`), NOT the anthropic-wire endpoint. So — unlike hermes and pi,
#      which pin `api.z.ai/api/anthropic` (HERMES_PROVIDER_URL / CLAUDE_PROVIDER_
#      BASEURL) — openclaw must be pointed at the openai-compat *coding* URL
#      `https://api.z.ai/api/coding/paas/v4`. Pinning the anthropic URL here would
#      break openclaw (wrong wire format). The two override tables are deliberately
#      NOT shared for this reason.
#   2. z.ai exposes four endpoint families (zai-global / zai-cn / zai-coding-global
#      / zai-coding-cn). openclaw's `zai-api-key` auto-detect probes the GENERAL
#      endpoints (zai-global, zai-cn) BEFORE the Coding Plan ones, and our create
#      path writes a bare `{provider:zai}` auth profile that never runs that probe
#      — so a GLM Coding-Plan key (which authorizes the *coding* surface) lands on
#      the general endpoint and 401s "authentication failed" (what lodar hit).
#      Pinning models.providers.zai.baseUrl to the coding-global URL selects the
#      right surface deterministically. Coding-Plan CN users override per agent
#      (`5dive agent <name> tui`) — we default to the global coding endpoint.
declare -A OPENCLAW_PROVIDER_URL=(
  [zai]="https://api.z.ai/api/coding/paas/v4"
)
# Optional per-(type, canonical) default model. Missing entry => leave the
# agent's own default selection logic alone. Conservative defaults: pick
# the vendor's flagship general-purpose model that's likely to exist in
# the in-tree catalog. When an entry turns out to be wrong (model id
# renamed upstream), the user can override via `5dive agent <name> tui`
# and the agent CLI's own model picker.
declare -A HERMES_PROVIDER_MODEL=(
  # Both catalogs are PER-PROVIDER, and so is the SPELLING: grade a pin against
  # its own provider's list, never against a grep of the whole catalog file.
  # hermes' curated anthropic list (hermes_cli/models.py) carries claude-sonnet-5
  # and the DATED claude-sonnet-4-5-20250929, but no bare claude-sonnet-4-5.
  # That bare id does appear in the same file, DASHED under `opencode-zen` and
  # `novita`, and DOTTED as claude-sonnet-4.5 under `copilot` and `novita`.
  # So a grep is blind twice over: wrong provider, and wrong spelling of the
  # same model. See DIVE-2607.
  #
  # And hermes has TWO catalogs per provider, which disagree:
  # curated_models_for_provider() prefers a LIVE models.dev/API fetch
  # (provider_model_ids) and falls back to the static _PROVIDER_MODELS only when
  # that fetch fails. `gemini` and `deepseek` are both in _MODELS_DEV_PREFERRED,
  # so the live list is the one that resolves a BYO pin — and it is SMALLER:
  # static deepseek carries deepseek-v4-pro, live carries only chat/reasoner.
  # DIVE-2607 cleared deepseek-v4-pro against the weaker list. So these pins are
  # chosen from the INTERSECTION of live and static: the pin then resolves
  # whichever catalog wins at runtime, including with the network down.
  # See DIVE-2628 and community/wiki/a-byo-model-pin-can-only-be-graded-off-ci.md.
  [anthropic]="claude-sonnet-5"
  [google]="gemini-3.5-flash"
  [deepseek]="deepseek-chat"
  [moonshot]="kimi-k2-turbo-preview"
  [openrouter]="openrouter/auto"
)
declare -A OPENCLAW_PROVIDER_MODEL=(
  # Grade a pin here with `openclaw models list --provider <native> --plain`,
  # NEVER with `--all`: `--all` is a SUBSET that omits the openai/, google/ AND
  # minimax/ namespaces entirely, and reading that omission as "no oracle" is
  # what left [openai] and [google] ungraded until DIVE-2631 and [minimax]
  # unpinned until DIVE-3184. The per-provider list is the same static catalog
  # (byte-identical to --all on `anthropic`, and unchanged with the network cut,
  # so it cannot flap).
  #
  # THAT LIST OF THREE IS NOT THE LIST OF OMISSIONS — it is the list of
  # omissions anyone has MEASURED. Four namespaces have ever been checked both
  # ways and three of the four were missing from --all (anthropic 9/9 diff-clean;
  # openai 20/0; google 7/0; minimax 3/0). The other 16 namespaces --all reports,
  # and any it hides that nobody has thought to ask about, are unmeasured in this
  # direction — and you cannot use --all to discover what --all is hiding. So the
  # rule takes no exceptions and needs no reasoning about which namespaces are
  # safe: use --provider, every time. It costs the same (DIVE-3183).
  #
  # And do NOT settle one of these against a DIFFERENT tool's catalog: models.dev
  # — which hermes itself prefers at runtime — lists both the old openai/gpt-4o
  # and the old google/gemini-2.0-flash as PRESENT. A cross-oracle read would
  # have cleared two genuinely stale pins. Only the list that resolves the pin
  # has authority over it (DIVE-2631).
  #
  # WHAT "STALE" MEANS HERE, AND WHAT IT DOES NOT. None of the replaced ids is
  # retired upstream. Google's own v1beta still serves gemini-2.0-flash (50
  # models, HTTP 200, queried with our key by main 2026-08-03), and models.dev
  # still lists gpt-4o. A pin is wrong here when the list that RESOLVES it does
  # not carry it, which is a property of the vendor agent's catalog, not of the
  # model's lifecycle. Write it that way in any future ticket or commit: "absent
  # from <the resolving list>, still present at <upstream>" — never "the vendor
  # dropped it". The two get fixed differently and only one of them is our bug.
  #
  # Measured on openclaw 2026.7.1-2: openai carries no gpt-4 family at all (20
  # ids, starting at gpt-5.3), google carries only 2.5.x/3.x (7 ids), moonshot
  # only k2.6 / k2.7-code, deepseek only chat / reasoner (DIVE-2628, DIVE-2631).
  # minimax carries 3 ids — MiniMax-M2.7, -M2.7-highspeed, M3 — graded on
  # 2026.7.1-2 (0790d9f) with anthropic=9 as the non-vacuity control; M2.7 is the
  # general-purpose one, so it is the pin rather than M3 (DIVE-3183/3184).
  #
  # zai, qwen and huggingface deliberately have NO row: their per-provider list
  # is empty on this version, which is a NO-ORACLE state and not a licence to
  # guess. They keep refusing at create until the operator passes --model
  # (DIVE-3130); the wizard's model field for them is DIVE-3183, not this table.
  [openai]="openai/gpt-5.6"
  [anthropic]="anthropic/claude-sonnet-5"
  [google]="google/gemini-3.5-flash"
  [deepseek]="deepseek/deepseek-chat"
  [moonshot]="moonshot/kimi-k2.6"
  [minimax]="minimax/MiniMax-M2.7"
  [openrouter]="openrouter/auto"
)
declare -A BYO_PROVIDER_LABEL=(
  [openai]="OpenAI"
  [anthropic]="Anthropic"
  [google]="Google AI"
  [deepseek]="DeepSeek"
  [moonshot]="Moonshot / Kimi"
  [openrouter]="OpenRouter"
  [nous]="Nous Portal"
  [zai]="Z.ai / GLM"
  [minimax]="MiniMax"
  [qwen]="Alibaba / Qwen"
  [huggingface]="Hugging Face"
)
valid_byo_provider() {
  [[ -n "${BYO_PROVIDER_LABEL[$1]:-}" ]]
}

# The canonical id a claude BYO agent carries when its endpoint came from
# --base-url rather than from the CLAUDE_PROVIDER_BASEURL catalog. It is a
# LABEL, not a vendor: nothing keys a model default or a native provider id off
# it, and it is deliberately absent from BYO_PROVIDER_LABEL so the pickers that
# enumerate that table (init step 6, the dashboard tiles) do not offer a vendor
# with no endpoint behind it (DIVE-2757).
CLAUDE_CUSTOM_PROVIDER_ID="custom"

# Validate an operator-supplied Anthropic-compatible endpoint for claude BYO.
#
# This value is written into an auth profile's combined.env and loaded by
# systemd as an EnvironmentFile, so the syntactic rules are not cosmetic: a
# newline forges a second variable in that file, and whitespace or a quote
# changes how systemd parses the line. Reject anything but a bare URL.
#
# SCHEME. https:// is required, because the agent's API key rides this URL on
# every request and a plaintext http:// endpoint puts it on the wire. The one
# exception is a loopback host — a local inference server (vLLM, llama.cpp,
# Ollama's anthropic shim) is reached over http://127.0.0.1 and never leaves the
# box, so requiring TLS there would refuse the most common self-hosted shape for
# no gain. A private-LAN address is NOT exempt: it is off-box, it is a real
# network, and "the LAN is trusted" is exactly the assumption that is wrong.
valid_base_url() {
  local url="$1" host=""
  [[ -n "$url" ]] || return 1
  (( ${#url} <= 512 )) || return 1
  # No whitespace (incl. newline/tab), quotes, backslash, or shell metacharacters.
  # Single-quoted so nothing in the class is expanded; `-` is last, `]` absent.
  # `]` must be first in the class and `-` last for both to be literal.
  local _re='^[]A-Za-z0-9._~:/?#@!$&*+,;=%[-]+$'
  [[ "$url" =~ $_re ]] || return 1
  case "$url" in
    https://*) return 0 ;;
    http://*)
      # Strip scheme, then any /path or ?query — what remains is host[:port].
      host="${url#http://}"; host="${host%%/*}"; host="${host%%\?*}"
      # A bracketed IPv6 literal is full of colons, so the port strip has to
      # respect the brackets or `[::1]:8080` truncates to `[:`.
      if [[ "$host" == \[*\]* ]]; then host="${host%%\]*}]"; else host="${host%:*}"; fi
      [[ "$host" == "127.0.0.1" || "$host" == "localhost" || "$host" == "[::1]" ]]
      return $? ;;
    *) return 1 ;;
  esac
}

# --- Claude (Claude Code) harness BYO custom-provider catalog -----------------
# The claude harness can be pointed at any third-party provider that ships an
# Anthropic Messages-API-compatible endpoint by overriding ANTHROPIC_BASE_URL +
# ANTHROPIC_AUTH_TOKEN and the per-tier model ids (the modern Claude Code knobs
# ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL — so whichever tier the agent
# selects, and the background haiku tasks, map to a model the provider actually
# serves instead of 404-ing on "claude-…"). Listed endpoints are VERIFIED, not
# necessarily vendor-DOCUMENTED — and the distinction is load-bearing, so do not
# "tidy" it back. Verified means: the route answers (401 for absent/invalid
# credentials, NOT 404 — a nonsense sibling path on the same host does return a
# real url.not_found body, which is what makes the 401 mean something) and a
# discriminating auth layer runs behind it (absent vs invalid credentials give
# different messages AND different error types).
#   moonshot is REAL BUT UNDOCUMENTED, measured 2026-07-28 (DIVE-2246). Moonshot's
# own docs describe an OpenAI-compatible API only — no `anthropic`, no `messages`,
# no ANTHROPIC_BASE_URL anywhere — yet api.moonshot.ai/anthropic answers exactly as
# above. A MISSING DOC PAGE IS NOT A MISSING ENDPOINT.
#   This comment previously said "only providers with a DOCUMENTED anthropic-compat
# endpoint are listed", which the table below it violated. That is worse than no
# comment: an auditor applying the stated rule finds moonshot backed by no vendor
# doc and DELETES A WORKING PROVIDER. If you add an entry here, verify the route
# yourself and say so — do not go looking for a doc page to justify it.
# The rest of BYO_PROVIDER_LABEL is intentionally absent (no compat path at all →
# would break the harness). Model
# ids drift upstream — operators can override per agent via the model picker, or
# we bump these. Values verified against vendor Claude-Code docs 2026-06-03.
# OpenRouter (DIVE-1100): OpenRouter ships a NATIVE Anthropic-skin endpoint at
# https://openrouter.ai/api (Claude Code appends /v1/messages), so the harness
# talks to it directly — no translation proxy. The OpenRouter key rides
# ANTHROPIC_AUTH_TOKEN (sk-or-…) and ANTHROPIC_API_KEY must be empty; both are
# already handled by _apply_byo_claude. NOTE: OpenRouter's Anthropic endpoint
# TRANSLATES — it accepts any OpenRouter model slug (openai/*, google/*, z-ai/*,
# deepseek/*, meta-llama/*) in Anthropic wire format and converts it, verified
# 2026-07-10 including a real headless Claude Code turn on z-ai/glm-4.6. The
# "openrouter/auto" alias does NOT resolve here (it's an OpenAI-format router
# convenience, not a real model), so we pin concrete per-tier defaults to
# anthropic/* as a SAFE DEFAULT — operators override any tier via
# `agent create --model=<slug>` or `agent config set model=<slug>` (DIVE-1103).
# Slugs verified against the LIVE openrouter.ai /api/v1/models list 2026-07-25
# (DIVE-1897). Verified present: anthropic/claude-opus-5, anthropic/claude-sonnet-5,
# anthropic/claude-haiku-4.5, openrouter/auto. NOTE haiku is deliberately NOT bumped:
# there is no claude-haiku-5 on OpenRouter, 4.5 is the current haiku. NOTE the opus
# slot was the only stale entry — its sibling sonnet was already at 5, so one tier had
# been bumped and the other had not.
# Qwen / Alibaba Model Studio (DIVE-2756): verified LIVE with a real Token Plan key
# 2026-08-07 — not doc-and-probe-only like the pre-ship research. A full /v1/messages
# POST to token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic returned 200 with
# a real completion, and a claude-type agent ran qwen3.8-max through this exact env
# shape for hours the same day. BEWARE THE KEY-SPACE SPLIT: Alibaba serves TWO
# credential families that do NOT interchange. Token Plan (subscription) keys auth
# ONLY on token-plan.<region>.maas.aliyuncs.com; pay-as-you-go Model Studio keys auth
# on dashscope[-intl|-us].aliyuncs.com. Measured 2026-08-07 with the same key across
# all three hosts: 200 on token-plan, `403 {"message":"invalid api-key"}` on both
# dashscope hosts — a discriminating auth layer rejecting a FOREIGN key, which is what
# makes the split real rather than a route difference. The tile ships the endpoint it
# was SMOKED on (token-plan); a pay-as-you-go key points at its own host through the
# generic `agent create --base-url` (DIVE-2757) instead of an unsmoked catalog default
# — a tile that 403s for every customer is worse than no tile. Region is part of the
# host (ap-southeast-1); operators on another region override via --base-url the same
# way. Auth rides ANTHROPIC_AUTH_TOKEN (Bearer) with ANTHROPIC_API_KEY empty — both
# already handled by _apply_byo_claude, same shape as openrouter. Model ids verified
# live the same day: qwen3.8-max answers on opus+sonnet tiers, qwen3.6-flash on the
# haiku tier. No context-cap var is set deliberately: the harness has no per-provider
# context knob, and a wrong one would silently TRUNCATE rather than error (the row's
# open question, resolved as "don't guess"). Region availability re-checked 2026-08-07
# (live probe + vendor confirmation): Token Plan is served ONLY from ap-southeast-1 —
# token-plan.eu-central-1 answers 400 BadRequest.IllegalEndpoint ("Workspace endpoint
# is invalid"), there is no eu-west-1 host, and us-east-1/cn-beijing reject the key
# (separate key namespaces). There is NO EU Token Plan endpoint to switch to for
# latency; EU-based boxes pay the ~170ms RTT to Singapore. Do not re-investigate
# without a new signal (a region added upstream, or a workspace provisioned in it).
declare -A CLAUDE_PROVIDER_BASEURL=(
  [deepseek]="https://api.deepseek.com/anthropic"
  [moonshot]="https://api.moonshot.ai/anthropic"
  [openrouter]="https://openrouter.ai/api"
  [qwen]="https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic"
  [zai]="https://api.z.ai/api/anthropic"
)
declare -A CLAUDE_PROVIDER_OPUS_MODEL=(
  [deepseek]="deepseek-v4-pro"
  [moonshot]="kimi-k2.5"
  [openrouter]="anthropic/claude-opus-5"
  [qwen]="qwen3.8-max"
  [zai]="glm-5.2"
)
declare -A CLAUDE_PROVIDER_SONNET_MODEL=(
  [deepseek]="deepseek-v4-pro"
  [moonshot]="kimi-k2.5"
  [openrouter]="anthropic/claude-sonnet-5"
  [qwen]="qwen3.8-max"
  [zai]="glm-5-turbo"
)
declare -A CLAUDE_PROVIDER_HAIKU_MODEL=(
  [deepseek]="deepseek-v4-flash"
  [moonshot]="kimi-k2.5"
  [openrouter]="anthropic/claude-haiku-4.5"
  [qwen]="qwen3.6-flash"
  [zai]="glm-4.5-air"
)

# claude_baseurl_catalog_provider <url> — reverse the CLAUDE_PROVIDER_BASEURL
# catalog: echo the canonical vendor id that serves <url>, or nothing when no
# row does. Empty output is the load-bearing answer: it means the url came from
# somewhere other than this table — i.e. an operator's --base-url (DIVE-2757) —
# which is the one value a re-derivation from the catalog must not silently
# overwrite (DIVE-2809). Exit status is not the signal; read stdout.
claude_baseurl_catalog_provider() {
  local url="$1" cand
  [[ -n "$url" ]] || return 0
  for cand in "${!CLAUDE_PROVIDER_BASEURL[@]}"; do
    if [[ "${CLAUDE_PROVIDER_BASEURL[$cand]}" == "$url" ]]; then
      echo "$cand"; return 0
    fi
  done
  return 0
}

# profile_env_value <profile> <VAR> — read one KEY=VALUE out of an auth
# profile's combined.env without creating anything (the writer's counterpart is
# profile_set_var in cmd_auth.sh, which is root-only and DOES create). Empty
# output for an absent file, an absent profile or an unset var — a caller that
# needs to tell those apart must check the file itself. Lives in header.sh
# rather than next to the writer because the create path reads it in contexts
# that do not source cmd_auth.sh.
profile_env_value() {
  local profile="$1" var="$2" file="${AUTH_PROFILES_DIR}/${1}/combined.env" v
  [[ -n "$profile" && -r "$file" ]] || return 0
  v=$(grep -E "^${var}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-) || v=""
  v="${v%\"}"; v="${v#\"}"
  printf '%s' "$v"
}

# Resolve a canonical UI id to the agent CLI's native provider id. Empty
# result means the type doesn't support that vendor and the caller should
# fail with a clear error.
resolve_native_provider() {
  local type="$1" canonical="$2"
  case "$type" in
    hermes)   echo "${HERMES_PROVIDER_ID[$canonical]:-}" ;;
    openclaw) echo "${OPENCLAW_PROVIDER_ID[$canonical]:-}" ;;
    # claude maps a supported provider to itself (the env-var override path in
    # _apply_byo_claude keys off the canonical id, not a renamed native id).
    claude)   [[ -n "${CLAUDE_PROVIDER_BASEURL[$canonical]:-}" ]] && echo "$canonical" ;;
    *)        echo "" ;;
  esac
}

# Reverse of resolve_native_provider for hermes: map a hermes-native provider id
# back to its canonical UI id. Needed anywhere a native id observed at runtime
# (e.g. a credential_pool key in auth.json, which is native — see cmd_account.sh
# set-active-provider) has to index a table keyed CANONICAL, like
# HERMES_PROVIDER_MODEL (DIVE-2666: that lookup used $native directly and
# silently no-op'd for the three providers HERMES_PROVIDER_ID renames — google,
# moonshot, qwen). Scans HERMES_PROVIDER_ID rather than a hand-maintained
# reverse table so the two tables can't drift out of sync.
#
# Echoes empty when $native doesn't match any HERMES_PROVIDER_ID value — the
# caller should treat that as a real key-space miss (an id our own table
# doesn't know, e.g. a future provider, a typo, or hermes' own further
# normalization of "kimi" to "kimi-coding") and warn rather than silently
# fall through, since every native id OUR code hands out does come from this
# same table and is expected to resolve.
resolve_canonical_provider_hermes() {
  local native="$1" canonical
  [[ -n "$native" ]] || { echo ""; return; }
  for canonical in "${!HERMES_PROVIDER_ID[@]}"; do
    if [[ "${HERMES_PROVIDER_ID[$canonical]}" == "$native" ]]; then
      echo "$canonical"
      return
    fi
  done
  echo ""
}

# Live auth probe: run "<cli> <args>" as user `claude` with a 5s wall-clock
# cap and see if exit==0. Empty string disables the probe for that type
# (fall back to sentinel-file presence). Args deliberately keep the prompt
# short — we care about "did the API accept our creds", not the response.
declare -A TYPE_PROBE=(
  [claude]='/home/claude/.local/bin/claude --print ping'
  # hermes/openclaw used to probe via `--print ping` against Anthropic; with the
  # OpenAI OAuth flow that argument shape no longer maps to a quick health check
  # we can rely on, so fall back to file-presence (auth_status_one returns "ok"
  # when no probe is configured and the credential file exists).
  [hermes]=''
  [openclaw]=''
  [codex]=''
  [opencode]=''
  # `agy --print ping` triggers a 30s OAuth wait when not authed and can't
  # tell stale-creds from rate-limit from a healthy box. File-presence is
  # the cheaper signal — fall through to TYPE_AUTH's sentinel.
  [antigravity]=''
  # `grok -p ping` would block on stdin via the inline UI; the `agent`
  # subcommand is meant for headless but takes longer to spin up than
  # we want for a 5s probe. Stick with file-presence.
  [grok]=''
  # devin -p spins up a full agent session — too slow for a 5s probe.
  # File-presence via the TYPE_AUTH sentinel.
  [devin]=''
)

# require_loaded <context> <fn>... — INST-5: fail-closed dependency assertion.
#
# The broker refactor moved push's security predicates out of cmd_push.sh and
# into src/lib/broker.sh. That introduced a failure mode the inline code could
# not have had: if the lib is not loaded, `broker_gate_check ...` is just
# "command not found" (rc 127), and as a BARE STATEMENT execution simply
# continues — push then reports "gate cleared" for a task carrying no gate at
# all. Extracting a predicate turns "cannot fail" into "fails open", so each
# brokered surface asserts its predicates are really loaded before it acts.
# Lives in header.sh deliberately: a guard against a missing file cannot itself
# live in the file that might be missing.
require_loaded() {
  local ctx="$1" fn; shift
  for fn in "$@"; do
    declare -F "$fn" >/dev/null && continue
    fail "$E_GENERIC" "${ctx}: required predicate '${fn}' is not loaded (src/lib/broker.sh missing from this build) — refusing"
  done
}
