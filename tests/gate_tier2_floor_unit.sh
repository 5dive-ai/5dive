#!/usr/bin/env bash
# DIVE-1117 isolated unit harness for the tier-2 PROVENANCE FLOOR in cmd_task_answer
# (companion to DIVE-1115, CLI side / defense in depth). The DIVE-916/950 human-only
# + evidence blocks key on need_type (approval/secret/manual); a `decision` gate
# FLOORED to tier 2 by the T2 category heuristic is agent-clearable BY TYPE, so it
# slipped past and accepted a bare-agent answer (need_answered_by=main) even with
# `gate-proof enforce` ON (the OSS-16/OSS-25 incidents). The floor added here: under
# enforcement, `task answer` on a tier-2 gate refuses a NON-HUMAN answer (no --human
# => non-human provenance) regardless of need_type; a --human (human:*) answer from a
# trusted path is accepted (DIVE-525: real taps keep working). Tier 0/1 unaffected.
# Isolation matches the sibling harnesses: source src/ libs, throwaway STATE_DIR — the
# live shared tasks.db is NEVER touched. Run: bash tests/gate_tier2_floor_unit.sh
# (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-tier2-unit.XXXXXX)"
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

# Don't DM on gate filing; no root-owned audit log in this harness.
task_need_notify() { :; }
audit_log() { :; }

# The immediate caller is a non-agent (post-sudo root / dashboard-as-claude). This
# isolates the tier-2 provenance floor from the DIVE-394 `id -un` agent block so a
# rejection here proves the FLOOR fired, not the caller-uid guard.
FAKE_CALLER="root"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
answered() { db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='$1';"; }
provby()  { db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='$1';"; }
tierof()  { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }

# A non-agent SUDO_UID throughout (root) so the DIVE-916 evidence forms are NOT what
# gates these cases — the tier-2 provenance floor is. (A tier-2 decision mints no
# nonce anyway; see gate_nonce_unit T2.)
export SUDO_UID=0

touch "$GATE_PROOF_ENFORCE"   # enforcement ON for the floor tests

# --- T1: a decision gate EXPLICITLY filed at tier 2 mints no nonce yet is a hard
#     floor: a bare-agent answer (no --human) is REFUSED under enforcement. --------
seed_task DIVE-101
cmd_task_need DIVE-101 --type=decision --ask="ship it?" --options="A|B" --recommend="A" --tier=2 >/dev/null 2>&1
[[ "$(tierof DIVE-101)" == "2" ]] && ok_t "T1 decision --tier=2 stored as tier 2" \
  || bad_t "T1 decision tier 2 stored" "got tier '$(tierof DIVE-101)'"
out=$(cmd_task_answer DIVE-101 --value=A 2>&1); rc=$?
[[ "$(answered DIVE-101)" == "open" && $rc -ne 0 ]] \
  && ok_t "T1 bare-agent answer on tier-2 decision REFUSED (the OSS-16/25 slip)" \
  || bad_t "T1 bare-agent tier-2 refused" "rc=$rc state=$(answered DIVE-101) out=$out"
[[ "$out" == *"tier-2 human gate"* || "$out" == *"only a human"* ]] \
  && ok_t "T1 rejection carries an actionable tier-2 message" \
  || bad_t "T1 actionable message" "out=$out"

# --- T2: SAME gate, a trusted human path passes --human (recorded human:*): ACCEPTED
#     (DIVE-525 — a real tap/dashboard answer must never be blocked). --------------
seed_task DIVE-102
cmd_task_need DIVE-102 --type=decision --ask="ship it?" --options="A|B" --recommend="A" --tier=2 >/dev/null 2>&1
cmd_task_answer DIVE-102 --value=A --human >/dev/null 2>&1
[[ "$(answered DIVE-102)" == "closed" ]] \
  && ok_t "T2 --human answer on tier-2 decision CLEARS (trusted path)" \
  || bad_t "T2 --human tier-2 clears" "still $(answered DIVE-102)"
case "$(provby DIVE-102)" in human:*) ok_t "T2 provenance recorded human:*" ;; *) bad_t "T2 provenance human:*" "got '$(provby DIVE-102)'" ;; esac

# --- T3: a tier-1 decision gate is UNCHANGED — agents legitimately clear these. ---
seed_task DIVE-103
cmd_task_need DIVE-103 --type=decision --ask="pick lane" --options="A|B" --recommend="A" --tier=1 >/dev/null 2>&1
[[ "$(tierof DIVE-103)" == "1" ]] || bad_t "T3 precond tier 1" "got '$(tierof DIVE-103)'"
cmd_task_answer DIVE-103 --value=A >/dev/null 2>&1
[[ "$(answered DIVE-103)" == "closed" ]] \
  && ok_t "T3 bare-agent answer on tier-1 decision UNCHANGED (clears)" \
  || bad_t "T3 tier-1 agent answer unchanged" "still $(answered DIVE-103)"

# --- T4: the tier-2 floor is need_type-agnostic — a gate floored to tier 2 by the
#     T2 CATEGORY HEURISTIC (not an explicit --tier) is refused for a bare agent too.
#     "secrets" in the ask trips _gate_tier2_floor_hit (the exact OSS-16 mechanism).
seed_task DIVE-104
cmd_task_need DIVE-104 --type=decision --ask="rotate the prod secrets now?" --options="yes|no" --recommend="no" >/dev/null 2>&1
if [[ "$(tierof DIVE-104)" == "2" ]]; then
  ok_t "T4 category heuristic floored the decision gate to tier 2"
  out=$(cmd_task_answer DIVE-104 --value=no 2>&1); rc=$?
  [[ "$(answered DIVE-104)" == "open" && $rc -ne 0 ]] \
    && ok_t "T4 bare-agent answer on category-floored tier-2 gate REFUSED" \
    || bad_t "T4 category-floored refused" "rc=$rc state=$(answered DIVE-104) out=$out"
else
  # If the floor keyword set ever changes, don't silently pass — flag it.
  bad_t "T4 category heuristic floored to tier 2" "got tier '$(tierof DIVE-104)' (keyword floor may have moved)"
fi

# --- T5: rollout safety — enforcement OFF => the floor is dormant (audit-only), a
#     bare-agent answer on a tier-2 gate clears (matches the evidence-block envelope).
rm -f "$GATE_PROOF_ENFORCE"
seed_task DIVE-105
cmd_task_need DIVE-105 --type=decision --ask="ship it?" --options="A|B" --recommend="A" --tier=2 >/dev/null 2>&1
cmd_task_answer DIVE-105 --value=A >/dev/null 2>&1
[[ "$(answered DIVE-105)" == "closed" ]] \
  && ok_t "T5 enforce OFF => tier-2 floor dormant, bare-agent clears (audit-only)" \
  || bad_t "T5 enforce OFF dormant" "still $(answered DIVE-105)"
touch "$GATE_PROOF_ENFORCE"

echo "-----"
printf 'gate_tier2_floor_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
