#!/usr/bin/env bash
# DIVE-4769 — the URGENT a2a interrupt, and the price that keeps it a class.
#
# DIVE-4214 spools a send to a BUSY seat and the heartbeat flushes it at the
# seat's next idle. That is right for the 40-of-67 mid-attempt sends it was
# measured on, and wrong for exactly one shape: a directive that is only worth
# anything BEFORE the current turn finishes. Measured 2026-09-21: main tried to
# cut quinn's in-flight grade short right after lodar said "don't let quinn spend
# much"; the message could not land until quinn went idle, which for a single
# grade turn is after the grade. lodar, 07:45Z: "we need urgent ping route".
#
# THE OBJECTION THIS FILE HAS TO ANSWER. DIVE-4214 refused a caller flag by name:
# "a flag whose only cost is typing it becomes every caller's default, and a class
# everyone is in is not a class"
# (community/wiki/the-interrupting-class-is-enumerated-by-the-transport-or-it-is-every-callers-default.md).
# That argument is about COST, not about the flag, and it is answered by giving
# the flag one:
#
#   1. BOUNDED. An urgent send is capped at A2A_URGENT_MAX_BYTES. An interrupt is
#      a steer ("stop, rubber-stamp it"), never a briefing; a briefing belongs on
#      the row, where the seat reads it without losing its turn. Over the bound is
#      a REFUSAL — nothing is typed, and the caller still holds the text.
#   2. BUDGETED. A2A_URGENT_BUDGET urgent sends per SENDER per
#      A2A_URGENT_WINDOW_SECS, counted in a ledger, all targets together. A sender
#      that spends its budget is not refused (losing a genuine "stop" is worse
#      than an extra queued message) — it is DOWNGRADED to the ordinary path and
#      told so, and the receipt says `urgent:false`. This is the half that stops
#      the flag becoming a default: the fourth urgent message in an hour simply is
#      not urgent, and the sender reads that in its own receipt.
#   3. LEGIBLE AT BOTH ENDS. The envelope carries `urgent=1`, the payload opens
#      with a marker the receiving model can act on, and the audit row carries
#      `urgent=1` — so "who is interrupting whom, how often" is a countable
#      number rather than a claim.
#
# WHAT IT DOES AND DOES NOT BUY, stated because the row asked for more than the
# transport can give. `tmux send-keys` into a busy claude pane makes the payload
# that seat's NEXT USER TURN: urgent skips the spool and the heartbeat tick, so
# the steer is read as soon as the current turn ends instead of at the next idle
# flush. It does NOT preempt a running turn at a tool boundary — no keystroke
# can, that needs an in-process run-loop hook. The verb that ENDS the turn now is
# `5dive agent halt`, which aborts it and RE-QUEUES the row (cmd_halt).
#
# The ledger is a sibling of A2A_ROUND_LEDGER and deliberately copies its write
# discipline (group-writable at creation, best-effort append, prune through the
# existing inode) — the reasons are written out in full in a2a_rounds.sh and are
# not repeated here.

# Not env-overridable, for the reason the round cap is not: an override is the
# exemption the control exists to remove. The LEDGER PATH is overridable, so a
# test can drive a budget without touching the fleet's.
A2A_URGENT_BUDGET=3
A2A_URGENT_WINDOW_SECS=3600
A2A_URGENT_MAX_BYTES=400

A2A_URGENT_LEDGER="${A2A_URGENT_LEDGER:-${STATE_DIR:-/var/lib/5dive}/a2a-urgent.tsv}"

# Urgent sends by `from` inside the window. An unreadable or absent ledger counts
# 0 — this control DOWNGRADES rather than refuses, so failing open costs one
# interrupt, while failing closed on a fresh box would break the rail on the day
# it is needed.
a2a_urgent_count() {
  local from="$1" now cutoff n=0 f t ts
  printf -v now '%(%s)T' -1
  cutoff=$(( now - A2A_URGENT_WINDOW_SECS ))
  [[ -r "$A2A_URGENT_LEDGER" ]] || { printf '0'; return 0; }
  while IFS=$'\t' read -r f t ts; do
    [[ "$f" == "$from" ]] || continue
    [[ "$ts" =~ ^[0-9]+$ ]] || continue
    (( ts >= cutoff )) && n=$(( n + 1 ))
  done < "$A2A_URGENT_LEDGER"
  printf '%s' "$n"
}

a2a_urgent_record() {
  local from="$1" to="$2" now
  printf -v now '%(%s)T' -1
  local dir; dir="$(dirname "$A2A_URGENT_LEDGER")"
  [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 0
  if [[ ! -e "$A2A_URGENT_LEDGER" ]]; then
    ( umask 0117; : >> "$A2A_URGENT_LEDGER" ) 2>/dev/null || true
  fi
  chmod 0660 "$A2A_URGENT_LEDGER" 2>/dev/null || true
  chgrp claude "$A2A_URGENT_LEDGER" 2>/dev/null || true
  # Grouped redirection: see the DIVE-3658 note in a2a_rounds.sh — an ungrouped
  # `>>` reports its own permission error on a stderr that is still the terminal.
  { printf '%s\t%s\t%s\n' "$from" "$to" "$now" >> "$A2A_URGENT_LEDGER"; } 2>/dev/null || return 0
}

a2a_urgent_prune() {
  local now cutoff tmp
  printf -v now '%(%s)T' -1
  cutoff=$(( now - A2A_URGENT_WINDOW_SECS ))
  [[ -w "$A2A_URGENT_LEDGER" ]] || return 0
  tmp="$(mktemp 2>/dev/null)" || return 0
  if awk -F'\t' -v c="$cutoff" '$3 ~ /^[0-9]+$/ && $3 >= c' "$A2A_URGENT_LEDGER" > "$tmp" 2>/dev/null; then
    { cat "$tmp" > "$A2A_URGENT_LEDGER"; } 2>/dev/null || true
  fi
  rm -f "$tmp" 2>/dev/null || true
}

# The refusal (over the byte bound). Nothing is typed and nothing is lost — the
# text is still in the caller's hands, which is why this one is a hard refusal
# while the budget is not.
a2a_urgent_too_long_msg() {
  local bytes="$1"
  printf 'refused: --urgent is %s bytes and the bound is %s. An urgent interrupt is a STEER a seat can act on without reading anything else ("stop grading DIVE-1234, rubber-stamp it") — at this length it is a briefing, and a briefing read mid-turn costs the turn it interrupts. Put the detail on the row (`5dive task set-body <ident>`), send the one-line steer with --urgent, or drop --urgent and let it queue in full.' \
    "$bytes" "$A2A_URGENT_MAX_BYTES"
}

# The downgrade (budget spent). A WARNING on stderr, like the round cap, because
# the send still happens — on the ordinary path, with the ordinary receipt.
a2a_urgent_over_budget_msg() {
  local from="$1" n="$2"
  printf 'urgent budget spent: %s has already interrupted %s time(s) in the last %sh (budget %s), so this send is being delivered on the NORMAL path — it queues if the target is mid-attempt and the receipt will say `urgent:false`. The budget is what keeps an interrupt worth reading: a fourth one in an hour is a conversation, and a conversation belongs in the row body. If this really is the stop-everything one, wait for the window or use `5dive agent halt %s` to end the turn outright.' \
    "$from" "$n" "$(( A2A_URGENT_WINDOW_SECS / 3600 ))" "$A2A_URGENT_BUDGET" "${3:-<seat>}"
}

# What the receiving model actually reads. The envelope's `urgent=1` is for the
# log and for a parser; this line is for the seat, and it says the one thing the
# seat has to decide: act on this before continuing.
a2a_urgent_prefix() {
  printf '%s' 'URGENT INTERRUPT — act on this before you continue your current row, then say what you did: '
}

# The one decision both delivery paths call, so `send` and the scoped `_deliver`
# can never disagree about what --urgent means (the DIVE-2362 rule that
# _a2a_queued_reason is written under).
#
# TWO CHANNELS, copied deliberately from a2a_round_guard:
#   - a REFUSAL (over the byte bound) prints on STDOUT and returns 1. The caller
#     owns the exit code and the audit row.
#   - a DOWNGRADE (budget spent) warns on STDERR, prints `0` on stdout and
#     returns 0. The send proceeds on the ordinary path.
# On a grant it prints `1` and RECORDS the spend, before delivery: a grant that
# is only counted when the keystroke lands would let a failing target refund an
# interrupt the sender has already decided to spend.
a2a_urgent_grant() {
  local from="$1" to="$2" msg="$3" n
  if (( ${#msg} > A2A_URGENT_MAX_BYTES )); then
    a2a_urgent_too_long_msg "${#msg}"
    return 1
  fi
  # An unmeasurable sender cannot be budgeted against a name we did not derive.
  # It still gets the bound above (that needs no identity) and is granted, for
  # the same reason the round cap does not refuse one: this control's job is to
  # keep a class small, not to authenticate.
  if [[ -z "$from" ]]; then printf '1'; return 0; fi
  n="$(a2a_urgent_count "$from")"
  if (( n >= A2A_URGENT_BUDGET )); then
    a2a_urgent_over_budget_msg "$from" "$n" "$to" >&2
    printf '\n' >&2
    printf '0'
    return 0
  fi
  a2a_urgent_record "$from" "$to"
  a2a_urgent_prune
  printf '1'
  return 0
}
