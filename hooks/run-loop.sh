#!/usr/bin/env bash
# DIVE-1029 — supervised restart loop with crash-loop detection.
#
# Runs the agent binary in a respawn loop inside the agent's tmux pane
# (invoked as the tmux session command by 5dive-agent-start). It replaces the
# old naive `while true; do claude ...; sleep 2; done` so the box can tell a
# genuine usage-limit park (claude ran healthy for a while, then exited) apart
# from a crash-loop (claude dies within seconds, over and over — e.g. the
# stale plugin-marketplace git remote after the 2026-07 org rename that
# crash-looped 19/21 agents).
#
# On a crash-loop it:
#   1. backs off exponentially (2s → … → BACKOFF_CAP) instead of hammering a
#      2s respawn,
#   2. surfaces the REAL error to the paired chats ONCE — the exit code plus
#      the last lines of the pane (which carry claude's actual stderr, e.g.
#      "fatal: remote origin ... not found"), rather than a misleading
#      "usage limit" banner, and
#   3. drops a crash-loop flag file that resume-after-reset.sh and
#      stop-failure-telegram.sh read to SUPPRESS the "Usage limit reset —
#      agent resumed" banner while the agent is actually just dying.
#
# A healthy run (>= FAST_SECS) clears the counter + flag and, if we had been
# crash-looping, sends a single "recovered" note.
#
# Env in:
#   RUN_CMD          (required) eval'd every iteration to launch the agent
#   RUN_CMD_FIRST    (optional) eval'd on the FIRST iteration only (--resume)
#   AGENT_NAME       agent name for the alert text (default: unknown)
#   TELEGRAM_BOT_TOKEN            inherited from the unit env; alert is a no-op without it
#   CRASH_ACCESS_FILE            access.json to resolve chat ids
#                                (default: $HOME/.claude/channels/telegram/access.json)
#   FAST_SECS        below this = a "fast failure" (default 45)
#   CRASHLOOP_N      this many fast failures in a row = crash-loop (default 3)
#   BACKOFF_CAP      max backoff seconds (default 300)
#   CRASHLOOP_FLAG   flag path (default: $HOME/.cache/5dive/crashloop.active)
#
# The pure decision helpers (_cl_is_fast / _cl_backoff) carry no side effects
# so tests can source this file (guarded by _RUN_LOOP_SOURCED=1) and assert on
# them without launching anything.

set -u

# _cl_is_fast <run_seconds> <fast_threshold>
# 0 (true) when the run was too short to be a healthy session.
_cl_is_fast() {
  local secs="${1:-0}" thr="${2:-45}"
  [[ "$secs" =~ ^[0-9]+$ ]] || secs=0
  (( secs < thr ))
}

# _cl_backoff <consecutive_fast_failures> <crashloop_n> <cap>
# Echoes the seconds to sleep before the next respawn. Below the crash-loop
# threshold we keep the original friendly 2s. At/after it we back off
# exponentially from the threshold, clamped to <cap>:
#   n=N   → 2s    (first flagged failure still respawns quickly)
#   n=N+1 → 5s, N+2 → 10s, N+3 → 20s, … doubling, capped at <cap>.
_cl_backoff() {
  local n="${1:-0}" thr="${2:-3}" cap="${3:-300}"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  if (( n < thr )); then
    echo 2
    return
  fi
  local over=$(( n - thr ))          # 0,1,2,3,…
  if (( over == 0 )); then
    echo 2
    return
  fi
  # 5 * 2^(over-1): 5,10,20,40,80,160,320…
  local delay=$(( 5 * (1 << (over - 1)) ))
  (( delay > cap )) && delay="$cap"
  echo "$delay"
}

# _cl_chat_ids <access_file> — echo whitespace-separated chat ids (allowFrom +
# group keys), mirroring stop-failure-telegram.sh's fallback set.
_cl_chat_ids() {
  local f="${1:-}"
  [[ -r "$f" ]] || return 0
  jq -r '(.allowFrom // []) + ((.groups // {}) | keys) | .[]' "$f" 2>/dev/null || true
}

# _cl_notify <text> — best-effort Telegram fan-out. Never fails the loop.
_cl_notify() {
  local text="$1"
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || return 0
  local access="${CRASH_ACCESS_FILE:-$HOME/.claude/channels/telegram/access.json}"
  local ids; ids=$(_cl_chat_ids "$access")
  [[ -n "$ids" ]] || return 0
  local id
  for id in $ids; do
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${id}" \
      --data-urlencode "text=${text}" \
      -o /dev/null 2>/dev/null || true
  done
}

# _cl_pane_tail <n> — last n non-blank lines of the current tmux pane, which is
# where the dying binary printed its actual error. Empty when not under tmux.
_cl_pane_tail() {
  local n="${1:-12}"
  [[ -n "${TMUX:-}" ]] || return 0
  tmux capture-pane -p 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n "$n" || true
}

run_loop() {
  local run_cmd="${RUN_CMD:?RUN_CMD required}"
  local run_cmd_first="${RUN_CMD_FIRST:-}"
  local name="${AGENT_NAME:-unknown}"
  local fast_secs="${FAST_SECS:-45}"
  local crashloop_n="${CRASHLOOP_N:-3}"
  local backoff_cap="${BACKOFF_CAP:-300}"
  local flag="${CRASHLOOP_FLAG:-$HOME/.cache/5dive/crashloop.active}"

  mkdir -p "$(dirname "$flag")" 2>/dev/null || true

  local consecutive=0 first=1 notified=0
  while true; do
    local start end dur ec
    start=$(date +%s)
    if (( first )) && [[ -n "$run_cmd_first" ]]; then
      eval "$run_cmd_first"; ec=$?
    else
      eval "$run_cmd"; ec=$?
    fi
    first=0
    end=$(date +%s)
    dur=$(( end - start ))
    (( dur < 0 )) && dur=0

    if _cl_is_fast "$dur" "$fast_secs"; then
      consecutive=$(( consecutive + 1 ))
    else
      # Healthy run. If we were crash-looping, announce recovery once.
      if (( notified )); then
        _cl_notify "Agent ${name} recovered — running normally again."
      fi
      consecutive=0
      notified=0
      rm -f "$flag" 2>/dev/null || true
    fi

    local delay
    delay=$(_cl_backoff "$consecutive" "$crashloop_n" "$backoff_cap")

    if (( consecutive >= crashloop_n )); then
      # Mark the crash-loop so the usage-limit resume banner is suppressed
      # (this is a dying agent, not a limit reset). Refresh mtime each round
      # so readers can treat a stale flag as expired.
      : > "$flag" 2>/dev/null || true
      if (( ! notified )); then
        notified=1
        local tail; tail=$(_cl_pane_tail 12)
        local text="Agent ${name} is crash-looping (exited ${consecutive}× in a row, last exit code ${ec}). Backing off ${delay}s and NOT resuming until it's healthy."
        [[ -n "$tail" ]] && text+=$'\n\n'"Last output:"$'\n'"$tail"
        _cl_notify "$text"
      fi
    fi

    sleep "$delay"
  done
}

# Only run the loop when executed, not when sourced by a test.
if [[ "${_RUN_LOOP_SOURCED:-0}" != "1" ]]; then
  run_loop
fi
