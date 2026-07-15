#!/usr/bin/env bash
# DIVE-1284 isolated unit harness for the gate-ROUTING default: an `approval`-type
# `task need` with --tier omitted must default to tier 1 (agent/Marcus-clearable),
# NOT tier 2 (hard human gate). ROOT CAUSE: the type-default was
# `case $type in decision) tier=1 ;; *) tier=2 ;;`, so only `decision` defaulted to
# tier 1 while `approval` (the MOST common builder gate — "approve this
# ship/close/commit") defaulted to tier 2 and routed straight to the paired human.
# FIX: `decision|approval) tier=1`. SAFETY: the T2 category floor
# (_gate_tier2_floor_hit — money/public-comms/secrets/destructive/brand) and the
# secret-type floor still force tier 2 regardless of this default, so genuinely-human
# approvals are unaffected. This harness proves BOTH halves: non-floored approval
# lands tier 1; a money/brand/secret/destructive approval still floors to tier 2.
# Isolation matches the sibling harnesses (gate_tier2_floor_unit.sh): source src/
# libs into a throwaway STATE_DIR — the live shared tasks.db is NEVER touched.
# Run: bash tests/gate_approval_routing_unit.sh   (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-approval-routing-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# Don't DM on gate filing; no root-owned audit log in this harness.
task_need_notify() { :; }
audit_log() { :; }

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
tierof()    { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }

# --- A1: THE FIX — a non-floored `approval` gate with --tier omitted lands tier 1
#     (agent/Marcus-clearable), so delegatable ship/close/commit approvals no longer
#     route straight to the paired human. --------------------------------------------
seed_task DIVE-201
cmd_task_need DIVE-201 --type=approval --ask="approve the mechanical README sync?" --recommend="yes" >/dev/null 2>&1
[[ "$(tierof DIVE-201)" == "1" ]] \
  && ok_t "A1 non-floored approval (no --tier) defaults to tier 1 -> Marcus (the DIVE-1284 fix)" \
  || bad_t "A1 approval defaults tier 1" "got tier '$(tierof DIVE-201)'"

# --- A2: regression — a non-floored `decision` gate still defaults to tier 1. -------
seed_task DIVE-202
cmd_task_need DIVE-202 --type=decision --ask="pick lane" --options="A|B" --recommend="A" >/dev/null 2>&1
[[ "$(tierof DIVE-202)" == "1" ]] \
  && ok_t "A2 non-floored decision still defaults to tier 1 (unchanged)" \
  || bad_t "A2 decision defaults tier 1" "got tier '$(tierof DIVE-202)'"

# --- A3: `manual` is NOT swept into the tier-1 default — it still defaults to tier 2
#     (only decision|approval were lowered). -----------------------------------------
seed_task DIVE-203
cmd_task_need DIVE-203 --type=manual --ask="run the physical box swap" >/dev/null 2>&1
[[ "$(tierof DIVE-203)" == "2" ]] \
  && ok_t "A3 manual still defaults to tier 2 (hard human — only decision|approval lowered)" \
  || bad_t "A3 manual defaults tier 2" "got tier '$(tierof DIVE-203)'"

# --- A4: SAFETY BACKSTOP (money) — an `approval` whose ask trips the T2 category
#     floor is force-floored to tier 2 despite the new tier-1 default. --------------
seed_task DIVE-204
cmd_task_need DIVE-204 --type=approval --ask="approve the \$500 ad spend increase?" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-204)" == "2" ]] \
  && ok_t "A4 money approval still floors to tier 2 -> human (backstop holds)" \
  || bad_t "A4 money approval floors tier 2" "got tier '$(tierof DIVE-204)' (floor may have moved)"

# --- A5: SAFETY BACKSTOP (public-comms/brand) — approval to publish an announce post
#     still floors to tier 2. --------------------------------------------------------
seed_task DIVE-205
cmd_task_need DIVE-205 --type=approval --ask="approve publishing the launch announce post?" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-205)" == "2" ]] \
  && ok_t "A5 public-comms/brand approval still floors to tier 2 -> human" \
  || bad_t "A5 public-comms approval floors tier 2" "got tier '$(tierof DIVE-205)'"

# --- A6: SAFETY BACKSTOP (destructive) — approval to delete/teardown floors to tier 2.
seed_task DIVE-206
cmd_task_need DIVE-206 --type=approval --ask="approve teardown of the prod database?" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-206)" == "2" ]] \
  && ok_t "A6 destructive approval still floors to tier 2 -> human" \
  || bad_t "A6 destructive approval floors tier 2" "got tier '$(tierof DIVE-206)'"

# --- A7: SAFETY BACKSTOP (secret type) — a `secret` gate is always tier 2. ----------
seed_task DIVE-207
cmd_task_need DIVE-207 --type=secret --ask="drop the deploy key" >/dev/null 2>&1
[[ "$(tierof DIVE-207)" == "2" ]] \
  && ok_t "A7 secret type still tier 2 (unchanged)" \
  || bad_t "A7 secret type tier 2" "got tier '$(tierof DIVE-207)'"

# --- A8: an explicit --tier=2 on an approval is honored (caller's hard-human contract).
seed_task DIVE-208
cmd_task_need DIVE-208 --type=approval --ask="approve the mechanical README sync?" --recommend="yes" --tier=2 >/dev/null 2>&1
[[ "$(tierof DIVE-208)" == "2" ]] \
  && ok_t "A8 explicit --tier=2 on approval honored (hard-human contract preserved)" \
  || bad_t "A8 explicit tier 2 honored" "got tier '$(tierof DIVE-208)'"

echo "-----"
printf 'gate_approval_routing_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
