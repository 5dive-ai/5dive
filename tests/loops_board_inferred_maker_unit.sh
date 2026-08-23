#!/usr/bin/env bash
# DIVE-2489 — the `task loops` maker column must not render an INFERRED maker
# identically to a measured one.
#
# The defect: `COALESCE(maker_agent, assignee) AS maker`. After a maker→verifier
# handoff the assignee IS the verifier, so a row that never stamped a maker
# rendered maker == verifier — visually identical to a row whose maker genuinely
# graded their own work. Those are different facts and one of them is a
# governance claim (marketing nearly published a self-graded figure off it).
#
# Isolation: source src/ libs, point STATE_DIR at a throwaway temp dir — the live
# shared tasks.db is NEVER touched. Rows are seeded with direct INSERTs because
# this grades the BOARD's rendering, not the delivery path that stamps the field;
# seeding through `task done` could not produce the never-stamped row at all.
# Run: bash tests/loops_board_inferred_maker_unit.sh  (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NOTE the absence of 2>/dev/null —
# the helper's stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/loops-inferred-maker.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh; do
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

# Three rows that the OLD column could not tell apart, plus a control.
#   T-INFER  never stamped a maker, delivered so assignee == verifier  -> INFERRED
#   T-REAL   maker_agent recorded and it EQUALS the verifier           -> a real self-grade
#   T-CLEAN  maker_agent recorded, different from the verifier         -> the normal case
#   T-NONE   never stamped a maker AND unassigned                      -> nothing to infer from
db "INSERT INTO tasks (ident,title,status,assignee,verifier,maker_agent,iteration,created_at)
    VALUES ('T-INFER','inferred maker','todo','grader','grader',NULL,1,datetime('now'));"
db "INSERT INTO tasks (ident,title,status,assignee,verifier,maker_agent,iteration,created_at)
    VALUES ('T-REAL','measured self-grade','todo','grader','grader','grader',1,datetime('now'));"
db "INSERT INTO tasks (ident,title,status,assignee,verifier,maker_agent,iteration,created_at)
    VALUES ('T-CLEAN','normal loop','todo','grader','grader','builder',1,datetime('now'));"
db "INSERT INTO tasks (ident,title,status,assignee,verifier,maker_agent,iteration,created_at)
    VALUES ('T-NONE','no maker, no holder','todo',NULL,'grader',NULL,1,datetime('now'));"

jmaker() { printf '%s' "$1" | jq -r --arg i "$2" '.data.loops[]|select(.ident==$i)|.maker|tostring'; }
jfield() { printf '%s' "$1" | jq -r --arg i "$2" --arg f "$3" '.data.loops[]|select(.ident==$i)|.[$f]|tostring'; }

# ---------------------------------------------------------------- JSON board
JSON_MODE=1
out=$( cmd_task_loops )

# T1 (the defect): an unstamped maker is NOT a name.
m_inf=$(jmaker "$out" T-INFER)
[[ "$m_inf" == "null" ]] \
  && ok_t "JSON: never-stamped maker renders as null, not the verifier's name" \
  || bad_t "JSON inferred maker" "expected null, got '$m_inf'"

# T2 (the positive control that makes T1 mean something): a REAL self-grade is
# still reported. A fix that merely blanked the column would pass T1 and be
# useless — this is the row the board exists to surface.
m_real=$(jmaker "$out" T-REAL)
v_real=$(jfield "$out" T-REAL verifier)
[[ "$m_real" == "grader" && "$v_real" == "grader" ]] \
  && ok_t "JSON: a MEASURED maker==verifier row still reports maker=verifier (real self-grade survives)" \
  || bad_t "JSON measured self-grade" "maker='$m_real' verifier='$v_real'"

# T3: the two rows are now DISTINGUISHABLE — the whole point of the row.
[[ "$m_inf" != "$m_real" ]] \
  && ok_t "JSON: inferred and measured no longer render as the same value" \
  || bad_t "JSON distinguishability" "both rendered '$m_inf'"

# T4: no information was lost — the assignee is still carried as `holder`.
h_inf=$(jfield "$out" T-INFER holder)
[[ "$h_inf" == "grader" ]] \
  && ok_t "JSON: holder still carries the assignee the fallback used to leak into maker" \
  || bad_t "JSON holder" "expected 'grader', got '$h_inf'"

# T5: the ordinary case is untouched.
m_cl=$(jmaker "$out" T-CLEAN)
[[ "$m_cl" == "builder" ]] \
  && ok_t "JSON: a normal maker!=verifier row is unchanged" || bad_t "JSON clean row" "$m_cl"

# ---------------------------------------------------------------- text board
JSON_MODE=0
tout=$( cmd_task_loops 2>&1 )
row() { printf '%s' "$tout" | grep -F "$1 " | head -1; }

# T6: the text board MARKS the inference rather than printing a bare name.
r=$(row T-INFER)
[[ "$r" == *"holder:grader"* ]] \
  && ok_t "text: inferred maker renders marked as 'holder:grader', never a bare name" \
  || bad_t "text inferred maker" "$r"

# T7: and the marked cell is not confusable with the measured one.
r_real=$(row T-REAL)
[[ "$r_real" != *"holder:"* ]] \
  && ok_t "text: a measured maker carries no holder: marker" || bad_t "text measured row" "$r_real"

# T8: neither maker nor assignee -> a plain absence, not an empty cell.
r_none=$(row T-NONE)
[[ "$r_none" == *"-"* && "$r_none" != *"holder:"* ]] \
  && ok_t "text: no maker and no assignee renders '-'" || bad_t "text empty row" "$r_none"

# T9 (negative control on the harness itself): the OLD expression, run against
# this same seed, MUST fail T1 — otherwise these rows do not reproduce the defect
# and every green above is vacuous.
old=$(db "SELECT COALESCE(maker_agent, assignee) FROM tasks WHERE ident='T-INFER';")
oldreal=$(db "SELECT COALESCE(maker_agent, assignee) FROM tasks WHERE ident='T-REAL';")
[[ "$old" == "grader" && "$old" == "$oldreal" ]] \
  && ok_t "negative control: the pre-fix expression DOES collapse both rows to 'grader' on this seed" \
  || bad_t "negative control" "old inferred='$old' old measured='$oldreal' — seed does not reproduce the defect"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
