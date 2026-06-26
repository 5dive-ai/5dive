# Standalone /usr/local/lib/5dive/ hook paths used to be preseeded into
# new-agent settings.json. As of plugin v0.4.4 every lifecycle hook
# (PreToolUse, PostToolUse, Stop, StopFailure) ships inside
# telegram@5dive-plugins/hooks/hooks.json, so new fork agents no longer
# wire any of them — preseeding would double-fire. The standalone files
# stay installed by scripts/install/agent-cli.sh + scripts/update.sh for
# existing-agent backward compatibility (settings.json on pre-fork
# agents still references them); update.sh's on_upstream_telegram() also
# strips them from fork agents that were provisioned before this change.
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
# --- Shared operator allowlist (DIVE-320/325) ---
# A customer's Telegram operator id(s) are the SAME person across their whole
# fleet, so we learn them ONCE (any pairing, or a CoS mint event) and auto-seed
# every new telegram agent's allowFrom — no per-agent pairing step. Per-agent
# customization still happens later via `telegram-access set`. Stored as a JSON
# array of string ids. Best-effort: writes need root (the CLI runs under sudo
# via shelld), and a failure never blocks create/pair.
OPERATOR_STORE="${OPERATOR_STORE:-$STATE_DIR/operator-allow.json}"

_operator_record() {
  local id="${1:-}"
  [[ -n "$id" && "$id" != "0" ]] || return 0
  valid_telegram_chat_id "$id" || return 0
  local cur="[]"
  [[ -r "$OPERATOR_STORE" ]] && cur=$(cat "$OPERATOR_STORE" 2>/dev/null || printf '[]')
  printf '%s' "$cur" | jq -e 'type=="array"' >/dev/null 2>&1 || cur="[]"
  local next
  next=$(jq -c --arg id "$id" '(. + [$id]) | unique' <<<"$cur" 2>/dev/null) || return 0
  ( umask 027; printf '%s\n' "$next" > "$OPERATOR_STORE" ) 2>/dev/null || return 0
  chmod 640 "$OPERATOR_STORE" 2>/dev/null || true
  return 0
}

_operator_ids() {
  [[ -r "$OPERATOR_STORE" ]] || return 0
  jq -r 'if type=="array" and length>0 then map(tostring) | join(",") else empty end' \
    "$OPERATOR_STORE" 2>/dev/null || true
}

preseed_claude_agent() {
  local name="$1" channels="$2"
  local user="agent-${name}" home="/home/agent-${name}"
  [[ -d "$home" ]] || fail "$E_GENERIC" "agent home missing: $home"

  sudo -u "$user" mkdir -p "$home/.claude"

  # ~/.local/bin/claude shim: agents launch via the SHARED binary
  # (/home/claude/.local/bin/claude in 5dive-agent-start), so the agent user
  # has no claude on its own PATH. CC >= 2.1.174 surfaces that as a /doctor
  # "claude command missing or broken" setup warning in every session
  # (DIVE-283). A per-agent symlink satisfies the check AND makes plain
  # `claude` work in agent subshells. Nightly soft-updates backfills
  # existing agents with the same shim.
  sudo -u "$user" mkdir -p "$home/.local/bin"
  sudo -u "$user" ln -sfn /home/claude/.local/bin/claude "$home/.local/bin/claude"

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
  # statusLine points at the shared /usr/local/lib/5dive/statusline.sh (mode
  # 0755, installed by scripts/install/apps.sh + refreshed by update.sh). The
  # main user's /home/claude/.claude/statusline.sh is mode 0600 and not
  # reachable from agent-<name> UIDs. The shared script also tees its input
  # JSON to $HOME/.claude/statusline-last.json so the telegram plugin's
  # /status command can read live 5h/7d rate-limit usage. Omit the key if
  # the file is missing (e.g. host predates the shared-copy rollout) — claude
  # falls back to its built-in statusline.
  local status_line_obj='{}'
  if [[ -x /usr/local/lib/5dive/statusline.sh ]]; then
    status_line_obj='{statusLine: {type: "command", command: "bash /usr/local/lib/5dive/statusline.sh"}}'
  fi
  # model: the FULL resolved id, NOT the bare "opus" alias. CC v2.1.181 ships a
  # one-time startup migration (migrationVersion 13, fires on ANY launch — not
  # just /config) that STRIPS a bare alias model:"opus" from a FRESH config dir,
  # so a new agent would lose its pin on first boot and fall back to the default
  # model. Valid ids (claude-opus-4-8) are left untouched. See DIVE-506.
  local settings
  settings=$(jq -n --argjson sl "$(jq -n "$status_line_obj")" --arg ghorg "$(gh_org)" '{
    model: "claude-opus-4-8",
    effortLevel: "high",
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
        source: {source: "github", repo: "\($ghorg)/5dive-plugins"}
      }
    }
  } + $sl')
  if [[ "$channels" == "telegram" ]]; then
    # 5dive-plugins/telegram (our fork) bundles every lifecycle hook —
    # PreToolUse, PostToolUse, Stop, and (as of plugin v0.4.4) StopFailure
    # too — via its own hooks.json. We don't preseed any of the standalone
    # /usr/local/lib/5dive/ copies into settings.json for new fork agents;
    # doing so would double-fire on the same event.
    settings=$(jq '. + {enabledPlugins: {"telegram@5dive-plugins": true}}' <<<"$settings")
  elif [[ "$channels" == "discord" ]]; then
    settings=$(jq '. + {enabledPlugins: {"discord@claude-plugins-official": true}}' <<<"$settings")
  fi

  # SessionStart resume-context hook (DIVE-726 Phase 0): on every boot, inject
  # the agent's in-flight in_progress task(s) + the latest carryover head, so a
  # service restart / crash / rotation never drops the thread. Core feature —
  # applies to every channel, and no plugin hooks.json defines SessionStart, so
  # there's no double-fire. Guarded on the shared copy existing (installed by
  # install.sh's hook loop + refreshed by update.sh), same pattern as statusLine.
  if [[ -x /usr/local/lib/5dive/sessionstart-resume-context.sh ]]; then
    settings=$(jq '. + {hooks: ((.hooks // {}) + {SessionStart: [{hooks: [{type: "command", command: "/usr/local/lib/5dive/sessionstart-resume-context.sh", timeout: 10}]}]})}' <<<"$settings")
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
      warn "$TELEGRAM_AGENT_CLAUDE_MD missing — per-agent telegram CLAUDE.md not wired (run: curl -fsSL https://raw.githubusercontent.com/$(gh_org)/5dive/main/install.sh | sudo bash)"
    fi
  fi

  # Default skills, best-effort: if npx isn't reachable yet (cold box, no network)
  # the agent still boots; users can re-trigger via the dashboard's Skills block.
  #   find-skills — search skills.sh and self-install additional skills on demand
  #   5dive-cli   — spawn sub-agents on this VM via the local 5dive CLI
  install_default_skill_for_agent "$name" claude vercel-labs/skills find-skills || true
  install_default_skill_for_agent "$name" claude "$(gh_org)/skills" 5dive-cli || true
  install_default_skill_for_agent "$name" claude "$(gh_org)/skills" compile-knowledge || true
  install_default_skill_for_agent "$name" claude "$(gh_org)/skills" openagent || true
}

# Preseed default skills for an antigravity agent. Unlike claude/codex/grok,
# antigravity has no plugin marketplace and no telegram channel installer
# (install_channel_for_agent doesn't route antigravity), so the seed step
# that lives inside channel installers for codex/grok has nowhere to land.
# This runs unconditionally from cmd_create so antigravity gets the same
# find-skills + 5dive-cli inheritance every other type gets. Skills land at
# $HOME/.agents/skills/ (per SKILLS_INSTALL_DIR + agy's own loader path).
preseed_antigravity_agent() {
  local name="$1"
  local home="/home/agent-${name}"
  [[ -d "$home" ]] || fail "$E_GENERIC" "agent home missing: $home"
  install_default_skill_for_agent "$name" antigravity vercel-labs/skills find-skills || true
  install_default_skill_for_agent "$name" antigravity "$(gh_org)/skills" 5dive-cli || true
  install_default_skill_for_agent "$name" antigravity "$(gh_org)/skills" compile-knowledge || true
  install_default_skill_for_agent "$name" antigravity "$(gh_org)/skills" openagent || true
}

# Types that `npx skills add --agent <id>` doesn't recognize. The upstream
# vercel-labs/skills CLI gates --agent against a hardcoded registry; passing
# an unknown id fails with "Invalid agents: <id>" (verified for grok 0.x).
# We fall back to a manual git-clone + cp for these, landing the skill at
# $HOME/${SKILLS_INSTALL_DIR[$type]}/<skill> just like the upstream installer
# would. Add new types here when upstream rejects them.
_skill_needs_manual_install() {
  local type="$1"
  case "$type" in
    grok) return 0 ;;
    *)    return 1 ;;
  esac
}

# Install one skill into an agent user's per-type skills dir. Routes through
# `npx skills add --agent <id>` for upstream-supported types, and falls back
# to a direct git-clone + cp -r for types upstream rejects (see
# _skill_needs_manual_install). Idempotent: skips if the target dir already
# exists. Returns non-zero on any failure so callers can decide whether to
# fail loudly or warn.
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
  if _skill_needs_manual_install "$type"; then
    sudo -u "$user" -H env SOURCE="$source" SKILL="$skill" INSTALL_DIR="$install_dir" bash -s >&2 <<'MANUAL_SKILL' \
      || { warn "default skill '$skill' install failed for agent '$name' (continuing)"; return 1; }
set -uo pipefail
unset CLAUDE_CONFIG_DIR
cd "$HOME"
TMPDIR=$(mktemp -d -t skill-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT
timeout 60 git clone --depth=1 "https://github.com/$SOURCE.git" "$TMPDIR/repo" >/dev/null 2>&1
SRC_DIR=""
for d in "$TMPDIR/repo/$SKILL" "$TMPDIR/repo/skills/$SKILL"; do
  if [ -f "$d/SKILL.md" ]; then SRC_DIR="$d"; break; fi
done
[ -n "$SRC_DIR" ] || { echo "ERROR: skill '$SKILL' not found in $SOURCE (looked at top-level and skills/)" >&2; exit 1; }
mkdir -p "$HOME/$INSTALL_DIR"
cp -r "$SRC_DIR" "$HOME/$INSTALL_DIR/$SKILL"
echo "manual-installed $SKILL → $HOME/$INSTALL_DIR/$SKILL"
MANUAL_SKILL
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
# DIVE-265: self-heal the bun dependency. Managed boxes get bun from
# provisioning (root symlink at /usr/local/bin/bun); a fresh OSS host has
# nothing until `doctor --repair`, so `5dive init` used to die at its first
# telegram agent (caught by lodar testing init, 2026-06-11). Install
# system-wide via BUN_INSTALL=/usr/local — root-owned, world-exec, visible to
# every agent user with zero PATH/profile wiring and no /home/claude traversal
# concerns. Idempotent: returns immediately when the user already sees bun.
ensure_bun_for_agent() {
  local user="$1"
  sudo -u "$user" -i bash -lc 'command -v bun' >/dev/null 2>&1 && return 0
  step "bun missing for $user — installing system-wide (/usr/local/bin/bun)"
  curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash >&2 || true
  sudo -u "$user" -i bash -lc 'command -v bun' >/dev/null 2>&1
}

install_channel_plugin_for_agent() {
  local plugin="$1" name="$2" allowed_users="${3:-}"
  local user="agent-${name}"
  id -u "$user" &>/dev/null || fail "$E_GENERIC" "agent user missing: $user"

  # Runtime precheck: the plugin is started with `bun server.ts`, so without
  # bun on the agent user's PATH the service would spin up, crash, and be
  # restarted by systemd — visible only in journalctl. Fail fast with a
  # message the frontend can show instead. Mirror 5dive-agent-start.sh by
  # sourcing nvm + shared profile the way the runtime shell does.
  if ! ensure_bun_for_agent "$user"; then
    fail "$E_NOT_INSTALLED" \
      "bun unavailable for $user (required by $plugin plugin) and automatic install failed. Check network access to bun.sh, or install bun to /usr/local/bin manually, then retry."
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
    mkt_repo="https://github.com/$(gh_org)/5dive-plugins.git"
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

# `claude plugin marketplace add` crashes headless for a user that has never
# run a claude session (ERR_STREAM_PREMATURE_CLOSE before git even spawns —
# verified on CC 2.1.169 and 2.1.170, DIVE-248). `marketplace update` works
# headless but needs the marketplace registered. So pre-register it ourselves
# (clone + known_marketplaces.json entry) and let `update` take it from there;
# `add` stays only as the fallback for an unforeseen registration shape.
MKT_DIR="$HOME/.claude/plugins/marketplaces/$MARKETPLACE"
if [ ! -d "$MKT_DIR/.git" ]; then
  mkdir -p "$HOME/.claude/plugins/marketplaces"
  rm -rf "$MKT_DIR"
  git clone -q --depth 1 "$MKT_REPO" "$MKT_DIR"
fi
MKT_SLUG=$(printf '%s' "$MKT_REPO" | sed -e 's#^https://github.com/##' -e 's#\.git$##')
KM_FILE="$HOME/.claude/plugins/known_marketplaces.json" \
  MKT_NAME="$MARKETPLACE" MKT_SLUG="$MKT_SLUG" MKT_DIR="$MKT_DIR" python3 <<'PREREG'
import json, os, datetime
km = os.environ["KM_FILE"]
d = {}
if os.path.exists(km):
    try:
        d = json.load(open(km))
    except Exception:
        d = {}
d.setdefault(os.environ["MKT_NAME"], {
    "source": {"source": "github", "repo": os.environ["MKT_SLUG"]},
    "installLocation": os.environ["MKT_DIR"],
    "lastUpdated": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.000Z"),
})
json.dump(d, open(km, "w"), indent=2)
PREREG

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

# Resolve the telegram-codex plugin checkout. Ordered candidates so this works
# on the 5dive control-plane host (the 5dive-plugins repo checkout) today and
# on customer VMs once install.sh deploys the plugin into /usr/local/lib/5dive.
# Override with TELEGRAM_CODEX_PLUGIN_DIR for offline / test installs. Prints
# the dir on success; returns 1 if none has a server.ts. Kept in sync with the
# identical resolver in 5dive-agent-start (the boot script is standalone, not
# part of this bundle).
codex_plugin_dir() {
  local c
  for c in "${TELEGRAM_CODEX_PLUGIN_DIR:-}" \
           /usr/local/lib/5dive/telegram-codex \
           /home/claude/projects/5dive/5dive-plugins/plugins/telegram-codex; do
    [[ -n "$c" && -f "$c/server.ts" ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# Configure the telegram channel for a codex agent. Codex has no plugin
# marketplace, so unlike claude there's nothing to install per-agent — a single
# shared plugin checkout serves every codex agent (server.ts resolves its state
# dir from the agent's own $HOME via homedir(), so per-agent isolation is
# automatic). Here we just (1) write the bot token into the agent's
# ~/.codex/channels/telegram/.env (the path the MCP server + pair.ts read) and
# (2) seed access.json so the bot answers the operator on the first DM. The MCP
# server + lifecycle hooks are wired into config.toml at boot by
# 5dive-agent-start, which also launches codex with --dangerously-bypass-hook-trust.
install_channel_for_codex_agent() {
  local plugin="$1" name="$2" token="$3" allowed_users="${4:-}"
  local user="agent-${name}"
  id -u "$user" &>/dev/null || fail "$E_GENERIC" "agent user missing: $user"
  [[ "$plugin" == "telegram" ]] \
    || fail "$E_VALIDATION" "codex channel plugin unsupported: $plugin (telegram only)"
  [[ -n "$token" ]] || fail "$E_VALIDATION" "codex telegram channel requires a bot token"
  if [[ -n "$allowed_users" ]]; then
    valid_telegram_chat_id_list "$allowed_users" \
      || fail "$E_VALIDATION" "invalid allowed_users (comma-separated numeric ids)"
  fi

  # Fail fast at create time if the plugin isn't deployed — otherwise
  # 5dive-agent-start would boot the agent with no telegram bridge wired and
  # the failure would only surface in journalctl.
  codex_plugin_dir >/dev/null \
    || fail "$E_NOT_INSTALLED" \
       "telegram-codex plugin not found (looked in /usr/local/lib/5dive/telegram-codex and the 5dive-plugins checkout). Set TELEGRAM_CODEX_PLUGIN_DIR or deploy the plugin."

  # bun runs server.ts + the hooks; fail fast like the claude installer does so
  # the frontend can show a clear message instead of a crash loop.
  if ! ensure_bun_for_agent "$user"; then
    fail "$E_NOT_INSTALLED" \
      "bun unavailable for $user (required by telegram-codex) and automatic install failed. Check network access to bun.sh, or install bun to /usr/local/bin manually, then retry."
  fi

  # Write the bot token into ~/.codex/channels/telegram/.env. Strip-then-append
  # the TELEGRAM_BOT_TOKEN line so a rotated token doesn't leave a stale value;
  # tmpfile + mv so a crash mid-write can't blank the file.
  step "Writing telegram token into ~/.codex/channels/telegram/.env for $user"
  if ! sudo -u "$user" -H env TOKEN="$token" bash -s >&2 <<'CODEX_ENV'
set -euo pipefail
mkdir -p "$HOME/.codex/channels/telegram"
chmod 700 "$HOME/.codex" "$HOME/.codex/channels" "$HOME/.codex/channels/telegram" 2>/dev/null || true
ENV_FILE="$HOME/.codex/channels/telegram/.env"
touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
TMP=$(mktemp --tmpdir="$HOME/.codex/channels/telegram" .env.XXXXXX); chmod 600 "$TMP"
grep -v '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" > "$TMP" || true
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" >> "$TMP"
mv "$TMP" "$ENV_FILE"
CODEX_ENV
  then
    fail "$E_GENERIC" "codex telegram .env write failed for agent '$name'"
  fi

  # Seed the allowlist so the operator's DMs reach codex on the first message.
  if [[ -n "$allowed_users" ]]; then
    seed_codex_telegram_access "$name" "$allowed_users"
  fi

  # Seed the notify-user skill into ~/.codex/.agents/skills so the agent
  # self-starts its comms loop on the first DM. Mirrors the grok 0.1.13 block
  # below — codex has no plugin marketplace either, but it reads SKILL.md
  # from its per-type skills dir natively. Without this, new codex+telegram
  # agents go dark on first contact until the operator manually copies SKILL.md
  # (or waits for update.sh's 03:00 type-aware refresh to heal them).
  if [[ -f "$AGENT_SKILLS_DIR/notify-user/SKILL.md" ]]; then
    sudo -u "$user" mkdir -p "/home/${user}/.agents/skills/notify-user"
    sudo -u "$user" cp "$AGENT_SKILLS_DIR/notify-user/SKILL.md" \
      "/home/${user}/.agents/skills/notify-user/SKILL.md"
  fi

  # Default skills, best-effort: match preseed_claude_agent + the grok
  # installer so codex+telegram agents get find-skills + 5dive-cli too.
  # Upstream `npx skills add --agent codex` IS supported (see SKILLS_AGENT_ID),
  # so these route through the normal path, not the manual-install fallback.
  install_default_skill_for_agent "$name" codex vercel-labs/skills find-skills || true
  install_default_skill_for_agent "$name" codex "$(gh_org)/skills" 5dive-cli || true
  install_default_skill_for_agent "$name" codex "$(gh_org)/skills" compile-knowledge || true
  install_default_skill_for_agent "$name" codex "$(gh_org)/skills" openagent || true
}

# Write ~/.codex/channels/telegram/access.json for agent-<name> with allowFrom
# seeded from a CSV of user ids. Idempotent — merges into an existing file so
# re-running only adds new ids. Matches the {allowFrom, groups} schema the codex
# server + pair.ts use (allowFrom is an array of string ids).
seed_codex_telegram_access() {
  local name="$1" allowed_users="$2"
  local user="agent-${name}"
  step "Pre-seeding codex telegram allowlist for $user (${allowed_users})"
  if ! sudo -u "$user" env CSV="$allowed_users" python3 - <<'PY' >&2; then
import json, os, tempfile

state = os.path.join(os.path.expanduser('~'), '.codex', 'channels', 'telegram')
os.makedirs(state, mode=0o700, exist_ok=True)
access_path = os.path.join(state, 'access.json')
ids = [s.strip() for s in os.environ['CSV'].split(',') if s.strip()]

try:
    with open(access_path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {"allowFrom": [], "groups": {}}

allow = list(data.get('allowFrom') or [])
for s in ids:
    if s not in allow:
        allow.append(s)
data['allowFrom'] = allow
data.setdefault('groups', {})

fd, tmp = tempfile.mkstemp(dir=state, prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, access_path)
print(f"Seeded allowFrom={allow} into {access_path}")
PY
    fail "$E_GENERIC" "codex telegram access.json pre-seed failed for agent '$name'"
  fi
}

# Resolve the telegram-grok plugin checkout. Same shape as codex_plugin_dir
# above — control-plane host uses the 5dive-plugins repo checkout, customer
# VMs use /usr/local/lib/5dive once install.sh deploys it. Override with
# TELEGRAM_GROK_PLUGIN_DIR for offline / test installs. The matching resolver
# in 5dive-agent-start is intentionally duplicated (the boot script is
# standalone).
grok_plugin_dir() {
  local c
  for c in "${TELEGRAM_GROK_PLUGIN_DIR:-}" \
           /usr/local/lib/5dive/telegram-grok \
           /home/claude/projects/5dive/5dive-plugins/plugins/telegram-grok; do
    [[ -n "$c" && -f "$c/server.ts" ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# Configure the telegram channel for a grok agent. Structurally identical to
# install_channel_for_codex_agent — grok has no plugin marketplace, so a single
# shared plugin checkout serves every grok agent (server.ts resolves its state
# dir from the agent's own $HOME via homedir()). We (1) write the bot token
# into ~/.grok/channels/telegram/.env and (2) seed access.json. The MCP server
# + lifecycle hooks are wired into ~/.grok/config.toml at boot by
# 5dive-agent-start. grok runs with --always-approve, which also auto-trusts
# plugin/MCP commands — no separate trust-bypass flag needed.
install_channel_for_grok_agent() {
  local plugin="$1" name="$2" token="$3" allowed_users="${4:-}"
  local user="agent-${name}"
  id -u "$user" &>/dev/null || fail "$E_GENERIC" "agent user missing: $user"
  [[ "$plugin" == "telegram" ]] \
    || fail "$E_VALIDATION" "grok channel plugin unsupported: $plugin (telegram only)"
  [[ -n "$token" ]] || fail "$E_VALIDATION" "grok telegram channel requires a bot token"
  if [[ -n "$allowed_users" ]]; then
    valid_telegram_chat_id_list "$allowed_users" \
      || fail "$E_VALIDATION" "invalid allowed_users (comma-separated numeric ids)"
  fi

  grok_plugin_dir >/dev/null \
    || fail "$E_NOT_INSTALLED" \
       "telegram-grok plugin not found (looked in /usr/local/lib/5dive/telegram-grok and the 5dive-plugins checkout). Set TELEGRAM_GROK_PLUGIN_DIR or deploy the plugin."

  if ! ensure_bun_for_agent "$user"; then
    fail "$E_NOT_INSTALLED" \
      "bun unavailable for $user (required by telegram-grok) and automatic install failed. Check network access to bun.sh, or install bun to /usr/local/bin manually, then retry."
  fi

  step "Writing telegram token into ~/.grok/channels/telegram/.env for $user"
  if ! sudo -u "$user" -H env TOKEN="$token" bash -s >&2 <<'GROK_ENV'
set -euo pipefail
mkdir -p "$HOME/.grok/channels/telegram"
chmod 700 "$HOME/.grok" "$HOME/.grok/channels" "$HOME/.grok/channels/telegram" 2>/dev/null || true
ENV_FILE="$HOME/.grok/channels/telegram/.env"
touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
TMP=$(mktemp --tmpdir="$HOME/.grok/channels/telegram" .env.XXXXXX); chmod 600 "$TMP"
grep -v '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" > "$TMP" || true
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" >> "$TMP"
mv "$TMP" "$ENV_FILE"
GROK_ENV
  then
    fail "$E_GENERIC" "grok telegram .env write failed for agent '$name'"
  fi

  if [[ -n "$allowed_users" ]]; then
    seed_grok_telegram_access "$name" "$allowed_users"
  fi

  # Seed the notify-user skill into ~/.grok/skills so the agent self-starts
  # its comms loop on first DM. Mirrors what preseed_claude_agent does for
  # claude-channel=telegram agents; grok has no claude-style plugin marketplace,
  # but it does read ~/.grok/skills/*/SKILL.md natively, so a direct copy is
  # all that's needed.
  if [[ -f "$AGENT_SKILLS_DIR/notify-user/SKILL.md" ]]; then
    sudo -u "$user" mkdir -p "/home/${user}/.grok/skills/notify-user"
    sudo -u "$user" cp "$AGENT_SKILLS_DIR/notify-user/SKILL.md" \
      "/home/${user}/.grok/skills/notify-user/SKILL.md"
  fi

  # Default skills, best-effort: match the claude-side install in
  # preseed_claude_agent so grok agents get find-skills + 5dive-cli too.
  # Upstream `npx skills add` doesn't recognize --agent grok, so these
  # route through the manual-install fallback in install_default_skill_for_agent.
  install_default_skill_for_agent "$name" grok vercel-labs/skills find-skills || true
  install_default_skill_for_agent "$name" grok "$(gh_org)/skills" 5dive-cli || true
  install_default_skill_for_agent "$name" grok "$(gh_org)/skills" compile-knowledge || true
  install_default_skill_for_agent "$name" grok "$(gh_org)/skills" openagent || true
}

# Write ~/.grok/channels/telegram/access.json for agent-<name> with allowFrom
# seeded from a CSV of user ids. Idempotent — mirrors seed_codex_telegram_access.
seed_grok_telegram_access() {
  local name="$1" allowed_users="$2"
  local user="agent-${name}"
  step "Pre-seeding grok telegram allowlist for $user (${allowed_users})"
  if ! sudo -u "$user" env CSV="$allowed_users" python3 - <<'PY' >&2; then
import json, os, tempfile

state = os.path.join(os.path.expanduser('~'), '.grok', 'channels', 'telegram')
os.makedirs(state, mode=0o700, exist_ok=True)
access_path = os.path.join(state, 'access.json')
ids = [s.strip() for s in os.environ['CSV'].split(',') if s.strip()]

try:
    with open(access_path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {"allowFrom": [], "groups": {}}

allow = list(data.get('allowFrom') or [])
for s in ids:
    if s not in allow:
        allow.append(s)
data['allowFrom'] = allow
data.setdefault('groups', {})

fd, tmp = tempfile.mkstemp(dir=state, prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, access_path)
print(f"Seeded allowFrom={allow} into {access_path}")
PY
    fail "$E_GENERIC" "grok telegram access.json pre-seed failed for agent '$name'"
  fi
}

# Resolve the telegram-agy plugin checkout. Same shape as grok_plugin_dir
# above — control-plane host uses the 5dive-plugins repo checkout, customer
# VMs use /usr/local/lib/5dive once install.sh deploys it. Override with
# TELEGRAM_AGY_PLUGIN_DIR for offline / test installs. The matching resolver
# in 5dive-agent-start is intentionally duplicated (the boot script is
# standalone).
antigravity_plugin_dir() {
  local c
  for c in "${TELEGRAM_AGY_PLUGIN_DIR:-}" \
           /usr/local/lib/5dive/telegram-agy \
           /home/claude/projects/5dive/5dive-plugins/plugins/telegram-agy; do
    [[ -n "$c" && -f "$c/server.ts" ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# Configure the telegram channel for an antigravity (agy) agent. Structurally
# identical to install_channel_for_grok_agent — agy has no plugin marketplace,
# so a single shared plugin checkout serves every agy agent (server.ts resolves
# its state dir from the agent's own $HOME via homedir() → ~/.gemini/channels/
# telegram). We (1) write the bot token into ~/.gemini/channels/telegram/.env
# and (2) seed access.json. The MCP server + lifecycle hooks are wired into the
# GLOBAL ~/.gemini/config/{mcp_config.json,hooks.json} at boot by
# 5dive-agent-start (agy doesn't auto-load a plugin's mcp_config/hooks — only
# skills/agents). agy runs with --dangerously-skip-permissions (set in
# 5dive-agent-start), so there are no tool prompts to bridge.
install_channel_for_antigravity_agent() {
  local plugin="$1" name="$2" token="$3" allowed_users="${4:-}"
  local user="agent-${name}"
  id -u "$user" &>/dev/null || fail "$E_GENERIC" "agent user missing: $user"
  [[ "$plugin" == "telegram" ]] \
    || fail "$E_VALIDATION" "antigravity channel plugin unsupported: $plugin (telegram only)"
  [[ -n "$token" ]] || fail "$E_VALIDATION" "antigravity telegram channel requires a bot token"
  if [[ -n "$allowed_users" ]]; then
    valid_telegram_chat_id_list "$allowed_users" \
      || fail "$E_VALIDATION" "invalid allowed_users (comma-separated numeric ids)"
  fi

  antigravity_plugin_dir >/dev/null \
    || fail "$E_NOT_INSTALLED" \
       "telegram-agy plugin not found (looked in /usr/local/lib/5dive/telegram-agy and the 5dive-plugins checkout). Set TELEGRAM_AGY_PLUGIN_DIR or deploy the plugin."

  if ! ensure_bun_for_agent "$user"; then
    fail "$E_NOT_INSTALLED" \
      "bun unavailable for $user (required by telegram-agy) and automatic install failed. Check network access to bun.sh, or install bun to /usr/local/bin manually, then retry."
  fi

  step "Writing telegram token into ~/.gemini/channels/telegram/.env for $user"
  if ! sudo -u "$user" -H env TOKEN="$token" bash -s >&2 <<'AGY_ENV'
set -euo pipefail
mkdir -p "$HOME/.gemini/channels/telegram"
chmod 700 "$HOME/.gemini" "$HOME/.gemini/channels" "$HOME/.gemini/channels/telegram" 2>/dev/null || true
ENV_FILE="$HOME/.gemini/channels/telegram/.env"
touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
TMP=$(mktemp --tmpdir="$HOME/.gemini/channels/telegram" .env.XXXXXX); chmod 600 "$TMP"
grep -v '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" > "$TMP" || true
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" >> "$TMP"
mv "$TMP" "$ENV_FILE"
AGY_ENV
  then
    fail "$E_GENERIC" "antigravity telegram .env write failed for agent '$name'"
  fi

  if [[ -n "$allowed_users" ]]; then
    seed_antigravity_telegram_access "$name" "$allowed_users"
  fi

  # Seed the notify-user skill into agy's skills dir so the agent self-starts
  # its comms loop on first DM. Mirrors the grok path; agy reads skills from
  # $HOME/.agents/skills/<name>/SKILL.md (per SKILLS_INSTALL_DIR[antigravity]).
  if [[ -f "$AGENT_SKILLS_DIR/notify-user/SKILL.md" ]]; then
    sudo -u "$user" mkdir -p "/home/${user}/.agents/skills/notify-user"
    sudo -u "$user" cp "$AGENT_SKILLS_DIR/notify-user/SKILL.md" \
      "/home/${user}/.agents/skills/notify-user/SKILL.md"
  fi

  # Default skills, best-effort: match the grok-side install so agy agents get
  # find-skills + 5dive-cli too. (preseed_antigravity_agent already runs these
  # from cmd_create; repeating here keeps channel-attach self-contained and the
  # installs are idempotent.)
  install_default_skill_for_agent "$name" antigravity vercel-labs/skills find-skills || true
  install_default_skill_for_agent "$name" antigravity "$(gh_org)/skills" 5dive-cli || true
  install_default_skill_for_agent "$name" antigravity "$(gh_org)/skills" compile-knowledge || true
  install_default_skill_for_agent "$name" antigravity "$(gh_org)/skills" openagent || true
}

# Write ~/.gemini/channels/telegram/access.json for agent-<name> with allowFrom
# seeded from a CSV of user ids. Idempotent — mirrors seed_grok_telegram_access.
seed_antigravity_telegram_access() {
  local name="$1" allowed_users="$2"
  local user="agent-${name}"
  step "Pre-seeding antigravity telegram allowlist for $user (${allowed_users})"
  if ! sudo -u "$user" env CSV="$allowed_users" python3 - <<'PY' >&2; then
import json, os, tempfile

state = os.path.join(os.path.expanduser('~'), '.gemini', 'channels', 'telegram')
os.makedirs(state, mode=0o700, exist_ok=True)
access_path = os.path.join(state, 'access.json')
ids = [s.strip() for s in os.environ['CSV'].split(',') if s.strip()]

try:
    with open(access_path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {"allowFrom": [], "groups": {}}

allow = list(data.get('allowFrom') or [])
for s in ids:
    if s not in allow:
        allow.append(s)
data['allowFrom'] = allow
data.setdefault('groups', {})

fd, tmp = tempfile.mkstemp(dir=state, prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, access_path)
print(f"Seeded allowFrom={allow} into {access_path}")
PY
    fail "$E_GENERIC" "antigravity telegram access.json pre-seed failed for agent '$name'"
  fi
}

# Resolve the telegram-opencode plugin checkout. Same shape as grok_plugin_dir
# above — control-plane host uses the 5dive-plugins repo checkout, customer VMs
# use /usr/local/lib/5dive once install.sh deploys it. Override with
# TELEGRAM_OPENCODE_PLUGIN_DIR for offline / test installs. The matching
# resolver in 5dive-agent-start is intentionally duplicated (the boot script is
# standalone).
opencode_plugin_dir() {
  local c
  for c in "${TELEGRAM_OPENCODE_PLUGIN_DIR:-}" \
           /usr/local/lib/5dive/telegram-opencode \
           /home/claude/projects/5dive/5dive-plugins/plugins/telegram-opencode; do
    [[ -n "$c" && -f "$c/server.ts" ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# Configure the telegram channel for an opencode agent. Unlike codex/grok/agy
# (MCP servers wired into the runtime's config), opencode is a STANDALONE RELAY:
# the bridge (telegram-opencode/server.ts) IS the agent's main process and
# itself spawns `opencode serve` over loopback HTTP — 5dive-agent-start launches
# `bun server.ts` instead of the opencode TUI for channels=telegram. So there's
# no config.toml/MCP wiring here; the installer just (1) writes the bot token
# into ~/.opencode/channels/telegram/.env (the path the relay reads its token
# from) and (2) seeds access.json. A single shared plugin checkout serves every
# opencode agent (the relay resolves its state dir from the agent's own $HOME).
install_channel_for_opencode_agent() {
  local plugin="$1" name="$2" token="$3" allowed_users="${4:-}"
  local user="agent-${name}"
  id -u "$user" &>/dev/null || fail "$E_GENERIC" "agent user missing: $user"
  [[ "$plugin" == "telegram" ]] \
    || fail "$E_VALIDATION" "opencode channel plugin unsupported: $plugin (telegram only)"
  [[ -n "$token" ]] || fail "$E_VALIDATION" "opencode telegram channel requires a bot token"
  if [[ -n "$allowed_users" ]]; then
    valid_telegram_chat_id_list "$allowed_users" \
      || fail "$E_VALIDATION" "invalid allowed_users (comma-separated numeric ids)"
  fi

  opencode_plugin_dir >/dev/null \
    || fail "$E_NOT_INSTALLED" \
       "telegram-opencode plugin not found (looked in /usr/local/lib/5dive/telegram-opencode and the 5dive-plugins checkout). Set TELEGRAM_OPENCODE_PLUGIN_DIR or deploy the plugin."

  # bun runs the relay (server.ts) — it IS the agent process, so a missing bun
  # would crash-loop the unit. Fail fast at create time like the other bridges.
  if ! ensure_bun_for_agent "$user"; then
    fail "$E_NOT_INSTALLED" \
      "bun unavailable for $user (required by telegram-opencode) and automatic install failed. Check network access to bun.sh, or install bun to /usr/local/bin manually, then retry."
  fi

  step "Writing telegram token into ~/.opencode/channels/telegram/.env for $user"
  if ! sudo -u "$user" -H env TOKEN="$token" bash -s >&2 <<'OPENCODE_ENV'
set -euo pipefail
mkdir -p "$HOME/.opencode/channels/telegram"
chmod 700 "$HOME/.opencode" "$HOME/.opencode/channels" "$HOME/.opencode/channels/telegram" 2>/dev/null || true
ENV_FILE="$HOME/.opencode/channels/telegram/.env"
touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
TMP=$(mktemp --tmpdir="$HOME/.opencode/channels/telegram" .env.XXXXXX); chmod 600 "$TMP"
grep -v '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" > "$TMP" || true
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" >> "$TMP"
mv "$TMP" "$ENV_FILE"
OPENCODE_ENV
  then
    fail "$E_GENERIC" "opencode telegram .env write failed for agent '$name'"
  fi

  # Always seed access.json (DIVE-45). The opencode bridge's loadAccess()
  # defaults to {allowFrom:[], dmPolicy:allowlist} when the file is absent —
  # i.e. block-everything — so a freshly-provisioned bot with no access.json
  # SILENTLY DROPS every DM and the customer never gets a reply. seed_* now
  # always writes the file: with allowed_users it allowlists them; without, it
  # defaults dmPolicy to 'pairing' so the first DM yields a pairing code (parity
  # with the claude/codex/grok effective default of pairing-on-first-contact).
  seed_opencode_telegram_access "$name" "$allowed_users"

  # Seed the notify-user skill so the agent self-starts its comms loop on first
  # DM. opencode reads skills from $HOME/.agents/skills/<name>/SKILL.md
  # (SKILLS_INSTALL_DIR[opencode]).
  if [[ -f "$AGENT_SKILLS_DIR/notify-user/SKILL.md" ]]; then
    sudo -u "$user" mkdir -p "/home/${user}/.agents/skills/notify-user"
    sudo -u "$user" cp "$AGENT_SKILLS_DIR/notify-user/SKILL.md" \
      "/home/${user}/.agents/skills/notify-user/SKILL.md"
  fi

  # Default skills, best-effort: match the grok/agy installers. opencode IS in
  # the upstream skills registry (SKILLS_AGENT_ID[opencode]=opencode), so these
  # route through the normal `npx skills add` path.
  install_default_skill_for_agent "$name" opencode vercel-labs/skills find-skills || true
  install_default_skill_for_agent "$name" opencode "$(gh_org)/skills" 5dive-cli || true
  install_default_skill_for_agent "$name" opencode "$(gh_org)/skills" compile-knowledge || true
  install_default_skill_for_agent "$name" opencode "$(gh_org)/skills" openagent || true
}

# Write ~/.opencode/channels/telegram/access.json for agent-<name>. Idempotent —
# mirrors seed_grok_telegram_access, but the opencode bridge's access schema also
# carries dmPolicy + pending (see the telegram-opencode PROVISIONING-CONTRACT
# §3), so we default those too. allowed_users may be empty: we still write the
# file (the bridge block-everything default makes a missing file a silent-DM-drop
# — DIVE-45), defaulting dmPolicy to 'pairing' so the first DM pairs instead of
# being dropped. An existing dmPolicy is never overridden (re-runs / token
# rotation preserve the operator's choice).
seed_opencode_telegram_access() {
  local name="$1" allowed_users="$2"
  local user="agent-${name}"
  if [[ -n "$allowed_users" ]]; then
    step "Seeding opencode telegram access.json for $user (allow ${allowed_users})"
  else
    step "Seeding opencode telegram access.json for $user (dmPolicy=pairing)"
  fi
  if ! sudo -u "$user" env CSV="$allowed_users" python3 - <<'PY' >&2; then
import json, os, tempfile

state = os.path.join(os.path.expanduser('~'), '.opencode', 'channels', 'telegram')
os.makedirs(state, mode=0o700, exist_ok=True)
access_path = os.path.join(state, 'access.json')
ids = [s.strip() for s in os.environ['CSV'].split(',') if s.strip()]

try:
    with open(access_path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}

allow = list(data.get('allowFrom') or [])
for s in ids:
    if s not in allow:
        allow.append(s)
data['allowFrom'] = allow
data.setdefault('groups', {})
data.setdefault('pending', {})
# Never override an explicit dmPolicy (re-run / rotation keeps the operator's
# choice). For a fresh file: allowlist when we have ids to allow, else pairing
# so the first DM yields a pairing code instead of a silent drop.
if 'dmPolicy' not in data:
    data['dmPolicy'] = 'allowlist' if allow else 'pairing'

fd, tmp = tempfile.mkstemp(dir=state, prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, access_path)
print(f"Seeded access.json dmPolicy={data['dmPolicy']} allowFrom={allow} into {access_path}")
PY
    fail "$E_GENERIC" "opencode telegram access.json pre-seed failed for agent '$name'"
  fi
}

# Single dispatch point used by cmd_create. Routes a (type, plugin) pair to
# the right install helper above, so the create flow stays type-agnostic.
# home_channel/allowed_users are hermes-telegram extras (ignored by other
# routes) — kept as positional so the call site stays uniform.
install_channel_for_agent() {
  local type="$1" plugin="$2" name="$3" token="$4" home_channel="${5:-}" allowed_users="${6:-}"
  case "$type" in
    claude)      install_channel_plugin_for_agent "$plugin" "$name" "$allowed_users" ;;
    codex)       install_channel_for_codex_agent "$plugin" "$name" "$token" "$allowed_users" ;;
    grok)        install_channel_for_grok_agent "$plugin" "$name" "$token" "$allowed_users" ;;
    antigravity) install_channel_for_antigravity_agent "$plugin" "$name" "$token" "$allowed_users" ;;
    opencode)    install_channel_for_opencode_agent "$plugin" "$name" "$token" "$allowed_users" ;;
    openclaw)    install_channel_for_openclaw_agent "$plugin" "$name" "$token" "$home_channel" "$allowed_users" ;;
    hermes)      install_channel_for_hermes_agent "$plugin" "$name" "$token" "$home_channel" "$allowed_users" ;;
    *) fail "$E_VALIDATION" "type '$type' does not support channels" ;;
  esac
}
