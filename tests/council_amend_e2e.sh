#!/usr/bin/env bash
# CNCL-15 bash e2e — CONSTITUTION AMENDMENTS wiring (real `5dive council {init,amend,convene,verify}`
# bundle against an isolated STATE_DIR + a self-provisioned gate-proof key). Asserts the acceptance:
#   (1) genesis seeds a v0 5dive.md and SEALS its digest into the genesis record;
#   (2) `council amend` runs as a constitutional-class motion — on a mock all-approve PASS the new
#       constitution is swapped on disk AND its digest is hash-chained into the lineage;
#   (3) drift FAILS CLOSED — a hand-edited 5dive.md makes `verify` go RED and a primary-council
#       `convene` ESCALATE (forged governance is not enforced), and restoring the file re-greens it;
#   (4) an INVALID proposed constitution is refused before any convene.
# Offline: COUNCIL_MOCK (mock all-approve votes), no network / tasks.db. Needs root for the
# in-process gate-proof seal; re-execs under passwordless sudo, else SKIPs green (like the peers).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
FIVE="$ROOT/5dive"

for b in node jq openssl sha256sum; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (council amend e2e needs it)"; exit 0; }
done
[[ -x "$FIVE" ]] || { echo "SKIP: built ./5dive not found (run ./build.sh first)"; exit 0; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if sudo -n true 2>/dev/null; then exec sudo -n env PATH="$PATH" bash "$0" "$@"; fi
  echo "SKIP: council amend e2e needs root (in-process gate-proof seal) and passwordless sudo is unavailable"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export STATE_DIR="$TMP" COUNCIL_MOCK=1 COUNCIL_5DIVE_BIN="$FIVE"
CFILE="$TMP/5dive.md"
LIN="$TMP/council/lineage.jsonl"
pass=0; fail=0
ok(){ echo "  ok:   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

# --- (1) genesis seeds v0 + seals its digest ----------------------------------------------------
"$FIVE" council init --seats="main:chair,theo,olivia" --threshold="majority" --veto="tg:433634012" >/dev/null 2>&1 \
  || { echo "FAIL: council init (cannot seal genesis — no gate-proof rail?)"; exit 1; }
[[ -f "$CFILE" ]] && ok "init seeded the v0 constitution on disk" || no "init did not seed 5dive.md"
GEN_DIGEST="$(jq -r 'select(.kind=="genesis") | .record.constitutionDigest' "$LIN" 2>/dev/null | head -n1)"
FILE_DIGEST="$(sha256sum < "$CFILE" | awk '{print $1}')"
[[ -n "$GEN_DIGEST" && "$GEN_DIGEST" == "$FILE_DIGEST" ]] && ok "genesis record seals the v0 constitution digest (matches the on-disk file)" || no "genesis constitutionDigest missing/mismatched (gen=$GEN_DIGEST file=$FILE_DIGEST)"
"$FIVE" council verify >/dev/null 2>&1 && ok "verify GREEN on the seeded genesis + matching constitution" || no "verify RED on a fresh genesis"

# --- (4) an invalid proposed constitution is refused BEFORE any convene --------------------------
printf 'not a constitution\n' > "$TMP/bad.md"
if "$FIVE" council amend --file="$TMP/bad.md" >/dev/null 2>&1; then no "amend accepted an invalid constitution"; else ok "amend refuses an invalid proposed 5dive.md (fail-closed, no convene)"; fi
# the refusal wrote nothing to the lineage
[[ "$(wc -l < "$LIN")" == "1" ]] && ok "a refused amend leaves the lineage untouched" || no "a refused amend touched the lineage"

# --- (2) amend carries: swap on disk + hash-chain the new digest --------------------------------
# A valid proposed constitution that CHANGES policy (bench name + a longer veto hold).
cat > "$TMP/new.md" <<'EOF'
---
council:
  bench: council
quorum: majority
veto:
  hold_secs: 1800
  posthoc_secs: 172800
hard_gates:
  secrets: 'secret|credential|api key|token|password'
---

# 5dive Constitution (amended)
EOF
NEW_DIGEST="$(sha256sum < "$TMP/new.md" | awk '{print $1}')"
A="$("$FIVE" council amend --file="$TMP/new.md" --mode=quick --json 2>/dev/null)"
[[ "$(printf '%s' "$A" | jq -r '.data.carried')" == "true" ]] && ok "amend carried (mock all-approve constitutional motion)" || no "amend did not carry ($A)"
[[ "$(printf '%s' "$A" | jq -r '.data.motion')" == "constitutional" ]] && ok "amend auto-classified constitutional (2/3 + full quorum)" || no "amend class wrong"
[[ "$(sha256sum < "$CFILE" | awk '{print $1}')" == "$NEW_DIGEST" ]] && ok "on-disk 5dive.md swapped to the ratified constitution" || no "5dive.md not swapped on a carried amend"
CHAIN_DIGEST="$(jq -r 'select((.record.constitutionDigest // "")!="") | .record.constitutionDigest' "$LIN" | tail -n1)"
[[ "$CHAIN_DIGEST" == "$NEW_DIGEST" ]] && ok "the new constitution digest is hash-chained into the lineage" || no "amend digest not chained (chain=$CHAIN_DIGEST new=$NEW_DIGEST)"
[[ "$(wc -l < "$LIN")" == "2" ]] && ok "amend appended exactly one lineage record" || no "amend lineage record count wrong"
"$FIVE" council verify >/dev/null 2>&1 && ok "verify GREEN after the amendment (live file matches the newly sealed digest)" || no "verify RED after a legit amend"

# --- (3) drift FAILS CLOSED: hand-edit -> verify RED + convene ESCALATE --------------------------
printf '\n# sneaky unsanctioned edit\n' >> "$CFILE"
if "$FIVE" council verify >/dev/null 2>&1; then no "verify GREEN on a drifted (hand-edited) constitution"; else ok "verify RED on a drifted constitution (fail-closed)"; fi
V="$("$FIVE" council verify --json 2>/dev/null)"
[[ "$(printf '%s' "$V" | jq -r '.data.constitutionOk')" == "false" ]] && ok "verify --json flags constitutionOk=false on drift" || no "verify json did not flag the drift"
# a primary-council convene under drift ESCALATES (does not enforce forged governance)
C="$("$FIVE" council convene "Ship the thing?" --json 2>/dev/null)"
[[ "$(printf '%s' "$C" | jq -r '.data.driftEscalated')" == "true" ]] && ok "primary-council convene ESCALATES under drift" || no "convene did not drift-escalate ($C)"
[[ "$(printf '%s' "$C" | jq -r '.data.verdict.recommendation')" == "escalate" ]] && ok "the drift verdict is escalate" || no "drift verdict not escalate"

# --- drift is RECOVERABLE: restore the sealed file -> GREEN again --------------------------------
cp "$TMP/new.md" "$CFILE"
"$FIVE" council verify >/dev/null 2>&1 && ok "verify GREEN again once the sealed 5dive.md is restored" || no "verify still RED after restoring the file"
[[ "$(printf '%s' "$("$FIVE" council convene "Ship the thing?" --json 2>/dev/null)" | jq -r '.data.driftEscalated // empty')" == "" ]] && ok "convene no longer drift-escalates once restored" || no "convene still drift-escalates after restore"

echo
if (( fail )); then echo "CNCL-15 amend/drift e2e: $pass passed, $fail FAILED"; exit 1; fi
echo "CNCL-15 amend/drift e2e: $pass passed, 0 failed"
