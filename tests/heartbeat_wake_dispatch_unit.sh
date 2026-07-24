#!/usr/bin/env bash
# DIVE-1858 Phase-1 wake-on-alert — isolated unit harness for the Stage-1
# opt-in wake_mode flag + wake-budget guardrail helpers.
#
# Stage 1 (main's staged plan A) adds a per-agent wake mode (always_on | cold)
# and a wakes/day budget cap with cost-per-wake visibility, so a chatty trigger
# can't thrash a cold agent — with NO live auto-sleep (that's Stage 2, held for
# main's pre-run lead review). This exercises the pure helpers over a throwaway
# registry JSON with the lock + chown stubbed — never touches the shared registry
# or a live pane. Asserts: default mode is always_on; setting cold seeds the
# default cap; --cap overrides; main/marketing refuse cold (olivia condition 3);
# budget gate passes under cap, blocks at/over cap, and resets on a new day;
# inc counts + rolls over; always_on agents are never budgeted; cost is surfaced.
# Run: bash tests/heartbeat_wake_dispatch_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-wakedispatch-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/registry.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

JSON_MODE=0
REGISTRY="$TMP/registry.json"
set +e   # header.sh enabled `set -e`; asserts below deliberately probe states

# --- Stubs: keep the helpers hermetic (no root, no flock, no chown) -----------
with_registry_lock() { local fn="$1"; shift; "$fn" "$@"; }   # call directly
registry_write()     { cat > "$REGISTRY"; }                   # no chown/atomic-move

seed() { printf '%s\n' "$1" > "$REGISTRY"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
rmode() { jq -r --arg n "$1" '.agents[$n].wake.mode // "unset"' "$REGISTRY"; }
rcap()  { jq -r --arg n "$1" '.agents[$n].wake.budget.capPerDay // "unset"' "$REGISTRY"; }
rused() { jq -r --arg n "$1" '.agents[$n].wake.budget.wakesToday // "unset"' "$REGISTRY"; }
rday()  { jq -r --arg n "$1" '.agents[$n].wake.budget.day // "unset"' "$REGISTRY"; }

seed '{"agents":{"testbot":{},"main":{},"marketing":{}}}'

# 1) default mode is always_on when unset
[[ "$(_hb_wake_mode testbot)" == "always_on" ]] \
  && ok_t "unset agent => always_on" || bad_t "unset agent => always_on" "got $(_hb_wake_mode testbot)"

# 2) protected-agent gate (olivia condition 3)
_hb_wake_protected main      && ok_t "main is protected"      || bad_t "main is protected"
_hb_wake_protected marketing && ok_t "marketing is protected" || bad_t "marketing is protected"
_hb_wake_protected testbot   && bad_t "testbot NOT protected" || ok_t "testbot NOT protected"

# 3) setting cold seeds the default cap and preserves counter
_hb_wake_mode_write testbot cold ""
[[ "$(rmode testbot)" == "cold" ]] && ok_t "set cold => mode cold" || bad_t "set cold => mode cold" "got $(rmode testbot)"
[[ "$(rcap testbot)" == "$_HB_WAKE_DEFAULT_CAP" ]] \
  && ok_t "cold seeds default cap ($_HB_WAKE_DEFAULT_CAP)" || bad_t "cold seeds default cap" "got $(rcap testbot)"
[[ "$(jq -r '.agents.testbot.wake.costPerWake // "unset"' "$REGISTRY")" != "unset" ]] \
  && ok_t "cost-per-wake surfaced" || bad_t "cost-per-wake surfaced"

# 4) --cap override
_hb_wake_mode_write testbot cold "5"
[[ "$(rcap testbot)" == "5" ]] && ok_t "--cap=5 overrides" || bad_t "--cap=5 overrides" "got $(rcap testbot)"

# 5) budget gate: under cap passes, at/over cap blocks. Seed used=4 of cap 5 today.
TODAY="2026-07-24"
seed "$(jq -n --arg d "$TODAY" '{agents:{testbot:{wake:{mode:"cold",budget:{capPerDay:5,wakesToday:4,day:$d}}}}}')"
_hb_wake_budget_ok testbot "$TODAY" && ok_t "4/5 under cap => wake ok" || bad_t "4/5 under cap => wake ok"
seed "$(jq -n --arg d "$TODAY" '{agents:{testbot:{wake:{mode:"cold",budget:{capPerDay:5,wakesToday:5,day:$d}}}}}')"
_hb_wake_budget_ok testbot "$TODAY" && bad_t "5/5 at cap => blocked" || ok_t "5/5 at cap => blocked"

# 6) new day resets the counter (yesterday's used=5 must not block today)
_hb_wake_budget_ok testbot "2026-07-25" && ok_t "new day resets budget" || bad_t "new day resets budget"

# 7) always_on / un-capped agents are never budgeted
seed '{"agents":{"testbot":{"wake":{"mode":"always_on","budget":{"capPerDay":1,"wakesToday":9,"day":"2026-07-24"}}}}}'
_hb_wake_budget_ok testbot "2026-07-24" && ok_t "always_on never budgeted" || bad_t "always_on never budgeted"
seed '{"agents":{"testbot":{"wake":{"mode":"cold"}}}}'   # cold, no cap => unlimited
_hb_wake_budget_ok testbot "2026-07-24" && ok_t "cold w/ no cap => unlimited" || bad_t "cold w/ no cap => unlimited"

# 8) inc counts within a day and rolls over across days
seed "$(jq -n --arg d "$TODAY" '{agents:{testbot:{wake:{mode:"cold",budget:{capPerDay:5,wakesToday:2,day:$d}}}}}')"
_hb_wake_budget_inc testbot "$TODAY"
[[ "$(rused testbot)" == "3" ]] && ok_t "inc within day: 2 -> 3" || bad_t "inc within day: 2 -> 3" "got $(rused testbot)"
_hb_wake_budget_inc testbot "2026-07-25"
{ [[ "$(rused testbot)" == "1" ]] && [[ "$(rday testbot)" == "2026-07-25" ]]; } \
  && ok_t "inc new day: resets to 1" || bad_t "inc new day: resets to 1" "used $(rused testbot) day $(rday testbot)"

# 9) inc is a no-op for always_on (never spends budget)
seed '{"agents":{"testbot":{"wake":{"mode":"always_on"}}}}'
_hb_wake_budget_inc testbot "$TODAY"
[[ "$(jq -r '.agents.testbot.wake.budget // "none"' "$REGISTRY")" == "none" ]] \
  && ok_t "inc no-op for always_on" || bad_t "inc no-op for always_on"

echo "-----"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
