#!/usr/bin/env bash
# DIVE-4251 isolated unit harness — the two CONSUMERS of the box policy:
# `task done` (the maker's close) and `task grader-tick` (the ephemeral lane).
#
# BOTH ARMS ARE DIFFERENTIAL, and that is the point. "No refusal appeared" and
# "no grader spawned" are both satisfied by a build where the code never ran at
# all, so each arm is measured against the SAME fixture under `verify=always`,
# where the refusal must appear and the spawn must happen. A pass is the
# DIFFERENCE between the two readings, never one reading on its own.
#
# Run: bash tests/verify_policy_close_and_pool_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/verify-policy-close.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/verify_policy.sh lib/tasks_db.sh \
         lib/actor.sh cmd_task.sh cmd_push.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done
source "$SRC/task/grader_pool.sh"

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
BOX_CONFIG="$TMP/box.json"; JSON_MODE=0
mkdir -p "$TASKS_DIR"
set +e
PASS=0; FAILN=0
ok_t()  { PASS=$((PASS+1));  printf 'ok   - %s\n' "$1"; }
bad_t() { FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
set_policy() { printf '{"verify":"%s"}\n' "$1" > "$BOX_CONFIG"; }
tasks_db_init >/dev/null 2>&1

# ── ARM 1: the maker's close on a `never` box ────────────────────────────────
# The fixture is a DELIVERED loop: assignee==verifier, maker recorded, still
# open. That is precisely the state DIVE-2007's guard protects, so under
# `always` the maker's own `task done` must be refused.
seed_delivered() { # -> ident
  local t="close $1 $RANDOM"
  db "INSERT INTO tasks (title,status,assignee,verifier,maker_agent,kind,priority,created_by,iteration,delivery_ref)
      VALUES ($(sqlq "$t"),'todo','quinn','quinn','dev2','standard','high','main',1,'https://github.com/o/r/pull/7');" >/dev/null
  db "SELECT ident FROM tasks ORDER BY id DESC LIMIT 1;"
}
maker_close() { # <ident> -> combined output
  ( actor_seam_as dev2; cmd_task_done "$1" --result="done" ) 2>&1
}

set_policy always
_i=$(seed_delivered always); _out_always=$(maker_close "$_i")
if [[ "$_out_always" == *"writer != grader"* ]]; then
  ok_t "always: maker's close on a delivered row is REFUSED (control)"
else
  bad_t "always: maker's close is refused (control)" "no DIVE-2007 refusal in: ${_out_always:0:240}"
fi

set_policy never
_i=$(seed_delivered never); _out_never=$(maker_close "$_i")
if [[ "$_out_never" == *"writer != grader"* ]]; then
  bad_t "never: maker's close is NOT refused" "the DIVE-2007 refusal still fires on a box that grants no grader: ${_out_never:0:240}"
else
  ok_t "never: maker's close is not refused (the row is closable by its maker)"
fi

# The absence of a refusal is not the same as a CLOSE, and the fixture above
# cannot tell them apart: it carries a delivery_ref, so DIVE-1830's merge gate
# holds it open whatever the verification policy says — correctly, because a
# merge gate is not a grader. So the close itself is asserted on the row shape
# that has no merge to gate: an unbound row (knowledge, ops, coordination), which
# is exactly the class `never` and `delivered-only` exist to stop charging for.
seed_unbound() {
  local t="unbound $RANDOM"
  db "INSERT INTO tasks (title,status,assignee,verifier,maker_agent,kind,priority,created_by,iteration)
      VALUES ($(sqlq "$t"),'todo','quinn','quinn','dev2','standard','high','main',1);" >/dev/null
  db "SELECT ident FROM tasks ORDER BY id DESC LIMIT 1;"
}
set_policy never
_iu=$(seed_unbound); _ou=$(maker_close "$_iu")
_stu=$(db "SELECT status FROM tasks WHERE ident=$(sqlq "$_iu");")
if [[ "$_stu" == "done" ]]; then
  ok_t "never: the maker's close actually CLOSES an unbound delivered row"
else
  bad_t "never: the maker's close closes an unbound row" "status='$_stu' out=${_ou:0:240}"
fi
set_policy always
_iu=$(seed_unbound); _ou=$(maker_close "$_iu")
_stu=$(db "SELECT status FROM tasks WHERE ident=$(sqlq "$_iu");")
if [[ "$_stu" != "done" ]]; then
  ok_t "always: the same close is held open (control — the difference is the policy)"
else
  bad_t "always: the same close is held open (control)" "status='$_stu' — the never arm above proves nothing"
fi

# ── ARM 2: the ephemeral lane's tick over MIXED-POLICY rows ──────────────────
# Three delivered rows, all with a pending grade request, differing only in
# their ROW override. Counts are asserted, not just the absence of a spawn.
seed_pending() { # <override:none|skip|force> -> ident
  local ov="$1"
  local t="pool ${ov} $RANDOM"
  # This fixture says it is delivered, so stamp the canonical delivery clock
  # that the real _task_route_to_verifier path always writes. A delivery_ref is
  # only an artifact binding; treating it as proof of a live handoff would put
  # already-graded merge work back into the pending pool.
  db "INSERT INTO tasks (title,status,assignee,verifier,maker_agent,kind,priority,created_by,
                         handoff_delivered_at,delivery_ref)
      VALUES ($(sqlq "$t"),'todo','quinn','quinn','dev2','standard','high','main',
              datetime('now'),'https://github.com/o/r/pull/8');" >/dev/null
  local id; id=$(db "SELECT ident FROM tasks ORDER BY id DESC LIMIT 1;")
  case "$ov" in
    skip)  db "UPDATE tasks SET verify_optout=1 WHERE ident=$(sqlq "$id");" >/dev/null ;;
    force) db "UPDATE tasks SET verify_forced=1 WHERE ident=$(sqlq "$id");" >/dev/null ;;
  esac
  # idem_key is NOT NULL UNIQUE — a fixture that omits it inserts nothing and the
  # tick then reads pending=0, which looks exactly like a working policy filter.
  db "INSERT INTO lifecycle_events (kind,ident,actor,idem_key,detail)
      VALUES ('task.grade.requested',$(sqlq "$id"),'sys',$(sqlq "req-${id}-$RANDOM"),'fixture');" >/dev/null
  printf '%s' "$id"
}
_p_none=$(seed_pending none); _p_skip=$(seed_pending skip); _p_force=$(seed_pending force)

# The lane is held dark by its own two locks in production; here the pool is
# named and the probes are stubbed permissive, so the ONLY thing that can
# suppress a spawn is the policy under test.
_GRADER_POOL="g1"
_GRADER_USAGE_CMD=_vp_usage
_vp_usage() { printf '{"agents":[{"account":"a","name":"g1","fiveHourPct":1,"sevenDayPct":1}]}'; }
_grader_can_read() { return 0; }
_grader_spawn_session() { return 0; }

tick_counts() { cmd_task_grader_tick --json 2>/dev/null; }

# PLANNED = spawned + queued. The pool's concurrency cap is 2 here, so the extra
# row lands in `queued` rather than `spawned` — a cap is not a policy refusal and
# an arm that could not tell them apart would read "the customer was spared a
# grader" off a busy pool.
planned() { jq -r '.spawned + .queued' <<<"$1"; }

set_policy always
_j=$(tick_counts); _sp_always=$(planned "$_j"); _dk_always=$(jq -r '.dark' <<<"$_j")
# `dark` is asserted beside the count on purpose: the pool's concurrency cap is 2,
# so a build that granted the --no-verify row a grader would ALSO read spawned=2
# — the third row would simply queue. Only the declined count distinguishes them.
if [[ "$_sp_always" == "2" && "$_dk_always" == "1" ]]; then
  ok_t "always: the tick plans 2 grades and DECLINES the --no-verify row (control)"
else
  bad_t "always: 2 planned, 1 declined" "planned=$_sp_always dark=$_dk_always json=$_j"
fi

set_policy never
_j=$(tick_counts); _sp_never=$(planned "$_j"); _dk_never=$(jq -r '.dark' <<<"$_j")
if [[ "$_sp_never" == "1" && "$_dk_never" == "2" ]]; then
  ok_t "never: only the --verify row is planned (1 spawn, 2 declined)"
else
  bad_t "never: only the --verify row is planned" "spawned=$_sp_never dark=$_dk_never json=$_j"
fi

set_policy delivered-only
_j=$(tick_counts); _sp_do=$(planned "$_j")
if [[ "$_sp_do" == "2" ]]; then
  ok_t "delivered-only: bound rows are planned (2 spawns), the opted-out row is not"
else
  bad_t "delivered-only: 2 spawns planned" "spawned=$_sp_do json=$_j"
fi

# The difference is what proves the policy is being read at all.
if [[ "$_sp_always" != "$_sp_never" ]]; then
  ok_t "the tick's spawn count MOVES with the box policy (always=$_sp_always never=$_sp_never)"
else
  bad_t "the tick's spawn count moves with the box policy" "identical counts ($_sp_always) under always and never — the lane is not reading the policy"
fi

# ── ARM 3 (quinn's reject, iteration 1): the `--no-verify` half, AT DELIVERY ──
# The 9-arm matrix drives the override only through `task add`, where the
# PRE-EXISTING `-z "$no_verify"` term at src/task/crud.sh:517 short-circuits
# before the resolver is consulted — so the three `--no-verify` arms pass whether
# or not `verify_grants_grader` honours `skip`, and deleting that branch reds
# nothing. `task deliver --pr=` is the call site where it is NOT subsumed: a row
# the customer opted out of is unbound at filing and becomes bound here, which is
# exactly the moment `delivered-only`/`always` would otherwise attach a grader.
# That is the customer-visible failure — a second session they declined and are
# billed for, on the row whose whole axis is that they get to decide.
#
# The arm runs under `verify=always` on purpose: the BOX says yes, so the only
# thing that can keep the grader off is the ROW's skip. The plain row beside it is
# the non-vacuity control — without it "the verifier column is empty" is also what
# a build that never attaches anything reads like.
set_policy always
FIVE_DELIVER_NO_REACH_PROBE=1
# The default-grader pick walks the org chart, which is empty in this fixture and
# would hand both rows an empty verifier for a reason that has nothing to do with
# the policy. Naming it here keeps the arm measuring the resolver.
_task_default_verifier() { printf 'quinn'; }

seed_deliverable() { # <override:none|skip> -> ident
  local ov="$1"; local t="deliver ${ov} $RANDOM"
  db "INSERT INTO tasks (title,status,assignee,maker_agent,kind,priority,created_by,iteration)
      VALUES ($(sqlq "$t"),'in_progress','dev2','dev2','standard','high','main',1);" >/dev/null
  local id; id=$(db "SELECT ident FROM tasks ORDER BY id DESC LIMIT 1;")
  [[ "$ov" == "skip" ]] && db "UPDATE tasks SET verify_optout=1 WHERE ident=$(sqlq "$id");" >/dev/null
  printf '%s' "$id"
}
deliver_as_maker() { ( actor_seam_as dev2; cmd_task_deliver "$1" --pr="https://github.com/o/r/pull/9" ) 2>&1; }
row_verifier() { db "SELECT COALESCE(verifier,'') FROM tasks WHERE ident=$(sqlq "$1");"; }

_j=$(tick_counts); _pl_base=$(planned "$_j"); _dk_base=$(jq -r '.dark' <<<"$_j")

_d_skip=$(seed_deliverable skip);  _od_skip=$(deliver_as_maker "$_d_skip")
_d_none=$(seed_deliverable none);  _od_none=$(deliver_as_maker "$_d_none")
_v_skip=$(row_verifier "$_d_skip"); _v_none=$(row_verifier "$_d_none")

if [[ -n "$_v_none" ]]; then
  ok_t "always: delivering a plain row ATTACHES a grader (control — the column can be written)"
else
  bad_t "always: delivering a plain row attaches a grader (control)" "verifier='' on the un-opted-out row — the skip arm below would pass on an empty fixture. out=${_od_none:0:240}"
fi
if [[ -z "$_v_skip" ]]; then
  ok_t "always: delivering a --no-verify row attaches NO grader (the row override survives the binding)"
else
  bad_t "always: delivering a --no-verify row attaches no grader" "verifier='$_v_skip' — the customer opted out and 'task deliver' booked them a grader session anyway. out=${_od_skip:0:240}"
fi

# And the pool must not pick it up either. This is the case the tick's own
# defence-in-depth branch exists for and no arm constructed: the request is
# emitted (here, by hand — the same shape a policy flip AFTER a queued request
# produces) and the tick must still decline it. Deltas, not absolutes, so the
# three rows already pending from ARM 2 cannot mask the reading.
# Only the opted-out row needs a hand-written request: the control's is emitted by
# the delivery itself when it routes, which is the realistic shape.
db "INSERT INTO lifecycle_events (kind,ident,actor,idem_key,detail)
    VALUES ('task.grade.requested',$(sqlq "$_d_skip"),'sys',$(sqlq "req-${_d_skip}-$RANDOM"),'fixture');" >/dev/null
# Model the state after a request was queued and policy then flipped to skip:
# the handoff remains delivered to its verifier, but the current policy must
# decline it. cmd_task_deliver correctly leaves an opted-out row with its maker,
# so the fixture must construct this historical transition explicitly.
db "UPDATE tasks
       SET status='todo', assignee='quinn', verifier='quinn',
           handoff_delivered_at=datetime('now')
     WHERE ident=$(sqlq "$_d_skip");" >/dev/null
_j=$(tick_counts); _pl_now=$(planned "$_j"); _dk_now=$(jq -r '.dark' <<<"$_j")
if [[ "$_pl_now" == "$((_pl_base+1))" && "$_dk_now" == "$((_dk_base+1))" ]]; then
  ok_t "always: the tick plans a grade for the plain delivered row and NONE for the --no-verify one (+1 planned, +1 declined)"
else
  bad_t "always: the tick declines the --no-verify delivered row" "planned $_pl_base->$_pl_now (want $((_pl_base+1))), dark $_dk_base->$_dk_now (want $((_dk_base+1))) json=$_j"
fi

# The resolver's `skip` branch, asserted directly. Cheap, and it names the line:
# with `skip) return 1` deleted this is the arm that says WHICH line moved, while
# the two above say what it cost the customer.
if verify_grants_grader always skip 1; then
  bad_t "resolver: 'always skip 1' is declined" "verify_grants_grader returned 0 — a row's --no-verify is being overruled by the box default"
else
  ok_t "resolver: 'always skip 1' is declined (the row override beats the box default)"
fi

# ── ARM 4: the retrofit is a DEMAND, not a decoration ────────────────────────
# `task verifier <id> <agent>` names a grader by hand. On a `never` box that must
# actually produce a graded row — an attach that stores a verifier the router then
# declines to use looks like it worked and grades nothing.
set_policy never
db "INSERT INTO tasks (title,status,assignee,kind,priority,created_by)
    VALUES ('retrofit row','todo','dev2','standard','high','main');" >/dev/null
_ri=$(db "SELECT ident FROM tasks ORDER BY id DESC LIMIT 1;")
_rid=$(db "SELECT id FROM tasks ORDER BY id DESC LIMIT 1;")
cmd_task_verifier "$_ri" quinn >/dev/null 2>&1
if _task_verify_grants "$_rid"; then
  ok_t "never: 'task verifier' retrofit grants the row a grader (it is a demand)"
else
  bad_t "never: 'task verifier' retrofit grants a grader" "the row stores verifier='$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${_rid};")' but the resolver still declines it"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAILN"
[[ "$FAILN" -eq 0 ]]
