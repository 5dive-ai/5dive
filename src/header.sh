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

# Bumped on every public release. `build.sh` checks this line exists; CI fails
# the bundle-drift check if it's missing or empty.
readonly FIVE_VERSION="0.9.6"

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

STATE_DIR="/var/lib/5dive"
REGISTRY="${STATE_DIR}/agents.json"
ENV_DIR="${STATE_DIR}/agents.d"
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
CONNECTORS_DIR="/etc/5dive/connectors"

# Known agent types -> (bin path, supports channels yes/no).
# auth_file is the shared-config path that indicates the type is authenticated.
# Extend here to add a new agent type.
declare -A TYPE_BIN=(
  [claude]="/home/claude/.local/bin/claude"
  [codex]="/home/claude/.nvm/versions/node/v24/bin/codex"
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
)
# Installer recipe per type. Run as `claude` user via `sudo -u claude -i bash -lc <recipe>`
# so $HOME/.nvm and PATH resolve correctly. Empty string => no automated installer
# (caller must hand-install). Idempotent: each recipe checks first.
declare -A TYPE_INSTALL=(
  [claude]="command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash"
  # Verify the EXACT TYPE_BIN path (not `command -v codex`): a stray
  # /usr/bin/codex from apt or a codex left over under a non-v24 nvm major
  # would short-circuit the install, leaving v24/bin/codex empty and
  # surfacing as "install reported success but bin missing". `nvm install 24`
  # provisions the pinned runtime on a fresh box and selects it, forcing the
  # npm install -g to land in v24's bin dir even when the default
  # alias has drifted (same drift the nightly soft-updates hit — DIVE-1189).
  # DIVE-1189: `5dive agent install codex --upgrade` sets FORCE_INSTALL=1 to skip
  # the -x short-circuit and reinstall @latest in place; without it (the
  # provisioning path) an existing v24 codex is left untouched. \$-escaped so the
  # var expands when the recipe runs under `bash -lc`, not at array-definition time.
  [codex]="{ [[ -z \"\${FORCE_INSTALL:-}\" ]] && [[ -x /home/claude/.nvm/versions/node/v24/bin/codex ]]; } || { . /home/claude/.nvm/nvm.sh && nvm install 24 >/dev/null && npm install -g @openai/codex@latest; }"
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
  [openclaw]="[[ -x /home/claude/.local/bin/openclaw ]] || { curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard && mkdir -p /home/claude/.local/bin && ln -sf \"\$(npm prefix -g)/bin/openclaw\" /home/claude/.local/bin/openclaw; }"
  # antigravity's installer drops the native-Go binary at ~/.local/bin/agy
  # and self-updates in the background on each run, so no daily-cron
  # equivalent of @google/gemini-cli's npm update is needed.
  # DIVE-901: gate and verify must agree. `command -v agy` can hit a copy
  # outside TYPE_BIN (PATH drift, image pre-seed) — the recipe then no-ops in
  # 0s and the -x TYPE_BIN guard fails even though agy works. Same class as
  # grok's opportunistic-symlink gap below: ensure the TYPE_BIN symlink
  # ourselves instead of trusting where the binary happened to land.
  [antigravity]="command -v agy >/dev/null || curl -fsSL https://antigravity.google/cli/install.sh | bash; [ -x /home/claude/.local/bin/agy ] || { mkdir -p /home/claude/.local/bin; p=\$(command -v agy 2>/dev/null || true); [ -n \"\$p\" ] && ln -sf \"\$p\" /home/claude/.local/bin/agy; }"
  # grok's installer drops the binary at ~/.grok/bin/grok but only creates the
  # ~/.local/bin/grok symlink *opportunistically* (its line 328 requires
  # ~/.local/bin already on PATH and ~/.grok/bin not on PATH). On a fresh VM
  # those conditions often don't hold, so it just appends ~/.grok/bin to
  # .bashrc and never makes the symlink TYPE_BIN expects — hence we create the
  # symlink ourselves here rather than trusting the installer. We also drop the
  # installer's ~/.local/bin/agent symlink so it can't shadow future tooling.
  # The binary self-updates on launch; no daily-cron entry needed.
  [grok]="command -v grok >/dev/null 2>&1 || curl -fsSL https://x.ai/cli/install.sh | bash; mkdir -p /home/claude/.local/bin; [ -e /home/claude/.grok/bin/grok ] && ln -sf /home/claude/.grok/bin/grok /home/claude/.local/bin/grok; rm -f /home/claude/.local/bin/agent"
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
  [grok]=grok
)
# Where the skills CLI lands SKILL.md inside the agent user's $HOME, per type.
# Used for post-install verification, the cmd_skill_list dir-scan fallback,
# and cmd_skill_rm. Probed empirically against npx skills v0.x — if upstream
# changes a path, update here. Unknown types fall through to ".claude/skills"
# in the lookup sites below.
declare -A SKILLS_INSTALL_DIR=(
  [claude]=".claude/skills"
  [codex]=".agents/skills"
  [hermes]=".hermes/skills"
  [openclaw]="skills"
  [opencode]=".agents/skills"
  # agy reads skills from {workspace}/.agents/skills/{name}/SKILL.md — confirmed
  # by grepping the antigravity binary for the path constant. Earlier map said
  # .gemini/antigravity-cli/skills (matching its state dir), which was a guess
  # — wrong. Upstream npx skills fallback already lands at .agents/skills.
  [antigravity]=".agents/skills"
  [grok]=".grok/skills"
)

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
declare -A OPENCLAW_PROVIDER_ID=(
  [openai]="openai"
  [anthropic]="anthropic"
  [google]="google"
  [deepseek]="deepseek"
  [moonshot]="moonshot"
  [openrouter]="openrouter"
  [nous]=""
  [zai]="zai"
  [minimax]="minimax"
  [qwen]="qwen"
  [huggingface]="huggingface"
)
# Optional per-(type, canonical) default model. Missing entry => leave the
# agent's own default selection logic alone. Conservative defaults: pick
# the vendor's flagship general-purpose model that's likely to exist in
# the in-tree catalog. When an entry turns out to be wrong (model id
# renamed upstream), the user can override via `5dive agent <name> tui`
# and the agent CLI's own model picker.
declare -A HERMES_PROVIDER_MODEL=(
  [anthropic]="claude-sonnet-4-5"
  [google]="gemini-2.0-flash"
  [deepseek]="deepseek-v4-pro"
  [moonshot]="kimi-k2-turbo-preview"
  [openrouter]="openrouter/auto"
)
declare -A OPENCLAW_PROVIDER_MODEL=(
  [openai]="openai/gpt-4o"
  [anthropic]="anthropic/claude-sonnet-4-5"
  [google]="google/gemini-2.0-flash"
  [deepseek]="deepseek/deepseek-v4-pro"
  [moonshot]="moonshot/kimi-k2-instruct"
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

# --- Claude (Claude Code) harness BYO custom-provider catalog -----------------
# The claude harness can be pointed at any third-party provider that ships an
# Anthropic Messages-API-compatible endpoint by overriding ANTHROPIC_BASE_URL +
# ANTHROPIC_AUTH_TOKEN and the per-tier model ids (the modern Claude Code knobs
# ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL — so whichever tier the agent
# selects, and the background haiku tasks, map to a model the provider actually
# serves instead of 404-ing on "claude-…"). Only providers with a documented
# anthropic-compat endpoint are listed; the rest of BYO_PROVIDER_LABEL is
# intentionally absent here (no compat path → would break the harness). Model
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
# Slugs verified against openrouter.ai 2026-07-10.
declare -A CLAUDE_PROVIDER_BASEURL=(
  [deepseek]="https://api.deepseek.com/anthropic"
  [moonshot]="https://api.moonshot.ai/anthropic"
  [openrouter]="https://openrouter.ai/api"
  [zai]="https://api.z.ai/api/anthropic"
)
declare -A CLAUDE_PROVIDER_OPUS_MODEL=(
  [deepseek]="deepseek-v4-pro"
  [moonshot]="kimi-k2.5"
  [openrouter]="anthropic/claude-opus-4.8"
  [zai]="glm-5.2"
)
declare -A CLAUDE_PROVIDER_SONNET_MODEL=(
  [deepseek]="deepseek-v4-pro"
  [moonshot]="kimi-k2.5"
  [openrouter]="anthropic/claude-sonnet-5"
  [zai]="glm-5-turbo"
)
declare -A CLAUDE_PROVIDER_HAIKU_MODEL=(
  [deepseek]="deepseek-v4-flash"
  [moonshot]="kimi-k2.5"
  [openrouter]="anthropic/claude-haiku-4.5"
  [zai]="glm-4.5-air"
)

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
)
