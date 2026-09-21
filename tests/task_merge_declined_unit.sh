#!/usr/bin/env bash
# DIVE-4778 — THE MERGING STAGE'S SECOND EXIT: `task merge-declined`.
#
# WHAT THIS GRADES. Before this row the MERGING stage (`_TASKS_TFV_SQL`) had
# exactly ONE exit that a seat could reach: a LANDING recorded by the forge's own
# probe (DIVE-4654). A row whose bound pull request is never going to merge — held,
# superseded, or re-pointed at a different repository — could not reach it, and
# nothing else released merge standing either: `task merge` is grader-only and
# `enqueuePullRequest` refuses a draft, `task merge-landed` is refused by
# `_merge_landed_read` (no mergedAt), and `task reject` is wrong (nothing is red)
# and destructive at the iteration cap. So the heartbeat woke the merge owner every
# tick at a seat with no available move. Measured on DIVE-4773: FIVE ops merge
# dispatches from ~10:00Z on 2026-09-21, five declines, zero moves, with DIVE-4370
# standing in the same shape. History:
# community/wiki/a-draft-flag-is-a-hold-the-merge-dispatch-cannot-see.md.
#
# THE BAR THE VERB MUST CLEAR, and the reason half these arms exist: it must NOT
# become a way to assert a landing the forge did not report. The rail's safety
# property is that only the probe's own answer writes `merge_landed_*`. A decline
# writes a DIFFERENT fact — this row is owed a merge by NOBODY — into its own four
# columns and must never touch those. Arms D1–D3 grade exactly that, in both
# directions: the decline writes no landing, AND a recorded landing is not
# declinable.
#
# MUTATION ARMS (M1–M5) revert each deliberate divergence in the shipped source
# and assert the property goes RED. A harness that only grades the fixed tree
# cannot tell a fix from a coincidence.
#
# Run: bash tests/task_merge_declined_unit.sh (no root, no network, no gh)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/dive4778.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0; mkdir -p "$TASKS_DIR"; set +e

audit_log() { return 0; }
registry_read() { printf '%s' '{"agents":{}}'; }
# NO NETWORK, ASSERTED NOT ASSUMED. `merge-declined` must reach its decision
# without asking GitHub anything — that is the whole difference between it and
# `merge-landed`. Any call to the probe here is a defect, so the stub records it
# and arm D2 reds on a non-empty log.
PROBE_LOG="$TMP/probe"; : >"$PROBE_LOG"
_merge_landed_probe() { printf '%s\n' "CALLED:$*" >>"$PROBE_LOG"; printf 'UNKNOWN'; }
_merge_landed_read()  { printf '%s\n' "CALLED:$*" >>"$PROBE_LOG"; return 1; }

tasks_db_init
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
addt()  { ( JSON_MODE=1; cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
# The verb keys on IDENT, exactly as `merge-landed` does, so the harness resolves
# the fixture's numeric id to its ident on every call. An earlier version passed
# the id and every arm below C failed with "no task 1" — including the mutation
# arms, which reported a confident RED that graded nothing.
idnt()  { db "SELECT COALESCE(ident,'') FROM tasks WHERE id=${1};"; }
run()   { local i; i=$(idnt "$1"); shift; ( cmd_task_merge_declined "$i" "$@" ) >"$TMP/out" 2>&1; printf '%s' "$?"; }
col()   { db "SELECT COALESCE($1,'<NULL>') FROM tasks WHERE id=${2};"; }
tfv()   { db "SELECT CASE WHEN (${_TASKS_TFV_SQL}) THEN 1 ELSE 0 END FROM tasks WHERE id=${1};"; }

ME=$(task_actor "")   # this harness's actor == the GRADER/merge owner in the fixture
# A RESERVED FAKE, never a real fleet seat: on agent-dev, ME=="dev", so a maker
# hardcoded "dev" makes assignee==verifier and `task add` correctly refuses EVERY
# fixture — a wall of red that reads as a product regression (DIVE-3098's harness
# was bitten by exactly this). Asserted, not assumed.
MAKER="fixturemaker"
[[ "$MAKER" != "$ME" ]] || { printf 'FATAL: fixture maker (%s) == harness actor (%s).\n' "$MAKER" "$ME" >&2; exit 1; }
PR1="https://github.com/5dive-ai/5dive/pull/1071"
PR2="https://github.com/5dive-ai/5dive-ui/pull/4"

# mkrow [ref] — one row sitting in the MERGING stage: delivered by MAKER, graded
# PASS by ME, binding bound, merge_owner naming ME. Built by UPDATE rather than by
# driving the verbs so the fixture is the STATE under test and not a second
# integration test of `task verify`.
mkrow() {
  local ref="${1:-$PR1}" id
  id=$(addt "merging-stage row" --assignee="$MAKER" --verifier="$ME" --priority=medium)
  [[ "$id" =~ ^[0-9]+$ ]] || { bad_t "FIXTURE could not be created" "addt returned '$id'"; printf '0'; return; }
  db "UPDATE tasks SET maker_agent='${MAKER}', assignee='${MAKER}', verifier='${ME}',
        status='in_progress', kind='standard',
        handoff_delivered_at=datetime('now','-40 minutes'),
        graded_at=datetime('now','-10 minutes'),
        graded_verdict_at=datetime('now','-10 minutes'),
        graded_verdict='pass', graded_by='${ME}',
        delivery_ref='${ref}', merge_owner='${ME}',
        merge_hold_reason='graded-pass-no-rail'
      WHERE id=${id};"
  printf '%s' "$id"
}

echo "── F: the fixture really is in the merging stage (or every arm below is vacuous) ──"
R=$(mkrow)
[[ "$(tfv "$R")" == "1" ]] \
  && ok_t "F1 fixture matches _TASKS_TFV_SQL before the decline" \
  || bad_t "F1 fixture is in the merging stage" "tfv=$(tfv "$R") — every arm below would be vacuous"
[[ "$(col merge_owner "$R")" == "$ME" ]] \
  && ok_t "F2 fixture names a merge owner ($ME)" || bad_t "F2 merge_owner set"

echo "── A: the reason IS the record — no unexplained decline ──"
rc=$(run "$R"); out=$(cat "$TMP/out")
[[ "$rc" != "0" ]] && ok_t "A1 a decline with no --reason is REFUSED (rc=$rc)" \
  || bad_t "A1 --reason is required" "rc=0: $out"
[[ "$(col merge_declined_at "$R")" == "<NULL>" && "$(col merge_owner "$R")" == "$ME" ]] \
  && ok_t "A2 the refused decline wrote NOTHING (no clock, hold intact)" \
  || bad_t "A2 refusal is a no-op" "at=$(col merge_declined_at "$R") owner=$(col merge_owner "$R")"
rc=$(run "$R" --reason="   ")
[[ "$rc" != "0" ]] && ok_t "A3 an ALL-WHITESPACE reason is refused too (not just an absent flag)" \
  || bad_t "A3 whitespace reason refused" "rc=0"

echo "── B: standing — the row's own seats, not the board ──"
S=$(mkrow)
rc=$( ( ACTOR_BOARD=""; task_actor_claim() { ACTOR_BOARD="stranger-seat"; }
        cmd_task_merge_declined "$(idnt "$S")" --reason="not mine to decline" ) >"$TMP/out" 2>&1; printf '%s' "$?" )
[[ "$rc" != "0" ]] && ok_t "B1 a seat the row does not name is REFUSED (rc=$rc)" \
  || bad_t "B1 stranger refused" "rc=0: $(cat "$TMP/out")"
[[ "$(col merge_declined_at "$S")" == "<NULL>" ]] \
  && ok_t "B2 the refused stranger wrote nothing" || bad_t "B2 stranger wrote nothing"

echo "── C: the happy path — the stage exits, the hold retires, the maker gets the row ──"
rc=$(run "$R" --reason="main ruled the page lands in 5dive-ai/5dive-ui, not core"); out=$(cat "$TMP/out")
[[ "$rc" == "0" ]] && ok_t "C1 a decline WITH a reason succeeds" || bad_t "C1 decline succeeds" "rc=$rc: $out"
[[ "$(tfv "$R")" == "0" ]] \
  && ok_t "C2 THE ROW HAS LEFT THE MERGING STAGE (_TASKS_TFV_SQL is false)" \
  || bad_t "C2 stage exit" "tfv still 1 — the dispatch would fire again next tick"
[[ "$(col merge_owner "$R")" == "<NULL>" && "$(col merge_hold_reason "$R")" == "<NULL>" ]] \
  && ok_t "C3 merge_owner and merge_hold_reason are RETIRED" \
  || bad_t "C3 hold retired" "owner=$(col merge_owner "$R") why=$(col merge_hold_reason "$R")"
[[ "$(col merge_declined_reason "$R")" == *"5dive-ui"* ]] \
  && ok_t "C4 the reason is stored verbatim" || bad_t "C4 reason stored" "got $(col merge_declined_reason "$R")"
[[ "$(col merge_declined_by "$R")" == "$ME" && "$(col merge_declined_ref "$R")" == "$PR1" ]] \
  && ok_t "C5 the decline records WHO and against WHICH binding" \
  || bad_t "C5 by/ref recorded" "by=$(col merge_declined_by "$R") ref=$(col merge_declined_ref "$R")"
# THE HANDOFF GOES TO THE MAKER, NOT THE VERIFIER — the divergence from
# merge-landed, and the one a copy-paste would get wrong. A landed row is owed a
# CLOSE (the verifier's act); a declined row is owed a RE-POINTED BINDING, which
# only the maker can deliver.
[[ "$(col assignee "$R")" == "$MAKER" ]] \
  && ok_t "C6 the row is handed to the MAKER (the seat that can re-point the binding)" \
  || bad_t "C6 handoff target" "assignee=$(col assignee "$R"), expected the maker $MAKER"
[[ "$(col status "$R")" == "in_progress" ]] \
  && ok_t "C7 the row is NOT closed — a decline is not a cancellation" || bad_t "C7 row stays open"

echo "── D: NO LANDING IS ASSERTED (the bar the row set) ──"
land=$(db "SELECT COALESCE(merge_landed_at,'')||'|'||COALESCE(merge_landed_sha,'')||'|'||COALESCE(merge_landed_by,'')||'|'||COALESCE(merge_landed_ref,'') FROM tasks WHERE id=${R};")
[[ "$land" == "|||" ]] \
  && ok_t "D1 all four merge_landed_* columns are STILL EMPTY after a decline" \
  || bad_t "D1 no landing written" "merge_landed_* = '$land' — the decline asserted a landing"
[[ "$(db "SELECT CASE WHEN (${_TASKS_MERGE_LANDED_SQL}) THEN 1 ELSE 0 END FROM tasks WHERE id=${R};")" == "0" ]] \
  && ok_t "D1b _TASKS_MERGE_LANDED_SQL is false — no reader can mistake this for a merge" \
  || bad_t "D1b landed predicate false"
[[ ! -s "$PROBE_LOG" ]] \
  && ok_t "D2 GITHUB WAS NEVER ASKED — the forge probe was not called once" \
  || bad_t "D2 no probe call" "probe log: $(cat "$PROBE_LOG")"
L=$(mkrow)
db "UPDATE tasks SET merge_landed_at=datetime('now'), merge_landed_sha='deadbeefcafe',
      merge_landed_by='ops', merge_landed_ref='${PR1}' WHERE id=${L};"
before=$(col merge_landed_sha "$L")
rc=$(run "$L" --reason="trying to talk a landing back")
[[ "$rc" != "0" ]] && ok_t "D3 a RECORDED LANDING cannot be declined (rc=$rc)" \
  || bad_t "D3 landed row refused" "rc=0: $(cat "$TMP/out")"
[[ "$(col merge_landed_sha "$L")" == "$before" && "$(col merge_declined_at "$L")" == "<NULL>" ]] \
  && ok_t "D3b the refused decline overwrote nothing on the landed row" || bad_t "D3b landed row untouched"

echo "── E: binding-scoped, idempotent, and refused where the stage is not ──"
was=$(col merge_declined_at "$R")
rc=$(run "$R" --reason="second read of the same board"); out=$(cat "$TMP/out")
[[ "$rc" == "0" ]] && ok_t "E1 a second run on the SAME binding is not a failure" || bad_t "E1 idempotent rc" "rc=$rc"
[[ "$(col merge_declined_at "$R")" == "$was" && "$(col merge_declined_reason "$R")" == *"5dive-ui"* ]] \
  && ok_t "E2 ...and it rewrites nothing (clock and reason unchanged)" \
  || bad_t "E2 idempotent write" "at=$(col merge_declined_at "$R")"
[[ "$out" == *"ALREADY RECORDED"* ]] && ok_t "E3 ...and says so" || bad_t "E3 already-recorded text" "$out"
# RE-POINTING THE BINDING RE-ENTERS THE STAGE. The decline was of a pull request,
# not of the row: the one act that makes it wrong must undo it.
db "UPDATE tasks SET delivery_ref='${PR2}', merge_owner='${ME}',
      handoff_delivered_at=datetime('now','-40 minutes') WHERE id=${R};"
[[ "$(tfv "$R")" == "1" ]] \
  && ok_t "E4 re-pointing delivery_ref RE-ENTERS the merging stage (the stale decline is scoped out)" \
  || bad_t "E4 binding-scoped exit" "tfv=0 after re-pointing — a stale decline swallowed the new PR"
N=$(mkrow); db "UPDATE tasks SET delivery_ref=NULL WHERE id=${N};"
rc=$(run "$N" --reason="nothing is bound")
[[ "$rc" != "0" ]] && ok_t "E5 a row with NO binding is refused" || bad_t "E5 unbound refused"
T=$(mkrow); db "UPDATE tasks SET status='done' WHERE id=${T};"
rc=$(run "$T" --reason="already terminal")
[[ "$rc" != "0" ]] && ok_t "E6 a terminal row is refused" || bad_t "E6 terminal refused"
U=$(mkrow); db "UPDATE tasks SET graded_at=NULL, graded_verdict=NULL WHERE id=${U};"
rc=$(run "$U" --reason="never graded")
[[ "$rc" != "0" ]] && ok_t "E7 an UNGRADED row is refused — this is not a way to disown a delivery" \
  || bad_t "E7 ungraded refused" "rc=0: $(cat "$TMP/out")"

echo "── G: the seats that read the row can SEE the decline ──"
shown=$( ( JSON_MODE=0; cmd_task_show "$(db "SELECT ident FROM tasks WHERE id=${L};")" ) 2>/dev/null )
D2ROW=$(mkrow); run "$D2ROW" --reason="superseded by the extracted repo" >/dev/null
IDENT=$(db "SELECT ident FROM tasks WHERE id=${D2ROW};")
shown=$( ( JSON_MODE=0; cmd_task_show "$IDENT" ) 2>/dev/null )
[[ "$shown" == *"MERGE DECLINED"* && "$shown" == *"superseded by the extracted repo"* ]] \
  && ok_t "G1 \`task show\` paints the decline and its reason in the merge_owner cell" \
  || bad_t "G1 task show paints it" "merge_owner cell: $(printf '%s' "$shown" | grep -i 'merge_owner' | head -1)"
[[ "$shown" == *"NO LANDING WAS ASSERTED"* ]] \
  && ok_t "G2 ...and says on the board that no landing was asserted" || bad_t "G2 board disclaims a landing"
# doctor's `graded-merge-held` class is derived from _TASKS_TFV_SQL, so the declined
# row must fall out of it with no second edit. That is the one-predicate property
# DIVE-4327 bought; asserted here because a future copy would silently lose it.
doc=$( ( JSON_MODE=1; cmd_task_doctor ) 2>/dev/null )
[[ "$doc" != *"\"$IDENT\""* || "$doc" != *"graded-merge-held"* ]] \
  && ok_t "G3 \`task doctor\` no longer calls the declined row an undispatchable graded-merge-held" \
  || bad_t "G3 doctor drops it" "still classed graded-merge-held"

echo "── H: the woken merge owner is TOLD the verb exists ──"
# The dispatch note is the FIRST text a merge owner reads. Five seats read the
# three-branch version of it on DIVE-4773 and found no move in it.
note=$(grep -c 'task merge-declined' src/cmd_heartbeat.sh)
[[ "${note:-0}" -ge 1 ]] \
  && ok_t "H1 the merge-owner wake note names \`task merge-declined\`" \
  || bad_t "H1 wake note names the verb" "a seat woken onto a held PR still has no move in the text it reads"
grep -q 'ruling dated AFTER the delivery' src/cmd_heartbeat.sh \
  && ok_t "H2 ...and tells the seat to read the row body for a ruling that postdates the delivery" \
  || bad_t "H2 wake note points at the body"
grep -q 'merge-declined' src/task/dispatch.sh \
  && ok_t "H3 the verb is registered AND listed in \`task --help\`" || bad_t "H3 registered+listed"

echo "── I: THE MIGRATION, not just the CREATE (DIVE-2512's tripwire) ──"
# A harness that only ever builds a FRESH store never executes `_tasks_db_migrate`,
# so a column declared in CREATE TABLE and forgotten in _TASKS_ADDITIVE_COLUMNS is
# green here and `no such column` on every live box. Asserted by taking the columns
# back off an EXISTING store and making the migration put them back.
MIGDB="$TMP/mig.db"
sqlite3 "$TASKS_DB" ".backup '$MIGDB'" 2>/dev/null
for c in merge_declined_at merge_declined_by merge_declined_ref merge_declined_reason; do
  sqlite3 "$MIGDB" "ALTER TABLE tasks DROP COLUMN $c;" 2>/dev/null
done
pre=$(sqlite3 "$MIGDB" "PRAGMA table_info(tasks);" 2>/dev/null | grep -c 'merge_declined_')
if [[ "${pre:-0}" -ne 0 ]]; then
  bad_t "I0 could not strip the columns from the fixture store" "this sqlite has no ALTER TABLE DROP COLUMN, so arm I1 would be vacuous (found $pre)"
else
  ok_t "I0 the four columns are OFF the pre-migration store (the arm is not vacuous)"
  ( TASKS_DB="$MIGDB" TASKS_DIR="$TMP" tasks_db_init ) >/dev/null 2>&1
  post=$(sqlite3 "$MIGDB" "PRAGMA table_info(tasks);" 2>/dev/null | grep -c 'merge_declined_')
  [[ "${post:-0}" -eq 4 ]]     && ok_t "I1 tasks_db_init MIGRATES all four onto an existing store (not just CREATE TABLE)"     || bad_t "I1 the migration adds the columns" "found $post of 4 — a live box would fail 'no such column' (DIVE-2512)"
fi

echo "── M: MUTATION ARMS — revert each divergence, assert the property reds ──"
# Each arm copies the shipped tree, reverts ONE deliberate divergence, and re-runs
# the property in a fresh bash. A property that stays green under its own mutation
# graded nothing.
mut() { # <name> <sed-expr> <file> <property-script> <expect-red-description>
  local name="$1" expr="$2" file="$3" prop="$4"
  local d="$TMP/mut-$RANDOM"; cp -r "$SRC" "$d"
  sed -i "$expr" "$d/$file" || { bad_t "M:$name could not apply the mutation" "sed failed"; return; }
  if cmp -s "$SRC/$file" "$d/$file"; then
    bad_t "M:$name THE MUTATION DID NOT APPLY" "the sed matched nothing, so this arm graded the UNMUTATED tree — a vacuous green"
    return
  fi
  local rc; MUTSRC="$d" MUTTMP="$TMP/mutdb-$RANDOM" bash -c "$prop" >/dev/null 2>&1; rc=$?
  [[ "$rc" != "0" ]] && ok_t "M:$name reverting it turns the property RED (rc=$rc)" \
    || bad_t "M:$name the property survived its own mutation" "green on a tree without the fix — this arm grades nothing"
}

# The property script, shared by every mutation arm: build the same fixture against
# $MUTSRC and assert (1) the decline succeeds, (2) the stage exits, (3) no landing.
read -r -d '' PROP <<PROPEOF
set -uo pipefail
SRC="\$MUTSRC"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh lib/actor.sh \
         cmd_task.sh cmd_org.sh cmd_heartbeat.sh; do source "\$SRC/\$f"; done
STATE_DIR="\$MUTTMP"; TASKS_DIR="\$STATE_DIR/tasks"; TASKS_DB="\$TASKS_DIR/tasks.db"
JSON_MODE=0; mkdir -p "\$TASKS_DIR"; set +e
audit_log() { return 0; }; registry_read() { printf '%s' '{"agents":{}}'; }
_merge_landed_probe() { printf 'UNKNOWN'; }; _merge_landed_read() { return 1; }
tasks_db_init
id=\$( ( JSON_MODE=1; cmd_task_add "mut row" --assignee="$MAKER" --verifier="$ME" --priority=medium ) 2>/dev/null | jq -r '.data.id' )
[[ "\$id" =~ ^[0-9]+\$ ]] || exit 9
db "UPDATE tasks SET maker_agent='$MAKER', assignee='$MAKER', verifier='$ME',
      status='in_progress', kind='standard',
      handoff_delivered_at=datetime('now','-40 minutes'),
      graded_at=datetime('now','-10 minutes'), graded_verdict_at=datetime('now','-10 minutes'),
      graded_verdict='pass', graded_by='$ME', delivery_ref='$PR1',
      merge_owner='$ME', merge_hold_reason='graded-pass-no-rail' WHERE id=\$id;"
[[ "\$(db "SELECT CASE WHEN (\${_TASKS_TFV_SQL}) THEN 1 ELSE 0 END FROM tasks WHERE id=\$id;")" == "1" ]] || exit 8
ident=\$(db "SELECT ident FROM tasks WHERE id=\$id;")
[[ -n "\$ident" ]] || exit 7
( cmd_task_merge_declined "\$ident" --reason="mutation arm" ) >/dev/null 2>&1 || exit 1
[[ "\$(db "SELECT CASE WHEN (\${_TASKS_TFV_SQL}) THEN 1 ELSE 0 END FROM tasks WHERE id=\$id;")" == "0" ]] || exit 2
[[ -z "\$(db "SELECT COALESCE(merge_landed_at,'') FROM tasks WHERE id=\$id;")" ]] || exit 3
[[ "\$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=\$id;")" == "$MAKER" ]] || exit 4
[[ -z "\$(db "SELECT COALESCE(merge_owner,'') FROM tasks WHERE id=\$id;")" ]] || exit 5
exit 0
PROPEOF

# M1 — the stage-exit conjunct itself. Without it the decline still writes its
# columns and the row NEVER LEAVES MERGING: the exact defect DIVE-4773 measured,
# now with a verb that looks like it worked.
mut "stage-exit-conjunct" 's|       AND NOT (${_TASKS_MERGE_DECLINED_SQL})||' 'lib/tasks_db.sh' "$PROP"
# M2 — binding scope. Dropping the `= delivery_ref` clause makes any decline, of
# any past pull request, exit the stage for a binding it never saw. It needs its
# OWN property: $PROP never re-points the delivery, so it is green either way —
# which is exactly what this arm reported until the property was written FOR the
# mutation instead of reused from the arm next door.
read -r -d '' SCOPE_TAIL <<SCOPEEOF
db "UPDATE tasks SET delivery_ref='$PR2', merge_owner='$ME',
      handoff_delivered_at=datetime('now','-40 minutes') WHERE id=\$id;"
[[ "\$(db "SELECT CASE WHEN (\${_TASKS_TFV_SQL}) THEN 1 ELSE 0 END FROM tasks WHERE id=\$id;")" == "1" ]] || exit 6
exit 0
SCOPEEOF
PROP_SCOPE="${PROP%exit 0}$SCOPE_TAIL"
mut "binding-scope" "s|       AND merge_declined_ref = delivery_ref|       AND 1=1|" 'lib/tasks_db.sh' "$PROP_SCOPE"
# M3 — the handoff target. Reverting it to merge-landed's verifier hands the row
# to the one seat that cannot re-point the binding.
mut "handoff-to-maker" 's|_task_merge_declined_handoff "$id" "$ident" "$asgn" "$maker"|_task_merge_declined_handoff "$id" "$ident" "$asgn" "$gb"|' 'task/delivery.sh' "$PROP"
# M4 — retiring the hold. Leaving merge_owner set paints the board with an action
# nobody can take, which is half of what the row was filed about.
mut "retire-the-hold" '/_task_merge_declined_record()/,/^}/ s|merge_owner=NULL,|merge_owner=merge_owner,|' 'task/delivery.sh' "$PROP"

printf '\n%s\n' "── $PASS pass, $FAIL fail ──"
[[ "$FAIL" -eq 0 ]]
