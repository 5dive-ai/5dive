#!/usr/bin/env bash
# OSS-39 isolated unit harness for the LOAD-BEARING publish guardrail
# (`_proof_publish_gate`): a public badge must never fire without lodar's tap.
# Stubs the task layer (cmd_task_add / cmd_task_need / db) and drives the gate
# through its full state machine against a temp proof.json. Asserts:
#   - first fire files an APPROVAL `task need` (routed to lodar) and BLOCKS,
#     recording the approval task ident; nothing publishes,
#   - a pending gate keeps blocking and does NOT re-file the task,
#   - a nonce-backed human 'approve' flips .publishApproved=true and proceeds,
#   - an empty-nonce human:* approve (FUNNEA-3 shape) does NOT authorize,
#   - once approved, the gate is a no-op pass (task layer never touched),
#   - a human REJECT blocks.
# Run: bash tests/proof_publish_gate_unit.sh   (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."

command -v jq >/dev/null 2>&1 || { echo "SKIP - jq absent"; exit 0; }

TMP="$(mktemp -d /tmp/proof-gate.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
JSON_MODE=0; E_USAGE=2; E_GENERIC=1
require_root() { :; }
fail() { echo "fail($1): $2" >&2; exit "$1"; }
sqlq() { printf "'%s'" "$1"; }

# Stubs record what the gate asked the task layer to do.
ADD_LOG="$TMP/add.log"; NEED_LOG="$TMP/need.log"; : >"$ADD_LOG"; : >"$NEED_LOG"
cmd_task_add()  { echo "add $*" >>"$ADD_LOG"; echo '{"data":{"ident":"DIVE-777"}}'; }
cmd_task_need() { echo "need $*" >>"$NEED_LOG"; return 0; }
# db returns the gate record for the ident lookup, controlled per-case via GATE_REC
# (format: answer<US>by<US>nonce). Empty by default (no answer yet).
GATE_REC=""
db() { printf '%s' "$GATE_REC"; }

# shellcheck disable=SC1091
source src/cmd_proof.sh

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
pref()  { jq -r "$1 // \"\"" "$STATE_DIR/proof.json" 2>/dev/null; }
US=$'\x1f'

# --- Case 1: first fire files the approval gate to lodar + BLOCKS ------------
rm -f "$STATE_DIR/proof.json"; : >"$ADD_LOG"; : >"$NEED_LOG"
if ( _proof_publish_gate ) >/dev/null 2>&1; then
  bad_t "first fire blocks" "gate returned 0 (would have published)"
else
  ok_t "first fire BLOCKS (non-zero) — nothing publishes"
fi
grep -q "add " "$ADD_LOG"  && ok_t "first fire creates the approval task" || bad_t "task add" "$(cat "$ADD_LOG")"
grep -q -- "--type=approval" "$NEED_LOG" && ok_t "gate is filed as type=approval" || bad_t "approval type" "$(cat "$NEED_LOG")"
grep -q -- "--from=proof" "$NEED_LOG"    && ok_t "gate is filed from=proof"       || bad_t "from proof" "$(cat "$NEED_LOG")"
[ "$(pref '.approvalTaskIdent')" = "DIVE-777" ] && ok_t "approval task ident persisted" || bad_t "persist ident" "$(pref '.approvalTaskIdent')"
# NB read raw (not via pref's `// ""`): jq's // treats boolean false as empty.
[ "$(jq -r '.publishApproved' "$STATE_DIR/proof.json")" = "false" ] && ok_t "publishApproved stays false" || bad_t "approved false" "$(jq -r '.publishApproved' "$STATE_DIR/proof.json")"

# --- Case 2: a pending gate keeps blocking and does NOT re-file --------------
: >"$ADD_LOG"; GATE_REC=""   # task exists (ident persisted), no answer yet
if ( _proof_publish_gate ) >/dev/null 2>&1; then
  bad_t "pending blocks" "gate returned 0"
else
  ok_t "pending gate BLOCKS"
fi
[ ! -s "$ADD_LOG" ] && ok_t "pending gate does NOT re-file the task" || bad_t "no re-file" "$(cat "$ADD_LOG")"

# --- Case 2b: an EMPTY-nonce human:* approve (FUNNEA-3 shape) must NOT flip ---
# main 2026-07-23: a gate answered 'approve' by human:main with an empty
# human_nonce_hash is distrust-worthy — the rail label alone is not a verifiable
# tap. Authorizing a PUBLIC badge must require the nonce, so this BLOCKS.
GATE_REC="approve${US}human:main${US}"   # human: provenance, NO nonce
if ( _proof_publish_gate ) >/dev/null 2>&1; then
  bad_t "empty-nonce human:* blocks" "gate authorized on a nonce-less human:* approve"
else
  ok_t "empty-nonce human:* approve BLOCKS (no verifiable tap)"
fi
[ "$(jq -r '.publishApproved' "$STATE_DIR/proof.json")" = "false" ] && ok_t "empty-nonce approve keeps publishApproved=false" || bad_t "empty-nonce flipped" "$(jq -r '.publishApproved' "$STATE_DIR/proof.json")"

# --- Case 3: a nonce-backed human approve proceeds + flips the flag ----------
GATE_REC="approve${US}human:lodar${US}tap_nonce_abc123"   # genuine tap: nonce present
if ( _proof_publish_gate ) >/dev/null 2>&1; then
  ok_t "human approve -> gate PASSES (publish may proceed)"
else
  bad_t "human approve passes" "gate blocked"
fi
[ "$(pref '.publishApproved')" = "true" ] && ok_t "approve flips publishApproved=true" || bad_t "flip approved" "$(pref '.publishApproved')"

# --- Case 4: once approved, the gate is a no-op pass (task layer untouched) --
: >"$ADD_LOG"; : >"$NEED_LOG"; GATE_REC="SHOULD_NOT_BE_READ"
if ( _proof_publish_gate ) >/dev/null 2>&1; then ok_t "already-approved -> pass"; else bad_t "approved pass" "blocked"; fi
[ ! -s "$ADD_LOG" ] && [ ! -s "$NEED_LOG" ] && ok_t "approved path never touches the task layer" || bad_t "no task calls" "add=$(cat "$ADD_LOG") need=$(cat "$NEED_LOG")"

# --- Case 5: a human REJECT blocks ------------------------------------------
echo '{"approvalTaskIdent":"DIVE-777","publishApproved":false}' > "$STATE_DIR/proof.json"
GATE_REC="no${US}human:lodar${US}tap_nonce_abc123"   # genuine tap, but a decline
if ( _proof_publish_gate ) >/dev/null 2>&1; then
  bad_t "reject blocks" "gate returned 0 after a reject"
else
  ok_t "human reject BLOCKS"
fi

echo
echo "proof_publish_gate_unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
