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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
