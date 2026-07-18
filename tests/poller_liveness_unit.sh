#!/usr/bin/env bash
# DIVE-1434 isolated unit harness for the transport-liveness canary decision.
#
# The initial gate ping delivers tap buttons via a direct curl, but the TAP that
# clears the gate arrives as a callback_query the agent's OWN getUpdates poller
# must consume. If that poller dies (restart left the DIVE-818 slot unacquired),
# buttons still SEND but taps never land. _hb_poller_verdict is the PURE decision:
# given (type, beacon mtime, now, allowFrom count, staleness threshold) it flags a
# DEAD poller, stays silent on healthy/not-applicable. This exercises exactly that
# logic — no registry, no channels, no network.
#
# Run: bash tests/poller_liveness_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
source "$SRC/header.sh"
set +e   # header.sh set -e; keep going so every assertion runs

# Pull just the pure helper out of cmd_heartbeat.sh without sourcing the whole
# file (which pulls in heavy deps). It's self-contained, so eval its definition.
eval "$(awk '/^_hb_poller_verdict\(\) \{/,/^\}/' "$SRC/cmd_heartbeat.sh")"

PASS=0; FAIL=0
NOW=1000000
THRESH=120
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"; fi
}
# A verdict is "dead" when it echoes a non-empty reason; "ok" when it echoes nothing.
verdict() { _hb_poller_verdict "$1" "$2" "$NOW" "$3" "$THRESH"; }

# 1. Fresh beacon on a paired claude agent -> healthy (silent).
check "fresh beacon healthy" "" "$(verdict claude $((NOW-3)) 1)"

# 2. Beacon just over threshold -> DEAD (non-empty reason).
r=$(verdict claude $((NOW-121)) 1); [[ -n "$r" ]] && r=DEAD || r=OK
check "stale beacon flagged dead" "DEAD" "$r"

# 3. Beacon exactly AT threshold (age==thresh, not >) -> still healthy.
check "beacon at threshold not flagged" "" "$(verdict claude $((NOW-120)) 1)"

# 4. Missing beacon (mtime 0) on a paired claude agent -> DEAD (never started).
r=$(verdict claude 0 1); [[ -n "$r" ]] && r=DEAD || r=OK
check "missing beacon flagged dead" "DEAD" "$r"

# 5. UNPAIRED agent (allowFrom 0) with a stale beacon -> skip (no human to deafen).
check "unpaired agent skipped" "" "$(verdict claude $((NOW-999)) 0)"

# 6. Non-claude runtime (codex) with no beacon -> skip (own liveness model).
check "codex runtime skipped" "" "$(verdict codex 0 1)"

# 7. Non-claude runtime (grok) even with a stale beacon -> skip.
check "grok runtime skipped" "" "$(verdict grok $((NOW-999)) 1)"

printf '\npoller-liveness unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
