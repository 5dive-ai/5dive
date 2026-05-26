#!/usr/bin/env bash
# 5dive CLI installer / uninstaller
# Install:   curl -fsSL https://raw.githubusercontent.com/5dive-com/5dive/main/install.sh | sudo bash
# Upgrade:   curl -fsSL https://raw.githubusercontent.com/5dive-com/5dive/main/install.sh | sudo bash -s -- --upgrade
# Uninstall: curl -fsSL https://raw.githubusercontent.com/5dive-com/5dive/main/install.sh | sudo bash -s -- --uninstall
set -euo pipefail

# Source for binaries / hooks / skills. Overridable for offline installs,
# enterprise mirrors, and pre-publish smoke tests (which point this at a
# `file://` bundle of the working tree).
REPO="${REPO:-https://raw.githubusercontent.com/5dive-com/5dive/main}"
BIN_DIR="/usr/local/bin"
STATE_DIR="/var/lib/5dive"
CONNECTORS_DIR="/etc/5dive/connectors"
SYSTEMD_DIR="/etc/systemd/system"
LIB_DIR="/usr/local/lib/5dive"
NODE_VERSION="22"

die() { echo "error: $*" >&2; exit 1; }
ok()  { echo "  ✓ $*"; }
say() { echo "→ $*"; }

[[ $EUID -eq 0 ]] || die "run as root: curl -fsSL ... | sudo bash"

# Refresh CLI binaries, systemd unit, hooks, and skills from $REPO. Shared by
# the default install path and `--upgrade`. Never touches state, auth profiles,
# the claude user, apt packages, nvm, or bun — so it's safe to rerun on a
# populated host.
refresh_managed_files() {
  curl -fsSL "$REPO/5dive" -o "$BIN_DIR/5dive"
  chmod 755 "$BIN_DIR/5dive"
  ok "5dive → $BIN_DIR/5dive"

  curl -fsSL "$REPO/5dive-agent-start" -o "$BIN_DIR/5dive-agent-start"
  chmod 755 "$BIN_DIR/5dive-agent-start"
  ok "5dive-agent-start → $BIN_DIR/5dive-agent-start"

  curl -fsSL "$REPO/systemd/5dive-agent%40.service" -o "$SYSTEMD_DIR/5dive-agent@.service"
  systemctl daemon-reload
  ok "systemd template installed"

  install -d -m 755 "$LIB_DIR" "$LIB_DIR/skills/notify-user"
  # Remove the deprecated sender-side PreToolUse mirror: it read the
  # pre-expansion command string, so it couldn't see heredoc bodies. The
  # receiver-side userprompt-mirror-inter-agent.sh below replaces it.
  rm -f "$LIB_DIR/mirror-agent-send.sh"
  for hook in stop-failure-telegram.sh resume-after-reset.sh \
              pretool-telegram-question.sh stop-telegram-reply-check.sh \
              posttool-telegram-relay.sh userprompt-mirror-inter-agent.sh \
              stop-mirror-inter-agent.sh; do
    curl -fsSL "$REPO/hooks/$hook" -o "$LIB_DIR/$hook"
    chmod 755 "$LIB_DIR/$hook"
    ok "$hook"
  done
  curl -fsSL "$REPO/skills/notify-user/SKILL.md" -o "$LIB_DIR/skills/notify-user/SKILL.md"
  chmod 644 "$LIB_DIR/skills/notify-user/SKILL.md"
  ok "notify-user skill"

  # CLAUDE.md fragment that preseed_claude_agent drops into a telegram-paired
  # agent's $HOME/.claude/ so the per-turn reply mandate + AskUserQuestion /
  # ExitPlanMode warning ride with the agents that actually need them — not
  # the shared projects-level file every agent reads.
  curl -fsSL "$REPO/telegram-agent-CLAUDE.md" -o "$LIB_DIR/telegram-agent-CLAUDE.md"
  chmod 644 "$LIB_DIR/telegram-agent-CLAUDE.md"
  ok "telegram-agent-CLAUDE.md"

  # /etc/claude-code/managed-settings.json — channel-plugin allowlist.
  # Claude reads a default Anthropic-blessed ledger when this file is
  # absent, which permits telegram@claude-plugins-official but NOT our
  # fork. The moment a custom allowlist exists, claude ignores the
  # default ledger entirely — so we list BOTH the 5dive fork and the
  # upstream entry, plus discord upstream. Existing agents pinned to
  # claude-plugins-official keep working; new agents on 5dive-plugins
  # are now allowlisted. Use install -m to preserve the file mode and
  # never clobber a customised entry: skip if the operator already
  # wrote one (e.g. with extra plugins of their own).
  # channelsEnabled: claude code 2.1.150+ requires this flag for any
  # allowedChannelPlugins entry to actually take effect. Without it,
  # the allowlist is silently inert and inbound channel messages
  # don't reach the session.
  install -d -m 755 /etc/claude-code
  if [[ ! -f /etc/claude-code/managed-settings.json ]]; then
    cat > /etc/claude-code/managed-settings.json <<'MANAGED'
{
  "channelsEnabled": true,
  "allowedChannelPlugins": [
    {"plugin": "telegram", "marketplace": "5dive-plugins"},
    {"plugin": "telegram", "marketplace": "claude-plugins-official"},
    {"plugin": "discord", "marketplace": "claude-plugins-official"}
  ]
}
MANAGED
    chmod 644 /etc/claude-code/managed-settings.json
    ok "/etc/claude-code/managed-settings.json (new)"
  else
    ok "/etc/claude-code/managed-settings.json (kept existing)"
  fi

  # Drop a slim projects-level CLAUDE.md so every agent spawned on this host
  # picks up baseline self-management guidance (project layout, sudo, where
  # the agent's own settings live, the host CLI). Only on first install —
  # never clobber a customised file. Symlink AGENTS.md so non-claude agent
  # types (codex, …) see the same instructions.
  install -d -m 755 -o claude -g claude /home/claude/projects
  if [[ ! -f /home/claude/projects/CLAUDE.md ]]; then
    curl -fsSL "$REPO/projects-CLAUDE.md" -o /home/claude/projects/CLAUDE.md
    chown claude:claude /home/claude/projects/CLAUDE.md
    chmod 644 /home/claude/projects/CLAUDE.md
    ok "projects/CLAUDE.md"
  else
    ok "projects/CLAUDE.md (kept existing)"
  fi
  if [[ ! -e /home/claude/projects/AGENTS.md ]]; then
    ln -sfn CLAUDE.md /home/claude/projects/AGENTS.md
    chown -h claude:claude /home/claude/projects/AGENTS.md
  fi
}

# --- Subcommand dispatch ---------------------------------------------------

if [[ "${1:-}" == "--uninstall" ]]; then
  shift
  PURGE=0
  YES=0
  for a in "$@"; do
    case "$a" in
      --purge) PURGE=1 ;;
      --yes|-y) YES=1 ;;
      *) die "unknown uninstall flag: $a" ;;
    esac
  done

  say "Uninstalling 5dive CLI"

  # 1. Stop + remove any running agents — leaves /var/lib/5dive/agents.json
  # consistent so an --upgrade reinstall could restore the registry. With
  # --purge we wipe everything anyway.
  if command -v 5dive >/dev/null 2>&1; then
    if [[ -f "$STATE_DIR/agents.json" ]]; then
      mapfile -t AGENT_NAMES < <(jq -r '.agents | keys[]?' "$STATE_DIR/agents.json" 2>/dev/null || true)
      if [[ ${#AGENT_NAMES[@]} -gt 0 ]]; then
        say "Stopping ${#AGENT_NAMES[@]} agent(s)"
        if [[ $YES -eq 0 ]]; then
          printf "    %s\n" "${AGENT_NAMES[@]}"
          read -r -p "  remove these agents? [y/N] " ans
          [[ "$ans" =~ ^[yY] ]] || die "aborted"
        fi
        for n in "${AGENT_NAMES[@]}"; do
          5dive agent rm "$n" >/dev/null 2>&1 || true
          ok "removed agent $n"
        done
      fi
    fi
  fi

  # 2. systemd template + reload
  if [[ -f "$SYSTEMD_DIR/5dive-agent@.service" ]]; then
    rm -f "$SYSTEMD_DIR/5dive-agent@.service"
    systemctl daemon-reload || true
    ok "removed systemd template"
  fi

  # 3. Binaries + shared libs
  rm -f "$BIN_DIR/5dive" "$BIN_DIR/5dive-agent-start"
  ok "removed CLI binaries"
  if [[ -d "$LIB_DIR" ]]; then
    rm -rf "$LIB_DIR"
    ok "removed $LIB_DIR (hooks, skills, ui)"
  fi

  # 4. State / connector / claude user — keep by default; --purge wipes.
  if [[ $PURGE -eq 1 ]]; then
    if [[ $YES -eq 0 ]]; then
      echo
      echo "  --purge will permanently delete:"
      [[ -d "$STATE_DIR" ]] && echo "    $STATE_DIR (registry, auth profiles, audit log)"
      [[ -d "$CONNECTORS_DIR" ]] && echo "    $CONNECTORS_DIR (telegram/discord bot tokens)"
      id -u claude >/dev/null 2>&1 && echo "    user 'claude' and /home/claude"
      read -r -p "  continue? [y/N] " ans
      [[ "$ans" =~ ^[yY] ]] || die "aborted"
    fi
    rm -rf "$STATE_DIR" "$CONNECTORS_DIR"
    ok "removed state + connector dirs"
    if id -u claude >/dev/null 2>&1; then
      userdel -r claude 2>/dev/null || userdel claude 2>/dev/null || true
      ok "removed user 'claude'"
    fi
    getent group claude >/dev/null 2>&1 && groupdel claude 2>/dev/null && ok "removed group 'claude'" || true
  else
    echo
    say "kept (run again with --purge to remove):"
    [[ -d "$STATE_DIR" ]] && echo "    $STATE_DIR"
    [[ -d "$CONNECTORS_DIR" ]] && echo "    $CONNECTORS_DIR"
    id -u claude >/dev/null 2>&1 && echo "    user 'claude'"
  fi

  echo
  echo "5dive uninstalled."
  exit 0
fi

if [[ "${1:-}" == "--upgrade" ]]; then
  shift
  # --no-ui used to gate the (since-removed) local dashboard install; the flag
  # was dropped in 8932961 but smoke harnesses and operator scripts still pass
  # it. Swallow it here as a deprecated no-op rather than break callers.
  [[ "${1:-}" == "--no-ui" ]] && shift
  [[ $# -eq 0 ]] || die "--upgrade takes no extra flags"

  [[ -x "$BIN_DIR/5dive" ]] || die "no existing 5dive at $BIN_DIR/5dive — run install without --upgrade first"

  say "Upgrading 5dive CLI (skipping apt / nvm / bun / state setup)"
  refresh_managed_files

  echo
  echo "5dive upgraded."
  exit 0
fi

# --- Install (default) -----------------------------------------------------

say "Installing 5dive CLI"

# System dependencies. Skip apt entirely if every package is already
# installed — both speeds up reruns and avoids apt-lock contention when
# unattended-upgrades is running concurrently (common on freshly-provisioned
# boxes).
say "Installing system dependencies"
APT_PKGS="jq tmux git curl python3-yaml unzip"
apt_need=0
for p in $APT_PKGS; do
  dpkg -s "$p" >/dev/null 2>&1 || { apt_need=1; break; }
done
if (( apt_need )); then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_PKGS
  ok "$APT_PKGS"
else
  ok "$APT_PKGS already present"
fi

# Create claude group + user (agents run as agent-<name> in the claude group)
if ! getent group claude >/dev/null 2>&1; then
  groupadd --system claude
  ok "group 'claude' created"
fi
if ! id -u claude >/dev/null 2>&1; then
  useradd --system --gid claude --shell /bin/bash --create-home --home-dir /home/claude claude
  ok "user 'claude' created"
fi

# nvm + node (needed for codex agent type)
say "Installing nvm + Node.js"
if [[ ! -f /home/claude/.nvm/nvm.sh ]]; then
  sudo -u claude bash -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | PROFILE=/dev/null bash'
  ok "nvm installed"
fi
# Write nvm init to .bash_profile so `bash -lc` commands (used by the CLI) find
# node/npm. Guarded so reruns don't accumulate duplicate blocks.
if ! sudo -u claude grep -q 'NVM_DIR="$HOME/.nvm"' /home/claude/.bash_profile 2>/dev/null; then
  sudo -u claude bash -c 'cat >> /home/claude/.bash_profile <<'"'"'NVM_INIT'"'"'

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
NVM_INIT
'
fi
sudo -u claude bash -lc "nvm install $NODE_VERSION && nvm alias default $NODE_VERSION" 2>&1 | grep -E "Downloading|Now using|default" || true
ok "Node.js $NODE_VERSION"

# bun (needed for telegram plugin)
say "Installing bun"
if ! sudo -u claude bash -lc 'command -v bun' >/dev/null 2>&1; then
  sudo -u claude bash -c 'curl -fsSL https://bun.sh/install | bash' 2>/dev/null
  ok "bun installed"
else
  ok "bun already present"
fi

# Create directories
say "Setting up 5dive directories"
install -d -m 755 "$STATE_DIR"
install -d -m 755 "$STATE_DIR/agents.d"
install -d -m 755 "$CONNECTORS_DIR"
chown root:claude "$STATE_DIR" "$STATE_DIR/agents.d" "$CONNECTORS_DIR"
chmod 750 "$CONNECTORS_DIR"
ok "directories ready"

# Install / refresh CLI binaries, systemd unit, hooks, and skills.
# preseed_claude_agent references the hooks by absolute path under
# /usr/local/lib/5dive/ and warns at agent-create time if any are missing —
# without them the channel-paired agent will appear to start fine but its
# rate-limit handler / picker-blocking guard / missed-reply auto-relay are
# all silently disabled.
say "Installing CLI binaries, systemd unit, hooks, and skills"
refresh_managed_files

echo
echo "5dive installed successfully."
echo

# Show health state immediately so a fresh user knows whether anything is
# missing (e.g. agent type binaries) before they try to create an agent.
# Fail-soft: doctor itself always exits 0, but `|| true` guards against
# future regressions so a doctor crash never breaks the install.
say "Running health check"
5dive doctor || true

echo
echo "Next steps:"
echo "  5dive agent list                          # list agents"
echo "  5dive doctor --repair                     # auto-install agent type binaries"
echo "  5dive agent create my-agent --type=claude # create your first agent"
echo
echo "To upgrade later: curl -fsSL $REPO/install.sh | sudo bash -s -- --upgrade"
echo "Docs: https://github.com/5dive-com/5dive"
