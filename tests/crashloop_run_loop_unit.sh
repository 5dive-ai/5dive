#!/usr/bin/env bash
# DIVE-1029 unit harness for the supervised run-loop's crash-loop detection
# (hooks/run-loop.sh). No root, no network, no tmux:
#   - _cl_is_fast: short runs are "fast failures", long runs are not
#   - _cl_backoff: 2s below the threshold, then exponential + capped
#   - run_loop end-to-end (stubbed launch + notify): after CRASHLOOP_N fast
#     exits it drops the crash-loop flag and raises exactly ONE alert
# Run: bash tests/crashloop_run_loop_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/crashloop-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Source the helper without running its loop.
_RUN_LOOP_SOURCED=1
# shellcheck source=/dev/null
source hooks/run-loop.sh

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- _cl_is_fast -----------------------------------------------------------
_cl_is_fast 5 45   && ok_t "5s run is a fast failure"        || bad_t "5s run should be fast"
_cl_is_fast 44 45  && ok_t "44s run is a fast failure"       || bad_t "44s should be fast"
_cl_is_fast 45 45  && bad_t "45s should NOT be fast (>= threshold)" || ok_t "45s run is healthy"
_cl_is_fast 600 45 && bad_t "600s should NOT be fast"        || ok_t "600s run is healthy"

# --- _cl_backoff (thr=3, cap=300) -----------------------------------------
check_backoff() { # <n> <expected>
  local got; got=$(_cl_backoff "$1" 3 300)
  [[ "$got" == "$2" ]] && ok_t "_cl_backoff($1)=$2" || bad_t "_cl_backoff($1)" "got $got want $2"
}
check_backoff 0 2
check_backoff 2 2      # below threshold → friendly 2s
check_backoff 3 2      # first flagged failure still respawns quickly
check_backoff 4 5
check_backoff 5 10
check_backoff 6 20
check_backoff 7 40
check_backoff 12 300   # would be 5*2^8=1280 → capped at 300

# --- run_loop end-to-end (stubbed) ----------------------------------------
# Stub the outbound alert so we can count it without touching Telegram.
NOTIFY_LOG="$TMP/notify.log"; : > "$NOTIFY_LOG"
_cl_notify() { printf '%s\n' "$1" >> "$NOTIFY_LOG"; }
FLAG="$TMP/crashloop.active"

# RUN_CMD='true' exits instantly (dur 0 < FAST_SECS) so every iteration is a
# fast failure; CRASHLOOP_N=2 trips quickly. BACKOFF_CAP=1 keeps the loop brisk.
# CRASHLOOP_N=1 so the very first fast exit trips detection (flag + alert land
# before the iteration's backoff sleep, so a short test window is enough).
RUN_CMD='true' RUN_CMD_FIRST='' AGENT_NAME='tester' \
  FAST_SECS=999 CRASHLOOP_N=1 BACKOFF_CAP=1 CRASHLOOP_FLAG="$FLAG" \
  run_loop &
LOOP_PID=$!
sleep 1
kill "$LOOP_PID" 2>/dev/null || true
wait "$LOOP_PID" 2>/dev/null || true

[[ -f "$FLAG" ]] && ok_t "crash-loop flag dropped" || bad_t "flag missing" "expected $FLAG"

n_alerts=$(grep -c 'crash-looping' "$NOTIFY_LOG" 2>/dev/null || echo 0)
if [[ "$n_alerts" == "1" ]]; then
  ok_t "exactly one crash-loop alert raised (no banner storm)"
else
  bad_t "alert count" "got $n_alerts crash-loop alerts, want 1"$'\n'"$(cat "$NOTIFY_LOG")"
fi

# --- resume banner suppression respects a fresh flag ----------------------
# Mirror the age check resume-after-reset.sh / stop-failure-telegram.sh apply.
flag_fresh() { # <flag>
  [[ -f "$1" ]] || return 1
  local age=$(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) ))
  (( age >= 0 && age < 300 ))
}
flag_fresh "$FLAG" && ok_t "fresh flag → resume banner suppressed" || bad_t "fresh flag should suppress"
touch -d '2000-01-01' "$FLAG" 2>/dev/null || touch -t 200001010000 "$FLAG"
flag_fresh "$FLAG" && bad_t "stale flag should NOT suppress" || ok_t "stale flag → banner allowed"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
