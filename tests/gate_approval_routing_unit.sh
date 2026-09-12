#!/usr/bin/env bash
# DIVE-1284 isolated unit harness for the gate-ROUTING default: an `approval`-type
# `task need` with --tier omitted must default to tier 1 (agent/Marcus-clearable),
# NOT tier 2 (hard human gate). ROOT CAUSE: the type-default was
# `case $type in decision) tier=1 ;; *) tier=2 ;;`, so only `decision` defaulted to
# tier 1 while `approval` (the MOST common builder gate — "approve this
# ship/close/commit") defaulted to tier 2 and routed straight to the paired human.
# FIX: `decision|approval) tier=1`. SAFETY: the T2 category floor
# (_gate_tier2_floor_hit — money/public-comms/secrets/destructive) and the
# secret-type floor still force tier 2 regardless of this default, so genuinely-human
# approvals are unaffected. This harness proves BOTH halves: non-floored approval
# lands tier 1; money/public-comms/secret/destructive approvals still floor to tier 2,
# while a pure brand ask remains tier 1 for org-lead review (DIVE-1492).
# Isolation matches the sibling harnesses (gate_tier2_floor_unit.sh): source src/
# libs into a throwaway STATE_DIR — the live shared tasks.db is NEVER touched.
# Run: bash tests/gate_approval_routing_unit.sh   (no root, no network).
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-approval-routing-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
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

# --- A4: SAFETY BACKSTOP (money) — DIVE-4175 arm C moved the backstop from the
#     ask's WORDING to the filer's DECLARATION. The property is unchanged: an
#     approval that really is asking to spend reaches the human despite the tier-1
#     default. What changed is what makes it so. The undeclared control below
#     records the loosening rather than losing it.
seed_task DIVE-204
cmd_task_need DIVE-204 --type=approval --needs=spend_authority --ask="approve the \$500 ad spend increase?" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-204)" == "2" ]] \
  && ok_t "A4 DECLARED money approval is tier 2 -> human (backstop holds)" \
  || bad_t "A4 money approval floors tier 2" "got tier '$(tierof DIVE-204)' (the --needs human half is the sole route now)"
seed_task DIVE-214
cmd_task_need DIVE-214 --type=approval --ask="approve the \$500 ad spend increase?" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-214)" == "1" ]] \
  && ok_t "A4 control (arm C): the SAME ask UNDECLARED is tier 1 — wording no longer promotes" \
  || bad_t "A4 undeclared must not floor" "got tier '$(tierof DIVE-214)' — the keyword promoter is back"

# --- A5: DIVE-1492 — a PURE brand ask is lead-clearable tier 1, not human-only. ----
seed_task DIVE-205
cmd_task_need DIVE-205 --type=approval --ask="approve the brand palette direction?" --recommend="yes" >/dev/null 2>&1
[[ "$(tierof DIVE-205)" == "1" ]] \
  && ok_t "A5 pure brand approval stays tier 1 -> org lead" \
  || bad_t "A5 pure brand approval should stay tier 1" "got tier '$(tierof DIVE-205)'"

# --- A5b: public/publish terms remain a hard-human backstop after brand removal. ---
# DIVE-4175 arm C: `publish` is the term the row was BUILT on — it alone promoted
# 27 gates in the 30 days to 2026-09-09 and lodar answered zero of them. So this
# arm converts to the declaration, and the undeclared control is not an incidental
# loosening here but the change's whole purpose.
seed_task DIVE-209
cmd_task_need DIVE-209 --type=approval --needs=human_tap --ask="approve publishing the launch announce post?" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-209)" == "2" ]] \
  && ok_t "A5b DECLARED public-comms approval is tier 2 -> human" \
  || bad_t "A5b public-comms approval floors tier 2" "got tier '$(tierof DIVE-209)'"
seed_task DIVE-219
cmd_task_need DIVE-219 --type=approval --ask="approve publishing the launch announce post?" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-219)" == "1" ]] \
  && ok_t "A5b control (arm C): an undeclared 'publish' approval no longer pages the human — the 27-gate class" \
  || bad_t "A5b undeclared must not floor" "got tier '$(tierof DIVE-219)'"

# --- A6: SAFETY BACKSTOP (destructive) — approval to delete/teardown floors to tier 2.
seed_task DIVE-206
cmd_task_need DIVE-206 --type=approval --needs=human_tap --ask="approve teardown of the prod database?" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-206)" == "2" ]] \
  && ok_t "A6 DECLARED destructive approval is tier 2 -> human" \
  || bad_t "A6 destructive approval floors tier 2" "got tier '$(tierof DIVE-206)'"
# THE RESIDUAL ARM C SIGNS, asserted rather than described. An undeclared teardown
# of a production database now reaches a SEAT. The 30-day replay found two real
# instances of this shape that the human had answered (DIVE-3496 personal-account
# repo access, DIVE-3614 purge-and-reprovision a box), neither of which declared a
# capability. Arm E (DIVE-4176) and the lint are what cover it; the lint ships as a
# WARNING, so nothing REFUSES this filing today. Written down here so the next
# reader meets the residual in the corpus and not only in a task body.
seed_task DIVE-216
cmd_task_need DIVE-216 --type=approval --ask="approve teardown of the prod database?" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-216)" == "1" ]] \
  && ok_t "A6 residual (arm C): an UNDECLARED prod teardown reaches a seat, not the human — signed, not fixed" \
  || bad_t "A6 undeclared teardown" "got tier '$(tierof DIVE-216)' — if this is 2 the promoter is back"

# --- A7: SAFETY BACKSTOP (secret type) — a `secret` gate is always tier 2. ----------
seed_task DIVE-207
cmd_task_need DIVE-207 --type=secret --ask="drop the deploy key" --secret-key=DEPLOY_KEY --connector=fixture >/dev/null 2>&1
[[ "$(tierof DIVE-207)" == "2" ]] \
  && ok_t "A7 secret type still tier 2 (unchanged)" \
  || bad_t "A7 secret type tier 2" "got tier '$(tierof DIVE-207)'"

# --- A8: an explicit --tier=2 on an approval is honored (caller's hard-human contract).
seed_task DIVE-208
# DIVE-4346: a gate reaching the human must now NAME the capability it consumes.
# This fixture must keep the explicit --tier=2 pin as the SOURCE of the tier (that is
# what A8 grades), so it takes the audited --ask-ok exception rather than --needs=,
# which would make the declaration the source and grade a different thing.
cmd_task_need DIVE-208 --type=approval --ask="approve the mechanical README sync?" --recommend="yes" --tier=2 \
  --rubber-stamp-ok="fixture: this case grades that an explicit --tier=2 pin is honored, so it must BE one (DIVE-2848 cap)" \
  --ask-ok="fixture: A8 grades that the --tier=2 pin itself is honored, so the gate must reach the human WITHOUT a declared capability (DIVE-4346)" >/dev/null 2>&1
[[ "$(tierof DIVE-208)" == "2" ]] \
  && ok_t "A8 explicit --tier=2 on approval honored (hard-human contract preserved)" \
  || bad_t "A8 explicit tier 2 honored" "got tier '$(tierof DIVE-208)'"

echo "-----"
printf 'gate_approval_routing_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
