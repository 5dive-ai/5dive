#!/usr/bin/env bash
# DIVE-2235 — CLASS OVER TIER, across the auto-answer writers.
#
# Tier says how hard a gate is pushed at a person. It must not decide WHETHER a
# person answers it. Three writers can answer a gate with no human in the loop:
#
#   (1) _hb_gate_ttl_sweep  — 48h tier-1 TTL applies `recommend`
#   (2) cmd_task_need tier 0 — applies `recommend` at file time, never pings
#   (3) cmd_task_need OSS-21 — precedent auto-clear (graded in
#                              tests/gate_precedent_unit.sh, cases A10/A11)
#
# Before this change (1) excluded only 'secret', so a tier-1 APPROVAL applied its
# own recommendation after two days with no human anywhere near it. That fired
# live on DIVE-2224, where lodar's own escalation-floor decision was queued to
# self-approve from the recommendation of the agent who filed it.
#
# EVERY CASE HERE IS DIFFERENTIAL. A human-class assertion is paired with a
# 'decision' control run through the SAME code on the SAME tick, because the
# cheap way to pass "the approval was not auto-answered" is for the sweep to be
# broken, mis-predicated or never reached — and a lone negative cannot tell that
# apart from the fix working. The controls are what make the negatives mean
# something. Assertions read the RECORD (need_answered_by / need_answered_at /
# tier), never a command's exit status: the defect being graded is a false row,
# and every command involved exits 0 either way.
#
# Run: bash tests/gate_class_over_tier_unit.sh   (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# No 2>/dev/null — that swallows the helper's own stderr line, which IS the
# payload, and silently unnames all 210 harnesses at once.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/gate-class-over-tier.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init
# A fresh store gets the base CREATE TABLE only; the additive columns arrive via
# the ALTER migrations, which tasks_db_init runs on its second call. A one-shot
# harness has to migrate itself or pass 1 of the sweep dies on parked_at.
_tasks_db_migrate

# --- stubs: nothing leaves the box -------------------------------------------
cmd_send()            { return 0; }
_task_agent_channel() { return 0; }
_task_send_owner()    { return 0; }
task_need_notify()    { return 0; }
audit_log()           { return 0; }
AUDIT_ROWS="$TMP/audit_rows"; : >"$AUDIT_ROWS"
_task_store_audit_log() { printf '%s\n' "$*" >>"$AUDIT_ROWS"; return 0; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }

# ∅ IS NOT ONE STATE. field() renders COALESCE(col,'∅'), so '∅' is returned both
# when the column is NULL and when NO ROW MATCHED — and sqlite returns the empty
# set silently, rc 0. Every negative below ("was not auto-answered", "was not
# created") therefore reads ∅ identically against a fixture that was never built
# and against a guard that held. That is the DIVE-2114 vacuous-control shape, and
# it is not hypothetical here: this harness shipped with `>/tmp/gcot3.out`, a
# fixed path outside $TMP. /tmp is sticky, so whoever ran the suite first owned
# the file and every OTHER user's redirect failed with EACCES — and a failed
# redirection means bash never runs the command at all. cmd_task_need was never
# invoked, the row kept the tier NULL that seed_task left, and the assertion read
# ∅. The harness was green for its author and red for main, root and claude.
#
# So: assert EXISTENCE separately from any field, and pair every ∅ with a
# POSITIVE reading off the same row that only a live command could have written.
rows()  { db "SELECT COUNT(*) FROM tasks WHERE ident='$1';"; }
exists_t() { eq_t "$2" "$(rows "$1")" "1"; }

# ==================== part 1: the 48h TTL sweep (writer 1) ===================
# One aged tier-1 gate per class, all with a recommendation, all filed 50h ago,
# all swept on the SAME _hb_gate_ttl_sweep call. Whatever the sweep does, it does
# to all six at once — so "the approval survived" cannot be the sweep not running.
mk_aged() { # <ident> <need_type>
  db "INSERT INTO tasks (ident, title, priority, assignee, created_by, kind, status,
                         need_type, tier, ask, recommend, need_asked_at, gate_pinged_at)
      VALUES ('$1', 'aged gate', 'medium', 'worker', 'main', 'standard', 'blocked',
              '$2', 1, 'the ask', 'yes', datetime('now','-50 hours'), NULL);"
}
for t in decision approval manual access secret; do
  mk_aged "TTL-$t" "$t"
done

_hb_gate_ttl_sweep

# CONTROL FIRST. If this one fails, every negative below is vacuous and the
# harness is grading a dead sweep rather than a live exclusion.
eq_t "TTL control: tier-1 DECISION still auto-applies (sweep is live)" \
     "$(field TTL-decision need_answered_by)" "auto:ttl"
eq_t "TTL control: decision answer is the recommendation" \
     "$(field TTL-decision need_answer)" "yes"

for t in approval manual access secret; do
  # Existence + a positive reading FIRST: the two ∅s below are only evidence that
  # the sweep declined to answer this row if the row is there and is still the
  # aged tier-1 gate of that class the sweep was offered.
  exists_t "TTL-$t" "TTL: tier-1 ${t} row exists (the ∅s below are about a real row)"
  eq_t "TTL: tier-1 ${t} is still an aged gate of its class" \
       "$(field "TTL-$t" need_type)|$(field "TTL-$t" tier)|$(field "TTL-$t" recommend)" "${t}|1|yes"
  eq_t "TTL: tier-1 ${t} is NOT auto-applied (human class)" \
       "$(field "TTL-$t" need_answered_by)" "∅"
  eq_t "TTL: tier-1 ${t} left unanswered" \
       "$(field "TTL-$t" need_answered_at)" "∅"
done

# COMPLEMENTARITY. Removing those four from the TTL sweep is only safe if the
# 72h stale-gate reminder picks them up — otherwise a tier-1 approval WITH a
# recommendation is an orphan: never applied, never reminded, invisible. The
# reminder predicate used to cover tier-1 only when recommend IS NULL, which is
# exactly the row shape above.
#
# GRADE THE SHIPPED PREDICATE, NOT A COPY OF IT. The first version of this block
# re-declared _t2_where's SQL here and counted rows against the local copy. It
# was green — and it stayed green when the arm was DELETED from
# cmd_heartbeat.sh, because nothing in it ever read cmd_heartbeat.sh. A test
# that reimplements the thing it grades cannot fail for the reason it exists.
# So: age a fresh set past 72h, run the REAL sweep, and read what the reminder
# actually addressed.
REMINDERS="$TMP/reminders"; : >"$REMINDERS"
_task_send_owner() { printf '%s\n' "$1" >>"$REMINDERS"; return 0; }

mk_stale() { # <ident> <need_type> — 80h old, past the 72h reminder threshold
  db "INSERT INTO tasks (ident, title, priority, assignee, created_by, kind, status,
                         need_type, tier, ask, recommend, need_asked_at, gate_pinged_at)
      VALUES ('$1', 'stale gate', 'medium', 'worker', 'main', 'standard', 'blocked',
              '$2', 1, 'the ask', 'yes', datetime('now','-80 hours'), NULL);"
}
for t in decision approval manual access secret; do
  mk_stale "REM-$t" "$t"
done

_hb_gate_ttl_sweep

# CONTROL FIRST, again, and it is a two-sided one: the decision gate must be
# RESOLVED by pass 2 rather than reminded about, which is what proves the two
# predicates are complementary rather than merely both-true. If REM-decision
# showed up in the reminder text, the sweep would be nagging about gates it had
# just answered.
eq_t "reminder control: stale tier-1 DECISION was TTL-applied, not reminded" \
     "$(field REM-decision need_answered_by)" "auto:ttl"
grep -q 'REM-decision' "$REMINDERS" \
  && bad_t "reminder control: decision must NOT be in the reminder" "it was TTL-applied; nagging about it is a double-handling bug" \
  || ok_t "reminder control: the TTL-applied decision is absent from the reminder"
[[ -s "$REMINDERS" ]] \
  && ok_t "reminder: the 72h stale-gate reminder fired at all (the greps below are live)" \
  || bad_t "reminder never fired" "_task_send_owner was not called — every grep below would pass vacuously"

for t in approval manual access secret; do
  exists_t "REM-$t" "reminder: stale tier-1 ${t} row exists"
  eq_t "reminder: stale tier-1 ${t} was NOT TTL-applied" \
       "$(field "REM-$t" need_answered_by)" "∅"
  grep -q "REM-$t" "$REMINDERS" \
    && ok_t "reminder: tier-1 ${t} IS named in the stale-gate reminder (not orphaned)" \
    || bad_t "reminder: tier-1 ${t} orphaned" "not applied by the TTL sweep and not named in the reminder text: $(cat "$REMINDERS")"
done

# ==================== part 2: tier-0 apply-at-file (writer 2) ================
# Tier 0 IS an auto-answer: it applies `recommend` immediately and never pings.
# A human-class gate pinned to tier 0 must be floored to tier 1 and left for a
# person; a decision at tier 0 must still auto-clear, which is the control.
seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }

seed_task DIVE-2300
# Subshell: cmd_task_need calls die() on a validation refusal, and die exits the
# shell — in a sourced harness that would take the whole run with it and report
# as "everything after this point silently passed".
( cmd_task_need DIVE-2300 --type=decision --tier=0 --ask="pick a colour for the label" \
    --options="red|blue" --recommend="red" ) >/dev/null 2>&1
eq_t "T0 control: decision at tier 0 still auto-clears" \
     "$(field DIVE-2300 need_answered_by)" "auto:t0"
eq_t "T0 control: decision tier stays 0" "$(field DIVE-2300 tier)" "0"

# WHICH HUMAN CLASSES CAN EVEN REACH TIER 0 — measured, not assumed. Two arg
# validations pin this: `--tier=0` REQUIRES --recommend, and --recommend is
# accepted only for decision/approval. They are mutually exclusive for manual,
# access and secret, so those three cannot be filed at tier 0 through the CLI at
# all. The live tier-0 exposure is therefore APPROVAL alone. That is asserted
# below rather than assumed, because it is the premise that makes the single
# approval case sufficient — if a later change relaxes either validation, these
# refusal assertions go red and say so instead of the floor quietly gaining an
# untested class.
seed_task DIVE-2301
( cmd_task_need DIVE-2301 --type=approval --tier=0 --ask="do the routine thing" \
    --recommend="yes" ) >"$TMP/t0-approval.out" 2>&1
# LIVENESS before the negative: the gate must actually have been FILED. Without
# this, "approval is NOT auto-answered" passes just as happily when cmd_task_need
# never ran — which is precisely how this file used to go red for everyone but
# its author.
exists_t DIVE-2301 "T0: approval task row exists"
eq_t "T0: approval gate was actually filed (cmd_task_need ran)" \
     "$(field DIVE-2301 need_type)" "approval"
eq_t "T0: approval pinned to tier 0 is floored to tier 1" "$(field DIVE-2301 tier)" "1"
eq_t "T0: approval is NOT auto-answered"     "$(field DIVE-2301 need_answered_at)" "∅"
eq_t "T0: approval left blocked for a human" "$(field DIVE-2301 status)"           "blocked"

n=2310
for t in manual access; do
  n=$((n+1)); id="DIVE-$n"
  seed_task "$id"
  ( cmd_task_need "$id" --type="$t" --tier=0 --ask="do the routine thing" ) >"$TMP/t0-$t.out" 2>&1
  rc=$?
  [[ "$rc" -ne 0 ]] \
    && ok_t "T0: ${t} cannot be filed at tier 0 at all (arg validation refuses)" \
    || bad_t "T0: ${t} cannot be filed at tier 0" "cmd_task_need returned 0"
  # The refusal must be a REFUSAL, not an absence. The task row has to be there
  # (so ∅ means "the column is NULL", not "there is nothing to read"), and the
  # command has to have said why — a non-zero rc with no output is what a failed
  # redirect or a missing binary looks like, and both would pass the rc check.
  exists_t "$id" "T0: ${t} task row exists (so the ∅ below is a NULL column)"
  eq_t "T0: ${t} gate was not created"  "$(field "$id" need_type)" "∅"
  [[ -s "$TMP/t0-$t.out" ]] \
    && ok_t "T0: ${t} refusal is spoken, not silent" \
    || bad_t "T0: ${t} refusal is spoken" "cmd_task_need produced no output — rc alone cannot tell a refusal from a command that never ran"
done

# secret is the exception and lands one layer earlier: --tier=0 is accepted (a
# secret gate needs no recommendation), but the DIVE-1117 T2 keyword floor
# re-tiers it before the class floor is ever consulted. Asserted because the
# route matters — "secret never auto-clears at tier 0" is true here for a
# DIFFERENT reason than approval's, and a reader who assumes the class floor did
# it would be wrong about which guard is load-bearing.
seed_task DIVE-2320
# $TMP, never a fixed /tmp path — see the ∅ note above. This one line is what
# made the harness pass for its author and fail for main, root and claude.
# DIVE-2411: a secret gate must name a delivery path to file at all, so this one
# carries a drop target. Unrelated to what the arm grades (the tier floor), but
# without it cmd_task_need refuses and every assertion below grades the refusal.
( cmd_task_need DIVE-2320 --type=secret --tier=0 --ask="drop the api key" --secret-key=API_KEY --connector=demo ) >"$TMP/t0-secret.out" 2>&1
exists_t DIVE-2320 "T0: secret task row exists"
eq_t "T0: secret gate was actually filed (cmd_task_need ran)" \
     "$(field DIVE-2320 need_type)" "secret"
# The floored tier is PERSISTED, not merely reported. The envelope says tier 2;
# this reads the column back, because a response that disagrees with the row is
# this ticket's own defect one layer over.
eq_t "T0: secret is re-tiered above 0 by the T2 floor" "$(field DIVE-2320 tier)" "2"
grep -q 'FORCED to tier 2' "$TMP/t0-secret.out" \
  && ok_t "T0: the T2 keyword floor is the guard that fired (announced on stderr)" \
  || bad_t "T0: T2 floor announced" "no 'FORCED to tier 2' in the captured output"
eq_t "T0: secret is NOT auto-answered"                 "$(field DIVE-2320 need_answered_at)" "∅"

# The floor must be OBSERVABLE, not just correct. A silent re-tier is the same
# class of unauditable record this whole ticket is about.
grep -q 'task need class-floor' "$AUDIT_ROWS" \
  && ok_t "T0: the class floor writes an audit row (from_tier=0 to_tier=1)" \
  || bad_t "T0: class floor is silent" "no 'task need class-floor' row in the audit sink"

# ==================== part 3: the classifier itself ==========================
# _gate_human_class is the single list the three writers share. It must agree
# with the nonce MINT list in cmd_task_need — if a class mints a nonce it is a
# class a human answers, and the two lists drifting apart is how this defect
# comes back. 'decision' is deliberately out of both, pending v0.18.
for t in approval secret manual access; do
  _gate_human_class "$t" && ok_t "class: ${t} is human-class" \
                         || bad_t "class: ${t} is human-class" "returned non-zero"
done
for t in decision "" bogus; do
  _gate_human_class "$t" && bad_t "class: [${t}] must NOT be human-class" "returned zero" \
                         || ok_t "class: [${t:-<empty>}] is not human-class"
done
# Lockstep: the SQL form and the shell form are two spellings of one list, and a
# writer that consults the wrong one silently re-opens the hole.
for t in approval secret manual access; do
  case "$_GATE_HUMAN_CLASS_SQL" in
    *"'$t'"*) ok_t "class: SQL form carries ${t}" ;;
    *)        bad_t "class: SQL form carries ${t}" "missing from $_GATE_HUMAN_CLASS_SQL" ;;
  esac
done
case "$_GATE_HUMAN_CLASS_SQL" in
  *"'decision'"*) bad_t "class: SQL form must not carry decision" "would kill the TTL sweep entirely" ;;
  *)              ok_t "class: SQL form excludes decision (TTL default survives)" ;;
esac

echo "-------------------------------------"
echo "gate_class_over_tier_unit: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
