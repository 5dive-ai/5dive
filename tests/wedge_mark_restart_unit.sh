#!/usr/bin/env bash
# TIER: core
#
# DIVE-9304 — a restarted seat must not stay `composer-wedged` forever.
#
# Box report 1450 (2026-11-25): after `sudo 5dive agent restart <seat>`, the
# remedy the supervisor's own verdict prints, `5dive supervisor` kept naming the
# seat `composer-wedged / submit-unverified` with a growing age. The wedge
# ledger was cleared ONLY by a verified heartbeat submit, and a seat with no row
# is never woken, so the verdict outlived the session it described.
#
# Arms:
#   R1  mark, then `agent restart` (plain and --defer), `agent start`,
#       `_self_restart` and `agent rm` each leave no mark
#   R2  a mark written BEFORE the unit came up is ignored by `_wedge_read`
#       (a restart by any route: systemd Restart=, reboot, raw systemctl)
#   R3  a mark written AFTER the unit came up (the pane is still wedged in the
#       new session) is still reported, and with no start time given the
#       pre-fix behaviour (report it) is kept
#   R4  the supervisor passes the unit's start to `_wedge_read`
#   M   mutation arms: drop the clear / drop the age filter -> the arms go red
#
# Stubbed systemctl / systemd-run, synthetic registry and STATE_DIR: no root,
# no systemd, no live seat touched. Seat 'seatx' does not exist.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
cd "$(dirname "$0")/.."
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }

TMP="$(mktemp -d /tmp/wedge-restart.XXXXXX)"
export STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"
# shellcheck disable=SC1091
source src/header.sh
for f in lib/error_codes.sh lib/output.sh lib/validation.sh lib/state.sh \
         lib/registry.sh cmd_agent_runtime.sh cmd_agent_lifecycle.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e
STATE_DIR="$TMP/state"
REGISTRY="$STATE_DIR/agents.json"
REGISTRY_LOCK="$TMP/registry.lock"; : > "$REGISTRY_LOCK"
ENV_DIR="$TMP/env"; mkdir -p "$ENV_DIR"
JSON_MODE=1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

SEAT=seatx
systemctl()   { :; }
systemd-run() { :; }
chown() { :; }; chmod() { :; }
require_root() { :; }; ensure_state() { :; }
normalize_restart_profile_perms() { :; }
restart_push_openclaw_state()     { :; }
# cmd_rm's side effects beyond the ledger are other rows' business.
account_binding_record() { :; }; remove_channel_secret() { :; }
delete_agent_user() { :; }; tasks_db_init() { :; }; db() { :; }
paperclip_unseed_for_profile() { :; }; step() { :; }

seed()   { printf '{"agents":{"%s":{"type":"codex"}}}\n' "$SEAT" > "$REGISTRY"; }
mark()   { _wedge_mark "$SEAT" 12 "/goal DIVE-1 do the thing" residual; }
marked() { [[ -f "$STATE_DIR/composer-wedge/$SEAT" ]]; }
# Write a mark with an explicit timestamp (the ledger's own format).
mark_at() {
  mkdir -p "$STATE_DIR/composer-wedge"
  printf '%s\x1f%s\x1f%s\x1f%s\n' "$1" 12 residual "/goal DIVE-1" > "$STATE_DIR/composer-wedge/$SEAT"
}

for fn in _wedge_mark _wedge_read _wedge_clear cmd_restart cmd_start cmd_self_restart cmd_rm; do
  declare -F "$fn" >/dev/null && ok_t "$fn is defined" || bad_t "$fn is defined" "an arm would grade nothing"
done

# ---- R1: the lifecycle verbs clear the mark ---------------------------------
seed; mark
marked && ok_t "precondition: _wedge_mark writes the ledger" || bad_t "precondition" "no ledger file"
( cmd_restart "$SEAT" ) >/dev/null 2>&1
! marked && ok_t "R1: agent restart clears the mark" || bad_t "R1: agent restart" "mark survived"
seed; mark
( cmd_restart "$SEAT" --defer ) >/dev/null 2>&1
! marked && ok_t "R1: agent restart --defer clears the mark" || bad_t "R1: restart --defer" "mark survived"
seed; mark
( cmd_start "$SEAT" ) >/dev/null 2>&1
! marked && ok_t "R1: agent start clears the mark" || bad_t "R1: agent start" "mark survived"
seed; mark
( SUDO_USER="agent-$SEAT" cmd_self_restart ) >/dev/null 2>&1
! marked && ok_t "R1: _self_restart clears the mark" || bad_t "R1: _self_restart" "mark survived"
seed; mark
( cmd_rm "$SEAT" ) >/dev/null 2>&1
! marked && ok_t "R1: agent rm clears the mark (a re-created seat is not born wedged)" || bad_t "R1: agent rm" "mark survived"

# ---- R2/R3: the age filter in _wedge_read -----------------------------------
now=$(date -u +%s)
mark_at $(( now - 3600 ))
_wedge_read "$SEAT" >/dev/null \
  && ok_t "R3: no start time given -> an old mark is still reported (pre-fix behaviour kept)" \
  || bad_t "R3: no start time" "mark hidden without a start time"
_wedge_read "$SEAT" $(( now - 600 )) >/dev/null
[[ $? -eq 1 ]] \
  && ok_t "R2: a mark from 60m ago on a unit up for 10m is ignored (rc 1)" \
  || bad_t "R2: stale mark ignored" "still reported after the unit restarted"
_wedge_read "$SEAT" 0 >/dev/null \
  && ok_t "R3: start=0 (unit down / unreadable) disarms the filter" \
  || bad_t "R3: start=0" "a zero start hid the mark"
mark_at $(( now - 60 ))
out=$(_wedge_read "$SEAT" $(( now - 600 )))
[[ $? -eq 0 && "$out" == *"UNSENT"* ]] \
  && ok_t "R3: a mark written after the unit came up (still wedged) is reported" \
  || bad_t "R3: fresh mark" "rc/out: $out"

# ---- R4: the supervisor passes the unit start ------------------------------
grep -qE '_wedge_read "\$name" "\$_sup_up_since"' src/cmd_supervisor.sh \
  && grep -qE '_sup_up_since=\$\(\( now - uptime \)\)' src/cmd_supervisor.sh \
  && ok_t "R4: the supervisor hands _wedge_read the unit's start (now - uptime)" \
  || bad_t "R4: supervisor wiring" "_wedge_read is called without the unit start"

# ---- M: mutation arms -------------------------------------------------------
(
  _wedge_clear() { :; }   # the pre-fix world: only a verified submit clears
  seed; mark
  cmd_restart "$SEAT" >/dev/null 2>&1
  marked
) && ok_t "M1: with the clear dropped, the mark survives a restart (R1 is live)" \
  || bad_t "M1: mutation" "R1 passes without the clear"
(
  eval "$(declare -f _wedge_read | sed 's/(( since > 0 \&\& ts < since ))/false/')"
  mark_at $(( now - 3600 ))
  _wedge_read "$SEAT" $(( now - 600 )) >/dev/null
) && ok_t "M2: with the age filter dropped, the stale mark is reported (R2 is live)" \
  || bad_t "M2: mutation" "R2 passes without the age filter"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
