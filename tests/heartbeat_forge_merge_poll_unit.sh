#!/usr/bin/env bash
# DIVE-4701 — the heartbeat polls the bound pull request of every row in
# graded->merge and RECORDS a landing the maintainer made on the forge.
#
# WHAT THIS GRADES. `_hb_forge_merge_sweep` (src/cmd_heartbeat.sh) is executed
# for real, on a throwaway tasks.db, over a stubbed `_gate_gh` — the same rail
# stub tests/task_merge_already_merged_unit.sh uses, and for the same reason: it
# keeps the TOKEN argument observable, which is the claim that the poll needs no
# machine account. `_merge_landed_probe`, `_task_merge_landed_record` and
# `_task_merge_landed_handoff` are the real ones out of src/task/delivery.sh.
#
# THE THREE THINGS THAT MUST NOT HAPPEN, each an arm below: it must not close a
# row (DIVE-4520 — an owed clause in a PASS verdict survives the merge); it must
# not write anything on an OPEN pull request; and it must not write anything on
# a rail that could not answer (DIVE-2318/DIVE-2414 — a non-verdict is not a
# negative). Each is paired with a MUTATION arm that deletes the guard and shows
# the assertion going red, because a negative control nothing can break is not a
# control (DIVE-4623).
#
# Run: bash tests/heartbeat_forge_merge_poll_unit.sh   (no root, no network).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/hb-forge-merge.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh \
         cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
AUDIT_LOG="$TMP/audit.log"     # never the host's /var/log/5dive layout
JSON_MODE=1
mkdir -p "$TASKS_DIR"
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"   # keep the real audit path live
set +e
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

PR=https://github.com/5dive-ai/ops/pull/20
SHA=8a1b2c3d4e5f60718293a4b5c6d7e8f901234567
AT=2026-09-20T19:08:15Z

# --- stubs -------------------------------------------------------------------
# The rail. The token is recorded to a FILE: every call is made inside a command
# substitution, which is a subshell, so a variable set there never reaches here.
TOKF="$TMP/tok"; : >"$TOKF"
READS="$TMP/reads"; : >"$READS"
_gate_gh_payload=""; _gate_gh_rc=0
_gate_gh() {                      # <tok> <timeout> gh-args...
  printf '[%s]' "$1" >"$TOKF"
  printf '%s\n' "${4:-}" >>"$READS"   # the pr ref this call asked about
  shift 2
  [[ -n "$_gate_gh_payload" ]] && printf '%s\n' "$_gate_gh_payload"
  return "$_gate_gh_rc"
}
SEND_LOG="$TMP/sent"; : >"$SEND_LOG"
cmd_send()            { printf '%s\n' "$1" >>"$SEND_LOG"; }
_task_agent_channel() { return 0; }
HB_LOG="$TMP/hb.log"; : >"$HB_LOG"
_hb_log()             { printf '%s\n' "$*" >>"$HB_LOG"; }
# The audit sink. `_task_store_audit_log` is the DIVE-2010 fence and routes to
# `audit_log` when the store is declared prod (it is, above) — so stubbing
# `audit_log` keeps the REAL fence in the path and still captures the row.
AUDIT_CALLS="$TMP/audit-calls"; : >"$AUDIT_CALLS"
audit_log()           { printf '%s\n' "$*" >>"$AUDIT_CALLS"; return 0; }

# A graded->merge row: graded PASS by a seat that is not the maker, a live
# binding, and a merge hold on the seat that can push. This is the exact shape
# `_TASKS_TFV_SQL` calls the MERGING stage.
mk_merging() {   # -> echoes id
  db "INSERT INTO tasks (title, priority, assignee, created_by, kind, status,
                         maker_agent, verifier, graded_by, graded_verdict, graded_at,
                         delivery_ref, merge_owner, merge_hold_reason)
      VALUES ('a graded row awaiting a merge', 'high', 'dev', 'lodar', 'standard', 'in_progress',
              'dev', 'quinn', 'quinn', 'pass', datetime('now','-2 hours'),
              $(sqlq "$PR"), 'ops', 'merger:no-push-right');
      SELECT last_insert_rowid();"
}
reset() {
  db "DELETE FROM tasks;"
  : >"$SEND_LOG"; : >"$READS"; : >"$HB_LOG"; : >"$TOKF"; : >"$AUDIT_CALLS"
  rm -f "$TMP/forge-merge-poll.reading"
  _gate_gh_payload=""; _gate_gh_rc=0
  _HB_FORGE_MERGE_POLL=on
}
snap() { db "SELECT COALESCE(merge_landed_sha,'-')||' '||COALESCE(merge_landed_by,'-')||' '||COALESCE(merge_owner,'-')||' '||COALESCE(assignee,'-')||' '||status||' '||COALESCE(done_at,'-') FROM tasks WHERE id=${1};"; }

# --- Case 1: a MERGED pull request -> the landing is recorded -----------------
reset
id=$(mk_merging)
_gate_gh_payload="MERGED|$SHA|$AT"
_hb_forge_merge_sweep
read -r g_sha g_by g_owner g_asgn g_st g_done < <(snap "$id")
[[ "$g_sha" == "$SHA" ]] \
  && ok_t "C1 the merge sha the forge reported is recorded on the row" \
  || bad_t "C1 merge_landed_sha" "got '$g_sha'"
[[ "$g_by" == "forge-poll" ]] \
  && ok_t "C1a THE ACTOR IS THE POLLER, not this box's seat — a record naming a seat would credit somebody who was not there with the maintainer's merge" \
  || bad_t "C1a merge_landed_by" "got '$g_by'"
[[ "$g_owner" == "-" ]] \
  && ok_t "C1b the merge hold is RETIRED — a landed pull request is owed a merge by nobody, so the board stops painting an action no seat can take" \
  || bad_t "C1b merge_owner retired" "got '$g_owner'"
[[ "$(db "SELECT CASE WHEN (${_TASKS_TFV_SQL}) THEN 1 ELSE 0 END FROM tasks WHERE id=${id};")" == "0" ]] \
  && ok_t "C1c ...and the row has LEFT the merging stage, which is what stops it being re-dispatched to a seat with nothing to do" \
  || bad_t "C1c still in merging stage" ""
[[ "$g_asgn" == "quinn" ]] \
  && ok_t "C1d the row is handed to the seat whose close is ungated on a loop row (its verifier)" \
  || bad_t "C1d handoff" "assignee='$g_asgn'"

# --- Case 2: IT DOES NOT CLOSE ------------------------------------------------
[[ "$g_st" == "in_progress" && "$g_done" == "-" ]] \
  && ok_t "C2 THE NARROWING: the row is NOT closed — a merged pull request is not automatically a finished row (DIVE-4520), so the close stays a judgement a seat makes" \
  || bad_t "C2 sweep closed the row" "status=$g_st done_at=$g_done"
[[ "$(cat "$TOKF")" == "[]" ]] \
  && ok_t "C2a the read went out with an EMPTY token — no machine account was resolved to ask what a pull request IS" \
  || bad_t "C2a credential-free read" "token seen '$(cat "$TOKF")'"
grep -qx 'quinn' "$SEND_LOG" \
  && ok_t "C2b the seat that owes the close is told, once" \
  || bad_t "C2b closer not pinged" "sent=[$(tr '\n' ',' <"$SEND_LOG")]"
grep -q 'task.merge-landed' "$AUDIT_CALLS" 2>/dev/null \
  && ok_t "C2c ...and the landing is in the audit log" \
  || bad_t "C2c no audit row" "$(tail -3 "$AUDIT_CALLS" 2>/dev/null)"
grep -q 'actor=forge-poll' "$AUDIT_CALLS" 2>/dev/null \
  && ok_t "C2d ...naming the poller as the actor, so the trail does not credit a seat" \
  || bad_t "C2d audit actor" "$(tail -3 "$AUDIT_CALLS" 2>/dev/null)"

# --- Case 3: an OPEN pull request changes NOTHING -----------------------------
reset
id=$(mk_merging)
before=$(snap "$id")
_gate_gh_payload="OPEN|null|null"
_hb_forge_merge_sweep
[[ "$(snap "$id")" == "$before" ]] \
  && ok_t "C3 NEGATIVE CONTROL — an OPEN pull request leaves the row byte-identical" \
  || bad_t "C3 open row mutated" "before=[$before] after=[$(snap "$id")]"
[[ "$(wc -l <"$READS")" == "1" ]] \
  && ok_t "C3a ...and it was read exactly once, so the next tick asks again (no stamp is consumed)" \
  || bad_t "C3a read count" "$(cat "$READS")"
[[ "$(sed -n 's/^class=//p' "$TMP/forge-merge-poll.reading")" == "ok" ]] \
  && ok_t "C3b an open pull request is a VERDICT, not an unreadable rail — the reading doctor reads says ok" \
  || bad_t "C3b reading class" "$(cat "$TMP/forge-merge-poll.reading" 2>/dev/null)"

# --- Case 4: a rail that could not answer changes NOTHING ---------------------
reset
id=$(mk_merging)
before=$(snap "$id")
_gate_gh_payload=""; _gate_gh_rc=1
_hb_forge_merge_sweep
[[ "$(snap "$id")" == "$before" ]] \
  && ok_t "C4 NEGATIVE CONTROL — an unreadable rail leaves the row byte-identical (a non-verdict is not a negative)" \
  || bad_t "C4 unreadable row mutated" "before=[$before] after=[$(snap "$id")]"
[[ "$(sed -n 's/^class=//p' "$TMP/forge-merge-poll.reading")" == "unreadable" ]] \
  && ok_t "C4a ...and it is SAID ONCE in a reading doctor reads, not on every tick (DIVE-4619)" \
  || bad_t "C4a reading class" "$(cat "$TMP/forge-merge-poll.reading" 2>/dev/null)"
[[ ! -s "$HB_LOG" ]] \
  && ok_t "C4b ...and the tick log stays silent about it — a per-tick line for a standing condition is how a tick log stops being read" \
  || bad_t "C4b tick log spoke" "$(cat "$HB_LOG")"

# --- Case 5: a row with NO delivery_ref is never read -------------------------
reset
db "INSERT INTO tasks (title, priority, assignee, created_by, kind, status,
                       maker_agent, verifier, graded_by, graded_verdict, graded_at)
    VALUES ('graded, nothing bound', 'high', 'dev', 'lodar', 'standard', 'in_progress',
            'dev', 'quinn', 'quinn', 'pass', datetime('now','-2 hours'));"
_gate_gh_payload="MERGED|$SHA|$AT"
_hb_forge_merge_sweep
[[ ! -s "$READS" ]] \
  && ok_t "C5 a row with no delivery_ref is NEVER read — the one thing this sweep does that leaves the box is not done on a row with nothing bound" \
  || bad_t "C5 read a row with no binding" "$(cat "$READS")"

# --- Case 6: a row that is not in the merging stage is never read -------------
reset
db "INSERT INTO tasks (title, priority, assignee, created_by, kind, status,
                       maker_agent, verifier, delivery_ref)
    VALUES ('delivered but UNGRADED', 'high', 'dev', 'lodar', 'standard', 'in_progress',
            'dev', 'quinn', $(sqlq "$PR"));"
_gate_gh_payload="MERGED|$SHA|$AT"
_hb_forge_merge_sweep
[[ ! -s "$READS" ]] \
  && ok_t "C6 SCOPED TO graded->merge — a delivered-but-ungraded row is not polled, so no landing is recorded against a hold nobody placed" \
  || bad_t "C6 polled an ungraded row" "$(cat "$READS")"

# --- Case 7: a recorded landing is read ONCE and never again ------------------
reset
id=$(mk_merging)
_gate_gh_payload="MERGED|$SHA|$AT"
_hb_forge_merge_sweep
: >"$READS"
_hb_forge_merge_sweep
[[ ! -s "$READS" ]] \
  && ok_t "C7 COST: once a landing is recorded the row leaves the polled population — one read per landing, not one per tick forever" \
  || bad_t "C7 re-read a recorded landing" "$(cat "$READS")"

# --- Case 8: the off switch ---------------------------------------------------
reset
id=$(mk_merging)
before=$(snap "$id")
_gate_gh_payload="MERGED|$SHA|$AT"
_HB_FORGE_MERGE_POLL=off
_hb_forge_merge_sweep
[[ ! -s "$READS" && "$(snap "$id")" == "$before" ]] \
  && ok_t "C8 FIVEDIVE_FORGE_MERGE_POLL=off reads nothing and writes nothing" \
  || bad_t "C8 off switch" "reads=[$(cat "$READS")]"
_HB_FORGE_MERGE_POLL=on

# --- Case 9: a partial tree says so rather than reading as 'nothing merged' ---
reset
id=$(mk_merging)
_gate_gh_payload="MERGED|$SHA|$AT"
_probe_save=$(declare -f _merge_landed_probe)
unset -f _merge_landed_probe
_hb_forge_merge_sweep
eval "$_probe_save"
grep -q 'not loaded in this context' "$HB_LOG" \
  && ok_t "C9 a tree without the merge-landing helpers SAYS the sweep did not run — a silent skip is indistinguishable from 'nothing had merged'" \
  || bad_t "C9 silent skip" "$(cat "$HB_LOG")"
[[ "$(db "SELECT COALESCE(merge_landed_sha,'-') FROM tasks WHERE id=${id};")" == "-" ]] \
  && ok_t "C9a ...and it wrote nothing" || bad_t "C9a wrote on a partial tree" ""

# --- Case 10: the doctor finding ---------------------------------------------
# shellcheck source=/dev/null
source "$SRC/cmd_doctor.sh" 2>/dev/null
DOCTOR_ROWS="$TMP/doctor"; : >"$DOCTOR_ROWS"
doctor_add() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >>"$DOCTOR_ROWS"; }
rm -f "$TMP/forge-merge-poll.reading"
doctor_check_forge_merge_poll
grep -q '^creds|forge-merge-poll|ok|.*no reading' "$DOCTOR_ROWS" \
  && ok_t "C10 a box with NO reading is reported 'not measured', never a clean bill" \
  || bad_t "C10 no-reading finding" "$(cat "$DOCTOR_ROWS")"
: >"$DOCTOR_ROWS"
_hb_forge_merge_record_reading unreadable 3 0 2 "first was ${PR}"
doctor_check_forge_merge_poll
grep -q '^creds|forge-merge-poll|warn|' "$DOCTOR_ROWS" \
  && ok_t "C10a an unreadable rail is ONE doctor warning (the DIVE-4619 shape: the sweep records, the health check reads)" \
  || bad_t "C10a unreadable finding" "$(cat "$DOCTOR_ROWS")"
: >"$DOCTOR_ROWS"
_hb_forge_merge_record_reading ok 3 1 0 ""
doctor_check_forge_merge_poll
grep -q '^creds|forge-merge-poll|ok|the forge merge poll read all 3' "$DOCTOR_ROWS" \
  && ok_t "C10b a measured pass reads differently from an absent measurement" \
  || bad_t "C10b ok finding" "$(cat "$DOCTOR_ROWS")"
unset -f doctor_add

# --- MUTANTS: each guard is shown to be load-bearing (DIVE-4623) --------------
# Each mutant is the shipped sweep with ONE guard removed, re-defined in this
# shell, and the paired arm above must go RED on it. A guard whose removal
# changes nothing is not a guard.
# A mutant that did not actually change anything grades NOTHING while reporting
# a pass, which is the DIVE-4428 iteration-2 failure exactly. So this refuses
# unless the sed CHANGED the extracted function and the result is still bash.
mutate_sweep() {  # <sed-expr>  -- redefine _hb_forge_merge_sweep from a mutant
  local f="$TMP/mut.sh" g="$TMP/mut-base.sh"
  sed -n '/^_hb_forge_merge_sweep() {$/,/^}$/p' "$SRC/cmd_heartbeat.sh" >"$g"
  [[ -s "$g" ]] || return 1
  sed "$1" "$g" >"$f"
  cmp -s "$g" "$f" && return 1          # the mutation did not land
  bash -n "$f" || return 1
  # shellcheck source=/dev/null
  source "$f"
}
_sweep_orig=$(declare -f _hb_forge_merge_sweep)

# M1 — the UNKNOWN arm falls through to the MERGED write.
reset
id=$(mk_merging)
mutate_sweep 's/^      \*)$/      *) : ;;\n      _NEVER_)/' \
  && ok_t "M1a the mutant that lets an unreadable rail fall through to the write LANDED and is valid bash" \
  || bad_t "M1a mutant build" "$(cat "$TMP/mut.sh" | head -5)"
_gate_gh_payload=""; _gate_gh_rc=1
_hb_forge_merge_sweep
[[ "$(db "SELECT COALESCE(merge_landed_sha,'-') FROM tasks WHERE id=${id};")" != "-" ]] \
  && ok_t "M1 MUTANT — C4 is RED on it: without the UNKNOWN arm an unreachable GitHub records a landing that nobody reported. The guard is load-bearing" \
  || bad_t "M1 mutant not red (C4 grades nothing)" "row unchanged even without the guard"
eval "$_sweep_orig"

# M2 — the stage predicate removed: the sweep polls rows that are not merging,
# and re-polls one whose landing it already recorded. C6 and C7 both ride on that
# one predicate, so one mutant grades both.
reset
id=$(mk_merging)
_gate_gh_payload="MERGED|$SHA|$AT"; _gate_gh_rc=0
_hb_forge_merge_sweep                      # records the landing; row leaves the stage
db "INSERT INTO tasks (title, priority, assignee, created_by, kind, status,
                       maker_agent, verifier, delivery_ref)
    VALUES ('delivered but UNGRADED', 'high', 'dev', 'lodar', 'standard', 'in_progress',
            'dev', 'quinn', $(sqlq "$PR"));"
mutate_sweep 's#^ *WHERE ([$]{_TASKS_TFV_SQL});.*#                WHERE 1;" 2>/dev/null)#' \
  && ok_t "M2a the mutant that drops the merging-stage predicate LANDED and is valid bash" \
  || bad_t "M2a mutant build" "sed did not change the function, or the result is not bash"
: >"$READS"
_hb_forge_merge_sweep
(( $(wc -l <"$READS") >= 2 )) \
  && ok_t "M2 MUTANT — C6 and C7 are RED on it: without the stage predicate the sweep reads an ungraded row AND re-reads a landing it already recorded. Both the scope and the cost bound are load-bearing" \
  || bad_t "M2 mutant not red (C6/C7 grade nothing)" "reads=[$(cat "$READS")]"
eval "$_sweep_orig"

# M3 — the close that must not happen. Nothing in the shipped sweep closes a
# row, so the mutant ADDS one: C2 must catch it, or C2 is grading an absence
# that no edit could ever introduce.
reset
id=$(mk_merging)
mutate_sweep "s#^    n_landed=\$((n_landed+1))#    n_landed=\$((n_landed+1)); db \"UPDATE tasks SET status='done', done_at=datetime('now') WHERE id=\${id};\"#" \
  && ok_t "M3a the mutant that closes the row on a landing LANDED and is valid bash" \
  || bad_t "M3a mutant build" ""
_gate_gh_payload="MERGED|$SHA|$AT"; _gate_gh_rc=0
_hb_forge_merge_sweep
read -r _ _ _ _ m_st m_done < <(snap "$id")
[[ "$m_st" == "done" && "$m_done" != "-" ]] \
  && ok_t "M3 MUTANT — C2 is RED on it: a sweep that closed the row would be caught. C2 grades a real property, not an absence nothing could break" \
  || bad_t "M3 mutant not red (C2 grades nothing)" "status=$m_st done_at=$m_done"
eval "$_sweep_orig"

printf -- '-----\nheartbeat_forge_merge_poll: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
