#!/usr/bin/env bash
# DIVE-8875: a gate filed by a principal sentinel must not take the row.
#
# `task need` hands the row to the filer (assignee=actor). Under root or cron
# with no --from the actor is the `cli` sentinel, and `--from=council` makes it
# `council`. Nothing dispatches a sentinel (DIVE-3344), so the heartbeat's own
# [task-budget] gate left the maker's row on `cli` and a "keep going" answer
# resumed nothing (teal-fox canary, DIVE-1366 on 2026-11-19).
#
# S1-S3 go red on the pre-fix tree. N1-N2 pin the behaviour that must not move:
# a real lane filing still takes the row (DIVE-891 owner-of-record), and the
# resume ping still goes to that lane. The DIVE-2624 and DIVE-3097 arms have
# their own harnesses (gate_filing_preserves_handoff_unit.sh,
# task_self_grade_writers_unit.sh).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
as_agent() { local _w="$1"; shift; ( actor_seam_as "$_w"; "$@" ); }
SRC=src
TMP="$(mktemp -d /tmp/gate-sentinel-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
jf()    { jq -r "$1" 2>/dev/null; }

tasks_db_init

# P0 — the seam really makes root an unattributed `cli` caller. Without this,
# every arm below could pass on a filer that was never the sentinel.
[[ "$( actor_seam_as root; task_actor )" == "cli" ]] \
  && ok_t "P0 root resolves to the cli sentinel" \
  || bad_t "P0 seam" "root did not resolve to cli"

# A maker's row, started, the shape [task-budget] gates.
mk_row() {
  local out id
  out=$(as_agent maker cmd_task_add --assignee=maker --body="build it" -- "$1" 2>"$TMP/err")
  id=$(printf '%s' "$out" | jf '.data.id')
  as_agent maker cmd_task_start "$id" >/dev/null 2>&1
  printf '%s' "$id"
}
row_state() { db "SELECT status||'|'||COALESCE(assignee,'')||'|'||COALESCE(need_type,'')||'|'||COALESCE(gate_filed_by,'') FROM tasks WHERE id=$1;"; }

# S1 — root files a gate with no --from (the heartbeat's [task-budget] call).
s1=$(mk_row "budget gate by root")
as_agent root cmd_task_need "$s1" --type=decision --tier=1 \
  --ask="Should this keep going on a bigger allowance, or stop here?" \
  --options="keep going|stop here" --recommend="stop here" >/dev/null 2>"$TMP/err"
st1=$(row_state "$s1")
[[ "$st1" == "blocked|maker|decision|cli" ]] \
  && ok_t "S1 root gate keeps the maker as holder, gate set, filer recorded as cli" \
  || bad_t "S1 root gate" "got=$st1 want=blocked|maker|decision|cli err=$(head -c 300 "$TMP/err")"

# S2 — "keep going" resumes the maker, not the sentinel.
ans=$(as_agent root cmd_task_answer "$s1" --value="keep going" 2>"$TMP/err")
own=$(printf '%s' "$ans" | jf '.data.owner')
asg=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=$s1;")
[[ "$own" == "maker" && "$asg" == "maker" ]] \
  && ok_t "S2 answer on a cli-filed gate resumes the maker" \
  || bad_t "S2 resume target" "owner=$own assignee=$asg ans=$ans err=$(head -c 300 "$TMP/err")"

# S3 — same with --from=council.
s3=$(mk_row "gate from council")
as_agent root cmd_task_need "$s3" --from=council --type=decision --tier=1 \
  --ask="Ship it now, or hold it until Monday?" \
  --options="ship now|hold until monday" --recommend="ship now" >/dev/null 2>"$TMP/err"
st3=$(row_state "$s3")
[[ "$st3" == "blocked|maker|decision|council" ]] \
  && ok_t "S3 --from=council gate keeps the maker as holder" \
  || bad_t "S3 council gate" "got=$st3 want=blocked|maker|decision|council err=$(head -c 300 "$TMP/err")"

# N1 — negative control: a real lane (not the verifier) still takes the row.
n1=$(mk_row "gate by a real lane")
as_agent other cmd_task_need "$n1" --type=decision --tier=1 \
  --ask="Use the blue colour, or the red one?" \
  --options="blue|red" --recommend="blue" >/dev/null 2>"$TMP/err"
nt1=$(row_state "$n1")
[[ "$nt1" == "blocked|other|decision|other" ]] \
  && ok_t "N1 a lane's gate still moves the row to that lane" \
  || bad_t "N1 lane gate" "got=$nt1 want=blocked|other|decision|other"

# N2 — and its answer still pings that lane.
ans2=$(as_agent other cmd_task_answer "$n1" --value="blue" 2>"$TMP/err")
[[ "$(printf '%s' "$ans2" | jf '.data.owner')" == "other" ]] \
  && ok_t "N2 answer on a lane-filed gate still resumes the filer" \
  || bad_t "N2 resume target" "$ans2"

# N3 — the sentinel arm never invents a holder: a row with no assignee filed by
# root keeps the old behaviour (owner-of-record = filer).
n3out=$(as_agent maker cmd_task_add --body="unowned" -- "no holder" 2>"$TMP/err")
n3=$(printf '%s' "$n3out" | jf '.data.id')
as_agent root cmd_task_need "$n3" --type=decision --tier=1 \
  --ask="Keep this idea, or drop it?" \
  --options="keep it|drop it" --recommend="keep it" >/dev/null 2>"$TMP/err"
nt3=$(db "SELECT COALESCE(need_type,'') FROM tasks WHERE id=$n3;")
[[ "$nt3" == "decision" ]] \
  && ok_t "N3 a root gate on an unassigned row still files" \
  || bad_t "N3 unassigned row" "need_type=$nt3 err=$(head -c 300 "$TMP/err")"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
