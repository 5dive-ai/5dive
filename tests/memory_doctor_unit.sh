#!/usr/bin/env bash
# DIVE-991 unit harness for memory hygiene (`5dive memory doctor` /
# `5dive doctor --category=memory`).
#
# Exercises the PURE scanner (_memory_scan_json) against synthetic stores — no
# root, no network. Verifies each finding class fires on a planted defect and
# stays silent on the healthy control:
#   - index-drift (missing target = error; unindexed file = warn)
#   - dangling-link (only for unknown slugs; real [[links]] pass)
#   - stale-ref (only when the cited path is absent from the code-root; real
#     paths and .tsx/.json extensions must not false-positive)
#   - near-dup (high token overlap between two bodies)
# Run: bash tests/memory_doctor_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/mem-doctor-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_memory.sh"
JSON_MODE=0
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# A fake code-root so stale-ref checks have something real to verify against.
CODE="$TMP/code"; mkdir -p "$CODE/src"
: > "$CODE/src/real.ts"          # a source file that DOES exist
: > "$CODE/src/real.tsx"         # full-extension control (must not read as .ts)
: > "$CODE/a.json"               # full-extension control (must not read as .js)
: > "$CODE/header.sh"

STORE="$TMP/proj/memory"; mkdir -p "$STORE"
cat > "$STORE/MEMORY.md" <<'EOF'
# Index
- [Alpha](alpha.md) — alpha fact
- [Ghost](ghost.md) — points at a missing file
EOF
cat > "$STORE/alpha.md" <<'EOF'
---
name: alpha
description: alpha
metadata:
  type: project
---
Alpha links to [[beta]] (exists), [[betaa]] (typo of beta -> warn), and
[[future-idea-not-written-yet]] (intentional forward-ref -> quiet).
Cites src/real.ts and header.sh (both real). Also src/real.tsx and a.json
must NOT be truncated. Cites made/up/gone.ts which is stale.
EOF
cat > "$STORE/beta.md" <<'EOF'
---
name: beta
description: beta
metadata:
  type: project
---
Beta body, listed nowhere in the index so it is unindexed.
EOF
cat > "$STORE/dup1.md" <<'EOF'
---
name: dup1
metadata:
  type: reference
---
the quick brown fox jumps over the lazy dog while eating twelve delicious purple grapes today here now
EOF
cat > "$STORE/dup2.md" <<'EOF'
---
name: dup2
metadata:
  type: reference
---
the quick brown fox jumps over the lazy dog while eating twelve delicious purple grapes today here later
EOF

SCAN="$(_memory_scan_json "$CODE" "$STORE")"
F() { jq -r ".findings[] | select(.file==\"$1\" and .kind==\"$2\") | .severity" <<<"$SCAN"; }
KINDS="$(jq -r '.findings[].kind' <<<"$SCAN" | sort -u | tr '\n' ' ')"

# 1. roster names the store once
[ "$(jq -r '.stores|length' <<<"$SCAN")" = "1" ] \
  && ok_t "roster lists exactly one store" \
  || bad_t "roster lists exactly one store" "got $(jq -c '.stores' <<<"$SCAN")"

# 2. index-drift: missing target is an error
[ "$(F ghost.md index-drift)" = "error" ] \
  && ok_t "index links a missing file -> error" \
  || bad_t "index links a missing file -> error" "$SCAN"

# 3. index-drift: unindexed on-disk file is a warn
[ "$(F beta.md index-drift)" = "warn" ] \
  && ok_t "unindexed file -> warn" \
  || bad_t "unindexed file -> warn" "$SCAN"

# 4. dangling-link fires ONLY for the typo-suspect ([[betaa]] ~ beta), not the
#    intentional forward-ref ([[future-idea-not-written-yet]], no near match)
[ "$(jq -r '[.findings[]|select(.kind=="dangling-link" and .file=="alpha.md")]|length' <<<"$SCAN")" = "1" ] \
  && ok_t "one dangling-link (only the typo-suspect)" \
  || bad_t "one dangling-link (only the typo-suspect)" "$SCAN"
# ...the warning points at the suspected real target
[ -n "$(jq -r '.findings[]|select(.kind=="dangling-link")|.message' <<<"$SCAN" | grep -i 'did you mean.*\[\[beta\]\]')" ] \
  && ok_t "typo dangling-link suggests [[beta]]" \
  || bad_t "typo dangling-link suggests [[beta]]" "$SCAN"
# ...and the forward-ref stub stays quiet (no false noise)
[ -z "$(jq -r '.findings[]|select(.kind=="dangling-link")|.message' <<<"$SCAN" | grep -i 'future-idea')" ] \
  && ok_t "intentional forward-ref is not flagged" \
  || bad_t "intentional forward-ref is not flagged" "$SCAN"

# 5. stale-ref fires ONLY for the gone path, never for real paths / .tsx / .json
STALE="$(jq -r '.findings[]|select(.kind=="stale-ref")|.message' <<<"$SCAN")"
echo "$STALE" | grep -q 'made/up/gone.ts' \
  && ok_t "stale-ref flags the gone path" \
  || bad_t "stale-ref flags the gone path" "$STALE"
if echo "$STALE" | grep -qE 'real\.ts|header\.sh|real\.tsx|a\.json'; then
  bad_t "no stale-ref false positives on real paths / tsx / json" "$STALE"
else
  ok_t "no stale-ref false positives on real paths / tsx / json"
fi

# 6. near-dup between dup1/dup2
[ "$(jq -r '[.findings[]|select(.kind=="near-dup")]|length' <<<"$SCAN")" -ge 1 ] \
  && ok_t "near-duplicate pair detected" \
  || bad_t "near-duplicate pair detected" "$SCAN"

# 7. an empty code-root skips stale-ref (no crying wolf off-box)
SCAN2="$(_memory_scan_json "$TMP/nonexistent-code-root" "$STORE")"
[ "$(jq -r '[.findings[]|select(.kind=="stale-ref")]|length' <<<"$SCAN2")" = "0" ] \
  && ok_t "no code-root -> stale-ref checks skipped" \
  || bad_t "no code-root -> stale-ref checks skipped" "$SCAN2"

# 8. a clean store yields zero findings
CLEAN="$TMP/clean/memory"; mkdir -p "$CLEAN"
cat > "$CLEAN/MEMORY.md" <<'EOF'
# Index
- [Solo](solo.md) — the only fact
EOF
cat > "$CLEAN/solo.md" <<'EOF'
---
name: solo
metadata:
  type: reference
---
A lone tidy memory citing header.sh which exists.
EOF
CLEANSCAN="$(_memory_scan_json "$CODE" "$CLEAN")"
[ "$(jq -r '.findings|length' <<<"$CLEANSCAN")" = "0" ] \
  && ok_t "clean store -> zero findings" \
  || bad_t "clean store -> zero findings" "$CLEANSCAN"

echo
echo "kinds seen: ${KINDS}"
echo "memory_doctor_unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
