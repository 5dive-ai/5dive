#!/usr/bin/env bash
# DIVE-2233 PHASE 1 — the sealed `authority.gate_clear_leads` READER, on its own.
#
# Phase 1 ships the reader and the selfcheck probe and enforces NOTHING: routing still
# carries the lead-clear exactly as it does today. So this harness deliberately does NOT
# drive cmd_task_answer — it grades the resolver directly, because that is the entire
# surface this release adds. The enforcement arms live in gate_sealed_routing_unit.sh,
# which lands with phase 3.
#
# WHY A READER SHIPS A RELEASE AHEAD OF ITS ENFORCER. The constitution normalizer rejects
# unknown top-level authority keys, and loadConstitution fails closed to shipped defaults.
# So the key must be READABLE by the fleet before it can safely be SEALED, and sealed
# before it can be ENFORCED. Sealing first does not work: `council amend` VALIDATES the
# proposed file and REFUSES (exit 4) on an unknown key, so on the current release the
# motion cannot even convene.
#
# Run: bash tests/gate_clear_leads_reader_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-clear-leads-reader.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# STATE_DIR before cmd_council.sh: COUNCIL_DIR/COUNCIL_LINEAGE are source-time globals.
STATE_DIR="$TMP"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_council.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
COUNCIL_DIR="$STATE_DIR/council"; COUNCIL_LINEAGE="$COUNCIL_DIR/lineage.jsonl"
mkdir -p "$STATE_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

write_c() { printf '%s' "$1" > "$STATE_DIR/constitution.yaml"; }
seal()    { mkdir -p "$COUNCIL_DIR"
            printf '{"seq":1,"record":{"constitutionDigest":"%s"}}\n' \
              "$(sha256sum < "$STATE_DIR/constitution.yaml" | awk '{print $1}')" > "$COUNCIL_LINEAGE"; }
unseal()  { rm -f "$COUNCIL_LINEAGE"; }
yaml()    { printf 'ship:\ncomms:\nauthority:\n  gate_clear_leads:\n%s' "$1"; }

# --- R1 THE GRANT + NON-VACUITY ----------------------------------------------------
write_c "$(yaml '    - main
    - marketing
')"; seal
names="$(_gate_clear_leads 2>/dev/null)"
[[ "$names" == $'main\nmarketing' ]] \
  && ok_t "R1 a sealed allowlist reads back both names, in order" \
  || bad_t "R1 sealed read" "got '$names'"
_gate_clear_lead_allowed main      && ok_t "R1 a named lead is allowed"        || bad_t "R1 main allowed" "refused"
_gate_clear_lead_allowed marketing && ok_t "R1 the SECOND entry is allowed too (not just the first)" || bad_t "R1 marketing allowed" "refused"
_gate_clear_lead_allowed dev       && bad_t "R1 an unnamed agent must be refused" "dev was allowed" || ok_t "R1 an unnamed agent is refused"
_gate_clear_lead_allowed ""        && bad_t "R1 empty name must be refused" "'' was allowed"        || ok_t "R1 an EMPTY name is refused (no '' == '' grant)"

# --- R2 THE SEAL IS THE VARIABLE ---------------------------------------------------
# The SAME bytes, unsealed, grant nothing; re-sealing them restores the grant. Without
# both halves, "unsealed denies" is indistinguishable from unrelated breakage.
unseal
_gate_clear_lead_allowed main && bad_t "R2 unsealed must deny" "main allowed with no seal" \
                             || ok_t "R2 the SAME bytes UNSEALED grant nothing"
[[ "$(_gate_clear_lead_denied_reason)" == "constitution-unsealed" ]] \
  && ok_t "R2 the reason is 'constitution-unsealed'" \
  || bad_t "R2 unsealed reason" "got '$(_gate_clear_lead_denied_reason)'"
seal
_gate_clear_lead_allowed main && ok_t "R2 re-sealing THE SAME BYTES restores it (the seal carries it)" \
                              || bad_t "R2 reseal restores" "still refused"

# --- R3 TAMPER IS SELF-DEFEATING ---------------------------------------------------
# Append a name WITHOUT re-sealing: the document no longer matches the sealed digest, so
# the resolver denies EVERYONE — including the legitimate holder. That is the property
# the whole design rests on: tampering is not prevented, it is made useless.
printf '    - rogue\n' >> "$STATE_DIR/constitution.yaml"
_gate_clear_lead_allowed rogue && bad_t "R3 the injected name must not be granted" "rogue allowed" \
                              || ok_t "R3 a name injected after sealing is NOT granted"
_gate_clear_lead_allowed main  && bad_t "R3 drift must deny the legitimate holder too" "main still allowed" \
                              || ok_t "R3 drift denies the LEGITIMATE holder too (self-defeating, not merely blocked)"
[[ "$(_gate_clear_lead_denied_reason)" == "constitution-drifted" ]] \
  && ok_t "R3 the reason is 'constitution-drifted', distinct from a missing key" \
  || bad_t "R3 drift reason" "got '$(_gate_clear_lead_denied_reason)'"

# --- R4 MALFORMED ENTRIES REFUSE THE WHOLE LIST ------------------------------------
# Dropping the bad entry and keeping the rest would let a hostile edit that FAILS
# validation still shift the effective allowlist — a partial grant from rejected bytes.
for bad in '../../etc/passwd' 'main; rm -rf /' '*' 'MAIN' 'human:marcus'; do
  write_c "$(printf 'ship:\ncomms:\nauthority:\n  gate_clear_leads:\n    - main\n    - %s\n' "$bad")"; seal
  _gate_clear_lead_allowed main \
    && bad_t "R4 a malformed sibling entry must refuse the WHOLE list" "'$bad' present yet main allowed" \
    || ok_t "R4 one malformed entry ('$bad') refuses the whole list, not just itself"
done

# --- R5 THE KEY'S ABSENCE IS ITS OWN REASON ----------------------------------------
write_c 'ship:
comms:
'; seal
_gate_clear_lead_allowed main && bad_t "R5 no key must deny" "main allowed" \
                             || ok_t "R5 a sealed constitution with NO gate_clear_leads key grants nobody"
[[ "$(_gate_clear_lead_denied_reason)" == "no-gate-clear-leads-key" ]] \
  && ok_t "R5 'no-gate-clear-leads-key' is distinct from unsealed and from drifted" \
  || bad_t "R5 no-key reason" "got '$(_gate_clear_lead_denied_reason)'"
# The three reasons must be mutually distinguishable — they demand opposite responses
# (convene a motion / investigate a tamper / seal the box for the first time).
r_nokey="$(_gate_clear_lead_denied_reason)"; unseal; r_unsealed="$(_gate_clear_lead_denied_reason)"
[[ "$r_nokey" != "$r_unsealed" ]] \
  && ok_t "R5 the deny reasons are not a single fixed string" \
  || bad_t "R5 reasons collapse" "both '$r_nokey'"

# --- R6 A KEY UNDER THE WRONG PARENT GRANTS NOTHING --------------------------------
write_c 'ship:
comms:
  gate_clear_leads:
    - main
'; seal
_gate_clear_lead_allowed main && bad_t "R6 gate_clear_leads under comms: must grant nothing" "main allowed" \
                             || ok_t "R6 gate_clear_leads under a DIFFERENT top-level key grants nothing"

echo "-----"
printf 'gate_clear_leads_reader_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
