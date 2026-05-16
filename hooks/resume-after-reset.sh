#!/usr/bin/env bash
# Spawned detached by stop-failure-telegram.sh after the rate-limit menu is
# auto-dismissed. Sleeps until the usage limit resets, then types "continue"
# into the originating tmux pane and pings the paired Telegram chats so the
# user knows their agent is awake again.
#
# Args: <delay_seconds> <tmux_socket> <tmux_target> <chat_ids_csv>
# Env:  TELEGRAM_BOT_TOKEN (required for the notification)

set -u
delay="${1:-0}"
socket="${2:-}"
target="${3:-}"
chat_ids_csv="${4:-}"

if [[ "$delay" =~ ^[0-9]+$ ]] && (( delay > 0 )); then
  sleep "$delay"
fi

if [[ -n "$socket" && -n "$target" ]]; then
  # If claude is still parked at "Stop and wait", typing "continue" + Enter
  # wakes it. If it has already exited, the pane is at a shell — typing
  # "continue" there is a no-op (command-not-found) which is harmless.
  tmux -S "$socket" send-keys -t "$target" "continue" Enter 2>/dev/null || true
fi

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "$chat_ids_csv" ]]; then
  IFS=',' read -ra cids <<< "$chat_ids_csv"
  for cid in "${cids[@]}"; do
    [[ -z "$cid" ]] && continue
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${cid}" \
      --data-urlencode "text=Usage limit reset — agent resumed." \
      -o /dev/null 2>/dev/null || true
  done
fi

exit 0
