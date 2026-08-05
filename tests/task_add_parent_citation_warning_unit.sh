#!/usr/bin/env bash
# TIER: pr
# DIVE-2449 regression harness. A numbered follow-up coordinate in a title is
# not a parent edge. `task add` must warn when --parent is absent, name an open
# row carrying the same coordinate, and stay quiet for prose-only mentions and
# explicit parent links.
set -uo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
SRC="${DIVE_TEST_SRC:-$ROOT/src}"
TMP="$(mktemp -d /tmp/task-add-parent-citation.XXXXXX)"

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
mkdir -p "$TASKS_DIR"
# shellcheck disable=SC2034
FIVE_VERIFY_DEFAULT=0
# shellcheck disable=SC2034
FIVE_FILING_CAP=0
set +e

PASS=0
FAIL=0
ok_t()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { [[ "$1" == *"$2"* ]]; }
jf()    { jq -r "$1" 2>/dev/null; }

run_add() {
  local tag="$1"; shift
  # shellcheck disable=SC2034
  ( JSON_MODE=1; cmd_task_add "$@" ) >"$TMP/$tag.out" 2>"$TMP/$tag.err"
}

tasks_db_init
# Use the exact live coordinates from the task's grading example, but only in
# this throwaway DB. Explicit idents bypass the normal counter trigger and make
# the assertion say what the product warning must say.
db "INSERT INTO tasks (ident,title,status,priority,created_by,project_key,kind)
    VALUES ('DIVE-2382','parent epic','todo','medium','main','dive','standard');"
parent_id=$(db "SELECT id FROM tasks WHERE ident='DIVE-2382';")
db "INSERT INTO tasks (ident,title,status,priority,created_by,project_key,kind)
    VALUES ('DIVE-2416','gates: render the tier requirement (DIVE-2382 fix #3)','todo','medium','main','dive','standard'),
           ('DIVE-2417','closed duplicate (DIVE-2382 fix #3)','cancelled','medium','main','dive','standard');"

# T1 — the reported shape: warn, name the cited epic, and name the OPEN match.
run_add t1 --assignee=dev -- 'gates: render the tier requirement (DIVE-2382 fix #3)'
t1_rc=$?
t1_out=$(<"$TMP/t1.out")
t1_err=$(<"$TMP/t1.err")
t1_id=$(printf '%s' "$t1_out" | jf '.data.id')
if (( t1_rc == 0 )) && [[ "$(printf '%s' "$t1_out" | jf '.data.parentLinkWarning')" == "true" ]]; then
  ok_t "T1a numbered follow-up without --parent is visibly classified"
else
  bad_t "T1a numbered follow-up without --parent is visibly classified" "rc=$t1_rc out=$t1_out err=$t1_err"
fi
if has "$t1_err" 'DIVE-2382 fix #3 without --parent' && has "$t1_err" 'DIVE-2416'; then
  ok_t "T1b stderr warning names the cited epic and existing open row DIVE-2416"
else
  bad_t "T1b stderr warning names the cited epic and existing open row DIVE-2416" "$t1_err"
fi
if [[ "$(printf '%s' "$t1_out" | jf '.data.openTitleMatches | join(",")')" == "DIVE-2416" ]]; then
  ok_t "T1c JSON names only the open same-token match"
else
  bad_t "T1c JSON names only the open same-token match" "$t1_out"
fi
if [[ "$(db "SELECT COALESCE(parent_id,'') FROM tasks WHERE id=${t1_id};")" == "" ]]; then
  ok_t "T1d advisory does not invent a parent edge"
else
  bad_t "T1d advisory does not invent a parent edge" "task_id=$t1_id"
fi

# T2 — the false-positive boundary from the ticket: a prose mention is quiet.
run_add t2 --assignee=dev -- 'ordinary follow-up to DIVE-2382'
t2_rc=$?
t2_out=$(<"$TMP/t2.out")
t2_err=$(<"$TMP/t2.err")
if (( t2_rc == 0 )) \
   && [[ "$(printf '%s' "$t2_out" | jf '.data.parentLinkWarning')" == "false" ]] \
   && ! has "$t2_err" 'without --parent'; then
  ok_t "T2 prose-only DIVE mention does not warn"
else
  bad_t "T2 prose-only DIVE mention does not warn" "rc=$t2_rc out=$t2_out err=$t2_err"
fi

# T3 — an explicit parent is authoritative and suppresses the prose advisory.
run_add t3 --assignee=dev --parent=DIVE-2382 -- 'linked child (DIVE-2382 fix #3)'
t3_rc=$?
t3_out=$(<"$TMP/t3.out")
t3_err=$(<"$TMP/t3.err")
t3_id=$(printf '%s' "$t3_out" | jf '.data.id')
if (( t3_rc == 0 )) \
   && [[ "$(printf '%s' "$t3_out" | jf '.data.parentLinkWarning')" == "false" ]] \
   && [[ "$(db "SELECT parent_id FROM tasks WHERE id=${t3_id};")" == "$parent_id" ]] \
   && ! has "$t3_err" 'without --parent'; then
  ok_t "T3 explicit --parent creates the edge and does not warn"
else
  bad_t "T3 explicit --parent creates the edge and does not warn" "rc=$t3_rc out=$t3_out err=$t3_err"
fi

# T4 — the complete narrow vocabulary, including an optional hash marker.
parse_bad=""
for sample in 'orphan #7' 'part 8' 'item #9'; do
  _task_numbered_followup_parse "DIVE-2382 $sample"
  [[ "$_TASK_FOLLOWUP_IDENT" == "DIVE-2382" && -n "$_TASK_FOLLOWUP_KIND" && -n "$_TASK_FOLLOWUP_NUMBER" ]] \
    || parse_bad+="${parse_bad:+,}$sample"
done
if [[ -z "$parse_bad" ]]; then
  ok_t "T4 fix/orphan/part/item numbered vocabulary is recognized"
else
  bad_t "T4 fix/orphan/part/item numbered vocabulary is recognized" "$parse_bad"
fi

# T5 — a numbered coordinate to a nonexistent ident is still ordinary prose;
# the rule is about missing linkage to an EXISTING board object.
run_add t5 --assignee=dev -- 'DIVE-999999 item #2'
t5_rc=$?
t5_out=$(<"$TMP/t5.out")
t5_err=$(<"$TMP/t5.err")
if (( t5_rc == 0 )) \
   && [[ "$(printf '%s' "$t5_out" | jf '.data.parentLinkWarning')" == "false" ]] \
   && ! has "$t5_err" 'without --parent'; then
  ok_t "T5 nonexistent cited ident does not warn"
else
  bad_t "T5 nonexistent cited ident does not warn" "rc=$t5_rc out=$t5_out err=$t5_err"
fi

# T6 — the numeric coordinate must end at a real boundary, not inside a word.
run_add t6 --assignee=dev -- 'documentation for DIVE-2382 part 3draft'
t6_rc=$?
t6_out=$(<"$TMP/t6.out")
t6_err=$(<"$TMP/t6.err")
if (( t6_rc == 0 )) \
   && [[ "$(printf '%s' "$t6_out" | jf '.data.parentLinkWarning')" == "false" ]] \
   && ! has "$t6_err" 'without --parent'; then
  ok_t "T6 alphanumeric suffix is not misread as a numbered coordinate"
else
  bad_t "T6 alphanumeric suffix is not misread as a numbered coordinate" "rc=$t6_rc out=$t6_out err=$t6_err"
fi

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
