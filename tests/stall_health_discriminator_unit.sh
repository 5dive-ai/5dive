#!/usr/bin/env bash
# DIVE-3594 unit: the stall-health pane scrape must not assert "Rate-limited"
# without the reset time that would evidence it.
#
# The defect (lodar, 2026-08-18 20:21Z, /dashboard/agents/claude-tom): the agent
# page showed "Rate-limited · no reset time shown · clears automatically" for an
# agent idle at a clean prompt. `agent stats claude-tom --json` re-run minutes
# later returned health:null — the box never thought it was rate-limited. The
# scrape had matched its keyword alternation against pane furniture and then
# filled the detail field, the only thing that could have supported the claim,
# with the literal string "no reset time shown".
#
# What is graded here is the verdict in BOTH directions, because a scraper that
# never fires is as useless as one that cries wolf:
#   - a keyword match with NO parseable reset emits NOTHING (the ticket);
#   - a keyword match with a real reset still emits cause=rate_limited, detail
#     carrying that reset — every clock/date/duration shape the CLIs print;
#   - the "reset" word alone is not a reset time (`/reset`, "reset your
#     password", a pane quoting the scraper's own regex — the live shape this
#     harness's author's own pane was in while writing it);
#   - the auth verdict is untouched, and a clean pane stays silent.
# Pure, no root, no tmux, no network:
#   bash tests/stall_health_discriminator_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/a2a_rounds.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f" 2>/dev/null || true
done
# shellcheck source=/dev/null
source "$SRC/cmd_agent_runtime.sh"

declare -F stall_health_from_pane >/dev/null \
  || { echo "PRECONDITION FAIL: stall_health_from_pane not defined"; exit 1; }
declare -F stall_reset_time >/dev/null \
  || { echo "PRECONDITION FAIL: stall_reset_time not defined"; exit 1; }

fail=0
# Empty blob -> the literal "none": jq prints NOTHING for empty input, and a
# grader comparing "" to "" would pass for a function that had crashed.
verdict() { local b c; b=$(stall_health_from_pane "$1"); [[ -n "$b" ]] || { echo none; return; }; c=$(jq -r '.cause // "none"' <<<"$b" 2>/dev/null); echo "${c:-unparseable}"; }
detail()  { stall_health_from_pane "$1" | jq -r '.detail // ""'    2>/dev/null || echo ""; }
check()   { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want='$3' got='$2')"; fail=1; fi; }

# --- (a) THE TICKET: keyword present, no reset time anywhere ---------------
# A claude boot/restart pane advertising its own slash commands. `rate limit`
# is furniture here, not a verdict. Old code: {cause:"rate_limited",
# detail:"no reset time shown"} -> the banner lodar saw.
boot_pane='
 ✻ Welcome to Claude Code
   /help for help, /status for your current setup
   /rate-limit-options   configure what happens at your rate limit
   /clear                clear conversation history

> '
check "boot pane advertising /rate-limit-options is NOT a rate-limit verdict" \
      "$(verdict "$boot_pane")" "none"
check "...and emits an empty blob, not one with a placeholder detail" \
      "$(stall_health_from_pane "$boot_pane")" ""

# (a2) An agent whose own scrollback contains the phrase — the live shape:
# captured verbatim from this harness author's pane while writing this test.
# The word "resets" is present, so the OLD reset grab succeeded and produced
# shell fragments as the customer-facing detail.
self_ref_pane='$ grep -inE "session limit|usage limit|rate limit|resets?" ; done;
dev MATCH reset='"'"'resets?" ; done;'"'"'
> '
check "a pane merely QUOTING the patterns is not a rate-limit verdict" \
      "$(verdict "$self_ref_pane")" "none"

# --- (b) TRUE POSITIVES: a real banner still fires, with its reset ---------
while IFS='|' read -r label pane want; do
  [[ -n "$label" ]] || continue
  check "fires: $label" "$(verdict "$pane")" "rate_limited"
  d="$(detail "$pane")"
  case "$d" in
    *"$want"*) echo "ok: detail carries the reset ($label)" ;;
    *) echo "FAIL: detail lost the reset ($label): want substring '$want' got '$d'"; fail=1 ;;
  esac
done <<'CASES'
claude 5h limit, clock reset|You've hit your usage limit. Resets at 9:00pm (America/Los_Angeles)|9:00pm
bare am/pm|Session limit reached · resets 9am|9am
ISO date|usage limit reached, resets 2026-08-19T04:00:00Z|2026-08-19
relative duration|You are rate limited. Resets in 2h 15m.|2h
minutes spelled out|hit your session limit — resets in 43 minutes|43 min
CASES

# --- (c) "reset" WITHOUT a time is not a reset time ------------------------
check "keyword + '/reset' slash command only" \
      "$(verdict 'usage limit info: type /reset to clear the conversation')" "none"
check "keyword + prose 'reset your password'" \
      "$(verdict 'rate limit docs: reset your password if sign-in fails')" "none"
check "stall_reset_time returns empty on a bare 'resets' fragment" \
      "$(stall_reset_time 'resets soon')" ""
check "stall_reset_time keeps a real fragment" \
      "$(stall_reset_time 'resets at 9:00pm')" "resets at 9:00pm"

# --- (d) NEGATIVE CONTROLS: the other verdicts are untouched --------------
check "clean idle prompt stays silent" "$(verdict '> ready when you are')" "none"
check "empty pane (unreadable / not root) stays silent" "$(verdict '')" "none"
check "login screen still reports auth" \
      "$(verdict 'Please sign in to continue')" "auth"
# The ticket's fix must not have widened itself into the auth arm: an auth pane
# carries no reset time and must STILL fire.
check "auth verdict does not require a reset time" \
      "$(verdict 'Authenticate to continue — no reset time here')" "auth"

# --- (e) POSITIVE CONTROL on the harness itself ---------------------------
# If this ever prints ok, the grader is comparing nothing to nothing.
if [[ "$(verdict 'You have hit your usage limit. Resets at 9:00pm')" == "rate_limited" ]]; then
  echo "ok: positive control — the scraper CAN still fire"
else
  echo "FAIL: positive control — the scraper never fires, every 'none' above is vacuous"; fail=1
fi

if (( fail )); then echo "RESULT: FAIL"; else echo "RESULT: PASS"; fi
# DIVE-2013 / harness-verdict-probe: the verdict must be the LAST executable
# line and in a shape the probe can identify, else `unit-tests/changed-harnesses`
# reports this file UNPROBEABLE and reds — the one PR arm that grades a newly
# added harness. `exit $(( fail > 0 ))` is one of the four shapes it knows; an
# `if ... exit 1 ... else exit 0 ... fi` verdict is none of them.
exit $(( fail > 0 ))
