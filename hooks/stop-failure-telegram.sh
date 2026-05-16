#!/usr/bin/env bash
# StopFailure hook: relay failure info to Telegram; if it's a rate_limit,
# auto-answer "1" (wait) to the blocking tmux prompt so the session stays
# responsive to incoming Telegram messages once the limit resets.

set -u
payload=$(cat)
msg=$(printf '%s' "$payload" | jq -r '[.message, .reason, .error, .stopReason] | map(select(.)) | join(" | ")' 2>/dev/null)
: "${msg:=no details}"

is_rate_limit=false
if printf '%s' "$payload" | grep -qi 'rate_limit\|usage.limit'; then
  is_rate_limit=true
fi

# Capture the rate-limit pane up front — used both for parsing the reset
# time (the pane is the most reliable source: claude prints "resets 9am
# (UTC)" verbatim) and later for the menu auto-press.
pane=""
if [[ -n "${TMUX:-}" ]]; then
  pane=$(tmux capture-pane -p 2>/dev/null || true)
fi

# Try to resolve an unlock/reset epoch from the payload, the message text,
# or the pane content (in that order).
# Payload shapes we've seen: numeric epoch in resetsAt/reset_at/resetAt, ISO
# string. Message/pane fallback: plain-English "resets 9am (UTC)" / "reset
# at 4pm (America/New_York)".
reset_epoch_num=""
reset_raw=$(printf '%s' "$payload" | jq -r '
  [.resetsAt, .reset_at, .resetAt, .error.resetsAt, .rateLimit.resetsAt]
  | map(select(. != null))
  | .[0] // empty
' 2>/dev/null)

if [[ -n "${reset_raw:-}" ]]; then
  if [[ "$reset_raw" =~ ^[0-9]+$ ]]; then
    reset_epoch_num="$reset_raw"
    if (( reset_epoch_num > 10000000000 )); then
      reset_epoch_num=$(( reset_epoch_num / 1000 ))
    fi
  else
    reset_epoch_num=$(date -d "$reset_raw" +%s 2>/dev/null || true)
  fi
fi

# parse_reset_from_text <text>: parse "<HH(:MM)?>(am|pm)? (<TZ>)?" out of
# <text>, set reset_epoch_num. Bumps to "tomorrow" if the parsed clock time
# is already in the past today.
parse_reset_from_text() {
  local text="$1"
  local t tz
  t=$(printf '%s' "$text" | grep -oiE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)' | head -1)
  tz=$(printf '%s' "$text" | grep -oE '\(([A-Za-z_]+/[A-Za-z_]+|UTC|GMT)\)' | head -1 | tr -d '()')
  [[ -z "$t" ]] && return 1
  local epoch
  if [[ -n "$tz" ]]; then
    epoch=$(TZ="$tz" date -d "$t" +%s 2>/dev/null || true)
  else
    epoch=$(date -d "$t" +%s 2>/dev/null || true)
  fi
  [[ -z "$epoch" ]] && return 1
  local now; now=$(date +%s)
  if (( epoch < now )); then
    if [[ -n "$tz" ]]; then
      epoch=$(TZ="$tz" date -d "$t tomorrow" +%s 2>/dev/null || true)
    else
      epoch=$(date -d "$t tomorrow" +%s 2>/dev/null || true)
    fi
  fi
  [[ -z "$epoch" ]] && return 1
  reset_epoch_num="$epoch"
  return 0
}

if [[ -z "$reset_epoch_num" ]]; then
  parse_reset_from_text "$msg" || true
fi

if [[ -z "$reset_epoch_num" && -n "$pane" ]]; then
  # Pane line we're after: "You've hit your limit · resets 9am (UTC)" — narrow
  # to the line containing "resets" so unrelated times in the pane (e.g. a
  # status line clock) don't poison the parse.
  reset_line=$(printf '%s' "$pane" | grep -iE 'resets?[[:space:]]+[0-9]' | head -1)
  if [[ -n "$reset_line" ]]; then
    parse_reset_from_text "$reset_line" || true
  fi
fi

time_left=""
if [[ -n "$reset_epoch_num" ]]; then
  now=$(date +%s)
  delta=$(( reset_epoch_num - now ))
  if (( delta <= 0 )); then
    time_left="any moment now"
  elif (( delta < 60 )); then
    time_left="${delta}s"
  elif (( delta < 3600 )); then
    time_left="$(( delta / 60 ))m"
  else
    h=$(( delta / 3600 ))
    m=$(( (delta % 3600) / 60 ))
    if (( m == 0 )); then
      time_left="${h}h"
    else
      time_left="${h}h ${m}m"
    fi
  fi
fi

if $is_rate_limit; then
  if [[ -n "$time_left" ]]; then
    text="Usage limit hit — resumes in ${time_left}."
  else
    text="The agent hit the usage limit — waiting for it to reset."
  fi
else
  text="The agent stopped with an error: ${msg}"
fi

access_file="${HOME}/.claude/channels/telegram/access.json"
chat_ids=$(jq -r '(.allowFrom // []) + ((.groups // {}) | keys) | .[]' "$access_file" 2>/dev/null)

for chat_id in $chat_ids; do
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${text}" \
    -o /dev/null 2>/dev/null || true
done

if $is_rate_limit; then
  # Hook runs as a subprocess of claude, which runs inside tmux — $TMUX is
  # inherited, so tmux commands without -t target the current session. That
  # makes this script agent-agnostic: same file serves `channel` and every
  # `agent-<name>` session.
  #
  # Auto-press "1" on the /rate-limit-options menu. The menu line looks like
  # "  ❯ 1. Stop and wait for limit to reset" — match the option label, not
  # the leading position, since the cursor glyph (❯) sits before the "1.".
  # Poll a few seconds because the menu can take a beat to render after the
  # StopFailure hook fires.
  attempt=0
  pressed=false
  while (( attempt < 20 )); do
    pane=$(tmux capture-pane -p 2>/dev/null || true)
    if printf '%s' "$pane" | grep -qiE '1\. Stop and wait'; then
      tmux send-keys "1" Enter 2>/dev/null || true
      pressed=true
      break
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  # Schedule a deferred auto-resume: at reset time, type "continue" + Enter
  # into the same tmux pane and ping Telegram so the user knows the agent is
  # back. Requires both a parsed reset epoch and a tmux target.
  if $pressed && [[ -n "$reset_epoch_num" && -n "${TMUX:-}" ]]; then
    tmux_socket=$(printf '%s' "$TMUX" | cut -d, -f1)
    tmux_target=$(tmux display -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)
    chat_ids_csv=$(printf '%s\n' $chat_ids | paste -sd, -)
    resume_helper="/usr/local/lib/5dive/resume-after-reset.sh"
    if [[ -n "$tmux_target" && -x "$resume_helper" ]]; then
      now=$(date +%s)
      delay=$(( reset_epoch_num - now + 30 ))  # 30s buffer past reset
      (( delay < 30 )) && delay=30
      log_dir="/var/lib/5dive/resume"
      mkdir -p "$log_dir" 2>/dev/null || log_dir="/tmp"
      log_file="${log_dir}/$(date +%s)-$$.log"
      TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
        setsid "$resume_helper" "$delay" "$tmux_socket" "$tmux_target" "$chat_ids_csv" \
        >"$log_file" 2>&1 < /dev/null &
      disown 2>/dev/null || true
    fi
  fi
fi

exit 0