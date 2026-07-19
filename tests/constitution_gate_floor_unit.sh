#!/usr/bin/env bash
# CNCL-14: task tier-floor consumer reads hard_gates from 5dive.md.
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
export FIVEDIVE_CONSTITUTION_FILE="$TMP/5dive.md"
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
printf '%s\n' '---' 'council:' '  bench: council' 'hard_gates:' \
  "  money: 'spend|billing'" "  public_comms: 'brand|press'" '---' '# policy' \
  > "$FIVEDIVE_CONSTITUTION_FILE"
_gate_tier2_floor_hit "review the brand strategy" \
  && ok_t "brand-present constitution floors brand" || bad_t "brand-present did not floor"

# Replacing the class map without brand removes it live while retaining named classes.
printf '%s\n' '---' 'hard_gates:' "  money: 'spend|billing'" \
  "  public_comms: 'press|customer email'" '---' '# amended policy' \
  > "$FIVEDIVE_CONSTITUTION_FILE"
if _gate_tier2_floor_hit "review the brand strategy"; then bad_t "brand-absent constitution still floors brand"
else ok_t "brand-absent constitution does not floor brand"; fi
_gate_tier2_floor_hit "approve billing" \
  && ok_t "other configured hard class remains active" || bad_t "configured money class missing"

# Malformed frontmatter is never partially applied: conservative shipped defaults return.
printf '%s\n' 'not yaml frontmatter' > "$FIVEDIVE_CONSTITUTION_FILE"
[[ "$(_council_hard_gate_rx)" == "$_GATE_T2_FLOOR_RX" ]] \
  && ok_t "malformed constitution falls back atomically" || bad_t "malformed policy partially applied"

printf '%s\n' '-----' "constitution_gate_floor_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
