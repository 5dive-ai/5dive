#!/usr/bin/env bash
# DIVE-1437 isolated unit harness for the T2-floor-refused ROUTED-gate escalation in
# cmd_task_answer. ROOT (DIVE-1429): a builder gate that DIVE-1145/1182 lead-routed
# (routed_reviewer set) but whose effective tier is 2 (a non-floored `manual` gate —
# manual still defaults to tier 2 per DIVE-1284) cannot be cleared by the agent lead:
# the DIVE-1117 tier-2 hard-human floor refuses the lead's non-human answer. And
# cmd_task_need RETURNED before task_need_notify when it routed, so the human never got
# a tap button — the gate STALLS (the lead hand-asks the human in plain chat with no
# button). FIX: at the T2-floor refusal, if the gate is a ROUTED approval/manual gate,
# ESCALATE to the human via task_need_notify (fires the tap keyboard), take the lead out
# (routed_reviewer NULL), re-arm the ping (gate_pinged_at NULL), and mint a FRESH human
# nonce so anti-forge holds (only a real tap/nonce/non-agent SUDO_UID clears it). A
# NON-routed tier-2 gate is unchanged (already got its human button at filing → still
# refused). Isolation matches the sibling harnesses. Run: bash tests/gate_t2_routed_escalate_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-t2-routed-escalate-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# File-backed observer: cmd_task_answer runs inside a `$(...)` subshell in the cases
# that capture its output, so a plain var would be lost — record the ping on disk.
NOTIFIED_FILE="$TMP/notified"; : > "$NOTIFIED_FILE"
task_need_notify() { echo "$1:$2" > "$NOTIFIED_FILE"; }   # "<ident>:<type>"
_nf()   { cat "$NOTIFIED_FILE" 2>/dev/null; }
_nf_reset() { : > "$NOTIFIED_FILE"; }
audit_log() { :; }

# The immediate caller is the agent LEAD (agent-marcus) attempting to clear a gate that
# was routed to it — the DIVE-1429 shape. id -un is stubbed so _lead_clear resolves.
FAKE_CALLER="agent-marcus"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }

seed_task()  { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
route_to()   { db "UPDATE tasks SET routed_reviewer='$2' WHERE ident='$1';"; }
answered()   { db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='$1';"; }
routedrev()  { db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }
noncehash()  { db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE ident='$1';"; }
pinged()     { db "SELECT COALESCE(gate_pinged_at,'') FROM tasks WHERE ident='$1';"; }
tierof()     { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }

export SUDO_UID=1234   # an agent-ish uid: not the non-agent (root/claude) evidence form
touch "$GATE_PROOF_ENFORCE"   # enforcement ON (the floor + escalation are live)

# --- E1: THE FIX — a ROUTED tier-2 manual gate, answered by its lead, ESCALATES to the
#     human instead of dead-ending: routed_reviewer cleared, ping re-armed, fresh nonce
#     minted, human ping fired, and the gate stays OPEN (awaiting the human tap). -------
seed_task DIVE-301
cmd_task_need DIVE-301 --type=manual --ask="run the physical box swap" >/dev/null 2>&1
[[ "$(tierof DIVE-301)" == "2" ]] || bad_t "E1 precond manual defaults tier 2" "got '$(tierof DIVE-301)'"
route_to DIVE-301 marcus
db "UPDATE tasks SET gate_pinged_at='2026-07-18 00:00:00' WHERE ident='DIVE-301';"  # a prior stale ping
_nf_reset
out=$(cmd_task_answer DIVE-301 --value=approved 2>&1); rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "E1 escalation returns success (not a dead-end fail)" \
  || bad_t "E1 escalation rc 0" "rc=$rc out=$out"
[[ "$(answered DIVE-301)" == "open" ]] \
  && ok_t "E1 gate stays OPEN (the lead did NOT clear it; awaiting the human)" \
  || bad_t "E1 gate open" "state=$(answered DIVE-301)"
[[ "$(routedrev DIVE-301)" == "" ]] \
  && ok_t "E1 routed_reviewer CLEARED (lead taken out of the loop)" \
  || bad_t "E1 routed_reviewer cleared" "got '$(routedrev DIVE-301)'"
[[ "$(pinged DIVE-301)" == "" ]] \
  && ok_t "E1 gate_pinged_at RE-ARMED to NULL (ping fires fresh)" \
  || bad_t "E1 gate_pinged_at re-armed" "got '$(pinged DIVE-301)'"
[[ -n "$(noncehash DIVE-301)" ]] \
  && ok_t "E1 fresh human nonce minted (anti-forge: only a real tap clears)" \
  || bad_t "E1 nonce minted" "human_nonce_hash empty"
[[ "$(_nf)" == "DIVE-301:manual" ]] \
  && ok_t "E1 task_need_notify FIRED with the tap keyboard (human gets a button)" \
  || bad_t "E1 human ping fired" "notified='$(_nf)'"
[[ "$out" == *'"escalated_to_human":true'* ]] \
  && ok_t "E1 result flags escalated_to_human (actionable to the caller)" \
  || bad_t "E1 escalation message" "out=$out"

# --- E2: a NON-routed tier-2 manual gate is UNCHANGED — it already got its human button
#     at filing, so a bare-agent answer is still REFUSED (no escalation, no re-ping). ---
seed_task DIVE-302
cmd_task_need DIVE-302 --type=manual --ask="run the physical box swap" >/dev/null 2>&1
# no route_to: routed_reviewer stays NULL
_nf_reset
out=$(cmd_task_answer DIVE-302 --value=approved 2>&1); rc=$?
[[ "$(answered DIVE-302)" == "open" && $rc -ne 0 ]] \
  && ok_t "E2 non-routed tier-2 manual still REFUSED (unchanged)" \
  || bad_t "E2 non-routed refused" "rc=$rc state=$(answered DIVE-302) out=$out"
[[ -z "$(_nf)" ]] \
  && ok_t "E2 no escalation ping on a non-routed gate" \
  || bad_t "E2 no ping" "notified='$(_nf)'"
[[ "$out" == *"only a human"* || "$out" == *"tier-2 human gate"* ]] \
  && ok_t "E2 keeps the original tier-2 refusal message" \
  || bad_t "E2 refusal message" "out=$out"

# --- E3: a routed tier-2 manual gate cleared by a real HUMAN (--human) clears normally —
#     escalation only fires for the NON-human refusal path (DIVE-525: taps never break). -
seed_task DIVE-303
cmd_task_need DIVE-303 --type=manual --ask="run the physical box swap" >/dev/null 2>&1
route_to DIVE-303 marcus
_nf_reset
cmd_task_answer DIVE-303 --value=approved --human >/dev/null 2>&1
[[ "$(answered DIVE-303)" == "closed" ]] \
  && ok_t "E3 --human answer on a routed tier-2 gate CLEARS (no escalation needed)" \
  || bad_t "E3 --human clears" "still $(answered DIVE-303)"
[[ -z "$(_nf)" ]] \
  && ok_t "E3 no re-escalation on a genuine human clear" \
  || bad_t "E3 no re-escalation" "notified='$(_nf)'"

# --- E4: rollout safety — enforcement OFF => the floor (and thus the escalation) is
#     dormant; a routed tier-2 manual gate is cleared by its lead directly (DIVE-1182). -
rm -f "$GATE_PROOF_ENFORCE"
seed_task DIVE-304
cmd_task_need DIVE-304 --type=manual --ask="run the physical box swap" >/dev/null 2>&1
route_to DIVE-304 marcus
_nf_reset
cmd_task_answer DIVE-304 --value=approved >/dev/null 2>&1
[[ "$(answered DIVE-304)" == "closed" && -z "$(_nf)" ]] \
  && ok_t "E4 enforce OFF => floor dormant, lead clears routed gate directly (no escalation)" \
  || bad_t "E4 enforce OFF dormant" "state=$(answered DIVE-304) notified='$(_nf)'"
touch "$GATE_PROOF_ENFORCE"

echo "-----"
printf 'gate_t2_routed_escalate_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
