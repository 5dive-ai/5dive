#!/usr/bin/env bash
# DIVE-6801: strip everything that makes the build server ONE particular server,
# so no two servers made from the image share a key. Runs as root right before
# the snapshot, after build.sh and before the provider's own clean-up and image
# check.
#
# Each removed item comes back on its own: the 5dive CLI makes its keys and the
# task board on first use, firstboot.sh re-runs the per-server install steps,
# cloud-init makes SSH host keys, systemd makes a machine id.
#
# IMAGE_ROOT points it at a fixture tree (tests/marketplace_image_unit.sh).
set -euo pipefail

r="${IMAGE_ROOT:-}"

# 5dive: per-server keys, the task board, account links, saved bot tokens.
rm -f  "$r/var/lib/5dive/gate-proof.key" "$r/etc/5dive/vault.key"
rm -f  "$r/etc/5dive/connectord.env" "$r/etc/5dive/provisioning.env"
rm -rf "$r/var/lib/5dive/tasks" "$r/var/lib/5dive/secret-drop"
if [[ -d "$r/etc/5dive/connectors" ]]; then
  find "$r/etc/5dive/connectors" -mindepth 1 -delete
fi

# The machine itself: id, SSH host and user keys, shell history. Caddy's
# certificates name the build server's address, if a later step added Caddy.
if [[ -f "$r/etc/machine-id" ]]; then
  : > "$r/etc/machine-id"
fi
rm -f  "$r/var/lib/dbus/machine-id"
rm -f  "$r"/etc/ssh/ssh_host_*
rm -rf "$r/var/lib/caddy/.local/share/caddy"
for h in "$r/root" "$r"/home/*; do
  [[ -d "$h" ]] || continue
  rm -f "$h/.ssh/authorized_keys" "$h"/.ssh/id_* "$h/.bash_history"
done

# The check: no key, token or certificate file is left in 5dive's state. A miss
# here fails the build rather than shipping one server's key to every customer.
left=$(find "$r/etc/5dive" "$r/var/lib/5dive" -type f \
  \( -name '*.key' -o -name '*.pem' -o -name '*token*' -o -name 'connectord.env' \) 2>/dev/null || true)
if [[ -n "$left" ]]; then
  echo "cleanup: per-server secrets are still in the image:" >&2
  echo "$left" >&2
  exit 1
fi
echo "cleanup: no per-server 5dive state left in the image"
