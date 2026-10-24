#!/usr/bin/env bash
# DIVE-6853 — an OSS box gets the heartbeat tick DRIVER, not just the config.
#
# Measured on a fresh Ubuntu 24.04 OSS install + `team import startup`: create
# printed "the tick will hand it board work" and no cron ran `heartbeat tick`, so
# no board row ever started. Managed boxes get /etc/cron.d/5dive-heartbeat from
# provisioning; OSS boxes got nothing.
#
#  D1  no driver anywhere -> _hb_driver_ensure writes one, mode 644, and the line
#      it writes is one the dispatcher probe recognises (else the next call
#      would write it again and the receipt would still say NO DISPATCHER).
#  D2  a driver already exists -> left byte-for-byte alone.
#  D3  the box drives the tick from root's crontab -> NO cron.d file. A second
#      driver would double the tick (this is how the control plane runs).
#  D4  the owner opted out (`heartbeat uninstall`) -> respected, nothing written.
#  D5  the root crontab is unreadable (not root) -> failed, not a guess.
#  D6  the cron dir is not writable -> failed, not a false "made".
#  D7  uninstall removes the file and records the opt-out; install clears it.
#  D8  `agent create` only promises the tick when a driver exists, and the
#      self-check reports "heartbeat on" without a driver as an issue.
#  D9  install.sh runs the verb on install/update (guarded on the bundle having
#      it and on the opt-out), pulls in cron, and uninstall removes the file.
#
# Throwaway dirs only; no root, no network.
# Run: bash tests/heartbeat_driver_install_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; chmod -R u+w "${TMP:-/nonexistent}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-driver-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/registry.sh lib/routing_receipt.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
export FIVEDIVE_HB_CRON_DIR="$TMP/cron.d"; mkdir -p "$FIVEDIVE_HB_CRON_DIR"
JSON_MODE=0
require_root() { :; }
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
CRON="$FIVEDIVE_HB_CRON_DIR/5dive-heartbeat"
reset() { rm -f "$CRON" "$STATE_DIR/heartbeat-driver.off"; chmod u+w "$FIVEDIVE_HB_CRON_DIR"; }

# The probe's own pattern, read from the source so the two cannot drift.
PROBE_RE=$(grep -oE "grep -qE '[^']*heartbeat\[\[:space:\]\]\+tick'" "$SRC/lib/routing_receipt.sh" | head -1 | sed -E "s/^grep -qE '//; s/'$//")

# D1
reset; _routing_receipt_dispatcher() { printf 'absent\n'; }
r=$(_hb_driver_ensure)
mode=$(stat -c %a "$CRON" 2>/dev/null)
{ [[ "$r" == "made:$CRON" ]] && [[ "$mode" == 644 ]] \
    && grep -qxF '*/5 * * * * root /usr/local/bin/5dive heartbeat tick >> /var/log/5dive-heartbeat.log 2>&1' "$CRON" \
    && [[ -n "$PROBE_RE" ]] && grep -qE "$PROBE_RE" "$CRON"; } \
  && ok_t "D1 no driver: writes $CRON (644) with the managed tick line, which the dispatcher probe recognises" \
  || bad_t "D1 driver not written as expected" "r=$r mode=$mode re=$PROBE_RE $(cat "$CRON" 2>/dev/null)"

# D2
echo "# hand-tuned" > "$CRON"; _routing_receipt_dispatcher() { printf 'installed:%s\n' "$CRON"; }
r=$(_hb_driver_ensure)
{ [[ "$r" == "installed:$CRON" ]] && [[ "$(cat "$CRON")" == "# hand-tuned" ]]; } \
  && ok_t "D2 an existing driver is reported and left untouched" \
  || bad_t "D2 existing driver rewritten" "r=$r content=$(cat "$CRON")"

# D3
reset; _routing_receipt_dispatcher() { printf 'installed:root crontab\n'; }
r=$(_hb_driver_ensure)
{ [[ "$r" == "installed:root crontab" ]] && [[ ! -e "$CRON" ]]; } \
  && ok_t "D3 a root-crontab driver means no second driver in cron.d" \
  || bad_t "D3 doubled the driver" "r=$r"

# D4
reset; : > "$STATE_DIR/heartbeat-driver.off"; _routing_receipt_dispatcher() { printf 'absent\n'; }
r=$(_hb_driver_ensure)
{ [[ "$r" == off:* ]] && [[ ! -e "$CRON" ]]; } \
  && ok_t "D4 the uninstall opt-out is respected" \
  || bad_t "D4 opt-out ignored" "r=$r"

# D5
reset; _routing_receipt_dispatcher() { printf 'unknown:root crontab is not readable as nobody\n'; }
r=$(_hb_driver_ensure)
{ [[ "$r" == failed:* ]] && [[ ! -e "$CRON" ]]; } \
  && ok_t "D5 an unreadable root crontab is 'failed', never a write" \
  || bad_t "D5 wrote on an unknown" "r=$r"

# D6
reset; _routing_receipt_dispatcher() { printf 'absent\n'; }; chmod a-w "$FIVEDIVE_HB_CRON_DIR"
r=$(_hb_driver_ensure)
chmod u+w "$FIVEDIVE_HB_CRON_DIR"
if [[ $EUID -eq 0 ]]; then ok_t "D6 skipped as root (a read-only dir is still writable for root)"
else
  { [[ "$r" == failed:* ]] && [[ ! -e "$CRON" ]]; } \
    && ok_t "D6 an unwritable cron dir is 'failed', not 'made'" \
    || bad_t "D6 claimed a write it could not make" "r=$r"
fi

# D7
reset; _routing_receipt_dispatcher() { [[ -f "$CRON" ]] && printf 'installed:%s\n' "$CRON" || printf 'absent\n'; }
out_i1=$(cmd_heartbeat_install 2>&1)
out_u=$(cmd_heartbeat_uninstall 2>&1)
gone=$([[ ! -e "$CRON" && -e "$STATE_DIR/heartbeat-driver.off" ]] && echo y)
again=$(_hb_driver_ensure)
out_i2=$(cmd_heartbeat_install 2>&1)
{ [[ "$out_i1" == *"driver installed"* ]] && [[ "$gone" == y ]] && [[ "$again" == off:* ]] \
    && [[ "$out_i2" == *"driver installed"* ]] && [[ -f "$CRON" ]] && [[ ! -e "$STATE_DIR/heartbeat-driver.off" ]]; } \
  && ok_t "D7 uninstall removes + opts out (later ensures stay off); install clears the opt-out and rewrites" \
  || bad_t "D7 install/uninstall round trip" "i1=$out_i1 | u=$out_u | gone=$gone again=$again | i2=$out_i2"

# D8 — static: the promise sits only in the driver-present branch.
C=$SRC/cmd_agent_create.sh
blk=$(awk '/_hb_driver=\$\(_hb_driver_ensure/{p=1} p{print} /^      esac$/ && p{exit}' "$C")
{ grep -q 'installed:\*|made:\*)' <<<"$blk" \
    && [[ $(grep -c 'the tick will hand it board work' "$C") == 1 ]] \
    && grep -q 'the tick will hand it board work' <<<"$blk" \
    && grep -qF 'no heartbeat driver on this box' <<<"$blk" \
    && grep -qF 'heartbeat on but NO DRIVER on this box' "$C"; } \
  && ok_t "D8 create promises the tick only with a driver; says the truth and flags the self-check without one" \
  || bad_t "D8 create still promises the tick unconditionally" "$(grep -n 'tick will hand\|NO DRIVER\|_hb_driver' "$C")"

# D9 — static: install.sh wiring.
I=install.sh
{ grep -qF "grep -q 'cmd_heartbeat_install' \"\$BIN_DIR/5dive\"" "$I" \
    && grep -qF 'heartbeat-driver.off' "$I" \
    && grep -qF '"$BIN_DIR/5dive" heartbeat install' "$I" \
    && grep -qE '^APT_PKGS="[^"]*\bcron\b' "$I" \
    && grep -qF 'rm -f /etc/cron.d/5dive-heartbeat' "$I"; } \
  && ok_t "D9 install.sh installs the driver (guarded), pulls in cron, and uninstall removes it" \
  || bad_t "D9 install.sh wiring missing" "$(grep -n 'heartbeat install\|heartbeat-driver\|APT_PKGS=\|5dive-heartbeat' "$I")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
