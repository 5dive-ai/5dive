#!/usr/bin/env bash
# DIVE-72: best-effort native push for agent events, teed alongside the Telegram
# notify hooks. Reads the box's per-server connectord token and POSTs the event
# to the control-plane, which fans it out to the owner's mobile devices (Expo).
#
# Bulletproof by contract — this MUST NEVER block or fail its caller. Callers
# invoke it backgrounded with output discarded:
#     /usr/local/lib/5dive/push-notify.sh <event> [message] [agent] &
# A box with no connectord token (OSS / unprovisioned) is a silent no-op.
#
#   <event>   done | blocked | error | question   (anything else => error)
#   [message] short human detail (the API trims to 180 chars)
#   [agent]   agent label; if omitted the helper derives a best-effort one
set -u

event="${1:-error}"
message="${2:-}"
agent="${3:-}"

# The connectord token doubles as this box's identity to the control-plane.
# File is 0640 root:claude, so the agent user (claude group) can read it.
token_file="/etc/5dive/connectord.env"
[ -r "$token_file" ] || exit 0
token=$(sed -n 's/^CONNECTORD_TOKEN=//p' "$token_file" 2>/dev/null | head -1)
[ -n "$token" ] || exit 0

# Best-effort agent label when the caller didn't pass one.
if [ -z "$agent" ]; then
  agent=$(sed -n 's/^FIVE_SERVER_NAME=//p' /etc/5dive/provisioning.env 2>/dev/null | head -1)
  [ -n "$agent" ] || agent=$(hostname -s 2>/dev/null || echo agent)
fi

api_base="${FIVE_API_BASE:-https://api.5dive.com}"
body=$(jq -nc --arg e "$event" --arg a "$agent" --arg m "$message" \
        '{event:$e, agent:$a, message:$m}' 2>/dev/null) || exit 0

curl -fsS --max-time 5 -X POST "$api_base/server/push/event" \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  --data "$body" >/dev/null 2>&1 || true

exit 0
