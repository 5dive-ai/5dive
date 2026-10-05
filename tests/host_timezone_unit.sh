#!/usr/bin/env bash
# DIVE-5165 unit harness: `5dive host timezone [set <zone>]`.
#
# 5dive-api calls `set` over /shell/exec (sudo -n 5dive …, so ROOT) with the
# zone a partner client's device reported. The zone is the only caller input,
# so the load-bearing arms are the refusals: a path, a traversal, a newline, a
# lower-cased name and a well-shaped name the box does not know must all stop
# before timedatectl is asked to set anything. Then the effects: an unchanged
# zone restarts nothing, a changed one restarts cron and exactly the ACTIVE
# agent units systemd reports (a stray unit line is never restarted), a parked
# agent (registry desiredState=stopped) is skipped, and --no-restart restarts
# nothing.
#
# timedatectl and systemctl are driven through the _host_timedatectl /
# _host_systemctl seams and recorded to a call log — no root, no systemd.
#
# Run: bash tests/host_timezone_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/host-timezone-unit.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_host.sh"

set +e   # header.sh enabled `set -e`; this harness asserts on values, not exits

PASSED=0; FAILED=0
pass() { PASSED=$((PASSED+1)); printf 'ok   — %s\n' "$1"; }
bad()  { FAILED=$((FAILED+1)); printf 'FAIL — %s\n' "$1"; }

# An agent's unit name, composed the way systemd templates it.
unit() { printf '5dive-agent@%s.service' "$1"; }
MAYA=$(unit maya); DARIA=$(unit daria); TRAVERSAL=$(unit ../x)

# ---- seams ------------------------------------------------------------------
CALLS="$TMP/calls"
CUR_TZ="$TMP/tz"
ZONES="$TMP/zones"
printf '%s\n' UTC Asia/Tokyo Europe/Berlin America/Argentina/Buenos_Aires Etc/GMT+3 > "$ZONES"

_host_timedatectl() {
  printf 'timedatectl %s\n' "$*" >> "$CALLS"
  case "$1" in
    show) cat "$CUR_TZ" ;;
    list-timezones) cat "$ZONES" ;;
    set-timezone) printf '%s\n' "$2" > "$CUR_TZ" ;;
  esac
}
UNITS_OUT=""
_host_systemctl() {
  printf 'systemctl %s\n' "$*" >> "$CALLS"
  case "$1" in
    list-units) printf '%s' "$UNITS_OUT" ;;
  esac
  return 0
}
require_root() { :; }   # the harness is not root; the real check is exercised below

reset() {   # <current zone>
  : > "$CALLS"; printf '%s\n' "$1" > "$CUR_TZ"; JSON_MODE=0
}

refuses_tz() {   # <desc> <zone>
  reset UTC
  local out rc
  out=$( cmd_host_timezone set "$2" 2>&1 ); rc=$?
  if (( rc != 0 )) && ! grep -q '^timedatectl set-timezone' "$CALLS"; then
    pass "$1 (refused rc=$rc, nothing set)"
  else
    bad "$1 — rc=$rc calls=$(tr '\n' ';' < "$CALLS") out=${out:-<none>}"
  fi
}

echo "== refusals: the zone never reaches timedatectl unless it is a known IANA name =="
refuses_tz "an absolute path"                 "/etc/passwd"
refuses_tz "a traversal"                      "../../etc/passwd"
refuses_tz "a traversal inside a name"        "Asia/../Tokyo"
refuses_tz "a trailing newline + second line" $'Asia/Tokyo\nUTC'
refuses_tz "lower case (timedatectl is case-sensitive)" "asia/tokyo"
refuses_tz "a shell metacharacter"            'Asia/Tokyo;id'
refuses_tz "an option-shaped value"           "--adjust-system-clock"
refuses_tz "a well-shaped name the box does not know" "Mars/Olympus_Mons"
refuses_tz "empty"                            ""

echo
echo "== accepted shapes =="
for z in UTC Europe/Berlin America/Argentina/Buenos_Aires Etc/GMT+3; do
  reset Asia/Tokyo
  out=$( cmd_host_timezone set "$z" --no-restart 2>&1 ); rc=$?
  if (( rc == 0 )) && grep -qx "timedatectl set-timezone $z" "$CALLS"; then
    pass "set $z"
  else
    bad "set $z — rc=$rc out=$out calls=$(tr '\n' ';' < "$CALLS")"
  fi
done

echo
echo "== an unchanged zone is a no-op =="
reset Asia/Tokyo
UNITS_OUT="$MAYA loaded active running maya"$'\n'
out=$( JSON_MODE=1; cmd_host_timezone set Asia/Tokyo --json 2>&1 ); rc=$?
if (( rc == 0 )) && ! grep -qE '^timedatectl set-timezone|^systemctl (restart|try-restart)' "$CALLS" \
   && [[ $(jq -c '.data | {changed, restarted}' <<<"$out") == '{"changed":false,"restarted":[]}' ]]; then
  pass "same zone: nothing set, nothing restarted, changed=false"
else
  bad "same zone — rc=$rc out=$out calls=$(tr '\n' ';' < "$CALLS")"
fi

echo
echo "== a changed zone restarts cron and exactly the active agent units =="
reset UTC
UNITS_OUT="$MAYA loaded active running maya"$'\n'"$DARIA loaded active running daria"$'\n'"evil.service loaded active running x"$'\n'"$TRAVERSAL loaded active running y"$'\n'
out=$( JSON_MODE=1; cmd_host_timezone set Asia/Tokyo --json 2>/dev/null ); rc=$?
restarts=$(grep -E '^systemctl restart ' "$CALLS" | sed 's/^systemctl restart //' | tr '\n' ' ')
if (( rc == 0 )) && [[ "$restarts" == "$MAYA $DARIA " ]]; then
  pass "restarted maya + daria, not the stray units"
else
  bad "restart set — rc=$rc restarts='$restarts'"
fi
grep -qx 'systemctl try-restart cron.service' "$CALLS" && pass "cron try-restarted" || bad "cron not restarted"
want=$(jq -cn --arg m "$MAYA" --arg d "$DARIA" '{timezone:"Asia/Tokyo",previous:"UTC",changed:true,restarted:[$m,$d]}')
if [[ $(jq -c '.data' <<<"$out") == "$want" ]]; then
  pass "JSON reply names the zone, the previous one and what restarted"
else
  bad "JSON reply — $out"
fi
[[ "$(cat "$CUR_TZ")" == "Asia/Tokyo" ]] && pass "the zone is now Asia/Tokyo" || bad "zone not set"

echo
echo "== a parked agent (desiredState=stopped) is never restarted =="
# The list-then-restart window: systemd still reports daria active, the registry
# says she was parked. A restart would bring back an agent its operator stopped.
REGISTRY="$TMP/agents.json"
jq -n '{agents:{maya:{}, daria:{desiredState:"stopped"}}}' > "$REGISTRY"
reset UTC
UNITS_OUT="$MAYA loaded active running maya"$'\n'"$DARIA loaded active running daria"$'\n'
out=$( JSON_MODE=1; cmd_host_timezone set Asia/Tokyo --json 2>"$TMP/err" ); rc=$?
restarts=$(grep -E '^systemctl restart ' "$CALLS" | sed 's/^systemctl restart //' | tr '\n' ' ')
if (( rc == 0 )) && [[ "$restarts" == "$MAYA " ]] && grep -q "daria' is parked" "$TMP/err" \
   && [[ $(jq -c '.data.restarted' <<<"$out") == "[\"$MAYA\"]" ]]; then
  pass "parked daria skipped (warned), maya (no desiredState) restarted"
else
  bad "parked — rc=$rc restarts='$restarts' err=$(cat "$TMP/err") out=$out"
fi
jq -n '{agents:{maya:{desiredState:"running"}, daria:{desiredState:"running"}}}' > "$REGISTRY"
reset UTC
out=$( cmd_host_timezone set Asia/Tokyo 2>/dev/null )
restarts=$(grep -E '^systemctl restart ' "$CALLS" | sed 's/^systemctl restart //' | tr '\n' ' ')
[[ "$restarts" == "$MAYA $DARIA " ]] && pass "desiredState=running restarts both" || bad "running — restarts='$restarts'"
unset REGISTRY

echo
echo "== --no-restart =="
reset UTC
out=$( cmd_host_timezone set Asia/Tokyo --no-restart 2>&1 ); rc=$?
if (( rc == 0 )) && grep -qx 'timedatectl set-timezone Asia/Tokyo' "$CALLS" \
   && ! grep -qE '^systemctl (restart|try-restart)' "$CALLS"; then
  pass "--no-restart sets the zone and restarts nothing"
else
  bad "--no-restart — rc=$rc calls=$(tr '\n' ';' < "$CALLS")"
fi

echo
echo "== read =="
reset Europe/Berlin
out=$( JSON_MODE=1; cmd_host_timezone --json 2>&1 )
[[ $(jq -c '.data' <<<"$out") == '{"timezone":"Europe/Berlin"}' ]] && pass "read returns the zone" || bad "read — $out"
out=$( cmd_host timezone 2>&1 ); rc=$?
(( rc == 0 )) && [[ "$out" == *"Europe/Berlin"* ]] && pass "cmd_host dispatches 'timezone'" || bad "dispatch — rc=$rc $out"

echo
echo "== set requires root =="
if (( EUID == 0 )); then
  pass "SKIP: running as root, the non-root refusal cannot be observed here"
else
  unset -f require_root
  # shellcheck source=/dev/null
  source "$SRC/lib/validation.sh"
  reset UTC
  out=$( cmd_host_timezone set Asia/Tokyo 2>&1 ); rc=$?
  if (( rc != 0 )) && ! grep -q '^timedatectl set-timezone' "$CALLS"; then
    pass "non-root set refused before anything is set"
  else
    bad "non-root set — rc=$rc out=$out"
  fi
fi

echo
echo "== the shape check refuses no real zone (this runner's own tz list) =="
if real=$(command timedatectl list-timezones 2>/dev/null) && [[ -n "$real" ]]; then
  miss=$(while read -r z; do [[ "$z" =~ $HOST_TZ_RE ]] || printf '%s ' "$z"; done <<<"$real")
  [[ -z "$miss" ]] && pass "all $(wc -l <<<"$real") real zones pass the shape check" || bad "real zones refused: $miss"
else
  pass "SKIP: no timedatectl on this runner"
fi

echo
echo "== structural: timedatectl only through its seam =="
CODE="$TMP/code.sh"
grep -vE '^[[:space:]]*#' "$SRC/cmd_host.sh" | awk '
  /^_host_timedatectl\(\)/ { skip=1 }
  skip && /^}/ { skip=0; next }
  !skip { print }' > "$CODE"
hits=$(grep -nE '(^[[:space:]]*|\$\([[:space:]]*|\|[[:space:]]*|&&[[:space:]]*|;[[:space:]]*)timedatectl([[:space:]]|$)' "$CODE")
[[ -z "$hits" ]] && pass "no raw timedatectl call outside _host_timedatectl" || bad "raw timedatectl: $hits"

echo
echo "passed=$PASSED failed=$FAILED"
(( FAILED == 0 ))
