#!/usr/bin/env bash
# DIVE-1950: pins the actual isolation bug — GATE_PROOF_KEY/GATE_PROOF_ENFORCE
# (and the sibling OPERATOR_STORE) used to be bound ONCE at source time from
# whatever STATE_DIR held at that moment. Every isolated unit harness sources
# tasks_db.sh/agent_setup.sh FIRST and re-points STATE_DIR AFTER (the same
# pattern task_set_branch_unit.sh etc. use) — so without an explicit
# GATE_PROOF_* override, those paths stayed frozen on the pre-isolation
# STATE_DIR forever, silently reading/writing whatever was there (in
# production: the live host's /var/lib/5dive). This harness deliberately
# does NOT set GATE_PROOF_KEY/GATE_PROOF_ENFORCE/OPERATOR_STORE after
# re-pointing STATE_DIR — that omission is exactly the ~53-harness shape
# DIVE-1919 found and DIVE-1950 fixes for good via lazy getters.
# Run: bash tests/gate_proof_lazy_resolve_unit.sh   (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
OLD_STATE="$(mktemp -d /tmp/gate-proof-lazy-old.XXXXXX)"
NEW_STATE="$(mktemp -d /tmp/gate-proof-lazy-new.XXXXXX)"
trap 'rm -rf "$OLD_STATE" "$NEW_STATE"' EXIT

STATE_DIR="$OLD_STATE"   # the pre-isolation default, same as header.sh's own default at source time

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh; do
  source "$SRC/$f"
done

# Re-point STATE_DIR AFTER sourcing, same as every isolated unit harness does
# — and deliberately leave GATE_PROOF_KEY/GATE_PROOF_ENFORCE/OPERATOR_STORE
# UNSET, i.e. the ~53-harness shape (no explicit binding).
STATE_DIR="$NEW_STATE"
JSON_MODE=1
set +e   # header.sh enabled `set -e`; tests expect non-zero exits

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- T1: the key-file getter resolves under the NEW (post-repoint) STATE_DIR
kf=$(_gate_proof_key_file)
[[ "$kf" == "$NEW_STATE/gate-proof.key" ]] \
  && ok_t "_gate_proof_key_file resolves under the re-pointed STATE_DIR" \
  || bad_t "_gate_proof_key_file resolves under the re-pointed STATE_DIR" "got: $kf"

# --- T2: the enforce-file getter resolves under the NEW STATE_DIR too
ef=$(_gate_proof_enforce_file)
[[ "$ef" == "$NEW_STATE/gate-proof.enforce" ]] \
  && ok_t "_gate_proof_enforce_file resolves under the re-pointed STATE_DIR" \
  || bad_t "_gate_proof_enforce_file resolves under the re-pointed STATE_DIR" "got: $ef"

# --- T3: a sentinel dropped in the OLD state dir (simulating a live host file
# that predates isolation) is NOT seen as enforced — the bug this fixes would
# have frozen enforcement to whatever the OLD dir held.
touch "$OLD_STATE/gate-proof.enforce"
_gate_proof_enforced && bad_t "enforce sentinel in the OLD (pre-repoint) dir must not leak into this isolated run" "_gate_proof_enforced returned true" \
  || ok_t "enforce sentinel in the OLD (pre-repoint) dir does not leak in"
rm -f "$OLD_STATE/gate-proof.enforce"

# --- T4: a sentinel dropped in the NEW state dir IS seen as enforced
touch "$NEW_STATE/gate-proof.enforce"
_gate_proof_enforced \
  && ok_t "enforce sentinel in the NEW (isolated) dir is read correctly" \
  || bad_t "enforce sentinel in the NEW (isolated) dir is read correctly" "_gate_proof_enforced returned false"
rm -f "$NEW_STATE/gate-proof.enforce"

# --- T5: an explicit GATE_PROOF_ENFORCE override still wins over STATE_DIR
override_dir="$(mktemp -d /tmp/gate-proof-lazy-override.XXXXXX)"
GATE_PROOF_ENFORCE="$override_dir/enforce"
touch "$GATE_PROOF_ENFORCE"
_gate_proof_enforced \
  && ok_t "an explicit GATE_PROOF_ENFORCE override still wins" \
  || bad_t "an explicit GATE_PROOF_ENFORCE override still wins" "_gate_proof_enforced returned false"
unset GATE_PROOF_ENFORCE
rm -rf "$override_dir"

# --- T6: OPERATOR_STORE (agent_setup.sh) has the same lazy fix — write under
# the NEW STATE_DIR, prove nothing landed in the OLD one.
_operator_record "1234567890"
[[ -f "$NEW_STATE/operator-allow.json" ]] \
  && ok_t "_operator_record writes under the re-pointed STATE_DIR" \
  || bad_t "_operator_record writes under the re-pointed STATE_DIR" "missing: $NEW_STATE/operator-allow.json"
[[ ! -f "$OLD_STATE/operator-allow.json" ]] \
  && ok_t "_operator_record does not touch the OLD (pre-repoint) dir" \
  || bad_t "_operator_record does not touch the OLD (pre-repoint) dir" "found: $OLD_STATE/operator-allow.json"
ids=$(_operator_ids)
[[ "$ids" == "1234567890" ]] \
  && ok_t "_operator_ids reads back what _operator_record wrote" \
  || bad_t "_operator_ids reads back what _operator_record wrote" "got: $ids"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
