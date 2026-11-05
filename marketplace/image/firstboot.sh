#!/usr/bin/env bash
# DIVE-6801: runs once on each NEW server made from the 5dive image (cloud-init
# runs /var/lib/cloud/scripts/per-instance/ once per instance id).
#
# It never blocks the login: every step is best-effort, and a failed one leaves
# the server on the image's CLI, which works.
set -uo pipefail

cli="${FIVEDIVE_CLI:-/usr/local/bin/5dive}"
log="${FIVEDIVE_FIRSTBOOT_LOG:-/var/log/5dive-firstboot.log}"
exec >>"$log" 2>&1
echo "5dive first boot $(date -u +%FT%TZ)"

# DIVE-7756: the one-time connect starts first, so the server checks in with
# 5dive within a minute of boot; it runs the link only after this script is done.
claim_dir="${FIVEDIVE_CLAIM_DIR:-/var/lib/5dive-claim}"
if [[ -f /etc/systemd/system/5dive-claim.service ]]; then
  systemctl enable --now --no-block 5dive-claim.service || echo "connect job did not start"
fi

# An image can be weeks older than the newest release: start on the newest.
if ! timeout 900 "$cli" self-update </dev/null; then
  echo "self-update failed; keeping the image's CLI"
fi

# The per-server steps of a fresh install, for this server (cleanup.sh removed
# the build server's): gate-proof on with its own key, and this server's own
# secret-link address routed before the first link needs it (DIVE-5372).
"$cli" gate-proof enforce on </dev/null || echo "gate-proof enforce on failed"
"$cli" secret _prewarm </dev/null || echo "secret _prewarm failed"
mkdir -p "$claim_dir" && touch "$claim_dir/firstboot-done"
echo "5dive first boot done"
