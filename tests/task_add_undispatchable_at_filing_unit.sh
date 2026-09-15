#!/usr/bin/env bash
# TIER: core
# DIVE-4555 — `task add` must not accept a row nothing will ever dispatch.
#
# THE MEASUREMENT THIS GRADES (teal-fox, 2026-09-15): 53 open rows, 41 of which
# `task doctor` calls undispatchable, and 14 todo rows with no assignee at all —
# filed by 8 different seats over 8 weeks with a plain `task add`, each of which
# printed "OK — created". The board had NINE org roots and none tagged, so every
# tier of `_task_resolve_coordinator` missed and the DIVE-333 default resolved to
# nothing. Nothing wakes an unassigned row: each was autonomy zero on arrival.
#
# TWO defects, and T4 is the one a reader will miss. `_task_require_lane` runs the
# heartbeat-off warning on what the CALLER TYPED; the DIVE-333 default resolved
# three lines later is the PARALLEL path and carried no check at all. Same rail,
# two columns, one guarded — so auto-coordinating onto a heartbeat-off lead was
# silent, and `task doctor` called the result dead-lane after the fact.
#
# T3 is the degrade arm and it is load-bearing: an EMPTY org chart is a fresh box
# or a unit fixture, not a misconfigured fleet. Turning "I could not measure"
# into a refusal would break every harness that files a row before building a
# chart, which is the failure direction this codebase's lane guards already
# refuse (see _task_doctor_lane_wakeable's rc=2).
# Run: bash tests/task_add_undispatchable_at_filing_unit.sh (no root, no network)
set -uo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
SRC="${DIVE_TEST_SRC:-$ROOT/src}"
TMP="$(mktemp -d /tmp/task-add-undispatchable.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP/state"
TASKS_DIR="$STATE_DIR/tasks"
# shellcheck disable=SC2034
TASKS_DB="$TASKS_DIR/tasks.db"
REG="$STATE_DIR/agents.json"
mkdir -p "$TASKS_DIR"
# shellcheck disable=SC2034
FIVE_VERIFY_DEFAULT=0
# shellcheck disable=SC2034
FIVE_FILING_CAP=0
# shellcheck disable=SC2034
ACTOR_BOARD="filer"
set +e

PASS=0
FAIL=0
ok_t()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { [[ "$1" == *"$2"* ]]; }

set_reg() { printf '%s' "$1" >"$REG"; }
# Every add runs in its own subshell: _TASK_ROSTER_STATE is memoised per process,
# so an arm that re-writes agents.json would otherwise grade the PREVIOUS arm's
# roster. The subshell is the isolation, not a style choice.
run_add() {
  local tag="$1"; shift
  # --from is passed explicitly: ACTOR_BOARD resolves against the HOST seat this
  # harness happens to run on, and the routing arms grade WHOSE manager was used.
  ( cmd_task_add --from=filer "$@" ) >"$TMP/$tag.out" 2>"$TMP/$tag.err"
}
chart_reset() { db "DELETE FROM agents_org;"; }

tasks_db_init

# Two live seats and a lead whose heartbeat is OFF — the teal-fox shape in
# miniature. Reserved-fake names only; nothing here names a real seat.
set_reg '{"agents":{"filer":{"type":"claude","heartbeat":{"enabled":true}},
                    "boss":{"type":"claude","heartbeat":{"enabled":true}},
                    "sleeper":{"type":"claude","heartbeat":{"enabled":false}}}}'

# ---------------------------------------------------------------------------
# T1 — TWO org roots, none tagged coordinator, filer has no manager. Every tier
# of the resolver misses and there is nowhere to route: REFUSE, and name the fix.
chart_reset
db "INSERT INTO agents_org (name,role) VALUES ('boss','AI CEO'),('sleeper','QA / testing');"
run_add t1 -- 'a row nobody would ever dispatch'
t1_rc=$?
t1_err=$(<"$TMP/t1.err")
if (( t1_rc != 0 )); then ok_t "T1a ownerless add on a chart with no coordinator is REFUSED (rc=$t1_rc)"
else bad_t "T1a ownerless add was accepted" "rc=0; err=$t1_err"; fi
if has "$t1_err" "org set" && has "$t1_err" "coordinator"; then
  ok_t "T1b the refusal names the fix (5dive org set … coordinator)"
else bad_t "T1b refusal does not name the fix" "$t1_err"; fi
if has "$t1_err" "nothing wakes an unassigned row"; then
  ok_t "T1c the refusal says WHY (nothing wakes an unassigned row)"
else bad_t "T1c refusal does not say why" "$t1_err"; fi
if [[ "$(db "SELECT COUNT(*) FROM tasks WHERE title='a row nobody would ever dispatch';")" == "0" ]]; then
  ok_t "T1d the refused row was not written to the board"
else bad_t "T1d a refused add still created the row" ""; fi

# ---------------------------------------------------------------------------
# T2 — same untagged chart, but the filer HAS a manager who is a real lane.
# ROUTE rather than refuse, and say so where the filer is looking.
chart_reset
db "INSERT INTO agents_org (name,role) VALUES ('boss','AI CEO'),('sleeper','QA / testing');
    INSERT INTO agents_org (name,reports_to) VALUES ('filer','boss');"
run_add t2 -- 'routed to the manager'
t2_rc=$?
t2_out=$(<"$TMP/t2.out"); t2_err=$(<"$TMP/t2.err")
t2_asg=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE title='routed to the manager';")
if (( t2_rc == 0 )) && [[ "$t2_asg" == "boss" ]]; then
  ok_t "T2a an ownerless row routes to the filer's manager instead of being refused"
else bad_t "T2a did not route to the manager" "rc=$t2_rc assignee='$t2_asg' err=$t2_err"; fi
if has "$t2_err" "manager 'boss'" ; then
  ok_t "T2b the route is announced, not silent"
else bad_t "T2b the route was silent" "$t2_err"; fi
if has "$t2_out" "manager of filer: boss"; then
  ok_t "T2c the created line names WHY it landed there"
else bad_t "T2c created line does not name the route" "$t2_out"; fi

# ---------------------------------------------------------------------------
# T7 — THE MATERIALIZED EXEMPTION (ops review finding on the delivery).
#
# `--materialized` does NOT change $kind (it stays `standard` unless --recurring),
# so the T1 refusal reached every internal writer that files an anchor row. Three
# in tree do it with no resolvable assignee — cmd_objective's re-plan anchor,
# cmd_goal's anchor when $planner is empty, and cmd_proof (--from=proof, a name
# that is not in agents_org, so the manager route misses too). On the T1 chart
# that is `objective` and `goal` losing their anchor and `proof publish`
# refusing, i.e. this row's fix breaking three unrelated verbs on exactly the
# board it ships for.
#
# Both sibling filing guards in the same function already carry `-z
# "$materialized"` for the reason written above each of them: a refusal mid-batch
# leaves a HALF-MATERIALIZED plan, some children filed and some not, with a loop
# driver already waiting on a short child list.
#
# Deliberately NOT exempted: the route and the heartbeat-off warning. A warning
# cannot abort a batch, and an anchor owned by the filer's manager beats an
# unowned one — graded by T8 below, so "exempt" cannot quietly become "skip the
# whole block".
chart_reset
db "INSERT INTO agents_org (name,role) VALUES ('boss','AI CEO'),('sleeper','QA / testing');"
run_add t7 --materialized -- 'an internal writers anchor row'
t7_rc=$?
t7_err=$(<"$TMP/t7.err")
t7_n=$(db "SELECT COUNT(*) FROM tasks WHERE title='an internal writers anchor row';")
if (( t7_rc == 0 )) && [[ "$t7_n" == "1" ]]; then
  ok_t "T7a a --materialized anchor is filed, not refused, on an unroutable chart"
else bad_t "T7a a --materialized anchor was refused (aborts a whole materialization)" "rc=$t7_rc n=$t7_n err=$t7_err"; fi
if ! has "$t7_err" "NO OWNER"; then
  ok_t "T7b and the refusal text is not printed on that path either"
else bad_t "T7b the refusal fired on the materialized path" "$t7_err"; fi

# CONTROL for T7. The SAME fixture without --materialized must still refuse, or
# T7 is graded against a guard that no longer fires for anyone.
run_add t7c -- 'the same row without the materialized flag'
t7c_rc=$?
t7c_n=$(db "SELECT COUNT(*) FROM tasks WHERE title='the same row without the materialized flag';")
if (( t7c_rc != 0 )) && [[ "$t7c_n" == "0" ]]; then
  ok_t "T7c CONTROL: the same add WITHOUT --materialized is still refused"
else bad_t "T7c the exemption disabled the guard for everyone" "rc=$t7c_rc n=$t7c_n"; fi

# ---------------------------------------------------------------------------
# T8 — the exemption is scoped to the `fail`, not to the block. On a chart where
# the filer HAS a manager (the T2 shape), a materialized anchor must still ROUTE
# and still be announced: an owned anchor is strictly better than an unowned one,
# and nothing about routing can abort a batch.
chart_reset
db "INSERT INTO agents_org (name,role) VALUES ('boss','AI CEO'),('sleeper','QA / testing');
    INSERT INTO agents_org (name,reports_to) VALUES ('filer','boss');"
run_add t8 --materialized -- 'a materialized anchor with a manager to route to'
t8_rc=$?
t8_asg=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE title='a materialized anchor with a manager to route to';")
if (( t8_rc == 0 )) && [[ "$t8_asg" == "boss" ]]; then
  ok_t "T8 a materialized anchor still ROUTES to the manager (exemption covers the fail only)"
else bad_t "T8 materialized anchor was not routed" "rc=$t8_rc assignee='$t8_asg'"; fi

# ---------------------------------------------------------------------------
# T3 — DEGRADE ARM. An EMPTY chart is a fresh box or a fixture, not a broken
# fleet: still accepted, unassigned, no refusal. A guard that cannot distinguish
# the two would refuse every add on a box that has not been set up yet.
chart_reset
run_add t3 -- 'fresh box with no chart at all'
t3_rc=$?
t3_asg=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE title='fresh box with no chart at all';")
if (( t3_rc == 0 )) && [[ -z "$t3_asg" ]]; then
  ok_t "T3 an empty org chart still accepts an unassigned row (could-not-measure is not a refusal)"
else bad_t "T3 empty chart refused or auto-assigned" "rc=$t3_rc assignee='$t3_asg'"; fi

# ---------------------------------------------------------------------------
# T4 — THE PARALLEL-PATH ARM. A LONE root resolves as coordinator, so the row is
# accepted and auto-coordinated — onto a seat whose heartbeat is off. Before this
# change the warning fired only for an explicit --assignee, so this landed silent
# and `task doctor` called it dead-lane afterwards.
chart_reset
db "INSERT INTO agents_org (name,role) VALUES ('sleeper','QA / testing');"
run_add t4 -- 'auto-coordinated onto a sleeping seat'
t4_rc=$?
t4_err=$(<"$TMP/t4.err")
t4_asg=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE title='auto-coordinated onto a sleeping seat';")
if (( t4_rc == 0 )) && [[ "$t4_asg" == "sleeper" ]]; then
  ok_t "T4a a lone root still resolves as the default owner (DIVE-333 behaviour preserved)"
else bad_t "T4a default coordination changed" "rc=$t4_rc assignee='$t4_asg'"; fi
if has "$t4_err" "NOTHING WAKES"; then
  ok_t "T4b the DEFAULT owner gets the heartbeat-off warning the explicit flag already got"
else bad_t "T4b the derived default was never checked for a live lane" "$t4_err"; fi

# ---------------------------------------------------------------------------
# T5 — NEGATIVE CONTROL. Same path, a coordinator whose heartbeat is ON: silence.
# Without this arm T4 would pass on a warning that fires unconditionally.
chart_reset
db "INSERT INTO agents_org (name,role) VALUES ('boss','AI CEO');"
run_add t5 -- 'auto-coordinated onto a live seat'
t5_err=$(<"$TMP/t5.err")
t5_asg=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE title='auto-coordinated onto a live seat';")
if [[ "$t5_asg" == "boss" ]] && ! has "$t5_err" "NOTHING WAKES"; then
  ok_t "T5 a live default owner draws no warning (the T4 arm discriminates)"
else bad_t "T5 warning fired on a live lane" "assignee='$t5_asg' err=$t5_err"; fi

# ---------------------------------------------------------------------------
# T6 — the same fact said one step earlier, to the person who can fix it for
# good: `org set` is the only writer of agents_org (no init/company wizard
# touches it), so it is where "this chart still routes nowhere" belongs.
chart_reset
# `org set` is root-only (DIVE-2124). The arm below grades the COORDINATOR
# WARNING, not that authorization — which tests/org_write_authz_unit.sh already
# grades, and grades by asserting the check is still textually present in each
# write verb. Standing in for root here is the same stand-in that harness uses
# for its own setup, and it is restored immediately after.
_real_require_root=$(declare -f require_root)
require_root() { :; }
( cmd_org_set boss --role='AI CEO' ) >"$TMP/t6a.out" 2>"$TMP/t6a.err"
( cmd_org_set sleeper --role='QA / testing' ) >"$TMP/t6b.out" 2>"$TMP/t6b.err"
t6b_err=$(<"$TMP/t6b.err")
if has "$t6b_err" "resolves NO coordinator"; then
  ok_t "T6a a chart left with no resolvable coordinator says so at the moment it is built"
else bad_t "T6a org set was silent about an unroutable chart" "$t6b_err"; fi
( cmd_org_set boss --role='AI CEO — fleet coordinator' ) >"$TMP/t6c.out" 2>"$TMP/t6c.err"
t6c_err=$(<"$TMP/t6c.err")
if ! has "$t6c_err" "resolves NO coordinator"; then
  ok_t "T6b once a coordinator is tagged the warning stops (not an unconditional nag)"
else bad_t "T6b warning fired on a chart that DOES resolve a coordinator" "$t6c_err"; fi

eval "$_real_require_root"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
