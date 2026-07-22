#!/usr/bin/env bash
# DIVE-1751 e2e — `5dive constitution set --json` (browser-callable STRUCTURED-field write) on the
# BUILT binary. Proves the dashboard EDIT contract (DIVE-1750):
#   · reads a JSON patch {hard_gates,ship,comms} from STDIN, MERGES it into the CURRENT constitution,
#     re-serializes + validates the YAML in the CLI (no browser YAML — DIVE-1700), and seals via the
#     EXACT SAME routing as `set --file=` (solo direct-seal / org council-amend from the sealed seat count).
#   · on a SOLO seal it emits EXACTLY ONE envelope — the `constitution show --json` view — and
#     `council verify` stays GREEN (DIVE-1695 drift applies to the sealed bytes).
#   · governance keys (council/quorum/veto/thresholds) are UNREACHABLE via this path (fail-closed),
#     and a real multi-seat council returns the machine amend-route and NEVER clobbers.
# Needs root for the in-process gate-proof seal; re-execs under passwordless sudo, else SKIPs green
# (like the council seal-path peers). Exit 0 == green.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
FIVE="$ROOT/5dive"

for b in node jq openssl sha256sum; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (constitution set --json e2e needs it)"; exit 0; }
done
if [[ ! -x "$FIVE" ]]; then
  if ! bash "$ROOT/build.sh" >/dev/null 2>&1 || [[ ! -x "$FIVE" ]]; then
    echo "SKIP: could not build ./5dive (build.sh failed)"; exit 0
  fi
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if sudo -n true 2>/dev/null; then exec sudo -n env PATH="$PATH" bash "$0" "$@"; fi
  echo "SKIP: constitution set --json e2e needs root (in-process gate-proof seal) and passwordless sudo is unavailable"
  exit 0
fi

BASE="$(mktemp -d)"; trap 'rm -rf "$BASE"' EXIT
pass=0; fail=0
ok(){ echo "  ok:   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

# ============================ SOLO route (fresh state, no council) ==============================
S="$BASE/solo"; mkdir -p "$S"
export STATE_DIR="$S" COUNCIL_5DIVE_BIN="$FIVE"
CFILE="$S/constitution.yaml"; LIN="$S/council/lineage.jsonl"; GEN="$S/council/genesis.json"

# 1) fresh SOLO structured write: seal ship.require_ci + comms.public_requires_human on a first save.
OUT="$(echo '{"ship":{"require_ci":true},"comms":{"public_requires_human":true}}' | "$FIVE" constitution set --json --principal=tg:1 2>/dev/null)"
[[ "$(jq -r '.ok' <<<"$OUT")" == "true" ]] && ok "solo set --json succeeds on a fresh state" || no "solo set --json failed ($OUT)"
# EXACTLY ONE JSON object on stdout (the show envelope) — the seal's own genesis envelope is swallowed.
[[ "$(jq -rs 'length' <<<"$OUT")" == "1" ]] && ok "emits exactly ONE JSON envelope (single-parse for the dashboard)" || no "emitted $(jq -rs 'length' <<<"$OUT") JSON objects (want 1)"
[[ "$(jq -r '.data.valid' <<<"$OUT")" == "true" ]] && ok "envelope is the constitution show --json view (valid=true)" || no "envelope not the show view ($OUT)"
[[ "$(jq -r '.data.ship.require_ci' <<<"$OUT")" == "true" ]] && ok "ship.require_ci sealed + reflected" || no "ship.require_ci not set ($OUT)"
[[ "$(jq -r '.data.comms.public_requires_human' <<<"$OUT")" == "true" ]] && ok "comms.public_requires_human sealed + reflected" || no "comms.public_requires_human not set"
SEALED1="$(jq -r '.data.sealedDigest' <<<"$OUT")"
[[ "$SEALED1" =~ ^[0-9a-f]{64}$ ]] && ok "a sealed digest is present in the envelope" || no "no sealed digest ($SEALED1)"
[[ -f "$GEN" ]] && ok "solo set --json created a single-principal genesis" || no "no genesis written"

# 2) the on-disk file matches the sealed digest, show agrees, verify is GREEN.
[[ "$(sha256sum < "$CFILE" | awk '{print $1}')" == "$SEALED1" ]] && ok "the live constitution.yaml digest == the sealed digest" || no "live file digest != sealed"
[[ "$(jq -r '.data.drifted' <<<"$OUT")" == "false" ]] && ok "not drifted right after the structured seal" || no "drifted right after seal"
"$FIVE" council verify >/dev/null 2>&1 && ok "council verify GREEN after the structured seal" || no "council verify RED after structured seal"

# 3) re-seal editing ONE hard_gates class — the OTHER classes are preserved (merge, not replace).
OUT2="$(echo '{"hard_gates":{"secrets":"secret|token|apikey|passphrase"}}' | "$FIVE" constitution set --json 2>/dev/null)"
[[ "$(jq -r '.data.hard_gates.secrets' <<<"$OUT2")" == "secret|token|apikey|passphrase" ]] && ok "hard_gates.secrets updated via the structured path" || no "secrets not updated ($OUT2)"
[[ "$(jq -r '.data.hard_gates_source.secrets' <<<"$OUT2")" == "custom" ]] && ok "edited class reads as customized" || no "secrets source not custom"
[[ "$(jq -r '.data.hard_gates_source.spend_billing' <<<"$OUT2")" == "default" ]] && ok "untouched classes survive the merge (spend_billing still default)" || no "an untouched class was clobbered"
[[ "$(jq -r '.data.sealedDigest' <<<"$OUT2")" != "$SEALED1" ]] && ok "the re-seal chains a NEW sealed digest" || no "re-seal did not change the sealed digest"
[[ "$(jq -sr 'map(select(.record.seats!=null)) | (last.record.seats|length)' "$LIN")" == "1" ]] && ok "re-seal keeps a single-principal genesis (no convene)" || no "re-seal changed the seat count"
"$FIVE" council verify >/dev/null 2>&1 && ok "council verify GREEN after the structured re-seal" || no "verify RED after re-seal"

# 4) governance keys are UNREACHABLE via the structured path (fail-closed) — lineage untouched.
LINES_BEFORE="$(wc -l < "$LIN")"
for bad in '{"veto":{"principal":"human:evil"}}' '{"council":{"bench":"packed"}}' '{"quorum":"none"}' '{"thresholds":{"constitutional":"1"}}'; do
  R="$(echo "$bad" | "$FIVE" constitution set --json 2>/dev/null)"
  [[ "$(jq -r '.ok' <<<"$R")" == "false" ]] && ok "refused governance key: $bad" || no "governance key NOT refused: $bad ($R)"
done
[[ "$(wc -l < "$LIN")" == "$LINES_BEFORE" ]] && ok "refused structured writes leave the lineage untouched" || no "a refused structured write touched the lineage"

# 5) malformed guardrail patches are refused before any seal.
for bad in \
  '{"ship":{"require_ci":true,"backdoor":true}}' \
  '{"comms":{"public_requires_human":"yes"}}' \
  '{"hard_gates":{"secrets":123}}' \
  '{"hard_gates":{"totally_new_class":"x"}}' \
  'not json'; do
  R="$(echo "$bad" | "$FIVE" constitution set --json 2>/dev/null)"
  [[ "$(jq -r '.ok' <<<"$R")" == "false" ]] && ok "refused malformed patch: $bad" || no "malformed patch NOT refused: $bad ($R)"
done
[[ "$(wc -l < "$LIN")" == "$LINES_BEFORE" ]] && ok "malformed patches seal nothing" || no "a malformed patch touched the lineage"

# 6) an empty patch is a no-op SAVE (re-serialize + re-seal current) — still a valid green envelope.
OUT3="$(echo '{}' | "$FIVE" constitution set --json 2>/dev/null)"
[[ "$(jq -r '.data.valid' <<<"$OUT3")" == "true" ]] && ok "an empty patch re-seals the current constitution (no-op save)" || no "empty patch envelope invalid ($OUT3)"
"$FIVE" council verify >/dev/null 2>&1 && ok "council verify GREEN after the empty-patch re-seal" || no "verify RED after empty-patch re-seal"

# ============================ ORG route (multi-seat council) ====================================
# A real multi-seat council governs -> the structured write is REFUSED with a machine amend-route and
# NEVER clobbers (the dashboard renders read-only; this is the fail-closed server-side backstop).
O="$BASE/org"; mkdir -p "$O"
export STATE_DIR="$O"
OLIN="$O/council/lineage.jsonl"
"$FIVE" council init --seats="main:chair,theo,olivia" --threshold="majority" --veto="tg:433634012" >/dev/null 2>&1 \
  || { echo "FAIL: could not seed a multi-seat council for the org route"; exit 1; }
OB="$(echo '{"ship":{"require_ci":true}}' | "$FIVE" constitution set --json 2>/dev/null)"
[[ "$(jq -r '.ok' <<<"$OB")" == "true" ]] && ok "org structured write returns a machine envelope" || no "org write no envelope ($OB)"
[[ "$(jq -r '.data.mode' <<<"$OB")" == "council" ]] && ok "a multi-seat council routes to the amend-route (not a solo seal)" || no "org route not 'council' ($OB)"
[[ "$(jq -r '.data.sealed' <<<"$OB")" == "false" ]] && ok "org structured write seals NOTHING (never clobbers)" || no "org write reported a seal"
[[ "$(wc -l < "$OLIN")" == "1" ]] && ok "the org lineage is untouched by the refused structured write" || no "org structured write touched the lineage"

echo "DIVE-1751 constitution set --json e2e: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
