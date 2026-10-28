#!/bin/bash
# DIVE-6802: the image's PID-1 wrapper. It runs once per container start, before
# systemd, and then execs /sbin/init.
#
# Why it exists: docker/compose.yaml keeps /etc, /home, /root, /var/lib/5dive and
# /var/spool/cron on named volumes, so a recreate keeps the agents (they are
# Linux users, sudoers files and enabled units in /etc, homes and harnesses in
# /home). But a NEW image's CLI then boots over the OLD image's /etc. So when the
# CLI baked into this image differs from the one that last laid down that state,
# re-run install.sh from the bundle the image carries: the same path a host takes
# on `5dive self-update`, just from file:// instead of GitHub.
#
# A failed re-run never blocks the boot: the marker is left alone, so the next
# start tries again, and the box comes up on whatever state it had.
set -u

marker=/var/lib/5dive/image-cli-version
want=$(/usr/local/bin/5dive --version 2>/dev/null | tr -d '\n')
have=$(cat "$marker" 2>/dev/null || true)

if [[ -n "$want" && "$want" != "$have" ]]; then
  echo "5dive: CLI changed (${have:-none} -> $want), re-applying install.sh over the saved state" >&2
  # Same stub as the build: systemd is not PID 1 yet, so install.sh's
  # daemon-reload cannot succeed here. Units load fresh when init starts.
  ln -sf /bin/true /usr/local/bin/systemctl
  if REPO=file:///opt/5dive-bundle bash /opt/5dive-bundle/install.sh >/var/log/5dive-image-sync.log 2>&1; then
    mkdir -p "${marker%/*}" && printf '%s\n' "$want" >"$marker"
    echo "5dive: re-applied, now $want" >&2
  else
    echo "5dive: install.sh failed (see /var/log/5dive-image-sync.log); booting the saved state as is, will retry next start" >&2
  fi
  rm -f /usr/local/bin/systemctl
fi

exec /sbin/init "$@"
