#!/usr/bin/env bash
# CNCL-14: task tier-floor consumer reads hard_gates from constitution.yaml.
set -uo pipefail
cd "$(dirname "$0")/.."

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_council.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done

TMP="$(mktemp -d /tmp/constitution-floor.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
STATE_DIR="$TMP"
export FIVEDIVE_CONSTITUTION_FILE="$TMP/constitution.yaml"
PASS=0; FAIL=0
ok_t() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# No file: byte-identical shipped floor (publish hits; brand does not).
[[ "$(_council_hard_gate_rx)" == "$_GATE_T2_FLOOR_RX" ]] \
  && ok_t "missing constitution returns exact legacy floor regex" || bad_t "missing regex drift"
_gate_tier2_floor_hit "publish the launch post" \
  && ok_t "missing constitution preserves public-comms floor" || bad_t "missing public-comms floor"
if _gate_tier2_floor_hit "review the brand strategy"; then bad_t "brand absent from shipped default"
else ok_t "brand remains absent from shipped default"; fi

# The no-file hot path must not invoke the Node/runtime loader at all.
original_hard_gate_fn="$(declare -f _council_hard_gate_rx)"
_council_hard_gate_rx() { : > "$TMP/hard-gate-loader.called"; printf '%s\n' "$_GATE_T2_FLOOR_RX"; }
rm -f "$TMP/hard-gate-loader.called"
_gate_tier2_floor_hit "approve billing" >/dev/null
[[ ! -e "$TMP/hard-gate-loader.called" ]] \
  && ok_t "missing constitution keeps gate floor in-process" || bad_t "missing constitution invoked runtime loader"
eval "$original_hard_gate_fn"

# A valid org constitution adds brand to the public-comms hard class.
printf '%s\n' 'council:' '  bench: council' 'hard_gates:' \
  "  money: 'spend|billing'" "  public_comms: 'brand|press'" '# policy' \
  > "$FIVEDIVE_CONSTITUTION_FILE"
_gate_tier2_floor_hit "review the brand strategy" \
  && ok_t "brand-present constitution floors brand" || bad_t "brand-present did not floor"

# Replacing the class map without brand removes it live while retaining named classes.
printf '%s\n' 'hard_gates:' "  money: 'spend|billing'" \
  "  public_comms: 'press|customer email'" '# amended policy' \
  > "$FIVEDIVE_CONSTITUTION_FILE"
if _gate_tier2_floor_hit "review the brand strategy"; then bad_t "brand-absent constitution still floors brand"
else ok_t "brand-absent constitution does not floor brand"; fi
_gate_tier2_floor_hit "approve billing" \
  && ok_t "other configured hard class remains active" || bad_t "configured money class missing"

# `[^]` is accepted by JavaScript's RegExp and the constitution loader, but
# rejected by Bash's POSIX ERE engine with rc=2. The Bash consumer must discard
# the entire loaded policy, retain the legacy floor, and leave a loud diagnostic
# instead of turning that rc=2 into a false "no hit" result.
printf '%s\n' 'hard_gates:' "  unsafe: '[^]'" "  public_comms: 'brand'" \
  '# JS-valid, ERE-invalid policy' > "$FIVEDIVE_CONSTITUTION_FILE"
ere_warning="$TMP/ere-warning"
_gate_tier2_floor_hit "approve billing" 2>"$ere_warning" \
  && ok_t "ERE-invalid constitution regex falls back to legacy floor" || bad_t "ERE-invalid regex disabled legacy floor"
if _gate_tier2_floor_hit "review the brand strategy" 2>/dev/null; then bad_t "ERE-invalid constitution partially applied"
else ok_t "ERE-invalid constitution is discarded atomically"; fi
grep -q 'invalid POSIX ERE; falling back to the shipped tier-2 floor' "$ere_warning" \
  && ok_t "ERE-invalid constitution emits fallback warning" || bad_t "ERE-invalid fallback was silent"

# Malformed frontmatter is never partially applied: conservative shipped defaults return.
printf '%s\n' 'not yaml frontmatter' > "$FIVEDIVE_CONSTITUTION_FILE"
[[ "$(_council_hard_gate_rx)" == "$_GATE_T2_FLOOR_RX" ]] \
  && ok_t "malformed constitution falls back atomically" || bad_t "malformed policy partially applied"

# DIVE-1695: the on-disk constitution is trusted for the floor ONLY when it
# matches the digest sealed in the council lineage. All tests above ran with no
# COUNCIL_LINEAGE (no seal) and so kept CNCL-14 behavior. Now exercise the
# sealed paths. Seal a digest by writing a lineage record carrying it.
export COUNCIL_LINEAGE="$TMP/lineage.jsonl"
_seal_digest() { printf '{"record":{"constitutionDigest":"%s"}}\n' "$1" > "$COUNCIL_LINEAGE"; }
_live_digest() { sha256sum < "$FIVEDIVE_CONSTITUTION_FILE" | awk '{print $1}'; }

# In sync: a file whose digest matches the seal IS trusted — its added brand class floors.
printf '%s\n' 'hard_gates:' "  money: 'spend|billing'" \
  "  public_comms: 'brand|press'" '# sealed policy' > "$FIVEDIVE_CONSTITUTION_FILE"
_seal_digest "$(_live_digest)"
if _council_constitution_drifted; then bad_t "in-sync constitution reported as drift"
else ok_t "constitution matching the sealed digest is not drift"; fi
_gate_tier2_floor_hit "review the brand strategy" \
  && ok_t "sealed+matching constitution floors its added brand class" || bad_t "sealed+matching not trusted"

# Drift (the attack): the file is edited AFTER sealing to DELETE the money class
# (weakening the human-gate floor), but the seal still holds the old digest. The
# edited file must NOT be trusted — bill floors via the shipped default, brand does
# not floor (the drifted file's classes are ignored), and a warning is emitted.
sealed_before="$(_live_digest)"; _seal_digest "$sealed_before"
printf '%s\n' 'hard_gates:' "  public_comms: 'brand'" \
  '# tampered: money class removed after sealing' > "$FIVEDIVE_CONSTITUTION_FILE"
if _council_constitution_drifted; then ok_t "post-seal edit detected as drift"
else bad_t "post-seal edit not detected as drift"; fi
drift_warning="$TMP/drift-warning"
_gate_tier2_floor_hit "approve billing" 2>"$drift_warning" \
  && ok_t "drifted constitution still floors billing via shipped default" \
  || bad_t "drifted constitution let billing through (floor weakened!)"
if _gate_tier2_floor_hit "review the brand strategy" 2>/dev/null; then bad_t "drifted constitution's classes were trusted"
else ok_t "drifted constitution's on-disk classes are ignored"; fi
grep -q 'drifted from the sealed digest' "$drift_warning" \
  && ok_t "drifted constitution emits fail-closed warning" || bad_t "drift fell back silently"

# Sealed but the file is deleted entirely: fail closed (drift).
rm -f "$FIVEDIVE_CONSTITUTION_FILE"
if _council_constitution_drifted; then ok_t "sealed digest with missing file is drift"
else bad_t "missing file under a seal was not flagged"; fi
_seal_digest ""  # no non-empty digest sealed -> pre-constitution lineage, never drift
printf '%s\n' 'hard_gates:' "  money: 'spend'" '# unsealed setup file' > "$FIVEDIVE_CONSTITUTION_FILE"
if _council_constitution_drifted; then bad_t "empty seal wrongly treated as drift"
else ok_t "no sealed digest leaves CNCL-14 behavior unchanged"; fi
unset COUNCIL_LINEAGE

printf '%s\n' '-----' "constitution_gate_floor_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
