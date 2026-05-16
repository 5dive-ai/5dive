#!/usr/bin/env bash
# 5dive CLI installer
# Usage: curl -fsSL https://raw.githubusercontent.com/5dive-com/5dive-cli/main/install.sh | sudo bash
set -euo pipefail

REPO="https://raw.githubusercontent.com/5dive-com/5dive-cli/main"
BIN_DIR="/usr/local/bin"
STATE_DIR="/var/lib/5dive"
CONNECTORS_DIR="/etc/5dive/connectors"
SYSTEMD_DIR="/etc/systemd/system"
NODE_VERSION="22"

die() { echo "error: $*" >&2; exit 1; }
ok()  { echo "  ✓ $*"; }
say() { echo "→ $*"; }

[[ $EUID -eq 0 ]] || die "run as root: curl -fsSL ... | sudo bash"

say "Installing 5dive CLI"

# System dependencies
say "Installing system dependencies"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq tmux git curl python3-yaml
ok "jq, tmux, git, curl, python3-yaml"

# Create claude group + user (agents run as agent-<name> in the claude group)
if ! getent group claude >/dev/null 2>&1; then
  groupadd --system claude
  ok "group 'claude' created"
fi
if ! id -u claude >/dev/null 2>&1; then
  useradd --system --gid claude --shell /bin/bash --create-home --home-dir /home/claude claude
  ok "user 'claude' created"
fi

# nvm + node (needed for codex, gemini agent types)
say "Installing nvm + Node.js"
if [[ ! -f /home/claude/.nvm/nvm.sh ]]; then
  sudo -u claude bash -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | PROFILE=/dev/null bash'
  ok "nvm installed"
fi
# Write nvm init to .bash_profile so `bash -lc` commands (used by the CLI) find node/npm
sudo -u claude bash -c 'cat >> /home/claude/.bash_profile <<'"'"'NVM_INIT'"'"'

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
NVM_INIT
'
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

# Install CLI
say "Installing CLI binaries"
curl -fsSL "$REPO/5dive" -o "$BIN_DIR/5dive"
chmod 755 "$BIN_DIR/5dive"
ok "5dive → $BIN_DIR/5dive"

curl -fsSL "$REPO/5dive-agent-start" -o "$BIN_DIR/5dive-agent-start"
chmod 755 "$BIN_DIR/5dive-agent-start"
ok "5dive-agent-start → $BIN_DIR/5dive-agent-start"

# Install systemd template
curl -fsSL "$REPO/systemd/5dive-agent%40.service" -o "$SYSTEMD_DIR/5dive-agent@.service"
systemctl daemon-reload
ok "systemd template installed"

# Install shared hooks + skills for claude-family telegram agents.
# preseed_claude_agent references these by absolute path under
# /usr/local/lib/5dive/, and warns at agent-create time if any are missing.
# Without these the channel-paired agent will appear to start fine but its
# rate-limit handler / picker-blocking guard / missed-reply auto-relay are
# all silently disabled.
say "Installing telegram hooks + skills"
HOOKS_DIR="/usr/local/lib/5dive"
install -d -m 755 "$HOOKS_DIR" "$HOOKS_DIR/skills/notify-user"
for hook in stop-failure-telegram.sh resume-after-reset.sh \
            pretool-telegram-question.sh stop-telegram-reply-check.sh; do
  curl -fsSL "$REPO/hooks/$hook" -o "$HOOKS_DIR/$hook"
  chmod 755 "$HOOKS_DIR/$hook"
  ok "$hook"
done
curl -fsSL "$REPO/skills/notify-user/SKILL.md" -o "$HOOKS_DIR/skills/notify-user/SKILL.md"
chmod 644 "$HOOKS_DIR/skills/notify-user/SKILL.md"
ok "notify-user skill"

echo
echo "5dive installed successfully."
echo
echo "Next steps:"
echo "  5dive agent list                          # list agents"
echo "  5dive doctor                              # check system health"
echo "  5dive doctor --repair                     # auto-install agent type binaries"
echo "  5dive agent create my-agent --type=claude # create your first agent"
echo
echo "Docs: https://github.com/5dive-com/5dive-cli"
