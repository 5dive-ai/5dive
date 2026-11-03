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
SEAT_REFUSAL_TEXT_RE='credit balance is too low|invalid api key|not logged in|please run /login|oauth token (has expired|revoked)|organization has been disabled|eligibility check failed|not eligible for antigravity'

# DIVE-7615 (live box arm, 2026-11-03, agy 1.4.12): a Google account that has not
# passed Google's age check signs in fine (the token is real, every file check
# reads ok), and then agy answers EVERY message with "Eligibility check failed:
# Your current account is not eligible for Antigravity. To use Antigravity you
# must be 18 years old or older...". agy keeps no transcript we read, so the one
# place that says so is the seat's own screen. SEAT_AGY_PANE_RE is that reading
# (seat_pane_refusal); the words the owner sees are SEAT_AGY_INELIGIBLE_MSG, not
# agy's, because "verify your age and log in again" does not say where.
SEAT_AGY_PANE_RE='eligibility check failed|not eligible for antigravity'
SEAT_AGY_INELIGIBLE_MSG="This Google account can't use Antigravity yet: Google needs to verify the account holder is 18+. Verify it at myaccount.google.com, or sign in with another account."

# seat_refusal_plain <text> — the owner's words for a refusal text: agy's
# eligibility refusal becomes SEAT_AGY_INELIGIBLE_MSG, anything else is printed
# as it came.
seat_refusal_plain() {
  if grep -qiE "$SEAT_AGY_PANE_RE" <<<"$1"; then printf '%s\n' "$SEAT_AGY_INELIGIBLE_MSG"
  else printf '%s\n' "$1"; fi
}

# _seat_pane <name> — the seat's visible screen (no scrollback: a restart, which
# is what a new sign-in does, starts a clean one). Test seam: SEAT_PANE_DIR
# holding <name>.pane.
_seat_pane() {
  local name="$1"
  if [[ -n "${SEAT_PANE_DIR:-}" ]]; then cat "$SEAT_PANE_DIR/${name}.pane" 2>/dev/null; return; fi
  sudo -n -u "agent-${name}" tmux capture-pane -t "agent-${name}" -p 2>/dev/null
}

# seat_pane_refusal <name> — SEAT_AGY_INELIGIBLE_MSG, rc 0, when <name> is an
# Antigravity seat whose screen shows agy's eligibility refusal. Lines that carry
# a 5dive message header or reply marker are skipped, so a question ABOUT the
# check cannot trip it. Only Antigravity seats are read: on any other harness the
# words are just text someone typed.
seat_pane_refusal() {
  local name="$1"
  declare -F agent_type >/dev/null 2>&1 || return 1
  [[ "$(agent_type "$name" 2>/dev/null)" == antigravity ]] || return 1
  _seat_pane "$name" | grep -vE '5dive-msg |5dive-r:' | grep -qiE "$SEAT_AGY_PANE_RE" || return 1
  printf '%s\n' "$SEAT_AGY_INELIGIBLE_MSG"
}

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
# DIVE-7527 (teal-fox, 2026-10-31): a run whose LAST failed turn is the model's
# safety filter refusing the conversation is not a stuck login. Claude Code
# writes it as error "invalid_request", text "API Error: <model>'s safeguards
# flagged this message…"; the login works, and the next session (a restart)
# answers. It reads `content-refused`, never `failing`, so nothing tells the
# owner to sign in again. The match is the text alone (any error class), the
# same words the heartbeat's _HB_CLAUDE_NOT_TRANSIENT already reads off a pane.
# It is NOT a refusal of the account, so it stays out of SEAT_REFUSAL_TEXT_RE.
SEAT_CONTENT_REFUSED_RE='safeguards flagged'

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

# DIVE-7373 — the third way a seat cannot answer, and the one that is known
# BEFORE a turn: a Hermes seat whose AI provider needs a package that is not in
# Hermes's venv. Hermes (0.21.5) leaves the Anthropic SDK out of its install and
# adds it at the seat's first message, which a seat cannot do: the venv is
# claude's, the seat's own ~/.hermes/bin has no uv, and Ubuntu's python3 has no
# ensurepip. The pane says "Your message was not sent" while the credential file
# is present, so `agent list` read AUTH ok / ready. The venv is the reading: it
# is what Hermes imports from. The fix installs into it as claude
# (TYPE_INSTALL[hermes] re-runs the step on `agent install hermes --upgrade`).
# Test seam: HERMES_AGENT_DIR.
HERMES_AGENT_DIR="${HERMES_AGENT_DIR:-/home/claude/.hermes/hermes-agent}"
HERMES_SDK_FIX="sudo 5dive agent install hermes --upgrade"

# hermes_sdk_state — "present", "missing", or "unknown" (no Hermes here, or a
# venv this caller cannot read).
hermes_sdk_state() {
  local lib="$HERMES_AGENT_DIR/venv/lib"
  if [[ ! -d "$HERMES_AGENT_DIR/tools" || ! -r "$lib" || ! -x "$lib" ]]; then echo unknown
  elif compgen -G "$lib/python3*/site-packages/anthropic/__init__.py" >/dev/null; then echo present
  else echo missing; fi
}

# hermes_missing_sdk <name> — the package name, rc 0, when <name> is a Hermes
# seat on a provider whose package Hermes's venv lacks. rc 1 for anything else,
# and for anything this caller cannot read: no reading is not trouble.
hermes_missing_sdk() {
  local name="$1" cfg provider=""
  [[ "$(hermes_sdk_state)" == missing ]] || return 1
  declare -F agent_type >/dev/null 2>&1 || return 1
  [[ "$(agent_type "$name" 2>/dev/null)" == hermes ]] || return 1
  # The seat's own config.yaml (re-seeded from claude's at every start), else
  # claude's: model.provider is what the seat connects with.
  for cfg in "${AGENT_HOME_ROOT:-/home}/agent-${name}/.hermes/config.yaml" /home/claude/.hermes/config.yaml; do
    [[ -r "$cfg" ]] || continue
    provider=$(awk '/^model:/{m=1; next} /^[^[:space:]#]/{m=0} m && /^[[:space:]]+provider:/{gsub(/["\047]/, "", $2); print $2; exit}' "$cfg")
    break
  done
  [[ "$provider" == anthropic ]] || return 1
  printf 'anthropic\n'
}

# seat_turn_trouble <name> [since-epoch] — "<refused|failing|content-refused|
# cannot-send>\t<what happened>", rc 0, when the seat cannot answer; rc 1 for anything else,
# including an unreadable transcript: no reading is not trouble, and this must
# never turn a healthy seat red. Only turns at or after since count; a
# cannot-send seat (DIVE-7373) is a fact about the box, not a turn, so it counts
# whenever it is read, and so does an Antigravity seat's screen (DIVE-7615).
seat_turn_trouble() {
  local name="$1" since="${2:-0}" raw out pkg
  [[ "$since" =~ ^[0-9]+$ ]] || since=0
  if pkg=$(hermes_missing_sdk "$name"); then
    printf "cannot-send\tHermes cannot send a message: the '%s' package its AI provider needs is not installed. Install it: %s\n" "$pkg" "$HERMES_SDK_FIX"
    return 0
  fi
  # DIVE-7615: an Antigravity seat has no transcript here; its screen is the reading.
  if pkg=$(seat_pane_refusal "$name"); then
    printf 'refused\t%s\n' "$pkg"
    return 0
  fi
  raw=$(_seat_recent_records "$name") || return 1
  # A turn is a prompt (a user record that is not a tool result) and the last
  # assistant record after it. fromjson? because `tail` can cut a record.
  out=$(jq -R -n -r --argjson since "$since" --arg re "$SEAT_REFUSAL_TEXT_RE" --arg pass "$SEAT_PASSING_ERROR_RE" \
          --arg content "$SEAT_CONTENT_REFUSED_RE" \
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
                | if ($n >= $want or ($n >= 2 and ($last.t - $first.t) >= $secs)) | not then empty
                  elif $last.text | test($content; "i")
                  then "content-refused\t\($n) turns in a row were refused by the AI safety filter since \($first.t | todate): \($last | say)"
                  else "failing\t\($n) turns in a row failed since \($first.t | todate): \($last | say)" end
              end
          end
      end' <<<"$raw" 2>/dev/null) || return 1
  [[ -n "$out" ]] || return 1
  out="${out//$'\n'/ }"
  printf '%s\n' "${out:0:240}"
}

# seat_account_refusal <name> [since-epoch] — what went wrong, rc 0, when the
# seat cannot answer (any kind). The kind is seat_turn_trouble's first field.
seat_account_refusal() {
  local t
  t=$(seat_turn_trouble "$@") || return 1
  printf '%s\n' "${t#*$'\t'}"
}
