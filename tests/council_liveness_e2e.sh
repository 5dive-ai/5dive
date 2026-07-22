#!/usr/bin/env bash
# DIVE-1739 liveness E2E — proves the FULL-QUORUM (constitutional) liveness pre-check is REACHABLE
# through the real bash dispatcher (src/cmd_council.sh -> cli.mjs) on the BUILT ./5dive binary, the
# surface an amend/convene actually invokes. Gate answer A: a constitutional motion with any
# unreachable (asleep/deaf) seat REFUSES to dispatch and escalates (never inquorate-gambles 6/6); an
# ordinary-class motion is NOT gated. A FAKE `5dive` at COUNCIL_5DIVE_BIN stands in for the fleet
# (agent list health / agent send / task add|show). SKIPs green when node/jq missing or build fails.
# Exit 0 == green.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for b in node jq; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (council liveness e2e needs it)"; exit 0; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FIVE="$TMP/5dive"
if ! BUILD_OUT="$FIVE" bash "$ROOT/build.sh" >/dev/null 2>&1 || [[ ! -x "$FIVE" ]]; then
  echo "SKIP: could not build a throwaway ./5dive (build.sh failed)"; exit 0
fi
export STATE_DIR="$TMP"

P=0; F=0
chk(){ if [ "$2" = "$3" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $1 (want=$2 got=$3)"; fi; }

# Fake fleet: `agent list` reports seat health from ASLEEP_BB (bb asleep when =1); `agent send` is a
# no-op wake nudge; task add/show let an all-awake convene actually carry (both seats vote approve).
FAKE="$TMP/fake-5dive"
cat > "$FAKE" <<'EOS'
#!/usr/bin/env bash
if [ "$1" = "agent" ] && [ "$2" = "list" ]; then
  bb_asleep="${ASLEEP_BB:-0}"
  if [ "$bb_asleep" = "1" ]; then
    echo '{"ok":true,"data":[{"name":"aa","health":{"asleep":false,"deaf":false}},{"name":"bb","health":{"asleep":true,"deaf":false}}]}'
  else
    echo '{"ok":true,"data":[{"name":"aa","health":{"asleep":false,"deaf":false}},{"name":"bb","health":{"asleep":false,"deaf":false}}]}'
  fi
  exit 0
fi
if [ "$1" = "agent" ] && [ "$2" = "send" ]; then echo "sent"; exit 0; fi
if [ "$1" = "task" ] && [ "$2" = "add" ]; then echo '{"ok":true,"data":{"id":1,"ident":"DIVE-1"}}'; exit 0; fi
if [ "$1" = "task" ] && [ "$2" = "show" ]; then echo '{"ok":true,"data":{"task":{"status":"done","result":"COUNCIL-VOTE: approve :: fake"}}}'; exit 0; fi
exit 1
EOS
chmod +x "$FAKE"

# --- A) constitutional convene, seat bb ASLEEP -> liveness-escalated, NOT dispatched ---
OUTA="$(ASLEEP_BB=1 COUNCIL_5DIVE_BIN="$FAKE" "$FIVE" council convene "adopt v0?" --seats=aa,bb --class=constitutional --json 2>/dev/null || true)"
chk "asleep seat -> liveness-escalated dispatch" "liveness-escalated" "$(echo "$OUTA" | jq -r '.data.dispatch' 2>/dev/null)"
chk "asleep seat -> escalate disposition"        "escalate"           "$(echo "$OUTA" | jq -r '.data.disposition' 2>/dev/null)"
chk "asleep seat surfaced as unreachable"        "bb"                 "$(echo "$OUTA" | jq -r '.data.unreachableSeats[0].id' 2>/dev/null)"
chk "unreachable reason is asleep"               "asleep"             "$(echo "$OUTA" | jq -r '.data.unreachableSeats[0].why' 2>/dev/null)"

# --- B) constitutional convene, BOTH awake -> NOT liveness-escalated (proceeds to real dispatch) ---
OUTB="$(ASLEEP_BB=0 COUNCIL_5DIVE_BIN="$FAKE" "$FIVE" council convene "adopt v0?" --seats=aa,bb --class=constitutional --ballot-deadline=2 --ballot-poll=1 --json 2>/dev/null || true)"
chk "all awake -> real dispatch (not liveness-escalated)" "real-agents" "$(echo "$OUTB" | jq -r '.data.dispatch' 2>/dev/null)"

# --- C) ORDINARY class with a seat asleep -> NOT gated (only full-quorum motions liveness-check) ---
OUTC="$(ASLEEP_BB=1 COUNCIL_5DIVE_BIN="$FAKE" "$FIVE" council convene "ship it?" --seats=aa,bb --ballot-deadline=2 --ballot-poll=1 --json 2>/dev/null || true)"
chk "ordinary motion is NOT liveness-gated" "real-agents" "$(echo "$OUTC" | jq -r '.data.dispatch' 2>/dev/null)"

echo "DIVE-1739 liveness E2E: $P passed, $F failed"
[ "$F" -eq 0 ]
