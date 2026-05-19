#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash): mirror outbound inter-agent traffic to a
# shared Telegram group so the human operator can watch agent-to-agent
# conversations alongside their own DMs.
#
# Fires when the agent runs `5dive agent send|ask <to> <body>`. Reads the
# group chat_id from the agent's own ~/.claude/channels/telegram/access.json
# (same-user, no cross-sandbox reads) and posts via the plugin's bot token
# already exported into the systemd env as TELEGRAM_BOT_TOKEN.
#
# Why PreToolUse (not Post): `5dive agent ask` blocks until the receiver
# replies. Mirroring on PostToolUse meant the question only posted AFTER
# the answer was already mirrored (by the receiver's own send PostToolUse),
# so the group saw reply-before-question. Mirroring on PreToolUse posts
# the outgoing line before the underlying call runs, preserving order. The
# only cost: if the send/ask itself fails (rare), the mirror is a false
# positive — operator sees a line that didn't actually reach the receiver.
# Cross-agent visibility outweighs that edge case.
#
# Idempotent skips (any of these → exit 0):
#   - Tool wasn't Bash or command doesn't match `5dive agent send|ask`
#   - No TELEGRAM_BOT_TOKEN in env (telegram plugin not provisioned)
#   - No group/supergroup chat in access.json (DM-only agent)
#   - Body argument couldn't be parsed
#   - Body contains unexpanded shell substitution (`$(`, backtick, `${`).
#     Bash runs the substitution before invoking 5dive, so the receiver
#     gets the right body — but the hook only sees the literal command
#     string. Rather than post garbled "$(cat <<EOF...)" text, skip this
#     one mirror and log a breadcrumb to stderr. Agents should prefer
#     plain quoted strings if they want every message mirrored.
#
# Loop prevention: relies on Telegram's default bot privacy_mode — bots
# don't see other bots' messages in groups, so agent A's plugin never sees
# the mirror line agent B posted. If the operator disables privacy_mode or
# promotes the bot to admin, a denylist would need to be added to the
# plugin (out of scope for v1).

set -u
payload=$(cat)

tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)
[[ "$tool" == "Bash" ]] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -z "$cmd" ]] && exit 0

# Quick filter — the regex match below is robust to whitespace and flags,
# but a substring check first keeps the common-case cost trivial.
[[ "$cmd" == *"5dive"*"agent"*"send"* || "$cmd" == *"5dive"*"agent"*"ask"* ]] || exit 0

[[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || exit 0

access_file="${HOME}/.claude/channels/telegram/access.json"
[[ -r "$access_file" ]] || exit 0
group_chat_id=$(jq -r '(.groups // {}) | keys | .[0] // empty' "$access_file" 2>/dev/null)
[[ -n "$group_chat_id" ]] || exit 0

from="${HOME##*/agent-}"
[[ -n "$from" && "$from" != "$HOME" ]] || exit 0

# Parse `<to>` and `<body>` out of the command via shlex so quoting,
# escapes, and inter-token whitespace don't trip naive splitting.
parsed=$(printf '%s' "$cmd" | python3 -c '
import sys, shlex
try:
  toks = shlex.split(sys.stdin.read())
except ValueError:
  sys.exit(0)
for i, t in enumerate(toks):
  if t in ("send", "ask"):
    # Find the preceding "agent" to be sure this is the 5dive verb, not
    # some other command that happens to contain "send".
    if i == 0 or toks[i-1] != "agent":
      continue
    j = i + 1
    while j < len(toks) and toks[j].startswith("--"):
      # Allow flags like --from=X, --raw, --json between verb and to.
      j += 1
    if j >= len(toks):
      sys.exit(0)
    to = toks[j]
    j += 1
    # Skip more flags after the to-name (--timeout, --json, etc).
    while j < len(toks) and toks[j].startswith("--"):
      j += 1
    if j >= len(toks):
      sys.exit(0)
    body = toks[j]
    print(to)
    print(body)
    sys.exit(0)
' 2>/dev/null)

to=$(printf '%s' "$parsed" | head -1)
body=$(printf '%s' "$parsed" | tail -n +2)
[[ -n "$to" && -n "$body" ]] || exit 0

# Unexpanded shell substitution → skip with a breadcrumb. Bash already
# expanded these before invoking 5dive, so the receiver got the right
# text; only the mirror would be garbled if we posted what we see here.
if [[ "$body" == *'$('* || "$body" == *'`'* || "$body" == *'${'* ]]; then
  printf '[mirror-agent-send] skip mirror: body has unexpanded shell substitution (to=%s)\n' "$to" >&2
  exit 0
fi

# Defensive: strip any envelope the agent may have manually included.
# The CLI auto-wraps; agents shouldn't pre-wrap, but tolerate it.
body=$(printf '%s' "$body" | sed -E 's/^\[5dive-msg[[:space:]]+from=[a-z0-9-]+[[:space:]]+id=[a-f0-9]+\][[:space:]]*//')

max_chars="${MIRROR_MAX_BODY_CHARS:-200}"
body_trim=$(printf '%s' "$body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
[[ -z "$body_trim" ]] && exit 0
if (( ${#body_trim} > max_chars )); then
  body_disp="${body_trim:0:$((max_chars - 1))}…"
  overflow=" (+$(( ${#body_trim} - max_chars )) chars)"
else
  body_disp="$body_trim"
  overflow=""
fi

# Resolve the receiver's Telegram bot username (if any) so the mirror
# line can @-mention it. The plugin's access.json allowFrom list filters
# out non-operator senders, so the receiver bot mentioning itself in the
# group does not cause it to ingest the mirror as inbound (no loop).
# Bare-name fallback if the agent isn't a telegram-channel agent or the
# registry lookup fails for any reason.
to_label="$to"
to_bot=$(sudo -n 5dive --json agent list 2>/dev/null \
  | jq -r --arg n "$to" '
      (.data // [])[]
      | select(.name == $n)
      | .botUsername // empty
    ' 2>/dev/null \
  | head -1)
[[ -n "$to_bot" ]] && to_label="@${to_bot}"

# Sender identity is already visible in Telegram from the posting bot;
# the receiver mention is enough context. Minimal format: "@bot <body>"
# (single space — reads like a normal Telegram mention).
text=$(printf '%s %s%s' "$to_label" "$body_disp" "$overflow")

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${group_chat_id}" \
  --data-urlencode "text=${text}" \
  -o /dev/null 2>/dev/null || true

exit 0
