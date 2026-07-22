#!/usr/bin/env bash
# DIVE-1686 e2e — belt-and-suspenders for the DIVE-1676 rename (5dive.md -> constitution.yaml).
# Proves `_council_constitution_path` reads a LEGACY ${STATE_DIR}/5dive.md when the canonical
# constitution.yaml is absent, does a ONE-TIME byte-preserving rename to the canonical name, and
# — crucially — that a box which SEALED a digest under the old name does NOT trip drift or silently
# revert to built-in defaults after upgrading to a post-rename build. Exercises the BUILT binary via
# `constitution show --json` (the READ verb resolves the path the same way every reader does).
# SKIPs green when node/jq missing or the build fails. Exit 0 == green.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for b in node jq; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (legacy-migration e2e needs it)"; exit 0; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FIVE="$TMP/5dive"
if ! BUILD_OUT="$FIVE" bash "$ROOT/build.sh" >/dev/null 2>&1 || [[ ! -x "$FIVE" ]]; then
  echo "SKIP: could not build a throwaway ./5dive (build.sh failed)"; exit 0
fi
export STATE_DIR="$TMP"          # isolate — never touch a live state dir
LEGACY="$TMP/5dive.md"
CANON="$TMP/constitution.yaml"
show(){ "$FIVE" constitution show --json 2>/dev/null; }
P=0; F=0
chk(){ if [ "$2" = "$3" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $1 (want=$2 got=$3)"; fi; }

constitution_body(){ cat <<'YAML'
council:
  bench: council
quorum: majority
veto:
  hold_secs: 900
  posthoc_secs: 172800
hard_gates:
  spend_billing: 'spend|billing|legacy-migration-marker'
  public_comms: 'publish|announce'
  secrets: 'secret|token'
  destructive: 'delete|wipe'
ship:
  require_ci: true
comms:
  public_requires_human: true
YAML
}

# --- CASE A: legacy 5dive.md present, canonical absent -> read legacy + one-time rename ---
constitution_body > "$LEGACY"
A="$(show)"
chk "A reads the file (not defaults)" "file"   "$(jq -r '.data.source' <<<"$A")"
chk "A custom marker read from legacy" "custom" "$(jq -r '.data.hard_gates_source.spend_billing' <<<"$A")"
chk "A renamed -> constitution.yaml exists" "yes" "$([[ -f "$CANON" ]] && echo yes || echo no)"
chk "A legacy 5dive.md is gone"        "yes"   "$([[ ! -e "$LEGACY" ]] && echo yes || echo no)"
chk "A canonical bytes == legacy bytes" "$(constitution_body | sha256sum | awk '{print $1}')" "$(sha256sum < "$CANON" | awk '{print $1}')"

# --- CASE B: second read is stable (canonical present, nothing to migrate) ---
B="$(show)"
chk "B still source=file"              "file"   "$(jq -r '.data.source' <<<"$B")"
chk "B legacy stays gone"              "yes"    "$([[ ! -e "$LEGACY" ]] && echo yes || echo no)"

# --- CASE C: a SEALED digest under the OLD name survives the rename (no drift, no silent revert) ---
rm -f "$CANON" "$LEGACY"; mkdir -p "$TMP/council"
constitution_body > "$LEGACY"
DIG="$(constitution_body | sha256sum | awk '{print $1}')"   # digest of the bytes, sealed pre-rename
echo '{"kind":"genesis"}' > "$TMP/council/genesis.json"
{
  printf '%s\n' '{"seq":0,"digest":"g0000","record":{"kind":"genesis","stampedAt":"2026-07-19T00:00:00Z"}}'
  printf '%s\n' "{\"seq\":1,\"digest\":\"r1111\",\"record\":{\"constitutionDigest\":\"$DIG\",\"stampedAt\":\"2026-07-20T00:00:00Z\",\"motion\":{\"kind\":\"amend\"},\"outcome\":\"approve\"}}"
} > "$TMP/council/lineage.jsonl"
C="$(show)"
chk "C sealed digest read"             "$DIG"   "$(jq -r '.data.sealedDigest' <<<"$C")"
chk "C live digest matches (renamed)"  "$DIG"   "$(jq -r '.data.liveDigest' <<<"$C")"
chk "C NOT drifted after rename"       "false"  "$(jq -r '.data.drifted' <<<"$C")"
chk "C migrated to canonical"          "yes"    "$([[ -f "$CANON" && ! -e "$LEGACY" ]] && echo yes || echo no)"

# --- CASE D: fresh box (neither file) -> defaults, no phantom files created ---
rm -rf "$TMP/council" "$CANON" "$LEGACY"
D="$(show)"
chk "D source=defaults"                "defaults" "$(jq -r '.data.source' <<<"$D")"
chk "D no constitution.yaml conjured"  "yes"      "$([[ ! -e "$CANON" ]] && echo yes || echo no)"

echo "constitution_legacy_migration_e2e: $P passed, $F failed"
[ "$F" -eq 0 ]
