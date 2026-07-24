#!/usr/bin/env bash
# DIVE-1858 Phase-1 Stage 2 — isolated unit harness for the LIVE auto-sleep pass.
#
# Stage 2 adds the reactive path's second half: a cold + running + confidently
# idle agent with NO open work is `systemctl stop`ped after an idle threshold,
# then woken again by the next trigger (the wake half already shipped in Stage 1).
# This exercises `_hb_autosleep_sweep` + `_hb_agent_has_work` over a throwaway
# registry with systemctl / the idle probe / the lock / the db all STUBBED, so it
# never touches a live unit, pane, or the shared registry. Asserts: arm-then-fire
# after the threshold; no fire before it; disarm on work or a busy/blocked pane;
# always_on agents are never touched; protected agents are never slept even if
# mis-flagged cold (olivia condition 3); a stopped unit clears a stale timer;
# per-agent --sleep-after override; has_work is fail-closed on a db error.
# Run: bash tests/heartbeat_wake_sleep_unit.sh   (no root, no network, no systemd).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-wakesleep-unit.XXXXXX)"
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

NOW=1000000                       # fixed "now" epoch — passed into the sweep
declare -A RUNNING IDLE_RC HASWORK
STOPPED=""

# --- Stubs: keep the sweep hermetic (no root, no flock, no systemd, no db) -----
with_registry_lock() { local fn="$1"; shift; "$fn" "$@"; }   # call the mutation directly
registry_write()     { cat > "$REGISTRY"; }                   # no chown/atomic-move
_unit_agent() { local u="$1"; u="${u#5dive-agent@}"; printf '%s' "${u%.service}"; }
systemctl() {
  case "$1" in
    is-active) local n; n=$(_unit_agent "${@: -1}"); [[ "${RUNNING[$n]:-0}" == "1" ]] && return 0 || return 3 ;;
    stop)      local n; n=$(_unit_agent "$2"); STOPPED+=" $n"; return 0 ;;
    *)         return 0 ;;
  esac
}
_hb_agent_idle()     { return "${IDLE_RC[$1]:-0}"; }          # 0 idle · 1 busy · 3 blocked
# Keep a copy of the REAL has_work (db-backed) before we stub it for the sweep,
# so the fail-closed tests below can exercise the genuine implementation.
eval "_hb_agent_has_work_real() $(declare -f _hb_agent_has_work | sed '1d')"
_hb_agent_has_work() { [[ "${HASWORK[$1]:-0}" == "1" ]]; }    # sweep-test stub (map-driven)

seed() { printf '%s\n' "$1" > "$REGISTRY"; }
sweep_reset() { RUNNING=(); IDLE_RC=(); HASWORK=(); STOPPED=""; }
r_idlesince() { jq -r --arg n "$1" '.agents[$n].wake.idleSince // "unset"' "$REGISTRY"; }
r_slept()     { jq -r --arg n "$1" '.agents[$n].wake.lastSleptAt // "unset"' "$REGISTRY"; }
stopped_has() { [[ " $STOPPED " == *" $1 "* ]]; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

cold() { printf '{"agents":{"%s":{"wake":{"mode":"cold"%s}}}}' "$1" "$2"; }

# 1) cold + running + idle + no work + no timer => ARM (idleSince=now), no stop
sweep_reset; seed "$(cold bot '')"; RUNNING[bot]=1; IDLE_RC[bot]=0; HASWORK[bot]=0
_hb_autosleep_sweep "$NOW" >/dev/null 2>&1
{ [[ "$(r_idlesince bot)" == "$NOW" ]] && ! stopped_has bot && (( _HB_SLEEP_ARMED == 1 )); } \
  && ok_t "idle+no-work arms the timer (no stop)" || bad_t "arm case" "idleSince=$(r_idlesince bot) stopped=[$STOPPED] armed=$_HB_SLEEP_ARMED"

# 2) timer past threshold (idleSince = now-20m, default 15m) => SLEEP
sweep_reset; seed "$(cold bot ",\"idleSince\":$((NOW-1200))")"; RUNNING[bot]=1; IDLE_RC[bot]=0; HASWORK[bot]=0
_hb_autosleep_sweep "$NOW" >/dev/null 2>&1
{ stopped_has bot && (( _HB_SLEPT == 1 )) && [[ "$(r_slept bot)" == "$NOW" ]] && [[ "$(r_idlesince bot)" == "unset" ]]; } \
  && ok_t "idle past threshold => systemctl stop + stamp + disarm" || bad_t "sleep case" "stopped=[$STOPPED] slept=$_HB_SLEPT lastSleptAt=$(r_slept bot) idleSince=$(r_idlesince bot)"

# 3) timer NOT yet past threshold (idleSince = now-5m) => hold, no stop
sweep_reset; seed "$(cold bot ",\"idleSince\":$((NOW-300))")"; RUNNING[bot]=1; IDLE_RC[bot]=0; HASWORK[bot]=0
_hb_autosleep_sweep "$NOW" >/dev/null 2>&1
{ ! stopped_has bot && (( _HB_SLEPT == 0 )) && [[ "$(r_idlesince bot)" == "$((NOW-300))" ]]; } \
  && ok_t "idle under threshold => hold (no stop, timer unchanged)" || bad_t "hold case" "stopped=[$STOPPED] idleSince=$(r_idlesince bot)"

# 4) has open work => DISARM even if idle and past threshold
sweep_reset; seed "$(cold bot ",\"idleSince\":$((NOW-1200))")"; RUNNING[bot]=1; IDLE_RC[bot]=0; HASWORK[bot]=1
_hb_autosleep_sweep "$NOW" >/dev/null 2>&1
{ ! stopped_has bot && [[ "$(r_idlesince bot)" == "unset" ]]; } \
  && ok_t "open work => disarm, never sleep" || bad_t "work disarm" "stopped=[$STOPPED] idleSince=$(r_idlesince bot)"

# 5) busy pane (idle rc 1) => DISARM, no stop
sweep_reset; seed "$(cold bot ",\"idleSince\":$((NOW-1200))")"; RUNNING[bot]=1; IDLE_RC[bot]=1; HASWORK[bot]=0
_hb_autosleep_sweep "$NOW" >/dev/null 2>&1
{ ! stopped_has bot && [[ "$(r_idlesince bot)" == "unset" ]]; } \
  && ok_t "busy pane => disarm, never sleep" || bad_t "busy disarm" "stopped=[$STOPPED] idleSince=$(r_idlesince bot)"

# 5b) blocked pane (idle rc 3, needs human) => DISARM, no stop
sweep_reset; seed "$(cold bot ",\"idleSince\":$((NOW-1200))")"; RUNNING[bot]=1; IDLE_RC[bot]=3; HASWORK[bot]=0
_hb_autosleep_sweep "$NOW" >/dev/null 2>&1
{ ! stopped_has bot; } && ok_t "blocked pane => never sleep" || bad_t "blocked" "stopped=[$STOPPED]"

# 6) NOT running => no stop, stale timer cleared
sweep_reset; seed "$(cold bot ",\"idleSince\":$((NOW-1200))")"; RUNNING[bot]=0; IDLE_RC[bot]=0; HASWORK[bot]=0
_hb_autosleep_sweep "$NOW" >/dev/null 2>&1
{ ! stopped_has bot && [[ "$(r_idlesince bot)" == "unset" ]]; } \
  && ok_t "stopped unit => clear stale timer, no stop" || bad_t "not-running" "stopped=[$STOPPED] idleSince=$(r_idlesince bot)"

# 7) always_on agent (default) => never considered, even if idle+running+past
sweep_reset; seed '{"agents":{"warm":{}}}'; RUNNING[warm]=1; IDLE_RC[warm]=0; HASWORK[warm]=0
_hb_autosleep_sweep "$NOW" >/dev/null 2>&1
{ ! stopped_has warm && [[ "$(r_idlesince warm)" == "unset" ]] && (( _HB_SLEEP_ARMED == 0 )); } \
  && ok_t "always_on agent untouched" || bad_t "always_on" "stopped=[$STOPPED] idleSince=$(r_idlesince warm)"

# 8) protected agent flagged cold + idle + past threshold => NEVER slept (condition 3)
sweep_reset; seed "$(cold main ",\"idleSince\":$((NOW-1200))")"; RUNNING[main]=1; IDLE_RC[main]=0; HASWORK[main]=0
_hb_autosleep_sweep "$NOW" >/dev/null 2>&1
{ ! stopped_has main && (( _HB_SLEPT == 0 )); } \
  && ok_t "protected(main) never slept even if cold-flagged" || bad_t "protected" "stopped=[$STOPPED] slept=$_HB_SLEPT"

# 9) per-agent sleepAfterMin=5 override => sleeps at now-6m (default 15 would hold)
sweep_reset; seed "$(cold bot ",\"sleepAfterMin\":5,\"idleSince\":$((NOW-360))")"; RUNNING[bot]=1; IDLE_RC[bot]=0; HASWORK[bot]=0
_hb_autosleep_sweep "$NOW" >/dev/null 2>&1
{ stopped_has bot && (( _HB_SLEPT == 1 )); } \
  && ok_t "per-agent sleep-after override honored" || bad_t "override" "stopped=[$STOPPED] slept=$_HB_SLEPT"

# --- _hb_agent_has_work is fail-closed (exercise the REAL db-backed fn) --------
db() { echo "$DB_OUT"; return "${DB_RC:-0}"; }   # stub the db seam only
sqlq() { printf "'%s'" "$1"; }
DB_OUT="0"; DB_RC=0; _hb_agent_has_work_real bot && bad_t "no rows => no work" || ok_t "db count 0 => no work"
DB_OUT="2"; DB_RC=0; _hb_agent_has_work_real bot && ok_t "db count 2 => has work" || bad_t "count 2 => has work"
DB_OUT="";  DB_RC=1; _hb_agent_has_work_real bot && ok_t "db error => fail-closed (has work)" || bad_t "db error => fail-closed"

echo
echo "DIVE-1858 Stage 2 auto-sleep unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
