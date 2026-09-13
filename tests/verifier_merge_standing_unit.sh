#!/usr/bin/env bash
# DIVE-3474 arm 1 — a verifier may merge WHAT IT GRADED, and nothing else.
#
# The ticket's acceptance is explicitly two-sided: "a verifier seat merges a PR on
# a row it graded, and is REFUSED on a row it did not grade — assert the negative,
# or the grant is unbounded and nobody will notice". A merge performed with the
# machine account leaves no field at the GitHub end that distinguishes a rightful
# one from a wrong one, so the negative is not a nicety here — it is the only
# place the boundary is observable at all.
#
# Graded at the PREDICATE and at the caller-side refusals, not through sudo: the
# root executor's authority check is `_task_merge_standing_sql`, the same string
# the preflight below is built from, so a fixture DB grades the real rule. What a
# fixture cannot grade is the sudo hop itself; the source-level assertions at the
# end pin the three properties that hop depends on (ident-only stdin, SUDO_UID
# derivation, delivery_ref read from the row) so a later edit that loosens one is
# a failing test rather than a silent widening.
# DIVE-2211: name the tree this harness grades. Sourced BEFORE the cd, from
# BASH_SOURCE, so the tree named is the one this FILE lives in rather than $PWD.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/verifier-merge-standing.XXXXXX)"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"; set +e
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
tasks_db_init

# A row in the exact state the board paints `graded->merge`: delivered, graded
# PASS by a verifier who is not the maker, not since rejected.
mk() { # <ident> <maker> <graded_by> <verdict|-> <delivery_ref|-> <rejected_at|-> [status]
  local dr="$5" gv="$4" hr="$6"
  db "INSERT INTO tasks(ident,title,status,created_by,maker_agent,graded_at,graded_by,
       graded_verdict,delivery_ref,handoff_rejected_at)
      VALUES('$1','t','${7:-todo}','main','$2','2026-08-16 09:00:00','$3',
       $([[ "$gv" == "-" ]] && printf 'NULL' || printf "'%s'" "$gv"),
       $([[ "$dr" == "-" ]] && printf 'NULL' || printf "'%s'" "$dr"),
       $([[ "$hr" == "-" ]] && printf 'NULL' || printf "'%s'" "$hr"));"
}
PR=https://github.com/5dive-ai/5dive/pull/658
mk DIVE-100 dev  quinn pass "$PR" -            # quinn graded it: quinn may merge
mk DIVE-101 dev  olivia pass "$PR" -           # someone ELSE graded it
mk DIVE-102 dev  quinn pass -    -             # graded, nothing bound
mk DIVE-103 dev  quinn fail "$PR" -            # a grade is not a pass (DIVE-3430)
mk DIVE-104 dev  quinn pass "$PR" '2026-08-16 10:00:00'   # rejected AFTER the grade (DIVE-3428)
mk DIVE-105 quinn quinn pass "$PR" -           # self-graded: writer IS grader (DIVE-477)
mk DIVE-106 dev  quinn pass "$PR" - done       # terminal row
db "INSERT INTO tasks(ident,title,status,created_by,maker_agent,delivery_ref)
    VALUES('DIVE-107','t','todo','main','dev','$PR');"   # delivered, NEVER graded

# --- 1. THE PREDICATE: standing is the ROW, not the seat ---------------------
# Selected over the same string the root executor uses, so this grades the real
# authority check rather than a copy of it.
sel() { db "SELECT ident FROM tasks WHERE ident='$1' AND $(_task_merge_standing_sql "$2");" 2>/dev/null; }
[[ "$(sel DIVE-100 quinn)" == "DIVE-100" ]] \
  && ok_t "POSITIVE: the seat that graded a row PASS has merge standing on it" || bad_t "positive standing" ""
# THE NEGATIVE THE TICKET ASKS FOR, and the reason the grant is bounded at all.
[[ -z "$(sel DIVE-101 quinn)" ]] \
  && ok_t "NEGATIVE: a row graded by ANOTHER seat gives quinn no standing (this is the whole boundary)" \
  || bad_t "negative: peer-graded row" "quinn matched DIVE-101"
[[ "$(sel DIVE-101 olivia)" == "DIVE-101" ]] \
  && ok_t "...and the seat that DID grade it still has its own standing (the rule is per-row, not a blocklist)" \
  || bad_t "olivia standing on her own grade" ""
[[ -z "$(sel DIVE-107 quinn)" ]] \
  && ok_t "NEGATIVE: an UNGRADED delivered row gives nobody standing — merging is not a way to skip grading" \
  || bad_t "negative: ungraded row" ""
[[ -z "$(sel DIVE-102 quinn)" ]] && ok_t "no delivery_ref = nothing to merge, so no standing" || bad_t "no ref" ""
[[ -z "$(sel DIVE-103 quinn)" ]] && ok_t "a recorded FAIL verdict gives no standing (DIVE-3430: a grade is not a pass)" || bad_t "fail verdict" ""
[[ -z "$(sel DIVE-104 quinn)" ]] && ok_t "a reject NEWER than the grade retires it (DIVE-3428: a grade is not a latch)" || bad_t "later reject" ""
[[ -z "$(sel DIVE-105 quinn)" ]] && ok_t "a SELF-graded row gives no standing (writer is not grader, DIVE-477)" || bad_t "self-graded" ""
[[ -z "$(sel DIVE-106 quinn)" ]] && ok_t "a terminal row is not a merge queue" || bad_t "terminal row" ""

# --- 1b. DIVE-4357: THE GRADE CLOCK THE ITERATION TEST READS IS THE CURRENT ONE ---
#
# DIVE-4327 added `handoff_delivered_at <= graded_at` so a grade cannot certify a
# delivery it never saw. Correct invariant, un-advanceable clock: `graded_at` is
# COALESCE'd at write time (first grade wins) and NOTHING refreshes it, so on a
# reject -> re-deliver -> re-grade cycle the delivery clock walks past a grade clock
# frozen at iteration 1 and this rail closed FOREVER on that row — the verifier had
# to hand the merge to a second seat, which is the hand-move DIVE-4137 removed.
#
# Measured 2026-09-12: DIVE-4346 (verify at iteration 1, then reject) was permanently
# unmergeable by its own verifier; DIVE-4344 (reject with NO verify, so graded_at was
# still NULL and COALESCE stamped it after the re-delivery) merged the same night.
# The contrast is the proof — whether a verified row can be merged by the seat that
# verified it was decided by whether that seat happened to run a verify before
# bouncing, which is not a property of the work.
#
# DRIVEN THROUGH THE REAL VERBS (deliver / verify / reject), not by hand-setting the
# two clocks: the bug IS the write rule on those columns, so a fixture that stamped
# them itself would grade the predicate against clocks the product never produces
# and would stay green under the real defect. The one thing set by hand afterwards
# is the actor pair (graded_by / maker_agent) — actor derivation is sealed to EUID
# here and is graded by section 1 above, so every row in this section would otherwise
# be self-graded and refused for a reason that has nothing to do with the clocks.
# Selected BY ID, not by ident: cmd_task_add leaves ident NULL on a fixture DB, so
# the ident-keyed selector above matches nothing here and EVERY arm in this section —
# the negative controls included — would pass vacuously. Measured while writing it.
selid() { db "SELECT id FROM tasks WHERE id=$1 AND $(_task_merge_standing_sql "$2");" 2>/dev/null; }
ITER_PR=https://github.com/5dive-ai/5dive/pull/659
ME_V=$(task_actor "")
MAKER_V="fixturemaker"
[[ "$MAKER_V" != "$ME_V" ]] || { printf 'FATAL: fixture maker == harness actor; task add refuses assignee==verifier.\n' >&2; exit 1; }

# One row, walked through the full cycle: deliver -> verify(FAIL) -> reject ->
# re-deliver -> verify(PASS). Backdating between the steps is the ONLY hand-write,
# and it buys ordering at datetime()'s one-second resolution: without it every stamp
# lands in the same second, `<=` is satisfied by the tie, and the arm goes green on
# the broken tree for a reason that has nothing to do with the fix.
# JSON_MODE is not set file-wide in this harness (section 1 reads the DB directly),
# so ask for it here rather than parsing the human render.
IT=$( ( JSON_MODE=1; cmd_task_add "iteration-clock" --assignee="$MAKER_V" --verifier="$ME_V" --priority=medium ) 2>/dev/null | jq -r '.data.id' )
[[ "$IT" =~ ^[0-9]+$ ]] || bad_t "1b/FIXTURE could not be created" "cmd_task_add returned '$IT'"
db "UPDATE tasks SET maker_agent='${MAKER_V}', assignee='${ME_V}', verifier='${ME_V}', status='todo' WHERE id=${IT};"
( cmd_task_deliver "$IT" --pr="$ITER_PR" --result="iteration 1" ) >/dev/null 2>&1
db "UPDATE tasks SET handoff_delivered_at=datetime('now','-3 hours') WHERE id=${IT};"
( cmd_task_verify "$IT" --no-done --cmd=false ) >/dev/null 2>&1          # iteration-1 FAIL: stamps graded_at
db "UPDATE tasks SET graded_at=datetime('now','-2 hours'), graded_verdict_at=datetime('now','-2 hours') WHERE id=${IT};"
IT_FROZEN=$(db "SELECT graded_at FROM tasks WHERE id=${IT};")
( cmd_task_reject "$IT" --feedback="bounced: fix the predicate" ) >/dev/null 2>&1
( cmd_task_deliver "$IT" --pr="$ITER_PR" --result="iteration 2" ) >/dev/null 2>&1   # re-delivery: advances the delivery clock, spends the reject token
db "UPDATE tasks SET handoff_delivered_at=datetime('now','-1 hour') WHERE id=${IT};"
db "UPDATE tasks SET graded_by='${ME_V}', maker_agent='${MAKER_V}' WHERE id=${IT};"

# THE CONTROL, and it runs BEFORE the re-grade because it is the same row mid-cycle:
# iteration 2 is delivered and carries only iteration 1's grade. DIVE-4327's whole
# invariant. If this is non-empty the fix has widened the rail rather than moved it.
[[ -z "$(selid "$IT" "$ME_V")" ]] \
  && ok_t "1b/CONTROL: a re-delivered row still carrying only the PREVIOUS iteration's grade confers NO standing (DIVE-4327 intact)" \
  || bad_t "1b/CONTROL: stale grade confers no standing" "the fix widened the rail — a grade now certifies a delivery it never saw"

( cmd_task_verify "$IT" --no-done --result="PASS: iteration 2 is correct" ) >/dev/null 2>&1
db "UPDATE tasks SET graded_by='${ME_V}', maker_agent='${MAKER_V}' WHERE id=${IT};"

[[ "$(db "SELECT graded_at FROM tasks WHERE id=${IT};")" == "$IT_FROZEN" ]] \
  && ok_t "1b/PRECONDITION: graded_at is STILL frozen at the iteration-1 grade — provenance was not rewritten to buy this" \
  || bad_t "1b/PRECONDITION: graded_at frozen across the re-grade" "the COALESCE on graded_at was dropped; DIVE-3428's older-reject arm and DIVE-2477 both key on it"
[[ "$(db "SELECT graded_verdict_at > handoff_delivered_at FROM tasks WHERE id=${IT};")" == "1" ]] \
  && ok_t "1b/PRECONDITION: and the VERDICT clock did advance past the re-delivery — the skew is real, not arranged" \
  || bad_t "1b/PRECONDITION: graded_verdict_at advanced past the re-delivery" "got verdict=$(db "SELECT COALESCE(graded_verdict_at,'<null>') FROM tasks WHERE id=${IT};") delivered=$(db "SELECT COALESCE(handoff_delivered_at,'<null>') FROM tasks WHERE id=${IT};")"
[[ "$(selid "$IT" "$ME_V")" == "$IT" ]] \
  && ok_t "1b/THE BUG: after reject -> re-deliver -> re-grade PASS the verifier HOLDS merge standing (DIVE-4357)" \
  || bad_t "1b/THE BUG: standing held at the end of a reject cycle" "the rail is closed for the life of the row; the verifier must hand the merge to a second seat, which is the hand-move DIVE-4137 removed"

# THE MIGRATION ARM. A row graded before graded_verdict_at existed (DIVE-3430) has
# only graded_at, and COALESCE must fall back to it — in BOTH directions, or this
# change either drops every legacy graded row off the rail or hands standing to a
# legacy grade that predates its delivery.
mkleg() { # <ident> <graded_at offset> <delivered offset>
  db "INSERT INTO tasks(ident,title,status,created_by,maker_agent,graded_at,graded_by,
       graded_verdict,graded_verdict_at,delivery_ref,handoff_delivered_at)
      VALUES('$1','t','todo','main','${MAKER_V}',datetime('now','$2'),'${ME_V}',
       NULL,NULL,'${ITER_PR}',datetime('now','$3'));"
}
mkleg DIVE-110 '-1 hour'  '-2 hours'    # legacy grade AFTER its delivery
mkleg DIVE-111 '-2 hours' '-1 hour'     # legacy grade BEFORE its delivery
[[ "$(sel DIVE-110 "$ME_V")" == "DIVE-110" ]] \
  && ok_t "1b/MIGRATION: a legacy row (no verdict clock) graded AFTER its delivery still confers standing — COALESCE falls back to graded_at" \
  || bad_t "1b/MIGRATION: legacy graded row keeps standing" "every row graded before graded_verdict_at existed just lost its rail"
[[ -z "$(sel DIVE-111 "$ME_V")" ]] \
  && ok_t "1b/MIGRATION CONTROL: and a legacy grade that PREDATES its delivery still confers none — the fallback narrows the same way" \
  || bad_t "1b/MIGRATION CONTROL: legacy stale grade refused" "the fallback fails open on exactly the rows that have no verdict clock to check"


# --- 2. the caller-side refusals arrive with a reason ------------------------
# Not decoration: a refusal a verifier cannot read is answered by asking a second
# seat to press the button, which is the exact ask this ticket removes.
pf() { ( _task_merge_preflight "$1" "$2" ) 2>&1; }
pf DIVE-100 quinn >/dev/null 2>&1 && ok_t "preflight PASSES the row this seat graded" || bad_t "preflight positive" "$(pf DIVE-100 quinn)"
O=$(pf DIVE-101 quinn)
grep -q 'olivia' <<<"$O" && ok_t "the refusal NAMES the seat that actually graded it" || bad_t "refusal names grader" "$O"
grep -qi 'not a merge capability\|does not extend' <<<"$O" \
  && ok_t "the refusal says what this rail is NOT, so it is not read as a broken permission" || bad_t "refusal explains scope" "$O"
grep -qi 'no grade' <<<"$(pf DIVE-107 quinn)" && ok_t "an ungraded row is refused as ungraded, not as unauthorised" || bad_t "ungraded refusal" ""
grep -qi 'deliver' <<<"$(pf DIVE-102 quinn)" && ok_t "a row with no PR names the verb that binds one" || bad_t "no-ref refusal" ""
grep -qi 'REJECTED' <<<"$(pf DIVE-104 quinn)" && ok_t "a re-rejected row is refused by naming the reject" || bad_t "reject refusal" ""

# --- 3. ONE predicate, and it is the board's ---------------------------------
# The board paints `graded->merge` from _TASKS_TFV_SQL. If this rail re-typed that
# rule the two would drift, and a drift HERE is a merge nobody authorised.
grep -q '_TASKS_TFV_SQL' <<<"$(declare -f _task_merge_standing_sql)" \
  && ok_t "the rail INTERPOLATES the shared graded-awaiting-merge predicate rather than re-typing it" \
  || bad_t "rail reuses _TASKS_TFV_SQL" "$(declare -f _task_merge_standing_sql)"

# --- 4. the sudo hop's properties, pinned at source --------------------------
DO=$(declare -f cmd_task_merge_do)
grep -q 'SUDO_UID' <<<"$DO" && ok_t "the executor derives the caller from SUDO_UID, never from an argument" || bad_t "SUDO_UID derivation" ""
grep -q '_gate_uid_to_agent' <<<"$DO" && ok_t "...and fails closed on a uid that owns no agent-* seat" || bad_t "uid maps to agent" ""
grep -q 'EUID -eq 0' <<<"$DO" && ok_t "the executor refuses unless it is root (reachable only via the exact-path grant)" || bad_t "root-only" ""
grep -q '_task_merge_standing_sql' <<<"$DO" && ok_t "standing is re-derived AS ROOT from the row, not accepted from the caller" || bad_t "root re-derives standing" ""
grep -q 'SELECT delivery_ref FROM tasks' <<<"$DO" \
  && ok_t "the pull request comes from the ROW — there is no argument through which a caller can name another one" \
  || bad_t "PR read from row" ""
grep -q '== 1 ' <<<"$DO" && ok_t "the executor accepts exactly ONE argument (an ident) and no flags" || bad_t "one-arg contract" ""
# The grant is UNCONDITIONAL for the _task_answer reason (it confers no authority
# of its own) — and must NOT sit in the can-push block, which would hand a grader
# the push capability the writer-is-not-grader rail says a grader must not hold.
SUD=$(sed -n '/^render_standard_sudoers()/,/^}/p' src/cmd_agent_create.sh)
grep -q '_merge_do' <<<"$SUD" && ok_t "the seat grant exists in render_standard_sudoers" || bad_t "grant rendered" ""
_UNCOND=$(awk '/^render_standard_sudoers\(\)/,/if \[\[ "\$can_push" == "1" \]\]/' src/cmd_agent_create.sh)
grep -q '_merge_do' <<<"$_UNCOND" \
  && ok_t "the grant is UNCONDITIONAL — not gated behind can-push, which a grader must not hold" \
  || bad_t "grant unconditional" "the _merge_do line is inside the can_push block"

# --- 5. DIVE-4428: a queue-governed branch is ENQUEUED, not squash-merged -----
# MEASURED 2026-09-13 (quinn, PRs #927/#928): `gh pr merge <url> --squash` names a
# merge strategy that the merge queue owns, and GitHub answers that combination
# with a GraphQL 500 — which reads as an outage and invites a retry that cannot
# work. Two verified-good fixes were left for a human to press by hand.
MERGE_CALLER=$(declare -f cmd_task_merge)
# The GitHub half lives in its own function since iteration 2 (see section 6):
# the authority half above is still graded against `cmd_task_merge_do`.
DO_GH=$(declare -f _merge_do_at_github)
grep -q 'enqueuePullRequest' <<<"$DO_GH" \
  && ok_t "the executor ENQUEUES on a queue-governed branch instead of naming a strategy the queue owns" \
  || bad_t "enqueuePullRequest reached" "$DO_GH"
grep -q 'expectedHeadOid' <<<"$DO_GH" \
  && ok_t "...pinning the graded head server-side, so a head that moved errors instead of queueing an ungraded tree" \
  || bad_t "expectedHeadOid pin" ""
grep -q 'mergeQueue{id}' <<<"$DO_GH" \
  && ok_t "...and the governance test is a non-null mergeQueue, not branchProtectionRule (a ruleset populates no rule)" \
  || bad_t "mergeQueue governance probe" ""
grep -q 'isInMergeQueue' <<<"$DO_GH" \
  && ok_t "an already-queued pull request is not re-enqueued (a second enqueue is a no-op at best)" \
  || bad_t "already-queued short circuit" ""
# The enqueue is reported as an enqueue. Saying "merged" over one is how a seat
# closes a row on a merge that has not happened, and the queue can still eject it.
grep -q 'disposition=enqueued' <<<"$DO_GH" \
  && ok_t "the executor names the disposition it actually achieved" \
  || bad_t "executor emits disposition" ""
grep -q '_merge_disp_read' <<<"$MERGE_CALLER" \
  && ok_t "...and the caller reads it rather than printing 'merged' in the past tense over an enqueue" \
  || bad_t "caller branches on disposition" "$MERGE_CALLER"
grep -q '_merge_disp_read' <<<"$(declare -f _merge_disp_do)" \
  && ok_t "...through the SAME reader the close-time rail uses — one reader of the marker, not two greps" \
  || bad_t "one reader of the marker" "$(declare -f _merge_disp_do)"
grep -q 'enqueued:true' <<<"$MERGE_CALLER" \
  && ok_t "...including in --json, where merged:false and enqueued:true are different facts" \
  || bad_t "json carries enqueued" ""
# gh's own words are the error. The defect this replaced pointed at output the
# caller captures and may never have shown.
grep -q "read gh'" <<<"$DO_GH" \
  && bad_t "gh output captured, not pointed at" "the executor still says 'read gh's message above'" \
  || ok_t "GitHub's own message is CAPTURED and reprinted, not referred to as output above"

# --- 6. DIVE-4428 iteration 2: THE ARMS THAT EXECUTE THE ENVELOPE -------------
#
# WHY THIS SECTION EXISTS. Iteration 1 graded this fix with eight `grep`s over
# `declare -f`. quinn re-applied two mutants with every one of those strings
# still intact and the harness stayed at 38 passed / 0 failed:
#   (a) `[[ -n "$_has_queue" ]]` -> `-z`   — inverts governance completely: it
#       would enqueue on branches with NO queue and squash-merge the queue-
#       governed ones, i.e. restore the exact 500 this row is about.
#   (b) `-f oid="$_head_oid"`   -> `-f oid=""` — removes the head pin an arm
#       above claims to hold.
# A string is not a behaviour. Every arm below RUNS `_merge_do_at_github` over a
# stubbed `gh`, and each of the five outcomes is asserted on what the rail
# actually invoked, what it returned, and what it audited.
#
# `_merge_do_at_github` is the GitHub half of `_merge_do`, split out for exactly
# this reason; the authority half (root, SUDO_UID, standing, the row's own
# delivery_ref) is unchanged and is still graded at source in section 4.
mkdir -p "$TMP/bin" "$TMP/ghcfg"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'GH %s\n' "$*" >>"$GH_ARGS_LOG"
_all="$*"
if [[ "$_all" == *"pr merge"* ]]; then
  case "${SQUASH_MODE:-ok}" in
    ok)   printf 'Squashed and merged pull request #658\n'; exit 0 ;;
    fail) printf '! The merge strategy for main is set by the merge queue\nGraphQL: Something went wrong while executing your query\n' >&2; exit 1 ;;
  esac
fi
if [[ "$_all" == *enqueuePullRequest* ]]; then
  case "${ENQ_MODE:-ok}" in
    ok)      printf '{"data":{"enqueuePullRequest":{"mergeQueueEntry":{"state":"QUEUED","position":1}}}}\n'; exit 0 ;;
    noentry) printf '{"data":{"enqueuePullRequest":{"mergeQueueEntry":null}}}\n'; exit 0 ;;
    err)     printf 'GraphQL: enqueuePullRequest is not admitted for this installation\n' >&2; exit 1 ;;
  esac
fi
# otherwise: the governance probe
case "${PROBE_MODE:-queue}" in
  queue)      printf '{"data":{"resource":{"id":"PR_node1","headRefOid":"%s","isInMergeQueue":false,"mergeQueue":{"id":"MQ_1"}}}}\n' "${HEAD_OID}"; exit 0 ;;
  noqueue)    printf '{"data":{"resource":{"id":"PR_node1","headRefOid":"%s","isInMergeQueue":false,"mergeQueue":null}}}\n' "${HEAD_OID}"; exit 0 ;;
  already)    printf '{"data":{"resource":{"id":"PR_node1","headRefOid":"%s","isInMergeQueue":true,"mergeQueue":{"id":"MQ_1"}}}}\n' "${HEAD_OID}"; exit 0 ;;
  nopin)      printf '{"data":{"resource":{"isInMergeQueue":false,"mergeQueue":{"id":"MQ_1"}}}}\n'; exit 0 ;;
  unreadable) printf 'GraphQL: Something went wrong while executing your query\n' >&2; exit 1 ;;
esac
exit 1
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"
export HEAD_OID=eb6528c1eb6528c1eb6528c1eb6528c1eb6528c1
AUDIT_LOG="$TMP/audit.log"; : >"$AUDIT_LOG"
# The audit line is half of what this fix changes (an enqueue must not be recorded
# as a merge), so it is captured rather than written to a real store.
_task_store_audit_log() { printf '%s\n' "$*" >>"$AUDIT_LOG"; }
XPR=https://github.com/5dive-ai/5dive/pull/658

# Runs the rail and captures rc, stderr, the gh argv log and the audit line.
# In a SUBSHELL: the stubs are the surface under test, not this shell's state.
run_rail() {
  : >"$GH_ARGS_LOG"; : >"$AUDIT_LOG"
  RERR=$( ( _merge_do_at_github DIVE-100 "$XPR" quinn faketoken "$TMP/ghcfg" >"$TMP/rail.out" 2>"$TMP/rail.err"; printf '%s' "$?" >"$TMP/rail.rc" ) ; cat "$TMP/rail.err" )
  RRC=$(cat "$TMP/rail.rc"); RLOG=$(cat "$GH_ARGS_LOG"); RAUD=$(cat "$AUDIT_LOG")
}
eq_t()   { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want '$3', got '$2'"; fi; }
has_t()  { if [[ "$2" == *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "missing '$3' in: $2"; fi; }
hasnt_t(){ if [[ "$2" != *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "unwanted '$3' in: $2"; fi; }

# E1 — THE FIX, EXECUTED. A queue-governed branch is enqueued, with the pull
# request's node id and the head sha on the wire. Kills mutant (a) and (b).
export PROBE_MODE=queue ENQ_MODE=ok SQUASH_MODE=ok
run_rail
eq_t   "E1 queue-governed: the rail returns 0"                       "$RRC" "0"
has_t  "E1 ...by CALLING enqueuePullRequest (not by printing it)"    "$RLOG" "enqueuePullRequest"
has_t  "E1 ...carrying the pull request's node id"                   "$RLOG" "-f pr=PR_node1"
has_t  "E1 ...and the graded head pinned server-side"                "$RLOG" "-f oid=$HEAD_OID"
hasnt_t "E1 ...and NO strategy-naming squash merge is attempted"     "$RLOG" "pr merge"
has_t  "E1 ...reported to the caller as an enqueue"                  "$RERR" "_merge_do: disposition=enqueued"
has_t  "E1 ...in words that refuse to call it a landing"             "$RERR" "This is NOT a landed merge"
has_t  "E1 ...and AUDITED as an enqueue, not as a merge"             "$RAUD" "disposition=enqueued"
hasnt_t "E1 ...(the audit does not also claim a merge)"              "$RAUD" "disposition=merged"

# E2 — THE CONTROL, and the other half of mutant (a)'s kill. No queue on the base
# branch: the ordinary squash merge, untouched.
export PROBE_MODE=noqueue ENQ_MODE=ok
run_rail
eq_t    "E2 unqueued branch: the rail returns 0"                     "$RRC" "0"
has_t   "E2 ...by shelling the ordinary squash merge"                "$RLOG" "pr merge $XPR --squash"
hasnt_t "E2 ...and the enqueue mutation does NOT fire"               "$RLOG" "enqueuePullRequest"
has_t   "E2 ...reported as a merge"                                  "$RERR" "merged by quinn"
has_t   "E2 ...and audited as one"                                   "$RAUD" "disposition=merged"

# E3 — an already-queued pull request is not re-enqueued, and is still reported
# as an enqueue rather than as a landing.
export PROBE_MODE=already
run_rail
eq_t    "E3 already in the queue: returns 0"                         "$RRC" "0"
hasnt_t "E3 ...without re-enqueueing"                                "$RLOG" "enqueuePullRequest"
hasnt_t "E3 ...and without falling back to a squash merge"           "$RLOG" "pr merge"
eq_t    "E3 ...exactly one round trip was spent"                     "$(grep -c '^GH ' <<<"$RLOG")" "1"
has_t   "E3 ...still reported as an enqueue"                         "$RERR" "_merge_do: disposition=enqueued"
has_t   "E3 ...and audited as already-queued"                        "$RAUD" "disposition=already-queued"

# E4 — THE FALL-THROUGH the code deliberately builds and no iteration-1 arm held:
# a governance probe must never be the thing that refuses.
export PROBE_MODE=unreadable
run_rail
eq_t    "E4 an unreadable governance probe does NOT refuse"          "$RRC" "0"
has_t   "E4 ...it falls THROUGH to the ordinary squash merge"        "$RLOG" "--squash"
hasnt_t "E4 ...and never enqueues blind"                             "$RLOG" "enqueuePullRequest"

# E5 — the enqueue is refused at GitHub. Non-zero, and GitHub's own bytes on
# stderr rather than a pointer to output the caller may never have shown.
export PROBE_MODE=queue ENQ_MODE=err
run_rail
eq_t   "E5 a refused enqueue returns non-zero"                       "$((RRC != 0))" "1"
has_t  "E5 ...with GitHub's OWN words reprinted verbatim"            "$RERR" "not admitted for this installation"
has_t  "E5 ...named as GitHub's answer, not as a standing refusal"   "$RERR" "ENQUEUE REFUSED"
hasnt_t "E5 ...and nothing is audited as merged or enqueued"         "$RAUD" "disposition="

# E5b — the mutation "succeeds" but returns no queue entry. rc=0 from gh is not
# evidence of a queued request; the entry is.
export PROBE_MODE=queue ENQ_MODE=noentry
run_rail
eq_t   "E5b an empty queue entry is a refusal, not a success"        "$((RRC != 0))" "1"
has_t  "E5b ...named as such"                                        "$RERR" "no queue entry returned"

# E6 — queue-governed, but the node id / head sha could not be read: there is
# nothing to pin an enqueue to, so it refuses rather than queueing unpinned.
export PROBE_MODE=nopin ENQ_MODE=ok
run_rail
eq_t    "E6 a queue-governed PR with no readable head refuses"       "$((RRC != 0))" "1"
has_t   "E6 ...naming what is missing"                               "$RERR" "nothing to pin an enqueue to"
hasnt_t "E6 ...and does not enqueue unpinned"                        "$RLOG" "enqueuePullRequest"

# E7 — the unqueued path's own refusal still carries gh's message.
export PROBE_MODE=noqueue SQUASH_MODE=fail
run_rail
eq_t   "E7 a refused squash merge returns non-zero"                  "$((RRC != 0))" "1"
has_t  "E7 ...with gh's own line reprinted"                          "$RERR" "The merge strategy for main is set by the merge queue"
export SQUASH_MODE=ok

# --- 7. THE DISPOSITION CONTRACT THE CLOSE-TIME RAIL DEPENDS ON --------------
# DIVE-4428 iteration 1's product defect: `src/task/status.sh` calls the SAME
# primitive and could not tell an enqueue from a merge, so it audited
# `task.merged-at-close` and told the operator the seat "merged it (squash)"
# over a request GitHub had only accepted. The marker is now read in ONE place.
eq_t "R1 the reader names an enqueue"  "$(_merge_disp_read 0 "$XPR ENQUEUED ...
_merge_do: disposition=enqueued")" "enqueued"
eq_t "R2 ...a plain merge"             "$(_merge_disp_read 0 "$XPR merged by quinn (the seat that graded it).")" "merged"
eq_t "R3 ...and says NOTHING on a refusal (no disposition was achieved)" \
     "$(_merge_disp_read 1 "_merge_do: ENQUEUE REFUSED for $XPR")" ""

# `_merge_disp_do` over a stubbed `sudo`: the stdout contract status.sh branches
# on, executed. Without this the branch below is graded only by reading it.
# `sudo` is a FUNCTION here, not a binary: tests/lib/env_isolation.sh installs one
# that REFUSES with rc=125 whenever host PAM would restore FIVE_* knobs across the
# sudo boundary (DIVE-3096), so a stub dropped on PATH is never reached — measured
# while writing this arm, which read as a refused rail. Overriding the function is
# the only stub that fires, and nothing here ever wants the real one.
sudo() {
  cat >/dev/null
  [[ "${RAIL_RC:-0}" == "0" ]] || { printf '_merge_do: ENQUEUE REFUSED\n' >&2; return "${RAIL_RC}"; }
  printf '%s\n' "${RAIL_OUT:-the pull request merged by quinn}" >&2
  return 0
}
export RAIL_RC=0 RAIL_OUT='ENQUEUED (state=QUEUED, head pinned at deadbeef)
_merge_do: disposition=enqueued'
eq_t "R4 _merge_disp_do hands the close an 'enqueued' disposition on stdout" \
     "$(_merge_disp_do DIVE-100 2>/dev/null)" "enqueued"
export RAIL_OUT='the pull request merged by quinn (the seat that graded it).'
eq_t "R5 ...and 'merged' when the rail landed it" \
     "$(_merge_disp_do DIVE-100 2>/dev/null)" "merged"
export RAIL_RC=1
eq_t "R6 ...and nothing at all on a refusal" "$( ( _merge_disp_do DIVE-100 2>/dev/null ) )" ""
export RAIL_RC=0

# --- 8. THE CLOSE-TIME RAIL, EXECUTED ----------------------------------------
# DIVE-4428 iteration 1's PRODUCT defect: `src/task/status.sh` calls the same
# primitive and could not tell an enqueue from a merge, so it audited
# `task.merged-at-close` and told the operator the seat "merged it (squash)" over
# a request GitHub had only ACCEPTED.
#
# WHY THESE ARE EXECUTABLE AND NOT GREPS. The first iteration-2 draft graded this
# branch by sed-ing the close's source and grepping it. Measured while writing
# this section: replacing the disposition test with `if false; then` — collapsing
# the enqueue arm back into the merge arm, i.e. RE-INTRODUCING THE EXACT DEFECT
# under grade — left every one of those greps passing at 83/0, because a dead
# branch still contains its strings. That is the same lesson as section 6, found
# a second time in the same fix. Every arm below RUNS `_merge_at_close_do`.
CAUD="$TMP/close-audit.log"; CWARN="$TMP/close-warn.log"; CDB="$TMP/close-db.log"
_task_store_audit_log() { printf '%s\n' "$*" >>"$CAUD"; }
warn() { printf '%s\n' "$*" >>"$CWARN"; }
_gate_slug_from_url() { printf '5dive-ai/5dive\n'; }
# `db` is defined through eval on purpose: a plain definition down here trips
# SC2218 (in shellcheck) against the REAL db calls in sections 1-5 above, which
# run before this point and must reach the fixture database, not this log.
eval 'db() { printf "%s\n" "$*" >>"$CDB"; }'
_gate_pr_state() { printf '%s\n' "${PR_STATE:-}"; }
# The rail itself is stubbed HERE (it is executed for real in section 7): what is
# under test is what the close DOES with each of the three answers it can get.
_merge_disp_do() { [[ -n "${DISP:-}" ]] || return 1; printf '%s\n' "$DISP"; }

run_close() {
  : >"$CAUD"; : >"$CWARN"; : >"$CDB"
  CRE=$(_merge_at_close_do DIVE-100 "$XPR" quinn abcdef1234567890 tok 7); CRC=$?
  CAUDT=$(cat "$CAUD"); CWARNT=$(cat "$CWARN"); CDBT=$(cat "$CDB")
}

# C1 — AN ENQUEUE IS NOT A LANDING. The defect, asserted on behaviour.
export DISP=enqueued PR_STATE='OPEN|null|PASS'
run_close
eq_t    "C1 an enqueue at close: the rail acted, so it returns 0"    "$CRC" "0"
has_t   "C1 ...and is AUDITED under its own event"                   "$CAUDT" "task.enqueued-at-close"
hasnt_t "C1 ...never as a merge that has not happened"               "$CAUDT" "task.merged-at-close"
hasnt_t "C1 ...and the operator is NOT told the seat merged it"      "$CWARNT" "merged it (squash)"
has_t   "C1 ...but that it is in the MERGE QUEUE"                    "$CWARNT" "MERGE QUEUE"
has_t   "C1 ...in words that refuse to call it a landing"            "$CWARNT" "NOT a landed merge"
hasnt_t "C1 ...and the merge owner is NOT retired: one is still owed" "$CDBT" "merge_owner=NULL"
has_t   "C1 ...the caller still gets the re-read state, not a claim" "$CRE" "OPEN|null"

# C2 — A REAL MERGE still behaves exactly as it did before this fix.
export DISP=merged PR_STATE='MERGED|2026-09-13T09:18:48Z|PASS'
run_close
eq_t    "C2 a landed merge at close: returns 0"                      "$CRC" "0"
has_t   "C2 ...audited as task.merged-at-close"                      "$CAUDT" "task.merged-at-close"
hasnt_t "C2 ...and not as an enqueue"                                "$CAUDT" "task.enqueued-at-close"
has_t   "C2 ...operator told the seat merged it"                     "$CWARNT" "merged it (squash)"
has_t   "C2 ...and the merge owner IS retired"                       "$CDBT" "merge_owner=NULL"
has_t   "C2 ...the caller gets MERGED from the RE-READ"              "$CRE" "MERGED|2026-09-13"

# C3 — the rail refused: nothing recorded, nothing claimed, the close falls
# through to the refusal it would have printed anyway.
export DISP="" PR_STATE='OPEN|null|PASS'
run_close
eq_t    "C3 a refused rail returns non-zero"                         "$((CRC != 0))" "1"
eq_t    "C3 ...and audits NOTHING"                                   "$CAUDT" ""
eq_t    "C3 ...and writes NOTHING to the row"                        "$CDBT" ""
has_t   "C3 ...and says the rail refused"                            "$CWARNT" "the merge rail refused"
eq_t    "C3 ...handing the caller no state to act on"                "$CRE" ""

# C4 — GitHub could not be re-read after the merge. The rail still acted, but the
# caller is handed NOTHING rather than an assumed MERGED: the one place a close
# could accept on a claim instead of a measurement.
export DISP=merged PR_STATE=''
run_close
eq_t    "C4 an unreadable re-read still returns 0 (the merge happened)"  "$CRC" "0"
eq_t    "C4 ...but hands the caller no state, so the gate refuses below" "$CRE" ""
export DISP=merged PR_STATE='MERGED|x|PASS'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
