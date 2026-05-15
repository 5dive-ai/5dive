#!/usr/bin/env bash
# 5dive CLI installer
# Usage: curl -fsSL https://raw.githubusercontent.com/5dive-com/5dive-cli/main/install.sh | sudo bash
set -euo pipefail

REPO="https://raw.githubusercontent.com/5dive-com/5dive-cli/main"
BIN_DIR="/usr/local/bin"
STATE_DIR="/var/lib/5dive"
CONNECTORS_DIR="/etc/5dive/connectors"
SYSTEMD_DIR="/etc/systemd/system"

die() { echo "error: $*" >&2; exit 1; }
ok()  { echo "  ✓ $*"; }
say() { echo "→ $*"; }

[[ $EUID -eq 0 ]] || die "run as root: curl -fsSL ... | sudo bash"

say "Installing 5dive CLI"

# Create directories
install -d -m 755 "$STATE_DIR"
install -d -m 755 "$STATE_DIR/agents.d"
install -d -m 755 "$CONNECTORS_DIR"
ok "directories created"

# Install CLI
curl -fsSL "$REPO/5dive" -o "$BIN_DIR/5dive"
chmod 755 "$BIN_DIR/5dive"
ok "5dive installed to $BIN_DIR/5dive"

# Install agent-start helper
curl -fsSL "$REPO/5dive-agent-start" -o "$BIN_DIR/5dive-agent-start"
chmod 755 "$BIN_DIR/5dive-agent-start"
ok "5dive-agent-start installed"

# Install systemd template
curl -fsSL "$REPO/systemd/5dive-agent%40.service" -o "$SYSTEMD_DIR/5dive-agent@.service"
systemctl daemon-reload
ok "systemd template installed"

# Create claude group if missing (agents run in this group)
if ! getent group claude >/dev/null 2>&1; then
  groupadd --system claude
  ok "group 'claude' created"
fi

# Create claude user if missing
if ! id -u claude >/dev/null 2>&1; then
  useradd --system --gid claude --shell /bin/bash --create-home --home-dir /home/claude claude
  ok "user 'claude' created"
fi

chown root:claude "$STATE_DIR" "$STATE_DIR/agents.d" "$CONNECTORS_DIR"
chmod 750 "$CONNECTORS_DIR"
ok "permissions set"

echo
echo "5dive installed. Try: 5dive agent list"
echo "Docs: https://github.com/5dive-com/5dive-cli"
