#!/usr/bin/env bash
# DIVE-4144 — a reject must carry the FIX, a bare re-deliver must not pass as rework.
#
# Provenance (DIVE-4113, 2026-09-09): three iterations, of which iteration 2 was a
# byte-identical re-deliver — olivia: "ITERATION 2 CHANGED NOTHING vs iteration 1" —
# and the fix that closed it in iteration 3 was already present in the ITERATION-1
# reject as "FIX (either closes it): (a)… (b)…". Two rounds were paid for
# information that already existed. Each maker<->verifier round is a cold reload of
# the PR, so this is the autonomy number, not tidiness.
#
# The arms, and each is written to FALSIFY one of the three:
#   A   an unstructured reject is REFUSED, and refused as a NO-OP: the maker's
#       delivered result and the iteration counter must both be untouched. A
#       refusal that had already written is worse than none — the verifier would
#       re-run the verb and double-bounce the row.
#   B   a reject naming a FIX proceeds and bounces to the maker (the guard must not
#       break the rail it protects).
#   B2  "prefix:" does NOT satisfy the marker — the boundary in the regex is
#       load-bearing and a substring match would green every arm here vacuously.
#   C   --no-fix=<why> is the declared exit; a bare --no-fix is a usage error.
#   D   the wake nudge carries the FIX block, keyed on the UNSPENT reject token.
#   D2  and goes quiet on a row with no outstanding reject (the negative control:
#       without it, a clause that fired unconditionally would pass D).
#   E   a byte-identical re-delivery after a reject is REFUSED, as a no-op.
#   F   --force-redeliver=<reason> is the declared exit.
#   G   a CHANGED re-delivery is untouched — the guard must not tax rework.
#
# Run: bash tests/task_reject_fix_template_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src

TMP="$(mktemp -d /tmp/task-reject-fix-template.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh \
         cmd_push.sh cmd_org.sh cmd_project.sh; do
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
res_of()    { db "SELECT COALESCE(result,'') FROM tasks WHERE ident=$(sqlq "$1");"; }
status_of() { db "SELECT status FROM tasks WHERE ident=$(sqlq "$1");"; }
col_of()    { db "SELECT COALESCE($2,'') FROM tasks WHERE ident=$(sqlq "$1");"; }

# PRECONDITION: without impersonation every reject below runs as the same actor
# and the DIVE-2112 maker refusal, not this ticket's guard, decides the arms.
[[ "$( ( actor_seam_as dev; task_actor ) )" == "dev" ]] \
  && ok_t "harness can impersonate an actor (task_actor -> dev)" \
  || bad_t "actor impersonation" "every arm below would be vacuous"

MAKER_TEXT="MAKER RESULT: implemented the thing, graded-sha abc1234, 9/9 unit"
FIXFB='FINDING: the guard fires only on done rows. FIX: key it on carries-a-result. VERIFY: I will re-run the todo-path arm.'

seed() {
  local out id; out=$(JSON_MODE=1 cmd_task_add "$1" --assignee=dev --verifier=main --verify \
                        --accept="must do the thing" 2>"$TMP"/err)
  id=$(printf '%s' "$out" | jq -r '.data.ident // empty' 2>/dev/null)
  as dev cmd_task_done "$id" --result="$MAKER_TEXT" >/dev/null
  printf '%s' "$id"
}

# ── A: the unstructured reject is refused, and refused BEFORE any write ───────
A=$(seed "A an unstructured reject is refused")
[[ "$(status_of "$A")" == "todo" && -n "$(col_of "$A" handoff_delivered_at)" ]] \
  && ok_t "A fixture is a DELIVERED row (status todo, handoff_delivered_at set)" \
  || bad_t "A fixture" "status=$(status_of "$A") — the arms would grade the wrong path"
a_iter_before=$(col_of "$A" iteration)
out=$(as main cmd_task_reject "$A" --feedback="not good enough, do better"); rc=$?
(( rc == E_VALIDATION )) \
  && ok_t "A a reject naming no FIX is refused (rc=$E_VALIDATION)" \
  || bad_t "A not refused" "rc=$rc out=$out err=$(cat "$TMP"/err)"
[[ "$(cat "$TMP"/err)$out" == *"FINDING:"*"FIX:"*"VERIFY:"* ]] \
  && ok_t "A the refusal RENDERS the FINDING/FIX/VERIFY template" \
  || bad_t "A template not printed" "$(cat "$TMP"/err)"
[[ "$(res_of "$A")" == "$MAKER_TEXT" ]] \
  && ok_t "A the refusal is a NO-OP: the maker's delivered result is byte-untouched" \
  || bad_t "A wrote anyway" "result=$(res_of "$A")"
[[ "$(col_of "$A" iteration)" == "$a_iter_before" && "$(status_of "$A")" == "todo" \
   && "$(col_of "$A" assignee)" == "main" ]] \
  && ok_t "A the counter, status and assignee are untouched by the refusal" \
  || bad_t "A row moved" "iter=$(col_of "$A" iteration) (was $a_iter_before) status=$(status_of "$A") assignee=$(col_of "$A" assignee)"
[[ "$(db "SELECT COUNT(*) FROM policy_refusals WHERE ident=$(sqlq "$A") AND policy='reject-names-no-fix';")" == "1" ]] \
  && ok_t "A the refusal is recorded in policy_refusals" \
  || bad_t "A refusal not audited" "$(db "SELECT policy FROM policy_refusals WHERE ident=$(sqlq "$A");")"

# ── B: a reject that names a FIX still bounces ────────────────────────────────
out=$(as main cmd_task_reject "$A" --feedback="$FIXFB"); rc=$?
(( rc == 0 )) && ok_t "B the SAME row rejects fine once the feedback names a FIX (rc=0)" \
  || bad_t "B structured reject broken" "rc=$rc err=$(cat "$TMP"/err)"
[[ "$(status_of "$A")" == "todo" && "$(col_of "$A" assignee)" == "dev" \
   && -n "$(col_of "$A" handoff_rejected_at)" ]] \
  && ok_t "B it bounced to the maker and stamped the reject token" \
  || bad_t "B rail broken" "status=$(status_of "$A") assignee=$(col_of "$A" assignee) rejected_at='$(col_of "$A" handoff_rejected_at)'"

# ── B2: the marker needs a boundary — "prefix:" must NOT count ────────────────
_reject_feedback_names_a_fix "prefix: this is broken" \
  && bad_t "B2 'prefix:' satisfies the FIX marker" "the boundary is missing; every arm here would green vacuously" \
  || ok_t "B2 'prefix:' does NOT satisfy the FIX marker (the regex boundary holds)"
_reject_feedback_names_a_fix "FIX:" \
  && bad_t "B2 a bare 'FIX:' label counts as naming a fix" "an empty label is not a fix" \
  || ok_t "B2 a bare 'FIX:' with nothing after it does NOT count"
_reject_feedback_names_a_fix 'FIX (either closes it): (a) widen the guard (b) drop it' \
  && ok_t "B2 olivia's measured shape — 'FIX (either closes it): (a)… (b)…' — counts" \
  || bad_t "B2 the shape from DIVE-4113 is rejected" "the guard would refuse the very reject that closed that row"

# ── C: the declared exit ─────────────────────────────────────────────────────
C=$(seed "C the no-fix exit")
out=$(as main cmd_task_reject "$C" --feedback="the numbers do not reproduce and I cannot see why" --no-fix="I cannot reproduce it either, need the maker's box"); rc=$?
(( rc == 0 )) && ok_t "C --no-fix=<why> proceeds (a refusal with no exit would wedge the loop)" \
  || bad_t "C exit does not work" "rc=$rc err=$(cat "$TMP"/err)"
[[ "$(res_of "$C")" == *"no FIX named"* && "$(res_of "$C")" == *"need the maker's box"* ]] \
  && ok_t "C the reason is written into the row, where the maker reads it" \
  || bad_t "C reason not recorded" "result=$(res_of "$C")"
C2=$(seed "C2 a bare --no-fix is a usage error")
out=$(as main cmd_task_reject "$C2" --no-fix --feedback="x"); rc=$?
(( rc == E_USAGE )) && ok_t "C2 a BARE --no-fix is a usage error, not a silent free pass" \
  || bad_t "C2 bare --no-fix accepted" "rc=$rc"

# ── D: the wake nudge carries the FIX block ──────────────────────────────────
# The clause helper is graded directly: _hb_wake itself needs systemd + tmux and
# is not reachable from a unit harness, so testing it would test nothing here.
if [[ -f "$SRC/cmd_heartbeat.sh" ]]; then
  # shellcheck source=/dev/null
  source "$SRC/cmd_heartbeat.sh" 2>/dev/null
fi
if declare -F _hb_reject_fix_clause >/dev/null 2>&1; then
  a_id=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$A");")
  clause=$(_hb_reject_fix_clause "$a_id")
  [[ "$clause" == *"FIX: key it on carries-a-result"* ]] \
    && ok_t "D the wake clause carries the verifier's FIX text verbatim" \
    || bad_t "D fix block not surfaced" "clause='$clause'"
  [[ "$clause" == *"REJECTED"* ]] \
    && ok_t "D and says why the maker is reading it" || bad_t "D unlabelled" "clause='$clause'"
  # D2 NEGATIVE CONTROL: a delivered row with NO outstanding reject.
  Dn=$(seed "D2 a row with no outstanding reject")
  dn_id=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$Dn");")
  [[ -z "$(_hb_reject_fix_clause "$dn_id")" ]] \
    && ok_t "D2 the clause is EMPTY on a row with no unspent reject (keyed on the token)" \
    || bad_t "D2 clause fires unconditionally" "it would pass D without reading the reject at all"
else
  bad_t "D _hb_reject_fix_clause is not defined" "arm 2 is ungraded"
fi

# ── E: the byte-identical re-deliver ─────────────────────────────────────────
# $A is bounced back to dev carrying an unspent reject token; re-deliver the
# EXACT text the reject displaced.
e_iter_before=$(col_of "$A" iteration)
out=$(as dev cmd_task_done "$A" --result="$MAKER_TEXT"); rc=$?
(( rc == E_CONFLICT )) \
  && ok_t "E a byte-identical re-delivery after a reject is refused (rc=$E_CONFLICT)" \
  || bad_t "E bare re-deliver accepted" "rc=$rc out=$out err=$(cat "$TMP"/err)"
[[ "$(col_of "$A" iteration)" == "$e_iter_before" && "$(col_of "$A" assignee)" == "dev" \
   && -n "$(col_of "$A" handoff_rejected_at)" ]] \
  && ok_t "E the refusal is a NO-OP: counter, assignee and the reject token all stand" \
  || bad_t "E wrote anyway" "iter=$(col_of "$A" iteration) (was $e_iter_before) assignee=$(col_of "$A" assignee) token='$(col_of "$A" handoff_rejected_at)'"

# ── F: the declared exit for a deliberate unchanged re-delivery ──────────────
out=$(as dev cmd_task_done "$A" --result="$MAKER_TEXT" --force-redeliver="restoring a handoff the gate path destroyed"); rc=$?
(( rc == 0 )) && ok_t "F --force-redeliver=<reason> proceeds (a lost handoff must be restorable)" \
  || bad_t "F exit does not work" "rc=$rc err=$(cat "$TMP"/err)"
[[ "$(col_of "$A" assignee)" == "main" ]] \
  && ok_t "F and it really delivered (assignee back to the verifier)" \
  || bad_t "F did not deliver" "assignee=$(col_of "$A" assignee)"

# ── G: a CHANGED re-delivery is not taxed ────────────────────────────────────
G=$(seed "G a changed re-delivery is untouched")
as main cmd_task_reject "$G" --feedback="$FIXFB" >/dev/null
out=$(as dev cmd_task_done "$G" --result="$MAKER_TEXT — and now the guard is keyed on carries-a-result, 11/11 unit"); rc=$?
(( rc == 0 )) && ok_t "G a re-delivery whose result CHANGED is delivered normally" \
  || bad_t "G rework taxed" "rc=$rc err=$(cat "$TMP"/err)"
[[ "$(col_of "$G" iteration)" == "2" ]] \
  && ok_t "G and it counts as a second pass (iteration 2)" \
  || bad_t "G counter" "iteration=$(col_of "$G" iteration)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
