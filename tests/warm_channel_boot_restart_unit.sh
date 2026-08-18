#!/usr/bin/env bash
# DIVE-3568 unit harness for the post-create channel warm-up restart.
#
# The defect: on a virgin box the FIRST claude-code boot ignores --channels
# ("Channels are not currently available") and stays deaf for that session's
# whole life; one restart later the same flag is honoured. `agent create`
# enables the unit and hands the customer that first, cold session.
#
# The fix demotes boot 1 to a warm-up and restarts once into the session the
# customer keeps. This harness grades the three properties that make that fix
# a fix rather than a sleep:
#
#   1. the restart happens EVEN IF the thing we wait for never appears
#      (the wait is an optimisation; a claude-code release that renames its
#      cache keys must cost latency, not the fix);
#   2. it does NOT wait when the warm-up already wrote its state;
#   3. a failed restart is reported (rc 1), never swallowed into a green create;
#   4. the call site is gated to claude-with-channels and sits AFTER the
#      `systemctl enable --now` that produces the boot it is warming.
#
# WHAT THIS HARNESS CANNOT SEE, and it is the important half: it grades the
# launcher's logic in isolation with systemctl and sleep stubbed. It cannot see
# whether claude-code's channel gate actually flips, because that gate is
# claude-code-side state on a virgin box — no unit test on this host can
# observe it (measured 2026-08-18: a cold-cache/warm-cache A/B on this box
# produced no gate at all, i.e. the box is not a virgin box). Treat a green
# here as "the restart is wired and unconditional", never as "the customer's
# first session hears its channels". DIVE-1591 lost a year to exactly that
# substitution.
#
# Run: bash tests/warm_channel_boot_restart_unit.sh  (no root, no network, no systemd).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
AS=$SRC/lib/agent_setup.sh
AC=$SRC/cmd_agent_create.sh

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN 2>/dev/null || true

# The helper only needs systemctl, sleep and jq, so it is exercised for real in
# a subshell with the first two stubbed and the wall clock accounted by hand.
run_helper() { # $1=cfg-json-or-empty $2=budget $3=restart-rc $4=is-active-rc
  local cfg="$TMP/claude.json"; rm -f "$cfg"
  [[ -n "$1" ]] && printf '%s' "$1" > "$cfg"
  ( set +e
    source "$AS" >/dev/null 2>&1
    SLEPT=0; RESTARTS=0
    sleep() { SLEPT=$(( SLEPT + ${1%.*} )); }
    systemctl() {
      case "$1" in
        restart)   RESTARTS=$(( RESTARTS + 1 )); return "$RESTART_RC" ;;
        is-active) return "$ACTIVE_RC" ;;
        *) return 0 ;;
      esac
    }
    RESTART_RC="$3"; ACTIVE_RC="$4"
    warm_channel_capability_restart chantest "$2" "$cfg"; rc=$?
    printf 'rc=%s restarts=%s slept=%s\n' "$rc" "$RESTARTS" "$SLEPT"
  )
}

# --- 1. the cache never appears: restart happens anyway ---------------------
out=$(run_helper '' 12 0 0)
case "$out" in
  "rc=0 restarts=1 slept=12"*) ok_t "never-warms: restarts anyway after spending the budget ($out)" ;;
  *) bad_t "never-warms: restarts anyway after spending the budget" \
           "got '$out' — if restarts=0 the wait became the fix, and a claude-code key rename silently un-fixes the create" ;;
esac

# --- 2. already warm: no wait -----------------------------------------------
out=$(run_helper '{"cachedGrowthBookFeatures":{"a":1}}' 30 0 0)
case "$out" in
  "rc=0 restarts=1 slept=10"*) ok_t "already-warm: no polling, but still holds the 10s warm-up floor ($out)" ;;
  *) bad_t "already-warm: no polling, but still holds the 10s warm-up floor" \
           "got '$out' — slept=0 means we restart the instant the cache file appears (~3s in, measured), cutting the rest of the first boot off at the knees" ;;
esac

# Negative control for 2: a config with NO cached* key must not read as warm.
#
# The budget MUST sit strictly above every clamp in the helper (floor_s=10, and
# the no-jq fixed slice of 15) or this arm grades nothing: at budget=6 the floor
# clamps to 6, so a correctly-cold poll (3,6) and a wrongly-warm break-at-0 that
# the floor pads to 6 BOTH print slept=6 and the arm cannot tell them apart.
# Verified by mutation (DIVE-3568 iteration 2): at 21, cold prints slept=21 and
# a predicate that matches any key prints slept=10. The escaped mutant is not
# hypothetical — a predicate matching hasCompletedOnboarding (written within a
# second of boot) collapses the whole wait to the bare floor, which is the one
# thing this arm exists to prevent.
out=$(run_helper '{"hasCompletedOnboarding":true}' 21 0 0)
case "$out" in
  "rc=0 restarts=1 slept=21"*) ok_t "NEGATIVE: an onboarding-only config is not 'warm' ($out)" ;;
  *) bad_t "NEGATIVE: an onboarding-only config is not 'warm'" \
           "got '$out' — expected slept=21 (polled the whole budget). slept=10 means the warm predicate matched a non-cache key and fell straight through to the floor, so we would restart before the warm-up wrote anything" ;;
esac

# Clamp arm. Arm 3 above must sit ABOVE every clamp to grade the predicate, so
# it can no longer see the floor's own clamp (`floor_s > budget && floor_s=budget`);
# this arm is the only thing holding it. Warm, so the poll returns at once and
# what remains is purely the floor: clamped it sleeps the budget (4), unclamped
# it sleeps the full 10 and overruns a caller that asked for less.
out=$(run_helper '{"cachedGrowthBookFeatures":{"a":1}}' 4 0 0)
case "$out" in
  "rc=0 restarts=1 slept=4"*) ok_t "floor is clamped by a budget shorter than it ($out)" ;;
  *) bad_t "floor is clamped by a budget shorter than it" \
           "got '$out' — expected slept=4; slept=10 means the floor ignores the budget and a caller asking for a short wait gets the full one" ;;
esac

# --- 3. a failed restart is reported, not swallowed -------------------------
out=$(run_helper '{"cachedGrowthBookFeatures":{"a":1}}' 30 1 0)
case "$out" in
  "rc=1 "*) ok_t "restart failure returns 1 ($out)" ;;
  *) bad_t "restart failure returns 1" "got '$out' — a green create would claim a warm session it never produced" ;;
esac
out=$(run_helper '{"cachedGrowthBookFeatures":{"a":1}}' 30 0 3)
case "$out" in
  "rc=1 "*) ok_t "unit not active after restart returns 1 ($out)" ;;
  *) bad_t "unit not active after restart returns 1" "got '$out'" ;;
esac

# --- 4. call site: gated, and AFTER the boot it is warming ------------------
if grep -q 'warm_channel_capability_restart "\$name"' "$AC"; then
  ok_t "cmd_agent_create calls warm_channel_capability_restart"
else
  bad_t "cmd_agent_create calls warm_channel_capability_restart" \
        "the helper exists but nothing calls it — the create still hands over boot 1"
fi
if grep -qE '\[\[ "\$type" == "claude" \]\] && \[\[ -n "\$channels" && "\$channels" != "none" \]\]' "$AC"; then
  ok_t "call is gated to claude-with-channels (no restart cost for channels=none / poll-fork types)"
else
  bad_t "call is gated to claude-with-channels" \
        "an ungated restart pays 20-40s on every create that has no channel flag to warm"
fi
enable_ln=$(grep -n 'systemctl enable --now "5dive-agent@\${name}.service"' "$AC" | head -1 | cut -d: -f1)
call_ln=$(grep -n 'warm_channel_capability_restart "\$name"' "$AC" | head -1 | cut -d: -f1)
if [[ -n "$enable_ln" && -n "$call_ln" ]] && (( call_ln > enable_ln )); then
  ok_t "restart is ordered AFTER 'systemctl enable --now' (line $call_ln > $enable_ln)"
else
  bad_t "restart is ordered AFTER 'systemctl enable --now'" \
        "enable=$enable_ln call=$call_ln — restarting before the first boot warms nothing"
fi

# --- 5. the create envelope reports what it did -----------------------------
if grep -q 'channelWarmRestart:\$wr' "$AC"; then
  ok_t "create envelope carries channelWarmRestart (skipped|restarted|failed)"
else
  bad_t "create envelope carries channelWarmRestart" \
        "without it a caller cannot tell a warmed create from a cold one"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
