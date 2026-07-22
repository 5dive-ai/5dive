#!/usr/bin/env bash
# DIVE-1701 e2e — `5dive constitution init` SEED verb on the BUILT binary. Proves the top-level
# constitution namespace routes through main.sh -> cmd_constitution -> _constitution_init and that:
#   · init writes the full default constitution.yaml with GUARDRAILS FIRST (hard_gates/ship/comms)
#     then the Council keys, present-but-DORMANT (no genesis/lineage created);
#   · the written file parses + validates (show reads it as source=file, valid);
#   · anti-clobber: an existing UNSEALED file needs --force; a Council-SEALED constitution is
#     HARD-refused even with --force (route to council amend / constitution edit).
# Needs NO gate-proof key (init never seals) so a hand-synthesized sealed lineage exercises the
# refusal root-free — this GATES in CI. SKIPs green when node/jq missing or build fails. Exit 0 == green.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for b in node jq; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (constitution init e2e needs it)"; exit 0; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FIVE="$TMP/5dive"
if ! BUILD_OUT="$FIVE" bash "$ROOT/build.sh" >/dev/null 2>&1 || [[ ! -x "$FIVE" ]]; then
  echo "SKIP: could not build a throwaway ./5dive (build.sh failed)"; exit 0
fi
export STATE_DIR="$TMP"          # isolate — never touch a live state dir
CY="$TMP/constitution.yaml"

P=0; F=0
chk(){ if [ "$2" = "$3" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $1 (want=$2 got=$3)"; fi; }
# line number of a top-level key in the written file ('' if absent)
lineof(){ grep -nE "^$1:" "$CY" | head -1 | cut -d: -f1; }

# --- CASE A: fresh box (no file, no council) -> init writes + exits 0 --------------------------
"$FIVE" constitution init >/dev/null 2>&1; chk "A init exit 0" "0" "$?"
chk "A file written" "yes" "$([ -f "$CY" ] && echo yes || echo no)"
# GUARDRAILS ordered BEFORE the Council section
hg="$(lineof hard_gates)"; sh="$(lineof ship)"; cm="$(lineof comms)"; co="$(lineof council)"; qm="$(lineof quorum)"; vt="$(lineof veto)"
chk "A hard_gates present" "yes" "$([ -n "$hg" ] && echo yes || echo no)"
chk "A ship present"       "yes" "$([ -n "$sh" ] && echo yes || echo no)"
chk "A comms present"      "yes" "$([ -n "$cm" ] && echo yes || echo no)"
chk "A council present"    "yes" "$([ -n "$co" ] && echo yes || echo no)"
chk "A guardrails before council" "yes" "$([ "$hg" -lt "$co" ] && [ "$sh" -lt "$co" ] && [ "$cm" -lt "$co" ] && echo yes || echo no)"
chk "A council keys after guardrails" "yes" "$([ "$co" -lt "$qm" ] && [ "$qm" -lt "$vt" ] && echo yes || echo no)"
chk "A dormant comment present" "yes" "$(grep -qiE 'DORMANT' "$CY" && echo yes || echo no)"
# NO genesis/lineage created — init seeds only, never seals
chk "A no genesis" "no" "$([ -f "$TMP/council/genesis.json" ] && echo yes || echo no)"
chk "A no lineage" "no" "$([ -f "$TMP/council/lineage.jsonl" ] && echo yes || echo no)"
# show reads it as a parsed file, valid, unsealed
S="$("$FIVE" constitution show --json 2>/dev/null)"
chk "A show source=file"  "file"  "$(jq -r '.data.source' <<<"$S")"
chk "A show valid"        "true"  "$(jq -r '.data.valid' <<<"$S")"
chk "A show unsealed"     "null"  "$(jq -r '.data.sealedDigest' <<<"$S")"
chk "A show 4 gate classes" "4"   "$(jq -r '.data.hard_gates|keys|length' <<<"$S")"

# --- CASE B: re-init refuses an existing UNSEALED file unless --force --------------------------
DIG0="$(sha256sum < "$CY" | awk '{print $1}')"
"$FIVE" constitution init >/dev/null 2>&1; chk "B re-init non-zero" "yes" "$([ "$?" -ne 0 ] && echo yes || echo no)"
chk "B file untouched" "$DIG0" "$(sha256sum < "$CY" | awk '{print $1}')"
J="$("$FIVE" constitution init --force --json 2>/dev/null)"
chk "B --force ok"     "true"  "$(jq -r '.ok' <<<"$J")"
chk "B --force wrote"  "true"  "$(jq -r '.data.wrote' <<<"$J")"
chk "B --force dormant" "dormant" "$(jq -r '.data.council' <<<"$J")"

# --- CASE C: a Council-SEALED constitution is HARD-refused (even with --force) -----------------
mkdir -p "$TMP/council"
echo '{"kind":"genesis"}' > "$TMP/council/genesis.json"
printf '%s\n' '{"seq":0,"digest":"g0","record":{"constitutionDigest":"SEALEDdeadbeef0000","stampedAt":"2026-07-20T00:00:00Z"}}' > "$TMP/council/lineage.jsonl"
DIG1="$(sha256sum < "$CY" | awk '{print $1}')"
"$FIVE" constitution init >/dev/null 2>&1;         chk "C sealed refuses"          "yes" "$([ "$?" -ne 0 ] && echo yes || echo no)"
"$FIVE" constitution init --force >/dev/null 2>&1; chk "C sealed refuses --force"   "yes" "$([ "$?" -ne 0 ] && echo yes || echo no)"
chk "C file untouched under seal" "$DIG1" "$(sha256sum < "$CY" | awk '{print $1}')"

echo "DIVE-1701 constitution init e2e: $P passed, $F failed"
[ "$F" -eq 0 ]
