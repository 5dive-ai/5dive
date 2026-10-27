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
# seat_refusal); tests/seat_account_refusal_unit.sh drives both on one fixture.

# The text arm is for a Claude Code that does not tag `error` yet.
SEAT_REFUSAL_TEXT_RE='credit balance is too low|invalid api key|not logged in|please run /login|oauth token (has expired|revoked)|organization has been disabled'

# seat_started_epoch <name> — when the seat's unit last became active, 0 when
# that cannot be read (0 counts every refusal: unknown is not "restarted since").
seat_started_epoch() {
  local ts="" e=""
  ts=$(systemctl show -p ActiveEnterTimestamp --value --timestamp=unix "5dive-agent@${1}.service" 2>/dev/null) || ts=""
  e="${ts#@}"
  [[ "$e" =~ ^[0-9]+$ ]] || e=0
  printf '%s\n' "$e"
}

# _seat_last_assistant_record <name> — the last assistant record of the seat's
# newest top-level transcript (subagent sidechains live one level deeper), or
# nothing. Root reads it directly; anyone else through the seat's own user.
# SEAT_TRANSCRIPT_ROOT is the test seam (a directory holding <project>/<id>.jsonl).
_seat_last_assistant_record() {
  local name="$1" raw=""
  local root="${SEAT_TRANSCRIPT_ROOT:-${AGENT_HOME_ROOT:-/home}/agent-${name}/.claude/projects}"
  # shellcheck disable=SC2016
  local script='f=$(ls -1t "$1"/*/*.jsonl 2>/dev/null | head -n 1); [ -n "$f" ] && tail -n 400 "$f"'
  if [[ -n "${SEAT_TRANSCRIPT_ROOT:-}" || "$(id -u)" == 0 ]]; then
    raw=$(sh -c "$script" _ "$root" 2>/dev/null) || raw=""
  else
    raw=$(sudo -n -u "agent-${name}" sh -c "$script" _ "$root" 2>/dev/null) || raw=""
  fi
  [[ -n "$raw" ]] || return 1
  # fromjson? because `tail` can cut the first line mid-record.
  jq -R -c 'fromjson? | select(.type == "assistant")' <<<"$raw" 2>/dev/null | tail -n 1
}

# seat_account_refusal <name> [since-epoch] — prints the refusal (trimmed), rc 0,
# when the seat's last turn was refused by its AI account at or after since.
# rc 1 for anything else, including an unreadable transcript: no reading is
# not a refusal, and this must never turn a healthy seat red.
seat_account_refusal() {
  local name="$1" since="${2:-0}" rec txt
  [[ "$since" =~ ^[0-9]+$ ]] || since=0
  rec=$(_seat_last_assistant_record "$name") || return 1
  [[ -n "$rec" ]] || return 1
  txt=$(jq -r --argjson since "$since" --arg re "$SEAT_REFUSAL_TEXT_RE" '
    select(.isApiErrorMessage == true)
    | ((.timestamp // "") | sub("\\.[0-9]+"; "") | (try fromdateiso8601 catch 0)) as $t
    | select($t >= $since)
    | ([.message.content[]? | select(.type == "text") | .text] | join(" ")) as $x
    | select((.error == "billing_error") or (.error == "authentication_failed") or ($x | test($re; "i")))
    | if $x == "" then (.error // "refused") else $x end' <<<"$rec" 2>/dev/null) || return 1
  [[ -n "$txt" ]] || return 1
  txt="${txt//$'\n'/ }"
  printf '%s\n' "${txt:0:200}"
}
