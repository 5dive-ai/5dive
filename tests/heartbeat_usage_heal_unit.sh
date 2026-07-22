#!/usr/bin/env bash
# DIVE-1666 unit harness for usage-limit self-heal classification.
#
# Regression guard for the fleet-stall root cause: the heartbeat's no-clobber
# guard defers a "blocked" (rc 3) reading so it never /clears a session parked on
# a genuine permission/plan dialog. That's correct — EXCEPT for the Claude Code
# usage/spend-limit dialog, which never self-clears, so deferring it every tick
# froze whole sessions permanently even after the 5h window rolled back (the
# 2026-07-21 ~4h stall). The fix classifies the dialog: a usage-limit match is a
# reclaimable frozen session (restart to self-heal, throttled), and headroom is
# proven by a live healthy peer on the same pooled account. This asserts the pure
# matcher's two-signature discipline, the peer-headroom logic, and the heal
# throttle counter + its clear.
# Run: bash tests/heartbeat_usage_heal_unit.sh  (no root, no network, no tmux).
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
TMPD=$(mktemp -d /tmp/usage-heal-test.XXXXXX)
REGISTRY="$TMPD/registry.json"
REGISTRY_LOCK="$TMPD/registry.lock"
printf '%s' '{"agents":{
  "dev":  {"authProfile":"acctA","heartbeat":{"enabled":true}},
  "dev2": {"authProfile":"acctA","heartbeat":{"enabled":true}},
  "solo": {"authProfile":"acctB","heartbeat":{"enabled":true}}
}}' > "$REGISTRY"
registry_write() { local tmp; tmp=$(mktemp "${REGISTRY}.XXXXXX"); cat > "$tmp"; mv "$tmp" "$REGISTRY"; }
with_registry_lock() { local fn="$1"; shift; "$fn" "$@"; }  # no flock/ensure_state in the harness
trap 'rm -rf "$TMPD"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want '$3' got '$2'"; fi; }

# --- Pure matcher: the usage/spend-limit dialog (two signatures) ---------------
MONTHLY=$'You'"'"'ve hit your monthly spend limit\n\n  1. Stop and wait for limit to reset\n  2. Upgrade your plan'
FIVEHR=$'Usage limit reached\n\nYour limit will reset at 3pm.'
_hb_pane_is_usage_limit "$MONTHLY" && ok_t "matches the monthly-spend dialog" || bad_t "monthly-spend not matched"
_hb_pane_is_usage_limit "$FIVEHR"  && ok_t "matches the 5h usage-limit dialog" || bad_t "5h variant not matched"

# --- Pure matcher: must NOT false-match real prompts / incidental text ---------
PERM=$'Claude wants to run:\n  rm -rf build/\n\n  1. Yes  2. No, and tell Claude what to do differently'
_hb_pane_is_usage_limit "$PERM" && bad_t "permission dialog MUST NOT match (would wrongly restart real work)" || ok_t "permission dialog correctly not matched"
# "Upgrade your plan" alone (only the ACTION signature, no header) must not match.
_hb_pane_is_usage_limit "Upgrade your plan for more features" && bad_t "single-signature text must not match" || ok_t "single action-signature alone not matched"
# A header word with no action line must not match either.
_hb_pane_is_usage_limit "the rate limit reached the API once" && bad_t "header-only text must not match" || ok_t "header-only signature alone not matched"

# --- Peer-headroom: a healthy peer on the pooled account proves headroom -------
# Stub the native probe so the test needs no live sessions.
_STATE=""; _hb_agent_native_state() { case "$1" in dev2) printf '%s' "$_STATE";; *) printf '';; esac; }
reg=$(cat "$REGISTRY")
_STATE="busy"
_hb_account_has_headroom dev acctA "$reg" && ok_t "busy peer on same account = headroom" || bad_t "busy peer should prove headroom"
_STATE="idle"
_hb_account_has_headroom dev acctA "$reg" && ok_t "idle peer on same account = headroom" || bad_t "idle peer should prove headroom"
_STATE="blocked:dialog open"
_hb_account_has_headroom dev acctA "$reg" && bad_t "a peer also blocked/frozen is NOT headroom" || ok_t "blocked peer is not headroom"
# solo agent has no peer on its account → never headroom (must surface, not churn).
_hb_account_has_headroom solo acctB "$reg" && bad_t "solo agent must have no provable headroom" || ok_t "solo agent = no provable headroom"

# --- Heal throttle counter: mark advances, records epoch, clear wipes ----------
n=$(with_registry_lock _hb_mark_usage_heal dev 1000); eq_t "1st heal count = 1" "$n" "1"
at=$(_hb_usage_heal_last dev);                          eq_t "heal epoch stored" "$at" "1000"
n=$(with_registry_lock _hb_mark_usage_heal dev 2000); eq_t "2nd heal count = 2" "$n" "2"
at=$(_hb_usage_heal_last dev);                          eq_t "heal epoch updated" "$at" "2000"
# _hb_clear_active_defer (fired on any wake/recovery) must reset the heal state,
# so a recovered agent's throttle starts fresh next time it freezes.
_hb_clear_active_defer dev
at=$(_hb_usage_heal_last dev);                          eq_t "clear resets heal epoch to 0" "$at" "0"
n=$(with_registry_lock _hb_mark_usage_heal dev 3000); eq_t "post-clear heal restarts at 1" "$n" "1"
# no-heal agent reads 0 cleanly.
at=$(_hb_usage_heal_last solo);                        eq_t "un-healed agent reads epoch 0" "$at" "0"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
