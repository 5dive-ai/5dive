# shellcheck shell=bash
# DIVE-7118 — did the seat's OWN last turn get refused by its AI account?
#
# Every green on a seat was measured somewhere other than the path the seat
# uses. `auth status --probe` runs `claude --print` (headless), and the live QA
# box's Anthropic key answered that and refused the seat's interactive turns
# ("Credit balance is too low"): the account allows one client and not the
# other. `agent list`/`agent info` read the credential FILE, which was present.
# So the probe said ok, the list said AUTH ok / STATE ready, and the heartbeat
# kept dispatching rows into a seat that could not answer one message.
#
# The one reading that is the seat's own path is the seat's own transcript.
# Claude Code writes a refused turn into it as an assistant record with
# `isApiErrorMessage: true`, and tags the class: `error: "billing_error"` for a
# credit balance, `"authentication_failed"` for a bad key or a lapsed login
# (2.1.311). Only those two classes count. A rate limit or an overloaded API
# rolls back on its own and has its own handling (DIVE-3465, DIVE-5624); a
# refusal needs a person to fix the account.
#
# Only a refusal written SINCE the seat last started counts, so the owner's fix
# (a new key, which restarts the seat) clears it without waiting for a turn, and
# the seat's next real turn is the next measurement.
#
# Same parse in the `agent list` snapshot (python, src/cmd_agent.sh
# seat_refusal); tests/selfhost_head_agent_unit.sh drives both on one fixture.

# The text arm is for a Claude Code that does not tag `error` yet.
SEAT_REFUSAL_TEXT_RE='credit balance is too low|invalid api key|not logged in|please run /login|oauth token (has expired|revoked)|organization has been disabled'

# seat_started_epoch <name> — when the seat's unit last became active, 0 when
# that cannot be read (0 counts every refusal: unknown is not "restarted since").
# DIVE-7331: --timestamp=unix needs systemd 251. Ubuntu 22.04's 249 refuses the
# whole call ("Invalid value: unix."), so fall back to --timestamp=utc (247+),
# which prints "Sun 2026-07-19 13:13:35 UTC".
seat_started_epoch() {
  local ts="" e="" flag
  for flag in --timestamp=unix --timestamp=utc; do
    ts=$(systemctl show -p ActiveEnterTimestamp --value "$flag" "5dive-agent@${1}.service" 2>/dev/null) && break
    ts=""
  done
  e="${ts#@}"
  if [[ "$ts" =~ ^[A-Za-z]{3}\ ([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?\ UTC$ ]]; then
    e=$(date -u -d "${BASH_REMATCH[1]}" +%s 2>/dev/null) || e=0
  fi
  [[ "$e" =~ ^[0-9]+$ ]] || e=0
  printf '%s\n' "$e"
}

# DIVE-7118 (customer-hit, witty-palm): the second way a seat cannot answer.
# Four seats on one login woke every 30 min and stopped with no output: Claude
# Code's StopFailure kind 'stop', an API error that is neither a rate limit nor a
# credit balance, so nothing above named it and DIVE-6734 kept every notice of it
# silent. One such error is noise; a RUN of them is a stuck login. A seat is
# `failing` when its last SEAT_FAILING_TURNS turns all ended in an API error that
# is not a rate limit or a passing overload, or when such a run has lasted
# SEAT_FAILING_SECS. Two readings make a failed turn:
#   * an API-error record in the transcript (Claude Code writes one per error);
#   * a turn with NO reply at all, when the telegram plugin's StopFailure hook
#     stamped a 'stop' after it began. The hook keeps one stamp per episode,
#     ~/.cache/5dive-telegram/resume/notify-<login>_stop_<route>-noepoch.stamp,
#     holding the time of the latest stop in ms. A rate limit, a credit wall,
#     the terms wall and a transient error each get their own kind, never 'stop'.
SEAT_FAILING_TURNS="${SEAT_FAILING_TURNS:-3}"
SEAT_FAILING_SECS="${SEAT_FAILING_SECS:-3600}"
SEAT_PASSING_ERROR_RE='overloaded|api error: 5[0-9][0-9]|internal server error|temporarily'

# _seat_recent_records <name> — the tail of the seat's newest top-level
# transcripts (subagent sidechains live one level deeper), oldest first, then one
# {"__stop_ms": N} line with the newest 'stop' stamp (0 when there is none). Five
# files, because a heartbeat seat that is woken fresh opens a new one per wake.
# Root reads them directly; anyone else through the seat's own user.
# Test seams: SEAT_TRANSCRIPT_ROOT (a directory holding <project>/<id>.jsonl) and
# SEAT_STOP_STAMP_DIR (the resume directory).
_seat_recent_records() {
  local name="$1" raw=""
  local home="${AGENT_HOME_ROOT:-/home}/agent-${name}"
  local root="${SEAT_TRANSCRIPT_ROOT:-$home/.claude/projects}"
  local stamps="${SEAT_STOP_STAMP_DIR:-$home/.cache/5dive-telegram/resume}"
  # shellcheck disable=SC2016
  local script='ls -1t "$1"/*/*.jsonl 2>/dev/null | head -n 5 | tac | while IFS= read -r f; do tail -n 400 "$f"; done
m=0; for s in "$2"/notify-*_stop_*.stamp; do [ -f "$s" ] || continue; v=$(head -c 20 "$s" | tr -cd 0-9); [ -n "$v" ] && [ "$v" -gt "$m" ] && m=$v; done
printf "{\"__stop_ms\":%s}\n" "$m"'
  if [[ -n "${SEAT_TRANSCRIPT_ROOT:-}" || "$(id -u)" == 0 ]]; then
    raw=$(sh -c "$script" _ "$root" "$stamps" 2>/dev/null) || raw=""
  else
    raw=$(sudo -n -u "agent-${name}" sh -c "$script" _ "$root" "$stamps" 2>/dev/null) || raw=""
  fi
  [[ -n "$raw" ]] || return 1
  printf '%s\n' "$raw"
}

# seat_turn_trouble <name> [since-epoch] — "<refused|failing>\t<what happened>",
# rc 0, when the seat cannot answer; rc 1 for anything else, including an
# unreadable transcript: no reading is not trouble, and this must never turn a
# healthy seat red. Only turns at or after since count.
seat_turn_trouble() {
  local name="$1" since="${2:-0}" raw out
  [[ "$since" =~ ^[0-9]+$ ]] || since=0
  raw=$(_seat_recent_records "$name") || return 1
  # A turn is a prompt (a user record that is not a tool result) and the last
  # assistant record after it. fromjson? because `tail` can cut a record.
  out=$(jq -R -n -r --argjson since "$since" --arg re "$SEAT_REFUSAL_TEXT_RE" --arg pass "$SEAT_PASSING_ERROR_RE" \
          --argjson want "$SEAT_FAILING_TURNS" --argjson secs "$SEAT_FAILING_SECS" '
    def ts: (.timestamp // "") | sub("\\.[0-9]+"; "") | (try fromdateiso8601 catch 0);
    def prompt: .type == "user" and (.isMeta != true)
      and ((.message.content | type) == "string"
           or ([.message.content[]? | select(.type == "tool_result")] | length) == 0);
    def say: if .text == "" then .error else .text end;
    [inputs | fromjson? | select(type == "object")] as $all
    | (([$all[] | .__stop_ms? // empty | numbers] | max // 0) / 1000 | floor) as $stop
    | [$all[] | select(has("__stop_ms") | not)]
    | reduce .[] as $r ([];
        if ($r | prompt) then . + [{pt: ($r | ts), out: null}]
        elif $r.type == "assistant" then
          (if length == 0 then [{pt: ($r | ts), out: null}] else . end)
          | .[-1].out = {err: ($r.isApiErrorMessage == true), error: ($r.error // ""), t: ($r | ts),
                         text: ([$r.message.content[]? | select(.type == "text") | .text] | join(" "))}
        else . end)
    | map(if .out != null then .out
          elif $stop > 0 and .pt > 0 and .pt <= $stop then
            {err: true, error: "stop", t: .pt, text: "stopped with no reply (StopFailure stop)"}
          else empty end
          | select(.t >= $since))
    | if length == 0 then empty else
        .[-1] as $last
        | if $last.err and (($last.error == "billing_error") or ($last.error == "authentication_failed")
                            or ($last.text | test($re; "i")))
          then "refused\t\($last | say)"
          else
            (reverse | (map(.err and .error != "rate_limit" and ((.text | test($pass; "i")) | not))
                        | index(false)) // length) as $n
            | if $n == 0 then empty else
                .[length - $n] as $first
                | if $n >= $want or ($n >= 2 and ($last.t - $first.t) >= $secs)
                  then "failing\t\($n) turns in a row failed since \($first.t | todate): \($last | say)"
                  else empty end
              end
          end
      end' <<<"$raw" 2>/dev/null) || return 1
  [[ -n "$out" ]] || return 1
  out="${out//$'\n'/ }"
  printf '%s\n' "${out:0:240}"
}

# seat_account_refusal <name> [since-epoch] — what went wrong, rc 0, when the
# seat cannot answer (either kind). The kind is seat_turn_trouble's first field.
seat_account_refusal() {
  local t
  t=$(seat_turn_trouble "$@") || return 1
  printf '%s\n' "${t#*$'\t'}"
}
