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

# DIVE-7731: first, the one-time connect page, so the hoster's "open
# http://<ip>/" link works within a minute or two of boot. It gets the server
# its own https name (an IP certificate) first; without one it stays closed and
# the login line's terminal path is the way.
claim="${FIVEDIVE_CLAIM:-/usr/local/lib/5dive-claim/claim.py}"
if [[ -f "$claim" ]]; then
  timeout 900 python3 -I "$claim" open </dev/null || echo "connect page did not open"
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
echo "5dive first boot done"
