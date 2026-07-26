#!/usr/bin/env bash
# OSS-33 isolated unit harness for objective PREFLIGHT + explicit STOP-CONDITIONS
# (cmd_objective.sh, MVP-bar items 4 & 5). No root, no network — drives the pure
# helpers + the resume/replan wiring against a temp db. Asserts:
#   PREFLIGHT (refuse resume/drive, always with a reason):
#     - bare box (no org, no planner) resumes fine (advisory, never false-fail)
#     - a populated org with a planner + a distinct teammate passes
#     - planner is the ONLY org member -> missing_verifier
#     - planner not in a populated org -> role_unreachable
#     - over-budget objective -> over_budget (refused even with no org)
#     - a preflight refusal is bypassable with --force
#   STOP-CONDITIONS (never a silent stall; explicit outcome recorded):
#     - a pending gate from a prior cycle -> gate_pending (loop waits, no new proposal)
#     - metric flat for N cycles -> no_progress + objective PAUSED
# Run: bash tests/objective_preflight_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/obj-preflight-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_goal.sh \
         cmd_loop.sh cmd_objective.sh; do
  source "$SRC/$f"
done

# test seam: never spawn a real planner agent (a live loop would block) — a live
# replan that reaches the planner returns a canned empty diff instead of hanging,
# so a guard that FAILS to fire surfaces as a wrong outcome, not a timeout.
cmd_loop_spawn() { printf '%s' '{"ok":true,"data":{"status":"done","result":"{}","tokensSpent":10}}'; }

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
jf()    { jq -r "$1" 2>/dev/null; }
run()   { ( "cmd_objective_$@" ) 2>"$TMP/err"; }
objid() { db "SELECT id FROM objectives WHERE name=$(sqlq "$1");"; }

# ---------- PREFLIGHT ----------

# T1: bare box (no org chart, no planner) — resume must PASS with an advisory.
( cmd_objective_add "bare" --metric-cmd="echo 1" --target=100 ) >/dev/null 2>&1
( cmd_objective_setstatus paused "bare" ) >/dev/null 2>&1
r=$(run setstatus active "bare")
[[ "$(echo "$r" | jf '.ok')" == "true" && "$(db "SELECT status FROM objectives WHERE name='bare';")" == "active" ]] \
  && ok_t "bare box (no org) resumes fine — preflight never false-fails" || bad_t "bare resume" "$r :: $(cat "$TMP/err")"

# Seed an org chart: a coordinator planner + one distinct teammate (the verifier).
( cmd_org set boss --role=coordinator ) >/dev/null 2>&1
( cmd_org set worker --manager=boss ) >/dev/null 2>&1

# T2: populated org, coordinator resolvable, distinct teammate exists -> PASS.
( cmd_objective_add "wired" --metric-cmd="echo 5" --target=100 --planner=boss ) >/dev/null 2>&1
( cmd_objective_setstatus paused "wired" ) >/dev/null 2>&1
r=$(run setstatus active "wired")
[[ "$(echo "$r" | jf '.ok')" == "true" ]] \
  && ok_t "wired objective (planner + distinct verifier) passes preflight" || bad_t "wired resume" "$r :: $(cat "$TMP/err")"

# T3: planner is the ONLY member of its org -> missing_verifier.
OID=$(objid "wired")
oid_pre() { ( cmd_objective_preflight "$1" "$2" ) >/dev/null 2>&1; }
# fresh single-member org db slice: point planner at 'solo' and ensure no distinct member
# (simulate by making the objective's planner a name that is the sole org row).
db "DELETE FROM agents_org;"
( cmd_org set solo --role=coordinator ) >/dev/null 2>&1
( cmd_objective_add "single" --metric-cmd="echo 5" --target=100 --planner=solo ) >/dev/null 2>&1
( cmd_objective_setstatus paused "single" ) >/dev/null 2>&1
r=$(run setstatus active "single")
[[ "$(echo "$r" | jf '.ok')" != "true" ]] && echo "$(cat "$TMP/err")" | grep -qi 'missing_verifier' \
  && ok_t "planner is the only org member -> missing_verifier (refused)" || bad_t "missing_verifier" "$r :: $(cat "$TMP/err")"

# T4: planner not present in a populated org -> role_unreachable.
( cmd_org set helper --manager=solo ) >/dev/null 2>&1   # org now has a distinct member
( cmd_objective_add "dangling" --metric-cmd="echo 5" --target=100 --planner=ghost ) >/dev/null 2>&1
( cmd_objective_setstatus paused "dangling" ) >/dev/null 2>&1
r=$(run setstatus active "dangling")
[[ "$(echo "$r" | jf '.ok')" != "true" ]] && grep -qi 'role_unreachable' "$TMP/err" \
  && ok_t "planner not in a populated org -> role_unreachable (refused)" || bad_t "role_unreachable" "$r :: $(cat "$TMP/err")"

# T5: over-budget objective -> over_budget (refused even independent of org).
( cmd_objective_add "spent" --metric-cmd="echo 5" --target=100 --budget=50 --planner=solo ) >/dev/null 2>&1
SID=$(objid "spent")
db "INSERT INTO objective_cycles (objective_id, cycle_no, tokens_spent, outcome) VALUES ($SID, 1, 60, 'applied');"
( cmd_objective_setstatus paused "spent" ) >/dev/null 2>&1
r=$(run setstatus active "spent")
[[ "$(echo "$r" | jf '.ok')" != "true" ]] && grep -qi 'over_budget' "$TMP/err" \
  && ok_t "over-budget objective -> over_budget (refused)" || bad_t "over_budget" "$r :: $(cat "$TMP/err")"

# T6: --force bypasses a refusal (deliberate human override).
r=$(run setstatus active "dangling" --force)
[[ "$(echo "$r" | jf '.ok')" == "true" && "$(db "SELECT status FROM objectives WHERE name='dangling';")" == "active" ]] \
  && ok_t "--force bypasses a preflight refusal" || bad_t "force bypass" "$r :: $(cat "$TMP/err")"

# ---------- STOP-CONDITIONS (live path) ----------

# T7: a pending gate from a prior cycle -> gate_pending; no new proposal stacked.
# Build a live objective, run a replan whose diff files a gate (proposal awaiting
# a decision), then a follow-up replan must WAIT on that gate rather than plan again.
db "DELETE FROM agents_org;"
( cmd_org set boss --role=coordinator ) >/dev/null 2>&1
( cmd_org set worker --manager=boss ) >/dev/null 2>&1
( cmd_objective_add "hg" --metric-cmd="echo 5" --target=100 --planner=boss --max-new-per-cycle=2 ) >/dev/null 2>&1
HID=$(objid "hg")
db "INSERT INTO objective_readings (objective_id, value, rc) VALUES ($HID, 5, 0);"
# A spend-risk create files an origination gate (tier depends on cmd_task_need's classifier).
DIFF_T2='{"create":[{"local_id":"t1","title":"buy paid ads to lift signups","assignee_or_role":"worker","risk":"spend"}]}'
r=$(run replan "hg" --diff="$DIFF_T2")
gated=$(echo "$r" | jf '.data.gated'); anchor=$(echo "$r" | jf '.data.anchor')
# Now the autonomous path (no --diff) must detect the pending gate and wait.
r2=$(run replan "hg")
out2=$(echo "$r2" | jf '.data.outcome')
[[ "$gated" == "true" && "$out2" == "gate_pending" ]] \
  && ok_t "pending gate from a prior cycle -> gate_pending (loop waits, no new proposal)" \
  || bad_t "gate_pending" "gated=$gated anchor=$anchor out2=$out2 :: r=$r :: r2=$r2 :: $(cat "$TMP/err")"

# T8: metric flat for N cycles -> no_progress + objective PAUSED.
( cmd_objective_add "flat" --metric-cmd="echo 5" --target=100 --planner=boss ) >/dev/null 2>&1
FID=$(objid "flat")
db "INSERT INTO objective_readings (objective_id, value, rc) VALUES ($FID, 5, 0);"
# Seed 3 prior cycles all at reading 5 (no movement) so a limit of 3 trips.
for c in 1 2 3; do
  db "INSERT INTO objective_cycles (objective_id, cycle_no, reading_value, outcome) VALUES ($FID, $c, 5, 'applied');"
done
r=$(run replan "flat" --no-progress-limit=3)
out=$(echo "$r" | jf '.data.outcome')
st=$(db "SELECT status FROM objectives WHERE id=$FID;")
[[ "$out" == "no_progress" && "$st" == "paused" ]] \
  && ok_t "metric flat for N cycles -> no_progress + PAUSED" || bad_t "no_progress" "out=$out st=$st :: $r :: $(cat "$TMP/err")"

# T9: no_progress does NOT trip while the metric is still improving.
( cmd_objective_add "moving" --metric-cmd="echo 9" --target=100 --planner=boss ) >/dev/null 2>&1
MID=$(objid "moving")
db "INSERT INTO objective_readings (objective_id, value, rc) VALUES ($MID, 9, 0);"
db "INSERT INTO objective_cycles (objective_id, cycle_no, reading_value, outcome) VALUES ($MID, 1, 5, 'applied');"
db "INSERT INTO objective_cycles (objective_id, cycle_no, reading_value, outcome) VALUES ($MID, 2, 7, 'applied');"
db "INSERT INTO objective_cycles (objective_id, cycle_no, reading_value, outcome) VALUES ($MID, 3, 9, 'applied');"
# helper returns 0 iff STOP; improving window must NOT stop.
_objective_no_progress "$MID" "up" 3
[[ $? -ne 0 ]] && ok_t "improving metric does NOT trip no_progress" || bad_t "no_progress false-positive" "tripped on rising window"

echo "-----"
printf 'objective_preflight_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
