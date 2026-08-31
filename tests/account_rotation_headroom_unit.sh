#!/usr/bin/env bash
# DIVE-3822: supervisor quota recovery may rotate only to a profile whose
# freshest statusline cache measures live headroom in every observed window.
#
# DIVE-3856 (iteration 2) also grades `cmd_agent_rotation_rotate`'s ENVELOPE
# here, by CALLING the verb. Iteration 1 graded it by grepping an awk-extracted
# copy of the function body — which certifies that a line of source exists, not
# that the verb emits anything, i.e. the row's own over-claim committed by its
# own tests. This harness is where that belongs: it already sources
# src/cmd_account.sh and drives the rotate path directly.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/header.sh
# shellcheck source=/dev/null
source src/cmd_account.sh

PASS=0
FAIL=0
t() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf 'FAIL: %s — expected %s, got %s\n' "$1" "$2" "$3"
  fi
}
rc_of() { if "$@"; then printf '0'; else printf '%s' "$?"; fi; }

NOW=$(date +%s)
RATELIMIT_FIXTURE=''
account_best_ratelimits() { printf '%s' "$RATELIMIT_FIXTURE"; }

RATELIMIT_FIXTURE=$(jq -cn --argjson now "$NOW" \
  '{asOf:$now,fiveHourPct:18,sevenDayPct:34}')
t "fresh low 5h + 7d is measured headroom" "0" "$(rc_of account_has_live_headroom roomy)"

RATELIMIT_FIXTURE=$(jq -cn --argjson now "$NOW" \
  '{asOf:$now,fiveHourPct:0,sevenDayPct:100}')
t "weekly 100 rejects a destination even when 5h reads fresh" "1" "$(rc_of account_has_live_headroom weekly-full)"

RATELIMIT_FIXTURE=$(jq -cn --argjson now "$NOW" \
  '{asOf:$now,fiveHourPct:null,sevenDayPct:28}')
t "missing 5h fails closed for destination measurement" "1" "$(rc_of account_has_live_headroom unmeasured)"

account_has_live_headroom() { [[ "$1" == "roomy" || "$1" == "also-roomy" ]]; }
t "candidate filter keeps only measured profiles, in preference order" \
  '["roomy","also-roomy"]' \
  "$(rotation_live_headroom_candidates '["weekly-full","roomy","unmeasured","also-roomy"]')"
t "candidate filter returns empty when no target is measured eligible" \
  '[]' "$(rotation_live_headroom_candidates '["weekly-full","unmeasured"]')"

# --- DIVE-3856 site 1: rotate's envelope, graded by EXECUTION ----------------
# Everything shadowed below is a boundary this harness has no business owning:
# the root check, the state dir, the registry file, and `cmd_config` (whose
# only job on this path is to re-point the profile and fire the DEFERRED
# systemd-run bounce — the very thing rotate cannot observe and must therefore
# not claim). The subject, `cmd_agent_rotation_rotate`, is real and is called.
require_root()   { :; }
ensure_state()   { :; }
registry_write() { cat >/dev/null; }
cmd_config()     { :; }
REG_FIXTURE=''
registry_read()  { printf '%s' "$REG_FIXTURE"; }

# A seat identical in every way EXCEPT its channels — so any difference in the
# envelope is attributable to the chat/headless distinction and nothing else.
rot_fixture() { # $1 = channels string, or "" for a seat with no channels key
  jq -cn --arg ch "$1" '{agents:{seat:(
      {type:"claude", authProfile:"full",
       rotation:{enabled:true, accounts:["full","roomy"], cooldowns:{}}}
      + (if $ch == "" then {} else {channels:$ch} end))}}'
}

rot_json() { REG_FIXTURE="$(rot_fixture "$1")"; JSON_MODE=1 cmd_agent_rotation_rotate seat; }
rot_prose() { REG_FIXTURE="$(rot_fixture "$1")"; JSON_MODE=0 cmd_agent_rotation_rotate seat; }

# jq -e on the VALUE, not a grep of the rendered text: `false` and `null` are
# distinct JSON values here and the whole point of the field is which one it is.
jqv() { jq -r "$2" <<<"$1"; }

CHAT_ENV="$(rot_json telegram)"
t "3856 rotate: a CHAT seat's envelope reports the bounce as scheduled" \
  "true" "$(jqv "$CHAT_ENV" '.data.channelBounceScheduled')"
t "3856 rotate: a CHAT seat's envelope reports channelVerified FALSE — the verb did not check" \
  "false" "$(jqv "$CHAT_ENV" '.data.channelVerified')"
t "3856 rotate: and it is the JSON value false, not the string \"false\" or a missing key" \
  "boolean" "$(jqv "$CHAT_ENV" '.data.channelVerified | type')"

HEADLESS_ENV="$(rot_json '')"
t "3856 rotate: a HEADLESS seat reports channelVerified NULL, not false" \
  "null" "$(jqv "$HEADLESS_ENV" '.data.channelVerified | if . == null then "null" else tostring end')"
t "3856 rotate: a HEADLESS seat schedules no channel bounce" \
  "false" "$(jqv "$HEADLESS_ENV" '.data.channelBounceScheduled')"
# The mutation control this pair exists for (measured, quinn's grade of
# iteration 1): widen the has_chat case in src/cmd_account.sh from
# `*,telegram,*|*,discord,*)` to `*)` and every headless seat rotates with
# channelVerified:false + "poller check OWED" — the exact false signal the
# code comment forbids. Under the grep arms that mutant was GREEN; these two
# arms and the prose arm below turn it red.

t "3856 rotate: the CHAT seat's HUMAN line names the poller check as OWED (JSON is not the only reader)" \
  "yes" "$(rot_prose telegram | grep -q 'poller check OWED' && printf yes || printf no)"
t "3856 rotate: the HEADLESS seat's human line does NOT owe a poller check" \
  "no" "$(rot_prose '' | grep -q 'poller check OWED' && printf yes || printf no)"
t "3856 rotate: neither envelope ever claims the channel was verified" \
  "0" "$(jq -s '[ .[] | select(.data.channelVerified == true) ] | length' \
           <<<"$CHAT_ENV
$HEADLESS_ENV")"

printf '\naccount_rotation_headroom_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
