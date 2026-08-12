#!/usr/bin/env bash
# TIER: nightly — 52.4s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-2477 — a re-close must not REFRESH done_at.
#
# Every close writer passed ", done_at=datetime('now')" unconditionally, so any
# second close on an already-closed row silently moved the original close
# timestamp forward. Measured on a fixture: a row closed at T, then a BARE
# `task done` (no --result, which is the one shape DIVE-2464's result guard
# correctly stays silent on) => done_at became 'now'.
#
# Why it matters beyond tidiness: DIVE-2464's own refusal quotes done_at as the
# evidence of who closed when ("is ALREADY done (closed <done_at>; assignee
# ...)"). A bare re-close in between moves that timestamp, so the refusal cites
# a time that is not the close it is protecting.
#
# FOUR writers, four arms — `task done`, `task cancel`, `task verify`'s
# auto-close, and the REOPEN path. The reopen arm is not decoration: COALESCE is
# only correct if a row that legitimately reopens has its done_at CLEARED,
# otherwise `task reject` (the one verb that reopens a closed row — the verifier
# withdrawing their own grade) leaves a stale done_at behind and the eventual
# real close would preserve THAT instead of stamping fresh. So the fix cuts both
# ways and both directions are graded here.
#
# Preserved-vs-refreshed is measured by BACKDATING done_at to a sentinel after
# the first close rather than by sleeping: datetime('now') has 1-second
# granularity, and a same-second re-stamp is indistinguishable from a preserve.
# The sentinel makes refresh unmissable.
# Run: bash tests/task_close_preserves_done_at_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades.
# NOTE the absence of `2>/dev/null` — the helper's stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
# DIVE-2518: impersonate through the SEALED seam. `USER=agent-x` no longer moves
# the actor — that env path WAS the forgery this ticket closed, and these arms
# were leaning on it. tests/lib/actor_seam.sh explains the migration.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"

SRC=src
TMP="$(mktemp -d /tmp/task-doneat-preserve-unit.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh lib/registry.sh \
         lib/disk.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_push.sh cmd_org.sh \
         cmd_project.sh; do
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

status_of() { db "SELECT status                 FROM tasks WHERE ident=$(sqlq "$1");"; }
doneat_of() { db "SELECT COALESCE(done_at,'')   FROM tasks WHERE ident=$(sqlq "$1");"; }
res_of()    { db "SELECT COALESCE(result,'')    FROM tasks WHERE ident=$(sqlq "$1");"; }

SENTINEL='2020-01-01 00:00:00'
backdate() { db "UPDATE tasks SET done_at=$(sqlq "$SENTINEL") WHERE ident=$(sqlq "$1");"; }

add() { JSON_MODE=1 cmd_task_add "$@" 2>"$TMP"/err | jq -r '.data.ident // empty'; }

# ── instrument: without impersonation the actor-scoped guards make cases vacuous
actor_is() { ( actor_seam_as "$1"; task_actor ); }
[[ "$(actor_is dev2)" == "dev2" ]] \
  && ok_t "INSTRUMENT: harness impersonates an actor (task_actor -> dev2)" \
  || bad_t "INSTRUMENT: actor impersonation broken" "got '$(actor_is dev2)' — cases are vacuous"

# ── A: the FIRST close still stamps done_at (the still-works control) ─────────
# Without this, a fix that simply never wrote done_at would pass every arm below.
A=$(add "A first done stamps done_at" --assignee=dev)
as dev cmd_task_done "$A" --result="first close" >/dev/null
a_at=$(doneat_of "$A")
[[ "$(status_of "$A")" == "done" && -n "$a_at" ]] \
  && ok_t "A: first 'task done' stamps done_at ($a_at)" \
  || bad_t "A: first close did not stamp done_at" "status=$(status_of "$A") done_at='$a_at'"

D=$(add "D first cancel stamps done_at" --assignee=dev)
as dev cmd_task_cancel "$D" --result="abandoned" >/dev/null
d_at=$(doneat_of "$D")
[[ "$(status_of "$D")" == "cancelled" && -n "$d_at" ]] \
  && ok_t "D: first 'task cancel' stamps done_at ($d_at)" \
  || bad_t "D: first cancel did not stamp done_at" "status=$(status_of "$D") done_at='$d_at'"

# ── B: a BARE repeat `task done` PRESERVES the first close timestamp ──────────
# The REPEAT is bare on purpose: that is the shape neither result guard refuses,
# so the write actually lands and this arm is not vacuous.
# DIVE-2773: the FIRST close now needs a reason (a first close with a blank one
# is refused on both verbs), so it carries a --result here. Only the first close
# moved — a bare re-close is explicitly exempt, which is what this arm grades and
# why the change did not cost this harness an assertion.
B=$(add "B bare re-done preserves done_at" --assignee=dev)
as dev cmd_task_done "$B" --result="first close" >/dev/null
backdate "$B"
as dev cmd_task_done "$B" >/dev/null; b_rc=$?
b_at=$(doneat_of "$B")
(( b_rc == 0 )) \
  && ok_t "B/REACHABILITY: the bare re-close lands (rc=0, not refused) — the arm below is not vacuous" \
  || bad_t "B/REACHABILITY: bare re-close did not land (rc=$b_rc)" "$(head -c 200 "$TMP"/err)"
[[ "$b_at" == "$SENTINEL" ]] \
  && ok_t "B: bare repeat 'task done' PRESERVES the original done_at" \
  || bad_t "B: bare repeat 'task done' REFRESHED done_at" "expected '$SENTINEL', got '$b_at'"

# ── C: `task cancel` after a done PRESERVES the first close timestamp ─────────
C=$(add "C cancel-after-done preserves done_at" --assignee=dev)
as dev cmd_task_done "$C" --result="first close" >/dev/null   # DIVE-2773: first close needs a reason
backdate "$C"
as dev cmd_task_cancel "$C" >/dev/null; c_rc=$?
c_at=$(doneat_of "$C")
(( c_rc == 0 )) \
  && ok_t "C/REACHABILITY: cancel-after-done lands (rc=0)" \
  || bad_t "C/REACHABILITY: cancel-after-done did not land (rc=$c_rc)" "$(head -c 200 "$TMP"/err)"
[[ "$c_at" == "$SENTINEL" ]] \
  && ok_t "C: 'task cancel' over a done row PRESERVES the original done_at" \
  || bad_t "C: 'task cancel' over a done row REFRESHED done_at" "expected '$SENTINEL', got '$c_at'"

# ── E: `task verify`'s auto-close is a THIRD close writer ─────────────────────
# DIVE-2067 taught this exact lesson one column over: when you guard one verb
# against a clobber the question is "which other verbs write this column".
# Reachable as the recorded verifier re-verifying their own already-done row
# (DIVE-2067's refusal fires only for a DIFFERENT actor).
#
# DIVE-3097: `add "..." --assignee=main --verifier=main` is now refused BY
# DESIGN — this is the exact create-time state that fix exists to close. But
# the state must stay reachable to CLOSE (the 149 existing rows in this shape
# are explicitly not retro-graded), so this arm reseeds it with a raw db
# write instead, the same escape `task verifier` itself relies on to test its
# own refusal (a guarded verb cannot be the thing that builds the fixture for
# its own guard). Without this, `add` silently returns empty, `cmd_task_verify
# ""` exits rc=2 as a USAGE error, and the arm reads as a `task verify`
# regression instead of what it actually is: a fixture built on a door this
# same change closed. The assertion right below is what stops that from
# happening again quietly — it fails LOUDLY if the seed ever stops landing in
# the guarded state, instead of the arm going vacuous.
E=$(db "INSERT INTO tasks (title, assignee, verifier, created_by, project_key)
        VALUES ($(sqlq "E verify re-close preserves done_at"), $(sqlq main), $(sqlq main), $(sqlq main), 'dive');
        SELECT ident FROM tasks WHERE id=last_insert_rowid();")
[[ -n "$E" && "$(db "SELECT assignee||'='||COALESCE(verifier,'') FROM tasks WHERE ident=$(sqlq "$E");")" == "main=main" ]] \
  && ok_t "E/SEED: raw-seeded row reaches assignee==verifier ('main'=='main') — the state DIVE-3097 blocks at CREATE, still reachable to grade" \
  || bad_t "E/SEED: raw seed did not reach the guarded state" "E='$E' row='$(db "SELECT assignee,verifier FROM tasks WHERE ident=$(sqlq "$E");")'"
as main cmd_task_done "$E" --result="closed by the verifier" >/dev/null
backdate "$E"
as main cmd_task_verify "$E" --cmd=true >/dev/null; e_rc=$?
e_at=$(doneat_of "$E")
(( e_rc == 0 )) \
  && ok_t "E/REACHABILITY: the verifier's re-verify of their own done row lands (rc=0)" \
  || bad_t "E/REACHABILITY: verify re-close did not land (rc=$e_rc)" "$(head -c 300 "$TMP"/err)"
[[ "$e_at" == "$SENTINEL" ]] \
  && ok_t "E: 'task verify' auto-close over a done row PRESERVES done_at" \
  || bad_t "E: 'task verify' auto-close REFRESHED done_at" "expected '$SENTINEL', got '$e_at'"
# DIVE-2067's preserve-by-appending must still hold — this arm must not have
# bought a timestamp by dropping the record it sits next to.
[[ "$(res_of "$E")" == *"superseded result"* ]] \
  && ok_t "E: DIVE-2067's preserve-by-appending still holds on that same write" \
  || bad_t "E: DIVE-2067 result preservation regressed" "result='$(head -c 120 <<<"$(res_of "$E")")'"

# ── F: the REOPEN path must CLEAR done_at, or COALESCE preserves a STALE one ──
# `task reject` is the one verb that reopens a CLOSED row: the recorded verifier
# withdrawing their own grade (DIVE-2112 refuses everyone else). Before this
# change it left done_at set — a row with status='todo' AND a close timestamp,
# the same self-contradiction DIVE-2113 refuses `task start` for. With COALESCE
# in place that stale value would then be PRESERVED as the real close time.
F=$(add "F reject clears done_at" --assignee=dev --verifier=main)
as dev  cmd_task_done "$F" --result="maker delivery" >/dev/null   # routes to verifier
as main cmd_task_done "$F" --result="verifier ACK" >/dev/null     # real close
backdate "$F"
as main cmd_task_reject "$F" --feedback="withdrawing my own grade" >/dev/null; f_rc=$?
f_reopened=$(status_of "$F"); f_at=$(doneat_of "$F")
(( f_rc == 0 )) && [[ "$f_reopened" == "todo" ]] \
  && ok_t "F/REACHABILITY: the verifier's reject reopens their own closed row (rc=0, status=todo)" \
  || bad_t "F/REACHABILITY: reject did not reopen the closed row (rc=$f_rc status=$f_reopened)" "$(head -c 300 "$TMP"/err)"
[[ -z "$f_at" ]] \
  && ok_t "F1: the reopen CLEARS done_at (no open row carrying a close timestamp)" \
  || bad_t "F1: reopened row still carries a done_at" "got '$f_at' on status=$f_reopened"
# ...and the eventual real close stamps FRESH, not the stale pre-reject value.
# TWO closes, not one: after the bounce the row is assigned to the MAKER again, so
# the maker's `task done` re-DELIVERS (routes to the verifier) and only the
# verifier's own close writes done_at. A single `as main cmd_task_done` here would
# route rather than close — and would then pass on the unfixed tree too, i.e. be
# vacuous. Asserted rather than assumed below.
as dev  cmd_task_done "$F" --result="maker delivery, second pass" >/dev/null
as main cmd_task_done "$F" --result="verifier ACK, second pass" >/dev/null
f2_at=$(doneat_of "$F")
[[ "$(status_of "$F")" == "done" ]] \
  && ok_t "F2/REACHABILITY: the second pass really CLOSES the row (status=done, not re-routed)" \
  || bad_t "F2/REACHABILITY: second pass did not close" "status=$(status_of "$F") — the arm below is vacuous"
[[ -n "$f2_at" && "$f2_at" != "$SENTINEL" ]] \
  && ok_t "F2: the close AFTER a reopen stamps a FRESH done_at ($f2_at), not the stale one" \
  || bad_t "F2: close after reopen did not stamp fresh" "expected != '$SENTINEL', got '$f2_at'"

# ── G: reject's OTHER exit — max_iterations — is a CONTROL, not a fix ──────────
# Same verb, different branch: it does not bounce, it files a gate. Symmetry says
# "clear done_at here too"; measurement says otherwise, and this arm is why the
# source does not. On a row that was CLOSED, `task need` REFUSES (rc=5, "is done —
# reopen it before gating on a human"), so the status stays 'done' — clearing
# done_at would leave a done row with no close clock, a new contradiction rather
# than a fix. So the invariant graded here is PRESERVED, same as B/C/E.
#
# It also records a SEPARATE pre-existing defect this ticket does not fix: that
# refusal means a reject at max_iterations over a closed row cannot escalate at
# all — it writes the feedback text and then fails rc!=0. Filed on its own row.
# max_iterations is set by SQL because the point is the branch, not the flag that
# reaches it.
G=$(add "G reject at max_iterations clears done_at" --assignee=dev --verifier=main)
as dev  cmd_task_done "$G" --result="maker delivery" >/dev/null
as main cmd_task_done "$G" --result="verifier ACK" >/dev/null
backdate "$G"
db "UPDATE tasks SET max_iterations=1, iteration=1 WHERE ident=$(sqlq "$G");"
as main cmd_task_reject "$G" --feedback="stuck, escalating" >/dev/null; g_rc=$?
g_st=$(status_of "$G"); g_at=$(doneat_of "$G")
# Reachability is the FEEDBACK WRITE, not rc: this branch is known to fail rc=5 on
# a closed row (that is the separate defect above). Keying reachability on rc would
# make the arm unrunnable; keying it on the write this branch uniquely performs
# does not.
[[ "$(res_of "$G")" == *"stuck, escalating"* ]] \
  && ok_t "G/REACHABILITY: the max_iterations branch ran (its feedback write landed; rc=$g_rc status=$g_st)" \
  || bad_t "G/REACHABILITY: max_iterations branch not reached (rc=$g_rc status=$g_st)" "$(head -c 300 "$TMP"/err)"
[[ "$g_at" == "$SENTINEL" && "$g_st" == "done" ]] \
  && ok_t "G: reject-at-max_iterations PRESERVES done_at — it does not reopen, so the close clock stands" \
  || bad_t "G: reject-at-max_iterations moved or cleared done_at" "got '$g_at' (want '$SENTINEL') on status=$g_st"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
