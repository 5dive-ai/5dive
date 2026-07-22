#!/usr/bin/env bash
# DIVE-1742 e2e — `5dive constitution show --json` READ verb on the BUILT binary. Proves the
# top-level constitution namespace routes through main.sh -> cmd_constitution -> cli.mjs
# constitution-show, and that the composed envelope is correct: source/defaults, per-class
# hard_gates + default-vs-custom, null-when-unsealed digests, genesisExists, sealed-lineage read
# (sealedDigest + amendment receipts), and DRIFT detection. The READ path needs NO gate-proof key
# (only WRITE/verify do), so a hand-synthesized lineage exercises the sealed case root-free — this
# GATES in CI. SKIPs green when node/jq missing or the build fails. Exit 0 == green.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for b in node jq; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (constitution show e2e needs it)"; exit 0; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FIVE="$TMP/5dive"
if ! BUILD_OUT="$FIVE" bash "$ROOT/build.sh" >/dev/null 2>&1 || [[ ! -x "$FIVE" ]]; then
  echo "SKIP: could not build a throwaway ./5dive (build.sh failed)"; exit 0
fi
export STATE_DIR="$TMP"          # isolate — never touch a live state dir
CY="$TMP/constitution.yaml"
show(){ "$FIVE" constitution show --json 2>/dev/null; }

P=0; F=0
chk(){ if [ "$2" = "$3" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $1 (want=$2 got=$3)"; fi; }

# --- CASE A: no constitution.yaml, no council -> shipped defaults, unsealed, no genesis ---
A="$(show)"
chk "A envelope ok"          "true"     "$(jq -r '.ok' <<<"$A")"
chk "A source=defaults"      "defaults" "$(jq -r '.data.source' <<<"$A")"
chk "A sealedDigest null"    "null"     "$(jq -r '.data.sealedDigest' <<<"$A")"
chk "A liveDigest null"      "null"     "$(jq -r '.data.liveDigest' <<<"$A")"
chk "A genesisExists false"  "false"    "$(jq -r '.data.genesisExists' <<<"$A")"
chk "A drifted false"        "false"    "$(jq -r '.data.drifted' <<<"$A")"
chk "A 4 hard_gate classes"  "4"        "$(jq -r '.data.hard_gates|keys|length' <<<"$A")"
chk "A all classes default"  "default"  "$(jq -r '.data.hard_gates_source.destructive' <<<"$A")"
chk "A verify null (no lineage)" "null"  "$(jq -r '.data.verify' <<<"$A")"
chk "A amendments empty"     "0"        "$(jq -r '.data.amendments|length' <<<"$A")"

# --- CASE B: a constitution.yaml on disk with a CUSTOM hard_gate class, still no council ---
cat > "$CY" <<'YAML'
council:
  bench: council
quorum: majority
veto:
  hold_secs: 900
  posthoc_secs: 172800
hard_gates:
  spend_billing: 'spend|billing|totally-custom-marker'
  public_comms: 'publish|announce'
  secrets: 'secret|token'
  destructive: 'delete|wipe'
ship:
  require_ci: true
comms:
  public_requires_human: true
YAML
B="$(show)"
chk "B source=file"          "file"     "$(jq -r '.data.source' <<<"$B")"
chk "B valid"                "true"     "$(jq -r '.data.valid' <<<"$B")"
chk "B liveDigest present"   "yes"      "$(jq -r 'if (.data.liveDigest|type)=="string" then "yes" else "no" end' <<<"$B")"
chk "B sealed still null"    "null"     "$(jq -r '.data.sealedDigest' <<<"$B")"
chk "B custom class flagged" "custom"   "$(jq -r '.data.hard_gates_source.spend_billing' <<<"$B")"
chk "B ship.require_ci read" "true"     "$(jq -r '.data.ship.require_ci' <<<"$B")"
chk "B comms flag read"      "true"     "$(jq -r '.data.comms.public_requires_human' <<<"$B")"

# --- CASE C: hand-synthesize a SEALED lineage (genesis + amend record whose constitutionDigest ==
# sha256 of the live constitution.yaml). The READ verb needs no key, so this exercises the sealed path.
mkdir -p "$TMP/council"
echo '{"kind":"genesis"}' > "$TMP/council/genesis.json"
DIG="$(sha256sum < "$CY" | awk '{print $1}')"
{
  printf '%s\n' '{"seq":0,"digest":"g0000","record":{"kind":"genesis","stampedAt":"2026-07-19T00:00:00Z"}}'
  printf '%s\n' "{\"seq\":1,\"digest\":\"r1111\",\"record\":{\"constitutionDigest\":\"$DIG\",\"stampedAt\":\"2026-07-20T00:00:00Z\",\"motion\":{\"kind\":\"amend\"},\"outcome\":\"approve\"}}"
} > "$TMP/council/lineage.jsonl"
C="$(show)"
chk "C sealedDigest = sealed" "$DIG"    "$(jq -r '.data.sealedDigest' <<<"$C")"
chk "C genesisExists true"    "true"    "$(jq -r '.data.genesisExists' <<<"$C")"
chk "C not drifted (match)"   "false"   "$(jq -r '.data.drifted' <<<"$C")"
chk "C one amendment"         "1"       "$(jq -r '.data.amendments|length' <<<"$C")"
chk "C amendment cdig"        "$DIG"    "$(jq -r '.data.amendments[0].constitutionDigest' <<<"$C")"
chk "C amendment motion"      "amend"   "$(jq -r '.data.amendments[0].motion' <<<"$C")"
chk "C amendment at"          "2026-07-20T00:00:00Z" "$(jq -r '.data.amendments[0].at' <<<"$C")"
chk "C amendment outcome"     "approve" "$(jq -r '.data.amendments[0].outcome' <<<"$C")"

# --- CASE D: DRIFT — edit the file after seal (a comment changes the bytes/sha, stays parseable) ---
printf '\n# drift marker\n' >> "$CY"
D="$(show)"
chk "D drifted true"          "true"    "$(jq -r '.data.drifted' <<<"$D")"
chk "D driftReason present"   "yes"     "$(jq -r 'if (.data.driftReason|type)=="string" then "yes" else "no" end' <<<"$D")"
chk "D sealedDigest unchanged" "$DIG"   "$(jq -r '.data.sealedDigest' <<<"$D")"

# --- human render smoke (non-json path must not error) ---
"$FIVE" constitution show >/dev/null 2>&1; chk "human render exit 0" "0" "$?"

echo "DIVE-1742 constitution show e2e: $P passed, $F failed"
[ "$F" -eq 0 ]
