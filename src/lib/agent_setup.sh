# Path to the shared StopFailure hook (rate-limit -> Telegram + "press 1").
# Installed by scripts/install/agent-cli.sh + scripts/update.sh at this
# location so every agent can reference a single canonical copy.
STOP_FAILURE_HOOK="/usr/local/lib/5dive/stop-failure-telegram.sh"
# Path to the shared PreToolUse hook that blocks AskUserQuestion / ExitPlanMode
# in telegram-paired sessions (their pickers are tmux-only — Telegram users
# never see them and the agent hangs).
PRETOOL_TELEGRAM_HOOK="/usr/local/lib/5dive/pretool-telegram-question.sh"
# Path to the shared Stop hook that catches "Telegram inbound this turn but
# no reply tool call" slips and auto-relays the assistant's transcript text.
STOP_TELEGRAM_REPLY_HOOK="/usr/local/lib/5dive/stop-telegram-reply-check.sh"
# Path to the shared PostToolUse hook that pairs with the Stop hook —
# relays new assistant text after each tool call so multiple in-turn
# texts don't get coalesced or lost when the model emits text → tool →
# text without ever calling reply.
POSTTOOL_TELEGRAM_RELAY_HOOK="/usr/local/lib/5dive/posttool-telegram-relay.sh"
# Inter-agent group mirror is fully sender-side now: every `5dive agent
# send|ask` posts "@<receiver> <body>" to the SENDER's group via the sender's
# bot (see mirror_interagent_outbound in cmd_agent.sh). Both halves of an
# exchange — A's outbound question and B's outbound reply — therefore show up
# under the correct sender's identity. The previous receiver-side hooks
# (userprompt-mirror-inter-agent.sh for the inbound, stop-mirror-inter-agent.sh
# for the reply) are retired no-ops, kept on disk only so existing agents'
# settings.json don't error on a missing command. New-agent settings.json
# below no longer wires either of them.
AGENT_SKILLS_DIR="/usr/local/lib/5dive/skills"
# CLAUDE.md fragment dropped into the per-agent $HOME/.claude/ when the
# agent is created with --channels=telegram. Carries the per-turn reply
# mandate + AskUserQuestion/ExitPlanMode warning — guidance that only
# applies to telegram-paired agents and used to live in the shared
# projects-level CLAUDE.md, polluting every non-telegram agent's prompt.
TELEGRAM_AGENT_CLAUDE_MD="/usr/local/lib/5dive/telegram-agent-CLAUDE.md"

# Preseed a claude-family agent's home dir so:
#   - 'claude --dangerously-skip-permissions' doesn't hit the first-run
#     theme picker / trust dialog / project-onboarding prompts
#   - channels=telegram agents pick up the StopFailure hook that pings the
#     paired chat on rate limits
# Written per-agent-user — the agent user cannot read the shared
# /home/claude/.claude/settings.json (mode 0600), so 5dive-agent-start.sh
# unsets CLAUDE_CONFIG_DIR before launching claude, making $HOME/.claude
# (i.e. the preseed below) the effective config dir.
preseed_claude_agent() {
  local name="$1" channels="$2"
  local user="agent-${name}" home="/home/agent-${name}"
  [[ -d "$home" ]] || fail "$E_GENERIC" "agent home missing: $home"

  sudo -u "$user" mkdir -p "$home/.claude"

  # .claude.json: theme + onboarding + trust for /home/claude/projects
  sudo -u "$user" tee "$home/.claude.json" >/dev/null <<JSON
{
  "theme": "dark",
  "hasCompletedOnboarding": true,
  "projects": {
    "/home/claude/projects": {
      "hasTrustDialogAccepted": true,
      "hasCompletedProjectOnboarding": true
    }
  }
}
JSON
  chmod 600 "$home/.claude.json"

  # settings.json: bypassPermissions + the marketplace + (if telegram/discord)
  # the plugin. Telegram additionally wires a StopFailure hook that DMs the
  # paired chat on rate-limit; the discord equivalent would need a separate
  # hook script (not written yet) so discord agents just enable the plugin.
  # Built with jq so channels=none / telegram / discord diverge cleanly.
  # permissions.allow short-circuits BEFORE the channels/telegram plugin's
  # claude/channel/permission relay (anthropics/claude-cli-internal#23061),
  # so explicit allows skip the "🔐 Permission: Bash" Telegram prompt that
  # bypassPermissions alone doesn't suppress under channel-relay mode. The
  # 5dive-transcribe entry covers the voice-pack flow; harmless when voice
  # isn't installed.
  local settings
  settings=$(jq -n '{
    permissions: {
      defaultMode: "bypassPermissions",
      allow: ["Bash(5dive-transcribe:*)"]
    },
    skipDangerousModePermissionPrompt: true,
    autoDreamEnabled: true,
    extraKnownMarketplaces: {
      "claude-plugins-official": {
        source: {source: "github", repo: "anthropics/claude-plugins-official"}
      },
      "5dive-plugins": {
        source: {source: "github", repo: "5dive-com/5dive-plugins"}
      }
    }
  }')
  if [[ "$channels" == "telegram" ]]; then
    # 5dive-plugins/telegram (our fork) bundles PreToolUse / Stop /
    # PostToolUse hooks via its own hooks.json, so we no longer wire the
    # standalone /usr/local/lib/5dive/ copies into settings.json for
    # telegram agents — that would double-fire. StopFailure stays: the
    # rate-limit detection + transcript scrape are 5dive-specific with
    # no plugin equivalent yet.
    [[ -x "$STOP_FAILURE_HOOK" ]] \
      || warn "$STOP_FAILURE_HOOK missing — StopFailure hook not wired (run: curl -fsSL https://raw.githubusercontent.com/5dive-com/5dive/main/install.sh | sudo bash)"
    settings=$(jq \
      --arg hook "$STOP_FAILURE_HOOK" '
      . + {
        enabledPlugins: {"telegram@5dive-plugins": true},
        hooks: {
          StopFailure: [{hooks: [{type: "command", command: $hook, timeout: 10}]}]
        }
      }
    ' <<<"$settings")
  elif [[ "$channels" == "discord" ]]; then
    settings=$(jq '. + {enabledPlugins: {"discord@claude-plugins-official": true}}' <<<"$settings")
  fi

  printf '%s\n' "$settings" | sudo -u "$user" tee "$home/.claude/settings.json" >/dev/null
  chmod 600 "$home/.claude/settings.json"

  # Telegram agents get the notify-user skill so claude knows how to ping the
  # paired chat with progress/completion/option-prompt messages.
  if [[ "$channels" == "telegram" && -f "$AGENT_SKILLS_DIR/notify-user/SKILL.md" ]]; then
    sudo -u "$user" mkdir -p "$home/.claude/skills/notify-user"
    sudo -u "$user" cp "$AGENT_SKILLS_DIR/notify-user/SKILL.md" \
      "$home/.claude/skills/notify-user/SKILL.md"
  fi

  # Telegram agents also get a per-agent CLAUDE.md fragment carrying the
  # reply mandate + AskUserQuestion/ExitPlanMode warning. Lands at
  # $HOME/.claude/CLAUDE.md — claude reads it on session start alongside
  # the shared projects-level CLAUDE.md. Best-effort: warn (don't fail)
  # if the installer hasn't placed the source file, since the agent boots
  # fine without it.
  if [[ "$channels" == "telegram" ]]; then
    if [[ -f "$TELEGRAM_AGENT_CLAUDE_MD" ]]; then
      sudo -u "$user" cp "$TELEGRAM_AGENT_CLAUDE_MD" "$home/.claude/CLAUDE.md"
      chmod 644 "$home/.claude/CLAUDE.md"
    else
      warn "$TELEGRAM_AGENT_CLAUDE_MD missing — per-agent telegram CLAUDE.md not wired (run: curl -fsSL https://raw.githubusercontent.com/5dive-com/5dive/main/install.sh | sudo bash)"
    fi
  fi

  # Default skills, best-effort: if npx isn't reachable yet (cold box, no network)
  # the agent still boots; users can re-trigger via the dashboard's Skills block.
  #   find-skills — search skills.sh and self-install additional skills on demand
  #   5dive-cli   — spawn sub-agents on this VM via the local 5dive CLI
  install_default_skill_for_agent "$name" claude vercel-labs/skills find-skills || true
  install_default_skill_for_agent "$name" claude 5dive-com/skills 5dive-cli || true
}

# Install one skill into an agent user's per-type skills dir via npx. Looks
# up SKILLS_AGENT_ID[$type] for `--agent <id>` and SKILLS_INSTALL_DIR[$type]
# for the post-install dir-presence check. Idempotent: skips if the target
# dir already exists. Returns non-zero on any failure so callers can decide
# whether to fail loudly or warn.
install_default_skill_for_agent() {
  local name="$1" type="$2" source="$3" skill="$4"
  local user="agent-${name}" home="/home/agent-${name}"
  local agent_id="${SKILLS_AGENT_ID[$type]:-claude-code}"
  local install_dir="${SKILLS_INSTALL_DIR[$type]:-.claude/skills}"
  [[ -d "$home" ]] || return 1
  id -u "$user" &>/dev/null || return 1
  if sudo -u "$user" test -d "$home/$install_dir/$skill"; then
    return 0
  fi
  sudo -u "$user" -H env SOURCE="$source" SKILL="$skill" AGENT_ID="$agent_id" bash -s >&2 <<'DEFAULT_SKILL' \
    || { warn "default skill '$skill' install failed for agent '$name' (continuing)"; return 1; }
set -uo pipefail
unset CLAUDE_CONFIG_DIR
export NVM_DIR="/home/claude/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/home/claude/.local/bin:$PATH"
cd "$HOME"
timeout 180 npx -y skills add "https://github.com/$SOURCE" --skill "$SKILL" --agent "$AGENT_ID" --yes 2>&1 | tail -15
DEFAULT_SKILL
}

# Install a claude-plugins-official channel plugin into the agent user's
# $HOME/.claude/plugins so the bun server can start first-try. Mirrors the
# channel-user setup in scripts/install/services.sh — registers the marketplace,
# installs the plugin, then npm-installs its deps and patches the start script
# (bun install stalls on a fresh box). Each agent user has its own ~/.claude:
# this function runs with CLAUDE_CONFIG_DIR unset (non-login shell), and at
# runtime 5dive-agent-start.sh also unsets it so the preseed is what claude
# reads. <plugin> is the plugin slug (telegram | discord).
install_channel_plugin_for_agent() {
  local plugin="$1" name="$2" allowed_users="${3:-}"
  local user="agent-${name}"
  id -u "$user" &>/dev/null || fail "$E_GENERIC" "agent user missing: $user"

  # Runtime precheck: the plugin is started with `bun server.ts`, so without
  # bun on the agent user's PATH the service would spin up, crash, and be
  # restarted by systemd — visible only in journalctl. Fail fast with a
  # message the frontend can show instead. Mirror 5dive-agent-start.sh by
  # sourcing nvm + shared profile the way the runtime shell does.
  if ! sudo -u "$user" -i bash -lc 'command -v bun' >/dev/null 2>&1; then
    fail "$E_NOT_INSTALLED" \
      "bun not on PATH for $user (required by $plugin plugin). Run: sudo 5dive doctor --repair"
  fi

  # Pick the marketplace per plugin. Telegram lives on our 5dive-plugins
  # fork (bundled hooks + richer commands); discord stays upstream until
  # we fork it too. Other plugins default to upstream.
  local marketplace="claude-plugins-official"
  # Full HTTPS URL — `claude plugin marketplace add` resolves the
  # GitHub shorthand `owner/repo` to git@github.com (SSH) on at least
  # some claude versions, which fails on agent-<name> users with no
  # SSH key configured. Explicit https URL sidesteps the shorthand
  # resolver entirely.
  local mkt_repo="https://github.com/anthropics/claude-plugins-official.git"
  if [[ "$plugin" == "telegram" ]]; then
    marketplace="5dive-plugins"
    mkt_repo="https://github.com/5dive-com/5dive-plugins.git"
  fi

  step "Installing $plugin plugin for $user (from $marketplace)"
  # Deliberately NOT a login shell: /etc/profile.d/5dive-shared-configs.sh
  # exports CLAUDE_CONFIG_DIR=/home/claude/.claude, which would cause
  # `claude plugin install` to land the plugin in the wrong home. Mirror
  # 5dive-agent-start.sh and source nvm manually instead.
  #
  # set -e + pipefail: without pipefail, `npm install | tail -5` masked
  # npm's exit code with tail's zero-exit and the agent would ship with
  # half-installed deps; surface the failure so the frontend can show it.
  if ! sudo -u "$user" -H env PLUGIN="$plugin" MARKETPLACE="$marketplace" MKT_REPO="$mkt_repo" bash -s >&2 <<'AGENT_PLUGIN_INSTALL'
set -euo pipefail
unset CLAUDE_CONFIG_DIR
export NVM_DIR="/home/claude/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/home/claude/.local/bin:$PATH"
CLAUDE=/home/claude/.local/bin/claude

"$CLAUDE" plugin marketplace update "$MARKETPLACE" 2>/dev/null \
  || "$CLAUDE" plugin marketplace add "$MKT_REPO"

yes | "$CLAUDE" plugin install "${PLUGIN}@${MARKETPLACE}" >/dev/null || true

PLUGIN_DIR=$(PLUGIN="$PLUGIN" MARKETPLACE="$MARKETPLACE" python3 -c '
import json, os
try:
    plugin = os.environ["PLUGIN"]
    marketplace = os.environ["MARKETPLACE"]
    d = json.load(open(os.path.expanduser("~/.claude/plugins/installed_plugins.json")))
    p = d.get("plugins", {}).get(f"{plugin}@{marketplace}", [])
    print(p[0]["installPath"] if p else "")
except Exception:
    print("")
' 2>/dev/null) || PLUGIN_DIR=""
[ -z "$PLUGIN_DIR" ] && PLUGIN_DIR=$(find "$HOME/.claude/plugins/cache" -name package.json -path "*/${PLUGIN}/*" 2>/dev/null | head -1 | xargs -r dirname)

if [ -z "$PLUGIN_DIR" ] || [ ! -d "$PLUGIN_DIR" ]; then
  echo "    ERROR: ${PLUGIN} plugin dir not found after install" >&2
  exit 1
fi

echo "    Plugin dir: $PLUGIN_DIR"
cd "$PLUGIN_DIR"
# tail keeps output bounded; pipefail above carries npm's real exit code.
timeout 60 npm install --omit=dev --ignore-scripts --no-audit --no-fund 2>&1 | tail -5

python3 <<'PATCHPY'
import json
with open("package.json") as f:
    d = json.load(f)
start = d.get("scripts", {}).get("start", "")
if "bun install" in start:
    d["scripts"]["start"] = "bun server.ts"
    with open("package.json", "w") as f:
        json.dump(d, f, indent=2)
    print("    Patched start script: removed bun install")
else:
    print("    Start script already clean: " + start)
PATCHPY
AGENT_PLUGIN_INSTALL
  then
    fail "$E_GENERIC" \
      "$plugin plugin install failed for agent '$name' (see journalctl / stderr above). Run: sudo 5dive doctor"
  fi

  # Pre-seed access.json with the operator's user id so the agent is usable on
  # the first DM. The plugin only writes access.json lazily — on the first
  # inbound message — so without this the wizard's post-create `agent pair
  # --user-id` could race the plugin: legacy pair waited up to 90s for the
  # file to exist, but if no second DM arrives the file never materializes
  # and pair times out. Pre-seeding here (before systemctl enable --now in
  # cmd_create) means the plugin reads our allowFrom on first message and
  # the queued DM goes straight to claude. The welcome DM stays in cmd_pair
  # so the dashboard's post-create `agent pair --user-id` is the single
  # welcome-delivery point on both old and new CLIs.
  if [[ "$plugin" == "telegram" && -n "$allowed_users" ]]; then
    seed_telegram_access_allowlist "$name" "$allowed_users"
  fi
}

# Write ~/.claude/channels/telegram/access.json for agent-<name> with allowFrom
# seeded from a CSV of user ids. Idempotent — merges into an existing file
# rather than clobbering, so re-running on an already-paired agent only adds
# new ids. Doesn't drop approved/<id> markers — that file is the trigger for
# the plugin's checkApprovals "Paired! Say hi to Claude." DM, and a fresh
# create that's about to be followed by `agent pair --user-id` already gets
# that path through the pair call. Doubling up here would duplicate the
# confirmation message.
seed_telegram_access_allowlist() {
  local name="$1" allowed_users="$2"
  local user="agent-${name}"
  local state_dir="/home/${user}/.claude/channels/telegram"

  step "Pre-seeding telegram allowlist for $user (${allowed_users})"
  if ! sudo -u "$user" env CSV="$allowed_users" STATE="$state_dir" python3 - <<'PY' >&2; then
import json, os, tempfile

state = os.environ['STATE']
csv = os.environ['CSV']
ids = [s.strip() for s in csv.split(',') if s.strip()]

os.makedirs(state, mode=0o700, exist_ok=True)
access_path = os.path.join(state, 'access.json')

try:
    with open(access_path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {"dmPolicy": "pairing", "allowFrom": [], "groups": {}, "pending": {}}

allow = list(data.get('allowFrom') or [])
for s in ids:
    if s not in allow:
        allow.append(s)
data['allowFrom'] = allow

fd, tmp = tempfile.mkstemp(dir=state, prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2)
os.replace(tmp, access_path)
print(f"Seeded allowFrom={allow} into {access_path}")
PY
    fail "$E_GENERIC" "telegram access.json pre-seed failed for agent '$name'"
  fi
}

# Back-compat shim so callers that still reference the telegram-specific name
# keep working. New code should call install_channel_plugin_for_agent directly.
install_telegram_plugin_for_agent() {
  install_channel_plugin_for_agent telegram "$1"
}

# Register a chat channel with openclaw's gateway for an agent user. openclaw
# stores the credential under $HOME/.openclaw/...; we just shell out to its
# native CLI (`openclaw channels add`) so future openclaw versions keep
# control of the on-disk schema. Token is passed via --token-file pointing
# at a stable secrets/<plugin>-bot-token file (mode 600), since openclaw
# re-reads the path every time the gateway restarts — a tmpfile would leave
# the gateway with a dangling reference. Pair-code roundtrips don't apply —
# openclaw does inbound DM approvals through its `pairing` subcommand
# instead, which the dashboard can wire up later. <plugin> is telegram |
# discord.
install_channel_for_openclaw_agent() {
  local plugin="$1" name="$2" token="$3" home_channel="${4:-}" allowed_users="${5:-}"
  local user="agent-${name}"
  id -u "$user" &>/dev/null || fail "$E_GENERIC" "agent user missing: $user"
  [[ -n "$token" ]] || fail "$E_VALIDATION" "openclaw $plugin channel requires a bot token"

  # Pre-seed the allowlist + command-owner list from the dashboard wizard's
  # --telegram-allowed-users so the agent is usable immediately on first DM.
  # Without this, openclaw's default `dmPolicy: "pairing"` makes the bot
  # demand `openclaw pairing approve telegram <code>` from the user before
  # any message reaches the agent — which is what `5dive agent pair` solves
  # for claude agents but doesn't apply to openclaw (its native `pairing`
  # subcommand operates on codes the user has already DM'd in, so it can't
  # pre-authorize). The dashboard already collects the user's numeric id
  # via @userinfobot, so we just write it into the right two slots:
  #   channels.<plugin>.allowFrom  → bypasses the pairing reply gate
  #   commands.ownerAllowFrom      → grants command-owner status
  # Same JSON state `openclaw pairing approve` ends up in, just without the
  # roundtrip. Only telegram is wired up — discord uses different shapes.
  local allow_from_json="" owner_allow_from_json=""
  if [[ "$plugin" == "telegram" && -n "$allowed_users" ]]; then
    valid_telegram_chat_id_list "$allowed_users" \
      || fail "$E_VALIDATION" "invalid allowed_users (comma-separated numeric ids)"
    allow_from_json=$(jq -cn --arg csv "$allowed_users" \
      '$csv | split(",") | map(select(length>0))')
    owner_allow_from_json=$(jq -cn --arg csv "$allowed_users" \
      '$csv | split(",") | map(select(length>0) | "telegram:" + .)')
  fi

  step "Registering $plugin channel with openclaw for $user"
  if ! sudo -u "$user" -H env \
      PLUGIN="$plugin" \
      TOKEN="$token" \
      ALLOW_FROM_JSON="$allow_from_json" \
      OWNER_ALLOW_FROM_JSON="$owner_allow_from_json" \
      bash -s >&2 <<'OPENCLAW_CHANNEL'
set -euo pipefail
export NVM_DIR="/home/claude/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/home/claude/.local/bin:$PATH"
OPENCLAW=/home/claude/.local/bin/openclaw

# `openclaw channels add --token-file` records the path inside openclaw.json
# and re-reads it whenever the gateway boots — so the token file has to
# survive past this script. Use a stable, mode-700 dir under the agent's
# home; tmpfile-with-trap-rm would silently strand the gateway on first
# restart with "ENOENT".
SECRET_DIR="$HOME/.openclaw/secrets"
install -d -m 700 "$SECRET_DIR"
TOKEN_FILE="$SECRET_DIR/${PLUGIN}-bot-token"
umask 077
printf '%s' "$TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

# openclaw refuses to start the gateway when gateway.mode is unset (its
# "suspicious or clobbered config" guard), so set it explicitly. `local`
# matches the binding the agent uses (loopback on 127.0.0.1:18789).
"$OPENCLAW" config set gateway.mode local 2>&1 | tail -3

# `openclaw channels add` is idempotent — re-running with the same channel/
# account just updates the stored token, which is what we want when an agent
# rotates its bot.
"$OPENCLAW" channels add --channel "$PLUGIN" --token-file "$TOKEN_FILE" 2>&1 | tail -10

# Auto-pair: if the dashboard supplied a Telegram allowlist, patch the
# config in a single validated write. `config patch` is recursive-merge for
# objects + replace for arrays, so this both seeds new fields and overwrites
# stale lists (e.g. when the agent is recreated with a different operator).
if [[ -n "$ALLOW_FROM_JSON" ]]; then
  PATCH=$(ALLOW_FROM="$ALLOW_FROM_JSON" OWNER_ALLOW_FROM="$OWNER_ALLOW_FROM_JSON" \
    PLUGIN="$PLUGIN" python3 -c '
import json, os
patch = {
  "channels": { os.environ["PLUGIN"]: { "allowFrom": json.loads(os.environ["ALLOW_FROM"]) } },
  "commands": { "ownerAllowFrom": json.loads(os.environ["OWNER_ALLOW_FROM"]) },
}
print(json.dumps(patch))
')
  printf '%s' "$PATCH" | "$OPENCLAW" config patch --stdin 2>&1 | tail -5
fi
OPENCLAW_CHANNEL
  then
    fail "$E_GENERIC" \
      "openclaw $plugin channel registration failed for agent '$name'. Try: sudo -u $user openclaw channels add --channel $plugin --token-file <path>"
  fi
}

# Configure a chat channel for a hermes agent. Unlike openclaw, hermes has no
# non-interactive `channels add` — its messaging gateway reads credentials
# from $HOME/.hermes/.env (TELEGRAM_BOT_TOKEN / DISCORD_BOT_TOKEN), so we
# write the env var directly. We strip any prior assignment of the same key
# so re-creating an agent with a rotated token doesn't leave a stale line.
#
# For telegram, hermes also needs TELEGRAM_HOME_CHANNEL (the chat the gateway
# posts unsolicited messages to) and TELEGRAM_ALLOWED_USERS (the comma-
# separated allowlist of inbound senders) — without those the gateway starts
# but ignores every incoming message. Both are passed in as the same numeric
# user id from the dashboard wizard (the user pastes their own Telegram id,
# fetched from @userinfobot), but we keep them as separate args so a future
# multi-user flow can fan out the allowlist without touching the home
# channel.
install_channel_for_hermes_agent() {
  local plugin="$1" name="$2" token="$3" home_channel="${4:-}" allowed_users="${5:-}"
  local user="agent-${name}"
  id -u "$user" &>/dev/null || fail "$E_GENERIC" "agent user missing: $user"
  [[ -n "$token" ]] || fail "$E_VALIDATION" "hermes $plugin channel requires a bot token"

  local var
  case "$plugin" in
    telegram) var="TELEGRAM_BOT_TOKEN" ;;
    discord)  var="DISCORD_BOT_TOKEN"  ;;
    *) fail "$E_VALIDATION" "hermes channel plugin unsupported: $plugin" ;;
  esac

  # Build the (var,value) pairs to upsert. Always include the bot token; for
  # telegram, also include home_channel/allowed_users when supplied so a
  # missing dashboard arg doesn't silently wipe a previously-set value (we
  # strip-then-append per VAR, so omitted vars are left intact).
  local -a pairs=( "$var=$token" )
  if [[ "$plugin" == "telegram" ]]; then
    [[ -n "$home_channel"  ]] && pairs+=( "TELEGRAM_HOME_CHANNEL=$home_channel" )
    [[ -n "$allowed_users" ]] && pairs+=( "TELEGRAM_ALLOWED_USERS=$allowed_users" )
  fi

  step "Writing $plugin credential into ~/.hermes/.env for $user"
  if ! sudo -u "$user" -H env PAIRS="$(printf '%s\n' "${pairs[@]}")" bash -s >&2 <<'HERMES_ENV'
set -euo pipefail
ENV_FILE="$HOME/.hermes/.env"
mkdir -p "$HOME/.hermes"
chmod 700 "$HOME/.hermes"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"
# Build a tmpfile that drops every VAR we're about to set, then appends the
# fresh assignments. tmpfile + mv so a crash mid-write can't blank the env.
TMP=$(mktemp --tmpdir="$HOME/.hermes" .env.XXXXXX)
chmod 600 "$TMP"
cp "$ENV_FILE" "$TMP"
while IFS= read -r pair; do
  [[ -z "$pair" ]] && continue
  key="${pair%%=*}"
  grep -v "^${key}=" "$TMP" > "$TMP.next" || true
  mv "$TMP.next" "$TMP"
  printf '%s\n' "$pair" >> "$TMP"
done <<< "$PAIRS"
mv "$TMP" "$ENV_FILE"
HERMES_ENV
  then
    fail "$E_GENERIC" \
      "hermes $plugin env write failed for agent '$name'."
  fi
}

# Idempotently install + start the hermes messaging gateway for agent-<name>.
# The gateway is a separate long-running process from the chat CLI and runs
# as `systemctl --user` so it stays owned by agent-<name> and can be
# restarted without touching the 5dive-agent@.service that hosts the tmux
# loop. linger keeps the user bus alive after we exit so the gateway
# survives logout. `gateway install` is idempotent — safe to re-run when
# rotating a token or attaching a channel post-create. Used by cmd_create
# (initial wiring) and cmd_config (post-create channel attach).
ensure_hermes_gateway() {
  local name="$1"
  step "Enabling systemd linger for agent-${name}"
  loginctl enable-linger "agent-${name}" >&2 \
    || warn "loginctl enable-linger failed for agent-${name} — gateway may not survive reboots"
  step "Installing hermes user gateway for agent-${name}"
  sudo -u "agent-${name}" -H "${TYPE_BIN[hermes]}" gateway install >&2 \
    || warn "hermes gateway install failed for agent '$name' (rerun: sudo -u agent-${name} -H ${TYPE_BIN[hermes]} gateway install)"
  sudo -u "agent-${name}" -H "${TYPE_BIN[hermes]}" gateway start >&2 \
    || warn "hermes gateway start failed for agent '$name' (rerun: sudo -u agent-${name} -H ${TYPE_BIN[hermes]} gateway start)"
}

# Upsert a KEY=VALUE pair into agent-${name}'s $HOME/.hermes/.env. Uses the
# same strip-then-append pattern as install_channel_for_hermes_agent so any
# previously-written channel tokens (TELEGRAM_BOT_TOKEN, etc.) are preserved.
# Called from cmd_create for hermes BYO providers whose key lives in .env
# rather than auth.json — Kimi/Moonshot (KIMI_API_KEY) today. The agent user
# must already exist; the gateway daemon (started later in cmd_create) reads
# .env at startup, so this must run before `hermes gateway start`.
seed_hermes_byo_env() {
  local name="$1" var="$2" value="$3"
  local user="agent-${name}"
  id -u "$user" &>/dev/null || fail "$E_GENERIC" "agent user missing: $user"
  if ! sudo -u "$user" -H env PAIR="$var=$value" bash -s >&2 <<'HERMES_BYO_ENV'
set -euo pipefail
ENV_FILE="$HOME/.hermes/.env"
mkdir -p "$HOME/.hermes"
chmod 700 "$HOME/.hermes"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"
TMP=$(mktemp --tmpdir="$HOME/.hermes" .env.XXXXXX)
chmod 600 "$TMP"
cp "$ENV_FILE" "$TMP"
key="${PAIR%%=*}"
grep -v "^${key}=" "$TMP" > "$TMP.next" || true
mv "$TMP.next" "$TMP"
printf '%s\n' "$PAIR" >> "$TMP"
mv "$TMP" "$ENV_FILE"
HERMES_BYO_ENV
  then
    fail "$E_GENERIC" "hermes BYO env write failed for agent '$name' ($var)"
  fi
}

# Single dispatch point used by cmd_create. Routes a (type, plugin) pair to
# the right install helper above, so the create flow stays type-agnostic.
# home_channel/allowed_users are hermes-telegram extras (ignored by other
# routes) — kept as positional so the call site stays uniform.
install_channel_for_agent() {
  local type="$1" plugin="$2" name="$3" token="$4" home_channel="${5:-}" allowed_users="${6:-}"
  case "$type" in
    claude)   install_channel_plugin_for_agent "$plugin" "$name" "$allowed_users" ;;
    openclaw) install_channel_for_openclaw_agent "$plugin" "$name" "$token" "$home_channel" "$allowed_users" ;;
    hermes)   install_channel_for_hermes_agent "$plugin" "$name" "$token" "$home_channel" "$allowed_users" ;;
    *) fail "$E_VALIDATION" "type '$type' does not support channels" ;;
  esac
}
