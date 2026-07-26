#!/usr/bin/env bash
# CNCL-10 co-signed-votes E2E — exercises the real `council sign-vote` / `verify-votes` CLI over
# REAL on-disk Ed25519 keys and proves: keys are 0600 owner-only, the honest path verifies green,
# and forged / cross-convene-replay / revoked-key votes are all rejected (non-zero exit). Exit 0 == green.
set -u
ENGINE="$(cd "$(dirname "$0")/.." && pwd)/src/council/engine.mjs"
CLI="$(cd "$(dirname "$0")/.." && pwd)/src/council/cli.mjs"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
P=0; F=0
chk(){ if [ "$2" = "$3" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $1 (want=$2 got=$3)"; fi; }

# --- provision two seats: private key 0600 owner-only, roster holds only pubkeys ---
node --input-type=module -e "
import { generateSeatKeypair } from '$ENGINE'; import fs from 'node:fs';
const roster = {};
for (const id of ['main','codex']) {
  const k = generateSeatKeypair();
  fs.writeFileSync('$TMP/'+id+'.key', k.privPem, { mode: 0o600 });
  roster[id] = { pub: k.pub, fingerprint: k.fingerprint, issuedAt: '2026-07-19T00:00:00Z' };
}
fs.writeFileSync('$TMP/roster.json', JSON.stringify(roster));
"
chk "main key perms 0600" "600" "$(stat -c '%a' "$TMP/main.key")"
chk "codex key perms 0600" "600" "$(stat -c '%a' "$TMP/codex.key")"

CV="cv-e2e-001"; Q="Ship 0.11.8?"
QD="$(node -e "import('$ENGINE').then(m=>process.stdout.write(m.questionDigest('$Q')))")"

# --- sign-at-source: each seat signs its OWN vote with its OWN key ---
SIG_MAIN="$(node "$CLI" sign-vote --seat=main --vote=approve --rationale=tested --convene="$CV" --qdigest="$QD" --key-file="$TMP/main.key" --emit=json)"
SIG_CODEX="$(node "$CLI" sign-vote --seat=codex --vote=approve --rationale=edges --convene="$CV" --qdigest="$QD" --key-file="$TMP/codex.key" --emit=json)"
VOTES="[$SIG_MAIN,$SIG_CODEX]"

# --- honest path verifies green (exit 0) ---
node "$CLI" verify-votes --votes="$VOTES" --roster="@$TMP/roster.json" --convene="$CV" --qdigest="$QD" >/dev/null 2>&1
chk "honest path verifies (exit 0)" "0" "$?"

# --- FORGE: flip main's vote approve->reject after signing ---
FORGED="[$(echo "$SIG_MAIN" | sed 's/"vote":"approve"/"vote":"reject"/'),$SIG_CODEX]"
node "$CLI" verify-votes --votes="$FORGED" --roster="@$TMP/roster.json" --convene="$CV" --qdigest="$QD" >/dev/null 2>&1
chk "forged vote rejected (exit 5)" "5" "$?"

# --- REPLAY: present main's honest vote under a DIFFERENT convene id ---
node "$CLI" verify-votes --votes="$VOTES" --roster="@$TMP/roster.json" --convene="cv-OTHER" --qdigest="$QD" >/dev/null 2>&1
chk "cross-convene replay rejected (exit 5)" "5" "$?"

# --- REVOKED: codex demoted, key revoked in roster ---
REVROSTER="$(node -e "const r=require('$TMP/roster.json');r.codex.revokedAt='2026-07-19T13:00:00Z';process.stdout.write(JSON.stringify(r))")"
node "$CLI" verify-votes --votes="$VOTES" --roster="$REVROSTER" --convene="$CV" --qdigest="$QD" >/dev/null 2>&1
chk "revoked-key vote rejected (exit 5)" "5" "$?"

echo "CNCL-10 co-sign E2E: $P passed, $F failed"
[ "$F" -eq 0 ]
