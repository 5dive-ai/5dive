#!/usr/bin/env bash
# DIVE-6801: the build-time half of the 5dive server image (DigitalOcean 1-Click
# today; any cloud-init provider's snapshot later). Runs as root on a throwaway
# Ubuntu 24.04 build server, before the snapshot.
#
# Packages and the CLI go into the image here. Nothing that belongs to ONE server
# (keys, tokens, an account link) may leave with the image: cleanup.sh strips it,
# and the 5dive CLI makes it again on the new server, lazily or in firstboot.sh.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export DEBIAN_FRONTEND=noninteractive

apt-get -qq update
apt-get -qqy -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
apt-get -qqy install ufw curl ca-certificates

# The marketplaces require a firewall that is on. SSH, plus 80/443: Caddy serves
# the server's own secret links over HTTPS (DIVE-7113). Everything else stays shut.
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# The CLI, from the newest release, exactly the way a person installs it.
curl -fsSL "${FIVEDIVE_INSTALL_URL:-https://install.5dive.ai}" | bash

# The one login line (how to link this server to a 5dive account) and the
# once-per-new-server step.
install -D -m 0755 "$here/files/etc/update-motd.d/99-5dive" /etc/update-motd.d/99-5dive
install -D -m 0755 "$here/firstboot.sh" /var/lib/cloud/scripts/per-instance/001_5dive

# DIVE-7731: the one-time "connect this server" page (no terminal: the owner
# types the root password the hoster shows, then signs in to 5dive). firstboot.sh
# opens it; it is off in the image itself.
install -D -m 0755 "$here/files/usr/local/lib/5dive-claim/claim.py" /usr/local/lib/5dive-claim/claim.py
install -D -m 0644 "$here/files/etc/systemd/system/5dive-claim.service" /etc/systemd/system/5dive-claim.service
systemctl daemon-reload

# Caddy for the server's own https front (`5dive secret https`, DIVE-7113), in the
# image so the connect page is up a minute after boot, not after an apt run.
# From Caddy's signed apt source: IP certificates need Caddy 2.11+. Its stock
# service stays off; 5dive runs its own unit.
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
  | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
echo 'deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main' \
  > /etc/apt/sources.list.d/caddy-stable.list
apt-get -qq update
apt-get -qqy install caddy
systemctl disable --now caddy.service

apt-get -qqy autoremove
apt-get -qqy clean
