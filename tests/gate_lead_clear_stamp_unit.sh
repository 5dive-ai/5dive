#!/usr/bin/env bash
# TIER: nightly — 18.9s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-2406 isolated unit harness — a LEAD-CLEARED gate must not be stamped as a
# HUMAN answer.
#
# WHY THIS EXISTS. `--human` is a self-asserted argv flag; nothing validates it.
# The provenance stamp read it directly (`(( human )) && answered_by="human:..."`)
# and the honest `lead:` label right below was guarded by `(( ! human ))`. So a
# lead who cleared a routed approval gate AND passed --human was recorded
# `answered_by=human:<lead>` with every evidence form of a human absent:
#
#   DIVE-2400, 2026-07-30 04:28:04Z, user=agent-marketing
#   answered_by=human:marketing tier=1 human=1 lead_clear=1
#   channel_proof=absent cp_ok=0 nonce_valid=0 sudo_nonagent=0
#
# The AUTHORITY was correct — the DIVE-1381 curation carve-out routes a persona
# batch to the lead deliberately — and no authority was escalated. The STAMP was
# the defect, and it is not cosmetic: that task's result then asserted "lodar
# approved all 7" when he had never answered, and `human:%` is a load-bearing
# predicate for cmd_trace, cmd_digest's human-touch count, cmd_proof's ledger and
# the precedent engine, which auto-applies a PRIOR HUMAN ANSWER to later gates.
#
# WHAT IS PINNED, and note the SHAPE of it. This fix REMOVES a label, so the arm
# that grades it (case 1) is NEW, but the arm that catches over-reach (case 2) was
# ALREADY GREEN before the change and has to STAY green — a suite built only from
# case 1 signs off happily on a build that demotes every human tap in the fleet.
# Both directions are mutation-measured in the PR body.
#   1. lead-clear + UNCORROBORATED --human  -> `lead:<lead>`, row human=0
#   2. lead-clear + CORROBORATED --human    -> `human:<lead>`  (already green)
#   3. the two labels are DISTINCT (neither case is trivially satisfied)
#   4. a non-lead human answer is UNTOUCHED -> `human:<actor>`
#   5. the DIVE-2099 STANDING clear takes the same demotion (it sets
#      _lead_clear=1, which is why the fix needs no second condition)
#   6. the row carries the CLAIM alongside the verdict (human=0 human_claim=1),
#      so the demotion is observable in the log and countable fleet-wide
#   7. no fixture row reaches the real fleet audit log (graded by MARKER, not
#      by byte offset — the offset moves on a live box because siblings write to it).
# Run: bash tests/gate_lead_clear_stamp_unit.sh   (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
# DIVE-2518: `--from` no longer moves the actor — derive as the agent each arm
# is impersonating. tests/lib/actor_seam.sh.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/gate-lead-clear-stamp.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

# Suite guard: remember the REAL log's length up front, so the check at the bottom
# fails if THIS run grew it.
REALLOG=/var/log/5dive/agent-audit.log
REALLOG_OFFSET=0
# One marker in every fixture title, so a leak is greppable in the real log.
FIXTURE_MARK="dive2406-fixture"
[[ -r "$REALLOG" ]] && REALLOG_OFFSET=$(wc -c <"$REALLOG" 2>/dev/null || echo 0)

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # AFTER sourcing: header.sh turns `set -e` back on.
tasks_db_init
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"   # DIVE-2010 fence: let the row through

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
addt()  { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
nby()   { db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE id=${1};"; }
row()   { grep 'task answer gate.*answered_by=' "$AUDIT_CALLS" | head -1; }

AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
# Preconditions, not observables. AUTH is the seam that decides _lead_clear: the
# production resolver reads the KERNEL-enforced caller (DIVE-2004) and cannot be
# driven from a test, so we drive it here and leave every OTHER condition real.
task_need_notify() { return 0; }
_gate_proof_enforced() { return 0; }
AUTH="main"
_gate_authenticated_actor() { printf '%s' "$AUTH"; }
# The DIVE-2233 sealed reader decides nothing in this release; stub it so the
# harness measures the stamp and not the constitution's availability on this box.
_gate_clear_lead_allowed() { return 0; }
_gate_clear_lead_denied_reason() { printf 'n/a'; }
# The two human-evidence forms. Default: NEITHER present — the DIVE-2400 shape.
SUDO_NONAGENT=1
_gate_sudo_uid_nonagent() { return "$SUDO_NONAGENT"; }
reset() { : >"$AUDIT_CALLS"; unset _TASK_STORE_AUDIT_FENCED; }

# A routed approval gate: `task need` does the routing from preferences we cannot
# rely on in a fixture, so the reviewer is set directly — routed_reviewer is the
# INPUT to the path under test, not part of what it decides.
mkgate() {
  local _t; _t=$(addt --assignee=dev -- "$2")
  cmd_task_need "$_t" --type=approval --ask="$1" --tier=1 >/dev/null 2>&1
  db "UPDATE tasks SET routed_reviewer='main' WHERE id=${_t};" >/dev/null 2>&1
  printf '%s' "$_t"
}

# --- 1+6. lead-clear + UNCORROBORATED --human -> lead:, and the row says so ----
reset
SUDO_NONAGENT=1
t1=$(mkgate "ship the persona batch" "fixture routed approval $FIXTURE_MARK")
( actor_seam_as main; cmd_task_answer "$t1" --value="approved" --human --from=main >/dev/null 2>&1 )
BY1=$(nby "$t1"); ROW1=$(row)
if [[ "$BY1" == "lead:main" ]]; then
  ok_t "an uncorroborated --human on a lead-cleared gate stamps lead:main"
else
  bad_t "a lead-clear with NO human evidence must not be stamped human:*" \
        "need_answered_by='$BY1' (expected lead:main)"
fi
if [[ "$ROW1" == *"human=0"* && "$ROW1" == *"lead_clear=1"* ]]; then
  ok_t "the audit row records human=0 lead_clear=1"
else
  bad_t "row must report the demoted verdict" "row='$ROW1'"
fi
if [[ "$ROW1" == *"human_claim=1"* ]]; then
  ok_t "the row carries the CLAIM beside the verdict (demotion is countable)"
else
  bad_t "a demotion the log cannot show is a demotion nobody can audit" "row='$ROW1'"
fi

# --- 2. lead-clear + CORROBORATED --human -> human:. ALREADY GREEN before the --
#        fix; this is the arm that fails if the demotion is made unconditional.
reset
SUDO_NONAGENT=0            # non-agent SUDO_UID: a real human-evidence form
t2=$(mkgate "ship the persona batch" "fixture routed approval, real human $FIXTURE_MARK")
( actor_seam_as main; cmd_task_answer "$t2" --value="approved" --human --from=main >/dev/null 2>&1 )
BY2=$(nby "$t2")
if [[ "$BY2" == "human:main" ]]; then
  ok_t "a CORROBORATED --human still stamps human:main (no genuine tap relabelled)"
else
  bad_t "the fix must not demote an evidenced human answer" \
        "need_answered_by='$BY2' (expected human:main)"
fi

# --- 3. DISTINCTNESS: the two cases must not be the same string ---------------
if [[ -n "$BY1" && -n "$BY2" && "$BY1" != "$BY2" ]]; then
  ok_t "the evidenced and unevidenced clears are recorded DIFFERENTLY"
else
  bad_t "both cases produced the same provenance — one of the arms is vacuous" \
        "unevidenced='$BY1' evidenced='$BY2'"
fi

# --- 4. a NON-lead human answer is untouched ---------------------------------
#        A tier-1 `decision` gate, chosen deliberately over an approval one: it
#        never enters the human-evidence block, so _hp/_su sit at the function-scope
#        DEFAULTS the fix introduced and _human_evid is 0 here. This is therefore
#        the arm that catches a demotion conditioned on evidence ALONE — drop the
#        `_lead_clear` guard from the fix and every ordinary human answer in the
#        fleet loses its human: stamp, and this is what says so.
reset
SUDO_NONAGENT=1
AUTH="nobody"
t4=$(addt --assignee=dev -- "fixture unrouted decision $FIXTURE_MARK")
cmd_task_need "$t4" --type=decision --options="A|B" --recommend="A" \
  --ask="pick one" --tier=1 >/dev/null 2>&1
( actor_seam_as lodar; cmd_task_answer "$t4" --value="A" --human --from=lodar >/dev/null 2>&1 )
BY4=$(nby "$t4")
if [[ "$BY4" == "human:lodar" ]]; then
  ok_t "a non-lead human answer keeps its human: stamp (fix is scoped to leads)"
else
  bad_t "the demotion escaped the lead-clear paths" \
        "need_answered_by='$BY4' (expected human:lodar)"
fi
AUTH="main"

# --- 5. the DIVE-2099 STANDING clear takes the same demotion ------------------
#        Standing needs no routed_reviewer; it sets _lead_clear=1 itself, which is
#        why the fix carries ONE condition. `_gate_standing_lead` reads the sealed
#        constitution (unavailable in a fixture) so it is the seam; ELIGIBILITY is
#        the real predicate and runs unstubbed.
reset
SUDO_NONAGENT=1
_gate_standing_lead() { printf 'main'; }
t5=$(addt --assignee=dev -- "fixture standing approval $FIXTURE_MARK")
cmd_task_need "$t5" --type=approval --ask="merge the CLI fix to main" --tier=1 >/dev/null 2>&1
( actor_seam_as main; cmd_task_answer "$t5" --value="approved" --human --from=main >/dev/null 2>&1 )
BY5=$(nby "$t5"); ROW5=$(row)
if [[ "$BY5" == "lead:standing:main" ]]; then
  ok_t "a standing clear with no human evidence stamps lead:standing:main"
elif [[ "$BY5" == "human:main" ]]; then
  bad_t "the standing path escaped the demotion" "need_answered_by='$BY5'"
else
  # Eligibility is a conjunction of real predicates; if the fixture ask does not
  # classify, say so rather than scoring a pass on a path that never ran.
  bad_t "standing clear did not engage — this arm graded nothing" \
        "need_answered_by='$BY5' row='$ROW5'"
fi

# --- 7. suite guard: no fixture row reached the real fleet log ----------------
# Graded by CONTENT, not by byte offset. The offset comparison other harnesses use
# is racy on a live box — measured here 2026-07-30: it "failed" on 273 bytes that
# agent-olivia wrote to the shared log while this suite ran, with nothing of ours
# in them. An offset guard cannot tell a leak from a sibling; a marker grep can,
# and it stays meaningful when a real leak is one row among a hundred.
# Three-state on purpose: `grep -c` EXITS 1 on zero matches while still printing
# "0", so the reflexive `|| echo 0` yields the string "0\n0" and the arm fails on a
# clean run. And an unreadable log is not a pass — it is an unprobed guard, and it
# says so instead of scoring green.
LEAKED=""
if [[ -r "$REALLOG" ]]; then
  LEAKED=$(grep -c "$FIXTURE_MARK" "$REALLOG" 2>/dev/null)
  [[ "$LEAKED" =~ ^[0-9]+$ ]] || LEAKED=""
fi
if [[ -z "$LEAKED" ]]; then
  printf 'skip - real fleet log not readable here; leak guard UNPROBED (not a pass)\n'
elif [[ "$LEAKED" == "0" ]]; then
  ok_t "no fixture row from this suite reached the real fleet audit log"
else
  bad_t "fixture rows LEAKED into the real audit log" "$LEAKED row(s) matching $FIXTURE_MARK"
fi
# Report the offset delta as CONTEXT so a reader is not misled into thinking the
# suite proved the file never moved. It moves; other agents write to it.
[[ -r "$REALLOG" ]] && printf '# note: real log grew %s bytes during this run (concurrent agents; see above)\n' \
  "$(( $(wc -c <"$REALLOG" 2>/dev/null || echo 0) - REALLOG_OFFSET ))"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
