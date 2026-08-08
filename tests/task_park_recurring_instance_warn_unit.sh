#!/usr/bin/env bash
# TIER: nightly — 2.9s measured (agent-main control plane, 2026-08-08, DIVE-2877): the core/
# installed-host tier measured 313s against a 312s effective cap WITH this file present and
# 256/256 harnesses passing, so the corpus is at its cap and a new guard has to pay for itself.
# The argument is not that 2.9s is expensive — it is which 2.9s is safest to move. What this
# file grades is a WARNING on a non-destructive path: park still succeeds either way, so its
# failure mode is "the advice is missing or stale", never a data loss or a wrong mutation. That
# is a slow-drift property, which is what a nightly sweep is for, and it is the only thing in
# the diff that could move without either retiring another subject's guard or welding these
# arms onto one that must stay in core.
# MERGE BY SUBJECT WAS TRIED FIRST (the guard's own first preference) and MEASURED, not assumed:
# folding these arms into tests/task_park_gate_guard_unit.sh — same subject, the guards on
# cmd_task_park — ran 6771ms against 6545ms for the two files separately, i.e. it reclaims
# NOTHING here; the per-file setup is already cheap and the arms dominate. It would also have
# welded a warn-only guard to the DIVE-1453 park-over-gate guard, which protects a path that
# SILENTLY DESTROYS an open human gate and therefore must not be demotable. Reverted.
#
# DIVE-2877 isolated unit harness for the RECURRING-INSTANCE warning in cmd_task_park.
#
# Bug: parking an instance materialized from a recurring template is not a delay of
# that row — it stops the whole beat. The materializer dedups on `status NOT IN
# ('done','cancelled')`, a park sets status='blocked', so the parked instance holds
# the template's only open slot and every occurrence in the window is DROPPED with no
# catch-up; and the DIVE-2693 stall ladder requires `status='todo' AND parked_at IS
# NULL` at both rungs, so the row that stopped the beat is the one state the watchdog
# cannot see. Live case: DIVE-2694 (daily character drip), 9 days dark, nothing red.
#
# Fix graded here: park WARNS (never refuses) when from_template_id IS NOT NULL,
# names the template + its schedule, says the occurrences are dropped, and points at
# the two levers that actually mean "pause the job" (park the TEMPLATE, or cancel the
# instance). The ladder is deliberately NOT widened — rung 2's remedy is auto-cancel,
# so a wider population would destroy rows someone deliberately froze.
#
# Isolation matches the sibling park harness (tests/task_park_gate_guard_unit.sh):
# source src/ libs into a throwaway STATE_DIR — the live shared tasks.db is NEVER
# touched. Run: bash tests/task_park_recurring_instance_warn_unit.sh (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades. No `2>/dev/null` — the helper's
# stderr line IS the payload (see the note in task_park_gate_guard_unit.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/park-recurring-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
# DIVE-1919: bind the gate-proof paths to the isolated STATE_DIR too; tasks_db.sh
# derives them at SOURCE time from the DEFAULT /var/lib/5dive.
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
audit_log() { :; }

seed_template() { db "INSERT INTO tasks (ident, title, status, created_by, kind, schedule) VALUES ('$1','tmpl-$1','todo','main','recurring','$2');"; }
seed_instance() { db "INSERT INTO tasks (ident, title, status, created_by, kind, from_template_id) VALUES ('$1','inst-$1','todo','main','standard',(SELECT id FROM tasks WHERE ident='$2'));"; }
seed_plain()    { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
statusof()      { db "SELECT status FROM tasks WHERE ident='$1';"; }
parkedof()      { db "SELECT CASE WHEN parked_at IS NULL THEN 'no' ELSE 'yes' END FROM tasks WHERE ident='$1';"; }

# PRECONDITION, asserted not assumed: the dedup predicate this warning describes must
# actually still count a parked instance as open. If a later change makes the
# materializer ignore parked rows, the warning becomes a lie and every arm below would
# still pass — so pin the claim, not just the message.
seed_template DIVE-2900 '0 4 * * *'
seed_instance DIVE-2901 DIVE-2900
cmd_task_park DIVE-2901 --reason="precond" --wake=+1d >/dev/null 2>&1
_open=$(db "SELECT COUNT(*) FROM tasks WHERE from_template_id=(SELECT id FROM tasks WHERE ident='DIVE-2900') AND status NOT IN ('done','cancelled');")
[[ "$_open" == "1" ]] \
  && ok_t "PRECOND a PARKED instance still counts as the template's open slot (dedup would skip)" \
  || bad_t "PRECOND parked instance counts as open" "open=$_open (expected 1 — if 0, the materializer no longer suppresses and this warning's premise is stale)"
# ...and the correct lever the warning names is real: a parked TEMPLATE leaves the
# materializer's own selection (kind='recurring' AND schedule IS NOT NULL AND status='todo').
cmd_task_park DIVE-2900 --reason="freeze the job" --wake=+1d >/dev/null 2>&1
_sel=$(db "SELECT COUNT(*) FROM tasks WHERE kind='recurring' AND schedule IS NOT NULL AND status='todo' AND ident='DIVE-2900';")
[[ "$_sel" == "0" ]] \
  && ok_t "PRECOND parking the TEMPLATE drops it from the materializer's selection (the lever we advise is real)" \
  || bad_t "PRECOND template park stops the beat" "still selected=$_sel"

# --- T1: parking a recurring INSTANCE warns, and the warning is actionable. --------
seed_template DIVE-2910 '17 5 * * 1'
seed_instance DIVE-2911 DIVE-2910
out=$(cmd_task_park DIVE-2911 --reason="hold" --wake=+2d 2>&1); rc=$?
[[ "$out" == *"warn:"* && "$out" == *"DIVE-2877"* ]] \
  && ok_t "T1 park on a recurring instance emits an attributed warning" \
  || bad_t "T1 warning emitted" "rc=$rc out=$out"
[[ "$out" == *"DIVE-2910"* ]] \
  && ok_t "T1 the warning NAMES the template" \
  || bad_t "T1 names template" "out=$out"
[[ "$out" == *"17 5 * * 1"* ]] \
  && ok_t "T1 the warning carries the template's schedule" \
  || bad_t "T1 carries schedule" "out=$out"
[[ "$out" == *"DROPPED"* || "$out" == *"no catch-up"* ]] \
  && ok_t "T1 the warning states the occurrences are dropped, not deferred" \
  || bad_t "T1 states no catch-up" "out=$out"
[[ "$out" == *"task park DIVE-2910"* && "$out" == *"task cancel DIVE-2911"* ]] \
  && ok_t "T1 the warning names BOTH correct levers, with idents filled in" \
  || bad_t "T1 names both levers" "out=$out"

# --- T2: it WARNS, it does not refuse — the park still lands. This is the whole
#     design call (DIVE-2694 was parked for a legitimate reason). ------------------
[[ $rc -eq 0 ]] \
  && ok_t "T2 park still SUCCEEDS (exit 0) — warn, never refuse" \
  || bad_t "T2 park succeeds" "rc=$rc out=$out"
[[ "$(statusof DIVE-2911)" == "blocked" && "$(parkedof DIVE-2911)" == "yes" ]] \
  && ok_t "T2 the park took effect (status=blocked, parked_at set)" \
  || bad_t "T2 park took effect" "status=$(statusof DIVE-2911) parked=$(parkedof DIVE-2911)"

# --- T3: MUTATION CONTROL. The arms above must be able to FAIL. An ordinary task
#     (from_template_id NULL) parks with NO warning — the guard is scoped, and the
#     string checks are not passing on something every park prints. ---------------
seed_plain DIVE-2920
out2=$(cmd_task_park DIVE-2920 --reason="revisit later" --wake=+3d 2>&1); rc2=$?
[[ "$out2" != *"warn:"* && "$out2" != *"DIVE-2877"* ]] \
  && ok_t "T3 an ordinary task parks with NO recurring warning (guard is scoped)" \
  || bad_t "T3 no warning on a plain task" "out2=$out2"
[[ $rc2 -eq 0 && "$(parkedof DIVE-2920)" == "yes" ]] \
  && ok_t "T3 the ordinary park is UNCHANGED" \
  || bad_t "T3 ordinary park unchanged" "rc2=$rc2 parked=$(parkedof DIVE-2920)"

# --- T4: the warning names the RIGHT template, not merely some template. Two
#     templates exist by now, so a hardcoded/wrong-join warning is caught here. ---
seed_template DIVE-2930 '0 9 * * *'
seed_instance DIVE-2931 DIVE-2930
out3=$(cmd_task_park DIVE-2931 --reason="hold" --wake=+1d 2>&1)
[[ "$out3" == *"DIVE-2930"* && "$out3" != *"DIVE-2910"* ]] \
  && ok_t "T4 the warning resolves ITS OWN template (not another instance's)" \
  || bad_t "T4 correct template resolved" "out3=$out3"

# --- T5: the JSON envelope carries the fact too — warn() is stderr-only, so a
#     machine caller reading stdout would otherwise never see it. -----------------
seed_template DIVE-2940 '30 6 * * *'
seed_instance DIVE-2941 DIVE-2940
j=$(cmd_task_park DIVE-2941 --reason="hold" --wake=+1d 2>/dev/null)
got=$(printf '%s' "$j" | jq -r '.data.stops_recurring_template // "null"' 2>/dev/null)
[[ "$got" == "DIVE-2940" ]] \
  && ok_t "T5 JSON data.stops_recurring_template names the template" \
  || bad_t "T5 JSON field set" "got='$got' json=$j"
seed_plain DIVE-2950
j2=$(cmd_task_park DIVE-2950 --reason="hold" --wake=+1d 2>/dev/null)
got2=$(printf '%s' "$j2" | jq -r '.data.stops_recurring_template // "null"' 2>/dev/null)
[[ "$got2" == "null" ]] \
  && ok_t "T5 JSON field is null on an ordinary park (no false positive)" \
  || bad_t "T5 JSON field null when scoped out" "got2='$got2' json=$j2"

printf '\n%s\n' "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
