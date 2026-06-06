#!/usr/bin/env bash
# StopFailure hook: relay failure info to Telegram. For rate-limit failures,
# fork the resume-after-reset helper which owns the full recovery flow
# (auto-press "1" on the menu, wait for reset, type "continue", ping). The
# hook itself stays short — well under its 10s timeout — because all the
# slow parts (menu polling, long wait) live in the detached helper.

set -u
payload=$(cat)
msg=$(printf '%s' "$payload" | jq -r '[.message, .reason, .error, .stopReason] | map(select(.)) | join(" | ")' 2>/dev/null)
: "${msg:=no details}"

is_rate_limit=false
if printf '%s' "$payload" | grep -qi 'rate_limit\|usage.limit'; then
  is_rate_limit=true
fi

# Pull the transcript path from the payload up front — used for both the
# reset-time parse below and caller-chat narrowing further down.
transcript_path=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)

# Capture the tmux pane. Two uses:
#   1. Scrape "API Error: 529 ..." for non-rate-limit failures (the
#      payload only carries the high-level reason; the API status line
#      only appears in claude's pane output).
#   2. Last-resort fallback for the rate-limit reset time.
#
# Not the primary source for rate-limit timing: when claude shows the
# "Stop and wait" menu, the pane switches to the alternate screen and the
# preceding "resets Xpm (TZ)" line is gone from what capture-pane sees.
# The transcript captures that line as a structured synthetic message
# (error="rate_limit", isApiErrorMessage=true) and is immune to tmux
# screen state.
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

# Source #2 (preferred fallback): the transcript. The most recent synthetic
# assistant message tagged error="rate_limit" carries the exact "resets Xpm
# (TZ)" line claude received from the 429 response. Authoritative and
# immune to the tmux alt-screen issue that hides the pane line when the
# "Stop and wait" menu is showing.
if [[ -z "$reset_epoch_num" && -n "$transcript_path" && -r "$transcript_path" ]]; then
  reset_text=$(jq -rs '
    [ .[]
      | select(.error == "rate_limit" and .isApiErrorMessage == true)
      | (.message.content[]? | select(.type == "text") | .text)
    ] | last // ""
  ' "$transcript_path" 2>/dev/null)
  if [[ -n "$reset_text" ]]; then
    parse_reset_from_text "$reset_text" || true
  fi
fi

if [[ -z "$reset_epoch_num" ]]; then
  parse_reset_from_text "$msg" || true
fi

# Last resort: scrape "resets Xpm (TZ)" from the pane. Often empty for
# rate-limit cases (alt-screen, see capture above) but cheap to try and
# catches the rare case where the transcript hasn't flushed yet.
if [[ -z "$reset_epoch_num" && -n "$pane" ]]; then
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

# Unified rate-limit text: same prefix in both branches, time tail only when
# we parsed a reset epoch. Prior split ("The agent hit the usage limit —
# waiting for it to reset" vs "Usage limit hit — resumes in 12m") read like
# two different events; this collapses them.
if $is_rate_limit; then
  if [[ -n "$time_left" ]]; then
    text="Usage limit hit — resumes in ${time_left}."
  else
    text="Usage limit hit — waiting for reset."
  fi
else
  text="The agent stopped with an error: ${msg}"
  # The StopFailure payload only carries the high-level reason
  # ("server_error"); the actual status line — "API Error: 529 Overloaded"
  # — lives only in claude's pane output. Pull it out of the pane capture
  # we already grabbed above so the Telegram alert names the failure.
  if [[ -n "$pane" ]]; then
    api_err=$(printf '%s' "$pane" | grep -oE 'API Error:[[:space:]]+[0-9]+[^.[:cntrl:]]*' | tail -1)
    if [[ -n "$api_err" ]]; then
      text+=$'\n'"${api_err}"
    fi
  fi
fi

# Caller-only narrowing: when an agent is paired with multiple chats (DM +
# group), the original "ping everyone in access.json" approach made an
# unrelated group buzz every time a single user's session hit the limit.
# Scan the transcript for the most-recent telegram <channel> inbound and
# ping only that chat. Fall back to all paired chat_ids if there's no
# inbound (autonomous task — silencing would lose visibility entirely).
# Same narrowed CSV is passed to resume-after-reset.sh below, so the
# "agent resumed" follow-up also stays scoped to the caller.
caller_chat_id=""
if [[ -n "$transcript_path" && -r "$transcript_path" ]]; then
  caller_chat_id=$(jq -rs '
    [ .[]
      | select(.type == "user")
      | (.message.content | tostring)
      | scan("source=\"plugin:telegram:telegram\" chat_id=\"([0-9]+)\"")
      | .[0]
    ] | last // ""
  ' "$transcript_path" 2>/dev/null)
fi

if [[ -n "$caller_chat_id" ]]; then
  chat_ids="$caller_chat_id"
else
  access_file="${HOME}/.claude/channels/telegram/access.json"
  chat_ids=$(jq -r '(.allowFrom // []) + ((.groups // {}) | keys) | .[]' "$access_file" 2>/dev/null)
fi

for chat_id in $chat_ids; do
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${text}" \
    -o /dev/null 2>/dev/null || true
done

# Detach the recovery helper for rate-limit failures. The helper handles
# menu polling, the wait, "continue" injection, and the resume ping — none
# of which are bounded by the hook's 10s timeout. Skipped if we don't have
# tmux context (can't press anything) or a reset epoch (don't know when to
# resume).
if $is_rate_limit && [[ -n "$reset_epoch_num" && -n "${TMUX:-}" ]]; then
  tmux_socket=$(printf '%s' "$TMUX" | cut -d, -f1)
  tmux_target=$(tmux display -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)
  chat_ids_csv=$(printf '%s\n' $chat_ids | paste -sd, -)
  resume_helper="/usr/local/lib/5dive/resume-after-reset.sh"
  if [[ -n "$tmux_target" && -x "$resume_helper" ]]; then
    # Log dir: /var/lib/5dive/resume isn't writable by agent users
    # (parent is mode 2750 root:claude). Fall back to ~/.cache/5dive/resume
    # which the agent owns. /tmp as a last-ditch fallback.
    log_dir="${HOME}/.cache/5dive/resume"
    if ! mkdir -p "$log_dir" 2>/dev/null; then
      log_dir="/tmp"
    fi
    log_file="${log_dir}/resume-$(date +%s)-$$.log"
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
      setsid "$resume_helper" "$reset_epoch_num" "$tmux_socket" "$tmux_target" "$chat_ids_csv" \
      >"$log_file" 2>&1 < /dev/null &
    disown 2>/dev/null || true
  fi
fi

# DIVE-72: tee a native mobile push alongside the Telegram relay. Only genuine
# failures (rate-limit pauses auto-resume via the helper above, so they don't
# push). Fully isolated: backgrounded, output discarded, and a no-op on boxes
# without a connectord token — can never block or fail this hook.
push_helper="/usr/local/lib/5dive/push-notify.sh"
if ! $is_rate_limit && [[ -x "$push_helper" ]]; then
  "$push_helper" error "$msg" >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

exit 0
