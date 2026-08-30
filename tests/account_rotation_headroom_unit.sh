#!/usr/bin/env bash
# DIVE-3822: supervisor quota recovery may rotate only to a profile whose
# freshest statusline cache measures live headroom in every observed window.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

# shellcheck source=/dev/null
source src/header.sh
# shellcheck source=/dev/null
source src/cmd_account.sh

PASS=0 FAIL=0
t() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); printf 'FAIL: %s — expected %s, got %s\n' "$1" "$2" "$3"
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

printf '\naccount_rotation_headroom_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
