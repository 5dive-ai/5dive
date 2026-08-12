#!/usr/bin/env bash
# DIVE-3318: enforce a ROUND cap on agent-to-agent sends.
#
# Why rounds and not characters. `agent-audit.log` already carries `bytes=` on
# every send. 24h to 2026-08-12: 222 sends, 387 KB fleet-wide — ~99k tokens of
# TEXT against ~97M tokens of fleet burn, **under 0.5%**. Message LENGTH is not
# the cost, so a character cap targets the wrong axis and would strip exactly
# the evidence blocks worth sending. The cost is that each inbound makes the
# recipient re-read logs, re-check state and re-derive: a 2 KB message is
# answered with twenty tool calls. That is also why "be concise" does not work —
# concision does not reduce the digging a message provokes.
#
# Two controls, both refusals (a warning an agent may ignore is the rule we
# already have in CLAUDE.md, and it is unenforced — that is what this row is
# for):
#
#   1. ROUND CAP per (sender, recipient, topic). Third round refused.
#   2. ACK REFUSAL. A send that is substantially "ack / agreed / taking it /
#      thank you" carrying no RESULT or EVIDENCE is the round that should never
#      have been sent. Refused regardless of round count, and never recorded.
#
# NO SENDER IS EXEMPT BY ROLE. The lead was the largest single sender in the
# measurement above (96 of 222 sends, 49% of volume), so a lead exemption
# exempts the problem.

# One round = one send in one direction on one topic. The cap is per DIRECTED
# pair, so each side gets A2A_ROUND_CAP turns: at cap 2 a topic affords
# A->B, B->A, A->B, B->A — "two exchanges per topic", and the third round in
# either direction is refused. Deliberately not overridable by env: an override
# is the exemption this control exists to remove.
A2A_ROUND_CAP=2

# Rounds age out, so a topic is not silenced forever by a conversation that
# happened yesterday. 24h matches the window the measurement above was taken
# over. A topic that needs a fifth message inside one day is a document.
A2A_ROUND_WINDOW_SECS=86400

A2A_ROUND_LEDGER="${A2A_ROUND_LEDGER:-${STATE_DIR:-/var/lib/5dive}/a2a-rounds.tsv}"

# The topic a send is about: the first task ident in the body. Rows are how this
# fleet names a subject, and an ident is in the message on nearly every real
# send. With no ident the pair itself is the topic — two agents chatting with no
# row to point at is precisely the traffic the cap should bite hardest on, not
# an exit from it.
a2a_topic_of() {
  local msg="$1" ident=""
  [[ "$msg" =~ ([A-Z][A-Z0-9]+-[0-9]+) ]] && ident="${BASH_REMATCH[1]}"
  printf '%s' "${ident:-pair}"
}

# True when the body is substantially an acknowledgement. Two conditions, both
# required, because either alone is wrong:
#
#   - it MATCHES an ack shape, and
#   - it carries no RESULT/EVIDENCE/BLOCKER/NEXT section and asks nothing.
#
# The second half is what keeps a real message that merely OPENS with "agreed —"
# and then delivers a measurement from being refused. A bare "ack" is terminal;
# "agreed, and here is the count" is not an ack, it is a result.
a2a_is_ack() {
  local msg="$1" body
  # Strip any [5dive-msg ...] envelope, lowercase, collapse whitespace.
  body="${msg#\[5dive-msg*\] }"
  body="$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')"
  body="${body#"${body%%[![:space:]]*}"}"
  body="${body%"${body##*[![:space:]]}"}"

  # Carries substance or asks a question -> not an ack, whatever it opens with.
  case "$msg" in
    *RESULT*|*EVIDENCE*|*BLOCKER*|*NEXT*|*'?'*) return 1 ;;
  esac

  # Long bodies are not acks. 240 chars is comfortably above every "ack, taking
  # it, will ping when the run lands" and below anything carrying an argument.
  (( ${#body} <= 240 )) || return 1

  local p
  for p in ack acked acknowledged agreed agree "got it" "will do" "taking it" \
           "taking this" "on it" thanks "thank you" thx "sounds good" \
           "makes sense" noted understood roger "+1" sgtm lgtm confirmed \
           "no objection" "no notes" "nothing to add" "fair enough" \
           "you are right" "you're right" "good catch"; do
    # Prefix match on a WORD boundary, so "acknowledged" matches but "acking the
    # release" does not become an ack by sharing three letters with one.
    [[ "$body" == "$p" ]] && return 0
    [[ "$body" == "$p"[^a-z0-9]* ]] && return 0
  done
  return 1
}

# Rounds already spent on (from -> to, topic) inside the window. Unreadable or
# absent ledger counts 0: this control refuses sends, and a control that
# fails CLOSED on its own missing state would silence the fleet on a fresh box.
# The failure mode is chosen deliberately and is stated here so it is not read
# later as an oversight.
a2a_round_count() {
  local from="$1" to="$2" topic="$3" now cutoff n=0
  printf -v now '%(%s)T' -1
  cutoff=$(( now - A2A_ROUND_WINDOW_SECS ))
  [[ -r "$A2A_ROUND_LEDGER" ]] || { printf '0'; return 0; }
  local f t p ts
  while IFS=$'\t' read -r f t p ts; do
    [[ "$f" == "$from" && "$t" == "$to" && "$p" == "$topic" ]] || continue
    [[ "$ts" =~ ^[0-9]+$ ]] || continue
    (( ts >= cutoff )) && n=$(( n + 1 ))
  done < "$A2A_ROUND_LEDGER"
  printf '%s' "$n"
}

a2a_record_round() {
  local from="$1" to="$2" topic="$3" now
  printf -v now '%(%s)T' -1
  local dir; dir="$(dirname "$A2A_ROUND_LEDGER")"
  [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 0
  # Best-effort, like audit_log: a send is not failed by a bookkeeping write.
  printf '%s\t%s\t%s\t%s\n' "$from" "$to" "$topic" "$now" \
    >> "$A2A_ROUND_LEDGER" 2>/dev/null || return 0
  chmod 0660 "$A2A_ROUND_LEDGER" 2>/dev/null || true
  chgrp claude "$A2A_ROUND_LEDGER" 2>/dev/null || true
}

# Drop ledger lines older than the window, so the file does not grow without
# bound. Called opportunistically from the record path.
a2a_round_prune() {
  local now cutoff tmp
  printf -v now '%(%s)T' -1
  cutoff=$(( now - A2A_ROUND_WINDOW_SECS ))
  [[ -w "$A2A_ROUND_LEDGER" ]] || return 0
  tmp="${A2A_ROUND_LEDGER}.$$"
  awk -F'\t' -v c="$cutoff" '$4 ~ /^[0-9]+$/ && $4 >= c' \
    "$A2A_ROUND_LEDGER" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$A2A_ROUND_LEDGER" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

# The refusal texts. Kept as functions so the unit test grades the exact string
# an agent will read, and so both delivery paths refuse identically.
a2a_ack_refusal_msg() {
  printf '%s' "refused: this send is an acknowledgement with no RESULT or EVIDENCE. \"Ack\", \"agreed\", \"taking it\" and \"thank you\" are terminal — the other agent does not need to be told you received it, and answering an ack costs them a full re-investigation. If you have something to report, lead with RESULT or EVIDENCE and send that instead."
}

a2a_round_refusal_msg() {
  local from="$1" to="$2" topic="$3" n="$4"
  local where
  if [[ "$topic" == "pair" ]]; then
    where="a task row"
  else
    where="$topic"
  fi
  printf 'refused: %s round %s to %s on %s — the cap is %s per topic per direction. A third round is a document, not a conversation: put it in the row body (`5dive task set-body %s`) and let them read it once, instead of a send that costs them another full re-investigation. Rounds age out after %sh.' \
    "$from" "$(( n + 1 ))" "$to" "$where" "$A2A_ROUND_CAP" "$where" "$(( A2A_ROUND_WINDOW_SECS / 3600 ))"
}

# The guard both send paths call, AFTER the body and both endpoints are
# resolved and BEFORE a keystroke reaches the target's pane. Prints the refusal
# on stdout and returns non-zero; the caller decides how to fail (so the audit
# row and exit code stay owned by the command).
#
# `_5DIVE_A2A_NOTIFY=1` skips the guard. This is NOT a sender exemption and no
# agent may set it by hand: it is set only by the in-repo NOTIFICATION rails
# (`_task_need_route_deliver`, supervisor capacity/tripwire alerts), which emit
# one-way machine notices that nobody replies to and which are therefore not
# rounds. A conversation routed through it is a rule broken, not a rule obeyed.
a2a_round_guard() {
  local from="$1" to="$2" msg="$3"
  [[ "${_5DIVE_A2A_NOTIFY:-0}" == "1" ]] && return 0
  # An unmeasurable sender still gets the ack check (it needs no identity) but
  # cannot be round-counted against a pair — record nothing rather than build a
  # ledger keyed on a name we did not derive.
  if a2a_is_ack "$msg"; then
    a2a_ack_refusal_msg
    return 1
  fi
  [[ -n "$from" && -n "$to" ]] || return 0
  local topic n
  topic="$(a2a_topic_of "$msg")"
  n="$(a2a_round_count "$from" "$to" "$topic")"
  if (( n >= A2A_ROUND_CAP )); then
    a2a_round_refusal_msg "$from" "$to" "$topic" "$n"
    return 1
  fi
  a2a_record_round "$from" "$to" "$topic"
  a2a_round_prune
  return 0
}

# DIVE-3318, clause 3 of the row: report `bytes=` and round counts per sender.
# The `bytes=` data has existed on every send row since DIVE-2797 and nobody had
# ever looked at it — which is exactly why an unmeasured guess ("the messages are
# the burn") survived until it was checked. A number nothing reports is a number
# nothing corrects, so this prints on the digest, not on request.
#
# Prints a text block on stdout. Sources are named and degrade LOUDLY: the audit
# log is 0640 root:claude, so a caller who cannot read it must say so rather than
# render a quiet fleet.
a2a_rounds_report() {
  local window="${1:-86400}" log="${AUDIT_LOG:-/var/log/5dive/agent-audit.log}"
  local hours=$(( window / 3600 ))
  printf '\n\U0001F4EC A2A rounds — last %sh (cap %s per topic per direction)\n' \
    "$hours" "$A2A_ROUND_CAP"

  if [[ -r "$log" ]] && command -v awk >/dev/null 2>&1; then
    local since; printf -v since '%(%Y-%m-%dT%H:%M:%S)T' $(( $(printf '%(%s)T' -1) - window ))
    awk -v since="$since" '
      /"cmd":"agent (send|_deliver)"/ {
        ts=""; if (match($0, /"ts":"[^"]+"/)) ts=substr($0, RSTART+6, RLENGTH-7)
        if (ts != "" && ts < since) next
        f=""; if (match($0, /from_derived=[^"\\, ]+/)) f=substr($0, RSTART+13, RLENGTH-13)
        if (f == "" || f == "<unmeasured>") f="<unmeasured>"
        b=0; if (match($0, /bytes=[0-9]+/)) b=substr($0, RSTART+6, RLENGTH-6)+0
        n[f]++; by[f]+=b; tot++; totb+=b
      }
      END {
        if (tot == 0) { print "  (no sends recorded in the window)"; exit }
        for (k in n) printf "  • %s %d sends / %.0f KB\n", k, n[k], by[k]/1024
      }' "$log" 2>/dev/null | sort -t/ -k2 -rn -s || printf '  (audit scan failed)\n'
    # The fleet total is printed OUTSIDE the sort. Piping it through with the
    # per-sender lines sorted it into the middle of them, where a total reads as
    # one more sender.
    awk -v since="$since" '
      /"cmd":"agent (send|_deliver)"/ {
        ts=""; if (match($0, /"ts":"[^"]+"/)) ts=substr($0, RSTART+6, RLENGTH-7)
        if (ts != "" && ts < since) next
        b=0; if (match($0, /bytes=[0-9]+/)) b=substr($0, RSTART+6, RLENGTH-6)+0
        tot++; totb+=b
      }
      END { if (tot) printf "  = %d messages, %.0f KB of text fleet-wide (both the direct `agent send` and the scoped `agent _deliver` rails)\n", tot, totb/1024 }
    ' "$log" 2>/dev/null || true
  else
    printf '  (unreadable: %s is 0640 root:claude — run the digest as root for the per-sender split)\n' "$log"
  fi

  # Live round pressure: topics at or near the cap right now. This is the half a
  # byte count cannot show, and the half the cap actually spends.
  if [[ -r "$A2A_ROUND_LEDGER" ]]; then
    local now cutoff; printf -v now '%(%s)T' -1; cutoff=$(( now - A2A_ROUND_WINDOW_SECS ))
    awk -F'\t' -v c="$cutoff" -v cap="$A2A_ROUND_CAP" '
      $4 ~ /^[0-9]+$/ && $4 >= c { k=$1" -> "$2" on "$3; n[k]++ }
      END {
        hot=0
        for (k in n) if (n[k] >= cap) { if (hot++ == 0) print "  at the cap (next round refused):"; print "  • " k }
        if (hot == 0) print "  no topic is at the cap"
      }' "$A2A_ROUND_LEDGER" 2>/dev/null
  else
    printf '  (round ledger not readable here: %s)\n' "$A2A_ROUND_LEDGER"
  fi
}
