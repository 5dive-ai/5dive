#!/usr/bin/env bash
# CNCL-18 ballot E2E — proves the NON-BLOCKING ballot dispatch is REACHABLE and DEFAULT through the
# real BASH dispatcher (src/cmd_council.sh -> cli.mjs), driving the BUILT ./5dive binary (not `node
# cli.mjs` directly), the surface a convener actually invokes.
#
# It builds a throwaway ./5dive to a temp dir (BUILD_OUT, pure-bash + fast) so it GATES in CI too.
# No root/seal/live-fleet is needed: an ad-hoc panel (--seats) skips the genesis + veto legs, an
# unsealed receipt is a valid convene (exit 0), and a FAKE `5dive` at COUNCIL_5DIVE_BIN stands in
# for the fleet (agent list / task add / task show / agent ask). SKIPs green when node/jq are
# missing or the build fails. Exit 0 == green.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for b in node jq; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (council ballot e2e needs it)"; exit 0; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FIVE="$TMP/5dive"
if ! BUILD_OUT="$FIVE" bash "$ROOT/build.sh" >/dev/null 2>&1 || [[ ! -x "$FIVE" ]]; then
  echo "SKIP: could not build a throwaway ./5dive (build.sh failed)"; exit 0
fi
export STATE_DIR="$TMP"  # isolate — never touch a live state dir

P=0; F=0
chk(){ if [ "$2" = "$3" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $1 (want=$2 got=$3)"; fi; }

# --- A) MOCK convene still works end-to-end through the bash route (offline, key-free) ---
OUT="$(COUNCIL_MOCK=1 "$FIVE" council convene "Ship it?" --seats=a,b,c --mode=deliberate --json 2>/dev/null || true)"
chk "MOCK convene exits with a verdict" "approve" "$(echo "$OUT" | jq -r '.data.verdict.recommendation' 2>/dev/null)"
chk "MOCK convene reports real-agents dispatch" "real-agents" "$(echo "$OUT" | jq -r '.data.dispatch' 2>/dev/null)"

# --- B) the CNCL-18 flags route through cmd_council() -> cli.mjs without an 'unknown flag' error ---
OUTF="$(COUNCIL_MOCK=1 "$FIVE" council convene "Ship it?" --seats=a,b,c --ask-rail --ballot-deadline=5 --ballot-poll=1 --json 2>/dev/null || true)"
chk "CNCL-18 flags are accepted through the bash route" "approve" "$(echo "$OUTF" | jq -r '.data.verdict.recommendation' 2>/dev/null)"

# --- fake fleet: log every subcommand; task show returns an already-cast ballot so the loop resolves at once ---
FAKE="$TMP/fake-5dive"; FLOG="$TMP/fleet.log"
cat > "$FAKE" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$FLOG"
if [ "$1" = "agent" ] && [ "$2" = "list" ]; then
  echo '{"ok":true,"data":[{"name":"a"},{"name":"b"},{"name":"c"}]}'; exit 0
fi
if [ "$1" = "task" ] && [ "$2" = "add" ]; then
  echo '{"ok":true,"data":{"id":1,"ident":"DIVE-1"}}'; exit 0
fi
if [ "$1" = "task" ] && [ "$2" = "show" ]; then
  echo '{"ok":true,"data":{"task":{"status":"done","result":"COUNCIL-VOTE: approve :: fake"}}}'; exit 0
fi
if [ "$1" = "agent" ] && [ "$2" = "ask" ]; then
  echo '{"ok":true,"data":{"reply":"COUNCIL-VOTE: approve :: fake"}}'; exit 0
fi
exit 1
EOS
chmod +x "$FAKE"
export FLOG

# --- C) DEFAULT (no --ask-rail, no MOCK) mints a ballot TASK — the non-blocking path ---
: > "$FLOG"
OUTB="$(COUNCIL_5DIVE_BIN="$FAKE" "$FIVE" council convene "Ship it?" --seats=a,b,c --ballot-deadline=5 --ballot-poll=1 --json 2>/dev/null || true)"
chk "default ballot convene exits with a verdict" "approve" "$(echo "$OUTB" | jq -r '.data.verdict.recommendation' 2>/dev/null)"
if grep -q "^task add" "$FLOG"; then chk "default dispatch MINTS a ballot task (non-blocking)" "yes" "yes"; else chk "default dispatch MINTS a ballot task (non-blocking)" "yes" "no"; fi
if grep -q "^agent ask" "$FLOG"; then chk "default dispatch does NOT use the agent-ask rail" "no" "yes"; else chk "default dispatch does NOT use the agent-ask rail" "no" "no"; fi

# --- D) --ask-rail escape hatch uses the OLD agent-ask pane-scrape instead of a task ---
: > "$FLOG"
COUNCIL_5DIVE_BIN="$FAKE" "$FIVE" council convene "Ship it?" --seats=a,b,c --ask-rail --timeout=5 --json >/dev/null 2>&1 || true
if grep -q "^agent ask" "$FLOG"; then chk "--ask-rail uses the agent-ask rail" "yes" "yes"; else chk "--ask-rail uses the agent-ask rail" "yes" "no"; fi
if grep -q "^task add" "$FLOG"; then chk "--ask-rail does NOT mint a ballot task" "no" "yes"; else chk "--ask-rail does NOT mint a ballot task" "no" "no"; fi

echo "CNCL-18 ballot E2E: $P passed, $F failed"
[ "$F" -eq 0 ]
