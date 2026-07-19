#!/usr/bin/env bash
# DIVE-1486 unit harness for active-defer reconciliation.
#
# Regression guard for the fleet-stall self-heal bug: a confident "active" (rc 1)
# reading defers the heartbeat nudge so an agent is never /cleared mid-turn, but
# an attached-but-idle session reads "active" forever (blinking cursor/spinner
# leaves the pane byte-unstable, or the native signal lags) while a dispatchable
# todo sits deferred and the supervisor calls the same agent "idle-stranded".
# _hb_mark_active_defer advances a per-agent counter ONLY while the pane
# fingerprint is unchanged (zero output progress); once it reaches
# _HB_ACTIVE_DEFER_ESCALATE the tick force-nudges instead of deferring forever.
# This asserts the counter's progress-reset + escalation semantics and the clear.
# Run: bash tests/heartbeat_active_defer_unit.sh  (no root, no network, no tmux).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_agent_runtime.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e  # header.sh enabled set -e; asserts below deliberately probe non-zero rc

# Isolate the registry to a temp file and drop the root-only chown so the test
# runs unprivileged (mirrors the isolated-DB discipline the other hb tests use).
TMPD=$(mktemp -d /tmp/active-defer-test.XXXXXX)
REGISTRY="$TMPD/registry.json"
REGISTRY_LOCK="$TMPD/registry.lock"
printf '{"agents":{"dev":{"heartbeat":{"enabled":true}}}}' > "$REGISTRY"
registry_write() { local tmp; tmp=$(mktemp "${REGISTRY}.XXXXXX"); cat > "$tmp"; mv "$tmp" "$REGISTRY"; }
with_registry_lock() { local fn="$1"; shift; "$fn" "$@"; }  # no flock/ensure_state in the harness
trap 'rm -rf "$TMPD"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want '$3' got '$2'"; fi; }

# --- Frozen pane: counter climbs one per tick and reaches the ceiling ----------
n=$(_hb_mark_active_defer dev "fpA"); eq_t "1st defer (frozen) = 1" "$n" "1"
n=$(_hb_mark_active_defer dev "fpA"); eq_t "2nd defer (same fp) = 2" "$n" "2"
n=$(_hb_mark_active_defer dev "fpA"); eq_t "3rd defer (same fp) = 3 → escalate" "$n" "3"
(( 3 >= _HB_ACTIVE_DEFER_ESCALATE )) && ok_t "3 hits default ceiling ($_HB_ACTIVE_DEFER_ESCALATE)" || bad_t "ceiling" "default=$_HB_ACTIVE_DEFER_ESCALATE"

# --- Streaming output (fingerprint moves) resets the counter every tick --------
n=$(_hb_mark_active_defer dev "fpB"); eq_t "fp change resets to 1" "$n" "1"
n=$(_hb_mark_active_defer dev "fpC"); eq_t "another fp change stays 1" "$n" "1"
n=$(_hb_mark_active_defer dev "fpC"); eq_t "then same fp climbs to 2" "$n" "2"

# --- Empty fingerprint (uncapturable pane) is fail-safe: never advances --------
n=$(_hb_mark_active_defer dev "");    eq_t "empty fp resets to 1 (no proof of no-progress)" "$n" "1"
n=$(_hb_mark_active_defer dev "");    eq_t "empty fp stays 1 (never climbs on missing signal)" "$n" "1"

# --- Clear wipes the counter so the next episode starts fresh ------------------
n=$(_hb_mark_active_defer dev "fpD"); eq_t "seed before clear = 1" "$n" "1"
n=$(_hb_mark_active_defer dev "fpD"); eq_t "seed before clear climbs = 2" "$n" "2"
_hb_clear_active_defer dev
stored=$(jq -r '.agents.dev.heartbeat.activeDefer // "gone"' "$REGISTRY")
eq_t "clear removes activeDefer node" "$stored" "gone"
n=$(_hb_mark_active_defer dev "fpD"); eq_t "post-clear restarts at 1" "$n" "1"

# --- Clear on an agent with no counter is a harmless no-op ---------------------
_hb_clear_active_defer ghost && ok_t "clear on unknown agent no-ops (no crash)" || bad_t "clear ghost crashed"

# --- Counter is per-agent (no cross-talk) --------------------------------------
_hb_clear_active_defer dev
n=$(_hb_mark_active_defer dev  "shared"); eq_t "dev starts at 1" "$n" "1"
# 'main' has no heartbeat node yet — mark must still create it cleanly.
n=$(_hb_mark_active_defer main "shared"); eq_t "main (new node) starts at 1" "$n" "1"
n=$(_hb_mark_active_defer dev  "shared"); eq_t "dev independently climbs to 2" "$n" "2"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
