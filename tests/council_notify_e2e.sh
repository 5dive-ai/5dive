#!/usr/bin/env bash
# DIVE-1494 (1) bash e2e — the read-only convene NOTICE wiring. Drives the real
# `5dive council {init,convene}` bundle against an isolated STATE_DIR and asserts the notice:
#   (a) fires when COUNCIL_NOTIFY is set, carrying the disposition + tally (aA/rR/eE) + receipt,
#   (b) carries NO raw nonce / bearer token (read-only — distinct from the founder veto ping),
#   (c) stays SILENT when COUNCIL_NOTIFY is unset (opt-in).
# Offline via the MOCK + COUNCIL_NOTIFY_SINK seam (double-gated, mirrors COUNCIL_VETO_NONCE_SINK) so
# PRODUCTION never writes the sink and delivers solely via the guarded-optional `_tg_send` seam.
#
# Needs root (the convene seal runs in-process against the isolated STATE_DIR). Re-execs under
# passwordless sudo when available; SKIPs (green) otherwise — same posture as council_veto_e2e.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
FIVE="$ROOT/5dive"

for b in node jq openssl sha256sum; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (council notify e2e needs it)"; exit 0; }
done
[[ -x "$FIVE" ]] || { echo "SKIP: built ./5dive not found (run ./build.sh first)"; exit 0; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if sudo -n true 2>/dev/null; then exec sudo -n env PATH="$PATH" bash "$0" "$@"; fi
  echo "SKIP: council notify e2e needs root (in-process seal) and passwordless sudo is unavailable"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export STATE_DIR="$TMP" COUNCIL_MOCK=1
SINK="$TMP/notify.sink"
pass=0; fail=0
ok(){ echo "  ok:   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

"$FIVE" council init --seats="a:chair,b,c" --threshold="majority" --veto="tg:1234567890" >/dev/null 2>&1 \
  || { echo "FAIL: council init (cannot seal genesis — no gate-proof rail?)"; exit 1; }

# (a) notice fires with disposition + tally when COUNCIL_NOTIFY is set
COUNCIL_NOTIFY="tg:999000" COUNCIL_NOTIFY_SINK="$SINK" \
  "$FIVE" council convene "e2e notify: ship the thing?" --seats="a:chair,b,c" --mode=quick >/dev/null 2>&1 \
  || { echo "FAIL: council convene (notify leg)"; exit 1; }
[[ -s "$SINK" ]] && ok "convene notice fired to the sink when COUNCIL_NOTIFY is set" || no "no notice captured in the sink"
NOTE="$(cat "$SINK" 2>/dev/null)"
grep -q "^Council " "$SINK" && ok "notice is a 'Council ...' summary line" || no "notice missing the 'Council' header"
grep -Eq "tally a[0-9]+/r[0-9]+/e[0-9]+" "$SINK" && ok "notice carries the aA/rR/eE tally" || no "notice missing the tally"
grep -q "receipt " "$SINK" && ok "notice references the sealed receipt" || no "notice missing the receipt reference"

# (b) read-only: the notice must NOT leak a raw nonce / bearer token (no long hex run). The veto
# nonce is 32 hex chars (openssl rand -hex 16) — assert no such token rides in the read-only notice.
if grep -Eq '[0-9a-f]{32}' "$SINK"; then no "notice leaked a 32-hex token (possible raw nonce) — must be read-only"; else ok "notice carries NO raw nonce / 32-hex token (read-only safe)"; fi

# (c) silent when COUNCIL_NOTIFY is unset (opt-in)
SINK2="$TMP/notify2.sink"
COUNCIL_NOTIFY_SINK="$SINK2" \
  "$FIVE" council convene "e2e notify: no opt-in?" --seats="a:chair,b,c" --mode=quick >/dev/null 2>&1 \
  || { echo "FAIL: council convene (no-notify leg)"; exit 1; }
[[ ! -s "$SINK2" ]] && ok "no notice fired when COUNCIL_NOTIFY is unset (opt-in)" || no "notice fired without COUNCIL_NOTIFY set"

echo "DIVE-1494 convene-notice e2e: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
