#!/usr/bin/env bash
# DIVE-8700 isolated unit harness — `task show` on a CLOSED row says what
# happened, not what filing promised.
#
# The defect (exact-swallow 2026-11-18, sig 4e4e25019237; teal-fox 2026-10-12,
# sig 668472907a5e): a row filed `--review=seat:researcher` on a
# verify=delivered-only box, closed by `task done` with no delivery bound, still
# printed "review: seat:researcher — graded by researcher in its own session"
# and "verify: … — no grader yet". No grade ever ran. A seat nearly deployed on it.
#
# Arms:
#   1. closed, ungraded seat-review row -> "not graded (…no delivery bound)",
#      never "graded by"; verify line says "closed without a grader".
#   2. same for --review=check (the 10-12 shape) and temp.
#   3. negative controls: a GRADED closed row still prints the grader; an OPEN
#      row prints the filing-time cost note unchanged; `none` is unchanged; a
#      closed row that had a delivery but no verdict says "no grade recorded",
#      never "not graded" (a verifier's prose-PASS close writes no verdict).
#   4. MUTATION: the shipping helper is cut back to the pre-fix behaviour
#      (always return 1) and arm 1 must go red.
#
# Same isolation contract as the other task harnesses: src/ sourced directly,
# STATE_DIR on a throwaway temp dir, BOX_CONFIG inside it.
# Run: bash tests/task_show_closed_review_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-show-closed-review.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/verify_policy.sh lib/tasks_db.sh \
         lib/actor.sh cmd_task.sh  cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
BOX_CONFIG="$TMP/box.json"
JSON_MODE=0
FIVE_TASK_SHOW_QUEUE=0
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAILN=0
ok_t()  { PASS=$((PASS+1));  printf 'ok   - %s\n' "$1"; }
bad_t() { FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init >/dev/null 2>&1
_task_default_verifier() { printf 'grader'; }
_task_require_lane() { return 0; }
printf '{"verify":"delivered-only"}\n' > "$BOX_CONFIG"

# new_row <label> [flags...] -> ident
new_row() {
  local label="$1"; shift
  local out
  out=$(JSON_MODE=1 cmd_task_add "$label $RANDOM" --assignee=dev2 --from=main --priority=high \
          --body="a real code row" "$@" 2>/dev/null)
  jq -r '.data.ident // empty' <<<"$out" 2>/dev/null
}
# close_row <ident> <status> — the store state `task done`/`task cancel` leaves
# on an unbound delivered-only row. Written directly so the arm grades the
# RENDER, not the close verb's own rails.
close_row() { db "UPDATE tasks SET status=$(sqlq "$2"), done_at=datetime('now') WHERE ident=$(sqlq "$1");"; }
line_of() { grep -m1 "^$2:" <<<"$(cmd_task_show "$1" 2>/dev/null)"; }

check_closed_ungraded() { # <label> <ident> <status> <mode-prefix>
  local label="$1" i="$2" st="$3" pre="$4" r v
  [[ -n "$i" ]] || { bad_t "$label" "row was not created"; return; }
  close_row "$i" "$st"
  r=$(line_of "$i" review); v=$(line_of "$i" verify)
  [[ "$r" == "review: ${pre}"*"not graded ("*"no delivery bound)"* && "$r" != *"graded by"* \
     && "$r" != *"grader session"* && "$r" != *"per delivery"* ]] \
    && ok_t "$label: review line says not graded, with the reason" \
    || bad_t "$label: review line says not graded" "got: $r"
  [[ "$v" == *"closed without a grader"* && "$v" != *"no grader yet"* ]] \
    && ok_t "$label: verify line says closed without a grader" \
    || bad_t "$label: verify line says closed without a grader" "got: $v"
}

echo "── 1. closed, ungraded seat-review row (DIVE-777 shape) ──────────"
I_SEAT=$(new_row "seat row" --review=seat:researcher)
check_closed_ungraded "seat:researcher, task done" "$I_SEAT" done "seat:researcher"

echo "── 2. same for check and temp ────────────────────────────────────"
I_CHK=$(new_row "check row" --review=check --verify="npm test" --mutant="sed -i s/expect/xx/ test.js")
check_closed_ungraded "check, task done" "$I_CHK" done "check"
I_TMP=$(new_row "temp row" --review=temp)
check_closed_ungraded "temp, task cancel" "$I_TMP" cancelled "temp"
r=$(line_of "$I_TMP" review)
[[ "$r" == *"task cancel"* ]] && ok_t "a cancelled row names the cancel, not task done" \
  || bad_t "a cancelled row names the cancel" "got: $r"

echo "── 3. negative controls ──────────────────────────────────────────"
# Graded closed row: the grader still prints.
I_GRD=$(new_row "graded row" --review=seat:researcher)
db "UPDATE tasks SET delivery_ref='https://github.com/x/y/pull/1', graded_verdict='pass',
       graded_verdict_at=datetime('now'), graded_at=datetime('now'), graded_by='researcher'
     WHERE ident=$(sqlq "$I_GRD");"
close_row "$I_GRD" done
r=$(line_of "$I_GRD" review)
[[ "$r" == "review: seat:researcher — graded by researcher in its own session" ]] \
  && ok_t "a GRADED closed row still prints the grader" || bad_t "a graded row prints the grader" "got: $r"
# Legacy grade (graded_at, NULL verdict — pre-DIVE-3430) is still a grade.
I_LEG=$(new_row "legacy graded row" --review=temp)
db "UPDATE tasks SET graded_at=datetime('now'), graded_by='grader' WHERE ident=$(sqlq "$I_LEG");"
close_row "$I_LEG" done
r=$(line_of "$I_LEG" review)
[[ "$r" == *"one grader session per delivery"* ]] \
  && ok_t "a legacy graded_at with NULL verdict still counts as graded" || bad_t "legacy grade counts" "got: $r"
# Open row: filing-time cost note unchanged, verify line unchanged.
I_OPEN=$(new_row "open row" --review=seat:researcher)
r=$(line_of "$I_OPEN" review); v=$(line_of "$I_OPEN" verify)
[[ "$r" == "review: seat:researcher — graded by researcher in its own session" ]] \
  && ok_t "an OPEN row prints the filing-time cost note unchanged" || bad_t "open row unchanged" "got: $r"
# DIVE-9175: a NAMED seat binds on delivered-only without a delivery, so the open
# row says who grades it instead of promising a grader that arrives with a PR.
[[ "$v" == *"the reviewer named on this row grades it"* && "$v" != *"no grader yet"* ]] \
  && ok_t "an OPEN named-seat row says the named reviewer grades it (DIVE-9175)" || bad_t "open named-seat verify line" "got: $v"
# none: its cost note already says nobody grades it.
I_NONE=$(new_row "none row" --review=none)
close_row "$I_NONE" done
r=$(line_of "$I_NONE" review)
[[ "$r" == *'no grader — "task done" closes it outright'* ]] \
  && ok_t "a closed review=none row is unchanged" || bad_t "none unchanged" "got: $r"
# Delivered, closed, no verdict column: never claim "not graded".
I_DLV=$(new_row "delivered row" --review=seat:researcher)
db "UPDATE tasks SET delivery_ref='https://github.com/x/y/pull/2', handoff_delivered_at=datetime('now')
     WHERE ident=$(sqlq "$I_DLV");"
close_row "$I_DLV" done
r=$(line_of "$I_DLV" review)
[[ "$r" == *"no grade recorded"* && "$r" != *"not graded"* && "$r" != *"graded by"* ]] \
  && ok_t "a delivered close with no verdict says 'no grade recorded', not 'not graded'" \
  || bad_t "delivered close wording" "got: $r"

echo "── 4. mutation: the pre-fix behaviour goes red ───────────────────"
_real=$(declare -f review_mode_closed_note)
review_mode_closed_note() { return 1; }
r=$(line_of "$I_SEAT" review)
[[ "$r" == *"graded by researcher"* ]] \
  && ok_t "MUTATION DETECTED: with the helper cut, arm 1 prints the false 'graded by' line again" \
  || bad_t "MUTATION not detected" "got: $r"
eval "$_real"
r=$(line_of "$I_SEAT" review)
[[ "$r" == *"not graded"* ]] && ok_t "helper restored" || bad_t "helper restored" "got: $r"

echo
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAILN"
[[ $FAILN -eq 0 ]]
