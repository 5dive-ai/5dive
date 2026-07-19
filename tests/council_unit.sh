#!/usr/bin/env bash
# CI wrapper: run the council node harnesses (engine + CLI contract + CNCL-7 dispatch) under
# the tests/*.sh runner so they actually GATE in CI (unit-tests.yml globs tests/*.sh, not
# *.mjs). All three are offline (COUNCIL_MOCK / mock adapters — no key, no network, no live
# tasks.db). node is present on the CI runner (other harnesses shell it too).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not on PATH (council harnesses need node)"; exit 0
fi

rc=0
for h in council_engine_unit.mjs council_cli_contract.mjs council_dispatch_unit.mjs council_cosign_unit.mjs; do
  echo "=== tests/$h"
  if ! node "tests/$h"; then echo "FAILED: tests/$h"; rc=1; fi
done

# CNCL-9: the founder-veto WIRING e2e (real 5dive council {init,convene,veto,lineage} bundle). It
# self-SKIPs (green) when it can't seal (no root / no passwordless sudo / missing openssl|jq), so
# it never falsely reds CI, but GATES the veto path wherever a seal is possible.
echo "=== tests/council_veto_e2e.sh"
if ! bash "tests/council_veto_e2e.sh"; then echo "FAILED: tests/council_veto_e2e.sh"; rc=1; fi

# CNCL-12: the gate-rot WIRING e2e (real 5dive council {gate-clear,rot-triage} bundle over an
# isolated STATE_DIR + TASKS_DB). Same self-SKIP-when-can't-seal posture as the veto e2e.
echo "=== tests/council_gate_e2e.sh"
if ! bash "tests/council_gate_e2e.sh"; then echo "FAILED: tests/council_gate_e2e.sh"; rc=1; fi
# CNCL-10: per-seat co-signed-votes e2e over REAL on-disk Ed25519 keys (0600 owner-only perms +
# honest verify + forge/replay/revoked all rejected). Offline, no seal/sudo needed — always gates.
echo "=== tests/council_cosign_e2e.sh"
if ! bash "tests/council_cosign_e2e.sh"; then echo "FAILED: tests/council_cosign_e2e.sh"; rc=1; fi

exit $rc
