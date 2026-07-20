#!/usr/bin/env bash
# CI wrapper: run the council node harnesses (engine + CLI contract + dispatch + constitution) under
# the tests/*.sh runner so they actually GATE in CI (unit-tests.yml globs tests/*.sh, not
# *.mjs). All three are offline (COUNCIL_MOCK / mock adapters — no key, no network, no live
# tasks.db). node is present on the CI runner (other harnesses shell it too).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not on PATH (council harnesses need node)"; exit 0
fi

rc=0
for h in council_engine_unit.mjs council_cli_contract.mjs council_dispatch_unit.mjs council_cosign_unit.mjs council_constitution_unit.mjs; do
  echo "=== tests/$h"
  if ! node "tests/$h"; then echo "FAILED: tests/$h"; rc=1; fi
done

# CNCL-9: the founder-veto WIRING e2e (real 5dive council {init,convene,veto,lineage} bundle). It
# self-SKIPs (green) when it can't seal (no root / no passwordless sudo / missing openssl|jq), so
# it never falsely reds CI, but GATES the veto path wherever a seal is possible.
echo "=== tests/council_veto_e2e.sh"
if ! bash "tests/council_veto_e2e.sh"; then echo "FAILED: tests/council_veto_e2e.sh"; rc=1; fi

# DIVE-1494 (1): the read-only convene NOTICE wiring (fires w/ disposition+tally, no raw nonce,
# silent unless COUNCIL_NOTIFY set). Offline via MOCK + COUNCIL_NOTIFY_SINK; self-skips green w/o root.
echo "=== tests/council_notify_e2e.sh"
if ! bash "tests/council_notify_e2e.sh"; then echo "FAILED: tests/council_notify_e2e.sh"; rc=1; fi

# CNCL-12: the gate-rot WIRING e2e (real 5dive council {gate-clear,rot-triage} bundle over an
# isolated STATE_DIR + TASKS_DB). Same self-SKIP-when-can't-seal posture as the veto e2e.
echo "=== tests/council_gate_e2e.sh"
if ! bash "tests/council_gate_e2e.sh"; then echo "FAILED: tests/council_gate_e2e.sh"; rc=1; fi
# CNCL-10: per-seat co-signed-votes e2e over REAL on-disk Ed25519 keys (0600 owner-only perms +
# honest verify + forge/replay/revoked all rejected). Offline, no seal/sudo needed — always gates.
echo "=== tests/council_cosign_e2e.sh"
if ! bash "tests/council_cosign_e2e.sh"; then echo "FAILED: tests/council_cosign_e2e.sh"; rc=1; fi

# CNCL-11: the governance-surface WIRING e2e (real 5dive council {roster,promote,demote,log,verify}
# bundle — a promote/demote runs as a convened motion, its receipt + roster join the tamper-evident
# lineage, recusal drops the subject, and verify goes RED on an edited/dropped/reordered record).
# Same self-SKIP-when-can't-seal posture as the veto e2e.
echo "=== tests/council_roster_lineage_e2e.sh"
if ! bash "tests/council_roster_lineage_e2e.sh"; then echo "FAILED: tests/council_roster_lineage_e2e.sh"; rc=1; fi

# CNCL-15: the constitution-AMENDMENTS WIRING e2e (real 5dive council {init,amend,convene,verify}
# bundle over an isolated STATE_DIR): genesis seals the v0 digest, amend is a constitutional motion
# that swaps + hash-chains, and drift fails closed (verify RED + convene escalate). Same self-SKIP.
echo "=== tests/council_amend_e2e.sh"
if ! bash "tests/council_amend_e2e.sh"; then echo "FAILED: tests/council_amend_e2e.sh"; rc=1; fi

# CNCL-17: the seat TRACK RECORD wiring e2e — `5dive council record` scores sealed votes against
# real task outcomes (done→good, cancelled→bad), vindicates dissents, skips undecided tasks.
echo "=== tests/council_record_e2e.sh"
if ! bash "tests/council_record_e2e.sh"; then echo "FAILED: tests/council_record_e2e.sh"; rc=1; fi

# CNCL-26: the bash-DISPATCHER route e2e — proves `5dive council sign-vote|verify-votes` reach the
# mjs verbs through cmd_council()'s allowlist (not just `node cli.mjs` directly, the blind spot that
# hid the CNCL-10 shell gap). Builds a throwaway ./5dive (BUILD_OUT) so it GATES in CI; no root/seal.
echo "=== tests/council_bashroute_e2e.sh"
if ! bash "tests/council_bashroute_e2e.sh"; then echo "FAILED: tests/council_bashroute_e2e.sh"; rc=1; fi

# CNCL-18: the non-blocking BALLOT dispatch e2e — proves the ballot selector is DEFAULT and reachable
# through cmd_council() on the BUILT binary (ad-hoc panel + fake fleet; unsealed convene, no root),
# and that --ask-rail / COUNCIL_ASK_RAIL keep the old agent-ask pane-scrape as an escape hatch.
# Builds a throwaway ./5dive (BUILD_OUT) so it GATES in CI; self-SKIPs green when it cannot build.
echo "=== tests/council_ballot_e2e.sh"
if ! bash "tests/council_ballot_e2e.sh"; then echo "FAILED: tests/council_ballot_e2e.sh"; rc=1; fi

# DIVE-1565: the human ballot TAP->task-close bridge e2e — proves `5dive council ballot-tap` reaches
# cli.mjs through cmd_council() on the BUILT binary, prefix-accepts a unique OPEN human ballot,
# verifies the one-time nonce, and closes it with the COUNCIL-VOTE line (fake board; fail-closed on
# wrong nonce / miss / agent-ballot). Builds a throwaway ./5dive (BUILD_OUT) so it GATES in CI.
echo "=== tests/council_ballot_tap_e2e.sh"
if ! bash "tests/council_ballot_tap_e2e.sh"; then echo "FAILED: tests/council_ballot_tap_e2e.sh"; rc=1; fi

exit $rc
