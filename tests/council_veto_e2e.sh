#!/usr/bin/env bash
# CNCL-9 bash e2e — the authenticated founder veto WIRING (not just the node engine). Drives the
# real `5dive council {init,convene,veto exercise,lineage verify}` bundle against an isolated
# STATE_DIR + a self-provisioned gate-proof key, and asserts the four legs main's hard gate
# required (2026-07-19): nonce-mismatch refused+logged, window-expiry refused, a real tap flipping
# pass->blocked inside a sealed receipt, and lineage-verify GREEN after the veto. Plus the security
# amendments: the receipt stores only the nonce DIGEST (never the raw bearer token), the pings
# audit is 0600, a forged `--veto-by` is refused+logged, and a tampered receipt canonical is
# refused (the re-seal hardening). Offline: COUNCIL_MOCK, no key/network/live tasks.db.
#
# Needs root (the gate-proof seal runs in-process against the isolated STATE_DIR). Re-execs under
# passwordless sudo when available; SKIPs (green) otherwise — same posture as the node-skip in
# council_unit.sh, so CI never goes red on a runner that can't seal.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
FIVE="$ROOT/5dive"

for b in node jq openssl sha256sum; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (council veto e2e needs it)"; exit 0; }
done
[[ -x "$FIVE" ]] || { echo "SKIP: built ./5dive not found (run ./build.sh first)"; exit 0; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if sudo -n true 2>/dev/null; then exec sudo -n env PATH="$PATH" bash "$0" "$@"; fi
  echo "SKIP: council veto e2e needs root (in-process gate-proof seal) and passwordless sudo is unavailable"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export STATE_DIR="$TMP" COUNCIL_MOCK=1
SINK="$TMP/nonce.sink"
pass=0; fail=0
ok(){ echo "  ok:   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
sha(){ printf '%s' "$1" | sha256sum | awk '{print $1}'; }

# CNCL-15: init now seeds a 5dive.md and the constitution GOVERNS the veto window (posthoc_secs),
# so the posthoc window is expressed in the constitution the council is seeded with — not via the
# pre-constitution COUNCIL_VETO_POSTHOC_SECS env (a valid on-disk file wins over it, by design).
# Seed a constitution with a 0s posthoc window (15m hold kept) so the window-expiry leg below fires.
cat > "$TMP/5dive.md" <<'EOF'
---
council:
  bench: council
veto:
  hold_secs: 900
  posthoc_secs: 0
---

# 5dive Constitution (veto e2e — zero posthoc window)
EOF

# --- genesis + a convene that offers the founder veto --------------------------------------------
"$FIVE" council init --seats="a:chair,b,c" --threshold="majority" --veto="tg:433634012" >/dev/null 2>&1 \
  || { echo "FAIL: council init (cannot seal genesis — no gate-proof rail?)"; exit 1; }

COUNCIL_VETO_NONCE_SINK="$SINK" "$FIVE" council convene "e2e: ship the thing?" --seats="a:chair,b,c" --mode=quick >/dev/null 2>&1 \
  || { echo "FAIL: council convene"; exit 1; }
RCPT="$(ls -1 "$TMP/council/receipts/"*.json 2>/dev/null | head -1)"
[[ -f "$RCPT" ]] || { echo "FAIL: no sealed receipt produced"; exit 1; }
DIGEST="$(jq -r '.sealedDigest' "$RCPT")"
NONCE="$(cat "$SINK" 2>/dev/null)"
[[ -n "$DIGEST" && -n "$NONCE" ]] || { echo "FAIL: could not read sealed digest / captured nonce"; exit 1; }

# --- security amendment 2: receipt stores the DIGEST, never the raw nonce; pings 0600 ------------
[[ "$(jq -r '.vetoNonceDigest // empty' "$RCPT")" == "$(sha "$NONCE")" ]] \
  && ok "receipt stores vetoNonceDigest = sha256(nonce)" || no "receipt vetoNonceDigest wrong/missing"
[[ -z "$(jq -r '.vetoNonce // empty' "$RCPT")" ]] \
  && ok "receipt does NOT carry the raw nonce" || no "raw nonce leaked into the receipt"
perm="$(stat -c '%a' "$TMP/council/veto-pings.jsonl" 2>/dev/null || echo '-')"
[[ "$perm" == "600" ]] && ok "veto-pings.jsonl is 0600" || no "veto-pings.jsonl perms=$perm (want 600)"
[[ -z "$(jq -r '.nonce // empty' "$TMP/council/veto-pings.jsonl" 2>/dev/null)" ]] \
  && ok "pings audit carries no raw nonce (digest only)" || no "pings audit leaked the raw nonce"

# --- leg: nonce-mismatch refused + LOGGED --------------------------------------------------------
if "$FIVE" council veto exercise --receipt="$DIGEST" --nonce="deadbeefdeadbeefdeadbeefdeadbeef" >/dev/null 2>&1; then
  no "nonce-mismatch exercise was NOT refused"
else
  ok "nonce-mismatch exercise refused"
fi
[[ -f "$TMP/council/veto-audit.jsonl" ]] && grep -q '"event":"nonce-mismatch"' "$TMP/council/veto-audit.jsonl" \
  && ok "nonce-mismatch written to the durable veto audit" || no "nonce-mismatch not logged"

# --- leg: window-expiry refused (posthoc past the constitution's zero window) --------------------
# The 0s posthoc window comes from the seeded constitution (CNCL-15: the file governs it).
if "$FIVE" council veto exercise --receipt="$DIGEST" --nonce="$NONCE" --tier=posthoc >/dev/null 2>&1; then
  no "expired-window exercise was NOT refused"
else
  ok "window-expiry exercise refused (past posthoc window)"
fi

# --- leg: a REAL tap flips pass->blocked inside a sealed record ----------------------------------
"$FIVE" council veto exercise --receipt="$DIGEST" --nonce="$NONCE" --tier=hold >/dev/null 2>&1 \
  || no "valid veto exercise returned nonzero"
VREC="$(ls -1t "$TMP/council/receipts/"veto-*.json 2>/dev/null | head -1)"
if [[ -f "$VREC" ]]; then
  ok "chained veto record sealed to disk"
  [[ "$(jq -r '.flippedVerdict.vetoed // false' "$VREC")" == "true" \
     && "$(jq -r '.flippedVerdict.disposition // empty' "$VREC")" == "blocked" ]] \
    && ok "authenticated tap flipped pass->blocked (vetoed, sealed)" \
    || no "sealed veto record is not vetoed/blocked"
else
  no "no sealed veto record written"
fi

# --- leg: lineage verify GREEN after the veto (the chain-defect regression) ----------------------
if "$FIVE" council lineage verify >/dev/null 2>&1; then
  ok "lineage verify GREEN after veto"
else
  no "lineage verify BROKEN after veto (chain defect)"
fi
ent="$(wc -l < "$TMP/council/lineage.jsonl" 2>/dev/null | tr -d ' ')"
[[ "$ent" == "2" ]] && ok "lineage has genesis + veto (2 entries)" || no "lineage entry count=$ent (want 2)"
vseq="$(tail -n1 "$TMP/council/lineage.jsonl" | jq -r '.seq')"
[[ "$vseq" == "1" ]] && ok "veto lineage entry seq=1 (not -1)" || no "veto lineage seq=$vseq (want 1)"

# --- security amendment 3: forged --veto-by refused (exit 9) + LOGGED ----------------------------
"$FIVE" council convene "forge attempt?" --seats="a:chair,b,c" --veto-by="lodar" >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 9 ]] && ok "forged --veto-by refused (exit 9)" || no "forged --veto-by exit=$rc (want 9)"
grep -q '"event":"forge-attempt-veto-by"' "$TMP/council/veto-audit.jsonl" 2>/dev/null \
  && ok "forge attempt written to the durable veto audit" || no "forge attempt not logged"

# --- hardening: a tampered receipt canonical is refused (re-seal mismatch) -----------------------
COUNCIL_VETO_NONCE_SINK="$TMP/n2" "$FIVE" council convene "second convene" --seats="a:chair,b,c" --mode=quick >/dev/null 2>&1
RCPT2="$(ls -1t "$TMP/council/receipts/"*.json | grep -v '/veto-' | head -1)"
DIG2="$(jq -r '.sealedDigest' "$RCPT2")"; N2="$(cat "$TMP/n2")"
jq '.canonical = (.canonical + " TAMPERED")' "$RCPT2" > "$TMP/rt.json" && cp "$TMP/rt.json" "$RCPT2"
if "$FIVE" council veto exercise --receipt="$DIG2" --nonce="$N2" --tier=hold >/dev/null 2>&1; then
  no "tampered-canonical receipt was NOT refused"
else
  ok "tampered-canonical receipt refused (re-seal hardening)"
fi

# --- AMENDMENT (main gate): swapping the WRAPPER .vetoNonceDigest to sha256(attacker-nonce) must be
# refused. Pre-amendment the nonce digest lived OUTSIDE .canonical, so this edit slipped past the
# re-seal check and let the attacker exercise with a chosen nonce. Now exercise reads the digest
# from the SEALED canonical (seal-augment folded it in), so the wrapper edit is ignored and the
# attacker's nonce fails authentication. .canonical is left INTACT here (re-seal still passes) to
# prove it is the seal-binding read — not the existing re-seal check — that closes this hole.
COUNCIL_VETO_NONCE_SINK="$TMP/n3" "$FIVE" council convene "third convene" --seats="a:chair,b,c" --mode=quick >/dev/null 2>&1
RCPT3="$(ls -1t "$TMP/council/receipts/"*.json | grep -v '/veto-' | head -1)"
DIG3="$(jq -r '.sealedDigest' "$RCPT3")"
ATT_NONCE="attackerchosennonce0000000000000"
jq --arg nd "$(sha "$ATT_NONCE")" '.vetoNonceDigest = $nd' "$RCPT3" > "$TMP/rt3.json" && cp "$TMP/rt3.json" "$RCPT3"
if "$FIVE" council veto exercise --receipt="$DIG3" --nonce="$ATT_NONCE" --tier=hold >/dev/null 2>&1; then
  no "swapped wrapper .vetoNonceDigest let an attacker exercise with a chosen nonce (HOLE OPEN)"
else
  ok "swapped wrapper .vetoNonceDigest refused — exercise reads the digest from the sealed canonical"
fi

echo "CNCL-9 veto e2e: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
