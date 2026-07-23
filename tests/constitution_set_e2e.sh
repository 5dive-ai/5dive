#!/usr/bin/env bash
# DIVE-1743 e2e — `5dive constitution set` / `edit` WRITE path on the BUILT binary. Proves the two
# routes off ONE shared parser:
#   SOLO  (no genesis, or a single-principal genesis) -> DIRECT-seal via a single-principal `council
#         init` (NO convene). First seal creates the genesis; a re-seal (--force, inherited principal)
#         chains a new digest. `constitution show` reflects the sealed digest, `council verify` is
#         GREEN, and a later hand-edit DRIFTS + fails closed (DIVE-1695).
#   ORG   (a real multi-seat council governs) -> routes to a constitutional amendment (`council
#         amend`); exercised here as --dry-run (a live convene needs live seats — covered by
#         council_amend_e2e.sh).
#   An INVALID proposed constitution is refused before any seal (fail-closed), lineage untouched.
# Needs root for the in-process gate-proof seal; re-execs under passwordless sudo, else SKIPs green
# (like the council seal-path peers). Exit 0 == green.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
FIVE="$ROOT/5dive"

for b in node jq openssl sha256sum; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (constitution set e2e needs it)"; exit 0; }
done
if [[ ! -x "$FIVE" ]]; then
  if ! bash "$ROOT/build.sh" >/dev/null 2>&1 || [[ ! -x "$FIVE" ]]; then
    echo "SKIP: could not build ./5dive (build.sh failed)"; exit 0
  fi
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if sudo -n true 2>/dev/null; then exec sudo -n env PATH="$PATH" bash "$0" "$@"; fi
  echo "SKIP: constitution set e2e needs root (in-process gate-proof seal) and passwordless sudo is unavailable"
  exit 0
fi

BASE="$(mktemp -d)"; trap 'rm -rf "$BASE"' EXIT
pass=0; fail=0
ok(){ echo "  ok:   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

good() { cat <<'EOF'
council:
  bench: council
quorum: majority
veto:
  hold_secs: 900
  posthoc_secs: 172800
hard_gates:
  spend_billing: 'spend|billing'
  public_comms: 'publish|announce'
  secrets: 'secret|token'
  destructive: 'delete|wipe'
ship:
  require_ci: true
comms:
  public_requires_human: true
EOF
}

# ============================ SOLO route (fresh state, no council) ==============================
S="$BASE/solo"; mkdir -p "$S"
export STATE_DIR="$S" COUNCIL_5DIVE_BIN="$FIVE"
CFILE="$S/constitution.yaml"; LIN="$S/council/lineage.jsonl"; GEN="$S/council/genesis.json"
PROP="$S/proposed.yaml"; good > "$PROP"
PDIG="$(sha256sum < "$PROP" | awk '{print $1}')"

# dry-run first, with NO genesis -> mode solo, no writes
D="$("$FIVE" constitution set --file="$PROP" --principal=tg:1 --dry-run --json 2>/dev/null)"
[[ "$(jq -r '.data.mode' <<<"$D")" == "solo" ]] && ok "dry-run (no council) routes SOLO" || no "dry-run route not solo ($D)"
[[ -f "$GEN" ]] && no "dry-run wrote a genesis" || ok "dry-run wrote nothing"

# real SOLO first seal
"$FIVE" constitution set --file="$PROP" --principal=tg:1 >/dev/null 2>&1 \
  || { echo "FAIL: solo set (cannot seal — no gate-proof rail?)"; exit 1; }
[[ -f "$GEN" ]] && ok "solo set created a single-principal genesis" || no "solo set wrote no genesis"
SEATS="$(jq -sr 'map(select(.record.seats!=null)) | (last.record.seats|length) // 0' "$LIN")"
[[ "$SEATS" == "1" ]] && ok "solo genesis has exactly one seat (single principal)" || no "solo genesis seat count = $SEATS (want 1)"
[[ "$(sha256sum < "$CFILE" | awk '{print $1}')" == "$PDIG" ]] && ok "the proposed constitution is now the live file" || no "live constitution != proposed"
SEALED="$(jq -r 'select((.record.constitutionDigest // "")!="") | .record.constitutionDigest' "$LIN" | tail -n1)"
[[ "$SEALED" == "$PDIG" ]] && ok "the proposed digest is sealed + hash-chained into the lineage" || no "sealed digest != proposed (sealed=$SEALED)"
"$FIVE" council verify >/dev/null 2>&1 && ok "council verify GREEN after solo seal" || no "council verify RED after solo seal"

SHOW="$("$FIVE" constitution show --json 2>/dev/null)"
[[ "$(jq -r '.data.sealedDigest' <<<"$SHOW")" == "$PDIG" ]] && ok "constitution show reports the sealed digest" || no "show sealedDigest wrong"
[[ "$(jq -r '.data.genesisExists' <<<"$SHOW")" == "true" ]] && ok "constitution show: genesisExists true" || no "show genesisExists not true"
[[ "$(jq -r '.data.drifted' <<<"$SHOW")" == "false" ]] && ok "constitution show: not drifted right after a seal" || no "show drifted true right after seal"

# re-seal (no --principal -> inherits from the existing solo genesis), new policy
PROP2="$S/proposed2.yaml"; { good; printf '\n# a solo policy tweak\n'; } > "$PROP2"
PDIG2="$(sha256sum < "$PROP2" | awk '{print $1}')"
"$FIVE" constitution set --file="$PROP2" >/dev/null 2>&1 || no "solo re-seal failed"
SEALED2="$(jq -r 'select((.record.constitutionDigest // "")!="") | .record.constitutionDigest' "$LIN" | tail -n1)"
[[ "$SEALED2" == "$PDIG2" ]] && ok "solo re-seal chains the NEW digest (inherited principal, --force)" || no "re-seal digest not chained (sealed=$SEALED2 want=$PDIG2)"
[[ "$(jq -sr 'map(select(.record.seats!=null)) | (last.record.seats|length)' "$LIN")" == "1" ]] && ok "re-seal keeps a single-principal genesis (no convene)" || no "re-seal changed the seat count"
"$FIVE" council verify >/dev/null 2>&1 && ok "council verify GREEN after re-seal" || no "verify RED after re-seal"

# an INVALID proposed constitution is refused BEFORE any write
LINES_BEFORE="$(wc -l < "$LIN")"
printf 'not a constitution\n' > "$S/bad.yaml"
if "$FIVE" constitution set --file="$S/bad.yaml" >/dev/null 2>&1; then no "solo set accepted an invalid constitution"; else ok "solo set refuses an invalid constitution (fail-closed)"; fi
[[ "$(wc -l < "$LIN")" == "$LINES_BEFORE" ]] && ok "a refused set leaves the lineage untouched" || no "a refused set touched the lineage"

# DRIFT fails closed: hand-edit the live file -> show drifted + verify RED
printf '\n# sneaky unsanctioned edit\n' >> "$CFILE"
[[ "$(jq -r '.data.drifted' <<<"$("$FIVE" constitution show --json 2>/dev/null)")" == "true" ]] && ok "constitution show: DRIFT after a hand-edit (DIVE-1695)" || no "show did not flag drift after hand-edit"
if "$FIVE" council verify >/dev/null 2>&1; then no "verify GREEN on a drifted constitution"; else ok "council verify RED on a drifted constitution (fail-closed)"; fi

# ============================ ORG route (multi-seat council) ====================================
O="$BASE/org"; mkdir -p "$O"
export STATE_DIR="$O"
"$FIVE" council init --seats="main:chair,theo,olivia" --threshold="majority" --veto="tg:1234567890" >/dev/null 2>&1 \
  || { echo "FAIL: could not seed a multi-seat council for the org route"; exit 1; }
ORGPROP="$O/proposed.yaml"; good > "$ORGPROP"
OD="$("$FIVE" constitution set --file="$ORGPROP" --dry-run --json 2>/dev/null)"
[[ "$(jq -r '.data.mode' <<<"$OD")" == "council" ]] && ok "a multi-seat council routes to the ORG amendment path" || no "org route not 'council' ($OD)"
[[ "$(jq -r '.data.seats' <<<"$OD")" == "3" ]] && ok "org route reports the 3-seat roster" || no "org route seat count wrong"
# the dry-run convened nothing / sealed nothing new
[[ "$(wc -l < "$O/council/lineage.jsonl")" == "1" ]] && ok "org dry-run seals nothing (routing only)" || no "org dry-run touched the lineage"

echo "DIVE-1743 constitution set e2e: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
