#!/usr/bin/env bash
# CNCL-26 bash-route E2E — proves `5dive council sign-vote` / `verify-votes` are REACHABLE
# through the real BASH dispatcher (src/cmd_council.sh), not just via `node cli.mjs` directly.
#
# This closes the blind spot that let CNCL-10 ship a gap: the co-sign engine + cli routes were
# fully tested, but the bash allowlist in cmd_council() never routed sign-vote/verify-votes, so
# `5dive council sign-vote` died E_USAGE ("unknown council command"). Every CNCL-10 test drove
# `node "$CLI"` directly, so 5/5 CI stayed green while the SHELL surface — the one a seat actually
# invokes from its own harness during a dispatched convene — was dead. This harness drives the
# BUILT binary so the dispatcher IS the thing under test.
#
# It builds a throwaway ./5dive to a temp dir (build.sh is pure-bash + fast, honours BUILD_OUT) so
# it GATES in CI too (CI never builds ./5dive, and no root/sudo/seal is needed — these verbs are
# pure). SKIPs green only when node/jq/openssl are missing or the build fails. Exit 0 == green.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/src/council/engine.mjs"
for b in node jq openssl; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (council bash-route e2e needs it)"; exit 0; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FIVE="$TMP/5dive"
if ! BUILD_OUT="$FIVE" bash "$ROOT/build.sh" >/dev/null 2>&1 || [[ ! -x "$FIVE" ]]; then
  echo "SKIP: could not build a throwaway ./5dive (build.sh failed)"; exit 0
fi
export STATE_DIR="$TMP"  # isolate — never touch a live state dir

P=0; F=0
chk(){ if [ "$2" = "$3" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $1 (want=$2 got=$3)"; fi; }

# --- REGRESSION GUARD: the bash dispatcher must ROUTE these verbs, not reject them as unknown. ---
# Pre-fix this printed "unknown council command" and exited E_USAGE; post-fix it reaches the mjs
# verb, which errors on the MISSING flag ("sign-vote needs --seat"). We assert on that difference.
UNK="$("$FIVE" council sign-vote 2>&1 || true)"
case "$UNK" in
  *"unknown council command"*) chk "sign-vote is routed (not unknown)" "routed" "unknown" ;;
  *) chk "sign-vote is routed (not unknown)" "routed" "routed" ;;
esac
UNKV="$("$FIVE" council verify-votes 2>&1 || true)"
case "$UNKV" in
  *"unknown council command"*) chk "verify-votes is routed (not unknown)" "routed" "unknown" ;;
  *) chk "verify-votes is routed (not unknown)" "routed" "routed" ;;
esac

# --- provision two seats (0600 keys, roster holds pubkeys only) ---
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
CV="cv-bashroute-001"; Q="Ship it via the shell?"
QD="$(node -e "import('$ENGINE').then(m=>process.stdout.write(m.questionDigest('$Q')))")"

# --- sign-at-source THROUGH THE BASH ROUTE (the product surface a seat uses) ---
SIG_MAIN="$("$FIVE" council sign-vote --seat=main --vote=approve --rationale=tested --convene="$CV" --qdigest="$QD" --key-file="$TMP/main.key" --emit=json)"
chk "bash sign-vote emits the signing seat" "main" "$(echo "$SIG_MAIN" | jq -r .seat 2>/dev/null)"
SIG_CODEX="$("$FIVE" council sign-vote --seat=codex --vote=approve --rationale=edges --convene="$CV" --qdigest="$QD" --key-file="$TMP/codex.key" --emit=json)"

# --- default emit (=line): the COUNCIL-SIG: contract must survive the bash wrapper verbatim ---
LINE="$("$FIVE" council sign-vote --seat=main --vote=approve --convene="$CV" --qdigest="$QD" --key-file="$TMP/main.key")"
case "$LINE" in
  "COUNCIL-SIG: "*) chk "bash sign-vote line contract intact" "ok" "ok" ;;
  *) chk "bash sign-vote line contract intact" "ok" "got:$LINE" ;;
esac

VOTES="[$SIG_MAIN,$SIG_CODEX]"

# --- honest verify THROUGH THE BASH ROUTE exits 0 ---
"$FIVE" council verify-votes --votes="$VOTES" --roster="@$TMP/roster.json" --convene="$CV" --qdigest="$QD" >/dev/null 2>&1
chk "bash verify-votes honest (exit 0)" "0" "$?"

# --- the non-zero exit contract must SURVIVE the bash wrapper (a seat harness gates on it) ---
FORGED="[$(echo "$SIG_MAIN" | sed 's/"vote":"approve"/"vote":"reject"/'),$SIG_CODEX]"
"$FIVE" council verify-votes --votes="$FORGED" --roster="@$TMP/roster.json" --convene="$CV" --qdigest="$QD" >/dev/null 2>&1
chk "bash verify-votes forged (exit 5)" "5" "$?"

# --- cross-convene replay likewise rejected through the wrapper ---
"$FIVE" council verify-votes --votes="$VOTES" --roster="@$TMP/roster.json" --convene="cv-OTHER" --qdigest="$QD" >/dev/null 2>&1
chk "bash verify-votes replay (exit 5)" "5" "$?"

echo "CNCL-26 bash-route E2E: $P passed, $F failed"
[ "$F" -eq 0 ]
