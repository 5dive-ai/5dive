#!/usr/bin/env bash
# Spawned detached by stop-failure-telegram.sh as soon as it detects a usage
# limit. Owns the full rate-limit recovery flow:
#
#   Phase 1 (auto-press): poll the tmux pane for claude's "1. Stop and wait"
#     menu, send "1" + Enter when it appears. Polls up to ~60s — long enough
#     for the menu to render in practice but bounded so a stuck pane doesn't
#     hold the process forever. Skipped silently if the menu never appears
#     (e.g. user pressed it themselves, or claude exited instead of parking).
#
#   Phase 2 (wait): sleep until reset_epoch + 30s buffer.
#
#   Phase 3 (resume): type "continue" + Enter into the originating tmux pane
#     so claude picks up the conversation. If claude already exited, the
#     keystrokes hit a shell — "continue" is a no-op there, harmless.
#
#   Phase 4 (ping): tell the paired Telegram chats the agent is back.
#
# Args: <reset_epoch> <tmux_socket> <tmux_target> <chat_ids_csv>
# Env:  TELEGRAM_BOT_TOKEN (required for the notification)
#
# Why this lives outside the hook: the StopFailure hook has timeout=10s but
# menu rendering can lag several seconds and the wait phase is up to 5h. The
# hook spawns this script via setsid + & so it runs free of the hook timeout
# and free of the agent's tmux session lifecycle.

set -u
reset_epoch="${1:-0}"
socket="${2:-}"
target="${3:-}"
chat_ids_csv="${4:-}"

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

log "resume-after-reset start: reset_epoch=$reset_epoch socket=$socket target=$target"

# Phase 1 — poll-and-press. Same regex as before (matches "1. Stop and wait"
# anywhere in the pane, tolerant of the cursor glyph ❯). Up to 60 attempts at
# 1s = 60s, generous enough for normal renders.
pressed=false
if [[ -n "$socket" && -n "$target" ]]; then
  attempt=0
  while (( attempt < 60 )); do
    pane=$(tmux -S "$socket" capture-pane -t "$target" -p 2>/dev/null || true)
    if printf '%s' "$pane" | grep -qiE '1\. Stop and wait'; then
      tmux -S "$socket" send-keys -t "$target" "1" Enter 2>/dev/null || true
      pressed=true
      log "phase1 pressed '1' on attempt $attempt"
      break
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  $pressed || log "phase1 menu never appeared after ${attempt}s — proceeding to wait anyway"
fi

# Phase 2 — sleep until reset + 30s buffer. Clamp to >=30s so a stale epoch
# never makes us skip the wait entirely.
now=$(date +%s)
if [[ "$reset_epoch" =~ ^[0-9]+$ ]] && (( reset_epoch > 0 )); then
  delay=$(( reset_epoch - now + 30 ))
  (( delay < 30 )) && delay=30
  log "phase2 sleeping ${delay}s until reset"
  sleep "$delay"
fi

# Phase 3 — resume claude. send-keys is a no-op if the pane has gone away.
if [[ -n "$socket" && -n "$target" ]]; then
  tmux -S "$socket" send-keys -t "$target" "continue" Enter 2>/dev/null || true
  log "phase3 sent 'continue' to $target"
fi

# Phase 4 — Telegram ping. Multiple chats supported (DM + group).
#
# DIVE-1029: suppress the "resumed" banner when the agent is actually
# crash-looping rather than genuinely back from a usage-limit reset. The
# supervised run-loop drops a fresh crash-loop flag while claude keeps dying;
# if it's present and recent, our "continue" keystroke landed on a dying agent,
# not a recovered one — posting "agent resumed" would be a lie (this is exactly
# the false banner storm that motivated this task). Treat a flag older than 5m
# as stale (the loop refreshes its mtime every crash round).
crashloop_flag="${CRASHLOOP_FLAG:-$HOME/.cache/5dive/crashloop.active}"
if [[ -f "$crashloop_flag" ]]; then
  flag_age=$(( $(date +%s) - $(stat -c %Y "$crashloop_flag" 2>/dev/null || echo 0) ))
  if (( flag_age >= 0 && flag_age < 300 )); then
    log "phase4 suppressed resume banner — agent is crash-looping (flag age ${flag_age}s)"
    exit 0
  fi
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
  log "phase4 telegram pings sent"
fi

exit 0
