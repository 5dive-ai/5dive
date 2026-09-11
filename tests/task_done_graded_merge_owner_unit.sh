#!/usr/bin/env bash
# DIVE-4261 — THE MERGE OWNER MAY CLOSE A GRADED ROW WHOSE PR IS MERGED.
#
# The DIVE-2007 delivered-loop guard reads only the DELIVERY tokens (maker set,
# verifier holding, actor is neither), so it fired identically on a row that had
# already been graded PASS and was sitting at graded->merge — and told the seat
# that owes the merge that the row "has NOT been graded" and that only the
# verifier may close it. Both halves are false there: the grade exists, and
# `task merge` refuses anyone but the grader. DIVE-4253 landed in exactly that
# corner on 2026-09-10 (PR #864 merged 23:12Z, graded, and neither the maker,
# the merge owner nor main could close it), which then kept the GRADER
# busy-skipped for the next hour — the other half of this ticket, graded in
# tests/heartbeat_dispatcher_claim_unit.sh.
#
# What this harness must prove, and the second half is the one that matters:
#   T1  the merge OWNER's close of a graded row whose PR is MERGED goes through;
#   T2  the SAME close with the PR still OPEN is refused by the DIVE-1830 merge
#       gate — so the exemption removed a wrong refusal, not the evidence rule;
#   T3  a row that is NOT graded still refuses with DIVE-2007 (the exemption did
#       not widen into "anyone named merge_owner may close anything");
#   T4  a graded row closed by a seat that is NOT its merge owner still refuses.
#
# Same isolation contract as the other task unit harnesses: src/ sourced
# directly, STATE_DIR on a throwaway temp dir, actor pinned through the sealed
# seam, and `gh` replaced by a stub on PATH — no network, no live tasks.db.
# Run: bash tests/task_done_graded_merge_owner_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src

TMP="$(mktemp -d /tmp/task-done-graded-merge-owner.XXXXXX)"

# --- gh stub: the merge gate's only window onto GitHub. Field-keyed exactly
# like tests/task_deliver_merge_gate_unit.sh's, so the two cannot drift. -------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
argv="$*"; q=""; state=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q) q="$2"; shift 2 ;;
    -q*) q="${1#-q}"; shift ;;
    --state) state="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
if [[ "$argv" == *"pr list"* && "$state" == "open" ]]; then
  printf '%s' "${GH_STUB_PRLIST:-[]}" | jq -r "$q" 2>/dev/null
  exit 0
fi
if [[ "$q" == *headRefOid* ]]; then
  printf '%s|%s\n' "${GH_STUB_HEAD_SHA-}" "${GH_STUB_MERGE_SHA-}"
  exit 0
fi
case "$q" in
  .state)          printf '%s\n' "${GH_STUB_STATE:-}" ;;
  .mergedAt|.\[0\].mergedAt|'.[0].mergedAt') printf '%s\n' "${GH_STUB_MERGED:-}" ;;
  *)               printf '{"state":"%s","mergedAt":"%s"}\n' "${GH_STUB_STATE:-}" "${GH_STUB_MERGED:-}" ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh \
         cmd_task.sh cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

as() { local who="$1"; shift; ( actor_seam_as "${who}"; "$@" ) 2>"$TMP"/err; }
[[ "$( ( actor_seam_as main; task_actor ) )" == "main" ]] \
  && ok_t "harness can impersonate an actor (task_actor -> main)" \
  || bad_t "actor impersonation" "every case below would be vacuous"

status_of()  { db "SELECT status FROM tasks WHERE ident=$(sqlq "$1");"; }
refusals()   { db "SELECT COUNT(*) FROM policy_refusals WHERE policy='done-over-delivered-loop' AND ident=$(sqlq "$1");"; }

# seed <title> <merge_owner> <graded:0|1> -> ident of a delivered row held by
# verifier 'quinn', made by 'dev2'. Graded rows satisfy _TASKS_TFV_SQL exactly.
seed() {
  local out ident
  out=$(JSON_MODE=1 cmd_task_add "$1" --assignee=dev2 --verifier=quinn 2>"$TMP"/err)
  ident=$(printf '%s' "$out" | jq -r '.data.ident // empty')
  db "UPDATE tasks SET maker_agent='dev2', verifier='quinn', assignee='quinn',
             status='in_progress', iteration=1,
             handoff_delivered_at=datetime('now','-2 hours'),
             delivery_ref='https://github.com/5dive-ai/5dive/pull/864',
             merge_owner=$(sqlq "$2")
       WHERE ident=$(sqlq "$ident");"
  if [[ "$3" == "1" ]]; then
    db "UPDATE tasks SET graded_by='quinn', graded_at=datetime('now','-1 hours'),
               graded_verdict='pass', handoff_rejected_at=NULL
         WHERE ident=$(sqlq "$ident");"
  fi
  printf '%s' "$ident"
}
# Precondition shared by T1/T2/T4: the board really does call these rows
# graded->merge. Read through the product predicate, not re-derived here.
is_tfv() { [[ "$(db "SELECT 1 FROM tasks WHERE ident=$(sqlq "$1") AND (${_TASKS_TFV_SQL});")" == "1" ]]; }

# --- T1: the merge owner closes a graded row whose PR is MERGED. -------------
T1=$(seed "T1 graded, merge owed by main" main 1)
is_tfv "$T1" && ok_t "T1 precondition: the row is graded->merge (the board's own predicate)" \
             || bad_t "T1 precondition" "the fixture is not graded->merge; T1/T2/T4 would be vacuous"
export GH_STUB_STATE="MERGED" GH_STUB_MERGED="2026-09-10T23:12:00Z"
out=$(as main cmd_task_done "$T1" --no-graded-sha --result="PR merged; closing as merge owner"); rc=$?
(( rc == 0 )) && [[ "$(status_of "$T1")" == "done" ]] \
  && ok_t "T1 the merge OWNER closes a graded row whose PR is MERGED" \
  || bad_t "T1 merge owner close" "rc=$rc status=$(status_of "$T1") $(cat "$TMP"/err)"
[[ "$(refusals "$T1")" == "0" ]] \
  && ok_t "T1 no DIVE-2007 'has NOT been graded' refusal on a row that IS graded" \
  || bad_t "T1 spurious refusal" "the delivered-loop guard fired on a graded row"

# --- T2: THE EVIDENCE RULE IS INTACT. Same actor, same graded row, PR OPEN. --
# This is what separates "removed a wrong refusal" from "removed the gate": the
# close still has to prove the delivery reached main, and the refusal that
# lands names the rule that is actually stopping it.
T2=$(seed "T2 graded, merge owed by main, PR still open" main 1)
GH_STUB_STATE="OPEN" GH_STUB_MERGED=""
out=$(as main cmd_task_done "$T2" --result="closing early"); rc=$?
(( rc != 0 )) && [[ "$(status_of "$T2")" != "done" ]] \
  && ok_t "T2 the same close with the PR UNMERGED is still REFUSED" \
  || bad_t "T2 unmerged close slipped through" "rc=$rc status=$(status_of "$T2")"
grep -qi "not merged to main" "$TMP"/err \
  && ok_t "T2 and the refusal is the MERGE GATE's, naming its criterion" \
  || bad_t "T2 wrong refusal" "$(cat "$TMP"/err)"
[[ "$(refusals "$T2")" == "0" ]] \
  && ok_t "T2 still no DIVE-2007 refusal (the graded row is never called ungraded)" \
  || bad_t "T2 DIVE-2007 fired" "$(cat "$TMP"/err)"

# --- T3: the exemption is NARROW — an UNGRADED delivered row is still guarded.
GH_STUB_STATE="MERGED" GH_STUB_MERGED="2026-09-10T23:12:00Z"
T3=$(seed "T3 delivered but never graded, merge owner main" main 0)
is_tfv "$T3" && bad_t "T3 precondition" "an ungraded row must NOT read graded->merge" \
             || ok_t "T3 precondition: the ungraded row is not graded->merge"
out=$(as main cmd_task_done "$T3" --no-graded-sha --result="drive-by close"); rc=$?
(( rc != 0 )) && [[ "$(status_of "$T3")" != "done" ]] \
  && ok_t "T3 an UNGRADED delivered row is still refused, merge_owner or not" \
  || bad_t "T3 exemption widened" "rc=$rc status=$(status_of "$T3")"
[[ "$(refusals "$T3")" == "1" ]] \
  && ok_t "T3 and the DIVE-2007 refusal is audited as before" \
  || bad_t "T3 refusal not audited" "count=$(refusals "$T3")"

# --- T4: and it is scoped to the OWNER — another seat's close still refuses. --
T4=$(seed "T4 graded, merge owed by main, closed by olivia" main 1)
out=$(as olivia cmd_task_done "$T4" --no-graded-sha --result="drive-by close"); rc=$?
(( rc != 0 )) && [[ "$(status_of "$T4")" != "done" ]] \
  && ok_t "T4 a seat that is not the merge owner is still refused on a graded row" \
  || bad_t "T4 exemption is not scoped to the owner" "rc=$rc status=$(status_of "$T4")"
[[ "$(refusals "$T4")" == "1" ]] \
  && ok_t "T4 and that refusal is the DIVE-2007 guard, unchanged" \
  || bad_t "T4 refusal not audited" "count=$(refusals "$T4")"

# --- T5: the VERIFIER's own close is untouched (no regression on the grader's
# happy path — it is the case the guard was always letting through).
T5=$(seed "T5 grader closes its own graded row" main 1)
out=$(as quinn cmd_task_done "$T5" --no-graded-sha --result="graded PASS, merged"); rc=$?
(( rc == 0 )) && [[ "$(status_of "$T5")" == "done" ]] \
  && ok_t "T5 the verifier's own close still works" \
  || bad_t "T5 verifier close regressed" "rc=$rc status=$(status_of "$T5") $(cat "$TMP"/err)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
