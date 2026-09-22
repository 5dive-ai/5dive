#!/usr/bin/env bash
# TIER: core — ~4s measured (agent-dev seat, worktree cli-4843-dev, 2026-09-22).
#   No root, no network, no tmux: the forge read is stubbed at `_gate_pr_shas`,
#   which is the single point where this code would leave the box.
#
# DIVE-4831 — THE PACKET'S SHA IS THE DELIVERY'S, OR THE PACKET SAYS SO.
#
# THE SPECIMEN, measured by quinn on DIVE-4825 (2026-09-22):
# `5dive task grade-context DIVE-4825` served DELIVERED_SHA / GRADE_TREE =
# 2b808908 — the sha quinn had ALREADY REJECTED at iteration 1 — with a bounded
# diff at that tree missing both fixes the reject demanded, while the claim block
# and `gh pr view 1091 --json headRefOid` both said 21ee01b6. Two earlier
# specimens: DIVE-4725 (an older iteration of the same branch) and DIVE-4744 (an
# unrelated lineage in another repo).
#
# WHY IT BECAME A CORRECTNESS BUG THE SAME DAY. Before DIVE-4825 the staleness
# was self-correcting: the grader read the diff, saw it did not answer its own
# reject, and bounced. DIVE-4825 put a COMPUTED GRADE TABLE in the packet under
# the words "do NOT re-run the unflagged lines". Compose the two and a stale
# packet stops costing a wasted re-grade and starts CLOSING A ROW on a verdict
# computed at a rejected tree. Nothing corrects a green table read by a grader
# who has been told the lines are settled.
#
# WHAT IS GRADED HERE, and the shape is deliberate: THREE outcomes, not two.
#   A  match        — board sha IS the pull request's head: the one state that
#                     licenses the "do NOT re-run" instruction.
#   B  superseded   — head readable, different, and present locally: the packet
#                     is REBUILT at the head and says so.
#   C  superseded   — head readable, different, and NOT present locally: the
#                     packet keeps the board's sha and marks everything unverified.
#                     It must not refuse: a packet that cannot be built is worse
#                     than one that is honest about what it is.
#   D  unread       — the forge could not be asked. NOT CHECKED is never MATCHED,
#                     and an outage must never manufacture a refusal.
#   E  the table's OWN header sha disagrees — independent of A-D.
#   F  THE SPECIMEN END TO END: the served diff carries the fix the reject
#      demanded, which is exactly what the measured packet omitted.
#   G  the grader's GOAL text, which reaches the seat BEFORE the packet and used
#      to issue the instruction the packet may now withdraw.
#
# Run: bash tests/task_grade_context_pr_head_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src; TMP=$(mktemp -d /tmp/dive4831.XXXXXX)
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
  lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh lib/registry.sh \
  lib/disk.sh lib/verify_policy.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh \
  cmd_push.sh cmd_org.sh cmd_project.sh; do source "$SRC/$f"; done
source "$SRC/task/grader_process.sh"
STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
BOX_CONFIG="$TMP/box.json"; HOME="$TMP/grader-home"; XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$TASKS_DIR" "$HOME"; chmod 700 "$HOME"; JSON_MODE=0; set +e
printf '{"verify":"always"}\n' >"$BOX_CONFIG"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
PASS=0; FAILN=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
tasks_db_init >/dev/null 2>&1

# THE SEAM IS THE FORGE READ AND NOTHING ELSE. `_task_grade_pr_shas` wraps
# `_gate_pr_shas`, so stubbing the wrapped function leaves the wrapper, its
# fail-open contract and every line of cmd_task_grade_context real.
_PR_PAIR=""
_gate_gh_token() { printf ''; }
_gate_slug_from_url() { printf '5dive-ai/5dive'; }
_gate_pr_shas() { printf '%s' "$_PR_PAIR"; }

# The DIVE-4825 lineage, in miniature: a rejected commit, then the commit that
# answers the reject. The whole question is which one the packet serves.
REPO="$TMP/repo"; mkdir -p "$REPO/src"; git -C "$REPO" init -q
printf 'old\n' >"$REPO/src/x.sh"; git -C "$REPO" add -A; git -C "$REPO" commit -qm base
BASE=$(git -C "$REPO" rev-parse HEAD); git -C "$REPO" branch origin/main "$BASE"
printf 'old\nnflags=$(grep -c . <<<"$flags")\n' >"$REPO/src/x.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "iteration 1 — the tree quinn REJECTED"
REJECTED=$(git -C "$REPO" rev-parse HEAD)
printf 'old\nnflags=$(grep -c . <<<"$flags") || nflags=0\n' >"$REPO/src/x.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "iteration 2 — the fix the reject demanded"
FIXED=$(git -C "$REPO" rev-parse HEAD)
ABSENT=1111111111111111111111111111111111111111

TABLE_AT() { printf 'GRADE %s @ %s (base %s)\nsuite   tests/x.sh 3/3 pass\nrails   changed-harness suite green at head\nVERDICT computed: PASS\n' "$2" "${1:0:12}" "${BASE:0:12}"; }
seed() { # <board-sha> <table-sha-or-empty>
  db "DELETE FROM tasks;"
  local body="" tbl=""
  if [[ -n "${2:-}" ]]; then
    tbl=$(TABLE_AT "$2" DIVE-T1)
    body=$'## COMPUTED GRADE (DIVE-4825)\n\n```\n'"${tbl}"$'\n```\n'
  fi
  local result=$'CHANGED: src/x.sh guards the substitution\nCHECKED: bash tests/x.sh — 3 arms, 3 pass\nDELIVERED-SHA: '"$FIXED"$'\nCI: green\nCRITERIA: the guard is present — CHECKED above'
  local i; i=$(db "INSERT INTO tasks (title,body,status,assignee,verifier,maker_agent,kind,priority,created_by,acceptance_criteria,result,review_mode,delivery_repo_path,delivered_sha,delivery_ref,delivered_at)
    VALUES ('sha reconciliation',$(sqlq "$body"),'todo','quinn','quinn','dev','standard','high','dev','The guard is added and tested.',$(sqlq "$result"),'temp',$(sqlq "$REPO/.git"),$(sqlq "$1"),'https://github.com/5dive-ai/5dive/pull/1091',datetime('now')); SELECT last_insert_rowid();")
  db "SELECT ident FROM tasks WHERE id=$i;"
}
pkt()  { cmd_task_grade_context "$1" 2>&1; }
field(){ sed -n "s/^$2: //p" <<<"$1" | head -1; }

echo "── A. match — the only state that licenses 'do NOT re-run' ──"
_PR_PAIR="${FIXED}|"; IDENT=$(seed "$FIXED" "$FIXED"); OUT=$(pkt "$IDENT")
[[ "$(field "$OUT" PR_HEAD_CHECK)" == match* ]] \
  && ok_t "A1 board sha == pull-request head is reported as 'match'" || bad_t "A1 match not reported" "$(field "$OUT" PR_HEAD_CHECK)"
[[ "$(field "$OUT" DELIVERED_SHA)" == "$FIXED" ]] \
  && ok_t "A2 ...and the served sha is unchanged — a confirmed packet is not rewritten" || bad_t "A2 served sha moved" "$(field "$OUT" DELIVERED_SHA)"
[[ "$OUT" == *"do NOT re-run the unflagged lines"* ]] \
  && ok_t "A3 ...and the DIVE-4825 instruction IS issued — this is the state it was written for" || bad_t "A3 instruction missing on a confirmed packet" "the fix must not cost the saving"
[[ "$OUT" != *"⚠️"* ]] && ok_t "A4 ...with no warning banner: a clean packet must still read clean" || bad_t "A4 spurious warning on a matched packet"

echo "── B. superseded, and the head IS in the checkout: rebuild at the head ──"
_PR_PAIR="${FIXED}|"; IDENT=$(seed "$REJECTED" "$REJECTED"); OUT=$(pkt "$IDENT")
[[ "$(field "$OUT" PR_HEAD_CHECK)" == superseded* ]] \
  && ok_t "B1 a board sha that is not the head is reported as 'superseded'" || bad_t "B1 superseded not reported" "$(field "$OUT" PR_HEAD_CHECK)"
[[ "$(field "$OUT" DELIVERED_SHA)" == "$FIXED" ]] \
  && ok_t "B2 THE ASK: the packet is rebuilt at the PULL REQUEST'S HEAD, not at what the board remembered" || bad_t "B2 packet still served the board's sha" "$(field "$OUT" DELIVERED_SHA) (board was ${REJECTED:0:12})"
[[ "$OUT" == *"STALE BOARD SHA (DIVE-4831)"* && "$OUT" == *"⚠️"* ]] \
  && ok_t "B3 ...and says so loudly, naming both shas" || bad_t "B3 the substitution was silent" "a silent rewrite is a different bug"
TREE=$(field "$OUT" GRADE_TREE)
[[ "$(git -C "$TREE" rev-parse HEAD 2>/dev/null)" == "$FIXED" ]] \
  && ok_t "B4 ...and the GRADE_TREE is checked out at the head too — the tree and the label cannot disagree" || bad_t "B4 tree is at a different sha" "$(git -C "$TREE" rev-parse HEAD 2>/dev/null)"
[[ "$OUT" != *"do NOT re-run the unflagged lines"* ]] \
  && ok_t "B5 ...and the 'do NOT re-run' instruction is WITHDRAWN — the table was computed at the rejected tree" || bad_t "B5 a stale table still told the grader to stop checking" "this is the close-on-a-rejected-verdict path"
[[ "$OUT" == *"NOT CONFIRMED AT THIS SHA (DIVE-4831)"* && "$OUT" == *"VERDICT computed: PASS"* ]] \
  && ok_t "B6 ...while the table itself still ships, relabelled as a claim to check rather than dropped" || bad_t "B6 the table was dropped or unlabelled"
# B7/B8 — THE REASON THE RESOLVER IS ONE FUNCTION. `--check=<tree>` is a SEPARATE
# invocation with no packet in scope: the grader runs it right before recording a
# verdict. If it resolved the sha its own way it would refuse the very tree the
# packet had just handed over, on exactly the rows this fix exists for — a fix
# that converts a wrong close into a wedged grade is not a fix.
( cmd_task_grade_context "$IDENT" --check="$TREE" >/dev/null 2>&1 ); RC=$?
(( RC == 0 )) \
  && ok_t "B7 the pre-verdict --check ACCEPTS the re-pointed tree — server and enforcer resolve the sha through one function" \
  || bad_t "B7 --check refused the tree the packet just served" "rc=$RC — the packet and its own checker disagree"
# ...and it is still a real check, not one that accepts anything.
git -C "$TREE" checkout -q --detach "$REJECTED" 2>/dev/null
( cmd_task_grade_context "$IDENT" --check="$TREE" >/dev/null 2>&1 ); RC=$?
(( RC != 0 )) \
  && ok_t "B8 CONTROL: ...while a tree moved back to the stale sha is still REFUSED — B7 is not a blanket accept" \
  || bad_t "B8 --check accepted a tree at the superseded sha" "the seal/sha invariant is gone"
git -C "$TREE" checkout -q --detach "$FIXED" 2>/dev/null

echo "── C. superseded, but the head is NOT in this checkout: keep, and mark ──"
_PR_PAIR="${ABSENT}|"; IDENT=$(seed "$REJECTED" "$REJECTED"); OUT=$(pkt "$IDENT"); RC=$?
(( RC == 0 )) && ok_t "C1 the packet is still BUILT — an unreachable head must not deny the grader a packet" || bad_t "C1 packet refused" "rc=$RC"
[[ "$(field "$OUT" DELIVERED_SHA)" == "$REJECTED" ]] \
  && ok_t "C2 ...at the board's sha, because the head cannot be checked out here" || bad_t "C2 served a sha it cannot have" "$(field "$OUT" DELIVERED_SHA)"
[[ "$OUT" == *"NOT IN THIS CHECKOUT"* && "$OUT" == *"UNVERIFIED"* ]] \
  && ok_t "C3 ...and every line below is marked UNVERIFIED against the delivery" || bad_t "C3 the unverifiable packet reads as verified"
[[ "$OUT" != *"do NOT re-run the unflagged lines"* ]] \
  && ok_t "C4 ...instruction withdrawn here too" || bad_t "C4 instruction survived an unverifiable packet"

echo "── D. no forge: the maker's own DELIVERED-SHA line is the second record ──"
# MOST BOXES HOLD NO gh CREDENTIAL. Treating every unreadable forge as
# unconfirmed would withdraw DIVE-4825's instruction fleet-wide and hand back the
# whole saving that row bought — so the packet falls back to the OTHER record of
# the same fact, written at delivery by a different writer than the column. On
# the measured specimen those two disagreed and the maker's line was right, which
# is how quinn noticed in the first place.
_PR_PAIR=""; IDENT=$(seed "$FIXED" "$FIXED"); OUT=$(pkt "$IDENT"); RC=$?
(( RC == 0 )) && ok_t "D1 a forge that cannot be asked does not manufacture a refusal (fail-open)" || bad_t "D1 outage became a refusal" "rc=$RC"
[[ "$(field "$OUT" PR_HEAD_CHECK)" == unread-corroborated* ]] \
  && ok_t "D2 the store and the maker's DELIVERED-SHA agree -> 'unread-corroborated', never 'match'" || bad_t "D2 wrong state with no forge" "$(field "$OUT" PR_HEAD_CHECK)"
[[ "$OUT" == *"do NOT re-run the unflagged lines"* ]] \
  && ok_t "D3 ...and the instruction SURVIVES, so a credential-less box keeps DIVE-4825's saving" || bad_t "D3 the saving was handed back on every box with no gh" "a freshness check must not cost more than the staleness it prevents"
[[ "$OUT" != *"⚠️"* ]] && ok_t "D4 ...with no warning banner: two agreeing records is not a warning" || bad_t "D4 spurious banner on a corroborated packet"
# D5/D6 — THE SPECIMEN'S OWN TELL, WITH NO CREDENTIAL. The store says the
# rejected sha; the maker's line says the fix. Disagreement is enough.
_PR_PAIR=""; IDENT=$(seed "$REJECTED" "$REJECTED"); OUT=$(pkt "$IDENT")
[[ "$(field "$OUT" PR_HEAD_CHECK)" == unread-contradicted* ]] \
  && ok_t "D5 the two records DISAGREEING is caught with no forge at all — the tell quinn used" || bad_t "D5 disagreement was not caught" "$(field "$OUT" PR_HEAD_CHECK)"
[[ "$OUT" != *"do NOT re-run the unflagged lines"* && "$OUT" == *"DISAGREE (DIVE-4831)"* ]] \
  && ok_t "D6 ...and the instruction is withdrawn and the disagreement named" || bad_t "D6 a contradicted packet still told the grader to stop checking"
# D7 — nothing to corroborate with: no DELIVERED-SHA line at all.
_PR_PAIR=""; IDENT=$(seed "$FIXED" "$FIXED")
db "UPDATE tasks SET result='CHANGED: src/x.sh' WHERE ident=$(sqlq "$IDENT");"
OUT=$(pkt "$IDENT")
[[ "$(field "$OUT" PR_HEAD_CHECK)" == unread* && "$OUT" != *"do NOT re-run the unflagged lines"* && "$OUT" == *"never 'matched'"* ]] \
  && ok_t "D7 with NO second record and no forge the packet is plainly 'unread' and claims nothing" || bad_t "D7 unconfirmed packet over-claimed" "$(field "$OUT" PR_HEAD_CHECK)"

echo "── E. the table's own header sha is checked independently ──"
_PR_PAIR="${FIXED}|"; IDENT=$(seed "$FIXED" "$REJECTED"); OUT=$(pkt "$IDENT")
[[ "$(field "$OUT" PR_HEAD_CHECK)" == match* ]] \
  && ok_t "E0/PRECONDITION: the sha check itself says match — so E1 grades the TABLE, not the sha" || bad_t "E0 precondition" "$(field "$OUT" PR_HEAD_CHECK)"
[[ "$OUT" != *"do NOT re-run the unflagged lines"* && "$OUT" == *"NOT CONFIRMED AT THIS SHA"* ]] \
  && ok_t "E1 a table computed at a DIFFERENT sha withdraws the instruction on its own (the re-delivery that did not recompute)" || bad_t "E1 a stale table rode a matched packet" "both conditions must license the clause"

echo "── F. THE SPECIMEN, end to end ──"
_PR_PAIR="${FIXED}|"; IDENT=$(seed "$REJECTED" "$REJECTED"); OUT=$(pkt "$IDENT")
[[ "$OUT" == *'|| nflags=0'* ]] \
  && ok_t "F1 the served diff CARRIES the fix the reject demanded — which is exactly what the measured DIVE-4825 packet omitted" || bad_t "F1 the packet still serves the rejected tree" "the specimen reproduces at head"
[[ "$OUT" == *"grep -c . <<<"* ]] \
  && ok_t "F1b CONTROL: ...and the diff is a real diff of this lineage, not an empty one that would pass F1 vacuously" || bad_t "F1b the diff is empty" "F1 proves nothing"

echo "── G. the goal text defers to the packet instead of pre-empting it ──"
_gp=$(_grader_method_clause "$IDENT" temp 2>/dev/null || printf '')
if [[ -z "$_gp" ]]; then
  _gp=$(declare -f | grep -c PR_HEAD_CHECK)
  [[ "$_gp" -gt 0 ]] && ok_t "G1 the grader's computed-table clause names PR_HEAD_CHECK" || bad_t "G1 goal text not reachable in this context" "clause helper not found"
else
  [[ "$_gp" == *"PR_HEAD_CHECK"* ]] \
    && ok_t "G1 the grader's goal text sends it to PR_HEAD_CHECK before it trusts the table" || bad_t "G1 goal text still pre-empts the packet" "${_gp:0:160}"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAILN"
exit $(( FAILN > 0 ? 1 : 0 ))
