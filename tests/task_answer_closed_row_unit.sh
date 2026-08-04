#!/usr/bin/env bash
# TIER: nightly — 39.5s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-2228 — `task answer` on a CLOSED row. The last open cell of the
# closed-task writer matrix (DIVE-2112 / DIVE-2113 / DIVE-2116 are the others).
#
# cmd_task_answer's only precondition was "this row has an unanswered gate";
# nothing in it was about status. A closed task carrying a dangling gate is an
# ordinary state — file a gate, then close or cancel without answering it — and
# the DIVE-909 close-as-done branch then ran `WHERE id=${id}` with no status
# predicate. Measured before the fix, as a third party who is neither maker nor
# verifier: on a `done` row rc=0 and done_at was RE-STAMPED; on a `cancelled`
# row rc=0 and cancelled -> done, with the cascade releasing its dependents.
#
# `result` survived both — DIVE-2067's CASE WHEN result='' guard was already
# applied — which is exactly why the row looked defended. So this harness does
# NOT grade on result. It grades status, done_at, and the dependent edge.
#
# The guard is SCOPED, not symmetric: only the paths that MOVE the row are
# refused. Cases D and E assert that answering a decision gate, or a manual gate
# with a non-"done" value, on a closed row still works exactly as measured
# clean — a refusal with no still-works control cannot be told apart from an
# outage. Case C is the writer's own still-works control AND its reachability
# proof: it must be rc=0 or every refusal above is vacuous.
# Run: bash tests/task_answer_closed_row_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
# DIVE-2518: impersonate through the SEALED seam. `USER=agent-x` no longer moves
# the actor — that env path WAS the forgery this ticket closed, and these arms
# were leaning on it. tests/lib/actor_seam.sh explains the migration.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"

# `manual` is a HUMAN-ONLY gate (DIVE-916) and that boundary reads the REAL unix
# caller, not $USER/$SUDO_USER. Under an agent-* uid every manual case below is
# refused with E_AUTH_REQUIRED before reaching the code under test, and a
# refusal and a defended row are the same observation at the row level and
# opposite facts — that vacuity is what made DIVE-2116's first run report this
# defect CLEAN. CI runs as a non-agent user and never takes this branch.
if [[ "$(id -un 2>/dev/null || echo '?')" == agent-* ]]; then
  exec sudo -n bash "$0" "$@"
fi

SRC=src
TMP="$(mktemp -d /tmp/task-answer-closed-unit.XXXXXX)"

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
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }

tasks_db_init
as() { local who="$1"; shift; ( actor_seam_as "${who}"; "$@" ) 2>"$TMP"/err; }
# The live human paths (Telegram tap -> `sudo -n 5dive task answer`, dashboard
# exec as claude) are non-agent unix callers with a non-agent SUDO_UID.
as_human() { ( SUDO_UID="1000"; SUDO_USER="lodar"; "$@" ) 2>"$TMP"/err; }

status_of() { db "SELECT status                       FROM tasks WHERE ident=$(sqlq "$1");"; }
res_of()    { db "SELECT COALESCE(result,'')          FROM tasks WHERE ident=$(sqlq "$1");"; }
doneat_of() { db "SELECT COALESCE(done_at,'')         FROM tasks WHERE ident=$(sqlq "$1");"; }
nat_of()    { db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE ident=$(sqlq "$1");"; }
refusals()  { db "SELECT COUNT(*) FROM policy_refusals WHERE policy='task_answer_closed_row' AND ident=$(sqlq "$1");"; }

ACK="verified PASS — the seal grades the bundle, not that src produces it"

# ── instrument: without impersonation every case below is vacuous ─────────────
actor_is() { ( actor_seam_as "$1"; task_actor ); }
[[ "$(actor_is dev2)" == "dev2" ]] \
  && ok_t "INSTRUMENT: harness impersonates a third party (task_actor -> dev2)" \
  || bad_t "INSTRUMENT: actor impersonation broken" "got '$(actor_is dev2)' — every case is vacuous"
[[ "$(id -un 2>/dev/null)" != agent-* ]] \
  && ok_t "INSTRUMENT: caller is a non-agent uid (the manual human-only floor is passable)" \
  || bad_t "INSTRUMENT: running as agent-*" "manual gates refuse before the code under test — vacuous"

add() { JSON_MODE=1 cmd_task_add "$@" 2>"$TMP"/err | jq -r '.data.ident // empty'; }

# A CLOSED, GRADED row: maker=dev delivers, verifier=main ACKs it done.
seed_closed() {
  local id; id=$(add "$1" --assignee=dev --verifier=main --accept="do the thing")
  as dev  cmd_task_done "$id" --result="maker delivery v1" >/dev/null
  as main cmd_task_done "$id" --result="$ACK" >/dev/null
  [[ "${2:-done}" == "cancelled" ]] && db "UPDATE tasks SET status='cancelled' WHERE ident=$(sqlq "$id");"
  printf '%s' "$id"
}
# The state that makes these writers reachable: a gate filed, task later closed
# without answering it. need_answered_at NULL is what the precondition reads.
attach_gate() {
  db "UPDATE tasks SET need_type=$(sqlq "$2"), ask='does this land on a closed row?',
        tier=1, need_asked_at=datetime('now'),
        need_answered_at=NULL, need_answered_by=NULL
      WHERE ident=$(sqlq "$1");"
}
# A dependent blocked by $1, so we can see whether a bogus close cascaded.
dependent_on() {
  local dep; dep=$(add "$2" --assignee=dev)
  db "UPDATE tasks SET status='blocked' WHERE ident=$(sqlq "$dep");
      INSERT OR IGNORE INTO task_deps (task_id, blocked_by)
        VALUES ((SELECT id FROM tasks WHERE ident=$(sqlq "$dep")),
                (SELECT id FROM tasks WHERE ident=$(sqlq "$1")));"
  printf '%s' "$dep"
}

# ── C — THE STILL-WORKS CONTROL, and the reachability proof ──────────────────
# A manual gate answered "done" on an OPEN task must close it exactly as before
# (DIVE-909) and cascade its dependents (DIVE-1415). If this goes red or the
# refusals below are really "answer refuses everything", that is an outage
# wearing a fix's clothes.
c=$(add "manual-done-on-open" --assignee=dev); attach_gate "$c" manual
cdep=$(dependent_on "$c" "dependent-of-open")
db "UPDATE tasks SET status='blocked' WHERE ident=$(sqlq "$c");"
as_human cmd_task_answer "$c" --value=done >/dev/null; rcc=$?
[[ $rcc -eq 0 ]] \
  && ok_t "C REACHED: manual-gate 'done' on an OPEN task still accepted (rc=0)" \
  || bad_t "C VACUOUS: the writer under test is unreachable (rc=$rcc)" "$(head -1 "$TMP"/err) — every refusal below proves nothing"
[[ "$(status_of "$c")" == "done" && -n "$(doneat_of "$c")" ]] \
  && ok_t "C: the open task closed as done with done_at stamped (DIVE-909 intact)" \
  || bad_t "C: open manual-gate close broke" "status=$(status_of "$c") done_at='$(doneat_of "$c")'"
[[ "$(status_of "$cdep")" == "todo" ]] \
  && ok_t "C: its dependent was released (DIVE-1415 cascade intact)" \
  || bad_t "C: cascade broke on the legitimate close" "dependent status=$(status_of "$cdep")"

# ── A — a DONE row: done_at must not be re-stamped ───────────────────────────
a=$(seed_closed "manual-done-on-done"); attach_gate "$a" manual
a_d0=$(doneat_of "$a"); sleep 1
as_human cmd_task_answer "$a" --value=done >/dev/null; rca=$?
[[ $rca -ne 0 ]] \
  && ok_t "A: refused on a done row (rc=$rca)" \
  || bad_t "A: accepted on a done row (rc=0)" "$(head -1 "$TMP"/err)"
[[ "$(doneat_of "$a")" == "$a_d0" ]] \
  && ok_t "A: done_at preserved — the verifier's close time survives" \
  || bad_t "A: done_at RE-STAMPED on a closed row" "was '$a_d0' now '$(doneat_of "$a")'"
[[ "$(status_of "$a")" == "done" && "$(res_of "$a")" == "$ACK" ]] \
  && ok_t "A: status and the verifier's ACK untouched" \
  || bad_t "A: graded record moved" "status=$(status_of "$a") result=$(res_of "$a")"
[[ -z "$(nat_of "$a")" ]] \
  && ok_t "A: all-or-nothing — the gate was NOT marked answered under a non-zero rc" \
  || bad_t "A: gate answered despite the refusal" "need_answered_at='$(nat_of "$a")'"
[[ "$(refusals "$a")" == "1" ]] \
  && ok_t "A: the refusal is recorded in policy_refusals (task_answer_closed_row)" \
  || bad_t "A: refusal not recorded" "count=$(refusals "$a")"

# ── B — a CANCELLED row: the destructive one ─────────────────────────────────
b=$(seed_closed "manual-done-on-cancelled" cancelled); attach_gate "$b" manual
bdep=$(dependent_on "$b" "dependent-of-cancelled")
as_human cmd_task_answer "$b" --value=done >/dev/null; rcb=$?
[[ $rcb -ne 0 ]] \
  && ok_t "B: refused on a cancelled row (rc=$rcb)" \
  || bad_t "B: accepted on a cancelled row (rc=0)" "$(head -1 "$TMP"/err)"
[[ "$(status_of "$b")" == "cancelled" ]] \
  && ok_t "B: cancelled work was NOT relabelled done" \
  || bad_t "B: cancelled -> $(status_of "$b") by a dangling manual gate" "cancelled work is now labelled completed"
[[ "$(status_of "$bdep")" == "blocked" ]] \
  && ok_t "B: its dependent stayed blocked (no cascade off a cancelled row)" \
  || bad_t "B: cascade released a cancelled task's dependent" "dependent status=$(status_of "$bdep")"

# ── D — SCOPE: a decision gate on a closed row is measured clean, keep it so ──
d=$(seed_closed "decision-on-done"); attach_gate "$d" decision
as dev2 cmd_task_answer "$d" --value=A >/dev/null; rcd=$?
[[ $rcd -eq 0 && -n "$(nat_of "$d")" ]] \
  && ok_t "D SCOPE: a decision gate on a closed row still answers (not over-refused)" \
  || bad_t "D: the guard over-reached onto a non-status-moving answer" "rc=$rcd answered_at='$(nat_of "$d")'"
[[ "$(status_of "$d")" == "done" && "$(doneat_of "$d")" != "" ]] \
  && ok_t "D SCOPE: and it still does not move the row (else-branch fenced on blocked)" \
  || bad_t "D: decision answer moved a closed row" "status=$(status_of "$d")"

# ── E — SCOPE: a manual gate with a NON-"done" value never closes anything ───
e=$(seed_closed "manual-other-on-done"); attach_gate "$e" manual
e_d0=$(doneat_of "$e")
as_human cmd_task_answer "$e" --value="key dropped in .env" >/dev/null; rce=$?
[[ $rce -eq 0 && -n "$(nat_of "$e")" ]] \
  && ok_t "E SCOPE: a manual answer that is not 'done' still records on a closed row" \
  || bad_t "E: the guard refused a non-status-moving manual answer" "rc=$rce answered_at='$(nat_of "$e")'"
[[ "$(status_of "$e")" == "done" && "$(doneat_of "$e")" == "$e_d0" ]] \
  && ok_t "E SCOPE: and the row is byte-identical" \
  || bad_t "E: non-'done' manual answer moved the row" "status=$(status_of "$e") done_at='$(doneat_of "$e")'"

# ── F — the next instance of the same shape: a closed LOOP GATE step ─────────
# The DIVE-552 relay branch (_lk=gate:*) carried the same unfenced
# `UPDATE tasks SET status='done', done_at=datetime('now') WHERE id=${id}`, plus
# a bounce arm that re-opens the PREVIOUS step. Same defect, different door.
# The step is seeded CANCELLED deliberately. On a `done` step the advance arm
# writes status='done' over 'done', so the ONLY tell is done_at, and done_at is
# datetime('now') at one-second resolution -- a write inside the same second is
# indistinguishable from no write, and this assertion passed on the broken
# baseline by luck before the `sleep 1` below was added. A cancelled step makes
# the defect visible as a status flip that no clock can hide.
f=$(seed_closed "loop-gate-step-closed" cancelled)
db "UPDATE tasks SET body='[[5dive-loop:gate:decision]]' WHERE ident=$(sqlq "$f");"
attach_gate "$f" decision
f_d0=$(doneat_of "$f"); sleep 1
as dev2 cmd_task_answer "$f" --value="Approve →" >/dev/null; rcf=$?
[[ $rcf -ne 0 ]] \
  && ok_t "F: a CLOSED loop-gate step refuses the relay answer (rc=$rcf)" \
  || bad_t "F: the loop-gate branch still writes a closed row (rc=0)" "$(head -1 "$TMP"/err)"
[[ "$(status_of "$f")" == "cancelled" ]] \
  && ok_t "F: the cancelled loop-gate step was NOT relabelled done by the relay" \
  || bad_t "F: loop-gate advance flipped cancelled -> $(status_of "$f")" "same defect, second door"
[[ "$(doneat_of "$f")" == "$f_d0" ]] \
  && ok_t "F: its done_at survives" \
  || bad_t "F: loop-gate advance re-stamped a closed step" "was '$f_d0' now '$(doneat_of "$f")'"

# ── G — GRADE THE CLASS, not the two instances we happened to find ───────────
# main's review of this fix, and the reason it exists: cmd_task_answer holds
# FOUR status-moving writes against the answered row, and ONE OF THEM WAS
# ALREADY FENCED before this change — the else-branch's
# `WHERE id=${id} AND status='blocked'`. So this was never "nobody thought of
# the fence". Someone wrote the right idiom once and three sibling writes did
# not get it: enumerate-the-dangerous has already been tried on this exact
# function and landed 1 for 4. Cases A/B/F above grade two instances; a FIFTH
# branch added later would ship exactly like the second one did.
#
# So this arm enumerates the writes statically and asserts the rule per TARGET.
# A future status write against the answered row fails the suite instead of
# shipping — which is the only version of this that survives the author not
# being the next person to touch the function.
_answer_fn() {   # the function body, comments stripped so prose can neither
                 # mask a real violation nor invent a phantom one
  awk '/^cmd_task_answer\(\) \{$/{on=1} on{print} on&&/^\}$/{exit}' "$SRC/cmd_task.sh" \
    | grep -v '^[[:space:]]*#'
}
_status_writes() {   # stdin -> one flattened SQL statement per line
  tr '\n' ' ' | sed 's/;/;\n/g' | grep 'UPDATE tasks SET' | grep "status='"
}
_is_fenced() { [[ "$1" == *"status NOT IN ('done','cancelled')"* || "$1" == *"AND status='blocked'"* ]]; }
# Returns the violating statements: a write against the ANSWERED row (id=${id})
# with no status predicate. A write against another row is not in the class —
# see the graded exemption below.
_violations() {
  local st
  while IFS= read -r st; do
    [[ "$st" == *'WHERE id=${id}'* ]] || continue
    _is_fenced "$st" || printf '%s\n' "$st"
  done
}

g_all=$(_answer_fn | _status_writes)
g_n=$(printf '%s\n' "$g_all" | grep -c 'UPDATE tasks SET')
g_id=$(printf '%s\n' "$g_all" | grep -c 'WHERE id=\${id}')
g_prev=$(printf '%s\n' "$g_all" | grep -c 'WHERE id=\${_prev}')
g_bad=$(printf '%s\n' "$g_all" | _violations)

# Non-vacuity FIRST: a broken extractor finds nothing and "no violations" is
# then a statement about the awk, not about the function.
[[ "$g_n" -ge 5 && "$g_id" -ge 4 ]] \
  && ok_t "G: the enumerator sees the writes it grades ($g_n status writes, $g_id against the answered row)" \
  || bad_t "G VACUOUS: extractor found $g_n status writes / $g_id on the answered row" "expected >=5 and >=4 — 'no violations' below would prove nothing"
[[ -z "$g_bad" ]] \
  && ok_t "G: EVERY status write against the answered row carries a status fence" \
  || bad_t "G: an UNFENCED status write against the answered row" "$(printf '%s' "$g_bad" | head -2)"
# The exemption is GRADED, not silently skipped. The bounce arm reopens the
# PREVIOUS step. DIVE-2261 separately preflights and refuses CANCELLED before
# any answer write; a status fence at this later write would partially commit
# the answer and silently omit the redo.
[[ "$g_prev" -eq 1 ]] \
  && ok_t "G: the one cross-row write (\${_prev}, the bounce reopen) is a named exemption, not an oversight" \
  || bad_t "G: expected exactly 1 write against \${_prev}, found $g_prev" "a new cross-row write needs its own reasoning"

# MUTATION — differential, because a checker that reports zero violations on a
# function with no violations is indistinguishable from one that reports zero
# on anything. Strip a single fence and require the count to move by exactly 1.
g_base_bad=$(printf '%s\n' "$g_all" | _violations | grep -c 'UPDATE tasks SET')
g_mut=$(printf '%s\n' "$g_all" | sed "0,/ AND status NOT IN ('done','cancelled')/s///")
if [[ "$g_mut" == "$g_all" ]]; then
  # Confirm the mutation LANDED before reading anything off it. An unchanged
  # mutant produces the SAME count as the real thing, and "the numbers match"
  # then reads as a passing differential when nothing was ever mutated.
  bad_t "G MUTATION did not land: no fence was there to strip" "the mutant is byte-identical to the source — nothing was measured"
else
  g_mut_bad=$(printf '%s\n' "$g_mut" | _violations | grep -c 'UPDATE tasks SET')
  [[ "$g_mut_bad" -eq $(( g_base_bad + 1 )) ]] \
    && ok_t "G MUTATION: stripping one fence moves the count by exactly 1 ($g_base_bad -> $g_mut_bad) — the checker discriminates" \
    || bad_t "G MUTATION: count went $g_base_bad -> $g_mut_bad, expected $(( g_base_bad + 1 ))" "the checker is not measuring what it claims"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
