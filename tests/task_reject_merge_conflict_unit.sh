#!/usr/bin/env bash
# DIVE-6753 — a merge-conflict bounce after a PASS does not spend an iteration.
#
# On 2026-10-22 three rows (DIVE-6716, -6729, -6717) each graded PASS, went
# CONFLICTING when a sibling merged first, and the merger's reject used up the
# last of max_iterations=2 and filed a keep-going / drop-it gate. The work had
# no defect; the cap counts quality rounds, and a rebase is not one.
#
#   M1  PASS -> merger `reject --merge-conflict` AT the cap -> the row is todo for
#       the maker, NO gate, and the cap is raised by the one iteration the
#       re-delivery will add. (Drop the flag and the same row gates: arm Q.)
#   M2  the re-delivery stays inside the cap, and a QUALITY reject after it still
#       gates — the cap keeps its purpose.
#   M3  --merge-conflict on a row with no PASS is refused, nothing written.
#   M4  ...and on a PASS recorded BEFORE the current delivery (it graded an older
#       head), refused.
#   M5  ...and from a seat that neither owes the merge nor graded it, refused.
#   Q   control: a plain reject at the cap on the same PASSed shape still gates.
#
# Run: bash tests/task_reject_merge_conflict_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src

TMP="$(mktemp -d /tmp/task-reject-merge-conflict-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh \
         cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1; mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
as() { local who="$1"; shift; ( actor_seam_as "${who}"; "$@" ) 2>"$TMP"/err; }

col_of()    { db "SELECT COALESCE($2,'') FROM tasks WHERE ident=$(sqlq "$1");"; }
events_of() { db "SELECT COUNT(*) FROM lifecycle_events WHERE ident=$(sqlq "$1") AND kind=$(sqlq "$2");"; }

MAKER_TEXT="MAKER RESULT: built it, 9/9 unit"
# A row delivered to its verifier (maker dev, verifier main), graded PASS at that
# delivery, merge owed by ops, and sitting AT the cap (iteration 1 of 1).
seed_passed() {
  local out id; out=$(JSON_MODE=1 cmd_task_add "$1" --assignee=dev --verifier=main --verify \
                        --accept="must do the thing" 2>"$TMP"/err)
  id=$(printf '%s' "$out" | jq -r '.data.ident // empty' 2>/dev/null)
  as dev cmd_task_done "$id" --result="$MAKER_TEXT" >/dev/null
  db "UPDATE tasks SET graded_verdict='pass', graded_verdict_at=datetime('now','+1 second'),
        graded_at=datetime('now','+1 second'), graded_by='main', merge_owner='ops',
        iteration=1, max_iterations=1 WHERE ident=$(sqlq "$id");"
  printf '%s' "$id"
}
FB="branch conflicts with main after a sibling merged FIX: rebase onto origin/main and re-deliver"

# --- Q: CONTROL first. The plain reject on this exact shape takes the cap branch,
# so M1's "no gate" is the flag's doing and not a fixture that never reaches the cap.
Q=$(seed_passed "Q a plain reject of a passed row at the cap")
as ops cmd_task_reject "$Q" --feedback="$FB" >/dev/null
[[ "$(col_of "$Q" need_type)" == "decision" ]] \
  && ok_t "Q control: a plain reject at the cap on a PASSed row still files the keep-going gate" \
  || bad_t "Q control" "need_type='$(col_of "$Q" need_type)' — the fixture never reaches the cap, so M1 would be vacuous"

# --- M1: the merger's bounce at the cap.
M=$(seed_passed "M a merge-conflict bounce after a pass")
out=$(as ops cmd_task_reject "$M" --feedback="$FB" --merge-conflict); rc=$?
(( rc == 0 )) && ok_t "M1 the merger's --merge-conflict bounce succeeds (rc=0)" \
  || bad_t "M1 rc" "rc=$rc $(cat "$TMP"/err)"
[[ "$(col_of "$M" status)" == "todo" && "$(col_of "$M" assignee)" == "dev" ]] \
  && ok_t "M1 the row is todo for the maker" \
  || bad_t "M1 not bounced" "status=$(col_of "$M" status) assignee=$(col_of "$M" assignee)"
[[ -z "$(col_of "$M" need_type)" ]] \
  && ok_t "M1 no gate was filed" || bad_t "M1 gated" "need_type='$(col_of "$M" need_type)' ask='$(col_of "$M" need_ask)'"
[[ "$(col_of "$M" max_iterations)" == "2" && "$(col_of "$M" iteration)" == "1" ]] \
  && ok_t "M1 the cap moved up by one (1 -> 2), the counter did not move" \
  || bad_t "M1 cap" "iteration=$(col_of "$M" iteration) max=$(col_of "$M" max_iterations)"
[[ "$(col_of "$M" result)" == *"$MAKER_TEXT"* && "$(col_of "$M" result)" == *"FIX: rebase"* ]] \
  && ok_t "M1 the maker's text survives and the FIX line reaches the maker" \
  || bad_t "M1 result" "$(col_of "$M" result)"
m_detail=$(db "SELECT COALESCE(detail,'') FROM lifecycle_events WHERE ident=$(sqlq "$M") AND kind='task.rejected';")
[[ "$m_detail" == *"merge conflict"* && "$m_detail" == *"not counted"* ]] \
  && ok_t "M1 the task.rejected event says it was a merge-conflict bounce, not counted" \
  || bad_t "M1 event" "detail='$m_detail'"

# --- M2: re-delivery stays inside the cap; a quality reject after it still gates.
as dev cmd_task_done "$M" --result="MAKER RESULT: rebased onto main, 9/9 unit" >/dev/null
[[ "$(col_of "$M" iteration)" == "2" && "$(col_of "$M" max_iterations)" == "2" && "$(col_of "$M" assignee)" == "main" ]] \
  && ok_t "M2 the re-delivery is iteration 2 of 2, back with the verifier" \
  || bad_t "M2 re-delivery" "iteration=$(col_of "$M" iteration) max=$(col_of "$M" max_iterations) assignee=$(col_of "$M" assignee)"
as main cmd_task_reject "$M" --feedback="the rebase dropped a hunk FIX: restore the dropped hunk" >/dev/null
[[ "$(col_of "$M" need_type)" == "decision" ]] \
  && ok_t "M2 a QUALITY reject at the cap still gates exactly as before" \
  || bad_t "M2 cap lost its purpose" "need_type='$(col_of "$M" need_type)'"

# --- M3/M4/M5: the flag is checked against the row; a refusal writes nothing.
refused_clean() { # <ident> <label> <events-before>
  local id="$1" label="$2"
  [[ $rc -ne 0 && "$(col_of "$id" result)" == "$MAKER_TEXT" && "$(col_of "$id" max_iterations)" == "1" \
     && "$(col_of "$id" assignee)" == "main" && -z "$(col_of "$id" need_type)" \
     && "$(events_of "$id" task.rejected)" == "0" ]] \
    && ok_t "$label refused, nothing written" \
    || bad_t "$label" "rc=$rc result='$(col_of "$id" result)' max=$(col_of "$id" max_iterations) assignee=$(col_of "$id" assignee) need='$(col_of "$id" need_type)' err=$(cat "$TMP"/err)"
}
N=$(seed_passed "N no pass on this delivery")
db "UPDATE tasks SET graded_verdict=NULL, graded_verdict_at=NULL WHERE ident=$(sqlq "$N");"
as ops cmd_task_reject "$N" --feedback="$FB" --merge-conflict >/dev/null; rc=$?
refused_clean "$N" "M3 --merge-conflict with no PASS"

S=$(seed_passed "S a pass on an older head")
db "UPDATE tasks SET graded_verdict_at=datetime('now','-1 hour') WHERE ident=$(sqlq "$S");"
as ops cmd_task_reject "$S" --feedback="$FB" --merge-conflict >/dev/null; rc=$?
refused_clean "$S" "M4 --merge-conflict on a PASS recorded before the current delivery"

W=$(seed_passed "W a seat that is not the merger")
as olivia cmd_task_reject "$W" --feedback="$FB" --merge-conflict >/dev/null; rc=$?
refused_clean "$W" "M5 --merge-conflict from a seat that neither owes the merge nor graded it"

printf '\n%s\n' "----------------------------------------"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
