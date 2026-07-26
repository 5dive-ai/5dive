#!/usr/bin/env bash
# DIVE-1565 ballot-tap E2E — proves the human ballot TAP->task-close BRIDGE is REACHABLE through the
# real BASH dispatcher (src/cmd_council.sh -> cli.mjs), driving the BUILT ./5dive binary (not `node
# cli.mjs` directly), the surface the DIVE-1566 telegram plugin actually shells (CNCL-26 bash-route
# lesson: an .mjs-only test would miss an embed-drift break).
#
# It builds a throwaway ./5dive to a temp dir (BUILD_OUT, pure-bash + fast) so it GATES in CI too. A
# FAKE `5dive` at COUNCIL_5DIVE_BIN stands in for the board: `task ls --json` returns one OPEN human
# ballot whose body carries nonceDigest=sha256(NONCE); `task done` is logged. SKIPs green when node/
# jq/sha256sum are missing or the build fails. Exit 0 == green.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for b in node jq sha256sum; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (council ballot-tap e2e needs it)"; exit 0; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FIVE="$TMP/5dive"
if ! BUILD_OUT="$FIVE" bash "$ROOT/build.sh" >/dev/null 2>&1 || [[ ! -x "$FIVE" ]]; then
  echo "SKIP: could not build a throwaway ./5dive (build.sh failed)"; exit 0
fi
export STATE_DIR="$TMP"  # isolate — never touch a live state dir

P=0; F=0
chk(){ if [ "$2" = "$3" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $1 (want=$2 got=$3)"; fi; }

NONCE="deadbeefdeadbeefdeadbeefdeadbeef"                       # a 16-byte hex one-time nonce
DIGEST="$(printf '%s' "$NONCE" | sha256sum | cut -d' ' -f1)"   # what the ballot body stores

# --- fake board: `task ls` yields one OPEN human ballot (DIVE-1600) carrying the nonce DIGEST;
#     `task done` is logged so we can assert what the tap wrote. ---
FAKE="$TMP/fake-5dive"; DLOG="$TMP/done.log"; export DLOG DIGEST
cat > "$FAKE" <<'EOS'
#!/usr/bin/env bash
if [ "$1" = "task" ] && [ "$2" = "ls" ]; then
  cat <<JSON
{"ok":true,"data":{"tasks":[
  {"id":1600,"ident":"DIVE-1600","status":"todo","body":"vote please\n[council ballot-auth] nonceDigest=${DIGEST}"},
  {"id":1601,"ident":"DIVE-1601","status":"todo","body":"agent ballot — Cast your vote by CLOSING this task"}
]}}
JSON
  exit 0
fi
if [ "$1" = "task" ] && [ "$2" = "done" ]; then
  echo "$*" >> "$DLOG"; echo '{"ok":true,"data":{}}'; exit 0
fi
exit 1
EOS
chmod +x "$FAKE"

run(){ COUNCIL_5DIVE_BIN="$FAKE" "$FIVE" council ballot-tap "$@" 2>/dev/null; }

# --- A) a valid approve tap resolves the ballot by prefix, verifies the nonce, closes with the line ---
: > "$DLOG"
OUT="$(run --convene=DIVE-1600 --vote=a --nonce="$NONCE"; echo "rc=$?")"
RC="$(echo "$OUT" | sed -n 's/^rc=//p')"; JSON="$(echo "$OUT" | sed '/^rc=/d')"
chk "valid tap exits 0"                "0"          "$RC"
chk "valid tap reports ok"             "true"       "$(echo "$JSON" | jq -r '.ok' 2>/dev/null)"
chk "valid tap maps a->approve"        "approve"    "$(echo "$JSON" | jq -r '.vote' 2>/dev/null)"
chk "valid tap resolves the task id"   "DIVE-1600"  "$(echo "$JSON" | jq -r '.taskId' 2>/dev/null)"
if grep -qF 'COUNCIL-VOTE: approve :: (human tap)' "$DLOG"; then chk "tap closes ballot with the COUNCIL-VOTE line" "yes" "yes"; else chk "tap closes ballot with the COUNCIL-VOTE line" "yes" "no"; fi

# --- B) the canonical --ref flag works identically to the --convene alias ---
: > "$DLOG"
chk "--ref alias maps r->reject" "reject" "$(run --ref=DIVE-1600 --vote=r --nonce="$NONCE" | jq -r '.vote' 2>/dev/null)"
if grep -qF 'COUNCIL-VOTE: reject :: (human tap)' "$DLOG"; then chk "--ref close writes reject" "yes" "yes"; else chk "--ref close writes reject" "yes" "no"; fi

# --- C) the third button (Abstain, e) is a valid vote ---
chk "e -> abstain" "abstain" "$(run --ref=DIVE-1600 --vote=e --nonce="$NONCE" | jq -r '.vote' 2>/dev/null)"

# --- D) a WRONG nonce is fail-closed (unauthenticated tap never closes the ballot) ---
: > "$DLOG"
BAD="$(run --ref=DIVE-1600 --vote=a --nonce=bogusnonce; echo "rc=$?")"
chk "wrong nonce exits non-zero" "5" "$(echo "$BAD" | sed -n 's/^rc=//p')"
chk "wrong nonce reports not-ok" "false" "$(echo "$BAD" | sed '/^rc=/d' | jq -r '.ok' 2>/dev/null)"
if [ -s "$DLOG" ]; then chk "wrong nonce never closes the ballot" "empty" "nonempty"; else chk "wrong nonce never closes the ballot" "empty" "empty"; fi

# --- E) an unknown prefix is a MISS; an agent ballot (no nonceDigest) is invisible to the bridge ---
chk "unknown ref -> miss"   "no match" "$(run --ref=DIVE-9999 --vote=a --nonce="$NONCE" | jq -r '.reason' 2>/dev/null)"
chk "agent ballot not tap-closable" "no match" "$(run --ref=DIVE-1601 --vote=a --nonce="$NONCE" | jq -r '.reason' 2>/dev/null)"

echo "DIVE-1565 ballot-tap E2E: $P passed, $F failed"
[ "$F" -eq 0 ]
