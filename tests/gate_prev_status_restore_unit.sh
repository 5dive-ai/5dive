#!/usr/bin/env bash
# DIVE-4817: retiring a gate puts the row back where it WAS, not on 'todo'.
#
# The defect (lodar, on DIVE-4811, 2026-09-22): `task need` writes
# status='blocked' over whatever the row held, and every clear path then wrote
# status='todo' back. Nothing anywhere recorded the pre-gate status, so an
# `in_progress` row that filed an inert gate mid-work — which every `5dive push`
# does — came out `todo`, with started_at still set, its maker still typing, and
# the heartbeat's "busy — N in_progress" guard no longer counting it. It is
# systemic, not one row: `gate.autocleared` fired 12 times on dev's rows alone in
# the 9h before it was caught.
#
# WHAT THIS GRADES, AND WHY IT IS MOSTLY NEGATIVE CONTROLS. The change turns a
# behaviour ON (restore the recorded status), so the positive arms are the cheap
# half — they go green the moment the column is written at all. The load-bearing
# arms are the ones that must STAY as they were: a `todo` row, a legacy row whose
# gate predates the column, a row still held by a task-task block edge, and the
# whitelist that stops a gate clear resurrecting a closed row. Section 5 asserts
# the pre-fix behaviour is byte-identical wherever the recorded status is 'todo'
# or absent — that is the whole compatibility claim.
#
# Run: bash tests/gate_prev_status_restore_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-prev-status-restore.XXXXXX)"
# DIVE-2190/2610: a `fail()` inside any cmd_* exits the whole script, which would
# end the run with an `ok` as the last line and no summary — a red that reads as
# a pass that stopped early. fd 8 is the REAL stderr, duped before any arm runs.
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "$TMP"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - gate_prev_status_restore_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/broker.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2
# The REAL branch parser the push-for-review auto-clear reads the row's binding
# through — same reason gate_pfr_autoclear_unit.sh sources it rather than
# re-implementing it.
# shellcheck source=/dev/null
source "$SRC/cmd_push.sh"

. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
FIXTURE_ACTOR=fixture-runner
fixture_actor() { FIXTURE_ACTOR="$1"; actor_seam_as "$1"; }

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

_task_need_notify_deliver() { :; }
audit_log() { :; }
_task_store_audit_log() { :; }
5dive() { return 0; }
export -f 5dive 2>/dev/null || true

# The root signing rail, stubbed at the SUDO CALL SITE (the push-for-review
# auto-clear will not fire without a closure signature). The signature returned
# is a real HMAC over the real payload against a fixture key, so nothing about
# the clear is simulated except the privilege.
export GATE_PROOF_KEY="$TMP/gate-proof.key"
( umask 077; openssl rand -hex 32 > "$GATE_PROOF_KEY" )
sudo() {
  if [[ "${1:-}" == "-n" && "${2:-}" == "5dive" && "${3:-}" == "gate-proof" && "${4:-}" == "sign" ]]; then
    local payload; payload=$(cat); _gate_proof_hmac "$payload"; return 0
  fi
  return 1
}

db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev2','main','builder');"

STARTED='2026-09-22 02:23:57'
# seed <ident> <status> [branch-body]
seed() {
  db "INSERT INTO tasks(ident,title,status,created_by,assignee,body,started_at,first_started_at)
      VALUES('$1','restore the row status when a gate retires',$(sqlq "$2"),'main','dev2',$(sqlq "${3-}"),
             CASE WHEN $(sqlq "$2")='in_progress' THEN $(sqlq "$STARTED") ELSE NULL END,
             CASE WHEN $(sqlq "$2")='in_progress' THEN $(sqlq "$STARTED") ELSE NULL END);"
}
gstat()  { db "SELECT status FROM tasks WHERE ident='$1';"; }
gprev()  { db "SELECT COALESCE(gate_prev_status,'<null>') FROM tasks WHERE ident='$1';"; }
gstart() { db "SELECT COALESCE(started_at,'<null>') FROM tasks WHERE ident='$1';"; }
gby()    { db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='$1';"; }
gid()    { db "SELECT id FROM tasks WHERE ident='$1';"; }
busy_n() { db "SELECT COUNT(*) FROM tasks WHERE status='in_progress';"; }

PFR_ASK='approve the delegated push of branch dive-4817-gate-status to origin for PR review'
BRANCH_BODY='Branch: dive-4817-gate-status'

# ================ 1. THE MEASURED CASE: pfr auto-clear, mid-work ===============
# DIVE-4811's exact shape — an in_progress row files the inert push-for-review
# approval every `5dive push` files, and it clears inside the same call.
fixture_actor dev2
seed DIVE-901 in_progress "$BRANCH_BODY"
( cmd_task_need DIVE-901 --type=approval --recommend='approve' --ask="$PFR_ASK" --from=dev2 ) >/dev/null 2>&1
[[ "$(gby DIVE-901)" == "auto:pfr" ]] \
  && ok_t "precondition: the push-for-review gate did auto-clear (auto:pfr)" \
  || bad_t "precondition: the gate auto-cleared" "got=$(gby DIVE-901)"
[[ "$(gstat DIVE-901)" == "in_progress" ]] \
  && ok_t "an in_progress row that files and clears a push gate STAYS in_progress" \
  || bad_t "in_progress survives the push-for-review auto-clear" "got=$(gstat DIVE-901)"
[[ "$(gstart DIVE-901)" == "$STARTED" ]] \
  && ok_t "started_at is untouched — the maker's clock is not restarted" \
  || bad_t "started_at untouched" "got=$(gstart DIVE-901)"
[[ "$(busy_n)" == "1" ]] \
  && ok_t "the heartbeat's in_progress busy count still sees the row (the guard that went blind)" \
  || bad_t "busy count still counts the row" "got=$(busy_n)"
[[ "$(gprev DIVE-901)" == "<null>" ]] \
  && ok_t "gate_prev_status is consumed by the restore, not left standing" \
  || bad_t "gate_prev_status consumed" "got=$(gprev DIVE-901)"

# ================ 2. THE OTHER SYNCHRONOUS CLEAR: tier 0 =======================
seed DIVE-902 in_progress
( cmd_task_need DIVE-902 --type=decision --tier=0 --recommend='keep the flag' \
    --options='keep the flag|drop the flag' --ask='keep the new flag or drop it?' --from=dev2 ) >/dev/null 2>&1
[[ "$(gby DIVE-902)" == "auto:t0" ]] \
  && ok_t "precondition: the tier-0 decision applied the recommendation (auto:t0)" \
  || bad_t "precondition: tier-0 auto-applied" "got=$(gby DIVE-902)"
[[ "$(gstat DIVE-902)" == "in_progress" ]] \
  && ok_t "a tier-0 gate filed mid-work leaves the row in_progress" \
  || bad_t "tier-0 leaves in_progress" "got=$(gstat DIVE-902)"

# ================ 3. THE ASYNC CLEARS: withdraw, and a typed answer ============
# These are the ones the in-memory variable the first draft reached for could not
# reach: the status must survive to a LATER call, so it is recorded on the row.
seed DIVE-903 in_progress
( cmd_task_need DIVE-903 --type=manual --ask='plug the cable in' --from=dev2 ) >/dev/null 2>&1
[[ "$(gstat DIVE-903)" == "blocked" && "$(gprev DIVE-903)" == "in_progress" ]] \
  && ok_t "a gate that does NOT auto-clear still parks the row blocked, with the pre-gate status recorded" \
  || bad_t "an unanswered gate parks blocked and records the status" "status=$(gstat DIVE-903) prev=$(gprev DIVE-903)"
( cmd_task_need DIVE-903 --withdraw --from=dev2 ) >/dev/null 2>&1
[[ "$(gstat DIVE-903)" == "in_progress" ]] \
  && ok_t "withdrawing that gate an hour later returns the row to in_progress, not to the queue" \
  || bad_t "withdraw restores in_progress" "got=$(gstat DIVE-903)"

# DIVE-4896: close out the rows the arms above left in_progress on dev2 first.
# A maker holding OTHER in_progress rows is now, correctly, busy elsewhere, and
# a typed answer yields to 'todo' for a busy maker (section 7 grades that). This
# arm is about the idle maker waiting on its gate, so the fixture must be one.
db "UPDATE tasks SET status='done' WHERE assignee='dev2' AND status='in_progress';"
seed DIVE-904 in_progress
( cmd_task_need DIVE-904 --type=decision --tier=1 --recommend='A' --options='A|B' \
    --ask='which way?' --from=dev2 ) >/dev/null 2>&1
[[ "$(gstat DIVE-904)" == "blocked" ]] \
  && ok_t "precondition: the tier-1 decision is parked awaiting a human" \
  || bad_t "precondition: tier-1 parks" "got=$(gstat DIVE-904)"
( cmd_task_answer DIVE-904 --value='B' --human ) >/dev/null 2>&1
[[ "$(gstat DIVE-904)" == "in_progress" ]] \
  && ok_t "a human's typed answer hands the row back to its maker in_progress" \
  || bad_t "typed answer restores in_progress" "got=$(gstat DIVE-904)"

# ================ 4. THE RE-FILE, WHICH IS WHERE THIS RE-BREAKS =================
# Filing on top of an open gate sees status='blocked' — recording THAT would make
# the restore fall through the whitelist to 'todo', reintroducing the defect
# through the one path (withdraw-and-refile) most used on a live row.
seed DIVE-905 in_progress "$BRANCH_BODY"
( cmd_task_need DIVE-905 --type=manual --ask='plug the cable in' --from=dev2 ) >/dev/null 2>&1
( cmd_task_need DIVE-905 --type=approval --recommend='approve' --ask="$PFR_ASK" --from=dev2 ) >/dev/null 2>&1
[[ "$(gby DIVE-905)" == "auto:pfr" ]] \
  && ok_t "precondition: the re-filed push gate auto-cleared" \
  || bad_t "precondition: re-file auto-cleared" "got=$(gby DIVE-905)"
[[ "$(gstat DIVE-905)" == "in_progress" ]] \
  && ok_t "a gate re-filed on top of an open one keeps the ORIGINAL pre-gate status" \
  || bad_t "re-file keeps the original pre-gate status" "got=$(gstat DIVE-905)"

# ================ 5. NEGATIVE CONTROLS — the compatibility claim ================
# 5a. A todo row is byte-identical to the pre-fix behaviour.
seed DIVE-906 todo "$BRANCH_BODY"
( cmd_task_need DIVE-906 --type=approval --recommend='approve' --ask="$PFR_ASK" --from=dev2 ) >/dev/null 2>&1
[[ "$(gstat DIVE-906)" == "todo" ]] \
  && ok_t "CONTROL: a todo row still comes out todo (the pre-fix path, unchanged)" \
  || bad_t "CONTROL: todo stays todo" "got=$(gstat DIVE-906)"

# 5b. A LEGACY row — gate filed by a build that had no such column, so it is NULL.
#     This is every row already carrying an open gate at the moment this ships.
seed DIVE-907 in_progress
( cmd_task_need DIVE-907 --type=manual --ask='plug the cable in' --from=dev2 ) >/dev/null 2>&1
db "UPDATE tasks SET gate_prev_status=NULL WHERE ident='DIVE-907';"
( cmd_task_need DIVE-907 --withdraw --from=dev2 ) >/dev/null 2>&1
[[ "$(gstat DIVE-907)" == "todo" ]] \
  && ok_t "CONTROL: a gate filed before this column existed still clears to todo (no backfill needed)" \
  || bad_t "CONTROL: legacy NULL clears to todo" "got=$(gstat DIVE-907)"

# 5c. A row still held by a task-task block edge must NOT be unblocked by a gate
#     clear — status='blocked' is overloaded, and the dep fence predates this row.
seed DIVE-908 in_progress
seed DIVE-909 todo
db "INSERT INTO task_deps (task_id, blocked_by) VALUES ($(gid DIVE-908), $(gid DIVE-909));"
( cmd_task_need DIVE-908 --type=manual --ask='plug the cable in' --from=dev2 ) >/dev/null 2>&1
( cmd_task_need DIVE-908 --withdraw --from=dev2 ) >/dev/null 2>&1
[[ "$(gstat DIVE-908)" == "blocked" ]] \
  && ok_t "CONTROL: a row still blocked by another TASK stays blocked when its gate clears" \
  || bad_t "CONTROL: dep edge still holds the row" "got=$(gstat DIVE-908)"
[[ "$(gprev DIVE-908)" == "in_progress" ]] \
  && ok_t "…and its pre-gate status is KEPT, because the restore has not happened yet" \
  || bad_t "pre-gate status kept while dep-blocked" "got=$(gprev DIVE-908)"

# 5d. THE WHITELIST. A gate clear must never resurrect a closed row, whatever is
#     in the column — graded on the restore SQL directly, because no cmd_* path
#     is supposed to be able to produce these values in the first place.
i=1
for bad in done cancelled blocked '' bogus; do
  seed "DIVE-92$i" todo
  db "UPDATE tasks SET status='blocked',
        gate_prev_status=$( [[ -z "$bad" ]] && printf NULL || sqlq "$bad" )
      WHERE ident='DIVE-92$i';"
  db "$(_gate_restore_status_sql "$(gid "DIVE-92$i")")"
  [[ "$(gstat "DIVE-92$i")" == "todo" ]] \
    || bad_t "WHITELIST: gate_prev_status='${bad:-<null>}' must fall back to todo" "got=$(gstat "DIVE-92$i")"
  i=$((i+1))
done
ok_t "WHITELIST: only todo/in_progress are restorable — done, cancelled, blocked, NULL and junk all fall back to todo"

# 5e. The restore is fenced on status='blocked', so it cannot touch a row that is
#     not parked on a gate at all.
seed DIVE-930 in_progress
db "UPDATE tasks SET gate_prev_status='todo' WHERE ident='DIVE-930';"
db "$(_gate_restore_status_sql "$(gid DIVE-930)")"
[[ "$(gstat DIVE-930)" == "in_progress" ]] \
  && ok_t "CONTROL: the restore is a no-op on a row that is not blocked (fence unchanged)" \
  || bad_t "CONTROL: restore no-ops off a blocked row" "got=$(gstat DIVE-930)"

# ================ 6. ONE HELPER, NOT SIX COPIES ================================
# The six clear sites shipped the same defect because they were six byte-identical
# copies. If a seventh path is added by copy-paste, this arm is what catches it.
_left=$(grep -cE "^[[:space:]]*UPDATE tasks SET status='todo'[[:space:]]*$" \
          "$SRC/task/need.sh" "$SRC/task/answer.sh" | awk -F: '{n+=$2} END{print n+0}')
[[ "${_left:-0}" == "0" ]] \
  && ok_t "no gate-clear path still inlines its own SET status='todo' (all route through the helper)" \
  || bad_t "a gate-clear path still inlines SET status='todo'" "count=$_left"

# ================ 7. DIVE-4896: THE MAKER HAS MOVED ON ==========================
# DIVE-4891, 2026-09-23: ops answered its gate after dev had taken DIVE-4893. The
# restore handed 4891 back in_progress (dev now held TWO in_progress rows) and the
# answer's ping was drained by dev's next fresh session, pre-empting the
# heartbeat's own choice of row. The rule: a seat busy on a DIFFERENT row gets the
# answered row back on 'todo' and no ping; a seat idle on THIS gate is unchanged.
# Its own seat (dev3), so the in_progress rows sections 1-5 leave on dev2 do not
# make every arm below read "busy".
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev3','main','builder');"
SENT="$TMP/sent"; : >"$SENT"
cmd_send() { printf '%s\t%s\n' "$1" "$*" >>"$SENT"; return 0; }
seed3() { # <ident> <status>
  db "INSERT INTO tasks(ident,title,status,created_by,assignee,started_at,first_started_at)
      VALUES('$1','a row on dev3',$(sqlq "$2"),'main','dev3',
             CASE WHEN $(sqlq "$2")='in_progress' THEN $(sqlq "$STARTED") ELSE NULL END,
             CASE WHEN $(sqlq "$2")='in_progress' THEN $(sqlq "$STARTED") ELSE NULL END);"
}
gfirst() { db "SELECT COALESCE(first_started_at,'<null>') FROM tasks WHERE ident='$1';"; }
busy3()  { db "SELECT COUNT(*) FROM tasks WHERE assignee='dev3' AND status='in_progress';"; }
park3()  { # <ident>: file a tier-1 decision that stays open, as dev3
  ( cmd_task_need "$1" --type=decision --tier=1 --recommend='A' --options='A|B' \
      --ask='which way?' --from=dev3 ) >/dev/null 2>&1
}
fixture_actor dev3

# 7a. THE MEASURED CASE — busy on row B when row A's gate is answered.
seed3 DIVE-940 in_progress
park3 DIVE-940
seed3 DIVE-941 in_progress           # the maker moved on while A was parked
[[ "$(gstat DIVE-940)" == "blocked" && "$(busy3)" == "1" ]] \
  && ok_t "7a precondition: A is parked on its gate and the maker holds only B in_progress" \
  || bad_t "7a precondition" "A=$(gstat DIVE-940) busy=$(busy3)"
: >"$SENT"
_out=$( ( cmd_task_answer DIVE-940 --value='B' --human ) 2>&1 )
[[ "$(gstat DIVE-940)" == "todo" ]] \
  && ok_t "7a: a gate answered while the maker works another row restores it to todo, not in_progress" \
  || bad_t "7a: busy maker -> answered row goes to todo" "got=$(gstat DIVE-940)"
[[ "$(busy3)" == "1" && "$(gstat DIVE-941)" == "in_progress" ]] \
  && ok_t "7a: the maker still holds exactly ONE in_progress row — the one it is working" \
  || bad_t "7a: the maker holds one in_progress row" "busy=$(busy3) B=$(gstat DIVE-941)"
[[ "$(gstart DIVE-940)" == "<null>" && "$(gfirst DIVE-940)" == "$STARTED" ]] \
  && ok_t "7a: started_at is cleared for a fresh claim, first_started_at is kept" \
  || bad_t "7a: claim reset" "started=$(gstart DIVE-940) first=$(gfirst DIVE-940)"
[[ ! -s "$SENT" ]] \
  && ok_t "7a: NOTHING is sent to the busy maker — the answer is on the row, the heartbeat dispatches it" \
  || bad_t "7a: no ping to a busy maker" "sent=[$(cat "$SENT")]"
[[ "$_out" == *"not pinged: dev3 is working DIVE-941"* ]] \
  && ok_t "7a: the answerer's receipt says why nobody was pinged, naming the row the maker is on" \
  || bad_t "7a: receipt names the busy row" "out=[$_out]"
[[ "$(gprev DIVE-940)" == "<null>" ]] \
  && ok_t "7a: gate_prev_status is still consumed on the yielded restore" \
  || bad_t "7a: gate_prev_status consumed" "got=$(gprev DIVE-940)"

# 7b. CONTROL — the maker's only in_progress row IS the answered one (idle,
#     waiting on this gate): today's behaviour, byte for byte.
db "UPDATE tasks SET status='done' WHERE ident='DIVE-941';"
seed3 DIVE-942 in_progress
park3 DIVE-942
: >"$SENT"
( cmd_task_answer DIVE-942 --value='A' --human ) >/dev/null 2>&1
[[ "$(gstat DIVE-942)" == "in_progress" && "$(gstart DIVE-942)" == "$STARTED" ]] \
  && ok_t "7b CONTROL: a maker idle on this gate gets it back in_progress, clock untouched" \
  || bad_t "7b CONTROL: idle maker -> in_progress" "status=$(gstat DIVE-942) started=$(gstart DIVE-942)"
grep -q "^dev3	.*DIVE-942 gate cleared" "$SENT" \
  && ok_t "7b CONTROL: ...and the resume ping is still sent" \
  || bad_t "7b CONTROL: idle maker still pinged" "sent=[$(cat "$SENT")]"

# 7c. CONTROL — a row that was 'todo' when gated comes back todo whether or not
#     the maker is busy, and a busy maker is still not pinged about it.
seed3 DIVE-943 todo
park3 DIVE-943
: >"$SENT"
( cmd_task_answer DIVE-943 --value='A' --human ) >/dev/null 2>&1
[[ "$(gstat DIVE-943)" == "todo" && ! -s "$SENT" ]] \
  && ok_t "7c: a todo row stays todo, and the maker busy on DIVE-942 is not pinged about it" \
  || bad_t "7c: todo row + busy maker" "status=$(gstat DIVE-943) sent=[$(cat "$SENT")]"

# 7d. SCOPE — only the typed answer yields. A filer's own withdraw runs inside
#     the filer's call, on THIS row, so it restores in_progress even while the
#     seat holds another in_progress row (the push-for-review / tier-0 clears are
#     the same shape, and yielding there would pull a row from under its pusher).
seed3 DIVE-944 in_progress
( cmd_task_need DIVE-944 --type=manual --ask='plug the cable in' --from=dev3 ) >/dev/null 2>&1
( cmd_task_need DIVE-944 --withdraw --from=dev3 ) >/dev/null 2>&1
[[ "$(gstat DIVE-944)" == "in_progress" ]] \
  && ok_t "7d CONTROL: a filer's own withdraw is not yielded (only the async typed answer is)" \
  || bad_t "7d CONTROL: withdraw restores in_progress" "got=$(gstat DIVE-944)"

# 7e. The helper's non-yield form is byte-identical to the DIVE-4817 statement,
#     so the five other callers cannot have moved.
seed3 DIVE-945 in_progress
db "UPDATE tasks SET status='blocked', gate_prev_status='in_progress' WHERE ident='DIVE-945';"
db "$(_gate_restore_status_sql "$(gid DIVE-945)")"
[[ "$(gstat DIVE-945)" == "in_progress" ]] \
  && ok_t "7e CONTROL: without 'yield' the restore ignores a busy seat, exactly as before" \
  || bad_t "7e CONTROL: non-yield restore unchanged" "got=$(gstat DIVE-945)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
SUMMARY_PRINTED=1
[[ "$FAIL" == "0" ]]
