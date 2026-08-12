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
# Two controls, and they are DELIBERATELY NOT THE SAME STRENGTH. The dividing
# principle, and the reason this file reads the way it does:
#
#   **A control may only refuse what it can actually identify.**
#
#   1. ACK REFUSAL — a REFUSAL. A send that is substantially "ack / agreed /
#      taking it / thank you" carrying no RESULT or EVIDENCE is the round that
#      should never have been sent, and the detector can SEE that it carries
#      nothing. Refused regardless of round count, and never recorded.
#   2. ROUND CAP — a WARNING. A counter cannot tell agreement from a CORRECTION,
#      and the correction is the expensive one to lose.
#
# The row as filed said "Refuse, not warn" for both. That was overturned on the
# gate (main, 2026-08-12 06:36Z) by a day of evidence, and the evidence is the
# strongest argument in this file: on DIVE-3320 that same day, EVERY message that
# made the work right arrived at round 3 or later — dev2's local-path-origin
# correction (502 phantom commits), dev's multi-commit-squash correction (the
# instrument was blind to the exact case it was introduced for), ops's `--all`
# correction (19,060 was an artifact), plus the two rounds that produced the
# STAGED-vs-SAFE distinction. A hard cap at round 3 would have shipped a wrong
# recipe to eight seats.
#
# So the counter warns and the detector refuses. That is not a softening — it is
# the cap pointed at the failure mode it can actually see. The rule exists to stop
# two agents AGREEING at length, and an acknowledgement is the one shape that is
# provably agreement.
#
# NO SENDER IS EXEMPT BY ROLE. The lead was the largest single sender in the
# measurement above (96 of 222 sends, 49% of volume), so a lead exemption
# exempts the problem.

# One round = one send in one direction on one topic. The cap is per DIRECTED
# pair, so each side gets A2A_ROUND_CAP turns before the WARNING starts: at cap 2
# a topic affords A->B, B->A, A->B, B->A — "two exchanges per topic" — and the
# third round in either direction is warned about, by name, with the count and the
# remedy. Deliberately not overridable by env: an override is the exemption this
# control exists to remove.
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

# The ack SHAPES, and the FILLER that can legally sit between them. Neither list
# is a refusal on its own — see a2a_is_ack, which refuses only what is left after
# every one of them has been removed.
A2A_ACK_PHRASES=(
  ack acked acknowledged agreed agree "got it" "will do" "taking it"
  "taking this" "taking care of it" "on it" thanks "thank you" thx
  "sounds good" "makes sense" noted understood roger "+1" sgtm lgtm
  confirmed "no objection" "no notes" "nothing to add" "fair enough"
  "you are right" "you're right" "good catch" "will ping" "will ping you"
  "will report back" "will let you know" "will do it" "doing it"
)
# Words that carry nothing on their own: connectives, pronouns and pleasantries.
# Removed so "got it — taking this one, thanks" reduces to empty, and so an ack
# is not spared by a trailing "too".
A2A_ACK_FILLER=(
  and but so then also too as "as well" now "for now" "right now" ok okay
  yes yeah yep yup sure cool great perfect nice np "no problem" "of course"
  it this that one them "the rest" "that one" "this one" "will be" i "i will"
  "me too" "same here" "for sure" "no worries" anyway again already still
)

# Trim leading and trailing whitespace/punctuation. Applied only AFTER a phrase
# match has been tried on the string as it stands, because trimming first would
# eat the "+" of "+1" and leave a bare digit that no phrase matches.
a2a__trim_edges() {
  local s="$1"
  while [[ -n "$s" && "$s" == [[:space:][:punct:]]* ]]; do s="${s#?}"; done
  while [[ -n "$s" && "$s" == *[[:space:][:punct:]] ]]; do s="${s%?}"; done
  printf '%s' "$s"
}

# True when the body is substantially an acknowledgement.
#
# THE TEST IS ON THE RESIDUE, NOT THE OPENER — and that distinction is the whole
# correctness of this function (main2, iteration 1 of DIVE-3318). An earlier
# version refused a body that STARTED with an ack phrase and carried none of our
# house section words. But corrections open with agreement in ordinary English:
# "good catch — it was 19,060 because --all counted the artifact rows too",
# "you're right, the sha is c391971 not c391972", "agreed. do not merge yet".
# Every one of those was hard-refused, which is precisely the message the gate
# answer protected by name — a heuristic anti-correlated with what it must spare.
# Testing for our RESULT/EVIDENCE vocabulary does not rescue it either: that is a
# vocabulary test, and this ships as an OSS CLI where nobody types "RESULT:".
#
# So: strip every ack phrase, filler word and piece of punctuation from the body,
# repeatedly, and refuse only if NOTHING IS LEFT. "agreed" -> empty -> refused.
# "agreed. do not merge yet" -> "do not merge yet" -> sent. This keeps the design's
# own principle honest — a control may only refuse what it can IDENTIFY — because
# an empty residue is a claim about the WHOLE body, not about its first token.
a2a_is_ack() {
  local msg="$1" body
  # Strip any [5dive-msg ...] envelope, lowercase, collapse whitespace.
  body="${msg#\[5dive-msg*\] }"
  body="$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')"
  body="${body#"${body%%[![:space:]]*}"}"
  body="${body%"${body##*[![:space:]]}"}"

  # Carries substance or asks a question -> not an ack, whatever it opens with.
  # Kept as a cheap early exit; the residue test below is what actually decides,
  # and it does not depend on this house vocabulary being present.
  case "$msg" in
    *RESULT*|*EVIDENCE*|*BLOCKER*|*NEXT*|*'?'*) return 1 ;;
  esac

  # Long bodies are not acks. 240 chars is comfortably above every "ack, taking
  # it, will ping when the run lands" and below anything carrying an argument.
  (( ${#body} <= 240 )) || return 1

  local residue="$body" prev="" p matched
  while [[ "$residue" != "$prev" ]]; do
    prev="$residue"
    matched=0
    for p in "${A2A_ACK_PHRASES[@]}" "${A2A_ACK_FILLER[@]}"; do
      # Whole-word match, so "acknowledged" matches but "acking the release"
      # does not become an ack by sharing three letters with one.
      if [[ "$residue" == "$p" ]]; then residue=""; matched=1; break; fi
      if [[ "$residue" == "$p"[^a-z0-9]* ]]; then
        residue="${residue#"$p"}"; matched=1; break
      fi
    done
    (( matched )) || residue="$(a2a__trim_edges "$residue")"
  done
  [[ -z "$residue" ]]
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
  printf '%s' "refused: after removing the acknowledgement itself this message says nothing — every word of it is \"ack\" / \"agreed\" / \"taking it\" / \"thanks\" or filler. Those are terminal: the other agent does not need to be told you received it, and an inbound costs them a full re-investigation, which is the real price of a round (not its length). Add the thing you actually want them to know — a result, a measurement, a disagreement, even one clause — and send that. A message that opens with \"agreed\" and then says something is NOT refused."
}

# The ROUND text is a warning, not a refusal, and it says so. It names the count,
# cites the rule and names the remedy — the three things that let a sender decide
# for themselves — and then gets out of the way. It explicitly blesses the one case
# the counter cannot see, so a correction is never talked out of being sent.
a2a_round_warning_msg() {
  local from="$1" to="$2" topic="$3" n="$4"
  local where
  if [[ "$topic" == "pair" ]]; then
    where="a task row"
  else
    where="$topic"
  fi
  printf 'a2a round cap: this is %s round %s to %s on %s — over the cap of %s per topic per direction. If this is another pass at agreement, put it in the row body (`5dive task set-body %s`) and let them read it once. If it is a CORRECTION or carries a measurement, send it: this is a warning precisely because a round counter cannot tell those apart, and a lost correction costs more than an extra round. Rounds age out after %sh.' \
    "$from" "$(( n + 1 ))" "$to" "$where" "$A2A_ROUND_CAP" "$where" "$(( A2A_ROUND_WINDOW_SECS / 3600 ))"
}

# The guard both send paths call, AFTER the body and both endpoints are
# resolved and BEFORE a keystroke reaches the target's pane.
#
# TWO CHANNELS, and the split is the whole design:
#   - a REFUSAL (ack only) goes to STDOUT and returns non-zero. The caller decides
#     how to fail, so the audit row and exit code stay owned by the command.
#   - a WARNING (round cap) goes to STDERR and returns ZERO. The send proceeds.
#     stderr, because the callers capture stdout in a command substitution — a
#     warning written to stdout would be swallowed into the refusal variable and
#     shown to nobody, which is the same silent control this row exists to fix.
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
    a2a_round_warning_msg "$from" "$to" "$topic" "$n" >&2
    printf '\n' >&2
  fi
  # Recorded on EVERY round, including the ones past the cap. The count is what
  # the digest reports and what makes an over-cap pair visible; stopping the
  # ledger at the cap would make the loudest conversations the least legible.
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
  printf '\n\U0001F4EC A2A rounds — last %sh (soft cap %s per topic per direction; over-cap warns, it does not refuse)\n' \
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
        for (k in n) if (n[k] >= cap) { if (hot++ == 0) print "  over the cap (next round warns):"; print "  • " k }
        if (hot == 0) print "  no topic is over the cap"
      }' "$A2A_ROUND_LEDGER" 2>/dev/null
  else
    printf '  (round ledger not readable here: %s)\n' "$A2A_ROUND_LEDGER"
  fi
}
